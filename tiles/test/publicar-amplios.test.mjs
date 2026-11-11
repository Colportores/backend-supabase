// Departamento y todo Uruguay: el publicador corta con los rectángulos de la lista fija (uruguay.mjs), no con
// los de public.ciudad. Mismo Storage de mentira y mismo recorte de mentira que publicar.test.mjs.
import assert from 'node:assert/strict';
import { mkdtemp, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { test } from 'node:test';
import { validar } from '../src/catalogo.mjs';
import { RUTA_CATALOGO, publicarAmplios, publicarCiudades } from '../src/publicar.mjs';
import { departamentosPublicables, uruguayPublicable } from '../src/uruguay.mjs';

const ESTILO_V = 'e'.repeat(64);
const AHORA = '2026-10-26T12:00:00Z';
const SALTO = { slug: 'salto', ambito_id: 'salto', nombre: 'Salto', bbox: [-58.08, -31.87, -56.01, -30.74] };
const SAN_JOSE = { slug: 'san-jose', ambito_id: 'san jose', nombre: 'San José', bbox: [-57.15, -34.78, -56.34, -33.83] };
const URUGUAY = { slug: 'uruguay', ambito_id: null, nombre: 'Uruguay', bbox: [-58.49, -35.78, -53.07, -30.08] };

function bucketFalso({ previo = {} } = {}) {
  const objetos = new Map(Object.entries(previo));
  const subidas = [];
  return {
    objetos,
    subidas,
    async subir(ruta, contenido) {
      objetos.set(ruta, Buffer.from(contenido));
      subidas.push(ruta);
    },
    async bajarJson(ruta) {
      return objetos.has(ruta) ? JSON.parse(objetos.get(ruta).toString()) : null;
    },
    async existe(ruta) {
      return objetos.has(ruta);
    },
    async listar(prefijo) {
      return [...objetos.keys()].filter((r) => r.startsWith(`${prefijo}/`)).map((ruta) => ({ ruta, actualizado_en: '2026-10-01T00:00:00Z' }));
    },
    async borrar(rutas) {
      for (const r of rutas) objetos.delete(r);
    },
  };
}

function recorteFalso({ bytes = 20_000 } = {}) {
  const llamadas = [];
  return {
    llamadas,
    extraer: async ({ bbox, zoomMax, destino }) => {
      llamadas.push({ bbox, zoomMax });
      await writeFile(destino, Buffer.alloc(bytes, `${zoomMax}${bbox.join()}`));
      return bytes;
    },
  };
}

async function conTmp(fn) {
  const tmp = await mkdtemp(join(tmpdir(), 'amplios-test-'));
  try {
    return await fn(tmp);
  } finally {
    await rm(tmp, { recursive: true, force: true });
  }
}

const conEstilo = () =>
  bucketFalso({ previo: { [RUTA_CATALOGO]: Buffer.from(JSON.stringify({ version: 1, generado_en: '2026-10-07T12:00:00Z', estilo: { url: 'estilo/colportores.json', version: ESTILO_V }, paquetes: [], retirados: [] })) } });

const opciones = (storage, recorte, tmp, extra = {}) => ({
  storage,
  extraer: recorte.extraer,
  tmp,
  build: '20261026',
  ahora: AHORA,
  limites: { maxBytes: 50_000 },
  ...extra,
});

test('cada departamento se corta por su rectángulo de la lista y entra al catálogo con su nombre normalizado de ámbito', () =>
  conTmp(async (tmp) => {
    const storage = conEstilo();
    const recorte = recorteFalso();
    const { catalogo } = await publicarAmplios(opciones(storage, recorte, tmp, { nivel: 'departamento', ambitos: [SALTO, SAN_JOSE] }));

    assert.deepEqual(recorte.llamadas.map((l) => l.bbox), [SALTO.bbox, SAN_JOSE.bbox], 'el corte usa los rectángulos de la lista, no los de la base');
    assert.deepEqual(catalogo.paquetes.map((p) => [p.id, p.nivel, p.ambito_id, p.nombre]), [
      ['departamento-salto', 'departamento', 'salto', 'Salto'],
      ['departamento-san-jose', 'departamento', 'san jose', 'San José'],
    ]);
    assert.deepEqual(catalogo.paquetes[0].bbox, SALTO.bbox);
    assert.equal(catalogo.estilo.version, ESTILO_V, 'conserva el estilo ya publicado');
    assert.deepEqual(validar(catalogo, { maxBytes: 50_000 }), []);

    const rutas = storage.subidas;
    assert.match(rutas[0], /^paquetes\/departamento\/salto\.[0-9a-f]{12}\.pmtiles$/);
    assert.equal(rutas.at(-1), RUTA_CATALOGO, 'el catálogo va último');
    assert.deepEqual(JSON.parse(storage.objetos.get(RUTA_CATALOGO)), catalogo);
  }));

test('todo Uruguay: un solo paquete, sin ambito_id, con el rectángulo del país', () =>
  conTmp(async (tmp) => {
    const storage = conEstilo();
    const recorte = recorteFalso();
    const { catalogo } = await publicarAmplios(opciones(storage, recorte, tmp, { nivel: 'uruguay', ambitos: [URUGUAY] }));
    assert.deepEqual(recorte.llamadas[0].bbox, URUGUAY.bbox);
    const [p] = catalogo.paquetes;
    assert.equal(p.id, 'uruguay-uruguay');
    assert.equal(p.nivel, 'uruguay');
    assert.equal(p.ambito_id, null, 'cubre cualquier lugar');
    assert.match(p.partes[0].archivo, /^paquetes\/uruguay\/uruguay\.[0-9a-f]{12}\.pmtiles$/);
  }));

test('no se mezcla con las ciudades: publicar departamentos conserva las ciudades del catálogo y no borra sus archivos', () =>
  conTmp(async (tmp) => {
    const storage = conEstilo();
    const recorte = recorteFalso();
    const montevideo = { slug: 'montevideo', nombre: 'Montevideo', ciudad_id: '09990000-0000-7000-8003-000000000001', bbox: [-56.433, -34.945, -55.948, -34.701] };
    await publicarCiudades({ ...opciones(storage, recorte, tmp), ciudades: [montevideo], estiloVersion: ESTILO_V });
    await publicarAmplios(opciones(storage, recorte, tmp, { nivel: 'departamento', ambitos: [SALTO] }));
    const catalogo = await storage.bajarJson(RUTA_CATALOGO);
    assert.deepEqual(catalogo.paquetes.map((p) => p.id), ['ciudad-montevideo', 'departamento-salto']);
    assert.ok([...storage.objetos.keys()].some((r) => r.startsWith('paquetes/ciudad/')));
  }));

test('volver a publicar lo mismo no sube nada nuevo', () =>
  conTmp(async (tmp) => {
    const storage = conEstilo();
    await publicarAmplios(opciones(storage, recorteFalso(), tmp, { nivel: 'departamento', ambitos: [SALTO] }));
    const antes = structuredClone(await storage.bajarJson(RUTA_CATALOGO));
    const mensajes = [];
    const subidasAntes = storage.subidas.length;
    await publicarAmplios(opciones(storage, recorteFalso(), tmp, { nivel: 'departamento', ambitos: [SALTO], ahora: '2026-10-27T12:00:00Z', log: (m) => mensajes.push(m) }));
    assert.ok(mensajes.some((m) => m.includes('departamento-salto: sin cambios')));
    assert.deepEqual((await storage.bajarJson(RUTA_CATALOGO)).paquetes, antes.paquetes);
    assert.equal(storage.subidas.length, subidasAntes + 1, 'solo el catálogo');
  }));

test('si el mapa del departamento cambia, el archivo viejo sale del catálogo y se borra a los 7 días', () =>
  conTmp(async (tmp) => {
    const storage = conEstilo();
    await publicarAmplios(opciones(storage, recorteFalso({ bytes: 20_000 }), tmp, { nivel: 'departamento', ambitos: [SALTO] }));
    const viejo = (await storage.bajarJson(RUTA_CATALOGO)).paquetes[0].partes[0].archivo;
    await publicarAmplios(opciones(storage, recorteFalso({ bytes: 21_000 }), tmp, { nivel: 'departamento', ambitos: [SALTO], ahora: '2026-10-27T12:00:00Z' }));
    const catalogo = await storage.bajarJson(RUTA_CATALOGO);
    assert.notEqual(catalogo.paquetes[0].partes[0].archivo, viejo);
    assert.deepEqual(catalogo.retirados.map((r) => r.archivo), [viejo], 'en período de gracia: hay teléfonos con la descarga pausada');
    assert.ok(storage.objetos.has(viejo));
    await publicarAmplios(opciones(storage, recorteFalso({ bytes: 21_000 }), tmp, { nivel: 'departamento', ambitos: [SALTO], ahora: '2026-11-05T12:00:00Z' }));
    assert.ok(!storage.objetos.has(viejo), 'pasados los 7 días, se borra');
  }));

test('con el tope de 50 MB del plan Free un departamento de verdad no entra: falla en voz alta y no sube nada', () =>
  conTmp(async (tmp) => {
    const storage = conEstilo();
    const recorte = recorteFalso({ bytes: 60_000 });
    await assert.rejects(
      publicarAmplios(opciones(storage, recorte, tmp, { nivel: 'departamento', ambitos: [SALTO] })),
      /No entra en 50000 bytes ni partido en dos .* pasar a Pro \(backend-supabase#68\)/,
    );
    assert.equal(storage.subidas.length, 0);
  }));

test('lo que puede impedir publicar se mira antes de subir nada', () =>
  conTmp(async (tmp) => {
    const recorte = recorteFalso();
    const sin = async (extra, mensaje, storage = conEstilo()) => {
      await assert.rejects(publicarAmplios(opciones(storage, recorte, tmp, extra)), mensaje);
      assert.equal(storage.subidas.length, 0);
    };
    await sin({ nivel: 'ciudad', ambitos: [SALTO] }, /no es amplio/);
    await sin({ nivel: 'departamento', ambitos: [{ ...SALTO, ambito_id: null }] }, /Falta el ambito_id de salto/);
    await sin({ nivel: 'uruguay', ambitos: [URUGUAY, { ...URUGUAY, slug: 'otro' }] }, /un solo paquete de todo Uruguay/);
    await sin({ nivel: 'uruguay', ambitos: [{ ...URUGUAY, ambito_id: 'uy' }] }, /no lleva ambito_id/);
    await sin({ nivel: 'departamento', ambitos: [SALTO] }, /no tiene la versión del estilo/, bucketFalso());
    assert.equal(recorte.llamadas.length, 0, 'ni siquiera se recortó');
  }));

test('un simulacro no sube nada y deja el catálogo como estaba', () =>
  conTmp(async (tmp) => {
    const storage = conEstilo();
    const antes = storage.objetos.get(RUTA_CATALOGO).toString();
    const { catalogo } = await publicarAmplios(opciones(storage, recorteFalso(), tmp, { nivel: 'departamento', ambitos: [SALTO], dryRun: true }));
    assert.equal(catalogo.paquetes.length, 1);
    assert.equal(storage.subidas.length, 0);
    assert.equal(storage.objetos.get(RUTA_CATALOGO).toString(), antes);
  }));

test('departamentosPublicables y uruguayPublicable arman justo lo que publicarAmplios espera', () => {
  const catalogo = {
    pais: { nombre: 'Uruguay', bbox: URUGUAY.bbox },
    departamentos: [{ nombre: 'Salto', bbox: SALTO.bbox }, { nombre: 'San José', bbox: SAN_JOSE.bbox }],
  };
  assert.deepEqual(departamentosPublicables(catalogo), [SALTO, SAN_JOSE]);
  assert.deepEqual(uruguayPublicable(catalogo), URUGUAY);
});
