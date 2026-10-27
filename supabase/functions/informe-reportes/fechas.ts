/**
 * Cuentas con fechas de calendario (`AAAA-MM-DD`) sin pasar por la zona horaria del servidor: todo se hace en UTC
 * sobre el día, así «el lunes de esta semana» da lo mismo en cualquier lugar. Son las mismas reglas que usa el panel
 * en pantalla (`src/datos/reportes/fechas.ts` de front-coordinadores-web): el informe tiene que decir lo mismo.
 */

/** Un día de calendario `AAAA-MM-DD`, el de Montevideo (el de la jornada), nunca con hora. */
export type Fecha = string;

const MS_POR_DIA = 86_400_000;
const DIA_ISO = /^(\d{4})-(\d{2})-(\d{2})$/;

const DIAS_ABREVIADOS = ["dom", "lun", "mar", "mié", "jue", "vie", "sáb"] as const;
const MESES = [
  "enero",
  "febrero",
  "marzo",
  "abril",
  "mayo",
  "junio",
  "julio",
  "agosto",
  "septiembre",
  "octubre",
  "noviembre",
  "diciembre",
] as const;

const DIA_EN_MONTEVIDEO = new Intl.DateTimeFormat("en-CA", {
  timeZone: "America/Montevideo",
  year: "numeric",
  month: "2-digit",
  day: "2-digit",
});

/** El día de hoy en Montevideo: a las 22:00 de allá sigue siendo el mismo día aunque en UTC ya sea el siguiente. */
export function hoyEnMontevideo(ahora: Date): Fecha {
  return DIA_EN_MONTEVIDEO.format(ahora);
}

export function esDiaIso(valor: unknown): valor is Fecha {
  if (typeof valor !== "string") return false;
  const partes = DIA_ISO.exec(valor);
  if (!partes) return false;
  const fecha = new Date(Date.UTC(Number(partes[1]), Number(partes[2]) - 1, Number(partes[3])));
  return fecha.toISOString().slice(0, 10) === valor;
}

function aMs(fecha: Fecha): number {
  const partes = DIA_ISO.exec(fecha);
  if (!partes) throw new Error(`«${fecha}» no es un día AAAA-MM-DD`);
  return Date.UTC(Number(partes[1]), Number(partes[2]) - 1, Number(partes[3]));
}

export function sumarDias(fecha: Fecha, dias: number): Fecha {
  return new Date(aMs(fecha) + dias * MS_POR_DIA).toISOString().slice(0, 10);
}

/** Días entre dos fechas (`hasta - desde`). */
export function diasEntre(desde: Fecha, hasta: Fecha): number {
  return Math.round((aMs(hasta) - aMs(desde)) / MS_POR_DIA);
}

/** 0 = domingo … 6 = sábado. */
export function diaDeSemana(fecha: Fecha): number {
  return new Date(aMs(fecha)).getUTCDay();
}

/** El lunes de la semana de la fecha (las semanas van de lunes a domingo). */
export function lunesDe(fecha: Fecha): Fecha {
  return sumarDias(fecha, -((diaDeSemana(fecha) + 6) % 7));
}

/** Mes de la fecha como número corrido (año × 12 + mes), para comparar y recorrer meses. */
export function numeroDeMes(fecha: Fecha): number {
  const [anio, mes] = fecha.split("-").map(Number);
  return anio * 12 + (mes - 1);
}

export function diaDelMes(fecha: Fecha): number {
  return Number(fecha.slice(8, 10));
}

/** `2026-10-20` → `20/10`. */
export function diaYMes(fecha: Fecha): string {
  return `${fecha.slice(8, 10)}/${fecha.slice(5, 7)}`;
}

/** `2026-10-21` → `21/10/2026`. */
export function fechaCompleta(fecha: Fecha): string {
  return `${diaYMes(fecha)}/${fecha.slice(0, 4)}`;
}

/** `2026-10-20` → `mar`. */
export function nombreDelDia(fecha: Fecha): string {
  return DIAS_ABREVIADOS[diaDeSemana(fecha)];
}

/** Nombre completo del mes en minúscula (`septiembre`) de un número de mes corrido. */
export function nombreDelMes(numero: number): string {
  return MESES[numero % 12];
}

/** Tres letras con la inicial en mayúscula (`Sep`): rótulo de la barra del mes. */
export function rotuloDelMes(numero: number): string {
  const corto = nombreDelMes(numero).slice(0, 3);
  return corto.charAt(0).toUpperCase() + corto.slice(1);
}

/** Tres letras con punto (`sep.`), para frases como «contra sep. a la misma fecha». */
export function mesAbreviado(numero: number): string {
  return `${nombreDelMes(numero).slice(0, 3)}.`;
}
