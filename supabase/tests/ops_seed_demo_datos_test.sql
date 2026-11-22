-- pgTAP · el generador de datos de demo (supabase/seed-demo/demo-datos.sql)
--
-- Lo corre dentro de una transacción que se deshace (como 0005_seed_idempotencia_test.sql: ningún dato de demo
-- queda para los demás archivos) y verifica que:
--   · carga lo esperado y las cifras son coherentes con el esquema vigente (si una migración cambia una tabla o una
--     regla y rompe el generador, este test falla en CI en vez de enterarnos al correrlo contra la demo);
--   · una segunda pasada no cambia nada (idempotente);
--   · todo lo que crea lleva el prefijo de la demo (se puede retirar), y el retiro deja la demo dada de baja salvo
--     los depósitos ya validados (DP001).
--
-- Requiere invocarse con cwd = raíz del repo (así lo hace scripts/db-test.sh).
begin;
select * from no_plan();

\i supabase/seed-demo/demo-datos.sql

select is((select count(*) from public.campania where id::text like '5eed0000-0000-7000-8%'), 2::bigint, 'dos campañas de demo');
select is((select count(*) from public.usuario where id::text like '5eed0000-0000-7000-8%'), 11::bigint, 'un coordinador y diez colportores');
select is((select count(*) from public.campania_colportor where id::text like '5eed0000-0000-7000-8%'), 13::bigint, '13 inscripciones');
select cmp_ok((select count(*) from public.venta where id::text like '5eed0000-0000-7000-8%'), '>', 200::bigint, 'hay ventas');
select cmp_ok((select count(*) from public.cobranza where id::text like '5eed0000-0000-7000-8%'), '>', 300::bigint, 'hay cobros');
select cmp_ok((select count(*) from public.deposito where id::text like '5eed0000-0000-7000-8%'), '>', 50::bigint, 'hay depósitos');
select cmp_ok((select count(*) from public.pedido_casa_editora where id::text like '5eed0000-0000-7000-8%'), '>', 20::bigint, 'hay pedidos');

-- Coherencia de plata
select is((select count(*) from public.venta v
            where v.id::text like '5eed0000-0000-7000-8%' and v.motivo_monto_manual is null
              and v.monto_total <> (select coalesce(sum(i.subtotal), 0) from public.venta_item i where i.venta_id = v.id)),
          0::bigint, 'el total de cada venta es la suma de sus renglones (salvo las que traen motivo)');
select is((select count(*) from public.venta v
            where v.id::text like '5eed0000-0000-7000-8%'
              and (select coalesce(sum(c.monto), 0) from public.cobranza c where c.venta_id = v.id and c.anulado_at is null) > v.monto_total),
          0::bigint, 'ninguna venta está cobrada de más');
select cmp_ok((select count(*) from public.venta v
                where v.id::text like '5eed0000-0000-7000-8%'
                  and (select coalesce(sum(c.monto), 0) from public.cobranza c where c.venta_id = v.id and c.anulado_at is null) < v.monto_total),
               '>', 0::bigint, 'hay deuda por cliente (ventas con saldo)');
select is((select count(*) from public.stock s
            where s.id::text like '5eed0000-0000-7000-8%'
              and (s.cantidad_disponible < 0
                   or s.cantidad_disponible <> (select coalesce(sum(case when m.tipo = 'ENTRADA_PEDIDO' then m.cantidad
                                                                           when m.tipo = 'SALIDA_ENTREGA' then -m.cantidad else 0 end), 0)
                                                  from public.movimiento_stock m
                                                 where m.usuario_id = s.usuario_id and m.producto_id = s.producto_id))),
          0::bigint, 'el stock cierra con sus movimientos y nunca es negativo');
select is((select count(*) from public.cuenta_colportor cu
            where cu.id::text like '5eed0000-0000-7000-8%'
              and cu.deuda_total <> (select coalesce(sum(coalesce(p.monto_autorizado, p.monto_total)), 0) from public.pedido_casa_editora p
                                      where p.colportor_id = cu.usuario_id and p.estado in ('AUTORIZADO', 'DESPACHADO', 'RECIBIDO'))
                                    - (select coalesce(sum(dp.monto), 0) from public.deposito dp
                                        where dp.colportor_id = cu.usuario_id and dp.concepto = 'CASA_EDITORA' and dp.validado_en is not null)
                                    - (select coalesce(sum(t.monto), 0) from public.ticket t
                                        where t.usuario_id = cu.usuario_id and t.tipo = 'COBRO_TARJETA' and t.estado = 'VALIDADO')),
          0::bigint, 'la deuda con la casa editora cierra con pedidos, depósitos validados y tarjetas validadas');

-- Idempotente: la segunda pasada no cambia nada
create temp table antes as
  select (select count(*) from public.venta) ventas, (select count(*) from public.cobranza) cobros,
         (select count(*) from public.usuario) usuarios, (select count(*) from public.movimiento_stock) movs;
\i supabase/seed-demo/demo-datos.sql
select results_eq(
  $$ select (select count(*) from public.venta), (select count(*) from public.cobranza),
            (select count(*) from public.usuario), (select count(*) from public.movimiento_stock) $$,
  $$ select ventas, cobros, usuarios, movs from antes $$,
  'una segunda pasada no duplica nada');

-- En mano: la cuenta del generador coincide con la del servidor (solo efectivo)
select is((select count(*) from public.cuenta_colportor cu where cu.id::text like '5eed0000-0000-7000-8%'
            and cu.dinero_en_mano <> public.efectivo_en_mano(cu.usuario_id)), 0::bigint,
          'el «en mano» de cada cuenta es el efectivo_en_mano() del servidor');

-- Retiro: baja lógica de todo lo de la demo; los depósitos validados quedan (DP001)
\i supabase/seed-demo/retirar-demo-datos.sql
select is((select count(*) from public.venta where id::text like '5eed0000-0000-7000-8%' and deleted_at is not null), 0::bigint,
          'la vista previa del retiro no da de baja nada');

select set_config('retiro.aplicar', 'si', true);
\i supabase/seed-demo/retirar-demo-datos.sql
select is((select count(*) from public.venta where id::text like '5eed0000-0000-7000-8%' and deleted_at is null), 0::bigint,
          'el retiro da de baja todas las ventas de la demo');
select is((select count(*) from public.usuario where id::text like '5eed0000-0000-7000-8%' and deleted_at is null), 0::bigint,
          'el retiro da de baja a los usuarios de la demo');
select is((select count(*) from public.campania where id::text like '5eed0000-0000-7000-8%' and deleted_at is null), 0::bigint,
          'el retiro da de baja las campañas de la demo');
select cmp_ok((select count(*) from public.deposito where id::text like '5eed0000-0000-7000-8%' and deleted_at is null and validado_en is null),
               '=', 0::bigint, 'los depósitos sin validar se dieron de baja');
select cmp_ok((select count(*) from public.deposito where id::text like '5eed0000-0000-7000-8%' and deleted_at is null and validado_en is not null),
               '>', 0::bigint, 'los depósitos validados quedan vivos (DP001)');
select is((select count(*) from public.venta where id::text not like '5eed0000-0000-7000-8%' and deleted_at is not null), 0::bigint,
          'el retiro no toca nada que no sea de la demo');
select is((select count(*) from public.cuenta_deuda_historial h where h.deleted_at is null
            and h.usuario_id in (select id from public.usuario where id::text like '5eed0000-0000-7000-8%')), 0::bigint,
          'el retiro da de baja también el historial de deuda de las cuentas de la demo');

select * from finish();
rollback;
