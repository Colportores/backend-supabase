import type { ColportorDelReporte, VentasDelDia } from "./calculo.ts";
import { diasEntre, esDiaIso, type Fecha, lunesDe, sumarDias } from "./fechas.ts";

/**
 * Lo que el informe lee de la base: las mismas RPC que usa la vista 32 del panel (Reportes), llamadas con el JWT de la
 * coordinadora (manda la RLS: la función nunca usa la clave de servicio):
 *
 *   · `campanias_del_coordinador()` (0033): la campaña, con su inicio y su fin.
 *   · `horas_por_ciudad_y_colportor()` (0060) y `ventas_por_ciudad_y_colportor()` (0061), por día.
 *   · `zonas_por_colportor()` (0047/0062): quienes están inscriptos aunque todavía no tengan horas.
 *   · `ciudades_de_campania()` (0066): el departamento de cada ciudad.
 *
 * Solo salen totales por colportor: ni clientes, ni personas visitadas, ni ubicaciones (las RPC no los devuelven y
 * acá tampoco se piden).
 */

export const ID_SIN_ZONA = "sin-zona";
export const NOMBRE_SIN_ZONA = "Sin zona asignada";

/** Filas a partir de las cuales una respuesta puede estar cortada por PostgREST (`max_rows`, config.toml). */
export const TOPE_FILAS = 1000;
/** Lo más largo que acepta la RPC por pedido (`22023` si se pasa). */
export const TOPE_DIAS = 366;
/** Días de trabajo (lunes a sábado) seguidos sin horas a partir de los cuales se avisa «sin datos desde». */
export const DIAS_SIN_DATOS = 2;

/** Una falla de la base o del servicio de la API, con el código de Postgres/PostgREST si lo hay. */
export class ErrorDeLaBase extends Error {
  constructor(readonly codigo: string, readonly http: number, mensaje: string) {
    super(mensaje);
    this.name = "ErrorDeLaBase";
  }
}

/** La respuesta de una RPC no tiene la forma del contrato de la base (cambió el backend, no es culpa de la persona). */
export class RespuestaInesperada extends Error {
  constructor(rpc: string, detalle: string) {
    super(`La RPC ${rpc} devolvió algo que no se entiende: ${detalle}.`);
    this.name = "RespuestaInesperada";
  }
}

/** Llama a una RPC con la sesión de quien pidió el informe. */
export type LlamarRpc = (nombre: string, argumentos: Record<string, unknown>) => Promise<unknown>;

export interface CiudadDelReporte {
  id: string;
  nombre: string;
  /** Departamento de la ciudad; `null` si la base todavía no lo sabe (o la campaña terminó y no deja leerlo). */
  departamento: string | null;
  colportores: ColportorDelReporte[];
}

export interface DatosDelReporte {
  campania: { id: string; nombre: string };
  inicioCampania: Fecha;
  finCampania: Fecha | null;
  hoy: Fecha;
  ciudades: CiudadDelReporte[];
}

type Objeto = Record<string, unknown>;

function esObjeto(valor: unknown): valor is Objeto {
  return typeof valor === "object" && valor !== null && !Array.isArray(valor);
}

function filas(rpc: string, respuesta: unknown): Objeto[] {
  if (!Array.isArray(respuesta) || !respuesta.every(esObjeto)) {
    throw new RespuestaInesperada(rpc, "no es una lista de filas");
  }
  return respuesta;
}

function cadena(rpc: string, fila: Objeto, campo: string): string {
  const valor = fila[campo];
  if (typeof valor !== "string") throw new RespuestaInesperada(rpc, `\`${campo}\` no es un texto`);
  return valor;
}

function cadenaONula(rpc: string, fila: Objeto, campo: string): string | null {
  const valor = fila[campo];
  if (valor === null || valor === undefined) return null;
  if (typeof valor !== "string") throw new RespuestaInesperada(rpc, `\`${campo}\` no es un texto ni null`);
  return valor;
}

function numero(rpc: string, fila: Objeto, campo: string): number {
  const valor = fila[campo];
  if (typeof valor !== "number" || !Number.isFinite(valor)) {
    throw new RespuestaInesperada(rpc, `\`${campo}\` no es un número`);
  }
  return valor;
}

function dia(rpc: string, fila: Objeto, campo: string): Fecha {
  const valor = cadena(rpc, fila, campo);
  if (!esDiaIso(valor)) throw new RespuestaInesperada(rpc, `\`${campo}\` no es un día (${valor})`);
  return valor;
}

function nombreVisible(nombre: string, apellido: string, alternativa: string): string {
  return `${nombre} ${apellido}`.trim() || alternativa;
}

/** La campaña se terminó o se dio de baja entre una llamada y la siguiente. */
function campaniaYaNoVigente(error: unknown): boolean {
  return error instanceof ErrorDeLaBase && (error.codigo === "CZ001" || error.codigo === "CZ011");
}

const COLLATOR = new Intl.Collator("es", { sensitivity: "base" });

/**
 * Las filas de una RPC por día entre `desde` y `hasta` (ambos incluidos), partiendo el pedido a la mitad mientras el
 * rango pase de `TOPE_DIAS` o la respuesta pueda estar cortada (`TOPE_FILAS`): PostgREST corta en silencio en
 * `max_rows` y se perderían los días más nuevos. Los tramos no se superponen, así que no hay filas repetidas. Un solo
 * día con `TOPE_FILAS` filas o más no se puede partir: sale como error, nunca como datos a medias.
 */
async function leerPorDia(
  llamar: LlamarRpc,
  rpc: string,
  campaniaId: string,
  desde: Fecha,
  hasta: Fecha,
): Promise<Objeto[]> {
  const dias = diasEntre(desde, hasta) + 1;
  const partir = async (): Promise<Objeto[]> => {
    const mitad = sumarDias(desde, Math.floor(dias / 2) - 1);
    const [primera, segunda] = await Promise.all([
      leerPorDia(llamar, rpc, campaniaId, desde, mitad),
      leerPorDia(llamar, rpc, campaniaId, sumarDias(mitad, 1), hasta),
    ]);
    return [...primera, ...segunda];
  };

  if (dias > TOPE_DIAS) return partir();

  const leidas = filas(
    rpc,
    await llamar(rpc, {
      p_campania_id: campaniaId,
      p_desde: desde,
      p_hasta: hasta,
      p_agrupar: "dia",
      p_ciudad_id: null,
      p_colportor_ids: null,
    }),
  );
  if (leidas.length < TOPE_FILAS) return leidas;
  if (dias === 1) {
    throw new RespuestaInesperada(
      rpc,
      `el día ${desde} trae ${leidas.length} filas o más y la respuesta puede estar cortada`,
    );
  }
  return partir();
}

interface ColportorAcumulado {
  id: string;
  nombre: string;
  apellido: string;
  nombreSolo: string;
  horasPorDia: Record<Fecha, number>;
  ventasPorDia: Record<Fecha, VentasDelDia>;
}

interface CiudadAcumulada {
  id: string;
  nombre: string;
  colportores: Map<string, ColportorAcumulado>;
}

/**
 * El último día con horas, si desde entonces pasaron `DIAS_SIN_DATOS` o más días de trabajo (lunes a sábado) sin horas,
 * sin contar `hoy` ni lo que quede después de `ultimoDia` (el último día de una campaña terminada); si no, `null`.
 */
export function sinDatosDesde(horasPorDia: Record<Fecha, number>, hoy: Fecha, ultimoDia: Fecha): Fecha | null {
  const conHoras = Object.keys(horasPorDia).sort();
  const ultimoConHoras = conHoras[conHoras.length - 1];
  if (ultimoConHoras === undefined) return null;
  const hasta = sumarDias(hoy, -1) < ultimoDia ? sumarDias(hoy, -1) : ultimoDia;
  let sinHoras = 0;
  for (let d = sumarDias(ultimoConHoras, 1); d <= hasta; d = sumarDias(d, 1)) {
    const esDomingo = diasEntre(lunesDe(d), d) === 6;
    if (!esDomingo && !(d in horasPorDia)) sinHoras++;
  }
  return sinHoras >= DIAS_SIN_DATOS ? ultimoConHoras : null;
}

/** Los departamentos por id de ciudad. Una campaña terminada no deja leerlos (`CZ011`): sus ciudades quedan sin departamento. */
async function departamentos(llamar: LlamarRpc, campaniaId: string): Promise<Map<string, string | null>> {
  const rpc = "ciudades_de_campania";
  try {
    const ciudades = filas(rpc, await llamar(rpc, { p_campania_id: campaniaId }));
    return new Map(ciudades.map((c) => [cadena(rpc, c, "ciudad_id"), cadenaONula(rpc, c, "departamento")]));
  } catch (error) {
    if (error instanceof ErrorDeLaBase && error.codigo === "CZ011") return new Map();
    throw error;
  }
}

/**
 * La campaña con la que se arma el informe: la que pide la coordinadora si figura en `campanias_del_coordinador()` y, si
 * no pidió ninguna o ya no figura (terminó o se dio de baja), la primera de la lista, igual que el panel (el id viene
 * del navegador, así que solo vale si figura en la lista de quien llama). `null` si no tiene ninguna.
 */
export async function elegirCampania(
  llamar: LlamarRpc,
  pedida: string | null,
): Promise<{ id: string; nombre: string; fechaInicio: Fecha; fechaFin: Fecha | null } | null> {
  const rpc = "campanias_del_coordinador";
  const todas = filas(rpc, await llamar(rpc, {}));
  const elegida = todas.find((fila) => fila.id === pedida) ?? todas[0];
  if (!elegida) return null;
  return {
    id: cadena(rpc, elegida, "id"),
    nombre: cadena(rpc, elegida, "nombre"),
    fechaInicio: dia(rpc, elegida, "fecha_inicio"),
    fechaFin: cadenaONula(rpc, elegida, "fecha_fin") === null ? null : dia(rpc, elegida, "fecha_fin"),
  };
}

/**
 * Las ciudades de la campaña con los colportores de sus zonas, con las horas y las ventas de cada día (la misma forma
 * que arma el panel para la vista 32):
 *
 *   · Se pide **por día** desde el primer día de la campaña hasta hoy (o su último día, si terminó); las semanas y los
 *     meses y la tendencia salen de `calculo.ts`.
 *   · Una fila de horas con `jornadas = 0` existe solo para la comparación del servidor: un día sin jornadas cerradas
 *     es un día **sin datos**, no un día de 0 horas.
 *   · Ventas: un día tiene datos si el colportor vendió o presentó algo, o si trabajó (jornada cerrada): ahí 0 ventas
 *     es 0 de verdad. Las filas en cero de la RPC (que existen por el período anterior) de un día sin jornada no
 *     cuentan como datos. `monto_total` llega en centavos y se pasa a $U.
 *   · La ciudad es la de la zona **actual** del colportor; quienes no tienen zona van una sola vez en «Sin zona
 *     asignada», al final.
 *   · Quienes están inscriptos y todavía no tienen horas figuran igual (con guion), por `zonas_por_colportor()`.
 *
 * Devuelve `null` si no hay una campaña que consultar: ninguna, una que todavía no empezó, o una que se terminó o se
 * dio de baja mientras se leía (`CZ001`, `CZ011`).
 */
export async function leerDatos(
  llamar: LlamarRpc,
  campaniaPedida: string | null,
  hoy: Fecha,
): Promise<DatosDelReporte | null> {
  const campania = await elegirCampania(llamar, campaniaPedida);
  if (!campania) return null;
  // Una campaña por empezar no tiene nada que leer (la RPC rechazaría un rango al revés).
  if (campania.fechaInicio > hoy) return null;
  const hasta = campania.fechaFin !== null && campania.fechaFin < hoy ? campania.fechaFin : hoy;

  let filasDeHoras: Objeto[];
  let filasDeVentas: Objeto[];
  let inscriptos: unknown;
  let departamentoDe: Map<string, string | null>;
  try {
    [filasDeHoras, filasDeVentas, inscriptos, departamentoDe] = await Promise.all([
      leerPorDia(llamar, "horas_por_ciudad_y_colportor", campania.id, campania.fechaInicio, hasta),
      leerPorDia(llamar, "ventas_por_ciudad_y_colportor", campania.id, campania.fechaInicio, hasta),
      llamar("zonas_por_colportor", { p_campania_id: campania.id }),
      departamentos(llamar, campania.id),
    ]);
  } catch (error) {
    if (campaniaYaNoVigente(error)) return null;
    throw error;
  }

  const ciudades = new Map<string, CiudadAcumulada>();
  const sinZona: CiudadAcumulada = { id: ID_SIN_ZONA, nombre: NOMBRE_SIN_ZONA, colportores: new Map() };
  const todos = new Map<string, ColportorAcumulado>();

  const grupoDe = (rpc: string, fila: Objeto): CiudadAcumulada => {
    const ciudadId = cadenaONula(rpc, fila, "ciudad_id");
    if (ciudadId === null) return sinZona;
    let existente = ciudades.get(ciudadId);
    if (!existente) {
      existente = {
        id: ciudadId,
        nombre: cadenaONula(rpc, fila, "ciudad_nombre") ?? "Ciudad sin nombre",
        colportores: new Map(),
      };
      ciudades.set(ciudadId, existente);
    }
    return existente;
  };

  const colportorDe = (rpc: string, ciudad: CiudadAcumulada, fila: Objeto): ColportorAcumulado => {
    const colportorId = cadena(rpc, fila, "colportor_id");
    let acumulado = ciudad.colportores.get(colportorId);
    if (!acumulado) {
      const nombre = cadenaONula(rpc, fila, "nombre") ?? "";
      const apellido = cadenaONula(rpc, fila, "apellido") ?? "";
      acumulado = {
        id: colportorId,
        nombre: nombreVisible(nombre, apellido, "Colportor sin nombre"),
        apellido,
        nombreSolo: nombre,
        horasPorDia: {},
        ventasPorDia: {},
      };
      ciudad.colportores.set(colportorId, acumulado);
      todos.set(colportorId, acumulado);
    }
    return acumulado;
  };

  const conHoras = new Set<string>();
  for (const fila of filasDeHoras) {
    const rpc = "horas_por_ciudad_y_colportor";
    const acumulado = colportorDe(rpc, grupoDe(rpc, fila), fila);
    conHoras.add(acumulado.id);
    // El colportor figura aunque este día no tenga jornadas; el día solo entra si tuvo alguna cerrada.
    if (numero(rpc, fila, "jornadas") > 0) {
      const fecha = dia(rpc, fila, "periodo_inicio");
      acumulado.horasPorDia[fecha] =
        Math.round(((acumulado.horasPorDia[fecha] ?? 0) + numero(rpc, fila, "horas")) * 100) / 100;
    }
  }

  for (const fila of filasDeVentas) {
    const rpc = "ventas_por_ciudad_y_colportor";
    const acumulado = colportorDe(rpc, grupoDe(rpc, fila), fila);
    const fecha = dia(rpc, fila, "periodo_inicio");
    const ventas = numero(rpc, fila, "ventas");
    const presentaciones = numero(rpc, fila, "presentaciones");
    const monto = numero(rpc, fila, "monto_total") / 100;
    // Una fila en cero de un día sin jornada cerrada existe solo para comparar con el período anterior: no es un dato.
    const trabajo = fecha in acumulado.horasPorDia;
    if (ventas === 0 && presentaciones === 0 && monto === 0 && !trabajo) continue;
    const previo = acumulado.ventasPorDia[fecha];
    acumulado.ventasPorDia[fecha] = {
      ventas: (previo?.ventas ?? 0) + ventas,
      presentaciones: (previo?.presentaciones ?? 0) + presentaciones,
      monto: Math.round(((previo?.monto ?? 0) + monto) * 100) / 100,
    };
  }

  // Un colportor que trabajó un día y no vendió nada tiene 0 ventas ese día, no «sin datos».
  for (const colportor of todos.values()) {
    for (const fecha of Object.keys(colportor.horasPorDia)) {
      colportor.ventasPorDia[fecha] ??= { ventas: 0, presentaciones: 0, monto: 0 };
    }
  }

  // Los inscriptos que todavía no tienen ninguna fila figuran sin horas (guion), en su ciudad o sin zona.
  const rpcInscriptos = "zonas_por_colportor";
  for (const fila of filas(rpcInscriptos, inscriptos)) {
    if (todos.has(cadena(rpcInscriptos, fila, "colportor_id"))) continue;
    colportorDe(rpcInscriptos, grupoDe(rpcInscriptos, fila), fila);
  }

  const aCiudad = (c: CiudadAcumulada, departamento: string | null): CiudadDelReporte => ({
    id: c.id,
    nombre: c.nombre,
    departamento,
    colportores: [...c.colportores.values()]
      .sort((a, b) => COLLATOR.compare(a.apellido, b.apellido) || COLLATOR.compare(a.nombreSolo, b.nombreSolo))
      .map((a): ColportorDelReporte => ({
        id: a.id,
        nombre: a.nombre,
        horasPorDia: a.horasPorDia,
        ventasPorDia: a.ventasPorDia,
        sinDatosDesde: sinDatosDesde(a.horasPorDia, hoy, hasta),
      })),
  });

  const lista = [...ciudades.values()]
    .sort((a, b) => COLLATOR.compare(a.nombre, b.nombre))
    .map((c) => aCiudad(c, departamentoDe.get(c.id) ?? null));
  if (sinZona.colportores.size > 0) lista.push(aCiudad(sinZona, null));

  return {
    campania: { id: campania.id, nombre: campania.nombre },
    inicioCampania: campania.fechaInicio,
    finCampania: campania.fechaFin,
    hoy,
    ciudades: lista,
  };
}
