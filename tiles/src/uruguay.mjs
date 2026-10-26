// El catálogo de Uruguay sacado de OpenStreetMap: los 19 departamentos con su rectángulo, el país, y sus
// ciudades, pueblos y villas con su departamento, su centro y su rectángulo cuando OSM trae el límite.
//
// Decisión de Cristian del 23/10, «Área depto» (backend-supabase#68, seguimiento en #139): «Lista fija con el
// publicador», con su nota: «Lista fija, pero todos los departamentos y ciudades de Uruguay que ya se carguen de
// OSM, así los nombres coinciden, no hay malos typos». La lista vive en `datos/uruguay-osm.json`, se arma con
// `node src/cli.mjs catalogo-uruguay` y de ella salen tres cosas:
//
//   · la migración 0109, que carga las ciudades en `public.ciudad` (la misma lista, copiada en la función
//     `public.catalogo_osm_uruguay()`; un test compara las dos);
//   · el publicador de mapas, que corta el paquete de cada departamento y el de todo Uruguay con sus rectángulos;
//   · la validación del departamento en el alta a mano de una ciudad (`public.agregar_ciudad_a_mano()`).
//
// Las funciones de este archivo son puras salvo `descargar` y `leerCatalogo`: la red y el disco llegan por parámetro
// para probarlas sin red (tiles/test/uruguay.test.mjs).

import { readFile } from 'node:fs/promises';
import { normalizar, slugDe } from './ambito.mjs';

export const VERSION_CATALOGO_URUGUAY = 1;
export const URL_OVERPASS = 'https://overpass-api.de/api/interpreter';
export const USER_AGENT = 'colportores-tiles/0.1 (+https://github.com/Colportores/backend-supabase)';

/** OSM: la relación del país. */
export const OSM_URUGUAY = 'relation/287072';

/** Cuántos departamentos tiene Uruguay. */
export const CANTIDAD_DE_DEPARTAMENTOS = 19;

/** Lo que cuenta como «lugar poblado» del catálogo: del más grande al más chico. Caseríos y barrios no. */
export const TIPOS_DE_LUGAR = ['city', 'town', 'village'];

export const ATRIBUCION = {
  nombre: 'OpenStreetMap',
  atribucion: '© OpenStreetMap contributors',
  licencia: 'ODbL 1.0',
  licencia_url: 'https://www.openstreetmap.org/copyright',
  via: 'Overpass API (https://overpass-api.de/api/interpreter)',
};

// ---------------------------------------------------------------------------------------------------------------
// Las consultas a Overpass
// ---------------------------------------------------------------------------------------------------------------

export const consultaDelPaisYSusDepartamentos = () => `[out:json][timeout:120];
(
  rel["boundary"="administrative"]["admin_level"="2"]["ISO3166-1"="UY"];
  rel["boundary"="administrative"]["admin_level"="4"](area:3600287072);
);
out tags bb;`;

/** Los lugares poblados dentro de la relación `relacionId` (un departamento). */
export const consultaDeLugares = (relacionId) => `[out:json][timeout:180];
rel(${relacionId});
map_to_area->.d;
nwr["place"~"^(${TIPOS_DE_LUGAR.join('|')})$"](area.d);
out tags center bb;`;

/** Los límites administrativos de nivel 8 (localidades): de ahí sale el rectángulo de un lugar. */
export const consultaDeLimites = () => `[out:json][timeout:240];
rel["boundary"="administrative"]["admin_level"="8"](area:3600287072);
out tags bb;`;

const redondear = (n) => Math.round(n * 1e6) / 1e6;

/** [oeste, sur, este, norte] a partir del `bounds` de Overpass. */
function bboxDe(bounds) {
  if (!bounds) return null;
  return [bounds.minlon, bounds.minlat, bounds.maxlon, bounds.maxlat].map(redondear);
}

const idOsm = (e) => `${e.type}/${e.id}`;

// ---------------------------------------------------------------------------------------------------------------
// Descargar
// ---------------------------------------------------------------------------------------------------------------

async function consultar({ fetchImpl, url, consulta, esperar, log, intentos = 7 }) {
  let ultimo;
  for (let intento = 1; intento <= intentos; intento++) {
    try {
      const respuesta = await fetchImpl(url, {
        method: 'POST',
        headers: { 'content-type': 'application/x-www-form-urlencoded', 'user-agent': USER_AGENT, accept: '*/*' },
        body: `data=${encodeURIComponent(consulta)}`,
      });
      if (respuesta.ok) return await respuesta.json();
      ultimo = new Error(`Overpass respondió ${respuesta.status}`);
      if (![429, 500, 502, 503, 504].includes(respuesta.status)) break;
    } catch (error) {
      ultimo = new Error(`No pude hablar con Overpass (${error.cause?.code ?? error.message})`);
    }
    if (intento < intentos) {
      log(`Overpass no pudo (${ultimo.message}); reintento ${intento}/${intentos - 1} en ${Math.min(60, 5 * 2 ** (intento - 1))} s`);
      // Backoff exponencial, como pide Overpass cuando está saturado: 5, 10, 20, 40 y 60 s.
      await esperar(Math.min(60_000, 5000 * 2 ** (intento - 1)));
    }
  }
  throw ultimo;
}

/**
 * Baja de Overpass todo lo que hace falta: el país y sus departamentos, los lugares poblados de cada uno y los
 * límites de nivel 8. Las consultas van de a una (Overpass es un servicio compartido) y con una pausa entre ellas.
 */
export async function descargar({ fetchImpl = fetch, url = URL_OVERPASS, esperar = (ms) => new Promise((r) => setTimeout(r, ms)), log = () => {} } = {}) {
  const pedir = async (consulta) => {
    const respuesta = await consultar({ fetchImpl, url, consulta, esperar, log });
    await esperar(1500);
    return respuesta;
  };
  const base = await pedir(consultaDelPaisYSusDepartamentos());
  const elementos = base.elements ?? [];
  const pais = elementos.find((e) => e.tags?.['ISO3166-1'] === 'UY');
  const departamentos = elementos.filter((e) => e.tags?.admin_level === '4');
  if (!pais) throw new Error('Overpass no devolvió la relación de Uruguay');
  if (departamentos.length !== CANTIDAD_DE_DEPARTAMENTOS) {
    throw new Error(`Overpass devolvió ${departamentos.length} departamentos y Uruguay tiene ${CANTIDAD_DE_DEPARTAMENTOS}; no sigo con una lista incompleta`);
  }
  log(`departamentos: ${departamentos.length}`);

  const lugaresPorDepartamento = [];
  for (const departamento of [...departamentos].sort((a, b) => a.tags.name.localeCompare(b.tags.name, 'es'))) {
    const respuesta = await pedir(consultaDeLugares(departamento.id));
    log(`${departamento.tags.name}: ${(respuesta.elements ?? []).length} lugares`);
    lugaresPorDepartamento.push({ departamento: departamento.id, elementos: respuesta.elements ?? [] });
  }
  const limites = (await pedir(consultaDeLimites())).elements ?? [];
  log(`límites de nivel 8: ${limites.length}`);
  return { pais, departamentos, lugaresPorDepartamento, limites, datosOsmDe: base.osm3s?.timestamp_osm_base ?? null };
}

// ---------------------------------------------------------------------------------------------------------------
// Armar el catálogo
// ---------------------------------------------------------------------------------------------------------------

const ordenDeTipo = (tipo) => TIPOS_DE_LUGAR.length - TIPOS_DE_LUGAR.indexOf(tipo);
const poblacion = (e) => Number.parseInt(String(e.tags?.population ?? '').replace(/\D/g, ''), 10) || 0;
const areaDe = (bbox) => (bbox[2] - bbox[0]) * (bbox[3] - bbox[1]);
const dentro = (bbox, lat, lon) => lon >= bbox[0] && lon <= bbox[2] && lat >= bbox[1] && lat <= bbox[3];
const limpiar = (texto) => String(texto ?? '').replace(/\s+/g, ' ').trim();

/**
 * Del resultado de `descargar` al catálogo (el contenido de `datos/uruguay-osm.json`). Pura y determinista: la
 * misma entrada da el mismo catálogo, ordenado, para que un diff muestre solo lo que cambió en OSM.
 *
 * Reglas:
 *   · una ciudad es un lugar `city`, `town` o `village` con nombre, dentro de un departamento;
 *   · el rectángulo es el del límite administrativo de nivel 8 con el mismo nombre normalizado que contiene al
 *     centro (si hay varios, el más chico); un lugar mapeado como área trae el suyo. Sin límite, no hay
 *     rectángulo: no se inventa uno;
 *   · un lugar que cae en dos departamentos (la frontera) queda en el primero; dos del mismo nombre normalizado en
 *     un mismo departamento son uno (queda el de mayor categoría y población). El resto se anota en `descartados`.
 */
export function armarCatalogo(descargado, { generadoEn }) {
  const { pais, departamentos, lugaresPorDepartamento, limites, datosOsmDe } = descargado;
  if (!pais) throw new Error('Overpass no devolvió la relación de Uruguay');

  const nombreDeDepartamento = new Map(departamentos.map((d) => [d.id, limpiar(d.tags.name)]));
  const limitesPorNombre = new Map();
  for (const limite of limites) {
    const bbox = bboxDe(limite.bounds);
    const nombre = normalizar(limpiar(limite.tags?.name));
    if (!bbox || nombre === '') continue;
    if (!limitesPorNombre.has(nombre)) limitesPorNombre.set(nombre, []);
    limitesPorNombre.get(nombre).push(bbox);
  }

  const vistos = new Set();
  const porClave = new Map();
  const descartados = [];
  for (const { departamento, elementos } of lugaresPorDepartamento) {
    const nombreDepartamento = nombreDeDepartamento.get(departamento);
    for (const e of elementos) {
      const nombre = limpiar(e.tags?.name);
      const tipo = e.tags?.place;
      if (nombre === '' || !TIPOS_DE_LUGAR.includes(tipo)) continue;
      const osm = idOsm(e);
      if (vistos.has(osm)) {
        descartados.push({ osm, nombre, motivo: `ya estaba en otro departamento (queda en el primero)` });
        continue;
      }
      vistos.add(osm);
      const lat = e.type === 'node' ? e.lat : e.center?.lat;
      const lon = e.type === 'node' ? e.lon : e.center?.lon;
      if (typeof lat !== 'number' || typeof lon !== 'number') continue;

      let bbox = e.type === 'node' ? null : bboxDe(e.bounds);
      if (!bbox) {
        const candidatos = (limitesPorNombre.get(normalizar(nombre)) ?? []).filter((b) => dentro(b, lat, lon));
        bbox = candidatos.sort((a, b) => areaDe(a) - areaDe(b))[0] ?? null;
      }
      const clave = `${normalizar(nombreDepartamento)}|${normalizar(nombre)}`;
      const lugar = {
        nombre,
        departamento: nombreDepartamento,
        tipo,
        osm,
        lat: redondear(lat),
        lon: redondear(lon),
        bbox,
        _poblacion: poblacion(e),
      };
      const anterior = porClave.get(clave);
      if (anterior) {
        const gana = ordenDeTipo(lugar.tipo) - ordenDeTipo(anterior.tipo) || lugar._poblacion - anterior._poblacion;
        const perdedor = gana > 0 ? anterior : lugar;
        descartados.push({ osm: perdedor.osm, nombre: perdedor.nombre, motivo: `mismo nombre que ${gana > 0 ? lugar.osm : anterior.osm} en ${nombreDepartamento}` });
        if (gana > 0) porClave.set(clave, lugar);
      } else {
        porClave.set(clave, lugar);
      }
    }
  }

  const ciudades = [...porClave.values()]
    .map(({ _poblacion, ...resto }) => resto)
    .sort((a, b) => normalizar(a.departamento).localeCompare(normalizar(b.departamento)) || normalizar(a.nombre).localeCompare(normalizar(b.nombre)) || a.osm.localeCompare(b.osm));

  return {
    version: VERSION_CATALOGO_URUGUAY,
    fuente: { ...ATRIBUCION, datos_osm_de: datosOsmDe, generado_en: generadoEn },
    pais: { nombre: limpiar(pais.tags.name), iso_code: 'UY', osm: idOsm(pais), bbox: bboxDe(pais.bounds) },
    departamentos: departamentos
      .map((d) => ({ nombre: limpiar(d.tags.name), iso_3166_2: d.tags['ISO3166-2'] ?? null, osm: idOsm(d), bbox: bboxDe(d.bounds) }))
      .sort((a, b) => normalizar(a.nombre).localeCompare(normalizar(b.nombre))),
    ciudades,
    descartados: descartados.sort((a, b) => a.osm.localeCompare(b.osm)),
  };
}

// ---------------------------------------------------------------------------------------------------------------
// Validar y leer
// ---------------------------------------------------------------------------------------------------------------

const esBbox = (b) =>
  Array.isArray(b) &&
  b.length === 4 &&
  b.every((n) => typeof n === 'number' && Number.isFinite(n)) &&
  b[0] >= -180 && b[2] <= 180 && b[1] >= -90 && b[3] <= 90 &&
  b[0] < b[2] && b[1] < b[3];

/** Lista de errores del catálogo; vacía si está bien. Lo mismo que la base le exige a una `ciudad`. */
export function validarCatalogo(catalogo) {
  const errores = [];
  const falla = (m) => errores.push(m);
  if (catalogo?.version !== VERSION_CATALOGO_URUGUAY) falla(`version debe ser ${VERSION_CATALOGO_URUGUAY}`);
  const fuente = catalogo?.fuente;
  if (!fuente?.atribucion || !/OpenStreetMap/.test(fuente.atribucion)) falla('fuente.atribucion falta (la de OSM es obligatoria)');
  if (!fuente?.licencia) falla('fuente.licencia falta');
  if (!/^\d{4}-\d{2}-\d{2}T/.test(fuente?.generado_en ?? '')) falla('fuente.generado_en falta (fecha ISO 8601)');
  if (!/^\d{4}-\d{2}-\d{2}T/.test(fuente?.datos_osm_de ?? '')) falla('fuente.datos_osm_de falta (de qué día son los datos de OSM)');

  if (catalogo?.pais?.iso_code !== 'UY') falla('pais.iso_code debe ser UY');
  if (!esBbox(catalogo?.pais?.bbox)) falla('pais.bbox no es un rectángulo [oeste, sur, este, norte]');

  const departamentos = catalogo?.departamentos;
  if (!Array.isArray(departamentos) || departamentos.length !== CANTIDAD_DE_DEPARTAMENTOS) {
    falla(`departamentos debe traer los ${CANTIDAD_DE_DEPARTAMENTOS} de Uruguay (trae ${departamentos?.length ?? 0})`);
  }
  const nombresDeDepartamento = new Set();
  for (const d of departamentos ?? []) {
    const donde = `departamento ${JSON.stringify(d?.nombre)}`;
    const norm = normalizar(d?.nombre ?? '');
    if (norm === '') falla(`${donde}: sin nombre`);
    if (nombresDeDepartamento.has(norm)) falla(`${donde}: repetido`);
    nombresDeDepartamento.add(norm);
    if (!esBbox(d?.bbox)) falla(`${donde}: bbox inválido`);
    if (d?.nombre !== limpiar(d?.nombre) || (d?.nombre ?? '').length > 60) falla(`${donde}: el nombre tiene espacios de más o pasa de 60 caracteres`);
  }

  if (!Array.isArray(catalogo?.ciudades)) {
    falla('ciudades debe ser una lista');
    return errores;
  }
  const claves = new Set();
  for (const c of catalogo.ciudades) {
    const donde = `ciudad ${JSON.stringify(c?.nombre)} (${c?.departamento})`;
    if (typeof c?.nombre !== 'string' || c.nombre !== limpiar(c.nombre) || c.nombre === '') falla(`${donde}: nombre inválido`);
    if (!nombresDeDepartamento.has(normalizar(c?.departamento ?? ''))) falla(`${donde}: el departamento no es uno de los 19`);
    if (!departamentos?.some((d) => d.nombre === c?.departamento)) falla(`${donde}: el departamento tiene que escribirse como en la lista`);
    const clave = `${normalizar(c?.departamento ?? '')}|${normalizar(c?.nombre ?? '')}`;
    if (claves.has(clave)) falla(`${donde}: repetida (mismo nombre en el mismo departamento)`);
    claves.add(clave);
    if (typeof c?.lat !== 'number' || typeof c?.lon !== 'number') falla(`${donde}: sin centro`);
    if (c?.bbox !== null) {
      if (!esBbox(c?.bbox)) falla(`${donde}: bbox inválido`);
      else if (!dentro(c.bbox, c.lat, c.lon)) falla(`${donde}: el centro cae fuera de su rectángulo`);
    }
  }
  return errores;
}

/** Lee y valida `datos/uruguay-osm.json`. */
export async function leerCatalogo(ruta) {
  const catalogo = JSON.parse(await readFile(ruta, 'utf8'));
  const errores = validarCatalogo(catalogo);
  if (errores.length > 0) throw new Error(`${ruta} no es válido:\n  ${errores.join('\n  ')}`);
  return catalogo;
}

/**
 * El JSON como se guarda: una línea por departamento y por ciudad (un diff muestra la ciudad que cambió) y el
 * resto con sangría. Termina en salto de línea.
 */
export function serializar(catalogo) {
  const linea = (o) => JSON.stringify(o);
  const lista = (items) => (items.length === 0 ? '[]' : `[\n${items.map((i) => `    ${linea(i)}`).join(',\n')}\n  ]`);
  return (
    '{\n' +
    `  "version": ${catalogo.version},\n` +
    `  "fuente": ${linea(catalogo.fuente)},\n` +
    `  "pais": ${linea(catalogo.pais)},\n` +
    `  "departamentos": ${lista(catalogo.departamentos)},\n` +
    `  "ciudades": ${lista(catalogo.ciudades)},\n` +
    `  "descartados": ${lista(catalogo.descartados ?? [])}\n` +
    '}\n'
  );
}

// ---------------------------------------------------------------------------------------------------------------
// Lo que usa el publicador
// ---------------------------------------------------------------------------------------------------------------

/**
 * Los paquetes de departamento a publicar: `{ slug, ambito_id, nombre, bbox }`. El `ambito_id` es el nombre
 * normalizado del departamento (decisión de Cristian del 23/10: «el paquete de departamento se elige por el nombre
 * normalizado de su departamento»), el mismo con el que se agrupa en el panel y con el que la app lo compara con el
 * departamento de la ciudad del colportor; el `slug` es el nombre del archivo.
 */
export function departamentosPublicables(catalogo) {
  return catalogo.departamentos.map((d) => ({ slug: slugDe(d.nombre), ambito_id: normalizar(d.nombre), nombre: d.nombre, bbox: d.bbox }));
}

/** El paquete de todo Uruguay: sin `ambito_id` (cubre cualquier lugar). */
export function uruguayPublicable(catalogo) {
  return { slug: 'uruguay', ambito_id: null, nombre: catalogo.pais.nombre, bbox: catalogo.pais.bbox };
}

// ---------------------------------------------------------------------------------------------------------------
// La función de la base
// ---------------------------------------------------------------------------------------------------------------

/**
 * El `create or replace function public.catalogo_osm_uruguay()` con el catálogo adentro, para pegarlo en una
 * migración nueva cuando se actualice la lista. El JSON va tal cual (`serializar`) entre `$catalogo$`.
 */
export function funcionSql(catalogo) {
  const json = serializar(catalogo);
  if (json.includes('$catalogo$') || json.includes('$f$')) throw new Error('El catálogo no puede contener las marcas $catalogo$ ni $f$');
  return `create or replace function public.catalogo_osm_uruguay()
returns jsonb
language sql
immutable
set search_path = ''
as $f$ select $catalogo$${json}$catalogo$::jsonb $f$;
`;
}
