-- pgTAP · migración 0207 (backend-supabase#313, «Avisos s/red»), el pull: las preferencias de avisos bajan con la sincronización.
--   1. Cada persona baja SOLO su fila (la de otra persona, aunque sea el ADMIN, no se cuela).
--   2. La fila trae lo que el teléfono usa (id de la persona, notif_preferences y las columnas comunes) y no la maquinaria del delta.
--   3. El delta: un cambio hecho en el servidor (la RPC o el servidor) baja solo, y uno que la persona subió desde otro teléfono también;
--      sin cambios no baja nada.
--   4. Un teléfono nuevo, desde cero, baja la fila con lo último.
-- Como 0201, NO va en una transacción (el delta solo sirve lo commiteado). Limpia al empezar y al final.

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
  select ('01920000-0000-7000-8000-0000000207' || p_sufijo)::uuid;
$$;
create or replace function pg_temp.limpiar() returns void language plpgsql as $$
begin
  delete from auth.users where id in (pg_temp.u('a1'), pg_temp.u('a2'), pg_temp.u('a9'));
end $$;
create or replace function pg_temp.pull_de(p text, p_marca jsonb default '{}'::jsonb) returns jsonb
language plpgsql as $$
declare d jsonb;
begin
  perform pg_temp.actuar_como(pg_temp.u(p));
  d := sync.pull(array['preferencia_de_avisos'], p_marca, 1000);
  perform pg_temp.como_servidor();
  return d;
end $$;
-- Las filas que bajaron: «sufijo:preferencias,…» ('-' si ninguna).
create or replace function pg_temp.filas(p_delta jsonb) returns text language sql as $$
  select coalesce(string_agg(right(e ->> 'id', 2) || ':' || coalesce((e -> 'notif_preferences')::text, 'null'), ',' order by e ->> 'id'), '-')
    from jsonb_array_elements(coalesce(p_delta -> 'rows' -> 'preferencia_de_avisos', '[]'::jsonb)) e
$$;

-- a1 y a2 colportores, a9 ADMIN.
select pg_temp.limpiar();
insert into auth.users (id, instance_id, aud, role, email, encrypted_password, confirmed_at, created_at, updated_at)
select pg_temp.u(s), '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
       'prefs207p-' || s || '@example.com', 'x', now(), now(), now()
  from unnest(array['a1','a2','a9']) s;
insert into public.usuario_rol (usuario_id, rol_id)
select pg_temp.u(x.s), r.id from (values ('a1','COLPORTOR'), ('a2','COLPORTOR'), ('a9','ADMIN')) x(s, codigo) join public.rol r on r.codigo = x.codigo;
update public.usuario set notif_preferences = '{"hora_cuota":"10:00"}' where id = pg_temp.u('a2');

-- 1. Cada persona baja la suya
create temp table p1 as select pg_temp.pull_de('a1') as d;
select is(pg_temp.filas((select d from p1)), 'a1:null', 'a1 baja solo su fila (sin preferencias: todo por defecto)');
create temp table p2 as select pg_temp.pull_de('a2') as d;
select is(pg_temp.filas((select d from p2)), 'a2:{"hora_cuota": "10:00"}', 'a2 baja la suya, con lo que ya tenía guardado');
create temp table p9 as select pg_temp.pull_de('a9') as d;
select is(pg_temp.filas((select d from p9)), 'a9:null', 'el ADMIN baja la suya y no la de las demás personas');

-- 2. La fila
select ok((select bool_and(e ?& array['id', 'notif_preferences', 'created_at', 'updated_at', 'deleted_at', 'sync_version'] and not (e ? 'xmin_w'))
             from jsonb_array_elements((select d -> 'rows' -> 'preferencia_de_avisos' from p1)) e),
          'la fila trae id, notif_preferences, las columnas comunes y no xmin_w');

-- 3. El delta
create temp table m1 as select d -> 'watermark' as w from p1;
select is(pg_temp.filas(pg_temp.pull_de('a1', (select w from m1))), '-', 'sin cambios, el delta no trae nada');

select pg_temp.actuar_como(pg_temp.u('a1'));
select public.guardar_mis_preferencias_de_avisos('{"hora_agenda":"21:00"}'::jsonb);
select pg_temp.como_servidor();
create temp table d1 as select pg_temp.pull_de('a1', (select w from m1)) as d;
select is(pg_temp.filas((select d from d1)), 'a1:{"hora_agenda": "21:00"}', 'lo que se guardó con conexión (la RPC) baja como un cambio de la fila');

-- Otro teléfono de a1 sube un cambio por el push.
create temp table m2 as select d -> 'watermark' as w from d1;
select pg_temp.actuar_como(pg_temp.u('a1'));
select sync.push(jsonb_build_array(jsonb_build_object(
         'client_op_id', gen_random_uuid(), 'entity', 'preferencia_de_avisos', 'op', 'update',
         'sync_version', (select sync_version from public.preferencia_de_avisos where id = pg_temp.u('a1')),
         'payload', jsonb_build_object('id', pg_temp.u('a1'), 'notif_preferences', '{"hora_agenda":"22:00","tickets":false}'::jsonb))));
select pg_temp.como_servidor();
create temp table d2 as select pg_temp.pull_de('a1', (select w from m2)) as d;
select is(pg_temp.filas((select d from d2)), 'a1:{"tickets": false, "hora_agenda": "22:00"}',
          'lo que subió el otro teléfono baja al primero');
select is((select notif_preferences from public.usuario where id = pg_temp.u('a1')), '{"tickets":false,"hora_agenda":"22:00"}'::jsonb,
          'y el servidor lo tiene en usuario.notif_preferences');

-- 4. Un teléfono nuevo
create temp table d3 as select pg_temp.pull_de('a1') as d;
select is(pg_temp.filas((select d from d3)), 'a1:{"tickets": false, "hora_agenda": "22:00"}', 'desde cero baja la fila con lo último');

select pg_temp.limpiar();
select * from finish();
