-- pgTAP · migración 0068 (backend-supabase#131, decisiones de Cristian del 23/10): la agenda es una sola
-- abstracción, con un tipo y con lo que la origina.
--   1. La forma: columnas nuevas (espacio_id, venta_id, entrega_id, monto_previsto; entrega.fecha_prevista),
--      NOT NULL / opcional, default, orden de los triggers y privilegios.
--   2. Los cuatro estados de la HU y los tres tipos; los nombres viejos ya no entran.
--   3. Cita sin persona: cuelga del espacio; con persona, el espacio es el de su vínculo.
--   4. Lo que origina la cita: monto previsto solo en una cobranza con venta, entrega solo en una cita
--      ENTREGA, y la venta y la entrega son de quien agenda.
--   5. Los topes del reparto: 12 cuotas por venta (AG001), ninguna supera el saldo (AG002), el día de
--      creación (AG003); qué cuenta y qué no.
--   6. Por sync_push: lo mismo vuelve invalid con su código sin tumbar el lote; los teléfonos que todavía
--      no mandan espacio_id siguen andando; el update con la fila entera no vuelve a medir lo que no cambió
--      y el reenvío de un alta que ya existe es duplicate.
--   7. entrega.fecha_prevista.
--   8. Cuando dos casas se unen, las citas (con o sin persona) siguen al espacio de A.
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
  select ('01920000-0000-7000-8000-0000000068' || p)::uuid;
$$;
-- El id de una cita (n hasta 65535, sin chocar con u()).
create or replace function pg_temp.ua(p_n integer) returns uuid language sql as $$
  select ('01920000-0000-7000-8000-00000068' || lpad(to_hex(p_n), 4, '0'))::uuid;
$$;
-- El mediodía de Montevideo, hoy + n días.
create or replace function pg_temp.dia(p_n integer) returns timestamptz language sql as $$
  select ((public.hoy_montevideo() + p_n)::timestamp + interval '12 hours') at time zone 'America/Montevideo';
$$;
-- SQLSTATE o 'ok' de lo que hace una sentencia (en subtransacción: no deja nada si falla).
create or replace function pg_temp.error_de(p_sql text) returns text language plpgsql as $$
begin
  execute p_sql;
  return 'ok';
exception when others then
  return sqlstate;
end $$;
-- Una cita tal como la inserta el teléfono: 'ok' o el SQLSTATE. El espacio por defecto es el 11; pasar
-- null lo quita.
create or replace function pg_temp.ins(
  p_id integer, p_tipo text, p_dia integer, p_estado text default 'PROGRAMADA',
  p_venta text default null, p_monto integer default null, p_persona text default null,
  p_espacio text default '11', p_entrega text default null, p_quien text default 'b1',
  p_creada timestamptz default null)
returns text language plpgsql as $$
begin
  insert into public.agenda (id, espacio_persona_id, espacio_id, tipo, fecha_programada, estado, colportor_id,
                             venta_id, monto_previsto, entrega_id, created_at)
  values (pg_temp.ua(p_id), pg_temp.u(p_persona), pg_temp.u(p_espacio), p_tipo, pg_temp.dia(p_dia), p_estado,
          pg_temp.u(p_quien), pg_temp.u(p_venta), p_monto, pg_temp.u(p_entrega), coalesce(p_creada, now()));
  return 'ok';
exception when others then
  return sqlstate;
end $$;
-- Una cuota (cita de cobranza con venta y monto, sin persona, en el espacio 11).
create or replace function pg_temp.cuota(p_id integer, p_venta text, p_monto integer, p_dia integer default 1,
                                         p_estado text default 'PROGRAMADA')
returns text language sql as $$
  select pg_temp.ins(p_id, 'COBRANZA', p_dia, p_estado, p_venta, p_monto);
$$;
create or replace function pg_temp.sobre() returns jsonb language sql as $$
  select jsonb_build_object('device_id', '01920000-0000-7000-8000-0000000068d0',
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
-- El payload de una cita como lo sube el teléfono (sin las columnas del servidor).
create or replace function pg_temp.payload_cita(p_id integer, p_tipo text, p_dia integer, p_estado text,
                                                p_espacio text, p_persona text, p_venta text, p_monto integer,
                                                p_creada timestamptz default null)
returns jsonb language sql as $$
  select jsonb_strip_nulls(jsonb_build_object(
    'id', pg_temp.ua(p_id), 'tipo', p_tipo, 'fecha_programada', pg_temp.dia(p_dia), 'estado', p_estado,
    'espacio_id', pg_temp.u(p_espacio), 'espacio_persona_id', pg_temp.u(p_persona),
    'venta_id', pg_temp.u(p_venta), 'monto_previsto', p_monto, 'created_at', p_creada));
$$;

-- --- fixtures (como postgres) --------------------------------------------------
-- b1 y b2 inscriptos en la campaña e1 de la ciudad c1. Ubicaciones: 01 (casa de b1, espacio único 11),
-- 02 (casa de b2, espacio único 12), 03 (edificio con los deptos 13 y 14). Vínculos: 21 (a1 en 11),
-- 22 (a1 en 12, de b2), 23 (a2 en el depto 13). Ventas de b1: 51 (1000,00), 53 (300,00), 54 (10000,00),
-- 55 (200,00); de b2: 52 (500,00). Entregas: 61 (venta 51), 62 (venta 52), 63 (venta 53). Cobranza 71 de
-- 100,00 en la venta 53.
insert into auth.users (id, instance_id, aud, role, email, encrypted_password, confirmed_at, created_at, updated_at)
select pg_temp.u(s), '00000000-0000-0000-0000-000000000000',
       'authenticated', 'authenticated', 'agenda68-' || s || '@example.com', 'x', now(), now(), now()
  from unnest(array['b1','b2']) s;
insert into public.pais (id, nombre, iso_code) values (pg_temp.u('c0'), 'Pais agenda', 'ZA');
insert into public.ciudad (id, nombre, departamento, pais_id, lat_centro, lon_centro)
values (pg_temp.u('c1'), 'Ciudad agenda', 'Departamento de prueba', pg_temp.u('c0'), -34.9, -56.2);
insert into public.campania (id, nombre, tipo, fecha_inicio, fecha_fin)
values (pg_temp.u('e1'), 'Verano agenda', 'VERANO', public.hoy_montevideo() - 10, public.hoy_montevideo() + 30);
insert into public.campania_ciudad (id, campania_id, ciudad_id) values (pg_temp.u('f1'), pg_temp.u('e1'), pg_temp.u('c1'));
insert into public.campania_colportor (campania_id, usuario_id, zona_id) values
  (pg_temp.u('e1'), pg_temp.u('b1'), null),
  (pg_temp.u('e1'), pg_temp.u('b2'), null);
insert into public.ubicacion (id, tipo, calle, numero, lat, lon, ciudad_id, created_by) values
  (pg_temp.u('01'), 'CASA',     'Agenda 01', '1', -34.91, -56.2, pg_temp.u('c1'), pg_temp.u('b1')),
  (pg_temp.u('02'), 'CASA',     'Agenda 02', '2', -34.92, -56.2, pg_temp.u('c1'), pg_temp.u('b2')),
  (pg_temp.u('03'), 'EDIFICIO', 'Agenda 03', '3', -34.93, -56.2, pg_temp.u('c1'), pg_temp.u('b1'));
insert into public.espacio (id, ubicacion_id, numero_depto, created_by) values
  (pg_temp.u('11'), pg_temp.u('01'), null, pg_temp.u('b1')),
  (pg_temp.u('12'), pg_temp.u('02'), null, pg_temp.u('b2')),
  (pg_temp.u('13'), pg_temp.u('03'), '1',  pg_temp.u('b1')),
  (pg_temp.u('14'), pg_temp.u('03'), '2',  pg_temp.u('b1'));
insert into public.espacio_persona (id, espacio_id, persona_id, created_by) values
  (pg_temp.u('21'), pg_temp.u('11'), pg_temp.u('a1'), pg_temp.u('b1')),
  (pg_temp.u('22'), pg_temp.u('12'), pg_temp.u('a1'), pg_temp.u('b2')),
  (pg_temp.u('23'), pg_temp.u('13'), pg_temp.u('a2'), pg_temp.u('b1'));
insert into public.venta (id, espacio_persona_id, numero_talonario, monto_total, fecha, colportor_id, created_by)
select pg_temp.u(x.v), pg_temp.u(x.ep), 'T-' || x.v, x.monto, now(), pg_temp.u(x.quien), pg_temp.u(x.quien)
  from (values ('51', '21', 100000, 'b1'), ('52', '22', 50000, 'b2'), ('53', '23', 30000, 'b1'),
               ('54', '21', 1000000, 'b1'), ('55', '21', 20000, 'b1')) x(v, ep, monto, quien);
insert into public.producto (id, nombre, tipo) values (pg_temp.u('d1'), 'Libro agenda', 'LIBRO');
insert into public.entrega (id, venta_id, producto_id, cantidad, created_by)
select pg_temp.u(x.e), pg_temp.u(x.v), pg_temp.u('d1'), 1, pg_temp.u(x.quien)
  from (values ('61', '51', 'b1'), ('62', '52', 'b2'), ('63', '53', 'b1')) x(e, v, quien);
insert into public.cobranza (id, venta_id, monto, medio, fecha, created_by)
values (pg_temp.u('71'), pg_temp.u('53'), 10000, 'EFECTIVO', now(), pg_temp.u('b1'));

-- ---------------------------------------------------------------------------
-- 1. La forma
-- ---------------------------------------------------------------------------
select col_type_is('public', 'agenda', 'espacio_id', 'uuid', 'agenda.espacio_id es uuid');
select col_not_null('public', 'agenda', 'espacio_id', 'y obligatorio: la cita siempre cuelga de un espacio');
select col_is_null('public', 'agenda', 'espacio_persona_id', 'la persona es opcional');
select col_type_is('public', 'agenda', 'venta_id', 'uuid', 'agenda.venta_id es uuid');
select col_is_null('public', 'agenda', 'venta_id', 'y opcional');
select col_type_is('public', 'agenda', 'entrega_id', 'uuid', 'agenda.entrega_id es uuid');
select col_is_null('public', 'agenda', 'entrega_id', 'y opcional');
select col_type_is('public', 'agenda', 'monto_previsto', 'integer', 'agenda.monto_previsto son centavos enteros');
select col_is_null('public', 'agenda', 'monto_previsto', 'y opcional');
select col_type_is('public', 'entrega', 'fecha_prevista', 'timestamp with time zone', 'entrega.fecha_prevista es timestamptz');
select col_is_null('public', 'entrega', 'fecha_prevista', 'y opcional');
select col_type_is('public', 'entrega', 'fecha_entrega', 'timestamp with time zone', 'fecha_entrega sigue (la real)');
select is((select column_default from information_schema.columns
            where table_schema = 'public' and table_name = 'agenda' and column_name = 'estado'),
          $$'PROGRAMADA'::text$$, 'una cita nueva arranca PROGRAMADA');
select is((select array_agg(tgname::text order by tgname::text collate "C") from pg_trigger
            where tgrelid = 'public.agenda'::regclass and not tgisinternal and (tgtype & 4) = 4),
          array['agenda_0_union_redirige', 'agenda_1_origen', 'agenda_auditoria_insert'],
          'al insertar corren, en este orden, la unión (espacio), el origen y la auditoría');
select ok(not has_function_privilege('authenticated', 'public.tg_agenda_origen()', 'execute')
          and not has_function_privilege('anon', 'public.tg_agenda_origen()', 'execute')
          and not has_function_privilege('authenticated', 'public.tg_espacio_union_mueve_agendas()', 'execute')
          and not has_function_privilege('anon', 'public.tg_espacio_union_mueve_agendas()', 'execute')
          and not has_function_privilege('authenticated', 'public.tg_agenda_union_redirige()', 'execute'),
          'las funciones de los triggers no las ejecuta nadie desde afuera');
select ok((select prosecdef from pg_proc where oid = 'public.tg_agenda_origen()'::regprocedure)
          and (select proconfig::text from pg_proc where oid = 'public.tg_agenda_origen()'::regprocedure) like '%search_path=%',
          'el trigger de origen es SECURITY DEFINER con search_path fijo');
select has_index('public', 'agenda', 'agenda_espacio_idx', 'hay índice por espacio');
select has_index('public', 'agenda', 'agenda_venta_idx', 'y por venta');
select has_index('public', 'agenda', 'agenda_entrega_idx', 'y por entrega');
select has_trigger('public', 'espacio_union', 'espacio_union_mueve_agendas', 'una unión de espacios mueve las citas');

-- ---------------------------------------------------------------------------
-- 2. Estados y tipos
-- ---------------------------------------------------------------------------
select pg_temp.actuar_como(pg_temp.u('b1'));

select is(pg_temp.ins(1, 'ENTREVISTA', 1, 'PROGRAMADA', p_persona => '21'), 'ok', 'PROGRAMADA entra');
select is(pg_temp.ins(2, 'ENTREVISTA', 1, 'CUMPLIDA', p_persona => '21'), 'ok', 'CUMPLIDA entra');
select is(pg_temp.ins(3, 'ENTREVISTA', 1, 'NO_CUMPLIDA', p_persona => '21'), 'ok', 'NO_CUMPLIDA entra');
select is(pg_temp.ins(4, 'ENTREVISTA', 1, 'CANCELADA', p_persona => '21'), 'ok', 'CANCELADA entra');
select is(pg_temp.ins(5, 'ENTREVISTA', 1, 'PENDIENTE', p_persona => '21'), '23514', 'PENDIENTE ya no entra');
select is(pg_temp.ins(6, 'ENTREVISTA', 1, 'COMPLETADA', p_persona => '21'), '23514', 'COMPLETADA tampoco');
select is(pg_temp.ins(7, 'ENTREVISTA', 1, 'VENCIDA', p_persona => '21'), '23514', 'ni un estado inventado (una vencida sigue PROGRAMADA)');
select is(pg_temp.ins(8, 'ENTREVISTA', 1, 'programada', p_persona => '21'), '23514', 'ni en minúsculas');
select is(pg_temp.ins(9, 'ENTREVISTA', 1, null, p_persona => '21'), '23502', 'el estado no puede ser null');
select lives_ok($$ insert into public.agenda (id, espacio_persona_id, tipo, fecha_programada, colportor_id)
                   values (pg_temp.ua(10), pg_temp.u('21'), 'ENTREVISTA', now(), pg_temp.u('b1')) $$,
                'sin estado, entra');
select is((select estado from public.agenda where id = pg_temp.ua(10)), 'PROGRAMADA', 'y queda PROGRAMADA');
select lives_ok($$ update public.agenda set estado = 'NO_CUMPLIDA' where id = pg_temp.ua(10) $$,
                'una programada pasa a no cumplida');
select lives_ok($$ update public.agenda set estado = 'PROGRAMADA' where id = pg_temp.ua(10) $$,
                'y se puede volver a programar');
select is(pg_temp.error_de($$ update public.agenda set estado = 'COMPLETADA' where id = pg_temp.ua(10) $$), '23514',
          'pasar a un nombre viejo se rechaza');

select is(pg_temp.ins(11, 'ENTREVISTA', 1), 'ok', 'ENTREVISTA entra');
select is(pg_temp.ins(12, 'COBRANZA', 1), 'ok', 'COBRANZA entra');
select is(pg_temp.ins(13, 'ENTREGA', 1), 'ok', 'ENTREGA entra');
select is(pg_temp.ins(14, 'PRESENTACION', 1), '23514', 'un tipo que todavía no existe se rechaza (se suma ampliando el CHECK)');
select is(pg_temp.ins(15, null, 1), '23502', 'sin tipo no entra');

-- ---------------------------------------------------------------------------
-- 3. Cita sin persona
-- ---------------------------------------------------------------------------
select is(pg_temp.ins(20, 'ENTREVISTA', 1), 'ok', 'una cita sin persona cuelga del espacio');
select is((select espacio_persona_id from public.agenda where id = pg_temp.ua(20)), null, 'y no tiene persona');
select is((select espacio_id from public.agenda where id = pg_temp.ua(20)), pg_temp.u('11'), 'sino el espacio');
select is(pg_temp.ins(21, 'ENTREVISTA', 1, p_espacio => null), '23502', 'sin persona y sin espacio no entra');
select is(pg_temp.ins(22, 'ENTREVISTA', 1, p_espacio => 'ff'), '23503', 'un espacio que no existe se rechaza');
select is(pg_temp.ins(23, 'ENTREVISTA', 1, p_persona => '21', p_espacio => null), 'ok',
          'con persona y sin espacio (el teléfono que todavía no lo manda) entra');
select is((select espacio_id from public.agenda where id = pg_temp.ua(23)), pg_temp.u('11'),
          'y toma el espacio de su vínculo');
select is(pg_temp.ins(24, 'ENTREVISTA', 1, p_persona => '21', p_espacio => '14'), 'ok',
          'con persona y otro espacio, entra');
select is((select espacio_id from public.agenda where id = pg_temp.ua(24)), pg_temp.u('11'),
          'pero el espacio es el de su vínculo, no el que llegó');
select is(pg_temp.ins(25, 'ENTREVISTA', 1, p_persona => 'ff', p_espacio => '11'), '23503', 'un vínculo que no existe se rechaza');
select lives_ok($$ update public.agenda set espacio_id = pg_temp.u('14') where id = pg_temp.ua(24) $$,
                'mover el espacio de una cita con persona no falla');
select is((select espacio_id from public.agenda where id = pg_temp.ua(24)), pg_temp.u('11'),
          'y sigue en el de su vínculo');
select lives_ok($$ update public.agenda set espacio_id = pg_temp.u('14') where id = pg_temp.ua(20) $$,
                'una cita sin persona sí cambia de espacio');
select is((select espacio_id from public.agenda where id = pg_temp.ua(20)), pg_temp.u('14'), 'y queda en el nuevo');
select lives_ok($$ update public.agenda set espacio_persona_id = pg_temp.u('23') where id = pg_temp.ua(20) $$,
                'una cita sin persona puede recibir una persona después');
select is((select espacio_id from public.agenda where id = pg_temp.ua(20)), pg_temp.u('13'),
          'y pasa al espacio de ese vínculo');
select lives_ok($$ update public.agenda set espacio_persona_id = null where id = pg_temp.ua(20) $$,
                'y se la puede soltar: la cita queda colgada de la casa');
select is((select espacio_id from public.agenda where id = pg_temp.ua(20)), pg_temp.u('13'), 'en el espacio donde estaba');

select pg_temp.actuar_como(pg_temp.u('b2'));
select is((select count(*)::int from public.agenda where id = pg_temp.ua(20)), 0, 'otro colportor no ve la cita');
select is(pg_temp.ins(26, 'ENTREVISTA', 1, p_quien => 'b1'), '42501', 'ni escribe a nombre de otro');
select pg_temp.actuar_como(pg_temp.u('b1'));

-- ---------------------------------------------------------------------------
-- 4. Lo que origina la cita
-- ---------------------------------------------------------------------------
select is(pg_temp.ins(30, 'COBRANZA', 1, p_venta => '51'), 'ok', 'una cobranza con venta y sin monto entra');
select is((select venta_id from public.agenda where id = pg_temp.ua(30)), pg_temp.u('51'), 'y guarda la venta');
select is(pg_temp.ins(31, 'COBRANZA', 1, p_monto => 1000), '23514', 'un monto previsto sin venta no entra');
select is(pg_temp.ins(32, 'COBRANZA', 1, p_venta => '51', p_monto => 0), '23514', 'ni un monto de cero');
select is(pg_temp.ins(33, 'COBRANZA', 1, p_venta => '51', p_monto => -5), '23514', 'ni negativo');
select is(pg_temp.ins(34, 'ENTREVISTA', 1, p_venta => '51', p_monto => 1000), '23514', 'ni en una entrevista');
select is(pg_temp.ins(35, 'ENTREGA', 1, p_venta => '51', p_monto => 1000), '23514', 'ni en una entrega');
select is(pg_temp.ins(36, 'COBRANZA', 1, p_entrega => '61'), '23514', 'una entrega solo en una cita ENTREGA');
select is(pg_temp.ins(37, 'ENTREVISTA', 1, p_entrega => '61'), '23514', 'ni en una entrevista');
select is(pg_temp.ins(38, 'ENTREGA', 1, p_entrega => '61'), 'ok', 'una cita ENTREGA con su entrega entra');
select is((select entrega_id from public.agenda where id = pg_temp.ua(38)), pg_temp.u('61'), 'y guarda la entrega');
select is(pg_temp.ins(39, 'ENTREGA', 1, p_entrega => '61', p_venta => '51'), 'ok', 'con la venta de esa entrega también');
select is(pg_temp.ins(40, 'ENTREGA', 1), 'ok', 'una cita ENTREGA sin entrega entra (la referencia es opcional)');
select is(pg_temp.ins(41, 'ENTREGA', 1, p_entrega => '63', p_venta => '51'), '23514', 'la entrega de otra venta no va con esa venta');
select is(pg_temp.ins(42, 'COBRANZA', 1, p_venta => 'ff'), '23503', 'una venta que no existe se rechaza');
select is(pg_temp.ins(43, 'ENTREGA', 1, p_entrega => 'ff'), '23503', 'una entrega que no existe se rechaza');
select throws_ok($$ insert into public.agenda (id, espacio_id, tipo, fecha_programada, colportor_id, venta_id)
                    values (pg_temp.ua(44), pg_temp.u('11'), 'COBRANZA', now(), pg_temp.u('b1'), pg_temp.u('52')) $$,
                 '42501', 'Esa venta es de otra persona: no se puede agendar sobre ella.',
                 'colgarle una cita a la venta de otro colportor se rechaza');
select throws_ok($$ insert into public.agenda (id, espacio_id, tipo, fecha_programada, colportor_id, entrega_id)
                    values (pg_temp.ua(45), pg_temp.u('11'), 'ENTREGA', now(), pg_temp.u('b1'), pg_temp.u('62')) $$,
                 '42501', 'Esa entrega es de otra persona: no se puede agendar sobre ella.',
                 'y a la entrega de otro');
select throws_ok($$ insert into public.agenda (id, espacio_id, tipo, fecha_programada, colportor_id, venta_id, monto_previsto)
                    values (pg_temp.ua(46), pg_temp.u('11'), 'COBRANZA', now(), pg_temp.u('b1'), pg_temp.u('52'), 1) $$,
                 '42501', null, 'con un monto no sirve para probar el saldo de una venta ajena');
select is(pg_temp.error_de($$ update public.agenda set venta_id = pg_temp.u('52') where id = pg_temp.ua(30) $$), '42501',
          'ni cambiándola después');
select is(pg_temp.error_de($$ update public.agenda set entrega_id = pg_temp.u('62'), tipo = 'ENTREGA'
                               where id = pg_temp.ua(40) $$), '42501', 'ni la entrega');
select is(pg_temp.error_de($$ update public.agenda set entrega_id = pg_temp.u('63') where id = pg_temp.ua(39) $$), '23514',
          'cambiar a la entrega de otra venta se rechaza');
select is(pg_temp.error_de($$ update public.agenda set monto_previsto = 100 where id = pg_temp.ua(11) $$), '23514',
          'ponerle monto a una entrevista, también');

-- ---------------------------------------------------------------------------
-- 5. Los topes del reparto
-- ---------------------------------------------------------------------------
-- 5a. Hasta 12 cuotas por venta (la 51, de 1000,00, sin cobros).
select is((select count(*)::int from generate_series(1, 12) i where pg_temp.cuota(100 + i, '51', 5000, i) = 'ok'), 12,
          'doce cuotas de una venta entran');
select is((select count(*)::int from public.agenda where venta_id = pg_temp.u('51') and monto_previsto is not null), 12,
          'y quedan doce');
select throws_ok($$ insert into public.agenda (id, espacio_id, tipo, fecha_programada, colportor_id, venta_id, monto_previsto)
                    values (pg_temp.ua(120), pg_temp.u('11'), 'COBRANZA', now(), pg_temp.u('b1'), pg_temp.u('51'), 5000) $$,
                 'AG001', 'Una venta admite hasta 12 cuotas y esta ya las tiene. Cancelá alguna cuota o usá una de las que ya hay.',
                 'la decimotercera se rechaza con un aviso que dice qué hacer');
select is(pg_temp.cuota(121, '53', 5000), 'ok', 'otra venta tiene sus propias doce');
select is(pg_temp.error_de($$ update public.agenda set estado = 'CANCELADA' where id = pg_temp.ua(101) $$), 'ok',
          'cancelar una cuota');
select is(pg_temp.cuota(122, '51', 5000), 'ok', 'libera un lugar: la cancelada no cuenta');
select is(pg_temp.cuota(123, '51', 5000), 'AG001', 'y otra vez completo');
select is(pg_temp.error_de($$ update public.agenda set estado = 'NO_CUMPLIDA' where id = pg_temp.ua(102) $$), 'ok',
          'marcar una cuota como no cumplida');
select is(pg_temp.cuota(124, '51', 5000), 'ok', 'tampoco cuenta');
select is(pg_temp.error_de($$ update public.agenda set estado = 'PROGRAMADA' where id = pg_temp.ua(102) $$), 'AG001',
          'pero volver a programarla con doce vivas se rechaza');
select is(pg_temp.error_de($$ update public.agenda set estado = 'CUMPLIDA' where id = pg_temp.ua(103) $$), 'ok',
          'una cuota cumplida');
select is(pg_temp.cuota(125, '51', 5000), 'AG001', 'sigue contando');
select is(pg_temp.error_de($$ update public.agenda set deleted_at = now() where id = pg_temp.ua(104) $$), 'ok',
          'una cuota dada de baja');
select is(pg_temp.cuota(125, '51', 5000), 'ok', 'libera su lugar');
select is(pg_temp.error_de($$ update public.agenda set deleted_at = null where id = pg_temp.ua(104) $$), 'AG001',
          'reactivarla con doce vivas se rechaza: volver a entrar al plan también cuenta');
select is(pg_temp.ins(126, 'COBRANZA', 1, 'PROGRAMADA', '51', null), 'ok',
          'una cobranza sin monto no es una cuota: no cuenta ni se limita');
select is(pg_temp.error_de($$ insert into public.agenda (id, espacio_id, tipo, fecha_programada, colportor_id, venta_id,
                                                           monto_previsto, deleted_at)
                              values (pg_temp.ua(127), pg_temp.u('11'), 'COBRANZA', now(), pg_temp.u('b1'),
                                      pg_temp.u('51'), 5000, now()) $$), 'ok',
          'una cuota que llega dada de baja se guarda sin mirar los topes');
select is(pg_temp.cuota(128, '51', 5000, 1, 'CANCELADA'), 'ok', 'una que llega cancelada también');
select is(pg_temp.cuota(129, '51', 5000, 1, 'CUMPLIDA'), 'AG001', 'pero una cumplida cuenta como cuota del plan');
-- Otro colportor no se ve afectado por las cuotas de b1.
select pg_temp.actuar_como(pg_temp.u('b2'));
select is(pg_temp.ins(130, 'COBRANZA', 1, 'PROGRAMADA', '52', 5000, p_espacio => '12', p_quien => 'b2'), 'ok',
          'las cuotas de otro colportor son de otra venta');
select pg_temp.actuar_como(pg_temp.u('b1'));

-- 5b. Ninguna cuota supera el saldo (la venta 53: 300,00 menos un cobro de 100,00 = 200,00).
select is(pg_temp.cuota(140, '53', 20000), 'ok', 'una cuota igual al saldo entra');
select is(pg_temp.cuota(141, '53', 20000), 'ok', 'otra igual también: el tope es por cuota');
select throws_ok($$ insert into public.agenda (id, espacio_id, tipo, fecha_programada, colportor_id, venta_id, monto_previsto)
                    values (pg_temp.ua(142), pg_temp.u('11'), 'COBRANZA', now(), pg_temp.u('b1'), pg_temp.u('53'), 20001) $$,
                 'AG002', 'La cuota de 200.01 supera lo que falta cobrar de la venta (200.00). Bajá el monto de la cuota.',
                 'un centavo más que el saldo se rechaza, con el monto y el saldo en el aviso');
select is(pg_temp.cuota(143, '53', 99999999, 1, 'CUMPLIDA'), 'ok', 'una cuota que llega cumplida no se compara con el saldo');
select is(pg_temp.cuota(144, '53', 99999999, 1, 'CANCELADA'), 'ok', 'ni una cancelada');
select is(pg_temp.cuota(145, '53', 99999999, 1, 'NO_CUMPLIDA'), 'ok', 'ni una no cumplida');
select is(pg_temp.error_de($$ update public.agenda set monto_previsto = 20001 where id = pg_temp.ua(140) $$), 'AG002',
          'subir el monto de una cuota programada por encima del saldo se rechaza');
select is(pg_temp.error_de($$ update public.agenda set monto_previsto = 15000 where id = pg_temp.ua(140) $$), 'ok',
          'bajarlo se puede');
select is(pg_temp.error_de($$ update public.agenda set monto_previsto = 20001, venta_id = pg_temp.u('54')
                               where id = pg_temp.ua(140) $$), 'ok', 'o pasarla a una venta con más saldo');
select is(pg_temp.error_de($$ update public.agenda set venta_id = pg_temp.u('53') where id = pg_temp.ua(140) $$), 'AG002',
          'y de vuelta a la de poco saldo, no');
select is(pg_temp.error_de($$ update public.agenda set monto_previsto = 1000, venta_id = pg_temp.u('53') where id = pg_temp.ua(140) $$), 'ok',
          'con un monto que entra, sí');
-- Los cobros bajan el saldo: las cuotas ya agendadas quedan, las nuevas se miden contra lo que falta.
select pg_temp.actuar_como_servidor();
insert into public.cobranza (id, venta_id, monto, medio, fecha, created_by)
values (pg_temp.u('72'), pg_temp.u('53'), 15000, 'EFECTIVO', now(), pg_temp.u('b1'));
select pg_temp.actuar_como(pg_temp.u('b1'));
select is(pg_temp.cuota(146, '53', 5001), 'AG002', 'con otro cobro de 150,00 el saldo es 50,00 y una de 50,01 no entra');
select is(pg_temp.cuota(147, '53', 5000), 'ok', 'una de 50,00 sí');
select is(pg_temp.error_de($$ update public.agenda set fecha_programada = fecha_programada + interval '1 day'
                               where id = pg_temp.ua(141) $$), 'ok',
          'mover la fecha de una cuota de 200,00 que ya estaba no se vuelve a medir');
select is(pg_temp.error_de($$ update public.agenda set estado = 'CUMPLIDA' where id = pg_temp.ua(141) $$), 'ok',
          'ni cumplirla');
select is(pg_temp.error_de($$ update public.agenda set estado = 'PROGRAMADA' where id = pg_temp.ua(145) $$), 'AG002',
          'reprogramar una no cumplida por más del saldo se rechaza');
select pg_temp.actuar_como_servidor();
update public.cobranza set deleted_at = now() where id = pg_temp.u('72');
select pg_temp.actuar_como(pg_temp.u('b1'));
select is(pg_temp.cuota(148, '53', 20000), 'ok', 'un cobro dado de baja vuelve a sumar al saldo');
select pg_temp.actuar_como_servidor();
insert into public.cobranza (id, venta_id, monto, medio, fecha, created_by)
values (pg_temp.u('73'), pg_temp.u('55'), 20000, 'EFECTIVO', now(), pg_temp.u('b1'));
select pg_temp.actuar_como(pg_temp.u('b1'));
select throws_ok($$ insert into public.agenda (id, espacio_id, tipo, fecha_programada, colportor_id, venta_id, monto_previsto)
                    values (pg_temp.ua(149), pg_temp.u('11'), 'COBRANZA', now(), pg_temp.u('b1'), pg_temp.u('55'), 1) $$,
                 'AG002', 'La cuota de 0.01 supera lo que falta cobrar de la venta (0.00). Bajá el monto de la cuota.',
                 'una venta ya saldada no admite cuotas nuevas');
select pg_temp.actuar_como_servidor();
insert into public.cobranza (id, venta_id, monto, medio, fecha, created_by)
values (pg_temp.u('74'), pg_temp.u('55'), 5000, 'EFECTIVO', now(), pg_temp.u('b1'));
select pg_temp.actuar_como(pg_temp.u('b1'));
select throws_ok($$ insert into public.agenda (id, espacio_id, tipo, fecha_programada, colportor_id, venta_id, monto_previsto)
                    values (pg_temp.ua(150), pg_temp.u('11'), 'COBRANZA', now(), pg_temp.u('b1'), pg_temp.u('55'), 1) $$,
                 'AG002', 'La cuota de 0.01 supera lo que falta cobrar de la venta (0.00). Bajá el monto de la cuota.',
                 'y cobrada de más, el saldo se muestra en cero, no negativo');

-- 5c. El día de creación (la venta 54, de 10000,00, sin límite de cuotas a la vista).
select is(pg_temp.cuota(160, '54', 1000, 0), 'ok', 'una cuota de hoy entra');
select is(pg_temp.cuota(161, '54', 1000, 5), 'ok', 'una de más adelante también');
select throws_ok($$ insert into public.agenda (id, espacio_id, tipo, fecha_programada, colportor_id, venta_id, monto_previsto)
                    values (pg_temp.ua(162), pg_temp.u('11'), 'COBRANZA', pg_temp.dia(-1), pg_temp.u('b1'), pg_temp.u('54'), 1000) $$,
                 'AG003', 'La cuota tiene una fecha que ya pasó. Elegí hoy o un día más adelante.',
                 'una cuota con el día de ayer se rechaza');
select is(pg_temp.cuota(163, '54', 1000, -400), 'AG003', 'y una de hace un año');
select is(pg_temp.cuota(164, '54', 1000, -1, 'CUMPLIDA'), 'ok', 'una cumplida con fecha pasada es un cobro que ya se hizo: entra');
select is(pg_temp.cuota(165, '54', 1000, -1, 'NO_CUMPLIDA'), 'ok', 'una no cumplida, también');
select is(pg_temp.cuota(166, '54', 1000, -1, 'CANCELADA'), 'ok', 'y una cancelada');
select is(pg_temp.ins(167, 'COBRANZA', -1, 'PROGRAMADA', '54'), 'ok', 'una cobranza sin monto no es una cuota: la fecha no se mira');
select is(pg_temp.ins(168, 'ENTREVISTA', -1), 'ok', 'ni una entrevista');
-- Un teléfono sin conexión: la cuota se creó hace tres días para anteayer... no, para hoy de aquel día.
select is(pg_temp.ins(169, 'COBRANZA', -2, 'PROGRAMADA', '54', 1000, p_creada => now() - interval '3 days'), 'ok',
          'creada hace tres días para hace dos: sube hoy sin perderse (se compara con el día en que se creó)');
select is(pg_temp.ins(170, 'COBRANZA', -4, 'PROGRAMADA', '54', 1000, p_creada => now() - interval '3 days'), 'AG003',
          'pero no una creada hace tres días para hace cuatro');
select is(pg_temp.ins(171, 'COBRANZA', -3, 'PROGRAMADA', '54', 1000, p_creada => now() - interval '3 days'), 'ok',
          'el mismo día en que se creó, entra (hoy)');
select is(pg_temp.error_de($$ update public.agenda set fecha_programada = pg_temp.dia(-10) where id = pg_temp.ua(160) $$), 'ok',
          'mover una cuota existente a una fecha pasada no se mira (la regla es al crearla)');
select is(pg_temp.error_de($$ update public.agenda set estado = 'NO_CUMPLIDA' where id = pg_temp.ua(160) $$), 'ok', 'y su estado cambia');
select is(pg_temp.error_de($$ update public.agenda set estado = 'PROGRAMADA' where id = pg_temp.ua(160) $$), 'ok',
          'y reprogramarla tampoco mira el día');

-- ---------------------------------------------------------------------------
-- 6. Por sync_push
-- ---------------------------------------------------------------------------
select is(pg_temp.resultados(pg_temp.push(jsonb_build_array(
            pg_temp.job('b1', 'agenda', pg_temp.payload_cita(200, 'ENTREVISTA', 1, 'PROGRAMADA', '11', null, null, null)),
            pg_temp.job('b2', 'agenda', pg_temp.payload_cita(201, 'ENTREVISTA', 1, 'PROGRAMADA', null, '21', null, null)),
            pg_temp.job('b3', 'agenda', pg_temp.payload_cita(202, 'COBRANZA', 1, 'PROGRAMADA', '11', null, '53', 20000))
          ))), array['accepted', 'accepted', 'accepted'],
          'sin persona, con persona y sin espacio (el teléfono viejo) y una cuota: las tres entran');
select is((select espacio_persona_id is null and espacio_id = pg_temp.u('11') from public.agenda where id = pg_temp.ua(200)),
          true, 'la cita sin persona quedó en la casa');
select is((select espacio_id from public.agenda where id = pg_temp.ua(201)), pg_temp.u('11'),
          'la que no mandó espacio toma el de su vínculo');
select is((select monto_previsto from public.agenda where id = pg_temp.ua(202)), 20000, 'y la cuota guarda su monto previsto');

with r as (select pg_temp.push(jsonb_build_array(
            pg_temp.job('c1', 'agenda', pg_temp.payload_cita(210, 'COBRANZA', 1, 'PROGRAMADA', '11', null, '53', 20001)),
            pg_temp.job('c2', 'agenda', pg_temp.payload_cita(211, 'ENTREVISTA', 1, 'PROGRAMADA', '11', null, null, null)),
            pg_temp.job('c3', 'agenda', pg_temp.payload_cita(212, 'COBRANZA', 1, 'PROGRAMADA', '11', null, '51', 5000)),
            pg_temp.job('c4', 'agenda', pg_temp.payload_cita(213, 'COBRANZA', -1, 'PROGRAMADA', '11', null, '54', 1000)),
            pg_temp.job('c5', 'agenda', pg_temp.payload_cita(214, 'COBRANZA', 1, 'PROGRAMADA', '11', null, '52', 100)),
            pg_temp.job('c6', 'agenda', pg_temp.payload_cita(215, 'ENTREVISTA', 1, 'PENDIENTE', '11', null, null, null)),
            pg_temp.job('c7', 'agenda', pg_temp.payload_cita(216, 'COBRANZA', 0, 'PROGRAMADA', '11', null, '54', 1000))
          )) as r)
select is(pg_temp.resultados((select r from r)), array['invalid', 'accepted', 'invalid', 'invalid', 'invalid', 'invalid', 'accepted'],
          'los topes y las reglas vuelven invalid sin tumbar el lote: lo bueno de antes y de después entra');
select is(pg_temp.resultados(pg_temp.push(jsonb_build_array(
            pg_temp.job('c1', 'agenda', pg_temp.payload_cita(210, 'COBRANZA', 1, 'PROGRAMADA', '11', null, '53', 20001))))),
          array['invalid'::text], 'el reintento de un invalid se evalúa de nuevo (no es un duplicado)');
select is(pg_temp.codigos(pg_temp.push(jsonb_build_array(
            pg_temp.job('c1', 'agenda', pg_temp.payload_cita(210, 'COBRANZA', 1, 'PROGRAMADA', '11', null, '53', 20001)),
            pg_temp.job('c3', 'agenda', pg_temp.payload_cita(212, 'COBRANZA', 1, 'PROGRAMADA', '11', null, '51', 5000)),
            pg_temp.job('c4', 'agenda', pg_temp.payload_cita(213, 'COBRANZA', -1, 'PROGRAMADA', '11', null, '54', 1000)),
            pg_temp.job('c5', 'agenda', pg_temp.payload_cita(214, 'COBRANZA', 1, 'PROGRAMADA', '11', null, '52', 100)),
            pg_temp.job('c6', 'agenda', pg_temp.payload_cita(215, 'ENTREVISTA', 1, 'PENDIENTE', '11', null, null, null))
          ))),
          array['AG002', 'AG001', 'AG003', '42501', '23514'],
          'con su código: saldo (AG002), 12 cuotas (AG001), día pasado (AG003), venta ajena (42501) y estado viejo (23514)');
select is((select count(*)::int from public.agenda where id in (pg_temp.ua(210), pg_temp.ua(212), pg_temp.ua(213),
                                                                pg_temp.ua(214), pg_temp.ua(215))), 0,
          'y ninguna quedó a medias');
select is((select message is not null from jsonb_to_recordset(pg_temp.push(jsonb_build_array(
            pg_temp.job('c1', 'agenda', pg_temp.payload_cita(210, 'COBRANZA', 1, 'PROGRAMADA', '11', null, '53', 20001)))) -> 'results')
            as x(message text)), true, 'el mensaje del invalid viaja, para que la app lo muestre');

-- 6b. Lo que sube el teléfono: la fila ENTERA en cada update, y el reenvío de altas (rev 148).
-- La venta 56 (200,00) con dos cuotas de 100,00. Después entra un cobro de 150,00: la primera se cumple
-- y la segunda queda en 100,00 con un saldo de 50,00 (las cuotas ya agendadas quedan).
select pg_temp.actuar_como_servidor();
insert into public.venta (id, espacio_persona_id, numero_talonario, monto_total, fecha, colportor_id, created_by)
values (pg_temp.u('56'), pg_temp.u('21'), 'T-56', 20000, now(), pg_temp.u('b1'), pg_temp.u('b1'));
select pg_temp.actuar_como(pg_temp.u('b1'));
create or replace function pg_temp.job_update(p_op text, p_id integer, p_payload jsonb) returns jsonb language sql as $$
  select jsonb_build_object('client_op_id', pg_temp.u(p_op), 'entity', 'agenda', 'op', 'update',
                            'sync_version', (select a.sync_version from public.agenda a where a.id = pg_temp.ua(p_id)),
                            'payload', p_payload);
$$;
-- La fila entera de una cita, con los cambios de p_cambios encima (lo que escribe el encolador del móvil).
create or replace function pg_temp.fila_entera(p_id integer, p_cambios jsonb default '{}') returns jsonb language sql as $$
  select jsonb_build_object('id', a.id, 'tipo', a.tipo, 'fecha_programada', a.fecha_programada, 'estado', a.estado,
                            'espacio_id', a.espacio_id, 'espacio_persona_id', a.espacio_persona_id,
                            'venta_id', a.venta_id, 'entrega_id', a.entrega_id, 'monto_previsto', a.monto_previsto,
                            'created_at', a.created_at, 'deleted_at', a.deleted_at) || p_cambios
    from public.agenda a where a.id = pg_temp.ua(p_id);
$$;
select is(pg_temp.resultados(pg_temp.push(jsonb_build_array(
            pg_temp.job('e1', 'agenda', pg_temp.payload_cita(400, 'COBRANZA', 1, 'PROGRAMADA', '11', null, '56', 10000)),
            pg_temp.job('e2', 'agenda', pg_temp.payload_cita(401, 'COBRANZA', 2, 'PROGRAMADA', '11', null, '56', 10000))
          ))), array['accepted', 'accepted'], 'dos cuotas de 100,00 de una venta de 200,00 entran');
select pg_temp.actuar_como_servidor();
insert into public.cobranza (id, venta_id, monto, medio, fecha, created_by)
values (pg_temp.u('75'), pg_temp.u('56'), 15000, 'EFECTIVO', now(), pg_temp.u('b1'));
select pg_temp.actuar_como(pg_temp.u('b1'));
select is(pg_temp.resultados(pg_temp.push(jsonb_build_array(
            pg_temp.job_update('e3', 400, pg_temp.fila_entera(400, '{"estado": "CUMPLIDA"}'))))),
          array['accepted'], 'la primera cuota se cumple (fila entera)');
select is(pg_temp.resultados(pg_temp.push(jsonb_build_array(
            pg_temp.job_update('e4', 401, pg_temp.fila_entera(401, jsonb_build_object(
              'fecha_programada', pg_temp.dia(9))))))),
          array['accepted'], 'mover la fecha de la segunda (100,00 sobre un saldo de 50,00) con la fila entera NO se vuelve a medir');
select is((select fecha_programada from public.agenda where id = pg_temp.ua(401)), pg_temp.dia(9), 'y la fecha cambió');
select is(pg_temp.codigos(pg_temp.push(jsonb_build_array(
            pg_temp.job_update('e5', 401, pg_temp.fila_entera(401, '{"monto_previsto": 10001}'))))),
          array['AG002'], 'subir su monto con la fila entera sí se mide');
select is(pg_temp.resultados(pg_temp.push(jsonb_build_array(
            pg_temp.job_update('e6', 401, pg_temp.fila_entera(401, '{"monto_previsto": 5000}'))))),
          array['accepted'], 'y bajarlo hasta el saldo entra');
select is(pg_temp.resultados(pg_temp.push(jsonb_build_array(
            pg_temp.job_update('e7', 401, pg_temp.fila_entera(401, jsonb_build_object(
              'estado', 'CANCELADA', 'fecha_programada', pg_temp.dia(10))))))),
          array['accepted'], 'cancelarla con la fila entera entra');
select is(pg_temp.codigos(pg_temp.push(jsonb_build_array(
            pg_temp.job_update('e8', 401, pg_temp.fila_entera(401, '{"estado": "PROGRAMADA", "monto_previsto": 5001}'))))),
          array['AG002'], 'reprogramarla por más del saldo se mide');
-- El reenvío de un alta que ya está es un duplicate aunque el saldo haya bajado (contrato §7).
select is(pg_temp.resultados(pg_temp.push(jsonb_build_array(
            pg_temp.job('e9', 'agenda', pg_temp.payload_cita(400, 'COBRANZA', 1, 'PROGRAMADA', '11', null, '56', 10000))))),
          array['duplicate'], 'reenviar el alta de la cuota 400 (otro client_op_id; hoy el saldo es 50,00) es duplicate');
select is(pg_temp.resultados(pg_temp.push(jsonb_build_array(
            pg_temp.job('e9', 'agenda', pg_temp.payload_cita(400, 'COBRANZA', 1, 'PROGRAMADA', '11', null, '56', 10000))))),
          array['duplicate'], 'y el mismo client_op_id otra vez también');
select is(pg_temp.resultados(pg_temp.push(jsonb_build_array(
            pg_temp.job('ea', 'agenda', pg_temp.payload_cita(402, 'COBRANZA', 1, 'PROGRAMADA', '11', null, '56', 10000))))),
          array['invalid'], 'una cuota nueva por más del saldo sigue siendo invalid');
select is((select count(*)::int from public.agenda where id = pg_temp.ua(400)), 1, 'y el reenvío no duplicó la fila');
select is((select estado from public.agenda where id = pg_temp.ua(400)), 'CUMPLIDA', 'ni pisó lo que ya tenía (cumplida)');
select is(pg_temp.ins(403, 'COBRANZA', 1, 'PROGRAMADA', '56', 10000), 'AG002', 'por SQL, una cuota nueva por más del saldo se rechaza');

-- ---------------------------------------------------------------------------
-- 7. entrega.fecha_prevista
-- ---------------------------------------------------------------------------
select lives_ok($$ update public.entrega set fecha_prevista = pg_temp.dia(7) where id = pg_temp.u('61') $$,
                'una entrega recibe su fecha prevista');
select is((select fecha_prevista from public.entrega where id = pg_temp.u('61')), pg_temp.dia(7), 'y queda');
select is((select fecha_entrega from public.entrega where id = pg_temp.u('61')), null, 'la fecha real sigue vacía mientras no se entrega');
select lives_ok($$ update public.entrega set fecha_entrega = pg_temp.dia(8), pendiente = false where id = pg_temp.u('61') $$,
                'al entregar se guarda la real');
select is((select fecha_prevista = pg_temp.dia(7) and fecha_entrega = pg_temp.dia(8) and not pendiente
             from public.entrega where id = pg_temp.u('61')), true, 'y la prevista no cambia');
select is(pg_temp.resultados(pg_temp.push(jsonb_build_array(
            pg_temp.job('d1', 'entrega', jsonb_build_object('id', pg_temp.u('64'), 'venta_id', pg_temp.u('53'),
                          'producto_id', pg_temp.u('d1'), 'cantidad', 2, 'pendiente', true,
                          'fecha_prevista', pg_temp.dia(3)))))), array['accepted'],
          'el teléfono sube la entrega con su fecha prevista');
select is((select fecha_prevista from public.entrega where id = pg_temp.u('64')), pg_temp.dia(3), 'y llega');
select is(pg_temp.resultados(pg_temp.push(jsonb_build_array(
            pg_temp.job('d2', 'agenda', jsonb_build_object('id', pg_temp.ua(220), 'tipo', 'ENTREGA',
                          'fecha_programada', pg_temp.dia(3), 'estado', 'PROGRAMADA', 'espacio_id', pg_temp.u('11'),
                          'espacio_persona_id', pg_temp.u('21'), 'entrega_id', pg_temp.u('64')))))), array['accepted'],
          'y su cita de entrega, atada a la entrega');
select is((select entrega_id from public.agenda where id = pg_temp.ua(220)), pg_temp.u('64'), 'que guarda su origen');

-- ---------------------------------------------------------------------------
-- 8. Cuando dos casas se unen
-- ---------------------------------------------------------------------------
-- b1 marca la 02 (de b2, espacio único 12) como duplicado de la 01 (espacio único 11). Antes, una cita
-- de b1 sin persona colgada del espacio 12, una de b1 con persona en el vínculo 22 y una de b2 también.
select pg_temp.actuar_como_servidor();
insert into public.agenda (id, espacio_persona_id, espacio_id, tipo, fecha_programada, colportor_id) values
  (pg_temp.ua(300), null,            pg_temp.u('12'), 'ENTREVISTA', now(), pg_temp.u('b1')),
  (pg_temp.ua(301), pg_temp.u('22'), pg_temp.u('12'), 'ENTREVISTA', now(), pg_temp.u('b1')),
  (pg_temp.ua(302), null,            pg_temp.u('12'), 'ENTREGA',    now(), pg_temp.u('b2')),
  (pg_temp.ua(303), null,            pg_temp.u('13'), 'ENTREVISTA', now(), pg_temp.u('b1'));
select pg_temp.actuar_como(pg_temp.u('b1'));
select lives_ok($$ select public.marcar_como_duplicado(pg_temp.u('02'), pg_temp.u('01')) $$, 'b1 une la casa 02 a la 01');
select pg_temp.actuar_como_servidor();
select is((select espacio_id from public.agenda where id = pg_temp.ua(300)), pg_temp.u('11'),
          'la cita sin persona pasó al espacio de A');
select is((select espacio_persona_id from public.agenda where id = pg_temp.ua(300)), null, 'y sigue sin persona');
select is((select espacio_id from public.agenda where id = pg_temp.ua(302)), pg_temp.u('11'),
          'la de otro colportor también');
select is((select espacio_persona_id::text || '/' || espacio_id::text from public.agenda where id = pg_temp.ua(301)),
          pg_temp.u('21')::text || '/' || pg_temp.u('11')::text,
          'la que tenía persona pasa al vínculo de A y a su espacio');
select is((select espacio_id from public.agenda where id = pg_temp.ua(303)), pg_temp.u('13'), 'una de otro espacio no se toca');
select is((select count(*)::int from public.agenda where espacio_id = pg_temp.u('12')), 0,
          'no queda ninguna cita en el espacio fundido');
select pg_temp.actuar_como(pg_temp.u('b1'));
select is(pg_temp.ins(310, 'ENTREVISTA', 1, p_espacio => '12'), 'ok', 'una cita que llega tarde al espacio fundido entra');
select is((select espacio_id from public.agenda where id = pg_temp.ua(310)), pg_temp.u('11'), 'y se guarda en el de A');
select is(pg_temp.ins(311, 'ENTREVISTA', 1, p_persona => '22', p_espacio => '12'), 'ok',
          'una con el vínculo fundido también entra');
select is((select espacio_persona_id::text || '/' || espacio_id::text from public.agenda where id = pg_temp.ua(311)),
          pg_temp.u('21')::text || '/' || pg_temp.u('11')::text, 'en el vínculo y el espacio de A');

select * from finish();
rollback;
