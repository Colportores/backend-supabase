import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { mkdtemp, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { test } from 'node:test';
import { fileURLToPath } from 'node:url';
import { validar } from '../src/catalogo.mjs';
import { estiloDePrueba } from './ayudas.mjs';
import {
  RUTA_CATALOGO,
  RUTA_ESTILO,
  listarArchivos,
  publicarCatalogoDeEstilo,
  publicarCiudades,
  publicarEstilo,
  serializarEstilo,
  versionDeEstilo,
} from '../src/publicar.mjs';

const AMBITO = '09990000-0000-7000-8003-000000000001';
const ESTILO_V = 'e'.repeat(64);
const MONTEVIDEO = { slug: 'montevideo', nombre: 'Montevideo', ciudad_id: AMBITO, bbox: [-56.433, -34.945, -55.948, -34.701] };
const sha = (buf) => createHash('sha256').update(buf).digest('hex');

/**
 * Un bucket en memoria con la misma interfaz que clienteStorage(), y el orden de lo que se subió.
 * Como el real, anota cuándo se subió cada objeto: con la hora de `storage.reloj`, que el test mueve.
 */
function bucketFalso({ previo = {}, fechas = {} } = {}) {
  const objetos = new Map(Object.entries(previo));
  const subidas = [];
  const storage = {
    objetos,
    subidas,
    reloj: '2026-10-07T11:00:00Z',
    async subir(ruta, contenido, { contentType, cacheControl }) {
      objetos.set(ruta, Buffer.from(contenido));
      fechas[ruta] = storage.reloj;
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
  return storage;
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
  estiloVersion: ESTILO_V,
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
    assert.equal(p.ambito_id, AMBITO, 'el catálogo lleva el id de public.ciudad: la app elige su paquete por él');
    assert.equal(catalogo.estilo.version, ESTILO_V, 'y la versión del estilo, como los paquetes');
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

    const mensajes = [];
    const { catalogo } = await publicarCiudades(
      opciones(storage, recorteFalso(), tmp, { ahora: '2026-10-08T12:00:00Z', log: (m) => mensajes.push(m) }),
    );
    assert.ok(mensajes.some((m) => m.includes('ciudad-montevideo: sin cambios')), 'lo dice: scripts y la prueba contra Storage lo esperan');
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
    assert.deepEqual(v2.retirados, [{ archivo: v1.paquetes[0].partes[0].archivo, desde: '2026-10-08T12:00:00Z' }]);
  }));

test('republicar semanas después no borra en la misma corrida el mapa que acaba de dejar de ser el vigente', () =>
  conTmp(async (tmp) => {
    // HU-SYNC-010: un teléfono con la descarga pausada la retoma con un Range del archivo que bajaba.
    const storage = bucketFalso();
    storage.reloj = '2026-10-07T12:00:00Z';
    const { catalogo: v1 } = await publicarCiudades(opciones(storage, recorteFalso({ semilla: 'a' }), tmp));
    const viejo = v1.paquetes[0].partes[0].archivo;

    // 30 días después sale un build nuevo: el viejo tiene un mes de subido, pero recién ahora deja de ser el vigente.
    const SALIO = '2026-11-06T12:00:00Z';
    storage.reloj = SALIO;
    const { catalogo: v2, borrados } = await publicarCiudades(
      opciones(storage, recorteFalso({ semilla: 'b' }), tmp, { ahora: SALIO, build: '20261106' }),
    );
    assert.notEqual(v2.paquetes[0].partes[0].archivo, viejo);
    assert.deepEqual(borrados, [], 'no se borra en la misma corrida que publica el nuevo');
    assert.ok(storage.objetos.has(viejo), 'el viejo sigue ahí para el teléfono que lo está bajando');
    assert.deepEqual(JSON.parse(storage.objetos.get(RUTA_CATALOGO)).retirados, [{ archivo: viejo, desde: SALIO }]);
    assert.deepEqual(validar(v2), []);

    // Cuatro días después (otra publicación, sin cambios en los mapas): sigue, y su fecha de retiro no se mueve.
    storage.reloj = '2026-11-10T12:00:00Z';
    const r3 = await publicarCiudades(
      opciones(storage, recorteFalso({ semilla: 'b' }), tmp, { ahora: '2026-11-10T12:00:00Z', build: '20261110' }),
    );
    assert.deepEqual(r3.borrados, []);
    assert.ok(storage.objetos.has(viejo));
    assert.deepEqual(r3.catalogo.retirados, [{ archivo: viejo, desde: SALIO }]);

    // Pasados 7 días desde que salió, ahora sí: se borra y el catálogo deja de recordarlo.
    storage.reloj = '2026-11-14T12:00:00Z';
    const r4 = await publicarCiudades(
      opciones(storage, recorteFalso({ semilla: 'b' }), tmp, { ahora: '2026-11-14T12:00:00Z', build: '20261114' }),
    );
    assert.deepEqual(r4.borrados, [viejo]);
    assert.equal(storage.objetos.has(viejo), false);
    assert.ok(storage.objetos.has(v2.paquetes[0].partes[0].archivo), 'el vigente nunca se borra');
    assert.deepEqual(r4.catalogo.retirados, []);
    assert.deepEqual(JSON.parse(storage.objetos.get(RUTA_CATALOGO)).retirados, []);
  }));

test('si el borrado falla, el catálogo ya quedó publicado y la próxima corrida junta lo que quedó', () =>
  conTmp(async (tmp) => {
    const storage = bucketFalso();
    storage.reloj = '2026-10-07T12:00:00Z';
    const { catalogo: v1 } = await publicarCiudades(opciones(storage, recorteFalso({ semilla: 'a' }), tmp));
    const viejo = v1.paquetes[0].partes[0].archivo;

    // Sale el 12/10; el 20/10 ya pasaron sus 7 días y el borrado falla una vez.
    storage.reloj = '2026-10-12T12:00:00Z';
    await publicarCiudades(opciones(storage, recorteFalso({ semilla: 'b' }), tmp, { ahora: '2026-10-12T12:00:00Z' }));
    const borrarOriginal = storage.borrar;
    storage.borrar = async () => {
      throw new Error('Borrar objetos falló: 500');
    };
    storage.reloj = '2026-10-20T12:00:00Z';
    await assert.rejects(
      publicarCiudades(opciones(storage, recorteFalso({ semilla: 'b' }), tmp, { ahora: '2026-10-20T12:00:00Z' })),
      /Borrar objetos falló/,
    );
    assert.ok(storage.objetos.has(viejo), 'no se borró');
    assert.deepEqual(JSON.parse(storage.objetos.get(RUTA_CATALOGO)).retirados, [], 'el catálogo ya no lo recuerda como retirado');

    storage.borrar = borrarOriginal;
    storage.reloj = '2026-10-21T12:00:00Z';
    const { borrados } = await publicarCiudades(opciones(storage, recorteFalso({ semilla: 'b' }), tmp, { ahora: '2026-10-21T12:00:00Z' }));
    assert.deepEqual(borrados, [viejo], 'sin fecha de retiro, se junta por su fecha de subida (ya vieja)');
  }));

test('cambiar el nombre o el ámbito de una ciudad llega al catálogo aunque los mapas no cambien', () =>
  conTmp(async (tmp) => {
    const storage = bucketFalso();
    const { catalogo: v1 } = await publicarCiudades(opciones(storage, recorteFalso(), tmp));
    assert.equal(v1.paquetes[0].ambito_id, AMBITO);
    const cantidad = storage.subidas.length;

    // Se recarga la ciudad en la base (otro id) y se la renombra: ciudades.json y public.ciudad mandan.
    const mensajes = [];
    const { catalogo: v2 } = await publicarCiudades(
      opciones(storage, recorteFalso(), tmp, {
        ciudades: [{ ...MONTEVIDEO, ciudad_id: '09990000-0000-7000-8003-000000000002', nombre: 'Montevideo (capital)' }],
        ahora: '2026-10-08T12:00:00Z',
        build: '20261007',
        log: (m) => mensajes.push(m),
      }),
    );
    const [p] = v2.paquetes;
    assert.equal(p.ambito_id, '09990000-0000-7000-8003-000000000002');
    assert.equal(p.nombre, 'Montevideo (capital)');
    assert.equal(p.version, v1.paquetes[0].version, 'el mapa es el mismo: la app no ve una actualización');
    assert.equal(p.actualizado_en, v1.paquetes[0].actualizado_en);
    assert.equal(p.fuente_build, '20261006', 'el build es el del contenido, que no cambió');
    assert.deepEqual(p.partes, v1.paquetes[0].partes);
    assert.equal(storage.subidas.length, cantidad + 1, 'solo el catálogo');
    assert.ok(mensajes.some((m) => m.includes('datos del catálogo actualizados')));
    assert.ok(!mensajes.some((m) => m.includes('sin cambios')));
    assert.deepEqual(JSON.parse(storage.objetos.get(RUTA_CATALOGO)).paquetes[0].ambito_id, p.ambito_id);
    assert.deepEqual(validar(v2), []);
  }));

test('una ciudad sin ciudad_id (no está en public.ciudad) no se publica: ni un archivo ni el catálogo', () =>
  conTmp(async (tmp) => {
    const storage = bucketFalso();
    const recorte = recorteFalso();
    await assert.rejects(
      publicarCiudades(opciones(storage, recorte, tmp, { ciudades: [{ ...MONTEVIDEO, ciudad_id: undefined }] })),
      /Falta el ciudad_id.*montevideo.*No se subió nada/s,
    );
    assert.equal(storage.subidas.length, 0);
    assert.equal(recorte.llamadas.length, 0, 'ni siquiera recorta');
  }));

test('sin versión del estilo (ni en la corrida ni en el catálogo del bucket) no se publica nada', () =>
  conTmp(async (tmp) => {
    const storage = bucketFalso();
    await assert.rejects(
      publicarCiudades(opciones(storage, recorteFalso(), tmp, { estiloVersion: undefined })),
      /publicá el estilo primero/,
    );
    assert.equal(storage.subidas.length, 0);
  }));

test('publicar solo ciudades conserva la versión del estilo que ya figuraba en el catálogo', () =>
  conTmp(async (tmp) => {
    const storage = bucketFalso();
    await publicarCiudades(opciones(storage, recorteFalso(), tmp));
    const { catalogo } = await publicarCiudades(
      opciones(storage, recorteFalso(), tmp, { estiloVersion: undefined, ahora: '2026-10-08T12:00:00Z' }),
    );
    assert.equal(catalogo.estilo.version, ESTILO_V);
    assert.deepEqual(validar(catalogo), []);
  }));

test('publicar solo el estilo actualiza el catálogo (estilo.version) y deja los paquetes como están', () =>
  conTmp(async (tmp) => {
    const storage = bucketFalso();
    const { catalogo: v1 } = await publicarCiudades(opciones(storage, recorteFalso(), tmp));
    const cantidad = storage.subidas.length;

    const nueva = 'f'.repeat(64);
    const mensajes = [];
    const { catalogo } = await publicarCatalogoDeEstilo({
      storage,
      estiloVersion: nueva,
      ahora: '2026-10-09T12:00:00Z',
      log: (m) => mensajes.push(m),
    });
    assert.equal(catalogo.estilo.version, nueva);
    assert.deepEqual(catalogo.paquetes, v1.paquetes, 'los paquetes no se tocan');
    assert.equal(catalogo.generado_en, '2026-10-09T12:00:00Z');
    assert.equal(storage.subidas.length, cantidad + 1, 'solo se sube el catálogo');
    assert.equal(storage.subidas.at(-1).ruta, RUTA_CATALOGO);
    assert.equal(storage.subidas.at(-1).cacheControl, 'public, max-age=60');
    assert.deepEqual(JSON.parse(storage.objetos.get(RUTA_CATALOGO)), catalogo);
    assert.deepEqual(validar(catalogo), []);
  }));

test('publicar solo el estilo en un bucket sin catálogo crea uno sin paquetes y válido', () =>
  conTmp(async () => {
    const storage = bucketFalso();
    const { catalogo } = await publicarCatalogoDeEstilo({ storage, estiloVersion: ESTILO_V, ahora: AHORA });
    assert.deepEqual(catalogo.paquetes, []);
    assert.equal(catalogo.estilo.version, ESTILO_V);
    assert.deepEqual(validar(catalogo), []);
    assert.equal(storage.subidas.length, 1);
  }));

test('con --dry-run el estilo no escribe el catálogo', () =>
  conTmp(async () => {
    const storage = bucketFalso();
    await publicarCatalogoDeEstilo({ storage, estiloVersion: ESTILO_V, ahora: AHORA, dryRun: true });
    assert.equal(storage.subidas.length, 0);
  }));

test('lo que nunca estuvo en un catálogo se borra pasados 7 días desde que se subió', () =>
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
    const { version } = await publicarEstilo({ storage, estilo: estiloDePrueba(), raizAssets });
    const porRuta = new Map(storage.subidas.map((s) => [s.ruta, s]));

    assert.equal(version, sha(storage.objetos.get(RUTA_ESTILO)), 'la versión es el SHA-256 del estilo subido');
    assert.equal(version, versionDeEstilo(serializarEstilo(estiloDePrueba())), 'y se puede calcular sin subir (simulacro)');

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
