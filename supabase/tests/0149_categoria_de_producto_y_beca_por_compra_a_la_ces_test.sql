-- pgTAP · 0149 (backend-supabase#221, «Categorías», «Meta CES» y «Beca alcanz.» del 28/10):
--   1. producto.categoria: una de cinco, obligatoria; desde 0198 es la única (el `tipo` heredado y su trigger de
--      transición ya no existen); es_bonificable sigue aparte.
--   2. becas_de_campania(): libros_bonificables, compra_ces, estado_beca y beca_alcanzada_tipo. La beca se alcanza
--      con lo comprado a la CES en bonificables (HU-BEC-002): el caso del issue (185.000 contra 180.000), lo que no
--      es bonificable no cuenta, los libros vendidos no disparan «alcanzada», y lo alcanzado no se pierde al
--      cambiar el tipo o las metas.
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
  select ('01920000-0000-7000-8000-0000000149' || p)::uuid;
$$;
create or replace function pg_temp.error_de(p_sql text) returns text language plpgsql as $$
declare
  v_restriccion text;
begin
  execute p_sql;
  return 'ok';
exception when others then
  get stacked diagnostics v_restriccion = constraint_name;
  return sqlstate || ' ' || coalesce(v_restriccion, '');
end $$;
-- La fila de un colportor en becas_de_campania, como «libros|compra|estado|tipo alcanzado» ('-' si es null).
create or replace function pg_temp.beca(p_us text) returns text language plpgsql as $$
declare
  v_r text;
begin
  perform pg_temp.actuar_como(pg_temp.u('c1'));
  select format('%s|%s|%s|%s', r.libros_bonificables, r.compra_ces, coalesce(r.estado_beca, '-'), coalesce(r.beca_alcanzada_tipo, '-'))
    into v_r
    from public.becas_de_campania(pg_temp.u('e1')) r
   where r.usuario_id = pg_temp.u(p_us);
  perform pg_temp.actuar_como_servidor();
  return v_r;
end $$;
create or replace function pg_temp.categoria(p text) returns text language sql as $$
  select categoria from public.producto where id = pg_temp.u(p);
$$;

-- ---------------------------------------------------------------------------
-- 1. Categoría de cada producto
-- ---------------------------------------------------------------------------
select has_column('public', 'producto', 'categoria', 'producto.categoria');
select col_not_null('public', 'producto', 'categoria', 'es obligatoria');
select hasnt_column('public', 'producto', 'tipo', 'el tipo heredado ya no existe (0198): la categoría es la única');
select is((select count(*)::int from public.producto where categoria is null), 0, 'ningún producto quedó sin categoría');
select is((select count(*)::int from sync.entidad where nombre = 'producto' and sync.expresion_json(tabla) like '%''categoria''%'), 1,
          'el pull del catálogo baja la categoría (la fila va entera)');
select is((select count(*)::int from sync.entidad where nombre = 'producto' and sync.expresion_json(tabla) like '%''tipo''%'), 0,
          'y ya no baja el tipo');

-- Alta: una de las cinco, elegida por quien carga el producto.
insert into public.producto (id, nombre, categoria, es_bonificable) values
  (pg_temp.u('01'), 'Bonificables t149', 'BONIFICABLES', true),
  (pg_temp.u('02'), 'Espirituales t149', 'ESPIRITUALES', false),
  (pg_temp.u('03'), 'Revistas t149', 'REVISTAS', false),
  (pg_temp.u('04'), 'Misioneros t149', 'MISIONEROS', false),
  (pg_temp.u('05'), 'Material t149', 'MATERIAL', false);
select is(pg_temp.categoria('01'), 'BONIFICABLES', 'alta en Bonificables');
select is(pg_temp.categoria('02'), 'ESPIRITUALES', 'alta en Espirituales');
select is(pg_temp.categoria('03'), 'REVISTAS', 'alta en Revistas');
select is(pg_temp.categoria('04'), 'MISIONEROS', 'alta en Misioneros');
select is(pg_temp.categoria('05'), 'MATERIAL', 'alta en Material');
select is(pg_temp.error_de($$ insert into public.producto (id, nombre) values ('01920000-0000-7000-8000-0000000149a0', 'Sin nada t149') $$),
          '23502 ', 'sin categoría no se puede: 23502 (no hay valor por defecto)');
select is(pg_temp.error_de($$ insert into public.producto (id, nombre, categoria) values ('01920000-0000-7000-8000-0000000149a1', 'Rara t149', 'JUGOS') $$),
          '23514 producto_categoria_check', 'una categoría fuera de las cinco: 23514');
select is(pg_temp.error_de($$ insert into public.producto (id, nombre, categoria, tipo) values ('01920000-0000-7000-8000-0000000149a2', 'Con tipo t149', 'MATERIAL', 'LIBRO') $$),
          '42703 ', 'el tipo ya no existe: escribirlo da 42703 (columna inexistente)');

-- es_bonificable es aparte de la categoría.
update public.producto set es_bonificable = true where id = pg_temp.u('03');
select is(pg_temp.categoria('03') || '/' || (select es_bonificable::text from public.producto where id = pg_temp.u('03')),
          'REVISTAS/true', 'una revista puede ser bonificable: la categoría no lo decide');

-- Cambios.
update public.producto set categoria = 'MATERIAL' where id = pg_temp.u('02');
select is(pg_temp.categoria('02'), 'MATERIAL', 'cambiar la categoría la cambia');
update public.producto set nombre = 'Renombrado t149' where id = pg_temp.u('04');
select is(pg_temp.categoria('04'), 'MISIONEROS', 'cambiar otra cosa no toca la categoría');
select is(pg_temp.error_de(format($$ update public.producto set categoria = 'JUGOS' where id = %L $$, pg_temp.u('04'))),
          '23514 producto_categoria_check', 'cambiarla a una inválida: 23514');
select is((select sync_version > 0 from public.producto where id = pg_temp.u('02')), true, 'y la fila sube su versión para bajar al teléfono');

-- ---------------------------------------------------------------------------
-- 2. La beca se alcanza con la compra a la CES
-- ---------------------------------------------------------------------------
select is((select has_function_privilege('authenticated', 'public.compra_a_la_ces(uuid,uuid)', 'execute')), false,
          'compra_a_la_ces es interna: authenticated no la ejecuta');
select is((select has_function_privilege('authenticated', 'public.libros_bonificables_de_la_campania(uuid,uuid)', 'execute')), false,
          'libros_bonificables_de_la_campania también');
select is((select has_function_privilege('authenticated', 'public.becas_de_campania(uuid, integer, integer)', 'execute')
           and not has_function_privilege('anon', 'public.becas_de_campania(uuid, integer, integer)', 'execute')), true,
          'becas_de_campania, la del panel, la ejecuta authenticated y no anon');

-- Staff: c1 coordina la campaña e1. Colportores: b1 Juan (alcanza la meta), b2 Ana (compra mucho no bonificable),
-- b3 Beto (sin tipo de beca), b4 Carla (compra de lo que no cuenta: pedido sin recibir, fuera de campaña, dada de baja).
insert into auth.users (id, instance_id, aud, role, email, encrypted_password, confirmed_at, created_at, updated_at)
select pg_temp.u(s), '00000000-0000-0000-0000-000000000000',
       'authenticated', 'authenticated', 'beca149-' || s || '@example.com', 'x', now(), now(), now()
  from unnest(array['c1','b1','b2','b3','b4']) s;
insert into public.usuario_rol (usuario_id, rol_id)
select pg_temp.u(x.s), r.id
  from (values ('c1','COORDINADOR'), ('b1','COLPORTOR'), ('b2','COLPORTOR'), ('b3','COLPORTOR'), ('b4','COLPORTOR')) x(s, codigo)
  join public.rol r on r.codigo = x.codigo;
insert into public.campania (id, nombre, tipo, fecha_inicio, fecha_fin, coordinador_id) values
  (pg_temp.u('e1'), 'Verano t149', 'VERANO', public.hoy_montevideo() - 30, public.hoy_montevideo() + 30, pg_temp.u('c1'));
insert into public.campania_colportor (campania_id, usuario_id, created_at)
select pg_temp.u('e1'), pg_temp.u(s), now() - interval '40 days' from unnest(array['b1','b2','b3','b4']) s;
-- La beca asignada: COMPLETA con meta de 180.000 a b1 y b2; MEDIA con 90.000 a b4; b3 sin beca.
update public.campania_colportor set tipo_beca = 'COMPLETA', meta_libros = 120, meta_monto_ces = 180000
 where campania_id = pg_temp.u('e1') and usuario_id in (pg_temp.u('b1'), pg_temp.u('b2'));
update public.campania_colportor set tipo_beca = 'MEDIA', meta_libros = 60, meta_monto_ces = 90000
 where campania_id = pg_temp.u('e1') and usuario_id = pg_temp.u('b4');

-- Productos: 11 bonificable, 12 bonificable, 13 que no lo es.
insert into public.producto (id, nombre, categoria, es_bonificable, precio_base_compra) values
  (pg_temp.u('11'), 'Bonif 1 t149', 'BONIFICABLES', true, 1850), (pg_temp.u('12'), 'Bonif 2 t149', 'BONIFICABLES', true, 1000),
  (pg_temp.u('13'), 'Comun t149', 'ESPIRITUALES', false, 1850);

-- Pedidos a la casa editora.
--   b1: 100 × 1850 del 11 recibidos (185.000).
--   b2: 50 × 1850 del 11 (92.500) y 100 × 1850 del 13, que no es bonificable (no cuenta).
--   b4: uno AUTORIZADO sin recibir (no cuenta), uno RECIBIDO pero de hace 400 días (otra campaña), uno RECIBIDO con la
--       línea dada de baja (no cuenta) y uno RECIBIDO de 100 pedidos de los que solo se recibieron 20 (cuenta 20).
insert into public.pedido_casa_editora (id, colportor_id, coordinador_id, fecha_pedido, estado, origen) values
  (pg_temp.u('a1'), pg_temp.u('b1'), pg_temp.u('c1'), now() - interval '5 days', 'RECIBIDO', 'COLPORTOR'),
  (pg_temp.u('a2'), pg_temp.u('b2'), pg_temp.u('c1'), now() - interval '5 days', 'RECIBIDO', 'COLPORTOR'),
  (pg_temp.u('a3'), pg_temp.u('b4'), pg_temp.u('c1'), now() - interval '5 days', 'AUTORIZADO', 'COLPORTOR'),
  (pg_temp.u('a4'), pg_temp.u('b4'), pg_temp.u('c1'), now() - interval '400 days', 'RECIBIDO', 'COLPORTOR'),
  (pg_temp.u('a5'), pg_temp.u('b4'), pg_temp.u('c1'), now() - interval '4 days', 'RECIBIDO', 'COLPORTOR'),
  (pg_temp.u('a6'), pg_temp.u('b4'), pg_temp.u('c1'), now() - interval '3 days', 'RECIBIDO', 'COLPORTOR');
insert into public.pedido_item (id, pedido_id, producto_id, cantidad, precio_unitario, cantidad_recibida, deleted_at) values
  (pg_temp.u('b1'), pg_temp.u('a1'), pg_temp.u('11'), 100, 1850, null, null),
  (pg_temp.u('b2'), pg_temp.u('a2'), pg_temp.u('11'), 50, 1850, null, null),
  (pg_temp.u('b3'), pg_temp.u('a2'), pg_temp.u('13'), 100, 1850, null, null),
  (pg_temp.u('b4'), pg_temp.u('a3'), pg_temp.u('11'), 40, 1850, null, null),
  (pg_temp.u('b5'), pg_temp.u('a4'), pg_temp.u('11'), 40, 1850, null, null),
  (pg_temp.u('b6'), pg_temp.u('a5'), pg_temp.u('11'), 40, 1850, null, now()),
  (pg_temp.u('b7'), pg_temp.u('a6'), pg_temp.u('12'), 100, 1000, 20, null);

-- Ventas de libros bonificables: b1 vende 5 del 11 y devuelve 2; b2 vende 500 (muchos libros, poca compra).
insert into public.pais (id, nombre, iso_code) values (pg_temp.u('f0'), 'Pais dev149', 'ZV');
insert into public.ciudad (id, nombre, departamento, pais_id, lat_centro, lon_centro)
values (pg_temp.u('f1'), 'Ciudad dev149', 'Departamento de prueba', pg_temp.u('f0'), -34.90, -56.20);
insert into public.ubicacion (id, tipo, calle, numero, lat, lon, ciudad_id, created_by) values
  (pg_temp.u('01'), 'CASA', 'Av. Italia', '100', -34.900, -56.200, pg_temp.u('f1'), pg_temp.u('b1'));
insert into public.espacio (id, ubicacion_id, created_by) values (pg_temp.u('e2'), pg_temp.u('01'), pg_temp.u('b1'));
insert into public.espacio_persona (id, espacio_id, persona_id, created_by) values
  (pg_temp.u('51'), pg_temp.u('e2'), pg_temp.u('c2'), pg_temp.u('b1'));
insert into public.venta (id, espacio_persona_id, numero_talonario, monto_total, fecha, colportor_id, created_by) values
  (pg_temp.u('71'), pg_temp.u('51'), 'T-14971', 100000, now() - interval '2 days', pg_temp.u('b1'), pg_temp.u('b1')),
  (pg_temp.u('72'), pg_temp.u('51'), 'T-14972', 100000, now() - interval '2 days', pg_temp.u('b2'), pg_temp.u('b2'));
insert into public.venta_item (id, venta_id, producto_id, cantidad, precio_unitario, subtotal) values
  (pg_temp.u('81'), pg_temp.u('71'), pg_temp.u('11'), 5, 10000, 50000),
  (pg_temp.u('82'), pg_temp.u('71'), pg_temp.u('13'), 4, 10000, 40000),
  (pg_temp.u('83'), pg_temp.u('72'), pg_temp.u('11'), 500, 100, 50000);
insert into public.devolucion (id, venta_id, productos_devueltos, fecha_devolucion, colportor_id) values
  (pg_temp.u('d1'), pg_temp.u('71'), jsonb_build_array(jsonb_build_object('producto_id', pg_temp.u('11'), 'cantidad', 2,
                                                                          'venta_item_id', pg_temp.u('81'))),
   now() - interval '1 day', pg_temp.u('b1'));

-- El caso del issue: Juan compró 185.000 en bonificables contra 180.000: alcanzada.
select is(pg_temp.beca('b1'), '3|185000|ALCANZADA|COMPLETA',
          'Juan: 3 libros (5 vendidos menos 2 devueltos), compró 185.000 contra 180.000: ALCANZADA (COMPLETA)');
-- Ana: 92.500 de bonificables (los 185.000 del libro común no cuentan) y 500 libros vendidos: no alcanza.
select is(pg_temp.beca('b2'), '500|92500|EN_PROGRESO|-',
          'Ana: compró 92.500 en bonificables (lo que no es bonificable no cuenta): EN_PROGRESO, aunque vendió 500 libros');
-- Beto: sin tipo de beca.
select is(pg_temp.beca('b3'), '0|0|-|-', 'Beto, sin beca asignada: sin estado');
-- Carla: solo cuenta la línea recibida de 20 × 1000 = 20.000 (no la autorizada sin recibir, ni la de otra campaña, ni la borrada).
select is(pg_temp.beca('b4'), '0|20000|EN_PROGRESO|-',
          'Carla: cuenta lo recibido (20 de los 100 pedidos); el pedido sin recibir, el de otra campaña y la línea dada de baja no');

-- Los libros vendidos no disparan «alcanzada»: 500 libros contra 120 de meta y sigue en progreso (arriba). Y si la
-- compra cruza la meta, se alcanza.
update public.pedido_item set cantidad_recibida = 100 where id = pg_temp.u('b7');
select is(pg_temp.beca('b4'), '0|100000|ALCANZADA|MEDIA', 'cuando Carla recibe los 100, su compra (100.000) pasa los 90.000: ALCANZADA (MEDIA)');

-- Lo alcanzado no se pierde: Juan pasa a «Sin beca» (tipo y metas en null) y el evento queda.
update public.campania_colportor set tipo_beca = null, meta_libros = null, meta_monto_ces = null
 where campania_id = pg_temp.u('e1') and usuario_id = pg_temp.u('b1');
select is((select count(*)::int from auditoria.audit_log
            where event_type = 'beca_alcanzada' and target_user_id = pg_temp.u('b1')), 1,
          'al cambiarle la beca a una que ya había alcanzado, queda el evento beca_alcanzada');
select is((select metadata ->> 'tipo_beca' || '/' || (metadata ->> 'meta_monto_ces') || '/' || (metadata ->> 'compra_ces')
             from auditoria.audit_log where event_type = 'beca_alcanzada' and target_user_id = pg_temp.u('b1')),
          'COMPLETA/180000/185000', 'con el tipo, la meta y la compra de ese momento (sin datos personales)');
select is(pg_temp.beca('b1'), '3|185000|ALCANZADA|COMPLETA', 'Juan sigue con la beca alcanzada aunque ya no tenga meta');
-- Si después le asignan una beca más chica que también alcanza (MEDIA, 90.000), se sigue viendo lo que alcanzó: COMPLETA.
update public.campania_colportor set tipo_beca = 'MEDIA', meta_libros = 60, meta_monto_ces = 90000
 where campania_id = pg_temp.u('e1') and usuario_id = pg_temp.u('b1');
select is(pg_temp.beca('b1'), '3|185000|ALCANZADA|COMPLETA',
          'le bajan la beca a MEDIA y también la alcanza: se ve lo que alcanzó (COMPLETA), no el tipo de ahora');
update public.campania_colportor set tipo_beca = null, meta_libros = null, meta_monto_ces = null
 where campania_id = pg_temp.u('e1') and usuario_id = pg_temp.u('b1');
select is(pg_temp.beca('b1'), '3|185000|ALCANZADA|COMPLETA', 'y al volver a «Sin beca» sigue igual');
-- Ana, que no la había alcanzado, queda sin estado al pasar a «Sin beca» y sin evento.
update public.campania_colportor set tipo_beca = null, meta_libros = null, meta_monto_ces = null
 where campania_id = pg_temp.u('e1') and usuario_id = pg_temp.u('b2');
select is((select count(*)::int from auditoria.audit_log
            where event_type = 'beca_alcanzada' and target_user_id = pg_temp.u('b2')), 0, 'Ana no había alcanzado nada: sin evento');
select is(pg_temp.beca('b2'), '500|92500|-|-', 'y sin tipo de beca no hay estado');

-- Cambiar otra cosa de la inscripción no dispara el evento.
update public.campania_colportor set meta_libros = 61 where campania_id = pg_temp.u('e1') and usuario_id = pg_temp.u('b4');
select is((select count(*)::int from auditoria.audit_log where event_type = 'beca_alcanzada' and target_user_id = pg_temp.u('b4')), 0,
          'cambiar otra cosa de la inscripción (las metas de libros) no deja evento');

-- La forma de la respuesta: las 4 columnas nuevas viajan para el panel, sin datos de clientes.
select pg_temp.actuar_como(pg_temp.u('c1'));
select ok((select to_jsonb(r) ?& array['libros_bonificables','compra_ces','estado_beca','beca_alcanzada_tipo']
             from public.becas_de_campania(pg_temp.u('e1')) r limit 1), 'la fila trae las cuatro columnas nuevas');
select is((select count(*)::int from public.becas_de_campania(pg_temp.u('e1'))), 4, 'y siguen saliendo los cuatro inscriptos');
select is(pg_temp.error_de(format($$ select * from public.becas_de_campania(%L) $$, pg_temp.u('e1'))), 'ok', 'el coordinador de la campaña la consulta');
select pg_temp.actuar_como(pg_temp.u('b1'));
select is(pg_temp.error_de(format($$ select * from public.becas_de_campania(%L) $$, pg_temp.u('e1'))), '42501 ',
          'una colportora no consulta las becas del equipo: 42501');
select pg_temp.actuar_como_servidor();

select * from finish();
rollback;
