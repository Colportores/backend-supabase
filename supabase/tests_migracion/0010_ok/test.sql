-- pgTAP · 0010 recalcula la zona de cada ubicación viva por su posición. Ver
-- scripts/db-test-migracion.sh.
begin;
select * from no_plan();

select results_eq(
  $$ select id, zona_id from public.ubicacion where id::text like '01920000-0000-7000-8000-0000000092a%' order by id $$,
  $$ values ('01920000-0000-7000-8000-0000000092a1'::uuid, '01920000-0000-7000-8000-0000000092d1'::uuid),
            ('01920000-0000-7000-8000-0000000092a2'::uuid, '01920000-0000-7000-8000-0000000092d1'::uuid),
            ('01920000-0000-7000-8000-0000000092a3'::uuid, '01920000-0000-7000-8000-0000000092d1'::uuid),
            ('01920000-0000-7000-8000-0000000092a4'::uuid, null::uuid),
            ('01920000-0000-7000-8000-0000000092a5'::uuid, '01920000-0000-7000-8000-0000000092d1'::uuid) $$,
  'u1 igual; u2 (sin zona) y u3 (zona de una campaña terminada) pasan a Centro; u4 a null; u5 (baja) no se toca');

select results_eq(
  $$ select ubicacion_id, zona_id from public.house_status where ubicacion_id::text like '01920000-0000-7000-8000-0000000092a%' order by ubicacion_id $$,
  $$ values ('01920000-0000-7000-8000-0000000092a1'::uuid, '01920000-0000-7000-8000-0000000092d1'::uuid),
            ('01920000-0000-7000-8000-0000000092a2'::uuid, '01920000-0000-7000-8000-0000000092d1'::uuid) $$,
  'cada house_status queda con la zona de su ubicación');

select is((select count(*) from public.ubicacion where id::text like '01920000-0000-7000-8000-0000000092a%'),
          5::bigint, 'ninguna ubicación se pierde');
select is((select count(*) from public.house_status where ubicacion_id::text like '01920000-0000-7000-8000-0000000092a%'),
          2::bigint, 'ningún house_status se pierde');
select is((select sync_version from public.ubicacion where id = '01920000-0000-7000-8000-0000000092a1'), 0::bigint,
          'la que no cambia no se toca (no se republica de más)');
select is((select sync_version from public.ubicacion where id = '01920000-0000-7000-8000-0000000092a2'), 1::bigint,
          'la que cambia se actualiza (sale en el próximo delta)');

select * from finish();
rollback;
