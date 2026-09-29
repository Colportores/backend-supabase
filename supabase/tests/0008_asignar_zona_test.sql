-- pgTAP · asignar zona a un colportor de la campaña (migración 0006, HU-CAM-006)
-- Cada regla por el RPC (código propio), el acceso (colportor, coordinador de otra campaña,
-- anon), la guarda del UPDATE directo de zona_id y el efecto en mis_zonas().
begin;
select * from no_plan();

-- --- helpers -------------------------------------------------------------------
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

-- --- fixtures (como postgres, sin RLS) -----------------------------------------
-- Staff: a1 coordinador de Verano y de Vieja (Montevideo), a2 coordinador de Salto (Salto)
--        y de Otoño (Montevideo), ad admin, a0 colportor.
-- Colportores: b1 en Verano sin zona (el caso feliz)   b2 inscripción borrada en Verano
--              b3 en Salto                              b4 en Vieja (campaña terminada)
--              b5 en Verano pero dado de baja           b6 no inscripto en ninguna
-- Zonas (Montevideo salvo d3): d1 Centro (sin campaña)  d2 Cordón (de Verano)
--              d3 Salto centro (Salto)  d4 Pocitos (de Otoño)  d5 Borrada
insert into auth.users (id, instance_id, aud, role, email, encrypted_password, confirmed_at, created_at, updated_at)
select ('01920000-0000-7000-8000-0000000008' || s)::uuid, '00000000-0000-0000-0000-000000000000',
       'authenticated', 'authenticated', 'zona-' || s || '@example.com', 'x', now(), now(), now()
  from unnest(array['a0','a1','a2','ad','b1','b2','b3','b4','b5','b6']) s;

insert into public.usuario_rol (usuario_id, rol_id)
select ('01920000-0000-7000-8000-0000000008' || x.s)::uuid, r.id
  from (values ('a1','COORDINADOR'), ('a2','COORDINADOR'), ('ad','ADMIN'), ('a0','COLPORTOR')) x(s, codigo)
  join public.rol r on r.codigo = x.codigo;

insert into public.pais (id, nombre, iso_code) values ('01920000-0000-7000-8000-0000000008c0', 'Pais zona', 'ZZ');
insert into public.ciudad (id, nombre, pais_id, lat_centro, lon_centro) values
  ('01920000-0000-7000-8000-0000000008c1', 'Montevideo zona', '01920000-0000-7000-8000-0000000008c0', -34.9, -56.16),
  ('01920000-0000-7000-8000-0000000008c2', 'Salto zona',      '01920000-0000-7000-8000-0000000008c0', -31.4, -57.96);

insert into public.campania (id, nombre, tipo, fecha_inicio, fecha_fin, coordinador_id, deleted_at) values
  ('01920000-0000-7000-8000-0000000008e1', 'Verano', 'VERANO', current_date - 10, current_date + 30, '01920000-0000-7000-8000-0000000008a1', null),
  ('01920000-0000-7000-8000-0000000008e2', 'Salto', 'VERANO', current_date - 10, null, '01920000-0000-7000-8000-0000000008a2', null),
  ('01920000-0000-7000-8000-0000000008e3', 'Vieja', 'VERANO', current_date - 90, current_date - 30, '01920000-0000-7000-8000-0000000008a1', null),
  ('01920000-0000-7000-8000-0000000008e4', 'Borrada', 'VERANO', current_date - 10, current_date + 30, '01920000-0000-7000-8000-0000000008a1', now()),
  ('01920000-0000-7000-8000-0000000008e5', 'Otoño', 'PERMANENTE', current_date - 10, null, '01920000-0000-7000-8000-0000000008a2', null);
insert into public.campania_ciudad (campania_id, ciudad_id) values
  ('01920000-0000-7000-8000-0000000008e1', '01920000-0000-7000-8000-0000000008c1'),
  ('01920000-0000-7000-8000-0000000008e2', '01920000-0000-7000-8000-0000000008c2'),
  ('01920000-0000-7000-8000-0000000008e3', '01920000-0000-7000-8000-0000000008c1'),
  ('01920000-0000-7000-8000-0000000008e4', '01920000-0000-7000-8000-0000000008c1'),
  ('01920000-0000-7000-8000-0000000008e5', '01920000-0000-7000-8000-0000000008c1');

-- Desde 0008 toda zona es de una ciudad de una campaña: Centro y Borrada pasan a Verano, y
-- Salto centro a Salto (antes eran de la ciudad, sin campaña).
insert into public.zona (id, nombre, campania_ciudad_id, tipo_forma, centro_lat, centro_lon, radio_m, deleted_at)
select x.id::uuid, x.nombre, cc.id, 'RADIAL', x.lat, x.lon, 300, x.borrada
  from (values ('01920000-0000-7000-8000-0000000008d1', 'Centro',       '01920000-0000-7000-8000-0000000008e1', -34.90, -56.18, null::timestamptz),
               ('01920000-0000-7000-8000-0000000008d2', 'Cordón',       '01920000-0000-7000-8000-0000000008e1', -34.90, -56.14, null),
               ('01920000-0000-7000-8000-0000000008d3', 'Salto centro', '01920000-0000-7000-8000-0000000008e2', -31.40, -57.96, null),
               ('01920000-0000-7000-8000-0000000008d4', 'Pocitos',      '01920000-0000-7000-8000-0000000008e5', -34.90, -56.18, null),
               ('01920000-0000-7000-8000-0000000008d5', 'Borrada',      '01920000-0000-7000-8000-0000000008e1', -34.90, -56.18, now()))
       x(id, nombre, campania, lat, lon, borrada)
  join public.campania_ciudad cc on cc.campania_id = x.campania::uuid;

-- d6: zona de Verano en Salto, una ciudad que después se quitó de la campaña (CZ005).
insert into public.campania_ciudad (id, campania_id, ciudad_id) values
  ('01920000-0000-7000-8000-0000000008f1', '01920000-0000-7000-8000-0000000008e1', '01920000-0000-7000-8000-0000000008c2');
insert into public.zona (id, nombre, campania_ciudad_id, tipo_forma, centro_lat, centro_lon, radio_m) values
  ('01920000-0000-7000-8000-0000000008d6', 'Ciudad quitada', '01920000-0000-7000-8000-0000000008f1', 'RADIAL', -31.40, -57.96, 300);
update public.campania_ciudad set deleted_at = now() where id = '01920000-0000-7000-8000-0000000008f1';

insert into public.campania_colportor (campania_id, usuario_id, deleted_at) values
  ('01920000-0000-7000-8000-0000000008e1', '01920000-0000-7000-8000-0000000008b1', null),
  ('01920000-0000-7000-8000-0000000008e1', '01920000-0000-7000-8000-0000000008b2', now()),
  ('01920000-0000-7000-8000-0000000008e2', '01920000-0000-7000-8000-0000000008b3', null),
  ('01920000-0000-7000-8000-0000000008e3', '01920000-0000-7000-8000-0000000008b4', null),
  ('01920000-0000-7000-8000-0000000008e1', '01920000-0000-7000-8000-0000000008b5', null);

update public.usuario set deleted_at = now() where id = '01920000-0000-7000-8000-0000000008b5';

-- ---------------------------------------------------------------------------
-- 1. Forma y privilegios
-- ---------------------------------------------------------------------------
select function_returns('public', 'asignar_zona', array['uuid','uuid','uuid'], 'campania_colportor',
                        'asignar_zona(uuid, uuid, uuid) devuelve la fila de campania_colportor');
select is((select prosecdef from pg_proc where oid = 'public.asignar_zona(uuid,uuid,uuid)'::regprocedure),
          true, 'asignar_zona() es SECURITY DEFINER: el único camino para cambiar zona_id con JWT');
select is((select proconfig from pg_proc where oid = 'public.asignar_zona(uuid,uuid,uuid)'::regprocedure),
          array['search_path=""'], 'asignar_zona() fija search_path vacío');
select ok(has_function_privilege('authenticated', 'public.asignar_zona(uuid,uuid,uuid)', 'execute'),
          'authenticated ejecuta asignar_zona()');
select ok(not has_function_privilege('anon', 'public.asignar_zona(uuid,uuid,uuid)', 'execute'),
          'anon NO ejecuta asignar_zona()');
select ok(not has_function_privilege('authenticated', 'public.motivo_rechazo_zona(uuid,uuid,uuid)', 'execute'),
          'authenticated NO ejecuta motivo_rechazo_zona()');
select ok(not has_function_privilege('authenticated', 'public.motivo_campania_del_coordinador(uuid)', 'execute'),
          'authenticated NO ejecuta motivo_campania_del_coordinador()');

select throws_ok(
  $$ select public.asignar_zona('01920000-0000-7000-8000-0000000008e1', '01920000-0000-7000-8000-0000000008b1', '01920000-0000-7000-8000-0000000008d1') $$,
  '42501', null, 'sin JWT, asignar_zona() falla'
);
select set_config('role', 'anon', true);
select throws_ok(
  $$ select public.asignar_zona('01920000-0000-7000-8000-0000000008e1', '01920000-0000-7000-8000-0000000008b1', '01920000-0000-7000-8000-0000000008d1') $$,
  '42501', null, 'anon no puede asignar zonas'
);
select set_config('role', 'postgres', true);

-- ---------------------------------------------------------------------------
-- 2. Acceso: colportor y coordinador de otra campaña
-- ---------------------------------------------------------------------------
select pg_temp.actuar_como('01920000-0000-7000-8000-0000000008a0');
select throws_ok(
  $$ select public.asignar_zona('01920000-0000-7000-8000-0000000008e1', '01920000-0000-7000-8000-0000000008b1', '01920000-0000-7000-8000-0000000008d1') $$,
  '42501', null, 'un colportor no puede asignar zonas'
);
select throws_ok(
  $$ select public.asignar_zona('01920000-0000-7000-8000-0000000008e1', '01920000-0000-7000-8000-0000000008a0', '01920000-0000-7000-8000-0000000008d1') $$,
  '42501', null, 'un colportor no puede asignarse una zona a sí mismo'
);

select pg_temp.actuar_como('01920000-0000-7000-8000-0000000008a2');
select throws_ok(
  $$ select public.asignar_zona('01920000-0000-7000-8000-0000000008e1', '01920000-0000-7000-8000-0000000008b1', '01920000-0000-7000-8000-0000000008d1') $$,
  '42501', null, 'el coordinador de Salto no asigna zonas en Verano'
);
select throws_ok(
  $$ select public.asignar_zona('01920000-0000-7000-8000-0000000008e1', '01920000-0000-7000-8000-0000000008b6', '01920000-0000-7000-8000-0000000008d3') $$,
  '42501', null, 'el coordinador ajeno recibe 42501 antes que cualquier dato (no CZ003 ni CZ005)'
);

-- ---------------------------------------------------------------------------
-- 3. Reglas, como coordinador de Verano
-- ---------------------------------------------------------------------------
select pg_temp.actuar_como('01920000-0000-7000-8000-0000000008a1');

select throws_ok(
  $$ select public.asignar_zona('01920000-0000-7000-8000-0000000008ff', '01920000-0000-7000-8000-0000000008b1', '01920000-0000-7000-8000-0000000008d1') $$,
  'CZ001', 'La campaña no existe.', 'campaña inexistente → CZ001'
);
select throws_ok(
  $$ select public.asignar_zona('01920000-0000-7000-8000-0000000008e4', '01920000-0000-7000-8000-0000000008b1', '01920000-0000-7000-8000-0000000008d1') $$,
  'CZ001', null, 'campaña borrada → CZ001'
);
select throws_ok(
  $$ select public.asignar_zona('01920000-0000-7000-8000-0000000008e3', '01920000-0000-7000-8000-0000000008b4', '01920000-0000-7000-8000-0000000008d1') $$,
  'CZ002', null, 'campaña terminada → CZ002'
);
select throws_ok(
  $$ select public.asignar_zona('01920000-0000-7000-8000-0000000008e1', '01920000-0000-7000-8000-0000000008b6', '01920000-0000-7000-8000-0000000008d1') $$,
  'CZ003', 'El colportor no está en esta campaña.', 'colportor sin inscripción en la campaña → CZ003'
);
select throws_ok(
  $$ select public.asignar_zona('01920000-0000-7000-8000-0000000008e1', '01920000-0000-7000-8000-0000000008b2', '01920000-0000-7000-8000-0000000008d1') $$,
  'CZ003', null, 'inscripción borrada → CZ003'
);
select throws_ok(
  $$ select public.asignar_zona('01920000-0000-7000-8000-0000000008e1', '01920000-0000-7000-8000-0000000008b3', '01920000-0000-7000-8000-0000000008d1') $$,
  'CZ003', null, 'colportor de otra campaña → CZ003'
);
select throws_ok(
  $$ select public.asignar_zona('01920000-0000-7000-8000-0000000008e1', '01920000-0000-7000-8000-0000000008b5', '01920000-0000-7000-8000-0000000008d1') $$,
  'CZ003', null, 'colportor dado de baja → CZ003'
);
select throws_ok(
  $$ select public.asignar_zona('01920000-0000-7000-8000-0000000008e1', '01920000-0000-7000-8000-0000000008b1', '01920000-0000-7000-8000-0000000008fe') $$,
  'CZ004', 'La zona no existe o ya se dio de baja. Recargá el mapa.', 'zona inexistente → CZ004 (texto de 0009)'
);
select throws_ok(
  $$ select public.asignar_zona('01920000-0000-7000-8000-0000000008e1', '01920000-0000-7000-8000-0000000008b1', null) $$,
  'CZ004', null, 'sin zona (null) → CZ004: desasignar no está en la HU'
);
select throws_ok(
  $$ select public.asignar_zona('01920000-0000-7000-8000-0000000008e1', '01920000-0000-7000-8000-0000000008b1', '01920000-0000-7000-8000-0000000008d5') $$,
  'CZ004', null, 'zona borrada → CZ004'
);
select throws_ok(
  $$ select public.asignar_zona('01920000-0000-7000-8000-0000000008e1', '01920000-0000-7000-8000-0000000008b1', '01920000-0000-7000-8000-0000000008d3') $$,
  'CZ006', 'La zona es de otra campaña. Elegí una zona de «Verano».', 'zona de otra ciudad (y otra campaña) → CZ006 desde 0008'
);
select throws_ok(
  $$ select public.asignar_zona('01920000-0000-7000-8000-0000000008e1', '01920000-0000-7000-8000-0000000008b1', '01920000-0000-7000-8000-0000000008d6') $$,
  'CZ005', 'La ciudad de esa zona ya no está en «Verano». Elegí una zona de otra ciudad de la campaña o volvé a agregar la ciudad.',
  'zona de una ciudad que se quitó de la campaña → CZ005 (edge de la HU, desde 0008)'
);
select throws_ok(
  $$ select public.asignar_zona('01920000-0000-7000-8000-0000000008e1', '01920000-0000-7000-8000-0000000008b1', '01920000-0000-7000-8000-0000000008d4') $$,
  'CZ006', 'La zona es de otra campaña. Elegí una zona de «Verano».', 'zona de otra campaña de la misma ciudad → CZ006'
);

-- ---------------------------------------------------------------------------
-- 4. El caso feliz y la zona anterior
-- ---------------------------------------------------------------------------
select pg_temp.actuar_como('01920000-0000-7000-8000-0000000008b1');
select is((select count(*) from public.mis_zonas()), 0::bigint, 'b1, inscripto sin zona, no tiene zonas');

select pg_temp.actuar_como('01920000-0000-7000-8000-0000000008a1');
select is(
  (select zona_id from public.asignar_zona('01920000-0000-7000-8000-0000000008e1', '01920000-0000-7000-8000-0000000008b1', '01920000-0000-7000-8000-0000000008d1')),
  '01920000-0000-7000-8000-0000000008d1'::uuid,
  'el coordinador de Verano asigna Centro (zona de la ciudad, sin campaña) a b1'
);
select pg_temp.actuar_como('01920000-0000-7000-8000-0000000008b1');
select set_eq($$ select * from public.mis_zonas() $$,
              $$ values ('01920000-0000-7000-8000-0000000008d1'::uuid) $$,
              'b1 ve Centro en mis_zonas()');

select pg_temp.actuar_como('01920000-0000-7000-8000-0000000008a1');
select is(
  (select zona_id from public.asignar_zona('01920000-0000-7000-8000-0000000008e1', '01920000-0000-7000-8000-0000000008b1', '01920000-0000-7000-8000-0000000008d2')),
  '01920000-0000-7000-8000-0000000008d2'::uuid,
  'cambia a Cordón (zona de su propia campaña)'
);
select pg_temp.actuar_como('01920000-0000-7000-8000-0000000008b1');
select set_eq($$ select * from public.mis_zonas() $$,
              $$ values ('01920000-0000-7000-8000-0000000008d2'::uuid) $$,
              'la zona anterior deja de estar en mis_zonas(): asignar reemplaza');

-- Asignar la misma zona no toca la fila.
select pg_temp.actuar_como_servidor();
create temp table sv_antes as
  select sync_version from public.campania_colportor
   where campania_id = '01920000-0000-7000-8000-0000000008e1' and usuario_id = '01920000-0000-7000-8000-0000000008b1';
grant select on sv_antes to authenticated;
select pg_temp.actuar_como('01920000-0000-7000-8000-0000000008a1');
select is(
  (select sync_version from public.asignar_zona('01920000-0000-7000-8000-0000000008e1', '01920000-0000-7000-8000-0000000008b1', '01920000-0000-7000-8000-0000000008d2')),
  (select sync_version from sv_antes),
  'reasignar la misma zona devuelve la fila sin subir sync_version'
);

-- El ADMIN asigna en cualquier campaña, con las mismas reglas.
select pg_temp.actuar_como('01920000-0000-7000-8000-0000000008ad');
select is(
  (select zona_id from public.asignar_zona('01920000-0000-7000-8000-0000000008e2', '01920000-0000-7000-8000-0000000008b3', '01920000-0000-7000-8000-0000000008d3')),
  '01920000-0000-7000-8000-0000000008d3'::uuid,
  'el ADMIN asigna zona en una campaña que no coordina'
);
select throws_ok(
  $$ select public.asignar_zona('01920000-0000-7000-8000-0000000008e2', '01920000-0000-7000-8000-0000000008b3', '01920000-0000-7000-8000-0000000008d1') $$,
  'CZ006', null, 'el ADMIN tampoco asigna una zona de otra campaña'
);

-- ---------------------------------------------------------------------------
-- 5. zona_id no cambia por UPDATE directo
-- ---------------------------------------------------------------------------
select pg_temp.actuar_como('01920000-0000-7000-8000-0000000008a1');
select throws_ok(
  $$ update public.campania_colportor set zona_id = '01920000-0000-7000-8000-0000000008d3'
      where campania_id = '01920000-0000-7000-8000-0000000008e1'
        and usuario_id = '01920000-0000-7000-8000-0000000008b1' $$,
  '23514', null, 'el coordinador no cambia zona_id con un UPDATE directo (se saltearía CZ005)'
);
select pg_temp.actuar_como('01920000-0000-7000-8000-0000000008a2');
select throws_ok(
  $$ update public.campania_colportor set zona_id = '01920000-0000-7000-8000-0000000008d4'
      where campania_id = '01920000-0000-7000-8000-0000000008e1'
        and usuario_id = '01920000-0000-7000-8000-0000000008b1' $$,
  '23514', null, 'un coordinador ajeno tampoco (la política UPDATE de 0003 se lo dejaba)'
);
select pg_temp.actuar_como('01920000-0000-7000-8000-0000000008ad');
select throws_ok(
  $$ update public.campania_colportor set zona_id = '01920000-0000-7000-8000-0000000008d1'
      where campania_id = '01920000-0000-7000-8000-0000000008e1'
        and usuario_id = '01920000-0000-7000-8000-0000000008b1' $$,
  '23514', null, 'ni el ADMIN: la zona se asigna con asignar_zona()'
);
select pg_temp.actuar_como('01920000-0000-7000-8000-0000000008a1');
select lives_ok(
  $$ update public.campania_colportor set meta_libros = 25
      where campania_id = '01920000-0000-7000-8000-0000000008e1'
        and usuario_id = '01920000-0000-7000-8000-0000000008b1' $$,
  'el resto del UPDATE no cambia (acotarlo es de HU-CAM-005)'
);
select is(
  (select (zona_id, meta_libros)::text from public.campania_colportor
    where campania_id = '01920000-0000-7000-8000-0000000008e1'
      and usuario_id = '01920000-0000-7000-8000-0000000008b1'),
  ('01920000-0000-7000-8000-0000000008d2'::uuid, 25)::text,
  '...y la fila queda con Cordón y meta_libros = 25'
);

-- Un proceso servidor (sin ser authenticated) sí cambia zona_id directo.
select pg_temp.actuar_como_servidor();
select lives_ok(
  $$ update public.campania_colportor set zona_id = '01920000-0000-7000-8000-0000000008d1'
      where campania_id = '01920000-0000-7000-8000-0000000008e1'
        and usuario_id = '01920000-0000-7000-8000-0000000008b1' $$,
  'un proceso servidor cambia zona_id directo'
);

-- ---------------------------------------------------------------------------
-- 6. Red del RPC: un UPDATE que no se aplica no es éxito
-- ---------------------------------------------------------------------------
-- La carrera real (soft delete concurrente entre el chequeo y el UPDATE) necesita dos
-- sesiones; el lock FOR UPDATE la cierra. Acá se cubre la red: un trigger de prueba que
-- descarta el UPDATE (0 filas afectadas) tiene que terminar en CZ003, no en una fila
-- devuelta como si la zona se hubiera asignado. b1 tiene hoy Centro (d1).
select pg_temp.actuar_como_servidor();
create function public.zz_test_descartar_update() returns trigger language plpgsql as $$
begin
  return null;
end $$;
create trigger zz_test_descartar_update before update on public.campania_colportor
  for each row execute function public.zz_test_descartar_update();

select pg_temp.actuar_como('01920000-0000-7000-8000-0000000008a1');
select throws_ok(
  $$ select public.asignar_zona('01920000-0000-7000-8000-0000000008e1', '01920000-0000-7000-8000-0000000008b1', '01920000-0000-7000-8000-0000000008d2') $$,
  'CZ003', null, 'si el UPDATE afecta 0 filas y la zona era otra → CZ003, no éxito'
);
select is(
  (select zona_id from public.asignar_zona('01920000-0000-7000-8000-0000000008e1', '01920000-0000-7000-8000-0000000008b1', '01920000-0000-7000-8000-0000000008d1')),
  '01920000-0000-7000-8000-0000000008d1'::uuid,
  'con la misma zona, 0 filas sigue siendo éxito (no había nada que cambiar)'
);

select pg_temp.actuar_como_servidor();
drop trigger zz_test_descartar_update on public.campania_colportor;
drop function public.zz_test_descartar_update();

select * from finish();
rollback;
