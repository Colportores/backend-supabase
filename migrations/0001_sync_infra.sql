-- Infraestructura de sincronización (§4: "RPC de ingesta batch, cache de
-- client_op_id (TTL 24 h), vistas de delta").
--
-- Todo vive en el schema `sync` para que se distinga de un vistazo del esquema
-- de negocio, que es de Cristian.

create schema if not exists sync;

-- ---------------------------------------------------------------------------
-- Qué entidades se pueden sincronizar
-- ---------------------------------------------------------------------------

-- El registro es una tabla y no una lista en el código a propósito: el RPC de
-- ingesta es genérico, y sin una lista blanca explícita un cliente podría
-- mandar `entity: "usuario"` y escribir donde no debe.
--
-- Es el espejo del SyncSpec del motor. Si una entidad no está acá, no entra:
-- el equivalente en SQL de "una entidad sin registrar es un error".
create table sync.entidad (
  nombre            text primary key,
  tabla             regclass not null,

  -- Columnas que fija el servidor y que el cliente NO puede sobrescribir
  -- (§5.4). Se descartan del payload en silencio: un cliente viejo que las
  -- mande no tiene por qué fallar, pero tampoco ganar.
  columnas_servidor text[] not null default array['sync_version', 'updated_at', 'pk_usuario'],

  unique (tabla)
);

-- ---------------------------------------------------------------------------
-- Cache de client_op_id (§5.3)
-- ---------------------------------------------------------------------------

-- Idempotencia del *intento*. Reintentar un push tras un timeout tiene que
-- devolver `duplicate`, no aplicar dos veces.
--
-- El TTL de 24 h alcanza para los reintentos de un ciclo; lo que sobrevive más
-- que eso —el replay de §7 desde un backup viejo— se apoya en la PK UUID v7
-- del dispositivo, no en este cache.
create table sync.op_cache (
  client_op_id  uuid primary key,
  pk_usuario    uuid not null,
  entidad       text not null,
  -- Solo se cachea lo que se aplicó. Un rechazo no entra: el job nunca tocó
  -- la base, así que no hay nada que deduplicar.
  outcome       text not null check (outcome in ('accepted','duplicate','conflict')),
  sync_version  int,
  codigo        text,
  mensaje       text,
  aplicado_en   timestamptz not null default now()
);

create index on sync.op_cache (aplicado_en);

comment on table sync.op_cache is
  'Idempotencia por intento. Purgar a las 24 h con sync.purgar_cache().';

create function sync.purgar_cache(p_ttl interval default interval '24 hours')
returns integer language sql as $$
  with borradas as (
    delete from sync.op_cache where aplicado_en < now() - p_ttl returning 1
  )
  select count(*)::int from borradas;
$$;

-- ---------------------------------------------------------------------------
-- Columnas que el cliente sí puede escribir
-- ---------------------------------------------------------------------------

create function sync.columnas_escribibles(p_entidad text)
returns text[] language sql stable as $$
  select coalesce(array_agg(c.attname::text), array[]::text[])
  from sync.entidad e
  join pg_attribute c on c.attrelid = e.tabla
  where e.nombre = p_entidad
    and c.attnum > 0
    and not c.attisdropped
    and not (c.attname::text = any (e.columnas_servidor));
$$;

-- ---------------------------------------------------------------------------
-- Serialización de una fila
-- ---------------------------------------------------------------------------

-- Los decimales viajan como string, nunca como número JSON.
--
-- `to_jsonb(fila)` convierte un numeric(10,2) en un número JSON: `42.50` sale
-- como `42.5`, y del otro lado `jsonDecode` lo parsea como double. Para km da
-- igual; para el `total` de una venta es exactamente lo que el formato de cable
-- prohíbe, y el error no se ve hasta que alguien suma mal un estado de cuenta.
--
-- La conversión se hace acá y no en el BFF porque acá se sabe el tipo de cada
-- columna: una vez que la fila es jsonb, esa información ya se perdió.

create function sync.expresion_json(p_tabla regclass)
returns text language sql stable as $$
  select 'jsonb_build_object(' || string_agg(
           format('%L, %s', c.attname,
             case when c.atttypid = 'numeric'::regtype
                  then format('(t.%I)::text', c.attname)
                  else format('t.%I', c.attname) end),
           ', ' order by c.attnum)
         || ')'
  from pg_attribute c
  where c.attrelid = p_tabla and c.attnum > 0 and not c.attisdropped;
$$;

comment on function sync.expresion_json(regclass) is
  'Arma la expresión que serializa una fila de p_tabla a jsonb con los numeric '
  'como texto. Se usa con `execute format(...)`; los nombres salen del catálogo '
  'y pasan por %I, así que no hay inyección posible.';
