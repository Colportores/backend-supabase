import assert from 'node:assert/strict';
import { test } from 'node:test';
import {
  CANTIDAD_DE_DEPARTAMENTOS,
  armarCatalogo,
  consultaDeLugares,
  departamentosPublicables,
  descargar,
  funcionSql,
  serializar,
  uruguayPublicable,
  validarCatalogo,
} from '../src/uruguay.mjs';

const NOMBRES = [
  'Artigas', 'Canelones', 'Cerro Largo', 'Colonia', 'Durazno', 'Flores', 'Florida', 'Lavalleja', 'Maldonado',
  'Montevideo', 'Paysandú', 'Río Negro', 'Rivera', 'Rocha', 'Salto', 'San José', 'Soriano', 'Tacuarembó', 'Treinta y Tres',
];

const bounds = (oeste, sur, este, norte) => ({ minlon: oeste, minlat: sur, maxlon: este, maxlat: norte });

// Un país y 19 departamentos de mentira, cada uno una franja de longitud.
function departamentosDePrueba() {
  return NOMBRES.map((nombre, i) => ({
    type: 'relation',
    id: 1000 + i,
    tags: { name: nombre, admin_level: '4', 'ISO3166-2': `UY-${i}` },
    bounds: bounds(-58 + i * 0.25, -35, -57.75 + i * 0.25, -31),
  }));
}

const nodo = (id, nombre, place, lat, lon, extra = {}) => ({ type: 'node', id, lat, lon, tags: { name: nombre, place, ...extra } });

function descargadoDePrueba(lugares = {}, limites = []) {
  const departamentos = departamentosDePrueba();
  return {
    pais: { type: 'relation', id: 287072, tags: { name: 'Uruguay', 'ISO3166-1': 'UY' }, bounds: bounds(-58.5, -35.8, -53, -30) },
    departamentos,
    lugaresPorDepartamento: departamentos.map((d) => ({ departamento: d.id, elementos: lugares[d.tags.name] ?? [] })),
    limites,
    datosOsmDe: '2026-10-26T19:44:21Z',
  };
}

const GENERADO = '2026-10-26T20:00:00Z';

test('el catálogo trae los 19 departamentos con su rectángulo y el país, ordenados', () => {
  const c = armarCatalogo(descargadoDePrueba(), { generadoEn: GENERADO });
  assert.equal(c.departamentos.length, CANTIDAD_DE_DEPARTAMENTOS);
  assert.deepEqual(c.departamentos.map((d) => d.nombre), NOMBRES);
  assert.deepEqual(c.pais.bbox, [-58.5, -35.8, -53, -30]);
  assert.equal(c.pais.osm, 'relation/287072');
  assert.equal(c.fuente.atribucion, '© OpenStreetMap contributors');
  assert.equal(c.fuente.licencia, 'ODbL 1.0');
  assert.equal(c.fuente.datos_osm_de, '2026-10-26T19:44:21Z', 'la fecha de los datos de OSM, no la de hoy');
  assert.equal(c.fuente.generado_en, GENERADO);
  assert.deepEqual(validarCatalogo(c), []);
});

test('una ciudad sin límite en OSM queda sin rectángulo: no se inventa uno', () => {
  const c = armarCatalogo(descargadoDePrueba({ Rivera: [nodo(1, 'Tranqueras', 'town', -31.19, -55.76)] }), { generadoEn: GENERADO });
  assert.deepEqual(c.ciudades, [{ nombre: 'Tranqueras', departamento: 'Rivera', tipo: 'town', osm: 'node/1', lat: -31.19, lon: -55.76, bbox: null }]);
});

test('el rectángulo es el del límite de nivel 8 con el mismo nombre que contiene al centro (el más chico)', () => {
  const limites = [
    { type: 'relation', id: 10, tags: { name: 'Tranqueras', admin_level: '8' }, bounds: bounds(-55.8, -31.25, -55.7, -31.15) },
    { type: 'relation', id: 11, tags: { name: 'TRANQUERAS', admin_level: '8' }, bounds: bounds(-56, -31.5, -55.5, -31) },
    { type: 'relation', id: 12, tags: { name: 'Tranqueras', admin_level: '8' }, bounds: bounds(-50, -20, -49, -19) },
    { type: 'relation', id: 13, tags: { name: 'Otro nombre', admin_level: '8' }, bounds: bounds(-55.8, -31.25, -55.7, -31.15) },
  ];
  const c = armarCatalogo(descargadoDePrueba({ Rivera: [nodo(1, 'Tranqueras', 'town', -31.19, -55.76)] }, limites), { generadoEn: GENERADO });
  assert.deepEqual(c.ciudades[0].bbox, [-55.8, -31.25, -55.7, -31.15], 'el más chico que contiene al centro');
  assert.deepEqual(validarCatalogo(c), [], 'y el centro cae adentro, como exige la base');
});

test('un lugar mapeado como área trae su rectángulo y su centro', () => {
  const area = { type: 'relation', id: 5, tags: { name: 'Villa X', place: 'village' }, center: { lat: -31.5, lon: -55.5 }, bounds: bounds(-55.6, -31.6, -55.4, -31.4) };
  const c = armarCatalogo(descargadoDePrueba({ Rivera: [area] }), { generadoEn: GENERADO });
  assert.deepEqual(c.ciudades[0], { nombre: 'Villa X', departamento: 'Rivera', tipo: 'village', osm: 'relation/5', lat: -31.5, lon: -55.5, bbox: [-55.6, -31.6, -55.4, -31.4] });
});

test('solo ciudades, pueblos y villas con nombre; caseríos, barrios y lugares sin nombre quedan afuera', () => {
  const c = armarCatalogo(
    descargadoDePrueba({
      Rivera: [
        nodo(1, 'Rivera', 'city', -30.9, -55.54),
        nodo(2, 'Un caserío', 'hamlet', -31, -55.5),
        nodo(3, 'Un barrio', 'neighbourhood', -31, -55.5),
        { type: 'node', id: 4, lat: -31, lon: -55.5, tags: { place: 'village' } },
        nodo(5, '  Masoller  ', 'village', -31.08, -56),
      ],
    }),
    { generadoEn: GENERADO },
  );
  assert.deepEqual(c.ciudades.map((x) => x.nombre), ['Masoller', 'Rivera'], 'ordenadas por nombre y sin espacios de más');
});

test('dos lugares con el mismo nombre en el mismo departamento son uno: queda el de mayor categoría y población', () => {
  const c = armarCatalogo(
    descargadoDePrueba({
      Salto: [nodo(1, 'San Antonio', 'village', -31, -57, { population: '100' }), nodo(2, 'San Antonio', 'town', -31.1, -57.1, { population: '50' }), nodo(3, 'san antonio', 'town', -31.2, -57.2, { population: '60' })],
    }),
    { generadoEn: GENERADO },
  );
  assert.equal(c.ciudades.length, 1);
  assert.equal(c.ciudades[0].osm, 'node/3');
  assert.equal(c.descartados.length, 2, 'lo descartado queda anotado');
  assert.deepEqual(validarCatalogo(c), []);
});

test('el mismo nombre en dos departamentos son dos ciudades (hay dos «San José»)', () => {
  const c = armarCatalogo(
    descargadoDePrueba({ 'San José': [nodo(1, 'San José de Mayo', 'city', -34.3, -56.7), nodo(9, 'Santa Ana', 'village', -34.2, -56.6)], Colonia: [nodo(2, 'Santa Ana', 'village', -34, -57.5)] }),
    { generadoEn: GENERADO },
  );
  assert.deepEqual(c.ciudades.filter((x) => x.nombre === 'Santa Ana').map((x) => x.departamento), ['Colonia', 'San José']);
});

test('un lugar de la frontera que cae en dos departamentos queda en el primero', () => {
  const frontera = nodo(7, 'Paso', 'village', -33, -56.5);
  const c = armarCatalogo(descargadoDePrueba({ Flores: [frontera], Durazno: [frontera] }), { generadoEn: GENERADO });
  assert.equal(c.ciudades.length, 1);
  assert.equal(c.ciudades[0].departamento, 'Durazno', 'en el orden en que se bajaron (A-Z)');
  assert.match(c.descartados[0].motivo, /ya estaba en otro departamento/);
});

test('el catálogo es determinista: la misma entrada da el mismo texto', () => {
  const lugares = { Rivera: [nodo(2, 'Zeta', 'village', -31, -55.5), nodo(1, 'Alfa', 'village', -31.1, -55.6)] };
  const a = serializar(armarCatalogo(descargadoDePrueba(lugares), { generadoEn: GENERADO }));
  const b = serializar(armarCatalogo(descargadoDePrueba(lugares), { generadoEn: GENERADO }));
  assert.equal(a, b);
  assert.deepEqual(JSON.parse(a), armarCatalogo(descargadoDePrueba(lugares), { generadoEn: GENERADO }));
  assert.ok(a.endsWith('\n'));
});

test('validar rechaza lo que la base rechazaría o lo que haría un catálogo dudoso', () => {
  const bueno = () => armarCatalogo(descargadoDePrueba({ Rivera: [nodo(1, 'Tranqueras', 'town', -31.19, -55.76)] }), { generadoEn: GENERADO });
  const errores = (cambiar) => {
    const c = bueno();
    cambiar(c);
    return validarCatalogo(c).join('\n');
  };
  assert.match(errores((c) => c.departamentos.pop()), /departamentos debe traer los 19/);
  assert.match(errores((c) => { c.fuente.atribucion = ''; }), /fuente\.atribucion falta/);
  assert.match(errores((c) => { c.fuente.datos_osm_de = null; }), /datos_osm_de falta/);
  assert.match(errores((c) => { c.ciudades[0].departamento = 'Atlantida'; }), /el departamento no es uno de los 19/);
  assert.match(errores((c) => { c.ciudades[0].departamento = 'rivera'; }), /tiene que escribirse como en la lista/);
  assert.match(errores((c) => { c.ciudades.push({ ...c.ciudades[0], nombre: 'TRANQUERAS' }); }), /repetida/);
  assert.match(errores((c) => { c.ciudades[0].bbox = [-55, -31, -54, -30]; }), /el centro cae fuera de su rectángulo/);
  assert.match(errores((c) => { c.ciudades[0].bbox = [-54, -31, -55, -30]; }), /bbox inválido/);
  assert.match(errores((c) => { c.ciudades[0].nombre = ' Tranqueras'; }), /nombre inválido/);
  assert.match(errores((c) => { c.pais.iso_code = 'AR'; }), /pais\.iso_code debe ser UY/);
});

test('el publicador corta cada departamento por su rectángulo y Uruguay por el del país', () => {
  const c = armarCatalogo(descargadoDePrueba(), { generadoEn: GENERADO });
  const deptos = departamentosPublicables(c);
  assert.equal(deptos.length, 19);
  const sanJose = deptos.find((d) => d.nombre === 'San José');
  assert.deepEqual(sanJose, { slug: 'san-jose', ambito_id: 'san jose', nombre: 'San José', bbox: c.departamentos.find((d) => d.nombre === 'San José').bbox });
  assert.equal(deptos.find((d) => d.nombre === 'Río Negro').ambito_id, 'rio negro', 'el ámbito es el nombre normalizado: sin tildes ni mayúsculas');
  assert.equal(new Set(deptos.map((d) => d.slug)).size, 19, 'un archivo por departamento');
  assert.deepEqual(uruguayPublicable(c), { slug: 'uruguay', ambito_id: null, nombre: 'Uruguay', bbox: [-58.5, -35.8, -53, -30] });
});

test('la función de la base lleva el catálogo tal cual, entre marcas que el catálogo no puede tener', () => {
  const c = armarCatalogo(descargadoDePrueba({ Rivera: [nodo(1, 'Tranqueras', 'town', -31.19, -55.76)] }), { generadoEn: GENERADO });
  const sql = funcionSql(c);
  assert.match(sql, /^create or replace function public\.catalogo_osm_uruguay\(\)\nreturns jsonb\nlanguage sql\nimmutable\n/);
  const literal = sql.match(/\$catalogo\$([\s\S]*)\$catalogo\$::jsonb/)[1];
  assert.deepEqual(JSON.parse(literal), c);
  c.ciudades[0].nombre = 'Con $catalogo$ adentro';
  assert.throws(() => funcionSql(c), /no puede contener las marcas/);
});

// --- descargar -------------------------------------------------------------------------------------------------

function overpassFalso(respuestas) {
  const pedidos = [];
  return {
    pedidos,
    fetchImpl: async (url, { body, headers }) => {
      const consulta = decodeURIComponent(body.replace(/^data=/, ''));
      pedidos.push({ url, consulta, userAgent: headers['user-agent'] });
      const respuesta = respuestas(consulta, pedidos.length);
      return { ok: respuesta.status === undefined, status: respuesta.status ?? 200, json: async () => respuesta.cuerpo };
    },
  };
}

test('descargar pide el país con sus departamentos, los lugares de cada uno y los límites, de a uno y con user-agent', async () => {
  const departamentos = departamentosDePrueba();
  const falso = overpassFalso((consulta) => {
    if (consulta.includes('"ISO3166-1"="UY"')) {
      return { cuerpo: { osm3s: { timestamp_osm_base: '2026-10-26T19:44:21Z' }, elements: [{ type: 'relation', id: 287072, tags: { name: 'Uruguay', 'ISO3166-1': 'UY' }, bounds: bounds(-58.5, -35.8, -53, -30) }, ...departamentos] } };
    }
    if (consulta.includes('map_to_area')) return { cuerpo: { elements: [] } };
    return { cuerpo: { elements: [] } };
  });
  const esperas = [];
  const d = await descargar({ fetchImpl: falso.fetchImpl, esperar: async (ms) => esperas.push(ms) });
  assert.equal(falso.pedidos.length, 1 + 19 + 1);
  assert.ok(falso.pedidos.every((p) => /colportores-tiles/.test(p.userAgent)), 'Overpass pide que uno se identifique');
  assert.equal(d.datosOsmDe, '2026-10-26T19:44:21Z');
  assert.equal(d.departamentos.length, 19);
  assert.equal(d.lugaresPorDepartamento.length, 19);
  assert.ok(esperas.length >= 20, 'una pausa entre consultas: Overpass es un servicio compartido');
  assert.match(consultaDeLugares(1627812), /rel\(1627812\);\nmap_to_area->\.d;/);
});

test('descargar reintenta ante un 429 y falla en voz alta si no se arregla', async () => {
  let n = 0;
  const falso = overpassFalso(() => (++n === 1 ? { status: 429 } : { cuerpo: { elements: [] } }));
  const esperas = [];
  const mensajes = [];
  await assert.rejects(descargar({ fetchImpl: falso.fetchImpl, esperar: async (ms) => esperas.push(ms), log: (m) => mensajes.push(m) }), /Overpass no devolvió la relación de Uruguay/);
  assert.equal(esperas[0], 5000, 'espera y reintenta');
  assert.match(mensajes[0], /Overpass no pudo \(Overpass respondió 429\); reintento 1\/6 en 5 s/);

  const esperasSiempre = [];
  const siempre = overpassFalso(() => ({ status: 504 }));
  await assert.rejects(descargar({ fetchImpl: siempre.fetchImpl, esperar: async (ms) => esperasSiempre.push(ms) }), /Overpass respondió 504/);
  assert.deepEqual(esperasSiempre, [5000, 10000, 20000, 40000, 60000, 60000], 'espera exponencial con tope de un minuto');
  assert.equal(siempre.pedidos.length, 7, 'siete intentos, con espera creciente');

  const prohibido = overpassFalso(() => ({ status: 406 }));
  await assert.rejects(descargar({ fetchImpl: prohibido.fetchImpl, esperar: async () => {} }), /Overpass respondió 406/);
  assert.equal(prohibido.pedidos.length, 1, 'un 406 no se arregla reintentando');
});
