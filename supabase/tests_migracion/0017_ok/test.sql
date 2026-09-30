-- pgTAP · 0017 da de baja los duplicados vivos que no tienen nada colgado. Ver
-- scripts/db-test-migracion.sh.
begin;
select * from no_plan();

select results_eq(
  $$ select id, deleted_at is null from public.ubicacion where id::text like '01920000-0000-7000-8000-0000000096a%' order by id $$,
  $$ values ('01920000-0000-7000-8000-0000000096a1'::uuid, true),  ('01920000-0000-7000-8000-0000000096a2'::uuid, false),
            ('01920000-0000-7000-8000-0000000096a3'::uuid, true),  ('01920000-0000-7000-8000-0000000096a4'::uuid, true),
            ('01920000-0000-7000-8000-0000000096a5'::uuid, false), ('01920000-0000-7000-8000-0000000096a6'::uuid, true),
            ('01920000-0000-7000-8000-0000000096a7'::uuid, true),  ('01920000-0000-7000-8000-0000000096a8'::uuid, true),
            ('01920000-0000-7000-8000-0000000096a9'::uuid, true),  ('01920000-0000-7000-8000-0000000096aa'::uuid, false),
            ('01920000-0000-7000-8000-0000000096ab'::uuid, true),  ('01920000-0000-7000-8000-0000000096ac'::uuid, true),
            ('01920000-0000-7000-8000-0000000096ad'::uuid, true),  ('01920000-0000-7000-8000-0000000096ae'::uuid, false),
            ('01920000-0000-7000-8000-0000000096af'::uuid, true) $$,
  'de baja solo a2, a5 y ae (duplicadas sin nada colgado); aa ya estaba de baja');

select is((select count(*) from public.ubicacion where id::text like '01920000-0000-7000-8000-0000000096a%'), 15::bigint,
          'no se borra ninguna ubicación');
select is((select deleted_at from public.ubicacion where id = '01920000-0000-7000-8000-0000000096aa'),
          '2026-09-10'::timestamptz, 'la que ya estaba de baja no se toca');
select results_eq(
  $$ select id, sync_version from public.ubicacion
      where id in ('01920000-0000-7000-8000-0000000096a1', '01920000-0000-7000-8000-0000000096a2',
                   '01920000-0000-7000-8000-0000000096a3', '01920000-0000-7000-8000-0000000096a5',
                   '01920000-0000-7000-8000-0000000096ae', '01920000-0000-7000-8000-0000000096af') order by id $$,
  $$ values ('01920000-0000-7000-8000-0000000096a1'::uuid, 0::bigint), ('01920000-0000-7000-8000-0000000096a2'::uuid, 1::bigint),
            ('01920000-0000-7000-8000-0000000096a3'::uuid, 0::bigint), ('01920000-0000-7000-8000-0000000096a5'::uuid, 1::bigint),
            ('01920000-0000-7000-8000-0000000096ae'::uuid, 1::bigint), ('01920000-0000-7000-8000-0000000096af'::uuid, 0::bigint) $$,
  'las bajas salen en el próximo delta (sync_version + 1); las que se quedan no se tocan');
select results_eq(
  $$ select id, ubicacion_id, deleted_at is null from public.espacio where id::text like '01920000-0000-7000-8000-0000000096b%' order by id $$,
  $$ values ('01920000-0000-7000-8000-0000000096b4'::uuid, '01920000-0000-7000-8000-0000000096a4'::uuid, true),
            ('01920000-0000-7000-8000-0000000096b5'::uuid, '01920000-0000-7000-8000-0000000096a5'::uuid, true) $$,
  'los espacios no se mueven ni se borran');

select throws_ok(
  $$ insert into public.ubicacion (tipo, calle, numero, lat, lon, ciudad_id)
     values ('CASA', 'Av. Itália', '100', -34.90, -56.2001, '01920000-0000-7000-8000-0000000096c1') $$,
  '23505', null, 'después de la migración la regla ya corre: otra Av. Italia 100 a ~9 m de a1 choca');
select lives_ok(
  $$ update public.ubicacion set deleted_at = now() where id = '01920000-0000-7000-8000-0000000096a1' $$,
  'dar de baja a1 pasa');
select throws_ok(
  $$ update public.ubicacion set deleted_at = null where id = '01920000-0000-7000-8000-0000000096a2' $$,
  '23505', null, 'y reactivar a2 choca con a3 (~96 m)');

select * from finish();
rollback;
