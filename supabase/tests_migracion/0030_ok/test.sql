-- pgTAP · 0030 renombra precio_por_zona a precio_por_ciudad y NO toca los datos: las mismas filas con los
-- mismos valores (sync_version y xmin_w incluidos), la misma tabla (mismo OID: no se recreó), las
-- mismas definiciones y los mismos privilegios, con el nombre nuevo. Ver scripts/db-test-migracion.sh y
-- los precios de datos.sql.
begin;
select * from no_plan();

select has_table('public', 'precio_por_ciudad', 'existe precio_por_ciudad');
select hasnt_table('public', 'precio_por_zona', 'ya no existe precio_por_zona');

-- --- los datos ---------------------------------------------------------------------------
select is((select count(*)::int from public.precio_por_ciudad), 7, 'los 7 precios siguen: no se perdió ninguno');
select is((select count(*)::int from public.precio_por_ciudad p join public.prueba_0030_precio s using (id)), 7,
          'y son los mismos ids de antes');
select is((select count(*)::int
             from public.precio_por_ciudad p
             join public.prueba_0030_precio s on s.id = p.id
            where to_jsonb(p) is distinct from to_jsonb(s)), 0,
          'cada fila quedó idéntica en todas sus columnas: importe, vigencia, baja, auditoría, sync_version y xmin_w');
select is((select count(*)::int from public.precio_por_ciudad where deleted_at is not null), 1,
          'el precio dado de baja sigue de baja');
select is((select oid_antes from public.prueba_0030_oid), 'public.precio_por_ciudad'::regclass::oid,
          'es la misma tabla (mismo OID): se renombró, no se recreó');

-- --- las definiciones: iguales, salvo el nombre ----------------------------------------
-- Para cada clase de objeto, lo de antes (con el prefijo viejo cambiado por el nuevo) tiene que ser
-- exactamente lo de ahora.
create temp table ahora_0030 on commit drop as
  select 'restriccion' as clase, c.conname::text as nombre, pg_get_constraintdef(c.oid) as def
    from pg_constraint c where c.conrelid = 'public.precio_por_ciudad'::regclass
  union all
  select 'indice', i.indexname::text, i.indexdef
    from pg_indexes i where i.schemaname = 'public' and i.tablename = 'precio_por_ciudad'
  union all
  select 'trigger', t.tgname::text, pg_get_triggerdef(t.oid)
    from pg_trigger t where t.tgrelid = 'public.precio_por_ciudad'::regclass and not t.tgisinternal
  union all
  select 'politica', p.policyname::text,
         concat_ws(' | ', p.cmd, p.roles::text, p.permissive, p.qual, p.with_check)
    from pg_policies p where p.schemaname = 'public' and p.tablename = 'precio_por_ciudad'
  union all
  select 'columna', a.attname::text,
         concat_ws(' | ', format_type(a.atttypid, a.atttypmod), a.attnotnull::text, pg_get_expr(d.adbin, d.adrelid))
    from pg_attribute a
    left join pg_attrdef d on d.adrelid = a.attrelid and d.adnum = a.attnum
   where a.attrelid = 'public.precio_por_ciudad'::regclass and a.attnum > 0 and not a.attisdropped
  union all
  select 'privilegios', 'tabla', c.relacl::text || ' | rls=' || c.relrowsecurity || ' | force=' || c.relforcerowsecurity
    from pg_class c where c.oid = 'public.precio_por_ciudad'::regclass
  union all
  select 'sync', e.nombre::text,
         concat_ws(' | ', e.tabla::oid::text, e.columna_pk, e.permite_push::text, e.sigue_campanias::text,
                   coalesce(e.columna_duenio, '-'), coalesce(e.columna_ubicacion, '-'))
    from sync.entidad e where e.tabla = 'public.precio_por_ciudad'::regclass
  union all
  select 'realtime', pt.pubname::text, pt.schemaname || '.' || pt.tablename
    from pg_publication_tables pt where pt.tablename = 'precio_por_ciudad';

create temp table antes_0030 on commit drop as
  select clase,
         replace(nombre, 'precio_por_zona', 'precio_por_ciudad') as nombre,
         replace(def, 'precio_por_zona', 'precio_por_ciudad') as def
    from public.prueba_0030_objeto;

select is((select count(*)::int from antes_0030), (select count(*)::int from ahora_0030),
          'hay los mismos objetos que antes: ninguno de más, ninguno de menos');
select is((select count(*)::int from antes_0030 a join ahora_0030 b using (clase, nombre, def)),
          (select count(*)::int from antes_0030),
          'y cada uno está definido igual (restricciones, índices, triggers, políticas, columnas, privilegios, sync, realtime), con el nombre nuevo');
select is((select count(*)::int from antes_0030 where clase = 'restriccion'), 10, 'eran 10 restricciones');
select is((select count(*)::int from antes_0030 where clase = 'indice'), 6, 'eran 6 índices');
select is((select count(*)::int from antes_0030 where clase = 'trigger'), 2, 'eran 2 triggers');
select is((select count(*)::int from antes_0030 where clase = 'politica'), 3, 'eran 3 políticas');
select is((select count(*)::int from antes_0030 where clase = 'sync'), 1, 'y 1 entidad de sync');

-- --- con el nombre nuevo, el sync la baja entera -------------------------------------------
select results_eq(
  $$ select nombre from sync.entidad where tabla = 'public.precio_por_ciudad'::regclass $$,
  $$ values ('precio_por_ciudad'::text) $$,
  'la entidad de sync se llama precio_por_ciudad');
select is((select count(*)::int from sync.entidad where nombre = 'precio_por_zona'), 0,
          'y precio_por_zona ya no está en el registro');

select * from finish();
rollback;
