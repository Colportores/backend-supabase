-- ============================================================================
-- 0012 · Zonas: la baja desasigna, «Quitar» deja sin zona y se rechazan los suspendidos
--        (backend-supabase#38)
--
-- Decisiones de Cristian del 30/09 en front-coordinadores-web#28 (punto 3, «Eliminar zona») y
-- front-coordinadores-web#20 (puntos 2 y 4, pendientes de HU-CAM-006):
--
--   · baja_zona() ya no se rechaza con colportores asignados (CZ010, S56): los deja sin zona
--     (campania_colportor.zona_id = null) y devuelve cuántos y quiénes, para el aviso «N
--     colportores quedan sin zona». Las ubicaciones no se tocan: la zona es solo visual (0011).
--   · quitar_zona(campania, usuario), un RPC nuevo: «Quitar» en la vista 24. El colportor queda
--     sin zona y vuelve a «Sin zona» (el panel avisa «<nombre> quedó sin zona.»). Es la misma
--     regla que al eliminar una zona.
--   · asignar_zona() rechaza una cuenta suspendida con un código nuevo, CZ014: «Cuenta
--     suspendida. Pedile a un administrador que la reactive.». Si ya tenía zona, la conserva:
--     el rechazo no toca la inscripción, y suspender no quita la zona. La lista del panel ya lo
--     muestra marcado (colportores_de_campania().suspendido, 0007).
--
-- ## La baja
--
-- Las inscripciones VIVAS con esa zona quedan sin zona, en la misma transacción que la baja y
-- con la zona tomada FOR UPDATE: un asignar_zona() concurrente a esa zona (que la toma FOR
-- SHARE, 0008) espera y después ve la zona dada de baja (CZ004). Ahora que la baja escribe
-- inscripciones, asignar_zona() toma la zona antes que la inscripción (el mismo orden que la
-- baja): al revés, reasignar la misma zona durante la baja era un deadlock. quitar_zona() no
-- toma la zona. La lista y el conteo salen del
-- UPDATE (RETURNING), no de una consulta previa: son exactamente los que quedaron sin zona.
-- Cuentan solo los usuarios vivos, como la lista de la vista previa y la del panel; la
-- inscripción viva de un usuario dado de baja también queda sin zona, para que no apunte a una
-- zona muerta. Una inscripción dada de baja conserva su zona: al reactivarla, el trigger de 0009
-- pide reactivarla sin zona (no se le borra en silencio).
-- Devuelve lo mismo que antes y una clave nueva:
--   colportores_asignados  en la vista previa, quiénes quedarían sin zona; al dar de baja,
--                          quiénes quedaron (antes, siempre []).
--   colportores_sin_zona   cuántos (la longitud de la lista).
-- CZ010 deja de usarse; el código no se reutiliza.
--
-- ## quitar_zona()
--
-- Mismo patrón que asignar_zona() (0006): permiso sobre la campaña primero
-- (motivo_campania_del_coordinador(): 42501, CZ001, CZ002), la inscripción FOR UPDATE y
-- después la regla (NO_INSCRIPTO, CZ003). Las reglas de la zona no aplican: null («sin zona»)
-- siempre es válido (el trigger de 0009 también lo deja pasar). Quitarle la zona a quien no
-- tiene no toca la fila (no sube sync_version), como asignar la misma zona. Una cuenta
-- suspendida sí se puede quitar: la decisión solo rechaza asignarle.
-- Cumple lo que pidió la revisión de #20: un RPC definer que cambia zona_id pasa por el permiso
-- y la regla de la inscripción, no solo por la guarda de `authenticated` (0006).
--
-- ## Suspendidos
--
-- USUARIO_SUSPENDIDO se evalúa después de NO_INSCRIPTO y antes de las reglas de la zona: es
-- un dato de la persona, y el aviso no depende de qué zona se eligió. asignar_zona() toma la
-- fila de usuario FOR SHARE antes de las reglas, así una suspensión concurrente espera a que
-- termine la asignación, o la asignación ve la suspensión. Reasignarle la zona que ya tiene
-- también se rechaza (la asignación se rechaza siempre), y la zona queda como estaba.
--
-- ## Para otros repos
--
--   · bff-coordinadores: endpoint de quitar_zona(), CZ014 (409, estado de la cuenta) en
--     asignar, y colportores_sin_zona en la baja.
--
-- Forward-only: esta migración no se edita una vez aplicada.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. Reglas de la asignación: la cuenta suspendida
-- ----------------------------------------------------------------------------

-- Igual que en 0008, más USUARIO_SUSPENDIDO después de NO_INSCRIPTO.
create or replace function public.motivo_rechazo_zona(p_campania_id uuid, p_usuario_id uuid, p_zona_id uuid)
returns text
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_motivo     text;
  v_zona       public.zona;
  v_cc         public.campania_ciudad;
  v_suspendido boolean;
begin
  v_motivo := public.motivo_campania_del_coordinador(p_campania_id);
  if v_motivo is not null then
    return v_motivo;
  end if;

  select u.suspendido_en is not null
    into v_suspendido
    from public.campania_colportor cc
    join public.usuario u on u.id = cc.usuario_id
   where cc.campania_id = p_campania_id and cc.usuario_id = p_usuario_id
     and cc.deleted_at is null and u.deleted_at is null;
  if not found then
    return 'NO_INSCRIPTO';
  end if;
  if v_suspendido then
    return 'USUARIO_SUSPENDIDO';
  end if;

  select * into v_zona from public.zona z where z.id = p_zona_id;
  if not found or v_zona.deleted_at is not null then
    return 'ZONA_INEXISTENTE';
  end if;

  select * into v_cc from public.campania_ciudad cc where cc.id = v_zona.campania_ciudad_id;
  if v_cc.campania_id <> p_campania_id then
    return 'ZONA_DE_OTRA_CAMPANIA';
  end if;
  if v_cc.deleted_at is not null then
    return 'ZONA_DE_OTRA_CIUDAD';
  end if;

  return null;
end;
$$;

comment on function public.motivo_rechazo_zona(uuid, uuid, uuid) is
  'HU-CAM-006: null si el usuario autenticado puede asignar p_zona_id a p_usuario_id en '
  'p_campania_id; si no, SIN_PERMISO | CAMPANIA_INEXISTENTE | CAMPANIA_NO_VIGENTE | NO_INSCRIPTO | '
  'USUARIO_SUSPENDIDO | ZONA_INEXISTENTE | ZONA_DE_OTRA_CIUDAD | ZONA_DE_OTRA_CAMPANIA. Interna: la '
  'llama asignar_zona().';

-- Igual que en 0009, más CZ014.
create or replace function public.lanzar_motivo_zona(p_motivo text)
returns void
language plpgsql
set search_path = ''
as $$
begin
  case p_motivo
    when 'SIN_PERMISO' then
      raise exception 'Solo el coordinador de la campaña puede asignar zonas en ella.'
        using errcode = 'insufficient_privilege';
    when 'CAMPANIA_INEXISTENTE' then
      raise exception 'La campaña no existe.' using errcode = 'CZ001';
    when 'CAMPANIA_NO_VIGENTE' then
      raise exception 'La campaña no está activa.' using errcode = 'CZ002';
    when 'NO_INSCRIPTO' then
      raise exception 'El colportor no está en esta campaña.' using errcode = 'CZ003';
    when 'ZONA_INEXISTENTE' then
      raise exception 'La zona no existe o ya se dio de baja. Recargá el mapa.' using errcode = 'CZ004';
    when 'ZONA_DE_OTRA_CIUDAD' then
      raise exception 'La zona no pertenece a la ciudad de la campaña.' using errcode = 'CZ005';
    when 'ZONA_DE_OTRA_CAMPANIA' then
      raise exception 'La zona pertenece a otra campaña.' using errcode = 'CZ006';
    when 'USUARIO_SUSPENDIDO' then
      raise exception 'Cuenta suspendida. Pedile a un administrador que la reactive.' using errcode = 'CZ014';
    else
      null;
  end case;
end;
$$;

-- Igual que en 0009, más la fila de usuario FOR SHARE antes de las reglas (ver la cabecera), y
-- la zona se toma antes que la inscripción (abajo).
create or replace function public.asignar_zona(p_campania_id uuid, p_usuario_id uuid, p_zona_id uuid)
returns public.campania_colportor
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_filas integer;
  v_fila  public.campania_colportor;
begin
  if auth.uid() is null then
    raise exception 'asignar_zona requiere un usuario autenticado'
      using errcode = 'insufficient_privilege';
  end if;

  perform public.lanzar_motivo_zona(public.motivo_campania_del_coordinador(p_campania_id));

  -- La zona ANTES que la inscripción, en el mismo orden que baja_zona() (zona FOR UPDATE y
  -- después las inscripciones con esa zona). Al revés, reasignarle a alguien la zona que ya
  -- tiene mientras se da de baja era un deadlock: esto tenía la inscripción y esperaba la
  -- zona, y la baja tenía la zona y esperaba la inscripción.
  perform 1 from public.zona z where z.id = p_zona_id for share;

  perform 1 from public.campania_colportor cc
   where cc.campania_id = p_campania_id and cc.usuario_id = p_usuario_id
     and cc.deleted_at is null
     for update;

  perform 1 from public.usuario u where u.id = p_usuario_id for share;

  perform public.lanzar_motivo_zona(public.motivo_rechazo_zona(p_campania_id, p_usuario_id, p_zona_id),
                                    p_campania_id);

  update public.campania_colportor cc
     set zona_id = p_zona_id
   where cc.campania_id = p_campania_id and cc.usuario_id = p_usuario_id
     and cc.deleted_at is null
     and cc.zona_id is distinct from p_zona_id;
  get diagnostics v_filas = row_count;

  select * into v_fila from public.campania_colportor cc
   where cc.campania_id = p_campania_id and cc.usuario_id = p_usuario_id
     and cc.deleted_at is null;

  if v_filas = 0 and (v_fila.id is null or v_fila.zona_id is distinct from p_zona_id) then
    perform public.lanzar_motivo_zona('NO_INSCRIPTO');
  end if;

  return v_fila;
end;
$$;

comment on function public.asignar_zona(uuid, uuid, uuid) is
  'HU-CAM-006: asigna p_zona_id a la inscripción de p_usuario_id en p_campania_id y devuelve la '
  'fila de campania_colportor. Errores: 42501 sin permiso; CZ001..CZ006 por regla; CZ014 cuenta '
  'suspendida (conserva la zona que tenía).';

-- ----------------------------------------------------------------------------
-- 2. quitar_zona() — «Quitar» en la vista 24
-- ----------------------------------------------------------------------------

create function public.quitar_zona(p_campania_id uuid, p_usuario_id uuid)
returns public.campania_colportor
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_fila public.campania_colportor;
begin
  if auth.uid() is null then
    raise exception 'quitar_zona requiere un usuario autenticado'
      using errcode = 'insufficient_privilege';
  end if;

  -- El permiso primero: quien no lo tiene no llega a tomar locks sobre inscripciones.
  perform public.lanzar_motivo_zona(public.motivo_campania_del_coordinador(p_campania_id));

  -- La inscripción FOR UPDATE antes de la regla, como asignar_zona(): una baja o una
  -- asignación concurrente esperan, y la regla ve la misma fila que el UPDATE.
  select cc.* into v_fila
    from public.campania_colportor cc
    join public.usuario u on u.id = cc.usuario_id
   where cc.campania_id = p_campania_id and cc.usuario_id = p_usuario_id
     and cc.deleted_at is null and u.deleted_at is null
     for update of cc;
  if not found then
    perform public.lanzar_motivo_zona('NO_INSCRIPTO');
  end if;

  -- Sin zona ya: no se toca la fila (no sube sync_version ni updated_at).
  if v_fila.zona_id is not null then
    update public.campania_colportor cc
       set zona_id = null
     where cc.id = v_fila.id
    returning * into v_fila;
  end if;

  return v_fila;
end;
$$;

comment on function public.quitar_zona(uuid, uuid) is
  'HU-CAM-006, «Quitar» en la vista 24 (decisión del 30/09, front-coordinadores-web#20): deja sin '
  'zona la inscripción de p_usuario_id en p_campania_id y devuelve la fila de campania_colportor. '
  'Sin zona ya, la devuelve igual. Errores: 42501 sin permiso; CZ001 campaña inexistente; CZ002 no '
  'vigente; CZ003 no inscripto.';

-- ----------------------------------------------------------------------------
-- 3. baja_zona(): los asignados quedan sin zona
-- ----------------------------------------------------------------------------

-- Misma firma que en 0011. La vista previa no cambia (más colportores_sin_zona); la baja ya no
-- se rechaza con asignados (CZ010): los deja sin zona y los devuelve.
create or replace function public.baja_zona(p_zona_id uuid, p_vista_previa boolean default false)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_zona       public.zona;
  v_cc         public.campania_ciudad;
  v_asignados  jsonb;
  v_incluidas  integer;
begin
  if auth.uid() is null then
    raise exception 'baja_zona requiere un usuario autenticado'
      using errcode = 'insufficient_privilege';
  end if;

  if not (public.tiene_rol('ADMIN') or public.tiene_rol('COORDINADOR')) then
    perform public.lanzar_motivo_mapa('SIN_PERMISO');
  end if;

  select * into v_zona from public.zona z where z.id = p_zona_id;
  if not found then
    perform public.lanzar_motivo_mapa('ZONA_INEXISTENTE');
  end if;
  select * into v_cc from public.campania_ciudad cc where cc.id = v_zona.campania_ciudad_id;
  perform public.lanzar_motivo_mapa(public.motivo_mapa_de_campania(v_cc.campania_id));

  perform public.bloquear_mapa(v_cc.id);
  select * into v_zona from public.zona z where z.id = p_zona_id for update;
  if v_zona.deleted_at is not null then
    perform public.lanzar_motivo_mapa('ZONA_INEXISTENTE');
  end if;

  v_incluidas := public.zona_ubicaciones_incluidas(v_cc.id, v_zona.poligono_geojson);

  if p_vista_previa then
    -- Quiénes quedarían sin zona: las inscripciones vivas con esta zona, de usuarios vivos.
    select jsonb_agg(jsonb_build_object('usuario_id', u.id, 'nombre', u.nombre, 'apellido', u.apellido)
                     order by u.apellido, u.nombre, u.id)
      into v_asignados
      from public.usuario u
     where u.deleted_at is null
       and exists (select 1 from public.campania_colportor ins
                    where ins.usuario_id = u.id and ins.zona_id = p_zona_id
                      and ins.deleted_at is null);

    return jsonb_build_object('dada_de_baja', false, 'zona', to_jsonb(v_zona) - 'xmin_w',
                              'colportores_asignados', coalesce(v_asignados, '[]'::jsonb),
                              'colportores_sin_zona', coalesce(jsonb_array_length(v_asignados), 0),
                              'ubicaciones_incluidas', v_incluidas);
  end if;

  -- Los asignados quedan sin zona. La lista sale del UPDATE: son los que quedaron.
  with sin_zona as (
    update public.campania_colportor ins
       set zona_id = null
     where ins.zona_id = p_zona_id
       and ins.deleted_at is null
    returning ins.usuario_id
  )
  select jsonb_agg(jsonb_build_object('usuario_id', u.id, 'nombre', u.nombre, 'apellido', u.apellido)
                   order by u.apellido, u.nombre, u.id)
    into v_asignados
    from public.usuario u
   where u.deleted_at is null
     and u.id in (select s.usuario_id from sin_zona s);

  update public.zona z set deleted_at = now() where z.id = p_zona_id
  returning * into v_zona;
  update public.zona_vertice v set deleted_at = now()
   where v.zona_id = p_zona_id and v.deleted_at is null;

  return jsonb_build_object('dada_de_baja', true, 'zona', to_jsonb(v_zona) - 'xmin_w',
                            'colportores_asignados', coalesce(v_asignados, '[]'::jsonb),
                            'colportores_sin_zona', coalesce(jsonb_array_length(v_asignados), 0),
                            'ubicaciones_incluidas', v_incluidas);
end;
$$;

comment on function public.baja_zona(uuid, boolean) is
  'Vista 24, «Eliminar zona»: baja lógica de la zona y sus vértices. Los colportores asignados '
  'quedan sin zona (decisión del 30/09, front-coordinadores-web#28): devuelve quiénes '
  '(colportores_asignados) y cuántos (colportores_sin_zona); con p_vista_previa, quiénes quedarían. '
  'Las ubicaciones no se tocan (ubicaciones_incluidas es el «Incluye N»). Errores: 42501; CZ001, '
  'CZ004, CZ011.';

-- ----------------------------------------------------------------------------
-- 4. Privilegios
-- ----------------------------------------------------------------------------

-- `authenticated` también en el revoke: en una base creada desde cero los default privileges de
-- la imagen le dan EXECUTE sobre cada función nueva de public (ver 0008). El RPC decide el
-- permiso adentro.
revoke all on function public.quitar_zona(uuid, uuid) from public, anon, authenticated;
grant execute on function public.quitar_zona(uuid, uuid) to authenticated, service_role;
