-- ============================================================================
-- 0050 · Unión de duplicados: el segundo vínculo de la misma persona en el espacio fundido se JUNTA
--        con el que ya está, no se rechaza (backend-supabase#105; HU-UBI-006; decisión de Cristian del
--        21/10, «Venta tarde»: «Juntar los dos»)
--
-- El caso: Luis une B a A mientras Ana, sin señal, cargó a Pedro y una venta en B. Cuando Ana
-- sincroniza, su vínculo de Pedro llega al espacio único de B, que ya se fundió en el de A, donde Pedro
-- ya tiene un vínculo. Hasta 0035 eso podía chocar con el unique (espacio_id, persona_id) (23505,
-- `invalid` en el push) y la venta quedaba en el teléfono sin subir. Ahora:
--
--   · El vínculo que llega se JUNTA con el existente: no se inserta una fila más; el servidor se
--     acuerda de que ese id es el del vínculo que quedó (public.espacio_persona_union) y las visitas,
--     agendas y ventas que lo nombran (en este push, en los siguientes o por PostgREST) se guardan en
--     el vínculo de A. Nada se rechaza y nada se pierde. Si el que llegó está vivo y el de A estaba
--     dado de baja, se reactiva; la cobranza alternativa que traía se hereda si el de A no tenía una
--     (lo mismo que ya hacía la unión misma, 0026/0035).
--   · La respuesta del push le dice al teléfono que su vínculo se juntó: un resultado nuevo
--     `{"client_op_id", "outcome": "merged", "merged_into": "<id del vínculo que queda>"}`. El motor lo
--     trata como terminado (`DONE`) y reapunta lo local que nombraba a su vínculo al que queda, sin
--     borrar nada (front-colportores-mobile#178). Va al contrato (docs/contrato-sync-engine.md §6.1).
--     Reintentar el mismo job (mismo `client_op_id` o no) vuelve a dar `merged` con el mismo destino.
--
-- ## El registro
--
--   · public.espacio_persona_union: `duplicada_id` (único; el id del vínculo que llegó y NO se
--     guardó: sin FK, esa fila no existe) → `destino_id` (el vínculo que quedó). Solo de la nube: NO
--     está en sync.entidad ni en Realtime, así que no va al pull y el contrato de las entidades no
--     cambia. Solo ids. Lo lee el ADMIN; lo escribe únicamente el trigger de espacio_persona.
--   · public.redirigir_vinculo() (la usan los triggers de visita, venta y agenda) mira primero este
--     registro y después sigue como en 0035 (si el vínculo está en un espacio fundido, el de la misma
--     persona en el espacio de A).
--   · public.vinculo_juntado(id): para sync.aplicar_job_interno (que corre como quien llama y no ve el
--     registro). Devuelve el vínculo que quedó solo si el id lo subió quien llama (created_by).
--
-- ## Lo que cambia en el trigger de espacio_persona
--
-- Solo en el INSERT. Antes: si la persona ya tenía vínculo en el espacio de destino, el que llegaba se
-- guardaba dado de baja donde llegó (en el espacio fundido), lo que chocaba con el unique si ahí ya
-- había otro de la misma persona (el fundido por la unión). Ahora no se guarda ninguno: el trigger
-- registra la unión y devuelve null (el INSERT no inserta, ni con ON CONFLICT DO NOTHING). La RLS de
-- espacio_persona es solo `created_by = auth.uid()` y el trigger de auditoría pone el created_by de
-- quien escribe, así que saltearla no ensancha ningún permiso. El UPDATE no cambia: mover un vínculo
-- ya existente a un espacio fundido donde su persona ya está sigue como en 0035 (queda de baja).
--
-- ## sync.push y sync.aplicar_job_interno
--
-- aplicar_job_interno (igual que en 0021) devuelve `merged` cuando un insert de espacio_persona no
-- inserta nada y el id está en el registro. Si no está, sigue siendo `duplicate` (la PK ya existía).
-- `merged` no entra al caché de client_op_id (que solo admite accepted y duplicate): no hace falta,
-- porque el reintento es idempotente por sí mismo. sync.push (igual que en 0042) cuenta `merged`
-- entre los aceptados del sync.log.
--
-- Update y delete de un vínculo que se juntó (un id que ya no existe): siguen dando FILA_INEXISTENTE.
-- Pendiente de decisión (mapa §2), ver el PR.
--
-- Datos: ninguno cambia. Se suman una tabla y una función, y se reemplazan cuatro funciones (el trigger de
-- espacio_persona, redirigir_vinculo, sync.aplicar_job_interno y sync.push).
-- Forward-only: esta migración no se edita una vez aplicada.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. El registro de los vínculos que se juntaron
-- ----------------------------------------------------------------------------

-- Con las columnas de auditoría y el cursor de todas las tablas de public (los tests de 0001 y 0002
-- lo exigen), aunque no esté en el sync. `created_by` sin FK, como en 0035.
create table public.espacio_persona_union (
  id            uuid primary key default public.uuid_generate_v7(),
  duplicada_id  uuid not null,
  destino_id    uuid not null references public.espacio_persona(id),
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  created_by    uuid default auth.uid(),
  deleted_at    timestamptz,
  sync_version  bigint not null default 0,
  xmin_w        xid8 not null default pg_current_xact_id(),
  constraint espacio_persona_union_distintos check (duplicada_id <> destino_id)
);

-- A un id se lo junta una sola vez; de ahí sale la idempotencia.
create unique index espacio_persona_union_duplicada_uidx on public.espacio_persona_union (duplicada_id);
-- Las FK se indexan (qué ids se juntaron en un vínculo).
create index espacio_persona_union_destino_idx on public.espacio_persona_union (destino_id);

comment on table public.espacio_persona_union is
  'Vínculos (espacio_persona) que llegaron tarde y se juntaron con el que ya tenía la misma persona en el '
  'espacio fundido (0050, backend-supabase#105): duplicada_id (el id que subió el teléfono; esa fila NO '
  'existe) → destino_id (el vínculo que quedó). Lo que llegue nombrando a duplicada_id se guarda en '
  'destino_id. Solo en la nube (no está en sync.entidad). Solo ids; lo lee el ADMIN.';
comment on column public.espacio_persona_union.duplicada_id is
  'El id del vínculo que subió el teléfono y no se guardó. Sin FK: no existe en espacio_persona. Único.';
comment on column public.espacio_persona_union.destino_id is 'El vínculo que quedó (puede haberse fundido después en otro: se sigue por redirigir_vinculo()).';
comment on column public.espacio_persona_union.created_by is 'Quién subió el vínculo que se juntó: solo él ve a dónde fue (vinculo_juntado()).';

create trigger espacio_persona_union_auditoria_insert before insert on public.espacio_persona_union
  for each row execute function public.tg_auditoria_insert();
create trigger espacio_persona_union_auditoria_update before update on public.espacio_persona_union
  for each row execute function public.tg_auditoria_update();

alter table public.espacio_persona_union enable row level security;

-- Solo el ADMIN la lee (soporte y auditoría). La escribe únicamente el trigger de espacio_persona
-- (SECURITY DEFINER): nadie tiene política de INSERT, UPDATE ni DELETE.
create policy espacio_persona_union_select_admin on public.espacio_persona_union
  for select to authenticated
  using ((select public.tiene_rol('ADMIN')));

revoke all on public.espacio_persona_union from anon, authenticated;
grant select on public.espacio_persona_union to authenticated;
grant all on public.espacio_persona_union to service_role;

-- ----------------------------------------------------------------------------
-- 2. A qué vínculo hay que escribir hoy
-- ----------------------------------------------------------------------------

-- Igual que en 0035, más el registro de los que se juntaron: si el id es de un vínculo que no se
-- guardó, se sigue al que quedó (y desde ahí, como siempre: si su espacio se fundió, al de A).
create or replace function public.redirigir_vinculo(p_vinculo_id uuid)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actual   uuid := p_vinculo_id;
  v_destino  uuid;
  v_saltos   integer := 0;
  v_espacio  uuid;
  v_persona  uuid;
  v_nuevo    uuid;
  v_vinculo  uuid;
begin
  -- 0050: el vínculo que se juntó con otro al llegar (no existe como fila) va al que quedó.
  loop
    select pu.destino_id into v_destino
      from public.espacio_persona_union pu
     where pu.duplicada_id = v_actual;
    exit when not found;
    v_actual := v_destino;
    v_saltos := v_saltos + 1;
    if v_saltos > 100 then
      raise exception using
        errcode = 'XX000',
        message = 'La cadena de vínculos juntados da la vuelta.';
    end if;
  end loop;

  select ep.espacio_id, ep.persona_id into v_espacio, v_persona
    from public.espacio_persona ep
   where ep.id = v_actual;
  if not found then
    return v_actual;
  end if;

  v_nuevo := public.redirigir_espacio(v_espacio);
  if v_nuevo = v_espacio then
    return v_actual;
  end if;

  -- Su espacio se fundió: la misma persona en el espacio de A (única por (espacio_id, persona_id)).
  select ep.id into v_vinculo
    from public.espacio_persona ep
   where ep.espacio_id = v_nuevo and ep.persona_id = v_persona;
  if found then
    return v_vinculo;
  end if;

  -- No tenía vínculo allá (no pasa si se fundió por la unión, que lo deja en uno u otro): se muda.
  update public.espacio_persona set espacio_id = v_nuevo where id = v_actual;
  return v_actual;
end;
$$;

comment on function public.redirigir_vinculo(uuid) is
  'El vínculo (espacio_persona) donde hay que escribir una visita, venta o agenda que nombra a '
  'p_vinculo_id: el que quedó si el suyo se juntó con otro al llegar (0050), o el de la misma persona en '
  'el espacio de A si el suyo se fundió (0035).';

-- A dónde fue un vínculo que subió quien llama y se juntó con otro; null si ese id no se juntó (o lo
-- subió otra persona: el registro no se lee desde afuera). La usa sync.aplicar_job_interno, que corre
-- como quien llama y no lee el registro.
create function public.vinculo_juntado(p_vinculo_id uuid)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_destino uuid;
begin
  select pu.destino_id into v_destino
    from public.espacio_persona_union pu
   where pu.duplicada_id = p_vinculo_id
     and (auth.uid() is null or pu.created_by is not distinct from auth.uid());
  if not found then
    return null;
  end if;
  return public.redirigir_vinculo(v_destino);
end;
$$;

comment on function public.vinculo_juntado(uuid) is
  'El vínculo que quedó cuando el que subió quien llama (p_vinculo_id) se juntó con otro al llegar '
  '(espacio_persona_union, 0050); null si no se juntó. Para la respuesta `merged` del push.';

-- ----------------------------------------------------------------------------
-- 3. El trigger de espacio_persona: el segundo vínculo de la misma persona se junta
-- ----------------------------------------------------------------------------

-- Igual que en 0035; cambia solo el INSERT de un vínculo cuya persona ya está en el espacio de A.
create or replace function public.tg_espacio_persona_union_redirige()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_destino   uuid;
  v_existente public.espacio_persona%rowtype;
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
        -- 0050: se JUNTA con el que ya está. No se guarda otra fila (chocaría con el unique si el
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
        insert into public.espacio_persona_union (duplicada_id, destino_id)
        values (new.id, v_existente.id)
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

comment on function public.tg_espacio_persona_union_redirige() is
  'BEFORE INSERT / UPDATE OF espacio_id, ubicacion_cobranza_alt_id de espacio_persona: lo que sube '
  'tarde al espacio fundido de B va al único de A; si la persona ya tiene vínculo en A, el que llega se '
  'junta con él (espacio_persona_union, 0050) y no se inserta; la cobranza alternativa que nombra a B '
  'pasa a A (0035).';

-- ----------------------------------------------------------------------------
-- 4. El push: la respuesta `merged`
-- ----------------------------------------------------------------------------

-- Igual que en 0021; cambia solo el insert de espacio_persona que se juntó con otro (`merged`, 0050).
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

    -- 0050: el insert no insertó nada porque el vínculo se juntó con el que ya tenía la misma persona
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

-- Igual que en 0042; cambia solo que `merged` (0050) cuenta entre los aceptados del log.
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
      when 'accepted', 'merged' then v_ok := v_ok + 1;
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

-- vinculo_juntado la llama sync.aplicar_job_interno, que corre como quien llama (authenticated): le
-- hace falta el EXECUTE. Solo devuelve algo si el id lo subió quien llama. Los default privileges de la
-- imagen dan EXECUTE a anon y authenticated sobre cada función nueva de public (ver 0008): se revoca
-- todo y se da lo que corresponde. redirigir_vinculo conserva sus privilegios de 0035 (create or replace).
revoke all on function public.vinculo_juntado(uuid) from public, anon, authenticated;
grant execute on function public.vinculo_juntado(uuid) to authenticated, service_role;
