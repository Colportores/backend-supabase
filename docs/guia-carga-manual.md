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
  `precio_por_zona`).
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
pais → ciudad ─┬→ campania
               └→ zona ──────────────────┐
                                          │
producto ────────────────────────────────┼→ precio_por_zona
                                          │   (FK directa a producto O a coleccion —
coleccion ────────────────────────────────┘    NO pasa por producto_coleccion)
   │
   └→ producto_coleccion   (vínculo M:N producto↔colección; solo agrupa
                             para mostrar/vender junto, no es prerequisito
                             de un precio de colección)
```

`precio_por_zona` tiene FKs **directas** a `producto(id)` y a `coleccion(id)`
(`0001_esquema_inicial.sql` §4) — `producto_coleccion` es un vínculo aparte,
para armar el catálogo agrupado. Podés cargar un precio de colección sin haber
cargado `producto_coleccion` todavía.

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
insert into public.campania (nombre, tipo, fecha_inicio, fecha_fin, ciudad_id, coordinador_id)
values ('<nombre real>', 'VERANO', '2026-01-05', '2026-02-20', '<id de ciudad>', null);
```

- `tipo` acepta **exactamente** `'VERANO'`, `'INVIERNO'` o `'PERMANENTE'`
  (mayúsculas, sin acentos) — cualquier otro valor lo rechaza el `check`.
- `fecha_inicio` es obligatoria. `fecha_fin` puede ser `null` (campaña
  permanente, sin fecha de cierre) pero si la cargás **tiene que ser >=
  `fecha_inicio`**.
- `ciudad_id` tiene que existir en `ciudad`.
- `coordinador_id` es opcional, pero si lo cargás tiene que ser el `id` de una
  fila de `public.usuario` que ya exista (el coordinador tiene que haberse
  registrado antes en la app — este dato no se puede anticipar acá).

### 4. `zona`

```sql
insert into public.zona (nombre, ciudad_id, campania_id, poligono_geojson)
values ('<nombre real>', '<id de ciudad>', '<id de campania o null>', null);
```

- `ciudad_id` obligatorio, tiene que existir.
- `campania_id` es opcional: una zona puede existir sin pertenecer a una
  campaña concreta (zona "permanente"). Si lo cargás, tiene que existir.
- `poligono_geojson` es opcional (`jsonb`) — se puede dejar en `null` y
  cargarlo después desde la app/panel cuando exista.

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

### 8. `precio_por_zona`

```sql
-- Precio de un producto individual en una zona:
insert into public.precio_por_zona (producto_id, coleccion_id, zona_id, precio_venta, valido_desde, valido_hasta)
values ('<id de producto>', null, '<id de zona>', 25000, current_date, null);

-- Precio de una colección completa en una zona (excluyente con lo anterior):
insert into public.precio_por_zona (producto_id, coleccion_id, zona_id, precio_venta, valido_desde, valido_hasta)
values (null, '<id de coleccion>', '<id de zona>', 45000, current_date, null);
```

- **Exactamente uno** de `producto_id` / `coleccion_id` tiene que ir cargado y
  el otro en `null` — mandar los dos o ninguno lo rechaza el `check`.
- `precio_venta` en centavos, entero, `>= 0`.
- `valido_desde` es obligatorio (default `current_date` si no lo mandás).
  `valido_hasta` en `null` significa "vigente hasta nuevo aviso".
- **No puede haber dos precios vigentes a la vez para el mismo
  producto/colección en la misma zona** (rango de fechas que se superpone): si
  ya existe una fila con `valido_hasta` en `null` (abierta) para ese
  producto+zona, insertar una nueva **falla** con un error de exclusión
  (`conflicting key value violates exclusion constraint`). Para cambiar un
  precio:
  ```sql
  -- 1. Cerrar el precio viejo:
  update public.precio_por_zona
     set valido_hasta = current_date - 1
   where producto_id = '<id de producto>' and zona_id = '<id de zona>' and valido_hasta is null;

  -- 2. Recién ahí insertar el nuevo:
  insert into public.precio_por_zona (producto_id, zona_id, precio_venta, valido_desde)
  values ('<id de producto>', '<id de zona>', 27000, current_date);
  ```

## Qué NO se carga por esta vía

- `usuario`, `rol`, `usuario_rol`, `campania_colportor`: identidad y
  asignación de colportores — se crean al registrarse en la app y al asignar
  zona/campaña desde el flujo de Auth, no acá.
- `persona`, `nota`: no existen en este backend (Ley 18.331, ver README
  §Privacidad) — no hay nada que cargar.

## Datos de ejemplo para desarrollo

`supabase/seed.sql` trae un set fijo y **claramente ficticio** de zonas,
campañas, catálogo y precios para levantar el entorno local sin cargar nada a
mano. Se aplica con `scripts/db-seed.sh` (ver README §Desarrollo) — no se usa
en `staging`/`production`.
