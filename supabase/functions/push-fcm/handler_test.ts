import { assert, assertEquals, assertStringIncludes } from "@std/assert";

import { type CuentaDeServicio, URL_DEL_TOKEN_DE_ACCESO } from "./fcm.ts";
import {
  AVISOS_POR_VUELTA,
  datosPermitidos,
  type Dependencias,
  ENVIOS_A_LA_VEZ,
  igualesSinFiltrar,
  manejar,
  VUELTAS_MAXIMAS,
} from "./handler.ts";

const URL_DE_LA_API = "https://proyecto.supabase.test";
const CLAVE_DE_SERVICIO = "clave-de-servicio-que-no-puede-salir";
const CLAVE_PUSH = "clave-compartida-que-no-puede-salir";
const AHORA = new Date("2026-11-04T15:00:00Z");
const EVENTO = (n: number) => `01920000-0000-7000-8000-${n.toString(16).padStart(12, "0")}`;
const PEDIDO = "01920000-0000-7000-8000-0000000000aa";

let cuentaCache: CuentaDeServicio | null = null;
async function cuentaDePrueba(): Promise<CuentaDeServicio> {
  if (cuentaCache) return cuentaCache;
  const par = await crypto.subtle.generateKey(
    { name: "RSASSA-PKCS1-v1_5", modulusLength: 2048, publicExponent: new Uint8Array([1, 0, 1]), hash: "SHA-256" },
    true,
    ["sign", "verify"],
  );
  const base64 = btoa(String.fromCharCode(...new Uint8Array(await crypto.subtle.exportKey("pkcs8", par.privateKey))));
  cuentaCache = {
    project_id: "colportores-prueba",
    client_email: "push@colportores-prueba.iam.gserviceaccount.com",
    private_key: `-----BEGIN PRIVATE KEY-----\n${base64.match(/.{1,64}/g)!.join("\n")}\n-----END PRIVATE KEY-----\n`,
  };
  return cuentaCache;
}

interface Fila {
  evento_id: string;
  token: string;
  datos: unknown;
  intento: number;
}

/** Un aviso de pedido autorizado tal como lo entrega `push_tomar_pendientes`. */
function fila(n: number, extra: Partial<Fila> = {}): Fila {
  return {
    evento_id: EVENTO(n),
    token: `token-del-telefono-${n}`,
    datos: { type: "pedido_autorizado", event_id: EVENTO(n), pedido_id: PEDIDO },
    intento: 1,
    ...extra,
  };
}

interface Resultado {
  p_evento_id: string;
  p_resultado: string;
  p_token: string | null;
  p_error: string | null;
}

interface Escenario {
  /** Lo que contesta `push_tomar_pendientes` en cada vuelta (la última se repite vacía). */
  vueltas?: Fila[][];
  /** Lo que contesta FCM por token. */
  fcm?: (token: string) => Response | Promise<Response>;
  /** Hace fallar `push_resultado` de ciertos eventos. */
  fallaAlContar?: (evento: string) => boolean;
  /** Hace fallar la lectura de la cola. */
  fallaAlLeer?: boolean;
}

async function armar(escenario: Escenario = {}, ajustes: Partial<Dependencias> = {}) {
  const resultados: Resultado[] = [];
  const pedidosAFcm: { token: string; data: Record<string, string> }[] = [];
  const tomas: unknown[] = [];
  let enVuelo = 0;
  let maximoEnVuelo = 0;
  const vueltas = [...(escenario.vueltas ?? [])];

  const falso: typeof fetch = async (entrada, init) => {
    const url = String(entrada);
    const cabeceras = new Headers(init?.headers);
    if (url === URL_DEL_TOKEN_DE_ACCESO) {
      return new Response(JSON.stringify({ access_token: "acceso", expires_in: 3600 }));
    }
    if (url.startsWith("https://fcm.googleapis.com/")) {
      const mensaje = JSON.parse(String(init?.body)).message;
      pedidosAFcm.push({ token: mensaje.token, data: mensaje.data });
      enVuelo++;
      maximoEnVuelo = Math.max(maximoEnVuelo, enVuelo);
      await new Promise((r) => setTimeout(r, 1));
      enVuelo--;
      return escenario.fcm ? await escenario.fcm(mensaje.token) : new Response(JSON.stringify({ name: "m/1" }));
    }
    // PostgREST: siempre con la clave de servicio.
    assertEquals(cabeceras.get("apikey"), CLAVE_DE_SERVICIO);
    assertEquals(cabeceras.get("Authorization"), `Bearer ${CLAVE_DE_SERVICIO}`);
    const nombre = url.slice(`${URL_DE_LA_API}/rest/v1/rpc/`.length);
    const cuerpo = JSON.parse(String(init?.body));
    if (nombre === "push_tomar_pendientes") {
      tomas.push(cuerpo);
      if (escenario.fallaAlLeer) return new Response("{}", { status: 500 });
      return new Response(JSON.stringify(vueltas.shift() ?? []));
    }
    if (nombre === "push_resultado") {
      if (escenario.fallaAlContar?.(cuerpo.p_evento_id)) return new Response("{}", { status: 500 });
      resultados.push(cuerpo);
      return new Response("true");
    }
    throw new Error(`RPC inesperada: ${nombre}`);
  };

  const deps: Dependencias = {
    fetch: falso,
    urlDeLaApi: URL_DE_LA_API,
    claveDeServicio: CLAVE_DE_SERVICIO,
    clavePush: CLAVE_PUSH,
    cuenta: await cuentaDePrueba(),
    ahora: () => AHORA,
    ...ajustes,
  };
  return { deps, resultados, pedidosAFcm, tomas, maximoEnVuelo: () => maximoEnVuelo };
}

function pedido(cabeceras: Record<string, string> = { "x-push-clave": CLAVE_PUSH }, metodo = "POST"): Request {
  return new Request("https://proyecto.supabase.test/functions/v1/push-fcm", {
    method: metodo,
    headers: cabeceras,
    body: metodo === "POST" ? "{}" : undefined,
  });
}

/** Junta lo que la función escribe en el log mientras corre `fn`. */
async function conLog<T>(fn: () => Promise<T>): Promise<{ valor: T; log: string }> {
  const original = console.error;
  const lineas: string[] = [];
  console.error = (...args: unknown[]) => void lineas.push(args.map(String).join(" "));
  try {
    return { valor: await fn(), log: lineas.join("\n") };
  } finally {
    console.error = original;
  }
}

// --- seguridad ------------------------------------------------------------------------------------------------------

Deno.test("solo acepta POST", async () => {
  const { deps } = await armar();
  for (const metodo of ["GET", "PUT", "DELETE"]) {
    const r = await manejar(pedido({ "x-push-clave": CLAVE_PUSH }, metodo), deps);
    assertEquals(r.status, 405);
    assertEquals((await r.json()).error.codigo, "metodo");
  }
});

Deno.test("sin la clave compartida, o con otra, no hace nada", async () => {
  const { deps, tomas } = await armar({ vueltas: [[fila(1)]] });
  for (
    const cabeceras of [{} as Record<string, string>, { "x-push-clave": "" }, { "x-push-clave": "otra" }, {
      "x-push-clave": CLAVE_PUSH + "x",
    }]
  ) {
    const r = await manejar(pedido(cabeceras), deps);
    assertEquals(r.status, 401);
    assertEquals((await r.json()).error.codigo, "no_autorizado");
  }
  assertEquals(tomas.length, 0, "ni siquiera leyó la cola");
});

Deno.test("sin configurar: 503, dice solo los NOMBRES de lo que falta y no toca la cola", async () => {
  const caso = async (ajustes: Partial<Dependencias>, faltante: string) => {
    const { deps, tomas } = await armar({}, ajustes);
    const { valor, log } = await conLog(() => manejar(pedido(), deps));
    assertEquals(valor.status, 503);
    assertEquals((await valor.json()).error.codigo, "sin_configurar");
    assertStringIncludes(log, faltante);
    assert(!log.includes(CLAVE_DE_SERVICIO) && !log.includes(CLAVE_PUSH), "ni un valor en el log");
    assertEquals(tomas.length, 0);
  };
  await caso({ cuenta: null }, "FCM_CUENTA_DE_SERVICIO");
  await caso({ clavePush: "" }, "PUSH_CLAVE");
  await caso({ claveDeServicio: "" }, "SUPABASE_SERVICE_ROLE_KEY");
  await caso({ urlDeLaApi: "" }, "SUPABASE_URL");
});

Deno.test("igualesSinFiltrar · compara textos completos", () => {
  assert(igualesSinFiltrar("abc", "abc"));
  assert(igualesSinFiltrar("", ""));
  assert(!igualesSinFiltrar("abc", "abd"));
  assert(!igualesSinFiltrar("abc", "abcd"));
  assert(!igualesSinFiltrar("abcd", "abc"));
  assert(!igualesSinFiltrar("", "a"));
});

// --- el payload -----------------------------------------------------------------------------------------------------

Deno.test("datosPermitidos · solo el tipo, el event_id y UUIDs de las claves conocidas", () => {
  const evento = EVENTO(1);
  assertEquals(datosPermitidos({ type: "agenda_manana", event_id: evento }), {
    type: "agenda_manana",
    event_id: evento,
  });
  assertEquals(
    datosPermitidos({ type: "asignacion_campania", event_id: evento, campania_id: PEDIDO, zona_id: PEDIDO }),
    { type: "asignacion_campania", event_id: evento, campania_id: PEDIDO, zona_id: PEDIDO },
  );

  assertEquals(datosPermitidos(null), null);
  assertEquals(datosPermitidos("texto"), null);
  assertEquals(datosPermitidos([]), null);
  assertEquals(datosPermitidos({ type: "agenda_manana" }), null, "sin event_id");
  assertEquals(datosPermitidos({ event_id: evento }), null, "sin tipo");
  assertEquals(datosPermitidos({ type: "tipo_raro", event_id: evento }), null, "un tipo que la app no conoce");
  assertEquals(datosPermitidos({ type: "agenda_manana", event_id: "no-es-uuid" }), null);
  assertEquals(datosPermitidos({ type: "agenda_manana", event_id: evento, nombre: "Ana" }), null, "un nombre jamás");
  assertEquals(datosPermitidos({ type: "agenda_manana", event_id: evento, monto: "1000" }), null, "ni un monto");
  assertEquals(datosPermitidos({ type: "pedido_autorizado", event_id: evento, pedido_id: "Ana Pérez" }), null);
  assertEquals(datosPermitidos({ type: "agenda_manana", event_id: evento, pedido_id: 5 }), null, "todo es texto");
});

// --- el flujo -------------------------------------------------------------------------------------------------------

Deno.test("manda cada aviso a FCM con su token y su payload, y cuenta el resultado", async () => {
  const { deps, resultados, pedidosAFcm } = await armar({ vueltas: [[fila(1), fila(2)]] });
  const r = await manejar(pedido(), deps);

  assertEquals(r.status, 200);
  assertEquals(await r.json(), {
    tomados: 2,
    enviados: 2,
    reintentos: 0,
    tokens_invalidos: 0,
    descartados: 0,
    sin_contar: 0,
  });
  assertEquals(pedidosAFcm.map((p) => p.token).sort(), ["token-del-telefono-1", "token-del-telefono-2"]);
  assertEquals(pedidosAFcm.find((p) => p.token === "token-del-telefono-1")!.data, {
    type: "pedido_autorizado",
    event_id: EVENTO(1),
    pedido_id: PEDIDO,
  });
  assertEquals(
    resultados.map((x) => [x.p_evento_id, x.p_resultado, x.p_token, x.p_error]).sort(),
    [[EVENTO(1), "ENVIADO", null, null], [EVENTO(2), "ENVIADO", null, null]],
  );
});

Deno.test("cada resultado de FCM llega a la base con su nombre; el token solo viaja si FCM lo rechazó", async () => {
  const respuestas: Record<string, Response> = {
    "token-del-telefono-1": new Response("{}"),
    "token-del-telefono-2": new Response(
      JSON.stringify({ error: { status: "NOT_FOUND", details: [{ errorCode: "UNREGISTERED" }] } }),
      { status: 404 },
    ),
    "token-del-telefono-3": new Response(JSON.stringify({ error: { status: "UNAVAILABLE" } }), { status: 503 }),
    "token-del-telefono-4": new Response(
      JSON.stringify({ error: { status: "INVALID_ARGUMENT", message: "Invalid value at 'message.data'" } }),
      { status: 400 },
    ),
  };
  const { deps, resultados } = await armar({
    vueltas: [[fila(1), fila(2), fila(3), fila(4)]],
    fcm: (token) => respuestas[token].clone(),
  });
  const r = await manejar(pedido(), deps);

  assertEquals(await r.json(), {
    tomados: 4,
    enviados: 1,
    reintentos: 1,
    tokens_invalidos: 1,
    descartados: 1,
    sin_contar: 0,
  });
  const de = (n: number) => resultados.find((x) => x.p_evento_id === EVENTO(n))!;
  assertEquals(de(1), { p_evento_id: EVENTO(1), p_resultado: "ENVIADO", p_token: null, p_error: null });
  assertEquals(de(2), {
    p_evento_id: EVENTO(2),
    p_resultado: "TOKEN_INVALIDO",
    p_token: "token-del-telefono-2",
    p_error: "UNREGISTERED",
  });
  assertEquals(de(3), { p_evento_id: EVENTO(3), p_resultado: "REINTENTAR", p_token: null, p_error: "UNAVAILABLE" });
  assertEquals(de(4), { p_evento_id: EVENTO(4), p_resultado: "DESCARTAR", p_token: null, p_error: "INVALID_ARGUMENT" });
});

Deno.test("un payload con algo de más no sale: se descarta sin llamar a FCM", async () => {
  const sucio = fila(1, {
    datos: { type: "pedido_autorizado", event_id: EVENTO(1), pedido_id: PEDIDO, nombre: "Ana" },
  });
  const { deps, resultados, pedidosAFcm } = await armar({ vueltas: [[sucio, fila(2, { datos: null })]] });
  const { valor } = await conLog(() => manejar(pedido(), deps));

  assertEquals((await valor.json()).descartados, 2);
  assertEquals(pedidosAFcm.length, 0, "nada salió a FCM");
  assertEquals(resultados.map((x) => [x.p_resultado, x.p_error]), [["DESCARTAR", "PAYLOAD_INVALIDO"], [
    "DESCARTAR",
    "PAYLOAD_INVALIDO",
  ]]);
});

Deno.test("si no puede contar el resultado lo anota y sigue con los demás", async () => {
  const { deps, resultados } = await armar({
    vueltas: [[fila(1), fila(2), fila(3)]],
    fallaAlContar: (evento) => evento === EVENTO(2),
  });
  const { valor, log } = await conLog(() => manejar(pedido(), deps));

  assertEquals(valor.status, 200);
  assertEquals(await valor.json(), {
    tomados: 3,
    enviados: 2,
    reintentos: 0,
    tokens_invalidos: 0,
    descartados: 0,
    sin_contar: 1,
  });
  assertEquals(resultados.length, 2);
  assertStringIncludes(log, "push-fcm.sin_contar");
});

Deno.test("sin avisos listos no manda nada", async () => {
  const { deps, pedidosAFcm, tomas } = await armar({ vueltas: [[]] });
  const r = await manejar(pedido(), deps);
  assertEquals(await r.json(), {
    tomados: 0,
    enviados: 0,
    reintentos: 0,
    tokens_invalidos: 0,
    descartados: 0,
    sin_contar: 0,
  });
  assertEquals(pedidosAFcm.length, 0);
  assertEquals(tomas, [{ p_max: AVISOS_POR_VUELTA }]);
});

Deno.test("si la base no contesta al leer la cola: 502", async () => {
  const { deps, pedidosAFcm } = await armar({ fallaAlLeer: true });
  const { valor, log } = await conLog(() => manejar(pedido(), deps));
  assertEquals(valor.status, 502);
  assertEquals((await valor.json()).error.codigo, "no_se_pudo_leer");
  assertStringIncludes(log, "push-fcm.no_se_pudo_leer");
  assertEquals(pedidosAFcm.length, 0);
});

Deno.test("si hay más de una vuelta de avisos, sigue hasta vaciar la cola, con un tope", async () => {
  const llena = (desde: number) => Array.from({ length: AVISOS_POR_VUELTA }, (_, i) => fila(desde + i));
  const { deps, tomas } = await armar({ vueltas: [llena(100), llena(200), [fila(300)]] });
  const r = await manejar(pedido(), deps);
  assertEquals((await r.json()).enviados, AVISOS_POR_VUELTA * 2 + 1);
  assertEquals(tomas.length, 3, "dos vueltas llenas y una con uno solo, que la cierra");

  const infinita = await armar({ vueltas: Array.from({ length: 10 }, (_, i) => llena(1000 * (i + 1))) });
  await manejar(pedido(), infinita.deps);
  assertEquals(
    infinita.tomas.length,
    VUELTAS_MAXIMAS,
    "no da más vueltas que el tope: lo que quede lo toma el próximo despertar",
  );
});

Deno.test("no manda más de ENVIOS_A_LA_VEZ avisos a la vez", async () => {
  const { deps, maximoEnVuelo, pedidosAFcm } = await armar({
    vueltas: [Array.from({ length: 35 }, (_, i) => fila(i + 1))],
  });
  await manejar(pedido(), deps);
  assertEquals(pedidosAFcm.length, 35);
  assert(maximoEnVuelo() <= ENVIOS_A_LA_VEZ, `llegó a ${maximoEnVuelo()}`);
  assert(maximoEnVuelo() > 1, "y sí manda en paralelo");
});

Deno.test("ni los tokens, ni las claves, ni la cuenta de servicio salen en una respuesta o en el log", async () => {
  const cuenta = await cuentaDePrueba();
  const { deps } = await armar({
    vueltas: [[fila(1), fila(2), fila(3)]],
    fcm: (token) =>
      token.endsWith("2")
        ? new Response(JSON.stringify({ error: { status: "NOT_FOUND", details: [{ errorCode: "UNREGISTERED" }] } }), {
          status: 404,
        })
        : new Response(JSON.stringify({ error: { status: "UNAVAILABLE" } }), { status: 503 }),
  });
  const { valor, log } = await conLog(() => manejar(pedido(), deps));
  const todo = `${await valor.text()}\n${log}`;
  for (
    const secreto of [CLAVE_DE_SERVICIO, CLAVE_PUSH, cuenta.private_key, "token-del-telefono-1", "token-del-telefono-2"]
  ) {
    assert(!todo.includes(secreto), `se coló un secreto: ${secreto.slice(0, 20)}…`);
  }
  assertStringIncludes(log, "push-fcm.no_enviado");
});
