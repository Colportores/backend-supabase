-- pgTAP · 0159 sobre los datos de antes: lo pagado por quien se dio de baja deja de trasladarse solo a la deuda: su deuda
-- vuelve a lo que era y esos 70000 quedan POR DECIDIR por el coordinador, sin perder un centavo (depósitos y cobros
-- idénticos); quien sigue inscripto en una campaña que cobra conserva su traslado automático; y cuando el coordinador
-- decide trasladar, la deuda baja otra vez. Ver scripts/db-test-migracion.sh y datos.sql.
begin;
select * from no_plan();

create or replace function pg_temp.actuar_como(p_uid uuid) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', json_build_object('sub', p_uid, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', p_uid::text, true);
  perform set_config('request.jwt.claim.role', 'authenticated', true);
  perform set_config('role', 'authenticated', true);
end $$;
create or replace function pg_temp.actuar_como_servidor() returns void language plpgsql as $$
begin
  perform set_config('role', 'postgres', true);
  perform set_config('request.jwt.claims', '', true);
  perform set_config('request.jwt.claim.sub', '', true);
  perform set_config('request.jwt.claim.role', '', true);
end $$;

-- --- la foto de antes ya traía el traslado automático ------------------------------------------------
select is((select format('%s|%s', deuda_total, alquiler_trasladado) from public.prueba_0159_cuenta
            where usuario_id = '01920000-0000-7000-8000-0000000159b2'), '-60000|70000',
          'antes de la 0159, b2 (de baja) tenía los 70000 pagados trasladados a su deuda');

-- --- nada se pierde ------------------------------------------------------------------------------------
select is((select count(*)::int from public.deposito d join public.prueba_0159_deposito s using (id)
            where to_jsonb(d) is distinct from to_jsonb(s)), 0, 'los depósitos, idénticos (sync_version incluida)');
select is((select count(*)::int from public.campania_colportor cc join public.prueba_0159_inscripcion s using (id)
            where to_jsonb(cc) is distinct from to_jsonb(s)), 0, 'las inscripciones, idénticas');
select is((select dinero_depositado from public.cuenta_colportor where usuario_id = '01920000-0000-7000-8000-0000000159b2'),
          70000::bigint, 'lo depositado por b2 sigue en 70000');

-- --- la baja: la deuda vuelve y lo pagado queda por decidir ------------------------------------------
select is((select format('%s|%s', deuda_total, alquiler_trasladado) from public.cuenta_colportor
            where usuario_id = '01920000-0000-7000-8000-0000000159b2'),
          '10000|0', 'b2: su deuda vuelve a 10000 y ya no hay nada trasladado');
select is((select format('%s|%s|%s|%s|%s', alquiler_pagado, alquiler_trasladado, alquiler_a_favor, alquiler_por_decidir, alquiler_debe)
             from public.cuenta_alquiler where usuario_id = '01920000-0000-7000-8000-0000000159b2'
              and campania_id = '01920000-0000-7000-8000-0000000159e1'),
          '70000|0|0|70000|0', 'y la cuenta del alquiler de b2 dice 70000 pagados, todos por decidir');
select is((select alquiler_trasladado + alquiler_a_favor + alquiler_por_decidir from public.cuenta_alquiler
            where usuario_id = '01920000-0000-7000-8000-0000000159b2' and campania_id = '01920000-0000-7000-8000-0000000159e1'),
          70000::bigint, 'trasladado + a favor + por decidir = lo pagado: no se perdió nada');

-- --- quien sigue inscripto conserva el traslado automático ---------------------------------------------
select is((select format('%s|%s', deuda_total, alquiler_trasladado) from public.cuenta_colportor
            where usuario_id = '01920000-0000-7000-8000-0000000159b1'),
          '50000|50000', 'b1 sigue con los 50000 de más trasladados a su deuda');
select is((select format('%s|%s|%s', alquiler_pagado, alquiler_trasladado, alquiler_por_decidir)
             from public.cuenta_alquiler where usuario_id = '01920000-0000-7000-8000-0000000159b1'
              and campania_id = '01920000-0000-7000-8000-0000000159e1'),
          '200000|50000|0', 'y su cuenta del alquiler no tiene nada por decidir');
select is((select format('%s|%s', deuda_total, alquiler_trasladado) from public.cuenta_colportor
            where usuario_id = '01920000-0000-7000-8000-0000000159b3'), '5000|0', 'b3, sin pagos, no cambia');

-- --- la decisión del coordinador -----------------------------------------------------------------------
select pg_temp.actuar_como('01920000-0000-7000-8000-0000000159c1');
select is((select format('%s|%s|%s', decision, monto_decidido, por_decidir)
             from public.decidir_alquiler_pagado('01920000-0000-7000-8000-0000000159b2', '01920000-0000-7000-8000-0000000159e1',
                                                 'TRASLADAR_A_LA_DEUDA')),
          'TRASLADAR_A_LA_DEUDA|70000|0', 'el coordinador traslada los 70000 de b2 a la deuda');
select pg_temp.actuar_como_servidor();
select is((select format('%s|%s', deuda_total, alquiler_trasladado) from public.cuenta_colportor
            where usuario_id = '01920000-0000-7000-8000-0000000159b2'),
          '-60000|70000', 'la deuda de b2 queda como antes de la migración, ahora por decisión del coordinador');

select * from finish();
rollback;
