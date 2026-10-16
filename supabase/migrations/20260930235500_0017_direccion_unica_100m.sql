-- ============================================================================
-- 0017 · Dirección única a menos de 100 m (D1) y normalización con espacios y tildes
--        (backend-supabase#34)
--
-- Decisión D1 de Cristian (29/09, backend-supabase#24, comentario 5900053347): «Dos ubicaciones
-- chocan cuando tienen la misma dirección normalizada (ciudad, calle y número) y están a menos de
-- 100 m una de otra. Con la misma dirección a 100 m o más, se aceptan las dos. […] El push que
-- choca devuelve un conflicto (el 23505 u otro código acordado con el motor, #178). La fila queda
-- en el celular y la app lo resuelve con la vista 10, así que no se pierde nada.»
-- Decisión 3 de front-colportores-mobile#207 (comentario 5900419787): «además de trim y
-- minúsculas, se juntan los espacios internos y los raros (tabs, espacios duros) y se sacan las
-- tildes: unaccent en direccion_normalizada() del servidor y lo mismo en Dart. Hay que rehacer el
-- índice de 0010 […] y aplica a la regla de dirección única de D1.»
-- Esquema: docs/esquema-datos.md, `ubicacion` (RF-UB08). Contrato de sync §2.2.
--
-- ## 1. direccion_normalizada(), con espacios y tildes
--
-- En este orden: unaccent (el diccionario `unaccent` de Postgres), cada carácter de espacio
-- Unicode (tabla abajo) pasa a un espacio común y los seguidos se juntan en uno, trim, minúsculas;
-- vacío = null. «  Av.  Itália » y «av. italia» dan lo mismo. Sigue IMMUTABLE: la usan índices.
-- El índice de dirección de 0010 (ubicacion_direccion_idx) se rehace, porque sus entradas se
-- calcularon con la versión vieja. posibles_duplicados_de_ubicacion() (el aviso de 0010) la usa, así
-- que el aviso también pasa a ignorar tildes y espacios.
--
-- ## 2. La regla: trigger con distancia, no índice único
--
-- «A menos de 100 m» no es una igualdad, así que no hay índice único que la cubra, y un EXCLUDE
-- con && sobre círculos compara cajas, no distancias. Va un trigger AFTER INSERT/UPDATE en
-- ubicacion (por cualquier camino: push, RPC, servidor):
--   · participan las filas vivas (deleted_at null) con calle Y número normalizados no nulos; las
--     dadas de baja y las que no tienen calle o número quedan afuera, de los dos lados;
--   · chocan dos filas de la misma ciudad (ciudad_id), con la misma calle y el mismo número
--     normalizados, a menos de 100 m (ST_Distance sobre geography, elipsoide: < 100). A 100 m
--     justos se aceptan;
--   · se revisa al insertar, y al cambiar calle, número, posición o ciudad, o al reactivar
--     (deleted_at vuelve a null). Cambiar otra cosa no revisa nada;
--   · SECURITY DEFINER: tiene que ver TODAS las ubicaciones, también las que la RLS no le muestra a
--     quien escribe (la casa que registró otro colportor, en otra zona). No devuelve nada de la
--     otra fila: ni su id ni su posición;
--   · carrera: dos altas de la misma dirección al mismo tiempo no se ven entre sí (ninguna hizo
--     commit). El trigger toma un lock advisory por (ciudad, calle, número) normalizados hasta el
--     final de la transacción y recién ahí mira: la segunda espera a que la primera termine y la
--     ve. Supone READ COMMITTED (el default de PostgREST y de sync.push): en REPEATABLE READ la
--     segunda no vería a la primera. Un lote que registra dos direcciones y otro que registra las
--     mismas en orden inverso pueden trabarse; Postgres corta a uno (sale 500 y el motor
--     reintenta), como el lock por ciudad de 0010.
-- El error: 23505 (unique_violation) con constraint = 'ubicacion_direccion_unica', y un mensaje que
-- dice qué hacer (abrir la existente, o corregir la dirección o la posición).
--
-- ## 3. El push: conflicto, no invalid (PROPUESTA, pendiente con el motor)
--
-- Hasta acá sync.aplicar_job() devolvía todo 23505 como `invalid`. Ahora, SOLO el de esta regla
-- (por el nombre de la restricción) vuelve como conflicto; el resto de la clase 23 sigue invalid:
--
--   {"client_op_id": …, "outcome": "conflict", "code": "23505",
--    "constraint": "ubicacion_direccion_unica", "message": "Ya hay otra ubicación en …"}
--
-- Sin server_row ni sync_version, a propósito: el conflicto de siempre (LWW por sync_version)
-- trae la fila del servidor para que el motor la aplique, y acá eso pisaría la fila del teléfono.
-- La fila queda en el celular, el servidor no escribe nada (ni la fila ni el cache de
-- client_op_id: un reintento se vuelve a revisar), y la app lo resuelve con la vista 10. Las
-- claves y el estado del job mientras tanto se acuerdan con el motor
-- (front-colportores-mobile#178, contrato §2.2); este formato es la propuesta del backend.
--
-- ## 4. Duplicados que ya están en la base: la migración no da de baja nada
--
-- Decisión de Cristian del 02/10 (backend-supabase#49, comentario 5951900680): «La migración 0017
-- aborta también con las casas repetidas vacías: lista todas las repetidas (misma dirección a
-- menos de 100 m) y se resuelven a mano desde la vista 10. Una migración nunca manda una baja,
-- porque el servidor no ve las personas y ventas que el teléfono todavía no subió.»
--
-- Antes de crear el trigger se revisan las ubicaciones vivas con la regla nueva (ya con tildes y
-- espacios): todo par de ubicaciones vivas de la misma ciudad, con la misma calle y número
-- normalizados, a menos de 100 m. Si hay alguno, la migración aborta sin cambiar nada y lista
-- TODOS los pares: la más nueva (B) con la más vieja (A, por created_at e id), la distancia, lo
-- que el servidor ve colgado de B (personas en sus espacios, estado en el mapa, departamentos o
-- espacios cargados, cobranzas o agendas que la usan como dirección alternativa) o que no ve
-- nada, y qué hacer: si es la misma casa, «Marcar como duplicado» desde la vista 10 (HU-UBI-006,
-- decisión 2 de front-colportores-mobile#207: pasa sus personas a la otra y la da de baja, y lo
-- hace la app porque las personas viven en el teléfono); si es otra casa, corregir su dirección o
-- su posición. Con la lista resuelta se vuelve a aplicar, y se revisa todo otra vez. Ni las que
-- no tienen nada colgado se dan de baja: «nada colgado» es lo que ve el servidor, no lo que el
-- teléfono tiene sin subir.
--
-- ## 5. Lo que cuelga de un alta en conflicto queda en espera (el push)
--
-- Decisión de Cristian del 02/10 (backend-supabase#49, comentario 5951937663): «Caso: un
-- colportor registra sin señal una casa que otro ya cargó (misma dirección a menos de 100 m) y le
-- agrega depto, persona y venta. El backend devuelve conflicto/espera (no invalid) para lo que
-- cuelga de un alta que volvió en conflicto, para que el motor lo reintente cuando se resuelva y
-- la venta no quede varada.»
--
-- Sin esto, el alta de la casa vuelve `conflict` (sección 3) y no se guarda, y lo que cuelga de
-- ella en el mismo lote falla porque su fila padre no existe en el servidor: el espacio por la
-- RLS (42501: no puede escribir en una casa que no existe), espacio_persona, la visita y la venta
-- por la FK (23503), y una corrección de una fila que tampoco entró por FILA_INEXISTENTE. Los tres
-- eran `invalid`: sin reintento automático (ADR-007), la venta quedaba varada en la cola de error.
--
-- sync.push() lleva, a lo largo del lote, las filas que quedaron en espera: el alta (op insert)
-- que volvió `conflict` sin server_row (la de D1) y, en cascada, las que esperan por ella. Un job
-- posterior del mismo lote que vuelve `invalid` con 23503, 42501 o FILA_INEXISTENTE y que tiene en
-- su payload el id de una fila en espera (como referencia o como su propia PK) vuelve:
--
--   {"client_op_id": …, "outcome": "conflict", "code": "ESPERA_ALTA_EN_CONFLICTO",
--    "depends_on": "<id de la fila en espera>", "message": "…"}
--
-- Sin server_row ni sync_version (no hay fila del servidor que aplicar), y sin escribir nada: ni la
-- fila ni el cache de client_op_id, así que al reintentarlo se vuelve a revisar. El motor lo deja
-- en espera hasta que la app resuelva el alta (vista 10) y lo reintenta después.
--   · Solo dentro del mismo lote y hacia adelante: los jobs van en orden de creación (contrato
--     §5.5), así que lo que cuelga de un alta llega después de ella. Lo que cuelga de un alta en
--     conflicto que se sube en OTRO lote sin el alta (el servidor no la guardó) sigue volviendo
--     `invalid`; si el motor reintenta el alta junto con lo que cuelga, vuelve a quedar en espera.
--     Cómo se arma el lote es del motor (#178).
--   · Los demás `invalid` no cambian: un 23503 o un 42501 que no cuelga de una fila en espera
--     sigue siendo un error de payload.
--
-- ## Para otros repos
--
--   · front-colportores-mobile (#207, #193, #202, #208, #233): la normalización en Dart tiene que
--     dar lo mismo. Espacios: [\u0009-\u000D \u0085   -
--       　﻿]+ → ' '. Tildes: las reglas de unaccent de Postgres (unaccent.rules),
--     que además de las tildes pasan ñ → n, ü → u, ç → c, æ → ae, ß → ss y otras ligaduras.
--     Chocar a menos de 100 m es ST_Distance sobre el elipsoide WGS84 (< 100, estricto).
--   · Motor de sync (#178, Bruno): el outcome `conflict` con code 23505 y constraint
--     'ubicacion_direccion_unica' no trae server_row: no se aplica LWW; la fila queda local y el job
--     espera a que la app lo resuelva (vista 10). Lo que cuelga de esa alta en el mismo lote vuelve
--     `conflict` con code 'ESPERA_ALTA_EN_CONFLICTO' y depends_on (sección 5): se reintenta cuando
--     se resuelva el alta. Forma pendiente de acuerdo; hay que sumarlo al contrato de sync
--     (docs-organizacion, §2.2).
--   · Migración: si la base tiene direcciones repetidas a menos de 100 m, aborta y las lista
--     (sección 4); se resuelven desde la vista 10 antes de volver a aplicarla.
--   · Panel y BFF: una escritura directa que choca recibe el 23505 con el mensaje y el hint.
--
-- ## Orden de despliegue
--
-- Va arriba de la pila #36…#48 (0011–0016), con número 0017 y timestamp posterior a 0016: entra
-- después, porque deploy.yml corre `supabase db push` sin --include-all. La migración no usa nada
-- de 0011–0016 (no toca sync.pull, las zonas ni la RLS); lo que la ata a la pila son los fixtures
-- de 0002_rls_test y 0013_ubicacion_sin_zona_test, que la pila ya había cambiado.
--
-- Forward-only: esta migración no se edita una vez aplicada.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. unaccent
-- ----------------------------------------------------------------------------

create extension if not exists unaccent with schema extensions;

do $$
declare
  v_esquema text;
begin
  select n.nspname into v_esquema
    from pg_extension e join pg_namespace n on n.oid = e.extnamespace
   where e.extname = 'unaccent';
  if v_esquema is distinct from 'extensions' then
    raise exception using
      message = format('La migración 0017 no se aplicó: la extensión unaccent está en el esquema %s '
                       'y direccion_normalizada() la busca en extensions. No se cambió nada.', v_esquema),
      hint    = 'Movela con «alter extension unaccent set schema extensions» y volvé a aplicar la migración.';
  end if;
end
$$;

-- ----------------------------------------------------------------------------
-- 2. direccion_normalizada(): tildes y espacios; el índice de 0010 se rehace
-- ----------------------------------------------------------------------------

-- unaccent con el diccionario explícito (dos argumentos): con search_path vacío la versión de un
-- argumento no encuentra el diccionario. La clase de espacios es la de «Para otros repos».
create or replace function public.direccion_normalizada(p_texto text)
returns text
language sql
immutable
parallel safe
set search_path = ''
as $$
  select nullif(lower(btrim(regexp_replace(
           extensions.unaccent('extensions.unaccent'::regdictionary, p_texto),
           '[\u0009-\u000d \u0085   -     　﻿]+',
           ' ', 'g'))), '');
$$;

comment on function public.direccion_normalizada(text) is
  'Calle o número normalizados para comparar direcciones (D1, front-colportores-mobile#207): '
  'unaccent, espacios Unicode juntados en uno, trim y minúsculas; vacío = null. La app usa la misma '
  'en Dart.';

drop index public.ubicacion_direccion_idx;
create index ubicacion_direccion_idx on public.ubicacion
  (ciudad_id, public.direccion_normalizada(calle), public.direccion_normalizada(numero))
  where deleted_at is null;

comment on index public.ubicacion_direccion_idx is
  'No es único: D1 mira la distancia (a menos de 100 m), así que la hace cumplir el trigger '
  'ubicacion_direccion_unica_* (0017). Este índice le acelera la búsqueda y al aviso de duplicados.';

-- ----------------------------------------------------------------------------
-- 3. Duplicados vivos que ya están en la base: si hay, aborta y los lista todos
-- ----------------------------------------------------------------------------

-- No da de baja nada (decisión del 02/10, ver el header): el servidor no ve lo que los teléfonos
-- todavía no subieron.
do $$
declare
  v_lista text;
  v_pares integer;
begin
  -- Cada par que la regla rechazaría: B es la más nueva (created_at, id), A la más vieja.
  create temp table d1_par on commit drop as
  select b.id as b_id, a.id as a_id,
         extensions.st_distance(public.ubicacion_geografia(a.lat, a.lon),
                                public.ubicacion_geografia(b.lat, b.lon)) as distancia
    from public.ubicacion b
    join public.ubicacion a
      on a.id <> b.id
     and a.deleted_at is null
     and a.ciudad_id = b.ciudad_id
     and public.direccion_normalizada(a.calle) = public.direccion_normalizada(b.calle)
     and public.direccion_normalizada(a.numero) = public.direccion_normalizada(b.numero)
     and (a.created_at, a.id) < (b.created_at, b.id)
     and extensions.st_dwithin(public.ubicacion_geografia(a.lat, a.lon),
                               public.ubicacion_geografia(b.lat, b.lon), 100.0::double precision)
     and extensions.st_distance(public.ubicacion_geografia(a.lat, a.lon),
                                public.ubicacion_geografia(b.lat, b.lon)) < 100.0
   where b.deleted_at is null
     and public.direccion_normalizada(b.calle) is not null
     and public.direccion_normalizada(b.numero) is not null;

  select count(*) into v_pares from d1_par;
  if v_pares = 0 then
    return;
  end if;

  -- Lo que el servidor ve colgado de cada B (para decidir; no cambia lo que pasa).
  select string_agg(
           format('  · %s %s (%s, registrada por %s el %s) está a %s m de %s %s (%s, registrada el %s), '
                  'con la misma dirección, y %s. Si es la misma casa, marcá la más nueva como '
                  'duplicado de la otra desde la app (vista 10, «Posibles duplicados»: pasa sus '
                  'personas a la otra y la da de baja); si es otra casa, corregí su dirección o su '
                  'posición.',
                  b.calle, b.numero, b.id, coalesce(b.created_by::text, 'nadie'),
                  to_char(b.created_at, 'DD/MM/YYYY'), round(p.distancia::numeric, 1),
                  a.calle, a.numero, a.id, to_char(a.created_at, 'DD/MM/YYYY'),
                  coalesce('tiene ' || nullif(array_to_string(array_remove(array[
                    case when exists (select 1 from public.espacio_persona ep
                                        join public.espacio e on e.id = ep.espacio_id
                                       where e.ubicacion_id = b.id)
                         then 'personas en sus espacios' end,
                    case when exists (select 1 from public.house_status h
                                       where h.ubicacion_id = b.id and h.deleted_at is null)
                         then 'estado en el mapa' end,
                    case when (select count(*) from public.espacio e
                                where e.ubicacion_id = b.id and e.deleted_at is null) > 1
                           or exists (select 1 from public.espacio e
                                       where e.ubicacion_id = b.id and e.deleted_at is null
                                         and (nullif(btrim(e.numero_depto), '') is not null
                                              or nullif(btrim(e.piso), '') is not null
                                              or nullif(btrim(e.descripcion), '') is not null))
                         then 'departamentos o espacios cargados' end,
                    case when exists (select 1 from public.espacio_persona ep
                                       where ep.ubicacion_cobranza_alt_id = b.id)
                           or exists (select 1 from public.agenda ag where ag.ubicacion_alt_id = b.id)
                         then 'cobranzas o agendas que la usan como dirección alternativa' end
                  ], null), ', '), ''),
                  'el servidor no ve nada colgado de ella (el teléfono puede tener personas o ventas '
                  'sin subir)')),
           E'\n' order by b.ciudad_id, b.created_at, b.id, a.created_at, a.id)
    into v_lista
    from d1_par p
    join public.ubicacion b on b.id = p.b_id
    join public.ubicacion a on a.id = p.a_id;

  raise exception using
    message = format('La migración 0017 (dirección única a menos de 100 m) no se aplicó: hay %s '
                     'par(es) de ubicaciones vivas con la misma dirección a menos de 100 m. No se '
                     'cambió nada.', v_pares),
    detail  = v_lista,
    hint    = 'Resolvé cada par desde la vista 10 de la app y volvé a aplicar la migración. La '
              'migración no da de baja ninguna, ni las que no tienen nada colgado: el servidor no ve '
              'lo que los teléfonos todavía no subieron.';
end
$$;

-- ----------------------------------------------------------------------------
-- 4. La regla: trigger en ubicacion
-- ----------------------------------------------------------------------------

create function public.tg_ubicacion_direccion_unica()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_calle  text := public.direccion_normalizada(new.calle);
  v_numero text := public.direccion_normalizada(new.numero);
  v_punto  extensions.geography;
begin
  if new.deleted_at is not null or v_calle is null or v_numero is null then
    return null;
  end if;

  -- Hasta el commit: la otra alta de la misma dirección espera acá y después ve esta fila.
  perform pg_advisory_xact_lock(hashtextextended(
    'direccion_unica:' || new.ciudad_id::text || ':' || v_calle || ':' || v_numero, 0));

  v_punto := public.ubicacion_geografia(new.lat, new.lon);

  if exists (
    select 1 from public.ubicacion u
     where u.ciudad_id = new.ciudad_id
       and public.direccion_normalizada(u.calle) = v_calle
       and public.direccion_normalizada(u.numero) = v_numero
       and u.deleted_at is null
       and u.id <> new.id
       and extensions.st_dwithin(public.ubicacion_geografia(u.lat, u.lon), v_punto, 100.0::double precision)
       and extensions.st_distance(public.ubicacion_geografia(u.lat, u.lon), v_punto) < 100.0
  ) then
    raise exception using
      errcode    = 'unique_violation',
      constraint = 'ubicacion_direccion_unica',
      schema     = 'public',
      table      = 'ubicacion',
      message    = format('Ya hay otra ubicación en «%s %s» a menos de 100 m.',
                          btrim(new.calle), btrim(new.numero)),
      hint       = 'Si es la misma casa, abrí la existente; si es otra, corregí la dirección o la '
                   'posición: con la misma dirección tienen que estar a 100 m o más.';
  end if;

  return null;
end;
$$;

comment on function public.tg_ubicacion_direccion_unica() is
  'D1: dos ubicaciones vivas de la misma ciudad con la misma calle y número normalizados no pueden '
  'estar a menos de 100 m. 23505 con constraint ubicacion_direccion_unica. SECURITY DEFINER: mira '
  'todas las filas, no solo las que la RLS le muestra a quien escribe (0017).';

create trigger ubicacion_direccion_unica_insert
  after insert on public.ubicacion
  for each row
  when (new.deleted_at is null and new.calle is not null and new.numero is not null)
  execute function public.tg_ubicacion_direccion_unica();

create trigger ubicacion_direccion_unica_update
  after update on public.ubicacion
  for each row
  when (new.deleted_at is null and new.calle is not null and new.numero is not null
        and (old.calle is distinct from new.calle
             or old.numero is distinct from new.numero
             or old.lat is distinct from new.lat
             or old.lon is distinct from new.lon
             or old.ciudad_id is distinct from new.ciudad_id
             or old.deleted_at is not null))
  execute function public.tg_ubicacion_direccion_unica();

-- ----------------------------------------------------------------------------
-- 5. El push: el choque de D1 vuelve como conflicto (propuesta, ver arriba)
-- ----------------------------------------------------------------------------

-- Igual que en 0002, salvo el handler: el 23505 de ubicacion_direccion_unica es `conflict`.
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
end;
$$;

-- ----------------------------------------------------------------------------
-- 6. El push: lo que cuelga de un alta en conflicto queda en espera
-- ----------------------------------------------------------------------------

-- El id de una fila en espera que el job nombra en su payload (su propia PK primero, después
-- cualquier columna), o null. Solo mira valores con forma de uuid. Interna de sync.push().
create function sync.fila_en_espera(p_job jsonb, p_en_espera uuid[])
returns uuid
language sql
stable
set search_path = ''
as $$
  select v.id
    from (select x.key,
                 case when x.value ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
                      then x.value::uuid end as id
            from jsonb_each_text(case when jsonb_typeof(p_job -> 'payload') = 'object'
                                      then p_job -> 'payload' else '{}'::jsonb end) x) v
   where v.id = any (p_en_espera)
   order by v.key = (select e.columna_pk from sync.entidad e where e.nombre = p_job ->> 'entity') desc,
            v.key
   limit 1;
$$;

comment on function sync.fila_en_espera(jsonb, uuid[]) is
  'El id de una fila en espera (un alta en conflicto del mismo lote, o algo que cuelga de ella) '
  'que el job nombra en su payload, o null. Interna de sync.push() (0017).';

-- Igual que en 0002, más la espera (sección 5 del header).
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
            hint = 'partí el lote; el BFF ya lo hace a los 500 (RR-02)';
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
-- 7. Privilegios
-- ----------------------------------------------------------------------------

-- `authenticated` también: en una base creada desde cero los default privileges de la imagen le
-- dan EXECUTE sobre cada función nueva de public (ver 0008). El trigger corre igual sin EXECUTE.
revoke all on function public.tg_ubicacion_direccion_unica() from public, anon, authenticated;

-- sync.fila_en_espera: la llama sync.push(), que corre como quien sube (SECURITY INVOKER), así
-- que authenticated la necesita; anon no (0003_sync_infra_test). sync.push() conserva los suyos
-- (create or replace no los toca).
revoke all on function sync.fila_en_espera(jsonb, uuid[]) from public, anon;
grant execute on function sync.fila_en_espera(jsonb, uuid[]) to authenticated, service_role;
