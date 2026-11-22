-- ============================================================================
-- 0183 · La lista de quién puede figurar como acompañante en el panel: los coordinadores de cualquier campaña y los
--        administradores
--        (backend-supabase#257, seguimiento de #254 y de front-coordinadores-web#146; decisión de Cristian del 05/11,
--        casillas «Valida acomp» y «Admins lista» de backend-supabase#249)
--
-- ## El caso
--
-- Luis, coordinador de «Verano», abre el historial de Ana en el panel (vista 33) y quiere anotar que Marta, coordinadora de otra
-- campaña, la acompañó el martes. `agregar_acompaniamiento()` (0177) ya acepta a cualquier coordinador y administrador, pero el
-- panel no tiene cómo mostrarle el selector: la 0015 le sacó a los coordinadores la lectura de `usuario`, y no se reabre.
--
-- ## Qué suma
--
--   acompaniantes_del_panel(p_campania_id uuid) -> (usuario_id, nombre, apellido)
--
-- Las cuentas que el panel puede ofrecer como acompañante de otra persona, además de los colportores del equipo (que ya salen de
-- las RPC de la campaña):
--
--   · todos los **coordinadores**, de cualquier campaña (no solo los de `p_campania_id`);
--   · todos los **administradores**.
--
-- «Activo» es el criterio de `cuenta_tiene_rol()` (0177), el mismo de `tiene_rol()`: el rol está vigente hoy y la cuenta no está
-- dada de baja ni suspendida. Una persona con los dos roles sale una sola vez. Orden: apellido, nombre, id.
--
-- Devuelve **id, nombre y apellido y nada más**: ni correo, ni teléfono, ni cédula, ni el rol. No es una lectura de `usuario`
-- para el coordinador (la 0015 sigue como está): es un listado cerrado de nombres de gente del equipo, para un único fin.
--
-- ## Permisos
--
-- Los de `motivo_mapa_de_campania()` (0175): 42501 sin sesión o sin ser ADMIN ni coordinador de ESA campaña (cualquiera de sus
-- coordinadores); CZ001 campaña inexistente. **Una campaña terminada se lee** (no hay CZ011): el selector se carga al abrir el
-- registro y quien pueda anotar o no se decide al guardar, con la regla de los 15 días de `agregar_acompaniamiento()`.
-- SECURITY DEFINER, `search_path` vacío, EXECUTE solo para `authenticated`.
--
-- ## Los datos
--
-- Solo una función nueva; no toca filas. Lo prueba supabase/tests/0183_… . Forward-only.
--
-- ## Para otros repos
--
--   · front-coordinadores-web#146: la vista 33 llama `acompaniantes_del_panel(campania)` para el selector «¿Quién acompañó?»,
--     junto a los colportores inscriptos.
--   · docs-organizacion: la fila de la RPC en el contrato (entrada «Sin publicar»).
--
-- Forward-only: esta migración no se edita una vez aplicada.
-- ============================================================================

create function public.acompaniantes_del_panel(p_campania_id uuid)
returns table (usuario_id uuid, nombre text, apellido text)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_motivo text;
begin
  -- El permiso, antes de mirar nada más. La terminada se lee (ver arriba); las demás no pasan a lanzar_motivo_mapa().
  v_motivo := public.motivo_mapa_de_campania(p_campania_id);
  if v_motivo is distinct from 'CAMPANIA_TERMINADA' then
    perform public.lanzar_motivo_mapa(v_motivo);
  end if;

  return query
    select u.id, u.nombre, u.apellido
      from public.usuario u
     where u.deleted_at is null
       and (public.cuenta_tiene_rol(u.id, 'COORDINADOR')
            or public.cuenta_tiene_rol(u.id, 'ADMIN'))
     order by u.apellido, u.nombre, u.id;
end;
$$;

comment on function public.acompaniantes_del_panel(uuid) is
  'Vista 33, quién puede figurar como acompañante (0183, backend-supabase#257): id, nombre y apellido de los coordinadores de '
  'cualquier campaña y de los administradores, activos hoy (rol vigente, cuenta no dada de baja ni suspendida; una persona con '
  'los dos roles sale una vez), por apellido, nombre e id. Nada más: sin correo, teléfono, cédula ni rol. La llama un '
  'coordinador de p_campania_id o un administrador; una campaña terminada también se lee. Errores: 42501 sin permiso; CZ001 '
  'campaña inexistente.';

revoke all on function public.acompaniantes_del_panel(uuid) from public, anon, authenticated, service_role;
grant execute on function public.acompaniantes_del_panel(uuid) to authenticated;
