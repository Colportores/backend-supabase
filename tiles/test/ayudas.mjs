// Ayudas compartidas por los tests (no es un test: node --test solo corre *.test.mjs).
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { readFileSync } from 'node:fs';
import { armarEstilo } from '../src/estilo.mjs';

const RAIZ = fileURLToPath(new URL('..', import.meta.url));

export const URL_BASE_DE_PRUEBA = 'https://proyecto.supabase.co/storage/v1/object/public/mapas/estilo';

export function estiloDePrueba() {
  const paleta = JSON.parse(readFileSync(join(RAIZ, 'paleta.json'), 'utf8'));
  return armarEstilo({ urlBase: URL_BASE_DE_PRUEBA, paleta, version: '5.7.2' });
}
