-- ============================================================================
-- 0179 · La deuda con la casa editora baja al teléfono por el sync
--        (backend-supabase#254, casilla «Deuda pull»; decisión de Cristian del 05/11 en docs-organizacion#76, seguimiento de
--        backend-supabase#235 y #243)
--
-- ## El caso
--
-- Ana abre «Deuda con la casa editora» en Mi Cuenta, sin señal. Hoy el teléfono llama a la RPC
-- `mi_deuda_con_la_casa_editora()` (0164, 0165, 0168) y, sin conexión, no tiene nada que mostrar. Cristian pidió que baje por el
-- sync como el stock (0145), para calcularla en el teléfono y verla siempre.
--
-- ## Qué hace
--
-- Registra dos entidades de **solo bajada**, cada persona con las filas suyas (la dueña en `usuario_id`):
--
--   1. **`cuenta_colportor`**: la cuenta de la colportora. Trae `deuda_total` (la deuda real, la que movió cualquier causa:
--      pedidos, depósitos, tarjeta, transferencias, alquiler) y lo demás de su cuenta. Es la cifra que la RPC devuelve como
--      `deuda_total`; una cuenta dada de baja (`deleted_at`) no debe nada.
--   2. **`cuenta_deuda_historial`**: cada cambio de esa deuda con su hora (0168). De ahí sale la deuda de hace 7 días exactos:
--      la última fila con `desde` igual o anterior a «ahora − 7 días» (`null` si no hay una).
--
-- Para repartir lo pagado «el más viejo primero» y sacar el saldo por pedido, el teléfono usa lo que **ya baja** por el sync y
-- no hace falta tocar: `pedido_casa_editora` y `pedido_item` (los pedidos AUTORIZADO, DESPACHADO y RECIBIDO, con
-- `monto_autorizado` o `monto_total` y las cantidades autorizadas), `deposito` (los de `concepto = 'CASA_EDITORA'` con
-- `validado_en`) y `ticket` (los `COBRO_TARJETA` en estado `VALIDADO`, 0165), más `producto` para el nombre de cada línea.
-- La regla es la de la RPC: pedidos por `fecha_pedido, numero, id`; el pagado de cada uno es
-- `min(monto, max(pagadoTotal − montoDeLosAnteriores, 0))`; se lista solo el de saldo > 0.
--
-- ## La RPC se queda
--
-- `mi_deuda_con_la_casa_editora()` **no se quita en esta migración**: la app que está en `develop` todavía la llama
-- (front-colportores-mobile#441). Se quita cuando el teléfono lea la deuda del sync (front-colportores-mobile#671) y nadie
-- más la use; mientras tanto es la referencia con la que los tests comparan el cálculo hecho sobre las filas que bajan
-- (supabase/tests/0179_…: los casos de #235).
--
-- ## Lo que NO hace
--
--   · No cambia quién lee la cuenta: la política de la 0067 sigue igual (la propia persona, el ADMIN y el coordinador de sus
--     colportoras). Lo que baja al teléfono es solo lo suyo (`usuario_id` = quien hace el pull).
--   · No escribe nada: el teléfono no sube ni cambia la cuenta ni el historial.
--
-- ## Los datos
--
-- No toca filas: dos índices y dos registros del sync. Lo prueba supabase/tests/0179_… . Forward-only.
--
-- ## Para otros repos
--
--   · front-colportores-mobile#671: baja `cuenta_colportor` y `cuenta_deuda_historial` (solo bajada) y calcula la deuda, el
--     saldo por pedido y la variación semanal con las filas locales.
--   · docs-organizacion#172: contrato del sync (§2, entidades nuevas) y `esquema-datos.md`.
--
-- Forward-only: esta migración no se edita una vez aplicada.
-- ============================================================================

-- El cursor del pull por dueña: (usuario_id, xmin_w, id), como el stock (0145).
create index cuenta_colportor_delta_idx on public.cuenta_colportor (usuario_id, xmin_w, id);
create index cuenta_deuda_historial_delta_idx on public.cuenta_deuda_historial (usuario_id, xmin_w, id);

insert into sync.entidad (nombre, tabla, columna_pk, permite_push, sigue_campanias, columna_duenio) values
  ('cuenta_colportor', 'public.cuenta_colportor'::regclass, 'id', false, false, 'usuario_id'),
  ('cuenta_deuda_historial', 'public.cuenta_deuda_historial'::regclass, 'id', false, false, 'usuario_id');

comment on table public.cuenta_colportor is
  'Snapshot calculado de la situación financiera del colportor (V2, HU-CTA-001..005): una fila por usuario. '
  'Lo escribe el servidor; esta migración no lo calcula. Lleva un id propio (el esquema decía usuario_id '
  'como clave) porque todas las tablas de public tienen id uuid. Se llamaba estado_cuenta hasta 0119: el '
  'nombre se pisaba con la función estado_cuenta() de 0004 (ACTIVA / PENDIENTE_ASIGNACION / SUSPENDIDA), '
  'que sigue llamándose así. El alquiler se lleva por campaña (cuentas_de_campania(), 0114), no acá. '
  'Desde la 0179 baja al teléfono por el sync (entidad de solo bajada, cada persona la suya): con ella y con lo que ya baja '
  '(pedidos, depósitos, tickets) el teléfono calcula la deuda y el saldo por pedido sin conexión.';

comment on table public.cuenta_deuda_historial is
  'La deuda con la casa editora de cada colportora a lo largo del tiempo (0168, backend-supabase#243, «Variación '
  'semanal»): una fila por cada cambio de cuenta_colportor.deuda_total (0 mientras la cuenta está de baja), con la hora '
  'en que cambió. La llena el trigger de cuenta_colportor, sea cual sea la causa del cambio. Desde la 0179 baja al teléfono '
  'por el sync (solo bajada, cada persona la suya) para decir cuánto debía hace 7 días. No escribe nadie con JWT.';
