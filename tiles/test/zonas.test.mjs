import assert from 'node:assert/strict';
import { mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { execFile } from 'node:child_process';
import { createServer } from 'node:http';
import { test } from 'node:test';
import { fileURLToPath } from 'node:url';
import { BUCKET } from '../src/bucket.mjs';
import { clienteStorage } from '../src/storage.mjs';
import {
  NOMBRE_DE_PAQUETE,
  archivosEnUso,
  clienteZonas,
  esActiva,
  hoyEnMontevideo,
  nuevoArchivo,
  podarAnteriores,
  publicarZonas,
  regionDe,
  restarDias,
  retirarVigente,
} from '../src/zonas.mjs';

const POLIGONO = {
  type: 'Polygon',
  coordinates: [
    [
      [-56.2, -34.9],
      [-56.1, -34.9],
      [-56.1, -34.8],
      [-56.2, -34.8],
      [-56.2, -34.9],
    ],
  ],
};
const POLIGONO_MOVIDO = { type: 'Polygon', coordinates: [POLIGONO.coordinates[0].map(([x, y]) => [x + 0.01, y])] };
const AHORA = '2026-10-07T12:00:00Z';
const HOY = '2026-10-07';

const zona = (id, extra = {}) => ({
  id,
  poligono_geojson: POLIGONO,
  paquete_mapa: null,
  sync_version: 10,
  deleted_at: null,
  campania_ciudad: { deleted_at: null, campania: { fecha_fin: null, deleted_at: null } },
  ...extra,
});
const conFin = (fechaFin) => ({ campania_ciudad: { deleted_at: null, campania: { fecha_fin: fechaFin, deleted_at: null } } });

/** Un nombre de archivo de los que pone el publicador, que se puede predecir: 000…001, 000…002, … */
function contador() {
  let n = 0;
  return () => `zonas/${(++n).toString(16).padStart(32, '0')}.pmtiles`;
}
const nombre = (n) => `zonas/${n.toString(16).padStart(32, '0')}.pmtiles`;

/** Un bucket en memoria (la interfaz de clienteStorage) que anota el orden de lo que pasa en `eventos`. */
function bucketFalso({ previo = {}, fechas = {}, eventos = [] } = {}) {
  const objetos = new Map(Object.entries(previo).map(([r, c]) => [r, Buffer.from(c)]));
  return {
    objetos,
    subidas: [],
    borrados: [],
    async subir(ruta, contenido, { contentType, cacheControl }) {
      objetos.set(ruta, Buffer.from(contenido));
      fechas[ruta] = AHORA;
      this.subidas.push({ ruta, contentType, cacheControl });
      eventos.push(`subir ${ruta}`);
    },
    async existe(ruta) {
      return objetos.has(ruta);
    },
    async listar(prefijo) {
      return [...objetos.keys()]
        .filter((r) => r.startsWith(`${prefijo}/`))
        .map((ruta) => ({ ruta, actualizado_en: fechas[ruta] ?? AHORA }));
    },
    async borrar(rutas) {
      for (const r of rutas) objetos.delete(r);
      this.borrados.push(...rutas);
      eventos.push(`borrar ${rutas.join()}`);
    },
  };
}

/** public.zona en memoria: la escritura es optimista, como la de PostgREST (sync_version=eq.N). */
function repoFalso(zonas, { eventos = [] } = {}) {
  return {
    zonas,
    guardados: [],
    async leer() {
      return structuredClone(zonas);
    },
    async guardarPaquete(id, version, paquete) {
      const z = zonas.find((x) => x.id === id);
      if (!z || z.sync_version !== version) return null;
      z.sync_version += 1;
      z.paquete_mapa = structuredClone(paquete);
      this.guardados.push({ id, paquete });
      eventos.push(`guardar ${id}`);
      return { sync_version: z.sync_version };
    },
  };
}

/** Un recorte de mentira: el tamaño depende del zoom; el contenido, de la semilla, el zoom y la región. */
function recorteFalso({ bytesPorZoom = { 15: 10_000, 14: 4_000 }, semilla = 'a' } = {}) {
  const llamadas = [];
  return {
    llamadas,
    extraer: async ({ region, zoomMax, destino }) => {
      const geojson = JSON.parse(await readFile(region, 'utf8'));
      llamadas.push({ zoomMax, geojson });
      const tamano = bytesPorZoom[zoomMax];
      await writeFile(destino, Buffer.alloc(tamano, `${semilla}${zoomMax}${JSON.stringify(geojson.geometry.coordinates)}`));
      return tamano;
    },
  };
}

async function conTmp(fn) {
  const tmp = await mkdtemp(join(tmpdir(), 'zonas-test-'));
  try {
    return await fn(tmp);
  } finally {
    await rm(tmp, { recursive: true, force: true });
  }
}

function correr({ zonas, storage = bucketFalso(), recorte = recorteFalso(), tmp, ...extra }) {
  const eventos = [];
  const repo = extra.repo ?? repoFalso(zonas, { eventos });
  const log = [];
  const promesa = publicarZonas({
    storage,
    repo,
    extraer: recorte.extraer,
    tmp,
    ahora: AHORA,
    hoy: HOY,
    archivoNuevo: contador(),
    log: (m) => log.push(m),
    ...extra,
  });
  return { promesa, repo, storage, recorte, log };
}

// ---------------------------------------------------------------- funciones sueltas

test('el nombre de un paquete de zona es de 128 bits al azar: ni adivinable ni repetido ni derivado de la zona', () => {
  const nombres = new Set(Array.from({ length: 200 }, () => nuevoArchivo()));
  assert.equal(nombres.size, 200);
  for (const n of nombres) assert.match(n, NOMBRE_DE_PAQUETE);
  assert.match(nuevoArchivo(() => Buffer.alloc(16, 0xab)), /^zonas\/abababababababababababababababab\.pmtiles$/);
  assert.equal(NOMBRE_DE_PAQUETE.test('zonas/notas.txt'), false);
  assert.equal(NOMBRE_DE_PAQUETE.test('paquetes/ciudad/montevideo.aaaaaaaaaaaa.pmtiles'), false);
  assert.equal(NOMBRE_DE_PAQUETE.test('zonas/../paquetes/x.pmtiles'), false);
});

test('el día de hoy es el de Montevideo, no el de la máquina que corre', () => {
  // 02:00 UTC es la noche anterior en Montevideo (UTC-3).
  assert.equal(hoyEnMontevideo(new Date('2026-10-07T02:00:00Z')), '2026-10-06');
  assert.equal(hoyEnMontevideo(new Date('2026-10-07T12:00:00Z')), '2026-10-07');
  assert.equal(restarDias('2026-10-07', 15), '2026-09-22');
  assert.equal(restarDias('2026-03-05', 10), '2026-02-23');
});

test('una zona tiene mapa mientras está viva, su campaña también y no terminó hace más de 15 días', () => {
  assert.equal(esActiva(zona('a'), HOY), true, 'campaña sin fecha de fin: no termina');
  assert.equal(esActiva(zona('a', conFin('2026-12-31')), HOY), true);
  assert.equal(esActiva(zona('a', conFin('2026-09-22')), HOY), true, 'terminó hace exactamente 15 días: todavía');
  assert.equal(esActiva(zona('a', conFin('2026-09-21')), HOY), false, 'hace 16 días: ya no');
  assert.equal(esActiva(zona('a', { deleted_at: '2026-10-01T00:00:00Z' }), HOY), false);
  assert.equal(esActiva(zona('a', { campania_ciudad: { deleted_at: '2026-10-01T00:00:00Z', campania: { fecha_fin: null, deleted_at: null } } }), HOY), false);
  assert.equal(esActiva(zona('a', { campania_ciudad: { deleted_at: null, campania: { fecha_fin: null, deleted_at: '2026-10-01T00:00:00Z' } } }), HOY), false);
  assert.equal(esActiva(zona('a', { campania_ciudad: null }), HOY), false, 'sin campaña no hay a quién servirle el mapa');
  assert.equal(esActiva(zona('a', conFin('no es una fecha')), HOY), false, 'ante un dato raro, no se publica');
});

test('la región de una zona es su polígono (Polygon, MultiPolygon o un Feature con uno) y su huella cambia solo si se mueve una esquina', () => {
  const a = regionDe({ poligono_geojson: POLIGONO });
  const comoFeature = regionDe({ poligono_geojson: { type: 'Feature', properties: { nombre: 'x' }, geometry: POLIGONO } });
  const otrosCampos = regionDe({ poligono_geojson: { coordinates: POLIGONO.coordinates, type: 'Polygon', crs: 'ignorado' } });
  assert.deepEqual(a.geometria, POLIGONO);
  assert.equal(comoFeature.sha256, a.sha256);
  assert.equal(otrosCampos.sha256, a.sha256);
  assert.match(a.sha256, /^[0-9a-f]{64}$/);
  assert.notEqual(regionDe({ poligono_geojson: POLIGONO_MOVIDO }).sha256, a.sha256);
  assert.equal(regionDe({ poligono_geojson: { type: 'MultiPolygon', coordinates: [POLIGONO.coordinates] } }).geometria.type, 'MultiPolygon');
  for (const raro of [null, { type: 'Point', coordinates: [0, 0] }, { type: 'Polygon' }, 'texto']) {
    assert.throws(() => regionDe({ poligono_geojson: raro }), /no es un Polygon ni un MultiPolygon/);
  }
});

test('retirar el archivo vigente lo manda a anteriores con la fecha de hoy y deja el resto', () => {
  const paquete = { archivo: nombre(1), tamano_bytes: 5, sha256: 'a'.repeat(64), zoom_max: 15, region_sha256: 'b'.repeat(64), actualizado_en: '2026-10-01T00:00:00Z', anteriores: [{ archivo: nombre(9), desde: '2026-09-30T00:00:00Z' }] };
  assert.deepEqual(retirarVigente(paquete, AHORA), {
    actualizado_en: AHORA,
    anteriores: [
      { archivo: nombre(9), desde: '2026-09-30T00:00:00Z' },
      { archivo: nombre(1), desde: AHORA },
    ],
  });
});

test('de anteriores se sacan los que pasaron 7 días; si no queda nada que recordar, el paquete es null', () => {
  const vigente = { archivo: nombre(1), anteriores: [{ archivo: nombre(2), desde: '2026-09-29T00:00:00Z' }, { archivo: nombre(3), desde: '2026-10-05T00:00:00Z' }] };
  const { paquete, borrar } = podarAnteriores(vigente, AHORA);
  assert.deepEqual(borrar, [nombre(2)]);
  assert.deepEqual(paquete.anteriores, [{ archivo: nombre(3), desde: '2026-10-05T00:00:00Z' }]);
  assert.equal(paquete.archivo, nombre(1));

  const soloViejo = { anteriores: [{ archivo: nombre(2), desde: '2026-09-29T00:00:00Z' }] };
  assert.deepEqual(podarAnteriores(soloViejo, AHORA), { paquete: null, borrar: [nombre(2)] });
  assert.deepEqual(podarAnteriores(null, AHORA), { paquete: null, borrar: [] });
  assert.deepEqual(podarAnteriores(vigente, '2026-10-05T12:00:00Z').borrar, [], 'a los 6 días todavía no');
});

test('los archivos en uso son el vigente y los anteriores de todas las zonas', () => {
  const zonas = [zona('a', { paquete_mapa: { archivo: nombre(1), anteriores: [{ archivo: nombre(2), desde: AHORA }] } }), zona('b'), zona('c', { paquete_mapa: { anteriores: [{ archivo: nombre(3), desde: AHORA }] } })];
  assert.deepEqual([...archivosEnUso(zonas)].sort(), [nombre(1), nombre(2), nombre(3)]);
});

// ---------------------------------------------------------------- publicarZonas

test('publica una zona nueva: corta por su polígono, sube con nombre al azar y recién después guarda el enlace', () =>
  conTmp(async (tmp) => {
    const eventos = [];
    const zonas = [zona('z1')];
    const storage = bucketFalso({ eventos });
    const repo = repoFalso(zonas, { eventos });
    const { promesa, recorte, log } = correr({ zonas, storage, repo, tmp });
    const resultado = await promesa;

    assert.deepEqual(resultado.publicadas, ['z1']);
    assert.deepEqual(eventos, [`subir ${nombre(1)}`, 'guardar z1'], 'primero el archivo, después el enlace: nunca un enlace a algo que no está');
    assert.deepEqual(recorte.llamadas.map((l) => l.zoomMax), [15]);
    assert.deepEqual(recorte.llamadas[0].geojson.geometry, POLIGONO, 'se corta por el polígono, no por su rectángulo');

    assert.equal(storage.subidas[0].cacheControl, 'public, max-age=31536000, immutable');
    assert.equal(storage.subidas[0].contentType, 'application/octet-stream');
    const [guardado] = repo.guardados;
    assert.deepEqual(guardado.paquete, {
      archivo: nombre(1),
      tamano_bytes: 10_000,
      sha256: guardado.paquete.sha256,
      zoom_max: 15,
      region_sha256: regionDe(zonas[0]).sha256,
      actualizado_en: AHORA,
      anteriores: [],
    });
    assert.equal(guardado.paquete.sha256.length, 64);
    assert.equal(storage.objetos.get(nombre(1)).length, 10_000);
    assert.ok(!storage.objetos.has('catalogo.json'), 'el catálogo público no se toca');

    const texto = log.join('\n');
    assert.ok(!texto.includes(nombre(1)) && !texto.includes('zonas/'), `el nombre del archivo es la llave del mapa de la zona: no sale en el log\n${texto}`);
  }));

test('volver a correr sin cambios no sube ni guarda nada', () =>
  conTmp(async (tmp) => {
    const zonas = [zona('z1')];
    const storage = bucketFalso();
    const repo = repoFalso(zonas);
    await correr({ zonas, storage, repo, tmp }).promesa;
    const subidas = storage.subidas.length;
    const guardados = repo.guardados.length;

    const { promesa, recorte } = correr({ zonas, storage, repo, tmp });
    const resultado = await promesa;
    assert.deepEqual(resultado.sinCambios, ['z1']);
    assert.deepEqual(resultado.publicadas, []);
    assert.equal(recorte.llamadas.length, 0, 'ni siquiera vuelve a cortar');
    assert.equal(storage.subidas.length, subidas);
    assert.equal(repo.guardados.length, guardados);
  }));

test('un build nuevo de Protomaps no cambia el mapa de una zona: solo mover su polígono (o --regenerar)', () =>
  conTmp(async (tmp) => {
    const zonas = [zona('z1')];
    const storage = bucketFalso();
    const repo = repoFalso(zonas);
    await correr({ zonas, storage, repo, tmp }).promesa;
    const primero = zonas[0].paquete_mapa;

    // «Otro build»: el recorte devolvería otro contenido, pero ni se llama.
    const otroBuild = recorteFalso({ semilla: 'b' });
    const sinCambios = await correr({ zonas, storage, repo, recorte: otroBuild, tmp, archivoNuevo: contador() }).promesa;
    assert.deepEqual(sinCambios.sinCambios, ['z1']);
    assert.equal(otroBuild.llamadas.length, 0);
    assert.deepEqual(zonas[0].paquete_mapa, primero);

    const regenerada = await correr({ zonas, storage, repo, recorte: otroBuild, tmp, regenerar: true, archivoNuevo: () => nombre(2) }).promesa;
    assert.deepEqual(regenerada.publicadas, ['z1']);
    assert.notEqual(zonas[0].paquete_mapa.archivo, primero.archivo);
    assert.deepEqual(zonas[0].paquete_mapa.anteriores, [{ archivo: primero.archivo, desde: AHORA }], 'el viejo sigue 7 días para quien lo está bajando');
    assert.ok(storage.objetos.has(primero.archivo), 'todavía no se borra');
  }));

test('si se mueve el polígono sale un archivo nuevo, y el anterior queda en anteriores y en el bucket', () =>
  conTmp(async (tmp) => {
    const zonas = [zona('z1')];
    const storage = bucketFalso();
    const repo = repoFalso(zonas);
    await correr({ zonas, storage, repo, tmp }).promesa;
    const primero = zonas[0].paquete_mapa;

    zonas[0].poligono_geojson = POLIGONO_MOVIDO;
    const { promesa } = correr({ zonas, storage, repo, tmp, archivoNuevo: () => nombre(2) });
    const resultado = await promesa;
    assert.deepEqual(resultado.publicadas, ['z1']);
    const ahora = zonas[0].paquete_mapa;
    assert.equal(ahora.archivo, nombre(2));
    assert.notEqual(ahora.sha256, primero.sha256);
    assert.equal(ahora.region_sha256, regionDe(zonas[0]).sha256);
    assert.deepEqual(ahora.anteriores, [{ archivo: primero.archivo, desde: AHORA }]);
    assert.ok(storage.objetos.has(primero.archivo) && storage.objetos.has(nombre(2)));
  }));

test('si el polígono cambia pero el mapa sale igual, no hay archivo nuevo: solo se anota la región', () =>
  conTmp(async (tmp) => {
    const zonas = [zona('z1')];
    const storage = bucketFalso();
    const repo = repoFalso(zonas);
    // El recorte ignora el polígono: sale el mismo contenido (un polígono que se movió dentro de los mismos tiles).
    const mismoSiempre = { llamadas: [], extraer: async ({ destino, zoomMax }) => { await writeFile(destino, Buffer.alloc(5_000, `z${zoomMax}`)); return 5_000; } };
    await correr({ zonas, storage, repo, recorte: mismoSiempre, tmp }).promesa;
    const primero = zonas[0].paquete_mapa;
    const subidas = storage.subidas.length;

    zonas[0].poligono_geojson = POLIGONO_MOVIDO;
    const resultado = await correr({ zonas, storage, repo, recorte: mismoSiempre, tmp, archivoNuevo: () => nombre(2) }).promesa;
    assert.deepEqual(resultado.sinCambios, ['z1']);
    assert.equal(storage.subidas.length, subidas, 'no se sube nada');
    assert.equal(zonas[0].paquete_mapa.archivo, primero.archivo);
    assert.equal(zonas[0].paquete_mapa.sha256, primero.sha256);
    assert.equal(zonas[0].paquete_mapa.region_sha256, regionDe(zonas[0]).sha256, 'pero ya sabe de qué región salió');
    assert.equal(zonas[0].paquete_mapa.actualizado_en, primero.actualizado_en, 'la fecha no cambia: nadie ve una actualización');
  }));

test('si el archivo que una zona nombra ya no está en el bucket, se vuelve a publicar', () =>
  conTmp(async (tmp) => {
    const zonas = [zona('z1')];
    const storage = bucketFalso();
    const repo = repoFalso(zonas);
    await correr({ zonas, storage, repo, tmp }).promesa;
    const perdido = zonas[0].paquete_mapa.archivo;
    storage.objetos.delete(perdido);

    const { promesa, log } = correr({ zonas, storage, repo, tmp, archivoNuevo: () => nombre(2) });
    await promesa;
    assert.equal(zonas[0].paquete_mapa.archivo, nombre(2));
    assert.deepEqual(zonas[0].paquete_mapa.anteriores, [], 'lo que no está no se guarda como anterior');
    assert.ok(storage.objetos.has(nombre(2)));
    assert.ok(log.some((m) => m.includes('no está en el bucket')));
  }));

test('prueba con zoom 15 y, si no entra en el tope, con 14; si tampoco, esa zona falla y las demás siguen', () =>
  conTmp(async (tmp) => {
    const zonas = [zona('z1'), zona('z2')];
    const recorte = { llamadas: [] };
    // La región que se le pasa al recorte es un archivo por zona (zona-<id>.geojson): de ahí se deduce de cuál es.
    const extraerPorArchivo = async ({ region, zoomMax, destino }) => {
      const id = region.includes('zona-z1') ? 'z1' : 'z2';
      recorte.llamadas.push(`${id}:${zoomMax}`);
      const tamano = { 'z1:15': 60_000, 'z1:14': 20_000, 'z2:15': 90_000, 'z2:14': 80_000 }[`${id}:${zoomMax}`];
      await writeFile(destino, Buffer.alloc(tamano, id));
      return tamano;
    };
    const { promesa, repo } = correr({ zonas, tmp, recorte: { extraer: extraerPorArchivo }, maxBytes: 50_000 });
    const resultado = await promesa;
    assert.deepEqual(recorte.llamadas, ['z1:15', 'z1:14', 'z2:15', 'z2:14']);
    assert.deepEqual(resultado.publicadas, ['z1']);
    assert.equal(zonas[0].paquete_mapa.zoom_max, 14);
    assert.equal(resultado.fallas.length, 1);
    assert.equal(resultado.fallas[0].id, 'z2');
    assert.match(
      resultado.fallas[0].error,
      /la zona z2 no entra en 50000 bytes ni con zoom máximo 14: es demasiado grande para un solo archivo\. Pedile al coordinador que la achique o la divida en dos zonas; mientras tanto, el colportor usa el mapa de la ciudad/,
    );
    assert.equal(zonas[1].paquete_mapa, null, 'la zona que falló no queda con un enlace roto');
    assert.equal(repo.guardados.length, 1);
  }));

test('una zona con el polígono roto falla sola y no frena a las otras', () =>
  conTmp(async (tmp) => {
    const zonas = [zona('z1', { poligono_geojson: { type: 'Point', coordinates: [0, 0] } }), zona('z2')];
    const resultado = await correr({ zonas, tmp }).promesa;
    assert.deepEqual(resultado.publicadas, ['z2']);
    assert.equal(resultado.fallas[0].id, 'z1');
    assert.match(resultado.fallas[0].error, /Polygon/);
  }));

test('una zona dada de baja, o de una campaña que terminó hace más de 15 días, deja de tener mapa: el archivo pasa a anteriores', () =>
  conTmp(async (tmp) => {
    const zonas = [zona('z1'), zona('z2'), zona('z3', conFin('2026-12-31'))];
    const storage = bucketFalso();
    const repo = repoFalso(zonas);
    await correr({ zonas, storage, repo, tmp, archivoNuevo: contador() }).promesa;
    const archivos = zonas.map((z) => z.paquete_mapa.archivo);

    zonas[0].deleted_at = '2026-10-06T00:00:00Z';
    zonas[1].campania_ciudad.campania.fecha_fin = '2026-09-01';
    const resultado = await correr({ zonas, storage, repo, tmp }).promesa;
    assert.deepEqual(resultado.retiradas, ['z1', 'z2']);
    assert.deepEqual(resultado.sinCambios, ['z3']);
    for (const i of [0, 1]) {
      assert.equal(zonas[i].paquete_mapa.archivo, undefined, 'ya no hay archivo vigente');
      assert.deepEqual(zonas[i].paquete_mapa.anteriores, [{ archivo: archivos[i], desde: AHORA }]);
      assert.ok(storage.objetos.has(archivos[i]), 'el archivo sigue 7 días para quien lo está bajando');
    }
    assert.equal(zonas[2].paquete_mapa.archivo, archivos[2]);

    // Y una zona inactiva que nunca tuvo mapa no se toca ni se corta.
    const vacias = [zona('z9', { deleted_at: AHORA })];
    const recorte = recorteFalso();
    await correr({ zonas: vacias, storage: bucketFalso(), recorte, tmp }).promesa;
    assert.equal(recorte.llamadas.length, 0);
  }));

test('si la zona cambió mientras se cortaba su mapa, no se pisa: queda en conflicto para la próxima corrida', () =>
  conTmp(async (tmp) => {
    const zonas = [zona('z1')];
    const storage = bucketFalso();
    const repo = repoFalso(zonas);
    const extraerYEditar = async (o) => {
      const bytes = await recorteFalso().extraer(o);
      zonas[0].sync_version += 1; // un coordinador editó la zona en el medio
      return bytes;
    };
    const { promesa, log } = correr({ zonas, storage, repo, tmp, recorte: { extraer: extraerYEditar } });
    const resultado = await promesa;
    assert.deepEqual(resultado.conflictos, ['z1']);
    assert.deepEqual(resultado.publicadas, []);
    assert.deepEqual(resultado.fallas, []);
    assert.equal(zonas[0].paquete_mapa, null, 'no se guardó nada');
    assert.ok(log.some((m) => m.includes('cambió mientras se publicaba')));

    // La próxima corrida lo logra (y el archivo huérfano de esta lo junta la limpieza a los 7 días).
    const siguiente = await correr({ zonas, storage, repo, tmp, archivoNuevo: () => nombre(2) }).promesa;
    assert.deepEqual(siguiente.publicadas, ['z1']);
  }));

// El cliente de Storage de verdad sobre un fetch de mentira: lo que sale por el log y por `fallas` es lo que de verdad dice.
function storageDeMentira(responder) {
  const llamadas = [];
  const fetchFn = async (url, opciones = {}) => {
    const llamada = { url: String(url), metodo: opciones.method };
    llamadas.push(llamada);
    return responder(llamada);
  };
  return { llamadas, storage: clienteStorage({ url: 'https://p.supabase.co', clave: 'CLAVE-DE-SERVICIO', fetchFn, esperaMs: 0 }) };
}
const LLAVE_EN_TEXTO = /[0-9a-f]{32}\.pmtiles/i;
const listaVacia = () => new Response('[]', { status: 200 });

test('si Storage se cae, ni el log ni la falla de la zona llevan el nombre del archivo (la llave de su mapa): al preguntar, al subir, o con un cuerpo que lo repite', () =>
  conTmp(async (tmp) => {
    // HEAD del archivo vigente → 503
    const vigente = nombre(1);
    const zonasA = [zona('z1', { paquete_mapa: { archivo: vigente, tamano_bytes: 10_000, sha256: 'a'.repeat(64), zoom_max: 15, region_sha256: regionDe(zona('z1')).sha256, actualizado_en: '2026-10-01T00:00:00Z', anteriores: [] } })];
    const a = storageDeMentira(({ metodo, url }) => (metodo === 'HEAD' ? new Response('', { status: 503 }) : url.includes('/object/list/') ? listaVacia() : new Response('{}', { status: 200 })));
    const resA = await correr({ zonas: zonasA, storage: a.storage, tmp }).promesa;
    assert.equal(resA.fallas.length, 1);
    assert.match(resA.fallas[0].error, /503/);
    assert.ok(a.llamadas.some((l) => l.url.includes(vigente.slice(6))), 'el pedido sí llevó el nombre');

    // POST de la subida → 503, y otra vez con un 413 cuyo cuerpo repite el nombre
    for (const respuestaDeLaSubida of [() => new Response('', { status: 503 }), ({ url }) => new Response(JSON.stringify({ message: `The resource ${url} already exists` }), { status: 413 })]) {
      const log = [];
      const b = storageDeMentira((l) => (l.metodo === 'POST' && l.url.includes('/object/list/') ? listaVacia() : respuestaDeLaSubida(l)));
      const resB = await correr({ zonas: [zona('z2')], storage: b.storage, tmp, archivoNuevo: () => nombre(5), log: (m) => log.push(m) }).promesa;
      assert.equal(resB.fallas.length, 1);
      assert.match(resB.fallas[0].error, /(503|413)/);
      assert.ok(b.llamadas.some((l) => l.url.includes(nombre(5).slice(6))), 'el pedido sí llevó el nombre');
      assert.doesNotMatch(JSON.stringify(resB.fallas), LLAVE_EN_TEXTO);
      assert.doesNotMatch(log.join('\n'), LLAVE_EN_TEXTO, 'el log de la corrida');
    }
    assert.doesNotMatch(JSON.stringify(resA.fallas), LLAVE_EN_TEXTO);

    // Y aunque el error venga de otro lado y lleve el nombre en el mensaje, la zona lo dice tapado.
    const log = [];
    const roto = bucketFalso();
    roto.subir = async (ruta) => {
      throw new Error(`Subir ${ruta} falló: 500 ${ruta}`);
    };
    const resC = await correr({ zonas: [zona('z3')], storage: roto, tmp, archivoNuevo: () => nombre(7), log: (m) => log.push(m) }).promesa;
    assert.equal(resC.fallas.length, 1);
    assert.match(resC.fallas[0].error, /Subir zonas\/<paquete de zona> falló: 500 zonas\/<paquete de zona>/);
    assert.doesNotMatch(`${JSON.stringify(resC.fallas)}${log.join('\n')}`, LLAVE_EN_TEXTO);
  }));

test('el programa entero, con Storage caído, no escribe en la consola el nombre del archivo de la zona (ni en stdout ni en stderr)', async () => {
  const llave = '0123456789abcdef0123456789abcdef';
  const zonaConMapa = zona('z1', {
    paquete_mapa: { archivo: `zonas/${llave}.pmtiles`, tamano_bytes: 1, sha256: 'a'.repeat(64), zoom_max: 15, region_sha256: regionDe(zona('z1')).sha256, actualizado_en: '2026-10-01T00:00:00Z', anteriores: [] },
  });
  const pedidos = [];
  const servidor = createServer((req, res) => {
    pedidos.push(`${req.method} ${req.url}`);
    const responder = (estado, cuerpo = '') => {
      res.writeHead(estado, { 'content-type': 'application/json' });
      res.end(typeof cuerpo === 'string' ? cuerpo : JSON.stringify(cuerpo));
    };
    if (req.method === 'GET' && req.url.startsWith('/storage/v1/bucket/')) return responder(200, { public: BUCKET.public, file_size_limit: BUCKET.file_size_limit, allowed_mime_types: BUCKET.allowed_mime_types });
    if (req.method === 'GET' && req.url.startsWith('/rest/v1/zona')) return responder(200, [zonaConMapa]);
    if (req.method === 'POST' && req.url.startsWith('/storage/v1/object/list/')) return responder(200, []);
    if (req.url.includes(llave)) return responder(503, `el servidor se cayó con ${req.url}`);
    return responder(404, {});
  });
  await new Promise((resolver) => servidor.listen(0, '127.0.0.1', resolver));
  try {
    const cli = fileURLToPath(new URL('../src/cli.mjs', import.meta.url));
    const env = { ...process.env, SUPABASE_URL: `http://127.0.0.1:${servidor.address().port}`, SUPABASE_SERVICE_ROLE_KEY: 'CLAVE-DE-SERVICIO-DE-PRUEBA' };
    const { codigo, salida } = await new Promise((resolver) => {
      execFile(process.execPath, [cli, 'publicar', '--solo', 'zonas'], { env, timeout: 30_000 }, (error, stdout, stderr) => {
        resolver({ codigo: error ? (error.code ?? 1) : 0, salida: `${stdout}\n${stderr}` });
      });
    });
    assert.ok(pedidos.some((p) => p.includes(llave)), `el programa sí le preguntó a Storage por el archivo:\n${pedidos.join('\n')}`);
    assert.equal(codigo, 1, salida);
    assert.match(salida, /zona z1: FALLA — .*503/);
    assert.doesNotMatch(salida, LLAVE_EN_TEXTO);
  } finally {
    servidor.close();
  }
});

test('si Storage no puede decir si el archivo vigente está (429), esa zona no se toca: ni se republica, ni se borra su mapa vigente o los viejos; las demás siguen', () =>
  conTmp(async (tmp) => {
    const vigente = nombre(1);
    const vencido = nombre(2);
    const paquete = {
      archivo: vigente,
      tamano_bytes: 10_000,
      sha256: 'a'.repeat(64),
      zoom_max: 15,
      region_sha256: regionDe(zona('z1')).sha256,
      actualizado_en: '2026-01-01T00:00:00Z',
      anteriores: [{ archivo: vencido, desde: '2026-09-01T00:00:00Z' }],
    };
    const zonas = [zona('z1', { paquete_mapa: structuredClone(paquete) }), zona('z2')];
    const { llamadas, storage } = storageDeMentira(({ metodo, url }) => {
      if (metodo === 'HEAD') return new Response('', { status: 429 });
      // Con más de 7 días de antigüedad los dos: si se los trata de «sin dueño», se borran.
      if (url.includes('/object/list/')) {
        return new Response(JSON.stringify([vigente, vencido].map((r) => ({ id: r, name: r.slice(6), updated_at: '2026-01-01T00:00:00Z' }))), { status: 200 });
      }
      return new Response('{}', { status: 200 });
    });
    const log = [];
    const { promesa, repo } = correr({ zonas, storage, tmp, archivoNuevo: () => nombre(9), log: (m) => log.push(m) });
    const resultado = await promesa;

    assert.deepEqual(resultado.fallas.map((f) => f.id), ['z1'], 'la zona que no se pudo comprobar queda como falla');
    assert.match(resultado.fallas[0].error, /falló: 429/);
    assert.deepEqual(resultado.publicadas, ['z2'], 'la otra zona siguió');
    assert.deepEqual(zonas[0].paquete_mapa, paquete, 'el enlace de la zona que falló quedó como estaba');
    assert.deepEqual(repo.guardados.map((g) => g.id), ['z2']);
    assert.deepEqual(resultado.borrados, [], 'ni el vigente ni el que sale de anteriores se borran: la próxima corrida lo vuelve a mirar');
    assert.ok(!llamadas.some((l) => l.metodo === 'DELETE'), 'ningún borrado llegó a Storage');
    assert.ok(!llamadas.some((l) => l.metodo === 'POST' && l.url.includes(vigente.slice(6))), 'no se volvió a subir el vigente');
    assert.doesNotMatch(log.join('\n'), LLAVE_EN_TEXTO);
  }));

test('si al podar el enlace no se pudo guardar (la zona cambió: 0 filas), los archivos vencidos no se borran; la corrida siguiente los borra', () =>
  conTmp(async (tmp) => {
    const vigente = nombre(1);
    const vencido = nombre(2);
    const reciente = nombre(3);
    const zonas = [
      zona('z1', {
        paquete_mapa: {
          archivo: vigente,
          tamano_bytes: 10_000,
          sha256: 'a'.repeat(64),
          zoom_max: 15,
          region_sha256: regionDe(zona('z1')).sha256,
          actualizado_en: '2026-10-01T00:00:00Z',
          anteriores: [{ archivo: vencido, desde: '2026-09-29T00:00:00Z' }, { archivo: reciente, desde: '2026-10-05T00:00:00Z' }],
        },
      }),
    ];
    const storage = bucketFalso({ previo: { [vigente]: 'v', [vencido]: 'x', [reciente]: 'y' } });
    const conConflicto = repoFalso(zonas);
    conConflicto.guardarPaquete = async () => null; // PATCH condicionado por sync_version: no tocó ninguna fila

    const primera = await correr({ zonas, storage, repo: conConflicto, tmp }).promesa;
    assert.deepEqual(primera.conflictos, ['z1']);
    assert.deepEqual(primera.borrados, []);
    assert.deepEqual(storage.borrados, [], 'no llegó ningún borrado a Storage');
    assert.ok([vigente, vencido, reciente].every((r) => storage.objetos.has(r)), 'los tres archivos siguen');
    assert.equal(zonas[0].paquete_mapa.anteriores.length, 2, 'el enlace sigue recordando al vencido');

    const segunda = await correr({ zonas, storage, tmp }).promesa;
    assert.deepEqual(segunda.borrados, [vencido], 'ahora que el enlace se pudo guardar, se borra');
    assert.ok(storage.objetos.has(vigente) && storage.objetos.has(reciente) && !storage.objetos.has(vencido));
  }));

test('--zona publica solo esa; las demás no se miran', () =>
  conTmp(async (tmp) => {
    const zonas = [zona('z1'), zona('z2')];
    const { promesa, recorte } = correr({ zonas, tmp, solo: ['z2'] });
    const resultado = await promesa;
    assert.deepEqual(resultado.publicadas, ['z2']);
    assert.equal(recorte.llamadas.length, 1);
    assert.equal(zonas[0].paquete_mapa, null);
  }));

test('--dry-run corta pero no sube, ni guarda, ni borra', () =>
  conTmp(async (tmp) => {
    const viejo = nombre(7);
    const zonas = [zona('z1'), zona('z2', { deleted_at: '2026-09-01T00:00:00Z', paquete_mapa: { anteriores: [{ archivo: nombre(8), desde: '2026-09-01T00:00:00Z' }] } })];
    const storage = bucketFalso({ previo: { [viejo]: 'huerfano', [nombre(8)]: 'vencido' }, fechas: { [viejo]: '2026-09-01T00:00:00Z' } });
    const repo = repoFalso(zonas);
    const { promesa, recorte, log } = correr({ zonas, storage, repo, tmp, dryRun: true });
    await promesa;
    assert.equal(recorte.llamadas.length, 1);
    assert.equal(storage.subidas.length, 0);
    assert.equal(storage.borrados.length, 0);
    assert.equal(repo.guardados.length, 0);
    assert.ok(storage.objetos.has(viejo) && storage.objetos.has(nombre(8)));
    assert.ok(log.some((m) => m.includes('[dry-run] subiría')));
    assert.ok(log.some((m) => m.includes('[dry-run] borraría')));
  }));

test('los archivos que salen de anteriores a los 7 días se borran: primero se saca el enlace y después el archivo', () =>
  conTmp(async (tmp) => {
    const eventos = [];
    const vigente = nombre(1);
    const vencido = nombre(2);
    const reciente = nombre(3);
    const zonas = [
      zona('z1', {
        paquete_mapa: {
          archivo: vigente,
          tamano_bytes: 10_000,
          sha256: 'a'.repeat(64),
          zoom_max: 15,
          region_sha256: regionDe({ poligono_geojson: POLIGONO }).sha256,
          actualizado_en: '2026-10-01T00:00:00Z',
          anteriores: [{ archivo: vencido, desde: '2026-09-29T00:00:00Z' }, { archivo: reciente, desde: '2026-10-05T00:00:00Z' }],
        },
      }),
    ];
    const storage = bucketFalso({ previo: { [vigente]: 'v', [vencido]: 'x', [reciente]: 'y' }, eventos });
    const repo = repoFalso(zonas, { eventos });
    const resultado = await correr({ zonas, storage, repo, tmp }).promesa;
    assert.deepEqual(eventos, ['guardar z1', `borrar ${vencido}`]);
    assert.deepEqual(resultado.borrados, [vencido]);
    assert.deepEqual(zonas[0].paquete_mapa.anteriores, [{ archivo: reciente, desde: '2026-10-05T00:00:00Z' }]);
    assert.ok(storage.objetos.has(vigente) && storage.objetos.has(reciente));
  }));

test('limpieza de huérfanos: solo nombres como los del publicador, que ninguna zona nombra y con más de 7 días', () =>
  conTmp(async (tmp) => {
    const enUso = nombre(1);
    const huerfanoViejo = nombre(2);
    const huerfanoReciente = nombre(3);
    const ajenoViejo = 'zonas/LEEME.txt';
    const mayusculas = `zonas/${'ABCDEF0123456789'.repeat(2)}.pmtiles`;
    const dePaquetes = 'paquetes/ciudad/montevideo.aaaaaaaaaaaa.pmtiles';
    const zonas = [
      zona('z1', {
        paquete_mapa: {
          archivo: enUso,
          tamano_bytes: 10_000,
          sha256: 'a'.repeat(64),
          zoom_max: 15,
          region_sha256: regionDe({ poligono_geojson: POLIGONO }).sha256,
          actualizado_en: '2026-09-01T00:00:00Z',
          anteriores: [],
        },
      }),
    ];
    const fechas = { [enUso]: '2026-09-01T00:00:00Z', [huerfanoViejo]: '2026-09-01T00:00:00Z', [huerfanoReciente]: '2026-10-06T00:00:00Z', [ajenoViejo]: '2026-09-01T00:00:00Z', [mayusculas]: '2026-09-01T00:00:00Z', [dePaquetes]: '2026-09-01T00:00:00Z' };
    const previo = Object.fromEntries(Object.keys(fechas).map((r) => [r, 'x']));
    const storage = bucketFalso({ previo, fechas });
    const resultado = await correr({ zonas, storage, tmp }).promesa;
    assert.deepEqual(resultado.borrados, [huerfanoViejo]);
    assert.deepEqual([...storage.objetos.keys()].sort(), [dePaquetes, enUso, huerfanoReciente, mayusculas, ajenoViejo].sort());
  }));

test('si la lectura no devuelve ninguna zona no se borra nada: una base vacía por error no tira los mapas', () =>
  conTmp(async (tmp) => {
    const viejo = nombre(2);
    const storage = bucketFalso({ previo: { [viejo]: 'x' }, fechas: { [viejo]: '2026-01-01T00:00:00Z' } });
    const resultado = await correr({ zonas: [], storage, tmp }).promesa;
    assert.deepEqual(resultado.borrados, []);
    assert.ok(storage.objetos.has(viejo));
  }));

test('un error al leer las zonas detiene la corrida antes de tocar nada', () =>
  conTmp(async (tmp) => {
    const storage = bucketFalso();
    const repo = { leer: async () => { throw new Error('Leer public.zona falló: 500'); }, guardarPaquete: async () => assert.fail('no debería guardar') };
    await assert.rejects(correr({ zonas: [], storage, repo, tmp }).promesa, /Leer public\.zona falló: 500/);
    assert.equal(storage.subidas.length, 0);
  }));

// ---------------------------------------------------------------- clienteZonas (PostgREST)

test('clienteZonas.leer pide las zonas de a 500, en orden, con la clave de servicio, hasta que una página viene corta', async () => {
  const pedidos = [];
  const fetchImpl = async (url, opciones) => {
    const u = new URL(url);
    pedidos.push({ url: u, opciones });
    const offset = Number(u.searchParams.get('offset'));
    const cantidad = offset === 0 ? 500 : 3;
    return new Response(JSON.stringify(Array.from({ length: cantidad }, (_, i) => ({ id: `z${offset + i}` }))), { status: 200 });
  };
  const repo = clienteZonas({ url: 'https://p.supabase.co/', clave: 'CLAVE-DE-SERVICIO', fetchImpl });
  const zonas = await repo.leer();
  assert.equal(zonas.length, 503);
  assert.deepEqual(pedidos.map((p) => p.url.searchParams.get('offset')), ['0', '500']);
  assert.equal(pedidos[0].url.origin + pedidos[0].url.pathname, 'https://p.supabase.co/rest/v1/zona');
  assert.equal(pedidos[0].url.searchParams.get('order'), 'id.asc');
  assert.equal(pedidos[0].url.searchParams.get('limit'), '500');
  for (const c of ['id', 'poligono_geojson', 'paquete_mapa', 'sync_version', 'deleted_at', 'campania_ciudad(']) {
    assert.ok(pedidos[0].url.searchParams.get('select').includes(c), `pide ${c}`);
  }
  assert.equal(pedidos[0].opciones.headers.authorization, 'Bearer CLAVE-DE-SERVICIO');
});

test('clienteZonas.guardarPaquete escribe solo si la zona sigue en la versión leída; devuelve la versión nueva o null', async () => {
  const pedidos = [];
  let respuesta = [{ sync_version: 11 }];
  const fetchImpl = async (url, opciones) => {
    pedidos.push({ url: new URL(url), opciones });
    return new Response(JSON.stringify(respuesta), { status: 200 });
  };
  const repo = clienteZonas({ url: 'https://p.supabase.co', clave: 'CLAVE-DE-SERVICIO', fetchImpl });

  assert.deepEqual(await repo.guardarPaquete('z1', 10, { archivo: nombre(1) }), { sync_version: 11 });
  const [{ url, opciones }] = pedidos;
  assert.equal(opciones.method, 'PATCH');
  assert.equal(url.searchParams.get('id'), 'eq.z1');
  assert.equal(url.searchParams.get('sync_version'), 'eq.10', 'la condición que hace optimista la escritura');
  assert.equal(opciones.headers.prefer, 'return=representation');
  assert.deepEqual(JSON.parse(opciones.body), { paquete_mapa: { archivo: nombre(1) } });

  respuesta = []; // nadie cumplió la condición: la zona cambió
  assert.equal(await repo.guardarPaquete('z1', 10, null), null);
  assert.deepEqual(JSON.parse(pedidos[1].opciones.body), { paquete_mapa: null }, 'null limpia el enlace');
});

test('clienteZonas dice qué falló, con el estado HTTP, y nunca la clave', async () => {
  const rechaza = async () => new Response('permission denied for table zona', { status: 403 });
  const repo = clienteZonas({ url: 'https://p.supabase.co', clave: 'CLAVE-DE-SERVICIO', fetchImpl: rechaza });
  await assert.rejects(repo.leer(), /Leer public\.zona falló: 403 permission denied/);
  await assert.rejects(repo.guardarPaquete('z1', 1, null), /Guardar el paquete de la zona falló: 403/);
  const sinRed = async () => {
    throw Object.assign(new Error('fetch failed'), { cause: { code: 'ECONNREFUSED' } });
  };
  const repoSinRed = clienteZonas({ url: 'https://p.supabase.co', clave: 'CLAVE-DE-SERVICIO', fetchImpl: sinRed });
  await assert.rejects(repoSinRed.leer(), (e) => /ECONNREFUSED/.test(e.message) && !e.message.includes('CLAVE-DE-SERVICIO'));

  // PostgREST repite la fila que no pudo escribir, con el nombre del archivo del mapa de la zona: no sale.
  const repiteLaFila = async () =>
    new Response(JSON.stringify({ message: 'new row violates check constraint', details: `Failing row contains ({"archivo": "${nombre(5)}"})` }), { status: 400 });
  const repoQueRepite = clienteZonas({ url: 'https://p.supabase.co', clave: 'CLAVE-DE-SERVICIO', fetchImpl: repiteLaFila });
  await assert.rejects(repoQueRepite.guardarPaquete('z1', 1, { archivo: nombre(5) }), (e) => /falló: 400 .*check constraint/.test(e.message) && !LLAVE_EN_TEXTO.test(e.message));
});
