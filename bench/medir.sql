\timing off
-- El cursor del delta es (xmin_w, id) desde 0010, no (updated_at, id). Medir el
-- plan viejo mediría un índice que `sync.pull` ya no usa.
select xmin_w::text as xw from ubicacion limit 1
\gset
\timing on

\echo
\echo '=== plan del delta (un colportor, watermark en la mitad de su historia) ==='
explain (analyze, buffers, costs off)
select coalesce(jsonb_agg(j order by xw, id), '[]'::jsonb)
from (
  select sync.expresion_json('ubicacion'::regclass) as j, t.xmin_w as xw, t.id as id
  from ubicacion t
  where t.pk_usuario = '11111111-1111-4111-8111-000000000007'::uuid
    and t.xmin_w < pg_snapshot_xmin(pg_current_snapshot())
    and (t.xmin_w, t.id) > (:'xw'::xid8, '018f2c4e-6b7d-7a22-9f3c-000000150000'::uuid)
  order by t.xmin_w, t.id
  limit 501
) s;

\echo
\echo '=== pull real: primera sync de un colportor (catálogo desde cero) ==='
select jsonb_array_length(
  sync.pull('11111111-1111-4111-8111-000000000007'::uuid,
            array['jornada','ubicacion'], '{}'::jsonb, 500) -> 'rows' -> 'ubicacion'
) as filas;

\echo
\echo '=== pull incremental: watermark al día ==='
select jsonb_typeof(
  sync.pull('11111111-1111-4111-8111-000000000007'::uuid,
            array['jornada','ubicacion'],
            -- Watermark al día = por delante de todo lo cargado. El xid de la
            -- carga más uno alcanza: nada por debajo del horizonte lo supera.
            jsonb_build_object(
              'ubicacion', jsonb_build_object('xid', (:'xw'::xid8::text::bigint + 1)::text, 'id','00000000-0000-0000-0000-000000000000'),
              'jornada',   jsonb_build_object('xid', (:'xw'::xid8::text::bigint + 1)::text, 'id','00000000-0000-0000-0000-000000000000')),
            500) -> 'rows') as sin_novedades;

\echo
\echo '=== push de un lote de 500 jobs ==='
select jsonb_array_length(
  sync.push('11111111-1111-4111-8111-000000000007'::uuid,
    (select jsonb_agg(jsonb_build_object(
       'client_op_id', ('cafe0000-0000-4000-8000-' || lpad(g::text,12,'0'))::uuid,
       'entity','ubicacion','op','insert',
       'payload', jsonb_build_object(
         'id', ('018f2c4e-6b7d-7a99-9f3c-' || lpad(g::text,12,'0'))::uuid,
         'estado','VENDIDA')))
     from generate_series(1,500) g)) -> 'results') as jobs_aplicados;

\echo
\echo '=== tamaño del cache de client_op_id ==='
select count(*) as ops, pg_size_pretty(pg_total_relation_size('sync.op_cache')) as en_disco
from sync.op_cache;
