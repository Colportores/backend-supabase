-- pgTAP · migración 0028 (backend-supabase#41, decisión de Cristian del 02/10): inscribir_colportor()
-- reactiva la inscripción dada de baja de esa campaña (la misma fila, sin zona) en vez de rechazarla
-- con CI008, con las mismas reglas de siempre; un UPDATE directo sigue sin poder reactivar; y las
-- cuentas de coordinador o admin se inscriben como colportores sin restricción de rol.
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

create or replace function pg_temp.actuar_como_anon() returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', '', true);
  perform set_config('request.jwt.claim.sub', '', true);
  perform set_config('role', 'anon', true);
end $$;

create or replace function pg_temp.u(p_sufijo text) returns uuid language sql as $$
  select ('01920000-0000-7000-8000-0000000035' || p_sufijo)::uuid;
$$;

-- La inscripción (campaña, usuario): cuántas filas hay y si está viva.
create or replace function pg_temp.filas(p_campania text, p_usuario text) returns bigint language sql as $$
  select count(*) from public.campania_colportor cc
   where cc.campania_id = pg_temp.u(p_campania) and cc.usuario_id = pg_temp.u(p_usuario);
$$;
create or replace function pg_temp.viva(p_campania text, p_usuario text) returns boolean language sql as $$
  select cc.deleted_at is null from public.campania_colportor cc
   where cc.campania_id = pg_temp.u(p_campania) and cc.usuario_id = pg_temp.u(p_usuario);
$$;
-- Tramos de zona abiertos de una inscripción (hasta null).
create or replace function pg_temp.tramos_abiertos(p_campania text, p_usuario text) returns bigint language sql as $$
  select count(*) from public.campania_colportor_zona_historial h
    join public.campania_colportor cc on cc.id = h.campania_colportor_id
   where cc.campania_id = pg_temp.u(p_campania) and cc.usuario_id = pg_temp.u(p_usuario) and h.hasta is null;
$$;
create or replace function pg_temp.tramos(p_campania text, p_usuario text) returns bigint language sql as $$
  select count(*) from public.campania_colportor_zona_historial h
    join public.campania_colportor cc on cc.id = h.campania_colportor_id
   where cc.campania_id = pg_temp.u(p_campania) and cc.usuario_id = pg_temp.u(p_usuario);
$$;
-- El DETAIL de un error (lo que PostgREST devuelve en `details`).
create or replace function pg_temp.detalle_error(p_sql text) returns text language plpgsql as $$
declare
  v_detalle text;
begin
  execute p_sql;
  return null;
exception when others then
  get stacked diagnostics v_detalle = pg_exception_detail;
  return v_detalle;
end $$;

-- --- fixtures (como postgres) --------------------------------------------------
-- Staff: a1 coordina Verano (e1) y Vieja (e4); a2 coordina Salto (e2); ad ADMIN; a0 colportor.
-- Campañas: e1 Verano y e2 Salto vigentes; e4 Vieja, terminada. Ciudad c1; zonas de Verano: d1 Norte, d2 Sur.
-- Inscripciones dadas de baja en Verano:
--   b1 Bea Uno       con meta_libros = 30, creada por ad; cuando estaba tenía a Norte y se la sacaron al
--                    darla de baja (0022: la baja la deja sin zona y cierra su tramo)
--   b2 Carlos Dos    del estado de antes de 0022: de baja CON Norte y su tramo abierto
--   b3 Dora Tres     igual, con Sur, que después se dio de baja
--   b4 Elsa Cuatro   suspendida
--   b5 Fede Cinco    y hoy está inscripta en Salto
--   b8 Hugo Ocho     una baja común    b9 Iris Nueve   otra, para el UPDATE directo
--   b6 Gina Seis     dada de baja en Vieja (terminada)
-- b7 Juan Siete no tiene ninguna inscripción.
insert into auth.users (id, instance_id, aud, role, email, encrypted_password, confirmed_at,
                        raw_user_meta_data, created_at, updated_at)
select pg_temp.u(x.s), '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
       x.s || '@reactivar35.test', 'x', now(),
       jsonb_build_object('nombre', x.n, 'apellido', x.a), now(), now()
  from (values ('a1', '', ''), ('a2', '', ''), ('ad', '', ''), ('a0', '', ''),
               ('b1', 'Bea', 'Uno'), ('b2', 'Carlos', 'Dos'), ('b3', 'Dora', 'Tres'), ('b4', 'Elsa', 'Cuatro'),
               ('b5', 'Fede', 'Cinco'), ('b6', 'Gina', 'Seis'), ('b7', 'Juan', 'Siete'), ('b8', 'Hugo', 'Ocho'),
               ('b9', 'Iris', 'Nueve')) x(s, n, a);
insert into public.usuario_rol (usuario_id, rol_id)
select pg_temp.u(x.s), r.id
  from (values ('a1','COORDINADOR'), ('a2','COORDINADOR'), ('ad','ADMIN'), ('a0','COLPORTOR')) x(s, codigo)
  join public.rol r on r.codigo = x.codigo;
update public.usuario set suspendido_en = now() where id = pg_temp.u('b4');

insert into public.pais (id, nombre, iso_code) values (pg_temp.u('c0'), 'Pais reactivar', 'ZR');
insert into public.ciudad (id, nombre, pais_id, lat_centro, lon_centro) values
  (pg_temp.u('c1'), 'Ciudad reactivar', pg_temp.u('c0'), -34.90, -56.16);
insert into public.campania (id, nombre, tipo, fecha_inicio, fecha_fin, coordinador_id) values
  (pg_temp.u('e1'), 'Verano',  'VERANO',     current_date - 10, current_date + 30, pg_temp.u('a1')),
  (pg_temp.u('e2'), 'Salto',   'PERMANENTE', current_date - 10, null,              pg_temp.u('a2')),
  (pg_temp.u('e4'), 'Vieja',   'VERANO',     current_date - 90, current_date - 30, pg_temp.u('a1'));
insert into public.campania_ciudad (id, campania_id, ciudad_id) values
  (pg_temp.u('f1'), pg_temp.u('e1'), pg_temp.u('c1')),
  (pg_temp.u('f2'), pg_temp.u('e2'), pg_temp.u('c1')),
  (pg_temp.u('f4'), pg_temp.u('e4'), pg_temp.u('c1'));
insert into public.zona (id, nombre, campania_ciudad_id, tipo_forma, centro_lat, centro_lon, radio_m) values
  (pg_temp.u('d1'), 'Norte', pg_temp.u('f1'), 'RADIAL', -34.88, -56.16, 300),
  (pg_temp.u('d2'), 'Sur',   pg_temp.u('f1'), 'RADIAL', -34.92, -56.16, 300);

-- b1: se inscribió, tuvo a Norte y la quitaron (la baja la deja sin zona). created_at lejano a propósito:
-- dentro de la transacción now() no cambia y no se distinguiría de un created_at nuevo.
insert into public.campania_colportor (id, campania_id, usuario_id, zona_id, meta_libros, created_at, created_by) values
  (pg_temp.u('c1'), pg_temp.u('e1'), pg_temp.u('b1'), pg_temp.u('d1'), 30, '2026-01-01 10:00+00', pg_temp.u('ad'));
update public.campania_colportor set deleted_at = now() where id = pg_temp.u('c1');
-- b2 y b3: como quedaban antes de 0022, de baja con su zona.
insert into public.campania_colportor (id, campania_id, usuario_id, zona_id, deleted_at) values
  (pg_temp.u('c2'), pg_temp.u('e1'), pg_temp.u('b2'), pg_temp.u('d1'), now()),
  (pg_temp.u('c3'), pg_temp.u('e1'), pg_temp.u('b3'), pg_temp.u('d2'), now());
update public.zona set deleted_at = now() where id = pg_temp.u('d2');
-- El resto, sin zona.
insert into public.campania_colportor (id, campania_id, usuario_id, deleted_at) values
  (pg_temp.u('c4'), pg_temp.u('e1'), pg_temp.u('b4'), now()),
  (pg_temp.u('c5'), pg_temp.u('e1'), pg_temp.u('b5'), now()),
  (pg_temp.u('c8'), pg_temp.u('e1'), pg_temp.u('b8'), now()),
  (pg_temp.u('c9'), pg_temp.u('e1'), pg_temp.u('b9'), now()),
  (pg_temp.u('c6'), pg_temp.u('e4'), pg_temp.u('b6'), now());
insert into public.campania_colportor (campania_id, usuario_id) values (pg_temp.u('e2'), pg_temp.u('b5'));

-- ---------------------------------------------------------------------------
-- 1. Punto de partida
-- ---------------------------------------------------------------------------
select is(pg_temp.filas('e1', 'b1'), 1::bigint, 'b1 tiene una sola inscripción en Verano');
select is(pg_temp.viva('e1', 'b1'), false, 'dada de baja');
select is((select zona_id from public.campania_colportor where id = pg_temp.u('c1')), null,
          'y sin zona (0022: la baja la deja sin zona)');
select is((select sync_version from public.campania_colportor where id = pg_temp.u('c1')), 1::bigint,
          'con la versión de sync en 1 (alta + baja)');
select is(pg_temp.tramos_abiertos('e1', 'b2'), 1::bigint, 'b2, de antes de 0022, tiene su tramo de Norte abierto');
select is((select zona_id from public.campania_colportor where id = pg_temp.u('c3')), pg_temp.u('d2'),
          'y b3 conserva la zona Sur, que ya se dio de baja');

-- ---------------------------------------------------------------------------
-- 2. El coordinador ve a la persona que quitó y puede volver a sumarla
-- ---------------------------------------------------------------------------
select pg_temp.actuar_como(pg_temp.u('a1'));
select results_eq(
  $$ select usuario_id, estado, campania_actual, motivo_bloqueo from public.buscar_candidatos(pg_temp.u('e1'), 'bea uno') $$,
  $$ values (pg_temp.u('b1'), 'PENDIENTE_ASIGNACION'::text, null::text, null::text) $$,
  'la búsqueda trae a la persona que quitó, sin motivo de bloqueo: «Añadir» habilitado');
select is((select count(*)::int from public.colportores_de_campania(pg_temp.u('e1')) where usuario_id = pg_temp.u('b1')), 0,
          'y no figura en el equipo mientras esté de baja');
select pg_temp.actuar_como(pg_temp.u('b1'));
select is(public.estado_cuenta(), 'PENDIENTE_ASIGNACION', 'su cuenta, pendiente de asignación');

select pg_temp.actuar_como(pg_temp.u('a1'));
select is((select f.id from public.inscribir_colportor(pg_temp.u('e1'), pg_temp.u('b1')) f), pg_temp.u('c1'),
          'inscribir_colportor() la reactiva: devuelve la misma fila (mismo id)');
select pg_temp.actuar_como_servidor();
select is(pg_temp.filas('e1', 'b1'), 1::bigint, 'no se creó otra inscripción');
select is(pg_temp.viva('e1', 'b1'), true, 'está viva');
select is((select zona_id from public.campania_colportor where id = pg_temp.u('c1')), null, 'vuelve sin zona');
select is((select meta_libros from public.campania_colportor where id = pg_temp.u('c1')), 30, 'conserva su meta_libros');
select is((select created_at from public.campania_colportor where id = pg_temp.u('c1')), '2026-01-01 10:00+00'::timestamptz,
          'conserva cuándo se inscribió la primera vez');
select is((select created_by from public.campania_colportor where id = pg_temp.u('c1')), pg_temp.u('ad'),
          'y quién la inscribió');
select is((select sync_version from public.campania_colportor where id = pg_temp.u('c1')), 2::bigint,
          'la reactivación sube la versión de sync, para que el delta la entregue');
select is(pg_temp.tramos('e1', 'b1'), 1::bigint, 'el historial de zonas no abre ningún tramo (vuelve sin zona)');
select is(pg_temp.tramos_abiertos('e1', 'b1'), 0::bigint, 'y no queda ninguno abierto');

select pg_temp.actuar_como(pg_temp.u('b1'));
select is(public.estado_cuenta(), 'ACTIVA', 'su cuenta pasa a ACTIVA sola');
select is((select count(*)::int from public.mis_zonas()), 0, 'sin zona hasta que el coordinador le asigne una');

select pg_temp.actuar_como(pg_temp.u('a1'));
select results_eq(
  $$ select usuario_id, zona_id from public.colportores_de_campania(pg_temp.u('e1')) where usuario_id = pg_temp.u('b1') $$,
  $$ values (pg_temp.u('b1'), null::uuid) $$,
  'vuelve a figurar en el equipo, en «Sin zona»');
select is((select count(*)::int from public.buscar_candidatos(pg_temp.u('e1'), 'bea uno')), 0,
          'y deja de ser candidata');
select lives_ok(
  $$ select public.asignar_zona(pg_temp.u('e1'), pg_temp.u('b1'), pg_temp.u('d1')) $$,
  'el coordinador le asigna una zona: vuelve a ser una colportora como cualquiera');
select pg_temp.actuar_como_servidor();
select is(pg_temp.tramos_abiertos('e1', 'b1'), 1::bigint, 'y se abre un tramo nuevo');

-- Reintentar con la inscripción ya viva: CI006, no una segunda fila.
select pg_temp.actuar_como(pg_temp.u('a1'));
select throws_ok($$ select public.inscribir_colportor(pg_temp.u('e1'), pg_temp.u('b1')) $$,
  'CI006', 'Ya está inscripto en esta campaña.', 'reintentar con la inscripción viva: CI006');
select pg_temp.actuar_como_servidor();
select is(pg_temp.filas('e1', 'b1'), 1::bigint, '...y sigue habiendo una sola');

-- Dos acciones seguidas: quitarla, volver a sumarla, quitarla y volver a sumarla.
select pg_temp.actuar_como(pg_temp.u('a1'));
update public.campania_colportor set deleted_at = now() where id = pg_temp.u('c1');
select lives_ok($$ select public.inscribir_colportor(pg_temp.u('e1'), pg_temp.u('b1')) $$, 'quitar y volver a sumar');
update public.campania_colportor set deleted_at = now() where id = pg_temp.u('c1');
select lives_ok($$ select public.inscribir_colportor(pg_temp.u('e1'), pg_temp.u('b1')) $$, 'y otra vez');
select pg_temp.actuar_como_servidor();
select is(pg_temp.filas('e1', 'b1'), 1::bigint, 'sigue siendo la misma fila');
select is(pg_temp.viva('e1', 'b1'), true, 'viva');
select is((select sync_version from public.campania_colportor where id = pg_temp.u('c1')), 7::bigint,
          'con una versión de sync por cada cambio (la asignación de zona, dos bajas y dos reactivaciones)');
select is((select zona_id from public.campania_colportor where id = pg_temp.u('c1')), null, 'y sin zona');

-- ---------------------------------------------------------------------------
-- 3. Las inscripciones de antes de 0022 (de baja con su zona) también vuelven, sin zona
-- ---------------------------------------------------------------------------
select pg_temp.actuar_como(pg_temp.u('a1'));
select lives_ok($$ select public.inscribir_colportor(pg_temp.u('e1'), pg_temp.u('b2')) $$,
  'b2, de baja con la zona Norte: se reactiva');
select lives_ok($$ select public.inscribir_colportor(pg_temp.u('e1'), pg_temp.u('b3')) $$,
  'b3, de baja con una zona que ya se dio de baja: también (no pide un arreglo que el coordinador no puede hacer)');
select pg_temp.actuar_como_servidor();
select is((select count(*)::int from public.campania_colportor where id in (pg_temp.u('c2'), pg_temp.u('c3')) and zona_id is not null),
          0, 'las dos vuelven sin zona');
select is(pg_temp.tramos_abiertos('e1', 'b2'), 0::bigint, 'y el tramo que había quedado abierto se cierra');
select is(pg_temp.tramos('e1', 'b2'), 1::bigint, 'sin abrir otro');
select is(pg_temp.viva('e1', 'b3'), true, 'b3 está viva');

-- ---------------------------------------------------------------------------
-- 4. Las reglas de siempre siguen valiendo al reactivar
-- ---------------------------------------------------------------------------
select pg_temp.actuar_como(pg_temp.u('a1'));
select throws_ok($$ select public.inscribir_colportor(pg_temp.u('e1'), pg_temp.u('b4')) $$,
  'CI005', 'La cuenta está suspendida. Contactá al administrador.', 'una cuenta suspendida no se reactiva (CI005)');
select throws_ok($$ select public.inscribir_colportor(pg_temp.u('e1'), pg_temp.u('b5')) $$,
  'CI007', 'Está en campaña Salto. Reasignar primero.', 'quien hoy está en otra campaña vigente, tampoco (CI007)');
select is(pg_temp.detalle_error($$ select public.inscribir_colportor(pg_temp.u('e1'), pg_temp.u('b5')) $$)::jsonb,
  jsonb_build_object('campania_id', pg_temp.u('e2'), 'campania_nombre', 'Salto'),
  'con la campaña en conflicto en details');
select throws_ok($$ select public.inscribir_colportor(pg_temp.u('e4'), pg_temp.u('b6')) $$,
  'CI002', null, 'en una campaña terminada no se reactiva (CI002)');
select pg_temp.actuar_como_servidor();
select is(pg_temp.viva('e1', 'b4'), false, 'b4 sigue de baja');
select is(pg_temp.viva('e1', 'b5'), false, 'b5 sigue de baja');
select is(pg_temp.viva('e4', 'b6'), false, 'b6 sigue de baja');

-- El permiso va primero: no se puede sondear nada de una cuenta ajena.
select pg_temp.actuar_como(pg_temp.u('a2'));
select throws_ok($$ select public.inscribir_colportor(pg_temp.u('e1'), pg_temp.u('b8')) $$,
  '42501', null, 'el coordinador de otra campaña no reactiva');
select throws_ok($$ select public.inscribir_colportor(pg_temp.u('e1'), pg_temp.u('b4')) $$,
  '42501', null, 'y recibe 42501 y no CI005: no sondea si la cuenta está suspendida');
select pg_temp.actuar_como(pg_temp.u('a0'));
select throws_ok($$ select public.inscribir_colportor(pg_temp.u('e1'), pg_temp.u('b8')) $$,
  '42501', null, 'un colportor no reactiva');
select pg_temp.actuar_como_anon();
select throws_ok($$ select public.inscribir_colportor(pg_temp.u('e1'), pg_temp.u('b8')) $$,
  '42501', null, 'anon tampoco');
select pg_temp.actuar_como_servidor();
select is(pg_temp.viva('e1', 'b8'), false, 'b8 sigue de baja');

-- Un UPDATE directo sigue sin poder reactivar: saltearía el permiso, la suspensión y la otra campaña.
select pg_temp.actuar_como(pg_temp.u('a1'));
select throws_ok(
  $$ update public.campania_colportor set deleted_at = null where id = pg_temp.u('c9') $$,
  '23514', 'una inscripción borrada se reactiva con inscribir_colportor() (HU-CAM-004), no con un UPDATE',
  'el coordinador de la campaña no reactiva con un UPDATE directo');
select pg_temp.actuar_como(pg_temp.u('ad'));
select throws_ok(
  $$ update public.campania_colportor set deleted_at = null where id = pg_temp.u('c9') $$,
  '23514', null, 'ni el ADMIN');
select pg_temp.actuar_como_servidor();
select is(pg_temp.viva('e1', 'b9'), false, 'b9 sigue de baja');
-- Un proceso del servidor (sin JWT) sí reactiva: la guarda es para quien escribe con JWT.
update public.campania_colportor set deleted_at = null where id = pg_temp.u('c9');
select is(pg_temp.viva('e1', 'b9'), true, 'el servidor reactiva directo (service_role, seeds, jobs)');

-- El ADMIN reactiva en cualquier campaña, con las mismas reglas.
select pg_temp.actuar_como(pg_temp.u('ad'));
select lives_ok($$ select public.inscribir_colportor(pg_temp.u('e1'), pg_temp.u('b8')) $$, 'el ADMIN reactiva');
select throws_ok($$ select public.inscribir_colportor(pg_temp.u('e1'), pg_temp.u('b4')) $$,
  'CI005', null, 'pero tampoco a una cuenta suspendida');
select pg_temp.actuar_como_servidor();
select is(pg_temp.viva('e1', 'b8'), true, 'b8 está viva');

-- Quien nunca estuvo sigue entrando por una fila nueva, con created_by del coordinador.
select pg_temp.actuar_como(pg_temp.u('a1'));
select is((select f.created_by from public.inscribir_colportor(pg_temp.u('e1'), pg_temp.u('b7')) f), pg_temp.u('a1'),
          'quien nunca estuvo en la campaña se inscribe como siempre (fila nueva, created_by = el coordinador)');
select pg_temp.actuar_como_servidor();
select is(pg_temp.filas('e1', 'b7'), 1::bigint, 'una sola fila');

-- ---------------------------------------------------------------------------
-- 5. Coordinador o admin como colportor: sin restricción de rol
-- ---------------------------------------------------------------------------
select pg_temp.actuar_como(pg_temp.u('a1'));
select results_eq(
  $$ select usuario_id, estado, motivo_bloqueo from public.buscar_candidatos(pg_temp.u('e1'), 'a2@reactivar35') $$,
  $$ values (pg_temp.u('a2'), 'PENDIENTE_ASIGNACION'::text, null::text) $$,
  'la búsqueda trae a otro coordinador, sin motivo de bloqueo');
select results_eq(
  $$ select usuario_id, estado, motivo_bloqueo from public.buscar_candidatos(pg_temp.u('e1'), 'ad@reactivar35') $$,
  $$ values (pg_temp.u('ad'), 'PENDIENTE_ASIGNACION'::text, null::text) $$,
  'y a un ADMIN');
select lives_ok($$ select public.inscribir_colportor(pg_temp.u('e1'), pg_temp.u('a2')) $$,
  'el coordinador de Verano inscribe como colportor al coordinador de Salto');
select lives_ok($$ select public.inscribir_colportor(pg_temp.u('e1'), pg_temp.u('ad')) $$,
  'y a un ADMIN');
select pg_temp.actuar_como(pg_temp.u('a2'));
select is(public.estado_cuenta(), 'ACTIVA', 'el coordinador de Salto pasa a ACTIVA como colportor de Verano');
select lives_ok($$ select public.inscribir_colportor(pg_temp.u('e2'), pg_temp.u('a0')) $$,
  'y sigue inscribiendo en la campaña que coordina');
select pg_temp.actuar_como(pg_temp.u('a1'));
select is((select count(*)::int from public.buscar_candidatos(pg_temp.u('e1'), 'a2@reactivar35')), 0,
          'ya no es candidato');
update public.campania_colportor set deleted_at = now()
 where campania_id = pg_temp.u('e1') and usuario_id = pg_temp.u('a2');
select lives_ok($$ select public.inscribir_colportor(pg_temp.u('e1'), pg_temp.u('a2')) $$,
  'si lo quita, también se reactiva');
select pg_temp.actuar_como_servidor();
select is(pg_temp.filas('e1', 'a2'), 1::bigint, 'con una sola inscripción');
select is(pg_temp.viva('e1', 'a2'), true, 'viva');

-- ---------------------------------------------------------------------------
-- 6. Forma: nada cambió de firma ni de privilegios
-- ---------------------------------------------------------------------------
select function_returns('public', 'inscribir_colportor', array['uuid','uuid'], 'campania_colportor',
                        'inscribir_colportor(uuid, uuid) devuelve la fila de campania_colportor');
select is((select prosecdef from pg_proc where oid = 'public.inscribir_colportor(uuid,uuid)'::regprocedure),
          true, 'inscribir_colportor() sigue siendo SECURITY DEFINER');
select is((select proconfig from pg_proc where oid = 'public.inscribir_colportor(uuid,uuid)'::regprocedure),
          array['search_path=""'], 'con search_path vacío');
select ok(has_function_privilege('authenticated', 'public.inscribir_colportor(uuid,uuid)', 'execute'),
          'authenticated la ejecuta');
select ok(not has_function_privilege('anon', 'public.inscribir_colportor(uuid,uuid)', 'execute'),
          'anon no');
select ok(not has_function_privilege('authenticated', 'public.motivo_rechazo_inscripcion(uuid,uuid)', 'execute'),
          'motivo_rechazo_inscripcion() sigue siendo interna');
select ok(not (select prosrc like '%INSCRIPCION_BORRADA%' or prosrc like '%CI008%'
                 from pg_proc where oid = 'public.inscribir_colportor(uuid,uuid)'::regprocedure),
          'inscribir_colportor() ya no tiene CI008');
select ok(not (select prosrc like '%INSCRIPCION_BORRADA%'
                 from pg_proc where oid = 'public.motivo_rechazo_inscripcion(uuid,uuid)'::regprocedure),
          'ni motivo_rechazo_inscripcion() el motivo INSCRIPCION_BORRADA');

select * from finish();
rollback;
