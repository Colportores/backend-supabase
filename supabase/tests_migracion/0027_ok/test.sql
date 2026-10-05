-- pgTAP · 0027 pasa cada precio de venta a la campania_ciudad de su zona, unifica los que valen lo
-- mismo y se pisan (sin borrar ninguna fila) y no toca ni pierde nada más. Ver
-- scripts/db-test-migracion.sh y los grupos A..H de datos.sql.
begin;
select * from no_plan();

select has_column('public', 'precio_por_zona', 'campania_ciudad_id', 'el precio tiene campania_ciudad_id');
select hasnt_column('public', 'precio_por_zona', 'zona_id', 'y ya no tiene zona_id');
select col_not_null('public', 'precio_por_zona', 'campania_ciudad_id', 'campania_ciudad_id es obligatorio');

select is((select count(*)::int from public.precio_por_zona), (select count(*)::int from public.prueba_0027_precio),
          'ninguna fila se pierde: hay las mismas que antes (17)');
select is((select count(*)::int from public.precio_por_zona), 17, 'son 17');

select is((select count(*)::int from public.precio_por_zona p
            join public.prueba_0027_precio s on s.id = p.id
           where p.campania_ciudad_id is distinct from s.cc_esperada), 0,
          'cada precio quedó en la campania_ciudad de su zona (la de la zona dada de baja también)');

-- Los unificados: de baja, no borrados.
select results_eq(
  $$ select right(p.id::text, 3) from public.precio_por_zona p
      join public.prueba_0027_precio s on s.id = p.id
     where p.deleted_at is not null and s.deleted_at is null order by 1 $$,
  $$ values ('102'), ('112'), ('122'), ('123'), ('162') $$,
  'se dieron de baja solo los repetidos: a2, b2, c2, c3 y g2');
select is((select count(*)::int from public.precio_por_zona where deleted_at is null), 11,
          'quedan 11 vivos: 17 menos los 5 unificados y el que ya estaba de baja');
select ok((select deleted_at from public.precio_por_zona where id = '01920000-0000-7000-8000-00000000a151')
          is not distinct from
          (select deleted_at from public.prueba_0027_precio where id = '01920000-0000-7000-8000-00000000a151'),
          'el precio que ya estaba de baja conserva la fecha de su baja');

-- Las vigencias de los que quedan.
select results_eq(
  $$ select valido_desde, valido_hasta from public.precio_por_zona where id = '01920000-0000-7000-8000-00000000a101' $$,
  $$ values ('2026-01-01'::date, null::date) $$, 'A: a1 queda como estaba, sin fin');
select results_eq(
  $$ select valido_desde, valido_hasta from public.precio_por_zona where id = '01920000-0000-7000-8000-00000000a111' $$,
  $$ values ('2026-01-01'::date, '2026-06-30'::date) $$, 'B: b1 se estira hasta donde terminaba b2');
select results_eq(
  $$ select valido_desde, valido_hasta from public.precio_por_zona where id = '01920000-0000-7000-8000-00000000a121' $$,
  $$ values ('2026-01-01'::date, null::date) $$, 'C: c1 cubre toda la cadena, hasta el que no tenía fin');
select results_eq(
  $$ select valido_desde, valido_hasta from public.precio_por_zona where id = '01920000-0000-7000-8000-00000000a161' $$,
  $$ values ('2026-01-01'::date, null::date) $$, 'G: la colección queda en g1, sin fin');

-- Todo lo demás queda igual (importe, producto o colección, vigencia, fechas, autor, baja).
select is((select count(*)::int
             from public.precio_por_zona p
             join public.prueba_0027_precio s on s.id = p.id
            where p.id not in ('01920000-0000-7000-8000-00000000a102', '01920000-0000-7000-8000-00000000a111',
                               '01920000-0000-7000-8000-00000000a112', '01920000-0000-7000-8000-00000000a121',
                               '01920000-0000-7000-8000-00000000a122', '01920000-0000-7000-8000-00000000a123',
                               '01920000-0000-7000-8000-00000000a162')
              and (p.producto_id, p.coleccion_id, p.precio_venta, p.valido_desde, p.valido_hasta,
                   p.created_at, p.created_by, p.deleted_at)
                  is distinct from
                  (s.producto_id, s.coleccion_id, s.precio_venta, s.valido_desde, s.valido_hasta,
                   s.created_at, s.created_by, s.deleted_at)), 0,
          'los que no se unificaron no cambian en nada (D contiguos, E otra ciudad, F con baja, H importes distintos)');
select is((select count(*)::int
             from public.precio_por_zona p
             join public.prueba_0027_precio s on s.id = p.id
            where (p.producto_id, p.coleccion_id, p.precio_venta, p.created_at, p.created_by)
                  is distinct from
                  (s.producto_id, s.coleccion_id, s.precio_venta, s.created_at, s.created_by)), 0,
          'ni siquiera los unificados cambian de importe, producto o autor: solo vigencia y baja');

-- El teléfono los baja otra vez: todos subieron de versión.
select is((select count(*)::int
             from public.precio_por_zona p
             join public.prueba_0027_precio s on s.id = p.id
            where p.sync_version <= s.sync_version), 0,
          'todos los precios subieron su sync_version: el pull los vuelve a bajar con la forma nueva');

-- La regla nueva vale sobre lo migrado.
select throws_ok(
  $$ insert into public.precio_por_zona (producto_id, campania_ciudad_id, precio_venta, valido_desde)
     values ('01920000-0000-7000-8000-00000000a1a1', '01920000-0000-7000-8000-00000000a1f1', 26000, '2026-05-01') $$,
  '23P01', null, 'un precio vigente nuevo del mismo producto en esa ciudad de la campaña se rechaza');
select lives_ok(
  $$ insert into public.precio_por_zona (producto_id, campania_ciudad_id, precio_venta, valido_desde)
     values ('01920000-0000-7000-8000-00000000a1a2', '01920000-0000-7000-8000-00000000a1f1', 31000, '2026-07-01') $$,
  'y uno que empieza después de que termina el estirado (b1 termina el 30/06) se acepta');
select throws_ok(
  $$ insert into public.precio_por_zona (producto_id, campania_ciudad_id, precio_venta, valido_desde)
     values ('01920000-0000-7000-8000-00000000a1a2', '01920000-0000-7000-8000-00000000a1f1', 31000, '2026-06-15') $$,
  '23P01', null, 'pero no uno que entra en lo que b1 cubre ahora');

select results_eq(
  $$ select sigue_campanias from sync.entidad where nombre = 'precio_por_zona' $$,
  $$ values (true) $$, 'la entidad de sync sigue las campañas');
with nuevo as (
  insert into public.precio_por_zona (producto_id, campania_ciudad_id, precio_venta)
  values ('01920000-0000-7000-8000-00000000a1a4', '01920000-0000-7000-8000-00000000a1f2', 1)
  returning valido_desde
)
select is((select valido_desde from nuevo), public.hoy_montevideo(), 'un precio sin fecha toma el día de Montevideo');

select * from finish();
rollback;
