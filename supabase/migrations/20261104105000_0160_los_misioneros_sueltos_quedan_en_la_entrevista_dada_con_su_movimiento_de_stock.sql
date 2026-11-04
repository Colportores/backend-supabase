-- ============================================================================
-- 0160 · Los misioneros sueltos quedan en la entrevista dada, con lo que dejó y su movimiento de stock
--        (backend-supabase#234, casilla «Talonario mis»; decisión de Cristian del 03/11 sobre
--        front-colportores-mobile#531: «los misioneros sueltos no crean una venta ni ocupan talonario»)
--
-- Ana deja dos ejemplares misioneros en una casa y no cobra nada: no es una venta, así que no pide talonario y no
-- crea `venta` ni `venta_item`. Lo que dejó queda colgado de la visita (la entrevista dada, `visita`), con la
-- cantidad de cada producto, y descuenta de su stock con un movimiento propio.
--
-- ## Qué hay
--
--   · `visita_misionero`: una fila por producto dejado en una visita (`visita_id`, `producto_id`, `cantidad`
--     mayor que 0), de la colportora dueña (`colportor_id`, lo fija el servidor desde el JWT). Un solo renglón vivo
--     por producto y visita (índice único parcial). Solo la dueña la lee y la escribe, y solo sobre una visita suya.
--     Sin datos del cliente ni texto libre.
--   · Solo productos de categoría MISIONEROS (0149): cualquier otro producto es 23514. Un libro común no se «deja»
--     sin venta.
--   · Entidad del push `visita_misionero` (push y pull de las propias, como `devolucion`); `colportor_id` se
--     descarta del payload.
--   · El stock: cada renglón vivo que entra descuenta su cantidad del stock de la colportora (que puede quedar en
--     negativo, S46) con un movimiento `SALIDA_MISIONERO` (`movimiento_stock.visita_misionero_id`) y deja el
--     evento `stock_descontado_por_misionero` en `audit_log`. Si el renglón se corrige a la baja, cambia de
--     producto o se da de baja, devuelve lo que había descontado, hasta lo que el historial dice
--     (`ENTRADA_MISIONERO_ANULADO`, evento `stock_devuelto_por_misionero`). Un reintento del push no vuelve a
--     descontar (el INSERT … ON CONFLICT DO NOTHING no dispara nada); un renglón que llega ya dado de baja no mueve
--     nada.
--   · `movimiento_stock.visita_misionero_id`: nuevo origen del movimiento (a lo sumo uno entre pedido,
--     transferencia, entrega, devolución y renglón de misioneros). Es columna del servidor: el teléfono no la manda
--     y el trigger del cliente la deja en null.
--
-- ## Los datos
--
-- Solo suma: una tabla nueva (vacía), una columna opcional, dos tipos de movimiento y una fila en `sync.entidad`.
-- Ninguna fila existente cambia (ni su `sync_version` ni su `xmin_w`).
--
-- ## Para otros repos
--   · front-colportores-mobile: la entidad `visita_misionero` (push y pull; `colportor_id` no se manda) y que una
--     entrevista con solo misioneros no crea venta; el movimiento nuevo baja en el pull de `movimiento_stock` con
--     `visita_misionero_id`. Un producto que no es misionero responde `invalid` 23514; una visita ajena o inexistente,
--     `invalid` 42501.
--   · docs-organizacion: HU-VEN-001, `esquema-datos.md` y `contrato-sync-engine.md` §2 (la entidad).
--
-- Forward-only: esta migración no se edita una vez aplicada.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. movimiento_stock: el origen «renglón de misioneros» y los dos tipos
-- ----------------------------------------------------------------------------

-- (La FK a visita_misionero se agrega después de crearla.)
alter table public.movimiento_stock
  add column visita_misionero_id uuid;

alter table public.movimiento_stock
  drop constraint movimiento_stock_tipo_check;
alter table public.movimiento_stock
  add constraint movimiento_stock_tipo_check
  check (tipo in ('ENTRADA_PEDIDO', 'SALIDA_ENTREGA', 'SALIDA_TRANSFERENCIA', 'ENTRADA_TRANSFERENCIA',
                  'ENTRADA_ENTREGA_ANULADA', 'ENTRADA_ENTREGA_CORREGIDA', 'ENTRADA_DEVOLUCION',
                  'SALIDA_DEVOLUCION_ANULADA', 'AJUSTE_ENTRADA', 'AJUSTE_SALIDA',
                  'SALIDA_MISIONERO', 'ENTRADA_MISIONERO_ANULADO'));

alter table public.movimiento_stock
  drop constraint movimiento_stock_un_origen_check;
alter table public.movimiento_stock
  add constraint movimiento_stock_un_origen_check
  check (num_nonnulls(pedido_id, transferencia_id, entrega_id, devolucion_id, visita_misionero_id) <= 1);

comment on column public.movimiento_stock.visita_misionero_id is
  'El renglón de misioneros dejados en una entrevista del que viene el movimiento (SALIDA_MISIONERO o '
  'ENTRADA_MISIONERO_ANULADO, 0160). Columna del servidor. Un movimiento viene de a lo sumo un pedido, una '
  'transferencia, una entrega, una devolución o un renglón de misioneros.';
comment on table public.movimiento_stock is
  'Histórico de cambios de stock del colportor (V2): entrada por pedido recibido, salida por entrega o por '
  'transferencia, las entradas de lo que se deshace (entrega anulada o corregida, libros devueltos), el ajuste que '
  'la colportora registra desde el teléfono (0148, con el motivo de una lista) y, desde 0160, los misioneros dejados '
  'en una entrevista sin venta (SALIDA_MISIONERO) y su vuelta si se corrige o se da de baja '
  '(ENTRADA_MISIONERO_ANULADO). La cantidad es siempre positiva y el tipo dice para qué lado va.';

-- ----------------------------------------------------------------------------
-- 2. La tabla
-- ----------------------------------------------------------------------------

create table public.visita_misionero (
  id            uuid primary key default public.uuid_generate_v7(),
  visita_id     uuid not null references public.visita(id),
  producto_id   uuid not null references public.producto(id),
  cantidad      integer not null,
  colportor_id  uuid not null default auth.uid() references public.usuario(id),
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  created_by    uuid default auth.uid() references public.usuario(id) on delete set null,
  deleted_at    timestamptz,
  sync_version  bigint not null default 0,
  xmin_w        xid8 not null default pg_current_xact_id(),
  constraint visita_misionero_cantidad_positiva check (cantidad >= 1)
);

comment on table public.visita_misionero is
  'Los misioneros sueltos que la colportora dejó en una entrevista dada, sin venta ni talonario (0160, '
  'backend-supabase#234, «Talonario mis»): un renglón por producto y visita, con su cantidad. Cada renglón vivo '
  'descuenta de su stock con un SALIDA_MISIONERO. Solo la dueña lo lee y lo escribe. Sin datos del cliente ni '
  'texto libre. Sube por push.';
comment on column public.visita_misionero.visita_id is 'La visita (entrevista dada) en la que se dejaron.';
comment on column public.visita_misionero.producto_id is 'El producto dejado: de categoría MISIONEROS (23514 si no).';
comment on column public.visita_misionero.cantidad is 'Cuántos ejemplares se dejaron (1 o más).';
comment on column public.visita_misionero.colportor_id is
  'La colportora dueña de la visita y del renglón. Lo fija el servidor desde el JWT; el payload no lo manda.';

create unique index visita_misionero_visita_producto_key
  on public.visita_misionero (visita_id, producto_id) where deleted_at is null;
create index visita_misionero_producto_idx on public.visita_misionero (producto_id);
create index visita_misionero_colportor_idx on public.visita_misionero (colportor_id);

-- El delta: el predicado de la RLS (colportor_id) primero, para que entre en el Index Cond (0002 §14).
create index visita_misionero_delta_idx on public.visita_misionero (colportor_id, xmin_w, id);

create trigger visita_misionero_auditoria_insert before insert on public.visita_misionero
  for each row execute function public.tg_auditoria_insert();
create trigger visita_misionero_auditoria_update before update on public.visita_misionero
  for each row execute function public.tg_auditoria_update();

alter table public.movimiento_stock
  add constraint movimiento_stock_visita_misionero_id_fkey
  foreign key (visita_misionero_id) references public.visita_misionero(id);

create index movimiento_stock_visita_misionero_idx on public.movimiento_stock (visita_misionero_id)
  where visita_misionero_id is not null;

-- ----------------------------------------------------------------------------
-- 3. Solo misioneros
-- ----------------------------------------------------------------------------

-- Corre como quien escribe (el catálogo lo lee todo autenticado). Un producto que no existe lo dice la FK (23503).
create function public.tg_visita_misionero_solo_misioneros()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_categoria text;
begin
  select p.categoria into v_categoria from public.producto p where p.id = new.producto_id;
  if found and v_categoria is distinct from 'MISIONEROS' then
    raise exception using
      errcode = '23514',
      message = 'Solo se pueden dejar sin venta los productos misioneros. Para los demás, registrá una venta.',
      constraint = 'visita_misionero_producto_misionero';
  end if;
  return new;
end;
$$;

comment on function public.tg_visita_misionero_solo_misioneros() is
  'BEFORE INSERT / UPDATE OF producto_id de visita_misionero (0160): el producto es de categoría MISIONEROS '
  '(23514 si no). Un producto inexistente lo rechaza la FK.';

revoke all on function public.tg_visita_misionero_solo_misioneros() from public, anon, authenticated, service_role;

create trigger visita_misionero_solo_misioneros
  before insert or update of producto_id on public.visita_misionero
  for each row execute function public.tg_visita_misionero_solo_misioneros();

-- ----------------------------------------------------------------------------
-- 4. RLS: solo la dueña, y sobre una visita suya
-- ----------------------------------------------------------------------------

alter table public.visita_misionero enable row level security;

create policy visita_misionero_select_propia on public.visita_misionero
  for select to authenticated
  using (colportor_id = (select auth.uid()));

create policy visita_misionero_insert_propia on public.visita_misionero
  for insert to authenticated
  with check (colportor_id = (select auth.uid())
              and exists (select 1 from public.visita vi
                           where vi.id = visita_id and vi.colportor_id = (select auth.uid())));

-- USING = lo que ve; WITH CHECK = lo que escribe (0021): no se pasa un renglón a una visita ajena.
create policy visita_misionero_update_propia on public.visita_misionero
  for update to authenticated
  using (colportor_id = (select auth.uid()))
  with check (colportor_id = (select auth.uid())
              and exists (select 1 from public.visita vi
                           where vi.id = visita_id and vi.colportor_id = (select auth.uid())));

-- Sin política de DELETE ni privilegio: una baja es `deleted_at`.
revoke all on public.visita_misionero from anon, authenticated;
grant select, insert, update on public.visita_misionero to authenticated;
grant all on public.visita_misionero to service_role;

-- ----------------------------------------------------------------------------
-- 5. El registro en el motor de sync
-- ----------------------------------------------------------------------------

insert into sync.entidad (nombre, tabla, columna_pk, permite_push, columna_duenio) values
  ('visita_misionero', 'public.visita_misionero'::regclass, 'id', true, 'colportor_id');

update sync.entidad
   set columnas_servidor = columnas_servidor || array['colportor_id']
 where nombre = 'visita_misionero';

-- El movimiento nuevo baja con su origen, y el teléfono no lo manda.
update sync.entidad
   set columnas_servidor = columnas_servidor || array['visita_misionero_id']
 where nombre = 'movimiento_stock'
   and not columnas_servidor @> array['visita_misionero_id'];

create or replace function public.tg_movimiento_stock_del_cliente()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if current_user not in ('authenticated', 'anon') then
    return new;
  end if;

  -- Lo que decide el servidor (también llega descartado del payload: columnas_servidor). Va antes que el
  -- reintento: la RLS de alta mira `usuario_id`, y la mira antes del ON CONFLICT.
  new.usuario_id := auth.uid();
  new.fecha := now();
  new.pedido_id := null;
  new.transferencia_id := null;
  new.entrega_id := null;
  new.devolucion_id := null;
  new.visita_misionero_id := null;

  if exists (select 1 from public.movimiento_stock m where m.id = new.id) then
    return new;
  end if;

  if new.tipo not in ('AJUSTE_ENTRADA', 'AJUSTE_SALIDA') then
    raise exception 'Desde el teléfono solo se registra un ajuste de tu stock. Los demás movimientos los hace el sistema.'
      using errcode = '42501';
  end if;
  return new;
end;
$$;

-- ----------------------------------------------------------------------------
-- 6. El stock
-- ----------------------------------------------------------------------------

-- Aplica un cambio de p_delta unidades dejadas de un producto en un renglón: positivo descuenta (SALIDA_MISIONERO),
-- negativo devuelve (ENTRADA_MISIONERO_ANULADO) con el tope de lo que el historial dice que ese renglón descontó.
-- Interna: la llama el trigger del renglón. DEFINER: el push corre INVOKER y no escribe stock ni movimientos.
create function public.mover_stock_de_misionero(p_renglon_id uuid, p_colportor_id uuid, p_producto_id uuid,
                                                p_delta integer, p_fecha timestamptz)
returns void
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_despues  integer;
  v_neto     bigint;
  v_cantidad integer;
begin
  if p_delta = 0 then
    return;
  end if;

  if p_delta > 0 then
    -- Una fila de stock dada de baja cuenta como cero (como en 0126).
    insert into public.stock as s (usuario_id, producto_id, cantidad_disponible)
    values (p_colportor_id, p_producto_id, -p_delta)
    on conflict (usuario_id, producto_id)
    do update set cantidad_disponible = case when s.deleted_at is null then s.cantidad_disponible else 0 end
                                        - p_delta,
                  deleted_at = null
    returning s.cantidad_disponible into v_despues;

    insert into public.movimiento_stock (usuario_id, producto_id, tipo, cantidad, fecha, visita_misionero_id)
    values (p_colportor_id, p_producto_id, 'SALIDA_MISIONERO', p_delta, coalesce(p_fecha, now()), p_renglon_id);

    perform auditoria.registrar(
      'stock_descontado_por_misionero', 'visita_misionero', p_renglon_id, p_colportor_id,
      jsonb_build_object('producto_id', p_producto_id,
                         'cantidad', p_delta,
                         'stock_antes', v_despues + p_delta,
                         'stock_despues', v_despues));
    return;
  end if;

  -- Devolver: hasta lo que este renglón descontó de este producto y todavía no devolvió.
  select coalesce(sum(case when m.tipo = 'SALIDA_MISIONERO' then m.cantidad else -m.cantidad end), 0)
    into v_neto
    from public.movimiento_stock m
   where m.visita_misionero_id = p_renglon_id
     and m.producto_id = p_producto_id
     and m.deleted_at is null
     and m.tipo in ('SALIDA_MISIONERO', 'ENTRADA_MISIONERO_ANULADO');

  v_cantidad := least(-p_delta, greatest(v_neto, 0))::integer;
  if v_cantidad <= 0 then
    return;
  end if;

  insert into public.stock as s (usuario_id, producto_id, cantidad_disponible)
  values (p_colportor_id, p_producto_id, v_cantidad)
  on conflict (usuario_id, producto_id)
  do update set cantidad_disponible = case when s.deleted_at is null then s.cantidad_disponible else 0 end
                                      + excluded.cantidad_disponible,
                deleted_at = null
  returning s.cantidad_disponible into v_despues;

  insert into public.movimiento_stock (usuario_id, producto_id, tipo, cantidad, fecha, visita_misionero_id)
  values (p_colportor_id, p_producto_id, 'ENTRADA_MISIONERO_ANULADO', v_cantidad, now(), p_renglon_id);

  perform auditoria.registrar(
    'stock_devuelto_por_misionero', 'visita_misionero', p_renglon_id, p_colportor_id,
    jsonb_build_object('producto_id', p_producto_id,
                       'cantidad', v_cantidad,
                       'stock_antes', v_despues - v_cantidad,
                       'stock_despues', v_despues));
end;
$$;

comment on function public.mover_stock_de_misionero(uuid, uuid, uuid, integer, timestamptz) is
  'Mueve el stock de una colportora por un cambio de p_delta unidades dejadas en un renglón de misioneros (0160, '
  '#234): positivo descuenta y deja SALIDA_MISIONERO; negativo devuelve, hasta lo que el historial dice que ese '
  'renglón descontó, y deja ENTRADA_MISIONERO_ANULADO. Los dos dejan su evento en audit_log (ids y números). '
  'Interna: la llama el trigger del renglón.';

revoke all on function public.mover_stock_de_misionero(uuid, uuid, uuid, integer, timestamptz)
  from public, anon, authenticated, service_role;

create function public.tg_visita_misionero_mueve_el_stock()
returns trigger
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_fecha  timestamptz;
  v_antes  integer := 0;
  v_ahora  integer;
begin
  select vi.fecha into v_fecha from public.visita vi where vi.id = new.visita_id;

  v_ahora := case when new.deleted_at is null then new.cantidad else 0 end;
  if tg_op = 'UPDATE' and old.deleted_at is null then
    v_antes := old.cantidad;
  end if;

  if tg_op = 'UPDATE' and old.producto_id is distinct from new.producto_id then
    -- Cambió de producto: devuelve todo lo del anterior y descuenta lo del nuevo.
    perform public.mover_stock_de_misionero(new.id, new.colportor_id, old.producto_id, -v_antes, v_fecha);
    perform public.mover_stock_de_misionero(new.id, new.colportor_id, new.producto_id, v_ahora, v_fecha);
  else
    perform public.mover_stock_de_misionero(new.id, new.colportor_id, new.producto_id, v_ahora - v_antes, v_fecha);
  end if;
  return null;
end;
$$;

comment on function public.tg_visita_misionero_mueve_el_stock() is
  'AFTER INSERT / UPDATE OF cantidad, producto_id, deleted_at de visita_misionero (0160): el renglón vivo '
  'descuenta su cantidad del stock de la colportora; si baja la cantidad, cambia de producto o se da de baja, '
  'devuelve lo que había descontado. El stock puede quedar en negativo (S46). Nunca rechaza.';

revoke all on function public.tg_visita_misionero_mueve_el_stock() from public, anon, authenticated, service_role;

create trigger visita_misionero_mueve_el_stock
  after insert or update of cantidad, producto_id, deleted_at on public.visita_misionero
  for each row execute function public.tg_visita_misionero_mueve_el_stock();
