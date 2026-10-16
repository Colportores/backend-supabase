-- pgTAP · migración 0031 (backend-supabase#42, etapa 2): el pull lleva el rectángulo de la ciudad y el enlace
-- al paquete de mapa de la zona, y solo a quien ve esa zona.
--   · `ciudad` baja con bbox_oeste, bbox_sur, bbox_este y bbox_norte (sync.expresion_json manda todas las
--     columnas de la entidad);
--   · `zona` baja con paquete_mapa a quien la ve (inscripto en la campaña) y a nadie más: el enlace al
--     paquete, que no está en el catálogo público, solo llega con su zona (decisión de Cristian del 06/10,
--     «Zona pública»);
--   · cuando el publicador cambia el enlace (UPDATE con la clave de servicio), el delta se lo lleva a
--     quien ve la zona, y no a los demás;
--   · poner el enlace no pasa por la validación de la forma (tg_zona_mapa) ni mueve la zona.
--
-- Como 0004, 0011, 0014, 0017, 0019 y 0034, NO va en una transacción: el delta solo sirve lo commiteado.
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
  select ('01920000-0000-7000-8000-0000000039' || p_sufijo)::uuid;
$$;

-- Los sufijos de los ids de la entidad `p_entidad` en `rows`, ordenados.
create or replace function pg_temp.filas(p_delta jsonb, p_entidad text) returns text[]
language sql as $$
  select coalesce(array_agg(right(e ->> 'id', 2) order by e ->> 'id'), array[]::text[])
    from jsonb_array_elements(coalesce(p_delta -> 'rows' -> p_entidad, '[]'::jsonb)) e;
$$;

-- ---------------------------------------------------------------------------
-- Fixtures (como postgres). Dos ciudades: c1 con su rectángulo, c2 sin él. Dos campañas, una en cada una
-- (f1 en c1, f2 en c2), y una zona en cada una (a1 en f1, con su paquete; a2 en f2, sin él).
-- b1 está inscripto en e1; b2 en e2.
-- ---------------------------------------------------------------------------
insert into auth.users (id, instance_id, aud, role, email, encrypted_password, confirmed_at, created_at, updated_at)
select pg_temp.u(s), '00000000-0000-0000-0000-000000000000',
       'authenticated', 'authenticated', 'bbox39-' || s || '@example.com', 'x', now(), now(), now()
  from unnest(array['b1','b2']) s;
insert into public.usuario_rol (usuario_id, rol_id)
select pg_temp.u(x.s), r.id
  from (values ('b1','COLPORTOR'), ('b2','COLPORTOR')) x(s, codigo)
  join public.rol r on r.codigo = x.codigo;

insert into public.pais (id, nombre, iso_code) values (pg_temp.u('c0'), 'Pais bbox39', 'ZV');
insert into public.ciudad (id, nombre, pais_id, lat_centro, lon_centro, bbox_oeste, bbox_sur, bbox_este, bbox_norte) values
  (pg_temp.u('c1'), 'Ciudad c1 bbox39', pg_temp.u('c0'), -34.9, -56.2, -56.433, -34.945, -55.948, -34.701),
  (pg_temp.u('c2'), 'Ciudad c2 bbox39', pg_temp.u('c0'), -34.7, -56.1, null, null, null, null);
insert into public.campania (id, nombre, tipo, fecha_inicio, fecha_fin) values
  (pg_temp.u('e1'), 'e1 bbox39', 'VERANO', public.hoy_montevideo() - 10, public.hoy_montevideo() + 30),
  (pg_temp.u('e2'), 'e2 bbox39', 'VERANO', public.hoy_montevideo() - 10, public.hoy_montevideo() + 30);
insert into public.campania_ciudad (id, campania_id, ciudad_id) values
  (pg_temp.u('f1'), pg_temp.u('e1'), pg_temp.u('c1')),
  (pg_temp.u('f2'), pg_temp.u('e2'), pg_temp.u('c2'));
insert into public.campania_colportor (campania_id, usuario_id) values
  (pg_temp.u('e1'), pg_temp.u('b1')),
  (pg_temp.u('e2'), pg_temp.u('b2'));
insert into public.zona (id, nombre, campania_ciudad_id, tipo_forma, centro_lat, centro_lon, radio_m, color, paquete_mapa) values
  (pg_temp.u('a1'), 'Zona a1 bbox39', pg_temp.u('f1'), 'RADIAL', -34.9, -56.2, 500, '#3A7BD5',
   '{"archivo":"zonas/11111111111111111111111111111111.pmtiles","tamano_bytes":1000,"sha256":"aa","zoom_max":15}'),
  (pg_temp.u('a2'), 'Zona a2 bbox39', pg_temp.u('f2'), 'RADIAL', -34.7, -56.1, 500, '#E07A5F', null);

-- ---------------------------------------------------------------------------
-- 1. Primer pull
-- ---------------------------------------------------------------------------
select pg_temp.actuar_como(pg_temp.u('b1'));
create temp table p1 as select sync.pull(array['ciudad', 'zona'], '{}'::jsonb, 1000) as d;
select ok((select (e ->> 'bbox_oeste')::float8 = -56.433 and (e ->> 'bbox_sur')::float8 = -34.945
                  and (e ->> 'bbox_este')::float8 = -55.948 and (e ->> 'bbox_norte')::float8 = -34.701
             from p1, jsonb_array_elements(d -> 'rows' -> 'ciudad') e where e ->> 'id' = pg_temp.u('c1')::text),
          'b1 baja la ciudad c1 con su rectángulo (los cuatro bbox_*) en el pull');
select ok((select e ? 'bbox_oeste' and e -> 'bbox_oeste' = 'null'::jsonb
             from p1, jsonb_array_elements(d -> 'rows' -> 'ciudad') e where e ->> 'id' = pg_temp.u('c2')::text),
          'y la ciudad sin rectángulo con las columnas en null (no faltan: el contrato manda todas)');
select is(pg_temp.filas(d, 'zona'), array['a1'], 'b1 baja la zona de su campaña y no la de la otra') from p1;
select is((select e -> 'paquete_mapa' ->> 'archivo'
             from p1, jsonb_array_elements(d -> 'rows' -> 'zona') e where right(e ->> 'id', 2) = 'a1'),
          'zonas/11111111111111111111111111111111.pmtiles', 'con el enlace a su paquete') from p1;

select pg_temp.actuar_como(pg_temp.u('b2'));
create temp table q1 as select sync.pull(array['ciudad', 'zona'], '{}'::jsonb, 1000) as d;
select is(pg_temp.filas(d, 'zona'), array['a2'], 'b2 baja solo la zona de su campaña') from q1;
select is((select count(*)::int from q1, jsonb_array_elements(d -> 'rows' -> 'zona') e
            where e::text like '%11111111111111111111111111111111%'), 0,
          'y el enlace del paquete de a1 no aparece en nada de lo que baja (no está en el catálogo público ni en el pull ajeno)') from q1;
select is((select (e -> 'paquete_mapa')::text
             from q1, jsonb_array_elements(d -> 'rows' -> 'zona') e where right(e ->> 'id', 2) = 'a2'),
          'null', 'la zona sin publicar baja con paquete_mapa null') from q1;

-- ---------------------------------------------------------------------------
-- 2. El publicador pone el paquete de a2 y cambia el de a1: el delta se lo lleva a cada uno
-- ---------------------------------------------------------------------------
select pg_temp.como_servidor();
update public.zona set paquete_mapa = '{"archivo":"zonas/22222222222222222222222222222222.pmtiles","tamano_bytes":2000,"sha256":"bb","zoom_max":15}'
 where id = pg_temp.u('a2');
update public.zona
   set paquete_mapa = '{"archivo":"zonas/33333333333333333333333333333333.pmtiles","tamano_bytes":3000,"sha256":"cc","zoom_max":15,"anteriores":[{"archivo":"zonas/11111111111111111111111111111111.pmtiles","desde":"2026-10-08T12:00:00Z"}]}'
 where id = pg_temp.u('a1');

select pg_temp.actuar_como(pg_temp.u('b2'));
create temp table q2 as select sync.pull(array['ciudad', 'zona'], (select d -> 'watermark' from q1), 1000) as d;
select is(pg_temp.filas(d, 'zona'), array['a2'], 'b2 recibe el enlace nuevo de su zona por delta, y no el de a1') from q2;
select is((select e -> 'paquete_mapa' ->> 'archivo'
             from q2, jsonb_array_elements(d -> 'rows' -> 'zona') e), 'zonas/22222222222222222222222222222222.pmtiles',
          'con el archivo nuevo') from q2;

select pg_temp.actuar_como(pg_temp.u('b1'));
create temp table p2 as select sync.pull(array['ciudad', 'zona'], (select d -> 'watermark' from p1), 1000) as d;
select is(pg_temp.filas(d, 'zona'), array['a1'], 'b1 recibe el cambio del enlace de a1 y no el de a2') from p2;
select is((select jsonb_array_length(e -> 'paquete_mapa' -> 'anteriores')
             from p2, jsonb_array_elements(d -> 'rows' -> 'zona') e), 1,
          'con la lista de archivos anteriores que lleva el publicador') from p2;

-- Sin cambios, el siguiente no baja nada.
create temp table p3 as select sync.pull(array['ciudad', 'zona'], (select d -> 'watermark' from p2), 1000) as d;
select is(pg_temp.filas(d, 'zona'), array[]::text[], 'y el pull siguiente, sin cambios, no baja zonas') from p3;

-- ---------------------------------------------------------------------------
-- 3. Se le carga el rectángulo a c2: la ciudad vuelve a bajar
-- ---------------------------------------------------------------------------
select pg_temp.como_servidor();
update public.ciudad set bbox_oeste = -56.2, bbox_sur = -34.8, bbox_este = -55.9, bbox_norte = -34.6
 where id = pg_temp.u('c2');

select pg_temp.actuar_como(pg_temp.u('b1'));
create temp table p4 as select sync.pull(array['ciudad', 'zona'], (select d -> 'watermark' from p3), 1000) as d;
select is(pg_temp.filas(d, 'ciudad'), array['c2'], 'al cargarle el rectángulo a c2, la ciudad baja por delta') from p4;
select is((select (e ->> 'bbox_norte')::float8
             from p4, jsonb_array_elements(d -> 'rows' -> 'ciudad') e), -34.6::float8, 'con su rectángulo') from p4;

-- ---------------------------------------------------------------------------
-- Limpieza
-- ---------------------------------------------------------------------------
select pg_temp.como_servidor();
drop table p1, p2, p3, p4, q1, q2;
delete from public.zona where id in (pg_temp.u('a1'), pg_temp.u('a2'));
delete from public.campania_colportor where campania_id in (pg_temp.u('e1'), pg_temp.u('e2'));
delete from public.campania_ciudad where id in (pg_temp.u('f1'), pg_temp.u('f2'));
delete from public.campania where id in (pg_temp.u('e1'), pg_temp.u('e2'));
delete from public.ciudad where id in (pg_temp.u('c1'), pg_temp.u('c2'));
delete from public.pais where id = pg_temp.u('c0');
delete from public.usuario_rol where usuario_id in (pg_temp.u('b1'), pg_temp.u('b2'));
delete from auth.users where id in (pg_temp.u('b1'), pg_temp.u('b2'));
select is((select count(*)::int from public.zona where id::text like '01920000-0000-7000-8000-0000000039%'),
          0, 'limpieza: no quedan zonas de la prueba');

select * from finish();
