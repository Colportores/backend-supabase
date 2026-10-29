-- pgTAP · alquiler como deuda aparte, por campaña, y las cuentas del equipo (migración 0114,
-- backend-supabase#111, HU-CTA-005, HU-CTA-007, HU-CAM-002, vista 36)
-- deposito.campania_id (obligatoria con concepto ALQUILER); definir_alquiler_de_campania() (permiso,
-- terminada, monto negativo, idempotencia, quitar el alquiler, el registro en audit_log también por el
-- UPDATE directo del ADMIN); cuentas_de_campania() (la forma de la respuesta, el permiso primero, las
-- cifras del snapshot, el alquiler de ESTA campaña: pagado solo con ticket validado, por validar, rechazado,
-- dado de baja, de otra campaña, pagado de más, campaña sin alquiler, saldos separados por campaña, el
-- recálculo al cambiar el monto, el que se inscribe después, el de baja) y que el alquiler no bloquea.
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

-- El uuid de un personaje del test (sufijo de dos caracteres HEX).
create or replace function pg_temp.u(p_sufijo text) returns uuid language sql immutable as $$
  select ('01920000-0000-7000-8000-0000000114' || p_sufijo)::uuid
$$;

-- El alquiler de un colportor en una campaña, como texto: monto|pagado|por_validar|debe|ultimo_pago (día).
create or replace function pg_temp.alq(p_camp text, p_colp text)
returns text language sql as $$
  select coalesce((
    select format('%s|%s|%s|%s|%s', coalesce(r.alquiler_monto::text, 'null'), r.alquiler_pagado,
                  r.alquiler_por_validar, coalesce(r.alquiler_debe::text, 'null'),
                  coalesce(to_char(r.alquiler_ultimo_pago_fecha at time zone 'UTC', 'YYYY-MM-DD'), 'null'))
      from public.cuentas_de_campania(pg_temp.u(p_camp)) r
     where r.colportor_id = pg_temp.u(p_colp)), 'sin fila')
$$;

-- Cuántos eventos de alquiler hay de una campaña, con el monto anterior y el nuevo (o sin filtrar).
-- SECURITY DEFINER: audit_log no la lee nadie con JWT.
create or replace function pg_temp.eventos(p_camp text, p_filtro jsonb default '{}'::jsonb)
returns integer language sql security definer as $$
  select count(*)::int from auditoria.audit_log a
   where a.event_type = 'alquiler_de_campania_cambiado'
     and a.fila_id = pg_temp.u(p_camp)
     and a.metadata @> p_filtro
$$;

-- --- fixtures ------------------------------------------------------------------
-- Staff: a1 coordinador de Cuentas, Sin alquiler, Terminada y Vacía; a2 coordinador de Otra; ad admin;
--        a0 colportor sin campaña; a3 sin rol; a4 coordinador con el rol vencido.
-- Colportores (campaña Cuentas, e1): b1 Alfa (zona Centro; también en Otra) b2 Bravo (zona Centro; también en
--        Terminada) b3 Cruz (inscripción de baja) b4 Duarte (sin zona, pagó de más) b5 Eguren.
--        b6 Fuentes está en Sin alquiler.
-- Campañas: e1 Cuentas (alquiler 150000, hasta 2099)  e2 Otra (a2, alquiler 100000, desde 2100)
--        e3 Sin alquiler (null)  e4 Borrada  e5 Terminada (a1, 90000, terminó el 30/06)  e6 Vacía.
-- Las fechas de e1 y e2 no se pisan (un colportor no está en dos campañas a la vez).
insert into auth.users (id, instance_id, aud, role, email, encrypted_password, confirmed_at, created_at, updated_at)
select pg_temp.u(s), '00000000-0000-0000-0000-000000000000',
       'authenticated', 'authenticated', 'cuentas-' || s || '@example.com', 'x', now(), now(), now()
  from unnest(array['a0','a1','a2','a3','a4','ad','b1','b2','b3','b4','b5','b6','b7']) s;

update public.usuario u set nombre = x.n, apellido = x.a
  from (values ('b1','Ana','Alfa'), ('b2','Beto','Bravo'), ('b3','Carla','Cruz'),
               ('b4','Diego','Duarte'), ('b5','Elena','Eguren'), ('b6','Fede','Fuentes'),
               ('b7','Gabi','Gómez')) x(s, n, a)
 where u.id = pg_temp.u(x.s);

insert into public.usuario_rol (usuario_id, rol_id)
select pg_temp.u(x.s), r.id
  from (values ('a1','COORDINADOR'), ('a2','COORDINADOR'), ('ad','ADMIN'), ('a0','COLPORTOR'),
               ('b1','COLPORTOR'), ('b2','COLPORTOR'), ('b3','COLPORTOR'), ('b4','COLPORTOR'),
               ('b5','COLPORTOR'), ('b6','COLPORTOR'), ('b7','COLPORTOR')) x(s, codigo)
  join public.rol r on r.codigo = x.codigo;
insert into public.usuario_rol (usuario_id, rol_id, valido_desde, valido_hasta)
select pg_temp.u('a4'), r.id, now() - interval '10 days', now() - interval '1 day'
  from public.rol r where r.codigo = 'COORDINADOR';

insert into public.pais (id, nombre, iso_code) values (pg_temp.u('c0'), 'Pais cuentas', 'ZU');
insert into public.ciudad (id, nombre, departamento, pais_id, lat_centro, lon_centro, zoom_inicial) values
  (pg_temp.u('c1'), 'Ciudad uno q111', 'Departamento de prueba uno', pg_temp.u('c0'), -34.91, -56.18, 13);

insert into public.campania (id, nombre, tipo, fecha_inicio, fecha_fin, coordinador_id, alquiler_monto, deleted_at) values
  (pg_temp.u('e1'), 'Cuentas',       'VERANO', '2026-08-03', '2099-12-31', pg_temp.u('a1'), 150000, null),
  (pg_temp.u('e2'), 'Otra',          'VERANO', '2100-01-01', null,         pg_temp.u('a2'), 100000, null),
  (pg_temp.u('e3'), 'Sin alquiler',  'VERANO', '2026-08-03', null,         pg_temp.u('a1'), null,   null),
  (pg_temp.u('e4'), 'Borrada',       'VERANO', '2026-08-03', null,         pg_temp.u('a1'), 1000,   now()),
  (pg_temp.u('e5'), 'Terminada',     'VERANO', '2026-04-01', '2026-06-30', pg_temp.u('a1'), 90000,  null),
  (pg_temp.u('e6'), 'Vacía',         'VERANO', '2026-08-03', null,         pg_temp.u('a1'), 5000,   null);
insert into public.campania_ciudad (id, campania_id, ciudad_id) values
  (pg_temp.u('71'), pg_temp.u('e1'), pg_temp.u('c1'));
insert into public.zona (id, nombre, campania_ciudad_id, tipo_forma, color, poligono_geojson) values
  (pg_temp.u('d1'), 'Centro', pg_temp.u('71'), 'ESQUINAS', '#112233',
   '{"type":"Polygon","coordinates":[[[-56.19,-34.92],[-56.17,-34.92],[-56.17,-34.91],[-56.19,-34.91],[-56.19,-34.92]]]}'::jsonb);

insert into public.campania_colportor (campania_id, usuario_id, zona_id, created_at) values
  (pg_temp.u('e1'), pg_temp.u('b1'), pg_temp.u('d1'), '2026-08-01 10:00-03'),
  (pg_temp.u('e1'), pg_temp.u('b2'), pg_temp.u('d1'), '2026-08-01 10:00-03'),
  (pg_temp.u('e1'), pg_temp.u('b3'), null,            '2026-08-01 10:00-03'),
  (pg_temp.u('e1'), pg_temp.u('b4'), null,            '2026-08-01 10:00-03'),
  (pg_temp.u('e1'), pg_temp.u('b5'), pg_temp.u('d1'), '2026-08-01 10:00-03'),
  (pg_temp.u('e2'), pg_temp.u('b1'), null,            '2026-07-01 10:00-03'),
  (pg_temp.u('e3'), pg_temp.u('b6'), null,            '2026-08-01 10:00-03'),
  (pg_temp.u('e5'), pg_temp.u('b2'), null,            '2026-03-20 10:00-03');
update public.campania_colportor set deleted_at = '2026-09-15 12:00:00+00'
 where campania_id = pg_temp.u('e1') and usuario_id = pg_temp.u('b3');

-- La cuenta (snapshot) de b1; la de b2 está dada de baja (no cuenta).
insert into public.cuenta_colportor (usuario_id, deuda_total, dinero_depositado, dinero_en_mano, dinero_por_cobrar, deleted_at) values
  (pg_temp.u('b1'), 1200000, 500000, 30000, 80000, null),
  (pg_temp.u('b2'), 777,     777,    777,   777,   now());

-- Tickets (el estado de cada uno) y depósitos.
insert into public.ticket (id, usuario_id, tipo, estado, motivo_rechazo) values
  (pg_temp.u('51'), pg_temp.u('b1'), 'DEPOSITO', 'VALIDADO',  null),
  (pg_temp.u('52'), pg_temp.u('b1'), 'DEPOSITO', 'PENDIENTE', null),
  (pg_temp.u('53'), pg_temp.u('b1'), 'DEPOSITO', 'RECHAZADO', 'No se ve el monto'),
  (pg_temp.u('54'), pg_temp.u('b1'), 'DEPOSITO', 'VALIDADO',  null),
  (pg_temp.u('55'), pg_temp.u('b1'), 'DEPOSITO', 'VALIDADO',  null),
  (pg_temp.u('56'), pg_temp.u('b1'), 'DEPOSITO', 'VALIDADO',  null),
  (pg_temp.u('57'), pg_temp.u('b1'), 'DEPOSITO', 'VALIDADO',  null),
  (pg_temp.u('58'), pg_temp.u('b4'), 'DEPOSITO', 'VALIDADO',  null),
  (pg_temp.u('59'), pg_temp.u('b6'), 'DEPOSITO', 'VALIDADO',  null),
  -- Comprobantes de los depósitos de casa editora y de los de prueba (0122: banco u oficina llevan ticket).
  (pg_temp.u('5a'), pg_temp.u('b1'), 'DEPOSITO', 'PENDIENTE', null),
  (pg_temp.u('5b'), pg_temp.u('b1'), 'DEPOSITO', 'PENDIENTE', null),
  (pg_temp.u('5c'), pg_temp.u('b1'), 'DEPOSITO', 'PENDIENTE', null),
  (pg_temp.u('5d'), pg_temp.u('b1'), 'DEPOSITO', 'PENDIENTE', null);

-- b1 en Cuentas (e1): 50000 validado (01/09) + 25000 validado (08/09) = 75000 pagado; 30000 con el ticket
--   pendiente y 20000 sin ticket (un retiro) = 50000 por validar; el de 99999 con el ticket rechazado, el de
--   40000 dado de baja y el de 70000 de OTRA campaña no cuentan. En Otra (e2): 70000 validado.
--   De casa editora: 10000 (10/09) es el último; el de 5000 (02/09) es anterior; el de 99 (20/09) está dado
--   de baja.
insert into public.deposito (id, colportor_id, monto, fecha, ticket_id, destino, concepto, campania_id, deleted_at) values
  (pg_temp.u('f1'), pg_temp.u('b1'), 50000, '2026-09-01 10:00+00', pg_temp.u('51'), 'BANCO',              'ALQUILER',     pg_temp.u('e1'), null),
  (pg_temp.u('f2'), pg_temp.u('b1'), 30000, '2026-09-05 10:00+00', pg_temp.u('52'), 'BANCO',              'ALQUILER',     pg_temp.u('e1'), null),
  (pg_temp.u('f3'), pg_temp.u('b1'), 20000, '2026-09-12 10:00+00', null,            'RETIRO_COORDINADOR', 'ALQUILER',     pg_temp.u('e1'), null),
  (pg_temp.u('f4'), pg_temp.u('b1'), 99999, '2026-09-07 10:00+00', pg_temp.u('53'), 'BANCO',              'ALQUILER',     pg_temp.u('e1'), null),
  (pg_temp.u('f5'), pg_temp.u('b1'), 70000, '2026-09-09 10:00+00', pg_temp.u('54'), 'BANCO',              'ALQUILER',     pg_temp.u('e2'), null),
  (pg_temp.u('f6'), pg_temp.u('b1'), 10000, '2026-09-10 10:00+00', pg_temp.u('55'), 'BANCO',              'CASA_EDITORA', null,            null),
  (pg_temp.u('f7'), pg_temp.u('b1'), 5000,  '2026-09-02 10:00+00', pg_temp.u('56'), 'BANCO',              'CASA_EDITORA', pg_temp.u('e1'), null),
  (pg_temp.u('f8'), pg_temp.u('b1'), 99,    '2026-09-20 10:00+00', pg_temp.u('5c'), 'OFICINA',            'CASA_EDITORA', null,            now()),
  (pg_temp.u('f9'), pg_temp.u('b1'), 40000, '2026-09-11 10:00+00', pg_temp.u('57'), 'BANCO',              'ALQUILER',     pg_temp.u('e1'), now()),
  (pg_temp.u('fa'), pg_temp.u('b1'), 25000, '2026-09-08 10:00+00', pg_temp.u('57'), 'BANCO',              'ALQUILER',     pg_temp.u('e1'), null),
  (pg_temp.u('fb'), pg_temp.u('b4'), 200000, '2026-09-03 10:00+00', pg_temp.u('58'), 'BANCO',             'ALQUILER',     pg_temp.u('e1'), null),
  (pg_temp.u('fd'), pg_temp.u('b1'), 3000,  '2026-09-15 10:00+00', pg_temp.u('5d'), 'OFICINA',            'CASA_EDITORA', pg_temp.u('e2'), null),
  (pg_temp.u('fc'), pg_temp.u('b6'), 15000, '2026-09-04 10:00+00', pg_temp.u('59'), 'BANCO',              'ALQUILER',     pg_temp.u('e3'), null);

-- Desde 0129 el depósito lleva su propia validación y es lo que cuenta como pagado: los que tienen el ticket
-- VALIDADO quedan validados (como los deja el backfill de la migración).
update public.deposito d
   set validado_en = d.fecha
  from public.ticket t
 where t.id = d.ticket_id and t.estado = 'VALIDADO';

-- Donde cuelga una venta (para probar que el alquiler no bloquea vender).
insert into public.ubicacion (id, tipo, calle, numero, lat, lon, ciudad_id)
values (pg_temp.u('f0'), 'CASA', 'Calle de prueba', '1', -34.915, -56.18, pg_temp.u('c1'));
insert into public.espacio (id, ubicacion_id) values (pg_temp.u('ee'), pg_temp.u('f0'));
insert into public.espacio_persona (id, espacio_id, persona_id)
values (pg_temp.u('ef'), pg_temp.u('ee'), pg_temp.u('ed'));

-- ---------------------------------------------------------------------------
-- 1. deposito.campania_id
-- ---------------------------------------------------------------------------
select has_column('public', 'deposito', 'campania_id', 'deposito.campania_id existe');
select col_is_fk('public', 'deposito', 'campania_id', 'deposito.campania_id es FK a campania');

-- Quién fue el actor de los registros de alquiler de una campaña. SECURITY DEFINER: audit_log no la lee nadie con JWT.
create or replace function pg_temp.actores(p_camp text)
returns text language sql security definer as $$
  select string_agg(distinct a.actor_user_id::text, ',') from auditoria.audit_log a
   where a.event_type = 'alquiler_de_campania_cambiado' and a.fila_id = pg_temp.u(p_camp)
$$;
-- Filas que toca un UPDATE (la RLS que no deja ver una fila no falla: toca 0).
create or replace function pg_temp.filas(p_sql text) returns integer language plpgsql as $$
declare n integer;
begin
  execute p_sql;
  get diagnostics n = row_count;
  return n;
end $$;

savepoint s_deposito;
select is(pg_temp.error_de($$ insert into public.deposito (colportor_id, monto, destino, concepto)
            values ('01920000-0000-7000-8000-0000000114b5', 100, 'BANCO', 'ALQUILER') $$),
          '23514: new row for relation "deposito" violates check constraint "deposito_pago_de_alquiler_con_campania_check"',
          'un depósito de ALQUILER sin campaña se rechaza');
select is(pg_temp.error_de($$ insert into public.deposito (colportor_id, monto, destino, concepto, campania_id, ticket_id)
            values ('01920000-0000-7000-8000-0000000114b5', 100, 'BANCO', 'ALQUILER', '01920000-0000-7000-8000-0000000114fe',
                    '01920000-0000-7000-8000-00000001145a') $$),
          '23503: insert or update on table "deposito" violates foreign key constraint "deposito_campania_id_fkey"',
          'un depósito de ALQUILER con una campaña que no existe se rechaza');
select is(pg_temp.error_de($$ insert into public.deposito (colportor_id, monto, destino, concepto, campania_id, ticket_id)
            values ('01920000-0000-7000-8000-0000000114b5', 100, 'BANCO', 'ALQUILER', '01920000-0000-7000-8000-0000000114e1',
                    '01920000-0000-7000-8000-00000001145a') $$),
          'ok', 'un depósito de ALQUILER con su campaña entra');
select is(pg_temp.error_de($$ insert into public.deposito (colportor_id, monto, destino, concepto, ticket_id)
            values ('01920000-0000-7000-8000-0000000114b5', 100, 'BANCO', 'CASA_EDITORA',
                    '01920000-0000-7000-8000-00000001145b') $$),
          'ok', 'uno de casa editora no necesita campaña');
rollback to s_deposito;

-- ---------------------------------------------------------------------------
-- 2. Las funciones: forma y privilegios
-- ---------------------------------------------------------------------------
select pg_temp.actuar_como(pg_temp.u('a1'));
select is((select array(select k from jsonb_object_keys(
                  (select to_jsonb(r) from public.cuentas_de_campania(pg_temp.u('e1')) r limit 1)) k
                 order by k collate "C")),
          (select array(select k from unnest(array['alquiler_trasladado','alquiler_debe','alquiler_monto','alquiler_pagado','alquiler_por_validar',
                'alquiler_ultimo_pago_fecha','apellido','ciudad_id','ciudad_nombre','colportor_id',
                'de_baja','deuda_total','dinero_depositado','dinero_en_mano','dinero_por_cobrar',
                'departamento','nombre','ultimo_deposito_fecha','ultimo_deposito_monto']) k
                 order by k collate "C")),
          'cuentas_de_campania: la forma de la respuesta, sin emails ni clientes');
select is((select array(select k from jsonb_object_keys(
                  (select to_jsonb(r) from public.definir_alquiler_de_campania(pg_temp.u('e1'), 150000) r limit 1)) k
                 order by k collate "C")),
          array['alquiler_monto','cambio'],
          'definir_alquiler_de_campania: la forma de la respuesta');
select pg_temp.actuar_como_servidor();

select is((select p.prosecdef from pg_proc p where p.oid = 'public.cuentas_de_campania(uuid)'::regprocedure),
          true, 'cuentas_de_campania es SECURITY DEFINER (el coordinador no lee las cuentas ni los depósitos ajenos)');
select is((select p.prosecdef from pg_proc p where p.oid = 'public.definir_alquiler_de_campania(uuid, bigint)'::regprocedure),
          true, 'definir_alquiler_de_campania es SECURITY DEFINER (el coordinador no escribe campania)');
select is((select p.provolatile from pg_proc p where p.oid = 'public.cuentas_de_campania(uuid)'::regprocedure),
          'v', 'cuentas_de_campania es VOLATILE (llama a lanzar_motivo_mapa())');
select is((select p.proconfig from pg_proc p where p.oid = 'public.cuentas_de_campania(uuid)'::regprocedure),
          array['search_path=""'], 'cuentas_de_campania fija search_path vacío');
select is((select p.proconfig from pg_proc p where p.oid = 'public.definir_alquiler_de_campania(uuid, bigint)'::regprocedure),
          array['search_path=""'], 'definir_alquiler_de_campania fija search_path vacío');
select ok(has_function_privilege('authenticated', 'public.cuentas_de_campania(uuid)', 'execute')
          and has_function_privilege('authenticated', 'public.definir_alquiler_de_campania(uuid, bigint)', 'execute'),
          'authenticated las ejecuta');
select ok(not has_function_privilege('anon', 'public.cuentas_de_campania(uuid)', 'execute')
          and not has_function_privilege('anon', 'public.definir_alquiler_de_campania(uuid, bigint)', 'execute'),
          'anon NO las ejecuta');
select ok(not has_function_privilege('service_role', 'public.cuentas_de_campania(uuid)', 'execute')
          and not has_function_privilege('service_role', 'public.definir_alquiler_de_campania(uuid, bigint)', 'execute'),
          'service_role NO las ejecuta (sin sesión no hay permiso que comprobar)');
select is((select count(*)::int
             from pg_proc p, aclexplode(p.proacl) a
            where a.grantee = 0 and a.privilege_type = 'EXECUTE'
              and p.oid in ('public.cuentas_de_campania(uuid)'::regprocedure,
                            'public.definir_alquiler_de_campania(uuid, bigint)'::regprocedure,
                            'public.tg_campania_alquiler_auditar()'::regprocedure)),
          0, 'no tienen EXECUTE para PUBLIC');
select is((select count(*)::int from pg_proc p
            where p.pronamespace = 'public'::regnamespace
              and p.proname in ('cuentas_de_campania', 'definir_alquiler_de_campania')),
          2, 'hay una sola firma de cada una');
select ok(not has_function_privilege('authenticated', 'public.tg_campania_alquiler_auditar()', 'execute'),
          'la función del trigger no se llama desde afuera');
select has_trigger('public', 'campania', 'campania_alquiler_auditar', 'campania tiene el trigger que audita el alquiler');

-- ---------------------------------------------------------------------------
-- 3. Acceso: el permiso es lo primero (las dos funciones)
-- ---------------------------------------------------------------------------
select pg_temp.actuar_como_servidor();
select throws_ok($$ select * from public.cuentas_de_campania('01920000-0000-7000-8000-0000000114e1') $$,
  '42501', null, 'cuentas: sin JWT (el servidor) falla');
select throws_ok($$ select * from public.definir_alquiler_de_campania('01920000-0000-7000-8000-0000000114e1', 1) $$,
  '42501', null, 'definir: sin JWT (el servidor) falla');

select pg_temp.actuar_sin_jwt();
select throws_ok($$ select * from public.cuentas_de_campania('01920000-0000-7000-8000-0000000114e1') $$,
  '42501', null, 'cuentas: authenticated sin sesión falla');
select throws_ok($$ select * from public.definir_alquiler_de_campania('01920000-0000-7000-8000-0000000114e1', 1) $$,
  '42501', null, 'definir: authenticated sin sesión falla');

select pg_temp.actuar_como(pg_temp.u('b1'));
select throws_ok($$ select * from public.cuentas_de_campania('01920000-0000-7000-8000-0000000114e1') $$,
  '42501', 'Solo el coordinador de la campaña o un administrador puede ver sus cuentas. Entrá con la cuenta del coordinador de esta campaña.',
  'cuentas: un colportor no las ve (ni las suyas por acá)');
select throws_ok($$ select * from public.definir_alquiler_de_campania('01920000-0000-7000-8000-0000000114e1', 1) $$,
  '42501', 'Solo el coordinador de la campaña o un administrador puede cambiar su alquiler. Entrá con la cuenta del coordinador de esta campaña.',
  'definir: un colportor no cambia el alquiler');

select pg_temp.actuar_como(pg_temp.u('a3'));
select throws_ok($$ select * from public.cuentas_de_campania('01920000-0000-7000-8000-0000000114e1') $$,
  '42501', null, 'cuentas: sin ningún rol falla');
select throws_ok($$ select * from public.definir_alquiler_de_campania('01920000-0000-7000-8000-0000000114e1', 1) $$,
  '42501', null, 'definir: sin ningún rol falla');

select pg_temp.actuar_como(pg_temp.u('a4'));
select throws_ok($$ select * from public.cuentas_de_campania('01920000-0000-7000-8000-0000000114e1') $$,
  '42501', null, 'cuentas: con el rol de coordinador vencido falla');
select throws_ok($$ select * from public.definir_alquiler_de_campania('01920000-0000-7000-8000-0000000114e1', 1) $$,
  '42501', null, 'definir: con el rol de coordinador vencido falla');

select pg_temp.actuar_como(pg_temp.u('a2'));
select throws_ok($$ select * from public.cuentas_de_campania('01920000-0000-7000-8000-0000000114e1') $$,
  '42501', null, 'cuentas: el coordinador de otra campaña falla');
select throws_ok($$ select * from public.definir_alquiler_de_campania('01920000-0000-7000-8000-0000000114e1', 1) $$,
  '42501', null, 'definir: el coordinador de otra campaña falla');

select pg_temp.actuar_como(pg_temp.u('a1'));
select throws_ok($$ select * from public.cuentas_de_campania('01920000-0000-7000-8000-0000000114e2') $$,
  '42501', null, 'cuentas: el coordinador no ve las de la campaña de otro');
select throws_ok($$ select * from public.cuentas_de_campania('01920000-0000-7000-8000-0000000114e4') $$,
  'CZ001', null, 'cuentas: una campaña dada de baja no existe');
select throws_ok($$ select * from public.cuentas_de_campania('01920000-0000-7000-8000-0000000114fe') $$,
  'CZ001', null, 'cuentas: una campaña inexistente no existe');
select throws_ok($$ select * from public.cuentas_de_campania(null) $$,
  'CZ001', null, 'cuentas: sin campaña, CZ001');
select throws_ok($$ select * from public.definir_alquiler_de_campania('01920000-0000-7000-8000-0000000114e4', 1) $$,
  'CZ001', null, 'definir: una campaña dada de baja no existe');
select throws_ok($$ select * from public.definir_alquiler_de_campania(null, 1) $$,
  'CZ001', null, 'definir: sin campaña, CZ001');

-- ---------------------------------------------------------------------------
-- 4. cuentas_de_campania: quiénes salen, las cifras y el alquiler de ESTA campaña
-- ---------------------------------------------------------------------------
select pg_temp.actuar_como(pg_temp.u('a1'));
select is((select count(*)::int from public.cuentas_de_campania(pg_temp.u('e1'))), 5,
          'cuentas: los 5 colportores de la campaña, el de baja incluido (su deuda no desaparece)');
select is((select array_agg(r.colportor_id order by r.colportor_id) from public.cuentas_de_campania(pg_temp.u('e1')) r),
          array[pg_temp.u('b1'), pg_temp.u('b2'), pg_temp.u('b3'), pg_temp.u('b4'), pg_temp.u('b5')],
          'cuentas: solo los de esta campaña (ni b6 de Sin alquiler ni b7)');
select is((select r.de_baja from public.cuentas_de_campania(pg_temp.u('e1')) r where r.colportor_id = pg_temp.u('b3')),
          true, 'cuentas: el de baja viene marcado');
select is((select count(*)::int from public.cuentas_de_campania(pg_temp.u('e1')) r where r.de_baja), 1,
          'cuentas: y es el único');
select is((select r.nombre || ' ' || r.apellido from public.cuentas_de_campania(pg_temp.u('e1')) r where r.colportor_id = pg_temp.u('b1')),
          'Ana Alfa', 'cuentas: el nombre del colportor');
select is((select r.ciudad_nombre || '/' || r.departamento from public.cuentas_de_campania(pg_temp.u('e1')) r where r.colportor_id = pg_temp.u('b1')),
          'Ciudad uno q111/Departamento de prueba uno', 'cuentas: la ciudad de su zona actual');
select is((select r.ciudad_id from public.cuentas_de_campania(pg_temp.u('e1')) r where r.colportor_id = pg_temp.u('b4')),
          null::uuid, 'cuentas: sin zona, sin ciudad');
select is((select r.ciudad_id from public.cuentas_de_campania(pg_temp.u('e1')) r where r.colportor_id = pg_temp.u('b3')),
          null::uuid, 'cuentas: con la inscripción de baja, sin ciudad');
select is((select array_agg(r.colportor_id order by r.colportor_id) from public.cuentas_de_campania(pg_temp.u('e1')) r
            where r.ciudad_id is null),
          array[pg_temp.u('b3'), pg_temp.u('b4')], 'cuentas: los sin ciudad salen igual, una sola vez cada uno');

-- Las cuatro cifras, del snapshot.
select is((select format('%s|%s|%s|%s', r.deuda_total, r.dinero_depositado, r.dinero_en_mano, r.dinero_por_cobrar)
             from public.cuentas_de_campania(pg_temp.u('e1')) r where r.colportor_id = pg_temp.u('b1')),
          '1200000|500000|0|80000', 'cuentas: las cuatro cifras de su cuenta (en mano se calcula: sin cobros en efectivo, 0)');
select is((select format('%s|%s|%s|%s', r.deuda_total, r.dinero_depositado, r.dinero_en_mano, r.dinero_por_cobrar)
             from public.cuentas_de_campania(pg_temp.u('e1')) r where r.colportor_id = pg_temp.u('b2')),
          '0|0|0|0', 'cuentas: una cuenta dada de baja no cuenta');
select is((select format('%s|%s|%s|%s', r.deuda_total, r.dinero_depositado, r.dinero_en_mano, r.dinero_por_cobrar)
             from public.cuentas_de_campania(pg_temp.u('e1')) r where r.colportor_id = pg_temp.u('b5')),
          '0|0|0|0', 'cuentas: sin cuenta todavía, en cero');
select is((select r.deuda_total from public.cuentas_de_campania(pg_temp.u('e1')) r where r.colportor_id = pg_temp.u('b1')),
          1200000::bigint, 'cuentas: el alquiler es una deuda aparte: no se suma a la deuda con la casa editora');

-- Las cuatro cifras son del colportor y no de la campaña: salen solo en su campaña vigente hoy.
select is((select format('%s|%s|%s|%s', coalesce(r.deuda_total::text, 'null'), coalesce(r.dinero_depositado::text, 'null'),
                         coalesce(r.dinero_en_mano::text, 'null'), coalesce(r.dinero_por_cobrar::text, 'null'))
             from public.cuentas_de_campania(pg_temp.u('e1')) r where r.colportor_id = pg_temp.u('b3')),
          'null|null|null|null', 'cuentas: el de baja (ya sin campaña vigente) trae las cuatro cifras en null');
select pg_temp.actuar_como(pg_temp.u('ad'));
select is((select format('%s|%s|%s|%s|%s', coalesce(r.deuda_total::text, 'null'), coalesce(r.dinero_depositado::text, 'null'),
                         coalesce(r.dinero_en_mano::text, 'null'), coalesce(r.dinero_por_cobrar::text, 'null'), r.alquiler_debe)
             from public.cuentas_de_campania(pg_temp.u('e2')) r where r.colportor_id = pg_temp.u('b1')),
          'null|null|null|null|30000',
          'cuentas: b1 ya está en Cuentas (más nueva): visto desde Otra, sus cuatro cifras son null y su alquiler de Otra sigue');
select is((select format('%s|%s|%s|%s', coalesce(r.deuda_total::text, 'null'), coalesce(r.dinero_depositado::text, 'null'),
                         coalesce(r.dinero_en_mano::text, 'null'), coalesce(r.dinero_por_cobrar::text, 'null'))
             from public.cuentas_de_campania(pg_temp.u('e5')) r where r.colportor_id = pg_temp.u('b2')),
          'null|null|null|null', 'cuentas: una campaña terminada hace más de 15 días tampoco muestra las cuatro cifras');
select is((select count(*)::int from public.cuentas_de_campania(pg_temp.u('e2')) r where r.de_baja is not null), 1,
          'cuentas: pero la fila sigue estando');
select pg_temp.actuar_como(pg_temp.u('a1'));

-- Último depósito de casa editora.
select is((select to_char(r.ultimo_deposito_fecha at time zone 'UTC', 'YYYY-MM-DD') || '|' || r.ultimo_deposito_monto
             from public.cuentas_de_campania(pg_temp.u('e1')) r where r.colportor_id = pg_temp.u('b1')),
          '2026-09-10|10000',
          'cuentas: el último depósito es el último de CASA EDITORA (no el de alquiler más nuevo ni el dado de baja)');
select pg_temp.actuar_como(pg_temp.u('ad'));
select is((select to_char(r.ultimo_deposito_fecha at time zone 'UTC', 'YYYY-MM-DD') || '|' || r.ultimo_deposito_monto
             from public.cuentas_de_campania(pg_temp.u('e2')) r where r.colportor_id = pg_temp.u('b1')),
          '2026-09-15|3000',
          'cuentas: en la otra campaña, su último depósito es el que lleva el campania_id de ella, no el de Cuentas (10/09)');
select is((select to_char(r.ultimo_deposito_fecha at time zone 'UTC', 'YYYY-MM-DD') || '|' || r.ultimo_deposito_monto
             from public.cuentas_de_campania(pg_temp.u('e1')) r where r.colportor_id = pg_temp.u('b1')),
          '2026-09-10|10000',
          'cuentas: y en Cuentas no aparece el del 15/09 de la otra campaña, aunque sea más nuevo');
select pg_temp.actuar_como(pg_temp.u('a1'));
select is((select r.ultimo_deposito_fecha from public.cuentas_de_campania(pg_temp.u('e1')) r where r.colportor_id = pg_temp.u('b4')),
          null::timestamptz, 'cuentas: el que solo pagó alquiler no tiene depósito de casa editora');

-- El alquiler de ESTA campaña: monto|pagado|por_validar|debe|último pago.
select is(pg_temp.alq('e1', 'b1'), '150000|75000|50000|75000|2026-09-08',
          'alquiler: pagado = solo tickets VALIDADOS de esta campaña (50000 + 25000); por validar = el ticket pendiente (30000) y el retiro sin ticket (20000); no cuentan el rechazado, el dado de baja ni el de otra campaña');
select is(pg_temp.alq('e1', 'b2'), '150000|0|0|150000|null', 'alquiler: sin pagos, debe todo');
select is(pg_temp.alq('e1', 'b3'), '150000|0|0|0|null', 'alquiler: el de baja no debe nada («Alq. de baja», 27/10, 0132)');
select is(pg_temp.alq('e1', 'b4'), '150000|200000|0|0|2026-09-03', 'alquiler: pagó de más: no debe, y se ve en pagado');
select is(pg_temp.alq('e1', 'b5'), '150000|0|0|150000|null', 'alquiler: otro sin pagos');
select is((select count(*)::int from public.cuentas_de_campania(pg_temp.u('e1')) r
            where r.alquiler_monto is distinct from 150000), 0,
          'alquiler: el monto es el de la campaña, el mismo para todos');

select pg_temp.actuar_como(pg_temp.u('ad'));
select is(pg_temp.alq('e2', 'b1'), '100000|70000|0|30000|2026-09-09',
          'alquiler: el saldo es uno por campaña: en Otra b1 pagó 70000 de 100000 (lo de Cuentas no se mezcla)');
select is((select count(*)::int from public.cuentas_de_campania(pg_temp.u('e2'))), 1,
          'el ADMIN lee las cuentas de cualquier campaña');
select pg_temp.actuar_como(pg_temp.u('a1'));
select is(pg_temp.alq('e3', 'b6'), 'null|15000|0|null|2026-09-04',
          'alquiler: una campaña que no cobra trae monto y debe en null (lo pagado se sigue viendo)');
select is(pg_temp.alq('e5', 'b2'), '90000|0|0|90000|null', 'alquiler: una campaña terminada se lee');
select is((select count(*)::int from public.cuentas_de_campania(pg_temp.u('e6'))), 0,
          'alquiler: una campaña sin colportores devuelve la lista vacía');

-- ---------------------------------------------------------------------------
-- 5. definir_alquiler_de_campania: el monto, el recálculo y el registro
-- ---------------------------------------------------------------------------
select pg_temp.actuar_como_servidor();
create temp table antes (sync_version bigint);
insert into antes select c.sync_version from public.campania c where c.id = pg_temp.u('e1');
grant select on antes to authenticated;
select pg_temp.actuar_como(pg_temp.u('a1'));

select is((select format('%s|%s', r.alquiler_monto, r.cambio) from public.definir_alquiler_de_campania(pg_temp.u('e1'), 180000) r),
          '180000|t', 'definir: el coordinador cambia el monto (150000 a 180000)');
select is((select c.alquiler_monto from public.campania c where c.id = pg_temp.u('e1')), 180000::bigint,
          'definir: la campaña quedó con el monto nuevo');
select ok((select c.sync_version > (select a.sync_version from antes a) from public.campania c where c.id = pg_temp.u('e1')),
          'definir: la campaña sube su versión (los teléfonos reciben el monto nuevo por el pull)');
select is(pg_temp.eventos('e1'), 1, 'definir: quedó un registro en audit_log');
select is(pg_temp.eventos('e1', '{"monto_anterior":150000,"monto_nuevo":180000}'), 1,
          'definir: el registro lleva el monto anterior y el nuevo');
select is(pg_temp.actores('e1'), pg_temp.u('a1')::text, 'definir: el actor del registro es el coordinador');
select is(pg_temp.alq('e1', 'b1'), '180000|75000|50000|105000|2026-09-08',
          'recálculo: a b1 le queda 180000 menos lo ya pagado (75000); lo depositado no se pierde');
select is(pg_temp.alq('e1', 'b2'), '180000|0|0|180000|null', 'recálculo: vale para todos los inscriptos');
select is(pg_temp.alq('e1', 'b4'), '180000|200000|0|0|2026-09-03', 'recálculo: el que pagó de más sigue sin deber');
select pg_temp.actuar_como(pg_temp.u('ad'));
select is(pg_temp.alq('e2', 'b1'), '100000|70000|0|30000|2026-09-09',
          'recálculo: solo se recalcula la campaña que cambió; la otra queda igual');
select pg_temp.actuar_como(pg_temp.u('a1'));

select pg_temp.actuar_como_servidor();
create temp table antes2 as select c.sync_version from public.campania c where c.id = pg_temp.u('e1');
grant select on antes2 to authenticated;
select pg_temp.actuar_como(pg_temp.u('a1'));
select is((select format('%s|%s', r.alquiler_monto, r.cambio) from public.definir_alquiler_de_campania(pg_temp.u('e1'), 180000) r),
          '180000|f', 'definir: el mismo valor no cambia nada (idempotente)');
select is(pg_temp.eventos('e1'), 1, 'definir: y no deja un segundo registro');
select is((select c.sync_version from public.campania c where c.id = pg_temp.u('e1')),
          (select a.sync_version from antes2 a), 'definir: ni sube la versión de la campaña (no se avisa a los teléfonos de nada)');

select is((select format('%s|%s', coalesce(r.alquiler_monto::text, 'null'), r.cambio)
             from public.definir_alquiler_de_campania(pg_temp.u('e1'), null) r),
          'null|t', 'definir: null = la campaña deja de cobrar alquiler');
select is(pg_temp.eventos('e1', '{"monto_anterior":180000,"monto_nuevo":null}'), 1,
          'definir: el registro del null lleva el monto nuevo en null');
select is(pg_temp.alq('e1', 'b1'), 'null|75000|50000|null|2026-09-08',
          'sin alquiler: monto y debe en null; lo pagado se sigue viendo');
select is((select format('%s|%s', coalesce(r.alquiler_monto::text, 'null'), r.cambio)
             from public.definir_alquiler_de_campania(pg_temp.u('e1'), null) r),
          'null|f', 'definir: null sobre null tampoco cambia nada');

select is((select format('%s|%s', r.alquiler_monto, r.cambio) from public.definir_alquiler_de_campania(pg_temp.u('e1'), 0) r),
          '0|t', 'definir: cero es un monto válido');
select is(pg_temp.alq('e1', 'b2'), '0|0|0|0|null', 'alquiler en cero: no debe nada');
select is(pg_temp.eventos('e1'), 3, 'definir: tres cambios, tres registros');

select throws_ok($$ select * from public.definir_alquiler_de_campania('01920000-0000-7000-8000-0000000114e1', -1) $$,
  '22023', 'El alquiler no puede ser negativo. Escribí un monto de cero o más, o dejalo vacío si la campaña no cobra alquiler.',
  'definir: un monto negativo se rechaza con un aviso que guía');
select is((select c.alquiler_monto from public.campania c where c.id = pg_temp.u('e1')), 0::bigint,
          'definir: el rechazo no cambió el monto');
select is(pg_temp.eventos('e1'), 3, 'definir: ni dejó registro');

select is((select format('%s|%s', r.alquiler_monto, r.cambio) from public.definir_alquiler_de_campania(pg_temp.u('e1'), 150000) r),
          '150000|t', 'definir: vuelve a 150000');

-- El que se inscribe después paga el mismo monto, y si cambia, cambia para todos.
select pg_temp.actuar_como_servidor();
insert into public.campania_colportor (campania_id, usuario_id, zona_id, created_at)
values (pg_temp.u('e1'), pg_temp.u('b7'), null, now());
select pg_temp.actuar_como(pg_temp.u('a1'));
select is(pg_temp.alq('e1', 'b7'), '150000|0|0|150000|null', 'el que se inscribe después debe el mismo monto');
select is((select format('%s|%s', r.alquiler_monto, r.cambio) from public.definir_alquiler_de_campania(pg_temp.u('e1'), 160000) r),
          '160000|t', 'definir: otro cambio');
select is(pg_temp.alq('e1', 'b7'), '160000|0|0|160000|null', 'y el cambio le llega también');
select is(pg_temp.alq('e1', 'b1'), '160000|75000|50000|85000|2026-09-08', 'y a b1 le queda lo que falta (160000 menos 75000)');
select is(pg_temp.eventos('e1'), 5, 'cinco cambios en e1, cinco registros');

-- La campaña terminada no se toca.
select throws_ok($$ select * from public.definir_alquiler_de_campania('01920000-0000-7000-8000-0000000114e5', 1) $$,
  'CZ011', 'La campaña ya terminó y su alquiler queda como estaba. Elegí una campaña en curso.',
  'definir: una campaña terminada no cambia su alquiler');
select is((select c.alquiler_monto from public.campania c where c.id = pg_temp.u('e5')), 90000::bigint,
          'definir: la terminada sigue con su monto');
select is(pg_temp.eventos('e5'), 0, 'definir: y sin registro');

-- El ADMIN: cualquier campaña, y su UPDATE directo también deja registro.
select pg_temp.actuar_como(pg_temp.u('ad'));
select is((select format('%s|%s', r.alquiler_monto, r.cambio) from public.definir_alquiler_de_campania(pg_temp.u('e2'), 120000) r),
          '120000|t', 'definir: el ADMIN cambia el alquiler de cualquier campaña');
select is(pg_temp.eventos('e2', '{"monto_anterior":100000,"monto_nuevo":120000}'), 1, 'definir: y queda su registro');
select is(pg_temp.actores('e2'), pg_temp.u('ad')::text, 'definir: con el ADMIN como actor');
update public.campania set alquiler_monto = 110000 where id = pg_temp.u('e2');
select is(pg_temp.eventos('e2', '{"monto_anterior":120000,"monto_nuevo":110000}'), 1,
          'el UPDATE directo del ADMIN también deja registro (lo escribe el trigger)');
update public.campania set nombre = 'Otra campaña' where id = pg_temp.u('e2');
select is(pg_temp.eventos('e2'), 2, 'cambiar otra columna no deja registro de alquiler');
update public.campania set alquiler_monto = 110000 where id = pg_temp.u('e2');
select is(pg_temp.eventos('e2'), 2, 'ni un UPDATE que deja el mismo monto');

select pg_temp.actuar_como(pg_temp.u('a2'));
select is(pg_temp.filas($$ update public.campania set alquiler_monto = 1 where id = '01920000-0000-7000-8000-0000000114e2' $$),
          0, 'un coordinador no cambia el monto por UPDATE directo (solo por la función)');
select pg_temp.actuar_como(pg_temp.u('a1'));
select throws_ok($$ select * from public.definir_alquiler_de_campania('01920000-0000-7000-8000-0000000114e2', 1) $$,
  '42501', null, 'definir: un coordinador no cambia el alquiler de la campaña de otro');
select pg_temp.actuar_como_servidor();
select is(pg_temp.eventos('e2'), 2, 'y esos intentos no dejaron registro');

-- ---------------------------------------------------------------------------
-- 6. El alquiler no bloquea nada
-- ---------------------------------------------------------------------------
-- b2 debe 160000 de alquiler y no pagó nada: puede vender igual.
select pg_temp.actuar_como(pg_temp.u('a1'));
select is(pg_temp.alq('e1', 'b2'), '160000|0|0|160000|null', 'b2 debe todo el alquiler');
select pg_temp.actuar_como(pg_temp.u('b2'));
select is(pg_temp.error_de($$ insert into public.venta (id, espacio_persona_id, numero_talonario, monto_total, fecha, colportor_id)
            values ('01920000-0000-7000-8000-0000000114c1', '01920000-0000-7000-8000-0000000114ef', 'T-114', 1000, now(),
                    '01920000-0000-7000-8000-0000000114b2') $$),
          'ok', 'con el alquiler sin pagar, el colportor registra una venta con normalidad');
select pg_temp.actuar_como_servidor();
select is((select count(*)::int from public.venta v where v.id = pg_temp.u('c1')), 1, 'y la venta quedó');

select * from finish();
rollback;
