import { assert, assertEquals, assertStringIncludes } from "@std/assert";

import {
  type ConfiguracionDeR2,
  type Dependencias,
  leerPedido,
  manejar,
  MAXIMO_DE_LA_FOTO,
  SEGUNDOS_PARA_SUBIR,
  SEGUNDOS_PARA_VER,
} from "./handler.ts";

const URL_DE_LA_API = "https://proyecto.supabase.test";
const CLAVE_PUBLICA = "clave-publica-de-prueba";
const AHORA = new Date("2026-10-28T15:00:00Z");
const JWT = "Bearer jwt-de-la-colportora";
const TICKET = "01920000-0000-7000-8000-0000000000aa";
const USUARIO = "01920000-0000-7000-8000-000000000001";

const R2: ConfiguracionDeR2 = {
  cuenta: "cuenta123",
  claveDeAcceso: "ACCESO-DE-PRUEBA",
  claveSecreta: "secreto-que-no-puede-salir",
  bucket: "fotos-tickets",
};

interface PedidoRegistrado {
  url: string;
  autorizacion: string | null;
  apikey: string | null;
  cuerpo: unknown;
}

/** Lo que contesta la base a una RPC: un valor (200) o un error de PostgREST con su SQLSTATE. */
type Respuesta = { ok: unknown } | { code: string; status: number } | "sin-red" | "no-json";

/** Un `fetch` que contesta como PostgREST y anota qué se le pidió. */
/** `headR2`: lo que contesta R2 al HEAD previo a una subida (404 = la foto no está). */
function dependenciasDe(
  respuestas: Record<string, Respuesta>,
  ajustes: Partial<Dependencias> = {},
  headR2: number | "sin-red" = 404,
) {
  const pedidos: PedidoRegistrado[] = [];
  const pedidosR2: { url: string; metodo: string }[] = [];
  const fetchFalso: typeof fetch = (entrada, init) => {
    const url = String(entrada);
    if (url.includes(".r2.cloudflarestorage.com")) {
      pedidosR2.push({ url, metodo: init?.method ?? "GET" });
      if (headR2 === "sin-red") return Promise.reject(new TypeError("sin red"));
      return Promise.resolve(new Response(null, { status: headR2 }));
    }
    const cabeceras = new Headers(init?.headers);
    pedidos.push({
      url,
      autorizacion: cabeceras.get("Authorization"),
      apikey: cabeceras.get("apikey"),
      cuerpo: JSON.parse(String(init?.body ?? "{}")),
    });
    const nombre = url.slice(`${URL_DE_LA_API}/rest/v1/rpc/`.length);
    const r = respuestas[nombre];
    if (r === undefined) throw new Error(`la función no debía llamar a ${nombre}`);
    if (r === "sin-red") return Promise.reject(new TypeError("sin red"));
    if (r === "no-json") return Promise.resolve(new Response("<html>", { status: 200 }));
    if ("ok" in r) {
      return Promise.resolve(
        new Response(JSON.stringify(r.ok), { status: 200, headers: { "Content-Type": "application/json" } }),
      );
    }
    return Promise.resolve(
      new Response(JSON.stringify({ code: r.code, message: "mensaje de la base" }), {
        status: r.status,
        headers: { "Content-Type": "application/json" },
      }),
    );
  };
  const dependencias: Dependencias = {
    fetch: fetchFalso,
    urlDeLaApi: URL_DE_LA_API,
    clavePublica: CLAVE_PUBLICA,
    r2: R2,
    ahora: () => AHORA,
    ...ajustes,
  };
  return { dependencias, pedidos, pedidosR2 };
}

function pedido(cuerpo: unknown, cabeceras: Record<string, string> = { Authorization: JWT }, metodo = "POST") {
  return new Request("https://proyecto.supabase.test/functions/v1/foto-ticket", {
    method: metodo,
    headers: { "Content-Type": "application/json", ...cabeceras },
    body: metodo === "POST" ? (typeof cuerpo === "string" ? cuerpo : JSON.stringify(cuerpo)) : undefined,
  });
}

const VER = { accion: "ver", ticketId: TICKET };
const SUBIR = { accion: "subir", ticketId: TICKET, tipoDeImagen: "image/jpeg", bytes: 180_000 };
const RUTA = `${USUARIO}/${TICKET}.jpg`;

async function error(respuesta: Response) {
  assertEquals(respuesta.headers.get("Content-Type"), "application/json; charset=utf-8");
  assertEquals(respuesta.headers.get("Cache-Control"), "no-store");
  const cuerpo = await respuesta.json();
  return cuerpo.error as { codigo: string; mensaje: string };
}

/** Anota lo que la función escribe en el log, para comprobar que no filtra nada. */
async function conLog<T>(f: () => Promise<T>): Promise<{ resultado: T; log: string[] }> {
  const original = console.error;
  const log: string[] = [];
  console.error = (...partes: unknown[]) => log.push(partes.map(String).join(" "));
  try {
    return { resultado: await f(), log };
  } finally {
    console.error = original;
  }
}

// --- ver ---------------------------------------------------------------------------------------------------------

Deno.test("ver · pide la ruta a la base con la sesión de quien pide y devuelve un enlace GET que vence en minutos", async () => {
  const { dependencias, pedidos } = dependenciasDe({ ruta_para_ver_foto_de_ticket: { ok: RUTA } });
  const respuesta = await manejar(pedido(VER), dependencias);
  assertEquals(respuesta.status, 200);
  assertEquals(respuesta.headers.get("Cache-Control"), "no-store");
  const cuerpo = await respuesta.json();
  assertEquals(cuerpo.accion, "ver");
  assertEquals(cuerpo.metodo, "GET");
  assertEquals(cuerpo.ruta, RUTA);
  assertEquals(cuerpo.cabeceras, {});
  assertEquals(cuerpo.venceEn, new Date(AHORA.getTime() + SEGUNDOS_PARA_VER * 1000).toISOString());
  assert(SEGUNDOS_PARA_VER <= 600, "el enlace de ver vence en minutos");

  const url = new URL(cuerpo.url);
  assertEquals(url.host, "cuenta123.r2.cloudflarestorage.com");
  assertEquals(url.pathname, `/fotos-tickets/${RUTA}`);
  assertEquals(url.searchParams.get("X-Amz-Expires"), String(SEGUNDOS_PARA_VER));
  assertEquals(url.searchParams.get("X-Amz-SignedHeaders"), "host");
  assert(/^[0-9a-f]{64}$/.test(url.searchParams.get("X-Amz-Signature") ?? ""));

  // La base recibió el JWT de la persona (manda la RLS), la clave pública y el id del ticket; nada más.
  assertEquals(pedidos.length, 1);
  assertEquals(pedidos[0].url, `${URL_DE_LA_API}/rest/v1/rpc/ruta_para_ver_foto_de_ticket`);
  assertEquals(pedidos[0].autorizacion, JWT);
  assertEquals(pedidos[0].apikey, CLAVE_PUBLICA);
  assertEquals(pedidos[0].cuerpo, { p_ticket_id: TICKET });
});

Deno.test("ver · la ruta la da la base, no el pedido: el cuerpo no puede nombrar otra", async () => {
  const { dependencias } = dependenciasDe({ ruta_para_ver_foto_de_ticket: { ok: RUTA } });
  const respuesta = await manejar(pedido({ ...VER, ruta: "otro/usuario.jpg" }), dependencias);
  assertEquals((await respuesta.json()).ruta, RUTA);
});

Deno.test("ver · lo que la base contesta con su SQLSTATE llega como el aviso que corresponde", async () => {
  const casos: [string, number, string, number][] = [
    ["FT001", 400, "ticket_no_encontrado", 404],
    ["FT002", 400, "sin_foto", 404],
    ["FT003", 400, "foto_vencida", 410],
    ["42501", 403, "sin_sesion", 401],
    ["PGRST301", 401, "sin_sesion", 401],
    ["XX000", 500, "no_se_pudo_leer", 502],
  ];
  for (const [code, status, codigo, http] of casos) {
    const { dependencias } = dependenciasDe({ ruta_para_ver_foto_de_ticket: { code, status } });
    const { resultado, log } = await conLog(() => manejar(pedido(VER), dependencias));
    assertEquals(resultado.status, http, code);
    const e = await error(resultado);
    assertEquals(e.codigo, codigo, code);
    assert(e.mensaje.length > 20, "el aviso dice qué pasó y qué hacer");
    // El log lleva el tipo de falla y el código, nunca el ticket ni la ruta.
    assertEquals(log.length, 1);
    assert(!log[0].includes(TICKET) && !log[0].includes(USUARIO), log[0]);
  }
});

Deno.test("ver · el aviso de la foto vencida dice que los datos del ticket siguen", async () => {
  const { dependencias } = dependenciasDe({ ruta_para_ver_foto_de_ticket: { code: "FT003", status: 400 } });
  const { resultado } = await conLog(() => manejar(pedido(VER), dependencias));
  assertStringIncludes((await error(resultado)).mensaje, "ya venció");
});

Deno.test("ver · sin red a la base, o con una respuesta que no es JSON, no se firma nada", async () => {
  for (const respuesta of ["sin-red", "no-json"] as const) {
    const { dependencias } = dependenciasDe({ ruta_para_ver_foto_de_ticket: respuesta });
    const { resultado } = await conLog(() => manejar(pedido(VER), dependencias));
    assertEquals(resultado.status, 502, respuesta);
    assertEquals((await error(resultado)).codigo, "no_se_pudo_leer");
  }
});

Deno.test("ver · una ruta vacía o que no es texto no se firma", async () => {
  for (const ok of ["", null, 7, { ruta: RUTA }]) {
    const { dependencias } = dependenciasDe({ ruta_para_ver_foto_de_ticket: { ok } });
    const { resultado } = await conLog(() => manejar(pedido(VER), dependencias));
    assertEquals(resultado.status, 502, JSON.stringify(ok));
  }
});

// --- subir ---------------------------------------------------------------------------------------------------------

Deno.test("subir · devuelve un enlace PUT que ata el tipo y el largo, y la ruta que va en url_cloud", async () => {
  const { dependencias, pedidos } = dependenciasDe({ ruta_para_subir_foto_de_ticket: { ok: RUTA } });
  const respuesta = await manejar(pedido(SUBIR), dependencias);
  assertEquals(respuesta.status, 200);
  const cuerpo = await respuesta.json();
  assertEquals(cuerpo.accion, "subir");
  assertEquals(cuerpo.metodo, "PUT");
  assertEquals(cuerpo.ruta, RUTA);
  assertEquals(cuerpo.cabeceras, { "Content-Type": "image/jpeg", "Content-Length": "180000" });
  assertEquals(cuerpo.venceEn, new Date(AHORA.getTime() + SEGUNDOS_PARA_SUBIR * 1000).toISOString());
  assert(SEGUNDOS_PARA_SUBIR <= 900, "el enlace de subir también vence en minutos");

  const url = new URL(cuerpo.url);
  assertEquals(url.pathname, `/fotos-tickets/${RUTA}`);
  assertEquals(url.searchParams.get("X-Amz-SignedHeaders"), "content-length;content-type;host");
  assertEquals(url.searchParams.get("X-Amz-Expires"), String(SEGUNDOS_PARA_SUBIR));

  assertEquals(pedidos[0].url, `${URL_DE_LA_API}/rest/v1/rpc/ruta_para_subir_foto_de_ticket`);
  assertEquals(pedidos[0].autorizacion, JWT);
  assertEquals(pedidos[0].cuerpo, { p_ticket_id: TICKET, p_extension: "jpg" });
});

Deno.test("subir · cada tipo de imagen pide su extensión", async () => {
  for (const [tipo, extension] of [["image/jpeg", "jpg"], ["image/png", "png"], ["image/webp", "webp"]]) {
    const { dependencias, pedidos } = dependenciasDe({
      ruta_para_subir_foto_de_ticket: { ok: `${USUARIO}/${TICKET}.${extension}` },
    });
    const respuesta = await manejar(pedido({ ...SUBIR, tipoDeImagen: tipo }), dependencias);
    assertEquals(respuesta.status, 200, tipo);
    assertEquals((pedidos[0].cuerpo as { p_extension: string }).p_extension, extension);
    assertEquals((await respuesta.json()).cabeceras["Content-Type"], tipo);
  }
});

Deno.test("subir · el borde del tope: 2 MiB entra, un byte más no; 0 y negativos no", async () => {
  const { dependencias } = dependenciasDe({ ruta_para_subir_foto_de_ticket: { ok: RUTA } });
  assertEquals((await manejar(pedido({ ...SUBIR, bytes: MAXIMO_DE_LA_FOTO }), dependencias)).status, 200);
  const grande = await manejar(pedido({ ...SUBIR, bytes: MAXIMO_DE_LA_FOTO + 1 }), dependencias);
  assertEquals(grande.status, 413);
  assertEquals((await error(grande)).codigo, "foto_muy_grande");
  for (const bytes of [0, -5, 1.5, "100", null, Number.NaN]) {
    assertEquals((await manejar(pedido({ ...SUBIR, bytes }), dependencias)).status, 400, String(bytes));
  }
});

Deno.test("subir · solo imágenes JPG, PNG y WebP", async () => {
  const { dependencias, pedidos } = dependenciasDe({});
  for (const tipo of ["image/gif", "application/pdf", "text/html", "image/jpeg; charset=utf-8", "IMAGE/JPEG", ""]) {
    const respuesta = await manejar(pedido({ ...SUBIR, tipoDeImagen: tipo }), dependencias);
    assertEquals(respuesta.status, 415, tipo);
    assertEquals((await error(respuesta)).codigo, "tipo_no_permitido");
  }
  assertEquals(pedidos.length, 0, "ni siquiera se le pregunta a la base");
});

Deno.test("subir · la base dice que la foto ya venció o que no hay sesión", async () => {
  for (const [code, codigo] of [["FT003", "foto_vencida"], ["42501", "sin_sesion"]]) {
    const { dependencias } = dependenciasDe({ ruta_para_subir_foto_de_ticket: { code, status: 400 } });
    const { resultado } = await conLog(() => manejar(pedido(SUBIR), dependencias));
    assertEquals((await error(resultado)).codigo, codigo);
  }
});

// --- el pedido ----------------------------------------------------------------------------------------------------

Deno.test("pedido · lo que no es válido se rechaza sin llamar a la base ni firmar", async () => {
  const { dependencias, pedidos } = dependenciasDe({});
  const invalidos: unknown[] = [
    "no es json",
    "[]",
    "null",
    "{}",
    { accion: "borrar", ticketId: TICKET },
    { accion: "ver" },
    { accion: "ver", ticketId: "no-es-uuid" },
    { accion: "ver", ticketId: TICKET.toUpperCase() },
    { accion: "ver", ticketId: `${TICKET}/../x` },
    { accion: "ver", ticketId: 7 },
    { accion: "subir", ticketId: TICKET },
    { accion: "subir", ticketId: TICKET, tipoDeImagen: 7, bytes: 10 },
  ];
  for (const cuerpo of invalidos) {
    const respuesta = await manejar(pedido(cuerpo), dependencias);
    assertEquals(respuesta.status, 400, JSON.stringify(cuerpo));
    assertEquals((await error(respuesta)).codigo, "pedido_invalido");
  }
  assertEquals(pedidos.length, 0);
});

Deno.test("pedido · leerPedido separa los dos pedidos", () => {
  assertEquals(leerPedido(VER), { accion: "ver", ticketId: TICKET });
  assertEquals(leerPedido(SUBIR), { accion: "subir", ticketId: TICKET, tipoDeImagen: "image/jpeg", bytes: 180_000 });
  assertEquals(
    leerPedido({ accion: "subir", ticketId: TICKET, tipoDeImagen: "image/gif", bytes: 1 }),
    "tipo_no_permitido",
  );
});

Deno.test("pedido · un cuerpo demasiado grande se corta (por el largo declarado y por el real)", async () => {
  const { dependencias } = dependenciasDe({});
  const grande = JSON.stringify({ ...VER, relleno: "x".repeat(2000) });
  assertEquals((await manejar(pedido(grande), dependencias)).status, 413);
  const declarado = pedido(VER, { Authorization: JWT, "Content-Length": "5000" });
  assertEquals((await manejar(declarado, dependencias)).status, 413);
});

Deno.test("sesión · sin Authorization o con algo que no es Bearer: 401 sin llamar a nadie", async () => {
  const { dependencias, pedidos } = dependenciasDe({});
  for (
    const cabeceras of [{} as Record<string, string>, { Authorization: "" }, { Authorization: "Basic abc" }, {
      Authorization: "Bearer",
    }]
  ) {
    const respuesta = await manejar(pedido(VER, cabeceras), dependencias);
    assertEquals(respuesta.status, 401, JSON.stringify(cabeceras));
    assertEquals((await error(respuesta)).codigo, "sin_sesion");
  }
  assertEquals(pedidos.length, 0);
});

Deno.test("método · solo POST; OPTIONS contesta el CORS", async () => {
  const { dependencias } = dependenciasDe({});
  const get = await manejar(pedido(null, { Authorization: JWT }, "GET"), dependencias);
  assertEquals(get.status, 405);
  assertEquals((await error(get)).codigo, "metodo");

  const opciones = await manejar(
    new Request("https://proyecto.supabase.test/functions/v1/foto-ticket", { method: "OPTIONS" }),
    dependencias,
  );
  assertEquals(opciones.status, 204);
  assertEquals(opciones.headers.get("Access-Control-Allow-Origin"), "*");
  assertStringIncludes(opciones.headers.get("Access-Control-Allow-Headers") ?? "", "authorization");
});

// --- los secretos de R2 ----------------------------------------------------------------------------------------------

Deno.test("secretos · sin las claves de R2 la función dice que no está disponible y no llama a la base", async () => {
  const { dependencias, pedidos } = dependenciasDe({}, { r2: null });
  for (const cuerpo of [VER, SUBIR]) {
    const respuesta = await manejar(pedido(cuerpo), dependencias);
    assertEquals(respuesta.status, 503);
    assertEquals((await error(respuesta)).codigo, "sin_configurar");
  }
  assertEquals(pedidos.length, 0);
});

Deno.test("secretos · la clave secreta de R2 no sale en ninguna respuesta ni en ningún log, ni en los errores", async () => {
  const secretos = [R2.claveSecreta, R2.claveDeAcceso];
  const escenarios: Record<string, Respuesta>[] = [
    { ruta_para_ver_foto_de_ticket: { ok: RUTA } },
    { ruta_para_ver_foto_de_ticket: { code: "FT003", status: 400 } },
    { ruta_para_ver_foto_de_ticket: { code: "XX000", status: 500 } },
    { ruta_para_ver_foto_de_ticket: "sin-red" },
  ];
  for (const respuestas of escenarios) {
    const { dependencias } = dependenciasDe(respuestas);
    const { resultado, log } = await conLog(() => manejar(pedido(VER), dependencias));
    const texto = await resultado.text();
    for (const secreto of secretos) {
      // La clave de ACCESO va en el enlace (en la credencial, como siempre en SigV4); la SECRETA nunca.
      if (secreto === R2.claveSecreta) assert(!texto.includes(secreto), "la clave secreta salió en la respuesta");
      assert(!log.join("\n").includes(secreto), "una clave de R2 salió en el log");
    }
    assert(!log.join("\n").includes("X-Amz-Signature"), "un enlace firmado salió en el log");
  }
});

// --- no se pisa una foto ya subida ---------------------------------------------------------------------------------

Deno.test("subir · antes de firmar le pregunta a R2 con un HEAD firmado de corta vida si la foto ya está", async () => {
  const { dependencias, pedidosR2 } = dependenciasDe({ ruta_para_subir_foto_de_ticket: { ok: RUTA } });
  const respuesta = await manejar(pedido(SUBIR), dependencias);
  assertEquals(respuesta.status, 200);
  assertEquals(pedidosR2.length, 1);
  assertEquals(pedidosR2[0].metodo, "HEAD");
  const url = new URL(pedidosR2[0].url);
  assertEquals(url.pathname, `/fotos-tickets/${RUTA}`);
  assertEquals(url.searchParams.get("X-Amz-Expires"), "60");
  // El enlace del HEAD no se le devuelve a nadie: el que sale es el PUT.
  assert((await respuesta.clone().text()).includes("X-Amz-Expires=600"));
  assert(!(await respuesta.text()).includes("X-Amz-Expires=60&"));
});

Deno.test("subir · si la foto ya está en R2: 409 y no se firma ninguna subida", async () => {
  const { dependencias } = dependenciasDe({ ruta_para_subir_foto_de_ticket: { ok: RUTA } }, {}, 200);
  const { resultado, log } = await conLog(() => manejar(pedido(SUBIR), dependencias));
  assertEquals(resultado.status, 409);
  const cuerpo = await resultado.text();
  assertEquals(JSON.parse(cuerpo).error.codigo, "foto_ya_subida");
  assertEquals(JSON.parse(cuerpo).error.mensaje, "Este ticket ya tiene su foto: no se puede cambiar.");
  assert(!cuerpo.includes("X-Amz-Signature"), "no se devolvió ningún enlace");
  assert(!log.join("").includes(TICKET), "el log no lleva el ticket");
});

Deno.test("subir · si R2 no contesta como se espera, ante la duda no se firma", async () => {
  for (const headR2 of [403, 500, 503, "sin-red"] as const) {
    const { dependencias } = dependenciasDe({ ruta_para_subir_foto_de_ticket: { ok: RUTA } }, {}, headR2);
    const { resultado } = await conLog(() => manejar(pedido(SUBIR), dependencias));
    assertEquals(resultado.status, 502, String(headR2));
    assertEquals((await error(resultado)).codigo, "no_se_pudo_comprobar");
  }
});

Deno.test("ver · no hace ningún pedido a R2 (solo firma)", async () => {
  const { dependencias, pedidosR2 } = dependenciasDe({ ruta_para_ver_foto_de_ticket: { ok: RUTA } });
  assertEquals((await manejar(pedido(VER), dependencias)).status, 200);
  assertEquals(pedidosR2.length, 0);
});

Deno.test("subir · si la base niega el permiso, ni siquiera se pregunta a R2", async () => {
  const { dependencias, pedidosR2 } = dependenciasDe(
    { ruta_para_subir_foto_de_ticket: { code: "FT003", status: 400 } },
    {},
    200,
  );
  const { resultado } = await conLog(() => manejar(pedido(SUBIR), dependencias));
  assertEquals((await error(resultado)).codigo, "foto_vencida");
  assertEquals(pedidosR2.length, 0);
});
