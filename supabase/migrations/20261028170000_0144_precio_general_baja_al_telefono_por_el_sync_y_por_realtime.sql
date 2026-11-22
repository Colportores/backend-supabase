-- ============================================================================
-- 0144 · `precio_general` baja al teléfono por el sync y por Realtime (backend-supabase#205)
--
-- Seguimiento de front-colportores-mobile#180 (PR #522), tanda de decisiones del 27/10:
-- https://github.com/Colportores/front-colportores-mobile/pull/522#issuecomment-6449496888
--
-- ## El caso
--
-- Agustín, colportor en Rivera, abre «Precios». Rivera no tiene excepción (`precio_por_ciudad`)
-- para «Conflicto de los Siglos», así que tiene que ver el precio general ($U 450). El teléfono ya
-- pide `precio_general` en el pull, pero el servidor no la manda: la 0034 la dejó fuera de
-- `sync.entidad` «hasta el OK del contrato», y ese OK ya es nuestro (Bruno terminó, 21/10).
--
-- ## Qué hace (solo suma; no toca filas ni políticas)
--
--   · Registra `precio_general` en `sync.entidad` como entidad de SOLO BAJADA (`permite_push =
--     false`: el general lo carga Administración, el teléfono nunca lo escribe), con el índice de
--     delta que ya existe (`precio_general_delta_idx`, 0034) y la PK `id`.
--   · Sin filtro por campaña ni por dueño: el general vale para todo el país («Precio gral.»), así
--     que la fila baja igual para todos los que la leen. Quién la lee lo siguen decidiendo las
--     políticas de la 0034 (`precio_general_select`: el ADMIN, o quien ve el mapa de una campaña),
--     que NO se tocan.
--   · `sigue_campanias = true`, como `precio_por_ciudad` (0027): NO es un filtro, es la huella de
--     las campañas del usuario dentro de su watermark. La política de lectura depende de que el
--     usuario tenga una campaña, y sin la huella un colportor que se inscribe DESPUÉS de su primer
--     pull no recibiría nunca los precios generales cargados antes (el delta solo trae lo más nuevo
--     que su watermark). Con la huella, al cambiar sus campañas la entidad baja completa.
--   · La suma a la publicación `supabase_realtime` junto a `precio_por_ciudad` (ADR-012: «solo en
--     tablas de catálogo y autorizaciones»): el cambio de un precio general llega al teléfono con
--     la app abierta. Realtime también respeta la RLS de la tabla.
--   · Actualiza el comentario de la tabla (decía que «todavía no baja al teléfono»).
--
-- ## Los datos
--
-- Ningún `update`, `delete` ni cambio de filas de negocio: un `insert` en `sync.entidad` (una fila de
-- registro), un `alter publication … add table` y un `comment on`. Idempotente en la publicación.
--
-- ## Para otros repos
--
--   · docs-organizacion#114: contrato de sync §2 con `precio_por_ciudad` (hoy dice `precio_por_zona`)
--     y `precio_general` (pull, sigue campañas, `realtime: true`).
--   · front-colportores-mobile#525: `realtime: true` en `lib/catalogo.dart` para `precio_general`.
--
-- Forward-only: esta migración no se edita una vez aplicada.
-- ============================================================================

insert into sync.entidad (nombre, tabla, columna_pk, permite_push, sigue_campanias) values
  ('precio_general', 'public.precio_general'::regclass, 'id', false, true);

do $$
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime')
     and not exists (select 1 from pg_publication_tables
                      where pubname = 'supabase_realtime' and schemaname = 'public'
                        and tablename = 'precio_general') then
    alter publication supabase_realtime add table public.precio_general;
  end if;
end
$$;

comment on table public.precio_general is
  'Precio de venta general de un producto o una colección: lo pone Administración y vale para todas '
  'las campañas del país (0034, decisión de Cristian del 06/10, «Precio gral.»). Las campañas lo '
  'modifican por ciudad en precio_por_ciudad. Centavos, con vigencia e historial: un solo precio '
  'vigente a la vez por producto o colección. Un precio nuevo vale para las ventas siguientes: '
  'venta_item guarda el suyo. Lo escribe solo el ADMIN; lo lee quien hoy lee precios con una '
  'campaña. Baja al teléfono por el sync (entidad de solo bajada que sigue las campañas, 0144) y '
  'por Realtime.';
