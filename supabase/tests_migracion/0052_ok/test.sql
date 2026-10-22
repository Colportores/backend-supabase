-- pgTAP · 0052 suma usuario.ultimo_push_at en null a los usuarios de antes (nadie subió nada que el servidor
-- haya registrado) y no toca nada más: ninguna otra columna, ni la versión de sync ni el updated_at de
-- ninguna fila. Ver scripts/db-test-migracion.sh y datos.sql.
begin;
select * from no_plan();

select is((select count(*)::int from public.usuario where id::text like '01920000-0000-7000-8000-0000000052%'), 3,
          'los 3 usuarios siguen: no se perdió ninguno');
select is((select count(*)::int from public.usuario
            where id::text like '01920000-0000-7000-8000-0000000052%' and ultimo_push_at is not null), 0,
          'ninguno trae marca de push: null hasta que llegue la primera sincronización');

-- Sin tocar las filas: la columna nueva es la única diferencia con la foto.
select is((select count(*)::int from public.usuario u join public.prueba_0052_usuario s using (id)
            where to_jsonb(u) - 'ultimo_push_at' is distinct from to_jsonb(s)), 0,
          'las 3 filas quedaron idénticas (versión de sync, updated_at y xmin_w incluidos) salvo la columna nueva');

-- Lo nuevo anda sobre los datos de antes.
select lives_ok($$select sync.registrar_push_recibido()$$, 'registrar_push_recibido corre sobre la base migrada');
select set_config('request.jwt.claims',
                  json_build_object('sub', '01920000-0000-7000-8000-0000000052b1', 'role', 'authenticated')::text, true);
select set_config('request.jwt.claim.sub', '01920000-0000-7000-8000-0000000052b1', true);
select set_config('role', 'authenticated', true);
select sync.registrar_push_recibido();
select set_config('role', 'postgres', true);
select is((select ultimo_push_at = now() from public.usuario where id = '01920000-0000-7000-8000-0000000052b1'), true,
          'registrar un push de un usuario de antes le pone la marca');
select is((select count(*)::int from public.usuario
            where id::text like '01920000-0000-7000-8000-0000000052%' and ultimo_push_at is not null), 1,
          'y a nadie más');

select * from finish();
rollback;
