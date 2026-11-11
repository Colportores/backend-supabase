-- pgTAP · migración 0193 (backend-supabase#280, HU-CAM-005; decisión de Cristian del 11/11 «Gracia baja»): la
-- inscripción dada de baja escribe 15 días desde la baja, como tras el fin de la campaña (0020).
--   1. Forma: mis_campanias_para_escribir() y mis_campanias_en_curso_para_escribir() siguen internas.
--   2. El caso de la decisión: Ana carga sin señal el depto 2 de una casa ajena, la persona, la visita y la
--      venta; Luis la quita con quitar_de_campania(); el push entra entero (y el estado nuevo de otra casa
--      ajena y la corrección de su propio depto).
--   3. Igual que tras el fin: la corrección de lo AJENO vuelve CG001.
--   4. Lo que no cambia: la lectura, la campaña vigente y la cuenta.
--   5. El plazo en el día de Montevideo: la baja a las 00:00 del día hoy-15 entra; un minuto antes (día hoy-16),
--      42501 como hoy.
--   6. La baja no estira el fin: campaña terminada hace 20 días y baja hace 2, 42501.
--   7. Una baja anterior al comienzo de la campaña no da gracia.
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
  select ('01920000-0000-7000-8000-0000000193' || p_sufijo)::uuid
$$;

create or replace function pg_temp.job(p_ent text, p_op text, p_payload jsonb, p_version bigint default null)
returns jsonb language sql as $$
  select jsonb_build_object('client_op_id', gen_random_uuid(), 'entity', p_ent, 'op', p_op,
                            'payload', p_payload, 'sync_version', p_version);
$$;

create or replace function pg_temp.resultados(p_r jsonb) returns text[] language sql as $$
  select array_agg((e ->> 'outcome') || coalesce(' ' || (e ->> 'code'), '') order by i)
    from jsonb_array_elements(p_r -> 'results') with ordinality x(e, i);
$$;

-- Un depto nuevo en la casa p_casa, por el push.
create or replace function pg_temp.depto(p_id text, p_casa text) returns text[] language sql as $$
  select pg_temp.resultados(sync.push(jsonb_build_array(
           pg_temp.job('espacio', 'insert', jsonb_build_object('id', pg_temp.u(p_id), 'ubicacion_id', pg_temp.u(p_casa))))));
$$;

-- La baja de la inscripción p_id, movida (como servidor) a p_cuando.
create or replace function pg_temp.baja_en(p_id text, p_cuando timestamptz) returns void language plpgsql as $$
begin
  perform pg_temp.actuar_como_servidor();
  update public.campania_colportor set deleted_at = p_cuando where id = pg_temp.u(p_id);
end $$;

-- Las 00:00 del día hoy - p_dias en Montevideo.
create or replace function pg_temp.medianoche_de_hace(p_dias integer) returns timestamptz language sql as $$
  select ((public.hoy_montevideo() - p_dias)::timestamp) at time zone 'America/Montevideo';
$$;

-- --- fixtures (como postgres) --------------------------------------------------
-- a1 Luis coordina Verano (e1, en curso desde hoy-60), Otoño (e2, empezó hoy-5) y Vieja (e3, terminó hace 20 días).
-- b1 Ana colportora en las tres; b2 Beto en Verano (el que cargó las casas ajenas).
-- c1 es la ciudad de Verano y de Vieja; c2 la de Otoño.
-- Casas de c1: 0a (de Beto, con su depto 0b y su estado) y 0e (de Beto, sin estado). Casa de c2: 0f (de Beto).
-- Ana ya había cargado su depto 0c en la casa ajena 0a, antes de la baja.
insert into auth.users (id, instance_id, aud, role, email, encrypted_password, confirmed_at, created_at, updated_at,
                        raw_user_meta_data)
select pg_temp.u(x.s), '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
       'gracia193-' || x.s || '@example.com', 'x', now(), now(), now(),
       jsonb_build_object('nombre', x.n, 'apellido', 'Prueba')
  from (values ('a1', 'Luis'), ('b1', 'Ana'), ('b2', 'Beto')) x(s, n);
insert into public.usuario_rol (usuario_id, rol_id)
select pg_temp.u(x.s), r.id
  from (values ('a1','COORDINADOR'), ('b1','COLPORTOR'), ('b2','COLPORTOR')) x(s, codigo)
  join public.rol r on r.codigo = x.codigo;

insert into public.pais (id, nombre, iso_code) values (pg_temp.u('c0'), 'Pais gracia193', 'ZJ');
insert into public.ciudad (id, nombre, departamento, pais_id, lat_centro, lon_centro) values
  (pg_temp.u('c1'), 'Ciudad gracia193',  'Departamento de prueba', pg_temp.u('c0'), -34.90, -56.16),
  (pg_temp.u('c2'), 'Ciudad otoño193',   'Departamento de prueba', pg_temp.u('c0'), -34.80, -56.10);
insert into public.campania (id, nombre, tipo, fecha_inicio, fecha_fin, coordinador_id) values
  (pg_temp.u('e1'), 'Verano193', 'VERANO', public.hoy_montevideo() - 60, public.hoy_montevideo() + 30, pg_temp.u('a1')),
  (pg_temp.u('e2'), 'Otoño193',  'VERANO', public.hoy_montevideo() - 5,  public.hoy_montevideo() + 30, pg_temp.u('a1')),
  (pg_temp.u('e3'), 'Vieja193',  'VERANO', public.hoy_montevideo() - 90, public.hoy_montevideo() - 20, pg_temp.u('a1'));
insert into public.campania_ciudad (id, campania_id, ciudad_id) values
  (pg_temp.u('f1'), pg_temp.u('e1'), pg_temp.u('c1')),
  (pg_temp.u('f2'), pg_temp.u('e2'), pg_temp.u('c2')),
  (pg_temp.u('f3'), pg_temp.u('e3'), pg_temp.u('c1'));
-- Ana: 11 en Verano (viva, la quita Luis), 12 en Otoño (de baja antes del comienzo), 13 en Vieja (viva por ahora).
insert into public.campania_colportor (id, campania_id, usuario_id, created_at, deleted_at) values
  (pg_temp.u('11'), pg_temp.u('e1'), pg_temp.u('b1'), now() - interval '50 days', null),
  (pg_temp.u('12'), pg_temp.u('e2'), pg_temp.u('b1'), now() - interval '9 days',  now() - interval '7 days'),
  (pg_temp.u('13'), pg_temp.u('e3'), pg_temp.u('b1'), now() - interval '80 days', null),
  (pg_temp.u('14'), pg_temp.u('e1'), pg_temp.u('b2'), now() - interval '50 days', null);

insert into public.ubicacion (id, tipo, lat, lon, ciudad_id, created_by) values
  (pg_temp.u('0a'), 'CASA', -34.88, -56.15, pg_temp.u('c1'), pg_temp.u('b2')),
  (pg_temp.u('0e'), 'CASA', -34.87, -56.15, pg_temp.u('c1'), pg_temp.u('b2')),
  (pg_temp.u('0f'), 'CASA', -34.80, -56.10, pg_temp.u('c2'), pg_temp.u('b2'));
insert into public.espacio (id, ubicacion_id, numero_depto, created_by) values
  (pg_temp.u('0b'), pg_temp.u('0a'), '1', pg_temp.u('b2')),
  (pg_temp.u('0c'), pg_temp.u('0a'), '3', pg_temp.u('b1'));
insert into public.house_status (ubicacion_id, lat, lon, tipo_ubicacion, color, prioridad, created_by)
values (pg_temp.u('0a'), -34.88, -56.15, 'CASA', 'RECHAZO', 7, pg_temp.u('b2'));

-- ---------------------------------------------------------------------------
-- 1. Forma
-- ---------------------------------------------------------------------------
select ok(not has_function_privilege('authenticated', 'public.mis_campanias_para_escribir()', 'execute'),
          'mis_campanias_para_escribir sigue interna');
select ok(not has_function_privilege('authenticated', 'public.mis_campanias_en_curso_para_escribir()', 'execute'),
          'mis_campanias_en_curso_para_escribir sigue interna');
select ok(has_function_privilege('authenticated', 'public.mis_ciudades_de_campania()', 'execute'),
          'mis_ciudades_de_campania conserva sus privilegios');

-- Vieja terminó hace 20 días: fuera de toda gracia. La dejamos de baja ya para que no cuente en lo que sigue.
select pg_temp.baja_en('13', now() - interval '2 days');

-- ---------------------------------------------------------------------------
-- 2. El caso de la decisión: Luis quita a Ana y lo que ella cargó sin señal sube entero
-- ---------------------------------------------------------------------------
select pg_temp.actuar_como(pg_temp.u('a1'));
select results_eq($$ select inscripcion_id from public.quitar_de_campania(pg_temp.u('e1'), pg_temp.u('b1')) $$,
  $$ values (pg_temp.u('11')) $$, 'Luis quita a Ana de Verano');

select pg_temp.actuar_como(pg_temp.u('b1'));
select is(pg_temp.resultados(sync.push(jsonb_build_array(
            pg_temp.job('espacio', 'insert', jsonb_build_object('id', pg_temp.u('21'), 'ubicacion_id', pg_temp.u('0a'),
                                                                'numero_depto', '2')),
            pg_temp.job('espacio_persona', 'insert', jsonb_build_object('id', pg_temp.u('22'), 'espacio_id', pg_temp.u('21'),
                                                                        'persona_id', pg_temp.u('23'))),
            pg_temp.job('visita', 'insert', jsonb_build_object('id', pg_temp.u('24'), 'espacio_persona_id', pg_temp.u('22'),
                                                               'fecha', now() - interval '1 hour', 'tipo_resultado', 'VENTA')),
            pg_temp.job('venta', 'insert', jsonb_build_object('id', pg_temp.u('25'), 'espacio_persona_id', pg_temp.u('22'),
                                                              'visita_id', pg_temp.u('24'), 'numero_talonario', 'GB-1',
                                                              'monto_total', 120000, 'fecha', now() - interval '1 hour')),
            pg_temp.job('house_status', 'insert', jsonb_build_object('ubicacion_id', pg_temp.u('0e'), 'tipo_ubicacion', 'CASA',
                                                                     'color', 'VENTA_COMPLETA', 'prioridad', 4)),
            pg_temp.job('espacio', 'update', jsonb_build_object('id', pg_temp.u('0c'), 'piso', '2'),
                        (select sync_version from public.espacio where id = pg_temp.u('0c')))))),
          array['accepted', 'accepted', 'accepted', 'accepted', 'accepted', 'accepted'],
          'tras la baja, el depto 2 de la casa ajena, la persona, la visita, la venta, el estado de otra casa ajena y la '
          'corrección de su propio depto entran: no se pierde la venta');
select pg_temp.actuar_como_servidor();
select is((select colportor_id from public.venta where id = pg_temp.u('25')), pg_temp.u('b1'), 'la venta está, a nombre de Ana');
select is((select ubicacion_id from public.espacio where id = pg_temp.u('21')), pg_temp.u('0a'), 'y el depto 2, en la casa ajena');
select is((select color::text from public.house_status where ubicacion_id = pg_temp.u('0e')), 'VENTA_COMPLETA',
          'y el estado de la otra casa ajena');
select is((select piso from public.espacio where id = pg_temp.u('0c')), '2', 'y la corrección de su depto');

-- ---------------------------------------------------------------------------
-- 3. Igual que tras el fin: lo ajeno no se corrige en la gracia (CG001, decisión del 02/10 en #52)
-- ---------------------------------------------------------------------------
select pg_temp.actuar_como(pg_temp.u('b1'));
select is(pg_temp.resultados(sync.push(jsonb_build_array(
            pg_temp.job('espacio', 'update', jsonb_build_object('id', pg_temp.u('0b'), 'piso', '4'), 0),
            pg_temp.job('house_status', 'update', jsonb_build_object('ubicacion_id', pg_temp.u('0a'), 'color', 'SIN_CONTESTAR',
                                                                     'prioridad', 6), 0)))),
          array['invalid CG001', 'invalid CG001'],
          'corregir el depto y el estado que cargó Beto, en la gracia de la baja: CG001 como tras el fin');

-- ---------------------------------------------------------------------------
-- 4. Lo que no cambia: solo es para escribir
-- ---------------------------------------------------------------------------
select is((select count(*) from public.mis_campanias_vigentes()), 0::bigint,
          'la inscripción de baja no es vigente: la cuenta, la zona y la inscripción no cambian');
select is((select count(*) from public.ubicacion where id in (pg_temp.u('0a'), pg_temp.u('0e'))), 0::bigint,
          'la lectura tampoco: ya no ve las casas ajenas');

-- ---------------------------------------------------------------------------
-- 5. El plazo, en el día de Montevideo
-- ---------------------------------------------------------------------------
select pg_temp.baja_en('11', pg_temp.medianoche_de_hace(15));
select pg_temp.actuar_como(pg_temp.u('b1'));
select is(pg_temp.depto('31', '0a'), array['accepted'], 'la baja a las 00:00 del día hoy-15 (día 15): entra');

select pg_temp.baja_en('11', pg_temp.medianoche_de_hace(15) - interval '1 minute');
select pg_temp.actuar_como(pg_temp.u('b1'));
select is(pg_temp.depto('32', '0a'), array['invalid 42501'],
          'la baja a las 23:59 de Montevideo del día hoy-16 (día 16), aunque en UTC ya sea el día siguiente: 42501 como hoy');
select is(pg_temp.resultados(sync.push(jsonb_build_array(
            pg_temp.job('espacio', 'update', jsonb_build_object('id', pg_temp.u('0c'), 'piso', '5'),
                        (select sync_version from public.espacio where id = pg_temp.u('0c')))))),
          array['invalid 42501'], 'día 16: tampoco corrige su depto');
select is(pg_temp.resultados(sync.push(jsonb_build_array(
            pg_temp.job('house_status', 'insert', jsonb_build_object('ubicacion_id', pg_temp.u('0a'), 'tipo_ubicacion', 'CASA',
                                                                     'color', 'VENTA_COMPLETA', 'prioridad', 4))))),
          array['invalid 42501'], 'ni carga un estado en una casa ajena');

-- ---------------------------------------------------------------------------
-- 6. La baja no estira el fin de la campaña
-- ---------------------------------------------------------------------------
-- Vieja (también en c1) terminó hace 20 días; su baja de hace 2 días no le da 15 días más. Verano sigue en el día 16.
select pg_temp.actuar_como(pg_temp.u('b1'));
select is(pg_temp.depto('33', '0a'), array['invalid 42501'],
          'campaña terminada hace 20 días y baja hace 2: 42501 (la inscripción termina en lo que llegue antes)');

-- ---------------------------------------------------------------------------
-- 7. Una baja anterior al comienzo de la campaña no da gracia
-- ---------------------------------------------------------------------------
-- Otoño empezó hace 5 días; Ana se dio de baja hace 7 (antes del comienzo): nunca escribió ahí.
select pg_temp.actuar_como(pg_temp.u('b1'));
select is(pg_temp.depto('34', '0f'), array['invalid 42501'], 'baja antes del comienzo de Otoño: no escribe en su ciudad');
select pg_temp.baja_en('12', now() - interval '1 day');
select pg_temp.actuar_como(pg_temp.u('b1'));
select is(pg_temp.depto('35', '0f'), array['accepted'], 'con la baja después del comienzo (ayer), sí: la gracia corre');

select * from finish();
rollback;
