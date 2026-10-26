-- pgTAP · migración 0105 (backend-supabase#157, decisión de Cristian del 25/10 en #132, «Visita ajena»): la
-- visita (con o sin persona) y la cita sin persona entran solo en una casa que registró la colportora o que
-- es de una ciudad de alguna campaña en la que está o estuvo inscripta, SIN plazo. Si no, 42501.
--   1. La forma: la función, sus privilegios y las cuatro políticas restrictivas (la RLS de lectura no cambia).
--   2. La visita sin persona y con persona: casa de una ciudad de una campaña terminada hace meses (entra),
--      casa propia en una ciudad sin campaña suya (entra), casa ajena de otra ciudad (42501), inscripción
--      dada de baja (entra), colportora sin ninguna inscripción (solo su casa).
--   3. El espacio FINAL decide: con persona sale del vínculo (lo que mande el teléfono da igual) y, si la
--      casa se unió a otra, el de A.
--   4. Corregir una visita: no se puede mover a una casa ajena; el resto de la corrección pasa. Y mudar el
--      vínculo propio a la casa de otra, que se llevaría la visita por el trigger DEFINER de 0069 (42501).
--   5. La cita sin persona, igual que la visita.
--   6. Un espacio que no existe o null no lo tapa la RLS: 23503 y 23502 como siempre.
--   7. Por sync_push: lo rechazado vuelve invalid con 42501 sin tumbar el lote, y el reenvío también.
--   8. La unión de dos casas (DEFINER) y el servidor siguen moviendo y escribiendo visitas sin pasar por la regla.
--   9. La dueña de la casa puede darla de baja: la visita ajena no entró (UB002).
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
  select ('01920000-0000-7000-8000-0000000105' || p)::uuid;
$$;
-- El id de una visita o de una cita (n hasta 65535, sin chocar con u()).
create or replace function pg_temp.uv(p_n integer) returns uuid language sql as $$
  select ('01920000-0000-7000-8000-00000105' || lpad(to_hex(p_n), 4, '0'))::uuid;
$$;
create or replace function pg_temp.dia(p_n integer) returns timestamptz language sql as $$
  select ((public.hoy_montevideo() + p_n)::timestamp + interval '12 hours') at time zone 'America/Montevideo';
$$;
-- Una visita tal como la inserta el teléfono: 'ok' o el SQLSTATE. Pasar null en el espacio lo quita.
create or replace function pg_temp.ins(
  p_id integer, p_espacio text, p_persona text default null, p_quien text default 'b1')
returns text language plpgsql as $$
begin
  insert into public.visita (id, espacio_persona_id, espacio_id, fecha, tipo_resultado, colportor_id)
  values (pg_temp.uv(p_id), pg_temp.u(p_persona), pg_temp.u(p_espacio), now(), 'NO_CONTESTO', pg_temp.u(p_quien));
  return 'ok';
exception when others then
  return sqlstate;
end $$;
-- Una cita tal como la inserta el teléfono: 'ok' o el SQLSTATE.
create or replace function pg_temp.cita(
  p_id integer, p_espacio text, p_persona text default null, p_quien text default 'b1')
returns text language plpgsql as $$
begin
  insert into public.agenda (id, espacio_persona_id, espacio_id, tipo, fecha_programada, colportor_id)
  values (pg_temp.uv(p_id), pg_temp.u(p_persona), pg_temp.u(p_espacio), 'ENTREVISTA', pg_temp.dia(1),
          pg_temp.u(p_quien));
  return 'ok';
exception when others then
  return sqlstate;
end $$;
create or replace function pg_temp.error_de(p_sql text) returns text language plpgsql as $$
begin
  execute p_sql;
  return 'ok';
exception when others then
  return sqlstate;
end $$;
create or replace function pg_temp.sobre() returns jsonb language sql as $$
  select jsonb_build_object('device_id', '01920000-0000-7000-8000-0000000105d0',
                            'app_version', '1.4.2', 'schema_version', 1);
$$;
create or replace function pg_temp.push(p_jobs jsonb) returns jsonb language sql as $$
  select public.sync_push(jsonb_build_object('device', pg_temp.sobre(), 'jobs', p_jobs));
$$;
create or replace function pg_temp.job(p_op text, p_entidad text, p_payload jsonb) returns jsonb language sql as $$
  select jsonb_build_object('client_op_id', pg_temp.u(p_op), 'entity', p_entidad, 'op', 'insert',
                            'sync_version', null, 'payload', p_payload);
$$;
create or replace function pg_temp.resultados(p_r jsonb) returns text[] language sql as $$
  select array_agg(e ->> 'outcome' order by i) from jsonb_array_elements(p_r -> 'results') with ordinality x(e, i);
$$;
create or replace function pg_temp.codigos(p_r jsonb) returns text[] language sql as $$
  select array_agg(coalesce(e ->> 'code', '-') order by i) from jsonb_array_elements(p_r -> 'results') with ordinality x(e, i);
$$;
create or replace function pg_temp.payload_visita(p_id integer, p_espacio text) returns jsonb language sql as $$
  select jsonb_build_object('id', pg_temp.uv(p_id), 'fecha', now(), 'tipo_resultado', 'NO_CONTESTO',
                            'espacio_id', pg_temp.u(p_espacio), 'created_at', now());
$$;
create or replace function pg_temp.payload_cita(p_id integer, p_espacio text) returns jsonb language sql as $$
  select jsonb_build_object('id', pg_temp.uv(p_id), 'tipo', 'ENTREVISTA', 'fecha_programada', pg_temp.dia(1),
                            'espacio_id', pg_temp.u(p_espacio), 'created_at', now());
$$;

-- --- fixtures (como postgres) --------------------------------------------------
-- Campañas: e1 TERMINADA hace 120 días en la ciudad c1; e2 en curso en la ciudad c2.
-- Colportores: b1 inscripta en e1 (y en nada más); b2 en e1 (registró la casa 01); b3 en e2 (registró las
-- casas 02, 05, 06 y 10); b4 sin ninguna inscripción (registró la casa 08); b5 inscripta en e1 pero dada
-- de baja.
-- Casas (ciudad, quién la registró, espacio único): 01 (c1, b2, 11) · 02 (c2, b3, 12) · 03 (c2, b1, 13) ·
-- 04 (c2, b1, 14) · 05 (c2, b3, 15) · 06 (c2, b3, 16) · 07 (c2, b1, 17) · 08 (c2, b4, 18) · 09 (c2, b1, 19) ·
-- 10 (c2, b3, 1a).
-- Vínculos: 21 (persona a1 en el 11), 22 (a1 en el 12, de b3), 23 (a2 en el 13, de b1).
insert into auth.users (id, instance_id, aud, role, email, encrypted_password, confirmed_at, created_at, updated_at)
select pg_temp.u(s), '00000000-0000-0000-0000-000000000000',
       'authenticated', 'authenticated', 'visita105-' || s || '@example.com', 'x', now(), now(), now()
  from unnest(array['b1','b2','b3','b4','b5','d1']) s;
insert into public.usuario_rol (usuario_id, rol_id)
select pg_temp.u(x.s), r.id
  from (values ('d1', 'COORDINADOR'), ('b1', 'COLPORTOR'), ('b2', 'COLPORTOR'), ('b3', 'COLPORTOR'),
               ('b4', 'COLPORTOR'), ('b5', 'COLPORTOR')) x(s, codigo)
  join public.rol r on r.codigo = x.codigo;
insert into public.pais (id, nombre, iso_code) values (pg_temp.u('c0'), 'Pais visita 105', 'ZW');
insert into public.ciudad (id, nombre, departamento, pais_id, lat_centro, lon_centro) values
  (pg_temp.u('c1'), 'Ciudad uno 105', 'Departamento de prueba', pg_temp.u('c0'), -34.9, -56.2),
  (pg_temp.u('c2'), 'Ciudad dos 105', 'Departamento de prueba', pg_temp.u('c0'), -34.5, -56.0);
insert into public.campania (id, nombre, tipo, fecha_inicio, fecha_fin, coordinador_id) values
  (pg_temp.u('e1'), 'Verano viejo 105', 'VERANO', public.hoy_montevideo() - 200, public.hoy_montevideo() - 120, pg_temp.u('d1')),
  (pg_temp.u('e2'), 'Verano vivo 105',  'VERANO', public.hoy_montevideo() - 10,  public.hoy_montevideo() + 30,  pg_temp.u('d1'));
insert into public.campania_ciudad (id, campania_id, ciudad_id) values
  (pg_temp.u('f1'), pg_temp.u('e1'), pg_temp.u('c1')),
  (pg_temp.u('f2'), pg_temp.u('e2'), pg_temp.u('c2'));
insert into public.campania_colportor (campania_id, usuario_id, deleted_at) values
  (pg_temp.u('e1'), pg_temp.u('b1'), null),
  (pg_temp.u('e1'), pg_temp.u('b2'), null),
  (pg_temp.u('e2'), pg_temp.u('b3'), null),
  (pg_temp.u('e1'), pg_temp.u('b5'), now());
insert into public.ubicacion (id, tipo, calle, numero, lat, lon, ciudad_id, created_by) values
  (pg_temp.u('01'), 'CASA', 'Visita 01', '1',  -34.91, -56.2,  pg_temp.u('c1'), pg_temp.u('b2')),
  (pg_temp.u('02'), 'CASA', 'Visita 02', '2',  -34.51, -56.0,  pg_temp.u('c2'), pg_temp.u('b3')),
  (pg_temp.u('03'), 'CASA', 'Visita 03', '3',  -34.52, -56.0,  pg_temp.u('c2'), pg_temp.u('b1')),
  (pg_temp.u('04'), 'CASA', 'Visita 04', '4',  -34.53, -56.0,  pg_temp.u('c2'), pg_temp.u('b1')),
  (pg_temp.u('05'), 'CASA', 'Visita 05', '5',  -34.54, -56.0,  pg_temp.u('c2'), pg_temp.u('b3')),
  (pg_temp.u('06'), 'CASA', 'Visita 06', '6',  -34.55, -56.0,  pg_temp.u('c2'), pg_temp.u('b3')),
  (pg_temp.u('07'), 'CASA', 'Visita 07', '7',  -34.56, -56.0,  pg_temp.u('c2'), pg_temp.u('b1')),
  (pg_temp.u('08'), 'CASA', 'Visita 08', '8',  -34.57, -56.0,  pg_temp.u('c2'), pg_temp.u('b4')),
  (pg_temp.u('09'), 'CASA', 'Visita 09', '9',  -34.58, -56.0,  pg_temp.u('c2'), pg_temp.u('b1')),
  (pg_temp.u('10'), 'CASA', 'Visita 10', '10', -34.59, -56.0,  pg_temp.u('c2'), pg_temp.u('b3'));
insert into public.espacio (id, ubicacion_id, numero_depto, created_by) values
  (pg_temp.u('11'), pg_temp.u('01'), null, pg_temp.u('b2')),
  (pg_temp.u('12'), pg_temp.u('02'), null, pg_temp.u('b3')),
  (pg_temp.u('13'), pg_temp.u('03'), null, pg_temp.u('b1')),
  (pg_temp.u('14'), pg_temp.u('04'), null, pg_temp.u('b1')),
  (pg_temp.u('15'), pg_temp.u('05'), null, pg_temp.u('b3')),
  (pg_temp.u('16'), pg_temp.u('06'), null, pg_temp.u('b3')),
  (pg_temp.u('17'), pg_temp.u('07'), null, pg_temp.u('b1')),
  (pg_temp.u('18'), pg_temp.u('08'), null, pg_temp.u('b4')),
  (pg_temp.u('19'), pg_temp.u('09'), null, pg_temp.u('b1')),
  (pg_temp.u('1a'), pg_temp.u('10'), null, pg_temp.u('b3'));
insert into public.espacio_persona (id, espacio_id, persona_id, created_by) values
  (pg_temp.u('21'), pg_temp.u('11'), pg_temp.u('a1'), pg_temp.u('b2')),
  (pg_temp.u('22'), pg_temp.u('12'), pg_temp.u('a1'), pg_temp.u('b3')),
  (pg_temp.u('23'), pg_temp.u('13'), pg_temp.u('a2'), pg_temp.u('b1'));

-- ---------------------------------------------------------------------------
-- 1. La forma
-- ---------------------------------------------------------------------------
select has_function('public', 'puedo_dejar_en_espacio', array['uuid'], 'existe puedo_dejar_en_espacio(uuid)');
select ok((select prosecdef from pg_proc where oid = 'public.puedo_dejar_en_espacio(uuid)'::regprocedure)
          and (select proconfig::text from pg_proc where oid = 'public.puedo_dejar_en_espacio(uuid)'::regprocedure) like '%search_path=%',
          'es SECURITY DEFINER con search_path fijo');
select ok(has_function_privilege('authenticated', 'public.puedo_dejar_en_espacio(uuid)', 'execute')
          and has_function_privilege('service_role', 'public.puedo_dejar_en_espacio(uuid)', 'execute')
          and not has_function_privilege('anon', 'public.puedo_dejar_en_espacio(uuid)', 'execute'),
          'la ejecutan authenticated (las políticas) y service_role, no anon');
select is((select array_agg(policyname::text order by policyname::text collate "C") from pg_policies
            where schemaname = 'public' and tablename = 'visita' and permissive = 'RESTRICTIVE'),
          array['visita_solo_en_casa_de_la_colportora_insert', 'visita_solo_en_casa_de_la_colportora_update'],
          'visita tiene dos políticas restrictivas: alta y corrección');
select is((select array_agg(policyname::text order by policyname::text collate "C") from pg_policies
            where schemaname = 'public' and tablename = 'agenda' and permissive = 'RESTRICTIVE'),
          array['agenda_sin_persona_solo_en_casa_de_la_colportora_insert', 'agenda_sin_persona_solo_en_casa_de_la_colportora_update'],
          'agenda también');
select is((select array_agg(policyname::text order by policyname::text collate "C") from pg_policies
            where schemaname = 'public' and tablename in ('visita', 'agenda') and permissive = 'PERMISSIVE'),
          array['agenda_propio', 'visita_propio'], 'y la RLS de lectura y escritura de la dueña no cambia');
select is((select array_agg(distinct cmd::text order by cmd::text) from pg_policies
            where schemaname = 'public' and tablename in ('visita', 'agenda') and permissive = 'RESTRICTIVE'),
          array['INSERT', 'UPDATE'], 'las restrictivas rigen en el alta y la corrección, no en la lectura');

-- ---------------------------------------------------------------------------
-- 2. Visita: sin persona y con persona
-- ---------------------------------------------------------------------------
select pg_temp.actuar_como(pg_temp.u('b1'));

select is(pg_temp.ins(1, '11'), 'ok',
          'b1 (inscripta en una campaña que terminó hace 120 días) deja una visita sin persona en una casa de esa ciudad, sin plazo');
select is(pg_temp.ins(2, '11', '21'), 'ok', 'y con persona');
select is(pg_temp.ins(3, '13'), 'ok', 'en una casa que registró ella, aunque sea de una ciudad sin campaña suya: entra');
select is(pg_temp.ins(4, '13', '23'), 'ok', 'con persona también');
select is(pg_temp.ins(5, '12'), '42501', 'sin persona en la casa de b3, de una ciudad en la que b1 nunca estuvo: 42501');
select is(pg_temp.ins(6, '12', '22'), '42501', 'con persona (el vínculo es de la casa de b3): 42501');
select is(pg_temp.ins(7, '11', '22'), '42501',
          'manda el espacio 11, que sí podría, pero el vínculo es de la casa ajena: el espacio final sale del vínculo');
select is(pg_temp.ins(8, '12', '21'), 'ok',
          'al revés: manda un espacio ajeno pero el vínculo es de una casa suya: el final es el del vínculo y entra');
select is((select espacio_id from public.visita where id = pg_temp.uv(8)), pg_temp.u('11'), 'y se guardó en el del vínculo');
select is((select count(*)::int from public.visita where id in (pg_temp.uv(5), pg_temp.uv(6), pg_temp.uv(7))), 0,
          'ninguna visita ajena quedó guardada');

-- Otras colportoras.
select pg_temp.actuar_como(pg_temp.u('b3'));
select is(pg_temp.ins(10, '12', p_quien => 'b3'), 'ok', 'b3, inscripta en la campaña en curso de la ciudad dos, deja una visita en la casa 02');
select is(pg_temp.ins(11, '15', p_quien => 'b3'), 'ok', 'y en una casa de b3 de la misma ciudad');
select is(pg_temp.ins(12, '11', p_quien => 'b3'), '42501', 'pero no en la casa de la ciudad uno, que no es de ninguna de sus campañas');
select pg_temp.actuar_como(pg_temp.u('b4'));
select is(pg_temp.ins(13, '18', p_quien => 'b4'), 'ok', 'b4, sin ninguna inscripción, deja una visita en la casa que registró ella');
select is(pg_temp.ins(14, '12', p_quien => 'b4'), '42501', 'y en la de otra, de la misma ciudad de una campaña en curso, no');
select is(pg_temp.ins(15, '11', '21', p_quien => 'b4'), '42501', 'ni con persona');
select pg_temp.actuar_como(pg_temp.u('b5'));
select is(pg_temp.ins(16, '11', p_quien => 'b5'), 'ok',
          'b5, que estuvo inscripta en la campaña (la dieron de baja), sigue pudiendo dejar lo que subió tarde en esa ciudad');
select is(pg_temp.ins(17, '12', p_quien => 'b5'), '42501', 'y en la otra ciudad no');
select pg_temp.actuar_como(pg_temp.u('b1'));

-- ---------------------------------------------------------------------------
-- 3. El espacio final: la unión de dos casas
-- ---------------------------------------------------------------------------
-- La casa 04 (de b1) se une a la 05 (de b3, ciudad dos): lo que b1 suba tarde nombrando la 04 se guarda en
-- el espacio de la 05, y es el espacio final el que se mira. La 06 (de b3) se une a la 07 (de b1): lo que
-- llegue nombrando la 06 queda en la 07 y entra.
select pg_temp.actuar_como_servidor();
select lives_ok($$ select public.marcar_como_duplicado(pg_temp.u('04'), pg_temp.u('05')) $$, 'se une la 04 (de b1) a la 05 (de b3)');
select lives_ok($$ select public.marcar_como_duplicado(pg_temp.u('06'), pg_temp.u('07')) $$, 'y la 06 (de b3) a la 07 (de b1)');
select pg_temp.actuar_como(pg_temp.u('b1'));
select is(pg_temp.ins(20, '14'), '42501', 'una visita que llega tarde a la 04 queda en la 05, ajena: 42501 (se mira el espacio final)');
select is(pg_temp.ins(21, '16'), 'ok', 'una que llega tarde a la 06 queda en la 07, de b1: entra');
select is((select espacio_id from public.visita where id = pg_temp.uv(21)), pg_temp.u('17'), 'y se guardó en el espacio de la 07');

-- ---------------------------------------------------------------------------
-- 4. Corregir una visita
-- ---------------------------------------------------------------------------
select lives_ok($$ update public.visita set tipo_resultado = 'RECHAZO' where id = pg_temp.uv(1) $$,
                'b1 corrige el resultado de su visita en la casa de la campaña vieja');
select is(pg_temp.error_de(format('update public.visita set espacio_id = %L where id = %L', pg_temp.u('12'), pg_temp.uv(1))),
          '42501', 'pero no la puede mover a la casa de otra ciudad que no es suya');
select is((select espacio_id from public.visita where id = pg_temp.uv(1)), pg_temp.u('11'), 'y la visita sigue donde estaba');
select is(pg_temp.error_de(format('update public.visita set espacio_id = %L where id = %L', pg_temp.u('13'), pg_temp.uv(1))),
          'ok', 'a una casa suya sí');
select is(pg_temp.error_de(format('update public.visita set espacio_persona_id = %L where id = %L', pg_temp.u('22'), pg_temp.uv(1))),
          '42501', 'ni colgarla de un vínculo de la casa ajena');
select is((select espacio_id from public.visita where id = pg_temp.uv(1)), pg_temp.u('13'), 'queda en la casa 03');

-- ---------------------------------------------------------------------------
-- 4b. El vínculo propio que se muda se lleva sus visitas
-- ---------------------------------------------------------------------------
-- espacio_persona_mueve_visitas (0069, DEFINER) lleva las visitas de un vínculo a su espacio nuevo sin pasar
-- por las políticas: sin un chequeo propio, mudar el vínculo a la casa de otra era el camino de vuelta al
-- hueco (y la dueña recibía UB002 al dar de baja su casa). El vínculo 23 es de b1, en su casa 03 (espacio
-- 13), y tiene la visita 4.
select is(pg_temp.error_de(format('update public.espacio_persona set espacio_id = %L where id = %L', pg_temp.u('12'), pg_temp.u('23'))),
          '42501', 'b1 no muda su vínculo al espacio de la casa de b3 (ciudad en la que nunca estuvo): 42501');
select is((select espacio_id from public.espacio_persona where id = pg_temp.u('23')), pg_temp.u('13'), 'el vínculo queda donde estaba');
select is((select espacio_id from public.visita where id = pg_temp.uv(4)), pg_temp.u('13'), 'y su visita también: no se la llevó a la casa ajena');
select is(pg_temp.error_de(format('update public.espacio_persona set espacio_id = %L where id = %L', pg_temp.u('14'), pg_temp.u('23'))),
          '42501', 'ni a un espacio que se fundió en uno ajeno (se mira el espacio final: el 14 es de la 04, unida a la 05 de b3)');
select is(pg_temp.error_de(format('update public.espacio_persona set persona_id = %L where id = %L', pg_temp.u('a3'), pg_temp.u('23'))),
          'ok', 'corregir otra cosa del vínculo no se toca');
select is(pg_temp.error_de(format('update public.espacio_persona set espacio_id = %L where id = %L', pg_temp.u('13'), pg_temp.u('23'))),
          'ok', 'ni dejarlo en su mismo espacio');
select is(pg_temp.error_de(format('update public.espacio_persona set espacio_id = %L where id = %L', pg_temp.u('11'), pg_temp.u('23'))),
          'ok', 'a una casa de la ciudad de su campaña vieja sí lo muda');
select is((select espacio_id from public.visita where id = pg_temp.uv(4)), pg_temp.u('11'), 'y la visita lo sigue');
select is((select tgname::text from pg_trigger where tgrelid = 'public.espacio_persona'::regclass and not tgisinternal
              and tgname = 'espacio_persona_1_no_se_muda_a_casa_ajena'),
          'espacio_persona_1_no_se_muda_a_casa_ajena', 'el trigger existe y corre después de la unión (por el nombre)');
select ok(not has_function_privilege('authenticated', 'public.tg_espacio_persona_no_se_muda_a_casa_ajena()', 'execute')
          and not has_function_privilege('anon', 'public.tg_espacio_persona_no_se_muda_a_casa_ajena()', 'execute'),
          'su función no la ejecuta nadie desde afuera');
-- El servidor y la unión DEFINER siguen mudando vínculos: el 22 (b3) a un espacio de b1, como postgres.
select pg_temp.actuar_como_servidor();
select is(pg_temp.error_de(format('update public.espacio_persona set espacio_id = %L where id = %L', pg_temp.u('13'), pg_temp.u('22'))),
          'ok', 'el servidor muda un vínculo a donde sea');
select pg_temp.actuar_como(pg_temp.u('b1'));

-- ---------------------------------------------------------------------------
-- 5. La cita sin persona
-- ---------------------------------------------------------------------------
select is(pg_temp.cita(100, '11'), 'ok', 'cita sin persona en una casa de una campaña terminada hace meses: entra');
select is(pg_temp.cita(101, '13'), 'ok', 'en una casa que registró ella: entra');
select is(pg_temp.cita(102, '12'), '42501', 'en la casa de otra ciudad que no es suya: 42501');
select is(pg_temp.cita(103, '14'), '42501', 'en una casa que se unió a una ajena: se mira el espacio final y es 42501');
select is(pg_temp.cita(104, '16'), 'ok', 'y a la inversa, entra');
select is((select espacio_id from public.agenda where id = pg_temp.uv(104)), pg_temp.u('17'), 'en el espacio de la 07');
select is((select count(*)::int from public.agenda where id in (pg_temp.uv(102), pg_temp.uv(103))), 0, 'ninguna cita ajena quedó guardada');
select is(pg_temp.error_de(format('update public.agenda set espacio_id = %L where id = %L', pg_temp.u('12'), pg_temp.uv(100))),
          '42501', 'la cita sin persona no se puede mover a una casa ajena');
select is(pg_temp.error_de(format($$update public.agenda set estado = 'CANCELADA' where id = %L$$, pg_temp.uv(100))),
          'ok', 'pero sí cancelar, y cualquier otra corrección');
select pg_temp.actuar_como(pg_temp.u('b4'));
select is(pg_temp.cita(105, '18', p_quien => 'b4'), 'ok', 'b4, sin inscripción, agenda en su propia casa');
select is(pg_temp.cita(106, '12', p_quien => 'b4'), '42501', 'y no en una ajena');
select pg_temp.actuar_como(pg_temp.u('b1'));

-- ---------------------------------------------------------------------------
-- 6. Lo que la RLS no tapa: espacio inexistente y espacio null
-- ---------------------------------------------------------------------------
select is(pg_temp.ins(30, 'ff'), '23503', 'una visita a un espacio que no existe sigue siendo 23503 (el push la deja en espera)');
select is(pg_temp.ins(31, null), '23502', 'sin espacio, 23502');
select is(pg_temp.ins(32, null, '99'), '23503', 'con un vínculo que no existe, 23503');
select is(pg_temp.cita(110, 'ff'), '23503', 'una cita sin persona a un espacio que no existe sigue siendo 23503');
select is(pg_temp.cita(111, null), '23502', 'sin espacio, 23502');

-- ---------------------------------------------------------------------------
-- 7. Por sync_push
-- ---------------------------------------------------------------------------
select is(pg_temp.resultados(pg_temp.push(jsonb_build_array(
            pg_temp.job('b1', 'visita', pg_temp.payload_visita(200, '12')),
            pg_temp.job('b2', 'visita', pg_temp.payload_visita(201, '11')),
            pg_temp.job('b3', 'agenda', pg_temp.payload_cita(202, '12')),
            pg_temp.job('b4', 'agenda', pg_temp.payload_cita(203, '11')),
            pg_temp.job('b5', 'visita', pg_temp.payload_visita(204, '13'))
          ))), array['invalid', 'accepted', 'invalid', 'accepted', 'accepted'],
          'la visita y la cita ajenas vuelven invalid sin tumbar el lote: lo demás entra');
select is(pg_temp.codigos(pg_temp.push(jsonb_build_array(
            pg_temp.job('b1', 'visita', pg_temp.payload_visita(200, '12')),
            pg_temp.job('b3', 'agenda', pg_temp.payload_cita(202, '12'))
          ))), array['42501', '42501'], 'con su SQLSTATE');
select is(pg_temp.resultados(pg_temp.push(jsonb_build_array(
            pg_temp.job('b2', 'visita', pg_temp.payload_visita(201, '11')),
            pg_temp.job('b4', 'agenda', pg_temp.payload_cita(203, '11'))))),
          array['duplicate', 'duplicate'], 'el reenvío de lo que entró es duplicate (no se vuelve invalid)');
select is(pg_temp.resultados(pg_temp.push(jsonb_build_array(
            pg_temp.job('c1', 'visita', pg_temp.payload_visita(205, 'ff'))))),
          array['invalid'], 'un espacio inexistente sigue su camino de siempre');
select is(pg_temp.codigos(pg_temp.push(jsonb_build_array(
            pg_temp.job('c1', 'visita', pg_temp.payload_visita(205, 'ff'))))),
          array['23503'], 'con 23503, no con 42501');
select is((select count(*)::int from public.visita where id in (pg_temp.uv(200), pg_temp.uv(205))), 0, 'y no quedó nada a medias');

-- ---------------------------------------------------------------------------
-- 8. La unión de dos casas y el servidor no pasan por la regla
-- ---------------------------------------------------------------------------
-- El servidor escribe lo que quiera (migraciones, soporte).
select pg_temp.actuar_como_servidor();
insert into public.visita (id, espacio_persona_id, espacio_id, fecha, tipo_resultado, colportor_id)
values (pg_temp.uv(300), null, pg_temp.u('12'), now(), 'NO_CONTESTO', pg_temp.u('b1'));
select is((select count(*)::int from public.visita where id = pg_temp.uv(300)), 1, 'el servidor escribe sin pasar por la regla');
-- b1 deja una visita en su casa 09; b3 une la 09 a la 10 (de b3): la visita de b1 sigue a la casa de A, que
-- no es suya, porque la unión corre como su dueño y no pierde nada.
insert into public.visita (id, espacio_persona_id, espacio_id, fecha, tipo_resultado, colportor_id)
values (pg_temp.uv(301), null, pg_temp.u('19'), now(), 'NO_CONTESTO', pg_temp.u('b1'));
select pg_temp.actuar_como(pg_temp.u('b3'));
select lives_ok($$ select public.marcar_como_duplicado(pg_temp.u('09'), pg_temp.u('10')) $$,
                'b3 une la casa 09 (de b1) a la 10 (suya)');
select pg_temp.actuar_como_servidor();
select is((select espacio_id from public.visita where id = pg_temp.uv(301)), pg_temp.u('1a'),
          'la visita de b1 pasó al espacio de A aunque b1 no escriba ahí');
select is((select colportor_id from public.visita where id = pg_temp.uv(301)), pg_temp.u('b1'), 'y sigue siendo suya');

-- ---------------------------------------------------------------------------
-- 9. La dueña de la casa puede darla de baja
-- ---------------------------------------------------------------------------
-- Ninguna visita de b1 entró en la casa 02 (sacando la que escribió el servidor), así que la dueña no tiene
-- por qué recibir UB002. Se borra la que puso el servidor para dejar el caso limpio.
delete from public.visita where id = pg_temp.uv(300);
select pg_temp.actuar_como(pg_temp.u('b3'));
select lives_ok(format('update public.ubicacion set deleted_at = now() where id = %L', pg_temp.u('02')),
                'b3 da de baja su casa 02: la visita ajena no entró y nada la frena (UB002)');

select * from finish();
rollback;
