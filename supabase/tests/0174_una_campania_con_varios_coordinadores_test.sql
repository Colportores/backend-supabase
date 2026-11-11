-- pgTAP · migraciones 0174 y 0175 (backend-supabase#254, casilla «Coord. camp.»; decisión de Cristian del 05/11): una campaña
-- puede tener varios coordinadores y cada uno puede todo lo del coordinador.
--   1. La forma de `campania_coordinador`: columnas, único vigente, identidad de la fila (CC001), nombre y apellido copiados
--      del perfil y que siguen al perfil, RLS y privilegios (escribe solo un ADMIN).
--   2. `campania.coordinador_id` es el primer coordinador vigente: una campaña con coordinador trae su fila; reasignar la
--      columna (el panel de antes) suma al nuevo y da de baja al anterior; sumar o dar de baja filas recalcula la columna.
--   3. Con dos coordinadores en la misma campaña los dos pueden lo mismo (campanias_del_coordinador, el permiso del mapa,
--      la lectura de las cuentas y los depósitos de su gente, la beca y la meta, decidir el alquiler de una baja, la lectura
--      de la decisión y de la cuenta del alquiler) y un tercero, nada. Dar de baja a uno le quita el permiso al instante.
-- Va en una transacción.
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
create or replace function pg_temp.u(p text) returns uuid language sql as $$
  select ('01920000-0000-7000-8000-0000000174' || p)::uuid;
$$;
-- «sqlstate» o «ok» de lo que hace una sentencia (en subtransacción).
create or replace function pg_temp.error_de(p_sql text) returns text language plpgsql as $$
begin
  execute p_sql;
  return 'ok';
exception when others then
  return sqlstate;
end $$;
-- Cuántas filas toca una sentencia.
create or replace function pg_temp.filas(p_sql text) returns bigint language plpgsql as $$
declare n bigint;
begin
  execute p_sql;
  get diagnostics n = row_count;
  return n;
end $$;
-- Los coordinadores vigentes de una campaña, por sufijo y en orden: «c1,c2».
create or replace function pg_temp.vigentes(p_camp text) returns text language sql security definer as $$
  select coalesce(string_agg(right(cc.usuario_id::text, 2), ',' order by cc.created_at, cc.id), '-')
    from public.campania_coordinador cc
   where cc.campania_id = pg_temp.u(p_camp) and cc.deleted_at is null
$$;
-- La columna de la campaña, por sufijo.
create or replace function pg_temp.columna(p_camp text) returns text language sql security definer as $$
  select coalesce(right(coordinador_id::text, 2), '-') from public.campania where id = pg_temp.u(p_camp)
$$;

-- Las funciones internas del mapa no las ejecuta `authenticated`: se llaman como el servidor pero con la sesión de esa persona.
create or replace function pg_temp.motivo(p_funcion text, p_quien text, p_camp text) returns text language plpgsql as $$
declare v text;
begin
  perform set_config('request.jwt.claims', json_build_object('sub', pg_temp.u(p_quien), 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', pg_temp.u(p_quien)::text, true);
  execute format('select public.%I(%L)', p_funcion, pg_temp.u(p_camp)) into v;
  perform set_config('request.jwt.claims', '', true);
  perform set_config('request.jwt.claim.sub', '', true);
  return coalesce(v, 'ok');
end $$;
-- Las campañas del mapa de esa persona, ordenadas.
create or replace function pg_temp.campanias_mapa(p_quien text) returns uuid[] language plpgsql as $$
declare v uuid[];
begin
  perform set_config('request.jwt.claims', json_build_object('sub', pg_temp.u(p_quien), 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', pg_temp.u(p_quien)::text, true);
  select array_agg(c order by c) into v from public.mis_campanias_del_mapa() c;
  perform set_config('request.jwt.claims', '', true);
  perform set_config('request.jwt.claim.sub', '', true);
  return v;
end $$;

-- --- fixtures (como postgres) --------------------------------------------------
-- La campaña e1 la coordinan c1 y c2; c3 coordina otra (e2) y no tiene que poder nada en e1. ad es ADMIN.
-- b1 (inscripto en e1, dado de baja con alquiler pagado), b2 (inscripto en e1, vivo) y b9 (en e2).
insert into auth.users (id, instance_id, aud, role, email, encrypted_password, confirmed_at, created_at, updated_at,
                        raw_user_meta_data)
select pg_temp.u(s), '00000000-0000-0000-0000-000000000000',
       'authenticated', 'authenticated', 'coord174-' || s || '@example.com', 'x', now(), now(), now(),
       jsonb_build_object('nombre', 'Nombre ' || s, 'apellido', 'Apellido ' || s)
  from unnest(array['b1','b2','b9','c1','c2','c3','ad']) s;
insert into public.usuario_rol (usuario_id, rol_id)
select pg_temp.u(x.s), r.id
  from (values ('b1','COLPORTOR'), ('b2','COLPORTOR'), ('b9','COLPORTOR'),
               ('c1','COORDINADOR'), ('c2','COORDINADOR'), ('c3','COORDINADOR'), ('ad','ADMIN')) x(s, codigo)
  join public.rol r on r.codigo = x.codigo;

-- La campaña nace con un coordinador en la columna (como hasta hoy) ...
insert into public.campania (id, nombre, tipo, fecha_inicio, fecha_fin, coordinador_id, alquiler_monto) values
  (pg_temp.u('e1'), 'e1 coord174', 'VERANO', public.hoy_montevideo() - 10, public.hoy_montevideo() + 30, pg_temp.u('c1'), 250000),
  (pg_temp.u('e2'), 'e2 coord174', 'VERANO', public.hoy_montevideo() - 10, public.hoy_montevideo() + 30, pg_temp.u('c3'), null),
  (pg_temp.u('e3'), 'e3 sin coordinador', 'VERANO', public.hoy_montevideo() - 10, public.hoy_montevideo() + 30, null, null);

-- ============================================================================
-- 1. La forma
-- ============================================================================
select has_table('public', 'campania_coordinador', 'existe campania_coordinador');
select has_column('public', 'campania_coordinador', c, format('campania_coordinador.%s', c))
  from unnest(array['campania_id','usuario_id','nombre','apellido','created_at','updated_at','created_by','deleted_at',
                    'sync_version','xmin_w']) c;
select is((select relrowsecurity from pg_class where oid = 'public.campania_coordinador'::regclass), true,
          'campania_coordinador tiene RLS');
select is(has_table_privilege('anon', 'public.campania_coordinador', 'select'), false, 'anon no lee los coordinadores');
select has_function('public', 'coordina_la_campania', array['uuid'], 'existe coordina_la_campania(uuid)');
select is(has_function_privilege('anon', 'public.coordina_la_campania(uuid)', 'execute'), false,
          'anon no ejecuta coordina_la_campania');
select is(has_function_privilege('authenticated', 'public.coordina_la_campania(uuid)', 'execute'), true,
          'authenticated sí (lo usan las políticas)');

-- ============================================================================
-- 2. campania.coordinador_id y la tabla, de acuerdo
-- ============================================================================
select is(pg_temp.vigentes('e1'), 'c1', 'la campaña que nace con coordinador en la columna lo tiene en la tabla');
select is(pg_temp.vigentes('e3'), '-', 'y la que nace sin coordinador, sin filas');
select is((select nombre || ' ' || apellido from public.campania_coordinador
            where campania_id = pg_temp.u('e1') and usuario_id = pg_temp.u('c1')),
          'Nombre c1 Apellido c1', 'la fila copia el nombre y el apellido del perfil');

-- El perfil cambia de nombre: la copia lo sigue (y la fila sube de versión para el delta).
update public.usuario set nombre = 'Luis', apellido = 'Pérez' where id = pg_temp.u('c1');
select is((select nombre || ' ' || apellido from public.campania_coordinador
            where campania_id = pg_temp.u('e1') and usuario_id = pg_temp.u('c1')),
          'Luis Pérez', 'si el coordinador cambia de nombre, la copia lo sigue');

-- Un segundo coordinador por la tabla: la columna sigue siendo el primero.
insert into public.campania_coordinador (campania_id, usuario_id, created_at) values (pg_temp.u('e1'), pg_temp.u('c2'), clock_timestamp());
select is(pg_temp.vigentes('e1'), 'c1,c2', 'una campaña tiene dos coordinadores vigentes');
select is(pg_temp.columna('e1'), 'c1', 'campania.coordinador_id es el primero (el más antiguo)');
select is(pg_temp.error_de($$ insert into public.campania_coordinador (campania_id, usuario_id)
                                values ('01920000-0000-7000-8000-0000000174e1', '01920000-0000-7000-8000-0000000174c2') $$),
          '23505', 'la misma persona no figura dos veces vigente en la misma campaña');
select is(pg_temp.error_de($$ update public.campania_coordinador set usuario_id = '01920000-0000-7000-8000-0000000174c3'
                              where campania_id = '01920000-0000-7000-8000-0000000174e1'
                                and usuario_id = '01920000-0000-7000-8000-0000000174c2' $$),
          'CC001', 'a una fila no se le cambia la persona (CC001)');
select is(pg_temp.error_de($$ update public.campania_coordinador set campania_id = '01920000-0000-7000-8000-0000000174e2'
                              where campania_id = '01920000-0000-7000-8000-0000000174e1'
                                and usuario_id = '01920000-0000-7000-8000-0000000174c2' $$),
          'CC001', 'ni la campaña (CC001)');

-- Dar de baja al primero: la columna pasa al siguiente; la fila de baja queda como historia.
update public.campania_coordinador set deleted_at = now()
 where campania_id = pg_temp.u('e1') and usuario_id = pg_temp.u('c1');
select is(pg_temp.vigentes('e1'), 'c2', 'la baja del primero deja al segundo');
select is(pg_temp.columna('e1'), 'c2', 'y la columna pasa al segundo');
select is((select count(*)::int from public.campania_coordinador where campania_id = pg_temp.u('e1')), 2,
          'la fila dada de baja queda (historia)');
-- Volver a sumar al mismo: es una fila nueva (y ahora la más nueva).
insert into public.campania_coordinador (campania_id, usuario_id, created_at) values (pg_temp.u('e1'), pg_temp.u('c1'), clock_timestamp());
select is(pg_temp.vigentes('e1'), 'c2,c1', 'volver a sumar a c1 es una fila nueva, después de c2');
select is((select count(*)::int from public.campania_coordinador where campania_id = pg_temp.u('e1')), 3,
          'con su fila vieja de baja como historia');
select is(pg_temp.columna('e1'), 'c2', 'la columna sigue en c2');

-- Reasignar la columna (el panel de antes): suma al nuevo y da de baja al anterior, o sea que reasignar sigue siendo reasignar.
update public.campania set coordinador_id = pg_temp.u('c3') where id = pg_temp.u('e1');
select is(pg_temp.columna('e1'), 'c3', 'reasignar la columna deja la columna como se escribió');
select is(pg_temp.vigentes('e1'), 'c1,c3', 'el reasignado entra a la tabla y el anterior (c2) sale; c1, que no era la columna, queda');
-- Dejarla en null baja al que figuraba.
update public.campania set coordinador_id = null where id = pg_temp.u('e1');
select is(pg_temp.vigentes('e1'), 'c1', 'dejarla en null da de baja a quien figuraba');
-- Y recalcula desde la tabla cuando la tabla cambia.
select is(pg_temp.columna('e1'), 'c1', 'y la columna vuelve a ser el primer vigente de la tabla');
-- Volver al estado de partida de la sección 3: c1 y c2 coordinan e1.
insert into public.campania_coordinador (campania_id, usuario_id, created_at) values (pg_temp.u('e1'), pg_temp.u('c2'), clock_timestamp());
select is(pg_temp.vigentes('e1'), 'c1,c2', 'e1 queda con c1 y c2');

-- Quién escribe la tabla.
select pg_temp.actuar_como(pg_temp.u('c1'));
select is(pg_temp.error_de($$ insert into public.campania_coordinador (campania_id, usuario_id)
                                values ('01920000-0000-7000-8000-0000000174e2', '01920000-0000-7000-8000-0000000174c1') $$),
          '42501', 'un coordinador no suma coordinadores (solo un ADMIN)');
select is(pg_temp.filas($$ update public.campania_coordinador set deleted_at = now()
                            where campania_id = '01920000-0000-7000-8000-0000000174e1' $$), 0::bigint,
          'ni los da de baja (la RLS no le deja ver nada para actualizar)');
select is((select count(*)::int from public.campania_coordinador), 5,
          'el coordinador lee las filas de su campaña (las suyas, las de sus colegas y la historia; 0178), no las de otra');
select is((select count(*)::int from public.campania_coordinador where campania_id <> pg_temp.u('e1')), 0,
          'y ninguna de otra campaña');
select pg_temp.actuar_como(pg_temp.u('b1'));
select is((select count(*)::int from public.campania_coordinador), 0, 'un colportor no lee la tabla (todavía: la lista del teléfono es la 0178)');
select pg_temp.actuar_como(pg_temp.u('ad'));
select is(pg_temp.error_de($$ insert into public.campania_coordinador (campania_id, usuario_id)
                               values ('01920000-0000-7000-8000-0000000174e2', '01920000-0000-7000-8000-0000000174c1') $$),
          'ok', 'un ADMIN suma a un coordinador a otra campaña');
select is((select count(*)::int from public.campania_coordinador where campania_id = pg_temp.u('e2')), 2,
          'y la ve (el ADMIN lee todo)');
select is(pg_temp.filas($$ update public.campania_coordinador set deleted_at = now()
                            where campania_id = '01920000-0000-7000-8000-0000000174e2'
                              and usuario_id = '01920000-0000-7000-8000-0000000174c1' $$), 1::bigint,
          'y lo da de baja');
select pg_temp.actuar_como_servidor();

-- ============================================================================
-- 3. Con dos coordinadores en la misma campaña, los dos pueden lo mismo
-- ============================================================================
-- Fixtures de lo que se mira: b1 (de baja con $ 70.000 de alquiler pagado, por decidir) y b2 (vivo) inscriptos en e1; b9 en e2.
insert into public.campania_colportor (campania_id, usuario_id, created_at) values
  (pg_temp.u('e1'), pg_temp.u('b1'), now() - interval '10 days'),
  (pg_temp.u('e1'), pg_temp.u('b2'), now() - interval '10 days'),
  (pg_temp.u('e2'), pg_temp.u('b9'), now() - interval '10 days');
insert into public.cuenta_colportor (usuario_id, deuda_total, dinero_depositado) values
  (pg_temp.u('b1'), 500000, 70000), (pg_temp.u('b2'), 500000, 0), (pg_temp.u('b9'), 500000, 0);
insert into public.deposito (id, colportor_id, monto, fecha, ticket_id, destino, concepto, campania_id, validado_en, validado_por) values
  (pg_temp.u('21'), pg_temp.u('b1'), 70000, now(), null, 'RETIRO_COORDINADOR', 'ALQUILER', pg_temp.u('e1'), now(), pg_temp.u('c1')),
  (pg_temp.u('22'), pg_temp.u('b9'), 1000, now(), null, 'RETIRO_COORDINADOR', 'CASA_EDITORA', null, now(), pg_temp.u('c3'));
update public.campania_colportor set deleted_at = now() - interval '2 days'
 where campania_id = pg_temp.u('e1') and usuario_id = pg_temp.u('b1');

-- coordina_la_campania
select pg_temp.actuar_como(pg_temp.u('c1'));
select is(public.coordina_la_campania(pg_temp.u('e1')), true, 'c1 coordina e1');
select pg_temp.actuar_como(pg_temp.u('c2'));
select is(public.coordina_la_campania(pg_temp.u('e1')), true, 'c2 también coordina e1');
select pg_temp.actuar_como(pg_temp.u('c3'));
select is(public.coordina_la_campania(pg_temp.u('e1')), false, 'c3 no coordina e1');
select is(public.coordina_la_campania(pg_temp.u('e2')), true, 'c3 coordina e2');

-- campanias_del_coordinador (el selector de campañas del panel)
select pg_temp.actuar_como(pg_temp.u('c2'));
select is((select array_agg(id order by nombre) from public.campanias_del_coordinador()), array[pg_temp.u('e1')],
          'c2 ve e1 en su selector (y solo esa)');
select pg_temp.actuar_como(pg_temp.u('c3'));
select is((select array_agg(id order by nombre) from public.campanias_del_coordinador()), array[pg_temp.u('e2')],
          'c3 ve solo e2');

-- el permiso del mapa (estas funciones las llama el servidor con la sesión de cada persona)
select pg_temp.actuar_como_servidor();
select is(pg_temp.motivo('motivo_mapa_de_campania', 'c1', 'e1'), 'ok', 'c1: el mapa de e1 está permitido');
select is(pg_temp.motivo('motivo_mapa_de_campania', 'c2', 'e1'), 'ok', 'c2: el mapa de e1 también');
select is(pg_temp.motivo('motivo_campania_del_coordinador', 'c2', 'e1'), 'ok', 'c2: y motivo_campania_del_coordinador');
select is(pg_temp.motivo('motivo_mapa_de_campania', 'c3', 'e1'), 'SIN_PERMISO', 'c3: el de e1 no');
select is(pg_temp.motivo('motivo_campania_del_coordinador', 'c3', 'e1'), 'SIN_PERMISO', 'c3: tampoco motivo_campania_del_coordinador');
select is(pg_temp.campanias_mapa('c3'), array[pg_temp.u('e2')], 'c3: sus campañas del mapa son solo e2');
select is(pg_temp.campanias_mapa('c2'), array[pg_temp.u('e1')], 'c2: sus campañas del mapa son e1');
select pg_temp.actuar_como(pg_temp.u('c2'));

-- las cuentas y los depósitos de su gente
select is((select count(*)::int from public.cuenta_colportor where usuario_id in (pg_temp.u('b1'), pg_temp.u('b2'), pg_temp.u('b9'))),
          2, 'c2 lee las cuentas de b1 y b2 (e1), no la de b9 (e2)');
select is((select count(*)::int from public.deposito where colportor_id in (pg_temp.u('b1'), pg_temp.u('b9'))), 1,
          'c2 lee el depósito de b1, no el de b9');
select pg_temp.actuar_como(pg_temp.u('c3'));
select is((select count(*)::int from public.cuenta_colportor where usuario_id in (pg_temp.u('b1'), pg_temp.u('b2'), pg_temp.u('b9'))),
          1, 'c3 lee solo la de b9');

-- la beca y la meta de su colportor
select pg_temp.actuar_como(pg_temp.u('c2'));
select is(pg_temp.filas($$ update public.campania_colportor set tipo_beca = 'MEDIA', meta_monto_ces = 3000000
                            where campania_id = '01920000-0000-7000-8000-0000000174e1'
                              and usuario_id = '01920000-0000-7000-8000-0000000174b2' $$), 1::bigint,
          'c2 fija la beca de b2');
select pg_temp.actuar_como(pg_temp.u('c3'));
select is(pg_temp.error_de($$ update public.campania_colportor set tipo_beca = 'COMPLETA', meta_monto_ces = 6000000
                              where campania_id = '01920000-0000-7000-8000-0000000174e1'
                                and usuario_id = '01920000-0000-7000-8000-0000000174b2' $$),
          '42501', 'c3 (otra campaña) no fija la beca de b2: 42501');
select is((select tipo_beca from public.campania_colportor
            where campania_id = pg_temp.u('e1') and usuario_id = pg_temp.u('b2')), 'MEDIA'::text,
          'y la beca de b2 sigue como la dejó c2');
select pg_temp.actuar_como_servidor();

-- decidir el alquiler de una baja (RPC): c2 puede, c3 no (AQ001)
select pg_temp.actuar_como(pg_temp.u('c3'));
select is(pg_temp.error_de($$ select * from public.decidir_alquiler_pagado('01920000-0000-7000-8000-0000000174b1',
                                  '01920000-0000-7000-8000-0000000174e1', 'SE_LO_QUEDA_EL_COORDINADOR') $$),
          'AQ001', 'c3 (otra campaña) no decide el alquiler de b1: AQ001');
select pg_temp.actuar_como(pg_temp.u('c2'));
select is(pg_temp.error_de($$ select * from public.decidir_alquiler_pagado('01920000-0000-7000-8000-0000000174b1',
                                  '01920000-0000-7000-8000-0000000174e1', 'SE_LO_QUEDA_EL_COORDINADOR') $$),
          'ok', 'c2 (el segundo coordinador) decide el alquiler de b1');
select is((select decision from public.alquiler_decision
            where usuario_id = pg_temp.u('b1') and campania_id = pg_temp.u('e1') and deleted_at is null),
          'SE_LO_QUEDA_EL_COORDINADOR'::text, 'y c2 lee la decisión que tomó (alquiler_decision_select)');
select is((select count(*)::int from public.cuenta_alquiler where campania_id = pg_temp.u('e1')), 2,
          'y lee la cuenta del alquiler de b1 y b2 (cuenta_alquiler_select)');
select pg_temp.actuar_como(pg_temp.u('c1'));
select is((select count(*)::int from public.alquiler_decision where campania_id = pg_temp.u('e1')), 1,
          'c1 lee la decisión de c2: la campaña es de los dos');
select pg_temp.actuar_como(pg_temp.u('c3'));
select is((select count(*)::int from public.alquiler_decision where campania_id = pg_temp.u('e1')), 0,
          'c3 no lee nada de e1');
select is((select count(*)::int from public.cuenta_alquiler where campania_id = pg_temp.u('e1')), 0,
          'ni la cuenta del alquiler');

-- Dar de baja a c2 le quita el permiso al instante.
select pg_temp.actuar_como_servidor();
update public.campania_coordinador set deleted_at = now()
 where campania_id = pg_temp.u('e1') and usuario_id = pg_temp.u('c2') and deleted_at is null;
select pg_temp.actuar_como(pg_temp.u('c2'));
select is(public.coordina_la_campania(pg_temp.u('e1')), false, 'c2, dado de baja, ya no coordina e1');
select is((select count(*)::int from public.cuenta_colportor where usuario_id in (pg_temp.u('b1'), pg_temp.u('b2'))), 0,
          'y no lee las cuentas de su ex equipo');
select pg_temp.actuar_como_servidor();
select is(pg_temp.motivo('motivo_mapa_de_campania', 'c2', 'e1'), 'SIN_PERMISO', 'y el mapa de e1 le da SIN_PERMISO');
select pg_temp.actuar_como(pg_temp.u('c1'));
select is(public.coordina_la_campania(pg_temp.u('e1')), true, 'c1, que sigue, conserva el permiso');
select pg_temp.actuar_como_servidor();

select * from finish();
rollback;
