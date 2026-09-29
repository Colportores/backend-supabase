-- Datos con el esquema de 0008 (usuario.zona_id todavía existe) para probar que 0009 pasa
-- cada zona directa a la inscripción sin perder nada. Ver scripts/db-test-migracion.sh.
--   a1 zona directa Centro, inscripto en Verano SIN zona       → se copia
--   a2 zona directa Cordón, inscripto en Verano CON Cordón      → nada que copiar
--   a3 sin zona directa, inscripto en Verano con Centro         → queda igual
--   a4 dado de baja, zona directa Salto, inscripto en Otra sin zona → se copia (es su dato)

insert into public.pais (id, nombre, iso_code) values ('01920000-0000-7000-8000-0000000090c0', 'Pais migración', 'ZX');
insert into public.ciudad (id, nombre, pais_id, lat_centro, lon_centro) values
  ('01920000-0000-7000-8000-0000000090c1', 'Montevideo', '01920000-0000-7000-8000-0000000090c0', -34.90, -56.16),
  ('01920000-0000-7000-8000-0000000090c2', 'Salto',      '01920000-0000-7000-8000-0000000090c0', -31.40, -57.96);
insert into public.campania (id, nombre, tipo, fecha_inicio) values
  ('01920000-0000-7000-8000-0000000090e1', 'Verano', 'VERANO',     current_date - 10),
  ('01920000-0000-7000-8000-0000000090e2', 'Otra',   'PERMANENTE', current_date - 10);
insert into public.campania_ciudad (id, campania_id, ciudad_id) values
  ('01920000-0000-7000-8000-0000000090f1', '01920000-0000-7000-8000-0000000090e1', '01920000-0000-7000-8000-0000000090c1'),
  ('01920000-0000-7000-8000-0000000090f2', '01920000-0000-7000-8000-0000000090e2', '01920000-0000-7000-8000-0000000090c2');
insert into public.zona (id, nombre, campania_ciudad_id, tipo_forma, centro_lat, centro_lon, radio_m) values
  ('01920000-0000-7000-8000-0000000090d1', 'Centro', '01920000-0000-7000-8000-0000000090f1', 'RADIAL', -34.90, -56.18, 300),
  ('01920000-0000-7000-8000-0000000090d2', 'Cordón', '01920000-0000-7000-8000-0000000090f1', 'RADIAL', -34.90, -56.14, 300),
  ('01920000-0000-7000-8000-0000000090d3', 'Salto',  '01920000-0000-7000-8000-0000000090f2', 'RADIAL', -31.40, -57.96, 300);

insert into auth.users (id, instance_id, aud, role, email, encrypted_password, created_at, updated_at)
select ('01920000-0000-7000-8000-0000000090' || s)::uuid, '00000000-0000-0000-0000-000000000000',
       'authenticated', 'authenticated', 'mig9-' || s || '@example.com', 'x', now(), now()
  from unnest(array['a1','a2','a3','a4']) s;

update public.usuario u set zona_id = x.zona::uuid
  from (values ('a1', '01920000-0000-7000-8000-0000000090d1'),
               ('a2', '01920000-0000-7000-8000-0000000090d2'),
               ('a4', '01920000-0000-7000-8000-0000000090d3')) x(s, zona)
 where u.id = ('01920000-0000-7000-8000-0000000090' || x.s)::uuid;
update public.usuario set deleted_at = now() where id = '01920000-0000-7000-8000-0000000090a4';

insert into public.campania_colportor (campania_id, usuario_id, zona_id) values
  ('01920000-0000-7000-8000-0000000090e1', '01920000-0000-7000-8000-0000000090a1', null),
  ('01920000-0000-7000-8000-0000000090e1', '01920000-0000-7000-8000-0000000090a2', '01920000-0000-7000-8000-0000000090d2'),
  ('01920000-0000-7000-8000-0000000090e1', '01920000-0000-7000-8000-0000000090a3', '01920000-0000-7000-8000-0000000090d1'),
  ('01920000-0000-7000-8000-0000000090e2', '01920000-0000-7000-8000-0000000090a4', null);
