-- ============================================================================
-- 0042 · Acompañamientos del coordinador: agregar uno a una jornada finalizada, el historial por
--        colportor y los «días sin acompañar» (backend-supabase#97, HU-JOR-004, vista 33 «Equipo»)
--
-- Origen: HU-JOR-004 y el cambio de requisitos del 21/10 (reunión del 05/10, docs#69, C13): en la
-- ficha del colportor (Equipo) el coordinador ve cuándo lo acompañó y hace cuántos días no lo
-- acompaña nadie, y puede completar el dato cuando el colportor se olvidó de marcarlo.
--
--   agregar_acompaniamiento(p_campania_id, p_jornada_id)
--     -> (jornada_id, colportor_id, dia, acompaniante_id, acompaniante_nombre,
--         acompaniante_apellido, ya_estaba)
--   acompaniamientos_por_colportor(p_campania_id)
--     -> (colportor_id, nombre, apellido, ciudad_id, ciudad_nombre, acompaniamientos,
--         ultimo_dia, dias_sin_acompaniar, contado_desde)
--   historial_de_acompaniamientos(p_campania_id, p_colportor_id)
--     -> (jornada_id, colportor_id, nombre, apellido, dia, horas, en_curso, acompaniante_id,
--         acompaniante_nombre, acompaniante_apellido)
--   jornadas_cerradas_de_colportor(p_campania_id, p_colportor_id)
--     -> (jornada_id, dia, horas, acompaniante_id, acompaniante_nombre, acompaniante_apellido)
--
-- Sin tablas ni columnas nuevas: todo sale de `jornada.acompaniante_id` (0001), que ya existe y
-- que la app ya sube. Interna: jornadas_acompaniadas_de_campania(p_campania_id), la única
-- definición de «una jornada acompañada de esta campaña» para las dos lecturas.
--
-- ## Qué cuenta como un acompañamiento de la campaña
--
--   · Una jornada viva con `acompaniante_id` de un colportor inscripto en p_campania_id, que
--     empezó entre `fecha_inicio` y `fecha_fin` de la campaña (día de Montevideo, ambos
--     incluidos). Una inscripción dada de baja sigue contando lo anterior a la baja (lo hecho no
--     desaparece); lo posterior no.
--   · Las jornadas todavía abiertas (sin `fin`) cuentan: el colportor marcó que lo acompañan
--     mientras trabaja (HU-JOR-003) y eso ya pasó. Su `horas` es null y `en_curso` true.
--   · Acompaña cualquiera (`acompaniante_id` es una FK a `usuario`): no se filtra por rol ni por
--     campaña del acompañante. «De cualquier coordinador» (HU-JOR-004).
--
-- ## Días sin acompañar (HU-JOR-004, vista 33, issue #97)
--
--   dias_sin_acompaniar = hoy - último acompañamiento, en días corridos de Montevideo; sin
--   ninguno, hoy - el INICIO DE LA CAMPAÑA (`contado_desde` dice desde qué día se contó y
--   `ultimo_dia` es null: el panel escribe «Nunca» / «sin acompañamientos»). Sin umbral ni alerta:
--   es informativo. Una campaña por empezar da 0.
--   La HU dice «desde que se inscribió en la campaña»; el issue y el canvas (vista 33: «desde el
--   inicio de la campaña (01/09)») dicen desde el inicio de la campaña. Gana el canvas (mapa de
--   decisiones, principio 3): contado_desde es la fecha de inicio de la campaña.
--
-- ## agregar_acompaniamiento
--
--   El coordinador de la campaña (o un ADMIN) marca «acompañé a este colportor en esta jornada»:
--   `jornada.acompaniante_id := auth.uid()` (HU-JOR-004: «acompañado_por = coordinador_id»).
--   Reglas, en este orden:
--     · permiso (42501) antes de mirar nada; campaña inexistente CZ001; campaña terminada CZ011
--       (ante la duda se bloquea; ver pendiente del PR);
--     · p_jornada_id nulo: 22023;
--     · la jornada no existe, está dada de baja o no es de un colportor de ESTA campaña (en sus
--       fechas, con la inscripción vigente ese día): JO001, el mismo error para las tres (no se
--       averigua qué jornadas hay);
--     · la jornada sigue abierta: JO002 («cuando el colportor la cierre, vas a poder…»);
--     · la jornada ya es del propio coordinador (colportor = quien llama): JO004;
--     · la jornada ya tiene acompañante: si es quien llama, idempotente (`ya_estaba` true, no se
--       toca la fila: un doble toque o un reintento no sube dos veces `sync_version`); si es otra
--       persona, JO003 y NO se pisa (nunca se pierde un dato);
--     · si no, UPDATE bajo `FOR UPDATE`: dos coordinadores que llegan a la vez, uno gana y el
--       otro ve JO003.
--   El UPDATE dispara `tg_auditoria_update` (0011): sube `sync_version` y `updated_at`. Si el
--   teléfono todavía tiene un job de esa jornada, su push da `conflict` (LWW por versión, 0002 §5)
--   y gana el servidor: el acompañamiento no se pierde. La jornada no baja al teléfono (push sin
--   pull), así que la app no se entera; el coordinador es quien lo ve en el panel.
--
-- ## Lo que NO hace (decisiones pendientes, ver el archivo de pendientes del PR)
--
--   · Elegir a OTRO colportor como acompañante (el canvas lo deja; la HU dice el coordinador).
--   · Nota opcional y «de dónde salió el dato» (lo marcó el colportor / lo cargó el coordinador):
--     el canvas los muestra, la HU dice «no hay datos nuevos»: son columnas nuevas.
--   · `audit_log`: no existe la tabla; queda `updated_at` y `acompaniante_id` en la propia fila.
--   · Agregar a una campaña terminada o reemplazar un acompañante ya registrado.
--
-- ## Modelo de permisos y respuesta
--
--   · Las tres, como las lecturas de la vista 24 y 32: `motivo_mapa_de_campania()` lo PRIMERO.
--     Sin JWT, colportor, sin rol, rol vencido o coordinador de otra campaña: 42501 (un colportor
--     no averigua qué campañas hay). ADMIN: cualquier campaña. Campaña inexistente: CZ001.
--     Las dos LECTURAS leen también una campaña terminada (el historial se consulta al cierre);
--     la ESCRITURA no.
--   · SECURITY DEFINER con search_path vacío: el coordinador no lee `jornada` (su RLS es por
--     colportor_id = auth.uid()) ni `usuario` ajeno. Columnas explícitas, nunca `to_jsonb`.
--   · Nunca devuelven clientes, personas visitadas, ventas, importes, ubicaciones, la hora de
--     inicio y fin ni el email: el día, las horas de la jornada y el nombre de quien acompañó.
--   · VOLATILE (llaman a lanzar_motivo_mapa()): supabase-js las manda por POST. EXECUTE solo para
--     `authenticated`.
--
-- ## Para otros repos
--
--   · front-coordinadores-web (vista 33, pestaña «Acompañamientos»):
--       POST /rest/v1/rpc/acompaniamientos_por_colportor   { p_campania_id }   -> la tabla
--       POST /rest/v1/rpc/historial_de_acompaniamientos    { p_campania_id, p_colportor_id }
--                                                          -> «Ver historial» (se abren varios)
--       POST /rest/v1/rpc/jornadas_cerradas_de_colportor   { p_campania_id, p_colportor_id }
--                                                          -> las jornadas entre las que elegir
--       POST /rest/v1/rpc/agregar_acompaniamiento          { p_campania_id, p_jornada_id }
--     «Total» = acompaniamientos; «hace N días» = dias_sin_acompaniar; «Nunca» = ultimo_dia null
--     (con «N días desde el inicio» = dias_sin_acompaniar). La fila de semanas acompañadas (S1 a
--     S8) la arma el panel con los `dia` del historial y las semanas de Reportes. Para elegir en
--     qué jornada registrar el acompañamiento («se registra sobre una jornada que ya existe»,
--     HU-JOR-004: «selecciona jornada finalizada del colportor») está jornadas_cerradas_de_
--     colportor: sus jornadas CERRADAS de la campaña, con quién la acompañó o null si todavía
--     nadie (el panel solo ofrece las de acompañante null).
--   · docs-organizacion: HU-JOR-004 habla de `acompañado_por` y de «desde que se inscribió»; la
--     columna real es `acompaniante_id` y el canvas cuenta desde el inicio de la campaña.
--   · Depende de que las jornadas suban a la nube (backend-supabase#53): hasta entonces las
--     lecturas devuelven ceros y «nunca», que no es un error.
--   · No toca el sync: no hay entidad nueva ni cambia ninguna firma de la app móvil.
--
-- Forward-only: no se edita una vez aplicada.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. Interna: las jornadas acompañadas de una campaña
-- ----------------------------------------------------------------------------

-- Sin permiso a propósito: la llaman solo las funciones de abajo, que lo piden antes. Nadie más
-- tiene EXECUTE (ni service_role): el dueño la ejecuta desde un SECURITY DEFINER.
create function public.jornadas_acompaniadas_de_campania(p_campania_id uuid)
returns table (jornada_id uuid, colportor_id uuid, dia date, horas numeric, en_curso boolean,
               acompaniante_id uuid)
language sql
stable
security definer
set search_path = ''
as $$
  select j.id,
         j.colportor_id,
         public.hoy_montevideo(j.inicio),
         case when j.fin is null then null
              else round(extract(epoch from (j.fin - j.inicio))::numeric / 3600, 2) end,
         (j.fin is null),
         j.acompaniante_id
    from public.campania c
    join public.campania_colportor i on i.campania_id = c.id
    join public.jornada j on j.colportor_id = i.usuario_id
   where c.id = p_campania_id
     and c.deleted_at is null
     and j.deleted_at is null
     and j.acompaniante_id is not null
     and (i.deleted_at is null or j.inicio < i.deleted_at)
     and public.hoy_montevideo(j.inicio) >= c.fecha_inicio
     and public.hoy_montevideo(j.inicio) <= coalesce(c.fecha_fin, 'infinity'::date)
$$;

comment on function public.jornadas_acompaniadas_de_campania(uuid) is
  'Interna (0042, backend-supabase#97): las jornadas vivas con acompañante de los colportores '
  'inscriptos en la campaña (antes de la baja, en sus fechas, día de Montevideo), abiertas '
  'incluidas (horas null). Sin permiso: la usan acompaniamientos_por_colportor() y '
  'historial_de_acompaniamientos(), que lo piden antes.';

revoke all on function public.jornadas_acompaniadas_de_campania(uuid)
  from public, anon, authenticated, service_role;

-- ----------------------------------------------------------------------------
-- 2. La tabla de la vista 33: por colportor, el total y los días sin acompañar
-- ----------------------------------------------------------------------------

create function public.acompaniamientos_por_colportor(p_campania_id uuid)
returns table (colportor_id uuid, nombre text, apellido text, ciudad_id uuid, ciudad_nombre text,
               acompaniamientos integer, ultimo_dia date, dias_sin_acompaniar integer,
               contado_desde date)
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_motivo   text;
  v_campania public.campania;
  v_hoy      date := public.hoy_montevideo();
begin
  -- El permiso, antes de mirar nada más. Una campaña terminada se lee (el historial se consulta
  -- también al cierre); una por empezar, también.
  v_motivo := public.motivo_mapa_de_campania(p_campania_id);
  if v_motivo = 'SIN_PERMISO' then
    raise exception 'Solo el coordinador de la campaña o un administrador puede ver sus acompañamientos. Entrá con la cuenta del coordinador de esta campaña.'
      using errcode = 'insufficient_privilege';
  end if;
  if v_motivo is distinct from 'CAMPANIA_TERMINADA' then
    perform public.lanzar_motivo_mapa(v_motivo);
  end if;

  select * into v_campania from public.campania c where c.id = p_campania_id;

  return query
    with acompaniadas as (
      select h.colportor_id as colp,
             count(*)::integer as total,
             max(h.dia) as ultimo
        from public.jornadas_acompaniadas_de_campania(p_campania_id) h
       group by h.colportor_id
    )
    select i.usuario_id,
           usr.nombre,
           usr.apellido,
           ci.ciudad_id,
           ciu.nombre,
           coalesce(a.total, 0),
           a.ultimo,
           greatest(v_hoy - coalesce(a.ultimo, v_campania.fecha_inicio), 0),
           coalesce(a.ultimo, v_campania.fecha_inicio)
      from public.campania_colportor i
      join public.usuario usr on usr.id = i.usuario_id
      -- La ciudad es la de la zona actual (decisión del 21/10, «Ciudad colp.»); sin zona, null.
      left join public.zona z on z.id = i.zona_id and z.deleted_at is null
      left join public.campania_ciudad ci on ci.id = z.campania_ciudad_id and ci.deleted_at is null
      left join public.ciudad ciu on ciu.id = ci.ciudad_id
      left join acompaniadas a on a.colp = i.usuario_id
     where i.campania_id = p_campania_id
       and i.deleted_at is null
     order by 8 desc, usr.apellido, usr.nombre, i.usuario_id;
end;
$$;

comment on function public.acompaniamientos_por_colportor(uuid) is
  'Vista 33, HU-JOR-004 (0042, backend-supabase#97): por colportor inscripto (vivo) de la '
  'campaña, cuántas jornadas acompañadas tiene, el día del último y los días corridos sin '
  'acompañar (desde el último o, si nunca, desde el inicio de la campaña: contado_desde; sin '
  'umbral). Orden: más días sin acompañar primero. Una campaña terminada se lee. Errores: 42501 '
  'sin permiso; CZ001 campaña inexistente. Solo totales: ni clientes ni ventas.';

revoke all on function public.acompaniamientos_por_colportor(uuid)
  from public, anon, authenticated, service_role;
grant execute on function public.acompaniamientos_por_colportor(uuid) to authenticated;

-- ----------------------------------------------------------------------------
-- 3. «Ver historial»: las jornadas acompañadas de un colportor (o de todos)
-- ----------------------------------------------------------------------------

create function public.historial_de_acompaniamientos(p_campania_id uuid,
                                                     p_colportor_id uuid default null)
returns table (jornada_id uuid, colportor_id uuid, nombre text, apellido text, dia date,
               horas numeric, en_curso boolean, acompaniante_id uuid,
               acompaniante_nombre text, acompaniante_apellido text)
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_motivo text;
begin
  v_motivo := public.motivo_mapa_de_campania(p_campania_id);
  if v_motivo = 'SIN_PERMISO' then
    raise exception 'Solo el coordinador de la campaña o un administrador puede ver sus acompañamientos. Entrá con la cuenta del coordinador de esta campaña.'
      using errcode = 'insufficient_privilege';
  end if;
  if v_motivo is distinct from 'CAMPANIA_TERMINADA' then
    perform public.lanzar_motivo_mapa(v_motivo);
  end if;

  return query
    select h.jornada_id,
           h.colportor_id,
           usr.nombre,
           usr.apellido,
           h.dia,
           h.horas,
           h.en_curso,
           h.acompaniante_id,
           aco.nombre,
           aco.apellido
      from public.jornadas_acompaniadas_de_campania(p_campania_id) h
      join public.usuario usr on usr.id = h.colportor_id
      join public.usuario aco on aco.id = h.acompaniante_id
     where p_colportor_id is null or h.colportor_id = p_colportor_id
     order by h.dia desc, h.jornada_id desc;
end;
$$;

comment on function public.historial_de_acompaniamientos(uuid, uuid) is
  'Vista 33, HU-JOR-004 (0042, backend-supabase#97): las jornadas acompañadas de la campaña '
  '(de p_colportor_id, o de todos si es null), la más nueva primero: día de Montevideo, horas de '
  'la jornada (null si sigue abierta) y quién acompañó. Una campaña terminada se lee. Un colportor '
  'que no es de la campaña da la lista vacía. Errores: 42501 sin permiso; CZ001 campaña '
  'inexistente.';

revoke all on function public.historial_de_acompaniamientos(uuid, uuid)
  from public, anon, authenticated, service_role;
grant execute on function public.historial_de_acompaniamientos(uuid, uuid) to authenticated;

-- ----------------------------------------------------------------------------
-- 4. Agregar un acompañamiento a una jornada finalizada
-- ----------------------------------------------------------------------------

create function public.agregar_acompaniamiento(p_campania_id uuid, p_jornada_id uuid)
returns table (jornada_id uuid, colportor_id uuid, dia date, acompaniante_id uuid,
               acompaniante_nombre text, acompaniante_apellido text, ya_estaba boolean)
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_motivo   text;
  v_campania public.campania;
  v_jornada  public.jornada;
  v_yo       uuid := auth.uid();
  v_otro     text;
begin
  -- El permiso, antes de mirar nada más.
  v_motivo := public.motivo_mapa_de_campania(p_campania_id);
  if v_motivo = 'SIN_PERMISO' then
    raise exception 'Solo el coordinador de la campaña o un administrador puede registrar acompañamientos. Entrá con la cuenta del coordinador de esta campaña.'
      using errcode = 'insufficient_privilege';
  end if;
  if v_motivo = 'CAMPANIA_TERMINADA' then
    raise exception 'La campaña ya terminó y sus acompañamientos quedan como están. Elegí una campaña en curso.'
      using errcode = 'CZ011';
  end if;
  perform public.lanzar_motivo_mapa(v_motivo);

  if p_jornada_id is null then
    raise exception 'Elegí la jornada del colportor a la que querés agregar tu acompañamiento.'
      using errcode = 'invalid_parameter_value';
  end if;

  select * into v_campania from public.campania c where c.id = p_campania_id;

  -- La jornada, solo si es de un colportor de esta campaña (inscripción vigente ese día, en las
  -- fechas de la campaña). Con candado: el doble toque y dos coordinadores se serializan acá.
  select j.* into v_jornada
    from public.jornada j
    join public.campania_colportor i
      on i.usuario_id = j.colportor_id and i.campania_id = p_campania_id
   where j.id = p_jornada_id
     and j.deleted_at is null
     and (i.deleted_at is null or j.inicio < i.deleted_at)
     and public.hoy_montevideo(j.inicio) >= v_campania.fecha_inicio
     and public.hoy_montevideo(j.inicio) <= coalesce(v_campania.fecha_fin, 'infinity'::date)
     for update of j;
  if not found then
    raise exception 'La jornada no existe o no es de un colportor de esta campaña. Recargá el historial del colportor y elegí otra.'
      using errcode = 'JO001';
  end if;

  if v_jornada.fin is null then
    raise exception 'La jornada todavía no terminó. Cuando el colportor la cierre vas a poder agregar tu acompañamiento.'
      using errcode = 'JO002';
  end if;

  if v_jornada.colportor_id = v_yo then
    raise exception 'No podés registrarte como acompañante de tu propia jornada. Elegí una jornada de otro colportor.'
      using errcode = 'JO004';
  end if;

  if v_jornada.acompaniante_id is not null and v_jornada.acompaniante_id <> v_yo then
    select trim(coalesce(u.nombre, '') || ' ' || coalesce(u.apellido, '')) into v_otro
      from public.usuario u where u.id = v_jornada.acompaniante_id;
    raise exception 'Esta jornada ya figura acompañada por %. El acompañamiento registrado no se cambia desde el panel.',
      coalesce(nullif(v_otro, ''), 'otra persona')
      using errcode = 'JO003';
  end if;

  if v_jornada.acompaniante_id is null then
    update public.jornada j set acompaniante_id = v_yo where j.id = v_jornada.id;
  end if;

  return query
    select v_jornada.id,
           v_jornada.colportor_id,
           public.hoy_montevideo(v_jornada.inicio),
           v_yo,
           usr.nombre,
           usr.apellido,
           (v_jornada.acompaniante_id is not null)
      from public.usuario usr
     where usr.id = v_yo;
end;
$$;

comment on function public.agregar_acompaniamiento(uuid, uuid) is
  'Vista 33, HU-JOR-004 (0042, backend-supabase#97): el coordinador de la campaña (o un ADMIN) '
  'registra que acompañó al colportor en una jornada ya cerrada: jornada.acompaniante_id = '
  'auth.uid(). Idempotente (ya_estaba) si ya era él; si la acompañó otra persona, JO003 y no se '
  'pisa. Errores: 42501 sin permiso; CZ001 campaña inexistente; CZ011 campaña terminada; 22023 '
  'sin jornada; JO001 jornada que no es de un colportor de la campaña; JO002 jornada abierta; '
  'JO003 ya acompañada por otra persona; JO004 la jornada es del propio coordinador.';

revoke all on function public.agregar_acompaniamiento(uuid, uuid)
  from public, anon, authenticated, service_role;
grant execute on function public.agregar_acompaniamiento(uuid, uuid) to authenticated;

-- ----------------------------------------------------------------------------
-- 5. Las jornadas cerradas de un colportor, para elegir en cuál registrar
-- ----------------------------------------------------------------------------

create function public.jornadas_cerradas_de_colportor(p_campania_id uuid, p_colportor_id uuid)
returns table (jornada_id uuid, dia date, horas numeric, acompaniante_id uuid,
               acompaniante_nombre text, acompaniante_apellido text)
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_motivo   text;
  v_campania public.campania;
begin
  v_motivo := public.motivo_mapa_de_campania(p_campania_id);
  if v_motivo = 'SIN_PERMISO' then
    raise exception 'Solo el coordinador de la campaña o un administrador puede ver sus jornadas. Entrá con la cuenta del coordinador de esta campaña.'
      using errcode = 'insufficient_privilege';
  end if;
  if v_motivo is distinct from 'CAMPANIA_TERMINADA' then
    perform public.lanzar_motivo_mapa(v_motivo);
  end if;

  select * into v_campania from public.campania c where c.id = p_campania_id;

  -- Las mismas jornadas que cuentan para la campaña (fechas, baja de la inscripción, día de
  -- Montevideo), pero solo las cerradas, con o sin acompañante. Un colportor que no es de la
  -- campaña (o null) da la lista vacía.
  return query
    select j.id,
           public.hoy_montevideo(j.inicio),
           round(extract(epoch from (j.fin - j.inicio))::numeric / 3600, 2),
           j.acompaniante_id,
           aco.nombre,
           aco.apellido
      from public.campania_colportor i
      join public.jornada j on j.colportor_id = i.usuario_id
      left join public.usuario aco on aco.id = j.acompaniante_id
     where i.campania_id = p_campania_id
       and i.usuario_id = p_colportor_id
       and j.deleted_at is null
       and j.fin is not null
       and (i.deleted_at is null or j.inicio < i.deleted_at)
       and public.hoy_montevideo(j.inicio) >= v_campania.fecha_inicio
       and public.hoy_montevideo(j.inicio) <= coalesce(v_campania.fecha_fin, 'infinity'::date)
     order by public.hoy_montevideo(j.inicio) desc, j.inicio desc, j.id desc;
end;
$$;

comment on function public.jornadas_cerradas_de_colportor(uuid, uuid) is
  'Vista 33, HU-JOR-004 (0042, backend-supabase#97): las jornadas CERRADAS de p_colportor_id en '
  'la campaña (fechas de la campaña, antes de la baja de la inscripción, día de Montevideo), la '
  'más nueva primero, con sus horas y quién la acompañó (null si nadie todavía): de ahí elige el '
  'coordinador a cuál agregar su acompañamiento. Un colportor que no es de la campaña da la lista '
  'vacía. Una campaña terminada se lee. Errores: 42501 sin permiso; CZ001 campaña inexistente.';

revoke all on function public.jornadas_cerradas_de_colportor(uuid, uuid)
  from public, anon, authenticated, service_role;
grant execute on function public.jornadas_cerradas_de_colportor(uuid, uuid) to authenticated;
