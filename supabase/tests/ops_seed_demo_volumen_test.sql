-- pgTAP · el volumen de datos de demo (supabase/seed-demo/demo-volumen.sql, backend-supabase#285)
--
-- Corre la demo base y la tanda de volumen dentro de una transacción que se deshace (ningún dato de demo queda para los
-- demás archivos) y verifica que:
--   · suma las ciudades, los colportores y las jornadas, ventas y cobros que prometen su cabecera y el issue;
--   · las cifras son coherentes con el esquema vigente (si una migración cambia una tabla o una regla y rompe el generador,
--     este test falla en CI en vez de enterarnos al correrlo contra la demo);
--   · el panel ve esos datos (Inicio y Reportes, con la cuenta del coordinador de la campaña);
--   · una segunda pasada no cambia nada (idempotente) y el retiro de la demo también da de baja esta tanda.
--
-- Requiere invocarse con cwd = raíz del repo (así lo hace scripts/db-test.sh).
begin;
select * from no_plan();

\i supabase/seed-demo/demo-datos.sql
\i supabase/seed-demo/demo-volumen.sql

-- Qué suma
select is((select count(*) from public.campania_ciudad where campania_id = '5eed0000-0000-7000-8003-000000000001' and id::text like '5eed0000-0000-7000-8109-%'),
          150::bigint, '150 ciudades más en la campaña de verano');
select is((select count(*) from public.zona where id::text like '5eed0000-0000-7000-8104-%'), 300::bigint, 'dos zonas por ciudad');
select cmp_ok((select count(*) from public.precio_por_ciudad where id::text like '5eed0000-0000-7000-8123-%'), '>', 0::bigint, 'hay ciudades con precios propios');
select is((select count(*) from public.usuario where id::text like '5eed0000-0000-7000-8100-%'), 54::bigint, '54 colportores nuevos');
select is((select count(*) from public.campania_colportor where id::text like '5eed0000-0000-7000-810b-%'), 54::bigint, 'cada uno inscripto');
select is((select count(*) from (select z.campania_ciudad_id from public.campania_colportor cc join public.zona z on z.id = cc.zona_id
                                  where cc.id::text like '5eed0000-0000-7000-810b-%' group by 1 having count(*) = 3) t),
          18::bigint, 'tres colportores en cada una de las 18 primeras ciudades');
select cmp_ok((select count(*) from public.jornada where id::text like '5eed0000-0000-7000-810f-%'), '>', 800::bigint, 'jornadas de seis semanas');
select cmp_ok((select count(*) from public.venta where id::text like '5eed0000-0000-7000-810a-%'), '>', 800::bigint, 'ventas');
select cmp_ok((select count(*) from public.cobranza where id::text like '5eed0000-0000-7000-810d-%'), '>', 800::bigint, 'cobros');
select is((select count(distinct v.fecha::date) / 7 from public.visita v where v.id::text like '5eed0000-0000-7000-810e-%'), 6::bigint,
          'la actividad cubre seis semanas');

-- Coherencia de plata y de agenda de trabajo
select is((select count(*) from public.venta v
            where v.id::text like '5eed0000-0000-7000-810a-%'
              and v.monto_total <> (select coalesce(sum(i.subtotal), 0) from public.venta_item i where i.venta_id = v.id)),
          0::bigint, 'el total de cada venta es la suma de sus renglones');
select is((select count(*) from public.venta v
            where v.id::text like '5eed0000-0000-7000-810a-%'
              and (select coalesce(sum(c.monto), 0) from public.cobranza c where c.venta_id = v.id and c.anulado_at is null) > v.monto_total),
          0::bigint, 'ninguna venta está cobrada de más');
select cmp_ok((select count(*) from public.venta v
                where v.id::text like '5eed0000-0000-7000-810a-%'
                  and (select coalesce(sum(c.monto), 0) from public.cobranza c where c.venta_id = v.id and c.anulado_at is null) < v.monto_total),
               '>', 0::bigint, 'hay clientes con saldo por cobrar');
select is((select count(*) from public.jornada j
            where j.id::text like '5eed0000-0000-7000-810f-%'
              and j.total_visitas <> (select count(*) from public.visita v where v.jornada_id = j.id)), 0::bigint,
          'el total de visitas de cada jornada cierra con sus visitas');
select is((select count(*) from public.cuenta_colportor cu where cu.id::text like '5eed0000-0000-7000-8115-%'
            and cu.dinero_en_mano <> public.efectivo_en_mano(cu.usuario_id)), 0::bigint,
          'el «en mano» de cada cuenta es el efectivo_en_mano() del servidor');
select is((select count(*) from public.campania_colportor_zona_historial h
            join public.campania_colportor cc on cc.id = h.campania_colportor_id
           where cc.id::text like '5eed0000-0000-7000-810b-%' and h.deleted_at is null
             and h.desde > cc.created_at), 0::bigint,
          'el tramo de zona empieza el día del alta, no el de la carga');

-- El panel ve estos datos: Reportes (horas y ventas por ciudad) e Inicio, con la cuenta del coordinador de la campaña
select set_config('request.jwt.claim.sub', '5eed0000-0000-7000-8000-000000000000', true),
       set_config('request.jwt.claims', '{"sub":"5eed0000-0000-7000-8000-000000000000","role":"authenticated"}', true);
select cmp_ok((select count(*) from public.horas_por_ciudad_y_colportor('5eed0000-0000-7000-8003-000000000001', date '2026-09-14', date '2026-11-17', 'semana', null, null)
                where colportor_id::text like '5eed0000-0000-7000-8100-%'),
               '>', 100::bigint, 'Reportes: horas por ciudad y colportor con volumen');
select cmp_ok((select count(*) from public.ventas_por_ciudad_y_colportor('5eed0000-0000-7000-8003-000000000001', date '2026-09-14', date '2026-11-17', 'semana', null, null)
                where colportor_id::text like '5eed0000-0000-7000-8100-%'),
               '>', 100::bigint, 'Reportes: ventas por ciudad y colportor con volumen');
select cmp_ok(jsonb_array_length(public.tablero_de_inicio('5eed0000-0000-7000-8003-000000000001', date '2026-11-17') -> 'ciudades'),
               '>=', 150, 'Inicio: la lista de ciudades trae las de la tanda');
select cmp_ok((public.tablero_de_inicio('5eed0000-0000-7000-8003-000000000001', date '2026-11-17') -> 'total' ->> 'cantidad_colportores')::int,
               '>=', 54, 'Inicio: cuenta a los colportores nuevos');
select set_config('request.jwt.claim.sub', '', true), set_config('request.jwt.claims', '', true);

-- Idempotente: la segunda pasada no cambia nada
create temp table antes as
  select (select count(*) from public.campania_ciudad) ciudades, (select count(*) from public.usuario) usuarios,
         (select count(*) from public.jornada) jornadas, (select count(*) from public.venta) ventas,
         (select count(*) from public.cobranza) cobros, (select count(*) from public.ciudad) catalogo;
\i supabase/seed-demo/demo-volumen.sql
select results_eq(
  $$ select (select count(*) from public.campania_ciudad), (select count(*) from public.usuario),
            (select count(*) from public.jornada), (select count(*) from public.venta),
            (select count(*) from public.cobranza), (select count(*) from public.ciudad) $$,
  $$ select ciudades, usuarios, jornadas, ventas, cobros, catalogo from antes $$,
  'una segunda pasada no duplica nada');

-- El retiro de la demo da de baja también esta tanda
select set_config('retiro.aplicar', 'si', true);
\i supabase/seed-demo/retirar-demo-datos.sql
select is((select count(*) from public.venta where id::text like '5eed0000-0000-7000-810a-%' and deleted_at is null), 0::bigint,
          'el retiro da de baja las ventas de la tanda');
select is((select count(*) from public.usuario where id::text like '5eed0000-0000-7000-8100-%' and deleted_at is null), 0::bigint,
          'el retiro da de baja a los colportores de la tanda');
select is((select count(*) from public.campania_ciudad where id::text like '5eed0000-0000-7000-8109-%' and deleted_at is null), 0::bigint,
          'el retiro da de baja las ciudades de campaña de la tanda');
select is((select count(*) from public.zona where id::text like '5eed0000-0000-7000-8104-%' and deleted_at is null), 0::bigint,
          'el retiro da de baja las zonas de la tanda');
select is((select count(*) from public.ciudad where id::text not like '5eed0000-0000-7000-8%' and deleted_at is not null), 0::bigint,
          'el retiro no toca el catálogo de ciudades (solo las de la demo base)');

select * from finish();
rollback;
