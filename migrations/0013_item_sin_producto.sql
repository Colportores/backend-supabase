-- Un renglón de venta o de entrega sin producto no significa nada.
--
-- `pk_producto` era nullable en las dos tablas de detalle, así que el servidor
-- aceptaba —con `accepted`, sin una queja— un `venta_item` de 3 unidades de
-- nada a $575, y un `entrega_item` de 3 unidades de nada.
--
-- Encontrado probando la app en un celular de verdad: el detalle subió con
-- `pk_producto` en null porque el catálogo todavía no había bajado al
-- dispositivo. El dato quedó guardado y sin sentido:
--
--   item: producto=(null)  cantidad=3
--
-- Y no es cosmético. RF-ST08 descuenta stock por entregas y la tarea 4.2 deriva
-- `c_stock`: las dos parten del producto. Un renglón sin él no se puede
-- descontar de ningún lado, no se puede valorizar, y nadie se entera hasta que
-- el stock no cierra al final de la campaña.
--
-- Con la columna `not null`, el mismo caso vuelve como `invalid` con su SQLSTATE
-- —clase 23, que `sync.aplicar_job` ya clasifica— y el renglón queda en la cola
-- de error del colportor, visible y corregible con `requeue()`. Que es
-- justamente la diferencia entre un dato que falta y un dato que se perdió.
--
-- El orden correcto en el dispositivo es bajar el catálogo antes de vender. Que
-- el servidor lo exija es lo que hace que ese orden no dependa de que la app se
-- porte bien.

alter table venta_item   alter column pk_producto set not null;
alter table entrega_item alter column pk_producto set not null;
