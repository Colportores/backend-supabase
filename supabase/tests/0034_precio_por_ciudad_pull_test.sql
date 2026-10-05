-- pgTAP · migración 0027 (backend-supabase#26): el pull de precio_por_zona.
--   · baja la forma nueva (campania_ciudad_id, sin zona_id) y solo los precios de las campañas que el
--     usuario ve: los de su campaña, no los de otra campaña aunque sea la misma ciudad;
--   · sigue las campañas (sigue_campanias): al inscribir a un colportor, o al dar una campaña para
--     coordinar, los precios que ya estaban cargados BAJAN COMPLETOS, aunque sean más viejos que su
--     watermark. Sin eso, el delta nunca los traería;
--   · después, solo el delta: el cambio de un precio y su baja lógica (el tombstone), y no los de las
--     campañas que no ve.
--
-- Como 0004, 0011, 0014, 0017 y 0019, NO va en una transacción: el delta solo sirve lo commiteado.
-- Limpia al final.

select * from no_plan();

create or replace function pg_temp.actuar_como(p_uid uuid) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', json_build_object('sub', p_uid, 'role', 'authenticated')::text, false);
  perform set_config('request.jwt.claim.sub', p_uid::text, false);
  perform set_config('role', 'authenticated', false);
end $$;

create or replace function pg_temp.como_servidor() returns void language plpgsql as $$
begin
  perform set_config('role', 'postgres', false);
  perform set_config('request.jwt.claims', '', false);
  perform set_config('request.jwt.claim.sub', '', false);
end $$;

create or replace function pg_temp.u(p_sufijo text) returns uuid language sql as $$
  select ('01920000-0000-7000-8000-0000000034' || p_sufijo)::uuid;
$$;

-- Los sufijos de los ids de los precios en `rows`, ordenados; con «x» si vienen dados de baja.
create or replace function pg_temp.filas(p_delta jsonb) returns text[]
language sql as $$
  select coalesce(array_agg(right(e ->> 'id', 2) || case when e ->> 'deleted_at' is not null then 'x' else '' end
                            order by e ->> 'id'), array[]::text[])
    from jsonb_array_elements(coalesce(p_delta -> 'rows' -> 'precio_por_zona', '[]'::jsonb)) e;
$$;

-- ---------------------------------------------------------------------------
-- Fixtures (como postgres). e1 (coordina a1) en c1 (f1) y c2 (f2); e2 (otra campaña, sin coordinador)
-- en la MISMA ciudad c1 (f3).
-- b1 está inscripto en e1; b2 en e2; b3 en ninguna (después se inscribe en e1).
-- Precios (todos del mismo producto: cada uno en su campania_ciudad): 01 en f1, 02 en f2, 03 en f3.
-- ---------------------------------------------------------------------------
insert into auth.users (id, instance_id, aud, role, email, encrypted_password, confirmed_at, created_at, updated_at)
select pg_temp.u(s), '00000000-0000-0000-0000-000000000000',
       'authenticated', 'authenticated', 'precio34-' || s || '@example.com', 'x', now(), now(), now()
  from unnest(array['a1','b1','b2','b3']) s;
insert into public.usuario_rol (usuario_id, rol_id)
select pg_temp.u(x.s), r.id
  from (values ('a1','COORDINADOR'), ('b1','COLPORTOR'), ('b2','COLPORTOR'), ('b3','COLPORTOR')) x(s, codigo)
  join public.rol r on r.codigo = x.codigo;

insert into public.pais (id, nombre, iso_code) values (pg_temp.u('c0'), 'Pais precio34', 'ZQ');
insert into public.ciudad (id, nombre, pais_id, lat_centro, lon_centro) values
  (pg_temp.u('c1'), 'Ciudad c1 precio34', pg_temp.u('c0'), -34.9, -56.2),
  (pg_temp.u('c2'), 'Ciudad c2 precio34', pg_temp.u('c0'), -34.7, -56.1);
insert into public.campania (id, nombre, tipo, fecha_inicio, fecha_fin, coordinador_id) values
  (pg_temp.u('e1'), 'e1 precio34', 'VERANO', public.hoy_montevideo() - 10, public.hoy_montevideo() + 30, pg_temp.u('a1')),
  (pg_temp.u('e2'), 'e2 precio34', 'VERANO', public.hoy_montevideo() - 10, public.hoy_montevideo() + 30, null);
insert into public.campania_ciudad (id, campania_id, ciudad_id) values
  (pg_temp.u('f1'), pg_temp.u('e1'), pg_temp.u('c1')),
  (pg_temp.u('f2'), pg_temp.u('e1'), pg_temp.u('c2')),
  (pg_temp.u('f3'), pg_temp.u('e2'), pg_temp.u('c1'));
insert into public.campania_colportor (campania_id, usuario_id) values
  (pg_temp.u('e1'), pg_temp.u('b1')),
  (pg_temp.u('e2'), pg_temp.u('b2'));
insert into public.producto (id, nombre, tipo) values (pg_temp.u('a1'), 'Libro precio34', 'LIBRO');
insert into public.precio_por_zona (id, producto_id, campania_ciudad_id, precio_venta, valido_desde) values
  (pg_temp.u('01'), pg_temp.u('a1'), pg_temp.u('f1'), 25000, '2026-01-01'),
  (pg_temp.u('02'), pg_temp.u('a1'), pg_temp.u('f2'), 27000, '2026-01-01'),
  (pg_temp.u('03'), pg_temp.u('a1'), pg_temp.u('f3'), 29000, '2026-01-01');

-- ---------------------------------------------------------------------------
-- 1. Primer pull: cada uno baja los precios de sus campañas, con la forma nueva
-- ---------------------------------------------------------------------------
select pg_temp.actuar_como(pg_temp.u('b1'));
create temp table p1 as select sync.pull(array['precio_por_zona'], '{}'::jsonb, 1000) as d;
select is(pg_temp.filas(d), array['01','02'],
          'b1 (inscripto en e1) baja los precios de las dos ciudades de e1, no el de e2 (misma ciudad c1, otra campaña)') from p1;
select ok((select bool_and((e ? 'campania_ciudad_id') and not (e ? 'zona_id'))
             from p1, jsonb_array_elements(d -> 'rows' -> 'precio_por_zona') e),
          'la fila lleva campania_ciudad_id y ya no zona_id') from p1;
select is((select e ->> 'campania_ciudad_id'
             from p1, jsonb_array_elements(d -> 'rows' -> 'precio_por_zona') e
            where right(e ->> 'id', 2) = '01'),
          pg_temp.u('f1')::text, 'y el id de campania_ciudad es el de su ciudad de la campaña');
select is((select (d -> 'watermark' -> 'precio_por_zona') ? 'area' from p1), true,
          'el watermark guarda la huella de las campañas (sigue_campanias)');

select pg_temp.actuar_como(pg_temp.u('b2'));
create temp table q1 as select sync.pull(array['precio_por_zona'], '{}'::jsonb, 1000) as d;
select is(pg_temp.filas(d), array['03'], 'b2 (inscripto en e2) baja solo el de e2') from q1;

select pg_temp.actuar_como(pg_temp.u('a1'));
create temp table c1 as select sync.pull(array['precio_por_zona'], '{}'::jsonb, 1000) as d;
select is(pg_temp.filas(d), array['01','02'], 'a1 (coordina e1) baja los de e1') from c1;

select pg_temp.actuar_como(pg_temp.u('b3'));
create temp table r1 as select sync.pull(array['precio_por_zona'], '{}'::jsonb, 1000) as d;
select is(pg_temp.filas(d), array[]::text[], 'b3 (sin campañas) no baja ningún precio') from r1;

-- ---------------------------------------------------------------------------
-- 2. Se inscribe a b3 en e1: los precios que ya estaban cargados bajan completos
-- ---------------------------------------------------------------------------
select pg_temp.como_servidor();
insert into public.campania_colportor (campania_id, usuario_id) values (pg_temp.u('e1'), pg_temp.u('b3'));

select pg_temp.actuar_como(pg_temp.u('b3'));
create temp table r2 as select sync.pull(array['precio_por_zona'], (select d -> 'watermark' from r1), 1000) as d;
select is(pg_temp.filas(d), array['01','02'],
          'b3, ya inscripto, baja los dos precios de e1 aunque se cargaron antes de su último pull (la huella cambió)') from r2;

-- Sin cambios, el pull siguiente no baja nada.
create temp table r3 as select sync.pull(array['precio_por_zona'], (select d -> 'watermark' from r2), 1000) as d;
select is(pg_temp.filas(d), array[]::text[], 'y el siguiente, sin cambios, no baja nada') from r3;

-- ---------------------------------------------------------------------------
-- 3. Cambios: el delta trae lo que cambió en su campaña, la baja lógica incluida, y nada de lo ajeno
-- ---------------------------------------------------------------------------
select pg_temp.como_servidor();
update public.precio_por_zona set precio_venta = 26000 where id = pg_temp.u('01');
update public.precio_por_zona set precio_venta = 29500 where id = pg_temp.u('03');

select pg_temp.actuar_como(pg_temp.u('b3'));
create temp table r4 as select sync.pull(array['precio_por_zona'], (select d -> 'watermark' from r3), 1000) as d;
select is(pg_temp.filas(d), array['01'], 'cambia el precio de f1 (de su campaña): baja; el de e2, que no ve, no') from r4;
select is((select (e ->> 'precio_venta')::int
             from r4, jsonb_array_elements(d -> 'rows' -> 'precio_por_zona') e), 26000, 'con el importe nuevo') from r4;

select pg_temp.como_servidor();
update public.precio_por_zona set deleted_at = now() where id = pg_temp.u('02');

select pg_temp.actuar_como(pg_temp.u('b3'));
create temp table r5 as select sync.pull(array['precio_por_zona'], (select d -> 'watermark' from r4), 1000) as d;
select is(pg_temp.filas(d), array['02x'], 'la baja lógica baja como tombstone, para que el teléfono borre su réplica') from r5;

select pg_temp.actuar_como(pg_temp.u('b2'));
create temp table q2 as select sync.pull(array['precio_por_zona'], (select d -> 'watermark' from q1), 1000) as d;
select is(pg_temp.filas(d), array['03'], 'b2 recibe el cambio del precio de su campaña, y no los de e1') from q2;

-- ---------------------------------------------------------------------------
-- 4. Se da de baja a b1 de la campaña: deja de ver sus precios (y no se le borra nada del teléfono)
-- ---------------------------------------------------------------------------
select pg_temp.como_servidor();
update public.campania_colportor set deleted_at = now()
 where campania_id = pg_temp.u('e1') and usuario_id = pg_temp.u('b1');
select pg_temp.actuar_como(pg_temp.u('b1'));
create temp table p2 as select sync.pull(array['precio_por_zona'], (select d -> 'watermark' from p1), 1000) as d;
select is(pg_temp.filas(d), array[]::text[],
          'b1, dado de baja de la campaña, ya no baja precios (el servidor no manda borrar nada: lo suyo queda en el teléfono)') from p2;

-- ---------------------------------------------------------------------------
-- Limpieza
-- ---------------------------------------------------------------------------
select pg_temp.como_servidor();
drop table p1, p2, q1, q2, c1, r1, r2, r3, r4, r5;
delete from public.precio_por_zona where id::text like '01920000-0000-7000-8000-0000000034%';
delete from public.producto where id = pg_temp.u('a1');
delete from public.campania_colportor where campania_id in (pg_temp.u('e1'), pg_temp.u('e2'));
delete from public.campania_ciudad where id in (pg_temp.u('f1'), pg_temp.u('f2'), pg_temp.u('f3'));
delete from public.campania where id in (pg_temp.u('e1'), pg_temp.u('e2'));
delete from public.ciudad where id in (pg_temp.u('c1'), pg_temp.u('c2'));
delete from public.pais where id = pg_temp.u('c0');
delete from public.usuario_rol where usuario_id in (pg_temp.u('a1'), pg_temp.u('b1'), pg_temp.u('b2'), pg_temp.u('b3'));
delete from auth.users where id in (pg_temp.u('a1'), pg_temp.u('b1'), pg_temp.u('b2'), pg_temp.u('b3'));
select is((select count(*)::int from public.precio_por_zona where id::text like '01920000-0000-7000-8000-0000000034%'),
          0, 'limpieza: no quedan precios de la prueba');

select * from finish();
