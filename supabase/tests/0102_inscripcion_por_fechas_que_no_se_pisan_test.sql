-- pgTAP · inscripción por fechas que no se pisan y cuenta activa desde que lo suman (migración 0102,
-- backend-supabase#142, decisiones de Cristian del 23/10 «Dos por empezar» y «Cuenta antes»)
--   1. El caso de Marta y Agustín: en la campaña de invierno y, cuando termine, en la de primavera.
--   2. Las fechas que se pisan: CI007 con el nombre y las fechas de la otra; el borde (el último día de
--      una es el primero de la otra); si hay más de una, la que empezó más tarde; el detail trae las fechas.
--   3. Campaña sin fecha de fin = abierta (ante la duda se bloquea); entre dos campañas hay lugar.
--   4. Lo que no cuenta: una inscripción dada de baja, una campaña terminada o borrada; la reactivación sí mira.
--   5. El estado de la cuenta (estado_cuenta(), colportores_de_campania(), buscar_candidatos()): ACTIVA con
--      una inscripción en una campaña que no terminó, también la que no empezó; los sugeridos no la traen.
--   6. Privilegios de las funciones nuevas.
--   7. El servidor rechaza una venta anterior al inicio de la campaña (política venta_no_antes_del_inicio):
--      directo, por sync_push, los bordes y lo que no se rechaza (corregir, vender en curso, venta tardía,
--      sin inscripciones, inscripción dada de baja).
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

-- El DETAIL de un error (lo que PostgREST devuelve en `details`); throws_ok no lo mira.
create or replace function pg_temp.detalle_error(p_sql text) returns text language plpgsql as $$
declare
  v_detalle text;
begin
  execute p_sql;
  return null;
exception when others then
  get stacked diagnostics v_detalle = pg_exception_detail;
  return v_detalle;
end $$;

-- SQLSTATE o 'ok' de lo que hace una sentencia (en subtransacción: no deja nada si falla).
create or replace function pg_temp.error_de(p_sql text) returns text language plpgsql as $$
begin
  execute p_sql;
  return 'ok';
exception when others then
  return sqlstate;
end $$;

create or replace function pg_temp.u(p_sufijo text) returns uuid language sql immutable as $$
  select ('01920000-0000-7000-8000-0000000102' || p_sufijo)::uuid
$$;

-- Hoy en Montevideo.
create or replace function pg_temp.hoy() returns date language sql stable as $$
  select (now() at time zone 'America/Montevideo')::date
$$;

-- El día como lo escribe el aviso.
create or replace function pg_temp.dm(p_dias integer) returns text language sql stable as $$
  select to_char(pg_temp.hoy() + p_dias, 'DD/MM')
$$;

create or replace function pg_temp.push(p_jobs jsonb) returns jsonb language sql as $$
  select public.sync_push(jsonb_build_object(
    'device', jsonb_build_object('device_id', '01920000-0000-7000-8000-0000000102d0',
                                 'app_version', '1.4.2', 'schema_version', 1),
    'jobs', p_jobs));
$$;
create or replace function pg_temp.job(p_op text, p_payload jsonb) returns jsonb language sql as $$
  select jsonb_build_object('client_op_id', pg_temp.u(p_op), 'entity', 'venta', 'op', 'insert',
                            'sync_version', null, 'payload', p_payload);
$$;
create or replace function pg_temp.payload_venta(p_id text, p_talonario text, p_fecha timestamptz)
returns jsonb language sql as $$
  select jsonb_build_object('id', pg_temp.u(p_id), 'espacio_persona_id', pg_temp.u('d4'),
         'numero_talonario', p_talonario, 'monto_total', 85000, 'fecha', p_fecha);
$$;
create or replace function pg_temp.resultados(p_r jsonb) returns text[] language sql as $$
  select array_agg(e ->> 'outcome' order by i) from jsonb_array_elements(p_r -> 'results') with ordinality x(e, i);
$$;
create or replace function pg_temp.codigos(p_r jsonb) returns text[] language sql as $$
  select array_agg(coalesce(e ->> 'code', '-') order by i) from jsonb_array_elements(p_r -> 'results') with ordinality x(e, i);
$$;

-- Una venta como el colportor logueado (RLS), con la fecha que se le pasa.
create or replace function pg_temp.vender(p_id text, p_talonario text, p_fecha timestamptz) returns text
language plpgsql as $$
begin
  insert into public.venta (id, espacio_persona_id, numero_talonario, monto_total, fecha)
  values (pg_temp.u(p_id), pg_temp.u('d4'), p_talonario, 10000, p_fecha);
  return 'ok';
exception when others then
  return sqlstate;
end $$;

-- --- fixtures (como postgres, sin RLS) -----------------------------------------
-- a0 ADMIN (inscribe en todas). Campañas (hoy = día de Montevideo):
--   c1 Invierno      hoy-10 .. hoy+20      c2 Primavera     hoy+21 .. hoy+80  (empieza el día después de c1)
--   c3 Pisa el borde hoy+20 .. hoy+60      (empieza el último día de c1 y se pisa con c2)
--   c4 Abierta       hoy+100 .. sin fin    c5 Lejana        hoy+200 .. hoy+260
--   c6 Terminada     hoy-90 .. hoy-30      c7 Borrada       hoy+30 .. hoy+60 (deleted_at)
--   c9 Hueco         hoy+81 .. hoy+99      (entre c2 y c4)  ca Mañana        hoy+1 .. hoy+40
--   cb Terminada pisada  hoy-20 .. hoy-5   (terminó, pero sus fechas se pisaban con Invierno)
--   cc Abierta ya empezada  hoy-5 .. sin fin
-- Colportores (verificados):
--   b1 en c1 (Agustín)   b2 en c1   b4 en c4   b5 en c5   b6 en c6 (terminada)   b7 con baja en c1
--   b8 en c7 (borrada)   b0 en c2 y c9   b9 en cb (terminada pisada)
--   estado de la cuenta: ba sin inscripción · bb solo en c6 (terminada) · bc solo con baja en c1 · bd solo en c7
--   (borrada) · be solo en c2 (por empezar) · bf solo en c1 (en curso) · b3 suspendido y en c2
--   ventas: e1 en ca (empieza mañana) y c2 · e2 en c1 y c2 · e3 en c6 y c2 · e4 con baja en c1 y en c2 · e5 sin
--   inscripción · e6 solo con baja en c2 · e7 solo en c7 (borrada, futura) · e8 en cc (abierta, ya empezada) y c2
insert into auth.users (id, instance_id, aud, role, email, encrypted_password, confirmed_at, created_at, updated_at)
select pg_temp.u(s), '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
       'fechas102-' || s || '@example.com', 'x', now(), now(), now()
  from unnest(array['a0','b1','b2','b3','b4','b5','b6','b7','b8','b9','ba','bb','bc','bd','be','bf','b0',
                    'e1','e2','e3','e4','e5','e6','e7','e8']) s;

insert into public.usuario_rol (usuario_id, rol_id)
select pg_temp.u('a0'), r.id from public.rol r where r.codigo = 'ADMIN';

update public.usuario set suspendido_en = now() where id = pg_temp.u('b3');

insert into public.pais (id, nombre, iso_code) values (pg_temp.u('d0'), 'Pais fechas102', 'ZL');
insert into public.ciudad (id, nombre, departamento, pais_id, lat_centro, lon_centro) values
  (pg_temp.u('d1'), 'Ciudad fechas102', 'Departamento de prueba', pg_temp.u('d0'), -34.9, -56.16);

insert into public.campania (id, nombre, tipo, fecha_inicio, fecha_fin, deleted_at) values
  (pg_temp.u('c1'), 'Invierno',       'INVIERNO',   pg_temp.hoy() - 10,  pg_temp.hoy() + 20,  null),
  (pg_temp.u('c2'), 'Primavera',      'VERANO',     pg_temp.hoy() + 21,  pg_temp.hoy() + 80,  null),
  (pg_temp.u('c3'), 'Pisa el borde',  'VERANO',     pg_temp.hoy() + 20,  pg_temp.hoy() + 60,  null),
  (pg_temp.u('c4'), 'Abierta',        'PERMANENTE', pg_temp.hoy() + 100, null,                null),
  (pg_temp.u('c5'), 'Lejana',         'VERANO',     pg_temp.hoy() + 200, pg_temp.hoy() + 260, null),
  (pg_temp.u('c6'), 'Terminada',      'VERANO',     pg_temp.hoy() - 90,  pg_temp.hoy() - 30,  null),
  (pg_temp.u('c7'), 'Borrada',        'VERANO',     pg_temp.hoy() + 30,  pg_temp.hoy() + 60,  now()),
  (pg_temp.u('c9'), 'Hueco',          'VERANO',     pg_temp.hoy() + 81,  pg_temp.hoy() + 99,  null),
  (pg_temp.u('ca'), 'Manana',         'VERANO',     pg_temp.hoy() + 1,   pg_temp.hoy() + 40,  null),
  (pg_temp.u('cb'), 'Terminada pisada', 'VERANO',   pg_temp.hoy() - 20,  pg_temp.hoy() - 5,   null),
  (pg_temp.u('cc'), 'Abierta empezada', 'PERMANENTE', pg_temp.hoy() - 5, null,                null);

-- Con inscripción de baja: deleted_at; las demás, vivas.
insert into public.campania_colportor (campania_id, usuario_id, deleted_at) values
  (pg_temp.u('c1'), pg_temp.u('b1'), null),
  (pg_temp.u('c1'), pg_temp.u('b2'), null),
  (pg_temp.u('c4'), pg_temp.u('b4'), null),
  (pg_temp.u('c5'), pg_temp.u('b5'), null),
  (pg_temp.u('c6'), pg_temp.u('b6'), null),
  (pg_temp.u('c1'), pg_temp.u('b7'), now()),
  (pg_temp.u('c7'), pg_temp.u('b8'), null),
  (pg_temp.u('cb'), pg_temp.u('b9'), null),
  (pg_temp.u('c2'), pg_temp.u('b0'), null),
  (pg_temp.u('c9'), pg_temp.u('b0'), null),
  (pg_temp.u('c6'), pg_temp.u('bb'), null),
  (pg_temp.u('c1'), pg_temp.u('bc'), now()),
  (pg_temp.u('c7'), pg_temp.u('bd'), null),
  (pg_temp.u('c2'), pg_temp.u('be'), null),
  (pg_temp.u('c1'), pg_temp.u('bf'), null),
  (pg_temp.u('c2'), pg_temp.u('b3'), null),
  (pg_temp.u('ca'), pg_temp.u('e1'), null),
  (pg_temp.u('c2'), pg_temp.u('e1'), null),
  (pg_temp.u('c2'), pg_temp.u('e6'), now()),
  (pg_temp.u('c7'), pg_temp.u('e7'), null),
  (pg_temp.u('cc'), pg_temp.u('e8'), null),
  (pg_temp.u('c2'), pg_temp.u('e8'), null),
  (pg_temp.u('c1'), pg_temp.u('e2'), null),
  (pg_temp.u('c2'), pg_temp.u('e2'), null),
  (pg_temp.u('c6'), pg_temp.u('e3'), null),
  (pg_temp.u('c2'), pg_temp.u('e3'), null),
  (pg_temp.u('c1'), pg_temp.u('e4'), now()),
  (pg_temp.u('c2'), pg_temp.u('e4'), null);

-- Una casa y un vínculo para las ventas.
insert into public.ubicacion (id, tipo, lat, lon, ciudad_id)
values (pg_temp.u('d2'), 'CASA', -34.88, -56.15, pg_temp.u('d1'));
insert into public.espacio (id, ubicacion_id) values (pg_temp.u('d3'), pg_temp.u('d2'));
insert into public.espacio_persona (id, espacio_id, persona_id)
values (pg_temp.u('d4'), pg_temp.u('d3'), pg_temp.u('d5'));

-- ---------------------------------------------------------------------------
-- 1. Marta y Agustín: la campaña de invierno y, después, la de primavera
-- ---------------------------------------------------------------------------
select pg_temp.actuar_como(pg_temp.u('a0'));

select lives_ok(
  format($$ select public.inscribir_colportor(%L, %L) $$, pg_temp.u('c2'), pg_temp.u('b1')),
  'b1 está en Invierno (hasta hoy+20) y lo suman a Primavera (desde hoy+21): las fechas no se pisan');
select throws_ok(
  format($$ select public.inscribir_colportor(%L, %L) $$, pg_temp.u('c2'), pg_temp.u('b1')),
  'CI006', null, 'volver a sumarlo a la misma: CI006');
select results_eq(
  format($$ select usuario_id, estado from public.colportores_de_campania(%L) where usuario_id = %L $$,
         pg_temp.u('c2'), pg_temp.u('b1')),
  format($$ values (%L::uuid, 'ACTIVA'::text) $$, pg_temp.u('b1')),
  'figura en Primavera, que no empezó, con la cuenta ACTIVA');

-- ---------------------------------------------------------------------------
-- 2. Las fechas que se pisan
-- ---------------------------------------------------------------------------
-- b2 solo está en Invierno (hoy-10 .. hoy+20). Pisa Invierno la campaña que empieza el último día.
select throws_ok(
  format($$ select public.inscribir_colportor(%L, %L) $$, pg_temp.u('c3'), pg_temp.u('b2')),
  'CI007',
  'Está en la campaña Invierno (del ' || pg_temp.dm(-10) || ' al ' || pg_temp.dm(20)
    || '). Elegí otra campaña o quitalo de esa primero.',
  'el último día de Invierno es el primero de Pisa el borde: se pisan, y el aviso nombra la campaña y sus fechas');
select is(
  pg_temp.detalle_error(format($$ select public.inscribir_colportor(%L, %L) $$, pg_temp.u('c3'), pg_temp.u('b2')))::jsonb,
  jsonb_build_object('campania_id', pg_temp.u('c1'), 'campania_nombre', 'Invierno',
                     'fecha_inicio', to_char(pg_temp.hoy() - 10, 'YYYY-MM-DD'),
                     'fecha_fin', to_char(pg_temp.hoy() + 20, 'YYYY-MM-DD')),
  'CI007 trae en details la campaña, su inicio y su fin');
-- b1 está en Invierno y en Primavera, y Pisa el borde se pisa con las dos: nombra la que empezó más tarde.
select throws_ok(
  format($$ select public.inscribir_colportor(%L, %L) $$, pg_temp.u('c3'), pg_temp.u('b1')),
  'CI007',
  'Está en la campaña Primavera (del ' || pg_temp.dm(21) || ' al ' || pg_temp.dm(80)
    || '). Elegí otra campaña o quitalo de esa primero.',
  'si se pisa con dos, el aviso nombra la que empezó más tarde');
select pg_temp.actuar_como_servidor();
select is((select count(*) from public.campania_colportor
            where usuario_id = pg_temp.u('b1') and deleted_at is null), 2::bigint,
          'el rechazo no dejó nada: b1 sigue en dos campañas');
select pg_temp.actuar_como(pg_temp.u('a0'));

-- ---------------------------------------------------------------------------
-- 3. Sin fecha de fin y los huecos entre campañas
-- ---------------------------------------------------------------------------
-- b4 está en Abierta (desde hoy+100, sin fin): se pisa con toda campaña que empiece después.
select throws_ok(
  format($$ select public.inscribir_colportor(%L, %L) $$, pg_temp.u('c5'), pg_temp.u('b4')),
  'CI007',
  'Está en la campaña Abierta (desde el ' || pg_temp.dm(100) || ', sin fecha de fin). '
    || 'Elegí otra campaña o quitalo de esa primero.',
  'una campaña sin fecha de fin cuenta como abierta: se pisa con una que empieza después');
select is(
  pg_temp.detalle_error(format($$ select public.inscribir_colportor(%L, %L) $$, pg_temp.u('c5'), pg_temp.u('b4')))::jsonb,
  jsonb_build_object('campania_id', pg_temp.u('c4'), 'campania_nombre', 'Abierta',
                     'fecha_inicio', to_char(pg_temp.hoy() + 100, 'YYYY-MM-DD'), 'fecha_fin', null),
  'y el detail trae fecha_fin null');
select lives_ok(
  format($$ select public.inscribir_colportor(%L, %L) $$, pg_temp.u('c9'), pg_temp.u('b4')),
  'pero antes de que empiece Abierta hay lugar: Hueco (hoy+81 .. hoy+99) no se pisa');
select lives_ok(
  format($$ select public.inscribir_colportor(%L, %L) $$, pg_temp.u('c2'), pg_temp.u('b4')),
  'y Primavera tampoco: queda anotado en tres campañas seguidas');
-- El otro orden: b5 está en Lejana (hoy+200 .. hoy+260) y lo suman a la abierta que empieza antes.
select throws_ok(
  format($$ select public.inscribir_colportor(%L, %L) $$, pg_temp.u('c4'), pg_temp.u('b5')),
  'CI007',
  'Está en la campaña Lejana (del ' || pg_temp.dm(200) || ' al ' || pg_temp.dm(260)
    || '). Elegí otra campaña o quitalo de esa primero.',
  'sumarlo a la abierta cuando ya está en una que empieza después: se pisan');

-- ---------------------------------------------------------------------------
-- 4. Lo que no cuenta, y la reactivación
-- ---------------------------------------------------------------------------
select lives_ok(
  format($$ select public.inscribir_colportor(%L, %L) $$, pg_temp.u('c1'), pg_temp.u('b6')),
  'una inscripción en una campaña terminada no cuenta');
select lives_ok(
  format($$ select public.inscribir_colportor(%L, %L) $$, pg_temp.u('c1'), pg_temp.u('b9')),
  'una campaña que ya terminó no cuenta aunque sus fechas se pisaran con las de Invierno');
select lives_ok(
  format($$ select public.inscribir_colportor(%L, %L) $$, pg_temp.u('c3'), pg_temp.u('b8')),
  'una inscripción en una campaña borrada no cuenta');
select lives_ok(
  format($$ select public.inscribir_colportor(%L, %L) $$, pg_temp.u('c3'), pg_temp.u('b7')),
  'una inscripción dada de baja en Invierno no cuenta: b7 se suma a Pisa el borde');
select throws_ok(
  format($$ select public.inscribir_colportor(%L, %L) $$, pg_temp.u('c1'), pg_temp.u('b7')),
  'CI007',
  'Está en la campaña Pisa el borde (del ' || pg_temp.dm(20) || ' al ' || pg_temp.dm(60)
    || '). Elegí otra campaña o quitalo de esa primero.',
  'reactivarlo en Invierno mira las fechas igual: ahora está en Pisa el borde');
select pg_temp.actuar_como_servidor();
select is((select deleted_at is not null from public.campania_colportor
            where campania_id = pg_temp.u('c1') and usuario_id = pg_temp.u('b7')), true,
          'y la inscripción dada de baja sigue de baja');
select pg_temp.actuar_como(pg_temp.u('a0'));
-- Una terminada no se puede, como siempre (CI002).
select throws_ok(
  format($$ select public.inscribir_colportor(%L, %L) $$, pg_temp.u('c6'), pg_temp.u('b9')),
  'CI002', 'La campaña ya terminó. Elegí una campaña en curso o por empezar.', 'la terminada sigue siendo CI002');

-- ---------------------------------------------------------------------------
-- 5. El estado de la cuenta
-- ---------------------------------------------------------------------------
select pg_temp.actuar_como(pg_temp.u('ba'));
select is(public.estado_cuenta(), 'PENDIENTE_ASIGNACION', 'sin inscripción: PENDIENTE_ASIGNACION');
select pg_temp.actuar_como(pg_temp.u('bb'));
select is(public.estado_cuenta(), 'PENDIENTE_ASIGNACION', 'solo en una campaña terminada: PENDIENTE_ASIGNACION');
select pg_temp.actuar_como(pg_temp.u('bc'));
select is(public.estado_cuenta(), 'PENDIENTE_ASIGNACION', 'solo con la inscripción dada de baja: PENDIENTE_ASIGNACION');
select pg_temp.actuar_como(pg_temp.u('bd'));
select is(public.estado_cuenta(), 'PENDIENTE_ASIGNACION', 'solo en una campaña borrada: PENDIENTE_ASIGNACION');
select pg_temp.actuar_como(pg_temp.u('be'));
select is(public.estado_cuenta(), 'ACTIVA', 'solo en una campaña por empezar: ACTIVA desde que lo suman');
select pg_temp.actuar_como(pg_temp.u('bf'));
select is(public.estado_cuenta(), 'ACTIVA', 'en una campaña en curso: ACTIVA');
select pg_temp.actuar_como(pg_temp.u('b3'));
select is(public.estado_cuenta(), 'SUSPENDIDA', 'suspendido y en una por empezar: SUSPENDIDA gana');

-- La lista del panel: la de Primavera (por empezar) trae ACTIVA para quien está inscripto.
select pg_temp.actuar_como(pg_temp.u('a0'));
select results_eq(
  format($$ select usuario_id, estado from public.colportores_de_campania(%L)
             where usuario_id in (%L, %L, %L) order by usuario_id $$, pg_temp.u('c2'),
         pg_temp.u('b3'), pg_temp.u('be'), pg_temp.u('b0')),
  format($$ values (%L::uuid, 'ACTIVA'::text), (%L::uuid, 'SUSPENDIDA'::text), (%L::uuid, 'ACTIVA'::text) $$,
         pg_temp.u('b0'), pg_temp.u('b3'), pg_temp.u('be')),
  'colportores_de_campania() de una campaña por empezar: ACTIVA, y la suspendida SUSPENDIDA');

-- buscar_candidatos() en Primavera: bf está en Invierno (no se pisa) y es ACTIVA y candidata sin bloqueo;
-- los sugeridos son solo los PENDIENTE_ASIGNACION.
select results_eq(
  format($$ select usuario_id, estado, campania_actual, motivo_bloqueo
             from public.buscar_candidatos(%L, 'fechas102-bf@') $$, pg_temp.u('c2')),
  format($$ values (%L::uuid, 'ACTIVA'::text, 'Invierno'::text, null::text) $$, pg_temp.u('bf')),
  'en Primavera, bf (en Invierno) es ACTIVA, muestra su campaña y no tiene motivo de bloqueo');
select is(
  (select count(*) from public.buscar_candidatos(pg_temp.u('c2')) where estado <> 'PENDIENTE_ASIGNACION'),
  0::bigint, 'los sugeridos son solo cuentas pendientes de asignación');
select is(
  (select count(*) from public.buscar_candidatos(pg_temp.u('c5'))
    where usuario_id in (pg_temp.u('bf'), pg_temp.u('be'), pg_temp.u('b0'), pg_temp.u('b1'))),
  0::bigint, 'y no sale entre los sugeridos de otras campañas quien ya está en una por empezar o en curso');
-- Bloqueado por fechas: bf en Pisa el borde (hoy+20 ..) se pisa con Invierno; la campaña que se muestra es la que bloquea.
select results_eq(
  format($$ select usuario_id, estado, campania_actual, motivo_bloqueo
             from public.buscar_candidatos(%L, 'fechas102-bf@') $$, pg_temp.u('c3')),
  format($$ values (%L::uuid, 'ACTIVA'::text, 'Invierno'::text, 'EN_OTRA_CAMPANIA'::text) $$, pg_temp.u('bf')),
  'en Pisa el borde, bf sale ACTIVA, con Invierno y bloqueado por EN_OTRA_CAMPANIA');
-- b1 está en Invierno (en curso) y en Primavera (por empezar): en Pisa el borde las dos bloquean y el
-- aviso nombra Primavera; la campaña que se muestra es esa y no la que está en curso.
select results_eq(
  format($$ select usuario_id, campania_actual, motivo_bloqueo
             from public.buscar_candidatos(%L, 'fechas102-b1@') $$, pg_temp.u('c3')),
  format($$ values (%L::uuid, 'Primavera'::text, 'EN_OTRA_CAMPANIA'::text) $$, pg_temp.u('b1')),
  'bloqueado por dos: se muestra la que nombra CI007 (Primavera), no la que está en curso');
-- Qué campaña se muestra sin bloqueo: la en curso, y si no la que empieza antes.
select results_eq(
  format($$ select usuario_id, campania_actual, motivo_bloqueo
             from public.buscar_candidatos(%L, 'fechas102-b1@') $$, pg_temp.u('c5')),
  format($$ values (%L::uuid, 'Invierno'::text, null::text) $$, pg_temp.u('b1')),
  'b1 (en Invierno, en curso, y en Primavera): sin bloqueo en Lejana; se muestra la en curso');
select results_eq(
  format($$ select usuario_id, campania_actual, motivo_bloqueo
             from public.buscar_candidatos(%L, 'fechas102-b0@') $$, pg_temp.u('c5')),
  format($$ values (%L::uuid, 'Primavera'::text, null::text) $$, pg_temp.u('b0')),
  'b0 (en Primavera y en Hueco, las dos por empezar): se muestra la que empieza antes');

-- ---------------------------------------------------------------------------
-- 6. Privilegios
-- ---------------------------------------------------------------------------
select ok(not has_function_privilege('authenticated', 'public.inscripciones_no_terminadas_de(uuid)', 'execute'),
          'authenticated NO ejecuta inscripciones_no_terminadas_de(): no se averigua en qué campaña está otro');
select ok(not has_function_privilege('anon', 'public.inscripciones_no_terminadas_de(uuid)', 'execute'),
          'anon tampoco');
select ok(has_function_privilege('service_role', 'public.inscripciones_no_terminadas_de(uuid)', 'execute'),
          'service_role sí');
select ok(has_function_privilege('authenticated', 'public.tengo_inscripcion_no_terminada()', 'execute'),
          'authenticated ejecuta tengo_inscripcion_no_terminada() (la llama estado_cuenta(), INVOKER)');
select ok(not has_function_privilege('anon', 'public.tengo_inscripcion_no_terminada()', 'execute'),
          'anon no');
select ok(has_function_privilege('authenticated', 'public.venta_antes_del_inicio(timestamptz)', 'execute'),
          'authenticated ejecuta venta_antes_del_inicio() (la evalúa la política)');
select ok(not has_function_privilege('anon', 'public.venta_antes_del_inicio(timestamptz)', 'execute'),
          'anon no');
select is((select prosecdef from pg_proc where oid = 'public.estado_cuenta()'::regprocedure),
          false, 'estado_cuenta() sigue siendo SECURITY INVOKER');
select is((select polpermissive from pg_policy where polname = 'venta_no_antes_del_inicio'
              and polrelid = 'public.venta'::regclass),
          false, 'venta_no_antes_del_inicio es RESTRICTIVE: se suma a la política del colportor, no la reemplaza');
select is((select polcmd from pg_policy where polname = 'venta_no_antes_del_inicio'
              and polrelid = 'public.venta'::regclass),
          'a', 'y es solo de INSERT');

-- ---------------------------------------------------------------------------
-- 7. El servidor rechaza una venta antes del inicio de la campaña
-- ---------------------------------------------------------------------------
-- e1 está en Mañana (empieza mañana) y en Primavera (hoy+21): hoy es antes del inicio de las dos.
select pg_temp.actuar_como(pg_temp.u('e1'));
select is(pg_temp.vender('f1', 'T-1', now()), '42501', 'e1 (en dos campañas que no empezaron): vender hoy, 42501');
select is(pg_temp.vender('f0', 'T-0', ((pg_temp.hoy())::timestamp + interval '22 hours') at time zone 'America/Montevideo'),
          '42501', 'a las 22:00 de Montevideo (01:00 UTC de mañana) todavía es hoy: 42501, el día se cuenta en Montevideo');
select is(pg_temp.vender('f2', 'T-2', now() + interval '1 day'), 'ok',
          'el día que empieza Mañana ya no es antes del inicio, aunque Primavera siga sin empezar');
select pg_temp.actuar_como_servidor();
select is((select count(*) from public.venta where colportor_id = pg_temp.u('e1')), 1::bigint,
          'de las dos quedó la del día de inicio: la rechazada no dejó nada');
select pg_temp.actuar_como(pg_temp.u('e1'));
-- Corregir una venta que ya existe no se mira: solo el alta.
select is(pg_temp.error_de(format($$ update public.venta set monto_total = 20000 where id = %L $$, pg_temp.u('f2'))),
          'ok', 'corregir la venta que ya existe no se rechaza');

-- Por el sync, que es el camino real: la rechazada vuelve invalid con 42501 y el lote sigue.
create temp table r_push on commit drop as
  select pg_temp.push(jsonb_build_array(
    pg_temp.job('01', pg_temp.payload_venta('f3', 'T-3', now())),
    pg_temp.job('02', pg_temp.payload_venta('f4', 'T-4', now() + interval '1 day')))) as r;
grant select on r_push to authenticated;
select is(pg_temp.resultados((select r from r_push)), array['invalid', 'accepted'],
          'sync_push: la venta de hoy vuelve invalid y la del día de inicio entra');
select is(pg_temp.codigos((select r from r_push)), array['42501', '-'], 'con 42501');

-- e2 está en Invierno (en curso) y en Primavera (por empezar): vende hoy.
select pg_temp.actuar_como(pg_temp.u('e2'));
select is(pg_temp.vender('f5', 'T-5', now()), 'ok', 'e2 (en curso y por empezar): vender hoy, ok');

-- e3: Terminada (terminó hace 30 días) y Primavera (por empezar).
select pg_temp.actuar_como(pg_temp.u('e3'));
select is(pg_temp.vender('f6', 'T-6', now()), '42501', 'e3: hoy no hay campaña empezada y pasa del plazo, 42501');
select is(pg_temp.vender('f7', 'T-7', now() - interval '60 days'), 'ok',
          'una venta tardía de dentro de Terminada (hoy-60) no se pierde');
select is(pg_temp.vender('f8', 'T-8', now() - interval '20 days'), 'ok',
          'ni la de los 15 días de gracia después de que terminó (hoy-20; Terminada acabó en hoy-30)');
select is(pg_temp.vender('a4', 'T-8B', now() - interval '15 days'), 'ok', 'el día 15 de la gracia todavía entra');
select is(pg_temp.vender('f9', 'T-9', now() - interval '14 days'), '42501', 'el día 16 ya no: 42501');
select is(pg_temp.vender('f9', 'T-9', now() - interval '10 days'), '42501',
          'pasado el plazo de Terminada (hoy-10) y antes de Primavera, 42501');

-- e4: dada de baja en Invierno (en curso) y por empezar en Primavera: la inscripción de baja cubre hoy.
select pg_temp.actuar_como(pg_temp.u('e4'));
select is(pg_temp.vender('fa', 'T-A', now()), 'ok',
          'e4 (de baja en Invierno, que ya empezó): una venta que ya existe en el teléfono no se pierde');

-- e6 solo tiene una inscripción dada de baja en una campaña futura; e7 una viva en una campaña borrada: no cuentan.
select pg_temp.actuar_como(pg_temp.u('e6'));
select is(pg_temp.vender('a1', 'T-E', now()), 'ok', 'e6 (de baja en una campaña que no empezó): vender, ok');
select pg_temp.actuar_como(pg_temp.u('e7'));
select is(pg_temp.vender('a2', 'T-F', now()), 'ok', 'e7 (solo en una campaña borrada): vender, ok');
-- e8 está en una abierta que ya empezó (sin fin) y en Primavera: la abierta cubre hoy.
select pg_temp.actuar_como(pg_temp.u('e8'));
select is(pg_temp.vender('a3', 'T-G', now()), 'ok', 'e8 (en una abierta ya empezada y una por empezar): vender, ok');

-- e5 no tiene ninguna inscripción: no cambia nada respecto de hoy.
select pg_temp.actuar_como(pg_temp.u('e5'));
select is(pg_temp.vender('fb', 'T-B', now()), 'ok', 'e5 (sin inscripciones): vender, como hasta ahora');

-- b4 en Hueco, Primavera y Abierta (sin fin, desde hoy+100): vender hoy sin ninguna empezada.
select pg_temp.actuar_como(pg_temp.u('b4'));
select is(pg_temp.vender('fc', 'T-C', now()), '42501', 'b4 (en tres campañas que no empezaron): vender hoy, 42501');
select is(pg_temp.vender('fd', 'T-D', now() + interval '100 days'), 'ok',
          'sin fecha de fin, el día que empieza Abierta ya vale');

-- Una venta de otro colportor sigue sin poder cargarse (la política de siempre).
select pg_temp.actuar_como(pg_temp.u('e2'));
select is(pg_temp.error_de(format($$ insert into public.venta (id, espacio_persona_id, numero_talonario, monto_total, fecha, colportor_id)
     values (%L, %L, 'T-Z', 10000, now(), %L) $$, pg_temp.u('fe'), pg_temp.u('d4'), pg_temp.u('e5'))),
          '42501', 'una venta a nombre de otro colportor sigue rechazada');

select * from finish();
rollback;
