import { assertEquals, assertExists } from "@std/assert";

import { colportorQueTrabaja, type Mundo, mundoVacio, rpcDe, uuid } from "./apoyo.ts";
import { type DatosDelReporte, leerDatos } from "./datos.ts";
import { armarReporte, type FilaDeTabla, type ReporteArmado } from "./reporte.ts";

const HOY = "2026-10-21";
const RIVERA = uuid(10);
const ARTIGAS = uuid(11);

function mundo(): Mundo {
  const beto = colportorQueTrabaja(2, "Beto", "Álvarez", "2026-10-05", "2026-10-20");
  // La segunda semana (12 a 17/10) trabajó la mitad de las horas.
  for (let d = 12; d <= 17; d++) beto.horas![`2026-10-${d}`] = 3;
  return mundoVacio({
    colportores: [
      colportorQueTrabaja(1, "Ana", "Pérez", "2026-10-05", "2026-10-20"),
      beto,
      colportorQueTrabaja(3, "Carla", "Mora", "2026-10-05", "2026-10-20", {
        ciudadId: ARTIGAS,
        ciudadNombre: "Artigas",
      }),
    ],
    departamentos: { [RIVERA]: "Rivera", [ARTIGAS]: "Artigas" },
  });
}

async function datos(m: Mundo = mundo(), hoy = HOY): Promise<DatosDelReporte> {
  const resultado = await leerDatos(rpcDe(m).llamar, null, hoy);
  assertExists(resultado);
  return resultado;
}

const filasDe = (r: ReporteArmado) =>
  r.tabla.filas.filter((f): f is Extract<FilaDeTabla, { tipo: "fila" }> => f.tipo === "fila");

Deno.test("reporte · todas las ciudades por semana: tarjetas, tendencia y totales de la campaña", async () => {
  const r = armarReporte(await datos(), { tipo: "todas" }, "semana");
  assertEquals(r.titulo, "Todas las ciudades");
  assertEquals(r.subtitulo, "3 colportores · S2 contra S1");
  assertEquals(r.periodo, "S2 contra S1");
  assertEquals(r.vistaElegida, null);
  assertEquals(r.tarjetas.map((t) => t.etiqueta), ["HORAS", "PRESENTACIONES", "VENTAS"]);

  const [horas, presentaciones, ventas] = r.tarjetas;
  // S2: Ana 36 + Carla 36 + Beto 18; S1: 3 × 36.
  assertEquals(horas.valor, "90");
  assertEquals(horas.tendencia, { sentido: "baja", texto: "17%" });
  assertEquals(horas.nota, "S2 · contra S1");
  assertEquals(horas.campania, "Campaña: 234");
  assertEquals(presentaciones.valor, "90");
  assertEquals(presentaciones.tendencia, { sentido: "igual", texto: "= 0%" });
  assertEquals(ventas.valor, "36");
  // Las ventas de la campaña llevan lo que sumaron en $U (150.000 centavos = $U 1.500 por colportor y día).
  assertEquals(ventas.campania, "Campaña: 84 · $U 63.000");

  // Un gráfico con una barra por semana; la que está en curso, marcada.
  assertEquals(horas.barras.map((b) => b.rotulo), ["S1", "S2", "S3"]);
  assertEquals(horas.barras.map((b) => b.enCurso), [false, false, true]);
  assertEquals(Math.max(...horas.barras.map((b) => b.proporcion)), 1);
});

Deno.test("reporte · la tabla agrupa por ciudad cuando hay más de una y lista a cada colportor con su nombre", async () => {
  const r = armarReporte(await datos(), { tipo: "todas" }, "semana");
  assertEquals(r.tabla.primeraColumna, "COLPORTOR · S2");
  assertEquals(r.tabla.columnas.map((c) => c.encabezado), ["HORAS", "PRESENTACIONES", "VENTAS", "MONTO"]);
  assertEquals(r.tabla.filas.map((f) => (f.tipo === "grupo" ? `[${f.nombre}] ${f.detalle}` : f.nombre)), [
    "[Artigas] 1 colportor",
    "Carla Mora",
    "[Rivera] 2 colportores",
    "Beto Álvarez",
    "Ana Pérez",
  ]);
  const beto = filasDe(r).find((f) => f.nombre === "Beto Álvarez");
  assertEquals(beto?.celdas.map((c) => c.valor), ["18,0", "30", "12", "$U 9.000"]);
  assertEquals(beto?.celdas[0].tendencia, { sentido: "baja", texto: "50%" });
  assertEquals(beto?.nota, null);
});

Deno.test("reporte · una ciudad: sin filas de grupo, con su departamento en el subtítulo", async () => {
  const r = armarReporte(await datos(), { tipo: "ciudad", ciudadId: RIVERA }, "semana");
  assertEquals(r.titulo, "Rivera");
  assertEquals(r.subtitulo, "Departamento Rivera · 2 colportores · S2 contra S1");
  assertEquals(r.tabla.filas.every((f) => f.tipo === "fila"), true);
  assertEquals(r.tarjetas[0].valor, "54");
});

Deno.test("reporte · un departamento", async () => {
  const r = armarReporte(await datos(), { tipo: "departamento", departamento: "Artigas" }, "semana");
  assertEquals(r.titulo, "Departamento Artigas");
  assertEquals(r.subtitulo, "Departamento Artigas · 1 colportor · S2 contra S1");
  assertEquals(filasDe(r).map((f) => f.nombre), ["Carla Mora"]);
});

Deno.test("reporte · un colportor: una fila por período, con un decimal y su ciudad", async () => {
  const r = armarReporte(await datos(), { tipo: "colportor", colportorId: uuid(101) }, "semana");
  assertEquals(r.titulo, "Ana Pérez");
  assertEquals(r.vistaElegida, "Ana Pérez (Rivera)");
  assertEquals(r.subtitulo, "Rivera · Departamento Rivera · S2 contra S1");
  assertEquals(r.tabla.primeraColumna, "SEMANA");
  assertEquals(r.tabla.descripcion, "Horas, presentaciones, ventas y monto de Ana Pérez por semana");
  const filas = filasDe(r);
  assertEquals(filas.map((f) => f.nombre), ["S1 · 05/10", "S2 · 12/10", "S3 · 19/10"]);
  assertEquals(filas[0].celdas[0].valor, "36,0");
  assertEquals(filas[1].celdas[0].tendencia, { sentido: "igual", texto: "= 0%" });
  // La semana en curso se avisa y no lleva tendencia.
  assertEquals(filas[2].nota, "en curso");
  assertEquals(filas[2].celdas.every((c) => c.tendencia === null), true);
  assertEquals(filas[0].celdas[0].tendencia, null);
  assertEquals(r.tarjetas[0].valor, "36,0");
});

Deno.test("reporte · un ámbito que ya no existe vuelve a «todas las ciudades»", async () => {
  const d = await datos();
  for (
    const ambito of [
      { tipo: "ciudad", ciudadId: "no-existe" },
      { tipo: "colportor", colportorId: "no-existe" },
      { tipo: "departamento", departamento: "Salto" },
    ] as const
  ) {
    const r = armarReporte(d, ambito, "semana");
    assertEquals(r.titulo, "Todas las ciudades");
    assertEquals(r.vistaElegida, null);
    assertEquals(filasDe(r).length, 3);
  }
});

Deno.test("reporte · por día y por mes", async () => {
  const d = await datos(mundo(), "2026-11-10");
  const dia = armarReporte(d, { tipo: "todas" }, "dia");
  // Hoy es martes 10/11: el último día completo es ayer, el lunes 9.
  assertEquals(dia.periodo, "ayer contra el día anterior");
  assertEquals(dia.tarjetas[0].barras.length <= 14, true);

  const mes = armarReporte(d, { tipo: "todas" }, "mes");
  assertEquals(mes.periodo, "nov. a la fecha contra oct. a la misma fecha");
  assertEquals(mes.tarjetas[0].barras.map((b) => b.rotulo), ["Oct", "Nov"]);
});

Deno.test("reporte · quien dejó de mandar datos lo dice: «sin datos desde el…»", async () => {
  const m = mundo();
  m.colportores.push(colportorQueTrabaja(4, "Dani", "Núñez", "2026-10-05", "2026-10-14"));
  const r = armarReporte(await datos(m), { tipo: "todas" }, "dia");
  const dani = filasDe(r).find((f) => f.nombre === "Dani Núñez");
  assertEquals(dani?.nota, "sin datos desde el 14/10");
  assertEquals(dani?.celdas.map((c) => c.valor), ["—", "—", "—", "—"]);
  assertEquals(dani?.celdas.every((c) => c.sinDatos && c.tendencia === null), true);
});

Deno.test("reporte · un inscripto sin ninguna jornada figura con guiones y «sin datos»", async () => {
  const m = mundo();
  m.colportores.push(
    colportorQueTrabaja(5, "Eva", "Rey", "2026-10-05", "2026-10-05", { horas: {}, ventas: {}, inscripto: true }),
  );
  const r = armarReporte(await datos(m), { tipo: "todas" }, "semana");
  const eva = filasDe(r).find((f) => f.nombre === "Eva Rey");
  assertEquals(eva?.nota, "sin datos");
  assertEquals(eva?.celdas[0].valor, "—");
});

Deno.test("reporte · un colportor sin datos en un período lo dice y recuerda cuándo fueron los últimos", async () => {
  const m = mundo();
  m.colportores.push(colportorQueTrabaja(6, "Fede", "Sosa", "2026-10-05", "2026-10-09"));
  const r = armarReporte(await datos(m), { tipo: "colportor", colportorId: uuid(106) }, "semana");
  const filas = filasDe(r);
  assertEquals(filas[1].nota, "sin datos · últimos datos el 09/10");
  assertEquals(filas[1].celdas[0].valor, "—");
});

Deno.test("reporte · todavía sin un período completo: lo dice, sin inventar cifras", async () => {
  const r = armarReporte(await datos(mundo(), "2026-10-07"), { tipo: "todas" }, "semana");
  assertEquals(r.periodo, "");
  assertEquals(r.tarjetas[0].valor, "—");
  assertEquals(r.tarjetas[0].nota, "Todavía no hay un período completo");
  assertEquals(r.tarjetas[0].tendencia, null);
  assertEquals(r.tabla.primeraColumna, "COLPORTOR");
});

Deno.test("reporte · sin colportores: tabla vacía y tarjetas «sin datos»", async () => {
  const r = armarReporte(await datos(mundoVacio()), { tipo: "todas" }, "semana");
  assertEquals(r.tabla.filas, []);
  assertEquals(r.subtitulo, "0 colportores · S2 contra S1");
  assertEquals(r.tarjetas[0].nota, "S2: sin datos");
});

Deno.test("reporte · 200 colportores en muchas semanas se arma rápido", async () => {
  const colportores = Array.from(
    { length: 200 },
    (_, i) => colportorQueTrabaja(i, `Nombre${i}`, `Apellido${String(i).padStart(3, "0")}`, "2026-08-03", "2026-10-20"),
  );
  const d = await datos(
    mundoVacio({
      colportores,
      campanias: [{ id: mundo().campanias[0].id, nombre: "C", fecha_inicio: "2026-08-03", fecha_fin: null }],
    }),
  );
  const t0 = performance.now();
  for (const g of ["dia", "semana", "mes"] as const) {
    assertEquals(filasDe(armarReporte(d, { tipo: "todas" }, g)).length, 200);
  }
  // Sobra: el límite de las Edge Functions es de unos 2 segundos de CPU en total.
  assertEquals(performance.now() - t0 < 1500, true);
});
