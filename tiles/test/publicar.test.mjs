import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { mkdtemp, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { test } from 'node:test';
import { fileURLToPath } from 'node:url';
import { validar } from '../src/catalogo.mjs';
import { estiloDePrueba } from './ayudas.mjs';
import { RUTA_CATALOGO, RUTA_ESTILO, listarArchivos, publicarCiudades, publicarEstilo } from '../src/publicar.mjs';

const MONTEVIDEO = { slug: 'montevideo', nombre: 'Montevideo', ciudad_id: null, bbox: [-56.433, -34.945, -55.948, -34.701] };
const sha = (buf) => createHash('sha256').update(buf).digest('hex');

/** Un bucket en memoria con la misma interfaz que clienteStorage(), y el orden de lo que se subió. */
function bucketFalso({ previo = {}, fechas = {} } = {}) {
  const objetos = new Map(Object.entries(previo));
  const subidas = [];
  return {
    objetos,
    subidas,
    async subir(ruta, contenido, { contentType, cacheControl }) {
      objetos.set(ruta, Buffer.from(contenido));
      subidas.push({ ruta, contentType, cacheControl });
    },
    async bajarJson(ruta) {
      return objetos.has(ruta) ? JSON.parse(objetos.get(ruta).toString()) : null;
    },
    async existe(ruta) {
      return objetos.has(ruta);
    },
    async listar(prefijo) {
      return [...objetos.keys()]
        .filter((r) => r.startsWith(`${prefijo}/`))
        .map((ruta) => ({ ruta, actualizado_en: fechas[ruta] ?? '2026-10-07T11:00:00Z' }));
    },
    async borrar(rutas) {
      for (const r of rutas) objetos.delete(r);
    },
  };
}

/** Un recorte de mentira: escribe un archivo cuyo contenido y tamaño dependen del zoom y del contenido de `semilla`. */
function recorteFalso({ bytesPorZoom = { 15: 10_000, 14: 4_000 }, semilla = 'a' } = {}) {
  const llamadas = [];
  return {
    llamadas,
    extraer: async ({ bbox, zoomMax, destino }) => {
      llamadas.push({ bbox, zoomMax });
      const tamano = Math.round(bytesPorZoom[zoomMax] * ((bbox[2] - bbox[0]) / (MONTEVIDEO.bbox[2] - MONTEVIDEO.bbox[0])));
      const contenido = Buffer.alloc(tamano, `${semilla}${zoomMax}${bbox.join()}`);
      await writeFile(destino, contenido);
      return tamano;
    },
  };
}

async function conTmp(fn) {
  const tmp = await mkdtemp(join(tmpdir(), 'publicar-test-'));
  try {
    return await fn(tmp);
  } finally {
    await rm(tmp, { recursive: true, force: true });
  }
}

const AHORA = '2026-10-07T12:00:00Z';
const opciones = (storage, recorte, tmp, extra = {}) => ({
  storage,
  ciudades: [MONTEVIDEO],
  extraer: recorte.extraer,
  tmp,
  build: '20261006',
  ahora: AHORA,
  limites: { maxBytes: 50_000 },
  ...extra,
});

test('publica una ciudad: sube el paquete y, recién después, el catálogo que lo describe', () =>
  conTmp(async (tmp) => {
    const storage = bucketFalso();
    const recorte = recorteFalso();
    const { catalogo } = await publicarCiudades(opciones(storage, recorte, tmp));

    const rutas = storage.subidas.map((s) => s.ruta);
    assert.equal(rutas.length, 2);
    assert.match(rutas[0], /^paquetes\/ciudad\/montevideo\.[0-9a-f]{12}\.pmtiles$/);
    assert.equal(rutas[1], RUTA_CATALOGO, 'el catálogo va último: nunca apunta a algo que no está');

    const [p] = catalogo.paquetes;
    assert.equal(p.id, 'ciudad-montevideo');
    assert.equal(p.nivel, 'ciudad');
    assert.equal(p.ambito_id, null);
    assert.equal(p.zoom_max, 15);
    assert.equal(p.tamano_bytes, 10_000);
    assert.equal(p.fuente_build, '20261006');
    assert.equal(p.partes[0].archivo, rutas[0]);
    assert.equal(p.partes[0].sha256, sha(storage.objetos.get(rutas[0])), 'el SHA-256 del catálogo es el del archivo subido');
    assert.equal(p.partes[0].tamano_bytes, storage.objetos.get(rutas[0]).length);
    assert.deepEqual(validar(catalogo), []);
    assert.deepEqual(JSON.parse(storage.objetos.get(RUTA_CATALOGO)), catalogo);

    assert.equal(storage.subidas[0].cacheControl, 'public, max-age=31536000, immutable');
    assert.equal(storage.subidas[1].cacheControl, 'public, max-age=60');
    assert.equal(storage.subidas[0].contentType, 'application/octet-stream');
    assert.equal(storage.subidas[1].contentType, 'application/json');
  }));

test('volver a publicar lo mismo no sube nada nuevo ni cambia la fecha del paquete', () =>
  conTmp(async (tmp) => {
    const storage = bucketFalso();
    await publicarCiudades(opciones(storage, recorteFalso(), tmp));
    const antes = structuredClone(await storage.bajarJson(RUTA_CATALOGO));
    const cantidad = storage.subidas.length;

    const { catalogo } = await publicarCiudades(opciones(storage, recorteFalso(), tmp, { ahora: '2026-10-08T12:00:00Z' }));
    assert.equal(storage.subidas.length, cantidad + 1, 'solo el catálogo (generado_en)');
    assert.equal(storage.subidas.at(-1).ruta, RUTA_CATALOGO);
    assert.deepEqual(catalogo.paquetes, antes.paquetes, 'el paquete queda idéntico: la app no ve una actualización');
  }));

test('con contenido nuevo el archivo nuevo convive con el viejo y la app ve una actualización', () =>
  conTmp(async (tmp) => {
    const storage = bucketFalso();
    const { catalogo: v1 } = await publicarCiudades(opciones(storage, recorteFalso({ semilla: 'a' }), tmp));
    const { catalogo: v2, borrados } = await publicarCiudades(
      opciones(storage, recorteFalso({ semilla: 'b' }), tmp, { ahora: '2026-10-08T12:00:00Z', build: '20261008' }),
    );

    assert.notEqual(v2.paquetes[0].version, v1.paquetes[0].version);
    assert.notEqual(v2.paquetes[0].partes[0].archivo, v1.paquetes[0].partes[0].archivo);
    assert.equal(v2.paquetes[0].fuente_build, '20261008');
    assert.equal(v2.paquetes[0].actualizado_en, '2026-10-08T12:00:00Z');
    assert.ok(storage.objetos.has(v1.paquetes[0].partes[0].archivo), 'el viejo sigue ahí: un teléfono puede estar bajándolo');
    assert.deepEqual(borrados, []);
  }));

test('lo que el catálogo ya no menciona se borra solo después de 7 días', () =>
  conTmp(async (tmp) => {
    const huerfano = 'paquetes/ciudad/montevideo.000000000000.pmtiles';
    const reciente = 'paquetes/ciudad/montevideo.111111111111.pmtiles';
    const storage = bucketFalso({
      previo: { [huerfano]: Buffer.from('x'), [reciente]: Buffer.from('y') },
      fechas: { [huerfano]: '2026-09-20T00:00:00Z', [reciente]: '2026-10-05T00:00:00Z' },
    });
    const { borrados } = await publicarCiudades(opciones(storage, recorteFalso(), tmp));
    assert.deepEqual(borrados, [huerfano]);
    assert.equal(storage.objetos.has(huerfano), false);
    assert.equal(storage.objetos.has(reciente), true);
  }));

test('una ciudad que no entra se parte en dos archivos y el catálogo lo dice', () =>
  conTmp(async (tmp) => {
    const storage = bucketFalso();
    const recorte = recorteFalso({ bytesPorZoom: { 15: 200_000, 14: 90_000 } });
    const { catalogo } = await publicarCiudades(opciones(storage, recorte, tmp));
    const [p] = catalogo.paquetes;
    assert.equal(p.partes.length, 2);
    assert.match(p.partes[0].archivo, /montevideo\.parte1de2\./);
    assert.match(p.partes[1].archivo, /montevideo\.parte2de2\./);
    assert.equal(p.zoom_max, 14);
    assert.ok(p.partes.every((x) => x.tamano_bytes <= 50_000));
    assert.equal(p.tamano_bytes, p.partes[0].tamano_bytes + p.partes[1].tamano_bytes);
    assert.deepEqual(validar(catalogo), []);
  }));

test('si una ciudad no entra de ninguna manera, no se publica nada (ni siquiera el catálogo)', () =>
  conTmp(async (tmp) => {
    const storage = bucketFalso();
    const recorte = recorteFalso({ bytesPorZoom: { 15: 9_000_000, 14: 9_000_000 } });
    await assert.rejects(publicarCiudades(opciones(storage, recorte, tmp)), /No entra/);
    assert.equal(storage.subidas.length, 0);
  }));

test('con --dry-run recorta y mide, pero no escribe en el bucket', () =>
  conTmp(async (tmp) => {
    const storage = bucketFalso();
    const mensajes = [];
    const { catalogo } = await publicarCiudades(opciones(storage, recorteFalso(), tmp, { dryRun: true, log: (m) => mensajes.push(m) }));
    assert.equal(storage.subidas.length, 0);
    assert.equal(catalogo.paquetes.length, 1);
    assert.ok(mensajes.some((m) => m.includes('[dry-run]')));
  }));

test('los otros paquetes del catálogo (por ejemplo, de zona) no se pierden al republicar una ciudad', () =>
  conTmp(async (tmp) => {
    const zona = {
      id: 'zona-z1',
      nivel: 'zona',
      ambito_id: 'z1',
      zoom_min: 0,
      zoom_max: 15,
      tamano_bytes: 5,
      version: 'a'.repeat(64),
      partes: [{ archivo: 'paquetes/zona/z1.aaaaaaaaaaaa.pmtiles', tamano_bytes: 5, sha256: 'a'.repeat(64) }],
      fuente_build: '20261001',
      actualizado_en: '2026-10-01T00:00:00Z',
    };
    const previo = {
      version: 1,
      generado_en: '2026-10-01T00:00:00Z',
      estilo: { url: RUTA_ESTILO, fuente_de_tiles: 'protomaps' },
      paquetes: [zona],
    };
    const storage = bucketFalso({
      previo: {
        [RUTA_CATALOGO]: Buffer.from(JSON.stringify(previo)),
        'paquetes/zona/z1.aaaaaaaaaaaa.pmtiles': Buffer.from('zzzzz'),
      },
    });
    const { catalogo, borrados } = await publicarCiudades(opciones(storage, recorteFalso(), tmp));
    assert.deepEqual(catalogo.paquetes.map((p) => p.id), ['zona-z1', 'ciudad-montevideo']);
    assert.deepEqual(borrados, []);
    assert.ok(storage.objetos.has('paquetes/zona/z1.aaaaaaaaaaaa.pmtiles'));
  }));

test('publica el estilo con sus glyphs y sprites, cada uno con su tipo de contenido', () =>
  conTmp(async () => {
    const storage = bucketFalso();
    const raizAssets = fileURLToPath(new URL('../assets', import.meta.url));
    await publicarEstilo({ storage, estilo: estiloDePrueba(), raizAssets });
    const porRuta = new Map(storage.subidas.map((s) => [s.ruta, s]));

    assert.equal(porRuta.get('estilo/glyphs/NotoSans-Regular/0-255.pbf').contentType, 'application/x-protobuf');
    assert.equal(porRuta.get('estilo/glyphs/OFL.txt').contentType, 'text/plain');
    assert.equal(porRuta.get('estilo/sprites/grayscale.json').contentType, 'application/json');
    assert.equal(porRuta.get('estilo/sprites/grayscale@2x.png').contentType, 'image/png');
    assert.equal(porRuta.get(RUTA_ESTILO).cacheControl, 'public, max-age=60');
    assert.equal(storage.subidas.at(-1).ruta, RUTA_ESTILO, 'el estilo va después de sus glyphs y sprites');
    assert.equal(JSON.parse(storage.objetos.get(RUTA_ESTILO)).name, 'Colportores');
  }));

test('listarArchivos devuelve rutas con barras, ordenadas', async () => {
  const raiz = fileURLToPath(new URL('../assets/sprites', import.meta.url));
  const archivos = await listarArchivos(raiz, 'estilo/sprites');
  assert.deepEqual(
    archivos.map((a) => a.ruta),
    ['estilo/sprites/grayscale.json', 'estilo/sprites/grayscale.png', 'estilo/sprites/grayscale@2x.json', 'estilo/sprites/grayscale@2x.png'],
  );
});
