-- ============================================================================
-- 0007 · Lecturas del panel para HU-CAM-004 y HU-CAM-006
--
-- Los formularios de bff-coordinadores necesitan de dónde elegir (front-coordinadores-web
-- #19 y #20). Dos RPC de lectura, solo lo necesario:
--
--   zonas_asignables(campania)          zonas que asignar_zona() aceptaría para esa campaña.
--   colportores_de_campania(campania)   inscriptos vivos con su zona actual.
--
-- ## Patrón
--
-- SECURITY DEFINER + search_path vacío (no INVOKER): el permiso es el de
-- motivo_campania_del_coordinador() (interna, sin grant a authenticated: un invoker no
-- puede llamarla), y el coordinador no lee usuario/zona por RLS más allá de lo que
-- devuelve la función. El permiso es lo PRIMERO: sin JWT o sin rol, 42501 antes de tocar
-- datos. Errores como asignar_zona(), vía lanzar_motivo_zona(): CZ001 (campaña inexistente)
-- y CZ002 (no vigente); son las lecturas del formulario de esa acción.
--
-- ## Criterio de zonas_asignables
--
-- El de motivo_rechazo_zona(): zona viva, de la ciudad de la campaña (CZ005) y sin campaña
-- propia o de ESTA campaña (CZ006). Devuelve id, nombre y de_esta_campania (true si
-- zona.campania_id es esta campaña: el panel puede destacarlas). Sin polígono.
--
-- ## Datos de colportores_de_campania
--
-- usuario_id, nombre, apellido, zona_id, zona_nombre. SIN email ni nada más.
--
-- ## Pendientes (no se deciden acá)
--
--   · Nombre y apellido: se devuelven para poder elegir a quién asignar; si el coordinador
--     no debe verlos, lo decide Cristian.
--   · Búsqueda de candidatos a inscribir por email o nombre (HU-CAM-004): fuera de esta
--     migración; qué datos de cada cuenta ve el coordinador lo decide Cristian.
--   · Las dos exigen campaña vigente (como asignar_zona). Leer el equipo de campañas
--     pasadas o futuras, si hace falta, es otra pregunta.
-- ============================================================================

create function public.zonas_asignables(p_campania_id uuid)
returns table (id uuid, nombre text, de_esta_campania boolean)
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if auth.uid() is null then
    raise exception 'zonas_asignables requiere un usuario autenticado'
      using errcode = 'insufficient_privilege';
  end if;

  -- El permiso primero.
  perform public.lanzar_motivo_zona(public.motivo_campania_del_coordinador(p_campania_id));

  return query
    select z.id, z.nombre, (z.campania_id is not null)
      from public.zona z
      join public.campania c on c.id = p_campania_id
     where z.deleted_at is null
       and z.ciudad_id = c.ciudad_id
       and (z.campania_id is null or z.campania_id = p_campania_id)
     order by z.nombre, z.id;
end;
$$;

comment on function public.zonas_asignables(uuid) is
  'HU-CAM-006: zonas que asignar_zona() aceptaría en p_campania_id (ciudad de la campaña, sin '
  'campaña de otra). Errores: 42501 sin permiso; CZ001 inexistente; CZ002 no vigente.';

create function public.colportores_de_campania(p_campania_id uuid)
returns table (usuario_id uuid, nombre text, apellido text, zona_id uuid, zona_nombre text)
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if auth.uid() is null then
    raise exception 'colportores_de_campania requiere un usuario autenticado'
      using errcode = 'insufficient_privilege';
  end if;

  perform public.lanzar_motivo_zona(public.motivo_campania_del_coordinador(p_campania_id));

  return query
    select u.id, u.nombre, u.apellido, z.id, z.nombre
      from public.campania_colportor cc
      join public.usuario u on u.id = cc.usuario_id
      left join public.zona z on z.id = cc.zona_id and z.deleted_at is null
     where cc.campania_id = p_campania_id
       and cc.deleted_at is null and u.deleted_at is null
     order by u.apellido, u.nombre, u.id;
end;
$$;

comment on function public.colportores_de_campania(uuid) is
  'HU-CAM-004/006: inscriptos vivos de p_campania_id con su zona actual (sin email). Errores: '
  '42501 sin permiso; CZ001 inexistente; CZ002 no vigente.';

revoke all on function public.zonas_asignables(uuid), public.colportores_de_campania(uuid)
  from public, anon;
grant execute on function public.zonas_asignables(uuid), public.colportores_de_campania(uuid)
  to authenticated, service_role;
