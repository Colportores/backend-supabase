-- 0141 (backend-supabase#201, decisión «Motivo devol.» del 27/10): la coordinadora lee las devoluciones de su
-- equipo, con el motivo que escribió el colportor (0136). Hasta acá solo la leía la dueña.
--
--   · Política de lectura nueva: el ADMIN y el coordinador de una campaña donde el colportor tiene o tuvo
--     inscripción (public.coordina_al_colportor(), la misma de stock y cuenta, 0067).
--   · No cambia el sync: el pull sigue filtrando por colportor_id = auth.uid(), así que un coordinador no baja
--     las devoluciones de su equipo a su teléfono; las lee el panel por PostgREST/RPC con esta política.
--   · La devolución no lleva datos del cliente (solo venta_id, productos, montos y motivo): el coordinador ve
--     montos, no clientes.

create policy devolucion_select_coordinacion on public.devolucion
  for select to authenticated
  using ((select public.tiene_rol('ADMIN')) or public.coordina_al_colportor(colportor_id));

comment on policy devolucion_select_coordinacion on public.devolucion is
  'El ADMIN y el coordinador de una campaña donde el colportor tiene o tuvo inscripción leen sus devoluciones, '
  'con el motivo (0141, backend-supabase#201). La escritura sigue siendo solo de la dueña.';
