-- ============================================================================
-- 0121 · La devolución y su anulación quedan en audit_log
--        (backend-supabase#172, seguimiento de #134 / PR #171, BACK-HU-VEN-004)
--
-- ADR-002 («Efectos» 6) pide auditoría obligatoria de la devolución y de su anulación, y la decisión de
-- Cristian «Audit log» (0073) dice que cada HU suma sus eventos con `auditoria.registrar()`. La 0108 creó la
-- tabla `devolucion` sin registrar nada; esta migración suma los dos eventos.
--
-- ## Qué crea
--
--   · `public.devolucion_detalle_de_auditoria(devolucion)`, interna: arma el detalle de los dos eventos.
--   · `public.tg_devolucion_auditar_alta()` (SECURITY DEFINER) y el trigger `devolucion_auditar_alta`, AFTER
--     INSERT en `devolucion`, por fila: deja `devolucion_registrada`. Si la fila ya entra dada de baja (la
--     colportora la registró y la anuló sin conexión, y sube todo junto), deja además `devolucion_anulada`:
--     la anulación no puede quedar sin rastro por haber llegado en el mismo lote.
--   · `public.tg_devolucion_auditar_baja()` (SECURITY DEFINER) y el trigger `devolucion_auditar_baja`, AFTER
--     UPDATE OF deleted_at, por fila y solo cuando `deleted_at` pasa de null a una fecha: deja
--     `devolucion_anulada`. Volver a dar de baja una fila ya dada de baja, o tocar otra columna, no registra
--     nada. (Si `deleted_at` vuelve a null no hay evento: ADR-002 no prevé reactivar una devolución.)
--
--   Cada evento: `tabla = 'devolucion'`, `fila_id` = la devolución, `target_user_id` = null (quien la hizo es
--   el actor, `auth.uid()` de la sesión, que lo pone `auditoria.registrar()`), y `metadata` =
--
--       {venta_id, productos_distintos, unidades_devueltas, dinero_retenido, monto_reembolsado,
--        fecha_devolucion}
--
--   Solo la venta, dos totales (cuántos productos distintos y cuántas unidades), centavos
--   (`monto_reembolsado` es null si no devolvió plata) y la fecha del teléfono. La lista de productos NO se
--   copia: `metadata` admite hasta 4000 caracteres (CHECK de 0073) y cada renglón ocupa ~75, así que una
--   devolución de 53 renglones o más haría fallar el INSERT de `audit_log` (23514) y, con él, el push y la
--   anulación de esa devolución. Qué productos eran se lee de la propia fila (`fila_id`): la devolución nunca
--   se borra, solo se da de baja. El detalle tiene un tamaño fijo, sea cual sea la devolución.
--   Nunca texto libre: la tabla no tiene `motivo` (pendiente de Cristian, #134) y, si algún día lo suma, no se
--   copia acá (regla de 0073). Ningún dato del cliente.
--
--   Los triggers son AFTER ... FOR EACH ROW: corren dentro de la transacción del cambio (el evento y la fila
--   quedan o ninguno queda). El push inserta con `ON CONFLICT DO NOTHING`: un reintento de la misma
--   devolución (`duplicate`) no inserta la fila, así que no dispara el trigger ni duplica el evento. Los
--   triggers de auditoría de siempre (`tg_auditoria_insert/update`) son BEFORE y no se tocan.
--
-- ## Lo que NO hace (y por qué)
--
--   · No aplica la ventana de 24 h para anular. La aplica la app (front-colportores-mobile#417 y #420) y el
--     servidor la aplicará con el criterio que Cristian elija en la pregunta «Anular offline»
--     (back-133-impl-p1-anular-offline: con qué hora se mide el plazo cuando la anulación sube tarde).
--     Hasta esa respuesta el servidor acepta la baja en cualquier momento y la deja en el registro, sin un
--     criterio provisorio. Queda en el issue #191 (esa parte espera).
--
-- ## Los datos
--
-- Solo suma: tres funciones y dos triggers. No hay tabla, columna, UPDATE ni DELETE de datos: ninguna fila
-- existente cambia, ni su `sync_version` ni su `xmin_w`, y no se crea ningún evento retroactivo (la tabla de
-- 0108 estuvo vacía hasta ahora en producción; si no lo estuviera, las devoluciones de antes quedarían sin
-- evento, como toda fila anterior a un evento nuevo).
--
-- ## Para otros repos
--
--   · docs-organizacion: esquema-datos.md (los eventos `devolucion_registrada` y `devolucion_anulada`) y
--     HU-VEN-004. Ver el issue de docs que acompaña a esta entrega.
--   · front-colportores-mobile: nada que cambiar; el push de `devolucion` responde lo mismo.
--
-- Forward-only: esta migración no se edita una vez aplicada.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 0. El detalle de los dos eventos (tamaño fijo)
-- ----------------------------------------------------------------------------

-- Interna: la llaman los dos triggers. Inmutable de entrada a salida; no lee tablas. Un producto_id repetido
-- no puede pasar (productos_devueltos_validos), pero el conteo es de elementos del arreglo igual. Si la fila
-- no tuviera la forma esperada (no puede: el CHECK corre antes de los AFTER) los totales quedan en null.
create function public.devolucion_detalle_de_auditoria(p_fila public.devolucion)
returns jsonb
language sql
immutable
set search_path = ''
as $$
  select jsonb_build_object(
           'venta_id', p_fila.venta_id,
           'productos_distintos', jsonb_array_length(p_fila.productos_devueltos),
           'unidades_devueltas', (select sum((e ->> 'cantidad')::bigint)
                                    from jsonb_array_elements(p_fila.productos_devueltos) e),
           'dinero_retenido', p_fila.dinero_retenido,
           'monto_reembolsado', p_fila.monto_reembolsado,
           'fecha_devolucion', p_fila.fecha_devolucion);
$$;

comment on function public.devolucion_detalle_de_auditoria(public.devolucion) is
  'El metadata de devolucion_registrada y devolucion_anulada (0121): la venta, cuántos productos distintos y '
  'cuántas unidades, los dos montos en centavos y la fecha. Tamaño fijo: la lista de productos no se copia '
  '(audit_log.metadata admite 4000 caracteres) y se lee de la fila.';

revoke all on function public.devolucion_detalle_de_auditoria(public.devolucion)
  from public, anon, authenticated, service_role;

-- ----------------------------------------------------------------------------
-- 1. Al registrar (y, si entra ya anulada, también la anulación)
-- ----------------------------------------------------------------------------

create function public.tg_devolucion_auditar_alta()
returns trigger
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_detalle jsonb;
begin
  -- Solo la venta, dos totales, centavos y la fecha del teléfono (regla de 0073). Quién: auth.uid() lo pone
  -- auditoria.registrar(); la colportora que sube la devolución es el actor.
  v_detalle := public.devolucion_detalle_de_auditoria(new);

  perform auditoria.registrar('devolucion_registrada', 'devolucion', new.id, null, v_detalle);

  -- Registrada y anulada sin conexión, y sube todo junto: la anulación también queda.
  if new.deleted_at is not null then
    perform auditoria.registrar('devolucion_anulada', 'devolucion', new.id, null, v_detalle);
  end if;

  return null;
end;
$$;

comment on function public.tg_devolucion_auditar_alta() is
  'AFTER INSERT en devolucion (0121, backend-supabase#172, HU-VEN-004, ADR-002): deja devolucion_registrada en '
  'audit_log con la venta, cuántos productos y unidades, el dinero retenido, el reembolso y la fecha; y '
  'devolucion_anulada si la fila ya entra dada de baja. Nunca texto libre.';

revoke all on function public.tg_devolucion_auditar_alta() from public, anon, authenticated, service_role;

create trigger devolucion_auditar_alta
  after insert on public.devolucion
  for each row
  execute function public.tg_devolucion_auditar_alta();

-- ----------------------------------------------------------------------------
-- 2. Al anular (la baja, deleted_at)
-- ----------------------------------------------------------------------------

create function public.tg_devolucion_auditar_baja()
returns trigger
language plpgsql
volatile
security definer
set search_path = ''
as $$
begin
  perform auditoria.registrar(
    'devolucion_anulada', 'devolucion', new.id, null,
    public.devolucion_detalle_de_auditoria(new));
  return null;
end;
$$;

comment on function public.tg_devolucion_auditar_baja() is
  'AFTER UPDATE OF deleted_at en devolucion, cuando pasa de null a una fecha (0121, backend-supabase#172, '
  'HU-VEN-004, ADR-002): deja devolucion_anulada en audit_log con el mismo detalle que la alta. Una baja '
  'repetida o otro UPDATE no registran nada. La ventana de 24 h no se aplica acá (pendiente «Anular offline»).';

revoke all on function public.tg_devolucion_auditar_baja() from public, anon, authenticated, service_role;

create trigger devolucion_auditar_baja
  after update of deleted_at on public.devolucion
  for each row
  when (old.deleted_at is null and new.deleted_at is not null)
  execute function public.tg_devolucion_auditar_baja();
