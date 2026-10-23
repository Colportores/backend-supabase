-- ============================================================================
-- 0053 · Último dato recibido por colportor: usuario.ultimo_push_at
--        (backend-supabase#93, HU-CAM-008, vista 31 «Inicio», C2 de docs#69, supuesto S61)
--
-- La vista rápida de Inicio muestra, en la fila de cada colportor, hace cuánto el servidor recibió
-- datos de su teléfono («sin conexión hace 4 días»). Sirve para distinguir al colportor que no salió
-- a trabajar del que salió y no tiene conexión (la app funciona sin internet). Es un dato VISUAL
-- (decisión de Cristian, 21/10): sin umbral, sin color y sin alerta; no hay nada que calcular acá.
--
-- ## Qué guarda
--
-- `usuario.ultimo_push_at` (timestamptz, null): el momento del último `sync_push` que el servidor
-- recibió de ese usuario, de cualquier tipo (S61). Null = todavía no llegó ninguna sincronización:
-- el panel muestra «sin datos». Un colportor que nunca subió nada devuelve null, no una fecha
-- inventada. No expone nada de los clientes: es una marca de tiempo del propio colportor.
--
-- ## Cuándo se actualiza
--
-- `public.sync_push()` (la puerta del motor, 0042) la actualiza cuando el lote pasó la puerta: sobre
-- válido, topes respetados y respuesta 200. Cuentan los lotes cuyos jobs vuelven accepted,
-- duplicate, conflict o invalid, porque en todos el teléfono estaba conectado y el servidor recibió
-- sus datos; un lote que la puerta rechaza (CS001, CS002, CS003, 42501) no cuenta, porque no se
-- recibió. Un pull no cuenta: el dato es del push. `sync.push()` llamada directo (tests, otros
-- caminos del servidor) tampoco: no es el teléfono quien llama.
--
-- Nunca retrocede: dos pushes del mismo colportor que terminan en otro orden del que empezaron
-- (la transacción más vieja confirma última) dejan el más reciente.
--
-- ## Quién la escribe
--
-- Solo el servidor. La puerta corre como quien llama (SECURITY INVOKER, RLS de la 0042), pero la
-- marca la escribe `sync.registrar_push_recibido()` (SECURITY DEFINER, en `sync`, que la Data API no
-- expone: no es una RPC del panel ni de la app). Y como `usuario_update_propio` deja que cada
-- usuario actualice su fila entera, un trigger descarta en silencio un valor de `ultimo_push_at`
-- que llegue de `authenticated` o `anon` (un PATCH de la propia fila), igual que la suspensión
-- (0004): un colportor no puede fingir que está conectado. service_role y los procesos del servidor
-- sí la escriben.
--
-- ## Efectos laterales (aceptados)
--
-- El UPDATE pasa por `tg_auditoria_update`: sube `updated_at` y `sync_version` de la fila de
-- `usuario` en cada push. `usuario` no está en `sync.entidad` (0015), así que a nadie le baja ni
-- invalida un job. Un solo UPDATE de una fila por push, tomado al final de la transacción del lote.
--
-- ## La lectura
--
-- La devuelve la lectura del tablero de Inicio (backend-supabase#94), que corre como DEFINER y ya
-- decide qué coordinador ve a qué colportor. Acá no se agrega ninguna lectura: `usuario` sigue
-- siendo legible solo por el propio usuario y el ADMIN (0015).
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. La columna
-- ----------------------------------------------------------------------------

alter table public.usuario add column ultimo_push_at timestamptz;

comment on column public.usuario.ultimo_push_at is
  'Cuándo el servidor recibió el último sync_push de este usuario (0053, HU-CAM-008, S61). null = '
  'todavía no llegó ninguno. Solo la escribe el servidor (sync.registrar_push_recibido); es un dato '
  'visual del panel (tiempo sin conexión), sin umbral ni alerta.';

-- ----------------------------------------------------------------------------
-- 2. Solo el servidor la escribe
-- ----------------------------------------------------------------------------

-- Igual que tg_usuario_suspension_servidor() (0004): se coerciona al valor viejo en silencio, para
-- que un cliente que manda su fila entera no falle, pero tampoco gane. La marca se distingue por el
-- rol que ejecuta el UPDATE y no por auth.uid(): la función de abajo corre con el JWT del colportor
-- (auth.uid() no es null) pero como su dueño, y current_user es el dueño.
create function public.tg_usuario_ultimo_push_servidor()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.ultimo_push_at is distinct from old.ultimo_push_at
     and current_user in ('authenticated', 'anon') then
    new.ultimo_push_at := old.ultimo_push_at;
  end if;
  return new;
end;
$$;

comment on function public.tg_usuario_ultimo_push_servidor() is
  'BEFORE UPDATE de usuario: descarta un cambio de ultimo_push_at hecho por authenticated o anon '
  '(la marca es del servidor, 0053).';

revoke all on function public.tg_usuario_ultimo_push_servidor() from public, anon, authenticated;

create trigger usuario_ultimo_push_servidor
  before update on public.usuario
  for each row execute function public.tg_usuario_ultimo_push_servidor();

-- ----------------------------------------------------------------------------
-- 3. Registrar el push recibido
-- ----------------------------------------------------------------------------

-- Marca el momento en que el servidor recibió un push del usuario autenticado. now() es el inicio
-- de la transacción del lote; greatest() la deja no retroceder. Sin sesión no hace nada.
create function sync.registrar_push_recibido()
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  update public.usuario
     set ultimo_push_at = now()
   where id = (select auth.uid())
     and (ultimo_push_at is null or ultimo_push_at < now());
end;
$$;

comment on function sync.registrar_push_recibido() is
  'Guarda en usuario.ultimo_push_at el momento del push que recibió el usuario autenticado, sin '
  'retroceder (0053, HU-CAM-008). La llama public.sync_push(); el schema sync no está en la Data API.';

revoke all on function sync.registrar_push_recibido() from public, anon;
grant execute on function sync.registrar_push_recibido() to authenticated, service_role;

-- ----------------------------------------------------------------------------
-- 4. La puerta del push la registra
-- ----------------------------------------------------------------------------

-- Mismo cuerpo que en 0042; suma el registro después de que sync.push() respondió (así un lote que
-- falla entero no deja marca, y la fila de usuario se toma al final de la transacción).
create or replace function public.sync_push(p_body jsonb)
returns jsonb
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_device    uuid;
  v_jobs      jsonb;
  v_bytes     integer;
  v_respuesta jsonb;
begin
  -- Antes que el sobre: sin sesión no se le dice nada del pedido.
  if auth.uid() is null then
    raise exception 'sync_push requiere un usuario autenticado'
      using errcode = 'insufficient_privilege';
  end if;

  v_device := sync.validar_sobre(p_body);

  v_jobs := p_body -> 'jobs';
  if jsonb_typeof(v_jobs) is distinct from 'array' then
    raise exception 'jobs tiene que ser un array de jobs'
      using errcode = 'invalid_parameter_value';
  end if;

  if jsonb_array_length(v_jobs) > 500 then
    raise exception 'lote de % jobs: el máximo es 500', jsonb_array_length(v_jobs)
      using errcode = 'CS003',
            hint = 'partí el lote y reintentá cada parte';
  end if;

  v_bytes := octet_length(v_jobs::text);
  if v_bytes > 1024 * 1024 then
    raise exception 'lote de % bytes: el máximo es 1 MB', v_bytes
      using errcode = 'CS003',
            hint = 'partí el lote y reintentá cada parte';
  end if;

  v_respuesta := sync.push(v_jobs, v_device);

  -- El servidor recibió datos de este teléfono (HU-CAM-008, S61).
  perform sync.registrar_push_recibido();

  return v_respuesta;
end;
$$;

comment on function public.sync_push(jsonb) is
  'Entrada del push del motor (POST /rest/v1/rpc/sync_push, ADR-013): valida el sobre y los '
  'topes del lote (500 jobs, 1 MB; CS003), delega en sync.push() como quien llama (0042) y deja en '
  'usuario.ultimo_push_at el momento en que lo recibió (0053).';
