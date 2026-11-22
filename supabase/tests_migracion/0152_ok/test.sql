-- pgTAP · 0152 sobre los datos de antes: se va deposito_cobro sin perder ningún cobro ni depósito (las filas quedan
-- idénticas, con la versión de sync, salvo las columnas nuevas); el alquiler pagado de más de antes se traslada a la
-- deuda con la casa editora una sola vez (b1: 50000 de más; b2, de baja: todo lo pagado, 70000); quien no pagó de más no
-- cambia; la fila guardada del alquiler dice lo trasladado; y «en mano» sale de lo cobrado en efectivo menos lo depositado.
-- Ver scripts/db-test-migracion.sh y datos.sql.
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

-- --- se fue la tabla de vínculos, y nada más ------------------------------------------------------
select hasnt_table('public', 'deposito_cobro', 'deposito_cobro se retiró');
select is((select count(*)::int from sync.entidad where nombre = 'deposito_cobro'), 0, 'y ya no es entidad del push');
select is((select count(*)::int from public.deposito d join public.prueba_0152_deposito s using (id)
            where to_jsonb(d) - 'rechazado_en' - 'rechazado_por' - 'motivo_rechazo' is distinct from to_jsonb(s)), 0,
          'los tres depósitos, idénticos en todas sus columnas de antes (sync_version y xmin_w incluidos)');
select is((select count(*)::int from public.deposito), 3, 'siguen los tres');
select is((select count(*)::int from public.deposito where rechazado_en is not null or motivo_rechazo is not null), 0,
          'y ninguno está rechazado');
select is((select count(*)::int from public.cobranza c join public.prueba_0152_cobranza s using (id)
            where to_jsonb(c) - 'corregido_at' is distinct from to_jsonb(s)), 0, 'los tres cobros, idénticos');
select is((select count(*)::int from public.cobranza where corregido_at is not null), 0, 'ninguno con hora de corrección');
select is((select count(*)::int from public.campania_colportor cc join public.prueba_0152_inscripcion s using (id)
            where to_jsonb(cc) is distinct from to_jsonb(s)), 0, 'las inscripciones, idénticas');

-- --- el alquiler pagado de más se traslada a la deuda con la casa editora -----------------------------
select is((select format('%s|%s|%s', deuda_total, dinero_depositado, alquiler_trasladado) from public.cuenta_colportor
            where usuario_id = '01920000-0000-7000-8000-0000000152b1'),
          '50000|200000|50000', 'b1 pagó 200000 de un alquiler de 150000: los 50000 de más bajan su deuda de 100000 a 50000');
select is((select format('%s|%s|%s', deuda_total, dinero_depositado, alquiler_trasladado) from public.cuenta_colportor
            where usuario_id = '01920000-0000-7000-8000-0000000152b2'),
          '-60000|70000|70000', 'b2, de baja, no debe alquiler: todo lo que pagó (70000) baja su deuda de 10000 y queda a favor');
select is((select format('%s|%s|%s', deuda_total, dinero_depositado, alquiler_trasladado) from public.cuenta_colportor
            where usuario_id = '01920000-0000-7000-8000-0000000152b3'),
          '5000|0|0', 'b3 no pagó nada: su cuenta no cambia');
select is((select sync_version from public.cuenta_colportor where usuario_id = '01920000-0000-7000-8000-0000000152b3'),
          (select sync_version from public.prueba_0152_cuenta where usuario_id = '01920000-0000-7000-8000-0000000152b3'),
          'y ni su versión de sync se movió: la migración solo toca lo que cambia');
select is((select count(*)::int from public.cuenta_colportor cu join public.prueba_0152_cuenta s using (id)
            where (cu.dinero_depositado, cu.dinero_en_mano, cu.dinero_por_cobrar) is distinct from
                  (s.dinero_depositado, s.dinero_en_mano, s.dinero_por_cobrar)), 0,
          'y Depositado, en mano y por cobrar guardados no se tocan en ninguna cuenta');
select is((select format('%s|%s|%s|%s', alquiler_pagado, alquiler_debe, alquiler_trasladado, alquiler_por_validar)
             from public.cuenta_alquiler where usuario_id = '01920000-0000-7000-8000-0000000152b1'
              and campania_id = '01920000-0000-7000-8000-0000000152e1'),
          '200000|0|50000|0', 'la fila guardada de b1 dice 50000 trasladados');
select is((select format('%s|%s|%s', alquiler_pagado, alquiler_debe, alquiler_trasladado)
             from public.cuenta_alquiler where usuario_id = '01920000-0000-7000-8000-0000000152b2'
              and campania_id = '01920000-0000-7000-8000-0000000152e1'),
          '70000|0|70000', 'la de b2, 70000');
select is((select alquiler_trasladado from public.cuenta_alquiler where usuario_id = '01920000-0000-7000-8000-0000000152b3'
             and campania_id = '01920000-0000-7000-8000-0000000152e1'), 0::bigint, 'la de b3, 0');
-- Se traslada una sola vez: recalcular de nuevo no mueve nada.
select public.refrescar_cuenta_alquiler('01920000-0000-7000-8000-0000000152e1', null);
select is((select deuda_total from public.cuenta_colportor where usuario_id = '01920000-0000-7000-8000-0000000152b1'), 50000::bigint,
          'recalcular otra vez no vuelve a restar');

-- --- el panel lee el traslado y «en mano» calculado -------------------------------------------------
select pg_temp.actuar_como('01920000-0000-7000-8000-0000000152ad');
select is((select format('%s|%s|%s|%s|%s', r.dinero_en_mano, r.deuda_total, r.alquiler_pagado, r.alquiler_debe, r.alquiler_trasladado)
             from public.cuentas_de_campania('01920000-0000-7000-8000-0000000152e1') r
            where r.colportor_id = '01920000-0000-7000-8000-0000000152b1'),
          '70000|50000|200000|0|50000',
          'cuentas_de_campania: b1 tiene 300000 cobrados en efectivo - 230000 depositados (200000 de alquiler y 30000) = 70000 en mano, debe 50000 y trasladó 50000');
select is((select r.alquiler_trasladado from public.cuentas_de_campania('01920000-0000-7000-8000-0000000152e1') r
            where r.colportor_id = '01920000-0000-7000-8000-0000000152b2'), 70000::bigint, 'y b2 trasladó 70000');
select pg_temp.actuar_como_servidor();

select * from finish();
rollback;
