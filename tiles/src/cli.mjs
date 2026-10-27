#!/usr/bin/env node
// Herramienta de los mapas propios (backend-supabase#42). Se explica entera en docs/mapas-tiles.md.
//
//   node src/cli.mjs estilo    [--url-base URL] [--salida DIR]
//   node src/cli.mjs publicar  [--solo estilo|ciudades|zonas|departamentos|uruguay] [--ciudad SLUG]... [--zona ID]...
//                              [--regenerar] [--quitar ID]... [--build AAAAMMDD] [--dry-run]
//   node src/cli.mjs catalogo-uruguay [--salida ARCHIVO] [--funcion-sql ARCHIVO] [--overpass URL]
//   node src/cli.mjs verificar [--url URL]
//
// Variables de entorno:
//   SUPABASE_URL                 https://<proyecto>.supabase.co   (publicar y verificar)
//   SUPABASE_SERVICE_ROLE_KEY    clave de servicio; solo publicar. NUNCA va al repo: sale de los secretos del workflow.
//                                Nada de lo que imprime este programa la lleva (ver secretos.mjs).
//   OVERPASS_URL                 otro servidor de Overpass para `catalogo-uruguay` (si el público está saturado)
//   PMTILES_BIN                  ruta al CLI `pmtiles` (si no, se usa el del PATH o se baja el de la release fijada)

import { mkdir, mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { parseArgs } from 'node:util';
import { ciudadesPublicables, leerCiudades } from './ambito.mjs';
import { BUCKET } from './bucket.mjs';
import { armarEstilo, leerPaleta } from './estilo.mjs';
import {
  ahoraIso,
  publicarCatalogoDeEstilo,
  publicarAmplios,
  publicarCiudades,
  publicarEstilo,
  serializarEstilo,
  versionDeEstilo,
} from './publicar.mjs';
import { FUENTE_PROTOMAPS, asegurarPmtiles, buscarBuild, extraer } from './recorte.mjs';
import { ocultar } from './secretos.mjs';
import { clienteStorage, tapar } from './storage.mjs';
import { verificar } from './verificar.mjs';
import {
  armarCatalogo,
  departamentosPublicables,
  descargar,
  funcionSql,
  leerCatalogo,
  serializar,
  URL_OVERPASS,
  uruguayPublicable,
  validarCatalogo,
} from './uruguay.mjs';
import { clienteZonas, publicarZonas } from './zonas.mjs';

const RAIZ = fileURLToPath(new URL('..', import.meta.url));
const CATALOGO_URUGUAY = join(RAIZ, 'datos', 'uruguay-osm.json');
const secretos = () => [process.env.SUPABASE_SERVICE_ROLE_KEY, process.env.SUPABASE_ACCESS_TOKEN];
// Nada de lo que imprime este programa lleva la clave ni el nombre del archivo del mapa de una zona (`tapar`).
const log = (mensaje) => console.log(tapar(ocultar(mensaje, ...secretos())));

function entorno(nombre) {
  const valor = process.env[nombre];
  if (!valor) throw new Error(`Falta la variable de entorno ${nombre}`);
  return valor;
}

const urlPublicaDe = (supabaseUrl) => `${supabaseUrl.replace(/\/+$/, '')}/storage/v1/object/public/${BUCKET.id}`;

async function versionDeBasemaps() {
  const paquete = JSON.parse(await readFile(join(RAIZ, 'package.json'), 'utf8'));
  return paquete.dependencies['@protomaps/basemaps'];
}

async function generarEstilo(urlBase) {
  const paleta = await leerPaleta(join(RAIZ, 'paleta.json'));
  return armarEstilo({ urlBase, paleta, version: await versionDeBasemaps() });
}

async function comandoEstilo(opciones) {
  const urlBase = opciones['url-base'] ?? `${urlPublicaDe(entorno('SUPABASE_URL'))}/estilo`;
  const salida = opciones.salida ?? join(RAIZ, 'dist', 'estilo');
  await mkdir(salida, { recursive: true });
  await writeFile(join(salida, 'colportores.json'), `${JSON.stringify(await generarEstilo(urlBase), null, 2)}\n`);
  log(`estilo escrito en ${join(salida, 'colportores.json')}`);
}

/**
 * Arma `datos/uruguay-osm.json` desde OpenStreetMap (Overpass): los 19 departamentos con su rectángulo, el país y
 * las ciudades, pueblos y villas con su departamento, su centro y su rectángulo cuando OSM trae el límite. Con
 * `--funcion-sql` escribe además el `create or replace function public.catalogo_osm_uruguay()` para pegarlo en una
 * migración nueva (la lista cambia con una migración, no editando la 0109).
 */
async function comandoCatalogoUruguay(opciones) {
  const salida = opciones.salida ?? CATALOGO_URUGUAY;
  const descargado = await descargar({ url: opciones.overpass ?? process.env.OVERPASS_URL ?? URL_OVERPASS, log });
  const catalogo = armarCatalogo(descargado, { generadoEn: ahoraIso() });
  const errores = validarCatalogo(catalogo);
  if (errores.length > 0) throw new Error(`El catálogo que salió de OSM no es válido; no se escribió nada:\n  ${errores.join('\n  ')}`);
  await mkdir(dirname(salida), { recursive: true });
  await writeFile(salida, serializar(catalogo));
  const conLimite = catalogo.ciudades.filter((c) => c.bbox).length;
  log(`${salida}: ${catalogo.departamentos.length} departamentos, ${catalogo.ciudades.length} ciudades (${conLimite} con rectángulo), ${catalogo.descartados.length} descartadas`);
  if (opciones['funcion-sql']) {
    await writeFile(opciones['funcion-sql'], funcionSql(catalogo));
    log(`${opciones['funcion-sql']}: la función para la migración`);
  }
}

async function comandoPublicar(opciones) {
  const dryRun = Boolean(opciones['dry-run']);
  const solo = opciones.solo ?? 'todo';
  if (!['todo', 'estilo', 'ciudades', 'zonas', 'departamentos', 'uruguay'].includes(solo)) {
    throw new Error('--solo es estilo, ciudades, zonas, departamentos o uruguay');
  }
  const nivelAmplio = solo === 'departamentos' ? 'departamento' : solo === 'uruguay' ? 'uruguay' : null;
  const conCiudades = solo === 'todo' || solo === 'ciudades';
  const conZonas = solo === 'todo' || solo === 'zonas';
  const quitarIds = opciones.quitar ?? [];
  if (quitarIds.length > 0 && !conCiudades) throw new Error('--quitar saca un paquete de ciudad del catálogo: va con --solo ciudades (o sin --solo)');
  if (quitarIds.length > 0 && opciones.ciudad?.length) throw new Error('--quitar no se combina con --ciudad: una publica una ciudad, la otra saca otra');

  const supabaseUrl = entorno('SUPABASE_URL');
  const clave = dryRun ? process.env.SUPABASE_SERVICE_ROLE_KEY : entorno('SUPABASE_SERVICE_ROLE_KEY');
  const storage = clienteStorage({ url: supabaseUrl, clave, bucket: BUCKET.id });

  // Lo que puede impedir publicar se resuelve ANTES de escribir nada en el bucket: qué ciudades se publican
  // (las de public.ciudad que tienen su rectángulo: no hay ninguna lista en el repo) y el id de cada una (su
  // `ambito_id` en el catálogo).
  let elegidas = [];
  let ciudadesEnBase;
  if (conCiudades) {
    if (clave) {
      ciudadesEnBase = await leerCiudades({ url: supabaseUrl, clave });
      const { publicables, sinRectangulo } = ciudadesPublicables(ciudadesEnBase);
      if (sinRectangulo.length > 0) {
        log(
          `ciudades sin rectángulo (no tienen mapa propio; se carga en public.ciudad, docs/guia-carga-manual.md § 2): ${sinRectangulo.join(', ')}`,
        );
      }
      elegidas = opciones.ciudad?.length ? publicables.filter((c) => opciones.ciudad.includes(c.slug)) : publicables;
      if (opciones.ciudad?.length && elegidas.length === 0) {
        throw new Error(`Ninguna ciudad con rectángulo coincide con ${opciones.ciudad.join(', ')} (las que hay: ${publicables.map((c) => c.slug).join(', ') || 'ninguna'})`);
      }
      if (elegidas.length === 0) log('no hay ciudades con rectángulo en public.ciudad: no hay mapas de ciudad para publicar');
    } else {
      log('[dry-run] sin clave de servicio no puedo leer public.ciudad: no hay ciudades que simular');
    }
  }

  if (conZonas && !clave) log('[dry-run] sin clave de servicio no puedo leer public.zona: no hay zonas que simular');
  if (!dryRun) log(`bucket ${BUCKET.id}: ${await storage.asegurarBucket(BUCKET)}`);

  let estiloVersion;
  if (solo === 'todo' || solo === 'estilo') {
    const estilo = await generarEstilo(`${urlPublicaDe(supabaseUrl)}/estilo`);
    if (dryRun) {
      estiloVersion = versionDeEstilo(serializarEstilo(estilo));
      log(`[dry-run] estilo con ${estilo.layers.length} capas, no se sube`);
    } else {
      ({ version: estiloVersion } = await publicarEstilo({ storage, estilo, raizAssets: join(RAIZ, 'assets'), log }));
    }
    // El estilo nuevo tiene que verse en el catálogo (estilo.version): con `todo`, lo escribe publicarCiudades.
    if (solo === 'estilo') await publicarCatalogoDeEstilo({ storage, estiloVersion, ahora: ahoraIso(), dryRun, log });
  }

  const hayCiudades = conCiudades && ciudadesEnBase !== undefined;
  const hayZonas = conZonas && Boolean(clave);
  if (!hayCiudades && !hayZonas && !nivelAmplio) return;

  const tmp = await mkdtemp(join(tmpdir(), 'tiles-'));
  try {
    // La fuente (el build de Protomaps y el CLI `pmtiles`) se busca la primera vez que hay algo que cortar:
    // una corrida en la que ninguna zona cambió no la necesita.
    let fuente;
    const preparar = async (build) => {
      fuente ??= (async () => {
        const elegido = build ?? (await buscarBuild());
        const pmtiles = await asegurarPmtiles({ cache: join(RAIZ, '.cache') });
        log(`fuente: ${FUENTE_PROTOMAPS(elegido)}`);
        return { build: elegido, pmtiles, url: FUENTE_PROTOMAPS(elegido) };
      })();
      return fuente;
    };

    if (hayCiudades) {
      const { build } = elegidas.length > 0 ? await preparar(opciones.build) : { build: opciones.build };
      await publicarCiudades({
        storage,
        ciudades: elegidas,
        ciudadesEnBase: opciones.ciudad?.length ? undefined : ciudadesEnBase,
        quitarIds,
        extraer: async ({ bbox, zoomMax, destino }) => {
          const { pmtiles, url } = await preparar(opciones.build);
          return extraer({ pmtiles, fuente: url, destino, bbox, zoomMax });
        },
        tmp,
        build,
        estiloVersion,
        ahora: ahoraIso(),
        dryRun,
        log,
      });
    }

    // Departamentos y todo Uruguay: solo a pedido (`--solo departamentos|uruguay`), con los rectángulos de la lista
    // fija de datos/uruguay-osm.json (no de public.ciudad). Un archivo de estos pesa cientos de MB: con el tope de
    // 50 MB del plan Free no entran y la corrida falla en voz alta (el tope de Pro es de backend-supabase#68).
    if (nivelAmplio) {
      const catalogoUruguay = await leerCatalogo(CATALOGO_URUGUAY);
      const ambitos = nivelAmplio === 'uruguay' ? [uruguayPublicable(catalogoUruguay)] : departamentosPublicables(catalogoUruguay);
      await publicarAmplios({
        storage,
        nivel: nivelAmplio,
        ambitos,
        extraer: async ({ bbox, zoomMax, destino }) => {
          const { pmtiles, url } = await preparar(opciones.build);
          return extraer({ pmtiles, fuente: url, destino, bbox, zoomMax });
        },
        tmp,
        build: (await preparar(opciones.build)).build,
        estiloVersion,
        ahora: ahoraIso(),
        dryRun,
        log,
      });
    }

    // Las zonas, DESPUÉS de las ciudades: una zona con falla no deshace lo ya publicado ni corta a las demás
    // (la corrida termina con error al final), y las ciudades son lo que el Hito 1 necesita.
    if (hayZonas) {
      const resultado = await publicarZonas({
        storage,
        repo: clienteZonas({ url: supabaseUrl, clave }),
        extraer: async ({ region, zoomMax, destino }) => {
          const { pmtiles, url } = await preparar(opciones.build);
          return extraer({ pmtiles, fuente: url, destino, region, zoomMax });
        },
        tmp,
        ahora: ahoraIso(),
        dryRun,
        log,
        solo: opciones.zona ?? [],
        regenerar: Boolean(opciones.regenerar),
      });
      if (resultado.fallas.length > 0) process.exitCode = 1;
    }
  } finally {
    await rm(tmp, { recursive: true, force: true });
  }
}

async function comandoVerificar(opciones) {
  const urlPublica = opciones.url ?? urlPublicaDe(entorno('SUPABASE_URL'));
  const resultados = await verificar({ urlPublica });
  for (const r of resultados) {
    const marca = !r.ok ? 'FALLA' : r.aviso ? 'aviso' : 'ok   ';
    log(`${marca} ${r.que}${r.detalle ? ` — ${r.detalle}` : ''}`);
  }
  const fallas = resultados.filter((r) => !r.ok).length;
  log(fallas === 0 ? `\nTodo bien (${resultados.length} comprobaciones).` : `\n${fallas} comprobaciones fallaron.`);
  if (fallas > 0) process.exitCode = 1;
}

async function main() {
  const { positionals, values } = parseArgs({
    allowPositionals: true,
    options: {
      'url-base': { type: 'string' },
      salida: { type: 'string' },
      solo: { type: 'string' },
      ciudad: { type: 'string', multiple: true },
      zona: { type: 'string', multiple: true },
      quitar: { type: 'string', multiple: true },
      regenerar: { type: 'boolean' },
      build: { type: 'string' },
      url: { type: 'string' },
      'funcion-sql': { type: 'string' },
      overpass: { type: 'string' },
      'dry-run': { type: 'boolean' },
    },
  });
  const [comando] = positionals;
  const comandos = { estilo: comandoEstilo, publicar: comandoPublicar, verificar: comandoVerificar, 'catalogo-uruguay': comandoCatalogoUruguay };
  if (!comandos[comando]) {
    console.error('Uso: node src/cli.mjs estilo | publicar | verificar | catalogo-uruguay (ver docs/mapas-tiles.md)');
    process.exitCode = 2;
    return;
  }
  await comandos[comando](values);
}

main().catch((error) => {
  const causa = error.cause ? ` (${error.cause.code ?? error.cause.message})` : '';
  console.error(`ERROR: ${tapar(ocultar(`${error.message}${causa}`, ...secretos()))}`);
  process.exitCode = 1;
});
