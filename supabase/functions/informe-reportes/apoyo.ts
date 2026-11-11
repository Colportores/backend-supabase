import { ErrorDeLaBase, type LlamarRpc } from "./datos.ts";
import type { Fecha } from "./fechas.ts";
import { sumarDias } from "./fechas.ts";

/** Ayudas de los tests: un «mundo» en memoria que contesta las RPC como PostgREST (con su tope de filas). */

export const CAMPANIA = "01920000-0000-7000-8000-000000000001";

export interface ColportorDePrueba {
  id: string;
  nombre: string;
  apellido: string;
  ciudadId: string | null;
  ciudadNombre: string | null;
  /** Jornadas cerradas: día → horas. */
  horas?: Record<Fecha, number>;
  /** Ventas: día → [ventas, presentaciones, monto en centavos]. */
  ventas?: Record<Fecha, [number, number, number]>;
  /** Figura en `zonas_por_colportor` (inscripto) aunque no tenga filas. */
  inscripto?: boolean;
}

export interface Mundo {
  campanias: { id: string; nombre: string; fecha_inicio: string; fecha_fin: string | null }[];
  colportores: ColportorDePrueba[];
  departamentos: Record<string, string | null>;
  /** El tope de filas de PostgREST (`max_rows`). */
  maxFilas: number;
  /** Códigos de error por RPC: la RPC falla con ese SQLSTATE. */
  fallas: Record<string, string>;
}

export function mundoVacio(parcial: Partial<Mundo> = {}): Mundo {
  return {
    campanias: [{ id: CAMPANIA, nombre: "Campaña de prueba", fecha_inicio: "2026-10-05", fecha_fin: null }],
    colportores: [],
    departamentos: {},
    maxFilas: 1000,
    fallas: {},
    ...parcial,
  };
}

export function uuid(n: number): string {
  return `01920000-0000-7000-8000-${String(n).padStart(12, "0")}`;
}

export interface LlamadaRegistrada {
  nombre: string;
  argumentos: Record<string, unknown>;
}

function dias(desde: Fecha, hasta: Fecha): Fecha[] {
  const lista: Fecha[] = [];
  for (let d = desde; d <= hasta; d = sumarDias(d, 1)) lista.push(d);
  return lista;
}

export function rpcDe(mundo: Mundo): { llamar: LlamarRpc; llamadas: LlamadaRegistrada[] } {
  const llamadas: LlamadaRegistrada[] = [];
  const llamar: LlamarRpc = (nombre, argumentos) => {
    llamadas.push({ nombre, argumentos });
    const falla = mundo.fallas[nombre];
    if (falla) {
      return Promise.reject(new ErrorDeLaBase(falla, falla === "42501" ? 403 : 400, `falla de prueba en ${nombre}`));
    }

    const identidad = (c: ColportorDePrueba) => ({
      colportor_id: c.id,
      nombre: c.nombre,
      apellido: c.apellido,
      ciudad_id: c.ciudadId,
      ciudad_nombre: c.ciudadNombre,
    });
    const recortar = <T>(filas: T[]): T[] => filas.slice(0, mundo.maxFilas);

    switch (nombre) {
      case "campanias_del_coordinador":
        return Promise.resolve(mundo.campanias.map((c) => ({ ...c, tipo: "NORMAL" })));
      case "ciudades_de_campania":
        return Promise.resolve(
          Object.entries(mundo.departamentos).map(([ciudad_id, departamento]) => ({ ciudad_id, departamento })),
        );
      case "zonas_por_colportor":
        return Promise.resolve(mundo.colportores.filter((c) => c.inscripto).map(identidad));
      case "horas_por_ciudad_y_colportor": {
        const desde = argumentos.p_desde as Fecha;
        const hasta = argumentos.p_hasta as Fecha;
        const filas = dias(desde, hasta).flatMap((dia) =>
          mundo.colportores.flatMap((c) =>
            c.horas && dia in c.horas
              ? [{ ...identidad(c), periodo_inicio: dia, periodo_fin: dia, horas: c.horas[dia], jornadas: 1 }]
              : []
          )
        );
        return Promise.resolve(recortar(filas));
      }
      case "ventas_por_ciudad_y_colportor": {
        const desde = argumentos.p_desde as Fecha;
        const hasta = argumentos.p_hasta as Fecha;
        const filas = dias(desde, hasta).flatMap((dia) =>
          mundo.colportores.flatMap((c) =>
            c.ventas && dia in c.ventas
              ? [{
                ...identidad(c),
                periodo_inicio: dia,
                periodo_fin: dia,
                ventas: c.ventas[dia][0],
                presentaciones: c.ventas[dia][1],
                monto_total: c.ventas[dia][2],
              }]
              : []
          )
        );
        return Promise.resolve(recortar(filas));
      }
      default:
        return Promise.reject(new Error(`RPC inesperada en la prueba: ${nombre}`));
    }
  };
  return { llamar, llamadas };
}

/** Un colportor de Rivera con horas de lunes a sábado entre `desde` y `hasta` y ventas esos días. */
export function colportorQueTrabaja(
  n: number,
  nombre: string,
  apellido: string,
  desde: Fecha,
  hasta: Fecha,
  extra: Partial<ColportorDePrueba> = {},
): ColportorDePrueba {
  const horas: Record<Fecha, number> = {};
  const ventas: Record<Fecha, [number, number, number]> = {};
  for (const dia of dias(desde, hasta)) {
    if (new Date(`${dia}T00:00:00Z`).getUTCDay() === 0) continue;
    horas[dia] = 6;
    ventas[dia] = [2, 5, 150_000];
  }
  return {
    id: uuid(100 + n),
    nombre,
    apellido,
    ciudadId: uuid(10),
    ciudadNombre: "Rivera",
    horas,
    ventas,
    ...extra,
  };
}
