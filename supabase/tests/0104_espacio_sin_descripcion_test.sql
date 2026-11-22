-- pgTAP · migración 0104 (backend-supabase#79; decisión de Cristian del 06/10, «Notas depto»): ningún texto
-- libre de un depto sube al servidor, así que espacio no tiene descripcion. Sobre una base recién migrada;
-- la migración con datos (vacíos y con texto) está en tests_migracion/0104_ok y 0104_aborta.
begin;
select * from no_plan();

select has_column('public', 'espacio', 'numero_depto', 'espacio conserva numero_depto');
select has_column('public', 'espacio', 'piso', 'y piso');
select hasnt_column('public', 'espacio', 'descripcion', 'pero no tiene descripcion: el texto libre de un depto no sube');
select columns_are('public', 'espacio',
  array['id', 'ubicacion_id', 'numero_depto', 'piso', 'created_at', 'updated_at', 'created_by', 'deleted_at',
        'sync_version', 'xmin_w'],
  'espacio queda con id, ubicacion_id, numero_depto, piso y las columnas de auditoría y de sync');

select * from finish();
rollback;
