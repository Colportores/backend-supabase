import {
  type Agregadores,
  agregadoresDe,
  type Calendario,
  type Cifra,
  CIFRA_SIN_DATOS,
  type ColportorDelReporte,
  compararCon,
  crearCalendario,
  formatearCifra,
  type Granularidad,
  type Medida,
  type Periodo,
  periodosDe,
  type Tendencia,
  tendenciaDe,
  ultimoDatoAntesDe,
} from "./calculo.ts";
import type { CiudadDelReporte, DatosDelReporte } from "./datos.ts";
import { diaYMes, type Fecha } from "./fechas.ts";

/**
 * Todo lo que muestra la vista 32 para un ámbito y una agrupación, armado con los mismos nombres, textos y cuentas que
 * el panel (`armado.ts`, `ambito.ts` y `metricas.ts` de front-coordinadores-web): el informe dice lo mismo que la
 * pantalla. Nunca lleva datos de clientes: solo el nombre del colportor y totales.
 */

/** Qué mira el reporte: todas las ciudades, un departamento, una ciudad o un colportor. */
export type Ambito =
  | { tipo: "todas" }
  | { tipo: "departamento"; departamento: string }
  | { tipo: "ciudad"; ciudadId: string }
  | { tipo: "colportor"; colportorId: string };

export interface AmbitoResuelto {
  ciudades: CiudadDelReporte[];
  /** Si se eligió un colportor: él y su ciudad. */
  colportor: { colportor: ColportorDelReporte; ciudad: CiudadDelReporte } | null;
  colportores: ColportorDelReporte[];
  titulo: string;
}

export function pluralColportores(cantidad: number): string {
  return `${cantidad} ${cantidad === 1 ? "colportor" : "colportores"}`;
}

/** Un ámbito que ya no existe en los datos (la ciudad o el colportor desaparecieron) vuelve a «todas», como en el panel. */
export function resolverAmbito(datos: DatosDelReporte, ambito: Ambito): AmbitoResuelto {
  const todas = (): AmbitoResuelto => ({
    ciudades: datos.ciudades,
    colportor: null,
    colportores: datos.ciudades.flatMap((c) => c.colportores),
    titulo: "Todas las ciudades",
  });

  if (ambito.tipo === "departamento") {
    const ciudades = datos.ciudades.filter((c) => c.departamento === ambito.departamento);
    if (ciudades.length === 0) return todas();
    return {
      ciudades,
      colportor: null,
      colportores: ciudades.flatMap((c) => c.colportores),
      titulo: `Departamento ${ambito.departamento}`,
    };
  }

  if (ambito.tipo === "ciudad") {
    const ciudad = datos.ciudades.find((c) => c.id === ambito.ciudadId);
    if (!ciudad) return todas();
    return { ciudades: [ciudad], colportor: null, colportores: ciudad.colportores, titulo: ciudad.nombre };
  }

  if (ambito.tipo === "colportor") {
    for (const ciudad of datos.ciudades) {
      const colportor = ciudad.colportores.find((c) => c.id === ambito.colportorId);
      if (colportor) {
        return {
          ciudades: [ciudad],
          colportor: { colportor, ciudad },
          colportores: [colportor],
          titulo: colportor.nombre,
        };
      }
    }
  }

  return todas();
}

export interface BarraDeCifra {
  rotulo: string;
  /** Alto relativo (0 a 1) respecto de la barra más alta de la tarjeta. */
  proporcion: number;
  sinDatos: boolean;
  enCurso: boolean;
}

export interface TarjetaArmada {
  clave: Medida;
  etiqueta: string;
  valor: string;
  tendencia: Tendencia | null;
  nota: string;
  campania: string;
  barras: BarraDeCifra[];
}

export interface CeldaDeTabla {
  clave: Medida;
  valor: string;
  sinDatos: boolean;
  tendencia: Tendencia | null;
}

export type FilaDeTabla =
  | { tipo: "grupo"; nombre: string; detalle: string }
  | { tipo: "fila"; nombre: string; nota: string | null; celdas: CeldaDeTabla[] };

export interface ReporteArmado {
  titulo: string;
  subtitulo: string;
  /** El período que se mira y contra cuál se compara: «S7 contra S6». Vacío si todavía no hay un período completo. */
  periodo: string;
  /** Con un colportor elegido: la ciudad y el departamento en el filtro «Ver». */
  vistaElegida: string | null;
  tarjetas: TarjetaArmada[];
  tabla: {
    descripcion: string;
    primeraColumna: string;
    columnas: { clave: Medida; encabezado: string }[];
    filas: FilaDeTabla[];
  };
}

interface DefinicionDeCifra {
  clave: Medida;
  /** Encabezado de la columna de la tabla. */
  columna: string;
  /** Nombre en la tarjeta (en mayúsculas) y en la frase del gráfico; `null` si no tiene tarjeta (el monto va con las ventas). */
  tarjeta: { etiqueta: string } | null;
  /** Cómo se nombra en la descripción de la tabla. */
  nombre: string;
}

/** Las cifras que la vista muestra, en el orden del diseño. */
const CIFRAS: DefinicionDeCifra[] = [
  { clave: "horas", columna: "HORAS", tarjeta: { etiqueta: "HORAS" }, nombre: "horas" },
  {
    clave: "presentaciones",
    columna: "PRESENTACIONES",
    tarjeta: { etiqueta: "PRESENTACIONES" },
    nombre: "presentaciones",
  },
  { clave: "ventas", columna: "VENTAS", tarjeta: { etiqueta: "VENTAS" }, nombre: "ventas" },
  { clave: "monto", columna: "MONTO", tarjeta: null, nombre: "monto" },
];

export const ETIQUETA_DE_GRANULARIDAD: Record<Granularidad, string> = { dia: "Días", semana: "Semanas", mes: "Meses" };
const NOMBRE_DE_GRANULARIDAD: Record<Granularidad, string> = { dia: "día", semana: "semana", mes: "mes" };
const PRIMERA_COLUMNA_DEL_COLPORTOR: Record<Granularidad, string> = { dia: "DÍA", semana: "SEMANA", mes: "MES" };

function listarNombres(cifras: DefinicionDeCifra[]): string {
  const nombres = cifras.map((c) => c.nombre);
  if (nombres.length <= 1) return nombres.join("");
  return `${nombres.slice(0, -1).join(", ")} y ${nombres[nombres.length - 1]}`;
}

function capitalizar(texto: string): string {
  return texto.charAt(0).toUpperCase() + texto.slice(1);
}

export function textoSinDatosDesde(fecha: Fecha): string {
  return `sin datos desde el ${diaYMes(fecha)}`;
}

export function armarReporte(datos: DatosDelReporte, ambito: Ambito, granularidad: Granularidad): ReporteArmado {
  const resuelto = resolverAmbito(datos, ambito);
  const calendario = crearCalendario(datos.inicioCampania, datos.hoy, datos.finCampania);
  const elegido = resuelto.colportor;
  // Una cifra de varios colportores se muestra entera; la de uno solo, con un decimal.
  const esTotal = elegido === null;

  const periodos = periodosDe(granularidad, calendario);
  const agregadores = agregadoresDe(resuelto.colportores);
  const tarjetas = CIFRAS.flatMap((cifra) => {
    const tarjeta = armarTarjeta(cifra, agregadores, granularidad, calendario, periodos, esTotal);
    return tarjeta ? [tarjeta] : [];
  });

  // Qué período se compara no depende de la cifra: sale de los días y las semanas del calendario.
  const comparacion = compararCon(granularidad, agregadores.horas, calendario);
  const rotuloActual = comparacion?.rotulo ?? null;
  const frasePeriodo = comparacion ? [comparacion.rotulo, comparacion.contra].filter(Boolean).join(" ") : "";

  const unaCiudad = resuelto.ciudades.length === 1 ? resuelto.ciudades[0] : null;
  const ubicacion = elegido
    ? [elegido.ciudad.nombre, elegido.ciudad.departamento ? `Departamento ${elegido.ciudad.departamento}` : null]
      .filter(Boolean)
      .join(" · ")
    : [
      unaCiudad?.departamento ? `Departamento ${unaCiudad.departamento}` : null,
      pluralColportores(resuelto.colportores.length),
    ]
      .filter(Boolean)
      .join(" · ");

  const nombres = listarNombres(CIFRAS);
  let filas: FilaDeTabla[];
  let primeraColumna: string;
  let descripcion: string;

  if (elegido) {
    descripcion = `${capitalizar(nombres)} de ${elegido.colportor.nombre} por ${NOMBRE_DE_GRANULARIDAD[granularidad]}`;
    primeraColumna = PRIMERA_COLUMNA_DEL_COLPORTOR[granularidad];
    const propios = agregadoresDe([elegido.colportor]);
    const cifrasDePeriodos = periodos.map((p) => CIFRAS.map((c) => propios[c.clave](p.dias)));
    filas = periodos.map((p, i) => {
      const sinDatos = !propios.horas(p.dias).hayDatos;
      const ultimo = sinDatos ? ultimoDatoAntesDe(elegido.colportor, p.inicio) : null;
      return {
        tipo: "fila",
        nombre: granularidad === "semana" ? `${p.rotulo} · ${p.detalle}` : p.detalle,
        nota: sinDatos
          ? (ultimo ? `sin datos · últimos datos el ${diaYMes(ultimo)}` : "sin datos")
          : p.enCurso
          ? "en curso"
          : null,
        celdas: CIFRAS.map((c, k): CeldaDeTabla => {
          const cifra = cifrasDePeriodos[i][k];
          return {
            clave: c.clave,
            valor: formatearCifra(cifra, false, c.clave),
            sinDatos: !cifra.hayDatos,
            // Cada fila compara con la anterior; la que está en curso no lleva tendencia.
            tendencia: i > 0 && !p.enCurso ? tendenciaDe(cifra, cifrasDePeriodos[i - 1][k]) : null,
          };
        }),
      };
    });
  } else {
    descripcion = `${capitalizar(nombres)} por colportor, ${NOMBRE_DE_GRANULARIDAD[granularidad]}`;
    primeraColumna = rotuloActual ? `COLPORTOR · ${rotuloActual.toUpperCase()}` : "COLPORTOR";
    filas = [];
    for (const ciudad of resuelto.ciudades) {
      if (resuelto.ciudades.length > 1) {
        filas.push({ tipo: "grupo", nombre: ciudad.nombre, detalle: pluralColportores(ciudad.colportores.length) });
      }
      for (const colportor of ciudad.colportores) {
        const propios = agregadoresDe([colportor]);
        const comparaciones = CIFRAS.map((c) => compararCon(granularidad, propios[c.clave], calendario));
        const horas = compararCon(granularidad, propios.horas, calendario)?.actual ?? CIFRA_SIN_DATOS;
        filas.push({
          tipo: "fila",
          nombre: colportor.nombre,
          nota: horas.hayDatos
            ? null
            : colportor.sinDatosDesde
            ? textoSinDatosDesde(colportor.sinDatosDesde)
            : "sin datos",
          celdas: CIFRAS.map((c, k): CeldaDeTabla => {
            const propia = comparaciones[k];
            const actual = propia?.actual ?? CIFRA_SIN_DATOS;
            return {
              clave: c.clave,
              valor: formatearCifra(actual, false, c.clave),
              sinDatos: !actual.hayDatos,
              tendencia: propia ? tendenciaDe(propia.actual, propia.base) : null,
            };
          }),
        });
      }
    }
  }

  return {
    titulo: resuelto.titulo,
    subtitulo: [ubicacion, frasePeriodo].filter(Boolean).join(" · "),
    periodo: frasePeriodo,
    vistaElegida: elegido ? `${elegido.colportor.nombre} (${elegido.ciudad.nombre})` : null,
    tarjetas,
    tabla: {
      descripcion,
      primeraColumna,
      columnas: CIFRAS.map((c) => ({ clave: c.clave, encabezado: c.columna })),
      filas,
    },
  };
}

/** La tarjeta de una cifra, o nada si esa cifra no tiene tarjeta (el monto va dentro de la de ventas). */
function armarTarjeta(
  cifra: DefinicionDeCifra,
  agregadores: Agregadores,
  granularidad: Granularidad,
  calendario: Calendario,
  periodos: Periodo[],
  esTotal: boolean,
): TarjetaArmada | null {
  if (!cifra.tarjeta) return null;
  const agregar = agregadores[cifra.clave];
  const comparacion = compararCon(granularidad, agregar, calendario);
  const cifrasDePeriodos: Cifra[] = periodos.map((p) => agregar(p.dias));

  const maximo = Math.max(1, ...cifrasDePeriodos.filter((c) => c.hayDatos).map((c) => c.valor));
  const barras: BarraDeCifra[] = periodos.map((p, i) => ({
    rotulo: p.rotulo,
    proporcion: cifrasDePeriodos[i].valor / maximo,
    sinDatos: !cifrasDePeriodos[i].hayDatos,
    enCurso: p.enCurso,
  }));

  const nota = !comparacion
    ? "Todavía no hay un período completo"
    : comparacion.actual.hayDatos
    ? [comparacion.rotulo, comparacion.contra].filter(Boolean).join(" · ")
    : `${comparacion.rotulo}: sin datos`;

  const deLaCampania = agregar(calendario.diasHabiles);
  // Las ventas de la campaña van con lo que sumaron en $U.
  const montoDeLaCampania = cifra.clave === "ventas" ? agregadores.monto(calendario.diasHabiles) : CIFRA_SIN_DATOS;
  const campania = [
    `Campaña: ${formatearCifra(deLaCampania, true, cifra.clave)}`,
    montoDeLaCampania.hayDatos ? formatearCifra(montoDeLaCampania, true, "monto") : null,
  ]
    .filter(Boolean)
    .join(" · ");

  return {
    clave: cifra.clave,
    etiqueta: cifra.tarjeta.etiqueta,
    valor: comparacion ? formatearCifra(comparacion.actual, esTotal, cifra.clave) : "—",
    tendencia: comparacion ? tendenciaDe(comparacion.actual, comparacion.base) : null,
    nota,
    campania,
    barras,
  };
}
