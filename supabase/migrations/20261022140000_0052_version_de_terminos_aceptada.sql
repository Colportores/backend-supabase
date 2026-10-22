-- ============================================================================
-- 0052 · La versión de Términos y Política de Privacidad que acepta la colportora (backend-supabase#109)
--
-- El caso: Rocío se registra y marca «He leído y acepto Términos y Política de Privacidad» (HU-AUTH-001,
-- R-AU04, R-PV-05, Ley 18.331). Hoy el servidor no guarda qué versión del documento aceptó ni cuándo, así
-- que si el texto cambia no hay cómo probar qué leyó cada persona. Decisiones de Cristian «Términos»
-- (07/10: una página web con su versión) y «Texto legal» (21/10: borrador nuestro, lo aprueba legal).
--
-- Dónde se guarda (lo propone este issue): una tabla aparte, `consentimiento_terminos`, y no columnas en
-- `usuario`.
--   · `usuario` es entidad de sync: una columna nueva viajaría en cada fila al teléfono y a quien lea el
--     perfil (y el contrato del motor no la conoce). La tabla nueva no entra a `sync.entidad`: el consentimiento
--     no baja al teléfono; la colportora lo lee con su JWT, por la API.
--   · Es un historial: cuando salga la v2 y haya que volver a pedir la aceptación, se suma una fila (la v1
--     queda como prueba) en vez de pisar la columna. Una fila por (usuario, versión).
--
-- Cómo llega la versión: el móvil la manda junto con el registro, en los metadatos de Supabase Auth
-- (`signUp(data: {'terminos_version': 'v1'})`, front-colportores-mobile#386). El trigger que ya crea el perfil
-- al registrarse (`on_auth_user_created`) crea también la fila del consentimiento, con la hora del servidor
-- (`now()`): el cliente no pone la fecha. La puede escribir solo ese trigger (SECURITY DEFINER) o el servidor
-- (`service_role`); un usuario con su JWT solo la lee, y solo la suya.
--
-- Reglas de la versión:
--   · Forma `v1`, `v2`, … (`^v[1-9][0-9]*$`, hasta 9 dígitos): la dirección del documento es `…/terminos/v1`.
--     El servidor NO sabe cuáles versiones existen (el texto lo aprueba legal, docs-organizacion#71): solo
--     exige la forma.
--   · Sin la clave `terminos_version` (o con null) el registro sigue como hasta hoy y no se guarda nada: el
--     móvil todavía no la manda. Volver obligatoria la versión es una pendiente (ver el PR).
--   · Con la clave y una forma que no es esa, el registro se rechaza con `TC001`: es un error del cliente y
--     dejar crear la cuenta sin poder probar qué aceptó es peor que frenarla.
--
-- Qué se preserva: la migración no toca ninguna fila existente. Las cuentas que ya existen (datos simulados
-- hasta diciembre) quedan sin consentimiento: no se inventa qué aceptaron. Lo único que cambia de lo que ya
-- estaba es el cuerpo de `tg_auth_usuario_nuevo()` (create or replace conserva dueño, privilegios y el trigger).
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. La tabla
-- ----------------------------------------------------------------------------

create table public.consentimiento_terminos (
  id            uuid primary key default public.uuid_generate_v7(),
  usuario_id    uuid not null references public.usuario(id) on delete cascade,
  version       text not null,
  aceptado_en   timestamptz not null default now(),
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  created_by    uuid references public.usuario(id) on delete set null,
  deleted_at    timestamptz,
  sync_version  bigint not null default 0,
  xmin_w        xid8 not null default pg_current_xact_id(),
  constraint consentimiento_terminos_version_check
    check (version ~ '^v[1-9][0-9]{0,8}$'),
  constraint consentimiento_terminos_usuario_version_key
    unique (usuario_id, version)
);

comment on table public.consentimiento_terminos is
  'Qué versión de los Términos y la Política de Privacidad aceptó cada persona y cuándo (0052, '
  'HU-AUTH-001, R-AU04). Una fila por (usuario, versión): un historial, no un dato que se pisa. Lo escribe '
  'solo el trigger del registro (tg_auth_usuario_nuevo) o el servidor; cada persona lee solo lo suyo. No '
  'está en sync.entidad: no baja al teléfono.';
comment on column public.consentimiento_terminos.version is
  'La versión aceptada, con la forma de la dirección del documento: v1, v2… El servidor no sabe cuáles '
  'existen, solo exige la forma.';
comment on column public.consentimiento_terminos.aceptado_en is
  'Cuándo, según el reloj del servidor en la transacción del registro. El cliente no la manda.';

-- El cursor del delta que exigen los triggers de auditoría (0002 §14); hoy nadie lo usa.
create index consentimiento_terminos_delta_idx on public.consentimiento_terminos (xmin_w, id);

create trigger consentimiento_terminos_auditoria_insert before insert on public.consentimiento_terminos
  for each row execute function public.tg_auditoria_insert();
create trigger consentimiento_terminos_auditoria_update before update on public.consentimiento_terminos
  for each row execute function public.tg_auditoria_update();

-- ----------------------------------------------------------------------------
-- 2. RLS: cada persona lee lo suyo; nadie lo escribe con su JWT
-- ----------------------------------------------------------------------------

alter table public.consentimiento_terminos enable row level security;

create policy consentimiento_terminos_select_propio on public.consentimiento_terminos
  for select to authenticated
  using (usuario_id = (select auth.uid()));

-- Sin política de INSERT ni de UPDATE, y sin el privilegio: el trigger del registro (DEFINER) y el servidor
-- son los únicos que escriben. Sin DELETE: el historial no se borra.
revoke all on public.consentimiento_terminos from anon, authenticated;
grant select on public.consentimiento_terminos to authenticated;
grant all on public.consentimiento_terminos to service_role;

-- ----------------------------------------------------------------------------
-- 3. El registro crea también el consentimiento
-- ----------------------------------------------------------------------------

-- Misma función de 0001 con la versión aceptada: el perfil se crea igual que antes y, si el registro trae
-- `terminos_version`, se guarda. SECURITY DEFINER y search_path vacío, como antes.
create or replace function public.tg_auth_usuario_nuevo()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_version text := new.raw_user_meta_data ->> 'terminos_version';
begin
  -- Antes de crear nada: una versión con forma inválida frena el registro entero.
  if v_version is not null and v_version !~ '^v[1-9][0-9]{0,8}$' then
    raise exception 'La versión de los Términos y la Política de Privacidad tiene que ser v1, v2… (llegó "%").',
      left(v_version, 40)
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

  return new;
end;
$$;

comment on function public.tg_auth_usuario_nuevo() is
  'AFTER INSERT en auth.users: crea el perfil (public.usuario) con el mismo id y, si el registro trae '
  'raw_user_meta_data.terminos_version (v1, v2…), la fila de consentimiento_terminos con la hora del servidor. '
  'Una versión con otra forma frena el registro con TC001 (0052, HU-AUTH-001).';

-- create or replace conserva los privilegios; se repite explícito, como las demás.
revoke all on function public.tg_auth_usuario_nuevo() from public, anon, authenticated;
