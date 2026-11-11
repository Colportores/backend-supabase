-- ============================================================================
-- 0005 · Inscribir un colportor en una campaña (HU-CAM-004)
--
-- El coordinador inscribe a un colportor en su campaña vigente. Con eso la cuenta sale
-- de PENDIENTE_ASIGNACION sola: estado_cuenta() (0004) lo deriva de campania_colportor.
--
-- ## Cómo se reparte
--
--   · motivo_rechazo_inscripcion(campania, usuario): la ÚNICA definición de qué
--     inscripción es válida y quién la puede hacer. Su columna `motivo` es null si se puede.
--     Interna: no la ejecuta authenticated (serviría para sondear datos de cualquier usuario).
--   · inscribir_colportor(campania, usuario): el RPC que llama el BFF, y el ÚNICO camino
--     para inscribir con JWT. Toma un lock por usuario, pide el motivo, responde un error
--     específico por regla e inserta.
--   · La política INSERT de campania_colportor desaparece: sin política, la RLS niega el
--     INSERT directo a authenticated (ADMIN incluido).
--
-- ## Por qué SECURITY DEFINER y un solo camino
--
-- Con un INSERT directo abierto (política con las mismas reglas), dos coordinadores que
-- inscriben a la misma persona a la vez en campañas distintas pasan los dos el chequeo
-- EN_OTRA_CAMPANIA: la política evalúa con el snapshot del INSERT y no puede tomar el
-- lock. La regla "una campaña vigente por colportor" solo se sostiene si toda inscripción
-- pasa por el lock, y eso exige un único camino. Como el INSERT directo queda cerrado, el
-- RPC tiene que ser DEFINER para poder insertar; el permiso lo decide motivo_…() como
-- primer chequeo, antes que cualquier dato del usuario objetivo. Mismo patrón que
-- tiene_rol()/mis_zonas(): definer, search_path vacío, identidad desde auth.uid().
--
-- ## Reglas (HU-CAM-004), en el orden en que se evalúan
--
--   SIN_PERMISO           ni ADMIN ni COORDINADOR; o COORDINADOR de otra campaña.
--   CAMPANIA_INEXISTENTE  la campaña no existe o está borrada.
--   CAMPANIA_NO_VIGENTE   "mi campaña activa": hoy fuera de fecha_inicio..fecha_fin.
--   USUARIO_INEXISTENTE   el usuario no existe o está dado de baja (SOFT_DELETED).
--   EMAIL_NO_VERIFICADO   "solo PENDIENTE_ASIGNACION o ACTIVA": no PENDIENTE_VERIFICACION_EMAIL.
--   USUARIO_SUSPENDIDO    "Edge -usuario suspendido": usuario.suspendido_en no es null.
--   YA_INSCRIPTO          ya tiene una inscripción viva en esta campaña.
--   INSCRIPCION_BORRADA   tiene una inscripción borrada en esta campaña (ver pendientes).
--   EN_OTRA_CAMPANIA      "Está en campaña X. Reasignar primero." (HU-CAM-005).
--
-- El permiso va primero a propósito: un colportor o un coordinador ajeno recibe
-- SIN_PERMISO y no puede sondear si alguien está suspendido o en qué campaña está.
--
-- ## Pendientes (no se deciden acá; ver front-coordinadores-web#19)
--
--   · Rol COLPORTOR del inscripto: la HU no lo pide y nadie lo asigna hoy (el alta no
--     crea usuario_rol), así que exigirlo bloquearía a toda cuenta pendiente. No se exige.
--   · Inscripción borrada en la misma campaña: unique (campania_id, usuario_id) impide
--     crear otra. ¿Se reactiva la borrada? Hoy: rechazo INSCRIPCION_BORRADA.
--   · Dos campañas a la vez: se bloquea solo si la otra está vigente HOY (la HU dice
--     "otra campaña activa"). Una inscripción en una campaña futura no bloquea.
--   · "fecha_inicio" de la inscripción (HU-CAM-004) y "fecha_fin" (HU-CAM-005) no existen
--     en campania_colportor; la vigencia sale de las fechas de la campaña. created_at
--     registra cuándo se inscribió.
--   · Notificación (HU-NOT-003) y audit log: no hay tabla de auditoría ni Edge Function.
--   · UPDATE de campania_colportor: la política sigue dejando a cualquier coordinador
--     actualizar cualquier fila (HU-CAM-005/006 la van a acotar). Lo único que se cierra
--     acá es lo que equivale a inscribir salteándose las reglas: cambiar campania_id o
--     usuario_id, y reactivar una inscripción borrada (deleted_at → null).
--   · Campañas futuras: solo se inscribe en una campaña vigente, así que ni el ADMIN ni el
--     coordinador pueden precargar el equipo antes de que arranque.
--   · EMAIL_NO_VERIFICADO mira auth.users.confirmed_at = least(email_confirmed_at,
--     phone_confirmed_at): deja de equivaler al email si se habilita el login por teléfono.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. Vigencia: una sola definición
-- ----------------------------------------------------------------------------

-- Vigencia de una campaña. La usan la vigencia de una inscripción (abajo) y la regla
-- CAMPANIA_NO_VIGENTE. Interna: solo la llaman funciones SECURITY DEFINER.
create function public.campania_vigente(p_campania public.campania)
returns boolean
language sql
stable
set search_path = ''
as $$
  select p_campania.deleted_at is null
     and p_campania.fecha_inicio <= current_date
     and (p_campania.fecha_fin is null or p_campania.fecha_fin >= current_date);
$$;

-- Inscripciones vigentes de CUALQUIER usuario. Recibe el usuario por parámetro, así que no
-- se otorga a authenticated: un colportor podría averiguar en qué campaña está otro. La
-- llaman mis_campanias_vigentes() (con auth.uid()) y motivo_rechazo_inscripcion(), que
-- son SECURITY DEFINER y corren como su dueño.
create function public.campanias_vigentes_de(p_usuario uuid)
returns table (campania_id uuid, zona_id uuid)
language sql
stable
security definer
set search_path = ''
as $$
  select cc.campania_id, cc.zona_id
    from public.campania_colportor cc
    join public.usuario u on u.id = cc.usuario_id
    join public.campania c on c.id = cc.campania_id
   where cc.usuario_id = p_usuario
     and cc.deleted_at is null
     and u.deleted_at is null
     and public.campania_vigente(c);
$$;

comment on function public.campanias_vigentes_de(uuid) is
  'Inscripciones vigentes hoy de un usuario (campania_colportor no borrada, usuario no dado de '
  'baja, campania_vigente()). Única definición de "vigente". Interna: no la ejecuta authenticated.';

-- Misma firma y mismo resultado que en 0004: ahora delega en campanias_vigentes_de().
create or replace function public.mis_campanias_vigentes()
returns table (campania_id uuid, zona_id uuid)
language sql
stable
security definer
set search_path = ''
as $$
  select v.campania_id, v.zona_id from public.campanias_vigentes_de(auth.uid()) v;
$$;

-- ----------------------------------------------------------------------------
-- 2. Reglas de la inscripción
-- ----------------------------------------------------------------------------

-- SECURITY DEFINER: lee la inscripción ajena, auth.users y el rol del llamador sin depender
-- de la RLS del que pregunta. Solo contesta sobre el usuario objetivo a quien ya pasó el
-- permiso (ADMIN, o el coordinador de esa campaña). Aun así es interna: si authenticated
-- la pudiera llamar, un coordinador sondearía con su campaña si cualquier usuario verificó
-- el email (auth.users no la lee nadie más). La llama solo inscribir_colportor().
--
-- Devuelve dos columnas: `motivo` (null = se puede) y, solo con EN_OTRA_CAMPANIA, la
-- campaña en conflicto, para que el RPC arme "Está en campaña X" sin volver a calcular la
-- vigencia.
create function public.motivo_rechazo_inscripcion(
  p_campania_id uuid, p_usuario_id uuid,
  out motivo text, out campania_en_conflicto uuid)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_campania public.campania;
  v_usuario  public.usuario;
  v_es_admin boolean := public.tiene_rol('ADMIN');
begin
  if auth.uid() is null or not (v_es_admin or public.tiene_rol('COORDINADOR')) then
    motivo := 'SIN_PERMISO'; return;
  end if;

  select * into v_campania from public.campania c where c.id = p_campania_id;
  if not found or v_campania.deleted_at is not null then
    motivo := 'CAMPANIA_INEXISTENTE'; return;
  end if;

  if not v_es_admin and v_campania.coordinador_id is distinct from auth.uid() then
    motivo := 'SIN_PERMISO'; return;
  end if;

  if not public.campania_vigente(v_campania) then
    motivo := 'CAMPANIA_NO_VIGENTE'; return;
  end if;

  select * into v_usuario from public.usuario u where u.id = p_usuario_id;
  if not found or v_usuario.deleted_at is not null then
    motivo := 'USUARIO_INEXISTENTE'; return;
  end if;

  -- confirmed_at y no email_confirmed_at: en el cloud es la columna generada
  -- least(email_confirmed_at, phone_confirmed_at) —no hay login por teléfono, así que es la
  -- del email—, y es la única de las dos que existe en la imagen local de CI.
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

  -- Si hubiera más de una (hoy nada lo impide para campañas futuras que ya empezaron), se
  -- nombra la más reciente.
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

comment on function public.motivo_rechazo_inscripcion(uuid, uuid) is
  'HU-CAM-004: motivo null si el usuario autenticado puede inscribir a p_usuario_id en '
  'p_campania_id; si no, el motivo (SIN_PERMISO, CAMPANIA_INEXISTENTE, CAMPANIA_NO_VIGENTE, USUARIO_INEXISTENTE, '
  'EMAIL_NO_VERIFICADO, USUARIO_SUSPENDIDO, YA_INSCRIPTO, INSCRIPCION_BORRADA, EN_OTRA_CAMPANIA; '
  'con este último, campania_en_conflicto). '
  'Única definición de las reglas. Interna: la llama inscribir_colportor().';

-- ----------------------------------------------------------------------------
-- 3. RLS: sin INSERT directo
-- ----------------------------------------------------------------------------

-- Antes: cualquier ADMIN o COORDINADOR insertaba cualquier fila, en cualquier campaña y
-- sin reglas. Ahora no hay política INSERT para authenticated, así que la RLS lo niega
-- (también al ADMIN, que inscribe por el RPC con su permiso sobre cualquier campaña y las
-- mismas reglas). Ver "Por qué SECURITY DEFINER y un solo camino" en el header.
-- service_role y los procesos servidor (bypass de RLS) siguen insertando directo.
drop policy campania_colportor_insert_staff on public.campania_colportor;

-- ----------------------------------------------------------------------------
-- 4. Guarda: un UPDATE no puede equivaler a inscribir
-- ----------------------------------------------------------------------------

-- La política UPDATE (0003) deja a cualquier coordinador actualizar cualquier inscripción;
-- acotarla es de HU-CAM-005/006. Lo que se cierra acá es lo que convierte un UPDATE en una
-- inscripción nueva salteándose motivo_rechazo_inscripcion():
--   · cambiar campania_id o usuario_id: HU-CAM-005 define reasignar como cerrar la
--     inscripción y abrir otra;
--   · reactivar una borrada (deleted_at → null): se saltearía SIN_PERMISO, la suspensión y
--     EN_OTRA_CAMPANIA, y si se reactiva o no está pendiente de decisión (INSCRIPCION_BORRADA).
-- Falla con error en vez de coercionar en silencio como las guardas del 0001:
-- campania_colportor no entra por el push de sync, así que no hay un cliente LWW que mande
-- la fila entera, y un cambio así ignorado en silencio sería peor. El resto del UPDATE
-- (zona_id, meta_libros, soft delete) pasa.
create function public.tg_campania_colportor_identidad()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if auth.uid() is null then
    return new;
  end if;

  if new.campania_id is distinct from old.campania_id
     or new.usuario_id is distinct from old.usuario_id then
    raise exception 'una inscripción no cambia de campaña ni de usuario: cerrala y abrí otra (HU-CAM-005)'
      using errcode = 'check_violation';
  end if;

  if old.deleted_at is not null and new.deleted_at is null then
    raise exception 'una inscripción borrada no se reactiva (decisión pendiente, front-coordinadores-web#19)'
      using errcode = 'check_violation';
  end if;

  return new;
end;
$$;

create trigger campania_colportor_identidad
  before update on public.campania_colportor
  for each row execute function public.tg_campania_colportor_identidad();

-- ----------------------------------------------------------------------------
-- 5. inscribir_colportor() — el RPC que consume bff-coordinadores
-- ----------------------------------------------------------------------------

-- Códigos de error propios (clase CI, "colportores inscripción", que Postgres no usa) para
-- que el BFF distinga cada regla sin parsear mensajes. PostgREST los devuelve con HTTP
-- 400 y el código en `code`; el BFF decide el status final (ADR-013). El mensaje es el
-- texto para la UI, con el literal de la HU cuando lo hay.
--
-- SECURITY DEFINER: es el único camino para inscribir con JWT (sección 3). El permiso no
-- lo da la RLS sino motivo_rechazo_inscripcion(), que lo evalúa primero; la identidad sale
-- de auth.uid(), nunca de un parámetro.
create function public.inscribir_colportor(p_campania_id uuid, p_usuario_id uuid)
returns public.campania_colportor
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_motivo    text;
  v_conflicto uuid;
  v_otra      public.campania;
  v_fila      public.campania_colportor;
begin
  if auth.uid() is null then
    raise exception 'inscribir_colportor requiere un usuario autenticado'
      using errcode = 'insufficient_privilege';
  end if;

  -- Serializa las inscripciones de un mismo usuario: sin esto, dos coordinadores que lo
  -- inscriben a la vez en campañas distintas pasan los dos el chequeo EN_OTRA_CAMPANIA.
  -- La función es volátil, así que cada sentencia de abajo ve lo que el otro commiteó.
  -- Alcanza porque no hay otro camino con JWT (sección 3).
  perform pg_advisory_xact_lock(hashtextextended('inscribir_colportor:' || p_usuario_id::text, 0));

  select m.motivo, m.campania_en_conflicto into v_motivo, v_conflicto
    from public.motivo_rechazo_inscripcion(p_campania_id, p_usuario_id) m;

  case v_motivo
    when 'SIN_PERMISO' then
      raise exception 'Solo el coordinador de la campaña puede inscribir colportores en ella.'
        using errcode = 'insufficient_privilege';
    when 'CAMPANIA_INEXISTENTE' then
      raise exception 'La campaña no existe.' using errcode = 'CI001';
    when 'CAMPANIA_NO_VIGENTE' then
      raise exception 'La campaña no está activa: solo se inscribe en una campaña vigente.'
        using errcode = 'CI002';
    when 'USUARIO_INEXISTENTE' then
      raise exception 'El usuario no existe o fue dado de baja.' using errcode = 'CI003';
    when 'EMAIL_NO_VERIFICADO' then
      raise exception 'El usuario todavía no verificó su email.' using errcode = 'CI004';
    when 'USUARIO_SUSPENDIDO' then
      raise exception 'La cuenta está suspendida. Contactá al administrador.' using errcode = 'CI005';
    when 'YA_INSCRIPTO' then
      raise exception 'Ya está inscripto en esta campaña.' using errcode = 'CI006';
    when 'EN_OTRA_CAMPANIA' then
      select * into v_otra from public.campania c where c.id = v_conflicto;
      raise exception 'Está en campaña %. Reasignar primero.', v_otra.nombre
        using errcode = 'CI007',
              detail = json_build_object('campania_id', v_otra.id, 'campania_nombre', v_otra.nombre)::text;
    when 'INSCRIPCION_BORRADA' then
      raise exception 'Tiene una inscripción dada de baja en esta campaña.' using errcode = 'CI008';
    else
      null;
  end case;

  insert into public.campania_colportor (campania_id, usuario_id, created_by)
  values (p_campania_id, p_usuario_id, auth.uid())
  returning * into v_fila;

  return v_fila;
end;
$$;

comment on function public.inscribir_colportor(uuid, uuid) is
  'HU-CAM-004: inscribe a p_usuario_id en p_campania_id y devuelve la fila de campania_colportor. '
  'Errores: 42501 sin permiso; CI001..CI008 por regla (ver 0005). La cuenta pasa a ACTIVA sola.';

-- ----------------------------------------------------------------------------
-- 6. Privilegios
-- ----------------------------------------------------------------------------

revoke all on function public.campania_vigente(public.campania), public.campanias_vigentes_de(uuid),
  public.motivo_rechazo_inscripcion(uuid, uuid), public.inscribir_colportor(uuid, uuid),
  public.tg_campania_colportor_identidad() from public, anon;

-- Internas: solo las llaman funciones SECURITY DEFINER (que corren como su dueño).
-- motivo_rechazo_inscripcion() incluida: con EXECUTE, un coordinador sondearía con su propia
-- campaña si cualquier usuario verificó el email o en qué campaña está.
revoke all on function public.campania_vigente(public.campania), public.campanias_vigentes_de(uuid),
  public.motivo_rechazo_inscripcion(uuid, uuid)
  from authenticated;
grant execute on function public.campania_vigente(public.campania), public.campanias_vigentes_de(uuid),
  public.motivo_rechazo_inscripcion(uuid, uuid)
  to service_role;

grant execute on function public.inscribir_colportor(uuid, uuid) to authenticated, service_role;
