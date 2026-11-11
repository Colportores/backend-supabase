-- ============================================================================
-- 0182 · La versión vigente de los Términos baja por el sync y la aceptación de cada versión nueva la registran todos los roles
--        (backend-supabase#254, casilla «Términos»; decisión de Cristian del 05/11 en docs-organizacion#76, sobre
--        backend-supabase#109 / 0065)
--
-- ## El caso
--
-- Sale la v2 de los Términos y la Política de Privacidad. Rocío (colportora) abre la app: tiene que saber, sin conexión, cuál es
-- la versión vigente y si ya aceptó esa. Luis (coordinador) y Daniel (administrador) abren el panel: a ellos también hay que
-- pedirles que acepten la v2, y la aceptación tiene que quedar guardada con su hora. Hasta hoy (0065) la versión solo se
-- registraba cuando una colportora creaba su cuenta, y el teléfono no tenía de dónde saber cuál era la vigente.
--
-- ## Qué hace
--
--   1. **La versión vigente es un parámetro global más** (`parametro_global`, 0070): la clave `terminos_version_vigente`, con el
--      número de la versión (1 = `v1`). Ya baja por el pull a todas las personas autenticadas, así que no hay entidad nueva
--      para la versión. Se siembra en 1 (la única publicada hoy). Sube con una migración, junto con
--      `terminos_versiones_publicadas()`, cuando se publica el texto de una versión nueva.
--      · Un trigger exige que sea una versión publicada: una vigente que nadie puede aceptar (`v9`) no entra.
--      · Cada cambio ya queda en `audit_log` (0110).
--   2. **`terminos_version_vigente()`**: la misma versión como texto (`'v1'`), para quien llama a la API (el panel).
--   3. **`aceptar_terminos(p_version)`**: la persona autenticada, con cualquier rol (colportor, coordinador o administrador),
--      acepta una versión publicada (`null` = la vigente). Escribe la fila de `consentimiento_terminos` con la hora del servidor
--      y deja un evento en `audit_log`. Repetirla no hace nada (`ya_estaba = true`). Una versión que no es una de las
--      publicadas levanta `TC001`, como el registro.
--   4. **`consentimiento_terminos` baja por el sync, solo la propia** (solo bajada, cada persona la suya): el teléfono sabe si ya
--      aceptó la vigente sin conexión. Cambia lo que decía la 0065 («no baja al teléfono»).
--
-- ## Lo que NO hace
--
--   · No bloquea nada en el servidor: pedir la aceptación antes de seguir es de la app y del panel (qué pantalla, cuándo).
--   · No toca las filas que existen: ninguna cuenta queda con una aceptación inventada.
--
-- ## Los datos
--
-- Una fila nueva en `parametro_global` (la clave sembrada en 1) y un índice. Forward-only. Lo prueba supabase/tests/0182_… .
--
-- ## Para otros repos
--
--   · front-colportores-mobile#671: lee `terminos_version_vigente` del pull de `parametro_global`, la compara con su
--     `consentimiento_terminos` bajado y, si falta, llama `aceptar_terminos()`.
--   · front-coordinadores-web#144: el panel llama `terminos_version_vigente()` y `aceptar_terminos()` (coordinadores y
--     administradores).
--   · docs-organizacion#172: contrato (clave y RPC nuevas) y esquema.
--
-- Forward-only: esta migración no se edita una vez aplicada.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. La clave nueva de parametro_global
-- ----------------------------------------------------------------------------

alter table public.parametro_global drop constraint parametro_global_clave_valor_check;
alter table public.parametro_global
  add constraint parametro_global_clave_valor_check
  check ((clave = 'dias_antiguedad_precios' and valor >= 1)
      or (clave = 'terminos_version_vigente' and valor between 1 and 999999999));

comment on table public.parametro_global is
  'Parámetros de toda la aplicación que cambia Administración (0070, decisión de Cristian del 23/10, HU-CAT-006). Una fila por '
  'clave, valor entero. Hoy: dias_antiguedad_precios (15 por defecto), los días desde que el colportor bajó los precios a '
  'partir de los cuales el aviso se pone fuerte y le pide conectarse; y terminos_version_vigente (0182), el número de la '
  'versión vigente de los Términos y la Política de Privacidad (1 = v1). Baja por el pull; lo lee todo usuario autenticado; '
  'lo escribe solo el servidor y cada cambio queda en audit_log (0110, backend-supabase#152).';
comment on column public.parametro_global.clave is
  'Nombre del parámetro. Hoy dias_antiguedad_precios y terminos_version_vigente.';
comment on column public.parametro_global.valor is
  'Valor entero. dias_antiguedad_precios: días, 1 o más (sin tope). terminos_version_vigente: el número de la versión (1 = '
  'v1), una de terminos_versiones_publicadas().';

-- Una vigente que no se puede aceptar no entra: tiene que ser una versión publicada.
create function public.tg_parametro_terminos_vigente()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.clave = 'terminos_version_vigente'
     and new.deleted_at is null
     and not ('v' || new.valor::text = any (public.terminos_versiones_publicadas())) then
    raise exception 'La versión vigente de los Términos tiene que ser una versión publicada (publicadas: %; llegó "v%").',
      array_to_string(public.terminos_versiones_publicadas(), ', '), new.valor
      using errcode = 'TC001';
  end if;
  return new;
end;
$$;

comment on function public.tg_parametro_terminos_vigente() is
  'BEFORE INSERT/UPDATE en parametro_global (0182): terminos_version_vigente solo puede ser una de '
  'terminos_versiones_publicadas(); otra levanta TC001.';

revoke all on function public.tg_parametro_terminos_vigente() from public, anon, authenticated, service_role;

create trigger parametro_global_terminos_vigente before insert or update on public.parametro_global
  for each row execute function public.tg_parametro_terminos_vigente();

-- La siembra, como la de la 0070: el valor de referencia no es un cambio de nadie, así que no deja un registro en audit_log
-- (0110: cada cambio posterior sí).
alter table public.parametro_global disable trigger parametro_global_auditar_cambio;
insert into public.parametro_global (clave, valor) values ('terminos_version_vigente', 1);
alter table public.parametro_global enable trigger parametro_global_auditar_cambio;

-- ----------------------------------------------------------------------------
-- 2. La versión vigente como texto
-- ----------------------------------------------------------------------------

create function public.terminos_version_vigente()
returns text
language sql
stable
security definer
set search_path = ''
as $$
  select 'v' || p.valor::text
    from public.parametro_global p
   where p.clave = 'terminos_version_vigente' and p.deleted_at is null
$$;

comment on function public.terminos_version_vigente() is
  'La versión vigente de los Términos y la Política de Privacidad como texto (v1, v2…): el parámetro global '
  'terminos_version_vigente (0182). La lee toda persona autenticada.';

revoke all on function public.terminos_version_vigente() from public, anon, authenticated, service_role;
grant execute on function public.terminos_version_vigente() to authenticated, service_role;

-- ----------------------------------------------------------------------------
-- 3. Aceptar una versión, con cualquier rol
-- ----------------------------------------------------------------------------

create function public.aceptar_terminos(p_version text default null)
returns table (version text, aceptado_en timestamptz, ya_estaba boolean)
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_yo      uuid := auth.uid();
  v_version text := coalesce(p_version, public.terminos_version_vigente());
  v_fila    public.consentimiento_terminos;
  v_nueva   boolean := false;
begin
  if v_yo is null
     or not exists (select 1 from public.usuario u
                     where u.id = v_yo and u.deleted_at is null and u.suspendido_en is null) then
    raise exception 'Entrá con tu cuenta para aceptar los Términos y la Política de Privacidad.'
      using errcode = 'insufficient_privilege';
  end if;

  if v_version is null
     or v_version !~ '^v[1-9][0-9]{0,8}$'
     or not (v_version = any (public.terminos_versiones_publicadas())) then
    raise exception 'La versión de los Términos y la Política de Privacidad no es una versión publicada (publicadas: %; llegó "%").',
      array_to_string(public.terminos_versiones_publicadas(), ', '), left(coalesce(v_version, ''), 40)
      using errcode = 'TC001';
  end if;

  insert into public.consentimiento_terminos as c (usuario_id, version, created_by)
  values (v_yo, v_version, v_yo)
  on conflict on constraint consentimiento_terminos_usuario_version_key do nothing
  returning * into v_fila;
  v_nueva := found;

  if not v_nueva then
    select * into v_fila from public.consentimiento_terminos c
     where c.usuario_id = v_yo and c.version = v_version;
  else
    perform auditoria.registrar('terminos_aceptados', 'consentimiento_terminos', v_fila.id, v_yo,
                                jsonb_build_object('version', v_version));
  end if;

  return query select v_fila.version, v_fila.aceptado_en, not v_nueva;
end;
$$;

comment on function public.aceptar_terminos(text) is
  'La persona autenticada, con cualquier rol (colportor, coordinador o administrador), acepta una versión publicada de los '
  'Términos y la Política de Privacidad (null = la vigente): guarda su fila en consentimiento_terminos con la hora del '
  'servidor y deja el evento terminos_aceptados en audit_log (0182, sobre 0065). Repetirla no hace nada (ya_estaba = true). '
  'Errores: 42501 sin sesión o cuenta dada de baja o suspendida; TC001 la versión no es una de las publicadas.';

revoke all on function public.aceptar_terminos(text) from public, anon, authenticated, service_role;
grant execute on function public.aceptar_terminos(text) to authenticated;

-- ----------------------------------------------------------------------------
-- 4. El consentimiento propio baja por el sync
-- ----------------------------------------------------------------------------

create index consentimiento_terminos_duenio_delta_idx on public.consentimiento_terminos (usuario_id, xmin_w, id);

insert into sync.entidad (nombre, tabla, columna_pk, permite_push, sigue_campanias, columna_duenio)
values ('consentimiento_terminos', 'public.consentimiento_terminos'::regclass, 'id', false, false, 'usuario_id');

comment on table public.consentimiento_terminos is
  'Qué versión de los Términos y la Política de Privacidad aceptó cada persona y cuándo (0065; HU-AUTH-001, R-AU04). Una fila '
  'por (usuario, versión): un historial, no un dato que se pisa. La escribe el trigger del registro (tg_auth_usuario_nuevo), '
  'aceptar_terminos() (cualquier rol, 0182) o el servidor; cada persona lee solo lo suyo. Desde la 0182 baja al teléfono por '
  'el sync (solo bajada, cada persona la suya) para saber sin conexión si ya aceptó la versión vigente.';
