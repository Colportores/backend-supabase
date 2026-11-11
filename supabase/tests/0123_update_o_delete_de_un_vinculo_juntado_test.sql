-- pgTAP · migración 0123 (backend-supabase#143; decisión de Cristian del 23/10, «Edición tarde»): el update
-- o delete de un vínculo (espacio_persona) que se juntó con otro al llegar (0064) se aplica al que quedó,
-- con conflicto si el que quedó cambió desde la unión; el delete se acepta sin darlo de baja; esos ids
-- dejan de responder FILA_INEXISTENTE. El alta que se junta (`merged`) está en 0044 y 0056.
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
  select ('01920000-0000-7000-8000-0000000143' || p)::uuid;
$$;
create or replace function pg_temp.job(p_ent text, p_op text, p_payload jsonb, p_version bigint default null,
                                       p_op_id uuid default gen_random_uuid()) returns jsonb language sql as $$
  select jsonb_build_object('client_op_id', p_op_id, 'entity', p_ent, 'op', p_op, 'payload', p_payload)
         || case when p_version is null then '{}'::jsonb else jsonb_build_object('sync_version', p_version) end;
$$;
create or replace function pg_temp.resultados(p_r jsonb) returns text[] language sql as $$
  select array_agg((e ->> 'outcome') || coalesce(' ' || (e ->> 'code'), '') order by i)
    from jsonb_array_elements(p_r -> 'results') with ordinality x(e, i);
$$;

-- --- fixtures (como postgres) --------------------------------------------------
-- Ids (prefijo 143): usuarios b1 (Luis) y b2 (Ana); ubicaciones 01 A, 02 B, 03 C, 04 D (dirección de cobro);
-- espacios únicos 11 (A), 12 (B), 13 (C); personas 60 (en las tres casas) y 61 (en A y B); vínculos
-- 21 (A, 60), 22 (B, 60), 23 (C, 60), 24 (A, 61), 25 (B, 61), todos de Luis.
insert into auth.users (id, instance_id, aud, role, email, encrypted_password, confirmed_at, created_at, updated_at)
select pg_temp.u(s), '00000000-0000-0000-0000-000000000000',
       'authenticated', 'authenticated', 'edicion143-' || s || '@example.com', 'x', now(), now(), now()
  from unnest(array['b1','b2']) s;
insert into public.pais (id, nombre, iso_code) values (pg_temp.u('f0'), 'Pais edicion143', 'ZK');
insert into public.ciudad (id, nombre, departamento, pais_id, lat_centro, lon_centro)
values (pg_temp.u('f1'), 'Ciudad edicion143', 'Departamento de prueba', pg_temp.u('f0'), -34.9, -56.2);
insert into public.campania (id, nombre, tipo, fecha_inicio, fecha_fin)
values (pg_temp.u('f3'), 'Verano edicion143', 'VERANO', public.hoy_montevideo() - 10, public.hoy_montevideo() + 30);
insert into public.campania_ciudad (id, campania_id, ciudad_id) values (pg_temp.u('f5'), pg_temp.u('f3'), pg_temp.u('f1'));
insert into public.campania_colportor (campania_id, usuario_id, zona_id) values
  (pg_temp.u('f3'), pg_temp.u('b1'), null), (pg_temp.u('f3'), pg_temp.u('b2'), null);
insert into public.ubicacion (id, tipo, calle, numero, lat, lon, ciudad_id, created_by)
select pg_temp.u(x.u), 'CASA', 'Edicion ' || x.u, x.u, -34.9 - x.n * 0.01, -56.2, pg_temp.u('f1'), pg_temp.u('b1')
  from (values ('01', 1), ('02', 2), ('03', 3), ('04', 4)) x(u, n);
insert into public.espacio (id, ubicacion_id, numero_depto, created_by)
values (pg_temp.u('11'), pg_temp.u('01'), null, pg_temp.u('b1')),
       (pg_temp.u('12'), pg_temp.u('02'), null, pg_temp.u('b1')),
       (pg_temp.u('13'), pg_temp.u('03'), null, pg_temp.u('b1'));
insert into public.espacio_persona (id, espacio_id, persona_id, created_by)
values (pg_temp.u('21'), pg_temp.u('11'), pg_temp.u('60'), pg_temp.u('b1')),
       (pg_temp.u('22'), pg_temp.u('12'), pg_temp.u('60'), pg_temp.u('b1')),
       (pg_temp.u('23'), pg_temp.u('13'), pg_temp.u('60'), pg_temp.u('b1')),
       (pg_temp.u('24'), pg_temp.u('11'), pg_temp.u('61'), pg_temp.u('b1')),
       (pg_temp.u('25'), pg_temp.u('12'), pg_temp.u('61'), pg_temp.u('b1'));

-- ---------------------------------------------------------------------------
-- 1. B se une a A; Ana (b2) sube a Pedro (60, id 31) y a la persona 61 (id 32) en B: los dos se juntan
-- ---------------------------------------------------------------------------
select pg_temp.actuar_como(pg_temp.u('b1'));
select is(public.marcar_como_duplicado(pg_temp.u('02'), pg_temp.u('01')) ->> 'ya_unida', 'false', 'Luis une B (02) a A (01)');
select pg_temp.actuar_como(pg_temp.u('b2'));
create temp table lote_1 on commit drop as
select sync.push(jsonb_build_array(
  pg_temp.job('espacio_persona', 'insert', jsonb_build_object('id', pg_temp.u('31'), 'espacio_id', pg_temp.u('12'),
              'persona_id', pg_temp.u('60'))),
  pg_temp.job('espacio_persona', 'insert', jsonb_build_object('id', pg_temp.u('32'), 'espacio_id', pg_temp.u('12'),
              'persona_id', pg_temp.u('61')))
)) as r;
select is((select pg_temp.resultados(r) from lote_1), array['merged', 'merged'], 'el alta de Pedro (31) y la de la persona 61 (32) se juntan');
select pg_temp.actuar_como_servidor();
select is((select pu.destino_version from public.espacio_persona_union pu where pu.duplicada_id = pg_temp.u('31')),
          (select ep.sync_version from public.espacio_persona ep where ep.id = pg_temp.u('21')),
          'la unión guarda la versión que tenía el vínculo que quedó (21) al juntarse');
select is((select pu.destino_version from public.espacio_persona_union pu where pu.duplicada_id = pg_temp.u('32')),
          (select ep.sync_version from public.espacio_persona ep where ep.id = pg_temp.u('24')),
          'y la del otro (24)');

-- ---------------------------------------------------------------------------
-- 2. Update: Ana cambia la dirección de cobro de Pedro (31) y se aplica al 21
-- ---------------------------------------------------------------------------
select pg_temp.actuar_como_servidor();
create temp table version_21_antes on commit drop as
select (select pu.destino_version from public.espacio_persona_union pu where pu.duplicada_id = pg_temp.u('31')) as v;
select pg_temp.actuar_como(pg_temp.u('b2'));
create temp table lote_2 on commit drop as
select sync.push(jsonb_build_array(
  pg_temp.job('espacio_persona', 'update',
              jsonb_build_object('id', pg_temp.u('31'), 'ubicacion_cobranza_alt_id', pg_temp.u('04')), 0,
              pg_temp.u('a1'))
)) as r;
select is((select pg_temp.resultados(r) from lote_2), array['accepted'], 'el update de Pedro (31) se acepta, ya no es FILA_INEXISTENTE');
select pg_temp.actuar_como_servidor();
select is((select ubicacion_cobranza_alt_id from public.espacio_persona where id = pg_temp.u('21')), pg_temp.u('04'),
          'la dirección de cobro quedó en el vínculo que quedó (21)');
select is((select count(*) from public.espacio_persona where id = pg_temp.u('31')), 0::bigint, 'el 31 sigue sin ser una fila');
select is((select created_by from public.espacio_persona where id = pg_temp.u('21')), pg_temp.u('b1'), 'el 21 sigue siendo de Luis');
select is((select deleted_at from public.espacio_persona where id = pg_temp.u('21')), null, 'y sigue vivo');
select is((select (r -> 'results' -> 0 ->> 'sync_version')::bigint from lote_2),
          (select sync_version from public.espacio_persona where id = pg_temp.u('21')),
          'la respuesta trae la sync_version nueva del que quedó');
select cmp_ok((select sync_version from public.espacio_persona where id = pg_temp.u('21')), '>', (select v from version_21_antes),
              'la versión del 21 subió');
select is((select pu.destino_version from public.espacio_persona_union pu where pu.duplicada_id = pg_temp.u('31')),
          (select sync_version from public.espacio_persona where id = pg_temp.u('21')),
          'la unión recuerda la versión nueva');

-- Reintentar el mismo trabajo (mismo client_op_id): duplicate, y no se aplica de nuevo.
select pg_temp.actuar_como(pg_temp.u('b2'));
create temp table lote_3 on commit drop as
select sync.push(jsonb_build_array(
  pg_temp.job('espacio_persona', 'update',
              jsonb_build_object('id', pg_temp.u('31'), 'ubicacion_cobranza_alt_id', pg_temp.u('03')), 0,
              pg_temp.u('a1'))
)) as r;
select is((select pg_temp.resultados(r) from lote_3), array['duplicate'], 'el mismo trabajo reintentado vuelve duplicate');
select pg_temp.actuar_como_servidor();
select is((select ubicacion_cobranza_alt_id from public.espacio_persona where id = pg_temp.u('21')), pg_temp.u('04'),
          'y no se aplicó otra vez');

-- Una segunda edición del mismo id (otro trabajo, ya en la cola) no choca con la primera.
select pg_temp.actuar_como(pg_temp.u('b2'));
create temp table lote_4 on commit drop as
select sync.push(jsonb_build_array(
  pg_temp.job('espacio_persona', 'update',
              jsonb_build_object('id', pg_temp.u('31'), 'ubicacion_cobranza_alt_id', pg_temp.u('03')), 0),
  pg_temp.job('espacio_persona', 'update',
              jsonb_build_object('id', pg_temp.u('31'), 'ubicacion_cobranza_alt_id', pg_temp.u('04')), 0)
)) as r;
select is((select pg_temp.resultados(r) from lote_4), array['accepted', 'accepted'], 'dos ediciones seguidas del mismo id juntado se aceptan');
select pg_temp.actuar_como_servidor();
select is((select ubicacion_cobranza_alt_id from public.espacio_persona where id = pg_temp.u('21')), pg_temp.u('04'),
          'gana la última');

-- Un update sin la cobranza alternativa (solo ids, o deleted_at) no toca nada, y no da de baja al que quedó.
select pg_temp.actuar_como_servidor();
create temp table version_21_antes_vacio on commit drop as
select sync_version as v from public.espacio_persona where id = pg_temp.u('21');
select pg_temp.actuar_como(pg_temp.u('b2'));
create temp table lote_5 on commit drop as
select sync.push(jsonb_build_array(
  pg_temp.job('espacio_persona', 'update',
              jsonb_build_object('id', pg_temp.u('31'), 'espacio_id', pg_temp.u('13'), 'deleted_at', now()), 0)
)) as r;
select is((select pg_temp.resultados(r) from lote_5), array['accepted'], 'un update que no trae la cobranza alternativa se acepta');
select pg_temp.actuar_como_servidor();
select is((select sync_version from public.espacio_persona where id = pg_temp.u('21')), (select v from version_21_antes_vacio),
          'sin tocar el vínculo que quedó (misma versión)');
select is((select deleted_at from public.espacio_persona where id = pg_temp.u('21')), null, 'ni darlo de baja');
select is((select espacio_id from public.espacio_persona where id = pg_temp.u('21')), pg_temp.u('11'), 'ni mudarlo');

-- ---------------------------------------------------------------------------
-- 3. Conflicto: Luis cambió el 21 después de la unión; el update de Ana vuelve conflict y no pisa nada
-- ---------------------------------------------------------------------------
select pg_temp.actuar_como(pg_temp.u('b1'));
update public.espacio_persona set ubicacion_cobranza_alt_id = pg_temp.u('03') where id = pg_temp.u('21');
select pg_temp.actuar_como(pg_temp.u('b2'));
create temp table lote_6 on commit drop as
select sync.push(jsonb_build_array(
  pg_temp.job('espacio_persona', 'update',
              jsonb_build_object('id', pg_temp.u('31'), 'ubicacion_cobranza_alt_id', pg_temp.u('04')), 0, pg_temp.u('a6'))
)) as r;
select is((select pg_temp.resultados(r) from lote_6), array['conflict'], 'el que quedó cambió: el update vuelve conflict');
select is((select r -> 'results' -> 0 -> 'server_row' ->> 'id' from lote_6), pg_temp.u('21')::text, 'con la fila del que quedó (21)');
select is((select r -> 'results' -> 0 -> 'server_row' ->> 'ubicacion_cobranza_alt_id' from lote_6), pg_temp.u('03')::text,
          'tal como la dejó Luis');
select is((select (r -> 'results' -> 0 ->> 'sync_version')::bigint from lote_6),
          (r -> 'results' -> 0 -> 'server_row' ->> 'sync_version')::bigint, 'y su sync_version')
  from lote_6;
select pg_temp.actuar_como_servidor();
select is((select ubicacion_cobranza_alt_id from public.espacio_persona where id = pg_temp.u('21')), pg_temp.u('03'),
          'el cambio de Luis sigue: nada se pisó');
select is((select count(*) from sync.op_cache where client_op_id = pg_temp.u('a6')), 0::bigint, 'el conflicto no entra al caché de client_op_id');

-- ---------------------------------------------------------------------------
-- 4. Delete: se acepta sin dar de baja al que quedó (aunque haya cambiado)
-- ---------------------------------------------------------------------------
select pg_temp.actuar_como(pg_temp.u('b2'));
create temp table lote_7 on commit drop as
select sync.push(jsonb_build_array(
  pg_temp.job('espacio_persona', 'delete', jsonb_build_object('id', pg_temp.u('31')), 0, pg_temp.u('a7')),
  pg_temp.job('espacio_persona', 'delete', jsonb_build_object('id', pg_temp.u('32')), 0, pg_temp.u('a8'))
)) as r;
select is((select pg_temp.resultados(r) from lote_7), array['accepted', 'accepted'], 'los deletes de los dos ids juntados se aceptan');
select pg_temp.actuar_como_servidor();
select is((select deleted_at from public.espacio_persona where id = pg_temp.u('21')), null, 'el 21 sigue vivo');
select is((select deleted_at from public.espacio_persona where id = pg_temp.u('24')), null, 'y el 24 también');
select is((select (r -> 'results' -> 0 ->> 'sync_version')::bigint from lote_7),
          (select sync_version from public.espacio_persona where id = pg_temp.u('21')),
          'la respuesta trae la sync_version del que quedó, sin cambios');
select pg_temp.actuar_como(pg_temp.u('b2'));
create temp table lote_8 on commit drop as
select sync.push(jsonb_build_array(
  pg_temp.job('espacio_persona', 'delete', jsonb_build_object('id', pg_temp.u('31')), 0, pg_temp.u('a7'))
)) as r;
select is((select pg_temp.resultados(r) from lote_8), array['duplicate'], 'el mismo delete reintentado vuelve duplicate');

-- ---------------------------------------------------------------------------
-- 5. Una unión anterior a 0123 (sin versión): el update vuelve conflict; ante la duda se bloquea
-- ---------------------------------------------------------------------------
select pg_temp.actuar_como_servidor();
update public.espacio_persona_union set destino_version = null where duplicada_id = pg_temp.u('32');
select pg_temp.actuar_como(pg_temp.u('b2'));
create temp table lote_9 on commit drop as
select sync.push(jsonb_build_array(
  pg_temp.job('espacio_persona', 'update',
              jsonb_build_object('id', pg_temp.u('32'), 'ubicacion_cobranza_alt_id', pg_temp.u('04')), 0)
)) as r;
select is((select pg_temp.resultados(r) from lote_9), array['conflict'], 'sin la versión de la unión: conflict');
select is((select r -> 'results' -> 0 -> 'server_row' ->> 'id' from lote_9), pg_temp.u('24')::text, 'con la fila del que quedó (24)');
select pg_temp.actuar_como_servidor();
select is((select ubicacion_cobranza_alt_id from public.espacio_persona where id = pg_temp.u('24')), null, 'y el 24 no cambió');

-- ---------------------------------------------------------------------------
-- 6. Solo quien subió el vínculo; y un id que nunca existió sigue en FILA_INEXISTENTE
-- ---------------------------------------------------------------------------
select pg_temp.actuar_como(pg_temp.u('b1'));
create temp table lote_10 on commit drop as
select sync.push(jsonb_build_array(
  pg_temp.job('espacio_persona', 'update',
              jsonb_build_object('id', pg_temp.u('31'), 'ubicacion_cobranza_alt_id', pg_temp.u('04')), 0),
  pg_temp.job('espacio_persona', 'delete', jsonb_build_object('id', pg_temp.u('31')), 0),
  pg_temp.job('espacio_persona', 'update',
              jsonb_build_object('id', pg_temp.u('99'), 'ubicacion_cobranza_alt_id', pg_temp.u('04')), 0)
)) as r;
select is((select pg_temp.resultados(r) from lote_10), array['invalid FILA_INEXISTENTE', 'invalid FILA_INEXISTENTE', 'invalid FILA_INEXISTENTE'],
          'Luis no subió el 31: para él no existe, igual que un id que nunca existió');
select pg_temp.actuar_como_servidor();
select is((select ubicacion_cobranza_alt_id from public.espacio_persona where id = pg_temp.u('21')), pg_temp.u('03'),
          'y no tocó el 21');

-- ---------------------------------------------------------------------------
-- 7. La cadena: A se une después a C y el 21 se funde en el 23; el update de Ana ya no es sobre el 21
-- ---------------------------------------------------------------------------
select pg_temp.actuar_como(pg_temp.u('b1'));
select is(public.marcar_como_duplicado(pg_temp.u('01'), pg_temp.u('03')) ->> 'ya_unida', 'false', 'Luis une A (01) a C (03)');
select pg_temp.actuar_como(pg_temp.u('b2'));
create temp table lote_11 on commit drop as
select sync.push(jsonb_build_array(
  pg_temp.job('espacio_persona', 'update',
              jsonb_build_object('id', pg_temp.u('31'), 'ubicacion_cobranza_alt_id', pg_temp.u('04')), 0)
)) as r;
select is((select pg_temp.resultados(r) from lote_11), array['conflict'], 'el que quedó se fundió en otro: conflict, no se escribe en el viejo');
select is((select r -> 'results' -> 0 -> 'server_row' ->> 'id' from lote_11), pg_temp.u('23')::text, 'con la fila del vínculo de hoy (23)');
select pg_temp.actuar_como(pg_temp.u('b2'));
create temp table lote_12 on commit drop as
select sync.push(jsonb_build_array(
  pg_temp.job('espacio_persona', 'delete', jsonb_build_object('id', pg_temp.u('31')), 0)
)) as r;
select is((select pg_temp.resultados(r) from lote_12), array['accepted'], 'el delete sigue aceptándose');
select pg_temp.actuar_como_servidor();
select is((select deleted_at from public.espacio_persona where id = pg_temp.u('23')), null, 'sin dar de baja el 23');

-- ---------------------------------------------------------------------------
-- 8. Privilegios de la función nueva
-- ---------------------------------------------------------------------------
select is(has_function_privilege('anon', 'public.aplicar_a_vinculo_juntado(uuid, text, jsonb)', 'execute')::text, 'false', 'anon no la ejecuta');
select is(has_function_privilege('authenticated', 'public.aplicar_a_vinculo_juntado(uuid, text, jsonb)', 'execute')::text, 'true', 'authenticated sí (la llama el push)');
select is((select count(*) from aclexplode((select proacl from pg_proc where oid = 'public.aplicar_a_vinculo_juntado(uuid, text, jsonb)'::regprocedure)) a
            where a.grantee = 0), 0::bigint, 'PUBLIC tampoco');

select * from finish();
rollback;
