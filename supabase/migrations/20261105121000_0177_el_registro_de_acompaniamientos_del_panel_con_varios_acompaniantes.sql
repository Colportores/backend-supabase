-- ============================================================================
-- 0177 · El registro de acompañamientos del panel con varios acompañantes por jornada, y «quién acompaña» sin ataduras
--        de campaña para coordinadores y administradores
--        (backend-supabase#254, casillas «Dos acomp.» y «Valida acomp»; sigue a la 0176)
--
-- ## El caso
--
-- Luis, coordinador, abre el historial de Ana y ve la jornada del martes con un acompañante: Daniel, que lo marcó ella en
-- el teléfono. Quiere anotar además a un coordinador de otra campaña, Marta, que vino ese día. Hasta hoy el panel
-- rechazaba la segunda persona (`JO003`) y a cualquiera que no fuera un colportor inscripto en la campaña (`JO005`).
--
-- ## Qué cambia (las RPC del registro del panel; los permisos de la 0175 siguen)
--
--   · `agregar_acompaniamiento(campania, jornada, acompaniante, nota)` **suma** un acompañante a la jornada: ya no hay
--     `JO003` (nunca se pisa a nadie: se agrega al lado). Idempotente por persona: si ya figura esa persona, `ya_estaba`
--     es `true` y la fila no se toca. `JO001`, `JO002`, `JO004` y `CZ011` como siempre.
--   · **`JO005` ahora solo rechaza a un colportor que no está inscripto vivo en la campaña**: un coordinador o un
--     administrador (de cualquier campaña) se puede anotar siempre. Decisión de Cristian (05/11, «Valida acomp»): «hay
--     otros coordinadores de otras campañas que pueden acompañar; en el dashboard aparecen todos los coordinadores y lo
--     puede añadir el coordinador».
--   · `historial_de_acompaniamientos` y `jornadas_cerradas_de_colportor` devuelven **una fila por acompañante** de cada
--     jornada (las columnas no cambian). Una jornada con dos acompañantes sale dos veces, con el mismo día y las mismas
--     horas; la jornada sin acompañante, una vez con el acompañante en null.
--   · `jornadas_acompaniadas_de_campania` (y por ende `acompaniamientos_por_colportor` y las horas por ciudad) sigue con
--     **una fila por jornada**: una jornada acompañada cuenta una sola vez aunque tenga varios acompañantes («los días
--     acompañados se cuentan una vez por jornada»). Trae el primer acompañante y su origen y nota.
--   · `cuenta_tiene_rol(usuario, rol)`: interna, el mismo criterio de `tiene_rol()` para otra persona (el rol vigente de
--     una cuenta activa), para decidir `JO005`.
--
-- ## Los datos
--
-- Solo funciones. Lo prueba supabase/tests/0176_… . Forward-only.
--
-- ## Para otros repos
--
--   · front-coordinadores-web#144: el registro agrupa por `jornada_id` (una fila por acompañante); la lista de quién puede
--     acompañar trae a todos los coordinadores (cualquier campaña) además de los colportores del equipo.
--   · docs-organizacion#172: HU-JOR-003/004, `esquema-datos.md` y el contrato.
--
-- Forward-only: esta migración no se edita una vez aplicada.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. El rol de otra persona
-- ----------------------------------------------------------------------------

create function public.cuenta_tiene_rol(p_usuario_id uuid, p_codigo text)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
      from public.usuario_rol ur
      join public.rol r on r.id = ur.rol_id
      join public.usuario u on u.id = ur.usuario_id
     where ur.usuario_id = p_usuario_id
       and r.codigo = p_codigo
       and ur.deleted_at is null
       and u.deleted_at is null
       and u.suspendido_en is null
       and r.deleted_at is null
       and (ur.valido_desde is null or ur.valido_desde <= now())
       and (ur.valido_hasta is null or ur.valido_hasta > now()));
$$;

comment on function public.cuenta_tiene_rol(uuid, text) is
  'true si esa cuenta tiene hoy ese rol (vigente, de una cuenta activa y no suspendida): el criterio de tiene_rol() para '
  'otra persona (0177). La usa agregar_acompaniamiento() para decidir JO005. Interna: nadie con JWT la llama.';

revoke all on function public.cuenta_tiene_rol(uuid, text) from public, anon, authenticated, service_role;

-- ----------------------------------------------------------------------------
-- 2. Las RPC del panel
-- ----------------------------------------------------------------------------

-- jornadas_acompaniadas_de_campania: una fila por jornada
create or replace function public.jornadas_acompaniadas_de_campania(p_campania_id uuid)
 RETURNS TABLE(jornada_id uuid, colportor_id uuid, dia date, horas numeric, en_curso boolean, acompaniante_id uuid, acompaniamiento_origen text, acompaniamiento_nota text)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $$
  select j.id,
         j.colportor_id,
         public.hoy_montevideo(j.inicio),
         case when j.fin is null then null
              else round(extract(epoch from (j.fin - j.inicio))::numeric / 3600, 2) end,
         (j.fin is null),
         j.acompaniante_id,
         d.origen,
         d.nota
    from public.campania c
    join public.campania_colportor i on i.campania_id = c.id
    join public.jornada j on j.colportor_id = i.usuario_id
    left join public.jornada_acompaniamiento d
      on d.jornada_id = j.id and d.acompaniante_id = j.acompaniante_id and d.deleted_at is null
   where c.id = p_campania_id
     and c.deleted_at is null
     and j.deleted_at is null
     and j.acompaniante_id is not null
     and public.inscripcion_cubre_el_instante(i.created_at, i.deleted_at, i.tramos_afuera, j.inicio)
     and public.hoy_montevideo(j.inicio) >= c.fecha_inicio
     and public.hoy_montevideo(j.inicio) <= coalesce(c.fecha_fin, 'infinity'::date)
$$;

-- agregar_acompaniamiento: suma un acompañante
create or replace function public.agregar_acompaniamiento(p_campania_id uuid, p_jornada_id uuid, p_acompaniante_id uuid DEFAULT NULL::uuid, p_nota text DEFAULT NULL::text)
 RETURNS TABLE(jornada_id uuid, colportor_id uuid, dia date, acompaniante_id uuid, acompaniante_nombre text, acompaniante_apellido text, ya_estaba boolean, acompaniamiento_origen text, acompaniamiento_nota text)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $$
declare
  v_motivo   text;
  v_campania public.campania;
  v_jornada  public.jornada;
  v_yo       uuid := auth.uid();
  v_acomp    uuid;
  v_nota     text;
  v_existente uuid;
  v_origen   text;
begin
  -- El permiso, antes de mirar nada más.
  v_motivo := public.motivo_mapa_de_campania(p_campania_id);
  if v_motivo = 'SIN_PERMISO' then
    raise exception 'Solo el coordinador de la campaña o un administrador puede registrar acompañamientos. Entrá con la cuenta del coordinador de esta campaña.'
      using errcode = 'insufficient_privilege';
  end if;

  -- Una campaña terminada admite el registro hasta 15 días después de su fin: la misma regla de las
  -- ventas (escritura_dentro_de_plazo, 0020). Pasado el plazo, CZ011 como siempre.
  if v_motivo = 'CAMPANIA_TERMINADA' then
    select * into v_campania from public.campania c where c.id = p_campania_id;
    if not public.escritura_dentro_de_plazo(v_campania.fecha_fin) then
      raise exception 'La campaña terminó hace más de 15 días y sus acompañamientos quedan como están. Elegí una campaña en curso o que haya terminado hace 15 días o menos.'
        using errcode = 'CZ011';
    end if;
  else
    perform public.lanzar_motivo_mapa(v_motivo);
    select * into v_campania from public.campania c where c.id = p_campania_id;
  end if;

  if p_jornada_id is null then
    raise exception 'Elegí la jornada del colportor a la que querés agregar el acompañamiento.'
      using errcode = 'invalid_parameter_value';
  end if;

  -- La nota: sin espacios ni saltos de línea en los extremos; vacía es sin nota.
  v_nota := nullif(regexp_replace(coalesce(p_nota, ''), '^\s+|\s+$', '', 'g'), '');
  if char_length(v_nota) > 500 then
    raise exception 'La nota admite hasta 500 caracteres y esta tiene %. Acortala; no pongas datos de clientes.',
      char_length(v_nota)
      using errcode = 'invalid_parameter_value';
  end if;

  -- «Yo» (sin p_acompaniante_id, o el propio) u otro colportor.
  v_acomp := coalesce(p_acompaniante_id, v_yo);

  -- La jornada, solo si es de un colportor de esta campaña (inscripción vigente ese día y fuera de sus
  -- huecos, en las fechas de la campaña). Con candado: el doble toque y dos coordinadores se serializan acá.
  select j.* into v_jornada
    from public.jornada j
    join public.campania_colportor i
      on i.usuario_id = j.colportor_id and i.campania_id = p_campania_id
   where j.id = p_jornada_id
     and j.deleted_at is null
     and public.inscripcion_cubre_el_instante(i.created_at, i.deleted_at, i.tramos_afuera, j.inicio)
     and public.hoy_montevideo(j.inicio) >= v_campania.fecha_inicio
     and public.hoy_montevideo(j.inicio) <= coalesce(v_campania.fecha_fin, 'infinity'::date)
     for update of j;
  if not found then
    raise exception 'La jornada no existe o no es de un colportor de esta campaña. Recargá el historial del colportor y elegí otra.'
      using errcode = 'JO001';
  end if;

  if v_jornada.fin is null then
    raise exception 'La jornada todavía no terminó. Cuando el colportor la cierre vas a poder agregar el acompañamiento.'
      using errcode = 'JO002';
  end if;

  if v_jornada.colportor_id = v_acomp then
    raise exception '%',
      case when v_acomp = v_yo
           then 'No podés registrarte como acompañante de tu propia jornada. Elegí una jornada de otro colportor.'
           else 'Un colportor no puede figurar como acompañante de su propia jornada. Elegí a otra persona.' end
      using errcode = 'JO004';
  end if;

  -- Una jornada puede tener varios acompañantes (0176): se suma uno más, nunca se pisa a otro. Ya registrado por la misma
  -- persona: idempotente, no se toca la fila (ni se cambia la nota).
  select a.id into v_existente
    from public.jornada_acompaniante a
   where a.jornada_id = v_jornada.id and a.acompaniante_id = v_acomp and a.deleted_at is null;

  if v_existente is null then
    -- Otro colportor: tiene que estar inscripto (vivo) en la campaña de la jornada. Un coordinador o un administrador
    -- (de esta campaña o de cualquier otra) se puede anotar siempre (decisión de Cristian, 05/11, «Valida acomp»).
    if v_acomp <> v_yo
       and not exists (
         select 1 from public.campania_colportor ac
          where ac.campania_id = p_campania_id and ac.usuario_id = v_acomp and ac.deleted_at is null)
       and not public.cuenta_tiene_rol(v_acomp, 'COORDINADOR')
       and not public.cuenta_tiene_rol(v_acomp, 'ADMIN') then
      raise exception 'Ese colportor no está inscripto en esta campaña. Elegí a alguien de su equipo o a un coordinador.'
        using errcode = 'JO005';
    end if;

    -- Quién lo cargó (0116, #173): quien llama, que es el coordinador de la campaña o un ADMIN. Lo pone el
    -- servidor con auth.uid() y el cliente no lo elige.
    -- created_at con el reloj real: el orden de los acompañantes (el primero vigente es el que queda en la jornada)
    -- no depende de que dos altas caigan en la misma transacción.
    insert into public.jornada_acompaniante (jornada_id, colportor_id, acompaniante_id, cargado_por, created_at)
    values (v_jornada.id, v_jornada.colportor_id, v_acomp, v_yo, clock_timestamp());

    -- El origen y la nota (0133, #204; una fila por acompañante desde la 0176): en la tabla interna, que no lee el
    -- colportor. El trigger de la tabla acaba de dejar la fila con origen COLPORTOR; acá pasa a COORDINADOR con la nota.
    insert into public.jornada_acompaniamiento (jornada_id, acompaniante_id, origen, nota)
    values (v_jornada.id, v_acomp, 'COORDINADOR', v_nota)
    on conflict on constraint jornada_acompaniamiento_jornada_acompaniante_key do update
      set origen = excluded.origen,
          nota = excluded.nota,
          deleted_at = null;
    v_origen := 'COORDINADOR';

    -- HU-JOR-004: «`audit_log` registra el cambio». Quién (actor) = quien lo cargó; sobre quién (target) = el
    -- colportor acompañado; el detalle, la campaña, el día, quién acompañó y si hubo nota: nunca nombres
    -- ni el texto de la nota.
    perform auditoria.registrar(
      'acompaniamiento_agregado', 'jornada', v_jornada.id, v_jornada.colportor_id,
      jsonb_build_object('campania_id', p_campania_id,
                         'dia', public.hoy_montevideo(v_jornada.inicio),
                         'acompaniante_id', v_acomp,
                         'con_nota', (v_nota is not null)));
  else
    select d.nota, d.origen into v_nota, v_origen
      from public.jornada_acompaniamiento d
     where d.jornada_id = v_jornada.id and d.acompaniante_id = v_acomp and d.deleted_at is null;
  end if;

  return query
    select v_jornada.id,
           v_jornada.colportor_id,
           public.hoy_montevideo(v_jornada.inicio),
           v_acomp,
           usr.nombre,
           usr.apellido,
           (v_existente is not null),
           v_origen,
           v_nota
      from public.usuario usr
     where usr.id = v_acomp;
end;
$$;

-- historial_de_acompaniamientos: una fila por acompañante
create or replace function public.historial_de_acompaniamientos(p_campania_id uuid, p_colportor_id uuid DEFAULT NULL::uuid)
 RETURNS TABLE(jornada_id uuid, colportor_id uuid, nombre text, apellido text, dia date, horas numeric, en_curso boolean, acompaniante_id uuid, acompaniante_nombre text, acompaniante_apellido text, acompaniamiento_origen text, acompaniamiento_nota text, acompaniamiento_cargado_por uuid, acompaniamiento_cargado_por_nombre text, acompaniamiento_cargado_por_apellido text)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $$
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

  -- Una fila por acompañante de cada jornada acompañada (0176): una jornada con dos acompañantes sale dos veces, con el
  -- mismo día y las mismas horas. Quien cuente jornadas o días acompañados cuenta los jornada_id distintos.
  return query
    select h.jornada_id,
           h.colportor_id,
           usr.nombre,
           usr.apellido,
           h.dia,
           h.horas,
           h.en_curso,
           a.acompaniante_id,
           aco.nombre,
           aco.apellido,
           d.origen,
           d.nota,
           a.cargado_por,
           car.nombre,
           car.apellido
      from public.jornadas_acompaniadas_de_campania(p_campania_id) h
      join public.jornada_acompaniante a on a.jornada_id = h.jornada_id and a.deleted_at is null
      join public.usuario usr on usr.id = h.colportor_id
      join public.usuario aco on aco.id = a.acompaniante_id
      left join public.jornada_acompaniamiento d
        on d.jornada_id = a.jornada_id and d.acompaniante_id = a.acompaniante_id and d.deleted_at is null
      left join public.usuario car on car.id = a.cargado_por
     where p_colportor_id is null or h.colportor_id = p_colportor_id
     order by h.dia desc, h.jornada_id desc, a.created_at, a.id;
end;
$$;

-- jornadas_cerradas_de_colportor: una fila por acompañante
create or replace function public.jornadas_cerradas_de_colportor(p_campania_id uuid, p_colportor_id uuid)
 RETURNS TABLE(jornada_id uuid, dia date, horas numeric, acompaniante_id uuid, acompaniante_nombre text, acompaniante_apellido text, acompaniamiento_origen text, acompaniamiento_nota text, acompaniamiento_cargado_por uuid, acompaniamiento_cargado_por_nombre text, acompaniamiento_cargado_por_apellido text)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $$
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

  -- Las mismas jornadas que cuentan para la campaña (fechas, baja y huecos de la inscripción, día de
  -- Montevideo), pero solo las cerradas, con o sin acompañante. Una fila por acompañante (0176): una jornada con dos
  -- acompañantes sale dos veces; una sin acompañante, una vez con los datos del acompañante en null. Un colportor que
  -- no es de la campaña (o null) da la lista vacía.
  return query
    select j.id,
           public.hoy_montevideo(j.inicio),
           round(extract(epoch from (j.fin - j.inicio))::numeric / 3600, 2),
           a.acompaniante_id,
           aco.nombre,
           aco.apellido,
           d.origen,
           d.nota,
           a.cargado_por,
           car.nombre,
           car.apellido
      from public.campania_colportor i
      join public.jornada j on j.colportor_id = i.usuario_id
      left join public.jornada_acompaniante a on a.jornada_id = j.id and a.deleted_at is null
      left join public.usuario aco on aco.id = a.acompaniante_id
      left join public.usuario car on car.id = a.cargado_por
      left join public.jornada_acompaniamiento d
        on d.jornada_id = j.id and d.acompaniante_id = a.acompaniante_id and d.deleted_at is null
     where i.campania_id = p_campania_id
       and i.usuario_id = p_colportor_id
       and j.deleted_at is null
       and j.fin is not null
       and public.inscripcion_cubre_el_instante(i.created_at, i.deleted_at, i.tramos_afuera, j.inicio)
       and public.hoy_montevideo(j.inicio) >= v_campania.fecha_inicio
       and public.hoy_montevideo(j.inicio) <= coalesce(v_campania.fecha_fin, 'infinity'::date)
     order by public.hoy_montevideo(j.inicio) desc, j.inicio desc, j.id desc, a.created_at, a.id;
end;
$$;

comment on function public.agregar_acompaniamiento(uuid, uuid, uuid, text) is
  '«Registrar acompañamiento» (HU-JOR-004; 0043, 0073, 0100, 0103, 0116, 0133; 0176/0177, #254): el coordinador de la '
  'campaña (o un ADMIN) suma un acompañante a una jornada ya cerrada de un colportor de esa campaña. Una jornada puede '
  'tener varios: se agrega al lado, nunca se pisa a otro (ya no hay JO003). Sin p_acompaniante_id (o con el propio) es '
  '«Yo»; con el de otra persona, tiene que ser un colportor inscripto vivo en la campaña de la jornada, o un coordinador o '
  'administrador de cualquier campaña (JO005 si no). Idempotente por persona: ya_estaba = true y la fila no se toca. Deja '
  'el origen COORDINADOR y la nota (opcional, hasta 500 caracteres) en jornada_acompaniamiento. Errores: 42501 sin '
  'permiso; CZ001 campaña inexistente; CZ011 terminada hace más de 15 días; 22023 sin jornada o nota larga; JO001 la '
  'jornada no es de un colportor de la campaña; JO002 abierta; JO004 la jornada es de quien se quiere anotar; JO005 el '
  'colportor elegido no está inscripto en la campaña. Deja el evento acompaniamiento_agregado en audit_log.';

comment on function public.historial_de_acompaniamientos(uuid, uuid) is
  'Historial de acompañamientos de la campaña (0043, 0100, 0116, 0133; 0177, #254): una fila por acompañante de cada '
  'jornada acompañada, con día, horas, quién acompañó, el origen y la nota (internos de coordinación) y quién lo cargó '
  'desde el panel. Una jornada con dos acompañantes sale dos veces: quien cuente jornadas cuenta jornada_id distintos. '
  'Permiso: coordinador de la campaña o ADMIN; las campañas terminadas se leen.';

comment on function public.jornadas_cerradas_de_colportor(uuid, uuid) is
  'Jornadas cerradas de un colportor de la campaña (0043, 0100, 0116, 0133; 0177, #254), con o sin acompañante: una fila '
  'por acompañante (una jornada sin acompañante sale una vez, con el acompañante en null). Permiso: coordinador de la '
  'campaña o ADMIN; las campañas terminadas se leen.';

comment on function public.jornadas_acompaniadas_de_campania(uuid) is
  'Las jornadas acompañadas de la campaña (0043, 0100; 0177): UNA fila por jornada aunque tenga varios acompañantes (los '
  'días acompañados se cuentan una vez por jornada), con el primer acompañante (el más antiguo) y su origen y nota. La '
  'usan acompaniamientos_por_colportor() y el historial. Interna.';
