-- ============================================================================
-- Seed de ejemplo · zonas, campañas, catálogo y precios (issue #16)
--
-- Corre automáticamente en `supabase db reset` (config.toml -> db.seed.sql_paths)
-- y con `scripts/db-seed.sh` sobre una base con las migraciones ya aplicadas.
--
-- TODOS los datos de acá son FICTICIOS Y OBVIOS a propósito: nombres de zona,
-- campaña, producto y precios no corresponden a ninguna campaña real. Sirven
-- solo para tener algo con qué probar la app en desarrollo. Los datos reales
-- se cargan a mano siguiendo docs/guia-carga-manual.md — este archivo no debe
-- editarse para meter datos de una campaña real.
--
-- Idempotente: cada fila tiene un id fijo (prefijo 09990000, uno por entidad
-- en el tercer grupo) e `insert ... on conflict do nothing` sin conflict_target,
-- así que una fila que ya existe (por id o por cualquier otro unique/exclusion,
-- como el anti-solape de precio_por_zona) se saltea en vez de fallar o duplicar.
-- Correr este archivo dos veces deja la base igual que correrlo una vez.
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

-- ----------------------------------------------------------------------------
-- 2. Campañas
-- ----------------------------------------------------------------------------

insert into public.campania (id, nombre, tipo, fecha_inicio, fecha_fin, ciudad_id) values
  ('09990000-0000-7000-8003-000000000001', 'Campaña Ejemplo Verano',
    'VERANO', '2026-01-05', '2026-02-20', '09990000-0000-7000-8002-000000000001'),
  ('09990000-0000-7000-8003-000000000002', 'Campaña Ejemplo Permanente',
    'PERMANENTE', '2026-01-01', null, '09990000-0000-7000-8002-000000000002')
on conflict do nothing;

-- ----------------------------------------------------------------------------
-- 3. Zonas — dos dentro de la campaña de verano, una permanente sin campaña
-- ----------------------------------------------------------------------------

insert into public.zona (id, nombre, ciudad_id, campania_id) values
  ('09990000-0000-7000-8004-000000000001', 'Zona Ejemplo 1',
    '09990000-0000-7000-8002-000000000001', '09990000-0000-7000-8003-000000000001'),
  ('09990000-0000-7000-8004-000000000002', 'Zona Ejemplo 2',
    '09990000-0000-7000-8002-000000000001', '09990000-0000-7000-8003-000000000001'),
  -- campania_id null a propósito: zona permanente que no pertenece a una campaña concreta.
  ('09990000-0000-7000-8004-000000000003', 'Zona Ejemplo 3 (sin campaña)',
    '09990000-0000-7000-8002-000000000002', null)
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
-- 5. Precios por zona — mismo producto, distinto precio según zona; un precio
--    de colección; y un ejemplar misionero a precio 0 (se entrega, no se vende).
-- ----------------------------------------------------------------------------

insert into public.precio_por_zona
  (id, producto_id, coleccion_id, zona_id, precio_venta, valido_desde, valido_hasta) values
  ('09990000-0000-7000-8008-000000000001',
    '09990000-0000-7000-8005-000000000001', null, '09990000-0000-7000-8004-000000000001',
    25000, '2026-01-01', null),
  ('09990000-0000-7000-8008-000000000002',
    '09990000-0000-7000-8005-000000000001', null, '09990000-0000-7000-8004-000000000002',
    27000, '2026-01-01', null),
  ('09990000-0000-7000-8008-000000000003',
    null, '09990000-0000-7000-8006-000000000001', '09990000-0000-7000-8004-000000000001',
    45000, '2026-01-01', null),
  ('09990000-0000-7000-8008-000000000004',
    '09990000-0000-7000-8005-000000000003', null, '09990000-0000-7000-8004-000000000002',
    8000, '2026-01-01', null),
  ('09990000-0000-7000-8008-000000000005',
    '09990000-0000-7000-8005-000000000004', null, '09990000-0000-7000-8004-000000000003',
    15000, '2026-01-01', null),
  ('09990000-0000-7000-8008-000000000006',
    '09990000-0000-7000-8005-000000000005', null, '09990000-0000-7000-8004-000000000003',
    0, '2026-01-01', null)
on conflict do nothing;
