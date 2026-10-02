-- ============================================================================
-- 0022 · Historial de zonas: la zona de cada inscripción, desde cuándo, hasta cuándo y quién
--        (backend-supabase#57, decisión de Cristian del 02/10)
--
-- Decisión de Cristian del 02/10 (front-colportores-mobile#244, comentario 5952408648; idéntica
-- en backend-supabase#32, comentario 5952409871 y #48, comentario 5952409154): «Modelo de zonas:
-- una zona actual en la inscripción, como hoy, más un historial (desde, hasta, quién la asignó)
-- que se llena solo al asignar, quitar o dar de baja. Sirve para auditoría; no cambia la app ni
-- la vista 24.» Y, también de Cristian (02/10, pendiente del PR #60): sacar al colportor de la
-- campaña (dar de baja su inscripción) lo deja sin zona, con el tramo cerrado (quién y cuándo), y
-- cuando vuelve aparece en «Sin zona», igual que con «Quitar» o «Eliminar zona». El esquema (esquema-datos.md, campania_colportor) y HU-CAM-006 («Historial de
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
--     baja_zona() (los asignados quedan sin zona), la baja de la inscripción (más abajo) y
--     cualquier UPDATE del servidor.
--   · Asignar la zona que ya tiene, quitarle la zona a quien no tiene, o cambiar otra columna
--     (meta_libros) no cambian el valor de zona_id: no escriben nada. Un rechazo (CZ0xx, 42501)
--     tampoco: pasa antes del UPDATE.
-- Es del trigger y no de cada RPC para que valga para todo camino de escritura, también los futuros
-- (reactivar una inscripción, reasignar). Corre en la misma transacción que el cambio: o quedan los
-- dos o ninguno. Los RPC ya toman la inscripción FOR UPDATE, así que dos cambios de la misma
-- inscripción se serializan y el historial no se cruza; el historial solo se toca con la
-- inscripción tomada, por lo que no agrega ningún orden de locks nuevo.
-- «Quién» es auth.uid(): adentro de los RPC (SECURITY DEFINER) el JWT sigue presente.
--
-- ## Dar de baja la inscripción: queda sin zona (decisión de Cristian del 02/10)
--
-- campania_colportor_zona_sale_con_la_baja (BEFORE UPDATE, WHEN deleted_at pasa de null a un valor
-- y la inscripción tenía zona): pone zona_id = null en la misma fila. El resto es lo de arriba: el
-- trigger del historial (que ahora también mira deleted_at, porque un UPDATE que solo toca esa
-- columna no dispara un `UPDATE OF zona_id`) cierra el tramo con quién y cuándo. Cuando la
-- inscripción se reactiva vuelve sin zona: aparece en «Sin zona» y se le asigna una con
-- asignar_zona(), que abre un tramo nuevo. Resuelve de paso que el tramo de una inscripción
-- cerrada (HU-CAM-005: reasignar es cerrar y abrir otra) quede abierto para siempre.
-- Orden de los BEFORE (alfabético, como en 0009): corre DESPUÉS de campania_colportor_zona_por_rpc
-- (0006), que rechaza que un JWT cambie zona_id fuera de asignar_zona(); la baja del coordinador
-- por UPDATE directo sigue pasando porque ese trigger ya miró antes de que cambie.
--
-- ## Lo que NO hace
--
--   · No baja al teléfono: no está en sync.entidad, no va por el pull ni por el push, y no cambia
--     la app ni la vista 24 (decisión del 02/10). Vive solo en la nube.
--   · No cambia lo que dice campania_colportor.zona_id ni lo que ve el colportor: mis_zonas(),
--     el mapa y el área del pull siguen leyendo la zona actual.
--   · No toca las inscripciones que YA estaban dadas de baja con zona (0012: la conservaban): siguen
--     con su zona y su tramo abierto, y al reactivarlas la conservan si sigue viva (0009). Si hay
--     que dejarlas sin zona como las nuevas es una limpieza aparte, pendiente de Cristian (en el PR).
--
-- ## Quién lo lee
--
-- El ADMIN y el coordinador de la campaña de esa inscripción (campania.coordinador_id), por
-- PostgREST. El colportor no lo ve, ni el suyo. Nadie escribe directo: authenticated y anon no
-- tienen el privilegio de escritura (solo el trigger, que es SECURITY DEFINER, y service_role).
-- Una baja es lógica (deleted_at), como en el resto del esquema; el historial no se borra nunca:
-- solo desaparece con la inscripción si se elimina a la persona (ON DELETE CASCADE de la
-- inscripción, que ya cae con el usuario). Si se elimina al usuario que asignó o cerró un tramo,
-- created_by y cerrada_por quedan en null (ON DELETE SET NULL): ver el trigger ..._sin_usuario.
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
-- baja, que hasta hoy conservaban la suya); no se toca ninguna fila existente.
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
  'asignar, quitar o dar de baja la zona, o dar de baja la inscripción. Solo en la nube: no va al pull ni al push. Lo lee el ADMIN y el '
  'coordinador de la campaña.';
comment on column public.campania_colportor_zona_historial.campania_colportor_id is
  'La inscripción (campania_colportor) a la que pertenece el tramo.';
comment on column public.campania_colportor_zona_historial.zona_id is
  'La zona de este tramo.';
comment on column public.campania_colportor_zona_historial.desde is
  'Cuándo empezó el tramo (hora real del cambio). En un tramo inicial es la fecha de la migración 0022, '
  'no la de la asignación, que no se puede reconstruir.';
comment on column public.campania_colportor_zona_historial.hasta is
  'Cuándo terminó el tramo (otra zona, «Quitar», baja de la zona o baja de la inscripción); null mientras '
  'sigue vigente. Cierra donde abre el siguiente.';
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

-- Al borrar un usuario que asignó o cerró un tramo, sus dos FK (created_by y cerrada_por) son
-- ON DELETE SET NULL. tg_auditoria_update (BEFORE UPDATE) fuerza new.created_by := old.created_by
-- (la columna es inmutable), así que el SET NULL de created_by no hace nada y deja el uuid colgando;
-- y como el SET NULL de cerrada_por actualiza una versión de la fila que escribió esta misma
-- transacción, Postgres vuelve a chequear todas las FK de esa fila y la de created_by falla (23503):
-- no se podía borrar un coordinador o ADMIN que asignó una zona y después la cambió o la quitó.
-- Este BEFORE UPDATE corre después del de auditoría (los BEFORE corren por orden alfabético) y suelta
-- created_by cuando el usuario ya no existe, que es lo que pidió el ON DELETE SET NULL. Solo lo
-- toca el borrado de un usuario: nadie más actualiza esta tabla. SECURITY DEFINER para leer
-- `usuario` sin depender de la RLS de quien dispara el borrado.
-- (Que tg_auditoria_update anule el ON DELETE SET NULL de created_by en todas las tablas es una deuda
-- anterior a esta migración, y no se toca acá: issue aparte.)
create function public.tg_campania_colportor_zona_historial_sin_usuario()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.created_by is not null
     and not exists (select 1 from public.usuario u where u.id = new.created_by) then
    new.created_by := null;
  end if;
  return new;
end;
$$;

comment on function public.tg_campania_colportor_zona_historial_sin_usuario() is
  'BEFORE UPDATE de campania_colportor_zona_historial (0022): suelta created_by cuando el usuario ya no '
  'existe, porque tg_auditoria_update deshace el ON DELETE SET NULL y el borrado del usuario fallaba.';

create trigger campania_colportor_zona_historial_sin_usuario
  before update on public.campania_colportor_zona_historial
  for each row execute function public.tg_campania_colportor_zona_historial_sin_usuario();

revoke all on function public.tg_campania_colportor_zona_historial_sin_usuario()
  from public, anon, authenticated;

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
  v_desde timestamptz;
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
    -- El tramo nuevo no empieza antes de que termine el anterior, aunque el reloj haya retrocedido:
    -- sin hueco ni superposición (greatest ignora el null de una inscripción sin tramos).
    select greatest(v_ahora, max(h.hasta)) into v_desde
      from public.campania_colportor_zona_historial h
     where h.campania_colportor_id = new.id;
    insert into public.campania_colportor_zona_historial (campania_colportor_id, zona_id, desde, created_by)
    values (new.id, new.zona_id, v_desde, v_quien);
  end if;

  return null;
end;
$$;

comment on function public.tg_campania_colportor_historial_de_zona() is
  'AFTER INSERT/UPDATE OF zona_id, deleted_at de campania_colportor (0022, decisión del 02/10): cierra el '
  'tramo abierto y abre el de la zona nueva en campania_colportor_zona_historial. Quién = auth.uid().';

-- WHEN: solo cuando hay algo que registrar. Dos triggers porque OLD no existe en el INSERT.
create trigger campania_colportor_historial_de_zona_insert
  after insert on public.campania_colportor
  for each row when (new.zona_id is not null)
  execute function public.tg_campania_colportor_historial_de_zona();
-- También mira deleted_at: un UPDATE que solo pone deleted_at (la baja de la inscripción) cambia
-- zona_id desde el BEFORE de abajo, y un `UPDATE OF zona_id` no cuenta lo que cambie un trigger.
create trigger campania_colportor_historial_de_zona_update
  after update of zona_id, deleted_at on public.campania_colportor
  for each row when (old.zona_id is distinct from new.zona_id)
  execute function public.tg_campania_colportor_historial_de_zona();

-- Dar de baja la inscripción la deja sin zona. El nombre ordena después de
-- campania_colportor_zona_por_rpc (0006) y antes de campania_colportor_zona_valida (0009): los
-- BEFORE corren por orden alfabético y el primero solo deja pasar el cambio de zona_id que hace
-- asignar_zona(); si este corriera antes, una baja del coordinador por UPDATE directo daría 23514.
create function public.tg_campania_colportor_baja_sin_zona()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.zona_id := null;
  return new;
end;
$$;

comment on function public.tg_campania_colportor_baja_sin_zona() is
  'BEFORE UPDATE de campania_colportor (0022, decisión del 02/10): al dar de baja la inscripción (deleted_at '
  'pasa de null a un valor) queda sin zona. El historial cierra el tramo; al reactivarla vuelve sin zona.';

create trigger campania_colportor_zona_sale_con_la_baja
  before update on public.campania_colportor
  for each row when (old.deleted_at is null and new.deleted_at is not null and old.zona_id is not null)
  execute function public.tg_campania_colportor_baja_sin_zona();

-- `authenticated` también en el revoke: en una base creada desde cero los default privileges de la
-- imagen le dan EXECUTE sobre cada función nueva de public (ver 0008).
revoke all on function public.tg_campania_colportor_historial_de_zona(),
                       public.tg_campania_colportor_baja_sin_zona()
  from public, anon, authenticated;

-- ----------------------------------------------------------------------------
-- 4. El tramo inicial de cada inscripción que hoy tiene zona
-- ----------------------------------------------------------------------------

-- No se puede reconstruir el pasado: arranca con la zona vigente de cada inscripción (esquema-datos.md).
-- También las dadas de baja antes de esta migración: conservan su zona y el historial sigue a zona_id
-- (ver la cabecera). Desde ahora, dar de baja una inscripción la deja sin zona. El
-- desde es el de esta migración y va marcado (inicial): no se inventa la fecha de la asignación.
-- Corre como el dueño de la migración, sin JWT: nadie la «asignó» (created_by null).
insert into public.campania_colportor_zona_historial (campania_colportor_id, zona_id, desde, inicial)
select cc.id, cc.zona_id, now(), true
  from public.campania_colportor cc
 where cc.zona_id is not null;
