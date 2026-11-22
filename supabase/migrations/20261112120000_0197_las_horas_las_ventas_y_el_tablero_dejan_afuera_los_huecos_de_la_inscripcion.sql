-- ============================================================================
-- 0197 · Las horas, las ventas y el tablero de Inicio dejan afuera lo que se hizo en un hueco de la inscripción
--        (backend-supabase#162, seguimiento de #140 y de #141)
--
-- Caso: a Diego lo dan de baja de la campaña, trabaja 20 días afuera y vuelve. Marta ve en Acompañamientos que
-- esos días no cuentan (0100: `inscripcion_cubre_el_instante()`), pero Horas por colportor, Ventas por ciudad y el
-- tablero de Inicio sí los contaban, y al reactivarlo esos días reaparecían en semanas que antes no los mostraban.
-- Y lo que Joaquín cargó mientras estaba afuera sumaba en «Sin zona asignada» de Reportes.
--
-- Decisiones (todas en el issue #162):
--   · «Jornada camp.» de Cristian, 26/10, regla R7: «las jornadas del tiempo en que estuvo afuera no cuentan en esa
--     campaña».
--   · Decisión del orquestador, 27/10: `ventas_por_ciudad_y_colportor` (0061) cuenta con la misma ventana que 0100:
--     desde el INSTANTE de alta (no desde el día), antes de la baja y fuera de los huecos.
--   · 10/11, punto 3 del issue: las funciones que reescribió la 0106 (#141, #168) también excluyen los huecos: horas,
--     ventas y el día pasado del tablero.
--
-- Qué cambia
--
--   · horas_por_ciudad_y_colportor (0060 → 0106): cada jornada cuenta solo si su `inicio` cae dentro de la inscripción
--     según `inscripcion_cubre_el_instante(alta, baja, tramos_afuera, inicio)`. Antes: desde el DÍA del alta y antes de
--     la baja, sin mirar los huecos. Se conservan por período `jornadas`, `dias_trabajados` y `jornadas_acompaniadas`
--     (las usa el reporte por rango del panel, front-coordinadores-web#107/#115, para el promedio por día y las
--     jornadas con acompañamiento).
--   · ventas_por_ciudad_y_colportor (0061 → 0106): lo mismo para cada venta y cada visita (con su `fecha`). Una venta
--     hecha el día del alta pero antes de la hora del alta ya no cuenta.
--   · tablero_de_inicio (0055 → 0106): el día pasado. Las jornadas, las ventas y las presentaciones de cada colportor
--     cuentan por la misma ventana. Los colportores del día siguen siendo los de las inscripciones vigentes ese día, y
--     se suma que quien estuvo afuera el día ENTERO (un hueco que lo cubre de punta a punta) no figura: tampoco cae en
--     «Sin zona». Un hueco que cubre solo parte del día lo deja en la lista y descuenta solo lo hecho adentro.
--
-- Lo que se hereda sin cambiar: la ciudad de cada día sale del historial de zonas (0106), la zona y el rango de fechas
-- de la campaña se miran igual, la firma y el tipo de retorno de las tres funciones (conservan sus privilegios; se
-- vuelven a poner) y los permisos. Sin datos nuevos y sin cambios en el sync.
--
-- Qué quedó igual a propósito: `acompaniamientos_por_colportor`, `historial_de_acompaniamientos` y
-- `jornadas_cerradas_de_colportor` ya usaban `inscripcion_cubre_el_instante()` desde la 0100.
--
-- Para otros repos
--   · docs-organizacion: HU-REP-001 y la HU de Inicio dicen que las horas, las ventas y el tablero cuentan desde el
--     instante del alta, hasta la baja y fuera de los huecos; esquema-datos.md (`campania_colportor.tramos_afuera`) lo
--     suma a los lectores de la columna. El issue de docs va en el cuerpo del PR.
--
-- Recrea con `create or replace` (las migraciones anteriores no se editan).
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
      -- Una por colportor de la campaña (unique campania_id, usuario_id), con el instante de su alta,
      -- su baja y sus huecos (tramos_afuera): lo que cuenta es lo que `inscripcion_cubre_el_instante()`
      -- (0100) dice que cae dentro. La ciudad no sale de aquí: sale del historial de zonas, jornada
      -- por jornada (más abajo).
      select i.id as inscripcion_id,
             i.usuario_id,
             i.created_at as alta,
             i.deleted_at as baja,
             i.tramos_afuera as afuera
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
         and public.inscripcion_cubre_el_instante(ins.alta, ins.baja, ins.afuera, j.inicio)
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
  'Vista 32, HU-REP-001 (0060, backend-supabase#95; la ciudad por el historial de zonas desde 0106, #141; sin los huecos de la inscripción desde 0197, #162): horas trabajadas por período (p_agrupar = '
  'dia | semana | mes) × ciudad (la de la zona que tenía el colportor el día de cada jornada, según el historial de zonas; sin zona ese día, ciudad null) × '
  'colportor, con jornadas cerradas de la campaña, y las del período anterior para la tendencia '
  '(el día anterior, el lunes contra el sábado; la semana anterior; el mismo tramo del mes '
  'pasado; lo en curso no se compara salvo el mes a la fecha). El rango sube a períodos completos; '
  'hasta 366 días. Cada colportor cuenta desde el instante de su inscripción en la campaña, hasta su baja y fuera de los huecos en que estuvo afuera (inscripcion_cubre_el_instante, 0100). Solo totales: ni clientes, ni ventas, ni importes. Errores: 42501 sin permiso; '
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
      -- Una por colportor de la campaña (unique campania_id, usuario_id), con el instante de su alta,
      -- su baja y sus huecos (tramos_afuera): lo hecho antes del alta, desde la baja o dentro de un
      -- hueco no es de esta campaña (`inscripcion_cubre_el_instante()`, 0100). La ciudad no sale de
      -- aquí: sale del historial de zonas, venta por venta (más abajo).
      select i.id as inscripcion_id,
             i.usuario_id,
             i.created_at as alta,
             i.deleted_at as baja,
             i.tramos_afuera as afuera
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
         and public.inscripcion_cubre_el_instante(ins.alta, ins.baja, ins.afuera, x.cuando)
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
  'Vista 32, HU-REP-002 (0061, backend-supabase#96; la ciudad por el historial de zonas desde 0106, #141; sin los huecos de la inscripción desde 0197, #162): ventas (cantidad y monto en centavos) y '
  'presentaciones (visitas VENTA o ENTREVISTA) por período (p_agrupar = dia | semana | mes) × '
  'ciudad (la de la zona que tenía el colportor el día de cada venta o visita, según el historial de zonas; sin zona ese día, ciudad null) × colportor, de la '
  'campaña (desde el instante en que se inscribió en ella, hasta su baja y fuera de los huecos en que estuvo afuera, inscripcion_cubre_el_instante de la 0100), y lo del período anterior para la '
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
    -- = sin zona asignada. La actividad que cuenta (jornadas, ventas y presentaciones) es la que
    -- `inscripcion_cubre_el_instante()` (0100) deja dentro: desde el alta, antes de la baja y fuera
    -- de los huecos (`afuera`). Un día entero dentro de un hueco no es de esa inscripción: no figura.
    select i.usuario_id, i.deleted_at as baja, i.created_at as inscripto_at,
           i.tramos_afuera as afuera,
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
       and not exists (select 1 from unnest(i.tramos_afuera) t
                        where t @> tstzrange(v_desde, v_hasta, '[)'))
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
       and public.inscripcion_cubre_el_instante(ins.inscripto_at, ins.baja, ins.afuera, j.inicio)
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
       and public.inscripcion_cubre_el_instante(ins.inscripto_at, ins.baja, ins.afuera, v.fecha)
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
       and public.inscripcion_cubre_el_instante(ins.inscripto_at, ins.baja, ins.afuera, vi.fecha)
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
  'Vista 31 (Inicio), HU-CAM-008 (0054, 0055, 0106 y 0197, backend-supabase#94, #141 y #162): el día (p_fecha, hoy si es null; '
  'no puede ser futuro) de la campaña en un jsonb: total, ciudades (cada una con sus cifras y sus '
  'colportores: estado EN_JORNADA | SIN_CERRAR | FINALIZADA | SIN_INICIAR, horas, presentaciones = visitas '
  'VENTA o ENTREVISTA, ventas, monto en centavos y ultimo_push_at), sin_zona (fuera de las '
  'cifras, con inscripcion_de_baja e inscripto_at = cuándo se inscribió) y pendientes (vacío hasta V2). La ciudad es la de la zona que tenía el colportor ese día, según el historial de zonas (0106, #141: la última si lo cambiaron de zona ese día); los colportores son los de las inscripciones '
  'vigentes ese día (no figura quien estuvo afuera el día entero), y lo que cuenta de cada uno es lo que cae dentro de su inscripción: desde el alta, antes de la baja y fuera de los huecos (0197, #162). Solo '
  'totales: ni clientes, ni ubicaciones, ni talonarios. Errores: 42501 sin permiso; CZ001 '
  'campaña inexistente; 22023 fecha futura. Una campaña terminada se lee.';
