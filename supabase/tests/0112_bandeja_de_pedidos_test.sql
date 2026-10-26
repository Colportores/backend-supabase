-- pgTAP · bandeja de pedidos del coordinador (migración 0112, backend-supabase#104, HU-STK-003, vista 35)
-- pedidos_de_campania(), pedido_lineas(), pedido_contexto(), autorizar_pedido(), rechazar_pedido() y
-- deshacer_decision_de_pedido(): la forma de las respuestas y los privilegios; el permiso primero (sin JWT,
-- colportor, sin rol, rol vencido, coordinador de otra campaña) y el de decisión, más estricto que el de
-- lectura (inscripción de baja, campaña cerrada hace más de 15 días); qué pedidos salen en la bandeja; las
-- líneas y el contexto de la cuenta; autorizar (todo, reducido, igual a lo pedido, lista vacía, cada error de
-- cantidades, reintento, estados que no se autorizan, deuda que se crea o se suma); rechazar (motivo
-- obligatorio, recortado, tope de 500, reintento); deshacer (plazo de 8 s, solo quien decidió, autorizado y
-- rechazado, reintento, pedido que siguió su camino); la auditoría sin el motivo; los CHECK de las columnas
-- nuevas; y que lo de siempre no cambia (la RLS de lectura del colportor).
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
  select ('01920000-0000-7000-8000-0000000112' || p_sufijo)::uuid
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

-- El SQLSTATE de lo que tira una consulta ('ok' si no tira).
create or replace function pg_temp.err(p_uid uuid, p_sql text) returns text language sql as $$
  select coalesce(pg_temp.como(p_uid, p_sql) ->> 'error', 'ok')
$$;

create or replace function pg_temp.aut(p_uid uuid, p_ped text, p_cant jsonb default null) returns jsonb language sql as $$
  select pg_temp.como(p_uid, format('select * from public.autorizar_pedido(%L, %L::jsonb)', pg_temp.u(p_ped), p_cant))
$$;
create or replace function pg_temp.rech(p_uid uuid, p_ped text, p_motivo text) returns jsonb language sql as $$
  select pg_temp.como(p_uid, format('select * from public.rechazar_pedido(%L, %L)', pg_temp.u(p_ped), p_motivo))
$$;
create or replace function pg_temp.des(p_uid uuid, p_ped text) returns jsonb language sql as $$
  select pg_temp.como(p_uid, format('select * from public.deshacer_decision_de_pedido(%L)', pg_temp.u(p_ped)))
$$;
create or replace function pg_temp.lista(p_uid uuid, p_camp text) returns jsonb language sql as $$
  select pg_temp.como(p_uid, format('select * from public.pedidos_de_campania(%L) ', pg_temp.u(p_camp)))
$$;
create or replace function pg_temp.lineas(p_uid uuid, p_ped text) returns jsonb language sql as $$
  select pg_temp.como(p_uid, format('select * from public.pedido_lineas(%L)', pg_temp.u(p_ped)))
$$;
create or replace function pg_temp.contexto(p_uid uuid, p_ped text) returns jsonb language sql as $$
  select pg_temp.como(p_uid, format('select * from public.pedido_contexto(%L)', pg_temp.u(p_ped)))
$$;

-- Los ids (sufijos) de la bandeja de una campaña, en el orden en que salen.
create or replace function pg_temp.ids(p_uid uuid, p_camp text) returns text language sql as $$
  select coalesce(string_agg(right(e ->> 'pedido_id', 2), ',' order by o), '')
    from jsonb_array_elements((select case when jsonb_typeof(l) = 'array' then l else '[]'::jsonb end
                                 from (select pg_temp.lista(p_uid, p_camp) l) q)) with ordinality t(e, o)
$$;

-- Lo que hay hoy en la deuda de un colportor (como el servidor).
create or replace function pg_temp.deuda(p_col text) returns bigint language sql as $$
  select coalesce((select deuda_total from public.estado_cuenta where usuario_id = pg_temp.u(p_col)), -1)
$$;

-- Hace que lo decidido hace p_seg segundos (para probar el plazo sin esperar).
create or replace function pg_temp.decidido_hace(p_ped text, p_seg numeric) returns void language sql as $$
  update public.pedido_casa_editora set decidido_en = clock_timestamp() - p_seg * interval '1 second'
   where id = pg_temp.u(p_ped)
$$;

create or replace function pg_temp.n_audit(p_evento text, p_ped text) returns bigint language sql as $$
  select count(*) from auditoria.audit_log where event_type = p_evento and fila_id = pg_temp.u(p_ped)
$$;

-- --- fixtures ------------------------------------------------------------------
-- Staff: a1 coordinador de Abierta, Cerrada, Reciente, Borde15, Borde16 y Vacía; a2 coordinador de Otra;
--        ad admin; a0 colportor; a3 sin rol; a4 coordinador con el rol vencido.
-- Colportores: b1 Ana Alfa (Abierta, zona Centro, ciudad uno)  b2 Beto Bravo (Abierta, sin zona)
--        b3 Carla Cruz (Abierta, inscripción dada de baja)  b4 Diego Duarte (Otra)  b5 Elena Eguren (Cerrada
--        hace más de 15 días)  b6 Fede Fuentes (Reciente: terminó hace 10 días; hoy en Nueva)  b7 Gabi Gómez (terminó hace
--        15 días justos)  b8 Hugo Haedo (terminó hace 16 días)  b9 Ines Ibarra (solo en la campaña Borrada;
--        su cuenta está dada de baja).
-- Campañas: e1 Abierta (sin fin, a1)  e2 Otra (a2)  e3 Cerrada (2025, a1)  e4 Reciente  e7 Borde15
--        e8 Borde16  e5 Vacía (a1)  e6 Borrada (a1).
-- Productos: 91 Libro Uno (1500)  92 Libro Dos (2500)  93 Revista Uno (200).
insert into auth.users (id, instance_id, aud, role, email, encrypted_password, confirmed_at, created_at, updated_at)
select pg_temp.u(s), '00000000-0000-0000-0000-000000000000',
       'authenticated', 'authenticated', 'bandeja-' || s || '@example.com', 'x', now(), now(), now()
  from unnest(array['a0','a1','a2','a3','a4','ad','b1','b2','b3','b4','b5','b6','b7','b8','b9']) s;

update public.usuario u set nombre = x.n, apellido = x.a
  from (values ('b1','Ana','Alfa'), ('b2','Beto','Bravo'), ('b3','Carla','Cruz'), ('b4','Diego','Duarte'),
               ('b5','Elena','Eguren'), ('b6','Fede','Fuentes'), ('b7','Gabi','Gómez'), ('b8','Hugo','Haedo')) x(s, n, a)
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

insert into public.pais (id, nombre, iso_code) values (pg_temp.u('c0'), 'Pais bandeja', 'ZU');
insert into public.ciudad (id, nombre, departamento, pais_id, lat_centro, lon_centro, zoom_inicial) values
  (pg_temp.u('c1'), 'Ciudad uno q104', 'Departamento de prueba uno', pg_temp.u('c0'), -34.91, -56.18, 13);

insert into public.campania (id, nombre, tipo, fecha_inicio, fecha_fin, coordinador_id, deleted_at) values
  (pg_temp.u('e1'), 'Abierta',  'VERANO', '2026-08-03', null, pg_temp.u('a1'), null),
  (pg_temp.u('e2'), 'Otra',     'VERANO', '2026-08-03', null, pg_temp.u('a2'), null),
  (pg_temp.u('e3'), 'Cerrada',  'VERANO', '2025-01-01', '2025-02-01', pg_temp.u('a1'), null),
  (pg_temp.u('e4'), 'Reciente', 'VERANO', public.hoy_montevideo() - 60, public.hoy_montevideo() - 10, pg_temp.u('a1'), null),
  (pg_temp.u('e7'), 'Borde15',  'VERANO', public.hoy_montevideo() - 90, public.hoy_montevideo() - 15, pg_temp.u('a1'), null),
  (pg_temp.u('e8'), 'Borde16',  'VERANO', public.hoy_montevideo() - 90, public.hoy_montevideo() - 16, pg_temp.u('a1'), null),
  (pg_temp.u('e5'), 'Vacía',    'VERANO', '2026-08-03', null, pg_temp.u('a1'), null),
  (pg_temp.u('e6'), 'Borrada',  'VERANO', '2026-08-03', null, pg_temp.u('a1'), now()),
  (pg_temp.u('e9'), 'Nueva',    'VERANO', public.hoy_montevideo() - 5, null, pg_temp.u('a2'), null);
insert into public.campania_ciudad (id, campania_id, ciudad_id) values
  (pg_temp.u('71'), pg_temp.u('e1'), pg_temp.u('c1'));
insert into public.zona (id, nombre, campania_ciudad_id, tipo_forma, color, poligono_geojson) values
  (pg_temp.u('d1'), 'Centro', pg_temp.u('71'), 'ESQUINAS', '#112233',
   '{"type":"Polygon","coordinates":[[[-56.19,-34.92],[-56.17,-34.92],[-56.17,-34.91],[-56.19,-34.91],[-56.19,-34.92]]]}'::jsonb);

insert into public.campania_colportor (campania_id, usuario_id, zona_id, created_at) values
  (pg_temp.u('e1'), pg_temp.u('b1'), pg_temp.u('d1'), '2026-08-01 10:00-03'),
  (pg_temp.u('e1'), pg_temp.u('b2'), null,            '2026-08-01 10:00-03'),
  (pg_temp.u('e1'), pg_temp.u('b3'), pg_temp.u('d1'), '2026-08-01 10:00-03'),
  (pg_temp.u('e2'), pg_temp.u('b4'), null,            '2026-08-01 10:00-03'),
  (pg_temp.u('e3'), pg_temp.u('b5'), null,            '2025-01-01 10:00-03'),
  (pg_temp.u('e4'), pg_temp.u('b6'), null,            (public.hoy_montevideo() - 60)::timestamptz),
  (pg_temp.u('e7'), pg_temp.u('b7'), null,            (public.hoy_montevideo() - 90)::timestamptz),
  (pg_temp.u('e8'), pg_temp.u('b8'), null,            (public.hoy_montevideo() - 90)::timestamptz),
  (pg_temp.u('e6'), pg_temp.u('b9'), null,            '2026-08-01 10:00-03'),
  (pg_temp.u('e9'), pg_temp.u('b6'), null,            (public.hoy_montevideo() - 5)::timestamptz);
-- b4 estuvo fuera de Otra entre el 01/09 y el 20/09 (un hueco de la inscripción).
update public.campania_colportor set tramos_afuera = array['[2026-09-01 00:00:00+00,2026-09-20 00:00:00+00)'::tstzrange]
 where campania_id = pg_temp.u('e2') and usuario_id = pg_temp.u('b4');
update public.campania_colportor set deleted_at = '2026-10-21 12:00:00+00'
 where campania_id = pg_temp.u('e1') and usuario_id = pg_temp.u('b3');

insert into public.producto (id, nombre, tipo, precio_base_compra) values
  (pg_temp.u('91'), 'Libro Uno',   'LIBRO',   1500),
  (pg_temp.u('92'), 'Libro Dos',   'LIBRO',   2500),
  (pg_temp.u('93'), 'Revista Uno', 'REVISTA', 200);

-- Lo que tiene b1 de cada producto (el de la Revista está dado de baja: cuenta como cero).
insert into public.stock (usuario_id, producto_id, cantidad_disponible, deleted_at) values
  (pg_temp.u('b1'), pg_temp.u('91'), 5,  null),
  (pg_temp.u('b1'), pg_temp.u('92'), -2, null),
  (pg_temp.u('b1'), pg_temp.u('93'), 50, now());

-- La cuenta de b1 (b2 no tiene) y sus depósitos: el más reciente vivo es el del 17/10.
insert into public.estado_cuenta (usuario_id, deuda_total, dinero_por_cobrar, deuda_alquiler)
values (pg_temp.u('b1'), 20000, 7000, 1234);
insert into public.estado_cuenta (usuario_id, deuda_total, dinero_por_cobrar, deuda_alquiler, deleted_at)
values (pg_temp.u('b9'), 777, 888, 99, now());
insert into public.deposito (colportor_id, monto, fecha, destino, concepto, deleted_at) values
  (pg_temp.u('b1'), 9000,  '2026-10-10 12:00:00+00', 'BANCO', 'CASA_EDITORA', null),
  (pg_temp.u('b1'), 12000, '2026-10-17 12:00:00+00', 'BANCO', 'CASA_EDITORA', null),
  (pg_temp.u('b1'), 1,     '2026-10-20 12:00:00+00', 'BANCO', 'CASA_EDITORA', now()),
  (pg_temp.u('b1'), 777,   '2026-10-24 12:00:00+00', 'BANCO', 'ALQUILER',     null);

-- Lo por entregar de b1: 3 + 1 vivas y pendientes; una entregada, una entrega dada de baja y una venta dada
-- de baja no cuentan. Lo de b2 no se mezcla.
insert into public.ubicacion (id, tipo, calle, numero, lat, lon, ciudad_id)
values (pg_temp.u('f1'), 'CASA', 'Calle de prueba', '1', -34.915, -56.18, pg_temp.u('c1'));
insert into public.espacio (id, ubicacion_id) values (pg_temp.u('f2'), pg_temp.u('f1'));
insert into public.espacio_persona (id, espacio_id, persona_id)
values (pg_temp.u('f3'), pg_temp.u('f2'), pg_temp.u('f4'));
insert into public.venta (id, espacio_persona_id, numero_talonario, monto_total, fecha, colportor_id, deleted_at) values
  (pg_temp.u('10'), pg_temp.u('f3'), 'T-1', 5000, '2026-10-01 12:00:00+00', pg_temp.u('b1'), null),
  (pg_temp.u('11'), pg_temp.u('f3'), 'T-2', 5000, '2026-10-02 12:00:00+00', pg_temp.u('b1'), now()),
  (pg_temp.u('12'), pg_temp.u('f3'), 'T-3', 5000, '2026-10-03 12:00:00+00', pg_temp.u('b2'), null);
insert into public.entrega (venta_id, producto_id, cantidad, pendiente, deleted_at) values
  (pg_temp.u('10'), pg_temp.u('91'), 3, true,  null),
  (pg_temp.u('10'), pg_temp.u('92'), 1, true,  null),
  (pg_temp.u('10'), pg_temp.u('91'), 5, false, null),
  (pg_temp.u('10'), pg_temp.u('93'), 7, true,  now()),
  (pg_temp.u('11'), pg_temp.u('91'), 2, true,  null),
  (pg_temp.u('12'), pg_temp.u('91'), 9, true,  null);

-- Pedidos (id, colportor, estado, total, origen, excede_limite, minuto, dado de baja, monto autorizado,
-- decidió, cuándo, motivo). Más reciente = minuto más alto.
insert into public.pedido_casa_editora (id, colportor_id, estado, monto_total, origen, excede_limite, fecha_pedido,
                                        deleted_at, monto_autorizado, decidido_por, decidido_en, motivo_rechazo)
select pg_temp.u(x.id), pg_temp.u(x.col), x.est, x.tot, x.ori, x.exc,
       '2026-10-20 10:00:00+00'::timestamptz + x.min * interval '1 minute',
       x.baja, x.mauth, case when x.dec is null then null else pg_temp.u(x.dec) end, x.decen, x.mot
  from (values
    ('c1', 'b1', 'PENDIENTE_AUTORIZACION', 13000, 'COLPORTOR',   false, 1,  null::timestamptz, null::bigint, null::text, null::timestamptz, null::text),
    ('c2', 'b1', 'AUTORIZADO',              3000, 'COLPORTOR',   false, 2,  null,              1500,         'a1',       '2026-10-25 12:00:00+00', null),
    ('c3', 'b1', 'RECHAZADO',               2500, 'COLPORTOR',   false, 3,  null,              null,         'ad',       '2026-10-25 13:00:00+00', 'Excede capacidad de pago actual'),
    ('c4', 'b2', 'PENDIENTE_AUTORIZACION',  1500, 'COLPORTOR',   true,  4,  null,              null,         null,       null, null),
    ('c5', 'b1', 'BORRADOR',                1500, 'COORDINADOR', false, 5,  null,              null,         null,       null, null),
    ('c6', 'b1', 'CANCELADO',               1500, 'COLPORTOR',   false, 6,  null,              null,         null,       null, null),
    ('c7', 'b4', 'PENDIENTE_AUTORIZACION',  2500, 'COLPORTOR',   false, 7,  null,              null,         null,       null, null),
    ('c8', 'b3', 'DESPACHADO',              1500, 'COLPORTOR',   false, 8,  null,              1500,         'a1',       '2026-10-24 12:00:00+00', null),
    ('c9', 'b5', 'PENDIENTE_AUTORIZACION',  1500, 'COLPORTOR',   false, 9,  null,              null,         null,       null, null),
    ('ca', 'b6', 'PENDIENTE_AUTORIZACION',  1500, 'COLPORTOR',   false, 10, null,              null,         null,       null, null),
    ('cb', 'b1', 'PENDIENTE_AUTORIZACION',  1500, 'COLPORTOR',   false, 11, now(),             null,         null,       null, null),
    ('cc', 'b1', 'RECIBIDO',                1500, 'COLPORTOR',   false, 12, null,              1500,         'a1',       '2026-10-23 12:00:00+00', null),
    ('cd', 'b1', 'PENDIENTE_AUTORIZACION', 11000, 'COLPORTOR',   false, 13, null,              null,         null,       null, null),
    ('ce', 'b1', 'PENDIENTE_AUTORIZACION',  4000, 'COLPORTOR',   false, 14, null,              null,         null,       null, null),
    ('cf', 'b1', 'PENDIENTE_AUTORIZACION',  1500, 'COLPORTOR',   false, 15, null,              null,         null,       null, null),
    ('d0', 'b1', 'PENDIENTE_AUTORIZACION',  1500, 'COLPORTOR',   false, 16, null,              null,         null,       null, null),
    ('d2', 'b1', 'PENDIENTE_AUTORIZACION',  7000, 'COLPORTOR',   false, 17, null,              null,         null,       null, null),
    ('d3', 'b1', 'PENDIENTE_AUTORIZACION',  1500, 'COLPORTOR',   false, 18, null,              null,         null,       null, null),
    ('d4', 'b1', 'PENDIENTE_AUTORIZACION',  2500, 'COLPORTOR',   false, 19, null,              null,         null,       null, null),
    ('d5', 'b1', 'PENDIENTE_AUTORIZACION',  1500, 'COLPORTOR',   false, 20, null,              null,         null,       null, null),
    ('d6', 'b1', 'PENDIENTE_AUTORIZACION',  4000, 'COLPORTOR',   false, 21, null,              null,         null,       null, null),
    ('d7', 'b7', 'PENDIENTE_AUTORIZACION',  1500, 'COLPORTOR',   false, 22, null,              null,         null,       null, null),
    ('d8', 'b8', 'PENDIENTE_AUTORIZACION',  1500, 'COLPORTOR',   false, 23, null,              null,         null,       null, null),
    ('d9', 'b3', 'PENDIENTE_AUTORIZACION',  1500, 'COLPORTOR',   false, 24, null,              null,         null,       null, null),
    ('db', 'b9', 'PENDIENTE_AUTORIZACION',  1500, 'COLPORTOR',   false, 25, null,              null,         null,       null, null)
  ) x(id, col, est, tot, ori, exc, min, baja, mauth, dec, decen, mot);

-- Los pedidos de las campañas con fechas propias se hicieron DENTRO de la inscripción: c9 en la Cerrada, ca en la
-- Reciente, d7 y d8 en las de los bordes (decisión del 26/10: un pedido es de la campaña cuya ventana de
-- inscripción lo contiene). b3 se dio de baja el 21/10 a las 12:00: sus pedidos c8 y d9 son anteriores.
update public.pedido_casa_editora set fecha_pedido = case id
    when pg_temp.u('c9') then '2025-01-15 10:00:00+00'::timestamptz
    else (public.hoy_montevideo() - 30)::timestamptz + interval '12 hours' end
 where id in (pg_temp.u('c9'), pg_temp.u('ca'), pg_temp.u('d7'), pg_temp.u('d8'));

-- De qué campaña es un pedido (decisión del 26/10): b6 pasó de Reciente (a1, terminó hace 10 días) a Nueva
-- (a2, abierta hace 5 días) y hoy pide dc. De b4, en Otra (alta 01/08 10:00, empieza el 03/08): dd entre el
-- alta y el inicio (es de Otra), de antes del alta (de ninguna), df dentro del hueco (de ninguna).
insert into public.pedido_casa_editora (id, colportor_id, estado, monto_total, origen, fecha_pedido) values
  (pg_temp.u('dc'), pg_temp.u('b6'), 'PENDIENTE_AUTORIZACION', 1500, 'COLPORTOR', now()),
  (pg_temp.u('dd'), pg_temp.u('b4'), 'PENDIENTE_AUTORIZACION', 1500, 'COLPORTOR', '2026-08-02 12:00:00-03'),
  (pg_temp.u('de'), pg_temp.u('b4'), 'PENDIENTE_AUTORIZACION', 1500, 'COLPORTOR', '2026-07-30 12:00:00-03'),
  (pg_temp.u('df'), pg_temp.u('b4'), 'PENDIENTE_AUTORIZACION', 1500, 'COLPORTOR', '2026-09-10 12:00:00-03');

-- Líneas (pedido, producto, cantidad, costo, cantidad autorizada, dada de baja).
insert into public.pedido_item (pedido_id, producto_id, cantidad, precio_unitario, cantidad_autorizada, deleted_at)
select pg_temp.u(x.p), pg_temp.u(x.pr), x.c, x.pu, x.ca, x.baja
  from (values
    ('c1', '91', 4, 1500, null::integer, null::timestamptz),
    ('c1', '92', 2, 2500, null,          null),
    ('c1', '93', 10, 200, null,          null),
    ('c2', '91', 2, 1500, 1,             null),
    ('c3', '92', 1, 2500, null,          null),
    ('c4', '91', 1, 1500, null,          null),
    ('c5', '91', 1, 1500, null,          null),
    ('c6', '91', 1, 1500, null,          null),
    ('c7', '92', 1, 2500, null,          null),
    ('c8', '91', 1, 1500, null,          null),
    ('c9', '91', 1, 1500, null,          null),
    ('ca', '91', 1, 1500, null,          null),
    ('cb', '91', 1, 1500, null,          null),
    ('cc', '91', 1, 1500, null,          null),
    ('cd', '91', 4, 1500, null,          null),
    ('cd', '92', 2, 2500, null,          null),
    ('cd', '93', 5, 200,  null,          now()),
    ('ce', '91', 1, 1500, null,          null),
    ('ce', '92', 1, 2500, null,          null),
    ('cf', '91', 1, 1500, null,          null),
    ('d0', '91', 1, 1500, null,          null),
    ('d2', '91', 3, 1500, null,          null),
    ('d2', '92', 1, 2500, null,          null),
    ('d3', '91', 1, 1500, null,          null),
    ('d4', '92', 1, 2500, null,          null),
    ('d5', '91', 1, 1500, null,          null),
    ('d6', '91', 1, 1500, null,          null),
    ('d6', '92', 1, 2500, null,          null),
    ('d7', '91', 1, 1500, null,          null),
    ('d8', '91', 1, 1500, null,          null),
    ('d9', '91', 1, 1500, null,          null),
    ('db', '91', 1, 1500, null,          null),
    ('dc', '91', 1, 1500, null,          null),
    ('dd', '91', 1, 1500, null,          null),
    ('de', '91', 1, 1500, null,          null),
    ('df', '91', 1, 1500, null,          null)
  ) x(p, pr, c, pu, ca, baja);

-- ============================================================================
-- 1. La forma y los privilegios
-- ============================================================================
select has_function('public', f, 'existe ' || f)
  from unnest(array['pedidos_de_campania','pedido_lineas','pedido_contexto','autorizar_pedido',
                    'rechazar_pedido','deshacer_decision_de_pedido','pedido_para','puede_decidir_pedido_de',
                    'mover_deuda_casa_editora','plazo_para_deshacer_pedido']) f;
select is((select proargnames from pg_proc where oid = 'public.autorizar_pedido(uuid, jsonb)'::regprocedure),
          array['p_pedido_id','p_cantidades','pedido_id','estado','monto_total','monto_autorizado','reducido',
                'decidido_en','deshacer_hasta','ya_estaba'], 'autorizar_pedido: parámetros y columnas');
select is((select proargnames from pg_proc where oid = 'public.rechazar_pedido(uuid, text)'::regprocedure),
          array['p_pedido_id','p_motivo','pedido_id','estado','decidido_en','deshacer_hasta','ya_estaba'],
          'rechazar_pedido: parámetros y columnas');
select is((select proargnames from pg_proc where oid = 'public.deshacer_decision_de_pedido(uuid)'::regprocedure),
          array['p_pedido_id','pedido_id','estado','ya_estaba'], 'deshacer_decision_de_pedido: parámetros y columnas');
select is((select proargnames from pg_proc where oid = 'public.pedidos_de_campania(uuid)'::regprocedure),
          array['p_campania_id','pedido_id','colportor_id','nombre','apellido','ciudad_id','ciudad_nombre',
                'departamento','de_baja','estado','origen','fecha_pedido','productos','unidades',
                'unidades_autorizadas','monto_total','monto_autorizado','excede_limite','decidido_en',
                'motivo_rechazo','deshacer_hasta'], 'pedidos_de_campania: parámetros y columnas');
select is((select proargnames from pg_proc where oid = 'public.pedido_lineas(uuid)'::regprocedure),
          array['p_pedido_id','producto_id','producto_nombre','producto_tipo','cantidad','cantidad_autorizada',
                'precio_unitario','subtotal','subtotal_autorizado','stock'], 'pedido_lineas: parámetros y columnas');
select is((select proargnames from pg_proc where oid = 'public.pedido_contexto(uuid)'::regprocedure),
          array['p_pedido_id','colportor_id','nombre','apellido','estado','monto_total','monto_autorizado',
                'deuda_actual','deuda_con_pedido','por_cobrar','libros_por_entregar',
                'ultimo_deposito_fecha','ultimo_deposito_monto'], 'pedido_contexto: parámetros y columnas');

select is(has_function_privilege(r, f, 'execute')::text, case when r = 'authenticated' then 'true' else 'false' end,
          format('%s %s EXECUTE en %s', r, case when r = 'authenticated' then 'tiene' else 'no tiene' end, f))
  from unnest(array['public.pedidos_de_campania(uuid)', 'public.pedido_lineas(uuid)', 'public.pedido_contexto(uuid)',
                    'public.autorizar_pedido(uuid, jsonb)', 'public.rechazar_pedido(uuid, text)',
                    'public.deshacer_decision_de_pedido(uuid)']) f,
       unnest(array['anon', 'authenticated', 'service_role']) r;
select is(has_function_privilege(r, f, 'execute')::text, 'false',
          format('%s no tiene EXECUTE en la pieza interna %s', r, f))
  from unnest(array['public.pedido_para(uuid, boolean)', 'public.puede_decidir_pedido_de(uuid, timestamptz)',
                    'public.puede_ver_pedido_de(uuid, timestamptz)',
                    'public.pedido_en_la_ventana(timestamptz, timestamptz, tstzrange[], date, timestamptz)',
                    'public.mover_deuda_casa_editora(uuid, bigint)', 'public.plazo_para_deshacer_pedido()',
                    'public.gracia_para_deshacer_pedido()']) f,
       unnest(array['anon', 'authenticated', 'service_role']) r;
-- PUBLIC (grantee 0) no tiene EXECUTE en ninguna de las funciones nuevas.
select is((select count(*)::int
             from pg_proc p, aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a
            where a.grantee = 0 and a.privilege_type = 'EXECUTE'
              and p.oid in ('public.pedidos_de_campania(uuid)'::regprocedure, 'public.pedido_lineas(uuid)'::regprocedure,
                            'public.pedido_contexto(uuid)'::regprocedure, 'public.autorizar_pedido(uuid, jsonb)'::regprocedure,
                            'public.rechazar_pedido(uuid, text)'::regprocedure,
                            'public.deshacer_decision_de_pedido(uuid)'::regprocedure,
                            'public.pedido_para(uuid, boolean)'::regprocedure,
                            'public.puede_decidir_pedido_de(uuid, timestamptz)'::regprocedure,
                            'public.puede_ver_pedido_de(uuid, timestamptz)'::regprocedure,
                            'public.pedido_en_la_ventana(timestamptz, timestamptz, tstzrange[], date, timestamptz)'::regprocedure,
                            'public.mover_deuda_casa_editora(uuid, bigint)'::regprocedure,
                            'public.plazo_para_deshacer_pedido()'::regprocedure,
                            'public.gracia_para_deshacer_pedido()'::regprocedure)), 0,
          'PUBLIC no tiene EXECUTE en ninguna de las funciones nuevas');
select is((select count(*)::int from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'public'
              and p.proname in ('pedidos_de_campania','pedido_lineas','pedido_contexto','autorizar_pedido',
                                'rechazar_pedido','deshacer_decision_de_pedido')
              and (not p.prosecdef or p.provolatile <> 'v' or p.proconfig is distinct from array['search_path=""'])),
          0, 'las seis son SECURITY DEFINER, VOLATILE y con search_path vacío');

-- ============================================================================
-- 2. El permiso de lectura, antes de mirar nada más
-- ============================================================================
select is(pg_temp.lista(null, 'e1') ->> 'error', '42501', 'sin sesión no ve la bandeja');
select is(pg_temp.lista(pg_temp.u('a0'), 'e1') ->> 'error', '42501', 'un colportor no ve la bandeja');
select is(pg_temp.lista(pg_temp.u('b1'), 'e1') ->> 'error', '42501', 'ni el colportor dueño de los pedidos');
select is(pg_temp.lista(pg_temp.u('a3'), 'e1') ->> 'error', '42501', 'sin rol, tampoco');
select is(pg_temp.lista(pg_temp.u('a4'), 'e1') ->> 'error', '42501', 'con el rol de coordinador vencido, tampoco');
select is(pg_temp.lista(pg_temp.u('a2'), 'e1') ->> 'error', '42501', 'el coordinador de otra campaña no ve esta');
select is(pg_temp.lista(pg_temp.u('a1'), 'e2') ->> 'error', '42501', 'ni esta el de la primera');
select is(pg_temp.lista(pg_temp.u('a1'), 'e6') ->> 'error', 'CZ001', 'una campaña dada de baja no existe');
select is(pg_temp.como(pg_temp.u('a1'), format('select * from public.pedidos_de_campania(%L)', '01920000-0000-7000-8000-0000000112ff')) ->> 'error',
          'CZ001', 'ni una campaña inexistente');
select is(pg_temp.lista(pg_temp.u('ad'), 'e5') -> 0, null, 'el administrador ve una campaña vacía: lista vacía, no error');
select alike(pg_temp.lista(pg_temp.u('a2'), 'e1') ->> 'mensaje', '%coordinador de la campaña%',
            'el aviso dice quién puede');

select is(pg_temp.err(null, format('select * from public.pedido_lineas(%L)', pg_temp.u('c1'))), '42501', 'líneas: sin sesión');
select is(pg_temp.err(pg_temp.u('a0'), format('select * from public.pedido_lineas(%L)', pg_temp.u('c1'))), '42501', 'líneas: un colportor');
select is(pg_temp.err(pg_temp.u('b1'), format('select * from public.pedido_lineas(%L)', pg_temp.u('c1'))), '42501', 'líneas: ni el dueño del pedido');
select is(pg_temp.err(pg_temp.u('a3'), format('select * from public.pedido_lineas(%L)', pg_temp.u('c1'))), '42501', 'líneas: sin rol');
select is(pg_temp.err(pg_temp.u('a4'), format('select * from public.pedido_lineas(%L)', pg_temp.u('c1'))), '42501', 'líneas: rol vencido');
select is(pg_temp.err(pg_temp.u('a2'), format('select * from public.pedido_lineas(%L)', pg_temp.u('c1'))), '42501', 'líneas: coordinador ajeno');
select is(pg_temp.err(pg_temp.u('a1'), format('select * from public.pedido_lineas(%L)', pg_temp.u('c1'))), 'ok', 'líneas: su coordinador');
select is(pg_temp.err(pg_temp.u('ad'), format('select * from public.pedido_lineas(%L)', pg_temp.u('c1'))), 'ok', 'líneas: el administrador');
select is(pg_temp.err(pg_temp.u('a2'), format('select * from public.pedido_contexto(%L)', pg_temp.u('c1'))), '42501', 'contexto: coordinador ajeno');
select is(pg_temp.err(pg_temp.u('b1'), format('select * from public.pedido_contexto(%L)', pg_temp.u('c1'))), '42501', 'contexto: el colportor');
select is(pg_temp.err(null, format('select * from public.pedido_contexto(%L)', pg_temp.u('c1'))), '42501', 'contexto: sin sesión');
select is(pg_temp.err(pg_temp.u('a1'), format('select * from public.pedido_lineas(%L)', '01920000-0000-7000-8000-0000000112ff')),
          'PE001', 'un pedido que no existe es PE001');
select is(pg_temp.err(pg_temp.u('a1'), format('select * from public.pedido_contexto(%L)', pg_temp.u('cb'))),
          'PE001', 'y uno dado de baja también');
select is(pg_temp.err(pg_temp.u('a3'), format('select * from public.pedido_lineas(%L)', '01920000-0000-7000-8000-0000000112ff')),
          '42501', 'sin rol, el permiso va antes que la existencia: no se entera de cuáles hay');
-- Quien coordinó al colportor en una campaña cerrada sigue viendo sus pedidos (como la RLS de siempre).
select is(pg_temp.err(pg_temp.u('a1'), format('select * from public.pedido_lineas(%L)', pg_temp.u('c9'))), 'ok',
          'el coordinador de una campaña cerrada todavía lee el pedido');

-- ============================================================================
-- 3. La bandeja
-- ============================================================================
-- Salen los cinco estados de las pestañas, vivos, el más reciente primero; no el BORRADOR (c5), el CANCELADO
-- (c6) ni el dado de baja (cb); ni los de otra campaña (c7 de Otra, c9, ca, d7, d8).
select is(pg_temp.ids(pg_temp.u('a1'), 'e1'), 'd9,d6,d5,d4,d3,d2,d0,cf,ce,cd,cc,c8,c4,c3,c2,c1',
          'la bandeja de Abierta: sus pedidos en los cinco estados, del más reciente al más viejo');
select is(pg_temp.ids(pg_temp.u('ad'), 'e1'), pg_temp.ids(pg_temp.u('a1'), 'e1'), 'el administrador ve lo mismo');
select is(pg_temp.ids(pg_temp.u('a2'), 'e2'), 'c7,dd',
          'cada campaña ve lo suyo: Otra, los de b4 hechos dentro de su inscripción (dd entre el alta y el inicio; no de, df ni los de otra campaña)');
select is(pg_temp.ids(pg_temp.u('ad'), 'e2'), 'c7,dd', 'el administrador, igual: la ventana vale para todos');
select is(pg_temp.ids(pg_temp.u('a2'), 'e9'), 'dc', 'el pedido de hoy de b6 sale en Nueva (a2)...');
select is(pg_temp.ids(pg_temp.u('a1'), 'e3'), 'c9', 'una campaña terminada se lee');
select is(pg_temp.ids(pg_temp.u('a1'), 'e4'), 'ca', '...y NO en Reciente (a1, terminó hace 10 días): solo el que hizo entonces');
select is(pg_temp.ids(pg_temp.u('a1'), 'e5'), '', 'la campaña sin colportores: bandeja vacía');

select is(pg_temp.como(pg_temp.u('a1'), format('select coalesce(sum(pedidos), 0)::int as n from public.pedidos_por_autorizar_por_ciudad(%L)', pg_temp.u('e4'))) -> 0 ->> 'n',
          '1', 'el aviso de Stock de Reciente cuenta solo ca, no el de hoy de b6 en Nueva (0111 con la ventana)');
select is(pg_temp.como(pg_temp.u('a2'), format('select coalesce(sum(pedidos), 0)::int as n from public.pedidos_por_autorizar_por_ciudad(%L)', pg_temp.u('e9'))) -> 0 ->> 'n',
          '1', 'y el de Nueva cuenta dc');
select is(pg_temp.como(pg_temp.u('a2'), format('select coalesce(sum(pedidos), 0)::int as n from public.pedidos_por_autorizar_por_ciudad(%L)', pg_temp.u('e2'))) -> 0 ->> 'n',
          '2', 'el de Otra, c7 y dd (no de ni df)');

select is(pg_temp.lista(pg_temp.u('a1'), 'e1') -> 15 ->> 'pedido_id', pg_temp.u('c1')::text, 'la última fila es c1 (la más vieja)');
create or replace function pg_temp.fila(p_ped text) returns jsonb language sql as $$
  select e from jsonb_array_elements(pg_temp.lista(pg_temp.u('a1'), 'e1')) e where e ->> 'pedido_id' = pg_temp.u(p_ped)::text
$$;
select is(pg_temp.fila('c1') - 'pedido_id' - 'colportor_id' - 'fecha_pedido' - 'ciudad_id',
          jsonb_build_object('nombre','Ana','apellido','Alfa','ciudad_nombre','Ciudad uno q104',
                             'departamento','Departamento de prueba uno','de_baja',false,
                             'estado','PENDIENTE_AUTORIZACION','origen','COLPORTOR','productos',3,'unidades',16,
                             'unidades_autorizadas',null,'monto_total',13000,'monto_autorizado',null,
                             'excede_limite',false,'decidido_en',null,'motivo_rechazo',null,'deshacer_hasta',null),
          'un pedido por autorizar: el colportor, su ciudad, 3 productos y 16 unidades, nada decidido');
select is(pg_temp.fila('c1') ->> 'colportor_id', pg_temp.u('b1')::text, 'el colportor es b1');
select is(pg_temp.fila('c1') ->> 'ciudad_id', pg_temp.u('c1')::text, 'y la ciudad, la de su zona actual');
select is(pg_temp.fila('c4') ->> 'ciudad_nombre', null, 'sin zona: sin ciudad (null, «Sin ciudad»)');
select is(pg_temp.fila('c4') ->> 'excede_limite', 'true', 'excede_limite sale como lo guardó quien envió el pedido');
select is(pg_temp.fila('c4') ->> 'departamento', null, 'y sin departamento');
select is(pg_temp.fila('c8') ->> 'de_baja', 'true', 'un colportor de baja se marca de_baja');
select is(pg_temp.fila('c8') ->> 'ciudad_nombre', null, 'y sale sin ciudad (la inscripción de baja no cuenta su zona)');
select is(pg_temp.fila('c8') ->> 'estado', 'DESPACHADO', 'el despachado sale');
select is(pg_temp.fila('cc') ->> 'estado', 'RECIBIDO', 'el recibido sale');
select is(pg_temp.fila('c2') ->> 'unidades_autorizadas', '1', 'el autorizado trae lo autorizado: 1 de 2 unidades');
select is(pg_temp.fila('c2') ->> 'unidades', '2', 'y lo pedido, intacto');
select is(pg_temp.fila('c2') ->> 'monto_autorizado', '1500', 'con su monto autorizado');
select is(pg_temp.fila('c2') ->> 'monto_total', '3000', 'y el monto pedido');
select is((pg_temp.fila('c2') ->> 'deshacer_hasta')::timestamptz, '2026-10-25 12:00:08+00'::timestamptz,
          'se puede deshacer hasta decidido_en + 8 segundos');
select is(pg_temp.fila('c3') ->> 'motivo_rechazo', 'Excede capacidad de pago actual', 'el rechazado trae su motivo');
select is((pg_temp.fila('c3') ->> 'deshacer_hasta')::timestamptz, '2026-10-25 13:00:08+00'::timestamptz,
          'y también su plazo de deshacer');
select is(pg_temp.fila('c8') ->> 'deshacer_hasta', null, 'el despachado ya no se deshace: sin deshacer_hasta');
select is(pg_temp.fila('cc') ->> 'deshacer_hasta', null, 'ni el recibido');
select is(pg_temp.fila('cd') ->> 'productos', '2', 'las líneas dadas de baja no cuentan: 2 productos');
select is(pg_temp.fila('cd') ->> 'unidades', '6', 'ni sus unidades: 6');

-- ============================================================================
-- 4. Las líneas
-- ============================================================================
select is((select jsonb_agg(l - 'producto_id' order by o) from jsonb_array_elements(pg_temp.lineas(pg_temp.u('a1'), 'c1')) with ordinality t(l, o)),
          '[{"stock":-2,"cantidad":2,"subtotal":5000,"producto_tipo":"LIBRO","precio_unitario":2500,"producto_nombre":"Libro Dos","subtotal_autorizado":5000,"cantidad_autorizada":null},
            {"stock":5,"cantidad":4,"subtotal":6000,"producto_tipo":"LIBRO","precio_unitario":1500,"producto_nombre":"Libro Uno","subtotal_autorizado":6000,"cantidad_autorizada":null},
            {"stock":0,"cantidad":10,"subtotal":2000,"producto_tipo":"REVISTA","precio_unitario":200,"producto_nombre":"Revista Uno","subtotal_autorizado":2000,"cantidad_autorizada":null}]'::jsonb,
          'las líneas por nombre, con el costo, los subtotales y el stock del colportor (negativo tal cual; el renglón dado de baja, cero)');
select is(jsonb_array_length(pg_temp.lineas(pg_temp.u('a1'), 'cd')), 2, 'las líneas dadas de baja no salen');
select is((pg_temp.lineas(pg_temp.u('a1'), 'c2') -> 0 ->> 'cantidad_autorizada'), '1', 'lo autorizado de una línea sale tal cual');
select is((pg_temp.lineas(pg_temp.u('a1'), 'c2') -> 0 ->> 'subtotal_autorizado'), '1500', 'con su subtotal autorizado');
select is((pg_temp.lineas(pg_temp.u('a1'), 'c2') -> 0 ->> 'subtotal'), '3000', 'y el pedido, intacto');
select is((pg_temp.lineas(pg_temp.u('a1'), 'c4') -> 0 ->> 'stock'), '0', 'un colportor sin renglón de stock tiene cero');

-- ============================================================================
-- 5. El contexto de la cuenta
-- ============================================================================
select is((pg_temp.contexto(pg_temp.u('a1'), 'c1') -> 0) - 'colportor_id',
          jsonb_build_object('nombre','Ana','apellido','Alfa','estado','PENDIENTE_AUTORIZACION','monto_total',13000,
                             'monto_autorizado',null,'deuda_actual',20000,'deuda_con_pedido',33000,'por_cobrar',7000,
                             'libros_por_entregar',4,'ultimo_deposito_fecha','2026-10-17T12:00:00+00:00',
                             'ultimo_deposito_monto',12000),
          'el contexto de un pedido por autorizar: la deuda actual, con el pedido, por cobrar, por entregar y el último depósito vivo');
select is(pg_temp.contexto(pg_temp.u('a1'), 'c1') -> 0 ->> 'colportor_id', pg_temp.u('b1')::text, 'del colportor del pedido');
select is(pg_temp.contexto(pg_temp.u('a1'), 'c2') -> 0 ->> 'deuda_con_pedido', '20000',
          'un pedido ya autorizado ya está en la deuda: no se suma otra vez');
select is(pg_temp.contexto(pg_temp.u('a1'), 'c3') -> 0 ->> 'deuda_con_pedido', '20000', 'un rechazado tampoco');
select is(pg_temp.contexto(pg_temp.u('a1'), 'c2') -> 0 ->> 'monto_autorizado', '1500', 'trae lo autorizado');
select is(pg_temp.contexto(pg_temp.u('a1'), 'c4') -> 0,
          jsonb_build_array(jsonb_build_object('colportor_id', pg_temp.u('b2'), 'nombre', 'Beto', 'apellido', 'Bravo',
                'estado', 'PENDIENTE_AUTORIZACION', 'monto_total', 1500, 'monto_autorizado', null, 'deuda_actual', 0,
                'deuda_con_pedido', 1500, 'por_cobrar', 0, 'libros_por_entregar', 9, 'ultimo_deposito_fecha', null,
                'ultimo_deposito_monto', null))->0,
          'sin cuenta ni depósitos: todo en cero y el depósito en null; lo por entregar es solo el suyo');

-- ============================================================================
-- 6. Autorizar
-- ============================================================================
-- Los permisos de decisión (más estrictos que los de lectura).
select is(pg_temp.aut(null, 'd0') ->> 'error', '42501', 'sin sesión no autoriza');
select is(pg_temp.aut(pg_temp.u('a0'), 'd0') ->> 'error', '42501', 'un colportor no autoriza');
select is(pg_temp.aut(pg_temp.u('b1'), 'd0') ->> 'error', '42501', 'ni el dueño del pedido');
select is(pg_temp.aut(pg_temp.u('a3'), 'd0') ->> 'error', '42501', 'sin rol, no');
select is(pg_temp.aut(pg_temp.u('a4'), 'd0') ->> 'error', '42501', 'con el rol vencido, no');
select is(pg_temp.aut(pg_temp.u('a2'), 'd0') ->> 'error', '42501', 'el coordinador de otra campaña, no');
select is(pg_temp.aut(pg_temp.u('a1'), 'c7') ->> 'error', '42501', 'a1 no autoriza el pedido de un colportor de Otra');
select is(pg_temp.aut(pg_temp.u('a1'), 'd9') ->> 'error', '42501', 'ni el de uno cuya inscripción está de baja');
select is(pg_temp.aut(pg_temp.u('a1'), 'c9') ->> 'error', '42501', 'ni el de una campaña cerrada hace más de 15 días');
select is(pg_temp.aut(pg_temp.u('a1'), 'd8') ->> 'error', '42501', 'ni el que terminó hace 16 días');
-- El pedido de hoy de b6 es de Nueva (de a2): a1, que lo coordinó en Reciente, no lo ve ni lo decide.
select is(pg_temp.aut(pg_temp.u('a1'), 'dc') ->> 'error', '42501', 'a1 no autoriza el pedido de hoy de b6 (es de la campaña de a2)');
select is(pg_temp.rech(pg_temp.u('a1'), 'dc', 'Motivo') ->> 'error', '42501', 'ni lo rechaza');
select is(pg_temp.lineas(pg_temp.u('a1'), 'dc') ->> 'error', '42501', 'ni lee sus líneas');
select is(pg_temp.contexto(pg_temp.u('a1'), 'dc') ->> 'error', '42501', 'ni su contexto (la deuda de b6)');
select is(pg_temp.des(pg_temp.u('a1'), 'dc') ->> 'error', '42501', 'ni lo deshace');
select is(pg_temp.deuda('b6'), -1::bigint, 'b6 sigue sin deuda');
select is(pg_temp.aut(pg_temp.u('a2'), 'de') ->> 'error', '42501', 'a2 no decide el que b4 hizo antes de inscribirse');
select is(pg_temp.aut(pg_temp.u('a2'), 'df') ->> 'error', '42501', 'ni el que hizo en el hueco de su inscripción');
select is(pg_temp.lineas(pg_temp.u('a2'), 'de') ->> 'error', '42501', 'ni lo lee');
select is(pg_temp.lineas(pg_temp.u('ad'), 'de') -> 0 ->> 'cantidad', '1', 'el administrador sí lo lee');
-- El borde: entre el alta y el inicio de la campaña, el pedido ya es de la campaña (pendiente P1 de la revisión).
select is(pg_temp.aut(pg_temp.u('a2'), 'dd') -> 0 ->> 'estado', 'AUTORIZADO', 'a2 sí decide el de b4 hecho entre su alta y el inicio');
select is(pg_temp.des(pg_temp.u('a2'), 'dd') -> 0 ->> 'estado', 'PENDIENTE_AUTORIZACION', 'y lo deshace');
select is(pg_temp.aut(pg_temp.u('a2'), 'dc') -> 0 ->> 'estado', 'AUTORIZADO', 'a2 sí decide el de hoy de b6');
select is(pg_temp.des(pg_temp.u('a2'), 'dc') -> 0 ->> 'estado', 'PENDIENTE_AUTORIZACION', 'y lo deshace');
select is(pg_temp.deuda('b6'), 0::bigint, 'la deuda de b6 vuelve a cero');
select is(pg_temp.aut(pg_temp.u('a1'), 'db') ->> 'error', '42501', 'ni el de una campaña dada de baja');
select is(pg_temp.rech(pg_temp.u('a1'), 'db', 'Motivo') ->> 'error', '42501', 'ni rechazarlo');
select is(pg_temp.contexto(pg_temp.u('ad'), 'db') -> 0 ->> 'deuda_actual', '0', 'la cuenta dada de baja no cuenta (deuda 0, no 777)');
select is(pg_temp.contexto(pg_temp.u('ad'), 'db') -> 0 ->> 'por_cobrar', '0', 'ni lo que tenía por cobrar');
select is(pg_temp.aut(pg_temp.u('a1'), '00')  ->> 'error', 'PE001', 'un pedido que no existe: PE001');
select is(pg_temp.aut(pg_temp.u('a1'), 'cb') ->> 'error', 'PE001', 'uno dado de baja: PE001');
select alike(pg_temp.aut(pg_temp.u('a2'), 'd0') ->> 'mensaje', '%campaña tuya%', 'el aviso dice qué hacer');
select is((select estado from public.pedido_casa_editora where id = pg_temp.u('d0')), 'PENDIENTE_AUTORIZACION',
          'ninguno de esos errores cambió el pedido');
select is(pg_temp.deuda('b1'), 20000::bigint, 'ni la deuda');

-- Los que sí pueden: terminó hace 15 días justos y hace 10 (dentro de los 15 de gracia), el de Otra por su
-- coordinador y el administrador sobre una campaña cerrada.
select is(pg_temp.aut(pg_temp.u('a1'), 'd7') ->> 'error', null, 'a1 autoriza el que terminó hace 15 días justos');
select is(pg_temp.aut(pg_temp.u('a1'), 'ca') ->> 'error', null, 'y el que terminó hace 10');
select is(pg_temp.aut(pg_temp.u('a2'), 'c7') ->> 'error', null, 'a2 autoriza el de su campaña');
select is(pg_temp.aut(pg_temp.u('ad'), 'c9') ->> 'error', null, 'el administrador autoriza hasta el de una campaña cerrada');
select is(pg_temp.deuda('b7'), 1500::bigint, 'y la deuda de quien no tenía cuenta se crea con el pedido');
select is(pg_temp.deuda('b5'), 1500::bigint, 'la de b5, igual');

-- Autorizar todo: c1 (13000) sobre la deuda de 20000.
create or replace function pg_temp.pedido(p_ped text) returns jsonb language sql as $$
  select to_jsonb(p) from public.pedido_casa_editora p where p.id = pg_temp.u(p_ped)
$$;
select is((pg_temp.aut(pg_temp.u('a1'), 'c1') -> 0) - 'decidido_en' - 'deshacer_hasta',
          jsonb_build_object('pedido_id', pg_temp.u('c1'), 'estado', 'AUTORIZADO', 'monto_total', 13000,
                             'monto_autorizado', 13000, 'reducido', false, 'ya_estaba', false),
          'autorizar todo devuelve el pedido AUTORIZADO por lo pedido');
select is(pg_temp.pedido('c1') ->> 'monto_autorizado', '13000', 'monto_autorizado = lo pedido');
select is(pg_temp.pedido('c1') ->> 'decidido_por', pg_temp.u('a1')::text, 'decidió a1');
select ok((pg_temp.pedido('c1') ->> 'decidido_en')::timestamptz > now() - interval '1 minute'
          and (pg_temp.pedido('c1') ->> 'decidido_en')::timestamptz <= clock_timestamp(), 'decidido_en es el reloj de ahora');
select is(pg_temp.pedido('c1') ->> 'monto_total', '13000', 'monto_total, intacto');
select is(pg_temp.pedido('c1') ->> 'motivo_rechazo', null, 'sin motivo');
select is(pg_temp.pedido('c1') ->> 'coordinador_id', null, 'coordinador_id (quien lo registró) no se toca');
select is((select count(*)::int from public.pedido_item where pedido_id = pg_temp.u('c1') and cantidad_autorizada is not null),
          0, 'autorizar todo no escribe cantidades en las líneas (null = lo pedido)');
select is(pg_temp.deuda('b1'), 33000::bigint, 'la deuda del colportor sube lo autorizado: 20000 + 13000');
select is((select dinero_por_cobrar from public.estado_cuenta where usuario_id = pg_temp.u('b1')), 7000::bigint,
          'lo demás de la cuenta no se mueve');
select is((select deuda_alquiler from public.estado_cuenta where usuario_id = pg_temp.u('b1')), 1234::bigint,
          'ni el alquiler');
select is((select cantidad_disponible from public.stock where usuario_id = pg_temp.u('b1') and producto_id = pg_temp.u('91')),
          5, 'el stock no cambia: entra al recibir');
select is(pg_temp.n_audit('pedido_autorizado', 'c1'), 1::bigint, 'dejó un registro de auditoría');
select is((select metadata from auditoria.audit_log where event_type = 'pedido_autorizado' and fila_id = pg_temp.u('c1')),
          '{"monto_total":13000,"monto_autorizado":13000,"reducido":false,"excede_limite":false}'::jsonb,
          'con ids, montos y estados');
select is((select actor_user_id from auditoria.audit_log where event_type = 'pedido_autorizado' and fila_id = pg_temp.u('c1')),
          pg_temp.u('a1'), 'el actor es quien autorizó');
select is((select target_user_id from auditoria.audit_log where event_type = 'pedido_autorizado' and fila_id = pg_temp.u('c1')),
          pg_temp.u('b1'), 'y el target, el colportor');
select is((select tabla from auditoria.audit_log where event_type = 'pedido_autorizado' and fila_id = pg_temp.u('c1')),
          'pedido_casa_editora', 'sobre la tabla del pedido');

-- Reintento de quien ya lo autorizó: no suma dos veces.
select is((pg_temp.aut(pg_temp.u('a1'), 'c1') -> 0 ->> 'ya_estaba'), 'true', 'el reintento de quien lo autorizó devuelve ya_estaba');
select is(pg_temp.deuda('b1'), 33000::bigint, 'y no suma la deuda dos veces');
select is(pg_temp.n_audit('pedido_autorizado', 'c1'), 1::bigint, 'ni deja un segundo registro');
select is((pg_temp.aut(pg_temp.u('a1'), 'c1') -> 0 ->> 'monto_autorizado'), '13000', 'el reintento trae lo autorizado');
-- Otra persona, o con otras cantidades, no es un reintento.
select is(pg_temp.aut(pg_temp.u('ad'), 'c1') ->> 'error', 'PE002', 'otro coordinador sobre uno ya autorizado: PE002');
select is(pg_temp.aut(pg_temp.u('a1'), 'c1', '[{"producto_id": "01920000-0000-7000-8000-000000011291", "cantidad": 1}]') ->> 'error',
          'PE002', 'con otras cantidades no es un reintento: PE002');
select alike(pg_temp.aut(pg_temp.u('ad'), 'c1') ->> 'mensaje', '%Recargá la bandeja%', 'y el aviso dice qué hacer');
select is(pg_temp.deuda('b1'), 33000::bigint, 'ninguno tocó la deuda');

-- Reducir: cd pide 4 de Libro Uno y 2 de Libro Dos (la Revista dada de baja no cuenta). Se autoriza 1 y 0.
select is((pg_temp.aut(pg_temp.u('a1'), 'cd',
            '[{"producto_id": "01920000-0000-7000-8000-000000011291", "cantidad": 1},
              {"producto_id": "01920000-0000-7000-8000-000000011292", "cantidad": 0}]') -> 0) - 'decidido_en' - 'deshacer_hasta',
          jsonb_build_object('pedido_id', pg_temp.u('cd'), 'estado', 'AUTORIZADO', 'monto_total', 11000,
                             'monto_autorizado', 1500, 'reducido', true, 'ya_estaba', false),
          'reducir devuelve lo autorizado y que se redujo');
select is(pg_temp.pedido('cd') ->> 'monto_total', '11000', 'lo que pidió el colportor no se pisa');
select is((select cantidad_autorizada from public.pedido_item where pedido_id = pg_temp.u('cd') and producto_id = pg_temp.u('91')),
          1, 'la línea guarda lo autorizado');
select is((select cantidad from public.pedido_item where pedido_id = pg_temp.u('cd') and producto_id = pg_temp.u('91')),
          4, 'y la cantidad pedida, intacta');
select is((select cantidad_autorizada from public.pedido_item where pedido_id = pg_temp.u('cd') and producto_id = pg_temp.u('92')),
          0, 'una línea se puede dejar en cero');
select is((select cantidad_autorizada from public.pedido_item where pedido_id = pg_temp.u('cd') and producto_id = pg_temp.u('93')),
          null, 'la línea dada de baja no se toca');
select is(pg_temp.deuda('b1'), 34500::bigint, 'la deuda sube solo lo autorizado: 33000 + 1500');
select is((pg_temp.aut(pg_temp.u('a1'), 'cd',
            '[{"producto_id": "01920000-0000-7000-8000-000000011291", "cantidad": 1},
              {"producto_id": "01920000-0000-7000-8000-000000011292", "cantidad": 0}]') -> 0 ->> 'ya_estaba'), 'true',
          'reintentar con las mismas cantidades reducidas: ya_estaba');
select is(pg_temp.deuda('b1'), 34500::bigint, 'sin sumar de nuevo');
select is(pg_temp.aut(pg_temp.u('a1'), 'cd',
            '[{"producto_id": "01920000-0000-7000-8000-000000011291", "cantidad": 2}]') ->> 'error', 'PE002',
          'reintentar con otras cantidades: PE002');
select is(pg_temp.n_audit('pedido_autorizado', 'cd'), 1::bigint, 'un solo registro');
select is((select metadata from auditoria.audit_log where event_type = 'pedido_autorizado' and fila_id = pg_temp.u('cd')),
          '{"monto_total":11000,"monto_autorizado":1500,"reducido":true,"excede_limite":false}'::jsonb,
          'la auditoría dice que se redujo');
select is(pg_temp.contexto(pg_temp.u('a1'), 'cd') -> 0 ->> 'monto_autorizado', '1500', 'el contexto trae lo autorizado');
select is(pg_temp.fila('cd') ->> 'unidades', '6', 'y las pedidas, intactas');

-- Una cantidad igual a la pedida se guarda como null (se autorizó lo pedido); lo que no se nombra, entero.
select is((pg_temp.aut(pg_temp.u('a1'), 'd2', '[{"producto_id": "01920000-0000-7000-8000-000000011291", "cantidad": 3}]') -> 0 ->> 'reducido'),
          'false', 'una cantidad igual a la pedida no reduce nada');
select is((select count(*)::int from public.pedido_item where pedido_id = pg_temp.u('d2') and cantidad_autorizada is not null),
          0, 'y queda null');
select is(pg_temp.pedido('d2') ->> 'monto_autorizado', '7000', 'se autoriza todo: 3 × 1500 + 2500');
-- La lista vacía es autorizar todo.
select is((pg_temp.aut(pg_temp.u('a1'), 'd3', '[]') -> 0 ->> 'monto_autorizado'), '1500', 'una lista vacía autoriza todo');
-- Dejar una línea en cero y otra entera: lo no nombrado se autoriza entero.
select is((pg_temp.aut(pg_temp.u('a1'), 'ce', '[{"producto_id": "01920000-0000-7000-8000-000000011291", "cantidad": 0}]') -> 0 ->> 'monto_autorizado'),
          '2500', 'lo que no se nombra se autoriza entero (solo queda Libro Dos)');
select is(pg_temp.deuda('b1'), 34500::bigint + 7000 + 1500 + 2500, 'la deuda de las tres autorizaciones suma lo autorizado');

-- Cada error de cantidades (d0 queda como estaba).
select is(pg_temp.aut(pg_temp.u('a1'), 'd0', '{}') ->> 'error', 'PE003', 'cantidades que no son una lista');
select is(pg_temp.aut(pg_temp.u('a1'), 'd0', '"x"') ->> 'error', 'PE003', 'ni un texto');
select is(pg_temp.aut(pg_temp.u('a1'), 'd0', '[1]') ->> 'error', 'PE003', 'elementos que no son objetos');
select is(pg_temp.aut(pg_temp.u('a1'), 'd0', '[{"cantidad": 1}]') ->> 'error', 'PE003', 'sin producto');
select is(pg_temp.aut(pg_temp.u('a1'), 'd0', '[{"producto_id": "01920000-0000-7000-8000-000000011291"}]') ->> 'error', 'PE003', 'sin cantidad');
select is(pg_temp.aut(pg_temp.u('a1'), 'd0', '[{"producto_id": "no-es-uuid", "cantidad": 1}]') ->> 'error', 'PE003', 'producto que no es un uuid');
select is(pg_temp.aut(pg_temp.u('a1'), 'd0', '[{"producto_id": "01920000-0000-7000-8000-000000011291", "cantidad": "uno"}]') ->> 'error', 'PE003', 'cantidad que no es un número');
select is(pg_temp.aut(pg_temp.u('a1'), 'd0', '[{"producto_id": "01920000-0000-7000-8000-000000011291", "cantidad": 1.5}]') ->> 'error', 'PE003', 'cantidad con decimales');
select is(pg_temp.aut(pg_temp.u('a1'), 'd0', '[{"producto_id": "01920000-0000-7000-8000-000000011291", "cantidad": 99999999999}]') ->> 'error', 'PE003', 'cantidad fuera del rango entero');
select is(pg_temp.aut(pg_temp.u('a1'), 'd0', '[{"producto_id": "01920000-0000-7000-8000-000000011291", "cantidad": -1}]') ->> 'error', 'PE003', 'cantidad negativa');
select is(pg_temp.aut(pg_temp.u('a1'), 'd0', '[{"producto_id": "01920000-0000-7000-8000-000000011291", "cantidad": 2}]') ->> 'error', 'PE003', 'más de lo pedido (1 → 2)');
select is(pg_temp.aut(pg_temp.u('a1'), 'd0', '[{"producto_id": "01920000-0000-7000-8000-000000011292", "cantidad": 1}]') ->> 'error', 'PE003', 'un producto que no está en el pedido');
select is(pg_temp.aut(pg_temp.u('a1'), 'd0', '[{"producto_id": "01920000-0000-7000-8000-000000011293", "cantidad": 1}]') ->> 'error', 'PE003', 'otro producto que no está en el pedido');
select is(pg_temp.aut(pg_temp.u('a1'), 'd0', '[{"producto_id": "01920000-0000-7000-8000-000000011291", "cantidad": 1},
                                               {"producto_id": "01920000-0000-7000-8000-000000011291", "cantidad": 1}]') ->> 'error', 'PE003', 'un producto repetido');
select is(pg_temp.aut(pg_temp.u('a1'), 'd0', '[{"producto_id": "01920000-0000-7000-8000-000000011291", "cantidad": 0}]') ->> 'error', 'PE003', 'todo en cero: eso es rechazar');
select is(pg_temp.aut(pg_temp.u('a1'), 'd6', '[{"producto_id": "01920000-0000-7000-8000-000000011291", "cantidad": 0},
                                               {"producto_id": "01920000-0000-7000-8000-000000011292", "cantidad": 0}]') ->> 'error', 'PE003', 'todas las líneas en cero');
select alike(pg_temp.aut(pg_temp.u('a1'), 'd0', '[{"producto_id": "01920000-0000-7000-8000-000000011291", "cantidad": 0}]') ->> 'mensaje', '%rechazalo%', 'y el aviso dice qué hacer');
select alike(pg_temp.aut(pg_temp.u('a1'), 'd0', '[{"producto_id": "01920000-0000-7000-8000-000000011291", "cantidad": 2}]') ->> 'mensaje', '%más de lo que pidió%', 'más de lo pedido: el aviso');
select is((select estado from public.pedido_casa_editora where id = pg_temp.u('d0')), 'PENDIENTE_AUTORIZACION', 'ningún error cambió el pedido');
select is((select count(*)::int from public.pedido_item where pedido_id = pg_temp.u('d0') and cantidad_autorizada is not null), 0, 'ni sus líneas');
select is((select count(*)::int from public.pedido_item where pedido_id = pg_temp.u('d6') and cantidad_autorizada is not null), 0, 'ni las de d6');
select is(pg_temp.deuda('b1'), 34500::bigint + 7000 + 1500 + 2500, 'ni la deuda');
select is(pg_temp.n_audit('pedido_autorizado', 'd0'), 0::bigint, 'ni dejó registros');
-- Un pedido sin líneas vivas no se autoriza.
insert into public.pedido_casa_editora (id, colportor_id, estado, monto_total, origen)
values (pg_temp.u('da'), pg_temp.u('b1'), 'PENDIENTE_AUTORIZACION', 0, 'COLPORTOR');
select is(pg_temp.aut(pg_temp.u('a1'), 'da') ->> 'error', 'PE003', 'un pedido sin líneas no se autoriza');

-- Estados que no se autorizan: PE002.
select is(pg_temp.aut(pg_temp.u('a1'), 'c3') ->> 'error', 'PE002', 'un rechazado');
select is(pg_temp.aut(pg_temp.u('a1'), 'c5') ->> 'error', 'PE002', 'un borrador (todavía no se envió)');
select is(pg_temp.aut(pg_temp.u('a1'), 'c6') ->> 'error', 'PE002', 'un cancelado');
select is(pg_temp.aut(pg_temp.u('a1'), 'cc') ->> 'error', 'PE002', 'un recibido');
select is(pg_temp.aut(pg_temp.u('a1'), 'c2') ->> 'error', 'PE002', 'uno autorizado antes por mí pero con otras cantidades (1 de 2): no es un reintento');
select is(pg_temp.aut(pg_temp.u('ad'), 'c2') ->> 'error', 'PE002', 'uno autorizado por otra persona');

-- Un pedido con excede_limite se autoriza igual: el límite solo avisa.
select is(pg_temp.aut(pg_temp.u('a1'), 'c4') -> 0 ->> 'estado', 'AUTORIZADO', 'el pedido que excede el límite se autoriza igual');
select is(pg_temp.deuda('b2'), 1500::bigint, 'y crea la deuda de quien no tenía cuenta');
select is((select metadata ->> 'excede_limite' from auditoria.audit_log where event_type = 'pedido_autorizado' and fila_id = pg_temp.u('c4')),
          'true', 'la auditoría guarda que excedía el límite');

-- ============================================================================
-- 7. Rechazar
-- ============================================================================
select is(pg_temp.rech(null, 'd4', 'No') ->> 'error', '42501', 'sin sesión no rechaza');
select is(pg_temp.rech(pg_temp.u('b1'), 'd4', 'No') ->> 'error', '42501', 'el colportor no rechaza su pedido');
select is(pg_temp.rech(pg_temp.u('a2'), 'd4', 'No') ->> 'error', '42501', 'el coordinador ajeno, no');
select is(pg_temp.rech(pg_temp.u('a4'), 'd4', 'No') ->> 'error', '42501', 'con el rol vencido, no');
select is(pg_temp.rech(pg_temp.u('a1'), 'c9', 'No') ->> 'error', '42501', 'ni el de una campaña cerrada hace más de 15 días');
select is(pg_temp.rech(pg_temp.u('a1'), 'd9', 'No') ->> 'error', '42501', 'ni el de una inscripción de baja');
select is(pg_temp.rech(pg_temp.u('a1'), '00', 'No') ->> 'error', 'PE001', 'un pedido que no existe: PE001');
select is(pg_temp.rech(pg_temp.u('a1'), 'd4', null) ->> 'error', 'PE004', 'sin motivo (null)');
select alike(pg_temp.rech(pg_temp.u('a1'), 'd4', '') ->> 'mensaje', '%Escribí el motivo%', 'el aviso dice qué hacer');
select is(pg_temp.rech(pg_temp.u('a1'), 'd4', '') ->> 'error', 'PE004', 'motivo vacío');
select is(pg_temp.rech(pg_temp.u('a1'), 'd4', E'  \t\n ') ->> 'error', 'PE004', 'motivo en blanco');
select is(pg_temp.rech(pg_temp.u('a1'), 'd4', repeat('x', 501)) ->> 'error', 'PE004', 'motivo de 501 caracteres');
select is(pg_temp.rech(pg_temp.u('a1'), 'd4', repeat('ñ', 501)) ->> 'error', 'PE004', 'el largo se mide en caracteres: 501 «ñ»');
select is(pg_temp.rech(pg_temp.u('a1'), 'd4', '  ' || repeat('x', 500) || '  ') ->> 'error', null, '500 caracteres rodeados de espacios entran: se mide recortado');
select is((select estado from public.pedido_casa_editora where id = pg_temp.u('d4')), 'RECHAZADO', 'rechazó d4');
select is(length((select motivo_rechazo from public.pedido_casa_editora where id = pg_temp.u('d4'))), 500, 'y guardó el motivo recortado');
select is(pg_temp.rech(pg_temp.u('a1'), 'cf', '  Excede la capacidad de pago  ') -> 0 ->> 'estado', 'RECHAZADO', 'rechazar devuelve RECHAZADO');
select is((select motivo_rechazo from public.pedido_casa_editora where id = pg_temp.u('cf')), 'Excede la capacidad de pago',
          'el motivo se guarda recortado');
select is(pg_temp.pedido('cf') ->> 'decidido_por', pg_temp.u('a1')::text, 'quedó quién lo rechazó');
select ok((pg_temp.pedido('cf') ->> 'decidido_en')::timestamptz > now() - interval '1 minute', 'y cuándo');
select is(pg_temp.pedido('cf') ->> 'monto_autorizado', null, 'un rechazado no tiene monto autorizado');
select is(pg_temp.deuda('b1'), 34500::bigint + 7000 + 1500 + 2500, 'rechazar no toca la deuda');
select is(pg_temp.n_audit('pedido_rechazado', 'cf'), 1::bigint, 'dejó un registro de auditoría');
select is((select metadata from auditoria.audit_log where event_type = 'pedido_rechazado' and fila_id = pg_temp.u('cf')),
          '{"monto_total":1500,"excede_limite":false}'::jsonb, 'sin el motivo: texto libre no se copia');
select is((select count(*)::int from auditoria.audit_log where fila_id = pg_temp.u('cf') and metadata::text like '%Excede%'), 0,
          'el motivo no está en ninguna auditoría');
select is((select target_user_id from auditoria.audit_log where event_type = 'pedido_rechazado' and fila_id = pg_temp.u('cf')),
          pg_temp.u('b1'), 'el target es el colportor');
-- Reintentos y estados.
select is(pg_temp.rech(pg_temp.u('a1'), 'cf', 'Excede la capacidad de pago') -> 0 ->> 'ya_estaba', 'true', 'el mismo motivo es un reintento');
select is(pg_temp.rech(pg_temp.u('a1'), 'cf', '  Excede la capacidad de pago ') -> 0 ->> 'ya_estaba', 'true', 'también con espacios de más');
select is(pg_temp.n_audit('pedido_rechazado', 'cf'), 1::bigint, 'sin un segundo registro');
select is(pg_temp.rech(pg_temp.u('a1'), 'cf', 'Otro motivo') ->> 'error', 'PE002', 'otro motivo no es un reintento: PE002');
select is(pg_temp.rech(pg_temp.u('ad'), 'cf', 'Excede la capacidad de pago') ->> 'error', 'PE002', 'otra persona, tampoco');
select is(pg_temp.rech(pg_temp.u('a1'), 'c1', 'No') ->> 'error', 'PE002', 'uno ya autorizado: PE002');
select is(pg_temp.rech(pg_temp.u('a1'), 'c3', 'No') ->> 'error', 'PE002', 'uno rechazado por otra persona: PE002');
select is(pg_temp.rech(pg_temp.u('a1'), 'c5', 'No') ->> 'error', 'PE002', 'un borrador: PE002');
select is(pg_temp.rech(pg_temp.u('a1'), 'cc', 'No') ->> 'error', 'PE002', 'un recibido: PE002');
select is(pg_temp.aut(pg_temp.u('a1'), 'cf') ->> 'error', 'PE002', 'y uno rechazado ya no se autoriza');
select is(pg_temp.deuda('b1'), 34500::bigint + 7000 + 1500 + 2500, 'ningún error tocó la deuda');

-- ============================================================================
-- 8. Deshacer
-- ============================================================================
-- Autorizado reducido (d5 se autoriza reducido y se deshace).
select is(pg_temp.aut(pg_temp.u('a1'), 'd5') -> 0 ->> 'estado', 'AUTORIZADO', 'd5 se autoriza');
select is(pg_temp.deuda('b1'), 34500::bigint + 7000 + 1500 + 2500 + 1500, 'y suma su deuda');
select is(pg_temp.des(pg_temp.u('a1'), 'd5') -> 0 ->> 'estado', 'PENDIENTE_AUTORIZACION', 'deshacer lo autorizado lo vuelve a esperar');
select is(pg_temp.deuda('b1'), 34500::bigint + 7000 + 1500 + 2500, 'resta de la deuda lo mismo que sumó');
select is(pg_temp.pedido('d5') - 'created_at' - 'updated_at' - 'sync_version' - 'xmin_w' - 'id' - 'fecha_pedido',
          jsonb_build_object('colportor_id', pg_temp.u('b1'), 'coordinador_id', null, 'estado', 'PENDIENTE_AUTORIZACION',
                             'monto_total', 1500, 'origen', 'COLPORTOR', 'excede_limite', false, 'created_by', null,
                             'deleted_at', null, 'monto_autorizado', null, 'decidido_por', null, 'decidido_en', null,
                             'motivo_rechazo', null),
          'el pedido queda como antes de decidirlo: sin monto autorizado, sin quién decidió ni cuándo');
select is((pg_temp.des(pg_temp.u('a1'), 'd5') -> 0 ->> 'ya_estaba'), 'true', 'deshacer de nuevo es un reintento: ya_estaba');
select is(pg_temp.deuda('b1'), 34500::bigint + 7000 + 1500 + 2500, 'y no resta dos veces');
select is(pg_temp.n_audit('pedido_decision_deshecha', 'd5'), 1::bigint, 'un solo registro de auditoría');
select is((select metadata from auditoria.audit_log where event_type = 'pedido_decision_deshecha' and fila_id = pg_temp.u('d5')),
          '{"decision_deshecha":"AUTORIZADO","monto_total":1500,"monto_autorizado":1500}'::jsonb, 'dice qué se deshizo');
select is((select actor_user_id from auditoria.audit_log where event_type = 'pedido_decision_deshecha' and fila_id = pg_temp.u('d5')),
          pg_temp.u('a1'), 'y quién');
-- Se puede autorizar de nuevo, ahora reducido.
select is(pg_temp.aut(pg_temp.u('a1'), 'd6', '[{"producto_id": "01920000-0000-7000-8000-000000011292", "cantidad": 0}]') -> 0 ->> 'monto_autorizado', '1500', 'd6 se autoriza reducido');
select is(pg_temp.deuda('b1'), 34500::bigint + 7000 + 1500 + 2500 + 1500, 'suma 1500');
select is((select cantidad_autorizada from public.pedido_item where pedido_id = pg_temp.u('d6') and producto_id = pg_temp.u('92')), 0, 'la línea en cero');
select is(pg_temp.des(pg_temp.u('a1'), 'd6') -> 0 ->> 'estado', 'PENDIENTE_AUTORIZACION', 'se deshace');
select is((select count(*)::int from public.pedido_item where pedido_id = pg_temp.u('d6') and cantidad_autorizada is not null), 0,
          'y las cantidades autorizadas se borran: vuelve lo pedido entero');
select is(pg_temp.deuda('b1'), 34500::bigint + 7000 + 1500 + 2500, 'la deuda, como antes');
select is(pg_temp.aut(pg_temp.u('a1'), 'd6') -> 0 ->> 'monto_autorizado', '4000', 'y se puede autorizar de nuevo, ahora entero: 4000');
select is(pg_temp.deuda('b1'), 34500::bigint + 7000 + 1500 + 2500 + 4000, 'suma 4000');
select is(pg_temp.n_audit('pedido_autorizado', 'd6'), 2::bigint, 'dos registros de autorización');
-- Rechazado.
select is(pg_temp.des(pg_temp.u('a1'), 'cf') -> 0 ->> 'estado', 'PENDIENTE_AUTORIZACION', 'deshacer un rechazo lo vuelve a esperar');
select is(pg_temp.pedido('cf') ->> 'motivo_rechazo', null, 'y borra el motivo');
select is(pg_temp.pedido('cf') ->> 'decidido_por', null, 'y quién decidió');
select is(pg_temp.deuda('b1'), 34500::bigint + 7000 + 1500 + 2500 + 4000, 'sin tocar la deuda');
select is((select metadata ->> 'decision_deshecha' from auditoria.audit_log where event_type = 'pedido_decision_deshecha' and fila_id = pg_temp.u('cf')),
          'RECHAZADO', 'la auditoría dice que era un rechazo');
select is(pg_temp.aut(pg_temp.u('a1'), 'cf') -> 0 ->> 'estado', 'AUTORIZADO', 'y se puede autorizar');

-- El plazo de 8 segundos (más 2 de gracia en el servidor).
select pg_temp.decidido_hace('d6', 7);
select is(pg_temp.des(pg_temp.u('a1'), 'd6') -> 0 ->> 'estado', 'PENDIENTE_AUTORIZACION', 'a los 7 segundos todavía se deshace');
select is(pg_temp.aut(pg_temp.u('a1'), 'd6') -> 0 ->> 'estado', 'AUTORIZADO', 'd6 se vuelve a autorizar');
-- La gracia de 2 s del servidor (el toque a los 7,9 s llega a los 8,5): hasta 10 s se deshace.
select pg_temp.decidido_hace('d6', 9.5);
select is(pg_temp.des(pg_temp.u('a1'), 'd6') -> 0 ->> 'estado', 'PENDIENTE_AUTORIZACION', 'a los 9,5 segundos todavía se deshace (gracia de la red)');
select is(pg_temp.aut(pg_temp.u('a1'), 'd6') -> 0 ->> 'estado', 'AUTORIZADO', 'd6 se vuelve a autorizar');
select pg_temp.decidido_hace('d6', 10.5);
select is(pg_temp.des(pg_temp.u('a1'), 'd6') ->> 'error', 'PE005', 'a los 10,5 segundos ya no');
select alike(pg_temp.des(pg_temp.u('a1'), 'd6') ->> 'mensaje', '%Pasaron más de 8 segundos%', 'el aviso dice por qué');
select is(pg_temp.pedido('d6') ->> 'estado', 'AUTORIZADO', 'el pedido sigue autorizado');
select is(pg_temp.deuda('b1'), 34500::bigint + 7000 + 1500 + 2500 + 4000 + 1500, 'y la deuda, con él (el de cf se autorizó de nuevo)');
select pg_temp.decidido_hace('d4', 11);
select is(pg_temp.des(pg_temp.u('a1'), 'd4') ->> 'error', 'PE005', 'un rechazo viejo tampoco se deshace');
select is(pg_temp.pedido('d4') ->> 'estado', 'RECHAZADO', 'sigue rechazado');
-- Solo quien decidió.
select is(pg_temp.aut(pg_temp.u('a1'), 'd9') ->> 'error', '42501', 'a1 no puede con el de la inscripción de baja (control)');
select is(pg_temp.des(pg_temp.u('ad'), 'cf') ->> 'error', 'PE005', 'otro coordinador no deshace lo que decidió a1');
select is(pg_temp.des(pg_temp.u('a2'), 'cf') ->> 'error', '42501', 'y uno ajeno, ni el permiso');
select is(pg_temp.des(null, 'cf') ->> 'error', '42501', 'sin sesión, no');
select is(pg_temp.des(pg_temp.u('b1'), 'cf') ->> 'error', '42501', 'el colportor, no');
select is(pg_temp.des(pg_temp.u('a4'), 'cf') ->> 'error', '42501', 'con el rol vencido, no');
select is(pg_temp.des(pg_temp.u('a1'), '00') ->> 'error', 'PE001', 'un pedido que no existe: PE001');
select is(pg_temp.pedido('cf') ->> 'estado', 'AUTORIZADO', 'cf sigue autorizado');
-- Un pedido que siguió su camino no se deshace.
select is(pg_temp.des(pg_temp.u('a1'), 'cc') ->> 'error', 'PE005', 'un recibido, no');
select is(pg_temp.des(pg_temp.u('a1'), 'c5') ->> 'error', 'PE005', 'un borrador, no');
select is(pg_temp.des(pg_temp.u('a1'), 'c6') ->> 'error', 'PE005', 'un cancelado, no');
update public.pedido_casa_editora set estado = 'DESPACHADO' where id = pg_temp.u('cf');
select is(pg_temp.des(pg_temp.u('a1'), 'cf') ->> 'error', 'PE005', 'uno que ya se despachó, aunque sea dentro de los 8 segundos');
select is(pg_temp.deuda('b1'), 34500::bigint + 7000 + 1500 + 2500 + 4000 + 1500, 'sin tocar la deuda');
-- Deshacer sobre uno que nunca se decidió es un reintento sin efecto.
select is(pg_temp.des(pg_temp.u('a1'), 'd0') -> 0 ->> 'ya_estaba', 'true', 'uno que espera: ya_estaba, sin efecto');
select is(pg_temp.des(pg_temp.u('a1'), 'd0') -> 0 ->> 'estado', 'PENDIENTE_AUTORIZACION', 'sigue esperando');
select is(pg_temp.n_audit('pedido_decision_deshecha', 'd0'), 0::bigint, 'y sin registro');
-- Los permisos de decisión también valen para deshacer: la campaña se cerró en el medio.
select is(pg_temp.aut(pg_temp.u('ad'), 'd8') -> 0 ->> 'estado', 'AUTORIZADO', 'el administrador autoriza el de la campaña cerrada hace 16 días');
select is(pg_temp.des(pg_temp.u('a1'), 'd8') ->> 'error', '42501', 'su coordinador de entonces no lo deshace (ya no puede decidir ahí)');

-- ============================================================================
-- 9. La bandeja después de decidir
-- ============================================================================
select is(pg_temp.fila('c1') ->> 'estado', 'AUTORIZADO', 'la bandeja ve lo decidido');
select is(pg_temp.fila('c1') ->> 'monto_autorizado', '13000', 'con su monto autorizado');
select ok((pg_temp.fila('c1') ->> 'deshacer_hasta')::timestamptz = (pg_temp.fila('c1') ->> 'decidido_en')::timestamptz + interval '8 seconds',
          'y su plazo: decidido_en + 8 s');
select is(pg_temp.fila('cd') ->> 'unidades_autorizadas', '1', 'las unidades autorizadas del reducido');
select is(pg_temp.fila('d4') ->> 'motivo_rechazo', repeat('x', 500), 'el motivo del rechazado');
select is(pg_temp.fila('d0') ->> 'estado', 'PENDIENTE_AUTORIZACION', 'lo que nadie decidió sigue esperando');

-- ============================================================================
-- 10. Los CHECK de las columnas nuevas
-- ============================================================================
create or replace function pg_temp.sql_err(p_sql text) returns text language plpgsql as $$
begin
  execute p_sql;
  return 'ok';
exception when others then
  return sqlstate || ': ' || sqlerrm;
end $$;
select is(pg_temp.sql_err(format($$ update public.pedido_casa_editora set estado = 'RECHAZADO' where id = %L $$, pg_temp.u('d0'))),
          '23514: new row for relation "pedido_casa_editora" violates check constraint "pedido_casa_editora_motivo_rechazo_check"',
          'un rechazado sin motivo no existe');
select is(pg_temp.sql_err(format($$ update public.pedido_casa_editora set estado = 'RECHAZADO', motivo_rechazo = '   ' where id = %L $$, pg_temp.u('d0'))),
          '23514: new row for relation "pedido_casa_editora" violates check constraint "pedido_casa_editora_motivo_rechazo_check"',
          'ni con un motivo en blanco');
select is(pg_temp.sql_err(format($$ update public.pedido_casa_editora set estado = 'RECHAZADO', motivo_rechazo = %L where id = %L $$, E' \t\n ', pg_temp.u('d0'))),
          '23514: new row for relation "pedido_casa_editora" violates check constraint "pedido_casa_editora_motivo_rechazo_check"',
          'ni con tabulaciones y saltos de línea');
select is(pg_temp.sql_err(format($$ update public.pedido_casa_editora set estado = 'RECHAZADO', motivo_rechazo = %L where id = %L $$, repeat('x', 501), pg_temp.u('d0'))),
          '23514: new row for relation "pedido_casa_editora" violates check constraint "pedido_casa_editora_motivo_rechazo_check"',
          'ni con 501 caracteres');
select is(pg_temp.sql_err(format($$ update public.pedido_casa_editora set estado = 'RECHAZADO', motivo_rechazo = %L where id = %L $$, repeat('x', 500), pg_temp.u('d0'))),
          'ok', 'con 500 sí');
select is(pg_temp.sql_err(format($$ update public.pedido_casa_editora set estado = 'AUTORIZADO' where id = %L $$, pg_temp.u('d0'))),
          '23514: new row for relation "pedido_casa_editora" violates check constraint "pedido_casa_editora_motivo_rechazo_check"',
          'un motivo en un pedido que no está rechazado tampoco existe');
select is(pg_temp.sql_err(format($$ update public.pedido_casa_editora set estado = 'PENDIENTE_AUTORIZACION', motivo_rechazo = null where id = %L $$, pg_temp.u('d0'))),
          'ok', 'sin motivo, vuelve a esperar');
select is(pg_temp.sql_err(format($$ update public.pedido_casa_editora set decidido_por = %L where id = %L $$, pg_temp.u('a1'), pg_temp.u('d0'))),
          '23514: new row for relation "pedido_casa_editora" violates check constraint "pedido_casa_editora_decision_completa_check"',
          'quien decidió sin cuándo: no');
select is(pg_temp.sql_err(format($$ update public.pedido_casa_editora set decidido_en = now() where id = %L $$, pg_temp.u('d0'))),
          '23514: new row for relation "pedido_casa_editora" violates check constraint "pedido_casa_editora_decision_completa_check"',
          'cuándo sin quién decidió: no');
select is(pg_temp.sql_err(format($$ update public.pedido_casa_editora set decidido_por = %L, decidido_en = now() where id = %L $$, pg_temp.u('a1'), pg_temp.u('d0'))),
          'ok', 'los dos juntos sí');
select is(pg_temp.sql_err(format($$ update public.pedido_casa_editora set decidido_por = %L where id = %L $$, pg_temp.u('ff'), pg_temp.u('d0'))),
          '23503: insert or update on table "pedido_casa_editora" violates foreign key constraint "pedido_casa_editora_decidido_por_fkey"',
          'quien decidió es un usuario');
select is(pg_temp.sql_err(format($$ update public.pedido_casa_editora set monto_autorizado = -1 where id = %L $$, pg_temp.u('d0'))),
          '23514: new row for relation "pedido_casa_editora" violates check constraint "pedido_casa_editora_monto_autorizado_check"',
          'el monto autorizado no es negativo');
select is(pg_temp.sql_err(format($$ update public.pedido_casa_editora set monto_autorizado = 0 where id = %L $$, pg_temp.u('d0'))),
          'ok', 'pero puede ser cero');
select is(pg_temp.sql_err(format($$ update public.pedido_item set cantidad_autorizada = 5 where pedido_id = %L $$, pg_temp.u('d0'))),
          '23514: new row for relation "pedido_item" violates check constraint "pedido_item_cantidad_autorizada_check"',
          'no se autoriza más de lo pedido');
select is(pg_temp.sql_err(format($$ update public.pedido_item set cantidad_autorizada = -1 where pedido_id = %L $$, pg_temp.u('d0'))),
          '23514: new row for relation "pedido_item" violates check constraint "pedido_item_cantidad_autorizada_check"',
          'ni una cantidad negativa');
select is(pg_temp.sql_err(format($$ update public.pedido_item set cantidad_autorizada = 1 where pedido_id = %L $$, pg_temp.u('d0'))),
          'ok', 'lo pedido justo sí');
select is(pg_temp.sql_err(format($$ update public.pedido_item set cantidad_autorizada = 0 where pedido_id = %L $$, pg_temp.u('d0'))),
          'ok', 'y cero también');

-- ============================================================================
-- 11. Lo de siempre no cambia
-- ============================================================================
select is(pg_temp.como(pg_temp.u('b1'), 'select count(*) as n from public.pedido_casa_editora') -> 0 ->> 'n',
          (select count(*)::text from public.pedido_casa_editora where colportor_id = pg_temp.u('b1')),
          'el colportor sigue viendo solo sus pedidos, con las columnas nuevas');
select is(pg_temp.como(pg_temp.u('b2'), 'select count(*) as n from public.pedido_casa_editora') -> 0 ->> 'n',
          (select count(*)::text from public.pedido_casa_editora where colportor_id = pg_temp.u('b2')), 'y b2 los suyos');
select is(pg_temp.err_dml(pg_temp.u('b1'), format($$ update public.pedido_casa_editora set estado = 'AUTORIZADO' where id = %L $$, pg_temp.u('d0'))),
          '42501', 'con un JWT nadie escribe el pedido directo: ni el dueño');
select is(pg_temp.err_dml(pg_temp.u('a1'), format($$ update public.pedido_casa_editora set estado = 'AUTORIZADO' where id = %L $$, pg_temp.u('d0'))),
          '42501', 'ni su coordinador: solo por las funciones');
select is(pg_temp.err_dml(pg_temp.u('a1'), format($$ update public.pedido_item set cantidad_autorizada = 1 where pedido_id = %L $$, pg_temp.u('d0'))),
          '42501', 'ni las líneas');
select is(pg_temp.err_dml(pg_temp.u('a1'), format($$ update public.estado_cuenta set deuda_total = 0 where usuario_id = %L $$, pg_temp.u('b1'))),
          '42501', 'ni la deuda');
select is(pg_temp.err(pg_temp.u('a1'), format($$ select public.mover_deuda_casa_editora(%L, 1) $$, pg_temp.u('b1'))),
          '42501', 'la pieza que mueve la deuda no se llama desde afuera');

select * from finish();
rollback;
