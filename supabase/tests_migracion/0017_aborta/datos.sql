-- Duplicados vivos con algo colgado: 0017 aborta, no cambia nada y nombra cada uno. Ver
-- scripts/db-test-migracion.sh. 0,0001° de longitud ≈ 9,1 m.
--   a2 (Av. Itália 100, a ~30 m de a1) tiene una persona en su espacio.
--   a4 (rivera 9, a ~20 m de a3) tiene estado en el mapa.
--   a6 (Colonia 1, a ~15 m de a5, edificio) tiene un departamento cargado.
--   a8 (Colonia 2, a ~10 m de a7) no tiene nada: se contaría para dar de baja.
--   aa (Colonia 3, a ~10 m de a9) es la dirección de cobranza de una persona de a9.

insert into public.pais (id, nombre, iso_code) values ('01920000-0000-7000-8000-0000000097c0', 'Pais migración 17b', 'ZV');
insert into public.ciudad (id, nombre, pais_id, lat_centro, lon_centro) values
  ('01920000-0000-7000-8000-0000000097c1', 'Montevideo', '01920000-0000-7000-8000-0000000097c0', -34.90, -56.20);

insert into public.ubicacion (id, tipo, calle, numero, lat, lon, ciudad_id, created_at) values
  ('01920000-0000-7000-8000-0000000097a1', 'CASA',     'Av. Italia', '100', -34.90, -56.20,    '01920000-0000-7000-8000-0000000097c1', '2026-09-01'),
  ('01920000-0000-7000-8000-0000000097a2', 'CASA',     'Av. Itália', '100', -34.90, -56.19967, '01920000-0000-7000-8000-0000000097c1', '2026-09-02'),
  ('01920000-0000-7000-8000-0000000097a3', 'CASA',     'Rivera',     '9',   -34.91, -56.20,    '01920000-0000-7000-8000-0000000097c1', '2026-09-01'),
  ('01920000-0000-7000-8000-0000000097a4', 'CASA',     'rivera',     '9',   -34.91, -56.19978, '01920000-0000-7000-8000-0000000097c1', '2026-09-02'),
  ('01920000-0000-7000-8000-0000000097a5', 'EDIFICIO', 'Colonia',    '1',   -34.92, -56.20,    '01920000-0000-7000-8000-0000000097c1', '2026-09-01'),
  ('01920000-0000-7000-8000-0000000097a6', 'EDIFICIO', 'Colonia',    '1',   -34.92, -56.19984, '01920000-0000-7000-8000-0000000097c1', '2026-09-02'),
  ('01920000-0000-7000-8000-0000000097a7', 'CASA',     'Colonia',    '2',   -34.93, -56.20,    '01920000-0000-7000-8000-0000000097c1', '2026-09-01'),
  ('01920000-0000-7000-8000-0000000097a8', 'CASA',     'Colonia',    '2',   -34.93, -56.19989, '01920000-0000-7000-8000-0000000097c1', '2026-09-02'),
  ('01920000-0000-7000-8000-0000000097a9', 'CASA',     'Colonia',    '3',   -34.94, -56.20,    '01920000-0000-7000-8000-0000000097c1', '2026-09-01'),
  ('01920000-0000-7000-8000-0000000097aa', 'CASA',     'Colonia',    '3',   -34.94, -56.19989, '01920000-0000-7000-8000-0000000097c1', '2026-09-02');

insert into public.espacio (id, ubicacion_id, numero_depto) values
  ('01920000-0000-7000-8000-0000000097b2', '01920000-0000-7000-8000-0000000097a2', null),
  ('01920000-0000-7000-8000-0000000097b6', '01920000-0000-7000-8000-0000000097a6', '3B'),
  ('01920000-0000-7000-8000-0000000097b9', '01920000-0000-7000-8000-0000000097a9', null);

insert into public.espacio_persona (id, espacio_id, persona_id, ubicacion_cobranza_alt_id) values
  ('01920000-0000-7000-8000-0000000097d2', '01920000-0000-7000-8000-0000000097b2', '01920000-0000-7000-8000-0000000097e2', null),
  ('01920000-0000-7000-8000-0000000097d9', '01920000-0000-7000-8000-0000000097b9', '01920000-0000-7000-8000-0000000097e9',
   '01920000-0000-7000-8000-0000000097aa');

insert into public.house_status (ubicacion_id, lat, lon, tipo_ubicacion, color, prioridad) values
  ('01920000-0000-7000-8000-0000000097a4', -34.91, -56.19978, 'CASA', 'RECHAZO', 7);
