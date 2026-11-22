import { PDFDocument, type PDFFont, PDFPage, rgb, StandardFonts } from "pdf-lib";

import type { Granularidad, Tendencia } from "./calculo.ts";
import { type Fecha, fechaCompleta } from "./fechas.ts";
import { ETIQUETA_DE_GRANULARIDAD, type ReporteArmado } from "./reporte.ts";

/**
 * El «Informe PDF» de la vista 32 (HU-REP-005): una hoja A4 con la marca del panel, los filtros que se están aplicando
 * (ámbito, agrupación, período y campaña), las cifras con su gráfico y la tabla, en el mismo orden y con los mismos
 * textos que el documento que antes armaba el navegador (`informe.ts` del panel). Se escribe con pdf-lib, que corre en
 * Deno sin navegador headless.
 *
 * Se hace en dos pasos para poder probarlo: `maquetar` decide qué va en cada página (textos ya limpios, con su posición)
 * y `dibujar` lo vuelca al PDF. Las coordenadas de la maqueta son de arriba hacia abajo, en puntos.
 */

const ANCHO_PAGINA = 595.28;
const ALTO_PAGINA = 841.89;
const MARGEN = 40;
const ANCHO_UTIL = ANCHO_PAGINA - 2 * MARGEN;
/** Lo que se reserva abajo para el pie de página. */
const ALTO_PIE = 30;
const LIMITE_INFERIOR = ALTO_PAGINA - MARGEN - ALTO_PIE;

type Color = readonly [number, number, number];

function hex(valor: string): Color {
  return [
    parseInt(valor.slice(1, 3), 16) / 255,
    parseInt(valor.slice(3, 5), 16) / 255,
    parseInt(valor.slice(5, 7), 16) / 255,
  ];
}

const COLOR_MARCA = hex("#002856");
const COLOR_TEXTO = hex("#0e1a2b");
const COLOR_SUAVE = hex("#5b6b82");
const COLOR_BORDE = hex("#cfd6e1");
const COLOR_BORDE_SUAVE = hex("#e3e7ee");
const COLOR_FONDO_FILTROS = hex("#f4f7fb");
export const COLOR_FONDO_GRUPO = hex("#f3f1ea");
export const COLOR_BARRA = hex("#13407a");
export const COLOR_BARRA_EN_CURSO = hex("#9db3d1");
const COLOR_SUBE = hex("#1f7a4d");
const COLOR_BAJA = hex("#b3261e");
const BLANCO: Color = [1, 1, 1];

export type NombreDeFuente = "normal" | "negrita" | "serif" | "serifNegrita";

export type Operacion =
  | {
    tipo: "texto";
    x: number;
    /** La línea base del texto. */
    y: number;
    texto: string;
    fuente: NombreDeFuente;
    tam: number;
    color: Color;
    /** `der`: `x` es el borde derecho del texto. */
    alinear?: "der";
  }
  | { tipo: "rect"; x: number; y: number; ancho: number; alto: number; relleno?: Color; borde?: Color }
  | { tipo: "linea"; x1: number; y1: number; x2: number; y2: number; color: Color }
  | { tipo: "triangulo"; x: number; y: number; arriba: boolean; color: Color };

export interface Pagina {
  operaciones: Operacion[];
}

/** Lo que la maqueta necesita saber de las tipografías: cuánto mide un texto y qué letras no se pueden escribir. */
export interface Medidor {
  medir(fuente: NombreDeFuente, tam: number, texto: string): number;
  /** El texto como se va a escribir: lo que la tipografía no trae se cambia por una letra parecida o por «?». */
  limpiar(fuente: NombreDeFuente, texto: string): string;
}

export interface ContextoDelInforme {
  granularidad: Granularidad;
  /** El día de hoy en Montevideo. */
  hoy: Fecha;
  /** El nombre de la campaña del informe. */
  campania: string;
}

/** Letras latinas que no se descomponen en letra + tilde (su «parecida» no sale de normalizar). */
const SIN_DESCOMPOSICION: Record<string, string> = {
  "Ł": "L",
  "ł": "l",
  "Đ": "D",
  "đ": "d",
  "Ħ": "H",
  "ħ": "h",
  "Ŀ": "L",
  "ŀ": "l",
};

const NOMBRES_STANDARD: Record<NombreDeFuente, StandardFonts> = {
  normal: StandardFonts.Helvetica,
  negrita: StandardFonts.HelveticaBold,
  serif: StandardFonts.TimesRoman,
  serifNegrita: StandardFonts.TimesRomanBold,
};

/** Las cuatro tipografías estándar del PDF (no se incrustan: no hace falta tener archivos de fuentes). */
export async function crearMedidor(
  documento: PDFDocument,
): Promise<{ medidor: Medidor; fuentes: Record<NombreDeFuente, PDFFont> }> {
  const nombres = Object.keys(NOMBRES_STANDARD) as NombreDeFuente[];
  const fuentes = {} as Record<NombreDeFuente, PDFFont>;
  const caracteres = {} as Record<NombreDeFuente, Set<number>>;
  for (const nombre of nombres) {
    fuentes[nombre] = await documento.embedFont(NOMBRES_STANDARD[nombre]);
    caracteres[nombre] = new Set(fuentes[nombre].getCharacterSet());
  }

  const limpiar = (fuente: NombreDeFuente, texto: string): string => {
    let salida = "";
    for (const letra of texto.normalize("NFC")) {
      const punto = letra.codePointAt(0)!;
      if (caracteres[fuente].has(punto)) {
        salida += letra;
      } else if ((punto >= 0x200b && punto <= 0x200f) || punto === 0x2060 || punto === 0xfeff) {
        // Caracteres de ancho cero y marcas de dirección: no se ven, no se escriben.
      } else if (/\s/.test(letra) || punto < 32) {
        // Saltos de línea, tabulaciones y espacios raros (nbsp…): un espacio.
        salida += " ";
      } else {
        // «ý» → «y», «Ł» → «L»…; lo que no tiene letra parecida (emoji, otro alfabeto) queda como «?».
        const base = SIN_DESCOMPOSICION[letra] ?? letra.normalize("NFD").replace(/\p{M}/gu, "");
        salida += base !== letra && [...base].every((b) => caracteres[fuente].has(b.codePointAt(0)!)) ? base : "?";
      }
    }
    return salida;
  };

  const medidor: Medidor = {
    limpiar,
    medir: (fuente, tam, texto) => fuentes[fuente].widthOfTextAtSize(limpiar(fuente, texto), tam),
  };
  return { medidor, fuentes };
}

/** Parte un texto en líneas que entran en `ancho`; una palabra más larga que la línea se corta donde haga falta. */
export function envolver(
  medidor: Medidor,
  fuente: NombreDeFuente,
  tam: number,
  texto: string,
  ancho: number,
): string[] {
  const limpio = medidor.limpiar(fuente, texto).trim();
  if (limpio === "") return [""];
  const lineas: string[] = [];
  let actual = "";
  for (const palabra of limpio.split(/\s+/)) {
    const candidata = actual === "" ? palabra : `${actual} ${palabra}`;
    if (medidor.medir(fuente, tam, candidata) <= ancho) {
      actual = candidata;
      continue;
    }
    if (actual !== "") lineas.push(actual);
    actual = "";
    let resto = palabra;
    while (medidor.medir(fuente, tam, resto) > ancho) {
      let corte = resto.length - 1;
      while (corte > 1 && medidor.medir(fuente, tam, resto.slice(0, corte)) > ancho) corte--;
      lineas.push(resto.slice(0, corte));
      resto = resto.slice(corte);
    }
    actual = resto;
  }
  if (actual !== "") lineas.push(actual);
  return lineas;
}

const INTERLINEADO = 1.25;

class Maqueta {
  readonly paginas: Pagina[] = [];
  y = MARGEN;

  constructor(readonly medidor: Medidor) {
    this.paginaNueva();
  }

  get pagina(): Pagina {
    return this.paginas[this.paginas.length - 1];
  }

  paginaNueva(): void {
    this.paginas.push({ operaciones: [] });
    this.y = MARGEN;
  }

  /** Si lo que sigue no entra en la página, empieza otra. Devuelve `true` si cambió de página. */
  asegurar(alto: number): boolean {
    if (this.y + alto <= LIMITE_INFERIOR) return false;
    this.paginaNueva();
    return true;
  }

  texto(
    x: number,
    y: number,
    texto: string,
    fuente: NombreDeFuente,
    tam: number,
    color: Color,
    alinear?: "der",
    en: Pagina = this.pagina,
  ): void {
    en.operaciones.push({
      tipo: "texto",
      x,
      y,
      texto: this.medidor.limpiar(fuente, texto),
      fuente,
      tam,
      color,
      alinear,
    });
  }

  /** Líneas ya envueltas, una debajo de la otra; devuelve el alto que ocupan. */
  parrafo(
    x: number,
    y: number,
    lineas: string[],
    fuente: NombreDeFuente,
    tam: number,
    color: Color,
    en: Pagina = this.pagina,
  ): number {
    lineas.forEach((linea, i) =>
      this.texto(x, y + tam + i * tam * INTERLINEADO, linea, fuente, tam, color, undefined, en)
    );
    return lineas.length * tam * INTERLINEADO;
  }

  rect(
    x: number,
    y: number,
    ancho: number,
    alto: number,
    relleno?: Color,
    borde?: Color,
    en: Pagina = this.pagina,
  ): void {
    en.operaciones.push({ tipo: "rect", x, y, ancho, alto, relleno, borde });
  }

  linea(x1: number, y1: number, x2: number, y2: number, color: Color, en: Pagina = this.pagina): void {
    en.operaciones.push({ tipo: "linea", x1, y1, x2, y2, color });
  }

  /** «▲ 10%» / «▼ 8%» / «= 0%», con el borde derecho en `xDerecho` y la línea base en `base`. */
  tendencia(t: Tendencia, xDerecho: number, base: number, tam: number, en: Pagina = this.pagina): void {
    const color = t.sentido === "sube" ? COLOR_SUBE : t.sentido === "baja" ? COLOR_BAJA : COLOR_SUAVE;
    this.texto(xDerecho, base, t.texto, "negrita", tam, color, "der", en);
    if (t.sentido === "igual") return;
    const ancho = this.medidor.medir("negrita", tam, t.texto);
    const lado = tam * 0.75;
    en.operaciones.push({
      tipo: "triangulo",
      x: xDerecho - ancho - lado - 2,
      y: base - lado,
      arriba: t.sentido === "sube",
      color,
    });
  }
}

const FRANJA_ENCABEZADO = 26;

function encabezado(m: Maqueta): void {
  m.rect(MARGEN, m.y, ANCHO_UTIL, FRANJA_ENCABEZADO, COLOR_MARCA);
  m.texto(MARGEN + 12, m.y + 17, "Colportaje", "negrita", 12, BLANCO);
  m.texto(MARGEN + ANCHO_UTIL - 12, m.y + 17, "Coordinador · Reportes", "normal", 9, BLANCO, "der");
  m.y += FRANJA_ENCABEZADO;
}

function filtros(m: Maqueta, reporte: ReporteArmado, contexto: ContextoDelInforme): void {
  const lista = [
    { etiqueta: "Campaña", valor: contexto.campania },
    { etiqueta: "Ver", valor: reporte.vistaElegida ?? reporte.titulo },
    { etiqueta: "Agrupado por", valor: ETIQUETA_DE_GRANULARIDAD[contexto.granularidad] },
    { etiqueta: "Período", valor: reporte.periodo || "Todavía no hay un período completo" },
    { etiqueta: "Al día", valor: fechaCompleta(contexto.hoy) },
  ];
  const columna = 80;
  const relleno = 8;
  const tam = 9;
  const filas = lista.map((f) => ({
    ...f,
    lineas: envolver(m.medidor, "normal", tam, f.valor, ANCHO_UTIL - 2 * relleno - columna - 12),
  }));
  const alto = 2 * relleno + filas.reduce((suma, f) => suma + f.lineas.length * tam * INTERLINEADO + 3, -3);
  m.asegurar(alto);
  m.rect(MARGEN, m.y, ANCHO_UTIL, alto, COLOR_FONDO_FILTROS, COLOR_BORDE);
  let y = m.y + relleno;
  for (const f of filas) {
    m.texto(MARGEN + relleno, y + tam, f.etiqueta, "negrita", tam, COLOR_TEXTO);
    m.parrafo(MARGEN + relleno + columna + 12, y, f.lineas, "normal", tam, COLOR_TEXTO);
    y += f.lineas.length * tam * INTERLINEADO + 3;
  }
  m.y += alto + 14;
}

function tarjetas(m: Maqueta, reporte: ReporteArmado): void {
  if (reporte.tarjetas.length === 0) return;
  const huecoEntre = 10;
  const ancho = (ANCHO_UTIL - huecoEntre * (reporte.tarjetas.length - 1)) / reporte.tarjetas.length;
  const relleno = 8;
  const interior = ancho - 2 * relleno;
  const altoGrafico = 38;

  const preparadas = reporte.tarjetas.map((t) => ({
    t,
    nota: envolver(m.medidor, "normal", 7.5, t.nota, interior),
    campania: envolver(m.medidor, "normal", 7.5, t.campania, interior),
  }));
  const alto = Math.max(
    ...preparadas.map((p) =>
      2 * relleno + 9 + 26 + (p.nota.length + p.campania.length) * 7.5 * INTERLINEADO + 6 + altoGrafico + 10
    ),
  );
  m.asegurar(alto);

  preparadas.forEach(({ t, nota, campania }, i) => {
    const x = MARGEN + i * (ancho + huecoEntre);
    let y = m.y;
    m.rect(x, y, ancho, alto, undefined, COLOR_BORDE_SUAVE);
    y += relleno;
    m.texto(x + relleno, y + 7, t.etiqueta, "negrita", 7, COLOR_SUAVE);
    y += 9;
    m.texto(x + relleno, y + 20, t.valor, "serifNegrita", 20, COLOR_MARCA);
    if (t.tendencia) m.tendencia(t.tendencia, x + ancho - relleno, y + 20, 9);
    y += 26;
    y += m.parrafo(x + relleno, y, nota, "normal", 7.5, COLOR_SUAVE);
    y += m.parrafo(x + relleno, y, campania, "normal", 7.5, COLOR_SUAVE);
    y += 6;

    // El gráfico: una barra por período; la que está en curso (parcial) más clara; sin datos, sin barra.
    const base = y + altoGrafico;
    const n = t.barras.length;
    if (n > 0) {
      const hueco = Math.min(3, (interior / n) * 0.25);
      const anchoBarra = (interior - hueco * (n - 1)) / n;
      const rotulos = t.barras.map((b) => m.medidor.limpiar("normal", b.rotulo));
      const masAncho = Math.max(...rotulos.map((r) => m.medidor.medir("normal", 5, r)));
      const salto = Math.max(1, Math.ceil((masAncho + 1) / (anchoBarra + hueco)));
      t.barras.forEach((b, k) => {
        const bx = x + relleno + k * (anchoBarra + hueco);
        if (!b.sinDatos) {
          const altoBarra = Math.max(2, Math.round(b.proporcion * (altoGrafico - 2)));
          m.rect(bx, base - altoBarra, anchoBarra, altoBarra, b.enCurso ? COLOR_BARRA_EN_CURSO : COLOR_BARRA);
        }
        if (k % salto === 0) {
          const centro = bx + anchoBarra / 2;
          m.texto(
            centro - m.medidor.medir("normal", 5, rotulos[k]) / 2,
            base + 7,
            rotulos[k],
            "normal",
            5,
            COLOR_SUAVE,
          );
        }
      });
    }
    m.linea(x + relleno, base, x + relleno + interior, base, COLOR_BORDE);
  });
  m.y += alto + 14;
}

const ANCHO_COLUMNA_DE_CIFRA = 76;
const RELLENO_CELDA = 5;

function tabla(m: Maqueta, reporte: ReporteArmado): void {
  const { columnas, filas, primeraColumna } = reporte.tabla;
  const anchoNombre = ANCHO_UTIL - columnas.length * ANCHO_COLUMNA_DE_CIFRA;
  const xDeColumna = (k: number) => MARGEN + anchoNombre + k * ANCHO_COLUMNA_DE_CIFRA;

  const cabecera = (): void => {
    const tam = 7;
    const lineasPrimera = envolver(m.medidor, "negrita", tam, primeraColumna, anchoNombre - 2 * RELLENO_CELDA);
    const alto = lineasPrimera.length * tam * INTERLINEADO + 8;
    m.asegurar(alto + 30);
    m.parrafo(MARGEN + RELLENO_CELDA, m.y + 3, lineasPrimera, "negrita", tam, COLOR_SUAVE);
    columnas.forEach((c, k) => {
      m.texto(
        xDeColumna(k) + ANCHO_COLUMNA_DE_CIFRA - RELLENO_CELDA,
        m.y + 3 + tam,
        c.encabezado,
        "negrita",
        tam,
        COLOR_SUAVE,
        "der",
      );
    });
    m.linea(MARGEN, m.y + alto, MARGEN + ANCHO_UTIL, m.y + alto, COLOR_BORDE);
    m.y += alto;
  };

  // Descripción de la tabla, para quien lee el documento sin mirar la pantalla.
  const descripcion = envolver(m.medidor, "negrita", 9, reporte.tabla.descripcion, ANCHO_UTIL);
  m.asegurar(descripcion.length * 9 * INTERLINEADO + 50);
  m.y += m.parrafo(MARGEN, m.y, descripcion, "negrita", 9, COLOR_MARCA) + 4;
  cabecera();

  if (filas.length === 0) {
    m.parrafo(
      MARGEN + RELLENO_CELDA,
      m.y + 6,
      ["Todavía no hay colportores para mostrar acá."],
      "normal",
      9,
      COLOR_SUAVE,
    );
    m.y += 26;
    return;
  }

  filas.forEach((fila) => {
    if (fila.tipo === "grupo") {
      const alto = 18;
      // Una ciudad no queda sola al pie de la página: se pasa a la siguiente con su primera fila.
      if (m.asegurar(alto + 34)) cabecera();
      m.rect(MARGEN, m.y, ANCHO_UTIL, alto, COLOR_FONDO_GRUPO);
      const nombre = m.medidor.limpiar("negrita", fila.nombre);
      m.texto(MARGEN + RELLENO_CELDA, m.y + 12, nombre, "negrita", 9, COLOR_MARCA);
      m.texto(
        MARGEN + RELLENO_CELDA + m.medidor.medir("negrita", 9, nombre) + 8,
        m.y + 12,
        fila.detalle,
        "normal",
        7.5,
        COLOR_SUAVE,
      );
      m.y += alto;
      return;
    }

    const nombre = envolver(m.medidor, "negrita", 9, fila.nombre, anchoNombre - 2 * RELLENO_CELDA);
    const nota = fila.nota ? envolver(m.medidor, "normal", 7.5, fila.nota, anchoNombre - 2 * RELLENO_CELDA) : [];
    const hayTendencia = fila.celdas.some((c) => c.tendencia);
    const altoNombre = nombre.length * 9 * INTERLINEADO + nota.length * 7.5 * INTERLINEADO;
    const altoCifras = 9 * INTERLINEADO + (hayTendencia ? 8 * INTERLINEADO : 0);
    const alto = Math.max(altoNombre, altoCifras) + 9;
    if (m.asegurar(alto)) cabecera();

    const arriba = m.y + 4;
    const usado = m.parrafo(MARGEN + RELLENO_CELDA, arriba, nombre, "negrita", 9, COLOR_TEXTO);
    m.parrafo(MARGEN + RELLENO_CELDA, arriba + usado, nota, "normal", 7.5, COLOR_SUAVE);
    fila.celdas.forEach((c, k) => {
      const derecho = xDeColumna(k) + ANCHO_COLUMNA_DE_CIFRA - RELLENO_CELDA;
      m.texto(derecho, arriba + 9, c.valor, "normal", 9, c.sinDatos ? COLOR_SUAVE : COLOR_TEXTO, "der");
      if (c.tendencia) m.tendencia(c.tendencia, derecho, arriba + 9 + 8 * INTERLINEADO, 7);
    });
    m.linea(MARGEN, m.y + alto, MARGEN + ANCHO_UTIL, m.y + alto, COLOR_BORDE_SUAVE);
    m.y += alto;
  });
}

/** Qué va en cada página del informe. */
export function maquetar(reporte: ReporteArmado, contexto: ContextoDelInforme, medidor: Medidor): Pagina[] {
  const m = new Maqueta(medidor);
  encabezado(m);
  m.y += 16;

  const titulo = envolver(medidor, "serifNegrita", 22, reporte.titulo, ANCHO_UTIL);
  m.y += m.parrafo(MARGEN, m.y, titulo, "serifNegrita", 22, COLOR_MARCA) + 2;
  const subtitulo = envolver(medidor, "normal", 11, reporte.subtitulo, ANCHO_UTIL);
  m.y += m.parrafo(MARGEN, m.y, subtitulo, "normal", 11, COLOR_SUAVE) + 8;

  filtros(m, reporte, contexto);
  tarjetas(m, reporte);
  tabla(m, reporte);

  // Pie de cada página: de dónde sale y que no lleva datos de clientes, y «Página n de N».
  const pie = `Informe generado desde el panel del coordinador el ${
    fechaCompleta(contexto.hoy)
  }. Muestra lo mismo que la pantalla; no incluye datos de clientes.`;
  m.paginas.forEach((pagina, i) => {
    const y = ALTO_PAGINA - MARGEN;
    m.linea(MARGEN, y - 10, MARGEN + ANCHO_UTIL, y - 10, COLOR_BORDE_SUAVE, pagina);
    m.texto(MARGEN, y, pie, "normal", 7, COLOR_SUAVE, undefined, pagina);
    m.texto(MARGEN + ANCHO_UTIL, y, `Página ${i + 1} de ${m.paginas.length}`, "normal", 7, COLOR_SUAVE, "der", pagina);
  });
  return m.paginas;
}

function aColor(color: Color) {
  return rgb(color[0], color[1], color[2]);
}

function dibujar(
  pagina: PDFPage,
  operaciones: Operacion[],
  fuentes: Record<NombreDeFuente, PDFFont>,
  medidor: Medidor,
): void {
  const alto = ALTO_PAGINA;
  for (const op of operaciones) {
    switch (op.tipo) {
      case "texto": {
        const ancho = op.alinear === "der" ? medidor.medir(op.fuente, op.tam, op.texto) : 0;
        pagina.drawText(op.texto, {
          x: op.x - ancho,
          y: alto - op.y,
          size: op.tam,
          font: fuentes[op.fuente],
          color: aColor(op.color),
        });
        break;
      }
      case "rect":
        pagina.drawRectangle({
          x: op.x,
          y: alto - op.y - op.alto,
          width: op.ancho,
          height: op.alto,
          color: op.relleno ? aColor(op.relleno) : undefined,
          borderColor: op.borde ? aColor(op.borde) : undefined,
          borderWidth: op.borde ? 0.75 : 0,
        });
        break;
      case "linea":
        pagina.drawLine({
          start: { x: op.x1, y: alto - op.y1 },
          end: { x: op.x2, y: alto - op.y2 },
          thickness: 0.75,
          color: aColor(op.color),
        });
        break;
      case "triangulo":
        // El origen del trazado es la esquina de arriba a la izquierda; el eje vertical del trazado va hacia abajo.
        pagina.drawSvgPath(op.arriba ? "M 3 0 L 6 6 L 0 6 Z" : "M 0 0 L 6 0 L 3 6 Z", {
          x: op.x,
          y: alto - op.y,
          color: aColor(op.color),
          borderWidth: 0,
        });
        break;
    }
  }
}

/** El PDF del informe, listo para bajar. */
export async function crearInformePdf(
  reporte: ReporteArmado,
  contexto: ContextoDelInforme,
  nombreDelArchivo: string,
): Promise<Uint8Array> {
  const documento = await PDFDocument.create();
  const { medidor, fuentes } = await crearMedidor(documento);

  documento.setTitle(medidor.limpiar("normal", nombreDelArchivo.replace(/\.pdf$/, "")));
  documento.setAuthor("Colportaje");
  documento.setSubject("Informe de Reportes del coordinador");
  documento.setCreator("Colportaje · informe-reportes");
  documento.setProducer("pdf-lib");
  documento.setLanguage("es-UY");
  const creado = new Date(`${contexto.hoy}T12:00:00Z`);
  documento.setCreationDate(creado);
  documento.setModificationDate(creado);

  for (const { operaciones } of maquetar(reporte, contexto, medidor)) {
    dibujar(documento.addPage([ANCHO_PAGINA, ALTO_PAGINA]), operaciones, fuentes, medidor);
  }
  return await documento.save();
}
