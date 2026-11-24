-- pgTAP · el límite de deuda de la campaña en las lecturas del panel (migración 0204, backend-supabase#308,
-- seguimiento de front-coordinadores-web#215, HU-STK-003, vista 35)
-- La forma de las tres lecturas (columnas nuevas al final, privilegios de antes); `limite_deuda` en
-- campanias_del_coordinador() (con y sin límite, límite cero, la campaña de otro coordinador no sale);
-- `limite_deuda` y `supera_limite_por` en pedidos_de_campania() y pedido_contexto(): por encima, justo en el
-- límite (no lo supera), la deuda sola ya pasa, sin cuenta, solo en un pedido por autorizar (autorizado y
-- rechazado en null), campaña sin límite, límite cero, pedido sin campaña (solo lo ve el ADMIN); y que el permiso
-- no cambió (otra campaña y sin sesión, 42501).
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

-- El uuid de un personaje del test (sufijo de dos caracteres HEX).
create or replace function pg_temp.u(p_sufijo text) returns uuid language sql immutable as $$
  select ('01920000-0000-7000-8000-0000000204' || p_sufijo)::uuid
$$;

-- Corre una consulta como ese usuario (null = sin sesión) y devuelve sus filas como jsonb; si tira,
-- {"error": <SQLSTATE>}. Al volver, el test sigue siendo el servidor.
create or replace function pg_temp.como(p_uid uuid, p_sql text) returns jsonb language plpgsql as $$
declare
  v_r jsonb;
begin
  if p_uid is null then
    perform pg_temp.actuar_sin_jwt();
  else
    perform pg_temp.actuar_como(p_uid);
  end if;
  begin
    execute format('select coalesce(jsonb_agg(to_jsonb(t)), ''[]''::jsonb) from (%s) t', p_sql) into v_r;
  exception when others then
    v_r := jsonb_build_object('error', sqlstate, 'mensaje', sqlerrm);
  end;
  perform pg_temp.actuar_como_servidor();
  return v_r;
end $$;

-- Lo que dicen las tres lecturas de un pedido o campaña: «límite / supera» (n = null).
create or replace function pg_temp.lista(p_uid uuid, p_camp text) returns jsonb language sql as $$
  select pg_temp.como(p_uid, format('select * from public.pedidos_de_campania(%L)', pg_temp.u(p_camp)))
$$;
create or replace function pg_temp.contexto(p_uid uuid, p_ped text) returns jsonb language sql as $$
  select pg_temp.como(p_uid, format('select * from public.pedido_contexto(%L)', pg_temp.u(p_ped)))
$$;

-- «límite/supera» del pedido en la bandeja de una campaña (n = null; «-» si el pedido no sale).
create or replace function pg_temp.en_lista(p_uid uuid, p_camp text, p_ped text) returns text language sql as $$
  select coalesce((select coalesce(e ->> 'limite_deuda', 'n') || '/' || coalesce(e ->> 'supera_limite_por', 'n')
                     from jsonb_array_elements(pg_temp.lista(p_uid, p_camp)) e
                    where e ->> 'pedido_id' = pg_temp.u(p_ped)::text), '-')
$$;
-- Lo mismo, del detalle (pedido_contexto): «límite/supera», o el SQLSTATE si tira.
create or replace function pg_temp.en_contexto(p_uid uuid, p_ped text) returns text language sql as $$
  select coalesce(c ->> 'error', coalesce(c ->> 'limite_deuda', 'n') || '/' || coalesce(c ->> 'supera_limite_por', 'n'))
    from (select case when jsonb_typeof(r) = 'array' then r -> 0 else r end c
            from (select pg_temp.contexto(p_uid, p_ped) r) q) z
$$;

-- --- fixtures ------------------------------------------------------------------
-- Staff: a1 coordinador de Con límite, Sin límite, Cero y Terminada; a2 coordinador de Otra; ad admin.
-- Colportores: b1 (deuda $U 200: 20.000 centavos)  b2 (deuda 28.500)  b3 (deuda 25.000, en Sin límite)
--        b4 (sin cuenta, en Con límite)  b5 (sin cuenta, en Cero)  b6 (sin inscripción en ninguna).
-- Campañas: e1 Con límite (30.000 centavos, a1)  e2 Sin límite (null, a1)  e3 Otra (100, a2)  e4 Cero (0, a1)
--        e5 Terminada (a1, 50.000, terminó hace 30 días).
insert into auth.users (id, instance_id, aud, role, email, encrypted_password, confirmed_at, created_at, updated_at)
select pg_temp.u(s), '00000000-0000-0000-0000-000000000000',
       'authenticated', 'authenticated', 'limite-lectura-' || s || '@example.com', 'x', now(), now(), now()
  from unnest(array['a1','a2','ad','b1','b2','b3','b4','b5','b6']) s;

insert into public.usuario_rol (usuario_id, rol_id)
select pg_temp.u(x.s), r.id
  from (values ('a1','COORDINADOR'), ('a2','COORDINADOR'), ('ad','ADMIN'),
               ('b1','COLPORTOR'), ('b2','COLPORTOR'), ('b3','COLPORTOR'), ('b4','COLPORTOR'),
               ('b5','COLPORTOR'), ('b6','COLPORTOR')) x(s, codigo)
  join public.rol r on r.codigo = x.codigo;

insert into public.campania (id, nombre, tipo, fecha_inicio, fecha_fin, coordinador_id, limite_deuda) values
  (pg_temp.u('e1'), 'Con límite', 'VERANO', '2026-08-03', null, pg_temp.u('a1'), 30000),
  (pg_temp.u('e2'), 'Sin límite', 'VERANO', '2026-08-03', null, pg_temp.u('a1'), null),
  (pg_temp.u('e3'), 'Otra',       'VERANO', '2026-08-03', null, pg_temp.u('a2'), 100),
  (pg_temp.u('e4'), 'Cero',       'VERANO', '2026-08-03', null, pg_temp.u('a1'), 0),
  (pg_temp.u('e5'), 'Terminada',  'VERANO', public.hoy_montevideo() - 90, public.hoy_montevideo() - 30,
   pg_temp.u('a1'), 50000);

insert into public.campania_colportor (campania_id, usuario_id, created_at) values
  (pg_temp.u('e1'), pg_temp.u('b1'), '2026-08-01 10:00-03'),
  (pg_temp.u('e1'), pg_temp.u('b2'), '2026-08-01 10:00-03'),
  (pg_temp.u('e2'), pg_temp.u('b3'), '2026-08-01 10:00-03'),
  (pg_temp.u('e1'), pg_temp.u('b4'), '2026-08-01 10:00-03'),
  (pg_temp.u('e4'), pg_temp.u('b5'), '2026-08-01 10:00-03');

insert into public.cuenta_colportor (usuario_id, deuda_total) values
  (pg_temp.u('b1'), 20000),
  (pg_temp.u('b2'), 28500),
  (pg_temp.u('b3'), 25000);

-- Pedidos (id c1–cc, colportor, estado, total). Todos de hoy, dentro de la inscripción.
--   c1 b1 por autorizar 10.000: 20.000 + 10.000 = 30.000, justo en el límite: NO lo supera.
--   c2 b1 por autorizar 10.001: supera por 1.
--   c3 b2 por autorizar 1.500: 28.500 + 1.500 = 30.000, justo.   c4 b2 por autorizar 5.000: supera por 3.500.
--   c5 b1 autorizado 50.000 (ya está en la deuda; no se mide).   c6 b1 rechazado 50.000 (no cuenta).
--   c7 b4 por autorizar 40.000, sin cuenta: supera por 10.000.   c8 b3 en Sin límite por autorizar 90.000.
--   c9 b5 en Cero por autorizar 100: supera por 100.             ca b6 sin inscripción, por autorizar 99.999.
--   cb b1 despachado 1.500 (tampoco se mide).                    cc b1 por autorizar dado de baja: no sale.
insert into public.pedido_casa_editora (id, colportor_id, estado, monto_total, origen, fecha_pedido,
                                        monto_autorizado, decidido_por, decidido_en, motivo_rechazo, deleted_at)
select pg_temp.u(x.id), pg_temp.u(x.col), x.est, x.tot, 'COLPORTOR', now(),
       x.mauth, case when x.est in ('AUTORIZADO', 'RECHAZADO', 'DESPACHADO') then pg_temp.u('a1') end,
       case when x.est in ('AUTORIZADO', 'RECHAZADO', 'DESPACHADO') then now() - interval '1 day' end,
       x.mot, x.baja
  from (values
    ('c1', 'b1', 'PENDIENTE_AUTORIZACION', 10000::bigint, null::bigint, null::text, null::timestamptz),
    ('c2', 'b1', 'PENDIENTE_AUTORIZACION', 10001, null, null, null),
    ('c3', 'b2', 'PENDIENTE_AUTORIZACION', 1500,  null, null, null),
    ('c4', 'b2', 'PENDIENTE_AUTORIZACION', 5000,  null, null, null),
    ('c5', 'b1', 'AUTORIZADO',             50000, 50000, null, null),
    ('c6', 'b1', 'RECHAZADO',              50000, null, 'Sin capacidad de pago', null),
    ('c7', 'b4', 'PENDIENTE_AUTORIZACION', 40000, null, null, null),
    ('c8', 'b3', 'PENDIENTE_AUTORIZACION', 90000, null, null, null),
    ('c9', 'b5', 'PENDIENTE_AUTORIZACION', 100,   null, null, null),
    ('ca', 'b6', 'PENDIENTE_AUTORIZACION', 99999, null, null, null),
    ('cb', 'b1', 'DESPACHADO',             1500,  1500, null, null),
    ('cc', 'b1', 'PENDIENTE_AUTORIZACION', 70000, null, null, now())
  ) x(id, col, est, tot, mauth, mot, baja);

-- ============================================================================
-- 1. La forma y los privilegios
-- ============================================================================
select is((select pg_get_function_result('public.campanias_del_coordinador()'::regprocedure)),
          'TABLE(id uuid, nombre text, tipo text, fecha_inicio date, fecha_fin date, limite_deuda bigint)',
          'campanias_del_coordinador(): el límite es la última columna');
select is((select proargnames from pg_proc where oid = 'public.pedidos_de_campania(uuid)'::regprocedure)[23:24],
          array['limite_deuda','supera_limite_por'], 'pedidos_de_campania: el límite y lo que supera son las dos últimas columnas');
select is((select proargnames from pg_proc where oid = 'public.pedido_contexto(uuid)'::regprocedure)[15:16],
          array['limite_deuda','supera_limite_por'], 'pedido_contexto: el límite y lo que supera son las dos últimas columnas');
select is((select count(*)::int from pg_proc where proname in ('pedidos_de_campania', 'pedido_contexto', 'campanias_del_coordinador')
              and pronamespace = 'public'::regnamespace), 3,
          'cada lectura existe una sola vez (el drop + create no dejó la firma vieja)');

select is(has_function_privilege(r, f, 'execute')::text, case when r = 'authenticated' then 'true' else 'false' end,
          format('%s %s EXECUTE en %s', r, case when r = 'authenticated' then 'tiene' else 'no tiene' end, f))
  from unnest(array['public.pedidos_de_campania(uuid)', 'public.pedido_contexto(uuid)',
                    'public.campanias_del_coordinador()']) f,
       unnest(array['anon', 'authenticated', 'service_role']) r;
select is((select count(*)::int
             from pg_proc p, aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a
            where a.grantee = 0 and a.privilege_type = 'EXECUTE'
              and p.oid in ('public.pedidos_de_campania(uuid)'::regprocedure, 'public.pedido_contexto(uuid)'::regprocedure,
                            'public.campanias_del_coordinador()'::regprocedure)), 0,
          'PUBLIC no ejecuta ninguna de las tres');
select is((select array_agg(p.prosecdef order by p.proname) from pg_proc p
            where p.oid in ('public.pedidos_de_campania(uuid)'::regprocedure, 'public.pedido_contexto(uuid)'::regprocedure,
                            'public.campanias_del_coordinador()'::regprocedure)),
          array[false, true, true], 'campanias_del_coordinador sigue INVOKER; las dos de pedidos, SECURITY DEFINER');
select is((select count(*)::int from pg_proc p
            where p.oid in ('public.pedidos_de_campania(uuid)'::regprocedure, 'public.pedido_contexto(uuid)'::regprocedure,
                            'public.campanias_del_coordinador()'::regprocedure)
              and p.proconfig = array['search_path=""']), 3, 'las tres fijan search_path vacío');
select is((select provolatile::text from pg_proc where oid = 'public.campanias_del_coordinador()'::regprocedure), 's',
          'campanias_del_coordinador() sigue STABLE');

-- ============================================================================
-- 2. campanias_del_coordinador(): el límite de cada campaña
-- ============================================================================
select is((select jsonb_object_agg(e ->> 'nombre', e -> 'limite_deuda')
             from jsonb_array_elements(pg_temp.como(pg_temp.u('a1'), 'select * from public.campanias_del_coordinador()')) e),
          '{"Con límite": 30000, "Sin límite": null, "Cero": 0}'::jsonb,
          'a1 ve el límite de cada campaña viva suya: 30.000, sin límite (null) y cero; la terminada no sale');
select is((select jsonb_object_agg(e ->> 'nombre', e -> 'limite_deuda')
             from jsonb_array_elements(pg_temp.como(pg_temp.u('a2'), 'select * from public.campanias_del_coordinador()')) e),
          '{"Otra": 100}'::jsonb, 'a2 ve solo la suya, con su límite: no el de las campañas de a1');
select is(pg_temp.como(pg_temp.u('b1'), 'select * from public.campanias_del_coordinador()') ->> 'error', '42501',
          'un colportor sigue sin poder llamarla');
select is(pg_temp.como(null, 'select * from public.campanias_del_coordinador()') ->> 'error', '42501',
          'sin sesión sigue siendo 42501');
select is((select count(*)::int
             from jsonb_array_elements(pg_temp.como(pg_temp.u('a1'), 'select * from public.campanias_del_coordinador()')) e),
          3, 'a1 sigue viendo las mismas tres campañas (la terminada no sale): solo se sumó la columna');

-- ============================================================================
-- 3. pedidos_de_campania(): el límite en cada fila y lo que pasa cada pedido por autorizar
-- ============================================================================
select is(pg_temp.en_lista(pg_temp.u('a1'), 'e1', 'c1'), '30000/n',
          'bandeja: justo en el límite (20.000 + 10.000 = 30.000) NO lo supera');
select is(pg_temp.en_lista(pg_temp.u('a1'), 'e1', 'c2'), '30000/1',
          'bandeja: un centavo por encima del límite supera por 1');
select is(pg_temp.en_lista(pg_temp.u('a1'), 'e1', 'c3'), '30000/n', 'bandeja: otra colportora justo en el límite, no lo supera');
select is(pg_temp.en_lista(pg_temp.u('a1'), 'e1', 'c4'), '30000/3500', 'bandeja: 28.500 + 5.000 supera por 3.500');
select is(pg_temp.en_lista(pg_temp.u('a1'), 'e1', 'c5'), '30000/n',
          'bandeja: un pedido autorizado trae el límite pero no se mide (su monto ya está en la deuda)');
select is(pg_temp.en_lista(pg_temp.u('a1'), 'e1', 'c6'), '30000/n', 'bandeja: un pedido rechazado no se mide');
select is(pg_temp.en_lista(pg_temp.u('a1'), 'e1', 'cb'), '30000/n', 'bandeja: un pedido despachado no se mide');
select is(pg_temp.en_lista(pg_temp.u('a1'), 'e1', 'c7'), '30000/10000',
          'bandeja: sin cuenta, la deuda es 0 y el pedido de 40.000 supera por 10.000');
select is(pg_temp.en_lista(pg_temp.u('a1'), 'e1', 'cc'), '-', 'bandeja: un pedido dado de baja no sale (como antes)');
select is(pg_temp.en_lista(pg_temp.u('a1'), 'e2', 'c8'), 'n/n',
          'bandeja de una campaña sin límite: limite_deuda null y nada supera, aunque pida 90.000');
select is(pg_temp.en_lista(pg_temp.u('a1'), 'e4', 'c9'), '0/100',
          'bandeja de una campaña con límite cero: lo que pide supera por todo (0 es un límite, no «sin límite»)');
select is((select count(distinct e ->> 'limite_deuda')::int from jsonb_array_elements(pg_temp.lista(pg_temp.u('a1'), 'e1')) e), 1,
          'bandeja: el límite es el mismo en todas las filas de la campaña');
select is((select count(*)::int from jsonb_array_elements(pg_temp.lista(pg_temp.u('a1'), 'e1')) e), 8,
          'bandeja de Con límite: las mismas filas de siempre (ocho; no sale el pedido de baja ni lo de otras campañas)');
select is(pg_temp.en_lista(pg_temp.u('ad'), 'e1', 'c2'), '30000/1', 'el ADMIN ve lo mismo que la coordinadora');
select is(pg_temp.lista(pg_temp.u('a2'), 'e1') ->> 'error', '42501', 'la coordinadora de otra campaña sigue con 42501');
select is(pg_temp.lista(null, 'e1') ->> 'error', '42501', 'sin sesión sigue con 42501');
select is(pg_temp.lista(pg_temp.u('b1'), 'e1') ->> 'error', '42501', 'un colportor sigue con 42501');
select is((select count(*)::int from jsonb_array_elements(pg_temp.lista(pg_temp.u('a1'), 'e5')) e), 0,
          'una campaña terminada se lee (sin pedidos: lista vacía, sin error)');

-- ============================================================================
-- 4. pedido_contexto(): lo mismo, en el detalle de un pedido
-- ============================================================================
select is(pg_temp.en_contexto(pg_temp.u('a1'), 'c1'), '30000/n', 'detalle: justo en el límite, no lo supera');
select is(pg_temp.en_contexto(pg_temp.u('a1'), 'c2'), '30000/1', 'detalle: supera por 1');
select is(pg_temp.en_contexto(pg_temp.u('a1'), 'c4'), '30000/3500', 'detalle: supera por 3.500');
select is(pg_temp.en_contexto(pg_temp.u('a1'), 'c7'), '30000/10000', 'detalle: sin cuenta, supera por 10.000');
select is(pg_temp.en_contexto(pg_temp.u('a1'), 'c5'), '30000/n', 'detalle: autorizado, el límite sin medir');
select is(pg_temp.en_contexto(pg_temp.u('a1'), 'c6'), '30000/n', 'detalle: rechazado, el límite sin medir');
select is(pg_temp.en_contexto(pg_temp.u('a1'), 'c8'), 'n/n', 'detalle de una campaña sin límite: las dos en null');
select is(pg_temp.en_contexto(pg_temp.u('a1'), 'c9'), '0/100', 'detalle con límite cero: supera por 100');
select is(pg_temp.en_contexto(pg_temp.u('ad'), 'ca'), 'n/n',
          'detalle de un pedido sin campaña (solo lo ve el ADMIN): sin límite y nada que medir');
select is(pg_temp.en_contexto(pg_temp.u('ad'), 'c2'), '30000/1', 'el ADMIN ve el detalle igual que la coordinadora');
select is(pg_temp.en_contexto(pg_temp.u('a2'), 'c2'), '42501', 'la coordinadora de otra campaña sigue con 42501');
select is(pg_temp.en_contexto(pg_temp.u('a1'), 'ca'), '42501', 'un pedido sin campaña sigue siendo solo del ADMIN');
select is(pg_temp.contexto(null, 'c2') ->> 'error', '42501', 'sin sesión sigue con 42501');
select is(pg_temp.contexto(pg_temp.u('a1'), 'cc') ->> 'error', 'PE001', 'un pedido dado de baja sigue con PE001');
-- La deuda del detalle no cambió: la actual, y con el pedido (solo por autorizar).
select is((pg_temp.contexto(pg_temp.u('a1'), 'c2') -> 0) - 'nombre' - 'apellido' - 'numero' - 'colportor_id',
          jsonb_build_object('estado', 'PENDIENTE_AUTORIZACION', 'monto_total', 10001, 'monto_autorizado', null,
                             'deuda_actual', 20000, 'deuda_con_pedido', 30001, 'por_cobrar', 0,
                             'libros_por_entregar', 0, 'ultimo_deposito_fecha', null, 'ultimo_deposito_monto', null,
                             'limite_deuda', 30000, 'supera_limite_por', 1),
          'detalle: lo de siempre no cambia y el límite coincide con deuda_con_pedido - limite_deuda');

-- ============================================================================
-- 5. Cambiar el límite se ve en las lecturas; quitarlo, también
-- ============================================================================
update public.campania set limite_deuda = 25000 where id = pg_temp.u('e1');
select is(pg_temp.en_lista(pg_temp.u('a1'), 'e1', 'c1'), '25000/5000', 'si el límite baja a 25.000, el pedido de 10.000 pasa a superar por 5.000');
select is(pg_temp.en_contexto(pg_temp.u('a1'), 'c1'), '25000/5000', 'y el detalle lo dice igual');
select is((select e ->> 'limite_deuda' from jsonb_array_elements(pg_temp.como(pg_temp.u('a1'),
            'select * from public.campanias_del_coordinador()')) e where e ->> 'nombre' = 'Con límite'), '25000',
          'y campanias_del_coordinador() trae el límite nuevo');
update public.campania set limite_deuda = null where id = pg_temp.u('e1');
select is(pg_temp.en_lista(pg_temp.u('a1'), 'e1', 'c2'), 'n/n', 'quitado el límite, nada supera');
select is(pg_temp.en_contexto(pg_temp.u('a1'), 'c2'), 'n/n', 'y el detalle tampoco');

select * from finish();
rollback;
