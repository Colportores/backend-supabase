-- ============================================================================
-- 0137 · Stock por ciudad: «por cobrar» en proporción a lo que falta cobrar y una columna «devueltos»
--        (backend-supabase#201, seguimiento de #101 / 0111, HU-STK-010, vista 34 «Stock por Ciudad»;
--        decisiones de Cristian del 27/10, «Por cobrar» y «Devol. stock», y por regla R4 del agente de decisiones)
--
-- Dos cambios en la lectura `stock_por_ciudad(p_campania_id)`; el resto (permiso, errores, qué ventas y qué
-- productos cuentan, la ciudad de la zona actual, `de_baja`, `ultimo_dato_at`) es el de 0111.
--
--   1. «Por cobrar» (decisión: proporcional). 0111 contaba TODAS las unidades entregadas de una venta con saldo
--      (una venta de 3 libros cobrada a la mitad contaba 3). Ahora cuenta cada línea entregada en proporción a lo
--      que falta cobrar de la venta:
--
--          por_cobrar de la línea = cantidad × saldo ÷ monto_total        (saldo = monto_total − cobros vivos
--                                                                          y no anulados, 0072)
--
--      REDONDEADO HACIA ARRIBA (regla R4 del 26/10, aplicada por el agente de decisiones el 27/10): nunca
--      subestima lo que falta cobrar y un libro no se parte. 3 libros cobrados a la mitad cuentan 2 (1,5 -> 2);
--      3 libros con un tercio por cobrar cuentan 1; 3 libros sin nada cobrado cuentan 3. Sin saldo (cobrada en su
--      punto o pagada de más), o con un total en cero, cuenta 0. Se redondea por línea de entrega (un producto de
--      una venta), y después se suma por colportor y producto: la suma de los redondeos nunca queda por debajo
--      de lo exacto. Solo cuentan las unidades ya entregadas, como antes.
--
--   2. «Devol. stock» (decisión: columna `devueltos`). La lectura suma `devueltos`: las unidades que los clientes
--      devolvieron de ese producto (`devolucion.productos_devueltos`, devoluciones vivas), de las ventas que
--      cuentan en la campaña con las mismas reglas que las entregas. `entregados` NO cambia: la devolución no lo
--      descuenta. El panel muestra «Devol. stock» aparte (front-coordinadores-web#109). Una devolución dada de
--      baja (anulada) no cuenta. Un producto con solo devoluciones en la campaña también sale (tiene
--      movimiento).
--
-- Cambia el tipo de retorno (suma `devueltos`): se hace drop + create y se vuelven a dar los permisos (EXECUTE solo
-- para `authenticated`), como en 0127. Sigue siendo SECURITY DEFINER, VOLATILE y de search_path vacío. Solo
-- cantidades: ni plata, ni clientes.
--
--   stock_por_ciudad(p_campania_id)
--     -> (ciudad_id, ciudad_nombre, departamento,
--         colportor_id, nombre, apellido, de_baja, ultimo_dato_at,
--         producto_id, producto_nombre, producto_tipo,
--         tiene, por_entregar, entregados, devueltos, por_cobrar)
--
-- ## Para otros repos
--
--   · front-coordinadores-web (vista 34, #109): POST /rest/v1/rpc/stock_por_ciudad; de cada fila sale
--     `existencias.devueltos` (nuevo) junto a `tiene`, `porEntregar`, `entregados` y `porCobrar`.
--   · docs-organizacion: HU-STK-010 y la vista 34: docs-organizacion#113.
--
-- Forward-only: esta migración no se edita una vez aplicada.
-- ============================================================================

drop function public.stock_por_ciudad(uuid);

create function public.stock_por_ciudad(p_campania_id uuid)
returns table (ciudad_id uuid, ciudad_nombre text, departamento text,
               colportor_id uuid, nombre text, apellido text, de_baja boolean,
               ultimo_dato_at timestamptz,
               producto_id uuid, producto_nombre text, producto_tipo text,
               tiene integer, por_entregar integer, entregados integer, devueltos integer, por_cobrar integer)
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_motivo    text;
  v_campania  public.campania;
begin
  -- El permiso, antes de mirar nada más. Una campaña terminada se lee; lo demás es lo de siempre.
  v_motivo := public.motivo_mapa_de_campania(p_campania_id);
  if v_motivo = 'SIN_PERMISO' then
    raise exception 'Solo el coordinador de la campaña o un administrador puede ver su stock. Entrá con la cuenta del coordinador de esta campaña.'
      using errcode = 'insufficient_privilege';
  end if;
  if v_motivo is distinct from 'CAMPANIA_TERMINADA' then
    perform public.lanzar_motivo_mapa(v_motivo);
  end if;

  select * into v_campania from public.campania c where c.id = p_campania_id;

  return query
    with inscripcion as materialized (
      -- Una por colportor de la campaña (unique campania_id, usuario_id). La ciudad sale de la zona
      -- actual; una zona, una ciudad de campaña o una inscripción dadas de baja no cuentan.
      select i.usuario_id,
             i.deleted_at as baja,
             public.hoy_montevideo(i.created_at) as desde_dia,
             ci.ciudad_id as ciudad_k
        from public.campania_colportor i
        left join public.zona z
               on z.id = i.zona_id and z.deleted_at is null and i.deleted_at is null
        left join public.campania_ciudad ci
               on ci.id = z.campania_ciudad_id and ci.deleted_at is null
       where i.campania_id = p_campania_id
    ),
    en_mano as (
      select ins.usuario_id as u_id, s.producto_id as p_id, s.cantidad_disponible as tiene
        from inscripcion ins
        join public.stock s on s.usuario_id = ins.usuario_id and s.deleted_at is null
    ),
    ventas_de_la_campania as materialized (
      -- Las ventas que cuentan (las de Reportes, 0061) con lo que falta cobrar de cada una. El saldo no cuenta
      -- los cobros anulados (0072) y resta lo que el cliente devolvió, a precio del renglón (ADR-002 efecto 3;
      -- el renglón de un combo, repartido entre sus unidades), sin bajar de cero.
      select ins.usuario_id as u_id, v.id as venta_id, v.monto_total::bigint as total, sd.saldo
        from inscripcion ins
        join public.venta v on v.colportor_id = ins.usuario_id and v.deleted_at is null
       cross join lateral (
         select greatest(
                  v.monto_total::bigint
                  - coalesce((select sum(co.monto) from public.cobranza co
                               where co.venta_id = v.id and co.deleted_at is null and co.anulado_at is null), 0)::bigint
                  - coalesce((select sum(((x ->> 'cantidad')::bigint * i.precio_unitario::bigint)
                                         / case when i.producto_id is null
                                                then greatest((select sum((c ->> 'cantidad')::bigint)
                                                                from jsonb_array_elements(coalesce(i.componentes, '[]'::jsonb)) c), 1)
                                                else 1 end)
                                from public.devolucion d
                               cross join lateral jsonb_array_elements(d.productos_devueltos) x
                                join public.venta_item i on i.id = (x ->> 'venta_item_id')::uuid
                               where d.venta_id = v.id and d.deleted_at is null), 0)::bigint,
                  0) as saldo
       ) sd
       where public.hoy_montevideo(v.fecha) >= v_campania.fecha_inicio
         and public.hoy_montevideo(v.fecha) <= coalesce(v_campania.fecha_fin, 'infinity'::date)
         and public.hoy_montevideo(v.fecha) >= ins.desde_dia
         and (ins.baja is null or v.fecha < ins.baja)
    ),
    movimiento as (
      -- Las entregas de esas ventas, por colportor y producto. «Por cobrar» cuenta cada línea ENTREGADA en
      -- proporción a lo que falta cobrar de su venta, redondeado hacia arriba (R4): ceil(cantidad × saldo ÷ total).
      select vc.u_id, e.producto_id as p_id,
             (sum(e.cantidad) filter (where e.pendiente))::integer as por_entregar,
             (sum(e.cantidad) filter (where not e.pendiente))::integer as entregados,
             (sum(((e.cantidad::bigint * least(vc.saldo, vc.total)) + vc.total - 1) / vc.total)
                filter (where not e.pendiente and vc.saldo > 0 and vc.total > 0))::integer as por_cobrar
        from ventas_de_la_campania vc
        join public.entrega e on e.venta_id = vc.venta_id and e.deleted_at is null
       group by vc.u_id, e.producto_id
    ),
    lo_devuelto as (
      -- Las unidades que los clientes devolvieron de esas ventas (devoluciones vivas), por colportor y producto.
      select vc.u_id, (x ->> 'producto_id')::uuid as p_id,
             (sum((x ->> 'cantidad')::bigint))::integer as devueltos
        from ventas_de_la_campania vc
        join public.devolucion d on d.venta_id = vc.venta_id and d.deleted_at is null
       cross join lateral jsonb_array_elements(d.productos_devueltos) x
       group by vc.u_id, (x ->> 'producto_id')::uuid
    ),
    base as (
      select coalesce(m.u_id, h.u_id, dv.u_id) as u_id,
             coalesce(m.p_id, h.p_id, dv.p_id) as p_id,
             h.tiene,
             m.por_entregar, m.entregados, dv.devueltos, m.por_cobrar
        from movimiento m
        full join en_mano h on h.u_id = m.u_id and h.p_id = m.p_id
        full join lo_devuelto dv on dv.u_id = coalesce(m.u_id, h.u_id) and dv.p_id = coalesce(m.p_id, h.p_id)
    ),
    productos as (
      -- Los que tienen movimiento en la campaña; uno dado de baja solo si queda algo de él.
      select b.p_id
        from base b
        join public.producto pr on pr.id = b.p_id
       group by b.p_id, pr.deleted_at
      having pr.deleted_at is null
          or coalesce(sum(b.tiene), 0) <> 0
          or coalesce(sum(b.por_entregar), 0) <> 0
    )
    select ciu.id,
           ciu.nombre,
           ciu.departamento,
           ins.usuario_id,
           usr.nombre,
           usr.apellido,
           (ins.baja is not null),
           usr.ultimo_push_at,
           pr.id,
           pr.nombre,
           pr.tipo,
           coalesce(b.tiene, 0),
           coalesce(b.por_entregar, 0),
           coalesce(b.entregados, 0),
           coalesce(b.devueltos, 0),
           coalesce(b.por_cobrar, 0)
      from inscripcion ins
      join public.usuario usr on usr.id = ins.usuario_id
      left join public.ciudad ciu on ciu.id = ins.ciudad_k
     cross join productos pd
      join public.producto pr on pr.id = pd.p_id
      left join base b on b.u_id = ins.usuario_id and b.p_id = pd.p_id
     order by ciu.nombre nulls last, usr.apellido, usr.nombre, ins.usuario_id,
              case pr.tipo when 'LIBRO' then 1 when 'REVISTA' then 2 when 'MATERIAL' then 3 else 4 end,
              pr.nombre, pr.id;
end;
$$;

comment on function public.stock_por_ciudad(uuid) is
  'Vista 34, HU-STK-010 (0111, 0137, backend-supabase#101 y #201): una fila por colportor de la campaña × producto '
  'con movimiento en ella: ciudad de su zona actual (sin zona o de baja, ciudad null), si está de baja, cuándo '
  'llegó su último push (ultimo_dato_at, usuario.ultimo_push_at), y en unidades lo que tiene (stock, tal cual, '
  'puede ser negativo), lo por entregar, lo entregado, lo devuelto por los clientes (devueltos) y lo por cobrar: '
  'las unidades entregadas en proporción a lo que falta cobrar de su venta, redondeado hacia arriba. Ventas desde '
  'el día de su inscripción, dentro de las fechas de la campaña. Solo cantidades: ni plata, ni clientes. '
  'Errores: 42501 sin permiso; CZ001 campaña inexistente. Una campaña terminada se lee.';

-- `authenticated` y `service_role` también en el revoke: en una base creada desde cero los default
-- privileges de la imagen les dan EXECUTE sobre cada función nueva de public (0008).
revoke all on function public.stock_por_ciudad(uuid)
  from public, anon, authenticated, service_role;
grant execute on function public.stock_por_ciudad(uuid) to authenticated;
