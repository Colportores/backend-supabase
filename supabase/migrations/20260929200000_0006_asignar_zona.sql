-- ============================================================================
-- 0006 · Asignar zona a un colportor de la campaña (HU-CAM-006)
--
-- El coordinador de la campaña (o un ADMIN) asigna o cambia la zona de un colportor
-- inscripto: campania_colportor.zona_id. Con eso mis_zonas() le abre esa zona (y deja de
-- abrirle la anterior) sin tocar nada más: la vigencia ya lee zona_id de la inscripción.
--
-- ## Mismo patrón que 0005
--
--   · motivo_campania_del_coordinador(campania): permiso + campaña existente + vigente. Es
--     el tramo que 0005 tenía adentro de motivo_rechazo_inscripcion(); ahora lo comparten
--     las dos reglas, con el mismo orden (el permiso antes que cualquier dato).
--   · motivo_rechazo_zona(campania, usuario, zona): las reglas de la HU. Interna.
--   · asignar_zona(campania, usuario, zona): el RPC que llama el BFF, SECURITY DEFINER, y
--     el ÚNICO camino para cambiar zona_id con JWT: un trigger rechaza el UPDATE directo
--     de zona_id que venga de `authenticated`.
--
-- ## Reglas (HU-CAM-006), en el orden en que se evalúan
--
--   SIN_PERMISO             ni ADMIN ni COORDINADOR; o COORDINADOR de otra campaña.
--   CAMPANIA_INEXISTENTE    la campaña no existe o está borrada.
--   CAMPANIA_NO_VIGENTE     "mi campaña": hoy fuera de fecha_inicio..fecha_fin.
--   NO_INSCRIPTO            "el colportor está en mi campaña": sin inscripción viva en esta
--                           campaña (o el usuario no existe o está dado de baja).
--   ZONA_INEXISTENTE        la zona no existe o está borrada.
--   ZONA_DE_OTRA_CIUDAD     "Zona debe pertenecer a una ciudad … que esté en la campaña" /
--                           "Edge -zona no pertenece a ciudades de la campaña".
--   ZONA_DE_OTRA_CAMPANIA   la zona pertenece a otra campaña concreta (esquema-datos:
--                           zona.campania_id = "si la zona pertenece a una campaña concreta").
--
-- ## La zona anterior
--
-- zona_id es una sola columna ("un colportor tiene 1 zona asignada por defecto"): asignar
-- reemplaza. mis_zonas() deja de devolver la anterior en la próxima consulta, salvo que siga
-- siendo su zona directa (usuario.zona_id). Asignar la misma zona que ya tiene no toca la
-- fila (no sube sync_version).
--
-- ## Por qué no se acota la política UPDATE de campania_colportor
--
-- Para esta HU alcanza con que zona_id solo cambie por el RPC (sección 3): el permiso sobre
-- la campaña y las reglas de la zona quedan en un solo lugar. La política UPDATE de 0003
-- sigue dejando a cualquier coordinador tocar meta_libros y hacer soft delete en
-- inscripciones de cualquier campaña: eso es de HU-CAM-005 (remover) y de la beca, y
-- acotarlo acá cambiaría flujos que esta HU no define.
--
-- ## Pendientes (no se deciden acá; ver front-coordinadores-web#20)
--
--   · usuario.zona_id ("zona directa", que mis_zonas() también suma) frente a
--     campania_colportor.zona_id: el 0001 dice que usuario.zona_id "lo asigna el coordinador
--     (HU-CAM-006)"; este RPC no lo toca.
--   · Impacto en el sync de la zona anterior (house_status, ubicaciones que el dispositivo
--     ya tiene) y cómo llega la asignación al dispositivo: campania_colportor no está en
--     sync.entidad, así que el delta pull no la entrega (HU-SYNC-002).
--   · Desasignar (dejar sin zona): la HU no lo pide; el RPC exige una zona.
--   · Notificación al colportor (HU-NOT): no hay Edge Function de push.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. Permiso sobre la campaña, compartido
-- ----------------------------------------------------------------------------

-- null si el usuario autenticado puede operar sobre p_campania_id como coordinador (es su
-- coordinador, o es ADMIN) y la campaña está vigente; si no, el motivo. Interna.
create function public.motivo_campania_del_coordinador(p_campania_id uuid)
returns text
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_campania public.campania;
  v_es_admin boolean := public.tiene_rol('ADMIN');
begin
  if auth.uid() is null or not (v_es_admin or public.tiene_rol('COORDINADOR')) then
    return 'SIN_PERMISO';
  end if;

  select * into v_campania from public.campania c where c.id = p_campania_id;
  if not found or v_campania.deleted_at is not null then
    return 'CAMPANIA_INEXISTENTE';
  end if;

  if not v_es_admin and v_campania.coordinador_id is distinct from auth.uid() then
    return 'SIN_PERMISO';
  end if;

  if not public.campania_vigente(v_campania) then
    return 'CAMPANIA_NO_VIGENTE';
  end if;

  return null;
end;
$$;

comment on function public.motivo_campania_del_coordinador(uuid) is
  'null si el usuario autenticado es ADMIN o el coordinador de p_campania_id y la campaña está '
  'vigente; si no, SIN_PERMISO | CAMPANIA_INEXISTENTE | CAMPANIA_NO_VIGENTE. Interna: la usan '
  'motivo_rechazo_inscripcion() y motivo_rechazo_zona().';

-- Misma firma, mismo resultado y mismo orden que en 0005: el tramo de permiso y campaña
-- pasa a motivo_campania_del_coordinador(). Lo verifica 0007_inscribir_colportor_test.
create or replace function public.motivo_rechazo_inscripcion(
  p_campania_id uuid, p_usuario_id uuid,
  out motivo text, out campania_en_conflicto uuid)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_usuario public.usuario;
begin
  motivo := public.motivo_campania_del_coordinador(p_campania_id);
  if motivo is not null then
    return;
  end if;

  select * into v_usuario from public.usuario u where u.id = p_usuario_id;
  if not found or v_usuario.deleted_at is not null then
    motivo := 'USUARIO_INEXISTENTE'; return;
  end if;

  -- confirmed_at y no email_confirmed_at: ver 0005.
  if not exists (select 1 from auth.users au
                  where au.id = p_usuario_id and au.confirmed_at is not null) then
    motivo := 'EMAIL_NO_VERIFICADO'; return;
  end if;

  if v_usuario.suspendido_en is not null then
    motivo := 'USUARIO_SUSPENDIDO'; return;
  end if;

  if exists (select 1 from public.campania_colportor cc
              where cc.campania_id = p_campania_id and cc.usuario_id = p_usuario_id
                and cc.deleted_at is null) then
    motivo := 'YA_INSCRIPTO'; return;
  end if;

  if exists (select 1 from public.campania_colportor cc
              where cc.campania_id = p_campania_id and cc.usuario_id = p_usuario_id) then
    motivo := 'INSCRIPCION_BORRADA'; return;
  end if;

  select v.campania_id into campania_en_conflicto
    from public.campanias_vigentes_de(p_usuario_id) v
    join public.campania c on c.id = v.campania_id
   where v.campania_id <> p_campania_id
   order by c.fecha_inicio desc
   limit 1;
  if found then
    motivo := 'EN_OTRA_CAMPANIA'; return;
  end if;
end;
$$;

-- ----------------------------------------------------------------------------
-- 2. Reglas de la asignación de zona
-- ----------------------------------------------------------------------------

create function public.motivo_rechazo_zona(p_campania_id uuid, p_usuario_id uuid, p_zona_id uuid)
returns text
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_motivo   text;
  v_campania public.campania;
  v_zona     public.zona;
begin
  v_motivo := public.motivo_campania_del_coordinador(p_campania_id);
  if v_motivo is not null then
    return v_motivo;
  end if;

  if not exists (select 1 from public.campania_colportor cc
                   join public.usuario u on u.id = cc.usuario_id
                  where cc.campania_id = p_campania_id and cc.usuario_id = p_usuario_id
                    and cc.deleted_at is null and u.deleted_at is null) then
    return 'NO_INSCRIPTO';
  end if;

  select * into v_zona from public.zona z where z.id = p_zona_id;
  if not found or v_zona.deleted_at is not null then
    return 'ZONA_INEXISTENTE';
  end if;

  select * into v_campania from public.campania c where c.id = p_campania_id;
  if v_zona.ciudad_id is distinct from v_campania.ciudad_id then
    return 'ZONA_DE_OTRA_CIUDAD';
  end if;

  if v_zona.campania_id is not null and v_zona.campania_id <> p_campania_id then
    return 'ZONA_DE_OTRA_CAMPANIA';
  end if;

  return null;
end;
$$;

comment on function public.motivo_rechazo_zona(uuid, uuid, uuid) is
  'HU-CAM-006: null si el usuario autenticado puede asignar p_zona_id a p_usuario_id en '
  'p_campania_id; si no, SIN_PERMISO | CAMPANIA_INEXISTENTE | CAMPANIA_NO_VIGENTE | NO_INSCRIPTO | '
  'ZONA_INEXISTENTE | ZONA_DE_OTRA_CIUDAD | ZONA_DE_OTRA_CAMPANIA. Interna: la llama asignar_zona().';

-- ----------------------------------------------------------------------------
-- 3. Guarda: zona_id solo cambia por asignar_zona()
-- ----------------------------------------------------------------------------

-- La política UPDATE (0003) deja a cualquier coordinador actualizar cualquier inscripción,
-- y el trigger de identidad (0005) deja pasar zona_id a propósito. Sin esto, un UPDATE
-- directo asigna una zona de otra ciudad, o la de una campaña ajena, salteando las reglas.
--
-- Se mira current_user y no auth.uid(): adentro de asignar_zona() (SECURITY DEFINER) el
-- JWT sigue presente, pero la sentencia corre como el dueño de la función. Un UPDATE que
-- llega por PostgREST corre como `authenticated`. service_role y los procesos servidor
-- (seeds, jobs) no son `authenticated` y pasan.
create function public.tg_campania_colportor_zona_por_rpc()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if current_user = 'authenticated' and new.zona_id is distinct from old.zona_id then
    raise exception 'la zona de una inscripción se asigna con asignar_zona() (HU-CAM-006)'
      using errcode = 'check_violation';
  end if;
  return new;
end;
$$;

create trigger campania_colportor_zona_por_rpc
  before update on public.campania_colportor
  for each row execute function public.tg_campania_colportor_zona_por_rpc();

-- ----------------------------------------------------------------------------
-- 4. asignar_zona() — el RPC que consume bff-coordinadores
-- ----------------------------------------------------------------------------

-- Códigos propios clase CZ ("colportores zona"), como los CI de 0005: PostgREST los
-- devuelve con HTTP 400 y el código en `code`; el BFF decide el status final (ADR-013).
-- Traduce un motivo de motivo_rechazo_zona() (o de motivo_campania_del_coordinador()) al
-- error del RPC; con null no hace nada. Interna.
create function public.lanzar_motivo_zona(p_motivo text)
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
      raise exception 'La zona no existe.' using errcode = 'CZ004';
    when 'ZONA_DE_OTRA_CIUDAD' then
      raise exception 'La zona no pertenece a la ciudad de la campaña.' using errcode = 'CZ005';
    when 'ZONA_DE_OTRA_CAMPANIA' then
      raise exception 'La zona pertenece a otra campaña.' using errcode = 'CZ006';
    else
      null;
  end case;
end;
$$;

create function public.asignar_zona(p_campania_id uuid, p_usuario_id uuid, p_zona_id uuid)
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

  -- El permiso primero: quien no lo tiene no llega a tomar locks sobre inscripciones.
  perform public.lanzar_motivo_zona(public.motivo_campania_del_coordinador(p_campania_id));

  -- Se bloquea la inscripción ANTES de las reglas, para que el chequeo y el UPDATE vean la
  -- misma fila. Sin esto, un soft delete concurrente commiteaba entre los dos: las reglas
  -- pasaban con su snapshot, el UPDATE reevaluaba deleted_at, afectaba 0 filas y el RPC
  -- devolvía éxito con la inscripción ya borrada (revisión de #20). La función es volátil:
  -- cada sentencia de abajo ve lo que se commiteó mientras esperaba el lock.
  perform 1 from public.campania_colportor cc
   where cc.campania_id = p_campania_id and cc.usuario_id = p_usuario_id
     and cc.deleted_at is null
     for update;

  perform public.lanzar_motivo_zona(public.motivo_rechazo_zona(p_campania_id, p_usuario_id, p_zona_id));

  -- Misma zona: no se toca la fila (no sube sync_version ni updated_at).
  update public.campania_colportor cc
     set zona_id = p_zona_id
   where cc.campania_id = p_campania_id and cc.usuario_id = p_usuario_id
     and cc.deleted_at is null
     and cc.zona_id is distinct from p_zona_id;
  get diagnostics v_filas = row_count;

  select * into v_fila from public.campania_colportor cc
   where cc.campania_id = p_campania_id and cc.usuario_id = p_usuario_id
     and cc.deleted_at is null;

  -- Red: si no se actualizó nada, solo es éxito si la inscripción sigue viva y ya tenía
  -- esa zona. Cualquier otra cosa (borrada, o un UPDATE que no se aplicó) es CZ003 y no
  -- una asignación que el BFF reportaría como hecha.
  if v_filas = 0 and (v_fila.id is null or v_fila.zona_id is distinct from p_zona_id) then
    perform public.lanzar_motivo_zona('NO_INSCRIPTO');
  end if;

  return v_fila;
end;
$$;

comment on function public.asignar_zona(uuid, uuid, uuid) is
  'HU-CAM-006: asigna p_zona_id a la inscripción de p_usuario_id en p_campania_id y devuelve la '
  'fila de campania_colportor. Errores: 42501 sin permiso; CZ001..CZ006 por regla (ver 0006).';

-- ----------------------------------------------------------------------------
-- 5. Privilegios
-- ----------------------------------------------------------------------------

revoke all on function public.motivo_campania_del_coordinador(uuid),
  public.motivo_rechazo_zona(uuid, uuid, uuid), public.lanzar_motivo_zona(text),
  public.asignar_zona(uuid, uuid, uuid), public.tg_campania_colportor_zona_por_rpc()
  from public, anon;

-- Internas: con EXECUTE, un coordinador sondearía datos de usuarios y zonas ajenos.
revoke all on function public.motivo_campania_del_coordinador(uuid),
  public.motivo_rechazo_zona(uuid, uuid, uuid), public.lanzar_motivo_zona(text) from authenticated;
grant execute on function public.motivo_campania_del_coordinador(uuid),
  public.motivo_rechazo_zona(uuid, uuid, uuid), public.lanzar_motivo_zona(text) to service_role;

grant execute on function public.asignar_zona(uuid, uuid, uuid) to authenticated, service_role;
