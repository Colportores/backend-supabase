-- ============================================================================
-- Chequeo de la demo de datos (solo lectura): conteos por tabla y coherencia entre las cifras.
-- Cada fila es (orden, que, valor, ok): `ok` es true cuando la cifra cierra con lo esperado (o no tiene regla).
-- Se corre con `scripts/db-seed-demo.sh --chequeo` (o pegándolo en el SQL Editor). Las filas de la demo se reconocen
-- por el prefijo de id 5eed0000-0000-7000-8 (ver demo-datos.sql).
-- ============================================================================
with
d as (select '5eed0000-0000-7000-8%'::text as pre),
conteos as (
  select 1 as o, 'usuarios (colportores + coordinador)' as que, count(*)::bigint as v from public.usuario, d where id::text like d.pre
  union all select 2, 'campañas', count(*) from public.campania, d where id::text like d.pre
  union all select 3, 'inscripciones', count(*) from public.campania_colportor, d where id::text like d.pre
  union all select 4, 'zonas', count(*) from public.zona, d where id::text like d.pre
  union all select 5, 'productos', count(*) from public.producto, d where id::text like d.pre
  union all select 6, 'precios (general + por ciudad)',
         (select count(*) from public.precio_general, d where id::text like d.pre)
         + (select count(*) from public.precio_por_ciudad, d where id::text like d.pre)
  union all select 7, 'casas (ubicaciones)', count(*) from public.ubicacion, d where id::text like d.pre
  union all select 8, 'espacios', count(*) from public.espacio, d where id::text like d.pre
  union all select 9, 'jornadas', count(*) from public.jornada, d where id::text like d.pre
  union all select 10, 'visitas', count(*) from public.visita, d where id::text like d.pre
  union all select 11, 'ventas', count(*) from public.venta, d where id::text like d.pre
  union all select 12, 'renglones de venta', count(*) from public.venta_item, d where id::text like d.pre
  union all select 13, 'entregas', count(*) from public.entrega, d where id::text like d.pre
  union all select 14, 'cobros (con anulados)', count(*) from public.cobranza, d where id::text like d.pre
  union all select 15, 'tickets', count(*) from public.ticket, d where id::text like d.pre
  union all select 16, 'depósitos', count(*) from public.deposito, d where id::text like d.pre
  union all select 17, 'pedidos a la casa editora', count(*) from public.pedido_casa_editora, d where id::text like d.pre
  union all select 18, 'renglones de pedido', count(*) from public.pedido_item, d where id::text like d.pre
  union all select 19, 'filas de stock', count(*) from public.stock, d where id::text like d.pre
  union all select 20, 'movimientos de stock del equipo', count(*) from public.movimiento_stock m
         where m.usuario_id in (select id from public.usuario, d where id::text like d.pre)
  union all select 21, 'agenda', count(*) from public.agenda, d where id::text like d.pre
  union all select 22, 'casas coloreadas (house_status)', count(*) from public.house_status h, d where h.ubicacion_id::text like d.pre
  union all select 23, 'cuentas de colportor', count(*) from public.cuenta_colportor, d where id::text like d.pre
  union all select 24, 'cuentas de alquiler', count(*) from public.cuenta_alquiler c
         where c.usuario_id in (select id from public.usuario, d where id::text like d.pre)
),
reglas as (
  -- 101: toda venta suma sus renglones, salvo las que llevan motivo del monto
  select 101 as o, 'ventas cuyo total no cierra con sus renglones (debe ser 0)' as que,
         count(*)::bigint as v, count(*) = 0 as ok
    from public.venta v, d
   where v.id::text like d.pre and v.motivo_monto_manual is null
     and v.monto_total <> (select coalesce(sum(i.subtotal), 0) from public.venta_item i where i.venta_id = v.id and i.deleted_at is null)
  union all
  -- 102: lo cobrado (sin anulados) nunca supera el total de la venta
  select 102, 'ventas cobradas de más (debe ser 0)', count(*), count(*) = 0
    from public.venta v, d
   where v.id::text like d.pre
     and (select coalesce(sum(c.monto), 0) from public.cobranza c where c.venta_id = v.id and c.anulado_at is null and c.deleted_at is null) > v.monto_total
  union all
  -- 103: ventas con saldo (deuda por cliente) y cuánto suman: informativo
  select 103, 'ventas con saldo por cobrar', count(*), true
    from public.venta v, d
   where v.id::text like d.pre
     and (select coalesce(sum(c.monto), 0) from public.cobranza c where c.venta_id = v.id and c.anulado_at is null and c.deleted_at is null) < v.monto_total
  union all
  select 104, 'saldo por cobrar de los clientes (centavos)',
         coalesce(sum(v.monto_total - (select coalesce(sum(c.monto), 0) from public.cobranza c
                                        where c.venta_id = v.id and c.anulado_at is null and c.deleted_at is null)), 0), true
    from public.venta v, d where v.id::text like d.pre
  union all
  -- 105: el stock de cada colportor es lo recibido menos lo entregado, y nunca queda negativo
  select 105, 'filas de stock que no cierran con sus movimientos o negativas (debe ser 0)', count(*), count(*) = 0
    from public.stock s, d
   where s.id::text like d.pre
     and (s.cantidad_disponible < 0
          or s.cantidad_disponible <> (select coalesce(sum(case when m.tipo = 'ENTRADA_PEDIDO' then m.cantidad when m.tipo = 'SALIDA_ENTREGA' then -m.cantidad else 0 end), 0)
                                         from public.movimiento_stock m
                                        where m.usuario_id = s.usuario_id and m.producto_id = s.producto_id and m.deleted_at is null))
  union all
  select 106, 'entregas marcadas con stock inconsistente (debe ser 0)', count(*), count(*) = 0
    from public.entrega e, d where e.id::text like d.pre and e.stock_inconsistente
  union all
  -- 107: la deuda con la casa editora = pedidos autorizados/recibidos - depósitos validados - tarjetas validadas
  select 107, 'cuentas cuya deuda no cierra con pedidos y pagos (debe ser 0)', count(*), count(*) = 0
    from public.cuenta_colportor cu, d
   where cu.id::text like d.pre
     and cu.deuda_total <> (select coalesce(sum(coalesce(p.monto_autorizado, p.monto_total)), 0) from public.pedido_casa_editora p
                             where p.colportor_id = cu.usuario_id and p.deleted_at is null and p.estado in ('AUTORIZADO', 'DESPACHADO', 'RECIBIDO'))
                           - (select coalesce(sum(dp.monto), 0) from public.deposito dp
                               where dp.colportor_id = cu.usuario_id and dp.deleted_at is null and dp.concepto = 'CASA_EDITORA' and dp.validado_en is not null)
                           - (select coalesce(sum(t.monto), 0) from public.ticket t
                               where t.usuario_id = cu.usuario_id and t.deleted_at is null and t.tipo = 'COBRO_TARJETA' and t.estado = 'VALIDADO')
  union all
  select 108, 'deuda total con la casa editora de los colportores de la demo (centavos)', coalesce(sum(cu.deuda_total), 0), true
    from public.cuenta_colportor cu, d where cu.id::text like d.pre
  union all
  select 109, 'colportores con deuda mayor a cero', count(*), true
    from public.cuenta_colportor cu, d where cu.id::text like d.pre and cu.deuda_total > 0
  union all
  select 110, 'pedidos por autorizar que exceden el límite de deuda', count(*), true
    from public.pedido_casa_editora p, d where p.id::text like d.pre and p.estado = 'PENDIENTE_AUTORIZACION' and p.excede_limite
  union all
  select 111, 'depósitos por validar', count(*), true
    from public.deposito dp, d where dp.id::text like d.pre and dp.validado_en is null and dp.rechazado_en is null
  union all
  select 112, 'tickets por validar', count(*), true
    from public.ticket t, d where t.id::text like d.pre and t.estado = 'PENDIENTE'
  union all
  select 113, 'tickets rechazados', count(*), true
    from public.ticket t, d where t.id::text like d.pre and t.estado = 'RECHAZADO'
  union all
  select 114, 'jornadas con total_visitas distinto de sus visitas (debe ser 0)', count(*), count(*) = 0
    from public.jornada j, d where j.id::text like d.pre and j.total_visitas <> (select count(*) from public.visita v where v.jornada_id = j.id)
  union all
  -- 115: el «en mano» de la cuenta es el que calcula el servidor (efectivo cobrado menos depósitos)
  select 115, 'cuentas cuyo «en mano» difiere de efectivo_en_mano() (debe ser 0)', count(*), count(*) = 0
    from public.cuenta_colportor cu, d where cu.id::text like d.pre and cu.dinero_en_mano <> public.efectivo_en_mano(cu.usuario_id)
  union all
  -- 116: una base sin demo (o una carga que falló) no puede salir toda en verde
  select 116, 'ventas de la demo cargadas (debe ser más de 0)', count(*), count(*) > 0
    from public.venta v, d where v.id::text like d.pre
)
select o as orden, que, v as valor, null::boolean as ok from conteos
union all select o, que, v, ok from reglas
order by 1;
