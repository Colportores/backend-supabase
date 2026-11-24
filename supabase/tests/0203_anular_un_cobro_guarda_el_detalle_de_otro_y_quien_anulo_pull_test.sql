-- pgTAP · migración 0203 (backend-supabase#306, decisión de Cristian del 23/11 «Anul. al tel»), el pull: la anulación que
-- hace el coordinador desde el panel baja al teléfono de la colportora con la sincronización.
--   1. Ana baja SOLO sus cobros (la RLS de `cobranza` es del dueño de la venta): ni los de otra colportora, ni el coordinador
--      que la anuló ve los cobros de ella por el pull.
--   2. La fila del cobro anulado trae la fecha, el motivo de la lista y quién lo anuló, y nada del detalle de «Otro».
--   3. El delta: la anulación que hace el coordinador después de un pull baja sola en el siguiente; un doble toque no la
--      vuelve a bajar; lo de otra persona no se cuela.
--   4. El detalle de «Otro» no aparece en ninguna respuesta del pull, ni siquiera en la del coordinador que lo escribió.
-- Como 0201, NO va en una transacción (el delta solo sirve lo commiteado). Inserta los cobros directo, como el servidor, y
-- anula con `anular_cobro()`, que no deja eventos en audit_log (que solo se agrega). Limpia al empezar y al final.

select * from no_plan();

create or replace function pg_temp.actuar_como(p_uid uuid) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', json_build_object('sub', p_uid, 'role', 'authenticated')::text, false);
  perform set_config('request.jwt.claim.sub', p_uid::text, false);
  perform set_config('role', 'authenticated', false);
end $$;

create or replace function pg_temp.como_servidor() returns void language plpgsql as $$
begin
  perform set_config('role', 'postgres', false);
  perform set_config('request.jwt.claims', '', false);
  perform set_config('request.jwt.claim.sub', '', false);
end $$;

-- Ids con el prefijo 2031: usuarios 2031b1.., campañas 2031e1.., ventas 203151.., cobros 2031c1..
create or replace function pg_temp.u(p_sufijo text) returns uuid language sql as $$
  select ('01920000-0000-7000-8000-00000203' || p_sufijo)::uuid;
$$;
create or replace function pg_temp.c(p_n integer) returns uuid language sql as $$
  select pg_temp.u('c' || lpad(p_n::text, 3, '0'));
$$;

create or replace function pg_temp.limpiar() returns void language plpgsql as $$
declare v_ids uuid[] := array[pg_temp.u('b1b1'), pg_temp.u('b2b2'), pg_temp.u('d1d1'), pg_temp.u('a1a1')];
begin
  delete from public.cobranza_anulacion_detalle where cobranza_id in (select c.id from public.cobranza c join public.venta v on v.id = c.venta_id where v.colportor_id = any (v_ids));
  delete from public.cobranza where venta_id in (select id from public.venta where colportor_id = any (v_ids));
  delete from public.venta where colportor_id = any (v_ids);
  delete from public.espacio_persona where created_by = any (v_ids);
  delete from public.espacio where created_by = any (v_ids);
  delete from public.ubicacion where ciudad_id = pg_temp.u('c1c1');
  delete from public.ciudad where id = pg_temp.u('c1c1');
  delete from public.pais where id = pg_temp.u('c0c0');
  delete from public.campania_colportor where usuario_id = any (v_ids);
  delete from public.campania where id = pg_temp.u('e1e1');
  delete from public.usuario_rol where usuario_id = any (v_ids);
  delete from auth.users where id = any (v_ids);
end $$;

create or replace function pg_temp.pull_de(p text, p_marca jsonb default '{}'::jsonb) returns jsonb
language plpgsql as $$
declare d jsonb;
begin
  perform pg_temp.actuar_como(pg_temp.u(p));
  d := sync.pull(array['cobranza'], p_marca, 1000);
  perform pg_temp.como_servidor();
  return d;
end $$;

-- Las filas de cobranza de una respuesta.
create or replace function pg_temp.filas(p_delta jsonb) returns setof jsonb language sql as $$
  select e from jsonb_array_elements(coalesce(p_delta -> 'rows' -> 'cobranza', '[]'::jsonb)) e
$$;

-- Los cobros que bajaron: «n[/anulado:motivo:por]» ordenados por id.
create or replace function pg_temp.cobros(p_delta jsonb) returns text language sql as $$
  select coalesce(string_agg(
           right(e ->> 'id', 3)
           || case when e ->> 'anulado_at' is null then ''
                   else '/anulado:' || (e ->> 'motivo_anulacion') || ':'
                        || coalesce(case (e ->> 'anulado_por')::uuid
                                      when pg_temp.u('b1b1') then 'ana'
                                      when pg_temp.u('d1d1') then 'marta'
                                      when pg_temp.u('a1a1') then 'admin' end, '?') end,
           ',' order by e ->> 'id'), '-')
    from pg_temp.filas(p_delta) e
$$;

-- ---------------------------------------------------------------------------
-- Fixtures (como postgres). Ana (b1b1) y Beatriz (b2b2) colportoras de e1, que coordina Marta (d1d1); ad es ADMIN.
-- Ana tiene los cobros 1, 2 y 3; Beatriz el 4.
-- ---------------------------------------------------------------------------
select pg_temp.limpiar();
insert into auth.users (id, instance_id, aud, role, email, encrypted_password, confirmed_at, created_at, updated_at)
select pg_temp.u(s), '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
       'cob203p-' || s || '@example.com', 'x', now(), now(), now()
  from unnest(array['b1b1','b2b2','d1d1','a1a1']) s;
insert into public.usuario_rol (usuario_id, rol_id)
select pg_temp.u(x.s), r.id
  from (values ('b1b1','COLPORTOR'), ('b2b2','COLPORTOR'), ('d1d1','COORDINADOR'), ('a1a1','ADMIN')) x(s, codigo)
  join public.rol r on r.codigo = x.codigo;
insert into public.campania (id, nombre, tipo, fecha_inicio, fecha_fin, coordinador_id) values
  (pg_temp.u('e1e1'), 'e1 cob203', 'VERANO', public.hoy_montevideo() - 10, public.hoy_montevideo() + 30, pg_temp.u('d1d1'));
insert into public.campania_colportor (campania_id, usuario_id, created_at) values
  (pg_temp.u('e1e1'), pg_temp.u('b1b1'), now() - interval '10 days'),
  (pg_temp.u('e1e1'), pg_temp.u('b2b2'), now() - interval '10 days');
insert into public.pais (id, nombre, iso_code) values (pg_temp.u('c0c0'), 'Pais cob203', 'ZE');
insert into public.ciudad (id, nombre, departamento, pais_id, lat_centro, lon_centro)
values (pg_temp.u('c1c1'), 'Ciudad cob203', 'Departamento de prueba', pg_temp.u('c0c0'), -34.9, -56.2);
insert into public.ubicacion (id, tipo, calle, numero, lat, lon, ciudad_id, created_by) values
  (pg_temp.u('0101'), 'CASA', 'Cob203 01', '1', -34.91, -56.2, pg_temp.u('c1c1'), pg_temp.u('b1b1')),
  (pg_temp.u('0202'), 'CASA', 'Cob203 02', '2', -34.92, -56.2, pg_temp.u('c1c1'), pg_temp.u('b2b2'));
insert into public.espacio (id, ubicacion_id, numero_depto, created_by) values
  (pg_temp.u('1111'), pg_temp.u('0101'), null, pg_temp.u('b1b1')),
  (pg_temp.u('1212'), pg_temp.u('0202'), null, pg_temp.u('b2b2'));
insert into public.espacio_persona (id, espacio_id, persona_id, created_by) values
  (pg_temp.u('2121'), pg_temp.u('1111'), pg_temp.u('a2a2'), pg_temp.u('b1b1')),
  (pg_temp.u('2222'), pg_temp.u('1212'), pg_temp.u('a3a3'), pg_temp.u('b2b2'));
insert into public.venta (id, espacio_persona_id, numero_talonario, monto_total, fecha, colportor_id, created_by) values
  (pg_temp.u('5151'), pg_temp.u('2121'), 'T-5151', 1000000, now(), pg_temp.u('b1b1'), pg_temp.u('b1b1')),
  (pg_temp.u('5252'), pg_temp.u('2222'), 'T-5252', 1000000, now(), pg_temp.u('b2b2'), pg_temp.u('b2b2'));
insert into public.cobranza (id, venta_id, monto, medio, fecha) values
  (pg_temp.c(1), pg_temp.u('5151'), 1000, 'EFECTIVO', now() - interval '3 hours'),
  (pg_temp.c(2), pg_temp.u('5151'), 2000, 'EFECTIVO', now() - interval '2 hours'),
  (pg_temp.c(3), pg_temp.u('5151'), 3000, 'EFECTIVO', now() - interval '1 hour'),
  (pg_temp.c(4), pg_temp.u('5252'), 4000, 'EFECTIVO', now() - interval '1 hour');
-- El 3 lo anuló Ana desde su teléfono, con su UPDATE.
select pg_temp.actuar_como(pg_temp.u('b1b1'));
update public.cobranza set anulado_at = now(), motivo_anulacion = 'Lo registré dos veces' where id = pg_temp.c(3);
select pg_temp.como_servidor();

-- ---------------------------------------------------------------------------
-- 1. Cada una baja los suyos
-- ---------------------------------------------------------------------------
create temp table pa as select pg_temp.pull_de('b1b1') as d;
select is(pg_temp.cobros((select d from pa)), '001,002,003/anulado:Lo registré dos veces:ana',
          'Ana baja sus tres cobros; el que anuló ella trae quién lo anuló: ella');
create temp table pb as select pg_temp.pull_de('b2b2') as d;
select is(pg_temp.cobros((select d from pb)), '004', 'Beatriz baja el suyo, no los de Ana');
create temp table pd as select pg_temp.pull_de('d1d1') as d;
select is(pg_temp.cobros((select d from pd)), '-', 'la coordinadora que anuló no baja los cobros de las personas que coordina');
create temp table pm as select pg_temp.pull_de('a1a1') as d;
select is(pg_temp.cobros((select d from pm)), '-', 'ni el administrador');

-- ---------------------------------------------------------------------------
-- 2. La anulación del coordinador baja en el delta, con quién la hizo
-- ---------------------------------------------------------------------------
select pg_temp.actuar_como(pg_temp.u('d1d1'));
select is((public.anular_cobro(pg_temp.c(1), 'Otro', 'Cobré de más a otra persona')) ->> 'ya_estaba', 'false',
          'Marta anula el cobro 1 de Ana con «Otro» y un detalle');
select is((public.anular_cobro(pg_temp.c(4), 'Monto equivocado')) ->> 'ya_estaba', 'false', 'y el 4 de Beatriz, con un motivo de la lista');
select pg_temp.como_servidor();

create temp table da as select pg_temp.pull_de('b1b1', (select d -> 'watermark' from pa)) as d;
select is(pg_temp.cobros((select d from da)), '001/anulado:Otro:marta',
          'el delta de Ana trae solo el cobro anulado, con el motivo de la lista y a Marta como quien lo anuló');
select ok((select (e ->> 'anulado_at') is not null and (e ->> 'deleted_at') is null from pg_temp.filas((select d from da)) e),
          'con la fecha de la anulación, sin darlo de baja');
select is(pg_temp.cobros((select pg_temp.pull_de('b2b2', (select d -> 'watermark' from pb)))), '004/anulado:Monto equivocado:marta',
          'el de Beatriz también (Marta coordina la campaña de las dos)');
-- Sin cambios: nada.
create temp table da2 as select pg_temp.pull_de('b1b1', (select d -> 'watermark' from da)) as d;
select is(pg_temp.cobros((select d from da2)), '-', 'un pull más, sin nada nuevo: la entidad no trae filas');

-- Un doble toque (el mismo anular_cobro) no vuelve a bajar nada.
select pg_temp.actuar_como(pg_temp.u('d1d1'));
select is((public.anular_cobro(pg_temp.c(1), 'Otro', 'Otro texto')) ->> 'ya_estaba', 'true', 'Marta toca de nuevo «Anular»: ya estaba');
select pg_temp.como_servidor();
create temp table da3 as select pg_temp.pull_de('b1b1', (select d -> 'watermark' from da)) as d;
select is(pg_temp.cobros((select d from da3)), '-', 'y no baja de nuevo (no subió la versión)');

-- Un reintento del push de Ana de la fila vieja del cobro anulado vuelve conflict: ella se entera por el pull.
select pg_temp.actuar_como(pg_temp.u('b1b1'));
select is((sync.push(jsonb_build_array(jsonb_build_object(
             'client_op_id', pg_temp.u('0f01'), 'entity', 'cobranza', 'op', 'update', 'sync_version', 0,
             'payload', jsonb_build_object('id', pg_temp.c(1), 'monto', 1000))))) -> 'results' -> 0 ->> 'outcome', 'conflict',
          'el push viejo de un cobro que anuló el coordinador vuelve conflict');
select pg_temp.como_servidor();

-- ---------------------------------------------------------------------------
-- 3. Lo que baja no lleva el detalle
-- ---------------------------------------------------------------------------
select is((select count(*)::int from pg_temp.filas((select d from da)) e, jsonb_object_keys(e) k where k like '%detalle%'), 0,
          'la fila del cobro no tiene ninguna clave de detalle');
select is((select count(*)::int from pa, da, da2, da3, pb, pd, pm
            where (pa.d::text || da.d::text || da2.d::text || da3.d::text || pb.d::text || pd.d::text || pm.d::text) like '%Cobré de más%'), 0,
          'y el texto de «Otro» no aparece en ninguna respuesta del pull');
select pg_temp.actuar_como(pg_temp.u('d1d1'));
select is((select count(*)::int from public.cobranza_anulacion_detalle d where d.cobranza_id = pg_temp.c(1)), 1,
          'el detalle sí está en el servidor y Marta lo lee');
select pg_temp.actuar_como(pg_temp.u('b1b1'));
select is((select count(*)::int from public.cobranza_anulacion_detalle d where d.cobranza_id = pg_temp.c(1)), 0, 'y Ana no');
select pg_temp.como_servidor();

select pg_temp.limpiar();
select * from finish();
