-- pgTAP · migración 0101 (backend-supabase#70; decisión de Cristian del 06/10, «Duplicado»: «Se encola y
-- sube después»): sync_push aplica el trabajo «marcar como duplicado» como marcar_como_duplicado(B, A).
--   1. El trabajo aplicado: `accepted` con destino_id y sync_version de B; B de baja, la unión
--      registrada y lo de B en A; el reintento del mismo client_op_id es `duplicate`.
--   2. Idempotente: otro client_op_id sobre el mismo par, el sentido contrario y la cadena A → C dan
--      `duplicate` con ya_unida y el destino de hoy.
--   3. Su lugar en el lote: lo que el teléfono subió de B antes pasa a A, y lo que sube después también.
--   4. Los rechazos vuelven `invalid` por trabajo y el lote sigue: UB003, UB004, 42501, CG001,
--      FILA_INEXISTENTE, PK_FALTANTE, OP_INVALIDA y un id que no es uuid. Rechazado no cambia nada.
--   5. Si B es un alta en conflicto del mismo lote, la unión queda en espera (0017).
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
  select ('01920000-0000-7000-8000-0000000101' || p)::uuid;
$$;
create or replace function pg_temp.job(p_ent text, p_op text, p_payload jsonb) returns jsonb language sql as $$
  select jsonb_build_object('client_op_id', gen_random_uuid(), 'entity', p_ent, 'op', p_op, 'payload', p_payload);
$$;
-- El trabajo «marcar como duplicado»: B (duplicada) y A (conservada), por sufijo.
create or replace function pg_temp.unir(p_b text, p_a text) returns jsonb language sql as $$
  select pg_temp.job('ubicacion', 'marcar_como_duplicado',
                     jsonb_build_object('duplicada_id', pg_temp.u(p_b), 'conservada_id', pg_temp.u(p_a)));
$$;
create or replace function pg_temp.resultados(p_r jsonb) returns text[] language sql as $$
  select array_agg((e ->> 'outcome') || coalesce(' ' || (e ->> 'code'), '') order by i)
    from jsonb_array_elements(p_r -> 'results') with ordinality x(e, i);
$$;
-- Foto de todo lo que toca la unión: dos fotos iguales = no se tocó nada.
create or replace function pg_temp.foto() returns text language sql as $$
  select md5(string_agg(x, ',' order by x)) from (
    select 'u' || id::text || sync_version::text || coalesce(deleted_at::text, '') x from public.ubicacion
    union all select 'e' || id::text || ubicacion_id::text || sync_version::text || coalesce(deleted_at::text, '') from public.espacio
    union all select 'p' || id::text || espacio_id::text || sync_version::text || coalesce(deleted_at::text, '') from public.espacio_persona
    union all select 'U' || id::text from public.ubicacion_union
    union all select 'E' || id::text from public.espacio_union
  ) f;
$$;

-- --- fixtures (como postgres) --------------------------------------------------
-- Ids (prefijo 0101): usuarios b1 b2 b3 (b3 sin campaña); ubicaciones 01..1f, todas CASA de b1 con un
-- espacio único (espacio = ubicación + 0x40: 01 -> 41); lo que sube tarde, a0...
insert into auth.users (id, instance_id, aud, role, email, encrypted_password, confirmed_at, created_at, updated_at)
select pg_temp.u(s), '00000000-0000-0000-0000-000000000000',
       'authenticated', 'authenticated', 'union100-' || s || '@example.com', 'x', now(), now(), now()
  from unnest(array['b1','b2','b3']) s;
insert into public.pais (id, nombre, iso_code) values (pg_temp.u('f0'), 'Pais union100', 'ZU');
insert into public.ciudad (id, nombre, departamento, pais_id, lat_centro, lon_centro)
values (pg_temp.u('f1'), 'Ciudad union100', 'Departamento de prueba', pg_temp.u('f0'), -34.9, -56.2);
insert into public.campania (id, nombre, tipo, fecha_inicio, fecha_fin)
values (pg_temp.u('f3'), 'Verano union100', 'VERANO', public.hoy_montevideo() - 10, public.hoy_montevideo() + 30);
insert into public.campania_ciudad (id, campania_id, ciudad_id) values (pg_temp.u('f5'), pg_temp.u('f3'), pg_temp.u('f1'));
insert into public.campania_colportor (campania_id, usuario_id, zona_id) values
  (pg_temp.u('f3'), pg_temp.u('b1'), null), (pg_temp.u('f3'), pg_temp.u('b2'), null);
insert into public.ubicacion (id, tipo, calle, numero, lat, lon, ciudad_id, created_by)
select pg_temp.u(lpad(to_hex(n), 2, '0')), 'CASA', 'Union ' || n, n::text, -34.9 - n * 0.01, -56.2, pg_temp.u('f1'), pg_temp.u('b1')
  from generate_series(1, 31) n;
insert into public.espacio (id, ubicacion_id, numero_depto, created_by)
select pg_temp.u(lpad(to_hex(n + 64), 2, '0')), pg_temp.u(lpad(to_hex(n), 2, '0')), null, pg_temp.u('b1')
  from generate_series(1, 31) n;

-- ---------------------------------------------------------------------------
-- 1. El trabajo aplicado
-- ---------------------------------------------------------------------------
select pg_temp.actuar_como(pg_temp.u('b1'));
create temp table op_1 as select pg_temp.unir('02', '01') j;
create temp table lote_1 on commit drop as
select sync.push(jsonb_build_array((select j from op_1))) as r;
select is((select pg_temp.resultados(r) from lote_1), array['accepted'], 'B (02) se une a A (01): accepted');
select is((select r -> 'results' -> 0 ->> 'ya_unida' from lote_1), 'false', 'ya_unida es false: se aplicó');
select is((select r -> 'results' -> 0 ->> 'destino_id' from lote_1), pg_temp.u('01')::text, 'destino_id es A');
select is((select r -> 'results' -> 0 ->> 'client_op_id' from lote_1), (select j ->> 'client_op_id' from op_1),
          'y devuelve el client_op_id del trabajo');
select pg_temp.actuar_como_servidor();
select is((select (r -> 'results' -> 0 ->> 'sync_version')::bigint from lote_1),
          (select sync_version from public.ubicacion where id = pg_temp.u('02')),
          'sync_version es la de B tras la baja');
select isnt((select deleted_at from public.ubicacion where id = pg_temp.u('02')), null, 'B quedó de baja');
select is((select count(*) from public.ubicacion_union where duplicada_id = pg_temp.u('02') and conservada_id = pg_temp.u('01')),
          1::bigint, 'la unión quedó registrada');
select is((select deleted_at is not null from public.espacio where id = pg_temp.u('42')), true,
          'el espacio único de B se fundió en el de A: de baja');
select is((select count(*) from sync.op_cache where client_op_id = (select (j ->> 'client_op_id')::uuid from op_1)),
          1::bigint, 'el trabajo entró al cache de client_op_id');

-- El reintento del mismo trabajo: duplicate, y no toca nada.
create temp table foto_1 as select pg_temp.foto() f;
select pg_temp.actuar_como(pg_temp.u('b1'));
create temp table lote_1b on commit drop as
select sync.push(jsonb_build_array((select j from op_1))) as r;
select is((select pg_temp.resultados(r) from lote_1b), array['duplicate'], 'el reintento del mismo client_op_id: duplicate');
select pg_temp.actuar_como_servidor();
select is(pg_temp.foto(), (select f from foto_1), 'y no cambia nada');

-- ---------------------------------------------------------------------------
-- 2. Idempotente: otro client_op_id sobre el mismo par, el sentido contrario y la cadena
-- ---------------------------------------------------------------------------
select pg_temp.actuar_como(pg_temp.u('b1'));
create temp table lote_2 on commit drop as
select sync.push(jsonb_build_array(pg_temp.unir('02', '01'), pg_temp.unir('01', '02'))) as r;
select is((select pg_temp.resultados(r) from lote_2), array['duplicate', 'duplicate'],
          'el mismo par con otro client_op_id, y el sentido contrario (A duplicada de B): duplicate');
select is((select r -> 'results' -> 0 ->> 'ya_unida' from lote_2), 'true', 'ya_unida es true');
select is((select r -> 'results' -> 1 ->> 'ya_unida' from lote_2), 'true', 'también en el sentido contrario');

-- A se une a C; después llega la unión de B a A: B ya estaba unida, y el destino de hoy es C.
create temp table lote_2b on commit drop as
select sync.push(jsonb_build_array(pg_temp.unir('01', '03'), pg_temp.unir('02', '01'))) as r;
select is((select pg_temp.resultados(r) from lote_2b), array['accepted', 'duplicate'], 'A se une a C; B (ya unida) otra vez: duplicate');
select is((select r -> 'results' -> 0 ->> 'destino_id' from lote_2b), pg_temp.u('03')::text, 'A → C: destino_id es C');
select is((select r -> 'results' -> 1 ->> 'destino_id' from lote_2b), pg_temp.u('03')::text,
          'y B, que ya estaba unida, ahora va a C (la cadena)');

-- ---------------------------------------------------------------------------
-- 3. Su lugar en el lote: lo de B que subió antes pasa a A; lo que sube después, también
-- ---------------------------------------------------------------------------
select pg_temp.actuar_como(pg_temp.u('b1'));
create temp table lote_3 on commit drop as
select sync.push(jsonb_build_array(
  pg_temp.job('espacio_persona', 'insert', jsonb_build_object('id', pg_temp.u('a1'), 'espacio_id', pg_temp.u('45'),
              'persona_id', pg_temp.u('b4'))),
  pg_temp.unir('05', '06'),
  pg_temp.job('espacio_persona', 'insert', jsonb_build_object('id', pg_temp.u('a2'), 'espacio_id', pg_temp.u('45'),
              'persona_id', pg_temp.u('b5')))
)) as r;
select is((select pg_temp.resultados(r) from lote_3), array['accepted', 'accepted', 'accepted'],
          'un vínculo en B, la unión de B a A y otro vínculo en B después: los tres entran');
select pg_temp.actuar_como_servidor();
select is((select espacio_id from public.espacio_persona where id = pg_temp.u('a1')), pg_temp.u('46'),
          'el vínculo que subió antes de la unión terminó en el espacio de A');
select is((select espacio_id from public.espacio_persona where id = pg_temp.u('a2')), pg_temp.u('46'),
          'el que subió después, nombrando el espacio de B, también');

-- ---------------------------------------------------------------------------
-- 4. Los rechazos: invalid por trabajo y el lote sigue
-- ---------------------------------------------------------------------------
-- UB004 (B = A), una unión buena y la misma otra vez, en un mismo lote.
select pg_temp.actuar_como(pg_temp.u('b1'));
create temp table lote_4 on commit drop as
select sync.push(jsonb_build_array(pg_temp.unir('07', '07'), pg_temp.unir('08', '09'), pg_temp.unir('08', '09'))) as r;
select is((select pg_temp.resultados(r) from lote_4), array['invalid UB004', 'accepted', 'duplicate'],
          'B = A es invalid UB004 y no tumba el lote: la unión que sigue entra');
select pg_temp.actuar_como_servidor();
select is((select deleted_at from public.ubicacion where id = pg_temp.u('07')), null, 'la 07 sigue viva');

-- UB003: A está de baja.
update public.ubicacion set deleted_at = now() where id = pg_temp.u('0b');
create temp table foto_4 as select pg_temp.foto() f;
select pg_temp.actuar_como(pg_temp.u('b1'));
create temp table lote_4b on commit drop as
select sync.push(jsonb_build_array(pg_temp.unir('0a', '0b'), pg_temp.unir('0c', '0d'))) as r;
select is((select pg_temp.resultados(r) from lote_4b), array['invalid UB003', 'accepted'],
          'A de baja: invalid UB003; la siguiente entra');
select pg_temp.actuar_como_servidor();
select is((select deleted_at from public.ubicacion where id = pg_temp.u('0a')), null, 'B (0a) sigue viva con lo suyo');
select is((select deleted_at is null from public.espacio where id = pg_temp.u('4a')), true, 'y su espacio también');

-- 42501: quien no escribe en las dos (b3, sin campaña) y una ubicación que no existe para quien no escribe.
select pg_temp.actuar_como(pg_temp.u('b3'));
create temp table lote_4c on commit drop as
select sync.push(jsonb_build_array(pg_temp.unir('0e', '0f'),
       pg_temp.job('ubicacion', 'marcar_como_duplicado',
                   jsonb_build_object('duplicada_id', gen_random_uuid(), 'conservada_id', pg_temp.u('0f'))))) as r;
select is((select pg_temp.resultados(r) from lote_4c), array['invalid 42501', 'invalid 42501'],
          'b3 no escribe en el par, y una B que no existe es lo mismo: invalid 42501');
select pg_temp.actuar_como_servidor();
select is((select deleted_at from public.ubicacion where id = pg_temp.u('0e')), null, 'nada se dio de baja');

-- FILA_INEXISTENTE: sin usuario (el servidor) la RPC levanta P0002.
select is((sync.aplicar_job(pg_temp.job('ubicacion', 'marcar_como_duplicado',
             jsonb_build_object('duplicada_id', gen_random_uuid(), 'conservada_id', pg_temp.u('0f')))) ->> 'code'),
          'FILA_INEXISTENTE', 'sin usuario, una ubicación que no existe: invalid FILA_INEXISTENTE y no una excepción');

-- PK_FALTANTE, OP_INVALIDA, un id que no es uuid y un payload que no es un objeto.
select pg_temp.actuar_como(pg_temp.u('b1'));
create temp table lote_4d on commit drop as
select sync.push(jsonb_build_array(
  pg_temp.job('ubicacion', 'marcar_como_duplicado', jsonb_build_object('duplicada_id', pg_temp.u('10'))),
  pg_temp.job('ubicacion', 'marcar_como_duplicado', jsonb_build_object('conservada_id', pg_temp.u('11'))),
  pg_temp.job('ubicacion', 'marcar_como_duplicado', '{}'::jsonb),
  pg_temp.job('espacio', 'marcar_como_duplicado', jsonb_build_object('duplicada_id', pg_temp.u('10'), 'conservada_id', pg_temp.u('11'))),
  pg_temp.job('ubicacion', 'marcar_como_duplicado', jsonb_build_object('duplicada_id', 'no-es-un-uuid', 'conservada_id', pg_temp.u('11'))),
  pg_temp.job('ubicacion', 'marcar_como_duplicado', to_jsonb('texto'::text)),
  pg_temp.unir('10', '11')
)) as r;
select is((select pg_temp.resultados(r) from lote_4d),
          array['invalid PK_FALTANTE', 'invalid PK_FALTANTE', 'invalid PK_FALTANTE', 'invalid OP_INVALIDA',
                'invalid 22P02', 'invalid PK_FALTANTE', 'accepted'],
          'faltan ids, otra entidad, un id que no es uuid, un payload que no es objeto: invalid cada uno, y la última entra');
select pg_temp.actuar_como_servidor();
select is((select count(*) from public.ubicacion_union where duplicada_id = pg_temp.u('10')), 1::bigint, 'y solo entró la buena');

-- Sin client_op_id: OP_ID_REQUERIDO, como todo job.
select pg_temp.actuar_como(pg_temp.u('b1'));
select is((sync.push(jsonb_build_array(jsonb_build_object('entity', 'ubicacion', 'op', 'marcar_como_duplicado',
             'payload', jsonb_build_object('duplicada_id', pg_temp.u('12'), 'conservada_id', pg_temp.u('13'))))) -> 'results' -> 0 ->> 'code'),
          'OP_ID_REQUERIDO', 'sin client_op_id: invalid OP_ID_REQUERIDO');
select pg_temp.actuar_como_servidor();
select is((select deleted_at from public.ubicacion where id = pg_temp.u('12')), null, 'y no se unió nada');

-- ---------------------------------------------------------------------------
-- 5. CG001: en la gracia, B tiene un espacio que cargó otro (b2)
-- ---------------------------------------------------------------------------
update public.campania set fecha_inicio = public.hoy_montevideo() - 60, fecha_fin = public.hoy_montevideo() - 5
 where id = pg_temp.u('f3');
insert into public.espacio (id, ubicacion_id, numero_depto, created_by, created_at)
values (pg_temp.u('d1'), pg_temp.u('14'), '1', pg_temp.u('b2'), now());
create temp table foto_5 as select pg_temp.foto() f;
select pg_temp.actuar_como(pg_temp.u('b1'));
create temp table lote_5 on commit drop as
select sync.push(jsonb_build_array(pg_temp.unir('14', '15'))) as r;
select is((select pg_temp.resultados(r) from lote_5), array['invalid CG001'], 'en la gracia, lo ajeno no se corrige: invalid CG001');
select pg_temp.actuar_como_servidor();
select is(pg_temp.foto(), (select f from foto_5), 'y no cambia nada: B sigue viva con todo');

-- ---------------------------------------------------------------------------
-- 6. B es un alta en conflicto del mismo lote: la unión queda en espera (0017)
-- ---------------------------------------------------------------------------
update public.campania set fecha_inicio = public.hoy_montevideo() - 10, fecha_fin = public.hoy_montevideo() + 30
 where id = pg_temp.u('f3');
select pg_temp.actuar_como(pg_temp.u('b1'));
create temp table lote_6 on commit drop as
select sync.push(jsonb_build_array(
  pg_temp.job('ubicacion', 'insert', jsonb_build_object('id', pg_temp.u('e0'), 'tipo', 'CASA', 'calle', 'Union 18',
              'numero', '18', 'lat', -34.9 - 18 * 0.01, 'lon', -56.2, 'ciudad_id', pg_temp.u('f1'))),
  pg_temp.unir('e0', '13')
)) as r;
select is((select pg_temp.resultados(r) from lote_6), array['conflict 23505', 'conflict ESPERA_ALTA_EN_CONFLICTO'],
          'la dirección de B ya existe (D1): el alta queda en conflicto y la unión espera, sin tumbar nada');
select pg_temp.actuar_como_servidor();
select is((select count(*) from public.ubicacion_union where duplicada_id = pg_temp.u('e0')), 0::bigint, 'no se registró ninguna unión');

select * from finish();
rollback;
