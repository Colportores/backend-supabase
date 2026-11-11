-- ============================================================================
-- 0189 · La cédula se guarda en 7 u 8 dígitos y el registro rechaza otra (backend-supabase#266, P1)
--
-- El caso: la 0188 copia a `ficha_administrativa` la cédula que llega en los metadatos del registro tal cual
-- (sin los espacios de los extremos). La app ya exige 7 u 8 dígitos, con puntos y guion permitidos
-- (`registrar_usuario_use_case.dart`), pero un `signUp` a mano contra la API podía guardar cualquier texto,
-- de cualquier largo, y Administración veía «4.567.890-1» o «45678901» según cómo se escribió.
--
-- Decisión del orquestador (11/11, por el mapa de decisiones, seguridad barata; PR #275, comentario
-- 6802891832): el servidor exige lo mismo que la app.
--   · `tg_auth_usuario_nuevo()` normaliza la cédula a solo dígitos (saca puntos, guion y espacios) y la guarda
--     así, para que Administración la vea siempre igual.
--   · Si después de normalizarla no quedan 7 u 8 dígitos, el registro se rechaza con `CD005` (no se crea ni
--     el perfil ni la cuenta). Un cliente de la app nunca choca con esto: valida lo mismo antes de mandar.
--   · Sin la clave, null o en blanco, sigue como en la 0188: no se crea la ficha y el registro sigue.
--   · El CHECK de la tabla pasa a «7 u 8 dígitos».
-- (P2 de la misma decisión: las cuentas de antes de la 0188 siguen sin ficha; una corrección se hace a mano
-- con service_role hasta la pantalla de Administración.)
--
-- Las fichas que ya existen (creadas desde la 0188) se normalizan igual. Si alguna no queda en 7 u 8 dígitos,
-- la migración no se aplica, no cambia nada y nombra cada cuenta (sin la cédula: es dato personal); se
-- corrige a mano con service_role y se vuelve a aplicar.
--
-- El código: CD001..CD004 ya los usan las ciudades (0066, 0109); CD005 es el siguiente libre de la serie.
--
-- Forward-only: esta migración no se edita una vez aplicada.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. La forma, en un solo lugar
-- ----------------------------------------------------------------------------

-- La cédula sin puntos, guiones ni espacios. No valida: la forma la mira quien la usa (7 u 8 dígitos).
create function public.cedula_normalizada(p_cedula text)
returns text
language sql
immutable
set search_path = ''
as $$
  select regexp_replace(p_cedula, '[.[:space:]-]', '', 'g')
$$;

comment on function public.cedula_normalizada(text) is
  'La cédula sin puntos, guiones ni espacios (0189). La ficha_administrativa la guarda así y exige 7 u 8 '
  'dígitos. Interna: nadie con JWT la llama.';

revoke all on function public.cedula_normalizada(text) from public, anon, authenticated, service_role;

-- ----------------------------------------------------------------------------
-- 2. Las fichas que ya existen
-- ----------------------------------------------------------------------------

do $$
declare
  v_malas  text;
  v_n      integer;
begin
  select count(*), string_agg(format('· cuenta %s%s: la cédula no queda en 7 u 8 dígitos.',
                                     f.usuario_id, case when f.deleted_at is not null then ' (dada de baja)' else '' end),
                              E'\n' order by f.usuario_id)
    into v_n, v_malas
    from public.ficha_administrativa f
   where public.cedula_normalizada(f.cedula) !~ '^[0-9]{7,8}$';

  if v_n > 0 then
    raise exception E'La migración 0189 (la cédula en 7 u 8 dígitos) no se aplicó: hay % ficha(s) con una cédula que no queda en 7 u 8 dígitos. No se cambió nada.\n%\nCorregila a mano con service_role (solo dígitos) y volvé a aplicar la migración.',
      v_n, v_malas;
  end if;
end;
$$;

update public.ficha_administrativa
   set cedula = public.cedula_normalizada(cedula)
 where cedula <> public.cedula_normalizada(cedula);

alter table public.ficha_administrativa drop constraint ficha_administrativa_cedula_no_vacia;
alter table public.ficha_administrativa
  add constraint ficha_administrativa_cedula_7_u_8_digitos check (cedula ~ '^[0-9]{7,8}$');

comment on column public.ficha_administrativa.cedula is
  'La cédula que la persona puso al registrarse, en solo dígitos (7 u 8; sin puntos, guion ni espacios, '
  '0189), copiada por el servidor al crear la cuenta. Dato personal: no entra al audit_log ni baja al teléfono.';

-- ----------------------------------------------------------------------------
-- 3. El registro normaliza y rechaza
-- ----------------------------------------------------------------------------

-- Mismo cuerpo de la 0188, con la cédula normalizada y CD005. La cédula se mira antes de crear nada, como
-- la versión de los Términos: un registro rechazado no deja ni el perfil.
create or replace function public.tg_auth_usuario_nuevo()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_version text := new.raw_user_meta_data ->> 'terminos_version';
  v_cedula  text := nullif(btrim(new.raw_user_meta_data ->> 'cedula'), '');
begin
  -- Antes de crear nada: una versión con forma inválida, o con la forma correcta pero que nunca se publicó,
  -- frena el registro entero.
  if v_version is not null
     and (v_version !~ '^v[1-9][0-9]{0,8}$'
          or not (v_version = any (public.terminos_versiones_publicadas()))) then
    raise exception 'La versión de los Términos y la Política de Privacidad no es una versión publicada (publicadas: %; llegó "%").',
      array_to_string(public.terminos_versiones_publicadas(), ', '), left(v_version, 40)
      using errcode = 'TC001';
  end if;

  -- La cédula: solo dígitos, 7 u 8. El aviso no repite lo que llegó (dato personal).
  if v_cedula is not null then
    v_cedula := public.cedula_normalizada(v_cedula);
    if v_cedula !~ '^[0-9]{7,8}$' then
      raise exception 'La cédula no es válida: tienen que ser 7 u 8 dígitos, con o sin puntos y guion. Revisala y volvé a registrarte.'
        using errcode = 'CD005';
    end if;
  end if;

  insert into public.usuario (id, email, nombre, apellido, created_by)
  values (
    new.id,
    new.email,
    coalesce(new.raw_user_meta_data ->> 'nombre', ''),
    coalesce(new.raw_user_meta_data ->> 'apellido', ''),
    new.id
  )
  on conflict (id) do nothing;

  if v_version is not null then
    insert into public.consentimiento_terminos (usuario_id, version, created_by)
    values (new.id, v_version, new.id)
    on conflict (usuario_id, version) do nothing;
  end if;

  if v_cedula is not null then
    insert into public.ficha_administrativa (usuario_id, cedula, created_by)
    values (new.id, v_cedula, new.id)
    on conflict (usuario_id) do nothing;
  end if;

  return new;
end;
$$;

comment on function public.tg_auth_usuario_nuevo() is
  'AFTER INSERT en auth.users: crea el perfil (public.usuario) con el mismo id; si el registro trae '
  'raw_user_meta_data.terminos_version (v1, v2…), la fila de consentimiento_terminos con la hora del servidor '
  '(una versión que no es una de terminos_versiones_publicadas() frena el registro con TC001, 0065); y si trae '
  'raw_user_meta_data.cedula, la ficha_administrativa con la cédula en solo dígitos (0188, 0189): si no quedan '
  '7 u 8 dígitos, el registro se frena con CD005. Corre solo al crear la cuenta: cambiar después los metadatos '
  'no toca la ficha.';

-- create or replace conserva los privilegios; se repite explícito, como las demás.
revoke all on function public.tg_auth_usuario_nuevo() from public, anon, authenticated;
