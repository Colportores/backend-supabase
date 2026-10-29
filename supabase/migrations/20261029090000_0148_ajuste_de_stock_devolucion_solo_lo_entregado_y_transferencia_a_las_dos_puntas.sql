-- ============================================================================
-- 0148 · Stock y transferencias con las respuestas del 28/10: el colportor ajusta su stock desde el teléfono, la
--        devolución suma al stock solo lo que se entregó, la transferencia baja a las dos puntas y quien la pidió
--        la puede cancelar (backend-supabase#221, seguimiento de #147 / 0118, #201 / 0136 y 0139, y #106 / 0126)
--
-- Origen: las decisiones de Cristian del 28/10 «Ajuste stock», «Devol. s/ent», «Ver transf.» y «Cancelar tr.».
-- Esta migración SOLO SUMA o redefine con `create or replace`: ninguna fila de negocio cambia (las filas de
-- `transferencia_stock` y `transferencia_item` que ya había se «tocan» una vez para que bajen a la otra punta).
--
-- ## 1. «Ajuste stock»: la colportora ajusta su stock desde el teléfono
--
-- Caso: Mariela arranca la campaña con 10 libros que trajo encima, sin ningún pedido; cada entrega se marcaba como
-- inconsistente («Sin stock», 27/10). Desde el teléfono registra un ajuste de +10 con el motivo «Stock inicial»,
-- y su stock pasa de 0 a 10. Si un libro se le dañó, ajusta -1 con «Libros dañados»; si cuenta y le faltan 2,
-- ajusta -2 con «Conteo».
--
--   · `movimiento_stock` gana el tipo `AJUSTE` y la columna `motivo`. Para el ajuste la `cantidad` lleva signo
--     (positiva sube el stock, negativa lo baja; cero no es un ajuste): los demás tipos siguen con cantidad mayor
--     que cero y el tipo dice para qué lado van. El `motivo` es un código de una lista (`STOCK_INICIAL`,
--     `LIBROS_DANIADOS`, `CONTEO`), obligatorio en un ajuste y nulo en cualquier otro movimiento: NO hay texto
--     libre que salga del teléfono.
--   · `movimiento_stock` entra al motor de sync como entidad de PUSH (y pull de las propias, `usuario_id`): el
--     teléfono solo INSERTA un movimiento de tipo `AJUSTE` de su propio stock. Lo demás lo pone el servidor:
--     `usuario_id` sale del JWT, `fecha` es cuándo LLEGÓ (como el pedido, 0124) y ningún origen (pedido,
--     transferencia, entrega, devolución) se elige desde el teléfono. Sin UPDATE ni DELETE: un ajuste no se edita,
--     se corrige con otro ajuste. Un reintento (replay del push) no suma dos veces: el `ON CONFLICT DO NOTHING`
--     no dispara el trigger de después.
--   · El stock se recalcula con el ajuste (AFTER INSERT, SECURITY DEFINER, mismo criterio de 0118/0136: una fila de
--     stock dada de baja cuenta como cero) y queda el evento `stock_ajustado` en `audit_log` (ids y números; el
--     motivo es un código). Puede dejar el stock en negativo, como todo el resto (S46). Un ajuste que llega ya dado
--     de baja (`deleted_at`) queda registrado y no mueve nada.
--   · La coordinadora lo ve en el historial de la vista 34 (casilla en front-coordinadores-web#91) con la lectura
--     que ya tiene (`movimiento_stock_select`, 0067). La pantalla del teléfono va en front-colportores-mobile#549.
--
-- ## 2. «Devol. s/ent»: la devolución suma solo lo entregado
--
-- Caso: Lucía vendió 3 libros a Pedro, entregó 1 y registra la devolución de los 3. Al stock vuelve 1 (lo que
-- había salido); los otros 2 nunca salieron de su mochila, así que NO suman al stock: salen de la entrega pendiente
-- (esa entrega por hacer baja de 2 a 0 y queda dada de baja).
--
--   · `tg_devolucion_devuelve_stock` (INSERT): por libro de la devolución, lo entregado es la suma de las `entrega`
--     vivas de esa venta y ese libro que ya no están pendientes, menos lo que otras devoluciones de la misma venta
--     ya devolvieron al stock (neto de las anuladas). El stock suma `least(devuelto, entregado - ya_devuelto)`; el
--     resto sale de las entregas pendientes de esa venta y ese libro (las más viejas primero: baja su cantidad o,
--     si se lleva toda, queda dada de baja). Si ya no hay pendiente de donde sacar, no pasa nada: la devolución
--     nunca se rechaza por esto.
--   · La entrega pendiente que se recorta deja el evento `entrega_pendiente_quitada_por_devolucion` (ids y números).
--   · Anular la devolución (0142) sigue restando solo lo que sumó: no cambia. Volver a poner en la entrega pendiente
--     lo que se quitó queda en el archivo de pendientes de esta entrega.
--   · Una devolución que ya no suma todo el stock (porque no se entregó) no deja un movimiento por esa parte.
--
-- ## 3. «Ver transf.»: la transferencia baja a las dos puntas
--
-- Caso: Marta arma desde el panel una transferencia de 2 libros de Ana a Juan. Hasta ahora no le llegaba a ninguno
-- de los dos hasta autorizarse (el pull de `transferencia_stock` y `transferencia_item` solo bajaba las del
-- solicitante, y la que arma el coordinador no tiene solicitante). Desde ahora baja a quien da y a quien recibe,
-- con su estado (por autorizar, autorizada, rechazada, cancelada), la arme quien la arme.
--
--   · `sync.entidad.columna_duenio` admite una LISTA de columnas separadas por coma: la fila baja si el usuario es
--     cualquiera de ellas (`sync.pull` arma `(t.a = $4 or t.b = $4)`; con una sola columna es igual que antes).
--     `transferencia_stock` y `transferencia_item` pasan a `origen_id,destino_id`.
--   · `transferencia_item` gana `origen_id` y `destino_id`, copiadas del encabezado por el trigger de 0139 (como
--     `solicitante_id`) para que el pull filtre por columnas de la propia tabla; las líneas que ya había se
--     completan. Son del servidor (`columnas_servidor`): el teléfono no las manda.
--   · Índices del delta con el dueño primero (uno por punta) en las dos tablas.
--   · La RLS de lectura no cambia (0067): las dos puntas, el coordinador de cada una y el ADMIN. Lo que baja al
--     teléfono de un coordinador sigue siendo solo lo suyo: si es una de las puntas.
--   · Las filas que ya existían se tocan una vez (sube su versión) para que la otra punta las reciba: de otro modo
--     quedarían debajo de su cursor.
--   · La acción pasa a llamarse «Pedir transferencia de materiales» (panel: front-coordinadores-web#91; teléfono:
--     front-colportores-mobile#512): es un cambio de texto de las pantallas, no de la base.
--
-- ## 4. «Cancelar tr.»: quien pidió la transferencia la puede cancelar
--
-- Caso: Ana pidió 2 libros a Beto y se arrepiente antes de que Marta decida. Desde el teléfono pasa su
-- transferencia a CANCELADO. Como en los pedidos (0124, «Cancelar ped»):
--
--   · El teléfono solo cambia el `estado` de SU transferencia (la que pidió: `solicitante_id`), de
--     `PENDIENTE_AUTORIZACION` a `CANCELADO`, con un UPDATE del push (privilegio por columna y política propia).
--     Autorizada, rechazada o ya cancelada, el teléfono ya no la toca (42501 con el aviso de qué hacer). Una
--     transferencia no se borra: se cancela. La que arma el coordinador (sin solicitante) la cancela él.
--   · Sin conflicto de versión: nada del servidor toca el encabezado entre el alta y la cancelación (las líneas no
--     lo recalculan), así que el UPDATE del push lleva la versión que el teléfono tiene. Si el coordinador la
--     decidió mientras tanto, la versión quedó vieja y el push vuelve `conflict` con la fila del servidor.
--   · El alta que nace `CANCELADO` (la colportora pidió y canceló sin conexión: el motor funde la cancelación en el
--     alta) se acepta como en los pedidos, sin pedir que el otro sea compañero de campaña, y sus líneas entran como
--     parte de una transferencia cancelada, sin ningún efecto.
--   · Autorizar y rechazar siguen exigiendo `PENDIENTE_AUTORIZACION` (TR002): una cancelada no se puede autorizar.
--
-- ## Para otros repos
--
--   · front-colportores-mobile#549: entidad `movimiento_stock` (push de `AJUSTE` + pull de los propios) con
--     `{ id, producto_id, tipo: 'AJUSTE', cantidad (con signo), motivo }`; `invalid` con 23514 (cantidad cero,
--     motivo fuera de la lista o faltante) y 42501 (otro tipo de movimiento).
--   · front-colportores-mobile#512: las transferencias bajan a las dos puntas; cancelar es un update
--     `{ id, estado: 'CANCELADO' }` con la `sync_version` que tiene (42501 si ya no está por autorizar).
--   · front-coordinadores-web#91: el historial de la vista 34 incluye los `AJUSTE` (cantidad con signo y motivo).
--   · docs-organizacion: esquema-datos.md, contrato-sync-engine.md §2 (lista en `columna_duenio`) y HU-STK-005,
--     HU-STK-007 y HU-VEN-004: se piden en el cuerpo del PR.
--
-- Forward-only: esta migración no se edita una vez aplicada.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. Ajuste de stock desde el teléfono
-- ----------------------------------------------------------------------------

alter table public.movimiento_stock
  add column motivo text;

alter table public.movimiento_stock
  drop constraint movimiento_stock_tipo_check;
alter table public.movimiento_stock
  add constraint movimiento_stock_tipo_check
  check (tipo in ('ENTRADA_PEDIDO', 'SALIDA_ENTREGA', 'SALIDA_TRANSFERENCIA', 'ENTRADA_TRANSFERENCIA',
                  'ENTRADA_ENTREGA_ANULADA', 'ENTRADA_ENTREGA_CORREGIDA', 'ENTRADA_DEVOLUCION',
                  'SALIDA_DEVOLUCION_ANULADA', 'AJUSTE'));

-- La cantidad es siempre positiva salvo en el ajuste, que lleva signo (cero no es un ajuste).
alter table public.movimiento_stock
  drop constraint movimiento_stock_cantidad_check;
alter table public.movimiento_stock
  add constraint movimiento_stock_cantidad_check
  check ((tipo = 'AJUSTE' and cantidad <> 0) or (tipo <> 'AJUSTE' and cantidad > 0));

-- El motivo: un código de una lista, obligatorio en el ajuste y nulo en cualquier otro movimiento. (`is not null`
-- explícito: `null in (...)` es null y un CHECK null PASA.)
alter table public.movimiento_stock
  add constraint movimiento_stock_motivo_check
  check ((tipo = 'AJUSTE' and motivo is not null and motivo in ('STOCK_INICIAL', 'LIBROS_DANIADOS', 'CONTEO'))
         or (tipo <> 'AJUSTE' and motivo is null));

comment on column public.movimiento_stock.motivo is
  'Por qué se ajustó el stock (solo en un AJUSTE, 0148): STOCK_INICIAL, LIBROS_DANIADOS o CONTEO. Un código de '
  'una lista, nunca texto libre. Nulo en los demás movimientos.';
comment on column public.movimiento_stock.cantidad is
  'Cuántas unidades. Mayor que cero en todos los tipos, y el tipo dice para qué lado va; salvo el AJUSTE (0148), '
  'que lleva signo: positiva sube el stock, negativa lo baja.';
comment on table public.movimiento_stock is
  'Histórico de cambios de stock del colportor (V2): entrada por pedido recibido, salida por entrega o por '
  'transferencia, las entradas de lo que se deshace (entrega anulada o corregida, libros devueltos) y, desde '
  '0148, el AJUSTE que la colportora registra desde el teléfono (cantidad con signo y motivo de una lista).';

-- La dueña del movimiento por default: el payload no la manda (columnas_servidor), sale del JWT.
alter table public.movimiento_stock
  alter column usuario_id set default auth.uid();

-- El delta con el dueño primero, para que el predicado entre en el Index Cond (0002 §14).
create index movimiento_stock_delta_idx on public.movimiento_stock (usuario_id, xmin_w, id);

-- Qué decide el servidor sobre un movimiento que llega del teléfono. Los BEFORE corren aun para una fila que el
-- push no inserta porque ya existía (INSERT ... ON CONFLICT DO NOTHING): si el movimiento ya está, no se valida
-- otra vez. El servidor (service_role, una función DEFINER, el editor SQL) no pasa por acá.
create function public.tg_movimiento_stock_del_cliente()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if current_user not in ('authenticated', 'anon') then
    return new;
  end if;

  -- Lo que decide el servidor (también llega descartado del payload: columnas_servidor). Va antes que el
  -- reintento: la RLS de alta mira `usuario_id`, y la mira antes del ON CONFLICT.
  new.usuario_id := auth.uid();
  new.fecha := now();
  new.pedido_id := null;
  new.transferencia_id := null;
  new.entrega_id := null;
  new.devolucion_id := null;

  if exists (select 1 from public.movimiento_stock m where m.id = new.id) then
    return new;
  end if;

  if new.tipo is distinct from 'AJUSTE' then
    raise exception 'Desde el teléfono solo se registra un ajuste de tu stock. Los demás movimientos los hace el sistema.'
      using errcode = '42501';
  end if;
  return new;
end;
$$;

comment on function public.tg_movimiento_stock_del_cliente() is
  'BEFORE INSERT de movimiento_stock, solo para authenticated (0148): desde el teléfono solo entra un AJUSTE de '
  'su propio stock (42501 si no); el servidor fija la dueña, la fecha (cuándo llegó) y deja sin origen el '
  'movimiento. El servidor no pasa por acá.';

revoke all on function public.tg_movimiento_stock_del_cliente() from public, anon, authenticated, service_role;

create trigger movimiento_stock_del_cliente
  before insert on public.movimiento_stock
  for each row execute function public.tg_movimiento_stock_del_cliente();

-- El ajuste mueve el stock. DEFINER: el push corre INVOKER y no escribe `stock` (sin políticas de escritura).
-- Solo corre para filas que de verdad entraron (un replay no vuelve a sumar).
create function public.tg_movimiento_stock_ajusta_el_stock()
returns trigger
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_despues integer;
begin
  if new.tipo <> 'AJUSTE' or new.deleted_at is not null then
    return null;
  end if;

  -- Una fila de stock dada de baja cuenta como cero (como en 0126 y 0136).
  insert into public.stock as s (usuario_id, producto_id, cantidad_disponible)
  values (new.usuario_id, new.producto_id, new.cantidad)
  on conflict (usuario_id, producto_id)
  do update set cantidad_disponible = case when s.deleted_at is null then s.cantidad_disponible else 0 end
                                      + excluded.cantidad_disponible,
                deleted_at = null
  returning s.cantidad_disponible into v_despues;

  perform auditoria.registrar(
    'stock_ajustado', 'movimiento_stock', new.id, new.usuario_id,
    jsonb_build_object('producto_id', new.producto_id,
                       'cantidad', new.cantidad,
                       'motivo', new.motivo,
                       'stock_antes', v_despues - new.cantidad,
                       'stock_despues', v_despues));
  return null;
end;
$$;

comment on function public.tg_movimiento_stock_ajusta_el_stock() is
  'AFTER INSERT de movimiento_stock (0148, #221): un AJUSTE suma su cantidad (con signo) al stock del colportor, '
  'que puede quedar en negativo (S46), y deja el evento stock_ajustado en audit_log. Un ajuste que entra dado de '
  'baja no mueve nada. Nunca rechaza.';

revoke all on function public.tg_movimiento_stock_ajusta_el_stock() from public, anon, authenticated, service_role;

create trigger movimiento_stock_ajusta_el_stock
  after insert on public.movimiento_stock
  for each row execute function public.tg_movimiento_stock_ajusta_el_stock();

-- RLS y privilegios: el teléfono INSERTA su ajuste y nada más (sin UPDATE ni DELETE). Privilegios por columna: el
-- teléfono escribe solo lo que el servidor no decide.
create policy movimiento_stock_insert_propio on public.movimiento_stock
  for insert to authenticated
  with check (usuario_id = (select auth.uid())
              and tipo = 'AJUSTE');

grant insert (id, producto_id, tipo, cantidad, motivo, created_at, deleted_at)
  on public.movimiento_stock to authenticated;

-- El registro en el motor de sync: push del ajuste y pull de los movimientos propios.
insert into sync.entidad (nombre, tabla, columna_pk, permite_push, columna_duenio) values
  ('movimiento_stock', 'public.movimiento_stock'::regclass, 'id', true, 'usuario_id');

update sync.entidad
   set columnas_servidor = columnas_servidor
       || array['usuario_id', 'fecha', 'pedido_id', 'transferencia_id', 'entrega_id', 'devolucion_id']
 where nombre = 'movimiento_stock';

-- ----------------------------------------------------------------------------
-- 2. La devolución suma al stock solo lo entregado
-- ----------------------------------------------------------------------------

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
  v_despues   integer;
  v_entregado bigint;
  v_ya        bigint;
  v_suma      integer;
  v_sale      integer;
  v_resta     integer;
  v_toma      integer;
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
      -- lleva toda, queda dada de baja. Sin pendiente de donde sacar, no pasa nada.
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
      end loop;

      if v_sale - v_resta > 0 then
        perform auditoria.registrar(
          'entrega_pendiente_quitada_por_devolucion', 'devolucion', new.id, new.colportor_id,
          jsonb_build_object('producto_id', r.prod_id,
                             'cantidad', v_sale - v_resta));
      end if;
    end if;
  end loop;
  return null;
end;
$$;

comment on function public.tg_devolucion_devuelve_stock() is
  'AFTER INSERT OR UPDATE OF deleted_at de devolucion (0136, 0142, 0148, #201 y #221, ADR-002 efecto 2). INSERT: '
  'por libro, suma al stock del colportor solo lo entregado de esa venta que otras devoluciones no devolvieron ya '
  '(movimiento ENTRADA_DEVOLUCION y evento stock_devuelto_por_devolucion); lo no entregado nunca salió del stock '
  'y sale de la entrega pendiente (baja su cantidad o la da de baja; evento '
  'entrega_pendiente_quitada_por_devolucion). Una devolución que entra anulada no mueve nada. UPDATE que anula '
  '(deleted_at de null a una fecha): resta lo que sumó con SALIDA_DEVOLUCION_ANULADA. Nunca rechaza.';

-- ----------------------------------------------------------------------------
-- 3. La transferencia baja a las dos puntas
-- ----------------------------------------------------------------------------

alter table public.transferencia_item
  add column origen_id  uuid references public.usuario(id),
  add column destino_id uuid references public.usuario(id);

comment on column public.transferencia_item.origen_id is
  'Quien da los libros: el origen de la transferencia, copiado del encabezado por un trigger (0148). Existe para '
  'que el pull filtre por una columna de la propia tabla; el teléfono no la manda.';
comment on column public.transferencia_item.destino_id is
  'Quien recibe los libros: el destino de la transferencia, copiado del encabezado por un trigger (0148). Existe '
  'para que el pull filtre por una columna de la propia tabla; el teléfono no la manda.';

-- Las líneas que ya había. (La actualización sube su versión y su xmin_w: las recibe quien todavía no las tenía.)
update public.transferencia_item i
   set origen_id = t.origen_id,
       destino_id = t.destino_id
  from public.transferencia_stock t
 where t.id = i.transferencia_id;

-- Los encabezados que ya había: se tocan una vez para que bajen a la otra punta (de otro modo quedarían debajo de
-- su cursor). No cambia ningún valor.
update public.transferencia_stock
   set deleted_at = deleted_at;

-- Índices del delta con el dueño primero, uno por punta (el pull busca `origen_id = $4 or destino_id = $4`).
create index transferencia_stock_delta_origen_idx on public.transferencia_stock (origen_id, xmin_w, id);
create index transferencia_stock_delta_destino_idx on public.transferencia_stock (destino_id, xmin_w, id);
create index transferencia_item_delta_origen_idx on public.transferencia_item (origen_id, xmin_w, id);
create index transferencia_item_delta_destino_idx on public.transferencia_item (destino_id, xmin_w, id);

-- Por todo camino (el teléfono, el servidor, los tests): las puntas de la línea son las del encabezado, como su
-- solicitante. DEFINER para leer el encabezado aunque la RLS lo esconda (una línea de una transferencia ajena o
-- inexistente queda en null y la frena la RLS o la FK).
create or replace function public.tg_transferencia_item_solicitante()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  select t.solicitante_id, t.origen_id, t.destino_id
    into new.solicitante_id, new.origen_id, new.destino_id
    from public.transferencia_stock t
   where t.id = new.transferencia_id;
  return new;
end;
$$;

comment on function public.tg_transferencia_item_solicitante() is
  'BEFORE INSERT de transferencia_item (0139, 0148): solicitante_id, origen_id y destino_id son los de la '
  'transferencia, venga de donde venga la línea.';

-- La columna del dueño pasa a ser una lista; el pull baja la fila si el usuario es cualquiera de las columnas.
update sync.entidad
   set columna_duenio = 'origen_id,destino_id'
 where nombre in ('transferencia_stock', 'transferencia_item');

update sync.entidad
   set columnas_servidor = columnas_servidor || array['origen_id', 'destino_id']
 where nombre = 'transferencia_item';

comment on column sync.entidad.columna_duenio is
  'Columna(s) con el usuario dueño de la fila (0014, 0148): si está, el pull baja solo las filas donde esa columna '
  'es el usuario autenticado. Puede ser una lista separada por coma (origen_id,destino_id): baja la fila si el '
  'usuario es cualquiera de ellas.';

-- El pull con la columna del dueño como lista. Misma firma y cuerpo que en 0023; solo cambia el filtro por
-- `columna_duenio`. Los privilegios de sync.pull (0011) siguen: create or replace los conserva.
create or replace function sync.pull(
  p_entidades text[],
  p_watermark jsonb default '{}'::jsonb,
  p_limite    integer default 500,
  p_device    uuid default null,
  p_alcance   text default null
)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_entidad   text;
  v_tabla     regclass;
  v_pk_col    text;
  v_col_ubic  text;
  v_desde     jsonb;
  v_lote      jsonb;
  v_filas     jsonb;
  v_rows      jsonb := '{}'::jsonb;
  v_nuevo     jsonb := coalesce(p_watermark, '{}'::jsonb);
  v_hay_mas   boolean := false;
  v_ultima    jsonb;
  v_horizonte xid8;
  v_limite    integer;
  v_arranque  timestamptz := clock_timestamp();
  v_total     integer := 0;
  v_salida    jsonb;
  v_usuario   uuid := auth.uid();
  v_ciudades  uuid[];
  v_huella    text;
  v_filtro    text;
  v_marca     jsonb;
  v_sigue     boolean;
  v_huella_mapa text;
  v_col_duenio text;
  v_fuera     jsonb := '{}'::jsonb;
  v_reinicio  text[] := array[]::text[];
  v_ids       jsonb;
  v_previas   text[];
  v_reiniciar boolean;
begin
  if v_usuario is null then
    raise exception 'sync.pull requiere un usuario autenticado'
      using errcode = 'insufficient_privilege';
  end if;

  -- Un límite fuera de rango es un cliente roto o un abuso: se acota y se sigue (0002).
  v_limite := least(greatest(coalesce(p_limite, 500), 1), 1000);

  -- Una sola vez para todas las entidades: el corte es el mismo para todas (0002).
  v_horizonte := pg_snapshot_xmin(pg_current_snapshot());

  foreach v_entidad in array coalesce(p_entidades, array[]::text[]) loop
    select e.tabla, e.columna_pk, e.columna_ubicacion, e.sigue_campanias, e.columna_duenio
      into v_tabla, v_pk_col, v_col_ubic, v_sigue, v_col_duenio
      from sync.entidad e where e.nombre = v_entidad;
    -- Una entidad que el servidor no conoce se ignora (0002).
    continue when v_tabla is null;

    -- Un watermark sin `xid` arranca de cero (0002).
    v_desde := coalesce(p_watermark -> v_entidad, '{}'::jsonb);
    v_filtro := '';
    v_marca := '{}'::jsonb;

    -- Alcance (0011, 0023): la fila baja si su ubicación la registró él o está en una de sus
    -- ciudades de trabajo (toda la ciudad de su zona; sin zona, todas las de su campaña).
    if v_col_ubic is not null then
      if v_huella is null then
        select a.ciudades, a.huella
          into v_ciudades, v_huella
          from sync.area_del_pull() a;
      end if;

      -- La lista de ciudades que guardó el watermark (0023); el motor lo devuelve tal cual. Algo que
      -- no es una lista cuenta como ausente. Se compara como texto: un elemento raro es una ciudad
      -- que la lista no tenía, y eso solo puede bajar de más, nunca de menos.
      v_previas := null;
      if jsonb_typeof(v_desde -> 'ciudades') = 'array' then
        v_previas := array(select jsonb_array_elements_text(v_desde -> 'ciudades'));
      end if;

      -- Con lista: la entidad baja completa solo si apareció una ciudad que el watermark no tenía
      -- (sus filas pueden ser más viejas que el cursor). Lista igual o más chica: el delta sigue, y lo
      -- que quedó afuera deja de actualizarse sin borrarse. Sin lista (un teléfono de antes de 0023,
      -- o con otro alcance): la huella, como antes; ahí hay un solo reinicio y el watermark nuevo
      -- ya lleva la lista.
      if v_previas is not null then
        v_reiniciar := not (v_ciudades::text[] <@ v_previas);
      else
        v_reiniciar := (v_desde ->> 'area') is distinct from v_huella;
      end if;

      -- Si había un watermark de antes, se avisa en area_reset (0016): el área creció y esta
      -- entidad vuelve a bajar desde cero; la ciudad que ya no es suya no se actualiza (el motor no
      -- borra nada de lo que ya tiene).
      if v_reiniciar then
        if v_desde ? 'xid' then
          v_reinicio := v_reinicio || v_entidad;
        end if;
        v_desde := '{}'::jsonb;
      end if;
      -- La lista de ahora, siempre: es la que cuenta en el pull siguiente.
      v_marca := jsonb_build_object('area', v_huella, 'ciudades', to_jsonb(v_ciudades));

      -- Por fila, contra la ubicación (su PK).
      v_filtro := format(
        'and exists (select 1 from public.ubicacion u where u.id = t.%I'
        ' and (u.created_by = $4 or u.ciudad_id = any ($5)))', v_col_ubic);

    -- El mapa (0013): qué filas ve depende de sus campañas (las que coordina y las que no
    -- terminaron en las que está inscripto). Si cambiaron desde su último pull (terminó una
    -- campaña, lo inscribieron, le dieron una campaña para coordinar), la entidad baja completa: esas
    -- filas pueden ser más viejas que su watermark. La RLS decide qué filas; acá no hay filtro.
    elsif v_sigue then
      if v_huella_mapa is null then
        v_huella_mapa := sync.huella_del_mapa();
      end if;
      if (v_desde ->> 'area') is distinct from v_huella_mapa then
        v_desde := '{}'::jsonb;
      end if;
      v_marca := jsonb_build_object('area', v_huella_mapa);
    end if;

    -- Solo las filas propias (0014): la RLS le puede mostrar más (el coordinador y el ADMIN
    -- ven todas las inscripciones), pero al teléfono baja solo lo suyo. Usa el índice
    -- (dueño, xmin_w, id).
    -- Desde 0148 la columna puede ser una lista separada por coma (origen_id,destino_id): la fila baja si el
    -- usuario es cualquiera de ellas.
    if v_col_duenio is not null then
      v_filtro := v_filtro || (select ' and (' || string_agg(format('t.%I = $4', c), ' or ' order by c) || ')'
                                 from unnest(string_to_array(v_col_duenio, ',')) c);
    end if;

    -- Una fila de más para saber si hay más; el xmin_w viaja al lado de la fila (0002).
    execute format($q$
      select coalesce(jsonb_agg(jsonb_build_object('j', j, 'xw', xw::text, 'id', id)
                                order by xw, id), '[]'::jsonb)
      from (
        select %s as j, t.xmin_w as xw, t.%I as id
        from %s t
        where t.xmin_w < $3
          and (t.xmin_w, t.%I) > ($1::xid8, $2::uuid)
          %s
        order by t.xmin_w, t.%I
        limit %s
      ) s
    $q$,
      sync.expresion_json(v_tabla), v_pk_col, v_tabla, v_pk_col, v_filtro, v_pk_col,
      (v_limite + 1)::text)
    into v_lote
    using coalesce(v_desde ->> 'xid', '0'),
          coalesce(v_desde ->> 'id', '00000000-0000-0000-0000-000000000000')::uuid,
          v_horizonte, v_usuario, v_ciudades;

    if jsonb_array_length(v_lote) = 0 then
      -- Con huella (área o mapa), nada debajo del horizonte: todo lo de abajo ya se revisó,
      -- así que el cursor pasa al horizonte (lo que venga tiene un xmin_w mayor o igual) y la
      -- huella, con la lista de ciudades, queda guardada. Sin esto, un área vacía se recorre
      -- entera en cada pull, y el watermark sin la huella nueva haría bajar completa la entidad
      -- otra vez.
      if v_marca <> '{}'::jsonb then
        v_nuevo := v_nuevo || jsonb_build_object(v_entidad,
          jsonb_build_object('xid', v_horizonte::text, 'id', '00000000-0000-0000-0000-000000000000')
          || v_marca);
      end if;
    else
      if jsonb_array_length(v_lote) > v_limite then
        v_hay_mas := true;
        v_lote := (select jsonb_agg(e) from (
          select e from jsonb_array_elements(v_lote) e limit v_limite
        ) s);
      end if;

      v_filas := (select jsonb_agg(e -> 'j') from jsonb_array_elements(v_lote) e);

      -- Una entidad ausente de `rows` significa "sin cambios" (0002).
      v_rows := v_rows || jsonb_build_object(v_entidad, v_filas);
      v_total := v_total + jsonb_array_length(v_filas);

      v_ultima := v_lote -> (jsonb_array_length(v_lote) - 1);
      v_nuevo := v_nuevo || jsonb_build_object(v_entidad,
        jsonb_build_object('xid', v_ultima ->> 'xw', 'id', v_ultima ->> 'id') || v_marca);
    end if;

    -- Lo que salió del área (0016, 0023): las ubicaciones que el teléfono tenía en una de sus
    -- ciudades al último pull y ya no están, porque cambiaron de ciudad en el mismo tramo del
    -- cursor que esta respuesta cubre: del watermark que llegó al nuevo. Solo en delta (con el
    -- área de antes): si el área cambió, la entidad baja completa y va en area_reset.
    if v_tabla = 'public.ubicacion'::regclass and (v_desde ? 'xid') and ((v_nuevo -> v_entidad) ? 'xid') then
      select coalesce(jsonb_agg(s.id order by s.id), '[]'::jsonb)
        into v_ids
        from public.ubicaciones_que_salieron(
               (v_desde ->> 'xid')::xid8,
               coalesce(v_desde ->> 'id', '00000000-0000-0000-0000-000000000000')::uuid,
               (v_nuevo -> v_entidad ->> 'xid')::xid8,
               (v_nuevo -> v_entidad ->> 'id')::uuid) s (id);
      if jsonb_array_length(v_ids) > 0 then
        v_fuera := v_fuera || jsonb_build_object(v_entidad, v_ids);
      end if;
    end if;
  end loop;

  v_salida := jsonb_build_object(
    'server_time', to_char(now() at time zone 'utc', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"'),
    'watermark', v_nuevo,
    'has_more', v_hay_mas,
    'rows', v_rows
  );
  -- Claves nuevas (0016), solo si hay algo: una respuesta sin avisos es igual que antes.
  if v_fuera <> '{}'::jsonb then
    v_salida := v_salida || jsonb_build_object('out_of_area', v_fuera);
  end if;
  if cardinality(v_reinicio) > 0 then
    v_salida := v_salida || jsonb_build_object('area_reset', to_jsonb(v_reinicio));
  end if;

  -- Un pull sin novedades no escribe nada: tomaría un xid y frenaría el horizonte de todos (0002).
  if v_total > 0 then
    insert into sync.log (device_id, operacion, duracion_ms, entidades, filas, hay_mas, bytes_salida)
    values (p_device, 'pull',
            extract(epoch from clock_timestamp() - v_arranque) * 1000,
            p_entidades, v_total, v_hay_mas, octet_length(v_salida::text));
  end if;

  return v_salida;
end;
$$;

comment on function sync.pull(text[], jsonb, integer, uuid, text) is
  'Delta por (xmin_w, id) con la RLS del que llama (0002). ubicacion, espacio y house_status bajan '
  'siempre por toda la ciudad de su zona (sin zona, todas las ciudades de su campaña) más lo que '
  'registró él, sin elección (0023, HU-SYNC-011). Su watermark lleva la huella y la lista de '
  'ciudades: bajan completas solo si apareció una ciudad que la lista no tenía; si la lista se '
  'achica, el delta sigue. p_alcance se acepta por compatibilidad y se ignora. El mapa (campania_ciudad, zona, '
  'zona_vertice) baja completo si cambiaron las campañas que ve (0013). Las entidades con '
  'columna_duenio bajan solo las filas del usuario autenticado (0014); si la columna es una lista separada por '
  'coma, las filas donde el usuario es cualquiera de ellas (0148). out_of_area: las ubicaciones '
  'que cambiaron de ciudad en el tramo; area_reset: las entidades que arrancaron de cero porque '
  'cambió el área (0016).';

-- ----------------------------------------------------------------------------
-- 4. Quien pidió la transferencia la puede cancelar
-- ----------------------------------------------------------------------------

-- ¿Por qué no se le pueden sumar líneas a esta transferencia de QUIEN LLAMA? (0139; desde 0148 una cancelada
-- también las acepta, como el pedido, 0124: el motor funde en el alta la cancelación hecha sin conexión.)
create or replace function public.transferencia_no_acepta_lineas(p_transferencia_id uuid)
returns text
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_solicitante uuid;
  v_estado      text;
begin
  select t.solicitante_id, t.estado into v_solicitante, v_estado
    from public.transferencia_stock t
   where t.id = p_transferencia_id and t.deleted_at is null
     for share;
  if v_solicitante is null or v_solicitante is distinct from (select auth.uid()) then
    return 'AJENA';
  end if;
  if v_estado not in ('PENDIENTE_AUTORIZACION', 'CANCELADO') then
    return 'ESTADO';
  end if;
  return null;
end;
$$;

comment on function public.transferencia_no_acepta_lineas(uuid) is
  'null si a esta transferencia de quien llama (auth.uid()) se le pueden sumar líneas; AJENA si es de otro o no '
  'existe; ESTADO si ya fue decidida (0139, 0148: una por autorizar o cancelada las acepta). Candado compartido '
  'sobre la transferencia. Interna.';

-- Alta: nace por autorizar o, si la colportora la canceló antes de que subiera, cancelada.
create or replace function public.tg_transferencia_stock_del_cliente()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_otro uuid;
begin
  -- El servidor (service_role, el editor SQL, una función DEFINER) no pasa por acá. El push corre INVOKER como
  -- `authenticated` (patrón de 0053, 0100, 0113, 0122 y 0124).
  if current_user not in ('authenticated', 'anon') then
    return new;
  end if;

  -- Lo que decide el servidor (también llega descartado del payload: columnas_servidor). Va antes que el
  -- reintento: la RLS de alta mira `solicitante_id`, y la mira antes del ON CONFLICT.
  new.solicitante_id := auth.uid();
  new.coordinador_id := null;
  new.monto_deuda := null;
  new.decidido_en := null;
  new.motivo_rechazo := null;
  new.fecha_solicitud := now();

  if exists (select 1 from public.transferencia_stock t where t.id = new.id) then
    return new;
  end if;

  if new.estado is distinct from 'PENDIENTE_AUTORIZACION' and new.estado is distinct from 'CANCELADO' then
    raise exception 'La transferencia se pide para que la autorice tu coordinador. Pedila desde la pantalla de transferencias.'
      using errcode = '23514', constraint = 'transferencia_del_colportor_nace_por_autorizar';
  end if;

  if new.origen_id is distinct from auth.uid() and new.destino_id is distinct from auth.uid() then
    raise exception 'Solo podés pedir una transferencia en la que vos das o recibís los libros.'
      using errcode = '42501';
  end if;

  -- Nació cancelada: no hay nada que autorizar, solo queda el registro (nunca se pierde nada).
  if new.estado = 'CANCELADO' then
    return new;
  end if;

  v_otro := case when new.origen_id = auth.uid() then new.destino_id else new.origen_id end;
  if v_otro is not distinct from auth.uid() then
    return new;   -- las dos puntas son la misma persona: lo dice el CHECK de la tabla (23514)
  end if;

  if not public.somos_companieros_de_campania(v_otro) then
    raise exception 'Solo podés pedir una transferencia a un compañero de tu campaña (los dos inscriptos, sin baja, en una campaña que no terminó). Elegí otro colportor o hablá con tu coordinador.'
      using errcode = '42501';
  end if;
  return new;
end;
$$;

comment on function public.tg_transferencia_stock_del_cliente() is
  'BEFORE INSERT de transferencia_stock, solo para authenticated (0139, 0148): nace PENDIENTE_AUTORIZACION o '
  'CANCELADO (23514), quien llama es una de las dos puntas (42501) y, si no nace cancelada, la otra es un '
  'compañero de su campaña (42501); el servidor fija solicitante y fecha de solicitud y deja en blanco '
  'coordinador, deuda, decisión y motivo. El servidor no pasa por acá.';

drop policy transferencia_stock_insert_propia on public.transferencia_stock;
create policy transferencia_stock_insert_propia on public.transferencia_stock
  for insert to authenticated
  with check (solicitante_id = (select auth.uid())
              and (origen_id = (select auth.uid()) or destino_id = (select auth.uid()))
              and estado in ('PENDIENTE_AUTORIZACION', 'CANCELADO'));

-- Cancelar: lo único que el teléfono cambia de una transferencia es su estado, de PENDIENTE_AUTORIZACION a
-- CANCELADO. Las demás columnas ya las frena el privilegio (UPDATE solo sobre id, estado, created_at y
-- deleted_at); la baja lógica la frena este trigger: una transferencia no se borra, se cancela.
create function public.tg_transferencia_stock_cancelar_del_cliente()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if current_user not in ('authenticated', 'anon') then
    return new;
  end if;

  if new.deleted_at is distinct from old.deleted_at then
    raise exception 'Una transferencia no se borra: se cancela mientras esté por autorizar.'
      using errcode = '42501';
  end if;

  if new.estado is not distinct from old.estado then
    return new;
  end if;

  if new.estado <> 'CANCELADO' then
    raise exception 'Desde el teléfono una transferencia solo se puede cancelar.'
      using errcode = '42501';
  end if;

  if old.estado in ('AUTORIZADO', 'EJECUTADO') then
    raise exception 'Tu coordinador ya autorizó esta transferencia: ya no se puede cancelar desde el teléfono. Hablá con él.'
      using errcode = '42501';
  elsif old.estado <> 'PENDIENTE_AUTORIZACION' then
    raise exception 'Esta transferencia ya no se puede cancelar: ya no está por autorizar.'
      using errcode = '42501';
  end if;
  return new;
end;
$$;

comment on function public.tg_transferencia_stock_cancelar_del_cliente() is
  'BEFORE UPDATE de transferencia_stock, solo para authenticated (0148): el teléfono solo cancela una transferencia '
  'por autorizar (no la borra); una autorizada, rechazada o cancelada ya no se toca (42501). El servidor no pasa '
  'por acá.';

revoke all on function public.tg_transferencia_stock_cancelar_del_cliente()
  from public, anon, authenticated, service_role;

create trigger transferencia_stock_cancelar_del_cliente
  before update on public.transferencia_stock
  for each row execute function public.tg_transferencia_stock_cancelar_del_cliente();

-- Quien la pidió es la única con UPDATE sobre su transferencia (la armada por el coordinador no tiene solicitante).
create policy transferencia_stock_update_propia on public.transferencia_stock
  for update to authenticated
  using (solicitante_id = (select auth.uid()))
  with check (solicitante_id = (select auth.uid()));

grant update (id, estado, created_at, deleted_at) on public.transferencia_stock to authenticated;

-- ----------------------------------------------------------------------------
-- 5. Cancelar la transferencia propia no compara versión (como el pedido, 0138)
-- ----------------------------------------------------------------------------
-- Lo único que cambia de sync.aplicar_job_interno es la condición de la cancelación: el cuerpo es el de 0138.

create or replace function sync.aplicar_job_interno(p_op_id uuid, p_job jsonb)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_entidad   text  := p_job ->> 'entity';
  v_op        text  := p_job ->> 'op';
  v_version   bigint;
  v_payload   jsonb := p_job -> 'payload';
  v_tabla     regclass;
  v_pk_col    text;
  v_push_ok   boolean;
  v_pk        uuid;
  v_usadas    text[];
  v_cache     sync.op_cache%rowtype;
  v_actual    jsonb;
  v_nueva     bigint;
  -- EXECUTE no toca FOUND en PL/pgSQL: hay que leer ROW_COUNT a mano. Con FOUND,
  -- un insert que chocó con una PK existente se reportaría `accepted` porque la
  -- variable venía en true de un SELECT anterior.
  v_filas     integer;
  v_juntado   uuid;
  v_duplicada  uuid;
  v_conservada uuid;
  v_union      jsonb;
  v_juntada    jsonb;
begin
  if p_op_id is null then
    return sync.rechazo(p_op_id, 'OP_ID_REQUERIDO', 'falta client_op_id o no es un uuid');
  end if;

  -- El cache gana sobre cualquier validación. Un op ya aplicado vuelve
  -- `duplicate` y no se re-valida: si no, un job aplicado cuya respuesta se
  -- perdió y que en el reintento cae en una validación quedaría INVALID con la
  -- fila ya escrita, y el colportor vería en la cola de error una venta que ya
  -- cobró. Como acá solo entra lo aplicado, un conflicto anterior no lo activa.
  select * into v_cache from sync.op_cache where client_op_id = p_op_id;
  if found then
    return jsonb_build_object('client_op_id', p_op_id, 'outcome', 'duplicate',
                              'sync_version', v_cache.sync_version);
  end if;

  select e.tabla, e.columna_pk, e.permite_push
    into v_tabla, v_pk_col, v_push_ok
    from sync.entidad e where e.nombre = v_entidad;
  if v_tabla is null then
    return sync.rechazo(p_op_id, 'ENTIDAD_DESCONOCIDA',
                        format('%L no está registrada para sync', v_entidad));
  end if;

  if not v_push_ok then
    return sync.rechazo(p_op_id, 'ENTIDAD_DE_SOLO_LECTURA',
                        format('%L es una réplica: la app no la escribe', v_entidad));
  end if;

  -- 0101: «marcar como duplicado» (HU-UBI-006, backend-supabase#70; decisión de Cristian del 06/10,
  -- «Duplicado»: «Se encola y sube después»). No es un upsert: no tiene PK ni sync_version, y lo aplica
  -- la misma operación atómica e idempotente de la RPC, `marcar_como_duplicado(B, A)`, con los mismos
  -- permisos y los mismos errores. Va después del cache y de los chequeos de la entidad, y antes de
  -- todo lo que piensa en una fila: el payload trae los dos ids (`duplicada_id` = B, `conservada_id` =
  -- A) y no una PK. Se aplica en su lugar del lote: después de lo que ese teléfono subió de A y de B.
  --   · aplicado -> `accepted`; B ya estaba unida (a A o a otra; A ya se había unido a B) -> `duplicate`,
  --     con `ya_unida: true`. Los dos traen `destino_id` (A, o aquella a la que A ya se había unido) y el
  --     `sync_version` de B, y entran al cache: el reintento con el mismo client_op_id es `duplicate`.
  --   · UB003, UB004, 42501 y CG001 salen como `invalid` (los atrapa sync.aplicar_job, abajo) y una
  --     ubicación que no existe, como `invalid FILA_INEXISTENTE`: ninguno tumba el lote.
  if v_op = 'marcar_como_duplicado' then
    if v_entidad <> 'ubicacion' then
      return sync.rechazo(p_op_id, 'OP_INVALIDA',
                          format('op %L solo va con la entidad ubicacion', v_op));
    end if;

    v_duplicada  := (v_payload ->> 'duplicada_id')::uuid;
    v_conservada := (v_payload ->> 'conservada_id')::uuid;
    if v_duplicada is null or v_conservada is null then
      return sync.rechazo(p_op_id, 'PK_FALTANTE', 'el payload no trae duplicada_id y conservada_id');
    end if;

    begin
      v_union := public.marcar_como_duplicado(v_duplicada, v_conservada);
    exception when no_data_found then
      -- La RPC la levanta (P0002) cuando alguna de las dos no existe.
      return sync.rechazo(p_op_id, 'FILA_INEXISTENTE', sqlerrm);
    end;

    select t.sync_version into v_nueva from public.ubicacion t where t.id = v_duplicada;
    return sync.registrar(p_op_id, v_entidad,
                          case when (v_union ->> 'ya_unida')::boolean then 'duplicate' else 'accepted' end,
                          v_nueva)
           || jsonb_build_object('ya_unida', (v_union ->> 'ya_unida')::boolean,
                                 'destino_id', v_union -> 'destino_id');
  end if;

  v_pk := (v_payload ->> v_pk_col)::uuid;
  if v_pk is null then
    return sync.rechazo(p_op_id, 'PK_FALTANTE',
                        format('el payload no trae %L', v_pk_col));
  end if;

  -- Solo las columnas que el cliente puede escribir (contrato §5.4). Las del
  -- servidor se descartan aunque vengan.
  select array_agg(k) into v_usadas
    from jsonb_object_keys(v_payload) k
   where k = any (sync.columnas_escribibles(v_entidad));

  if v_usadas is null then
    return sync.rechazo(p_op_id, 'PAYLOAD_VACIO',
                        'el payload no trae ninguna columna escribible');
  end if;

  -- ---- insert ----
  if v_op = 'insert' then
    execute format(
      'insert into %s (%s) select %s from jsonb_populate_record(null::%s, $1) x '
      'on conflict (%I) do nothing',
      v_tabla,
      (select string_agg(quote_ident(c), ', ' order by c) from unnest(v_usadas) c),
      (select string_agg('x.' || quote_ident(c), ', ' order by c) from unnest(v_usadas) c),
      v_tabla, v_pk_col
    ) using v_payload;
    get diagnostics v_filas = row_count;

    -- 0064: el insert no insertó nada porque el vínculo se juntó con el que ya tenía la misma persona
    -- en el espacio fundido (el trigger de espacio_persona lo registró). No es un duplicado: el
    -- teléfono tiene que saber cuál es el vínculo que quedó. Reintentar da lo mismo.
    if v_filas = 0 and v_entidad = 'espacio_persona' then
      v_juntado := public.vinculo_juntado(v_pk);
      if v_juntado is not null then
        return jsonb_build_object('client_op_id', p_op_id, 'outcome', 'merged',
                                  'merged_into', v_juntado);
      end if;
    end if;

    execute format('select t.sync_version from %s t where t.%I = $1', v_tabla, v_pk_col)
      into v_nueva using v_pk;

    -- La PK ya existía: el UUID v7 lo generó el dispositivo, así que es la misma
    -- fila y no otra. Éxito idempotente, no error (contrato §7, replay).
    return sync.registrar(p_op_id, v_entidad,
                          case when v_filas > 0 then 'accepted' else 'duplicate' end, v_nueva);
  end if;

  if v_op not in ('update', 'delete') then
    return sync.rechazo(p_op_id, 'OP_INVALIDA', format('op %L', v_op));
  end if;

  -- ---- update / delete ----
  begin
    v_version := (p_job ->> 'sync_version')::bigint;
  exception when data_exception then
    v_version := null;
  end;

  -- 0021: corregir lo que cargó otro con la campaña en la gracia de 0020 (decisión de Cristian
  -- del 02/10 en #52). Antes de leer la fila: la lectura no tiene gracia y no la vería.
  if public.correccion_ajena_en_gracia(v_entidad, v_pk) then
    return sync.rechazo(p_op_id, 'CG001',
                        'La campaña ya terminó: solo se guardan tus ventas y lo que cargaste vos. Lo '
                        'que cargó otra persona queda como estaba. Descartá este cambio.');
  end if;

  execute format('select %s from %s t where t.%I = $1',
                 sync.expresion_json(v_tabla), v_tabla, v_pk_col)
    into v_actual using v_pk;
  if v_actual is null then
    -- 0123: un vínculo que se juntó con otro al llegar no existe como fila (0064): su update o delete
    -- se aplica al que quedó (decisión de Cristian del 23/10, «Edición tarde»), con conflicto si el
    -- que quedó cambió después de la unión. Solo si el id lo subió quien llama; si no, sigue como antes.
    if v_entidad = 'espacio_persona' then
      v_juntada := public.aplicar_a_vinculo_juntado(v_pk, v_op, v_payload);
      if v_juntada is not null then
        if v_juntada ->> 'outcome' = 'conflict' then
          return jsonb_build_object(
            'client_op_id', p_op_id, 'outcome', 'conflict',
            'sync_version', (v_juntada ->> 'sync_version')::bigint,
            'server_row', v_juntada -> 'server_row');
        end if;
        return sync.registrar(p_op_id, v_entidad, 'accepted', (v_juntada ->> 'sync_version')::bigint);
      end if;
    end if;
    return sync.rechazo(p_op_id, 'FILA_INEXISTENTE',
                        format('%s no existe en %s', v_pk, v_entidad));
  end if;

  -- 0148 («Cancelar tr.», decisión de Cristian del 28/10): lo mismo para la transferencia de stock que pidió la
  -- colportora: cancelarla no compara versión (el servidor le fija el número y el teléfono puede tener una vieja).
  -- 0138 («Cancelar ped», decisión de Cristian del 27/10): cancelar un pedido propio que está por autorizar NO
  -- compara versión. Cancelar es "no lo quiero" y no depende de qué versión del pedido tenía el teléfono (las
  -- líneas, el monto y el aviso del límite se recalculan en el servidor y el teléfono puede tener una vieja). Se
  -- aplica sobre la versión que hay. Si el pedido ya no está por autorizar, el trigger de pedido_casa_editora
  -- (0124) lo frena con su aviso (42501: el coordinador ya lo autorizó, pedile que lo cancele) y el push vuelve
  -- `invalid` con el texto; si ya estaba cancelado, no cambia nada. Una cancelación nunca vuelve atrás a
  -- «por autorizar»: ese cambio no es una cancelación y sigue comparando versión (y el trigger lo frena).
  if v_op = 'update' and v_entidad in ('pedido_casa_editora', 'transferencia_stock') and v_payload ->> 'estado' = 'CANCELADO' then
    v_version := (v_actual ->> 'sync_version')::bigint;
  end if;

  -- LWW por sync_version (contrato §5.4). Si el servidor tiene una más nueva,
  -- gana él y devuelve su fila: el cliente resuelve sin un pull extra.
  if v_version is null or (v_actual ->> 'sync_version')::bigint <> v_version then
    return jsonb_build_object(
      'client_op_id', p_op_id, 'outcome', 'conflict',
      'sync_version', (v_actual ->> 'sync_version')::bigint,
      'server_row', v_actual);
  end if;

  -- La versión va en el WHERE del propio UPDATE, no solo en el `if` de arriba.
  --
  -- Entre aquel SELECT y este UPDATE hay una ventana: en READ COMMITTED otra
  -- transacción puede bumpear la fila justo ahí. El UPDATE quedaría esperando el
  -- lock, y al soltarse re-leería la fila y escribiría igual, pisando el cambio
  -- ajeno y devolviendo `accepted` con una versión que el cliente creía vieja.
  -- Es la actualización perdida clásica, y acá significa que el estado de una
  -- ubicación que dos dispositivos tocaron a la vez queda en el que llegó
  -- primero, sin que nadie se entere.
  --
  -- Con la versión en el WHERE es un compare-and-swap: o aplica sobre la versión
  -- que el cliente esperaba, o no aplica y se reporta como conflicto.
  --
  -- sync_version, updated_at y xmin_w no se asignan acá: los pone el trigger de
  -- auditoría del 0001 (§8), que corre igual venga la escritura de donde venga.
  if v_op = 'delete' then
    execute format('update %s t set deleted_at = now() where t.%I = $1 and t.sync_version = $2',
                   v_tabla, v_pk_col) using v_pk, v_version;
  else
    execute format(
      'update %s t set %s from jsonb_populate_record(null::%s, $1) x '
      'where t.%I = $2 and t.sync_version = $3',
      v_tabla,
      (select string_agg(format('%I = x.%I', c, c), ', ' order by c) from unnest(v_usadas) c),
      v_tabla, v_pk_col
    ) using v_payload, v_pk, v_version;
  end if;
  get diagnostics v_filas = row_count;

  if v_filas = 0 then
    -- Otro escritor ganó la carrera entre el SELECT y el UPDATE.
    execute format('select %s from %s t where t.%I = $1',
                   sync.expresion_json(v_tabla), v_tabla, v_pk_col)
      into v_actual using v_pk;
    return jsonb_build_object(
      'client_op_id', p_op_id, 'outcome', 'conflict',
      'sync_version', (v_actual ->> 'sync_version')::bigint,
      'server_row', v_actual);
  end if;

  execute format('select t.sync_version from %s t where t.%I = $1', v_tabla, v_pk_col)
    into v_nueva using v_pk;
  return sync.registrar(p_op_id, v_entidad, 'accepted', v_nueva);
end;
$$;

comment on function sync.aplicar_job_interno(uuid, jsonb) is
  'Aplica un job del push. Además de insert/update/delete de una entidad (0002, 0021, 0064), '
  'op ''marcar_como_duplicado'' con entity ''ubicacion'' y payload {duplicada_id, conservada_id}: llama a '
  'marcar_como_duplicado(B, A) y responde accepted, o duplicate con ya_unida (0101, HU-UBI-006). El '
  'update o delete de un espacio_persona que se juntó con otro al llegar se aplica al que quedó, con '
  'conflicto si cambió desde la unión (0123). El update de un pedido_casa_editora o de una transferencia_stock a '
  'CANCELADO no compara versión (0138, 0148).';
