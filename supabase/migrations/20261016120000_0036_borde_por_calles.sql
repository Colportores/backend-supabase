-- ============================================================================
-- 0036 · Borde de las zonas por esquinas: las calles de OpenStreetMap y el ruteo en Postgres
--        (backend-supabase#25, ADR-018, HU-CAM-006, vista 24)
--
-- Decisión de Cristian del 29/09 (D3, «Motor de ruteo»): el borde de las zonas por esquinas se
-- calcula con pgRouting, en la misma base que ya valida las zonas con PostGIS (0008). Las calles de
-- OSM se importan por ciudad con un script, y el panel solo llama RPC (ADR-013: sin BFF; el panel
-- llama directo a las RPC de esquina y de tramo, front-coordinadores-web#40). Descartadas: OSRM o
-- Valhalla propio, una API pública y el ruteo en el navegador (ADR-018).
--
-- ## Qué hace falta (el issue) y qué entra acá
--
--   1. Esquina más cercana: dado un punto, el cruce de calles OSM más cercano (un nodo donde se
--      juntan al menos dos calles distintas), con sus coordenadas y los nombres calle_a y calle_b.
--        → public.esquina_mas_cercana(campania_ciudad, lon, lat)
--   2. Tramo por calles: dados dos cruces, el camino más corto por la red de calles, sin respetar
--      sentidos de circulación (el colportor camina).
--        → public.tramo_por_calles(campania_ciudad, desde_lon, desde_lat, hasta_lon, hasta_lat)
--   3. Polígono: la concatenación de los tramos, cerrada en la esquina 1, es el poligono_geojson
--      que recibe guardar_zona() (0008, 0024). Sin esta función el panel tendría que pedir un
--      tramo por esquina y pegarlos él: la geometría es del backend (ADR-018), así que la pega la
--      base y devuelve junto con las esquinas ya enganchadas, listas para p_vertices.
--        → public.poligono_por_calles(campania_ciudad, esquinas)
--   +  Las calles: schema `ruteo` (red, nodo, tramo) y `ruteo.cargar_red()`, que reemplaza en una
--      sola transacción la red de una ciudad con el JSON de OSM (formato de Overpass). El script
--      scripts/db-importar-calles.sh la llama; docs/calles-ruteo.md explica cómo conseguir el
--      archivo y cómo se actualiza la red.
--
-- `guardar_zona()` NO cambia: sigue recibiendo el polígono de una zona ESQUINAS ya calculado y lo
-- valida (forma válida, el borde pasa a 1 m o menos de cada esquina). Lo que arma poligono_por_calles
-- pasa esa validación porque el borde recorre exactamente los cruces.
--
-- ## Dónde viven las calles y por qué
--
-- En un schema propio, `ruteo`, que NO está en la API (config.toml, [api] schemas) ni tiene grants
-- para anon ni authenticated: son datos de referencia derivados de OSM (ODbL), no una entidad del
-- dominio, no viajan al teléfono (no están en sync.entidad) y no llevan las columnas de auditoría
-- de las tablas de public (cientos de miles de filas que se reemplazan enteras al reimportar). Las
-- RPC de public (SECURITY DEFINER) son la única puerta. Las tablas tienen RLS activada y ninguna
-- política, además de no tener grants: si alguien abre un grant por error, la RLS lo sigue cerrando.
--
--   ruteo.red    una fila por ciudad con calles cargadas: cuándo, de qué fuente, cuántos nodos,
--                cruces y tramos. Es lo que las RPC miran para decir «todavía no hay calles» (CZ015).
--   ruteo.nodo   un nodo de la red: cada extremo de calle y cada punto donde se juntan dos vías de
--                OSM. `es_cruce` = se juntan al menos DOS CALLES DISTINTAS (distinto `name`; una vía
--                sin nombre cuenta como su propia calle). Dos vías con el mismo nombre que se unen
--                (la misma calle cortada en dos vías de OSM) NO son un cruce, pero sí un nodo: el
--                camino pasa por ahí. calle_a y calle_b son las dos primeras calles con nombre, en
--                orden por código de carácter (con 3 calles o más, las otras no se muestran); una esquina sin
--                nombres tiene los dos en null (ADR-018, riesgo de OSM en zonas rurales).
--   ruteo.tramo  una calle entre dos nodos consecutivos, con su geometría y su largo en metros. Los
--                sentidos de circulación (`oneway`) se ignoran: el costo es el mismo en los dos sentidos.
--
-- Qué vías entran: highway = trunk, primary, secondary, tertiary, unclassified, residential,
-- living_street, pedestrian o road (parámetro p_tipos de ruteo.cargar_red). No entran autopistas,
-- ramas, senderos, escaleras, ciclovías, caminos rurales ni `service` (pasajes de estacionamiento y
-- entradas de garaje fabrican cruces que no son esquinas). El script puede pasar otra lista.
--
-- ## Cómo se calcula (pgRouting 3.4, pgr_dijkstra, no dirigido)
--
-- Esquina: el índice GiST (distancia plana en grados, rápida pero deformada: un grado de longitud
-- mide menos metros que uno de latitud) da un primer candidato; su distancia en METROS (geography)
-- acota la búsqueda a un radio en grados que cubre a cualquier cruce más cerca que él, y entre todos
-- los que caen adentro (el índice también los encuentra) se elige el más cercano en metros. Un empate
-- se desempata por id. Tramo: pgr_dijkstra sobre
-- los tramos de la ciudad con costo = largo en metros y directed = false. Se busca primero dentro
-- del rectángulo de los dos puntos agrandado en max(1000 m, distancia entre ellos): como cualquier
-- camino que salga de ahí mide al menos el doble de ese margen, un resultado de hasta 2 × margen es
-- el más corto de toda la red; si es más largo, o no hay camino ahí, se busca de nuevo en toda la
-- ciudad. Así el viaje de cada clic del panel (ADR-018, «consecuencias») no lee la red entera y el
-- resultado es el mismo que con toda la red.
-- pgRouting 3.4 llama a sus funciones internas sin calificar, así que NO se puede llamar con
-- search_path vacío: lo hace ruteo.dijkstra(), una envoltura interna con search_path = extensions
-- (schema de Supabase que solo escriben los administradores) que solo ejecuta pgr_dijkstra.
--
-- ## Recargar las calles mientras alguien dibuja
--
-- ruteo.cargar_red() toma un advisory lock EXCLUSIVO por ciudad y public.ciudad_para_dibujar() uno
-- COMPARTIDO (la misma clave, después del permiso): una recarga espera a que terminen las llamadas en
-- curso y las llamadas nuevas esperan a que la recarga confirme. Sin esto, una llamada que engancha
-- las esquinas antes de la recarga y busca el camino después (los ids de nodo cambian al recargar)
-- daría un CZ016 falso, «no hay camino entre «<NULL>» y «<NULL>»».
--
-- ## Modelo de permisos
--
--   · Las tres RPC se llaman con el JWT del usuario y el permiso es lo PRIMERO, el mismo que
--     guardar_zona() (la vista 24 las usa para dibujar lo que después se guarda): sin JWT → 42501;
--     sin el rol COORDINADOR ni ADMIN → 42501; la ciudad de la campaña tiene que existir y estar
--     viva (CZ012, antes del permiso sobre la campaña, igual que guardar_zona()); la campaña la
--     coordina quien llama o es ADMIN, y no terminó (motivo_mapa_de_campania(): 42501 / CZ001 /
--     CZ011). Una campaña por empezar SÍ: la vista 24 prepara el mapa antes del inicio.
--   · Son SECURITY DEFINER con search_path vacío: leen ruteo.*, que ningún cliente puede leer.
--     Devuelven solo posiciones y nombres de calles (datos públicos de OSM): ni personas, ni
--     ubicaciones, ni zonas de nadie.
--   · EXECUTE solo para `authenticated` (con service_role sin JWT fallarían con 42501 igual).
--     La comprobación común, public.ciudad_para_dibujar(), es interna: solo service_role.
--   · ruteo.cargar_red() es SECURITY INVOKER y solo service_role (o el dueño, que es quien corre el
--     script con la cadena de conexión) la ejecuta; ruteo.* no tiene EXECUTE para nadie más.
--   · Tope de esquinas: poligono_por_calles() acepta hasta 100 (una zona real tiene entre 4 y 12);
--     cada esquina es una búsqueda de camino y el tope evita que un cliente pida miles de una vez.
--
-- ## Códigos de rechazo (los traduce la fuente de datos del panel, ADR-013)
--
--   42501  sin sesión, sin el rol, o la campaña es de otro coordinador (y existe)
--   CZ001  la campaña no existe (o está dada de baja)          [lanzar_motivo_mapa]
--   CZ011  la campaña ya terminó                                [lanzar_motivo_mapa]
--   CZ012  la ciudad no está en esta campaña (o está de baja)   [lanzar_motivo_mapa]
--   CZ008  datos no válidos: punto fuera del mapa o sin lon/lat, menos de 3 esquinas (o menos de 3
--          en lugares distintos), más de 100, o un borde por las calles que se cruza o vuelve sobre
--          sí mismo (el mismo código y la misma idea que guardar_zona())
--   CZ015  (nuevo) la ciudad todavía no tiene calles cargadas, o las cargadas no tienen ningún cruce
--   CZ016  (nuevo) no hay camino por las calles entre dos esquinas: están en partes de la red que no
--          se tocan (un barrio aislado, una isla, un dato de OSM sin conectar)
--
-- ## Para otros repos
--
--   · front-coordinadores-web#40 (fuente de datos de la vista 24, esquinaMasCercana() y
--     tramoPorCalles()): por PostgREST es POST /rest/v1/rpc/<función>, parámetros por nombre, JWT
--     del coordinador; las tres son VOLATILE (llaman a lanzar_motivo_mapa()) y supabase-js las manda
--     por POST. El `ciudadId` del contrato del panel es el `campania_ciudad_id` de la pestaña. La
--     forma de cada respuesta está en docs/calles-ruteo.md.
--   · `distancia_m` de esquina_mas_cercana() es lo lejos que quedó el cruce del punto: sin tope, el
--     panel decide si un cruce a 800 m sigue siendo «la esquina de al lado» (decidido el 16/10: sin tope;
--     el coordinador ve en el mapa dónde se enganchó la esquina antes de agregarla).
--   · El aviso «Comparte la calle Heredia con Belvedere» (vista 24) NO sale de estas funciones: hace
--     falta comparar el borde nuevo con el de las otras zonas de la ciudad. Decidido el 16/10: va a
--     la vista previa de guardar_zona(), en un issue de seguimiento del backend (ver el PR).
--   · No tocan el sync: no hay entidad nueva ni cambia ninguna firma que use la app móvil.
--   · docs-organizacion: esquema-datos.md no menciona el schema `ruteo` (datos de referencia que no
--     son una entidad del dominio); ADR-018 ya dice «guardar esa red en la base, con su tamaño».
--
-- Forward-only: esta migración no se edita una vez aplicada.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. pgRouting y el schema de las calles
-- ----------------------------------------------------------------------------

-- Misma convención que PostGIS (0008): en `extensions`, como recomienda Supabase.
create extension if not exists pgrouting with schema extensions;

create schema ruteo;

comment on schema ruteo is
  'Las calles de OpenStreetMap por ciudad (datos de referencia, ODbL) y el ruteo sobre ellas '
  '(backend-supabase#25, ADR-018). Fuera de la API y sin grants para anon ni authenticated: se '
  'consulta solo por las RPC de public (esquina_mas_cercana, tramo_por_calles, poligono_por_calles).';

revoke all on schema ruteo from public, anon, authenticated;
grant usage on schema ruteo to service_role;

-- ----------------------------------------------------------------------------
-- 2. Tablas
-- ----------------------------------------------------------------------------

create table ruteo.red (
  ciudad_id  uuid primary key references public.ciudad(id),
  cargada_en timestamptz not null default now(),
  fuente     text,
  vias       integer not null check (vias >= 0),
  nodos      integer not null check (nodos >= 0),
  cruces     integer not null check (cruces >= 0),
  tramos     integer not null check (tramos >= 0)
);

comment on table ruteo.red is
  'Una fila por ciudad con calles cargadas (ruteo.cargar_red): cuándo, de qué fuente y cuántas vías '
  'de OSM, nodos, cruces y tramos. Las RPC de ruteo piden que exista (CZ015).';

create table ruteo.nodo (
  id        bigint generated always as identity primary key,
  ciudad_id uuid not null references public.ciudad(id),
  osm_id    bigint not null,
  geom      extensions.geometry(Point, 4326) not null,
  es_cruce  boolean not null,
  calle_a   text,
  calle_b   text,
  constraint nodo_ciudad_osm_uk unique (ciudad_id, osm_id),
  constraint nodo_calle_b_necesita_calle_a_check check (calle_b is null or calle_a is not null)
);

comment on table ruteo.nodo is
  'Nodo de la red de calles: extremo de una calle o punto donde se juntan dos vías de OSM. Es un cruce '
  '(es_cruce) si se juntan al menos dos calles distintas; calle_a y calle_b son las dos primeras con '
  'nombre, en orden por código de carácter (collate "C").';
comment on column ruteo.nodo.osm_id is 'Id del nodo en OpenStreetMap (informativo; único por ciudad).';

-- Solo los cruces: es lo que busca esquina_mas_cercana() por vecino más cercano (KNN).
create index nodo_cruce_geom_gix on ruteo.nodo using gist (geom) where es_cruce;

create table ruteo.tramo (
  id         bigint generated always as identity primary key,
  ciudad_id  uuid not null references public.ciudad(id),
  via_osm_id bigint not null,
  nombre     text,
  tipo       text not null,
  origen     bigint not null references ruteo.nodo(id),
  destino    bigint not null references ruteo.nodo(id),
  largo_m    double precision not null check (largo_m >= 0),
  geom       extensions.geometry(LineString, 4326) not null
);

comment on table ruteo.tramo is
  'Tramo de calle entre dos nodos consecutivos de una vía de OSM, con su geometría (de origen a '
  'destino) y su largo en metros. El ruteo ignora el sentido de circulación.';

create index tramo_geom_gix    on ruteo.tramo using gist (geom);
create index tramo_ciudad_idx  on ruteo.tramo (ciudad_id);
-- Las dos de abajo las usa la FK al borrar nodos (reimportar una ciudad), no las consultas.
create index tramo_origen_idx  on ruteo.tramo (origen);
create index tramo_destino_idx on ruteo.tramo (destino);

-- RLS activada y sin políticas, además de sin grants: la RLS es la autoridad (ADR-012) y acá no
-- hay ninguna lectura directa que permitir; todo pasa por las RPC de public.
alter table ruteo.red   enable row level security;
alter table ruteo.nodo  enable row level security;
alter table ruteo.tramo enable row level security;

revoke all on all tables    in schema ruteo from public, anon, authenticated;
revoke all on all sequences in schema ruteo from public, anon, authenticated;
grant all on all tables    in schema ruteo to service_role;
grant usage, select on all sequences in schema ruteo to service_role;

-- ----------------------------------------------------------------------------
-- 3. Cargar las calles de una ciudad
-- ----------------------------------------------------------------------------

-- Reemplaza TODA la red de la ciudad por la del JSON, en una sola transacción: o queda la red
-- nueva o queda la vieja (si el archivo no trae ninguna calle utilizable, falla y no toca nada).
-- Las zonas ya guardadas no cambian: guardan su polígono y sus esquinas, no apuntan a la red.
--
-- p_osm: lo que devuelve Overpass con `[out:json]; way["highway"](bbox); out body geom;`:
--   {"elements": [{"type":"way", "id":…, "nodes":[ids de nodo…], "geometry":[{"lat":…,"lon":…}…],
--                  "tags":{"highway":"residential","name":"…"}}, …]}
-- `nodes` y `geometry` van en el mismo orden y tienen que tener el mismo largo; una vía con otro
-- largo, con menos de 2 puntos o con un punto sin coordenadas se descarta entera (no se inventa
-- nada). Cada vía se parte en los nodos donde toca a otra vía o a sí misma y en sus dos extremos:
-- cada pedazo es un tramo. Devuelve un resumen (jsonb) con lo que cargó.
create function ruteo.cargar_red(
  p_ciudad_id uuid,
  p_osm       jsonb,
  p_fuente    text default null,
  p_tipos     text[] default array['trunk', 'primary', 'secondary', 'tertiary', 'unclassified',
                                   'residential', 'living_street', 'pedestrian', 'road']
)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_vias_en_archivo integer;
  v_vias            integer;
  v_nodos           integer;
  v_cruces          integer;
  v_tramos          integer;
begin
  perform pg_advisory_xact_lock(hashtextextended('ruteo_red:' || coalesce(p_ciudad_id::text, ''), 0));

  if p_ciudad_id is null
     or not exists (select 1 from public.ciudad c where c.id = p_ciudad_id and c.deleted_at is null) then
    raise exception 'La ciudad % no existe en el catálogo o está dada de baja. Cargala primero (docs/guia-carga-manual.md) y volvé a importar.',
        p_ciudad_id
      using errcode = 'invalid_parameter_value';
  end if;
  if p_osm is null or jsonb_typeof(p_osm -> 'elements') is distinct from 'array' then
    raise exception 'El archivo no es una respuesta de Overpass: falta la lista «elements». Descargalo con [out:json] y «out body geom;» (docs/calles-ruteo.md).'
      using errcode = 'invalid_parameter_value';
  end if;
  if p_tipos is null or cardinality(p_tipos) = 0 then
    raise exception 'Falta la lista de tipos de calle (highway) que entran en la red.'
      using errcode = 'invalid_parameter_value';
  end if;

  select count(*)::integer into v_vias_en_archivo
    from jsonb_array_elements(p_osm -> 'elements') e
   where e ->> 'type' = 'way';

  -- Reemplazo: primero los tramos (FK a los nodos), después los nodos.
  delete from ruteo.tramo t where t.ciudad_id = p_ciudad_id;
  delete from ruteo.nodo n where n.ciudad_id = p_ciudad_id;

  with
  vias as (
    select distinct on ((e ->> 'id')::bigint)
           (e ->> 'id')::bigint                         as via_id,
           nullif(btrim(e #>> '{tags,name}'), '')       as nombre,
           e #>> '{tags,highway}'                       as tipo,
           e -> 'nodes'                                 as nodos,
           e -> 'geometry'                              as geom
      from jsonb_array_elements(p_osm -> 'elements') e
     where e ->> 'type' = 'way'
       and (e #>> '{tags,highway}') = any (p_tipos)
       and jsonb_typeof(e -> 'nodes') = 'array'
       and jsonb_typeof(e -> 'geometry') = 'array'
       and jsonb_array_length(e -> 'nodes') >= 2
       and jsonb_array_length(e -> 'nodes') = jsonb_array_length(e -> 'geometry')
     order by (e ->> 'id')::bigint
  ),
  puntos as (
    select v.via_id, v.nombre, v.tipo, g.ord,
           (v.nodos ->> (g.ord::integer - 1))::bigint          as osm_nodo,
           case when jsonb_typeof(g.punto) = 'object' then (g.punto ->> 'lon')::double precision end as lon,
           case when jsonb_typeof(g.punto) = 'object' then (g.punto ->> 'lat')::double precision end as lat
      from vias v
      cross join lateral jsonb_array_elements(v.geom) with ordinality g(punto, ord)
  ),
  -- Una vía con un punto sin coordenadas o fuera del mapa se descarta entera.
  invalidas as (
    select distinct p.via_id
      from puntos p
     where p.lon is null or p.lat is null
        or p.lon not between -180 and 180 or p.lat not between -90 and 90
  ),
  -- Sin el mismo nodo dos veces seguidas (un dato malo de OSM): fabricaría un tramo de largo 0.
  validos as (
    select q.via_id, q.nombre, q.tipo, q.ord, q.osm_nodo, q.lon, q.lat
      from (
        select p.*, lag(p.osm_nodo) over (partition by p.via_id order by p.ord) as previo
          from puntos p
         where not exists (select 1 from invalidas i where i.via_id = p.via_id)
      ) q
     where q.previo is distinct from q.osm_nodo
  ),
  extremos as (
    select v.via_id, min(v.ord) as primero, max(v.ord) as ultimo
      from validos v
     group by v.via_id
  ),
  uso as (
    select v.osm_nodo,
           count(*)                                                       as apariciones,
           count(distinct coalesce(v.nombre, 'osm:' || v.via_id::text))   as calles,
           array_agg(distinct v.nombre collate "C") filter (where v.nombre is not null) as nombres
      from validos v
     group by v.osm_nodo
  ),
  -- Se corta la vía en sus dos extremos y en cada nodo que aparece más de una vez (otra vía, o la
  -- misma que se toca): ahí empieza y termina un tramo.
  marcados as (
    select v.*, (v.ord in (x.primero, x.ultimo) or u.apariciones >= 2) as es_corte
      from validos v
      join extremos x on x.via_id = v.via_id
      join uso u on u.osm_nodo = v.osm_nodo
  ),
  con_tramo as (
    select m.*,
           max(case when m.es_corte then m.ord end)
             over (partition by m.via_id order by m.ord)                              as tramo_ini,
           max(case when m.es_corte then m.ord end)
             over (partition by m.via_id order by m.ord rows between unbounded preceding and 1 preceding) as tramo_prev
      from marcados m
  ),
  -- Cada punto va en el tramo que empieza en el último corte; el corte siguiente lo cierra, así que
  -- también va como último punto del tramo anterior.
  piezas as (
    select c.via_id, c.tramo_ini as tramo, c.ord, c.osm_nodo, c.lon, c.lat, c.nombre, c.tipo
      from con_tramo c
    union all
    select c.via_id, c.tramo_prev, c.ord, c.osm_nodo, c.lon, c.lat, c.nombre, c.tipo
      from con_tramo c
     where c.es_corte and c.tramo_prev is not null
  ),
  tramos as (
    select p.via_id, p.tramo,
           min(p.nombre)                                         as nombre,
           min(p.tipo)                                           as tipo,
           (array_agg(p.osm_nodo order by p.ord))[1]             as origen_osm,
           (array_agg(p.osm_nodo order by p.ord desc))[1]        as destino_osm,
           extensions.st_setsrid(
             extensions.st_makeline(extensions.st_makepoint(p.lon, p.lat) order by p.ord), 4326) as geom
      from piezas p
     group by p.via_id, p.tramo
    having count(*) >= 2
  ),
  nodos_nuevos as (
    insert into ruteo.nodo (ciudad_id, osm_id, geom, es_cruce, calle_a, calle_b)
    select p_ciudad_id, n.osm_nodo,
           extensions.st_setsrid(extensions.st_makepoint(n.lon, n.lat), 4326),
           u.calles >= 2, u.nombres[1], u.nombres[2]
      from (select distinct on (m.osm_nodo) m.osm_nodo, m.lon, m.lat
              from marcados m
             where m.es_corte
             order by m.osm_nodo, m.via_id, m.ord) n
      join uso u on u.osm_nodo = n.osm_nodo
    returning id, osm_id
  )
  insert into ruteo.tramo (ciudad_id, via_osm_id, nombre, tipo, origen, destino, largo_m, geom)
  select p_ciudad_id, t.via_id, t.nombre, t.tipo, o.id, d.id,
         extensions.st_length(extensions.geography(t.geom)), t.geom
    from tramos t
    join nodos_nuevos o on o.osm_id = t.origen_osm
    join nodos_nuevos d on d.osm_id = t.destino_osm;

  select count(*)::integer, (count(*) filter (where n.es_cruce))::integer
    into v_nodos, v_cruces
    from ruteo.nodo n
   where n.ciudad_id = p_ciudad_id;
  select count(*)::integer, count(distinct t.via_osm_id)::integer
    into v_tramos, v_vias
    from ruteo.tramo t
   where t.ciudad_id = p_ciudad_id;

  -- Falla ANTES de dejar la ciudad sin calles: la transacción deshace el reemplazo.
  if v_tramos = 0 then
    raise exception 'El archivo no trae ninguna calle utilizable (vías de tipo %). No se cambió nada.',
        array_to_string(p_tipos, ', ')
      using errcode = 'invalid_parameter_value';
  end if;
  if v_cruces = 0 then
    raise exception 'Las calles del archivo no tienen ningún cruce (dos calles con nombres distintos que se junten en un nodo). No se cambió nada.'
      using errcode = 'invalid_parameter_value';
  end if;

  insert into ruteo.red (ciudad_id, fuente, vias, nodos, cruces, tramos)
  values (p_ciudad_id, p_fuente, v_vias, v_nodos, v_cruces, v_tramos)
  on conflict (ciudad_id) do update
     set cargada_en = now(), fuente = excluded.fuente, vias = excluded.vias, nodos = excluded.nodos,
         cruces = excluded.cruces, tramos = excluded.tramos;

  return jsonb_build_object(
    'ciudad_id', p_ciudad_id,
    'vias_en_archivo', v_vias_en_archivo,
    'vias', v_vias,
    'vias_descartadas', v_vias_en_archivo - v_vias,
    'nodos', v_nodos,
    'cruces', v_cruces,
    'tramos', v_tramos);
end;
$$;

comment on function ruteo.cargar_red(uuid, jsonb, text, text[]) is
  'Reemplaza en una transacción la red de calles de una ciudad con el JSON de Overpass (way con nodes, '
  'geometry y tags). Parte cada vía en sus cruces y extremos; es_cruce = al menos dos calles distintas. '
  'Falla sin tocar nada si no hay ninguna calle utilizable. Devuelve un resumen. Solo service_role.';

-- ----------------------------------------------------------------------------
-- 4. Ayudas internas del ruteo
-- ----------------------------------------------------------------------------

-- La esquina en palabras, para los avisos: «Pororó y Heredia», «Heredia» o «una esquina sin nombre».
create function ruteo.nombre_de_esquina(p_calle_a text, p_calle_b text)
returns text
language sql
immutable
set search_path = ''
as $$
  select case
           when p_calle_a is not null and p_calle_b is not null then p_calle_a || ' y ' || p_calle_b
           else coalesce(p_calle_a, p_calle_b, 'una esquina sin nombre')
         end;
$$;

-- Un punto válido del mapa (lon entre -180 y 180, lat entre -90 y 90; null y NaN no valen).
create function ruteo.exigir_punto(p_lon double precision, p_lat double precision)
returns void
language plpgsql
immutable
set search_path = ''
as $$
begin
  if p_lon is null or p_lat is null
     or not (p_lon between -180 and 180) or not (p_lat between -90 and 90) then
    raise exception 'El punto no está en el mapa (hace falta una longitud entre -180 y 180 y una latitud entre -90 y 90). Marcalo de nuevo.'
      using errcode = 'CZ008';
  end if;
end;
$$;

-- El cruce de calles más cercano de la ciudad a un punto, en metros (geography). El índice GiST
-- (distancia plana en grados, que deforma: un grado de longitud mide menos metros que uno de
-- latitud) da el primer candidato y su distancia en metros acota la búsqueda: cualquier cruce a esa
-- distancia o menos está a menos de `grados` del punto (un grado de latitud mide al menos 110 574 m
-- y uno de longitud 111 320 m × cos de la latitud más lejana; 5 % de aire). De todos los que caen
-- adentro (st_dwithin también usa el índice) gana el más cercano en metros; el empate lo desempata
-- el id. Ninguna fila si la ciudad no tiene cruces.
create function ruteo.cruce_mas_cercano(p_ciudad_id uuid, p_lon double precision, p_lat double precision)
returns table (nodo_id bigint, lon double precision, lat double precision,
               calle_a text, calle_b text, distancia_m double precision)
language sql
stable
set search_path = ''
as $$
  with punto as (
    select extensions.st_setsrid(extensions.st_makepoint(p_lon, p_lat), 4326) as g
  ),
  primero as (
    select extensions.st_distance(extensions.geography(c.geom), extensions.geography(punto.g)) as d
      from punto,
           lateral (
             select n.geom
               from ruteo.nodo n
              where n.ciudad_id = p_ciudad_id
                and n.es_cruce
              order by n.geom operator(extensions.<->) punto.g
              limit 1
           ) c
  ),
  radio as (
    select punto.g,
           primero.d * 1.05
             / least(110574.0,
                     111320.0 * cos(radians(least(abs(p_lat) + primero.d / 110574.0, 89.0)))) as grados
      from punto, primero
  )
  select n.id,
         extensions.st_x(n.geom),
         extensions.st_y(n.geom),
         n.calle_a,
         n.calle_b,
         extensions.st_distance(extensions.geography(n.geom), extensions.geography(radio.g))
    from radio
    join ruteo.nodo n
      on n.ciudad_id = p_ciudad_id
     and n.es_cruce
     and extensions.st_dwithin(n.geom, radio.g, radio.grados)
   order by 6, n.id
   limit 1;
$$;

-- pgr_dijkstra no dirigido sobre el SQL de aristas que se le pase (interna: el texto lo arma
-- ruteo.camino() solo con números y el id de la ciudad, nunca con texto de un cliente). Aparte de
-- las demás porque pgRouting 3.4 necesita `extensions` en el search_path; ver la cabecera.
create function ruteo.dijkstra(p_aristas text, p_a bigint, p_b bigint)
returns table (path_seq integer, node bigint, edge bigint, agg_cost double precision)
language sql
set search_path = extensions
as $$
  select r.path_seq, r.node, r.edge, r.agg_cost
    from pgr_dijkstra(p_aristas, p_a, p_b, false) r;
$$;

-- El camino más corto por las calles entre dos nodos de la ciudad, como LineString orientado de
-- p_a a p_b, y su largo en metros. Ninguna fila si no hay camino. p_a y p_b tienen que ser
-- distintos (el que llama resuelve el caso de la misma esquina).
-- Búsqueda acotada + prueba de que es la más corta: ver la cabecera ("Cómo se calcula").
create function ruteo.camino(p_ciudad_id uuid, p_a bigint, p_b bigint)
returns table (geom extensions.geometry, largo_m double precision)
language plpgsql
volatile
set search_path = ''
as $$
#variable_conflict use_column
declare
  c_margen_minimo constant double precision := 1000;   -- metros
  v_ga       extensions.geometry;
  v_gb       extensions.geometry;
  v_margen   double precision;   -- el margen que vale la prueba (m)
  v_dlat     double precision;   -- el mismo margen, 5 % más, en grados
  v_dlon     double precision;
  v_aristas  text;
  v_n        integer;
  v_largo    double precision;
  v_linea    extensions.geometry;
begin
  select n.geom into v_ga from ruteo.nodo n where n.id = p_a and n.ciudad_id = p_ciudad_id;
  select n.geom into v_gb from ruteo.nodo n where n.id = p_b and n.ciudad_id = p_ciudad_id;
  if v_ga is null or v_gb is null then
    return;
  end if;

  v_margen := greatest(c_margen_minimo,
                       extensions.st_distance(extensions.geography(v_ga), extensions.geography(v_gb)));
  -- Un grado de latitud mide al menos 110 574 m y uno de longitud 111 320 m × cos(latitud); el 5 %
  -- de más cubre que la latitud cambie dentro del rectángulo.
  v_dlat := v_margen * 1.05 / 110574.0;
  v_dlon := v_margen * 1.05 / (111320.0 * greatest(cos(radians(abs((extensions.st_y(v_ga) + extensions.st_y(v_gb)) / 2))), 0.01));

  for v_pasada in 1..2 loop
    v_aristas := format(
      'select t.id, t.origen as source, t.destino as target, t.largo_m as cost '
      'from ruteo.tramo t where t.ciudad_id = %L%s',
      p_ciudad_id,
      case when v_pasada = 1 then
        format(' and t.geom && extensions.st_makeenvelope(%s, %s, %s, %s, 4326)',
               least(extensions.st_x(v_ga), extensions.st_x(v_gb)) - v_dlon,
               least(extensions.st_y(v_ga), extensions.st_y(v_gb)) - v_dlat,
               greatest(extensions.st_x(v_ga), extensions.st_x(v_gb)) + v_dlon,
               greatest(extensions.st_y(v_ga), extensions.st_y(v_gb)) + v_dlat)
      else '' end);

    with r as materialized (
      select d.path_seq, d.node, d.edge, d.agg_cost from ruteo.dijkstra(v_aristas, p_a, p_b) d
    )
    select (select count(*) from r)::integer,
           (select max(r.agg_cost) from r),
           (select extensions.st_removerepeatedpoints(extensions.st_makeline(
                     case when t.origen = r.node then t.geom else extensions.st_reverse(t.geom) end
                     order by r.path_seq))
              from r join ruteo.tramo t on t.id = r.edge)
      into v_n, v_largo, v_linea;

    -- En la primera pasada el resultado vale solo si mide hasta el doble del margen (todo camino que
    -- sale del rectángulo mide más); en la segunda (toda la ciudad) vale siempre.
    if v_n > 0 and (v_pasada = 2 or v_largo <= 2 * v_margen) then
      geom := v_linea;
      largo_m := v_largo;
      return next;
      return;
    end if;
  end loop;
end;
$$;

comment on function ruteo.camino(uuid, bigint, bigint) is
  'Camino más corto por las calles (sin sentidos) entre dos nodos de la ciudad: LineString de p_a a p_b '
  'y largo en metros; ninguna fila si no hay camino. Busca primero en el rectángulo de los dos puntos '
  'más max(1000 m, distancia) y, si el resultado mide más del doble de ese margen o no hay, en toda la ciudad.';

-- ----------------------------------------------------------------------------
-- 5. El permiso, una sola vez (interna)
-- ----------------------------------------------------------------------------

-- Lanza el error que corresponda si el usuario autenticado no puede dibujar el mapa de esta ciudad
-- de la campaña, y si puede devuelve la ciudad del catálogo (la que tiene las calles). Mismo
-- permiso, mismo orden y mismos códigos que guardar_zona() (0008, 0024). Después del permiso, que
-- la ciudad tenga calles cargadas (CZ015).
create function public.ciudad_para_dibujar(p_campania_ciudad_id uuid)
returns uuid
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_cc public.campania_ciudad;
begin
  if auth.uid() is null then
    raise exception 'Hace falta iniciar sesión. Entrá con tu cuenta de coordinador.'
      using errcode = 'insufficient_privilege';
  end if;

  -- El permiso primero: sin rol de staff, 42501 antes de mirar ningún dato.
  if not (public.tiene_rol('ADMIN') or public.tiene_rol('COORDINADOR')) then
    perform public.lanzar_motivo_mapa('SIN_PERMISO');
  end if;

  select * into v_cc from public.campania_ciudad cc where cc.id = p_campania_ciudad_id;
  if not found then
    perform public.lanzar_motivo_mapa('CIUDAD_FUERA_DE_CAMPANIA');
  end if;
  perform public.lanzar_motivo_mapa(public.motivo_mapa_de_campania(v_cc.campania_id));
  if v_cc.deleted_at is not null then
    perform public.lanzar_motivo_mapa('CIUDAD_FUERA_DE_CAMPANIA');
  end if;

  -- Una recarga de las calles en curso (cargar_red(), lock exclusivo) se espera; y mientras dura
  -- esta llamada, una recarga espera a que termine: los ids de nodo no cambian a mitad de camino.
  perform pg_advisory_xact_lock_shared(hashtextextended('ruteo_red:' || v_cc.ciudad_id::text, 0));

  if not exists (select 1 from ruteo.red r where r.ciudad_id = v_cc.ciudad_id) then
    raise exception 'Todavía no están cargadas las calles de esta ciudad. Pedile a un administrador que las cargue y volvé a intentar.'
      using errcode = 'CZ015';
  end if;

  return v_cc.ciudad_id;
end;
$$;

comment on function public.ciudad_para_dibujar(uuid) is
  'Interna (0036): 42501 si no hay sesión o el usuario no es ADMIN ni el coordinador de la campaña; '
  'CZ012 si la ciudad no está viva en la campaña; CZ001 / CZ011 como guardar_zona(); CZ015 si la ciudad '
  'no tiene calles cargadas. Devuelve la ciudad del catálogo.';

-- ----------------------------------------------------------------------------
-- 6. Las RPC del panel (vista 24)
-- ----------------------------------------------------------------------------

-- Al pasar por el mapa: «Pororó y Heredia · clic para agregar». Una fila: el cruce de calles OSM
-- más cercano al punto, sus coordenadas, los nombres de las dos calles (null si la calle no tiene
-- nombre en OSM) y a cuántos metros del punto queda. No hay tope de distancia: dice la más cercana
-- de la ciudad y `distancia_m` deja al panel decidir si le sirve.
create function public.esquina_mas_cercana(
  p_campania_ciudad_id uuid,
  p_lon                double precision,
  p_lat                double precision
)
returns table (lon double precision, lat double precision, calle_a text, calle_b text,
               distancia_m double precision)
language plpgsql
security definer
set search_path = ''
as $$
#variable_conflict use_column
declare
  v_ciudad uuid;
  v_c      record;
begin
  v_ciudad := public.ciudad_para_dibujar(p_campania_ciudad_id);
  perform ruteo.exigir_punto(p_lon, p_lat);

  select * into v_c from ruteo.cruce_mas_cercano(v_ciudad, p_lon, p_lat);
  if not found then
    raise exception 'Las calles cargadas de esta ciudad no tienen ningún cruce. Pedile a un administrador que las vuelva a cargar.'
      using errcode = 'CZ015';
  end if;

  return query
    select v_c.lon, v_c.lat, v_c.calle_a, v_c.calle_b, round(v_c.distancia_m::numeric, 1)::double precision;
end;
$$;

comment on function public.esquina_mas_cercana(uuid, double precision, double precision) is
  'Vista 24: el cruce de calles OSM más cercano a un punto (lon, lat, calle_a, calle_b, distancia_m). '
  'Errores: 42501; CZ001, CZ011, CZ012; CZ008 (punto no válido); CZ015 (sin calles).';

-- Entre dos esquinas el borde sigue la calle. Los dos puntos se enganchan al cruce más cercano (una
-- esquina ya enganchada se engancha a sí misma) y la respuesta es el recorrido más corto por las
-- calles, sin sentidos de circulación: los puntos en orden, de `desde` a `hasta`, empezando y
-- terminando en los cruces. Si los dos puntos caen en el mismo cruce, un solo punto.
create function public.tramo_por_calles(
  p_campania_ciudad_id uuid,
  p_desde_lon          double precision,
  p_desde_lat          double precision,
  p_hasta_lon          double precision,
  p_hasta_lat          double precision
)
returns table (orden integer, lon double precision, lat double precision)
language plpgsql
security definer
set search_path = ''
as $$
#variable_conflict use_column
declare
  v_ciudad uuid;
  v_a      record;
  v_b      record;
  v_camino record;
begin
  v_ciudad := public.ciudad_para_dibujar(p_campania_ciudad_id);
  perform ruteo.exigir_punto(p_desde_lon, p_desde_lat);
  perform ruteo.exigir_punto(p_hasta_lon, p_hasta_lat);

  select * into v_a from ruteo.cruce_mas_cercano(v_ciudad, p_desde_lon, p_desde_lat);
  if not found then
    raise exception 'Las calles cargadas de esta ciudad no tienen ningún cruce. Pedile a un administrador que las vuelva a cargar.'
      using errcode = 'CZ015';
  end if;
  select * into v_b from ruteo.cruce_mas_cercano(v_ciudad, p_hasta_lon, p_hasta_lat);

  if v_a.nodo_id = v_b.nodo_id then
    return query select 1, v_a.lon, v_a.lat;
    return;
  end if;

  select * into v_camino from ruteo.camino(v_ciudad, v_a.nodo_id, v_b.nodo_id);
  if not found then
    raise exception 'No hay un camino por las calles entre «%» y «%». Elegí otra esquina que esté sobre la misma red de calles.',
        ruteo.nombre_de_esquina(v_a.calle_a, v_a.calle_b), ruteo.nombre_de_esquina(v_b.calle_a, v_b.calle_b)
      using errcode = 'CZ016';
  end if;

  return query
    select (d.path[1])::integer, extensions.st_x(d.geom), extensions.st_y(d.geom)
      from extensions.st_dumppoints(v_camino.geom) d
     order by d.path[1];
end;
$$;

comment on function public.tramo_por_calles(uuid, double precision, double precision, double precision, double precision) is
  'Vista 24: el recorrido más corto por las calles OSM (sin sentidos) entre los cruces más cercanos a '
  'dos puntos: (orden, lon, lat), de desde a hasta. Errores: 42501; CZ001, CZ011, CZ012; CZ008; CZ015; '
  'CZ016 (sin camino entre las dos esquinas).';

-- La zona por esquinas entera: p_esquinas es la lista, en el orden en que se marcaron, de
-- {"lon": …, "lat": …} (las claves de más se ignoran; sirve lo que devolvió esquina_mas_cercana()
-- o los clics sin enganchar). Cada una se engancha a su cruce; el borde es la concatenación de los
-- tramos de cada esquina a la siguiente y de la última a la primera (el polígono se cierra en la
-- esquina 1). Devuelve el poligono_geojson para guardar_zona() y las esquinas ya enganchadas, con
-- la forma de su p_vertices: [{"orden", "lon", "lat", "calle_a", "calle_b"}].
-- Una esquina repetida seguida (o la última igual a la primera) no agrega tramo. Si el recorrido no
-- es un borde válido (se cruza o vuelve sobre una calle), CZ008 con el motivo, como guardar_zona().
create function public.poligono_por_calles(p_campania_ciudad_id uuid, p_esquinas jsonb)
returns table (poligono_geojson jsonb, esquinas jsonb)
language plpgsql
security definer
set search_path = ''
as $$
#variable_conflict use_column
declare
  c_maximo constant integer := 100;
  v_ciudad   uuid;
  v_n        integer;
  v_e        jsonb;
  v_c        record;
  v_camino   record;
  v_nodos    bigint[] := array[]::bigint[];
  v_anillo   bigint[] := array[]::bigint[];
  v_esq      jsonb := '[]'::jsonb;
  v_lineas   extensions.geometry[] := array[]::extensions.geometry[];
  v_borde    extensions.geometry;
  v_json     jsonb;
  v_problema text;
  v_a        bigint;
  v_b        bigint;
begin
  v_ciudad := public.ciudad_para_dibujar(p_campania_ciudad_id);

  if p_esquinas is null or jsonb_typeof(p_esquinas) is distinct from 'array' then
    raise exception 'Las esquinas tienen que ser una lista de puntos con longitud y latitud. Volvé a marcarlas en el mapa.'
      using errcode = 'CZ008';
  end if;
  v_n := jsonb_array_length(p_esquinas);
  if v_n < 3 then
    raise exception 'Una zona por esquinas necesita al menos 3 esquinas (tiene %). Marcá más esquinas en el mapa.', v_n
      using errcode = 'CZ008';
  end if;
  if v_n > c_maximo then
    raise exception 'Una zona por esquinas puede tener hasta % esquinas y marcaste %. Dividí el área en varias zonas.', c_maximo, v_n
      using errcode = 'CZ008';
  end if;

  -- Cada esquina, enganchada a su cruce.
  for v_i in 1..v_n loop
    v_e := p_esquinas -> (v_i - 1);
    if jsonb_typeof(v_e) is distinct from 'object'
       or jsonb_typeof(v_e -> 'lon') is distinct from 'number'
       or jsonb_typeof(v_e -> 'lat') is distinct from 'number' then
      raise exception 'La esquina % no tiene longitud y latitud. Volvé a marcarla.', v_i
        using errcode = 'CZ008';
    end if;
    perform ruteo.exigir_punto((v_e ->> 'lon')::double precision, (v_e ->> 'lat')::double precision);

    select * into v_c from ruteo.cruce_mas_cercano(v_ciudad, (v_e ->> 'lon')::double precision,
                                                   (v_e ->> 'lat')::double precision);
    if not found then
      raise exception 'Las calles cargadas de esta ciudad no tienen ningún cruce. Pedile a un administrador que las vuelva a cargar.'
        using errcode = 'CZ015';
    end if;
    v_nodos := v_nodos || v_c.nodo_id;
    v_esq := v_esq || jsonb_build_array(jsonb_build_object(
      'orden', v_i, 'lon', v_c.lon, 'lat', v_c.lat, 'calle_a', v_c.calle_a, 'calle_b', v_c.calle_b));
  end loop;

  -- El anillo de cruces: sin repetidos seguidos y sin la vuelta a la primera al final.
  for v_i in 1..v_n loop
    if cardinality(v_anillo) = 0 or v_anillo[cardinality(v_anillo)] <> v_nodos[v_i] then
      v_anillo := v_anillo || v_nodos[v_i];
    end if;
  end loop;
  if cardinality(v_anillo) > 1 and v_anillo[1] = v_anillo[cardinality(v_anillo)] then
    v_anillo := v_anillo[1:cardinality(v_anillo) - 1];
  end if;
  if (select count(distinct x) from unnest(v_anillo) x) < 3 then
    raise exception 'Una zona por esquinas necesita al menos 3 esquinas en lugares distintos y hay %. Marcá las esquinas que faltan en el mapa.',
        (select count(distinct x) from unnest(v_anillo) x)
      using errcode = 'CZ008';
  end if;

  -- Un tramo por esquina, de cada una a la siguiente y de la última a la primera.
  for v_i in 1..cardinality(v_anillo) loop
    v_a := v_anillo[v_i];
    v_b := v_anillo[case when v_i = cardinality(v_anillo) then 1 else v_i + 1 end];
    select * into v_camino from ruteo.camino(v_ciudad, v_a, v_b);
    if not found then
      raise exception 'No hay un camino por las calles entre «%» y «%». Elegí otra esquina que esté sobre la misma red de calles.',
          (select ruteo.nombre_de_esquina(n.calle_a, n.calle_b) from ruteo.nodo n where n.id = v_a),
          (select ruteo.nombre_de_esquina(n.calle_a, n.calle_b) from ruteo.nodo n where n.id = v_b)
        using errcode = 'CZ016';
    end if;
    v_lineas := v_lineas || v_camino.geom;
  end loop;

  v_borde := extensions.st_removerepeatedpoints(extensions.st_makeline(v_lineas));
  if not extensions.st_isclosed(v_borde) or extensions.st_npoints(v_borde) < 4 then
    raise exception 'El borde por las calles no se cierra. Volvé a marcar las esquinas.'
      using errcode = 'CZ008';
  end if;

  v_json := extensions.st_asgeojson(extensions.st_makepolygon(v_borde), 7)::jsonb;
  v_problema := public.zona_problema_de_forma(v_json);
  if v_problema is not null then
    raise exception 'El borde por las calles no forma una zona: %. Mové o quitá una esquina para que el recorrido no se cruce ni vuelva sobre una calle.', v_problema
      using errcode = 'CZ008';
  end if;

  return query select v_json, v_esq;
end;
$$;

comment on function public.poligono_por_calles(uuid, jsonb) is
  'Vista 24: el polígono de una zona por esquinas (poligono_geojson para guardar_zona()) como la '
  'concatenación de los tramos por las calles, cerrada en la esquina 1, y las esquinas enganchadas '
  '(orden, lon, lat, calle_a, calle_b). De 3 a 100 esquinas. Errores: 42501; CZ001, CZ011, CZ012; '
  'CZ008 (esquinas o borde no válidos); CZ015; CZ016.';

-- ----------------------------------------------------------------------------
-- 7. Privilegios
-- ----------------------------------------------------------------------------

-- `authenticated` y `service_role` también en el revoke: en una base creada desde cero los default
-- privileges de la imagen de Supabase les dan EXECUTE sobre cada función nueva de public (ver 0008,
-- 0024 y 0033).
revoke all on function
  public.ciudad_para_dibujar(uuid),
  public.esquina_mas_cercana(uuid, double precision, double precision),
  public.tramo_por_calles(uuid, double precision, double precision, double precision, double precision),
  public.poligono_por_calles(uuid, jsonb)
  from public, anon, authenticated, service_role;

-- Las tres RPC que llama el panel (0033: solo authenticated; sin JWT fallan con 42501 igual).
grant execute on function
  public.esquina_mas_cercana(uuid, double precision, double precision),
  public.tramo_por_calles(uuid, double precision, double precision, double precision, double precision),
  public.poligono_por_calles(uuid, jsonb)
  to authenticated;

-- Interna: la llaman las tres RPC (que corren como el dueño); solo service_role además.
grant execute on function public.ciudad_para_dibujar(uuid) to service_role;

-- Todo lo de ruteo: nadie lo ejecuta salvo el dueño (que corre dentro de las RPC) y service_role.
revoke all on function
  ruteo.cargar_red(uuid, jsonb, text, text[]),
  ruteo.nombre_de_esquina(text, text),
  ruteo.exigir_punto(double precision, double precision),
  ruteo.cruce_mas_cercano(uuid, double precision, double precision),
  ruteo.dijkstra(text, bigint, bigint),
  ruteo.camino(uuid, bigint, bigint)
  from public, anon, authenticated;
grant execute on function
  ruteo.cargar_red(uuid, jsonb, text, text[]),
  ruteo.nombre_de_esquina(text, text),
  ruteo.exigir_punto(double precision, double precision),
  ruteo.cruce_mas_cercano(uuid, double precision, double precision),
  ruteo.dijkstra(text, bigint, bigint),
  ruteo.camino(uuid, bigint, bigint)
  to service_role;
