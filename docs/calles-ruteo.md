# Calles de OpenStreetMap y borde de las zonas por esquinas — HU-CAM-006 (vista 24), lado servidor

El borde de una zona dibujada **por esquinas** sigue las calles. Lo calcula la base con **pgRouting**, sobre las calles de
OpenStreetMap (OSM) de la ciudad guardadas en el schema `ruteo`, y el panel solo llama RPC (sin BFF,
[ADR-013](https://github.com/Colportores/docs-organizacion/blob/main/docs/decisiones/ADR-013-clientes-directo-a-rpc-de-supabase.md)).
Decisión de Cristian del 29/09 (pgRouting en el Postgres de Supabase), [ADR-018](https://github.com/Colportores/docs-organizacion/blob/main/docs/decisiones/ADR-018-geometria-de-zonas-y-ruteo-en-postgres.md).
Migración `0036`, backend-supabase#25.

Esta guía cubre: [qué hay en la base](#qué-hay-en-la-base), [cómo se cargan las calles de una ciudad](#cargar-las-calles-de-una-ciudad),
[las tres RPC](#las-tres-rpc-de-la-vista-24), [permisos y códigos](#permisos-y-códigos) y [límites](#límites-y-supuestos).

## Qué hay en la base

Un schema propio, `ruteo`, que **no está en la API** y no tiene permisos para `anon` ni `authenticated`: son datos de
referencia derivados de OSM, no una entidad del dominio. No viajan al teléfono (no están en `sync.entidad`) y no llevan las
columnas de auditoría de `public`. Las tablas tienen RLS activada y ninguna política, además de no tener grants; la única
puerta son las RPC de `public` (`SECURITY DEFINER`).

| Tabla | Qué es |
|---|---|
| `ruteo.red` | Una fila por ciudad con calles cargadas: cuándo (`cargada_en`), de dónde (`fuente`) y cuántas vías, nodos, cruces y tramos. Si no hay fila, las RPC contestan `CZ015` («todavía no están cargadas las calles»). |
| `ruteo.nodo` | Un punto de la red: cada extremo de calle y cada lugar donde se juntan dos vías de OSM. `es_cruce` = se juntan **al menos dos calles distintas**; `calle_a` y `calle_b` son las dos primeras con nombre, en orden por código de carácter (mayúsculas antes que minúsculas; el mismo en cualquier base). |
| `ruteo.tramo` | Una calle entre dos nodos consecutivos, con su geometría y su largo en metros. |

- **Qué es un cruce.** Dos calles con **nombres distintos** que se juntan en un nodo. Una vía sin nombre cuenta como su propia
  calle (dos vías sin nombre que se cruzan forman un cruce con `calle_a` y `calle_b` en `null`, que el panel muestra como «una
  esquina sin nombre»). La misma calle cortada en dos vías de OSM **no** es un cruce, pero sí un nodo por el que pasa el camino.
  Con tres calles o más en un nodo se muestran las dos primeras de ese orden.
- **Qué vías entran.** `highway` = `trunk`, `primary`, `secondary`, `tertiary`, `unclassified`, `residential`, `living_street`,
  `pedestrian` o `road`. No entran autopistas ni ramas (`motorway`, `*_link`), senderos, escaleras, ciclovías, caminos rurales
  (`track`) ni `service`: los pasajes de estacionamiento y las entradas de garaje fabrican cruces que no son esquinas. La lista
  es un parámetro de `ruteo.cargar_red()` por si hace falta otra.
- **Sentidos de circulación.** Se ignoran: el costo de un tramo es el mismo en los dos sentidos (el colportor camina).

## Cargar las calles de una ciudad

Las calles se cargan **una vez por ciudad** y se actualizan **reimportando**. El repo no descarga nada: recibe el archivo.

### 1. Conseguir el archivo

El formato que espera es el JSON de la API de Overpass con la geometría de las vías (`[out:json]` y `out body geom;`). Una consulta
de ejemplo, para el rectángulo de la ciudad (`sur,oeste,norte,este`, que `public.ciudad` guarda en `bbox_sur`, `bbox_oeste`,
`bbox_norte` y `bbox_este`):

```
[out:json][timeout:300];
way["highway"~"^(trunk|primary|secondary|tertiary|unclassified|residential|living_street|pedestrian|road)$"](-34.945,-56.433,-34.701,-55.948);
out body geom;
```

```sql
-- El rectángulo, listo para pegar en la consulta:
select bbox_sur || ',' || bbox_oeste || ',' || bbox_norte || ',' || bbox_este as bbox from public.ciudad where id = '<ciudad_id>';
```

Es solo la documentación del formato; cómo y desde dónde se baja lo decide quien opera. Si se usa un servidor público de Overpass:
es de uso compartido, hay que identificarse con un `User-Agent` propio y reintentar (a veces contesta `502`/`504` o rechaza por
carga). Un extracto de OSM procesado con otra herramienta sirve si termina siendo ese mismo JSON.

### 2. Importar

```bash
DB_URL=postgresql://… bash scripts/db-importar-calles.sh <ciudad_id> calles-montevideo.json "Overpass 2026-10-16"
```

- `<ciudad_id>` es el `id` de la fila de `public.ciudad` (la ciudad tiene que estar cargada en el catálogo antes;
  ver [`guia-carga-manual.md`](guia-carga-manual.md)). **No** es el `campania_ciudad_id`.
- El tercer argumento es una nota libre sobre el origen (queda en `ruteo.red.fuente`); por omisión, el nombre del archivo y la fecha.
- Lo hace `ruteo.cargar_red()`, **en una sola transacción**: reemplaza la red entera de la ciudad, o falla y deja la que había.
  Falla, sin tocar nada, si el archivo no es de Overpass, no trae ninguna calle utilizable o las calles no tienen ningún cruce.
  Devuelve un resumen: vías en el archivo, vías cargadas y descartadas, nodos, cruces y tramos.
- Una vía se **descarta entera** si le falta un punto, si `nodes` y `geometry` no tienen el mismo largo o si trae menos de 2
  puntos (no se inventa nada). El resumen cuenta cuántas.
- Contra la nube, usar la cadena de conexión **directa** del proyecto (puerto 5432), no el pooler en modo transacción: una ciudad
  grande tarda más que el tiempo que permite el pooler.
- **Tamaño.** Una ciudad entera son decenas de miles de tramos. El archivo se lee entero en memoria dentro de la transacción: conviene
  pedir solo los tipos de la lista de arriba y solo el rectángulo de la ciudad. El tamaño real de Montevideo se mide en la primera carga.
- Las **zonas ya guardadas no cambian** al reimportar: guardan su polígono y sus esquinas, no apuntan a la red.

### Actualizar las calles

Es volver a bajar el archivo y volver a correr el script: OSM cambia todos los días y no hay una actualización automática.
No hace falta ningún aviso: la próxima llamada del panel ya usa la red nueva.
Se puede reimportar con el panel en uso: cada ciudad tiene un candado (`pg_advisory_xact_lock`): la recarga espera a que terminen las llamadas en
curso de esa ciudad y las llamadas nuevas esperan a que la recarga confirme. Así ninguna llamada junta esquinas de la red
vieja con un camino de la nueva, que daría un `CZ016` falso. Las otras ciudades no se enteran.

La espera cuenta como parte de la consulta, y la API de Supabase corta las consultas del rol `authenticated` a los 8 segundos
(`statement_timeout` por defecto). Si la recarga dura más que eso, la llamada que esperaba falla con **`57014`**
(`canceling statement due to statement timeout`) en vez de contestar: no es un error de datos ni de permisos, la red nueva está bien, y
repetir la llamada cuando la recarga terminó funciona. Para que casi nadie lo vea, conviene reimportar en un momento tranquilo
(la recarga solo bloquea mientras corre `ruteo.cargar_red()`: el `analyze` posterior no espera a nadie). El script no pone tope de tiempo a la
recarga (`statement_timeout = 0`): una ciudad grande puede tardar más de 8 segundos.

### Atribución

Las calles son datos de OpenStreetMap, © colaboradores de OpenStreetMap, bajo la [licencia ODbL](https://www.openstreetmap.org/copyright).
Quien muestre el mapa tiene que atribuirlo (el estilo de los mapas propios ya lo hace, [`mapas-tiles.md`](mapas-tiles.md)).

## Las tres RPC de la vista 24

Se llaman con el JWT del coordinador. Por PostgREST son `POST /rest/v1/rpc/<función>` con los parámetros por nombre (son `VOLATILE`:
llaman a `lanzar_motivo_mapa()`). El `p_campania_ciudad_id` es el de la pestaña de la vista 24, el mismo que recibe `guardar_zona()`.

### `esquina_mas_cercana(p_campania_ciudad_id, p_lon, p_lat)`

«Pororó y Heredia · clic para agregar». Una fila: el cruce de calles más cercano al punto.

| Columna | |
|---|---|
| `lon`, `lat` | el cruce |
| `calle_a`, `calle_b` | las dos calles (`null` si OSM no tiene el nombre) |
| `distancia_m` | a cuántos metros del punto quedó el cruce (un decimal) |

**No hay tope de distancia**: devuelve el más cercano de la ciudad, aunque quede lejos, y `distancia_m` deja al panel decidir si un
cruce a 800 m sigue siendo «la esquina de al lado». El más cercano se mide en **metros** (no en grados); si dos empatan, el de menor id.

### `tramo_por_calles(p_campania_ciudad_id, p_desde_lon, p_desde_lat, p_hasta_lon, p_hasta_lat)`

El recorrido más corto por las calles entre las esquinas más cercanas a los dos puntos (cada uno se engancha primero a su cruce; una
esquina ya enganchada se engancha a sí misma). Devuelve los puntos en orden, de `desde` a `hasta`, empezando y terminando en los cruces:

| Columna | |
|---|---|
| `orden` | 1, 2, 3, … |
| `lon`, `lat` | el punto |

Si los dos puntos caen en el mismo cruce, un solo punto. Si no hay camino (están en partes de la red que no se tocan), `CZ016`.

### `poligono_por_calles(p_campania_ciudad_id, p_esquinas)`

La zona entera. `p_esquinas` es la lista, **en el orden en que se marcaron**, de `{"lon": …, "lat": …}` (las claves de más se ignoran, así que
sirve lo que devolvió `esquina_mas_cercana()` o los clics sin enganchar). De 3 a 100 esquinas. Cada una se engancha a su cruce y el borde es la
concatenación de los tramos de cada esquina a la siguiente y **de la última a la primera**: el polígono se cierra en la esquina 1.

| Columna | |
|---|---|
| `poligono_geojson` | el `Polygon` GeoJSON, para el `p_poligono_geojson` de `guardar_zona()` |
| `esquinas` | las esquinas ya enganchadas, para el `p_vertices` de `guardar_zona()`: `[{"orden", "lon", "lat", "calle_a", "calle_b"}]` |

Una esquina repetida seguida (o la última igual a la primera) no agrega tramo, y vuelve en `esquinas` tal como se marcó. Si el recorrido
no es un borde válido —se cruza o vuelve sobre una calle— devuelve `CZ008` con el motivo, igual que `guardar_zona()`. Lo que arma pasa
la validación de `guardar_zona()` (el borde pasa a 1 m o menos de cada esquina) porque recorre exactamente los cruces.

```sql
-- el flujo de la vista 24, por esquinas (:cc es el campania_ciudad_id de la pestaña)
select * from public.esquina_mas_cercana(:cc, -56.1936, -34.9047);                  -- al pasar el mouse
select * from public.poligono_por_calles(:cc, '[{"lon":-56.19,"lat":-34.90}, …]');   -- al cerrar la forma: devuelve poligono_geojson y esquinas
select public.guardar_zona(:cc, 'Zona 1', 'ESQUINAS',                                -- al guardar, con lo que devolvió la llamada anterior
                           p_vertices => :esquinas, p_poligono_geojson => :poligono_geojson);
```

`guardar_zona()` **no cambia**: sigue recibiendo el polígono ya calculado y lo valida.

## Permisos y códigos

Las tres usan el mismo permiso que `guardar_zona()` (la vista 24 las llama para dibujar lo que después se guarda), y **es lo primero** que se mira:

1. Sin sesión → `42501`.
2. Sin el rol `COORDINADOR` ni `ADMIN` → `42501` (un colportor, un usuario sin rol o con el rol vencido no averigua si la ciudad existe).
3. La ciudad de la campaña tiene que existir y estar viva → `CZ012`.
4. La campaña la coordina quien llama (o es ADMIN): si es de otro, `42501`; si no existe, `CZ001`; si **ya terminó**, `CZ011`. Una campaña **por empezar** sí: la vista 24 prepara el mapa antes del inicio.
5. Que la ciudad tenga calles cargadas → `CZ015`.

| Código | Cuándo |
|---|---|
| `42501` | sin sesión, sin el rol, o la campaña es de otro coordinador |
| `CZ001` | la campaña no existe (o está dada de baja) |
| `CZ011` | la campaña ya terminó |
| `CZ012` | la ciudad no está en la campaña (o está dada de baja) |
| `CZ008` | punto fuera del mapa o sin `lon`/`lat`, menos de 3 esquinas (o menos de 3 en lugares distintos), más de 100, o un borde que se cruza o vuelve sobre sí mismo |
| `CZ015` | la ciudad todavía no tiene calles cargadas (o las cargadas no tienen ningún cruce) |
| `CZ016` | no hay camino por las calles entre dos esquinas |

Los mensajes vienen en español, dicen qué pasó y qué hacer, y se pueden mostrar tal cual. Devuelven solo posiciones y nombres de calles
(datos públicos de OSM): ni personas, ni ubicaciones, ni zonas de nadie. `EXECUTE` solo para `authenticated`; `ruteo.cargar_red()` y lo demás
del schema, solo para `service_role` (o el dueño, que es quien corre el script con la cadena de conexión).

## Límites y supuestos

- **Cómo se calcula.** Dijkstra no dirigido (`pgr_dijkstra`) con costo = largo en metros. Se busca primero dentro del rectángulo de los dos
  puntos agrandado en `max(1000 m, distancia entre ellos)`: como cualquier camino que salga de ahí mide al menos el doble de ese margen, un
  resultado de hasta ese largo es el más corto de toda la red; si es más largo, o no hay camino ahí, se busca de nuevo en toda la ciudad. El resultado es
  el mismo que con la red entera, pero cada clic no la lee toda.
- **pgRouting y `search_path`.** pgRouting 3.4 llama a sus funciones internas sin calificar y no funciona con `search_path` vacío: solo
  `ruteo.dijkstra()` —una envoltura interna con `search_path = extensions` que únicamente ejecuta `pgr_dijkstra`— lo necesita; todo lo demás sigue con `search_path` vacío.
- **El camino más corto no siempre es el que dibujaría una persona.** Entre dos esquinas sigue el tramo más corto, sin mirar manzanas ni
  zonas ya dibujadas. Si el borde sale mal, se mueve una esquina.
- **Calidad de OSM.** Una calle sin nombre en OSM es una esquina sin nombre. Dos calles que no se tocan en OSM (un puente, un dato sin conectar)
  no se tocan acá. Un barrio aislado de la red no tiene camino hacia el resto (`CZ016`).
- **No hay `provincia`** en el catálogo de ciudades ni se usa acá.
- **El aviso «Comparte la calle Heredia con Belvedere»** de la vista 24 necesita comparar el borde con el de las otras zonas de la ciudad, y no sale de estas
  funciones. Decidido el 16/10: va a la vista previa de `guardar_zona()` (backend-supabase#87), que devolverá las calles compartidas con otras zonas.
