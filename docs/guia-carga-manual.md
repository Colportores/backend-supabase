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
  `precio_por_ciudad`).
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
   └→ producto_coleccion   (vínculo M:N producto↔colección; solo agrupa
                             para mostrar/vender junto, no es prerequisito
                             de un precio de colección)
```

`precio_por_ciudad` cuelga de la **ciudad de la campaña** (`campania_ciudad(id)`, desde
la migración `0027`; antes colgaba de la zona), y tiene FKs **directas** a
`producto(id)` y a `coleccion(id)` (`0001_esquema_inicial.sql` §4) —
`producto_coleccion` es un vínculo aparte, para armar el catálogo agrupado.
Podés cargar un precio de colección sin haber cargado `producto_coleccion`
todavía. La tabla se llamaba `precio_por_zona`: la migración `0030` la renombró
(decisión de Cristian del 06/10). Son los precios **por ciudad**, los casos
específicos: el precio general todavía no existe en el modelo (espera una
respuesta de Cristian), y un libro sin precio en una ciudad no se ofrece allí.

### 1. `pais` (normalmente ya existe — V1 es solo Uruguay)

```sql
insert into public.pais (nombre, iso_code)
values ('Uruguay', 'UY');
```

- `iso_code` es **`char(2)` y único**: un segundo `'UY'` lo rechaza. Revisá
  primero con `select * from public.pais;` si ya está cargado.

### 2. `ciudad`

```sql
insert into public.ciudad (nombre, pais_id, lat_centro, lon_centro, zoom_inicial)
values ('<nombre real>', '<id de pais>', <lat>, <lon>, 13);
```

- `pais_id` tiene que ser el `id` real de la fila de `pais` (buscalo con
  `select id from public.pais where iso_code = 'UY';`).
- `lat_centro`/`lon_centro` son obligatorios y sin rango validado por el
  esquema (a diferencia de `ubicacion.lat/lon`, que sí exige -90..90/-180..180)
  — igual cargá coordenadas reales, son el centro del mapa de esa ciudad.
- `zoom_inicial` es opcional (default 13) pero si lo mandás tiene que estar
  entre 1 y 22.

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
insert into public.producto_coleccion (producto_id, coleccion_id)
values ('<id de producto>', '<id de coleccion>');
```

- El par `(producto_id, coleccion_id)` es único: cargarlo dos veces lo
  rechaza.

### 8. `precio_por_ciudad` (el precio de venta, por ciudad de la campaña)

Antes de `0030` esta tabla se llamaba `precio_por_zona`.

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
  -- 1. Cerrar el precio viejo:
  update public.precio_por_ciudad
     set valido_hasta = public.hoy_montevideo() - 1
   where producto_id = '<id de producto>' and campania_ciudad_id = '<id de campania_ciudad>'
     and valido_hasta is null and deleted_at is null;

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
campañas, catálogo y precios (por ciudad de la campaña) para levantar el entorno local sin cargar nada a
mano. Se aplica con `scripts/db-seed.sh` (ver README §Desarrollo) — no se usa
en `staging`/`production`.
