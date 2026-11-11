// Ayudas compartidas por los tests (no es un test: node --test solo corre *.test.mjs).
import { estiloDeLaLibreria } from '../src/lib-mapa.mjs';

export const URL_BASE_DE_PRUEBA = 'https://proyecto.supabase.co/storage/v1/object/public/mapas/estilo';

/** El estilo de lib-mapa (la release fijada en package.json) con la URL de un bucket de prueba. */
export const estiloDePrueba = () => structuredClone(ESTILO_DE_PRUEBA);
const ESTILO_DE_PRUEBA = await estiloDeLaLibreria(URL_BASE_DE_PRUEBA);
