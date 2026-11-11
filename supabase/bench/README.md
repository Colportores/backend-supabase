# Bench del delta

Carga sintética y medición del camino de sincronización. **No lo corre CI**: tarda minutos y deja ~390.000 filas en la base.

```sh
docker compose -f compose.dev.yml run --rm cli bash scripts/db-reset.sh
docker compose -f compose.dev.yml run --rm -e COLPORTORES=150 cli bash scripts/db-bench.sh
```

`CIUDADES_AJENAS=N` (por defecto 4) suma N ciudades de 60.000 casas de otro colportor, para que el delta tenga filas que descartar; `0` mide con una sola ciudad.

Dimensionado según **RP-01**: 150 colportores, una temporada de campaña. `COLPORTORES=10` para una corrida rápida.

| tabla | filas |
|---|---|
| `ubicacion` (su ciudad), `espacio`, `espacio_persona` | 60.000 c/u |
| `ubicacion` de otras ciudades | 60.000 por ciudad (4 por defecto) |
| `visita`, `venta`, `venta_item` | 60.000 c/u |
| `jornada` | 30.000 |

`carga.sql` reparte `xmin_w` a mano al final. Toda la carga entra en pocas transacciones, así que sin eso casi todas las filas compartirían cursor y la paginación del delta degeneraría a ordenar por `id`. Los valores quedan **por debajo** del xid actual, o el corte por horizonte de `sync.pull` los dejaría afuera y la medición correría sobre cero filas.

## Para qué existe

Contesta la pregunta que abrió el paso a `SECURITY INVOKER` (issue #6): al mover el filtrado por fila de un `where pk_usuario = $1` explícito al predicado de la política RLS, **¿el delta sigue usando el índice?**

Lo que hay que mirar en cada plan: si el predicado aparece como **`Index Cond`** (el índice lo resuelve) o como **`Filter`** con `Rows Removed by Filter` alto (recorre la tabla y descarta).

## Resultados — 2026-09-02, 390.000 filas

Una página del delta (500 filas) por entidad, como colportor autenticado:

| entidad | predicado de la política | plan | antes de `0003` | después |
|---|---|---|---|---|
| `visita` | `colportor_id = auth.uid()` | **Index Only Scan**, predicado en el `Index Cond` | 0,35 ms | **0,77 ms** |
| `jornada` | `colportor_id = auth.uid()` | Bitmap Index Scan + Sort | 1,36 ms | **0,31 ms** |
| `venta_item` | `EXISTS` contra `venta` | Index Scan + Filter | 24,6 ms | **20,2 ms** |
| `ubicacion` | `zona_id in (mis_zonas()) OR …` | Index Scan + **Filter** | **1.210 ms** | **34,6 ms** |

Los RPC completos:

| | |
|---|---|
| `sync.pull` primera página, 4 entidades | 56 ms |
| `sync.pull` incremental sin novedades | 46 ms |
| `sync.push` de 100 jobs | **60 ms** |

RR-02 pide lotes de 100 registros en menos de 30 s: hay tres órdenes de magnitud de margen.

## Lo que encontró

**`tiene_rol()` suelta en un `USING` se evalúa por fila.** El plan de `ubicacion` antes de la migración `0003`:

```
Index Scan using ubicacion_delta_idx on ubicacion t  (actual time=1163..1206 rows=400)
  Filter: ((zona_id = ANY (hashed SubPlan 1)) OR (created_by = ...)
           OR tiene_rol('COORDINADOR') OR tiene_rol('ADMIN'))
  Rows Removed by Filter: 59600
  Buffers: shared hit=24106 read=844
Execution Time: 1209.991 ms
```

60.000 llamadas a `tiene_rol()`, cada una con sus joins contra `usuario_rol`/`rol`/`usuario`. De ahí los 24.000 buffers. Envuelta en `(select ...)` pasa a ser un InitPlan que se evalúa una vez — misma semántica, **35× más rápido** y 10× menos buffers. Es la regla de `security-rls-performance.md` de la skill del dominio, y la migración `0003` la aplica a todas las políticas. Hay un test en `0002_rls_test.sql` que falla si alguna futura se aparta.

## Lo que seguía abierto (2026-09-02; el estado de hoy está más abajo)

**El predicado por zona sigue siendo un `Filter`, no un `Index Cond`.** `ubicacion`, `espacio` y `house_status` recorren la tabla entera para servir una página: `Rows Removed by Filter: 59600` para devolver 400. A 60.000 filas son 35 ms; el costo crece linealmente con los datos.

La causa no es el índice sino la forma de la política: una cadena de `OR` sobre columnas distintas más dos llamadas a función no es indexable, por más índice que se agregue. Arreglarlo requiere sacar el bypass de staff (`COORDINADOR`/`ADMIN`) fuera del `OR` — por ejemplo, dándole al panel del coordinador un camino propio — y eso **cambia el modelo de permisos**, así que no entra por la puerta del rendimiento.

`venta_item`, `entrega` y `cobranza` tienen el mismo patrón por otra razón: su predicado es un `EXISTS` contra `venta`, que tampoco es indexable en la tabla hija. A 60.000 filas son 20 ms.

## Estado al 2026-10-29 (0148) — lo que dice hoy #14

Re-medido con la carga de ahora: 150 colportores, su ciudad (60.000 casas) y **4 ciudades ajenas de otras 60.000 casas c/u** (300.000 ubicaciones en la tabla; `CIUDADES_AJENAS=0` vuelve a una sola ciudad). Y con el cursor repartido de verdad: en una base recién levantada el xid actual ronda 1.600, y `carga.sql` restaba el número de fila al xid, así que el 98 % de las filas quedaba en `xmin_w = 1` y el delta paginaba solo por `id`. Eso hacía que las páginas posteriores a la primera eligieran otro plan (Hash Join contra toda la tabla, 160-550 ms por página) que no existe en una base con el cursor repartido. Las secciones de arriba se midieron con ese reparto: sirven por el plan, no por el tiempo de las páginas posteriores a la primera.

**Lo que ya no es como lo describe el issue:**

- `ubicacion`, `espacio` y `house_status` **no tienen predicado por zona** desde `0011` (la zona se calcula al descargar, `zona_id` ya no existe en ellas): la política es por ciudad, `created_by = uid OR ciudad_id IN (mis_ciudades_de_trabajo()) OR staff`, y el pull baja **toda la ciudad** (`0023`), a propósito. El `OR` con `tiene_rol('COORDINADOR'/'ADMIN')` sigue ahí, pero para un colportor sus dos `InitPlan` figuran `never executed`: el planner los resuelve una vez y no cuestan nada por fila.
- `venta_item`, `entrega` y `cobranza` **no tienen bypass de staff**: su política es solo `EXISTS (venta del colportor)`. No tienen rama de staff en la política. Es decir que la opción 1 del issue (camino propio para el staff) ya es el estado de esas tres tablas; lo que queda en ellas es el `EXISTS`, no el `OR`.
- El pull de las tres tablas por ciudad le suma `exists (select 1 from ubicacion u where u.id = t.<col> and (u.created_by = $4 or u.ciudad_id = any($5)))`: es una igualdad por PK, entra por nested loop y no recorre nada de más.

**Plan del delta, primera página de 500, como colportor** (6 ciudades en la tabla):

| entidad | plan | filas descartadas por el `Filter` | tiempo |
|---|---|---|---|
| `jornada`, `visita` | Index Only Scan, `colportor_id` en el `Index Cond` | 0 | 0,7 y 0,4 ms |
| `ubicacion` | Index Scan por `(xmin_w, id)` + `Filter` por ciudad | 1.944 (de 2.444 leídas) | 14 ms |
| `venta_item` | Index Scan por `(xmin_w, id)` + `Filter` (`venta_id` en el hash de sus ventas) | **59.600** (para 400) | **39 ms** |

**Descarga completa** (un teléfono nuevo, todas las páginas de 500 con `sync.pull`):

| entidad | filas | páginas | tiempo |
|---|---|---|---|
| `ubicacion` (su ciudad, entre 6) | 60.000 | 120 | 5,1 s |
| `espacio` | 60.000 | 120 | 2,4 s |
| `venta_item`, `visita`, `venta`, `jornada` | 300-400 c/u | 1 | 6-30 ms |

**Cómo crece.** El costo del `Filter` es proporcional a las filas de la tabla **por encima del cursor**, no a la tabla. Una descarga completa recorre la tabla una vez (los 39 ms de `venta_item` son esa pasada, no una por página: el colportor recibe sus 400 filas en la primera). Un pull incremental recorre solo lo que cambió desde el último cursor. Con las ciudades de otros, `ubicacion` lee ~5 filas por cada una que baja, que es lineal en la cantidad de ciudades y cuesta ~40 ms por página de 500 en la descarga completa.

**Qué queda de #14.** Ninguna de las tres opciones del issue se necesita para que el delta funcione: el cambio de plan (que `zona_id`/`ciudad_id` aparezca en el `Index Cond`) pide cambiar el modelo de permisos o el de datos (denormalizar `colportor_id` en `venta_item`, `entrega` y `cobranza`; o un camino de staff aparte para `ubicacion`), y lo que compra es bajar 39 ms por descarga completa y ~40 ms por página en una ciudad de 60.000 casas. Esa decisión no es de rendimiento (toca ADR-016 y el tablero del coordinador, ADR-010), así que sigue planteada en el issue #14 (backend-supabase#14) con estos números.

## Alcance del pull (0011) — 2026-09-30, misma carga (histórico: desde 0023 solo queda el camino «ciudad»)

Desde `0011` el pull de `ubicacion`, `espacio` y `house_status` baja según el alcance (HU-SYNC-011). En la carga, cada colportor tiene 400 casas propias dentro de su zona, entre 60.000 de la misma ciudad.

| | |
|---|---|
| área completa de su zona, 3 entidades desde cero | 61 ms |
| pull de la zona sin novedades | ~50 ms |
| primera página de «ciudad», 3 entidades | 82 ms |
| «Incluye N ubicaciones» de una zona | 12 ms |

La parte «zona» sale del índice GiST, una vez por consulta, con `ubicaciones_de_mi_zona()` (SECURITY DEFINER). Con el filtro escrito sobre la tabla con RLS, `ST_Covers` no es LEAKPROOF, el planificador no puede usar el índice y evalúa el polígono casa por casa: ~3 µs por casa, 630 ms para bajar el área completa de una zona.

Desde `0023` (backend-supabase#58) el pull baja siempre toda la ciudad de la zona del colportor: la rama «zona» y `ubicaciones_de_mi_zona()` ya no existen y no hay alcance que elegir. Los números de arriba son de `0011` y no se volvieron a medir; el camino que queda es el de «ciudad» (82 ms la primera página), sin el aviso de salida por posición. `medir.sql` pasó a medir ese único camino.
