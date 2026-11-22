-- pgTAP · supabase/seed-demo/sumar-colportor-demo.sql: colportor.demo queda inscripta en la campaña de la demo con su ciudad, su zona,
-- su stock y dos semanas de actividad (backend-supabase#286).
--   1. Sin la cuenta colportor.demo, o sin la demo base cargada, no hace nada ni falla (la base local y CI no las tienen).
--   2. Con ambas: la inscribe en la campaña de verano, zona Pocitos, con el alta el 14/09 (no el día de la carga) y el primer tramo
--      de zona desde ese día; le deja stock y actividad coherentes; la app (mis_zonas, mis_campania_ciudades) ve su ciudad.
--   3. Correrlo dos veces no agrega nada.
--   4. El retiro de la demo da de baja la actividad de esta carga y deja viva la cuenta (no es de la demo generada).
-- Va en una transacción que se deshace. Requiere invocarse con cwd = raíz del repo (así lo hace scripts/db-test.sh).
begin;
select * from no_plan();

create or replace function pg_temp.u(p text) returns uuid language sql as $$
  select ('01920000-0000-7000-8000-0000000286' || p)::uuid;
$$;

-- 1. Sin colportor.demo y sin la demo base: no hace nada
\o /dev/null
\i supabase/seed-demo/sumar-colportor-demo.sql
\o
select is((select count(*) from public.campania_colportor), 0::bigint, 'sin colportor.demo no inscribe a nadie');

-- Con la cuenta pero sin la demo base: tampoco
insert into auth.users (id, instance_id, aud, role, email, encrypted_password, confirmed_at, created_at, updated_at)
values (pg_temp.u('a1'), '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
        'colportor.demo@example.com', 'x', now(), now(), now());
insert into public.usuario_rol (usuario_id, rol_id) select pg_temp.u('a1'), r.id from public.rol r where r.codigo = 'COLPORTOR';
\o /dev/null
\i supabase/seed-demo/sumar-colportor-demo.sql
\o
select is((select count(*) from public.campania_colportor where usuario_id = pg_temp.u('a1')), 0::bigint, 'sin la demo base no inscribe a nadie');

-- 2. Con ambas. La cuenta de saldo que ya tenía (viva) se respeta y se le suma lo cobrado.
delete from public.cuenta_colportor where usuario_id = pg_temp.u('a1');
insert into public.cuenta_colportor (usuario_id, deuda_total, dinero_depositado, dinero_en_mano, dinero_por_cobrar)
values (pg_temp.u('a1'), 1000, 2000, 5000, 700);
\o /dev/null
\i supabase/seed-demo/demo-datos.sql
\i supabase/seed-demo/sumar-colportor-demo.sql
\o
select is((select count(*) from public.campania_colportor cc
            where cc.usuario_id = pg_temp.u('a1') and cc.deleted_at is null and cc.campania_id = '5eed0000-0000-7000-8003-000000000001'
              and cc.zona_id = '5eed0000-0000-7000-8004-000000000001'),
          1::bigint, 'colportor.demo está inscripta en la campaña de verano, zona Pocitos');
select is((select ci.nombre from public.campania_colportor cc
             join public.zona z on z.id = cc.zona_id
             join public.campania_ciudad c2 on c2.id = z.campania_ciudad_id
             join public.ciudad ci on ci.id = c2.ciudad_id
            where cc.usuario_id = pg_temp.u('a1')), 'Montevideo', 'su ciudad es Montevideo');
select is((select cc.created_at from public.campania_colportor cc where cc.usuario_id = pg_temp.u('a1')),
          date '2026-09-14'::timestamp at time zone 'America/Montevideo', 'el alta es el primer día, no el de la carga');
select is((select count(*) from public.campania_colportor_zona_historial h
             join public.campania_colportor cc on cc.id = h.campania_colportor_id
            where cc.usuario_id = pg_temp.u('a1') and h.deleted_at is null and h.desde = cc.created_at),
          1::bigint, 'el primer tramo de zona empieza el día del alta');
select is((select count(*) from public.stock s where s.usuario_id = pg_temp.u('a1') and s.deleted_at is null and s.cantidad_disponible >= 12),
          10::bigint, 'tiene stock de los diez productos de la demo');
select is((select count(*) from public.movimiento_stock m where m.usuario_id = pg_temp.u('a1') and m.tipo = 'AJUSTE_ENTRADA' and m.motivo = 'STOCK_INICIAL'),
          10::bigint, 'el stock sale de ajustes STOCK_INICIAL, como los que registra la app');
select cmp_ok((select count(*) from public.jornada j where j.colportor_id = pg_temp.u('a1')), '>=', 10::bigint, 'jornadas de dos semanas');
select cmp_ok((select count(*) from public.venta v where v.colportor_id = pg_temp.u('a1')), '>', 0::bigint, 'ventas');
select is((select count(*) from public.venta v
            where v.colportor_id = pg_temp.u('a1')
              and v.monto_total <> (select coalesce(sum(i.subtotal), 0) from public.venta_item i where i.venta_id = v.id)),
          0::bigint, 'el total de cada venta es la suma de sus renglones');
select is((select count(*) from public.venta v
            where v.colportor_id = pg_temp.u('a1')
              and (select coalesce(sum(c.monto), 0) from public.cobranza c where c.venta_id = v.id and c.anulado_at is null) > v.monto_total),
          0::bigint, 'ninguna venta está cobrada de más');
select is((select count(*) from public.jornada j
            where j.colportor_id = pg_temp.u('a1')
              and j.total_visitas <> (select count(*) from public.visita v where v.jornada_id = j.id)), 0::bigint,
          'el total de visitas de cada jornada cierra con sus visitas');
select is((select cu.dinero_en_mano from public.cuenta_colportor cu where cu.usuario_id = pg_temp.u('a1')),
          5000 + public.efectivo_en_mano(pg_temp.u('a1')), 'a su cuenta de antes se le suma el efectivo cobrado (efectivo_en_mano() del servidor)');
select is((select cu.deuda_total || '/' || cu.dinero_depositado from public.cuenta_colportor cu where cu.usuario_id = pg_temp.u('a1')),
          '1000/2000', 'lo demás de su cuenta no cambia');
select is((select count(*) from public.cuenta_colportor cu where cu.usuario_id = pg_temp.u('a1')), 1::bigint, 'sigue con una sola cuenta');
select is((select count(*) from public.jornada j where j.colportor_id = pg_temp.u('a1') and j.id::text not like '5eed0000-0000-7000-8%'), 0::bigint,
          'todo lo cargado lleva el prefijo de la demo');

-- Lo que baja a su teléfono: su zona y las ciudades de su campaña
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', pg_temp.u('a1'), 'role', 'authenticated')::text, true),
       set_config('request.jwt.claim.sub', pg_temp.u('a1')::text, true),
       set_config('request.jwt.claim.role', 'authenticated', true);
select cmp_ok((select count(*) from public.mis_campania_ciudades()), '>=', 3::bigint, 'la app ve las ciudades de la campaña');
select cmp_ok((select count(*) from public.zona z where z.campania_ciudad_id in (select public.mis_campania_ciudades())), '>', 0::bigint, 'la app ve sus zonas');
reset role;
-- Sin sesión de nuevo: lo que sigue corre como el servidor (un cobro con sesión de colportor no se da de baja, CB007)
select set_config('request.jwt.claims', '', true), set_config('request.jwt.claim.sub', '', true), set_config('request.jwt.claim.role', '', true);

-- 3. Idempotente
create temp table antes as
  select (select count(*) from public.jornada) jornadas, (select count(*) from public.venta) ventas, (select count(*) from public.cobranza) cobros,
         (select count(*) from public.movimiento_stock) movs, (select count(*) from public.campania_colportor) insc;
\o /dev/null
\i supabase/seed-demo/sumar-colportor-demo.sql
\o
select results_eq(
  $$ select (select count(*) from public.jornada), (select count(*) from public.venta), (select count(*) from public.cobranza),
            (select count(*) from public.movimiento_stock), (select count(*) from public.campania_colportor) $$,
  $$ select jornadas, ventas, cobros, movs, insc from antes $$,
  'una segunda corrida no agrega nada');

-- 4. El retiro de la demo
select set_config('retiro.aplicar', 'si', true);
\o /dev/null
\i supabase/seed-demo/retirar-demo-datos.sql
\o
select is((select count(*) from public.venta v where v.colportor_id = pg_temp.u('a1') and v.deleted_at is null), 0::bigint,
          'el retiro da de baja las ventas de colportor.demo');
select is((select count(*) from public.jornada j where j.colportor_id = pg_temp.u('a1') and j.deleted_at is null), 0::bigint,
          'el retiro da de baja sus jornadas');
select is((select count(*) from public.usuario where id = pg_temp.u('a1') and deleted_at is null), 1::bigint,
          'colportor.demo sigue viva: no es un usuario de la demo generada');

select * from finish();
rollback;
