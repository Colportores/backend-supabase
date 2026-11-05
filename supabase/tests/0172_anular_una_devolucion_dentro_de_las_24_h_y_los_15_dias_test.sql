-- pgTAP · migración 0172 (backend-supabase#246, seguimiento de #172; decisión «Anular offline» de Cristian del 27/10):
--   anular una devolución solo dentro de las 24 h con la hora del teléfono y de los 15 días de gracia.
--   1. La forma: el trigger BEFORE y la función sin EXECUTE para nadie.
--   2. Las 24 h son con la hora del teléfono: anulada a las 20 h y subida a las 30 h pasa; a las 24 h inclusive pasa; a las
--      24 h y un segundo, a las 25 h, DV001. La fila no cambia y no queda `devolucion_anulada`.
--   3. La hora del futuro (más de 5 minutos) o anterior a la devolución: DV002; hasta 5 minutos de reloj adelantado, pasa.
--   4. Los 15 días de gracia: sin campaña, 15 días desde la devolución inclusive (a los 16, DV003); con una campaña en
--      curso rige la de la campaña (una devolución de hace 20 días se anula); con la campaña ya cerrada, DV003 aunque la
--      devolución sea de hace pocos días.
--   5. Una devolución que ya llega anulada (registrada y anulada sin señal) se juzga igual; un reenvío del alta que ya está
--      no (duplicate); una baja repetida no se vuelve a juzgar; el servidor sin sesión no controla nada.
--   6. Por sync.push: DV001 vuelve invalid sin tumbar el lote.
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
  select ('01920000-0000-7000-8000-0000000172' || p)::uuid;
$$;
-- La devolución número n.
create or replace function pg_temp.ud(p_n integer) returns uuid language sql as $$
  select ('01920000-0000-7000-8000-00000172' || lpad(to_hex(p_n), 4, '0'))::uuid;
$$;
create or replace function pg_temp.op(p_n integer) returns uuid language sql as $$
  select ('01920000-0000-7000-8000-00000172' || lpad(to_hex(p_n + 4096), 4, '0'))::uuid;
$$;
create or replace function pg_temp.el(p_renglon text) returns jsonb language sql as $$
  select jsonb_build_array(jsonb_build_object('producto_id', pg_temp.u('11'), 'cantidad', 1, 'venta_item_id', pg_temp.u(p_renglon)));
$$;
-- Una devolución cargada por el servidor (sin sesión nada se controla), de la colportora dueña de la venta.
create or replace function pg_temp.dv(p_n integer, p_venta text, p_renglon text, p_fecha timestamptz, p_baja timestamptz default null)
returns void language sql as $$
  insert into public.devolucion (id, venta_id, productos_devueltos, fecha_devolucion, colportor_id, deleted_at)
  values (pg_temp.ud(p_n), pg_temp.u(p_venta), pg_temp.el(p_renglon), p_fecha,
          (select v.colportor_id from public.venta v where v.id = pg_temp.u(p_venta)), p_baja);
$$;
create or replace function pg_temp.fecha_de(p_n integer) returns timestamptz language sql as $$
  select fecha_devolucion from public.devolucion where id = pg_temp.ud(p_n);
$$;
-- Anular como quien llama con la hora del teléfono que se le dice: 'ok', '0 filas' o el SQLSTATE (y, con p_msg, el mensaje).
create or replace function pg_temp.anular_a(p_quien text, p_n integer, p_hora timestamptz, p_msg boolean default false)
returns text language plpgsql as $$
declare
  v_filas integer;
  v_r     text;
begin
  perform pg_temp.actuar_como(pg_temp.u(p_quien));
  begin
    update public.devolucion set deleted_at = p_hora where id = pg_temp.ud(p_n);
    get diagnostics v_filas = row_count;
    v_r := case when v_filas = 1 then 'ok' else v_filas || ' filas' end;
  exception when others then
    v_r := case when p_msg then sqlstate || ': ' || sqlerrm else sqlstate end;
  end;
  perform pg_temp.actuar_como_servidor();
  return v_r;
end $$;
-- Una devolución cargada con sesión (INSERT por la API): 'ok' o el SQLSTATE.
create or replace function pg_temp.alta_a(p_quien text, p_n integer, p_venta text, p_renglon text, p_fecha timestamptz,
                                          p_baja timestamptz) returns text language plpgsql as $$
declare
  v_r text;
begin
  perform pg_temp.actuar_como(pg_temp.u(p_quien));
  begin
    insert into public.devolucion (id, venta_id, productos_devueltos, fecha_devolucion, deleted_at)
    values (pg_temp.ud(p_n), pg_temp.u(p_venta), pg_temp.el(p_renglon), p_fecha, p_baja);
    v_r := 'ok';
  exception when others then
    v_r := sqlstate;
  end;
  perform pg_temp.actuar_como_servidor();
  return v_r;
end $$;
create or replace function pg_temp.anulada(p_n integer) returns text language sql as $$
  select coalesce((select (d.deleted_at is not null)::text from public.devolucion d where d.id = pg_temp.ud(p_n)), 'no existe');
$$;
create or replace function pg_temp.eventos(p_tipo text, p_n integer) returns integer language sql as $$
  select count(*)::int from auditoria.audit_log a where a.event_type = p_tipo and a.fila_id = pg_temp.ud(p_n);
$$;
create or replace function pg_temp.version_de(p_n integer) returns bigint language sql as $$
  select sync_version from public.devolucion where id = pg_temp.ud(p_n);
$$;
-- Un push de varios jobs como la colportora; devuelve el arreglo `results`.
create or replace function pg_temp.push(p_quien text, p_jobs jsonb) returns jsonb language plpgsql as $$
declare
  v_r jsonb;
begin
  perform pg_temp.actuar_como(pg_temp.u(p_quien));
  v_r := sync.push(p_jobs) -> 'results';
  perform pg_temp.actuar_como_servidor();
  return v_r;
end $$;
create or replace function pg_temp.job(p_op integer, p_tipo text, p_payload jsonb, p_version bigint default null)
returns jsonb language sql as $$
  select jsonb_strip_nulls(jsonb_build_object('client_op_id', pg_temp.op(p_op), 'entity', 'devolucion', 'op', p_tipo,
                                              'sync_version', p_version, 'payload', p_payload));
$$;

-- --- fixtures (como postgres) --------------------------------------------------
-- Campañas: c1 en curso (la de b1); c4 terminada hace 16 días (su gracia cerró ayer; la de b4). b7 está en una campaña
-- que no cubre su venta de hace 200 días. Libro 11. Una venta por colportora, con un renglón de 100 libros.
insert into auth.users (id, instance_id, aud, role, email, encrypted_password, confirmed_at, created_at, updated_at)
select pg_temp.u(s), '00000000-0000-0000-0000-000000000000',
       'authenticated', 'authenticated', 'dev172-' || s || '@example.com', 'x', now(), now(), now()
  from unnest(array['d1','d2','b1','b4','b7']) s;
insert into public.usuario_rol (usuario_id, rol_id)
select pg_temp.u(x.s), r.id
  from (values ('d1', 'COORDINADOR'), ('d2', 'COORDINADOR'), ('b1', 'COLPORTOR'), ('b4', 'COLPORTOR'), ('b7', 'COLPORTOR')) x(s, codigo)
  join public.rol r on r.codigo = x.codigo;
insert into public.campania (id, nombre, tipo, fecha_inicio, fecha_fin, coordinador_id) values
  (pg_temp.u('c1'), 'c1 en curso', 'VERANO', public.hoy_montevideo() - 45, public.hoy_montevideo() + 30, pg_temp.u('d1')),
  (pg_temp.u('c4'), 'c4 hace 16 dias', 'VERANO', public.hoy_montevideo() - 60, public.hoy_montevideo(now() - interval '3 hours') - 16, pg_temp.u('d2')),
  (pg_temp.u('c6'), 'c6 en curso', 'VERANO', public.hoy_montevideo() - 10, public.hoy_montevideo() + 30, pg_temp.u('d2'));
insert into public.campania_colportor (campania_id, usuario_id, created_at) values
  (pg_temp.u('c1'), pg_temp.u('b1'), now() - interval '40 days'),
  (pg_temp.u('c4'), pg_temp.u('b4'), now() - interval '59 days'),
  (pg_temp.u('c6'), pg_temp.u('b7'), now() - interval '9 days');
insert into public.producto (id, nombre, tipo, precio_base_compra) values (pg_temp.u('11'), 'Libro t172', 'LIBRO', 1500);

insert into public.pais (id, nombre, iso_code) values (pg_temp.u('f0'), 'Pais dev172', 'ZX');
insert into public.ciudad (id, nombre, departamento, pais_id, lat_centro, lon_centro)
values (pg_temp.u('f1'), 'Ciudad dev172', 'Departamento de prueba', pg_temp.u('f0'), -34.90, -56.20);
insert into public.ubicacion (id, tipo, calle, numero, lat, lon, ciudad_id, created_by)
values (pg_temp.u('f2'), 'CASA', 'Dev 172', '1', -34.91, -56.2, pg_temp.u('f1'), pg_temp.u('b1'));
insert into public.espacio (id, ubicacion_id, numero_depto, created_by) values (pg_temp.u('f3'), pg_temp.u('f2'), null, pg_temp.u('b1'));
insert into public.espacio_persona (id, espacio_id, persona_id, created_by)
values (pg_temp.u('f4'), pg_temp.u('f3'), pg_temp.u('f5'), pg_temp.u('b1'));
insert into public.venta (id, espacio_persona_id, numero_talonario, monto_total, fecha, colportor_id, created_by, motivo_monto_manual)
select pg_temp.u(x.v), pg_temp.u('f4'), 'T-172-' || x.v, 1000000, now() - x.hace, pg_temp.u(x.quien), pg_temp.u(x.quien),
       'fixture: ítems que no cuadran con el total (0150)'
  from (values ('71', interval '30 days', 'b1'), ('74', interval '30 days', 'b4'), ('77', interval '200 days', 'b7')) x(v, hace, quien);
insert into public.venta_item (id, venta_id, producto_id, cantidad, precio_unitario, subtotal) values
  (pg_temp.u('81'), pg_temp.u('71'), pg_temp.u('11'), 100, 1000, 100000),
  (pg_temp.u('84'), pg_temp.u('74'), pg_temp.u('11'), 100, 1000, 100000),
  (pg_temp.u('87'), pg_temp.u('77'), pg_temp.u('11'), 100, 1000, 100000);

-- ---------------------------------------------------------------------------
-- 1. La forma
-- ---------------------------------------------------------------------------
select has_trigger('public', 'devolucion', 'devolucion_anulacion_a_tiempo', 'devolucion tiene el trigger de la anulación a tiempo');
select is((select (t.tgtype & 2)::int || ' ' || (t.tgtype & 1)::int || ' ' || (t.tgtype & 4)::int || ' ' || (t.tgtype & 16)::int
             from pg_trigger t where t.tgname = 'devolucion_anulacion_a_tiempo' and t.tgrelid = 'public.devolucion'::regclass),
          '2 1 4 16', 'es BEFORE, por fila, de INSERT y de UPDATE');
select ok((select pg_get_triggerdef(t.oid) ~ 'UPDATE OF deleted_at'
             from pg_trigger t where t.tgname = 'devolucion_anulacion_a_tiempo' and t.tgrelid = 'public.devolucion'::regclass),
          'y del UPDATE de deleted_at nada más');
select is((select array[has_function_privilege('anon', 'public.tg_devolucion_anulacion_a_tiempo()', 'execute')::text,
                        has_function_privilege('authenticated', 'public.tg_devolucion_anulacion_a_tiempo()', 'execute')::text,
                        has_function_privilege('service_role', 'public.tg_devolucion_anulacion_a_tiempo()', 'execute')::text]),
          array['false', 'false', 'false'], 'la función no la ejecuta nadie a mano');

-- ---------------------------------------------------------------------------
-- 2. Las 24 h con la hora del teléfono
-- ---------------------------------------------------------------------------
-- Devoluciones registradas hace 30 horas: «anulada a las 20 h y subida a las 30 h».
select pg_temp.dv(1, '71', '81', now() - interval '30 hours');
select pg_temp.dv(2, '71', '81', now() - interval '30 hours');
select pg_temp.dv(3, '71', '81', now() - interval '30 hours');
select pg_temp.dv(4, '71', '81', now() - interval '30 hours');
select is(pg_temp.anular_a('b1', 1, pg_temp.fecha_de(1) + interval '20 hours'), 'ok',
          'anulada a las 20 h y subida a las 30 h: pasa (cuenta la hora del teléfono, no la de subida)');
select is(pg_temp.anulada(1) || ' ' || pg_temp.eventos('devolucion_anulada', 1), 'true 1', 'queda anulada y deja su evento');
select is((select deleted_at from public.devolucion where id = pg_temp.ud(1)), pg_temp.fecha_de(1) + interval '20 hours',
          'con la hora del teléfono en deleted_at');

select is(pg_temp.anular_a('b1', 2, pg_temp.fecha_de(2) + interval '25 hours'), 'DV001', 'anulada a las 25 h: DV001');
select is(pg_temp.anulada(2) || ' ' || pg_temp.version_de(2) || ' ' || pg_temp.eventos('devolucion_anulada', 2), 'false 0 0',
          'la fila no cambia (ni su sync_version) y no queda devolucion_anulada en audit_log');
select alike(pg_temp.anular_a('b1', 2, pg_temp.fecha_de(2) + interval '25 hours', true), 'DV001: %24 horas%',
            'y el aviso dice las 24 horas');

select is(pg_temp.anular_a('b1', 3, pg_temp.fecha_de(3) + interval '24 hours'), 'ok', 'a las 24 h justas: pasa (inclusive)');
select is(pg_temp.anular_a('b1', 4, pg_temp.fecha_de(4) + interval '24 hours 1 second'), 'DV001', 'a las 24 h y un segundo: DV001');
select is(pg_temp.anulada(4) || ' ' || pg_temp.eventos('devolucion_anulada', 4), 'false 0', 'y no queda anulada');
-- Rechazada una vez, la misma devolución se anula después con una hora buena.
select is(pg_temp.anular_a('b1', 4, pg_temp.fecha_de(4) + interval '23 hours'), 'ok', 'rechazada una vez, se anula luego con una hora en plazo');

-- ---------------------------------------------------------------------------
-- 3. La hora del teléfono tiene que ser de fiar
-- ---------------------------------------------------------------------------
select pg_temp.dv(5, '71', '81', now() - interval '2 hours');
select pg_temp.dv(6, '71', '81', now() - interval '2 hours');
select pg_temp.dv(7, '71', '81', now() - interval '2 hours');
select pg_temp.dv(8, '71', '81', now() - interval '2 hours');
select is(pg_temp.anular_a('b1', 5, now() + interval '1 hour'), 'DV002', 'una hora del futuro (1 h): DV002');
select is(pg_temp.anular_a('b1', 5, now() + interval '5 minutes 1 second'), 'DV002', 'y 5 minutos y un segundo, también');
select alike(pg_temp.anular_a('b1', 5, now() + interval '1 hour', true), 'DV002: %fecha y la hora de tu teléfono%',
            'el aviso manda revisar la fecha y la hora del teléfono');
select is(pg_temp.anulada(5) || ' ' || pg_temp.eventos('devolucion_anulada', 5), 'false 0', 'la fila no cambia y no deja evento');
select is(pg_temp.anular_a('b1', 6, pg_temp.fecha_de(6) - interval '1 minute'), 'DV002', 'una hora anterior a la devolución: DV002');
select is(pg_temp.anular_a('b1', 7, now() + interval '4 minutes'), 'ok', 'hasta 5 minutos de reloj adelantado: pasa');
select is(pg_temp.anular_a('b1', 8, pg_temp.fecha_de(8)), 'ok', 'anulada en el mismo instante en que se registró: pasa');

-- ---------------------------------------------------------------------------
-- 4. Los 15 días de gracia
-- ---------------------------------------------------------------------------
-- Sin campaña (la venta 77 de b7 no cae en ninguna): 15 días desde la devolución, inclusive.
select pg_temp.dv(10, '77', '87', now() - interval '16 days');
select pg_temp.dv(11, '77', '87', now() - interval '14 days');
select pg_temp.dv(12, '77', '87', now() - interval '15 days');
select pg_temp.dv(13, '77', '87', now() - interval '15 days' - interval '1 second');
select is(pg_temp.anular_a('b7', 10, pg_temp.fecha_de(10) + interval '2 hours'), 'DV003', 'sin campaña, subida a los 16 días: DV003');
select alike(pg_temp.anular_a('b7', 10, pg_temp.fecha_de(10) + interval '2 hours', true), 'DV003: %15 días desde la devolución%',
            'el aviso dice los 15 días desde la devolución y manda al coordinador');
select is(pg_temp.anulada(10) || ' ' || pg_temp.eventos('devolucion_anulada', 10), 'false 0', 'la fila no cambia y no deja evento');
select is(pg_temp.anular_a('b7', 11, pg_temp.fecha_de(11) + interval '2 hours'), 'ok', 'sin campaña, a los 14 días: pasa');
select is(pg_temp.anular_a('b7', 12, pg_temp.fecha_de(12) + interval '2 hours'), 'ok', 'a los 15 días justos: pasa');
select is(pg_temp.anular_a('b7', 13, pg_temp.fecha_de(13) + interval '2 hours'), 'DV003', 'a los 15 días y un segundo: DV003');

-- Con la campaña en curso rige la de la campaña: una devolución de hace 20 días todavía se anula (y la hora del
-- teléfono dentro de las 24 h de la devolución).
select pg_temp.dv(14, '71', '81', now() - interval '20 days');
select is(pg_temp.anular_a('b1', 14, pg_temp.fecha_de(14) + interval '2 hours'), 'ok',
          'con la campaña en curso, subida a los 20 días: pasa (rige la gracia de la campaña)');
-- Con la campaña cerrada (b4, c4: terminó hace 16 días y su gracia cerró ayer) no sube, aunque la devolución sea de hace
-- pocos días: se registró con la gracia abierta y ahora está cerrada.
select pg_temp.dv(15, '74', '84', now() - interval '3 days');
select alike(pg_temp.anular_a('b4', 15, pg_temp.fecha_de(15) + interval '1 hour', true), 'DV003: La campaña de esta venta terminó hace más de 15 días%',
            'con la campaña ya cerrada: DV003, aunque la devolución sea de hace 3 días');
select is(pg_temp.anulada(15) || ' ' || pg_temp.eventos('devolucion_anulada', 15), 'false 0', 'la fila no cambia y no deja evento');

-- ---------------------------------------------------------------------------
-- 5. El alta que llega ya anulada, el reenvío, la baja repetida y el servidor
-- ---------------------------------------------------------------------------
-- Registrada y anulada sin conexión, y sube todo junto: se juzga igual.
select is(pg_temp.alta_a('b1', 20, '71', '81', now() - interval '30 hours', now() - interval '10 hours'), 'ok',
          'una devolución que llega anulada a las 20 h (subida a las 30 h): se acepta');
select is(pg_temp.eventos('devolucion_registrada', 20) || ' ' || pg_temp.eventos('devolucion_anulada', 20), '1 1',
          'y deja su registro y su anulación');
select is(pg_temp.alta_a('b1', 21, '71', '81', now() - interval '30 hours', now() - interval '4 hours'), 'DV001',
          'la que llega anulada a las 26 h: DV001');
select is(pg_temp.anulada(21) || ' ' || pg_temp.eventos('devolucion_registrada', 21) || ' ' || pg_temp.eventos('devolucion_anulada', 21),
          'no existe 0 0', 'no entra la fila y no deja ni el registro ni la anulación');
select is(pg_temp.alta_a('b1', 22, '71', '81', now() - interval '30 hours', now() + interval '1 hour'), 'DV002',
          'la que llega anulada con una hora del futuro: DV002');

-- El reenvío de un alta que ya está (aunque su anulación vieja hoy ya no pasaría) es un duplicado, no un invalid.
select pg_temp.dv(23, '77', '87', now() - interval '60 days', now() - interval '60 days' + interval '1 hour');
select is((select pg_temp.push('b7', jsonb_build_array(pg_temp.job(1, 'insert',
             jsonb_build_object('id', pg_temp.ud(23), 'venta_id', pg_temp.u('77'), 'productos_devueltos', pg_temp.el('87'),
                                'fecha_devolucion', now() - interval '60 days',
                                'deleted_at', now() - interval '60 days' + interval '1 hour')))) -> 0 ->> 'outcome'),
          'duplicate', 'el reenvío de un alta vieja que ya está: duplicate, no se vuelve a juzgar');

-- Una baja repetida (la fila ya estaba anulada, hace mucho) no se juzga.
select pg_temp.dv(24, '77', '87', now() - interval '60 days', now() - interval '60 days' + interval '1 hour');
select is(pg_temp.anular_a('b7', 24, pg_temp.fecha_de(24) + interval '2 hours'), 'ok',
          'una baja repetida de una devolución ya anulada no se juzga');
select is(pg_temp.eventos('devolucion_anulada', 24), 1, 'ni suma un evento (queda el único, el de cuando entró anulada)');

-- Sin sesión (el servidor, las migraciones, el editor SQL) no hay control.
select pg_temp.dv(25, '77', '87', now() - interval '60 days');
update public.devolucion set deleted_at = fecha_devolucion + interval '30 days' where id = pg_temp.ud(25);
select is(pg_temp.anulada(25), 'true', 'el servidor (sin sesión) anula una devolución vieja y fuera de las 24 h: no controla nada');

-- ---------------------------------------------------------------------------
-- 6. Por sync.push: DV001 vuelve invalid y no tumba el lote
-- ---------------------------------------------------------------------------
select pg_temp.dv(30, '71', '81', now() - interval '30 hours');
select pg_temp.dv(31, '71', '81', now() - interval '30 hours');
create temp table t172_push as
select pg_temp.push('b1', jsonb_build_array(
         pg_temp.job(10, 'update', jsonb_build_object('id', pg_temp.ud(30), 'deleted_at', pg_temp.fecha_de(30) + interval '25 hours'), 0),
         pg_temp.job(11, 'update', jsonb_build_object('id', pg_temp.ud(31), 'deleted_at', pg_temp.fecha_de(31) + interval '20 hours'), 0))) as r;
select is((select r -> 0 ->> 'outcome' from t172_push), 'invalid', 'la anulación a las 25 h por push: invalid');
select is((select r -> 0 ->> 'code' from t172_push), 'DV001', 'con su código DV001');
select is((select r -> 1 ->> 'outcome' from t172_push), 'accepted', 'y la siguiente del mismo lote (a las 20 h) se acepta: el lote sigue');
select is(pg_temp.anulada(30) || ' ' || pg_temp.eventos('devolucion_anulada', 30) || ' ' || pg_temp.anulada(31) || ' ' || pg_temp.eventos('devolucion_anulada', 31),
          'false 0 true 1', 'la rechazada no cambia ni deja evento; la aceptada queda anulada con su evento');
select is((select pg_temp.push('b1', jsonb_build_array(
             pg_temp.job(12, 'update', jsonb_build_object('id', pg_temp.ud(30), 'deleted_at', now() + interval '1 hour'), 0))) -> 0 ->> 'code'),
          'DV002', 'una hora del futuro por push: DV002');
select is((select pg_temp.push('b7', jsonb_build_array(
             pg_temp.job(13, 'insert', jsonb_build_object('id', pg_temp.ud(32), 'venta_id', pg_temp.u('77'),
               'productos_devueltos', pg_temp.el('87'), 'fecha_devolucion', now() - interval '16 days',
               'deleted_at', now() - interval '16 days' + interval '2 hours')))) -> 0 ->> 'code'),
          'DV003', 'un alta anulada pasada la gracia por push: DV003');
select is(pg_temp.anulada(32), 'no existe', 'y no entra la fila');
select is((select pg_temp.push('b1', jsonb_build_array(
             pg_temp.job(14, 'insert', jsonb_build_object('id', pg_temp.ud(33), 'venta_id', pg_temp.u('71'),
               'productos_devueltos', pg_temp.el('81'), 'fecha_devolucion', now() - interval '30 hours',
               'deleted_at', now() - interval '10 hours')))) -> 0 ->> 'outcome'),
          'accepted', 'un alta anulada a las 20 h por push: accepted');
select is(pg_temp.anulada(33) || ' ' || pg_temp.eventos('devolucion_anulada', 33), 'true 1', 'queda anulada con su evento');

select * from finish();
rollback;
