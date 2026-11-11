-- ============================================================================
-- 0135 · Anular una entrega, volverla a pendiente o bajarle la cantidad devuelve lo descontado al stock del
--        colportor, con un movimiento de entrada en el historial
--        (backend-supabase#201, seguimiento de #147 / 0118, HU-STK-007; decisión de Cristian del 27/10,
--        «Entrega desh»: «vuelve con movimiento»)
--
-- Caso: Emiliano entregó 3 ejemplares del Libro A (el stock pasó de 10 a 7). Después se arrepiente: da de baja
-- la entrega, la vuelve a «pendiente» o la corrige a 2. Hasta ahora el servidor no devolvía nada y el stock
-- quedaba en 7 (0118 lo dejó como pendiente). Ahora:
--
--   · entrega anulada (`deleted_at`) o vuelta a pendiente -> entra un movimiento `ENTRADA_ENTREGA_ANULADA`
--     por todo lo que esa entrega tenía descontado y el stock sube de 7 a 10;
--   · entrega entregada con una cantidad menor (3 -> 2) -> entra un movimiento `ENTRADA_ENTREGA_CORREGIDA` por
--     la diferencia y el stock sube de 7 a 8;
--   · entrega entregada con una cantidad mayor (3 -> 4) o entregada otra vez después de anulada -> sale un
--     `SALIDA_ENTREGA` por la diferencia (o por todo), como en 0118.
--   · si la entrega cambia de producto estando entregada, el producto viejo recupera lo suyo y el nuevo
--     descuenta.
--   Cada movimiento queda en `movimiento_stock` (con `entrega_id`) y en `audit_log`
--   (`stock_descontado_por_entrega` / `stock_devuelto_por_entrega`, ids y números, sin texto libre).
--
-- ## Cómo se mide lo descontado
--
-- El servidor no guarda cuánto descontó una entrega en la entrega: lo saca del historial. Lo descontado de una
-- entrega y un producto es la suma de sus `SALIDA_ENTREGA` menos la suma de sus `ENTRADA_ENTREGA_*` vivas. Eso
-- tiene dos consecuencias buenas:
--
--   · Idempotente. El push hace `INSERT … ON CONFLICT DO NOTHING` (no dispara el trigger de después) y un
--     UPDATE que no cambia lo entregado (reintento, otra columna) no mueve nada: lo que se mueve es la
--     DIFERENCIA entre lo que la fila entregaba antes de la escritura y lo que entrega después.
--   · Nunca devuelve de más. Una entrega ya entregada ANTES de la 0118 no descontó nada (no hay con qué
--     reconstruirlo; los datos son simulados) y, si se anula, no devuelve nada: el tope de lo que vuelve es lo
--     que el historial dice que esa entrega descontó. Una entrega que ya devolvió todo no devuelve dos veces.
--
-- El índice único de 0118 (`movimiento_stock_salida_entrega_key`, una sola SALIDA_ENTREGA por entrega) se quita:
-- decía «volver a pendiente y entregar otra vez no descuenta de nuevo», que era el límite de no tener la
-- devolución. Ahora entregar otra vez sí descuenta, porque lo anterior volvió.
--
-- ## La marca de inconsistencia (S46)
--
-- `entrega.stock_inconsistente` se calcula con la regla de siempre cuando la escritura ENTREGA algo más (la
-- cantidad que suma, no la total): el stock registrado era menor que lo que se agrega. Una entrega que deja de
-- estar entregada vuelve a false (ya no hay entrega que marcar). Sigue siendo del servidor: el push la
-- descarta y un trigger la deja como estaba si la escribe un cliente.
--
-- ## Lo que suma para la devolución de una venta (HU-VEN-004)
--
-- La devolución de una venta usa «el mismo movimiento» para devolver sus libros al stock (decisión del 27/10):
-- este archivo agrega el tipo `ENTRADA_DEVOLUCION` y la columna `movimiento_stock.devolucion_id` (un movimiento
-- viene de a lo sumo un pedido, una transferencia, una entrega o una devolución); el trigger que lo escribe
-- está en la 0136, con la devolución por renglón.
--
-- ## Lo que NO hace
--
--   · No toca las entregas anteriores ni reconstruye lo que no se descontó.
--   · No devuelve stock de una venta anulada: una venta no se anula (ADR-002), se devuelve (0136).
--   · No pone un piso al stock: puede quedar negativo (S46).
--
-- ## Para otros repos
--
--   · docs-organizacion: esquema-datos.md (los tres tipos nuevos de `movimiento_stock`, la columna, los eventos)
--     y HU-STK-007 / HU-VEN-004: docs-organizacion#113.
--   · front-colportores-mobile: nada; el push de `entrega` responde lo mismo.
--
-- Forward-only: esta migración no se edita una vez aplicada.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. movimiento_stock: tres tipos de entrada y el origen «devolución»
-- ----------------------------------------------------------------------------

alter table public.movimiento_stock
  add column devolucion_id uuid references public.devolucion(id);

alter table public.movimiento_stock
  drop constraint movimiento_stock_tipo_check;
alter table public.movimiento_stock
  add constraint movimiento_stock_tipo_check
  check (tipo in ('ENTRADA_PEDIDO', 'SALIDA_ENTREGA', 'SALIDA_TRANSFERENCIA', 'ENTRADA_TRANSFERENCIA',
                  'ENTRADA_ENTREGA_ANULADA', 'ENTRADA_ENTREGA_CORREGIDA', 'ENTRADA_DEVOLUCION'));

alter table public.movimiento_stock
  drop constraint movimiento_stock_un_origen_check;
alter table public.movimiento_stock
  add constraint movimiento_stock_un_origen_check
  check (num_nonnulls(pedido_id, transferencia_id, entrega_id, devolucion_id) <= 1);

create index movimiento_stock_devolucion_idx on public.movimiento_stock (devolucion_id)
  where devolucion_id is not null;

comment on column public.movimiento_stock.devolucion_id is
  'La devolución de una venta de la que vienen los libros que entran al stock (ENTRADA_DEVOLUCION, 0135/0136). '
  'Un movimiento viene de a lo sumo un pedido, una transferencia, una entrega o una devolución.';
comment on table public.movimiento_stock is
  'Histórico de cambios de stock del colportor (V2): entrada por pedido recibido, salida por entrega o por '
  'transferencia, y desde 0135 las entradas de lo que se deshace: entrega anulada o corregida a la baja y '
  'libros devueltos por una devolución de venta. La cantidad es siempre positiva y el tipo dice para qué lado va.';

-- Entregar otra vez una entrega anulada tiene que volver a descontar: ya no hay una sola salida por entrega.
drop index public.movimiento_stock_salida_entrega_key;

-- ----------------------------------------------------------------------------
-- 2. El movimiento de stock de una entrega (interna)
-- ----------------------------------------------------------------------------

-- Aplica un cambio de p_delta unidades entregadas de un producto en una entrega: positivo = descuenta (salida),
-- negativo = devuelve (entrada), con el tope de lo que el historial dice que esa entrega descontó. Interna: la
-- llama el trigger de entrega, que ya conoce al colportor de la venta. SECURITY DEFINER porque el push corre
-- INVOKER y no escribe stock ni movimientos.
create function public.mover_stock_de_entrega(p_entrega_id uuid, p_colportor_id uuid, p_producto_id uuid,
                                              p_delta integer, p_entregada_ahora boolean,
                                              p_fecha_entrega timestamptz, p_inconsistente boolean)
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
    insert into public.stock as s (usuario_id, producto_id, cantidad_disponible)
    values (p_colportor_id, p_producto_id, -p_delta)
    on conflict (usuario_id, producto_id)
    do update set cantidad_disponible = s.cantidad_disponible - p_delta
    returning s.cantidad_disponible into v_despues;

    insert into public.movimiento_stock (usuario_id, producto_id, tipo, cantidad, fecha, entrega_id)
    values (p_colportor_id, p_producto_id, 'SALIDA_ENTREGA', p_delta, coalesce(p_fecha_entrega, now()), p_entrega_id);

    perform auditoria.registrar(
      'stock_descontado_por_entrega', 'entrega', p_entrega_id, p_colportor_id,
      jsonb_build_object('producto_id', p_producto_id,
                         'cantidad', p_delta,
                         'stock_antes', v_despues + p_delta,
                         'stock_despues', v_despues,
                         'inconsistente', p_inconsistente));
    return;
  end if;

  -- Devolver: hasta lo que esta entrega descontó de este producto y todavía no devolvió.
  select coalesce(sum(case when m.tipo = 'SALIDA_ENTREGA' then m.cantidad else -m.cantidad end), 0)
    into v_neto
    from public.movimiento_stock m
   where m.entrega_id = p_entrega_id
     and m.producto_id = p_producto_id
     and m.deleted_at is null
     and m.tipo in ('SALIDA_ENTREGA', 'ENTRADA_ENTREGA_ANULADA', 'ENTRADA_ENTREGA_CORREGIDA');

  v_cantidad := least(-p_delta, greatest(v_neto, 0))::integer;
  if v_cantidad <= 0 then
    return;
  end if;

  -- Una fila de stock dada de baja cuenta como cero (como en 0126).
  insert into public.stock as s (usuario_id, producto_id, cantidad_disponible)
  values (p_colportor_id, p_producto_id, v_cantidad)
  on conflict (usuario_id, producto_id)
  do update set cantidad_disponible = case when s.deleted_at is null then s.cantidad_disponible else 0 end
                                      + excluded.cantidad_disponible,
                deleted_at = null
  returning s.cantidad_disponible into v_despues;

  insert into public.movimiento_stock (usuario_id, producto_id, tipo, cantidad, fecha, entrega_id)
  values (p_colportor_id, p_producto_id,
          case when p_entregada_ahora then 'ENTRADA_ENTREGA_CORREGIDA' else 'ENTRADA_ENTREGA_ANULADA' end,
          v_cantidad, now(), p_entrega_id);

  perform auditoria.registrar(
    'stock_devuelto_por_entrega', 'entrega', p_entrega_id, p_colportor_id,
    jsonb_build_object('producto_id', p_producto_id,
                       'cantidad', v_cantidad,
                       'stock_antes', v_despues - v_cantidad,
                       'stock_despues', v_despues,
                       'motivo', case when p_entregada_ahora then 'corregida' else 'anulada' end));
end;
$$;

comment on function public.mover_stock_de_entrega(uuid, uuid, uuid, integer, boolean, timestamptz, boolean) is
  'Mueve el stock de un colportor por un cambio de p_delta unidades entregadas (0135, #201): positivo descuenta y '
  'deja SALIDA_ENTREGA; negativo devuelve, hasta lo que el historial dice que esa entrega descontó, y deja '
  'ENTRADA_ENTREGA_ANULADA (ya no está entregada) o ENTRADA_ENTREGA_CORREGIDA (sigue entregada, con menos). Los '
  'dos dejan su evento en audit_log. Interna: la llama el trigger de entrega.';

revoke all on function public.mover_stock_de_entrega(uuid, uuid, uuid, integer, boolean, timestamptz, boolean)
  from public, anon, authenticated, service_role;

-- ----------------------------------------------------------------------------
-- 3. BEFORE: la marca, sobre lo que esta escritura agrega
-- ----------------------------------------------------------------------------

create or replace function public.tg_entrega_stock_inconsistente()
returns trigger
language plpgsql
volatile
set search_path = ''
as $$
declare
  v_colportor  uuid;
  v_disponible integer;
  v_ahora      integer;
  v_antes      integer := 0;
  v_agrega     integer;
  v_marcada    boolean := false;
begin
  -- Un cliente (el push o PostgREST) no elige la marca: queda la que había.
  if current_user in ('authenticated', 'anon') then
    new.stock_inconsistente := case when tg_op = 'UPDATE' then old.stock_inconsistente else false end;
  end if;

  -- Lo que la fila entrega después de esta escritura, y lo que entregaba antes (del mismo producto).
  v_ahora := case when not new.pendiente and new.deleted_at is null then new.cantidad else 0 end;
  if tg_op = 'UPDATE' and not old.pendiente and old.deleted_at is null and old.producto_id = new.producto_id then
    v_antes := old.cantidad;
    v_marcada := old.stock_inconsistente;
  end if;

  -- Ya no está entregada: no hay entrega que marcar.
  if v_ahora = 0 then
    new.stock_inconsistente := false;
    return new;
  end if;

  v_agrega := v_ahora - v_antes;
  if v_agrega <= 0 then
    return new;
  end if;

  select v.colportor_id into v_colportor from public.venta v where v.id = new.venta_id;
  if v_colportor is null then
    return new;   -- la venta no existe o no se ve: la FK o la RLS dirán lo suyo, no esta marca
  end if;

  select s.cantidad_disponible into v_disponible
    from public.stock s
   where s.usuario_id = v_colportor and s.producto_id = new.producto_id;

  -- Lo que ya estaba marcado sigue marcado mientras siga entregada (solo sube la entrega).
  new.stock_inconsistente := v_marcada or coalesce(v_disponible, 0) < v_agrega;
  return new;
end;
$$;

comment on function public.tg_entrega_stock_inconsistente() is
  'BEFORE INSERT/UPDATE de entrega (0118, 0135): la marca stock_inconsistente es del servidor. Un cliente no la '
  'elige; cuando la escritura entrega más (pasa a entregada o sube la cantidad) se pone en true si el stock '
  'registrado del colportor era menor que lo que se agrega (sin fila de stock = 0); si deja de estar entregada '
  'vuelve a false. Solo lee: no descuenta (eso lo hace entrega_descuenta_stock).';

-- ----------------------------------------------------------------------------
-- 4. AFTER: el movimiento, sobre la diferencia
-- ----------------------------------------------------------------------------

create or replace function public.tg_entrega_descuenta_stock()
returns trigger
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_colportor uuid;
  v_ahora     integer;
  v_antes     integer := 0;
  v_mismo     boolean := true;
begin
  v_ahora := case when not new.pendiente and new.deleted_at is null then new.cantidad else 0 end;
  if tg_op = 'UPDATE' then
    if not old.pendiente and old.deleted_at is null then
      v_antes := old.cantidad;
    end if;
    v_mismo := old.producto_id = new.producto_id;
  end if;

  -- Nada cambió en lo entregado (otra columna, un reintento): no hay nada que mover.
  if v_mismo and v_ahora = v_antes then
    return null;
  end if;
  if not v_mismo and v_ahora = 0 and v_antes = 0 then
    return null;
  end if;

  select v.colportor_id into v_colportor from public.venta v where v.id = new.venta_id;
  if v_colportor is null then
    return null;
  end if;

  -- El producto de la fila: la diferencia contra lo que entregaba antes (si era el mismo producto).
  perform public.mover_stock_de_entrega(
            new.id, v_colportor, new.producto_id,
            v_ahora - case when v_mismo then v_antes else 0 end,
            v_ahora > 0, new.fecha_entrega, new.stock_inconsistente);

  -- Cambió de producto estando entregada: el producto viejo recupera lo suyo.
  if not v_mismo and v_antes > 0 then
    perform public.mover_stock_de_entrega(
              new.id, v_colportor, old.producto_id, -v_antes, v_ahora > 0, new.fecha_entrega, false);
  end if;
  return null;
end;
$$;

comment on function public.tg_entrega_descuenta_stock() is
  'AFTER INSERT/UPDATE de entrega (0118, 0135, HU-STK-007): mueve el stock del colportor de la venta por la '
  'diferencia entre lo que la fila entregaba antes y lo que entrega después: descuenta (SALIDA_ENTREGA) o '
  'devuelve (ENTRADA_ENTREGA_ANULADA / ENTRADA_ENTREGA_CORREGIDA, hasta lo que esa entrega descontó). Un reintento '
  'o un cambio de otra columna no mueve nada. Nunca rechaza.';
