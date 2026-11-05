-- ============================================================================
-- 0176 · Varios acompañantes por jornada: la tabla que junta la jornada y sus acompañantes
--        (backend-supabase#254, casilla «Dos acomp.»; decisión de Cristian del 05/11 en docs-organizacion#76: «puede haber
--        varios acompañantes en la misma jornada»)
--
-- ## El caso
--
-- Ana sale a trabajar y la acompañan Luis y Daniel. Hasta hoy la jornada guarda UN acompañante
-- (`jornada.acompaniante_id`) y, si hay otro, el coordinador no puede anotarlo (`JO003`: «ya figura acompañada por otra
-- persona»). Cristian pidió que sean varios, sin perder el acompañante que ya está guardado.
--
-- ## Qué hace
--
--   1. `jornada_acompaniante`: una fila por (jornada, acompañante), con alta y baja lógica. Es entidad de sync **de
--      subida y de bajada propia** (como `visita_misionero`): el teléfono sube la lista fila por fila, y cada persona solo
--      ve las de sus jornadas. El servidor pone `colportor_id` (el dueño de la jornada) y `cargado_por` (quién la anotó
--      desde el panel); el push los descarta. Un único vigente por (jornada, persona).
--   2. Los acompañantes que ya estaban (`jornada.acompaniante_id`) pasan a la tabla, con quien los cargó
--      (`acompaniamiento_cargado_por`). No se pierde ninguno.
--   3. `jornada_acompaniamiento` (el origen y la nota, internos de coordinación) pasa a ser **una fila por acompañante**:
--      suma `acompaniante_id` y su único pasa a (jornada, acompañante). La nota de cada acompañamiento queda con su persona.
--   4. `jornada.acompaniante_id` y `acompaniamiento_cargado_por` **se conservan** como «el primer acompañante vigente»
--      (el más antiguo) y quien lo cargó: así las horas por ciudad (`jornadas_acompaniadas`) y todo lo que ya las lee
--      cuentan **una jornada acompañada una sola vez, aunque tenga varios acompañantes**. La tabla es la fuente; la columna
--      la mantiene un trigger **sin subir la versión de la jornada** (republicado, como 0011), para no hacer que la
--      jornada que el teléfono todavía va a subir dé `conflict`.
--   5. **Compatibilidad con el teléfono de antes**: si un teléfono que no conoce la tabla sube `jornada.acompaniante_id`,
--      un trigger lo anota en la tabla (suma al nuevo y, si cambió, da de baja al anterior, que era el reemplazo de antes).
--
-- ## El servidor no controla al acompañante
--
-- Decisión de Cristian (05/11, «Valida acomp»): «no controla; desde el celular elige solo los de la campaña, en el
-- dashboard aparecen todos los coordinadores». El push acepta **cualquier cuenta existente** como acompañante (la FK a
-- `usuario`), de cualquier campaña, también un coordinador o un administrador, sin `JO005`. El control de «quién puede
-- anotarse desde el panel» sigue en `agregar_acompaniamiento()` (0177).
--
-- ## Lo que NO hace
--
--   · No cambia las lecturas del panel: eso es la 0177.
--   · No toca `jornada` por esta migración: ninguna jornada cambia de `sync_version`.
--
-- ## Los datos
--
-- Se agregan filas a `jornada_acompaniante` (una por jornada con acompañante, incluidas las de baja) y se llena
-- `jornada_acompaniamiento.acompaniante_id`. Una fila de origen/nota sin acompañante (que no debería existir: sin
-- acompañante no hay origen ni nota) se descarta. Lo prueba supabase/tests_migracion/0176_ok. Forward-only.
--
-- ## Para otros repos
--
--   · front-colportores-mobile#671 (y #146): subir cada acompañante como una fila de `jornada_acompaniante`
--     (`{id, jornada_id, acompaniante_id}`); la lista del teléfono sale de la 0178.
--   · front-coordinadores-web#144: el registro del panel (0177) y la lista de todos los coordinadores.
--   · docs-organizacion#172: contrato del sync (entidad nueva `jornada_acompaniante`) y `esquema-datos.md`.
--
-- Forward-only: esta migración no se edita una vez aplicada.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. La tabla
-- ----------------------------------------------------------------------------

create table public.jornada_acompaniante (
  id              uuid primary key default public.uuid_generate_v7(),
  jornada_id      uuid not null references public.jornada(id) on delete cascade,
  colportor_id    uuid not null default auth.uid() references public.usuario(id),
  acompaniante_id uuid not null references public.usuario(id) on delete cascade,
  cargado_por     uuid references public.usuario(id) on delete set null,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  created_by      uuid default auth.uid() references public.usuario(id) on delete set null,
  deleted_at      timestamptz,
  sync_version    bigint not null default 0,
  xmin_w          xid8 not null default pg_current_xact_id()
);

comment on table public.jornada_acompaniante is
  'Quién acompañó cada jornada (0176, backend-supabase#254, «Dos acomp.»): una fila por (jornada, acompañante) con alta y '
  'baja lógica. Una jornada puede tener varios. La sube el teléfono (entidad de sync) o la anota el coordinador desde el '
  'panel (agregar_acompaniamiento). El servidor pone colportor_id (dueño de la jornada) y cargado_por. Un acompañante '
  'puede ser cualquier cuenta existente (el servidor no controla al que sube el teléfono). La nota y el origen de cada '
  'uno viven en jornada_acompaniamiento (interna).';
comment on column public.jornada_acompaniante.colportor_id is
  'El dueño de la jornada. Lo pone el servidor (el push lo descarta): cada persona solo ve las filas de sus jornadas.';
comment on column public.jornada_acompaniante.acompaniante_id is
  'La persona que acompañó (una cuenta cualquiera: colportor, coordinador o administrador). No cambia en una fila: se da '
  'de baja y se suma otra.';
comment on column public.jornada_acompaniante.cargado_por is
  'Quién anotó este acompañamiento desde el panel (el coordinador de la campaña o un ADMIN): lo pone '
  'agregar_acompaniamiento() con auth.uid(). null si lo marcó el colportor en el teléfono o es anterior a la 0116 (no se '
  'sabe). El colportor lo puede leer (decisión del 28/10, «Quién cargó»).';

-- Un acompañante vigente por jornada y persona; la baja deja la historia y se puede volver a sumar.
create unique index jornada_acompaniante_vigente_uidx
  on public.jornada_acompaniante (jornada_id, acompaniante_id) where deleted_at is null;
-- El cursor del pull por dueño (colportor_id, xmin_w, id), como las demás entidades propias.
create index jornada_acompaniante_delta_idx on public.jornada_acompaniante (colportor_id, xmin_w, id);
create index jornada_acompaniante_acompaniante_idx on public.jornada_acompaniante (acompaniante_id);

create trigger jornada_acompaniante_auditoria_insert
  before insert on public.jornada_acompaniante
  for each row execute function public.tg_auditoria_insert();
create trigger jornada_acompaniante_auditoria_update
  before update on public.jornada_acompaniante
  for each row execute function public.tg_auditoria_update();

-- ----------------------------------------------------------------------------
-- 2. Lo que decide el servidor
-- ----------------------------------------------------------------------------

-- El dueño sale de la jornada; quién la cargó lo pone el servidor; la identidad de la fila no cambia.
create function public.tg_jornada_acompaniante_del_servidor()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_duenio uuid;
begin
  if tg_op = 'INSERT' then
    -- Siempre el dueño de la jornada (la RLS compara después con auth.uid()). Si la jornada no existe, que lo diga la FK.
    select j.colportor_id into v_duenio from public.jornada j where j.id = new.jornada_id;
    if found then
      new.colportor_id := v_duenio;
    end if;
    if current_user in ('authenticated', 'anon') then
      new.cargado_por := null;
      -- Lo sube el teléfono: la columna de la jornada se recalcula sin subir su versión (ver el AFTER).
      perform set_config('colportores.acompaniante_del_telefono', 'on', true);
    end if;
  else
    if new.jornada_id is distinct from old.jornada_id
       or new.acompaniante_id is distinct from old.acompaniante_id
       or new.colportor_id is distinct from old.colportor_id then
      raise exception 'A un acompañamiento no se le cambia la jornada ni la persona. Dalo de baja y sumá a quien corresponda.'
        using errcode = '23514';
    end if;
    if current_user in ('authenticated', 'anon') then
      new.cargado_por := old.cargado_por;
      perform set_config('colportores.acompaniante_del_telefono', 'on', true);
    end if;
  end if;
  return new;
end;
$$;

comment on function public.tg_jornada_acompaniante_del_servidor() is
  'BEFORE INSERT o UPDATE de jornada_acompaniante (0176): colportor_id es siempre el dueño de la jornada; el teléfono no '
  'elige cargado_por; a una fila no se le cambia la jornada, la persona ni el dueño (23514).';

revoke all on function public.tg_jornada_acompaniante_del_servidor() from public, anon, authenticated, service_role;

create trigger jornada_acompaniante_del_servidor
  before insert or update on public.jornada_acompaniante
  for each row execute function public.tg_jornada_acompaniante_del_servidor();

-- ----------------------------------------------------------------------------
-- 3. RLS y privilegios: cada persona lo de sus jornadas, como visita_misionero
-- ----------------------------------------------------------------------------

alter table public.jornada_acompaniante enable row level security;

revoke all on public.jornada_acompaniante from anon, authenticated;
grant select, insert, update on public.jornada_acompaniante to authenticated;
grant all on public.jornada_acompaniante to service_role;

create policy jornada_acompaniante_select_propia on public.jornada_acompaniante
  for select to authenticated
  using (colportor_id = (select auth.uid()));

create policy jornada_acompaniante_insert_propia on public.jornada_acompaniante
  for insert to authenticated
  with check (
    colportor_id = (select auth.uid())
    and exists (select 1 from public.jornada j
                 where j.id = jornada_acompaniante.jornada_id and j.colportor_id = (select auth.uid())));

create policy jornada_acompaniante_update_propia on public.jornada_acompaniante
  for update to authenticated
  using (colportor_id = (select auth.uid()))
  with check (
    colportor_id = (select auth.uid())
    and exists (select 1 from public.jornada j
                 where j.id = jornada_acompaniante.jornada_id and j.colportor_id = (select auth.uid())));

-- ----------------------------------------------------------------------------
-- 4. Entidad de sync
-- ----------------------------------------------------------------------------

insert into sync.entidad (nombre, tabla, permite_push, columnas_servidor, columna_duenio)
values ('jornada_acompaniante', 'public.jornada_acompaniante', true,
        array['sync_version', 'updated_at', 'created_by', 'xmin_w', 'colportor_id', 'cargado_por'],
        'colportor_id');

-- ----------------------------------------------------------------------------
-- 5. El origen y la nota: una fila por acompañante
-- ----------------------------------------------------------------------------

-- Es interna del servidor y no baja al teléfono: no hace falta cuidar sync_version.
alter table public.jornada_acompaniamiento
  add column acompaniante_id uuid references public.usuario(id) on delete cascade;

alter table public.jornada_acompaniamiento disable trigger jornada_acompaniamiento_auditoria_update;
update public.jornada_acompaniamiento d
   set acompaniante_id = j.acompaniante_id
  from public.jornada j
 where j.id = d.jornada_id;
alter table public.jornada_acompaniamiento enable trigger jornada_acompaniamiento_auditoria_update;

-- Sin acompañante no hay origen ni nota (el trigger de antes ya las borraba): lo que quedara sin persona se descarta.
delete from public.jornada_acompaniamiento where acompaniante_id is null;

alter table public.jornada_acompaniamiento alter column acompaniante_id set not null;
alter table public.jornada_acompaniamiento drop constraint jornada_acompaniamiento_jornada_key;
alter table public.jornada_acompaniamiento
  add constraint jornada_acompaniamiento_jornada_acompaniante_key unique (jornada_id, acompaniante_id);

comment on column public.jornada_acompaniamiento.acompaniante_id is
  'De qué acompañante de la jornada son este origen y esta nota (0176): una fila por (jornada, acompañante).';

-- ----------------------------------------------------------------------------
-- 6. Los acompañantes que ya estaban pasan a la tabla
-- ----------------------------------------------------------------------------

insert into public.jornada_acompaniante (jornada_id, colportor_id, acompaniante_id, cargado_por, created_at, deleted_at)
select j.id, j.colportor_id, j.acompaniante_id, j.acompaniamiento_cargado_por, j.created_at, j.deleted_at
  from public.jornada j
 where j.acompaniante_id is not null;

-- ----------------------------------------------------------------------------
-- 7. La columna de la jornada queda como el primer acompañante vigente
-- ----------------------------------------------------------------------------

-- Recalcula jornada.acompaniante_id y acompaniamiento_cargado_por desde la tabla, sin subir la versión de la jornada.
create function public.refrescar_acompaniante_de_la_jornada(p_jornada_id uuid, p_republicar boolean)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_acomp   uuid;
  v_cargado uuid;
  v_antes   text := current_setting('colportores.republicar', true);
begin
  select a.acompaniante_id, a.cargado_por into v_acomp, v_cargado
    from public.jornada_acompaniante a
   where a.jornada_id = p_jornada_id and a.deleted_at is null
   order by a.created_at, a.id
   limit 1;

  if exists (select 1 from public.jornada j
              where j.id = p_jornada_id
                and (j.acompaniante_id, j.acompaniamiento_cargado_por) is distinct from (v_acomp, v_cargado)) then
    -- Si lo cambió el propio teléfono (o el servidor al acomodar lo que subió el de antes), se republica (0011): sube
    -- xmin_w pero no la versión, para no invalidar el push que el teléfono tenga pendiente. Si lo anotó el panel, la
    -- versión sube: un push viejo de esa jornada da `conflict` y gana el servidor (como siempre), así no borra el
    -- acompañante que el coordinador acaba de anotar.
    perform set_config('colportores.acompaniante_espejo', 'on', true);
    if p_republicar then
      perform set_config('colportores.republicar', 'on', true);
    end if;
    update public.jornada j
       set acompaniante_id = v_acomp,
           acompaniamiento_cargado_por = v_cargado
     where j.id = p_jornada_id;
    perform set_config('colportores.republicar', coalesce(v_antes, 'off'), true);
    perform set_config('colportores.acompaniante_espejo', 'off', true);
  end if;
end;
$$;

comment on function public.refrescar_acompaniante_de_la_jornada(uuid, boolean) is
  'Deja jornada.acompaniante_id y acompaniamiento_cargado_por en el primer acompañante vigente de jornada_acompaniante '
  '(el más antiguo) y en quien lo cargó, o en null si no queda ninguno (0176). Con p_republicar no sube la versión de la '
  'jornada (lo cambió el teléfono); sin él sí (lo anotó el panel). La llaman los triggers. Interna.';

revoke all on function public.refrescar_acompaniante_de_la_jornada(uuid, boolean) from public, anon, authenticated, service_role;

-- La tabla cambió: el origen y la nota de ese acompañante, y la columna de la jornada.
create function public.tg_jornada_acompaniante_detalle_y_espejo()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.deleted_at is null then
    -- El teléfono (o el servidor) la anotó: origen COLPORTOR y sin nota. agregar_acompaniamiento() lo pasa a COORDINADOR.
    insert into public.jornada_acompaniamiento (jornada_id, acompaniante_id, origen, nota)
    values (new.jornada_id, new.acompaniante_id, 'COLPORTOR', null)
    on conflict on constraint jornada_acompaniamiento_jornada_acompaniante_key do update
      set origen = 'COLPORTOR', nota = null, deleted_at = null;
  else
    -- Sin acompañante no hay origen ni nota.
    delete from public.jornada_acompaniamiento d
     where d.jornada_id = new.jornada_id and d.acompaniante_id = new.acompaniante_id;
  end if;

  -- Lo que escribe el trigger de la jornada (el teléfono de antes) recalcula la columna al final.
  if current_setting('colportores.acompaniante_columna', true) is distinct from 'on' then
    perform public.refrescar_acompaniante_de_la_jornada(
      new.jornada_id, current_setting('colportores.acompaniante_del_telefono', true) = 'on');
  end if;
  perform set_config('colportores.acompaniante_del_telefono', 'off', true);
  return null;
end;
$$;

comment on function public.tg_jornada_acompaniante_detalle_y_espejo() is
  'AFTER INSERT o UPDATE de deleted_at en jornada_acompaniante (0176): crea (o borra, si se dio de baja) el origen y la '
  'nota de ese acompañante y recalcula jornada.acompaniante_id. Origen COLPORTOR y sin nota: lo pone el panel después.';

revoke all on function public.tg_jornada_acompaniante_detalle_y_espejo() from public, anon, authenticated, service_role;

create trigger jornada_acompaniante_detalle_y_espejo_insert
  after insert on public.jornada_acompaniante
  for each row execute function public.tg_jornada_acompaniante_detalle_y_espejo();
create trigger jornada_acompaniante_detalle_y_espejo_update
  after update of deleted_at on public.jornada_acompaniante
  for each row
  when (old.deleted_at is distinct from new.deleted_at)
  execute function public.tg_jornada_acompaniante_detalle_y_espejo();

-- El teléfono de antes: sube jornada.acompaniante_id. El trigger de la jornada (que antes creaba el origen) lo anota en
-- la tabla; si el acompañante cambia, el de antes se da de baja (el reemplazo de antes) y si queda en null, también.
create or replace function public.tg_jornada_acompaniamiento_detalle()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  -- Lo que escribe el recalculo de la columna no vuelve a la tabla.
  if current_setting('colportores.acompaniante_espejo', true) = 'on' then
    return null;
  end if;

  perform set_config('colportores.acompaniante_columna', 'on', true);

  if tg_op = 'UPDATE' and old.acompaniante_id is not null and old.acompaniante_id is distinct from new.acompaniante_id then
    update public.jornada_acompaniante a
       set deleted_at = now()
     where a.jornada_id = new.id and a.acompaniante_id = old.acompaniante_id and a.deleted_at is null;
  end if;

  if new.acompaniante_id is not null
     and not exists (select 1 from public.jornada_acompaniante a
                      where a.jornada_id = new.id and a.acompaniante_id = new.acompaniante_id and a.deleted_at is null) then
    insert into public.jornada_acompaniante (jornada_id, colportor_id, acompaniante_id, cargado_por, created_at)
    values (new.id, new.colportor_id, new.acompaniante_id, new.acompaniamiento_cargado_por, clock_timestamp());
  end if;

  perform set_config('colportores.acompaniante_columna', 'off', true);
  -- La columna vuelve a ser el primero que quede en la tabla (con un solo acompañante, el que se escribió).
  perform public.refrescar_acompaniante_de_la_jornada(new.id, true);
  return null;
end;
$$;

comment on function public.tg_jornada_acompaniamiento_detalle() is
  'AFTER INSERT o UPDATE de jornada.acompaniante_id (0176; antes 0043/0100): el teléfono de antes marca un solo '
  'acompañante en la jornada y este trigger lo anota en jornada_acompaniante (con su origen COLPORTOR); si cambia o '
  'queda en null, da de baja al de antes. Después recalcula la columna desde la tabla.';
