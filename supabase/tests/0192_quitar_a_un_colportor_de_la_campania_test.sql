-- pgTAP · migración 0192 (backend-supabase#273, HU-CAM-005 «Remover»; decisiones del 11/11): quitar_de_campania(campaña,
-- usuario) da de baja la inscripción viva sin borrar nada.
--   1. Forma y privilegios.
--   2. Permisos: sin sesión, un colportor y el coordinador de otra campaña no quitan (42501), y no cambia nada.
--   3. Rechazos: QC001 campaña inexistente, QC002 terminada, QC003 no está o ya lo quitaron.
--   4. La baja: deleted_at, sin zona y el tramo cerrado con quién, la jornada abierta cerrada (republicada, sin subir la
--      versión), las demás jornadas como estaban, la cuenta de alquiler en debe 0 y viva, el evento en audit_log y el
--      estado de la cuenta.
--   5. Otra campaña: quitarlo de la por empezar no le cierra la jornada de la en curso y la cuenta sigue ACTIVA; un segundo
--      coordinador y un ADMIN también quitan.
--   6. Nada se pierde: lo que el teléfono registró antes de la baja y sube después (la jornada con la versión de antes, la
--      visita y la venta) entra.
--   7. Volver a añadirlo reactiva la misma inscripción, sin zona, y vuelve a deber el alquiler.
--   8. La baja por otro camino (UPDATE del servidor) también cierra la jornada.
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

create or replace function pg_temp.u(p_sufijo text) returns uuid language sql immutable as $$
  select ('01920000-0000-7000-8000-0000000192' || p_sufijo)::uuid
$$;

-- «quitado|zona» de una inscripción: «viva» o «baja», y la zona o «-».
create or replace function pg_temp.inscripcion(p_id text) returns text language sql as $$
  select case when cc.deleted_at is null then 'viva' else 'baja' end || '|' || coalesce(cc.zona_id::text, '-')
    from public.campania_colportor cc where cc.id = pg_temp.u(p_id)
$$;

-- «abierta|v<versión>» o «fin|v<versión>» de una jornada.
create or replace function pg_temp.jornada(p_id text) returns text language sql as $$
  select case when j.fin is null then 'abierta' else 'cerrada' end || '|v' || j.sync_version
    from public.jornada j where j.id = pg_temp.u(p_id)
$$;

create or replace function pg_temp.push(p_jobs jsonb) returns jsonb language sql as $$
  select public.sync_push(jsonb_build_object(
    'device', jsonb_build_object('device_id', '01920000-0000-7000-8000-0000000192d0',
                                 'app_version', '1.4.2', 'schema_version', 1),
    'jobs', p_jobs));
$$;
create or replace function pg_temp.resultados(p_r jsonb) returns text[] language sql as $$
  select array_agg((e ->> 'outcome') || coalesce(' ' || (e ->> 'code'), '') order by i)
    from jsonb_array_elements(p_r -> 'results') with ordinality x(e, i);
$$;

-- --- fixtures (como postgres) --------------------------------------------------
-- Staff: a1 coordina Verano (e1), Diciembre (e3) y Vieja (e4); a5 es el segundo coordinador de Verano; a2 coordina Otra
-- (e2); ad ADMIN; a0 colportor sin rol de personal.
-- Campañas: e1 Verano en curso (hoy-10 .. hoy+30, alquiler 500,00), e2 Otra en curso, e3 Diciembre por empezar
-- (hoy+40 .. hoy+80), e4 Vieja terminada. Zona d1 Norte en Verano.
-- Colportores (inscriptos hace 5 días, salvo que se diga):
--   b1 Ana   en Verano con Norte. Jornadas: 21 abierta desde hace 2 h, 22 cerrada ayer, 23 abierta de hace 20 días (antes
--            de inscribirse: de otra cosa, no se toca).
--   b2 Beto  en Verano y en Diciembre (por empezar, sumado ayer). Jornada 24 abierta desde hace 1 h.
--   b3 Caro  en Vieja (terminada).
--   b4 Dani  sin inscripción en Verano.
--   b5 Eva   en Verano (la quita el ADMIN).
--   b6 Fede  en Verano, jornada 26 abierta (la baja la hace el servidor por UPDATE).
insert into auth.users (id, instance_id, aud, role, email, encrypted_password, confirmed_at, created_at, updated_at,
                        raw_user_meta_data)
select pg_temp.u(x.s), '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
       'quitar192-' || x.s || '@example.com', 'x', now(), now(), now(),
       jsonb_build_object('nombre', x.n, 'apellido', 'Prueba')
  from (values ('a1', 'Luis'), ('a2', 'Marta'), ('a5', 'Rosa'), ('ad', 'Carlos'), ('a0', 'Pablo'),
               ('b1', 'Ana'), ('b2', 'Beto'), ('b3', 'Caro'), ('b4', 'Dani'), ('b5', 'Eva'), ('b6', 'Fede')) x(s, n);
insert into public.usuario_rol (usuario_id, rol_id)
select pg_temp.u(x.s), r.id
  from (values ('a1','COORDINADOR'), ('a2','COORDINADOR'), ('a5','COORDINADOR'), ('ad','ADMIN'), ('a0','COLPORTOR'),
               ('b1','COLPORTOR'), ('b2','COLPORTOR'), ('b3','COLPORTOR'), ('b4','COLPORTOR'), ('b5','COLPORTOR'),
               ('b6','COLPORTOR')) x(s, codigo)
  join public.rol r on r.codigo = x.codigo;

insert into public.pais (id, nombre, iso_code) values (pg_temp.u('c0'), 'Pais quitar192', 'ZQ');
insert into public.ciudad (id, nombre, departamento, pais_id, lat_centro, lon_centro) values
  (pg_temp.u('c1'), 'Ciudad quitar192', 'Departamento de prueba', pg_temp.u('c0'), -34.90, -56.16);
insert into public.campania (id, nombre, tipo, fecha_inicio, fecha_fin, coordinador_id, alquiler_monto) values
  (pg_temp.u('e1'), 'Verano192',    'VERANO',     current_date - 10, current_date + 30, pg_temp.u('a1'), 50000),
  (pg_temp.u('e2'), 'Otra192',      'PERMANENTE', current_date - 10, null,              pg_temp.u('a2'), null),
  (pg_temp.u('e3'), 'Diciembre192', 'VERANO',     current_date + 40, current_date + 80, pg_temp.u('a1'), null),
  (pg_temp.u('e4'), 'Vieja192',     'VERANO',     current_date - 90, current_date - 30, pg_temp.u('a1'), null);
insert into public.campania_coordinador (campania_id, usuario_id) values (pg_temp.u('e1'), pg_temp.u('a5'));
insert into public.campania_ciudad (id, campania_id, ciudad_id) values (pg_temp.u('f1'), pg_temp.u('e1'), pg_temp.u('c1'));
insert into public.zona (id, nombre, campania_ciudad_id, tipo_forma, centro_lat, centro_lon, radio_m) values
  (pg_temp.u('d1'), 'Norte', pg_temp.u('f1'), 'RADIAL', -34.88, -56.16, 300);

insert into public.campania_colportor (id, campania_id, usuario_id, zona_id, created_at) values
  (pg_temp.u('11'), pg_temp.u('e1'), pg_temp.u('b1'), pg_temp.u('d1'), now() - interval '5 days'),
  (pg_temp.u('12'), pg_temp.u('e1'), pg_temp.u('b2'), null,             now() - interval '5 days'),
  (pg_temp.u('13'), pg_temp.u('e3'), pg_temp.u('b2'), null,             now() - interval '1 day'),
  (pg_temp.u('14'), pg_temp.u('e4'), pg_temp.u('b3'), null,             now() - interval '60 days'),
  (pg_temp.u('15'), pg_temp.u('e1'), pg_temp.u('b5'), null,             now() - interval '5 days'),
  (pg_temp.u('16'), pg_temp.u('e1'), pg_temp.u('b6'), null,             now() - interval '5 days');

insert into public.jornada (id, colportor_id, inicio, fin, total_visitas, created_by) values
  (pg_temp.u('21'), pg_temp.u('b1'), now() - interval '2 hours',  null,                                 0, pg_temp.u('b1')),
  (pg_temp.u('22'), pg_temp.u('b1'), now() - interval '26 hours', now() - interval '20 hours',          4, pg_temp.u('b1')),
  (pg_temp.u('23'), pg_temp.u('b1'), now() - interval '20 days',  null,                                 0, pg_temp.u('b1')),
  (pg_temp.u('24'), pg_temp.u('b2'), now() - interval '1 hour',   null,                                 0, pg_temp.u('b2')),
  (pg_temp.u('26'), pg_temp.u('b6'), now() - interval '3 hours',  null,                                 0, pg_temp.u('b6'));

-- La casa, el depto y la persona que Ana cargó antes de la baja (para la visita y la venta que suben después).
insert into public.ubicacion (id, tipo, lat, lon, ciudad_id, created_by)
values (pg_temp.u('0a'), 'CASA', -34.88, -56.15, pg_temp.u('c1'), pg_temp.u('b1'));
insert into public.espacio (id, ubicacion_id, created_by) values (pg_temp.u('0b'), pg_temp.u('0a'), pg_temp.u('b1'));
insert into public.espacio_persona (id, espacio_id, persona_id, created_by)
values (pg_temp.u('0c'), pg_temp.u('0b'), pg_temp.u('0d'), pg_temp.u('b1'));

-- ---------------------------------------------------------------------------
-- 1. Forma y privilegios
-- ---------------------------------------------------------------------------
select is((select pg_get_function_result('public.quitar_de_campania(uuid, uuid)'::regprocedure)),
          'TABLE(inscripcion_id uuid, quitado_en timestamp with time zone, jornadas_cerradas integer, estado text)',
          'quitar_de_campania(campaña, usuario) devuelve la inscripción, cuándo, las jornadas cerradas y el estado');
select is((select p.prosecdef from pg_proc p where p.oid = 'public.quitar_de_campania(uuid, uuid)'::regprocedure),
          true, 'SECURITY DEFINER');
select is((select p.proconfig from pg_proc p where p.oid = 'public.quitar_de_campania(uuid, uuid)'::regprocedure),
          array['search_path=""'], 'con search_path vacío');
select ok(has_function_privilege('authenticated', 'public.quitar_de_campania(uuid, uuid)', 'execute'), 'authenticated la ejecuta');
select ok(has_function_privilege('service_role', 'public.quitar_de_campania(uuid, uuid)', 'execute'), 'service_role la ejecuta');
select ok(not has_function_privilege('anon', 'public.quitar_de_campania(uuid, uuid)', 'execute'), 'anon NO la ejecuta');
select is((select count(*)::int from pg_proc p, aclexplode(p.proacl) a
            where a.grantee = 0 and a.privilege_type = 'EXECUTE'
              and p.oid = 'public.quitar_de_campania(uuid, uuid)'::regprocedure),
          0, 'sin EXECUTE para PUBLIC');
select ok((select obj_description('public.quitar_de_campania(uuid, uuid)'::regprocedure, 'pg_proc')
             ~ '42501.*QC001.*QC002.*QC003'), 'el comentario publica los rechazos');
select ok(not has_function_privilege('authenticated', 'public.tg_campania_colportor_cierra_la_jornada()', 'execute'),
          'la función del trigger no la ejecuta authenticated');
select has_trigger('public', 'campania_colportor', 'campania_colportor_cierra_la_jornada',
                   'la baja de la inscripción tiene el trigger que cierra la jornada');

-- ---------------------------------------------------------------------------
-- 2. Permisos
-- ---------------------------------------------------------------------------
select pg_temp.actuar_como_servidor();
select throws_ok($$ select * from public.quitar_de_campania(pg_temp.u('e1'), pg_temp.u('b1')) $$,
  '42501', null, 'sin sesión: 42501');
select pg_temp.actuar_como(pg_temp.u('a0'));
select throws_ok($$ select * from public.quitar_de_campania(pg_temp.u('e1'), pg_temp.u('b1')) $$,
  '42501', null, 'un colportor no quita a nadie');
select pg_temp.actuar_como(pg_temp.u('b1'));
select throws_ok($$ select * from public.quitar_de_campania(pg_temp.u('e1'), pg_temp.u('b1')) $$,
  '42501', null, 'ni a sí mismo');
select pg_temp.actuar_como(pg_temp.u('a2'));
select throws_ok($$ select * from public.quitar_de_campania(pg_temp.u('e1'), pg_temp.u('b1')) $$,
  '42501', 'Solo un coordinador de la campaña o un administrador puede quitar colportores de ella. Entrá con la cuenta de un coordinador de esta campaña.',
  'la coordinadora de otra campaña no quita: 42501 con un aviso que dice qué hacer');
select pg_temp.actuar_como_servidor();
select is(pg_temp.inscripcion('11'), 'viva|' || pg_temp.u('d1'), 'tras los rechazos Ana sigue en el equipo, con su zona');
select is(pg_temp.jornada('21'), 'abierta|v0', 'y su jornada sigue abierta');

-- ---------------------------------------------------------------------------
-- 3. Rechazos con su código
-- ---------------------------------------------------------------------------
select pg_temp.actuar_como(pg_temp.u('a1'));
select throws_ok($$ select * from public.quitar_de_campania(pg_temp.u('ee'), pg_temp.u('b1')) $$,
  'QC001', 'La campaña no existe o fue dada de baja. Actualizá la lista de campañas.', 'campaña inexistente: QC001');
select throws_ok($$ select * from public.quitar_de_campania(pg_temp.u('e4'), pg_temp.u('b3')) $$,
  'QC002', 'La campaña ya terminó y su equipo queda como está. Elegí una campaña en curso o por empezar.',
  'campaña terminada: QC002 (lo cerrado no se toca)');
select throws_ok($$ select * from public.quitar_de_campania(pg_temp.u('e1'), pg_temp.u('b4')) $$,
  'QC003', 'No está en el equipo de esta campaña: puede que ya lo hayan quitado. Actualizá la lista.',
  'quien no está en la campaña: QC003');
select pg_temp.actuar_como_servidor();
select is(pg_temp.inscripcion('14'), 'viva|-', 'la inscripción de la campaña terminada sigue como estaba');

-- ---------------------------------------------------------------------------
-- 4. Luis quita a Ana
-- ---------------------------------------------------------------------------
select is((select alquiler_debe from public.cuenta_alquiler
            where usuario_id = pg_temp.u('b1') and campania_id = pg_temp.u('e1')), 50000::bigint,
          'antes: Ana debe el alquiler de Verano');
create temp table version_21 as select sync_version as v, updated_at from public.jornada where id = pg_temp.u('21');
grant select on version_21 to authenticated;

select pg_temp.actuar_como(pg_temp.u('a1'));
create temp table quitada_b1 as select * from public.quitar_de_campania(pg_temp.u('e1'), pg_temp.u('b1'));
select pg_temp.actuar_como_servidor();
select results_eq($$ select inscripcion_id, quitado_en, jornadas_cerradas, estado from quitada_b1 $$,
  $$ values (pg_temp.u('11'), now(), 1, 'PENDIENTE_ASIGNACION'::text) $$,
  'devuelve la inscripción, la hora de la baja, una jornada cerrada y que la cuenta quedó PENDIENTE_ASIGNACION');

select is(pg_temp.inscripcion('11'), 'baja|-', 'la inscripción queda dada de baja y sin zona');
select is((select deleted_at from public.campania_colportor where id = pg_temp.u('11')), now(), 'deleted_at = now()');
select is((select count(*)::int from public.campania_colportor where usuario_id = pg_temp.u('b1')), 1,
          'nada se borró: sigue la misma fila');
select ok((select h.hasta is not null and h.cerrada_por = pg_temp.u('a1')
             from public.campania_colportor_zona_historial h where h.campania_colportor_id = pg_temp.u('11')),
          'el tramo de Norte se cerró, con Luis como quien lo cerró');

select is((select fin from public.jornada where id = pg_temp.u('21')), now(), 'la jornada abierta se cerró con fin = la baja');
select is((select sync_version from public.jornada where id = pg_temp.u('21')), (select v from version_21),
          'sin subir la versión (republicada)');
select is((select updated_at from public.jornada where id = pg_temp.u('21')), (select updated_at from version_21),
          'ni updated_at');
select ok((select xmin_w = pg_current_xact_id() from public.jornada where id = pg_temp.u('21')),
          'pero sube xmin_w: el teléfono la baja en el próximo pull');
select is(pg_temp.jornada('22'), 'cerrada|v0', 'la jornada ya cerrada de ayer no se toca');
select ok((select fin = now() - interval '20 hours' from public.jornada where id = pg_temp.u('22')), 'conserva su fin');
select is(pg_temp.jornada('23'), 'abierta|v0', 'la abierta de antes de inscribirse no es de esta inscripción: no se toca');
select is((select count(*)::int from public.jornada where colportor_id = pg_temp.u('b1') and deleted_at is null), 3,
          'ninguna jornada se borró');

select results_eq(
  $$ select alquiler_monto, alquiler_debe, deleted_at from public.cuenta_alquiler
      where usuario_id = pg_temp.u('b1') and campania_id = pg_temp.u('e1') $$,
  $$ values (50000::bigint, 0::bigint, null::timestamptz) $$,
  'la cuenta de alquiler queda en debe 0 y viva (lo pagado se decide en Cuentas)');

select results_eq(
  $$ select actor_user_id, target_user_id, tabla, fila_id, metadata from auditoria.audit_log
      where event_type = 'colportor_quitado_de_campania' and target_user_id = pg_temp.u('b1') $$,
  $$ values (pg_temp.u('a1'), pg_temp.u('b1'), 'campania_colportor'::text, pg_temp.u('11'),
             jsonb_build_object('campania_id', pg_temp.u('e1'), 'zona_id', pg_temp.u('d1'), 'jornadas_cerradas', 1)) $$,
  'una línea en audit_log: quién, a quién, la inscripción, la campaña, la zona que tenía y las jornadas cerradas');

select pg_temp.actuar_como(pg_temp.u('b1'));
select is(public.estado_cuenta(), 'PENDIENTE_ASIGNACION', 'Ana ve su cuenta PENDIENTE_ASIGNACION');

-- Otra vez (otra pestaña, otro coordinador): ya no está.
select pg_temp.actuar_como(pg_temp.u('a5'));
select throws_ok($$ select * from public.quitar_de_campania(pg_temp.u('e1'), pg_temp.u('b1')) $$,
  'QC003', null, 'quitarla otra vez: QC003 (el panel refresca la lista)');
select pg_temp.actuar_como_servidor();
select is((select count(*)::int from auditoria.audit_log
            where event_type = 'colportor_quitado_de_campania' and target_user_id = pg_temp.u('b1')), 1,
          'el rechazo no suma eventos');

-- ---------------------------------------------------------------------------
-- 5. Beto está en dos campañas
-- ---------------------------------------------------------------------------
select pg_temp.actuar_como(pg_temp.u('a1'));
select results_eq($$ select jornadas_cerradas, estado from public.quitar_de_campania(pg_temp.u('e3'), pg_temp.u('b2')) $$,
  $$ values (0, 'ACTIVA'::text) $$,
  'quitarlo de Diciembre (por empezar): ninguna jornada que cerrar y la cuenta sigue ACTIVA (está en Verano)');
select pg_temp.actuar_como_servidor();
select is(pg_temp.jornada('24'), 'abierta|v0', 'la jornada de hoy en Verano sigue abierta');
select is(pg_temp.inscripcion('12'), 'viva|-', 'y su inscripción en Verano sigue viva');

-- El segundo coordinador de Verano también puede.
select pg_temp.actuar_como(pg_temp.u('a5'));
select results_eq($$ select jornadas_cerradas, estado from public.quitar_de_campania(pg_temp.u('e1'), pg_temp.u('b2')) $$,
  $$ values (1, 'PENDIENTE_ASIGNACION'::text) $$,
  'el segundo coordinador lo quita de Verano: se cierra la jornada y queda PENDIENTE_ASIGNACION');
select pg_temp.actuar_como_servidor();
select is(pg_temp.jornada('24'), 'cerrada|v0', 'la jornada de Beto se cerró, sin subir la versión');

-- Y un ADMIN.
select pg_temp.actuar_como(pg_temp.u('ad'));
select results_eq($$ select inscripcion_id, jornadas_cerradas from public.quitar_de_campania(pg_temp.u('e1'), pg_temp.u('b5')) $$,
  $$ values (pg_temp.u('15'), 0) $$, 'un ADMIN quita a Eva');
select pg_temp.actuar_como_servidor();
select is((select actor_user_id from auditoria.audit_log
            where event_type = 'colportor_quitado_de_campania' and target_user_id = pg_temp.u('b5')), pg_temp.u('ad'),
          'el evento lleva al ADMIN como actor');

-- ---------------------------------------------------------------------------
-- 6. Lo que el teléfono de Ana registró antes de la baja sube después y entra
-- ---------------------------------------------------------------------------
select pg_temp.actuar_como(pg_temp.u('b1'));
create temp table lote_b1 as
select pg_temp.push(jsonb_build_array(
  jsonb_build_object('client_op_id', pg_temp.u('31'), 'entity', 'jornada', 'op', 'update',
    'sync_version', (select v from version_21),
    'payload', jsonb_build_object('id', pg_temp.u('21'), 'inicio', now() - interval '2 hours',
                                  'fin', now() - interval '10 minutes', 'total_visitas', 3, 'total_ventas', 1,
                                  'acompaniante_id', null, 'created_at', now())),
  jsonb_build_object('client_op_id', pg_temp.u('32'), 'entity', 'visita', 'op', 'insert', 'sync_version', null,
    'payload', jsonb_build_object('id', pg_temp.u('0e'), 'fecha', now() - interval '1 hour', 'tipo_resultado', 'NO_CONTESTO',
                                  'espacio_id', pg_temp.u('0b'), 'espacio_persona_id', pg_temp.u('0c'),
                                  'jornada_id', pg_temp.u('21'), 'created_at', now())),
  jsonb_build_object('client_op_id', pg_temp.u('33'), 'entity', 'venta', 'op', 'insert', 'sync_version', null,
    'payload', jsonb_build_object('id', pg_temp.u('0f'), 'espacio_persona_id', pg_temp.u('0c'),
                                  'numero_talonario', 'Q192-1', 'monto_total', 85000,
                                  'fecha', now() - interval '50 minutes')))) as r;
select is((select pg_temp.resultados(r) from lote_b1), array['accepted', 'accepted', 'accepted'],
          'la jornada (con la versión de antes de la baja), la visita y la venta entran: nada se pierde');
select pg_temp.actuar_como_servidor();
select ok((select fin = now() - interval '10 minutes' and total_visitas = 3 and sync_version = (select v from version_21) + 1
             from public.jornada where id = pg_temp.u('21')),
          'la jornada queda con la hora y los totales del teléfono');
select is((select colportor_id from public.venta where id = pg_temp.u('0f')), pg_temp.u('b1'), 'la venta está, a nombre de Ana');
select is((select colportor_id from public.visita where id = pg_temp.u('0e')), pg_temp.u('b1'), 'y la visita');

-- ---------------------------------------------------------------------------
-- 7. Luis la vuelve a añadir: la misma inscripción, sin zona
-- ---------------------------------------------------------------------------
select pg_temp.actuar_como(pg_temp.u('a1'));
select is((select id from public.inscribir_colportor(pg_temp.u('e1'), pg_temp.u('b1'))), pg_temp.u('11'),
          'inscribir_colportor() reactiva la misma fila');
select pg_temp.actuar_como_servidor();
select is(pg_temp.inscripcion('11'), 'viva|-', 'viva otra vez y sin zona');
select is((select count(*)::int from public.campania_colportor where usuario_id = pg_temp.u('b1')), 1, 'sin filas de más');
select is((select alquiler_debe from public.cuenta_alquiler
            where usuario_id = pg_temp.u('b1') and campania_id = pg_temp.u('e1')), 50000::bigint,
          'y vuelve a deber el alquiler');
select pg_temp.actuar_como(pg_temp.u('b1'));
select is(public.estado_cuenta(), 'ACTIVA', 'su cuenta vuelve a ACTIVA');

-- ---------------------------------------------------------------------------
-- 8. La baja por otro camino también cierra la jornada
-- ---------------------------------------------------------------------------
select pg_temp.actuar_como_servidor();
update public.campania_colportor set deleted_at = now() where id = pg_temp.u('16');
select is(pg_temp.jornada('26'), 'cerrada|v0', 'una baja del servidor por UPDATE también cierra la jornada abierta');
-- Volver a dar de baja una ya de baja (cambiar la hora) no vuelve a tocar nada.
update public.jornada set fin = null where id = pg_temp.u('26');
update public.campania_colportor set deleted_at = now() - interval '1 minute' where id = pg_temp.u('16');
select is((select fin from public.jornada where id = pg_temp.u('26')), null::timestamptz,
          'el trigger solo corre cuando la inscripción pasa de viva a de baja');

select * from finish();
rollback;
