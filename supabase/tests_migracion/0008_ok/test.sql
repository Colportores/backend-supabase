-- pgTAP · 0008 migra los datos de datos.sql sin perder nada. Ver scripts/db-test-migracion.sh.
begin;
select * from no_plan();

select results_eq(
  $$ select campania_id, ciudad_id from public.campania_ciudad order by campania_id, ciudad_id $$,
  $$ values ('01920000-0000-7000-8000-0000000080e1'::uuid, '01920000-0000-7000-8000-0000000080c1'::uuid),
            ('01920000-0000-7000-8000-0000000080e1'::uuid, '01920000-0000-7000-8000-0000000080c2'::uuid),
            ('01920000-0000-7000-8000-0000000080e2'::uuid, '01920000-0000-7000-8000-0000000080c2'::uuid) $$,
  'cada campaña queda con la fila de su ciudad, y Verano con una más por la zona de Las Piedras');

select results_eq(
  $$ select z.id, cc.campania_id, cc.ciudad_id from public.zona z
       join public.campania_ciudad cc on cc.id = z.campania_ciudad_id order by z.id $$,
  $$ values ('01920000-0000-7000-8000-0000000080d1'::uuid, '01920000-0000-7000-8000-0000000080e1'::uuid, '01920000-0000-7000-8000-0000000080c1'::uuid),
            ('01920000-0000-7000-8000-0000000080d2'::uuid, '01920000-0000-7000-8000-0000000080e1'::uuid, '01920000-0000-7000-8000-0000000080c2'::uuid),
            ('01920000-0000-7000-8000-0000000080d3'::uuid, '01920000-0000-7000-8000-0000000080e1'::uuid, '01920000-0000-7000-8000-0000000080c1'::uuid),
            ('01920000-0000-7000-8000-0000000080d4'::uuid, '01920000-0000-7000-8000-0000000080e2'::uuid, '01920000-0000-7000-8000-0000000080c2'::uuid) $$,
  'cada zona queda en la fila de su (campaña, ciudad)');

select is((select count(*) from public.zona), 4::bigint, 'ninguna zona se pierde');
select is((select count(*) from public.zona where tipo_forma = 'ESQUINAS'), 4::bigint, 'todas pasan a ESQUINAS');
select is((select poligono_geojson from public.zona where id = '01920000-0000-7000-8000-0000000080d1'),
          '{"type":"Polygon","coordinates":[[[-56.17,-34.91],[-56.16,-34.91],[-56.16,-34.90],[-56.17,-34.90],[-56.17,-34.91]]]}'::jsonb,
          'el polígono queda intacto');
select results_eq(
  $$ select orden, lat, lon from public.zona_vertice
      where zona_id = '01920000-0000-7000-8000-0000000080d1' order by orden $$,
  $$ values (1, -34.91::float8, -56.17::float8), (2, -34.91::float8, -56.16::float8),
            (3, -34.90::float8, -56.16::float8), (4, -34.90::float8, -56.17::float8) $$,
  'los puntos del borde pasan a ser las esquinas, en orden y sin el de cierre');
select is((select count(*) from public.zona_vertice where zona_id = '01920000-0000-7000-8000-0000000080d2'),
          3::bigint, 'el triángulo queda con 3 esquinas');
select is((select count(*) from public.zona_vertice
            where zona_id = '01920000-0000-7000-8000-0000000080d3' and deleted_at is not null),
          4::bigint, 'las esquinas de la zona dada de baja quedan de baja');
select ok((select deleted_at is not null from public.zona where id = '01920000-0000-7000-8000-0000000080d3'),
          'la zona dada de baja sigue dada de baja');
select is((select sync_version from public.zona where id = '01920000-0000-7000-8000-0000000080d1'), 1::bigint,
          'las zonas migradas suben de versión: salen en el próximo delta');

select is((select count(*) from public.campania), 2::bigint, 'ninguna campaña se pierde');
select ok((select deleted_at is not null from public.campania where id = '01920000-0000-7000-8000-0000000080e2'),
          'la campaña dada de baja sigue dada de baja');
select is((select count(*) from public.precio_por_zona where zona_id = '01920000-0000-7000-8000-0000000080d1'),
          1::bigint, 'el precio de la zona sigue');
select is((select zona_id from public.usuario where id = '01920000-0000-7000-8000-0000000080a1'),
          '01920000-0000-7000-8000-0000000080d1'::uuid, 'usuario.zona_id sigue (lo migra #23)');
select is((select zona_id from public.campania_colportor where usuario_id = '01920000-0000-7000-8000-0000000080a1'),
          '01920000-0000-7000-8000-0000000080d1'::uuid, 'la inscripción conserva su zona');

select * from finish();
rollback;
