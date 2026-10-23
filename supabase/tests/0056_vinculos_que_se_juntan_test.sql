-- pgTAP · migración 0064 (backend-supabase#105; decisión de Cristian del 21/10, «Venta tarde»):
-- el vínculo que llega de una persona que ya tiene uno en el espacio fundido se JUNTA con él. El caso
-- base (la venta y la visita tardías terminan en A, la respuesta `merged`, los permisos del registro)
-- está en 0044; acá, la cadena: A se une después a C y el vínculo juntado sigue al que quedó.
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
  select ('01920000-0000-7000-8000-0000000056' || p)::uuid;
$$;
create or replace function pg_temp.job(p_ent text, p_op text, p_payload jsonb) returns jsonb language sql as $$
  select jsonb_build_object('client_op_id', gen_random_uuid(), 'entity', p_ent, 'op', p_op, 'payload', p_payload);
$$;
create or replace function pg_temp.resultados(p_r jsonb) returns text[] language sql as $$
  select array_agg((e ->> 'outcome') || coalesce(' ' || (e ->> 'code'), '') order by i)
    from jsonb_array_elements(p_r -> 'results') with ordinality x(e, i);
$$;

-- --- fixtures (como postgres) --------------------------------------------------
-- Ids (prefijo 56): usuarios b1 b2; ubicaciones 01 A, 02 B, 03 C; espacios únicos 11 (A), 12 (B), 13 (C);
-- personas 60 (en las tres casas) y 61 (solo en A); vínculos 21 (A, 60), 22 (B, 60), 23 (C, 60), 24 (A, 61).
insert into auth.users (id, instance_id, aud, role, email, encrypted_password, confirmed_at, created_at, updated_at)
select pg_temp.u(s), '00000000-0000-0000-0000-000000000000',
       'authenticated', 'authenticated', 'juntan56-' || s || '@example.com', 'x', now(), now(), now()
  from unnest(array['b1','b2']) s;
insert into public.pais (id, nombre, iso_code) values (pg_temp.u('f0'), 'Pais juntan56', 'ZJ');
insert into public.ciudad (id, nombre, departamento, pais_id, lat_centro, lon_centro)
values (pg_temp.u('f1'), 'Ciudad juntan56', 'Departamento de prueba', pg_temp.u('f0'), -34.9, -56.2);
insert into public.campania (id, nombre, tipo, fecha_inicio, fecha_fin)
values (pg_temp.u('f3'), 'Verano juntan56', 'VERANO', public.hoy_montevideo() - 10, public.hoy_montevideo() + 30);
insert into public.campania_ciudad (id, campania_id, ciudad_id) values (pg_temp.u('f5'), pg_temp.u('f3'), pg_temp.u('f1'));
insert into public.campania_colportor (campania_id, usuario_id, zona_id) values
  (pg_temp.u('f3'), pg_temp.u('b1'), null), (pg_temp.u('f3'), pg_temp.u('b2'), null);
insert into public.ubicacion (id, tipo, calle, numero, lat, lon, ciudad_id, created_by)
select pg_temp.u(x.u), 'CASA', 'Juntan ' || x.u, x.u, -34.9 - x.n * 0.01, -56.2, pg_temp.u('f1'), pg_temp.u('b1')
  from (values ('01', 1), ('02', 2), ('03', 3)) x(u, n);
insert into public.espacio (id, ubicacion_id, numero_depto, created_by)
values (pg_temp.u('11'), pg_temp.u('01'), null, pg_temp.u('b1')),
       (pg_temp.u('12'), pg_temp.u('02'), null, pg_temp.u('b1')),
       (pg_temp.u('13'), pg_temp.u('03'), null, pg_temp.u('b1'));
insert into public.espacio_persona (id, espacio_id, persona_id, created_by)
values (pg_temp.u('21'), pg_temp.u('11'), pg_temp.u('60'), pg_temp.u('b1')),
       (pg_temp.u('22'), pg_temp.u('12'), pg_temp.u('60'), pg_temp.u('b1')),
       (pg_temp.u('23'), pg_temp.u('13'), pg_temp.u('60'), pg_temp.u('b1')),
       (pg_temp.u('24'), pg_temp.u('11'), pg_temp.u('61'), pg_temp.u('b1'));

-- ---------------------------------------------------------------------------
-- 1. B se une a A; Ana (b2) sube después a Pedro (persona 60) en B, con una visita y una venta
-- ---------------------------------------------------------------------------
select pg_temp.actuar_como(pg_temp.u('b1'));
select is(public.marcar_como_duplicado(pg_temp.u('02'), pg_temp.u('01')) ->> 'ya_unida', 'false', 'b1 une B (02) a A (01)');
select pg_temp.actuar_como(pg_temp.u('b2'));
create temp table lote_1 on commit drop as
select sync.push(jsonb_build_array(
  pg_temp.job('espacio_persona', 'insert', jsonb_build_object('id', pg_temp.u('31'), 'espacio_id', pg_temp.u('12'),
              'persona_id', pg_temp.u('60'))),
  pg_temp.job('visita', 'insert', jsonb_build_object('id', pg_temp.u('41'), 'espacio_persona_id', pg_temp.u('31'),
              'fecha', now(), 'tipo_resultado', 'ENTREVISTA')),
  pg_temp.job('venta', 'insert', jsonb_build_object('id', pg_temp.u('51'), 'espacio_persona_id', pg_temp.u('31'),
              'numero_talonario', 'T-51', 'monto_total', 90000, 'fecha', now())),
  pg_temp.job('espacio_persona', 'insert', jsonb_build_object('id', pg_temp.u('32'), 'espacio_id', pg_temp.u('12'),
              'persona_id', pg_temp.u('61')))
)) as r;
select is((select pg_temp.resultados(r) from lote_1), array['merged', 'accepted', 'accepted', 'merged'],
          'el vínculo de Pedro y el de la persona 61 (que ya están en A) se juntan; la visita y la venta se aceptan');
select is((select r -> 'results' -> 0 ->> 'merged_into' from lote_1), pg_temp.u('21')::text, 'Pedro: el vínculo que queda es el 21');
select is((select r -> 'results' -> 3 ->> 'merged_into' from lote_1), pg_temp.u('24')::text, 'la persona 61: el 24');
select pg_temp.actuar_como_servidor();
select is((select espacio_persona_id from public.visita where id = pg_temp.u('41')), pg_temp.u('21'), 'la visita terminó en el 21');
select is((select espacio_persona_id from public.venta where id = pg_temp.u('51')), pg_temp.u('21'), 'la venta también');

-- ---------------------------------------------------------------------------
-- 2. Después A se une a C: el vínculo juntado sigue al que quedó (la cadena)
-- ---------------------------------------------------------------------------
select pg_temp.actuar_como(pg_temp.u('b1'));
select is(public.marcar_como_duplicado(pg_temp.u('01'), pg_temp.u('03')) ->> 'ya_unida', 'false', 'b1 une A (01) a C (03)');
select pg_temp.actuar_como_servidor();
select is((select deleted_at is not null from public.espacio_persona where id = pg_temp.u('21')), true,
          'el 21 se fundió en el de C (23) y quedó dado de baja');
select pg_temp.actuar_como(pg_temp.u('b2'));
select is(public.vinculo_juntado(pg_temp.u('31')), pg_temp.u('23'), 'Pedro (31) ahora es el 23, el de C: sigue la cadena');
select is(public.vinculo_juntado(pg_temp.u('32')), pg_temp.u('24'), 'la persona 61 (32), que se mudó a C con su mismo id: el 24');
create temp table lote_2 on commit drop as
select sync.push(jsonb_build_array(
  pg_temp.job('espacio_persona', 'insert', jsonb_build_object('id', pg_temp.u('31'), 'espacio_id', pg_temp.u('12'),
              'persona_id', pg_temp.u('60'))),
  pg_temp.job('visita', 'insert', jsonb_build_object('id', pg_temp.u('42'), 'espacio_persona_id', pg_temp.u('31'),
              'fecha', now(), 'tipo_resultado', 'RECHAZO')),
  pg_temp.job('espacio_persona', 'insert', jsonb_build_object('id', pg_temp.u('33'), 'espacio_id', pg_temp.u('12'),
              'persona_id', pg_temp.u('60'))),
  pg_temp.job('venta', 'insert', jsonb_build_object('id', pg_temp.u('52'), 'espacio_persona_id', pg_temp.u('33'),
              'numero_talonario', 'T-52', 'monto_total', 10000, 'fecha', now()))
)) as r;
select is((select pg_temp.resultados(r) from lote_2), array['merged', 'accepted', 'merged', 'accepted'],
          'reintentar a Pedro (31) y subir uno nuevo (33): los dos se juntan, y la visita y la venta se aceptan');
select is((select r -> 'results' -> 0 ->> 'merged_into' from lote_2), pg_temp.u('23')::text, 'el reintento dice el destino de hoy (23), no el de entonces (21)');
select is((select r -> 'results' -> 2 ->> 'merged_into' from lote_2), pg_temp.u('23')::text, 'y el nuevo (33), el 23');
select pg_temp.actuar_como_servidor();
select is((select espacio_persona_id from public.visita where id = pg_temp.u('42')), pg_temp.u('23'), 'la visita que nombra a Pedro (31) cae en el vínculo de C');
select is((select espacio_persona_id from public.venta where id = pg_temp.u('52')), pg_temp.u('23'), 'la venta que nombra al 33, también');
select is((select count(*) from public.espacio_persona where id in (pg_temp.u('31'), pg_temp.u('32'), pg_temp.u('33'))), 0::bigint,
          'ninguno de los vínculos que subió Ana (31, 32, 33) es una fila: todos se juntaron');
select is((select espacio_id from public.espacio_persona where id = pg_temp.u('24')), pg_temp.u('13'), 'y el de la persona 61 está en el único de C');
select is((select count(*) from public.venta where id in (pg_temp.u('51'), pg_temp.u('52')) and deleted_at is null), 2::bigint,
          'las dos ventas están, vivas');
select is((select deleted_at from public.espacio_persona where id = pg_temp.u('23')), null, 'y el vínculo de C sigue vivo');

select * from finish();
rollback;
