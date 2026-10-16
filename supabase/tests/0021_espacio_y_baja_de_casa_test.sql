-- pgTAP · migración 0018 (backend-supabase#32; decisión de Cristian del 02/10 en #51):
--   1. el autor corrige o da de baja su espacio solo con la campaña vigente: con la terminada, el
--      push vuelve invalid 42501 (visible) en vez de un conflict falso; el ajeno, FILA_INEXISTENTE;
--   2. no se da de baja una casa con ventas (UB001) ni con visitas de otro colportor (UB002).
begin;
select * from no_plan();

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
create or replace function pg_temp.job(p_ent text, p_op text, p_payload jsonb, p_version bigint default null)
returns jsonb language sql as $$
  select jsonb_build_object('client_op_id', gen_random_uuid(), 'entity', p_ent, 'op', p_op,
                            'payload', p_payload, 'sync_version', p_version);
$$;
create or replace function pg_temp.resultados(p_r jsonb) returns text[] language sql as $$
  select array_agg((e ->> 'outcome') || coalesce(' ' || (e ->> 'code'), '') order by i)
    from jsonb_array_elements(p_r -> 'results') with ordinality x(e, i);
$$;
create or replace function pg_temp.u(p text) returns uuid language sql as $$ select ('01920000-0000-7000-8000-0000000021' || p)::uuid $$;
create or replace function pg_temp.version(p_tabla text, p_id uuid) returns bigint language plpgsql as $$
declare v bigint;
begin
  execute format('select sync_version from public.%I where id = $1', p_tabla) into v using p_id;
  return v;
end $$;

-- --- fixtures (como postgres) --------------------------------------------------
-- Verano (vigente) en c1; b1 y b2 inscriptos sin zona; b3 sin campaña. 01: casa del servidor en
-- c1; 02: casa en otra ciudad, fuera de toda campaña.
insert into auth.users (id, instance_id, aud, role, email, encrypted_password, confirmed_at, created_at, updated_at)
select pg_temp.u(s), '00000000-0000-0000-0000-000000000000',
       'authenticated', 'authenticated', 'espprop-' || s || '@example.com', 'x', now(), now(), now()
  from unnest(array['b1','b2','b3']) s;
insert into public.pais (id, nombre, iso_code) values ('01920000-0000-7000-8000-0000000021c0', 'Pais espprop', 'ZQ');
insert into public.ciudad (id, nombre, pais_id, lat_centro, lon_centro) values
  ('01920000-0000-7000-8000-0000000021c1', 'Ciudad espprop',   '01920000-0000-7000-8000-0000000021c0', -34.9, -56.2),
  ('01920000-0000-7000-8000-0000000021c3', 'Ciudad espprop 2', '01920000-0000-7000-8000-0000000021c0', -30.0, -51.0);
insert into public.campania (id, nombre, tipo, fecha_inicio, fecha_fin)
values ('01920000-0000-7000-8000-0000000021e1', 'Verano espprop', 'VERANO', current_date - 10, current_date + 30);
insert into public.campania_ciudad (id, campania_id, ciudad_id) values ('01920000-0000-7000-8000-0000000021f1', '01920000-0000-7000-8000-0000000021e1', '01920000-0000-7000-8000-0000000021c1');
insert into public.campania_colportor (campania_id, usuario_id, zona_id) values
  ('01920000-0000-7000-8000-0000000021e1', '01920000-0000-7000-8000-0000000021b1', null),
  ('01920000-0000-7000-8000-0000000021e1', '01920000-0000-7000-8000-0000000021b2', null);
insert into public.ubicacion (id, tipo, calle, numero, lat, lon, ciudad_id) values
  ('01920000-0000-7000-8000-000000002101', 'CASA', 'Espprop', '1', -34.9, -56.2, '01920000-0000-7000-8000-0000000021c1'),
  ('01920000-0000-7000-8000-000000002102', 'CASA', 'Lejos',   '2', -30.0, -51.0, '01920000-0000-7000-8000-0000000021c3');

-- ---------------------------------------------------------------------------
-- 1. Espacios: corregir y dar de baja solo con la campaña vigente
-- ---------------------------------------------------------------------------
select pg_temp.actuar_como(pg_temp.u('b1'));
select is(pg_temp.resultados(sync.push(jsonb_build_array(
            pg_temp.job('espacio', 'insert', jsonb_build_object('id', pg_temp.u('11'), 'ubicacion_id', pg_temp.u('01'), 'numero_depto', '1')),
            pg_temp.job('espacio', 'insert', jsonb_build_object('id', pg_temp.u('13'), 'ubicacion_id', pg_temp.u('01'), 'numero_depto', '3'))))),
          array['accepted', 'accepted'], 'b1 carga dos deptos con la campaña vigente');
select is(pg_temp.resultados(sync.push(jsonb_build_array(
            pg_temp.job('espacio', 'update', jsonb_build_object('id', pg_temp.u('11'), 'piso', '6'), 0)))),
          array['accepted'], 'y con la campaña vigente corrige el suyo');
select pg_temp.actuar_como(pg_temp.u('b2'));
select is(pg_temp.resultados(sync.push(jsonb_build_array(
            pg_temp.job('espacio', 'insert', jsonb_build_object('id', pg_temp.u('12'), 'ubicacion_id', pg_temp.u('01'), 'numero_depto', '2'))))),
          array['accepted'], 'b2 carga el suyo');

-- Mover el propio a una casa de fuera de sus campañas, con la campaña vigente: rechazado.
select pg_temp.actuar_como(pg_temp.u('b1'));
select is(pg_temp.resultados(sync.push(jsonb_build_array(
            pg_temp.job('espacio', 'update', jsonb_build_object('id', pg_temp.u('11'), 'ubicacion_id', pg_temp.u('02')), 1)))),
          array['invalid 42501'], 'el autor no mueve su espacio a una casa de fuera de sus campañas (push)');
select throws_ok(format('update public.espacio set ubicacion_id = %L where id = %L', pg_temp.u('02'), pg_temp.u('11')),
                 '42501', null, 'ni por UPDATE directo');

-- La campaña termina (hace más de 15 días: fuera de toda gracia).
select pg_temp.actuar_como_servidor();
update public.campania set fecha_inicio = current_date - 90, fecha_fin = current_date - 30 where id = pg_temp.u('e1');

select pg_temp.actuar_como(pg_temp.u('b1'));
select is((select count(*) from public.espacio where id = pg_temp.u('11')), 1::bigint, 'b1 ve su espacio (lo cargó él)');
select is((select count(*) from public.espacio where id = pg_temp.u('12')), 0::bigint, 'y no el de b2 en una casa que ya no ve');

select is(pg_temp.resultados(sync.push(jsonb_build_array(
            pg_temp.job('espacio', 'update', jsonb_build_object('id', pg_temp.u('11'), 'piso', '7'), 1),
            pg_temp.job('espacio', 'delete', jsonb_build_object('id', pg_temp.u('13')), 0)))),
          array['invalid 42501', 'invalid 42501'],
          'con la campaña terminada, corregir o dar de baja su espacio vuelve invalid 42501 (visible), no un conflict falso');
select throws_ok(format('update public.espacio set piso = %L where id = %L', '8', pg_temp.u('11')),
                 '42501', null, 'por UPDATE directo, el mismo 42501');
select pg_temp.actuar_como_servidor();
select is((select piso from public.espacio where id = pg_temp.u('11')), '6', 'el espacio quedó como estaba');
select is((select deleted_at from public.espacio where id = pg_temp.u('13')), null, 'y el otro no se dio de baja');
select is((select ubicacion_id from public.espacio where id = pg_temp.u('11')), pg_temp.u('01'), 'ni se movió');

-- El ajeno sigue rechazado: por el push, por UPDATE directo y sin poder verlo.
select pg_temp.actuar_como(pg_temp.u('b1'));
select is(pg_temp.resultados(sync.push(jsonb_build_array(
            pg_temp.job('espacio', 'update', jsonb_build_object('id', pg_temp.u('12'), 'piso', '9'), 0),
            pg_temp.job('espacio', 'delete', jsonb_build_object('id', pg_temp.u('12')), 0)))),
          array['invalid FILA_INEXISTENTE', 'invalid FILA_INEXISTENTE'],
          'b1 no toca el espacio de b2 en una casa que ya no ve');
update public.espacio set piso = '9' where id = pg_temp.u('12');  -- 0 filas
select pg_temp.actuar_como(pg_temp.u('b3'));
update public.espacio set piso = '9' where id = pg_temp.u('12');  -- b3 (sin campaña): 0 filas
select pg_temp.actuar_como_servidor();
select is((select piso from public.espacio where id = pg_temp.u('12')), null,
          'el espacio de b2 quedó como estaba (ni b1 ni b3 lo tocaron por UPDATE directo)');

-- Un ex colportor tampoco corrige lo que cargó (la pendiente de la versión anterior: decidida).
insert into public.campania_colportor (campania_id, usuario_id, zona_id) values (pg_temp.u('e1'), pg_temp.u('b3'), null);
insert into public.espacio (id, ubicacion_id, numero_depto, created_by) values (pg_temp.u('14'), pg_temp.u('01'), '4', pg_temp.u('b3'));
select pg_temp.actuar_como(pg_temp.u('b3'));
select throws_ok(format('update public.espacio set piso = %L where id = %L', '5', pg_temp.u('14')),
                 '42501', null, 'un ex colportor (campaña terminada) no corrige su espacio: 42501');

-- En una casa que registró él, sin campaña en la que escribir, tampoco corrige su espacio (desde
-- 0021 la rama del autor de puedo_escribir_en_ubicacion() exige campaña; antes, 0011, no).
select pg_temp.actuar_como_servidor();
insert into public.ubicacion (id, tipo, calle, numero, lat, lon, ciudad_id, created_by)
values (pg_temp.u('03'), 'CASA', 'Propia', '3', -34.91, -56.21, pg_temp.u('c1'), pg_temp.u('b1'));
insert into public.espacio (id, ubicacion_id, created_by) values (pg_temp.u('15'), pg_temp.u('03'), pg_temp.u('b1'));
select pg_temp.actuar_como(pg_temp.u('b1'));
select is(pg_temp.resultados(sync.push(jsonb_build_array(
            pg_temp.job('espacio', 'update', jsonb_build_object('id', pg_temp.u('15'), 'piso', '1'), 0)))),
          array['invalid 42501'],
          'en una casa que registró él, sin campaña en la que escribir, ya no corrige su espacio (0021: el autor también necesita campaña vigente)');

-- ---------------------------------------------------------------------------
-- 2. La baja de una casa con ventas (UB001) o con visitas de otro colportor (UB002)
-- ---------------------------------------------------------------------------
select pg_temp.actuar_como_servidor();
update public.campania set fecha_inicio = current_date - 10, fecha_fin = current_date + 30 where id = pg_temp.u('e1');
-- Casas de b1 en c1: 31 con una venta suya; 32 con una visita de b2; 33 solo con una visita suya;
-- 34 con una venta dada de baja; 35 con una venta en un espacio dado de baja; 36 sin nada.
insert into public.ubicacion (id, tipo, calle, numero, lat, lon, ciudad_id, created_by)
select pg_temp.u(x.u), 'CASA', 'Baja', x.u, -34.92, -56.22 - x.n * 0.01, pg_temp.u('c1'), pg_temp.u('b1')
  from (values ('31', 1), ('32', 2), ('33', 3), ('34', 4), ('35', 5), ('36', 6)) x(u, n);
insert into public.espacio (id, ubicacion_id, created_by, deleted_at)
select pg_temp.u('4' || right(x.u, 1)), pg_temp.u(x.u), pg_temp.u('b1'), case when x.u = '35' then now() end
  from (values ('31'), ('32'), ('33'), ('34'), ('35')) x(u);
insert into public.espacio_persona (id, espacio_id, persona_id, created_by)
select pg_temp.u('5' || right(x.u, 1)), pg_temp.u('4' || right(x.u, 1)), gen_random_uuid(), x.quien
  from (values ('31', pg_temp.u('b1')), ('32', pg_temp.u('b2')), ('33', pg_temp.u('b1')),
               ('34', pg_temp.u('b1')), ('35', pg_temp.u('b1'))) x(u, quien);
insert into public.visita (id, espacio_persona_id, fecha, tipo_resultado, colportor_id, created_by)
values (pg_temp.u('62'), pg_temp.u('52'), now(), 'RECHAZO', pg_temp.u('b2'), pg_temp.u('b2')),
       (pg_temp.u('63'), pg_temp.u('53'), now(), 'NO_CONTESTO', pg_temp.u('b1'), pg_temp.u('b1'));
insert into public.venta (id, espacio_persona_id, numero_talonario, monto_total, fecha, colportor_id, created_by, deleted_at)
values (pg_temp.u('71'), pg_temp.u('51'), 'T-71', 100000, now(), pg_temp.u('b1'), pg_temp.u('b1'), null),
       (pg_temp.u('74'), pg_temp.u('54'), 'T-74', 100000, now(), pg_temp.u('b1'), pg_temp.u('b1'), now()),
       (pg_temp.u('75'), pg_temp.u('55'), 'T-75', 100000, now(), pg_temp.u('b1'), pg_temp.u('b1'), null);

select pg_temp.actuar_como(pg_temp.u('b1'));
select is(pg_temp.resultados(sync.push(jsonb_build_array(
            pg_temp.job('ubicacion', 'delete', jsonb_build_object('id', pg_temp.u('31')), 0),
            pg_temp.job('ubicacion', 'delete', jsonb_build_object('id', pg_temp.u('32')), 0),
            pg_temp.job('ubicacion', 'delete', jsonb_build_object('id', pg_temp.u('34')), 0),
            pg_temp.job('ubicacion', 'delete', jsonb_build_object('id', pg_temp.u('35')), 0),
            pg_temp.job('ubicacion', 'update', jsonb_build_object('id', pg_temp.u('31'), 'deleted_at', now()), 0),
            pg_temp.job('ubicacion', 'delete', jsonb_build_object('id', pg_temp.u('33')), 0)))),
          array['invalid UB001', 'invalid UB002', 'invalid UB001', 'invalid UB001', 'invalid UB001', 'accepted'],
          'el push rechaza la baja con UB001 (venta: suya, dada de baja o en un espacio dado de baja) y UB002 (visita de otro), sin tumbar el lote; la casa con solo visitas suyas se da de baja');
select pg_temp.actuar_como_servidor();
select is((select count(*) from public.ubicacion where id in (pg_temp.u('31'), pg_temp.u('32'), pg_temp.u('34'), pg_temp.u('35'))
             and deleted_at is null), 4::bigint, 'las casas rechazadas quedaron como estaban');
select isnt((select deleted_at from public.ubicacion where id = pg_temp.u('33')), null, 'la 33 quedó de baja');

select pg_temp.actuar_como(pg_temp.u('b1'));
select throws_ok(format('update public.ubicacion set deleted_at = now() where id = %L', pg_temp.u('31')),
  'UB001', 'No se puede dar de baja esta casa: tiene ventas registradas. La casa queda como estaba.',
  'por UPDATE directo, UB001 con un mensaje que dice qué pasa');
select throws_ok(format('update public.ubicacion set deleted_at = now() where id = %L', pg_temp.u('32')),
  'UB002', 'No se puede dar de baja esta casa: otro colportor registró visitas en ella. La casa queda como estaba.',
  'y UB002');
select lives_ok(format('update public.ubicacion set calle = %L where id = %L', 'Baja corregida', pg_temp.u('31')),
  'corregir otra cosa de una casa con ventas sigue andando');
select lives_ok(format('update public.ubicacion set deleted_at = now() where id = %L', pg_temp.u('36')),
  'una casa sin ventas ni visitas se da de baja');

-- b2 da de baja la casa en la que solo él visitó (la registró b1, en una ciudad de su campaña).
select pg_temp.actuar_como(pg_temp.u('b2'));
select lives_ok(format('update public.ubicacion set deleted_at = now() where id = %L', pg_temp.u('32')),
  'quien registró la visita la puede dar de baja: la visita es suya');

-- Sin usuario autenticado (mantenimiento del servidor) no se exige.
select pg_temp.actuar_como_servidor();
select lives_ok(format('update public.ubicacion set deleted_at = now() where id = %L', pg_temp.u('31')),
  'el servidor da de baja una casa con ventas (mantenimiento)');

-- Forma y privilegios.
select has_trigger('public', 'ubicacion', 'ubicacion_baja_con_ventas_o_visitas', 'el trigger de la baja');
select ok((select p.prosecdef from pg_proc p where p.oid = 'public.tg_ubicacion_baja_con_ventas_o_visitas()'::regprocedure),
          'es SECURITY DEFINER: ve las ventas y visitas de los demás');
select ok(not has_function_privilege(r, 'public.tg_ubicacion_baja_con_ventas_o_visitas()', 'execute'),
          r || ' no ejecuta el trigger a mano')
  from unnest(array['anon', 'authenticated']) r;
select hasnt_trigger('public', 'espacio', 'espacio_no_mover_a_casa_ajena',
                     'sin el trigger de la versión anterior: el WITH CHECK ya impide mover el espacio');

select * from finish();
rollback;
