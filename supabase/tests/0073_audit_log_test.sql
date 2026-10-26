-- pgTAP · audit_log (migración 0073, backend-supabase#136, RA-SE05, HU-ADM-007, HU-JOR-004)
-- La tabla auditoria.audit_log: que existe fuera de public y fuera del sync, que solo la escribe el
-- servidor (auditoria.registrar y service_role), que un cliente (anon, authenticated) no la lee ni
-- la escribe ni ve el schema, que solo se agrega (UPDATE, DELETE y TRUNCATE dan AU001), que el
-- detalle no lleva correo ni datos de clientes, que el actor sale de la sesión y que
-- agregar_acompaniamiento() escribe su evento (una vez por cambio, ninguno si falla ni si repite).
begin;
select * from no_plan();

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

-- service_role de la API: sin usuario en el JWT.
create or replace function pg_temp.actuar_como_service_role() returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', json_build_object('role', 'service_role')::text, true);
  perform set_config('request.jwt.claim.sub', '', true);
  perform set_config('request.jwt.claim.role', 'service_role', true);
  perform set_config('role', 'service_role', true);
end $$;

create or replace function pg_temp.actuar_como_anon() returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', '', true);
  perform set_config('request.jwt.claim.sub', '', true);
  perform set_config('request.jwt.claim.role', 'anon', true);
  perform set_config('role', 'anon', true);
end $$;

create or replace function pg_temp.u(p_sufijo text) returns uuid language sql immutable as $$
  select ('01920000-0000-7000-8000-0000000073' || p_sufijo)::uuid
$$;

create or replace function pg_temp.hoy() returns date language sql stable as $$
  select (now() at time zone 'America/Montevideo')::date
$$;

-- SQLSTATE|mensaje del error que da una sentencia ('ok' si no da ninguno).
create or replace function pg_temp.error_de(p_sql text) returns text language plpgsql as $$
begin
  execute p_sql;
  return 'ok';
exception when others then
  return sqlstate || '|' || sqlerrm;
end $$;

-- Solo el SQLSTATE.
create or replace function pg_temp.codigo_de(p_sql text) returns text language sql as $$
  select split_part(pg_temp.error_de(p_sql), '|', 1)
$$;

-- Agregar un acompañamiento: 'ok|ya_estaba' o 'SQLSTATE|mensaje'.
create or replace function pg_temp.agregar(p_camp text, p_jor text) returns text language plpgsql as $$
declare
  r record;
begin
  select * into r from public.agregar_acompaniamiento(pg_temp.u(p_camp), pg_temp.u(p_jor));
  return 'ok|' || r.ya_estaba::text;
exception when others then
  return sqlstate || '|' || sqlerrm;
end $$;

-- Cuántos registros hay (hay que llamarla como postgres: un cliente no ve la tabla).
create or replace function pg_temp.n(p_event text default null) returns bigint language sql as $$
  select count(*) from auditoria.audit_log where p_event is null or event_type = p_event
$$;

-- Registrar con un detalle de texto: 'ok' o el SQLSTATE.
create or replace function pg_temp.registrar(p_event text, p_metadata text, p_tabla text default null,
                                             p_fila text default null) returns text language plpgsql as $$
begin
  perform auditoria.registrar(p_event, p_tabla, case when p_fila is null then null else pg_temp.u(p_fila) end,
                              null, p_metadata::jsonb);
  return 'ok';
exception when others then
  return sqlstate;
end $$;

-- --- fixtures ------------------------------------------------------------------
-- Staff: a1 coordinador de la campaña e1, a2 coordinador de otra, ad admin (y colportor inscripto
--        en e1), a0 colportor.  Colportores: b1 Alfa, b2 Bravo (inscriptos en e1), b3 (sin inscribir).
-- Campañas: e1 en curso (desde hoy - 60, a1) · e2 terminada (a1) · e3 otra (a2).
insert into auth.users (id, instance_id, aud, role, email, encrypted_password, confirmed_at, created_at, updated_at)
select pg_temp.u(s), '00000000-0000-0000-0000-000000000000',
       'authenticated', 'authenticated', 'auditoria-' || s || '@example.com', 'x', now(), now(), now()
  from unnest(array['a0','a1','a2','ad','b1','b2','b3']) s;

update public.usuario u set nombre = x.n, apellido = x.a
  from (values ('a1','Mariela','Pereyra'), ('a2','Nora','Quiroga'), ('ad','Admin','Zeta'),
               ('b1','Ana','Alfa'), ('b2','Beto','Bravo'), ('b3','Carla','Cruz')) x(s, n, a)
 where u.id = pg_temp.u(x.s);

insert into public.usuario_rol (usuario_id, rol_id)
select pg_temp.u(x.s), r.id
  from (values ('a1','COORDINADOR'), ('a2','COORDINADOR'), ('ad','ADMIN'), ('a0','COLPORTOR'),
               ('b1','COLPORTOR'), ('b2','COLPORTOR'), ('b3','COLPORTOR')) x(s, codigo)
  join public.rol r on r.codigo = x.codigo;

insert into public.campania (id, nombre, tipo, fecha_inicio, fecha_fin, coordinador_id) values
  (pg_temp.u('e1'), 'En curso',  'VERANO', pg_temp.hoy() - 60, null,                 pg_temp.u('a1')),
  (pg_temp.u('e2'), 'Terminada', 'VERANO', pg_temp.hoy() - 90, pg_temp.hoy() - 40,   pg_temp.u('a1')),
  (pg_temp.u('e3'), 'Otra',      'VERANO', pg_temp.hoy() - 60, null,                 pg_temp.u('a2'));

insert into public.campania_colportor (campania_id, usuario_id, created_at)
select pg_temp.u(x.c), pg_temp.u(x.s), now() - interval '200 days'
  from (values ('e1','b1'), ('e1','b2'), ('e1','ad'), ('e2','b1')) x(c, s);

-- Jornadas cerradas de 9 a 12 h (id, colportor, hace cuántos días, acompañante):
--   j1 b1 hace 3, sin acompañante · j2 b1 hace 4, con a2 · j3 b1 ABIERTA hace 2 · j4 ad hace 2,
--   sin acompañante (la propia del admin) · j5 b2 hace 5, sin acompañante · j6 b1 hace 6, con a1 ·
--   j7 b3 hace 3 (b3 no está inscripto) · j8 b2 hace 7, sin acompañante.
insert into public.jornada (id, colportor_id, inicio, fin, acompaniante_id)
select pg_temp.u(x.id), pg_temp.u(x.colp),
       (pg_temp.hoy() - x.dias + time '09:00') at time zone 'America/Montevideo',
       case when x.abierta then null
            else (pg_temp.hoy() - x.dias + time '12:00') at time zone 'America/Montevideo' end,
       case when x.acomp is null then null else pg_temp.u(x.acomp) end
  from (values
    ('f1', 'b1', 3, false, null::text),
    ('f2', 'b1', 4, false, 'a2'),
    ('f3', 'b1', 2, true,  null),
    ('f4', 'ad', 2, false, null),
    ('f5', 'b2', 5, false, null),
    ('f6', 'b1', 6, false, 'a1'),
    ('f7', 'b3', 3, false, null),
    ('f8', 'b2', 7, false, null)) x(id, colp, dias, abierta, acomp);

-- ---------------------------------------------------------------------------
-- 1. Dónde está y cómo es
-- ---------------------------------------------------------------------------
select has_schema('auditoria', 'existe el schema auditoria');
select has_table('auditoria', 'audit_log', 'existe auditoria.audit_log');
select hasnt_table('public', 'audit_log', 'audit_log no está en public');
select columns_are('auditoria', 'audit_log',
  array['id','created_at','event_type','actor_user_id','target_user_id','tabla','fila_id','metadata'],
  'las columnas de audit_log (HU-ADM-007; created_at es el timestamp)');
select col_type_is('auditoria', 'audit_log', 'metadata', 'jsonb', 'metadata es jsonb');
select col_not_null('auditoria', 'audit_log', 'event_type', 'event_type es obligatorio');
select col_not_null('auditoria', 'audit_log', 'created_at', 'created_at es obligatorio');
select col_not_null('auditoria', 'audit_log', 'metadata', 'metadata es obligatorio');
select col_is_null('auditoria', 'audit_log', 'actor_user_id', 'el actor puede ser null (lo hizo el servidor)');
select col_is_pk('auditoria', 'audit_log', 'id', 'id es la clave');
select fk_ok('auditoria', 'audit_log', 'actor_user_id', 'public', 'usuario', 'id', 'el actor es un usuario');
select fk_ok('auditoria', 'audit_log', 'target_user_id', 'public', 'usuario', 'id', 'el target es un usuario');

select is((select relrowsecurity from pg_class where oid = 'auditoria.audit_log'::regclass), true,
          'audit_log tiene RLS activada');
select is((select count(*) from pg_policies where schemaname = 'auditoria'), 0::bigint,
          'y ninguna política: nadie con JWT la lee ni la escribe');

select is((select count(*) from sync.entidad where nombre like '%audit%'), 0::bigint,
          'audit_log no está en sync.entidad: no viaja al teléfono');
select is((select count(*) from pg_publication_tables where schemaname = 'auditoria'), 0::bigint,
          'audit_log no está en ninguna publicación (Realtime)');

-- ---------------------------------------------------------------------------
-- 2. Privilegios: solo el servidor
-- ---------------------------------------------------------------------------
select is(has_schema_privilege('anon', 'auditoria', 'usage'), false, 'anon no ve el schema');
select is(has_schema_privilege('authenticated', 'auditoria', 'usage'), false, 'authenticated no ve el schema');
select is(has_schema_privilege('service_role', 'auditoria', 'usage'), true, 'service_role sí');

select is(has_table_privilege(r, 'auditoria.audit_log', p), false, format('%s no tiene %s sobre audit_log', r, p))
  from unnest(array['anon','authenticated']) r,
       unnest(array['select','insert','update','delete','truncate']) p;
select is(has_table_privilege('service_role', 'auditoria.audit_log', 'select'), true, 'service_role lee');
select is(has_table_privilege('service_role', 'auditoria.audit_log', 'insert'), true, 'service_role escribe');
select is(has_table_privilege('service_role', 'auditoria.audit_log', 'update'), false, 'service_role no modifica');
select is(has_table_privilege('service_role', 'auditoria.audit_log', 'delete'), false, 'service_role no borra');
select is(has_table_privilege('service_role', 'auditoria.audit_log', 'truncate'), false, 'service_role no vacía');

select is(has_function_privilege(r, 'auditoria.registrar(text,text,uuid,uuid,jsonb)', 'execute'), r = 'service_role',
          format('registrar(): %s %s', r, case when r = 'service_role' then 'puede' else 'no puede' end))
  from unnest(array['anon','authenticated','service_role']) r;

select function_returns('auditoria', 'registrar', array['text','text','uuid','uuid','jsonb'], 'uuid',
                        'registrar() devuelve el id del registro');
select is((select pg_get_function_arguments('auditoria.registrar(text,text,uuid,uuid,jsonb)'::regprocedure)
                  ~* 'actor'),
          false, 'registrar() no recibe el actor: sale de la sesión');
select is((select prosecdef from pg_proc where oid = 'auditoria.registrar(text,text,uuid,uuid,jsonb)'::regprocedure),
          true, 'registrar() es SECURITY DEFINER');
select is((select proconfig from pg_proc where oid = 'auditoria.registrar(text,text,uuid,uuid,jsonb)'::regprocedure),
          array['search_path=""'], 'con search_path vacío');

-- Un cliente no entra ni por la tabla ni por la función.
select pg_temp.actuar_como(pg_temp.u('a1'));
select is(pg_temp.codigo_de('select * from auditoria.audit_log'), '42501', 'un coordinador no la lee');
select is(pg_temp.codigo_de($$insert into auditoria.audit_log (event_type) values ('intento_de_cliente')$$), '42501',
          'un coordinador no la escribe');
select is(pg_temp.codigo_de($$select auditoria.registrar('intento_de_cliente')$$), '42501',
          'ni por registrar()');
select pg_temp.actuar_como(pg_temp.u('ad'));
select is(pg_temp.codigo_de('select * from auditoria.audit_log'), '42501', 'un administrador con JWT tampoco la lee');
select is(pg_temp.codigo_de($$select auditoria.registrar('intento_de_admin')$$), '42501', 'ni la escribe por registrar()');
select pg_temp.actuar_como(pg_temp.u('a0'));
select is(pg_temp.codigo_de('select * from auditoria.audit_log'), '42501', 'un colportor no la lee');
select pg_temp.actuar_como_anon();
select is(pg_temp.codigo_de('select * from auditoria.audit_log'), '42501', 'anon no la lee');
select is(pg_temp.codigo_de($$insert into auditoria.audit_log (event_type) values ('intento_de_anon')$$), '42501',
          'anon no la escribe');
select is(pg_temp.codigo_de($$select auditoria.registrar('intento_de_anon')$$), '42501', 'ni por registrar()');
select pg_temp.actuar_como_servidor();
select is(pg_temp.n(), 0::bigint, 'ningún intento de un cliente dejó registro');

-- ---------------------------------------------------------------------------
-- 3. El servidor la escribe: service_role (sin usuario) y el dueño con la sesión de un usuario
-- ---------------------------------------------------------------------------
select pg_temp.actuar_como_service_role();
select is(pg_temp.error_de($$select auditoria.registrar('prueba_del_servidor')$$), 'ok', 'service_role registra un evento sin fila');
select is((select actor_user_id from auditoria.audit_log where event_type = 'prueba_del_servidor'), null::uuid,
          'sin sesión de usuario el actor queda null');
select is((select metadata from auditoria.audit_log where event_type = 'prueba_del_servidor'), '{}'::jsonb,
          'y el detalle por defecto es un objeto vacío');
select is(pg_temp.error_de($$select auditoria.registrar('servidor_con_target', null, null, '01920000-0000-7000-8000-0000000073b1'::uuid)$$), 'ok', 'service_role registra un evento sobre un usuario');
select is((select (actor_user_id, target_user_id)::text from auditoria.audit_log where event_type = 'servidor_con_target'), '(,01920000-0000-7000-8000-0000000073b1)', 'sin sesion el actor sigue null aunque haya target');
select is(pg_temp.error_de($$insert into auditoria.audit_log (event_type, tabla, metadata) values ('insert_directo', 'jornada', '{"k":1}')$$),
          'ok', 'service_role puede insertar directo');
select is(pg_temp.codigo_de($$update auditoria.audit_log set tabla = 'otra'$$), '42501', 'service_role no modifica');
select is(pg_temp.codigo_de($$delete from auditoria.audit_log$$), '42501', 'service_role no borra');
select is(pg_temp.codigo_de($$truncate auditoria.audit_log$$), '42501', 'service_role no vacía');
select is((select count(*) from auditoria.audit_log), 3::bigint, 'service_role las lee');
select pg_temp.actuar_como_servidor();

-- El dueño con la sesión de un usuario (lo que pasa dentro de un SECURITY DEFINER): el actor es él.
create or replace function pg_temp.sesion_de(p_uid uuid) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', json_build_object('sub', p_uid, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', p_uid::text, true);
end $$;
select pg_temp.sesion_de(pg_temp.u('a2'));
select is(pg_temp.error_de($$select auditoria.registrar('evento_de_a2', 'jornada', '01920000-0000-7000-8000-0000000073f1'::uuid, '01920000-0000-7000-8000-0000000073b1'::uuid, '{"clave":"valor"}')$$),
          'ok', 'el dueño registra con la sesión de a2');
select pg_temp.actuar_como_servidor();
select results_eq(
  $$select actor_user_id, target_user_id, tabla, fila_id, metadata from auditoria.audit_log where event_type = 'evento_de_a2'$$,
  $$values (pg_temp.u('a2'), pg_temp.u('b1'), 'jornada'::text, pg_temp.u('f1'), '{"clave":"valor"}'::jsonb)$$,
  'el actor es auth.uid() de la sesión, y lo demás queda como se pasó');
select ok((select created_at from auditoria.audit_log where event_type = 'evento_de_a2') = now(), 'created_at es el momento');

-- ---------------------------------------------------------------------------
-- 4. Solo se agrega
-- ---------------------------------------------------------------------------
select is(pg_temp.error_de($$update auditoria.audit_log set tabla = 'otra'$$),
          'AU001|El registro de auditoría solo se agrega: no se modifica ni se borra.',
          'el dueño no modifica (AU001)');
select is(pg_temp.codigo_de($$update auditoria.audit_log set metadata = '{}'$$), 'AU001', 'ni el detalle');
select is(pg_temp.codigo_de($$delete from auditoria.audit_log$$), 'AU001', 'el dueño no borra (AU001)');
select is(pg_temp.codigo_de($$delete from auditoria.audit_log where event_type = 'evento_de_a2'$$), 'AU001', 'ni uno solo');
select is(pg_temp.codigo_de($$truncate auditoria.audit_log$$), 'AU001', 'el dueño no vacía (AU001)');
select is(pg_temp.n(), 4::bigint, 'los registros siguen todos');

-- ---------------------------------------------------------------------------
-- 5. El detalle no lleva correo ni datos de clientes
-- ---------------------------------------------------------------------------
select is(pg_temp.registrar('detalle_ok', '{"campania_id":"01920000-0000-7000-8000-0000000073e1","dia":"2026-10-01","cantidad":3,"anterior":false}'),
          'ok', 'un detalle de identificadores, días y cantidades pasa');
select is(pg_temp.registrar('detalle_ok', '{"lista":[1,2,3],"sub":{"a":"b"}}'), 'ok', 'y uno con listas y objetos sin datos personales');
select is(pg_temp.registrar('detalle_ok', null), 'ok', 'sin detalle queda el objeto vacío');

select is(pg_temp.registrar('con_correo', '{"dato":"marta@example.com"}'), '23514', 'un correo en un valor se rechaza');
select is(pg_temp.registrar('con_correo', '{"a":{"b":["x","marta@example.com"]}}'), '23514', 'o en el fondo de una lista');
select is(pg_temp.registrar('con_correo', '{"x@y":1}'), '23514', 'o en una clave');
select is(pg_temp.registrar('con_clave', '{"email":"no"}'), '23514', 'una clave email se rechaza');
select is(pg_temp.registrar('con_clave', '{"Correo":"no"}'), '23514', 'o Correo (sin mirar mayúsculas)');
select is(pg_temp.registrar('con_clave', '{"telefono":"099123456"}'), '23514', 'telefono');
select is(pg_temp.registrar('con_clave', '{"nombre":"Ana"}'), '23514', 'nombre');
select is(pg_temp.registrar('con_clave', '{"apellido":"Alfa"}'), '23514', 'apellido');
select is(pg_temp.registrar('con_clave', '{"direccion":"Calle 1"}'), '23514', 'direccion');
select is(pg_temp.registrar('con_clave', '{"cliente":"x"}'), '23514', 'cliente');
select is(pg_temp.registrar('con_clave', '{"persona_id":"x"}'), '23514', 'persona_id (la clave contiene persona)');
select is(pg_temp.registrar('con_clave', '{"nombre_cliente":"x"}'), '23514', 'nombre_cliente');
select is(pg_temp.registrar('con_clave', '{"ok":{"anidado":{"telefono":1}}}'), '23514', 'una clave prohibida anidada');
select is(pg_temp.registrar('con_clave', '{"password":"x"}'), '23514', 'password');
select is(pg_temp.registrar('con_clave', '{"token":"x"}'), '23514', 'token');
select is(pg_temp.registrar('forma', '[1,2]'), '23514', 'un arreglo no es un detalle');
select is(pg_temp.registrar('forma', '"texto"'), '23514', 'un texto tampoco');
select is(pg_temp.registrar('forma', '1'), '23514', 'ni un número');
select is(pg_temp.registrar('grande', format('{"k":"%s"}', repeat('a', 4000))), '23514', 'más de 4000 caracteres se rechaza');
select is(pg_temp.registrar('grande', format('{"k":"%s"}', repeat('a', 3900))), 'ok', 'y 3900 caracteres pasa');
select is(length(('{"k":"' || repeat('a', 3991) || '"}')::jsonb::text), 4000, 'el borde: este detalle mide justo 4000 caracteres');
select is(pg_temp.registrar('grande', format('{"k":"%s"}', repeat('a', 3991))), 'ok', 'justo 4000 caracteres pasa');
select is(pg_temp.registrar('grande', format('{"k":"%s"}', repeat('a', 3992))), '23514', 'y 4001 se rechaza');

-- El evento y la fila.
select is(pg_temp.registrar('Acompañamiento', '{}'), '23514', 'un evento con mayúsculas o eñes se rechaza');
select is(pg_temp.registrar('ab', '{}'), '23514', 'o muy corto');
select is(pg_temp.registrar('con espacio', '{}'), '23514', 'o con espacios');
select is(pg_temp.registrar('1_empieza_con_numero', '{}'), '23514', 'o que empieza con un número');
select is(pg_temp.registrar(repeat('a', 61), '{}'), '23514', 'o de más de 60 caracteres');
select is(pg_temp.registrar('tabla_mal', '{}', 'Jornada'), '23514', 'una tabla con mayúsculas se rechaza');
select is(pg_temp.registrar('fila_sin_tabla', '{}', null, 'f1'), '23514', 'una fila sin tabla se rechaza');
select is(pg_temp.registrar('fila_y_tabla', '{}', 'jornada', 'f1'), 'ok', 'con tabla va');
select is(pg_temp.codigo_de($$select auditoria.registrar('target_inexistente', null, null, gen_random_uuid())$$), '23503',
          'un target que no es usuario se rechaza (FK)');

-- ---------------------------------------------------------------------------
-- 6. agregar_acompaniamiento() escribe su evento
-- ---------------------------------------------------------------------------
create temp table base as select count(*)::bigint as n from auditoria.audit_log;

select pg_temp.actuar_como(pg_temp.u('a1'));
select is(pg_temp.agregar('e1', 'f1'), 'ok|false', 'a1 agrega su acompañamiento a la jornada de b1');
select pg_temp.actuar_como_servidor();
select is(pg_temp.n('acompaniamiento_agregado'), 1::bigint, 'dejó un registro');
select results_eq(
  $$select actor_user_id, target_user_id, tabla, fila_id, metadata from auditoria.audit_log where event_type = 'acompaniamiento_agregado'$$,
  format($$values (%L::uuid, %L::uuid, 'jornada'::text, %L::uuid, jsonb_build_object('campania_id', %L::uuid, 'dia', %L::date, 'acompaniante_id', %L::uuid, 'con_nota', false))$$,
         pg_temp.u('a1'), pg_temp.u('b1'), pg_temp.u('f1'), pg_temp.u('e1'), pg_temp.hoy() - 3, pg_temp.u('a1')),
  'actor = el coordinador, target = el colportor, la jornada, y el detalle con la campaña, el día, quién acompañó y si hubo nota');
select is((select array_agg(k order by k) from auditoria.audit_log a, jsonb_object_keys(a.metadata) k
            where a.event_type = 'acompaniamiento_agregado'),
          array['acompaniante_id','campania_id','con_nota','dia'], 'el detalle tiene solo esas cuatro claves (ni nombres ni el texto de la nota)');
select is((select count(*) from auditoria.audit_log
            where event_type = 'acompaniamiento_agregado'
              and (metadata::text like '%@%' or metadata::text ~* 'mail|nombre|apellido|Ana|Alfa|Mariela|Pereyra')),
          0::bigint, 'ni un correo ni un nombre en el registro');
select is((select count(*) from auditoria.audit_log a
            where event_type = 'acompaniamiento_agregado'
              and to_jsonb(a)::text ~* 'auditoria-a1|example\.com'),
          0::bigint, 'ni el correo del coordinador en ninguna columna');

-- Repetir (doble toque, reintento): idempotente y sin segundo registro.
select pg_temp.actuar_como(pg_temp.u('a1'));
select is(pg_temp.agregar('e1', 'f1'), 'ok|true', 'repetir da ya_estaba');
select is(pg_temp.agregar('e1', 'f6'), 'ok|true', 'y una jornada que ya era de a1 desde antes también');
select pg_temp.actuar_como_servidor();
select is(pg_temp.n('acompaniamiento_agregado'), 1::bigint, 'nada se sumó: el cambio ya estaba hecho');

-- Los errores no dejan registro (y salen antes que el cambio).
select pg_temp.actuar_como(pg_temp.u('a1'));
select is(left(pg_temp.agregar('e1', 'f2'), 5), 'JO003', 'ya acompañada por otra persona: JO003');
select is(left(pg_temp.agregar('e1', 'f3'), 5), 'JO002', 'jornada abierta: JO002');
select is(left(pg_temp.agregar('e1', 'f7'), 5), 'JO001', 'colportor no inscripto: JO001');
select is(left(pg_temp.agregar('e1', 'f0'), 5), 'JO001', 'jornada inexistente: JO001');
select is(left(pg_temp.agregar('e2', 'f1'), 5), 'CZ011', 'campaña terminada: CZ011');
select is(left(pg_temp.agregar('e1', null), 5), '22023', 'sin jornada: 22023');
select is(left(pg_temp.agregar('ee', 'f1'), 5), 'CZ001', 'campaña inexistente: CZ001');
select pg_temp.actuar_como(pg_temp.u('a2'));
select is(left(pg_temp.agregar('e1', 'f5'), 5), '42501', 'coordinador de otra campaña: 42501');
select pg_temp.actuar_como(pg_temp.u('a0'));
select is(left(pg_temp.agregar('e1', 'f5'), 5), '42501', 'un colportor: 42501');
select pg_temp.actuar_como(pg_temp.u('ad'));
select is(left(pg_temp.agregar('e1', 'f4'), 5), 'JO004', 'el admin en su propia jornada: JO004');
select pg_temp.actuar_como_servidor();
select is(pg_temp.n('acompaniamiento_agregado'), 1::bigint, 'ningún error dejó registro');
select is(pg_temp.n(), (select n from base) + 1, 'y no se coló ningún otro evento');
select is((select acompaniante_id from public.jornada where id = pg_temp.u('f2')), pg_temp.u('a2'), 'la jornada de a2 no se pisó');

-- Un ADMIN también deja su registro: el actor es él.
select pg_temp.actuar_como(pg_temp.u('ad'));
select is(pg_temp.agregar('e1', 'f5'), 'ok|false', 'el admin agrega su acompañamiento a la jornada de b2');
select pg_temp.actuar_como_servidor();
select is(pg_temp.n('acompaniamiento_agregado'), 2::bigint, 'son dos registros');
select results_eq(
  $$select actor_user_id, target_user_id, fila_id from auditoria.audit_log
     where event_type = 'acompaniamiento_agregado' and fila_id = '01920000-0000-7000-8000-0000000073f5'::uuid$$,
  format($$values (%L::uuid, %L::uuid, %L::uuid)$$, pg_temp.u('ad'), pg_temp.u('b2'), pg_temp.u('f5')),
  'con el admin como actor');

-- Un registro lo escribe la misma transacción que el cambio: si el cambio se deshace, el registro también.
create or replace function pg_temp.agregar_y_fallar(p_camp text, p_jor text) returns text language plpgsql as $$
begin
  perform public.agregar_acompaniamiento(pg_temp.u(p_camp), pg_temp.u(p_jor));
  raise exception 'forzado' using errcode = 'P0001';
exception when others then
  return sqlstate;
end $$;
select pg_temp.actuar_como(pg_temp.u('a1'));
select is(pg_temp.agregar_y_fallar('e1', 'f8'), 'P0001', 'a1 agrega a la jornada f8 y la transacción falla después');
select pg_temp.actuar_como_servidor();
select is(pg_temp.n('acompaniamiento_agregado'), 2::bigint, 'al deshacerse el cambio, el registro se deshace con él');
select is((select acompaniante_id from public.jornada where id = pg_temp.u('f8')), null::uuid, 'y la jornada queda como estaba');

-- Los retornos de agregar_acompaniamiento (0100: dos parámetros opcionales y dos columnas al final).
select pg_temp.actuar_como(pg_temp.u('a1'));
select is((select count(*) from public.agregar_acompaniamiento(pg_temp.u('e1'), pg_temp.u('f8'))), 1::bigint,
          'agregar_acompaniamiento() sigue devolviendo una fila');
select pg_temp.actuar_como_servidor();
select is((select proargnames::text[] from pg_proc where oid = 'public.agregar_acompaniamiento(uuid,uuid,uuid,text)'::regprocedure),
          array['p_campania_id','p_jornada_id','p_acompaniante_id','p_nota','jornada_id','colportor_id','dia',
                'acompaniante_id','acompaniante_nombre','acompaniante_apellido','ya_estaba',
                'acompaniamiento_origen','acompaniamiento_nota'], 'con los dos parámetros opcionales de la 0100 y las dos columnas nuevas');
select is((select count(*) from pg_proc where proname = 'agregar_acompaniamiento' and pronamespace = 'public'::regnamespace),
          1::bigint, 'y es una sola función: la de dos argumentos ya no existe');
select is(has_function_privilege('authenticated', 'public.agregar_acompaniamiento(uuid,uuid,uuid,text)', 'execute'), true,
          'el coordinador sigue pudiendo llamarla');
select is(has_function_privilege('anon', 'public.agregar_acompaniamiento(uuid,uuid,uuid,text)', 'execute'), false, 'anon no');

select * from finish();
rollback;
