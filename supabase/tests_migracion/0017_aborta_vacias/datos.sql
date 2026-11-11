-- Duplicados vivos SIN nada colgado (decisión del 02/10, backend-supabase#49): 0017 aborta igual,
-- no da de baja ninguna y lista TODOS los pares. Ver scripts/db-test-migracion.sh. En
-- P0 = (-34.90, -56.20); 0,0001° de longitud ≈ 9,1 m.
--   a1/a2/a3  Av. Italia 100: a2 a ~50 m de a1; a3 a ~146 m de a1 y a ~96 m de a2. Dos pares:
--             (a1, a2) y (a2, a3).
--   a4/a5     Rivera 5 a ~10 m, cada una con su espacio único (sin departamento): un par.
--   ae/af     Rivera 9 a ~20 m: la más vieja es af (created_at), aunque su id sea mayor.

insert into public.pais (id, nombre, iso_code) values ('01920000-0000-7000-8000-0000000098c0', 'Pais migración 17c', 'ZW');
insert into public.ciudad (id, nombre, pais_id, lat_centro, lon_centro) values
  ('01920000-0000-7000-8000-0000000098c1', 'Montevideo', '01920000-0000-7000-8000-0000000098c0', -34.90, -56.20);

insert into public.ubicacion (id, tipo, calle, numero, lat, lon, ciudad_id, created_at) values
  ('01920000-0000-7000-8000-0000000098a1', 'CASA', 'Av. Italia',  '100', -34.90, -56.20,     '01920000-0000-7000-8000-0000000098c1', '2026-09-01'),
  ('01920000-0000-7000-8000-0000000098a2', 'CASA', 'av.  itália', '100', -34.90, -56.19945,  '01920000-0000-7000-8000-0000000098c1', '2026-09-02'),
  ('01920000-0000-7000-8000-0000000098a3', 'CASA', 'AV. ITALIA',  '100', -34.90, -56.19840,  '01920000-0000-7000-8000-0000000098c1', '2026-09-03'),
  ('01920000-0000-7000-8000-0000000098a4', 'CASA', 'Rivera',      '5',   -34.91, -56.20,     '01920000-0000-7000-8000-0000000098c1', '2026-09-01'),
  ('01920000-0000-7000-8000-0000000098a5', 'CASA', 'rivera ',     ' 5',  -34.91, -56.19989,  '01920000-0000-7000-8000-0000000098c1', '2026-09-02'),
  ('01920000-0000-7000-8000-0000000098ae', 'CASA', 'Rivera',      '9',   -34.96, -56.20,     '01920000-0000-7000-8000-0000000098c1', '2026-09-05'),
  ('01920000-0000-7000-8000-0000000098af', 'CASA', 'Rivera',      '9',   -34.96, -56.19978,  '01920000-0000-7000-8000-0000000098c1', '2026-09-04');

insert into public.espacio (id, ubicacion_id) values
  ('01920000-0000-7000-8000-0000000098b4', '01920000-0000-7000-8000-0000000098a4'),
  ('01920000-0000-7000-8000-0000000098b5', '01920000-0000-7000-8000-0000000098a5');
