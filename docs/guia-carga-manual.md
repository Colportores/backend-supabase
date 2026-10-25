# Guía de carga manual — zonas, campañas, catálogo y precios

Mientras no exista el panel de administración (sale de Fase 1, ver
[`plan-sprints.md` §1](https://github.com/Colportores/docs-organizacion/blob/main/docs/plan-sprints.md)),
estos datos se cargan a mano desde el **SQL Editor de Supabase Studio**, contra
el proyecto del ambiente que corresponda (`develop`/`staging`/`production`).
No hace falta acceso al código ni a este repo clonado — solo al proyecto de
Supabase y permiso para correr SQL.

> **Dónde vive esta guía**: no está definido si debe vivir acá o en
> `docs-organizacion` (ver comentario en el issue
> [#16](https://github.com/Colportores/backend-supabase/issues/16)). Queda acá
> por ahora para que el PR de los seeds sea autocontenido.

## Antes de empezar

- El SQL Editor de Studio corre como `postgres`, que **bypassea RLS**. Esto
  significa que no hace falta iniciar sesión como ADMIN/COORDINADOR para
  insertar — pero también que ninguna política de permisos te va a frenar si
  te equivocás. Los únicos frenos son las validaciones del esquema que lista
  cada sección de abajo (`not null`, `check`, FKs, y el anti-solape de
  `precio_general` y de `precio_por_ciudad`).
- Envolvé cada carga en una transacción y revisá con `select` antes de hacer
  `commit`:
  ```sql
  begin;
  -- inserts acá
  -- select * from public.zona order by created_at desc limit 10;
  commit; -- o rollback; si algo no cierra
  ```
- No hace falta mandar `id`: todas las tablas tienen
  `default public.uuid_generate_v7()`. Mandalo solo si necesitás saber el id
  de antemano (por ejemplo, para referenciarlo en el mismo bloque).
- No hace falta mandar `created_at`, `updated_at` ni `sync_version`: el
  servidor los completa (trigger de auditoría). `created_by` podés dejarlo en
  `null` — no hay un `auth.uid()` real cuando cargás desde el SQL Editor.
- **Nunca uses `delete`** sobre estas tablas: `authenticated` ni siquiera tiene
  el privilegio, y borrar de verdad una fila que ya tiene FKs (zonas con
  ubicaciones, productos con ventas) rompe el historial. Para dar de baja algo,
  hacé baja lógica:
  ```sql
  update public.producto set deleted_at = now() where id = '...';
  ```
- Los nombres, precios y fechas de esta guía son ejemplos de sintaxis. Los
  valores reales (qué campañas existen, cómo se llaman las zonas, qué libros
  vende cada campaña y a qué precio) los define el coordinador/admin del
  proyecto — no se inventan acá.

## Orden de carga (respeta las FKs)

```
pais → ciudad ─┐
     campania ─┴→ campania_ciudad ─┬→ zona ─→ zona_vertice (solo ESQUINAS)
                                    │
producto ──────────────────────────┼→ precio_por_ciudad
                                    │   (FK a campania_ciudad y, directa, a producto O a
coleccion ─────────────────────────┘    coleccion — NO pasa por la zona ni por producto_coleccion)
   │
   └→ producto_coleccion   (vínculo M:N producto↔colección con su cantidad; agrupa
                             para mostrar/vender junto —un combo, § 7b— y no es
                             prerequisito de un precio de colección)

producto ──┬→ precio_general   (el precio de todo el país, de Administración: FK directa a
coleccion ─┘                    producto O a coleccion; no cuelga de ninguna campaña ni ciudad)
```

`precio_general` no cuelga de nada más que del producto o la colección: vale para
todas las campañas del país (§ 8, desde la migración `0034`).
`precio_por_ciudad` cuelga de la **ciudad de la campaña** (`campania_ciudad(id)`, desde
la migración `0027`; antes colgaba de la zona), y tiene FKs **directas** a
`producto(id)` y a `coleccion(id)` (`0001_esquema_inicial.sql` §4) —
`producto_coleccion` es un vínculo aparte, para armar el catálogo agrupado.
Podés cargar un precio de colección sin haber cargado `producto_coleccion`
todavía. La tabla se llamaba `precio_por_zona`: la migración `0030` la renombró
(decisión de Cristian del 06/10). Son los precios **por ciudad**, los casos
específicos: modifican el precio general (§ 8), y vale el modificado vigente o,
si no hay, el general. Un libro sin ninguno de los dos en una ciudad no se
ofrece allí.

### 1. `pais` (normalmente ya existe — V1 es solo Uruguay)

```sql
insert into public.pais (nombre, iso_code)
values ('Uruguay', 'UY');
```

- `iso_code` es **`char(2)` y único**: un segundo `'UY'` lo rechaza. Revisá
  primero con `select * from public.pais;` si ya está cargado.

### 2. `ciudad`

```sql
insert into public.ciudad (nombre, departamento, pais_id, lat_centro, lon_centro, zoom_inicial,
                           bbox_oeste, bbox_sur, bbox_este, bbox_norte)
values ('<nombre real>', '<departamento>', '<id de pais>', <lat>, <lon>, 13,
        <oeste>, <sur>, <este>, <norte>);
```

- **`departamento`** (desde la migración `0066`, decisión de Cristian del 21/10): el departamento
  al que pertenece la ciudad, como texto («Artigas», «Salto», «Río Negro»…). **Cargalo siempre**:
  es obligatorio en toda ciudad (HU-ADM-005) y la base lo exige: una ciudad nueva sin departamento se rechaza con `CD001` («Cargá el departamento de la ciudad») y a una que ya lo tiene no se le puede borrar. El panel agrupa
  y filtra por él (departamento → ciudad) y el buscador de «+ Agregar ciudad» muestra cada ciudad
  con su departamento y también busca por él; con dos «San José» es lo que las distingue.
  - Escribilo siempre igual (misma ortografía, con tilde: «Paysandú», no «Paysandu»): el panel
    agrupa por el texto exacto, y «Salto» y «salto» serían dos grupos. El esquema rechaza uno en
    blanco, con espacios al principio o al final, o de más de 60 caracteres
    (`ciudad_departamento_check`).
  - Para cargarlo o corregirlo después (los teléfonos lo bajan por el sync):
    ```sql
    update public.ciudad set departamento = '<departamento>' where id = '<id de ciudad>';
    ```
  - **Ciudades sin departamento.** Las que se cargaron antes de la `0066` quedan con el
    departamento vacío (la migración solo completa Montevideo; no adivina el de las demás).
    Esas se siguen pudiendo actualizar y dar de baja sin departamento (la regla de `CD001` rige
    para las nuevas y para no borrarlo, no sobre lo ya cargado).
    Para encontrarlas y completarlas:
    ```sql
    select c.id, c.nombre from public.ciudad c
     where c.deleted_at is null and c.departamento is null
     order by c.nombre;
    ```
- `pais_id` tiene que ser el `id` real de la fila de `pais` (buscalo con
  `select id from public.pais where iso_code = 'UY';`).
- `lat_centro`/`lon_centro` son obligatorios y sin rango validado por el
  esquema (a diferencia de `ubicacion.lat/lon`, que sí exige -90..90/-180..180)
  — igual cargá coordenadas reales, son el centro del mapa de esa ciudad.
- `zoom_inicial` es opcional (default 13) pero si lo mandás tiene que estar
  entre 1 y 22.
- **El rectángulo** (`bbox_oeste`, `bbox_sur`, `bbox_este`, `bbox_norte`; desde la
  migración `0031`, decisión de Cristian del 06/10) es la parte del planeta que
  se recorta para el mapa de la ciudad. Va en grados (WGS84) y **en este orden**:
  oeste (longitud mínima), sur (latitud mínima), este (longitud máxima), norte
  (latitud máxima). Ojo: Google Maps da las coordenadas como *latitud, longitud*,
  al revés de este orden.
  - **El publicador de mapas publica las ciudades que lo tienen.** Una ciudad sin
    rectángulo no tiene mapa propio: el publicador la lista y la saltea, no
    inventa uno. No hay ninguna lista de ciudades en el repo.
  - Es opcional, pero **los cuatro vienen juntos o ninguno** (`ciudad_bbox_completo_check`),
    cada longitud entre -180 y 180 y cada latitud entre -90 y 90
    (`ciudad_bbox_rango_check`), con el oeste antes que el este y el sur antes que el
    norte (`ciudad_bbox_orden_check`), y **el centro de la ciudad tiene que caer
    adentro** (`ciudad_bbox_contiene_centro_check`: así un lat/lon cargado al revés no
    pasa). Si algo no cierra, el `insert` falla con el nombre de esa restricción.
  - Cuánto abarcar: la ciudad y los barrios de alrededor donde se trabaja. Cuanto
    más grande, más pesa el mapa: el de Montevideo (el rectángulo de abajo) son ~11 MB.
    Si un rectángulo pasa de 50 MB, el publicador baja el zoom y, si no alcanza, parte
    la ciudad ([`docs/mapas-tiles.md`](mapas-tiles.md) § «Tamaño»).
  - Para cambiarlo después, un solo `update` con los cuatro valores juntos
    (el mapa se vuelve a cortar en la próxima publicación, y los teléfonos bajan el
    rectángulo nuevo por el sync):
    ```sql
    update public.ciudad
       set bbox_oeste = <oeste>, bbox_sur = <sur>, bbox_este = <este>, bbox_norte = <norte>
     where id = '<id de ciudad>';
    ```

#### Montevideo, lista para pegar (la primera ciudad con mapa)

Sirve en cualquier estado de la base y se puede correr más de una vez sin duplicar
nada: si Montevideo ya está cargada le pone el rectángulo (solo si no tenía uno); si no
está, la carga. No toca ninguna otra ciudad. Pegalo entero en el SQL Editor del proyecto
(necesita que el país `UY` ya esté cargado, [§ 1](#1-pais-normalmente-ya-existe--v1-es-solo-uruguay)):

```sql
-- 1. Si Montevideo ya estaba (viva, de Uruguay) sin rectángulo, se lo ponemos.
update public.ciudad c
   set bbox_oeste = -56.433, bbox_sur = -34.945, bbox_este = -55.948, bbox_norte = -34.701
  from public.pais p
 where p.id = c.pais_id and p.iso_code = 'UY'
   and c.nombre = 'Montevideo' and c.deleted_at is null
   and c.bbox_oeste is null;

-- 1b. Si Montevideo ya estaba sin departamento (cargada antes de la migración 0066), se lo ponemos.
update public.ciudad c
   set departamento = 'Montevideo'
  from public.pais p
 where p.id = c.pais_id and p.iso_code = 'UY'
   and c.nombre = 'Montevideo' and c.deleted_at is null
   and c.departamento is null;

-- 2. Si no había ninguna Montevideo viva, se carga (con el mismo rectángulo).
insert into public.ciudad (nombre, departamento, pais_id, lat_centro, lon_centro, zoom_inicial,
                           bbox_oeste, bbox_sur, bbox_este, bbox_norte)
select 'Montevideo', 'Montevideo', p.id, -34.9011, -56.1645, 13,
       -56.433, -34.945, -55.948, -34.701
  from public.pais p
 where p.iso_code = 'UY'
   and not exists (select 1 from public.ciudad c
                    where c.pais_id = p.id and c.nombre = 'Montevideo' and c.deleted_at is null);

-- 3. Revisá: tiene que salir UNA fila, con los cuatro valores cargados.
select c.id, c.nombre, c.departamento, p.iso_code, c.lat_centro, c.lon_centro,
       c.bbox_oeste, c.bbox_sur, c.bbox_este, c.bbox_norte
  from public.ciudad c join public.pais p on p.id = c.pais_id
 where p.iso_code = 'UY' and c.nombre = 'Montevideo' and c.deleted_at is null;
```

- **Este bloque no lleva `begin`/`commit` a propósito**: cada sentencia es atómica, el bloque se
  puede repetir sin duplicar nada y el SQL Editor corre todo junto, así que la revisión
  (el `select` final) se mira después y, si algo no cierra, se corrige repitiendo el bloque.
- Qué tiene que salir: **una sola fila** con `departamento = 'Montevideo'` y los cuatro `bbox_*` cargados. Si salen cero filas,
  falta el país `UY` (cargalo con la [§ 1](#1-pais-normalmente-ya-existe--v1-es-solo-uruguay) y
  repetí el bloque). Si salen dos, había dos Montevideo vivas: no sigas, avisá a quien administra
  la base (el publicador se detiene cuando dos ciudades tienen el mismo nombre).

- El centro (`-34.9011, -56.1645`) y el rectángulo son los de siempre del mapa de
  Montevideo; el `update` no cambia el centro de una Montevideo que ya estaba cargada
  (y si ese centro cae fuera del rectángulo, el esquema lo rechaza y no se guarda nada).
- Desde la migración `0031`, una base que ya tenía exactamente una Montevideo viva y
  sin rectángulo la recibe sola al aplicarla: en ese caso el bloque no hace nada (y la
  revisión del paso 3 muestra el rectángulo igual). Lo mismo con el `departamento` desde la
  `0066`: una Montevideo viva, única y con su centro adentro del rectángulo lo recibe sola.

#### Después de cargar la ciudad: sus calles

Una ciudad recién cargada **todavía no tiene calles**, y sin ellas las zonas por esquinas de la
vista 24 no se pueden dibujar (las tres RPC contestan `CZ015`, «todavía no están cargadas las
calles de esta ciudad»); las zonas radiales no las necesitan. Las calles de OpenStreetMap se cargan
**a mano, una vez por ciudad**, en el mismo paso en que se carga la ciudad y se publica su mapa:
con el archivo de calles del rectángulo de la ciudad y la cadena de conexión de la base (la **directa**, puerto 5432).
Con Docker, como el resto del repo:
`docker compose -f compose.dev.yml run --rm -e DB_URL=postgresql://… cli bash scripts/db-importar-calles.sh <id de ciudad> calles.json`
(con `-e`: compose ya fija un `DB_URL`, el de la base local, y uno puesto delante del comando no entra al contenedor, así que
la carga iría a la base local; el archivo tiene que estar dentro del repo, que el contenedor ve en `/work`). Sin Docker:
`DB_URL=postgresql://… bash scripts/db-importar-calles.sh <id de ciudad> calles.json`. Cómo conseguir el archivo,
qué calles entran y cómo se actualizan: [`docs/calles-ruteo.md`](calles-ruteo.md).

### 3. `campania`

```sql
insert into public.campania (nombre, tipo, fecha_inicio, fecha_fin, coordinador_id)
values ('<nombre real>', 'VERANO', '2026-01-05', '2026-02-20', null);
```

- `tipo` acepta **exactamente** `'VERANO'`, `'INVIERNO'` o `'PERMANENTE'`
  (mayúsculas, sin acentos) — cualquier otro valor lo rechaza el `check`.
- `fecha_inicio` es obligatoria. `fecha_fin` puede ser `null` (campaña
  permanente, sin fecha de cierre) pero si la cargás **tiene que ser >=
  `fecha_inicio`**.
- `coordinador_id` es opcional, pero si lo cargás tiene que ser el `id` de una
  fila de `public.usuario` que ya exista (el coordinador tiene que haberse
  registrado antes en la app — este dato no se puede anticipar acá).
- Las ciudades de la campaña van aparte, en `campania_ciudad` (una campaña
  abarca una o más ciudades, migración `0008`).
- `alquiler_monto` (opcional, desde la migración `0067`): el alquiler de la
  campaña **en centavos**, el mismo para todos los inscriptos; `null` (o no
  ponerlo) si la campaña no cobra alquiler. Se puede cargar o cambiar después:
  `update public.campania set alquiler_monto = 150000 where id = '<id>';`
  (`>= 0`). Es V2: todavía nada lo usa.

### 4. `campania_ciudad` y `zona`

Desde la migración `0008`, el camino normal es el panel (vista 24), que llama
a `agregar_ciudad_a_campania()` y `guardar_zona()`. A mano, como `postgres`:

```sql
insert into public.campania_ciudad (campania_id, ciudad_id)
values ('<id de campania>', '<id de ciudad>');

-- RADIAL: el polígono lo calcula el servidor a partir del centro y el radio.
insert into public.zona (nombre, campania_ciudad_id, tipo_forma, centro_lat, centro_lon, radio_m, color)
values ('<nombre real>', '<id de campania_ciudad>', 'RADIAL', <lat>, <lon>, <metros, de 1 a 3000>, '#3A7BD5');
```

- Toda zona es de una ciudad de una campaña (`campania_ciudad_id`
  obligatorio) y tiene forma: `RADIAL` (centro y radio) o `ESQUINAS` (el
  `poligono_geojson` ya calculado, un `Polygon` cerrado, más sus esquinas en
  `zona_vertice`, al menos 3). No se cargan zonas sin forma.
- Las zonas se pueden superponer (S56, migración `0013`): el `insert` no
  mira si una zona toca o cubre parte de otra.
- El nombre no se repite entre las zonas vivas de la misma `campania_ciudad`.

### 5. `producto`

```sql
insert into public.producto (nombre, descripcion, tipo, es_bonificable, es_misionero, precio_base_compra, casa_editora, imagen_url)
values ('<nombre real>', '<descripción>', 'LIBRO', true, false, 12000, '<editorial>', null);
```

- `tipo` acepta **exactamente** `'LIBRO'`, `'REVISTA'`, `'MATERIAL'` o
  `'MISIONERO'`.
- `precio_base_compra` (si lo cargás) va en **centavos, entero** y `>= 0` —
  nunca decimal. `$120,00` son `12000`, no `120.00`.
- `es_bonificable`/`es_misionero` son booleanos, default `false` si no los
  mandás.

### 6. `coleccion` (opcional — solo si el producto se vende agrupado)

```sql
insert into public.coleccion (nombre) values ('<nombre real>');
```

### 7. `producto_coleccion` (solo si usaste `coleccion`)

```sql
insert into public.producto_coleccion (producto_id, coleccion_id, cantidad)
values ('<id de producto>', '<id de coleccion>', 1);
```

- El par `(producto_id, coleccion_id)` es único: cargarlo dos veces lo
  rechaza. Para cambiar cuántas unidades lleva, se modifica la fila (§ 7b).
- `cantidad` (desde la migración `0056`) es cuántas unidades de ese producto
  lleva la colección: entero `> 0`, `1` si no lo mandás. Cero, negativo o
  `null` los rechaza la base.
- `producto_id` es siempre un **producto**: una colección no puede ser
  componente de otra (un combo no puede incluir otro combo).

### 7b. Combos (una colección con precio propio, desde la migración `0056`)

Un **combo** es una `coleccion` con productos (§ 7) y **su propio precio**
(decisión de Cristian del 21/10, HU-CAT-009): el colportor lo vende como **un
solo ítem** de la venta, con el precio del combo en su ciudad, y no el de cada
producto. Hasta que exista la pantalla de Administración (después del 20/11) se
arma acá, en este orden:

```sql
-- 1. El combo (§ 6) y sus componentes (§ 7): 1 libro y 2 revistas.
insert into public.coleccion (nombre) values ('Pack Familiar') returning id;
insert into public.producto_coleccion (producto_id, coleccion_id, cantidad) values
  ('<id del libro>',   '<id del combo>', 1),
  ('<id de la revista>', '<id del combo>', 2);

-- 2. Su precio general, para todo el país (§ 8; la columna producto_id va en null):
insert into public.precio_general (producto_id, coleccion_id, precio_venta, valido_desde, valido_hasta)
values (null, '<id del combo>', 120000, public.hoy_montevideo(), null);

-- 3. Si una ciudad se aparta, su excepción (§ 9):
insert into public.precio_por_ciudad (producto_id, coleccion_id, campania_ciudad_id, precio_venta, valido_desde, valido_hasta)
values (null, '<id del combo>', '<id de campania_ciudad>', 110000, public.hoy_montevideo(), null);
```

- **El precio del combo es suyo**, no la suma de los componentes: cargalo
  como cualquier otro precio (centavos, entero). Un combo sin precio general
  ni excepción en la ciudad **no se ofrece** allí.
- **Verificá** lo que ve una ciudad: `select * from public.precio_vigente('<id de campania_ciudad>', null, '<id del combo>');`
  (una fila con `GENERAL` o `MODIFICADO`) o, para todo el catálogo,
  `public.precios_de_la_ciudad(...)` (el combo sale con `tipo = 'COLECCION'`).
- **Una «Colección de N libros»** (desde la `0071`) es **otra colección** con su precio, que además de lo
  fijo deja elegir N libros al vender: se carga igual y se le dice cuántos con
  `update public.coleccion set libros_a_elegir = 2 where id = '<id del combo>';` (`0` = combo fijo, el valor
  por defecto). Cada tamaño (2, 3, 5…) es su propia colección con su propio precio (§ 8 y § 9). Los libros que
  elige quien vende no se cargan acá: los copia el teléfono en el ítem de la venta (`venta_item.componentes`).
- **Cambiar la cantidad de un componente** es un `update` de su fila
  (`update public.producto_coleccion set cantidad = 3 where id = '<id>';`).
  Las ventas hechas **no cambian**: guardan el ítem del combo y el precio con que
  se vendió (`venta_item.coleccion_id`, `precio_unitario`, `subtotal`).
- **Si un componente se da de baja** (`producto.deleted_at`), el combo deja de
  ofrecerse hasta corregirlo (el teléfono lo decide con lo que baja por el pull; el precio
  no se quita). `public.precios_de_la_ciudad(...)` lo cuenta en `componentes_de_baja`
  (desde la `0057`; 0 si ninguno). Para ver qué combos quedaron afectados con una consulta:
  ```sql
  select c.id, c.nombre, p.nombre as componente_de_baja
    from public.coleccion c
    join public.producto_coleccion pc on pc.coleccion_id = c.id and pc.deleted_at is null
    join public.producto p on p.id = pc.producto_id and p.deleted_at is not null
   where c.deleted_at is null;
  ```
  Se corrige quitando el componente (`update public.producto_coleccion set deleted_at = now() where id = '...'`)
  o poniendo uno vivo. El combo se da de baja como cualquier fila: `update public.coleccion set deleted_at = now()`.
- **Vender un combo.** El teléfono sube un `venta_item` con `coleccion_id` y sin
  `producto_id` (exactamente uno de los dos; si vienen los dos o ninguno, `23514`).
  El stock de cada producto del combo se descuenta recién en V2.

### 8. `precio_general` (el precio de venta de todo el país, de Administración)

Desde la migración `0034` (decisión de Cristian del 06/10, «Precio gral.»):
**Administración pone un precio general** por producto o por colección, que
queda para todas las campañas, y la coordinadora puede **modificarlo para una
ciudad de su campaña** (§ 9). No lleva ciudad ni campaña, ni país ni moneda
(V1 es solo Uruguay). Hasta que exista la pantalla de Administración (después del
20/11), el general se carga acá.

```sql
-- Precio general de un producto:
insert into public.precio_general (producto_id, coleccion_id, precio_venta, valido_desde, valido_hasta)
values ('<id de producto>', null, 24000, public.hoy_montevideo(), null);

-- Precio general de una colección completa (excluyente con lo anterior):
insert into public.precio_general (producto_id, coleccion_id, precio_venta, valido_desde, valido_hasta)
values (null, '<id de coleccion>', 44000, public.hoy_montevideo(), null);
```

- **Exactamente uno** de `producto_id` / `coleccion_id` tiene que ir cargado y
  el otro en `null` — mandar los dos o ninguno lo rechaza el `check`.
- `precio_venta` en centavos, entero, `>= 0` (`0` es el ejemplar misionero, que
  se entrega y no se vende).
- `valido_desde` es obligatorio (si no lo mandás, toma el día de Montevideo,
  `public.hoy_montevideo()`). `valido_hasta` en `null` significa "vigente hasta
  nuevo aviso". Las dos fechas valen: el último día todavía cuenta.
- **No puede haber dos generales vigentes a la vez para el mismo
  producto/colección** (rango de fechas que se superpone): insertar uno nuevo
  mientras hay otro abierto **falla** con un error de exclusión (23P01). Un
  general dado de baja (`deleted_at`) no cuenta. Para cambiarlo se cierra el
  viejo y se inserta el nuevo; cada tramo queda como una fila, que es el
  historial:
  ```sql
  -- 1a. Cerrar ayer el precio que ya rige (empezó antes de hoy y no terminó):
  update public.precio_general
     set valido_hasta = public.hoy_montevideo() - 1
   where producto_id = '<id de producto>' and deleted_at is null
     and valido_desde < public.hoy_montevideo()
     and (valido_hasta is null or valido_hasta >= public.hoy_montevideo());

  -- 1b. Dar de baja el que empieza hoy o más adelante: uno cargado hoy no se puede cerrar
  --     «ayer» (el rango quedaría al revés: 23514), y uno programado a futuro se superpondría
  --     con el nuevo (23P01); el nuevo lo reemplaza.
  update public.precio_general
     set deleted_at = now()
   where producto_id = '<id de producto>' and deleted_at is null
     and valido_desde >= public.hoy_montevideo();

  -- 2. Recién ahí insertar el nuevo:
  insert into public.precio_general (producto_id, precio_venta, valido_desde)
  values ('<id de producto>', 26000, public.hoy_montevideo());
  ```
  Para el general de una colección es lo mismo con `coleccion_id = '<id de coleccion>'`.
  Cambiar el general **no toca las ventas anteriores**: cada ítem de venta
  guarda el precio con el que se vendió (`venta_item.precio_unitario`).
- Lo escribe solo el **ADMIN**; el coordinador y el colportor no. (Desde el SQL
  Editor corrés como `postgres` y ningún permiso te frena.) Lo lee el ADMIN y
  quien hoy lee los precios de una campaña: su coordinador y los colportores
  inscriptos en una campaña que no terminó.
- **Todavía no baja a los teléfonos**: el contrato de sync no lo incluye hasta
  que lo apruebe el PR de docs correspondiente. Hasta entonces la app sigue
  usando `precio_por_ciudad`.

#### Qué precio rige: `precio_vigente()`

```sql
-- El de hoy, de un producto, en una ciudad de una campaña:
select * from public.precio_vigente('<id de campania_ciudad>', '<id de producto>');
-- El de una colección, en otra fecha:
select * from public.precio_vigente('<id de campania_ciudad>', null, '<id de coleccion>', '2026-03-01');
```

Devuelve **una fila** con `origen` (`'MODIFICADO'`, el de `precio_por_ciudad`, o
`'GENERAL'`), `precio_id`, `precio_venta`, `valido_desde` y `valido_hasta`, o
**ninguna** si el producto no tiene ni modificado ni general vigente en esa
fecha (no se ofrece en esa ciudad). Si hay modificado vigente, gana siempre al
general; si no, rige el general. Sin fecha usa el día de Montevideo. Pasá el
producto **o** la colección, nunca los dos (22023). Para quien llama, la ciudad
de la campaña tiene que ser visible: con la API, un coordinador consulta las de
su campaña.

Para ver **todos** los precios de una ciudad de la campaña juntos (cada producto
y cada colección con su general, su modificado y el que rige), `precios_de_la_ciudad()`
(`0037`):

```sql
select tipo, nombre, precio_general, precio_modificado, precio_vigente, origen
  from public.precios_de_la_ciudad('<id de campania_ciudad>');
-- Los productos bonificables que no tienen precio en esa ciudad (no se ofrecen):
select nombre from public.precios_de_la_ciudad('<id de campania_ciudad>')
 where tipo = 'PRODUCTO' and es_bonificable and origen is null;
```

Es la lectura de la vista 27 del panel: pide una sesión (ADMIN o el coordinador
de la campaña), así que en el SQL Editor, que corre como `postgres`, no tiene
sesión y falla con `42501`; para mirar los precios desde ahí, usá
`precio_vigente()` o leé las tablas.

### 9. `precio_por_ciudad` (la modificación del general, por ciudad de la campaña)

Antes de `0030` esta tabla se llamaba `precio_por_zona`. Es la excepción al
precio general (§ 8): lo que la coordinadora cambia para una ciudad de su
campaña. Si una ciudad no tiene fila vigente acá, rige el general.

El precio es de la **ciudad de la campaña** (`campania_ciudad_id`), no de una
zona: vale para todas las zonas de esa ciudad y dibujar o mover una zona no lo
toca. Dos campañas en la misma ciudad tienen cada una el suyo.

```sql
-- Precio de un producto individual en una ciudad de una campaña:
insert into public.precio_por_ciudad (producto_id, coleccion_id, campania_ciudad_id, precio_venta, valido_desde, valido_hasta)
values ('<id de producto>', null, '<id de campania_ciudad>', 25000, public.hoy_montevideo(), null);

-- Precio de una colección completa en una ciudad de una campaña (excluyente con lo anterior):
insert into public.precio_por_ciudad (producto_id, coleccion_id, campania_ciudad_id, precio_venta, valido_desde, valido_hasta)
values (null, '<id de coleccion>', '<id de campania_ciudad>', 45000, public.hoy_montevideo(), null);
```

- **Exactamente uno** de `producto_id` / `coleccion_id` tiene que ir cargado y
  el otro en `null` — mandar los dos o ninguno lo rechaza el `check`.
- `precio_venta` en centavos, entero, `>= 0`.
- `valido_desde` es obligatorio (si no lo mandás, toma el día de Montevideo,
  `public.hoy_montevideo()`, no el `current_date` de la sesión, que es UTC).
  `valido_hasta` en `null` significa "vigente hasta nuevo aviso".
- **No puede haber dos precios vigentes a la vez para el mismo
  producto/colección en la misma ciudad de la campaña** (rango de fechas que se
  superpone): si ya existe una fila con `valido_hasta` en `null` (abierta) para
  ese producto+`campania_ciudad`, insertar una nueva **falla** con un error de
  exclusión (`conflicting key value violates exclusion constraint`, 23P01).
  Otra ciudad de la misma campaña, u otra campaña en la misma ciudad (otra
  `campania_ciudad`), no cuenta. Un precio dado de baja (`deleted_at`) tampoco.
  Para cambiar un precio:
  ```sql
  -- 1a. Cerrar ayer el precio que ya rige (empezó antes de hoy y no terminó):
  update public.precio_por_ciudad
     set valido_hasta = public.hoy_montevideo() - 1
   where producto_id = '<id de producto>' and campania_ciudad_id = '<id de campania_ciudad>'
     and deleted_at is null
     and valido_desde < public.hoy_montevideo()
     and (valido_hasta is null or valido_hasta >= public.hoy_montevideo());

  -- 1b. Dar de baja el que empieza hoy o más adelante: uno cargado hoy no se puede cerrar
  --     «ayer» (el rango quedaría al revés: 23514), y uno programado a futuro se superpondría
  --     con el nuevo (23P01); el nuevo lo reemplaza.
  update public.precio_por_ciudad
     set deleted_at = now()
   where producto_id = '<id de producto>' and campania_ciudad_id = '<id de campania_ciudad>'
     and deleted_at is null
     and valido_desde >= public.hoy_montevideo();

  -- 2. Recién ahí insertar el nuevo:
  insert into public.precio_por_ciudad (producto_id, campania_ciudad_id, precio_venta, valido_desde)
  values ('<id de producto>', '<id de campania_ciudad>', 27000, public.hoy_montevideo());
  ```

## Qué NO se carga por esta vía

- `usuario`, `rol`, `usuario_rol`, `campania_colportor`: identidad y
  asignación de colportores — se crean al registrarse en la app y al asignar
  zona/campaña desde el flujo de Auth, no acá.
- `persona`, `nota`: no existen en este backend (Ley 18.331, ver README
  §Privacidad) — no hay nada que cargar.

## Datos de ejemplo para desarrollo

`supabase/seed.sql` trae un set fijo y **claramente ficticio** de zonas,
campañas, catálogo, precio general y precios por ciudad de la campaña para levantar el entorno local sin cargar nada a
mano. Se aplica con `scripts/db-seed.sh` (ver README §Desarrollo) — no se usa
en `staging`/`production`.

La excepción es **Montevideo**: el seed la carga con su centro y su rectángulo reales (los mismos
del bloque de [§ 2](#montevideo-lista-para-pegar-la-primera-ciudad-con-mapa)), para que el publicador
de mapas tenga algo que publicar contra una base local. Las dos «Ciudad Ejemplo» no traen rectángulo,
y el publicador las lista como ciudades sin mapa.
