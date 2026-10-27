import { assertEquals } from "@std/assert";

import {
  agregadoresDe,
  CIFRA_SIN_DATOS,
  type ColportorDelReporte,
  compararCon,
  crearCalendario,
  formatearCifra,
  formatearDecimal,
  formatearEntero,
  periodosDe,
  sumarCifras,
  tendenciaDe,
  ultimoDatoAntesDe,
} from "./calculo.ts";
import { diasEntre, esDiaIso, hoyEnMontevideo, lunesDe, sumarDias } from "./fechas.ts";

function colportor(horasPorDia: Record<string, number>, id = "c1"): ColportorDelReporte {
  return { id, nombre: `Colportor ${id}`, horasPorDia, ventasPorDia: {}, sinDatosDesde: null };
}

Deno.test("fechas · las cuentas son de calendario, sin zona horaria", () => {
  assertEquals(sumarDias("2026-10-31", 1), "2026-11-01");
  assertEquals(diasEntre("2026-10-05", "2026-10-21"), 16);
  assertEquals(lunesDe("2026-10-21"), "2026-10-19");
  assertEquals(lunesDe("2026-10-25"), "2026-10-19");
  assertEquals(esDiaIso("2026-02-30"), false);
  assertEquals(esDiaIso("2026-10-21"), true);
  assertEquals(esDiaIso("21/10/2026"), false);
});

Deno.test("fechas · a las 22:00 de Montevideo sigue siendo el mismo día aunque en UTC ya sea el siguiente", () => {
  // 2026-10-22T01:00Z = 2026-10-21 22:00 en Montevideo (UTC-3).
  assertEquals(hoyEnMontevideo(new Date("2026-10-22T01:00:00Z")), "2026-10-21");
  assertEquals(hoyEnMontevideo(new Date("2026-10-22T03:00:00Z")), "2026-10-22");
});

Deno.test("calendario · no cuenta los domingos y corta en el fin de la campaña", () => {
  const abierto = crearCalendario("2026-10-05", "2026-10-21");
  assertEquals(abierto.diasHabiles.length, 6 + 6 + 3);
  assertEquals(abierto.diasHabiles.includes("2026-10-11"), false);
  const terminado = crearCalendario("2026-10-05", "2026-11-10", "2026-10-17");
  assertEquals(terminado.diasHabiles.at(-1), "2026-10-17");
});

Deno.test("períodos · días: los últimos 14, con hoy en curso", () => {
  const periodos = periodosDe("dia", crearCalendario("2026-10-05", "2026-10-21"));
  assertEquals(periodos.length, 14);
  assertEquals(periodos.at(-1)?.inicio, "2026-10-21");
  assertEquals(periodos.at(-1)?.enCurso, true);
  assertEquals(periodos.at(-1)?.detalle, "mié 21/10");
  assertEquals(periodos.filter((p) => p.enCurso).length, 1);
});

Deno.test("períodos · semanas S1, S2… y solo la última en curso", () => {
  const periodos = periodosDe("semana", crearCalendario("2026-10-05", "2026-10-21"));
  assertEquals(periodos.map((p) => p.rotulo), ["S1", "S2", "S3"]);
  assertEquals(periodos.map((p) => p.enCurso), [false, false, true]);
  assertEquals(periodos[2].dias, ["2026-10-19", "2026-10-20", "2026-10-21"]);
  assertEquals(periodos[0].detalle, "05/10");
});

Deno.test("períodos · una campaña que arranca a mitad de semana cuenta la semana desde su lunes", () => {
  // Arranca un miércoles: esa semana es S1 aunque tenga 4 días.
  const periodos = periodosDe("semana", crearCalendario("2026-10-07", "2026-10-21"));
  assertEquals(periodos.map((p) => p.rotulo), ["S1", "S2", "S3"]);
  assertEquals(periodos[0].dias.length, 4);
});

Deno.test("períodos · meses con rótulo corto", () => {
  const periodos = periodosDe("mes", crearCalendario("2026-10-05", "2026-11-10"));
  assertEquals(periodos.map((p) => p.rotulo), ["Oct", "Nov"]);
  assertEquals(periodos.map((p) => p.detalle), ["octubre", "noviembre"]);
  assertEquals(periodos.map((p) => p.enCurso), [false, true]);
});

Deno.test("comparación · días: ayer contra el día anterior; el lunes se mira el sábado", () => {
  const agregar = agregadoresDe([colportor({ "2026-10-19": 4, "2026-10-20": 6 })]).horas;
  const c = compararCon("dia", agregar, crearCalendario("2026-10-05", "2026-10-21"));
  assertEquals(c?.rotulo, "ayer");
  assertEquals(c?.contra, "contra el día anterior");
  assertEquals(c?.actual, { valor: 6, hayDatos: true });
  assertEquals(c?.base, { valor: 4, hayDatos: true });

  const lunes = compararCon("dia", agregar, crearCalendario("2026-10-05", "2026-10-19"));
  assertEquals(lunes?.rotulo, "ayer"); // el sábado 17: el domingo no se trabaja
  assertEquals(lunes?.actual.hayDatos, false);
});

Deno.test("comparación · semanas: la última completa contra la anterior", () => {
  const agregar = agregadoresDe([colportor({ "2026-10-06": 10, "2026-10-13": 12, "2026-10-20": 3 })]).horas;
  const c = compararCon("semana", agregar, crearCalendario("2026-10-05", "2026-10-21"));
  assertEquals(c?.rotulo, "S2");
  assertEquals(c?.contra, "contra S1");
  assertEquals(c?.actual.valor, 12);
  assertEquals(c?.base?.valor, 10);
});

Deno.test("comparación · sin período completo no hay comparación", () => {
  const agregar = agregadoresDe([colportor({})]).horas;
  // La primera semana todavía está en curso y no hay día completo.
  assertEquals(compararCon("semana", agregar, crearCalendario("2026-10-19", "2026-10-21")), null);
  assertEquals(compararCon("dia", agregar, crearCalendario("2026-10-21", "2026-10-21")), null);
  // Una sola semana completa: se muestra, pero sin contra qué compararla.
  const unaSola = compararCon("semana", agregar, crearCalendario("2026-10-12", "2026-10-21"));
  assertEquals(unaSola?.rotulo, "S1");
  assertEquals(unaSola?.contra, "");
  assertEquals(unaSola?.base, null);
});

Deno.test("comparación · el mes en curso se compara con el mismo tramo del anterior", () => {
  const horas = { "2026-10-06": 5, "2026-10-09": 5, "2026-10-20": 50, "2026-11-04": 8, "2026-11-09": 9 };
  const agregar = agregadoresDe([colportor(horas)]).horas;
  const c = compararCon("mes", agregar, crearCalendario("2026-10-05", "2026-11-10"));
  assertEquals(c?.rotulo, "nov. a la fecha");
  assertEquals(c?.contra, "contra oct. a la misma fecha");
  assertEquals(c?.actual.valor, 17);
  // Octubre del 1 al 10 (el día de hoy): el 20 de octubre no entra.
  assertEquals(c?.base?.valor, 10);
});

Deno.test("comparación · un mes terminado se compara entero y sin «a la fecha»", () => {
  const horas = { "2026-09-10": 7, "2026-10-06": 5, "2026-10-20": 50 };
  const agregar = agregadoresDe([colportor(horas)]).horas;
  const c = compararCon("mes", agregar, crearCalendario("2026-09-01", "2026-11-10", "2026-10-31"));
  assertEquals(c?.rotulo, "oct.");
  assertEquals(c?.contra, "contra sep.");
  assertEquals(c?.actual.valor, 55);
  assertEquals(c?.base?.valor, 7);
});

Deno.test("tendencia · sube, baja, igual y sin contra qué comparar", () => {
  const cifra = (valor: number) => ({ valor, hayDatos: true });
  assertEquals(tendenciaDe(cifra(110), cifra(100)), { sentido: "sube", texto: "10%" });
  assertEquals(tendenciaDe(cifra(92), cifra(100)), { sentido: "baja", texto: "8%" });
  assertEquals(tendenciaDe(cifra(100), cifra(100)), { sentido: "igual", texto: "= 0%" });
  assertEquals(tendenciaDe(cifra(100), cifra(0)), null);
  assertEquals(tendenciaDe(cifra(100), null), null);
  assertEquals(tendenciaDe(CIFRA_SIN_DATOS, cifra(100)), null);
  assertEquals(tendenciaDe(cifra(100), CIFRA_SIN_DATOS), null);
});

Deno.test("cifras · sin datos no es cero", () => {
  assertEquals(sumarCifras([CIFRA_SIN_DATOS, CIFRA_SIN_DATOS]), CIFRA_SIN_DATOS);
  assertEquals(sumarCifras([CIFRA_SIN_DATOS, { valor: 0, hayDatos: true }]), { valor: 0, hayDatos: true });
  assertEquals(formatearCifra(CIFRA_SIN_DATOS, true, "horas"), "—");
  assertEquals(formatearCifra({ valor: 0, hayDatos: true }, true, "ventas"), "0");
});

Deno.test("cifras · formato de miles con punto, decimales con coma y $U", () => {
  assertEquals(formatearEntero(1450), "1.450");
  assertEquals(formatearEntero(1234567.6), "1.234.568");
  assertEquals(formatearDecimal(27.44), "27,4");
  assertEquals(formatearCifra({ valor: 27.44, hayDatos: true }, false, "horas"), "27,4");
  assertEquals(formatearCifra({ valor: 274.4, hayDatos: true }, true, "horas"), "274");
  assertEquals(formatearCifra({ valor: 12500, hayDatos: true }, true, "monto"), "$U 12.500");
});

Deno.test("agregadores · varios colportores suman día por día y un día sin datos de todos sigue sin datos", () => {
  const a = colportor({ "2026-10-20": 4 }, "a");
  const b = colportor({ "2026-10-20": 3, "2026-10-19": 2 }, "b");
  const { horas } = agregadoresDe([a, b]);
  assertEquals(horas(["2026-10-20"]), { valor: 7, hayDatos: true });
  assertEquals(horas(["2026-10-19"]), { valor: 2, hayDatos: true });
  assertEquals(horas(["2026-10-17"]), CIFRA_SIN_DATOS);
});

Deno.test("último dato anterior a un día", () => {
  const c = colportor({ "2026-10-06": 1, "2026-10-13": 1, "2026-10-20": 1 });
  assertEquals(ultimoDatoAntesDe(c, "2026-10-20"), "2026-10-13");
  assertEquals(ultimoDatoAntesDe(c, "2026-10-06"), null);
});
