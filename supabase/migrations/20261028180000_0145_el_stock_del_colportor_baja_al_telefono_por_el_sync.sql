-- ============================================================================
-- 0145 · El stock del colportor baja al teléfono por el sync, de solo lectura (backend-supabase#218)
--
-- Prioridad alta (Cristian, 28/10): para probar la demo, el teléfono tiene que mostrar el stock del colportor
-- también sin conexión (HU-STK-004, «Consultar mi stock»: «Listo cuando veo mi stock al detalle, también sin
-- internet»). Seguimiento de front-colportores-mobile#545 (la réplica local) y de la 0067, que dejó `stock` fuera
-- de `sync.entidad` hasta que se decidiera «el camino de la conexión de V2».
--
-- ## El caso
--
-- Ana, colportora de la campaña Libertador San Martín, abre el teléfono sin señal y quiere saber cuántos libros
-- le quedan de cada producto. El inventario existe en la base (`public.stock`: una fila por colportor y
-- producto, que escribe el servidor al recibir un pedido, al entregar, al devolver y al transferir: 0118, 0126,
-- 0135, 0136, 0142), pero `sync.pull` no lo entregaba y la app no tenía de dónde leerlo.
--
-- ## Qué hace (solo suma; no toca filas, políticas ni privilegios)
--
--   · Registra `stock` en `sync.entidad` como entidad de SOLO BAJADA (`permite_push = false`): el teléfono nunca
--     lo escribe. Lo mueven el servidor y las RPC (el push de una entrega descuenta; un pedido recibido suma),
--     y el teléfono muestra lo que dice el servidor. Un push de `stock` se rechaza con
--     `ENTIDAD_DE_SOLO_LECTURA`.
--   · `columna_duenio = 'usuario_id'` (0014): el pull baja SOLO las filas del propio usuario. La política de
--     lectura `stock_select` (0067) deja ver también al ADMIN y al coordinador de cada colportor (para el panel:
--     «el coordinador ve cantidades»); sin la columna del dueño el teléfono de un coordinador bajaría el stock de
--     todos sus colportores. Es el mismo criterio de `devolucion`, `ticket`, `pedido_casa_editora` y
--     `transferencia_stock`. La RLS sigue siendo la autoridad de lectura: el filtro del dueño solo recorta.
--     No hace falta una columna de dueño nueva: `usuario_id` ya existe.
--   · Índice del delta con el dueño primero (`stock (usuario_id, xmin_w, id)`), como `devolucion_delta_idx` (0108):
--     así `usuario_id = auth.uid()` entra en el Index Cond y el delta no recorre el stock de todos (0002 §14).
--
-- ## Lo que baja
--
-- La fila entera de `stock` (`sync.expresion_json`, como el resto de las réplicas): `id`, `usuario_id`,
-- `producto_id`, `cantidad_disponible`, `cantidad_reservada`, `created_at`, `updated_at`, `created_by`,
-- `deleted_at` y `sync_version` (`xmin_w` no viaja). `cantidad_disponible` puede ser NEGATIVA a propósito (S46):
-- entregar más de lo registrado se permite y queda como inconsistencia. Una baja lógica (`deleted_at`) baja como
-- tombstone. Cada vez que el servidor mueve el stock (`update` por una RPC o un trigger) el trigger de
-- auditoría sube `sync_version` y `xmin_w`, así que el delta del siguiente pull trae la fila nueva.
--
-- ## Lo que NO hace (y por qué)
--
--   · Sin Realtime: ADR-012 lo reserva para «tablas de catálogo y autorizaciones». El stock baja en el
--     próximo pull del ciclo del motor.
--   · No hay descuento local ni mezcla con ventas sin conexión: el teléfono no modifica la réplica. La entrega
--     se descuenta en el servidor cuando sube (0118) y el stock nuevo vuelve en el pull siguiente. Si el
--     teléfono tiene que mostrar el descuento al instante es una decisión de dominio pendiente (ver el
--     pendiente de esta entrega).
--   · No baja `movimiento_stock` (el histórico): la HU pide el stock actual por producto.
--   · No cambia el contrato de sync (docs-organizacion §2: suma `stock` como `pull` de V2): va en un issue de
--     docs aparte.
--
-- ## Los datos
--
-- Ningún `update`, `delete` ni cambio de filas de negocio: un `insert` en `sync.entidad` (una fila de registro),
-- un `create index` y un `comment on`. Los teléfonos que ya existen no re-descargan nada que no pidan.
--
-- Forward-only: esta migración no se edita una vez aplicada.
-- ============================================================================

-- El delta: el predicado de la RLS (el dueño) primero, para que entre en el Index Cond.
create index stock_delta_idx on public.stock (usuario_id, xmin_w, id);

insert into sync.entidad (nombre, tabla, columna_pk, permite_push, columna_duenio) values
  ('stock', 'public.stock'::regclass, 'id', false, 'usuario_id');

comment on table public.stock is
  'Inventario en mano del colportor, por producto (V2, R-ST01). Los combos no tienen stock propio. '
  'Solo lo escribe el servidor. Baja al teléfono por el sync como réplica de solo lectura (entidad sin push, '
  'solo las filas del propio usuario, 0145); sin Realtime.';
