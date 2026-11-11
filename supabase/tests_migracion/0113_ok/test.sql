-- pgTAP · 0113 sobre los datos de antes: solo suma. Los tickets que ya había, su depósito, el cobro que apunta a uno
-- y la venta quedan idénticos (con su versión de sync y su xmin_w: ni se enteran los teléfonos); las entidades de antes
-- también, y la única nueva es ticket; los tickets de antes se leen en el historial del coordinador, la dueña completa
-- la foto del que estaba por validar y no cambia nada más. Ver scripts/db-test-migracion.sh y datos.sql.
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
select is((select count(*)::int from public.ticket), 3, 'los 3 tickets siguen');
select is((select count(*)::int from public.ticket t join public.prueba_0113_ticket s using (id)
            where to_jsonb(t) is distinct from to_jsonb(s)), 0,
          'quedaron idénticos en todas sus columnas, sync_version y xmin_w incluidos');
select is((select count(*)::int from public.deposito d join public.prueba_0113_deposito s using (id)
            where to_jsonb(d) is distinct from to_jsonb(s)), 0, 'el depósito, idéntico');
select is((select count(*)::int from public.cobranza c join public.prueba_0113_cobranza s using (id)
            where to_jsonb(c) is distinct from to_jsonb(s)), 0, 'y el cobro que apunta al ticket');
select is((select count(*)::int from public.venta v join public.prueba_0113_venta s using (id)
            where to_jsonb(v) is distinct from to_jsonb(s)), 0, 'y la venta');

-- --- el registro de sync ---------------------------------------------------------------------------
select is((select count(*)::int
             from sync.entidad e
             join public.prueba_0113_entidad s using (nombre)
            where (e.tabla::text, e.columna_pk, e.permite_push, e.columnas_servidor, e.sigue_campanias, e.columna_duenio)
                  is distinct from (s.tabla, s.columna_pk, s.permite_push, s.columnas_servidor, s.sigue_campanias, s.columna_duenio)), 0,
          'las entidades de antes quedaron idénticas');
select is((select array_agg(nombre) from sync.entidad e
            where not exists (select 1 from public.prueba_0113_entidad s where s.nombre = e.nombre)),
          array['ticket'], 'y la única nueva es ticket');

-- --- lo de antes se lee y se completa ---------------------------------------------------------------
select pg_temp.actuar_como('01920000-0000-7000-8000-0000000113d1');
select is((select array_agg(right(ticket_id::text, 2) order by ord)
             from (select r.*, row_number() over () as ord
                     from public.tickets_de_campania('01920000-0000-7000-8000-0000000113e1') r) x),
          array['a1', 'a2', 'a3'],
          'el coordinador ve los tickets de antes en su historial: el pendiente primero, y después el más nuevo');
select is((select deposito_destino || '/' || deposito_concepto
             from public.tickets_de_campania('01920000-0000-7000-8000-0000000113e1') where ticket_id = '01920000-0000-7000-8000-0000000113a2'),
          'BANCO/ALQUILER', 'con el depósito del validado');

select pg_temp.actuar_como('01920000-0000-7000-8000-0000000113b1');
select is((select count(*)::int from public.ticket), 3, 'la colportora ve sus 3 tickets');
select is(pg_temp.error_de($$ update public.ticket set monto = 1 where id = '01920000-0000-7000-8000-0000000113a1' $$), '42501',
          'pero ya no corrige el monto de uno subido (sube uno nuevo)');
select is(pg_temp.error_de($$ update public.ticket set url_cloud = '01920000-0000-7000-8000-0000000113b1/01920000-0000-7000-8000-0000000113a1.jpg'
                              where id = '01920000-0000-7000-8000-0000000113a1' $$), 'ok',
          'sí completa la foto del que estaba por validar');
select pg_temp.actuar_como_servidor();
select is((select count(*)::int from public.ticket t join public.prueba_0113_ticket s using (id)
            where t.id <> '01920000-0000-7000-8000-0000000113a1' and to_jsonb(t) is distinct from to_jsonb(s)), 0,
          'y los otros dos no se movieron');
select pg_temp.actuar_como('01920000-0000-7000-8000-0000000113b1');
select is(pg_temp.error_de($$ update public.ticket set url_cloud = '01920000-0000-7000-8000-0000000113b1/01920000-0000-7000-8000-0000000113a2.jpg'
                              where id = '01920000-0000-7000-8000-0000000113a2' $$), 'ok',
          'el validado: la política no lo ve, la fila no se toca (0 filas, sin error)');
select is((select url_cloud from public.ticket where id = '01920000-0000-7000-8000-0000000113a2'), null,
          'y su foto sigue sin ruta');
select is(pg_temp.error_de($$ insert into public.ticket (id, tipo, monto, fecha) values ('01920000-0000-7000-8000-0000000113a4', 'DEPOSITO', 10000, now()) $$),
          'ok', 'la colportora sube un ticket nuevo por la API');
select is((select estado from public.ticket where id = '01920000-0000-7000-8000-0000000113a4'), 'PENDIENTE', 'y nace por validar');
select is(pg_temp.error_de($$ insert into public.cobranza (id, venta_id, monto, medio, fecha, ticket_id)
                              values ('01920000-0000-7000-8000-000000011332', '01920000-0000-7000-8000-000000011301', 1000, 'TARJETA', now(),
                                      '01920000-0000-7000-8000-0000000113a4') $$),
          'ok', 'y lo liga a un cobro de su venta');

select pg_temp.actuar_como_servidor();
select is((select count(*)::int from public.cobranza c join public.prueba_0113_cobranza s using (id)
            where to_jsonb(c) is distinct from to_jsonb(s)), 0, 'el cobro de antes sigue como estaba');

select * from finish();
rollback;
