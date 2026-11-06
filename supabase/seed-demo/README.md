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
```

Reglas que el script hace cumplir: nunca `db reset`, nunca borra ni trunca; en remoto solo acepta el proyecto
`ohdsavwpasfpapbyutrv` (el viejo `isygm…` y cualquier otro se rechazan); sin `--remoto` rechaza cualquier `DB_URL` de
Supabase. La contraseña de los usuarios de la demo (`DEMO_PASSWORD`) solo se aplica en local y se lee con `\getenv`:
no se escribe en archivos ni pasa por la línea de comandos. Sin ella, los usuarios de la demo no pueden iniciar
sesión; en remoto se les pone contraseña desde Supabase Studio (Authentication) si hace falta entrar con ellos.

## Cómo está armado

- **Marca**: toda fila creada lleva un id con el prefijo `5eed0000-0000-7000-8…` (`pg_temp.did(tabla, n)`). Es
  determinístico: dos corridas generan los mismos ids, y el retiro encuentra todo por ese prefijo.
- **Idempotente**: si la campaña de verano de la demo ya existe, no hace nada; además cada `INSERT` lleva
  `on conflict do nothing`.
- **Determinístico**: no usa `random()`; los "azares" salen de un hash (`pg_temp.rnd`), así que la historia es la misma.
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
