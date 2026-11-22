-- pgTAP · 0141 (backend-supabase#201, «Motivo devol.»): la coordinadora de la campaña lee las devoluciones de su
-- equipo con el motivo; otra coordinadora, otra colportora y anon no; y nadie más que la dueña escribe.
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
create or replace function pg_temp.u(p text) returns uuid language sql immutable as $$
  select ('01920000-0000-7000-8000-0000000141' || p)::uuid;
$$;

insert into auth.users (id, instance_id, aud, role, email, encrypted_password, confirmed_at, created_at, updated_at)
select pg_temp.u(s), '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
       'dev141-' || s || '@example.com', 'x', now(), now(), now()
  from unnest(array['c1','c2','ad','b1','b2']) s;
insert into public.usuario_rol (usuario_id, rol_id)
select pg_temp.u(x.s), r.id
  from (values ('c1','COORDINADOR'), ('c2','COORDINADOR'), ('ad','ADMIN'), ('b1','COLPORTOR'), ('b2','COLPORTOR')) x(s, codigo)
  join public.rol r on r.codigo = x.codigo;
insert into public.campania (id, nombre, tipo, fecha_inicio, fecha_fin, coordinador_id) values
  (pg_temp.u('e1'), 'Campania uno 141', 'VERANO', public.hoy_montevideo() - 30, public.hoy_montevideo() + 10, pg_temp.u('c1')),
  (pg_temp.u('e2'), 'Campania dos 141', 'VERANO', public.hoy_montevideo() - 30, public.hoy_montevideo() + 10, pg_temp.u('c2'));
insert into public.campania_colportor (campania_id, usuario_id, created_at) values
  (pg_temp.u('e1'), pg_temp.u('b1'), now() - interval '40 days'),
  (pg_temp.u('e2'), pg_temp.u('b2'), now() - interval '40 days');
insert into public.producto (id, nombre, tipo, precio_base_compra) values (pg_temp.u('91'), 'Libro t141', 'LIBRO', 1500);
insert into public.pais (id, nombre, iso_code) values (pg_temp.u('f0'), 'Pais dev141', 'ZQ');
insert into public.ciudad (id, nombre, departamento, pais_id, lat_centro, lon_centro)
values (pg_temp.u('f1'), 'Ciudad dev141', 'Departamento de prueba', pg_temp.u('f0'), -34.90, -56.20);
insert into public.ubicacion (id, tipo, calle, numero, lat, lon, ciudad_id, created_by) values
  (pg_temp.u('a1'), 'CASA', 'Av. Italia', '100', -34.900, -56.200, pg_temp.u('f1'), pg_temp.u('b1')),
  (pg_temp.u('a2'), 'CASA', 'Calle Dos',  '2',   -34.905, -56.195, pg_temp.u('f1'), pg_temp.u('b2'));
insert into public.espacio (id, ubicacion_id, created_by) values
  (pg_temp.u('b3'), pg_temp.u('a1'), pg_temp.u('b1')), (pg_temp.u('b4'), pg_temp.u('a2'), pg_temp.u('b2'));
insert into public.espacio_persona (id, espacio_id, persona_id, created_by) values
  (pg_temp.u('51'), pg_temp.u('b3'), pg_temp.u('a5'), pg_temp.u('b1')),
  (pg_temp.u('53'), pg_temp.u('b4'), pg_temp.u('a6'), pg_temp.u('b2'));
insert into public.venta (id, espacio_persona_id, numero_talonario, monto_total, fecha, colportor_id, created_by) values
  (pg_temp.u('71'), pg_temp.u('51'), 'T-14171', 150000, '2026-10-01 15:00:00+00', pg_temp.u('b1'), pg_temp.u('b1')),
  (pg_temp.u('72'), pg_temp.u('53'), 'T-14172', 150000, '2026-10-01 16:00:00+00', pg_temp.u('b2'), pg_temp.u('b2'));
insert into public.venta_item (id, venta_id, producto_id, cantidad, precio_unitario, subtotal) values
  (pg_temp.u('81'), pg_temp.u('71'), pg_temp.u('91'), 1, 150000, 150000),
  (pg_temp.u('82'), pg_temp.u('72'), pg_temp.u('91'), 1, 150000, 150000);
insert into public.devolucion (id, venta_id, colportor_id, productos_devueltos, fecha_devolucion, motivo, created_by) values
  (pg_temp.u('d1'), pg_temp.u('71'), pg_temp.u('b1'),
   jsonb_build_array(jsonb_build_object('producto_id', pg_temp.u('91'), 'cantidad', 1, 'venta_item_id', pg_temp.u('81'))), now(), 'No le gustó', pg_temp.u('b1')),
  (pg_temp.u('d2'), pg_temp.u('72'), pg_temp.u('b2'),
   jsonb_build_array(jsonb_build_object('producto_id', pg_temp.u('91'), 'cantidad', 1, 'venta_item_id', pg_temp.u('82'))), now(), null, pg_temp.u('b2'));

select is((select count(*)::int from pg_policies where tablename = 'devolucion' and policyname = 'devolucion_select_coordinacion'), 1,
          'existe la política de lectura de la coordinación');
select is((select array_agg(policyname::text order by policyname) from pg_policies where tablename = 'devolucion' and cmd <> 'SELECT'),
          array['devolucion_insert_propia','devolucion_update_propia'], 'la escritura sigue siendo solo de la dueña');

select pg_temp.actuar_como(pg_temp.u('c1'));
select is((select array_agg(right(id::text, 2) order by id) from public.devolucion where id in (pg_temp.u('d1'), pg_temp.u('d2'))),
          array['d1'], 'c1 lee la de su colportora (b1) y no la de la campaña de c2');
select is((select motivo from public.devolucion where id = pg_temp.u('d1')), 'No le gustó', 'con el motivo');
select pg_temp.actuar_como(pg_temp.u('c2'));
select is((select array_agg(right(id::text, 2) order by id) from public.devolucion where id in (pg_temp.u('d1'), pg_temp.u('d2'))),
          array['d2'], 'c2 lee solo la de su equipo');
select pg_temp.actuar_como(pg_temp.u('ad'));
select is((select count(*)::int from public.devolucion where id in (pg_temp.u('d1'), pg_temp.u('d2'))), 2, 'el ADMIN lee las dos');
select pg_temp.actuar_como(pg_temp.u('b1'));
select is((select array_agg(right(id::text, 2) order by id) from public.devolucion where id in (pg_temp.u('d1'), pg_temp.u('d2'))),
          array['d1'], 'b1 sigue leyendo solo la suya');

-- La coordinadora no escribe: ni cambia el motivo ni anota una devolución.
select pg_temp.actuar_como(pg_temp.u('c1'));
update public.devolucion set motivo = 'cambiado' where id = pg_temp.u('d1');
select pg_temp.actuar_como_servidor();
select is((select motivo from public.devolucion where id = pg_temp.u('d1')), 'No le gustó', 'c1 no cambia el motivo (el update no toca filas)');

select * from finish();
rollback;
