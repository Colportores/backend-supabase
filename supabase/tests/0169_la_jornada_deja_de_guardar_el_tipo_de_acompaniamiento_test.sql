-- pgTAP · migración 0169 (backend-supabase#243, casilla «Tipo acomp.»; decisión de Cristian del 04/11, «Sacarlo del esquema»):
-- `jornada.tipo_acompaniamiento` ya no existe, ni en la tabla ni en lo que el sync baja y sube; el acompañamiento de verdad
-- (la tabla `jornada_acompaniamiento`) no se toca. Va en una transacción.
begin;
select * from no_plan();

select hasnt_column('public', 'jornada', 'tipo_acompaniamiento', 'jornada ya no guarda el tipo de acompañamiento');
select has_table('public', 'jornada_acompaniamiento', 'la tabla jornada_acompaniamiento sigue');
select is((select count(*)::int from unnest(sync.columnas_escribibles('jornada')) c where c = 'tipo_acompaniamiento'), 0,
          'el push no la escribe');
select is(position('tipo_acompaniamiento' in sync.expresion_json('public.jornada'::regclass)), 0, 'el delta no la baja');
select is((select count(*)::int from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname in ('public', 'sync', 'auditoria') and p.prosrc like '%tipo_acompaniamiento%'), 0,
          'ninguna función la nombra');

select * from finish();
rollback;
