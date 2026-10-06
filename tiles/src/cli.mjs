#!/usr/bin/env node
// Herramienta de los mapas propios (backend-supabase#42). Se explica entera en docs/mapas-tiles.md.
//
//   node src/cli.mjs estilo    [--url-base URL] [--salida DIR]
//   node src/cli.mjs publicar  [--solo estilo|ciudades] [--ciudad SLUG]... [--build AAAAMMDD] [--dry-run]
//   node src/cli.mjs verificar [--url URL]
//
// Variables de entorno:
//   SUPABASE_URL                 https://<proyecto>.supabase.co   (publicar y verificar)
//   SUPABASE_SERVICE_ROLE_KEY    clave de servicio; solo publicar. NUNCA va al repo: sale de los secretos del workflow.
//   PMTILES_BIN                  ruta al CLI `pmtiles` (si no, se usa el del PATH o se baja el de la release fijada)

import { mkdir, mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { parseArgs } from 'node:util';
import { BUCKET } from './bucket.mjs';
import { armarEstilo, leerPaleta } from './estilo.mjs';
import { ahoraIso, publicarCiudades, publicarEstilo } from './publicar.mjs';
import { FUENTE_PROTOMAPS, asegurarPmtiles, buscarBuild, extraer } from './recorte.mjs';
import { clienteStorage } from './storage.mjs';
import { verificar } from './verificar.mjs';

const RAIZ = fileURLToPath(new URL('..', import.meta.url));
const log = (mensaje) => console.log(mensaje);

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

async function comandoPublicar(opciones) {
  const dryRun = Boolean(opciones['dry-run']);
  const solo = opciones.solo ?? 'todo';
  if (!['todo', 'estilo', 'ciudades'].includes(solo)) throw new Error('--solo es estilo o ciudades');

  const supabaseUrl = entorno('SUPABASE_URL');
  const storage = clienteStorage({
    url: supabaseUrl,
    clave: dryRun ? process.env.SUPABASE_SERVICE_ROLE_KEY : entorno('SUPABASE_SERVICE_ROLE_KEY'),
    bucket: BUCKET.id,
  });

  if (!dryRun) log(`bucket ${BUCKET.id}: ${await storage.asegurarBucket(BUCKET)}`);

  if (solo !== 'ciudades') {
    const estilo = await generarEstilo(`${urlPublicaDe(supabaseUrl)}/estilo`);
    if (dryRun) log(`[dry-run] estilo con ${estilo.layers.length} capas, no se sube`);
    else await publicarEstilo({ storage, estilo, raizAssets: join(RAIZ, 'assets'), log });
  }

  if (solo !== 'estilo') {
    const { ciudades } = JSON.parse(await readFile(join(RAIZ, 'ciudades.json'), 'utf8'));
    const elegidas = opciones.ciudad?.length ? ciudades.filter((c) => opciones.ciudad.includes(c.slug)) : ciudades;
    if (elegidas.length === 0) throw new Error(`Ninguna ciudad coincide con ${opciones.ciudad}`);

    const build = opciones.build ?? (await buscarBuild());
    const pmtiles = await asegurarPmtiles({ cache: join(RAIZ, '.cache') });
    const tmp = await mkdtemp(join(tmpdir(), 'tiles-'));
    try {
      log(`fuente: ${FUENTE_PROTOMAPS(build)}`);
      await publicarCiudades({
        storage,
        ciudades: elegidas,
        extraer: ({ bbox, zoomMax, destino }) =>
          extraer({ pmtiles, fuente: FUENTE_PROTOMAPS(build), destino, bbox, zoomMax }),
        tmp,
        build,
        ahora: ahoraIso(),
        dryRun,
        log,
      });
    } finally {
      await rm(tmp, { recursive: true, force: true });
    }
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
      build: { type: 'string' },
      url: { type: 'string' },
      'dry-run': { type: 'boolean' },
    },
  });
  const [comando] = positionals;
  const comandos = { estilo: comandoEstilo, publicar: comandoPublicar, verificar: comandoVerificar };
  if (!comandos[comando]) {
    console.error('Uso: node src/cli.mjs estilo | publicar | verificar (ver docs/mapas-tiles.md)');
    process.exitCode = 2;
    return;
  }
  await comandos[comando](values);
}

main().catch((error) => {
  console.error(`ERROR: ${error.message}`);
  process.exitCode = 1;
});
