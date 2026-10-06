// El catálogo (`catalogo.json`) que vive en el bucket público `mapas`, al lado de los paquetes.
// Lo leen la app (front-colportores-mobile#189) y el panel. Funciones puras. Formato en
// docs/mapas-tiles.md § «El catálogo».

import { createHash } from 'node:crypto';
import { MAX_BYTES } from './politica.mjs';

export const VERSION_CATALOGO = 1;

/** Del más chico al más grande, como `NivelCobertura` de la app. Departamento y Uruguay: #68. */
export const NIVELES = ['zona', 'ciudad', 'departamento', 'uruguay'];

const SHA256 = /^[0-9a-f]{64}$/;
const FECHA_ISO = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?Z$/;

/** Dónde queda un archivo en el bucket. El nombre lleva el SHA-256: nunca se pisa un archivo. */
export function rutaArchivo({ nivel, clave, parte = 1, total = 1, sha256 }) {
  const sufijo = total > 1 ? `.parte${parte}de${total}` : '';
  return `paquetes/${nivel}/${clave}${sufijo}.${sha256.slice(0, 12)}.pmtiles`;
}

/**
 * Qué cambió: el SHA-256 de la parte única o, si hay varias, el de sus SHA-256 en orden. La app
 * compara este texto para saber si hay una versión nueva (`hayActualizacion`).
 */
export function versionDe(partes) {
  if (partes.length === 1) return partes[0].sha256;
  return createHash('sha256').update(partes.map((p) => p.sha256).join('\n')).digest('hex');
}

/**
 * Arma la entrada de un paquete.
 * `partes`: [{ archivo, tamano_bytes, sha256, bbox }] (bbox de cada parte, opcional).
 * Los paquetes de zona no llevan nombre ni bbox: el catálogo es público y la app ya conoce sus
 * zonas por la réplica local; solo necesita el id.
 */
export function armarPaquete({
  nivel,
  clave,
  ambitoId = null,
  nombre = null,
  bbox = null,
  zoomMin = 0,
  zoomMax,
  partes,
  build,
  ahora,
  regionSha256 = null,
}) {
  const paquete = {
    id: `${nivel}-${clave}`,
    nivel,
    ambito_id: ambitoId,
  };
  if (nombre !== null) paquete.nombre = nombre;
  if (bbox !== null) paquete.bbox = bbox;
  paquete.zoom_min = zoomMin;
  paquete.zoom_max = zoomMax;
  paquete.tamano_bytes = partes.reduce((suma, p) => suma + p.tamano_bytes, 0);
  paquete.version = versionDe(partes);
  paquete.partes = partes;
  paquete.fuente_build = build;
  if (regionSha256 !== null) paquete.region_sha256 = regionSha256;
  paquete.actualizado_en = ahora;
  return paquete;
}

export function catalogoVacio(ahora) {
  return {
    version: VERSION_CATALOGO,
    generado_en: ahora,
    fuente: {
      proveedor: 'Protomaps (datos de OpenStreetMap)',
      atribucion: '© OpenStreetMap contributors',
      licencia: 'ODbL 1.0',
    },
    estilo: {
      url: 'estilo/colportores.json',
      fuente_de_tiles: 'protomaps',
    },
    paquetes: [],
  };
}

/**
 * Mezcla lo nuevo con lo ya publicado: el paquete nuevo reemplaza al de su mismo `id`, los
 * `quitar` se sacan y el resto queda como estaba.
 */
export function fusionar(previo, nuevos, { quitar = [], ahora }) {
  const base = previo ?? catalogoVacio(ahora);
  const porId = new Map(base.paquetes.map((p) => [p.id, p]));
  for (const id of quitar) porId.delete(id);
  for (const p of nuevos) porId.set(p.id, p);
  const paquetes = [...porId.values()].sort(
    (a, b) => NIVELES.indexOf(a.nivel) - NIVELES.indexOf(b.nivel) || a.id.localeCompare(b.id),
  );
  return { ...base, version: VERSION_CATALOGO, generado_en: ahora, paquetes };
}

/** Todos los archivos que el catálogo referencia. */
export function archivosDe(catalogo) {
  return new Set(catalogo.paquetes.flatMap((p) => p.partes.map((parte) => parte.archivo)));
}

/** Lista de errores del catálogo; vacía si está bien. */
export function validar(catalogo, { maxBytes = MAX_BYTES } = {}) {
  const errores = [];
  const falla = (msg) => errores.push(msg);

  if (catalogo?.version !== VERSION_CATALOGO) falla(`version debe ser ${VERSION_CATALOGO}`);
  if (typeof catalogo?.generado_en !== 'string' || !FECHA_ISO.test(catalogo.generado_en)) {
    falla('generado_en debe ser una fecha ISO 8601 en UTC');
  }
  if (typeof catalogo?.estilo?.url !== 'string') falla('estilo.url falta');
  if (!Array.isArray(catalogo?.paquetes)) {
    falla('paquetes debe ser una lista');
    return errores;
  }

  const ids = new Set();
  for (const p of catalogo.paquetes) {
    const donde = `paquete ${p?.id ?? '(sin id)'}`;
    if (typeof p.id !== 'string' || p.id === '') falla(`${donde}: id falta`);
    if (ids.has(p.id)) falla(`${donde}: id repetido`);
    ids.add(p.id);
    if (!NIVELES.includes(p.nivel)) falla(`${donde}: nivel inválido (${p.nivel})`);
    if (p.ambito_id !== null && typeof p.ambito_id !== 'string') falla(`${donde}: ambito_id`);
    if (!Array.isArray(p.partes) || p.partes.length < 1) {
      falla(`${donde}: sin partes`);
      continue;
    }
    let suma = 0;
    for (const parte of p.partes) {
      if (typeof parte.archivo !== 'string' || parte.archivo.startsWith('/') || parte.archivo.includes('..')) {
        falla(`${donde}: archivo debe ser una ruta relativa al catálogo`);
      }
      if (!Number.isInteger(parte.tamano_bytes) || parte.tamano_bytes <= 0) {
        falla(`${donde}: tamano_bytes inválido`);
      } else if (parte.tamano_bytes > maxBytes) {
        falla(`${donde}: una parte pesa ${parte.tamano_bytes} bytes y el tope es ${maxBytes}`);
      } else {
        suma += parte.tamano_bytes;
      }
      if (!SHA256.test(parte.sha256 ?? '')) falla(`${donde}: sha256 inválido`);
    }
    if (p.tamano_bytes !== suma) falla(`${donde}: tamano_bytes no es la suma de sus partes`);
    if (p.version !== versionDe(p.partes)) falla(`${donde}: version no coincide con sus partes`);
  }
  return errores;
}

/** Archivos de `publicados` que el catálogo ya no referencia: candidatos a borrar. */
export function obsoletos(publicados, catalogo, { ahora, diasDeGracia = 7 }) {
  const vigentes = archivosDe(catalogo);
  const limite = new Date(ahora).getTime() - diasDeGracia * 86_400_000;
  return publicados
    .filter((a) => !vigentes.has(a.ruta) && new Date(a.actualizado_en).getTime() < limite)
    .map((a) => a.ruta);
}
