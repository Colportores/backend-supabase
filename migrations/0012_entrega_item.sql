-- El detalle de la entrega: qué producto y cuántos.
--
-- ## Por qué
--
-- El modelo local (`DiagramaER_Local_PlantUML.puml`) tiene ENTREGA y
-- ENTREGA_DETALLE. Del lado del cloud solo estaba `entrega`, y con un
-- `cantidad int` suelto: una entrega de 3 títulos distintos se aplastaba a un
-- número. Con eso no se puede saber qué salió del stock.
--
-- Y eso bloquea cosas concretas río abajo: RF-ST08 dice que el stock se
-- descuenta por entregas, y la tarea 4.2 del plan pide `c_stock` derivado de
-- ellas. Ninguna de las dos es implementable sobre un entero sin producto.
--
-- Es el mismo par que `venta` / `venta_item`, y por la misma razón.
--
-- ## Qué NO lleva
--
-- El modelo local pone `pk_espacio_persona` en ENTREGA: a quién se le entregó.
-- Acá no está y no va a estar. `espacio_persona` apunta a `persona`, que es
-- `local` por P2 —sin datos personales en el cloud—, así que el vínculo con el
-- cliente se queda en el dispositivo. Del lado del servidor la entrega se ata a
-- la venta, que es lo que el coordinador necesita ver.

create table entrega_item (
  id           uuid primary key,          -- UUID v7 del dispositivo (§7)
  pk_usuario   uuid not null,
  -- La FK es lo que impide que un item entre sin su entrega: si el lote llega
  -- desordenado, el item se rechaza como `invalid` y el motor lo reencola.
  pk_entrega   uuid not null references entrega(id),
  pk_producto  uuid references producto(id),
  cantidad     int not null,

  sync_version int not null default 1,
  updated_at   timestamptz not null default now(),
  deleted      boolean not null default false,
  -- El cursor del delta (0010). Una tabla sincronizable que no la tenga hace
  -- fallar el guard de `sync_test.sql`.
  xmin_w       xid8 not null default pg_current_xact_id()
);

create index entrega_item_delta_xid on entrega_item (pk_usuario, xmin_w, id);

-- ---------------------------------------------------------------------------
-- `entrega` deja de llevar la cantidad
-- ---------------------------------------------------------------------------

-- Un `cantidad` en la entrega y otro en cada item son dos fuentes para el mismo
-- número, y tarde o temprano no coinciden. `venta` no guarda la suma de sus
-- items por la misma razón; guarda `total`, que es otra cosa.
--
-- Se puede borrar sin ceremonia: no hay datos en producción todavía. Después de
-- la primera campaña esto sería una migración de datos.
alter table entrega drop column cantidad;

-- Lo que sí faltaba de ENTREGA en el modelo local.
alter table entrega add column notas text;

-- ---------------------------------------------------------------------------
-- Registro y RLS
-- ---------------------------------------------------------------------------

insert into sync.entidad (nombre, tabla, por_usuario, permite_push)
values ('entrega_item', 'entrega_item'::regclass, true, true);

-- El recorrido de 0008 ya corrió: una tabla nueva necesita su política escrita
-- acá, o queda legible por cualquiera en el camino directo de Realtime.
alter table entrega_item enable row level security;

create policy entrega_item_visible on entrega_item
  for select to public
  using (pk_usuario = sync.usuario_actual());
