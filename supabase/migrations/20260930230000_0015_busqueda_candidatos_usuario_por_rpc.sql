-- ============================================================================
-- 0015 · Búsqueda de candidatos en el servidor y `usuario` acotado a RPCs
--        (backend-supabase#41)
--
-- Decisiones de Cristian del 30/09:
--   · front-coordinadores-web#29, punto 1: «Búsqueda: en el servidor. Cada búsqueda consulta
--     al backend y devuelve pocas cuentas.» Punto 3: «Sugeridos: más nuevos primero (las 5
--     cuentas pendientes de asignación, por fecha de creación descendente).»
--   · front-coordinadores-web#20, punto 5: «`usuario`: se acota a RPCs. El coordinador deja
--     de leer la tabla directo. Ve a los colportores de sus campañas (nombre, email y estado)
--     y busca candidatos solo con el RPC de búsqueda de la vista 23, que devuelve pocas
--     cuentas y solo esas columnas.»
--
-- ## 1. Qué ve el coordinador de `usuario`
--
-- Antes (0003, usuario_select_propio_o_staff) cualquier COORDINADOR leía todas las filas y
-- columnas de public.usuario por PostgREST, email incluido, aunque la campaña no fuera suya.
-- Ahora la política es usuario_select_propio_o_admin: cada uno lee SU fila (la necesita el
-- GET /v1/me de los dos BFF) y el ADMIN, todas. El coordinador llega a las cuentas ajenas
-- solo por dos RPC SECURITY DEFINER, que acotan filas y columnas:
--
--   colportores_de_campania(campania)          los inscriptos de su campaña (0007), que
--                                              ahora suma email y estado (punto 5).
--   buscar_candidatos(campania, texto)         la búsqueda de la vista 23 (sección 3).
--
-- Ninguna función de la base leía cuentas ajenas con la RLS del coordinador (todas las que
-- leen usuario son DEFINER; estado_cuenta() es INVOKER pero lee solo la fila propia), y
-- usuario no está en sync.entidad, así que cerrar la política no rompe ningún camino.
--
-- ## 2. El estado de la cuenta, en un solo lugar
--
-- La precedencia (SUSPENDIDA gana; si no, ACTIVA con una inscripción vigente; si no,
-- PENDIENTE_ASIGNACION) estaba escrita adentro de estado_cuenta() (0004). Ahora hace falta
-- también para cuentas ajenas, así que pasa a estado_de_cuenta(suspendido_en, con_vigente):
-- una función pura, sin acceso a datos, que usan estado_cuenta() y los dos RPC. «Vigente»
-- sigue escrito una sola vez, en campanias_vigentes_de() (0005). estado_cuenta() no cambia de
-- firma, de resultado ni de seguridad (sigue INVOKER).
--
-- ## 3. buscar_candidatos(p_campania_id, p_texto)
--
-- SECURITY DEFINER, como las lecturas de 0007. El permiso es lo primero, con el mismo tramo que
-- inscribir_colportor() (motivo_campania_del_coordinador(): el coordinador de esa campaña o un
-- ADMIN, campaña vigente) y sus mismos códigos: 42501 sin permiso, CI001 campaña inexistente,
-- CI002 no vigente. Es la lectura del formulario de esa acción.
--
-- Qué cuentas son candidatas (diseño de la vista 23, «Solo aparecen cuentas pendientes de
-- asignación o activas sin campaña», y «Las cuentas suspendidas o con otra campaña aparecen en
-- la búsqueda, con "Añadir" deshabilitado y el motivo»):
--   · vivas (sin deleted_at) y con el email verificado (inscribir rechaza el resto: CI003, CI004);
--   · que no estén ya en el equipo: sin inscripción viva en ESTA campaña (las muestra
--     colportores_de_campania(), el «Ya en tu equipo»).
-- Las suspendidas, las que están en otra campaña vigente y las que tienen una inscripción dada
-- de baja en esta campaña aparecen, con su motivo.
--
-- Dos modos:
--   · texto vacío (null, '' o solo espacios): los SUGERIDOS, hasta 5 cuentas con estado
--     PENDIENTE_ASIGNACION, de la más nueva a la más vieja (created_at desc, id desc como
--     desempate estable).
--   · con texto: hasta 10 cuentas cuyo nombre completo («nombre apellido») o email CONTIENE el
--     texto, sin distinguir mayúsculas ni tildes («martinez» encuentra «Martínez»). El texto se
--     busca literal (strpos, no LIKE: un «%» o un «_» no son comodines). Orden: primero las que
--     EMPIEZAN con el texto (el nombre completo, el apellido o el email), después por nombre
--     completo normalizado con collate "C" (palabra por palabra: «ana martinez» antes que
--     «anabel»; la collation de la base ignora los espacios), y el id como desempate.
--
-- Columnas, las que usa la vista 23 (CandidatoColportor en front-coordinadores-web):
--   usuario_id, nombre, apellido, email, estado (PENDIENTE_ASIGNACION | ACTIVA | SUSPENDIDA,
--   como estado_cuenta()), campania_actual (nombre de la campaña vigente en la que está, o null:
--   «Campaña actual» y «Está en campaña X. Reasignar primero.» del criterio de la HU),
--   creada_en («Cuenta creada») y motivo_bloqueo.
-- motivo_bloqueo es el motivo con que inscribir_colportor() la rechazaría AHORA, sacado de la
-- única definición de las reglas (motivo_rechazo_inscripcion()): null si se puede añadir,
-- USUARIO_SUSPENDIDO, EN_OTRA_CAMPANIA o INSCRIPCION_BORRADA. Así el panel no reescribe las
-- reglas para decidir si apaga «Añadir». Se calcula solo para las filas que se devuelven.
--
-- ## Para otros repos
--
--   · bff-coordinadores: endpoint nuevo para la búsqueda (p. ej. GET
--     /v1/campanias/:campaniaId/candidatos?q=), que llama a buscar_candidatos() con el JWT del
--     coordinador; CI001 → 404 y CI002 → 409, como la inscripción. colportores_de_campania()
--     suma `email` y `estado` al final (las columnas de antes siguen iguales). GET /v1/me sigue
--     andando: lee la fila propia. Cualquier otra lectura directa de `usuario` con el JWT de un
--     coordinador ahora devuelve solo su fila.
--   · front-coordinadores-web (vista 23): la búsqueda y los sugeridos salen de este RPC al
--     conectar la vista; el orden de los sugeridos es el del servidor (más nuevos primero).
--
-- ## Pendientes (no se deciden acá; comentario en backend-supabase#41)
--
--   · El orden de los resultados con texto y el tope de 10: la HU solo fija los sugeridos.
--   · Cuentas de staff: un COORDINADOR o ADMIN sin inscripción es PENDIENTE_ASIGNACION y aparece
--     como candidato, igual que inscribir_colportor() lo acepta (0005: no se exige rol COLPORTOR).
--   · INSCRIPCION_BORRADA: aparece con ese motivo; el texto para el panel no está en el diseño.
--   · usuario_rol sigue legible por cualquier coordinador (usuario_rol_select, 0003): ids y
--     roles, sin nombre ni email. La decisión habló solo de `usuario`.
--
-- Forward-only: esta migración no se edita una vez aplicada.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. Estado de la cuenta: una sola definición
-- ----------------------------------------------------------------------------

-- Pura: no lee ninguna tabla, así que se puede otorgar a authenticated sin exponer nada
-- (estado_cuenta() es INVOKER y la llama con los privilegios del usuario).
create function public.estado_de_cuenta(p_suspendido_en timestamptz, p_con_campania_vigente boolean)
returns text
language sql
immutable
set search_path = ''
as $$
  select case
           when p_suspendido_en is not null then 'SUSPENDIDA'
           when coalesce(p_con_campania_vigente, false) then 'ACTIVA'
           else 'PENDIENTE_ASIGNACION'
         end;
$$;

comment on function public.estado_de_cuenta(timestamptz, boolean) is
  'HU-AUTH-008: SUSPENDIDA si p_suspendido_en no es null; si no, ACTIVA si tiene una inscripción '
  'vigente; si no, PENDIENTE_ASIGNACION. Única definición de la precedencia: la usan '
  'estado_cuenta(), colportores_de_campania() y buscar_candidatos() (0015).';

-- Misma firma, mismo resultado, mismos errores y sigue INVOKER (lee la fila propia con la RLS
-- del llamador): solo la precedencia pasa a estado_de_cuenta(). Lo verifica 0006.
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

  return public.estado_de_cuenta(v_suspendido_en,
                                 exists (select 1 from public.mis_campanias_vigentes()));
end;
$$;

-- ----------------------------------------------------------------------------
-- 2. RLS: el coordinador lee solo su fila de usuario
-- ----------------------------------------------------------------------------

drop policy usuario_select_propio_o_staff on public.usuario;

create policy usuario_select_propio_o_admin on public.usuario
  for select to authenticated
  using (id = (select auth.uid()) or (select public.tiene_rol('ADMIN')));

comment on policy usuario_select_propio_o_admin on public.usuario is
  'Cada usuario lee su fila; el ADMIN, todas. El coordinador ve cuentas ajenas solo por '
  'colportores_de_campania() y buscar_candidatos() (decisión de Cristian del 30/09, '
  'front-coordinadores-web#20 punto 5; 0015).';

-- ----------------------------------------------------------------------------
-- 3. colportores_de_campania(): suma email y estado
-- ----------------------------------------------------------------------------

-- Cambia el tipo de retorno, así que se recrea (create or replace no puede). Las columnas de
-- 0007 quedan iguales y en el mismo orden; email y estado van al final, para que un
-- consumidor que lee por nombre no note el cambio. Mismo permiso, errores y orden. Pasa de
-- stable a volatile, como toda lectura que lanza motivos (lanzar_motivo_zona() es volátil): el
-- BFF la llama por POST, así que no cambia nada para él.
drop function public.colportores_de_campania(uuid);

create function public.colportores_de_campania(p_campania_id uuid)
returns table (usuario_id uuid, nombre text, apellido text, zona_id uuid, zona_nombre text,
                suspendido boolean, email text, estado text)
language plpgsql
volatile
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
    select u.id, u.nombre, u.apellido, z.id, z.nombre, (u.suspendido_en is not null), u.email,
           public.estado_de_cuenta(u.suspendido_en,
                                   exists (select 1 from public.campanias_vigentes_de(u.id)))
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
  'cuenta (0015). Errores: 42501 sin permiso; CZ001 inexistente; CZ002 no vigente.';

-- ----------------------------------------------------------------------------
-- 4. buscar_candidatos()
-- ----------------------------------------------------------------------------

-- Minúsculas, sin tildes y con los espacios colapsados; null si queda vacío. translate() antes
-- de lower() para no depender del locale de la base con las mayúsculas acentuadas. Interna.
create function public.normalizar_busqueda(p_texto text)
returns text
language sql
immutable
set search_path = ''
as $$
  select nullif(btrim(regexp_replace(
           lower(translate(coalesce(p_texto, ''),
                           'ÁÀÄÂÃÉÈËÊÍÌÏÎÓÒÖÔÕÚÙÜÛÑÇáàäâãéèëêíìïîóòöôõúùüûñç',
                           'AAAAAEEEEIIIIOOOOOUUUUNCaaaaaeeeeiiiiooooouuuunc')),
           '\s+', ' ', 'g')), '');
$$;

comment on function public.normalizar_busqueda(text) is
  'Texto para comparar en buscar_candidatos(): minúsculas, sin tildes, espacios colapsados; '
  'null si queda vacío. Interna (0015).';

create function public.buscar_candidatos(p_campania_id uuid, p_texto text default null)
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
      raise exception 'La campaña no está activa: solo se inscribe en una campaña vigente.'
        using errcode = 'CI002';
    else
      null;
  end case;

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
    elegida as (
      -- Sugeridos: sin texto, las 5 pendientes de asignación más nuevas.
      (select c.*, row_number() over (order by c.created_at desc, c.id desc) as orden
         from candidata c
        where v_texto is null
          and public.estado_de_cuenta(c.suspendido_en,
                exists (select 1 from public.campanias_vigentes_de(c.id))) = 'PENDIENTE_ASIGNACION'
        order by c.created_at desc, c.id desc
        limit 5)
      union all
      -- Búsqueda: hasta 10 que contienen el texto, primero las que empiezan con él.
      (select c.*, row_number() over (
                -- coalesce: sin nombre ni apellido, el «empieza» sería null, y null va primero en desc.
                order by coalesce(strpos(c.n_completo, v_texto) = 1 or strpos(c.n_apellido, v_texto) = 1
                                  or strpos(c.n_email, v_texto) = 1, false) desc,
                         c.n_completo collate "C", c.id) as orden
         from candidata c
        where v_texto is not null
          and (strpos(c.n_completo, v_texto) > 0 or strpos(c.n_email, v_texto) > 0)
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

comment on function public.buscar_candidatos(uuid, text) is
  'HU-CAM-004, vista 23: cuentas para añadir a p_campania_id. Sin texto, los sugeridos (hasta 5 '
  'PENDIENTE_ASIGNACION, más nuevas primero); con texto, hasta 10 cuyo nombre completo o email '
  'lo contiene (sin mayúsculas ni tildes), primero las que empiezan con él. Devuelve estado, '
  'campaña vigente y motivo_bloqueo (el de inscribir_colportor(), null si se puede). Errores: '
  '42501 sin permiso; CI001 campaña inexistente; CI002 no vigente (0015).';

-- ----------------------------------------------------------------------------
-- 5. Privilegios
-- ----------------------------------------------------------------------------

-- En una base nueva la imagen da EXECUTE a authenticated sobre toda función nueva: se revoca
-- todo y se otorga explícito.
revoke all on function public.estado_de_cuenta(timestamptz, boolean),
  public.colportores_de_campania(uuid), public.normalizar_busqueda(text),
  public.buscar_candidatos(uuid, text)
  from public, anon, authenticated;

-- estado_de_cuenta: pura; la necesita estado_cuenta(), que corre con los privilegios del usuario.
grant execute on function public.estado_de_cuenta(timestamptz, boolean) to authenticated, service_role;
grant execute on function public.colportores_de_campania(uuid), public.buscar_candidatos(uuid, text)
  to authenticated, service_role;
-- normalizar_busqueda: interna, la llama buscar_candidatos() como su dueño.
grant execute on function public.normalizar_busqueda(text) to service_role;
