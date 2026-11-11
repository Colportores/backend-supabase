# Datos de demo simulados

Generador versionado e idempotente que llena una base con una historia creíble: catálogo y precios, tres ciudades,
dos campañas, diez colportores y un coordinador, casas visitadas, ventas, cobros, deudas, depósitos, pedidos y stock.
**Todo es ficticio** (nombres, correos `@example.com`, direcciones, montos): no hay producción hasta diciembre.

No es una migración ni el seed de ejemplo (`supabase/seed.sql`, que usa `scripts/db-seed.sh`). Staging y producción no
lo reciben.

| Archivo | Para qué |
|---|---|
| `demo-datos.sql` | La carga. Un solo `DO`: o carga todo o no carga nada. |
| `chequeo-demo.sql` | Solo lectura: conteo por tabla y reglas de coherencia (`ok = true` cuando cierran). |
| `retirar-demo-datos.sql` | Baja lógica de todo lo de la demo (vista previa por defecto). |
| `sumar-coordinador-demo.sql` | Suma a `coordinador.demo` como coordinador de las campañas de la demo (solo agrega). |
| `corregir-fechas-de-alta-demo.sql` | Una sola vez: fecha de alta de las inscripciones de una demo cargada antes del 11/11 (vista previa por defecto). |

## Cómo se corre

```bash
# Base local (compose.dev.yml): DB_URL ya está en el entorno del contenedor `cli`
docker compose -f compose.dev.yml run --rm cli bash scripts/db-seed-demo.sh
docker compose -f compose.dev.yml run --rm cli bash scripts/db-seed-demo.sh --chequeo
DEMO_PASSWORD='…' docker compose -f compose.dev.yml run --rm -e DEMO_PASSWORD cli bash scripts/db-seed-demo.sh   # opcional

# Proyecto de DEMO en Supabase (ohdsavwpasfpapbyutrv), con el CLI logueado o SUPABASE_ACCESS_TOKEN en el entorno
scripts/db-seed-demo.sh --remoto            # carga
scripts/db-seed-demo.sh --remoto --chequeo  # conteos y coherencia

# Retirar la demo
scripts/db-seed-demo.sh [--remoto] --retirar            # vista previa, no cambia nada
scripts/db-seed-demo.sh [--remoto] --retirar --aplicar  # lo hace

# Que coordinador.demo (la cuenta con la que se entra al panel) vea la demo
scripts/db-seed-demo.sh [--remoto] --coordinador

# Corregir la fecha de alta de las inscripciones (demo cargada antes del 11/11)
scripts/db-seed-demo.sh [--remoto] --fechas            # vista previa
scripts/db-seed-demo.sh [--remoto] --fechas --aplicar  # lo hace
```

Reglas que el script hace cumplir: nunca `db reset`, nunca borra ni trunca; en remoto solo acepta el proyecto
`ohdsavwpasfpapbyutrv` (el viejo `isygm…` y cualquier otro se rechazan); sin `--remoto` rechaza cualquier `DB_URL` de
Supabase. La contraseña de los usuarios de la demo (`DEMO_PASSWORD`) solo se aplica en local y se lee con `\getenv`:
no se escribe en archivos ni pasa por la línea de comandos. Sin ella, los usuarios de la demo no pueden iniciar
sesión; en remoto se les pone contraseña desde Supabase Studio (Authentication) si hace falta entrar con ellos.

## Entrar al panel y ver la demo

El generador deja las dos campañas a cargo de su propio coordinador (`demo.gustavo.ferreira`), que no tiene contraseña.
El panel muestra solo las campañas que coordina quien entra (`campanias_del_coordinador()` y la RLS), así que con
`coordinador.demo` no se ve nada de la demo hasta correr `--coordinador`: suma a `coordinador.demo` como coordinador de
las campañas de la demo (una campaña admite varios, migración 0174). El coordinador generado sigue y
`campania.coordinador_id` no cambia. Es idempotente, sin esa cuenta no hace nada, y el retiro también da de baja estas
filas. La campaña de invierno ya terminó: el panel no la lista.

**Fechas de alta de las inscripciones.** Inicio (`tablero_de_inicio`) y Reportes (`horas_por_ciudad_y_colportor`,
`ventas_por_ciudad_y_colportor`) cuentan solo lo que pasó con la inscripción vigente y en la zona de ese día. Por eso el
generador da de alta cada inscripción el primer día de su historia (00:00 de Montevideo) y abre su primer tramo de zona
ese mismo día. Una demo cargada antes del 11/11 quedó con la hora de la carga: `--fechas` lo corrige (vista previa;
`--fechas --aplicar` lo hace). Toca solo las 13 inscripciones de la demo y su primer tramo, desactiva el trigger de
auditoría de `campania_colportor` solo dentro de su transacción (congela `created_at`) y es idempotente. En
`ohdsavwpasfpapbyutrv` se aplicó el 11/11.

Inicio muestra un día (hoy por defecto) y la historia termina el 03/11: para ver actividad hay que elegir un día anterior.

## Cómo está armado

- **Marca**: toda fila creada lleva un id con el prefijo `5eed0000-0000-7000-8…` (`pg_temp.did(tabla, n)`). Es
  determinístico: dos corridas generan los mismos ids, y el retiro encuentra todo por ese prefijo.
- **Idempotente**: si la campaña de verano de la demo ya existe, no hace nada; además cada `INSERT` lleva
  `on conflict do nothing`.
- **Determinístico**: no usa `random()`; los "azares" salen de un hash (`pg_temp.rnd`), así que la historia es la misma.
- **Sin depender del día en que se corre**: la historia queda anclada en el 04/11/2026, y las altas de `agenda` llevan `created_at` de ese día (el disparador AG003 mide la fecha programada contra `created_at`; sin él, una carga posterior rechazaría las cuotas ya vencidas). El test `ops_seed_demo_datos_test.sql` corre la carga y el retiro completos en CI.
- **Con las reglas del dominio**: pasa por los mismos disparadores que la app (la entrega descuenta el stock, el
  alquiler se calcula, los depósitos pasan por sus reglas). La plata va en centavos de peso uruguayo y los precios
  salen de `precio_por_ciudad` (si la ciudad no tiene precio, `precio_general`).
- **Sin personas con datos**: `persona` es solo del teléfono (ADR-018); en la nube solo hay `espacio_persona`.
- **La historia**: la campaña de verano (Montevideo, Maldonado y Salto) arrancó el 14/09; la de invierno terminó el 28/08.
  Hoy = 04/11/2026. Hay colportores más y menos productivos, clientes que pagan en cuotas y morosos, depósitos
  semanales (algunos atrasados), un alquiler sin pagar, tickets validados, pendientes y rechazados, pedidos recibidos,
  autorizados, por autorizar y rechazado, y entregas pendientes con su cita en la agenda.

## Qué NO se puede retirar del todo

Un depósito ya validado no se da de baja ni desde el servidor (trigger `DP001`, migración 0129). El retiro lo deja
vivo y lo cuenta en el resumen ("AVISO …"). Quitarlos es una decisión de dominio, no de este script.
