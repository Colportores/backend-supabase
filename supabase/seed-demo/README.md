# Datos de demo simulados

Generador versionado e idempotente que llena una base con una historia creíble: catálogo y precios, tres ciudades,
dos campañas, diez colportores y un coordinador, casas visitadas, ventas, cobros, deudas, depósitos, pedidos y stock.
**Todo es ficticio** (nombres, correos `@example.com`, direcciones, montos): no hay producción hasta diciembre.

No es una migración ni el seed de ejemplo (`supabase/seed.sql`, que usa `scripts/db-seed.sh`, solo para la base local).
Producción no lo recibe. Solo se carga en la base local o en el proyecto de demo de abajo (referencia fija en el script);
`scripts/db-seed.sh` sigue rechazando cualquier base remota.

**Esquema vigente.** Los archivos de acá siguen el esquema de la última migración del repo. Desde la 0198, `producto` no
tiene la columna `tipo`: ninguna carga la escribe, y el tipo sale de la categoría (`tipo_de_categoria`; el pull del
teléfono sigue recibiendo la clave `tipo`, derivada). Contra una base anterior a la 0198 la carga falla.

| Archivo | Para qué |
|---|---|
| `demo-datos.sql` | La carga. Un solo `DO`: o carga todo o no carga nada. |
| `chequeo-demo.sql` | Solo lectura: conteo por tabla y reglas de coherencia (`ok = true` cuando cierran). |
| `retirar-demo-datos.sql` | Baja lógica de todo lo de la demo (vista previa por defecto). |
| `sumar-coordinador-demo.sql` | Suma a `coordinador.demo` como coordinador de las campañas de la demo (solo agrega). |
| `corregir-fechas-de-alta-demo.sql` | Una sola vez: fecha de alta de las inscripciones de una demo cargada antes del 11/11 (vista previa por defecto). |
| `sumar-colportor-demo.sql` | Inscribe a `colportor.demo` en la campaña de la demo, con su ciudad, su zona, su stock y dos semanas de actividad (solo agrega). |
| `demo-volumen.sql` | Segunda tanda, para las pruebas de los evaluadores: 150 ciudades, 54 colportores, seis semanas de actividad (ver abajo). |
| `demo-listas.sql` | Tercera tanda: que toda lista desplazable del panel y de la app tenga más de 25 registros (ver «Listas largas»). |
| `chequeo-listas-demo.sql` | Solo lectura: cuántos registros ve cada lista con `coordinador.demo` y `colportor.demo` (`ok` cuando llega a 26). |

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

# Que colportor.demo (la cuenta con la que se entra a la app) tenga ciudad, campaña, zona y datos para probar
scripts/db-seed-demo.sh [--remoto] --colportor
# Más volumen para las pruebas de los evaluadores (después de la carga base; ver «Volumen para las pruebas»)
scripts/db-seed-demo.sh [--remoto] --volumen
# Que toda lista desplazable tenga más de 25 registros (después de lo anterior; ver «Listas largas»)
scripts/db-seed-demo.sh [--remoto] --listas
scripts/db-seed-demo.sh [--remoto] --chequeo-listas
```

Reglas que el script hace cumplir: nunca `db reset`, nunca borra ni trunca; en remoto solo acepta el proyecto
`ohdsavwpasfpapbyutrv` (el viejo `isygm…` y cualquier otro se rechazan); sin `--remoto` rechaza cualquier `DB_URL` de
Supabase. La contraseña de los usuarios de la demo (`DEMO_PASSWORD`) solo se aplica en local y se lee con `\getenv`:
no se escribe en archivos ni pasa por la línea de comandos. Sin ella, los usuarios de la demo no pueden iniciar
sesión; en remoto se les pone contraseña desde Supabase Studio (Authentication) si hace falta entrar con ellos.

## Entrar a la app como colportor.demo

`colportor.demo` la crea Auth, no el seed, y para el teléfono sin inscripción no hay ciudad ni zona: la app entra vacía
(backend-supabase#286, lo que vieron los evaluadores). `sumar-colportor-demo.sql` (`--colportor`) la inscribe en la campaña de verano
de la demo, en la zona **Pocitos** de **Montevideo** (alta el 14/09, como los demás colportores de la demo, y primer tramo de
zona desde ese día), le deja stock inicial (ajuste `STOCK_INICIAL`, el mismo movimiento de la app: 12 ejemplares de cada libro,
20 de cada revista y folleto) y dos semanas de trabajo hasta el 17/11 (jornadas, visitas a las casas de Pocitos, ventas con sus
renglones, cobros en efectivo al contado o en parte), que suma a su cuenta de saldo si la tiene viva. Con eso puede elegir ciudad,
ver el mapa con sus casas, abrir una jornada y registrar una venta con entrega.

Reglas: sin la cuenta (base local, CI) o sin la demo base, no hace nada; solo agrega (el único UPDATE es el de su cuenta de
saldo y el del primer tramo de la inscripción nueva); si ya tiene inscripción en esa campaña, viva o de baja, no la toca y avisa
(una baja se revierte con `inscribir_colportor()`, no con un INSERT); si hay jornadas de esta carga, no repite. Lo que crea lleva el
prefijo de la demo, así que `--retirar` lo da de baja (el usuario `colportor.demo`, que no es de la demo generada, se queda).
No toca contraseñas ni Auth.
## Volumen para las pruebas de los evaluadores

`demo-volumen.sql` (`scripts/db-seed-demo.sh [--remoto] --volumen`, backend-supabase#285) suma, sobre la campaña de verano
ya cargada, lo que las listas largas y los reportes necesitan para verse como en uso real:

- **150 ciudades más** (del catálogo de Uruguay de la migración 0109; si la base no lo tiene, el script corre
  `public.cargar_catalogo_ciudades()`, que no borra ni duplica), cada una con su ciudad de campaña y dos zonas radiales
  (`Centro` y `Zona Norte`); una de cada tres con precios propios (±6 % sobre el general en tres libros).
- **54 colportores nuevos** (`demo.<nombre>.<apellido>.<n>@example.com`, sin contraseña), tres en cada una de las 18 primeras
  ciudades, con inscripciones escalonadas entre el 28/09 y el 12/10.
- **Seis semanas de actividad** (hasta el 17/11, de lunes a sábado): unas 1.150 jornadas, 7.000 visitas (ventas, entrevistas,
  rechazos y puertas sin respuesta), 1.000 ventas con sus renglones, 1.085 cobros en efectivo (al contado, en parte o en dos
  cuotas, con clientes que quedan debiendo), casas coloreadas en el mapa y la cuenta de cada colportor.

Qué **no** suma: entregas, stock, pedidos, depósitos ni agenda (la tanda base ya ejercita esos flujos). Requiere la demo base
(usa su campaña, su coordinador y sus productos): sin ella se detiene con un mensaje y no cambia nada. Es idempotente y
determinístico, y usa ids con el mismo prefijo `5eed0000-0000-7000-8…` y el código de tabla corrido 256 lugares
(`5eed0000-0000-7000-81xx-…`), así que `--retirar` también la retira y `--chequeo` la cuenta. El coordinador de la campaña es
el mismo (`demo.gustavo.ferreira`; con `--coordinador`, también `coordinador.demo`): Inicio, Equipo, Ciudades y Reportes la ven
sin más pasos. El test `supabase/tests/ops_seed_demo_volumen_test.sql` corre la base y la tanda completas, el panel sobre
ellas, la segunda pasada y el retiro.

## Listas largas (más de 25 registros en toda lista desplazable)

`demo-listas.sql` (`scripts/db-seed-demo.sh [--remoto] --listas`, backend-supabase#289) completa lo que la base y el volumen no
cubrían, para que los evaluadores abran cualquier lista y vean volumen (front-coordinadores-web#192 y
front-colportores-mobile#720 revisan cómo se muestran y si hace falta paginar). **Orden de carga**: base, `--coordinador`,
`--colportor`, `--volumen` y `--listas` (sin la base o sin el volumen se detiene con un mensaje y no cambia nada; sin `colportor.demo`
o sin `--colportor` carga todo menos la historia de esa cuenta, y avisa: al repetir `--listas` después de `--colportor` se le carga solo
su historia). Después, `--chequeo-listas` mide cada lista con la sesión de cada cuenta. Es idempotente (lo común lo guarda el producto 12
del catálogo y la historia de colportor.demo, su primera jornada) y la retira `--retirar` junto con el resto.

Lo que suma, sobre lo que ya había:

- **Catálogo**: 16 productos más (27 en total, 26 a la venta), cada uno con su precio general: el catálogo de la app y los
  precios de una ciudad pasan de 13 filas a 26 o más. **Los códigos 12 a 27 (`DEMO26-012` a `DEMO26-027`) son de relleno**, solo
  para las listas largas: mismos tipos y categorías que los diez títulos de la tanda base, sin significado de negocio.
- **Cuentas sueltas**: 24 coordinadores (la lista de acompañantes del panel llega a 26) y 30 cuentas de colportor sin campaña
  (lo que «Añadir colportor» sugiere y busca: la búsqueda pagina de a 10).
- **26 barrios de Montevideo** como zonas radiales (la lista de zonas de la ciudad).
- **Colportores del volumen (54)**: un depósito por semana con sus tickets (por validar las dos últimas semanas, validados y
  rechazados) y sus retiros del coordinador (por confirmar, confirmados y rechazados); cuatro pedidos cada uno (el kit de 26
  títulos y una reposición, recibidos; un tercero por autorizar o autorizado; un cuarto rechazado o despachado) con su stock;
  transferencias entre los de una misma ciudad (por autorizar, autorizadas, rechazadas); acompañamientos del coordinador (todas
  las jornadas de quienes tienen 26 o más); 40 ventas con un monto acordado y su motivo; y sus cuentas al día
  (`efectivo_en_mano()`, deuda con la casa, depositado).
- **colportor.demo**: su historia desde el 14/09 (44 jornadas, 87 ventas de las que 54 tienen saldo, 40 entregas pendientes, 91
  hechas, la agenda de cobranzas, entregas y entrevistas, un depósito por día hábil con sus tickets y retiros, 49 pedidos a la
  casa editora de los que 39 con saldo) y su cuenta al día.

Inventario de listas (qué tabla o RPC lee cada una; «filas» es lo que mide `--chequeo-listas` en una base local con todo cargado;
el mínimo es 26):

| Dónde | Lista | Fuente | Filas |
|---|---|---|---|
| Panel · Inicio y Ciudades | Ciudades de la campaña | `ciudades_de_campania` | 153 |
| Panel · Ciudades | Zonas de Montevideo / zonas para asignar / catálogo de ciudades | `zonas_de_ciudad`, `zonas_asignables`, `ciudades_del_catalogo` | 30 / 334 / 197 |
| Panel · Ciudades (precios) | Precios de una ciudad | `precios_de_la_ciudad` | 29 |
| Panel · Equipo | Colportores, zonas, becas, acompañamientos por colportor | `colportores_de_campania`, `zonas_por_colportor`, `becas_de_campania`, `acompaniamientos_por_colportor` | 65 |
| Panel · Equipo | Historial de acompañamientos (campaña / un colportor) y jornadas cerradas de un colportor | `historial_de_acompaniamientos`, `jornadas_cerradas_de_colportor` | 575 / 35 / 35 |
| Panel · Equipo | Acompañantes y búsqueda para añadir colportor | `acompaniantes_del_panel`, `buscar_candidatos` (páginas de 10) | 26 / 30 |
| Panel · Cuentas | Cuentas de los colportores | `cuentas_de_campania` | 65 |
| Panel · Cuentas · Validar tickets | Tickets: todos / por validar / validados / rechazados | `tickets_de_campania` | 184 / 54 / 97 / 33 |
| Panel · Cuentas · Validar tickets | Retiros: todos / por confirmar / confirmados / rechazados | `retiros_de_campania` | 132 / 38 / 59 / 35 |
| Panel · Reportes | Horas y ventas por ciudad y colportor; ventas con monto acordado | `horas_por_ciudad_y_colportor`, `ventas_por_ciudad_y_colportor`, `ventas_con_motivo_de_campania` | 400 / 384 / 40 |
| Panel · Stock | Stock por ciudad y producto | `stock_por_ciudad` | 1.690 |
| Panel · Pedidos | Pedidos (todos / por autorizar / autorizados / despachados / recibidos / rechazados) | `pedidos_de_campania` | 211 / 30 / 49 / 49 / 54 / 29 |
| Panel · Pedidos | Transferencias (todas / por autorizar / autorizadas / rechazadas) | `transferencias_de_campania` | 108 / 36 / 39 / 33 |
| App · Mapa | Ciudades (y mapas sin conexión) y casas | `mis_campania_ciudades()`, `ubicacion` | 153 / 192 |
| App · Nueva venta y Precios | Catálogo y precios | `producto`, `precio_general` | 26 |
| App · Jornada | Jornadas y visitas | `jornada`, `visita` | 44 / 307 |
| App · Ventas y Cobros | Ventas, ventas con saldo, cobros | `venta`, `cobranza` | 87 / 54 / 69 |
| App · Mi plata | Depósitos | `deposito` | 31 |
| App · Entregas | Pendientes y hechas (devolución) | `entrega` | 40 / 91 |
| App · Agenda | Cobranzas, entregas y entrevistas | `agenda` | 54 / 40 / 55 |
| App · Deuda con la casa | Pedidos con saldo | `mi_deuda_con_la_casa_editora()` | 39 |
| App · Pedidos y stock | Pedidos a la casa editora, títulos en stock, movimientos | `pedido_casa_editora`, `stock`, `movimiento_stock` | 49 / 26 / 127 |

Lo que **no** se puede sembrar desde la nube: las personas, las notas, los posibles duplicados y el «con quién» (viven solo en
el teléfono, ADR-018: el teléfono las crea y la nube solo guarda `espacio_persona`) y el historial del centro de notificaciones
(lo arma la app al recibir cada aviso). Esas listas se llenan usando la app. En el panel, **Cuentas, Stock y Pedidos todavía leen
datos simulados del propio front** (V2, después del 20/11: backend-supabase#101 y #104); el seed ya deja las filas que esas RPC
devolverán, así que ahí se verán largas cuando se conecten.

**Límite conocido**: las 10 inscripciones de la demo base quedan con el alta del día de la carga (ver «Limitación conocida (11/11)»):
`tickets_de_campania`, `retiros_de_campania` y `pedidos_de_campania` no las cuentan hasta que `corregir-fechas-de-alta-demo.sql`
(en `develop`) llegue a esta base. Las listas largas salen de los 54 colportores del volumen y de colportor.demo, que sí tienen el
alta en su primer día.

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

Un depósito ya validado no se da de baja ni desde el servidor (trigger `DP001`, migración 0129), y un retiro rechazado queda
como historia. El retiro los deja vivos y los cuenta en el resumen ("AVISO …"). Quitarlos es una decisión de dominio, no de este script.
