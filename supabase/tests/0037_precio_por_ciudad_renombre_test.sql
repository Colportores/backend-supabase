-- pgTAP · migración 0030 (backend-supabase#71, decisión de Cristian del 06/10, «Nombre tabla»): la tabla
-- del precio de venta se llama precio_por_ciudad (antes precio_por_zona) y NINGÚN objeto de la base
-- arrastra el nombre viejo: ni la tabla, ni sus restricciones, índices, triggers y políticas, ni la
-- entidad de sync. Esta prueba mira la base ya migrada, sin datos; que el renombre conserve los datos
-- y las definiciones lo prueba supabase/tests_migracion/0030_ok (con datos, a través de la migración).
-- Las políticas, las restricciones y el pull se prueban con su comportamiento en 0033 y 0034.
begin;
select * from no_plan();

-- --- la tabla ------------------------------------------------------------------------
select has_table('public', 'precio_por_ciudad', 'existe public.precio_por_ciudad');
select hasnt_table('public', 'precio_por_zona', 'y ya no existe public.precio_por_zona');
select ok((select c.relrowsecurity from pg_class c where c.oid = 'public.precio_por_ciudad'::regclass),
          'la RLS sigue prendida');

-- --- nada con el nombre viejo ----------------------------------------------------------
select is((select count(*)::int from pg_class c join pg_namespace n on n.oid = c.relnamespace
            where n.nspname in ('public', 'sync') and c.relname like '%precio\_por\_zona%'),
          0, 'ninguna tabla, índice ni secuencia lleva precio_por_zona en el nombre');
select is((select count(*)::int from pg_constraint where conname like '%precio\_por\_zona%'),
          0, 'ninguna restricción');
select is((select count(*)::int from pg_trigger where tgname like '%precio\_por\_zona%'),
          0, 'ningún trigger');
select is((select count(*)::int from pg_policy where polname like '%precio\_por\_zona%'),
          0, 'ninguna política');
select is((select count(*)::int from sync.entidad where nombre like '%precio\_por\_zona%' or tabla::text like '%precio\_por\_zona%'),
          0, 'ninguna entidad de sync');
select is((select count(*)::int from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname in ('public', 'sync') and p.prosrc like '%precio\_por\_zona%'),
          0, 'ninguna función de public ni de sync nombra la tabla vieja');
select is((select count(*)::int from pg_description d where d.description like '%precio\_por\_zona%'
              and d.objoid <> 'public.precio_por_ciudad'::regclass),
          0, 'ningún comentario de otro objeto la nombra como si fuera la de hoy');

-- --- los nombres nuevos --------------------------------------------------------------------
select set_eq(
  $$ select conname::text from pg_constraint where conrelid = 'public.precio_por_ciudad'::regclass $$,
  array['precio_por_ciudad_pkey', 'precio_por_ciudad_producto_id_fkey', 'precio_por_ciudad_coleccion_id_fkey',
        'precio_por_ciudad_created_by_fkey', 'precio_por_ciudad_campania_ciudad_id_fkey',
        'precio_por_ciudad_precio_venta_check', 'precio_por_ciudad_check', 'precio_por_ciudad_check1',
        'precio_por_ciudad_producto_sin_solape', 'precio_por_ciudad_coleccion_sin_solape'],
  'las 10 restricciones: clave, 4 FK, 3 checks y las 2 de no solapamiento, con el nombre nuevo');
select indexes_are('public', 'precio_por_ciudad',
  array['precio_por_ciudad_pkey', 'precio_por_ciudad_producto_idx', 'precio_por_ciudad_delta_idx',
        'precio_por_ciudad_campania_ciudad_idx', 'precio_por_ciudad_producto_sin_solape',
        'precio_por_ciudad_coleccion_sin_solape'],
  'los 6 índices (3 de restricciones y 3 sueltos) con el nombre nuevo');
select triggers_are('public', 'precio_por_ciudad',
  array['precio_por_ciudad_auditoria_insert', 'precio_por_ciudad_auditoria_update'],
  'los dos triggers de auditoría');
select policies_are('public', 'precio_por_ciudad',
  array['precio_por_ciudad_select', 'precio_por_ciudad_insert_staff', 'precio_por_ciudad_update_staff'],
  'las tres políticas (sin DELETE: la baja es lógica)');

-- Lo que el nombre nuevo no cambia: la forma de 0027.
select has_column('public', 'precio_por_ciudad', 'campania_ciudad_id', 'sigue colgando de la campania_ciudad');
select hasnt_column('public', 'precio_por_ciudad', 'zona_id', 'sin zona_id');
select hasnt_column('public', 'precio_por_ciudad', 'ciudad_id',
                    'y sin un precio general ni columna nueva: esa decisión espera a Cristian');
select col_is_pk('public', 'precio_por_ciudad', 'id', 'la clave primaria sigue siendo id');

-- --- sync -----------------------------------------------------------------------------------
select results_eq(
  $$ select nombre, tabla::text, columna_pk, permite_push, sigue_campanias
       from sync.entidad where nombre = 'precio_por_ciudad' $$,
  $$ values ('precio_por_ciudad'::text, 'precio_por_ciudad'::text, 'id'::text, false, true) $$,
  'la entidad de sync: precio_por_ciudad, de solo bajada y siguiendo las campañas del usuario');
-- Sin ubicacion_par_decidido, que suma 0032 (después del renombre).
select is((select count(*)::int from sync.entidad where nombre <> 'ubicacion_par_decidido'), 22,
          'el renombre no sumó ni sacó entidades (siguen 22)');

-- --- realtime ---------------------------------------------------------------------------------
select is((select count(*)::int from pg_publication_tables
            where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'precio_por_ciudad'),
          1, 'supabase_realtime sigue publicando la tabla, con el nombre nuevo');
select is((select count(*)::int from pg_publication_tables
            where pubname = 'supabase_realtime' and tablename = 'precio_por_zona'),
          0, 'y no con el viejo');

select * from finish();
rollback;
