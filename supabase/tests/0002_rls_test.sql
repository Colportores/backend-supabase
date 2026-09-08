-- pgTAP · políticas RLS de la migración 0001
-- Simula JWTs de dos colportores y verifica el aislamiento básico. Las políticas se refinan
-- HU por HU desde Sprint 3; acá se fija el piso: nadie ve ni escribe lo del otro.
begin;
select * from no_plan();

-- --- fixtures (como postgres, sin RLS) ---------------------------------------
insert into auth.users (id, instance_id, aud, role, email, encrypted_password, created_at, updated_at) values
  ('01920000-0000-7000-8000-0000000000a1', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'ana@example.com', 'x', now(), now()),
  ('01920000-0000-7000-8000-0000000000a2', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'beto@example.com', 'x', now(), now());

insert into public.pais (id, nombre, iso_code) values ('01920000-0000-7000-8000-0000000000c0', 'Uruguay', 'UY');
insert into public.ciudad (id, nombre, pais_id, lat_centro, lon_centro) values
  ('01920000-0000-7000-8000-0000000000c1', 'Montevideo', '01920000-0000-7000-8000-0000000000c0', -34.9, -56.16);
insert into public.zona (id, nombre, ciudad_id) values
  ('01920000-0000-7000-8000-0000000000d1', 'Zona Ana',  '01920000-0000-7000-8000-0000000000c1'),
  ('01920000-0000-7000-8000-0000000000d2', 'Zona Beto', '01920000-0000-7000-8000-0000000000c1');
update public.usuario set zona_id = '01920000-0000-7000-8000-0000000000d1' where id = '01920000-0000-7000-8000-0000000000a1';
update public.usuario set zona_id = '01920000-0000-7000-8000-0000000000d2' where id = '01920000-0000-7000-8000-0000000000a2';

insert into public.producto (id, nombre, tipo) values ('01920000-0000-7000-8000-0000000000e1', 'Libro', 'LIBRO');

-- --- helper: actuar como un usuario autenticado --------------------------------
-- Se setean las dos formas del claim: `request.jwt.claims` (PostgREST ≥ 9, auth.uid() de los
-- proyectos hosteados) y `request.jwt.claim.sub` (la que lee auth.uid() de la imagen base).
create or replace function pg_temp.actuar_como(p_uid uuid) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', json_build_object('sub', p_uid, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', p_uid::text, true);
  perform set_config('request.jwt.claim.role', 'authenticated', true);
  perform set_config('role', 'authenticated', true);
end $$;

-- --- Ana crea su jornada y una ubicación en su zona --------------------------------
select pg_temp.actuar_como('01920000-0000-7000-8000-0000000000a1');

select lives_ok(
  $$ insert into public.jornada (id, inicio) values ('01920000-0000-7000-8000-0000000000f1', now()) $$,
  'Ana crea una jornada (colportor_id por default = auth.uid())'
);
select is((select colportor_id from public.jornada where id = '01920000-0000-7000-8000-0000000000f1'),
          '01920000-0000-7000-8000-0000000000a1'::uuid, 'colportor_id se rellena con auth.uid()');

select lives_ok(
  $$ insert into public.ubicacion (id, tipo, calle, numero, lat, lon, ciudad_id, zona_id)
     values ('01920000-0000-7000-8000-0000000000f2', 'CASA', 'Av. 18 de Julio', '1000', -34.9, -56.18,
             '01920000-0000-7000-8000-0000000000c1', '01920000-0000-7000-8000-0000000000d1') $$,
  'Ana crea una ubicación en su zona'
);

select throws_ok(
  $$ insert into public.ubicacion (id, tipo, calle, numero, lat, lon, ciudad_id, zona_id)
     values ('01920000-0000-7000-8000-0000000000f3', 'CASA', 'Otra', '1', -34.9, -56.18,
             '01920000-0000-7000-8000-0000000000c1', '01920000-0000-7000-8000-0000000000d2') $$,
  '42501', null,
  'Ana NO puede crear una ubicación en la zona de Beto'
);

select throws_ok(
  $$ insert into public.jornada (id, inicio, colportor_id)
     values ('01920000-0000-7000-8000-0000000000f4', now(), '01920000-0000-7000-8000-0000000000a2') $$,
  '42501', null,
  'Ana NO puede crear una jornada a nombre de Beto'
);

select is((select count(*) from public.producto), 1::bigint, 'Ana lee el catálogo');
select throws_ok(
  $$ insert into public.producto (nombre, tipo) values ('Pirata', 'LIBRO') $$,
  '42501', null,
  'Ana (sin rol ADMIN) NO puede escribir el catálogo'
);

select throws_ok(
  $$ delete from public.jornada where id = '01920000-0000-7000-8000-0000000000f1' $$,
  '42501', null,
  'authenticated no puede DELETE físico'
);

-- --- Beto no ve lo de Ana --------------------------------------------------------
select pg_temp.actuar_como('01920000-0000-7000-8000-0000000000a2');

select is((select count(*) from public.jornada), 0::bigint, 'Beto no ve las jornadas de Ana');
select is((select count(*) from public.ubicacion), 0::bigint, 'Beto no ve ubicaciones fuera de su zona');
select is((select count(*) from public.usuario where id = '01920000-0000-7000-8000-0000000000a1'), 0::bigint,
          'Beto no ve el perfil de Ana');
select is((select count(*) from public.usuario where id = '01920000-0000-7000-8000-0000000000a2'), 1::bigint,
          'Beto ve su propio perfil');

-- --- ...pero Beto SÍ ve y escribe lo suyo -----------------------------------------
-- Contracara de los tres negativos de arriba. Sin esto, una política invertida que dejara a todo
-- el mundo afuera de sus propios datos pasaría igual: los counts darían 0 por el motivo equivocado.
select lives_ok(
  $$ insert into public.jornada (id, inicio) values ('01920000-0000-7000-8000-0000000000f5', now()) $$,
  'Beto crea su propia jornada'
);
select is((select count(*) from public.jornada), 1::bigint, 'Beto ve su propia jornada');

-- Sin calle ni numero: el alta por marcador manual sobre el mapa no los conoce (HU-UBI, ADR-018).
select lives_ok(
  $$ insert into public.ubicacion (id, tipo, lat, lon, ciudad_id, zona_id)
     values ('01920000-0000-7000-8000-0000000000f6', 'CASA', -34.88, -56.15,
             '01920000-0000-7000-8000-0000000000c1', '01920000-0000-7000-8000-0000000000d2') $$,
  'Beto crea una ubicación sin calle ni numero (alta por marcador manual)'
);
select is((select count(*) from public.ubicacion), 1::bigint, 'Beto ve su propia ubicación');

-- RF-UB08 es una advertencia del cliente, no un constraint: "crear igual con justificación" es una
-- salida deliberada de la HU y el cloud no puede rechazarla.
select lives_ok(
  $$ insert into public.ubicacion (id, tipo, calle, numero, lat, lon, ciudad_id, zona_id)
     values ('01920000-0000-7000-8000-0000000000f7', 'CASA', 'Av. 18 de Julio', '1000', -34.9, -56.18,
             '01920000-0000-7000-8000-0000000000c1', '01920000-0000-7000-8000-0000000000d2') $$,
  'una dirección duplicada se acepta (RF-UB08 se resuelve en el cliente)'
);

-- --- escalada de privilegios: las columnas que deciden qué filas se ven -------------
select pg_temp.actuar_como('01920000-0000-7000-8000-0000000000a1');

update public.usuario set zona_id = '01920000-0000-7000-8000-0000000000d2'
where id = '01920000-0000-7000-8000-0000000000a1';
select is((select zona_id from public.usuario where id = '01920000-0000-7000-8000-0000000000a1'),
          '01920000-0000-7000-8000-0000000000d1'::uuid,
          'Ana NO puede auto-asignarse la zona de Beto (R-SY04: la asignación gana del backend)');
select is((select count(*) from public.ubicacion), 1::bigint,
          'Ana sigue viendo solo su zona después de intentar la escalada');

update public.ubicacion set zona_id = '01920000-0000-7000-8000-0000000000d2'
where id = '01920000-0000-7000-8000-0000000000f2';
select is((select zona_id from public.ubicacion where id = '01920000-0000-7000-8000-0000000000f2'),
          '01920000-0000-7000-8000-0000000000d1'::uuid,
          'Ana NO puede mover su ubicación a la zona de Beto');

-- --- sync_version es del servidor también en el INSERT ------------------------------
select lives_ok(
  $$ insert into public.jornada (id, inicio, sync_version)
     values ('01920000-0000-7000-8000-0000000000f8', now(), 999) $$,
  'el INSERT con sync_version del cliente no falla'
);
select is((select sync_version from public.jornada where id = '01920000-0000-7000-8000-0000000000f8'),
          0::bigint,
          'el sync_version que manda el cliente en el INSERT se ignora (contrato §5.4)');

-- --- constraints de integridad del dominio ------------------------------------------
select throws_ok(
  $$ insert into public.house_status (ubicacion_id, lat, lon, tipo_ubicacion, zona_id, color, prioridad)
     values ('01920000-0000-7000-8000-0000000000f2', -34.9, -56.18, 'CASA',
             '01920000-0000-7000-8000-0000000000d1', 'RECHAZO', 1) $$,
  '23514', null,
  'house_status con color y prioridad contradictorios se rechaza (ADR-010)'
);
select lives_ok(
  $$ insert into public.house_status (ubicacion_id, lat, lon, tipo_ubicacion, zona_id, color, prioridad)
     values ('01920000-0000-7000-8000-0000000000f2', -34.9, -56.18, 'CASA',
             '01920000-0000-7000-8000-0000000000d1', 'RECHAZO', 7) $$,
  'house_status con el par color/prioridad de ADR-010 se acepta'
);

-- venta_item: la línea es aritmética pura. El descuento informal vive en venta.monto_total (S38).
insert into public.espacio (id, ubicacion_id) values
  ('01920000-0000-7000-8000-000000000101', '01920000-0000-7000-8000-0000000000f2');
insert into public.espacio_persona (id, espacio_id, persona_id) values
  ('01920000-0000-7000-8000-000000000102', '01920000-0000-7000-8000-000000000101',
   '01920000-0000-7000-8000-000000000103');
insert into public.venta (id, espacio_persona_id, numero_talonario, monto_total, fecha) values
  ('01920000-0000-7000-8000-000000000104', '01920000-0000-7000-8000-000000000102', 'A-1', 30000, now());

select throws_ok(
  $$ insert into public.venta_item (venta_id, producto_id, cantidad, precio_unitario, subtotal)
     values ('01920000-0000-7000-8000-000000000104', '01920000-0000-7000-8000-0000000000e1',
             3, 10000, 999999) $$,
  '23514', null,
  'venta_item con subtotal que no es cantidad * precio_unitario se rechaza'
);
select lives_ok(
  $$ insert into public.venta_item (venta_id, producto_id, cantidad, precio_unitario, subtotal)
     values ('01920000-0000-7000-8000-000000000104', '01920000-0000-7000-8000-0000000000e1',
             3, 10000, 30000) $$,
  'venta_item con el subtotal correcto se acepta'
);

-- --- vigencia: campaña terminada y baja administrativa ------------------------------
-- Fixtures como postgres (session_user), que no pasa por RLS.
select set_config('role', 'postgres', true);

insert into public.zona (id, nombre, ciudad_id) values
  ('01920000-0000-7000-8000-000000000201', 'Zona campaña vieja', '01920000-0000-7000-8000-0000000000c1'),
  ('01920000-0000-7000-8000-000000000202', 'Zona campaña viva',  '01920000-0000-7000-8000-0000000000c1');
insert into public.campania (id, nombre, tipo, fecha_inicio, fecha_fin, ciudad_id) values
  ('01920000-0000-7000-8000-000000000203', 'Verano 2020', 'VERANO', '2020-01-01', '2020-03-01',
   '01920000-0000-7000-8000-0000000000c1'),
  ('01920000-0000-7000-8000-000000000204', 'Permanente', 'PERMANENTE', current_date - 30, null,
   '01920000-0000-7000-8000-0000000000c1');
insert into public.campania_colportor (id, campania_id, usuario_id, zona_id) values
  ('01920000-0000-7000-8000-000000000205', '01920000-0000-7000-8000-000000000203',
   '01920000-0000-7000-8000-0000000000a2', '01920000-0000-7000-8000-000000000201'),
  ('01920000-0000-7000-8000-000000000206', '01920000-0000-7000-8000-000000000204',
   '01920000-0000-7000-8000-0000000000a2', '01920000-0000-7000-8000-000000000202');

select pg_temp.actuar_como('01920000-0000-7000-8000-0000000000a2');

-- La inscripción de una campaña terminada no se soft-deletea sola: sin filtrar por fechas seguiría
-- dando acceso a la zona para siempre.
select is((select count(*) from public.mis_zonas() z where z = '01920000-0000-7000-8000-000000000201'),
          0::bigint,
          'una campaña terminada ya no da acceso a su zona');
select is((select count(*) from public.mis_zonas() z where z = '01920000-0000-7000-8000-000000000202'),
          1::bigint,
          'una campaña vigente sí da acceso a su zona');

-- Baja administrativa (ADR-011): la revocación de sesión ocurre fuera de esta base, así que los
-- helpers de autorización tienen que caerse solos si la sesión sobrevive.
select set_config('role', 'postgres', true);
update public.usuario set deleted_at = now() where id = '01920000-0000-7000-8000-0000000000a2';
select pg_temp.actuar_como('01920000-0000-7000-8000-0000000000a2');

select is((select count(*) from public.mis_zonas()), 0::bigint,
          'un usuario con baja administrativa pierde todas sus zonas (ADR-011)');
select is(public.tiene_rol('COLPORTOR'), false,
          'un usuario con baja administrativa pierde sus roles (ADR-011)');

-- --- anon no ve nada ----------------------------------------------------------------
select set_config('role', 'anon', true);
select throws_ok($$ select count(*) from public.producto $$, '42501', null, 'anon no puede leer ni el catálogo');

-- --- rendimiento de las políticas (0003) -------------------------------------
-- Una llamada suelta en el USING se evalúa POR FILA; envuelta en (select ...) se
-- convierte en InitPlan y se evalúa una vez. Medido con supabase/bench sobre
-- 390.000 filas, la diferencia en el delta de `ubicacion` fue 1210 ms → 14 ms.
-- Este test existe para que una política nueva no vuelva a perderlo en silencio.
select set_config('role', 'postgres', true);

-- Toda aparición tiene que venir precedida por SELECT. Se cuentan las dos
-- formas y se comparan: si hay más llamadas que llamadas envueltas, alguna
-- quedó suelta y se evalúa por fila.
select is(
  (select array_agg(policyname::text order by policyname)
     from pg_policies p,
          lateral (select coalesce(p.qual, '') || ' ' || coalesce(p.with_check, '') as e) x
    where p.schemaname = 'public'
      and regexp_count(x.e, 'tiene_rol\(') > regexp_count(x.e, 'SELECT tiene_rol\(')),
  null::text[],
  'ninguna política llama a tiene_rol() sin envolver en (select ...)'
);

select is(
  (select array_agg(policyname::text order by policyname)
     from pg_policies p,
          lateral (select coalesce(p.qual, '') || ' ' || coalesce(p.with_check, '') as e) x
    where p.schemaname = 'public'
      and regexp_count(x.e, 'auth\.uid\(\)') > regexp_count(x.e, 'SELECT auth\.uid\(\)')),
  null::text[],
  'ninguna política llama a auth.uid() sin envolver en (select ...)'
);

-- Y que el guard sirva de algo: una política suelta tiene que hacerlo fallar.
create policy zz_guard_canario on public.jornada
  for select to authenticated using (colportor_id = auth.uid());
select is(
  (select count(*)::integer from pg_policies p
    where p.schemaname = 'public' and p.policyname = 'zz_guard_canario'
      and regexp_count(coalesce(p.qual, ''), 'auth\.uid\(\)')
        > regexp_count(coalesce(p.qual, ''), 'SELECT auth\.uid\(\)')),
  1,
  'el guard detecta una política con auth.uid() suelto (canario)'
);
drop policy zz_guard_canario on public.jornada;

select * from finish();
rollback;
