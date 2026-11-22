-- ============================================================================
-- 0188 · La cédula del colportor en una ficha solo de la nube que lee Administración (backend-supabase#266)
--
-- El caso: Rocío pone su cédula al registrarse (HU-AUTH-001). Administración la necesita para identificarla
-- (becas, pagos, casa editora). Hasta hoy quedaba solo en los metadatos de Supabase Auth
-- (`auth.users.raw_user_meta_data.cedula`): ninguna tabla la tenía, Administración la veía solo entrando a
-- Supabase a mano y Rocío la podía cambiar (`auth.updateUser`) sin que nadie se enterara.
--
-- Decisión de Cristian (11/11, «Cédula adm.», docs-organizacion#184, comentario 6794634519): ficha propia en
-- el servidor. Al registrarse, el servidor copia la cédula a un lugar solo de la nube, que lee únicamente
-- Administración por una RPC y que Rocío no puede cambiar sola. La app no cambia: sigue mandándola en los
-- metadatos del registro (`signUp(data: {'cedula': …})`, front-colportores-mobile).
--
-- Dónde se guarda: una tabla aparte, `ficha_administrativa`, y no una columna de `usuario`.
--   · `usuario` baja al teléfono y la leen el coordinador (por sus RPC) y cada persona la suya: una columna
--     nueva viajaría con la fila. La ficha no entra a `sync.entidad`: no baja al teléfono.
--   · Una fila por cuenta (`usuario_id` único). Es dato personal: no entra al `audit_log` (su CHECK ya
--     rechaza una clave `cedula`, 0073) y ningún evento lleva su valor.
--
-- Quién la lee y quién la escribe:
--   · La escribe solo el trigger del registro (`tg_auth_usuario_nuevo`, SECURITY DEFINER) o el servidor
--     (`service_role`). Ninguna persona con su JWT tiene privilegios sobre la tabla: ni leerla ni cambiarla
--     (tampoco Rocío la suya, ni el coordinador, ni el ADMIN directo).
--   · La lee Administración (rol ADMIN) por `cedula_de_la_cuenta(p_usuario_id)`. Cualquier otra sesión, 42501.
--   · Cambiar después los metadatos de Auth no toca la ficha: el trigger corre solo al crear la cuenta.
--
-- Qué se copia: el valor de `raw_user_meta_data ->> 'cedula'` sin los espacios de los extremos. Sin la clave,
-- con null o vacía, no se crea la ficha y el registro sigue igual (cuentas creadas a mano, el panel). Si el
-- servidor valida o normaliza la forma (7 u 8 dígitos, puntos y guion) está pendiente de decisión (ver el PR):
-- hoy se copia lo que llega, como pide la decisión.
--
-- Qué se preserva: la migración no toca ninguna fila existente (las cuentas que ya existen no tienen ficha:
-- copiarles la cédula de los metadatos de hoy también está pendiente, ver el PR). Lo único que cambia de lo
-- que ya estaba es el cuerpo de `tg_auth_usuario_nuevo()` (create or replace conserva dueño, privilegios y el
-- trigger `on_auth_user_created`); la versión de los Términos (0065) se guarda igual que antes.
--
-- Forward-only: esta migración no se edita una vez aplicada.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. La tabla
-- ----------------------------------------------------------------------------

create table public.ficha_administrativa (
  id            uuid primary key default public.uuid_generate_v7(),
  usuario_id    uuid not null references public.usuario(id) on delete cascade,
  cedula        text not null,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  created_by    uuid references public.usuario(id) on delete set null,
  deleted_at    timestamptz,
  sync_version  bigint not null default 0,
  xmin_w        xid8 not null default pg_current_xact_id(),
  constraint ficha_administrativa_usuario_key unique (usuario_id),
  constraint ficha_administrativa_cedula_no_vacia check (btrim(cedula) <> '')
);

comment on table public.ficha_administrativa is
  'Datos de la cuenta que lee solo Administración, hoy la cédula (0188, backend-supabase#266, decisión de '
  'Cristian 11/11 «Cédula adm.»). Una fila por cuenta. Solo de la nube: no está en sync.entidad. La escribe '
  'el trigger del registro (tg_auth_usuario_nuevo) o el servidor; nadie con su JWT la lee ni la cambia: '
  'Administración la lee por cedula_de_la_cuenta().';
comment on column public.ficha_administrativa.cedula is
  'La cédula que la persona puso al registrarse (raw_user_meta_data.cedula, sin espacios en los extremos), '
  'copiada por el servidor al crear la cuenta. Dato personal: no entra al audit_log ni baja al teléfono.';

-- El cursor del delta que exigen los triggers de auditoría (0002 §14); hoy nadie lo usa.
create index ficha_administrativa_delta_idx on public.ficha_administrativa (xmin_w, id);

create trigger ficha_administrativa_auditoria_insert before insert on public.ficha_administrativa
  for each row execute function public.tg_auditoria_insert();
create trigger ficha_administrativa_auditoria_update before update on public.ficha_administrativa
  for each row execute function public.tg_auditoria_update();

-- ----------------------------------------------------------------------------
-- 2. RLS y privilegios: nadie la toca con su JWT
-- ----------------------------------------------------------------------------

alter table public.ficha_administrativa enable row level security;

-- La única política: si algún día se diera el privilegio de lectura, solo el ADMIN vería filas. Hoy
-- authenticated no tiene ningún privilegio sobre la tabla, así que la lectura va solo por la RPC.
create policy ficha_administrativa_select_admin on public.ficha_administrativa
  for select to authenticated
  using ((select public.tiene_rol('ADMIN')));

comment on policy ficha_administrativa_select_admin on public.ficha_administrativa is
  'Red de seguridad: solo el ADMIN. authenticated no tiene privilegios sobre la tabla; Administración lee '
  'por cedula_de_la_cuenta() (0188).';

revoke all on public.ficha_administrativa from public, anon, authenticated;
grant all on public.ficha_administrativa to service_role;

-- ----------------------------------------------------------------------------
-- 3. El registro crea también la ficha
-- ----------------------------------------------------------------------------

-- Mismo cuerpo de 0065 con la cédula: el perfil y el consentimiento se crean igual que antes y, si el
-- registro trae `cedula`, se guarda la ficha. SECURITY DEFINER y search_path vacío, como antes.
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
  'raw_user_meta_data.cedula, la ficha_administrativa con esa cédula (0188). Corre solo al crear la cuenta: '
  'cambiar después los metadatos no toca la ficha.';

-- create or replace conserva los privilegios; se repite explícito, como las demás.
revoke all on function public.tg_auth_usuario_nuevo() from public, anon, authenticated;

-- ----------------------------------------------------------------------------
-- 4. La lectura de Administración
-- ----------------------------------------------------------------------------

-- La cédula de una cuenta, o null si no tiene ficha viva (se registró sin cédula, la cuenta no existe o la
-- ficha se dio de baja). Solo el ADMIN; cualquier otra sesión, 42501. No registra eventos: el valor no
-- entra al audit_log.
create function public.cedula_de_la_cuenta(p_usuario_id uuid)
returns text
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_cedula text;
begin
  if auth.uid() is null then
    raise exception 'Para ver la cédula de una cuenta hay que iniciar sesión.'
      using errcode = 'insufficient_privilege';
  end if;

  if not public.tiene_rol('ADMIN') then
    raise exception 'Solo Administración puede ver la cédula de una cuenta. Si la necesitás, pedísela a Administración.'
      using errcode = 'insufficient_privilege';
  end if;

  select f.cedula into v_cedula
    from public.ficha_administrativa f
   where f.usuario_id = p_usuario_id
     and f.deleted_at is null;

  return v_cedula;
end;
$$;

comment on function public.cedula_de_la_cuenta(uuid) is
  'La cédula que la cuenta puso al registrarse (ficha_administrativa), o null si no tiene ficha viva. Solo '
  'Administración (rol ADMIN); otra sesión, 42501 (0188, backend-supabase#266, decisión de Cristian 11/11 '
  '«Cédula adm.»).';

revoke all on function public.cedula_de_la_cuenta(uuid) from public, anon, authenticated, service_role;
grant execute on function public.cedula_de_la_cuenta(uuid) to authenticated;
