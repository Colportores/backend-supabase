-- ============================================================================
-- 0018 · El autor de un espacio lo puede corregir aunque su campaña haya terminado
--        (backend-supabase#32, menor de la re-revisión de #36, comentario 5920668801)
--
-- Problema. 0011 le dio a espacio_por_ubicacion_select la rama «lo cargó él» (created_by), que el
-- push necesita por el INSERT ... ON CONFLICT (id). El UPDATE siguió pidiendo solo
-- puedo_escribir_en_ubicacion(). Con la campaña terminada (o la ciudad fuera de ella), el colportor
-- ve su espacio y no lo puede actualizar: el UPDATE del push no toca ninguna fila y
-- sync.aplicar_job lo toma por «otro escritor ganó la carrera» y devuelve `conflict` con la misma
-- versión que mandó. El teléfono aplica el LWW y pisa su corrección con la fila del servidor, sin
-- aviso. Con un delete pasa lo mismo.
--
-- Arreglo. La política de UPDATE iguala la rama del SELECT: quien lo cargó, o quien puede escribir
-- en la ubicación. Va también en WITH CHECK (sin cláusula propia, Postgres usa el USING para la fila
-- nueva, y con la campaña terminada la fila corregida no pasaría). created_by es inmutable por
-- UPDATE (tg_auditoria_update), así que «lo cargó él» no se puede fabricar. Para el espacio de otro
-- que ya no se ve, todo sigue igual: FILA_INEXISTENTE (`invalid`).
--
-- Fuera de alcance. La venta del último día que sincroniza con la campaña ya terminada (la vigencia
-- usa current_date en UTC) es una decisión pendiente de Cristian: no se toca acá.
--
-- Datos: ninguno cambia; solo se reemplaza una política.
-- Para otros repos: el contrato no cambia. El push de un espacio propio de una campaña terminada
-- vuelve `accepted` en vez de `conflict` (front-colportores-mobile#178).
-- ============================================================================

drop policy espacio_por_ubicacion_update on public.espacio;
create policy espacio_por_ubicacion_update on public.espacio
  for update to authenticated
  using (created_by = (select auth.uid())
         or public.puedo_escribir_en_ubicacion(ubicacion_id))
  with check (created_by = (select auth.uid())
              or public.puedo_escribir_en_ubicacion(ubicacion_id));
