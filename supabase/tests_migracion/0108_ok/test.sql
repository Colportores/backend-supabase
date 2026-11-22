-- pgTAP · 0108 sobre los datos de antes: solo suma. La venta, sus ítems y su cobro (con su versión de sync y su
-- xmin_w) quedan idénticos, las entidades de antes también, y la tabla devolucion nace vacía y guarda una
-- devolución de una venta que ya existía. Ver scripts/db-test-migracion.sh y datos.sql.
begin;
select * from no_plan();

-- --- los datos de antes siguen --------------------------------------------------------------
select is((select count(*)::int from public.venta), 2, 'las 2 ventas siguen, también la dada de baja');
select is((select count(*)::int from public.venta v join public.prueba_0108_venta s using (id)
            where to_jsonb(v) is distinct from to_jsonb(s)), 0,
          'quedaron idénticas en todas sus columnas, sync_version y xmin_w incluidos: ni se enteran los teléfonos');
select is((select sync_version from public.venta where id = '01920000-0000-7000-8000-000000010801'), 1::bigint,
          'la corregida conserva su versión de sync');
select is((select count(*)::int from public.venta_item i join public.prueba_0108_venta_item s using (id)
            where to_jsonb(i) is distinct from to_jsonb(s)), 0, 'los 2 ítems, idénticos');
select is((select count(*)::int from public.cobranza c join public.prueba_0108_cobranza s using (id)
            where to_jsonb(c) is distinct from to_jsonb(s)), 0, 'y el cobro');

-- --- el registro de sync -----------------------------------------------------------------------
select is((select count(*)::int
             from sync.entidad e
             join public.prueba_0108_entidad s using (nombre)
            where (e.tabla::text, e.columna_pk, e.permite_push, e.columnas_servidor, e.sigue_campanias, e.columna_duenio)
                  is distinct from (s.tabla, s.columna_pk, s.permite_push, s.columnas_servidor, s.sigue_campanias, s.columna_duenio)), 0,
          'las entidades de antes quedaron idénticas');
select is((select array_agg(nombre) from sync.entidad e
            where not exists (select 1 from public.prueba_0108_entidad s where s.nombre = e.nombre)),
          array['devolucion'], 'y la única nueva es devolucion');

-- --- la tabla nueva ------------------------------------------------------------------------------
select is((select count(*)::int from public.devolucion), 0, 'nace vacía: hasta hoy ningún teléfono la sube');
select lives_ok($$ insert into public.devolucion (venta_id, productos_devueltos, monto_reembolsado, fecha_devolucion, colportor_id)
                   values ('01920000-0000-7000-8000-000000010801',
                           '[{"producto_id": "01920000-0000-7000-8000-000000010811", "cantidad": 1}]'::jsonb,
                           190000, now(), '01920000-0000-7000-8000-0000000108b1') $$,
                'y guarda una devolución de una venta que ya existía, con su reembolso');
select lives_ok($$ insert into public.devolucion (venta_id, productos_devueltos, fecha_devolucion, colportor_id)
                   values ('01920000-0000-7000-8000-000000010802',
                           '[{"producto_id": "01920000-0000-7000-8000-000000010812", "cantidad": 1}]'::jsonb,
                           now(), '01920000-0000-7000-8000-0000000108b1') $$,
                'incluso de una venta dada de baja (una devolución previa a la baja no se pierde)');
select is((select count(*)::int from public.venta v join public.prueba_0108_venta s using (id)
            where to_jsonb(v) is distinct from to_jsonb(s)), 0,
          'y la venta original sigue intacta: la devolución no la toca');

select * from finish();
rollback;
