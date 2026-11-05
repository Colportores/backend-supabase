-- ============================================================================
-- 0178 · La lista «¿Quién te acompaña?» baja al teléfono por el sync
--        (backend-supabase#254, casilla «Lista acomp.»; decisión de Cristian del 05/11 en docs-organizacion#76)
--
-- ## El caso
--
-- Ana, colportora de la campaña «Verano», termina una jornada y el teléfono le pregunta «¿Quién te acompañó?». La lista tiene
-- que traer a los coordinadores de su campaña (Luis y Daniel), con nombre y apellido. Hasta hoy el teléfono no tenía de dónde
-- sacarla: un colportor no puede leer `usuario` de otra persona (privacidad), y la lista del panel sale de una RPC que el
-- teléfono no llama.
--
-- ## Qué hace
--
--   1. La entidad de sync **`campania_coordinador`** (de solo bajada) baja al teléfono con `sigue_campanias`: cada persona recibe
--      los coordinadores de las campañas que ve en su mapa. Es la tabla de la 0174: una fila por (campaña, coordinador), con
--      el `usuario_id` (lo que el teléfono sube como `acompaniante_id` en la 0176) y la copia de `nombre` y `apellido`.
--   2. La política de lectura de esa tabla suma a la colportora: ve las filas de las campañas en las que está inscripta (viva),
--      **solo de quienes tienen hoy el rol COORDINADOR** (los administradores que no coordinan no aparecen: «sin
--      administradores»). El coordinador de la campaña ve a sus colegas; el ADMIN ve todo, como antes.
--   3. Qué NO baja: ni el correo ni el teléfono ni nada más del perfil. La tabla no tiene esas columnas (solo ids, nombre,
--      apellido y la maquinaria del sync): el nombre y el apellido son una copia que mantiene el servidor (0174).
--
-- ## Lo que NO hace
--
--   · No filtra por la campaña del colportor en el teléfono: el teléfono muestra los coordinadores de la campaña de su jornada
--     (las filas traen `campania_id`). Si deja una campaña, las filas ya bajadas quedan y no se actualizan.
--   · No toca `usuario`: nadie con JWT lee más de lo que leía.
--
-- ## Los datos
--
-- No toca filas: solo una función, una política y un registro del sync. Lo prueba supabase/tests/0178_… . Forward-only.
--
-- ## Para otros repos
--
--   · front-colportores-mobile#671: baja la entidad `campania_coordinador` (solo bajada, `sigue_campanias`) y arma la lista
--     «¿Quién te acompaña?» con ella; sube cada elegido como una fila de `jornada_acompaniante` (0176).
--   · docs-organizacion#172: el contrato del sync (§2, entidad nueva) y `esquema-datos.md`.
--
-- Forward-only: esta migración no se edita una vez aplicada.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. ¿La persona autenticada puede ver a ese coordinador de esa campaña?
-- ----------------------------------------------------------------------------

-- Solo contesta que sí si quien llama está inscripto (vivo) en esa campaña y el coordinador tiene hoy el rol COORDINADOR:
-- con cualquier otro uuid da false, así que no sirve para averiguar los roles de otra persona.
create function public.puedo_ver_al_coordinador(p_campania_id uuid, p_usuario_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
      from public.campania_colportor i
      join public.campania c on c.id = i.campania_id
      join public.usuario u on u.id = i.usuario_id
     where i.campania_id = p_campania_id
       and i.usuario_id = auth.uid()
       and i.deleted_at is null
       and c.deleted_at is null
       and u.deleted_at is null
       and u.suspendido_en is null)
    and public.cuenta_tiene_rol(p_usuario_id, 'COORDINADOR');
$$;

comment on function public.puedo_ver_al_coordinador(uuid, uuid) is
  'true si la persona autenticada tiene una inscripción viva en esa campaña (no dada de baja, campaña y cuenta activas) y '
  'ese usuario tiene hoy el rol COORDINADOR (0178). La usa la política de lectura de campania_coordinador para que la '
  'colportora vea a los coordinadores de su campaña, sin administradores. Una cuenta sin sesión, o sin inscripción en la '
  'campaña, da false: no sirve para averiguar los roles de otra persona.';

revoke all on function public.puedo_ver_al_coordinador(uuid, uuid) from public, anon, authenticated, service_role;
grant execute on function public.puedo_ver_al_coordinador(uuid, uuid) to authenticated, service_role;

-- ----------------------------------------------------------------------------
-- 2. La política de lectura
-- ----------------------------------------------------------------------------

alter policy campania_coordinador_select on public.campania_coordinador
  using (
    (select public.tiene_rol('ADMIN'))
    or usuario_id = (select auth.uid())
    or (select public.coordina_la_campania(campania_id))
    or (select public.puedo_ver_al_coordinador(campania_id, usuario_id)));

comment on table public.campania_coordinador is
  'Los coordinadores de cada campaña (0174, backend-supabase#254): una fila por (campaña, coordinador) con alta y baja '
  'lógica. La escribe el ADMIN (o el trigger que sigue la columna campania.coordinador_id). Copia nombre y apellido del '
  'perfil del coordinador (nunca correo ni teléfono) para que los lea quien no puede leer `usuario`: desde la 0178 baja al '
  'teléfono por el sync (solo bajada, sigue las campañas) y la colportora inscripta ve a los coordinadores de su campaña '
  '(solo quienes tienen el rol COORDINADOR, sin administradores).';

-- ----------------------------------------------------------------------------
-- 3. El registro del sync
-- ----------------------------------------------------------------------------

insert into sync.entidad (nombre, tabla, columna_pk, permite_push, sigue_campanias)
values ('campania_coordinador', 'public.campania_coordinador'::regclass, 'id', false, true);
