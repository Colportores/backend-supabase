-- El delta y la RLS, ahora que hay tablas globales.

-- --- pull: las globales no se filtran por usuario ---------------------------

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
begin
  foreach v_entidad in array p_entidades loop
    select e.tabla, e.por_usuario into v_tabla, v_por_usuario
    from sync.entidad e where e.nombre = v_entidad;
    -- Una entidad que el cliente pide y el servidor no conoce se ignora: un
    -- cliente más nuevo que el backend no puede tumbar la sync de los demás.
    continue when v_tabla is null;

    v_desde := coalesce(p_watermark -> v_entidad,
                        jsonb_build_object('ts', '-infinity', 'id', '00000000-0000-0000-0000-000000000000'));

    -- Un catálogo no tiene dueño: el filtro por usuario se reemplaza por
    -- `true`. Escribirlo así, y no con dos consultas, deja el orden y el
    -- paginado en un solo lugar.
    execute format($q$
      select coalesce(jsonb_agg(j order by ts, id), '[]'::jsonb)
      from (
        select %s as j, t.updated_at as ts, t.id as id
        from %s t
        where %s
          and (t.updated_at, t.id) > ($2::timestamptz, $3::uuid)
        order by t.updated_at, t.id
        limit $4 + 1
      ) s
    $q$,
      sync.expresion_json(v_tabla), v_tabla,
      case when v_por_usuario then 't.pk_usuario = $1' else '($1 is not null)' end)
    into v_filas
    using p_usuario, (v_desde ->> 'ts'), (v_desde ->> 'id')::uuid, p_limite;

    continue when jsonb_array_length(v_filas) = 0;

    if jsonb_array_length(v_filas) > p_limite then
      v_hay_mas := true;
      v_filas := (select jsonb_agg(f) from (
        select f from jsonb_array_elements(v_filas) f limit p_limite
      ) s);
    end if;

    v_rows := v_rows || jsonb_build_object(v_entidad, v_filas);

    v_ultima := v_filas -> (jsonb_array_length(v_filas) - 1);
    v_nuevo := v_nuevo || jsonb_build_object(v_entidad, jsonb_build_object(
      'ts', v_ultima ->> 'updated_at',
      'id', v_ultima ->> 'id'
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

-- --- push: los catálogos son de solo lectura, y el servidor lo hace cumplir --

create function sync.ya_aplicado(p_op_id uuid) returns boolean language sql stable as $$
  select exists (select 1 from sync.op_cache where client_op_id = p_op_id);
$$;


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

-- --- RLS para todo lo nuevo -------------------------------------------------

do $$
declare r record;
begin
  for r in select e.nombre, e.tabla::text as tabla, e.por_usuario
           from sync.entidad e loop
    execute format('alter table %s enable row level security', r.tabla);

    -- `drop policy if exists` avisa por cada una que no existía; en una
    -- migración que crea 17 políticas eso es puro ruido.
    set local client_min_messages = warning;
    execute format('drop policy if exists %I on %s', r.nombre || '_visible', r.tabla);

    if r.por_usuario then
      -- Cada colportor ve lo suyo.
      execute format(
        'create policy %I on %s for select to public using (pk_usuario = sync.usuario_actual())',
        r.nombre || '_visible', r.tabla);
    else
      -- El catálogo lo ve cualquiera que esté autenticado, pero nadie sin
      -- identidad: no hay razón para que un anónimo lea la lista de precios.
      execute format(
        'create policy %I on %s for select to public using (sync.usuario_actual() is not null)',
        r.nombre || '_visible', r.tabla);
    end if;
  end loop;
end;
$$;
