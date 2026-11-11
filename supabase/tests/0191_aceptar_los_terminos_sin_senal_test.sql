-- pgTAP · migración 0191 (backend-supabase#267, BACK-HU-AUTH-011; decisión de Cristian del 11/11, «TyC s/red»: se acepta
-- sin señal y sube después): sync_push aplica el trabajo «aceptar los Términos» como aceptar_terminos(version).
--   1. Sin señal: Ana aceptó la v2 en el teléfono y la aceptación llega en un push posterior, en medio de su lote: `accepted`,
--      la fila con la hora del servidor, el evento de auditoría y el cache; el reintento del mismo client_op_id es
--      `duplicate` y no deja nada de más.
--   2. Idempotente: otro client_op_id con la misma versión, o una que ya había aceptado por la RPC: `duplicate` con
--      ya_estaba.
--   3. La versión es la que leyó: si mientras estaba sin señal salió la v3, la que sube (v2) es la que queda.
--   4. Cualquier rol, por la puerta real (public.sync_push): un coordinador.
--   5. Los rechazos vuelven `invalid` por trabajo y el lote sigue: TC001, PAYLOAD_VACIO, OP_INVALIDA, 42501 (cuenta dada
--      de baja) y ENTIDAD_DE_SOLO_LECTURA para una fila de consentimiento_terminos. Rechazado no escribe nada. La cuenta
--      suspendida no llega al trabajo: CS004 del push entero (0143).
--   6. La hora del teléfono (`aceptado_en_telefono`): se guarda si es creíble (no más de 5 min en el futuro ni antes de que
--      la versión pasara a vigente); si no, null y la aceptación vale igual; la primera no se pisa.
-- Va en una transacción (audit_log solo se agrega y no se puede limpiar).
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
create or replace function pg_temp.como_servidor() returns void language plpgsql as $$
begin
  perform set_config('role', 'postgres', true);
  perform set_config('request.jwt.claims', '', true);
  perform set_config('request.jwt.claim.sub', '', true);
  perform set_config('request.jwt.claim.role', '', true);
end $$;
create or replace function pg_temp.u(p text) returns uuid language sql as $$
  select ('01920000-0000-7000-8000-0000000191' || p)::uuid;
$$;
create or replace function pg_temp.job(p_ent text, p_op text, p_payload jsonb) returns jsonb language sql as $$
  select jsonb_build_object('client_op_id', gen_random_uuid(), 'entity', p_ent, 'op', p_op, 'payload', p_payload);
$$;
-- El trabajo «aceptar los Términos» de una versión.
create or replace function pg_temp.aceptar(p_version text) returns jsonb language sql as $$
  select pg_temp.job('consentimiento_terminos', 'aceptar_terminos', jsonb_build_object('version', p_version));
$$;
create or replace function pg_temp.resultados(p_r jsonb) returns text[] language sql as $$
  select array_agg((e ->> 'outcome') || coalesce(' ' || (e ->> 'code'), '') order by i)
    from jsonb_array_elements(p_r -> 'results') with ordinality x(e, i);
$$;
-- «versión,…» de lo que aceptó la persona.
create or replace function pg_temp.versiones(p text) returns text language sql as $$
  select coalesce(string_agg(version, ',' order by version), '-') from public.consentimiento_terminos where usuario_id = pg_temp.u(p);
$$;
create or replace function pg_temp.eventos(p text) returns int language sql as $$
  select count(*)::int from auditoria.audit_log a
   where a.event_type = 'terminos_aceptados' and a.actor_user_id = pg_temp.u(p);
$$;
create or replace function pg_temp.sobre() returns jsonb language sql as $$
  select jsonb_build_object('device_id', '01920000-0000-7000-8000-0000000191d0', 'app_version', '1.4.2', 'schema_version', 1);
$$;

-- --- fixtures (como postgres) --------------------------------------------------
-- b1 colportora (Ana), b2 colportora suspendida, b3 colportora dada de baja, c1 coordinador.
insert into auth.users (id, instance_id, aud, role, email, encrypted_password, confirmed_at, created_at, updated_at)
select pg_temp.u(s), '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
       'terminos189-' || s || '@example.com', 'x', now(), now(), now()
  from unnest(array['b1','b2','b3','c1']) s;
insert into public.usuario_rol (usuario_id, rol_id)
select pg_temp.u(x.s), r.id
  from (values ('b1','COLPORTOR'), ('b2','COLPORTOR'), ('b3','COLPORTOR'), ('c1','COORDINADOR')) x(s, codigo)
  join public.rol r on r.codigo = x.codigo;

-- Ana aceptó la v1 con conexión (la RPC de la 0182).
select pg_temp.actuar_como(pg_temp.u('b1'));
select is((select version from public.aceptar_terminos('v1')), 'v1', 'Ana aceptó la v1 con conexión');
select pg_temp.como_servidor();

-- Sale la v2: se publica y pasa a vigente. El teléfono de Ana se entera con el pull.
create or replace function public.terminos_versiones_publicadas() returns text[] language sql immutable set search_path = ''
as $$ select array['v1', 'v2']::text[] $$;
update public.parametro_global set valor = 2 where clave = 'terminos_version_vigente';
select is(public.terminos_version_vigente(), 'v2', 'la v2 es la vigente');

-- ---------------------------------------------------------------------------
-- 1. Sin señal: la aceptación llega en un push posterior
-- ---------------------------------------------------------------------------
-- En el campo, Ana lee la v2 y la acepta: el teléfono encola el trabajo. Al volver la señal sube con lo que cargó.
select pg_temp.actuar_como(pg_temp.u('b1'));
create temp table op_1 as select pg_temp.aceptar('v2') j;
create temp table lote_1 on commit drop as
select sync.push(jsonb_build_array(
         pg_temp.job('consentimiento_terminos', 'aceptar_terminos', '{"version": "v7"}'::jsonb),
         (select j from op_1))) as r;
select is((select pg_temp.resultados(r) from lote_1), array['invalid TC001', 'accepted'],
          'el trabajo de la v2 llega en el lote, detrás de uno rechazado: accepted (el rechazo no tumba el lote)');
select is((select r -> 'results' -> 1 ->> 'client_op_id' from lote_1), (select j ->> 'client_op_id' from op_1),
          'devuelve el client_op_id del trabajo');
select is((select r -> 'results' -> 1 ->> 'ya_estaba' from lote_1), 'false', 'ya_estaba es false: se aplicó');
select is((select r -> 'results' -> 1 ->> 'version' from lote_1), 'v2', 'con la versión aceptada');
select pg_temp.como_servidor();
select is(pg_temp.versiones('b1'), 'v1,v2', 'queda el historial de Ana: v1 y v2');
select is((select (r -> 'results' -> 1 ->> 'sync_version')::bigint from lote_1),
          (select sync_version from public.consentimiento_terminos where usuario_id = pg_temp.u('b1') and version = 'v2'),
          'sync_version es el de la fila nueva');
select is((select (r -> 'results' -> 1 ->> 'aceptado_en')::timestamptz from lote_1),
          (select aceptado_en from public.consentimiento_terminos where usuario_id = pg_temp.u('b1') and version = 'v2'),
          'aceptado_en es el de la fila');
select ok((select aceptado_en = now() and created_by = usuario_id and deleted_at is null
             from public.consentimiento_terminos where usuario_id = pg_temp.u('b1') and version = 'v2'),
          'con la hora del servidor al subir y quién la aceptó');
select is((select count(*)::int from auditoria.audit_log a
             join public.consentimiento_terminos c on c.id = a.fila_id
            where a.event_type = 'terminos_aceptados' and a.actor_user_id = pg_temp.u('b1')
              and c.version = 'v2' and a.metadata = jsonb_build_object('version', 'v2')), 1,
          'y el evento terminos_aceptados con la versión');
select is((select count(*)::int from sync.op_cache where client_op_id = (select (j ->> 'client_op_id')::uuid from op_1)), 1,
          'el trabajo entró al cache de client_op_id');

-- La respuesta se perdió y el teléfono reintenta el mismo trabajo.
select pg_temp.actuar_como(pg_temp.u('b1'));
create temp table lote_1b on commit drop as select sync.push(jsonb_build_array((select j from op_1))) as r;
select is((select pg_temp.resultados(r) from lote_1b), array['duplicate'], 'el reintento del mismo client_op_id: duplicate');
select pg_temp.como_servidor();
select is(pg_temp.versiones('b1'), 'v1,v2', 'sin filas de más');
select is(pg_temp.eventos('b1'), 2, 'ni eventos de más (v1 por la RPC y v2 por el push)');

-- ---------------------------------------------------------------------------
-- 2. Idempotente con otro client_op_id
-- ---------------------------------------------------------------------------
select pg_temp.actuar_como(pg_temp.u('b1'));
create temp table lote_2 on commit drop as
select sync.push(jsonb_build_array(pg_temp.aceptar('v2'), pg_temp.aceptar('v1'))) as r;
select is((select pg_temp.resultados(r) from lote_2), array['duplicate', 'duplicate'],
          'la v2 otra vez (otro teléfono) y la v1, que aceptó por la RPC: duplicate');
select is((select r -> 'results' -> 0 ->> 'ya_estaba' from lote_2), 'true', 'con ya_estaba true');
select is((select r -> 'results' -> 1 ->> 'version' from lote_2), 'v1', 'y la versión que ya estaba');
select pg_temp.como_servidor();
select is((select (r -> 'results' -> 0 ->> 'aceptado_en')::timestamptz from lote_2),
          (select aceptado_en from public.consentimiento_terminos where usuario_id = pg_temp.u('b1') and version = 'v2'),
          'aceptado_en es el de la primera aceptación, no se pisa');
select is(pg_temp.eventos('b1'), 2, 'sin eventos nuevos');

-- ---------------------------------------------------------------------------
-- 3. La versión que sube es la que leyó
-- ---------------------------------------------------------------------------
-- El coordinador c1 leyó la v2 sin señal; antes de que suba, se publica la v3. Sube la v2, no la vigente.
create or replace function public.terminos_versiones_publicadas() returns text[] language sql immutable set search_path = ''
as $$ select array['v1', 'v2', 'v3']::text[] $$;
update public.parametro_global set valor = 3 where clave = 'terminos_version_vigente';

-- ---------------------------------------------------------------------------
-- 4. Cualquier rol, por la puerta real
-- ---------------------------------------------------------------------------
select pg_temp.actuar_como(pg_temp.u('c1'));
create temp table lote_4 on commit drop as
select public.sync_push(jsonb_build_object('device', pg_temp.sobre(), 'jobs', jsonb_build_array(pg_temp.aceptar('v2')))) as r;
select is((select pg_temp.resultados(r) from lote_4), array['accepted'], 'el coordinador acepta la v2 por sync_push: accepted');
select pg_temp.como_servidor();
select is(pg_temp.versiones('c1'), 'v2', 'queda la v2 que leyó, no la v3 vigente');

-- ---------------------------------------------------------------------------
-- 5. Rechazos: invalid por trabajo, sin escribir nada
-- ---------------------------------------------------------------------------
create temp table foto_5 as
select (select count(*) from public.consentimiento_terminos) filas,
       (select count(*) from auditoria.audit_log where event_type = 'terminos_aceptados') eventos;
select pg_temp.actuar_como(pg_temp.u('c1'));
create temp table lote_5 on commit drop as
select sync.push(jsonb_build_array(
         pg_temp.aceptar('v9'),
         pg_temp.aceptar('x1'),
         pg_temp.aceptar(''),
         pg_temp.job('consentimiento_terminos', 'aceptar_terminos', '{}'::jsonb),
         pg_temp.job('consentimiento_terminos', 'aceptar_terminos', '{"version": 3}'::jsonb),
         pg_temp.job('consentimiento_terminos', 'aceptar_terminos', '{"version": null}'::jsonb),
         jsonb_build_object('client_op_id', gen_random_uuid(), 'entity', 'consentimiento_terminos', 'op', 'aceptar_terminos'),
         pg_temp.job('ubicacion', 'aceptar_terminos', '{"version": "v3"}'::jsonb),
         pg_temp.job('consentimiento_terminos', 'insert',
                     jsonb_build_object('id', pg_temp.u('e1'), 'usuario_id', pg_temp.u('c1'), 'version', 'v3')),
         pg_temp.aceptar('v3'))) as r;
select is((select pg_temp.resultados(r) from lote_5),
          array['invalid TC001', 'invalid TC001', 'invalid TC001',
                'invalid PAYLOAD_VACIO', 'invalid PAYLOAD_VACIO', 'invalid PAYLOAD_VACIO', 'invalid PAYLOAD_VACIO',
                'invalid OP_INVALIDA', 'invalid ENTIDAD_DE_SOLO_LECTURA', 'accepted'],
          'no publicada, forma inválida y vacía: TC001; sin versión (o no texto): PAYLOAD_VACIO; otra entidad: OP_INVALIDA; '
          'una fila por el push: ENTIDAD_DE_SOLO_LECTURA; y el último del lote se aplica');
select ok((select r -> 'results' -> 0 ->> 'message' from lote_5) like 'La versión de los Términos%publicadas: v1, v2, v3%',
          'TC001 trae el aviso con las versiones publicadas');
select pg_temp.como_servidor();
select is((select count(*) from public.consentimiento_terminos) - (select filas from foto_5), 1::bigint,
          'solo el último dejó una fila');
select is((select count(*) from auditoria.audit_log where event_type = 'terminos_aceptados') - (select eventos from foto_5), 1::bigint,
          'y un solo evento');
select is(pg_temp.versiones('c1'), 'v2,v3', 'el coordinador queda con v2 y v3');
select is((select count(*)::int from sync.op_cache c
             join jsonb_array_elements((select r -> 'results' from lote_5)) e on c.client_op_id = (e ->> 'client_op_id')::uuid
            where e ->> 'outcome' = 'invalid'), 0,
          'los rechazados no entran al cache: se pueden reintentar con el mismo client_op_id');

-- La cuenta dada de baja: 42501 por trabajo.
update public.usuario set deleted_at = now() where id = pg_temp.u('b3');
select pg_temp.actuar_como(pg_temp.u('b3'));
create temp table lote_5b on commit drop as select sync.push(jsonb_build_array(pg_temp.aceptar('v3'))) as r;
select is((select pg_temp.resultados(r) from lote_5b), array['invalid 42501'], 'cuenta dada de baja: invalid 42501');
select pg_temp.como_servidor();
select is(pg_temp.versiones('b3'), '-', 'y no deja nada');

-- La cuenta suspendida no llega al trabajo: el push entero es CS004 y el trabajo queda en el teléfono.
update public.usuario set suspendido_en = now() where id = pg_temp.u('b2');
select pg_temp.actuar_como(pg_temp.u('b2'));
select throws_ok(
  format('select public.sync_push(%L::jsonb)',
         jsonb_build_object('device', pg_temp.sobre(), 'jobs', jsonb_build_array(pg_temp.aceptar('v3')))),
  'CS004', null, 'cuenta suspendida: sync_push entero responde CS004');
select pg_temp.como_servidor();
select is(pg_temp.versiones('b2'), '-', 'y no deja nada');

-- ---------------------------------------------------------------------------
-- 6. La hora del teléfono (P2 de #267, decisión del 11/11 por R1 y R2)
-- ---------------------------------------------------------------------------
-- La v4 pasó a vigente hace dos días (el evento de audit_log de entonces; hoy se vuelve a fijar). Cinco colportoras la
-- aceptan sin señal y suben con la hora del teléfono.
create or replace function public.terminos_versiones_publicadas() returns text[] language sql immutable set search_path = ''
as $$ select array['v1', 'v2', 'v3', 'v4']::text[] $$;
insert into auditoria.audit_log (created_at, event_type, tabla, fila_id, metadata)
select now() - interval '2 days', 'parametro_global_cambio', 'parametro_global', p.id,
       jsonb_build_object('clave', 'terminos_version_vigente', 'valor_anterior', 3, 'valor_nuevo', 4, 'rol', 'postgres',
                          'definitiva', true)
  from public.parametro_global p where p.clave = 'terminos_version_vigente';
update public.parametro_global set valor = 4 where clave = 'terminos_version_vigente';

create or replace function pg_temp.aceptar_a_las(p_version text, p_hora jsonb) returns jsonb language sql as $$
  select pg_temp.job('consentimiento_terminos', 'aceptar_terminos',
                     jsonb_build_object('version', p_version, 'aceptado_en_telefono', p_hora));
$$;
-- Ana (d1..d5) sube la v4 con esa hora; devuelve «outcome|aceptado_en_telefono de la respuesta».
create or replace function pg_temp.sube_con_hora(p text, p_hora jsonb) returns text language plpgsql as $$
declare r jsonb;
begin
  perform pg_temp.actuar_como(pg_temp.u(p));
  r := sync.push(jsonb_build_array(pg_temp.aceptar_a_las('v4', p_hora))) -> 'results' -> 0;
  perform pg_temp.como_servidor();
  return (r ->> 'outcome') || '|' || coalesce(r ->> 'aceptado_en_telefono', '-');
end $$;
create or replace function pg_temp.hora_guardada(p text) returns timestamptz language sql as $$
  select aceptado_en_telefono from public.consentimiento_terminos where usuario_id = pg_temp.u(p) and version = 'v4';
$$;

insert into auth.users (id, instance_id, aud, role, email, encrypted_password, confirmed_at, created_at, updated_at)
select pg_temp.u(s), '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
       'terminos189-' || s || '@example.com', 'x', now(), now(), now()
  from unnest(array['d1','d2','d3','d4','d5','d6']) s;

select is(pg_temp.sube_con_hora('d1', to_jsonb((now() - interval '1 day')::text)),
          'accepted|' || (to_jsonb(now() - interval '1 day') #>> '{}'),
          'aceptó ayer sin señal (después de que la v4 pasó a vigente): accepted, con la hora del teléfono');
select is(pg_temp.hora_guardada('d1'), now() - interval '1 day', 'la hora del teléfono queda guardada');
select is((select aceptado_en from public.consentimiento_terminos where usuario_id = pg_temp.u('d1') and version = 'v4'), now(),
          'y aceptado_en sigue siendo la hora del servidor');
select is(pg_temp.sube_con_hora('d2', to_jsonb((now() + interval '2 minutes')::text)) like 'accepted|2%', true,
          'un reloj adelantado 2 min (dentro de los 5): se guarda');
select is(pg_temp.hora_guardada('d2'), now() + interval '2 minutes', 'con esa hora');
select is(pg_temp.sube_con_hora('d3', to_jsonb((now() + interval '10 minutes')::text)), 'accepted|-',
          'más de 5 min en el futuro: la aceptación vale, sin hora del teléfono');
select is(pg_temp.hora_guardada('d3'), null, 'queda en null');
select is(pg_temp.sube_con_hora('d4', to_jsonb((now() - interval '3 days')::text)), 'accepted|-',
          'antes de que la v4 pasara a vigente: la aceptación vale, sin hora del teléfono');
select is(pg_temp.hora_guardada('d4'), null, 'queda en null');
select is(pg_temp.sube_con_hora('d5', '"ayer a la tarde"'::jsonb), 'accepted|-', 'una hora que no es una fecha: accepted, sin hora');
select is(pg_temp.sube_con_hora('d6', '1731340800'::jsonb), 'accepted|-', 'una hora que no es un texto: accepted, sin hora');
select is((select count(*)::int from public.consentimiento_terminos
            where usuario_id in (pg_temp.u('d3'), pg_temp.u('d4'), pg_temp.u('d5'), pg_temp.u('d6')) and version = 'v4'), 4,
          'las cuatro aceptaciones sin hora quedaron registradas');

-- Otro teléfono de d1 sube la misma aceptación con otra hora: duplicate, la primera no se pisa.
select is(pg_temp.sube_con_hora('d1', to_jsonb((now() - interval '1 hour')::text)),
          'duplicate|' || (to_jsonb(now() - interval '1 day') #>> '{}'),
          'la misma versión con otra hora: duplicate, con la hora que ya estaba');
select is(pg_temp.hora_guardada('d1'), now() - interval '1 day', 'la hora guardada no cambia');
select is(has_function_privilege('anon', 'sync.hora_de_aceptacion_del_telefono(text, text)', 'execute'), false,
          'anon no ejecuta sync.hora_de_aceptacion_del_telefono');

select * from finish();
rollback;
