-- ============================================================================
-- 0161 · usuario.fcm_token: a qué teléfono mandarle las push
--        (backend-supabase#237, HU-NOT-001 y HU-NOT-003, ADR-014, R-NO04; decisión de Cristian del 23/10,
--        «Token FCM»)
--
-- El caso: Ana da el permiso de avisos en su teléfono. La app obtiene el token de FCM y lo guarda en su
-- perfil; si el sistema lo cambia, lo vuelve a guardar. Con ese dato el servidor sabe a dónde mandar «tu
-- pedido fue autorizado» (0162) sin que Ana haga nada más. Si Ana cierra sesión, la app lo borra.
--
-- ## Qué guarda
--
-- `usuario.fcm_token` (texto, opcional, SOLO EN LA NUBE): el token de registro de FCM del teléfono. No es
-- un dato de una persona (ADR-014, R-NO04): es un identificador del aparato que FCM puede revocar en
-- cualquier momento. `usuario` no está en `sync.entidad`, así que ni baja ni sube por el motor.
-- Columna que solo suma (regla R1): ninguna fila existente cambia, todas quedan en `null`.
--
-- ## Quién la escribe
--
-- Cada usuario escribe SOLO el suyo, con la política que ya existe (`usuario_update_propio`: la fila
-- propia, o cualquiera si es ADMIN), por la Data API: `PATCH /rest/v1/usuario?id=eq.<mi id>` con
-- `{"fcm_token": "<token>"}`, o `{"fcm_token": null}` para borrarlo al cerrar sesión. No hace falta una
-- RPC ni una entidad del motor (es lo mismo que hace `carrera_id`). La lee solo el propio usuario y el
-- ADMIN (`usuario_select_propio_o_admin`, 0015): el coordinador no ve tokens de otros.
--
-- ## Dos reglas del servidor
--
--   1. Forma: entre 1 y 4096 caracteres, sin espacios ni saltos de línea. La app manda `null` (no una
--      cadena vacía) para borrarlo.
--   2. Un token pertenece a UN usuario. Si Beto inicia sesión en el teléfono de Ana y guarda el mismo
--      token, el servidor se lo quita a Ana en la misma transacción: si no, los avisos de Ana (su pedido,
--      su ticket) llegarían al teléfono de Beto. Esa fila de Ana queda con `null`: la próxima vez que
--      ella abra la app en SU teléfono, lo vuelve a guardar. El token de FCM que rechaza el propio FCM
--      lo borra la Edge Function `push-fcm` por `public.push_resultado()` (0162).
--
-- Forward-only: esta migración no se edita una vez aplicada.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. La columna
-- ----------------------------------------------------------------------------

alter table public.usuario
  add column fcm_token text;

alter table public.usuario
  add constraint usuario_fcm_token_forma
    check (fcm_token is null
           or (char_length(fcm_token) between 1 and 4096 and fcm_token !~ '\s'));

comment on column public.usuario.fcm_token is
  'Token de registro de FCM del teléfono de este usuario, para las push (0161, ADR-014, R-NO04). Solo en la '
  'nube y sin datos personales. Cada usuario escribe el suyo (PATCH de su fila); null = sin push. Un token es '
  'de un solo usuario: guardarlo en otra cuenta se lo quita a la anterior.';

-- Para encontrar al dueño anterior de un token sin recorrer todos los usuarios (regla 2 de abajo).
create index usuario_fcm_token_idx on public.usuario (fcm_token) where fcm_token is not null;

-- ----------------------------------------------------------------------------
-- 2. Un token, un usuario
-- ----------------------------------------------------------------------------

-- DEFINER: la política de UPDATE solo deja tocar la fila propia, y acá hay que vaciar la de otro. Corre
-- después del cambio (AFTER) y solo si el token cambió; el UPDATE de abajo vuelve a disparar el trigger
-- con `null`, que no hace nada.
create function public.tg_usuario_fcm_token_unico()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.fcm_token is not null then
    update public.usuario u
       set fcm_token = null
     where u.fcm_token = new.fcm_token
       and u.id <> new.id;
  end if;
  return null;
end;
$$;

comment on function public.tg_usuario_fcm_token_unico() is
  'AFTER INSERT/UPDATE de usuario.fcm_token: el token guardado en una cuenta se le quita a cualquier otra '
  '(0161). Así el aviso de una persona no llega al teléfono de otra que inició sesión después.';

revoke all on function public.tg_usuario_fcm_token_unico() from public, anon, authenticated, service_role;

create trigger usuario_fcm_token_unico
  after insert or update of fcm_token on public.usuario
  for each row
  when (new.fcm_token is not null)
  execute function public.tg_usuario_fcm_token_unico();
