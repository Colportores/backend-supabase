-- ============================================================================
-- 0055 · Tablero de Inicio: inscripciones vigentes ese día y estado «sin cerrar»
--        (backend-supabase#94, decisiones del 22/10 sobre los pendientes P2 y P3 de la 0054)
--
-- Cambia tablero_de_inicio(uuid, date) con `create or replace` (misma firma y mismo tipo de
-- retorno: conserva sus privilegios; el comentario se vuelve a poner). La 0054 ya está en develop
-- y no se edita.
--
--   · P2, coherencia con los reportes (0044/0045). Al mirar un día, los colportores son los de las
--     inscripciones VIGENTES ese día: creadas antes de que termine el día y sin baja, o con la baja
--     posterior al comienzo del día. Quien todavía no estaba inscripto ese día no figura. Quien se
--     dio de baja después va donde lo pone 0044: sin ciudad (la baja lo deja sin zona), en
--     `sin_zona` y fuera de las cifras; solo cuentan sus jornadas anteriores a la baja (de ahí sale
--     su estado). `sin_zona[]` suma `inscripcion_de_baja` (boolean) para que el panel no le ofrezca
--     «Asignar zona» a quien ya no está en la campaña, e `inscripto_at` (timestamptz, el
--     `created_at` de la inscripción: decisión del 22/10) para «se sumó hoy a las 11:02» de la
--     tarjeta «Colportora sin zona asignada» del canvas 31.
--   · P3, decir la verdad. Un día ANTERIOR a hoy en que el colportor empezó una jornada que quedó
--     abierta: estado 'SIN_CERRAR' (antes 'FINALIZADA' con 0 h). Las horas siguen sumando solo las
--     cerradas (nada inventa un `fin`, HU-JOR-002) y el día siguiente sigue 'SIN_INICIAR'. El panel
--     lo muestra «Sin cerrar» con el estilo de los otros estados: único apartamiento del canvas 31.
--
-- Para otros repos: front-coordinadores-web (vista 31) agrega el estado SIN_CERRAR y lee
-- `sin_zona[].inscripcion_de_baja`.
--
-- Forward-only: no se edita una vez aplicada.
-- ============================================================================

create or replace function public.tablero_de_inicio(p_campania_id uuid, p_fecha date default null)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  -- Resultados de una visita que cuentan como presentación (HU-VIS-005, S62: RECHAZO, a confirmar).
  c_presentacion constant text[] := array['VENTA', 'ENTREVISTA'];
  v_motivo       text;
  v_campania     public.campania;
  v_hoy          date := public.hoy_montevideo();
  v_ahora        timestamptz := now();
  v_dia          date;
  v_desde        timestamptz;
  v_hasta        timestamptz;
  v_en_campania  boolean;
  v_res          jsonb;
begin
  -- El permiso, antes de mirar nada más. Una campaña terminada se lee; lo demás es lo de
  -- siempre de la vista 24.
  v_motivo := public.motivo_mapa_de_campania(p_campania_id);
  if v_motivo = 'SIN_PERMISO' then
    raise exception 'Solo el coordinador de la campaña o un administrador puede ver su tablero. Entrá con la cuenta del coordinador de esta campaña.'
      using errcode = 'insufficient_privilege';
  end if;
  if v_motivo is distinct from 'CAMPANIA_TERMINADA' then
    perform public.lanzar_motivo_mapa(v_motivo);
  end if;

  v_dia := coalesce(p_fecha, v_hoy);
  if v_dia > v_hoy then
    raise exception 'Ese día todavía no llegó. Elegí hoy o un día anterior.'
      using errcode = 'invalid_parameter_value';
  end if;

  select * into v_campania from public.campania c where c.id = p_campania_id;
  v_en_campania := v_dia >= v_campania.fecha_inicio
               and v_dia <= coalesce(v_campania.fecha_fin, 'infinity'::date);

  -- El día de Montevideo, como rango de instantes.
  v_desde := v_dia::timestamp at time zone 'America/Montevideo';
  v_hasta := (v_dia + 1)::timestamp at time zone 'America/Montevideo';

  with inscripcion as materialized (
    -- Una por colportor de la campaña con la inscripción vigente ese día (unique campania_id,
    -- usuario_id): creada antes de que termine el día y sin baja, o con la baja posterior al
    -- comienzo del día. La ciudad sale de la zona actual; una zona o una ciudad de campaña dadas
    -- de baja no cuentan, y una inscripción de baja no tiene ciudad, como en 0044 (ciudad_id null
    -- = sin zona asignada). `baja` limita la actividad que cuenta: solo la anterior a la baja.
    select i.usuario_id, i.deleted_at as baja, i.created_at as inscripto_at, ci.ciudad_id
      from public.campania_colportor i
      left join public.zona z
             on z.id = i.zona_id and z.deleted_at is null and i.deleted_at is null
      left join public.campania_ciudad ci
             on ci.id = z.campania_ciudad_id and ci.deleted_at is null
     where i.campania_id = p_campania_id
       and i.created_at < v_hasta
       and (i.deleted_at is null or i.deleted_at > v_desde)
  ),
  jornadas as (
    select ins.usuario_id,
           count(*) as cantidad,
           bool_or(j.fin is null) as abierta,
           sum(case
                 when j.fin is not null then extract(epoch from (j.fin - j.inicio))
                 -- La abierta de hoy suma hasta ahora; la de un día anterior no inventa un fin.
                 when v_dia = v_hoy then greatest(extract(epoch from (v_ahora - j.inicio)), 0)
                 else 0
               end) as segundos
      from inscripcion ins
      join public.jornada j on j.colportor_id = ins.usuario_id
     where v_en_campania
       and j.deleted_at is null
       and j.inicio >= v_desde
       and j.inicio <  v_hasta
       and (ins.baja is null or j.inicio < ins.baja)
     group by ins.usuario_id
  ),
  ventas as (
    select ins.usuario_id, count(*) as cantidad, sum(v.monto_total)::bigint as monto
      from inscripcion ins
      join public.venta v on v.colportor_id = ins.usuario_id
     where v_en_campania
       and v.deleted_at is null
       and v.fecha >= v_desde
       and v.fecha <  v_hasta
     group by ins.usuario_id
  ),
  presentaciones as (
    select ins.usuario_id, count(*) as cantidad
      from inscripcion ins
      join public.visita vi on vi.colportor_id = ins.usuario_id
     where v_en_campania
       and vi.deleted_at is null
       and vi.tipo_resultado = any (c_presentacion)
       and vi.fecha >= v_desde
       and vi.fecha <  v_hasta
     group by ins.usuario_id
  ),
  colportor as (
    select ins.usuario_id,
           ins.ciudad_id,
           (ins.baja is not null) as de_baja,
           ins.inscripto_at,
           usr.nombre,
           usr.apellido,
           usr.ultimo_push_at,
           case
             when coalesce(j.abierta, false) and v_dia = v_hoy then 'EN_JORNADA'
             -- Un día anterior con una jornada que quedó abierta: nada inventa su fin.
             when coalesce(j.abierta, false) then 'SIN_CERRAR'
             when coalesce(j.cantidad, 0) > 0 then 'FINALIZADA'
             else 'SIN_INICIAR'
           end as estado,
           round(coalesce(j.segundos, 0) / 3600, 2) as horas,
           coalesce(p.cantidad, 0)::integer as presentaciones,
           coalesce(v.cantidad, 0)::integer as ventas,
           coalesce(v.monto, 0)::bigint as monto_total
      from inscripcion ins
      join public.usuario usr on usr.id = ins.usuario_id
      left join jornadas j on j.usuario_id = ins.usuario_id
      left join ventas v on v.usuario_id = ins.usuario_id
      left join presentaciones p on p.usuario_id = ins.usuario_id
  )
  select jsonb_build_object(
           'fecha', to_jsonb(v_dia),
           'es_hoy', (v_dia = v_hoy),
           'calculado_a', to_jsonb(v_ahora),
           'total', (
             select jsonb_build_object(
                      'cantidad_colportores', count(*)::integer,
                      'en_jornada', (count(*) filter (where c.estado = 'EN_JORNADA'))::integer,
                      'horas', coalesce(sum(c.horas), 0),
                      'presentaciones', coalesce(sum(c.presentaciones), 0)::integer,
                      'ventas', coalesce(sum(c.ventas), 0)::integer,
                      'monto_total', coalesce(sum(c.monto_total), 0)::bigint)
               from colportor c
              where c.ciudad_id is not null),
           'ciudades', (
             select coalesce(jsonb_agg(
                      jsonb_build_object(
                        'ciudad_id', ciu.id,
                        'nombre', ciu.nombre,
                        'cantidad_colportores', coalesce(a.cantidad, 0),
                        'en_jornada', coalesce(a.en_jornada, 0),
                        'horas', coalesce(a.horas, 0),
                        'presentaciones', coalesce(a.presentaciones, 0),
                        'ventas', coalesce(a.ventas, 0),
                        'monto_total', coalesce(a.monto_total, 0),
                        'colportores', coalesce(a.lista, '[]'::jsonb))
                      order by ciu.nombre, ciu.id), '[]'::jsonb)
               from public.campania_ciudad cc
               join public.ciudad ciu on ciu.id = cc.ciudad_id
               left join lateral (
                 select count(*)::integer as cantidad,
                        (count(*) filter (where c.estado = 'EN_JORNADA'))::integer as en_jornada,
                        sum(c.horas) as horas,
                        sum(c.presentaciones)::integer as presentaciones,
                        sum(c.ventas)::integer as ventas,
                        sum(c.monto_total)::bigint as monto_total,
                        jsonb_agg(
                          jsonb_build_object(
                            'colportor_id', c.usuario_id,
                            'nombre', c.nombre,
                            'apellido', c.apellido,
                            'estado', c.estado,
                            'horas', c.horas,
                            'presentaciones', c.presentaciones,
                            'ventas', c.ventas,
                            'monto_total', c.monto_total,
                            'ultimo_push_at', c.ultimo_push_at)
                          order by c.apellido, c.nombre, c.usuario_id) as lista
                   from colportor c
                  where c.ciudad_id = cc.ciudad_id) a on true
              where cc.campania_id = p_campania_id
                and cc.deleted_at is null),
           'sin_zona', (
             select coalesce(jsonb_agg(
                      jsonb_build_object(
                        'colportor_id', c.usuario_id,
                        'nombre', c.nombre,
                        'apellido', c.apellido,
                        'estado', c.estado,
                        'inscripcion_de_baja', c.de_baja,
                        'inscripto_at', c.inscripto_at,
                        'ultimo_push_at', c.ultimo_push_at)
                      order by c.apellido, c.nombre, c.usuario_id), '[]'::jsonb)
               from colportor c
              where c.ciudad_id is null),
           'pendientes', '[]'::jsonb)
    into v_res;

  return v_res;
end;
$$;

comment on function public.tablero_de_inicio(uuid, date) is
  'Vista 31 (Inicio), HU-CAM-008 (0054 y 0055, backend-supabase#94): el día (p_fecha, hoy si es null; '
  'no puede ser futuro) de la campaña en un jsonb: total, ciudades (cada una con sus cifras y sus '
  'colportores: estado EN_JORNADA | SIN_CERRAR | FINALIZADA | SIN_INICIAR, horas, presentaciones = visitas '
  'VENTA o ENTREVISTA, ventas, monto en centavos y ultimo_push_at), sin_zona (fuera de las '
  'cifras, con inscripcion_de_baja e inscripto_at = cuándo se inscribió) y pendientes (vacío hasta V2). La ciudad es la de la zona actual del colportor; los colportores son los de las inscripciones '
  'vigentes ese día. Solo '
  'totales: ni clientes, ni ubicaciones, ni talonarios. Errores: 42501 sin permiso; CZ001 '
  'campaña inexistente; 22023 fecha futura. Una campaña terminada se lee.';
