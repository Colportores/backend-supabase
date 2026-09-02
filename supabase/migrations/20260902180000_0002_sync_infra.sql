-- ============================================================================
-- 0002 · Infraestructura de sincronización (Sprint 3 · issue #9)
--
-- Lo que ADR-017 §4 pone de este lado: RPC de ingesta batch, cache de
-- client_op_id (TTL 24 h) y delta pull. Adaptado desde el árbol del prototipo
-- del PR #5 al esquema real del 0001.
--
-- Tres decisiones que separan esto de aquel árbol:
--
--   1. LA RLS ES LA AUTORIDAD DE PERMISOS, TAMBIÉN EN EL PUSH (ADR-016, #6).
--      Los RPC son SECURITY INVOKER y no reciben el usuario por parámetro: lo
--      sacan de auth.uid(). El BFF reenvía el JWT y no decide nada.
--
--      Consecuencia: no hay filtro manual por columna de dueño. Un `select`
--      dentro de estas funciones ya devuelve solo lo que el usuario puede ver,
--      y un `insert` que no cumpla el WITH CHECK falla como falla cualquier
--      escritura. Eso resuelve de una tres casos que un filtro por columna no
--      cubría: venta_item/entrega/cobranza (sin columna de dueño, heredan el
--      permiso vía venta), las tablas compartidas por zona (mis_zonas(), que no
--      es una igualdad) y los catálogos globales.
--
--   2. EL CURSOR DEL DELTA ES EL XID, NO EL RELOJ. `updated_at` se llena con
--      now(), que es la hora de INICIO de transacción: dos escritores
--      concurrentes commitean en orden distinto al de sus timestamps y la fila
--      que commiteó tarde queda detrás de un watermark que ya avanzó — subida,
--      guardada y jamás entregada. Se ordena por (xmin_w, id) y se sirve solo lo
--      que está por debajo de pg_snapshot_xmin(pg_current_snapshot()).
--      El diagnóstico y el arreglo son de @BrunoFCapri (PR #5, 0010).
--
--   3. xmin_w LO PONE EL TRIGGER DE AUDITORÍA, NO EL RPC. Si dependiera del RPC,
--      cualquier escritura que no pase por sync.push() —seeds, panel del
--      coordinador, un job -- dejaría la fila con el xid de su INSERT: modificada
--      en la base y nunca propagada. Es el mismo bug del punto 2 entrando por la
--      otra puerta. Se agrega a tg_auditoria_insert/update del 0001, que ya
--      corren en las 24 tablas.
--
-- Forward-only: esta migración no se edita una vez aplicada.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. xmin_w: el cursor del delta, en todas las tablas
-- ----------------------------------------------------------------------------

-- En las 24, no solo en las sincronizables: las funciones de auditoría del 0001
-- son compartidas y una asignación condicional por tabla sería una rama que hay
-- que mantener sincronizada con el registro. La columna son 8 bytes.
do $$
declare
  t text;
begin
  foreach t in array array[
    'pais','ciudad','usuario','rol','usuario_rol','horario_colportor','campania','zona',
    'campania_colportor','producto','coleccion','producto_coleccion','precio_por_zona',
    'ubicacion','espacio','espacio_persona','jornada','visita','agenda','venta','venta_item',
    'entrega','cobranza','house_status'
  ] loop
    execute format(
      'alter table public.%I add column xmin_w xid8 not null default pg_current_xact_id()', t);
  end loop;
end
$$;

comment on column public.venta.xmin_w is
  'Cursor del delta: id de la transacción que escribió la fila por última vez. Lo pone el '
  'trigger de auditoría. No viaja por el cable — es maquinaria, no un dato del negocio.';

-- ----------------------------------------------------------------------------
-- 2. Los triggers de auditoría del 0001, ahora también estampan el cursor
-- ----------------------------------------------------------------------------

-- Se reemplazan las funciones, no los triggers: siguen siendo los mismos 48
-- triggers que cableó el 0001 §8.

create or replace function public.tg_auditoria_insert()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.sync_version := 0;
  new.updated_at := now();
  new.xmin_w := pg_current_xact_id();
  return new;
end;
$$;

comment on function public.tg_auditoria_insert() is
  'BEFORE INSERT: sync_version = 0, updated_at = now() y xmin_w = xid actual, los fije o no '
  'el cliente (contrato §5.4).';

create or replace function public.tg_auditoria_update()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.updated_at := now();
  new.sync_version := old.sync_version + 1;
  new.created_at := old.created_at;
  new.created_by := old.created_by;
  -- Sin esto, una fila actualizada conserva el xid de su INSERT, queda detrás del
  -- watermark de cualquier cliente que ya la bajó, y la modificación no se
  -- propaga nunca.
  new.xmin_w := pg_current_xact_id();
  return new;
end;
$$;

comment on function public.tg_auditoria_update() is
  'BEFORE UPDATE: updated_at = now(), sync_version = old + 1, xmin_w = xid actual; '
  'created_at/created_by inmutables.';

-- ----------------------------------------------------------------------------
-- 3. El schema sync y el registro de entidades
-- ----------------------------------------------------------------------------

create schema sync;

comment on schema sync is
  'Maquinaria de sincronización (ADR-017 §4). No se expone en la Data API: config.toml '
  'lista solo public y graphql_public. Se llega por los RPC, con el JWT del usuario.';

-- El registro es una tabla y no una lista en el código a propósito: el RPC es
-- genérico, y sin lista blanca explícita un cliente podría mandar
-- `entity: "usuario"` y escribir donde no debe. Es el espejo en SQL del SyncSpec
-- del motor (contrato §2): si una entidad no está acá, no entra.
create table sync.entidad (
  nombre            text primary key,
  tabla             regclass not null unique,

  -- house_status tiene ubicacion_id como PK, no id (0001 §7). El RPC es
  -- genérico; la excepción vive en el registro y no en un `if` adentro.
  columna_pk        text not null default 'id',

  -- Réplica de solo lectura (contrato §2, política `pull`). Que la app no las
  -- escriba es una convención; que el servidor las rechace es una garantía.
  permite_push      boolean not null default true,

  -- Columnas que fija el servidor y que el cliente NO puede sobrescribir
  -- (contrato §5.4). Se descartan del payload en silencio: un cliente viejo que
  -- las mande no tiene por qué fallar, pero tampoco ganar.
  --
  -- created_at NO está: el 0001 regla 3 dice que el cliente sí lo provee en el
  -- INSERT (la fila nace offline y sube después) y el trigger lo preserva en el
  -- UPDATE, que es donde había que protegerlo.
  columnas_servidor text[] not null default array['sync_version','updated_at','created_by','xmin_w']
);

comment on table sync.entidad is
  'Qué entidades se pueden sincronizar. Espejo en SQL del SyncSpec del motor (contrato §2).';

-- No hay columna `por_usuario`: con SECURITY INVOKER la RLS decide qué filas ve
-- cada usuario, así que el delta no necesita saber por qué columna filtrar.

-- ----------------------------------------------------------------------------
-- 4. Cache de client_op_id (contrato §5.3)
-- ----------------------------------------------------------------------------

-- Idempotencia del INTENTO. Reintentar un push tras un timeout tiene que
-- devolver `duplicate`, no aplicar dos veces.
--
-- El TTL de 24 h alcanza para los reintentos de un ciclo; lo que sobrevive más
-- que eso —el replay del contrato §7 desde un backup viejo— se apoya en la PK
-- UUID v7 del dispositivo, no en este cache.
create table sync.op_cache (
  client_op_id  uuid primary key,
  usuario_id    uuid not null default auth.uid() references public.usuario(id) on delete cascade,
  device_id     uuid,
  entidad       text not null,

  -- Solo entra lo que se APLICÓ. Un rechazo no entra, y un conflicto tampoco:
  -- ninguno de los dos tocó la base, así que no hay nada que deduplicar. Si el
  -- motor resuelve el LWW y reintenta con el mismo client_op_id, tiene que
  -- volver a validarse contra el estado nuevo — no recibir un `duplicate` por
  -- una respuesta vieja y dar por escrita una corrección que nunca ocurrió.
  outcome       text not null check (outcome in ('accepted','duplicate')),
  sync_version  bigint,
  aplicado_en   timestamptz not null default now()
);

comment on table sync.op_cache is
  'Idempotencia por intento (contrato §5.3). Solo ops aplicados. Purga a las 24 h.';
comment on column sync.op_cache.device_id is
  'Qué instalación aplicó este op primero. No se pisa en un reintento: interesa quién lo aplicó.';

create index op_cache_purga_idx on sync.op_cache (aplicado_en);
create index op_cache_usuario_idx on sync.op_cache (usuario_id);

-- ----------------------------------------------------------------------------
-- 5. Telemetría (RF-SY06) — un registro por ciclo
-- ----------------------------------------------------------------------------

-- Solo UUIDs, contadores y bytes. Nada de PII, ni siquiera para debug
-- (convenciones-desarrollo.md §7).
create table sync.log (
  id            bigint generated always as identity primary key,
  usuario_id    uuid not null default auth.uid() references public.usuario(id) on delete cascade,
  device_id     uuid,
  operacion     text not null check (operacion in ('push','pull')),

  -- clock_timestamp() y no now(): interesa el momento real del ciclo, no el
  -- inicio de la transacción. Es la misma distinción que causa el bug del delta,
  -- mirada desde el otro lado.
  momento       timestamptz not null default clock_timestamp(),
  duracion_ms   numeric(10,2) not null,

  jobs          integer,
  aceptados     integer,
  duplicados    integer,
  conflictos    integer,
  invalidos     integer,

  entidades     text[],
  filas         integer,
  hay_mas       boolean,

  -- Los dos lados del ciclo. RR-07 (consumo de datos del piloto) se mide acá.
  bytes_entrada integer not null default 0,
  bytes_salida  integer not null default 0
);

create index log_usuario_idx on sync.log (usuario_id, momento desc);
create index log_purga_idx on sync.log (momento);

-- ----------------------------------------------------------------------------
-- 6. RLS sobre las tablas del schema sync
-- ----------------------------------------------------------------------------

-- Regla 6 del 0001: RLS en todas las tablas. Con SECURITY INVOKER esto no es
-- decorativo — las funciones tocan estas tablas con los privilegios del usuario,
-- así que es lo único que impide leer el cache o la telemetría de otro.

alter table sync.entidad  enable row level security;
alter table sync.op_cache enable row level security;
alter table sync.log      enable row level security;

-- El registro es metadata pública para cualquier autenticado: el motor necesita
-- saber qué puede sincronizar. Lo escribe una migración, no un usuario.
create policy entidad_select_autenticado on sync.entidad
  for select to authenticated using (true);

create policy op_cache_propio on sync.op_cache
  for select to authenticated using (usuario_id = (select auth.uid()));
create policy op_cache_insert_propio on sync.op_cache
  for insert to authenticated with check (usuario_id = (select auth.uid()));
-- El device_id se estampa al final del push sobre las filas del propio usuario.
create policy op_cache_update_propio on sync.op_cache
  for update to authenticated
  using (usuario_id = (select auth.uid())) with check (usuario_id = (select auth.uid()));

create policy log_propio on sync.log
  for select to authenticated using (usuario_id = (select auth.uid()));
create policy log_insert_propio on sync.log
  for insert to authenticated with check (usuario_id = (select auth.uid()));

-- ----------------------------------------------------------------------------
-- 7. Helpers
-- ----------------------------------------------------------------------------

-- Las columnas que el cliente sí puede escribir.
create function sync.columnas_escribibles(p_entidad text)
returns text[]
language sql
stable
set search_path = ''
as $$
  select coalesce(array_agg(c.attname::text), array[]::text[])
  from sync.entidad e
  join pg_catalog.pg_attribute c on c.attrelid = e.tabla
  where e.nombre = p_entidad
    and c.attnum > 0
    and not c.attisdropped
    and not (c.attname::text = any (e.columnas_servidor));
$$;

-- Arma la expresión que serializa una fila a jsonb.
--
-- Los decimales viajan como string, nunca como número JSON: to_jsonb() convierte
-- un numeric(10,2) en número, `42.50` sale como `42.5`, y del otro lado
-- jsonDecode lo parsea como double. Para km da igual; para el total de una venta
-- es lo que el formato de cable prohíbe, y el error no se ve hasta que alguien
-- suma mal un estado de cuenta. La conversión se hace acá y no en el BFF porque
-- acá se sabe el tipo de cada columna: una vez que la fila es jsonb, se perdió.
--
-- xmin_w queda afuera: es maquinaria del cursor, no un dato del negocio.
create function sync.expresion_json(p_tabla regclass)
returns text
language sql
stable
set search_path = ''
as $$
  select 'jsonb_build_object(' || string_agg(
           format('%L, %s', c.attname,
             case when c.atttypid = 'pg_catalog.numeric'::regtype
                  then format('(t.%I)::text', c.attname)
                  else format('t.%I', c.attname) end),
           ', ' order by c.attnum)
         || ')'
  from pg_catalog.pg_attribute c
  where c.attrelid = p_tabla
    and c.attnum > 0
    and not c.attisdropped
    and c.attname::text <> 'xmin_w';
$$;

comment on function sync.expresion_json(regclass) is
  'Serializa una fila a jsonb con los numeric como texto. Se usa con execute format(); los '
  'nombres salen del catálogo y pasan por %I, así que no hay inyección posible.';

-- Un rechazo NO entra al cache: el job nunca tocó la base.
create function sync.rechazo(p_op_id uuid, p_codigo text, p_mensaje text)
returns jsonb
language sql
immutable
set search_path = ''
as $$
  select jsonb_build_object('client_op_id', p_op_id, 'outcome', 'invalid',
                            'code', p_codigo, 'message', p_mensaje);
$$;

create function sync.registrar(p_op_id uuid, p_entidad text, p_outcome text, p_version bigint)
returns jsonb
language plpgsql
set search_path = ''
as $$
begin
  insert into sync.op_cache (client_op_id, entidad, outcome, sync_version)
  values (p_op_id, p_entidad, p_outcome, p_version)
  on conflict (client_op_id) do nothing;

  return jsonb_build_object('client_op_id', p_op_id, 'outcome', p_outcome,
                            'sync_version', p_version);
end;
$$;

-- ----------------------------------------------------------------------------
-- 8. Aplicar un job
-- ----------------------------------------------------------------------------

-- El bloque `exception` de acá no es cosmético: en PL/pgSQL abre una
-- subtransacción, y es lo que hace que un job con el payload roto no se lleve
-- puesto el lote entero.
create function sync.aplicar_job(p_job jsonb)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_id uuid;
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
  -- Clase 22 (data_exception) y 23 (integrity_constraint_violation): el payload
  -- está mal. Una fecha que no es fecha, un texto donde va un número, una FK que
  -- no existe. 42501 (insufficient_privilege): la RLS rechazó la fila — el
  -- cliente mandó algo que no le corresponde escribir.
  --
  -- Los tres son INVALID: visibles, corregibles con requeue(), sin reintento
  -- automático (contrato §5.1, ADR-013). Y ninguno puede tumbar a los demás jobs
  -- del lote: sin esto un solo job venenoso hace fallar el push entero, el motor
  -- lo clasifica como 5xx transitorio y lo reintenta para siempre — la cola del
  -- colportor queda bloqueada y ninguna venta vuelve a subir.
  --
  -- Lo que NO se atrapa —deadlock, conexión caída, falta de memoria— sube y sale
  -- como 500. Ahí reintentar sí es lo correcto.
  when data_exception or integrity_constraint_violation or insufficient_privilege then
    return jsonb_build_object(
      'client_op_id', v_id,
      'outcome', 'invalid',
      'code', sqlstate,
      'message', sqlerrm
    );
end;
$$;

create function sync.aplicar_job_interno(p_op_id uuid, p_job jsonb)
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

-- ----------------------------------------------------------------------------
-- 9. sync.push — el RPC de ingesta
-- ----------------------------------------------------------------------------

-- Un solo round trip para todo el lote, y aceptación por job: un registro
-- inválido no tumba a los demás. La alternativa —una query por job— multiplica
-- la latencia por el tamaño del lote, que es justo lo que RR-02 no perdona.
--
-- No recibe el usuario: sale de auth.uid(). Que el llamador no pueda declarar
-- quién es, es la diferencia entre confiar en el BFF y no tener que hacerlo.
create function sync.push(p_jobs jsonb, p_device uuid default null)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_job      jsonb;
  v_res      jsonb;
  v_results  jsonb := '[]'::jsonb;
  v_arranque timestamptz := clock_timestamp();
  v_ok       integer := 0;
  v_dup      integer := 0;
  v_conf     integer := 0;
  v_inv      integer := 0;
  v_ops      uuid[] := '{}'::uuid[];
  v_salida   jsonb;
begin
  if auth.uid() is null then
    raise exception 'sync.push requiere un usuario autenticado'
      using errcode = 'insufficient_privilege';
  end if;

  if jsonb_typeof(p_jobs) is distinct from 'array' then
    raise exception 'p_jobs tiene que ser un array de jobs'
      using errcode = 'invalid_parameter_value';
  end if;

  -- En orden: los jobs de una misma entidad se aplican en orden de creación
  -- (contrato §5.5), y un item nunca antes que su venta.
  for v_job in select * from jsonb_array_elements(p_jobs) loop
    v_res := sync.aplicar_job(v_job);
    v_results := v_results || jsonb_build_array(v_res);

    case v_res ->> 'outcome'
      when 'accepted'  then v_ok   := v_ok   + 1;
      when 'duplicate' then v_dup  := v_dup  + 1;
      when 'conflict'  then v_conf := v_conf + 1;
      else                  v_inv  := v_inv  + 1;
    end case;

    -- El op_id sale del RESULTADO, no del job crudo: ahí ya pasó por
    -- aplicar_job() y es un uuid o es null. Castear acá afuera, donde no hay
    -- bloque exception que lo contenga, convertiría un client_op_id malformado
    -- en un 500 que tumba el lote entero.
    if v_res ->> 'client_op_id' is not null then
      v_ops := v_ops || ((v_res ->> 'client_op_id')::uuid);
    end if;
  end loop;

  -- device_id is null protege el reintento: si el op ya estaba en el cache
  -- porque lo aplicó OTRO dispositivo, la fila conserva al primero. Es la
  -- pregunta que importa —quién lo aplicó— y no quién lo repitió.
  if p_device is not null and array_length(v_ops, 1) is not null then
    update sync.op_cache set device_id = p_device
     where client_op_id = any (v_ops) and device_id is null;
  end if;

  v_salida := jsonb_build_object(
    'server_time', to_char(now() at time zone 'utc', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"'),
    'results', v_results
  );

  -- El log va al final y en la misma transacción que el lote: si el push se cae,
  -- no queda una línea de telemetría diciendo que entró algo que no entró.
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
-- 10. sync.pull — el delta
-- ----------------------------------------------------------------------------

-- El watermark es (xmin_w, id) POR ENTIDAD, no un reloj global: así una
-- colección no arrastra a la otra. Es opaco para el cliente.
--
-- No hay filtro por usuario: con SECURITY INVOKER el SELECT ya devuelve lo que
-- la RLS deja ver, que además es la definición correcta para las tablas
-- compartidas por zona y para los catálogos globales.
create function sync.pull(
  p_entidades text[],
  p_watermark jsonb default '{}'::jsonb,
  p_limite    integer default 500,
  p_device    uuid default null
)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_entidad   text;
  v_tabla     regclass;
  v_desde     jsonb;
  v_lote      jsonb;
  v_filas     jsonb;
  v_rows      jsonb := '{}'::jsonb;
  v_nuevo     jsonb := coalesce(p_watermark, '{}'::jsonb);
  v_hay_mas   boolean := false;
  v_ultima    jsonb;
  v_horizonte xid8;
  v_limite    integer;
  v_arranque  timestamptz := clock_timestamp();
  v_total     integer := 0;
  v_salida    jsonb;
begin
  if auth.uid() is null then
    raise exception 'sync.pull requiere un usuario autenticado'
      using errcode = 'insufficient_privilege';
  end if;

  -- Un límite fuera de rango es un cliente roto o un abuso, no una razón para
  -- devolver 500 (un `limit` negativo es un error de Postgres) ni para armar una
  -- respuesta de un millón de filas. Se acota y se sigue.
  v_limite := least(greatest(coalesce(p_limite, 500), 1), 1000);

  -- Una sola vez para todas las entidades: así el corte es el mismo para todas y
  -- el watermark que se devuelve es consistente entre ellas.
  --
  -- Toda transacción que todavía pueda commitear tiene xid >= este horizonte por
  -- definición de xmin, así que cualquier fila futura entra con un xmin_w mayor
  -- que TODO lo que este pull entregó. La fila que commiteó tarde no se saltea:
  -- espera y sale en el pull siguiente.
  v_horizonte := pg_snapshot_xmin(pg_current_snapshot());

  foreach v_entidad in array coalesce(p_entidades, array[]::text[]) loop
    select e.tabla into v_tabla from sync.entidad e where e.nombre = v_entidad;
    -- Una entidad que el cliente pide y el servidor no conoce se ignora: un
    -- cliente más nuevo que el backend no puede tumbar la sync de los demás.
    continue when v_tabla is null;

    -- Un watermark sin `xid` —ausente, o del formato viejo con `ts`— arranca de
    -- cero. Resincronizar de más es barato; saltear una fila no.
    v_desde := coalesce(p_watermark -> v_entidad, '{}'::jsonb);

    -- Se pide una fila de más para saber si hay más sin contar la tabla entera.
    -- El xmin_w viaja al lado de la fila y no dentro de ella: no es un dato del
    -- negocio, pero es lo que arma el watermark, y traerlo acá evita un segundo
    -- SELECT por entidad.
    execute format($q$
      select coalesce(jsonb_agg(jsonb_build_object('j', j, 'xw', xw::text, 'id', id)
                                order by xw, id), '[]'::jsonb)
      from (
        select %s as j, t.xmin_w as xw, t.%I as id
        from %s t
        where t.xmin_w < $3
          and (t.xmin_w, t.%I) > ($1::xid8, $2::uuid)
        order by t.xmin_w, t.%I
        limit %s
      ) s
    $q$,
      sync.expresion_json(v_tabla),
      (select e.columna_pk from sync.entidad e where e.tabla = v_tabla),
      v_tabla,
      (select e.columna_pk from sync.entidad e where e.tabla = v_tabla),
      (select e.columna_pk from sync.entidad e where e.tabla = v_tabla),
      (v_limite + 1)::text)
    into v_lote
    using coalesce(v_desde ->> 'xid', '0'),
          coalesce(v_desde ->> 'id', '00000000-0000-0000-0000-000000000000')::uuid,
          v_horizonte;

    continue when jsonb_array_length(v_lote) = 0;

    if jsonb_array_length(v_lote) > v_limite then
      v_hay_mas := true;
      v_lote := (select jsonb_agg(e) from (
        select e from jsonb_array_elements(v_lote) e limit v_limite
      ) s);
    end if;

    v_filas := (select jsonb_agg(e -> 'j') from jsonb_array_elements(v_lote) e);

    -- Una entidad ausente de `rows` significa "sin cambios": el cliente no borra
    -- nada por ausencia, así que solo van las que traen algo.
    v_rows := v_rows || jsonb_build_object(v_entidad, v_filas);
    v_total := v_total + jsonb_array_length(v_filas);

    v_ultima := v_lote -> (jsonb_array_length(v_lote) - 1);
    v_nuevo := v_nuevo || jsonb_build_object(v_entidad, jsonb_build_object(
      'xid', v_ultima ->> 'xw',
      'id',  v_ultima ->> 'id'
    ));
  end loop;

  v_salida := jsonb_build_object(
    'server_time', to_char(now() at time zone 'utc', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"'),
    'watermark', v_nuevo,
    'has_more', v_hay_mas,
    'rows', v_rows
  );

  -- Un pull sin novedades no escribe nada, y eso es deliberado: es el latido más
  -- común de todos, y loguearlo lo convertiría en una escritura. Cuesta WAL y
  -- vacuum por cada latido de cada colportor, pero sobre todo CADA PULL TOMARÍA
  -- UN XID y con eso frenaría el horizonte del delta de todos los demás mientras
  -- dura. Con 200 usuarios sincronizando seguido, el horizonte casi no avanzaría.
  if v_total > 0 then
    insert into sync.log (device_id, operacion, duracion_ms, entidades, filas, hay_mas, bytes_salida)
    values (p_device, 'pull',
            extract(epoch from clock_timestamp() - v_arranque) * 1000,
            p_entidades, v_total, v_hay_mas, octet_length(v_salida::text));
  end if;

  return v_salida;
end;
$$;

-- ----------------------------------------------------------------------------
-- 11. sync.estado — lo que el servidor PUEDE contestar (RF-SY06)
-- ----------------------------------------------------------------------------

-- La cola de pendientes y la de error viven en el dispositivo
-- (engine.errorQueue()); el servidor no las conoce: un job que nunca llegó no
-- dejó rastro acá. Devolver un "pendientes: 0" sacado de esta tabla sería
-- mentirle al colportor sobre lo único que le importa.
create function sync.estado(p_ventana interval default interval '24 hours')
returns jsonb
language sql
stable
set search_path = ''
as $$
  with v as (
    select * from sync.log where momento > now() - p_ventana
  )
  select jsonb_build_object(
    'server_time', to_char(now() at time zone 'utc', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"'),
    'ultimo_push', (select max(momento) from sync.log where operacion = 'push'),
    'ultimo_pull', (select max(momento) from sync.log where operacion = 'pull'),
    'ventana', jsonb_build_object(
      'desde',      to_char((now() - p_ventana) at time zone 'utc', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
      'ciclos',     (select count(*) from v),
      'jobs',       (select coalesce(sum(jobs), 0) from v),
      'aceptados',  (select coalesce(sum(aceptados), 0) from v),
      'duplicados', (select coalesce(sum(duplicados), 0) from v),
      'conflictos', (select coalesce(sum(conflictos), 0) from v),
      'invalidos',  (select coalesce(sum(invalidos), 0) from v),
      'filas_bajadas', (select coalesce(sum(filas), 0) from v),
      -- RR-07: lo que el colportor paga de su plan de datos.
      'bytes_entrada', (select coalesce(sum(bytes_entrada), 0) from v),
      'bytes_salida',  (select coalesce(sum(bytes_salida), 0) from v),
      -- p95 y no promedio: RR-02 es un techo, y un techo no se verifica con una
      -- media que un montón de ciclos vacíos empuja hacia abajo.
      'p95_ms', (select round(percentile_cont(0.95)
                   within group (order by duracion_ms)::numeric, 2) from v)
    )
  );
$$;

-- La RLS de sync.log ya limita las filas al usuario autenticado; por eso no
-- recibe p_usuario y por eso es la misma función para todos.

-- ----------------------------------------------------------------------------
-- 12. Purga
-- ----------------------------------------------------------------------------

-- Medido con los números de RP-01 (150 colportores, ~140 registros por día), el
-- cache pasa de 5 MB en régimen a 945 MB en una temporada si no lo purga nadie.
-- Y no es solo disco: buscar el client_op_id es lo primero que hace cada job de
-- cada push, así que el índice degradado se paga en cada sincronización.
--
-- SECURITY DEFINER porque la corre pg_cron, no un usuario, y tiene que ver todas
-- las filas: la RLS de op_cache la dejaría borrar solo las suyas (ninguna).
create function sync.purgar_cache(p_ttl interval default interval '24 hours')
returns integer
language sql
security definer
set search_path = ''
as $$
  with borradas as (
    delete from sync.op_cache where aplicado_en < now() - p_ttl returning 1
  )
  select count(*)::integer from borradas;
$$;

-- 90 días: cubre una temporada de campaña entera, que es la ventana sobre la que
-- tiene sentido comparar un piloto.
create function sync.purgar_log(p_ttl interval default interval '90 days')
returns integer
language sql
security definer
set search_path = ''
as $$
  with borradas as (
    delete from sync.log where momento < now() - p_ttl returning 1
  )
  select count(*)::integer from borradas;
$$;

-- La purga se agenda en la misma migración que crea las tablas. Un TTL
-- documentado y no ejecutado es una tabla que crece hasta que el índice se
-- degrada, y se descubre midiendo, tarde.
do $$
begin
  -- Se pregunta si la extensión está disponible antes de crearla: un
  -- `create extension if not exists` igual falla si no está instalada en el
  -- sistema, y eso frenaría el despliegue en cualquier Postgres que no sea
  -- Supabase (la imagen de compose.dev.yml la trae; un Postgres pelado no).
  if not exists (select 1 from pg_available_extensions where name = 'pg_cron') then
    raise warning
      'pg_cron no está disponible: agendá `select sync.purgar_cache();` y '
      '`select sync.purgar_log();` a diario por fuera, o las tablas crecen sin límite.';
    return;
  end if;

  create extension if not exists pg_cron;

  -- Idempotente: reaplicar la migración no duplica el job.
  perform cron.unschedule('sync-purgar-op-cache')
   where exists (select 1 from cron.job where jobname = 'sync-purgar-op-cache');
  perform cron.unschedule('sync-purgar-log')
   where exists (select 1 from cron.job where jobname = 'sync-purgar-log');

  -- 4:17 UTC: de madrugada en Uruguay, lejos de la jornada.
  perform cron.schedule('sync-purgar-op-cache', '17 4 * * *',
                        $cmd$ select sync.purgar_cache(); $cmd$);
  perform cron.schedule('sync-purgar-log', '32 4 * * *',
                        $cmd$ select sync.purgar_log(); $cmd$);
end
$$;

-- ----------------------------------------------------------------------------
-- 13. El registro de entidades (contrato §2)
-- ----------------------------------------------------------------------------

insert into sync.entidad (nombre, tabla, columna_pk, permite_push) values
  -- pull (cloud → app): réplica de solo lectura. La app nunca las escribe.
  ('pais',               'public.pais'::regclass,               'id', false),
  ('ciudad',             'public.ciudad'::regclass,             'id', false),
  ('zona',               'public.zona'::regclass,               'id', false),
  ('campania',           'public.campania'::regclass,           'id', false),
  ('producto',           'public.producto'::regclass,           'id', false),
  ('coleccion',          'public.coleccion'::regclass,          'id', false),
  ('producto_coleccion', 'public.producto_coleccion'::regclass, 'id', false),
  ('precio_por_zona',    'public.precio_por_zona'::regclass,    'id', false),

  -- push (app → cloud)
  ('jornada',         'public.jornada'::regclass,         'id', true),
  ('visita',          'public.visita'::regclass,          'id', true),
  ('agenda',          'public.agenda'::regclass,          'id', true),
  ('venta',           'public.venta'::regclass,           'id', true),
  ('venta_item',      'public.venta_item'::regclass,      'id', true),
  ('entrega',         'public.entrega'::regclass,         'id', true),
  ('cobranza',        'public.cobranza'::regclass,        'id', true),

  -- push + alsoPull (bidireccional, LWW)
  ('ubicacion',       'public.ubicacion'::regclass,       'id', true),
  ('espacio',         'public.espacio'::regclass,         'id', true),
  -- El contrato §2 no la lista, pero visita.espacio_persona_id es NOT NULL con FK:
  -- sin subir el vínculo primero, ninguna visita puede pushearse. Solo IDs — la
  -- persona vive en el dispositivo (0001 §5).
  ('espacio_persona', 'public.espacio_persona'::regclass, 'id', true),
  -- PK es ubicacion_id, no id (0001 §7).
  ('house_status',    'public.house_status'::regclass,    'ubicacion_id', true);

-- persona y nota no están, y no van a estar: son `local` (contrato §2).
-- Ley 18.331 — ni las tablas ni columnas de texto libre sobre clientes.

-- colportor_id es la columna que decide QUÉ FILAS ve el usuario en las tablas de
-- operación. La RLS ya impide escribirla a nombre de otro (0001 §10.4), pero
-- descartarla del payload evita que un cliente la mande y crea que se aplicó.
update sync.entidad
   set columnas_servidor = columnas_servidor || array['colportor_id']
 where nombre in ('jornada','visita','agenda','venta');

-- ----------------------------------------------------------------------------
-- 14. Índices del delta
-- ----------------------------------------------------------------------------

-- El orden importa: la columna del predicado RLS va PRIMERO, para que
-- `colportor_id = auth.uid()` entre en el Index Cond y no quede como filtro
-- después del scan. Sin eso, servir 500 filas de un colportor entre 150 obliga a
-- recorrer ~75.000 (security-rls-performance.md).
create index jornada_delta_idx    on public.jornada    (colportor_id, xmin_w, id);
create index visita_delta_idx     on public.visita     (colportor_id, xmin_w, id);
create index agenda_delta_idx     on public.agenda     (colportor_id, xmin_w, id);
create index venta_delta_idx      on public.venta      (colportor_id, xmin_w, id);

-- Estas heredan el permiso vía venta (0001 §10.4): el predicado es un EXISTS y
-- no una igualdad indexable, así que el índice solo ordena el delta.
create index venta_item_delta_idx on public.venta_item (xmin_w, id);
create index entrega_delta_idx    on public.entrega    (xmin_w, id);
create index cobranza_delta_idx   on public.cobranza   (xmin_w, id);

-- espacio_persona filtra por created_by (0001 §10.3).
create index espacio_persona_delta_idx on public.espacio_persona (created_by, xmin_w, id);

-- Compartidas por zona: mis_zonas() es un IN sobre una función, no una igualdad.
create index ubicacion_delta_idx    on public.ubicacion    (xmin_w, id);
create index espacio_delta_idx      on public.espacio      (xmin_w, id);
create index house_status_delta_idx on public.house_status (xmin_w, ubicacion_id);

-- Catálogo y geografía: lectura para todo autenticado, sin predicado por fila.
create index pais_delta_idx               on public.pais               (xmin_w, id);
create index ciudad_delta_idx             on public.ciudad             (xmin_w, id);
create index zona_delta_idx               on public.zona               (xmin_w, id);
create index campania_delta_idx           on public.campania           (xmin_w, id);
create index producto_delta_idx           on public.producto           (xmin_w, id);
create index coleccion_delta_idx          on public.coleccion          (xmin_w, id);
create index producto_coleccion_delta_idx on public.producto_coleccion (xmin_w, id);
create index precio_por_zona_delta_idx    on public.precio_por_zona    (xmin_w, id);

-- ----------------------------------------------------------------------------
-- 15. Privilegios
-- ----------------------------------------------------------------------------

-- Mismo criterio que el 0001 §10: anon no ve nada, authenticated lo justo, y las
-- funciones se revocan de PUBLIC (Postgres otorga EXECUTE a PUBLIC en cada
-- CREATE FUNCTION, y anon lo hereda: revocarle a anon un grant directo que nunca
-- tuvo deja el privilegio heredado intacto).

alter default privileges in schema sync revoke all on tables from anon;
alter default privileges in schema sync revoke all on functions from public, anon;

revoke all on schema sync from public;
grant usage on schema sync to authenticated, service_role;

revoke all on all tables in schema sync from public, anon;
grant select on sync.entidad to authenticated;
grant select, insert, update on sync.op_cache to authenticated;
grant select, insert on sync.log to authenticated;
grant all on all tables in schema sync to service_role;

revoke all on all functions in schema sync from public, anon;

grant execute on function sync.push(jsonb, uuid) to authenticated, service_role;
grant execute on function sync.pull(text[], jsonb, integer, uuid) to authenticated, service_role;
grant execute on function sync.estado(interval) to authenticated, service_role;

-- Las internas también, porque push/pull son SECURITY INVOKER: la cadena corre
-- con los privilegios de quien llama, así que sin EXECUTE propio el push falla
-- con "permission denied for function aplicar_job".
--
-- Que sean invocables de forma directa no agrega superficie: al no ser
-- SECURITY DEFINER no hay privilegio que escalar, y cada sentencia que emiten
-- pasa por la RLS igual que si el cliente la escribiera a mano. Es justamente lo
-- que se pierde cuando la ingesta corre como su dueño.
grant execute on function sync.aplicar_job(jsonb) to authenticated, service_role;
grant execute on function sync.aplicar_job_interno(uuid, jsonb) to authenticated, service_role;
grant execute on function sync.columnas_escribibles(text) to authenticated, service_role;
grant execute on function sync.expresion_json(regclass) to authenticated, service_role;
grant execute on function sync.registrar(uuid, text, text, bigint) to authenticated, service_role;
grant execute on function sync.rechazo(uuid, text, text) to authenticated, service_role;

-- purgar_* no se otorga a nadie: las corre pg_cron como su dueño, y son
-- SECURITY DEFINER justamente para poder borrar filas de todos los usuarios.
