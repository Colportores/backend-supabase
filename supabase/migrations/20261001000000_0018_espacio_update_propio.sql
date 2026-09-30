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
-- Mover el espacio de casa. La rama created_by del WITH CHECK dejaría al autor reapuntar su espacio
-- (ubicacion_id) a una casa de fuera de sus campañas, y el equipo de esa ciudad lo vería y lo
-- bajaría con el pull 'ciudad'. Un WITH CHECK no ve la fila vieja, así que lo cierra un trigger
-- BEFORE UPDATE: si cambia ubicacion_id, la casa de destino la tiene que poder escribir
-- (puedo_escribir_en_ubicacion), igual que para insertar. Corregir otros campos no lo toca. Sin
-- usuario autenticado (mantenimiento del servidor) no se exige.
--
-- Decisión pendiente de Cristian, sin tocar: un ex colportor (sin campaña vigente) sigue
-- corrigiendo y dando de baja SUS espacios, y el equipo actual de la casa ve esos cambios. Lo
-- documenta el test 0021.
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

create function public.tg_espacio_no_mover_a_casa_ajena()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if (select auth.uid()) is not null
     and not public.puedo_escribir_en_ubicacion(new.ubicacion_id) then
    raise exception 'No podés mover el espacio a una casa de fuera de tus campañas. Dejalo en su casa o pedile a un coordinador que lo corrija.'
      using errcode = 'insufficient_privilege';
  end if;
  return new;
end;
$$;

revoke all on function public.tg_espacio_no_mover_a_casa_ajena() from public, anon, authenticated;

create trigger espacio_no_mover_a_casa_ajena
  before update of ubicacion_id on public.espacio
  for each row
  when (old.ubicacion_id is distinct from new.ubicacion_id)
  execute function public.tg_espacio_no_mover_a_casa_ajena();
