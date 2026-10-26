-- ============================================================================
-- 0073 · Tabla audit_log: la auditoría de la nube, que solo escribe el servidor, empezando por
--        agregar_acompaniamiento() (backend-supabase#136, HU-ADM-007, HU-JOR-004, RA-SE05)
--
-- Origen: decisión de Cristian del 23/10, «Audit log» («Crear la auditoría»): la tabla `audit_log`
-- de la nube que ya describen los documentos (RA-SE05 en 08-conceptos-transversales.md, HU-ADM-007,
-- conservada 5 años según ADR-005) registra las operaciones críticas del sistema con el evento,
-- quién, cuándo y la fila, nunca un correo ni datos de clientes. El acompañamiento agregado a una
-- jornada cerrada (HU-JOR-004: «`audit_log` registra el cambio») es el primer evento. Los demás
-- eventos críticos (cambio de rol, baja de cuenta, el parámetro de antigüedad de los precios…) los
-- suma cada HU llamando a `auditoria.registrar()`.
--
-- ## Dónde vive y por qué
--
-- En un schema propio, `auditoria`, que NO está en la API (config.toml, [api] schemas) ni tiene
-- grants para anon ni authenticated; mismo criterio que `ruteo` (0036) y `sync` (0002). Una tabla de
-- `public` tendría que llevar las columnas de auditoría de fila, `sync_version`, `xmin_w` y el
-- trigger de edición que exigen los tests 0001/0002/0003, y un registro que solo se agrega no se
-- edita ni se sincroniza. Tiene RLS activada y ninguna política, además de no tener grants: si
-- alguien abre un grant por error, la RLS lo sigue cerrando. NO está en `sync.entidad` ni en
-- Realtime: no viaja al teléfono (el `audit_log` local, R-UB09, es otra cosa y no se sincroniza).
--
-- ## Las columnas (HU-ADM-007)
--
--   id             uuid, lo genera la base.
--   created_at     cuándo (la HU lo llama `timestamp`; todas las tablas del repo dicen created_at).
--   event_type     el evento, en minúsculas y con guion bajo: `acompaniamiento_agregado`.
--   actor_user_id  quién lo hizo: `auth.uid()` de la sesión que llamó; null si lo hizo el servidor
--                  sin sesión de usuario (service_role). FK a `usuario`: ADR-005, un usuario no se
--                  borra, así que el actor de un registro nunca queda huérfano.
--   target_user_id sobre quién (opcional): el colportor acompañado.
--   tabla, fila_id sobre qué fila (opcional): `jornada` y su id.
--   metadata       el detalle, un objeto JSON SIN datos personales (ver abajo).
--
-- ## Quién escribe y quién lee
--
--   · Escribir: solo el servidor. `auditoria.registrar()` (SECURITY DEFINER) es la única puerta;
--     la llaman las funciones SECURITY DEFINER y los triggers de `public` (corren como dueño, con el
--     JWT de quien llamó, así que `actor_user_id` es esa persona) y `service_role` (que además
--     puede hacer INSERT directo). anon y authenticated no tienen ni USAGE sobre el schema: un
--     cliente ni siquiera ve que la tabla existe. Un trigger de `public` que registre algo tiene que
--     ser SECURITY DEFINER.
--   · Leer: nadie con JWT. Mientras ninguna HU tenga una pantalla para verla (HU-ADM-007 es la del
--     panel del administrador), `service_role` y el dueño son los únicos que la leen. Cuando llegue,
--     la lectura será una RPC de ADMIN con filtros y la exportación, no un grant a la tabla.
--   · Solo se agrega: UPDATE, DELETE y TRUNCATE los rechaza un trigger (AU001) también para el
--     dueño y para service_role («RLS + permisos lo bloquean», HU-ADM-007). La retención de 5 años
--     (S30, ADR-005) no se aplica todavía: nada la borra; la purga, si hace falta, es una decisión
--     y una migración aparte.
--
-- ## Sin datos personales (RA-SE05, Ley 18.331)
--
-- `metadata` solo admite un objeto chico (hasta 4000 caracteres) sin ningún `@` (un correo) y sin
-- claves que nombren datos personales o de clientes: correo/email/mail, teléfono/celular/whatsapp,
-- nombre, apellido, dirección, documento/cédula, persona, cliente, contraseña/token. Lo valida un
-- CHECK (`auditoria.metadata_sin_datos_personales`): es una red de seguridad barata contra un
-- descuido, no un detector; la regla de fondo es que el detalle lleve identificadores (uuid), días y
-- cantidades, no texto de personas. Quién y sobre quién van en columnas (uuid), no en el detalle.
--
-- ## Para otros repos
--
--   · docs-organizacion: HU-JOR-004 apunta a esta tabla; esquema-datos.md la suma (tabla de la
--     nube, schema `auditoria`, fuera del sync); HU-ADM-007 usa estos nombres de columna
--     (created_at en vez de `timestamp`). Issue de seguimiento en docs-organizacion.
--   · front-coordinadores-web: nada que cambiar. agregar_acompaniamiento() devuelve lo mismo;
--     el evento se escribe solo cuando la fila cambia (un reintento con ya_estaba = true no suma
--     un segundo registro).
--   · Otros eventos: `perform auditoria.registrar('<evento>', '<tabla>', <fila_id>, <usuario>,
--     jsonb_build_object(…))` dentro de la misma transacción que el cambio, para que ambos
--     queden o ninguno quede.
--
-- Forward-only: no se edita una vez aplicada.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. El schema, cerrado a los clientes
-- ----------------------------------------------------------------------------

create schema auditoria;

comment on schema auditoria is
  'La auditoría de la nube (backend-supabase#136, RA-SE05, HU-ADM-007): audit_log, que solo escribe el '
  'servidor y solo se agrega. Fuera de la API y sin acceso para anon ni authenticated.';

revoke all on schema auditoria from public, anon, authenticated;
grant usage on schema auditoria to service_role;

-- ----------------------------------------------------------------------------
-- 2. La validación del detalle: sin correo ni datos de clientes
-- ----------------------------------------------------------------------------

create function auditoria.metadata_sin_datos_personales(p_metadata jsonb)
returns boolean
language sql
immutable
set search_path = ''
as $$
  select p_metadata is not null
     and jsonb_typeof(p_metadata) = 'object'
     and length(p_metadata::text) <= 4000
     -- Ningún correo, en ninguna parte (ni en un valor ni en una clave).
     and position('@' in p_metadata::text) = 0
     -- Ninguna clave (a cualquier profundidad) que nombre un dato personal o de un cliente.
     -- Una clave que contenga la palabra también cuenta: es la opción segura.
     and p_metadata::text !~* ('"[^"]*(mail|correo|telefono|celular|whatsapp|phone|nombre|apellido'
                               || '|direccion|domicilio|documento|cedula|persona|cliente'
                               || '|password|contrasenia|token)[^"]*"\s*:')
$$;

comment on function auditoria.metadata_sin_datos_personales(jsonb) is
  'CHECK de audit_log.metadata (0073): un objeto JSON de hasta 4000 caracteres, sin ningún @ y sin '
  'claves que nombren correo, teléfono, nombre, apellido, dirección, documento, persona, cliente, '
  'contraseña o token. Red de seguridad, no detector.';

revoke all on function auditoria.metadata_sin_datos_personales(jsonb)
  from public, anon, authenticated, service_role;
-- Un CHECK se evalúa con los permisos de quien inserta: service_role puede insertar directo.
grant execute on function auditoria.metadata_sin_datos_personales(jsonb) to service_role;

-- ----------------------------------------------------------------------------
-- 3. La tabla
-- ----------------------------------------------------------------------------

create table auditoria.audit_log (
  id             uuid primary key default gen_random_uuid(),
  created_at     timestamptz not null default now(),
  event_type     text not null,
  actor_user_id  uuid references public.usuario (id),
  target_user_id uuid references public.usuario (id),
  tabla          text,
  fila_id        uuid,
  metadata       jsonb not null default '{}'::jsonb,
  constraint audit_log_event_type_forma check (event_type ~ '^[a-z][a-z0-9_]{2,59}$'),
  constraint audit_log_tabla_forma check (tabla is null or tabla ~ '^[a-z][a-z0-9_]{0,62}$'),
  -- La fila va con su tabla: un fila_id suelto no dice de qué fila habla.
  constraint audit_log_fila_con_tabla check (fila_id is null or tabla is not null),
  constraint audit_log_metadata_sin_datos_personales
    check (auditoria.metadata_sin_datos_personales(metadata))
);

comment on table auditoria.audit_log is
  'Auditoría de la nube (0073, backend-supabase#136, RA-SE05, HU-ADM-007): una fila por operación '
  'crítica, con el evento, quién (actor_user_id; null si lo hizo el servidor sin sesión), sobre quién '
  '(target_user_id), sobre qué fila (tabla, fila_id) y un detalle JSON SIN datos personales. Solo la '
  'escribe el servidor (auditoria.registrar y service_role), nadie con JWT la lee y solo se agrega: '
  'UPDATE, DELETE y TRUNCATE dan AU001.';
comment on column auditoria.audit_log.created_at is 'Cuándo (la HU-ADM-007 lo llama timestamp).';
comment on column auditoria.audit_log.event_type is
  'El evento, en minúsculas y con guion bajo (p. ej. acompaniamiento_agregado).';
comment on column auditoria.audit_log.actor_user_id is
  'Quién lo hizo: auth.uid() de la sesión que llamó; null si lo hizo el servidor sin sesión.';
comment on column auditoria.audit_log.target_user_id is 'Sobre quién (opcional).';
comment on column auditoria.audit_log.tabla is 'Tabla de la fila afectada (opcional).';
comment on column auditoria.audit_log.fila_id is 'Id de la fila afectada (opcional; exige tabla).';
comment on column auditoria.audit_log.metadata is
  'Detalle del evento: un objeto JSON de hasta 4000 caracteres sin correo ni datos de clientes '
  '(auditoria.metadata_sin_datos_personales).';

-- Los filtros de HU-ADM-007: por tipo de evento, por actor, por target y por rango de fechas.
create index audit_log_created_at_idx on auditoria.audit_log (created_at desc);
create index audit_log_event_type_idx on auditoria.audit_log (event_type, created_at desc);
create index audit_log_actor_idx on auditoria.audit_log (actor_user_id, created_at desc)
  where actor_user_id is not null;
create index audit_log_target_idx on auditoria.audit_log (target_user_id, created_at desc)
  where target_user_id is not null;

alter table auditoria.audit_log enable row level security;
-- Sin políticas, a propósito: ver el comentario del encabezado.

revoke all on auditoria.audit_log from public, anon, authenticated, service_role;
grant select, insert on auditoria.audit_log to service_role;

-- ----------------------------------------------------------------------------
-- 4. Solo se agrega
-- ----------------------------------------------------------------------------

create function auditoria.tg_solo_agregar()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  raise exception 'El registro de auditoría solo se agrega: no se modifica ni se borra.'
    using errcode = 'AU001';
end;
$$;

comment on function auditoria.tg_solo_agregar() is
  'Trigger de audit_log (0073): rechaza UPDATE, DELETE y TRUNCATE con AU001, también al dueño.';

revoke all on function auditoria.tg_solo_agregar() from public, anon, authenticated, service_role;

create trigger audit_log_solo_agregar_fila
  before update or delete on auditoria.audit_log
  for each row execute function auditoria.tg_solo_agregar();

create trigger audit_log_solo_agregar_truncate
  before truncate on auditoria.audit_log
  for each statement execute function auditoria.tg_solo_agregar();

-- ----------------------------------------------------------------------------
-- 5. La puerta: auditoria.registrar()
-- ----------------------------------------------------------------------------

create function auditoria.registrar(p_event_type text,
                                    p_tabla text default null,
                                    p_fila_id uuid default null,
                                    p_target_user_id uuid default null,
                                    p_metadata jsonb default '{}'::jsonb)
returns uuid
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_id uuid;
begin
  -- El actor es quien llamó (el JWT de la sesión sigue visible dentro de un SECURITY DEFINER);
  -- nadie lo puede pasar a mano. Sin sesión de usuario (service_role) queda null.
  insert into auditoria.audit_log (event_type, actor_user_id, target_user_id, tabla, fila_id,
                                   metadata)
  values (p_event_type, auth.uid(), p_target_user_id, p_tabla, p_fila_id,
          coalesce(p_metadata, '{}'::jsonb))
  returning id into v_id;
  return v_id;
end;
$$;

comment on function auditoria.registrar(text, text, uuid, uuid, jsonb) is
  'La única puerta a audit_log (0073, backend-supabase#136): agrega un registro con el actor = '
  'auth.uid(). La llaman las funciones y triggers SECURITY DEFINER de public dentro de la '
  'transacción del cambio, y service_role. Rechaza (22023/23514) un evento mal formado o un detalle '
  'con correo o datos de clientes.';

revoke all on function auditoria.registrar(text, text, uuid, uuid, jsonb)
  from public, anon, authenticated, service_role;
grant execute on function auditoria.registrar(text, text, uuid, uuid, jsonb) to service_role;

-- ----------------------------------------------------------------------------
-- 6. agregar_acompaniamiento() escribe su evento (HU-JOR-004)
-- ----------------------------------------------------------------------------

-- Igual que la de 0043 salvo el `perform auditoria.registrar(...)` después del UPDATE. El evento se
-- escribe solo cuando la fila cambia: el reintento idempotente (ya_estaba) no suma un segundo
-- registro, y cualquier error (JO001..JO004, CZ011…) sale antes y no deja ninguno. El detalle lleva
-- la campaña y el día, nunca nombres.
create or replace function public.agregar_acompaniamiento(p_campania_id uuid, p_jornada_id uuid)
returns table (jornada_id uuid, colportor_id uuid, dia date, acompaniante_id uuid,
               acompaniante_nombre text, acompaniante_apellido text, ya_estaba boolean)
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_motivo   text;
  v_campania public.campania;
  v_jornada  public.jornada;
  v_yo       uuid := auth.uid();
  v_otro     text;
begin
  -- El permiso, antes de mirar nada más.
  v_motivo := public.motivo_mapa_de_campania(p_campania_id);
  if v_motivo = 'SIN_PERMISO' then
    raise exception 'Solo el coordinador de la campaña o un administrador puede registrar acompañamientos. Entrá con la cuenta del coordinador de esta campaña.'
      using errcode = 'insufficient_privilege';
  end if;
  if v_motivo = 'CAMPANIA_TERMINADA' then
    raise exception 'La campaña ya terminó y sus acompañamientos quedan como están. Elegí una campaña en curso.'
      using errcode = 'CZ011';
  end if;
  perform public.lanzar_motivo_mapa(v_motivo);

  if p_jornada_id is null then
    raise exception 'Elegí la jornada del colportor a la que querés agregar tu acompañamiento.'
      using errcode = 'invalid_parameter_value';
  end if;

  select * into v_campania from public.campania c where c.id = p_campania_id;

  -- La jornada, solo si es de un colportor de esta campaña (inscripción vigente ese día, en las
  -- fechas de la campaña). Con candado: el doble toque y dos coordinadores se serializan acá.
  select j.* into v_jornada
    from public.jornada j
    join public.campania_colportor i
      on i.usuario_id = j.colportor_id and i.campania_id = p_campania_id
   where j.id = p_jornada_id
     and j.deleted_at is null
     and j.inicio >= i.created_at
     and (i.deleted_at is null or j.inicio < i.deleted_at)
     and public.hoy_montevideo(j.inicio) >= v_campania.fecha_inicio
     and public.hoy_montevideo(j.inicio) <= coalesce(v_campania.fecha_fin, 'infinity'::date)
     for update of j;
  if not found then
    raise exception 'La jornada no existe o no es de un colportor de esta campaña. Recargá el historial del colportor y elegí otra.'
      using errcode = 'JO001';
  end if;

  if v_jornada.fin is null then
    raise exception 'La jornada todavía no terminó. Cuando el colportor la cierre vas a poder agregar tu acompañamiento.'
      using errcode = 'JO002';
  end if;

  if v_jornada.colportor_id = v_yo then
    raise exception 'No podés registrarte como acompañante de tu propia jornada. Elegí una jornada de otro colportor.'
      using errcode = 'JO004';
  end if;

  if v_jornada.acompaniante_id is not null and v_jornada.acompaniante_id <> v_yo then
    select trim(coalesce(u.nombre, '') || ' ' || coalesce(u.apellido, '')) into v_otro
      from public.usuario u where u.id = v_jornada.acompaniante_id;
    raise exception 'Esta jornada ya figura acompañada por %. El acompañamiento registrado no se cambia desde el panel.',
      coalesce(nullif(v_otro, ''), 'otra persona')
      using errcode = 'JO003';
  end if;

  if v_jornada.acompaniante_id is null then
    update public.jornada j set acompaniante_id = v_yo where j.id = v_jornada.id;
    -- HU-JOR-004: «`audit_log` registra el cambio». Quién (actor) = el coordinador; sobre quién
    -- (target) = el colportor acompañado; el detalle, la campaña y el día, sin nombres.
    perform auditoria.registrar(
      'acompaniamiento_agregado', 'jornada', v_jornada.id, v_jornada.colportor_id,
      jsonb_build_object('campania_id', p_campania_id,
                         'dia', public.hoy_montevideo(v_jornada.inicio)));
  end if;

  return query
    select v_jornada.id,
           v_jornada.colportor_id,
           public.hoy_montevideo(v_jornada.inicio),
           v_yo,
           usr.nombre,
           usr.apellido,
           (v_jornada.acompaniante_id is not null)
      from public.usuario usr
     where usr.id = v_yo;
end;
$$;

comment on function public.agregar_acompaniamiento(uuid, uuid) is
  'Vista 33, HU-JOR-004 (0043, backend-supabase#97; 0073, #136): el coordinador de la campaña (o un '
  'ADMIN) registra que acompañó al colportor en una jornada ya cerrada: jornada.acompaniante_id = '
  'auth.uid(), y deja el evento acompaniamiento_agregado en audit_log (actor = quien llama, target = '
  'el colportor, detalle = campaña y día). Idempotente (ya_estaba, sin segundo registro) si ya era '
  'él; si la acompañó otra persona, JO003 y no se pisa. Errores: 42501 sin permiso; CZ001 campaña '
  'inexistente; CZ011 campaña terminada; 22023 sin jornada; JO001 jornada que no es de un colportor '
  'de la campaña; JO002 jornada abierta; JO003 ya acompañada por otra persona; JO004 la jornada es '
  'del propio coordinador.';
