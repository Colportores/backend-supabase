import { assert, assertEquals, assertStringIncludes } from "@std/assert";

import { CAMPANIA, colportorQueTrabaja, mundoVacio, uuid } from "./apoyo.ts";
import { textosDelPdf } from "./apoyo_pdf.ts";
import { CLAVE_PUBLICA, dependenciasDe, pedidoDeInforme, URL_DE_LA_API } from "./apoyo_http.ts";
import { leerPedido, manejar, nombreDeArchivo } from "./handler.ts";

const VALIDO = { ambito: { tipo: "todas" }, granularidad: "semana" };

function mundoConDatos() {
  return mundoVacio({
    colportores: [
      colportorQueTrabaja(1, "Ana", "Pérez", "2026-10-05", "2026-10-20"),
      colportorQueTrabaja(2, "Beto", "Álvarez", "2026-10-05", "2026-10-20"),
    ],
    departamentos: { [uuid(10)]: "Rivera" },
  });
}

async function error(respuesta: Response) {
  assertEquals(respuesta.headers.get("Content-Type"), "application/json; charset=utf-8");
  const cuerpo = await respuesta.json();
  return cuerpo.error as { codigo: string; mensaje: string };
}

/** Anota lo que la función escribe en el log, para comprobar que no filtra datos. */
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

Deno.test("handler · devuelve el PDF para bajar, con su nombre y sin guardarlo en ninguna caché", async () => {
  const { dependencias } = dependenciasDe(mundoConDatos());
  const respuesta = await manejar(pedidoDeInforme(VALIDO), dependencias);
  assertEquals(respuesta.status, 200);
  assertEquals(respuesta.headers.get("Content-Type"), "application/pdf");
  assertEquals(
    respuesta.headers.get("Content-Disposition"),
    'attachment; filename="reportes-todas-las-ciudades-semanas-2026-10-21.pdf"',
  );
  assertEquals(respuesta.headers.get("Cache-Control"), "no-store");
  assertEquals(respuesta.headers.get("Access-Control-Expose-Headers"), "Content-Disposition");
  const bytes = new Uint8Array(await respuesta.arrayBuffer());
  assertEquals(String(bytes.byteLength), respuesta.headers.get("Content-Length"));
  assertEquals(new TextDecoder().decode(bytes.slice(0, 5)), "%PDF-");

  const textos = (await textosDelPdf(bytes)).flat();
  for (const esperado of ["Todas las ciudades", "Ana Pérez", "Beto Álvarez", "Campaña de prueba", "S2 contra S1"]) {
    assert(textos.includes(esperado), `falta «${esperado}»`);
  }
});

Deno.test("handler · lee con la sesión de quien pidió el informe y la clave pública: nunca otra credencial", async () => {
  const { dependencias, pedidos } = dependenciasDe(mundoConDatos());
  await manejar(pedidoDeInforme(VALIDO, { Authorization: "Bearer jwt-de-la-coordinadora" }), dependencias);
  assert(pedidos.length >= 5);
  for (const p of pedidos) {
    assertEquals(p.metodo, "POST");
    assertEquals(p.autorizacion, "Bearer jwt-de-la-coordinadora");
    assertEquals(p.apikey, CLAVE_PUBLICA);
    assert(p.url.startsWith(`${URL_DE_LA_API}/rest/v1/rpc/`), p.url);
  }
  assertEquals(
    new Set(pedidos.map((p) => p.url.split("/").pop())),
    new Set([
      "campanias_del_coordinador",
      "horas_por_ciudad_y_colportor",
      "ventas_por_ciudad_y_colportor",
      "zonas_por_colportor",
      "ciudades_de_campania",
    ]),
  );
});

Deno.test("handler · el nombre del archivo sigue el ámbito elegido", async () => {
  const { dependencias } = dependenciasDe(mundoConDatos());
  const respuesta = await manejar(
    pedidoDeInforme({ ambito: { tipo: "colportor", colportorId: uuid(101) }, granularidad: "mes" }),
    dependencias,
  );
  assertEquals(respuesta.status, 200);
  assertStringIncludes(
    respuesta.headers.get("Content-Disposition") ?? "",
    'filename="reportes-ana-perez-meses-2026-10-21.pdf"',
  );
});

Deno.test("handler · sin sesión: 401 con el aviso de volver a entrar", async () => {
  const { dependencias, pedidos } = dependenciasDe(mundoConDatos());
  for (
    const cabeceras of [{}, { Authorization: "" }, { Authorization: "Bearer" }, {
      Authorization: "Basic abc",
    }] as Record<string, string>[]
  ) {
    const respuesta = await manejar(pedidoDeInforme(VALIDO, cabeceras), dependencias);
    assertEquals(respuesta.status, 401);
    const e = await error(respuesta);
    assertEquals(e.codigo, "sin_sesion");
    assertStringIncludes(e.mensaje, "Iniciá sesión de nuevo");
  }
  // Sin sesión ni siquiera se le pregunta a la base.
  assertEquals(pedidos.length, 0);
});

Deno.test("handler · una sesión vencida (la base contesta 401) también es «sin sesión»", async () => {
  for (const codigo of ["401", "PGRST301", "PGRST303"]) {
    const { dependencias } = dependenciasDe(mundoVacio({ fallas: { campanias_del_coordinador: codigo } }));
    // El fetch de prueba contesta `400` para los códigos que no son 42501: forzamos el 401 como lo haría PostgREST.
    const original = dependencias.fetch;
    dependencias.fetch = async (...args) => {
      const r = await original(...args);
      return new Response(await r.text(), { status: 401, headers: r.headers });
    };
    const respuesta = await manejar(pedidoDeInforme(VALIDO), dependencias);
    assertEquals(respuesta.status, 401);
    assertEquals((await error(respuesta)).codigo, "sin_sesion");
  }
});

Deno.test("handler · sin el rol de coordinación de esa campaña (42501): 403", async () => {
  for (const rpc of ["campanias_del_coordinador", "horas_por_ciudad_y_colportor", "ventas_por_ciudad_y_colportor"]) {
    const { dependencias } = dependenciasDe({ ...mundoConDatos(), fallas: { [rpc]: "42501" } });
    const respuesta = await manejar(pedidoDeInforme(VALIDO), dependencias);
    assertEquals(respuesta.status, 403, rpc);
    const e = await error(respuesta);
    assertEquals(e.codigo, "sin_permiso");
    assertStringIncludes(e.mensaje, "No tenés permiso");
  }
});

Deno.test("handler · sin campaña, o con una que todavía no empezó: 404 con qué hacer", async () => {
  for (const campanias of [[], [{ id: CAMPANIA, nombre: "C", fecha_inicio: "2026-11-02", fecha_fin: null }]]) {
    const { dependencias } = dependenciasDe(mundoVacio({ campanias }));
    const respuesta = await manejar(pedidoDeInforme(VALIDO), dependencias);
    assertEquals(respuesta.status, 404);
    assertEquals((await error(respuesta)).codigo, "sin_campania");
  }
});

Deno.test("handler · un reporte sin colportores no se exporta: 422 con el aviso de la pantalla", async () => {
  const { dependencias } = dependenciasDe(mundoVacio());
  const respuesta = await manejar(pedidoDeInforme(VALIDO), dependencias);
  assertEquals(respuesta.status, 422);
  const e = await error(respuesta);
  assertEquals(e.codigo, "sin_datos");
  assertEquals(e.mensaje, "No hay colportores para exportar en este reporte.");
});

Deno.test("handler · si la base falla o no contesta: 502, nunca un PDF a medias", async () => {
  for (const codigo of ["XX000", "500"]) {
    const { dependencias } = dependenciasDe({ ...mundoConDatos(), fallas: { ventas_por_ciudad_y_colportor: codigo } });
    const { resultado, log } = await conLog(() => manejar(pedidoDeInforme(VALIDO), dependencias));
    assertEquals(resultado.status, 502);
    assertEquals((await error(resultado)).codigo, "no_se_pudo_leer");
    assertEquals(log.length, 1);
  }

  const sinRed = dependenciasDe(mundoConDatos(), {
    fetch: () => Promise.reject(new TypeError("fallo de red")),
  }).dependencias;
  const caida = await manejar(pedidoDeInforme(VALIDO), sinRed);
  assertEquals(caida.status, 502);
  assertStringIncludes((await error(caida)).mensaje, "Esperá unos minutos");
});

Deno.test("handler · una respuesta que no es JSON o no tiene la forma del contrato es una falla de lectura", async () => {
  const roto = dependenciasDe(mundoConDatos(), {
    fetch: () => Promise.resolve(new Response("<html>mantenimiento</html>", { status: 200 })),
  }).dependencias;
  assertEquals((await manejar(pedidoDeInforme(VALIDO), roto)).status, 502);

  const forma = dependenciasDe(mundoConDatos(), {
    fetch: () => Promise.resolve(new Response(JSON.stringify({ no: "es una lista" }), { status: 200 })),
  }).dependencias;
  assertEquals((await manejar(pedidoDeInforme(VALIDO), forma)).status, 502);
});

Deno.test("handler · una falla inesperada de la propia función es un 500 con el aviso de reintentar", async () => {
  const { dependencias } = dependenciasDe(mundoConDatos(), {
    ahora: () => {
      throw new Error("falla del reloj");
    },
  });
  const { resultado } = await conLog(() => manejar(pedidoDeInforme(VALIDO), dependencias));
  assertEquals(resultado.status, 500);
  assertEquals((await error(resultado)).codigo, "no_se_pudo_armar");
});

Deno.test("handler · el log solo dice qué falló: ni nombres de colportores ni ids ni el JWT", async () => {
  const { dependencias } = dependenciasDe({ ...mundoConDatos(), fallas: { zonas_por_colportor: "XX000" } });
  const { log } = await conLog(() =>
    manejar(
      pedidoDeInforme({ ambito: { tipo: "colportor", colportorId: uuid(101) }, granularidad: "semana" }),
      dependencias,
    )
  );
  const todo = log.join("\n");
  assertStringIncludes(todo, "informe-reportes.fallo");
  for (const prohibido of ["Ana", "Pérez", uuid(101), "jwt-de-la-coordinadora", CAMPANIA]) {
    assert(!todo.includes(prohibido), prohibido);
  }
});

Deno.test("handler · pedidos inválidos: 400 sin tocar la base", async () => {
  const { dependencias, pedidos } = dependenciasDe(mundoConDatos());
  const invalidos: unknown[] = [
    "no es json {",
    "[]",
    "null",
    "42",
    {},
    { ambito: { tipo: "todas" } },
    { granularidad: "semana" },
    { ambito: { tipo: "todas" }, granularidad: "anio" },
    { ambito: { tipo: "marte" }, granularidad: "semana" },
    { ambito: "todas", granularidad: "semana" },
    { ambito: { tipo: "ciudad" }, granularidad: "semana" },
    { ambito: { tipo: "ciudad", ciudadId: "" }, granularidad: "semana" },
    { ambito: { tipo: "ciudad", ciudadId: 7 }, granularidad: "semana" },
    { ambito: { tipo: "colportor", colportorId: "x".repeat(65) }, granularidad: "semana" },
    { ambito: { tipo: "departamento", departamento: "   " }, granularidad: "semana" },
    { ...VALIDO, campaniaId: 123 },
    { ...VALIDO, campaniaId: "" },
  ];
  for (const cuerpo of invalidos) {
    const respuesta = await manejar(pedidoDeInforme(cuerpo), dependencias);
    assertEquals(respuesta.status, 400, JSON.stringify(cuerpo));
    assertEquals((await error(respuesta)).codigo, "pedido_invalido");
  }
  assertEquals(pedidos.length, 0);
});

Deno.test("handler · un cuerpo desmedido se rechaza: 413", async () => {
  const { dependencias, pedidos } = dependenciasDe(mundoConDatos());
  const grande = JSON.stringify({ ...VALIDO, relleno: "x".repeat(5000) });
  assertEquals((await manejar(pedidoDeInforme(grande), dependencias)).status, 413);
  const declarado = new Request("https://proyecto.supabase.test/f", {
    method: "POST",
    headers: { Authorization: "Bearer jwt", "Content-Length": "999999" },
    body: "{}",
  });
  assertEquals((await manejar(declarado, dependencias)).status, 413);
  assertEquals(pedidos.length, 0);
});

Deno.test("handler · otros métodos: 405; el preflight de CORS contesta lo que el panel necesita", async () => {
  const { dependencias } = dependenciasDe(mundoConDatos());
  const get = await manejar(new Request("https://proyecto.supabase.test/f", { method: "GET" }), dependencias);
  assertEquals(get.status, 405);
  await get.body?.cancel();

  const opciones = await manejar(new Request("https://proyecto.supabase.test/f", { method: "OPTIONS" }), dependencias);
  assertEquals(opciones.status, 204);
  assertStringIncludes(opciones.headers.get("Access-Control-Allow-Headers") ?? "", "authorization");
  assertStringIncludes(opciones.headers.get("Access-Control-Allow-Methods") ?? "", "POST");
  assertEquals(opciones.headers.get("Access-Control-Allow-Origin"), "*");
});

Deno.test("handler · doble clic: dos pedidos a la vez dan dos PDF completos, sin pisarse", async () => {
  const { dependencias } = dependenciasDe(mundoConDatos());
  const [a, b] = await Promise.all([
    manejar(pedidoDeInforme(VALIDO), dependencias),
    manejar(pedidoDeInforme({ ...VALIDO, granularidad: "mes" }), dependencias),
  ]);
  assertEquals([a.status, b.status], [200, 200]);
  const [ta, tb] = await Promise.all([a.arrayBuffer(), b.arrayBuffer()]);
  const textosA = (await textosDelPdf(new Uint8Array(ta))).flat();
  const textosB = (await textosDelPdf(new Uint8Array(tb))).flat();
  assert(textosA.includes("Semanas") && !textosA.includes("Meses"));
  assert(textosB.includes("Meses") && !textosB.includes("Semanas"));
});

Deno.test("handler · después de una falla, el reintento anda (la función no guarda estado)", async () => {
  const mundo = mundoConDatos();
  mundo.fallas = { horas_por_ciudad_y_colportor: "XX000" };
  const { dependencias } = dependenciasDe(mundo);
  const { resultado } = await conLog(() => manejar(pedidoDeInforme(VALIDO), dependencias));
  assertEquals(resultado.status, 502);
  mundo.fallas = {};
  assertEquals((await manejar(pedidoDeInforme(VALIDO), dependencias)).status, 200);
});

Deno.test("handler · la campaña pedida que no figura en la lista de quien llama se ignora (se usa la suya)", async () => {
  const { dependencias, pedidos } = dependenciasDe(mundoConDatos());
  const ajena = "01920000-0000-7000-8000-0000000000aa";
  const respuesta = await manejar(pedidoDeInforme({ ...VALIDO, campaniaId: ajena }), dependencias);
  assertEquals(respuesta.status, 200);
  // Ninguna RPC se llamó con el id ajeno: el id solo vale si figura en `campanias_del_coordinador()`.
  assert(pedidos.length > 1);
  assert(pedidos.every((p) => !p.cuerpo.includes(ajena)));
  assert(pedidos.some((p) => p.cuerpo.includes(CAMPANIA)));
});

Deno.test("pedido · se lee el Ambito y la Granularidad tal como los usa el panel", () => {
  assertEquals(
    leerPedido({ ambito: { tipo: "ciudad", ciudadId: "sin-zona" }, granularidad: "dia", campaniaId: CAMPANIA }),
    {
      campaniaId: CAMPANIA,
      ambito: { tipo: "ciudad", ciudadId: "sin-zona" },
      granularidad: "dia",
    },
  );
  assertEquals(
    leerPedido({ ambito: { tipo: "departamento", departamento: "Río Negro" }, granularidad: "mes", campaniaId: null }),
    {
      campaniaId: null,
      ambito: { tipo: "departamento", departamento: "Río Negro" },
      granularidad: "mes",
    },
  );
  // Lo que sobra no pasa: solo se queda con lo que entiende.
  assertEquals(
    leerPedido({ ambito: { tipo: "todas", extra: "x" }, granularidad: "semana", otro: 1 }),
    { campaniaId: null, ambito: { tipo: "todas" }, granularidad: "semana" },
  );
});

Deno.test("nombre del archivo · sin tildes ni caracteres raros, cortado y con un valor de respaldo", () => {
  assertEquals(nombreDeArchivo("Rivera", "semana", "2026-10-21"), "reportes-rivera-semanas-2026-10-21.pdf");
  assertEquals(
    nombreDeArchivo("Paso de los Toros", "dia", "2026-10-21"),
    "reportes-paso-de-los-toros-dias-2026-10-21.pdf",
  );
  assertEquals(nombreDeArchivo('José Ñandú / "X"', "mes", "2026-10-21"), "reportes-jose-nandu-x-meses-2026-10-21.pdf");
  assertEquals(nombreDeArchivo("???", "semana", "2026-10-21"), "reportes-semanas-2026-10-21.pdf");
  assertEquals(nombreDeArchivo("", "semana", "2026-10-21"), "reportes-semanas-2026-10-21.pdf");
  const largo = nombreDeArchivo("a".repeat(30) + " " + "b".repeat(30), "semana", "2026-10-21");
  assert(!largo.includes("--") && largo.length < 80, largo);
  // Un nombre con comillas no puede romper la cabecera.
  assert(!nombreDeArchivo('Ana"; filename="x', "dia", "2026-10-21").includes('"; '));
});
