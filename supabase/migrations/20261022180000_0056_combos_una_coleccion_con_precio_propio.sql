-- ============================================================================
-- 0056 · Combos: una colección con precio propio que se vende como un solo ítem
--        (backend-supabase#99, HU-CAT-009 y HU-VEN-001, decisión de Cristian del 21/10, C10,
--        docs-organizacion#69)
--
-- Un COMBO es una `coleccion` de productos con su propio precio (R-CT06): se carga a mano hasta que
-- exista el panel de Administración (front-admin-web, HU-CAT-009), tiene precio general
-- (`precio_general`, 0034) y excepciones por ciudad (`precio_por_ciudad`, 0027/0030) como cualquier
-- producto, y el colportor lo vende como UN ÍTEM de la venta con el precio del combo en su ciudad.
--
-- ## Qué había y qué faltaba (la verificación que pide el issue)
--
--   · `precio_general` y `precio_por_ciudad` ya admitían una colección (producto_id O coleccion_id) y
--     `precio_vigente(campania_ciudad, producto, coleccion, fecha)` (0034) ya la resuelve: no se toca.
--     `precios_de_la_ciudad()` (0037) ya la lista. Lo prueba el pgTAP 0061 con un combo armado.
--   · `venta_item` NO admitía una colección: `producto_id` era NOT NULL y la tabla no tenía otra
--     columna a qué apuntar. Un combo no se podía vender como un ítem. Esta migración lo arregla.
--   · `producto_coleccion` no decía cuántas unidades de cada producto lleva el combo («1 libro y 2
--     revistas», HU-CAT-009). Esta migración suma `cantidad`.
--
-- ## Qué cambia
--
--   1. `venta_item.coleccion_id` (uuid, FK a coleccion, opcional) y `venta_item.producto_id` pasa a
--      ser opcional. Exactamente UNO de los dos va cargado: el mismo CHECK que ya tienen
--      `precio_general` y `precio_por_ciudad` (`(producto_id is null) <> (coleccion_id is null)`,
--      23514 si vienen los dos o ninguno). La fila es la misma de siempre: `cantidad`,
--      `precio_unitario` (la foto del precio del combo al vender) y `subtotal = cantidad *
--      precio_unitario`. La regla del subtotal, el permiso (heredado de `venta`, 0003) y el sync (el
--      teléfono la sube con `sync_push`: las columnas escribibles salen del catálogo) no cambian.
--   2. `producto_coleccion.cantidad` (integer NOT NULL, default 1, > 0): cuántas unidades del
--      producto lleva el combo. Las filas de antes quedan en 1 (valor que ya tenían de hecho), sin
--      reescribir la tabla: el `xmin_w` de nadie cambia y ningún teléfono re-descarga nada.
--
-- ## Lo que NO hace (queda como estaba o es de otra entrega)
--
--   · Un combo no puede incluir otro combo: no hace falta una regla, no se puede representar.
--     `producto_coleccion.producto_id` apunta a `producto`, nunca a una colección.
--   · No valida en el servidor que el combo se «ofrezca» (que tenga precio en la ciudad ni que sus
--     componentes estén vivos): la venta se hace sin conexión con el catálogo del teléfono y una
--     venta hecha nunca se rechaza por el catálogo (principio: nunca se pierde una venta).
--   · No descuenta el stock de cada producto del combo: es V2 (necesita la tabla `stock`, HU-STK-007).
--   · `entrega` queda igual (una fila por producto entregado): el combo, al entregarse, genera una
--     por componente.
--   · No guarda la composición del combo en el momento de la venta (qué productos y cuántos): ver el
--     archivo de pendientes de esta entrega.
--
-- ## Los datos
--
-- Solo se suman una columna opcional a `venta_item` y una con valor por defecto a `producto_coleccion`;
-- se afloja un NOT NULL. Ninguna fila se borra ni se modifica: las ventas de antes siguen apuntando a
-- su producto y el CHECK nuevo las cumple (tienen producto_id y no coleccion_id). Lo prueba el caso
-- `tests_migracion/0056_ok`.
--
-- ## Para otros repos
--
--   · front-colportores-mobile (HU-VEN-001, #158): la tabla local `venta_item` tiene que admitir
--     `coleccion_id` (con `producto_id` nulo en ese caso) y la local `producto_coleccion` la columna
--     `cantidad`. El pull de `producto_coleccion` y el push de `venta_item` ya llevan las columnas
--     nuevas (el sync serializa las de la tabla, sin lista aparte).
--   · docs-organizacion: `esquema-datos.md` (`venta_item`: `producto_id` O `coleccion_id`;
--     `producto_coleccion`: `cantidad`) y el contrato del sync (payload de `venta_item`).
--
-- Forward-only: esta migración no se edita una vez aplicada.
-- ============================================================================

-- 1. venta_item: un producto O una colección (combo).
alter table public.venta_item
  alter column producto_id drop not null;

alter table public.venta_item
  add column coleccion_id uuid references public.coleccion(id);

alter table public.venta_item
  add constraint venta_item_producto_o_coleccion
  check ((producto_id is null) <> (coleccion_id is null));

create index venta_item_coleccion_idx on public.venta_item (coleccion_id)
  where coleccion_id is not null;

comment on column public.venta_item.producto_id is
  'El producto vendido. Va null cuando el ítem es un combo (coleccion_id): exactamente uno de los dos.';
comment on column public.venta_item.coleccion_id is
  'La colección (combo) vendida como un solo ítem, con el precio del combo en la ciudad de la venta '
  '(precio_unitario es la foto de ese precio). Null cuando el ítem es un producto (producto_id): '
  'exactamente uno de los dos (0056, backend-supabase#99, HU-VEN-001, C10).';

-- 2. producto_coleccion: cuántas unidades del producto lleva el combo.
alter table public.producto_coleccion
  add column cantidad integer not null default 1;

alter table public.producto_coleccion
  add constraint producto_coleccion_cantidad_positiva
  check (cantidad > 0);

comment on column public.producto_coleccion.cantidad is
  'Unidades de este producto que lleva el combo (1 libro y 2 revistas = dos filas, con 1 y 2). '
  'Las filas de antes de la 0056 quedan en 1. Un combo no puede incluir otro combo: '
  'producto_id apunta a un producto, nunca a una colección (0056, HU-CAT-009).';
