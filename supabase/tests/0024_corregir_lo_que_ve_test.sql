-- pgTAP · migración 0021 (backend-supabase#45 y #51): corregir lo que la lectura ya ve vuelve
-- `invalid` 42501 y no un `conflict` falso con server_row; y el autor de una casa escribe solo
-- con la campaña vigente (con los 15 días de gracia de 0020).
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
create or replace function pg_temp.u(p text) returns uuid language sql as $$
  select ('01920000-0000-7000-8000-0000000024' || p)::uuid;
$$;
create or replace function pg_temp.job(p_ent text, p_op text, p_payload jsonb, p_version bigint default null)
returns jsonb language sql as $$
  select jsonb_build_object('client_op_id', gen_random_uuid(), 'entity', p_ent, 'op', p_op,
                            'payload', p_payload, 'sync_version', p_version);
$$;
-- El resultado del push con la clase de salida, el código y si trae server_row (que no debe traer).
create or replace function pg_temp.resultados(p_r jsonb) returns text[] language sql as $$
  select array_agg((e ->> 'outcome') || coalesce(' ' || (e ->> 'code'), '')
                    || case when e ? 'server_row' then ' +server_row' else '' end order by i)
    from jsonb_array_elements(p_r -> 'results') with ordinality x(e, i);
$$;
-- Un push de una sola corrección, con la versión que el servidor tiene hoy (como el teléfono que
-- bajó la fila al día).
create or replace function pg_temp.corregir(p_entidad text, p_id uuid, p_cambios jsonb) returns text[]
language plpgsql as $$
declare
  v_version bigint;
  v_clave   text := case when p_entidad = 'house_status' then 'ubicacion_id' else 'id' end;
begin
  execute format('select sync_version from public.%I where %I = $1', p_entidad, v_clave) into v_version using p_id;
  return pg_temp.resultados(sync.push(jsonb_build_array(
           pg_temp.job(p_entidad, 'update', jsonb_build_object(v_clave, p_id) || p_cambios, v_version))));
end $$;
create or replace function pg_temp.hoy() returns date language sql as $$
  select (now() at time zone 'America/Montevideo')::date;
$$;
create or replace function pg_temp.campania_de(p_inicio date, p_fin date) returns void language sql as $$
  update public.campania set fecha_inicio = p_inicio, fecha_fin = p_fin where id = pg_temp.u('e1');
$$;

-- ---------------------------------------------------------------------------
-- Fixtures: b1 inscripta (sin zona) en Verano (e1, ciudad c1); b2 registró la casa 01, con su
-- espacio 11 y su estado; b3 sin campaña.
-- ---------------------------------------------------------------------------
insert into auth.users (id, instance_id, aud, role, email, encrypted_password, confirmed_at, created_at, updated_at)
select pg_temp.u(s), '00000000-0000-0000-0000-000000000000',
       'authenticated', 'authenticated', 'lovisto-' || s || '@example.com', 'x', now(), now(), now()
  from unnest(array['b1','b2','b3']) s;
insert into public.pais (id, nombre, iso_code) values (pg_temp.u('c0'), 'Pais lo visto', 'ZV');
insert into public.ciudad (id, nombre, pais_id, lat_centro, lon_centro)
values (pg_temp.u('c1'), 'Ciudad lo visto', pg_temp.u('c0'), -34.9, -56.2);
insert into public.campania (id, nombre, tipo, fecha_inicio, fecha_fin)
values (pg_temp.u('e1'), 'Verano lo visto', 'VERANO', current_date + 3, current_date + 60);
insert into public.campania_ciudad (id, campania_id, ciudad_id) values (pg_temp.u('f1'), pg_temp.u('e1'), pg_temp.u('c1'));
insert into public.campania_colportor (campania_id, usuario_id) values (pg_temp.u('e1'), pg_temp.u('b1'));
insert into public.ubicacion (id, tipo, calle, numero, lat, lon, ciudad_id, created_by)
values (pg_temp.u('01'), 'CASA', 'Futura', '1', -34.9, -56.2, pg_temp.u('c1'), pg_temp.u('b2'));
insert into public.espacio (id, ubicacion_id, created_by) values (pg_temp.u('11'), pg_temp.u('01'), pg_temp.u('b2'));
insert into public.house_status (ubicacion_id, lat, lon, tipo_ubicacion, color, prioridad, created_by)
values (pg_temp.u('01'), -34.9, -56.2, 'CASA', 'RECHAZO', 7, pg_temp.u('b2'));
-- Una casa, un espacio y un estado que b1 registró él, para la parte 3.
insert into public.ubicacion (id, tipo, calle, numero, lat, lon, ciudad_id, created_by)
values (pg_temp.u('02'), 'CASA', 'Propia', '2', -34.91, -56.21, pg_temp.u('c1'), pg_temp.u('b1'));
insert into public.espacio (id, ubicacion_id, created_by) values (pg_temp.u('12'), pg_temp.u('02'), pg_temp.u('b1'));
insert into public.house_status (ubicacion_id, lat, lon, tipo_ubicacion, color, prioridad, created_by)
values (pg_temp.u('02'), -34.91, -56.21, 'CASA', 'SIN_CONTESTAR', 6, pg_temp.u('b1'));

-- ---------------------------------------------------------------------------
-- 1. Antes del primer día: lo ajeno se ve, y corregirlo vuelve 42501 visible (no conflict)
-- ---------------------------------------------------------------------------
select pg_temp.actuar_como(pg_temp.u('b1'));
select is((select count(*) from public.ubicacion where id = pg_temp.u('01')), 1::bigint, 've la casa ajena (campaña por empezar)');
select is((select count(*) from public.espacio where id = pg_temp.u('11')), 1::bigint, 've el espacio ajeno');
select is((select count(*) from public.house_status where ubicacion_id = pg_temp.u('01')), 1::bigint, 've el estado ajeno');

select is(pg_temp.corregir('ubicacion', pg_temp.u('01'), '{"numero": "1 bis"}'), array['invalid 42501'],
          'corregir la casa ajena antes del primer día: invalid 42501, sin server_row ni conflict');
select is(pg_temp.corregir('espacio', pg_temp.u('11'), '{"piso": "3"}'), array['invalid 42501'],
          'corregir el espacio ajeno: invalid 42501');
select is(pg_temp.corregir('house_status', pg_temp.u('01'), '{"color": "SIN_CONTESTAR", "prioridad": 6}'), array['invalid 42501'],
          'corregir el estado ajeno: invalid 42501');
select is(pg_temp.resultados(sync.push(jsonb_build_array(
            pg_temp.job('espacio', 'insert', jsonb_build_object('id', pg_temp.u('13'), 'ubicacion_id', pg_temp.u('01')))))),
          array['invalid 42501'], 'y el depto nuevo, como antes');
select throws_ok(format('update public.ubicacion set numero = %L where id = %L', '1 bis', pg_temp.u('01')),
                 '42501', null, 'por UPDATE directo, la casa ajena: 42501 (antes 0 filas, en silencio)');
select throws_ok(format('update public.espacio set piso = %L where id = %L', '3', pg_temp.u('11')),
                 '42501', null, 'el espacio ajeno: 42501');
select throws_ok(format('update public.house_status set color = %L where ubicacion_id = %L', 'SIN_CONTESTAR', pg_temp.u('01')),
                 '42501', null, 'el estado ajeno: 42501');

select pg_temp.actuar_como_servidor();
select is((select numero from public.ubicacion where id = pg_temp.u('01')), '1', 'la casa quedó como estaba');
select is((select piso from public.espacio where id = pg_temp.u('11')), null, 'el espacio quedó como estaba');
select is((select color from public.house_status where ubicacion_id = pg_temp.u('01')), 'RECHAZO', 'el estado quedó como estaba');

-- Quien no ve la fila (b3, sin campaña) sigue con FILA_INEXISTENTE.
select pg_temp.actuar_como(pg_temp.u('b3'));
select is(pg_temp.resultados(sync.push(jsonb_build_array(
            pg_temp.job('ubicacion', 'update', jsonb_build_object('id', pg_temp.u('01'), 'numero', '1 bis'), 0)))),
          array['invalid FILA_INEXISTENTE'], 'sin campaña no ve la casa: FILA_INEXISTENTE, como antes');

-- ---------------------------------------------------------------------------
-- 2. Con la campaña empezada, lo mismo se acepta
-- ---------------------------------------------------------------------------
select pg_temp.actuar_como_servidor();
select pg_temp.campania_de(current_date - 10, current_date + 30);
select pg_temp.actuar_como(pg_temp.u('b1'));
select is(pg_temp.corregir('ubicacion', pg_temp.u('01'), '{"numero": "1 bis"}'), array['accepted'], 'empezada: corrige la casa ajena');
select is(pg_temp.corregir('espacio', pg_temp.u('11'), '{"piso": "3"}'), array['accepted'], 'empezada: corrige el espacio ajeno');
select is(pg_temp.corregir('house_status', pg_temp.u('01'), '{"color": "SIN_CONTESTAR", "prioridad": 6}'), array['accepted'],
          'empezada: corrige el estado ajeno');

-- ---------------------------------------------------------------------------
-- 3. El autor: solo con la campaña vigente (y los 15 días de gracia)
-- ---------------------------------------------------------------------------
select ok(public.puedo_escribir_en_ubicacion(pg_temp.u('02')), 'con campaña vigente, escribe en la casa que registró');
select is(pg_temp.corregir('espacio', pg_temp.u('12'), '{"piso": "1"}'), array['accepted'], 'vigente: el autor corrige su espacio');
select is(pg_temp.corregir('house_status', pg_temp.u('02'), '{"color": "RECHAZO", "prioridad": 7}'), array['accepted'], 'vigente: y su estado');

select pg_temp.actuar_como_servidor();
select pg_temp.campania_de(pg_temp.hoy() - 90, pg_temp.hoy() - 15);
select pg_temp.actuar_como(pg_temp.u('b1'));
select is(pg_temp.corregir('espacio', pg_temp.u('12'), '{"piso": "2"}'), array['accepted'],
          'terminada hace 15 días (gracia de 0020): el autor sigue corrigiendo');

select pg_temp.actuar_como_servidor();
select pg_temp.campania_de(pg_temp.hoy() - 90, pg_temp.hoy() - 16);
select pg_temp.actuar_como(pg_temp.u('b1'));
select is((select count(*) from public.ubicacion where id = pg_temp.u('02')), 1::bigint, 'terminada hace 16 días: sigue viendo lo que registró');
select ok(not public.puedo_escribir_en_ubicacion(pg_temp.u('02')), 'pero ya no escribe en su casa');
select is(pg_temp.corregir('espacio', pg_temp.u('12'), '{"piso": "3"}'), array['invalid 42501'],
          'terminada hace 16 días: el autor ya no corrige su espacio (invalid 42501, no conflict)');
select is(pg_temp.corregir('house_status', pg_temp.u('02'), '{"color": "SIN_CONTESTAR", "prioridad": 6}'), array['invalid 42501'],
          'ni su estado');
select is(pg_temp.resultados(sync.push(jsonb_build_array(
            pg_temp.job('espacio', 'delete', jsonb_build_object('id', pg_temp.u('12')),
                        (select sync_version from public.espacio where id = pg_temp.u('12')))))),
          array['invalid 42501'], 'ni da de baja su espacio');
select throws_ok(format('update public.espacio set piso = %L where id = %L', '4', pg_temp.u('12')),
                 '42501', null, 'por UPDATE directo, 42501');

select pg_temp.actuar_como_servidor();
select is((select piso from public.espacio where id = pg_temp.u('12')), '2', 'el espacio quedó como estaba');

-- Sin inscripción en ninguna campaña, el autor tampoco escribe.
insert into public.ubicacion (id, tipo, calle, numero, lat, lon, ciudad_id, created_by)
values (pg_temp.u('03'), 'CASA', 'Sin campaña', '3', -34.92, -56.22, pg_temp.u('c1'), pg_temp.u('b3'));
select pg_temp.actuar_como(pg_temp.u('b3'));
select ok(not public.puedo_escribir_en_ubicacion(pg_temp.u('03')), 'sin ninguna campaña, no escribe en la casa que registró');

select * from finish();
rollback;
