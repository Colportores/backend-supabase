-- pgTAP · migración 0150 (backend-supabase#206, HU-VEN-001; decisiones de Cristian del 27/10 y 28/10 en
-- front-colportores-mobile#531):
--   1. Talonario: CHECK venta_numero_talonario_forma (1 a 30 caracteres, no bytes; sin espacios ni saltos de
--      línea en los extremos), directo, en el UPDATE y por sync_push (invalid 23514).
--   2. Motivo del monto: si el total de la venta queda por debajo de la suma de los ítems vivos y no hay
--      motivo_monto_manual, 23514. Total igual, total distinto con motivo, total distinto sin motivo; el orden
--      en que llegan la venta y sus ítems (mismo lote y lotes distintos); ítems dados de baja; el UPDATE de la
--      venta y del ítem; el reintento; una venta vieja que ya lo incumple no se toca por otro cambio.
--   3. Privilegios y forma del trigger.
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
  select ('01920000-0000-7000-8000-0000000150' || p)::uuid;
$$;
create or replace function pg_temp.h() returns date language sql as $$
  select public.hoy_montevideo();
$$;
-- SQLSTATE o 'ok' de lo que hace una sentencia (en subtransacción: no deja nada si falla).
create or replace function pg_temp.error_de(p_sql text) returns text language plpgsql as $$
begin
  execute p_sql;
  return 'ok';
exception when others then
  return sqlstate;
end $$;
create or replace function pg_temp.sobre() returns jsonb language sql as $$
  select jsonb_build_object('device_id', '01920000-0000-7000-8000-0000000150d0',
                            'app_version', '1.4.2', 'schema_version', 1);
$$;
create or replace function pg_temp.push(p_jobs jsonb) returns jsonb language sql as $$
  select public.sync_push(jsonb_build_object('device', pg_temp.sobre(), 'jobs', p_jobs));
$$;
create or replace function pg_temp.job(p_op text, p_entidad text, p_payload jsonb) returns jsonb language sql as $$
  select jsonb_build_object('client_op_id', pg_temp.u(p_op), 'entity', p_entidad, 'op', 'insert',
                            'sync_version', null, 'payload', p_payload);
$$;
create or replace function pg_temp.resultados(p_r jsonb) returns text[] language sql as $$
  select array_agg(e ->> 'outcome' order by i) from jsonb_array_elements(p_r -> 'results') with ordinality x(e, i);
$$;
create or replace function pg_temp.codigos(p_r jsonb) returns text[] language sql as $$
  select array_agg(coalesce(e ->> 'code', '-') order by i) from jsonb_array_elements(p_r -> 'results') with ordinality x(e, i);
$$;
create or replace function pg_temp.payload_venta(p_id text, p_talonario text, p_total integer, p_motivo text default null)
returns jsonb language sql as $$
  select jsonb_strip_nulls(jsonb_build_object('id', pg_temp.u(p_id), 'espacio_persona_id', pg_temp.u('ca'),
         'numero_talonario', p_talonario, 'monto_total', p_total, 'fecha', now(), 'motivo_monto_manual', p_motivo));
$$;
-- Un ítem de un solo libro (11): cantidad 1, así que el subtotal es el precio.
create or replace function pg_temp.payload_item(p_id text, p_venta text, p_subtotal integer)
returns jsonb language sql as $$
  select jsonb_build_object('id', pg_temp.u(p_id), 'venta_id', pg_temp.u(p_venta), 'producto_id', pg_temp.u('11'),
                            'cantidad', 1, 'precio_unitario', p_subtotal, 'subtotal', p_subtotal);
$$;
-- Una venta como postgres (sin ítems) y, aparte, un ítem. Devuelven el SQLSTATE o 'ok'.
create or replace function pg_temp.venta(p_id text, p_talonario text, p_total integer, p_motivo text default null)
returns text language plpgsql as $$
begin
  insert into public.venta (id, espacio_persona_id, numero_talonario, monto_total, fecha, colportor_id, motivo_monto_manual)
  values (pg_temp.u(p_id), pg_temp.u('ca'), p_talonario, p_total, now(), pg_temp.u('b1'), p_motivo);
  return 'ok';
exception when others then
  return sqlstate;
end $$;
create or replace function pg_temp.item(p_id text, p_venta text, p_subtotal integer, p_baja boolean default false)
returns text language plpgsql as $$
begin
  insert into public.venta_item (id, venta_id, producto_id, cantidad, precio_unitario, subtotal, deleted_at)
  values (pg_temp.u(p_id), pg_temp.u(p_venta), pg_temp.u('11'), 1, p_subtotal, p_subtotal,
          case when p_baja then now() end);
  return 'ok';
exception when others then
  return sqlstate;
end $$;

-- --- fixtures (como postgres) --------------------------------------------------
-- b1 es colportor inscripto en la campaña e1; b2, otro colportor.
insert into auth.users (id, instance_id, aud, role, email, encrypted_password, confirmed_at, created_at, updated_at)
select pg_temp.u(s), '00000000-0000-0000-0000-000000000000',
       'authenticated', 'authenticated', 'tope150-' || s || '@example.com', 'x', now(), now(), now()
  from unnest(array['b1','b2']) s;
insert into public.usuario_rol (usuario_id, rol_id)
select pg_temp.u(x.s), r.id
  from (values ('b1','COLPORTOR'), ('b2','COLPORTOR')) x(s, codigo)
  join public.rol r on r.codigo = x.codigo;
insert into public.pais (id, nombre, iso_code) values (pg_temp.u('c0'), 'Pais tope150', 'ZK');
insert into public.ciudad (id, nombre, departamento, pais_id, lat_centro, lon_centro) values
  (pg_temp.u('c1'), 'Ciudad c1 tope150', 'Departamento de prueba', pg_temp.u('c0'), -34.90, -56.16);
insert into public.campania (id, nombre, tipo, fecha_inicio, fecha_fin) values
  (pg_temp.u('e1'), 'e1 tope150', 'VERANO', pg_temp.h() - 10, pg_temp.h() + 30);
insert into public.campania_ciudad (id, campania_id, ciudad_id) values
  (pg_temp.u('f1'), pg_temp.u('e1'), pg_temp.u('c1'));
insert into public.campania_colportor (campania_id, usuario_id, zona_id) values
  (pg_temp.u('e1'), pg_temp.u('b1'), null);
insert into public.producto (id, nombre, tipo) values (pg_temp.u('11'), 'Libro 1 t150', 'LIBRO');
insert into public.ubicacion (id, tipo, lat, lon, ciudad_id)
values (pg_temp.u('c8'), 'CASA', -34.88, -56.15, pg_temp.u('c1'));
insert into public.espacio (id, ubicacion_id) values (pg_temp.u('c9'), pg_temp.u('c8'));
insert into public.espacio_persona (id, espacio_id, persona_id)
values (pg_temp.u('ca'), pg_temp.u('c9'), pg_temp.u('cb'));

-- ---------------------------------------------------------------------------
-- 1. Talonario: entre 1 y 30 caracteres, sin espacios ni saltos de línea en los extremos
-- ---------------------------------------------------------------------------
select is((select pg_get_constraintdef(oid) from pg_constraint
            where conrelid = 'public.venta'::regclass and conname = 'venta_numero_talonario_forma'),
          'CHECK ((((char_length(numero_talonario) >= 1) AND (char_length(numero_talonario) <= 30)) AND (numero_talonario ~ ''^\S(.*\S)?$''::text)))',
          'el CHECK del talonario: 1 a 30 caracteres y sin espacios en los extremos');
select is((select convalidated from pg_constraint
            where conrelid = 'public.venta'::regclass and conname = 'venta_numero_talonario_forma'),
          true, 'y está validado (en una base sin talonarios fuera de forma)');

select is(r.est, r.esperado, r.caso)
from (
  select t.caso, t.esperado,
         pg_temp.venta('1' || t.n, t.talonario, 1000) as est
    from (values
      ('0', repeat('a', 30),  'ok',    '30 caracteres: el tope'),
      ('1', repeat('a', 31),  '23514', '31 caracteres: pasa el tope'),
      ('2', 'T',              'ok',    'un caracter'),
      ('3', '',               '23514', 'vacío'),
      ('4', '   ',            '23514', 'solo espacios'),
      ('5', ' T-1',           '23514', 'espacio al principio'),
      ('6', 'T-2 ',           '23514', 'espacio al final'),
      ('7', 'T-3' || E'\n',   '23514', 'salto de línea al final'),
      ('8', E'\t' || 'T-4',   '23514', 'tabulación al principio'),
      ('9', 'T 5',            'ok',    'un espacio adentro vale'),
      ('a', repeat('ñ', 30),  'ok',    '30 caracteres de 2 bytes: se cuentan caracteres y no bytes'),
      ('b', repeat('ñ', 31),  '23514', '31 caracteres de 2 bytes'),
      ('c', repeat('a', 29) || 'z', 'ok', '30 caracteres con la última letra pegada al borde'),
      ('d', E'\n',            '23514', 'solo un salto de línea')
    ) t(n, talonario, esperado, caso)
) r;

-- El UPDATE también.
select is(pg_temp.error_de($$ update public.venta set numero_talonario = repeat('b', 31)
      where id = '01920000-0000-7000-8000-000000015010' $$), '23514', 'el UPDATE a 31 caracteres: rechazado');
select is(pg_temp.error_de($$ update public.venta set numero_talonario = repeat('b', 30)
      where id = '01920000-0000-7000-8000-000000015010' $$), 'ok', 'y a 30 caracteres: vale');

-- Por el push: el lote sigue y cada rechazo vuelve invalid con 23514.
select pg_temp.actuar_como(pg_temp.u('b1'));
create temp table r_push1 on commit drop as
  select pg_temp.push(jsonb_build_array(
    pg_temp.job('01', 'venta', pg_temp.payload_venta('a1', repeat('p', 30), 1000)),
    pg_temp.job('02', 'venta', pg_temp.payload_venta('a2', repeat('p', 31), 1000)),
    pg_temp.job('03', 'venta', pg_temp.payload_venta('a3', ' P-3', 1000)),
    pg_temp.job('04', 'venta', pg_temp.payload_venta('a4', 'P-4', 1000)))) as r;
grant select on r_push1 to authenticated;
select is(pg_temp.resultados((select r from r_push1)), array['accepted', 'invalid', 'invalid', 'accepted'],
          'push: 30 caracteres y uno normal entran; 31 y el que empieza con espacio vuelven invalid');
select is(pg_temp.codigos((select r from r_push1)), array['-', '23514', '23514', '-'], 'los rechazados con 23514');
select pg_temp.actuar_como_servidor();
select is((select count(*)::int from public.venta where id in (pg_temp.u('a2'), pg_temp.u('a3'))), 0,
          'las rechazadas no dejaron nada');

-- ---------------------------------------------------------------------------
-- 2. Motivo del monto: obligatorio si el total queda por debajo de la suma de los ítems
-- ---------------------------------------------------------------------------
select has_trigger('public', 'venta', 'venta_exige_motivo_si_el_total_baja', 'venta tiene el trigger del motivo');
select has_trigger('public', 'venta_item', 'venta_item_exige_motivo_si_el_total_baja', 'y venta_item también');

-- Total igual a la suma: sin motivo, entra (la venta de siempre).
select is(pg_temp.venta('01', 'M-01', 8900), 'ok', 'la venta de $ 8.900 entra sin ítems todavía (no hay con qué compararla)');
select is(pg_temp.item('a1', '01', 8900), 'ok', 'total igual a la suma, sin motivo: entra');

-- El caso de Ana: baja el total de 8.900 a 8.500 y no escribe el motivo.
select is(pg_temp.venta('02', 'M-02', 8500), 'ok', 'la venta de $ 8.500 entra sola: sus ítems todavía no llegaron');
select is(pg_temp.item('a2', '02', 8900), '23514', 'el ítem de $ 8.900 hace pasar la suma del total sin motivo: 23514');
select is((select count(*)::int from public.venta_item where venta_id = pg_temp.u('02')), 0, 'y el ítem rechazado no queda');

-- Total distinto con motivo: entra.
select is(pg_temp.venta('03', 'M-03', 8500, 'descuento por pago en efectivo'), 'ok', 'la venta de $ 8.500 con motivo');
select is(pg_temp.item('a3', '03', 8900), 'ok', 'total distinto con motivo: el ítem entra');

-- Varios ítems: se rechaza el que pasa el total, los anteriores quedan, y uno que vuelve a entrar en el total, entra.
select is(pg_temp.venta('04', 'M-04', 10000), 'ok', 'venta de $ 10.000');
select is(pg_temp.item('a4', '04', 6000), 'ok', 'primer ítem de $ 6.000 (la suma 6.000 no pasa el total)');
select is(pg_temp.item('a5', '04', 5000), '23514', 'segundo de $ 5.000: la suma 11.000 pasa el total');
select is(pg_temp.item('a6', '04', 4000), 'ok', 'uno de $ 4.000 que cierra justo en 10.000: entra');
select is(pg_temp.item('a7', '04', 1), '23514', 'y un peso más ya pasa');

-- El otro sentido NO se rechaza (los ítems todavía pueden estar subiendo): total por encima de la suma.
select is(pg_temp.venta('05', 'M-05', 9500), 'ok', 'venta de $ 9.500');
select is(pg_temp.item('a8', '05', 8900), 'ok', 'con ítems que suman menos que el total y sin motivo: no se decide (falta lo que sube)');

-- Los ítems dados de baja no cuentan.
select is(pg_temp.venta('06', 'M-06', 10000), 'ok', 'venta de $ 10.000 con un ítem dado de baja');
select is(pg_temp.item('a9', '06', 10000), 'ok', 'ítem de $ 10.000');
select is(pg_temp.item('aa', '06', 5000, true), 'ok', 'otro de $ 5.000 ya dado de baja: no cuenta');
select is(pg_temp.error_de($$ update public.venta_item set deleted_at = null
      where id = '01920000-0000-7000-8000-0000000150aa' $$), '23514', 'revivirlo suma 15.000 y falta el motivo: 23514');
select is(pg_temp.error_de($$ update public.venta_item set deleted_at = now()
      where id = '01920000-0000-7000-8000-0000000150a9' $$), 'ok', 'dar de baja un ítem nunca se rechaza');

-- El UPDATE de un ítem: subir su monto.
select is(pg_temp.venta('07', 'M-07', 10000), 'ok', 'venta de $ 10.000 para editar el ítem');
select is(pg_temp.item('b1', '07', 10000), 'ok', 'ítem de $ 10.000');
select is(pg_temp.error_de($$ update public.venta_item set precio_unitario = 12000, subtotal = 12000
      where id = '01920000-0000-7000-8000-0000000150b1' $$), '23514', 'subirle el monto a $ 12.000 pasa el total: 23514');
select is(pg_temp.error_de($$ update public.venta_item set precio_unitario = 9000, subtotal = 9000
      where id = '01920000-0000-7000-8000-0000000150b1' $$), 'ok', 'bajárselo a $ 9.000 vale');
select is(pg_temp.error_de($$ update public.venta_item set updated_at = now()
      where id = '01920000-0000-7000-8000-0000000150b1' $$), 'ok', 'y un UPDATE que no toca montos no mira nada');

-- El UPDATE de la venta: bajar el total o borrar el motivo cuando los ítems ya están.
select is(pg_temp.venta('08', 'M-08', 10000), 'ok', 'venta de $ 10.000 con su ítem');
select is(pg_temp.item('c1', '08', 10000), 'ok', 'ítem de $ 10.000');
select is(pg_temp.error_de($$ update public.venta set monto_total = 9000
      where id = '01920000-0000-7000-8000-000000015008' $$), '23514', 'bajar el total a $ 9.000 sin motivo: 23514');
select is(pg_temp.error_de($$ update public.venta set monto_total = 9000, motivo_monto_manual = 'descuento por pago en efectivo'
      where id = '01920000-0000-7000-8000-000000015008' $$), 'ok', 'bajarlo con el motivo en el mismo UPDATE vale');
select is(pg_temp.error_de($$ update public.venta set motivo_monto_manual = null
      where id = '01920000-0000-7000-8000-000000015008' $$), '23514', 'y borrarle el motivo con el total bajado: 23514');
select is(pg_temp.error_de($$ update public.venta set monto_total = 10000, motivo_monto_manual = null
      where id = '01920000-0000-7000-8000-000000015008' $$), 'ok', 'volver al total de la suma y sin motivo vale');
select is(pg_temp.error_de($$ update public.venta set monto_total = 12000
      where id = '01920000-0000-7000-8000-000000015008' $$), 'ok', 'subir el total por encima de la suma no se rechaza (ver arriba)');

-- Una venta dada de baja no se mira.
select is(pg_temp.error_de($$ update public.venta set monto_total = 5000, deleted_at = now()
      where id = '01920000-0000-7000-8000-000000015008' $$), 'ok', 'dar de baja una venta nunca se rechaza');

-- Una venta anterior que ya lo incumple: un cambio que no toca montos ni motivo no la mira.
alter table public.venta_item disable trigger venta_item_exige_motivo_si_el_total_baja;
select is(pg_temp.venta('09', 'M-09', 5000), 'ok', 'venta de $ 5.000 (simula una venta vieja)');
select is(pg_temp.item('d1', '09', 8000), 'ok', 'con un ítem de $ 8.000 que entró antes de la regla');
alter table public.venta_item enable trigger venta_item_exige_motivo_si_el_total_baja;
select is(pg_temp.error_de($$ update public.venta set espacio_persona_id = '01920000-0000-7000-8000-0000000150ca'
      where id = '01920000-0000-7000-8000-000000015009' $$), 'ok',
          'una venta vieja fuera de regla: mover su espacio_persona (la unión de duplicados) no se rechaza');
select is(pg_temp.error_de($$ update public.venta set monto_total = 5001
      where id = '01920000-0000-7000-8000-000000015009' $$), '23514', 'pero tocar su total sí lo mira');

-- Por el push, como colportor. La venta y los ítems en el mismo lote.
select pg_temp.actuar_como(pg_temp.u('b1'));
create temp table r_push2 on commit drop as
  select pg_temp.push(jsonb_build_array(
    pg_temp.job('11', 'venta', pg_temp.payload_venta('e1', 'P-11', 8900)),
    pg_temp.job('12', 'venta_item', pg_temp.payload_item('e2', 'e1', 8900)),
    pg_temp.job('13', 'venta', pg_temp.payload_venta('e3', 'P-13', 8500)),
    pg_temp.job('14', 'venta_item', pg_temp.payload_item('e4', 'e3', 8900)),
    pg_temp.job('15', 'venta', pg_temp.payload_venta('e5', 'P-15', 8500, 'descuento por pago en efectivo')),
    pg_temp.job('16', 'venta_item', pg_temp.payload_item('e6', 'e5', 8900)),
    pg_temp.job('17', 'venta', pg_temp.payload_venta('e7', 'P-17', 9900)))) as r;
grant select on r_push2 to authenticated;
select is(pg_temp.resultados((select r from r_push2)),
          array['accepted', 'accepted', 'accepted', 'invalid', 'accepted', 'accepted', 'accepted'],
          'push, un lote: total igual entra; total bajado sin motivo, el ítem vuelve invalid; con motivo entra; el lote sigue');
select is(pg_temp.codigos((select r from r_push2)), array['-', '-', '-', '23514', '-', '-', '-'], 'el rechazado con 23514');

-- La venta en un lote y el ítem en el siguiente (el motor parte los lotes a los 500 jobs o 1 MB).
create temp table r_push3 on commit drop as
  select pg_temp.push(jsonb_build_array(
    pg_temp.job('21', 'venta', pg_temp.payload_venta('f1', 'P-21', 8500)),
    pg_temp.job('22', 'venta', pg_temp.payload_venta('f2', 'P-22', 8900)))) as r;
grant select on r_push3 to authenticated;
select is(pg_temp.resultados((select r from r_push3)), array['accepted', 'accepted'],
          'lote 1: las ventas entran aunque sus ítems todavía no llegaron');
create temp table r_push4 on commit drop as
  select pg_temp.push(jsonb_build_array(
    pg_temp.job('23', 'venta_item', pg_temp.payload_item('f3', 'f1', 8900)),
    pg_temp.job('24', 'venta_item', pg_temp.payload_item('f4', 'f2', 5000)),
    pg_temp.job('25', 'venta_item', pg_temp.payload_item('f5', 'f2', 3900)))) as r;
grant select on r_push4 to authenticated;
select is(pg_temp.resultados((select r from r_push4)), array['invalid', 'accepted', 'accepted'],
          'lote 2: el ítem de la venta bajada sin motivo vuelve invalid; los dos ítems de la venta de $ 8.900 (5.000 + 3.900) entran');
select is(pg_temp.codigos((select r from r_push4)), array['23514', '-', '-'], 'con 23514');

-- Un reintento no vuelve a evaluar nada.
create temp table r_push5 on commit drop as
  select pg_temp.push(jsonb_build_array(
    pg_temp.job('24', 'venta_item', pg_temp.payload_item('f4', 'f2', 5000)))) as r;
grant select on r_push5 to authenticated;
select is(pg_temp.resultados((select r from r_push5)), array['duplicate'], 'el reintento del mismo job es duplicate');
select pg_temp.actuar_como_servidor();
select is((select count(*)::int from public.venta_item where venta_id in (pg_temp.u('e1'), pg_temp.u('e5'), pg_temp.u('f2'))), 4,
          'quedaron los ítems buenos (1 + 1 + 2) y ninguno repetido');
select is((select count(*)::int from public.venta_item where id in (pg_temp.u('e4'), pg_temp.u('f3'))), 0,
          'y los dos ítems de ventas bajadas sin motivo no entraron');

-- ---------------------------------------------------------------------------
-- 3. Privilegios y forma de la función
-- ---------------------------------------------------------------------------
select is(has_function_privilege('anon', 'public.tg_venta_exige_motivo_si_el_total_baja()', 'execute'), false, 'anon no ejecuta el trigger');
select is(has_function_privilege('authenticated', 'public.tg_venta_exige_motivo_si_el_total_baja()', 'execute'), false, 'authenticated tampoco');
select is(has_function_privilege('service_role', 'public.tg_venta_exige_motivo_si_el_total_baja()', 'execute'), false, 'ni service_role');
select is((select prosecdef from pg_proc where oid = 'public.tg_venta_exige_motivo_si_el_total_baja()'::regprocedure), true,
          'es DEFINER: suma todos los ítems sin importar la RLS');
select is((select proconfig from pg_proc where oid = 'public.tg_venta_exige_motivo_si_el_total_baja()'::regprocedure),
          array['search_path=""'], 'con el search_path vacío');

select * from finish();
rollback;
