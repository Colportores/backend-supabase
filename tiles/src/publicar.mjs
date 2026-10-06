// Orquesta la publicación en el bucket `mapas`. Todo lo que toca el mundo (Storage, el recorte, el
// disco) llega por parámetro, para probarlo sin red ni Docker (tiles/test/publicar.test.mjs).
//
// Orden, pensado para que el catálogo NUNCA apunte a algo que todavía no está:
//   1. el bucket existe y está como debe;
//   2. estilo, glyphs y sprites;
//   3. cada paquete, solo si no estaba ya publicado (el nombre lleva el SHA-256);
//   4. el catálogo, último;
//   5. recién ahí, borrar lo que el catálogo ya no menciona y pasó el período de gracia.

import { readdir, readFile } from 'node:fs/promises';
import { join, posix, relative, sep } from 'node:path';
import { BUCKET, cacheControlDe, tipoDe } from './bucket.mjs';
import { armarPaquete, fusionar, obsoletos, rutaArchivo, validar, versionDe } from './catalogo.mjs';
import { planificar } from './politica.mjs';
import { sha256DeArchivo } from './recorte.mjs';

export const RUTA_CATALOGO = 'catalogo.json';
export const RUTA_ESTILO = 'estilo/colportores.json';

/** Fecha ISO 8601 en UTC, sin milisegundos. */
export function ahoraIso(fecha = new Date()) {
  return fecha.toISOString().replace(/\.\d{3}Z$/, 'Z');
}

/** Todos los archivos de `raiz`, como [{ ruta: '<prefijo>/<relativa>', local }], en orden estable. */
export async function listarArchivos(raiz, prefijo) {
  const encontrados = [];
  async function recorrer(directorio) {
    const entradas = await readdir(directorio, { withFileTypes: true });
    entradas.sort((a, b) => (a.name < b.name ? -1 : a.name > b.name ? 1 : 0));
    for (const entrada of entradas) {
      const local = join(directorio, entrada.name);
      if (entrada.isDirectory()) await recorrer(local);
      else encontrados.push({ ruta: posix.join(prefijo, relative(raiz, local).split(sep).join('/')), local });
    }
  }
  await recorrer(raiz);
  return encontrados;
}

async function subirArchivo(storage, ruta, contenido) {
  await storage.subir(ruta, contenido, { contentType: tipoDe(ruta), cacheControl: cacheControlDe(ruta) });
}

/** Sube el estilo y sus glyphs y sprites. `estilo` es el objeto de armarEstilo(). */
export async function publicarEstilo({ storage, estilo, raizAssets, log = () => {} }) {
  const archivos = [
    ...(await listarArchivos(join(raizAssets, 'glyphs'), 'estilo/glyphs')),
    ...(await listarArchivos(join(raizAssets, 'sprites'), 'estilo/sprites')),
  ];
  for (const { ruta, local } of archivos) await subirArchivo(storage, ruta, await readFile(local));
  log(`estilo: ${archivos.length} archivos de glyphs y sprites`);
  await subirArchivo(storage, RUTA_ESTILO, Buffer.from(`${JSON.stringify(estilo, null, 2)}\n`));
  log(`estilo: ${RUTA_ESTILO}`);
}

/**
 * Recorta un ámbito (una ciudad, o una zona) con la política de tamaño y devuelve sus partes ya con
 * SHA-256 y ruta. Los archivos quedan en `tmp`.
 *
 * @param {object} p
 * @param {string} p.nivel   'ciudad' | 'zona'
 * @param {string} p.clave   nombre del archivo: slug de la ciudad o id de la zona
 * @param {number[]} p.bbox
 * @param {(opts: {bbox:number[], zoomMax:number, destino:string}) => Promise<number>} p.extraer  devuelve bytes
 */
export async function prepararPaquete({ nivel, clave, bbox, extraer, tmp, log = () => {}, limites }) {
  const hechos = new Map();
  let n = 0;
  const medir = async (cuadro, zoomMax) => {
    const destino = join(tmp, `${nivel}-${clave}-${++n}.pmtiles`);
    const bytes = await extraer({ bbox: cuadro, zoomMax, destino });
    hechos.set(`${cuadro.join(',')}@${zoomMax}`, destino);
    log(`${nivel} ${clave}: zoom ${zoomMax}, ${cuadro.join(',')} → ${(bytes / 1e6).toFixed(1)} MB`);
    return bytes;
  };
  const plan = await planificar(bbox, medir, limites);

  const partes = [];
  for (const [i, parte] of plan.partes.entries()) {
    const local = hechos.get(`${parte.bbox.join(',')}@${parte.zoom_max}`);
    const sha256 = await sha256DeArchivo(local);
    const archivo = rutaArchivo({ nivel, clave, parte: i + 1, total: plan.partes.length, sha256 });
    partes.push({ archivo, tamano_bytes: parte.bytes, sha256, bbox: parte.bbox, local });
  }
  return { partes, zoomMax: plan.partes[0].zoom_max };
}

/**
 * Publica las ciudades de `ciudades` (tiles/ciudades.json) y deja el catálogo al día.
 * `dryRun`: hace todo menos escribir en el bucket.
 */
export async function publicarCiudades({
  storage,
  ciudades,
  extraer,
  tmp,
  build,
  ahora = ahoraIso(),
  dryRun = false,
  log = () => {},
  limites,
}) {
  const previo = await storage.bajarJson(RUTA_CATALOGO);
  const nuevos = [];

  for (const ciudad of ciudades) {
    const { partes, zoomMax } = await prepararPaquete({
      nivel: 'ciudad',
      clave: ciudad.slug,
      bbox: ciudad.bbox,
      extraer,
      tmp,
      log,
      limites,
    });
    const publicables = partes.map(({ local, ...resto }) => resto);
    const id = `ciudad-${ciudad.slug}`;
    const anterior = previo?.paquetes.find((p) => p.id === id);

    if (anterior && anterior.version === versionDe(publicables) && anterior.zoom_max === zoomMax) {
      log(`${id}: sin cambios (${anterior.version.slice(0, 12)})`);
      nuevos.push(anterior);
      continue;
    }

    for (const parte of partes) {
      if (dryRun) {
        log(`${id}: [dry-run] subiría ${parte.archivo}`);
      } else if (await storage.existe(parte.archivo)) {
        log(`${id}: ${parte.archivo} ya estaba`);
      } else {
        await subirArchivo(storage, parte.archivo, await readFile(parte.local));
        log(`${id}: subido ${parte.archivo}`);
      }
    }
    nuevos.push(
      armarPaquete({
        nivel: 'ciudad',
        clave: ciudad.slug,
        ambitoId: ciudad.ciudad_id,
        nombre: ciudad.nombre,
        bbox: ciudad.bbox,
        zoomMax,
        partes: publicables,
        build,
        ahora,
      }),
    );
  }

  const catalogo = fusionar(previo, nuevos, { ahora });
  const errores = validar(catalogo);
  if (errores.length > 0) throw new Error(`El catálogo no es válido:\n  ${errores.join('\n  ')}`);

  if (dryRun) {
    log(`[dry-run] catálogo con ${catalogo.paquetes.length} paquetes, no se sube`);
    return { catalogo, borrados: [] };
  }
  await storage.subir(RUTA_CATALOGO, Buffer.from(`${JSON.stringify(catalogo, null, 2)}\n`), {
    contentType: tipoDe(RUTA_CATALOGO),
    cacheControl: cacheControlDe(RUTA_CATALOGO),
  });
  log(`catálogo publicado: ${catalogo.paquetes.map((p) => p.id).join(', ')}`);

  const publicados = [
    ...(await storage.listar('paquetes/ciudad')),
    ...(await storage.listar('paquetes/zona')),
  ];
  const borrar = obsoletos(publicados, catalogo, { ahora });
  await storage.borrar(borrar);
  if (borrar.length > 0) log(`borrados por obsoletos (más de 7 días sin catálogo): ${borrar.join(', ')}`);
  return { catalogo, borrados: borrar };
}

export { BUCKET };
