-- ============================================================================
-- 0028 · Reactivar una inscripción dada de baja (backend-supabase#41)
--
-- Decisión de Cristian del 02/10 (comentario «Decisiones de Cristian (02/10): inscripción en
-- campañas», https://github.com/Colportores/backend-supabase/issues/41#issuecomment-5952055719):
--
--   1. Cuentas de coordinador o admin: se pueden inscribir como colportor sin restricción; un
--      coordinador puede ser colportor normal en otra campaña. No se filtra por rol ni en la
--      búsqueda ni en la inscripción.
--   2. Inscripción borrada: se habilita reactivarla ya (lo que estaba abierto en
--      front-coordinadores-web#19). En la vista 23 el coordinador ve a la persona que quitó y puede
--      volver a sumarla: reactiva la inscripción, sin crear otra.
--
-- ## Punto 1: ya estaba así, no cambia nada
--
-- Ni buscar_candidatos() (0015) ni motivo_rechazo_inscripcion() (0005/0006) miran el rol de la cuenta:
-- un COORDINADOR o un ADMIN sin inscripción es PENDIENTE_ASIGNACION y aparece como candidato, y
-- inscribir_colportor() lo inscribe (la regla «una campaña vigente por colportor» mira solo
-- inscripciones, no quién coordina qué). Lo que sí hace esta migración es dejarlo fijado con tests
-- (0035) y sacar el pendiente de los comentarios.
--
-- ## Punto 2: reactivar
--
-- inscribir_colportor(campania, usuario) ahora, si el usuario tiene una inscripción dada de baja en
-- ESA campaña, la reactiva (deleted_at = null) en vez de rechazarla con CI008. Es la misma fila: no
-- se crea otra (unique (campania_id, usuario_id)), conserva su id, su created_at y su created_by (la
-- primera vez que se inscribió y quién lo hizo), y su meta_libros; updated_at y sync_version registran
-- la reactivación. Las demás reglas siguen valiendo, en el mismo orden: quien reactiva tiene que ser
-- el coordinador de la campaña o un ADMIN (SIN_PERMISO), la campaña tiene que estar vigente, la
-- cuenta existir, tener el email verificado y no estar suspendida, y no estar en otra campaña vigente
-- (CI007, «Está en campaña X. Reasignar primero.»). Reintentar con la inscripción ya viva es CI006.
--
--   · motivo_rechazo_inscripcion(): sale la regla INSCRIPCION_BORRADA. Lo que de ella dependía lo
--     resuelve solo: buscar_candidatos() ya devuelve a quien tiene una inscripción dada de baja en
--     esta campaña (solo excluye a quien tiene una viva), y su motivo_bloqueo, que sale de esa única
--     definición, pasa a ser null: «Añadir» queda habilitado.
--   · tg_campania_colportor_identidad() (0005): el trigger que prohibía reactivar con un UPDATE lo
--     sigue prohibiendo para quien escribe directo (`authenticated`, por PostgREST): un UPDATE
--     directo saltearía el permiso, la suspensión y EN_OTRA_CAMPANIA. Deja de prohibirlo cuando la
--     sentencia corre adentro de una función SECURITY DEFINER, que es inscribir_colportor() y ya
--     pasó todas las reglas. Se mira current_user y no auth.uid(), como 0006
--     (tg_campania_colportor_zona_por_rpc): adentro del RPC el JWT sigue presente, pero la sentencia
--     corre como el dueño de la función. service_role y los procesos servidor siguen pasando.
--   · CI008 («Tiene una inscripción dada de baja en esta campaña.») deja de existir: ningún camino lo
--     devuelve. El código queda sin reutilizar.
--
-- ## Qué pasa con la zona
--
-- Una inscripción reactivada vuelve SIN zona, también si la fila trae una de antes de 0022 (que
-- conservaba la zona al darse de baja, 0012). Es lo que dice 0022 («cuando la inscripción se
-- reactiva vuelve sin zona: aparece en "Sin zona" y se le asigna una con asignar_zona(), que abre un
-- tramo nuevo», decisión de Cristian del 02/10). Para las filas viejas es lo mismo: en vez de
-- reactivar con una zona que pudo quedar dada de baja o en una ciudad quitada (0009: CZ004/CZ005, que
-- le pedirían al coordinador un arreglo que no puede hacer), la fila vuelve sin zona y el historial
-- (0022) cierra el tramo que había quedado abierto. Sin esto, reactivar a alguien de esas filas
-- fallaría o lo dejaría con una zona que ya no existe.
--
-- ## El sync
--
-- campania_colportor está en sync.entidad como pull desde 0014 (la app no la escribe: el push
-- responde ENTIDAD_DE_SOLO_LECTURA). El UPDATE de la reactivación pasa por tg_auditoria_update, que
-- sube el xmin_w, y el pull le vuelve a bajar al colportor su fila, ya sin deleted_at y sin zona.
-- El mapa de la campaña también vuelve a bajar, igual que con una inscripción nueva, pero no por
-- los triggers de republicar de 0008 y 0010 (se borraron en 0013 y 0011): cambia la huella de las
-- campañas que ve (mis_campanias_del_mapa(), 0013) que compara sync.pull (0023), y esas entidades
-- bajan completas.
--
-- ## Para otros repos
--
--   · front-coordinadores-web (vista 23, #19): una persona que se quitó de esta misma campaña sale
--     en la búsqueda con motivo_bloqueo = null, «Añadir» habilitado, y al añadirla inscribir_colportor()
--     devuelve la inscripción reactivada (la misma fila, mismo id). El motivo INSCRIPCION_BORRADA y el
--     error CI008 ya no se devuelven: sacar el texto que faltaba en el diseño. Si el panel quiere
--     avisar «ya estuvo en tu equipo», hoy no hay una columna para eso (buscar_candidatos() no la
--     trae): es un agregado al contrato, no cambia lo que hace esta migración.
--   · docs-organizacion (HU-CAM-004 y el contrato): el rechazo CI008 desaparece; reactivar es el
--     comportamiento de inscribir_colportor() cuando hay una inscripción dada de baja en la campaña.
--
-- ## Datos
--
-- No toca ninguna fila: solo redefine tres funciones (create or replace, con la misma firma y los
-- mismos privilegios). Las inscripciones dadas de baja que ya existen quedan como están hasta que
-- alguien las reactive.
--
-- Forward-only: esta migración no se edita una vez aplicada.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. Las reglas: una inscripción dada de baja en esta campaña ya no es un motivo de rechazo
-- ----------------------------------------------------------------------------

-- Igual que en 0006, sin el tramo INSCRIPCION_BORRADA.
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

  -- Una inscripción dada de baja en esta campaña no rechaza: inscribir_colportor() la reactiva
  -- (0028). Solo cuenta lo que pasa con las inscripciones vivas en OTRAS campañas.
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
  'p_campania_id (o reactivar su inscripción dada de baja en ella, 0028); si no, el motivo '
  '(SIN_PERMISO, CAMPANIA_INEXISTENTE, CAMPANIA_NO_VIGENTE, USUARIO_INEXISTENTE, EMAIL_NO_VERIFICADO, '
  'USUARIO_SUSPENDIDO, YA_INSCRIPTO, EN_OTRA_CAMPANIA; con este último, campania_en_conflicto). '
  'Única definición de las reglas. Interna: la llaman inscribir_colportor() y buscar_candidatos().';

-- ----------------------------------------------------------------------------
-- 2. Un UPDATE directo sigue sin poder reactivar; el RPC sí
-- ----------------------------------------------------------------------------

-- Igual que en 0005, salvo la reactivación: se rechaza cuando la sentencia llega por PostgREST
-- (current_user = authenticated) y pasa cuando corre adentro de inscribir_colportor().
create or replace function public.tg_campania_colportor_identidad()
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

  if current_user = 'authenticated' and old.deleted_at is not null and new.deleted_at is null then
    raise exception 'una inscripción borrada se reactiva con inscribir_colportor() (HU-CAM-004), no con un UPDATE'
      using errcode = 'check_violation';
  end if;

  return new;
end;
$$;

-- ----------------------------------------------------------------------------
-- 3. inscribir_colportor(): reactiva la inscripción dada de baja de esa campaña
-- ----------------------------------------------------------------------------

-- Igual que en 0005, salvo que no hay CI008 y que, si el usuario tiene una inscripción dada de baja en
-- esta campaña, la reactiva (sin zona, ver el header) en vez de insertar una nueva. El lock por
-- usuario y las reglas son los de siempre: pasan por motivo_rechazo_inscripcion().
create or replace function public.inscribir_colportor(p_campania_id uuid, p_usuario_id uuid)
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
  -- Alcanza porque no hay otro camino con JWT (0005, sección 3).
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
    else
      null;
  end case;

  -- Si ya estuvo en el equipo y la quitaron, vuelve la misma inscripción: sin zona (0022) y con lo
  -- demás como estaba (meta_libros, created_at, created_by).
  update public.campania_colportor cc
     set deleted_at = null, zona_id = null
   where cc.campania_id = p_campania_id and cc.usuario_id = p_usuario_id
     and cc.deleted_at is not null
  returning * into v_fila;
  if found then
    return v_fila;
  end if;

  insert into public.campania_colportor (campania_id, usuario_id, created_by)
  values (p_campania_id, p_usuario_id, auth.uid())
  returning * into v_fila;

  return v_fila;
end;
$$;

comment on function public.inscribir_colportor(uuid, uuid) is
  'HU-CAM-004: inscribe a p_usuario_id en p_campania_id y devuelve la fila de campania_colportor; si '
  'tenía una inscripción dada de baja en esa campaña, la reactiva (la misma fila, sin zona, 0028). '
  'Errores: 42501 sin permiso; CI001..CI007 por regla (ver 0005). La cuenta pasa a ACTIVA sola.';
