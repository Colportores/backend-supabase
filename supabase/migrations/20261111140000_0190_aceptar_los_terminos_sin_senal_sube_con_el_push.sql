-- ============================================================================
-- 0190 · Aceptar los Términos sin señal: la aceptación sube con el push como trabajo del motor
--        (backend-supabase#267, BACK-HU-AUTH-011; decisión de Cristian del 11/11, «TyC s/red»:
--        https://github.com/Colportores/docs-organizacion/pull/185#issuecomment-6794635485)
--
-- ## El caso
--
-- Salió la v2 de los Términos y la Política de Privacidad, y el teléfono de Ana se enteró en la última sincronización
-- (la clave `terminos_version_vigente` de `parametro_global`, 0182). Al otro día, en el campo y sin señal, le aparece la
-- pantalla para aceptarla. Hasta hoy aceptar era `aceptar_terminos()` (0182), una llamada directa que pide conexión.
-- Cristian decidió que se acepta sin señal y sube después, como la unión de duplicados («Duplicado»): la aceptación
-- queda guardada en el teléfono y sube con la sincronización como un trabajo más del motor.
--
-- ## Qué hace
--
--   1. **`sync_push` recibe el trabajo «aceptar los Términos»**, con el mismo sobre de siempre:
--        {"client_op_id": "<uuid>", "entity": "consentimiento_terminos", "op": "aceptar_terminos",
--         "payload": {"version": "v2"}}
--      y lo aplica como `aceptar_terminos(version)` (0182): las mismas reglas, los mismos permisos y los mismos errores.
--      · La versión va siempre explícita: es la que Ana leyó y aceptó en el teléfono. Sin `version` (o si no es un
--        texto) vuelve `invalid PAYLOAD_VACIO`: aceptar «la vigente» del servidor al subir podría registrar una versión
--        que ella nunca leyó (si salió otra mientras estaba sin señal).
--      · Aplicada -> `accepted`; la cuenta ya había aceptado esa versión (otro teléfono, la RPC, el registro) ->
--        `duplicate`. Los dos traen `ya_estaba`, `version`, `aceptado_en`, `aceptado_en_telefono` y el `sync_version` de la fila de
--        `consentimiento_terminos`, y entran al cache: el reintento del mismo client_op_id es `duplicate`.
--      · Una versión que no es una de las publicadas -> `invalid TC001`; una cuenta dada de baja -> `invalid 42501`.
--        Ninguno tumba el lote. La cuenta suspendida no llega hasta acá: `sync_push` entero responde CS004 (0143) y
--        el trabajo queda pendiente en el teléfono hasta que la reactiven, como todo lo demás.
--      · `aceptado_en` es la hora del servidor al aplicar el trabajo (la misma regla de `aceptar_terminos()` y de la
--        columna: el cliente no la manda).
--   2. **La hora del teléfono, aparte** (decisión del agente de decisiones del 11/11, P2 de #267, por R1 y R2:
--      https://github.com/Colportores/backend-supabase/issues/267#issuecomment-6803044544): el payload puede traer
--      `aceptado_en_telefono` (ISO 8601), la hora en que Ana tocó «Aceptar» sin señal. Se guarda en la columna nueva y
--      opcional `consentimiento_terminos.aceptado_en_telefono`, sin tocar `aceptado_en`. Con el mismo criterio que las
--      otras horas del teléfono (0131, 0172: no más de 5 min en el futuro), y además no antes de que esa versión pasara a
--      vigente: una hora futura, anterior a la versión o que no es una fecha queda en null y la aceptación se registra
--      igual. Solo la primera aceptación de esa versión la guarda: si ya estaba, no se pisa nada.
--   3. `sync.aplicar_job` suma TC001 a los códigos propios que vuelven `invalid` sin tumbar el lote.
--
-- ## Los datos
--
-- Una columna nueva y opcional (`aceptado_en_telefono`, null en las filas que existen: no se inventa) que baja con el
-- pull como las demás.
--
-- ## Lo que NO cambia
--
--   · `consentimiento_terminos` sigue siendo de solo bajada para el resto: un `insert`, `update` o `delete` por el push
--     sigue volviendo `ENTIDAD_DE_SOLO_LECTURA`. La única escritura es este trabajo, que pasa por `aceptar_terminos()`.
--   · `aceptar_terminos()` sigue como RPC (el panel la usa con conexión, HU-AUTH-012).
--   · Ninguna fila existente se toca. Las dos funciones del motor se reemplazan con el cuerpo vigente (0148 y 0172) más
--     lo de arriba.
--
-- ## Para otros repos
--
--   · front-colportores-mobile#671: encola el trabajo al aceptar sin señal; con `accepted` o `duplicate` la aceptación
--     queda hecha; con `invalid` muestra el aviso.
--   · docs-organizacion#188: el contrato suma la operación, sus respuestas y TC001 en la tabla de rechazos por trabajo.
--
-- Forward-only: esta migración no se edita una vez aplicada. Lo prueba supabase/tests/0190_… .
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 0. La hora del teléfono
-- ----------------------------------------------------------------------------

alter table public.consentimiento_terminos add column aceptado_en_telefono timestamptz;

comment on column public.consentimiento_terminos.aceptado_en_telefono is
  'Cuándo se aceptó en el teléfono, si se aceptó sin señal y subió después por el push (0190, HU-AUTH-011). La manda el '
  'teléfono; el servidor la guarda solo si no está más de 5 min en el futuro ni es anterior a que esa versión pasara a '
  'vigente (si no, null). Null en el registro, en aceptar_terminos() con conexión y en las filas de antes de la 0190. '
  'aceptado_en sigue siendo la hora del servidor.';

-- Guarda la hora del teléfono en la aceptación propia de esa versión, si todavía no tiene una y si es creíble. La llama
-- la rama aceptar_terminos de sync.aplicar_job_interno justo después de una aceptación nueva. DEFINER porque nadie con
-- JWT escribe consentimiento_terminos (0065); solo toca la fila de quien llama (auth.uid()).
create function sync.hora_de_aceptacion_del_telefono(p_version text, p_hora text)
returns timestamptz
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_yo      uuid := auth.uid();
  v_hora    timestamptz;
  v_numero  bigint;
  v_vigente timestamptz;
begin
  if v_yo is null or p_hora is null or p_version is null or p_version !~ '^v[1-9][0-9]{0,8}$' then
    return null;
  end if;

  -- Una hora que no es una fecha no frena la aceptación: queda sin hora del teléfono.
  begin
    v_hora := p_hora::timestamptz;
  exception when others then
    return null;
  end;

  -- Como las otras horas del teléfono (0131, 0172): no más de 5 min en el futuro.
  if v_hora is null or v_hora > now() + interval '5 minutes' then
    return null;
  end if;

  -- Ni antes de que esa versión pasara a vigente: la primera alta o cambio de terminos_version_vigente a ese número
  -- (audit_log, 0110); la v1 se sembró sin evento (0182): desde que existe la clave.
  v_numero := substr(p_version, 2)::bigint;
  select min(a.created_at) into v_vigente
    from auditoria.audit_log a
   where a.event_type in ('parametro_global_alta', 'parametro_global_cambio')
     and a.tabla = 'parametro_global'
     and a.metadata ->> 'clave' = 'terminos_version_vigente'
     and a.metadata ->> 'valor_nuevo' = v_numero::text;
  if v_vigente is null then
    select p.created_at into v_vigente
      from public.parametro_global p
     where p.clave = 'terminos_version_vigente';
  end if;
  if v_vigente is not null and v_hora < v_vigente then
    return null;
  end if;

  update public.consentimiento_terminos c
     set aceptado_en_telefono = v_hora
   where c.usuario_id = v_yo and c.version = p_version and c.aceptado_en_telefono is null;
  if not found then
    return null;
  end if;
  return v_hora;
end;
$$;

comment on function sync.hora_de_aceptacion_del_telefono(text, text) is
  'Guarda en la aceptación propia (auth.uid()) de esa versión la hora del teléfono que trae el trabajo aceptar_terminos '
  'del push, si no tiene una, no está más de 5 min en el futuro ni es anterior a que la versión pasara a vigente; si no, '
  'no guarda nada y devuelve null (0190, HU-AUTH-011). La llama sync.aplicar_job_interno.';

revoke all on function sync.hora_de_aceptacion_del_telefono(text, text) from public, anon, authenticated, service_role;
grant execute on function sync.hora_de_aceptacion_del_telefono(text, text) to authenticated, service_role;

-- ----------------------------------------------------------------------------
-- 1. El trabajo «aceptar los Términos» en sync.aplicar_job_interno
-- ----------------------------------------------------------------------------
-- El cuerpo es el de 0148 más la rama de aceptar_terminos, después de los chequeos de la entidad y antes del de
-- «solo lectura» (consentimiento_terminos no permite push de filas).

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
  v_tc_version   text;
  v_tc_aceptado  timestamptz;
  v_tc_ya        boolean;
  v_tc_telefono  timestamptz;
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

  -- 0190: «aceptar los Términos» (BACK-HU-AUTH-011, backend-supabase#267; decisión de Cristian del 11/11, «TyC
  -- s/red»: se acepta sin señal y sube después, como «Duplicado»). No es un upsert: no trae PK ni sync_version y lo
  -- aplica aceptar_terminos(version) (0182), con sus permisos y sus errores. Va antes del chequeo de «solo lectura»:
  -- consentimiento_terminos no acepta filas por el push, solo este trabajo.
  --   · la versión va explícita (la que se leyó y se aceptó en el teléfono); sin ella, PAYLOAD_VACIO.
  --   · aplicada -> `accepted`; ya estaba aceptada -> `duplicate`. Los dos con ya_estaba, version, aceptado_en,
  --     aceptado_en_telefono y el sync_version de la fila, y entran al cache. La hora del teléfono, en la sección 0.
  --   · TC001 (versión no publicada) y 42501 (cuenta dada de baja) salen `invalid` (sync.aplicar_job, abajo).
  if v_op = 'aceptar_terminos' then
    if v_entidad <> 'consentimiento_terminos' then
      return sync.rechazo(p_op_id, 'OP_INVALIDA',
                          format('op %L solo va con la entidad consentimiento_terminos', v_op));
    end if;

    if jsonb_typeof(v_payload -> 'version') is distinct from 'string' then
      return sync.rechazo(p_op_id, 'PAYLOAD_VACIO',
                          'el payload no trae version: la versión de los Términos que se leyó y se aceptó (v1, v2…)');
    end if;

    select a.version, a.aceptado_en, a.ya_estaba
      into v_tc_version, v_tc_aceptado, v_tc_ya
      from public.aceptar_terminos(v_payload ->> 'version') a;

    -- La hora del teléfono, solo en la aceptación nueva y solo si es creíble (si no, null; la aceptación vale igual).
    if not v_tc_ya and jsonb_typeof(v_payload -> 'aceptado_en_telefono') = 'string' then
      perform sync.hora_de_aceptacion_del_telefono(v_tc_version, v_payload ->> 'aceptado_en_telefono');
    end if;

    select c.sync_version, c.aceptado_en_telefono into v_nueva, v_tc_telefono
      from public.consentimiento_terminos c
     where c.usuario_id = auth.uid() and c.version = v_tc_version;

    return sync.registrar(p_op_id, v_entidad, case when v_tc_ya then 'duplicate' else 'accepted' end, v_nueva)
           || jsonb_build_object('ya_estaba', v_tc_ya, 'version', v_tc_version, 'aceptado_en', v_tc_aceptado,
                                 'aceptado_en_telefono', v_tc_telefono);
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

  -- 0148 («Cancelar tr.», decisión de Cristian del 28/10): lo mismo para la transferencia de stock que pidió la
  -- colportora: cancelarla no compara versión (el servidor le fija el número y el teléfono puede tener una vieja).
  -- 0138 («Cancelar ped», decisión de Cristian del 27/10): cancelar un pedido propio que está por autorizar NO
  -- compara versión. Cancelar es "no lo quiero" y no depende de qué versión del pedido tenía el teléfono (las
  -- líneas, el monto y el aviso del límite se recalculan en el servidor y el teléfono puede tener una vieja). Se
  -- aplica sobre la versión que hay. Si el pedido ya no está por autorizar, el trigger de pedido_casa_editora
  -- (0124) lo frena con su aviso (42501: el coordinador ya lo autorizó, pedile que lo cancele) y el push vuelve
  -- `invalid` con el texto; si ya estaba cancelado, no cambia nada. Una cancelación nunca vuelve atrás a
  -- «por autorizar»: ese cambio no es una cancelación y sigue comparando versión (y el trigger lo frena).
  if v_op = 'update' and v_entidad in ('pedido_casa_editora', 'transferencia_stock') and v_payload ->> 'estado' = 'CANCELADO' then
    v_version := (v_actual ->> 'sync_version')::bigint;
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
  'marcar_como_duplicado(B, A) y responde accepted, o duplicate con ya_unida (0101, HU-UBI-006); y op '
  '''aceptar_terminos'' con entity ''consentimiento_terminos'' y payload {version}: llama a aceptar_terminos(version) y '
  'responde accepted, o duplicate si ya estaba aceptada, con ya_estaba, version, aceptado_en y aceptado_en_telefono; '
  'guarda la hora del teléfono del payload (aceptado_en_telefono) si es creíble (0190, HU-AUTH-011). El '
  'update o delete de un espacio_persona que se juntó con otro al llegar se aplica al que quedó, con '
  'conflicto si cambió desde la unión (0123). El update de un pedido_casa_editora o de una transferencia_stock a '
  'CANCELADO no compara versión (0138, 0148).';

-- ----------------------------------------------------------------------------
-- 2. TC001 vuelve invalid sin tumbar el lote
-- ----------------------------------------------------------------------------

-- Igual que en 0172, más TC001 (0190). Sus privilegios siguen (create or replace los conserva).
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
  -- CB003, CB005 y CB006, 0072), el cobro que ya no se puede cambiar, la hora de anulación inválida y la anulación fuera de la
  -- gracia (CB007 a CB009, 0131), anular una devolución pasadas las 24 h, con una hora inválida o fuera de la gracia
  -- (DV001 a DV004, 0172), aceptar los Términos con una versión que no es una publicada (TC001, 0190) y la unión de duplicados con A de baja o con B = A (UB003 y UB004, 0101): códigos propios, que la
  -- app traduce a un aviso. INVALID como el resto, sin tumbar el lote.
  when sqlstate 'UB001' or sqlstate 'UB002' or sqlstate 'UB003' or sqlstate 'UB004' or sqlstate 'CG001' or sqlstate 'UB005'
    or sqlstate 'AG001' or sqlstate 'AG002' or sqlstate 'AG003'
    or sqlstate 'CB001' or sqlstate 'CB002' or sqlstate 'CB003' or sqlstate 'CB005' or sqlstate 'CB006'
    or sqlstate 'CB007' or sqlstate 'CB008' or sqlstate 'CB009'
    or sqlstate 'DV001' or sqlstate 'DV002' or sqlstate 'DV003' or sqlstate 'DV004'
    or sqlstate 'TC001' then
    return jsonb_build_object(
      'client_op_id', v_id,
      'outcome', 'invalid',
      'code', sqlstate,
      'message', sqlerrm
    );
end;
$$;

-- ----------------------------------------------------------------------------
-- 3. La tabla lo dice
-- ----------------------------------------------------------------------------

comment on table public.consentimiento_terminos is
  'Qué versión de los Términos y la Política de Privacidad aceptó cada persona y cuándo (0065; HU-AUTH-001, R-AU04). Una fila '
  'por (usuario, versión): un historial, no un dato que se pisa. La escribe el trigger del registro (tg_auth_usuario_nuevo), '
  'aceptar_terminos() (cualquier rol, 0182; también como trabajo del push, op aceptar_terminos, para aceptar sin señal, '
  '0190) o el servidor; cada persona lee solo lo suyo. Desde la 0182 baja al teléfono por el sync (cada persona la suya) '
  'para saber sin conexión si ya aceptó la versión vigente; filas por el push no entran (solo ese trabajo).';
