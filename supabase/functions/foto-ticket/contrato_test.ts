import { assert, assertEquals } from "@std/assert";

import { EXTENSION_DE } from "./handler.ts";

/**
 * La función le pregunta el permiso a la base por dos RPC y entiende tres SQLSTATE propios. Estas pruebas la atan a las
 * migraciones: si alguien renombra una RPC, le cambia los argumentos o los códigos de error, esto falla acá y no recién
 * cuando la colportora sube la foto. Lee la última migración que define cada función, sin base de datos.
 */

const CARPETA = new URL("../../migrations/", import.meta.url);

async function codigoSql(): Promise<string[]> {
  const nombres: string[] = [];
  for await (const e of Deno.readDir(CARPETA)) if (e.isFile && e.name.endsWith(".sql")) nombres.push(e.name);
  nombres.sort();
  return await Promise.all(
    nombres.map(async (nombre) =>
      // Sin comentarios de línea: el texto de documentación también nombra funciones y códigos.
      (await Deno.readTextFile(new URL(nombre, CARPETA))).replace(/--.*$/gm, "")
    ),
  );
}

/** Los argumentos («nombre tipo») y el cuerpo de la última migración que define `public.<rpc>`. */
async function definicionDe(rpc: string): Promise<{ argumentos: string[]; cuerpo: string }> {
  const patron = new RegExp(
    String
      .raw`create\s+(?:or\s+replace\s+)?function\s+public\.${rpc}\s*\(([^)]*)\)\s*returns\s+text[\s\S]*?\$\$([\s\S]*?)\$\$`,
    "i",
  );
  let ultima: { argumentos: string[]; cuerpo: string } | null = null;
  for (const texto of await codigoSql()) {
    const m = patron.exec(texto);
    if (m) ultima = { argumentos: m[1].split(",").map((a) => a.trim().replace(/\s+/g, " ")), cuerpo: m[2] };
  }
  assert(ultima, `ninguna migración define public.${rpc}`);
  return ultima;
}

Deno.test("contrato · ruta_para_ver_foto_de_ticket recibe p_ticket_id (uuid) y avisa con FT001, FT002 y FT003", async () => {
  const { argumentos, cuerpo } = await definicionDe("ruta_para_ver_foto_de_ticket");
  assertEquals(argumentos, ["p_ticket_id uuid"]);
  for (const codigo of ["FT001", "FT002", "FT003"]) {
    assert(cuerpo.includes(`'${codigo}'`), `la base ya no avisa ${codigo}`);
  }
});

Deno.test("contrato · ruta_para_subir_foto_de_ticket recibe p_ticket_id (uuid) y p_extension (text)", async () => {
  const { argumentos, cuerpo } = await definicionDe("ruta_para_subir_foto_de_ticket");
  assertEquals(argumentos, ["p_ticket_id uuid", "p_extension text"]);
  assert(cuerpo.includes("'FT003'"), "la base ya no avisa FT003");
});

Deno.test("contrato · las extensiones que la función pide son las que la base admite, y solo esas", async () => {
  const { cuerpo } = await definicionDe("ruta_para_subir_foto_de_ticket");
  const m = /p_extension\s+not\s+in\s*\(([^)]*)\)/i.exec(cuerpo);
  assert(m, "la base ya no valida la extensión");
  const admitidas = [...m[1].matchAll(/'([^']+)'/g)].map((x) => x[1]).sort();
  assertEquals([...new Set(Object.values(EXTENSION_DE))].sort(), admitidas);
});
