-- pgTAP · 0168 sobre los datos de antes: cada cuenta que ya existía recibe UNA primera fila en el historial con la deuda que
-- se lee hoy (0 la de la cuenta de baja), la que no tiene cuenta no recibe nada, las cuentas quedan idénticas, y a partir de
-- ahí `mi_deuda_con_la_casa_editora()` dice null hasta que haya un registro de hace 7 días, y después la deuda de entonces.
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
-- «deuda_total|deuda_hace_7_dias» (n si es null) de la colportora p, como ella.
create or replace function pg_temp.dos(p uuid) returns text language plpgsql as $$
declare j jsonb;
begin
  perform pg_temp.actuar_como(p);
  j := public.mi_deuda_con_la_casa_editora();
  perform pg_temp.actuar_como_servidor();
  return format('%s|%s', j ->> 'deuda_total', coalesce(j ->> 'deuda_hace_7_dias', 'n'));
end $$;

-- --- el historial arranca con lo que hay ---------------------------------------------------------------
select is((select count(*)::int from public.cuenta_deuda_historial), 2, 'dos filas: una por cada cuenta que ya existía');
select is((select deuda from public.cuenta_deuda_historial where usuario_id = '01920000-0000-7000-8000-0000000168b1'),
          100000::bigint, 'b1: su deuda de hoy');
select is((select deuda from public.cuenta_deuda_historial where usuario_id = '01920000-0000-7000-8000-0000000168b2'),
          0::bigint, 'b2: la cuenta de baja se lee en 0');
select is((select count(*)::int from public.cuenta_deuda_historial where usuario_id = '01920000-0000-7000-8000-0000000168b3'), 0,
          'b3, sin cuenta, no recibe nada');
select is((select count(*)::int from public.cuenta_deuda_historial where desde > now() + interval '1 minute'), 0,
          'ninguna fila con una hora inventada en el futuro');

-- --- nada se mueve --------------------------------------------------------------------------------------
select is((select count(*)::int from public.cuenta_colportor c join public.prueba_0168_cuenta s using (id)
            where to_jsonb(c) is distinct from to_jsonb(s)), 0, 'las cuentas, idénticas (deuda y versión incluidas)');

-- --- la respuesta ---------------------------------------------------------------------------------------
select is(pg_temp.dos('01920000-0000-7000-8000-0000000168b1'), '100000|n',
          'hoy no hay datos de hace 7 días: null (la primera fila es de esta migración)');
select is(pg_temp.dos('01920000-0000-7000-8000-0000000168b3'), '0|n', 'sin cuenta: 0 y null');
-- Pasan 8 días sin cambios: la deuda de hace 7 días es la misma de hoy.
update public.cuenta_deuda_historial set desde = now() - interval '8 days';
select is(pg_temp.dos('01920000-0000-7000-8000-0000000168b1'), '100000|100000',
          '8 días después, sin cambios: la de hace 7 días es la de hoy');
-- Cambia la deuda hoy: el total se mueve, el de hace 7 días no.
select public.acreditar_en_la_cuenta('01920000-0000-7000-8000-0000000168b1', 2100, true);
select is(pg_temp.dos('01920000-0000-7000-8000-0000000168b1'), '97900|100000',
          'un depósito validado hoy: baja el total y la de hace 7 días sigue siendo 100000 («▼ $ 2.100»)');
select is((select count(*)::int from public.cuenta_deuda_historial where usuario_id = '01920000-0000-7000-8000-0000000168b1'), 2,
          'el cambio dejó su fila');

select * from finish();
rollback;
