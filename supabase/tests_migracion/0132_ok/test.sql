-- pgTAP · 0132 sobre los datos de antes: solo suma. Las inscripciones, los depósitos, las campañas y las personas que
-- ya había quedan idénticos (versión de sync incluida); cada inscripción tiene su fila de alquiler con la cuenta de
-- siempre (quien estaba de baja ya no debe y lo pagado queda a favor); la tabla coincide con cuentas_de_campania();
-- una beca de antes en una campaña permanente no se toca (pero no se puede cambiar a otro tipo); y la corrección de
-- carrera recalcula la meta de la inscripción de Verano.
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
create or replace function pg_temp.cod(p_sql text) returns text language plpgsql as $$
begin
  execute p_sql;
  return 'ok';
exception when others then
  return sqlstate;
end $$;

-- --- los datos de antes siguen ---------------------------------------------------------------
select is((select count(*)::int from public.campania_colportor cc join public.prueba_0132_inscripcion s using (id)
            where to_jsonb(cc) is distinct from to_jsonb(s)), 0,
          'las cuatro inscripciones, idénticas en todas sus columnas (sync_version y xmin_w incluidos)');
select is((select count(*)::int from public.campania_colportor), 4, 'siguen las cuatro');
select is((select count(*)::int from public.deposito d join public.prueba_0132_deposito s using (id)
            where to_jsonb(d) is distinct from to_jsonb(s)), 0, 'los depósitos, idénticos');
select is((select count(*)::int from public.campania c join public.prueba_0132_campania s using (id)
            where to_jsonb(c) is distinct from to_jsonb(s)), 0, 'las campañas, idénticas');
select is((select count(*)::int from public.usuario u join public.prueba_0132_usuario s using (id)
            where to_jsonb(u) is distinct from to_jsonb(s)), 0, 'las personas, idénticas');

-- --- la tabla nueva, cargada con la cuenta de siempre -----------------------------------------------
select is((select count(*)::int from public.cuenta_alquiler
            where campania_id in ('01920000-0000-7000-8000-0000000132e1', '01920000-0000-7000-8000-0000000132e2')), 4,
          'una fila por inscripción que ya existía (la de baja incluida)');
select is((select format('%s|%s|%s|%s|%s', coalesce(alquiler_monto::text, 'n'), alquiler_pagado, alquiler_por_validar,
                         coalesce(alquiler_debe::text, 'n'), alquiler_a_favor)
             from public.cuenta_alquiler where usuario_id = '01920000-0000-7000-8000-0000000132b1'
              and campania_id = '01920000-0000-7000-8000-0000000132e1'),
          '150000|50000|20000|100000|0', 'b1 en E: pagó 50000, tiene 20000 por validar y debe 100000');
select is((select format('%s|%s|%s|%s|%s', coalesce(alquiler_monto::text, 'n'), alquiler_pagado, alquiler_por_validar,
                         coalesce(alquiler_debe::text, 'n'), alquiler_a_favor)
             from public.cuenta_alquiler where usuario_id = '01920000-0000-7000-8000-0000000132b2'
              and campania_id = '01920000-0000-7000-8000-0000000132e1'),
          '150000|70000|0|0|70000', 'b2 en E (de baja): ya no debe y los 70000 quedan a favor');
select is((select format('%s|%s|%s|%s|%s', coalesce(alquiler_monto::text, 'n'), alquiler_pagado, alquiler_por_validar,
                         coalesce(alquiler_debe::text, 'n'), alquiler_a_favor)
             from public.cuenta_alquiler where usuario_id = '01920000-0000-7000-8000-0000000132b3'
              and campania_id = '01920000-0000-7000-8000-0000000132e1'),
          '150000|0|0|150000|0', 'b3 en E: debe todo');
select is((select format('%s|%s|%s|%s|%s', coalesce(alquiler_monto::text, 'n'), alquiler_pagado, alquiler_por_validar,
                         coalesce(alquiler_debe::text, 'n'), alquiler_a_favor)
             from public.cuenta_alquiler where usuario_id = '01920000-0000-7000-8000-0000000132b1'
              and campania_id = '01920000-0000-7000-8000-0000000132e2'),
          'n|0|0|n|0', 'b1 en P: la campaña no cobra alquiler');

select pg_temp.actuar_como('01920000-0000-7000-8000-0000000132ad');
select is((select count(*)::int
             from public.cuentas_de_campania('01920000-0000-7000-8000-0000000132e1') r
             full join (select * from public.cuenta_alquiler where campania_id = '01920000-0000-7000-8000-0000000132e1') ca
                    on ca.usuario_id = r.colportor_id
            where r.colportor_id is null or ca.id is null
               or (r.alquiler_monto, r.alquiler_pagado, r.alquiler_por_validar, r.alquiler_debe, r.alquiler_a_favor)
                  is distinct from
                  (ca.alquiler_monto, ca.alquiler_pagado, ca.alquiler_por_validar, ca.alquiler_debe, ca.alquiler_a_favor)), 0,
          'la tabla coincide con cuentas_de_campania()');

-- --- una beca de antes en una permanente no se toca -------------------------------------------------
select pg_temp.actuar_como_servidor();
select is((select tipo_beca from public.campania_colportor
            where campania_id = '01920000-0000-7000-8000-0000000132e2' and usuario_id = '01920000-0000-7000-8000-0000000132b1'),
          'MEDIA', 'la media beca de antes en la permanente sigue');
select is(pg_temp.cod($$ update public.campania_colportor set meta_libros = 61
            where campania_id = '01920000-0000-7000-8000-0000000132e2' and usuario_id = '01920000-0000-7000-8000-0000000132b1' $$),
          'ok', 'se puede tocar otra cosa de esa inscripción');
select is(pg_temp.cod($$ update public.campania_colportor set tipo_beca = 'COMPLETA'
            where campania_id = '01920000-0000-7000-8000-0000000132e2' and usuario_id = '01920000-0000-7000-8000-0000000132b1' $$),
          'BC006', 'pero no cambiarla a otro tipo');

-- --- la corrección de carrera recalcula la meta ---------------------------------------------------------
select pg_temp.actuar_como('01920000-0000-7000-8000-0000000132ad');
select is((select r.cambio from public.elegir_carrera('01920000-0000-7000-8000-0000000132e1',
            '01920000-0000-7000-8000-0000000132b3', '01920000-0000-7000-8000-0000000132a2') r), true,
          'el ADMIN corrige la carrera de b3: Teología a Sistemas');
select pg_temp.actuar_como_servidor();
select is((select format('%s|%s|%s', tipo_beca, meta_libros, meta_monto_ces) from public.campania_colportor
            where campania_id = '01920000-0000-7000-8000-0000000132e1' and usuario_id = '01920000-0000-7000-8000-0000000132b3'),
          'MEDIA|10|500000', 'la media beca de b3 toma la meta de Sistemas');
select pg_temp.actuar_como('01920000-0000-7000-8000-0000000132c1');
select is((select (r.meta_recalculada_en is not null) from public.becas_de_campania('01920000-0000-7000-8000-0000000132e1') r
            where r.usuario_id = '01920000-0000-7000-8000-0000000132b3'), true,
          'y Becas devuelve la marca del aviso');

select * from finish();
rollback;
