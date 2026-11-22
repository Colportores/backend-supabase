-- ============================================================================
-- 0101 · La unión de duplicados como trabajo del motor: sync_push aplica «marcar como duplicado»
--        (backend-supabase#70; HU-UBI-006; decisión de Cristian del 06/10, «Duplicado»: «Se encola y
--        sube después»)
--
-- El caso: la colportora, sin señal, une B a A en la vista 10. La app espera los 8 s de «Deshacer»,
-- une en el teléfono y encola un trabajo. Cuando hay señal, el motor lo manda y el servidor hace lo
-- mismo que `marcar_como_duplicado(B, A)` (0026, 0035, 0069).
--
-- Qué cambia (solo el push; ninguna tabla, ninguna columna, ningún dato):
--
--   1. `sync.aplicar_job_interno` acepta un trabajo que NO es un upsert:
--        {"client_op_id": <uuid>, "entity": "ubicacion", "op": "marcar_como_duplicado",
--         "payload": {"duplicada_id": <B>, "conservada_id": <A>}}
--      Se aplica en su lugar del lote (los trabajos se aplican en el orden en que llegan, así que
--      queda después de lo que ese teléfono tenía pendiente de A y de B) llamando a la RPC, que
--      tiene sus permisos y sus errores. Responde:
--        · `accepted` si la unión se aplicó;
--        · `duplicate` con `ya_unida: true` si B ya estaba unida (a A o a otra; o A ya se había unido
--          a B): es idempotente, un reintento no hace nada de más;
--        · los dos con `destino_id` (A, o aquella a la que A ya se había unido) y el `sync_version`
--          de B. Entran al cache de client_op_id: el reintento del mismo trabajo vuelve `duplicate`.
--        · `invalid` con `UB003` (A está de baja), `UB004` (B = A), `42501` (no escribe en las dos),
--          `CG001` (corrección ajena en la gracia), `FILA_INEXISTENTE` (alguna no existe),
--          `PK_FALTANTE` (falta un id) u `OP_INVALIDA` (la op con otra entidad); el lote sigue.
--      Lo que otro cargó en B mientras tanto pasa a A cuando se aplica, y lo que llega después va a A
--      (0035, 0064): ahí no cambia nada.
--
--   2. `sync.aplicar_job` atrapa `UB003` y `UB004` como `invalid`, igual que UB001/UB002/CG001: sin
--      eso, un SQLSTATE propio saldría del push y se llevaría puesto el lote entero.
--
-- `sync.push` no cambia: `invalid` con 23503, 42501 o FILA_INEXISTENTE cuando A o B es un alta en
-- conflicto del mismo lote sigue volviendo como «en espera» (0017). La app no encola la unión si una
-- de las dos no está en el servidor («Par local», mobile#285).
-- ============================================================================

-- Igual que en 0064; cambia solo la rama `marcar_como_duplicado` (0101), antes de leer la PK.
create or replace function sync.aplicar_job_interno(p_op_id uuid, p_job jsonb)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_entidad   text  := p_job ->> 'entity';
  v_op        text  := p_job ->> 'op';
  v_version   bigint;
  v_payload   jsonb := p_job -> 'payload';
  v_tabla     regclass;
  v_pk_col    text;
  v_push_ok   boolean;
  v_pk        uuid;
  v_usadas    text[];
  v_cache     sync.op_cache%rowtype;
  v_actual    jsonb;
  v_nueva     bigint;
  -- EXECUTE no toca FOUND en PL/pgSQL: hay que leer ROW_COUNT a mano. Con FOUND,
  -- un insert que chocó con una PK existente se reportaría `accepted` porque la
  -- variable venía en true de un SELECT anterior.
  v_filas     integer;
  v_juntado   uuid;
  v_duplicada  uuid;
  v_conservada uuid;
  v_union      jsonb;
begin
  if p_op_id is null then
    return sync.rechazo(p_op_id, 'OP_ID_REQUERIDO', 'falta client_op_id o no es un uuid');
  end if;

  -- El cache gana sobre cualquier validación. Un op ya aplicado vuelve
  -- `duplicate` y no se re-valida: si no, un job aplicado cuya respuesta se
  -- perdió y que en el reintento cae en una validación quedaría INVALID con la
  -- fila ya escrita, y el colportor vería en la cola de error una venta que ya
  -- cobró. Como acá solo entra lo aplicado, un conflicto anterior no lo activa.
  select * into v_cache from sync.op_cache where client_op_id = p_op_id;
  if found then
    return jsonb_build_object('client_op_id', p_op_id, 'outcome', 'duplicate',
                              'sync_version', v_cache.sync_version);
  end if;

  select e.tabla, e.columna_pk, e.permite_push
    into v_tabla, v_pk_col, v_push_ok
    from sync.entidad e where e.nombre = v_entidad;
  if v_tabla is null then
    return sync.rechazo(p_op_id, 'ENTIDAD_DESCONOCIDA',
                        format('%L no está registrada para sync', v_entidad));
  end if;

  if not v_push_ok then
    return sync.rechazo(p_op_id, 'ENTIDAD_DE_SOLO_LECTURA',
                        format('%L es una réplica: la app no la escribe', v_entidad));
  end if;

  -- 0101: «marcar como duplicado» (HU-UBI-006, backend-supabase#70; decisión de Cristian del 06/10,
  -- «Duplicado»: «Se encola y sube después»). No es un upsert: no tiene PK ni sync_version, y lo aplica
  -- la misma operación atómica e idempotente de la RPC, `marcar_como_duplicado(B, A)`, con los mismos
  -- permisos y los mismos errores. Va después del cache y de los chequeos de la entidad, y antes de
  -- todo lo que piensa en una fila: el payload trae los dos ids (`duplicada_id` = B, `conservada_id` =
  -- A) y no una PK. Se aplica en su lugar del lote: después de lo que ese teléfono subió de A y de B.
  --   · aplicado -> `accepted`; B ya estaba unida (a A o a otra; A ya se había unido a B) -> `duplicate`,
  --     con `ya_unida: true`. Los dos traen `destino_id` (A, o aquella a la que A ya se había unido) y el
  --     `sync_version` de B, y entran al cache: el reintento con el mismo client_op_id es `duplicate`.
  --   · UB003, UB004, 42501 y CG001 salen como `invalid` (los atrapa sync.aplicar_job, abajo) y una
  --     ubicación que no existe, como `invalid FILA_INEXISTENTE`: ninguno tumba el lote.
  if v_op = 'marcar_como_duplicado' then
    if v_entidad <> 'ubicacion' then
      return sync.rechazo(p_op_id, 'OP_INVALIDA',
                          format('op %L solo va con la entidad ubicacion', v_op));
    end if;

    v_duplicada  := (v_payload ->> 'duplicada_id')::uuid;
    v_conservada := (v_payload ->> 'conservada_id')::uuid;
    if v_duplicada is null or v_conservada is null then
      return sync.rechazo(p_op_id, 'PK_FALTANTE', 'el payload no trae duplicada_id y conservada_id');
    end if;

    begin
      v_union := public.marcar_como_duplicado(v_duplicada, v_conservada);
    exception when no_data_found then
      -- La RPC la levanta (P0002) cuando alguna de las dos no existe.
      return sync.rechazo(p_op_id, 'FILA_INEXISTENTE', sqlerrm);
    end;

    select t.sync_version into v_nueva from public.ubicacion t where t.id = v_duplicada;
    return sync.registrar(p_op_id, v_entidad,
                          case when (v_union ->> 'ya_unida')::boolean then 'duplicate' else 'accepted' end,
                          v_nueva)
           || jsonb_build_object('ya_unida', (v_union ->> 'ya_unida')::boolean,
                                 'destino_id', v_union -> 'destino_id');
  end if;

  v_pk := (v_payload ->> v_pk_col)::uuid;
  if v_pk is null then
    return sync.rechazo(p_op_id, 'PK_FALTANTE',
                        format('el payload no trae %L', v_pk_col));
  end if;

  -- Solo las columnas que el cliente puede escribir (contrato §5.4). Las del
  -- servidor se descartan aunque vengan.
  select array_agg(k) into v_usadas
    from jsonb_object_keys(v_payload) k
   where k = any (sync.columnas_escribibles(v_entidad));

  if v_usadas is null then
    return sync.rechazo(p_op_id, 'PAYLOAD_VACIO',
                        'el payload no trae ninguna columna escribible');
  end if;

  -- ---- insert ----
  if v_op = 'insert' then
    execute format(
      'insert into %s (%s) select %s from jsonb_populate_record(null::%s, $1) x '
      'on conflict (%I) do nothing',
      v_tabla,
      (select string_agg(quote_ident(c), ', ' order by c) from unnest(v_usadas) c),
      (select string_agg('x.' || quote_ident(c), ', ' order by c) from unnest(v_usadas) c),
      v_tabla, v_pk_col
    ) using v_payload;
    get diagnostics v_filas = row_count;

    -- 0064: el insert no insertó nada porque el vínculo se juntó con el que ya tenía la misma persona
    -- en el espacio fundido (el trigger de espacio_persona lo registró). No es un duplicado: el
    -- teléfono tiene que saber cuál es el vínculo que quedó. Reintentar da lo mismo.
    if v_filas = 0 and v_entidad = 'espacio_persona' then
      v_juntado := public.vinculo_juntado(v_pk);
      if v_juntado is not null then
        return jsonb_build_object('client_op_id', p_op_id, 'outcome', 'merged',
                                  'merged_into', v_juntado);
      end if;
    end if;

    execute format('select t.sync_version from %s t where t.%I = $1', v_tabla, v_pk_col)
      into v_nueva using v_pk;

    -- La PK ya existía: el UUID v7 lo generó el dispositivo, así que es la misma
    -- fila y no otra. Éxito idempotente, no error (contrato §7, replay).
    return sync.registrar(p_op_id, v_entidad,
                          case when v_filas > 0 then 'accepted' else 'duplicate' end, v_nueva);
  end if;

  if v_op not in ('update', 'delete') then
    return sync.rechazo(p_op_id, 'OP_INVALIDA', format('op %L', v_op));
  end if;

  -- ---- update / delete ----
  begin
    v_version := (p_job ->> 'sync_version')::bigint;
  exception when data_exception then
    v_version := null;
  end;

  -- 0021: corregir lo que cargó otro con la campaña en la gracia de 0020 (decisión de Cristian
  -- del 02/10 en #52). Antes de leer la fila: la lectura no tiene gracia y no la vería.
  if public.correccion_ajena_en_gracia(v_entidad, v_pk) then
    return sync.rechazo(p_op_id, 'CG001',
                        'La campaña ya terminó: solo se guardan tus ventas y lo que cargaste vos. Lo '
                        'que cargó otra persona queda como estaba. Descartá este cambio.');
  end if;

  execute format('select %s from %s t where t.%I = $1',
                 sync.expresion_json(v_tabla), v_tabla, v_pk_col)
    into v_actual using v_pk;
  if v_actual is null then
    return sync.rechazo(p_op_id, 'FILA_INEXISTENTE',
                        format('%s no existe en %s', v_pk, v_entidad));
  end if;

  -- LWW por sync_version (contrato §5.4). Si el servidor tiene una más nueva,
  -- gana él y devuelve su fila: el cliente resuelve sin un pull extra.
  if v_version is null or (v_actual ->> 'sync_version')::bigint <> v_version then
    return jsonb_build_object(
      'client_op_id', p_op_id, 'outcome', 'conflict',
      'sync_version', (v_actual ->> 'sync_version')::bigint,
      'server_row', v_actual);
  end if;

  -- La versión va en el WHERE del propio UPDATE, no solo en el `if` de arriba.
  --
  -- Entre aquel SELECT y este UPDATE hay una ventana: en READ COMMITTED otra
  -- transacción puede bumpear la fila justo ahí. El UPDATE quedaría esperando el
  -- lock, y al soltarse re-leería la fila y escribiría igual, pisando el cambio
  -- ajeno y devolviendo `accepted` con una versión que el cliente creía vieja.
  -- Es la actualización perdida clásica, y acá significa que el estado de una
  -- ubicación que dos dispositivos tocaron a la vez queda en el que llegó
  -- primero, sin que nadie se entere.
  --
  -- Con la versión en el WHERE es un compare-and-swap: o aplica sobre la versión
  -- que el cliente esperaba, o no aplica y se reporta como conflicto.
  --
  -- sync_version, updated_at y xmin_w no se asignan acá: los pone el trigger de
  -- auditoría del 0001 (§8), que corre igual venga la escritura de donde venga.
  if v_op = 'delete' then
    execute format('update %s t set deleted_at = now() where t.%I = $1 and t.sync_version = $2',
                   v_tabla, v_pk_col) using v_pk, v_version;
  else
    execute format(
      'update %s t set %s from jsonb_populate_record(null::%s, $1) x '
      'where t.%I = $2 and t.sync_version = $3',
      v_tabla,
      (select string_agg(format('%I = x.%I', c, c), ', ' order by c) from unnest(v_usadas) c),
      v_tabla, v_pk_col
    ) using v_payload, v_pk, v_version;
  end if;
  get diagnostics v_filas = row_count;

  if v_filas = 0 then
    -- Otro escritor ganó la carrera entre el SELECT y el UPDATE.
    execute format('select %s from %s t where t.%I = $1',
                   sync.expresion_json(v_tabla), v_tabla, v_pk_col)
      into v_actual using v_pk;
    return jsonb_build_object(
      'client_op_id', p_op_id, 'outcome', 'conflict',
      'sync_version', (v_actual ->> 'sync_version')::bigint,
      'server_row', v_actual);
  end if;

  execute format('select t.sync_version from %s t where t.%I = $1', v_tabla, v_pk_col)
    into v_nueva using v_pk;
  return sync.registrar(p_op_id, v_entidad, 'accepted', v_nueva);
end;
$$;

-- Igual que en 0072, más UB003 y UB004 (0101). Sus privilegios siguen (create or replace los conserva).
create or replace function sync.aplicar_job(p_job jsonb)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_id          uuid;
  v_restriccion text;
begin
  -- El cast va adentro del bloque protegido: un client_op_id malformado es un
  -- payload inválido, no un 500.
  begin
    v_id := (p_job ->> 'client_op_id')::uuid;
  exception when data_exception then
    v_id := null;
  end;

  return sync.aplicar_job_interno(v_id, p_job);
exception
  -- Clase 22, clase 23 y 42501: el payload está mal o la RLS rechazó la fila. INVALID, sin
  -- reintento automático, y sin tumbar al resto del lote (ver 0002).
  --
  -- Menos D1 (0017): misma dirección a menos de 100 m de otra ubicación viva. No es un payload
  -- roto: la fila es buena y la resuelve el colportor en la vista 10. Vuelve como conflicto, sin
  -- server_row (no hay fila del servidor que aplicar), y no entra al cache de client_op_id.
  when data_exception or integrity_constraint_violation or insufficient_privilege then
    get stacked diagnostics v_restriccion = constraint_name;
    if sqlstate = '23505' and v_restriccion = 'ubicacion_direccion_unica' then
      return jsonb_build_object(
        'client_op_id', v_id,
        'outcome', 'conflict',
        'code', sqlstate,
        'constraint', v_restriccion,
        'message', sqlerrm
      );
    end if;
    return jsonb_build_object(
      'client_op_id', v_id,
      'outcome', 'invalid',
      'code', sqlstate,
      'message', sqlerrm
    );
  -- La baja de una casa con ventas o con visitas de otro colportor (0018), la corrección ajena en la
  -- gracia (CG001, 0021), reactivar una casa que se unió a otra (UB005, 0051) y los topes de las cuotas
  -- (AG001 a AG003, 0068) y anular un cobro fuera de plazo, con el ticket validado o ya anulado (CB001 a
  -- CB003, CB005 y CB006, 0072) y la unión de duplicados con A de baja o con B = A (UB003 y UB004, 0101): códigos propios, que la app traduce a un aviso. INVALID como el resto, sin tumbar el lote.
  when sqlstate 'UB001' or sqlstate 'UB002' or sqlstate 'UB003' or sqlstate 'UB004' or sqlstate 'CG001' or sqlstate 'UB005'
    or sqlstate 'AG001' or sqlstate 'AG002' or sqlstate 'AG003'
    or sqlstate 'CB001' or sqlstate 'CB002' or sqlstate 'CB003' or sqlstate 'CB005' or sqlstate 'CB006' then
    return jsonb_build_object(
      'client_op_id', v_id,
      'outcome', 'invalid',
      'code', sqlstate,
      'message', sqlerrm
    );
end;
$$;

comment on function sync.aplicar_job_interno(uuid, jsonb) is
  'Aplica un job del push. Además de insert/update/delete de una entidad (0002, 0021, 0064), '
  'op ''marcar_como_duplicado'' con entity ''ubicacion'' y payload {duplicada_id, conservada_id}: llama a '
  'marcar_como_duplicado(B, A) y responde accepted, o duplicate con ya_unida (0101, HU-UBI-006).';
