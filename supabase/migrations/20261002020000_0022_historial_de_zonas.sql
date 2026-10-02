-- ============================================================================
-- 0022 · Historial de zonas: la zona de cada inscripción, desde cuándo, hasta cuándo y quién
--        (backend-supabase#57, decisión de Cristian del 02/10)
--
-- Decisión de Cristian del 02/10 (front-colportores-mobile#244, comentario 5952408648; idéntica
-- en backend-supabase#32, comentario 5952409871 y #48, comentario 5952409154): «Modelo de zonas:
-- una zona actual en la inscripción, como hoy, más un historial (desde, hasta, quién la asignó)
-- que se llena solo al asignar, quitar o dar de baja. Sirve para auditoría; no cambia la app ni
-- la vista 24.» El esquema (esquema-datos.md, campania_colportor) y HU-CAM-006 («Historial de
-- zonas») dejaron el nombre de la tabla y las columnas a acordar con el backend: son las de abajo.
--
-- ## Qué es
--
-- campania_colportor.zona_id sigue siendo la zona actual y la única que lee el resto del sistema
-- (mis_zonas(), el pull, la RLS). El historial es una tabla aparte, campania_colportor_zona_historial,
-- con una fila por tramo: «esta inscripción tuvo esta zona desde X hasta Y». Mientras la zona sigue
-- vigente, hasta es null: hay a lo sumo un tramo abierto por inscripción (índice único parcial), y
-- coincide con campania_colportor.zona_id (null = sin tramo abierto).
--
--   zona                    la zona de ese tramo (las zonas no se borran: la baja es lógica).
--   desde / hasta           cuándo empezó y cuándo terminó (null = sigue vigente). Hora real
--                           (clock_timestamp), no la de inicio de la transacción: si dos
--                           coordinadores cambian la misma inscripción a la vez, el segundo espera
--                           el lock de la fila y su now() sería anterior al desde que dejó el
--                           primero (hasta < desde). Un tramo cierra donde abre el siguiente: el
--                           mismo instante, sin hueco.
--   created_by              quién ASIGNÓ la zona (la columna de auditoría de siempre: el que abrió
--                           el tramo). null = un proceso del servidor (seeds, un job, service_role).
--   cerrada_por             quién hizo el cambio que cerró el tramo (la otra zona, «Quitar» o la
--                           baja de la zona). null mientras está abierto, o si fue un proceso del
--                           servidor.
--   inicial                 true en los tramos que ya estaban cuando se activó el historial (0022):
--                           su desde es el de esta migración y no el de la asignación real, que no se
--                           puede reconstruir («arranca con la zona vigente de cada inscripción»,
--                           esquema-datos.md). No se inventa una fecha: se marca.
--
-- ## Quién lo llena: un trigger, sin acción del coordinador
--
-- tg_campania_colportor_historial_de_zona(), AFTER sobre campania_colportor:
--   · INSERT con zona_id no null → abre un tramo (altas del servidor con zona).
--   · UPDATE de zona_id (cambia de valor) → cierra el tramo abierto y, si la zona nueva no es
--     null, abre otro. Cubre asignar_zona() (asignar y cambiar), quitar_zona() («Quitar»),
--     baja_zona() (los asignados quedan sin zona) y cualquier UPDATE del servidor.
--   · Asignar la zona que ya tiene, quitarle la zona a quien no tiene, o cambiar otra columna
--     (meta_libros, la baja de la inscripción) no tocan la fila de zona_id o no cambian su valor:
--     no escriben nada. Un rechazo (CZ0xx, 42501) tampoco: pasa antes del UPDATE.
-- Es del trigger y no de cada RPC para que valga para todo camino de escritura, también los futuros
-- (reactivar una inscripción, reasignar). Corre en la misma transacción que el cambio: o quedan los
-- dos o ninguno. Los RPC ya toman la inscripción FOR UPDATE, así que dos cambios de la misma
-- inscripción se serializan y el historial no se cruza; el historial solo se toca con la
-- inscripción tomada, por lo que no agrega ningún orden de locks nuevo.
-- «Quién» es auth.uid(): adentro de los RPC (SECURITY DEFINER) el JWT sigue presente.
--
-- ## Lo que NO hace
--
--   · No baja al teléfono: no está en sync.entidad, no va por el pull ni por el push, y no cambia
--     la app ni la vista 24 (decisión del 02/10). Vive solo en la nube.
--   · No cambia lo que dice campania_colportor.zona_id ni lo que ve el colportor: mis_zonas(),
--     el mapa y el área del pull siguen leyendo la zona actual.
--   · No cierra el tramo al dar de baja la INSCRIPCIÓN (deleted_at): una inscripción dada de baja
--     conserva su zona (0012), y el historial sigue a zona_id. Qué pasa con el tramo cuando la
--     inscripción se da de baja o se reactiva queda como pregunta para Cristian (en el PR).
--
-- ## Quién lo lee
--
-- El ADMIN y el coordinador de la campaña de esa inscripción (campania.coordinador_id), por
-- PostgREST. El colportor no lo ve, ni el suyo. Nadie escribe directo: authenticated y anon no
-- tienen el privilegio de escritura (solo el trigger, que es SECURITY DEFINER, y service_role).
-- Una baja es lógica (deleted_at), como en el resto del esquema; el historial no se borra nunca:
-- solo desaparece con la inscripción si se elimina a la persona (ON DELETE CASCADE de la
-- inscripción, que ya cae con el usuario).
--
-- ## Para otros repos
--
--   · docs-organizacion (esquema-datos.md, campania_colportor): el nombre de la tabla y sus
--     columnas, que la decisión dejó «a acordar con el backend».
--   · bff-coordinadores (cuando exista) y el panel: si algún día muestran el historial, leen la
--     tabla con el JWT del coordinador; hoy no hace falta ningún endpoint.
--   · front-colportores-mobile y motor (#178): nada, no baja al teléfono.
--
-- Datos: se agrega un tramo inicial por cada inscripción que hoy tiene zona (también las dadas de
-- baja, que conservan la suya); no se toca ninguna fila existente.
-- Forward-only: esta migración no se edita una vez aplicada.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. La tabla
-- ----------------------------------------------------------------------------

-- Con las columnas de auditoría y el cursor de todas las tablas de public (los tests de 0001 y
-- 0002 lo exigen), aunque no esté en el sync: created_by es el que asignó la zona.
create table public.campania_colportor_zona_historial (
  id                     uuid primary key default public.uuid_generate_v7(),
  campania_colportor_id  uuid not null references public.campania_colportor(id) on delete cascade,
  zona_id                uuid not null references public.zona(id),
  desde                  timestamptz not null,
  hasta                  timestamptz,
  cerrada_por            uuid references public.usuario(id) on delete set null,
  inicial                boolean not null default false,
  created_at             timestamptz not null default now(),
  updated_at             timestamptz not null default now(),
  created_by             uuid references public.usuario(id) on delete set null,
  deleted_at             timestamptz,
  sync_version           bigint not null default 0,
  xmin_w                 xid8 not null default pg_current_xact_id(),
  constraint campania_colportor_zona_historial_orden check (hasta is null or hasta >= desde),
  constraint campania_colportor_zona_historial_cierre check (hasta is not null or cerrada_por is null)
);

-- A lo sumo un tramo abierto por inscripción (y de paso, el tramo vigente se busca por índice).
create unique index campania_colportor_zona_historial_abierto_uidx
  on public.campania_colportor_zona_historial (campania_colportor_id)
  where hasta is null;
-- El historial de una inscripción, en orden.
create index campania_colportor_zona_historial_inscripcion_idx
  on public.campania_colportor_zona_historial (campania_colportor_id, desde);
-- Quién pasó por una zona (y la FK a zona).
create index campania_colportor_zona_historial_zona_idx
  on public.campania_colportor_zona_historial (zona_id);

comment on table public.campania_colportor_zona_historial is
  'Historial de zonas de una inscripción, para auditoría (HU-CAM-006, decisión del 02/10): un tramo por '
  'zona con desde, hasta (null = vigente) y quién. Lo llena solo el trigger de campania_colportor al '
  'asignar, quitar o dar de baja la zona. Solo en la nube: no va al pull ni al push. Lo lee el ADMIN y el '
  'coordinador de la campaña.';
comment on column public.campania_colportor_zona_historial.campania_colportor_id is
  'La inscripción (campania_colportor) a la que pertenece el tramo.';
comment on column public.campania_colportor_zona_historial.zona_id is
  'La zona de este tramo.';
comment on column public.campania_colportor_zona_historial.desde is
  'Cuándo empezó el tramo (hora real del cambio). En un tramo inicial es la fecha de la migración 0022, '
  'no la de la asignación, que no se puede reconstruir.';
comment on column public.campania_colportor_zona_historial.hasta is
  'Cuándo terminó el tramo (otra zona, «Quitar» o baja de la zona); null mientras sigue vigente. Cierra '
  'donde abre el siguiente.';
comment on column public.campania_colportor_zona_historial.cerrada_por is
  'Quién hizo el cambio que cerró el tramo; null si sigue abierto o si lo hizo un proceso del servidor.';
comment on column public.campania_colportor_zona_historial.inicial is
  'true en los tramos que ya existían al activar el historial (0022): su desde es una cota, no la fecha '
  'real de la asignación.';
comment on column public.campania_colportor_zona_historial.created_by is
  'Quién asignó la zona (abrió el tramo); null si fue un proceso del servidor o un tramo inicial.';

create trigger campania_colportor_zona_historial_auditoria_insert
  before insert on public.campania_colportor_zona_historial
  for each row execute function public.tg_auditoria_insert();
create trigger campania_colportor_zona_historial_auditoria_update
  before update on public.campania_colportor_zona_historial
  for each row execute function public.tg_auditoria_update();
alter table public.campania_colportor_zona_historial enable row level security;

-- ----------------------------------------------------------------------------
-- 2. Quién lo lee: el ADMIN y el coordinador de la campaña
-- ----------------------------------------------------------------------------

-- Misma forma que precio_por_zona (0008): el ADMIN, o el COORDINADOR de la campaña de la
-- inscripción. Las llamadas van envueltas en (select ...): un InitPlan en vez de una por fila
-- (el test de 0002 lo verifica).
create policy campania_colportor_zona_historial_select on public.campania_colportor_zona_historial
  for select to authenticated
  using (
    (select public.tiene_rol('ADMIN'))
    or ((select public.tiene_rol('COORDINADOR')) and exists (
          select 1 from public.campania_colportor cc
            join public.campania c on c.id = cc.campania_id
           where cc.id = campania_colportor_zona_historial.campania_colportor_id
             and c.coordinador_id = (select auth.uid())))
  );

-- Sin políticas de escritura y sin el privilegio: un INSERT/UPDATE directo falla con 42501.
-- Escribe el trigger de abajo (SECURITY DEFINER) y los procesos del servidor. Los grants van
-- explícitos, como en 0008: los default privileges de `public` dependen de cómo se creó el schema.
revoke all on public.campania_colportor_zona_historial from anon, authenticated;
grant select on public.campania_colportor_zona_historial to authenticated;
grant all on public.campania_colportor_zona_historial to service_role;

-- ----------------------------------------------------------------------------
-- 3. El trigger: asignar, cambiar, quitar y dar de baja la zona
-- ----------------------------------------------------------------------------

create function public.tg_campania_colportor_historial_de_zona()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  -- Hora real y no now(): ver la cabecera. Una sola para cerrar y abrir, así no hay hueco.
  v_ahora timestamptz := clock_timestamp();
  v_quien uuid := auth.uid();
begin
  if tg_op = 'UPDATE' then
    -- greatest(): un reloj que retrocede (un ajuste de hora del servidor) no puede dejar un tramo
    -- con hasta < desde, que el CHECK rechazaría y tumbaría el cambio de zona.
    update public.campania_colportor_zona_historial h
       set hasta = greatest(v_ahora, h.desde),
           cerrada_por = v_quien
     where h.campania_colportor_id = new.id
       and h.hasta is null;
  end if;

  if new.zona_id is not null then
    insert into public.campania_colportor_zona_historial (campania_colportor_id, zona_id, desde, created_by)
    values (new.id, new.zona_id, v_ahora, v_quien);
  end if;

  return null;
end;
$$;

comment on function public.tg_campania_colportor_historial_de_zona() is
  'AFTER INSERT/UPDATE OF zona_id de campania_colportor (0022, decisión del 02/10): cierra el tramo '
  'abierto y abre el de la zona nueva en campania_colportor_zona_historial. Quién = auth.uid().';

-- WHEN: solo cuando hay algo que registrar. Dos triggers porque OLD no existe en el INSERT.
create trigger campania_colportor_historial_de_zona_insert
  after insert on public.campania_colportor
  for each row when (new.zona_id is not null)
  execute function public.tg_campania_colportor_historial_de_zona();
create trigger campania_colportor_historial_de_zona_update
  after update of zona_id on public.campania_colportor
  for each row when (old.zona_id is distinct from new.zona_id)
  execute function public.tg_campania_colportor_historial_de_zona();

-- `authenticated` también en el revoke: en una base creada desde cero los default privileges de la
-- imagen le dan EXECUTE sobre cada función nueva de public (ver 0008).
revoke all on function public.tg_campania_colportor_historial_de_zona()
  from public, anon, authenticated;

-- ----------------------------------------------------------------------------
-- 4. El tramo inicial de cada inscripción que hoy tiene zona
-- ----------------------------------------------------------------------------

-- No se puede reconstruir el pasado: arranca con la zona vigente de cada inscripción (esquema-datos.md).
-- También las dadas de baja: conservan su zona y el historial sigue a zona_id (ver la cabecera). El
-- desde es el de esta migración y va marcado (inicial): no se inventa la fecha de la asignación.
-- Corre como el dueño de la migración, sin JWT: nadie la «asignó» (created_by null).
insert into public.campania_colportor_zona_historial (campania_colportor_id, zona_id, desde, inicial)
select cc.id, cc.zona_id, now(), true
  from public.campania_colportor cc
 where cc.zona_id is not null;
