-- pgTAP · migración 0021, parte de la revisión de #55 y de las decisiones de Cristian del 02/10:
--   1. mover algo que solo ve (la casa, el depto o el estado de una campaña por empezar) hacia
--      donde escribe: 42501, por el push y por UPDATE directo;
--   2. el autor de una casa: con alguna campaña (aunque sea de otra ciudad) la corrige; sin
--      ninguna, ni la corrige, ni la muda, ni la da de baja; y el alta del espacio y el estado en
--      una casa nueva propia entra aunque la campaña no haya empezado;
--   3. los 15 días de gracia: lo ajeno que sube después del fin se rechaza con CG001 (el código
--      que el teléfono distingue del 42501), también por UPDATE directo sobre lo que ve.
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
create or replace function pg_temp.u(p text) returns uuid language sql as $$
  select ('01920000-0000-7000-8000-0000000026' || p)::uuid;
$$;
create or replace function pg_temp.job(p_ent text, p_op text, p_payload jsonb, p_version bigint default null)
returns jsonb language sql as $$
  select jsonb_build_object('client_op_id', gen_random_uuid(), 'entity', p_ent, 'op', p_op,
                            'payload', p_payload, 'sync_version', p_version);
$$;
create or replace function pg_temp.resultados(p_r jsonb) returns text[] language sql as $$
  select array_agg((e ->> 'outcome') || coalesce(' ' || (e ->> 'code'), '')
                    || case when e ? 'server_row' then ' +server_row' else '' end order by i)
    from jsonb_array_elements(p_r -> 'results') with ordinality x(e, i);
$$;
-- Un push de una sola operación sobre una fila que ya existe, con la versión que el servidor
-- tiene hoy (como el teléfono que bajó la fila al día; la versión se lee como postgres).
create or replace function pg_temp.pushear(p_entidad text, p_op text, p_id uuid, p_cambios jsonb default '{}')
returns text[] language plpgsql as $$
declare
  v_version bigint;
  v_clave   text := case when p_entidad = 'house_status' then 'ubicacion_id' else 'id' end;
  v_rol     text := current_setting('role');
  v_claims  text := current_setting('request.jwt.claims', true);
  v_res     text[];
begin
  perform set_config('role', 'postgres', true);
  execute format('select sync_version from public.%I where %I = $1', p_entidad, v_clave) into v_version using p_id;
  perform set_config('role', v_rol, true);
  return pg_temp.resultados(sync.push(jsonb_build_array(
           pg_temp.job(p_entidad, p_op, jsonb_build_object(v_clave, p_id) || p_cambios, v_version))));
end $$;
create or replace function pg_temp.hoy() returns date language sql as $$
  select (now() at time zone 'America/Montevideo')::date;
$$;
-- Fechas de una campaña.
create or replace function pg_temp.campania_de(p_id text, p_inicio date, p_fin date) returns void language sql as $$
  update public.campania set fecha_inicio = p_inicio, fecha_fin = p_fin where id = pg_temp.u(p_id);
$$;

-- ---------------------------------------------------------------------------
-- Fixtures: c1 con la campaña e1 en curso, c2 con la campaña e2 que empieza en 3 días.
--   b1 inscripta (sin zona) en las dos; b4 solo en e2; b3 en ninguna; b2 es el autor de lo ajeno.
-- ---------------------------------------------------------------------------
insert into auth.users (id, instance_id, aud, role, email, encrypted_password, confirmed_at, created_at, updated_at)
select pg_temp.u(s), '00000000-0000-0000-0000-000000000000',
       'authenticated', 'authenticated', 'mover-' || s || '@example.com', 'x', now(), now(), now()
  from unnest(array['b1','b2','b3','b4']) s;
insert into public.pais (id, nombre, iso_code) values (pg_temp.u('c0'), 'Pais mover', 'ZM');
insert into public.ciudad (id, nombre, pais_id, lat_centro, lon_centro) values
  (pg_temp.u('c1'), 'Ciudad en curso mover', pg_temp.u('c0'), -34.9, -56.2),
  (pg_temp.u('c2'), 'Ciudad futura mover',   pg_temp.u('c0'), -33.0, -55.0);
insert into public.campania (id, nombre, tipo, fecha_inicio, fecha_fin) values
  (pg_temp.u('e1'), 'En curso mover', 'VERANO', current_date - 10, current_date + 30),
  (pg_temp.u('e2'), 'Futura mover',   'VERANO', current_date + 3,  current_date + 60);
insert into public.campania_ciudad (id, campania_id, ciudad_id) values
  (pg_temp.u('f1'), pg_temp.u('e1'), pg_temp.u('c1')),
  (pg_temp.u('f2'), pg_temp.u('e2'), pg_temp.u('c2'));
insert into public.campania_colportor (campania_id, usuario_id) values
  (pg_temp.u('e1'), pg_temp.u('b1')), (pg_temp.u('e2'), pg_temp.u('b1')), (pg_temp.u('e2'), pg_temp.u('b4'));
-- Lo que cargó b2: H2 en la ciudad futura (con su depto S2 y su estado), H1 y H3 en la que está
-- en curso (H1 con el depto S1).
insert into public.ubicacion (id, tipo, calle, numero, lat, lon, ciudad_id, created_by) values
  (pg_temp.u('02'), 'CASA', 'Futura',   '2', -33.0,  -55.0,  pg_temp.u('c2'), pg_temp.u('b2')),
  (pg_temp.u('01'), 'CASA', 'En curso', '1', -34.9,  -56.2,  pg_temp.u('c1'), pg_temp.u('b2')),
  (pg_temp.u('03'), 'CASA', 'En curso', '3', -34.91, -56.21, pg_temp.u('c1'), pg_temp.u('b2'));
insert into public.espacio (id, ubicacion_id, created_by) values
  (pg_temp.u('12'), pg_temp.u('02'), pg_temp.u('b2')),
  (pg_temp.u('11'), pg_temp.u('01'), pg_temp.u('b2'));
insert into public.house_status (ubicacion_id, lat, lon, tipo_ubicacion, color, prioridad, created_by)
values (pg_temp.u('02'), -33.0, -55.0, 'CASA', 'RECHAZO', 7, pg_temp.u('b2'));

-- ---------------------------------------------------------------------------
-- 1. Mover lo que solo ve hacia donde escribe: 42501, por el push y por UPDATE directo
-- ---------------------------------------------------------------------------
select pg_temp.actuar_como(pg_temp.u('b1'));
select is((select count(*) from public.ubicacion where id = pg_temp.u('02')), 1::bigint, 'b1 ve H2 (ciudad de la campaña por empezar)');
select ok(not public.puedo_escribir_en_ubicacion(pg_temp.u('02')), 'pero no escribe en H2');

select is(pg_temp.pushear('ubicacion', 'update', pg_temp.u('02'), '{"numero": "2 bis"}'), array['invalid 42501'],
          'control: corregir el número de H2: invalid 42501 sin server_row');
select is(pg_temp.pushear('ubicacion', 'update', pg_temp.u('02'), jsonb_build_object('ciudad_id', pg_temp.u('c1'))),
          array['invalid 42501'], 'llevar H2 a la ciudad en la que escribe: invalid 42501 (antes accepted)');
select is(pg_temp.pushear('espacio', 'update', pg_temp.u('12'), jsonb_build_object('ubicacion_id', pg_temp.u('01'))),
          array['invalid 42501'], 'llevarse el depto de H2 a H1: invalid 42501 (antes accepted)');
select throws_ok(format('update public.house_status set ubicacion_id = %L where ubicacion_id = %L',
                        pg_temp.u('03'), pg_temp.u('02')),
                 '42501', null, 'por UPDATE directo, el estado de H2 a H3: 42501 (antes 1 fila)');
select throws_ok(format('update public.ubicacion set ciudad_id = %L where id = %L', pg_temp.u('c1'), pg_temp.u('02')),
                 '42501', null, 'por UPDATE directo, H2 a la otra ciudad: 42501');
select throws_ok(format('update public.espacio set ubicacion_id = %L where id = %L', pg_temp.u('01'), pg_temp.u('12')),
                 '42501', null, 'por UPDATE directo, el depto de H2 a H1: 42501');

select pg_temp.actuar_como_servidor();
select is((select ciudad_id from public.ubicacion where id = pg_temp.u('02')), pg_temp.u('c2'), 'H2 sigue en su ciudad');
select is((select ubicacion_id from public.espacio where id = pg_temp.u('12')), pg_temp.u('02'), 'el depto sigue en H2');
select is((select count(*) from public.house_status where ubicacion_id = pg_temp.u('02')), 1::bigint, 'el estado sigue en H2');

-- No regresiona lo permitido: mover un depto entre dos casas en las que escribe.
select pg_temp.actuar_como(pg_temp.u('b1'));
select is(pg_temp.pushear('espacio', 'update', pg_temp.u('11'), jsonb_build_object('ubicacion_id', pg_temp.u('03'))),
          array['accepted'], 'un depto de H1 a H3 (las dos de la campaña en curso): accepted');

-- ---------------------------------------------------------------------------
-- 2. El alta en una casa nueva propia entra antes del primer día; corregirla, no
-- ---------------------------------------------------------------------------
-- b4 solo está inscripta en e2, que empieza en 3 días: todavía no tiene campaña en la que escribir.
select pg_temp.actuar_como(pg_temp.u('b4'));
select ok(not public.puedo_escribir_en_ubicacion(pg_temp.u('01')), 'b4 todavía no escribe en casas ajenas');
select is(pg_temp.resultados(sync.push(jsonb_build_array(
            pg_temp.job('ubicacion', 'insert', jsonb_build_object('id', pg_temp.u('06'), 'tipo', 'CASA', 'calle', 'Nueva',
                                                                  'numero', '6', 'lat', -33.1, 'lon', -55.1,
                                                                  'ciudad_id', pg_temp.u('c2'))),
            pg_temp.job('espacio', 'insert', jsonb_build_object('id', pg_temp.u('16'), 'ubicacion_id', pg_temp.u('06'))),
            pg_temp.job('house_status', 'insert', jsonb_build_object('ubicacion_id', pg_temp.u('06'), 'tipo_ubicacion', 'CASA',
                                                                     'color', 'SIN_CONTESTAR', 'prioridad', 6))))),
          array['accepted', 'accepted', 'accepted'],
          'antes del primer día: la casa nueva, su depto y su estado entran (como antes de 0021)');
select is(pg_temp.pushear('espacio', 'update', pg_temp.u('16'), '{"piso": "1"}'), array['invalid 42501'],
          'pero corregir ese depto antes del primer día es invalid 42501');
select is(pg_temp.resultados(sync.push(jsonb_build_array(
            pg_temp.job('espacio', 'insert', jsonb_build_object('id', pg_temp.u('17'), 'ubicacion_id', pg_temp.u('01')))))),
          array['invalid 42501'], 'y el alta de un depto en una casa AJENA sin campaña en la que escribir sigue siendo 42501');

-- b3 no está inscripto en nada: carga una casa propia con su depto y su estado.
select pg_temp.actuar_como(pg_temp.u('b3'));
select is(pg_temp.resultados(sync.push(jsonb_build_array(
            pg_temp.job('ubicacion', 'insert', jsonb_build_object('id', pg_temp.u('04'), 'tipo', 'CASA', 'calle', 'Sin campaña',
                                                                  'numero', '4', 'lat', -34.95, 'lon', -56.25,
                                                                  'ciudad_id', pg_temp.u('c1'))),
            pg_temp.job('espacio', 'insert', jsonb_build_object('id', pg_temp.u('13'), 'ubicacion_id', pg_temp.u('04'))),
            pg_temp.job('house_status', 'insert', jsonb_build_object('ubicacion_id', pg_temp.u('04'), 'tipo_ubicacion', 'CASA',
                                                                     'color', 'SIN_CONTESTAR', 'prioridad', 6))))),
          array['accepted', 'accepted', 'accepted'], 'sin ninguna campaña: el alta de lo propio entra');
select is(pg_temp.pushear('ubicacion', 'update', pg_temp.u('04'), '{"numero": "4 bis"}'), array['invalid 42501'],
          'sin campaña, el autor no corrige su casa');
select is(pg_temp.pushear('ubicacion', 'update', pg_temp.u('04'), jsonb_build_object('ciudad_id', pg_temp.u('c2'))),
          array['invalid 42501'], 'ni la muda a otra ciudad');
select is(pg_temp.pushear('ubicacion', 'delete', pg_temp.u('04')), array['invalid 42501'], 'ni la da de baja');
select throws_ok(format('update public.ubicacion set numero = %L where id = %L', '4 bis', pg_temp.u('04')),
                 '42501', null, 'por UPDATE directo, 42501');
select pg_temp.actuar_como_servidor();
select is((select numero from public.ubicacion where id = pg_temp.u('04')), '4', 'la casa quedó como estaba');

-- b1: su casa 05 en c1; la campaña e1 pasa a «terminada» y e2 sigue (otra ciudad).
insert into public.ubicacion (id, tipo, calle, numero, lat, lon, ciudad_id, created_by)
values (pg_temp.u('05'), 'CASA', 'Propia', '5', -34.92, -56.22, pg_temp.u('c1'), pg_temp.u('b1'));
select pg_temp.campania_de('e1', pg_temp.hoy() - 90, pg_temp.hoy() - 20);
select pg_temp.campania_de('e2', pg_temp.hoy() - 10, pg_temp.hoy() + 60);
select pg_temp.actuar_como(pg_temp.u('b1'));
select is(pg_temp.pushear('ubicacion', 'update', pg_temp.u('05'), '{"numero": "5 bis"}'), array['accepted'],
          'decisión de Cristian: con alguna campaña vigente (e2, de otra ciudad) el autor corrige su casa de c1');

-- Sin ninguna campaña vigente ni dentro de la gracia: e2 también terminó hace 16 días.
select pg_temp.actuar_como_servidor();
select pg_temp.campania_de('e2', pg_temp.hoy() - 90, pg_temp.hoy() - 16);
select pg_temp.actuar_como(pg_temp.u('b1'));
select is((select count(*) from public.ubicacion where id = pg_temp.u('05')), 1::bigint, 'sigue viendo su casa');
select is(pg_temp.pushear('ubicacion', 'update', pg_temp.u('05'), '{"numero": "5 ter"}'), array['invalid 42501'],
          'pasados la campaña y los 15 días: el autor no corrige su casa (invalid 42501)');
select is(pg_temp.pushear('ubicacion', 'update', pg_temp.u('05'), jsonb_build_object('ciudad_id', pg_temp.u('c2'))),
          array['invalid 42501'], 'ni la muda');
select is(pg_temp.pushear('ubicacion', 'delete', pg_temp.u('05')), array['invalid 42501'], 'ni la da de baja');
select throws_ok(format('update public.ubicacion set deleted_at = now() where id = %L', pg_temp.u('05')),
                 '42501', null, 'por UPDATE directo, la baja: 42501');
-- Día 15 de la última (e1 terminó hace 20, e2 hace 15): entra.
select pg_temp.actuar_como_servidor();
select pg_temp.campania_de('e2', pg_temp.hoy() - 90, pg_temp.hoy() - 15);
select pg_temp.actuar_como(pg_temp.u('b1'));
select is(pg_temp.pushear('ubicacion', 'update', pg_temp.u('05'), '{"numero": "5 ter"}'), array['accepted'],
          'a los 15 días de la última campaña, el autor sigue corrigiendo lo propio');

-- ---------------------------------------------------------------------------
-- 3. Gracia: lo ajeno vuelve CG001, también por UPDATE directo sobre lo que ve
-- ---------------------------------------------------------------------------
-- b1 tiene su casa 05 con un depto de b2 (07) y uno propio (08). Solo está en la gracia (e2).
select pg_temp.actuar_como_servidor();
insert into public.espacio (id, ubicacion_id, created_by) values
  (pg_temp.u('07'), pg_temp.u('05'), pg_temp.u('b2')),
  (pg_temp.u('08'), pg_temp.u('05'), pg_temp.u('b1'));
select pg_temp.actuar_como(pg_temp.u('b1'));
select is((select count(*) from public.espacio where id = pg_temp.u('07')), 1::bigint, 've el depto de b2 (es de su casa)');
select is(pg_temp.pushear('espacio', 'update', pg_temp.u('07'), '{"piso": "9"}'), array['invalid CG001'],
          'gracia: corregir el depto de otro, en su casa: invalid CG001 (el teléfono lo distingue del 42501)');
select is(pg_temp.pushear('espacio', 'delete', pg_temp.u('07')), array['invalid CG001'], 'ni darlo de baja: CG001');
select throws_ok(format('update public.espacio set piso = %L where id = %L', '9', pg_temp.u('07')),
                 'CG001', null, 'por UPDATE directo sobre lo que ve: CG001');
select is(pg_temp.pushear('espacio', 'update', pg_temp.u('08'), '{"piso": "1"}'), array['accepted'],
          'gracia: corregir su propio depto entra');
select ok(has_function_privilege('authenticated', 'public.correccion_ajena_en_gracia(text, uuid)', 'execute'),
          'correccion_ajena_en_gracia la llama el push, como quien sube');
select ok(not has_function_privilege('authenticated', 'public.ubicacion_solo_en_gracia(uuid)', 'execute'),
          'ubicacion_solo_en_gracia es interna');
select ok(not has_function_privilege('authenticated', 'public.tg_control_de_correccion()', 'execute'),
          'el trigger no es llamable');
select ok(has_function_privilege('authenticated', 'public.puedo_cargar_en_ubicacion(uuid)', 'execute'),
          'puedo_cargar_en_ubicacion la usan las políticas de INSERT');

select pg_temp.actuar_como_servidor();
select is((select piso from public.espacio where id = pg_temp.u('07')), null, 'el depto ajeno quedó como estaba');

select * from finish();
rollback;
