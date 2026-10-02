-- ============================================================================
-- 0022 · Funciones de entrada del sync en public: sync_push y sync_pull (backend-supabase#53)
--
-- ADR-013 (docs-organizacion#22, decisión de Cristian del 02/10): en la Fase 1 no hay BFF. El
-- motor llama directo a `POST /rest/v1/rpc/sync_push` y `.../sync_pull` con la anon key y el JWT
-- del usuario (SupabaseRpcTransport, front-colportores-mobile#178). El schema `sync` no se expone
-- en la Data API (config.toml: public y graphql_public), así que hacen falta puertas en public.
-- Acuerdos del #53 (comentario 5958415169): puntos 1 a 3 de abajo.
--
-- ## 1. El cuerpo: el mismo JSON que arma el codec del motor
--
-- Reciben un solo argumento, `p_body jsonb`, y no parámetros sueltos (registro de Cristian del
-- 02/10 en #53): `formato-de-cable.md` (sync_engine) sigue siendo la única definición del mensaje.
-- PostgREST pasa el cuerpo entero a `p_body` con `Prefer: params=single-object`, o el motor lo
-- manda como `{"p_body": …}`.
--
--   push:  {"device": {sobre}, "jobs": [ … ]}             (pushRequestToJson, tal cual)
--   pull:  {"device": {sobre}, "entities": ["venta", …], "watermark": "…", "limit": 500}
--
-- El pull pasa de GET con query a POST con cuerpo: `entities` es un array y no una lista con
-- comas, y el sobre va en `device`, como en el push. `watermark` y `limit` son opcionales.
-- La respuesta es la de sync.push() y sync.pull(), con una diferencia: el `watermark` del pull
-- sale como string (el jsonb de sync.pull() serializado). Para el motor es opaco y lo guarda como
-- String (pullResponseFromJson); un objeto rompería el cast. Vuelve igual en el pedido siguiente.
--
-- ## 2. El sobre y los rechazos del lote entero (SQLSTATE de la clase CS, libre hasta acá)
--
-- sync.validar_sobre() sigue a envelopeFromJson() del codec:
--   · sin `device`: es una app anterior al sobre, no un cliente roto → CS002, como el 426 del BFF;
--   · `device` presente y mal formado (no es objeto, `device_id` no es UUID, `schema_version` no
--     es entero) → CS001;
--   · `schema_version` menor a la mínima que entiende la base (hoy 1) → CS002;
--   · `app_version` es telemetría: si falta o está mal, no rechaza nada.
-- `jobs`, `entities`, `watermark` o `limit` con otra forma → 22023 (invalid_parameter_value),
-- como sync.push() con un `p_jobs` que no es array.
--
--   CS001  sobre inválido                         el motor: payload (los jobs a INVALID)
--   CS002  schema_version vieja o sin sobre       el motor: transitorio (actualizar la app)
--   CS003  lote demasiado grande (500 jobs, 1 MB) el motor: parte el lote y lo reintenta
--
-- PostgREST devuelve todo SQLSTATE propio como HTTP 400, así que el motor tiene que clasificar
-- CS002 y CS003 por el `code` del cuerpo y no por el status (contrato §6, tabla de rechazos).
-- El resultado por job (accepted / duplicate / conflict / invalid / en espera) sigue en el cuerpo
-- de una respuesta 200, como en sync.push().
--
-- ## 3. Topes en la puerta: 500 jobs y 1 MB
--
-- public.sync_push los valida antes de delegar, con CS003, para que el motor parta el lote en vez
-- de reintentarlo entero. sync.push() conserva los suyos (500 jobs, 8 MB, 54000) como defensa de
-- quien la llame por otro camino. El MB se mide sobre `jobs` como texto de jsonb, que pone un
-- espacio después de cada `:` y cada `,`: pesa un poco más que el JSON compacto con el que el
-- motor arma los lotes (buildBatches, kMaxBatchBytes). Un lote al borde puede volver con CS003; el
-- motor lo parte y sigue.
--
-- ## 4. El pull baja siempre toda la ciudad de su zona (contrato 0.9.8)
--
-- public.sync_pull no expone el alcance: llama a sync.pull() con 'ciudad'
-- (mis_ciudades_de_trabajo(): la ciudad de su zona y, sin zona, todas las de la campaña). El
-- default 'zona' de sync.pull() es de la 0.9.5. Sacar p_alcance de sync.pull() va en otro issue.
--
-- ## 5. Privilegios: SECURITY INVOKER y sync.* sigue con su grant a authenticated
--
-- Las dos corren como quien llama: la RLS y auth.uid() son las del colportor, igual que si
-- llamara a sync.*. Por eso authenticated necesita EXECUTE sobre sync.push() (0002) y sync.pull()
-- (0011), y sobre las internas que llaman; esos grants ya existen y se quedan. No abren nada:
-- PostgREST solo resuelve funciones de los schemas expuestos, y anon no tiene USAGE sobre sync.
-- EXECUTE de las dos puertas: solo authenticated (y service_role); ni anon ni public.
--
-- ## 6. El hint del tope de 500 en sync.push()
--
-- Nombraba al BFF, que en la Fase 1 no existe. Ahora apunta al motor, que arma los lotes. El resto
-- de sync.push() es el de 0017, sin cambios.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. El sobre
-- ----------------------------------------------------------------------------

-- Valida el sobre del cuerpo y devuelve el device_id. Interna de las puertas de abajo; corre como
-- quien llama y no lee ninguna tabla.
create function sync.validar_sobre(p_body jsonb)
returns uuid
language plpgsql
immutable
set search_path = ''
as $$
declare
  -- La mínima schema_version del cable que entiende la base. Sube solo ante un cambio
  -- incompatible del cable (contrato §9).
  c_schema_minima constant integer := 1;
  v_sobre   jsonb := p_body -> 'device';
  v_version jsonb;
begin
  if v_sobre is null or jsonb_typeof(v_sobre) = 'null' then
    raise exception 'el pedido no trae sobre (device): la app es anterior al formato actual'
      using errcode = 'CS002',
            hint = 'actualizá la app; los cambios quedan en el teléfono y suben después';
  end if;

  if jsonb_typeof(v_sobre) <> 'object' then
    raise exception 'el sobre (device) tiene que ser un objeto'
      using errcode = 'CS001';
  end if;

  if jsonb_typeof(v_sobre -> 'device_id') is distinct from 'string'
     or (v_sobre ->> 'device_id') !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then
    raise exception 'device_id tiene que ser un UUID'
      using errcode = 'CS001';
  end if;

  v_version := v_sobre -> 'schema_version';
  if jsonb_typeof(v_version) is distinct from 'number'
     or (v_version #>> '{}')::numeric <> trunc((v_version #>> '{}')::numeric) then
    raise exception 'schema_version tiene que ser un entero'
      using errcode = 'CS001';
  end if;

  if (v_version #>> '{}')::numeric < c_schema_minima then
    raise exception 'schema_version % es vieja: la mínima es %', v_version #>> '{}', c_schema_minima
      using errcode = 'CS002',
            hint = 'actualizá la app; los cambios quedan en el teléfono y suben después';
  end if;

  return (v_sobre ->> 'device_id')::uuid;
end;
$$;

comment on function sync.validar_sobre(jsonb) is
  'Valida el sobre (device: device_id, app_version, schema_version) de un pedido de sync y '
  'devuelve el device_id. CS001 sobre inválido, CS002 sin sobre o schema_version vieja (0022). '
  'Interna de public.sync_push() y public.sync_pull().';

-- ----------------------------------------------------------------------------
-- 2. public.sync_push
-- ----------------------------------------------------------------------------

create function public.sync_push(p_body jsonb)
returns jsonb
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_device uuid;
  v_jobs   jsonb;
  v_bytes  integer;
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

  return sync.push(v_jobs, v_device);
end;
$$;

comment on function public.sync_push(jsonb) is
  'Entrada del push del motor (POST /rest/v1/rpc/sync_push, ADR-013): valida el sobre y los '
  'topes del lote (500 jobs, 1 MB; CS003) y delega en sync.push() como quien llama (0022).';

-- ----------------------------------------------------------------------------
-- 3. public.sync_pull
-- ----------------------------------------------------------------------------

create function public.sync_pull(p_body jsonb)
returns jsonb
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_device    uuid;
  v_entidades text[];
  v_marca     jsonb;
  v_limite    integer;
  v_delta     jsonb;
begin
  if auth.uid() is null then
    raise exception 'sync_pull requiere un usuario autenticado'
      using errcode = 'insufficient_privilege';
  end if;

  v_device := sync.validar_sobre(p_body);

  if jsonb_typeof(p_body -> 'entities') is distinct from 'array'
     or exists (select 1 from jsonb_array_elements(p_body -> 'entities') e
                 where jsonb_typeof(e) <> 'string') then
    raise exception 'entities tiene que ser un array de nombres de entidad'
      using errcode = 'invalid_parameter_value';
  end if;
  v_entidades := array(select jsonb_array_elements_text(p_body -> 'entities'));

  -- Ausente o null: réplica desde cero. Si no, el string que devolvió el pull anterior.
  case coalesce(jsonb_typeof(p_body -> 'watermark'), 'null')
    when 'null' then
      v_marca := '{}'::jsonb;
    when 'string' then
      begin
        v_marca := (p_body ->> 'watermark')::jsonb;
      exception when invalid_text_representation then
        v_marca := null;
      end;
      if jsonb_typeof(v_marca) is distinct from 'object' then
        raise exception 'watermark no es uno que haya devuelto el pull'
          using errcode = 'invalid_parameter_value';
      end if;
    else
      raise exception 'watermark tiene que ser el string que devolvió el pull'
        using errcode = 'invalid_parameter_value';
  end case;

  -- Fuera de rango lo acota sync.pull() (0002); acá solo se pide que sea un entero.
  case coalesce(jsonb_typeof(p_body -> 'limit'), 'null')
    when 'null' then
      v_limite := null;
    when 'number' then
      begin
        v_limite := (p_body ->> 'limit')::integer;
      exception when invalid_text_representation or numeric_value_out_of_range then
        v_limite := null;
      end;
      if v_limite is null or v_limite::numeric <> (p_body ->> 'limit')::numeric then
        raise exception 'limit tiene que ser un entero'
          using errcode = 'invalid_parameter_value';
      end if;
    else
      raise exception 'limit tiene que ser un entero'
        using errcode = 'invalid_parameter_value';
  end case;

  -- Siempre 'ciudad': el colportor no elige el alcance (contrato 0.9.8, sección 4 del header).
  v_delta := sync.pull(v_entidades, v_marca, v_limite, v_device, 'ciudad');

  return jsonb_set(v_delta, '{watermark}', to_jsonb((v_delta -> 'watermark')::text));
end;
$$;

comment on function public.sync_pull(jsonb) is
  'Entrada del pull del motor (POST /rest/v1/rpc/sync_pull, ADR-013): valida el sobre y delega en '
  'sync.pull() con alcance ciudad (contrato 0.9.8) como quien llama. El watermark viaja como '
  'string opaco (0022).';

-- ----------------------------------------------------------------------------
-- 4. sync.push(): el hint del tope de 500 ya no nombra al BFF
-- ----------------------------------------------------------------------------

-- Igual que en 0017; cambia solo el hint del tope de 500.
create or replace function sync.push(p_jobs jsonb, p_device uuid default null)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_job       jsonb;
  v_res       jsonb;
  v_results   jsonb := '[]'::jsonb;
  v_arranque  timestamptz := clock_timestamp();
  v_ok        integer := 0;
  v_dup       integer := 0;
  v_conf      integer := 0;
  v_inv       integer := 0;
  v_ops       uuid[] := '{}'::uuid[];
  v_salida    jsonb;
  -- Las filas del lote que no entraron por un alta en conflicto, y las que esperan por ellas.
  v_en_espera uuid[] := '{}'::uuid[];
  v_espera    uuid;
  v_pk        uuid;
begin
  if auth.uid() is null then
    raise exception 'sync.push requiere un usuario autenticado'
      using errcode = 'insufficient_privilege';
  end if;

  if jsonb_typeof(p_jobs) is distinct from 'array' then
    raise exception 'p_jobs tiene que ser un array de jobs'
      using errcode = 'invalid_parameter_value';
  end if;

  -- Los topes de lote de 0002 (500 jobs, 8 MB): ver ahí el porqué.
  if jsonb_array_length(p_jobs) > 500 then
    raise exception 'lote de % jobs: el máximo es 500', jsonb_array_length(p_jobs)
      using errcode = 'program_limit_exceeded',
            hint = 'partí el lote; el motor los arma de hasta 500 jobs (RR-02)';
  end if;

  if octet_length(p_jobs::text) > 8 * 1024 * 1024 then
    raise exception 'lote de % bytes: el máximo es 8 MB', octet_length(p_jobs::text)
      using errcode = 'program_limit_exceeded',
            hint = 'partí el lote; RR-02 dimensiona los lotes en ~1 MB';
  end if;

  -- En orden: los jobs de una misma entidad se aplican en orden de creación
  -- (contrato §5.5), y un item nunca antes que su venta.
  for v_job in select * from jsonb_array_elements(p_jobs) loop
    v_res := sync.aplicar_job(v_job);

    -- Cuelga de una fila en espera: no es un error de payload, espera (0017).
    if v_res ->> 'outcome' = 'invalid'
       and v_res ->> 'code' in ('23503', '42501', 'FILA_INEXISTENTE')
       and cardinality(v_en_espera) > 0 then
      v_espera := sync.fila_en_espera(v_job, v_en_espera);
      if v_espera is not null then
        v_res := jsonb_build_object(
          'client_op_id', v_res -> 'client_op_id',
          'outcome', 'conflict',
          'code', 'ESPERA_ALTA_EN_CONFLICTO',
          'depends_on', v_espera,
          'message', format('Queda en espera: depende de %s, que no se guardó porque su alta está en '
                            'conflicto (misma dirección que otra ubicación). Se sube cuando se '
                            'resuelva en la vista 10.', v_espera));
      end if;
    end if;

    -- Un alta que no entró por un conflicto sin fila del servidor (D1, o en espera): lo que
    -- cuelgue de ella más adelante en el lote también espera.
    if v_res ->> 'outcome' = 'conflict' and not (v_res ? 'server_row')
       and v_job ->> 'op' = 'insert' then
      v_pk := null;
      begin
        v_pk := (v_job -> 'payload' ->> (select e.columna_pk from sync.entidad e
                                          where e.nombre = v_job ->> 'entity'))::uuid;
      exception when data_exception then
        v_pk := null;
      end;
      if v_pk is not null then
        v_en_espera := v_en_espera || v_pk;
      end if;
    end if;

    v_results := v_results || jsonb_build_array(v_res);

    case v_res ->> 'outcome'
      when 'accepted'  then v_ok   := v_ok   + 1;
      when 'duplicate' then v_dup  := v_dup  + 1;
      when 'conflict'  then v_conf := v_conf + 1;
      else                  v_inv  := v_inv  + 1;
    end case;

    -- El op_id sale del RESULTADO, no del job crudo (ver 0002).
    if v_res ->> 'client_op_id' is not null then
      v_ops := v_ops || ((v_res ->> 'client_op_id')::uuid);
    end if;
  end loop;

  -- device_id is null protege el reintento (ver 0002).
  if p_device is not null and array_length(v_ops, 1) is not null then
    update sync.op_cache set device_id = p_device
     where client_op_id = any (v_ops) and device_id is null;
  end if;

  v_salida := jsonb_build_object(
    'server_time', to_char(now() at time zone 'utc', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"'),
    'results', v_results
  );

  -- El log va al final y en la misma transacción que el lote (ver 0002).
  insert into sync.log (device_id, operacion, duracion_ms, jobs,
                        aceptados, duplicados, conflictos, invalidos,
                        bytes_entrada, bytes_salida)
  values (p_device, 'push',
          extract(epoch from clock_timestamp() - v_arranque) * 1000,
          jsonb_array_length(p_jobs), v_ok, v_dup, v_conf, v_inv,
          octet_length(p_jobs::text), octet_length(v_salida::text));

  return v_salida;
end;
$$;

-- ----------------------------------------------------------------------------
-- 5. Privilegios
-- ----------------------------------------------------------------------------

-- sync.validar_sobre: la llaman las puertas, que corren como quien llama, así que authenticated la
-- necesita; anon no (como sync.fila_en_espera, 0017).
revoke all on function sync.validar_sobre(jsonb) from public, anon;
grant execute on function sync.validar_sobre(jsonb) to authenticated, service_role;

-- `authenticated` también en el revoke: en una base creada desde cero los default privileges de la
-- imagen le dan EXECUTE sobre cada función nueva de public (ver 0008). Después se le da explícito.
revoke all on function public.sync_push(jsonb), public.sync_pull(jsonb) from public, anon, authenticated;
grant execute on function public.sync_push(jsonb), public.sync_pull(jsonb) to authenticated, service_role;

-- sync.push() conserva sus privilegios (create or replace no los toca).
