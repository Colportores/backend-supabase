-- ============================================================================
-- 0003 · Las políticas del 0001, con las funciones envueltas en (select ...)
--
-- Cambio de RENDIMIENTO, no de permisos: cada política queda lógicamente
-- idéntica. Lo verifica la suite que ya existe — `0002_rls_test.sql` prueba el
-- aislamiento entre dos colportores y `0004_sync_delta_test.sql` el del delta.
-- Si alguna de estas reescrituras cambiara la semántica, esos tests fallan.
--
-- ## El problema, medido
--
-- `supabase/bench/` con 390.000 filas (150 colportores, RP-01), sirviendo una
-- página del delta de `ubicacion`:
--
--     Index Scan using ubicacion_delta_idx  (actual time=1163..1206 rows=400)
--       Filter: ((zona_id = ANY (hashed SubPlan 1)) OR (created_by = ...)
--                OR tiene_rol('COORDINADOR') OR tiene_rol('ADMIN'))
--       Rows Removed by Filter: 59600
--       Buffers: shared hit=24106 read=844
--     Execution Time: 1209.991 ms
--
-- `tiene_rol()` es `stable`, pero escrita suelta en el `USING` el planner la
-- evalúa **por fila**: 60.000 llamadas, cada una con sus joins contra
-- `usuario_rol`/`rol`/`usuario`. De ahí los 24.000 buffers.
--
-- Envuelta en `(select ...)` se convierte en un InitPlan: se evalúa **una vez**
-- por consulta y el resultado se reusa. Mismo plan de acceso, mismo filtro,
-- misma semántica:
--
--     Execution Time: 14.030 ms      ← 86× más rápido, 2.227 buffers
--
-- Es la regla de `security-rls-performance.md` de la skill del dominio
-- (`.claude/skills/supabase-postgres-best-practices/`), que el 0001 aplicó a
-- los índices pero no a las llamadas.
--
-- ## Lo que esto NO arregla
--
-- El predicado por zona sigue siendo un `Filter` y no un `Index Cond`: la
-- cadena de `OR` sobre columnas distintas más dos llamadas a función no es
-- indexable. El delta de `ubicacion`/`espacio`/`house_status` sigue recorriendo
-- la tabla entera para servir una página, y eso crece con los datos. Queda
-- anotado como issue: requiere rediseñar el bypass de staff (COORDINADOR/ADMIN)
-- fuera del `OR`, y eso sí cambia el modelo de permisos.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. Catálogo y geografía (pull): escribe ADMIN
-- ----------------------------------------------------------------------------

do $$
declare
  t text;
begin
  foreach t in array array[
    'pais','ciudad','zona','campania','producto','coleccion','producto_coleccion','rol'
  ] loop
    execute format('drop policy %I on public.%I', t || '_insert_admin', t);
    execute format('drop policy %I on public.%I', t || '_update_admin', t);
    execute format(
      'create policy %I on public.%I for insert to authenticated
         with check ((select public.tiene_rol(''ADMIN'')))',
      t || '_insert_admin', t);
    execute format(
      'create policy %I on public.%I for update to authenticated
         using ((select public.tiene_rol(''ADMIN'')))
         with check ((select public.tiene_rol(''ADMIN'')))',
      t || '_update_admin', t);
  end loop;
end
$$;

-- precio_por_zona: lo escribe el COORDINADOR de la campaña, no el ADMIN
-- (R-CT02, HU-CAT-005).
drop policy precio_por_zona_insert_staff on public.precio_por_zona;
drop policy precio_por_zona_update_staff on public.precio_por_zona;

create policy precio_por_zona_insert_staff on public.precio_por_zona
  for insert to authenticated
  with check (
    (select public.tiene_rol('ADMIN'))
    or ((select public.tiene_rol('COORDINADOR')) and exists (
          select 1 from public.zona z
            join public.campania c on c.id = z.campania_id
           where z.id = precio_por_zona.zona_id and c.coordinador_id = (select auth.uid())))
  );

create policy precio_por_zona_update_staff on public.precio_por_zona
  for update to authenticated
  using (
    (select public.tiene_rol('ADMIN'))
    or ((select public.tiene_rol('COORDINADOR')) and exists (
          select 1 from public.zona z
            join public.campania c on c.id = z.campania_id
           where z.id = precio_por_zona.zona_id and c.coordinador_id = (select auth.uid())))
  )
  with check (
    (select public.tiene_rol('ADMIN'))
    or ((select public.tiene_rol('COORDINADOR')) and exists (
          select 1 from public.zona z
            join public.campania c on c.id = z.campania_id
           where z.id = precio_por_zona.zona_id and c.coordinador_id = (select auth.uid())))
  );

-- ----------------------------------------------------------------------------
-- 2. Identidad
-- ----------------------------------------------------------------------------

drop policy usuario_select_propio_o_staff on public.usuario;
drop policy usuario_update_propio on public.usuario;

create policy usuario_select_propio_o_staff on public.usuario
  for select to authenticated
  using (id = (select auth.uid())
         or (select public.tiene_rol('ADMIN'))
         or (select public.tiene_rol('COORDINADOR')));
create policy usuario_update_propio on public.usuario
  for update to authenticated
  using (id = (select auth.uid()) or (select public.tiene_rol('ADMIN')))
  with check (id = (select auth.uid()) or (select public.tiene_rol('ADMIN')));

drop policy usuario_rol_select on public.usuario_rol;
drop policy usuario_rol_insert_admin on public.usuario_rol;
drop policy usuario_rol_update_admin on public.usuario_rol;

create policy usuario_rol_select on public.usuario_rol
  for select to authenticated
  using (usuario_id = (select auth.uid())
         or (select public.tiene_rol('ADMIN'))
         or (select public.tiene_rol('COORDINADOR')));
create policy usuario_rol_insert_admin on public.usuario_rol
  for insert to authenticated with check ((select public.tiene_rol('ADMIN')));
create policy usuario_rol_update_admin on public.usuario_rol
  for update to authenticated
  using ((select public.tiene_rol('ADMIN'))) with check ((select public.tiene_rol('ADMIN')));

drop policy horario_colportor_propio on public.horario_colportor;
drop policy horario_colportor_select_staff on public.horario_colportor;

create policy horario_colportor_propio on public.horario_colportor
  for all to authenticated
  using (usuario_id = (select auth.uid())) with check (usuario_id = (select auth.uid()));
create policy horario_colportor_select_staff on public.horario_colportor
  for select to authenticated
  using ((select public.tiene_rol('ADMIN')) or (select public.tiene_rol('COORDINADOR')));

drop policy campania_colportor_select on public.campania_colportor;
drop policy campania_colportor_insert_staff on public.campania_colportor;
drop policy campania_colportor_update_staff on public.campania_colportor;

create policy campania_colportor_select on public.campania_colportor
  for select to authenticated
  using (usuario_id = (select auth.uid())
         or (select public.tiene_rol('ADMIN'))
         or (select public.tiene_rol('COORDINADOR')));
create policy campania_colportor_insert_staff on public.campania_colportor
  for insert to authenticated
  with check ((select public.tiene_rol('ADMIN')) or (select public.tiene_rol('COORDINADOR')));
create policy campania_colportor_update_staff on public.campania_colportor
  for update to authenticated
  using ((select public.tiene_rol('ADMIN')) or (select public.tiene_rol('COORDINADOR')))
  with check ((select public.tiene_rol('ADMIN')) or (select public.tiene_rol('COORDINADOR')));

-- ----------------------------------------------------------------------------
-- 3. Modelo Espacio — el que paga la cuenta del delta
-- ----------------------------------------------------------------------------

drop policy ubicacion_por_zona_select on public.ubicacion;
drop policy ubicacion_por_zona_insert on public.ubicacion;
drop policy ubicacion_por_zona_update on public.ubicacion;

create policy ubicacion_por_zona_select on public.ubicacion
  for select to authenticated
  using (zona_id in (select public.mis_zonas())
         or created_by = (select auth.uid())
         or (select public.tiene_rol('COORDINADOR'))
         or (select public.tiene_rol('ADMIN')));
create policy ubicacion_por_zona_insert on public.ubicacion
  for insert to authenticated
  with check (created_by = (select auth.uid())
              and (zona_id is null or zona_id in (select public.mis_zonas())));
create policy ubicacion_por_zona_update on public.ubicacion
  for update to authenticated
  using (zona_id in (select public.mis_zonas()) or created_by = (select auth.uid()))
  with check (zona_id is null
              or zona_id in (select public.mis_zonas())
              or created_by = (select auth.uid()));

drop policy espacio_por_zona_select on public.espacio;
drop policy espacio_por_zona_insert on public.espacio;
drop policy espacio_por_zona_update on public.espacio;

create policy espacio_por_zona_select on public.espacio
  for select to authenticated
  using (exists (select 1 from public.ubicacion u where u.id = ubicacion_id
                   and (u.zona_id in (select public.mis_zonas()) or u.created_by = (select auth.uid())))
         or (select public.tiene_rol('COORDINADOR')) or (select public.tiene_rol('ADMIN')));
create policy espacio_por_zona_insert on public.espacio
  for insert to authenticated
  with check (created_by = (select auth.uid())
              and exists (select 1 from public.ubicacion u where u.id = ubicacion_id
                   and (u.zona_id in (select public.mis_zonas()) or u.created_by = (select auth.uid()))));
create policy espacio_por_zona_update on public.espacio
  for update to authenticated
  using (exists (select 1 from public.ubicacion u where u.id = ubicacion_id
                   and (u.zona_id in (select public.mis_zonas()) or u.created_by = (select auth.uid()))));

drop policy espacio_persona_propio on public.espacio_persona;
create policy espacio_persona_propio on public.espacio_persona
  for all to authenticated
  using (created_by = (select auth.uid())) with check (created_by = (select auth.uid()));

drop policy house_status_por_zona_select on public.house_status;
drop policy house_status_por_zona_insert on public.house_status;
drop policy house_status_por_zona_update on public.house_status;

create policy house_status_por_zona_select on public.house_status
  for select to authenticated
  using (zona_id in (select public.mis_zonas())
         or created_by = (select auth.uid())
         or (select public.tiene_rol('COORDINADOR'))
         or (select public.tiene_rol('ADMIN')));
create policy house_status_por_zona_insert on public.house_status
  for insert to authenticated
  with check (created_by = (select auth.uid())
              and (zona_id is null or zona_id in (select public.mis_zonas())));
create policy house_status_por_zona_update on public.house_status
  for update to authenticated
  using (zona_id in (select public.mis_zonas()) or created_by = (select auth.uid()));

-- ----------------------------------------------------------------------------
-- 4. Operación de campo
-- ----------------------------------------------------------------------------

do $$
declare
  t text;
begin
  foreach t in array array['jornada','visita','agenda','venta'] loop
    execute format('drop policy %I on public.%I', t || '_propio', t);
    execute format(
      'create policy %I on public.%I for all to authenticated
         using (colportor_id = (select auth.uid()))
         with check (colportor_id = (select auth.uid()))',
      t || '_propio', t);
  end loop;

  foreach t in array array['venta_item','entrega','cobranza'] loop
    execute format('drop policy %I on public.%I', t || '_propio', t);
    execute format(
      'create policy %I on public.%I for all to authenticated
         using (exists (select 1 from public.venta v
                         where v.id = venta_id and v.colportor_id = (select auth.uid())))
         with check (exists (select 1 from public.venta v
                         where v.id = venta_id and v.colportor_id = (select auth.uid())))',
      t || '_propio', t);
  end loop;
end
$$;
