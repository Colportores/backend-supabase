-- pgTAP · migración 0168 (backend-supabase#243, casilla «Variación semanal»; decisión de Cristian del 04/11, «Del servidor,
-- todo cuenta»): `mi_deuda_con_la_casa_editora()` devuelve también `deuda_hace_7_dias`.
--   1. La forma: la tabla `cuenta_deuda_historial` (RLS, privilegios), el trigger de `cuenta_colportor`, la clave nueva.
--   2. El historial se llena con cada cambio de la deuda, sea cual sea la causa (cuenta nueva, depósito, tarjeta, alquiler,
--      una transferencia o el servidor a mano), y no con lo que no la mueve; una cuenta de baja figura en 0.
--   3. La respuesta: `null` sin datos de hace 7 días (cuenta nueva, sin cuenta); con datos, la última deuda registrada hasta
--      hace 7 días exactos; el borde (7 × 24 h exactos incluido, un segundo después no); con y sin cambios dentro de la semana.
--   4. Quién lee el historial: la propia persona y el ADMIN; nadie lo escribe con JWT.
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
  select ('01920000-0000-7000-8000-0000000168' || p)::uuid;
$$;
create or replace function pg_temp.error_de(p_sql text) returns text language plpgsql as $$
begin
  execute p_sql;
  return 'ok';
exception when others then
  return sqlstate;
end $$;
-- La respuesta de la colportora p (como ella), vuelta al servidor.
create or replace function pg_temp.mi(p text) returns jsonb language plpgsql as $$
declare r jsonb;
begin
  perform pg_temp.actuar_como(pg_temp.u(p));
  r := public.mi_deuda_con_la_casa_editora();
  perform pg_temp.actuar_como_servidor();
  return r;
end $$;
-- «deuda_total|deuda_hace_7_dias» (n si es null).
create or replace function pg_temp.dos(p text) returns text language sql as $$
  select format('%s|%s', j ->> 'deuda_total', coalesce(j ->> 'deuda_hace_7_dias', 'n'))
    from (select pg_temp.mi(p) j) x;
$$;
-- Las deudas registradas de p, de la más vieja a la más nueva: «100,90,0».
create or replace function pg_temp.hist(p text) returns text language sql security definer as $$
  select coalesce(string_agg(deuda::text, ',' order by desde, id), '-')
    from public.cuenta_deuda_historial where usuario_id = pg_temp.u(p)
$$;
-- Mueve en el tiempo las filas del historial de p: la n-ésima (por orden de llegada) pasa a «ahora − intervalo».
create or replace function pg_temp.fechar(p text, p_n int, p_hace interval) returns void language sql security definer as $$
  update public.cuenta_deuda_historial h
     set desde = now() - p_hace
   where h.id = (select x.id from public.cuenta_deuda_historial x where x.usuario_id = pg_temp.u(p)
                  order by x.desde, x.id offset p_n - 1 limit 1);
$$;

-- --- fixtures ------------------------------------------------------------------
insert into auth.users (id, instance_id, aud, role, email, encrypted_password, confirmed_at, created_at, updated_at)
select pg_temp.u(s), '00000000-0000-0000-0000-000000000000',
       'authenticated', 'authenticated', 'hist168-' || s || '@example.com', 'x', now(), now(), now()
  from unnest(array['b1','b2','b3','b4','b5','ad']) s;
insert into public.usuario_rol (usuario_id, rol_id)
select pg_temp.u(x.s), r.id
  from (values ('b1','COLPORTOR'), ('b2','COLPORTOR'), ('b3','COLPORTOR'), ('b4','COLPORTOR'), ('b5','COLPORTOR'),
               ('ad','ADMIN')) x(s, codigo)
  join public.rol r on r.codigo = x.codigo;

-- ---------------------------------------------------------------------------
-- 1. La forma
-- ---------------------------------------------------------------------------
select has_table('public', 'cuenta_deuda_historial', 'existe cuenta_deuda_historial');
select col_is_fk('public', 'cuenta_deuda_historial', 'usuario_id', 'usuario_id es FK');
select col_type_is('public', 'cuenta_deuda_historial', 'deuda', 'bigint', 'deuda es bigint');
select is((select relrowsecurity from pg_class where oid = 'public.cuenta_deuda_historial'::regclass), true, 'con RLS');
select is(has_table_privilege('authenticated', 'public.cuenta_deuda_historial', 'insert')
          or has_table_privilege('authenticated', 'public.cuenta_deuda_historial', 'update')
          or has_table_privilege('authenticated', 'public.cuenta_deuda_historial', 'delete'), false,
          'authenticated no la escribe');
select is(has_table_privilege('anon', 'public.cuenta_deuda_historial', 'select'), false, 'anon no la lee');
select is((select count(*)::int from sync.entidad where tabla = 'public.cuenta_deuda_historial'::regclass and not permite_push), 1,
          'viaja por el sync desde la 0179, de solo bajada (el teléfono no la escribe)');
select has_trigger('public', 'cuenta_colportor', 'cuenta_colportor_historial_deuda', 'cuenta_colportor tiene el trigger del historial');
select is((select p.prosecdef from pg_proc p where p.oid = 'public.tg_cuenta_colportor_historial_deuda()'::regprocedure), true,
          'que es SECURITY DEFINER');
select is((select has_function_privilege(r, 'public.tg_cuenta_colportor_historial_deuda()', 'execute')), false,
          format('y %s no la ejecuta', r))
  from unnest(array['anon', 'authenticated', 'service_role']) r;
select is(jsonb_typeof(pg_temp.mi('b5') -> 'deuda_hace_7_dias'), 'null', 'la respuesta trae la clave, en null cuando no hay datos');

-- ---------------------------------------------------------------------------
-- 2. El historial se llena con cada cambio, sea cual sea la causa
-- ---------------------------------------------------------------------------
-- b1: la cuenta nace con 100000.
insert into public.cuenta_colportor (usuario_id, deuda_total) values (pg_temp.u('b1'), 100000);
select is(pg_temp.hist('b1'), '100000', 'una cuenta nueva deja su primera fila');
-- Un cambio que no mueve la deuda no deja fila.
update public.cuenta_colportor set dinero_depositado = 5 where usuario_id = pg_temp.u('b1');
update public.cuenta_colportor set deuda_total = 100000 where usuario_id = pg_temp.u('b1');
select is(pg_temp.hist('b1'), '100000', 'tocar otra cifra, o dejar la deuda igual, no deja fila');
-- Un depósito validado a la casa editora (acreditar_en_la_cuenta) baja la deuda.
select public.acreditar_en_la_cuenta(pg_temp.u('b1'), 10000, true);
select is(pg_temp.hist('b1'), '100000,90000', 'validar un depósito o una tarjeta deja una fila');
-- Un depósito que no es de la casa editora (alquiler) suma a Depositado y no mueve la deuda: sin fila.
select public.acreditar_en_la_cuenta(pg_temp.u('b1'), 3000, false);
select is(pg_temp.hist('b1'), '100000,90000', 'depositar sin bajar la deuda no deja fila');
-- El alquiler pagado de más (trasladar_alquiler_a_la_deuda) baja la deuda.
select public.trasladar_alquiler_a_la_deuda(pg_temp.u('b1'), 5000);
select is(pg_temp.hist('b1'), '100000,90000,85000', 'el alquiler trasladado deja una fila');
-- Una transferencia o el servidor a mano (update directo).
update public.cuenta_colportor set deuda_total = deuda_total + 20000 where usuario_id = pg_temp.u('b1');
select is(pg_temp.hist('b1'), '100000,90000,85000,105000', 'cualquier otra causa también');
-- La cuenta dada de baja se lee en 0; al reactivarla vuelve su deuda.
update public.cuenta_colportor set deleted_at = now() where usuario_id = pg_temp.u('b1');
select is(pg_temp.hist('b1'), '100000,90000,85000,105000,0', 'una cuenta de baja figura en 0');
update public.cuenta_colportor set deleted_at = null where usuario_id = pg_temp.u('b1');
select is(pg_temp.hist('b1'), '100000,90000,85000,105000,0,105000', 'y al reactivarla, su deuda de nuevo');
-- Una deuda a favor se guarda negativa.
update public.cuenta_colportor set deuda_total = -700 where usuario_id = pg_temp.u('b1');
select is(pg_temp.hist('b1'), '100000,90000,85000,105000,0,105000,-700', 'una deuda a favor, negativa');

-- ---------------------------------------------------------------------------
-- 3. La respuesta
-- ---------------------------------------------------------------------------
-- Hoy todo se registró hace un instante: no hay datos de hace 7 días.
select is(pg_temp.dos('b1'), '-700|n', 'sin datos de hace 7 días: null');
select is(pg_temp.dos('b2'), '0|n', 'sin cuenta: deuda 0 y null');
-- b1: 100000 hace 20 días, 90000 hace 10, 85000 hace 3 días... y el resto, hoy.
select pg_temp.fechar('b1', 1, interval '20 days');
select pg_temp.fechar('b1', 2, interval '10 days');
select pg_temp.fechar('b1', 3, interval '3 days');
select pg_temp.fechar('b1', 4, interval '2 days');
select pg_temp.fechar('b1', 5, interval '1 day');
select pg_temp.fechar('b1', 6, interval '1 hour');
select is(pg_temp.dos('b1'), '-700|90000', 'con datos: la última deuda registrada hasta hace 7 días (90000, de hace 10)');
-- El cambio de la semana no la mueve: el valor de hace 7 días sigue siendo el mismo hasta que pase una fila más.
select public.acreditar_en_la_cuenta(pg_temp.u('b1'), 1, true);
select is(pg_temp.dos('b1'), '-701|90000', 'un cambio de hoy mueve el total y no el de hace 7 días');
-- El borde: exactamente hace 7 días entra; un segundo después, no.
select pg_temp.fechar('b1', 3, interval '7 days');
select is(pg_temp.dos('b1'), '-701|85000', 'una fila de hace exactamente 7 × 24 h cuenta (<=)');
select pg_temp.fechar('b1', 3, interval '7 days' - interval '1 second');
select is(pg_temp.dos('b1'), '-701|90000', 'un segundo menos de 7 días, no');
-- Sin cambios en la semana: la deuda de hace 7 días es la misma de hoy (la cuenta tiene una fila vieja).
insert into public.cuenta_colportor (usuario_id, deuda_total) values (pg_temp.u('b3'), 4200);
select pg_temp.fechar('b3', 1, interval '9 days');
select is(pg_temp.dos('b3'), '4200|4200', 'una deuda que no cambió en la semana: la de hoy y la de hace 7 días son la misma');
-- Una cuenta que nació hace 3 días: antes de eso no hay datos.
insert into public.cuenta_colportor (usuario_id, deuda_total) values (pg_temp.u('b4'), 9000);
select pg_temp.fechar('b4', 1, interval '3 days');
select is(pg_temp.dos('b4'), '9000|n', 'cuenta de hace 3 días: no hay datos de hace 7');
-- Una cuenta que se dio de baja hoy: debe 0, pero hace 7 días debía lo suyo.
insert into public.cuenta_colportor (usuario_id, deuda_total) values (pg_temp.u('b5'), 5000);
select pg_temp.fechar('b5', 1, interval '12 days');
update public.cuenta_colportor set deleted_at = now() where usuario_id = pg_temp.u('b5');
select is(pg_temp.dos('b5'), '0|5000', 'cuenta dada de baja hoy: hoy 0 y hace 7 días 5000');
-- Cada colportora ve solo lo suyo.
select is(pg_temp.dos('b3'), '4200|4200', 'b3 no ve nada de b1');
select is(pg_temp.dos('ad'), '0|n', 'el ADMIN ve su propia cuenta (vacía)');
-- La lectura es repetible y no cambia nada.
select is(pg_temp.dos('b1'), pg_temp.dos('b1'), 'leerla dos veces da lo mismo');
select is(pg_temp.hist('b3'), '4200', 'y no deja filas');

-- ---------------------------------------------------------------------------
-- 4. Quién lee el historial
-- ---------------------------------------------------------------------------
select pg_temp.actuar_como(pg_temp.u('b3'));
select is((select count(*)::int from public.cuenta_deuda_historial), 1, 'b3 lee solo su fila');
select is(pg_temp.error_de($$ insert into public.cuenta_deuda_historial (usuario_id, deuda) values (pg_temp.u('b3'), 1) $$), '42501',
          'y no escribe (42501)');
select is(pg_temp.error_de($$ update public.cuenta_deuda_historial set deuda = 1 $$), '42501', 'ni corrige (42501)');
select pg_temp.actuar_como(pg_temp.u('ad'));
select is((select count(distinct usuario_id)::int from public.cuenta_deuda_historial where usuario_id in (pg_temp.u('b1'), pg_temp.u('b3'), pg_temp.u('b4'), pg_temp.u('b5'))),
          4, 'el ADMIN lee las de varias personas');
select pg_temp.actuar_como_servidor();

select * from finish();
rollback;
