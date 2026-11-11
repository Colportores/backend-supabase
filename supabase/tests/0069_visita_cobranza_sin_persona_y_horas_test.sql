-- pgTAP · migración 0069 (backend-supabase#132, decisiones de Cristian del 23/10): la visita acepta el
-- resultado COBRANZA, puede ir sin persona y guarda la hora de entrada y de salida de la entrevista.
--   1. La forma: columnas nuevas (espacio_id, entrevista_entrada, entrevista_salida), NOT NULL / opcional,
--      orden de los triggers, privilegios y que la RLS sigue siendo solo la de la dueña.
--   2. Los cinco resultados; COBRANZA entra, uno inventado o en minúsculas no.
--   3. Visita sin persona: cuelga del espacio; con persona, el espacio es el de su vínculo.
--   4. Las horas de la entrevista: opcionales, la salida no es anterior a la entrada.
--   5. Solo la dueña las lee (otro colportor y el coordinador no ven la visita).
--   6. Por sync_push: la visita sin persona, la cobranza y las horas entran; lo malo vuelve invalid sin
--      tumbar el lote; el pull lleva las columnas nuevas.
--   7. COBRANZA no es una presentación: ni el tablero de Inicio ni el reporte de ventas la cuentan.
--   8. Cuando dos casas se unen, las visitas (con o sin persona) siguen al espacio de A; si un vínculo cambia
--      de espacio, sus visitas lo siguen.
--   9. La baja de una casa con una visita sin persona de otro colportor (UB002).
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
  select ('01920000-0000-7000-8000-0000000069' || p)::uuid;
$$;
-- El id de una visita (n hasta 65535, sin chocar con u()).
create or replace function pg_temp.uv(p_n integer) returns uuid language sql as $$
  select ('01920000-0000-7000-8000-00000069' || lpad(to_hex(p_n), 4, '0'))::uuid;
$$;
create or replace function pg_temp.hoy() returns date language sql stable as $$
  select (now() at time zone 'America/Montevideo')::date
$$;
-- Un instante de hoy en Montevideo.
create or replace function pg_temp.a(p_hora time) returns timestamptz language sql stable as $$
  select (pg_temp.hoy() + p_hora) at time zone 'America/Montevideo'
$$;
create or replace function pg_temp.error_de(p_sql text) returns text language plpgsql as $$
begin
  execute p_sql;
  return 'ok';
exception when others then
  return sqlstate;
end $$;
-- Una visita tal como la inserta el teléfono: 'ok' o el SQLSTATE. El espacio por defecto es el 11; pasar
-- null lo quita.
create or replace function pg_temp.ins(
  p_id integer, p_resultado text, p_persona text default null, p_espacio text default '11',
  p_quien text default 'b1', p_entrada timestamptz default null, p_salida timestamptz default null)
returns text language plpgsql as $$
begin
  insert into public.visita (id, espacio_persona_id, espacio_id, fecha, tipo_resultado, colportor_id,
                             entrevista_entrada, entrevista_salida)
  values (pg_temp.uv(p_id), pg_temp.u(p_persona), pg_temp.u(p_espacio), now(), p_resultado,
          pg_temp.u(p_quien), p_entrada, p_salida);
  return 'ok';
exception when others then
  return sqlstate;
end $$;
create or replace function pg_temp.sobre() returns jsonb language sql as $$
  select jsonb_build_object('device_id', '01920000-0000-7000-8000-0000000069d0',
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
-- La fila de una visita tal como la serializa el pull (la expresión que arma sync.pull).
create or replace function pg_temp.fila_del_pull(p_id uuid) returns jsonb language plpgsql as $$
declare
  v_fila jsonb;
begin
  execute format('select %s from public.visita t where t.id = $1', sync.expresion_json('public.visita'::regclass))
     into v_fila using p_id;
  return v_fila;
end $$;
-- El payload de una visita como lo sube el teléfono (sin las columnas del servidor).
create or replace function pg_temp.payload_visita(p_id integer, p_resultado text, p_espacio text, p_persona text,
                                                  p_entrada timestamptz default null, p_salida timestamptz default null)
returns jsonb language sql as $$
  select jsonb_strip_nulls(jsonb_build_object(
    'id', pg_temp.uv(p_id), 'fecha', now(), 'tipo_resultado', p_resultado,
    'espacio_id', pg_temp.u(p_espacio), 'espacio_persona_id', pg_temp.u(p_persona),
    'entrevista_entrada', p_entrada, 'entrevista_salida', p_salida, 'created_at', now()));
$$;

-- --- fixtures (como postgres) --------------------------------------------------
-- b1 y b2 colportores inscriptos (sin zona) en la campaña e1 (en curso) de la ciudad c1; b3 inscripto en la
-- zona d2 (para los tableros); d1 coordinador de e1.
-- Ubicaciones: 01 (casa de b1, espacio único 11), 02 (casa de b2, espacio único 12), 03 (edificio con los
-- deptos 13 y 14), 04 (casa de b1, espacio 15, para la baja), 05 (casa de b1, espacio 16, para la baja).
-- Vínculos: 21 (persona p1 en 11), 22 (p1 en 12, de b2), 23 (p2 en el depto 13).
insert into auth.users (id, instance_id, aud, role, email, encrypted_password, confirmed_at, created_at, updated_at)
select pg_temp.u(s), '00000000-0000-0000-0000-000000000000',
       'authenticated', 'authenticated', 'visita69-' || s || '@example.com', 'x', now(), now(), now()
  from unnest(array['b1','b2','b3','d1']) s;
insert into public.usuario_rol (usuario_id, rol_id)
select pg_temp.u(x.s), r.id
  from (values ('d1', 'COORDINADOR'), ('b1', 'COLPORTOR'), ('b2', 'COLPORTOR'), ('b3', 'COLPORTOR')) x(s, codigo)
  join public.rol r on r.codigo = x.codigo;
insert into public.pais (id, nombre, iso_code) values (pg_temp.u('c0'), 'Pais visita', 'ZV');
insert into public.ciudad (id, nombre, departamento, pais_id, lat_centro, lon_centro)
values (pg_temp.u('c1'), 'Ciudad visita', 'Departamento de prueba', pg_temp.u('c0'), -34.9, -56.2);
insert into public.campania (id, nombre, tipo, fecha_inicio, fecha_fin, coordinador_id)
values (pg_temp.u('e1'), 'Verano visita', 'VERANO', public.hoy_montevideo() - 10, public.hoy_montevideo() + 30, pg_temp.u('d1'));
insert into public.campania_ciudad (id, campania_id, ciudad_id) values (pg_temp.u('f1'), pg_temp.u('e1'), pg_temp.u('c1'));
insert into public.zona (id, nombre, campania_ciudad_id, tipo_forma, color, poligono_geojson)
values (pg_temp.u('d2'), 'Centro', pg_temp.u('f1'), 'ESQUINAS', '#112233',
        '{"type":"Polygon","coordinates":[[[-56.19,-34.99],[-56.17,-34.99],[-56.17,-34.98],[-56.19,-34.98],[-56.19,-34.99]]]}'::jsonb);
insert into public.campania_colportor (campania_id, usuario_id, zona_id) values
  (pg_temp.u('e1'), pg_temp.u('b1'), null),
  (pg_temp.u('e1'), pg_temp.u('b2'), null),
  (pg_temp.u('e1'), pg_temp.u('b3'), pg_temp.u('d2'));
insert into public.ubicacion (id, tipo, calle, numero, lat, lon, ciudad_id, created_by) values
  (pg_temp.u('01'), 'CASA',     'Visita 01', '1', -34.91, -56.2,  pg_temp.u('c1'), pg_temp.u('b1')),
  (pg_temp.u('02'), 'CASA',     'Visita 02', '2', -34.92, -56.2,  pg_temp.u('c1'), pg_temp.u('b2')),
  (pg_temp.u('03'), 'EDIFICIO', 'Visita 03', '3', -34.93, -56.2,  pg_temp.u('c1'), pg_temp.u('b1')),
  (pg_temp.u('04'), 'CASA',     'Visita 04', '4', -34.94, -56.2,  pg_temp.u('c1'), pg_temp.u('b1')),
  (pg_temp.u('05'), 'CASA',     'Visita 05', '5', -34.95, -56.2,  pg_temp.u('c1'), pg_temp.u('b1'));
insert into public.espacio (id, ubicacion_id, numero_depto, created_by) values
  (pg_temp.u('11'), pg_temp.u('01'), null, pg_temp.u('b1')),
  (pg_temp.u('12'), pg_temp.u('02'), null, pg_temp.u('b2')),
  (pg_temp.u('13'), pg_temp.u('03'), '1',  pg_temp.u('b1')),
  (pg_temp.u('14'), pg_temp.u('03'), '2',  pg_temp.u('b1')),
  (pg_temp.u('15'), pg_temp.u('04'), null, pg_temp.u('b1')),
  (pg_temp.u('16'), pg_temp.u('05'), null, pg_temp.u('b1'));
insert into public.espacio_persona (id, espacio_id, persona_id, created_by) values
  (pg_temp.u('21'), pg_temp.u('11'), pg_temp.u('a1'), pg_temp.u('b1')),
  (pg_temp.u('22'), pg_temp.u('12'), pg_temp.u('a1'), pg_temp.u('b2')),
  (pg_temp.u('23'), pg_temp.u('13'), pg_temp.u('a2'), pg_temp.u('b1'));

-- ---------------------------------------------------------------------------
-- 1. La forma
-- ---------------------------------------------------------------------------
select col_type_is('public', 'visita', 'espacio_id', 'uuid', 'visita.espacio_id es uuid');
select col_not_null('public', 'visita', 'espacio_id', 'y obligatorio: la visita siempre cuelga de un espacio');
select col_is_null('public', 'visita', 'espacio_persona_id', 'la persona es opcional');
select col_type_is('public', 'visita', 'entrevista_entrada', 'timestamp with time zone', 'entrevista_entrada es timestamptz');
select col_is_null('public', 'visita', 'entrevista_entrada', 'y opcional');
select col_type_is('public', 'visita', 'entrevista_salida', 'timestamp with time zone', 'entrevista_salida es timestamptz');
select col_is_null('public', 'visita', 'entrevista_salida', 'y opcional');
select is((select array_agg(tgname::text order by tgname::text collate "C") from pg_trigger
            where tgrelid = 'public.visita'::regclass and not tgisinternal and (tgtype & 4) = 4),
          array['visita_0_union_redirige', 'visita_auditoria_insert'],
          'al insertar corren, en este orden, la unión (espacio) y la auditoría');
select ok(not has_function_privilege('authenticated', 'public.tg_visita_union_redirige()', 'execute')
          and not has_function_privilege('anon', 'public.tg_visita_union_redirige()', 'execute')
          and not has_function_privilege('authenticated', 'public.tg_espacio_persona_mueve_visitas()', 'execute')
          and not has_function_privilege('anon', 'public.tg_espacio_persona_mueve_visitas()', 'execute'),
          'las funciones de los triggers no las ejecuta nadie desde afuera');
select ok((select prosecdef from pg_proc where oid = 'public.tg_visita_union_redirige()'::regprocedure)
          and (select proconfig::text from pg_proc where oid = 'public.tg_visita_union_redirige()'::regprocedure) like '%search_path=%',
          'el trigger de la unión es SECURITY DEFINER con search_path fijo');
select has_index('public', 'visita', 'visita_espacio_idx', 'hay índice por espacio');
select has_trigger('public', 'espacio_persona', 'espacio_persona_mueve_visitas', 'un vínculo que cambia de espacio se lleva sus visitas');
select is((select array_agg(policyname::text order by policyname::text collate "C") from pg_policies
            where schemaname = 'public' and tablename = 'visita' and permissive = 'PERMISSIVE'),
          array['visita_propio'], 'la RLS de visita sigue siendo una sola: la de su dueña (0105 suma solo restrictivas)');
select is((select qual from pg_policies where schemaname = 'public' and tablename = 'visita' and policyname = 'visita_propio'),
          '(colportor_id = ( SELECT auth.uid() AS uid))', 'y lee lo que es suyo y nada más');
select is((select permite_push from sync.entidad where nombre = 'visita'), true, 'la visita sigue en el push');
select ok(sync.expresion_json('public.visita'::regclass) like '%''entrevista_entrada''%'
          and sync.expresion_json('public.visita'::regclass) like '%''entrevista_salida''%'
          and sync.expresion_json('public.visita'::regclass) like '%''espacio_id''%',
          'y el pull lleva las columnas nuevas: un teléfono nuevo no pierde las horas');

-- ---------------------------------------------------------------------------
-- 2. Los resultados
-- ---------------------------------------------------------------------------
select pg_temp.actuar_como(pg_temp.u('b1'));

select is(pg_temp.ins(1, 'VENTA', '21'), 'ok', 'VENTA entra');
select is(pg_temp.ins(2, 'NO_CONTESTO', '21'), 'ok', 'NO_CONTESTO entra');
select is(pg_temp.ins(3, 'RECHAZO', '21'), 'ok', 'RECHAZO entra');
select is(pg_temp.ins(4, 'ENTREVISTA', '21'), 'ok', 'ENTREVISTA entra');
select is(pg_temp.ins(5, 'COBRANZA', '21'), 'ok', 'COBRANZA entra: María no pagó la cuota');
select is((select tipo_resultado from public.visita where id = pg_temp.uv(5)), 'COBRANZA', 'y se guarda como cobranza');
select is(pg_temp.ins(6, 'cobranza', '21'), '23514', 'en minúsculas no');
select is(pg_temp.ins(7, 'COBRO', '21'), '23514', 'ni un resultado inventado');
select is(pg_temp.ins(8, null, '21'), '23502', 'ni sin resultado');
select lives_ok($$ update public.visita set tipo_resultado = 'COBRANZA' where id = pg_temp.uv(2) $$,
                'una visita de antes puede quedar como cobranza');
select is(pg_temp.error_de($$ update public.visita set tipo_resultado = 'OTRO' where id = pg_temp.uv(2) $$), '23514',
          'pero no como cualquier cosa');

-- ---------------------------------------------------------------------------
-- 3. Visita sin persona
-- ---------------------------------------------------------------------------
select is(pg_temp.ins(20, 'NO_CONTESTO'), 'ok', '«No contestó» sin elegir a nadie: la visita cuelga del espacio');
select is((select espacio_persona_id from public.visita where id = pg_temp.uv(20)), null, 'y no tiene persona');
select is((select espacio_id from public.visita where id = pg_temp.uv(20)), pg_temp.u('11'), 'sino el espacio');
select is(pg_temp.ins(21, 'NO_CONTESTO', p_espacio => null), '23502', 'sin persona y sin espacio no entra');
select is(pg_temp.ins(22, 'NO_CONTESTO', p_espacio => 'ff'), '23503', 'un espacio que no existe se rechaza');
select is(pg_temp.ins(23, 'ENTREVISTA', '21', p_espacio => null), 'ok',
          'con persona y sin espacio (el teléfono que todavía no lo manda) entra');
select is((select espacio_id from public.visita where id = pg_temp.uv(23)), pg_temp.u('11'),
          'y toma el espacio de su vínculo');
select is(pg_temp.ins(24, 'ENTREVISTA', '21', p_espacio => '14'), 'ok', 'con persona y otro espacio, entra');
select is((select espacio_id from public.visita where id = pg_temp.uv(24)), pg_temp.u('11'),
          'pero el espacio es el de su vínculo, no el que llegó');
select is(pg_temp.ins(25, 'ENTREVISTA', 'ff', p_espacio => '11'), '23503', 'un vínculo que no existe se rechaza');
select is(pg_temp.ins(28, 'ENTREVISTA', 'ff', p_espacio => null), '23503',
          'también sin espacio: es el error de clave foránea (el push deja en espera lo que cuelga de un alta en conflicto), no un NOT NULL');
select lives_ok($$ update public.visita set espacio_id = pg_temp.u('14') where id = pg_temp.uv(24) $$,
                'mover el espacio de una visita con persona no falla');
select is((select espacio_id from public.visita where id = pg_temp.uv(24)), pg_temp.u('11'),
          'y sigue en el de su vínculo');
select lives_ok($$ update public.visita set espacio_id = pg_temp.u('14') where id = pg_temp.uv(20) $$,
                'una visita sin persona sí cambia de espacio');
select is((select espacio_id from public.visita where id = pg_temp.uv(20)), pg_temp.u('14'), 'y queda en el nuevo');
select lives_ok($$ update public.visita set espacio_persona_id = pg_temp.u('23') where id = pg_temp.uv(20) $$,
                'una visita sin persona puede recibir una persona después');
select is((select espacio_id from public.visita where id = pg_temp.uv(20)), pg_temp.u('13'),
          'y pasa al espacio de ese vínculo');
select lives_ok($$ update public.visita set espacio_persona_id = null where id = pg_temp.uv(20) $$,
                'y se la puede soltar: la visita queda colgada de la casa');
select is((select espacio_id from public.visita where id = pg_temp.uv(20)), pg_temp.u('13'), 'en el espacio donde estaba');
select is(pg_temp.ins(26, 'COBRANZA'), 'ok', 'una visita de cobranza también va sin persona');
select is(pg_temp.ins(27, 'ENTREVISTA', p_quien => 'b2'), '42501', 'nadie escribe a nombre de otro');

-- ---------------------------------------------------------------------------
-- 4. Las horas de la entrevista
-- ---------------------------------------------------------------------------
select is(pg_temp.ins(30, 'ENTREVISTA', '21', p_entrada => pg_temp.a('14:00'), p_salida => pg_temp.a('14:22')), 'ok',
          'Ana toca «Empezar» y «Finalizar» en lo de Pedro: entrada y salida entran');
select is((select (extract(epoch from entrevista_salida - entrevista_entrada) / 60)::int
             from public.visita where id = pg_temp.uv(30)), 22, 'y el historial puede mostrar cuánto duró: 22 minutos');
select is(pg_temp.ins(31, 'ENTREVISTA', '21', p_entrada => pg_temp.a('14:00'), p_salida => pg_temp.a('14:00')), 'ok',
          'una entrevista de cero minutos entra (la salida no es anterior)');
select is(pg_temp.ins(32, 'ENTREVISTA', '21', p_entrada => pg_temp.a('14:00'), p_salida => pg_temp.a('13:59')), '23514',
          'la salida antes de la entrada no entra');
select is(pg_temp.ins(33, 'ENTREVISTA', '21', p_entrada => pg_temp.a('14:00')), 'ok', 'solo la entrada entra (entrevista en curso)');
select is(pg_temp.ins(34, 'ENTREVISTA', '21', p_salida => pg_temp.a('14:00')), 'ok', 'solo la salida entra: nada se inventa');
select is(pg_temp.ins(35, 'ENTREVISTA', '21'), 'ok', 'sin horas entra');
select is((select entrevista_entrada is null and entrevista_salida is null from public.visita where id = pg_temp.uv(35)),
          true, 'y quedan en null');
select is(pg_temp.ins(36, 'VENTA', null, p_entrada => pg_temp.a('15:00'), p_salida => pg_temp.a('15:40')), 'ok',
          'una entrevista que terminó en venta, sin persona, también guarda las horas');
select lives_ok($$ update public.visita set entrevista_salida = pg_temp.a('14:40') where id = pg_temp.uv(30) $$,
                'Ana corrige la salida');
select is(pg_temp.error_de($$ update public.visita set entrevista_salida = pg_temp.a('13:00') where id = pg_temp.uv(30) $$),
          '23514', 'pero no antes de la entrada');
select is(pg_temp.error_de($$ update public.visita set entrevista_entrada = pg_temp.a('15:00') where id = pg_temp.uv(30) $$),
          '23514', 'ni la entrada después de la salida');
select lives_ok($$ update public.visita set entrevista_entrada = null where id = pg_temp.uv(30) $$,
                'y se puede soltar una hora');
select is((select entrevista_salida from public.visita where id = pg_temp.uv(30)), pg_temp.a('14:40'), 'la otra queda');

-- ---------------------------------------------------------------------------
-- 5. Solo la dueña las lee
-- ---------------------------------------------------------------------------
select is((select count(*)::int from public.visita where id in (pg_temp.uv(30), pg_temp.uv(5), pg_temp.uv(26))), 3,
          'b1 ve sus visitas, con horas, cobranza y sin persona');
select pg_temp.actuar_como(pg_temp.u('b2'));
select is((select count(*)::int from public.visita where id in (pg_temp.uv(30), pg_temp.uv(5), pg_temp.uv(26))), 0,
          'otro colportor no ve ninguna');
select is(pg_temp.error_de($$ update public.visita set entrevista_salida = null where id = pg_temp.uv(30) $$), 'ok',
          'y borrarle la hora no cambia nada: no la ve (0 filas)');
select is((select entrevista_salida from public.visita where id = pg_temp.uv(30)), null, 'ni la lee');
select pg_temp.actuar_como(pg_temp.u('d1'));
select is((select count(*)::int from public.visita), 0, 'el coordinador de la campaña no ve ninguna visita ni sus horas');
select pg_temp.actuar_como_servidor();
select is((select entrevista_salida from public.visita where id = pg_temp.uv(30)), pg_temp.a('14:40'),
          'y la de b1 sigue intacta');
select is((select count(*)::int from pg_attribute a join pg_class c on c.oid = a.attrelid
            where c.relnamespace = 'public'::regnamespace and a.attnum > 0 and not a.attisdropped
              and a.attname in ('entrevista_entrada', 'entrevista_salida') and c.relname <> 'visita'), 0,
          'las horas de la entrevista no están en ninguna otra tabla (ninguna lectura del panel las toca)');

-- ---------------------------------------------------------------------------
-- 6. Por sync_push
-- ---------------------------------------------------------------------------
select pg_temp.actuar_como(pg_temp.u('b1'));
select is(pg_temp.resultados(pg_temp.push(jsonb_build_array(
            pg_temp.job('b1', 'visita', pg_temp.payload_visita(200, 'NO_CONTESTO', '11', null)),
            pg_temp.job('b2', 'visita', pg_temp.payload_visita(201, 'COBRANZA', '11', '21')),
            pg_temp.job('b3', 'visita', pg_temp.payload_visita(202, 'ENTREVISTA', null, '21', pg_temp.a('16:00'), pg_temp.a('16:30'))),
            pg_temp.job('b4', 'visita', pg_temp.payload_visita(203, 'VENTA', '11', null, pg_temp.a('17:00'), pg_temp.a('17:10')))
          ))), array['accepted', 'accepted', 'accepted', 'accepted'],
          'sin persona, cobranza, el teléfono viejo (sin espacio) y las horas de una entrevista: las cuatro entran');
select is((select espacio_persona_id is null and espacio_id = pg_temp.u('11') from public.visita where id = pg_temp.uv(200)),
          true, 'la visita sin persona quedó en la casa');
select is((select tipo_resultado from public.visita where id = pg_temp.uv(201)), 'COBRANZA', 'la cobranza se guardó');
select is((select espacio_id from public.visita where id = pg_temp.uv(202)), pg_temp.u('11'),
          'la que no mandó espacio toma el de su vínculo');
select is((select entrevista_entrada = pg_temp.a('16:00') and entrevista_salida = pg_temp.a('16:30')
             from public.visita where id = pg_temp.uv(202)), true, 'y las horas llegaron');
with r as (select pg_temp.push(jsonb_build_array(
            pg_temp.job('c1', 'visita', pg_temp.payload_visita(210, 'ENTREVISTA', '11', null, pg_temp.a('16:00'), pg_temp.a('15:00'))),
            pg_temp.job('c2', 'visita', pg_temp.payload_visita(211, 'NO_CONTESTO', '11', null)),
            pg_temp.job('c3', 'visita', pg_temp.payload_visita(212, 'COBRO', '11', null)),
            pg_temp.job('c4', 'visita', pg_temp.payload_visita(213, 'NO_CONTESTO', null, null)),
            pg_temp.job('c5', 'visita', pg_temp.payload_visita(214, 'COBRANZA', 'ff', null))
          )) as r)
select is(pg_temp.resultados((select r from r)), array['invalid', 'accepted', 'invalid', 'invalid', 'invalid'],
          'las horas al revés, un resultado inventado, sin espacio y un espacio inexistente vuelven invalid sin tumbar el lote');
select is(pg_temp.codigos(pg_temp.push(jsonb_build_array(
            pg_temp.job('c1', 'visita', pg_temp.payload_visita(210, 'ENTREVISTA', '11', null, pg_temp.a('16:00'), pg_temp.a('15:00'))),
            pg_temp.job('c3', 'visita', pg_temp.payload_visita(212, 'COBRO', '11', null)),
            pg_temp.job('c4', 'visita', pg_temp.payload_visita(213, 'NO_CONTESTO', null, null)),
            pg_temp.job('c5', 'visita', pg_temp.payload_visita(214, 'COBRANZA', 'ff', null))
          ))), array['23514', '23514', '23502', '23503'], 'con su código');
select is((select count(*)::int from public.visita where id in (pg_temp.uv(210), pg_temp.uv(212), pg_temp.uv(213), pg_temp.uv(214))), 0,
          'y ninguna quedó a medias');
select is(pg_temp.resultados(pg_temp.push(jsonb_build_array(
            pg_temp.job('b1', 'visita', pg_temp.payload_visita(200, 'NO_CONTESTO', '11', null))))),
          array['duplicate'::text], 'el reenvío de una visita sin persona es duplicate');
-- Update con la fila entera: las horas se cargan después.
select is(pg_temp.resultados(pg_temp.push(jsonb_build_array(
            jsonb_build_object('client_op_id', pg_temp.u('d1'), 'entity', 'visita', 'op', 'update',
                               'sync_version', (select v.sync_version from public.visita v where v.id = pg_temp.uv(200)),
                               'payload', pg_temp.payload_visita(200, 'ENTREVISTA', '11', null, pg_temp.a('18:00'), pg_temp.a('18:20')))))),
          array['accepted'], 'una visita sin persona se actualiza con la fila entera');
select is((select tipo_resultado || '/' || (extract(epoch from entrevista_salida - entrevista_entrada) / 60)::int
             from public.visita where id = pg_temp.uv(200)), 'ENTREVISTA/20', 'y cambia el resultado y suma las horas');
-- El pull lleva todo.
select pg_temp.actuar_como_servidor();
select is((select pg_temp.fila_del_pull(pg_temp.uv(202)) ->> 'espacio_id'), pg_temp.u('11')::text,
          'la fila que baja por el pull trae el espacio');
select is((select (pg_temp.fila_del_pull(pg_temp.uv(202)) ->> 'entrevista_salida')::timestamptz), pg_temp.a('16:30'),
          'y la hora de salida');
select is((select (pg_temp.fila_del_pull(pg_temp.uv(200)) ->> 'tipo_resultado')), 'ENTREVISTA', 'y el resultado');
select is((select pg_temp.fila_del_pull(pg_temp.uv(200)) -> 'espacio_persona_id'), 'null'::jsonb,
          'de una visita sin persona baja la persona en null');

-- ---------------------------------------------------------------------------
-- 7. COBRANZA no es una presentación
-- ---------------------------------------------------------------------------
-- b3 (inscripto hoy, en la zona d2) con hoy: una ENTREVISTA, una VENTA (presentaciones), dos COBRANZA (una
-- sin persona), un NO_CONTESTO y un RECHAZO. Solo las dos primeras cuentan.
select pg_temp.actuar_como_servidor();
insert into public.visita (id, espacio_persona_id, espacio_id, fecha, tipo_resultado, colportor_id, created_by)
select pg_temp.uv(x.n), pg_temp.u(x.p), pg_temp.u('11'), pg_temp.a('10:00'), x.r, pg_temp.u('b3'), pg_temp.u('b3')
  from (values (400, '21', 'ENTREVISTA'), (401, '21', 'VENTA'), (402, '21', 'COBRANZA'), (403, null, 'COBRANZA'),
               (404, '21', 'NO_CONTESTO'), (405, null, 'RECHAZO')) x(n, p, r);
select pg_temp.actuar_como(pg_temp.u('d1'));
select is((public.tablero_de_inicio(pg_temp.u('e1'), pg_temp.hoy()) -> 'total' ->> 'presentaciones')::int, 2,
          'el tablero de Inicio cuenta 2 presentaciones: la entrevista y la venta; las cobranzas no');
select is((select sum(r.presentaciones)::int from public.ventas_por_ciudad_y_colportor(pg_temp.u('e1'), pg_temp.hoy(), pg_temp.hoy(), 'dia') r
            where r.colportor_id = pg_temp.u('b3')), 2,
          'el reporte de ventas por ciudad y colportor también: 2');
select pg_temp.actuar_como_servidor();
update public.visita set tipo_resultado = 'ENTREVISTA' where id = pg_temp.uv(402);
select pg_temp.actuar_como(pg_temp.u('d1'));
select is((public.tablero_de_inicio(pg_temp.u('e1'), pg_temp.hoy()) -> 'total' ->> 'presentaciones')::int, 3,
          'control: la misma visita como ENTREVISTA sí suma (el 2 de antes es por ser cobranza)');
select is((select sum(r.presentaciones)::int from public.ventas_por_ciudad_y_colportor(pg_temp.u('e1'), pg_temp.hoy(), pg_temp.hoy(), 'dia') r
            where r.colportor_id = pg_temp.u('b3')), 3, 'y en el reporte también');
select pg_temp.actuar_como_servidor();
update public.visita set tipo_resultado = 'COBRANZA' where id = pg_temp.uv(402);

-- ---------------------------------------------------------------------------
-- 8. Cuando dos casas se unen
-- ---------------------------------------------------------------------------
-- b1 marca la 02 (de b2, espacio único 12) como duplicado de la 01 (espacio único 11). Antes, una visita
-- de b1 sin persona colgada del espacio 12, una de b1 con persona en el vínculo 22 y una de b2 también.
select pg_temp.actuar_como_servidor();
insert into public.visita (id, espacio_persona_id, espacio_id, fecha, tipo_resultado, colportor_id) values
  (pg_temp.uv(300), null,            pg_temp.u('12'), now(), 'NO_CONTESTO', pg_temp.u('b1')),
  (pg_temp.uv(301), pg_temp.u('22'), pg_temp.u('12'), now(), 'ENTREVISTA',  pg_temp.u('b1')),
  (pg_temp.uv(302), null,            pg_temp.u('12'), now(), 'COBRANZA',    pg_temp.u('b2')),
  (pg_temp.uv(303), null,            pg_temp.u('13'), now(), 'NO_CONTESTO', pg_temp.u('b1'));
-- Un depto de la 02 que se dio de baja (espacio 17) y todavía tiene una visita de b2 sin persona.
insert into public.espacio (id, ubicacion_id, numero_depto, created_by, deleted_at)
values (pg_temp.u('17'), pg_temp.u('02'), '9', pg_temp.u('b2'), now());
insert into public.visita (id, espacio_persona_id, espacio_id, fecha, tipo_resultado, colportor_id)
values (pg_temp.uv(304), null, pg_temp.u('17'), now(), 'NO_CONTESTO', pg_temp.u('b2'));
select pg_temp.actuar_como(pg_temp.u('b1'));
select lives_ok($$ select set_config('t69.union', public.marcar_como_duplicado(pg_temp.u('02'), pg_temp.u('01'))::text, true) $$,
                'b1 une la casa 02 a la 01 (con visitas de b2 sin persona, también en un depto dado de baja)');
select pg_temp.actuar_como_servidor();
select is((select espacio_id from public.visita where id = pg_temp.uv(300)), pg_temp.u('11'),
          'la visita sin persona pasó al espacio de A');
select is((select espacio_persona_id from public.visita where id = pg_temp.uv(300)), null, 'y sigue sin persona');
select is((select espacio_id from public.visita where id = pg_temp.uv(302)), pg_temp.u('11'),
          'la de otro colportor también');
select is((select espacio_persona_id::text || '/' || espacio_id::text from public.visita where id = pg_temp.uv(301)),
          pg_temp.u('21')::text || '/' || pg_temp.u('11')::text,
          'la que tenía persona pasa al vínculo de A y a su espacio');
select is((select espacio_id from public.visita where id = pg_temp.uv(303)), pg_temp.u('13'), 'una de otro espacio no se toca');
select is((select count(*)::int from public.visita where espacio_id = pg_temp.u('12')), 0,
          'no queda ninguna visita en el espacio fundido');
select is((select count(*)::int from public.visita where id in (pg_temp.uv(300), pg_temp.uv(301), pg_temp.uv(302), pg_temp.uv(303), pg_temp.uv(304))), 5,
          'y no se perdió ninguna');
select is((select e.ubicacion_id from public.espacio e where e.id = pg_temp.u('17')), pg_temp.u('01'),
          'el depto dado de baja con una visita sin persona pasó a la casa 01');
select is((select espacio_id from public.visita where id = pg_temp.uv(304)), pg_temp.u('17'), 'y la visita sigue en él');
-- La respuesta cuenta las visitas que pasaron: 300, 301, 302 (espacio 12) y 304 (espacio 17).
select is(current_setting('t69.union')::jsonb ->> 'visitas', '4', 'la respuesta cuenta las 4 visitas que pasaron, también las sin persona');
select pg_temp.actuar_como(pg_temp.u('b1'));
select is((select public.marcar_como_duplicado(pg_temp.u('02'), pg_temp.u('01')) ->> 'ya_unida'), 'true',
          'repetir la unión es idempotente');
select is(pg_temp.ins(310, 'NO_CONTESTO', p_espacio => '12'), 'ok', 'una visita que llega tarde al espacio fundido entra');
select is((select espacio_id from public.visita where id = pg_temp.uv(310)), pg_temp.u('11'), 'y se guarda en el de A');
select is(pg_temp.ins(311, 'ENTREVISTA', '22', p_espacio => '12'), 'ok', 'una con el vínculo fundido también entra');
select is((select espacio_persona_id::text || '/' || espacio_id::text from public.visita where id = pg_temp.uv(311)),
          pg_temp.u('21')::text || '/' || pg_temp.u('11')::text, 'en el vínculo y el espacio de A');

-- Un vínculo que cambia de espacio se lleva sus visitas (las de cualquier colportor), no las de otro vínculo.
select pg_temp.actuar_como_servidor();
insert into public.visita (id, espacio_persona_id, espacio_id, fecha, tipo_resultado, colportor_id) values
  (pg_temp.uv(330), pg_temp.u('23'), pg_temp.u('13'), now(), 'ENTREVISTA',  pg_temp.u('b1')),
  (pg_temp.uv(331), pg_temp.u('23'), pg_temp.u('13'), now(), 'NO_CONTESTO', pg_temp.u('b2')),
  (pg_temp.uv(332), null,            pg_temp.u('13'), now(), 'NO_CONTESTO', pg_temp.u('b1'));
update public.espacio_persona set espacio_id = pg_temp.u('14') where id = pg_temp.u('23');
select is((select array_agg(espacio_id order by id) from public.visita where id in (pg_temp.uv(330), pg_temp.uv(331))),
          array[pg_temp.u('14'), pg_temp.u('14')], 'las visitas del vínculo, de cualquier colportor, lo siguen al depto 14');
select is((select espacio_id from public.visita where id = pg_temp.uv(332)), pg_temp.u('13'),
          'y la que no tiene persona se queda en su espacio');
update public.espacio_persona set updated_at = now() where id = pg_temp.u('23');
select is((select espacio_id from public.visita where id = pg_temp.uv(330)), pg_temp.u('14'),
          'tocar el vínculo sin cambiarle el espacio no mueve nada');

-- ---------------------------------------------------------------------------
-- 9. La baja de una casa con visitas de otro colportor
-- ---------------------------------------------------------------------------
-- La casa 04 (de b1) tiene una visita de b2 sin persona: UB002 como si tuviera persona. La 05 solo tiene
-- una visita sin persona de b1: se da de baja.
select pg_temp.actuar_como_servidor();
insert into public.visita (id, espacio_persona_id, espacio_id, fecha, tipo_resultado, colportor_id) values
  (pg_temp.uv(320), null, pg_temp.u('15'), now(), 'NO_CONTESTO', pg_temp.u('b2')),
  (pg_temp.uv(321), null, pg_temp.u('16'), now(), 'NO_CONTESTO', pg_temp.u('b1'));
select pg_temp.actuar_como(pg_temp.u('b1'));
select throws_ok(format('update public.ubicacion set deleted_at = now() where id = %L', pg_temp.u('04')),
  'UB002', 'No se puede dar de baja esta casa: otro colportor registró visitas en ella. La casa queda como estaba.',
  'una visita sin persona de otro colportor frena la baja de la casa (UB002)');
select lives_ok(format('update public.ubicacion set deleted_at = now() where id = %L', pg_temp.u('05')),
  'y una visita sin persona propia no la frena');
select pg_temp.actuar_como_servidor();
select is((select deleted_at is null from public.ubicacion where id = pg_temp.u('04')), true, 'la 04 quedó como estaba');
select is((select count(*)::int from public.visita where id in (pg_temp.uv(320), pg_temp.uv(321))), 2, 'y ninguna visita se perdió');

select * from finish();
rollback;
