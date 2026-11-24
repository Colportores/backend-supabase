-- ============================================================================
-- 0198 · Se saca `producto.tipo` y las lecturas que devolvían `producto_tipo`
--        (backend-supabase#233, seguimiento de #226 / #221; decisión P2 del 29/10, «Categorías» de Cristian)
--
-- Caso: Administración carga un producto con su categoría (Espirituales, Bonificables, Misioneros, Revistas o
-- Material). Desde 0149 la categoría es la única que decide cómo se etiqueta, y `tipo` quedó como columna heredada
-- que un trigger mantenía en el mismo sentido solo para que las lecturas viejas siguieran andando. Ya ningún lector
-- la usa: la app pasó a la categoría (front-colportores-mobile#561, cerrada) y el panel no lee `producto_tipo`
-- (ni en `develop` ni en sus ramas abiertas). Esta migración cierra la transición.
--
-- Qué cambia
--
--   · `producto.tipo` se elimina (con su CHECK). Un producto ya cargado no pierde nada: su categoría es obligatoria
--     desde 0149 y es la que cuenta. Baja a la app por el pull como columna menos; el motor ignora lo que no conoce.
--   · Se eliminan el trigger de transición `producto_categoria_y_tipo` y dos de las tres funciones que solo él usaba:
--     `tg_producto_categoria_y_tipo()` y `categoria_de_producto(text, boolean, boolean)`. `tipo_de_categoria(text)` se
--     queda (ver el punto siguiente).
--   · El pull de `producto` SIGUE mandando una clave `tipo`, derivada de la categoría con `tipo_de_categoria` (LIBRO,
--     MISIONERO, REVISTA o MATERIAL, el mismo valor que mantenía el trigger). Ya no es una columna: es una clave
--     calculada en `sync.expresion_json`, como `unida_a_id` en `ubicacion` (0051). Por qué: la tabla local del
--     teléfono (`front-colportores-mobile`, `productos_table.dart`) todavía tiene `tipo` NOT NULL, y una fila de
--     `producto` que baja sin esa clave rompe el upsert, revierte la página del pull y el watermark no avanza (lo mismo
--     le pasa a una app vieja instalada). Cuando el móvil saque la columna de su esquema local, un seguimiento quita
--     la clave de `sync.expresion_json` y `tipo_de_categoria`.
--     Desde ahora quien escribe un producto tiene que decir su categoría: sin ella, 23502 (NOT NULL), como siempre
--     para una alta sin categoría.
--   · Las tres lecturas que devolvían `producto_tipo` lo dejan de devolver (cambia el tipo de retorno: drop + create,
--     con los permisos de antes, EXECUTE solo para `authenticated`):
--       stock_por_ciudad(p_campania_id)        (cuerpo de 0137)
--       pedido_lineas(p_pedido_id)             (cuerpo de 0112)
--       transferencia_lineas(p_transferencia_id)  (cuerpo de 0126)
--     Fuera de la columna, el cuerpo es el mismo, salvo el orden de `stock_por_ciudad`: antes ordenaba los productos de
--     cada colportor por tipo (libros, revistas, material, el resto) y ahora lo hace por categoría con el mismo
--     criterio: Espirituales y Bonificables (los libros), Revistas, Material y el resto (Misioneros).
--
-- ## Para otros repos
--
--   · front-coordinadores-web: `stock_por_ciudad`, `pedido_lineas` y `transferencia_lineas` ya no traen
--     `producto_tipo`. Si una vista necesita agrupar o etiquetar, que lea la categoría del catálogo.
--   · front-colportores-mobile: el pull de `producto` sigue trayendo `tipo` (derivado de la categoría) mientras su
--     tabla local lo exija; la app lee `categoria` desde #561 y puede sacar la columna de su esquema local cuando quiera.
--   · docs-organizacion: esquema-datos.md (`producto.tipo` y los `producto_tipo` de esas tres lecturas) y el contrato
--     de las RPC: se piden en el cuerpo del PR.
--
-- Forward-only: esta migración no se edita una vez aplicada.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. Las lecturas, sin `producto_tipo`
-- ----------------------------------------------------------------------------

drop function public.stock_por_ciudad(uuid);

create function public.stock_por_ciudad(p_campania_id uuid)
returns table (ciudad_id uuid, ciudad_nombre text, departamento text,
               colportor_id uuid, nombre text, apellido text, de_baja boolean,
               ultimo_dato_at timestamptz,
               producto_id uuid, producto_nombre text,
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
              case pr.categoria when 'BONIFICABLES' then 1 when 'ESPIRITUALES' then 1 when 'REVISTAS' then 2 when 'MATERIAL' then 3 else 4 end,
              pr.nombre, pr.id;
end;
$$;

comment on function public.stock_por_ciudad(uuid) is
  'Vista 34, HU-STK-010 (0111, 0137, 0198, backend-supabase#101, #201 y #233): una fila por colportor de la campaña × producto '
  'con movimiento en ella: ciudad de su zona actual (sin zona o de baja, ciudad null), si está de baja, cuándo '
  'llegó su último push (ultimo_dato_at, usuario.ultimo_push_at), y en unidades lo que tiene (stock, tal cual, '
  'puede ser negativo), lo por entregar, lo entregado, lo devuelto por los clientes (devueltos) y lo por cobrar: '
  'las unidades entregadas en proporción a lo que falta cobrar de su venta, redondeado hacia arriba. Ventas desde '
  'el día de su inscripción, dentro de las fechas de la campaña. Los productos de cada colportor, por categoría '
  '(libros, revistas, material, el resto) y por nombre. Solo cantidades: ni plata, ni clientes. '
  'Errores: 42501 sin permiso; CZ001 campaña inexistente. Una campaña terminada se lee.';

-- `authenticated` y `service_role` también en el revoke: en una base creada desde cero los default
-- privileges de la imagen les dan EXECUTE sobre cada función nueva de public (0008).
revoke all on function public.stock_por_ciudad(uuid)
  from public, anon, authenticated, service_role;
grant execute on function public.stock_por_ciudad(uuid) to authenticated;

drop function public.pedido_lineas(uuid);

create function public.pedido_lineas(p_pedido_id uuid)
returns table (producto_id uuid, producto_nombre text,
               cantidad integer, cantidad_autorizada integer, precio_unitario bigint,
               subtotal bigint, subtotal_autorizado bigint, stock integer)
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_pedido  public.pedido_casa_editora;
begin
  v_pedido := public.pedido_para(p_pedido_id, false);

  return query
    select it.producto_id,
           pr.nombre,
           it.cantidad,
           it.cantidad_autorizada,
           it.precio_unitario,
           it.cantidad::bigint * it.precio_unitario,
           coalesce(it.cantidad_autorizada, it.cantidad)::bigint * it.precio_unitario,
           coalesce(st.cantidad_disponible, 0)
      from public.pedido_item it
      join public.producto pr on pr.id = it.producto_id
      left join public.stock st
             on st.usuario_id = v_pedido.colportor_id
            and st.producto_id = it.producto_id
            and st.deleted_at is null
     where it.pedido_id = v_pedido.id and it.deleted_at is null
     order by pr.nombre, it.producto_id;
end;
$$;

comment on function public.pedido_lineas(uuid) is
  'Vista 35, HU-STK-003 (0112, 0198): las líneas del pedido con su costo unitario de la casa editora (la foto de '
  'precio_base_compra al pedir), lo pedido, lo autorizado (null = lo pedido), los subtotales y el stock que '
  'el colportor tiene hoy de ese producto (puede ser negativo, tal cual). Errores: 42501 sin permiso; '
  'PE001 si el pedido no existe.';

revoke all on function public.pedido_lineas(uuid)
  from public, anon, authenticated, service_role;
grant execute on function public.pedido_lineas(uuid) to authenticated;

drop function public.transferencia_lineas(uuid);

create function public.transferencia_lineas(p_transferencia_id uuid)
returns table (producto_id uuid, producto_nombre text,
               cantidad integer, precio_unitario bigint, subtotal bigint,
               tiene_quien_da integer, debe_entregar_quien_recibe integer, tiene_quien_recibe integer)
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_t  public.transferencia_stock;
begin
  v_t := public.transferencia_para(p_transferencia_id, false);

  return query
    select it.producto_id,
           pr.nombre,
           it.cantidad,
           coalesce(it.precio_unitario, pr.precio_base_compra)::bigint,
           it.cantidad::bigint * coalesce(it.precio_unitario, pr.precio_base_compra),
           coalesce(sd.cantidad_disponible, 0),
           (select coalesce(sum(en.cantidad), 0)::integer
              from public.venta ve
              join public.entrega en
                on en.venta_id = ve.id and en.deleted_at is null and en.pendiente
               and en.producto_id = it.producto_id
             where ve.colportor_id = v_t.destino_id and ve.deleted_at is null),
           coalesce(sr.cantidad_disponible, 0)
      from public.transferencia_item it
      join public.producto pr on pr.id = it.producto_id
      left join public.stock sd
             on sd.usuario_id = v_t.origen_id and sd.producto_id = it.producto_id and sd.deleted_at is null
      left join public.stock sr
             on sr.usuario_id = v_t.destino_id and sr.producto_id = it.producto_id and sr.deleted_at is null
     where it.transferencia_id = v_t.id and it.deleted_at is null
     order by pr.nombre, it.producto_id;
end;
$$;

comment on function public.transferencia_lineas(uuid) is
  'Vista 35, HU-STK-005/006 (0126, 0198): las líneas de la transferencia con su costo unitario de la casa editora (la '
  'foto si ya se autorizó, si no el vigente; null si falta), los subtotales y el stock de los dos: cuánto tiene '
  'hoy quien da, cuántas unidades de ese producto debe entregar quien recibe (vendidas y todavía no entregadas) '
  'y cuánto tiene ya quien recibe (puede ser negativo, tal cual). Errores: 42501 sin permiso; TR001 si no '
  'existe.';

revoke all on function public.transferencia_lineas(uuid)
  from public, anon, authenticated, service_role;
grant execute on function public.transferencia_lineas(uuid) to authenticated;

-- ----------------------------------------------------------------------------
-- 2. La transición se cierra: sin trigger, sin helpers y sin la columna
-- ----------------------------------------------------------------------------

drop trigger producto_categoria_y_tipo on public.producto;
drop function public.tg_producto_categoria_y_tipo();
drop function public.categoria_de_producto(text, boolean, boolean);

alter table public.producto
  drop column tipo;

comment on column public.producto.categoria is
  'La categoría del producto (0149, «Categorías» del 28/10): BONIFICABLES, MISIONEROS, REVISTAS, ESPIRITUALES o '
  'MATERIAL. Una por producto, obligatoria y sin valor por defecto: la elige quien lo carga. Desde 0198 es la única: '
  'el `tipo` heredado ya no existe. `es_bonificable` sigue aparte, como sí/no: es lo que cuenta para la beca y para '
  'la compra a la CES.';

-- ----------------------------------------------------------------------------
-- 3. El pull de `producto` sigue trayendo `tipo` (derivado de la categoría)
-- ----------------------------------------------------------------------------

-- Igual que en 0051 (que sumó `unida_a_id` a `ubicacion`), más la clave `tipo` en la fila de `producto`: la que
-- calcula `tipo_de_categoria(t.categoria)`. El alias de la tabla es `t` en todos los que la usan. create or replace
-- conserva privilegios. `tipo_de_categoria` es pura e inmutable y la ejecuta quien tiene sesión (authenticated) y el
-- servidor (service_role), como en 0149.
create or replace function sync.expresion_json(p_tabla regclass)
returns text
language sql
stable
set search_path = ''
as $$
  select 'jsonb_build_object(' || string_agg(
           format('%L, %s', c.attname,
             case when c.atttypid = 'pg_catalog.numeric'::regtype
                  then format('(t.%I)::text', c.attname)
                  else format('t.%I', c.attname) end),
           ', ' order by c.attnum)
         || case when p_tabla = 'public.ubicacion'::regclass
                 then ', ''unida_a_id'', public.ubicacion_unida_a(t.id)'
                 when p_tabla = 'public.producto'::regclass
                 then ', ''tipo'', public.tipo_de_categoria(t.categoria)'
                 else '' end
         || ')'
  from pg_catalog.pg_attribute c
  where c.attrelid = p_tabla
    and c.attnum > 0
    and not c.attisdropped
    and c.attname::text <> 'xmin_w';
$$;

comment on function sync.expresion_json(regclass) is
  'Serializa una fila a jsonb con los numeric como texto. Se usa con execute format(); los '
  'nombres salen del catálogo y pasan por %I, así que no hay inyección posible. La fila de ubicacion '
  'suma unida_a_id (0051): a qué ubicación se unió, o null; no es una columna. La de producto suma `tipo` '
  '(0198): el tipo heredado derivado de la categoría, mientras la tabla local del teléfono lo exija.';

comment on function public.tipo_de_categoria(text) is
  'El tipo heredado (LIBRO, REVISTA, MATERIAL o MISIONERO) que corresponde a una categoría (0149). Desde 0198 ya no '
  'hay columna producto.tipo ni trigger: lo usa solo `sync.expresion_json` para la clave `tipo` que el pull de '
  'producto sigue mandando al teléfono hasta que su tabla local deje de exigirla.';
