-- pgTAP · las listas largas de la demo (supabase/seed-demo/demo-listas.sql, backend-supabase#289)
--   1. Sin la tanda de volumen no carga nada (y avisa).
--   2. Con la base, el coordinador, el volumen y colportor.demo: suma el catálogo, las cuentas sueltas, los barrios, los
--      depósitos, pedidos, transferencias y acompañamientos de los colportores del volumen y la historia de colportor.demo.
--   3. Cada lista desplazable del panel y de la app llega a 26 registros (supabase/seed-demo/chequeo-listas-demo.sql, que
--      corre cada RPC con la sesión de la cuenta de la demo) y las cifras son coherentes con el esquema vigente (efectivo
--      en mano, deuda con la casa, stock): si una migración cambia una regla y rompe el generador, este test falla en CI.
--   4. Una segunda pasada no cambia nada, y el retiro de la demo también da de baja esta tanda.
-- Va en una transacción que se deshace. Requiere invocarse con cwd = raíz del repo (así lo hace scripts/db-test.sh).
begin;
select * from no_plan();

create or replace function pg_temp.u(p text) returns uuid language sql as $$
  select ('01920000-0000-7000-8000-0000000289' || p)::uuid;
$$;

-- La cuenta de coordinador.demo (la crea Auth en el proyecto real; el seed no la crea) y la base de la demo.
insert into auth.users (id, instance_id, aud, role, email, encrypted_password, confirmed_at, created_at, updated_at)
values (pg_temp.u('a1'), '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'coordinador.demo@example.com', 'x', now(), now(), now());
insert into public.usuario_rol (usuario_id, rol_id) select pg_temp.u('a1'), r.id from public.rol r where r.codigo = 'COORDINADOR';

\o /dev/null
\i supabase/seed-demo/demo-datos.sql
\o

-- 1. Sin el volumen, la tanda se detiene y no deja nada (la guarda lanza una excepción: se prueba dentro de un savepoint)
savepoint sin_volumen;
\set ON_ERROR_STOP off
\o /dev/null
\i supabase/seed-demo/demo-listas.sql
\o
\set ON_ERROR_STOP on
rollback to savepoint sin_volumen;
select is((select count(*) from public.producto where id = '5eed0000-0000-7000-8005-00000000000c'), 0::bigint, 'sin el volumen no carga ningún producto');

\o /dev/null
\i supabase/seed-demo/sumar-coordinador-demo.sql
\i supabase/seed-demo/demo-volumen.sql
\i supabase/seed-demo/demo-listas.sql
\o

-- 1b. Primera pasada SIN colportor.demo (todavía no corrió --colportor): carga lo común y se queda a la espera de su historia
select is((select count(*) from public.producto where id::text like '5eed0000-0000-7000-8005-%'), 27::bigint, 'primera pasada sin colportor.demo: el catálogo ya está');
select is((select count(*) from public.pedido_casa_editora where id::text like '5eed0000-0000-7000-8210-%'), (54 * 4)::bigint, 'primera pasada sin colportor.demo: solo los pedidos de los del volumen');
select is((select count(*) from public.agenda where id::text like '5eed0000-0000-7000-821a-%'), 0::bigint, 'primera pasada sin colportor.demo: no hay agenda suya todavía');

-- Aparece colportor.demo (la crea Auth), corre --colportor y se repite --listas: se le carga solo su historia, sin repetir lo común
insert into auth.users (id, instance_id, aud, role, email, encrypted_password, confirmed_at, created_at, updated_at)
values (pg_temp.u('a2'), '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'colportor.demo@example.com', 'x', now(), now(), now());
insert into public.usuario_rol (usuario_id, rol_id) select pg_temp.u('a2'), r.id from public.rol r where r.codigo = 'COLPORTOR';
create temp table antes_comun as
  select (select count(*) from public.producto) productos, (select count(*) from public.usuario where id::text like '5eed0000-0000-7000-8200-%') sueltas,
         (select count(*) from public.deposito where colportor_id::text like '5eed0000-0000-7000-8100-%') depositos_volumen,
         (select count(*) from public.transferencia_stock) transferencias;
\o /dev/null
\i supabase/seed-demo/sumar-colportor-demo.sql
\i supabase/seed-demo/demo-listas.sql
\o
select results_eq(
  $$ select (select count(*) from public.producto), (select count(*) from public.usuario where id::text like '5eed0000-0000-7000-8200-%'),
            (select count(*) from public.deposito where colportor_id::text like '5eed0000-0000-7000-8100-%'), (select count(*) from public.transferencia_stock) $$,
  $$ select productos, sueltas, depositos_volumen, transferencias from antes_comun $$,
  'la segunda pasada, con colportor.demo lista, no repite lo común');
select cmp_ok((select count(*) from public.agenda where colportor_id = pg_temp.u('a2')), '>', 100::bigint, 'la segunda pasada le carga la historia a colportor.demo');

-- 2. Qué suma
select is((select count(*) from public.producto where id::text like '5eed0000-0000-7000-8005-%'), 27::bigint, '27 productos en el catálogo de la demo (16 más)');
select is((select count(*) from public.precio_general pg where pg.producto_id::text like '5eed0000-0000-7000-8005-%' and pg.deleted_at is null), 27::bigint, 'cada producto tiene su precio general (el misionero, en cero)');
select is((select count(*) from public.usuario where id::text like '5eed0000-0000-7000-8200-%'), 54::bigint, '24 coordinadores y 30 colportores sin campaña');
select is((select count(*) from public.usuario_rol ur join public.rol r on r.id = ur.rol_id
            where ur.usuario_id::text like '5eed0000-0000-7000-8200-%' and ur.deleted_at is null and r.codigo = 'COORDINADOR'), 24::bigint, '24 con rol de coordinador');
select is((select count(*) from public.zona where id::text like '5eed0000-0000-7000-8204-%'), 26::bigint, '26 barrios de Montevideo');
select cmp_ok((select count(*) from public.deposito where id::text like '5eed0000-0000-7000-821b-%'), '>', 200::bigint, 'depósitos de los colportores del volumen y de colportor.demo');
select cmp_ok((select count(*) from public.deposito where id::text like '5eed0000-0000-7000-821b-%' and destino = 'RETIRO_COORDINADOR'), '>', 80::bigint, 'hay retiros del coordinador');
select cmp_ok((select count(*) from public.ticket where id::text like '5eed0000-0000-7000-821c-%' and estado = 'PENDIENTE'), '>', 25::bigint, 'hay tickets por validar');
select is((select count(*) from public.pedido_casa_editora where id::text like '5eed0000-0000-7000-8210-%'), (54 * 4 + 49)::bigint, 'cuatro pedidos por colportor del volumen y 49 de colportor.demo');
select is((select count(*) from public.transferencia_stock where id::text like '5eed0000-0000-7000-821d-%'), 108::bigint, 'seis transferencias por cada trío de colportores');
select cmp_ok((select count(*) from public.jornada_acompaniante where id::text like '5eed0000-0000-7000-8221-%'), '>', 300::bigint, 'acompañamientos del coordinador');
select is((select count(*) from public.venta where id::text like '5eed0000-0000-7000-820a-%' and motivo_monto_manual is not null), 40::bigint, '40 ventas con monto acordado y motivo');
select cmp_ok((select count(*) from public.venta v where v.id::text like '5eed0000-0000-7000-820a-%'), '>', 90::bigint, 'ventas de colportor.demo y con monto acordado');

-- Coherencia con el esquema vigente
select is((select count(*) from public.venta v
            where v.id::text like '5eed0000-0000-7000-82%'
              and v.monto_total <> (select coalesce(sum(i.subtotal), 0) from public.venta_item i where i.venta_id = v.id)
              and v.motivo_monto_manual is null), 0::bigint, 'el total de cada venta nueva sin motivo es la suma de sus renglones');
select is((select count(*) from public.venta v
            where v.id::text like '5eed0000-0000-7000-82%'
              and (select coalesce(sum(c.monto), 0) from public.cobranza c where c.venta_id = v.id and c.anulado_at is null) > v.monto_total),
          0::bigint, 'ninguna venta nueva está cobrada de más');
select is((select count(*) from public.jornada j where j.colportor_id in (select id from public.usuario where id::text like '5eed0000-0000-7000-8100-%' or id = pg_temp.u('a2'))
            and j.total_visitas <> (select count(*) from public.visita v where v.jornada_id = j.id)), 0::bigint,
          'el total de visitas de cada jornada cierra con sus visitas');
select is((select count(*) from public.cuenta_colportor cu
            where (cu.id::text like '5eed0000-0000-7000-8115-%' or cu.usuario_id = pg_temp.u('a2')) and cu.dinero_en_mano <> public.efectivo_en_mano(cu.usuario_id)),
          0::bigint, 'el «en mano» de cada cuenta es el efectivo_en_mano() del servidor');
select is((select count(*) from public.cuenta_colportor cu
            where cu.id::text like '5eed0000-0000-7000-8115-%'
              and cu.deuda_total <> (select coalesce(sum(coalesce(p.monto_autorizado, p.monto_total)), 0) from public.pedido_casa_editora p
                                      where p.colportor_id = cu.usuario_id and p.deleted_at is null and p.estado in ('AUTORIZADO', 'DESPACHADO', 'RECIBIDO'))
                                    - (select coalesce(sum(dp.monto), 0) from public.deposito dp
                                        where dp.colportor_id = cu.usuario_id and dp.deleted_at is null and dp.concepto = 'CASA_EDITORA' and dp.validado_en is not null)
                                    + (select coalesce(sum(tr.monto_deuda), 0) from public.transferencia_stock tr
                                        where tr.destino_id = cu.usuario_id and tr.deleted_at is null and tr.estado = 'AUTORIZADO')
                                    - (select coalesce(sum(tr.monto_deuda), 0) from public.transferencia_stock tr
                                        where tr.origen_id = cu.usuario_id and tr.deleted_at is null and tr.estado = 'AUTORIZADO')),
          0::bigint, 'la deuda de cada cuenta del volumen cierra con sus pedidos, depósitos y transferencias');
select is((select count(*) from public.stock s
            where s.id::text like '5eed0000-0000-7000-8219-%'
              and (s.cantidad_disponible < 0
                   or s.cantidad_disponible <> (select coalesce(sum(case when m.tipo like 'ENTRADA%' or m.tipo = 'AJUSTE_ENTRADA' then m.cantidad else -m.cantidad end), 0)
                                                  from public.movimiento_stock m
                                                 where m.usuario_id = s.usuario_id and m.producto_id = s.producto_id and m.deleted_at is null))),
          0::bigint, 'el stock de cada colportor del volumen cierra con sus movimientos y no queda negativo');
select is((select count(*) from public.entrega e where e.id::text like '5eed0000-0000-7000-820c-%' and e.stock_inconsistente), 0::bigint, 'ninguna entrega de colportor.demo quedó con stock inconsistente');
select ok(coalesce((select cu.deuda_total >= 0 from public.cuenta_colportor cu where cu.usuario_id = pg_temp.u('a2') and cu.deleted_at is null), false), 'la cuenta de colportor.demo existe y no queda con deuda negativa');

-- 3. Cada lista llega a 26 (corre las RPC y las tablas con la sesión de coordinador.demo y de colportor.demo)
\o /dev/null
\i supabase/seed-demo/chequeo-listas-demo.sql
\o
select cmp_ok((select count(*) from chequeo_listas_demo where ok), '>=', 50::bigint, 'se midieron al menos 50 listas que llegan al mínimo');
select is((select count(*) from chequeo_listas_demo where ok is false
             and (public.hoy_montevideo() <= date '2027-03-13' or fuente not in ('buscar_candidatos', 'zonas_asignables', 'ciudades_del_catalogo'))),
          0::bigint, 'ninguna lista del panel ni de la app se queda corta (' || coalesce((select string_agg(lista || ': ' || filas, ' · ') from chequeo_listas_demo where ok is false), 'sin faltantes') || ')');
select is((select count(*) from chequeo_listas_demo where filas = -1
             and (public.hoy_montevideo() <= date '2027-03-13' or fuente not in ('buscar_candidatos', 'zonas_asignables', 'ciudades_del_catalogo'))),
          0::bigint, 'ninguna RPC de las listas falló');
select is((select count(*) from chequeo_listas_demo where ok is null), 2::bigint, 'dos listas no se pueden sembrar desde la nube (personas y avisos)');

-- 4. Idempotente
create temp table antes as
  select (select count(*) from public.producto) productos, (select count(*) from public.usuario) usuarios, (select count(*) from public.deposito) depositos,
         (select count(*) from public.pedido_casa_editora) pedidos, (select count(*) from public.venta) ventas, (select count(*) from public.agenda) agenda,
         (select count(*) from public.zona) zonas;
\o /dev/null
\i supabase/seed-demo/demo-listas.sql
\o
select results_eq(
  $$ select (select count(*) from public.producto), (select count(*) from public.usuario), (select count(*) from public.deposito),
            (select count(*) from public.pedido_casa_editora), (select count(*) from public.venta), (select count(*) from public.agenda),
            (select count(*) from public.zona) $$,
  $$ select productos, usuarios, depositos, pedidos, ventas, agenda, zonas from antes $$,
  'una segunda pasada no agrega nada');

-- El retiro de la demo también da de baja esta tanda
select set_config('retiro.aplicar', 'si', true);
\o /dev/null
\i supabase/seed-demo/retirar-demo-datos.sql
\o
select is((select count(*) from public.venta where id::text like '5eed0000-0000-7000-820a-%' and deleted_at is null), 0::bigint, 'el retiro da de baja las ventas de la tanda');
select is((select count(*) from public.pedido_casa_editora where id::text like '5eed0000-0000-7000-8210-%' and deleted_at is null), 0::bigint, 'el retiro da de baja los pedidos de la tanda');
select is((select count(*) from public.transferencia_stock where id::text like '5eed0000-0000-7000-821d-%' and deleted_at is null), 0::bigint, 'el retiro da de baja las transferencias');
select is((select count(*) from public.jornada_acompaniante where id::text like '5eed0000-0000-7000-8221-%' and deleted_at is null), 0::bigint, 'el retiro da de baja los acompañamientos');
select is((select count(*) from public.zona where id::text like '5eed0000-0000-7000-8204-%' and deleted_at is null), 0::bigint, 'el retiro da de baja los barrios');
select is((select count(*) from public.producto where id::text like '5eed0000-0000-7000-8005-%' and deleted_at is null), 0::bigint, 'el retiro da de baja los productos de la demo');
select is((select count(*) from public.usuario where id::text like '5eed0000-0000-7000-8200-%' and deleted_at is null), 0::bigint, 'el retiro da de baja las cuentas sueltas');
select is((select count(*) from public.deposito where id::text like '5eed0000-0000-7000-821b-%' and deleted_at is null),
          (select count(*) from public.deposito where id::text like '5eed0000-0000-7000-821b-%' and (validado_en is not null or rechazado_en is not null)),
          'quedan vivos solo los depósitos validados y los retiros rechazados (no se pueden dar de baja)');
select is((select count(*) from public.usuario where id in (pg_temp.u('a1'), pg_temp.u('a2')) and deleted_at is null), 2::bigint, 'coordinador.demo y colportor.demo siguen vivas');

select * from finish();
rollback;
