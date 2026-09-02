-- RLS sobre las tablas sincronizables.
--
-- **Nota de reparto (§4)**: las RLS son de Cristian. Esto es el mínimo que la
-- sincronización necesita para no tener un agujero, escrito acá porque el
-- motivo es de la arquitectura de sync y conviene que quede junto a ella.
-- Revisalo y movelo si preferís tenerlo con el resto del esquema.
--
-- El motivo: §6 dice que **Realtime va directo a Supabase, sin pasar por el
-- BFF**. Por ese camino no corre `sync.pull`, así que el filtrado manual por
-- `pk_usuario` no protege nada. Sin RLS, un colportor puede suscribirse a los
-- cambios de otro. Verificado: con las tablas como estaban, un rol
-- `authenticated` cualquiera veía las jornadas de todos.

-- ---------------------------------------------------------------------------
-- Quién es el usuario en el camino directo
-- ---------------------------------------------------------------------------

-- En Supabase esto es `auth.uid()`. Se envuelve para que las políticas también
-- se puedan probar en un Postgres pelado, seteando la GUC a mano.
create function sync.usuario_actual()
returns uuid language plpgsql stable as $$
declare v_id text;
begin
  begin
    execute 'select auth.uid()::text' into v_id;
  exception when undefined_function or invalid_schema_name then
    v_id := current_setting('request.jwt.claim.sub', true);
  end;
  return nullif(v_id, '')::uuid;
exception when others then
  -- Sin identidad no se ve nada. Fallar hacia "no autorizado" y no hacia
  -- "todo" es la única opción defendible acá.
  return null;
end;
$$;

-- ---------------------------------------------------------------------------
-- Las políticas
-- ---------------------------------------------------------------------------

alter table jornada   enable row level security;
alter table ubicacion enable row level security;

-- Solo lectura, y solo lo propio.
--
-- Escribir por el camino directo no está permitido a propósito: §2 dice que la
-- app nunca escribe las tablas del cloud, *stagea* y el motor sube. Todo lo que
-- entra pasa por `sync.push`, que es donde viven la idempotencia, el LWW y el
-- descarte de columnas server-authoritative. Una escritura directa se saltearía
-- las tres cosas.
create policy jornada_propia on jornada
  for select to public
  using (pk_usuario = sync.usuario_actual());

create policy ubicacion_propia on ubicacion
  for select to public
  using (pk_usuario = sync.usuario_actual());

-- ---------------------------------------------------------------------------
-- El camino del BFF sigue funcionando
-- ---------------------------------------------------------------------------

-- `security definer`: las funciones corren como su dueño y no las alcanza la
-- RLS. No es un atajo — es la separación de los dos caminos:
--
--   BFF        → sync.push / sync.pull, que filtran por el pk_usuario que el
--                BFF sacó del JWT verificado.
--   Realtime   → acceso directo a la tabla, donde manda la RLS.
--
-- El `search_path` fijo es obligatorio en una función `security definer`: sin
-- él, quien la llama puede anteponer un schema propio y hacer que `jornada`
-- resuelva a una tabla suya, ejecutando código con los privilegios del dueño.
alter function sync.push(uuid, jsonb)             security definer set search_path = sync, public, pg_temp;
alter function sync.pull(uuid, text[], jsonb, int) security definer set search_path = sync, public, pg_temp;
alter function sync.aplicar_job(uuid, jsonb)       security definer set search_path = sync, public, pg_temp;
alter function sync.aplicar_job_interno(uuid, jsonb) security definer set search_path = sync, public, pg_temp;

-- Y que no las pueda llamar cualquiera desde PostgREST: al BFF se le da el rol
-- que corresponda, pero el camino directo no tiene por qué invocarlas.
revoke execute on function sync.push(uuid, jsonb) from public;
revoke execute on function sync.pull(uuid, text[], jsonb, int) from public;
