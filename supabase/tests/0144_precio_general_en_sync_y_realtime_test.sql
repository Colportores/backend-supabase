-- pgTAP · migración 0144 (backend-supabase#205): precio_general baja al teléfono.
--   · el registro: entidad de solo bajada (el push se rechaza), PK id, sigue las campañas del usuario
--     (sigue_campanias, como precio_por_ciudad) y usa el índice del delta de la 0034;
--   · Realtime: la tabla está en supabase_realtime, junto al resto del catálogo;
--   · las políticas de lectura no cambiaron (las tres de la 0034);
--   · el pull: Agustín (Rivera, sin excepción de precio) recibe el precio general; lo reciben igual
--     los colportores de cualquier campaña y el coordinador, sin filtro por campaña ni por ciudad; quien
--     no tiene campaña no recibe nada (lo decide la RLS); al inscribirse DESPUÉS de su primer pull le
--     bajan completos los precios que ya estaban cargados (la huella de las campañas); después, solo
--     el delta (el cambio de un importe y la baja lógica como tombstone).
--
-- Como 0004, 0011 y 0034_pull, NO va en una transacción: el delta solo sirve lo commiteado.
-- Limpia al final.

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

create or replace function pg_temp.u(p_sufijo text) returns uuid language sql as $$
  select ('01920000-0000-7000-8000-0000000144' || p_sufijo)::uuid;
$$;

-- Los sufijos de los ids de los precios en `rows`, ordenados; con «x» si vienen dados de baja.
create or replace function pg_temp.filas(p_delta jsonb) returns text[]
language sql as $$
  select coalesce(array_agg(right(e ->> 'id', 2) || case when e ->> 'deleted_at' is not null then 'x' else '' end
                            order by e ->> 'id'), array[]::text[])
    from jsonb_array_elements(coalesce(p_delta -> 'rows' -> 'precio_general', '[]'::jsonb)) e;
$$;

-- ---------------------------------------------------------------------------
-- 1. El registro, Realtime y las políticas
-- ---------------------------------------------------------------------------
select results_eq(
  $$ select nombre, tabla::text, columna_pk, permite_push, sigue_campanias, columna_ubicacion, columna_duenio
       from sync.entidad where nombre = 'precio_general' $$,
  $$ values ('precio_general'::text, 'precio_general'::text, 'id'::text, false, true, null::text, null::text) $$,
  'la entidad de sync: precio_general, de solo bajada, que sigue las campañas, sin ubicación ni dueño');
select has_index('public', 'precio_general', 'precio_general_delta_idx', array['xmin_w', 'id'],
                 'el índice del delta que ya existía');
select is((select count(*)::int from pg_publication_tables
            where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'precio_general'),
          1, 'supabase_realtime publica precio_general');
select bag_eq(
  $$ select tablename::text from pg_publication_tables where pubname = 'supabase_realtime' and schemaname = 'public' $$,
  array['producto','coleccion','producto_coleccion','precio_por_ciudad','precio_general'],
  'y sigue siendo solo el catálogo');
select bag_eq(
  $$ select policyname::text from pg_policies where schemaname = 'public' and tablename = 'precio_general' $$,
  array['precio_general_select','precio_general_insert_admin','precio_general_update_admin'],
  'las políticas de la 0034 no cambiaron');
select unalike((select obj_description('public.precio_general'::regclass, 'pg_class')), '%Todavía no baja%',
               'el comentario de la tabla ya no dice que no baja al teléfono');

-- ---------------------------------------------------------------------------
-- Fixtures (como postgres). e1 (coordina a1) tiene Rivera (f1); e2 (sin coordinador), Salto (f2).
-- b1 (Agustín) está inscripto en e1; b2 en e2; b3 en ninguna (después se inscribe en e1).
-- Ninguna ciudad tiene precio por ciudad: el único precio es el general.
-- Precios generales: 01 y 02 vigentes (dos productos), 03 es el tramo anterior del producto a1.
-- ---------------------------------------------------------------------------
insert into auth.users (id, instance_id, aud, role, email, encrypted_password, confirmed_at, created_at, updated_at)
select pg_temp.u(s), '00000000-0000-0000-0000-000000000000',
       'authenticated', 'authenticated', 'general144-' || s || '@example.com', 'x', now(), now(), now()
  from unnest(array['a1','b1','b2','b3']) s;
insert into public.usuario_rol (usuario_id, rol_id)
select pg_temp.u(x.s), r.id
  from (values ('a1','COORDINADOR'), ('b1','COLPORTOR'), ('b2','COLPORTOR'), ('b3','COLPORTOR')) x(s, codigo)
  join public.rol r on r.codigo = x.codigo;

insert into public.pais (id, nombre, iso_code) values (pg_temp.u('c0'), 'Pais general144', 'ZK');
insert into public.ciudad (id, nombre, departamento, pais_id, lat_centro, lon_centro) values
  (pg_temp.u('c1'), 'Rivera general144', 'Rivera', pg_temp.u('c0'), -30.9, -55.5),
  (pg_temp.u('c2'), 'Salto general144', 'Salto', pg_temp.u('c0'), -31.4, -57.9);
insert into public.campania (id, nombre, tipo, fecha_inicio, fecha_fin, coordinador_id) values
  (pg_temp.u('e1'), 'e1 general144', 'VERANO', public.hoy_montevideo() - 10, public.hoy_montevideo() + 30, pg_temp.u('a1')),
  (pg_temp.u('e2'), 'e2 general144', 'VERANO', public.hoy_montevideo() - 10, public.hoy_montevideo() + 30, null);
insert into public.campania_ciudad (id, campania_id, ciudad_id) values
  (pg_temp.u('f1'), pg_temp.u('e1'), pg_temp.u('c1')),
  (pg_temp.u('f2'), pg_temp.u('e2'), pg_temp.u('c2'));
insert into public.campania_colportor (campania_id, usuario_id) values
  (pg_temp.u('e1'), pg_temp.u('b1')),
  (pg_temp.u('e2'), pg_temp.u('b2'));
insert into public.producto (id, nombre, tipo) values
  (pg_temp.u('a1'), 'Conflicto de los Siglos general144', 'LIBRO'),
  (pg_temp.u('a2'), 'Otro libro general144', 'LIBRO');
insert into public.precio_general (id, producto_id, precio_venta, valido_desde, valido_hasta) values
  (pg_temp.u('01'), pg_temp.u('a1'), 45000, '2026-01-01', null),
  (pg_temp.u('02'), pg_temp.u('a2'), 30000, '2026-01-01', null),
  (pg_temp.u('03'), pg_temp.u('a1'), 40000, '2025-01-01', '2025-12-31');

-- ---------------------------------------------------------------------------
-- 2. Primer pull: el general baja para todos los que lo leen, de cualquier campaña
-- ---------------------------------------------------------------------------
select pg_temp.actuar_como(pg_temp.u('b1'));
create temp table p1 as select sync.pull(array['precio_general'], '{}'::jsonb, 1000) as d;
select is(pg_temp.filas(d), array['01','02','03'],
          'Agustín (b1, Rivera, sin excepción) baja los precios generales: el vigente de cada producto y el tramo anterior') from p1;
select is((select (e ->> 'precio_venta')::int
             from p1, jsonb_array_elements(d -> 'rows' -> 'precio_general') e
            where right(e ->> 'id', 2) = '01'),
          45000, 'con el importe del Conflicto de los Siglos en centavos') from p1;
select is((select e ->> 'producto_id'
             from p1, jsonb_array_elements(d -> 'rows' -> 'precio_general') e
            where right(e ->> 'id', 2) = '01'),
          pg_temp.u('a1')::text, 'y a qué producto corresponde') from p1;
select ok((select bool_and(e ? 'valido_desde' and e ? 'valido_hasta' and e ? 'coleccion_id' and not (e ? 'xmin_w'))
             from p1, jsonb_array_elements(d -> 'rows' -> 'precio_general') e),
          'la fila lleva la vigencia y los dos posibles dueños, y no la maquinaria del delta') from p1;
select is((select (d -> 'watermark' -> 'precio_general') ? 'area' from p1), true,
          'el watermark guarda la huella de las campañas (sigue_campanias)');

select pg_temp.actuar_como(pg_temp.u('b2'));
create temp table q1 as select sync.pull(array['precio_general'], '{}'::jsonb, 1000) as d;
select is(pg_temp.filas(d), array['01','02','03'],
          'b2 (otra campaña, otra ciudad) baja los mismos: el general vale para todo el país') from q1;

select pg_temp.actuar_como(pg_temp.u('a1'));
create temp table c1 as select sync.pull(array['precio_general'], '{}'::jsonb, 1000) as d;
select is(pg_temp.filas(d), array['01','02','03'], 'el coordinador de e1 también') from c1;

select pg_temp.actuar_como(pg_temp.u('b3'));
create temp table r1 as select sync.pull(array['precio_general'], '{}'::jsonb, 1000) as d;
select is(pg_temp.filas(d), array[]::text[], 'b3 (sin campaña) no baja nada: lo decide la política de lectura') from r1;

-- ---------------------------------------------------------------------------
-- 3. Se inscribe a b3 en e1: los precios que ya estaban cargados bajan completos
-- ---------------------------------------------------------------------------
select pg_temp.como_servidor();
insert into public.campania_colportor (campania_id, usuario_id) values (pg_temp.u('e1'), pg_temp.u('b3'));

select pg_temp.actuar_como(pg_temp.u('b3'));
create temp table r2 as select sync.pull(array['precio_general'], (select d -> 'watermark' from r1), 1000) as d;
select is(pg_temp.filas(d), array['01','02','03'],
          'b3, ya inscripto, baja los tres aunque se cargaron antes de su último pull (la huella cambió)') from r2;

create temp table r3 as select sync.pull(array['precio_general'], (select d -> 'watermark' from r2), 1000) as d;
select is(pg_temp.filas(d), array[]::text[], 'y el siguiente, sin cambios, no baja nada') from r3;

-- ---------------------------------------------------------------------------
-- 4. Cambios: el delta trae el importe nuevo y la baja lógica (tombstone), a quien ya tenía todo
-- ---------------------------------------------------------------------------
select pg_temp.como_servidor();
update public.precio_general set precio_venta = 46000 where id = pg_temp.u('01');

select pg_temp.actuar_como(pg_temp.u('b1'));
create temp table p2 as select sync.pull(array['precio_general'], (select d -> 'watermark' from p1), 1000) as d;
select is(pg_temp.filas(d), array['01'], 'cambia un importe: baja solo esa fila') from p2;
select is((select (e ->> 'precio_venta')::int
             from p2, jsonb_array_elements(d -> 'rows' -> 'precio_general') e), 46000, 'con el importe nuevo') from p2;

select pg_temp.como_servidor();
update public.precio_general set deleted_at = now() where id = pg_temp.u('02');

select pg_temp.actuar_como(pg_temp.u('b1'));
create temp table p3 as select sync.pull(array['precio_general'], (select d -> 'watermark' from p2), 1000) as d;
select is(pg_temp.filas(d), array['02x'], 'la baja lógica baja como tombstone, para que el teléfono borre su réplica') from p3;

select pg_temp.actuar_como(pg_temp.u('b2'));
create temp table q2 as select sync.pull(array['precio_general'], (select d -> 'watermark' from q1), 1000) as d;
select is(pg_temp.filas(d), array['01','02x'], 'b2, de otra campaña, recibe los dos cambios') from q2;

-- ---------------------------------------------------------------------------
-- 5. Solo bajada: el teléfono no escribe el precio general
-- ---------------------------------------------------------------------------
select pg_temp.actuar_como(pg_temp.u('b1'));
select is(
  sync.push(jsonb_build_array(jsonb_build_object(
    'client_op_id', '01920000-0000-7000-8000-000000144b01', 'entity', 'precio_general', 'op', 'insert',
    'payload', jsonb_build_object('id', '01920000-0000-7000-8000-000000144f01', 'producto_id', pg_temp.u('a2'),
                                  'precio_venta', 1, 'valido_desde', '2026-02-01'))))
    #>> '{results,0,code}',
  'ENTIDAD_DE_SOLO_LECTURA',
  'subir un precio general desde el teléfono se rechaza (la réplica es de solo lectura)');
select pg_temp.como_servidor();
select is((select count(*)::int from public.precio_general where id = '01920000-0000-7000-8000-000000144f01'), 0,
          'y no quedó escrito');

-- ---------------------------------------------------------------------------
-- Limpieza
-- ---------------------------------------------------------------------------
drop table p1, p2, p3, q1, q2, c1, r1, r2, r3;
delete from public.precio_general where id::text like '01920000-0000-7000-8000-0000000144%';
delete from public.producto where id in (pg_temp.u('a1'), pg_temp.u('a2'));
delete from public.campania_colportor where campania_id in (pg_temp.u('e1'), pg_temp.u('e2'));
delete from public.campania_ciudad where id in (pg_temp.u('f1'), pg_temp.u('f2'));
delete from public.campania where id in (pg_temp.u('e1'), pg_temp.u('e2'));
delete from public.ciudad where id in (pg_temp.u('c1'), pg_temp.u('c2'));
delete from public.pais where id = pg_temp.u('c0');
delete from public.usuario_rol where usuario_id in (pg_temp.u('a1'), pg_temp.u('b1'), pg_temp.u('b2'), pg_temp.u('b3'));
delete from auth.users where id in (pg_temp.u('a1'), pg_temp.u('b1'), pg_temp.u('b2'), pg_temp.u('b3'));
select is((select count(*)::int from public.precio_general where id::text like '01920000-0000-7000-8000-0000000144%'),
          0, 'limpieza: no quedan precios de la prueba');

select * from finish();
