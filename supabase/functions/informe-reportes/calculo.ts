import {
  diaDelMes,
  diaDeSemana,
  diasEntre,
  diaYMes,
  type Fecha,
  lunesDe,
  mesAbreviado,
  nombreDelDia,
  nombreDelMes,
  numeroDeMes,
  rotuloDelMes,
  sumarDias,
} from "./fechas.ts";

/**
 * Cuentas de la vista 32 (HU-REP-001 y HU-REP-002): de las horas y las ventas de cada día salen los períodos (días,
 * semanas, meses) y la tendencia contra el período anterior. Es la misma regla que aplica el panel en pantalla
 * (`calculo.ts` de front-coordinadores-web): el informe tiene que decir lo mismo que la pantalla. Funciones puras, sin
 * reloj: el «hoy» viene en los datos.
 *
 * El «% por cobrar» (V2, depende de Cuentas) no está: el panel no lo muestra todavía (`MOSTRAR_POR_COBRAR = false`).
 */

export type Granularidad = "dia" | "semana" | "mes";

/** Lo que se muestra: las medidas del día, una por columna de la tabla. */
export type Medida = "horas" | "presentaciones" | "ventas" | "monto";

/** Lo que un colportor hizo en un día: cifras agregadas, nunca quién compró ni cuánto compró cada persona. */
export interface VentasDelDia {
  presentaciones: number;
  ventas: number;
  /** Monto vendido en el día, en $U. */
  monto: number;
}

/** Un colportor con sus horas y sus ventas por día. Un día que no figura es un día sin datos, no un día de 0. */
export interface ColportorDelReporte {
  id: string;
  /** Nombre y apellido, tal cual se muestran. */
  nombre: string;
  horasPorDia: Readonly<Record<Fecha, number>>;
  ventasPorDia: Readonly<Record<Fecha, VentasDelDia>>;
  /** Su último día con horas, solo si dejó de llegar información y hace falta avisarlo. */
  sinDatosDesde: Fecha | null;
}

/** Una cifra de un período. Sin datos no es lo mismo que 0: se muestra con guion y no lleva tendencia. */
export interface Cifra {
  valor: number;
  hayDatos: boolean;
}

export const CIFRA_SIN_DATOS: Cifra = { valor: 0, hayDatos: false };

/** Cuántos días se dibujan en la vista «Días». */
export const DIAS_EN_VISTA_DIAS = 14;

export interface Calendario {
  inicio: Fecha;
  hoy: Fecha;
  /** Días de la campaña hasta hoy (o hasta su último día, si ya terminó), sin domingos (no se trabaja). */
  diasHabiles: Fecha[];
}

export function crearCalendario(inicio: Fecha, hoy: Fecha, fin: Fecha | null = null): Calendario {
  const ultimo = fin !== null && fin < hoy ? fin : hoy;
  const diasHabiles: Fecha[] = [];
  for (let d = inicio; d <= ultimo; d = sumarDias(d, 1)) {
    if (diaDeSemana(d) !== 0) diasHabiles.push(d);
  }
  return { inicio, hoy, diasHabiles };
}

/** La cifra de un día: de un colportor, o la suma de varios. */
export type Serie = (fecha: Fecha) => Cifra;

/** Cómo se junta la cifra de varios días en la de un período. */
export type Agregar = (dias: Fecha[]) => Cifra;

export function serieDeColportor(colportor: ColportorDelReporte, medida: Medida): Serie {
  if (medida === "horas") {
    return (fecha) => {
      const valor = colportor.horasPorDia[fecha];
      return valor === undefined ? CIFRA_SIN_DATOS : { valor, hayDatos: true };
    };
  }
  return (fecha) => {
    const dia = colportor.ventasPorDia[fecha];
    if (dia === undefined) return CIFRA_SIN_DATOS;
    return { valor: dia[medida], hayDatos: true };
  };
}

export function sumarCifras(cifras: Cifra[]): Cifra {
  let valor = 0;
  let hayDatos = false;
  for (const c of cifras) {
    if (!c.hayDatos) continue;
    valor += c.valor;
    hayDatos = true;
  }
  return hayDatos ? { valor, hayDatos } : CIFRA_SIN_DATOS;
}

export function serieSuma(series: Serie[]): Serie {
  return (fecha) => sumarCifras(series.map((serie) => serie(fecha)));
}

export function cifraDeDias(serie: Serie, dias: Fecha[]): Cifra {
  return sumarCifras(dias.map(serie));
}

export interface Periodo {
  /** Primer día del período. */
  inicio: Fecha;
  /** Rótulo corto de la barra: «S7», «20», «Sep». */
  rotulo: string;
  /** Rótulo largo de la fila: «14/09», «mar 20/10», «septiembre». */
  detalle: string;
  dias: Fecha[];
  /** El período incluye a hoy: todavía no cerró y no se usa para comparar. */
  enCurso: boolean;
}

/** Todos los períodos de la campaña hasta hoy, del más viejo al más nuevo (en «Días», solo los últimos 14). */
export function periodosDe(granularidad: Granularidad, calendario: Calendario): Periodo[] {
  const { diasHabiles, hoy, inicio } = calendario;

  if (granularidad === "dia") {
    return diasHabiles.slice(-DIAS_EN_VISTA_DIAS).map((fecha) => ({
      inicio: fecha,
      rotulo: fecha.slice(8, 10),
      detalle: `${nombreDelDia(fecha)} ${diaYMes(fecha)}`,
      dias: [fecha],
      enCurso: fecha === hoy,
    }));
  }

  if (granularidad === "semana") {
    const primerLunes = lunesDe(inicio);
    const porLunes = new Map<Fecha, Fecha[]>();
    for (const fecha of diasHabiles) {
      const lunes = lunesDe(fecha);
      porLunes.set(lunes, [...(porLunes.get(lunes) ?? []), fecha]);
    }
    return [...porLunes.entries()].map(([lunes, dias]) => ({
      inicio: lunes,
      rotulo: `S${diasEntre(primerLunes, lunes) / 7 + 1}`,
      detalle: diaYMes(lunes),
      dias,
      enCurso: hoy >= lunes && hoy <= sumarDias(lunes, 6),
    }));
  }

  const porMes = new Map<number, Fecha[]>();
  for (const fecha of diasHabiles) {
    const mes = numeroDeMes(fecha);
    porMes.set(mes, [...(porMes.get(mes) ?? []), fecha]);
  }
  return [...porMes.entries()].map(([mes, dias]) => ({
    inicio: dias[0],
    rotulo: rotuloDelMes(mes),
    detalle: nombreDelMes(mes),
    dias,
    enCurso: numeroDeMes(hoy) === mes,
  }));
}

export interface Comparacion {
  /** Qué período se muestra: «S7», «ayer», «oct. a la fecha». */
  rotulo: string;
  /** Contra qué se compara: «contra S6». Vacío si no hay período anterior. */
  contra: string;
  actual: Cifra;
  /** Cifra del período anterior; `null` si no existe. */
  base: Cifra | null;
}

function esAyer(fecha: Fecha, hoy: Fecha): boolean {
  // Los domingos no se trabaja: el día anterior a un lunes es el sábado.
  return fecha === sumarDias(hoy, -1) || (diaDeSemana(hoy) === 1 && fecha === sumarDias(hoy, -2));
}

/**
 * El período que se compara y contra cuál: el día anterior contra el anterior; la última semana completa contra la
 * semana anterior; el mes a la fecha contra el mes pasado a la misma fecha (para que el mes en curso no salga siempre
 * en baja). Lo que está en curso no se compara. `null` si todavía no hay un período completo.
 */
export function compararCon(granularidad: Granularidad, agregar: Agregar, calendario: Calendario): Comparacion | null {
  const { diasHabiles, hoy } = calendario;

  if (granularidad === "dia") {
    const completos = diasHabiles.filter((d) => d !== hoy);
    const actual = completos.at(-1);
    if (actual === undefined) return null;
    const anterior = completos.at(-2);
    return {
      rotulo: esAyer(actual, hoy) ? "ayer" : `${nombreDelDia(actual)} ${diaYMes(actual)}`,
      contra: anterior === undefined ? "" : "contra el día anterior",
      actual: agregar([actual]),
      base: anterior === undefined ? null : agregar([anterior]),
    };
  }

  if (granularidad === "semana") {
    const completas = periodosDe("semana", calendario).filter((p) => !p.enCurso);
    const actual = completas.at(-1);
    if (actual === undefined) return null;
    const anterior = completas.at(-2);
    return {
      rotulo: actual.rotulo,
      contra: anterior === undefined ? "" : `contra ${anterior.rotulo}`,
      actual: agregar(actual.dias),
      base: anterior === undefined ? null : agregar(anterior.dias),
    };
  }

  const meses = [...new Set(diasHabiles.map(numeroDeMes))];
  const ultimo = meses.at(-1);
  if (ultimo === undefined) return null;
  const enCurso = numeroDeMes(hoy) === ultimo;
  const tieneAnterior = meses.at(-2) === ultimo - 1;
  const diasActual = diasHabiles.filter((d) => numeroDeMes(d) === ultimo);
  // El mes en curso se compara con el mismo tramo del anterior (del 1 al día de hoy); uno terminado, entero.
  const diasBase = tieneAnterior
    ? diasHabiles.filter((d) => numeroDeMes(d) === ultimo - 1 && (!enCurso || diaDelMes(d) <= diaDelMes(hoy)))
    : [];
  return {
    rotulo: enCurso ? `${mesAbreviado(ultimo)} a la fecha` : mesAbreviado(ultimo),
    contra: tieneAnterior ? `contra ${mesAbreviado(ultimo - 1)}${enCurso ? " a la misma fecha" : ""}` : "",
    actual: agregar(diasActual),
    base: tieneAnterior ? agregar(diasBase) : null,
  };
}

export interface Tendencia {
  sentido: "sube" | "baja" | "igual";
  /** «+10%», «-8%», «= 0%». (El informe dibuja el triángulo aparte: la tipografía del PDF no trae ▲ ni ▼.) */
  texto: string;
}

/**
 * Tendencia de una cifra contra la del período anterior. Sin tendencia (`null`) si a alguna de las dos le faltan
 * datos o la anterior es 0 (no hay contra qué calcular el porcentaje).
 */
export function tendenciaDe(actual: Cifra, base: Cifra | null): Tendencia | null {
  if (!base || !actual.hayDatos || !base.hayDatos || base.valor === 0) return null;
  const porcentaje = Math.round((actual.valor / base.valor - 1) * 100);
  if (porcentaje > 0) return { sentido: "sube", texto: `${porcentaje}%` };
  if (porcentaje < 0) return { sentido: "baja", texto: `${-porcentaje}%` };
  return { sentido: "igual", texto: "= 0%" };
}

/** Miles con punto: 1450 → «1.450». */
export function formatearEntero(valor: number): string {
  return String(Math.round(valor)).replace(/\B(?=(\d{3})+(?!\d))/g, ".");
}

/** Una posición decimal con coma: 27.4 → «27,4». */
export function formatearDecimal(valor: number): string {
  return valor.toFixed(1).replace(".", ",");
}

/**
 * Cifra para mostrar: «—» sin datos. Las horas van enteras si son el total de varios colportores y con un decimal si
 * son de uno; los $U con «$U » y miles con punto.
 */
export function formatearCifra(cifra: Cifra, total: boolean, medida: Medida): string {
  if (!cifra.hayDatos) return "—";
  switch (medida) {
    case "horas":
      return total ? formatearEntero(cifra.valor) : formatearDecimal(cifra.valor);
    case "monto":
      return `$U ${formatearEntero(cifra.valor)}`;
    default:
      return formatearEntero(cifra.valor);
  }
}

/** Último día con horas anterior a `antesDe`, o `null`. */
export function ultimoDatoAntesDe(colportor: Pick<ColportorDelReporte, "horasPorDia">, antesDe: Fecha): Fecha | null {
  let ultimo: Fecha | null = null;
  for (const fecha of Object.keys(colportor.horasPorDia)) {
    if (fecha < antesDe && (ultimo === null || fecha > ultimo)) ultimo = fecha;
  }
  return ultimo;
}

/** Cómo se junta la cifra de un conjunto de días, para cada medida. */
export type Agregadores = Record<Medida, Agregar>;

/** Los agregadores de un colportor, o de varios juntos (la suma de lo que cada uno tenga en cada día). */
export function agregadoresDe(colportores: ColportorDelReporte[]): Agregadores {
  const suma = (medida: Medida): Agregar => {
    const serie = serieSuma(colportores.map((c) => serieDeColportor(c, medida)));
    return (dias) => cifraDeDias(serie, dias);
  };
  return {
    horas: suma("horas"),
    presentaciones: suma("presentaciones"),
    ventas: suma("ventas"),
    monto: suma("monto"),
  };
}
