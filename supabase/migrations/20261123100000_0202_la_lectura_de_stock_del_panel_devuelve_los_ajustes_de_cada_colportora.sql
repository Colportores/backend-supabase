-- ============================================================================
-- 0202 · La lectura de Stock del panel devuelve los ajustes de stock de cada colportora
--        (backend-supabase#304, seguimiento de front-coordinadores-web#91; decisión del 23/11 por la regla R1:
--        un dato de más en una lectura que ya existe y que los documentos ya prometen, «Ajuste stock» de Cristian,
--        28/10)
--
-- Caso: Marta, coordinadora, abre un libro en Stock (vista 34) y quiere ver por qué a Lucía le cambió el stock a
-- mano: cuánto sumó o restó, por qué motivo de la lista y cuándo. Desde 0148 cada ajuste que Lucía carga en su
-- teléfono queda en `movimiento_stock` (AJUSTE_ENTRADA / AJUSTE_SALIDA con su motivo), pero `stock_por_ciudad` solo
-- traía el stock resultante, sin el historial.
--
-- Qué cambia
--
--   · `stock_por_ciudad(p_campania_id)` suma una columna al FINAL, `ajustes jsonb`: en cada fila (colportora ×
--     producto), un arreglo con sus ajustes vivos de ese producto, los más nuevos primero, o `[]` si no tiene
--     ninguno. Cada elemento: `id`, `cantidad` (con signo: la entrada suma, la salida resta; nunca cero),
--     `motivo` (`STOCK_INICIAL`, `LIBROS_DANIADOS` o `CONTEO`, la lista cerrada de 0148: nunca texto libre),
--     `cuando` (el momento en que llegó al servidor, `movimiento_stock.fecha`) y `cargado_por` (nombre y apellido de
--     quien lo cargó: `created_by`, y si no está, la colportora dueña del movimiento; null si no tiene nombre).
--   · Mismo permiso que el resto de la lectura (la coordinadora de la campaña o un admin; una campaña terminada se
--     lee) y mismas filas: los ajustes son de las colportoras inscriptas en la campaña, de cualquier fecha (el stock
--     no es de una campaña: un «Stock inicial» cargado antes de empezar explica lo que tiene hoy). Los ajustes dados
--     de baja no salen. Solo cantidades y códigos: ni plata ni clientes.
--   · El resto de la respuesta (cuerpo de 0198) es el mismo. Cambia el tipo de retorno: drop + create, con los
--     privilegios de antes (EXECUTE solo para `authenticated`).
--
-- ## Para otros repos
--
--   · front-coordinadores-web: `ColportorDeStock.ajustes` sale de la columna `ajustes` de cada fila: se junta, por
--     colportora, el arreglo de todas sus filas (la clave `productoId` es el `producto_id` de la fila). `cargado_por`
--     es el texto que muestra el historial. La fuente simulada ya cumple el contrato.
--   · docs-organizacion: README de este repo ya lo anota; el contrato de las RPC y esquema-datos.md (la columna
--     nueva de `stock_por_ciudad`): se piden en el cuerpo del PR.
--
-- Forward-only: esta migración no se edita una vez aplicada.
-- ============================================================================

drop function public.stock_por_ciudad(uuid);

create function public.stock_por_ciudad(p_campania_id uuid)
returns table (ciudad_id uuid, ciudad_nombre text, departamento text,
               colportor_id uuid, nombre text, apellido text, de_baja boolean,
               ultimo_dato_at timestamptz,
               producto_id uuid, producto_nombre text,
               tiene integer, por_entregar integer, entregados integer, devueltos integer, por_cobrar integer,
               ajustes jsonb)
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
    ajuste as (
      -- Los ajustes que cada colportor cargó desde su teléfono (0148), por producto: `cantidad` con signo (la entrada
      -- suma, la salida resta), el motivo de la lista, cuándo llegó y el nombre de quien lo cargó. Sin los dados de
      -- baja. Los más nuevos primero.
      select m.usuario_id as u_id, m.producto_id as p_id,
             jsonb_agg(jsonb_build_object(
                         'id', m.id,
                         'cantidad', case m.tipo when 'AJUSTE_ENTRADA' then m.cantidad else -m.cantidad end,
                         'motivo', m.motivo,
                         'cuando', m.fecha,
                         'cargado_por', nullif(btrim(concat_ws(' ', cu.nombre, cu.apellido)), ''))
                       order by m.fecha desc, m.id desc) as ajustes
        from inscripcion ins
        join public.movimiento_stock m
          on m.usuario_id = ins.usuario_id and m.deleted_at is null and m.tipo in ('AJUSTE_ENTRADA', 'AJUSTE_SALIDA')
        left join public.usuario cu on cu.id = coalesce(m.created_by, m.usuario_id)
       group by m.usuario_id, m.producto_id
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
           coalesce(b.tiene, 0),
           coalesce(b.por_entregar, 0),
           coalesce(b.entregados, 0),
           coalesce(b.devueltos, 0),
           coalesce(b.por_cobrar, 0),
           coalesce(aj.ajustes, '[]'::jsonb)
      from inscripcion ins
      join public.usuario usr on usr.id = ins.usuario_id
      left join public.ciudad ciu on ciu.id = ins.ciudad_k
     cross join productos pd
      join public.producto pr on pr.id = pd.p_id
      left join base b on b.u_id = ins.usuario_id and b.p_id = pd.p_id
      left join ajuste aj on aj.u_id = ins.usuario_id and aj.p_id = pd.p_id
     order by ciu.nombre nulls last, usr.apellido, usr.nombre, ins.usuario_id,
              case pr.categoria when 'BONIFICABLES' then 1 when 'ESPIRITUALES' then 1 when 'REVISTAS' then 2 when 'MATERIAL' then 3 else 4 end,
              pr.nombre, pr.id;
end;
$$;

comment on function public.stock_por_ciudad(uuid) is
  'Vista 34, HU-STK-010 (0111, 0137, 0198, 0202, backend-supabase#101, #201, #233 y #304): una fila por colportor de la campaña × producto '
  'con movimiento en ella: ciudad de su zona actual (sin zona o de baja, ciudad null), si está de baja, cuándo '
  'llegó su último push (ultimo_dato_at, usuario.ultimo_push_at), y en unidades lo que tiene (stock, tal cual, '
  'puede ser negativo), lo por entregar, lo entregado, lo devuelto por los clientes (devueltos) y lo por cobrar: '
  'las unidades entregadas en proporción a lo que falta cobrar de su venta, redondeado hacia arriba, y sus ajustes '
  '(ajustes: arreglo jsonb, [] si no tiene; cada uno con id, cantidad con signo, motivo de la lista, cuando y '
  'cargado_por, el nombre de quien lo cargó; sin texto libre). Ventas desde '
  'el día de su inscripción, dentro de las fechas de la campaña. Los productos de cada colportor, por categoría '
  '(libros, revistas, material, el resto) y por nombre. Solo cantidades: ni plata, ni clientes. '
  'Errores: 42501 sin permiso; CZ001 campaña inexistente. Una campaña terminada se lee.';

-- `authenticated` y `service_role` también en el revoke: en una base creada desde cero los default
-- privileges de la imagen les dan EXECUTE sobre cada función nueva de public (0008).
revoke all on function public.stock_por_ciudad(uuid)
  from public, anon, authenticated, service_role;
grant execute on function public.stock_por_ciudad(uuid) to authenticated;
