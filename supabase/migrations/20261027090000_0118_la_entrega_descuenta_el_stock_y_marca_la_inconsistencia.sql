-- ============================================================================
-- 0118 · La entrega descuenta el stock del colportor y, si no alcanzaba, queda marcada (backend-supabase#147,
--        HU-STK-007, Supuesto S46)
-- ============================================================================
-- Caso: Emiliano tiene registrados 2 ejemplares del Libro A y entrega 5 (el stock del sistema no coincide con
-- lo que lleva en la mochila). La venta se registra igual y la entrega queda marcada como inconsistente;
-- con 10 y entregando 3, el stock pasa a 7 y nada queda marcado. Un combo se entrega como una fila de
-- `entrega` por componente (0056): cada componente descuenta su producto en su propia cantidad.
--
-- ## Qué hace
--
--   1. `entrega.stock_inconsistente boolean not null default false`: la marca de S46. La pone el servidor y
--      es `true` cuando, al entregarse, el stock registrado del colportor para ese producto era menor que lo
--      entregado (sin fila de stock vale 0). Un cliente nunca la elige: está entre las `columnas_servidor`
--      de `entrega` (el push la descarta) y un trigger la deja como estaba si alguien con JWT la escribe
--      directo.
--   2. Una entrega ENTREGADA descuenta: la salida cuenta cuando la fila queda con `pendiente = false` y sin
--      `deleted_at`, ya sea porque se inserta así (entrega inmediata, HU-VEN-002) o porque pasa de pendiente
--      a entregada (HU-VEN-003). Ahí el servidor, en la misma transacción del push:
--        · resta `cantidad` de `stock.cantidad_disponible` del colportor de la venta (crea la fila si no
--          existía; el saldo puede quedar negativo a propósito, 0067);
--        · agrega un `movimiento_stock` `SALIDA_ENTREGA` con `entrega_id` (la `fecha` es la `fecha_entrega`
--          real si vino, o ahora);
--        · deja el evento `stock_descontado_por_entrega` en `audit_log` (ids y números, sin texto libre).
--      Nunca rechaza: entregar de más se permite (S46, «nunca se pierde una venta»).
--   3. Una sola vez por entrega: un índice único parcial sobre `movimiento_stock(entrega_id)` (tipo
--      `SALIDA_ENTREGA`) y la comprobación del trigger. Dos pushes de la misma entrega (replay), una entrega
--      que vuelve a pendiente y se entrega otra vez, o un UPDATE de otra columna no descuentan de nuevo. El
--      push de una fila que ya existe (`ON CONFLICT DO NOTHING`) no dispara el trigger de después, así que
--      el reintento idempotente tampoco descuenta.
--
-- ## Qué no hace (queda como estaba o es de otra entrega)
--
--   · No devuelve stock: ni la devolución de una venta (HU-VEN-004, `devolucion` de la 0108; el CHECK de
--     `movimiento_stock` no tiene un tipo de entrada por devolución), ni una entrega que se anula
--     (`deleted_at`), vuelve a pendiente o cambia de cantidad después de descontada. Queda en el archivo de
--     pendientes de esta entrega.
--   · No toca las entregas anteriores: las ya entregadas antes de esta migración no descuentan nada
--     (no hay con qué reconstruirlo; los datos son simulados hasta diciembre) y quedan con la marca en false.
--     Tampoco descuentan si después se les cambia otra columna: solo cuenta el paso a entregada.
--   · No avisa al colportor: la advertencia «Tu stock registrado era N pero entregaste M» es del teléfono con
--     su stock local (V2, front-colportores-mobile). El servidor guarda la marca, que baja en el pull de
--     `entrega` como cualquier columna.
--   · No hay reporte de inconsistencias (R49, HU-REP): la marca ya queda en la fila para armarlo.
--   · No se agrega una entidad nueva a `sync.entidad`: `entrega` ya es entidad; solo cambia su lista de
--     columnas del servidor. No hay que tocar los conteos de 0003/0037/0044.
--
-- ## Cómo
--
--   · Dos triggers sobre `entrega`, porque el push corre INVOKER y no puede escribir `stock` ni
--     `movimiento_stock` (sin políticas de escritura), y una función SECURITY DEFINER pierde el
--     `current_user` del cliente:
--       - BEFORE INSERT/UPDATE `entrega_stock_inconsistente` (INVOKER): si escribe un cliente (authenticated
--         o anon) deja la marca como estaba; si esta escritura es la que entrega, calcula la marca leyendo el
--         stock del colportor (con su propia lectura RLS). Solo lee: el `INSERT … ON CONFLICT DO NOTHING` del
--         push dispara los triggers de antes aun para una fila que después no entra.
--       - AFTER INSERT/UPDATE `entrega_descuenta_stock` (SECURITY DEFINER, search_path vacío): descuenta,
--         registra el movimiento y audita. Solo corre para filas que de verdad entraron.
--   · La marca y el descuento usan la misma regla: «entregada ahora» (`not pendiente` y sin `deleted_at`) y
--     no «ya entregada antes» (en un UPDATE, que la fila vieja no lo estuviera), y sin un SALIDA_ENTREGA
--     vivo de esa entrega.
--
-- ## Para otros repos
--
--   · front-colportores-mobile: el pull de `entrega` trae `stock_inconsistente` (el push la descarta); la
--     tabla local puede ignorarla o mostrarla en la entrega. El stock local y su advertencia previa a
--     registrar son del teléfono (HU-STK-007, V2).
--   · docs-organizacion: `esquema-datos.md` (`entrega.stock_inconsistente`; el movimiento `SALIDA_ENTREGA`
--     y el evento `stock_descontado_por_entrega`) y el contrato del sync (columna del servidor de `entrega`).
--
-- Forward-only: no se edita una vez aplicada.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. La marca
-- ----------------------------------------------------------------------------

alter table public.entrega
  add column stock_inconsistente boolean not null default false;

comment on column public.entrega.stock_inconsistente is
  'S46 (0118, #147, HU-STK-007): true si al entregarse el stock registrado del colportor para el producto era '
  'menor que lo entregado (la entrega se registra igual). La pone el servidor; el push la descarta. false en '
  'las entregas anteriores a la 0118, que no descontaron nada.';

-- El push no la escribe (contrato §5.4): se descarta en silencio.
update sync.entidad
   set columnas_servidor = columnas_servidor || array['stock_inconsistente']
 where nombre = 'entrega';

-- ----------------------------------------------------------------------------
-- 2. Una sola salida por entrega
-- ----------------------------------------------------------------------------

create unique index movimiento_stock_salida_entrega_key
  on public.movimiento_stock (entrega_id)
  where tipo = 'SALIDA_ENTREGA' and deleted_at is null;

-- ----------------------------------------------------------------------------
-- 3. BEFORE: la marca (solo la pone el servidor)
-- ----------------------------------------------------------------------------

create function public.tg_entrega_stock_inconsistente()
returns trigger
language plpgsql
volatile
set search_path = ''
as $$
declare
  v_colportor uuid;
  v_disponible integer;
begin
  -- Un cliente (el push o PostgREST) no elige la marca: queda la que había.
  if current_user in ('authenticated', 'anon') then
    new.stock_inconsistente := case when tg_op = 'UPDATE' then old.stock_inconsistente else false end;
  end if;

  -- Solo la escritura que entrega calcula la marca: la fila queda entregada ahora y no lo estaba antes.
  if new.pendiente or new.deleted_at is not null then
    return new;
  end if;
  if tg_op = 'UPDATE' and not old.pendiente and old.deleted_at is null then
    return new;
  end if;
  if tg_op = 'UPDATE' and exists (select 1 from public.movimiento_stock m
                                   where m.entrega_id = new.id and m.tipo = 'SALIDA_ENTREGA'
                                     and m.deleted_at is null) then
    return new;
  end if;

  select v.colportor_id into v_colportor from public.venta v where v.id = new.venta_id;
  if v_colportor is null then
    return new;   -- la venta no existe o no se ve: la FK o la RLS dirán lo suyo, no esta marca
  end if;

  select s.cantidad_disponible into v_disponible
    from public.stock s
   where s.usuario_id = v_colportor and s.producto_id = new.producto_id;

  new.stock_inconsistente := coalesce(v_disponible, 0) < new.cantidad;
  return new;
end;
$$;

comment on function public.tg_entrega_stock_inconsistente() is
  'BEFORE INSERT/UPDATE de entrega (0118, #147): la marca stock_inconsistente es del servidor. Un cliente no '
  'la elige; al pasar a entregada se pone en true si el stock registrado del colportor era menor que la '
  'cantidad (sin fila de stock = 0). Solo lee: no descuenta (eso lo hace entrega_descuenta_stock).';

revoke all on function public.tg_entrega_stock_inconsistente() from public, anon, authenticated, service_role;

create trigger entrega_stock_inconsistente
  before insert or update on public.entrega
  for each row
  execute function public.tg_entrega_stock_inconsistente();

-- ----------------------------------------------------------------------------
-- 4. AFTER: el descuento, el movimiento y la auditoría
-- ----------------------------------------------------------------------------

create function public.tg_entrega_descuenta_stock()
returns trigger
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_colportor uuid;
  v_despues   integer;
begin
  if new.pendiente or new.deleted_at is not null then
    return null;
  end if;
  if tg_op = 'UPDATE' and not old.pendiente and old.deleted_at is null then
    return null;   -- ya estaba entregada: no es el paso a entregada
  end if;
  if exists (select 1 from public.movimiento_stock m
              where m.entrega_id = new.id and m.tipo = 'SALIDA_ENTREGA' and m.deleted_at is null) then
    return null;   -- ya descontó: una sola vez por entrega
  end if;

  select v.colportor_id into v_colportor from public.venta v where v.id = new.venta_id;
  if v_colportor is null then
    return null;
  end if;

  insert into public.stock as s (usuario_id, producto_id, cantidad_disponible)
  values (v_colportor, new.producto_id, -new.cantidad)
  on conflict (usuario_id, producto_id)
  do update set cantidad_disponible = s.cantidad_disponible - new.cantidad
  returning s.cantidad_disponible into v_despues;

  insert into public.movimiento_stock (usuario_id, producto_id, tipo, cantidad, fecha, entrega_id)
  values (v_colportor, new.producto_id, 'SALIDA_ENTREGA', new.cantidad,
          coalesce(new.fecha_entrega, now()), new.id);

  -- Quién: auth.uid() (el colportor que sube la entrega). El detalle, solo ids y números.
  perform auditoria.registrar(
    'stock_descontado_por_entrega', 'entrega', new.id, v_colportor,
    jsonb_build_object('producto_id', new.producto_id,
                       'cantidad', new.cantidad,
                       'stock_antes', v_despues + new.cantidad,
                       'stock_despues', v_despues,
                       'inconsistente', new.stock_inconsistente));
  return null;
end;
$$;

comment on function public.tg_entrega_descuenta_stock() is
  'AFTER INSERT/UPDATE de entrega (0118, #147, HU-STK-007): cuando la fila pasa a entregada resta la cantidad '
  'del stock del colportor de la venta (puede quedar negativo, S46), agrega el movimiento SALIDA_ENTREGA y '
  'deja el evento stock_descontado_por_entrega en audit_log. Una sola vez por entrega; nunca rechaza.';

revoke all on function public.tg_entrega_descuenta_stock() from public, anon, authenticated, service_role;

create trigger entrega_descuenta_stock
  after insert or update on public.entrega
  for each row
  execute function public.tg_entrega_descuenta_stock();
