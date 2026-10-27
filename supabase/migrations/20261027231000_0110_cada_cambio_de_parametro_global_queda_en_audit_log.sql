-- ============================================================================
-- 0110 · Cada cambio de parametro_global queda en audit_log
--        (backend-supabase#152, seguimiento de #137, HU-CAT-006; «Precio viejo», Cristian 23/10)
--
-- Caso de uso
--   · Administración pasa los días de antigüedad de los precios de 15 a 20. Después alguien pregunta
--     «¿quién lo cambió, cuándo y de cuánto a cuánto?». La respuesta tiene que estar en audit_log,
--     venga el cambio del SQL Editor, de service_role o, cuando exista, de una RPC de Administración.
--
-- Decisión del agente de decisiones (25/10, por el mapa de decisiones): aplicar una decisión que ya tomó
-- Cristian («Precio viejo»: cada cambio queda registrado). El registro va en `auditoria.audit_log`
-- (0073, #136), no en una tabla de historial propia.
--
-- ## Qué hace
--
-- Un trigger AFTER ... FOR EACH ROW en `public.parametro_global` (SECURITY DEFINER, como pide 0073 para los
-- triggers que registran) que llama a `auditoria.registrar()` en la MISMA transacción que el cambio: o
-- quedan el cambio y su registro, o ninguno de los dos. Al ser un trigger y no una función, no hay
-- camino que lo esquive: el SQL Editor (rol dueño), `service_role` y la RPC de Administración que
-- llegue algún día lo disparan igual.
--
-- Eventos (`event_type`), uno por cambio de fila:
--
--   · `parametro_global_alta`    se crea una fila, o una fila dada de baja se reactiva.
--   · `parametro_global_cambio`  cambia `valor` (o `clave`) de una fila.
--   · `parametro_global_baja`    la fila se da de baja (`deleted_at`) o se borra de verdad (DELETE).
--   · `parametro_global_vaciado` TRUNCATE de la tabla (no hay fila que nombrar: lleva cuántas había).
--
-- Un UPDATE que no cambia nada (mismo valor, misma clave, mismo `deleted_at`) NO escribe nada: «cada
-- cambio» es cada cambio, no cada sentencia.
--
-- Qué lleva cada registro (las columnas de `audit_log`; sin datos personales, 0073):
--
--   · quién:   `actor_user_id` = `auth.uid()` de la sesión; null si no hay usuario (SQL Editor,
--              `service_role`). En ese caso `metadata.rol` dice el rol del servidor: `auth.role()` si la
--              petición trae un JWT (`service_role`), o el usuario de la conexión (`postgres`…) si no.
--   · cuándo:  `created_at` (el momento de la transacción).
--   · la fila: `tabla = 'parametro_global'`, `fila_id` = el id de la fila.
--   · el detalle (`metadata`): `clave`, `valor_anterior` y `valor_nuevo` (enteros; null donde no
--              aplica: no hay anterior en un alta ni nuevo en una baja), `rol` y, en una baja,
--              `definitiva` (true si fue un DELETE, false si fue la baja lógica).
--
-- ## Lo que NO hace
--
--   · No registra hacia atrás: la fila de 15 que sembró 0070 no tiene evento de alta (el trigger no
--     existía). Lo primero que se ve en audit_log es el primer cambio posterior.
--   · No abre escritura a ningún cliente con JWT, ni siquiera al ADMIN: `parametro_global` sigue sin
--     políticas de INSERT, UPDATE ni DELETE para `authenticated`. Una RPC de Administración (o la
--     pantalla del panel) es otro issue; cuando llegue, el trigger ya la cubre y el actor sale del
--     JWT.
--
-- ## Los datos
--
-- Solo se suma un trigger y dos funciones: no se toca ninguna fila de `parametro_global` ni de
-- `audit_log`.
--
-- ## Para otros repos
--
--   · docs-organizacion: HU-CAT-006 («cada cambio queda registrado») pasa a estar cumplida por
--     audit_log; la lista de eventos de HU-ADM-007 suma los cuatro de arriba. Issue de seguimiento.
--   · front-*: nada que cambiar; audit_log no baja al teléfono ni se lee con JWT.
--
-- Forward-only: esta migración no se edita una vez aplicada.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. El trigger por fila
-- ----------------------------------------------------------------------------

create function public.tg_parametro_global_auditar()
returns trigger
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_evento    text;
  v_fila      public.parametro_global;
  v_anterior  integer;
  v_nuevo     integer;
  v_extra     jsonb := '{}'::jsonb;
begin
  if tg_op = 'INSERT' then
    v_evento := 'parametro_global_alta';
    v_fila := new;
    v_nuevo := new.valor;
  elsif tg_op = 'DELETE' then
    v_evento := 'parametro_global_baja';
    v_fila := old;
    v_anterior := old.valor;
    v_extra := jsonb_build_object('definitiva', true);
  else
    v_fila := new;
    if old.deleted_at is null and new.deleted_at is not null then
      -- La baja lógica: el valor que tenía deja de valer.
      v_evento := 'parametro_global_baja';
      v_anterior := old.valor;
      v_extra := jsonb_build_object('definitiva', false);
    elsif old.deleted_at is not null and new.deleted_at is null then
      -- Una fila dada de baja vuelve a valer: no había valor vigente antes.
      v_evento := 'parametro_global_alta';
      v_nuevo := new.valor;
    elsif old.valor is distinct from new.valor or old.clave is distinct from new.clave then
      v_evento := 'parametro_global_cambio';
      v_anterior := old.valor;
      v_nuevo := new.valor;
    else
      -- Ni el valor, ni la clave, ni la baja: nada que registrar (p. ej. un UPDATE que solo toca
      -- updated_at o sync_version).
      return null;
    end if;
  end if;

  -- Quién: auth.uid() lo pone auditoria.registrar(). Sin usuario (SQL Editor, service_role), el rol
  -- del servidor: el de la petición si trae JWT, el de la conexión si no.
  perform auditoria.registrar(
    v_evento, 'parametro_global', v_fila.id, null,
    jsonb_build_object('clave', v_fila.clave,
                       'valor_anterior', v_anterior,
                       'valor_nuevo', v_nuevo,
                       'rol', coalesce(auth.role(), session_user::text)) || v_extra);
  return null;
end;
$$;

comment on function public.tg_parametro_global_auditar() is
  'Trigger de parametro_global (0110, backend-supabase#152): cada alta, cambio de valor y baja de una fila '
  'escribe su evento en audit_log (parametro_global_alta / _cambio / _baja) en la misma transacción, con '
  'el valor anterior y el nuevo, y el rol del servidor si no hay usuario. Un UPDATE sin cambios no '
  'escribe nada.';

revoke all on function public.tg_parametro_global_auditar()
  from public, anon, authenticated, service_role;

create trigger parametro_global_auditar_cambio
  after insert or update or delete on public.parametro_global
  for each row execute function public.tg_parametro_global_auditar();

-- ----------------------------------------------------------------------------
-- 2. TRUNCATE: no hay fila que nombrar, pero tampoco puede pasar sin registro
-- ----------------------------------------------------------------------------

create function public.tg_parametro_global_vaciado()
returns trigger
language plpgsql
volatile
security definer
set search_path = ''
as $$
begin
  perform auditoria.registrar(
    'parametro_global_vaciado', 'parametro_global', null, null,
    jsonb_build_object('filas', (select count(*) from public.parametro_global),
                       'rol', coalesce(auth.role(), session_user::text)));
  return null;
end;
$$;

comment on function public.tg_parametro_global_vaciado() is
  'Trigger de TRUNCATE de parametro_global (0110, backend-supabase#152): deja el evento '
  'parametro_global_vaciado con cuántas filas había.';

revoke all on function public.tg_parametro_global_vaciado()
  from public, anon, authenticated, service_role;

create trigger parametro_global_auditar_vaciado
  before truncate on public.parametro_global
  for each statement execute function public.tg_parametro_global_vaciado();
