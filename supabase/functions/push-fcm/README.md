# push-fcm

Edge Function (Deno) que manda por FCM los avisos push que la base dejó en su cola. Backend-supabase#237, HU-NOT-003,
ADR-014.

La base decide **qué** avisos hay, **a quién** y **con qué datos**; la función solo los entrega a Firebase Cloud
Messaging (API HTTP v1, sin el Admin SDK) y le cuenta a la base cómo salió cada uno. No lleva lógica de negocio.

## Cómo encaja

```
trigger / job (pg_cron) ──► push.evento (cola, misma transacción que el cambio)
                                 ▲                      │
        pg_cron cada minuto ──► push.despertar() ──pg_net──► POST /functions/v1/push-fcm   (x-push-clave)
                                                        │
              push_tomar_pendientes(p_max) ◄────────────┤   (service_role)
              push_resultado(...)          ◄────────────┤   (service_role)
                                                        └──► FCM v1  messages:send
```

- **Cola `push.evento`** (migración `0162`): un aviso por evento y usuario, con clave única (idempotencia). Tiene demora
  (`enviar_desde`), vigencia (`vence_en`), reserva de 2 minutos (`reservado_hasta`, con `for update skip locked`) y
  reintentos con espera creciente (1, 2, 4, 8, 16 y 30 min; a los 6 intentos queda `AGOTADO`).
- **Disparadores** (en la misma transacción que el cambio, así que un `rollback` no deja avisos): pedido autorizado,
  ticket validado, ticket rechazado y primera campaña asignada. Los programados (`0163`, a la hora de cada usuario desde
  la `0166`): cuotas pendientes y agenda de mañana.
- **`push.despertar()`** (`0163`) llama a esta función por `pg_net` cuando hay avisos listos.

## Contrato

`POST /functions/v1/push-fcm` con el encabezado `x-push-clave: <PUSH_CLAVE>`. Sin JWT de usuario (`verify_jwt = false`):
se autentica con la clave compartida, comparada en tiempo constante.

| Respuesta                                                                          | Cuándo                                                                                                                                                   |
| ---------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `200` `{tomados, enviados, reintentos, tokens_invalidos, descartados, sin_contar}` | Corrió (también si no había nada: todo en 0).                                                                                                            |
| `401` `no_autorizado`                                                              | Falta `x-push-clave` o no coincide. No toca la cola.                                                                                                     |
| `405` `metodo`                                                                     | No es POST.                                                                                                                                              |
| `502` `no_se_pudo_leer`                                                            | La base no contestó al pedir los avisos y no se mandó ninguno.                                                                                           |
| `503` `sin_configurar`                                                             | Falta un secreto (`SUPABASE_URL`, `SUPABASE_SERVICE_ROLE_KEY`, `PUSH_CLAVE` o `FCM_CUENTA_DE_SERVICIO`). El log dice **solo el nombre** de lo que falta. |

Da hasta 4 vueltas de 50 avisos por despertar y manda 10 a la vez; lo que quede lo toma el próximo despertar (un minuto
después).

### Lo que usa de la base

| RPC (`public`, solo `service_role`)                                                      | Para qué                                                                                                                                                 |
| ---------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `push_tomar_pendientes(p_max integer default 50)` → `(evento_id, token, datos, intento)` | Toma y reserva los avisos listos, vigentes y con token. Descarta en el acto los que ya no aplican (la cuenta se suspendió, el pedido se deshizo, etc.).  |
| `push_resultado(p_evento_id, p_resultado, p_token, p_error)` → `boolean`                 | `ENVIADO`, `REINTENTAR`, `TOKEN_INVALIDO` o `DESCARTAR`. Con `TOKEN_INVALIDO` borra `usuario.fcm_token` (solo si sigue siendo ese token) y no reintenta. |

`contrato_test.ts` ata estos nombres, firmas, resultados, tipos y claves del payload a las migraciones: si cambian, el
CI lo avisa.

### Cómo se clasifica la respuesta de FCM

| FCM                                                                                                     | Resultado                                             |
| ------------------------------------------------------------------------------------------------------- | ----------------------------------------------------- |
| `200`                                                                                                   | `ENVIADO`                                             |
| `UNREGISTERED`, `SENDER_ID_MISMATCH`, o `400 INVALID_ARGUMENT` que nombra al _registration token_       | `TOKEN_INVALIDO` (se borra el token, no se reintenta) |
| `401`, `403`, `404` sin `UNREGISTERED`, `408`, `429`, `5xx`, error de red o de autenticación con Google | `REINTENTAR`                                          |
| Otro `4xx` (mensaje mal armado) y payload fuera de contrato                                             | `DESCARTAR`                                           |

Un `404` o `403` sin el código de token **no** borra nada: suele ser un proyecto o una cuenta de servicio mal
configurados, y borrar tokens por eso dejaría a todos sin push.

## Payload

Los **datos** (`data`) de cada aviso y un **título fijo** por tipo (decisión de Cristian, 04/11, «Título fijo del
servidor»): el servidor no escribe nada más. El texto completo lo arma la app con sus textos locales cuando se abre
(R-NO02: nada de nombres, montos ni direcciones en el servidor ni en Google). Todos los valores de `data` son texto; la
función frena cualquier clave que no sea de esta tabla o cuyo valor de `*_id` no sea un UUID.

| `type`                | Título (fijo)                | Claves además de `type` y `event_id`   | Cuándo sale                                                                                                                                                                                                            |
| --------------------- | ---------------------------- | -------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `pedido_autorizado`   | «Tu pedido fue autorizado»   | `pedido_id`                            | Al autorizarse el pedido, con 15 s de demora (la ventana de «Deshacer»); si se deshace antes, no sale.                                                                                                                 |
| `ticket_validado`     | «Tu ticket fue validado»     | `ticket_id`                            | Al validar el ticket.                                                                                                                                                                                                  |
| `ticket_rechazado`    | «Tu ticket fue rechazado»    | `ticket_id`                            | Al rechazar el ticket.                                                                                                                                                                                                 |
| `asignacion_campania` | «Te asignaron a una campaña» | `campania_id`, `zona_id` (si hay zona) | La cuenta pasa de PENDIENTE_ASIGNACION a ACTIVA: su primera inscripción viva en una campaña no terminada (cuenta no suspendida). `zona_id` sólo si la inscripción ya tiene zona. Un cambio de zona posterior no avisa. |
| `cuota_pendiente`     | «Tenés una cuota por cobrar» | `agenda_id`                            | Cita de cobranza programada que cumple 3 días y cuya venta sigue con saldo; una vez por cita, a la `hora_cuota` de cada usuario (por defecto 09:00 de Montevideo, ver abajo).                                          |
| `agenda_manana`       | «Mañana tenés visitas»       | —                                      | A quien tiene citas programadas para mañana, desde su `hora_agenda` (por defecto 20:00 de Montevideo); vence a las 4 horas de esa hora, y nunca pasada la medianoche.                                                  |

`event_id` es el id del aviso: la app lo usa para no mostrar dos veces el mismo si FCM lo reentrega.

**Cómo llega con la app cerrada:** Android lleva `notification: { title }` y `priority: HIGH`; iOS lleva `aps.alert`
(`title`), `apns-push-type: alert`, `apns-priority: 10` y `content-available: 1` (la app también recibe los datos). Sin
cuerpo: el título es todo lo que escribe el servidor. Un tipo que no tiene título (la función ya lo frena antes) saldría
como mensaje de solo datos (`apns-push-type: background`, prioridad 5). `contrato_test.ts` ata los títulos a los seis
tipos de la cola: sumar un tipo sin título falla en CI.

### La hora de cada usuario

La hora de `cuota_pendiente` y de `agenda_manana` la elige cada usuario en Configuración › Notificaciones (decisión de
Cristian, 04/11, «Hora avisos», front-colportores-mobile#516). Vive en `usuario.notif_preferences` (jsonb) como
`hora_cuota` y `hora_agenda`, `"HH:MM"` en hora de Montevideo (por defecto `09:00` y `20:00`), y se guarda con la RPC
`guardar_mis_preferencias_de_avisos(p_preferencias jsonb)` (el objeto entero, `null` = valores por defecto). Los
trabajos de `pg_cron` corren cada 15 minutos y cada pasada anota el aviso de quien ya pasó su hora y no lo recibió;
cambiar la hora después de recibirlo no lo repite. Detalle en la migración `0166`.

## Puesta en marcha

Todo esto lo hace una persona con acceso al proyecto de Firebase y al de Supabase, una vez por environment. **Nada de
esto va al repo.**

1. **Firebase.** En el proyecto de la app: Configuración → Cuentas de servicio → _Generar nueva clave privada_. Es un
   JSON con `project_id`, `client_email` y `private_key`. La cuenta necesita el rol _Firebase Cloud Messaging API Admin_
   (o `cloudmessaging.messages.create`) y la API _Firebase Cloud Messaging API (V1)_ habilitada.
2. **Secretos de la función** (el runtime ya pone `SUPABASE_URL` y `SUPABASE_SERVICE_ROLE_KEY`):
   ```bash
   supabase secrets set PUSH_CLAVE="$(openssl rand -hex 32)" FCM_CUENTA_DE_SERVICIO="$(cat cuenta-de-servicio.json)" --project-ref <ref>
   ```
   Anotá el valor de `PUSH_CLAVE`: hace falta en el paso siguiente.
3. **Secretos de la base (Vault)**, para que `push.despertar()` sepa a qué llamar. En el editor SQL del proyecto:
   ```sql
   select vault.create_secret('https://<ref>.supabase.co/functions/v1/push-fcm', 'push_fcm_url');
   select vault.create_secret('<el mismo PUSH_CLAVE>', 'push_fcm_clave');
   ```
   Mientras falte alguno de los dos, `push.despertar()` no hace nada (y los avisos esperan en la cola, vigentes hasta su
   `vence_en`). Para rotar la clave: `vault.update_secret` y `supabase secrets set` con el mismo valor nuevo.
4. **Publicar la función.** Lo hace `deploy.yml` junto con las demás (`supabase functions deploy --use-api`).
5. **Extensiones.** `pg_net` y `pg_cron` las crea la migración `0163` si el proyecto las permite; en Supabase se
   habilitan desde Database → Extensions si hiciera falta.

Verificar: `select * from cron.job where jobname like 'push-%';` (cuatro trabajos), y después de un cambio que dispare
un aviso, `select estado, intentos, ultimo_error from push.evento order by creado_en desc limit 5;` (como
`service_role`/`postgres`).

## Operación

- Un aviso `AGOTADO` o `DESCARTADO` queda en `push.evento` 14 días y después lo purga `push-purgar`.
- Los logs son una línea JSON por hecho (`push-fcm.no_enviado`, `push-fcm.sin_contar`, …) con el resultado y un código
  corto. **Nunca** salen tokens, claves, la cuenta de servicio ni datos del aviso.
- Si FCM aceptó un aviso pero la función no pudo contárselo a la base (`sin_contar`), el aviso vuelve a la cola a los 2
  minutos y puede llegar dos veces; la app lo descarta por `event_id`.

## Desarrollo

```bash
cd supabase/functions/push-fcm
deno task check   # tipos, lint y formato
deno task test    # fetch falso de Google y FCM + contrato contra las migraciones; sin red ni base
```

La firma del JWT (RS256 por WebCrypto), la caché del token de acceso (se renueva un minuto antes de vencer) y la
clasificación de respuestas están en `fcm.ts`; el flujo de la cola, en `handler.ts`.
