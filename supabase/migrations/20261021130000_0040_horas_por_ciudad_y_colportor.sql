-- ============================================================================
-- 0040 · Horas trabajadas por ciudad y colportor, por día, semana o mes, con la tendencia
--        contra el período anterior (backend-supabase#95, HU-REP-001, vista 32)
--
-- Origen: cambio de requisitos del 21/10 (reunión del 05/10, docs#69, C3 y C15): el reporte de
-- horas se agrupa por ciudad y se abre a los colportores, y el diseño de la vista 32 agrega el
-- selector Días / Semanas / Meses y la comparación con el período anterior.
--
--   horas_por_ciudad_y_colportor(p_campania_id, p_desde, p_hasta, p_agrupar,
--                                p_ciudad_id, p_colportor_ids)
--     -> (periodo_inicio, periodo_fin, ciudad_id, ciudad_nombre, colportor_id, nombre, apellido,
--         horas, jornadas, dias_trabajados, jornadas_acompaniadas, en_curso,
--         horas_anterior, jornadas_anterior)
--
-- ## Qué devuelve
--
-- Una fila por período × ciudad × colportor. El panel arma las dos alturas del reporte (la
-- ciudad que se expande a sus colportores) sumando las filas de cada ciudad; no hay filas de
-- subtotal.
--
--   periodo_inicio / periodo_fin   los días (incluidos) del período: el día; lunes a domingo;
--                                  el mes calendario.
--   ciudad_id, ciudad_nombre       la ciudad de la ZONA ACTUAL del colportor en esta campaña
--                                  (decisión de Cristian del 21/10, «Ciudad colp.»: la ciudad de
--                                  un colportor sale de su zona, sin dato nuevo). Sin zona (o con
--                                  la zona dada de baja, o la inscripción dada de baja): ambos
--                                  null, UNA sola vez, no repetido en cada ciudad: repetirlo
--                                  inflaría el total de horas. Ver pendientes del PR.
--   colportor_id, nombre, apellido el colportor (sin email ni nada más de la persona).
--   horas                          suma de (fin - inicio) de sus jornadas CERRADAS del período,
--                                  en horas con 2 decimales. Una jornada sin `fin` no suma
--                                  horas (HU-REP-001) y tampoco cuenta como jornada.
--   jornadas                       cuántas jornadas cerradas. 0 = el colportor no tiene datos de
--                                  ese período (el panel lo muestra con guion y sin tendencia).
--   dias_trabajados                en cuántos días distintos tuvo jornadas (para el promedio
--                                  diario: horas / dias_trabajados).
--   jornadas_acompaniadas          cuántas tienen acompañante (jornada.acompaniante_id).
--   en_curso                       el período incluye hoy (el día de Montevideo).
--   horas_anterior, jornadas_anterior
--                                  lo mismo del período contra el que se compara (abajo).
--                                  null cuando ese período no se compara.
--
-- Nunca devuelve clientes, personas visitadas, ventas, importes, ubicaciones ni la hora de
-- inicio y fin de cada jornada: solo totales. Columnas explícitas, nunca `to_jsonb`.
--
-- ## Período anterior (decidido por el diseño de la vista 32 y el issue)
--
--   · Días: el día anterior; el anterior de un lunes es el sábado (los domingos no se trabaja).
--   · Semanas: la semana anterior, completa.
--   · Meses: el mismo tramo del mes anterior. Un mes terminado se compara con el mes anterior
--     completo; el mes en curso, con los días 1 a N del mes pasado, siendo N el día de hoy (así
--     el mes a la fecha no sale siempre en baja).
--   · Lo que está en curso (hoy, la semana en curso) NO se compara: horas_anterior y
--     jornadas_anterior son null. El mes en curso sí, por el tramo de arriba.
--   · Si el período anterior no tiene jornadas, horas_anterior es 0.00 y jornadas_anterior 0:
--     el panel decide si lo muestra como «sin datos» (jornadas_anterior = 0) o como una suba.
--   · Una fila con `jornadas = 0` existe cuando el período anterior sí tiene datos (el colportor
--     trabajó ayer y hoy no): se necesita para que la suma de horas_anterior de una ciudad sea
--     la de verdad. Los períodos futuros no salen.
--
-- ## Qué cuenta como una jornada del período
--
--   · De la campaña: solo jornadas de colportores INSCRIPTOS en p_campania_id, y solo las que
--     arrancan entre fecha_inicio y fecha_fin de la campaña (días de Montevideo, ambos
--     incluidos). Las horas de otra campaña del mismo colportor no se mezclan. Una inscripción
--     dada de baja sigue contando las jornadas anteriores a la baja (para liquidar viáticos, lo
--     trabajado no desaparece); las posteriores no.
--   · El día de una jornada es el de su `inicio` en America/Montevideo, sin depender de la zona
--     horaria de la sesión (hoy_montevideo(timestamptz), 0024). Una jornada que cruza la
--     medianoche cuenta entera en el día en que empezó. Ver pendientes del PR.
--   · No cuentan las dadas de baja (deleted_at) ni las abiertas (sin `fin`).
--
-- ## El rango
--
--   · p_desde y p_hasta son días (ambos incluidos). El rango se redondea a PERÍODOS COMPLETOS:
--     p_desde sube al inicio de su semana o de su mes y p_hasta baja al final de la suya; así
--     una semana o un mes de la punta nunca sale cortado, que se compararía mal. En días no se
--     redondea nada. Ver pendientes del PR.
--   · Tope: 366 días ya redondeados. Un rango más largo es un error (22023), no se recorta en
--     silencio: el panel creería que tiene el reporte completo.
--     Peor caso medido (200 colportores × 365 días en días, 72 mil filas): ~1,6 s.
--
-- ## Modelo de permisos
--
-- Mismo permiso que las lecturas de la vista 24 (0033): lo PRIMERO. Distinto en una cosa: un
-- reporte de horas también se pide DESPUÉS de que la campaña terminó (es cuando se liquidan los
-- viáticos), así que una campaña terminada se lee. Ver pendientes del PR.
--
--   · Sin JWT, colportor, sin rol, rol vencido o coordinador de otra campaña: 42501. Los
--     colportores no llaman y no averiguan qué campañas hay. ADMIN: cualquier campaña.
--   · Campaña inexistente o dada de baja: CZ001.
--   · p_agrupar distinto de 'dia' | 'semana' | 'mes', una fecha nula, p_desde > p_hasta o más de
--     366 días: 22023.
--   · SECURITY DEFINER con search_path vacío: el coordinador no lee `jornada` (su RLS es por
--     colportor_id = auth.uid()); la función devuelve solo totales.
--   · VOLATILE (llama a motivo_mapa_de_campania() y lanzar_motivo_mapa()): supabase-js la manda
--     por POST.
--   · EXECUTE solo para `authenticated`.
--
-- ## Para otros repos
--
--   · front-coordinadores-web (vista 32, Reportes): POST /rest/v1/rpc/horas_por_ciudad_y_colportor
--     con p_campania_id, p_desde, p_hasta, p_agrupar ('dia' | 'semana' | 'mes') y, si filtra,
--     p_ciudad_id y p_colportor_ids. Las cifras con tendencia («▲ 10 %») salen de horas y
--     horas_anterior de la suma de las filas que se muestran.
--   · docs-organizacion: HU-REP-001 tiene solo la tendencia semanal; el selector Días / Semanas /
--     Meses y la comparación con el período anterior vienen del diseño de la vista 32 (hay que
--     llevarlos a la HU si se aceptan). El filtro «departamento → ciudad» no se puede servir
--     todavía: public.ciudad no tiene `departamento` (ver el pendiente de provincia de 0033).
--   · Depende de que las jornadas suban a la nube (backend-supabase#53): hasta entonces la
--     lectura devuelve la lista vacía, que no es un error.
--   · No toca el sync: no hay entidad nueva ni cambia ninguna firma de la app móvil.
--
-- Forward-only: no se edita una vez aplicada.
-- ============================================================================

create function public.horas_por_ciudad_y_colportor(p_campania_id uuid, p_desde date, p_hasta date,
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
      -- Una por colportor de la campaña (unique campania_id, usuario_id). La ciudad sale de la
      -- zona actual; una zona o una ciudad de campaña dadas de baja no cuentan. Sin ciudad: el
      -- uuid cero, para poder unir sin `is not distinct from`.
      select i.usuario_id,
             i.deleted_at as baja,
             coalesce(ci.ciudad_id, c_sin_ciudad) as ciudad_k
        from public.campania_colportor i
        left join public.zona z
               on z.id = i.zona_id and z.deleted_at is null and i.deleted_at is null
        left join public.campania_ciudad ci
               on ci.id = z.campania_ciudad_id and ci.deleted_at is null
       where i.campania_id = p_campania_id
         and (p_colportor_ids is null or i.usuario_id = any (p_colportor_ids))
    ),
    diario as materialized (
      -- Lo trabajado por colportor y día de Montevideo.
      select ins.ciudad_k,
             ins.usuario_id,
             public.hoy_montevideo(j.inicio) as dia,
             count(*)::integer as jornadas,
             (count(*) filter (where j.acompaniante_id is not null))::integer as acompaniadas,
             sum(extract(epoch from (j.fin - j.inicio)))::numeric as segundos
        from inscripcion ins
        join public.jornada j on j.colportor_id = ins.usuario_id
       where j.deleted_at is null
         and j.fin is not null
         and j.inicio >= (v_desde_leer::timestamp at time zone 'America/Montevideo')
         and j.inicio <  ((v_fin + 1)::timestamp at time zone 'America/Montevideo')
         and public.hoy_montevideo(j.inicio) >= v_campania.fecha_inicio
         and public.hoy_montevideo(j.inicio) <= coalesce(v_campania.fecha_fin, 'infinity'::date)
         and (ins.baja is null or j.inicio < ins.baja)
         and (p_ciudad_id is null
              or (ins.ciudad_k = p_ciudad_id and p_ciudad_id <> c_sin_ciudad))
       group by ins.ciudad_k, ins.usuario_id, public.hoy_montevideo(j.inicio)
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
  'Vista 32, HU-REP-001 (0040, backend-supabase#95): horas trabajadas por período (p_agrupar = '
  'dia | semana | mes) × ciudad (la de la zona actual del colportor; sin zona, ciudad null) × '
  'colportor, con jornadas cerradas de la campaña, y las del período anterior para la tendencia '
  '(el día anterior, el lunes contra el sábado; la semana anterior; el mismo tramo del mes '
  'pasado; lo en curso no se compara salvo el mes a la fecha). El rango sube a períodos completos; '
  'hasta 366 días. Solo totales: ni clientes, ni ventas, ni importes. Errores: 42501 sin permiso; '
  'CZ001 campaña inexistente; 22023 agrupación, fechas o rango inválidos. Una campaña terminada '
  'se lee.';

-- `authenticated` y `service_role` también en el revoke: en una base creada desde cero los
-- default privileges de la imagen les dan EXECUTE sobre cada función nueva de public (0008).
revoke all on function public.horas_por_ciudad_y_colportor(uuid, date, date, text, uuid, uuid[])
  from public, anon, authenticated, service_role;
grant execute on function public.horas_por_ciudad_y_colportor(uuid, date, date, text, uuid, uuid[])
  to authenticated;
