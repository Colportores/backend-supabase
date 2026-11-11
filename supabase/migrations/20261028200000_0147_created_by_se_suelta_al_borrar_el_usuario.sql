-- ============================================================================
-- 0147 · Borrar a un usuario suelta su created_by en todas las tablas (backend-supabase#62)
--
-- El caso: el ADMIN borra la cuenta de un coordinador que creó países, ciudades, campañas, zonas... Las FK
-- `created_by -> usuario(id)` son ON DELETE SET NULL, y `esquema-datos.md` lo promete: «created_by (UUID usuario;
-- nullable: seeds y autor eliminado)». Pero no pasaba: `tg_auditoria_update` (BEFORE UPDATE de toda tabla con
-- auditoría) fuerza `new.created_by := old.created_by` para que la columna sea inmutable, y el SET NULL de la FK es
-- un UPDATE más, que pasa por ese trigger. Resultado: el SET NULL no hacía nada y `created_by` quedaba con el uuid
-- de un usuario que ya no existe, sin error y sin que nada lo avisara. Con dos FK a `usuario` en la misma fila
-- (`created_by` y `cerrada_por` del historial de zonas, 0022) el segundo SET NULL dejaba además el borrado en 23503;
-- 0022 lo resolvió con un trigger propio de esa tabla. Esta migración lo resuelve de raíz, para todas.
--
-- ## Qué cambia
--
--   `tg_auditoria_update` deja pasar el cambio de `created_by` a null solo cuando se cumplen las tres:
--     1. `pg_trigger_depth() > 1`: el UPDATE nace adentro de otro trigger (el de la acción de la FK, que corre al
--        borrar al usuario), no es una sentencia de primer nivel. Un UPDATE directo de `created_by` (de un cliente
--        con JWT, del ADMIN, del servidor) sigue sin poder cambiarlo: queda como estaba, igual que antes. Es el
--        mismo recurso que usa el republicado de 0011 (`colportores.republicar`).
--     2. el valor nuevo es null (nunca otro uuid: la columna no se reasigna a nadie);
--     3. el usuario viejo ya no existe en `usuario`.
--   La 3 se mira con los privilegios de quien corre el trigger: la acción de la FK corre como el dueño de la tabla,
--   que lee `usuario` entera; un cliente con JWT no llega a la rama (la 1 se lo impide).
--
--   Cualquier otra cosa se comporta como antes: `created_at` inmutable, `updated_at = now()`, `sync_version + 1`,
--   `xmin_w` (y el republicado de 0011). El SET NULL, como cualquier UPDATE, sube `sync_version` y `xmin_w` de la
--   fila: el delta la baja con el `created_by` limpio.
--
--   Se borra el trigger propio del historial de zonas (`..._sin_usuario`, 0022) y su función: ya no hace falta, y el
--   test 0027 (borrar al que asignó y cerró un tramo) pasa a probar la solución general.
--
-- ## Lo que NO hace
--
--   · No limpia filas viejas con `created_by` colgado (usuarios borrados antes de esta migración): hasta producción
--     las bases tienen datos simulados y no se hacen migraciones de limpieza (Cristian, 02/10, back#57). Esas
--     filas siguen como están; si alguien las actualiza por SQL de primer nivel, el uuid sigue igual.
--   · No agrega, quita ni renombra columnas ni cambia quién ve qué.
--
-- Forward-only: esta migración no se edita una vez aplicada.
-- ============================================================================

create or replace function public.tg_auditoria_update()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.created_at := old.created_at;
  -- created_by es inmutable, salvo el SET NULL de la FK cuando el usuario se borró (0147): UPDATE anidado
  -- (el de la acción de la FK), valor nuevo null y usuario viejo inexistente. Cualquier otro caso lo deja igual.
  if pg_trigger_depth() > 1
     and old.created_by is not null
     and new.created_by is null
     and not exists (select 1 from public.usuario u where u.id = old.created_by) then
    new.created_by := null;
  else
    new.created_by := old.created_by;
  end if;
  -- Sin esto, una fila actualizada conserva el xid de su INSERT, queda detrás del watermark de
  -- cualquier cliente que ya la bajó, y la modificación no se propaga nunca (0002).
  new.xmin_w := pg_current_xact_id();
  if current_setting('colportores.republicar', true) = 'on' and pg_trigger_depth() > 1 then
    new.updated_at := old.updated_at;
    new.sync_version := old.sync_version;
  else
    new.updated_at := now();
    new.sync_version := old.sync_version + 1;
  end if;
  return new;
end;
$$;

comment on function public.tg_auditoria_update() is
  'BEFORE UPDATE: updated_at = now(), sync_version = old + 1, xmin_w = xid actual; '
  'created_at/created_by inmutables, salvo el SET NULL de la FK al borrar al usuario (0147: UPDATE anidado, '
  'valor nuevo null y usuario inexistente). Con colportores.republicar = on (republicado, 0011) solo sube xmin_w.';

-- El trigger del historial de zonas (0022) hacía esto solo para esa tabla; ya lo cubre la función general.
drop trigger if exists campania_colportor_zona_historial_sin_usuario on public.campania_colportor_zona_historial;
drop function if exists public.tg_campania_colportor_zona_historial_sin_usuario();
