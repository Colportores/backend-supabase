-- pgTAP · 0122 sobre los datos de antes: solo suma. El depósito que ya había, su ticket, los cobros y la venta
-- quedan idénticos (con su versión de sync y su xmin_w: ni se enteran los teléfonos); las entidades de antes
-- también, y las únicas nuevas son deposito y deposito_cobro; la tabla de vínculos nace vacía y se puede vincular
-- un cobro de antes con el depósito de antes. Ver scripts/db-test-migracion.sh y datos.sql.
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
create or replace function pg_temp.error_de(p_sql text) returns text language plpgsql as $$
begin
  execute p_sql;
  return 'ok';
exception when others then
  return sqlstate;
end $$;

-- --- los datos de antes siguen ---------------------------------------------------------------
select is((select count(*)::int from public.deposito), 2, 'los dos depósitos siguen (también el que no tiene ticket)');
select is((select convalidated from pg_constraint where conname = 'deposito_ticket_obligatorio'), false,
          'el ticket obligatorio rige para lo nuevo; la fila de antes sin ticket lo deja sin validar y no se borra');
select is((select count(*)::int from public.deposito d join public.prueba_0122_deposito s using (id)
            where to_jsonb(d) is distinct from to_jsonb(s)), 0,
          'quedó idéntico en todas sus columnas, sync_version y xmin_w incluidos: ni se enteran los teléfonos');
select is((select count(*)::int from public.ticket t join public.prueba_0122_ticket s using (id)
            where to_jsonb(t) is distinct from to_jsonb(s)), 0, 'su ticket, idéntico');
select is((select count(*)::int from public.cobranza c join public.prueba_0122_cobranza s using (id)
            where to_jsonb(c) is distinct from to_jsonb(s)), 0, 'los 3 cobros, idénticos');
select is((select count(*)::int from public.venta v join public.prueba_0122_venta s using (id)
            where to_jsonb(v) is distinct from to_jsonb(s)), 0, 'y la venta');

-- --- el registro de sync -----------------------------------------------------------------------
select is((select count(*)::int
             from sync.entidad e
             join public.prueba_0122_entidad s using (nombre)
            where (e.tabla::text, e.columna_pk, e.permite_push, e.columnas_servidor, e.sigue_campanias, e.columna_duenio)
                  is distinct from (s.tabla, s.columna_pk, s.permite_push, s.columnas_servidor, s.sigue_campanias, s.columna_duenio)), 0,
          'las entidades de antes quedaron idénticas');
select is((select array_agg(nombre order by nombre) from sync.entidad e
            where not exists (select 1 from public.prueba_0122_entidad s where s.nombre = e.nombre)),
          array['deposito', 'deposito_cobro'], 'y las únicas nuevas son deposito y deposito_cobro');

-- --- la tabla nueva ------------------------------------------------------------------------------
select is((select count(*)::int from public.deposito_cobro), 0, 'los vínculos nacen vacíos: hasta hoy ningún teléfono los sube');
select lives_ok($$ insert into public.deposito_cobro (deposito_id, cobranza_id, colportor_id)
                   values ('01920000-0000-7000-8000-0000000122f1', '01920000-0000-7000-8000-000000012231',
                           '01920000-0000-7000-8000-0000000122b1') $$,
                'se puede vincular un cobro en efectivo de antes con el depósito de antes');
select is(pg_temp.error_de($$ insert into public.deposito_cobro (deposito_id, cobranza_id, colportor_id)
                              values ('01920000-0000-7000-8000-0000000122f1', '01920000-0000-7000-8000-000000012231',
                                      '01920000-0000-7000-8000-0000000122b1') $$),
          '23505', 'pero no dos veces');

-- La dueña registra un depósito nuevo y le incluye el otro cobro en efectivo de antes.
select pg_temp.actuar_como('01920000-0000-7000-8000-0000000122b1');
select lives_ok($$ insert into public.deposito (id, monto, fecha, destino, concepto)
                   values ('01920000-0000-7000-8000-0000000122f6', 150000, now(), 'RETIRO_COORDINADOR', 'CASA_EDITORA') $$,
                'la colportora registra un depósito nuevo (un retiro por el coordinador)');
select lives_ok($$ insert into public.deposito_cobro (deposito_id, cobranza_id)
                   values ('01920000-0000-7000-8000-0000000122f6', '01920000-0000-7000-8000-000000012232') $$,
                'con el otro cobro en efectivo de antes');
select is(pg_temp.error_de($$ insert into public.deposito (id, monto, fecha, destino, concepto)
                              values ('01920000-0000-7000-8000-0000000122f8', 100, now(), 'BANCO', 'CASA_EDITORA') $$),
          '23514', 'un depósito nuevo de banco sin ticket se rechaza');
select is(pg_temp.error_de($$ insert into public.deposito_cobro (deposito_id, cobranza_id)
                              values ('01920000-0000-7000-8000-0000000122f6', '01920000-0000-7000-8000-000000012233') $$),
          '23514', 'y el cobro con tarjeta de antes no entra a un depósito de efectivo');
select pg_temp.actuar_como_servidor();
select is((select count(*)::int from public.deposito d join public.prueba_0122_deposito s using (id)
            where to_jsonb(d) is distinct from to_jsonb(s)), 0, 'y el depósito de antes sigue intacto');

select * from finish();
rollback;
