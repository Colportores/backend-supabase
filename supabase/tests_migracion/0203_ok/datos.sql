-- Datos con el esquema de 0202 (cobranza sin `anulado_por`, sin tabla del detalle) para probar que 0203 solo suma la
-- columna, en null, sin tocar ninguna fila ni su sincronización. Ver scripts/db-test-migracion.sh.
--
-- Una colportora (inscripta en la campaña de un coordinador) con una venta y tres cobros: uno vivo, uno anulado por la
-- colportora antes de la 0203 (no se sabe quién: queda con anulado_por null) y uno dado de baja. La foto de antes queda en
-- prueba_0203_cobranza de public: db-reset.sh la borra con el resto.

insert into public.pais (id, nombre, iso_code) values
  ('01920000-0000-7000-8000-0000000203a1', 'Uruguay', 'UY');
insert into public.ciudad (id, nombre, departamento, pais_id, lat_centro, lon_centro, zoom_inicial) values
  ('01920000-0000-7000-8000-0000000203c1', 'Ciudad 203', 'Departamento 203', '01920000-0000-7000-8000-0000000203a1', -34.9011, -56.1645, 13);
insert into auth.users (id, instance_id, aud, role, email, encrypted_password, confirmed_at, created_at, updated_at) values
  ('01920000-0000-7000-8000-0000000203b1', '00000000-0000-0000-0000-000000000000',
   'authenticated', 'authenticated', 'migracion203b@example.com', 'x', now(), now(), now()),
  ('01920000-0000-7000-8000-0000000203d1', '00000000-0000-0000-0000-000000000000',
   'authenticated', 'authenticated', 'migracion203d@example.com', 'x', now(), now(), now());
insert into public.usuario_rol (usuario_id, rol_id)
select x.u::uuid, r.id
  from (values ('01920000-0000-7000-8000-0000000203b1', 'COLPORTOR'),
               ('01920000-0000-7000-8000-0000000203d1', 'COORDINADOR')) x(u, codigo)
  join public.rol r on r.codigo = x.codigo;
insert into public.campania (id, nombre, tipo, fecha_inicio, fecha_fin, coordinador_id) values
  ('01920000-0000-7000-8000-0000000203e1', 'Verano 203', 'VERANO', public.hoy_montevideo() - 10, public.hoy_montevideo() + 30,
   '01920000-0000-7000-8000-0000000203d1');
insert into public.campania_colportor (campania_id, usuario_id) values
  ('01920000-0000-7000-8000-0000000203e1', '01920000-0000-7000-8000-0000000203b1');

insert into public.ubicacion (id, tipo, calle, numero, lat, lon, ciudad_id, created_by) values
  ('01920000-0000-7000-8000-0000000203f1', 'CASA', 'Av. Italia', '100', -34.9000, -56.2000,
   '01920000-0000-7000-8000-0000000203c1', '01920000-0000-7000-8000-0000000203b1');
insert into public.espacio (id, ubicacion_id, created_by) values
  ('01920000-0000-7000-8000-0000000203f2', '01920000-0000-7000-8000-0000000203f1', '01920000-0000-7000-8000-0000000203b1');
insert into public.espacio_persona (id, espacio_id, persona_id, created_by) values
  ('01920000-0000-7000-8000-0000000203f3', '01920000-0000-7000-8000-0000000203f2',
   '01920000-0000-7000-8000-0000000203f4', '01920000-0000-7000-8000-0000000203b1');
insert into public.venta (id, espacio_persona_id, numero_talonario, monto_total, fecha, colportor_id, created_by) values
  ('01920000-0000-7000-8000-000000020301', '01920000-0000-7000-8000-0000000203f3', 'T-0301', 270000,
   now() - interval '2 hours', '01920000-0000-7000-8000-0000000203b1', '01920000-0000-7000-8000-0000000203b1');

insert into public.cobranza (id, venta_id, monto, medio, fecha, created_by, deleted_at) values
  ('01920000-0000-7000-8000-000000020311', '01920000-0000-7000-8000-000000020301', 50000, 'EFECTIVO',
   now() - interval '1 hour', '01920000-0000-7000-8000-0000000203b1', null),
  ('01920000-0000-7000-8000-000000020312', '01920000-0000-7000-8000-000000020301', 120000, 'EFECTIVO',
   now() - interval '1 hour', '01920000-0000-7000-8000-0000000203b1', null),
  ('01920000-0000-7000-8000-000000020313', '01920000-0000-7000-8000-000000020301', 20000, 'EFECTIVO',
   now() - interval '1 hour', '01920000-0000-7000-8000-0000000203b1', now());
-- El 312 lo anuló la colportora: una corrección con versión de sync 1 y un xmin_w propio.
update public.cobranza set anulado_at = now() - interval '30 minutes', motivo_anulacion = 'Monto equivocado'
 where id = '01920000-0000-7000-8000-000000020312';

-- La foto de antes: las filas enteras.
create table public.prueba_0203_cobranza as select * from public.cobranza;
