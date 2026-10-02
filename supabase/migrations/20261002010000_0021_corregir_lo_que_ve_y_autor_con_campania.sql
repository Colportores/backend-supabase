-- ============================================================================
-- 0021 · Corregir lo que se ve (el rechazo es visible, no un conflicto falso), y el autor de una
--        casa también escribe solo con la campaña vigente
--        (backend-supabase#45, re-revisión del 02/10; backend-supabase#51, decisión del orquestador)
--
-- ## 1. El UPDATE llega a lo que la lectura ya ve (hallazgo de la re-revisión de #45)
--
-- Re-revisión de #45 (comentario 5953241096): desde 0013 la lectura de ubicacion (y por ella la de
-- espacio y house_status) incluye las campañas que todavía no empezaron
-- (mis_ciudades_de_trabajo()), pero el USING de los UPDATE de 0011 y 0018 sigue pidiendo campaña
-- que ya empezó (mis_ciudades_de_campania(), puedo_escribir_en_ubicacion()). Antes del primer día,
-- el colportor ve una casa o un espacio ajeno, lo corrige, y el UPDATE no alcanza ninguna fila:
-- sync.aplicar_job_interno lo toma por «otro escritor ganó la carrera» y devuelve `conflict` con
-- server_row y la misma versión que mandó. El teléfono pisaba su corrección con la fila del
-- servidor, sin aviso (el mismo problema que 0018 arregló para el espacio propio).
--
-- Arreglo, como 0018: el USING suma lo que la lectura ve, y el WITH CHECK sigue pidiendo lo que
-- puede escribir. El UPDATE llega a la fila y el WITH CHECK la rechaza con 42501: el push lo
-- devuelve `invalid`, visible en la cola de error, sin reintento automático. Se redefinen las tres
-- políticas (la de espacio, tal como la dejó 0018):
--   · ubicacion_por_ciudad_update: USING suma `ciudad_id in mis_ciudades_de_trabajo()` (lo que
--     ve por ciudad). El WITH CHECK queda como en 0011.
--   · house_status_por_ubicacion_update y espacio_por_ubicacion_update: USING suma
--     `exists (select 1 from ubicacion u where u.id = ubicacion_id)` (lo que ve de la casa). El
--     WITH CHECK queda como en 0011 y 0018: puedo_escribir_en_ubicacion().
-- Lo que ya no ve sigue igual: FILA_INEXISTENTE (`invalid`).
--
-- ## 2. El autor de una casa escribe solo con la campaña vigente (decisión del 02/10 en #51)
--
-- Decisión del orquestador (backend-supabase#51, comentario 5953264962; coherencia con la decisión
-- de Cristian del 02/10, comentario 5951900059, «solo con campaña vigente»): la rama «la registró
-- él» de puedo_escribir_en_ubicacion() dejaba al autor seguir corrigiendo los espacios y estados
-- de su casa para siempre, con la campaña terminada. Pasa a exigir campaña en la que se puede
-- escribir (mis_campanias_para_escribir(), 0020: ya empezó, y no terminó o terminó hace 15 días o
-- menos): pasado el plazo, el autor tampoco escribe, y el push devuelve `invalid` 42501.
--   · Qué campaña: cualquiera de las suyas en las que puede escribir, no la de la ciudad de la
--     casa (el autor la puede haber cargado en una ciudad fuera de sus campañas). Pendiente de
--     confirmar en el PR.
--   · No cambia lo que ve: la lectura del autor (created_by) sigue, para que el push no rompa
--     el INSERT ... ON CONFLICT ni tape lo que cargó.
--   · Registrar una casa nueva, la persona, la visita y la venta siguen sin mirar la campaña
--     (0020).
--
-- ## Para otros repos
--
--   · front-colportores-mobile y motor (#178): corregir una casa, un espacio o un estado ajeno
--     antes del primer día de la campaña vuelve `invalid` 42501 (antes `conflict` con server_row).
--     Corregir lo propio con la campaña terminada hace más de 15 días, también 42501 (antes entraba).
--
-- Datos: ninguno cambia; se reemplazan tres políticas y una función.
-- Forward-only: esta migración no se edita una vez aplicada.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. Los UPDATE llegan a lo que la lectura ve
-- ----------------------------------------------------------------------------

drop policy ubicacion_por_ciudad_update on public.ubicacion;
create policy ubicacion_por_ciudad_update on public.ubicacion
  for update to authenticated
  using (created_by = (select auth.uid())
         or ciudad_id in (select public.mis_ciudades_de_campania())
         or ciudad_id in (select public.mis_ciudades_de_trabajo()))
  with check (created_by = (select auth.uid())
              or ciudad_id in (select public.mis_ciudades_de_campania()));

drop policy house_status_por_ubicacion_update on public.house_status;
create policy house_status_por_ubicacion_update on public.house_status
  for update to authenticated
  using (created_by = (select auth.uid())
         or public.puedo_escribir_en_ubicacion(ubicacion_id)
         or exists (select 1 from public.ubicacion u where u.id = ubicacion_id))
  with check (public.puedo_escribir_en_ubicacion(ubicacion_id));

drop policy espacio_por_ubicacion_update on public.espacio;
create policy espacio_por_ubicacion_update on public.espacio
  for update to authenticated
  using (created_by = (select auth.uid())
         or public.puedo_escribir_en_ubicacion(ubicacion_id)
         or exists (select 1 from public.ubicacion u where u.id = ubicacion_id))
  with check (public.puedo_escribir_en_ubicacion(ubicacion_id));

-- ----------------------------------------------------------------------------
-- 2. puedo_escribir_en_ubicacion(): el autor también con campaña
-- ----------------------------------------------------------------------------

-- Misma firma que en 0011; cambia la rama del autor.
create or replace function public.puedo_escribir_en_ubicacion(p_ubicacion_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (select 1 from public.ubicacion u
                  where u.id = p_ubicacion_id
                    and ((u.created_by = auth.uid()
                          and exists (select 1 from public.mis_campanias_para_escribir()))
                         or u.ciudad_id in (select public.mis_ciudades_de_campania())));
$$;

comment on function public.puedo_escribir_en_ubicacion(uuid) is
  'Si el usuario autenticado escribe en la ubicación (corregirla, cargarle espacios y estados): '
  'estando inscripto en una campaña en la que puede escribir (ya empezada, y sin terminar o '
  'terminada hace 15 días o menos: mis_campanias_para_escribir(), 0020), y la registró él o es de '
  'una ciudad de esas campañas (mis_ciudades_de_campania()). Sin pasar por la RLS de lectura: la '
  'usan las políticas de escritura de espacio y house_status (0021).';

-- ----------------------------------------------------------------------------
-- 3. Comentarios que habían quedado viejos
-- ----------------------------------------------------------------------------

comment on policy ubicacion_por_ciudad_update on public.ubicacion is
  'Corrige quien la registró o quien trabaja en la ciudad. USING: lo que ve (también las campañas '
  'por empezar), para que el rechazo llegue como 42501 visible y no como un conflicto falso. '
  'WITH CHECK: solo lo que puede escribir (0021).';
