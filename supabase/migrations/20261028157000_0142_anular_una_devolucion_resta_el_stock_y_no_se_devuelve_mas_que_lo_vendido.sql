-- 0142 (backend-supabase#201, decisiones del agente de decisiones P1 y P3 sobre 0136):
--   1. Anular una devolución (deleted_at pasa de null a una fecha) resta del stock del colportor lo que esa
--      devolución sumó, con un movimiento SALIDA_DEVOLUCION_ANULADA por libro y el evento
--      stock_revertido_por_devolucion_anulada. Una devolución que llega ya anulada no suma ni resta (0136).
--   2. Una devolución no puede devolver más de lo vendido: por renglón y libro, lo que lleva (más lo que ya
--      devolvieron las otras devoluciones vivas del mismo renglón) no pasa de la cantidad del renglón (de la
--      cantidad por la del componente, en un combo). 23514 `devolucion_cantidad_del_renglon`; el teléfono
--      conserva la devolución con «Reintentar».
-- El stock puede quedar en negativo (S46), como en el resto.

-- ----------------------------------------------------------------------------
-- 1. Anular resta el stock
-- ----------------------------------------------------------------------------

alter table public.movimiento_stock
  drop constraint movimiento_stock_tipo_check;
alter table public.movimiento_stock
  add constraint movimiento_stock_tipo_check
  check (tipo in ('ENTRADA_PEDIDO', 'SALIDA_ENTREGA', 'SALIDA_TRANSFERENCIA', 'ENTRADA_TRANSFERENCIA',
                  'ENTRADA_ENTREGA_ANULADA', 'ENTRADA_ENTREGA_CORREGIDA', 'ENTRADA_DEVOLUCION',
                  'SALIDA_DEVOLUCION_ANULADA'));

-- Una salida por libro y devolución, una sola vez.
create unique index movimiento_stock_salida_devolucion_anulada_key
  on public.movimiento_stock (devolucion_id, producto_id)
  where tipo = 'SALIDA_DEVOLUCION_ANULADA' and deleted_at is null;

create or replace function public.tg_devolucion_devuelve_stock()
returns trigger
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  r          record;
  v_despues  integer;
begin
  if tg_op = 'UPDATE' then
    -- Solo la anulación mueve el stock; cualquier otro cambio de la devolución, no.
    if not (old.deleted_at is null and new.deleted_at is not null) then
      return null;
    end if;

    -- Se resta lo que ella sumó (sus entradas vivas, descontando una salida que ya hubiera salido).
    for r in
      select m.producto_id as prod_id,
             (sum(case when m.tipo = 'ENTRADA_DEVOLUCION' then m.cantidad else -m.cantidad end))::integer as cant
        from public.movimiento_stock m
       where m.devolucion_id = new.id
         and m.deleted_at is null
         and m.tipo in ('ENTRADA_DEVOLUCION', 'SALIDA_DEVOLUCION_ANULADA')
       group by m.producto_id
      having sum(case when m.tipo = 'ENTRADA_DEVOLUCION' then m.cantidad else -m.cantidad end) > 0
       order by m.producto_id
    loop
      insert into public.stock as s (usuario_id, producto_id, cantidad_disponible)
      values (new.colportor_id, r.prod_id, -r.cant)
      on conflict (usuario_id, producto_id)
      do update set cantidad_disponible = case when s.deleted_at is null then s.cantidad_disponible else 0 end
                                          + excluded.cantidad_disponible,
                    deleted_at = null
      returning s.cantidad_disponible into v_despues;

      insert into public.movimiento_stock (usuario_id, producto_id, tipo, cantidad, fecha, devolucion_id)
      values (new.colportor_id, r.prod_id, 'SALIDA_DEVOLUCION_ANULADA', r.cant, now(), new.id);

      perform auditoria.registrar(
        'stock_revertido_por_devolucion_anulada', 'devolucion', new.id, new.colportor_id,
        jsonb_build_object('producto_id', r.prod_id,
                           'cantidad', r.cant,
                           'stock_antes', v_despues + r.cant,
                           'stock_despues', v_despues));
    end loop;
    return null;
  end if;

  -- INSERT. Registrada y anulada sin conexión, y sube todo junto: no hay nada que devolver.
  if new.deleted_at is not null then
    return null;
  end if;

  for r in
    select (e ->> 'producto_id')::uuid as prod_id, (sum((e ->> 'cantidad')::integer))::integer as cant
      from jsonb_array_elements(new.productos_devueltos) e
     group by 1
     order by 1
  loop
    -- Una fila de stock dada de baja cuenta como cero (como en 0126).
    insert into public.stock as s (usuario_id, producto_id, cantidad_disponible)
    values (new.colportor_id, r.prod_id, r.cant)
    on conflict (usuario_id, producto_id)
    do update set cantidad_disponible = case when s.deleted_at is null then s.cantidad_disponible else 0 end
                                        + excluded.cantidad_disponible,
                  deleted_at = null
    returning s.cantidad_disponible into v_despues;

    insert into public.movimiento_stock (usuario_id, producto_id, tipo, cantidad, fecha, devolucion_id)
    values (new.colportor_id, r.prod_id, 'ENTRADA_DEVOLUCION', r.cant, new.fecha_devolucion, new.id);

    perform auditoria.registrar(
      'stock_devuelto_por_devolucion', 'devolucion', new.id, new.colportor_id,
      jsonb_build_object('producto_id', r.prod_id,
                         'cantidad', r.cant,
                         'stock_antes', v_despues - r.cant,
                         'stock_despues', v_despues));
  end loop;
  return null;
end;
$$;

comment on function public.tg_devolucion_devuelve_stock() is
  'AFTER INSERT OR UPDATE OF deleted_at de devolucion (0136, 0142, #201, ADR-002 efecto 2). INSERT: suma al stock '
  'del colportor los libros devueltos (los renglones de un mismo libro se suman), con un movimiento '
  'ENTRADA_DEVOLUCION por libro y el evento stock_devuelto_por_devolucion; una devolución que entra anulada no '
  'mueve nada. UPDATE que anula (deleted_at de null a una fecha): resta lo que sumó con un movimiento '
  'SALIDA_DEVOLUCION_ANULADA por libro y el evento stock_revertido_por_devolucion_anulada. Nunca rechaza.';

drop trigger devolucion_devuelve_stock on public.devolucion;
create trigger devolucion_devuelve_stock
  after insert or update of deleted_at on public.devolucion
  for each row execute function public.tg_devolucion_devuelve_stock();

-- ----------------------------------------------------------------------------
-- 2. No se devuelve más de lo vendido
-- ----------------------------------------------------------------------------

create function public.tg_devolucion_tope_del_renglon()
returns trigger
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  r record;
begin
  -- Una devolución anulada no cuenta, y con otra forma lo rechaza el CHECK.
  if new.deleted_at is not null
     or new.productos_devueltos is null
     or not public.devolucion_renglones_validos(new.productos_devueltos) then
    return new;
  end if;

  -- Lo que se rechaza antes por otra razón (sin fecha, venta que no existe o ajena) lo dice su propio error:
  -- NOT NULL, FK o la política.
  if new.fecha_devolucion is null
     or new.venta_id is null
     or not exists (select 1 from public.venta v
                     where v.id = new.venta_id and v.colportor_id is not distinct from new.colportor_id) then
    return new;
  end if;

  -- Dos devoluciones del mismo renglón a la vez no se pasan entre sí (se toman en el mismo orden).
  perform 1
     from public.venta_item i
    where i.id in (select (e ->> 'venta_item_id')::uuid from jsonb_array_elements(new.productos_devueltos) e)
    order by i.id
      for update;

  for r in
    select (e ->> 'venta_item_id')::uuid as renglon,
           (e ->> 'producto_id')::uuid as prod_id,
           (e ->> 'cantidad')::integer as cant,
           case when i.producto_id = (e ->> 'producto_id')::uuid
                then i.cantidad
                else i.cantidad * coalesce((select (c ->> 'cantidad')::integer
                                              from jsonb_array_elements(coalesce(i.componentes, '[]'::jsonb)) c
                                             where (c ->> 'producto_id')::uuid = (e ->> 'producto_id')::uuid
                                             limit 1), 0)
           end as maximo
      from jsonb_array_elements(new.productos_devueltos) e
      join public.venta_item i on i.id = (e ->> 'venta_item_id')::uuid
  loop
    if r.cant + coalesce((select sum((pe ->> 'cantidad')::integer)
                            from public.devolucion d
                            cross join lateral jsonb_array_elements(d.productos_devueltos) pe
                           where d.id is distinct from new.id
                             and d.deleted_at is null
                             and public.devolucion_renglones_validos(d.productos_devueltos)
                             and (pe ->> 'venta_item_id')::uuid = r.renglon
                             and (pe ->> 'producto_id')::uuid = r.prod_id), 0) > r.maximo then
      raise exception using
        errcode = '23514',
        message = format('Se devuelven más libros de los que se vendieron en ese renglón (el libro %s, renglón %s: como mucho %s). Corregí la cantidad.',
                         r.prod_id, r.renglon, r.maximo),
        constraint = 'devolucion_cantidad_del_renglon';
    end if;
  end loop;
  return new;
end;
$$;

comment on function public.tg_devolucion_tope_del_renglon() is
  'BEFORE INSERT / UPDATE OF productos_devueltos, deleted_at de devolucion (0142, #201): por renglón y libro, lo '
  'que lleva la devolución más lo que ya devolvieron las otras devoluciones vivas no pasa de la cantidad '
  'vendida (cantidad del renglón, o por la del componente en un combo): 23514 devolucion_cantidad_del_renglon. '
  'Corre después de devolucion_productos (que valida que el renglón exista y sea de la venta). Toma el renglón '
  'FOR UPDATE.';

revoke all on function public.tg_devolucion_tope_del_renglon() from public, anon, authenticated, service_role;

create trigger devolucion_tope_del_renglon
  before insert or update of productos_devueltos, deleted_at on public.devolucion
  for each row execute function public.tg_devolucion_tope_del_renglon();
