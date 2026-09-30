-- pgTAP · migración 0018 — el autor de un espacio lo corrige (update y delete) aunque su campaña
-- haya terminado (backend-supabase#32). El espacio de otro que ya no ve sigue rechazado.
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
create or replace function pg_temp.job(p_ent text, p_op text, p_payload jsonb, p_version bigint default null)
returns jsonb language sql as $$
  select jsonb_build_object('client_op_id', gen_random_uuid(), 'entity', p_ent, 'op', p_op,
                            'payload', p_payload, 'sync_version', p_version);
$$;
create or replace function pg_temp.resultados(p_r jsonb) returns text[] language sql as $$
  select array_agg((e ->> 'outcome') || coalesce(' ' || (e ->> 'code'), '') order by i)
    from jsonb_array_elements(p_r -> 'results') with ordinality x(e, i);
$$;

-- --- fixtures (como postgres) --------------------------------------------------
-- Verano (vigente) en c1; b1 y b2 inscriptos sin zona; b3 sin campaña. u1: casa del servidor en c1.
insert into auth.users (id, instance_id, aud, role, email, encrypted_password, confirmed_at, created_at, updated_at)
select ('01920000-0000-7000-8000-0000000021' || s)::uuid, '00000000-0000-0000-0000-000000000000',
       'authenticated', 'authenticated', 'espprop-' || s || '@example.com', 'x', now(), now(), now()
  from unnest(array['b1','b2','b3']) s;
insert into public.pais (id, nombre, iso_code) values ('01920000-0000-7000-8000-0000000021c0', 'Pais espprop', 'ZQ');
insert into public.ciudad (id, nombre, pais_id, lat_centro, lon_centro)
values ('01920000-0000-7000-8000-0000000021c1', 'Ciudad espprop', '01920000-0000-7000-8000-0000000021c0', -34.9, -56.2);
insert into public.campania (id, nombre, tipo, fecha_inicio, fecha_fin)
values ('01920000-0000-7000-8000-0000000021e1', 'Verano espprop', 'VERANO', current_date - 10, current_date + 30);
insert into public.campania_ciudad (id, campania_id, ciudad_id)
values ('01920000-0000-7000-8000-0000000021f1', '01920000-0000-7000-8000-0000000021e1', '01920000-0000-7000-8000-0000000021c1');
insert into public.campania_colportor (campania_id, usuario_id, zona_id) values
  ('01920000-0000-7000-8000-0000000021e1', '01920000-0000-7000-8000-0000000021b1', null),
  ('01920000-0000-7000-8000-0000000021e1', '01920000-0000-7000-8000-0000000021b2', null);
insert into public.ubicacion (id, tipo, calle, numero, lat, lon, ciudad_id)
values ('01920000-0000-7000-8000-000000002101', 'CASA', 'Espprop', '1', -34.9, -56.2, '01920000-0000-7000-8000-0000000021c1');

-- Con la campaña vigente, b1 carga dos deptos y b2 uno en la casa del servidor.
select pg_temp.actuar_como('01920000-0000-7000-8000-0000000021b1');
select is(pg_temp.resultados(sync.push(jsonb_build_array(
            pg_temp.job('espacio', 'insert', '{"id": "01920000-0000-7000-8000-000000002111",
                                               "ubicacion_id": "01920000-0000-7000-8000-000000002101", "numero_depto": "1"}'),
            pg_temp.job('espacio', 'insert', '{"id": "01920000-0000-7000-8000-000000002113",
                                               "ubicacion_id": "01920000-0000-7000-8000-000000002101", "numero_depto": "3"}')))),
          array['accepted', 'accepted'], 'b1 carga dos deptos con la campaña vigente');
select pg_temp.actuar_como('01920000-0000-7000-8000-0000000021b2');
select is(pg_temp.resultados(sync.push(jsonb_build_array(
            pg_temp.job('espacio', 'insert', '{"id": "01920000-0000-7000-8000-000000002112",
                                               "ubicacion_id": "01920000-0000-7000-8000-000000002101", "numero_depto": "2"}')))),
          array['accepted'], 'b2 carga el suyo');

-- La campaña termina.
select pg_temp.actuar_como_servidor();
update public.campania set fecha_fin = current_date - 1 where id = '01920000-0000-7000-8000-0000000021e1';

select pg_temp.actuar_como('01920000-0000-7000-8000-0000000021b1');
select is((select count(*) from public.espacio where id = '01920000-0000-7000-8000-000000002111'), 1::bigint,
          'b1 ve su espacio (lo cargó él)');
select is((select count(*) from public.espacio where id = '01920000-0000-7000-8000-000000002112'), 0::bigint,
          'y no el de b2 en una casa que ya no ve');

-- El propio: update y delete con la versión correcta (0) son accepted, no conflict.
select is(pg_temp.resultados(sync.push(jsonb_build_array(
            pg_temp.job('espacio', 'update', '{"id": "01920000-0000-7000-8000-000000002111", "piso": "7"}', 0)))),
          array['accepted'], 'b1 corrige su espacio con la campaña terminada: accepted');
select is((select piso from public.espacio where id = '01920000-0000-7000-8000-000000002111'), '7',
          'la corrección quedó escrita');
select is(pg_temp.resultados(sync.push(jsonb_build_array(
            pg_temp.job('espacio', 'delete', '{"id": "01920000-0000-7000-8000-000000002113"}', 0)))),
          array['accepted'], 'b1 da de baja su espacio con la campaña terminada: accepted');
select pg_temp.actuar_como_servidor();
select isnt((select deleted_at from public.espacio where id = '01920000-0000-7000-8000-000000002113'), null,
            'la baja quedó escrita');

-- El ajeno sigue rechazado: por el push, por UPDATE directo y sin poder verlo.
select pg_temp.actuar_como('01920000-0000-7000-8000-0000000021b1');
select is(pg_temp.resultados(sync.push(jsonb_build_array(
            pg_temp.job('espacio', 'update', '{"id": "01920000-0000-7000-8000-000000002112", "piso": "9"}', 0),
            pg_temp.job('espacio', 'delete', '{"id": "01920000-0000-7000-8000-000000002112"}', 0)))),
          array['invalid FILA_INEXISTENTE', 'invalid FILA_INEXISTENTE'],
          'b1 no toca el espacio de b2 en una casa que ya no ve');
update public.espacio set piso = '9' where id = '01920000-0000-7000-8000-000000002112';  -- ni por UPDATE directo (0 filas)
select pg_temp.actuar_como('01920000-0000-7000-8000-0000000021b3');
update public.espacio set piso = '9' where id = '01920000-0000-7000-8000-000000002112';  -- b3 (sin campaña) tampoco (0 filas)
select pg_temp.actuar_como_servidor();
select is((select piso from public.espacio where id = '01920000-0000-7000-8000-000000002112'), null,
          'el espacio de b2 quedó como estaba (ni b1 ni b3 lo tocaron por UPDATE directo)');

select * from finish();
rollback;
