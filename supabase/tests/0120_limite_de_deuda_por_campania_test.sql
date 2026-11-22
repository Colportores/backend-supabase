-- pgTAP · límite de deuda único por campaña (migración 0120, backend-supabase#156, HU-STK-003, vista 35)
-- campania.limite_deuda (null = sin límite, >= 0, viaja en el pull); campania_colportor.limite_pedido ya no existe y
-- su trigger de candado sigue para la beca y las metas; definir_limite_de_deuda_de_campania() (permiso, terminada,
-- negativo, idempotencia, quitar el límite, el registro en audit_log también por el UPDATE directo del ADMIN);
-- supera_limite_de_deuda_por() / pedido_excede_limite_de_deuda() (sin límite, justo en el límite, por encima,
-- ya por encima antes del pedido, sin cuenta, cuenta dada de baja, campaña dada de baja o inexistente) y que
-- ninguna de las dos se ejecuta desde afuera.
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

-- El rol `authenticated` pero sin sesión: auth.uid() es null.
create or replace function pg_temp.actuar_sin_jwt() returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', '', true);
  perform set_config('request.jwt.claim.sub', '', true);
  perform set_config('request.jwt.claim.role', '', true);
  perform set_config('role', 'authenticated', true);
end $$;

create or replace function pg_temp.error_de(p_sql text) returns text language plpgsql as $$
begin
  execute p_sql;
  return 'ok';
exception when others then
  return sqlstate || ': ' || sqlerrm;
end $$;

-- Filas que toca un UPDATE (la RLS que no deja ver una fila no falla: toca 0).
create or replace function pg_temp.filas(p_sql text) returns integer language plpgsql as $$
declare n integer;
begin
  execute p_sql;
  get diagnostics n = row_count;
  return n;
end $$;

-- El uuid de un personaje del test (sufijo de dos caracteres HEX).
create or replace function pg_temp.u(p_sufijo text) returns uuid language sql immutable as $$
  select ('01920000-0000-7000-8000-0000000120' || p_sufijo)::uuid
$$;

-- Cuántos eventos de límite hay de una campaña, con el monto anterior y el nuevo (o sin filtrar).
-- SECURITY DEFINER: audit_log no la lee nadie con JWT.
create or replace function pg_temp.eventos(p_camp text, p_filtro jsonb default '{}'::jsonb)
returns integer language sql security definer as $$
  select count(*)::int from auditoria.audit_log a
   where a.event_type = 'limite_de_deuda_de_campania_cambiado'
     and a.fila_id = pg_temp.u(p_camp)
     and a.metadata @> p_filtro
$$;

-- Quién fue el actor de los registros de límite de una campaña.
create or replace function pg_temp.actores(p_camp text)
returns text language sql security definer as $$
  select string_agg(distinct a.actor_user_id::text, ',') from auditoria.audit_log a
   where a.event_type = 'limite_de_deuda_de_campania_cambiado' and a.fila_id = pg_temp.u(p_camp)
$$;

-- «¿Cuánto supera?» y «¿excede?» de un colportor en una campaña con un pedido; la función es interna, así que
-- el test la llama como el dueño.
create or replace function pg_temp.supera(p_colp text, p_camp text, p_monto bigint)
returns text language sql as $$
  select coalesce(public.supera_limite_de_deuda_por(pg_temp.u(p_colp), pg_temp.u(p_camp), p_monto)::text, 'null')
$$;
create or replace function pg_temp.excede(p_colp text, p_camp text, p_monto bigint)
returns text language sql as $$
  select public.pedido_excede_limite_de_deuda(pg_temp.u(p_colp), pg_temp.u(p_camp), p_monto)::text
$$;

-- --- fixtures ------------------------------------------------------------------
-- Staff: a1 coordinador de Con límite, Terminada, Borrada y Sin límite; a2 coordinador de Otra; ad admin;
--        a3 sin rol; a4 coordinador con el rol vencido.
-- Colportores: b1 Ana (debe $U 50.500, con cuenta) b2 Beto (debe $U 40.000) b3 Carla (sin cuenta)
--        b4 Diego (cuenta dada de baja con $U 99.999,99).
-- Campañas: e1 Con límite ($U 50.000 = 5.000.000 centavos, a1)  e2 Otra (sin límite, a2)  e3 Borrada (con límite)
--        e4 Terminada (a1, con límite, terminó el 30/06)  e5 Sin límite (a1).
insert into auth.users (id, instance_id, aud, role, email, encrypted_password, confirmed_at, created_at, updated_at)
select pg_temp.u(s), '00000000-0000-0000-0000-000000000000',
       'authenticated', 'authenticated', 'limite-' || s || '@example.com', 'x', now(), now(), now()
  from unnest(array['a1','a2','a3','a4','ad','b1','b2','b3','b4']) s;

insert into public.usuario_rol (usuario_id, rol_id)
select pg_temp.u(x.s), r.id
  from (values ('a1','COORDINADOR'), ('a2','COORDINADOR'), ('ad','ADMIN'),
               ('b1','COLPORTOR'), ('b2','COLPORTOR'), ('b3','COLPORTOR'), ('b4','COLPORTOR')) x(s, codigo)
  join public.rol r on r.codigo = x.codigo;
insert into public.usuario_rol (usuario_id, rol_id, valido_desde, valido_hasta)
select pg_temp.u('a4'), r.id, now() - interval '10 days', now() - interval '1 day'
  from public.rol r where r.codigo = 'COORDINADOR';

insert into public.campania (id, nombre, tipo, fecha_inicio, fecha_fin, coordinador_id, limite_deuda, deleted_at) values
  (pg_temp.u('e1'), 'Con límite', 'VERANO', '2026-08-03', '2099-12-31', pg_temp.u('a1'), 5000000, null),
  (pg_temp.u('e2'), 'Otra',       'VERANO', '2100-01-01', null,         pg_temp.u('a2'), null,    null),
  (pg_temp.u('e3'), 'Borrada',    'VERANO', '2026-08-03', null,         pg_temp.u('a1'), 1000,    now()),
  (pg_temp.u('e4'), 'Terminada',  'VERANO', '2026-04-01', '2026-06-30', pg_temp.u('a1'), 3000000, null),
  (pg_temp.u('e5'), 'Sin límite', 'VERANO', '2026-08-03', null,         pg_temp.u('a1'), null,    null);

insert into public.campania_colportor (id, campania_id, usuario_id, created_at) values
  (pg_temp.u('c1'), pg_temp.u('e1'), pg_temp.u('b1'), '2026-08-01 10:00-03'),
  (pg_temp.u('c2'), pg_temp.u('e2'), pg_temp.u('b2'), '2026-08-01 10:00-03');

insert into public.cuenta_colportor (usuario_id, deuda_total, deleted_at) values
  (pg_temp.u('b1'), 5050000, null),
  (pg_temp.u('b2'), 4000000, null),
  (pg_temp.u('b4'), 9999999, now());

-- ---------------------------------------------------------------------------
-- 1. La forma: la columna nueva, la vieja que se fue
-- ---------------------------------------------------------------------------
select has_column('public', 'campania', 'limite_deuda', 'campania.limite_deuda existe');
select col_type_is('public', 'campania', 'limite_deuda', 'bigint', 'limite_deuda es bigint (centavos)');
select col_is_null('public', 'campania', 'limite_deuda', 'limite_deuda es opcional (null = sin límite)');
select hasnt_column('public', 'campania_colportor', 'limite_pedido',
                    'el límite ya no es de la inscripción: campania_colportor.limite_pedido se fue');
select has_trigger('public', 'campania_colportor', 'campania_colportor_beca_y_limite',
                    'el candado de la beca y las metas sigue en campania_colportor');
select has_trigger('public', 'campania', 'campania_limite_deuda_auditar', 'campania tiene el trigger que audita el límite');
select is(pg_temp.error_de($$ update public.campania set limite_deuda = -1 where id = '01920000-0000-7000-8000-0000000120e1' $$),
          '23514: new row for relation "campania" violates check constraint "campania_limite_deuda_check"',
          'un límite negativo se rechaza');
select is(pg_temp.error_de($$ update public.campania set limite_deuda = 0 where id = '01920000-0000-7000-8000-0000000120e5' $$),
          'ok', 'cero es un límite válido (no se puede deber nada)');
select is(pg_temp.error_de($$ update public.campania set limite_deuda = null where id = '01920000-0000-7000-8000-0000000120e5' $$),
          'ok', 'y se vuelve a null');

-- Viaja en el pull: el motor serializa las columnas de la tabla (sync.expresion_json), sin lista aparte, así que
-- la campaña trae el límite. (El delta solo sirve filas commiteadas: este test va en una transacción, por eso se
-- mira la expresión y no un pull.)
select ok(sync.expresion_json('public.campania'::regclass) ~ 'limite_deuda',
          'el pull de campania serializa limite_deuda: la app avisa sin conexión');
select ok(sync.expresion_json('public.campania_colportor'::regclass) !~ 'limite_pedido',
          'y el de campania_colportor ya no lleva limite_pedido');
select is((select permite_push from sync.entidad where nombre = 'campania'), false,
          'campania sigue siendo solo de lectura para el teléfono: la app no escribe el límite');

-- Lo lee todo autenticado con la campaña; el colportor no lo cambia.
select pg_temp.actuar_como(pg_temp.u('b1'));
select is((select limite_deuda from public.campania where id = pg_temp.u('e1')), 5000000::bigint,
          'el colportor lee el límite de su campaña');
select is(pg_temp.filas($$ update public.campania set limite_deuda = 1 where id = '01920000-0000-7000-8000-0000000120e1' $$), 0,
          'pero no lo cambia por UPDATE directo');
select pg_temp.actuar_como(pg_temp.u('a1'));
select is(pg_temp.filas($$ update public.campania set limite_deuda = 1 where id = '01920000-0000-7000-8000-0000000120e1' $$), 0,
          'ni el coordinador: para eso está la función');
select pg_temp.actuar_como_servidor();
select is((select limite_deuda from public.campania where id = pg_temp.u('e1')), 5000000::bigint, 'el límite no se movió');

-- ---------------------------------------------------------------------------
-- 2. Las funciones: forma y privilegios
-- ---------------------------------------------------------------------------
select pg_temp.actuar_como(pg_temp.u('a1'));
select is((select array(select k from jsonb_object_keys(
                  (select to_jsonb(r) from public.definir_limite_de_deuda_de_campania(pg_temp.u('e1'), 5000000) r limit 1)) k
                 order by k collate "C")),
          array['cambio','limite_deuda'],
          'definir_limite_de_deuda_de_campania: la forma de la respuesta');
select pg_temp.actuar_como_servidor();

select is((select p.prosecdef from pg_proc p where p.oid = 'public.definir_limite_de_deuda_de_campania(uuid, bigint)'::regprocedure),
          true, 'definir es SECURITY DEFINER (el coordinador no escribe campania)');
select is((select p.proconfig from pg_proc p where p.oid = 'public.definir_limite_de_deuda_de_campania(uuid, bigint)'::regprocedure),
          array['search_path=""'], 'definir fija search_path vacío');
select ok(has_function_privilege('authenticated', 'public.definir_limite_de_deuda_de_campania(uuid, bigint)', 'execute'),
          'authenticated ejecuta definir');
select ok(not has_function_privilege('anon', 'public.definir_limite_de_deuda_de_campania(uuid, bigint)', 'execute'),
          'anon NO ejecuta definir');
select ok(not has_function_privilege('service_role', 'public.definir_limite_de_deuda_de_campania(uuid, bigint)', 'execute'),
          'service_role NO ejecuta definir (sin sesión no hay permiso que comprobar)');
select is((select count(*)::int
             from pg_proc p, aclexplode(p.proacl) a
            where a.grantee = 0 and a.privilege_type = 'EXECUTE'
              and p.oid in ('public.definir_limite_de_deuda_de_campania(uuid, bigint)'::regprocedure,
                            'public.supera_limite_de_deuda_por(uuid, uuid, bigint)'::regprocedure,
                            'public.pedido_excede_limite_de_deuda(uuid, uuid, bigint)'::regprocedure,
                            'public.tg_campania_limite_deuda_auditar()'::regprocedure)),
          0, 'ninguna tiene EXECUTE para PUBLIC');
select is((select count(*)::int from pg_proc p
            where p.pronamespace = 'public'::regnamespace
              and p.proname in ('definir_limite_de_deuda_de_campania', 'supera_limite_de_deuda_por',
                                'pedido_excede_limite_de_deuda')),
          3, 'hay una sola firma de cada una');
select ok(not has_function_privilege('authenticated', 'public.tg_campania_limite_deuda_auditar()', 'execute'),
          'la función del trigger no se llama desde afuera');

-- Las dos de medir reciben un colportor cualquiera: no las ejecuta nadie con JWT ni el servidor.
select ok(not has_function_privilege('authenticated', 'public.supera_limite_de_deuda_por(uuid, uuid, bigint)', 'execute')
          and not has_function_privilege('anon', 'public.supera_limite_de_deuda_por(uuid, uuid, bigint)', 'execute')
          and not has_function_privilege('service_role', 'public.supera_limite_de_deuda_por(uuid, uuid, bigint)', 'execute'),
          'supera_limite_de_deuda_por no se ejecuta desde afuera (lee la deuda de cualquiera)');
select ok(not has_function_privilege('authenticated', 'public.pedido_excede_limite_de_deuda(uuid, uuid, bigint)', 'execute')
          and not has_function_privilege('anon', 'public.pedido_excede_limite_de_deuda(uuid, uuid, bigint)', 'execute')
          and not has_function_privilege('service_role', 'public.pedido_excede_limite_de_deuda(uuid, uuid, bigint)', 'execute'),
          'pedido_excede_limite_de_deuda tampoco');
select is((select p.provolatile from pg_proc p where p.oid = 'public.supera_limite_de_deuda_por(uuid, uuid, bigint)'::regprocedure),
          's', 'supera_limite_de_deuda_por es STABLE: solo lee');
select is((select p.proconfig from pg_proc p where p.oid = 'public.supera_limite_de_deuda_por(uuid, uuid, bigint)'::regprocedure),
          array['search_path=""'], 'y fija search_path vacío');
select pg_temp.actuar_como(pg_temp.u('a1'));
select throws_ok($$ select public.supera_limite_de_deuda_por('01920000-0000-7000-8000-0000000120b1',
                                                              '01920000-0000-7000-8000-0000000120e1', 1) $$,
  '42501', null, 'un coordinador no puede preguntar la deuda de un colportor por esta puerta');
select pg_temp.actuar_como_servidor();

-- ---------------------------------------------------------------------------
-- 3. Acceso a definir: el permiso es lo primero
-- ---------------------------------------------------------------------------
select throws_ok($$ select * from public.definir_limite_de_deuda_de_campania('01920000-0000-7000-8000-0000000120e1', 1) $$,
  '42501', null, 'definir: sin JWT (el servidor) falla');

select pg_temp.actuar_sin_jwt();
select throws_ok($$ select * from public.definir_limite_de_deuda_de_campania('01920000-0000-7000-8000-0000000120e1', 1) $$,
  '42501', null, 'definir: authenticated sin sesión falla');

select pg_temp.actuar_como(pg_temp.u('b1'));
select throws_ok($$ select * from public.definir_limite_de_deuda_de_campania('01920000-0000-7000-8000-0000000120e1', 1) $$,
  '42501', 'Solo el coordinador de la campaña o un administrador puede cambiar su límite de deuda. Entrá con la cuenta del coordinador de esta campaña.',
  'definir: un colportor no cambia el límite');

select pg_temp.actuar_como(pg_temp.u('a3'));
select throws_ok($$ select * from public.definir_limite_de_deuda_de_campania('01920000-0000-7000-8000-0000000120e1', 1) $$,
  '42501', null, 'definir: sin ningún rol falla');

select pg_temp.actuar_como(pg_temp.u('a4'));
select throws_ok($$ select * from public.definir_limite_de_deuda_de_campania('01920000-0000-7000-8000-0000000120e1', 1) $$,
  '42501', null, 'definir: con el rol de coordinador vencido falla');

select pg_temp.actuar_como(pg_temp.u('a2'));
select throws_ok($$ select * from public.definir_limite_de_deuda_de_campania('01920000-0000-7000-8000-0000000120e1', 1) $$,
  '42501', null, 'definir: el coordinador de otra campaña falla');

select pg_temp.actuar_como(pg_temp.u('a1'));
select throws_ok($$ select * from public.definir_limite_de_deuda_de_campania('01920000-0000-7000-8000-0000000120e2', 1) $$,
  '42501', null, 'definir: el coordinador no cambia el de la campaña de otro');
select throws_ok($$ select * from public.definir_limite_de_deuda_de_campania('01920000-0000-7000-8000-0000000120e3', 1) $$,
  'CZ001', null, 'definir: una campaña dada de baja no existe');
select throws_ok($$ select * from public.definir_limite_de_deuda_de_campania('01920000-0000-7000-8000-0000000120fe', 1) $$,
  'CZ001', null, 'definir: una campaña inexistente no existe');
select throws_ok($$ select * from public.definir_limite_de_deuda_de_campania(null, 1) $$,
  'CZ001', null, 'definir: sin campaña, CZ001');
select pg_temp.actuar_como_servidor();
select is(pg_temp.eventos('e1') + pg_temp.eventos('e2') + pg_temp.eventos('e3'), 0,
          'ninguno de esos intentos dejó registro');

-- ---------------------------------------------------------------------------
-- 4. definir: el monto, la idempotencia y el registro
-- ---------------------------------------------------------------------------
create temp table antes as select c.sync_version from public.campania c where c.id = pg_temp.u('e1');
grant select on antes to authenticated;
select pg_temp.actuar_como(pg_temp.u('a1'));

select is((select format('%s|%s', r.limite_deuda, r.cambio) from public.definir_limite_de_deuda_de_campania(pg_temp.u('e1'), 6000000) r),
          '6000000|t', 'definir: el coordinador cambia el límite (50.000 a 60.000)');
select is((select c.limite_deuda from public.campania c where c.id = pg_temp.u('e1')), 6000000::bigint,
          'definir: la campaña quedó con el límite nuevo');
select ok((select c.sync_version > (select a.sync_version from antes a) from public.campania c where c.id = pg_temp.u('e1')),
          'definir: la campaña sube su versión (los teléfonos reciben el límite nuevo por el pull)');
select is(pg_temp.eventos('e1'), 1, 'definir: quedó un registro en audit_log');
select is(pg_temp.eventos('e1', '{"monto_anterior":5000000,"monto_nuevo":6000000}'), 1,
          'definir: el registro lleva el monto anterior y el nuevo');
select is(pg_temp.actores('e1'), pg_temp.u('a1')::text, 'definir: el actor del registro es el coordinador');

select pg_temp.actuar_como_servidor();
create temp table antes2 as select c.sync_version from public.campania c where c.id = pg_temp.u('e1');
grant select on antes2 to authenticated;
select pg_temp.actuar_como(pg_temp.u('a1'));
select is((select format('%s|%s', r.limite_deuda, r.cambio) from public.definir_limite_de_deuda_de_campania(pg_temp.u('e1'), 6000000) r),
          '6000000|f', 'definir: el mismo valor no cambia nada (idempotente)');
select is(pg_temp.eventos('e1'), 1, 'definir: y no deja un segundo registro');
select is((select c.sync_version from public.campania c where c.id = pg_temp.u('e1')),
          (select a.sync_version from antes2 a), 'definir: ni sube la versión de la campaña');

select is((select format('%s|%s', coalesce(r.limite_deuda::text, 'null'), r.cambio)
             from public.definir_limite_de_deuda_de_campania(pg_temp.u('e1'), null) r),
          'null|t', 'definir: null = la campaña deja de tener límite');
select is(pg_temp.eventos('e1', '{"monto_anterior":6000000,"monto_nuevo":null}'), 1,
          'definir: el registro del null lleva el monto nuevo en null');
select is((select format('%s|%s', coalesce(r.limite_deuda::text, 'null'), r.cambio)
             from public.definir_limite_de_deuda_de_campania(pg_temp.u('e1'), null) r),
          'null|f', 'definir: null sobre null tampoco cambia nada');
select is((select format('%s|%s', r.limite_deuda, r.cambio) from public.definir_limite_de_deuda_de_campania(pg_temp.u('e1'), 0) r),
          '0|t', 'definir: cero es un límite válido');
select is(pg_temp.eventos('e1'), 3, 'definir: tres cambios, tres registros');

select throws_ok($$ select * from public.definir_limite_de_deuda_de_campania('01920000-0000-7000-8000-0000000120e1', -1) $$,
  '22023', 'El límite de deuda no puede ser negativo. Escribí un monto de cero o más, o dejalo vacío si la campaña no tiene límite.',
  'definir: un monto negativo se rechaza con un aviso que guía');
select is((select c.limite_deuda from public.campania c where c.id = pg_temp.u('e1')), 0::bigint,
          'definir: el rechazo no cambió el límite');
select is(pg_temp.eventos('e1'), 3, 'definir: ni dejó registro');

select is((select format('%s|%s', r.limite_deuda, r.cambio) from public.definir_limite_de_deuda_de_campania(pg_temp.u('e1'), 5000000) r),
          '5000000|t', 'definir: vuelve a 5.000.000');

-- La campaña terminada no se toca.
select throws_ok($$ select * from public.definir_limite_de_deuda_de_campania('01920000-0000-7000-8000-0000000120e4', 1) $$,
  'CZ011', 'La campaña ya terminó y su límite de deuda queda como estaba. Elegí una campaña en curso.',
  'definir: una campaña terminada no cambia su límite');
select is((select c.limite_deuda from public.campania c where c.id = pg_temp.u('e4')), 3000000::bigint,
          'definir: la terminada sigue con su límite');
select is(pg_temp.eventos('e4'), 0, 'definir: y sin registro');

-- Una campaña sin límite lo puede estrenar.
select is((select format('%s|%s', r.limite_deuda, r.cambio) from public.definir_limite_de_deuda_de_campania(pg_temp.u('e5'), 100) r),
          '100|t', 'definir: una campaña sin límite lo estrena');
select is((select format('%s|%s', coalesce(r.limite_deuda::text, 'null'), r.cambio)
             from public.definir_limite_de_deuda_de_campania(pg_temp.u('e5'), null) r),
          'null|t', 'y lo vuelve a quitar');

-- El ADMIN: cualquier campaña, y su UPDATE directo también deja registro.
select pg_temp.actuar_como(pg_temp.u('ad'));
select is((select format('%s|%s', r.limite_deuda, r.cambio) from public.definir_limite_de_deuda_de_campania(pg_temp.u('e2'), 7000000) r),
          '7000000|t', 'definir: el ADMIN cambia el límite de cualquier campaña');
select is(pg_temp.eventos('e2', '{"monto_anterior":null,"monto_nuevo":7000000}'), 1, 'definir: y queda su registro');
select is(pg_temp.actores('e2'), pg_temp.u('ad')::text, 'definir: con el ADMIN como actor');
update public.campania set limite_deuda = 8000000 where id = pg_temp.u('e2');
select is(pg_temp.eventos('e2', '{"monto_anterior":7000000,"monto_nuevo":8000000}'), 1,
          'el UPDATE directo del ADMIN también deja registro (lo escribe el trigger)');
update public.campania set nombre = 'Otra campaña' where id = pg_temp.u('e2');
select is(pg_temp.eventos('e2'), 2, 'cambiar otra columna no deja registro de límite');
update public.campania set limite_deuda = 8000000 where id = pg_temp.u('e2');
select is(pg_temp.eventos('e2'), 2, 'ni un UPDATE que deja el mismo límite');

select pg_temp.actuar_como(pg_temp.u('a2'));
select is(pg_temp.filas($$ update public.campania set limite_deuda = 1 where id = '01920000-0000-7000-8000-0000000120e2' $$),
          0, 'un coordinador no cambia el límite por UPDATE directo (solo por la función)');
select pg_temp.actuar_como_servidor();
select is(pg_temp.eventos('e2'), 2, 'y ese intento no dejó registro');

-- ---------------------------------------------------------------------------
-- 5. Cuánto supera el límite un pedido (e1: límite 5.000.000)
-- ---------------------------------------------------------------------------
-- El ejemplo del issue: Ana (b1) debe 5.050.000 y pide 1.000.000: 6.050.000 contra 5.000.000.
select is(pg_temp.supera('b1', 'e1', 1000000), '1050000', 'Ana debe 50.500 y pide 10.000: supera el límite de 50.000 por 10.500');
select is(pg_temp.excede('b1', 'e1', 1000000), 'true', 'y el pedido excede el límite');
-- Beto (b2) debe 4.000.000: con 1.000.000 llega JUSTO al límite.
select is(pg_temp.supera('b2', 'e1', 1000000), 'null', 'justo en el límite NO lo supera (4.000.000 + 1.000.000 = 5.000.000)');
select is(pg_temp.excede('b2', 'e1', 1000000), 'false', 'y no excede');
select is(pg_temp.supera('b2', 'e1', 1000001), '1', 'un centavo por encima lo supera por 1');
select is(pg_temp.excede('b2', 'e1', 1000001), 'true', 'y excede');
select is(pg_temp.supera('b2', 'e1', 999999), 'null', 'un centavo por debajo no lo supera');
select is(pg_temp.excede('b2', 'e1', 999999), 'false', 'y no excede');
-- Un pedido ya autorizado: su monto ya está en la deuda, se pasa 0.
select is(pg_temp.supera('b1', 'e1', 0), '50000', 'con el pedido ya en la deuda (0), Ana ya está 500 por encima');
select is(pg_temp.supera('b2', 'e1', 0), 'null', 'Beto con 0 no supera nada');
select is(pg_temp.supera('b1', 'e1', null), '50000', 'un monto null cuenta como 0');
-- Sin cuenta, la deuda es 0; con la cuenta dada de baja, también.
select is(pg_temp.supera('b3', 'e1', 5000000), 'null', 'sin cuenta (deuda 0), un pedido igual al límite no lo supera');
select is(pg_temp.supera('b3', 'e1', 5000001), '1', 'y uno de un centavo más sí');
select is(pg_temp.supera('b4', 'e1', 1000000), 'null', 'una cuenta dada de baja no cuenta: deuda 0');
-- Sin límite, nunca excede; también donde el colportor debe mucho.
select is(pg_temp.supera('b1', 'e5', 99999999), 'null', 'campaña sin límite: no supera nada');
select is(pg_temp.excede('b1', 'e5', 99999999), 'false', 'y no excede');
select is(pg_temp.excede('b3', 'e5', 99999999), 'false', 'tampoco para un colportor sin deuda');
-- Campaña dada de baja, inexistente o sin campaña: sin límite que comparar.
select is(pg_temp.supera('b1', 'e3', 99999999), 'null', 'campaña dada de baja: sin límite');
select is(pg_temp.excede('b1', 'e3', 99999999), 'false', 'y no excede');
select is(pg_temp.supera('b1', 'fe', 99999999), 'null', 'campaña inexistente: sin límite');
select is(public.supera_limite_de_deuda_por(pg_temp.u('b1'), null, 1), null::bigint, 'sin campaña: null');
select is(public.pedido_excede_limite_de_deuda(pg_temp.u('b1'), null, 1), false, 'sin campaña no excede');
-- Un límite de cero: deber algo ya lo supera, no deber nada no.
update public.campania set limite_deuda = 0 where id = pg_temp.u('e1');
select is(pg_temp.supera('b3', 'e1', 0), 'null', 'límite 0: pedir nada sin deber nada no lo supera');
select is(pg_temp.supera('b3', 'e1', 1), '1', 'límite 0: pedir un centavo lo supera por 1');
-- Cambiar el límite cambia la respuesta al instante, para todos los colportores de la campaña.
update public.campania set limite_deuda = 6050000 where id = pg_temp.u('e1');
select is(pg_temp.supera('b1', 'e1', 1000000), 'null', 'con el límite en 60.500 Ana queda justo: ya no lo supera');
select is(pg_temp.supera('b1', 'e1', 1000001), '1', 'y un centavo más sí');
update public.campania set limite_deuda = null where id = pg_temp.u('e1');
select is(pg_temp.excede('b1', 'e1', 99999999), 'false', 'quitar el límite deja de avisar');
-- La deuda sube y la medida la sigue.
update public.campania set limite_deuda = 5000000 where id = pg_temp.u('e1');
update public.cuenta_colportor set deuda_total = deuda_total + 1000000 where usuario_id = pg_temp.u('b2');
select is(pg_temp.supera('b2', 'e1', 1), '1', 'Beto, con 50.000 de deuda, supera por 1 con un centavo de pedido');
select is(pg_temp.supera('b2', 'e1', 0), 'null', 'y con 0 queda justo en el límite');

-- Un colportor en dos campañas se mide contra el límite de la campaña que se nombra.
select is(pg_temp.excede('b1', 'e1', 1), 'true', 'Ana contra el límite de e1');
select is(pg_temp.excede('b1', 'e2', 1), 'false', 'y contra e2 (límite de 80.000) no');

-- ---------------------------------------------------------------------------
-- 6. El candado de la beca y las metas sigue en pie
-- ---------------------------------------------------------------------------
select pg_temp.actuar_como(pg_temp.u('a1'));
select is(pg_temp.filas($$ update public.campania_colportor set tipo_beca = 'MEDIA' where id = '01920000-0000-7000-8000-0000000120c1' $$), 1,
          'el coordinador de la campaña sigue dando la beca');
select pg_temp.actuar_como(pg_temp.u('a2'));
select is(pg_temp.error_de($$ update public.campania_colportor set tipo_beca = 'COMPLETA' where id = '01920000-0000-7000-8000-0000000120c1' $$),
          '42501: La beca y la meta las fija el coordinador de la campaña',
          'y el de otra campaña no');
select pg_temp.actuar_como_servidor();

select * from finish();
rollback;
