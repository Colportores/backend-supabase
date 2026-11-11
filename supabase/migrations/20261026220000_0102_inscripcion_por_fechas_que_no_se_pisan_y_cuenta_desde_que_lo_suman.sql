-- ============================================================================
-- 0102 · Inscripción por fechas que no se pisan y cuenta activa desde que lo suman
--        (backend-supabase#142, seguimiento de #103; decisiones de Cristian del 23/10,
--        «Dos por empezar» y «Cuenta antes»)
--
-- El caso: Marta suma a Agustín a la campaña de invierno y otra coordinadora lo suma a la de
-- primavera, que empieza después de que termine la de invierno. Y Agustín, inscripto y con zona en la
-- campaña del 1/12, abre la app el 20/11 y baja el mapa con wifi.
--
-- ## Qué cambia
--
--   1. R-CM02 por superposición de fechas (`motivo_rechazo_inscripcion()`, 0058). Antes: «otra
--      campaña del mismo momento» (las dos en curso o las dos por empezar). Ahora: se lo puede
--      sumar a cualquier campaña que no terminó siempre que sus fechas no se superpongan con las de
--      otra campaña no terminada en la que ya tiene una inscripción viva. Así nunca queda en dos en
--      curso a la vez, ni hoy ni cuando empiecen, y puede estar anotado en varias seguidas.
--        · El cruce es por días y con los dos extremos incluidos (`daterange(inicio, fin, '[]')`): una
--          que termina el 30/11 y otra que empieza el 30/11 se pisan; la que empieza el 1/12 no.
--        · Una campaña sin fecha de fin cuenta como abierta hasta el infinito: ante la duda se
--          bloquea (se pisa con toda campaña que empiece después que ella).
--        · Cuentan las inscripciones vivas en campañas vivas que no terminaron; una dada de baja, una
--          campaña terminada o borrada no. Si hay más de una que se pisa, el aviso nombra la que
--          empezó más tarde (como en 0058).
--   2. CI007 (`inscribir_colportor()`): «Está en la campaña <nombre> (del <dd/mm> al <dd/mm>). Elegí
--      otra campaña o quitalo de esa primero.» El `detail` suma `fecha_inicio` y `fecha_fin` (ISO,
--      `null` si no tiene fin) a `campania_id` y `campania_nombre`. Si la otra no tiene fecha de fin
--      el paréntesis dice «desde el <dd/mm>, sin fecha de fin» (texto pendiente, §2: ver el PR).
--   3. La cuenta está activa desde que lo suman a una campaña que no terminó (HU-CAM-004, HU-AUTH-008):
--      `estado_cuenta()`, `colportores_de_campania().estado` y `buscar_candidatos()` (el `estado`, la
--      `campania_actual` y los sugeridos) cuentan las inscripciones en campañas no terminadas, no solo
--      las en curso. `estado_de_cuenta(suspendido_en, boolean)` no cambia: sigue siendo pura; lo que
--      cambia es el booleano que se le pasa (la columna se llama todavía `p_con_campania_vigente`,
--      renombrar un argumento es un `drop function`). Un colportor inscripto solo en una por empezar
--      deja de ser `PENDIENTE_ASIGNACION` y no sale entre los sugeridos de otras campañas. Hasta que la
--      campaña empieza la app le dice cuándo empieza y no lo deja iniciar jornada ni vender en ella
--      (eso lo hace el cliente, front-colportores-mobile#62); el servidor lo respalda con el punto 4.
--      `campania_actual` de `buscar_candidatos()` pasa a ser la campaña que bloquea (la que nombra
--      CI007), si no la que está en curso, si no la que empieza antes.
--   4. El servidor rechaza una venta anterior al inicio de la campaña (`venta_antes_del_inicio()` y la
--      política restrictiva `venta_no_antes_del_inicio` sobre `venta`, INSERT). Hasta hoy ninguna política de
--      `venta` miraba la campaña (solo `colportor_id = auth.uid()`, 0001; 0020 lo anotó). La regla,
--      por el día de la venta en Montevideo (`venta.fecha`): se rechaza si el colportor tiene una
--      inscripción viva en una campaña que empieza DESPUÉS de ese día y ninguna inscripción (viva o dada
--      de baja) en una campaña ya empezada ese día y no pasada del plazo de 15 días (0020). Quien no tiene
--      ninguna inscripción por empezar no cambia (se acepta como hoy, también la venta tardía de
--      una campaña vieja: una venta que ya existe en el teléfono no se pierde). El rechazo sale como
--      un 42501 del push, igual que cualquier otra venta ajena a su permiso.
--   5. `mis_inscripciones_no_terminadas()` (0013) no cambia. La RLS de zonas, ubicaciones, casas y mapa
--      tampoco: lo que se abre es el estado de la cuenta, no la lectura (el mapa y las casas ya bajaban
--      desde que la campaña existe, 0013 y 0058).
--
-- ## Funciones nuevas (internas salvo `tengo_inscripcion_no_terminada()` y `venta_antes_del_inicio()`, que
--    las llaman `estado_cuenta()` y la política con los privilegios de quien consulta)
--
--   · `inscripciones_no_terminadas_de(usuario)`: lo mismo que `mis_inscripciones_no_terminadas()` pero
--     por usuario. Sin EXECUTE para authenticated (un colportor averiguaría en qué campaña está otro).
--   · `tengo_inscripcion_no_terminada()`: si el usuario autenticado tiene una. La llama `estado_cuenta()`,
--     que sigue siendo INVOKER (0006).
--
-- ## Para otros repos
--
--   · front-coordinadores-web#41: el aviso CI007 trae el nombre y las fechas de la otra campaña; ya no
--     hay CI007 por dos campañas por empezar que no se pisan. `estado` de la lista de colportores de una
--     campaña por empezar es `ACTIVA` para quien está inscripto.
--   · front-colportores-mobile#62: `estado_cuenta()` devuelve `ACTIVA` para quien solo está en una
--     campaña por empezar; la app tiene que decirle cuándo empieza y frenar jornada y venta (la venta,
--     además, la rechaza el push con 42501).
--   · docs-organizacion: HU-CAM-004, HU-CAM-005, R-CM02 y HU-AUTH-008 (ver el issue de docs del PR).
--
-- ## Los datos
--
-- No toca ninguna fila: redefine funciones (`create or replace`, misma firma, mismos privilegios) y
-- suma una política restrictiva. Las inscripciones de hoy siguen valiendo, aunque hubiera dos que
-- hoy se pisan (solo importa al sumar una nueva).
--
-- Forward-only: esta migración no se edita una vez aplicada.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. Las inscripciones en campañas que no terminaron, por usuario
-- ----------------------------------------------------------------------------

-- Igual que mis_inscripciones_no_terminadas() (0013, 0024) pero de cualquier usuario. SECURITY
-- DEFINER: lee la inscripción ajena. Interna: solo la llaman funciones DEFINER o INVOKER que ya
-- pasaron su permiso.
create function public.inscripciones_no_terminadas_de(p_usuario uuid)
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
     and c.deleted_at is null
     and (c.fecha_fin is null or c.fecha_fin >= public.hoy_montevideo());
$$;

comment on function public.inscripciones_no_terminadas_de(uuid) is
  'Inscripciones vivas de un usuario en campañas vivas que no terminaron (en curso o por empezar), con '
  'su zona; el día se cuenta en America/Montevideo (0024). Es lo que hace ACTIVA a una cuenta (0102). '
  'Interna: no la ejecuta authenticated.';

create function public.tengo_inscripcion_no_terminada()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (select 1 from public.inscripciones_no_terminadas_de(auth.uid()));
$$;

comment on function public.tengo_inscripcion_no_terminada() is
  'Si el usuario autenticado tiene una inscripción viva en una campaña que no terminó (en curso o por '
  'empezar). La llama estado_cuenta(), que es INVOKER y corre con los privilegios del usuario (0102).';

revoke all on function public.inscripciones_no_terminadas_de(uuid),
  public.tengo_inscripcion_no_terminada() from public, anon, authenticated;
grant execute on function public.inscripciones_no_terminadas_de(uuid) to service_role;
grant execute on function public.tengo_inscripcion_no_terminada() to authenticated, service_role;

-- ----------------------------------------------------------------------------
-- 2. El estado de la cuenta
-- ----------------------------------------------------------------------------

-- Igual que en 0015, salvo el booleano: una inscripción en una campaña que no terminó (antes,
-- mis_campanias_vigentes(): solo en curso). Sigue INVOKER.
create or replace function public.estado_cuenta()
returns text
language plpgsql
stable
set search_path = ''
as $$
declare
  v_suspendido_en timestamptz;
begin
  if auth.uid() is null then
    raise exception 'estado_cuenta requiere un usuario autenticado'
      using errcode = 'insufficient_privilege';
  end if;

  select u.suspendido_en into v_suspendido_en
    from public.usuario u
   where u.id = auth.uid();

  if not found then
    raise exception 'el usuario autenticado no tiene perfil en public.usuario'
      using errcode = 'no_data_found';
  end if;

  return public.estado_de_cuenta(v_suspendido_en, public.tengo_inscripcion_no_terminada());
end;
$$;

comment on function public.estado_cuenta() is
  'HU-AUTH-008: estado de la cuenta del usuario autenticado: SUSPENDIDA, ACTIVA (inscripción viva en una '
  'campaña que no terminó, en curso o por empezar, desde 0102) o PENDIENTE_ASIGNACION. INVOKER.';

comment on function public.estado_de_cuenta(timestamptz, boolean) is
  'HU-AUTH-008: SUSPENDIDA si p_suspendido_en no es null; si no, ACTIVA si p_con_campania_vigente (desde '
  '0102, con una inscripción en una campaña que no terminó); si no, PENDIENTE_ASIGNACION. Única '
  'definición de la precedencia: la usan estado_cuenta(), colportores_de_campania() y '
  'buscar_candidatos() (0015).';

-- ----------------------------------------------------------------------------
-- 3. Inscribir: las fechas no se pisan
-- ----------------------------------------------------------------------------

-- Igual que en 0058, salvo EN_OTRA_CAMPANIA: antes, otra campaña no terminada del mismo momento (las
-- dos en curso o las dos por empezar); ahora, otra campaña no terminada cuyas fechas se pisan con
-- las de esta (daterange inclusivo; sin fecha de fin = abierta).
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
  -- si sus fechas se pisan con las de esta (R-CM02, 0102). La campaña existe y no terminó: lo acaba
  -- de decir el permiso.
  select c.* into v_campania from public.campania c where c.id = p_campania_id;

  select c.id into campania_en_conflicto
    from public.campania_colportor cc
    join public.campania c on c.id = cc.campania_id
   where cc.usuario_id = p_usuario_id
     and cc.deleted_at is null
     and c.deleted_at is null
     and c.id <> p_campania_id
     and (c.fecha_fin is null or c.fecha_fin >= v_hoy)
     and daterange(c.fecha_inicio, c.fecha_fin, '[]')
         && daterange(v_campania.fecha_inicio, v_campania.fecha_fin, '[]')
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
  'terminada cuyas fechas se pisan con las de esta, sin fecha de fin = abierta, 0102). Única '
  'definición de las reglas. Interna: la llaman inscribir_colportor() y buscar_candidatos().';

-- Igual que en 0058, salvo el aviso de CI007: nombra la campaña y sus fechas.
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
      raise exception 'Está en la campaña % (%). Elegí otra campaña o quitalo de esa primero.', v_otra.nombre,
        case when v_otra.fecha_fin is null
             then 'desde el ' || to_char(v_otra.fecha_inicio, 'DD/MM') || ', sin fecha de fin'
             else 'del ' || to_char(v_otra.fecha_inicio, 'DD/MM') || ' al ' || to_char(v_otra.fecha_fin, 'DD/MM')
        end
        using errcode = 'CI007',
              detail = json_build_object('campania_id', v_otra.id, 'campania_nombre', v_otra.nombre,
                                         'fecha_inicio', v_otra.fecha_inicio,
                                         'fecha_fin', v_otra.fecha_fin)::text;
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
  'Vale en una campaña en curso o por empezar (0058); una terminada es CI002. Errores: 42501 sin '
  'permiso; CI001..CI007 por regla (ver 0005; CI007: ya está en otra campaña cuyas fechas se pisan con '
  'las de esta, con su nombre y fechas, 0102). La cuenta pasa a ACTIVA sola al sumarlo a una campaña que '
  'no terminó (0102).';

-- ----------------------------------------------------------------------------
-- 4. colportores_de_campania(): el estado cuenta las campañas que no terminaron
-- ----------------------------------------------------------------------------

-- Igual que en 0033, salvo el booleano de estado_de_cuenta().
create or replace function public.colportores_de_campania(p_campania_id uuid)
returns table (usuario_id uuid, nombre text, apellido text, zona_id uuid, zona_nombre text,
                suspendido boolean, email text, estado text)
language plpgsql
volatile
security definer
set search_path = ''
as $$
begin
  perform public.exigir_lectura_de_campania(p_campania_id);

  return query
    select u.id, u.nombre, u.apellido, z.id, z.nombre, (u.suspendido_en is not null), u.email,
           public.estado_de_cuenta(u.suspendido_en,
                                   exists (select 1 from public.inscripciones_no_terminadas_de(u.id)))
      from public.campania_colportor cc
      join public.usuario u on u.id = cc.usuario_id
      left join public.zona z on z.id = cc.zona_id and z.deleted_at is null
     where cc.campania_id = p_campania_id
       and cc.deleted_at is null and u.deleted_at is null
     order by u.apellido, u.nombre, u.id;
end;
$$;

comment on function public.colportores_de_campania(uuid) is
  'HU-CAM-004/006: inscriptos vivos de p_campania_id con su zona actual, email y estado de la '
  'cuenta (0015; desde 0102, ACTIVA con una inscripción en una campaña que no terminó). Se lee con el '
  'criterio del mapa (0033): una campaña por empezar contesta con quienes se sumaron antes del inicio. '
  'Errores: 42501 sin permiso; CZ001 inexistente; CZ011 terminada.';

-- ----------------------------------------------------------------------------
-- 5. buscar_candidatos() va al final del archivo (copia entera de la 0058 con dos cambios)
-- ----------------------------------------------------------------------------

comment on function public.buscar_candidatos(uuid, text, uuid) is
  'HU-CAM-004, vista 23: cuentas para añadir a p_campania_id. Sin texto, los sugeridos (hasta 5 '
  'PENDIENTE_ASIGNACION, o sea sin inscripción en ninguna campaña que no terminó; más nuevas primero, '
  'una sola página); con texto, las que contienen el texto en el nombre completo o el email (sin '
  'mayúsculas ni tildes), primero las que empiezan con él y después alfabético, de a 10 por página: '
  'p_despues_de es el usuario_id de la última de la página anterior. Devuelve estado (ACTIVA con una '
  'inscripción en una campaña que no terminó, 0102), campania_actual (la que bloquea, si no la en '
  'curso, si no la que empieza antes) y motivo_bloqueo (el de inscribir_colportor(), null si se '
  'puede). Errores: 42501 sin permiso; CI001 campaña inexistente; CI002 terminada (una por empezar se '
  'busca, 0058); 22023 cursor desconocido (0015).';

-- ----------------------------------------------------------------------------
-- 6. El servidor rechaza una venta anterior al inicio de la campaña
-- ----------------------------------------------------------------------------

-- Si una venta del día p_fecha (en Montevideo) cae antes del inicio de todas las campañas en las que
-- el usuario autenticado está inscripto y tiene alguna por empezar para ese día. Ver el punto 4 del
-- encabezado. Una venta de un colportor sin inscripciones o sin ninguna campaña que empiece después de
-- ese día no se mira. SECURITY DEFINER: lee la inscripción propia sin depender de las políticas de
-- campania_colportor ni de campania.
create function public.venta_antes_del_inicio(p_fecha timestamptz)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  with dia as (
    select (p_fecha at time zone 'America/Montevideo')::date as d
  )
  -- Por empezar para ese día: una inscripción viva en una campaña viva que empieza después.
  select exists (select 1
                   from public.campania_colportor cc
                   join public.campania c on c.id = cc.campania_id, dia
                  where cc.usuario_id = (select auth.uid())
                    and cc.deleted_at is null
                    and c.deleted_at is null
                    and c.fecha_inicio > dia.d)
  -- Cubierto: alguna inscripción del usuario, aunque se haya dado de baja después, en una campaña
  -- que ya había empezado ese día y no había pasado del plazo. Una venta de entonces no se pierde.
     and not exists (select 1
                       from public.campania_colportor cc
                       join public.campania c on c.id = cc.campania_id, dia
                      where cc.usuario_id = (select auth.uid())
                        and c.fecha_inicio <= dia.d
                        and (c.fecha_fin is null or dia.d <= c.fecha_fin + 15));
$$;

comment on function public.venta_antes_del_inicio(timestamptz) is
  'Si una venta de ese día (en America/Montevideo) cae antes del inicio de la campaña: el usuario '
  'autenticado tiene una inscripción viva en una campaña que empieza después de ese día y ninguna '
  '(viva o de baja) en una campaña ya empezada ese día y no pasada del plazo de 15 días (0020). La usa la política '
  'venta_no_antes_del_inicio (0102).';

revoke all on function public.venta_antes_del_inicio(timestamptz) from public, anon, authenticated;
grant execute on function public.venta_antes_del_inicio(timestamptz) to authenticated, service_role;

-- RESTRICTIVE: se suma a venta_propia (colportor_id = auth.uid()), no la reemplaza. Solo el alta: una
-- venta que ya existe se corrige, se anula y se cobra como siempre.
create policy venta_no_antes_del_inicio on public.venta
  as restrictive
  for insert
  to authenticated
  with check (not public.venta_antes_del_inicio(fecha));

comment on policy venta_no_antes_del_inicio on public.venta is
  'El servidor no acepta una venta anterior al inicio de la campaña del colportor (0102, '
  'backend-supabase#142, decisión de Cristian del 23/10 «Cuenta antes»).';

-- Igual que en 0058, salvo dos cosas: el estado de la cuenta cuenta las inscripciones en campañas
-- que no terminaron, y la campaña que se muestra es la que bloquea (si la hay).
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
                exists (select 1 from public.inscripciones_no_terminadas_de(c.id))) = 'PENDIENTE_ASIGNACION'
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
      cross join lateral public.motivo_rechazo_inscripcion(p_campania_id, e.id) m
      left join lateral (
        -- La campaña que se muestra: la que bloquea (la misma que nombra inscribir_colportor() en
        -- «Está en la campaña X»); si nada bloquea, la que está en curso; si no, la que empieza antes.
        select c.id, c.nombre
          from public.inscripciones_no_terminadas_de(e.id) v
          join public.campania c on c.id = v.campania_id
         order by (c.id = m.campania_en_conflicto) desc nulls last,
                  (c.fecha_inicio <= public.hoy_montevideo()) desc,
                  c.fecha_inicio, c.id
         limit 1
      ) act on true
     order by e.orden;
end;
$$;
