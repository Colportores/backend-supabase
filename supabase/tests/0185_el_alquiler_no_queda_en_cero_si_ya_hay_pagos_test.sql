-- pgTAP · el alquiler de la campaña no puede quedar en 0 ni vacío si ya hay pagos (migración 0185,
-- backend-supabase#260, HU-CAM-002, decisión de Cristian del 10/11 «Alquiler a 0»: «Bloquear si ya hay pagos»).
-- definir_alquiler_de_campania(): con un pago por validar (con comprobante pendiente o sin comprobante), con uno validado
-- (aunque sea de una baja) o con uno en un estado que no encaja (ante la duda) se rechaza 0 y null con CZ017 sin escribir
-- nada; con todos rechazados, anulados o dados de baja, o sin pagos, deja; cambiar el monto con pagos deja; el ADMIN
-- también se frena; el orden de los errores de antes no cambia.
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

-- El uuid de un personaje del test (sufijo de dos caracteres HEX).
create or replace function pg_temp.u(p_sufijo text) returns uuid language sql immutable as $$
  select ('01920000-0000-7000-8000-0000000185' || p_sufijo)::uuid
$$;

-- «sqlstate: mensaje» del error de una llamada, u «ok».
create or replace function pg_temp.error_de(p_sql text) returns text language plpgsql as $$
begin
  execute p_sql;
  return 'ok';
exception when others then
  return sqlstate || ': ' || sqlerrm;
end $$;

-- definir_alquiler_de_campania(campaña, monto) como texto «monto|cambio», o el error.
create or replace function pg_temp.definir(p_camp text, p_monto bigint) returns text language plpgsql as $$
declare v text;
begin
  select format('%s|%s', coalesce(r.alquiler_monto::text, 'null'), r.cambio) into v
    from public.definir_alquiler_de_campania(pg_temp.u(p_camp), p_monto) r;
  return v;
exception when others then
  return sqlstate || ': ' || sqlerrm;
end $$;

-- El monto guardado de una campaña y cuántos registros de cambio tiene. SECURITY DEFINER: audit_log no la lee nadie con JWT.
create or replace function pg_temp.estado(p_camp text) returns text language sql security definer as $$
  select format('%s|%s',
                coalesce((select c.alquiler_monto::text from public.campania c where c.id = pg_temp.u(p_camp)), 'null'),
                (select count(*) from auditoria.audit_log a
                  where a.event_type = 'alquiler_de_campania_cambiado' and a.fila_id = pg_temp.u(p_camp)))
$$;

-- --- fixtures (como postgres) --------------------------------------------------
-- a1 coordina e1..e6; ad ADMIN. Todas las campañas cobran 150000 y están en curso.
--   e1 b1 un pago con el comprobante PENDIENTE (por validar)
--   e2 b2 un pago validado; la inscripción de b2 está dada de baja (su pago sigue contando)
--   e3 b3 solo pagos que no cuentan: un retiro rechazado, uno con el comprobante RECHAZADO, uno validado y anulado
--         (devuelto, 0167) y uno dado de baja; más un depósito de casa editora de esta campaña
--   e4 b4 sin ningún pago de alquiler (tiene un depósito de casa editora de esta campaña)
--   e5 b5 un retiro sin comprobante, todavía por validar
--   e6 b6 un pago sin validar con el comprobante VALIDADO (un estado que no encaja: ante la duda, cuenta)
insert into auth.users (id, instance_id, aud, role, email, encrypted_password, confirmed_at, created_at, updated_at)
select pg_temp.u(s), '00000000-0000-0000-0000-000000000000',
       'authenticated', 'authenticated', 'alq185-' || s || '@example.com', 'x', now(), now(), now()
  from unnest(array['a1','ad','b1','b2','b3','b4','b5','b6']) s;
insert into public.usuario_rol (usuario_id, rol_id)
select pg_temp.u(x.s), r.id
  from (values ('a1','COORDINADOR'), ('ad','ADMIN'), ('b1','COLPORTOR'), ('b2','COLPORTOR'), ('b3','COLPORTOR'),
               ('b4','COLPORTOR'), ('b5','COLPORTOR'), ('b6','COLPORTOR')) x(s, codigo)
  join public.rol r on r.codigo = x.codigo;

insert into public.campania (id, nombre, tipo, fecha_inicio, fecha_fin, coordinador_id, alquiler_monto)
select pg_temp.u(s), s || ' alq185', 'VERANO', public.hoy_montevideo() - 10, public.hoy_montevideo() + 30, pg_temp.u('a1'), 150000
  from unnest(array['e1','e2','e3','e4','e5','e6']) s;
insert into public.campania_colportor (campania_id, usuario_id, created_at)
select pg_temp.u(x.e), pg_temp.u(x.b), now() - interval '10 days'
  from (values ('e1','b1'), ('e2','b2'), ('e3','b3'), ('e4','b4'), ('e5','b5'), ('e6','b6')) x(e, b);
update public.campania_colportor set deleted_at = now()
 where campania_id = pg_temp.u('e2') and usuario_id = pg_temp.u('b2');

insert into public.ticket (id, usuario_id, tipo, estado, motivo_rechazo) values
  (pg_temp.u('51'), pg_temp.u('b1'), 'DEPOSITO', 'PENDIENTE', null),
  (pg_temp.u('53'), pg_temp.u('b3'), 'DEPOSITO', 'RECHAZADO', 'No se ve el monto'),
  (pg_temp.u('54'), pg_temp.u('b3'), 'DEPOSITO', 'PENDIENTE', null),
  (pg_temp.u('55'), pg_temp.u('b4'), 'DEPOSITO', 'PENDIENTE', null),
  (pg_temp.u('56'), pg_temp.u('b6'), 'DEPOSITO', 'VALIDADO',  null);

insert into public.deposito (id, colportor_id, monto, fecha, ticket_id, destino, concepto, campania_id) values
  (pg_temp.u('d1'), pg_temp.u('b1'), 30000, now(), pg_temp.u('51'), 'BANCO',              'ALQUILER',     pg_temp.u('e1')),
  (pg_temp.u('d4'), pg_temp.u('b3'), 20000, now(), pg_temp.u('53'), 'BANCO',              'ALQUILER',     pg_temp.u('e3')),
  (pg_temp.u('d7'), pg_temp.u('b3'), 9000,  now(), pg_temp.u('54'), 'BANCO',              'CASA_EDITORA', pg_temp.u('e3')),
  (pg_temp.u('d8'), pg_temp.u('b4'), 8000,  now(), pg_temp.u('55'), 'BANCO',              'CASA_EDITORA', pg_temp.u('e4')),
  (pg_temp.u('d9'), pg_temp.u('b5'), 10000, now(), null,            'RETIRO_COORDINADOR', 'ALQUILER',     pg_temp.u('e5')),
  (pg_temp.u('da'), pg_temp.u('b6'), 12000, now(), pg_temp.u('56'), 'BANCO',              'ALQUILER',     pg_temp.u('e6'));
insert into public.deposito (id, colportor_id, monto, fecha, ticket_id, destino, concepto, campania_id, validado_en, validado_por) values
  (pg_temp.u('d2'), pg_temp.u('b2'), 40000, now(), null, 'RETIRO_COORDINADOR', 'ALQUILER', pg_temp.u('e2'), now(), pg_temp.u('a1'));
insert into public.deposito (id, colportor_id, monto, fecha, ticket_id, destino, concepto, campania_id,
                             rechazado_en, rechazado_por, motivo_rechazo) values
  (pg_temp.u('d3'), pg_temp.u('b3'), 15000, now(), null, 'RETIRO_COORDINADOR', 'ALQUILER', pg_temp.u('e3'),
   now(), pg_temp.u('a1'), 'No me lo entregó');
insert into public.deposito (id, colportor_id, monto, fecha, ticket_id, destino, concepto, campania_id, validado_en, validado_por,
                             anulado_at, anulado_por) values
  (pg_temp.u('d5'), pg_temp.u('b3'), 25000, now(), null, 'RETIRO_COORDINADOR', 'ALQUILER', pg_temp.u('e3'), now(), pg_temp.u('a1'),
   now(), pg_temp.u('a1'));
insert into public.deposito (id, colportor_id, monto, fecha, ticket_id, destino, concepto, campania_id, deleted_at) values
  (pg_temp.u('d6'), pg_temp.u('b3'), 35000, now(), null, 'RETIRO_COORDINADOR', 'ALQUILER', pg_temp.u('e3'), now());

-- El aviso de CZ017, uno solo para todos los casos.
create temp table aviso (t text);
insert into aviso values ('CZ017: Ya hay pagos de alquiler en esta campaña, así que no puede quedar sin alquiler ni en cero. '
                          || 'Podés cambiarlo por otro monto mayor que cero.');
grant select on aviso to public;

select pg_temp.actuar_como(pg_temp.u('a1'));

-- ---------------------------------------------------------------------------
-- 1. Con pagos vivos: ni 0 ni vacío, y no se escribe nada
-- ---------------------------------------------------------------------------
select is(pg_temp.definir('e1', 0), (select t from aviso),
          'por validar (comprobante pendiente): 0 se rechaza con CZ017 y un aviso que guía');
select is(pg_temp.definir('e1', null), (select t from aviso), 'por validar (comprobante pendiente): vacío también');
select is(pg_temp.estado('e1'), '150000|0', '  … el monto sigue y no quedó registro en audit_log');

select is(pg_temp.definir('e2', 0), (select t from aviso), 'validado (de una baja): 0 se rechaza');
select is(pg_temp.definir('e2', null), (select t from aviso), 'validado (de una baja): vacío también');
select is(pg_temp.estado('e2'), '150000|0', '  … sin cambios');

select is(pg_temp.definir('e5', 0), (select t from aviso), 'retiro sin comprobante por validar: 0 se rechaza');
select is(pg_temp.definir('e5', null), (select t from aviso), 'retiro sin comprobante por validar: vacío también');
select is(pg_temp.estado('e5'), '150000|0', '  … sin cambios');

select is(pg_temp.definir('e6', 0), (select t from aviso),
          'sin validar con el comprobante VALIDADO (no encaja): ante la duda cuenta como pago y se bloquea');
select is(pg_temp.estado('e6'), '150000|0', '  … sin cambios');

-- El ADMIN también se frena.
select pg_temp.actuar_como(pg_temp.u('ad'));
select is(pg_temp.definir('e1', null), (select t from aviso), 'el ADMIN tampoco deja la campaña sin alquiler si hay pagos');
select pg_temp.actuar_como(pg_temp.u('a1'));

-- Los errores de antes salen antes que CZ017: el monto negativo sigue siendo 22023.
select is(pg_temp.definir('e1', -1),
          '22023: El alquiler no puede ser negativo. Escribí un monto de cero o más, o dejalo vacío si la campaña no cobra alquiler.',
          'con pagos, un monto negativo sigue dando su error de siempre');

-- ---------------------------------------------------------------------------
-- 2. Con pagos, cambiar el monto a otro mayor que 0 deja
-- ---------------------------------------------------------------------------
select is(pg_temp.definir('e1', 200000), '200000|t', 'con pagos, subir el monto deja');
select is(pg_temp.definir('e1', 1), '1|t', 'con pagos, bajarlo a 1 centavo deja (mayor que 0)');
select is(pg_temp.definir('e1', 1), '1|f', '  … y el mismo valor sigue siendo idempotente');
select is(pg_temp.estado('e1'), '1|2', '  … dos cambios, dos registros');
select is(pg_temp.definir('e2', 180000), '180000|t', 'con un pago validado, cambiar el monto deja');

-- ---------------------------------------------------------------------------
-- 3. Sin pagos vivos: 0 y vacío dejan
-- ---------------------------------------------------------------------------
select is(pg_temp.definir('e3', 0), '0|t',
          'solo rechazados (retiro y comprobante), anulados y dados de baja: 0 deja');
select is(pg_temp.definir('e3', null), 'null|t', '  … y vacío también');
select is(pg_temp.estado('e3'), 'null|2', '  … con sus dos registros');

select is(pg_temp.definir('e4', null), 'null|t', 'sin pagos de alquiler (solo casa editora): vacío deja');
select is(pg_temp.definir('e4', 0), '0|t', '  … y 0 también');
select is(pg_temp.definir('e4', 150000), '150000|t', '  … y vuelve a cobrar');

-- Si nadie pagó todavía y después llega un pago, desde ese momento se bloquea.
select pg_temp.actuar_como_servidor();
insert into public.deposito (id, colportor_id, monto, fecha, ticket_id, destino, concepto, campania_id) values
  (pg_temp.u('db'), pg_temp.u('b4'), 5000, now(), null, 'RETIRO_COORDINADOR', 'ALQUILER', pg_temp.u('e4'));
select pg_temp.actuar_como(pg_temp.u('a1'));
select is(pg_temp.definir('e4', 0), (select t from aviso), 'llega el primer pago de e4: desde ahí 0 se rechaza');

-- Y si ese único pago se rechaza, vuelve a dejar.
select pg_temp.actuar_como_servidor();
update public.deposito set rechazado_en = now(), rechazado_por = pg_temp.u('a1'), motivo_rechazo = 'No lo entregó'
 where id = pg_temp.u('db');
select pg_temp.actuar_como(pg_temp.u('a1'));
select is(pg_temp.definir('e4', 0), '0|t', 'rechazado ese pago, e4 vuelve a poder quedar en 0');

-- ---------------------------------------------------------------------------
-- 4. La función sigue siendo la misma (firma, DEFINER, search_path, privilegios)
-- ---------------------------------------------------------------------------
select pg_temp.actuar_como_servidor();
select is((select p.prosecdef from pg_proc p where p.oid = 'public.definir_alquiler_de_campania(uuid, bigint)'::regprocedure),
          true, 'sigue siendo SECURITY DEFINER');
select is((select p.proconfig from pg_proc p where p.oid = 'public.definir_alquiler_de_campania(uuid, bigint)'::regprocedure),
          array['search_path=""'], 'con search_path vacío');
select ok(has_function_privilege('authenticated', 'public.definir_alquiler_de_campania(uuid, bigint)', 'execute')
          and not has_function_privilege('anon', 'public.definir_alquiler_de_campania(uuid, bigint)', 'execute')
          and not has_function_privilege('service_role', 'public.definir_alquiler_de_campania(uuid, bigint)', 'execute'),
          'EXECUTE solo para authenticated');
select ok(obj_description('public.definir_alquiler_de_campania(uuid, bigint)'::regprocedure, 'pg_proc') like '%CZ017%',
          'el comentario de la función nombra CZ017');

select * from finish();
rollback;
