-- Mide el delta con la RLS haciendo el filtrado. Ver supabase/bench/README.md.
--
-- La pregunta que contesta (issue #6): al pasar los RPC a SECURITY INVOKER, el
-- filtrado por fila dejó de ser un `where pk_usuario = $1` explícito y pasó a
-- ser el predicado de la política. Para `jornada`/`venta` ese predicado es
-- `colportor_id = auth.uid()` — una igualdad, y el índice del delta la lleva
-- adelante. Para `ubicacion`/`espacio`/`house_status` es
-- `zona_id in (select mis_zonas())`, que NO es una igualdad indexable, y para
-- `venta_item` es un EXISTS contra `venta`.
--
-- Lo que hay que mirar en cada plan: si aparece **Index Cond** con la columna
-- del predicado, o si aparece **Filter** después de un scan grande.

\set ON_ERROR_STOP on

-- Se actúa como un colportor cualquiera de la carga.
select id as bench_uid from public.usuario where email = 'bench-1@bench.local' \gset
\echo '-- midiendo como' :bench_uid

select set_config('request.jwt.claims',
                  json_build_object('sub', :'bench_uid', 'role', 'authenticated')::text, false);
select set_config('request.jwt.claim.sub', :'bench_uid', false);
set role authenticated;

\echo ''
\echo '============================================================'
\echo ' 1. jornada — predicado RLS = igualdad (colportor_id)'
\echo '============================================================'
explain (analyze, buffers, costs off)
select t.id, t.xmin_w from public.jornada t
 where t.xmin_w < pg_snapshot_xmin(pg_current_snapshot())
   and (t.xmin_w, t.id) > ('0'::xid8, '00000000-0000-0000-0000-000000000000'::uuid)
 order by t.xmin_w, t.id limit 500;

\echo ''
\echo '============================================================'
\echo ' 2. ubicacion — predicado RLS = mis_zonas() (NO es igualdad)'
\echo '    Es la pregunta abierta de #6.'
\echo '============================================================'
explain (analyze, buffers, costs off)
select t.id, t.xmin_w from public.ubicacion t
 where t.xmin_w < pg_snapshot_xmin(pg_current_snapshot())
   and (t.xmin_w, t.id) > ('0'::xid8, '00000000-0000-0000-0000-000000000000'::uuid)
 order by t.xmin_w, t.id limit 500;

\echo ''
\echo '============================================================'
\echo ' 3. venta_item — predicado RLS = EXISTS contra venta'
\echo '============================================================'
explain (analyze, buffers, costs off)
select t.id, t.xmin_w from public.venta_item t
 where t.xmin_w < pg_snapshot_xmin(pg_current_snapshot())
   and (t.xmin_w, t.id) > ('0'::xid8, '00000000-0000-0000-0000-000000000000'::uuid)
 order by t.xmin_w, t.id limit 500;

\echo ''
\echo '============================================================'
\echo ' 4. visita — igualdad, la tabla más grande'
\echo '============================================================'
explain (analyze, buffers, costs off)
select t.id, t.xmin_w from public.visita t
 where t.xmin_w < pg_snapshot_xmin(pg_current_snapshot())
   and (t.xmin_w, t.id) > ('0'::xid8, '00000000-0000-0000-0000-000000000000'::uuid)
 order by t.xmin_w, t.id limit 500;

\echo ''
\echo '============================================================'
\echo ' 5. Los RPC completos, punta a punta'
\echo '============================================================'

\timing on
\echo '-- pull de una página (primera, watermark en cero)'
select jsonb_array_length(sync.pull(array['jornada','visita','ubicacion','venta'])
                          #> '{rows,visita}') as filas_visita;

\echo '-- pull incremental sin novedades (el latido más común)'
select sync.pull(array['jornada','visita','ubicacion','venta'],
                 sync.pull(array['jornada','visita','ubicacion','venta']) -> 'watermark') -> 'has_more';

\echo '-- push de un lote de 100 jornadas (RR-02: 100 registros bajo 30 s)'
select (sync.push(
  (select jsonb_agg(jsonb_build_object(
     'client_op_id', public.uuid_generate_v7(),
     'entity', 'jornada',
     'op', 'insert',
     'payload', jsonb_build_object('id', public.uuid_generate_v7(),
                                   'inicio', (now() - (n || ' minutes')::interval)::text)))
   from generate_series(1, 100) n)
) -> 'results') is not null as push_ok;
\timing off

reset role;
select set_config('request.jwt.claims', '', false);
select set_config('request.jwt.claim.sub', '', false);
