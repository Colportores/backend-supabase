import { assert, assertEquals, assertStringIncludes } from "@std/assert";
import { PDFDocument } from "pdf-lib";

import { colportorQueTrabaja, mundoVacio, rpcDe, uuid } from "./apoyo.ts";
import { textosDelPdf } from "./apoyo_pdf.ts";
import { leerDatos } from "./datos.ts";
import {
  COLOR_BARRA,
  COLOR_BARRA_EN_CURSO,
  COLOR_FONDO_GRUPO,
  crearInformePdf,
  crearMedidor,
  envolver,
  maquetar,
  type Medidor,
  type Operacion,
  type Pagina,
} from "./pdf.ts";
import { type Ambito, armarReporte } from "./reporte.ts";

const HOY = "2026-10-21";
const CONTEXTO = { granularidad: "semana", hoy: HOY, campania: "Campaña de otoño" } as const;

async function reporteDe(
  colportores = [colportorQueTrabaja(1, "Ana", "Pérez", "2026-10-05", "2026-10-20")],
  ambito: Ambito = { tipo: "todas" },
) {
  const datos = await leerDatos(
    rpcDe(mundoVacio({ colportores, departamentos: { [uuid(10)]: "Rivera" } })).llamar,
    null,
    HOY,
  );
  assert(datos);
  return armarReporte(datos, ambito, "semana");
}

async function medidor(): Promise<Medidor> {
  const documento = await PDFDocument.create();
  return (await crearMedidor(documento)).medidor;
}

const textosDe = (paginas: Pagina[]) =>
  paginas.map((p) => p.operaciones.flatMap((o) => (o.tipo === "texto" ? [o.texto] : [])));

Deno.test("pdf · la primera página lleva la marca, el título, los filtros aplicados, las cifras y la tabla", async () => {
  const paginas = maquetar(await reporteDe(), CONTEXTO, await medidor());
  const textos = textosDe(paginas)[0];
  for (
    const esperado of [
      "Colportaje",
      "Coordinador · Reportes",
      "Todas las ciudades",
      "Campaña",
      "Campaña de otoño",
      "Ver",
      "Agrupado por",
      "Semanas",
      "Período",
      "S2 contra S1",
      "Al día",
      "21/10/2026",
      "HORAS",
      "PRESENTACIONES",
      "VENTAS",
      "COLPORTOR · S2",
      "MONTO",
      "Ana Pérez",
    ]
  ) assert(textos.includes(esperado), `falta «${esperado}» en ${JSON.stringify(textos)}`);
});

Deno.test("pdf · el pie dice de dónde sale, que no lleva datos de clientes, y numera las páginas", async () => {
  const paginas = maquetar(await reporteDe(), CONTEXTO, await medidor());
  const pie = textosDe(paginas)[0];
  assertStringIncludes(
    pie.join("\n"),
    "Informe generado desde el panel del coordinador el 21/10/2026. Muestra lo mismo que la pantalla; no incluye datos de clientes.",
  );
  assert(pie.includes("Página 1 de 1"));
});

Deno.test("pdf · con muchos colportores sigue en más páginas, repite el encabezado de la tabla y numera bien", async () => {
  const colportores = Array.from(
    { length: 120 },
    (_, i) => colportorQueTrabaja(i, `Nombre${i}`, `Apellido${String(i).padStart(3, "0")}`, "2026-10-05", "2026-10-20"),
  );
  const paginas = maquetar(await reporteDe(colportores), CONTEXTO, await medidor());
  assert(paginas.length >= 3, `páginas: ${paginas.length}`);
  const textos = textosDe(paginas);
  textos.forEach((t, i) => assert(t.includes(`Página ${i + 1} de ${paginas.length}`), `pie de la página ${i + 1}`));
  // La tabla sigue arriba en las páginas siguientes con su encabezado.
  for (const t of textos.slice(1)) assert(t.includes("COLPORTOR · S2") && t.includes("HORAS"), "encabezado repetido");
  // Todos aparecen una sola vez.
  const nombres = textos.flat().filter((t) => /^Nombre\d+ Apellido\d+$/.test(t));
  assertEquals(nombres.length, 120);
  assertEquals(new Set(nombres).size, 120);
});

function limites(op: Operacion, m: Medidor): [number, number, number, number] {
  switch (op.tipo) {
    case "texto": {
      const ancho = m.medir(op.fuente, op.tam, op.texto);
      const x0 = op.alinear === "der" ? op.x - ancho : op.x;
      return [x0, op.y - op.tam, x0 + ancho, op.y];
    }
    case "rect":
      return [op.x, op.y, op.x + op.ancho, op.y + op.alto];
    case "linea":
      return [Math.min(op.x1, op.x2), Math.min(op.y1, op.y2), Math.max(op.x1, op.x2), Math.max(op.y1, op.y2)];
    case "triangulo":
      return [op.x, op.y, op.x + 6, op.y + 6];
  }
}

Deno.test("pdf · nada se dibuja fuera de los márgenes de la hoja", async () => {
  const colportores = Array.from(
    { length: 60 },
    (_, i) =>
      colportorQueTrabaja(i, `Nombre${i}`, `Apellido${i}`, "2026-10-05", "2026-10-20", {
        ciudadId: uuid(10 + (i % 3)),
        ciudadNombre: `Ciudad ${i % 3}`,
      }),
  );
  const m = await medidor();
  for (const pagina of maquetar(await reporteDe(colportores), CONTEXTO, m)) {
    for (const op of pagina.operaciones) {
      const [x0, y0, x1, y1] = limites(op, m);
      assert(x0 >= 39 && x1 <= 595.28 - 39, `x fuera de los márgenes: ${JSON.stringify(op)}`);
      assert(y0 >= 39 && y1 <= 842 - 39, `y fuera de los márgenes: ${JSON.stringify(op)}`);
    }
  }
});

Deno.test("pdf · un nombre larguísimo se parte en líneas y no se sale de su columna", async () => {
  const m = await medidor();
  const largo = "Maximiliano ".repeat(8) + "Pneumonoultramicroscopicsilicovolcanoconiosis".repeat(2);
  const lineas = envolver(m, "negrita", 9, largo, 200);
  assert(lineas.length > 3);
  for (const l of lineas) assert(m.medir("negrita", 9, l) <= 200, l);
  assertEquals(lineas.join(" ").replaceAll(" ", "").length, largo.replaceAll(" ", "").length);
  assertEquals(envolver(m, "normal", 9, "   ", 100), [""]);
});

Deno.test("pdf · un nombre larguísimo en la tabla no rompe la maqueta", async () => {
  const largo = colportorQueTrabaja(
    1,
    "Maximiliano ".repeat(6),
    "Pneumonoultramicroscopicsilicovolcanoconiosis",
    "2026-10-05",
    "2026-10-20",
  );
  const m = await medidor();
  for (const pagina of maquetar(await reporteDe([largo]), CONTEXTO, m)) {
    for (const op of pagina.operaciones) {
      const [x0, , x1] = limites(op, m);
      assert(x0 >= 39 && x1 <= 595.28 - 39, JSON.stringify(op));
    }
  }
});

Deno.test("pdf · letras que la tipografía no trae se cambian por una parecida o por «?» y el PDF se genera igual", async () => {
  const m = await medidor();
  assertEquals(m.limpiar("normal", "Łukasz Nýgaard Čech Őrs"), "Lukasz Nýgaard Cech Ors");
  assertEquals(m.limpiar("normal", "Привет"), "??????");
  assertEquals(m.limpiar("normal", "Ana 😀 ​Pérez\tNúñez\n"), "Ana ? Pérez Núñez ");
  assertEquals(m.limpiar("normal", "Año ñandú — “comillas” €"), "Año ñandú — “comillas” €");

  const raro = colportorQueTrabaja(1, "Łukasz 😀", "Ýñigo<script>&amp;", "2026-10-05", "2026-10-20");
  const bytes = await crearInformePdf(await reporteDe([raro]), CONTEXTO, "reportes.pdf");
  const textos = (await textosDelPdf(bytes)).flat();
  assert(textos.some((t) => t.startsWith("Lukasz ?") && t.includes("Ýñigo<script>&amp;")), JSON.stringify(textos));
});

Deno.test("pdf · el archivo es un PDF válido, de A4, con título, autor e idioma, que se vuelve a abrir", async () => {
  const bytes = await crearInformePdf(
    await reporteDe(),
    CONTEXTO,
    "reportes-todas-las-ciudades-semanas-2026-10-21.pdf",
  );
  assertEquals(new TextDecoder().decode(bytes.slice(0, 5)), "%PDF-");
  const documento = await PDFDocument.load(bytes);
  assertEquals(documento.getPageCount(), 1);
  const { width, height } = documento.getPage(0).getSize();
  assertEquals([Math.round(width), Math.round(height)], [595, 842]);
  assertEquals(documento.getTitle(), "reportes-todas-las-ciudades-semanas-2026-10-21");
  assertEquals(documento.getAuthor(), "Colportaje");
  assertEquals(documento.getCreationDate()?.toISOString().slice(0, 10), HOY);
});

Deno.test("pdf · el texto del archivo real es el de la maqueta, con los nombres y las cifras", async () => {
  const bytes = await crearInformePdf(await reporteDe(), CONTEXTO, "reportes.pdf");
  const textos = (await textosDelPdf(bytes)).flat();
  for (const esperado of ["Colportaje", "Todas las ciudades", "Ana Pérez", "36", "$U 9.000", "Página 1 de 1"]) {
    assert(textos.includes(esperado), `falta «${esperado}» en ${JSON.stringify(textos)}`);
  }
});

Deno.test("pdf · nada de datos de clientes: el archivo solo tiene nombres de colportores y totales", async () => {
  const bytes = await crearInformePdf(await reporteDe(), CONTEXTO, "reportes.pdf");
  const todo = (await textosDelPdf(bytes)).flat().join("\n").toLowerCase();
  // «no incluye datos de clientes» del pie es la única mención permitida.
  const sinPie = todo.replace("no incluye datos de clientes", "");
  for (const prohibido of ["cliente", "teléfono", "telefono", "dirección", "direccion", "@", "contacto"]) {
    assert(!sinPie.includes(prohibido), `aparece «${prohibido}»`);
  }
});

Deno.test("pdf · una tendencia dibuja su triángulo; «= 0%» no lleva", async () => {
  const sube = colportorQueTrabaja(1, "Ana", "Pérez", "2026-10-05", "2026-10-20");
  for (let d = 12; d <= 17; d++) sube.horas![`2026-10-${d}`] = 9;
  const paginas = maquetar(await reporteDe([sube]), CONTEXTO, await medidor());
  const triangulos = paginas[0].operaciones.filter((o) => o.tipo === "triangulo");
  assert(triangulos.length > 0);
  assert(triangulos.every((t) => t.tipo === "triangulo" && t.arriba));
  assert(textosDe(paginas)[0].includes("50%"));

  const igual = maquetar(await reporteDe(), CONTEXTO, await medidor());
  assertEquals(igual[0].operaciones.filter((o) => o.tipo === "triangulo").length, 0);
  assert(textosDe(igual)[0].includes("= 0%"));
});

Deno.test("pdf · sin filas el informe igual se arma (la función no llega acá, pero no se cae)", async () => {
  const reporte = await reporteDe([]);
  const paginas = maquetar(reporte, CONTEXTO, await medidor());
  assert(textosDe(paginas)[0].includes("Todavía no hay colportores para mostrar acá."));
  await crearInformePdf(reporte, CONTEXTO, "x.pdf");
});

Deno.test("pdf · armar el informe de 200 colportores cabe en el presupuesto de CPU de una Edge Function", async () => {
  const colportores = Array.from(
    { length: 200 },
    (_, i) => colportorQueTrabaja(i, `Nombre${i}`, `Apellido${String(i).padStart(3, "0")}`, "2026-08-03", "2026-10-20"),
  );
  const reporte = await reporteDe(colportores);
  const t0 = performance.now();
  const bytes = await crearInformePdf(reporte, CONTEXTO, "x.pdf");
  const ms = performance.now() - t0;
  assert(ms < 1500, `tardó ${ms} ms`);
  assert(bytes.byteLength < 2_000_000, `pesa ${bytes.byteLength} bytes`);
});

Deno.test("pdf · el gráfico marca con otro color la barra del período en curso (parcial)", async () => {
  const paginas = maquetar(await reporteDe(), CONTEXTO, await medidor());
  const rects = paginas[0].operaciones.filter((o) => o.tipo === "rect");
  // Tres tarjetas, tres semanas: S1 y S2 completas y S3 en curso.
  assertEquals(rects.filter((o) => o.relleno === COLOR_BARRA).length, 6);
  assertEquals(rects.filter((o) => o.relleno === COLOR_BARRA_EN_CURSO).length, 3);
});

Deno.test("pdf · el nombre de una ciudad nunca queda solo al pie de la página: va con su primera fila", async () => {
  const m = await medidor();
  for (let cantidad = 1; cantidad <= 45; cantidad++) {
    const colportores = [
      ...Array.from(
        { length: cantidad },
        (_, i) =>
          colportorQueTrabaja(i, `Nombre${i}`, `Apellido${String(i).padStart(3, "0")}`, "2026-10-05", "2026-10-20", {
            ciudadId: uuid(11),
            ciudadNombre: "Artigas",
          }),
      ),
      ...Array.from(
        { length: 9 },
        (_, i) =>
          colportorQueTrabaja(100 + i, `Otro${i}`, `Zeta${i}`, "2026-10-05", "2026-10-20", {
            ciudadId: uuid(10),
            ciudadNombre: "Rivera",
          }),
      ),
    ];
    const paginas = maquetar(await reporteDe(colportores), CONTEXTO, m);
    paginas.forEach((pagina, n) => {
      // Cada página que sigue arranca con el encabezado de la tabla.
      if (n > 0) assert(textosDe([pagina])[0].includes("HORAS"), `página ${n + 1} sin encabezado (${cantidad})`);
      for (const op of pagina.operaciones) {
        if (op.tipo !== "rect" || op.relleno !== COLOR_FONDO_GRUPO) continue;
        // Debajo de la franja de la ciudad hay al menos una fila (y no solo el pie de página, que va más abajo).
        const filaDebajo = pagina.operaciones.some((o) => o.tipo === "texto" && o.y > op.y + op.alto && o.y < 842 - 60);
        assert(filaDebajo, `ciudad sola al pie de la página ${n + 1} con ${cantidad} colportores`);
      }
    });
  }
});
