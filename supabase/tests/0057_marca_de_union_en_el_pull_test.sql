-- pgTAP · migración 0051 (backend-supabase#107; decisión de Cristian del 21/10, «Marca unión»):
-- la unión baja al teléfono con la ubicación y el servidor rechaza reactivar una casa unida.
--   1. El pull de `ubicacion` trae `unida_a_id` en cada fila: null si no se unió, el id de la ubicación a
--      la que se unió si sí; llega por delta cuando se une (también si B ya estaba de baja y se registra
--      sin tocarla), en un primer pull (un teléfono nuevo) y en el `server_row` de un conflicto; no es una
--      columna ni sale en otras entidades; la cadena (A se une a C después) no cambia la marca de B.
--   2. Reactivar una B unida (por push, por UPDATE directo, con o sin usuario) da `UB005` con su texto; el
--      push la devuelve `invalid` sin tumbar el lote y sin dejar nada a medias; una baja común se sigue
--      reactivando, una y otra vez; editar una B unida sin reactivarla no se rechaza.
--   3. Permisos: ubicacion_unida_a para authenticated y service_role pero no para anon; ubicacion_union
--      sigue sin leerla un colportor; quien no ve la ubicación no recibe la marca.
--
-- Como 0004, 0011, 0014, 0017, 0019 y 0039, NO va en una transacción: el delta solo sirve lo commiteado.
-- Limpia al empezar y al terminar.

select * from no_plan();

-- --- helpers -------------------------------------------------------------------
create or replace function pg_temp.actuar_como(p_uid uuid) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', json_build_object('sub', p_uid, 'role', 'authenticated')::text, false);
  perform set_config('request.jwt.claim.sub', p_uid::text, false);
  perform set_config('request.jwt.claim.role', 'authenticated', false);
  perform set_config('role', 'authenticated', false);
end $$;
create or replace function pg_temp.actuar_como_servidor() returns void language plpgsql as $$
begin
  perform set_config('role', 'postgres', false);
  perform set_config('request.jwt.claims', '', false);
  perform set_config('request.jwt.claim.sub', '', false);
  perform set_config('request.jwt.claim.role', '', false);
end $$;
create or replace function pg_temp.actuar_como_anon() returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', json_build_object('role', 'anon')::text, false);
  perform set_config('request.jwt.claim.sub', '', false);
  perform set_config('request.jwt.claim.role', 'anon', false);
  perform set_config('role', 'anon', false);
end $$;
create or replace function pg_temp.u(p text) returns uuid language sql as $$
  select ('01920000-0000-7000-8000-0000000057' || p)::uuid;
$$;
-- «sqlstate», u «ok», de lo que hace una sentencia.
create or replace function pg_temp.err(p_sql text) returns text language plpgsql as $$
begin
  execute p_sql;
  return 'ok';
exception when others then
  return sqlstate;
end $$;
create or replace function pg_temp.version(p_id uuid) returns bigint language sql as $$
  select sync_version from public.ubicacion where id = p_id;
$$;
-- Los sufijos de los ids de `ubicacion` en `rows`, ordenados.
create or replace function pg_temp.filas(p_delta jsonb) returns text[] language sql as $$
  select coalesce(array_agg(right(e ->> 'id', 2) order by e ->> 'id'), array[]::text[])
    from jsonb_array_elements(coalesce(p_delta -> 'rows' -> 'ubicacion', '[]'::jsonb)) e;
$$;
-- La fila de la ubicación `p_sufijo` en `rows`.
create or replace function pg_temp.fila(p_delta jsonb, p_sufijo text) returns jsonb language sql as $$
  select e from jsonb_array_elements(coalesce(p_delta -> 'rows' -> 'ubicacion', '[]'::jsonb)) e
   where right(e ->> 'id', 2) = p_sufijo;
$$;
-- Hacia dónde se unió, en el sufijo del id (null si la clave es null; 'falta' si la fila no la trae).
create or replace function pg_temp.marca(p_delta jsonb, p_sufijo text) returns text language sql as $$
  select case when not (f ? 'unida_a_id') then 'falta'
              when f -> 'unida_a_id' = 'null'::jsonb then null
              else right(f ->> 'unida_a_id', 2) end
    from (select pg_temp.fila(p_delta, p_sufijo) f) x;
$$;
-- Un trabajo de push con su client_op_id propio (se borra al limpiar).
create or replace function pg_temp.job(p_op text, p_op_n text, p_payload jsonb, p_version bigint default null)
returns jsonb language sql as $$
  select jsonb_build_object('client_op_id', pg_temp.u(p_op_n), 'entity', 'ubicacion', 'op', p_op,
                            'payload', p_payload, 'sync_version', p_version);
$$;
create or replace function pg_temp.resultados(p_r jsonb) returns text[] language sql as $$
  select array_agg((e ->> 'outcome') || coalesce(' ' || (e ->> 'code'), '') order by i)
    from jsonb_array_elements(p_r -> 'results') with ordinality x(e, i);
$$;

create or replace function pg_temp.limpiar() returns void language plpgsql as $$
begin
  perform set_config('role', 'postgres', false);
  perform set_config('request.jwt.claims', '', false);
  delete from sync.op_cache where client_op_id::text like '01920000-0000-7000-8000-0000000057%';
  delete from public.ubicacion_union where duplicada_id::text like '01920000-0000-7000-8000-0000000057%';
  delete from public.ubicacion where id::text like '01920000-0000-7000-8000-0000000057%';
  delete from public.campania_colportor where campania_id::text like '01920000-0000-7000-8000-0000000057%';
  delete from public.campania_ciudad where id::text like '01920000-0000-7000-8000-0000000057%';
  delete from public.campania where id::text like '01920000-0000-7000-8000-0000000057%';
  delete from public.ciudad where id::text like '01920000-0000-7000-8000-0000000057%';
  delete from public.pais where id::text like '01920000-0000-7000-8000-0000000057%';
  delete from auth.users where id::text like '01920000-0000-7000-8000-0000000057%';
end $$;

select pg_temp.limpiar();

-- --- fixtures (como postgres) --------------------------------------------------
-- Usuarios: b1 y b2 inscriptos en la campaña de f1; b3 en la de f2 (otra ciudad).
-- Ubicaciones de f1 (cada una a más de 100 m de las otras), todas de b1:
--   01 A, 02 B (viva, se une a A), 03 C (a la que se une A después), 04 E (de baja común, se une a A:
--   «B ya estaba de baja»), 05 R (de baja común, se reactiva), 06 X (viva, control), 07 Y (viva,
--   se une a X dentro de un lote).
insert into auth.users (id, instance_id, aud, role, email, encrypted_password, confirmed_at, created_at, updated_at)
select pg_temp.u(s), '00000000-0000-0000-0000-000000000000',
       'authenticated', 'authenticated', 'marca57-' || s || '@example.com', 'x', now(), now(), now()
  from unnest(array['b1','b2','b3']) s;
insert into public.pais (id, nombre, iso_code) values (pg_temp.u('f0'), 'Pais marca57', 'ZM');
insert into public.ciudad (id, nombre, departamento, pais_id, lat_centro, lon_centro) values
  (pg_temp.u('f1'), 'Ciudad f1 marca57', 'Departamento de prueba', pg_temp.u('f0'), -34.9, -56.2),
  (pg_temp.u('f2'), 'Ciudad f2 marca57', 'Departamento de prueba', pg_temp.u('f0'), -31.4, -57.9);
insert into public.campania (id, nombre, tipo, fecha_inicio, fecha_fin) values
  (pg_temp.u('f3'), 'Verano marca57', 'VERANO', public.hoy_montevideo() - 10, public.hoy_montevideo() + 30),
  (pg_temp.u('f4'), 'Otoño marca57',  'VERANO', public.hoy_montevideo() - 10, public.hoy_montevideo() + 30);
insert into public.campania_ciudad (id, campania_id, ciudad_id) values
  (pg_temp.u('f5'), pg_temp.u('f3'), pg_temp.u('f1')),
  (pg_temp.u('f6'), pg_temp.u('f4'), pg_temp.u('f2'));
insert into public.campania_colportor (campania_id, usuario_id, zona_id) values
  (pg_temp.u('f3'), pg_temp.u('b1'), null),
  (pg_temp.u('f3'), pg_temp.u('b2'), null),
  (pg_temp.u('f4'), pg_temp.u('b3'), null);
insert into public.ubicacion (id, tipo, calle, numero, lat, lon, ciudad_id, created_by, deleted_at)
select pg_temp.u(x.u), 'CASA', 'Marca ' || x.u, x.u, -34.9 - x.n * 0.01, -56.2, pg_temp.u('f1'), pg_temp.u('b1'),
       case when x.baja then now() - interval '2 days' end
  from (values ('01', 1, false), ('02', 2, false), ('03', 3, false), ('04', 4, true),
               ('05', 5, true), ('06', 6, false), ('07', 7, false)) x(u, n, baja);

-- ---------------------------------------------------------------------------
-- 1. Antes de toda unión: la clave viaja, en null
-- ---------------------------------------------------------------------------
select pg_temp.actuar_como(pg_temp.u('b1'));
create temp table p1 as select sync.pull(array['ubicacion'], '{}'::jsonb, 1000) as d;
select is(pg_temp.filas(d), array['01','02','03','04','05','06','07'], 'b1 baja sus 7 ubicaciones') from p1;
select is((select count(*)::int from p1, jsonb_array_elements(d -> 'rows' -> 'ubicacion') e
            where e ? 'unida_a_id' and e -> 'unida_a_id' = 'null'::jsonb), 7,
          'y todas traen unida_a_id, en null: ninguna se unió') from p1;

-- Otra ciudad: no ve nada, ni la marca.
select pg_temp.actuar_como(pg_temp.u('b3'));
select is(pg_temp.filas(sync.pull(array['ubicacion'], '{}'::jsonb, 1000)), array[]::text[],
          'b3, de otra ciudad, no baja ninguna ubicación de f1');
select pg_temp.actuar_como_servidor();

-- ---------------------------------------------------------------------------
-- 2. b1 une la 02 (B) a la 01 (A): la marca baja por delta
-- ---------------------------------------------------------------------------
create temp table v2 as select pg_temp.version(pg_temp.u('02')) as antes;
select pg_temp.actuar_como(pg_temp.u('b1'));
select is((select public.marcar_como_duplicado(pg_temp.u('02'), pg_temp.u('01')) ->> 'ya_unida'), 'false',
          'b1 une la 02 a la 01');
select pg_temp.actuar_como_servidor();
select is(pg_temp.version(pg_temp.u('02')), (select antes + 1 from v2),
          'la baja de B sube su versión una vez: registrar la unión no la toca de nuevo si ya se tocó en la operación');

select pg_temp.actuar_como(pg_temp.u('b1'));
create temp table p2 as select sync.pull(array['ubicacion'], (select d -> 'watermark' from p1), 1000) as d;
select is(pg_temp.filas(d), array['02'], 'el delta de b1 trae solo la 02') from p2;
select is(pg_temp.marca(d, '02'), '01', 'con unida_a_id = la 01') from p2;
select ok((select (pg_temp.fila(d, '02') ->> 'deleted_at') is not null from p2), 'y dada de baja');

-- Un teléfono nuevo (otro colportor, primer pull): la marca viene en la fila completa.
select pg_temp.actuar_como(pg_temp.u('b2'));
create temp table q1 as select sync.pull(array['ubicacion'], '{}'::jsonb, 1000) as d;
select is(pg_temp.marca(d, '02'), '01', 'b2, con un primer pull, recibe la 02 con su marca') from q1;
select is((select count(*)::int from q1, jsonb_array_elements(d -> 'rows' -> 'ubicacion') e
            where e -> 'unida_a_id' <> 'null'::jsonb), 1, 'y es la única con marca') from q1;

-- Sin cambios, el pull siguiente no baja nada.
select pg_temp.actuar_como(pg_temp.u('b1'));
select is(pg_temp.filas(sync.pull(array['ubicacion'], (select d -> 'watermark' from p2), 1000)), array[]::text[],
          'sin novedades, el pull siguiente no baja ubicaciones');

-- ---------------------------------------------------------------------------
-- 3. B ya estaba de baja (común) y se une después: se registra sin tocarla, y la marca baja igual
-- ---------------------------------------------------------------------------
select pg_temp.actuar_como_servidor();
update v2 set antes = pg_temp.version(pg_temp.u('04'));
select pg_temp.actuar_como(pg_temp.u('b1'));
select is((select public.marcar_como_duplicado(pg_temp.u('04'), pg_temp.u('01')) ->> 'ya_unida'), 'true',
          'b1 une la 04, que ya estaba de baja, a la 01: se registra (ya_unida)');
select pg_temp.actuar_como_servidor();
select is(pg_temp.version(pg_temp.u('04')), (select antes + 1 from v2),
          'registrarla toca a la 04: sube su versión una vez, para que baje por delta');
select pg_temp.actuar_como(pg_temp.u('b1'));
create temp table p3 as select sync.pull(array['ubicacion'], (select d -> 'watermark' from p2), 1000) as d;
select is(pg_temp.filas(d), array['04'], 'el delta trae solo la 04') from p3;
select is(pg_temp.marca(d, '04'), '01', 'con unida_a_id = la 01') from p3;

-- ---------------------------------------------------------------------------
-- 4. La cadena: la 01 se une después a la 03; las marcas de 02 y 04 no cambian
-- ---------------------------------------------------------------------------
select is((select public.marcar_como_duplicado(pg_temp.u('01'), pg_temp.u('03')) ->> 'ya_unida'), 'false',
          'b1 une la 01 a la 03');
create temp table p4 as select sync.pull(array['ubicacion'], (select d -> 'watermark' from p3), 1000) as d;
select is(pg_temp.filas(d), array['01'], 'el delta trae solo la 01 (la 02 y la 04 no se tocan)') from p4;
select is(pg_temp.marca(d, '01'), '03', 'con unida_a_id = la 03') from p4;
create temp table p5 as select sync.pull(array['ubicacion'], '{}'::jsonb, 1000) as d;
select is(array[pg_temp.marca(d, '01'), pg_temp.marca(d, '02'), pg_temp.marca(d, '03'), pg_temp.marca(d, '04'),
                pg_temp.marca(d, '05'), pg_temp.marca(d, '06')],
          array['03', '01', null, '01', null, null],
          'a pull completo: 01→03, 02→01, 04→01; la 03, la 05 y la 06 en null (la marca de B no sigue la cadena)') from p5;

-- ---------------------------------------------------------------------------
-- 5. Reactivar por push
-- ---------------------------------------------------------------------------
create temp table r1 as
select sync.push(jsonb_build_array(
  pg_temp.job('update', 'c1', jsonb_build_object('id', pg_temp.u('02'), 'deleted_at', null), pg_temp.version(pg_temp.u('02')))
)) as r;
select is(pg_temp.resultados(r), array['invalid UB005'], 'reactivar la 02 (unida) por push: invalid UB005') from r1;
select is((select r -> 'results' -> 0 ->> 'message' from r1), 'Esta ubicación se unió a otra y no se puede reactivar.',
          'con el texto de la decisión') from r1;
select pg_temp.actuar_como_servidor();
select ok((select deleted_at is not null from public.ubicacion where id = pg_temp.u('02')), 'y la 02 sigue de baja');
select pg_temp.actuar_como(pg_temp.u('b1'));

-- El reintento (otro op) vuelve a dar lo mismo: un rechazo no entra al cache.
select is(pg_temp.resultados(sync.push(jsonb_build_array(
            pg_temp.job('update', 'c1', jsonb_build_object('id', pg_temp.u('02'), 'deleted_at', null), pg_temp.version(pg_temp.u('02')))))),
          array['invalid UB005'], 'el mismo trabajo reintentado vuelve a dar UB005 (el rechazo no entra al cache)');

-- Una baja común se reactiva, y el lote sigue: [reactivar la 02, reactivar la 05, editar la 06].
select is(pg_temp.resultados(sync.push(jsonb_build_array(
            pg_temp.job('update', 'c2', jsonb_build_object('id', pg_temp.u('02'), 'deleted_at', null), pg_temp.version(pg_temp.u('02'))),
            pg_temp.job('update', 'c3', jsonb_build_object('id', pg_temp.u('05'), 'deleted_at', null), pg_temp.version(pg_temp.u('05'))),
            pg_temp.job('update', 'c4', jsonb_build_object('id', pg_temp.u('06'), 'numero', '6 bis'), pg_temp.version(pg_temp.u('06')))))),
          array['invalid UB005', 'accepted', 'accepted'],
          'en un lote, la unida se rechaza y la baja común (05) y la edición (06) se aceptan');
select pg_temp.actuar_como_servidor();
select is((select deleted_at is null from public.ubicacion where id = pg_temp.u('05')), true, 'la 05 quedó viva');
select is((select numero from public.ubicacion where id = pg_temp.u('06')), '6 bis', 'y la 06 editada');
select pg_temp.actuar_como(pg_temp.u('b1'));

-- La que se reactivó baja sin marca; se puede dar de baja y reactivar otra vez.
create temp table p6 as select sync.pull(array['ubicacion'], (select d -> 'watermark' from p4), 1000) as d;
select is(pg_temp.filas(d), array['05','06'], 'el delta trae la 05 y la 06') from p6;
select is(pg_temp.marca(d, '05'), null, 'la 05 reactivada, sin marca') from p6;
select is(pg_temp.resultados(sync.push(jsonb_build_array(
            pg_temp.job('update', 'c5', jsonb_build_object('id', pg_temp.u('05'), 'deleted_at', now()), pg_temp.version(pg_temp.u('05'))),
            pg_temp.job('update', 'c6', jsonb_build_object('id', pg_temp.u('05'), 'deleted_at', null), pg_temp.version(pg_temp.u('05')) + 1)))),
          array['accepted', 'accepted'], 'una baja común se da de baja y se reactiva las veces que haga falta');

-- Un teléfono atrasado (sin la versión de ahora) recibe el conflicto con la marca en el server_row.
create temp table r2 as
select sync.push(jsonb_build_array(
  pg_temp.job('update', 'c7', jsonb_build_object('id', pg_temp.u('02'), 'numero', '2 tarde'), 0))) as r;
select is(pg_temp.resultados(r), array['conflict'], 'un teléfono con una versión vieja de la 02 recibe un conflicto') from r2;
select is(right(r -> 'results' -> 0 -> 'server_row' ->> 'unida_a_id', 2), '01',
          'y el server_row trae la marca: adopta la baja y la leyenda') from r2;

-- ---------------------------------------------------------------------------
-- 6. Reactivar por UPDATE directo (PostgREST) y como servidor
-- ---------------------------------------------------------------------------
select is(pg_temp.err(format('update public.ubicacion set deleted_at = null where id = %L', pg_temp.u('02'))), 'UB005',
          'b1, por UPDATE directo, reactivando la 02: UB005');
select is(pg_temp.err(format('update public.ubicacion set deleted_at = null, numero = %L where id = %L', 'x', pg_temp.u('04'))), 'UB005',
          'y la 04 (unida cuando ya estaba de baja), también, aunque cambie otra columna a la vez');
select throws_ok(format('update public.ubicacion set deleted_at = null where id = %L', pg_temp.u('02')),
                  'UB005', 'Esta ubicación se unió a otra y no se puede reactivar.',
                  'con el mismo texto');
select is(pg_temp.err(format('update public.ubicacion set numero = %L where id = %L', '2 bis', pg_temp.u('02'))), 'ok',
          'editar una unida sin reactivarla no se rechaza');
select is(pg_temp.err(format('update public.ubicacion set deleted_at = now() where id = %L', pg_temp.u('02'))), 'ok',
          'ni darla de baja de nuevo');
select pg_temp.actuar_como_servidor();
select is(pg_temp.err(format('update public.ubicacion set deleted_at = null where id = %L', pg_temp.u('02'))), 'UB005',
          'el servidor (sin usuario) tampoco la reactiva');
select is(pg_temp.err(format('update public.ubicacion set deleted_at = null where id = %L', pg_temp.u('06'))), 'ok',
          'pero una viva que se actualiza con deleted_at null (sin cambio) pasa');
select ok((select deleted_at is not null from public.ubicacion where id = pg_temp.u('02')), 'la 02 sigue de baja');
select is(pg_temp.err(format('update public.ubicacion set deleted_at = null where id = %L', pg_temp.u('03'))), 'ok',
          'la 03, a la que otras se unieron, está viva y no tiene problema');

-- Una unión hecha por el servidor (sin usuario: created_by null) también se manda y se frena.
select is(public.marcar_como_duplicado(pg_temp.u('07'), pg_temp.u('06')) ->> 'ya_unida', 'false',
          'el servidor une la 07 a la 06');
select is((select created_by from public.ubicacion_union where duplicada_id = pg_temp.u('07')), null,
          'sin autor en el registro');
select is(pg_temp.err(format('update public.ubicacion set deleted_at = null where id = %L', pg_temp.u('07'))), 'UB005',
          'y la 07 tampoco se reactiva');
select pg_temp.actuar_como(pg_temp.u('b1'));
create temp table p7 as select sync.pull(array['ubicacion'], (select d -> 'watermark' from p6), 1000) as d;
select ok('07' = any (pg_temp.filas(d)), 'el delta de b1 trae la 07 (y las que se tocaron desde el pull anterior)') from p7;
select is(pg_temp.marca(d, '07'), '06', 'con unida_a_id = la 06') from p7;
select pg_temp.actuar_como_servidor();

-- ---------------------------------------------------------------------------
-- 7. Permisos y alcance
-- ---------------------------------------------------------------------------
select is(public.ubicacion_unida_a(pg_temp.u('02')), pg_temp.u('01'), 'ubicacion_unida_a(02) = 01');
select is(public.ubicacion_unida_a(pg_temp.u('03')), null, 'ubicacion_unida_a(03) = null');
select is(public.ubicacion_unida_a(gen_random_uuid()), null, 'y de una que no existe, null');
select pg_temp.actuar_como(pg_temp.u('b1'));
select is(public.ubicacion_unida_a(pg_temp.u('02')), pg_temp.u('01'), 'authenticated la ejecuta (la necesita el pull)');
select is((select count(*)::int from public.ubicacion_union), 0, 'pero un colportor sigue sin leer ubicacion_union: es del ADMIN');
select pg_temp.actuar_como_anon();
select is(pg_temp.err(format('select public.ubicacion_unida_a(%L)', pg_temp.u('02'))), '42501', 'anon no la ejecuta');
select pg_temp.actuar_como_servidor();
select pg_temp.actuar_como(pg_temp.u('b1'));
select is(pg_temp.err('select public.tg_ubicacion_union_avisa_al_telefono()'), '42501',
          'los triggers no los ejecuta authenticated');
select pg_temp.actuar_como_servidor();
select ok(sync.expresion_json('public.ubicacion'::regclass) like '%unida_a_id%', 'la fila de ubicacion lleva la clave');
select ok(sync.expresion_json('public.espacio'::regclass) not like '%unida_a_id%'
          and sync.expresion_json('public.house_status'::regclass) not like '%unida_a_id%',
          'y las demás entidades no');
select ok('unida_a_id' <> all (sync.columnas_escribibles('ubicacion')),
          'unida_a_id no es una columna escribible: un push que la mande se ignora');
select pg_temp.actuar_como(pg_temp.u('b1'));
select is(pg_temp.resultados(sync.push(jsonb_build_array(
            pg_temp.job('update', 'c8', jsonb_build_object('id', pg_temp.u('06'), 'numero', '6 ter', 'unida_a_id', pg_temp.u('01')),
                        pg_temp.version(pg_temp.u('06')))))),
          array['accepted'], 'un push de la 06 que manda unida_a_id se acepta (la clave se ignora)');
select pg_temp.actuar_como_servidor();
select is(public.ubicacion_unida_a(pg_temp.u('06')), null, 'y la 06 no quedó unida');

-- ---------------------------------------------------------------------------
-- Limpieza
-- ---------------------------------------------------------------------------
drop table p1, p2, p3, p4, p5, p6, p7, q1, r1, r2, v2;
select pg_temp.limpiar();
select is((select count(*)::int from public.ubicacion where id::text like '01920000-0000-7000-8000-0000000057%'),
          0, 'limpieza: no quedan ubicaciones de la prueba');

select * from finish();
