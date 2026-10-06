import assert from 'node:assert/strict';
import { execFile } from 'node:child_process';
import { access, mkdtemp, readFile, readdir, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { test } from 'node:test';
import { fileURLToPath } from 'node:url';
import { promisify } from 'node:util';
import { validateStyleMin } from '@maplibre/maplibre-gl-style-spec';
import { ATRIBUCION, NOMBRE_DE_LA_FUENTE, URL_A_REEMPLAZAR, armarEstilo, leerPaleta } from '../src/estilo.mjs';

const RAIZ = fileURLToPath(new URL('..', import.meta.url));
const URL_BASE = 'https://proyecto.supabase.co/storage/v1/object/public/mapas/estilo';
const paleta = await leerPaleta(join(RAIZ, 'paleta.json'));
const estilo = armarEstilo({ urlBase: URL_BASE, paleta, version: '5.7.2' });

/** Todas las cadenas de un valor de estilo, también las de adentro de una expresión. */
function cadenas(valor, salida = new Set()) {
  if (typeof valor === 'string') salida.add(valor);
  else if (Array.isArray(valor)) valor.forEach((v) => cadenas(v, salida));
  else if (valor && typeof valor === 'object') Object.values(valor).forEach((v) => cadenas(v, salida));
  return salida;
}

test('es un estilo de MapLibre válido', () => {
  assert.deepEqual(validateStyleMin(structuredClone(estilo)), []);
  assert.equal(estilo.version, 8);
  assert.ok(estilo.layers.length > 50, `tiene ${estilo.layers.length} capas`);
});

test('pinta con la paleta del canvas: tierra, agua, parques y avenidas', () => {
  const capa = (id) => estilo.layers.find((l) => l.id === id);
  assert.equal(capa('background').paint['background-color'], '#F6F5F0');
  assert.equal(capa('water').paint['fill-color'], '#C9D6EA');
  assert.ok(cadenas(capa('landuse_park').paint).has('#DDE8D3'), 'los parques van en el verde del canvas');
  assert.ok(estilo.layers.every((l) => l.id !== 'pois'), 'sin puntos de interés: el sprite no trae sus íconos');
  const colores = cadenas(estilo.layers.map((l) => l.paint));
  for (const color of ['#FBF1D6', '#EAD9A6', '#E1DED3']) {
    assert.ok(colores.has(color), `falta ${color} en el estilo`);
  }
});

/** Contraste WCAG entre dos colores #RRGGBB. */
function contraste(a, b) {
  const luz = (hex) => {
    const [r, g, bl] = [1, 3, 5].map((i) => parseInt(hex.slice(i, i + 2), 16) / 255);
    const lineal = (c) => (c <= 0.03928 ? c / 12.92 : ((c + 0.055) / 1.055) ** 2.4);
    return 0.2126 * lineal(r) + 0.7152 * lineal(g) + 0.0722 * lineal(bl);
  };
  const [claro, oscuro] = [luz(a), luz(b)].sort((x, y) => y - x);
  return (claro + 0.05) / (oscuro + 0.05);
}

/** El objeto de paleta.json que tiene la clave `clave` (no importa a qué profundidad esté). */
function conClave(valor, clave) {
  if (!valor || typeof valor !== 'object') return undefined;
  if (clave in valor) return valor;
  for (const hijo of Object.values(valor)) {
    const hallado = conClave(hijo, clave);
    if (hallado) return hallado;
  }
  return undefined;
}

test('los rótulos que se leen (calles, barrios, números de puerta) cumplen AA (4,5:1) sobre su halo', async () => {
  // Decisión del 06/10: AA gana al canvas, que da 3,41:1 (#7C8594) y 2,85:1 (#8A93A0) sobre #F6F5F0.
  const colores = conClave(JSON.parse(await readFile(join(RAIZ, 'paleta.json'), 'utf8')), 'roads_label_minor');
  for (const clave of ['roads_label_minor', 'roads_label_major', 'subplace_label', 'address_label']) {
    const razon = contraste(colores[clave], colores[`${clave}_halo`]);
    assert.ok(razon >= 4.5, `${clave} (${colores[clave]} sobre ${colores[`${clave}_halo`]}) da ${razon.toFixed(2)}:1`);
  }
});

test('un solo estilo: una fuente de tiles que el cliente completa con el archivo de su paquete', () => {
  assert.deepEqual(Object.keys(estilo.sources), [NOMBRE_DE_LA_FUENTE]);
  assert.equal(estilo.sources.protomaps.url, URL_A_REEMPLAZAR);
  assert.ok(estilo.layers.every((l) => l.type === 'background' || l.source === NOMBRE_DE_LA_FUENTE));
});

test('cita a OpenStreetMap en la atribución (ODbL)', () => {
  assert.equal(estilo.sources.protomaps.attribution, ATRIBUCION);
  assert.match(ATRIBUCION, /OpenStreetMap/);
  assert.match(ATRIBUCION, /openstreetmap\.org\/copyright/);
});

test('glyphs y sprites salen del mismo bucket, con URLs absolutas', () => {
  assert.equal(estilo.glyphs, `${URL_BASE}/glyphs/{fontstack}/{range}.pbf`);
  assert.equal(estilo.sprite, `${URL_BASE}/sprites/grayscale`);
  assert.throws(() => armarEstilo({ urlBase: 'estilo', paleta, version: '5.7.2' }), /absoluta/);
  assert.equal(armarEstilo({ urlBase: `${URL_BASE}///`, paleta, version: '5.7.2' }).glyphs, estilo.glyphs);
});

test('es determinista: la misma paleta da el mismo archivo, byte por byte', () => {
  const otra = armarEstilo({ urlBase: URL_BASE, paleta: structuredClone(paleta), version: '5.7.2' });
  assert.equal(JSON.stringify(otra), JSON.stringify(estilo));
});

test('los rótulos van en español', () => {
  const textos = JSON.stringify(estilo.layers.map((l) => l.layout?.['text-field']));
  assert.match(textos, /name:es/);
});

test('cada fuente que el estilo pide tiene sus glyphs publicados (los rangos de español y puntuación)', async () => {
  const fuentes = [...cadenas(estilo.layers.map((l) => l.layout?.['text-font']))].filter((s) => s.startsWith('NotoSans-'));
  assert.deepEqual(fuentes.sort(), ['NotoSans-Italic', 'NotoSans-Medium', 'NotoSans-Regular']);
  for (const fuente of fuentes) {
    const rangos = await readdir(join(RAIZ, 'assets', 'glyphs', fuente));
    for (const esperado of ['0-255.pbf', '256-511.pbf', '8192-8447.pbf']) {
      assert.ok(rangos.includes(esperado), `${fuente} sin ${esperado}`);
    }
  }
  await access(join(RAIZ, 'assets', 'glyphs', 'OFL.txt'));
});

test('el sprite trae el índice y las imágenes a 1x y 2x, y el ícono de flecha de los rótulos de calle', async () => {
  for (const archivo of ['grayscale.json', 'grayscale@2x.json', 'grayscale.png', 'grayscale@2x.png']) {
    await access(join(RAIZ, 'assets', 'sprites', archivo));
  }
  const indice = JSON.parse(await readFile(join(RAIZ, 'assets', 'sprites', 'grayscale.json'), 'utf8'));
  assert.ok('arrow' in indice, 'falta el ícono arrow');
  assert.ok(Object.keys(indice).length >= 15);
});

test('la paleta no usa colores mal escritos', () => {
  const colores = cadenas([paleta.flavor, paleta.landcover]);
  for (const c of colores) {
    if (c.startsWith('NotoSans')) continue;
    assert.match(c, /^#[0-9A-Fa-f]{6}$/, `color inválido: ${c}`);
  }
});

test('el CLI escribe el estilo en un directorio', async () => {
  const salida = await mkdtemp(join(tmpdir(), 'estilo-'));
  try {
    await promisify(execFile)(process.execPath, [join(RAIZ, 'src', 'cli.mjs'), 'estilo', '--url-base', URL_BASE, '--salida', salida]);
    const escrito = JSON.parse(await readFile(join(salida, 'colportores.json'), 'utf8'));
    assert.equal(JSON.stringify(escrito), JSON.stringify(estilo));
  } finally {
    await rm(salida, { recursive: true, force: true });
  }
});
