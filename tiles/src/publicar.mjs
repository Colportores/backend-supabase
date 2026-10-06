// Orquesta la publicación en el bucket `mapas`. Todo lo que toca el mundo (Storage, el recorte, el
// disco) llega por parámetro, para probarlo sin red ni Docker (tiles/test/publicar.test.mjs).
//
// Orden, pensado para que el catálogo NUNCA apunte a algo que todavía no está:
//   1. el bucket existe y está como debe;
//   2. estilo, glyphs y sprites;
//   3. cada paquete, solo si no estaba ya publicado (el nombre lleva el SHA-256);
//   4. el catálogo, último;
//   5. recién ahí, borrar lo que el catálogo ya no menciona y pasó el período de gracia, que corre
//      desde que el archivo salió del catálogo (`retirados`), no desde que se subió.

import { createHash } from 'node:crypto';
import { readdir, readFile } from 'node:fs/promises';
import { join, posix, relative, sep } from 'node:path';
import { BUCKET, cacheControlDe, tipoDe } from './bucket.mjs';
import { DIAS_DE_GRACIA, armarPaquete, fusionar, obsoletos, podarRetirados, rutaArchivo, validar, versionDe } from './catalogo.mjs';
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

/** Los bytes con los que el estilo se sube al bucket. */
export const serializarEstilo = (estilo) => Buffer.from(`${JSON.stringify(estilo, null, 2)}\n`);

/** La versión del estilo en el catálogo: el SHA-256 de esos bytes (como la de los paquetes). */
export const versionDeEstilo = (contenido) => createHash('sha256').update(contenido).digest('hex');

/** Sube el estilo y sus glyphs y sprites; devuelve su `version`. `estilo` es el objeto de armarEstilo(). */
export async function publicarEstilo({ storage, estilo, raizAssets, log = () => {} }) {
  const archivos = [
    ...(await listarArchivos(join(raizAssets, 'glyphs'), 'estilo/glyphs')),
    ...(await listarArchivos(join(raizAssets, 'sprites'), 'estilo/sprites')),
  ];
  for (const { ruta, local } of archivos) await subirArchivo(storage, ruta, await readFile(local));
  log(`estilo: ${archivos.length} archivos de glyphs y sprites`);
  const contenido = serializarEstilo(estilo);
  await subirArchivo(storage, RUTA_ESTILO, contenido);
  const version = versionDeEstilo(contenido);
  log(`estilo: ${RUTA_ESTILO} (versión ${version.slice(0, 12)})`);
  return { version };
}

async function subirCatalogo(storage, catalogo) {
  await storage.subir(RUTA_CATALOGO, Buffer.from(`${JSON.stringify(catalogo, null, 2)}\n`), {
    contentType: tipoDe(RUTA_CATALOGO),
    cacheControl: cacheControlDe(RUTA_CATALOGO),
  });
}

/**
 * `publicar --solo estilo`: el estilo cambió, así que el catálogo también (su `estilo.version` es lo que
 * le dice a la app que hay un estilo nuevo, igual que `version` en los paquetes). No toca los paquetes.
 */
export async function publicarCatalogoDeEstilo({ storage, estiloVersion, ahora = ahoraIso(), dryRun = false, log = () => {} }) {
  const previo = await storage.bajarJson(RUTA_CATALOGO);
  const catalogo = fusionar(previo, previo?.paquetes ?? [], { ahora, estiloVersion });
  const errores = validar(catalogo, { exigirAmbito: !dryRun });
  if (errores.length > 0) throw new Error(`El catálogo no es válido:\n  ${errores.join('\n  ')}`);
  if (dryRun) {
    log(`[dry-run] catálogo con el estilo ${estiloVersion.slice(0, 12)}, no se sube`);
    return { catalogo };
  }
  await subirCatalogo(storage, catalogo);
  log(`catálogo publicado: estilo ${estiloVersion.slice(0, 12)}, ${catalogo.paquetes.length} paquetes`);
  return { catalogo };
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
 * Publica las ciudades de `ciudades` (tiles/ciudades.json, cada una con su `ciudad_id` de public.ciudad)
 * y deja el catálogo al día. `estiloVersion`: la versión del estilo que se acaba de subir; si no viene,
 * se conserva la del catálogo publicado (y si no hay, no se publica: antes va el estilo).
 * `dryRun`: hace todo menos escribir en el bucket.
 */
export async function publicarCiudades({
  storage,
  ciudades,
  extraer,
  tmp,
  build,
  estiloVersion,
  ahora = ahoraIso(),
  dryRun = false,
  log = () => {},
  limites,
}) {
  // Todo lo que puede impedir publicar se mira ANTES de subir un solo archivo.
  const sinAmbito = ciudades.filter((c) => !c.ciudad_id);
  if (!dryRun && sinAmbito.length > 0) {
    throw new Error(
      `Falta el ciudad_id (public.ciudad) de ${sinAmbito.map((c) => c.slug).join(', ')}: un paquete de ciudad sin ambito_id no lo encuentra la app. No se subió nada.`,
    );
  }
  const previo = await storage.bajarJson(RUTA_CATALOGO);
  if (!estiloVersion && !previo?.estilo?.version) {
    throw new Error('El catálogo del bucket no tiene la versión del estilo: publicá el estilo primero (--solo estilo, o todo). No se subió nada.');
  }
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
      // El mismo mapa: no se sube nada ni cambia su versión ni su fecha (la app no ve una actualización).
      // Pero lo que dice el catálogo de la ciudad (nombre, ámbito, bbox) sale de ciudades.json y puede
      // haber cambiado sin que cambien los tiles: se rearma la entrada con los datos de hoy.
      const rearmado = armarPaquete({
        nivel: 'ciudad',
        clave: ciudad.slug,
        ambitoId: ciudad.ciudad_id,
        nombre: ciudad.nombre,
        bbox: ciudad.bbox,
        zoomMax,
        partes: publicables,
        build: anterior.fuente_build,
        ahora: anterior.actualizado_en,
      });
      if (JSON.stringify(rearmado) === JSON.stringify(anterior)) {
        log(`${id}: sin cambios (${anterior.version.slice(0, 12)})`);
        nuevos.push(anterior);
      } else {
        log(`${id}: mismo mapa (${anterior.version.slice(0, 12)}), datos del catálogo actualizados`);
        nuevos.push(rearmado);
      }
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

  const fusionado = fusionar(previo, nuevos, { ahora, estiloVersion });
  const erroresFusionado = validar(fusionado, { exigirAmbito: !dryRun });
  if (erroresFusionado.length > 0) throw new Error(`El catálogo no es válido:\n  ${erroresFusionado.join('\n  ')}`);

  if (dryRun) {
    log(`[dry-run] catálogo con ${fusionado.paquetes.length} paquetes, no se sube`);
    return { catalogo: fusionado, borrados: [] };
  }

  // Qué se puede borrar se decide ANTES de subir el catálogo, para que el catálogo que se publica ya
  // no recuerde como «retirado» lo que se va a borrar. Si el borrado falla, esos archivos quedan sin
  // fecha de retiro y la próxima corrida los junta por su fecha de subida (ya vieja).
  const publicados = [
    ...(await storage.listar('paquetes/ciudad')),
    ...(await storage.listar('paquetes/zona')),
  ];
  const borrar = obsoletos(publicados, fusionado, { ahora });
  const catalogo = podarRetirados(fusionado, { borrados: borrar, publicados });
  const errores = validar(catalogo);
  if (errores.length > 0) throw new Error(`El catálogo no es válido:\n  ${errores.join('\n  ')}`);

  await subirCatalogo(storage, catalogo);
  log(`catálogo publicado: ${catalogo.paquetes.map((p) => p.id).join(', ')}`);
  if (catalogo.retirados.length > 0) {
    log(`retirados, con su período de gracia de ${DIAS_DE_GRACIA} días: ${catalogo.retirados.map((r) => `${r.archivo} (desde ${r.desde})`).join(', ')}`);
  }

  await storage.borrar(borrar);
  if (borrar.length > 0) log(`borrados (más de ${DIAS_DE_GRACIA} días fuera del catálogo): ${borrar.join(', ')}`);
  return { catalogo, borrados: borrar };
}

export { BUCKET };
