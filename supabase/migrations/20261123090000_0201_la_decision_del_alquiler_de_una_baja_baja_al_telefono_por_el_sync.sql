-- ============================================================================
-- 0201 · La decisión del alquiler de una baja baja al teléfono por el sync
--        (backend-supabase#301, seguimiento de front-colportores-mobile#389; decisión del 23/11 por la regla R1, modelo que
--        solo suma; HU-CTA-007)
--
-- ## El caso
--
-- Ana se dio de baja de la campaña Otoño después de pagar $ 5.000 de alquiler. Su coordinador decidió qué hacer con esa plata
-- (devolvérsela, dejarla a cuenta de su próximo depósito o quedársela: `alquiler_decision`, 0159, 0167, 0181). Ana abre «Mi
-- alquiler» en el teléfono, a veces sin señal, y quiere saber qué pasó con sus $ 5.000. Hoy el teléfono no tiene dónde leerlo:
-- `alquiler_decision` no viaja por el sync y lo único que baja es el pago, anulado si se lo devolvieron.
--
-- ## Qué hace
--
-- Registra `alquiler_decision` como entidad de **solo bajada**, cada persona con las filas suyas (la dueña en `usuario_id`),
-- como `cuenta_colportor` (0179). La fila baja entera, con las columnas comunes del sync (`sync.expresion_json`):
--
--   · `id`, `usuario_id`, `campania_id`, `decision` (`DEVOLVER_AL_COLPORTOR`, `A_CUENTA_PROXIMO_DEPOSITO` o
--     `SE_LO_QUEDA_EL_COORDINADOR`), `decidido_en` y `created_at` (cuándo se decidió: ver abajo cuál usar), `monto` (lo decidido en ese paso, en centavos),
--     `decidido_por` (el id de quien decidió, que no es un dato personal nuevo: ya baja en `campania_coordinador`) y las
--     columnas de auditoría. **Sin texto libre**: ninguna columna lo admite.
--   · `deleted_at`: una decisión deshecha (la persona volvió a la campaña y «a cuenta» o «se lo queda» ya no cuentan, 0159) baja
--     como baja y el teléfono la saca de lo que muestra. «Devolver» no se deshace (la plata ya volvió).
--
-- Con eso y con lo que **ya baja** el teléfono arma la línea de «Mi alquiler» de la campaña de la baja, sin pedirle nada al
-- servidor:
--
--   · la inscripción con `deleted_at` (`campania_colportor`, desde la 0014: baja también la dada de baja y la de una campaña
--     terminada), la campaña (`campania`) y lo pagado (`deposito` de concepto `ALQUILER` con `validado_en`, con `anulado_at` si lo
--     devolvieron);
--   · lo **por decidir**, con la misma cuenta que `alquiler_calculado()` (0167): lo pagado (los `deposito` de concepto `ALQUILER` con
--     `validado_en`, sin `deleted_at` ni `anulado_at`) menos lo ya decidido (la suma de `monto` de las decisiones vigentes, sin
--     `deleted_at`, `A_CUENTA_PROXIMO_DEPOSITO` y `SE_LO_QUEDA_EL_COORDINADOR`; las `DEVOLVER_AL_COLPORTOR` no restan porque sus
--     pagos ya quedaron anulados), sin bajar de 0. Solo cuando lo pagado lo decide el coordinador: la inscripción está dada de baja o la
--     campaña no cobra alquiler (`campania.alquiler_monto` nulo); con la inscripción viva en una campaña que cobra, el sobrante pasa solo
--     a la deuda y no hay nada por decidir. Si pagó después de la última decisión, esa diferencia es lo nuevo que vuelve a
--     quedar por decidir. Por eso no hace falta bajar `cuenta_alquiler` (el monto por decidir del servidor): sale de las mismas
--     filas. Lo prueba supabase/tests/0201_… contra `cuenta_alquiler.alquiler_por_decidir`.
--   · cuándo se decidió: `created_at` de la decisión (la hora real de su transacción, 0181) y no `decidido_en` (la hora de inicio de
--     la transacción: puede ser anterior a un pago que la decisión no incluyó). Para saber qué pagos son de después de la
--     última decisión se compara `deposito.validado_en` con el `created_at` de la última decisión vigente, como hace «devolver».
--
-- ## Lo que NO cambia
--
--   · Quién ve qué: la política de lectura de la 0175 sigue igual (la persona, el ADMIN y quien coordina esa campaña). Lo que baja al
--     teléfono es solo lo suyo (`usuario_id` = quien hace el pull): un coordinador o un ADMIN que usan la app bajan sus propias
--     decisiones, no las de las personas que coordinan.
--   · Lo que sube: nada. El teléfono no escribe una decisión (solo `decidir_alquiler_pagado()`, que es del panel).
--   · `cuenta_alquiler` sigue sin viajar.
--
-- ## Los datos
--
-- No toca filas: un índice y un registro del sync. Las decisiones que ya existen bajan completas la primera vez que cada teléfono
-- pide la entidad (no tiene marca). Lo prueba supabase/tests/0201_… . Forward-only.
--
-- ## Para otros repos
--
--   · front-colportores-mobile#740: baja `alquiler_decision` (solo bajada) y muestra, en «Mi alquiler», la campaña de la baja con
--     lo que pagó y «por decidir» o lo que decidió el coordinador.
--   · docs-organizacion: contrato del sync §2 (entidad nueva, solo bajada, dueña en `usuario_id`) y `esquema-datos.md`
--     (`alquiler_decision` ya no es «no viaja por el sync»).
--
-- Forward-only: esta migración no se edita una vez aplicada.
-- ============================================================================

-- El cursor del pull por dueña: (usuario_id, xmin_w, id), como las cuentas (0179).
create index alquiler_decision_delta_idx on public.alquiler_decision (usuario_id, xmin_w, id);

insert into sync.entidad (nombre, tabla, columna_pk, permite_push, sigue_campanias, columna_duenio) values
  ('alquiler_decision', 'public.alquiler_decision'::regclass, 'id', false, false, 'usuario_id');

comment on table public.alquiler_decision is
  'Lo que el coordinador (o un ADMIN) decidió hacer con lo pagado de alquiler por quien se dio de baja o en una campaña sin '
  'alquiler (0159, backend-supabase#234; tres destinos desde la 0167): una decisión por todo lo pagado hasta ese momento. Lo '
  'escribe únicamente decidir_alquiler_pagado(). La cuenta vigente es la de alquiler_calculado(): una decisión de una cuenta '
  'que ya no está por decidir se da de baja (deleted_at, refrescar_cuenta_alquiler) y queda como historia. Desde la 0201 baja '
  'al teléfono por el sync (entidad de solo bajada, cada persona las suyas) para que «Mi alquiler» diga qué se decidió con lo '
  'pagado de una baja; la baja lógica baja como baja. Sin texto libre.';
