-- pgTAP · transferencia de stock entre colportores (migración 0126, backend-supabase#106, HU-STK-005/006,
-- vista 35 pestaña «Transferencias»)
-- transferencias_de_campania(), transferencia_lineas(), autorizar_transferencia() y rechazar_transferencia(): los
-- privilegios; el permiso primero (sin JWT, colportor, sin rol, rol vencido, coordinador de otra campaña) y el de
-- decisión, más estricto que el de lectura (uno de los dos dado de baja, campaña cerrada hace más de 15 días);
-- qué transferencias salen en la bandeja; las líneas con el stock de los dos; autorizar (el stock y la deuda
-- pasan, los movimientos, el costo que queda en cada línea, reintento, cada error, todo o nada, cuentas que se
-- crean o se reactivan, el ADMIN); rechazar (motivo obligatorio, recortado, tope de 500, reintento); la
-- auditoría sin el motivo; los CHECK de las columnas nuevas; y que lo de siempre no cambia (el colportor no
-- escribe la tabla).
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

-- El rol `authenticated` pero sin sesión: auth.uid() es null.
create or replace function pg_temp.actuar_sin_jwt() returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', '', true);
  perform set_config('request.jwt.claim.sub', '', true);
  perform set_config('request.jwt.claim.role', '', true);
  perform set_config('role', 'authenticated', true);
end $$;

-- El uuid de un personaje del test (sufijo de dos caracteres HEX).
create or replace function pg_temp.u(p_sufijo text) returns uuid language sql immutable as $$
  select ('01920000-0000-7000-8000-0000000125' || p_sufijo)::uuid
$$;

-- Corre una consulta como ese usuario (null = sin sesión) y devuelve sus filas como jsonb; si tira,
-- {"error": <SQLSTATE>, "mensaje": <texto>}. Al volver, el test sigue siendo el servidor.
create or replace function pg_temp.como(p_uid uuid, p_sql text) returns jsonb language plpgsql as $$
declare
  v_r jsonb;
begin
  if p_uid is null then
    perform pg_temp.actuar_sin_jwt();
  else
    perform pg_temp.actuar_como(p_uid);
  end if;
  begin
    execute format('select coalesce(jsonb_agg(to_jsonb(t)), ''[]''::jsonb) from (%s) t', p_sql) into v_r;
  exception when others then
    v_r := jsonb_build_object('error', sqlstate, 'mensaje', sqlerrm);
  end;
  perform pg_temp.actuar_como_servidor();
  return v_r;
end $$;

-- El SQLSTATE de lo que tira una sentencia (UPDATE, INSERT...) ejecutada como ese usuario ('ok' si no tira).
create or replace function pg_temp.err_dml(p_uid uuid, p_sql text) returns text language plpgsql as $$
declare
  v_r text;
begin
  perform pg_temp.actuar_como(p_uid);
  begin
    execute p_sql;
    v_r := 'ok';
  exception when others then
    v_r := sqlstate;
  end;
  perform pg_temp.actuar_como_servidor();
  return v_r;
end $$;

-- El SQLSTATE de una sentencia ejecutada como el servidor ('ok' si no tira).
create or replace function pg_temp.err_srv(p_sql text) returns text language plpgsql as $$
begin
  execute p_sql;
  return 'ok';
exception when others then
  return sqlstate;
end $$;

-- El SQLSTATE de lo que tira una consulta ('ok' si no tira).
create or replace function pg_temp.err(p_uid uuid, p_sql text) returns text language sql as $$
  select coalesce(pg_temp.como(p_uid, p_sql) ->> 'error', 'ok')
$$;

-- Un campo de la primera fila de lo que devolvió pg_temp.como.
create or replace function pg_temp.c(p_j jsonb, p_k text) returns text language sql immutable as $$
  select (p_j -> 0) ->> p_k
$$;

create or replace function pg_temp.aut(p_uid uuid, p_t text) returns jsonb language sql as $$
  select pg_temp.como(p_uid, format('select * from public.autorizar_transferencia(%L)', pg_temp.u(p_t)))
$$;
create or replace function pg_temp.rech(p_uid uuid, p_t text, p_motivo text) returns jsonb language sql as $$
  select pg_temp.como(p_uid, format('select * from public.rechazar_transferencia(%L, %L)', pg_temp.u(p_t), p_motivo))
$$;
create or replace function pg_temp.lista(p_uid uuid, p_camp text) returns jsonb language sql as $$
  select pg_temp.como(p_uid, format('select * from public.transferencias_de_campania(%L)', pg_temp.u(p_camp)))
$$;
create or replace function pg_temp.lineas(p_uid uuid, p_t text) returns jsonb language sql as $$
  select pg_temp.como(p_uid, format('select * from public.transferencia_lineas(%L)', pg_temp.u(p_t)))
$$;

-- Los ids (sufijos) de la bandeja de una campaña, en el orden en que salen.
create or replace function pg_temp.ids(p_uid uuid, p_camp text) returns text language sql as $$
  select coalesce(string_agg(right(e ->> 'transferencia_id', 2), ',' order by o), '')
    from jsonb_array_elements((select case when jsonb_typeof(l) = 'array' then l else '[]'::jsonb end
                                 from (select pg_temp.lista(p_uid, p_camp) l) q)) with ordinality t(e, o)
$$;

-- Lo que hay hoy (como el servidor): la deuda de un colportor (-1 = sin cuenta viva) y su stock de un producto
-- (-1 = sin fila viva).
create or replace function pg_temp.deuda(p_col text) returns bigint language sql as $$
  select coalesce((select deuda_total from public.cuenta_colportor
                    where usuario_id = pg_temp.u(p_col) and deleted_at is null), -1)
$$;
create or replace function pg_temp.stock(p_col text, p_prod text) returns integer language sql as $$
  select coalesce((select cantidad_disponible from public.stock
                    where usuario_id = pg_temp.u(p_col) and producto_id = pg_temp.u(p_prod) and deleted_at is null), -1)
$$;
create or replace function pg_temp.estado(p_t text) returns text language sql as $$
  select estado from public.transferencia_stock where id = pg_temp.u(p_t)
$$;
create or replace function pg_temp.n_audit(p_evento text, p_t text) returns bigint language sql as $$
  select count(*) from auditoria.audit_log where event_type = p_evento and fila_id = pg_temp.u(p_t)
$$;
create or replace function pg_temp.n_mov(p_t text) returns bigint language sql as $$
  select count(*) from public.movimiento_stock where transferencia_id = pg_temp.u(p_t)
$$;

-- --- fixtures ------------------------------------------------------------------
-- Staff: a1 coordinador de Abierta, Borde15 y Borde16; a2 coordinador de Otra; ad admin; a0 colportor;
--        a3 sin rol; a4 coordinador con el rol vencido.
-- Colportores: b1 Ana Alfa (Abierta, zona Centro, ciudad uno)  b2 Beto Bravo (Abierta, sin zona)
--        b3 Carla Cruz (Abierta, inscripción dada de baja)  b4 Diego Duarte (Otra)  b5 Elena Eguren (Abierta, sin
--        zona)  b6 Fede Fuentes y b7 Gabi Gómez (Borde15: terminó hace 15 días)  b8 Hugo Haedo y b9 Ines Ibarra
--        (Borde16: terminó hace 16 días).
-- Campañas: e1 Abierta (a1)  e2 Otra (a2)  e5 Borde15 (a1)  e4 Borde16 (a1)  e7 Borrada (a1, dada de baja: bc y bd).
-- b5 se inscribió el 01/09 (las pedidas antes no lo incluyen) y su zona está dada de baja.
-- Productos: 91 Libro Uno (1500)  92 Libro Dos (2500)  93 Revista Uno (200)  94 Sin Costo (null)  95 Gratis (0).
insert into auth.users (id, instance_id, aud, role, email, encrypted_password, confirmed_at, created_at, updated_at)
select pg_temp.u(s), '00000000-0000-0000-0000-000000000000',
       'authenticated', 'authenticated', 'transf-' || s || '@example.com', 'x', now(), now(), now()
  from unnest(array['a0','a1','a2','a3','a4','ad','b1','b2','b3','b4','b5','b6','b7','b8','b9','bc','bd']) s;

update public.usuario u set nombre = x.n, apellido = x.a
  from (values ('b1','Ana','Alfa'), ('b2','Beto','Bravo'), ('b3','Carla','Cruz'), ('b4','Diego','Duarte'),
               ('b5','Elena','Eguren'), ('b6','Fede','Fuentes'), ('b7','Gabi','Gómez'), ('b8','Hugo','Haedo'),
               ('b9','Ines','Ibarra')) x(s, n, a)
 where u.id = pg_temp.u(x.s);

insert into public.usuario_rol (usuario_id, rol_id)
select pg_temp.u(x.s), r.id
  from (values ('a1','COORDINADOR'), ('a2','COORDINADOR'), ('ad','ADMIN'), ('a0','COLPORTOR'),
               ('b1','COLPORTOR'), ('b2','COLPORTOR'), ('b3','COLPORTOR'), ('b4','COLPORTOR'),
               ('b5','COLPORTOR'), ('b6','COLPORTOR'), ('b7','COLPORTOR'), ('b8','COLPORTOR'), ('b9','COLPORTOR')) x(s, codigo)
  join public.rol r on r.codigo = x.codigo;
insert into public.usuario_rol (usuario_id, rol_id, valido_desde, valido_hasta)
select pg_temp.u('a4'), r.id, now() - interval '10 days', now() - interval '1 day'
  from public.rol r where r.codigo = 'COORDINADOR';

insert into public.pais (id, nombre, iso_code) values (pg_temp.u('c0'), 'Pais transferencias', 'ZT');
insert into public.ciudad (id, nombre, departamento, pais_id, lat_centro, lon_centro, zoom_inicial) values
  (pg_temp.u('c1'), 'Ciudad uno q106', 'Departamento de prueba uno', pg_temp.u('c0'), -34.91, -56.18, 13);

insert into public.campania (id, nombre, tipo, fecha_inicio, fecha_fin, coordinador_id) values
  (pg_temp.u('e1'), 'Abierta',  'VERANO', '2026-08-03', null, pg_temp.u('a1')),
  (pg_temp.u('e2'), 'Otra',     'VERANO', '2026-08-03', null, pg_temp.u('a2')),
  (pg_temp.u('e5'), 'Borde15',  'VERANO', public.hoy_montevideo() - 90, public.hoy_montevideo() - 15, pg_temp.u('a1')),
  (pg_temp.u('e4'), 'Borde16',  'VERANO', public.hoy_montevideo() - 90, public.hoy_montevideo() - 16, pg_temp.u('a1'));
insert into public.campania (id, nombre, tipo, fecha_inicio, fecha_fin, coordinador_id, deleted_at) values
  (pg_temp.u('e7'), 'Borrada',  'VERANO', '2026-08-03', null, pg_temp.u('a1'), now());
insert into public.campania_ciudad (id, campania_id, ciudad_id) values
  (pg_temp.u('71'), pg_temp.u('e1'), pg_temp.u('c1'));
insert into public.zona (id, nombre, campania_ciudad_id, tipo_forma, color, poligono_geojson) values
  (pg_temp.u('d1'), 'Centro', pg_temp.u('71'), 'ESQUINAS', '#112233',
   '{"type":"Polygon","coordinates":[[[-56.19,-34.92],[-56.17,-34.92],[-56.17,-34.91],[-56.19,-34.91],[-56.19,-34.92]]]}'::jsonb);

insert into public.zona (id, nombre, campania_ciudad_id, tipo_forma, color, poligono_geojson) values
  (pg_temp.u('d2'), 'Vieja', pg_temp.u('71'), 'ESQUINAS', '#445566',
   '{"type":"Polygon","coordinates":[[[-56.16,-34.92],[-56.15,-34.92],[-56.15,-34.91],[-56.16,-34.91],[-56.16,-34.92]]]}'::jsonb);

insert into public.campania_colportor (campania_id, usuario_id, zona_id, created_at) values
  (pg_temp.u('e1'), pg_temp.u('b1'), pg_temp.u('d1'), '2026-08-01 10:00-03'),
  (pg_temp.u('e1'), pg_temp.u('b2'), null,            '2026-08-01 10:00-03'),
  (pg_temp.u('e1'), pg_temp.u('b3'), pg_temp.u('d1'), '2026-08-01 10:00-03'),
  (pg_temp.u('e2'), pg_temp.u('b4'), null,            '2026-08-01 10:00-03'),
  (pg_temp.u('e1'), pg_temp.u('b5'), pg_temp.u('d2'), '2026-09-01 10:00-03'),
  (pg_temp.u('e5'), pg_temp.u('b6'), null,            (public.hoy_montevideo() - 90)::timestamptz),
  (pg_temp.u('e5'), pg_temp.u('b7'), null,            (public.hoy_montevideo() - 90)::timestamptz),
  (pg_temp.u('e4'), pg_temp.u('b8'), null,            (public.hoy_montevideo() - 90)::timestamptz),
  (pg_temp.u('e4'), pg_temp.u('b9'), null,            (public.hoy_montevideo() - 90)::timestamptz),
  (pg_temp.u('e7'), pg_temp.u('bc'), null,            '2026-08-01 10:00-03'),
  (pg_temp.u('e7'), pg_temp.u('bd'), null,            '2026-08-01 10:00-03');
update public.zona set deleted_at = now() where id = pg_temp.u('d2');
-- b3 se dio de baja el 21/10 a las 12:00.
update public.campania_colportor set deleted_at = '2026-10-21 12:00:00+00'
 where campania_id = pg_temp.u('e1') and usuario_id = pg_temp.u('b3');

insert into public.producto (id, nombre, tipo, precio_base_compra) values
  (pg_temp.u('91'), 'Libro Uno',   'LIBRO',    1500),
  (pg_temp.u('92'), 'Libro Dos',   'LIBRO',    2500),
  (pg_temp.u('93'), 'Revista Uno', 'REVISTA',  200),
  (pg_temp.u('94'), 'Sin Costo',   'MATERIAL', null),
  (pg_temp.u('95'), 'Gratis',      'MATERIAL', 0);

-- Lo por entregar de b2: 3 unidades del Libro Uno vendidas y no entregadas (una entrega ya hecha y una venta de
-- otro colportor no cuentan). Las entregas van ANTES del stock: 0118 descuenta stock por cada una.
insert into public.ubicacion (id, tipo, calle, numero, lat, lon, ciudad_id)
values (pg_temp.u('f1'), 'CASA', 'Calle de prueba', '1', -34.915, -56.18, pg_temp.u('c1'));
insert into public.espacio (id, ubicacion_id) values (pg_temp.u('f2'), pg_temp.u('f1'));
insert into public.espacio_persona (id, espacio_id, persona_id)
values (pg_temp.u('f3'), pg_temp.u('f2'), pg_temp.u('f4'));
insert into public.venta (id, espacio_persona_id, numero_talonario, monto_total, fecha, colportor_id) values
  (pg_temp.u('30'), pg_temp.u('f3'), 'T-1', 5000, '2026-10-01 12:00:00+00', pg_temp.u('b2')),
  (pg_temp.u('31'), pg_temp.u('f3'), 'T-2', 5000, '2026-10-02 12:00:00+00', pg_temp.u('b1'));
insert into public.venta (id, espacio_persona_id, numero_talonario, monto_total, fecha, colportor_id, deleted_at) values
  (pg_temp.u('32'), pg_temp.u('f3'), 'T-3', 5000, '2026-10-03 12:00:00+00', pg_temp.u('b2'), now());
insert into public.entrega (venta_id, producto_id, cantidad, pendiente) values
  (pg_temp.u('30'), pg_temp.u('91'), 3, true),
  (pg_temp.u('30'), pg_temp.u('91'), 5, false),
  (pg_temp.u('31'), pg_temp.u('91'), 9, true),
  (pg_temp.u('32'), pg_temp.u('91'), 4, true);
delete from public.movimiento_stock;
delete from public.stock;

-- El stock de partida (b1 tiene el de la Revista dado de baja: cuenta como cero).
insert into public.stock (usuario_id, producto_id, cantidad_disponible, deleted_at) values
  (pg_temp.u('b1'), pg_temp.u('91'), 5,  null),
  (pg_temp.u('b1'), pg_temp.u('92'), 3,  null),
  (pg_temp.u('b1'), pg_temp.u('93'), 50, now()),
  (pg_temp.u('b2'), pg_temp.u('91'), 1,  null),
  (pg_temp.u('b2'), pg_temp.u('93'), 7,  now()),
  (pg_temp.u('b5'), pg_temp.u('93'), 10, null),
  (pg_temp.u('b6'), pg_temp.u('91'), 3,  null),
  (pg_temp.u('b8'), pg_temp.u('95'), 1,  null);

-- Las cuentas: b1 debe 20000; b5 tiene una cuenta dada de baja (777); b2, b4 y b6 no tienen.
insert into public.cuenta_colportor (usuario_id, deuda_total) values (pg_temp.u('b1'), 20000);
insert into public.cuenta_colportor (usuario_id, deuda_total, deleted_at) values (pg_temp.u('b5'), 777, now());

-- Transferencias (id, de, a, estado, minuto, dada de baja, monto, decidió, cuándo, motivo). Más reciente = minuto más alto.
insert into public.transferencia_stock (id, origen_id, destino_id, estado, fecha_solicitud, deleted_at,
                                        monto_deuda, coordinador_id, decidido_en, motivo_rechazo)
select pg_temp.u(x.id), pg_temp.u(x.de), pg_temp.u(x.a), x.est,
       '2026-10-20 10:00:00+00'::timestamptz + x.min * interval '1 minute',
       x.baja, x.monto, case when x.dec is null then null else pg_temp.u(x.dec) end, x.decen, x.mot
  from (values
    ('11', 'b1', 'b2', 'PENDIENTE_AUTORIZACION', 1,  null::timestamptz, null::bigint, null::text, null::timestamptz, null::text),
    ('12', 'b1', 'b2', 'PENDIENTE_AUTORIZACION', 2,  null, null, null, null, null),
    ('13', 'b1', 'b2', 'PENDIENTE_AUTORIZACION', 3,  null, null, null, null, null),
    ('14', 'b1', 'b2', 'PENDIENTE_AUTORIZACION', 4,  null, null, null, null, null),
    ('15', 'b1', 'b2', 'AUTORIZADO',             5,  null, 1000, 'a1', '2026-10-25 12:00:00+00', null),
    ('16', 'b1', 'b2', 'RECHAZADO',              6,  null, null, 'a1', '2026-10-25 13:00:00+00', 'No hay stock'),
    ('17', 'b1', 'b2', 'CANCELADO',              7,  null, null, null, null, null),
    ('18', 'b1', 'b4', 'PENDIENTE_AUTORIZACION', 8,  null, null, null, null, null),
    ('19', 'b1', 'b3', 'PENDIENTE_AUTORIZACION', 9,  null, null, null, null, null),
    ('1a', 'b1', 'b2', 'PENDIENTE_AUTORIZACION', 10, now(), null, null, null, null),
    ('1b', 'b1', 'b2', 'PENDIENTE_AUTORIZACION', 11, null, null, null, null, null),
    ('1c', 'b1', 'b2', 'PENDIENTE_AUTORIZACION', 12, null, null, null, null, null),
    ('1d', 'b5', 'b1', 'PENDIENTE_AUTORIZACION', 13, null, null, null, null, null),
    ('1e', 'b8', 'b9', 'PENDIENTE_AUTORIZACION', 14, null, null, null, null, null),
    ('1f', 'b1', 'b2', 'PENDIENTE_AUTORIZACION', 15, null, null, null, null, null),
    ('20', 'b6', 'b7', 'PENDIENTE_AUTORIZACION', 16, null, null, null, null, null),
    ('21', 'bc', 'bd', 'PENDIENTE_AUTORIZACION', 17, null, null, null, null, null),
    ('22', 'b1', 'b5', 'PENDIENTE_AUTORIZACION', 18, null, null, null, null, null),
    ('23', 'b5', 'b1', 'PENDIENTE_AUTORIZACION', 19, null, null, null, null, null),
    ('24', 'b8', 'b9', 'PENDIENTE_AUTORIZACION', 20, null, null, null, null, null),
    ('25', 'b3', 'b2', 'PENDIENTE_AUTORIZACION', 21, null, null, null, null, null),
    ('26', 'b2', 'b1', 'PENDIENTE_AUTORIZACION', 22, null, null, null, null, null),
    ('27', 'b6', 'b7', 'PENDIENTE_AUTORIZACION', 23, null, null, null, null, null),
    ('28', 'b8', 'b9', 'PENDIENTE_AUTORIZACION', 24, null, null, null, null, null)
  ) x(id, de, a, est, min, baja, monto, dec, decen, mot);

-- 1f se pidió antes de que b1 y b2 estuvieran inscriptos (alta del 01/08): no es de ninguna campaña.
update public.transferencia_stock set fecha_solicitud = '2026-07-01 12:00:00+00' where id = pg_temp.u('1f');
-- 22 y 23 se pidieron el 15/08: b5 todavía no estaba inscripta (alta del 01/09), una vez como quien recibe y otra
-- como quien da.
update public.transferencia_stock set fecha_solicitud = '2026-08-15 12:00:00+00' where id in (pg_temp.u('22'), pg_temp.u('23'));
-- 1e y 20 se pidieron dentro de la inscripción de las campañas que terminaron hace 16 y 15 días; 27 también, una
-- hora después de la 20, y 28 una hora antes de la 1e.
update public.transferencia_stock set fecha_solicitud = (public.hoy_montevideo() - 30)::timestamptz + interval '12 hours'
 where id in (pg_temp.u('1e'), pg_temp.u('20'));
update public.transferencia_stock set fecha_solicitud = (public.hoy_montevideo() - 30)::timestamptz + interval '13 hours'
 where id = pg_temp.u('27');
update public.transferencia_stock set fecha_solicitud = (public.hoy_montevideo() - 30)::timestamptz + interval '11 hours'
 where id = pg_temp.u('28');
-- 24 se pidió ayer: la campaña de b8 y b9 había terminado hace 16 días.
update public.transferencia_stock set fecha_solicitud = (public.hoy_montevideo() - 1)::timestamptz + interval '12 hours'
 where id = pg_temp.u('24');

-- Líneas (transferencia, producto, cantidad, costo guardado, dada de baja).
insert into public.transferencia_item (transferencia_id, producto_id, cantidad, precio_unitario, deleted_at)
select pg_temp.u(x.t), pg_temp.u(x.pr), x.c, x.pu, x.baja
  from (values
    ('11', '91', 2, null::bigint, null::timestamptz),
    ('11', '92', 1, null,         null),
    ('11', '93', 5, null,         now()),
    ('12', '91', 1, null,         null),
    ('12', '92', 9, null,         null),
    ('13', '91', 1, null,         null),
    ('13', '94', 1, null,         null),
    ('15', '91', 1, 1000,         null),
    ('16', '91', 1, null,         null),
    ('17', '91', 1, null,         null),
    ('18', '91', 1, null,         null),
    ('19', '91', 1, null,         null),
    ('1a', '91', 1, null,         null),
    ('1b', '91', 2, null,         null),
    ('1b', '93', 5, null,         now()),
    ('1c', '91', 1, null,         null),
    ('1d', '93', 4, null,         null),
    ('1e', '91', 1, null,         null),
    ('1f', '91', 1, null,         null),
    ('20', '91', 1, null,         null),
    ('21', '91', 1, null,         null),
    ('22', '91', 1, null,         null),
    ('23', '93', 1, null,         null),
    ('24', '91', 1, null,         null),
    ('25', '91', 1, null,         null),
    ('26', '93', 1, null,         null),
    ('27', '91', 2, null,         null),
    ('28', '95', 1, null,         null)
  ) x(t, pr, c, pu, baja);

-- ============================================================================
-- 1. Los privilegios
-- ============================================================================

select is((select has_function_privilege('authenticated', 'public.transferencias_de_campania(uuid)', 'execute')
              and has_function_privilege('authenticated', 'public.transferencia_lineas(uuid)', 'execute')
              and has_function_privilege('authenticated', 'public.autorizar_transferencia(uuid)', 'execute')
              and has_function_privilege('authenticated', 'public.rechazar_transferencia(uuid, text)', 'execute')),
          true, 'el coordinador (authenticated) ejecuta las cuatro RPC');
select is((select has_function_privilege('anon', 'public.transferencias_de_campania(uuid)', 'execute')
              or has_function_privilege('anon', 'public.transferencia_lineas(uuid)', 'execute')
              or has_function_privilege('anon', 'public.autorizar_transferencia(uuid)', 'execute')
              or has_function_privilege('anon', 'public.rechazar_transferencia(uuid, text)', 'execute')),
          false, 'anon no ejecuta ninguna');
select is((select has_function_privilege('service_role', 'public.autorizar_transferencia(uuid)', 'execute')
              or has_function_privilege('service_role', 'public.rechazar_transferencia(uuid, text)', 'execute')),
          false, 'ni service_role: las decide un usuario con su sesión');
select is((select has_function_privilege('authenticated', 'public.transferencia_para(uuid, boolean)', 'execute')
              or has_function_privilege('authenticated', 'public.coordina_la_transferencia(uuid, uuid, timestamptz, boolean)', 'execute')
              or has_function_privilege('authenticated', 'public.trasladar_deuda_casa_editora(uuid, uuid, bigint)', 'execute')),
          false, 'las tres internas no las ejecuta nadie con JWT');
select is((select count(*)::int from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'public'
              and p.proname in ('transferencias_de_campania', 'transferencia_lineas', 'autorizar_transferencia',
                                'rechazar_transferencia', 'transferencia_para', 'coordina_la_transferencia',
                                'trasladar_deuda_casa_editora')
              and (not p.prosecdef or p.proconfig is null)), 0,
          'todas son SECURITY DEFINER con search_path fijo');

-- ============================================================================
-- 2. El permiso, primero
-- ============================================================================

select is(pg_temp.err(null, format('select * from public.transferencias_de_campania(%L)', pg_temp.u('e1'))),
          '42501', 'la bandeja sin sesión: sin permiso');
select is(pg_temp.err(pg_temp.u('a0'), format('select * from public.transferencias_de_campania(%L)', pg_temp.u('e1'))),
          '42501', 'un colportor no ve la bandeja');
select is(pg_temp.err(pg_temp.u('a3'), format('select * from public.transferencias_de_campania(%L)', pg_temp.u('e1'))),
          '42501', 'ni quien no tiene rol');
select is(pg_temp.err(pg_temp.u('a4'), format('select * from public.transferencias_de_campania(%L)', pg_temp.u('e1'))),
          '42501', 'ni un coordinador con el rol vencido');
select is(pg_temp.err(pg_temp.u('a2'), format('select * from public.transferencias_de_campania(%L)', pg_temp.u('e1'))),
          '42501', 'ni el coordinador de OTRA campaña');
select is(pg_temp.err(pg_temp.u('a1'), format('select * from public.transferencias_de_campania(%L)', pg_temp.u('c0'))),
          'CZ001', 'una campaña que no existe: CZ001');
select is(pg_temp.err(pg_temp.u('a1'), format('select * from public.transferencias_de_campania(%L)', pg_temp.u('e1'))),
          'ok', 'el coordinador de la campaña la ve');
select is(pg_temp.err(pg_temp.u('ad'), format('select * from public.transferencias_de_campania(%L)', pg_temp.u('e1'))),
          'ok', 'y el administrador también');

select is(pg_temp.err(null, format('select * from public.autorizar_transferencia(%L)', pg_temp.u('11'))),
          '42501', 'autorizar sin sesión: sin permiso');
select is(pg_temp.err(pg_temp.u('b1'), format('select * from public.autorizar_transferencia(%L)', pg_temp.u('11'))),
          '42501', 'quien da no se autoriza su propia transferencia');
select is(pg_temp.err(pg_temp.u('b2'), format('select * from public.rechazar_transferencia(%L, %L)', pg_temp.u('11'), 'no')),
          '42501', 'ni quien recibe puede rechazarla');
select is(pg_temp.err(pg_temp.u('a3'), format('select * from public.autorizar_transferencia(%L)', pg_temp.u('11'))),
          '42501', 'ni quien no tiene rol');
select is(pg_temp.err(pg_temp.u('a4'), format('select * from public.autorizar_transferencia(%L)', pg_temp.u('11'))),
          '42501', 'ni un coordinador con el rol vencido');
select is(pg_temp.err(pg_temp.u('a2'), format('select * from public.autorizar_transferencia(%L)', pg_temp.u('11'))),
          '42501', 'ni el coordinador de otra campaña');
select is(pg_temp.err(pg_temp.u('a2'), format('select * from public.rechazar_transferencia(%L, %L)', pg_temp.u('11'), 'no')),
          '42501', 'ni rechazarla');
select is(pg_temp.err(pg_temp.u('a2'), format('select * from public.transferencia_lineas(%L)', pg_temp.u('11'))),
          '42501', 'ni leer sus líneas');
select is(pg_temp.err(pg_temp.u('a1'), format('select * from public.transferencia_lineas(%L)', pg_temp.u('18'))),
          '42501', 'a1 no lee una transferencia con un colportor de otra campaña (b4)');
select is(pg_temp.err(pg_temp.u('a1'), format('select * from public.autorizar_transferencia(%L)', pg_temp.u('18'))),
          '42501', 'ni la autoriza');
select is(pg_temp.err(pg_temp.u('a2'), format('select * from public.autorizar_transferencia(%L)', pg_temp.u('18'))),
          '42501', 'a2 tampoco: b1 no es de su campaña');
select is(pg_temp.err(pg_temp.u('a1'), format('select * from public.transferencia_lineas(%L)', pg_temp.u('19'))),
          'ok', 'las líneas de una con un colportor dado de baja SÍ se leen (lectura)');
select is(pg_temp.err(pg_temp.u('a1'), format('select * from public.autorizar_transferencia(%L)', pg_temp.u('19'))),
          '42501', 'pero no se autoriza: b3 está de baja (decidir es más estricto que ver)');
select is(pg_temp.err(pg_temp.u('a1'), format('select * from public.rechazar_transferencia(%L, %L)', pg_temp.u('19'), 'no')),
          '42501', 'ni se rechaza');
select is(pg_temp.err(pg_temp.u('a1'), format('select * from public.autorizar_transferencia(%L)', pg_temp.u('1e'))),
          '42501', 'una campaña que terminó hace 16 días ya no se escribe');
select is(pg_temp.err(pg_temp.u('a1'), format('select * from public.transferencia_lineas(%L)', pg_temp.u('1e'))),
          'ok', 'pero se lee');
select is(pg_temp.err(pg_temp.u('a1'), format('select * from public.autorizar_transferencia(%L)', pg_temp.u('1f'))),
          '42501', 'una pedida antes de que los dos estuvieran inscriptos no es de ninguna campaña');
select is(pg_temp.err(pg_temp.u('a1'), format('select * from public.autorizar_transferencia(%L)', pg_temp.u('1a'))),
          'TR001', 'una dada de baja no existe');
select is(pg_temp.err(pg_temp.u('a1'), format('select * from public.autorizar_transferencia(%L)', pg_temp.u('c0'))),
          'TR001', 'ni un id inventado');
select is(pg_temp.err(pg_temp.u('a1'), format('select * from public.rechazar_transferencia(%L, %L)', pg_temp.u('c0'), 'no')),
          'TR001', 'tampoco para rechazar');
select is(pg_temp.err(pg_temp.u('a1'), format('select * from public.transferencia_lineas(%L)', pg_temp.u('c0'))),
          'TR001', 'ni para leer');

-- ============================================================================
-- 3. La bandeja
-- ============================================================================

select is(pg_temp.ids(pg_temp.u('a1'), 'e1'), '26,25,1d,1c,1b,19,16,15,14,13,12,11',
          'la bandeja de Abierta: las más recientes primero; sin la cancelada, la dada de baja, la de otra campaña, '
          'las de antes de la inscripción de b5 ni la de la campaña borrada');
select is(pg_temp.ids(pg_temp.u('ad'), 'e1'), '26,25,1d,1c,1b,19,16,15,14,13,12,11', 'el administrador ve lo mismo');
select is(pg_temp.ids(pg_temp.u('a1'), 'e5'), '27,20', 'las de la campaña que terminó hace 15 días salen');
select is(pg_temp.ids(pg_temp.u('a1'), 'e4'), '1e,28',
          'y las de la que terminó hace 16 (se leen aunque ya no se escriban); la pedida ayer, ya terminada, no');
select is(pg_temp.ids(pg_temp.u('a2'), 'e2'), '', 'la campaña de a2 no tiene ninguna: b4 no tiene con quién');

select is((select to_jsonb(t) - 'transferencia_id' - 'fecha_solicitud'
             from jsonb_to_recordset(pg_temp.lista(pg_temp.u('a1'), 'e1')) as t(transferencia_id text, origen_id text,
                  origen_nombre text, origen_apellido text, destino_id text, destino_nombre text, destino_apellido text,
                  ciudad_id text, ciudad_nombre text, departamento text, estado text, fecha_solicitud text,
                  productos int, unidades int, monto_deuda bigint, decidido_en text, motivo_rechazo text)
            where right(t.transferencia_id, 2) = '11'),
          jsonb_build_object('origen_id', pg_temp.u('b1'), 'origen_nombre', 'Ana', 'origen_apellido', 'Alfa',
                             'destino_id', pg_temp.u('b2'), 'destino_nombre', 'Beto', 'destino_apellido', 'Bravo',
                             'ciudad_id', pg_temp.u('c1'), 'ciudad_nombre', 'Ciudad uno q106',
                             'departamento', 'Departamento de prueba uno', 'estado', 'PENDIENTE_AUTORIZACION',
                             'productos', 2, 'unidades', 3, 'monto_deuda', 5500, 'decidido_en', null,
                             'motivo_rechazo', null),
          'una por autorizar: quién da y quién recibe, la ciudad de quien da, 2 productos, 3 unidades y la deuda estimada con el costo vigente (la línea dada de baja no cuenta)');
select is((select t.monto_deuda from jsonb_to_recordset(pg_temp.lista(pg_temp.u('a1'), 'e1'))
              as t(transferencia_id text, monto_deuda bigint) where right(t.transferencia_id, 2) = '13'),
          null::bigint, 'con un producto sin costo la deuda no se estima (null)');
select is((select t.monto_deuda from jsonb_to_recordset(pg_temp.lista(pg_temp.u('a1'), 'e1'))
              as t(transferencia_id text, monto_deuda bigint) where right(t.transferencia_id, 2) = '14'),
          null::bigint, 'ni sin líneas');
select is((select t.productos from jsonb_to_recordset(pg_temp.lista(pg_temp.u('a1'), 'e1'))
              as t(transferencia_id text, productos int) where right(t.transferencia_id, 2) = '14'),
          0, 'una sin líneas sale con 0 productos');
select is((select t.monto_deuda from jsonb_to_recordset(pg_temp.lista(pg_temp.u('a1'), 'e1'))
              as t(transferencia_id text, monto_deuda bigint) where right(t.transferencia_id, 2) = '15'),
          1000::bigint, 'una autorizada trae la deuda que quedó guardada, no la estimada con el costo de hoy');
select is((select t.motivo_rechazo from jsonb_to_recordset(pg_temp.lista(pg_temp.u('a1'), 'e1'))
              as t(transferencia_id text, motivo_rechazo text) where right(t.transferencia_id, 2) = '16'),
          'No hay stock', 'una rechazada trae el motivo');
select is((select t.ciudad_nombre from jsonb_to_recordset(pg_temp.lista(pg_temp.u('a1'), 'e1'))
              as t(transferencia_id text, ciudad_nombre text) where right(t.transferencia_id, 2) = '1d'),
          null::text, 'si la zona de quien da está dada de baja, la ciudad es null («Sin ciudad»)');
select is((select t.ciudad_nombre from jsonb_to_recordset(pg_temp.lista(pg_temp.u('a1'), 'e1'))
              as t(transferencia_id text, ciudad_nombre text) where right(t.transferencia_id, 2) = '25'),
          null::text, 'ni si quien da se dio de baja de la campaña, aunque tuviera zona');
select is((select t.ciudad_nombre from jsonb_to_recordset(pg_temp.lista(pg_temp.u('a1'), 'e1'))
              as t(transferencia_id text, ciudad_nombre text) where right(t.transferencia_id, 2) = '12'),
          'Ciudad uno q106', 'con zona vigente, la ciudad de la zona de quien da');

-- ============================================================================
-- 4. Las líneas
-- ============================================================================

select is(pg_temp.lineas(pg_temp.u('a1'), '11'),
          jsonb_build_array(
            jsonb_build_object('producto_id', pg_temp.u('92'), 'producto_nombre', 'Libro Dos', 'producto_tipo', 'LIBRO',
                               'cantidad', 1, 'precio_unitario', 2500, 'subtotal', 2500,
                               'tiene_quien_da', 3, 'debe_entregar_quien_recibe', 0, 'tiene_quien_recibe', 0),
            jsonb_build_object('producto_id', pg_temp.u('91'), 'producto_nombre', 'Libro Uno', 'producto_tipo', 'LIBRO',
                               'cantidad', 2, 'precio_unitario', 1500, 'subtotal', 3000,
                               'tiene_quien_da', 5, 'debe_entregar_quien_recibe', 3, 'tiene_quien_recibe', 1)),
          'las líneas por nombre, con el costo, el stock de los dos y lo que debe entregar quien recibe (la línea dada de baja, la entrega hecha y la venta de otro no cuentan)');
select is(pg_temp.lineas(pg_temp.u('a1'), '15') -> 0 ->> 'precio_unitario', '1000',
          'una línea con costo guardado muestra el guardado, no el vigente (1500)');
select is(pg_temp.lineas(pg_temp.u('a1'), '15') -> 0 ->> 'subtotal', '1000', 'y valúa el subtotal con el guardado');
select is(pg_temp.err(pg_temp.u('a1'), format('select * from public.transferencia_lineas(%L)', pg_temp.u('1a'))),
          'TR001', 'las líneas de una dada de baja tampoco existen');
select is(pg_temp.lineas(pg_temp.u('a1'), '13') -> 1 ->> 'precio_unitario', null,
          'un producto sin costo sale con costo null');
select is(pg_temp.lineas(pg_temp.u('a1'), '14'), '[]'::jsonb, 'una sin líneas devuelve la lista vacía');
select is(pg_temp.lineas(pg_temp.u('a1'), '1d') -> 0 ->> 'tiene_quien_recibe', '0',
          'el stock dado de baja de quien recibe cuenta como cero');

-- ============================================================================
-- 5. Autorizar
-- ============================================================================

select is(pg_temp.estado('11'), 'PENDIENTE_AUTORIZACION', 'antes: por autorizar');
select is((pg_temp.aut(pg_temp.u('a1'), '11') -> 0) - 'decidido_en',
          jsonb_build_object('transferencia_id', pg_temp.u('11'), 'estado', 'AUTORIZADO', 'monto_deuda', 5500,
                             'ya_estaba', false),
          'a1 la autoriza: AUTORIZADO, con la deuda que pasa (3000 + 2500)');
select is(pg_temp.estado('11'), 'AUTORIZADO', 'queda AUTORIZADO');
select is((select (coordinador_id, monto_deuda, decidido_en is not null)::text from public.transferencia_stock
            where id = pg_temp.u('11')),
          format('(%s,5500,t)', pg_temp.u('a1')), 'quién la decidió, la deuda y cuándo');
select is((pg_temp.stock('b1', '91'), pg_temp.stock('b1', '92'))::text, '(3,2)', 'quien da: 5 - 2 y 3 - 1');
select is((pg_temp.stock('b2', '91'), pg_temp.stock('b2', '92'))::text, '(3,1)',
          'quien recibe: 1 + 2 (la fila que tenía) y 0 + 1 (fila nueva)');
select is(pg_temp.deuda('b1'), 14500::bigint, 'la deuda de quien da baja: 20000 - 5500');
select is(pg_temp.deuda('b2'), 5500::bigint, 'y la de quien recibe sube: no tenía cuenta, se crea con 5500');
select is(pg_temp.n_mov('11'), 4::bigint, 'cuatro movimientos de stock, con la transferencia como origen');
select is((select array_agg(m.tipo || ':' || m.cantidad order by m.tipo, m.producto_id) from public.movimiento_stock m
            where m.transferencia_id = pg_temp.u('11') and m.usuario_id = pg_temp.u('b1')),
          array['SALIDA_TRANSFERENCIA:2', 'SALIDA_TRANSFERENCIA:1'], 'las salidas son de quien da');
select is((select array_agg(m.tipo || ':' || m.cantidad order by m.tipo, m.producto_id) from public.movimiento_stock m
            where m.transferencia_id = pg_temp.u('11') and m.usuario_id = pg_temp.u('b2')),
          array['ENTRADA_TRANSFERENCIA:2', 'ENTRADA_TRANSFERENCIA:1'], 'y las entradas, de quien recibe');
select is((select array_agg(i.precio_unitario order by i.producto_id) from public.transferencia_item i
            where i.transferencia_id = pg_temp.u('11') and i.deleted_at is null),
          array[1500::bigint, 2500::bigint], 'cada línea guarda el costo con el que se valuó');
select is((select i.precio_unitario from public.transferencia_item i
            where i.transferencia_id = pg_temp.u('11') and i.deleted_at is not null), null::bigint,
          'la línea dada de baja no se toca');
select is(pg_temp.n_audit('transferencia_autorizada', '11'), 1::bigint, 'deja un evento en la auditoría');
select is((select array_agg(k order by k) from auditoria.audit_log a, jsonb_object_keys(a.metadata) k
            where a.event_type = 'transferencia_autorizada' and a.fila_id = pg_temp.u('11')),
          array['destino_id', 'monto_deuda', 'origen_id', 'productos', 'unidades'],
          'con solo ids, cantidades y monto');
select is((select (a.actor_user_id, a.target_user_id, a.tabla)::text from auditoria.audit_log a
            where a.event_type = 'transferencia_autorizada' and a.fila_id = pg_temp.u('11')),
          format('(%s,%s,transferencia_stock)', pg_temp.u('a1'), pg_temp.u('b2')), 'quién la autorizó, sobre quién y en qué tabla');
select is((select (a.metadata ->> 'productos', a.metadata ->> 'unidades', a.metadata ->> 'monto_deuda')::text
              from auditoria.audit_log a where a.event_type = 'transferencia_autorizada' and a.fila_id = pg_temp.u('11')),
          '(2,3,5500)', 'los productos (2), las unidades (3) y la deuda (5500) del evento');
select ok(auditoria.metadata_sin_datos_personales((select a.metadata from auditoria.audit_log a
            where a.event_type = 'transferencia_autorizada' and a.fila_id = pg_temp.u('11'))),
          'el detalle pasa el control de datos personales');

-- El reintento no mueve nada dos veces.
select is((pg_temp.aut(pg_temp.u('a1'), '11') -> 0) - 'decidido_en',
          jsonb_build_object('transferencia_id', pg_temp.u('11'), 'estado', 'AUTORIZADO', 'monto_deuda', 5500,
                             'ya_estaba', true),
          'un reintento de quien ya la autorizó: ya_estaba = true');
select is((pg_temp.stock('b1', '91'), pg_temp.stock('b2', '91'), pg_temp.deuda('b1'), pg_temp.deuda('b2'), pg_temp.n_mov('11'))::text,
          '(3,3,14500,5500,4)', 'sin mover stock, deuda ni movimientos otra vez');
select is(pg_temp.n_audit('transferencia_autorizada', '11'), 1::bigint, 'ni repetir el evento');
select is(pg_temp.err(pg_temp.u('ad'), format('select * from public.autorizar_transferencia(%L)', pg_temp.u('11'))),
          'TR002', 'otra persona (el admin) que llega después: ya no está por autorizar');
select is(pg_temp.err(pg_temp.u('a1'), format('select * from public.rechazar_transferencia(%L, %L)', pg_temp.u('11'), 'tarde')),
          'TR002', 'y una autorizada ya no se rechaza');

-- Los errores no mueven nada (todo o nada).
select is(pg_temp.err(pg_temp.u('a1'), format('select * from public.autorizar_transferencia(%L)', pg_temp.u('12'))),
          'TR003', 'quien da no tiene el stock completo (92: tiene 2 y hacen falta 9): TR003');
select alike(pg_temp.aut(pg_temp.u('a1'), '12') ->> 'mensaje', '%Libro Dos (tiene 2 y hacen falta 9)%',
             'el mensaje dice qué producto y cuánto falta');
select is((pg_temp.stock('b1', '91'), pg_temp.stock('b1', '92'), pg_temp.stock('b2', '91'), pg_temp.deuda('b1'),
           pg_temp.n_mov('12'), pg_temp.estado('12'))::text,
          '(3,2,3,14500,0,PENDIENTE_AUTORIZACION)', 'y no se movió ni la línea que sí alcanzaba: sigue por autorizar');
select is(pg_temp.err(pg_temp.u('a1'), format('select * from public.autorizar_transferencia(%L)', pg_temp.u('13'))),
          'TR005', 'un producto sin costo de la casa editora: TR005');
select alike(pg_temp.aut(pg_temp.u('a1'), '13') ->> 'mensaje', '%Sin Costo%', 'el mensaje dice cuál');
select is(pg_temp.err(pg_temp.u('a1'), format('select * from public.autorizar_transferencia(%L)', pg_temp.u('14'))),
          'TR005', 'una sin líneas: TR005');
select is(pg_temp.err(pg_temp.u('ad'), format('select * from public.autorizar_transferencia(%L)', pg_temp.u('15'))),
          'TR002', 'una que ya estaba autorizada por a1 (fixture), vista por otro: TR002');
select is(pg_temp.err(pg_temp.u('a1'), format('select * from public.autorizar_transferencia(%L)', pg_temp.u('16'))),
          'TR002', 'una rechazada no se autoriza');
select is(pg_temp.err(pg_temp.u('a1'), format('select * from public.autorizar_transferencia(%L)', pg_temp.u('17'))),
          'TR002', 'ni una cancelada');

-- El ADMIN: crea o reactiva las cuentas, reactiva el stock dado de baja y decide aunque sean de campañas distintas.
select is(pg_temp.aut(pg_temp.u('ad'), '1d') -> 0 ->> 'estado', 'AUTORIZADO', 'el admin autoriza una de b5 a b1');
select is((pg_temp.stock('b5', '93'), pg_temp.stock('b1', '93'))::text, '(6,4)',
          'el stock de quien recibe estaba dado de baja (50): arranca de cero y suma 4, y vuelve a estar vivo');
select is((pg_temp.deuda('b5'), pg_temp.deuda('b1'))::text, '(-800,15300)',
          'la cuenta de b5 estaba dada de baja (777): se reactiva desde cero y queda a favor; b1 suma 800');
select is((select coordinador_id from public.transferencia_stock where id = pg_temp.u('1d')), pg_temp.u('ad'),
          'queda quién la decidió (el admin)');
select is(pg_temp.aut(pg_temp.u('ad'), '18') -> 0 ->> 'estado', 'AUTORIZADO',
          'el admin autoriza una entre b1 (Abierta) y b4 (Otra)');
select is((pg_temp.stock('b1', '91'), pg_temp.stock('b4', '91'), pg_temp.deuda('b1'), pg_temp.deuda('b4'))::text,
          '(2,1,13800,1500)', 'el stock y la deuda de las dos puntas');
select is(pg_temp.aut(pg_temp.u('a1'), '20') -> 0 ->> 'estado', 'AUTORIZADO',
          'a1 autoriza dentro del plazo de 15 días de una campaña terminada');
select is((pg_temp.stock('b6', '91'), pg_temp.stock('b7', '91'), pg_temp.deuda('b6'), pg_temp.deuda('b7'))::text,
          '(2,1,-1500,1500)', 'quien da queda con saldo a favor');

-- ============================================================================
-- 6. Rechazar
-- ============================================================================

select is(pg_temp.err(pg_temp.u('a1'), format('select * from public.rechazar_transferencia(%L, null)', pg_temp.u('1c'))),
          'TR004', 'sin motivo: TR004');
select is(pg_temp.err(pg_temp.u('a1'), format('select * from public.rechazar_transferencia(%L, %L)', pg_temp.u('1c'), '   ')),
          'TR004', 'con el motivo en blanco: TR004');
select is(pg_temp.err(pg_temp.u('a1'), format('select * from public.rechazar_transferencia(%L, %L)', pg_temp.u('1c'), repeat('x', 501))),
          'TR004', 'con más de 500 caracteres: TR004');
select is(pg_temp.estado('1c'), 'PENDIENTE_AUTORIZACION', 'y sigue por autorizar');

select is((pg_temp.rech(pg_temp.u('a1'), '1b', '  No hay libros  ') -> 0) - 'decidido_en',
          jsonb_build_object('transferencia_id', pg_temp.u('1b'), 'estado', 'RECHAZADO', 'ya_estaba', false),
          'rechazar con motivo: RECHAZADO');
select is((select (estado, motivo_rechazo, coordinador_id, decidido_en is not null, monto_deuda)::text
             from public.transferencia_stock where id = pg_temp.u('1b')),
          format('(RECHAZADO,"No hay libros",%s,t,)', pg_temp.u('a1')), 'se guarda recortado, con quién y cuándo');
select is((pg_temp.stock('b1', '91'), pg_temp.stock('b2', '91'), pg_temp.deuda('b1'), pg_temp.n_mov('1b'))::text,
          '(2,3,13800,0)', 'no toca el stock ni la deuda');
select is(pg_temp.n_audit('transferencia_rechazada', '1b'), 1::bigint, 'deja un evento en la auditoría');
select is((select array_agg(k order by k) from auditoria.audit_log a, jsonb_object_keys(a.metadata) k
            where a.event_type = 'transferencia_rechazada' and a.fila_id = pg_temp.u('1b')),
          array['destino_id', 'origen_id', 'productos', 'unidades'], 'con solo ids y cantidades');
select is((select count(*)::int from auditoria.audit_log a where a.fila_id = pg_temp.u('1b')
              and a.metadata::text like '%libros%'), 0, 'el motivo, que es texto libre, no se copia');
select is((select (a.metadata ->> 'productos', a.metadata ->> 'unidades')::text from auditoria.audit_log a
            where a.event_type = 'transferencia_rechazada' and a.fila_id = pg_temp.u('1b')),
          '(1,2)', 'un producto y dos unidades (la línea dada de baja no cuenta)');
select is((select (a.actor_user_id, a.target_user_id, a.tabla)::text from auditoria.audit_log a
            where a.event_type = 'transferencia_rechazada' and a.fila_id = pg_temp.u('1b')),
          format('(%s,%s,transferencia_stock)', pg_temp.u('a1'), pg_temp.u('b2')), 'quién la rechazó y sobre quién (quien recibe)');
select is(pg_temp.rech(pg_temp.u('a1'), '1b', 'No hay libros') -> 0 ->> 'ya_estaba', 'true',
          'un reintento con el mismo motivo: ya_estaba = true');
select is(pg_temp.n_audit('transferencia_rechazada', '1b'), 1::bigint, 'sin repetir el evento');
select is(pg_temp.err(pg_temp.u('ad'), format('select * from public.rechazar_transferencia(%L, %L)', pg_temp.u('1b'), 'No hay libros')),
          'TR002', 'el mismo motivo pero de otra persona (el admin): ya no está por autorizar, no es un reintento');
select is(pg_temp.err(pg_temp.u('a1'), format('select * from public.rechazar_transferencia(%L, %L)', pg_temp.u('1b'), 'Otro motivo')),
          'TR002', 'con otro motivo ya no está por autorizar: TR002');
select is(pg_temp.err(pg_temp.u('a1'), format('select * from public.autorizar_transferencia(%L)', pg_temp.u('1b'))),
          'TR002', 'y una rechazada tampoco se autoriza');
select is(pg_temp.err(pg_temp.u('a1'), format('select * from public.rechazar_transferencia(%L, %L)', pg_temp.u('1c'), repeat('y', 500))),
          'ok', 'un motivo de justo 500 caracteres entra');

-- ============================================================================
-- 7. Las columnas nuevas y lo de siempre
-- ============================================================================

select is(pg_temp.err_srv(format($$ update public.transferencia_stock set estado = 'RECHAZADO', motivo_rechazo = null where id = %L $$, pg_temp.u('12'))),
          '23514', 'una transferencia rechazada sin motivo no entra');
select is(pg_temp.err_srv(format($$ update public.transferencia_stock set estado = 'RECHAZADO', motivo_rechazo = '   ' where id = %L $$, pg_temp.u('12'))),
          '23514', 'ni con el motivo en blanco');
select is(pg_temp.err_srv(format($$ update public.transferencia_stock set motivo_rechazo = 'algo' where id = %L $$, pg_temp.u('12'))),
          '23514', 'un motivo en una que no está rechazada tampoco');
select is(pg_temp.err_srv(format($$ update public.transferencia_stock set monto_deuda = -1 where id = %L $$, pg_temp.u('12'))),
          '23514', 'la deuda no es negativa');
select is(pg_temp.err_srv(format($$ update public.transferencia_item set precio_unitario = -1 where transferencia_id = %L $$, pg_temp.u('12'))),
          '23514', 'ni el costo de una línea');
select is(pg_temp.err_dml(pg_temp.u('b1'), format($$ update public.transferencia_stock set estado = 'AUTORIZADO' where id = %L $$, pg_temp.u('12'))),
          '42501', 'un colportor sigue sin poder escribir la tabla');
select is((select count(*)::int from public.transferencia_stock where id = pg_temp.u('12')
              and estado = 'PENDIENTE_AUTORIZACION'), 1, 'y la fila no cambió');

-- ============================================================================
-- 8. Casos límite del permiso y de los datos
-- ============================================================================

-- La campaña dada de baja no cuenta, aunque la coordine a1 y los dos estén inscriptos.
select is(pg_temp.err(pg_temp.u('a1'), format('select * from public.transferencia_lineas(%L)', pg_temp.u('21'))),
          '42501', 'una entre dos colportores de una campaña dada de baja no se lee');
select is(pg_temp.err(pg_temp.u('a1'), format('select * from public.autorizar_transferencia(%L)', pg_temp.u('21'))),
          '42501', 'ni se autoriza');
select is(pg_temp.err(pg_temp.u('ad'), format('select * from public.transferencias_de_campania(%L)', pg_temp.u('e7'))),
          'CZ001', 'ni la bandeja de esa campaña existe, tampoco para el admin');
-- Lo pedido antes de que alguno de los dos estuviera inscripto no es de la campaña, sea quien da o quien recibe.
select is(pg_temp.err(pg_temp.u('a1'), format('select * from public.transferencia_lineas(%L)', pg_temp.u('22'))),
          '42501', 'pedida antes de la inscripción de quien recibe: no se lee');
select is(pg_temp.err(pg_temp.u('a1'), format('select * from public.transferencia_lineas(%L)', pg_temp.u('23'))),
          '42501', 'pedida antes de la inscripción de quien da: tampoco');
select is(pg_temp.err(pg_temp.u('a1'), format('select * from public.autorizar_transferencia(%L)', pg_temp.u('22'))),
          '42501', 'ni se autoriza (quien recibe)');
select is(pg_temp.err(pg_temp.u('a1'), format('select * from public.autorizar_transferencia(%L)', pg_temp.u('23'))),
          '42501', 'ni se autoriza (quien da)');
-- Pedida cuando la campaña ya había terminado: no es de la campaña, aunque los dos sigan inscriptos.
select is(pg_temp.err(pg_temp.u('a1'), format('select * from public.transferencia_lineas(%L)', pg_temp.u('24'))),
          '42501', 'pedida después del fin de la campaña: no se lee');
-- Quien da se dio de baja de la campaña: se ve, no se decide.
select is(pg_temp.err(pg_temp.u('a1'), format('select * from public.transferencia_lineas(%L)', pg_temp.u('25'))),
          'ok', 'si quien da está de baja, sus líneas se leen');
select is(pg_temp.err(pg_temp.u('a1'), format('select * from public.autorizar_transferencia(%L)', pg_temp.u('25'))),
          '42501', 'pero no se autoriza');
select is(pg_temp.err(pg_temp.u('a1'), format('select * from public.rechazar_transferencia(%L, %L)', pg_temp.u('25'), 'no')),
          '42501', 'ni se rechaza');

-- El stock dado de baja de quien da cuenta como cero: ni se ve ni alcanza.
select is(pg_temp.lineas(pg_temp.u('a1'), '26') -> 0 ->> 'tiene_quien_da', '0',
          'quien da tiene el stock de la Revista dado de baja (7): cuenta como cero');
select is(pg_temp.err(pg_temp.u('a1'), format('select * from public.autorizar_transferencia(%L)', pg_temp.u('26'))),
          'TR003', 'y no alcanza para autorizar');
select is((pg_temp.stock('b2', '93'), pg_temp.stock('b1', '93'), pg_temp.n_mov('26'))::text, '(-1,4,0)',
          'sin tocar nada');

-- Con justo lo que tiene, alcanza.
select is(pg_temp.stock('b6', '91'), 2, 'b6 tiene 2 del Libro Uno después de la 20');
select is(pg_temp.aut(pg_temp.u('a1'), '27') -> 0 ->> 'estado', 'AUTORIZADO', 'darlo todo (2 de 2) se puede');
select is((pg_temp.stock('b6', '91'), pg_temp.stock('b7', '91'), pg_temp.deuda('b6'), pg_temp.deuda('b7'))::text,
          '(0,3,-4500,4500)', 'quien da se queda en cero y la deuda pasa: 2 x 1500 = 3000 más lo anterior');

-- Una deuda de cero no abre cuentas.
select is(pg_temp.aut(pg_temp.u('ad'), '28') -> 0 ->> 'monto_deuda', '0', 'el admin autoriza una con costo cero: la deuda es 0');
select is((pg_temp.stock('b8', '95'), pg_temp.stock('b9', '95'), pg_temp.deuda('b8'), pg_temp.deuda('b9'))::text,
          '(0,1,-1,-1)', 'el stock pasa y nadie abre una cuenta de la casa editora por cero');

select * from finish();
rollback;
