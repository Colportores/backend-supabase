// El estilo que publica backend sale de lib-mapa (ADR-019, backend-supabase#256). Los tests del estilo en sí
// (MapLibre válido, paleta, contraste AA, capturas) viven en lib-mapa; acá se prueba lo que le toca al
// publicador: que use la release fijada, que apunte los glyphs y los sprites a nuestro bucket y que encuentre
// los archivos que sube.
import assert from 'node:assert/strict';
import { execFile } from 'node:child_process';
import { access, mkdtemp, readFile, readdir, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { test } from 'node:test';
import { fileURLToPath } from 'node:url';
import { promisify } from 'node:util';
import { RAIZ_ASSETS, VERSION_DE_LA_LIBRERIA, estiloDeLaLibreria, tagFijado } from '../src/lib-mapa.mjs';
import { URL_BASE_DE_PRUEBA, estiloDePrueba } from './ayudas.mjs';

const RAIZ = fileURLToPath(new URL('..', import.meta.url));
const paquete = JSON.parse(await readFile(join(RAIZ, 'package.json'), 'utf8'));
const estilo = estiloDePrueba();

/** Todas las cadenas de un valor de estilo, también las de adentro de una expresión. */
function cadenas(valor, salida = new Set()) {
  if (typeof valor === 'string') salida.add(valor);
  else if (Array.isArray(valor)) valor.forEach((v) => cadenas(v, salida));
  else if (valor && typeof valor === 'object') Object.values(valor).forEach((v) => cadenas(v, salida));
  return salida;
}

// Mientras lib-mapa no tenga el tag de su release, el PR lo fija por commit y este test queda como `todo` (se ve
// en la salida, no frena): con el tag en package.json vuelve a ser obligatorio.
const espec = paquete.dependencies['@colportores/lib-mapa'] ?? '';
const porCommit = /^github:Colportores\/lib-mapa#[0-9a-f]{40}$/.test(espec);

test('package.json fija lib-mapa por tag de GitHub, y la instalada es esa versión', { todo: porCommit && `fijada por commit (${espec.slice(-7)}), falta el tag de la release de lib-mapa` }, () => {
  assert.match(espec, /^github:Colportores\/lib-mapa#v\d+\.\d+\.\d+$/);
  assert.equal(tagFijado(paquete), `v${VERSION_DE_LA_LIBRERIA}`, 'node_modules tiene otra versión: correr npm ci');
  assert.equal(estilo.metadata['colportores:estilo'], VERSION_DE_LA_LIBRERIA, 'el estilo lleva la versión de la librería');
});

test('tagFijado lee solo un tag vX.Y.Z', () => {
  assert.equal(tagFijado({ dependencies: { '@colportores/lib-mapa': 'github:Colportores/lib-mapa#v1.2.3' } }), 'v1.2.3');
  assert.equal(tagFijado({ dependencies: { '@colportores/lib-mapa': 'github:Colportores/lib-mapa#develop' } }), null);
  assert.equal(tagFijado({ dependencies: {} }), null);
});

test('el estilo, la paleta y los assets ya no están duplicados en tiles/', async () => {
  assert.equal(paquete.dependencies['@protomaps/basemaps'], undefined, 'basemaps llega por lib-mapa, con su versión fijada allá');
  for (const viejo of ['paleta.json', 'assets', join('src', 'estilo.mjs')]) {
    await assert.rejects(access(join(RAIZ, viejo)), `tiles/${viejo} no debería existir: vive en lib-mapa`);
  }
});

test('los glyphs y los sprites apuntan al bucket; la fuente de tiles la pone cada cliente', () => {
  assert.equal(estilo.glyphs, `${URL_BASE_DE_PRUEBA}/glyphs/{fontstack}/{range}.pbf`);
  assert.equal(estilo.sprite, `${URL_BASE_DE_PRUEBA}/sprites/grayscale`);
  assert.deepEqual(Object.keys(estilo.sources), ['protomaps']);
  assert.equal(estilo.sources.protomaps.url, 'pmtiles://REEMPLAZAR');
  assert.match(estilo.sources.protomaps.attribution, /OpenStreetMap/);
});

test('una URL base relativa no sirve (MapLibre pide glyphs y sprites con URL absoluta)', async () => {
  await assert.rejects(estiloDeLaLibreria('estilo'), /absoluta/);
});

test('es determinista: la misma release y la misma URL dan el mismo archivo', async () => {
  assert.equal(JSON.stringify(await estiloDeLaLibreria(`${URL_BASE_DE_PRUEBA}///`)), JSON.stringify(estilo));
});

test('trae los números de puerta de OSM desde el zoom de calle (z16, decisión P4)', () => {
  const numeros = estilo.layers.find((capa) => capa.id === 'address_label');
  assert.ok(numeros, 'falta la capa address_label');
  assert.ok(numeros.minzoom <= 16, `address_label desde z${numeros.minzoom}`);
});

test('cada fuente que el estilo pide tiene sus glyphs en la librería (los rangos de español y puntuación)', async () => {
  const fuentes = [...cadenas(estilo.layers.map((l) => l.layout?.['text-font']))].filter((s) => s.startsWith('NotoSans-'));
  assert.ok(fuentes.length > 0);
  for (const fuente of fuentes) {
    const rangos = await readdir(join(RAIZ_ASSETS, 'glyphs', fuente));
    for (const esperado of ['0-255.pbf', '256-511.pbf', '8192-8447.pbf']) {
      assert.ok(rangos.includes(esperado), `${fuente} sin ${esperado}`);
    }
  }
  await access(join(RAIZ_ASSETS, 'glyphs', 'OFL.txt'));
});

test('el sprite de la librería trae el índice y las imágenes a 1x y 2x', async () => {
  for (const archivo of ['grayscale.json', 'grayscale@2x.json', 'grayscale.png', 'grayscale@2x.png']) {
    await access(join(RAIZ_ASSETS, 'sprites', archivo));
  }
  const indice = JSON.parse(await readFile(join(RAIZ_ASSETS, 'sprites', 'grayscale.json'), 'utf8'));
  assert.ok('arrow' in indice, 'falta el ícono arrow de los rótulos de calle');
});

test('el CLI escribe en un directorio el estilo de la librería', async () => {
  const salida = await mkdtemp(join(tmpdir(), 'estilo-'));
  try {
    await promisify(execFile)(process.execPath, [join(RAIZ, 'src', 'cli.mjs'), 'estilo', '--url-base', URL_BASE_DE_PRUEBA, '--salida', salida]);
    const escrito = JSON.parse(await readFile(join(salida, 'colportores.json'), 'utf8'));
    assert.equal(JSON.stringify(escrito), JSON.stringify(estilo));
  } finally {
    await rm(salida, { recursive: true, force: true });
  }
});
