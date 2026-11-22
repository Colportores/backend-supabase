-- pgTAP · 0145 sobre los datos de antes: solo suma. El stock que ya había queda idéntico (con su versión de sync y
-- su xmin_w: ni se enteran los teléfonos); las entidades de antes quedan idénticas y la única nueva es `stock`
-- (solo bajada, con el dueño en usuario_id); y la colportora que ya tenía stock lo baja entero por el pull, sin el
-- de su compañera. Ver scripts/db-test-migracion.sh y datos.sql.
begin;
select * from no_plan();

create or replace function pg_temp.actuar_como(p_uid uuid) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', json_build_object('sub', p_uid, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', p_uid::text, true);
  perform set_config('request.jwt.claim.role', 'authenticated', true);
  perform set_config('role', 'authenticated', true);
end $$;
create or replace function pg_temp.actuar_como_servidor() returns void language plpgsql as $$
begin
  perform set_config('role', 'postgres', true);
  perform set_config('request.jwt.claims', '', true);
  perform set_config('request.jwt.claim.sub', '', true);
  perform set_config('request.jwt.claim.role', '', true);
end $$;

-- --- los datos de antes siguen ---------------------------------------------------------------
select is((select count(*)::int from public.stock), 3, 'las tres filas de stock siguen');
select is((select count(*)::int from public.stock s join public.prueba_0145_stock f using (id)
            where to_jsonb(s) is distinct from to_jsonb(f)), 0,
          'quedaron idénticas en todas sus columnas, sync_version y xmin_w incluidos: ni se enteran los teléfonos');

-- --- el registro de sync -----------------------------------------------------------------------
select is((select count(*)::int
             from sync.entidad e
             join public.prueba_0145_entidad s using (nombre)
            where (e.tabla::text, e.columna_pk, e.permite_push, e.columnas_servidor, e.sigue_campanias, e.columna_duenio)
                  is distinct from (s.tabla, s.columna_pk, s.permite_push, s.columnas_servidor, s.sigue_campanias, s.columna_duenio)), 0,
          'las entidades de antes quedaron idénticas');
select is((select array_agg(nombre order by nombre) from sync.entidad e
            where not exists (select 1 from public.prueba_0145_entidad s where s.nombre = e.nombre)),
          array['stock'], 'y la única nueva es stock');
select results_eq(
  $$ select permite_push, columna_pk, columna_duenio, sigue_campanias from sync.entidad where nombre = 'stock' $$,
  $$ values (false, 'id'::text, 'usuario_id'::text, false) $$,
  'de solo bajada y con el dueño en usuario_id');

-- --- la colportora baja el stock que ya tenía ---------------------------------------------------
select pg_temp.actuar_como('01920000-0000-7000-8000-0000000145b1');
select is((select array_agg(right(e ->> 'id', 2) || '=' || (e ->> 'cantidad_disponible') order by e ->> 'id')
             from jsonb_array_elements(sync.pull(array['stock'], '{}'::jsonb, 1000) -> 'rows' -> 'stock') e),
          array['c1=10', 'c2=-2'], 'b1 baja por el pull las dos filas que ya tenía, con sus cantidades (la negativa también)');
select pg_temp.actuar_como('01920000-0000-7000-8000-0000000145b2');
select is((select array_agg(right(e ->> 'id', 2) || '=' || (e ->> 'cantidad_disponible') order by e ->> 'id')
             from jsonb_array_elements(sync.pull(array['stock'], '{}'::jsonb, 1000) -> 'rows' -> 'stock') e),
          array['c3=7'], 'y b2 baja la suya y nada de b1');
select pg_temp.actuar_como('01920000-0000-7000-8000-0000000145d1');
select is((select count(*)::int
             from jsonb_array_elements(coalesce(sync.pull(array['stock'], '{}'::jsonb, 1000) -> 'rows' -> 'stock', '[]'::jsonb))),
          0, 'el coordinador, que lee el stock de sus colportores por RLS, no lo baja a su teléfono');

select pg_temp.actuar_como_servidor();
select is((select count(*)::int from public.stock s join public.prueba_0145_stock f using (id)
            where to_jsonb(s) is distinct from to_jsonb(f)), 0, 'y el pull no tocó ninguna fila');

select * from finish();
rollback;
