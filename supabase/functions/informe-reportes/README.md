# `informe-reportes` · el «Informe PDF» de Reportes

Edge Function (Deno) que arma el **«Informe PDF»** de la vista 32 (Reportes) del panel del coordinador y lo devuelve
para bajar. Es la decisión de Cristian del 23/10 («PDF informe»: **en el servidor**) para HU-REP-005, issue
[backend-supabase#144](https://github.com/Colportores/backend-supabase/issues/144), seguimiento de
`front-coordinadores-web#62`. No es un BFF
([ADR-013](https://github.com/Colportores/docs-organizacion/blob/main/docs/decisiones/ADR-013-clientes-directo-a-rpc-de-supabase.md)):
no tiene lógica de negocio propia ni escribe nada; arma un archivo con lo que las RPC ya devuelven. Está dentro del
stack de
[ADR-012](https://github.com/Colportores/docs-organizacion/blob/main/docs/decisiones/ADR-012-backend-supabase-sa-east-1.md).

## Qué hace

1. Toma el JWT de la coordinadora (`Authorization: Bearer …`) y **lee con él** las mismas RPC que la pantalla:
   `campanias_del_coordinador()`, `horas_por_ciudad_y_colportor()`, `ventas_por_ciudad_y_colportor()`,
   `zonas_por_colportor()` y `ciudades_de_campania()`. Manda la RLS y los permisos de las RPC: la función **nunca usa la
   clave de servicio** (solo la clave pública del proyecto para el encabezado `apikey`).
2. Arma el reporte con las mismas cuentas y los mismos textos que la pantalla (períodos, tendencia contra el período
   anterior, «sin datos desde…», «S2 contra S1»): `calculo.ts` y `reporte.ts` son la regla de `calculo.ts`,
   `metricas.ts`, `ambito.ts` y `armado.ts` del panel. Si la regla cambia allá, cambia acá.
3. Dibuja el PDF con **pdf-lib** (JavaScript puro, corre en Deno, sin navegador headless): la marca, los filtros
   aplicados (campaña, ver, agrupado por, período, al día), las tarjetas con su gráfico y la tabla, en A4, con
   encabezado de tabla repetido, la ciudad siempre con su primera fila y «Página n de N». Tipografías estándar del PDF
   (no se incrusta ninguna); una letra que no trae («Ł», emoji, otro alfabeto) sale como la más parecida o como «?».
4. **Nunca lleva datos de clientes**: las RPC no los devuelven y el archivo solo tiene el nombre de cada colportor y
   totales («el coordinador ve montos, no clientes»; decisión «CSV nombres» del 23/10: el nombre del colportor sí).

El «% por cobrar» (V2) no está: el panel todavía no lo muestra (`MOSTRAR_POR_COBRAR = false`).

## Contrato

`POST /functions/v1/informe-reportes` con `Authorization: Bearer <JWT de la sesión>` y `apikey` (el SDK de Supabase los
pone solos con `supabase.functions.invoke`).

```json
{
  "campaniaId": "uuid | null",
  "ambito": { "tipo": "todas" }
          | { "tipo": "departamento", "departamento": "Rivera" }
          | { "tipo": "ciudad", "ciudadId": "uuid | sin-zona" }
          | { "tipo": "colportor", "colportorId": "uuid" },
  "granularidad": "dia" | "semana" | "mes"
}
```

`ambito` y `granularidad` son los `Ambito` y `Granularidad` de la vista 32 tal cual. `campaniaId` es la campaña elegida
en el selector del panel: solo vale si figura en `campanias_del_coordinador()` de quien llama; si falta o ya no figura,
se usa la primera (igual que el panel). Un `ambito` que ya no existe en los datos vuelve a «Todas las ciudades» (y el
informe lo dice en «Ver»). El cuerpo no puede pasar de 4 KB.

| Resultado                                          | Cuándo                                                                                     | Cuerpo                                                                                                                                                                                 |
| -------------------------------------------------- | ------------------------------------------------------------------------------------------ | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `200`                                              | listo                                                                                      | el `.pdf` (`application/pdf`), con `Content-Disposition: attachment; filename="reportes-rivera-semanas-2026-10-21.pdf"` (mismo nombre que armaba el panel) y `Cache-Control: no-store` |
| `400` `pedido_invalido`                            | el cuerpo no tiene esa forma                                                               | `{ "error": { "codigo", "mensaje" } }`                                                                                                                                                 |
| `401` `sin_sesion`                                 | sin JWT, o vencido                                                                         | idem                                                                                                                                                                                   |
| `403` `sin_permiso`                                | no coordina esa campaña (`42501`)                                                          | idem                                                                                                                                                                                   |
| `404` `sin_campania`                               | no tiene una campaña en curso (o todavía no empezó)                                        | idem                                                                                                                                                                                   |
| `405` / `413`                                      | método que no es POST / cuerpo demasiado grande                                            | idem                                                                                                                                                                                   |
| `422` `sin_datos`                                  | el reporte no tiene ningún colportor («No hay colportores para exportar en este reporte.») | idem                                                                                                                                                                                   |
| `500` `no_se_pudo_armar` / `502` `no_se_pudo_leer` | falla propia / la base o la API no contestaron                                             | idem                                                                                                                                                                                   |

Los `mensaje` dicen qué pasó y qué hacer, en español, para que el panel los muestre tal cual. Sin conexión no hay
respuesta: ahí el panel muestra «Necesitás conexión para descargar el informe PDF.» (es del panel, no de la función).

CORS: `Access-Control-Allow-Origin: *` (la autenticación va en el JWT, no en cookies) y `Content-Disposition` expuesto
para que el navegador pueda leer el nombre del archivo.

## Límites a tener en cuenta

- **Filas de PostgREST**: las RPC se piden por día y, si una respuesta llega a `max_rows` (1000), el rango se parte a la
  mitad hasta que ninguna esté cortada (igual que el panel). Un solo día con 1000 filas o más sale como error, nunca
  como datos a medias.
- **CPU**: una campaña de ~3 meses con 200 colportores arma el PDF en ~150 ms de CPU y pesa unas decenas de KB, lejos
  del tope de las Edge Functions. Reportes de más de 10 mil filas pasan al trabajo en segundo plano con correo
  (HU-REP-005, cuando un reporte llegue a eso).
- **Logs**: solo `{"evento":"informe-reportes.fallo","codigo":…,"origen":…}`; nunca nombres, ids ni el JWT.

## Pruebas

Con [Deno](https://deno.com) 2.x (lo mismo que corre el job `funciones` de CI, sin base de datos ni Docker):

```bash
cd supabase/functions/informe-reportes
deno task test    # unitarias + contrato contra las migraciones
deno task check   # tipos, lint y formato
```

- `calculo_test.ts` / `reporte_test.ts`: períodos, comparación, tendencia, ámbitos y textos.
- `datos_test.ts`: las lecturas (partido del pedido, sin zona, inscriptos sin horas, errores que no se toman por «sin
  datos»).
- `pdf_test.ts`: la maqueta (páginas, pie, márgenes, nombres largos, caracteres raros) y el PDF real, que se vuelve a
  abrir.
- `handler_test.ts`: el contrato HTTP completo con un `fetch` falso que contesta como PostgREST.
- `contrato_test.ts`: ata las columnas que lee la función a la última migración que define cada RPC.

Para probarla a mano: `supabase functions serve informe-reportes` y un `curl` con un JWT de coordinadora.
