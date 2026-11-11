// El estilo del mapa sale de la librería compartida `lib-mapa` (ADR-019, backend-supabase#256): el estilo de
// MapLibre, la paleta, los glyphs y los sprites viven allá, y el publicador los toma de la release fijada en
// package.json (`github:Colportores/lib-mapa#vX.Y.Z`). Acá no se arma ni se pinta nada: solo se le dice a la
// librería dónde van a quedar los glyphs y los sprites en el bucket, y se suben los archivos que trae.
//
// Cambiar el aspecto del mapa = una release nueva de lib-mapa + subir el tag en package.json (y
// package-lock.json con `npm install`) + `publicar --solo estilo` (docs/mapas-tiles.md).

import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { VERSION_DE_LA_LIBRERIA, armarEstilo, leerPaleta } from '@colportores/lib-mapa/estilo';

export { VERSION_DE_LA_LIBRERIA };

/** Dónde trae la librería los glyphs (`glyphs/`) y los sprites (`sprites/`) que se publican junto al estilo. */
export const RAIZ_ASSETS = fileURLToPath(new URL('assets/', import.meta.resolve('@colportores/lib-mapa/package.json')));

/** El tag de lib-mapa que fija package.json (`#vX.Y.Z`), o null si no es un tag. */
export function tagFijado(paquete = JSON.parse(readFileSync(new URL('../package.json', import.meta.url), 'utf8'))) {
  const espec = paquete.dependencies?.['@colportores/lib-mapa'] ?? '';
  const m = espec.match(/#(v\d+\.\d+\.\d+)$/);
  return m ? m[1] : null;
}

/**
 * El estilo de la librería, con los glyphs y los sprites en `urlBase` (absoluta, sin barra al final:
 * `<SUPABASE_URL>/storage/v1/object/public/mapas/estilo`). Es el mismo `colportores.json` de la release de
 * lib-mapa, con nuestra URL en lugar de `https://REEMPLAZAR/estilo`. Determinista: la misma release y la
 * misma URL dan el mismo archivo, byte por byte.
 */
export async function estiloDeLaLibreria(urlBase) {
  return armarEstilo({ urlBase, paleta: await leerPaleta() });
}
