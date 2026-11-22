-- pgTAP · número visible de la transferencia de stock (migración 0127, backend-supabase#106, vista 35 «T-18»)
-- La columna numero: única, no nula, de una secuencia global que crece; la función del default no la ejecuta
-- anon; y transferencias_de_campania() la devuelve en cada fila.
begin;
select * from no_plan();

create or replace function pg_temp.u(p_sufijo text) returns uuid language sql immutable as $$
  select ('01920000-0000-7000-8000-0000000127' || p_sufijo)::uuid
$$;

create or replace function pg_temp.err_srv(p_sql text) returns text language plpgsql as $$
begin
  execute p_sql;
  return 'ok';
exception when others then
  return sqlstate;
end $$;

-- Una coordinadora (a1) con su campaña y dos colportores inscriptos (b1 da, b2 recibe).
insert into auth.users (id, instance_id, aud, role, email, encrypted_password, confirmed_at, created_at, updated_at)
select pg_temp.u(s), '00000000-0000-0000-0000-000000000000',
       'authenticated', 'authenticated', 'numero-' || s || '@example.com', 'x', now(), now(), now()
  from unnest(array['a1','b1','b2']) s;
insert into public.usuario_rol (usuario_id, rol_id)
select pg_temp.u(x.s), r.id
  from (values ('a1','COORDINADOR'), ('b1','COLPORTOR'), ('b2','COLPORTOR')) x(s, codigo)
  join public.rol r on r.codigo = x.codigo;
insert into public.campania (id, nombre, tipo, fecha_inicio, fecha_fin, coordinador_id) values
  (pg_temp.u('e1'), 'Abierta', 'VERANO', '2026-08-03', null, pg_temp.u('a1'));
insert into public.campania_colportor (campania_id, usuario_id, created_at) values
  (pg_temp.u('e1'), pg_temp.u('b1'), '2026-08-01 10:00-03'),
  (pg_temp.u('e1'), pg_temp.u('b2'), '2026-08-01 10:00-03');

-- Tres transferencias: la 11 y la 12 con el default, la 13 recién después.
insert into public.transferencia_stock (id, origen_id, destino_id, fecha_solicitud) values
  (pg_temp.u('11'), pg_temp.u('b1'), pg_temp.u('b2'), '2026-10-20 10:00:00+00');
insert into public.transferencia_stock (id, origen_id, destino_id, fecha_solicitud) values
  (pg_temp.u('12'), pg_temp.u('b2'), pg_temp.u('b1'), '2026-10-20 11:00:00+00');
insert into public.transferencia_stock (id, origen_id, destino_id, fecha_solicitud) values
  (pg_temp.u('13'), pg_temp.u('b1'), pg_temp.u('b2'), '2026-10-20 12:00:00+00');

select is((select count(distinct numero)::int from public.transferencia_stock where id in (pg_temp.u('11'), pg_temp.u('12'), pg_temp.u('13'))),
          3, 'cada transferencia nace con su propio número');
select is((select (t12.numero - t11.numero, t13.numero - t12.numero)::text
             from public.transferencia_stock t11, public.transferencia_stock t12, public.transferencia_stock t13
            where t11.id = pg_temp.u('11') and t12.id = pg_temp.u('12') and t13.id = pg_temp.u('13')),
          '(1,1)', 'y se numeran en el orden en que se crean');
select is(pg_temp.err_srv(format($$ update public.transferencia_stock set numero = (select numero from public.transferencia_stock where id = %L) where id = %L $$, pg_temp.u('11'), pg_temp.u('12'))),
          '23505', 'dos transferencias no pueden tener el mismo número');
select is(pg_temp.err_srv(format($$ update public.transferencia_stock set numero = null where id = %L $$, pg_temp.u('12'))),
          '23502', 'ni quedar sin número');

-- La función del default: la usa el servidor, no la ejecuta anon.
select is((select has_function_privilege('anon', 'public.siguiente_numero_de_transferencia()', 'execute')), false,
          'anon no ejecuta la función del número');
select is((select p.prosecdef and p.proconfig is not null from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'public' and p.proname = 'siguiente_numero_de_transferencia'), true,
          'es SECURITY DEFINER con search_path fijo');

-- La bandeja trae el número de cada fila.
select set_config('request.jwt.claims', json_build_object('sub', pg_temp.u('a1'), 'role', 'authenticated')::text, true);
select set_config('request.jwt.claim.sub', pg_temp.u('a1')::text, true);
select set_config('request.jwt.claim.role', 'authenticated', true);
select set_config('role', 'authenticated', true);
select is((select string_agg(right(b.transferencia_id::text, 2) || '=' || (b.numero - (select min(numero) from public.transferencia_stock where id in (pg_temp.u('11'))))::text, ',' order by b.fecha_solicitud)
             from public.transferencias_de_campania(pg_temp.u('e1')) b),
          '11=0,12=1,13=2', 'la bandeja trae el número de cada una');
select set_config('role', 'postgres', true);
select set_config('request.jwt.claims', '', true);

select * from finish();
rollback;
