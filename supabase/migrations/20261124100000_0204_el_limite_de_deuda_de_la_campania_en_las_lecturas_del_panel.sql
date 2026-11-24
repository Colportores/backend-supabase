-- ============================================================================
-- 0204 · El límite de deuda de la campaña en las lecturas del panel
--        (backend-supabase#308, seguimiento de front-coordinadores-web#215; decisión del 24/11 por la regla R1:
--        un dato de más en una lectura que los documentos ya prometen, «Límite ped.» de Cristian, 25/10, #156)
--
-- Caso: Marta, coordinadora, abre Pedidos y transferencias (vista 35) y tiene que ver «Límite de deuda de la
-- campaña: $U 50.000 por colportor» y qué pedidos lo pasan, para decidir si autoriza igual, reduce o rechaza.
-- Desde 0120 la campaña tiene `limite_deuda` y las funciones internas que lo miden, pero el panel no puede leer la
-- tabla `campania` (ADR-013) y las lecturas de la bandeja no lo traían (0112 y 0130 lo dejaron para cuando
-- existiera).
--
-- Qué cambia (solo suma columnas: no cambia quién ve qué ni qué filas salen)
--
--   · `pedidos_de_campania(p_campania_id)` suma al FINAL dos columnas:
--       `limite_deuda bigint`      el límite de la campaña en centavos (el mismo en todas las filas), o null si no
--                                  tiene límite;
--       `supera_limite_por bigint` cuánto pasa el límite la deuda del colportor con la casa editora MÁS ese
--                                  pedido, en centavos, o null si no lo pasa (justo en el límite no) o si no hay
--                                  límite. Se mide con `supera_limite_de_deuda_por()` (0120), como el aviso de la
--                                  app. Solo para un pedido POR AUTORIZAR (`PENDIENTE_AUTORIZACION`), que es el
--                                  que el coordinador todavía decide: en los demás estados es null (en uno ya
--                                  autorizado el monto ya está en la deuda y en uno rechazado no cuenta; lo que
--                                  pasó al enviarlo queda en `excede_limite`, que no cambia).
--   · `pedido_contexto(p_pedido_id)` suma al FINAL las mismas dos columnas, con el mismo criterio. La campaña del
--     pedido es la de `campania_del_ticket()` del colportor en el momento del pedido (la misma que decide a quién
--     le toca verlo); un pedido sin campaña (su inscripción ya no cubre ese momento) sale con las dos en null.
--   · `campanias_del_coordinador()` suma al FINAL `limite_deuda bigint`, para que el panel lo vea aunque la
--     campaña todavía no tenga pedidos. Misma lista de campañas que 0175.
--
-- Cada función cambia el tipo de retorno: drop + create, con los privilegios de antes (EXECUTE solo para
-- `authenticated`). Los cuerpos son los de 0130 (las dos de pedidos) y 0175 (campañas) más lo de arriba.
--
-- ## Para otros repos
--
--   · front-coordinadores-web (#215): `rpc.ts` lee `limite_deuda` de `campanias_del_coordinador()` (la campaña
--     elegida) y `supera_limite_por` de cada pedido por autorizar; con `limite_deuda` null no hay aviso. Las
--     columnas nuevas van al final: el código que lee por nombre no se entera.
--   · docs-organizacion: esquema-datos.md (`pedido_contexto`: ya no «todavía no trae el límite»; las columnas
--     nuevas de las tres lecturas) y el contrato de las RPC; se piden en el cuerpo del PR.
--
-- Forward-only: esta migración no se edita una vez aplicada.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. pedidos_de_campania: el límite y cuánto lo pasa cada pedido por autorizar
-- ----------------------------------------------------------------------------

drop function public.pedidos_de_campania(uuid);

create function public.pedidos_de_campania(p_campania_id uuid)
returns table (pedido_id uuid, numero bigint, colportor_id uuid, nombre text, apellido text,
               ciudad_id uuid, ciudad_nombre text, departamento text, de_baja boolean,
               estado text, origen text, fecha_pedido timestamptz,
               productos integer, unidades integer, unidades_autorizadas integer,
               monto_total bigint, monto_autorizado bigint, excede_limite boolean,
               decidido_en timestamptz, motivo_rechazo text, deshacer_hasta timestamptz,
               limite_deuda bigint, supera_limite_por bigint)
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_motivo  text;
  v_limite  bigint;
begin
  v_motivo := public.motivo_mapa_de_campania(p_campania_id);
  if v_motivo = 'SIN_PERMISO' then
    raise exception 'Solo el coordinador de la campaña o un administrador puede ver sus pedidos. Entrá con la cuenta del coordinador de esta campaña.'
      using errcode = 'insufficient_privilege';
  end if;
  if v_motivo is distinct from 'CAMPANIA_TERMINADA' then
    perform public.lanzar_motivo_mapa(v_motivo);
  end if;

  select c.limite_deuda into v_limite
    from public.campania c
   where c.id = p_campania_id and c.deleted_at is null;

  return query
    select pe.id,
           pe.numero,
           i.usuario_id,
           usr.nombre,
           usr.apellido,
           ciu.id,
           ciu.nombre,
           ciu.departamento,
           (i.deleted_at is not null),
           pe.estado,
           pe.origen,
           pe.fecha_pedido,
           ln.productos,
           ln.unidades,
           case when pe.monto_autorizado is null then null else ln.unidades_autorizadas end,
           pe.monto_total,
           pe.monto_autorizado,
           pe.excede_limite,
           pe.decidido_en,
           pe.motivo_rechazo,
           case when pe.estado in ('AUTORIZADO', 'RECHAZADO')
                then pe.decidido_en + public.plazo_para_deshacer_pedido() end,
           v_limite,
           case when pe.estado = 'PENDIENTE_AUTORIZACION'
                then public.supera_limite_de_deuda_por(i.usuario_id, p_campania_id, pe.monto_total) end
      from public.campania_colportor i
      join public.pedido_casa_editora pe
        on pe.colportor_id = i.usuario_id
       and pe.deleted_at is null
       and pe.estado in ('PENDIENTE_AUTORIZACION', 'AUTORIZADO', 'DESPACHADO', 'RECIBIDO', 'RECHAZADO')
       and public.campania_del_ticket(i.usuario_id, pe.fecha_pedido) = i.campania_id
      join public.usuario usr on usr.id = i.usuario_id
      left join public.zona z
             on z.id = i.zona_id and z.deleted_at is null and i.deleted_at is null
      left join public.campania_ciudad cc
             on cc.id = z.campania_ciudad_id and cc.deleted_at is null
      left join public.ciudad ciu on ciu.id = cc.ciudad_id
     cross join lateral (
       select (count(*))::integer as productos,
              (coalesce(sum(it.cantidad), 0))::integer as unidades,
              (coalesce(sum(coalesce(it.cantidad_autorizada, it.cantidad)), 0))::integer as unidades_autorizadas
         from public.pedido_item it
        where it.pedido_id = pe.id and it.deleted_at is null
     ) ln
     where i.campania_id = p_campania_id
     order by pe.fecha_pedido desc, pe.id;
end;
$$;

comment on function public.pedidos_de_campania(uuid) is
  'Vista 35, HU-STK-003 (0112, backend-supabase#104; el número visible, 0130, #180; el límite de deuda, 0204, #308): los pedidos a la casa editora de los colportores de '
  'la campaña (los que hizo dentro de la ventana de su inscripción, hasta 15 días después del fin si no hubo '
  'baja, y que no son de una inscripción más nueva: no los que pidió en la campaña de otro coordinador) en los cinco estados de las pestañas (por autorizar, autorizado, '
  'despachado, recibido, rechazado; sin borradores ni cancelados), el más reciente primero, con la ciudad de la zona actual del '
  'colportor, el número visible («Pedido #231»), lo pedido y lo autorizado, el motivo del rechazo y hasta cuándo se puede deshacer lo '
  'decidido. limite_deuda es el límite de la campaña en centavos (null = sin límite); supera_limite_por, solo en un '
  'pedido por autorizar, cuánto pasa el límite la deuda del colportor más el pedido (null si no lo pasa). '
  'Errores: 42501 sin permiso; CZ001 campaña inexistente. Una campaña terminada se lee.';

revoke all on function public.pedidos_de_campania(uuid)
  from public, anon, authenticated, service_role;
grant execute on function public.pedidos_de_campania(uuid) to authenticated;

-- ----------------------------------------------------------------------------
-- 2. pedido_contexto: el límite y cuánto lo pasa el pedido
-- ----------------------------------------------------------------------------

drop function public.pedido_contexto(uuid);

create function public.pedido_contexto(p_pedido_id uuid)
returns table (numero bigint, colportor_id uuid, nombre text, apellido text, estado text,
               monto_total bigint, monto_autorizado bigint,
               deuda_actual bigint, deuda_con_pedido bigint, por_cobrar bigint,
               libros_por_entregar integer,
               ultimo_deposito_fecha timestamptz, ultimo_deposito_monto bigint,
               limite_deuda bigint, supera_limite_por bigint)
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_pedido    public.pedido_casa_editora;
  v_campania  uuid;
  v_limite    bigint;
begin
  v_pedido := public.pedido_para(p_pedido_id, false);

  v_campania := public.campania_del_ticket(v_pedido.colportor_id, v_pedido.fecha_pedido);
  select c.limite_deuda into v_limite
    from public.campania c
   where c.id = v_campania and c.deleted_at is null;

  return query
    select v_pedido.numero,
           v_pedido.colportor_id,
           usr.nombre,
           usr.apellido,
           v_pedido.estado,
           v_pedido.monto_total,
           v_pedido.monto_autorizado,
           coalesce(cu.deuda_total, 0),
           coalesce(cu.deuda_total, 0)
             + case when v_pedido.estado = 'PENDIENTE_AUTORIZACION' then v_pedido.monto_total else 0 end,
           coalesce(cu.dinero_por_cobrar, 0),
           (select coalesce(sum(en.cantidad), 0)::integer
              from public.venta v
              join public.entrega en on en.venta_id = v.id and en.deleted_at is null and en.pendiente
             where v.colportor_id = v_pedido.colportor_id and v.deleted_at is null),
           dep.fecha,
           dep.monto,
           v_limite,
           case when v_pedido.estado = 'PENDIENTE_AUTORIZACION'
                then public.supera_limite_de_deuda_por(v_pedido.colportor_id, v_campania, v_pedido.monto_total) end
      from public.usuario usr
      left join public.cuenta_colportor cu
             on cu.usuario_id = usr.id and cu.deleted_at is null
      left join lateral (
        select d.fecha, d.monto
          from public.deposito d
         where d.colportor_id = usr.id and d.deleted_at is null
           and d.concepto = 'CASA_EDITORA'
         order by d.fecha desc, d.id
         limit 1
      ) dep on true
     where usr.id = v_pedido.colportor_id;
end;
$$;

comment on function public.pedido_contexto(uuid) is
  'Vista 35, HU-STK-003 (0112; el número visible, 0130, #180; el límite de deuda, 0204, #308): la cuenta del colportor para decidir su pedido: número del pedido, deuda actual '
  '(cuenta_colportor.deuda_total), deuda con el pedido (la actual más el pedido mientras está por autorizar), '
  'por cobrar (cuenta_colportor.dinero_por_cobrar), unidades vendidas por entregar y su último depósito, más el '
  'límite de deuda de la campaña del pedido (centavos; null = sin límite o pedido sin campaña) y, solo si el pedido '
  'está por autorizar, cuánto pasa el límite la deuda con el pedido (supera_limite_por; null si no lo pasa). Solo '
  'montos y cantidades: ni clientes ni cobros. Errores: 42501 sin permiso; PE001 si el pedido no existe.';

revoke all on function public.pedido_contexto(uuid)
  from public, anon, authenticated, service_role;
grant execute on function public.pedido_contexto(uuid) to authenticated;

-- ----------------------------------------------------------------------------
-- 3. campanias_del_coordinador: el límite, aunque la campaña no tenga pedidos
-- ----------------------------------------------------------------------------

drop function public.campanias_del_coordinador();

create function public.campanias_del_coordinador()
returns table (id uuid, nombre text, tipo text, fecha_inicio date, fecha_fin date, limite_deuda bigint)
language plpgsql
stable
set search_path = ''
as $$
declare
  v_hoy date := public.hoy_montevideo();
begin
  if auth.uid() is null then
    raise exception 'Hace falta iniciar sesión. Entrá con tu cuenta de coordinador.'
      using errcode = 'insufficient_privilege';
  end if;

  if not (public.tiene_rol('COORDINADOR') or public.tiene_rol('ADMIN')) then
    raise exception 'Esta cuenta no es de coordinador. Entrá con tu cuenta de coordinador.'
      using errcode = 'insufficient_privilege';
  end if;

  return query
    select c.id, c.nombre, c.tipo, c.fecha_inicio, c.fecha_fin, c.limite_deuda
      from public.campania c
     where public.coordina_la_campania(c.id)
       and c.deleted_at is null
       and (c.fecha_fin is null or c.fecha_fin >= v_hoy)
     order by (c.fecha_inicio > v_hoy), abs(c.fecha_inicio - v_hoy), c.id;
end;
$$;

comment on function public.campanias_del_coordinador() is
  'Panel (0033, ADR-013; el límite de deuda, 0204, #308): las campañas vivas que coordina el usuario autenticado y que no '
  'terminaron (en curso o por empezar; hoy = el día de Montevideo), con su límite de deuda en centavos (null = sin '
  'límite). Primero las en curso, la que empezó más tarde primero; después las por empezar, la más próxima primero. '
  'Errores: 42501 sin sesión o sin el rol COORDINADOR ni ADMIN. Un ADMIN ve solo las que coordina.';

revoke all on function public.campanias_del_coordinador()
  from public, anon, authenticated, service_role;
grant execute on function public.campanias_del_coordinador() to authenticated;
