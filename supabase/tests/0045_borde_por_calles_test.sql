-- pgTAP · borde de las zonas por esquinas (migración 0036, backend-supabase#25, ADR-018)
-- Las calles de OSM (schema ruteo) y las tres RPC de la vista 24: esquina_mas_cercana(),
-- tramo_por_calles() y poligono_por_calles().
--   1. El schema ruteo: pgRouting, sin grants, con RLS; la forma y los privilegios de las funciones.
--   2. ruteo.cargar_red(): partir las vías en cruces, qué es un cruce, qué se descarta, reemplazar
--      sin perder la red vieja si el archivo no sirve.
--   3. esquina_mas_cercana(): «esquina a 20 m de un cruce», nombres, el más cercano en METROS.
--   4. tramo_por_calles(): «dos esquinas sobre la misma calle → sigue la calle», el más corto, sin
--      sentidos de circulación, sin camino (CZ016), búsqueda fuera del rectángulo.
--   5. poligono_por_calles(): «cuatro esquinas en L → polígono válido y cerrado», «dos zonas
--      vecinas que usan las mismas esquinas comparten borde sin superponerse», bordes que se cruzan.
--   6. El permiso primero en las tres (sin JWT, colportor, otra campaña, terminada, sin calles…).
--   7. Lo que arma poligono_por_calles() lo acepta guardar_zona().
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

-- El rol `authenticated` pero sin sesión: auth.uid() es null.
create or replace function pg_temp.actuar_sin_jwt() returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', '', true);
  perform set_config('request.jwt.claim.sub', '', true);
  perform set_config('request.jwt.claim.role', '', true);
  perform set_config('role', 'authenticated', true);
end $$;

create or replace function pg_temp.actuar_como_anon() returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', '', true);
  perform set_config('request.jwt.claim.sub', '', true);
  perform set_config('request.jwt.claim.role', 'anon', true);
  perform set_config('role', 'anon', true);
end $$;

-- sqlstate de ejecutar p_sql ('OK' si no falló): para repetir una prueba con distintos usuarios.
create or replace function pg_temp.codigo(p_sql text) returns text language plpgsql as $$
begin
  execute p_sql;
  return 'OK';
exception when others then
  return sqlstate;
end $$;

-- --- OSM de mentira (el formato de Overpass: way con nodes, geometry y tags) --------------------
-- Una coordenada con 7 decimales (la precisión de OSM) vuelve idéntica del JSON a la base.
create or replace function pg_temp.r7(p double precision) returns double precision language sql immutable as
$$ select round(p::numeric, 7)::double precision $$;

-- El id de nodo sale de las coordenadas: dos vías que pasan por el mismo punto comparten el nodo.
create or replace function pg_temp.nid(p_lon double precision, p_lat double precision) returns bigint
language sql immutable as
$$ select round(p_lon * 1e7)::bigint * 1000000007 + round(p_lat * 1e7)::bigint $$;

create or replace function pg_temp.via(p_id bigint, p_nombre text, p_tipo text, p_pts jsonb,
                                       p_extra jsonb default '{}'::jsonb) returns jsonb
language sql as $$
  select jsonb_build_object(
    'type', 'way', 'id', p_id,
    'nodes', (select jsonb_agg(pg_temp.nid((e ->> 0)::double precision, (e ->> 1)::double precision) order by i)
                from jsonb_array_elements(p_pts) with ordinality t(e, i)),
    'geometry', (select jsonb_agg(jsonb_build_object('lat', (e ->> 1)::double precision,
                                                     'lon', (e ->> 0)::double precision) order by i)
                   from jsonb_array_elements(p_pts) with ordinality t(e, i)),
    'tags', jsonb_build_object('highway', p_tipo)
            || case when p_nombre is null then '{}'::jsonb else jsonb_build_object('name', p_nombre) end
            || p_extra);
$$;

-- La cuadrícula de c1: 4 calles de oeste a este (filas) por 4 de norte a sur (columnas). Las
-- coordenadas se corren unos metros para que dos caminos que dan la vuelta a la manzana nunca midan
-- lo mismo (sin empates entre recorridos de igual largo).
create or replace function pg_temp.glon(c integer, r integer) returns double precision language sql immutable as
$$ select pg_temp.r7(-56.2000 + 0.0010 * c + 0.00003 * sin(r * 3.1 + c * 1.7)) $$;
create or replace function pg_temp.glat(c integer, r integer) returns double precision language sql immutable as
$$ select pg_temp.r7(-34.9000 - 0.0010 * r + 0.00003 * cos(r * 2.3 + c * 4.1)) $$;
create or replace function pg_temp.gpt(c integer, r integer) returns jsonb language sql immutable as
$$ select jsonb_build_array(pg_temp.glon(c, r), pg_temp.glat(c, r)) $$;

-- Un punto de una malla de 0,001° con origen (lon0, lat0): x hacia el este, y hacia el sur.
create or replace function pg_temp.pt(p_lon0 numeric, p_lat0 numeric, p_x numeric, p_y numeric) returns jsonb
language sql immutable as
$$ select jsonb_build_array(pg_temp.r7(p_lon0 + 0.001 * p_x), pg_temp.r7(p_lat0 - 0.001 * p_y)) $$;

create temp table osm_doc (k text primary key, doc jsonb) on commit drop;

-- c1 «Cuadrícula»: 8 vías de la cuadrícula + una cruz aislada + 7 vías que se descartan.
insert into osm_doc
select 'grilla', jsonb_build_object('version', 0.6, 'generator', 'pgTAP', 'elements',
  (select jsonb_agg(w order by ord) from (
     select r as ord,
            pg_temp.via(1000 + r, (array['Heredia', 'Garzón', 'Belvedere', 'Larrañaga'])[r + 1], 'residential',
                        (select jsonb_agg(pg_temp.gpt(c, r) order by c) from generate_series(0, 3) c),
                        case when r = 0 then '{"oneway":"yes"}'::jsonb else '{}'::jsonb end) as w
       from generate_series(0, 3) r
     union all
     select 10 + c,
            pg_temp.via(2000 + c, (array['Pororó', 'Aparicio', 'Charrúa', 'Yaro'])[c + 1], 'tertiary',
                        (select jsonb_agg(pg_temp.gpt(c, r) order by r) from generate_series(0, 3) r))
       from generate_series(0, 3) c
     union all
     -- Una cruz lejos y sin conexión con la cuadrícula; «Aislada Este» repite un nodo seguido (dato malo).
     select 20, pg_temp.via(3001, 'Aislada Norte', 'residential',
                            '[[-56.15,-34.85],[-56.15,-34.8505],[-56.15,-34.851]]'::jsonb)
     union all
     select 21, pg_temp.via(3002, 'Aislada Este', 'residential',
                            '[[-56.1505,-34.8505],[-56.15,-34.8505],[-56.15,-34.8505],[-56.1495,-34.8505]]'::jsonb)
     union all
     -- Fuera de la lista de tipos: ni senderos, ni pasajes de servicio, ni autopistas.
     select 30, pg_temp.via(4001, 'Sendero', 'footway', jsonb_build_array(pg_temp.gpt(0, 0), pg_temp.gpt(3, 3)))
     union all
     select 31, pg_temp.via(4002, 'Pasaje', 'service', jsonb_build_array(pg_temp.gpt(1, 1), pg_temp.pt(-56.2, -34.9, 1.3, 1.5)))
     union all
     select 32, pg_temp.via(4003, 'Ruta', 'motorway', jsonb_build_array(pg_temp.gpt(2, 0), pg_temp.gpt(2, 3)))
     union all
     -- Vías rotas: sin highway, nodes y geometry de distinto largo, un punto sin coordenadas, un solo nodo.
     select 33, '{"type":"way","id":4004,"nodes":[1,2],"geometry":[{"lat":-34.9,"lon":-56.2},{"lat":-34.91,"lon":-56.2}],"tags":{"name":"Sin tipo"}}'::jsonb
     union all
     select 34, '{"type":"way","id":4005,"nodes":[3,4,5],"geometry":[{"lat":-34.9,"lon":-56.3},{"lat":-34.91,"lon":-56.3}],"tags":{"highway":"residential","name":"Corta"}}'::jsonb
     union all
     select 35, '{"type":"way","id":4006,"nodes":[6,7],"geometry":[{"lat":-34.9,"lon":-56.4},null],"tags":{"highway":"residential","name":"Con hueco"}}'::jsonb
     union all
     select 36, '{"type":"way","id":4007,"nodes":[8],"geometry":[{"lat":-34.9,"lon":-56.5}],"tags":{"highway":"residential","name":"Un punto"}}'::jsonb
     union all
     -- Elementos que no son vías.
     select 40, '{"type":"node","id":9,"lat":-34.9,"lon":-56.2}'::jsonb
     union all
     select 41, '{"type":"relation","id":10,"members":[]}'::jsonb
  ) x));

-- c2 «Ciudad L»: un anillo de seis calles alrededor de un bloque en L.
--   P1(0,0) ─Norte─ P2(3,0)
--   │Oeste           │Este
--   P6(0,3)  P4(1,1)─Alta─ P3(3,1)
--     └Baja─ P5(1,3)  └Interior┘ (P4 a P5)
insert into osm_doc
select 'ele', jsonb_build_object('elements', jsonb_build_array(
  pg_temp.via(5001, 'Norte',    'residential', jsonb_build_array(pg_temp.pt(-56.1, -34.8, 0, 0), pg_temp.pt(-56.1, -34.8, 3, 0))),
  pg_temp.via(5002, 'Este',     'residential', jsonb_build_array(pg_temp.pt(-56.1, -34.8, 3, 0), pg_temp.pt(-56.1, -34.8, 3, 1))),
  pg_temp.via(5003, 'Alta',     'residential', jsonb_build_array(pg_temp.pt(-56.1, -34.8, 3, 1), pg_temp.pt(-56.1, -34.8, 1, 1))),
  pg_temp.via(5004, 'Interior', 'residential', jsonb_build_array(pg_temp.pt(-56.1, -34.8, 1, 1), pg_temp.pt(-56.1, -34.8, 1, 3))),
  pg_temp.via(5005, 'Baja',     'residential', jsonb_build_array(pg_temp.pt(-56.1, -34.8, 1, 3), pg_temp.pt(-56.1, -34.8, 0, 3))),
  pg_temp.via(5006, 'Oeste',    'residential', jsonb_build_array(pg_temp.pt(-56.1, -34.8, 0, 3), pg_temp.pt(-56.1, -34.8, 0, 0)))));

-- c3 «Continuas»: la misma calle cortada en dos vías no es un cruce; las calles sin nombre sí cruzan.
--   Recta: a(0,0) b(1,0) c(2,0) | c d(3,0), dos vías con el mismo nombre. Cruz Uno pasa por b y Cruz Dos
--   termina en d. e(5,0) es el cruce de dos vías sin nombre; g(7,0), el de «Solo» con una sin nombre.
insert into osm_doc
select 'continuas', jsonb_build_object('elements', jsonb_build_array(
  pg_temp.via(6001, 'Recta',    'residential', jsonb_build_array(pg_temp.pt(-56, -34.7, 0, 0), pg_temp.pt(-56, -34.7, 1, 0), pg_temp.pt(-56, -34.7, 2, 0))),
  pg_temp.via(6002, 'Recta',    'residential', jsonb_build_array(pg_temp.pt(-56, -34.7, 2, 0), pg_temp.pt(-56, -34.7, 3, 0))),
  pg_temp.via(6003, 'Cruz Uno', 'residential', jsonb_build_array(pg_temp.pt(-56, -34.7, 1, -1), pg_temp.pt(-56, -34.7, 1, 0), pg_temp.pt(-56, -34.7, 1, 1))),
  pg_temp.via(6004, 'Cruz Dos', 'residential', jsonb_build_array(pg_temp.pt(-56, -34.7, 3, -1), pg_temp.pt(-56, -34.7, 3, 0), pg_temp.pt(-56, -34.7, 3, 1))),
  pg_temp.via(6005, null,       'residential', jsonb_build_array(pg_temp.pt(-56, -34.7, 5, -1), pg_temp.pt(-56, -34.7, 5, 0), pg_temp.pt(-56, -34.7, 5, 1))),
  pg_temp.via(6006, null,       'residential', jsonb_build_array(pg_temp.pt(-56, -34.7, 4, 0), pg_temp.pt(-56, -34.7, 5, 0), pg_temp.pt(-56, -34.7, 6, 0))),
  pg_temp.via(6007, 'Solo',     'residential', jsonb_build_array(pg_temp.pt(-56, -34.7, 7, -1), pg_temp.pt(-56, -34.7, 7, 0), pg_temp.pt(-56, -34.7, 7, 1))),
  pg_temp.via(6008, null,       'residential', jsonb_build_array(pg_temp.pt(-56, -34.7, 7, 0), pg_temp.pt(-56, -34.7, 8, 0)))));

-- c4 «Rodeo»: dos calles paralelas a 46 m que solo se unen por el fondo, a 1,66 km. Entre las puntas de
-- arriba hay 46 m en línea recta y 3,4 km por las calles: el camino sale del rectángulo de búsqueda.
insert into osm_doc
select 'rodeo', jsonb_build_object('elements', jsonb_build_array(
  pg_temp.via(7001, 'Calle A', 'residential', '[[-56.3,-34.8],[-56.3,-34.815]]'::jsonb),
  pg_temp.via(7002, 'Calle B', 'residential', '[[-56.2995,-34.815],[-56.2995,-34.8]]'::jsonb),
  pg_temp.via(7003, 'Fondo',   'residential', '[[-56.3,-34.815],[-56.2995,-34.815]]'::jsonb),
  pg_temp.via(7004, 'Norte Uno', 'residential', '[[-56.3003,-34.8],[-56.3,-34.8],[-56.2998,-34.8]]'::jsonb),
  pg_temp.via(7005, 'Norte Dos', 'residential', '[[-56.2997,-34.8],[-56.2995,-34.8],[-56.2992,-34.8]]'::jsonb)));

-- c5 «Empate»: desde P, el cruce X queda a 85 m al este y el Y a 90 m al norte. En grados Y parece
-- más cerca (la longitud vale menos metros que la latitud); en metros, X.
insert into osm_doc
select 'empate', jsonb_build_object('elements', jsonb_build_array(
  pg_temp.via(8001, 'X1', 'residential', jsonb_build_array(jsonb_build_array(x.lon, x.lat - 0.0003), jsonb_build_array(x.lon, x.lat), jsonb_build_array(x.lon, x.lat + 0.0003))),
  pg_temp.via(8002, 'X2', 'residential', jsonb_build_array(jsonb_build_array(x.lon - 0.0003, x.lat), jsonb_build_array(x.lon, x.lat), jsonb_build_array(x.lon + 0.0003, x.lat))),
  pg_temp.via(8003, 'Y1', 'residential', jsonb_build_array(jsonb_build_array(y.lon, y.lat - 0.0003), jsonb_build_array(y.lon, y.lat), jsonb_build_array(y.lon, y.lat + 0.0003))),
  pg_temp.via(8004, 'Y2', 'residential', jsonb_build_array(jsonb_build_array(y.lon - 0.0003, y.lat), jsonb_build_array(y.lon, y.lat), jsonb_build_array(y.lon + 0.0003, y.lat)))))
  from (select pg_temp.r7(-56.4 + 85 / (111320 * cos(radians(34.6)))) as lon, -34.6::double precision as lat) x,
       (select -56.4::double precision as lon, pg_temp.r7(-34.6 + 90 / 110950.0) as lat) y;

-- c8 «Atajos»: tres lugares donde el camino más corto sale del rectángulo de búsqueda de ruteo.camino()
-- (los dos puntos más max(1 km, su distancia), con 5 % de aire) o queda justo afuera. En cada uno hay un
-- recorrido largo que sí cae adentro (el que se encuentra primero) y uno más corto que sale a buscar.
--   1. A y B a 92 m; «Gran Rodeo» da 4,3 km por adentro (más del doble del margen: se descarta y se
--      busca en toda la ciudad) y el atajo por el norte mide 2,5 km pero su «Techo» está a 1,2 km.
--   2. A2 y B2 a 275 m; un zigzag de 624 m por adentro contra un techo de 497 m a 111 m al norte.
--   3. A3 y B3 a 333 m (norte-sur); un zigzag de 648 m contra un lateral de 553 m a 110 m al este.
insert into osm_doc
select 'atajos', jsonb_build_object('elements', jsonb_build_array(
  pg_temp.via(9101, 'Gran Rodeo',    'residential', '[[-56.5,-34.5],[-56.511,-34.5],[-56.511,-34.49],[-56.499,-34.49],[-56.499,-34.5]]'::jsonb),
  pg_temp.via(9102, 'Atajo Oeste',   'residential', '[[-56.5,-34.5],[-56.5,-34.489]]'::jsonb),
  pg_temp.via(9103, 'Atajo Techo',   'residential', '[[-56.5,-34.489],[-56.499,-34.489]]'::jsonb),
  pg_temp.via(9104, 'Atajo Este',    'residential', '[[-56.499,-34.489],[-56.499,-34.5]]'::jsonb),
  pg_temp.via(9111, 'Zigzag',        'residential', '[[-56.4,-34.5],[-56.3995,-34.4995],[-56.399,-34.5005],[-56.3985,-34.4995],[-56.398,-34.5005],[-56.3975,-34.4995],[-56.397,-34.5]]'::jsonb),
  pg_temp.via(9112, 'Techo Oeste',   'residential', '[[-56.4,-34.5],[-56.4,-34.499]]'::jsonb),
  pg_temp.via(9113, 'Techo',         'residential', '[[-56.4,-34.499],[-56.397,-34.499]]'::jsonb),
  pg_temp.via(9114, 'Techo Este',    'residential', '[[-56.397,-34.499],[-56.397,-34.5]]'::jsonb),
  pg_temp.via(9121, 'Zigzag Tres',   'residential', '[[-56.3,-34.5],[-56.2994,-34.5005],[-56.3006,-34.501],[-56.2994,-34.5015],[-56.3006,-34.502],[-56.2994,-34.5025],[-56.3,-34.503]]'::jsonb),
  pg_temp.via(9122, 'Lateral Norte', 'residential', '[[-56.3,-34.5],[-56.2988,-34.5]]'::jsonb),
  pg_temp.via(9123, 'Lateral',       'residential', '[[-56.2988,-34.5],[-56.2988,-34.503]]'::jsonb),
  pg_temp.via(9124, 'Lateral Sur',   'residential', '[[-56.2988,-34.503],[-56.3,-34.503]]'::jsonb)));

-- c9 «Eco»: una ciudad vecina con un cruce a 3,7 m del cruce (1,1) de la cuadrícula (c1), que no es suyo.
-- Además: dos cruces «gemelos» a la misma distancia (exacta) del punto (-56,25, -34,95) (±2^-10 grados de
-- longitud: simétricos también en binario), y un cruce cuyas
-- calles ordenan distinto según la collation de la base («Zorrilla» y «arenal»).
insert into osm_doc
select 'eco', jsonb_build_object('elements', jsonb_build_array(
  pg_temp.via(9201, 'Eco Uno', 'residential', jsonb_build_array(jsonb_build_array(e.x, e.y - 0.0003), jsonb_build_array(e.x, e.y), jsonb_build_array(e.x, e.y + 0.0003))),
  pg_temp.via(9202, 'Eco Dos', 'residential', jsonb_build_array(jsonb_build_array(e.x - 0.0003, e.y), jsonb_build_array(e.x, e.y), jsonb_build_array(e.x + 0.0003, e.y))),
  pg_temp.via(9211, 'Gemela Oeste Uno', 'residential', '[[-56.2509765625,-34.9503],[-56.2509765625,-34.95],[-56.2509765625,-34.9497]]'::jsonb),
  pg_temp.via(9212, 'Gemela Oeste Dos', 'residential', '[[-56.2512765625,-34.95],[-56.2509765625,-34.95],[-56.2506765625,-34.95]]'::jsonb),
  pg_temp.via(9213, 'Gemela Este Uno',  'residential', '[[-56.2490234375,-34.9503],[-56.2490234375,-34.95],[-56.2490234375,-34.9497]]'::jsonb),
  pg_temp.via(9214, 'Gemela Este Dos',  'residential', '[[-56.2493234375,-34.95],[-56.2490234375,-34.95],[-56.2487234375,-34.95]]'::jsonb),
  pg_temp.via(9221, 'Zorrilla', 'residential', '[[-56.35,-34.9503],[-56.35,-34.95],[-56.35,-34.9497]]'::jsonb),
  pg_temp.via(9222, 'arenal',   'residential', '[[-56.3503,-34.95],[-56.35,-34.95],[-56.3497,-34.95]]'::jsonb)))
  from (select pg_temp.r7(pg_temp.glon(1, 1) + 0.00004) as x, pg_temp.glat(1, 1) as y) e;

-- --- fixtures del dominio ------------------------------------------------------------------------
-- Staff: a1 coordinador de e1 (vigente), e3 (terminada), e4 y e5 (por empezar); a2 coordinador de e2; ad admin;
--        a0 colportor; a3 sin ningún rol; a4 coordinador con el rol vencido.
-- Ciudades: c1 Cuadrícula  c2 Ciudad L  c3 Continuas  c4 Rodeo  c5 Empate  c6 Sin calles  c7 Con red vacía de cruces
--           c8 Atajos  c9 Eco (cruces de otra ciudad, empate exacto, nombres)  ca dada de baja
-- Campañas: e1 Verano (vigente, a1)  e2 Otra (vigente, a2)  e3 Vieja (terminada, a1)  e4 Futura (a1)
-- campania_ciudad: 71 e1/c1  72 e1/c2  73 e1/c3  74 e1/c4  75 e1/c5  76 e1/c6  77 e1/c7  78 e1/c1 de baja (e5)
--        79 e2/c1  7a e3/c1  7b e4/c1  7c e1/c8  7d e1/c9
insert into auth.users (id, instance_id, aud, role, email, encrypted_password, confirmed_at, created_at, updated_at)
select ('01920000-0000-7000-8000-0000000045' || s)::uuid, '00000000-0000-0000-0000-000000000000',
       'authenticated', 'authenticated', 'calles-' || s || '@example.com', 'x', now(), now(), now()
  from unnest(array['a0', 'a1', 'a2', 'a3', 'a4', 'ad']) s;
insert into public.usuario_rol (usuario_id, rol_id)
select ('01920000-0000-7000-8000-0000000045' || x.s)::uuid, r.id
  from (values ('a1', 'COORDINADOR'), ('a2', 'COORDINADOR'), ('ad', 'ADMIN'), ('a0', 'COLPORTOR')) x(s, codigo)
  join public.rol r on r.codigo = x.codigo;
insert into public.usuario_rol (usuario_id, rol_id, valido_desde, valido_hasta)
select '01920000-0000-7000-8000-0000000045a4'::uuid, r.id, now() - interval '10 days', now() - interval '1 day'
  from public.rol r where r.codigo = 'COORDINADOR';

insert into public.pais (id, nombre, iso_code) values ('01920000-0000-7000-8000-0000000045c0', 'Pais calles', 'ZQ');
insert into public.ciudad (id, nombre, pais_id, lat_centro, lon_centro, zoom_inicial) values
  ('01920000-0000-7000-8000-0000000045c1', 'Cuadrícula q25',  '01920000-0000-7000-8000-0000000045c0', -34.90, -56.20, 15),
  ('01920000-0000-7000-8000-0000000045c2', 'Ciudad L q25',    '01920000-0000-7000-8000-0000000045c0', -34.80, -56.10, 15),
  ('01920000-0000-7000-8000-0000000045c3', 'Continuas q25',   '01920000-0000-7000-8000-0000000045c0', -34.70, -56.00, 15),
  ('01920000-0000-7000-8000-0000000045c4', 'Rodeo q25',       '01920000-0000-7000-8000-0000000045c0', -34.80, -56.30, 15),
  ('01920000-0000-7000-8000-0000000045c5', 'Empate q25',      '01920000-0000-7000-8000-0000000045c0', -34.60, -56.40, 15),
  ('01920000-0000-7000-8000-0000000045c6', 'Sin calles q25',  '01920000-0000-7000-8000-0000000045c0', -33.00, -56.00, 15),
  ('01920000-0000-7000-8000-0000000045c7', 'Sin cruces q25',  '01920000-0000-7000-8000-0000000045c0', -32.00, -56.00, 15),
  ('01920000-0000-7000-8000-0000000045c8', 'Atajos q25',      '01920000-0000-7000-8000-0000000045c0', -34.50, -56.40, 15),
  ('01920000-0000-7000-8000-0000000045c9', 'Eco q25',         '01920000-0000-7000-8000-0000000045c0', -34.90, -56.30, 15),
  ('01920000-0000-7000-8000-0000000045ca', 'Dada de baja q25', '01920000-0000-7000-8000-0000000045c0', -31.00, -56.00, 15);
update public.ciudad set deleted_at = now() where id = '01920000-0000-7000-8000-0000000045ca';

insert into public.campania (id, nombre, tipo, fecha_inicio, fecha_fin, coordinador_id) values
  ('01920000-0000-7000-8000-0000000045e1', 'Verano',  'VERANO', public.hoy_montevideo() - 10, public.hoy_montevideo() + 30, '01920000-0000-7000-8000-0000000045a1'),
  ('01920000-0000-7000-8000-0000000045e2', 'Otra',    'VERANO', public.hoy_montevideo() - 10, null,                         '01920000-0000-7000-8000-0000000045a2'),
  ('01920000-0000-7000-8000-0000000045e3', 'Vieja',   'VERANO', public.hoy_montevideo() - 90, public.hoy_montevideo() - 30, '01920000-0000-7000-8000-0000000045a1'),
  ('01920000-0000-7000-8000-0000000045e4', 'Futura',  'VERANO', public.hoy_montevideo() + 10, public.hoy_montevideo() + 40, '01920000-0000-7000-8000-0000000045a1'),
  ('01920000-0000-7000-8000-0000000045e5', 'Baja cc', 'VERANO', public.hoy_montevideo() - 10, public.hoy_montevideo() + 30, '01920000-0000-7000-8000-0000000045a1');
insert into public.campania_ciudad (id, campania_id, ciudad_id, deleted_at) values
  ('01920000-0000-7000-8000-000000004571', '01920000-0000-7000-8000-0000000045e1', '01920000-0000-7000-8000-0000000045c1', null),
  ('01920000-0000-7000-8000-000000004572', '01920000-0000-7000-8000-0000000045e1', '01920000-0000-7000-8000-0000000045c2', null),
  ('01920000-0000-7000-8000-000000004573', '01920000-0000-7000-8000-0000000045e1', '01920000-0000-7000-8000-0000000045c3', null),
  ('01920000-0000-7000-8000-000000004574', '01920000-0000-7000-8000-0000000045e1', '01920000-0000-7000-8000-0000000045c4', null),
  ('01920000-0000-7000-8000-000000004575', '01920000-0000-7000-8000-0000000045e1', '01920000-0000-7000-8000-0000000045c5', null),
  ('01920000-0000-7000-8000-000000004576', '01920000-0000-7000-8000-0000000045e1', '01920000-0000-7000-8000-0000000045c6', null),
  ('01920000-0000-7000-8000-000000004577', '01920000-0000-7000-8000-0000000045e1', '01920000-0000-7000-8000-0000000045c7', null),
  ('01920000-0000-7000-8000-000000004578', '01920000-0000-7000-8000-0000000045e5', '01920000-0000-7000-8000-0000000045c1', now()),
  ('01920000-0000-7000-8000-000000004579', '01920000-0000-7000-8000-0000000045e2', '01920000-0000-7000-8000-0000000045c1', null),
  ('01920000-0000-7000-8000-00000000457a', '01920000-0000-7000-8000-0000000045e3', '01920000-0000-7000-8000-0000000045c1', null),
  ('01920000-0000-7000-8000-00000000457b', '01920000-0000-7000-8000-0000000045e4', '01920000-0000-7000-8000-0000000045c1', null),
  ('01920000-0000-7000-8000-00000000457c', '01920000-0000-7000-8000-0000000045e1', '01920000-0000-7000-8000-0000000045c8', null),
  ('01920000-0000-7000-8000-00000000457d', '01920000-0000-7000-8000-0000000045e1', '01920000-0000-7000-8000-0000000045c9', null);

-- ---------------------------------------------------------------------------
-- 1. El schema ruteo y los privilegios
-- ---------------------------------------------------------------------------
select is((select extnamespace::regnamespace::text from pg_extension where extname = 'pgrouting'), 'extensions',
          'pgRouting está en el schema extensions, como PostGIS');
select ok(exists (select 1 from pg_namespace where nspname = 'ruteo'), 'existe el schema ruteo');

select is((select relrowsecurity from pg_class where oid = t::regclass), true, 'RLS activada en ' || t)
  from unnest(array['ruteo.red', 'ruteo.nodo', 'ruteo.tramo']) t;
select is((select count(*)::int from pg_policies where schemaname = 'ruteo'), 0,
          'ninguna política en ruteo: la RLS cierra aunque se abra un grant por error');

select ok(not has_table_privilege(r, t, p), r || ' NO tiene ' || p || ' sobre ' || t)
  from unnest(array['anon', 'authenticated']) r,
       unnest(array['ruteo.red', 'ruteo.nodo', 'ruteo.tramo']) t,
       unnest(array['select', 'insert', 'update', 'delete']) p;
select ok(not has_schema_privilege(r, 'ruteo', 'usage'), r || ' NO tiene USAGE sobre el schema ruteo')
  from unnest(array['anon', 'authenticated']) r;
select ok(has_table_privilege('service_role', t, 'select'), 'service_role lee ' || t)
  from unnest(array['ruteo.red', 'ruteo.nodo', 'ruteo.tramo']) t;

select ok(not has_function_privilege(r, f, 'execute'), r || ' NO ejecuta ' || f)
  from unnest(array['anon', 'authenticated']) r,
       unnest(array['ruteo.cargar_red(uuid,jsonb,text,text[])', 'ruteo.cruce_mas_cercano(uuid,double precision,double precision)',
                    'ruteo.camino(uuid,bigint,bigint)', 'ruteo.dijkstra(text,bigint,bigint)',
                    'ruteo.exigir_punto(double precision,double precision)',
                    'ruteo.nombre_de_esquina(text,text)', 'public.ciudad_para_dibujar(uuid)']) f;
select ok(has_function_privilege('service_role', 'ruteo.cargar_red(uuid,jsonb,text,text[])', 'execute'),
          'service_role carga las calles');
select ok(has_function_privilege('service_role', 'public.ciudad_para_dibujar(uuid)', 'execute'),
          'service_role ejecuta la comprobación interna');

select ok(has_function_privilege('authenticated', f, 'execute'), 'authenticated ejecuta ' || f)
  from unnest(array['public.esquina_mas_cercana(uuid,double precision,double precision)',
                    'public.tramo_por_calles(uuid,double precision,double precision,double precision,double precision)',
                    'public.poligono_por_calles(uuid,jsonb)']) f;
select ok(not has_function_privilege('anon', f, 'execute'), 'anon NO ejecuta ' || f)
  from unnest(array['public.esquina_mas_cercana(uuid,double precision,double precision)',
                    'public.tramo_por_calles(uuid,double precision,double precision,double precision,double precision)',
                    'public.poligono_por_calles(uuid,jsonb)']) f;
select ok(not has_function_privilege('service_role', f, 'execute'),
          'service_role NO ejecuta ' || f || ' (sin JWT fallaría con 42501 igual)')
  from unnest(array['public.esquina_mas_cercana(uuid,double precision,double precision)',
                    'public.tramo_por_calles(uuid,double precision,double precision,double precision,double precision)',
                    'public.poligono_por_calles(uuid,jsonb)']) f;

select is((select pg_get_function_result('public.esquina_mas_cercana(uuid,double precision,double precision)'::regprocedure)),
          'TABLE(lon double precision, lat double precision, calle_a text, calle_b text, distancia_m double precision)',
          'esquina_mas_cercana(): la forma de la respuesta');
select is((select pg_get_function_result('public.tramo_por_calles(uuid,double precision,double precision,double precision,double precision)'::regprocedure)),
          'TABLE(orden integer, lon double precision, lat double precision)',
          'tramo_por_calles(): la forma de la respuesta');
select is((select pg_get_function_result('public.poligono_por_calles(uuid,jsonb)'::regprocedure)),
          'TABLE(poligono_geojson jsonb, esquinas jsonb)', 'poligono_por_calles(): la forma de la respuesta');

select is((select p.prosecdef from pg_proc p where p.oid = f::regprocedure), true, f || ' es SECURITY DEFINER')
  from unnest(array['public.esquina_mas_cercana(uuid,double precision,double precision)',
                    'public.tramo_por_calles(uuid,double precision,double precision,double precision,double precision)',
                    'public.poligono_por_calles(uuid,jsonb)', 'public.ciudad_para_dibujar(uuid)']) f;
select is((select p.proconfig from pg_proc p where p.oid = f::regprocedure), array['search_path=""'],
          f || ' fija search_path vacío')
  from unnest(array['public.esquina_mas_cercana(uuid,double precision,double precision)',
                    'public.tramo_por_calles(uuid,double precision,double precision,double precision,double precision)',
                    'public.poligono_por_calles(uuid,jsonb)', 'public.ciudad_para_dibujar(uuid)',
                    'ruteo.cargar_red(uuid,jsonb,text,text[])', 'ruteo.camino(uuid,bigint,bigint)']) f;
select is((select p.proconfig from pg_proc p where p.oid = 'ruteo.dijkstra(text,bigint,bigint)'::regprocedure),
          array['search_path=extensions'],
          'ruteo.dijkstra() es la única con search_path = extensions (pgRouting 3.4 llama sin calificar)');
select is((select p.prosecdef from pg_proc p where p.oid = 'ruteo.cargar_red(uuid,jsonb,text,text[])'::regprocedure), false,
          'ruteo.cargar_red() es SECURITY INVOKER: no presta permisos');

-- ---------------------------------------------------------------------------
-- 2. ruteo.cargar_red()
-- ---------------------------------------------------------------------------
create or replace function pg_temp.cargar(p_ciudad text, p_clave text) returns jsonb language sql as
$$ select ruteo.cargar_red(('01920000-0000-7000-8000-0000000045' || p_ciudad)::uuid,
                           (select doc from osm_doc where k = p_clave), 'pgTAP ' || p_clave) $$;

create temp table resumen (k text primary key, r jsonb) on commit drop;
insert into resumen select 'grilla', pg_temp.cargar('c1', 'grilla');
insert into resumen select 'ele', pg_temp.cargar('c2', 'ele');
insert into resumen select 'continuas', pg_temp.cargar('c3', 'continuas');
insert into resumen select 'rodeo', pg_temp.cargar('c4', 'rodeo');
insert into resumen select 'empate', pg_temp.cargar('c5', 'empate');
insert into resumen select 'atajos', pg_temp.cargar('c8', 'atajos');
insert into resumen select 'eco', pg_temp.cargar('c9', 'eco');

select is((select r - 'ciudad_id' from resumen where k = 'grilla'),
          '{"vias_en_archivo": 17, "vias": 10, "vias_descartadas": 7, "nodos": 21, "cruces": 17, "tramos": 28}'::jsonb,
          'cuadrícula: 17 vías en el archivo, 10 entran (8 de la cuadrícula + la cruz), 21 nodos, 17 cruces, 28 tramos');
select is((select r ->> 'ciudad_id' from resumen where k = 'grilla'), '01920000-0000-7000-8000-0000000045c1',
          'el resumen dice de qué ciudad es');
select is((select r - 'ciudad_id' from resumen where k = 'ele'),
          '{"vias_en_archivo": 6, "vias": 6, "vias_descartadas": 0, "nodos": 6, "cruces": 6, "tramos": 6}'::jsonb,
          'ciudad L: seis vías, seis nodos que son seis cruces, seis tramos');
select is((select r - 'ciudad_id' from resumen where k = 'continuas'),
          '{"vias_en_archivo": 8, "vias": 8, "vias_descartadas": 0, "nodos": 17, "cruces": 4, "tramos": 14}'::jsonb,
          'continuas: 17 nodos y solo 4 cruces (b, d, e, g)');

select is((select row(cargada_en is not null, fuente, vias, nodos, cruces, tramos)::text from ruteo.red
            where ciudad_id = '01920000-0000-7000-8000-0000000045c1'),
          '(t,"pgTAP grilla",10,21,17,28)', 'ruteo.red guarda cuándo, la fuente y los conteos');
select is((select count(*)::int from ruteo.red), 7, 'una fila de ruteo.red por ciudad cargada');

-- Cada vía de la cuadrícula se parte en los cruces: una calle de 4 nodos son 3 tramos.
select is((select count(*)::int from ruteo.tramo where ciudad_id = '01920000-0000-7000-8000-0000000045c1' and via_osm_id between 1000 and 1003), 12,
          'las cuatro calles de oeste a este quedan en 3 tramos cada una');
select is((select count(*)::int from ruteo.tramo where ciudad_id = '01920000-0000-7000-8000-0000000045c1' and via_osm_id between 2000 and 2003), 12,
          'las cuatro calles de norte a sur quedan en 3 tramos cada una');
select is((select count(*)::int from ruteo.tramo where via_osm_id in (3001, 3002)), 4,
          'la cruz aislada: 4 tramos (el nodo repetido seguido no hace un tramo de largo 0)');
select is((select count(*)::int from ruteo.tramo where largo_m = 0), 0, 'ningún tramo de largo 0');
select is((select count(*)::int from ruteo.tramo where via_osm_id between 4001 and 4007), 0,
          'senderos, pasajes de servicio, autopistas y vías rotas no entran');
select is((select count(*)::int from ruteo.nodo where osm_id in (1, 2, 3, 4, 5, 6, 7, 8, 9, 10)), 0,
          'los nodos de las vías rotas y los elementos que no son vías no entran');

-- El largo es el de la geometría, en metros.
select ok((select bool_and(abs(t.largo_m - extensions.st_length(extensions.geography(t.geom))) < 0.001)
             from ruteo.tramo t), 'largo_m es el largo geodésico de la geometría');
select ok((select bool_and(extensions.st_srid(geom) = 4326) from ruteo.tramo), 'geometrías en SRID 4326');
select ok((select bool_and(extensions.st_equals(extensions.st_startpoint(t.geom), o.geom)
                           and extensions.st_equals(extensions.st_endpoint(t.geom), d.geom))
             from ruteo.tramo t join ruteo.nodo o on o.id = t.origen join ruteo.nodo d on d.id = t.destino),
          'cada tramo va del nodo origen al nodo destino');
select ok((select bool_and(o.ciudad_id = t.ciudad_id and d.ciudad_id = t.ciudad_id)
             from ruteo.tramo t join ruteo.nodo o on o.id = t.origen join ruteo.nodo d on d.id = t.destino),
          'los nodos de un tramo son de su ciudad');

-- Qué es un cruce.
select is((select array[calle_a, calle_b] from ruteo.nodo
            where ciudad_id = '01920000-0000-7000-8000-0000000045c1' and es_cruce
              and geom = extensions.st_setsrid(extensions.st_makepoint(pg_temp.glon(1, 1), pg_temp.glat(1, 1)), 4326)),
          array['Aparicio', 'Garzón'], 'el cruce (1,1) es de Aparicio y Garzón, en orden alfabético');
select is((select array[calle_a, calle_b] from ruteo.nodo
            where ciudad_id = '01920000-0000-7000-8000-0000000045c1'
              and geom = extensions.st_setsrid(extensions.st_makepoint(pg_temp.glon(0, 0), pg_temp.glat(0, 0)), 4326)),
          array['Heredia', 'Pororó'], 'la esquina de la punta (0,0) también es un cruce: Heredia y Pororó');
select is((select count(*)::int from ruteo.nodo where ciudad_id = '01920000-0000-7000-8000-0000000045c1' and not es_cruce), 4,
          'las 4 puntas de la cruz aislada no son cruces (una sola calle)');
select is((select array[calle_a, calle_b] from ruteo.nodo n
            where n.ciudad_id = '01920000-0000-7000-8000-0000000045c3'
              and n.geom = extensions.st_setsrid(extensions.st_makepoint(
                    (pg_temp.pt(-56, -34.7, 2, 0) ->> 0)::double precision, (pg_temp.pt(-56, -34.7, 2, 0) ->> 1)::double precision), 4326)),
          array['Recta', null], 'c: dos vías con el mismo nombre que se unen NO son un cruce (pero sí un nodo)');
select is((select es_cruce from ruteo.nodo n
            where n.ciudad_id = '01920000-0000-7000-8000-0000000045c3'
              and n.geom = extensions.st_setsrid(extensions.st_makepoint(
                    (pg_temp.pt(-56, -34.7, 2, 0) ->> 0)::double precision, (pg_temp.pt(-56, -34.7, 2, 0) ->> 1)::double precision), 4326)),
          false, 'el nodo c no es cruce');
select is((select array_agg(calle_a || '/' || coalesce(calle_b, '-') order by calle_a) from ruteo.nodo
            where ciudad_id = '01920000-0000-7000-8000-0000000045c3' and es_cruce and calle_a is not null),
          array['Cruz Dos/Recta', 'Cruz Uno/Recta', 'Solo/-'],
          'cruces con nombre: Cruz Uno × Recta, Cruz Dos × Recta, y «Solo» con una vía sin nombre');
select is((select count(*)::int from ruteo.nodo
            where ciudad_id = '01920000-0000-7000-8000-0000000045c3' and es_cruce and calle_a is null and calle_b is null), 1,
          'dos vías sin nombre se cruzan: es un cruce sin nombres (calle_a y calle_b en null)');
select is((select count(*)::int from ruteo.nodo where calle_b is not null and calle_a is null), 0,
          'calle_b nunca viene sin calle_a');

-- Reemplazar: la misma red de nuevo no duplica nada; otra ciudad no se toca.
select is((select count(*)::int from ruteo.nodo where ciudad_id = '01920000-0000-7000-8000-0000000045c2'), 6, 'c2 tiene 6 nodos antes');
create temp table ids_antes on commit drop as
  select array_agg(id order by id) ids from ruteo.nodo where ciudad_id = '01920000-0000-7000-8000-0000000045c1';
select pg_temp.cargar('c1', 'grilla');
select is((select count(*)::int from ruteo.nodo where ciudad_id = '01920000-0000-7000-8000-0000000045c1'), 21,
          'volver a cargar la misma red deja 21 nodos, no 42');
select is((select count(*)::int from ruteo.tramo where ciudad_id = '01920000-0000-7000-8000-0000000045c1'), 28,
          'y 28 tramos');
select isnt((select array_agg(id order by id) from ruteo.nodo where ciudad_id = '01920000-0000-7000-8000-0000000045c1'),
            (select ids from ids_antes), 'los nodos son filas nuevas (reemplazo, no remiendo)');
select is((select count(*)::int from ruteo.nodo where ciudad_id = '01920000-0000-7000-8000-0000000045c2'), 6,
          'la red de otra ciudad no se toca');
select is((select count(*)::int from ruteo.red where ciudad_id = '01920000-0000-7000-8000-0000000045c1'), 1,
          'ruteo.red sigue con una fila por ciudad');

-- Un archivo que no sirve no deja a la ciudad sin calles.
select throws_ok($$ select ruteo.cargar_red('01920000-0000-7000-8000-0000000045c1', '{"elements": []}'::jsonb) $$,
                  '22023', 'El archivo no trae ninguna calle utilizable (vías de tipo trunk, primary, secondary, tertiary, unclassified, residential, living_street, pedestrian, road). No se cambió nada.',
                  'un archivo sin calles falla con el motivo');
select is((select count(*)::int from ruteo.nodo where ciudad_id = '01920000-0000-7000-8000-0000000045c1'), 21,
          'y la red que había queda como estaba (21 nodos)');
select is((select count(*)::int from ruteo.tramo where ciudad_id = '01920000-0000-7000-8000-0000000045c1'), 28,
          'y sus 28 tramos');
select throws_ok($$ select ruteo.cargar_red('01920000-0000-7000-8000-0000000045c1', '{"elements": [{"type":"way"}]}'::jsonb) $$,
                  '22023', null, 'una vía sin nodos ni geometría tampoco cuenta como calle');
select throws_ok($$ select ruteo.cargar_red('01920000-0000-7000-8000-0000000045c1', '{"foo": 1}'::jsonb) $$,
                  '22023', 'El archivo no es una respuesta de Overpass: falta la lista «elements». Descargalo con [out:json] y «out body geom;» (docs/calles-ruteo.md).',
                  'un JSON que no es de Overpass falla con cómo bajarlo');
select throws_ok($$ select ruteo.cargar_red('01920000-0000-7000-8000-0000000045c1', null) $$,
                  '22023', null, 'sin JSON falla');
select throws_ok($$ select ruteo.cargar_red('01920000-0000-7000-8000-0000000045c1', '{"elements": []}'::jsonb, null, array[]::text[]) $$,
                  '22023', 'Falta la lista de tipos de calle (highway) que entran en la red.', 'sin tipos de calle falla');
select throws_ok($$ select ruteo.cargar_red('01920000-0000-7000-8000-0000000045ff', '{"elements": []}'::jsonb) $$,
                  '22023', 'La ciudad 01920000-0000-7000-8000-0000000045ff no existe en el catálogo o está dada de baja. Cargala primero (docs/guia-carga-manual.md) y volvé a importar.',
                  'una ciudad que no existe falla, y dice qué hacer');
-- Aunque el archivo sea bueno: una ciudad dada de baja no recibe calles.
select throws_ok($$ select ruteo.cargar_red('01920000-0000-7000-8000-0000000045ca', (select doc from osm_doc where k = 'grilla')) $$,
                  '22023', 'La ciudad 01920000-0000-7000-8000-0000000045ca no existe en el catálogo o está dada de baja. Cargala primero (docs/guia-carga-manual.md) y volvé a importar.',
                  'una ciudad dada de baja tampoco');
select is((select count(*)::int from ruteo.red where ciudad_id = '01920000-0000-7000-8000-0000000045ca'), 0,
          'y no queda ninguna red para ella');
select throws_ok($$ select ruteo.cargar_red(null, '{"elements": []}'::jsonb) $$, '22023', null, 'sin ciudad falla');

-- Calles sin ningún cruce: tampoco se carga (no se podría enganchar ninguna esquina).
select throws_ok(format($q$ select ruteo.cargar_red('01920000-0000-7000-8000-0000000045c7', %L::jsonb) $q$,
                        jsonb_build_object('elements', jsonb_build_array(
                          pg_temp.via(9001, 'Sola', 'residential', '[[-56.5,-34.5],[-56.5,-34.501]]'::jsonb)))),
                  '22023', 'Las calles del archivo no tienen ningún cruce (dos calles con nombres distintos que se junten en un nodo). No se cambió nada.',
                  'una sola calle no tiene cruces');
select is((select count(*)::int from ruteo.red where ciudad_id = '01920000-0000-7000-8000-0000000045c7'), 0,
          'y la ciudad sigue sin red');

-- p_tipos: otra lista cambia qué entra (acá solo «service», la «Pasaje» suelta de la cuadrícula).
select throws_ok($$ select ruteo.cargar_red('01920000-0000-7000-8000-0000000045c7',
                                             (select doc from osm_doc where k = 'grilla'), null, array['service']) $$,
                  '22023', null, 'con otra lista de tipos entra otra cosa (una sola vía de servicio: sin cruces)');

-- ---------------------------------------------------------------------------
-- 3. esquina_mas_cercana()
-- ---------------------------------------------------------------------------
select pg_temp.actuar_como('01920000-0000-7000-8000-0000000045a1');

-- «Esquina a 20 m de un cruce → devuelve ese cruce con los dos nombres.»
select results_eq(
  format($q$ select lon, lat, calle_a, calle_b from public.esquina_mas_cercana(
              '01920000-0000-7000-8000-000000004571', %s, %s) $q$,
         pg_temp.glon(1, 1) + 20 / (111320 * cos(radians(34.9))), pg_temp.glat(1, 1)),
  format($q$ values (%s::double precision, %s::double precision, 'Aparicio'::text, 'Garzón'::text) $q$,
         pg_temp.glon(1, 1), pg_temp.glat(1, 1)),
  'a 20 m al este de un cruce: devuelve ese cruce, con sus coordenadas y los dos nombres');
select ok((select distancia_m between 19 and 21 from public.esquina_mas_cercana(
             '01920000-0000-7000-8000-000000004571', pg_temp.glon(1, 1) + 20 / (111320 * cos(radians(34.9))), pg_temp.glat(1, 1))),
          'y dice que quedó a unos 20 m');
select is((select distancia_m from public.esquina_mas_cercana(
             '01920000-0000-7000-8000-000000004571', pg_temp.glon(2, 2), pg_temp.glat(2, 2))),
          0::double precision, 'justo sobre el cruce: 0 m (una esquina ya enganchada se engancha a sí misma)');
select is((select calle_a || '/' || calle_b from public.esquina_mas_cercana(
             '01920000-0000-7000-8000-000000004571', pg_temp.glon(3, 3) - 0.00005, pg_temp.glat(3, 3) + 0.00005)),
          'Larrañaga/Yaro', 'la esquina de abajo a la derecha (3,3) es Larrañaga y Yaro');
select is((select distancia_m from public.esquina_mas_cercana(
             '01920000-0000-7000-8000-000000004571', pg_temp.glon(1, 1), pg_temp.glat(1, 1) + 0.0004)),
          44.4::double precision, 'la distancia sale en metros con un decimal (0,0004° de latitud ≈ 44 m)');

-- Cada uno de los 16 cruces se encuentra desde un punto cercano.
select is((select count(*)::int from generate_series(0, 3) c, generate_series(0, 3) r,
                  lateral public.esquina_mas_cercana('01920000-0000-7000-8000-000000004571',
                                                     pg_temp.glon(c, r) + 0.00002, pg_temp.glat(c, r) - 0.00002) e
            where e.lon = pg_temp.glon(c, r) and e.lat = pg_temp.glat(c, r)), 16,
          'los 16 cruces de la cuadrícula se enganchan desde un punto a unos 3 m');
select is((select count(*)::int from public.esquina_mas_cercana('01920000-0000-7000-8000-000000004571', -56.199, -34.899)), 1,
          'devuelve siempre una sola fila');

-- Sin tope de distancia: el más cercano de la ciudad, aunque quede lejos; el panel decide con distancia_m.
select ok((select distancia_m > 4000 from public.esquina_mas_cercana('01920000-0000-7000-8000-000000004571', -56.25, -34.95)),
          'un clic a kilómetros de las calles devuelve el cruce más cercano con su distancia (sin tope)');
-- El cruce de la cruz aislada solo se ofrece a quien clickea cerca de ahí.
select is((select calle_a || '/' || calle_b from public.esquina_mas_cercana('01920000-0000-7000-8000-000000004571', -56.1500, -34.8506)),
          'Aislada Este/Aislada Norte', 'la cruz aislada también es una esquina de la ciudad');
-- Las puntas que no son cruces no se ofrecen: el clic sobre la punta de «Aislada Norte» engancha al cruce del medio.
select is((select calle_a || '/' || calle_b from public.esquina_mas_cercana('01920000-0000-7000-8000-000000004571', -56.15, -34.85)),
          'Aislada Este/Aislada Norte', 'una punta sin cruce no es una esquina: engancha al cruce más cercano');

-- Nombres de la esquina: sin nombre y con medio nombre.
select results_eq(
  format($q$ select calle_a, calle_b from public.esquina_mas_cercana('01920000-0000-7000-8000-000000004573', %s, %s) $q$,
         (pg_temp.pt(-56, -34.7, 5, 0) ->> 0)::double precision, (pg_temp.pt(-56, -34.7, 5, 0) ->> 1)::double precision),
  $q$ values (null::text, null::text) $q$, 'un cruce de dos vías sin nombre: calle_a y calle_b en null');
select results_eq(
  format($q$ select calle_a, calle_b from public.esquina_mas_cercana('01920000-0000-7000-8000-000000004573', %s, %s) $q$,
         (pg_temp.pt(-56, -34.7, 7, 0) ->> 0)::double precision, (pg_temp.pt(-56, -34.7, 7, 0) ->> 1)::double precision),
  $q$ values ('Solo'::text, null::text) $q$, 'un cruce de una calle con nombre y otra sin: calle_b en null');

select pg_temp.actuar_como_servidor();
-- El más cercano en METROS, no en grados (c5: X a 85 m al este, Y a 90 m al norte).
select ok((select extensions.st_distance(extensions.geography(x.g), extensions.geography(p.g))
                < extensions.st_distance(extensions.geography(y.g), extensions.geography(p.g))
             from (select extensions.st_setsrid(extensions.st_makepoint(-56.4, -34.6), 4326) g) p,
                  (select geom g from ruteo.nodo where calle_a = 'X1' and es_cruce) x,
                  (select geom g from ruteo.nodo where calle_a = 'Y1' and es_cruce) y),
          'precondición: en metros X está más cerca de P que Y');
select ok((select extensions.st_distance(x.g, p.g) > extensions.st_distance(y.g, p.g)
             from (select extensions.st_setsrid(extensions.st_makepoint(-56.4, -34.6), 4326) g) p,
                  (select geom g from ruteo.nodo where calle_a = 'X1' and es_cruce) x,
                  (select geom g from ruteo.nodo where calle_a = 'Y1' and es_cruce) y),
          'precondición: en grados, Y parece más cerca (la distancia plana engaña)');
select pg_temp.actuar_como('01920000-0000-7000-8000-0000000045a1');
select is((select calle_a from public.esquina_mas_cercana('01920000-0000-7000-8000-000000004575', -56.4, -34.6)), 'X1',
          'engancha al más cercano en metros (X1/X2), no al más cercano en grados');

-- Los cruces de otra ciudad no cuentan, aunque queden más cerca: c9 tiene un cruce a 3,7 m del (1,1) de c1.
select pg_temp.actuar_como_servidor();
select ok((select extensions.st_distance(extensions.geography(e.geom), extensions.geography(c.geom)) between 3 and 5
             from (select geom from ruteo.nodo where ciudad_id = '01920000-0000-7000-8000-0000000045c9' and calle_a = 'Eco Dos' and es_cruce) e,
                  (select geom from ruteo.nodo where ciudad_id = '01920000-0000-7000-8000-0000000045c1' and calle_a = 'Aparicio' and calle_b = 'Garzón') c),
          'precondición: el cruce de Eco queda a unos 3,7 m del cruce (1,1) de la cuadrícula');
select pg_temp.actuar_como('01920000-0000-7000-8000-0000000045a1');
select is((select calle_a || '/' || calle_b from public.esquina_mas_cercana('01920000-0000-7000-8000-000000004571',
             pg_temp.r7(pg_temp.glon(1, 1) + 0.00004), pg_temp.glat(1, 1))),
          'Aparicio/Garzón', 'pidiendo c1 desde el cruce de Eco: engancha al de c1, no al de la ciudad vecina');
select is((select calle_a || '/' || calle_b from public.esquina_mas_cercana('01920000-0000-7000-8000-00000000457d',
             pg_temp.r7(pg_temp.glon(1, 1) + 0.00004), pg_temp.glat(1, 1))),
          'Eco Dos/Eco Uno', 'y pidiendo c9 desde el mismo punto, el de Eco');

-- Dos cruces exactamente a la misma distancia: gana el de menor id (siempre el mismo).
select pg_temp.actuar_como_servidor();
create temp table gemelos as
  select n.id, extensions.st_x(n.geom) as lon, extensions.st_y(n.geom) as lat,
         extensions.st_distance(extensions.geography(n.geom),
                                extensions.geography(extensions.st_setsrid(extensions.st_makepoint(-56.25, -34.95), 4326))) as d
    from ruteo.nodo n
   where n.ciudad_id = '01920000-0000-7000-8000-0000000045c9' and n.es_cruce and n.calle_a like 'Gemela%';
grant select on gemelos to authenticated;
select is((select count(*)::int from gemelos), 2, 'precondición: dos cruces gemelos');
select is((select count(distinct d)::int from gemelos), 1, 'precondición: a la misma distancia (exacta) de (-56,25, -34,95)');
select pg_temp.actuar_como('01920000-0000-7000-8000-0000000045a1');
select is((select lon from public.esquina_mas_cercana('01920000-0000-7000-8000-00000000457d', -56.25, -34.95)),
          (select lon from gemelos order by id limit 1), 'con dos cruces a igual distancia gana el de menor id');

-- calle_a y calle_b salen en orden por código de carácter (el mismo en cualquier base): «Zorrilla» antes que «arenal».
select is((select calle_a || '/' || calle_b from public.esquina_mas_cercana('01920000-0000-7000-8000-00000000457d', -56.35, -34.95)),
          'Zorrilla/arenal', 'calle_a y calle_b: orden por código de carácter, no el de la collation de la base');

-- Una ciudad sin calles cargadas dice qué hacer.
select throws_ok($$ select * from public.esquina_mas_cercana('01920000-0000-7000-8000-000000004576', -56, -33) $$,
                  'CZ015', 'Todavía no están cargadas las calles de esta ciudad. Pedile a un administrador que las cargue y volvé a intentar.',
                  'una ciudad sin calles cargadas: CZ015 con qué hacer');

-- Puntos que no sirven: CZ008 con qué hacer.
select throws_ok($$ select * from public.esquina_mas_cercana('01920000-0000-7000-8000-000000004571', 181, -34.9) $$,
                  'CZ008', 'El punto no está en el mapa (hace falta una longitud entre -180 y 180 y una latitud entre -90 y 90). Marcalo de nuevo.',
                  'longitud fuera del mapa');
select throws_ok($$ select * from public.esquina_mas_cercana('01920000-0000-7000-8000-000000004571', -56.2, -91) $$,
                  'CZ008', null, 'latitud fuera del mapa');
select throws_ok($$ select * from public.esquina_mas_cercana('01920000-0000-7000-8000-000000004571', null, -34.9) $$,
                  'CZ008', null, 'sin longitud');
select throws_ok($$ select * from public.esquina_mas_cercana('01920000-0000-7000-8000-000000004571', -56.2, null) $$,
                  'CZ008', null, 'sin latitud');
select throws_ok($$ select * from public.esquina_mas_cercana('01920000-0000-7000-8000-000000004571', 'NaN'::double precision, -34.9) $$,
                  'CZ008', null, 'NaN no es una longitud');
select throws_ok($$ select * from public.esquina_mas_cercana('01920000-0000-7000-8000-000000004571', 'Infinity'::double precision, -34.9) $$,
                  'CZ008', null, 'infinito tampoco');

-- ---------------------------------------------------------------------------
-- 4. tramo_por_calles()
-- ---------------------------------------------------------------------------
-- «Dos esquinas sobre la misma calle → el tramo sigue la calle» (Heredia, de (0,0) a (3,0)).
select is((select array_agg(orden order by orden) from public.tramo_por_calles(
             '01920000-0000-7000-8000-000000004571', pg_temp.glon(0, 0), pg_temp.glat(0, 0), pg_temp.glon(3, 0), pg_temp.glat(3, 0))),
          array[1, 2, 3, 4], 'dos esquinas sobre la misma calle: 4 puntos numerados de 1 a 4');
select is((select array_agg(lon order by orden) from public.tramo_por_calles(
             '01920000-0000-7000-8000-000000004571', pg_temp.glon(0, 0), pg_temp.glat(0, 0), pg_temp.glon(3, 0), pg_temp.glat(3, 0))),
          array[pg_temp.glon(0, 0), pg_temp.glon(1, 0), pg_temp.glon(2, 0), pg_temp.glon(3, 0)],
          'el tramo pasa por los cruces de Heredia en orden (longitudes)');
select is((select array_agg(lat order by orden) from public.tramo_por_calles(
             '01920000-0000-7000-8000-000000004571', pg_temp.glon(0, 0), pg_temp.glat(0, 0), pg_temp.glon(3, 0), pg_temp.glat(3, 0))),
          array[pg_temp.glat(0, 0), pg_temp.glat(1, 0), pg_temp.glat(2, 0), pg_temp.glat(3, 0)],
          'y por sus latitudes');
-- «Heredia» tiene oneway=yes y el sentido de circulación se ignora: de este a oeste también.
select is((select array_agg(lon order by orden) from public.tramo_por_calles(
             '01920000-0000-7000-8000-000000004571', pg_temp.glon(3, 0), pg_temp.glat(3, 0), pg_temp.glon(0, 0), pg_temp.glat(0, 0))),
          array[pg_temp.glon(3, 0), pg_temp.glon(2, 0), pg_temp.glon(1, 0), pg_temp.glon(0, 0)],
          'Heredia es de un solo sentido y se recorre al revés igual: el colportor camina');
-- Una columna.
select is((select array_agg(lat order by orden) from public.tramo_por_calles(
             '01920000-0000-7000-8000-000000004571', pg_temp.glon(2, 0), pg_temp.glat(2, 0), pg_temp.glon(2, 3), pg_temp.glat(2, 3))),
          array[pg_temp.glat(2, 0), pg_temp.glat(2, 1), pg_temp.glat(2, 2), pg_temp.glat(2, 3)],
          'bajando por Charrúa, de (2,0) a (2,3)');

-- Los extremos se enganchan: desde puntos a unos metros de los cruces da lo mismo.
select is((select array_agg(lon order by orden) from public.tramo_por_calles(
             '01920000-0000-7000-8000-000000004571', pg_temp.glon(0, 0) + 0.00003, pg_temp.glat(0, 0) - 0.00003,
             pg_temp.glon(3, 0) - 0.00002, pg_temp.glat(3, 0) + 0.00002)),
          array[pg_temp.glon(0, 0), pg_temp.glon(1, 0), pg_temp.glon(2, 0), pg_temp.glon(3, 0)],
          'los dos puntos se enganchan al cruce más cercano antes de buscar el camino');

-- Mismo cruce: un solo punto.
select results_eq(
  format($q$ select orden, lon, lat from public.tramo_por_calles('01920000-0000-7000-8000-000000004571', %s, %s, %s, %s) $q$,
         pg_temp.glon(1, 2), pg_temp.glat(1, 2), pg_temp.glon(1, 2) + 0.00001, pg_temp.glat(1, 2)),
  format($q$ values (1, %s::double precision, %s::double precision) $q$, pg_temp.glon(1, 2), pg_temp.glat(1, 2)),
  'dos puntos que caen en el mismo cruce: un solo punto');

-- El más corto: de (0,0) a (2,2) hay seis recorridos en escalera; se elige el de menor largo.
create temp table cam on commit drop as
  select t.orden, t.lon, t.lat from public.tramo_por_calles(
           '01920000-0000-7000-8000-000000004571', pg_temp.glon(0, 0), pg_temp.glat(0, 0), pg_temp.glon(2, 2), pg_temp.glat(2, 2)) t;
select is((select count(*)::int from cam), 5, 'de (0,0) a (2,2) por la cuadrícula: 5 puntos (4 cuadras)');
select ok((select orden = 1 and lon = pg_temp.glon(0, 0) and lat = pg_temp.glat(0, 0) from cam where orden = 1), 'empieza en el primer cruce');
select ok((select lon = pg_temp.glon(2, 2) and lat = pg_temp.glat(2, 2) from cam where orden = 5), 'y termina en el segundo');
-- Largo del camino devuelto = el mínimo de los seis recorridos en escalera, calculados a mano por geography.
create or replace function pg_temp.d(c1 integer, r1 integer, c2 integer, r2 integer) returns double precision
language sql immutable as $$
  select extensions.st_distance(
    extensions.geography(extensions.st_setsrid(extensions.st_makepoint(pg_temp.glon(c1, r1), pg_temp.glat(c1, r1)), 4326)),
    extensions.geography(extensions.st_setsrid(extensions.st_makepoint(pg_temp.glon(c2, r2), pg_temp.glat(c2, r2)), 4326))) $$;
select ok((select abs((select sum(extensions.st_distance(extensions.geography(extensions.st_setsrid(extensions.st_makepoint(a.lon, a.lat), 4326)),
                                                           extensions.geography(extensions.st_setsrid(extensions.st_makepoint(b.lon, b.lat), 4326))))
                         from cam a join cam b on b.orden = a.orden + 1)
                  - least(
                      -- E E S S, E S E S, E S S E, S E E S, S E S E, S S E E (cada cuadra entre cruces vecinos)
                      pg_temp.d(0,0,1,0) + pg_temp.d(1,0,2,0) + pg_temp.d(2,0,2,1) + pg_temp.d(2,1,2,2),
                      pg_temp.d(0,0,1,0) + pg_temp.d(1,0,1,1) + pg_temp.d(1,1,2,1) + pg_temp.d(2,1,2,2),
                      pg_temp.d(0,0,1,0) + pg_temp.d(1,0,1,1) + pg_temp.d(1,1,1,2) + pg_temp.d(1,2,2,2),
                      pg_temp.d(0,0,0,1) + pg_temp.d(0,1,1,1) + pg_temp.d(1,1,2,1) + pg_temp.d(2,1,2,2),
                      pg_temp.d(0,0,0,1) + pg_temp.d(0,1,1,1) + pg_temp.d(1,1,1,2) + pg_temp.d(1,2,2,2),
                      pg_temp.d(0,0,0,1) + pg_temp.d(0,1,0,2) + pg_temp.d(0,2,1,2) + pg_temp.d(1,2,2,2))) < 0.01),
          'el camino devuelto es el más corto de los seis recorridos en escalera');
select pg_temp.actuar_como_servidor();
select ok((select bool_and(exists (select 1 from ruteo.nodo n
                                     where extensions.st_x(n.geom) = c.lon and extensions.st_y(n.geom) = c.lat and n.es_cruce))
             from cam c), 'cada punto del camino es un cruce de la red (la cuadrícula no tiene puntos intermedios)');

-- El largo que devuelve ruteo.camino() es el de una búsqueda sobre toda la red (el rectángulo no cambia el resultado).
select ok((select bool_and(abs(k.largo_m - f.agg) < 0.001) from (
             select c.largo_m, a.id as a_id, b.id as b_id
               from ruteo.nodo a join ruteo.nodo b on b.id > a.id and b.ciudad_id = a.ciudad_id,
                    lateral ruteo.camino(a.ciudad_id, a.id, b.id) c
              where a.ciudad_id = '01920000-0000-7000-8000-0000000045c1' and a.es_cruce and b.es_cruce
                and a.calle_a in ('Aparicio', 'Heredia', 'Larrañaga')) k,
             lateral (select max(d.agg_cost) agg from ruteo.dijkstra(
                        'select id, origen as source, destino as target, largo_m as cost from ruteo.tramo where ciudad_id = ''01920000-0000-7000-8000-0000000045c1''',
                        k.a_id, k.b_id) d) f
            where f.agg is not null),
          'ruteo.camino() mide lo mismo que pgr_dijkstra sobre toda la ciudad, para muchos pares de cruces');
select is((select count(*)::int from ruteo.nodo a join ruteo.nodo b on b.id > a.id and b.ciudad_id = a.ciudad_id,
                  lateral ruteo.camino(a.ciudad_id, a.id, b.id) c
            where a.ciudad_id = '01920000-0000-7000-8000-0000000045c1' and a.es_cruce and b.es_cruce
              and a.calle_a not like 'Aislada%' and b.calle_a not like 'Aislada%'), 120,
          'toda pareja de los 16 cruces de la cuadrícula tiene camino (120 parejas)');

select pg_temp.actuar_como('01920000-0000-7000-8000-0000000045a1');
-- Sin camino: la cruz aislada no se conecta con la cuadrícula (CZ016, con las dos esquinas por su nombre).
select throws_ok($$ select * from public.tramo_por_calles('01920000-0000-7000-8000-000000004571',
                      -56.15, -34.8505, -56.2, -34.9) $$,
                  'CZ016', 'No hay un camino por las calles entre «Aislada Este y Aislada Norte» y «Heredia y Pororó». Elegí otra esquina que esté sobre la misma red de calles.',
                  'dos esquinas de partes de la red que no se tocan: CZ016 con sus nombres');
select throws_ok($$ select * from public.tramo_por_calles('01920000-0000-7000-8000-000000004571',
                      -56.2, -34.9, -56.15, -34.8505) $$,
                  'CZ016', null, 'y al revés');

-- Un camino que sale del rectángulo de búsqueda (c4): 46 m en línea recta, 3,4 km por las calles.
select is((select count(*)::int from public.tramo_por_calles('01920000-0000-7000-8000-000000004574', -56.3, -34.8, -56.2995, -34.8)), 4,
          'Rodeo: de la punta de una calle a la de la paralela, por el fondo (4 puntos)');
select ok((select abs(sum(d) - 3 * 1e3 * 1.1) < 400 from (
             select extensions.st_distance(extensions.geography(extensions.st_setsrid(extensions.st_makepoint(a.lon, a.lat), 4326)),
                                           extensions.geography(extensions.st_setsrid(extensions.st_makepoint(b.lon, b.lat), 4326))) d
               from public.tramo_por_calles('01920000-0000-7000-8000-000000004574', -56.3, -34.8, -56.2995, -34.8) a
               join public.tramo_por_calles('01920000-0000-7000-8000-000000004574', -56.3, -34.8, -56.2995, -34.8) b on b.orden = a.orden + 1) x),
          'y mide unos 3,4 km: se buscó fuera del rectángulo de los dos puntos');
select is((select array_agg(lat order by orden) from public.tramo_por_calles('01920000-0000-7000-8000-000000004574', -56.3, -34.8, -56.2995, -34.8)),
          array[-34.8, -34.815, -34.815, -34.8]::double precision[], 'baja por Calle A, cruza por el Fondo y sube por Calle B');

-- Atajos (c8): el camino más corto sale del rectángulo de búsqueda (o queda justo afuera). El resultado es el
-- mismo que buscando en toda la ciudad: la prueba de «más corto» no se contenta con lo que hay adentro.
select is((select array_agg(lon order by orden) || array_agg(lat order by orden) from public.tramo_por_calles(
             '01920000-0000-7000-8000-00000000457c', -56.5, -34.5, -56.499, -34.5)),
          array[-56.5, -56.5, -56.499, -56.499, -34.5, -34.489, -34.489, -34.5]::double precision[],
          'Atajos 1: A y B a 92 m; el recorrido por adentro mide 4,3 km, el atajo por el norte 2,5 km: va por el atajo');
select is((select array_agg(lat order by orden) from public.tramo_por_calles(
             '01920000-0000-7000-8000-00000000457c', -56.499, -34.5, -56.5, -34.5)),
          array[-34.5, -34.489, -34.489, -34.5]::double precision[], 'y de B a A, el mismo atajo');
select is((select array_agg(lon order by orden) || array_agg(lat order by orden) from public.tramo_por_calles(
             '01920000-0000-7000-8000-00000000457c', -56.4, -34.5, -56.397, -34.5)),
          array[-56.4, -56.4, -56.397, -56.397, -34.5, -34.499, -34.499, -34.5]::double precision[],
          'Atajos 2: un techo de 497 m a 111 m al norte gana a un zigzag de 624 m que cabe en el rectángulo');
select is((select array_agg(lon order by orden) || array_agg(lat order by orden) from public.tramo_por_calles(
             '01920000-0000-7000-8000-00000000457c', -56.3, -34.5, -56.3, -34.503)),
          array[-56.3, -56.2988, -56.2988, -56.3, -34.5, -34.5, -34.503, -34.503]::double precision[],
          'Atajos 3: lo mismo hacia el este (553 m contra un zigzag de 648 m)');

-- Continuas (c3): el camino pasa por el nodo c, que une dos vías con el mismo nombre y no es un cruce.
select is((select count(*)::int from public.tramo_por_calles('01920000-0000-7000-8000-000000004573',
             (pg_temp.pt(-56, -34.7, 1, 0) ->> 0)::double precision, (pg_temp.pt(-56, -34.7, 1, 0) ->> 1)::double precision,
             (pg_temp.pt(-56, -34.7, 3, 0) ->> 0)::double precision, (pg_temp.pt(-56, -34.7, 3, 0) ->> 1)::double precision)), 3,
          'de Cruz Uno a Cruz Dos por Recta: tres puntos, pasando por el nodo donde se unen las dos vías de Recta');

-- Puntos que no sirven.
select throws_ok($$ select * from public.tramo_por_calles('01920000-0000-7000-8000-000000004571', 200, -34.9, -56.2, -34.9) $$,
                  'CZ008', null, 'el punto de partida fuera del mapa');
select throws_ok($$ select * from public.tramo_por_calles('01920000-0000-7000-8000-000000004571', -56.2, -34.9, -56.2, 95) $$,
                  'CZ008', null, 'el punto de llegada fuera del mapa');
select throws_ok($$ select * from public.tramo_por_calles('01920000-0000-7000-8000-000000004571', null, -34.9, -56.2, -34.9) $$,
                  'CZ008', null, 'sin punto de partida');
select throws_ok($$ select * from public.tramo_por_calles('01920000-0000-7000-8000-000000004571', -56.2, -34.9, -56.2, null) $$,
                  'CZ008', null, 'sin punto de llegada');

-- ---------------------------------------------------------------------------
-- 5. poligono_por_calles()
-- ---------------------------------------------------------------------------
-- «Cuatro esquinas en L → polígono válido y cerrado» (c2): se marcan P1, P2, P4 y P6; los tramos
-- siguen las calles por P3 y P5 y el borde da la L de seis esquinas.
create or replace function pg_temp.l(x numeric, y numeric) returns jsonb language sql immutable as
$$ select jsonb_build_object('lon', pg_temp.r7(-56.1 + 0.001 * x), 'lat', pg_temp.r7(-34.8 - 0.001 * y)) $$;

create temp table l_ok on commit drop as
  select p.poligono_geojson, p.esquinas
    from public.poligono_por_calles('01920000-0000-7000-8000-000000004572',
           jsonb_build_array(pg_temp.l(0, 0), pg_temp.l(3, 0), pg_temp.l(1, 1), pg_temp.l(0, 3))) p;

select is((select poligono_geojson ->> 'type' from l_ok), 'Polygon', 'cuatro esquinas en L: un Polygon GeoJSON');
select is((select jsonb_array_length(poligono_geojson -> 'coordinates') from l_ok), 1, 'con un solo anillo (sin huecos)');
select is((select jsonb_array_length(poligono_geojson -> 'coordinates' -> 0) from l_ok), 7,
          'de 6 esquinas más la que lo cierra: 7 puntos');
select is((select poligono_geojson -> 'coordinates' -> 0 -> 0 from l_ok), (select poligono_geojson -> 'coordinates' -> 0 -> 6 from l_ok),
          'cerrado: el último punto repite el primero');
select is((select poligono_geojson -> 'coordinates' -> 0 -> 0 from l_ok),
          jsonb_build_array((pg_temp.l(0, 0) ->> 'lon')::double precision, (pg_temp.l(0, 0) ->> 'lat')::double precision),
          'y se cierra en la esquina 1');
select is((select public.zona_problema_de_forma(poligono_geojson) from l_ok), null, 'lo valida zona_problema_de_forma(): válido');
select ok((select extensions.st_equals(public.zona_geometria(poligono_geojson),
            extensions.st_setsrid(extensions.st_makepolygon(extensions.st_makeline(array[
              extensions.st_makepoint((pg_temp.l(0, 0) ->> 'lon')::double precision, (pg_temp.l(0, 0) ->> 'lat')::double precision),
              extensions.st_makepoint((pg_temp.l(3, 0) ->> 'lon')::double precision, (pg_temp.l(3, 0) ->> 'lat')::double precision),
              extensions.st_makepoint((pg_temp.l(3, 1) ->> 'lon')::double precision, (pg_temp.l(3, 1) ->> 'lat')::double precision),
              extensions.st_makepoint((pg_temp.l(1, 1) ->> 'lon')::double precision, (pg_temp.l(1, 1) ->> 'lat')::double precision),
              extensions.st_makepoint((pg_temp.l(1, 3) ->> 'lon')::double precision, (pg_temp.l(1, 3) ->> 'lat')::double precision),
              extensions.st_makepoint((pg_temp.l(0, 3) ->> 'lon')::double precision, (pg_temp.l(0, 3) ->> 'lat')::double precision),
              extensions.st_makepoint((pg_temp.l(0, 0) ->> 'lon')::double precision, (pg_temp.l(0, 0) ->> 'lat')::double precision)])), 4326))
            from l_ok), 'el borde es exactamente la L: pasa por P3 y P5 aunque no se marcaron, siguiendo las calles');
select ok((select extensions.st_area(extensions.geography(public.zona_geometria(poligono_geojson))) > 30000 from l_ok),
          'la L encierra un área (más de 3 hectáreas)');

-- Las esquinas enganchadas, listas para p_vertices de guardar_zona().
select is((select jsonb_array_length(esquinas) from l_ok), 4, 'devuelve las 4 esquinas marcadas');
select is((select array_agg(k order by k) from (select distinct jsonb_object_keys(e) k from l_ok, jsonb_array_elements(esquinas) e) x),
          array['calle_a', 'calle_b', 'lat', 'lon', 'orden'], 'con las claves que lee guardar_zona(): orden, lon, lat, calle_a, calle_b');
select is((select array_agg((e ->> 'orden')::int order by (e ->> 'orden')::int) from l_ok, jsonb_array_elements(esquinas) e),
          array[1, 2, 3, 4], 'numeradas de 1 a 4 en el orden en que se marcaron');
select is((select esquinas -> 2 ->> 'calle_a' || '/' || (esquinas -> 2 ->> 'calle_b') from l_ok), 'Alta/Interior',
          'la esquina 3 (P4) es Alta e Interior');
select is((select esquinas -> 3 ->> 'calle_a' || '/' || (esquinas -> 3 ->> 'calle_b') from l_ok), 'Baja/Oeste',
          'la esquina 4 (P6) es Baja y Oeste');

-- Marcar sin enganchar o con lo que devolvió esquina_mas_cercana() da el mismo polígono; el orden inverso, la misma zona.
select is((select poligono_geojson from public.poligono_por_calles('01920000-0000-7000-8000-000000004572',
             jsonb_build_array(jsonb_build_object('lon', -56.1 + 0.00002, 'lat', -34.8 - 0.00003),
                               jsonb_build_object('lon', -56.1 + 0.00298, 'lat', -34.8 + 0.00001),
                               jsonb_build_object('lon', -56.1 + 0.00101, 'lat', -34.8 - 0.00102),
                               jsonb_build_object('lon', -56.1 - 0.00004, 'lat', -34.8 - 0.00299)))),
          (select poligono_geojson from l_ok), 'clics a unos metros de las esquinas: el mismo polígono');
select is((select poligono_geojson from public.poligono_por_calles('01920000-0000-7000-8000-000000004572',
             (select jsonb_agg(jsonb_build_object('lon', e -> 'lon', 'lat', e -> 'lat', 'orden', e -> 'orden', 'calle_a', e -> 'calle_a') order by (e ->> 'orden')::int)
                from l_ok, jsonb_array_elements(esquinas) e))),
          (select poligono_geojson from l_ok), 'las esquinas que devolvió se pueden volver a mandar (las claves de más se ignoran)');
select ok((select extensions.st_equals(public.zona_geometria(a.poligono_geojson), public.zona_geometria(b.poligono_geojson))
             from l_ok a, public.poligono_por_calles('01920000-0000-7000-8000-000000004572',
                    jsonb_build_array(pg_temp.l(0, 3), pg_temp.l(1, 1), pg_temp.l(3, 0), pg_temp.l(0, 0))) b),
          'marcadas al revés dan la misma zona');
select is((select poligono_geojson from public.poligono_por_calles('01920000-0000-7000-8000-000000004572',
             jsonb_build_array(pg_temp.l(0, 0), pg_temp.l(3, 0), pg_temp.l(3, 0), pg_temp.l(1, 1), pg_temp.l(0, 3), pg_temp.l(0, 0)))),
          (select poligono_geojson from l_ok), 'una esquina repetida seguida y la última igual a la primera no agregan tramos');
select is((select jsonb_array_length(esquinas) from public.poligono_por_calles('01920000-0000-7000-8000-000000004572',
             jsonb_build_array(pg_temp.l(0, 0), pg_temp.l(3, 0), pg_temp.l(3, 0), pg_temp.l(1, 1), pg_temp.l(0, 3), pg_temp.l(0, 0)))), 6,
          'pero se devuelven las 6 esquinas marcadas, en su orden');

-- Un cuadrado de la cuadrícula (c1), por tramos alineados: sin empates.
create temp table z1 on commit drop as
  select * from public.poligono_por_calles('01920000-0000-7000-8000-000000004571', jsonb_build_array(
    jsonb_build_object('lon', pg_temp.glon(0, 0), 'lat', pg_temp.glat(0, 0)),
    jsonb_build_object('lon', pg_temp.glon(1, 0), 'lat', pg_temp.glat(1, 0)),
    jsonb_build_object('lon', pg_temp.glon(1, 2), 'lat', pg_temp.glat(1, 2)),
    jsonb_build_object('lon', pg_temp.glon(0, 2), 'lat', pg_temp.glat(0, 2))));
create temp table z2 on commit drop as
  select * from public.poligono_por_calles('01920000-0000-7000-8000-000000004571', jsonb_build_array(
    jsonb_build_object('lon', pg_temp.glon(1, 0), 'lat', pg_temp.glat(1, 0)),
    jsonb_build_object('lon', pg_temp.glon(2, 0), 'lat', pg_temp.glat(2, 0)),
    jsonb_build_object('lon', pg_temp.glon(2, 2), 'lat', pg_temp.glat(2, 2)),
    jsonb_build_object('lon', pg_temp.glon(1, 2), 'lat', pg_temp.glat(1, 2))));
select is((select jsonb_array_length(poligono_geojson -> 'coordinates' -> 0) from z1), 7,
          'una zona de 1×2 cuadras: 6 cruces en el borde + el cierre = 7 puntos');
select is((select public.zona_problema_de_forma(poligono_geojson) from z1), null, 'z1 es válida');
select is((select public.zona_problema_de_forma(poligono_geojson) from z2), null, 'z2 es válida');
-- «Dos zonas vecinas que usan las mismas esquinas → comparten borde sin superponerse.»
select ok((select extensions.st_area(extensions.st_intersection(public.zona_geometria(a.poligono_geojson), public.zona_geometria(b.poligono_geojson))) = 0
             from z1 a, z2 b), 'dos zonas vecinas con las mismas esquinas no se superponen (la intersección no tiene área)');
select ok((select abs(extensions.st_length(extensions.geography(extensions.st_intersection(public.zona_geometria(a.poligono_geojson), public.zona_geometria(b.poligono_geojson))))
                      - (pg_temp.d(1, 0, 1, 1) + pg_temp.d(1, 1, 1, 2))) < 0.01
             from z1 a, z2 b), 'comparten exactamente el borde de Aparicio entre las dos esquinas (las dos cuadras)');
select ok((select extensions.st_touches(public.zona_geometria(a.poligono_geojson), public.zona_geometria(b.poligono_geojson))
             from z1 a, z2 b), 'se tocan solo por el borde');

-- Un borde que vuelve sobre una calle no es una zona (CZ008, como guardar_zona()).
create or replace function pg_temp.mensaje(p_sql text) returns text language plpgsql as $$
begin
  execute p_sql;
  return null;
exception when others then
  return sqlerrm;
end $$;

create temp table spike_json on commit drop as
  select jsonb_build_array(jsonb_build_object('lon', pg_temp.glon(0, 0), 'lat', pg_temp.glat(0, 0)),
                           jsonb_build_object('lon', pg_temp.glon(3, 0), 'lat', pg_temp.glat(3, 0)),
                           jsonb_build_object('lon', pg_temp.glon(1, 0), 'lat', pg_temp.glat(1, 0))) j;
select throws_ok(format($q$ select * from public.poligono_por_calles('01920000-0000-7000-8000-000000004571', %L::jsonb) $q$,
                        (select j from spike_json)),
                  'CZ008', null, 'tres esquinas sobre la misma calle: el recorrido vuelve sobre sí mismo');
select matches(pg_temp.mensaje(format($q$ select * from public.poligono_por_calles('01920000-0000-7000-8000-000000004571', %L::jsonb) $q$,
                                      (select j from spike_json))),
               '^El borde por las calles no forma una zona: .+\. Mové o quitá una esquina para que el recorrido no se cruce ni vuelva sobre una calle\.$',
               'y el aviso dice por qué no es una zona y qué hacer');

-- Esquinas que no sirven: CZ008 con qué hacer.
select throws_ok(format($q$ select * from public.poligono_por_calles('01920000-0000-7000-8000-000000004572', %L::jsonb) $q$,
                        jsonb_build_array(pg_temp.l(0, 0), pg_temp.l(3, 0))),
                  'CZ008', 'Una zona por esquinas necesita al menos 3 esquinas (tiene 2). Marcá más esquinas en el mapa.',
                  'con 2 esquinas no se arma una zona');
select throws_ok($$ select * from public.poligono_por_calles('01920000-0000-7000-8000-000000004572', '[]'::jsonb) $$,
                  'CZ008', 'Una zona por esquinas necesita al menos 3 esquinas (tiene 0). Marcá más esquinas en el mapa.',
                  'ni con la lista vacía');
select throws_ok(format($q$ select * from public.poligono_por_calles('01920000-0000-7000-8000-000000004572', %L::jsonb) $q$,
                        jsonb_build_array(pg_temp.l(0, 0), pg_temp.l(0, 0), pg_temp.l(3, 0))),
                  'CZ008', 'Una zona por esquinas necesita al menos 3 esquinas en lugares distintos y hay 2. Marcá las esquinas que faltan en el mapa.',
                  '3 clics pero solo 2 lugares distintos (una esquina repetida)');
select throws_ok(format($q$ select * from public.poligono_por_calles('01920000-0000-7000-8000-000000004572', %L::jsonb) $q$,
                        jsonb_build_array(pg_temp.l(0, 0), pg_temp.l(3, 0), pg_temp.l(0, 0))),
                  'CZ008', null, 'ir y volver a la primera tampoco suma una esquina');
select throws_ok(format($q$ select * from public.poligono_por_calles('01920000-0000-7000-8000-000000004572', %L::jsonb) $q$,
                        (select jsonb_agg(pg_temp.l(0, 0)) from generate_series(1, 101))),
                  'CZ008', 'Una zona por esquinas puede tener hasta 100 esquinas y marcaste 101. Dividí el área en varias zonas.',
                  'más de 100 esquinas: el tope técnico');
select is((select poligono_geojson from public.poligono_por_calles('01920000-0000-7000-8000-000000004572',
             (select jsonb_agg(pg_temp.l(0, 0)) || jsonb_build_array(pg_temp.l(3, 0), pg_temp.l(1, 1), pg_temp.l(0, 3)) from generate_series(1, 97)))),
          (select poligono_geojson from l_ok), 'con exactamente 100 esquinas (97 repetidas de la primera) se arma igual');
select throws_ok($$ select * from public.poligono_por_calles('01920000-0000-7000-8000-000000004572', '{"lon": -56.1, "lat": -34.8}'::jsonb) $$,
                  'CZ008', 'Las esquinas tienen que ser una lista de puntos con longitud y latitud. Volvé a marcarlas en el mapa.',
                  'un objeto en vez de una lista de esquinas');
select throws_ok($$ select * from public.poligono_por_calles('01920000-0000-7000-8000-000000004572', null) $$,
                  'CZ008', null, 'sin esquinas (null)');
select throws_ok($$ select * from public.poligono_por_calles('01920000-0000-7000-8000-000000004572',
                      '[{"lon": -56.1, "lat": -34.8}, {"lon": -56.099}, {"lon": -56.098, "lat": -34.8}]'::jsonb) $$,
                  'CZ008', 'La esquina 2 no tiene longitud y latitud. Volvé a marcarla.', 'una esquina sin latitud');
select throws_ok($$ select * from public.poligono_por_calles('01920000-0000-7000-8000-000000004572',
                      '[{"lon": "-56.1", "lat": "-34.8"}, {"lon": -56.099, "lat": -34.8}, {"lon": -56.098, "lat": -34.8}]'::jsonb) $$,
                  'CZ008', 'La esquina 1 no tiene longitud y latitud. Volvé a marcarla.', 'una esquina con la posición como texto');
select throws_ok($$ select * from public.poligono_por_calles('01920000-0000-7000-8000-000000004572',
                      '[{"lon": -56.1, "lat": -34.8}, {"lon": -56.099, "lat": -34.8}, [1, 2]]'::jsonb) $$,
                  'CZ008', 'La esquina 3 no tiene longitud y latitud. Volvé a marcarla.', 'una esquina que no es un objeto');
select throws_ok($$ select * from public.poligono_por_calles('01920000-0000-7000-8000-000000004572',
                      '[{"lon": -56.1, "lat": -34.8}, {"lon": 181, "lat": -34.8}, {"lon": -56.098, "lat": -34.8}]'::jsonb) $$,
                  'CZ008', 'El punto no está en el mapa (hace falta una longitud entre -180 y 180 y una latitud entre -90 y 90). Marcalo de nuevo.',
                  'una esquina fuera del mapa');

-- Una esquina en una parte de la red que no se toca con el resto: CZ016, con los nombres.
select throws_ok(format($q$ select * from public.poligono_por_calles('01920000-0000-7000-8000-000000004571', %L::jsonb) $q$,
                        jsonb_build_array(jsonb_build_object('lon', pg_temp.glon(0, 0), 'lat', pg_temp.glat(0, 0)),
                                          jsonb_build_object('lon', pg_temp.glon(1, 0), 'lat', pg_temp.glat(1, 0)),
                                          jsonb_build_object('lon', -56.15, 'lat', -34.8505))),
                  'CZ016', 'No hay un camino por las calles entre «Aparicio y Heredia» y «Aislada Este y Aislada Norte». Elegí otra esquina que esté sobre la misma red de calles.',
                  'una esquina en la cruz aislada: no hay camino hasta las otras');

-- ---------------------------------------------------------------------------
-- 6. Lo que arma poligono_por_calles() lo acepta guardar_zona() (la vista 24 lo manda tal cual)
-- ---------------------------------------------------------------------------
select is((public.guardar_zona(p_campania_ciudad_id => '01920000-0000-7000-8000-000000004571', p_nombre => 'Zona uno',
                               p_tipo_forma => 'ESQUINAS', p_vertices => (select esquinas from z1),
                               p_poligono_geojson => (select poligono_geojson from z1), p_vista_previa => true)) -> 'guardada',
          'false'::jsonb, 'guardar_zona() en vista previa acepta el polígono y las esquinas de poligono_por_calles()');
select is((public.guardar_zona(p_campania_ciudad_id => '01920000-0000-7000-8000-000000004571', p_nombre => 'Zona uno',
                               p_tipo_forma => 'ESQUINAS', p_vertices => (select esquinas from z1),
                               p_poligono_geojson => (select poligono_geojson from z1), p_vista_previa => true)) -> 'poligono_geojson',
          (select poligono_geojson from z1), 'y devuelve el mismo borde');

create temp table g1 on commit drop as
  select public.guardar_zona(p_campania_ciudad_id => '01920000-0000-7000-8000-000000004571', p_nombre => 'Zona uno',
                             p_tipo_forma => 'ESQUINAS', p_vertices => (select esquinas from z1),
                             p_poligono_geojson => (select poligono_geojson from z1)) r;
create temp table g2 on commit drop as
  select public.guardar_zona(p_campania_ciudad_id => '01920000-0000-7000-8000-000000004571', p_nombre => 'Zona dos',
                             p_tipo_forma => 'ESQUINAS', p_vertices => (select esquinas from z2),
                             p_poligono_geojson => (select poligono_geojson from z2)) r;
select is((select r ->> 'guardada' from g1), 'true', 'la zona uno se guarda');
select is((select r ->> 'guardada' from g2), 'true', 'y la zona vecina, que comparte el borde de Aparicio, también (las zonas pueden tocarse)');
select is((select jsonb_array_length(r -> 'vertices') from g1), 4, 'la zona uno guarda sus 4 esquinas');
select is((select r -> 'vertices' -> 0 ->> 'calle_a' from g1) || '/' || (select r -> 'vertices' -> 0 ->> 'calle_b' from g1),
          'Heredia/Pororó', 'con los nombres de las calles de cada esquina (la primera: Heredia y Pororó)');
select is((select r -> 'poligono_geojson' from g1), (select poligono_geojson from z1), 'y el borde que armó poligono_por_calles()');
select is((select r -> 'poligono_geojson' from g2), (select poligono_geojson from z2), 'la vecina también');
select is((select count(*)::int from public.zona where campania_ciudad_id = '01920000-0000-7000-8000-000000004571' and deleted_at is null), 2,
          'dos zonas vivas en la ciudad');

-- ---------------------------------------------------------------------------
-- 7. Permiso: las tres RPC, el mismo que guardar_zona(), y primero que todo lo demás
-- ---------------------------------------------------------------------------
select pg_temp.actuar_como_servidor();
create or replace function pg_temp.foto_ruteo() returns text language sql as $$
  select md5(coalesce((select string_agg(r::text, ',' order by r.ciudad_id) from ruteo.red r), '')
          || coalesce((select string_agg(n::text, ',' order by n.id) from ruteo.nodo n), '')
          || coalesce((select string_agg(t.id::text || t.largo_m::text, ',' order by t.id) from ruteo.tramo t), ''));
$$;
create temp table foto_ruteo_antes on commit drop as select pg_temp.foto_ruteo() f;

-- Una llamada válida para la ciudad c1 (los datos no importan para las ciudades sin calles: el permiso va antes).
create or replace function pg_temp.llamada(p_fn text, p_cc text) returns text language sql as $$
  select case p_fn
    when 'esquina' then format('select * from public.esquina_mas_cercana(%L, %s, %s)', p_cc, pg_temp.glon(1, 1), pg_temp.glat(1, 1))
    when 'tramo' then format('select * from public.tramo_por_calles(%L, %s, %s, %s, %s)', p_cc,
                             pg_temp.glon(0, 0), pg_temp.glat(0, 0), pg_temp.glon(1, 0), pg_temp.glat(1, 0))
    else format('select * from public.poligono_por_calles(%L, %L::jsonb)', p_cc,
                jsonb_build_array(jsonb_build_object('lon', pg_temp.glon(0, 0), 'lat', pg_temp.glat(0, 0)),
                                  jsonb_build_object('lon', pg_temp.glon(1, 0), 'lat', pg_temp.glat(1, 0)),
                                  jsonb_build_object('lon', pg_temp.glon(1, 1), 'lat', pg_temp.glat(1, 1)),
                                  jsonb_build_object('lon', pg_temp.glon(0, 1), 'lat', pg_temp.glat(0, 1))))
  end $$;

-- Quién llama: a0 colportor, a1 coordinador de e1 (y e3, e4, e5), a2 coordinador de e2, a3 sin rol,
-- a4 coordinador con el rol vencido, ad admin; anon y sinjwt.
create or replace function pg_temp.como(p_quien text, p_sql text) returns text language plpgsql as $$
declare
  v_r text;
begin
  if p_quien = 'anon' then
    perform pg_temp.actuar_como_anon();
  elsif p_quien = 'sinjwt' then
    perform pg_temp.actuar_sin_jwt();
  else
    perform pg_temp.actuar_como(('01920000-0000-7000-8000-0000000045' || p_quien)::uuid);
  end if;
  v_r := pg_temp.codigo(p_sql);
  perform pg_temp.actuar_como_servidor();
  return v_r;
end $$;

-- (quién, campania_ciudad, qué pasa): 71 e1/c1 · 76 e1/c6 sin calles · 77 e1/c7 sin calles · 78 e5/c1 de baja
-- · 79 e2/c1 · 7a e3 terminada · 7b e4 por empezar · ff inexistente
create temp table matriz (quien text, cc text, esperado text, que text) on commit drop;
insert into matriz values
  ('anon',   '71', '42501', 'anon: permission denied'),
  ('sinjwt', '71', '42501', 'authenticated sin sesión'),
  ('a0',     '71', '42501', 'un colportor'),
  ('a3',     '71', '42501', 'un usuario sin ningún rol'),
  ('a4',     '71', '42501', 'un coordinador con el rol vencido'),
  ('a2',     '71', '42501', 'el coordinador de otra campaña'),
  ('a1',     '79', '42501', 'el coordinador de la campaña de otro'),
  ('a0',     'ff', '42501', 'un colportor y una ciudad que no existe: el permiso va primero'),
  ('a0',     '76', '42501', 'un colportor y una ciudad sin calles: el permiso va primero'),
  ('a3',     '7a', '42501', 'sin rol y una campaña terminada: el permiso va primero'),
  ('a2',     '7a', '42501', 'el coordinador de otra campaña y una terminada: el permiso va primero'),
  ('a1',     '71', 'OK',    'el coordinador de la campaña'),
  ('a2',     '79', 'OK',    'el coordinador de su propia campaña'),
  ('ad',     '71', 'OK',    'el ADMIN'),
  ('ad',     '79', 'OK',    'el ADMIN en la campaña de otro'),
  ('a1',     '7b', 'OK',    'una campaña por empezar (la vista 24 prepara el mapa antes del inicio)'),
  ('a1',     '7a', 'CZ011', 'una campaña terminada'),
  ('ad',     '7a', 'CZ011', 'una campaña terminada, aun el ADMIN'),
  ('a1',     '78', 'CZ012', 'la ciudad de la campaña dada de baja'),
  ('a1',     'ff', 'CZ012', 'una ciudad que no está en la campaña'),
  ('ad',     'ff', 'CZ012', 'el ADMIN y una ciudad que no existe'),
  ('a1',     '76', 'CZ015', 'una ciudad sin calles cargadas'),
  ('a1',     '77', 'CZ015', 'otra ciudad sin calles cargadas');

select is(pg_temp.como(m.quien, pg_temp.llamada(f.fn, '01920000-0000-7000-8000-0000000045' || m.cc)), m.esperado,
          f.fn || ' · ' || m.que || ' → ' || m.esperado)
  from matriz m, (values ('esquina'), ('tramo'), ('poligono')) f(fn)
 order by f.fn, m.quien, m.cc;

-- anon y authenticated no leen ni ejecutan nada del schema ruteo.
select pg_temp.actuar_como('01920000-0000-7000-8000-0000000045a1');
select is(pg_temp.codigo('select count(*) from ruteo.nodo'), '42501', 'authenticated no lee ruteo.nodo (sin USAGE del schema)');
select is(pg_temp.codigo('select count(*) from ruteo.tramo'), '42501', 'ni ruteo.tramo');
select is(pg_temp.codigo('select count(*) from ruteo.red'), '42501', 'ni ruteo.red');
select is(pg_temp.codigo($$ select ruteo.cargar_red('01920000-0000-7000-8000-0000000045c1', '{"elements": []}'::jsonb) $$), '42501',
          'ni carga calles: ni siquiera un coordinador');
select is(pg_temp.codigo($$ select * from ruteo.camino('01920000-0000-7000-8000-0000000045c1', 1, 2) $$), '42501', 'ni calcula caminos');
select is(pg_temp.codigo($$ select * from public.ciudad_para_dibujar('01920000-0000-7000-8000-000000004571') $$), '42501',
          'ni llama a la comprobación interna');
select pg_temp.actuar_como_anon();
select is(pg_temp.codigo('select count(*) from ruteo.nodo'), '42501', 'anon no lee ruteo.nodo');
select pg_temp.actuar_como_servidor();

-- Nada de esto cambió datos de nadie: las RPC solo leen.
select is(pg_temp.foto_ruteo(), (select f from foto_ruteo_antes), 'las RPC no tocaron la red de calles (ni red, ni nodos, ni tramos)');
select is((select count(*)::int from public.zona where deleted_at is null), 2, 'ni crearon zonas por su cuenta (solo las dos de guardar_zona())');

select * from finish();
rollback;
