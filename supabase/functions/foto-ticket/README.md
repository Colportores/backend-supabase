# `foto-ticket` · la foto del ticket en Cloudflare R2

Edge Function (Deno) que da **enlaces firmados de Cloudflare R2, con vencimiento de minutos**, para subir o para ver la
foto de un ticket de tarjeta o de depósito. Es la decisión de Cristian del 27/10 («Foto cifrada»: carpeta privada, «R2
con permisos derivados de supa»; «Borrar foto»: la regla de borrado se aplica en R2), issue
[backend-supabase#182](https://github.com/Colportores/backend-supabase/issues/182), para HU-COB-007 y HU-COB-009. No es
un BFF
([ADR-013](https://github.com/Colportores/docs-organizacion/blob/main/docs/decisiones/ADR-013-clientes-directo-a-rpc-de-supabase.md)):
no guarda nada ni tiene reglas de negocio; las reglas están en la base (migración `0134`).

## Quién decide qué

| Pieza                                      | Qué hace                                                                                                                                                        |
| ------------------------------------------ | --------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| La base (`ruta_para_ver_foto_de_ticket`)   | Dice si quien pregunta ve la foto de ese ticket (la dueña, el ADMIN o el coordinador de la campaña del ticket: lo mismo que `ticket_select`) y cuál es su ruta. |
| La base (`ruta_para_subir_foto_de_ticket`) | Da la ruta `<usuario_id>/<ticket_id>.<ext>`; la carpeta sale de la sesión (`auth.uid()`), nunca del pedido.                                                     |
| Esta función                               | Llama a esas dos RPC **con el JWT de quien pidió** (manda la RLS), valida el pedido y firma el enlace de R2.                                                    |
| R2                                         | Guarda el archivo en un bucket privado y lo borra por su regla de ciclo de vida.                                                                                |

La función nunca usa la clave de servicio de Supabase (solo la clave pública del proyecto para el encabezado `apikey`),
y las claves de R2 son secretos de la función: no están en el código, en el teléfono, en el panel, ni en ningún log.

## Contrato

`POST /functions/v1/foto-ticket` con `Authorization: Bearer <JWT de la sesión>` y `apikey` (el SDK de Supabase los pone
solo con `supabase.functions.invoke`). Cuerpo de hasta 1 KB.

```json
{ "accion": "ver", "ticketId": "uuid en minúsculas" }

{ "accion": "subir", "ticketId": "uuid en minúsculas", "tipoDeImagen": "image/jpeg | image/png | image/webp", "bytes": 180000 }
```

`200`:

```json
{
  "accion": "subir",
  "metodo": "PUT",
  "url": "https://<cuenta>.r2.cloudflarestorage.com/<bucket>/<usuario_id>/<ticket_id>.jpg?X-Amz-…&X-Amz-Signature=…",
  "ruta": "<usuario_id>/<ticket_id>.jpg",
  "cabeceras": { "Content-Type": "image/jpeg", "Content-Length": "180000" },
  "venceEn": "2026-10-28T15:10:00.000Z"
}
```

- **Subir** (`PUT`, vence a los 10 minutos): el cliente hace `PUT <url>` con el cuerpo de la foto y **exactamente** las
  `cabeceras` que devolvió la función (la firma las ata; con otro tipo o largo, R2 contesta 403). Sin `Content-Type` con
  charset ni otra cosa. `ruta` es lo que va en `ticket.url_cloud`. Tope: 2 MiB, solo JPG, PNG o WebP.
- **Ver** (`GET`, vence a los 5 minutos): el cliente abre o baja `url` tal cual. La ruta sale de `ticket.url_cloud` en
  la base, no del pedido. `cabeceras` viene vacío.

| Resultado                    | Cuándo                                                                                  |
| ---------------------------- | --------------------------------------------------------------------------------------- |
| `400` `pedido_invalido`      | el cuerpo no tiene esa forma (acción, `ticketId` uuid, `bytes` entero ≥ 1)              |
| `401` `sin_sesion`           | sin JWT, vencido, o la base lo rechazó                                                  |
| `404` `ticket_no_encontrado` | el ticket no existe **o** no lo ve quien pregunta (no se distingue)                     |
| `404` `sin_foto`             | el ticket todavía no tiene foto                                                         |
| `405` / `413` / `415`        | método que no es POST / cuerpo o foto demasiado grande / tipo que no es JPG, PNG o WebP |
| `409` `foto_ya_subida`       | (subir) la foto de ese ticket ya está en R2: no se pisa                                 |
| `502` `no_se_pudo_comprobar` | (subir) R2 no contestó al HEAD previo: no se firma                                      |
| `410` `foto_vencida`         | pasaron 4 meses desde que se subió el ticket (RF-CO08A)                                 |
| `502` `no_se_pudo_leer`      | la base no contestó                                                                     |
| `500` `no_se_pudo_firmar`    | falla propia al firmar                                                                  |
| `503` `sin_configurar`       | faltan los secretos de R2 (nadie firma nada)                                            |

Cuerpo de error: `{ "error": { "codigo", "mensaje" } }`. Los `mensaje` dicen qué pasó y qué hacer, en español, para
mostrarse tal cual. Los códigos de la base (`FT001`, `FT002`, `FT003`) se traducen a los de la tabla; ver la migración
`0134`. CORS: `Access-Control-Allow-Origin: *` (la autenticación va en el JWT, no en cookies).

## Puesta en marcha (los pasos 1 a 4 los hace Cristian, una vez por ambiente; la publicación la hace `deploy.yml`)

1. **Bucket privado en R2** (Cloudflare → R2): sin acceso público ni dominio público. Un bucket por ambiente (develop,
   staging, production).
2. **Token de API de R2** con permiso _Object Read & Write_ **solo sobre ese bucket**. Guardar el _Account ID_, el
   _Access Key ID_ y el _Secret Access Key_; el secreto se ve una sola vez.
3. **Regla de ciclo de vida del bucket** (Settings → Object lifecycle rules → _Delete objects_): borrar los objetos a
   los **125 días** de subidos (ver «Pendientes»). Esto es lo que borra la foto a los 4 meses; no hay tarea propia. La
   base ya deja de ofrecerla a los 4 meses calendario (`FT003`) y suelta la ruta del ticket sola
   (`soltar_fotos_vencidas()`, pg_cron).
4. **Secretos de la función**, por ambiente (se cargan con la CLI, no se escriben en un archivo del repo):

   ```bash
   supabase secrets set --project-ref <ref> \
     R2_CUENTA=<account id> R2_CLAVE_DE_ACCESO=<access key id> R2_CLAVE_SECRETA=<secret access key> R2_BUCKET=<nombre del bucket>
   ```

5. **Publicar la función**: no hay que hacerlo a mano. `deploy.yml` corre `supabase functions deploy --use-api` después
   de `db push` en cada ambiente (backend-supabase#203). Para publicarla a mano, igual sirve
   `supabase functions deploy foto-ticket --project-ref <ref>`.
6. **CORS del bucket**, solo si el panel baja la foto con `fetch`/blob en vez de mostrarla en una etiqueta `<img>` o
   abrirla: permitir `GET` desde el origen del panel. El teléfono sube desde código nativo y no lo necesita.

Sin los cuatro secretos la función contesta `503 sin_configurar` y deja en el log solo **los nombres** de los que
faltan.

## Límites a tener en cuenta

- **Una foto ya subida no se pisa** (decisión del 28/10, pendiente P1 §2 de #182; el bucket de Supabase tampoco lo
  permitía). Antes de firmar una subida la función le hace a R2 un `HEAD` firmado (vence en 60 s y no sale de la
  función): si la clave ya existe contesta `409 foto_ya_subida` («Este ticket ya tiene su foto: no se puede cambiar.») y
  no firma nada; si R2 no contesta 200 ni 404, `502 no_se_pudo_comprobar` (ante la duda no se firma). Quien reintente
  una subida cuyo `PUT` sí llegó a R2 pero cuya respuesta se perdió recibe ese `409`: el teléfono lo tiene que tomar
  como «la foto ya está» y seguir. Queda una carrera mínima entre el `HEAD` y el `PUT`. **Para después, con el bucket
  real:** probar un `PUT` con la cabecera firmada `If-None-Match: *`; si R2 la respeta, se suma a `cabecerasFirmadas` y
  la carrera desaparece (si no la respeta, no se suma).
- **No hay cifrado propio de cada colportora**: la foto la ve el panel (decisión «Foto cifrada» del 27/10: carpeta
  privada, sin clave por colportora). R2 cifra en reposo.
- Los enlaces firmados son del portador: quien tenga el enlace puede usarlo hasta que venza. Por eso vencen en minutos y
  no se guardan ni se loguean.
- **Logs**: solo `{"evento":"foto-ticket.fallo","codigo":…,"origen":…}`; nunca el ticket, la ruta, el enlace ni una
  clave.
- El enlace se prueba contra R2 real recién cuando Cristian crea el bucket: hasta entonces la firma se prueba contra el
  vector oficial de AWS (R2 valida con el mismo algoritmo).

## Pruebas

Con [Deno](https://deno.com) 2.x (lo mismo que corre el job `funciones` de CI, sin base de datos ni Docker):

```bash
cd supabase/functions/foto-ticket
deno task test    # firma contra el vector de AWS + contrato HTTP + contrato con las migraciones
deno task check   # tipos, lint y formato
```

- `firma_test.ts`: la firma SigV4 contra el vector de pruebas de AWS, qué cosas cambian la firma y los bordes del
  vencimiento.
- `handler_test.ts`: el contrato HTTP completo con un `fetch` falso que contesta como PostgREST; que ninguna clave salga
  en respuestas ni logs.
- `contrato_test.ts`: ata los nombres, argumentos y códigos de error a la última migración que define cada RPC.
- Los permisos de verdad (quién ve, quién sube, qué vence) están en
  `supabase/tests/0134_fotos_de_tickets_en_r2_test.sql`.

Para probarla a mano: `supabase functions serve foto-ticket --env-file <archivo fuera del repo>` y un `curl` con un JWT.
