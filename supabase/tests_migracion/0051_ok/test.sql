-- pgTAP · 0051 toca una vez a las B de las uniones ya registradas (para que los teléfonos que ya las bajaron
-- reciban la marca por delta) sin cambiar ningún valor, y no toca nada más: ni A, ni una ubicación sin
-- unión, ni una baja común, ni el registro. Ver scripts/db-test-migracion.sh y datos.sql.
begin;
select * from no_plan();

select is((select count(*)::int from public.ubicacion), 4, 'las 4 ubicaciones siguen: no se perdió ninguna');

-- B (e2): la única que cambia, y solo su versión.
select is((select sync_version from public.ubicacion where id = '01920000-0000-7000-8000-0000000051e2'),
          (select sync_version + 1 from public.prueba_0051_ubicacion where id = '01920000-0000-7000-8000-0000000051e2'),
          'la B de la unión sube su versión de sync una vez');
select ok((select u.xmin_w <> s.xmin_w from public.ubicacion u join public.prueba_0051_ubicacion s using (id)
            where id = '01920000-0000-7000-8000-0000000051e2'),
          'y su xmin_w avanza: el delta la lleva a los teléfonos que ya la tenían');
select is((select to_jsonb(u) - 'sync_version' - 'xmin_w' - 'updated_at'
             from public.ubicacion u where id = '01920000-0000-7000-8000-0000000051e2'),
          (select to_jsonb(s) - 'sync_version' - 'xmin_w' - 'updated_at'
             from public.prueba_0051_ubicacion s where id = '01920000-0000-7000-8000-0000000051e2'),
          'sin cambiar ninguna columna más (la baja incluida)');

-- Todo lo demás, idéntico.
select is((select count(*)::int from public.ubicacion u join public.prueba_0051_ubicacion s using (id)
            where u.id <> '01920000-0000-7000-8000-0000000051e2' and to_jsonb(u) is distinct from to_jsonb(s)), 0,
          'las otras 3 (A, la sin unión y la baja común) quedaron idénticas, versión y xmin_w incluidos');
select is((select count(*)::int from public.ubicacion_union u join public.prueba_0051_union s using (id)
            where to_jsonb(u) is distinct from to_jsonb(s)), 0, 'el registro de la unión, idéntico');
select is((select count(*)::int from public.ubicacion_union), 1, 'y sin uniones nuevas');

-- Lo nuevo anda sobre los datos de antes.
select is(public.ubicacion_unida_a('01920000-0000-7000-8000-0000000051e2'),
          '01920000-0000-7000-8000-0000000051e1'::uuid, 'ubicacion_unida_a dice a cuál se unió la B de antes');
select is(public.ubicacion_unida_a('01920000-0000-7000-8000-0000000051e4'), null,
          'y de la baja común, null');
select throws_ok($$update public.ubicacion set deleted_at = null where id = '01920000-0000-7000-8000-0000000051e2'$$,
                 'UB005', 'Esta ubicación se unió a otra y no se puede reactivar.',
                 'la B de una unión de antes no se reactiva');
select lives_ok($$update public.ubicacion set deleted_at = null where id = '01920000-0000-7000-8000-0000000051e4'$$,
                'y la baja común sí');

select * from finish();
rollback;
