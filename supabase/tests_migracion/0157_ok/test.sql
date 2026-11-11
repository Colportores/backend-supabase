-- pgTAP · 0155, 0156 y 0157 sobre los datos de antes: la devolución de antes sigue con sus productos y su fecha (solo
-- se fueron el dinero retenido y el reembolsado); la venta, sus ítems y su cobro quedan idénticos salvo que el cobro
-- ya no guarda el número de cuota; el saldo de la venta sale de lo cobrado y lo devuelto; y una devolución nueva sobre
-- una venta ya saldada se rechaza. Ver scripts/db-test-migracion.sh y datos.sql.
begin;
select * from no_plan();

create or replace function pg_temp.actuar_como_servidor() returns void language plpgsql as $$
begin
  perform set_config('role', 'postgres', true);
  perform set_config('request.jwt.claims', '', true);
  perform set_config('request.jwt.claim.sub', '', true);
  perform set_config('request.jwt.claim.role', '', true);
end $$;
create or replace function pg_temp.actuar_como(p_uid uuid) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', json_build_object('sub', p_uid, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', p_uid::text, true);
  perform set_config('request.jwt.claim.role', 'authenticated', true);
  perform set_config('role', 'authenticated', true);
end $$;

-- --- la devolución de antes ---------------------------------------------------------------------------
select is((select count(*)::int from public.devolucion), 1, 'sigue la devolución de antes');
select is((select count(*)::int from public.devolucion d join public.prueba_0157_devolucion s using (id)
            where (to_jsonb(d) - 'sync_version' - 'xmin_w' - 'updated_at')
                  is distinct from (to_jsonb(s) - 'dinero_retenido' - 'monto_reembolsado' - 'sync_version' - 'xmin_w' - 'updated_at')), 0,
          'idéntica en todas sus columnas, salvo las dos de plata que se fueron');
select hasnt_column('public', 'devolucion', 'dinero_retenido', 'sin dinero_retenido');
select hasnt_column('public', 'devolucion', 'monto_reembolsado', 'sin monto_reembolsado');

-- --- la venta, sus ítems y el cobro --------------------------------------------------------------------
select is((select count(*)::int from public.venta v join public.prueba_0157_venta s using (id)
            where to_jsonb(v) is distinct from to_jsonb(s)), 0, 'las ventas, idénticas');
select is((select count(*)::int from public.venta_item v join public.prueba_0157_venta_item s using (id)
            where to_jsonb(v) is distinct from to_jsonb(s)), 0, 'los ítems, idénticos');
select hasnt_column('public', 'cobranza', 'numero_cuota', 'el cobro ya no guarda el número de cuota');
select is((select count(*)::int from public.cobranza c join public.prueba_0157_cobranza s using (id)
            where (to_jsonb(c) - 'sync_version' - 'xmin_w' - 'updated_at')
                  is distinct from (to_jsonb(s) - 'numero_cuota' - 'sync_version' - 'xmin_w' - 'updated_at')), 0,
          'el cobro, idéntico salvo el número de cuota');
select is((select monto from public.cobranza where id = '01920000-0000-7000-8000-000000015731'), 250000,
          'y su monto sigue en 250000');

-- --- el saldo ---------------------------------------------------------------------------------------
-- venta 460000 − cobrado 250000 − devuelto (1 × 150000 de la devolución de antes) = 60000
select is(public.saldo_de_la_venta('01920000-0000-7000-8000-000000015701'), 60000::bigint,
          'saldo = 460000 − 250000 − 150000 = 60000');
select is(public.valor_devuelto_de_la_venta('01920000-0000-7000-8000-000000015701'), 150000::bigint, 'lo devuelto vale 150000');

-- Como la colportora (el servidor no pasa por la regla): con 60000 de saldo todavía se acepta; cuando se salda, rechaza.
select pg_temp.actuar_como('01920000-0000-7000-8000-0000000157b1');
select lives_ok($$ insert into public.devolucion (id, venta_id, productos_devueltos, fecha_devolucion, colportor_id, created_by)
  values ('01920000-0000-7000-8000-000000015742', '01920000-0000-7000-8000-000000015701',
          jsonb_build_array(jsonb_build_object('producto_id', '01920000-0000-7000-8000-000000015711', 'cantidad', 1,
                                                'venta_item_id', '01920000-0000-7000-8000-000000015721')),
          '2026-10-04 15:00:00+00', '01920000-0000-7000-8000-0000000157b1', '01920000-0000-7000-8000-0000000157b1') $$,
  'con saldo pendiente todavía se acepta una devolución');
select pg_temp.actuar_como_servidor();
select is(public.saldo_de_la_venta('01920000-0000-7000-8000-000000015701'), 0::bigint, 'ahora la venta queda saldada (saldo 0)');
select pg_temp.actuar_como('01920000-0000-7000-8000-0000000157b1');
select throws_ok($$ insert into public.devolucion (id, venta_id, productos_devueltos, fecha_devolucion, colportor_id, created_by)
  values ('01920000-0000-7000-8000-000000015743', '01920000-0000-7000-8000-000000015701',
          jsonb_build_array(jsonb_build_object('producto_id', '01920000-0000-7000-8000-000000015711', 'cantidad', 1,
                                                'venta_item_id', '01920000-0000-7000-8000-000000015721')),
          '2026-10-05 15:00:00+00', '01920000-0000-7000-8000-0000000157b1', '01920000-0000-7000-8000-0000000157b1') $$,
  '23514', null, 'y sobre la venta ya saldada, no');

select * from finish();
rollback;
