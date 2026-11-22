-- ============================================================================
-- 0106 · La ciudad de un colportor es la de la zona que tenía ese día, según el historial de zonas
--        (backend-supabase#141, seguimiento de #95, decisión de Cristian del 23/10, «Horas y zona»)
--
-- Decisión de Cristian (23/10, «Horas y zona»): «La zona de ese día». Cada jornada cuenta en la
-- ciudad de la zona que el colportor tenía el día en que la trabajó, según el historial de zonas
-- que ya guarda la nube (campania_colportor_zona_historial, 0022; desde <= inicio < hasta); los
-- días en que no tenía zona van a «Sin zona asignada». Un reporte de un mes cerrado no cambia
-- aunque después lo muevan. Sin datos nuevos. Caso: Ana trabajó tres semanas en Rivera y la
-- pasan a una zona de Artigas; en Reportes, las horas de Rivera quedan en Rivera para liquidar
-- viáticos.
-- Decisión del agente de decisiones (25/10), regla R7: el historial vale también para un
-- colportor cuya inscripción se dio de baja después (Joaquín trabajó 80 horas y se dio de baja el
-- 12/10: sus horas de cada día van a la ciudad de la zona que tenía ese día; la ciudad nula queda
-- solo para los días sin zona).
--
-- Recrea con `create or replace` (misma firma y mismo tipo de retorno: conservan sus
-- privilegios; los comentarios se vuelven a poner). Las migraciones anteriores no se editan.
--
--   · horas_por_ciudad_y_colportor (0060): la ciudad se busca por JORNADA, en el instante de su
--     `inicio`: el tramo del historial de la inscripción con desde <= inicio < hasta (hasta null =
--     vigente). Una jornada que cruza la medianoche o un cambio de zona cuenta entera donde empezó.
--   · ventas_por_ciudad_y_colportor (0061, la hermana: «la misma ciudad del colportor»): lo mismo,
--     por venta y por visita, en el instante de su `fecha`.
--   · tablero_de_inicio (0055, el día pasado del tablero): un colportor aparece en UNA ciudad, así
--     que se toma la zona que tenía ese día: el tramo que cubre el día y, si hubo más de uno (lo
--     cambiaron de zona ese mismo día), el último; quien se quedó sin zona o se dio de baja a media
--     jornada sigue en la ciudad donde trabajó esa mañana. Hoy es la zona de ahora (el tablero en
--     vivo), igual que antes: quien ya no tiene zona hoy figura en «Sin zona».
--
-- Qué cambia respecto de la zona actual
--
--   · Cambio de zona a mitad de mes: las jornadas de antes del cambio quedan en la ciudad de la
--     zona vieja y las de después en la de la nueva; antes todo el mes iba a la ciudad nueva. El
--     colportor sale con una fila por ciudad y período (el panel ya suma por ciudad).
--   · Los días sin zona van a «sin ciudad» (ciudad_id y ciudad_nombre null), UNA sola vez: antes de
--     que le asignaran zona, después de un «Quitar» o de la baja de la inscripción.
--   · Un colportor dado de baja (inscripción) o con la zona o la ciudad de la campaña dadas de baja
--     DESPUÉS ya no pierde la ciudad de los días en que sí la tenía: el tramo de esos días sigue en
--     el historial. Por eso no se filtra por `deleted_at` de la zona ni de la ciudad de campaña (un
--     reporte cerrado no se mueve porque después las den de baja). Las jornadas posteriores a la
--     baja de la inscripción siguen sin contar, como antes. Excepción: el tablero solo lista las
--     ciudades vivas de la campaña, así que un tramo cuya ciudad de campaña se dio de baja va a
--     «Sin zona» ahí, para que nadie quede fuera de la lista.
--   · Tendencia (horas_anterior, jornadas_anterior, etc.): la comparación sigue siendo por ciudad y
--     colportor. Si Ana pasó de Rivera a Artigas, el período siguiente trae su fila de Artigas con
--     lo suyo y una fila de Rivera con 0 y lo del período anterior: la suma por ciudad es la
--     verdad de cada una (en Rivera bajó a cero), nada se cuenta dos veces.
--   · Un tramo `inicial` (0022, inscripciones que ya tenían zona cuando se activó el historial)
--     abre en la fecha de esa migración, no en la de la asignación real: lo anterior a esa fecha
--     cuenta como sin zona. Los datos de hoy son simulados y producción arranca en diciembre
--     (decisión del 02/10), así que no se reconstruye nada.
--
-- Sin datos nuevos, sin cambio de firma: el panel (front-coordinadores-web#60) no cambia, la ciudad
-- llega de la RPC. No toca el sync. Rendimiento: la búsqueda del tramo usa el índice
-- (campania_colportor_id, desde) del historial.
--
-- Para otros repos
--   · docs-organizacion: HU-REP-001 y esquema-datos.md (campania_colportor_zona_historial) pasan a
--     decir que la ciudad de las horas, las ventas y el tablero de un día sale del historial de
--     zonas de ese día; issue en docs-organizacion.
--
-- Forward-only: no se edita una vez aplicada.
-- ============================================================================

create or replace function public.horas_por_ciudad_y_colportor(p_campania_id uuid, p_desde date, p_hasta date,
                                                    p_agrupar text,
                                                    p_ciudad_id uuid default null,
                                                    p_colportor_ids uuid[] default null)
returns table (periodo_inicio date, periodo_fin date, ciudad_id uuid, ciudad_nombre text,
               colportor_id uuid, nombre text, apellido text, horas numeric, jornadas integer,
               dias_trabajados integer, jornadas_acompaniadas integer, en_curso boolean,
               horas_anterior numeric, jornadas_anterior integer)
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  c_sin_ciudad constant uuid := '00000000-0000-0000-0000-000000000000'::uuid;
  v_motivo     text;
  v_campania   public.campania;
  v_hoy        date := public.hoy_montevideo();
  v_ini        date;
  v_fin        date;
  v_desde_leer date;
begin
  -- El permiso, antes de mirar nada más. Una campaña terminada se lee (un reporte de horas se
  -- pide al cierre); lo demás es lo de siempre de la vista 24.
  v_motivo := public.motivo_mapa_de_campania(p_campania_id);
  if v_motivo = 'SIN_PERMISO' then
    raise exception 'Solo el coordinador de la campaña o un administrador puede ver sus reportes. Entrá con la cuenta del coordinador de esta campaña.'
      using errcode = 'insufficient_privilege';
  end if;
  if v_motivo is distinct from 'CAMPANIA_TERMINADA' then
    perform public.lanzar_motivo_mapa(v_motivo);
  end if;

  if p_agrupar is null or p_agrupar not in ('dia', 'semana', 'mes') then
    raise exception 'Elegí cómo agrupar las horas: por día, por semana o por mes.'
      using errcode = 'invalid_parameter_value';
  end if;
  if p_desde is null or p_hasta is null or p_desde > p_hasta then
    raise exception 'Elegí un rango de fechas: la fecha de inicio no puede ser posterior a la de fin.'
      using errcode = 'invalid_parameter_value';
  end if;

  -- El rango, a períodos completos.
  if p_agrupar = 'dia' then
    v_ini := p_desde;
    v_fin := p_hasta;
  elsif p_agrupar = 'semana' then
    v_ini := date_trunc('week', p_desde::timestamp)::date;
    v_fin := date_trunc('week', p_hasta::timestamp)::date + 6;
  else
    v_ini := date_trunc('month', p_desde::timestamp)::date;
    v_fin := (date_trunc('month', p_hasta::timestamp) + interval '1 month' - interval '1 day')::date;
  end if;
  if v_fin - v_ini + 1 > 366 then
    raise exception 'El rango es demasiado largo: pedí hasta 366 días por vez.'
      using errcode = 'invalid_parameter_value';
  end if;

  select * into v_campania from public.campania c where c.id = p_campania_id;

  -- Hasta dónde hay que mirar hacia atrás para el período anterior.
  v_desde_leer := v_ini - case p_agrupar when 'dia' then 2 when 'semana' then 7 else 31 end;

  return query
    with inscripcion as materialized (
      -- Una por colportor de la campaña (unique campania_id, usuario_id), con el día desde el que
      -- cuenta (el de su inscripción) y la baja hasta la que cuenta. La ciudad ya no sale de aquí:
      -- sale del historial de zonas, jornada por jornada (más abajo).
      select i.id as inscripcion_id,
             i.usuario_id,
             i.deleted_at as baja,
             public.hoy_montevideo(i.created_at) as desde_dia
        from public.campania_colportor i
       where i.campania_id = p_campania_id
         and (p_colportor_ids is null or i.usuario_id = any (p_colportor_ids))
    ),
    diario as materialized (
      -- Lo trabajado por colportor, ciudad de la zona de ese día y día de Montevideo.
      select zd.ciudad_k,
             ins.usuario_id,
             public.hoy_montevideo(j.inicio) as dia,
             count(*)::integer as jornadas,
             (count(*) filter (where j.acompaniante_id is not null))::integer as acompaniadas,
             sum(extract(epoch from (j.fin - j.inicio)))::numeric as segundos
        from inscripcion ins
        join public.jornada j on j.colportor_id = ins.usuario_id
       cross join lateral (
         -- La ciudad de la zona que tenía en el instante j.inicio (0022: desde <= instante < hasta,
         -- hasta null = vigente). Sin tramo, o con un tramo cuya zona ya no tiene ciudad: sin ciudad.
         select coalesce(
                  (select ci.ciudad_id
                     from public.campania_colportor_zona_historial h
                     join public.zona z on z.id = h.zona_id
                     join public.campania_ciudad ci on ci.id = z.campania_ciudad_id
                    where h.campania_colportor_id = ins.inscripcion_id
                      and h.deleted_at is null
                      and h.desde <= j.inicio
                      and (h.hasta is null or j.inicio < h.hasta)
                    order by h.desde desc
                    limit 1),
                  c_sin_ciudad) as ciudad_k
       ) zd
       where j.deleted_at is null
         and j.fin is not null
         and j.inicio >= (v_desde_leer::timestamp at time zone 'America/Montevideo')
         and j.inicio <  ((v_fin + 1)::timestamp at time zone 'America/Montevideo')
         and public.hoy_montevideo(j.inicio) >= v_campania.fecha_inicio
         and public.hoy_montevideo(j.inicio) <= coalesce(v_campania.fecha_fin, 'infinity'::date)
         and public.hoy_montevideo(j.inicio) >= ins.desde_dia
         and (ins.baja is null or j.inicio < ins.baja)
         and (p_ciudad_id is null
              or (zd.ciudad_k = p_ciudad_id and p_ciudad_id <> c_sin_ciudad))
       group by zd.ciudad_k, ins.usuario_id, public.hoy_montevideo(j.inicio)
    ),
    actual as (
      -- Lo del período (dentro del rango redondeado).
      select d.ciudad_k, d.usuario_id,
             case p_agrupar
               when 'dia' then d.dia
               when 'semana' then date_trunc('week', d.dia::timestamp)::date
               else date_trunc('month', d.dia::timestamp)::date
             end as p_ini,
             sum(d.segundos) as segundos,
             sum(d.jornadas)::integer as jornadas,
             sum(d.acompaniadas)::integer as acompaniadas,
             count(*)::integer as dias
        from diario d
       where d.dia between v_ini and v_fin
       group by 1, 2, 3
    ),
    anterior as (
      -- Cada día trabajado, puesto como «anterior» del período contra el que se compara:
      --   día: el día siguiente (un sábado también del lunes; un domingo de nadie);
      --   semana: la semana siguiente;
      --   mes: el mes siguiente, y si es el mes en curso, solo hasta el día de hoy.
      select d.ciudad_k, d.usuario_id, k.clave,
             sum(d.segundos) as segundos,
             sum(d.jornadas)::integer as jornadas
        from diario d
       cross join lateral unnest(
         case p_agrupar
           when 'dia' then
             case extract(isodow from d.dia)::integer
               when 7 then array[]::date[]
               when 6 then array[d.dia + 1, d.dia + 2]
               else array[d.dia + 1]
             end
           when 'semana' then
             array[date_trunc('week', d.dia::timestamp)::date + 7]
           else
             case
               when (date_trunc('month', d.dia::timestamp) + interval '1 month')::date
                      = date_trunc('month', v_hoy::timestamp)::date
                    and extract(day from d.dia) > extract(day from v_hoy)
                 then array[]::date[]
               else array[(date_trunc('month', d.dia::timestamp) + interval '1 month')::date]
             end
         end
       ) as k(clave)
       group by d.ciudad_k, d.usuario_id, k.clave
    ),
    unidas as (
      select coalesce(a.ciudad_k, p.ciudad_k) as ciudad_k,
             coalesce(a.usuario_id, p.usuario_id) as usuario_id,
             coalesce(a.p_ini, p.clave) as p_ini,
             a.segundos, a.jornadas, a.acompaniadas, a.dias,
             p.segundos as segundos_ant, p.jornadas as jornadas_ant
        from actual a
        full join anterior p
               on p.ciudad_k = a.ciudad_k and p.usuario_id = a.usuario_id and p.clave = a.p_ini
    ),
    periodos as (
      select u.*,
             case p_agrupar
               when 'dia' then u.p_ini
               when 'semana' then u.p_ini + 6
               else (u.p_ini + interval '1 month' - interval '1 day')::date
             end as p_fin
        from unidas u
       where u.p_ini between v_ini and v_fin
         and u.p_ini <= v_hoy
    ),
    final as (
      select p.*,
             (v_hoy between p.p_ini and p.p_fin) as en_curso
        from periodos p
    )
    select f.p_ini,
           f.p_fin,
           nullif(f.ciudad_k, c_sin_ciudad),
           ciu.nombre,
           f.usuario_id,
           usr.nombre,
           usr.apellido,
           round(coalesce(f.segundos, 0) / 3600, 2),
           coalesce(f.jornadas, 0),
           coalesce(f.dias, 0),
           coalesce(f.acompaniadas, 0),
           f.en_curso,
           -- Lo en curso no se compara, salvo el mes a la fecha.
           case when f.en_curso and p_agrupar <> 'mes' then null
                else round(coalesce(f.segundos_ant, 0) / 3600, 2) end,
           case when f.en_curso and p_agrupar <> 'mes' then null
                else coalesce(f.jornadas_ant, 0) end
      from final f
      left join public.ciudad ciu on ciu.id = nullif(f.ciudad_k, c_sin_ciudad)
      join public.usuario usr on usr.id = f.usuario_id
     -- Una fila con jornadas = 0 solo si hay algo que comparar (un período en curso sin su
     -- anterior a la vista no dice nada).
     where f.jornadas > 0
        or not (f.en_curso and p_agrupar <> 'mes')
     order by f.p_ini, ciu.nombre nulls last, usr.apellido, usr.nombre, f.usuario_id;
end;
$$;

comment on function public.horas_por_ciudad_y_colportor(uuid, date, date, text, uuid, uuid[]) is
  'Vista 32, HU-REP-001 (0060, backend-supabase#95; la ciudad por el historial de zonas desde 0106, #141): horas trabajadas por período (p_agrupar = '
  'dia | semana | mes) × ciudad (la de la zona que tenía el colportor el día de cada jornada, según el historial de zonas; sin zona ese día, ciudad null) × '
  'colportor, con jornadas cerradas de la campaña, y las del período anterior para la tendencia '
  '(el día anterior, el lunes contra el sábado; la semana anterior; el mismo tramo del mes '
  'pasado; lo en curso no se compara salvo el mes a la fecha). El rango sube a períodos completos; '
  'hasta 366 días. Cada colportor cuenta desde el día de su inscripción en la campaña y hasta su baja. Solo totales: ni clientes, ni ventas, ni importes. Errores: 42501 sin permiso; '
  'CZ001 campaña inexistente; 22023 agrupación, fechas o rango inválidos. Una campaña terminada '
  'se lee.';

-- `authenticated` y `service_role` también en el revoke: en una base creada desde cero los
-- default privileges de la imagen les dan EXECUTE sobre cada función nueva de public (0008).
revoke all on function public.horas_por_ciudad_y_colportor(uuid, date, date, text, uuid, uuid[])
  from public, anon, authenticated, service_role;
grant execute on function public.horas_por_ciudad_y_colportor(uuid, date, date, text, uuid, uuid[])
  to authenticated;

create or replace function public.ventas_por_ciudad_y_colportor(p_campania_id uuid, p_desde date, p_hasta date,
                                                     p_agrupar text,
                                                     p_ciudad_id uuid default null,
                                                     p_colportor_ids uuid[] default null)
returns table (periodo_inicio date, periodo_fin date, ciudad_id uuid, ciudad_nombre text,
               colportor_id uuid, nombre text, apellido text, ventas integer, monto_total bigint,
               presentaciones integer, en_curso boolean,
               ventas_anterior integer, monto_anterior bigint, presentaciones_anterior integer,
               cobrado bigint, cobrado_anterior bigint)
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  c_sin_ciudad  constant uuid := '00000000-0000-0000-0000-000000000000'::uuid;
  -- Resultados de una visita que cuentan como presentación (HU-VIS-005, S62: RECHAZO, a confirmar).
  c_presentacion constant text[] := array['VENTA', 'ENTREVISTA'];
  v_motivo      text;
  v_campania    public.campania;
  v_hoy         date := public.hoy_montevideo();
  v_ini         date;
  v_fin         date;
  v_desde_leer  date;
begin
  -- El permiso, antes de mirar nada más. Una campaña terminada se lee (un reporte se pide al
  -- cierre); lo demás es lo de siempre de la vista 24.
  v_motivo := public.motivo_mapa_de_campania(p_campania_id);
  if v_motivo = 'SIN_PERMISO' then
    raise exception 'Solo el coordinador de la campaña o un administrador puede ver sus reportes. Entrá con la cuenta del coordinador de esta campaña.'
      using errcode = 'insufficient_privilege';
  end if;
  if v_motivo is distinct from 'CAMPANIA_TERMINADA' then
    perform public.lanzar_motivo_mapa(v_motivo);
  end if;

  if p_agrupar is null or p_agrupar not in ('dia', 'semana', 'mes') then
    raise exception 'Elegí cómo agrupar las ventas: por día, por semana o por mes.'
      using errcode = 'invalid_parameter_value';
  end if;
  if p_desde is null or p_hasta is null or p_desde > p_hasta then
    raise exception 'Elegí un rango de fechas: la fecha de inicio no puede ser posterior a la de fin.'
      using errcode = 'invalid_parameter_value';
  end if;

  -- El rango, a períodos completos.
  if p_agrupar = 'dia' then
    v_ini := p_desde;
    v_fin := p_hasta;
  elsif p_agrupar = 'semana' then
    v_ini := date_trunc('week', p_desde::timestamp)::date;
    v_fin := date_trunc('week', p_hasta::timestamp)::date + 6;
  else
    v_ini := date_trunc('month', p_desde::timestamp)::date;
    v_fin := (date_trunc('month', p_hasta::timestamp) + interval '1 month' - interval '1 day')::date;
  end if;
  if v_fin - v_ini + 1 > 366 then
    raise exception 'El rango es demasiado largo: pedí hasta 366 días por vez.'
      using errcode = 'invalid_parameter_value';
  end if;

  select * into v_campania from public.campania c where c.id = p_campania_id;

  -- Hasta dónde hay que mirar hacia atrás para el período anterior.
  v_desde_leer := v_ini - case p_agrupar when 'dia' then 2 when 'semana' then 7 else 31 end;

  return query
    with inscripcion as materialized (
      -- Una por colportor de la campaña (unique campania_id, usuario_id). La ciudad ya no sale
      -- de aquí: sale del historial de zonas, venta por venta (más abajo). `desde_dia`: el día en
      -- que se inscribió en esta campaña; antes de eso lo hecho no es de ella.
      select i.id as inscripcion_id,
             i.usuario_id,
             i.deleted_at as baja,
             public.hoy_montevideo(i.created_at) as desde_dia
        from public.campania_colportor i
       where i.campania_id = p_campania_id
         and (p_colportor_ids is null or i.usuario_id = any (p_colportor_ids))
    ),
    diario as materialized (
      -- Lo hecho por colportor y día de Montevideo: cada venta suma 1 venta y su monto; cada
      -- visita con la entrevista hecha suma 1 presentación.
      select zd.ciudad_k,
             ins.usuario_id,
             x.dia,
             (sum(x.n_ventas))::integer as ventas,
             (sum(x.monto))::bigint as monto,
             (sum(x.n_pres))::integer as presentaciones
        from inscripcion ins
       cross join lateral (
         select public.hoy_montevideo(v.fecha) as dia,
                1 as n_ventas, v.monto_total::bigint as monto, 0 as n_pres, v.fecha as cuando
           from public.venta v
          where v.colportor_id = ins.usuario_id
            and v.deleted_at is null
         union all
         select public.hoy_montevideo(vi.fecha), 0, 0::bigint, 1, vi.fecha
           from public.visita vi
          where vi.colportor_id = ins.usuario_id
            and vi.deleted_at is null
            and vi.tipo_resultado = any (c_presentacion)
       ) x
       cross join lateral (
         -- La ciudad de la zona que tenía en el instante x.cuando (0022: desde <= instante < hasta,
         -- hasta null = vigente). Sin tramo, o con un tramo cuya zona ya no tiene ciudad: sin ciudad.
         select coalesce(
                  (select ci.ciudad_id
                     from public.campania_colportor_zona_historial h
                     join public.zona z on z.id = h.zona_id
                     join public.campania_ciudad ci on ci.id = z.campania_ciudad_id
                    where h.campania_colportor_id = ins.inscripcion_id
                      and h.deleted_at is null
                      and h.desde <= x.cuando
                      and (h.hasta is null or x.cuando < h.hasta)
                    order by h.desde desc
                    limit 1),
                  c_sin_ciudad) as ciudad_k
       ) zd
       where x.cuando >= (v_desde_leer::timestamp at time zone 'America/Montevideo')
         and x.cuando <  ((v_fin + 1)::timestamp at time zone 'America/Montevideo')
         and x.dia >= v_campania.fecha_inicio
         and x.dia <= coalesce(v_campania.fecha_fin, 'infinity'::date)
         and x.dia >= ins.desde_dia
         and (ins.baja is null or x.cuando < ins.baja)
         and (p_ciudad_id is null
              or (zd.ciudad_k = p_ciudad_id and p_ciudad_id <> c_sin_ciudad))
       group by zd.ciudad_k, ins.usuario_id, x.dia
    ),
    actual as (
      -- Lo del período (dentro del rango redondeado).
      select d.ciudad_k, d.usuario_id,
             case p_agrupar
               when 'dia' then d.dia
               when 'semana' then date_trunc('week', d.dia::timestamp)::date
               else date_trunc('month', d.dia::timestamp)::date
             end as p_ini,
             sum(d.ventas)::integer as ventas,
             sum(d.monto)::bigint as monto,
             sum(d.presentaciones)::integer as presentaciones
        from diario d
       where d.dia between v_ini and v_fin
       group by 1, 2, 3
    ),
    anterior as (
      -- Cada día con datos, puesto como «anterior» del período contra el que se compara:
      --   día: el día siguiente (un sábado también del lunes; un domingo de nadie);
      --   semana: la semana siguiente;
      --   mes: el mes siguiente, y si es el mes en curso, solo hasta el día de hoy.
      select d.ciudad_k, d.usuario_id, k.clave,
             sum(d.ventas)::integer as ventas,
             sum(d.monto)::bigint as monto,
             sum(d.presentaciones)::integer as presentaciones
        from diario d
       cross join lateral unnest(
         case p_agrupar
           when 'dia' then
             case extract(isodow from d.dia)::integer
               when 7 then array[]::date[]
               when 6 then array[d.dia + 1, d.dia + 2]
               else array[d.dia + 1]
             end
           when 'semana' then
             array[date_trunc('week', d.dia::timestamp)::date + 7]
           else
             case
               when (date_trunc('month', d.dia::timestamp) + interval '1 month')::date
                      = date_trunc('month', v_hoy::timestamp)::date
                    and extract(day from d.dia) > extract(day from v_hoy)
                 then array[]::date[]
               else array[(date_trunc('month', d.dia::timestamp) + interval '1 month')::date]
             end
         end
       ) as k(clave)
       group by d.ciudad_k, d.usuario_id, k.clave
    ),
    unidas as (
      select coalesce(a.ciudad_k, p.ciudad_k) as ciudad_k,
             coalesce(a.usuario_id, p.usuario_id) as usuario_id,
             coalesce(a.p_ini, p.clave) as p_ini,
             a.ventas, a.monto, a.presentaciones,
             p.ventas as ventas_ant, p.monto as monto_ant, p.presentaciones as pres_ant
        from actual a
        full join anterior p
               on p.ciudad_k = a.ciudad_k and p.usuario_id = a.usuario_id and p.clave = a.p_ini
    ),
    periodos as (
      select u.*,
             case p_agrupar
               when 'dia' then u.p_ini
               when 'semana' then u.p_ini + 6
               else (u.p_ini + interval '1 month' - interval '1 day')::date
             end as p_fin
        from unidas u
       where u.p_ini between v_ini and v_fin
         and u.p_ini <= v_hoy
    ),
    final as (
      select p.*,
             (v_hoy between p.p_ini and p.p_fin) as en_curso
        from periodos p
    )
    select f.p_ini,
           f.p_fin,
           nullif(f.ciudad_k, c_sin_ciudad),
           ciu.nombre,
           f.usuario_id,
           usr.nombre,
           usr.apellido,
           coalesce(f.ventas, 0),
           coalesce(f.monto, 0)::bigint,
           coalesce(f.presentaciones, 0),
           f.en_curso,
           -- Lo en curso no se compara, salvo el mes a la fecha.
           case when f.en_curso and p_agrupar <> 'mes' then null
                else coalesce(f.ventas_ant, 0) end,
           case when f.en_curso and p_agrupar <> 'mes' then null
                else coalesce(f.monto_ant, 0)::bigint end,
           case when f.en_curso and p_agrupar <> 'mes' then null
                else coalesce(f.pres_ant, 0) end,
           -- V2: lo cobrado depende de los cobros (HU-COB-005, HU-CTA-005): null = sin conectar.
           null::bigint,
           null::bigint
      from final f
      left join public.ciudad ciu on ciu.id = nullif(f.ciudad_k, c_sin_ciudad)
      join public.usuario usr on usr.id = f.usuario_id
     -- Una fila vacía solo si hay algo que comparar (un período en curso sin su anterior a la
     -- vista no dice nada).
     where coalesce(f.ventas, 0) > 0
        or coalesce(f.presentaciones, 0) > 0
        or not (f.en_curso and p_agrupar <> 'mes')
     order by f.p_ini, ciu.nombre nulls last, usr.apellido, usr.nombre, f.usuario_id;
end;
$$;

comment on function public.ventas_por_ciudad_y_colportor(uuid, date, date, text, uuid, uuid[]) is
  'Vista 32, HU-REP-002 (0061, backend-supabase#96; la ciudad por el historial de zonas desde 0106, #141): ventas (cantidad y monto en centavos) y '
  'presentaciones (visitas VENTA o ENTREVISTA) por período (p_agrupar = dia | semana | mes) × '
  'ciudad (la de la zona que tenía el colportor el día de cada venta o visita, según el historial de zonas; sin zona ese día, ciudad null) × colportor, de la '
  'campaña (desde el día en que se inscribió en ella), y lo del período anterior para la '
  'tendencia (el día anterior, el lunes contra el sábado; la semana anterior; el mismo tramo '
  'del mes pasado; lo en curso no se compara salvo el mes a la fecha). cobrado y '
  'cobrado_anterior (centavos) son null hasta V2: el panel saca el % por cobrar. El rango sube a períodos completos; '
  'hasta 366 días. Solo totales: ni clientes, ni cobros, ni ubicaciones. Errores: 42501 sin '
  'permiso; CZ001 campaña inexistente; 22023 agrupación, fechas o rango inválidos. Una campaña '
  'terminada se lee.';

-- `authenticated` y `service_role` también en el revoke: en una base creada desde cero los
-- default privileges de la imagen les dan EXECUTE sobre cada función nueva de public (0008).
revoke all on function public.ventas_por_ciudad_y_colportor(uuid, date, date, text, uuid, uuid[])
  from public, anon, authenticated, service_role;
grant execute on function public.ventas_por_ciudad_y_colportor(uuid, date, date, text, uuid, uuid[])
  to authenticated;

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
    -- comienzo del día. La ciudad es la de la zona que tenía ese día según el historial de zonas
    -- (0022). Hoy es la zona de ahora (el tablero en vivo); un día anterior, el tramo que cubre el
    -- día y, si hubo más de uno (lo cambiaron de zona ese mismo día), el último: quien se quedó sin
    -- zona o se dio de baja a las 12:00 sigue donde trabajó esa mañana. Sin tramo ese día (nunca
    -- tuvo zona, o ya se la habían quitado) o con la ciudad de campaña dada de baja: ciudad_id null
    -- = sin zona asignada. `baja` limita la actividad que cuenta: solo la anterior a la baja.
    select i.usuario_id, i.deleted_at as baja, i.created_at as inscripto_at,
           (select ci.ciudad_id
              from public.campania_colportor_zona_historial h
              join public.zona z on z.id = h.zona_id
              join public.campania_ciudad ci on ci.id = z.campania_ciudad_id and ci.deleted_at is null
             where h.campania_colportor_id = i.id
               and h.deleted_at is null
               and h.desde < v_hasta
               and (h.hasta is null or h.hasta > v_desde)
               -- Hoy es la zona de ahora (el tablero en vivo); un día anterior, la última del día.
               and (v_dia < v_hoy or h.hasta is null)
             order by h.desde desc
             limit 1) as ciudad_id
      from public.campania_colportor i
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
  'Vista 31 (Inicio), HU-CAM-008 (0054, 0055 y 0106, backend-supabase#94 y #141): el día (p_fecha, hoy si es null; '
  'no puede ser futuro) de la campaña en un jsonb: total, ciudades (cada una con sus cifras y sus '
  'colportores: estado EN_JORNADA | SIN_CERRAR | FINALIZADA | SIN_INICIAR, horas, presentaciones = visitas '
  'VENTA o ENTREVISTA, ventas, monto en centavos y ultimo_push_at), sin_zona (fuera de las '
  'cifras, con inscripcion_de_baja e inscripto_at = cuándo se inscribió) y pendientes (vacío hasta V2). La ciudad es la de la zona que tenía el colportor ese día, según el historial de zonas (0106, #141: la última si lo cambiaron de zona ese día); los colportores son los de las inscripciones '
  'vigentes ese día. Solo '
  'totales: ni clientes, ni ubicaciones, ni talonarios. Errores: 42501 sin permiso; CZ001 '
  'campaña inexistente; 22023 fecha futura. Una campaña terminada se lee.';
