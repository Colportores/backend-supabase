import { assert, assertEquals, assertNotEquals } from "@std/assert";

import {
  armarMensaje,
  clasificarRespuesta,
  ClienteFcm,
  codigoCorto,
  type CuentaDeServicio,
  firmarJwt,
  leerCuentaDeServicio,
  URL_DEL_TOKEN_DE_ACCESO,
} from "./fcm.ts";

const AHORA = new Date("2026-11-04T15:00:00Z");

function pemDe(pkcs8: ArrayBuffer): string {
  const base64 = btoa(String.fromCharCode(...new Uint8Array(pkcs8)));
  return `-----BEGIN PRIVATE KEY-----\n${base64.match(/.{1,64}/g)!.join("\n")}\n-----END PRIVATE KEY-----\n`;
}

/** Un par de claves RSA de prueba y la cuenta de servicio que las usa. */
async function cuentaDePrueba(): Promise<{ cuenta: CuentaDeServicio; publica: CryptoKey }> {
  const par = await crypto.subtle.generateKey(
    { name: "RSASSA-PKCS1-v1_5", modulusLength: 2048, publicExponent: new Uint8Array([1, 0, 1]), hash: "SHA-256" },
    true,
    ["sign", "verify"],
  );
  const pkcs8 = await crypto.subtle.exportKey("pkcs8", par.privateKey);
  return {
    cuenta: {
      project_id: "colportores-prueba",
      client_email: "push@colportores-prueba.iam.gserviceaccount.com",
      private_key: pemDe(pkcs8),
    },
    publica: par.publicKey,
  };
}

function decodificar(parte: string): Record<string, unknown> {
  const base64 = parte.replace(/-/g, "+").replace(/_/g, "/");
  return JSON.parse(atob(base64.padEnd(Math.ceil(base64.length / 4) * 4, "=")));
}

Deno.test("leerCuentaDeServicio · acepta el JSON de Firebase y descarta lo que no sirve", async () => {
  const { cuenta } = await cuentaDePrueba();
  const completo = JSON.stringify({ ...cuenta, type: "service_account", otra_cosa: "x" });
  assertEquals(leerCuentaDeServicio(completo), cuenta, "se queda solo con lo que usa");

  assertEquals(leerCuentaDeServicio(undefined), null);
  assertEquals(leerCuentaDeServicio(""), null);
  assertEquals(leerCuentaDeServicio("no es json"), null);
  assertEquals(leerCuentaDeServicio("[]"), null);
  assertEquals(leerCuentaDeServicio(JSON.stringify({ ...cuenta, project_id: "" })), null);
  assertEquals(leerCuentaDeServicio(JSON.stringify({ ...cuenta, client_email: 3 })), null);
  assertEquals(leerCuentaDeServicio(JSON.stringify({ ...cuenta, private_key: "no es una clave" })), null);
});

Deno.test("firmarJwt · RS256 con la clave de la cuenta, el alcance de FCM y una hora de vida", async () => {
  const { cuenta, publica } = await cuentaDePrueba();
  const jwt = await firmarJwt(cuenta, AHORA);
  const [cabecera, reclamos, firma] = jwt.split(".");

  assertEquals(decodificar(cabecera), { alg: "RS256", typ: "JWT" });
  const iat = Math.floor(AHORA.getTime() / 1000);
  assertEquals(decodificar(reclamos), {
    iss: cuenta.client_email,
    scope: "https://www.googleapis.com/auth/firebase.messaging",
    aud: URL_DEL_TOKEN_DE_ACCESO,
    iat,
    exp: iat + 3600,
  });

  const base64 = firma.replace(/-/g, "+").replace(/_/g, "/");
  const bytes = Uint8Array.from(atob(base64.padEnd(Math.ceil(base64.length / 4) * 4, "=")), (c) => c.charCodeAt(0));
  const valida = await crypto.subtle.verify(
    "RSASSA-PKCS1-v1_5",
    publica,
    bytes,
    new TextEncoder().encode(`${cabecera}.${reclamos}`),
  );
  assert(valida, "la firma se verifica con la clave pública");
  assert(!/[+/=]/.test(jwt), "base64url: sin +, / ni =");
});

Deno.test("codigoCorto · deja un código apto para la base y, si no se puede, el de reserva", () => {
  assertEquals(codigoCorto("UNAVAILABLE", "X"), "UNAVAILABLE");
  assertEquals(codigoCorto("quota exceeded", "X"), "QUOTA_EXCEEDED");
  assertEquals(codigoCorto(undefined, "HTTP_500"), "HTTP_500");
  assertEquals(codigoCorto("", "HTTP_500"), "HTTP_500");
  assertEquals(codigoCorto("9ABC", "HTTP_500"), "HTTP_500", "tiene que empezar con una letra");
  assertEquals(codigoCorto("A".repeat(41), "HTTP_500"), "HTTP_500", "hasta 40 caracteres");
});

Deno.test("clasificarRespuesta · cada respuesta de FCM tiene su destino", () => {
  const error = (estado: number, status: string, errorCode?: string, message = "") => ({
    error: { code: estado, status, message, details: errorCode ? [{ errorCode }] : [] },
  });

  assertEquals(clasificarRespuesta(200, { name: "projects/x/messages/1" }), { resultado: "ENVIADO" });
  assertEquals(clasificarRespuesta(200, null), { resultado: "ENVIADO" });

  // El token no sirve: solo cuando FCM lo dice con todas las letras.
  assertEquals(clasificarRespuesta(404, error(404, "NOT_FOUND", "UNREGISTERED")), {
    resultado: "TOKEN_INVALIDO",
    codigo: "UNREGISTERED",
  });
  assertEquals(clasificarRespuesta(403, error(403, "PERMISSION_DENIED", "SENDER_ID_MISMATCH")), {
    resultado: "TOKEN_INVALIDO",
    codigo: "SENDER_ID_MISMATCH",
  });
  assertEquals(
    clasificarRespuesta(
      400,
      error(400, "INVALID_ARGUMENT", undefined, "The registration token is not a valid FCM registration token"),
    ),
    { resultado: "TOKEN_INVALIDO", codigo: "INVALID_ARGUMENT" },
  );

  // Un 404 sin UNREGISTERED es un proyecto mal puesto: se reintenta y NO se borra ningún token.
  assertEquals(clasificarRespuesta(404, error(404, "NOT_FOUND", undefined, "Requested entity was not found.")), {
    resultado: "REINTENTAR",
    codigo: "NOT_FOUND",
  });
  assertEquals(clasificarRespuesta(404, null), { resultado: "REINTENTAR", codigo: "HTTP_404" });

  // Un mensaje mal armado no tiene sentido reintentarlo.
  assertEquals(
    clasificarRespuesta(400, error(400, "INVALID_ARGUMENT", undefined, "Invalid value at 'message.data'")),
    { resultado: "DESCARTAR", codigo: "INVALID_ARGUMENT" },
  );
  assertEquals(clasificarRespuesta(400, error(400, "FAILED_PRECONDITION")), {
    resultado: "DESCARTAR",
    codigo: "FAILED_PRECONDITION",
  });

  // Lo transitorio o de configuración se reintenta.
  for (
    const [estado, status] of [[429, "RESOURCE_EXHAUSTED"], [500, "INTERNAL"], [503, "UNAVAILABLE"], [
      401,
      "UNAUTHENTICATED",
    ]] as const
  ) {
    assertEquals(clasificarRespuesta(estado, error(estado, status)), { resultado: "REINTENTAR", codigo: status });
  }
  assertEquals(clasificarRespuesta(403, error(403, "PERMISSION_DENIED")), {
    resultado: "REINTENTAR",
    codigo: "PERMISSION_DENIED",
  });
  assertEquals(clasificarRespuesta(502, "<html>Bad gateway</html>"), { resultado: "REINTENTAR", codigo: "HTTP_502" });
});

Deno.test("armarMensaje · solo datos, con lo que hace falta para llegar con la app cerrada", () => {
  const datos = { type: "agenda_manana", event_id: "01920000-0000-7000-8000-000000000001" };
  const { message } = armarMensaje("token-123", datos);
  assertEquals(message.token, "token-123");
  assertEquals(message.data, datos);
  assertEquals(message.android.priority, "HIGH");
  assertEquals(message.apns.payload.aps["content-available"], 1);
  assertEquals(message.apns.headers["apns-priority"], "5");
  // «Push fondo» (pregunta abierta para Cristian): mientras tanto, nada de título ni cuerpo del servidor.
  assert(!("notification" in message), "sin bloque notification: el texto lo arma la app");
  assert(!("notification" in message.android) && !("alert" in message.apns.payload.aps));
});

/** Un `fetch` falso de Google: el token de acceso y el envío. */
function googleFalso(
  opciones: { expiraEn?: number; fcm?: () => Response | Promise<Response>; token?: () => Response } = {},
) {
  const pedidos: { url: string; autorizacion: string | null; cuerpo: string }[] = [];
  let tokensEmitidos = 0;
  const falso: typeof fetch = (entrada, init) => {
    const url = String(entrada);
    const cabeceras = new Headers(init?.headers);
    pedidos.push({ url, autorizacion: cabeceras.get("Authorization"), cuerpo: String(init?.body ?? "") });
    if (url === URL_DEL_TOKEN_DE_ACCESO) {
      if (opciones.token) return Promise.resolve(opciones.token());
      tokensEmitidos++;
      return Promise.resolve(
        new Response(
          JSON.stringify({ access_token: `acceso-${tokensEmitidos}`, expires_in: opciones.expiraEn ?? 3600 }),
        ),
      );
    }
    return Promise.resolve(opciones.fcm ? opciones.fcm() : new Response(JSON.stringify({ name: "m/1" })));
  };
  return { falso, pedidos, tokens: () => tokensEmitidos };
}

const DATOS = { type: "agenda_manana", event_id: "01920000-0000-7000-8000-000000000001" };

Deno.test("ClienteFcm · manda a la URL del proyecto con el token de acceso y el mensaje", async () => {
  const { cuenta } = await cuentaDePrueba();
  const g = googleFalso();
  const cliente = new ClienteFcm(cuenta, g.falso, () => AHORA);

  assertEquals(await cliente.enviar("token-del-telefono", DATOS), { resultado: "ENVIADO" });
  const envio = g.pedidos.at(-1)!;
  assertEquals(envio.url, "https://fcm.googleapis.com/v1/projects/colportores-prueba/messages:send");
  assertEquals(envio.autorizacion, "Bearer acceso-1");
  assertEquals(JSON.parse(envio.cuerpo), armarMensaje("token-del-telefono", DATOS));

  const pedidoDelToken = g.pedidos[0];
  assertEquals(pedidoDelToken.url, URL_DEL_TOKEN_DE_ACCESO);
  const formulario = new URLSearchParams(pedidoDelToken.cuerpo);
  assertEquals(formulario.get("grant_type"), "urn:ietf:params:oauth:grant-type:jwt-bearer");
  assertEquals(formulario.get("assertion")!.split(".").length, 3, "el JWT firmado");
});

Deno.test("ClienteFcm · reutiliza el token de acceso hasta un minuto antes de que venza", async () => {
  const { cuenta } = await cuentaDePrueba();
  const g = googleFalso({ expiraEn: 3600 });
  let ahora = AHORA;
  const cliente = new ClienteFcm(cuenta, g.falso, () => ahora);

  await cliente.enviar("t", DATOS);
  await cliente.enviar("t", DATOS);
  assertEquals(g.tokens(), 1, "dos envíos, un solo token de acceso");

  ahora = new Date(AHORA.getTime() + 3600_000 - 61_000);
  await cliente.enviar("t", DATOS);
  assertEquals(g.tokens(), 1, "a 61 segundos de vencer todavía sirve");

  ahora = new Date(AHORA.getTime() + 3600_000 - 59_000);
  await cliente.enviar("t", DATOS);
  assertEquals(g.tokens(), 2, "a menos de un minuto de vencer pide uno nuevo");
  assertEquals(g.pedidos.at(-1)!.autorizacion, "Bearer acceso-2");
});

Deno.test("ClienteFcm · un 401 de FCM descarta el token de acceso y el próximo envío pide otro", async () => {
  const { cuenta } = await cuentaDePrueba();
  let primera = true;
  const g = googleFalso({
    fcm: () => {
      if (primera) {
        primera = false;
        return new Response(JSON.stringify({ error: { code: 401, status: "UNAUTHENTICATED" } }), { status: 401 });
      }
      return new Response("{}");
    },
  });
  const cliente = new ClienteFcm(cuenta, g.falso, () => AHORA);

  assertEquals(await cliente.enviar("t", DATOS), { resultado: "REINTENTAR", codigo: "UNAUTHENTICATED" });
  assertEquals(await cliente.enviar("t", DATOS), { resultado: "ENVIADO" });
  assertEquals(g.tokens(), 2);
});

Deno.test("ClienteFcm · si Google no da el token de acceso, se reintenta y no se manda nada", async () => {
  const { cuenta } = await cuentaDePrueba();
  for (
    const token of [
      () => new Response("{}", { status: 400 }),
      () => new Response("no es json"),
      () => new Response(JSON.stringify({ expires_in: 3600 })),
    ]
  ) {
    const g = googleFalso({ token });
    const cliente = new ClienteFcm(cuenta, g.falso, () => AHORA);
    assertEquals(await cliente.enviar("t", DATOS), { resultado: "REINTENTAR", codigo: "FCM_AUTH" });
    assert(g.pedidos.every((p) => p.url === URL_DEL_TOKEN_DE_ACCESO), "ningún mensaje salió a FCM");
  }

  const sinRed: typeof fetch = () => Promise.reject(new TypeError("sin red"));
  assertEquals(await new ClienteFcm(cuenta, sinRed, () => AHORA).enviar("t", DATOS), {
    resultado: "REINTENTAR",
    codigo: "FCM_AUTH",
  });

  const claveRota = { ...cuenta, private_key: "-----BEGIN PRIVATE KEY-----\nAAAA\n-----END PRIVATE KEY-----" };
  assertEquals(await new ClienteFcm(claveRota, googleFalso().falso, () => AHORA).enviar("t", DATOS), {
    resultado: "REINTENTAR",
    codigo: "FCM_AUTH",
  });
});

Deno.test("ClienteFcm · si FCM no contesta, se reintenta; nunca lanza", async () => {
  const { cuenta } = await cuentaDePrueba();
  const fcmCaido: typeof fetch = (entrada) =>
    String(entrada) === URL_DEL_TOKEN_DE_ACCESO
      ? Promise.resolve(new Response(JSON.stringify({ access_token: "a", expires_in: 3600 })))
      : Promise.reject(new TypeError("sin red"));
  assertEquals(await new ClienteFcm(cuenta, fcmCaido, () => AHORA).enviar("t", DATOS), {
    resultado: "REINTENTAR",
    codigo: "RED",
  });

  const g = googleFalso({ fcm: () => new Response("<html>", { status: 503 }) });
  assertEquals(await new ClienteFcm(cuenta, g.falso, () => AHORA).enviar("t", DATOS), {
    resultado: "REINTENTAR",
    codigo: "HTTP_503",
  });
  assertNotEquals(g.pedidos.length, 0);
});
