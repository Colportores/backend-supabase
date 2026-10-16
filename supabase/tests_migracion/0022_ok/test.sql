-- pgTAP · 0022 abre un tramo inicial por cada inscripción con zona (también la dada de baja) sin
-- tocar ninguna inscripción. Ver scripts/db-test-migracion.sh.
begin;
select * from no_plan();

select has_table('public', 'campania_colportor_zona_historial', 'existe el historial de zonas');

select results_eq(
  $$ select id, campania_id, usuario_id, zona_id, meta_libros, created_at, updated_at, created_by, deleted_at,
            sync_version, xmin_w::text from public.campania_colportor order by id $$,
  $$ select * from public.prueba_0022_campania_colportor order by id $$,
  'ninguna inscripción se pierde ni cambia (ni su sync_version ni su xmin_w), la dada de baja incluida');

select is((select count(*)::integer from public.campania_colportor_zona_historial), 3,
          'un tramo por cada inscripción con zona: b1, b3 (dada de baja) y b4; b2, sin zona, ninguno');
select results_eq(
  $$ select campania_colportor_id, zona_id from public.campania_colportor_zona_historial order by campania_colportor_id $$,
  $$ select id, zona_id from public.prueba_0022_campania_colportor where zona_id is not null order by id $$,
  'cada tramo es el de la zona que la inscripción tenía');
select is((select count(*)::integer from public.campania_colportor_zona_historial
            where hasta is null and cerrada_por is null and created_by is null and deleted_at is null), 3,
          'todos abiertos, sin quién (nadie los asignó: es el punto de partida)');
select is((select count(*)::integer from public.campania_colportor_zona_historial where inicial), 3,
          'y marcados como iniciales: su desde es una cota, no la fecha de la asignación');
select ok((select bool_and(desde >= (select max(created_at) from public.prueba_0022_campania_colportor))
             from public.campania_colportor_zona_historial),
          'con el desde de la migración, nunca anterior a la inscripción: no se inventa un pasado');

-- Desde acá el historial sigue a las inscripciones: el cambio de zona cierra el tramo inicial.
update public.campania_colportor set zona_id = '01920000-0000-7000-8000-0000000099d2'
 where id = '01920000-0000-7000-8000-0000000099a1';
select is((select count(*)::integer from public.campania_colportor_zona_historial
            where campania_colportor_id = '01920000-0000-7000-8000-0000000099a1'), 2,
          'cambiarle la zona a b1 suma un tramo');
select is((select inicial from public.campania_colportor_zona_historial
            where campania_colportor_id = '01920000-0000-7000-8000-0000000099a1' and hasta is not null),
          true, 'y el tramo inicial queda cerrado');
select is((select zona_id from public.campania_colportor_zona_historial
            where campania_colportor_id = '01920000-0000-7000-8000-0000000099a1' and hasta is null),
          '01920000-0000-7000-8000-0000000099d2'::uuid, 'con la zona nueva abierta');

select * from finish();
rollback;
