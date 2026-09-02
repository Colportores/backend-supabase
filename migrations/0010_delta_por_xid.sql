-- El cursor del delta pasa de (updated_at, id) a (xmin_w, id).
--
-- ## El bug
--
-- `updated_at` se llena con `now()`, que en Postgres es la hora de **inicio de
-- la transacción**, no la del commit. Dos escritores concurrentes pueden
-- commitear en orden distinto del de sus timestamps:
--
--     A: begin (15:43) ── insert ────────────────────── commit (15:45)
--     B:            begin (15:44) ── insert ── commit (15:44)
--     pull:                                  ↑ acá: ve solo B, watermark = 15:44
--
-- Cuando A commitea, su fila queda con `updated_at` 15:43 — **detrás** de un
-- watermark que ya avanzó a 15:44. El delta filtra por
-- `(updated_at, id) > watermark`, así que esa fila no vuelve a aparecer nunca.
-- La jornada del colportor se subió, el servidor la tiene, y ningún cliente la
-- ve jamás.
--
-- El par `(updated_at, id)` **no** arregla esto: desempata timestamps iguales,
-- que es otro problema. Acá los timestamps son distintos y el orden está mal.
--
-- Reproducido con dos conexiones en `test/concurrencia.sh`: dos filas en la
-- base, una sola entregada, y la segunda perdida para siempre.
--
-- ## El arreglo
--
-- El orden lo tiene que dar algo que no pueda retroceder, y en Postgres eso es
-- el id de transacción. Cada fila guarda el suyo (`xmin_w`), y el pull sirve
-- solo lo que está **por debajo del horizonte del snapshot**:
--
--     pg_snapshot_xmin(pg_current_snapshot())  -- el xid vivo más viejo
--
-- Toda transacción que todavía pueda commitear tiene xid ≥ ese horizonte, por
-- definición de xmin. Entonces cualquier fila futura entra con un `xmin_w`
-- mayor que **todo** lo que este pull entregó, y por lo tanto por delante del
-- watermark. La fila de A del ejemplo no se saltea: se queda esperando y sale
-- en el pull siguiente, que es justo lo que tiene que pasar.
--
-- `xid8` es de 64 bits y no da la vuelta, así que se compara como un entero
-- común y no hay que pensar en wraparound.
--
-- Se usa el horizonte y no `pg_stat_activity`: leer el `xact_start` de otros
-- backends necesita `pg_monitor`, y si no lo tenés `min()` devuelve NULL y la
-- protección desaparece **en silencio**. El horizonte no depende de permisos.
--
-- ## Qué NO cambia
--
-- `updated_at` se queda: sirve para el negocio y viaja en el payload. Lo que
-- deja de hacer es ordenar el delta.
--
-- El watermark es opaco para el cliente (lo dice el BFF), así que cambiarle la
-- forma de `{ts, id}` a `{xid, id}` no rompe el contrato. Un watermark viejo
-- con `ts` se trata como "desde cero": se resincroniza y no se pierde nada.

-- ---------------------------------------------------------------------------
-- La columna, en toda tabla registrada
-- ---------------------------------------------------------------------------

-- Se recorre el registro en vez de listar 17 tablas a mano: el registro ya es
-- la fuente de verdad de qué se sincroniza, y así una entidad futura no se
-- puede olvidar de esta columna.
do $$
declare r record;
begin
  for r in select e.tabla::text as tabla from sync.entidad e loop
    execute format(
      'alter table %s add column if not exists xmin_w xid8 not null default pg_current_xact_id()',
      r.tabla);
  end loop;
end;
$$;

-- Es una columna del servidor: que el cliente la mande no puede servirle de
-- nada, o se saltearía el orden del delta.
alter table sync.entidad
  alter column columnas_servidor
  set default array['sync_version', 'updated_at', 'pk_usuario', 'xmin_w'];

update sync.entidad
   set columnas_servidor = array(select distinct unnest(columnas_servidor || array['xmin_w']))
 where not ('xmin_w' = any (columnas_servidor));

-- El índice del delta, en el orden nuevo.
do $$
declare r record;
begin
  for r in select e.tabla::text as tabla, e.por_usuario from sync.entidad e loop
    if r.por_usuario then
      execute format('create index if not exists %I on %s (pk_usuario, xmin_w, id)',
                     replace(r.tabla, '.', '_') || '_delta_xid', r.tabla);
    else
      execute format('create index if not exists %I on %s (xmin_w, id)',
                     replace(r.tabla, '.', '_') || '_delta_xid', r.tabla);
    end if;
  end loop;
end;
$$;

-- ---------------------------------------------------------------------------
-- `xmin_w` no viaja por el cable
-- ---------------------------------------------------------------------------

-- Es maquinaria del cursor, no un dato del negocio. El cliente no la necesita
-- y mandársela invita a que alguien la use como si significara algo.
create or replace function sync.expresion_json(p_tabla regclass)
returns text language sql stable as $$
  select 'jsonb_build_object(' || string_agg(
           format('%L, %s', c.attname,
             case when c.atttypid = 'numeric'::regtype
                  then format('(t.%I)::text', c.attname)
                  else format('t.%I', c.attname) end),
           ', ' order by c.attnum)
         || ')'
  from pg_attribute c
  where c.attrelid = p_tabla and c.attnum > 0 and not c.attisdropped
    and c.attname::text <> 'xmin_w';
$$;

-- ---------------------------------------------------------------------------
-- El pull
-- ---------------------------------------------------------------------------

create or replace function sync.pull(
  p_usuario   uuid,
  p_entidades text[],
  p_watermark jsonb default '{}'::jsonb,
  p_limite    int default 500
) returns jsonb language plpgsql as $$
declare
  v_entidad     text;
  v_tabla       regclass;
  v_por_usuario boolean;
  v_desde       jsonb;
  v_filas       jsonb;
  v_rows        jsonb := '{}'::jsonb;
  v_nuevo       jsonb := coalesce(p_watermark, '{}'::jsonb);
  v_hay_mas     boolean := false;
  v_ultima      jsonb;
  v_horizonte   xid8;
  v_limite      int;
begin
  -- Un límite fuera de rango es un cliente roto o un abuso, no una razón para
  -- devolver 500 (un `limit` negativo es un error de Postgres) ni para armar
  -- una respuesta de un millón de filas. Se acota y se sigue.
  v_limite := least(greatest(coalesce(p_limite, 500), 1), 1000);

  -- Una sola vez para todas las entidades del pull: así el corte es el mismo
  -- para todas y el watermark que devolvemos es consistente entre ellas.
  v_horizonte := pg_snapshot_xmin(pg_current_snapshot());

  foreach v_entidad in array p_entidades loop
    select e.tabla, e.por_usuario into v_tabla, v_por_usuario
    from sync.entidad e where e.nombre = v_entidad;
    -- Una entidad que el cliente pide y el servidor no conoce se ignora: un
    -- cliente más nuevo que el backend no puede tumbar la sync de los demás.
    continue when v_tabla is null;

    -- Un watermark sin `xid` —ausente, o del formato viejo con `ts`— arranca
    -- de cero. Resincronizar de más es barato; saltear una fila no.
    v_desde := coalesce(p_watermark -> v_entidad, '{}'::jsonb);

    execute format($q$
      select coalesce(jsonb_agg(j order by xw, id), '[]'::jsonb)
      from (
        select %s as j, t.xmin_w as xw, t.id as id
        from %s t
        where %s
          and t.xmin_w < $5
          and (t.xmin_w, t.id) > ($2::xid8, $3::uuid)
        order by t.xmin_w, t.id
        limit $4 + 1
      ) s
    $q$,
      sync.expresion_json(v_tabla), v_tabla,
      case when v_por_usuario then 't.pk_usuario = $1' else '($1 is not null)' end)
    into v_filas
    using p_usuario,
          coalesce(v_desde ->> 'xid', '0'),
          coalesce(v_desde ->> 'id', '00000000-0000-0000-0000-000000000000')::uuid,
          v_limite,
          v_horizonte;

    continue when jsonb_array_length(v_filas) = 0;

    if jsonb_array_length(v_filas) > v_limite then
      v_hay_mas := true;
      v_filas := (select jsonb_agg(f) from (
        select f from jsonb_array_elements(v_filas) f limit v_limite
      ) s);
    end if;

    -- Una entidad ausente de `rows` significa "sin cambios": el cliente no
    -- borra nada por ausencia, así que solo van las que traen algo.
    v_rows := v_rows || jsonb_build_object(v_entidad, v_filas);

    -- El `xmin_w` de la última fila no está en el payload (no viaja), así que
    -- se lee de la tabla por id. Es una fila, por PK.
    v_ultima := v_filas -> (jsonb_array_length(v_filas) - 1);
    execute format('select to_jsonb(t.xmin_w::text) from %s t where t.id = $1', v_tabla)
      into v_desde using (v_ultima ->> 'id')::uuid;

    v_nuevo := v_nuevo || jsonb_build_object(v_entidad, jsonb_build_object(
      'xid', v_desde #>> '{}',
      'id',  v_ultima ->> 'id'
    ));
  end loop;

  return jsonb_build_object(
    'server_time', to_char(now() at time zone 'utc', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"'),
    'watermark', v_nuevo,
    'has_more', v_hay_mas,
    'rows', v_rows
  );
end;
$$;

alter function sync.pull(uuid, text[], jsonb, int)
  security definer set search_path = sync, public, pg_temp;
revoke execute on function sync.pull(uuid, text[], jsonb, int) from public;

-- ---------------------------------------------------------------------------
-- El push tiene que rebotar `xmin_w`
-- ---------------------------------------------------------------------------

-- Sin esto el arreglo sería peor que el bug: una fila actualizada conserva el
-- xid de su INSERT, queda detrás del watermark de cualquier cliente que ya la
-- bajó, y **la modificación no se propaga jamás**. El INSERT no necesita nada
-- porque el DEFAULT de la columna ya pone el xid de la transacción que inserta.
create or replace function sync.aplicar_job_interno(p_usuario uuid, p_job jsonb)
returns jsonb language plpgsql as $$
declare
  v_op_id     uuid   := (p_job ->> 'client_op_id')::uuid;
  v_entidad   text   := p_job ->> 'entity';
  v_op        text   := p_job ->> 'op';
  v_version   int    := (p_job ->> 'sync_version')::int;
  v_payload   jsonb  := p_job -> 'payload';
  v_pk        uuid;
  v_tabla     regclass;
  v_push_ok   boolean;
  v_cols      text[];
  v_usadas    text[];
  v_cache     sync.op_cache%rowtype;
  v_actual    jsonb;
  v_version_nueva int;
  v_filas     int;
begin
  if v_op_id is null then
    return sync.rechazo(v_op_id, 'OP_ID_REQUERIDO', 'falta client_op_id');
  end if;

  -- El cache gana sobre cualquier validación: un op ya aplicado vuelve
  -- `duplicate` y no se re-valida (ver 0002).
  if sync.ya_aplicado(v_op_id) then
    select * into v_cache from sync.op_cache where client_op_id = v_op_id;
    return jsonb_build_object('client_op_id', v_op_id, 'outcome', 'duplicate',
                              'sync_version', v_cache.sync_version);
  end if;

  select e.tabla, e.permite_push into v_tabla, v_push_ok
  from sync.entidad e where e.nombre = v_entidad;
  if v_tabla is null then
    return sync.rechazo(v_op_id, 'ENTIDAD_DESCONOCIDA',
                        format('%L no está registrada para sync', v_entidad));
  end if;

  -- Réplica de solo lectura (§2). Que el cliente no las escriba es una
  -- convención; que el servidor las rechace es una garantía.
  if not v_push_ok then
    return sync.rechazo(v_op_id, 'ENTIDAD_DE_SOLO_LECTURA',
                        format('%L es una réplica: la app no la escribe', v_entidad));
  end if;

  v_pk := (v_payload ->> 'id')::uuid;
  if v_pk is null then
    return sync.rechazo(v_op_id, 'PK_FALTANTE', 'el payload no trae "id"');
  end if;

  v_cols := sync.columnas_escribibles(v_entidad);
  select array_agg(k) into v_usadas
  from jsonb_object_keys(v_payload) k where k = any (v_cols);

  if v_op = 'insert' then
    execute format(
      'insert into %s (%s, pk_usuario) select %s, $2 from jsonb_populate_record(null::%s, $1) x on conflict (id) do nothing',
      v_tabla,
      (select string_agg(quote_ident(c), ', ') from unnest(v_usadas) c),
      (select string_agg('x.' || quote_ident(c), ', ') from unnest(v_usadas) c),
      v_tabla
    ) using v_payload, p_usuario;
    get diagnostics v_filas = row_count;

    execute format('select sync_version from %s where id = $1', v_tabla)
      into v_version_nueva using v_pk;
    return sync.ok(v_op_id, case when v_filas > 0 then 'accepted' else 'duplicate' end,
                   v_version_nueva, v_entidad, p_usuario);
  end if;

  if v_op not in ('update', 'delete') then
    return sync.rechazo(v_op_id, 'OP_INVALIDA', format('op %L', v_op));
  end if;

  execute format('select %s from %s t where t.id = $1',
                 sync.expresion_json(v_tabla), v_tabla)
    into v_actual using v_pk;
  if v_actual is null then
    return sync.rechazo(v_op_id, 'FILA_INEXISTENTE',
                        format('%s no existe en %s', v_pk, v_entidad));
  end if;

  if v_version is null or (v_actual ->> 'sync_version')::int <> v_version then
    perform sync.registrar(v_op_id, p_usuario, v_entidad, 'conflict',
                           (v_actual ->> 'sync_version')::int, null, null);
    return jsonb_build_object('client_op_id', v_op_id, 'outcome', 'conflict',
      'sync_version', (v_actual ->> 'sync_version')::int, 'server_row', v_actual);
  end if;

  -- La versión va en el WHERE del propio UPDATE: es un compare-and-swap, no un
  -- `if` seguido de una escritura (ver 0002).
  if v_op = 'delete' then
    execute format(
      'update %s set deleted = true, sync_version = sync_version + 1, '
      'updated_at = now(), xmin_w = pg_current_xact_id() '
      'where id = $1 and sync_version = $2 returning sync_version',
      v_tabla) into v_version_nueva using v_pk, v_version;
  else
    execute format(
      'update %s t set (%s) = (select %s from jsonb_populate_record(null::%s, $1) x), '
      'sync_version = t.sync_version + 1, updated_at = now(), '
      'xmin_w = pg_current_xact_id() '
      'where t.id = $2 and t.sync_version = $3 returning t.sync_version',
      v_tabla,
      (select string_agg(quote_ident(c), ', ') from unnest(v_usadas) c),
      (select string_agg('x.' || quote_ident(c), ', ') from unnest(v_usadas) c),
      v_tabla
    ) into v_version_nueva using v_payload, v_pk, v_version;
  end if;

  get diagnostics v_filas = row_count;
  if v_filas = 0 then
    execute format('select %s from %s t where t.id = $1',
                   sync.expresion_json(v_tabla), v_tabla)
      into v_actual using v_pk;
    perform sync.registrar(v_op_id, p_usuario, v_entidad, 'conflict',
                           (v_actual ->> 'sync_version')::int, null, null);
    return jsonb_build_object('client_op_id', v_op_id, 'outcome', 'conflict',
      'sync_version', (v_actual ->> 'sync_version')::int, 'server_row', v_actual);
  end if;

  return sync.ok(v_op_id, 'accepted', v_version_nueva, v_entidad, p_usuario);
end;
$$;

alter function sync.aplicar_job_interno(uuid, jsonb)
  security definer set search_path = sync, public, pg_temp;
