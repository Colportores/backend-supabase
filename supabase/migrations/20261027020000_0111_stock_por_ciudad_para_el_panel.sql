-- ============================================================================
-- 0111 · Stock por ciudad para el panel: lo que tiene, lo por entregar, lo entregado y lo por cobrar de
--        cada colportor producto por producto, cuándo llegó su último dato y los pedidos por autorizar de
--        cada ciudad (backend-supabase#101, HU-STK-010, vista 34 «Stock por Ciudad»)
--
-- Origen: cambio de requisitos del 21/10 (reunión del 05/10, docs#69, C4 y C15) y las decisiones de
-- Cristian del 25/10 «Fecha stock» y «Pedidos stock» (front-coordinadores-web#91 y #92). Es V2: se
-- conecta después del 20/11 (plan-sprints §5). Se escribe ahora para no rehacerlo. SOLO LEE: no crea
-- tablas ni columnas, no toca el sync y no cambia ninguna firma existente.
--
--   stock_por_ciudad(p_campania_id)
--     -> (ciudad_id, ciudad_nombre, departamento,
--         colportor_id, nombre, apellido, de_baja, ultimo_dato_at,
--         producto_id, producto_nombre, producto_tipo,
--         tiene, por_entregar, entregados, por_cobrar)
--
--   pedidos_por_autorizar_por_ciudad(p_campania_id)
--     -> (ciudad_id, ciudad_nombre, departamento, pedidos)
--
-- ## Qué devuelve stock_por_ciudad
--
-- Una fila por colportor de la campaña × producto: es lo que dibuja el canvas (el panel suma por ciudad,
-- por departamento y por tipo, y saca «Agotado en la ciudad» y «Faltan N para entregar» de estas
-- cantidades; las alertas no viajan). Un colportor sin nada de un producto trae el producto en cero, así
-- el panel no tiene que completar huecos.
--
--   ciudad_id, ciudad_nombre,   la ciudad de la ZONA ACTUAL del colportor en esta campaña (S69, la misma
--   departamento                regla que 0060/0061/0054). Sin zona, con la zona o la ciudad de campaña
--                               dadas de baja, o con la inscripción dada de baja: los tres null, UNA sola
--                               vez («Sin ciudad»): repetir al colportor en cada ciudad contaría su stock
--                               varias veces. `departamento` también es null si la ciudad no lo tiene
--                               cargado.
--   colportor_id, nombre,       el colportor (sin email ni nada más de la persona).
--   apellido
--   de_baja                     true si su inscripción en esta campaña está dada de baja. Sigue saliendo:
--                               los libros que se llevó no desaparecen del stock (nunca se pierde nada) y
--                               el coordinador tiene que poder ir a buscarlos. Sale sin ciudad.
--   ultimo_dato_at              cuándo el servidor recibió su último push (`usuario.ultimo_push_at`, 0053,
--                               la misma cifra que muestra Inicio): «Sincronizó el 22/10 a las 18:30»
--                               (decisión de Cristian del 25/10, «Fecha stock»). null = todavía no llegó
--                               ninguno. Es el dato de su teléfono y no el del stock en sí: hasta V2 el
--                               stock solo lo escribe el servidor.
--   producto_id, producto_nombre,  el producto y su tipo (LIBRO, REVISTA, MATERIAL o MISIONERO). Los combos
--   producto_tipo               no tienen stock propio (HU-CAT-009): no salen.
--   tiene                       unidades en mano: `stock.cantidad_disponible`. Se devuelve TAL CUAL: la HU
--                               permite entregar más de lo registrado (S46) y deja el stock negativo como
--                               señal de inconsistencia; el panel lo toma como cero al sumar.
--   por_entregar                unidades vendidas y todavía no entregadas (`entrega.pendiente`).
--   entregados                  unidades ya entregadas (`entrega` con `pendiente` en false).
--   por_cobrar                  unidades YA ENTREGADAS cuya venta todavía tiene saldo (`venta.monto_total`
--                               menos sus cobros vivos y no anulados, 0072): se cuentan en unidades y no
--                               en plata (el canvas lo dice así); la plata está en Cuentas. Una venta
--                               pagada de más o en su punto justo no cuenta. Ver «Pendiente» más abajo.
--
-- ## Qué productos salen
--
-- Los que tienen movimiento en la campaña: un renglón de `stock` vivo de algún colportor inscripto (aunque
-- esté en cero) o una entrega de sus ventas. Un producto que nadie tuvo nunca en la campaña no sale: no se
-- «agotó», nunca estuvo, y avisar «Agotado en la ciudad» por cada título del catálogo ahogaría la
-- alerta real. Un producto dado de baja del catálogo solo sale si todavía queda algo en alguna mano o por
-- entregar. No hay umbral ni stock mínimo (S47): el canvas avisa solo al llegar a cero o cuando no
-- alcanza para lo por entregar.
--
-- ## Qué ventas y entregas cuentan
--
-- Las mismas reglas que Reportes (0061): ventas vivas de colportores INSCRIPTOS en p_campania_id, hechas
-- entre `fecha_inicio` y `fecha_fin` de la campaña (días de Montevideo, ambos incluidos), desde el día en
-- que el colportor se inscribió en ESTA campaña y, si la inscripción se dio de baja, hasta la baja. Así un
-- colportor en dos campañas con fechas que se pisan no cuenta las mismas entregas dos veces. No cuentan las
-- ventas ni las entregas dadas de baja (`deleted_at`). `tiene` no mira fechas: es el saldo de hoy.
--
-- ## Qué trae pedidos_por_autorizar_por_ciudad
--
-- Una fila por ciudad (la de la zona actual, o null = «Sin ciudad») con cuántos pedidos a la casa editora
-- (`pedido_casa_editora`) esperan autorización: estado PENDIENTE_AUTORIZACION y vivos, de colportores
-- inscriptos en la campaña. Sale solo la ciudad que tiene al menos uno. Es el aviso «2 pedidos por
-- autorizar en Rivera» con «Ver pedidos» hacia la vista 35 (decisión de Cristian del 25/10, «Pedidos
-- stock»). Un BORRADOR (lo que arma el coordinador) no espera a nadie: no cuenta. Solo el número: ni
-- monto, ni líneas, ni quién pidió.
--
-- ## Permiso y errores (los de las demás lecturas del panel)
--
--   · Sin JWT, colportor, sin rol, rol vencido o coordinador de otra campaña: 42501, antes de mirar nada
--     más. ADMIN: cualquier campaña. Campaña inexistente o dada de baja: CZ001. Una campaña terminada se
--     lee (el stock se mira al cierre para saber qué recoger).
--   · SECURITY DEFINER con search_path vacío (el coordinador no lee `stock`, `entrega`, `venta` ni
--     `cobranza` ajenas por RLS: la función devuelve solo cantidades). Columnas explícitas, nunca
--     `to_jsonb`. VOLATILE (llama a motivo_mapa_de_campania() y lanzar_motivo_mapa()): supabase-js la
--     manda por POST. EXECUTE solo para `authenticated`.
--   · Nunca devuelve clientes, personas visitadas, números de talonario, montos ni cobros: solo
--     cantidades (HU-STK-010, R-RP01). La plata de cada colportor es de Cuentas.
--
-- ## Para otros repos
--
--   · front-coordinadores-web (vista 34, Stock; #65 ya tiene el contrato simulado, #92 la fecha, #91 el
--     aviso de pedidos): POST /rest/v1/rpc/stock_por_ciudad con { p_campania_id } y POST
--     /rest/v1/rpc/pedidos_por_autorizar_por_ciudad con { p_campania_id }. De las filas de la primera salen
--     `DatosDeStock.productos` (producto_id distintos), `colportores` (colportor_id distintos con su
--     ciudad_id y sus `existencias`) y `ciudades` (las de la lista de la campaña, ciudades_de_campania()).
--     `existencias.{tiene, porEntregar, entregados, porCobrar}` son `tiene`, `por_entregar`, `entregados` y
--     `por_cobrar`.
--   · Depende de que las ventas y las entregas suban a la nube (sync) y de que el servidor escriba `stock`
--     (V2): hasta entonces la lectura devuelve la lista vacía, que no es un error.
--
-- ## Pendiente (archivo de pendientes de esta entrega)
--
--   · `por_cobrar` de una venta cobrada a medias cuenta todas sus unidades entregadas (no se prorratea).
--   · Las devoluciones (0108) no descuentan unidades de `entregados` ni de `por_cobrar`.
--
-- Forward-only: no se edita una vez aplicada.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. stock_por_ciudad
-- ----------------------------------------------------------------------------

create function public.stock_por_ciudad(p_campania_id uuid)
returns table (ciudad_id uuid, ciudad_nombre text, departamento text,
               colportor_id uuid, nombre text, apellido text, de_baja boolean,
               ultimo_dato_at timestamptz,
               producto_id uuid, producto_nombre text, producto_tipo text,
               tiene integer, por_entregar integer, entregados integer, por_cobrar integer)
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
    movimiento as (
      -- Las entregas de las ventas de la campaña, por colportor y producto. El saldo de la venta no
      -- cuenta los cobros anulados (0072).
      select ins.usuario_id as u_id, e.producto_id as p_id,
             (sum(e.cantidad) filter (where e.pendiente))::integer as por_entregar,
             (sum(e.cantidad) filter (where not e.pendiente))::integer as entregados,
             (sum(e.cantidad) filter (where not e.pendiente and sd.saldo > 0))::integer as por_cobrar
        from inscripcion ins
        join public.venta v on v.colportor_id = ins.usuario_id and v.deleted_at is null
        join public.entrega e on e.venta_id = v.id and e.deleted_at is null
       cross join lateral (
         select v.monto_total::bigint - coalesce(sum(co.monto), 0)::bigint as saldo
           from public.cobranza co
          where co.venta_id = v.id and co.deleted_at is null and co.anulado_at is null
       ) sd
       where public.hoy_montevideo(v.fecha) >= v_campania.fecha_inicio
         and public.hoy_montevideo(v.fecha) <= coalesce(v_campania.fecha_fin, 'infinity'::date)
         and public.hoy_montevideo(v.fecha) >= ins.desde_dia
         and (ins.baja is null or v.fecha < ins.baja)
       group by ins.usuario_id, e.producto_id
    ),
    base as (
      select coalesce(m.u_id, h.u_id) as u_id,
             coalesce(m.p_id, h.p_id) as p_id,
             h.tiene,
             m.por_entregar, m.entregados, m.por_cobrar
        from movimiento m
        full join en_mano h on h.u_id = m.u_id and h.p_id = m.p_id
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
  'Vista 34, HU-STK-010 (0111, backend-supabase#101): una fila por colportor de la campaña × producto con '
  'movimiento en ella: ciudad de su zona actual (sin zona o de baja, ciudad null), si está de baja, cuándo '
  'llegó su último push (ultimo_dato_at, usuario.ultimo_push_at), y en unidades lo que tiene (stock, tal '
  'cual, puede ser negativo), lo por entregar, lo entregado y lo entregado cuya venta aún tiene saldo '
  '(por_cobrar). Ventas desde el día de su inscripción, dentro de las fechas de la campaña. Solo '
  'cantidades: ni plata, ni clientes. Errores: 42501 sin permiso; CZ001 campaña inexistente. Una campaña '
  'terminada se lee.';

-- `authenticated` y `service_role` también en el revoke: en una base creada desde cero los default
-- privileges de la imagen les dan EXECUTE sobre cada función nueva de public (0008).
revoke all on function public.stock_por_ciudad(uuid)
  from public, anon, authenticated, service_role;
grant execute on function public.stock_por_ciudad(uuid) to authenticated;

-- ----------------------------------------------------------------------------
-- 2. pedidos_por_autorizar_por_ciudad
-- ----------------------------------------------------------------------------

create function public.pedidos_por_autorizar_por_ciudad(p_campania_id uuid)
returns table (ciudad_id uuid, ciudad_nombre text, departamento text, pedidos integer)
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_motivo  text;
begin
  v_motivo := public.motivo_mapa_de_campania(p_campania_id);
  if v_motivo = 'SIN_PERMISO' then
    raise exception 'Solo el coordinador de la campaña o un administrador puede ver sus pedidos. Entrá con la cuenta del coordinador de esta campaña.'
      using errcode = 'insufficient_privilege';
  end if;
  if v_motivo is distinct from 'CAMPANIA_TERMINADA' then
    perform public.lanzar_motivo_mapa(v_motivo);
  end if;

  return query
    select ciu.id,
           ciu.nombre,
           ciu.departamento,
           (count(*))::integer
      from public.campania_colportor i
      left join public.zona z
             on z.id = i.zona_id and z.deleted_at is null and i.deleted_at is null
      left join public.campania_ciudad cc
             on cc.id = z.campania_ciudad_id and cc.deleted_at is null
      left join public.ciudad ciu on ciu.id = cc.ciudad_id
      join public.pedido_casa_editora pe
        on pe.colportor_id = i.usuario_id
       and pe.estado = 'PENDIENTE_AUTORIZACION'
       and pe.deleted_at is null
     where i.campania_id = p_campania_id
     group by ciu.id, ciu.nombre, ciu.departamento
     order by ciu.nombre nulls last, ciu.id;
end;
$$;

comment on function public.pedidos_por_autorizar_por_ciudad(uuid) is
  'Vista 34, HU-STK-010 (0111, backend-supabase#101, decisión «Pedidos stock» del 25/10): cuántos pedidos a '
  'la casa editora esperan autorización (estado PENDIENTE_AUTORIZACION, vivos) por ciudad de la zona actual '
  'del colportor de la campaña (ciudad null = sin ciudad). Solo las ciudades con al menos uno; solo el '
  'número. Errores: 42501 sin permiso; CZ001 campaña inexistente. Una campaña terminada se lee.';

revoke all on function public.pedidos_por_autorizar_por_ciudad(uuid)
  from public, anon, authenticated, service_role;
grant execute on function public.pedidos_por_autorizar_por_ciudad(uuid) to authenticated;
