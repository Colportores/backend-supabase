-- RPC de ingesta batch (§4, §6.1 del formato de cable).
--
-- Un solo round trip para todo el lote, y aceptación por job: un registro
-- inválido no tumba a los demás. La alternativa —una query por job— multiplica
-- la latencia por el tamaño del lote, que es justo lo que RR-02 no perdona.

-- Aplica UN job. Devuelve el objeto `result` del formato de cable.
--
-- El bloque `exception` de abajo no es cosmético: en PL/pgSQL abre una
-- subtransacción, y es lo que hace que un job con un payload roto no se lleve
-- puesto el lote entero.
create function sync.aplicar_job(p_usuario uuid, p_job jsonb)
returns jsonb language plpgsql as $$
declare
  v_id uuid := (p_job ->> 'client_op_id')::uuid;
begin
  return sync.aplicar_job_interno(p_usuario, p_job);
exception
  -- Clase 22 (data_exception) y clase 23 (integrity_constraint_violation): el
  -- payload está mal. Una fecha que no es fecha, un texto donde va un número,
  -- una FK que no existe. Eso es INVALID —visible, corregible con requeue— y
  -- no puede tumbar a los demás jobs del lote.
  --
  -- Sin esto, un solo job venenoso hace fallar el push entero, el motor lo
  -- clasifica como 5xx transitorio y lo reintenta para siempre: la cola del
  -- colportor queda bloqueada y ninguna venta vuelve a subir.
  --
  -- Lo que NO se atrapa —deadlock, conexión caída, falta de memoria— sube y
  -- sale como 500. Ahí reintentar sí es lo correcto.
  when data_exception or integrity_constraint_violation then
    return jsonb_build_object(
      'client_op_id', v_id,
      'outcome', 'invalid',
      'code', sqlstate,
      'message', sqlerrm
    );
end;
$$;

create function sync.aplicar_job_interno(p_usuario uuid, p_job jsonb)
returns jsonb language plpgsql as $$
declare
  v_op_id     uuid   := (p_job ->> 'client_op_id')::uuid;
  v_entidad   text   := p_job ->> 'entity';
  v_op        text   := p_job ->> 'op';
  v_version   int    := (p_job ->> 'sync_version')::int;
  v_payload   jsonb  := p_job -> 'payload';
  v_pk        uuid;
  v_tabla     regclass;
  v_cols      text[];
  v_usadas    text[];
  v_cache     sync.op_cache%rowtype;
  v_actual    jsonb;
  v_version_nueva int;
  -- EXECUTE no toca FOUND en PL/pgSQL: hay que leer ROW_COUNT a mano. Con
  -- FOUND, un insert que chocó con una PK existente se reportaba `accepted`
  -- porque la variable venía en true de un SELECT anterior.
  v_filas     int;
begin
  if v_op_id is null then
    return sync.rechazo(v_op_id, 'OP_ID_REQUERIDO', 'falta client_op_id');
  end if;

  -- Cache de intentos (§5.3). Gana sobre cualquier validación: un op que ya se
  -- aplicó vuelve `duplicate` y no se re-valida. Al revés, un job aplicado cuya
  -- respuesta se perdió y que en el reintento cae en una validación quedaría
  -- INVALID con la fila ya escrita: el colportor vería en la cola de error una
  -- venta que en realidad ya cobró.
  select * into v_cache from sync.op_cache where client_op_id = v_op_id;
  if found then
    return jsonb_build_object(
      'client_op_id', v_op_id,
      'outcome', 'duplicate',
      'sync_version', v_cache.sync_version
    );
  end if;

  select e.tabla into v_tabla from sync.entidad e where e.nombre = v_entidad;
  if v_tabla is null then
    return sync.rechazo(v_op_id, 'ENTIDAD_DESCONOCIDA',
                        format('%L no está registrada para sync', v_entidad));
  end if;

  v_pk := (v_payload ->> 'id')::uuid;
  if v_pk is null then
    return sync.rechazo(v_op_id, 'PK_FALTANTE', 'el payload no trae "id"');
  end if;

  -- Solo las columnas que el cliente puede escribir (§5.4). Las del servidor se
  -- descartan aunque vengan.
  v_cols := sync.columnas_escribibles(v_entidad);
  select array_agg(k) into v_usadas
  from jsonb_object_keys(v_payload) k
  where k = any (v_cols);

  if v_op = 'insert' then
    execute format(
      'insert into %s (%s, pk_usuario) select %s, $2 from jsonb_populate_record(null::%s, $1) x on conflict (id) do nothing',
      v_tabla,
      (select string_agg(quote_ident(c), ', ') from unnest(v_usadas) c),
      (select string_agg('x.' || quote_ident(c), ', ') from unnest(v_usadas) c),
      v_tabla
    ) using v_payload, p_usuario;
    get diagnostics v_filas = row_count;

    if v_filas > 0 then
      execute format('select sync_version from %s where id = $1', v_tabla)
        into v_version_nueva using v_pk;
      return sync.ok(v_op_id, 'accepted', v_version_nueva, v_entidad, p_usuario);
    end if;

    -- La PK ya existe. §7: el UUID v7 lo generó el dispositivo, así que es la
    -- misma fila y no otra. Éxito idempotente, no error.
    execute format('select sync_version from %s where id = $1', v_tabla)
      into v_version_nueva using v_pk;
    return sync.ok(v_op_id, 'duplicate', v_version_nueva, v_entidad, p_usuario);
  end if;

  if v_op not in ('update', 'delete') then
    return sync.rechazo(v_op_id, 'OP_INVALIDA', format('op %L', v_op));
  end if;

  -- Con los decimales como texto: el `server_row` de un conflicto es una fila
  -- como cualquier otra y viaja igual que las del pull.
  execute format('select %s from %s t where t.id = $1',
                 sync.expresion_json(v_tabla), v_tabla)
    into v_actual using v_pk;
  if v_actual is null then
    return sync.rechazo(v_op_id, 'FILA_INEXISTENTE',
                        format('%s no existe en %s', v_pk, v_entidad));
  end if;

  -- LWW por sync_version (§5.4). Si el servidor tiene una más nueva, gana él y
  -- devuelve su fila: el cliente resuelve sin un pull extra.
  if v_version is null or (v_actual ->> 'sync_version')::int <> v_version then
    perform sync.registrar(v_op_id, p_usuario, v_entidad, 'conflict',
                           (v_actual ->> 'sync_version')::int, null, null);
    return jsonb_build_object(
      'client_op_id', v_op_id,
      'outcome', 'conflict',
      'sync_version', (v_actual ->> 'sync_version')::int,
      'server_row', v_actual
    );
  end if;

  -- La versión va en el WHERE del propio UPDATE, no solo en el `if` de arriba.
  --
  -- Entre aquel SELECT y este UPDATE hay una ventana: en READ COMMITTED, otra
  -- transacción puede bumpear la fila justo ahí. El UPDATE quedaría esperando
  -- el lock, y al soltarse re-leería la fila y escribiría igual, pisando el
  -- cambio ajeno y devolviendo `accepted` con una versión que el cliente creía
  -- vieja. Es la actualización perdida clásica, y en este dominio significa que
  -- el estado de una ubicación que dos dispositivos tocaron a la vez queda en
  -- el que llegó primero, sin que nadie se entere.
  --
  -- Con la versión en el WHERE, el UPDATE es un compare-and-swap: o aplica
  -- sobre la versión que el cliente esperaba, o no aplica y se reporta como
  -- conflicto. El `if` de arriba sigue sirviendo para el caso común, que es
  -- devolver el server_row sin pagar un UPDATE que no va a hacer nada.
  if v_op = 'delete' then
    execute format(
      'update %s set deleted = true, sync_version = sync_version + 1, updated_at = now() '
      'where id = $1 and sync_version = $2 returning sync_version',
      v_tabla) into v_version_nueva using v_pk, v_version;
  else
    execute format(
      'update %s t set (%s) = (select %s from jsonb_populate_record(null::%s, $1) x), '
      'sync_version = t.sync_version + 1, updated_at = now() '
      'where t.id = $2 and t.sync_version = $3 returning t.sync_version',
      v_tabla,
      (select string_agg(quote_ident(c), ', ') from unnest(v_usadas) c),
      (select string_agg('x.' || quote_ident(c), ', ') from unnest(v_usadas) c),
      v_tabla
    ) into v_version_nueva using v_payload, v_pk, v_version;
  end if;

  get diagnostics v_filas = row_count;
  if v_filas = 0 then
    -- Otro escritor ganó la carrera entre el SELECT y el UPDATE.
    execute format('select %s from %s t where t.id = $1',
                   sync.expresion_json(v_tabla), v_tabla)
      into v_actual using v_pk;
    perform sync.registrar(v_op_id, p_usuario, v_entidad, 'conflict',
                           (v_actual ->> 'sync_version')::int, null, null);
    return jsonb_build_object(
      'client_op_id', v_op_id,
      'outcome', 'conflict',
      'sync_version', (v_actual ->> 'sync_version')::int,
      'server_row', v_actual
    );
  end if;

  return sync.ok(v_op_id, 'accepted', v_version_nueva, v_entidad, p_usuario);
end;
$$;

-- Helpers: registrar en el cache y armar la respuesta.

create function sync.registrar(
  p_op_id uuid, p_usuario uuid, p_entidad text, p_outcome text,
  p_version int, p_codigo text, p_mensaje text)
returns void language sql as $$
  insert into sync.op_cache
    (client_op_id, pk_usuario, entidad, outcome, sync_version, codigo, mensaje)
  values (p_op_id, p_usuario, coalesce(p_entidad, '?'), p_outcome, p_version, p_codigo, p_mensaje)
  on conflict (client_op_id) do nothing;
$$;

create function sync.ok(p_op_id uuid, p_outcome text, p_version int,
                        p_entidad text, p_usuario uuid)
returns jsonb language plpgsql as $$
begin
  perform sync.registrar(p_op_id, p_usuario, p_entidad, p_outcome, p_version, null, null);
  return jsonb_build_object('client_op_id', p_op_id, 'outcome', p_outcome,
                            'sync_version', p_version);
end;
$$;

-- Un rechazo NO entra al cache. El job nunca se aplicó, así que no hay nada que
-- deduplicar: si el colportor corrige el dato y reencola, tiene que volver a
-- validarse contra el estado nuevo y no contra la respuesta vieja.
create function sync.rechazo(p_op_id uuid, p_codigo text, p_mensaje text)
returns jsonb language sql as $$
  select jsonb_build_object('client_op_id', p_op_id, 'outcome', 'invalid',
                            'code', p_codigo, 'message', p_mensaje);
$$;

-- ---------------------------------------------------------------------------
-- El RPC que llama el BFF
-- ---------------------------------------------------------------------------

create function sync.push(p_usuario uuid, p_jobs jsonb)
returns jsonb language plpgsql as $$
declare
  v_job      jsonb;
  v_results  jsonb := '[]'::jsonb;
begin
  -- En orden: los jobs de una misma entidad se aplican en orden de creación
  -- (§5.5), y un item nunca antes que su venta.
  for v_job in select * from jsonb_array_elements(p_jobs) loop
    v_results := v_results || jsonb_build_array(sync.aplicar_job(p_usuario, v_job));
  end loop;

  return jsonb_build_object(
    'server_time', to_char(now() at time zone 'utc', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"'),
    'results', v_results
  );
end;
$$;
