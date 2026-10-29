-- pgTAP · supabase/ops/retirar-demo-argentina.sql (backend-supabase#216): el retiro de la demo de Argentina.
--   1. Se frena, sin cambiar nada, si el catálogo de la demo lo usa una venta de otro lado.
--   2. Sin pedir aplicar corre en vista previa: cuenta todo y no cambia nada.
--   3. Aplicado, da de baja lógica toda la demo de AR (geografía, campaña, inscripciones, catálogo, pedidos, stock,
--      ubicaciones y la actividad de colportor2.demo), bloquea el login de colportor2.demo y NO toca Uruguay ni a
--      colportor.demo ni a coordinador.demo.
--   4. Nada se borra de verdad: las filas siguen ahí con deleted_at y sync_version subió (el teléfono recibe la baja).
--   5. Correrlo dos veces no encuentra nada nuevo.
-- El bloqueo del login (banned_until) solo existe en Supabase Auth: acá se prueba que no falla sin él.
-- El script se carga con \i, tal como se pega en el SQL Editor. Va en una transacción.
begin;
select * from no_plan();

-- --- helpers -------------------------------------------------------------------
create or replace function pg_temp.u(p text) returns uuid language sql as $$
  select ('01920000-0000-7000-8000-0000000216' || p)::uuid;
$$;
-- El catálogo de la demo lleva los ids con los que se sembró (lo único que el script busca por id).
create or replace function pg_temp.dede(p_tag text, p_n integer) returns uuid language sql as $$
  select ('dede0000-0000-7000-' || p_tag || '-' || lpad(to_hex(p_n), 12, '0'))::uuid;
$$;

-- Cuántas filas de la lista siguen vivas. pk: la columna que las identifica.
create or replace function pg_temp.vivas(p_tabla text, p_pk text, p_ids uuid[]) returns bigint language plpgsql as $$
declare
  v bigint;
begin
  execute format('select count(*) from public.%I where %I = any ($1) and deleted_at is null', p_tabla, p_pk)
    into v using p_ids;
  return v;
end $$;
create or replace function pg_temp.existen(p_tabla text, p_pk text, p_ids uuid[]) returns bigint language plpgsql as $$
declare
  v bigint;
begin
  execute format('select count(*) from public.%I where %I = any ($1)', p_tabla, p_pk) into v using p_ids;
  return v;
end $$;

-- --- fixtures (como postgres) --------------------------------------------------
-- co coordinador.demo, d1 colportor.demo (Uruguay y Argentina), d2 colportor2.demo (solo Argentina).
insert into auth.users (id, instance_id, aud, role, email, encrypted_password, confirmed_at, created_at, updated_at)
select pg_temp.u(x.s), '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
       x.mail, 'x', now(), now(), now()
  from (values ('a1', 'coordinador.demo@example.com'), ('a2', 'colportor.demo@example.com'),
               ('a3', 'colportor2.demo@example.com')) x(s, mail);
insert into public.usuario_rol (usuario_id, rol_id)
select pg_temp.u(x.s), r.id
  from (values ('a1', 'COORDINADOR'), ('a2', 'COLPORTOR'), ('a3', 'COLPORTOR')) x(s, codigo)
  join public.rol r on r.codigo = x.codigo;

-- Uruguay (lo que se queda): campaña ya terminada para que d1 pueda estar también en la de AR.
insert into public.pais (id, nombre, iso_code) values (pg_temp.u('b0'), 'Uruguay t216', 'UY');
insert into public.ciudad (id, nombre, departamento, pais_id, lat_centro, lon_centro)
values (pg_temp.u('b1'), 'Montevideo t216', 'Montevideo', pg_temp.u('b0'), -34.90, -56.16);
insert into public.campania (id, nombre, tipo, fecha_inicio, fecha_fin, coordinador_id)
values (pg_temp.u('b2'), 'Campaña Montevideo t216', 'VERANO', public.hoy_montevideo() - 200, public.hoy_montevideo() - 60, pg_temp.u('a1'));
insert into public.campania_ciudad (id, campania_id, ciudad_id) values (pg_temp.u('b3'), pg_temp.u('b2'), pg_temp.u('b1'));
insert into public.zona (id, nombre, campania_ciudad_id, tipo_forma, centro_lat, centro_lon, radio_m)
values (pg_temp.u('b4'), 'Zona UY', pg_temp.u('b3'), 'RADIAL', -34.90, -56.16, 300);
insert into public.campania_colportor (id, campania_id, usuario_id, zona_id, created_at)
values (pg_temp.u('b5'), pg_temp.u('b2'), pg_temp.u('a2'), pg_temp.u('b4'), now() - interval '200 days');
insert into public.ubicacion (id, tipo, calle, numero, lat, lon, ciudad_id)
values (pg_temp.u('b6'), 'CASA', 'Av. Italia', '100', -34.900, -56.160, pg_temp.u('b1'));
insert into public.espacio (id, ubicacion_id) values (pg_temp.u('b7'), pg_temp.u('b6'));
insert into public.espacio_persona (id, espacio_id, persona_id) values (pg_temp.u('b8'), pg_temp.u('b7'), pg_temp.u('ff'));
insert into public.visita (id, espacio_persona_id, espacio_id, fecha, tipo_resultado, colportor_id)
values (pg_temp.u('bf'), pg_temp.u('b8'), pg_temp.u('b7'), now(), 'RECHAZO', pg_temp.u('a2'));
insert into public.venta (id, espacio_persona_id, numero_talonario, monto_total, fecha, colportor_id)
values (pg_temp.u('b9'), pg_temp.u('b8'), 'T-UY', 6500, now(), pg_temp.u('a2'));
insert into public.cobranza (id, venta_id, monto, medio, fecha) values (pg_temp.u('ba'), pg_temp.u('b9'), 1000, 'EFECTIVO', now());
insert into public.producto (id, nombre, tipo) values (pg_temp.u('bb'), 'Libro UY t216', 'LIBRO');
insert into public.venta_item (id, venta_id, producto_id, cantidad, precio_unitario, subtotal)
values (pg_temp.u('be'), pg_temp.u('b9'), pg_temp.u('bb'), 1, 4500, 4500);
insert into public.pedido_casa_editora (id, colportor_id, estado, monto_total, origen)
values (pg_temp.u('bc'), pg_temp.u('a2'), 'AUTORIZADO', 4500, 'COLPORTOR');
insert into public.pedido_item (id, pedido_id, producto_id, cantidad, precio_unitario, colportor_id)
values (pg_temp.u('bd'), pg_temp.u('bc'), pg_temp.u('bb'), 3, 1500, pg_temp.u('a2'));
insert into public.movimiento_stock (id, usuario_id, producto_id, tipo, cantidad, pedido_id)
values (pg_temp.u('b1') , pg_temp.u('a2'), pg_temp.u('bb'), 'ENTRADA_PEDIDO', 3, pg_temp.u('bc'));
insert into public.cuenta_colportor (usuario_id, deuda_total) values (pg_temp.u('a1'), 0);

-- Argentina (lo que se retira)
insert into public.pais (id, nombre, iso_code) values (pg_temp.u('c0'), 'Argentina t216', 'AR');
insert into public.ciudad (id, nombre, departamento, pais_id, lat_centro, lon_centro, origen,
                           bbox_oeste, bbox_sur, bbox_este, bbox_norte)
values (pg_temp.u('c1'), 'Libertador San Martín t216', 'Diamante', pg_temp.u('c0'), -32.07, -60.46, 'MANUAL',
        -60.495, -32.095, -60.43, -32.04);
insert into public.campania (id, nombre, tipo, fecha_inicio, fecha_fin, coordinador_id, alquiler_monto, limite_deuda)
values (pg_temp.u('c2'), 'Campaña Libertador San Martín t216', 'VERANO',
        public.hoy_montevideo() - 10, public.hoy_montevideo() + 100, null, 100000, 500000);
insert into public.campania_ciudad (id, campania_id, ciudad_id) values (pg_temp.u('c3'), pg_temp.u('c2'), pg_temp.u('c1'));
insert into public.zona (id, nombre, campania_ciudad_id, tipo_forma, centro_lat, centro_lon, radio_m)
values (pg_temp.u('c4'), 'Zona Centro t216', pg_temp.u('c3'), 'RADIAL', -32.07, -60.46, 300);
insert into public.campania_colportor (id, campania_id, usuario_id, zona_id, created_at) values
  (pg_temp.u('c5'), pg_temp.u('c2'), pg_temp.u('a2'), pg_temp.u('c4'), now() - interval '9 days'),
  (pg_temp.u('c6'), pg_temp.u('c2'), pg_temp.u('a3'), pg_temp.u('c4'), now() - interval '9 days');

-- El catálogo de la demo, con sus ids de siembra.
insert into public.producto (id, nombre, tipo) values
  (pg_temp.dede('8005', 1), 'Libro AR 1 t216', 'LIBRO'), (pg_temp.dede('8005', 2), 'Libro AR 2 t216', 'LIBRO');
insert into public.coleccion (id, nombre) values (pg_temp.dede('8006', 1), 'Colección AR t216');
insert into public.producto_coleccion (id, producto_id, coleccion_id)
values (pg_temp.u('d8'), pg_temp.dede('8005', 1), pg_temp.dede('8006', 1));
insert into public.precio_general (id, producto_id, precio_venta) values (pg_temp.u('d7'), pg_temp.dede('8005', 1), 2000);
insert into public.precio_por_ciudad (id, producto_id, precio_venta, campania_ciudad_id)
values (pg_temp.u('d6'), pg_temp.dede('8005', 2), 2500, pg_temp.u('c3'));
insert into public.carrera (id, nombre) values (pg_temp.dede('801e', 1), 'Carrera AR t216');
insert into public.meta_beca (id, carrera_id, tipo_campania, meta_media, meta_completa, meta_media_monto, meta_completa_monto)
values (pg_temp.u('d9'), pg_temp.dede('801e', 1), 'VERANO', 10, 20, 100000, 200000);

-- Pedido a la casa editora, su entrada de stock (el trigger arma el stock) y las cuentas.
insert into public.pedido_casa_editora (id, colportor_id, estado, monto_total, origen)
values (pg_temp.u('d3'), pg_temp.u('a3'), 'AUTORIZADO', 20000, 'COLPORTOR');
insert into public.pedido_item (id, pedido_id, producto_id, cantidad, precio_unitario, colportor_id)
values (pg_temp.u('d4'), pg_temp.u('d3'), pg_temp.dede('8005', 1), 10, 2000, pg_temp.u('a3'));
insert into public.movimiento_stock (id, usuario_id, producto_id, tipo, cantidad, pedido_id)
values (pg_temp.u('d5'), pg_temp.u('a3'), pg_temp.dede('8005', 1), 'ENTRADA_PEDIDO', 10, pg_temp.u('d3'));
insert into public.cuenta_colportor (usuario_id, deuda_total) values (pg_temp.u('a2'), 1000), (pg_temp.u('a3'), 20000);

-- Ubicación y actividad de colportor2.
insert into public.ubicacion (id, tipo, calle, numero, lat, lon, ciudad_id)
values (pg_temp.u('c7'), 'CASA', 'Calle Real', '10', -32.07, -60.46, pg_temp.u('c1'));
insert into public.house_status (ubicacion_id, lat, lon, tipo_ubicacion, color, prioridad)
values (pg_temp.u('c7'), -32.07, -60.46, 'CASA', 'VENTA_COMPLETA', 4);
insert into public.espacio (id, ubicacion_id) values (pg_temp.u('c8'), pg_temp.u('c7'));
insert into public.espacio_persona (id, espacio_id, persona_id) values (pg_temp.u('c9'), pg_temp.u('c8'), pg_temp.u('fe'));
insert into public.jornada (id, colportor_id, inicio) values (pg_temp.u('ca'), pg_temp.u('a3'), now() - interval '3 hours');
insert into public.visita (id, espacio_persona_id, espacio_id, fecha, tipo_resultado, colportor_id, jornada_id)
values (pg_temp.u('cb'), pg_temp.u('c9'), pg_temp.u('c8'), now(), 'VENTA', pg_temp.u('a3'), pg_temp.u('ca'));
insert into public.venta (id, espacio_persona_id, numero_talonario, monto_total, fecha, colportor_id, visita_id)
values (pg_temp.u('cc'), pg_temp.u('c9'), 'T-AR', 4000, now(), pg_temp.u('a3'), pg_temp.u('cb'));
insert into public.venta_item (id, venta_id, producto_id, cantidad, precio_unitario, subtotal)
values (pg_temp.u('cd'), pg_temp.u('cc'), pg_temp.dede('8005', 1), 2, 2000, 4000);
insert into public.entrega (id, venta_id, producto_id, cantidad, fecha_entrega, pendiente)
values (pg_temp.u('ce'), pg_temp.u('cc'), pg_temp.dede('8005', 1), 2, now(), false);
insert into public.cobranza (id, venta_id, monto, medio, fecha) values (pg_temp.u('cf'), pg_temp.u('cc'), 1500, 'EFECTIVO', now());
insert into public.agenda (id, espacio_persona_id, espacio_id, tipo, fecha_programada, colportor_id, venta_id, monto_previsto)
values (pg_temp.u('d0'), pg_temp.u('c9'), pg_temp.u('c8'), 'COBRANZA', now() + interval '2 days', pg_temp.u('a3'),
        pg_temp.u('cc'), 2500);
insert into public.deposito (id, colportor_id, monto, fecha, destino, concepto, campania_id)
values (pg_temp.u('d1'), pg_temp.u('a3'), 1500, public.hoy_montevideo(), 'RETIRO_COORDINADOR', 'CASA_EDITORA', pg_temp.u('c2'));
insert into public.deposito_cobro (id, deposito_id, cobranza_id, colportor_id)
values (pg_temp.u('d2'), pg_temp.u('d1'), pg_temp.u('cf'), pg_temp.u('a3'));

-- Qué es de AR y qué es de Uruguay, tabla por tabla (tabla, columna que la identifica, ids).
create temp table t_ar (tabla text, pk text, ids uuid[]) on commit drop;
insert into t_ar values
  ('pais', 'id', array[pg_temp.u('c0')]), ('ciudad', 'id', array[pg_temp.u('c1')]),
  ('campania', 'id', array[pg_temp.u('c2')]), ('campania_ciudad', 'id', array[pg_temp.u('c3')]),
  ('zona', 'id', array[pg_temp.u('c4')]), ('campania_colportor', 'id', array[pg_temp.u('c5'), pg_temp.u('c6')]),
  ('producto', 'id', array[pg_temp.dede('8005', 1), pg_temp.dede('8005', 2)]),
  ('coleccion', 'id', array[pg_temp.dede('8006', 1)]), ('producto_coleccion', 'id', array[pg_temp.u('d8')]),
  ('precio_general', 'id', array[pg_temp.u('d7')]), ('precio_por_ciudad', 'id', array[pg_temp.u('d6')]),
  ('carrera', 'id', array[pg_temp.dede('801e', 1)]), ('meta_beca', 'id', array[pg_temp.u('d9')]),
  ('pedido_casa_editora', 'id', array[pg_temp.u('d3')]), ('pedido_item', 'id', array[pg_temp.u('d4')]),
  ('movimiento_stock', 'id', array[pg_temp.u('d5'), (select m.id from public.movimiento_stock m
                                                       where m.entrega_id = pg_temp.u('ce'))]),
  ('ubicacion', 'id', array[pg_temp.u('c7')]), ('house_status', 'ubicacion_id', array[pg_temp.u('c7')]),
  ('espacio', 'id', array[pg_temp.u('c8')]), ('espacio_persona', 'id', array[pg_temp.u('c9')]),
  ('jornada', 'id', array[pg_temp.u('ca')]), ('visita', 'id', array[pg_temp.u('cb')]),
  ('venta', 'id', array[pg_temp.u('cc')]), ('venta_item', 'id', array[pg_temp.u('cd')]),
  ('entrega', 'id', array[pg_temp.u('ce')]), ('cobranza', 'id', array[pg_temp.u('cf')]),
  ('agenda', 'id', array[pg_temp.u('d0')]), ('deposito', 'id', array[pg_temp.u('d1')]),
  ('deposito_cobro', 'id', array[pg_temp.u('d2')]), ('usuario', 'id', array[pg_temp.u('a3')]),
  ('usuario_rol', 'usuario_id', array[pg_temp.u('a3')]),
  ('cuenta_colportor', 'usuario_id', array[pg_temp.u('a3')]);
-- Lo que los triggers armaron solos y también tiene que caer (se busca por su dueño, sin ids fijos).
insert into t_ar
select 'stock', 'id', array_agg(id) from public.stock where producto_id in (pg_temp.dede('8005', 1), pg_temp.dede('8005', 2))
union all
select 'cuenta_alquiler', 'id', array_agg(id) from public.cuenta_alquiler where campania_id = pg_temp.u('c2')
union all
select 'campania_colportor_zona_historial', 'id', array_agg(id)
  from public.campania_colportor_zona_historial where campania_colportor_id in (pg_temp.u('c5'), pg_temp.u('c6'));

create temp table t_uy (tabla text, pk text, ids uuid[]) on commit drop;
insert into t_uy values
  ('pais', 'id', array[pg_temp.u('b0')]), ('ciudad', 'id', array[pg_temp.u('b1')]),
  ('campania', 'id', array[pg_temp.u('b2')]), ('campania_ciudad', 'id', array[pg_temp.u('b3')]),
  ('zona', 'id', array[pg_temp.u('b4')]), ('campania_colportor', 'id', array[pg_temp.u('b5')]),
  ('ubicacion', 'id', array[pg_temp.u('b6')]), ('espacio', 'id', array[pg_temp.u('b7')]),
  ('espacio_persona', 'id', array[pg_temp.u('b8')]), ('visita', 'id', array[pg_temp.u('bf')]),
  ('venta', 'id', array[pg_temp.u('b9')]), ('venta_item', 'id', array[pg_temp.u('be')]),
  ('cobranza', 'id', array[pg_temp.u('ba')]), ('producto', 'id', array[pg_temp.u('bb')]),
  ('pedido_casa_editora', 'id', array[pg_temp.u('bc')]), ('pedido_item', 'id', array[pg_temp.u('bd')]),
  ('movimiento_stock', 'id', array[pg_temp.u('b1')]),
  ('usuario', 'id', array[pg_temp.u('a1'), pg_temp.u('a2')]),
  ('usuario_rol', 'usuario_id', array[pg_temp.u('a1'), pg_temp.u('a2')]),
  ('cuenta_colportor', 'usuario_id', array[pg_temp.u('a1'), pg_temp.u('a2')]);
insert into t_uy
select 'stock', 'id', array_agg(id) from public.stock where producto_id = pg_temp.u('bb');

-- Cuántas filas de la lista están vivas en total (la suma de todas las tablas).
create or replace function pg_temp.total_vivas(p_lista text) returns bigint language plpgsql as $$
declare
  v bigint := 0;
  r record;
begin
  for r in execute format('select tabla, pk, ids from %I', p_lista) loop
    v := v + pg_temp.vivas(r.tabla, r.pk, r.ids);
  end loop;
  return v;
end $$;
create or replace function pg_temp.total_filas(p_lista text) returns bigint language plpgsql as $$
declare
  v bigint := 0;
  r record;
begin
  for r in execute format('select tabla, pk, ids from %I', p_lista) loop
    v := v + pg_temp.existen(r.tabla, r.pk, r.ids);
  end loop;
  return v;
end $$;

select ok((select bool_and(array_length(ids, 1) > 0 and ids is not null) from t_ar),
          'fixture: cada tabla de AR tiene filas (incluidas stock, cuenta de alquiler e historial de zonas)');
select cmp_ok(pg_temp.total_vivas('t_ar'), '=', pg_temp.total_filas('t_ar'), 'fixture: todo lo de AR arranca vivo');
select cmp_ok(pg_temp.total_vivas('t_uy'), '=', pg_temp.total_filas('t_uy'), 'fixture: todo lo de Uruguay arranca vivo');

create temp table fotos (n text, vivas_ar bigint, vivas_uy bigint, versiones bigint) on commit drop;
-- sync_version sumada de las filas de AR: la baja la tiene que subir.
create or replace function pg_temp.versiones_ar() returns bigint language plpgsql as $$
declare
  v bigint := 0;
  r record;
  x bigint;
begin
  for r in select tabla, pk, ids from t_ar loop
    execute format('select coalesce(sum(sync_version), 0) from public.%I where %I = any ($1)', r.tabla, r.pk)
      into x using r.ids;
    v := v + x;
  end loop;
  return v;
end $$;
insert into fotos values ('antes', pg_temp.total_vivas('t_ar'), pg_temp.total_vivas('t_uy'), pg_temp.versiones_ar());

-- --- 1. Se frena si la demo y el dominio comparten catálogo ----------------------
-- Una venta de Uruguay que usa un libro de la demo de Argentina.
insert into public.venta_item (id, venta_id, producto_id, cantidad, precio_unitario, subtotal)
values (pg_temp.u('e1'), pg_temp.u('b9'), pg_temp.dede('8005', 1), 1, 2000, 2000);

savepoint s_guarda;
select set_config('retiro.aplicar', 'si', true);
\set ON_ERROR_STOP off
\o /dev/null
\i supabase/ops/retirar-demo-argentina.sql
\o
rollback to savepoint s_guarda;
\set ON_ERROR_STOP on

select cmp_ok(pg_temp.total_vivas('t_ar'), '=', (select vivas_ar from fotos where n = 'antes'),
              'con una venta ajena que usa el catálogo de la demo, el retiro se frena y no cambia nada');
delete from public.venta_item where id = pg_temp.u('e1');

-- --- 2. Vista previa: cuenta todo y no cambia nada -------------------------------
select set_config('retiro.aplicar', '', true);
\o /dev/null
\i supabase/ops/retirar-demo-argentina.sql
\o

select cmp_ok(pg_temp.total_vivas('t_ar'), '=', (select vivas_ar from fotos where n = 'antes'),
              'vista previa: la demo de AR sigue viva');
select cmp_ok(pg_temp.total_vivas('t_uy'), '=', (select vivas_uy from fotos where n = 'antes'),
              'vista previa: Uruguay sigue vivo');
select is((select que from retiro_resumen order by orden limit 1), 'VISTA PREVIA (no se cambió nada)',
          'vista previa: el resumen lo dice en el primer renglón');
select is((select filas from retiro_resumen where que = 'venta'), 1, 'vista previa: cuenta lo que daría de baja (la venta)');
select is((select filas from retiro_resumen where que = 'pais'), 1, 'vista previa: el país AR');
select is((select filas from retiro_resumen where que = 'usuario'), 1, 'vista previa: colportor2.demo');

-- --- 3. Aplicado -----------------------------------------------------------------
select set_config('retiro.aplicar', 'si', true);
\o /dev/null
\i supabase/ops/retirar-demo-argentina.sql
\o

select is((select que from retiro_resumen order by orden limit 1), 'APLICADO', 'aplicado: el resumen lo dice');
select is(pg_temp.total_vivas('t_ar'), 0::bigint, 'aplicado: no queda NINGUNA fila viva de la demo de AR');
select cmp_ok(pg_temp.total_vivas('t_uy'), '=', (select vivas_uy from fotos where n = 'antes'),
              'aplicado: Uruguay, colportor.demo y coordinador.demo siguen vivos');
select is(pg_temp.total_filas('t_ar'), (select count(*) from (select unnest(ids) from t_ar) z)::bigint,
          'nada se borró de verdad: todas las filas de la demo siguen ahí, con su baja');
select cmp_ok(pg_temp.versiones_ar(), '>', (select versiones from fotos where n = 'antes'),
              'cada baja sube sync_version: los teléfonos reciben la baja');
select is((select count(*) from public.pais where deleted_at is null and iso_code <> 'UY'), 0::bigint,
          'criterio: ningún país vivo fuera de UY');
select is((select count(*) from public.ubicacion u join public.ciudad c on c.id = u.ciudad_id
                                                    join public.pais p on p.id = c.pais_id
            where u.deleted_at is null and p.iso_code <> 'UY'), 0::bigint,
          'criterio: ninguna ubicación viva fuera de UY');
-- La base local no trae la columna banned_until (es de Supabase Auth, y postgres no es su dueño): ahí el script no
-- tiene qué bloquear y lo dice con un 0. El bloqueo real se verifica en el proyecto de desarrollo (README de ops).
select is((select filas from retiro_resumen where que = 'auth.users (login bloqueado)'), 0,
          'sin la columna banned_until de Supabase Auth, el script no falla ni inventa un bloqueo');
-- La cuenta de saldo de colportor.demo sigue viva, y la deuda que se le mueva después cuenta (no cae en una fila oculta).
select public.mover_deuda_casa_editora(pg_temp.u('a2'), 500);
select is((select deuda_total from public.cuenta_colportor where usuario_id = pg_temp.u('a2') and deleted_at is null),
          1500::bigint, 'la cuenta de colportor.demo sigue viva y suma la deuda nueva');
select is((select count(*) from auth.users where email like '%.demo@example.com'), 3::bigint,
          'las cuentas de Auth no se borran');
select ok((select deleted_at is null from public.campania where id = pg_temp.u('b2')),
          'la campaña de Montevideo sigue viva');
select is((select coordinador_id from public.campania where id = pg_temp.u('b2')), pg_temp.u('a1'),
          'y con su coordinador');

-- --- 4. Dos veces: no encuentra nada ---------------------------------------------
\o /dev/null
\i supabase/ops/retirar-demo-argentina.sql
\o
select is((select coalesce(sum(filas), 0) from retiro_resumen), 0::bigint, 'correrlo de nuevo no da de baja nada más');

select * from finish();
rollback;
