-- pgTAP · migración 0107 (backend-supabase#150, seguimiento de #132): la cita de la agenda sigue a su
-- vínculo cuando cambia de espacio, como la visita (0069), y una cita con persona inexistente da 23503.
--   1. La forma: el trigger hermano y sus privilegios.
--   2. Un vínculo que cambia de espacio se lleva sus citas (de todos los colportores, con o sin
--      resultado, también las dadas de baja); no toca las de otro vínculo ni las que no tienen persona, y
--      no se pierde ninguna.
--   3. Una cita con persona inexistente: 23503 con y sin espacio; con persona que existe, el espacio es
--      el de su vínculo.
--   4. Por sync_push: una cita que cuelga de un alta en conflicto queda en espera (0017); una con un
--      vínculo que no existe y no está en espera es invalid 23503.
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
  select ('01920000-0000-7000-8000-0000000107' || p)::uuid;
$$;
-- El id de una cita (n hasta 65535, sin chocar con u()).
create or replace function pg_temp.ua(p_n integer) returns uuid language sql as $$
  select ('01920000-0000-7000-8000-00000107' || lpad(to_hex(p_n), 4, '0'))::uuid;
$$;
-- Una cita tal como la inserta el teléfono: 'ok' o el SQLSTATE. Pasar null en el espacio lo quita.
create or replace function pg_temp.ins(
  p_id integer, p_persona text, p_espacio text default null, p_quien text default 'b1')
returns text language plpgsql as $$
begin
  insert into public.agenda (id, espacio_persona_id, espacio_id, tipo, fecha_programada, colportor_id)
  values (pg_temp.ua(p_id), pg_temp.u(p_persona), pg_temp.u(p_espacio), 'ENTREVISTA',
          now() + interval '1 day', pg_temp.u(p_quien));
  return 'ok';
exception when others then
  return sqlstate;
end $$;
create or replace function pg_temp.espacio_de(p_id integer) returns uuid language sql as $$
  select espacio_id from public.agenda where id = pg_temp.ua(p_id);
$$;

-- --- fixtures (como postgres) --------------------------------------------------
-- b1, b3 y b2 son colportores; b1 y b3 están en la campaña e1 de la ciudad c1, b2 en la e2 de la ciudad
-- c2 (no ve lo de c1). Ubicaciones de b1: 01 (casa, espacio único 11), 02 (casa, espacio único 12),
-- 03 (edificio, depto 13). Vínculos: 21 (a1 en 11), 22 (a2 en 11), 23 (a3 en 13).
insert into auth.users (id, instance_id, aud, role, email, encrypted_password, confirmed_at, created_at, updated_at)
select pg_temp.u(s), '00000000-0000-0000-0000-000000000000',
       'authenticated', 'authenticated', 'agenda107-' || s || '@example.com', 'x', now(), now(), now()
  from unnest(array['b1','b2','b3']) s;
insert into public.pais (id, nombre, iso_code) values (pg_temp.u('c0'), 'Pais agenda 107', 'ZB');
insert into public.ciudad (id, nombre, departamento, pais_id, lat_centro, lon_centro) values
  (pg_temp.u('c1'), 'Ciudad agenda 107', 'Departamento de prueba', pg_temp.u('c0'), -34.9, -56.2),
  (pg_temp.u('c2'), 'Otra ciudad 107',   'Departamento de prueba', pg_temp.u('c0'), -34.9, -56.2);
insert into public.campania (id, nombre, tipo, fecha_inicio, fecha_fin) values
  (pg_temp.u('e1'), 'Verano 107', 'VERANO', public.hoy_montevideo() - 10, public.hoy_montevideo() + 30),
  (pg_temp.u('e2'), 'Otoño 107',  'VERANO', public.hoy_montevideo() - 10, public.hoy_montevideo() + 30);
insert into public.campania_ciudad (id, campania_id, ciudad_id) values
  (pg_temp.u('f1'), pg_temp.u('e1'), pg_temp.u('c1')),
  (pg_temp.u('f2'), pg_temp.u('e2'), pg_temp.u('c2'));
insert into public.campania_colportor (campania_id, usuario_id, zona_id) values
  (pg_temp.u('e1'), pg_temp.u('b1'), null),
  (pg_temp.u('e1'), pg_temp.u('b3'), null),
  (pg_temp.u('e2'), pg_temp.u('b2'), null);
insert into public.ubicacion (id, tipo, calle, numero, lat, lon, ciudad_id, created_by) values
  (pg_temp.u('01'), 'CASA',     'Agenda 107 uno',  '1', -34.91, -56.2, pg_temp.u('c1'), pg_temp.u('b1')),
  (pg_temp.u('02'), 'CASA',     'Agenda 107 dos',  '2', -34.92, -56.2, pg_temp.u('c1'), pg_temp.u('b1')),
  (pg_temp.u('03'), 'EDIFICIO', 'Agenda 107 tres', '3', -34.93, -56.2, pg_temp.u('c1'), pg_temp.u('b1'));
insert into public.espacio (id, ubicacion_id, numero_depto, created_by) values
  (pg_temp.u('11'), pg_temp.u('01'), null, pg_temp.u('b1')),
  (pg_temp.u('12'), pg_temp.u('02'), null, pg_temp.u('b1')),
  (pg_temp.u('13'), pg_temp.u('03'), '1',  pg_temp.u('b1'));
insert into public.espacio_persona (id, espacio_id, persona_id, created_by) values
  (pg_temp.u('21'), pg_temp.u('11'), pg_temp.u('a1'), pg_temp.u('b1')),
  (pg_temp.u('22'), pg_temp.u('11'), pg_temp.u('a2'), pg_temp.u('b1')),
  (pg_temp.u('23'), pg_temp.u('13'), pg_temp.u('a3'), pg_temp.u('b1'));
-- Las citas del vínculo 21 (de b1 y de b3, una cumplida y una dada de baja), una del vínculo 22 y una sin
-- persona en el espacio 11.
insert into public.agenda (id, espacio_persona_id, espacio_id, tipo, fecha_programada, estado, colportor_id, deleted_at) values
  (pg_temp.ua(1), pg_temp.u('21'), pg_temp.u('11'), 'ENTREVISTA', now(), 'PROGRAMADA', pg_temp.u('b1'), null),
  (pg_temp.ua(2), pg_temp.u('21'), pg_temp.u('11'), 'ENTREVISTA', now(), 'PROGRAMADA', pg_temp.u('b3'), null),
  (pg_temp.ua(3), pg_temp.u('21'), pg_temp.u('11'), 'ENTREVISTA', now(), 'CUMPLIDA',   pg_temp.u('b1'), null),
  (pg_temp.ua(4), pg_temp.u('21'), pg_temp.u('11'), 'ENTREVISTA', now(), 'CANCELADA',  pg_temp.u('b1'), now()),
  (pg_temp.ua(5), pg_temp.u('22'), pg_temp.u('11'), 'ENTREVISTA', now(), 'PROGRAMADA', pg_temp.u('b1'), null),
  (pg_temp.ua(6), null,            pg_temp.u('11'), 'ENTREVISTA', now(), 'PROGRAMADA', pg_temp.u('b1'), null);

-- ---------------------------------------------------------------------------
-- 1. La forma
-- ---------------------------------------------------------------------------
select has_trigger('public', 'espacio_persona', 'espacio_persona_mueve_agendas',
                   'un vínculo que cambia de espacio se lleva sus citas');
select has_trigger('public', 'espacio_persona', 'espacio_persona_mueve_visitas',
                   'y el de las visitas (0069) sigue');
select ok((select prosecdef from pg_proc where oid = 'public.tg_espacio_persona_mueve_agendas()'::regprocedure)
          and (select proconfig::text from pg_proc where oid = 'public.tg_espacio_persona_mueve_agendas()'::regprocedure)
              like '%search_path=%',
          'el trigger es SECURITY DEFINER con search_path fijo: mueve también las citas de los demás');
select ok(not has_function_privilege('authenticated', 'public.tg_espacio_persona_mueve_agendas()', 'execute')
          and not has_function_privilege('anon', 'public.tg_espacio_persona_mueve_agendas()', 'execute'),
          'y nadie lo ejecuta desde afuera');
select ok((select prosecdef from pg_proc where oid = 'public.tg_agenda_union_redirige()'::regprocedure),
          'tg_agenda_union_redirige() sigue siendo SECURITY DEFINER');
select is((select array_agg(tgname::text order by tgname::text collate "C") from pg_trigger
            where tgrelid = 'public.agenda'::regclass and not tgisinternal and (tgtype & 4) = 4),
          array['agenda_0_union_redirige', 'agenda_1_origen', 'agenda_auditoria_insert'],
          'al insertar corren, en el mismo orden de siempre, la unión, el origen y la auditoría');

-- ---------------------------------------------------------------------------
-- 2. Un vínculo que cambia de espacio se lleva sus citas
-- ---------------------------------------------------------------------------
create temp table antes on commit drop as
  select id, sync_version from public.agenda;

-- Otra columna del vínculo no mueve nada.
update public.espacio_persona set deleted_at = null, ubicacion_cobranza_alt_id = null where id = pg_temp.u('21');
select is((select count(*)::int from public.agenda a join antes using (id) where a.sync_version <> antes.sync_version),
          0, 'cambiar otra cosa del vínculo no toca ninguna cita');

-- El vínculo 21 se muda al espacio 12 (lo que hace la unión de dos casas).
update public.espacio_persona set espacio_id = pg_temp.u('12') where id = pg_temp.u('21');
select is(array(select id from public.agenda where espacio_id = pg_temp.u('12') order by id),
          array[pg_temp.ua(1), pg_temp.ua(2), pg_temp.ua(3), pg_temp.ua(4)],
          'sus cuatro citas (de b1 y de b3, la cumplida y la dada de baja) lo siguieron');
select is(pg_temp.espacio_de(5), pg_temp.u('11'), 'la cita de otro vínculo del mismo espacio no se mueve');
select is(pg_temp.espacio_de(6), pg_temp.u('11'), 'ni la que no tiene persona');
select is((select count(*)::int from public.agenda), 6, 'no se pierde ninguna cita');
select is((select estado from public.agenda where id = pg_temp.ua(3)), 'CUMPLIDA', 'ni se toca su estado');
select ok((select deleted_at is not null from public.agenda where id = pg_temp.ua(4)), 'ni lo dado de baja');
select is((select count(*)::int from public.agenda a join antes using (id)
            where a.sync_version > antes.sync_version), 4,
          'las cuatro citas que se mudaron suben su versión: el teléfono las baja con el pull');

-- Se muda de nuevo, esta vez a un depto, y la que acaba de moverse vuelve a seguirlo.
update public.espacio_persona set espacio_id = pg_temp.u('13') where id = pg_temp.u('21');
select is(pg_temp.espacio_de(1), pg_temp.u('13'), 'una segunda mudanza también la sigue');
select is(pg_temp.espacio_de(2), pg_temp.u('13'), 'la de otro colportor también');

-- Quien es dueño del vínculo lo muda y las citas de los demás lo siguen (DEFINER, sin pasar por su RLS).
select pg_temp.actuar_como(pg_temp.u('b1'));
select lives_ok($$ update public.espacio_persona set espacio_id = pg_temp.u('12') where id = pg_temp.u('21') $$,
                'b1 muda su vínculo');
select is(pg_temp.espacio_de(1), pg_temp.u('12'), 'su cita lo sigue');
select pg_temp.actuar_como_servidor();
select is(pg_temp.espacio_de(2), pg_temp.u('12'), 'y la de b3, que b1 no ve');
select is(pg_temp.espacio_de(5), pg_temp.u('11'), 'las de otros vínculos siguen donde estaban');

-- ---------------------------------------------------------------------------
-- 3. Una cita con persona inexistente: 23503
-- ---------------------------------------------------------------------------
select pg_temp.actuar_como(pg_temp.u('b1'));
select is(pg_temp.ins(10, 'ff'), '23503', 'un vínculo que no existe y sin espacio: 23503, no 23502');
select is(pg_temp.ins(11, 'ff', '11'), '23503', 'con espacio: 23503 también');
select is(pg_temp.ins(12, null, null), '23502', 'sin persona y sin espacio sigue siendo 23502 (el NOT NULL)');
select is(pg_temp.ins(13, null, '11'), 'ok', 'sin persona y con espacio entra');
select is(pg_temp.ins(14, '23'), 'ok', 'con un vínculo que existe y sin espacio entra');
select is(pg_temp.espacio_de(14), pg_temp.u('13'), 'y toma el espacio de su vínculo');
select is(pg_temp.ins(15, '23', '12'), 'ok', 'con un vínculo que existe y otro espacio entra');
select is(pg_temp.espacio_de(15), pg_temp.u('13'), 'pero el espacio es el de su vínculo');
select throws_ok($$ update public.agenda set espacio_persona_id = pg_temp.u('ff') where id = pg_temp.ua(1) $$,
                 '23503', null, 'pasar una cita a un vínculo que no existe da 23503');
select is(pg_temp.espacio_de(1), pg_temp.u('12'), 'y la cita no cambió');
select is((select count(*)::int from public.agenda where id in (pg_temp.ua(10), pg_temp.ua(11), pg_temp.ua(12))),
          0, 'ninguna de las rechazadas quedó');

-- ---------------------------------------------------------------------------
-- 4. Por sync_push: lo que cuelga de un alta en conflicto queda en espera
-- ---------------------------------------------------------------------------
-- b1 registra A (Av. Italia 100); b2 (inscripto solo en c2, no la ve) sube sin señal la misma casa a ~30 m,
-- con un depto, una persona y tres citas, todo en el mismo lote.
select pg_temp.actuar_como(pg_temp.u('b1'));
select is(sync.push(jsonb_build_array(jsonb_build_object(
            'client_op_id', pg_temp.u('d1'), 'entity', 'ubicacion', 'op', 'insert',
            'payload', jsonb_build_object('id', pg_temp.u('a9'), 'tipo', 'CASA', 'calle', 'Av. Italia', 'numero', '100',
                                          'lat', -34.90, 'lon', -56.20, 'ciudad_id', pg_temp.u('c1'))))) #>> '{results,0,outcome}',
          'accepted', 'b1 registra A (Av. Italia 100)');

create or replace function pg_temp.job(p_op text, p_entidad text, p_payload jsonb) returns jsonb language sql as $$
  select jsonb_build_object('client_op_id', pg_temp.u(p_op), 'entity', p_entidad, 'op', 'insert', 'payload', p_payload);
$$;
-- Un punto a ~30 m de A (en latitud: 0,00027 grados son ~30 m).
create or replace function pg_temp.lote() returns jsonb language sql as $$
  select jsonb_build_array(
    pg_temp.job('91', 'ubicacion', jsonb_build_object('id', pg_temp.u('d9'), 'tipo', 'CASA', 'calle', 'Av. Italia',
      'numero', '100', 'lat', -34.90027, 'lon', -56.20, 'ciudad_id', pg_temp.u('c1'))),
    pg_temp.job('92', 'espacio', jsonb_build_object('id', pg_temp.u('d8'), 'ubicacion_id', pg_temp.u('d9'),
      'numero_depto', '3B')),
    pg_temp.job('93', 'espacio_persona', jsonb_build_object('id', pg_temp.u('d7'),
      'espacio_id', pg_temp.u('d8'), 'persona_id', pg_temp.u('a4'))),
    -- La cita con persona, sin espacio (como la sube el teléfono): cuelga del vínculo d7.
    pg_temp.job('94', 'agenda', jsonb_build_object('id', pg_temp.ua(40), 'tipo', 'ENTREVISTA',
      'fecha_programada', now() + interval '1 day', 'espacio_persona_id', pg_temp.u('d7'))),
    -- La misma, con el espacio del depto en espera.
    pg_temp.job('95', 'agenda', jsonb_build_object('id', pg_temp.ua(41), 'tipo', 'ENTREVISTA',
      'fecha_programada', now() + interval '1 day', 'espacio_persona_id', pg_temp.u('d7'),
      'espacio_id', pg_temp.u('d8'))),
    -- La cita sin persona colgada del depto en espera.
    pg_temp.job('96', 'agenda', jsonb_build_object('id', pg_temp.ua(42), 'tipo', 'ENTREVISTA',
      'fecha_programada', now() + interval '1 day', 'espacio_id', pg_temp.u('d8'))),
    -- Un vínculo que no existe y no está en espera: invalid.
    pg_temp.job('97', 'agenda', jsonb_build_object('id', pg_temp.ua(43), 'tipo', 'ENTREVISTA',
      'fecha_programada', now() + interval '1 day', 'espacio_persona_id', pg_temp.u('ee'))));
$$;

select pg_temp.actuar_como(pg_temp.u('b2'));
create temp table lote_espera on commit drop as select sync.push(pg_temp.lote()) -> 'results' as r;

select is((select r -> 0 ->> 'outcome' from lote_espera) || ' ' || (select r -> 0 ->> 'code' from lote_espera),
          'conflict 23505', 'el alta de la casa de b2 choca con A: conflicto');
select results_eq(
  $$ select e ->> 'outcome', e ->> 'code', e ->> 'depends_on'
       from lote_espera, jsonb_array_elements(r) with ordinality x(e, n) where n between 2 and 6 order by n $$,
  $$ values ('conflict', 'ESPERA_ALTA_EN_CONFLICTO', '01920000-0000-7000-8000-0000000107d9'),
            ('conflict', 'ESPERA_ALTA_EN_CONFLICTO', '01920000-0000-7000-8000-0000000107d8'),
            ('conflict', 'ESPERA_ALTA_EN_CONFLICTO', '01920000-0000-7000-8000-0000000107d7'),
            ('conflict', 'ESPERA_ALTA_EN_CONFLICTO', '01920000-0000-7000-8000-0000000107d8'),
            ('conflict', 'ESPERA_ALTA_EN_CONFLICTO', '01920000-0000-7000-8000-0000000107d8') $$,
  'el depto, el vínculo y las tres citas que cuelgan de ellos quedan en espera, con de quién dependen (la cita con persona y sin espacio, del vínculo; las que nombran el depto, del depto)');
select is((select r -> 6 ->> 'outcome' from lote_espera) || ' ' || (select r -> 6 ->> 'code' from lote_espera),
          'invalid 23503', 'una cita con un vínculo que no existe y no está en espera es invalid 23503 (no 23502)');

select pg_temp.actuar_como_servidor();
select is((select count(*)::int from public.agenda where id in (pg_temp.ua(40), pg_temp.ua(41), pg_temp.ua(42), pg_temp.ua(43))),
          0, 'y ninguna de las cuatro entró: lo en espera se vuelve a subir cuando se resuelva el conflicto');

select * from finish();
rollback;
