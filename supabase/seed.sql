-- ============================================================================
-- Seed de ejemplo · zonas, campañas, catálogo y precios (issue #16)
--
-- Se aplica con `scripts/db-seed.sh` sobre una base con las migraciones ya
-- aplicadas. `config.toml` lo registra en `db.seed.sql_paths` (convención del
-- CLI) pero `[db.seed] enabled = false` a propósito: si estuviera en true,
-- `supabase db reset --linked` sembraría este catálogo ficticio sobre
-- cualquier proyecto remoto linkeado, staging/producción incluidos.
-- `scripts/db-seed.sh` es el único camino sancionado.
--
-- Los datos de acá son FICTICIOS Y OBVIOS a propósito (la única excepción es la
-- ciudad Montevideo de la sección 1, con su rectángulo real): nombres de zona,
-- campaña, producto y precios no corresponden a ninguna campaña real. Sirven
-- solo para tener algo con qué probar la app en desarrollo. Los datos reales
-- se cargan a mano siguiendo docs/guia-carga-manual.md — este archivo no debe
-- editarse para meter datos de una campaña real.
--
-- Idempotente: cada fila tiene un id fijo (prefijo 09990000, uno por entidad
-- en el tercer grupo) e `insert ... on conflict do nothing` sin conflict_target,
-- así que una fila que ya existe (por id o por cualquier otro unique/exclusion,
-- como el anti-solape de precio_por_ciudad) se saltea en vez de fallar o duplicar.
-- Correr este archivo dos veces deja la base igual que correrlo una vez.
--
-- Dos límites de ese "idempotente" a tener presentes:
--   · Si un dato real cargado a mano choca con uno del seed (p. ej. un precio
--     que se solapa en rango de fechas para la misma ciudad de la campaña y
--     producto), el
--     insert del seed se saltea EN SILENCIO — no avisa, no falla.
--   · "No duplica ni falla" no es "converge al contenido de este archivo": si
--     mañana se edita un valor acá (por id ya existente) y se re-corre sobre
--     una base ya sembrada, `on conflict do nothing` deja la fila vieja tal
--     cual. Para aplicar un cambio hay que borrar esas filas de ejemplo o
--     usar un `id` nuevo.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. Geografía — país real (V1 es solo Uruguay, esquema-datos.md), ciudades ficticias
-- ----------------------------------------------------------------------------

insert into public.pais (id, nombre, iso_code) values
  ('09990000-0000-7000-8001-000000000001', 'Uruguay', 'UY')
on conflict do nothing;

insert into public.ciudad (id, nombre, pais_id, lat_centro, lon_centro, zoom_inicial) values
  ('09990000-0000-7000-8002-000000000001', 'Ciudad Ejemplo Norte', '09990000-0000-7000-8001-000000000001', -33.0, -56.0, 13),
  ('09990000-0000-7000-8002-000000000002', 'Ciudad Ejemplo Sur',   '09990000-0000-7000-8001-000000000001', -34.0, -55.5, 13)
on conflict do nothing;

-- Montevideo, con su rectángulo (migración 0031, backend-supabase#42): es la ciudad del mapa propio de la
-- demo del Hito 1 y la única que el publicador de mapas (tiles/) publica de este seed; las dos de ejemplo
-- de arriba no tienen rectángulo y el publicador las avisa sin publicarlas. Es una ciudad REAL con datos
-- reales (nombre, centro y rectángulo), a diferencia del resto de este archivo, y se pone acá solo para
-- tener algo que publicar en la base local; en el proyecto hosteado se carga con docs/guia-carga-manual.md §2
-- (el mismo bloque, idempotente). `where not exists`: si la base ya tiene una Montevideo viva en Uruguay
-- (cargada a mano, con otro id) no se agrega una segunda.
insert into public.ciudad
  (id, nombre, pais_id, lat_centro, lon_centro, zoom_inicial, bbox_oeste, bbox_sur, bbox_este, bbox_norte)
select '09990000-0000-7000-8002-000000000003', 'Montevideo', p.id, -34.9011, -56.1645, 13,
       -56.433, -34.945, -55.948, -34.701
  from public.pais p
 where p.iso_code = 'UY'
   and not exists (select 1 from public.ciudad c
                    where c.pais_id = p.id and c.nombre = 'Montevideo' and c.deleted_at is null)
on conflict do nothing;

-- ----------------------------------------------------------------------------
-- 2. Campañas
-- ----------------------------------------------------------------------------

insert into public.campania (id, nombre, tipo, fecha_inicio, fecha_fin) values
  ('09990000-0000-7000-8003-000000000001', 'Campaña Ejemplo Verano', 'VERANO', '2026-01-05', '2026-02-20'),
  ('09990000-0000-7000-8003-000000000002', 'Campaña Ejemplo Permanente', 'PERMANENTE', '2026-01-01', null)
on conflict do nothing;
-- ----------------------------------------------------------------------------
-- 3. Mapa: ciudades de cada campaña, zonas y esquinas (migración 0008)
--    Verano abarca las dos ciudades; Permanente, solo la Sur. Hay zonas RADIAL y
--    ESQUINAS, y ninguna se superpone con otra de su misma campaña y ciudad.
-- ----------------------------------------------------------------------------

insert into public.campania_ciudad (id, campania_id, ciudad_id) values
  ('09990000-0000-7000-8009-000000000001',
    '09990000-0000-7000-8003-000000000001', '09990000-0000-7000-8002-000000000001'),
  ('09990000-0000-7000-8009-000000000002',
    '09990000-0000-7000-8003-000000000001', '09990000-0000-7000-8002-000000000002'),
  ('09990000-0000-7000-8009-000000000003',
    '09990000-0000-7000-8003-000000000002', '09990000-0000-7000-8002-000000000002')
on conflict do nothing;

-- RADIAL: el polígono lo calcula el servidor (trigger zona_mapa) a partir de centro y radio.
-- ESQUINAS: el borde viene calculado (en la app, siguiendo las calles; acá, un cuadrado de
-- unos 500 m) y sus esquinas van en zona_vertice.
insert into public.zona
  (id, nombre, campania_ciudad_id, tipo_forma, centro_lat, centro_lon, radio_m, poligono_geojson, color) values
  ('09990000-0000-7000-8004-000000000001', 'Zona Ejemplo 1', '09990000-0000-7000-8009-000000000001',
    'RADIAL', -33.0, -56.0, 500, null, '#3A7BD5'),
  ('09990000-0000-7000-8004-000000000002', 'Zona Ejemplo 2', '09990000-0000-7000-8009-000000000001',
    'ESQUINAS', null, null, null,
    '{"type":"Polygon","coordinates":[[[-55.99,-33.003],[-55.985,-33.003],[-55.985,-32.997],[-55.99,-32.997],[-55.99,-33.003]]]}',
    '#E07A5F'),
  ('09990000-0000-7000-8004-000000000003', 'Zona Ejemplo 3', '09990000-0000-7000-8009-000000000003',
    'RADIAL', -34.0, -55.5, 400, null, '#81B29A'),
  ('09990000-0000-7000-8004-000000000004', 'Zona Ejemplo 4', '09990000-0000-7000-8009-000000000002',
    'ESQUINAS', null, null, null,
    '{"type":"Polygon","coordinates":[[[-55.49,-34.003],[-55.485,-34.003],[-55.485,-33.997],[-55.49,-33.997],[-55.49,-34.003]]]}',
    '#F2CC8F')
on conflict do nothing;

insert into public.zona_vertice (id, zona_id, orden, lat, lon, calle_a, calle_b) values
  ('09990000-0000-7000-800a-000000000001', '09990000-0000-7000-8004-000000000002', 1, -33.003, -55.99,  'Calle Ejemplo A', 'Calle Ejemplo 1'),
  ('09990000-0000-7000-800a-000000000002', '09990000-0000-7000-8004-000000000002', 2, -33.003, -55.985, 'Calle Ejemplo B', 'Calle Ejemplo 1'),
  ('09990000-0000-7000-800a-000000000003', '09990000-0000-7000-8004-000000000002', 3, -32.997, -55.985, 'Calle Ejemplo B', 'Calle Ejemplo 2'),
  ('09990000-0000-7000-800a-000000000004', '09990000-0000-7000-8004-000000000002', 4, -32.997, -55.99,  'Calle Ejemplo A', 'Calle Ejemplo 2'),
  ('09990000-0000-7000-800a-000000000005', '09990000-0000-7000-8004-000000000004', 1, -34.003, -55.49,  'Calle Ejemplo C', 'Calle Ejemplo 3'),
  ('09990000-0000-7000-800a-000000000006', '09990000-0000-7000-8004-000000000004', 2, -34.003, -55.485, 'Calle Ejemplo D', 'Calle Ejemplo 3'),
  ('09990000-0000-7000-800a-000000000007', '09990000-0000-7000-8004-000000000004', 3, -33.997, -55.485, 'Calle Ejemplo D', 'Calle Ejemplo 4'),
  ('09990000-0000-7000-800a-000000000008', '09990000-0000-7000-8004-000000000004', 4, -33.997, -55.49,  'Calle Ejemplo C', 'Calle Ejemplo 4')
on conflict do nothing;

-- ----------------------------------------------------------------------------
-- 4. Catálogo — un producto por tipo, más una colección con dos productos
-- ----------------------------------------------------------------------------

insert into public.producto
  (id, nombre, descripcion, tipo, es_bonificable, es_misionero, precio_base_compra, casa_editora) values
  ('09990000-0000-7000-8005-000000000001', 'Libro de Ejemplo A', 'Descripción de ejemplo A',
    'LIBRO', true, false, 12000, 'Editorial Ejemplo'),
  ('09990000-0000-7000-8005-000000000002', 'Libro de Ejemplo B', 'Descripción de ejemplo B',
    'LIBRO', true, false, 14000, 'Editorial Ejemplo'),
  ('09990000-0000-7000-8005-000000000003', 'Revista de Ejemplo', 'Descripción de ejemplo C',
    'REVISTA', false, false, 3000, 'Editorial Ejemplo'),
  ('09990000-0000-7000-8005-000000000004', 'Material de Ejemplo', 'Descripción de ejemplo D',
    'MATERIAL', false, false, 5000, 'Editorial Ejemplo'),
  -- es_misionero=true + precio_base_compra null: ejemplar de regalo, sin costo de reposición cargado.
  ('09990000-0000-7000-8005-000000000005', 'Ejemplar Misionero de Ejemplo', 'Descripción de ejemplo E',
    'MISIONERO', false, true, null, 'Editorial Ejemplo')
on conflict do nothing;

insert into public.coleccion (id, nombre) values
  ('09990000-0000-7000-8006-000000000001', 'Colección de Ejemplo — Serie A')
on conflict do nothing;

insert into public.producto_coleccion (id, producto_id, coleccion_id) values
  ('09990000-0000-7000-8007-000000000001',
    '09990000-0000-7000-8005-000000000001', '09990000-0000-7000-8006-000000000001'),
  ('09990000-0000-7000-8007-000000000002',
    '09990000-0000-7000-8005-000000000002', '09990000-0000-7000-8006-000000000001')
on conflict do nothing;

-- ----------------------------------------------------------------------------
-- 5. Precios por ciudad de la campaña (migración 0027) — mismo producto, distinto
--    precio según la ciudad; un precio de colección; y un ejemplar misionero a
--    precio 0 (se entrega, no se vende).
-- ----------------------------------------------------------------------------

insert into public.precio_por_ciudad
  (id, producto_id, coleccion_id, campania_ciudad_id, precio_venta, valido_desde, valido_hasta) values
  ('09990000-0000-7000-8008-000000000001',
    '09990000-0000-7000-8005-000000000001', null, '09990000-0000-7000-8009-000000000001',
    25000, '2026-01-01', null),
  ('09990000-0000-7000-8008-000000000002',
    '09990000-0000-7000-8005-000000000001', null, '09990000-0000-7000-8009-000000000002',
    27000, '2026-01-01', null),
  ('09990000-0000-7000-8008-000000000003',
    null, '09990000-0000-7000-8006-000000000001', '09990000-0000-7000-8009-000000000001',
    45000, '2026-01-01', null),
  ('09990000-0000-7000-8008-000000000004',
    '09990000-0000-7000-8005-000000000003', null, '09990000-0000-7000-8009-000000000002',
    8000, '2026-01-01', null),
  ('09990000-0000-7000-8008-000000000005',
    '09990000-0000-7000-8005-000000000004', null, '09990000-0000-7000-8009-000000000003',
    15000, '2026-01-01', null),
  ('09990000-0000-7000-8008-000000000006',
    '09990000-0000-7000-8005-000000000005', null, '09990000-0000-7000-8009-000000000003',
    0, '2026-01-01', null)
on conflict do nothing;
