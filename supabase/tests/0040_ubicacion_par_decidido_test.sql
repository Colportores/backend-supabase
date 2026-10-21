-- pgTAP · migración 0032 (backend-supabase#35): ubicacion_par_decidido sube al servidor.
--   1. La forma: columnas, el par ordenado, la decisión acotada, los índices (el delta con el dueño
--      primero), los triggers de auditoría, la RLS, los privilegios y el registro en sync.entidad.
--   2. La RLS contra la tabla: cada colportor lee y escribe lo suyo, sin columna de dueño (created_by lo
--      fija el servidor); ni el ADMIN ni un coordinador ven las de otros por la tabla; no se pasa una fila
--      a otro; sin DELETE; las restricciones con el SQLSTATE que el motor devuelve.
--   3. Por sync.push: idempotente por client_op_id, el dueño sale del JWT y no del payload, lo que
--      llega mal vuelve `invalid` con su código, lo ajeno no se toca, y una decisión que cuelga de un
--      alta en conflicto (D1) queda en espera, no se pierde.
--   4. R21 (public.metrica_r21): solo ADMIN, solo números, sin las dadas de baja.
-- El pull (reinstalar) está en 0041: el delta solo sirve filas commiteadas.
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
  perform set_config('request.jwt.claims', json_build_object('role', 'anon')::text, true);
  perform set_config('request.jwt.claim.sub', '', true);
  perform set_config('request.jwt.claim.role', 'anon', true);
  perform set_config('role', 'anon', true);
end $$;

-- Ids (prefijo 40, el número del archivo): usuarios 40b1.., ubicaciones 40a1.., decisiones 40d1..; los
-- client_op_id, 40 y dos dígitos (los otros llevan una letra, no se pisan).
create or replace function pg_temp.u(p text) returns uuid language sql as $$
  select ('01920000-0000-7000-8000-000000004' || '0' || p)::uuid;
$$;
create or replace function pg_temp.op(p text) returns uuid language sql as $$
  select ('01920000-0000-7000-8000-00000000' || '40' || p)::uuid;
$$;

-- «sqlstate restricción», u «ok», de lo que hace una sentencia (la excepción no deja la transacción rota).
create or replace function pg_temp.error_de(p_sql text) returns text language plpgsql as $$
declare
  v_restriccion text;
begin
  execute p_sql;
  return 'ok';
exception when others then
  get stacked diagnostics v_restriccion = constraint_name;
  return sqlstate || ' ' || coalesce(v_restriccion, '');
end $$;

-- El mensaje del error (para distinguir «sin sesión» de «no es ADMIN»: los dos son 42501).
create or replace function pg_temp.mensaje_de(p_sql text) returns text language plpgsql as $$
begin
  execute p_sql;
  return 'ok';
exception when others then
  return sqlerrm;
end $$;

-- Cuántas filas tocaría una sentencia de escritura («ok N»), o su SQLSTATE si falla; no deja nada hecho.
create or replace function pg_temp.probar(p_sql text) returns text language plpgsql as $$
declare
  v_n integer;
begin
  begin
    execute p_sql;
    get diagnostics v_n = row_count;
    raise exception 'deshacer';
  exception when others then
    if sqlerrm = 'deshacer' then
      return 'ok ' || v_n;
    end if;
    return sqlstate;
  end;
end $$;

-- Cuántas filas tocó una sentencia de escritura.
create or replace function pg_temp.filas(p_sql text) returns integer language plpgsql as $$
declare
  v_n integer;
begin
  execute p_sql;
  get diagnostics v_n = row_count;
  return v_n;
end $$;

-- El payload de una decisión tal como lo manda el teléfono.
create or replace function pg_temp.par(p_id uuid, p_a uuid, p_b uuid, p_decision text default 'CONSERVAR_AMBOS')
returns jsonb language sql as $$
  select jsonb_build_object('id', p_id, 'ubicacion_a_id', p_a, 'ubicacion_b_id', p_b,
                            'decision', p_decision, 'decidido_en', '2026-10-05T12:00:00Z');
$$;
-- Un job de push de la entidad; devuelve el resultado.
create or replace function pg_temp.push1(p_op uuid, p_tipo text, p_payload jsonb, p_version bigint default null)
returns jsonb language sql as $$
  select sync.push(jsonb_build_array(jsonb_strip_nulls(jsonb_build_object(
           'client_op_id', p_op, 'entity', 'ubicacion_par_decidido', 'op', p_tipo,
           'sync_version', p_version, 'payload', p_payload)))) -> 'results' -> 0;
$$;

-- --- fixtures (como postgres) --------------------------------------------------
-- Colportores b1 y b2 (inscriptos, sin zona, en una campaña vigente de la ciudad c1: lo que la RLS de
-- ubicacion pide para subir una casa), b3 (sin campaña), un coordinador y un ADMIN.
-- Ubicaciones a1..a5 (a1 = Av. Italia 100); sus ids crecen, así que (a1, a2) es un par ordenado.
insert into auth.users (id, instance_id, aud, role, email, encrypted_password, confirmed_at, created_at, updated_at)
select pg_temp.u(s), '00000000-0000-0000-0000-000000000000',
       'authenticated', 'authenticated', 'par40-' || s || '@example.com', 'x', now(), now(), now()
  from unnest(array['b1','b2','b3','c1','ad']) s;
insert into public.usuario_rol (usuario_id, rol_id)
select pg_temp.u(x.s), r.id
  from (values ('b1','COLPORTOR'), ('b2','COLPORTOR'), ('b3','COLPORTOR'), ('c1','COORDINADOR'), ('ad','ADMIN')) x(s, codigo)
  join public.rol r on r.codigo = x.codigo;

insert into public.pais (id, nombre, iso_code) values (pg_temp.u('f0'), 'Pais par40', 'ZQ');
insert into public.ciudad (id, nombre, pais_id, lat_centro, lon_centro)
values (pg_temp.u('f1'), 'Ciudad par40', pg_temp.u('f0'), -34.90, -56.20);
insert into public.campania (id, nombre, tipo, fecha_inicio, fecha_fin)
values (pg_temp.u('e0'), 'Verano par40', 'VERANO', current_date - 10, current_date + 30);
insert into public.campania_ciudad (id, campania_id, ciudad_id)
values (pg_temp.u('e1'), pg_temp.u('e0'), pg_temp.u('f1'));
insert into public.campania_colportor (campania_id, usuario_id) values
  (pg_temp.u('e0'), pg_temp.u('b1')), (pg_temp.u('e0'), pg_temp.u('b2'));

insert into public.ubicacion (id, tipo, calle, numero, lat, lon, ciudad_id) values
  (pg_temp.u('a1'), 'CASA', 'Av. Italia', '100',  -34.900, -56.200, pg_temp.u('f1')),
  (pg_temp.u('a2'), 'CASA', 'Calle Dos',  '2',    -34.905, -56.195, pg_temp.u('f1')),
  (pg_temp.u('a3'), 'CASA', 'Calle Tres', '3',    -34.910, -56.190, pg_temp.u('f1')),
  (pg_temp.u('a4'), 'CASA', 'Calle Cuatro', '4',  -34.915, -56.185, pg_temp.u('f1')),
  (pg_temp.u('a5'), 'CASA', 'Calle Cinco', '5',   -34.920, -56.180, pg_temp.u('f1'));

-- ---------------------------------------------------------------------------
-- 1. La forma
-- ---------------------------------------------------------------------------
select has_table('public', 'ubicacion_par_decidido', 'existe la tabla');
select columns_are('public', 'ubicacion_par_decidido',
  array['id', 'ubicacion_a_id', 'ubicacion_b_id', 'decision', 'decidido_en',
        'created_at', 'updated_at', 'created_by', 'deleted_at', 'sync_version', 'xmin_w'],
  'las cuatro columnas del teléfono más las de sync; sin motivo ni colportor_id');
select col_is_pk('public', 'ubicacion_par_decidido', 'id', 'la clave es un uuid (el motor identifica por una columna)');
select col_type_is('public', 'ubicacion_par_decidido', 'id', 'uuid', 'id uuid');
select col_type_is('public', 'ubicacion_par_decidido', 'decidido_en', 'timestamp with time zone', 'decidido_en timestamptz');
select col_not_null('public', 'ubicacion_par_decidido', 'decidido_en', 'decidido_en es obligatorio (la fecha va del teléfono)');
select col_hasnt_default('public', 'ubicacion_par_decidido', 'decidido_en', 'y sin default: el servidor no la inventa');
select col_not_null('public', 'ubicacion_par_decidido', 'decision', 'decision es obligatoria');
select col_has_default('public', 'ubicacion_par_decidido', 'created_by', 'created_by se fija desde el JWT (default auth.uid())');
select col_type_is('public', 'ubicacion_par_decidido', 'xmin_w', 'xid8', 'xmin_w xid8, como todas');
select fk_ok('public', 'ubicacion_par_decidido', 'ubicacion_a_id', 'public', 'ubicacion', 'id', 'a cuelga de ubicacion');
select fk_ok('public', 'ubicacion_par_decidido', 'ubicacion_b_id', 'public', 'ubicacion', 'id', 'b cuelga de ubicacion');
select ok(exists (select 1 from pg_constraint
                   where conrelid = 'public.ubicacion_par_decidido'::regclass and contype = 'c'
                     and conname = 'ubicacion_par_decidido_par_ordenado'
                     and pg_get_constraintdef(oid) like '%ubicacion_a_id < ubicacion_b_id%'),
          'CHECK a < b (el mismo que la tabla local)');
select ok(exists (select 1 from pg_constraint
                   where conrelid = 'public.ubicacion_par_decidido'::regclass and contype = 'c'
                     and conname = 'ubicacion_par_decidido_decision_valida'
                     and pg_get_constraintdef(oid) like '%CONSERVAR_AMBOS%' and pg_get_constraintdef(oid) like '%IGNORAR%'),
          'CHECK decision in (CONSERVAR_AMBOS, IGNORAR)');
select has_index('public', 'ubicacion_par_decidido', 'ubicacion_par_decidido_delta_idx',
                 array['created_by', 'xmin_w', 'id'], 'índice del delta con el dueño primero');
select has_index('public', 'ubicacion_par_decidido', 'ubicacion_par_decidido_ubicacion_a_idx', array['ubicacion_a_id'], 'índice por a');
select has_index('public', 'ubicacion_par_decidido', 'ubicacion_par_decidido_ubicacion_b_idx', array['ubicacion_b_id'], 'índice por b');
select ok((select i.indisunique and i.indpred is not null
             from pg_index i join pg_class c on c.oid = i.indexrelid
            where c.relname = 'ubicacion_par_decidido_par_vivo_uidx'),
          'un solo par vivo por colportor: único y parcial (la baja no estorba)');
select has_trigger('public', 'ubicacion_par_decidido', 'ubicacion_par_decidido_auditoria_insert', 'auditoría al insertar');
select has_trigger('public', 'ubicacion_par_decidido', 'ubicacion_par_decidido_auditoria_update', 'auditoría al modificar');
select ok((select relrowsecurity from pg_class where oid = 'public.ubicacion_par_decidido'::regclass), 'RLS habilitada');

-- (Las columnas de pg_policies no traen una collation determinable: se fija una al concatenar.)
select is(
  (select array_agg((p.policyname::text || ' ' || p.cmd::text || ' ' || p.roles::text) collate "C"
                    order by p.policyname::text collate "C")
     from pg_policies p where p.schemaname = 'public' and p.tablename = 'ubicacion_par_decidido'),
  array['ubicacion_par_decidido_insert_propio INSERT {authenticated}',
        'ubicacion_par_decidido_select_propio SELECT {authenticated}',
        'ubicacion_par_decidido_update_propio UPDATE {authenticated}'],
  'tres políticas, solo para authenticated, y ninguna de DELETE');
-- USING = lo que ve; WITH CHECK = lo que escribe (0021). Cada una se mira por separado contra el dueño.
select ok((select coalesce(p.qual, '') like '%created_by%auth.uid()%' from pg_policies p
            where p.policyname = 'ubicacion_par_decidido_select_propio'),
          'SELECT: lo que ve (USING) se mide contra el dueño');
select ok((select coalesce(p.qual, '') like '%created_by%auth.uid()%' from pg_policies p
            where p.policyname = 'ubicacion_par_decidido_update_propio'),
          'UPDATE: lo que ve (USING) se mide contra el dueño: no toca lo de otro');
select ok((select coalesce(p.with_check, '') like '%created_by%auth.uid()%' from pg_policies p
            where p.policyname = 'ubicacion_par_decidido_update_propio'),
          'UPDATE: lo que escribe (WITH CHECK) se mide contra el dueño: no se pasa una decisión a otro');
select ok((select coalesce(p.with_check, '') like '%created_by%auth.uid()%' from pg_policies p
            where p.policyname = 'ubicacion_par_decidido_insert_propio'),
          'INSERT: lo que escribe (WITH CHECK) se mide contra el dueño');

select table_privs_are('public', 'ubicacion_par_decidido', 'authenticated', array['SELECT', 'INSERT', 'UPDATE'],
                       'authenticated lee, inserta y modifica; no borra');
select table_privs_are('public', 'ubicacion_par_decidido', 'anon', array[]::text[], 'anon no tiene nada');

select results_eq(
  $$ select permite_push, columna_pk, columna_duenio, sigue_campanias
       from sync.entidad where nombre = 'ubicacion_par_decidido' $$,
  $$ values (true, 'id'::text, 'created_by'::text, false) $$,
  'registrada en sync.entidad como push, PK id, bajando solo lo del dueño (created_by), sin campañas');
select is((select tabla::text from sync.entidad where nombre = 'ubicacion_par_decidido'), 'ubicacion_par_decidido',
          'apunta a la tabla');
select ok(not ('created_by' = any (sync.columnas_escribibles('ubicacion_par_decidido'))),
          'created_by no es escribible por el cliente (no hay colportor_id que mandar)');
select ok(not ('sync_version' = any (sync.columnas_escribibles('ubicacion_par_decidido'))), 'ni sync_version');
select ok(sync.columnas_escribibles('ubicacion_par_decidido') @> array['ubicacion_a_id', 'ubicacion_b_id', 'decision', 'decidido_en', 'deleted_at'],
          'el par, la decisión, la fecha y la baja sí');

-- ---------------------------------------------------------------------------
-- 2. La RLS contra la tabla
-- ---------------------------------------------------------------------------
select pg_temp.actuar_como(pg_temp.u('b1'));
select is(pg_temp.error_de($$ insert into public.ubicacion_par_decidido (id, ubicacion_a_id, ubicacion_b_id, decision, decidido_en)
                              values (pg_temp.u('d1'), pg_temp.u('a1'), pg_temp.u('a2'), 'CONSERVAR_AMBOS', '2026-10-04 10:00+00') $$),
          'ok', 'b1 guarda su decisión (a1, a2)');
select is(pg_temp.error_de($$ insert into public.ubicacion_par_decidido (id, ubicacion_a_id, ubicacion_b_id, decision, decidido_en)
                              values (pg_temp.u('d2'), pg_temp.u('a1'), pg_temp.u('a3'), 'IGNORAR', '2026-10-04 11:00+00'),
                                     (pg_temp.u('d3'), pg_temp.u('a2'), pg_temp.u('a3'), 'CONSERVAR_AMBOS', '2026-10-04 12:00+00') $$),
          'ok', 'y dos más: (a1, a3) ignorada y (a2, a3) conservada');
select is((select created_by from public.ubicacion_par_decidido where id = pg_temp.u('d1')), pg_temp.u('b1'),
          'created_by sale del JWT, sin que nadie lo mande');
select is((select decidido_en from public.ubicacion_par_decidido where id = pg_temp.u('d1')), '2026-10-04 10:00+00'::timestamptz,
          'decidido_en es el del teléfono, no el de ahora');
select is(pg_temp.error_de($$ insert into public.ubicacion_par_decidido (id, created_by, ubicacion_a_id, ubicacion_b_id, decision, decidido_en)
                              values (pg_temp.u('d9'), pg_temp.u('b2'), pg_temp.u('a4'), pg_temp.u('a5'), 'IGNORAR', now()) $$),
          '42501 ', 'b1 no puede escribir una decisión a nombre de b2 (WITH CHECK)');
select is(pg_temp.error_de($$ insert into public.ubicacion_par_decidido (id, created_by, ubicacion_a_id, ubicacion_b_id, decision, decidido_en)
                              values (pg_temp.u('d9'), null, pg_temp.u('a4'), pg_temp.u('a5'), 'IGNORAR', now()) $$),
          '42501 ', 'ni sin dueño (created_by null)');

select pg_temp.actuar_como(pg_temp.u('b2'));
select is(pg_temp.error_de($$ insert into public.ubicacion_par_decidido (id, ubicacion_a_id, ubicacion_b_id, decision, decidido_en)
                              values (pg_temp.u('d4'), pg_temp.u('a1'), pg_temp.u('a2'), 'IGNORAR', '2026-10-04 13:00+00'),
                                     (pg_temp.u('d5'), pg_temp.u('a1'), pg_temp.u('a4'), 'CONSERVAR_AMBOS', '2026-10-04 14:00+00') $$),
          'ok', 'b2 decide el MISMO par (a1, a2) que b1 (una por colportor) y otro más');

-- Quién ve qué: cada uno, lo suyo.
select is((select count(*)::int from public.ubicacion_par_decidido), 2, 'b2 ve solo las suyas');
select is((select array_agg(right(id::text, 2) order by id) from public.ubicacion_par_decidido), array['d4', 'd5'],
          'las suyas: d4 y d5, no las de b1 (d1, d2, d3)');
select pg_temp.actuar_como(pg_temp.u('b1'));
select is((select array_agg(right(id::text, 2) order by id) from public.ubicacion_par_decidido), array['d1', 'd2', 'd3'], 'b1 ve las tres suyas');
select pg_temp.actuar_como(pg_temp.u('b3'));
select is((select count(*)::int from public.ubicacion_par_decidido), 0, 'b3 (sin decisiones) no ve nada');
select pg_temp.actuar_como(pg_temp.u('c1'));
select is((select count(*)::int from public.ubicacion_par_decidido), 0, 'el coordinador no ve las de nadie por la tabla');
select pg_temp.actuar_como(pg_temp.u('ad'));
select is((select count(*)::int from public.ubicacion_par_decidido), 0, 'ni el ADMIN: la cuenta de todos es la de R21, por la función');
select pg_temp.actuar_como_anon();
select is(pg_temp.error_de('select count(*) from public.ubicacion_par_decidido'), '42501 ', 'anon: permission denied');
select is(pg_temp.error_de($$ insert into public.ubicacion_par_decidido (ubicacion_a_id, ubicacion_b_id, decision, decidido_en)
                              values (pg_temp.u('a1'), pg_temp.u('a2'), 'IGNORAR', now()) $$), '42501 ', 'ni escribe');

-- Lo ajeno no se toca: ni modificar ni dar de baja ni borrar.
select pg_temp.actuar_como(pg_temp.u('b2'));
select is(pg_temp.filas($$ update public.ubicacion_par_decidido set decision = 'IGNORAR' where id = pg_temp.u('d1') $$), 0,
          'b2 no modifica la decisión de b1 (la fila ni se ve)');
select is(pg_temp.filas($$ update public.ubicacion_par_decidido set deleted_at = now() where id = pg_temp.u('d1') $$), 0,
          'ni la da de baja');
select is(pg_temp.error_de($$ delete from public.ubicacion_par_decidido where id = pg_temp.u('d4') $$), '42501 ',
          'nadie borra: ni lo propio (una baja es deleted_at)');
-- Sin WHERE Postgres no aplica la política de SELECT a lo que busca: lo que frena es el USING del UPDATE.
select is(pg_temp.probar($$ update public.ubicacion_par_decidido set decision = 'IGNORAR' $$), 'ok 2',
          'un UPDATE sin WHERE de b2 toca solo sus dos (d4, d5), sin error: lo de b1 ni se mira');
select is(pg_temp.probar($$ update public.ubicacion_par_decidido set decidido_en = now() where id = pg_temp.u('d1') $$), 'ok 0',
          'y apuntando a la d1 de b1, ninguna');
-- Pasar una fila propia a otro: el dueño no cambia (tg_auditoria_update lo deja como estaba).
select is(pg_temp.error_de($$ update public.ubicacion_par_decidido set created_by = pg_temp.u('b1') where id = pg_temp.u('d4') $$),
          'ok', 'b2 intenta pasarle su d4 a b1: la sentencia no rompe');
select is((select created_by from public.ubicacion_par_decidido where id = pg_temp.u('d4')), pg_temp.u('b2'),
          'y d4 sigue siendo de b2');
select pg_temp.actuar_como_servidor();
select is((select created_by from public.ubicacion_par_decidido where id = pg_temp.u('d4')), pg_temp.u('b2'),
          'visto como servidor también: no se la regaló a b1');

-- Lo propio: decidir de nuevo pisa la decisión.
select pg_temp.actuar_como(pg_temp.u('b1'));
select is(pg_temp.filas($$ update public.ubicacion_par_decidido set decision = 'CONSERVAR_AMBOS', decidido_en = '2026-10-06 09:00+00'
                           where id = pg_temp.u('d2') $$), 1,
          'b1 cambia de idea sobre (a1, a3): IGNORAR pasa a CONSERVAR_AMBOS');
select is((select sync_version from public.ubicacion_par_decidido where id = pg_temp.u('d2')), 1::bigint,
          'y sube sync_version (el teléfono ve el cambio)');
select is(pg_temp.filas($$ update public.ubicacion_par_decidido set deleted_at = now() where id = pg_temp.u('d3') $$), 1,
          'b1 da de baja (a2, a3): tombstone');
select is(pg_temp.error_de($$ insert into public.ubicacion_par_decidido (id, ubicacion_a_id, ubicacion_b_id, decision, decidido_en)
                              values (pg_temp.u('d6'), pg_temp.u('a2'), pg_temp.u('a3'), 'IGNORAR', now()) $$),
          'ok', 'y ese par se puede decidir de nuevo con otra fila: la baja no estorba');

-- Las bajas también son de su dueño: con la baja (d3) de b1 en la tabla, nadie más la ve.
select pg_temp.actuar_como(pg_temp.u('b2'));
select is((select array_agg(right(id::text, 2) order by id) from public.ubicacion_par_decidido), array['d4', 'd5'],
          'b2 sigue viendo solo las suyas: ni la baja (d3) ni la nueva (d6) de b1');
select pg_temp.actuar_como(pg_temp.u('b3'));
select is((select count(*)::int from public.ubicacion_par_decidido), 0, 'b3 no ve ni las bajas de nadie');
select pg_temp.actuar_como(pg_temp.u('c1'));
select is((select count(*)::int from public.ubicacion_par_decidido), 0, 'el coordinador tampoco');
select pg_temp.actuar_como(pg_temp.u('ad'));
select is((select count(*)::int from public.ubicacion_par_decidido), 0, 'ni el ADMIN');
select pg_temp.actuar_como(pg_temp.u('b1'));
select is((select array_agg(right(id::text, 2) order by id) from public.ubicacion_par_decidido), array['d1', 'd2', 'd3', 'd6'],
          'b1 sí ve las suyas, la baja incluida (el teléfono la baja como tombstone)');

-- Las restricciones, con el SQLSTATE que el motor devuelve como `invalid`.
select is(pg_temp.error_de($$ insert into public.ubicacion_par_decidido (ubicacion_a_id, ubicacion_b_id, decision, decidido_en)
                              values (pg_temp.u('a2'), pg_temp.u('a1'), 'IGNORAR', now()) $$),
          '23514 ubicacion_par_decidido_par_ordenado', 'el par desordenado (b, a) se rechaza');
select is(pg_temp.error_de($$ insert into public.ubicacion_par_decidido (ubicacion_a_id, ubicacion_b_id, decision, decidido_en)
                              values (pg_temp.u('a1'), pg_temp.u('a1'), 'IGNORAR', now()) $$),
          '23514 ubicacion_par_decidido_par_ordenado', 'el par de una ubicación consigo misma, también');
select is(pg_temp.error_de($$ insert into public.ubicacion_par_decidido (ubicacion_a_id, ubicacion_b_id, decision, decidido_en)
                              values (pg_temp.u('a4'), pg_temp.u('a5'), 'TAL_VEZ', now()) $$),
          '23514 ubicacion_par_decidido_decision_valida', 'una decisión que no es una de las dos se rechaza');
select is(pg_temp.error_de($$ insert into public.ubicacion_par_decidido (ubicacion_a_id, ubicacion_b_id, decision, decidido_en)
                              values (pg_temp.u('a4'), pg_temp.u('a5'), null, now()) $$) like '23502%', true, 'sin decisión: not null');
select is(pg_temp.error_de($$ insert into public.ubicacion_par_decidido (ubicacion_a_id, ubicacion_b_id, decision, decidido_en)
                              values (pg_temp.u('a4'), pg_temp.u('a5'), 'IGNORAR', null) $$) like '23502%', true, 'sin fecha: not null');
select is(pg_temp.error_de($$ insert into public.ubicacion_par_decidido (ubicacion_a_id, ubicacion_b_id, decision, decidido_en)
                              values (pg_temp.u('a4'), pg_temp.u('af'), 'IGNORAR', now()) $$),
          '23503 ubicacion_par_decidido_ubicacion_b_id_fkey', 'una ubicación que no existe: foreign key');
select is(pg_temp.error_de($$ insert into public.ubicacion_par_decidido (ubicacion_a_id, ubicacion_b_id, decision, decidido_en)
                              values (pg_temp.u('a1'), pg_temp.u('a2'), 'IGNORAR', now()) $$),
          '23505 ubicacion_par_decidido_par_vivo_uidx', 'el mismo par vivo dos veces para el mismo colportor: único');
select is(pg_temp.error_de($$ insert into public.ubicacion_par_decidido (id, ubicacion_a_id, ubicacion_b_id, decision, decidido_en)
                              values (pg_temp.u('d1'), pg_temp.u('a4'), pg_temp.u('a5'), 'IGNORAR', now()) $$),
          '23505 ubicacion_par_decidido_pkey', 'el mismo id dos veces: clave primaria');

-- ---------------------------------------------------------------------------
-- 3. Por sync.push
-- ---------------------------------------------------------------------------
select pg_temp.actuar_como(pg_temp.u('b1'));
create temp table r_alta as
  select pg_temp.push1(pg_temp.op('01'), 'insert',
                       pg_temp.par(pg_temp.u('d7'), pg_temp.u('a3'), pg_temp.u('a4'))
                         || jsonb_build_object('created_by', pg_temp.u('b2'))) as r;
select is((select r ->> 'outcome' from r_alta), 'accepted', 'el push de una decisión se acepta');
select is((select created_by from public.ubicacion_par_decidido where id = pg_temp.u('d7')), pg_temp.u('b1'),
          'el dueño es quien sube (JWT): el created_by del payload se descarta');

select is((select pg_temp.push1(pg_temp.op('01'), 'insert',
                                pg_temp.par(pg_temp.u('d7'), pg_temp.u('a3'), pg_temp.u('a4'))) ->> 'outcome'),
          'duplicate', 'el mismo client_op_id otra vez: duplicate (idempotente)');
select is((select pg_temp.push1(pg_temp.op('02'), 'insert',
                                pg_temp.par(pg_temp.u('d7'), pg_temp.u('a3'), pg_temp.u('a4'), 'IGNORAR')) ->> 'outcome'),
          'duplicate', 'el mismo id con otro client_op_id (un reintento tras reinstalar): duplicate');
select pg_temp.actuar_como_servidor();
select is((select count(*)::int from public.ubicacion_par_decidido where id = pg_temp.u('d7')), 1, 'una sola fila');
select is((select decision from public.ubicacion_par_decidido where id = pg_temp.u('d7')), 'CONSERVAR_AMBOS',
          'y el reintento no pisó la decisión');

-- El id de otro colportor: no se escribe ni se toca la fila ajena.
select pg_temp.actuar_como(pg_temp.u('b2'));
select is((select pg_temp.push1(pg_temp.op('03'), 'insert',
                                pg_temp.par(pg_temp.u('d7'), pg_temp.u('a3'), pg_temp.u('a4'), 'IGNORAR')) ->> 'outcome'),
          'duplicate', 'b2 sube un alta con el id que ya usó b1: duplicate (el id lo genera el teléfono; no se comparte)');
select is((select count(*)::int from public.ubicacion_par_decidido where id = pg_temp.u('d7')), 0, 'b2 no ve esa fila');
select pg_temp.actuar_como_servidor();
select is((select array[created_by::text, decision] from public.ubicacion_par_decidido where id = pg_temp.u('d7')),
          array[pg_temp.u('b1')::text, 'CONSERVAR_AMBOS'], 'la fila de b1 sigue igual');

-- Modificar: LWW por sync_version.
select pg_temp.actuar_como(pg_temp.u('b1'));
select is((select pg_temp.push1(pg_temp.op('04'), 'update',
                                jsonb_build_object('id', pg_temp.u('d7'), 'decision', 'IGNORAR',
                                                   'decidido_en', '2026-10-06T08:00:00Z'), 0) ->> 'outcome'),
          'accepted', 'b1 cambia su decisión con la versión que tiene');
select is((select decision from public.ubicacion_par_decidido where id = pg_temp.u('d7')), 'IGNORAR', 'quedó cambiada');
select is((select sync_version from public.ubicacion_par_decidido where id = pg_temp.u('d7')), 1::bigint, 'con la versión nueva');
select is((select pg_temp.push1(pg_temp.op('05'), 'update',
                                jsonb_build_object('id', pg_temp.u('d7'), 'decision', 'CONSERVAR_AMBOS'), 0) ->> 'outcome'),
          'conflict', 'con una versión vieja es conflict (gana el servidor)');
select is((select decision from public.ubicacion_par_decidido where id = pg_temp.u('d7')), 'IGNORAR', 'y no se pisó');

-- Lo ajeno por push: no existe para quien sube.
select pg_temp.actuar_como(pg_temp.u('b2'));
select is((select pg_temp.push1(pg_temp.op('06'), 'update',
                                jsonb_build_object('id', pg_temp.u('d7'), 'decision', 'CONSERVAR_AMBOS'), 1) ->> 'outcome'),
          'invalid', 'b2 intenta modificar la de b1: invalid');
select is((select pg_temp.push1(pg_temp.op('07'), 'update',
                                jsonb_build_object('id', pg_temp.u('d7'), 'decision', 'CONSERVAR_AMBOS'), 1) ->> 'code'),
          'FILA_INEXISTENTE', 'FILA_INEXISTENTE: para b2 esa fila no existe');
select is((select pg_temp.push1(pg_temp.op('08'), 'delete', jsonb_build_object('id', pg_temp.u('d7')), 1) ->> 'outcome'),
          'invalid', 'ni darla de baja');
select pg_temp.actuar_como_servidor();
select is((select array[decision, deleted_at::text] from public.ubicacion_par_decidido where id = pg_temp.u('d7')),
          array['IGNORAR', null], 'la fila de b1 no cambió ni se dio de baja');

-- La baja propia (tombstone), por push.
select pg_temp.actuar_como(pg_temp.u('b1'));
select is((select pg_temp.push1(pg_temp.op('09'), 'delete', jsonb_build_object('id', pg_temp.u('d7')), 1) ->> 'outcome'),
          'accepted', 'b1 da de baja la suya');
select ok((select deleted_at is not null from public.ubicacion_par_decidido where id = pg_temp.u('d7')),
          'queda con deleted_at: la fila no se borra');

-- Lo que llega mal vuelve invalid con su código (y no tumba al lote).
select is((select pg_temp.push1(pg_temp.op('10'), 'insert',
                                pg_temp.par(pg_temp.u('d8'), pg_temp.u('a2'), pg_temp.u('a1'))) ->> 'code'),
          '23514', 'el par desordenado: invalid 23514');
select is((select pg_temp.push1(pg_temp.op('11'), 'insert',
                                pg_temp.par(pg_temp.u('d8'), pg_temp.u('a4'), pg_temp.u('a5'), 'TAL_VEZ')) ->> 'code'),
          '23514', 'una decisión que no es de las dos: invalid 23514');
select is((select pg_temp.push1(pg_temp.op('12'), 'insert',
                                pg_temp.par(pg_temp.u('d8'), pg_temp.u('a4'), pg_temp.u('a5')) - 'decidido_en') ->> 'code'),
          '23502', 'sin fecha: invalid 23502');
select is((select pg_temp.push1(pg_temp.op('13'), 'insert',
                                pg_temp.par(pg_temp.u('d8'), pg_temp.u('a4'), pg_temp.u('af'))) ->> 'code'),
          '23503', 'una ubicación desconocida: invalid 23503');
select is((select pg_temp.push1(pg_temp.op('14'), 'insert',
                                pg_temp.par(pg_temp.u('d8'), pg_temp.u('a1'), pg_temp.u('a2'))) ->> 'code'),
          '23505', 'el mismo par vivo con otro id: invalid 23505');
select pg_temp.actuar_como_servidor();
select is((select count(*)::int from public.ubicacion_par_decidido where id = pg_temp.u('d8')), 0, 'ninguna de esas escribió nada');

-- Una decisión que cuelga de un alta en conflicto (D1: otra ubicación de la misma dirección a menos
-- de 100 m) no es un error de payload: queda en espera y se sube cuando la app resuelva el par (0017).
select pg_temp.actuar_como(pg_temp.u('b1'));
create temp table r_espera as
select sync.push(jsonb_build_array(
  jsonb_build_object('client_op_id', pg_temp.op('20'), 'entity', 'ubicacion', 'op', 'insert',
                     'payload', jsonb_build_object('id', pg_temp.u('a9'), 'tipo', 'CASA', 'calle', 'Av.  Italia', 'numero', '100',
                                                   'lat', -34.9003, 'lon', -56.2, 'ciudad_id', pg_temp.u('f1'))),
  jsonb_build_object('client_op_id', pg_temp.op('21'), 'entity', 'ubicacion_par_decidido', 'op', 'insert',
                     'payload', pg_temp.par(pg_temp.u('d8'), pg_temp.u('a1'), pg_temp.u('a9'))))) -> 'results' as r;
select is((select r -> 0 ->> 'outcome' from r_espera), 'conflict', 'la casa que choca por dirección vuelve conflict (queda en el teléfono)');
select is((select r -> 1 ->> 'code' from r_espera), 'ESPERA_ALTA_EN_CONFLICTO',
          'la decisión que la nombra queda en espera, no invalid');
select is((select r -> 1 ->> 'outcome' from r_espera), 'conflict', 'como conflict');
select is((select r -> 1 ->> 'depends_on' from r_espera), pg_temp.u('a9')::text, 'esperando a esa casa');
select pg_temp.actuar_como_servidor();
select is((select count(*)::int from public.ubicacion_par_decidido where id = pg_temp.u('d8')), 0,
          'sin escribir nada: al reintentarla, se vuelve a revisar');

-- ---------------------------------------------------------------------------
-- 4. R21
-- ---------------------------------------------------------------------------
-- Estado conocido: se vacía la tabla (es una transacción) y se cargan seis decisiones.
--   b1: (a1,a2) CONSERVAR, (a1,a3) CONSERVAR, (a2,a3) IGNORAR, (a1,a4) CONSERVAR dada de baja
--   b2: (a1,a2) CONSERVAR (el mismo par: cuenta otra vez, es otro colportor), (a1,a5) IGNORAR
delete from public.ubicacion_par_decidido;
insert into public.ubicacion_par_decidido (ubicacion_a_id, ubicacion_b_id, decision, decidido_en, created_by, deleted_at) values
  (pg_temp.u('a1'), pg_temp.u('a2'), 'CONSERVAR_AMBOS', now(), pg_temp.u('b1'), null),
  (pg_temp.u('a1'), pg_temp.u('a3'), 'CONSERVAR_AMBOS', now(), pg_temp.u('b1'), null),
  (pg_temp.u('a2'), pg_temp.u('a3'), 'IGNORAR',         now(), pg_temp.u('b1'), null),
  (pg_temp.u('a1'), pg_temp.u('a4'), 'CONSERVAR_AMBOS', now(), pg_temp.u('b1'), now()),
  (pg_temp.u('a1'), pg_temp.u('a2'), 'CONSERVAR_AMBOS', now(), pg_temp.u('b2'), null),
  (pg_temp.u('a1'), pg_temp.u('a5'), 'IGNORAR',         now(), pg_temp.u('b2'), null);

select ok(not has_function_privilege('anon', 'public.metrica_r21()', 'execute'), 'anon no ejecuta metrica_r21');
select ok(has_function_privilege('authenticated', 'public.metrica_r21()', 'execute'),
          'authenticated sí (adentro, solo el ADMIN pasa)');
select ok((select p.prosecdef from pg_proc p where p.oid = 'public.metrica_r21()'::regprocedure),
          'es SECURITY DEFINER: cuenta lo que la RLS le esconde a cada uno');
select ok((select p.proconfig @> array['search_path=""'] from pg_proc p where p.oid = 'public.metrica_r21()'::regprocedure),
          'con search_path vacío');

select pg_temp.actuar_como(pg_temp.u('ad'));
select results_eq(
  $$ select decisiones, conservar_ambos, ignorar, proporcion_conservar_ambos from public.metrica_r21() $$,
  $$ values (5::bigint, 3::bigint, 2::bigint, 0.6::numeric) $$,
  'el ADMIN: 5 decisiones vivas, 3 «Conservar ambos», 2 «Ignorar», 60 % (la dada de baja no cuenta)');
select is((select array_agg(k order by k) from jsonb_object_keys((select to_jsonb(r) from public.metrica_r21() r)) k),
          array['conservar_ambos', 'decisiones', 'ignorar', 'proporcion_conservar_ambos'],
          'devuelve solo números: ninguna ubicación, ningún par, ningún colportor');
select is((select count(*)::int from public.metrica_r21()), 1, 'una sola fila');

select is(pg_temp.error_de('select * from public.metrica_r21()'), 'ok', 'el ADMIN la ejecuta');
select pg_temp.actuar_como(pg_temp.u('b1'));
select is(pg_temp.error_de('select * from public.metrica_r21()'), '42501 ', 'un colportor, aunque sea dueño de decisiones: 42501');
select pg_temp.actuar_como(pg_temp.u('c1'));
select is(pg_temp.error_de('select * from public.metrica_r21()'), '42501 ', 'un coordinador: 42501');
select pg_temp.actuar_como(pg_temp.u('b3'));
select is(pg_temp.error_de('select * from public.metrica_r21()'), '42501 ', 'quien no tiene decisiones ni campañas: 42501');
select pg_temp.actuar_como_anon();
select is(pg_temp.error_de('select * from public.metrica_r21()'), '42501 ', 'anon: 42501');
select pg_temp.actuar_como_servidor();
select is(pg_temp.error_de('select * from public.metrica_r21()'), '42501 ', 'sin sesión (servidor sin JWT): 42501');
select is(pg_temp.mensaje_de('select * from public.metrica_r21()'), 'metrica_r21 requiere un usuario autenticado',
          'y el aviso dice que falta la sesión (no que «no es ADMIN»)');
select pg_temp.actuar_como(pg_temp.u('b1'));
select is(pg_temp.mensaje_de('select * from public.metrica_r21()'), 'metrica_r21 es solo para el ADMIN',
          'a un colportor le dice que es solo para el ADMIN');

-- Sin decisiones vivas no hay proporción: null, no 0 ni un error de división.
select pg_temp.actuar_como_servidor();
update public.ubicacion_par_decidido set deleted_at = now() where deleted_at is null;
select pg_temp.actuar_como(pg_temp.u('ad'));
select results_eq(
  $$ select decisiones, conservar_ambos, ignorar, proporcion_conservar_ambos from public.metrica_r21() $$,
  $$ values (0::bigint, 0::bigint, 0::bigint, null::numeric) $$,
  'sin decisiones vivas: (0, 0, 0, null)');

select * from finish();
rollback;
