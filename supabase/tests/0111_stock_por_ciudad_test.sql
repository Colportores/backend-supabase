-- pgTAP · stock por ciudad para el panel (migración 0111, backend-supabase#101, HU-STK-010, vista 34)
-- stock_por_ciudad() y pedidos_por_autorizar_por_ciudad(): la forma de la respuesta y los privilegios; el
-- permiso primero (sin JWT, anon, colportor, sin rol, rol vencido, coordinador de otra campaña) y que una
-- campaña terminada se lee; los errores de campaña; lo que tiene cada colportor (el stock vivo, negativo
-- tal cual, el renglón dado de baja no cuenta), lo por entregar, lo entregado y lo por cobrar (venta con
-- saldo: cobros dados de baja y anulados no cuentan; cobro parcial; venta paga); qué ventas cuentan (los
-- bordes de la campaña, la baja de la inscripción, el día en que se inscribió, ventas y entregas dadas de
-- baja); la ciudad de la zona actual y «sin ciudad» (sin zona, zona dada de baja, inscripción de baja);
-- qué productos salen (los que tienen movimiento; el de baja solo si queda algo); que cada campaña ve lo
-- suyo; la fecha del último push; los pedidos por autorizar por ciudad; que la respuesta no trae nada de más.
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
  select ('01920000-0000-7000-8000-0000000111' || p_sufijo)::uuid
$$;

-- Lo de un colportor y un producto, como texto: tiene|por_entregar|entregados|por_cobrar.
create or replace function pg_temp.fila(p_camp text, p_colp text, p_prod text)
returns text language sql as $$
  select coalesce((
    select format('%s|%s|%s|%s', r.tiene, r.por_entregar, r.entregados, r.por_cobrar)
      from public.stock_por_ciudad(pg_temp.u(p_camp)) r
     where r.colportor_id = pg_temp.u(p_colp) and r.producto_id = pg_temp.u(p_prod)), 'sin fila')
$$;

-- La ciudad de un colportor, como texto («(sin ciudad)» si es null).
create or replace function pg_temp.ciudad_de(p_camp text, p_colp text)
returns text language sql as $$
  select coalesce((
    select coalesce(r.ciudad_nombre, '(sin ciudad)') || '/' || coalesce(r.departamento, 'null')
      from public.stock_por_ciudad(pg_temp.u(p_camp)) r
     where r.colportor_id = pg_temp.u(p_colp)
     limit 1), 'sin fila')
$$;

-- --- fixtures ------------------------------------------------------------------
-- Staff: a1 coordinador de Cierre y Vacía; a2 coordinador de Otra; ad admin; a0 colportor; a3 sin rol;
--        a4 coordinador con el rol vencido.
-- Colportores (campaña Cierre): b1 Alfa (zona Centro, c1)  b2 Bravo (Centro)  b3 Cruz (zona Costa, c2)
--        b4 Duarte (sin zona)  b5 Eguren (inscripción de baja el 15/09, con zona)  b7 Gómez (se inscribe
--        el 09/09 a las 15:00, zona Centro)  b8 Haedo (su zona se dio de baja)  b9 Ibarra (la ciudad de su
--        zona se dio de baja de la campaña).
--        b6 Fuentes NO está en Cierre: está en Otra.
-- Campañas: e1 Cierre (03/08/2026 a 30/09/2026, terminada, a1)  e2 Otra (a2, sin fin)  e4 Borrada (a1)
--        e5 Vacía (a1, sin colportores)
-- Ciudades: c1 «Ciudad uno q101» y c2 «Ciudad dos q101» (dos antes que uno en el orden alfabético); c3
--        «Ciudad tres q101», sacada de la campaña.
-- Productos: 91 Libro Uno  92 Libro Dos  93 Revista Uno  94 Material Uno  95 Misionero Uno
--        96 Libro Nunca (nadie lo tuvo)  97 Libro Cero (un renglón en cero)  98 Libro De Baja (dado de baja
--        del catálogo, pero b1 tiene 3)  99 Libro Baja Vacio (dado de baja y sin nada).
insert into auth.users (id, instance_id, aud, role, email, encrypted_password, confirmed_at, created_at, updated_at)
select pg_temp.u(s), '00000000-0000-0000-0000-000000000000',
       'authenticated', 'authenticated', 'stock-' || s || '@example.com', 'x', now(), now(), now()
  from unnest(array['a0','a1','a2','a3','a4','ad','b1','b2','b3','b4','b5','b6','b7','b8','b9']) s;

update public.usuario u set nombre = x.n, apellido = x.a
  from (values ('b1','Ana','Alfa'), ('b2','Beto','Bravo'), ('b3','Carla','Cruz'),
               ('b4','Diego','Duarte'), ('b5','Elena','Eguren'), ('b6','Fede','Fuentes'),
               ('b7','Gabi','Gómez'), ('b8','Hugo','Haedo'), ('b9','Iris','Ibarra')) x(s, n, a)
 where u.id = pg_temp.u(x.s);
update public.usuario set ultimo_push_at = '2026-09-20 13:00:00+00' where id = pg_temp.u('b1');

insert into public.usuario_rol (usuario_id, rol_id)
select pg_temp.u(x.s), r.id
  from (values ('a1','COORDINADOR'), ('a2','COORDINADOR'), ('ad','ADMIN'), ('a0','COLPORTOR'),
               ('b1','COLPORTOR'), ('b2','COLPORTOR'), ('b3','COLPORTOR')) x(s, codigo)
  join public.rol r on r.codigo = x.codigo;
insert into public.usuario_rol (usuario_id, rol_id, valido_desde, valido_hasta)
select pg_temp.u('a4'), r.id, now() - interval '10 days', now() - interval '1 day'
  from public.rol r where r.codigo = 'COORDINADOR';

insert into public.pais (id, nombre, iso_code) values (pg_temp.u('c0'), 'Pais stock', 'ZT');
insert into public.ciudad (id, nombre, departamento, pais_id, lat_centro, lon_centro, zoom_inicial) values
  (pg_temp.u('c1'), 'Ciudad uno q101', 'Departamento de prueba uno', pg_temp.u('c0'), -34.91, -56.18, 13),
  (pg_temp.u('c2'), 'Ciudad dos q101', 'Departamento de prueba dos', pg_temp.u('c0'), -34.91, -56.18, 13),
  (pg_temp.u('c3'), 'Ciudad tres q101', 'Departamento de prueba tres', pg_temp.u('c0'), -34.91, -56.18, 13);

insert into public.campania (id, nombre, tipo, fecha_inicio, fecha_fin, coordinador_id, deleted_at) values
  (pg_temp.u('e1'), 'Cierre',  'VERANO', '2026-08-03', '2026-09-30', pg_temp.u('a1'), null),
  (pg_temp.u('e2'), 'Otra',    'VERANO', '2026-08-03', null,         pg_temp.u('a2'), null),
  (pg_temp.u('e4'), 'Borrada', 'VERANO', '2026-08-03', '2026-09-30', pg_temp.u('a1'), now()),
  (pg_temp.u('e5'), 'Vacía',   'VERANO', '2026-08-03', null,         pg_temp.u('a1'), null);
insert into public.campania_ciudad (id, campania_id, ciudad_id) values
  (pg_temp.u('71'), pg_temp.u('e1'), pg_temp.u('c1')),
  (pg_temp.u('72'), pg_temp.u('e1'), pg_temp.u('c2')),
  (pg_temp.u('73'), pg_temp.u('e1'), pg_temp.u('c3'));

insert into public.zona (id, nombre, campania_ciudad_id, tipo_forma, color, poligono_geojson) values
  (pg_temp.u('d1'), 'Centro', pg_temp.u('71'), 'ESQUINAS', '#112233',
   '{"type":"Polygon","coordinates":[[[-56.19,-34.92],[-56.17,-34.92],[-56.17,-34.91],[-56.19,-34.91],[-56.19,-34.92]]]}'::jsonb),
  (pg_temp.u('d2'), 'Costa',  pg_temp.u('72'), 'ESQUINAS', '#445566',
   '{"type":"Polygon","coordinates":[[[-56.19,-34.90],[-56.17,-34.90],[-56.17,-34.89],[-56.19,-34.89],[-56.19,-34.90]]]}'::jsonb),
  (pg_temp.u('d3'), 'Baja',   pg_temp.u('71'), 'ESQUINAS', null,
   '{"type":"Polygon","coordinates":[[[-56.19,-34.95],[-56.17,-34.95],[-56.17,-34.94],[-56.19,-34.94],[-56.19,-34.95]]]}'::jsonb),
  (pg_temp.u('d4'), 'Tres',   pg_temp.u('73'), 'ESQUINAS', null,
   '{"type":"Polygon","coordinates":[[[-56.19,-35.00],[-56.17,-35.00],[-56.17,-34.99],[-56.19,-34.99],[-56.19,-35.00]]]}'::jsonb);

-- `created_at` explícito: un colportor cuenta desde el día en que se inscribió en la campaña.
insert into public.campania_colportor (campania_id, usuario_id, zona_id, created_at) values
  (pg_temp.u('e1'), pg_temp.u('b1'), pg_temp.u('d1'), '2026-08-01 10:00-03'),
  (pg_temp.u('e1'), pg_temp.u('b2'), pg_temp.u('d1'), '2026-08-01 10:00-03'),
  (pg_temp.u('e1'), pg_temp.u('b3'), pg_temp.u('d2'), '2026-08-01 10:00-03'),
  (pg_temp.u('e1'), pg_temp.u('b4'), null,            '2026-08-01 10:00-03'),
  (pg_temp.u('e1'), pg_temp.u('b5'), pg_temp.u('d1'), '2026-08-01 10:00-03'),
  (pg_temp.u('e1'), pg_temp.u('b7'), pg_temp.u('d1'), '2026-09-09 15:00-03'),
  (pg_temp.u('e1'), pg_temp.u('b8'), pg_temp.u('d3'), '2026-08-01 10:00-03'),
  (pg_temp.u('e1'), pg_temp.u('b9'), pg_temp.u('d4'), '2026-08-01 10:00-03'),
  (pg_temp.u('e2'), pg_temp.u('b6'), null,            '2026-08-01 10:00-03');
update public.zona set deleted_at = now() where id = pg_temp.u('d3');
update public.campania_ciudad set deleted_at = now() where id = pg_temp.u('73');
update public.campania_colportor set deleted_at = '2026-09-15 12:00:00+00'
 where campania_id = pg_temp.u('e1') and usuario_id = pg_temp.u('b5');

insert into public.producto (id, nombre, tipo, deleted_at) values
  (pg_temp.u('91'), 'Libro Uno',         'LIBRO',     null),
  (pg_temp.u('92'), 'Libro Dos',         'LIBRO',     null),
  (pg_temp.u('93'), 'Revista Uno',       'REVISTA',   null),
  (pg_temp.u('94'), 'Material Uno',      'MATERIAL',  null),
  (pg_temp.u('95'), 'Misionero Uno',     'MISIONERO', null),
  (pg_temp.u('96'), 'Libro Nunca',       'LIBRO',     null),
  (pg_temp.u('97'), 'Libro Cero',        'LIBRO',     null),
  (pg_temp.u('98'), 'Libro De Baja',     'LIBRO',     now()),
  (pg_temp.u('99'), 'Libro Baja Vacio',  'LIBRO',     now());

-- Lo que tiene cada uno (el renglón de b1 con 92 está dado de baja; b6 no está en Cierre).
insert into public.stock (usuario_id, producto_id, cantidad_disponible, deleted_at) values
  (pg_temp.u('b1'), pg_temp.u('91'), 5,  null),
  (pg_temp.u('b1'), pg_temp.u('93'), 10, null),
  (pg_temp.u('b1'), pg_temp.u('92'), 50, now()),
  (pg_temp.u('b1'), pg_temp.u('98'), 3,  null),
  (pg_temp.u('b1'), pg_temp.u('99'), 0,  null),
  (pg_temp.u('b2'), pg_temp.u('91'), 0,  null),
  (pg_temp.u('b3'), pg_temp.u('91'), 2,  null),
  (pg_temp.u('b3'), pg_temp.u('93'), -2, null),
  (pg_temp.u('b4'), pg_temp.u('92'), 4,  null),
  (pg_temp.u('b4'), pg_temp.u('97'), 0,  null),
  (pg_temp.u('b5'), pg_temp.u('92'), 7,  null),
  (pg_temp.u('b6'), pg_temp.u('91'), 99, null),
  (pg_temp.u('b8'), pg_temp.u('94'), 6,  null),
  (pg_temp.u('b8'), pg_temp.u('95'), 1,  null);

-- Donde cuelgan las ventas (las FK lo piden; la función no las mira).
insert into public.ubicacion (id, tipo, calle, numero, lat, lon, ciudad_id)
values (pg_temp.u('f1'), 'CASA', 'Calle de prueba', '1', -34.915, -56.18, pg_temp.u('c1'));
insert into public.espacio (id, ubicacion_id) values (pg_temp.u('f2'), pg_temp.u('f1'));
insert into public.espacio_persona (id, espacio_id, persona_id)
values (pg_temp.u('f3'), pg_temp.u('f2'), pg_temp.u('f4'));

-- Ventas (horas locales de Montevideo, UTC-3). Cierre va del 03/08 al 30/09.
--   b1: 10 paga completa; 11 sin cobros; 12 con un cobro parcial; 13 con un cobro ANULADO; 14 dada de baja;
--       15 con la entrega dada de baja; 16 antes de la campaña; 17 después; 18 con un cobro dado de baja.
--   b2: los bordes: 20 el primer día a las 00:00 y 21 el último a las 23:59 cuentan; 22 (02/08 23:59) y 23
--       (01/10 00:00) no.
--   b3: 30 paga; 31 sin cobros.   b4: 40.   b5: 50 antes de la baja (15/09 12:00 UTC) y 51 después.
--   b6: 60 (de Otra).   b7 (se inscribe el 09/09 15:00): 70 el 08/09 (antes: no) y 7a el 09/09 08:00 (el
--       mismo día, antes de la hora: cuenta, la regla es por día).
insert into public.venta (id, espacio_persona_id, numero_talonario, monto_total, fecha, colportor_id, deleted_at)
select pg_temp.u(x.id), pg_temp.u('f3'), 'T-' || x.id, x.m, x.f::timestamptz, pg_temp.u(x.s), x.baja
  from (values
    ('10', 'b1', '2026-09-07 09:00-03', 10000, null::timestamptz),
    ('11', 'b1', '2026-09-08 09:00-03', 20000, null),
    ('12', 'b1', '2026-09-09 09:00-03', 5000,  null),
    ('13', 'b1', '2026-09-10 09:00-03', 8000,  null),
    ('14', 'b1', '2026-09-11 09:00-03', 3000,  now()),
    ('15', 'b1', '2026-09-12 09:00-03', 3500,  null),
    ('16', 'b1', '2026-07-20 09:00-03', 1000,  null),
    ('17', 'b1', '2026-10-02 09:00-03', 1000,  null),
    ('18', 'b1', '2026-09-13 09:00-03', 4000,  null),
    ('20', 'b2', '2026-08-03 00:00-03', 1111,  null),
    ('21', 'b2', '2026-09-30 23:59-03', 2222,  null),
    ('22', 'b2', '2026-08-02 23:59-03', 999,   null),
    ('23', 'b2', '2026-10-01 00:00-03', 888,   null),
    ('30', 'b3', '2026-09-07 09:00-03', 3000,  null),
    ('31', 'b3', '2026-08-20 09:00-03', 5000,  null),
    ('40', 'b4', '2026-09-08 09:00-03', 7000,  null),
    ('50', 'b5', '2026-09-10 09:00-03', 2000,  null),
    ('51', 'b5', '2026-09-20 09:00-03', 3000,  null),
    ('60', 'b6', '2026-09-07 09:00-03', 9000,  null),
    ('70', 'b7', '2026-09-08 09:00-03', 1000,  null),
    ('7a', 'b7', '2026-09-09 08:00-03', 1000,  null)
  ) x(id, s, f, m, baja);

-- Entregas: (venta, producto, cantidad, pendiente, dada de baja). Sin los triggers de la 0118 (descuentan el stock
-- de lo entregado): acá el stock es el de arriba y las entregas son solo lo que se lee.
alter table public.entrega disable trigger entrega_descuenta_stock;
alter table public.entrega disable trigger entrega_stock_inconsistente;
insert into public.entrega (venta_id, producto_id, cantidad, pendiente, deleted_at)
select pg_temp.u(x.v), pg_temp.u(x.p), x.c, x.pend, x.baja
  from (values
    ('10', '91', 2,   false, null::timestamptz),
    ('11', '91', 3,   false, null),
    ('11', '91', 1,   true,  null),
    ('11', '92', 4,   true,  null),
    ('12', '93', 6,   false, null),
    ('13', '93', 1,   false, null),
    ('14', '91', 100, true,  null),
    ('15', '91', 100, true,  now()),
    ('16', '91', 50,  true,  null),
    ('17', '91', 60,  true,  null),
    ('18', '94', 2,   false, null),
    ('20', '91', 1,   false, null),
    ('21', '91', 2,   true,  null),
    ('22', '91', 7,   true,  null),
    ('23', '91', 8,   true,  null),
    ('30', '93', 1,   false, null),
    ('31', '91', 5,   false, null),
    ('40', '92', 2,   true,  null),
    ('50', '92', 3,   true,  null),
    ('51', '92', 9,   true,  null),
    ('60', '91', 70,  true,  null),
    ('70', '91', 5,   true,  null),
    ('7a', '91', 1,   true,  null)
  ) x(v, p, c, pend, baja);
alter table public.entrega enable trigger entrega_descuenta_stock;
alter table public.entrega enable trigger entrega_stock_inconsistente;

-- Cobros (centavos): 10 pagada justo; 12 parcial; 13 anulado; 18 dado de baja; 30 pagada.
insert into public.cobranza (venta_id, monto, medio, fecha, deleted_at, anulado_at, motivo_anulacion)
select pg_temp.u(x.v), x.m, 'EFECTIVO', x.f::timestamptz, x.baja, x.anul, case when x.anul is null then null else 'Monto equivocado' end
  from (values
    ('10', 10000, '2026-09-07 10:00-03', null::timestamptz, null::timestamptz),
    ('12', 2000,  '2026-09-09 10:00-03', null,              null),
    ('13', 8000,  '2026-09-10 10:00-03', null,              '2026-09-10 12:00+00'::timestamptz),
    ('18', 4000,  '2026-09-13 10:00-03', now(),             null),
    ('30', 3000,  '2026-09-07 10:00-03', null,              null)
  ) x(v, m, f, baja, anul);

-- Pedidos a la casa editora (un colportor, varios estados). Esperan autorización los PENDIENTE_AUTORIZACION
-- vivos: b1 uno (hay otro dado de baja, uno AUTORIZADO, uno BORRADOR y uno RECHAZADO), b2, b3, b4, b5 (de
-- baja), b8 y b6 (de Otra).
-- Todos del 10/09: dentro de la inscripción (la de b5 se da de baja el 15/09) y antes del fin de Cierre (0112).
insert into public.pedido_casa_editora (colportor_id, estado, monto_total, origen, deleted_at, motivo_rechazo, fecha_pedido)
select pg_temp.u(x.s), x.e, 1000, 'COLPORTOR', x.baja, case when x.e = 'RECHAZADO' then 'Motivo de prueba' end,
       '2026-09-10 12:00:00-03'
  from (values
    ('b1', 'PENDIENTE_AUTORIZACION', null::timestamptz),
    ('b1', 'PENDIENTE_AUTORIZACION', now()),
    ('b1', 'AUTORIZADO',             null),
    ('b1', 'BORRADOR',               null),
    ('b1', 'RECHAZADO',              null),
    ('b2', 'PENDIENTE_AUTORIZACION', null),
    ('b3', 'PENDIENTE_AUTORIZACION', null),
    ('b4', 'PENDIENTE_AUTORIZACION', null),
    ('b5', 'PENDIENTE_AUTORIZACION', null),
    ('b8', 'PENDIENTE_AUTORIZACION', null),
    ('b6', 'PENDIENTE_AUTORIZACION', null)
  ) x(s, e, baja);

-- ---------------------------------------------------------------------------
-- 1. Las funciones: forma y privilegios
-- ---------------------------------------------------------------------------
select pg_temp.actuar_como('01920000-0000-7000-8000-0000000111a1');
select is((select array(select k from jsonb_object_keys(
                  (select to_jsonb(r) from public.stock_por_ciudad(pg_temp.u('e1')) r limit 1)) k
                 order by k collate "C")),
          array['apellido','ciudad_id','ciudad_nombre','colportor_id','de_baja','departamento','devueltos','entregados',
                'nombre','por_cobrar','por_entregar','producto_id','producto_nombre','producto_tipo','tiene',
                'ultimo_dato_at'],
          'stock_por_ciudad: la forma de la respuesta, solo cantidades (sin plata, clientes, talonarios ni emails)');
select is((select array(select k from jsonb_object_keys(
                  (select to_jsonb(r) from public.pedidos_por_autorizar_por_ciudad(pg_temp.u('e1')) r limit 1)) k
                 order by k collate "C")),
          array['ciudad_id','ciudad_nombre','departamento','pedidos'],
          'pedidos_por_autorizar_por_ciudad: la forma de la respuesta, solo el número');
select pg_temp.actuar_como_servidor();

select is((select p.prosecdef from pg_proc p where p.oid = 'public.stock_por_ciudad(uuid)'::regprocedure),
          true, 'stock_por_ciudad es SECURITY DEFINER (el coordinador no lee stock, entrega ni cobranza ajenas)');
select is((select p.prosecdef from pg_proc p where p.oid = 'public.pedidos_por_autorizar_por_ciudad(uuid)'::regprocedure),
          true, 'pedidos_por_autorizar_por_ciudad es SECURITY DEFINER');
select is((select p.provolatile from pg_proc p where p.oid = 'public.stock_por_ciudad(uuid)'::regprocedure),
          'v', 'stock_por_ciudad es VOLATILE (llama a lanzar_motivo_mapa())');
select is((select p.provolatile from pg_proc p where p.oid = 'public.pedidos_por_autorizar_por_ciudad(uuid)'::regprocedure),
          'v', 'pedidos_por_autorizar_por_ciudad es VOLATILE');
select is((select p.proconfig from pg_proc p where p.oid = 'public.stock_por_ciudad(uuid)'::regprocedure),
          array['search_path=""'], 'stock_por_ciudad fija search_path vacío');
select is((select p.proconfig from pg_proc p where p.oid = 'public.pedidos_por_autorizar_por_ciudad(uuid)'::regprocedure),
          array['search_path=""'], 'pedidos_por_autorizar_por_ciudad fija search_path vacío');
select ok(has_function_privilege('authenticated', 'public.stock_por_ciudad(uuid)', 'execute')
          and has_function_privilege('authenticated', 'public.pedidos_por_autorizar_por_ciudad(uuid)', 'execute'),
          'authenticated las ejecuta');
select ok(not has_function_privilege('anon', 'public.stock_por_ciudad(uuid)', 'execute')
          and not has_function_privilege('anon', 'public.pedidos_por_autorizar_por_ciudad(uuid)', 'execute'),
          'anon NO las ejecuta');
select ok(not has_function_privilege('service_role', 'public.stock_por_ciudad(uuid)', 'execute')
          and not has_function_privilege('service_role', 'public.pedidos_por_autorizar_por_ciudad(uuid)', 'execute'),
          'service_role NO las ejecuta (sin sesión no hay permiso que comprobar)');
select is((select count(*)::int
             from pg_proc p, aclexplode(p.proacl) a
            where a.grantee = 0 and a.privilege_type = 'EXECUTE'
              and p.oid in ('public.stock_por_ciudad(uuid)'::regprocedure,
                            'public.pedidos_por_autorizar_por_ciudad(uuid)'::regprocedure)),
          0, 'no tienen EXECUTE para PUBLIC');
select is((select count(*)::int from pg_proc p
            where p.pronamespace = 'public'::regnamespace
              and p.proname in ('stock_por_ciudad', 'pedidos_por_autorizar_por_ciudad')),
          2, 'hay una sola firma de cada una');

-- ---------------------------------------------------------------------------
-- 2. Acceso: el permiso es lo primero (las dos funciones)
-- ---------------------------------------------------------------------------
select pg_temp.actuar_como_servidor();
select throws_ok($$ select * from public.stock_por_ciudad('01920000-0000-7000-8000-0000000111e1') $$,
  '42501', null, 'stock: sin JWT (el servidor) falla');
select throws_ok($$ select * from public.pedidos_por_autorizar_por_ciudad('01920000-0000-7000-8000-0000000111e1') $$,
  '42501', null, 'pedidos: sin JWT (el servidor) falla');

select pg_temp.actuar_sin_jwt();
select throws_ok($$ select * from public.stock_por_ciudad('01920000-0000-7000-8000-0000000111e1') $$,
  '42501', null, 'stock: authenticated sin sesión falla');
select throws_ok($$ select * from public.pedidos_por_autorizar_por_ciudad('01920000-0000-7000-8000-0000000111e1') $$,
  '42501', null, 'pedidos: authenticated sin sesión falla');

select pg_temp.actuar_como_servidor();
select set_config('role', 'anon', true);
select throws_ok($$ select * from public.stock_por_ciudad('01920000-0000-7000-8000-0000000111e1') $$,
  '42501', null, 'stock: anon no la llama');
select throws_ok($$ select * from public.pedidos_por_autorizar_por_ciudad('01920000-0000-7000-8000-0000000111e1') $$,
  '42501', null, 'pedidos: anon no la llama');
select pg_temp.actuar_como_servidor();

select pg_temp.actuar_como('01920000-0000-7000-8000-0000000111a0');
select throws_ok($$ select * from public.stock_por_ciudad('01920000-0000-7000-8000-0000000111e1') $$,
  '42501', null, 'stock: un colportor no la llama');
select throws_ok($$ select * from public.pedidos_por_autorizar_por_ciudad('01920000-0000-7000-8000-0000000111e1') $$,
  '42501', null, 'pedidos: un colportor no la llama');
select pg_temp.actuar_como('01920000-0000-7000-8000-0000000111b1');
select throws_ok($$ select * from public.stock_por_ciudad('01920000-0000-7000-8000-0000000111e1') $$,
  '42501', null, 'stock: un colportor inscripto en la campaña tampoco ve el de sus compañeros');
-- El permiso va antes que la existencia.
select throws_ok($$ select * from public.stock_por_ciudad('01920000-0000-7000-8000-0000000111ff') $$,
  '42501', null, 'stock: un colportor con una campaña inexistente: 42501, no CZ001');

select pg_temp.actuar_como('01920000-0000-7000-8000-0000000111a3');
select throws_ok($$ select * from public.stock_por_ciudad('01920000-0000-7000-8000-0000000111e1') $$,
  '42501', null, 'stock: un usuario sin ningún rol no la llama');
select throws_ok($$ select * from public.pedidos_por_autorizar_por_ciudad('01920000-0000-7000-8000-0000000111e1') $$,
  '42501', null, 'pedidos: un usuario sin ningún rol no la llama');
select pg_temp.actuar_como('01920000-0000-7000-8000-0000000111a4');
select throws_ok($$ select * from public.stock_por_ciudad('01920000-0000-7000-8000-0000000111e1') $$,
  '42501', null, 'stock: con el rol de coordinador vencido falla');
select throws_ok($$ select * from public.pedidos_por_autorizar_por_ciudad('01920000-0000-7000-8000-0000000111e1') $$,
  '42501', null, 'pedidos: con el rol de coordinador vencido falla');

select pg_temp.actuar_como('01920000-0000-7000-8000-0000000111a2');
select throws_ok($$ select * from public.stock_por_ciudad('01920000-0000-7000-8000-0000000111e1') $$,
  '42501', null, 'stock: el coordinador de otra campaña no ve este stock');
select throws_ok($$ select * from public.stock_por_ciudad('01920000-0000-7000-8000-0000000111e1') $$,
  '42501', 'Solo el coordinador de la campaña o un administrador puede ver su stock. Entrá con la cuenta del coordinador de esta campaña.',
  'stock: el mensaje del 42501 dice quién puede');
select throws_ok($$ select * from public.pedidos_por_autorizar_por_ciudad('01920000-0000-7000-8000-0000000111e1') $$,
  '42501', 'Solo el coordinador de la campaña o un administrador puede ver sus pedidos. Entrá con la cuenta del coordinador de esta campaña.',
  'pedidos: el coordinador de otra campaña no los ve, y el mensaje dice quién puede');
select throws_ok($$ select * from public.stock_por_ciudad('01920000-0000-7000-8000-0000000111ff') $$,
  'CZ001', null, 'stock: un coordinador con una campaña inexistente: CZ001');
select throws_ok($$ select * from public.pedidos_por_autorizar_por_ciudad('01920000-0000-7000-8000-0000000111ff') $$,
  'CZ001', null, 'pedidos: un coordinador con una campaña inexistente: CZ001');
select pg_temp.actuar_como_servidor();

-- ---------------------------------------------------------------------------
-- 3. Errores de campaña (como el coordinador de la campaña)
-- ---------------------------------------------------------------------------
select pg_temp.actuar_como('01920000-0000-7000-8000-0000000111a1');
select throws_ok($$ select * from public.stock_por_ciudad('01920000-0000-7000-8000-0000000111e4') $$,
  'CZ001', null, 'stock: una campaña dada de baja: CZ001');
select throws_ok($$ select * from public.pedidos_por_autorizar_por_ciudad('01920000-0000-7000-8000-0000000111e4') $$,
  'CZ001', null, 'pedidos: una campaña dada de baja: CZ001');
select throws_ok($$ select * from public.stock_por_ciudad(null) $$,
  'CZ001', null, 'stock: una campaña nula: CZ001');
select lives_ok($$ select * from public.stock_por_ciudad('01920000-0000-7000-8000-0000000111e1') $$,
  'stock: una campaña terminada se lee (el stock se mira al cierre)');
select is((select count(*)::int from public.stock_por_ciudad(pg_temp.u('e5'))), 0,
          'stock: una campaña sin colportores devuelve la lista vacía, no un error');
select is((select count(*)::int from public.pedidos_por_autorizar_por_ciudad(pg_temp.u('e5'))), 0,
          'pedidos: una campaña sin colportores devuelve la lista vacía');
select pg_temp.actuar_como_servidor();

-- ---------------------------------------------------------------------------
-- 4. stock_por_ciudad: filas y productos (como el coordinador de Cierre)
-- ---------------------------------------------------------------------------
select pg_temp.actuar_como('01920000-0000-7000-8000-0000000111a1');
select is((select count(*)::int from public.stock_por_ciudad(pg_temp.u('e1'))), 56,
          'ocho colportores × siete productos con movimiento');
select is((select array_agg(distinct r.producto_nombre order by r.producto_nombre)
             from public.stock_por_ciudad(pg_temp.u('e1')) r),
          array['Libro Cero','Libro De Baja','Libro Dos','Libro Uno','Material Uno','Misionero Uno','Revista Uno'],
          'los productos: los que tienen movimiento; sin el que nadie tuvo ni el de baja sin nada');
select is((select count(*)::int from public.stock_por_ciudad(pg_temp.u('e1')) r
            where r.producto_id = pg_temp.u('96')),
          0, 'un producto que nadie tuvo nunca no sale: no se agotó, nunca estuvo');
select is((select count(*)::int from public.stock_por_ciudad(pg_temp.u('e1')) r
            where r.producto_id = pg_temp.u('99')),
          0, 'un producto dado de baja y sin nada en ninguna mano no sale');
select is((select count(*)::int from public.stock_por_ciudad(pg_temp.u('e1')) r
            where r.producto_id = pg_temp.u('98')),
          8, 'uno dado de baja pero con 3 en una mano sale, para todos');
select is((select count(*)::int from public.stock_por_ciudad(pg_temp.u('e1')) r
            where r.colportor_id = pg_temp.u('b6')),
          0, 'quien no está inscripto en la campaña no sale');
select is((select array_agg(distinct r.colportor_id order by r.colportor_id) from public.stock_por_ciudad(pg_temp.u('e1')) r),
          array[pg_temp.u('b1'), pg_temp.u('b2'), pg_temp.u('b3'), pg_temp.u('b4'), pg_temp.u('b5'),
                pg_temp.u('b7'), pg_temp.u('b8'), pg_temp.u('b9')],
          'los colportores de la campaña, también el de baja y los sin ciudad');
select is((select array_agg(s.x order by s.n)
             from (select r.colportor_id::text || '/' || r.producto_nombre as x, row_number() over () as n
                     from public.stock_por_ciudad(pg_temp.u('e1')) r) s
            where s.n <= 8),
          array[pg_temp.u('b3') || '/Libro Cero', pg_temp.u('b3') || '/Libro De Baja', pg_temp.u('b3') || '/Libro Dos',
                pg_temp.u('b3') || '/Libro Uno', pg_temp.u('b3') || '/Revista Uno', pg_temp.u('b3') || '/Material Uno',
                pg_temp.u('b3') || '/Misionero Uno', pg_temp.u('b1') || '/Libro Cero'],
          'el orden: por ciudad (dos antes que uno), colportor y productos por tipo (libros, revistas, material, misioneros) y nombre');

-- ---------------------------------------------------------------------------
-- 5. Lo que tiene, lo por entregar, lo entregado y lo por cobrar (tiene|por_entregar|entregados|por_cobrar)
-- ---------------------------------------------------------------------------
select is(pg_temp.fila('e1', 'b1', '91'), '5|1|5|3',
          'b1, Libro Uno: tiene 5; 1 por entregar; entregó 2 + 3; por cobrar solo las 3 de la venta sin cobros (la de 2 está paga)');
select is(pg_temp.fila('e1', 'b1', '92'), '0|4|0|0',
          'b1, Libro Dos: su renglón de stock está dado de baja (no cuenta) y 4 por entregar');
select is(pg_temp.fila('e1', 'b1', '93'), '10|0|7|5',
          'b1, Revista: por cobrar en proporción (0137): 6 de una venta de 5000 con 2000 cobrados = ceil(6 × 3000 / 5000) = 4, y 1 de una de 8000 con el cobro anulado = 1');
select is(pg_temp.fila('e1', 'b1', '94'), '0|0|2|2',
          'b1, Material: un cobro dado de baja no cuenta: la venta sigue con saldo');
select is(pg_temp.fila('e1', 'b1', '98'), '3|0|0|0', 'b1, Libro De Baja: lo que tiene, 3');
select is(pg_temp.fila('e1', 'b1', '97'), '0|0|0|0', 'b1, Libro Cero: sin nada, en cero y no «sin fila»');
select is(pg_temp.fila('e1', 'b1', '95'), '0|0|0|0', 'b1, Misionero: sin nada');
-- Nada de lo dado de baja, ni lo de fuera de la campaña, ni la venta de otro: 91 de b1 ya lo prueba
-- (14, 15, 16 y 17 sumarían 310).
select is(pg_temp.fila('e1', 'b2', '91'), '0|2|1|1',
          'b2, Libro Uno: los bordes de la campaña: el 03/08 00:00 y el 30/09 23:59 cuentan; el 02/08 23:59 y el 01/10 00:00 no');
select is(pg_temp.fila('e1', 'b3', '91'), '2|0|5|5', 'b3, Libro Uno: tiene 2 y entregó 5 sin cobrar');
select is(pg_temp.fila('e1', 'b3', '93'), '-2|0|1|0',
          'b3, Revista: el stock negativo (entregó más de lo registrado, S46) se devuelve tal cual; la venta paga no queda por cobrar');
select is(pg_temp.fila('e1', 'b4', '92'), '4|2|0|0', 'b4, Libro Dos: tiene 4 y 2 por entregar');
select is(pg_temp.fila('e1', 'b5', '92'), '7|3|0|0',
          'b5 (inscripción de baja): lo vendido antes de la baja cuenta (3) y lo posterior (9) no; su stock sigue');
select is(pg_temp.fila('e1', 'b7', '91'), '0|1|0|0',
          'b7 (se inscribió el 09/09 15:00): la venta del 08/09 no cuenta; la del 09/09 08:00 sí, la regla es por día');
select is(pg_temp.fila('e1', 'b8', '94'), '6|0|0|0', 'b8: tiene 6 de Material');
select is(pg_temp.fila('e1', 'b8', '95'), '1|0|0|0', 'b8: tiene 1 Misionero');
select is(pg_temp.fila('e1', 'b4', '97'), '0|0|0|0', 'un renglón de stock en cero es un producto en cero, no falta');

-- ---------------------------------------------------------------------------
-- 6. Ciudad, baja y último dato
-- ---------------------------------------------------------------------------
select is(pg_temp.ciudad_de('e1', 'b1'), 'Ciudad uno q101/Departamento de prueba uno', 'b1: la ciudad y el departamento de su zona');
select is(pg_temp.ciudad_de('e1', 'b3'), 'Ciudad dos q101/Departamento de prueba dos', 'b3: la otra ciudad');
select is(pg_temp.ciudad_de('e1', 'b4'), '(sin ciudad)/null', 'b4, sin zona: sin ciudad');
select is(pg_temp.ciudad_de('e1', 'b8'), '(sin ciudad)/null', 'b8, con la zona dada de baja: sin ciudad');
select is(pg_temp.ciudad_de('e1', 'b9'), '(sin ciudad)/null', 'b9, con la ciudad de su zona sacada de la campaña: sin ciudad');
select is(pg_temp.ciudad_de('e1', 'b5'), '(sin ciudad)/null', 'b5, con la inscripción dada de baja: sin ciudad, aunque conservó la zona');
select is((select array_agg(distinct r.colportor_id order by r.colportor_id)
             from public.stock_por_ciudad(pg_temp.u('e1')) r where r.de_baja),
          array[pg_temp.u('b5')], 'de_baja: solo b5, que sigue saliendo (sus libros no desaparecen)');
select is((select count(distinct r.ciudad_id)::int from public.stock_por_ciudad(pg_temp.u('e1')) r where r.ciudad_id is not null),
          2, 'dos ciudades con colportores');
select is((select count(distinct r.colportor_id)::int from public.stock_por_ciudad(pg_temp.u('e1')) r where r.ciudad_id is null),
          4, 'cuatro colportores sin ciudad (b4, b5, b8 y b9), cada uno una sola vez');
select is((select max(r.ultimo_dato_at) from public.stock_por_ciudad(pg_temp.u('e1')) r where r.colportor_id = pg_temp.u('b1')),
          '2026-09-20 13:00:00+00'::timestamptz, 'ultimo_dato_at: cuándo llegó el último push de b1 (usuario.ultimo_push_at)');
select is((select count(*)::int from public.stock_por_ciudad(pg_temp.u('e1')) r
            where r.colportor_id = pg_temp.u('b1') and r.ultimo_dato_at is distinct from '2026-09-20 13:00:00+00'::timestamptz),
          0, 'ultimo_dato_at: el mismo valor en todas las filas del colportor');
select is((select count(*)::int from public.stock_por_ciudad(pg_temp.u('e1')) r
            where r.colportor_id = pg_temp.u('b2') and r.ultimo_dato_at is not null),
          0, 'ultimo_dato_at: null si todavía no llegó ningún push');

-- ---------------------------------------------------------------------------
-- 7. Cada campaña ve lo suyo, y el ADMIN ve cualquiera
-- ---------------------------------------------------------------------------
select pg_temp.actuar_como('01920000-0000-7000-8000-0000000111a2');
select is((select array_agg(r.colportor_id::text || '/' || r.producto_nombre || '/' || r.tiene || '/' || r.por_entregar)
             from public.stock_por_ciudad(pg_temp.u('e2')) r),
          array[pg_temp.u('b6') || '/Libro Uno/99/70'],
          'Otra: solo b6 y solo lo suyo (las ventas de Cierre no se mezclan)');
select pg_temp.actuar_como('01920000-0000-7000-8000-0000000111ad');
select is((select count(*)::int from public.stock_por_ciudad(pg_temp.u('e1'))), 56, 'el ADMIN lee cualquier campaña');
select is((select count(*)::int from public.pedidos_por_autorizar_por_ciudad(pg_temp.u('e2'))), 1, 'el ADMIN lee los pedidos de Otra');
select pg_temp.actuar_como_servidor();

-- ---------------------------------------------------------------------------
-- 8. Pedidos por autorizar por ciudad
-- ---------------------------------------------------------------------------
select pg_temp.actuar_como('01920000-0000-7000-8000-0000000111a1');
select is((select array_agg(coalesce(r.ciudad_nombre, '(sin ciudad)') || '/' || coalesce(r.departamento, 'null') || '/' || r.pedidos)
             from public.pedidos_por_autorizar_por_ciudad(pg_temp.u('e1')) r),
          array['Ciudad dos q101/Departamento de prueba dos/1',
                'Ciudad uno q101/Departamento de prueba uno/2',
                '(sin ciudad)/null/3'],
          'pedidos: por ciudad (uno de b3; b1 y b2 en la otra; b4, b5 de baja y b8 sin ciudad), solo los PENDIENTE_AUTORIZACION vivos');
select is((select count(*)::int from public.pedidos_por_autorizar_por_ciudad(pg_temp.u('e1')) r where r.pedidos < 1), 0,
          'pedidos: solo salen las ciudades que tienen al menos uno');
select pg_temp.actuar_como_servidor();
select pg_temp.actuar_como('01920000-0000-7000-8000-0000000111a2');
select is((select array_agg(coalesce(r.ciudad_nombre, '(sin ciudad)') || '/' || r.pedidos)
             from public.pedidos_por_autorizar_por_ciudad(pg_temp.u('e2')) r),
          array['(sin ciudad)/1'], 'pedidos: Otra cuenta solo el de b6, sin ciudad (no se mezcla con Cierre)');
select pg_temp.actuar_como_servidor();

select * from finish();
rollback;
