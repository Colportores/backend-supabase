import { assert, assertEquals } from "@std/assert";

import { TITULOS } from "./fcm.ts";
import { CLAVES_DE_ID } from "./handler.ts";

/**
 * La función entiende dos RPC de la cola, los seis tipos de aviso y las claves de su payload. Estas pruebas la atan a las
 * migraciones: si alguien renombra una RPC, le cambia los argumentos, suma un tipo o una clave al payload, esto falla
 * acá y no recién cuando un aviso llega mal. Lee las migraciones, sin base de datos.
 */

const CARPETA = new URL("../../migrations/", import.meta.url);

async function codigoSql(): Promise<string> {
  const nombres: string[] = [];
  for await (const e of Deno.readDir(CARPETA)) if (e.isFile && e.name.endsWith(".sql")) nombres.push(e.name);
  nombres.sort();
  const textos = await Promise.all(
    // Sin comentarios de línea: el texto de documentación también nombra funciones, tipos y claves.
    nombres.map(async (n) => (await Deno.readTextFile(new URL(n, CARPETA))).replace(/--.*$/gm, "")),
  );
  return textos.join("\n");
}

/** Los argumentos («nombre tipo [default …]») de la última definición de `public.<rpc>`. */
function argumentosDe(sql: string, rpc: string): string[] {
  const patron = new RegExp(String.raw`create\s+(?:or\s+replace\s+)?function\s+public\.${rpc}\s*\(([^)]*)\)`, "gi");
  const ultima = [...sql.matchAll(patron)].at(-1);
  assert(ultima, `ninguna migración define public.${rpc}`);
  return ultima[1].split(",").map((a) => a.trim().replace(/\s+/g, " "));
}

function cuerpoDe(sql: string, firma: string): string {
  const patron = new RegExp(
    String.raw`create\s+(?:or\s+replace\s+)?function\s+${firma}[\s\S]*?\$\$([\s\S]*?)\$\$`,
    "gi",
  );
  const ultima = [...sql.matchAll(patron)].at(-1);
  assert(ultima, `ninguna migración define ${firma}`);
  return ultima[1];
}

Deno.test("contrato · push_tomar_pendientes recibe p_max y devuelve evento_id, token, datos e intento", async () => {
  const sql = await codigoSql();
  assertEquals(argumentosDe(sql, "push_tomar_pendientes"), ["p_max integer default 50"]);
  const m = /function\s+public\.push_tomar_pendientes[\s\S]*?returns\s+table\s*\(([^)]*)\)/i.exec(sql);
  assert(m, "la base ya no devuelve una tabla");
  assertEquals(
    m[1].split(",").map((c) => c.trim().replace(/\s+/g, " ")),
    ["evento_id uuid", "token text", "datos jsonb", "intento integer"],
  );
});

Deno.test("contrato · push_resultado recibe p_evento_id, p_resultado, p_token y p_error", async () => {
  const sql = await codigoSql();
  assertEquals(argumentosDe(sql, "push_resultado"), [
    "p_evento_id uuid",
    "p_resultado text",
    "p_token text default null",
    "p_error text default null",
  ]);
});

Deno.test("contrato · los resultados que manda la función son los que la base acepta, y solo esos", async () => {
  const sql = await codigoSql();
  const cuerpo = cuerpoDe(sql, String.raw`public\.push_resultado\s*\(`);
  const m = /p_resultado\s+not\s+in\s*\(([^)]*)\)/i.exec(cuerpo);
  assert(m, "la base ya no valida el resultado");
  const aceptados = [...m[1].matchAll(/'([^']+)'/g)].map((x) => x[1]).sort();
  assertEquals(aceptados, ["DESCARTAR", "ENVIADO", "REINTENTAR", "TOKEN_INVALIDO"]);

  // Y los que la función usa en su código (fcm.ts y handler.ts) están entre ellos.
  const usados = new Set<string>();
  for (const archivo of ["fcm.ts", "handler.ts"]) {
    const texto = await Deno.readTextFile(new URL(`./${archivo}`, import.meta.url));
    for (const x of texto.matchAll(/resultado:\s*"([A-Z_]+)"/g)) usados.add(x[1]);
  }
  assertEquals([...usados].sort(), aceptados, "la función usa exactamente los cuatro resultados");
});

Deno.test("contrato · los seis tipos de aviso de la base son los que la función deja pasar", async () => {
  const sql = await codigoSql();
  const m = /constraint\s+evento_tipo_check\s+check\s*\(\s*tipo\s+in\s*\(([^)]*)\)/i.exec(sql);
  assert(m, "la base ya no limita los tipos");
  const tipos = [...m[1].matchAll(/'([^']+)'/g)].map((x) => x[1]).sort();
  assertEquals(tipos, [
    "agenda_manana",
    "asignacion_campania",
    "cuota_pendiente",
    "pedido_autorizado",
    "ticket_rechazado",
    "ticket_validado",
  ]);
  const handler = await Deno.readTextFile(new URL("./handler.ts", import.meta.url));
  const delHandler = [...(/const TIPOS = \[([^\]]*)\]/.exec(handler)?.[1] ?? "").matchAll(/"([^"]+)"/g)].map((x) =>
    x[1]
  ).sort();
  assertEquals(delHandler, tipos);
  // Y cada uno tiene su título fijo (backend-supabase#242): ni uno sin título ni un título de un tipo que no existe.
  assertEquals(Object.keys(TITULOS).sort(), tipos);
});

Deno.test("contrato · las claves del payload que arma la base son las que la función permite", async () => {
  const sql = await codigoSql();
  const cuerpo = cuerpoDe(sql, String.raw`push\.datos_del_aviso\s*\(`);
  const claves = new Set([...cuerpo.matchAll(/'([a-z_]+)'\s*,/g)].map((x) => x[1]));
  // type y event_id van siempre; el resto son *_id.
  assertEquals([...claves].filter((c) => c !== "type").sort(), [...CLAVES_DE_ID].sort());
});
