-- Datos con el esquema de 0108 (ciudad sin `origen`) para probar que 0109 carga el catálogo de Uruguay de
-- OpenStreetMap SIN borrar ni duplicar: las ciudades de antes siguen idénticas (salvo el origen y lo que la carga
-- completa a propósito) y las que no figuran en la lista se avisan y no se tocan. Ver scripts/db-test-migracion.sh.
--
-- Uruguay con cinco ciudades de antes y Chile con otra «Montevideo»:
--   c1 Montevideo (Montevideo), con el rectángulo de la 0031        -> casa: queda OSM y conserva SU rectángulo
--   c2 Salto, departamento «salto» en minúscula                      -> casa sin tildes ni mayúsculas: queda OSM, «Salto»
--   c3 Pueblo Aparte (Rivera), no está en la lista                   -> no casa: se avisa, no se toca
--   c4 Rivera, sin departamento (cargada antes de la 0066)           -> no casa: se avisa, no se toca
--   c5 Maldonado (Maldonado), dada de baja                           -> casa con la lista pero está de baja: no se recrea
--   c6 Montevideo (CL), de otro país                                 -> otro país: ni se mira
-- Una campaña de verano en c1 y en c2, y una zona en c1.
-- La foto de antes queda en prueba_0109_* de public: db-reset.sh las borra con el resto.

insert into public.pais (id, nombre, iso_code) values
  ('01920000-0000-7000-8000-0000000109a1', 'Uruguay', 'UY'),
  ('01920000-0000-7000-8000-0000000109a2', 'Chile',   'CL');
insert into public.ciudad (id, nombre, departamento, pais_id, lat_centro, lon_centro, zoom_inicial,
                           bbox_oeste, bbox_sur, bbox_este, bbox_norte, deleted_at) values
  ('01920000-0000-7000-8000-0000000109c1', 'Montevideo', 'Montevideo', '01920000-0000-7000-8000-0000000109a1',
   -34.9011, -56.1645, 13, -56.433, -34.945, -55.948, -34.701, null),
  ('01920000-0000-7000-8000-0000000109c2', 'Salto', 'salto', '01920000-0000-7000-8000-0000000109a1',
   -31.3833, -57.9667, 14, null, null, null, null, null),
  ('01920000-0000-7000-8000-0000000109c3', 'Pueblo Aparte', 'Rivera', '01920000-0000-7000-8000-0000000109a1',
   -30.9000, -55.5400, 14, null, null, null, null, null),
  ('01920000-0000-7000-8000-0000000109c5', 'Maldonado', 'Maldonado', '01920000-0000-7000-8000-0000000109a1',
   -34.9000, -54.9500, 13, null, null, null, null, '2026-05-01 10:00:00+00'),
  ('01920000-0000-7000-8000-0000000109c6', 'Montevideo', 'Montevideo', '01920000-0000-7000-8000-0000000109a2',
   -34.9011, -56.1645, 13, null, null, null, null, null);
-- Una ciudad vieja, de antes de la 0066, sin departamento: el trigger CD001 no deja crearla hoy, así que se arma con
-- el trigger apagado.
alter table public.ciudad disable trigger ciudad_departamento_obligatorio;
insert into public.ciudad (id, nombre, departamento, pais_id, lat_centro, lon_centro, zoom_inicial) values
  ('01920000-0000-7000-8000-0000000109c4', 'Rivera', null, '01920000-0000-7000-8000-0000000109a1', -30.9053, -55.5508, 14);
alter table public.ciudad enable trigger ciudad_departamento_obligatorio;

insert into public.campania (id, nombre, tipo, fecha_inicio, fecha_fin) values
  ('01920000-0000-7000-8000-0000000109e1', 'Verano 109', 'VERANO', '2026-01-05', '2026-12-20');
insert into public.campania_ciudad (id, campania_id, ciudad_id) values
  ('01920000-0000-7000-8000-0000000109f1', '01920000-0000-7000-8000-0000000109e1', '01920000-0000-7000-8000-0000000109c1'),
  ('01920000-0000-7000-8000-0000000109f2', '01920000-0000-7000-8000-0000000109e1', '01920000-0000-7000-8000-0000000109c2');
insert into public.zona (id, nombre, campania_ciudad_id, tipo_forma, centro_lat, centro_lon, radio_m, color) values
  ('01920000-0000-7000-8000-0000000109b1', 'Zona Montevideo 109', '01920000-0000-7000-8000-0000000109f1', 'RADIAL', -34.90, -56.16, 500, '#3A7BD5');

-- La foto de antes: las filas enteras.
create table public.prueba_0109_ciudad as select * from public.ciudad;
create table public.prueba_0109_zona   as select * from public.zona;
create table public.prueba_0109_campania_ciudad as select * from public.campania_ciudad;
