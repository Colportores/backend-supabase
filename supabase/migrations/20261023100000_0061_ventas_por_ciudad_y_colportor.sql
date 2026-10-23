-- ============================================================================
-- 0061 · Ventas y presentaciones por ciudad y colportor, por día, semana o mes, con la
--        tendencia contra el período anterior (backend-supabase#96, HU-REP-002, vista 32)
--
-- Origen: cambio de requisitos del 21/10 (reunión del 05/10, docs#69, C3 y C15): el reporte de
-- ventas se agrupa por ciudad, suma las presentaciones del equipo y, en el diseño de la vista 32,
-- trae el selector Días / Semanas / Meses con la comparación contra el período anterior y una
-- columna «% por cobrar» que se conecta en V2: la lectura devuelve lo COBRADO (decisión del
-- orquestador del 21/10, origen front-coordinadores-web#73 P3) y el panel calcula el % del período.
--
--   ventas_por_ciudad_y_colportor(p_campania_id, p_desde, p_hasta, p_agrupar,
--                                 p_ciudad_id, p_colportor_ids)
--     -> (periodo_inicio, periodo_fin, ciudad_id, ciudad_nombre, colportor_id, nombre, apellido,
--         ventas, monto_total, presentaciones, en_curso,
--         ventas_anterior, monto_anterior, presentaciones_anterior,
--         cobrado, cobrado_anterior)
--
-- Es la hermana de horas_por_ciudad_y_colportor() (#95): mismos parámetros, mismo permiso,
-- mismas reglas de período, de rango y de comparación, y la misma ciudad del colportor. Lo único
-- que cambia es lo que se suma.
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
--                                  (decisión de Cristian del 21/10, «Ciudad colp.»). Sin zona (o
--                                  con la zona dada de baja, o la inscripción dada de baja):
--                                  ambos null, UNA sola vez, no repetido en cada ciudad:
--                                  repetirlo inflaría los totales.
--   colportor_id, nombre, apellido el colportor (sin email ni nada más de la persona).
--   ventas                         cuántas ventas hizo (filas de `venta` vivas del período). Es
--                                  la cantidad de VENTAS, no de unidades ni de libros (esos son
--                                  otro KPI de la HU: «libros bonificables»).
--   monto_total                    la suma de `venta.monto_total`, en CENTAVOS (bigint), como se
--                                  guarda; el panel formatea. Es lo vendido, no lo cobrado.
--   presentaciones                 cuántas visitas con la entrevista hecha (HU-VIS-005, decisión
--                                  de Cristian del 21/10, C1): tipo_resultado VENTA o ENTREVISTA.
--                                  NO_CONTESTO no cuenta (nadie atendió). RECHAZO tampoco, de
--                                  forma PROVISORIA: confirmarlo es el supuesto S62 de la HU,
--                                  de Cristian; si cuenta, es agregar 'RECHAZO' a la lista
--                                  `c_presentacion` de abajo y a pgTAP 0065. La cobranza no es
--                                  una visita de la nube (no tiene tipo_resultado COBRANZA).
--   en_curso                       el período incluye hoy (el día de Montevideo).
--   ventas_anterior, monto_anterior, presentaciones_anterior
--                                  lo mismo del período contra el que se compara (abajo). null
--                                  cuando ese período no se compara.
--   cobrado,                       lo cobrado del período y del período contra el que se compara,
--   cobrado_anterior               en CENTAVOS (bigint), como monto_total: SIEMPRE null por ahora
--                                  («sin conectar»). Depende de los cobros y de Cuentas
--                                  (HU-COB-005, HU-CTA-005), que son V2 (se conectan después del
--                                  20/11, plan-sprints §5). Se devuelve el cobrado y NO el % hecho
--                                  porque un porcentaje por fila no se puede sumar por ciudad ni
--                                  reagrupar en el navegador: el panel suma monto y cobrado de todo
--                                  el período y saca el % por cobrar de ahí, sin promediar
--                                  porcentajes. Mientras venga null el panel oculta la columna.
--                                  Las columnas existen desde ya con su tipo definitivo: cuando se
--                                  calculen alcanza con un `create or replace` (mismas columnas).

-- Nunca devuelve clientes, personas visitadas, espacios, ubicaciones, medios de pago, cobros ni
-- números de talonario: solo totales (el coordinador ve montos, no clientes). Columnas
-- explícitas, nunca `to_jsonb`.
--
-- ## Período anterior (decidido por el diseño de la vista 32 y por #95)
--
--   · Días: el día anterior; el anterior de un lunes es el sábado (los domingos no se trabaja).
--   · Semanas: la semana anterior, completa.
--   · Meses: el mismo tramo del mes anterior. Un mes terminado se compara con el mes anterior
--     completo; el mes en curso, con los días 1 a N del mes pasado, siendo N el día de hoy.
--   · Lo que está en curso (hoy, la semana en curso) NO se compara: los tres «_anterior» son
--     null. El mes en curso sí, por el tramo de arriba.
--   · Si el período anterior no tiene nada, ventas_anterior = 0, monto_anterior = 0 y
--     presentaciones_anterior = 0: el panel decide si lo muestra como «sin datos» o como una
--     suba. No se distingue «no trabajó» de «trabajó y no vendió»: ambos son 0.
--   · Una fila con ventas = 0 y presentaciones = 0 existe cuando el período anterior sí tiene
--     datos (vendió ayer y hoy nada): hace falta para que la suma de los «_anterior» de una
--     ciudad sea la de verdad. Los períodos futuros no salen.
--
-- ## Qué cuenta
--
--   · De la campaña: solo ventas y visitas de colportores INSCRIPTOS en p_campania_id, y solo
--     las de los días entre fecha_inicio y fecha_fin de la campaña (días de Montevideo, ambos
--     incluidos) y desde el día en que se inscribió en ESTA campaña (el día de Montevideo de
--     `campania_colportor.created_at`; decisión del orquestador del 22/10, la misma regla que 0044
--     y el tablero de Inicio 0054/0055). Una inscripción dada de baja sigue contando lo anterior a
--     la baja (lo vendido no desaparece); lo posterior no.
--     Así, un colportor inscripto en dos campañas cuyas fechas se pisan no cuenta lo mismo en las
--     dos. Queda sin cubrir un caso raro: si dejó la campaña B, trabajó en A y volvió a B, la
--     reactivación conserva el `created_at` original y los días del hueco cuentan en las dos
--     (taparlo exige guardar la fecha de la reactivación, un dato nuevo; queda anotado para Cristian).
--   · El día es el de la `fecha` de la venta o de la visita en America/Montevideo, sin depender
--     de la zona horaria de la sesión (hoy_montevideo(timestamptz), 0024).
--   · No cuentan las dadas de baja (deleted_at). Cada venta y cada visita cuenta para el colportor
--     que la hizo (`colportor_id`), esté en el espacio que esté.
--
-- ## El rango, el tope, el permiso y los errores
--
-- Idénticos a horas_por_ciudad_y_colportor():
--   · p_desde y p_hasta son días (ambos incluidos), redondeados a PERÍODOS COMPLETOS. Tope de
--     366 días ya redondeados: un rango más largo es un error (22023), no se recorta en silencio.
--   · Sin JWT, colportor, sin rol, rol vencido o coordinador de otra campaña: 42501, antes de
--     mirar nada más. ADMIN: cualquier campaña. Campaña inexistente o dada de baja: CZ001. Una
--     campaña terminada se lee (el reporte se pide al cierre). p_agrupar distinto de 'dia' |
--     'semana' | 'mes', una fecha nula, p_desde > p_hasta o más de 366 días: 22023.
--   · SECURITY DEFINER con search_path vacío (el coordinador no lee `venta` ni `visita` ajenas
--     por RLS: la función devuelve solo totales). VOLATILE (llama a motivo_mapa_de_campania() y
--     lanzar_motivo_mapa()): supabase-js la manda por POST. EXECUTE solo para `authenticated`.
--
-- ## Para otros repos
--
--   · front-coordinadores-web (vista 32, Reportes): POST /rest/v1/rpc/ventas_por_ciudad_y_colportor
--     con p_campania_id, p_desde, p_hasta, p_agrupar ('dia' | 'semana' | 'mes') y, si filtra,
--     p_ciudad_id y p_colportor_ids. Las cifras con tendencia («▲ 10 %») salen de ventas /
--     presentaciones y sus «_anterior», sumando las filas que se muestran. El total de la
--     campaña es la suma de todas las filas del período. El % por cobrar es sum(cobrado) /
--     sum(monto_total) de las filas que se muestran (VentasDelDia.cobrado: number | null en el
--     contrato del panel); mientras `cobrado` sea null en todas las filas, la columna se oculta.
--   · docs-organizacion: el filtro «departamento → ciudad» no se puede servir todavía (hay que
--     filtrar por ciudad: public.ciudad no tiene `departamento`, ver el pendiente de 0033). La
--     «comparativa contra el promedio del grupo» y el «% rechazo / % no contesta» de la HU no
--     están acá: no los pide el issue; el promedio lo saca el panel de estas mismas filas.
--   · Depende de que las ventas y las visitas suban a la nube (sync, backend-supabase#53):
--     hasta entonces la lectura devuelve la lista vacía, que no es un error.
--   · No toca el sync: no hay entidad nueva ni cambia ninguna firma de la app móvil.
--
-- Forward-only: no se edita una vez aplicada.
-- ============================================================================

create function public.ventas_por_ciudad_y_colportor(p_campania_id uuid, p_desde date, p_hasta date,
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
      -- Una por colportor de la campaña (unique campania_id, usuario_id). La ciudad sale de la
      -- zona actual; una zona o una ciudad de campaña dadas de baja no cuentan. Sin ciudad: el
      -- uuid cero, para poder unir sin `is not distinct from`. `desde_dia`: el día en que se
      -- inscribió en esta campaña; antes de eso lo hecho no es de ella.
      select i.usuario_id,
             i.deleted_at as baja,
             public.hoy_montevideo(i.created_at) as desde_dia,
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
      -- Lo hecho por colportor y día de Montevideo: cada venta suma 1 venta y su monto; cada
      -- visita con la entrevista hecha suma 1 presentación.
      select ins.ciudad_k,
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
       where x.cuando >= (v_desde_leer::timestamp at time zone 'America/Montevideo')
         and x.cuando <  ((v_fin + 1)::timestamp at time zone 'America/Montevideo')
         and x.dia >= v_campania.fecha_inicio
         and x.dia <= coalesce(v_campania.fecha_fin, 'infinity'::date)
         and x.dia >= ins.desde_dia
         and (ins.baja is null or x.cuando < ins.baja)
         and (p_ciudad_id is null
              or (ins.ciudad_k = p_ciudad_id and p_ciudad_id <> c_sin_ciudad))
       group by ins.ciudad_k, ins.usuario_id, x.dia
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
  'Vista 32, HU-REP-002 (0061, backend-supabase#96): ventas (cantidad y monto en centavos) y '
  'presentaciones (visitas VENTA o ENTREVISTA) por período (p_agrupar = dia | semana | mes) × '
  'ciudad (la de la zona actual del colportor; sin zona, ciudad null) × colportor, de la '
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
