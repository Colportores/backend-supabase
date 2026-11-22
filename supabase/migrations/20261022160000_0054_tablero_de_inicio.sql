-- ============================================================================
-- 0054 · Tablero de Inicio del panel: horas, presentaciones y ventas del día por ciudad y
--        colportor (backend-supabase#94, HU-CAM-008, HU-VIS-005, vista 31 «Inicio», C1/C2)
--
-- Origen: cambio de requisitos del 21/10 (reunión del 05/10, docs#69). La vista 31 muestra «cómo
-- está mi gente hoy»: la lista de ciudades con sus cifras del día y, a la derecha, la ciudad
-- elegida con sus colportores (estado, horas, presentaciones, ventas, monto y «últimos datos»).
-- Los clientes no hacen `select` sobre tablas (ADR-013): hace falta una RPC de lectura.
--
--   tablero_de_inicio(p_campania_id uuid, p_fecha date default null) -> jsonb
--
-- Es una sola llamada con todo el día: elegir otra ciudad o «Todo el departamento» no vuelve al
-- servidor, y el panel puede repetirla cada tanto para «Actualizado 10:40».
--
-- ## Qué devuelve (jsonb, siempre con estas claves)
--
--   fecha            el día que se mira (día de Montevideo): p_fecha, o hoy si es null.
--   es_hoy           true si ese día es hoy en Montevideo.
--   calculado_a      el momento en que se calculó (para «Actualizado 10:40» y para «hace 12 min»
--                    sin depender del reloj del navegador).
--   total            lo de todas las ciudades: cantidad_colportores, en_jornada, horas,
--                    presentaciones, ventas, monto_total.
--   ciudades         una por cada ciudad VIVA de la campaña, aunque no tenga colportores (la
--                    lista de la izquierda las muestra todas), por nombre:
--                      ciudad_id, nombre, cantidad_colportores, en_jornada, horas,
--                      presentaciones, ventas, monto_total, y
--                      colportores: [ {colportor_id, nombre, apellido, estado, horas,
--                                      presentaciones, ventas, monto_total, ultimo_push_at} ]
--                    por apellido, nombre.
--   sin_zona         los colportores inscriptos SIN zona asignada (o con la zona, o la ciudad de
--                    la zona, dada de baja): {colportor_id, nombre, apellido, estado,
--                    ultimo_push_at}. NO entran en ninguna cifra ni en ninguna ciudad hasta que
--                    tengan una zona (HU-CAM-008): se cuentan aparte, y de ahí sale la tarjeta
--                    «Colportora sin zona asignada» de Pendientes de acción.
--   pendientes       SIEMPRE [] por ahora: los tickets de depósito por validar y los pedidos de
--                    libros por autorizar son V2 (HU-COB-008, HU-STK-003). La clave existe para
--                    que el panel no cambie cuando se conecten.
--
-- ## Cada cifra
--
--   estado           'EN_JORNADA' (tiene una jornada abierta que empezó ese día, y ese día es
--                    hoy), 'FINALIZADA' (tuvo jornada ese día y no queda ninguna abierta) o
--                    'SIN_INICIAR' (no tuvo jornada ese día). Se decide solo con la jornada,
--                    nunca con las ventas: un colportor con ventas sin jornada subida figura
--                    'SIN_INICIAR' y sus cifras SÍ salen (el panel las muestra con guion solo
--                    cuando son cero, como dice el diseño).
--   horas            suma de (fin - inicio) de sus jornadas de ese día, en horas con 2 decimales.
--                    La jornada ABIERTA de hoy suma hasta ahora (el diseño muestra horas de quien
--                    está «En jornada»). Una jornada abierta de un día anterior suma 0: nada
--                    inventa un `fin` (HU-JOR-002). La de la ciudad es la suma de las de sus
--                    colportores YA redondeadas, así la columna cierra con su total.
--   presentaciones   visitas con la entrevista hecha (HU-VIS-005, C1): tipo_resultado VENTA o
--                    ENTREVISTA. NO_CONTESTO no cuenta. RECHAZO tampoco, de forma PROVISORIA
--                    (supuesto S62 de Cristian; es agregar 'RECHAZO' a `c_presentacion` de abajo
--                    y a pgTAP 0060, igual que en 0045). La cobranza no es una visita de la nube.
--   ventas           cuántas ventas (filas vivas de `venta`) hizo ese día.
--   monto_total      su suma, en CENTAVOS (bigint), como se guarda; el panel formatea «$U 4.350».
--                    Es lo vendido, no lo cobrado ni lo depositado (eso es de Cuentas).
--   ultimo_push_at   usuario.ultimo_push_at (0053): cuándo el servidor recibió el último
--                    sync_push de su teléfono; null si nunca llegó uno («sin datos»). Es solo
--                    visual: sin umbral ni alerta.
--
-- ## Qué cuenta, y quién aparece
--
--   · Aparecen los colportores con la inscripción VIVA en la campaña. Uno dado de baja ya no
--     figura (ni ese día ni los anteriores: la baja lo deja sin zona y sin ciudad donde
--     ponerlo); lo suyo sigue en los reportes (0044/0045, que cuentan hasta la baja).
--   · El día es el de Montevideo (sin depender de la zona horaria de la sesión). Una jornada que
--     cruza la medianoche cuenta entera en el día en que empezó.
--   · La ciudad de un colportor es la de su ZONA ACTUAL (mismo criterio de 0044/0045), incluso
--     al mirar un día anterior.
--   · Solo cuenta lo de los días entre fecha_inicio y fecha_fin de la campaña (ambos incluidos):
--     un día fuera de ella da todas las cifras en cero y a todos 'SIN_INICIAR' (no es un error).
--   · Las jornadas, visitas y ventas dadas de baja (deleted_at) no cuentan.
--   · Una campaña terminada se lee (se pueden repasar sus últimos días).
--   · No hay datos de clientes: ni personas visitadas, ni espacios, ni ubicaciones, ni talonarios,
--     ni emails. Columnas explícitas, nunca `to_jsonb` de una fila.
--
-- ## Permisos y errores
--
-- Mismo permiso que las lecturas de la vista 24 (0033) y que 0044/0045, y lo PRIMERO que se
-- comprueba:
--   · Sin JWT, colportor, sin rol, rol vencido o coordinador de otra campaña: 42501. ADMIN:
--     cualquier campaña.
--   · Campaña inexistente o dada de baja: CZ001.
--   · p_fecha posterior a hoy (Montevideo): 22023 («Hoy y los días anteriores»).
--   · SECURITY DEFINER con search_path vacío (el coordinador no lee `jornada`, `visita` ni `venta`
--     ajenas por RLS; la función devuelve solo totales). VOLATILE (llama a
--     lanzar_motivo_mapa()): supabase-js la manda por POST. EXECUTE solo para `authenticated`.
--
-- ## Para otros repos
--
--   · front-coordinadores-web (vista 31, Inicio): POST /rest/v1/rpc/tablero_de_inicio con
--     p_campania_id y, para otro día, p_fecha. El filtro departamento -> ciudad usa
--     `ciudades_de_campania().departamento` (backend-supabase#92, 0048 en el PR #120) por el
--     `ciudad_id` de cada ciudad: esta lectura NO trae el departamento para no depender de un
--     PR que todavía no está en develop; cuando llegue, se suma con un `create or replace`.
--     «Todo el departamento» y la elección de la ciudad se resuelven en el panel con esta misma
--     respuesta. Los textos («hace 12 min», «Sin iniciar») y el «% de la meta» son del panel
--     (la meta no está en esta lectura: ver los pendientes del PR).
--   · Depende de que las jornadas, las visitas y las ventas suban a la nube (backend-supabase#53
--     y el sync de la app): hasta entonces todos figuran 'SIN_INICIAR' con las cifras en cero, que
--     no es un error.
--   · No toca el sync: no hay entidad nueva ni cambia ninguna firma de la app móvil.
--
-- Forward-only: no se edita una vez aplicada.
-- ============================================================================

create function public.tablero_de_inicio(p_campania_id uuid, p_fecha date default null)
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
    -- Una por colportor de la campaña con la inscripción viva (unique campania_id, usuario_id).
    -- La ciudad sale de la zona actual; una zona o una ciudad de campaña dadas de baja no
    -- cuentan (ciudad_id null = sin zona asignada).
    select i.usuario_id, ci.ciudad_id
      from public.campania_colportor i
      left join public.zona z
             on z.id = i.zona_id and z.deleted_at is null
      left join public.campania_ciudad ci
             on ci.id = z.campania_ciudad_id and ci.deleted_at is null
     where i.campania_id = p_campania_id
       and i.deleted_at is null
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
           usr.nombre,
           usr.apellido,
           usr.ultimo_push_at,
           case
             when coalesce(j.abierta, false) and v_dia = v_hoy then 'EN_JORNADA'
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
  'Vista 31 (Inicio), HU-CAM-008 (0054, backend-supabase#94): el día (p_fecha, hoy si es null; '
  'no puede ser futuro) de la campaña en un jsonb: total, ciudades (cada una con sus cifras y sus '
  'colportores: estado EN_JORNADA | FINALIZADA | SIN_INICIAR, horas, presentaciones = visitas '
  'VENTA o ENTREVISTA, ventas, monto en centavos y ultimo_push_at), sin_zona (fuera de las '
  'cifras) y pendientes (vacío hasta V2). La ciudad es la de la zona actual del colportor. Solo '
  'totales: ni clientes, ni ubicaciones, ni talonarios. Errores: 42501 sin permiso; CZ001 '
  'campaña inexistente; 22023 fecha futura. Una campaña terminada se lee.';

-- `authenticated` y `service_role` también en el revoke: en una base creada desde cero los
-- default privileges de la imagen les dan EXECUTE sobre cada función nueva de public (0008).
revoke all on function public.tablero_de_inicio(uuid, date)
  from public, anon, authenticated, service_role;
grant execute on function public.tablero_de_inicio(uuid, date) to authenticated;
