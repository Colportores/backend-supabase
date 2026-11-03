-- ============================================================================
-- 0154 · El depósito baja al teléfono con su validación o rechazo (backend-supabase#231, seguimiento de
--        front-colportores-mobile#173; decisión del agente de decisiones del 30/10, reglas R1 y R7, P1 de
--        front-colportores-mobile#593)
--
-- ## El caso
--
-- Lucía depositó 250.000 en el banco y entregó 40.000 a su coordinador, que pasó a retirarlos. El teléfono tiene que
-- decirle la verdad sin esperar a recuperar el dispositivo:
--   · «Depositado» suma solo lo VALIDADO («Acredita V1», 23/10); lo que está por validar se muestra aparte.
--   · Si el coordinador rechazó el retiro, Lucía ve el motivo en su teléfono y carga uno corregido
--     («Rechazo ret.», 28/10: «Lucía ve el motivo en su teléfono»; la 0152 ya lo prometía: el rechazo «baja al
--     teléfono con el motivo»).
-- Hasta hoy el contrato de sync (§2) dejaba la bajada del depósito «pendiente de decisión».
--
-- ## Qué hay que hacer en la base: nada que cambie filas, políticas ni privilegios
--
-- El pull de `deposito` ya estaba armado desde la 0122 y no hacía falta tocarlo; lo que faltaba era decidir que se
-- usa y probarlo. Esta migración solo lo deja dicho en el catálogo (comentarios) y lo prueba el pgTAP de esta entrega
-- (`0154_el_deposito_baja_al_telefono_pull_test.sql`):
--
--   · `sync.entidad` ya tiene `deposito` con `permite_push = true` y `columna_duenio = 'colportor_id'` (0122):
--     `sync.pull` baja SOLO las filas de la dueña. La política de lectura `deposito_select` (0067) deja ver también
--     al ADMIN y a la coordinadora de cada colportor (para el panel), pero sin la columna del dueño el teléfono de
--     una coordinadora bajaría los depósitos de todas sus colportoras: el pull recorta a lo propio, igual que
--     `stock` (0145), `devolucion` (0108) y `ticket` (0113). La RLS sigue siendo la autoridad de lectura.
--   · El índice del delta con el dueño primero ya existe (`deposito_delta_idx (colportor_id, xmin_w, id)`, 0122):
--     `colportor_id = auth.uid()` entra en el Index Cond y el delta no recorre los depósitos de todos.
--   · `validado_en`, `validado_por`, `rechazado_en`, `rechazado_por` y `motivo_rechazo` bajan con el resto de la
--     fila (`sync.expresion_json` baja todas las columnas): son fechas, un id de usuario y un motivo corto (hasta 500
--     caracteres, de quien rechazó), sin datos de clientes. Siguen siendo columnas del servidor: están en
--     `sync.entidad.columnas_servidor` (0129, 0152), el push las descarta y, por la API directa, el trigger del
--     cliente las rechaza con `42501`.
--   · Cuando el servidor valida o rechaza (RPC `validar_ticket`, `confirmar_retiro`, `rechazar_retiro`, o el UPDATE de
--     la fila) sube su `sync_version` y su `xmin_w`: el delta del siguiente pull trae el estado nuevo, sin que el
--     teléfono haga nada.
--   · Sin Realtime (ADR-012: solo catálogo y autorizaciones): el estado baja en el próximo pull del ciclo del motor.
--   · Los depósitos validados o rechazados no se editan (`DP001`, `DP005`): la fila que baja con el estado es la
--     definitiva. Un retiro rechazado queda como historia; la colportora carga uno nuevo.
--
-- ## Para otros repos
--
--   · front-colportores-mobile: la entidad `deposito` pasa a `SyncSpec.push(Tables.deposito, critical: true,
--     alsoPull: true)` (crítica: sube enseguida, como `cobranza` y `devolucion`; casilla de la QA de #593). El
--     estado se lee así: `validado_en` no nulo = validado; `rechazado_en` no nulo = rechazado (con
--     `motivo_rechazo`); los dos nulos = por validar.
--   · docs-organizacion: contrato del sync §2, nota «Depósito» (push + pull y crítica) y el changelog «Sin publicar».
--
-- ## Los datos
--
-- Ningún `insert`, `update`, `delete` ni cambio de esquema: solo `comment on`. Los teléfonos que ya existen bajan sus
-- depósitos en el primer pull que los pida.
--
-- Forward-only: esta migración no se edita una vez aplicada.
-- ============================================================================

comment on table public.deposito is
  'Depósito de efectivo del colportor (V2, HU-CTA-004): monto, fecha, a dónde fue y para qué era. '
  'Un depósito tiene un solo concepto (S68): para pagar los dos, dos depósitos. '
  'Sube por push (0122) y baja al teléfono por el pull de su dueña con su estado: validado (validado_en), '
  'rechazado (rechazado_en y motivo_rechazo) o por validar (los dos nulos) (0154); sin Realtime.';

comment on column public.deposito.rechazado_por is
  'El coordinador (o ADMIN) que rechazó el retiro (0152). Lo pone el servidor. Baja al teléfono con la fila (0154).';
