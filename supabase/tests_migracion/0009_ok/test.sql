-- pgTAP · 0009 pasa cada zona directa a la inscripción. Ver scripts/db-test-migracion.sh.
begin;
select * from no_plan();

select hasnt_column('public', 'usuario', 'zona_id', 'usuario.zona_id ya no existe');

select results_eq(
  $$ select usuario_id, zona_id from public.campania_colportor order by usuario_id $$,
  $$ values ('01920000-0000-7000-8000-0000000090a1'::uuid, '01920000-0000-7000-8000-0000000090d1'::uuid),
            ('01920000-0000-7000-8000-0000000090a2'::uuid, '01920000-0000-7000-8000-0000000090d2'::uuid),
            ('01920000-0000-7000-8000-0000000090a3'::uuid, '01920000-0000-7000-8000-0000000090d1'::uuid),
            ('01920000-0000-7000-8000-0000000090a4'::uuid, '01920000-0000-7000-8000-0000000090d3'::uuid) $$,
  'la zona directa pasa a la inscripción sin zona (a1, y a4 aunque esté dado de baja); la que ya la tenía (a2) y la que no tenía zona directa (a3) quedan igual');

select is((select count(*) from public.campania_colportor), 4::bigint, 'ninguna inscripción se pierde ni se agrega');
select is((select count(*) from public.usuario where id::text like '01920000-0000-7000-8000-0000000090a%'),
          4::bigint, 'ningún usuario se pierde');

select * from finish();
rollback;
