-- pgTAP · fechas de alta de las inscripciones de la demo (supabase/seed-demo/demo-datos.sql y corregir-fechas-de-alta-demo.sql)
--   1. El generador carga cada inscripción con su primer día como fecha de alta y el primer tramo de zona desde ese día.
--   2. Con eso, Inicio y Reportes de la campaña de Verano tienen datos (tablero_de_inicio, ventas_/horas_por_ciudad_y_colportor),
--      leídos con la sesión del coordinador de la demo, y las ventas caen en una ciudad.
--   3. La corrección, sobre una demo cargada con la hora de la carga (como quedó el remoto antes del 11/11): la vista previa no
--      cambia nada; aplicada, pone las fechas de las 13 inscripciones y de sus primeros tramos, deja el trigger de auditoría
--      activo y no toca otra cosa; una segunda corrida no encuentra nada.
-- Va en una transacción que se deshace. Requiere invocarse con cwd = raíz del repo (así lo hace scripts/db-test.sh).
begin;
select * from no_plan();

\o /dev/null
\i supabase/seed-demo/demo-datos.sql
\o

create or replace function pg_temp.inscr() returns setof uuid language sql as $$
  select ('5eed0000-0000-7000-800b-' || lpad(to_hex(n), 12, '0'))::uuid from generate_series(1, 13) n;
$$;
create or replace function pg_temp.primer_tramo(p_inscr uuid) returns timestamptz language sql as $$
  select min(h.desde) from public.campania_colportor_zona_historial h where h.campania_colportor_id = p_inscr and h.deleted_at is null;
$$;
-- Lo que leen Inicio y Reportes, con la sesión del coordinador generado (5eed…-8000-…0).
create or replace function pg_temp.como_coordinador() returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', json_build_object('sub', '5eed0000-0000-7000-8000-000000000000', 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', '5eed0000-0000-7000-8000-000000000000', true);
  perform set_config('request.jwt.claim.role', 'authenticated', true);
end $$;

-- 1. El generador
select is((select count(*) from public.campania_colportor cc
             join (values (1, date '2026-09-14'), (2, date '2026-09-14'), (3, date '2026-09-14'), (4, date '2026-09-14'),
                          (5, date '2026-09-28'), (6, date '2026-09-14'), (7, date '2026-09-14'), (8, date '2026-09-21'),
                          (9, date '2026-09-14'), (10, date '2026-10-05'), (11, date '2026-07-13'), (12, date '2026-07-13'),
                          (13, date '2026-07-20')) v(no, d0)
               on cc.id = ('5eed0000-0000-7000-800b-' || lpad(to_hex(v.no), 12, '0'))::uuid
            where cc.created_at = v.d0::timestamp at time zone 'America/Montevideo'),
          13::bigint, 'cada inscripción tiene como alta su primer día (00:00 de Montevideo)');
select is((select count(*) from public.jornada j join public.campania_colportor cc on cc.usuario_id = j.colportor_id
            where cc.id in (select pg_temp.inscr()) and j.deleted_at is null
              and not exists (select 1 from public.campania_colportor c2 where c2.usuario_id = j.colportor_id and c2.created_at <= j.inicio)),
          0::bigint, 'ninguna jornada es anterior al alta de su colportor');
select is((select count(*) from public.campania_colportor cc where cc.id in (select pg_temp.inscr())
            and pg_temp.primer_tramo(cc.id) = cc.created_at),
          13::bigint, 'el primer tramo de zona de cada inscripción empieza el día del alta');

-- 2. Inicio y Reportes de Verano
select pg_temp.como_coordinador();
set local role authenticated;
select cmp_ok((select count(*) from public.ventas_por_ciudad_y_colportor('5eed0000-0000-7000-8003-000000000001', date '2026-09-14', date '2026-11-04', 'dia')),
              '>', 0::bigint, 'Reportes: hay ventas de la campaña de Verano');
select is((select count(*) from public.ventas_por_ciudad_y_colportor('5eed0000-0000-7000-8003-000000000001', date '2026-09-14', date '2026-11-04', 'dia')
            where ciudad_id is null and ventas > 0),
          0::bigint, 'Reportes: ninguna venta queda sin ciudad');
select cmp_ok((select coalesce(sum(jornadas), 0) from public.horas_por_ciudad_y_colportor('5eed0000-0000-7000-8003-000000000001', date '2026-09-14', date '2026-11-04', 'dia')),
              '>', 0::bigint, 'Reportes: hay jornadas de la campaña de Verano');
select cmp_ok((select count(*) from jsonb_array_elements(public.tablero_de_inicio('5eed0000-0000-7000-8003-000000000001', date '2026-10-15') -> 'ciudades') ci,
                    jsonb_array_elements(ci -> 'colportores') col),
              '>', 0::bigint, 'Inicio: un día de octubre muestra colportores en sus ciudades');
reset role;

-- 3. La corrección sobre una demo cargada con la hora de la carga
alter table public.campania_colportor disable trigger campania_colportor_auditoria_update;
update public.campania_colportor set created_at = now() where id in (select pg_temp.inscr());
alter table public.campania_colportor enable trigger campania_colportor_auditoria_update;
update public.campania_colportor_zona_historial h set desde = now()
 where h.campania_colportor_id in (select pg_temp.inscr()) and h.hasta is null and h.desde = pg_temp.primer_tramo(h.campania_colportor_id);
create temp table tramos_rotos as
  select h.id from public.campania_colportor_zona_historial h where h.campania_colportor_id in (select pg_temp.inscr()) and h.desde = now();
create temp table otras_antes as
  select cc.id, cc.created_at, cc.updated_at, cc.sync_version from public.campania_colportor cc where cc.id not in (select pg_temp.inscr());

\o /dev/null
\i supabase/seed-demo/corregir-fechas-de-alta-demo.sql
\o
select is((select count(*) from public.campania_colportor where id in (select pg_temp.inscr()) and created_at = now()),
          13::bigint, 'la vista previa no cambia nada');
select is((select filas from fechas_demo_resumen where que = 'campania_colportor.created_at'), 13,
          'la vista previa cuenta las 13 inscripciones');

select set_config('fechas.aplicar', 'si', true);
\o /dev/null
\i supabase/seed-demo/corregir-fechas-de-alta-demo.sql
\o
select is((select filas from fechas_demo_resumen where que = 'campania_colportor.created_at'), 13, 'aplicada: 13 inscripciones');
select is((select filas from fechas_demo_resumen where que like 'campania_colportor_zona_historial%'),
          (select count(*)::integer from tramos_rotos), 'aplicada: los primeros tramos que estaban rotos');
select is((select count(*) from public.campania_colportor cc where cc.id in (select pg_temp.inscr())
            and cc.created_at < timestamptz '2026-11-01 00:00:00-03' and pg_temp.primer_tramo(cc.id) = cc.created_at),
          13::bigint, 'las 13 inscripciones vuelven a su fecha de alta, con el primer tramo desde ese día');
select is((select tgenabled from pg_trigger where tgname = 'campania_colportor_auditoria_update'), 'O'::"char",
          'el trigger de auditoría queda activo');
select is((select count(*) from public.campania_colportor cc join otras_antes o on o.id = cc.id
            where (cc.created_at, cc.updated_at, cc.sync_version) is distinct from (o.created_at, o.updated_at, o.sync_version)),
          0::bigint, 'ninguna otra inscripción cambia');

\o /dev/null
\i supabase/seed-demo/corregir-fechas-de-alta-demo.sql
\o
select is((select sum(filas)::integer from fechas_demo_resumen where filas is not null), 0, 'una segunda corrida no encuentra nada');

select * from finish();
rollback;
