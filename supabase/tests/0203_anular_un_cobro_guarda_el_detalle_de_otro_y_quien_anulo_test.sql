-- pgTAP · migración 0203 (backend-supabase#306, seguimiento de front-coordinadores-web#81, decisiones de Cristian del 23/11
-- «Otro panel» y «Anul. al tel»): anular_cobro() recibe el detalle de «Otro», que queda en el servidor y lo lee solo la
-- coordinación; y el cobro anulado guarda quién lo anuló.
--   1. La forma: columna, tabla, RLS, privilegios; la firma vieja ya no existe; la tabla no está en el sync.
--   2. El detalle: obligatorio con «Otro», opcional con los demás motivos, hasta 200 caracteres, recortado; idempotente; una
--      anulación que falla (72 h) no deja detalle.
--   3. Quién lo lee: el coordinador de la campaña, el ADMIN y quien lo escribió; no otro coordinador, ni la colportora (ni la
--      dueña del cobro), ni un anónimo; nadie lo escribe con JWT.
--   4. `anulado_por`: lo fija el servidor con la persona de la sesión, no se cambia después ni lo manda el teléfono (push).
--   5. Lo que baja en la fila del cobro no lleva el detalle (el pull completo está en `0203_..._pull_test.sql`).
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
  select ('01920000-0000-7000-8000-0000000203' || p)::uuid;
$$;
-- El id de un cobro (n hasta 65535).
create or replace function pg_temp.uc(p_n integer) returns uuid language sql as $$
  select ('01920000-0000-7000-8000-00000203' || lpad(to_hex(p_n), 4, '0'))::uuid;
$$;
create or replace function pg_temp.error_de(p_sql text) returns text language plpgsql as $$
begin
  execute p_sql;
  return 'ok';
exception when others then
  return sqlstate;
end $$;
create or replace function pg_temp.mensaje_de(p_sql text) returns text language plpgsql as $$
begin
  execute p_sql;
  return 'ok';
exception when others then
  return sqlstate || ': ' || sqlerrm;
end $$;
-- Cuántos detalles de los cobros de este archivo ve quien está actuando.
create or replace function pg_temp.detalles_que_ve() returns integer language sql as $$
  select count(*)::int from public.cobranza_anulacion_detalle d where d.cobranza_id between pg_temp.uc(1) and pg_temp.uc(99);
$$;
create or replace function pg_temp.detalle_de(p_n integer) returns text language sql as $$
  select d.detalle from public.cobranza_anulacion_detalle d where d.cobranza_id = pg_temp.uc(p_n);
$$;
create or replace function pg_temp.anulado_por(p_n integer) returns uuid language sql as $$
  select anulado_por from public.cobranza where id = pg_temp.uc(p_n);
$$;
create or replace function pg_temp.sobre() returns jsonb language sql as $$
  select jsonb_build_object('device_id', '01920000-0000-7000-8000-0000000203d0',
                            'app_version', '1.4.2', 'schema_version', 1);
$$;
create or replace function pg_temp.push(p_jobs jsonb) returns jsonb language sql as $$
  select public.sync_push(jsonb_build_object('device', pg_temp.sobre(), 'jobs', p_jobs));
$$;

-- --- fixtures (como postgres) --------------------------------------------------
-- b1 (Ana, venta 51) y b2 (venta 52) colportoras; d1 coordina c1 (Ana inscripta), d2 coordina c2 (b2 inscripta); a1 ADMIN.
insert into auth.users (id, instance_id, aud, role, email, encrypted_password, confirmed_at, created_at, updated_at)
select pg_temp.u(s), '00000000-0000-0000-0000-000000000000',
       'authenticated', 'authenticated', 'cobro203-' || s || '@example.com', 'x', now(), now(), now()
  from unnest(array['b1','b2','d1','d2','a1']) s;
insert into public.usuario_rol (usuario_id, rol_id)
select pg_temp.u(x.s), r.id
  from (values ('d1', 'COORDINADOR'), ('d2', 'COORDINADOR'), ('a1', 'ADMIN'),
               ('b1', 'COLPORTOR'), ('b2', 'COLPORTOR')) x(s, codigo)
  join public.rol r on r.codigo = x.codigo;
insert into public.pais (id, nombre, iso_code) values (pg_temp.u('c0'), 'Pais cobro 203', 'ZD');
insert into public.ciudad (id, nombre, departamento, pais_id, lat_centro, lon_centro)
values (pg_temp.u('c1'), 'Ciudad cobro 203', 'Departamento de prueba', pg_temp.u('c0'), -34.9, -56.2);
insert into public.campania (id, nombre, tipo, fecha_inicio, fecha_fin, coordinador_id) values
  (pg_temp.u('e1'), 'Verano cobro 203', 'VERANO', public.hoy_montevideo() - 10, public.hoy_montevideo() + 30, pg_temp.u('d1')),
  (pg_temp.u('e2'), 'Invierno cobro 203', 'INVIERNO', public.hoy_montevideo() - 10, public.hoy_montevideo() + 30, pg_temp.u('d2'));
insert into public.campania_colportor (campania_id, usuario_id, zona_id, deleted_at) values
  (pg_temp.u('e1'), pg_temp.u('b1'), null, null),
  (pg_temp.u('e2'), pg_temp.u('b2'), null, null);
insert into public.ubicacion (id, tipo, calle, numero, lat, lon, ciudad_id, created_by) values
  (pg_temp.u('01'), 'CASA', 'Cobro 01', '1', -34.91, -56.2, pg_temp.u('c1'), pg_temp.u('b1')),
  (pg_temp.u('02'), 'CASA', 'Cobro 02', '2', -34.92, -56.2, pg_temp.u('c1'), pg_temp.u('b2'));
insert into public.espacio (id, ubicacion_id, numero_depto, created_by) values
  (pg_temp.u('11'), pg_temp.u('01'), null, pg_temp.u('b1')),
  (pg_temp.u('12'), pg_temp.u('02'), null, pg_temp.u('b2'));
insert into public.espacio_persona (id, espacio_id, persona_id, created_by) values
  (pg_temp.u('21'), pg_temp.u('11'), pg_temp.u('a2'), pg_temp.u('b1')),
  (pg_temp.u('22'), pg_temp.u('12'), pg_temp.u('a3'), pg_temp.u('b2'));
insert into public.venta (id, espacio_persona_id, numero_talonario, monto_total, fecha, colportor_id, created_by)
select pg_temp.u(x.v), pg_temp.u(x.ep), 'T-' || x.v, 1000000, now(), pg_temp.u(x.quien), pg_temp.u(x.quien)
  from (values ('51', '21', 'b1'), ('52', '22', 'b2')) x(v, ep, quien);
-- Los cobros (los inserta el servidor: sin sesión nada se controla). Los de la venta 51 son de Ana.
create or replace function pg_temp.fx(p_n integer, p_fecha timestamptz, p_venta text default '51') returns void
language sql as $$
  insert into public.cobranza (id, venta_id, monto, medio, fecha)
  values (pg_temp.uc(p_n), pg_temp.u(p_venta), 1000, 'EFECTIVO', p_fecha);
$$;
select pg_temp.fx(1, now() - interval '1 hour');
select pg_temp.fx(2, now() - interval '1 hour');
select pg_temp.fx(3, now() - interval '1 hour');
select pg_temp.fx(4, now() - interval '1 hour');
select pg_temp.fx(5, now() - interval '73 hours');
select pg_temp.fx(6, now() - interval '1 hour');
select pg_temp.fx(7, now() - interval '1 hour');
select pg_temp.fx(8, now() - interval '1 hour');
select pg_temp.fx(9, now() - interval '1 hour', '52');
select pg_temp.fx(10, now() - interval '1 hour', '52');
select pg_temp.fx(11, now() - interval '1 hour');
-- Uno que anuló el servidor sin sesión antes de la 0203 (no se sabe quién): anulado_por null.
update public.cobranza set anulado_at = now() - interval '30 minutes', motivo_anulacion = 'Monto equivocado'
 where id = pg_temp.uc(11);

-- ---------------------------------------------------------------------------
-- 1. La forma
-- ---------------------------------------------------------------------------
select has_column('public', 'cobranza', 'anulado_por', 'cobranza tiene anulado_por');
select col_type_is('public', 'cobranza', 'anulado_por', 'uuid', 'anulado_por es un uuid');
select col_is_null('public', 'cobranza', 'anulado_por', 'y es opcional');
select hasnt_function('public', 'anular_cobro', array['uuid', 'text'], 'la firma de dos argumentos ya no existe');
select has_function('public', 'anular_cobro', array['uuid', 'text', 'text'], 'anular_cobro recibe el detalle');
select ok(has_function_privilege('authenticated', 'public.anular_cobro(uuid, text, text)', 'execute')
          and not has_function_privilege('anon', 'public.anular_cobro(uuid, text, text)', 'execute')
          and not has_function_privilege('service_role', 'public.anular_cobro(uuid, text, text)', 'execute'),
          'anular_cobro() la ejecuta authenticated y nadie más');
select ok((select prosecdef from pg_proc where oid = 'public.anular_cobro(uuid, text, text)'::regprocedure)
          and (select proconfig::text from pg_proc where oid = 'public.anular_cobro(uuid, text, text)'::regprocedure) like '%search_path=%',
          'sigue siendo SECURITY DEFINER con search_path fijo');
select ok((select relrowsecurity from pg_class where oid = 'public.cobranza_anulacion_detalle'::regclass),
          'la tabla del detalle tiene RLS');
select is((select count(*)::int from pg_policy where polrelid = 'public.cobranza_anulacion_detalle'::regclass), 1,
          'con una sola política (la de lectura)');
select ok(has_table_privilege('authenticated', 'public.cobranza_anulacion_detalle', 'select')
          and not has_table_privilege('authenticated', 'public.cobranza_anulacion_detalle', 'insert')
          and not has_table_privilege('authenticated', 'public.cobranza_anulacion_detalle', 'update')
          and not has_table_privilege('authenticated', 'public.cobranza_anulacion_detalle', 'delete')
          and not has_table_privilege('anon', 'public.cobranza_anulacion_detalle', 'select'),
          'authenticated solo lee el detalle; anon ni eso');
select is((select count(*)::int from sync.entidad where nombre = 'cobranza_anulacion_detalle' or tabla = 'public.cobranza_anulacion_detalle'::regclass),
          0, 'la tabla del detalle no está en el sync: no baja al teléfono');
select ok((select 'anulado_por' = any (columnas_servidor) from sync.entidad where nombre = 'cobranza'),
          'anulado_por lo fija el servidor: el teléfono no lo manda');
select ok(not ('anulado_por' = any (sync.columnas_escribibles('cobranza'))), 'y no figura entre las columnas que el push escribe');
select ok(sync.expresion_json('public.cobranza'::regclass) like '%anulado_por%', 'pero sí baja en la fila del cobro');

-- ---------------------------------------------------------------------------
-- 2. El detalle
-- ---------------------------------------------------------------------------
select pg_temp.actuar_como(pg_temp.u('d1'));
select is((public.anular_cobro(pg_temp.uc(1), 'Otro', '  Cobré de más a otra persona  ')) ->> 'ya_estaba', 'false',
          'con «Otro» y un detalle, el coordinador anula');
select is(pg_temp.detalle_de(1), 'Cobré de más a otra persona', 'el detalle queda recortado');

select is(pg_temp.error_de($$ select public.anular_cobro(pg_temp.uc(2), 'Otro') $$), '22023', 'con «Otro» y sin detalle, 22023');
select is(pg_temp.error_de($$ select public.anular_cobro(pg_temp.uc(2), 'Otro', null) $$), '22023', 'con el detalle null, 22023');
select is(pg_temp.error_de($$ select public.anular_cobro(pg_temp.uc(2), 'Otro', '') $$), '22023', 'con el detalle vacío, 22023');
select is(pg_temp.error_de($$ select public.anular_cobro(pg_temp.uc(2), 'Otro', E'  \n\t ') $$), '22023',
          'con el detalle en blanco (espacios y saltos de línea), 22023');
select is(pg_temp.mensaje_de($$ select public.anular_cobro(pg_temp.uc(2), 'Otro') $$),
          '22023: Con «Otro», contá qué pasó: escribí el detalle del motivo (hasta 200 caracteres). No pongas datos del cliente.',
          'y el mensaje le dice qué hacer');
select is(pg_temp.error_de(format($$ select public.anular_cobro(pg_temp.uc(2), 'Otro', %L) $$, repeat('a', 201))), '22023',
          'con 201 caracteres, 22023');
select is(pg_temp.mensaje_de(format($$ select public.anular_cobro(pg_temp.uc(2), 'Otro', %L) $$, repeat('a', 201))),
          '22023: El detalle del motivo tiene 201 caracteres y el máximo es 200. Acortalo.', 'y el mensaje dice cuántos tiene');
select is(pg_temp.error_de(format($$ select public.anular_cobro(pg_temp.uc(2), 'Otro', %L) $$, repeat(' ', 5) || repeat('a', 201))),
          '22023', 'los espacios de los extremos no cuentan, pero los 201 caracteres sí');
select pg_temp.actuar_como_servidor();
select is((select anulado_at is null from public.cobranza where id = pg_temp.uc(2)), true, 'ninguno de esos intentos anuló el cobro');
select is((select count(*)::int from public.cobranza_anulacion_detalle where cobranza_id = pg_temp.uc(2)), 0, 'ni dejó un detalle');

select pg_temp.actuar_como(pg_temp.u('d1'));
select is(pg_temp.error_de(format($$ select public.anular_cobro(pg_temp.uc(2), 'Otro', %L) $$, repeat('á', 200))), 'ok',
          'con 200 caracteres justos (con tildes: se cuentan caracteres, no bytes), anula');
select is(char_length(pg_temp.detalle_de(2)), 200, 'y quedan los 200');
select is((public.anular_cobro(pg_temp.uc(3), 'Monto equivocado')) ->> 'ya_estaba', 'false', 'con otro motivo, el detalle es opcional');
select is((select count(*)::int from public.cobranza_anulacion_detalle where cobranza_id = pg_temp.uc(3)), 0, 'y sin él no queda ninguna fila');
select is((public.anular_cobro(pg_temp.uc(4), 'Monto equivocado', 'El monto era 5000')) ->> 'ya_estaba', 'false',
          'con otro motivo, el detalle también se acepta');
select is(pg_temp.detalle_de(4), 'El monto era 5000', 'y se guarda');
select is((public.anular_cobro(pg_temp.uc(6), 'Cliente equivocado', '   ')) ->> 'ya_estaba', 'false',
          'con otro motivo y el detalle en blanco, anula igual');
select is((select count(*)::int from public.cobranza_anulacion_detalle where cobranza_id = pg_temp.uc(6)), 0, 'y el blanco no se guarda');

-- Pasadas las 72 h, nada: ni anulación ni detalle.
select is(pg_temp.error_de($$ select public.anular_cobro(pg_temp.uc(5), 'Otro', 'Cobré de más a otra persona') $$), 'CB001',
          'pasadas las 72 h, CB001');
select pg_temp.actuar_como_servidor();
select is((select anulado_at is null from public.cobranza where id = pg_temp.uc(5)), true, 'el cobro sigue vivo');
select is((select count(*)::int from public.cobranza_anulacion_detalle where cobranza_id = pg_temp.uc(5)), 0,
          'y no quedó ningún detalle de una anulación que no se hizo');

-- Idempotencia: un doble toque no pisa el detalle ni sube la versión.
create temp table v1 as select sync_version from public.cobranza where id = pg_temp.uc(1);
select pg_temp.actuar_como(pg_temp.u('d1'));
select is((public.anular_cobro(pg_temp.uc(1), 'Otro', 'Otro texto distinto')) ->> 'ya_estaba', 'true', 'anular de nuevo devuelve ya_estaba');
select is(pg_temp.detalle_de(1), 'Cobré de más a otra persona', 'y no pisa el detalle');
select pg_temp.actuar_como_servidor();
select is((select sync_version from public.cobranza where id = pg_temp.uc(1)), (select sync_version from v1), 'ni sube la versión de sync');
select is((select sync_version > 0 from v1), true, 'la anulación sí la había subido (el delta la lleva al teléfono)');

-- Los permisos de siempre siguen (el detalle no los abre).
select pg_temp.actuar_como(pg_temp.u('d2'));
select is(pg_temp.error_de($$ select public.anular_cobro(pg_temp.uc(7), 'Otro', 'Cobré de más a otra persona') $$), 'CB004',
          'el coordinador de otra campaña no ve el cobro: CB004');
select pg_temp.actuar_como(pg_temp.u('b1'));
select is(pg_temp.error_de($$ select public.anular_cobro(pg_temp.uc(7), 'Otro', 'Cobré de más a otra persona') $$), '42501',
          'una colportora no usa la RPC del coordinador: 42501');
select pg_temp.actuar_como_servidor();
select is((select count(*)::int from public.cobranza_anulacion_detalle where cobranza_id = pg_temp.uc(7)), 0, 'y no deja detalle');

-- ---------------------------------------------------------------------------
-- 3. Quién lo lee
-- ---------------------------------------------------------------------------
-- Los de Ana (cobros 1, 2 y 4) los anuló d1: tres detalles.
select pg_temp.actuar_como(pg_temp.u('d1'));
select is(pg_temp.detalles_que_ve(), 3, 'el coordinador de la campaña lee los detalles de sus colportoras');
select is(pg_temp.detalle_de(1), 'Cobré de más a otra persona', 'con el texto tal cual');
select pg_temp.actuar_como(pg_temp.u('a1'));
select is(pg_temp.detalles_que_ve(), 3, 'el ADMIN lee todos');
select pg_temp.actuar_como(pg_temp.u('d2'));
select is(pg_temp.detalles_que_ve(), 0, 'el coordinador de otra campaña no lee ninguno');
select pg_temp.actuar_como(pg_temp.u('b1'));
select is(pg_temp.detalles_que_ve(), 0, 'la dueña de los cobros (Ana) no lee ninguno');
select is(pg_temp.detalle_de(1), null, 'ni el de su cobro anulado');
select pg_temp.actuar_como(pg_temp.u('b2'));
select is(pg_temp.detalles_que_ve(), 0, 'ni otra colportora');
select pg_temp.actuar_como_servidor();
select set_config('role', 'anon', true);
select is(pg_temp.error_de($$ select count(*) from public.cobranza_anulacion_detalle $$), '42501', 'un anónimo no lee la tabla: 42501');
select pg_temp.actuar_como(pg_temp.u('d1'));
select is(pg_temp.error_de($$ insert into public.cobranza_anulacion_detalle (cobranza_id, detalle) values (pg_temp.uc(8), 'x') $$), '42501',
          'nadie con JWT inserta un detalle por fuera de la RPC');
select is(pg_temp.error_de($$ update public.cobranza_anulacion_detalle set detalle = 'otro' $$), '42501', 'ni lo cambia');
select is(pg_temp.error_de($$ delete from public.cobranza_anulacion_detalle $$), '42501', 'ni lo borra');
select pg_temp.actuar_como_servidor();
select is(pg_temp.detalle_de(1), 'Cobré de más a otra persona', 'y los detalles siguen como estaban');

-- Quien lo escribió lo sigue leyendo aunque la colportora ya no esté en su campaña.
select pg_temp.actuar_como(pg_temp.u('d2'));
select is((public.anular_cobro(pg_temp.uc(9), 'Otro', 'Era de otra venta')) ->> 'ya_estaba', 'false', 'd2 anula un cobro de b2 con un detalle');
select pg_temp.actuar_como_servidor();
update public.campania_colportor set deleted_at = now() where campania_id = pg_temp.u('e2') and usuario_id = pg_temp.u('b2');
select pg_temp.actuar_como(pg_temp.u('d2'));
select is(pg_temp.detalle_de(9), 'Era de otra venta', 'b2 se dio de baja de la campaña y d2, que lo escribió, igual lo lee');
select pg_temp.actuar_como(pg_temp.u('d1'));
select is(pg_temp.detalle_de(9), null, 'pero no el coordinador de otra campaña');

-- ---------------------------------------------------------------------------
-- 4. anulado_por
-- ---------------------------------------------------------------------------
select pg_temp.actuar_como_servidor();
select is(pg_temp.anulado_por(1), pg_temp.u('d1'), 'anular_cobro deja al coordinador como quien anuló');
select is(pg_temp.anulado_por(3), pg_temp.u('d1'), 'también sin detalle');
select pg_temp.actuar_como(pg_temp.u('a1'));
select is((public.anular_cobro(pg_temp.uc(10), 'Cliente equivocado')) ->> 'ya_estaba', 'false', 'un ADMIN anula el cobro de b2');
select pg_temp.actuar_como_servidor();
select is(pg_temp.anulado_por(10), pg_temp.u('a1'), 'y queda él como quien anuló');
select is(pg_temp.anulado_por(11), null, 'lo anulado por el servidor antes de la 0203 queda sin anulador (no se inventa)');
select is(pg_temp.anulado_por(7), null, 'un cobro vivo no tiene anulador');

-- La colportora anula desde su teléfono: anulado_por es ella, aunque mande otro.
select pg_temp.actuar_como(pg_temp.u('b1'));
select is(pg_temp.error_de($$ update public.cobranza set anulado_at = now(), motivo_anulacion = 'Otro', anulado_por = pg_temp.u('d1')
                              where id = pg_temp.uc(7) $$), 'ok', 'la colportora anula su cobro (UPDATE) y manda a d1 como anulador');
select pg_temp.actuar_como_servidor();
select is(pg_temp.anulado_por(7), pg_temp.u('b1'), 'anulado_por es ella, no lo que mandó');
select pg_temp.actuar_como(pg_temp.u('b1'));
select is(pg_temp.error_de($$ update public.cobranza set anulado_por = pg_temp.u('d2') where id = pg_temp.uc(7) $$), 'ok',
          'cambiar solo el anulador de un cobro anulado no falla (es lo mismo)');
select pg_temp.actuar_como_servidor();
select is(pg_temp.anulado_por(7), pg_temp.u('b1'), 'pero no lo cambia');
select pg_temp.actuar_como(pg_temp.u('b1'));
select is(pg_temp.error_de($$ update public.cobranza set anulado_por = pg_temp.u('d1') where id = pg_temp.uc(8) $$), 'ok',
          'poner un anulador en un cobro vivo no falla');
select pg_temp.actuar_como_servidor();
select is(pg_temp.anulado_por(8), null, 'y queda sin anulador (sin anulación no hay quién la hizo)');
-- Un cobro que nace anulado en el teléfono.
select pg_temp.actuar_como(pg_temp.u('b1'));
select is(pg_temp.error_de($$ insert into public.cobranza (id, venta_id, monto, medio, fecha, anulado_at, motivo_anulacion, anulado_por)
                              values (pg_temp.uc(12), pg_temp.u('51'), 1000, 'EFECTIVO', now() - interval '2 hours', now() - interval '1 hour',
                                      'Monto equivocado', pg_temp.u('d1')) $$), 'ok', 'un cobro que nace anulado entra');
select pg_temp.actuar_como_servidor();
select is(pg_temp.anulado_por(12), pg_temp.u('b1'), 'con la colportora como quien anuló');
-- Sin sesión (el servidor corrigiendo a mano) queda lo que se escriba.
update public.cobranza set anulado_por = pg_temp.u('d2') where id = pg_temp.uc(11);
select is(pg_temp.anulado_por(11), pg_temp.u('d2'), 'sin sesión, el servidor puede escribir el anulador a mano');
-- Un cobro sin anulación no puede nombrar a nadie, ni a mano.
select is(pg_temp.error_de($$ update public.cobranza set anulado_por = pg_temp.u('d2') where id = pg_temp.uc(6) $$), 'ok',
          'sin sesión, ponerle anulador a uno anulado no falla');
select is(pg_temp.error_de($$ update public.cobranza set anulado_at = null, motivo_anulacion = null where id = pg_temp.uc(11) $$), 'ok',
          'el servidor sin sesión puede reabrir uno a mano (CB003 es solo con sesión)');
select is(pg_temp.anulado_por(11), null, 'y entonces el anulador se va con la anulación');

-- Por sync_push: el teléfono manda anulado_por y el servidor lo descarta.
select pg_temp.actuar_como(pg_temp.u('b1'));
create temp table lote as
  select pg_temp.push(jsonb_build_array(jsonb_build_object(
    'client_op_id', pg_temp.u('f1'), 'entity', 'cobranza', 'op', 'update',
    'sync_version', (select c.sync_version from public.cobranza c where c.id = pg_temp.uc(8)),
    'payload', jsonb_build_object('id', pg_temp.uc(8), 'anulado_at', now(), 'motivo_anulacion', 'Monto equivocado',
                                  'anulado_por', pg_temp.u('d1'))))) as r;
grant select on lote to authenticated;
select is((select e ->> 'outcome' from lote, jsonb_array_elements(r -> 'results') e limit 1), 'accepted', 'el push de la anulación entra');
select pg_temp.actuar_como_servidor();
select is(pg_temp.anulado_por(8), pg_temp.u('b1'), 'y anulado_por es la colportora de la sesión, no el que mandó el teléfono');

-- ---------------------------------------------------------------------------
-- 5. La fila que baja no lleva el detalle
-- ---------------------------------------------------------------------------
select is((select count(*)::int from jsonb_object_keys(to_jsonb((select c from public.cobranza c where c.id = pg_temp.uc(1)))) k
            where k like '%detalle%'), 0, 'la fila del cobro no tiene ninguna clave de detalle');
select ok(sync.expresion_json('public.cobranza'::regclass) not like '%detalle%', 'ni la expresión del pull la nombra');
select ok(sync.expresion_json('public.cobranza'::regclass) like '%motivo_anulacion%'
          and sync.expresion_json('public.cobranza'::regclass) like '%anulado_at%',
          'el pull sí lleva la fecha y el motivo de la lista');

select * from finish();
rollback;
