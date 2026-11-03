-- ============================================================================
-- 0153 · Anular una devolución restituye la entrega pendiente que había quitado (backend-supabase#226, seguimiento de
--        #221 / PR 225; decisión del 29/10 por la regla R1 y el precedente «Entrega desh»:
--        https://github.com/Colportores/backend-supabase/pull/225#issuecomment-6491193945)
--
-- Caso: Ana vendió 3 libros a Pedro, entregó 1 y registra la devolución de los 3 (vuelve 1 al stock y los otros 2,
-- que nunca salieron de su mochila, salen de la entrega pendiente: la fila de 2 queda dada de baja). Después se da
-- cuenta de que se equivocó de venta y anula la devolución. Hasta 0148 el stock volvía a restarse, pero los 2 libros
-- que Pedro sigue esperando quedaban sin entrega pendiente: una venta perdida de vista. Desde ahora anular deshace
-- lo que la devolución hizo, con la misma regla que ya tenía «deshacer una entrega».
--
--   · La traza de lo quitado (`entrega_pendiente_quitada_por_devolucion` en `audit_log`, 0148) pasa a llevar UNA FILA
--     POR ENTREGA tocada, con `entrega_id` (qué fila de `entrega`), `cantidad` (cuántas unidades se le sacaron) y
--     `baja` (true si se la llevó toda y quedó dada de baja; false si solo bajó su cantidad). Antes llevaba un solo
--     evento por libro, sin decir de qué fila: solo suma datos (ids y números), no cambia nada de lo que ya hacía.
--   · `tg_devolucion_devuelve_stock` (UPDATE que anula): además de restar el stock que sumó la devolución, devuelve a
--     pendiente lo que quitó, en la misma transacción:
--       - La MISMA entrega, con su fecha de alta y su cantidad: si se había dado de baja, vuelve a vivir; si solo
--         había bajado su cantidad, recupera las unidades que perdió.
--       - Si esa entrega ya no puede recibirlo (entre una cosa y otra se entregó o se dio de baja por su cuenta), lo
--         que se quitó vuelve como una entrega pendiente NUEVA de esa venta y ese libro, con la fecha prevista de la
--         original: nunca se pierde una venta.
--         Nada se descuenta del stock por esto (una entrega pendiente no es una entrega hecha).
--     Deja el evento `entrega_pendiente_restituida_por_anulacion` (ids y números, con `entrega_id` = la entrega de la
--     que se había quitado y, si hubo que crear otra, `entrega_nueva_id`). Lo que cada devolución restituye es lo
--     que quitó menos lo ya restituido de esa misma devolución: anular dos veces no
--     duplica nada.
--   · Las devoluciones anteriores a esta migración dejaron un evento sin `entrega_id`: no hay de qué fila restituir
--     y se saltean (datos simulados hasta diciembre, sin migración de corrección).
--   · Las entregas del libro en esa venta se toman con candado (por id, como al registrar la devolución): una
--     devolución nueva y esta anulación a la vez no se pisan.
--   · Nunca rechaza: la anulación de la devolución entra siempre. El stock se resta como hasta ahora.
--   · Una devolución anulada no se reabre (decisión del 03/11, revisión de este PR): un UPDATE que le devuelve
--     `deleted_at` a null vuelve `invalid` con `42501` y el aviso «Una devolución anulada no se reabre: registrá una
--     nueva.». Reabrirla dejaba una devolución viva junto a las entregas pendientes ya restituidas y sin volver a
--     sumar el stock. Cambiarle la hora a la baja (de una fecha a otra) sigue pasando sin efectos.
--
-- Lo que cambia para el teléfono: el `update` que reabre una devolución anulada vuelve `invalid` 42501 (el móvil no
-- tiene esa acción hoy). Nada más en el contrato. Las entregas que vuelven suben su `sync_version` y bajan por
-- el pull como cualquier cambio de servidor (la fila recuperada reaparece en «Entregas pendientes»).
--
-- Forward-only: esta migración no se edita una vez aplicada. Se escribe sobre el CUERPO de 0148.
-- ============================================================================

create or replace function public.tg_devolucion_devuelve_stock()
returns trigger
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  r           record;
  p           record;
  q           record;
  v_despues   integer;
  v_entregado bigint;
  v_ya        bigint;
  v_suma      integer;
  v_sale      integer;
  v_resta     integer;
  v_toma      integer;
  v_nueva     uuid;
begin
  if tg_op = 'UPDATE' then
    -- Solo la anulación mueve el stock; cualquier otro cambio de la devolución, no.
    if not (old.deleted_at is null and new.deleted_at is not null) then
      return null;
    end if;

    -- Se resta lo que ella sumó (sus entradas vivas, descontando una salida que ya hubiera salido).
    for r in
      select m.producto_id as prod_id,
             (sum(case when m.tipo = 'ENTRADA_DEVOLUCION' then m.cantidad else -m.cantidad end))::integer as cant
        from public.movimiento_stock m
       where m.devolucion_id = new.id
         and m.deleted_at is null
         and m.tipo in ('ENTRADA_DEVOLUCION', 'SALIDA_DEVOLUCION_ANULADA')
       group by m.producto_id
      having sum(case when m.tipo = 'ENTRADA_DEVOLUCION' then m.cantidad else -m.cantidad end) > 0
       order by m.producto_id
    loop
      insert into public.stock as s (usuario_id, producto_id, cantidad_disponible)
      values (new.colportor_id, r.prod_id, -r.cant)
      on conflict (usuario_id, producto_id)
      do update set cantidad_disponible = case when s.deleted_at is null then s.cantidad_disponible else 0 end
                                          + excluded.cantidad_disponible,
                    deleted_at = null
      returning s.cantidad_disponible into v_despues;

      insert into public.movimiento_stock (usuario_id, producto_id, tipo, cantidad, fecha, devolucion_id)
      values (new.colportor_id, r.prod_id, 'SALIDA_DEVOLUCION_ANULADA', r.cant, now(), new.id);

      perform auditoria.registrar(
        'stock_revertido_por_devolucion_anulada', 'devolucion', new.id, new.colportor_id,
        jsonb_build_object('producto_id', r.prod_id,
                           'cantidad', r.cant,
                           'stock_antes', v_despues + r.cant,
                           'stock_despues', v_despues));
    end loop;

    -- Lo que la devolución sacó de la entrega pendiente vuelve a pendiente (0153, #226): por cada entrega de la que
    -- quitó, lo quitado menos lo que ya se restituyó de esa misma devolución. Las entregas de la venta se toman con
    -- candado, por id, antes de mirar nada.
    perform 1
       from public.entrega e
      where e.venta_id = new.venta_id
      order by e.id
        for update;

    for q in
      select (a.metadata ->> 'entrega_id')::uuid as entrega_id,
             (a.metadata ->> 'producto_id')::uuid as prod_id,
             (sum(case a.event_type
                    when 'entrega_pendiente_quitada_por_devolucion' then (a.metadata ->> 'cantidad')::integer
                    else -(a.metadata ->> 'cantidad')::integer
                  end))::integer as cant,
             bool_or(a.event_type = 'entrega_pendiente_quitada_por_devolucion'
                     and coalesce((a.metadata ->> 'baja')::boolean, false)) as se_dio_de_baja
        from auditoria.audit_log a
       where a.tabla = 'devolucion'
         and a.fila_id = new.id
         and a.event_type in ('entrega_pendiente_quitada_por_devolucion',
                              'entrega_pendiente_restituida_por_anulacion')
         and a.metadata ? 'entrega_id'
       group by 1, 2
      having sum(case a.event_type
                   when 'entrega_pendiente_quitada_por_devolucion' then (a.metadata ->> 'cantidad')::integer
                   else -(a.metadata ->> 'cantidad')::integer
                 end) > 0
       order by 1
    loop
      v_nueva := null;
      select e.* into p from public.entrega e where e.id = q.entrega_id;

      if found and p.venta_id = new.venta_id and p.pendiente and p.deleted_at is null then
        -- La misma entrega, todavía pendiente: recupera lo que perdió.
        update public.entrega set cantidad = cantidad + q.cant where id = p.id;
      elsif found and p.venta_id = new.venta_id and p.pendiente and p.deleted_at is not null
            and q.se_dio_de_baja and p.cantidad = q.cant then
        -- La misma entrega, que la devolución dio de baja entera y nadie tocó: vuelve a vivir con su cantidad.
        update public.entrega set deleted_at = null where id = p.id;
      else
        -- Ya no puede recibirlo (se entregó, se tocó o no está): vuelve como una entrega pendiente nueva.
        v_nueva := public.uuid_generate_v7();
        insert into public.entrega (id, venta_id, producto_id, cantidad, pendiente, fecha_prevista)
        values (v_nueva, new.venta_id, q.prod_id, q.cant, true, p.fecha_prevista);
      end if;

      perform auditoria.registrar(
        'entrega_pendiente_restituida_por_anulacion', 'devolucion', new.id, new.colportor_id,
        case when v_nueva is null
             then jsonb_build_object('producto_id', q.prod_id, 'entrega_id', q.entrega_id, 'cantidad', q.cant)
             else jsonb_build_object('producto_id', q.prod_id, 'entrega_id', q.entrega_id, 'cantidad', q.cant,
                                     'entrega_nueva_id', v_nueva)
        end);
    end loop;
    return null;
  end if;

  -- INSERT. Registrada y anulada sin conexión, y sube todo junto: no hay nada que devolver.
  if new.deleted_at is not null then
    return null;
  end if;

  for r in
    select (e ->> 'producto_id')::uuid as prod_id, (sum((e ->> 'cantidad')::integer))::integer as cant
      from jsonb_array_elements(new.productos_devueltos) e
     group by 1
     order by 1
  loop
    -- Las entregas de este libro en esta venta, tomadas para que dos cambios a la vez no se pisen.
    perform 1
       from public.entrega e
      where e.venta_id = new.venta_id and e.producto_id = r.prod_id
      order by e.id
        for update;

    -- Lo que salió de la mochila: lo entregado de ese libro en la venta, menos lo que otras devoluciones de la
    -- misma venta ya le devolvieron al stock (neto de las anuladas).
    select coalesce(sum(e.cantidad), 0) into v_entregado
      from public.entrega e
     where e.venta_id = new.venta_id and e.producto_id = r.prod_id
       and not e.pendiente and e.deleted_at is null;

    select coalesce(sum(case m.tipo when 'ENTRADA_DEVOLUCION' then m.cantidad else -m.cantidad end), 0)
      into v_ya
      from public.movimiento_stock m
      join public.devolucion d on d.id = m.devolucion_id
     where d.venta_id = new.venta_id and d.id <> new.id
       and m.producto_id = r.prod_id
       and m.deleted_at is null
       and m.tipo in ('ENTRADA_DEVOLUCION', 'SALIDA_DEVOLUCION_ANULADA');

    -- Al stock vuelve solo lo entregado que todavía no volvió; el resto nunca salió: sale de la entrega pendiente.
    v_suma := least(r.cant, greatest(v_entregado - v_ya, 0))::integer;
    v_sale := r.cant - v_suma;

    if v_suma > 0 then
      -- Una fila de stock dada de baja cuenta como cero (como en 0126).
      insert into public.stock as s (usuario_id, producto_id, cantidad_disponible)
      values (new.colportor_id, r.prod_id, v_suma)
      on conflict (usuario_id, producto_id)
      do update set cantidad_disponible = case when s.deleted_at is null then s.cantidad_disponible else 0 end
                                          + excluded.cantidad_disponible,
                    deleted_at = null
      returning s.cantidad_disponible into v_despues;

      insert into public.movimiento_stock (usuario_id, producto_id, tipo, cantidad, fecha, devolucion_id)
      values (new.colportor_id, r.prod_id, 'ENTRADA_DEVOLUCION', v_suma, new.fecha_devolucion, new.id);

      perform auditoria.registrar(
        'stock_devuelto_por_devolucion', 'devolucion', new.id, new.colportor_id,
        jsonb_build_object('producto_id', r.prod_id,
                           'cantidad', v_suma,
                           'stock_antes', v_despues - v_suma,
                           'stock_despues', v_despues));
    end if;

    if v_sale > 0 then
      -- Lo no entregado sale de las entregas pendientes (las más viejas primero): baja su cantidad o, si se la
      -- lleva toda, queda dada de baja. Sin pendiente de donde sacar, no pasa nada. Cada entrega tocada deja su
      -- evento con qué fila fue y cuánto se le sacó: es lo que lee la anulación para restituirla (0153).
      v_resta := v_sale;
      for p in
        select e.id, e.cantidad
          from public.entrega e
         where e.venta_id = new.venta_id and e.producto_id = r.prod_id
           and e.pendiente and e.deleted_at is null
         order by e.created_at, e.id
           for update
      loop
        exit when v_resta <= 0;
        v_toma := least(v_resta, p.cantidad);
        if v_toma = p.cantidad then
          update public.entrega set deleted_at = now() where id = p.id;
        else
          update public.entrega set cantidad = cantidad - v_toma where id = p.id;
        end if;
        v_resta := v_resta - v_toma;

        perform auditoria.registrar(
          'entrega_pendiente_quitada_por_devolucion', 'devolucion', new.id, new.colportor_id,
          jsonb_build_object('producto_id', r.prod_id,
                             'entrega_id', p.id,
                             'cantidad', v_toma,
                             'baja', v_toma = p.cantidad));
      end loop;
    end if;
  end loop;
  return null;
end;
$$;

comment on function public.tg_devolucion_devuelve_stock() is
  'AFTER INSERT OR UPDATE OF deleted_at de devolucion (0136, 0142, 0148, 0153, #201, #221 y #226, ADR-002 efecto 2). '
  'INSERT: por libro, suma al stock del colportor solo lo entregado de esa venta que otras devoluciones no '
  'devolvieron ya (movimiento ENTRADA_DEVOLUCION y evento stock_devuelto_por_devolucion); lo no entregado nunca '
  'salió del stock y sale de la entrega pendiente (baja su cantidad o la da de baja) con un evento '
  'entrega_pendiente_quitada_por_devolucion por cada entrega tocada (entrega_id, cantidad, baja). Una devolución que '
  'entra anulada no mueve nada. UPDATE que anula (deleted_at de null a una fecha): resta lo que sumó con '
  'SALIDA_DEVOLUCION_ANULADA y devuelve a pendiente lo que quitó (la misma entrega, o una nueva si ya no puede '
  'recibirlo; evento entrega_pendiente_restituida_por_anulacion), sin duplicar si se anula dos veces. Nunca rechaza.';

-- ----------------------------------------------------------------------------
-- Una devolución anulada no se reabre
-- ----------------------------------------------------------------------------

create function public.tg_devolucion_no_se_reabre()
returns trigger
language plpgsql
volatile
set search_path = ''
as $$
begin
  if old.deleted_at is not null and new.deleted_at is null then
    raise exception 'Una devolución anulada no se reabre: registrá una nueva.'
      using errcode = '42501';
  end if;
  return new;
end;
$$;

comment on function public.tg_devolucion_no_se_reabre() is
  'BEFORE UPDATE OF deleted_at de devolucion (0153, #226): una devolución anulada no vuelve a estar viva (42501): '
  'reabrirla dejaría una devolución viva con las entregas pendientes ya restituidas y sin volver a sumar el stock. '
  'Pasar de una fecha de baja a otra no es reabrirla y pasa.';

revoke all on function public.tg_devolucion_no_se_reabre() from public, anon, authenticated, service_role;

create trigger devolucion_no_se_reabre
  before update of deleted_at on public.devolucion
  for each row execute function public.tg_devolucion_no_se_reabre();
