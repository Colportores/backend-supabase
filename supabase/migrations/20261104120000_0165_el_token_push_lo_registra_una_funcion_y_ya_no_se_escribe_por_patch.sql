-- ============================================================================
-- 0165 · El token push lo registra una función del servidor; ya no se escribe por PATCH
--        (backend-supabase#242, seguimiento de #237; decisión de Cristian del 04/11, «Token push», ADR-013)
--
-- El caso: Ana entra a la app y el teléfono le avisa al servidor a dónde mandarle los avisos. Hasta la 0161
-- la app lo hacía con un PATCH a su fila de `usuario`. Cristian decidió (04/11) que no: los clientes no
-- hacen `update` sobre tablas (ADR-013) y esta columna no es la excepción. El token sube por una función
-- propia, y al cerrar sesión la app llama a la misma función con `null`.
--
-- ## Qué cambia
--
--   1. `public.registrar_mi_token_push(p_token text)`: guarda `p_token` en `usuario.fcm_token` de QUIEN
--      LLAMA (`auth.uid()`), nunca de otro: la función no recibe a quién. `null` borra el token (cierre de
--      sesión). La forma del token (entre 1 y 4096 caracteres, sin espacios) la sigue cuidando el CHECK de la
--      0161: una cadena vacía o con espacios es `23514`. Si el token ya era el de esa cuenta no escribe
--      nada (no mueve `updated_at` ni la versión de la fila en cada arranque de la app).
--   2. La columna deja de poder escribirse por PATCH: un trigger descarta, sin error, el cambio de
--      `fcm_token` que llegue de `authenticated` o `anon` (como `ultimo_push_at`, 0053, y la suspensión,
--      0004: una app que reenvía su fila entera no falla, pero tampoco gana). Lo escriben la función de
--      arriba (DEFINER), el trigger de token único (0161) y `public.push_resultado()` (0162) cuando FCM
--      rechaza un token; también el service_role y los procesos del servidor.
--
-- ## Lo que no cambia
--
--   · El trigger de token único de la 0161: guardar en una cuenta un token que tenía otra se lo quita a la
--     otra (el teléfono de Ana, ahora con la sesión de Beto, no recibe los avisos de Ana).
--   · Quién lee la columna (el propio usuario y el ADMIN) y que `usuario` no es entidad del motor de sync.
--
-- Forward-only: esta migración no se edita una vez aplicada.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. La función que registra el token
-- ----------------------------------------------------------------------------

create function public.registrar_mi_token_push(p_token text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if (select auth.uid()) is null then
    raise exception 'Iniciá sesión para que este teléfono reciba los avisos.' using errcode = '42501';
  end if;

  -- Solo la fila de quien llama, y solo si el token cambia. Una cuenta dada de baja no registra nada.
  update public.usuario u
     set fcm_token = p_token
   where u.id = (select auth.uid())
     and u.deleted_at is null
     and u.fcm_token is distinct from p_token;
end;
$$;

comment on function public.registrar_mi_token_push(text) is
  'Guarda el token de FCM del teléfono en usuario.fcm_token de quien llama (auth.uid()); null lo borra al cerrar '
  'sesión (0165, ADR-013). Un token es de una sola cuenta: guardarlo le quita el token a la anterior (0161). '
  'Sin sesión: 42501. Forma inválida (vacío, con espacios, de más de 4096): 23514.';

revoke all on function public.registrar_mi_token_push(text) from public, anon, authenticated, service_role;
grant execute on function public.registrar_mi_token_push(text) to authenticated;

-- ----------------------------------------------------------------------------
-- 2. La columna ya no se escribe por PATCH
-- ----------------------------------------------------------------------------

-- Se distingue por el rol que ejecuta el UPDATE y no por auth.uid(): la función de arriba corre con el JWT de
-- la colportora (auth.uid() no es null) pero como su dueño, y current_user es el dueño.
create function public.tg_usuario_fcm_token_servidor()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.fcm_token is distinct from old.fcm_token
     and current_user in ('authenticated', 'anon') then
    new.fcm_token := old.fcm_token;
  end if;
  return new;
end;
$$;

comment on function public.tg_usuario_fcm_token_servidor() is
  'BEFORE UPDATE de usuario: descarta un cambio de fcm_token hecho por authenticated o anon (el token se registra '
  'con registrar_mi_token_push(), 0165, ADR-013).';

revoke all on function public.tg_usuario_fcm_token_servidor() from public, anon, authenticated, service_role;

create trigger usuario_fcm_token_servidor
  before update on public.usuario
  for each row execute function public.tg_usuario_fcm_token_servidor();

comment on column public.usuario.fcm_token is
  'Token de registro de FCM del teléfono de este usuario, para las push (0161, ADR-014, R-NO04). Solo en la '
  'nube y sin datos personales. Se registra con registrar_mi_token_push(p_token) (null = sin push; 0165): un '
  'PATCH a la fila no lo cambia. Un token es de un solo usuario: guardarlo en otra cuenta se lo quita a la anterior.';
