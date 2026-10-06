// El estilo de MapLibre de Colportores: UNO solo, compartido por la app (front-colportores-mobile#286)
// y el panel de coordinadores. Las capas salen de @protomaps/basemaps (el esquema de los tiles de
// Protomaps), pintadas con la paleta del canvas (tiles/paleta.json).
//
// Es determinista: la misma paleta y la misma URL base dan el mismo archivo, byte por byte, así que
// republicarlo sin cambios no cambia nada.

import { readFile } from 'node:fs/promises';
import { layers, namedFlavor } from '@protomaps/basemaps';

export const NOMBRE_DE_LA_FUENTE = 'protomaps';

/**
 * El estilo no sabe de qué archivo PMTiles sale el mapa: cada ciudad y cada zona tiene el suyo.
 * El cliente reemplaza `sources.protomaps.url` por `pmtiles://<archivo del paquete>` (un archivo
 * local en la app, la URL pública del paquete en el panel) antes de dárselo a MapLibre.
 */
export const URL_A_REEMPLAZAR = 'pmtiles://REEMPLAZAR';

export const ATRIBUCION =
  '<a href="https://github.com/protomaps/basemaps">Protomaps</a> © <a href="https://openstreetmap.org/copyright">OpenStreetMap</a>';

export async function leerPaleta(ruta) {
  return JSON.parse(await readFile(ruta, 'utf8'));
}

/** La paleta de Colportores sobre `light` de Protomaps: lo que la paleta no dice, lo hereda. */
export function flavorColportores(paleta) {
  const base = namedFlavor('light');
  return {
    ...base,
    ...paleta.flavor,
    landcover: { ...base.landcover, ...paleta.landcover },
  };
}

/**
 * @param {object} opciones
 * @param {string} opciones.urlBase  Dónde quedan los archivos del estilo, sin barra al final:
 *   `<SUPABASE_URL>/storage/v1/object/public/mapas/estilo`. MapLibre pide glyphs y sprites con
 *   URLs absolutas, por eso el estilo se genera para cada proyecto de Supabase (staging, producción).
 * @param {object} opciones.paleta   Contenido de tiles/paleta.json.
 * @param {string} opciones.version  Versión de @protomaps/basemaps con la que se generó (queda en metadata).
 */
export function armarEstilo({ urlBase, paleta, version }) {
  if (!/^https?:\/\//.test(urlBase)) throw new Error(`urlBase tiene que ser absoluta: ${urlBase}`);
  const base = urlBase.replace(/\/+$/, '');
  return {
    version: 8,
    name: 'Colportores',
    metadata: {
      'colportores:paleta': paleta.version,
      'colportores:basemaps': version,
    },
    sources: {
      [NOMBRE_DE_LA_FUENTE]: {
        type: 'vector',
        attribution: ATRIBUCION,
        url: URL_A_REEMPLAZAR,
      },
    },
    layers: layers(NOMBRE_DE_LA_FUENTE, flavorColportores(paleta), { lang: paleta.idioma }).filter(
      (capa) => !(paleta.sin_capas ?? []).includes(capa.id),
    ),
    glyphs: `${base}/glyphs/{fontstack}/{range}.pbf`,
    sprite: `${base}/sprites/grayscale`,
  };
}
