-- ============================================================================
-- 0196 · Paginación opcional en las RPC de listas del panel que pueden pasar de 1000 filas
--        (backend-supabase#290, seguimiento de front-coordinadores-web#192 / PR 193, P3)
--
-- ## El caso
--
-- Marta, coordinadora, abre «Reportes» o el registro de acompañamientos de su campaña. Con 100 colportores y 60 días de
-- campaña, `historial_de_acompaniamientos` pasa de 6000 filas. PostgREST corta toda respuesta en `max_rows = 1000`
-- (supabase/config.toml) sin avisar: la lista se ve completa y le faltan filas. Con la paginación, el panel pide de a
-- páginas hasta que una venga con menos filas que el límite y la lista está entera.
--
-- ## Qué cambia
--
-- Las siete RPC de lista del panel que pueden pasar de 1000 filas suman, AL FINAL de sus parámetros y con valor por
-- defecto, dos opcionales (la misma forma que `retiros_de_campania`, 0184, y `tickets_de_campania`, 0131):
--
--   p_limite          integer default null   filas por página, de 1 a 1000 (1000 = el `max_rows` de PostgREST: un límite
--                                            mayor se cortaría en silencio, justo lo que esto evita, así que es 22023);
--                                            null = todas, como hasta hoy.
--   p_desplazamiento  integer default 0      cuántas filas saltear, desde 0.
--
--   colportores_de_campania(p_campania_id, p_limite, p_desplazamiento)
--   ciudades_de_campania(p_campania_id, p_limite, p_desplazamiento)
--   zonas_por_colportor(p_campania_id, p_limite, p_desplazamiento)
--   acompaniamientos_por_colportor(p_campania_id, p_limite, p_desplazamiento)
--   historial_de_acompaniamientos(p_campania_id, p_colportor_id, p_limite, p_desplazamiento)
--   jornadas_cerradas_de_colportor(p_campania_id, p_colportor_id, p_limite, p_desplazamiento)
--   becas_de_campania(p_campania_id, p_limite, p_desplazamiento)
--
-- `tablero_de_inicio` devuelve un jsonb (una sola fila) y no se corta: queda como está.
--
-- Regla R1 (solo suma): llamada sin los dos parámetros nuevos, cada función devuelve las mismas filas, en el mismo
-- orden y con las mismas columnas que antes (con `max_rows`, igual que hoy). Las columnas de salida, el permiso y los
-- errores no cambian; se suma el 22023 por un límite o un desplazamiento fuera de rango.
--
-- ## Orden estable y único
--
-- Un desplazamiento solo sirve si el orden no empata. Cada función ya terminaba su `order by` en una clave única
-- (el id de la fila, o `a.id` en el historial y en las jornadas); se verificó una por una y no se cambió ningún orden:
-- colportores / zonas / acompañamientos: `usuario_id` (una inscripción viva por colportor y campaña); ciudades:
-- `campania_ciudad.id`; becas: `usuario.id`; historial: día, jornada y `jornada_acompaniante.id`; jornadas cerradas:
-- día, inicio, jornada y `jornada_acompaniante.id`. Pedir páginas seguidas no repite ni saltea filas mientras los datos
-- no cambien entre una y otra.
--
-- ## Cómo
--
-- Cada función se recrea con `drop` + `create` (agregar parámetros cambia la firma: dejar la vieja al lado haría
-- ambigua la llamada por nombre de PostgREST). El cuerpo es el de su última migración (0102, 0066, 0062, 0100, 0177,
-- 0177, 0149) con dos agregados: la validación `public.validar_pagina_de_lista(p_limite, p_desplazamiento)` después del
-- permiso y `limit p_limite offset p_desplazamiento` al final del `order by`. Los privilegios son los de siempre
-- (`authenticated`; `colportores_de_campania` también `service_role`, como desde la 0015).
--
-- ## Los datos
--
-- No toca filas. Lo prueba supabase/tests/0196_paginacion_opcional_en_las_listas_del_panel_test.sql. Forward-only.
-- ============================================================================

-- Valida la página pedida. Interna: la llaman las siete funciones (SECURITY DEFINER, como su dueño), así que no hace
-- falta que ningún rol pueda ejecutarla.
create function public.validar_pagina_de_lista(p_limite integer, p_desplazamiento integer)
returns void
language plpgsql
stable
set search_path = ''
as $$
begin
  if p_limite is not null and (p_limite < 1 or p_limite > 1000) then
    raise exception 'El límite de la página es de 1 a 1000 filas (o sin límite).'
      using errcode = '22023',
            hint = 'Pedí de a 1000 filas como máximo y seguí con p_desplazamiento hasta que una página venga con menos filas que p_limite.';
  end if;
  if p_desplazamiento is null or p_desplazamiento < 0 then
    raise exception 'El desplazamiento no puede ser negativo.'
      using errcode = '22023';
  end if;
end;
$$;

comment on function public.validar_pagina_de_lista(integer, integer) is
  'Interna (0196, #290): valida p_limite (null o de 1 a 1000, el max_rows de PostgREST) y p_desplazamiento (0 o más); '
  '22023 si no. La llaman las RPC de lista del panel que se pueden pedir por páginas.';

revoke all on function public.validar_pagina_de_lista(integer, integer)
  from public, anon, authenticated, service_role;

-- ----------------------------------------------------------------------------
-- 1. colportores_de_campania
-- ----------------------------------------------------------------------------

drop function public.colportores_de_campania(uuid);

create function public.colportores_de_campania(p_campania_id uuid, p_limite integer default null, p_desplazamiento integer default 0)
returns table (usuario_id uuid, nombre text, apellido text, zona_id uuid, zona_nombre text,
                suspendido boolean, email text, estado text)
language plpgsql
volatile
security definer
set search_path = ''
as $$
begin
  perform public.exigir_lectura_de_campania(p_campania_id);

  perform public.validar_pagina_de_lista(p_limite, p_desplazamiento);

  return query
    select u.id, u.nombre, u.apellido, z.id, z.nombre, (u.suspendido_en is not null), u.email,
           public.estado_de_cuenta(u.suspendido_en,
                                   exists (select 1 from public.inscripciones_no_terminadas_de(u.id)))
      from public.campania_colportor cc
      join public.usuario u on u.id = cc.usuario_id
      left join public.zona z on z.id = cc.zona_id and z.deleted_at is null
     where cc.campania_id = p_campania_id
       and cc.deleted_at is null and u.deleted_at is null
     order by u.apellido, u.nombre, u.id
     limit p_limite offset p_desplazamiento;
end;
$$;

comment on function public.colportores_de_campania(uuid, integer, integer) is
  'HU-CAM-004/006: inscriptos vivos de p_campania_id con su zona actual, email y estado de la '
  'cuenta (0015; desde 0102, ACTIVA con una inscripción en una campaña que no terminó). Se lee con el '
  'criterio del mapa (0033): una campaña por empezar contesta con quienes se sumaron antes del inicio. '
  'Errores: 42501 sin permiso; CZ001 inexistente; CZ011 terminada.'
  ' Paginación opcional (0196, #290): p_limite (de 1 a 1000; null = todas, como antes) y p_desplazamiento (desde 0, por defecto); el orden es fijo y único, así que páginas seguidas no repiten ni saltean filas. Sin parámetros devuelve lo mismo que antes, pero PostgREST corta en 1000 filas (max_rows): una lista que pueda pasar de ahí se pide por páginas, hasta que una venga con menos filas que p_limite. Un p_limite o un p_desplazamiento fuera de rango es 22023.';

revoke all on function public.colportores_de_campania(uuid, integer, integer)
  from public, anon, authenticated, service_role;
grant execute on function public.colportores_de_campania(uuid, integer, integer) to authenticated, service_role;

-- ----------------------------------------------------------------------------
-- 2. ciudades_de_campania
-- ----------------------------------------------------------------------------

drop function public.ciudades_de_campania(uuid);

create function public.ciudades_de_campania(p_campania_id uuid, p_limite integer default null, p_desplazamiento integer default 0)
returns table (campania_ciudad_id uuid, ciudad_id uuid, nombre text, departamento text,
               lat_centro double precision, lon_centro double precision, zoom_inicial smallint,
               cantidad_zonas integer)
language plpgsql
volatile
security definer
set search_path = ''
as $$
begin
  perform public.exigir_lectura_de_campania(p_campania_id);

  perform public.validar_pagina_de_lista(p_limite, p_desplazamiento);

  return query
    select cc.id, c.id, c.nombre, c.departamento, c.lat_centro, c.lon_centro, c.zoom_inicial,
           (select count(*)::integer
              from public.zona z
             where z.campania_ciudad_id = cc.id and z.deleted_at is null)
      from public.campania_ciudad cc
      join public.ciudad c on c.id = cc.ciudad_id
     where cc.campania_id = p_campania_id
       and cc.deleted_at is null
     order by c.nombre, cc.id
     limit p_limite offset p_desplazamiento;
end;
$$;

comment on function public.ciudades_de_campania(uuid, integer, integer) is
  'Vista 24 (0033, con departamento desde 0066): las ciudades vivas de p_campania_id con su departamento '
  '(null = sin cargar), centro, zoom y cantidad de zonas vivas. campania_ciudad_id es el id de la pestaña; '
  'ciudad_id, el del catálogo. Errores: 42501 sin permiso; CZ001 inexistente; CZ011 terminada.'
  ' Paginación opcional (0196, #290): p_limite (de 1 a 1000; null = todas, como antes) y p_desplazamiento (desde 0, por defecto); el orden es fijo y único, así que páginas seguidas no repiten ni saltean filas. Sin parámetros devuelve lo mismo que antes, pero PostgREST corta en 1000 filas (max_rows): una lista que pueda pasar de ahí se pide por páginas, hasta que una venga con menos filas que p_limite. Un p_limite o un p_desplazamiento fuera de rango es 22023.';

revoke all on function public.ciudades_de_campania(uuid, integer, integer)
  from public, anon, authenticated, service_role;
grant execute on function public.ciudades_de_campania(uuid, integer, integer) to authenticated;

-- ----------------------------------------------------------------------------
-- 3. zonas_por_colportor
-- ----------------------------------------------------------------------------

drop function public.zonas_por_colportor(uuid);

create function public.zonas_por_colportor(p_campania_id uuid, p_limite integer default null, p_desplazamiento integer default 0)
returns table (colportor_id uuid, nombre text, apellido text, ciudad_id uuid, ciudad_nombre text,
               zona_id uuid, zona_nombre text, zona_desde date, zona_desde_inicial boolean,
               zonas_anteriores jsonb, casas_registradas integer)
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_motivo text;
begin
  -- El permiso, antes de mirar nada más. Una campaña terminada se lee; una por empezar, también.
  v_motivo := public.motivo_mapa_de_campania(p_campania_id);
  if v_motivo = 'SIN_PERMISO' then
    raise exception 'Solo el coordinador de la campaña o un administrador puede ver las zonas de su equipo. Entrá con la cuenta del coordinador de esta campaña.'
      using errcode = 'insufficient_privilege';
  end if;
  if v_motivo is distinct from 'CAMPANIA_TERMINADA' then
    perform public.lanzar_motivo_mapa(v_motivo);
  end if;

  perform public.validar_pagina_de_lista(p_limite, p_desplazamiento);

  return query
    select i.usuario_id,
           usr.nombre,
           usr.apellido,
           ci.ciudad_id,
           ciu.nombre,
           z.id,
           z.nombre,
           public.hoy_montevideo(actual.desde),
           actual.inicial,
           coalesce((select jsonb_agg(jsonb_build_object(
                               'zona_id', zz.id,
                               'nombre', zz.nombre,
                               'ciudad_id', cia.ciudad_id,
                               'ciudad_nombre', ciua.nombre,
                               'desde', public.hoy_montevideo(h.desde),
                               'hasta', public.hoy_montevideo(h.hasta),
                               'inicial', h.inicial,
                               'eliminada', zz.deleted_at is not null)
                             order by h.desde, h.id)
                       from public.campania_colportor_zona_historial h
                       join public.zona zz on zz.id = h.zona_id
                       left join public.campania_ciudad cia on cia.id = zz.campania_ciudad_id
                       left join public.ciudad ciua on ciua.id = cia.ciudad_id
                      where h.campania_colportor_id = i.id
                        and h.hasta is not null
                        and h.deleted_at is null),
                    '[]'::jsonb),
           (select count(*)::integer
              from public.ubicacion ub
             where ub.created_by = i.usuario_id
               and ub.deleted_at is null
               and ub.created_at >= i.created_at
               and public.hoy_montevideo(ub.created_at) <= coalesce(camp.fecha_fin, 'infinity'::date)
               and exists (select 1
                             from public.campania_ciudad cx
                            where cx.campania_id = p_campania_id
                              and cx.ciudad_id = ub.ciudad_id
                              and cx.deleted_at is null))
      from public.campania_colportor i
      join public.campania camp on camp.id = i.campania_id
      join public.usuario usr on usr.id = i.usuario_id
      -- La zona de hoy, y su ciudad (decisión del 21/10, «Ciudad colp.»); sin zona, todo null.
      left join public.zona z on z.id = i.zona_id and z.deleted_at is null
      left join public.campania_ciudad ci on ci.id = z.campania_ciudad_id and ci.deleted_at is null
      left join public.ciudad ciu on ciu.id = ci.ciudad_id
      -- El tramo abierto de esa zona (a lo sumo uno por inscripción: índice único parcial de 0022).
      left join lateral (select h.desde, h.inicial
                           from public.campania_colportor_zona_historial h
                          where h.campania_colportor_id = i.id
                            and h.zona_id = z.id
                            and h.hasta is null
                            and h.deleted_at is null
                          limit 1) actual on true
     where i.campania_id = p_campania_id
       and i.deleted_at is null
       and usr.deleted_at is null
     order by usr.apellido, usr.nombre, i.usuario_id
     limit p_limite offset p_desplazamiento;
end;
$$;

comment on function public.zonas_por_colportor(uuid, integer, integer) is
  'Vista 33 «Equipo», HU-CAM-006 (0047 y 0062, backend-supabase#98): por inscripto vivo de la campaña, su '
  'zona de hoy (con la ciudad y desde qué día; zona_desde_inicial = el día es una cota, no la '
  'asignación real) y sus zonas_anteriores con las fechas (jsonb [{zona_id, nombre, ciudad_id, '
  'ciudad_nombre, desde, hasta, inicial, eliminada}], del más viejo al más nuevo; día de Montevideo). '
  'Sale del historial de la 0022. casas_registradas: ubicaciones vivas que creó el colportor en las '
  'ciudades vivas de la campaña desde que se inscribió y hasta el último día de la campaña, sin mirar '
  'la zona (las de una zona anterior siguen contando). Una campaña por empezar o terminada se lee. Errores: 42501 sin permiso; CZ001 '
  'campaña inexistente. Sin email ni clientes.'
  ' Paginación opcional (0196, #290): p_limite (de 1 a 1000; null = todas, como antes) y p_desplazamiento (desde 0, por defecto); el orden es fijo y único, así que páginas seguidas no repiten ni saltean filas. Sin parámetros devuelve lo mismo que antes, pero PostgREST corta en 1000 filas (max_rows): una lista que pueda pasar de ahí se pide por páginas, hasta que una venga con menos filas que p_limite. Un p_limite o un p_desplazamiento fuera de rango es 22023.';

revoke all on function public.zonas_por_colportor(uuid, integer, integer)
  from public, anon, authenticated, service_role;
grant execute on function public.zonas_por_colportor(uuid, integer, integer) to authenticated;

-- ----------------------------------------------------------------------------
-- 4. acompaniamientos_por_colportor
-- ----------------------------------------------------------------------------

drop function public.acompaniamientos_por_colportor(uuid);

create function public.acompaniamientos_por_colportor(p_campania_id uuid, p_limite integer default null, p_desplazamiento integer default 0)
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

  perform public.validar_pagina_de_lista(p_limite, p_desplazamiento);

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
           greatest(v_hoy - coalesce(a.ultimo, d.desde), 0),
           coalesce(a.ultimo, d.desde)
      from public.campania_colportor i
      join public.usuario usr on usr.id = i.usuario_id
      -- Quien nunca fue acompañado se cuenta desde lo más tarde entre el inicio de la campaña y el día en
      -- que se sumó (o en que volvió, si estuvo afuera): una inscripción que vuelve arranca de nuevo.
      cross join lateral (
        select greatest(
                 v_campania.fecha_inicio,
                 public.hoy_montevideo(
                   coalesce((select max(upper(t)) from unnest(i.tramos_afuera) t), i.created_at))) as desde
      ) d
      -- La ciudad es la de la zona actual (decisión del 21/10, «Ciudad colp.»); sin zona, null.
      left join public.zona z on z.id = i.zona_id and z.deleted_at is null
      left join public.campania_ciudad ci on ci.id = z.campania_ciudad_id and ci.deleted_at is null
      left join public.ciudad ciu on ciu.id = ci.ciudad_id
      left join acompaniadas a on a.colp = i.usuario_id
     where i.campania_id = p_campania_id
       and i.deleted_at is null
     order by 8 desc, usr.apellido, usr.nombre, i.usuario_id
     limit p_limite offset p_desplazamiento;
end;
$$;

comment on function public.acompaniamientos_por_colportor(uuid, integer, integer) is
  'Vista 33, HU-JOR-004 (0043, backend-supabase#97; 0100, #140): por colportor inscripto (vivo) de la '
  'campaña, cuántas jornadas acompañadas tiene, el día del último y los días corridos sin acompañar '
  '(desde el último o, si nunca, desde contado_desde: lo más tarde entre el inicio de la campaña y el día '
  'en que se sumó o volvió; sin umbral). Las jornadas del tiempo que estuvo afuera no cuentan. Orden: más '
  'días sin acompañar primero. Una campaña terminada se lee. Errores: 42501 sin permiso; CZ001 campaña '
  'inexistente. Solo totales: ni clientes ni ventas.'
  ' Paginación opcional (0196, #290): p_limite (de 1 a 1000; null = todas, como antes) y p_desplazamiento (desde 0, por defecto); el orden es fijo y único, así que páginas seguidas no repiten ni saltean filas. Sin parámetros devuelve lo mismo que antes, pero PostgREST corta en 1000 filas (max_rows): una lista que pueda pasar de ahí se pide por páginas, hasta que una venga con menos filas que p_limite. Un p_limite o un p_desplazamiento fuera de rango es 22023.';

revoke all on function public.acompaniamientos_por_colportor(uuid, integer, integer)
  from public, anon, authenticated, service_role;
grant execute on function public.acompaniamientos_por_colportor(uuid, integer, integer) to authenticated;

-- ----------------------------------------------------------------------------
-- 5. historial_de_acompaniamientos
-- ----------------------------------------------------------------------------

drop function public.historial_de_acompaniamientos(uuid, uuid);

create function public.historial_de_acompaniamientos(p_campania_id uuid, p_colportor_id uuid DEFAULT NULL::uuid, p_limite integer default null, p_desplazamiento integer default 0)
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
  perform public.validar_pagina_de_lista(p_limite, p_desplazamiento);

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
     order by h.dia desc, h.jornada_id desc, a.created_at, a.id
     limit p_limite offset p_desplazamiento;
end;
$$;

comment on function public.historial_de_acompaniamientos(uuid, uuid, integer, integer) is
  'Historial de acompañamientos de la campaña (0043, 0100, 0116, 0133; 0177, #254): una fila por acompañante de cada '
  'jornada acompañada, con día, horas, quién acompañó, el origen y la nota (internos de coordinación) y quién lo cargó '
  'desde el panel. Una jornada con dos acompañantes sale dos veces: quien cuente jornadas cuenta jornada_id distintos. '
  'Permiso: coordinador de la campaña o ADMIN; las campañas terminadas se leen.'
  ' Paginación opcional (0196, #290): p_limite (de 1 a 1000; null = todas, como antes) y p_desplazamiento (desde 0, por defecto); el orden es fijo y único, así que páginas seguidas no repiten ni saltean filas. Sin parámetros devuelve lo mismo que antes, pero PostgREST corta en 1000 filas (max_rows): una lista que pueda pasar de ahí se pide por páginas, hasta que una venga con menos filas que p_limite. Un p_limite o un p_desplazamiento fuera de rango es 22023.';

revoke all on function public.historial_de_acompaniamientos(uuid, uuid, integer, integer)
  from public, anon, authenticated, service_role;
grant execute on function public.historial_de_acompaniamientos(uuid, uuid, integer, integer) to authenticated;

-- ----------------------------------------------------------------------------
-- 6. jornadas_cerradas_de_colportor
-- ----------------------------------------------------------------------------

drop function public.jornadas_cerradas_de_colportor(uuid, uuid);

create function public.jornadas_cerradas_de_colportor(p_campania_id uuid, p_colportor_id uuid, p_limite integer default null, p_desplazamiento integer default 0)
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
  perform public.validar_pagina_de_lista(p_limite, p_desplazamiento);

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
     order by public.hoy_montevideo(j.inicio) desc, j.inicio desc, j.id desc, a.created_at, a.id
     limit p_limite offset p_desplazamiento;
end;
$$;

comment on function public.jornadas_cerradas_de_colportor(uuid, uuid, integer, integer) is
  'Jornadas cerradas de un colportor de la campaña (0043, 0100, 0116, 0133; 0177, #254), con o sin acompañante: una fila '
  'por acompañante (una jornada sin acompañante sale una vez, con el acompañante en null). Permiso: coordinador de la '
  'campaña o ADMIN; las campañas terminadas se leen.'
  ' Paginación opcional (0196, #290): p_limite (de 1 a 1000; null = todas, como antes) y p_desplazamiento (desde 0, por defecto); el orden es fijo y único, así que páginas seguidas no repiten ni saltean filas. Sin parámetros devuelve lo mismo que antes, pero PostgREST corta en 1000 filas (max_rows): una lista que pueda pasar de ahí se pide por páginas, hasta que una venga con menos filas que p_limite. Un p_limite o un p_desplazamiento fuera de rango es 22023.';

revoke all on function public.jornadas_cerradas_de_colportor(uuid, uuid, integer, integer)
  from public, anon, authenticated, service_role;
grant execute on function public.jornadas_cerradas_de_colportor(uuid, uuid, integer, integer) to authenticated;

-- ----------------------------------------------------------------------------
-- 7. becas_de_campania
-- ----------------------------------------------------------------------------

drop function public.becas_de_campania(uuid);

create function public.becas_de_campania(p_campania_id uuid, p_limite integer default null, p_desplazamiento integer default 0)
returns table (usuario_id uuid, nombre text, apellido text, carrera_id uuid, carrera_nombre text,
               carrera_elegida_en timestamptz, tipo_beca text, meta_libros integer, meta_monto_ces bigint,
               meta_configurada boolean, meta_recalculada_en timestamptz,
               libros_bonificables integer, compra_ces bigint, estado_beca text, beca_alcanzada_tipo text)
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_tipo_campania text;
begin
  perform public.exigir_coordinador_de_campania_para_beca(p_campania_id);

  select c.tipo into v_tipo_campania from public.campania c where c.id = p_campania_id;

  perform public.validar_pagina_de_lista(p_limite, p_desplazamiento);

  return query
    select u.id, u.nombre, u.apellido, ca.id, ca.nombre, u.carrera_elegida_en,
           cc.tipo_beca, cc.meta_libros, cc.meta_monto_ces,
           exists (select 1 from public.meta_beca mb
                    where mb.carrera_id = u.carrera_id and mb.tipo_campania = v_tipo_campania
                      and mb.deleted_at is null),
           -- La última vez que una corrección de carrera dejó a esta inscripción con la meta que tiene ahora.
           (select max(a.created_at)
              from auditoria.audit_log a
             where a.event_type = 'meta_de_beca_recalculada'
               and a.target_user_id = u.id and a.fila_id = cc.id
               and a.metadata ->> 'tipo_beca' = cc.tipo_beca
               and (a.metadata ->> 'meta_libros')::integer is not distinct from cc.meta_libros
               and (a.metadata ->> 'meta_monto_ces')::bigint is not distinct from cc.meta_monto_ces),
           av.libros, av.compra,
           -- Se alcanza con la compra a la CES; los libros son la otra forma de ver el avance (S67).
           case when av.alcanzada_ahora or av.tipo_previo is not null then 'ALCANZADA'
                when cc.tipo_beca is not null then 'EN_PROGRESO'
           end,
           -- Lo alcanzado no se pierde («Logro beca»): el mayor entre lo que alcanzó ahora y lo que ya había alcanzado
           -- (COMPLETA > MEDIA), aunque después le hayan bajado la beca.
           case when av.alcanzada_ahora and av.tipo_previo is not null
                  then case when 'COMPLETA' in (cc.tipo_beca, av.tipo_previo) then 'COMPLETA' else 'MEDIA' end
                when av.alcanzada_ahora then cc.tipo_beca
                else av.tipo_previo
           end
      from public.campania_colportor cc
      join public.usuario u on u.id = cc.usuario_id
      left join public.carrera ca on ca.id = u.carrera_id
     cross join lateral (
             select public.libros_bonificables_de_la_campania(u.id, cc.campania_id) as libros,
                    public.compra_a_la_ces(u.id, cc.campania_id) as compra) c1
     cross join lateral (
             select c1.libros, c1.compra,
                    (cc.tipo_beca is not null and cc.meta_monto_ces is not null
                     and c1.compra >= cc.meta_monto_ces) as alcanzada_ahora,
                    -- «Logro beca»: lo mejor que alcanzó antes de que le cambiaran el tipo o la meta (COMPLETA > MEDIA).
                    (select a.metadata ->> 'tipo_beca'
                       from auditoria.audit_log a
                      where a.event_type = 'beca_alcanzada' and a.fila_id = cc.id
                      order by (a.metadata ->> 'tipo_beca' = 'COMPLETA') desc, a.created_at desc, a.id desc
                      limit 1) as tipo_previo) av
     where cc.campania_id = p_campania_id
       and cc.deleted_at is null and u.deleted_at is null
     order by u.apellido, u.nombre, u.id
     limit p_limite offset p_desplazamiento;
end;
$$;

comment on function public.becas_de_campania(uuid, integer, integer) is
  'Vista 33, HU-BEC-002/004/006 (0117, 0132, 0149; backend-supabase#112, #202 y #221): los inscriptos vivos de '
  'p_campania_id con su carrera y cuándo se eligió (carrera_elegida_en), el tipo de beca asignado, las dos metas '
  'copiadas (libros y monto en centavos), si la carrera tiene meta cargada para el tipo de la campaña '
  '(meta_configurada), meta_recalculada_en (el aviso «Carrera corregida: meta de <carrera>») y, desde 0149, el '
  'avance: libros_bonificables (vendidos menos devueltos), compra_ces (lo comprado a la casa editora en '
  'bonificables, centavos), estado_beca (null | EN_PROGRESO | ALCANZADA: se alcanza con la compra a la CES) y '
  'beca_alcanzada_tipo (MEDIA | COMPLETA, aunque después le cambien el tipo: lo alcanzado no se pierde). Errores: '
  '42501 sin permiso; CZ001 inexistente; BC001 terminada.'
  ' Paginación opcional (0196, #290): p_limite (de 1 a 1000; null = todas, como antes) y p_desplazamiento (desde 0, por defecto); el orden es fijo y único, así que páginas seguidas no repiten ni saltean filas. Sin parámetros devuelve lo mismo que antes, pero PostgREST corta en 1000 filas (max_rows): una lista que pueda pasar de ahí se pide por páginas, hasta que una venga con menos filas que p_limite. Un p_limite o un p_desplazamiento fuera de rango es 22023.';

revoke all on function public.becas_de_campania(uuid, integer, integer)
  from public, anon, authenticated, service_role;
grant execute on function public.becas_de_campania(uuid, integer, integer) to authenticated;
