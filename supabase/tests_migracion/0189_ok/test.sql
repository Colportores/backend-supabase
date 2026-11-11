-- pgTAP · 0189 sobre los datos de antes: las fichas pasan a solo dígitos (también la dada de baja), la que ya estaba en
-- dígitos no se toca, la cuenta sin ficha sigue sin ficha y el CHECK nuevo quedó. Ver scripts/db-test-migracion.sh.
begin;
select * from no_plan();

select is(
  (select string_agg(right(f.usuario_id::text, 2) || '=' || f.cedula, ' ' order by f.usuario_id)
     from public.ficha_administrativa f),
  'd1=45678901 d2=1234567 d3=12345678 d4=1234567',
  'cada ficha quedó en solo dígitos'
);
select is((select count(*)::int from public.ficha_administrativa), (select count(*)::int from public.prueba_0189_ficha),
          'no se pierde ni se suma ninguna ficha');
select is((select count(*)::int from public.ficha_administrativa where usuario_id = '01920000-0000-7000-8000-0000000189d5'), 0,
          'la cuenta sin cédula sigue sin ficha');
select is((select count(*)::int from public.ficha_administrativa f join public.prueba_0189_ficha p using (id)
            where to_jsonb(f) is distinct from to_jsonb(p)), 3,
          'solo cambiaron las tres que no estaban en dígitos');
select ok((select f.deleted_at is not null from public.ficha_administrativa f
            where f.usuario_id = '01920000-0000-7000-8000-0000000189d4'),
          'la dada de baja sigue dada de baja');
select ok(exists (select 1 from pg_constraint where conname = 'ficha_administrativa_cedula_7_u_8_digitos'),
          'el CHECK de 7 u 8 dígitos quedó');

select * from finish();
rollback;
