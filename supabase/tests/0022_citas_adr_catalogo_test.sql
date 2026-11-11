-- pgTAP · migración 0019 (backend-supabase#43): los comentarios del catálogo citan la numeración
-- nueva de los ADR (docs-organizacion, renumeración del 23/09).
begin;
select * from no_plan();

select is(col_description('public.espacio'::regclass,
                          (select attnum from pg_attribute where attrelid = 'public.espacio'::regclass
                                                             and attname = 'numero_depto')),
          'Va al cloud siempre. ADR-004 descartó propagarlo solo con operaciones financieras: va con '
          'la casa, igual que calle/numero.',
          'espacio.numero_depto cita ADR-004');
select is(obj_description('sync'::regnamespace, 'pg_namespace'),
          'Maquinaria de sincronización (ADR-008). No se expone en la Data API: config.toml '
          'lista solo public y graphql_public. Se llega por los RPC, con el JWT del usuario.',
          'el esquema sync cita ADR-008');
select ok(obj_description('public.ubicacion'::regclass, 'pg_class') like '%(ADR-004)%',
          'ubicacion ya citaba ADR-004 (0011)');
select ok((select prosrc not like '%ADR-013%' from pg_proc where oid = 'sync.aplicar_job(jsonb)'::regprocedure),
          'sync.aplicar_job ya no tiene la cita vieja (ADR-013)');

select * from finish();
rollback;
