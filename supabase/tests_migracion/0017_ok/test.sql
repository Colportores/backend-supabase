-- pgTAP · 0017 sin duplicados vivos: se aplica y no toca ninguna fila. Ver
-- scripts/db-test-migracion.sh.
begin;
select * from no_plan();

select results_eq(
  $$ select id, deleted_at is null, sync_version from public.ubicacion where id::text like '01920000-0000-7000-8000-0000000096a%' order by id $$,
  $$ values ('01920000-0000-7000-8000-0000000096a1'::uuid, true, 0::bigint),  ('01920000-0000-7000-8000-0000000096a3'::uuid, true, 0::bigint),
            ('01920000-0000-7000-8000-0000000096a4'::uuid, true, 0::bigint),  ('01920000-0000-7000-8000-0000000096a6'::uuid, true, 0::bigint),
            ('01920000-0000-7000-8000-0000000096a7'::uuid, true, 0::bigint),  ('01920000-0000-7000-8000-0000000096a8'::uuid, true, 0::bigint),
            ('01920000-0000-7000-8000-0000000096a9'::uuid, true, 0::bigint),  ('01920000-0000-7000-8000-0000000096aa'::uuid, false, 0::bigint),
            ('01920000-0000-7000-8000-0000000096ab'::uuid, true, 0::bigint),  ('01920000-0000-7000-8000-0000000096ac'::uuid, true, 0::bigint),
            ('01920000-0000-7000-8000-0000000096ad'::uuid, true, 0::bigint) $$,
  'ninguna ubicación cambia: ni bajas ni versión nueva');
select is((select deleted_at from public.ubicacion where id = '01920000-0000-7000-8000-0000000096aa'),
          '2026-09-10'::timestamptz, 'la que ya estaba de baja no se toca');
select results_eq(
  $$ select id, ubicacion_id, deleted_at is null from public.espacio where id::text like '01920000-0000-7000-8000-0000000096b%' order by id $$,
  $$ values ('01920000-0000-7000-8000-0000000096b4'::uuid, '01920000-0000-7000-8000-0000000096a4'::uuid, true) $$,
  'los espacios no se mueven ni se borran');

select throws_ok(
  $$ insert into public.ubicacion (tipo, calle, numero, lat, lon, ciudad_id)
     values ('CASA', 'Av. Itália', '100', -34.90, -56.2001, '01920000-0000-7000-8000-0000000096c1') $$,
  '23505', null, 'después de la migración la regla ya corre: otra Av. Italia 100 a ~9 m de a1 choca');
select lives_ok(
  $$ update public.ubicacion set deleted_at = now() where id = '01920000-0000-7000-8000-0000000096a1' $$,
  'dar de baja a1 pasa');
select throws_ok(
  $$ update public.ubicacion set deleted_at = null where id = '01920000-0000-7000-8000-0000000096aa' $$,
  '23505', null, 'y reactivar aa choca con ab (~1 m)');

select * from finish();
rollback;
