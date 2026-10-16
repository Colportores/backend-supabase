-- pgTAP · migración 0020 (backend-supabase#32, decisión del 02/10): las escrituras de un
-- colportor que estuvo inscripto se aceptan hasta 15 días después de que la campaña terminó,
-- contados en la hora de America/Montevideo (la hora UTC no corta antes).
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
  select ('01920000-0000-7000-8000-0000000023' || p)::uuid;
$$;
create or replace function pg_temp.job(p_ent text, p_op text, p_payload jsonb, p_version bigint default null)
returns jsonb language sql as $$
  select jsonb_build_object('client_op_id', gen_random_uuid(), 'entity', p_ent, 'op', p_op,
                            'payload', p_payload, 'sync_version', p_version);
$$;
create or replace function pg_temp.resultados(p_r jsonb) returns text[] language sql as $$
  select array_agg((e ->> 'outcome') || coalesce(' ' || (e ->> 'code'), '') order by i)
    from jsonb_array_elements(p_r -> 'results') with ordinality x(e, i);
$$;
-- Hoy en Montevideo, y la campaña terminada hace p_dias.
create or replace function pg_temp.hoy() returns date language sql as $$
  select (now() at time zone 'America/Montevideo')::date;
$$;
create or replace function pg_temp.terminada_hace(p_dias integer) returns void language sql as $$
  update public.campania set fecha_inicio = pg_temp.hoy() - 90, fecha_fin = pg_temp.hoy() - p_dias
   where id = pg_temp.u('e1');
$$;
-- Un depto nuevo en la casa ajena 01, por el push.
create or replace function pg_temp.depto(p_id text) returns text[] language sql as $$
  select pg_temp.resultados(sync.push(jsonb_build_array(
           pg_temp.job('espacio', 'insert', jsonb_build_object('id', pg_temp.u(p_id), 'ubicacion_id', pg_temp.u('01'))))));
$$;

-- ---------------------------------------------------------------------------
-- 1. La regla, pura: día 15 entra, día 16 no, en la hora de Montevideo
-- ---------------------------------------------------------------------------
select is(public.escritura_dentro_de_plazo(null, now()), true, 'sin fecha de fin, siempre');
select is(public.escritura_dentro_de_plazo('2026-10-01', '2026-10-01 12:00-03'), true, 'el último día');
select is(public.escritura_dentro_de_plazo('2026-10-01', '2026-10-16 00:00-03'), true, 'el día 15, a las 00:00');
select is(public.escritura_dentro_de_plazo('2026-10-01', '2026-10-16 23:59-03'), true,
          'el día 15 a las 23:59 de Montevideo entra, aunque en UTC ya sea el 17 (la hora UTC no corta antes)');
select is(public.escritura_dentro_de_plazo('2026-10-01', '2026-10-17 02:59+00'), true,
          'lo mismo escrito en UTC: 02:59 del 17 en UTC es todavía el día 15 en Montevideo');
select is(public.escritura_dentro_de_plazo('2026-10-01', '2026-10-17 00:00-03'), false, 'el día 16, no');
select is(public.escritura_dentro_de_plazo('2026-10-01', '2026-10-17 03:00+00'), false,
          '03:00 UTC del 17 ya es el día 16 en Montevideo: no');

select ok(not has_function_privilege('authenticated', 'public.escritura_dentro_de_plazo(date, timestamptz)', 'execute'),
          'escritura_dentro_de_plazo es interna');
select ok(not has_function_privilege('authenticated', 'public.mis_campanias_para_escribir()', 'execute'),
          'mis_campanias_para_escribir es interna');
select ok(has_function_privilege('authenticated', 'public.mis_ciudades_de_campania()', 'execute'),
          'mis_ciudades_de_campania conserva sus privilegios');

-- ---------------------------------------------------------------------------
-- 2. Con datos: b1 estuvo en Verano (c1); 01 es una casa ajena de c1
-- ---------------------------------------------------------------------------
insert into auth.users (id, instance_id, aud, role, email, encrypted_password, confirmed_at, created_at, updated_at)
select pg_temp.u(s), '00000000-0000-0000-0000-000000000000',
       'authenticated', 'authenticated', 'gracia-' || s || '@example.com', 'x', now(), now(), now()
  from unnest(array['b1','b2']) s;
insert into public.pais (id, nombre, iso_code) values (pg_temp.u('c0'), 'Pais gracia', 'ZG');
insert into public.ciudad (id, nombre, pais_id, lat_centro, lon_centro)
values (pg_temp.u('c1'), 'Ciudad gracia', pg_temp.u('c0'), -34.9, -56.2);
insert into public.campania (id, nombre, tipo, fecha_inicio, fecha_fin)
values (pg_temp.u('e1'), 'Verano gracia', 'VERANO', current_date - 90, current_date + 30);
insert into public.campania_ciudad (id, campania_id, ciudad_id) values (pg_temp.u('f1'), pg_temp.u('e1'), pg_temp.u('c1'));
insert into public.campania_colportor (campania_id, usuario_id, zona_id, deleted_at) values
  (pg_temp.u('e1'), pg_temp.u('b1'), null, null),
  (pg_temp.u('e1'), pg_temp.u('b2'), null, now());
insert into public.ubicacion (id, tipo, calle, numero, lat, lon, ciudad_id)
values (pg_temp.u('01'), 'CASA', 'Gracia', '1', -34.9, -56.2, pg_temp.u('c1'));

-- El caso de la decisión: vendió sin señal el último día y sincroniza al día siguiente.
select pg_temp.terminada_hace(1);
select pg_temp.actuar_como(pg_temp.u('b1'));
select is(pg_temp.resultados(sync.push(jsonb_build_array(
            pg_temp.job('espacio', 'insert', jsonb_build_object('id', pg_temp.u('11'), 'ubicacion_id', pg_temp.u('01'), 'numero_depto', '2A')),
            pg_temp.job('espacio_persona', 'insert', jsonb_build_object('id', pg_temp.u('21'), 'espacio_id', pg_temp.u('11'),
                                                                        'persona_id', pg_temp.u('31'))),
            pg_temp.job('visita', 'insert', jsonb_build_object('id', pg_temp.u('41'), 'espacio_persona_id', pg_temp.u('21'),
                                                               'fecha', now() - interval '1 day', 'tipo_resultado', 'VENTA')),
            pg_temp.job('venta', 'insert', jsonb_build_object('id', pg_temp.u('51'), 'espacio_persona_id', pg_temp.u('21'),
                                                              'visita_id', pg_temp.u('41'), 'numero_talonario', 'G-1',
                                                              'monto_total', 120000, 'fecha', now() - interval '1 day'))))),
          array['accepted', 'accepted', 'accepted', 'accepted'],
          'al día siguiente del fin, el depto nuevo de una casa ajena, la persona, la visita y la venta entran');

select pg_temp.actuar_como_servidor();
select pg_temp.terminada_hace(15);
select pg_temp.actuar_como(pg_temp.u('b1'));
select is(pg_temp.depto('12'), array['accepted'], 'terminada hace 15 días (día 15): entra');
select is(pg_temp.resultados(sync.push(jsonb_build_array(
            pg_temp.job('espacio', 'update', jsonb_build_object('id', pg_temp.u('11'), 'piso', '2'), 0)))),
          array['accepted'], 'y corrige su espacio (0018 pide campaña vigente: la gracia cuenta)');

select pg_temp.actuar_como_servidor();
select pg_temp.terminada_hace(16);
select pg_temp.actuar_como(pg_temp.u('b1'));
select is(pg_temp.depto('13'), array['invalid 42501'], 'terminada hace 16 días: se rechaza como antes');
select is(pg_temp.resultados(sync.push(jsonb_build_array(
            pg_temp.job('espacio', 'update', jsonb_build_object('id', pg_temp.u('11'), 'piso', '3'), 1)))),
          array['invalid 42501'], 'ni corrige su espacio');

-- Con la inscripción dada de baja no hay gracia (como hoy).
select pg_temp.actuar_como_servidor();
select pg_temp.terminada_hace(1);
select pg_temp.actuar_como(pg_temp.u('b2'));
select is(pg_temp.depto('14'), array['invalid 42501'], 'b2, con la inscripción dada de baja, no escribe');

-- Lo que la gracia no cambia.
select pg_temp.actuar_como(pg_temp.u('b1'));
select is((select count(*) from public.mis_campanias_vigentes()), 0::bigint,
          'la campaña ya no es vigente: el estado de la cuenta, la zona y la inscripción no cambian');
select is((select count(*) from public.ubicacion where id = pg_temp.u('01')), 0::bigint,
          'la lectura tampoco: terminada la campaña, ya no ve la casa ajena');
select is(pg_temp.resultados(sync.push(jsonb_build_array(
            pg_temp.job('ubicacion', 'update', jsonb_build_object('id', pg_temp.u('01'), 'numero', '1 bis'), 0)))),
          array['invalid CG001'],
          'corregir una fila ajena que ya no ve vuelve CG001 (decisión de Cristian del 02/10 en #52), no FILA_INEXISTENTE');

-- Los 15 días: solo entran las ventas y las altas, y las correcciones de lo propio. Lo ajeno que
-- sube después del fin vuelve CG001 (un código propio, que el teléfono distingue del 42501).
select pg_temp.actuar_como_servidor();
insert into public.espacio (id, ubicacion_id, created_by) values (pg_temp.u('16'), pg_temp.u('01'), pg_temp.u('b2'));
insert into public.house_status (ubicacion_id, lat, lon, tipo_ubicacion, color, prioridad, created_by)
values (pg_temp.u('01'), -34.9, -56.2, 'CASA', 'RECHAZO', 7, pg_temp.u('b2'));
select pg_temp.terminada_hace(1);
select pg_temp.actuar_como(pg_temp.u('b1'));
select is(pg_temp.resultados(sync.push(jsonb_build_array(
            pg_temp.job('espacio', 'update', jsonb_build_object('id', pg_temp.u('16'), 'piso', '2'), 0),
            pg_temp.job('house_status', 'update', jsonb_build_object('ubicacion_id', pg_temp.u('01'), 'color', 'SIN_CONTESTAR', 'prioridad', 6), 0),
            pg_temp.job('espacio', 'delete', jsonb_build_object('id', pg_temp.u('16')), 0)))),
          array['invalid CG001', 'invalid CG001', 'invalid CG001'],
          'día 1 después del fin: corregir el depto y el estado ajenos, o dar de baja el depto: CG001');

-- Día 15: la venta propia entra (con su depto, persona y visita), la corrección ajena sigue en CG001.
select pg_temp.actuar_como_servidor();
select pg_temp.terminada_hace(15);
select pg_temp.actuar_como(pg_temp.u('b1'));
select is(pg_temp.resultados(sync.push(jsonb_build_array(
            pg_temp.job('espacio', 'insert', jsonb_build_object('id', pg_temp.u('17'), 'ubicacion_id', pg_temp.u('01'), 'numero_depto', '3C')),
            pg_temp.job('espacio_persona', 'insert', jsonb_build_object('id', pg_temp.u('22'), 'espacio_id', pg_temp.u('17'),
                                                                        'persona_id', pg_temp.u('32'))),
            pg_temp.job('visita', 'insert', jsonb_build_object('id', pg_temp.u('42'), 'espacio_persona_id', pg_temp.u('22'),
                                                               'fecha', now() - interval '15 days', 'tipo_resultado', 'VENTA')),
            pg_temp.job('venta', 'insert', jsonb_build_object('id', pg_temp.u('52'), 'espacio_persona_id', pg_temp.u('22'),
                                                              'visita_id', pg_temp.u('42'), 'numero_talonario', 'G-2',
                                                              'monto_total', 90000, 'fecha', now() - interval '15 days'))))),
          array['accepted', 'accepted', 'accepted', 'accepted'],
          'día 15: la venta propia, con su depto, su persona y su visita, entra');
select is(pg_temp.resultados(sync.push(jsonb_build_array(
            pg_temp.job('espacio', 'update', jsonb_build_object('id', pg_temp.u('16'), 'piso', '2'), 0)))),
          array['invalid CG001'], 'día 15: la corrección ajena sigue en CG001');

-- Día 16: ya no escribe en nada; lo ajeno que no ve vuelve FILA_INEXISTENTE como antes.
select pg_temp.actuar_como_servidor();
select pg_temp.terminada_hace(16);
select pg_temp.actuar_como(pg_temp.u('b1'));
select is(pg_temp.resultados(sync.push(jsonb_build_array(
            pg_temp.job('espacio', 'update', jsonb_build_object('id', pg_temp.u('16'), 'piso', '2'), 0)))),
          array['invalid FILA_INEXISTENTE'], 'día 16: sin gracia, FILA_INEXISTENTE como antes');

-- Con otra campaña en curso que cubre la ciudad, la corrección ajena entra.
select pg_temp.actuar_como_servidor();
select pg_temp.terminada_hace(1);
insert into public.campania (id, nombre, tipo, fecha_inicio, fecha_fin)
values (pg_temp.u('e3'), 'Otoño gracia', 'VERANO', current_date - 10, current_date + 30);
insert into public.campania_ciudad (id, campania_id, ciudad_id) values (pg_temp.u('f3'), pg_temp.u('e3'), pg_temp.u('c1'));
insert into public.campania_colportor (campania_id, usuario_id) values (pg_temp.u('e3'), pg_temp.u('b1'));
select pg_temp.actuar_como(pg_temp.u('b1'));
select is(pg_temp.resultados(sync.push(jsonb_build_array(
            pg_temp.job('espacio', 'update', jsonb_build_object('id', pg_temp.u('16'), 'piso', '2'),
                        (select sync_version from public.espacio where id = pg_temp.u('16')))))),
          array['accepted'], 'con otra campaña en curso en la ciudad, corregir lo ajeno entra (CG001 es solo de la gracia)');
select pg_temp.actuar_como_servidor();
update public.campania_colportor set deleted_at = now() where campania_id = pg_temp.u('e3');
select pg_temp.actuar_como(pg_temp.u('b1'));

-- Una campaña que todavía no empezó tampoco admite escrituras (como hoy).
select pg_temp.actuar_como_servidor();
update public.campania set fecha_inicio = current_date + 5, fecha_fin = current_date + 60 where id = pg_temp.u('e1');
select pg_temp.actuar_como(pg_temp.u('b1'));
select is(pg_temp.depto('15'), array['invalid 42501'], 'antes de que empiece la campaña, no escribe en casas ajenas');

select * from finish();
rollback;
