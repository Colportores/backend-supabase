-- pgTAP · 0104 sobre los datos de antes (descripción vacía): la migración pasa, `espacio` pierde la
-- columna y nada más cambia: ni una fila, ni su versión de sync. Ver scripts/db-test-migracion.sh y datos.sql.
begin;
select * from no_plan();

select ok(not exists (select 1 from information_schema.columns
                       where table_schema = 'public' and table_name = 'espacio' and column_name = 'descripcion'),
          'espacio ya no tiene la columna descripcion');
select is((select array_agg(column_name::text order by column_name)
             from information_schema.columns
            where table_schema = 'public' and table_name = 'espacio'
              and column_name in ('id', 'ubicacion_id', 'numero_depto', 'piso')),
          array['id', 'numero_depto', 'piso', 'ubicacion_id'],
          'y conserva id, ubicacion_id, numero_depto y piso');

-- Nada se pierde ni se toca.
select is((select count(*)::int from public.espacio), 4, 'los 4 espacios siguen, también el dado de baja');
select is((select count(*)::int from public.espacio e join public.prueba_0104_espacio s using (id)
            where to_jsonb(e) is distinct from to_jsonb(s) - 'descripcion'), 0,
          'los espacios quedaron idénticos (versión de sync, updated_at y xmin_w incluidos) salvo la columna que se fue');
select is((select count(*)::int from public.espacio where sync_version <> 0), 0,
          'ninguno subió de versión de sync: ningún teléfono baja nada de nuevo');

-- Y se sigue cargando un depto.
insert into public.espacio (id, ubicacion_id, numero_depto, piso) values
  ('01920000-0000-7000-8000-0000000104b5', '01920000-0000-7000-8000-0000000104a1', '6E', '6');
select is((select numero_depto from public.espacio where id = '01920000-0000-7000-8000-0000000104b5'), '6E',
          'un depto nuevo se carga sin descripcion');
select throws_ok($$ insert into public.espacio (id, ubicacion_id, descripcion)
                    values ('01920000-0000-7000-8000-0000000104b6', '01920000-0000-7000-8000-0000000104a1', 'x') $$,
                 '42703', null, 'y un texto en descripcion ya no entra: la columna no existe');

select * from finish();
rollback;
