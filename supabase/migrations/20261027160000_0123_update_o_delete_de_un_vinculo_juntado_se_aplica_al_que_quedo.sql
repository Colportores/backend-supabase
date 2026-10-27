-- ============================================================================
-- 0123 · El update o delete de un vínculo que ya se juntó se aplica al que quedó, con conflicto si
--        cambió (backend-supabase#143; HU-UBI-006; seguimiento de #105; decisión de Cristian del 23/10,
--        «Edición tarde»: «Pasarlo al que quedó»)
--
-- El caso: Ana, sin señal, carga a Pedro en la casa ya unida (su vínculo, id 31) y después cambia la
-- dirección de cobro de ese Pedro. Al subir, el alta de 31 se juntó con el vínculo que Pedro ya tenía en
-- A (0064: 31 no existe como fila, queda en `espacio_persona_union`). Hasta ahora el update o el delete
-- de 31 daba `invalid FILA_INEXISTENTE`: el cambio de Ana se perdía en la cola de error. Ahora:
--
--   · update  -> se aplica al vínculo que quedó (`destino_id` del registro, y desde ahí la cadena de
--     uniones de `redirigir_vinculo()`), pero SOLO si ese vínculo no cambió desde que se juntó: la
--     versión que tenía en ese momento se guarda en la unión (`destino_version`) y el update se compara
--     contra ella, no contra la `sync_version` del job (el teléfono no conoce la del que quedó). Si
--     cambió (otro lo editó, se reactivó, se fundió su espacio en otro), vuelve `conflict` con el
--     `server_row` del que quedó y nada se pisa. Ana lo ve y decide, como cualquier conflicto del push.
--     Aceptado, responde `accepted` con la `sync_version` nueva del que quedó, y la unión pasa a
--     recordar esa versión: una segunda edición del mismo id juntado, que ya viajaba en la cola, no
--     choca con la primera. Reintentar el mismo trabajo vuelve `duplicate` (caché de client_op_id).
--   · delete  -> se acepta sin dar de baja al que quedó: ya estaba juntado, así que sacarlo de la casa
--     «cuenta como hecho». Responde `accepted` con la `sync_version` del que quedó, que no cambia.
--   · Esos ids dejan de responder `FILA_INEXISTENTE`. Un id que no se juntó (o que juntó otra persona)
--     sigue respondiéndolo igual que antes: el registro solo lo ve quien subió el vínculo.
--
-- El móvil lo trata como hoy un aceptado o un conflicto: no hay un resultado nuevo en el contrato (el
-- `merged` de 0064 es solo del alta). Va al contrato §6.1 (docs-organizacion).
--
-- ## Qué se aplica del update
--
-- Solo `ubicacion_cobranza_alt_id` (la dirección de cobro del caso). `id`, `espacio_id` y `persona_id`
-- no: el que quedó ya está en su espacio con su persona (es lo que «juntar» significa), y mover el
-- vínculo de otro a un espacio que no es el suyo no es una edición de Ana. `deleted_at` tampoco: dar de
-- baja al que quedó es lo que el delete NO hace, y reactivarlo ya lo hizo la unión si el alta venía viva;
-- un update que no trae la cobranza alternativa se acepta sin tocar nada. La cobranza alternativa que
-- nombra a una casa fundida pasa a A por el trigger de siempre (0035).
--
-- ## Permisos
--
-- El que quedó lo creó otra persona y la RLS de `espacio_persona` (`created_by = auth.uid()`) no
-- dejaría a Ana escribirlo: la escritura la hace una función SECURITY DEFINER, igual que el trigger
-- de 0064 que registra la unión. Lo que habilita el permiso es haber subido el vínculo que se juntó
-- (`espacio_persona_union.created_by`), así que no se ensancha ningún permiso: nadie toca el vínculo
-- de otro por un id que no subió.
--
-- ## Las uniones anteriores a esta migración
--
-- No guardaron la versión (`destino_version` null): no se sabe si el que quedó cambió desde entonces.
-- Ante la duda se bloquea: el update vuelve `conflict` y el delete se acepta (no escribe nada).
--
-- Datos: ninguno cambia. Una columna nueva en el registro (solo de la nube, fuera del sync), una
-- función nueva, y se reemplazan dos (el trigger de espacio_persona y sync.aplicar_job_interno).
-- Forward-only: esta migración no se edita una vez aplicada.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. El registro guarda la versión del que quedó
-- ----------------------------------------------------------------------------

alter table public.espacio_persona_union add column destino_version bigint;

comment on column public.espacio_persona_union.destino_version is
  'La sync_version del vínculo que quedó (destino_id) al juntarse, o la que dejó el último update que se '
  'le aplicó por este id (0123). El update de un id juntado se aplica solo si el que quedó sigue en esa '
  'versión; si no, es un conflicto. Null en las uniones anteriores a 0123: versión desconocida, conflicto.';

-- ----------------------------------------------------------------------------
-- 2. El trigger de espacio_persona anota la versión al juntar
-- ----------------------------------------------------------------------------

-- Igual que en 0064; cambia solo el registro de la unión: suma la versión del que quedó.

create or replace function public.tg_espacio_persona_union_redirige()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_destino   uuid;
  v_existente public.espacio_persona%rowtype;
  v_version   bigint;
begin
  if new.ubicacion_cobranza_alt_id is not null then
    new.ubicacion_cobranza_alt_id := public.redirigir_ubicacion(new.ubicacion_cobranza_alt_id);
  end if;

  -- Un alta de un id que ya existe (el reintento de un job, o un payload roto) no se toca: la PK lo
  -- resuelve (`duplicate` en el push). Así nunca se registra un id que sí tiene fila.
  if tg_op = 'INSERT' and exists (select 1 from public.espacio_persona x where x.id = new.id) then
    return new;
  end if;

  v_destino := public.redirigir_espacio(new.espacio_id);
  if v_destino is distinct from new.espacio_id then
    -- ¿La misma persona ya tiene su vínculo en el espacio de A? (es único por espacio y persona,
    -- de quien sea: la unión de 0026 también funde los de distintos colportores)
    select * into v_existente
      from public.espacio_persona ep
     where ep.espacio_id = v_destino and ep.persona_id = new.persona_id
       and ep.id <> new.id;
    if found then
      if tg_op = 'INSERT' then
        -- 0064: se JUNTA con el que ya está. No se guarda otra fila (chocaría con el unique si el
        -- espacio fundido ya tiene la suya); se recuerda que este id es el de ese vínculo, y lo que lo
        -- nombre (visitas, ventas, agendas) cae en él por redirigir_vinculo().
        if new.deleted_at is null
           and (v_existente.deleted_at is not null
                or (v_existente.ubicacion_cobranza_alt_id is null and new.ubicacion_cobranza_alt_id is not null)) then
          update public.espacio_persona
             set deleted_at = null,
                 ubicacion_cobranza_alt_id = coalesce(ubicacion_cobranza_alt_id, new.ubicacion_cobranza_alt_id)
           where id = v_existente.id;
        end if;
        -- 0123: la versión del que quedó en este instante (después de reactivarlo, si hizo falta): el
        -- update que llegue después se compara contra ella.
        select ep.sync_version into v_version from public.espacio_persona ep where ep.id = v_existente.id;
        insert into public.espacio_persona_union (duplicada_id, destino_id, destino_version)
        values (new.id, v_existente.id, v_version)
        on conflict (duplicada_id) do nothing;
        return null;
      end if;

      -- UPDATE de un vínculo que ya existe (como en 0035): este queda donde llegó, dado de baja; el de
      -- A se reactiva y hereda la cobranza. Sus visitas y ventas nombran este id, y redirigir_vinculo()
      -- las lleva al de A.
      if new.deleted_at is null then
        new.deleted_at := now();
        update public.espacio_persona
           set deleted_at = null,
               ubicacion_cobranza_alt_id = coalesce(ubicacion_cobranza_alt_id, new.ubicacion_cobranza_alt_id)
         where id = v_existente.id
           and (deleted_at is not null
                or (ubicacion_cobranza_alt_id is null and new.ubicacion_cobranza_alt_id is not null));
      end if;
    else
      new.espacio_id := v_destino;
    end if;
  end if;
  return new;
end;
$$;

-- ----------------------------------------------------------------------------
-- 3. El update o delete de un vínculo juntado
-- ----------------------------------------------------------------------------

-- Aplica el update o el delete de un vínculo que el servidor juntó con otro al llegar (p_vinculo_id es un
-- duplicada_id que subió quien llama). Devuelve null si ese id no se juntó o lo subió otra persona (el
-- push sigue con FILA_INEXISTENTE, como antes); si no, un jsonb:
--   {"outcome": "accepted", "sync_version": <la del que quedó>}
--   {"outcome": "conflict", "sync_version": <la del que quedó>, "server_row": <su fila>}
-- Corre como DEFINER: el que quedó no es de quien llama y la RLS no lo dejaría escribir (ver arriba).
create function public.aplicar_a_vinculo_juntado(p_vinculo_id uuid, p_op text, p_payload jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_union   public.espacio_persona_union%rowtype;
  v_final   uuid;
  v_fila    public.espacio_persona%rowtype;
  v_nueva   bigint;
  v_json    jsonb;
begin
  select * into v_union
    from public.espacio_persona_union pu
   where pu.duplicada_id = p_vinculo_id
     and (auth.uid() is null or pu.created_by is not distinct from auth.uid());
  if not found then
    return null;
  end if;

  -- El vínculo que quedó hoy: si su espacio se fundió después, el de A (0035); si el suyo se juntó con
  -- otro, ese (0064).
  v_final := public.redirigir_vinculo(v_union.destino_id);

  -- Con candado: entre la comparación y el UPDATE nadie más lo cambia (READ COMMITTED releería la fila
  -- al soltarse el candado, y se compararía contra la versión nueva).
  select * into v_fila from public.espacio_persona ep where ep.id = v_final for update;

  -- El delete cuenta como hecho: el vínculo ya estaba juntado, y sacarlo de la casa no da de baja al que quedó.
  if p_op = 'delete' then
    return jsonb_build_object('outcome', 'accepted', 'sync_version', v_fila.sync_version);
  end if;

  -- El update se compara contra la versión que tenía el que quedó al juntarse. Cambió si: la unión no la
  -- guardó (anterior a 0123), el que quedó ya es otro (su espacio se fundió o se juntó con otro, que
  -- además lo dio de baja y subió su versión) o su versión es otra.
  if v_union.destino_version is null
     or v_final <> v_union.destino_id
     or v_fila.sync_version <> v_union.destino_version then
    execute format('select %s from public.espacio_persona t where t.id = $1',
                   sync.expresion_json('public.espacio_persona'::regclass))
      into v_json using v_final;
    return jsonb_build_object('outcome', 'conflict', 'sync_version', v_fila.sync_version,
                              'server_row', v_json);
  end if;

  -- Solo la cobranza alternativa: no id, espacio_id, persona_id ni deleted_at (ver arriba).
  if not (p_payload ? 'ubicacion_cobranza_alt_id') then
    return jsonb_build_object('outcome', 'accepted', 'sync_version', v_fila.sync_version);
  end if;

  update public.espacio_persona ep
     set ubicacion_cobranza_alt_id = (p_payload ->> 'ubicacion_cobranza_alt_id')::uuid
   where ep.id = v_final
  returning ep.sync_version into v_nueva;

  -- La unión recuerda la versión nueva: una segunda edición del mismo id juntado no choca con la primera.
  update public.espacio_persona_union set destino_version = v_nueva where id = v_union.id;

  return jsonb_build_object('outcome', 'accepted', 'sync_version', v_nueva);
end;
$$;

comment on function public.aplicar_a_vinculo_juntado(uuid, text, jsonb) is
  'Aplica el update o delete de un vínculo que se juntó con otro al llegar (espacio_persona_union, 0064) '
  'al que quedó: el delete se acepta sin tocarlo; el update solo si el que quedó no cambió desde la unión '
  '(destino_version), si no es un conflicto con su fila. Null si el id no se juntó o lo subió otra '
  'persona. Para sync.aplicar_job_interno (0123, backend-supabase#143).';


-- ----------------------------------------------------------------------------
-- 4. El push: update y delete de un id juntado
-- ----------------------------------------------------------------------------

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
  v_juntada    jsonb;
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
    -- 0123: un vínculo que se juntó con otro al llegar no existe como fila (0064): su update o delete
    -- se aplica al que quedó (decisión de Cristian del 23/10, «Edición tarde»), con conflicto si el
    -- que quedó cambió después de la unión. Solo si el id lo subió quien llama; si no, sigue como antes.
    if v_entidad = 'espacio_persona' then
      v_juntada := public.aplicar_a_vinculo_juntado(v_pk, v_op, v_payload);
      if v_juntada is not null then
        if v_juntada ->> 'outcome' = 'conflict' then
          return jsonb_build_object(
            'client_op_id', p_op_id, 'outcome', 'conflict',
            'sync_version', (v_juntada ->> 'sync_version')::bigint,
            'server_row', v_juntada -> 'server_row');
        end if;
        return sync.registrar(p_op_id, v_entidad, 'accepted', (v_juntada ->> 'sync_version')::bigint);
      end if;
    end if;
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

comment on function sync.aplicar_job_interno(uuid, jsonb) is
  'Aplica un job del push. Además de insert/update/delete de una entidad (0002, 0021, 0064), '
  'op ''marcar_como_duplicado'' con entity ''ubicacion'' y payload {duplicada_id, conservada_id}: llama a '
  'marcar_como_duplicado(B, A) y responde accepted, o duplicate con ya_unida (0101, HU-UBI-006). El '
  'update o delete de un espacio_persona que se juntó con otro al llegar se aplica al que quedó, con '
  'conflicto si cambió desde la unión (0123).';

-- ----------------------------------------------------------------------------
-- 5. Privilegios
-- ----------------------------------------------------------------------------

-- La llama sync.aplicar_job_interno, que corre como quien llama (authenticated). Los default privileges
-- de la imagen dan EXECUTE a anon y authenticated sobre cada función nueva de public (ver 0008): se
-- revoca todo y se da lo que corresponde. Solo toca algo si el id lo subió quien llama.
revoke all on function public.aplicar_a_vinculo_juntado(uuid, text, jsonb) from public, anon, authenticated, service_role;
grant execute on function public.aplicar_a_vinculo_juntado(uuid, text, jsonb) to authenticated, service_role;
