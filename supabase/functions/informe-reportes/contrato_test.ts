import { assert, assertEquals } from "@std/assert";

/**
 * La función lee cinco RPC por nombre de columna. Estas pruebas la atan a las migraciones: si alguien renombra o
 * borra una columna de esas RPC (o les cambia los argumentos), esto falla acá y no recién en producción, cuando la
 * coordinadora aprieta «Informe PDF». Lee la última migración que define cada función, sin base de datos.
 */

const CARPETA = new URL("../../migrations/", import.meta.url);

interface Definicion {
  archivo: string;
  argumentos: string[];
  columnas: string[];
}

async function migraciones(): Promise<{ nombre: string; texto: string }[]> {
  const nombres: string[] = [];
  for await (const e of Deno.readDir(CARPETA)) if (e.isFile && e.name.endsWith(".sql")) nombres.push(e.name);
  nombres.sort();
  return await Promise.all(
    nombres.map(async (nombre) => ({ nombre, texto: await Deno.readTextFile(new URL(nombre, CARPETA)) })),
  );
}

/** Los nombres de una lista «nombre tipo, nombre tipo, …» (los tipos de estas RPC no llevan comas ni paréntesis). */
function nombres(lista: string): string[] {
  return lista
    .split(",")
    .map((p) => p.trim().replace(/^(in|out|inout)\s+/i, "").split(/\s+/)[0])
    .filter((n) => n !== "");
}

async function definicionDe(rpc: string): Promise<Definicion> {
  const patron = new RegExp(
    `create\\s+(?:or\\s+replace\\s+)?function\\s+public\\.${rpc}\\s*\\(([^)]*)\\)\\s*returns\\s+table\\s*\\(([^)]*)\\)`,
    "i",
  );
  let ultima: Definicion | null = null;
  for (const { nombre, texto } of await migraciones()) {
    // Sin comentarios de línea: el texto de documentación también nombra funciones.
    const codigo = texto.replace(/--.*$/gm, "");
    const m = patron.exec(codigo);
    if (m) ultima = { archivo: nombre, argumentos: nombres(m[1]), columnas: nombres(m[2]) };
  }
  assert(ultima, `ninguna migración define public.${rpc}`);
  return ultima;
}

/** Lo que `datos.ts` lee de cada RPC. */
const LEIDAS: Record<string, string[]> = {
  campanias_del_coordinador: ["id", "nombre", "fecha_inicio", "fecha_fin"],
  ciudades_de_campania: ["ciudad_id", "departamento"],
  zonas_por_colportor: ["colportor_id", "nombre", "apellido", "ciudad_id", "ciudad_nombre"],
  horas_por_ciudad_y_colportor: [
    "periodo_inicio",
    "ciudad_id",
    "ciudad_nombre",
    "colportor_id",
    "nombre",
    "apellido",
    "horas",
    "jornadas",
  ],
  ventas_por_ciudad_y_colportor: [
    "periodo_inicio",
    "ciudad_id",
    "ciudad_nombre",
    "colportor_id",
    "nombre",
    "apellido",
    "ventas",
    "monto_total",
    "presentaciones",
  ],
};

/** Columnas que jamás deben aparecer en lo que lee el informe: clientes, contactos, ubicaciones, cobros. */
const PROHIBIDAS = /cliente|persona|telefono|email|correo|direccion|ubicacion|lat|lon|medio_de_pago|talonario/i;

for (const [rpc, leidas] of Object.entries(LEIDAS)) {
  Deno.test(`contrato · ${rpc} devuelve las columnas que lee la función`, async () => {
    const { columnas, archivo } = await definicionDe(rpc);
    for (const c of leidas) {
      assert(columnas.includes(c), `${rpc} (${archivo}) ya no devuelve «${c}»: columnas = ${columnas.join(", ")}`);
    }
  });

  Deno.test(`contrato · ${rpc} no devuelve datos de clientes ni contactos`, async () => {
    const { columnas, archivo } = await definicionDe(rpc);
    // `ciudad_*` y `lat_centro`/`lon_centro` son de la ciudad (no de una persona): solo se mira lo que lee la función.
    for (const c of leidas) assert(!PROHIBIDAS.test(c.replace("ciudad_", "")), `${rpc} (${archivo}): «${c}»`);
    assert(columnas.length > 0);
  });
}

Deno.test("contrato · las RPC de horas y de ventas se llaman con los mismos argumentos que manda la función", async () => {
  for (const rpc of ["horas_por_ciudad_y_colportor", "ventas_por_ciudad_y_colportor"]) {
    const { argumentos } = await definicionDe(rpc);
    assertEquals(argumentos, ["p_campania_id", "p_desde", "p_hasta", "p_agrupar", "p_ciudad_id", "p_colportor_ids"]);
  }
  assertEquals((await definicionDe("zonas_por_colportor")).argumentos, ["p_campania_id"]);
  assertEquals((await definicionDe("ciudades_de_campania")).argumentos, ["p_campania_id"]);
  assertEquals((await definicionDe("campanias_del_coordinador")).argumentos, []);
});

Deno.test("contrato · las cinco RPC se pueden ejecutar con la sesión de un usuario (authenticated), no solo con la clave de servicio", async () => {
  const todo = (await migraciones()).map((m) => m.texto.replace(/--.*$/gm, "")).join("\n");
  for (const rpc of Object.keys(LEIDAS)) {
    const otorgado = new RegExp(
      `grant\\s+execute\\s+on\\s+function[^;]*?public\\.${rpc}\\s*\\([^;]*?\\bto\\s+authenticated`,
      "i",
    );
    assert(otorgado.test(todo), `ninguna migración da execute de ${rpc} a authenticated`);
  }
});

Deno.test("contrato · el análisis de las migraciones encuentra la última definición (ciudades_de_campania ya trae el departamento)", async () => {
  const { archivo, columnas } = await definicionDe("ciudades_de_campania");
  assert(columnas.includes("departamento"));
  assert(archivo >= "20261023150000_0066", archivo);
});
