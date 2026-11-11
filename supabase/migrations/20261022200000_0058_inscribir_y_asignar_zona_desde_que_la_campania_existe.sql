-- ============================================================================
-- 0058 · Sumar colportores y asignar zona desde que la campaña existe
--        (backend-supabase#103, decisión de Cristian del 21/10, «Antes inicio»)
--
-- El caso: Marta suma a Agustín y le asigna zona el 20/11 en una campaña que empieza el 1/12, para
-- que él baje el mapa y las casas con wifi antes del primer día (decisiones del 30/09, backend#39, y
-- del 02/10, backend#45 / HU-SYNC-011). Hasta hoy `inscribir_colportor()` y `asignar_zona()` exigían
-- que la campaña ya hubiera empezado y no hubiera terminado (`campania_vigente()`, CI002 / CZ002 en
-- una por empezar). Cristian lo cambió el 21/10: «Sí, desde que la campaña existe» (backend-supabase
-- #82, pendiente `backend-supabase-54-rev-261015-2356.md` P2). La regla pasa a ser «la campaña no
-- terminó».
--
-- ## Qué cambia
--
--   1. `motivo_campania_del_coordinador(campania)` (0006): el permiso es el mismo, pero ya no pide
--      que la campaña haya empezado: solo que no haya terminado (`fecha_fin < hoy_montevideo()`,
--      el mismo criterio de `motivo_mapa_de_campania()`, 0024). Sigue devolviendo
--      `CAMPANIA_NO_VIGENTE` para la terminada, con los mismos códigos (CI002 al inscribir y buscar,
--      CZ002 al asignar y quitar la zona). Los textos de esos dos avisos cambian (sección 4):
--      «La campaña ya terminó. Elegí una campaña en curso o por empezar.» (CI002) y «La campaña ya
--      terminó: ya no se asignan zonas.» (CZ002). El aviso de «no está activa» deja de salir en una
--      campaña por empezar. Es la regla compartida por cinco funciones, que cambian juntas (mismo caso, misma
--      regla):
--        · `inscribir_colportor()` y `buscar_candidatos()` (vista 23, «Añadir colportor»), por
--          `motivo_rechazo_inscripcion()`;
--        · `asignar_zona()` (por `motivo_rechazo_zona()`) y `quitar_zona()` (vista 24): quien puede
--          asignar una zona antes del inicio también puede quitarla.
--      `colportores_de_campania()` y `zonas_asignables()` ya leían con el criterio del mapa desde la
--      0033: no se tocan (una campaña por empezar ahora lista a sus inscriptos en vez de una lista
--      vacía).
--   2. `motivo_rechazo_inscripcion()` (0028): la regla de la otra campaña (R-CM02, «una sola
--      campaña activa a la vez») pasa de «ya está en otra campaña vigente» a «ya está en otra
--      campaña del mismo momento»:
--        · una campaña en curso (empezó y no terminó) y otra por empezar se pueden tener a la vez:
--          un colportor que sigue en una campaña en curso se puede sumar a la que empieza después;
--        · dos en curso a la vez siguen sin poderse (CI007, «Está en campaña X. Reasignar primero.»);
--        · dos por empezar a la vez tampoco: la decisión de Cristian habla de «una en curso y otra por
--          empezar» y no dice nada de dos por empezar; ante la duda se bloquea y queda como pendiente
--          (`backend-supabase-103-impl-261022-*.md` P1). Se destraba sacando una comparación.
--      La campaña en conflicto es siempre otra campaña no terminada y no borrada en la que el usuario
--      tiene una inscripción viva; si hay más de una, la que empezó más tarde.
--
-- ## Lo que NO cambia
--
--   · `campania_vigente()`, `campanias_vigentes_de()` y `mis_campanias_vigentes()` siguen diciendo
--     «en curso» (empezó y no terminó): de ellas salen el estado de la cuenta (`estado_cuenta()`,
--     `colportores_de_campania().estado`, `buscar_candidatos()`), `mis_zonas()` y la RLS. Un colportor
--     inscripto solo en una campaña por empezar sigue en `PENDIENTE_ASIGNACION` hasta que ella
--     empiece: eso es lo que NO está decidido y queda como pendiente (P2 del mismo archivo).
--   · Los códigos de rechazo: CI001..CI007 y CZ001..CZ006, CZ014 como estaban (cambian solo los
--     textos de CI002 y CZ002).
--   · El resto de las reglas de inscribir y asignar: permiso, usuario existente, email verificado,
--     no suspendido, no inscripto ya, zona viva de una ciudad viva de esa campaña.
--   · El lock por usuario de `inscribir_colportor()` (dos coordinadores a la vez), la reactivación de
--     una inscripción dada de baja (0028) y el orden de los locks de `asignar_zona()`.
--
-- ## Los datos
--
-- No toca ninguna fila: solo redefine funciones (`create or replace`, misma firma, mismos privilegios
-- y mismos comentarios salvo los que describían «campaña vigente»). Las inscripciones y las zonas de
-- hoy siguen valiendo. Ningún camino borra del teléfono ubicaciones, espacios, personas ni ventas.
--
-- ## Para otros repos
--
--   · front-coordinadores-web (vista 23, #41): «Añadir colportor» deja de recibir CI002 en una
--     campaña por empezar y puede recibir CI007 si el colportor ya está en otra campaña del mismo
--     momento; el aviso de la terminada cambia de texto (CI002: «La campaña ya terminó. Elegí una campaña en curso o por empezar.»).
--   · docs-organizacion (HU-CAM-004, docs#72): «mi campaña activa» pasa a «una campaña de la que soy
--     coordinador y que no terminó».
--
-- Forward-only: esta migración no se edita una vez aplicada.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. El permiso compartido: la campaña no terminó
-- ----------------------------------------------------------------------------

-- Igual que en 0006, salvo la última regla: antes `not campania_vigente()` (no empezó o terminó),
-- ahora solo la que ya terminó, según el día de Montevideo (0024).
create or replace function public.motivo_campania_del_coordinador(p_campania_id uuid)
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

  if v_campania.fecha_fin is not null and v_campania.fecha_fin < public.hoy_montevideo() then
    return 'CAMPANIA_NO_VIGENTE';
  end if;

  return null;
end;
$$;

comment on function public.motivo_campania_del_coordinador(uuid) is
  'null si el usuario autenticado es ADMIN o el coordinador de p_campania_id y la campaña no '
  'terminó (en curso o por empezar; el día se cuenta en America/Montevideo, 0024, 0058); si no, '
  'SIN_PERMISO | CAMPANIA_INEXISTENTE | CAMPANIA_NO_VIGENTE (terminada). Interna: la usan '
  'motivo_rechazo_inscripcion(), motivo_rechazo_zona(), quitar_zona() y buscar_candidatos().';

-- ----------------------------------------------------------------------------
-- 2. Inscribir: una en curso y otra por empezar sí; dos del mismo momento no
-- ----------------------------------------------------------------------------

-- Igual que en 0028, salvo EN_OTRA_CAMPANIA: antes cualquier inscripción viva en una campaña en
-- curso (campanias_vigentes_de()); ahora cualquier inscripción viva en otra campaña no terminada que
-- esté en el mismo momento que esta (las dos en curso, o las dos por empezar).
create or replace function public.motivo_rechazo_inscripcion(
  p_campania_id uuid, p_usuario_id uuid,
  out motivo text, out campania_en_conflicto uuid)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_usuario  public.usuario;
  v_campania public.campania;
  v_hoy      date := public.hoy_montevideo();
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
  -- (0028). Solo cuenta lo que pasa con las inscripciones vivas en OTRAS campañas que no terminaron:
  -- en curso con en curso, o por empezar con por empezar (R-CM02, 0058). Una en curso y otra por
  -- empezar a la vez se puede. La campaña existe y no terminó: lo acaba de decir el permiso.
  select c.* into v_campania from public.campania c where c.id = p_campania_id;

  select c.id into campania_en_conflicto
    from public.campania_colportor cc
    join public.campania c on c.id = cc.campania_id
   where cc.usuario_id = p_usuario_id
     and cc.deleted_at is null
     and c.deleted_at is null
     and c.id <> p_campania_id
     and (c.fecha_fin is null or c.fecha_fin >= v_hoy)
     and (c.fecha_inicio <= v_hoy) = (v_campania.fecha_inicio <= v_hoy)
   order by c.fecha_inicio desc, c.id
   limit 1;
  if found then
    motivo := 'EN_OTRA_CAMPANIA'; return;
  end if;
end;
$$;

comment on function public.motivo_rechazo_inscripcion(uuid, uuid) is
  'HU-CAM-004: motivo null si el usuario autenticado puede inscribir a p_usuario_id en '
  'p_campania_id (o reactivar su inscripción dada de baja en ella, 0028) mientras la campaña no '
  'terminó (en curso o por empezar, 0058); si no, el motivo (SIN_PERMISO, CAMPANIA_INEXISTENTE, '
  'CAMPANIA_NO_VIGENTE, USUARIO_INEXISTENTE, EMAIL_NO_VERIFICADO, USUARIO_SUSPENDIDO, '
  'YA_INSCRIPTO, EN_OTRA_CAMPANIA; con este último, campania_en_conflicto: otra campaña no '
  'terminada en el mismo momento, las dos en curso o las dos por empezar). Única definición de las '
  'reglas. Interna: la llaman inscribir_colportor() y buscar_candidatos().';

-- ----------------------------------------------------------------------------
-- 3. Comentarios que decían «campaña vigente»
-- ----------------------------------------------------------------------------

comment on function public.motivo_rechazo_zona(uuid, uuid, uuid) is
  'HU-CAM-006: null si el usuario autenticado puede asignar p_zona_id a p_usuario_id en '
  'p_campania_id, mientras la campaña no terminó (en curso o por empezar, 0058); si no, '
  'SIN_PERMISO | CAMPANIA_INEXISTENTE | CAMPANIA_NO_VIGENTE (terminada) | NO_INSCRIPTO | '
  'USUARIO_SUSPENDIDO | ZONA_INEXISTENTE | ZONA_DE_OTRA_CIUDAD | ZONA_DE_OTRA_CAMPANIA. Interna: la '
  'llama asignar_zona().';

comment on function public.inscribir_colportor(uuid, uuid) is
  'HU-CAM-004: inscribe a p_usuario_id en p_campania_id y devuelve la fila de campania_colportor; si '
  'tenía una inscripción dada de baja en esa campaña, la reactiva (la misma fila, sin zona, 0028). '
  'Vale en una campaña en curso o por empezar (0058); una terminada es CI002. Errores: 42501 sin '
  'permiso; CI001..CI007 por regla (ver 0005; CI007: ya está en otra campaña del mismo momento). '
  'La cuenta pasa a ACTIVA sola cuando la campaña está en curso.';

comment on function public.asignar_zona(uuid, uuid, uuid) is
  'HU-CAM-006: asigna p_zona_id a la inscripción de p_usuario_id en p_campania_id y devuelve la '
  'fila de campania_colportor, en una campaña en curso o por empezar (0058). Errores: 42501 sin '
  'permiso; CZ001..CZ006 por regla (CZ002: la campaña terminó); CZ014 cuenta suspendida (conserva '
  'la zona que tenía).';

comment on function public.quitar_zona(uuid, uuid) is
  'HU-CAM-006, «Quitar» en la vista 24 (decisión del 30/09, front-coordinadores-web#20): deja sin '
  'zona la inscripción de p_usuario_id en p_campania_id y devuelve la fila de campania_colportor, en '
  'una campaña en curso o por empezar (0058). Sin zona ya, la devuelve igual. Errores: 42501 sin '
  'permiso; CZ001 campaña inexistente; CZ002 terminada; CZ003 no inscripto.';

comment on function public.buscar_candidatos(uuid, text, uuid) is
  'HU-CAM-004, vista 23: cuentas para añadir a p_campania_id. Sin texto, los sugeridos (hasta 5 '
  'PENDIENTE_ASIGNACION, más nuevas primero, una sola página); con texto, las que contienen el '
  'texto en el nombre completo o el email (sin mayúsculas ni tildes), primero las que empiezan '
  'con él y después alfabético, de a 10 por página: p_despues_de es el usuario_id de la última '
  'de la página anterior. Devuelve estado, campaña vigente (en curso) y motivo_bloqueo (el de '
  'inscribir_colportor(), null si se puede). Errores: 42501 sin permiso; CI001 campaña '
  'inexistente; CI002 terminada (una por empezar se busca, 0058); 22023 cursor desconocido (0015).';

-- ----------------------------------------------------------------------------
-- 4. Los avisos de la campaña terminada (decisión del agente de decisiones, §2, sobre el pendiente P3)
-- ----------------------------------------------------------------------------

-- «No está activa» y «solo se inscribe en una campaña vigente» ya no describen la regla (una campaña
-- por empezar también se puede): ahora dicen qué pasó y qué hacer. Los códigos no cambian (CI002,
-- CZ002). Las tres funciones se copian enteras de su última versión, salvo el texto.

-- Igual que en 0012, salvo el texto de CZ002.
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
      raise exception 'La campaña ya terminó: ya no se asignan zonas.' using errcode = 'CZ002';
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

-- Igual que en 0028, salvo el texto de CI002.
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
      raise exception 'La campaña ya terminó. Elegí una campaña en curso o por empezar.'
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

-- Igual que en 0015, salvo el texto de CI002.
create or replace function public.buscar_candidatos(p_campania_id uuid, p_texto text default null,
                                         p_despues_de uuid default null)
returns table (usuario_id uuid, nombre text, apellido text, email text, estado text,
               campania_actual text, creada_en timestamptz, motivo_bloqueo text)
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_texto  text := public.normalizar_busqueda(p_texto);
  v_motivo text;
  -- La clave de orden de la cuenta del cursor: (no empieza, sin nombre, nombre, id).
  v_cursor_no_empieza  boolean;
  v_cursor_sin_nombre  boolean;
  v_cursor_nombre      text;
begin
  if auth.uid() is null then
    raise exception 'buscar_candidatos requiere un usuario autenticado'
      using errcode = 'insufficient_privilege';
  end if;

  -- El permiso primero, con los códigos de inscribir_colportor().
  v_motivo := public.motivo_campania_del_coordinador(p_campania_id);
  case v_motivo
    when 'SIN_PERMISO' then
      raise exception 'Solo el coordinador de la campaña puede buscar cuentas para inscribir en ella.'
        using errcode = 'insufficient_privilege';
    when 'CAMPANIA_INEXISTENTE' then
      raise exception 'La campaña no existe.' using errcode = 'CI001';
    when 'CAMPANIA_NO_VIGENTE' then
      raise exception 'La campaña ya terminó. Elegí una campaña en curso o por empezar.'
        using errcode = 'CI002';
    else
      null;
  end case;

  -- La página siguiente. Sin texto, los sugeridos son una sola página.
  if p_despues_de is not null then
    if v_texto is null then
      return;
    end if;
    select not coalesce(strpos(x.n_completo, v_texto) = 1 or strpos(x.n_apellido, v_texto) = 1
                        or strpos(x.n_email, v_texto) = 1, false),
           x.n_completo is null, coalesce(x.n_completo, '')
      into v_cursor_no_empieza, v_cursor_sin_nombre, v_cursor_nombre
      from (select public.normalizar_busqueda(u.nombre || ' ' || u.apellido) as n_completo,
                   public.normalizar_busqueda(u.apellido) as n_apellido,
                   public.normalizar_busqueda(u.email) as n_email
              from public.usuario u
             where u.id = p_despues_de) x;
    if not found then
      raise exception 'No se encontró la última cuenta de la página anterior. Volvé a buscar desde el principio.'
        using errcode = 'invalid_parameter_value';
    end if;
  end if;

  return query
    with candidata as (
      select u.id, u.nombre, u.apellido, u.email, u.created_at, u.suspendido_en,
             public.normalizar_busqueda(u.nombre || ' ' || u.apellido) as n_completo,
             public.normalizar_busqueda(u.apellido) as n_apellido,
             public.normalizar_busqueda(u.email) as n_email
        from public.usuario u
       where u.deleted_at is null
         and exists (select 1 from auth.users au
                      where au.id = u.id and au.confirmed_at is not null)
         and not exists (select 1 from public.campania_colportor cc
                          where cc.campania_id = p_campania_id and cc.usuario_id = u.id
                            and cc.deleted_at is null)
    ),
    -- La clave de orden de la búsqueda: primero las que empiezan con el texto (false < true),
    -- después alfabético, las sin nombre al final, y el id.
    clave as (
      select c.*,
             not coalesce(strpos(c.n_completo, v_texto) = 1 or strpos(c.n_apellido, v_texto) = 1
                          or strpos(c.n_email, v_texto) = 1, false) as no_empieza,
             c.n_completo is null as sin_nombre,
             coalesce(c.n_completo, '') as nombre_orden
        from candidata c
    ),
    elegida as (
      -- Sugeridos: sin texto, las 5 pendientes de asignación más nuevas.
      (select c.*, row_number() over (order by c.created_at desc, c.id desc) as orden
         from clave c
        where v_texto is null
          and public.estado_de_cuenta(c.suspendido_en,
                exists (select 1 from public.campanias_vigentes_de(c.id))) = 'PENDIENTE_ASIGNACION'
        order by c.created_at desc, c.id desc
        limit 5)
      union all
      -- Búsqueda: de a 10 que contienen el texto, primero las que empiezan con él; después
      -- del cursor, si viene. El coalesce de no_empieza: sin nombre ni apellido, el «empieza»
      -- sería null.
      (select c.*, row_number() over (
                order by c.no_empieza, c.sin_nombre, c.nombre_orden collate "C", c.id) as orden
         from clave c
        where v_texto is not null
          and (strpos(c.n_completo, v_texto) > 0 or strpos(c.n_email, v_texto) > 0)
          and (p_despues_de is null
               or (c.no_empieza, c.sin_nombre, c.nombre_orden collate "C", c.id)
                  > (v_cursor_no_empieza, v_cursor_sin_nombre, v_cursor_nombre collate "C", p_despues_de))
        order by orden
        limit 10)
    )
    select e.id, e.nombre, e.apellido, e.email,
           public.estado_de_cuenta(e.suspendido_en, act.id is not null),
           act.nombre, e.created_at, m.motivo
      from elegida e
      left join lateral (
        -- La misma que nombra inscribir_colportor() en «Está en campaña X» (la más reciente).
        select c.id, c.nombre
          from public.campanias_vigentes_de(e.id) v
          join public.campania c on c.id = v.campania_id
         order by c.fecha_inicio desc, c.id
         limit 1
      ) act on true
      cross join lateral public.motivo_rechazo_inscripcion(p_campania_id, e.id) m
     order by e.orden;
end;
$$;
