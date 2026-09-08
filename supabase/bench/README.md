# Bench del delta

Carga sintética y medición del camino de sincronización. **No lo corre CI**: tarda minutos y deja ~390.000 filas en la base.

```sh
docker compose -f compose.dev.yml run --rm cli bash scripts/db-reset.sh
docker compose -f compose.dev.yml run --rm -e COLPORTORES=150 cli bash scripts/db-bench.sh
```

Dimensionado según **RP-01**: 150 colportores, una temporada de campaña. `COLPORTORES=10` para una corrida rápida.

| tabla | filas |
|---|---|
| `ubicacion`, `espacio`, `espacio_persona` | 60.000 c/u |
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

## Lo que sigue abierto

**El predicado por zona sigue siendo un `Filter`, no un `Index Cond`.** `ubicacion`, `espacio` y `house_status` recorren la tabla entera para servir una página: `Rows Removed by Filter: 59600` para devolver 400. A 60.000 filas son 35 ms; el costo crece linealmente con los datos.

La causa no es el índice sino la forma de la política: una cadena de `OR` sobre columnas distintas más dos llamadas a función no es indexable, por más índice que se agregue. Arreglarlo requiere sacar el bypass de staff (`COORDINADOR`/`ADMIN`) fuera del `OR` — por ejemplo, dándole al panel del coordinador un camino propio — y eso **cambia el modelo de permisos**, así que no entra por la puerta del rendimiento.

`venta_item`, `entrega` y `cobranza` tienen el mismo patrón por otra razón: su predicado es un `EXISTS` contra `venta`, que tampoco es indexable en la tabla hija. A 60.000 filas son 20 ms.
