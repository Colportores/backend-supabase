-- pgTAP · 0011 saca ubicacion.zona_id y house_status.zona_id sin tocar nada más, y nadie deja de
-- ver lo que veía. Ver scripts/db-test-migracion.sh.
begin;
select * from no_plan();

create or replace function pg_temp.actuar_como(p_uid uuid) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', json_build_object('sub', p_uid, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', p_uid::text, true);
  perform set_config('role', 'authenticated', true);
end $$;

select ok((select zona_id from public.prueba_0011_ubicacion where id = '01920000-0000-7000-8000-0000000094a1')
            = '01920000-0000-7000-8000-0000000094d1',
          'antes: u1 tenía la zona Centro (0010)');

select hasnt_column('public', 'ubicacion', 'zona_id', 'ubicacion.zona_id ya no existe');
select hasnt_column('public', 'house_status', 'zona_id', 'house_status.zona_id ya no existe');

select results_eq(
  $$ select id, tipo, calle, numero, lat, lon, ciudad_id, created_at, updated_at, created_by, deleted_at,
            sync_version, xmin_w::text from public.ubicacion order by id $$,
  $$ select id, tipo, calle, numero, lat, lon, ciudad_id, created_at, updated_at, created_by, deleted_at,
            sync_version, xmin_w from public.prueba_0011_ubicacion order by id $$,
  'ninguna ubicación se pierde ni cambia (tampoco su sync_version ni su xmin_w), la baja incluida');
select results_eq(
  $$ select ubicacion_id, lat, lon, tipo_ubicacion, color, prioridad, created_at, updated_at, created_by, deleted_at,
            sync_version, xmin_w::text from public.house_status order by ubicacion_id $$,
  $$ select * from public.prueba_0011_house_status order by ubicacion_id $$,
  'ningún house_status se pierde ni cambia');
select results_eq(
  $$ select id, ubicacion_id, sync_version, xmin_w::text from public.espacio order by id $$,
  $$ select * from public.prueba_0011_espacio order by id $$,
  'los espacios quedan igual');
select results_eq(
  $$ select id, espacio_persona_id, monto_total, sync_version from public.venta order by id $$,
  $$ select * from public.prueba_0011_venta order by id $$,
  'la venta queda igual');

-- Nadie deja de ver lo que veía. b1 veía por su zona u1 y la baja u3: las sigue viendo (y ahora
-- también u2, de su ciudad), y su pull de «zona» baja lo mismo que antes.
select pg_temp.actuar_como('01920000-0000-7000-8000-0000000094b1');
select results_eq(
  $$ select id from public.ubicacion order by id $$,
  $$ values ('01920000-0000-7000-8000-0000000094a1'::uuid), ('01920000-0000-7000-8000-0000000094a2'::uuid),
            ('01920000-0000-7000-8000-0000000094a3'::uuid) $$,
  'b1 ve las casas de su ciudad, entre ellas las de su zona');
select is(
  (select array_agg(e ->> 'id' order by e ->> 'id')
     from jsonb_array_elements(sync.pull(array['ubicacion'], '{}'::jsonb, 1000) -> 'rows' -> 'ubicacion') e),
  array['01920000-0000-7000-8000-0000000094a1', '01920000-0000-7000-8000-0000000094a3'],
  'su pull de «zona» baja las de Centro, la baja incluida: lo mismo que antes');

-- Un watermark de antes de 0011 (sin huella) arranca de cero una vez, aunque esté al día.
select is(
  (select jsonb_array_length(sync.pull(array['ubicacion'],
     jsonb_build_object('ubicacion', jsonb_build_object(
       'xid', (select max(xmin_w::text::bigint) from public.ubicacion)::text,
       'id', 'ffffffff-ffff-ffff-ffff-ffffffffffff')), 1000) -> 'rows' -> 'ubicacion')),
  2,
  'un watermark sin huella baja completa el área (u1 y u3)');

select pg_temp.actuar_como('01920000-0000-7000-8000-0000000094b2');
select is(
  (select coalesce(jsonb_array_length(sync.pull(array['ubicacion'], '{}'::jsonb, 1000) -> 'rows' -> 'ubicacion'), 0)),
  0,
  'b2, sin zona y sin casas propias, no baja nada con «zona»');
select is(
  (select array_agg(e ->> 'id' order by e ->> 'id')
     from jsonb_array_elements(sync.pull(array['ubicacion'], '{}'::jsonb, 1000, null, 'ciudad') -> 'rows' -> 'ubicacion') e),
  array['01920000-0000-7000-8000-0000000094a1', '01920000-0000-7000-8000-0000000094a2',
        '01920000-0000-7000-8000-0000000094a3'],
  'y con «ciudad» baja las de Montevideo, no las de Canelones');

select * from finish();
rollback;
