-- pgTAP · 0133 sobre los datos de antes: la nota y el origen pasan a jornada_acompaniamiento sin perder ninguno,
-- las jornadas no cambian (salvo las dos columnas que se van), ni su versión de sync, y el colportor no lee lo que
-- se movió. Ver scripts/db-test-migracion.sh y datos.sql.
begin;
select * from no_plan();

-- Nada se pierde en la jornada.
select is((select count(*)::int from public.jornada), 5, 'las 5 jornadas siguen');
select is((select count(*)::int from public.jornada j join public.prueba_0133_jornada s using (id)
            where to_jsonb(j) is distinct from to_jsonb(s) - 'acompaniamiento_origen' - 'acompaniamiento_nota'), 0,
          'las jornadas quedaron idénticas (versión de sync, updated_at, xmin_w y quién cargó incluidos) salvo las dos columnas que se fueron');
select is((select count(*)::int from pg_attribute where attrelid = 'public.jornada'::regclass and not attisdropped
              and attname in ('acompaniamiento_origen', 'acompaniamiento_nota')), 0,
          'y esas dos columnas ya no están');
select is((select sync_version from public.jornada where id = '01920000-0000-7000-8000-000000013301'), 1::bigint,
          'la jornada corregida conserva su versión de sync: ningún teléfono re-sube nada');

-- Se movió todo lo que había, con su origen y su nota.
select is((select count(*)::int from public.jornada_acompaniamiento), 3,
          'tres filas: las tres jornadas que tenían origen (la de antes de la 0100 y la libre quedan sin fila)');
select is((select string_agg(format('%s|%s|%s', right(jornada_id::text, 2), origen, coalesce(nota, 'null')), ';' order by jornada_id)
             from public.jornada_acompaniamiento),
          '01|COORDINADOR|Le costó arrancar; mejoró a la tarde;02|COLPORTOR|null;04|COORDINADOR|null',
          'cada una con su origen y su nota, tal como estaban');
select is((select count(*)::int from public.jornada_acompaniamiento where jornada_id in
            ('01920000-0000-7000-8000-000000013303', '01920000-0000-7000-8000-000000013305')), 0,
          'la acompañada de antes de la 0100 (origen desconocido) no se inventa, y la libre no tiene nada');

-- El colportor dueño de las jornadas no lee nada de lo que se movió.
select set_config('request.jwt.claims', json_build_object('sub', '01920000-0000-7000-8000-0000000133b1', 'role', 'authenticated')::text, true);
select set_config('request.jwt.claim.sub', '01920000-0000-7000-8000-0000000133b1', true);
select set_config('request.jwt.claim.role', 'authenticated', true);
select set_config('role', 'authenticated', true);
select is((select count(*)::int from public.jornada_acompaniamiento), 0, 'Ana no lee ninguna fila de la tabla nueva');
select is((select count(*)::int from public.jornada), 5, 'y sigue leyendo sus 5 jornadas');

-- El coordinador de la campaña sí, y el panel lo ve igual que antes.
select set_config('request.jwt.claims', json_build_object('sub', '01920000-0000-7000-8000-0000000133a1', 'role', 'authenticated')::text, true);
select set_config('request.jwt.claim.sub', '01920000-0000-7000-8000-0000000133a1', true);
select is((select count(*)::int from public.jornada_acompaniamiento), 3, 'Mariela lee las tres filas');
select is((select string_agg(format('%s|%s|%s', r.acompaniante_nombre, coalesce(r.acompaniamiento_origen, 'null'),
                                    coalesce(r.acompaniamiento_nota, 'null')), ';' order by r.dia, r.jornada_id)
             from public.historial_de_acompaniamientos('01920000-0000-7000-8000-0000000133e1') r),
          'Mariela|COORDINADOR|Le costó arrancar; mejoró a la tarde;Beto|COLPORTOR|null;Mariela|null|null;Beto|COORDINADOR|null',
          'el historial devuelve lo mismo que antes de la 0133 (el origen de cada una no cambia)');
select is((select r.acompaniamiento_nota from public.jornadas_cerradas_de_colportor('01920000-0000-7000-8000-0000000133e1',
              '01920000-0000-7000-8000-0000000133b1') r where r.jornada_id = '01920000-0000-7000-8000-000000013301'),
          'Le costó arrancar; mejoró a la tarde', 'y las jornadas cerradas, también');

select set_config('role', 'postgres', true);
select * from finish();
rollback;
