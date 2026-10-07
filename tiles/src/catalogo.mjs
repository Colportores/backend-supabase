// El catálogo (`catalogo.json`) que vive en el bucket público `mapas`, al lado de los paquetes.
// Lo leen la app (front-colportores-mobile#189) y el panel. Funciones puras. Formato en
// docs/mapas-tiles.md § «El catálogo».

import { createHash } from 'node:crypto';
import { MAX_BYTES } from './politica.mjs';

export const VERSION_CATALOGO = 1;

/**
 * Del más chico al más grande, como `NivelCobertura` de la app. Departamento y Uruguay: #68.
 * `zona` figura por orden, pero **el catálogo no lleva paquetes de zona**: el catálogo es público y el archivo
 * de una zona muestra su rectángulo a quien lo baje (decisión de Cristian del 06/10, «Zona pública»). Cada
 * zona guarda el enlace a su paquete en `public.zona.paquete_mapa` y le llega al colportor por el sync;
 * `validar` rechaza un paquete de nivel `zona`.
 */
export const NIVELES = ['zona', 'ciudad', 'departamento', 'uruguay'];

const SHA256 = /^[0-9a-f]{64}$/;
const FECHA_ISO = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?Z$/;

/** Dónde queda un archivo de un paquete del catálogo. El nombre lleva el SHA-256: nunca se pisa un archivo. */
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
 * Arma la entrada de un paquete del catálogo (hoy, de ciudad: los de zona no van al catálogo, ver NIVELES).
 * `partes`: [{ archivo, tamano_bytes, sha256, bbox }] (bbox de cada parte, opcional).
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
    retirados: [],
  };
}

/**
 * Mezcla lo nuevo con lo ya publicado: el paquete nuevo reemplaza al de su mismo `id`, los
 * `quitar` se sacan y el resto queda como estaba.
 *
 * También anota en `retirados` cada archivo que el catálogo previo referenciaba y el nuevo ya no,
 * con la fecha en que salió (`ahora`): desde ahí corre el período de gracia que le da tiempo a un
 * teléfono con la descarga pausada, o al panel abierto, de terminar con el archivo viejo. Un archivo
 * que ya figuraba como retirado conserva su fecha; uno que vuelve a ser referenciado deja de estarlo.
 */
export function fusionar(previo, nuevos, { quitar = [], ahora, estiloVersion }) {
  const base = previo ?? catalogoVacio(ahora);
  const porId = new Map(base.paquetes.map((p) => [p.id, p]));
  for (const id of quitar) porId.delete(id);
  for (const p of nuevos) porId.set(p.id, p);
  const paquetes = [...porId.values()].sort(
    (a, b) => NIVELES.indexOf(a.nivel) - NIVELES.indexOf(b.nivel) || a.id.localeCompare(b.id),
  );
  const retirados = retiradosDe(previo, { paquetes }, ahora);
  // La versión del estilo es la de lo que hay en el bucket: la que se acaba de subir, o la que ya figuraba.
  const version = estiloVersion ?? base.estilo?.version;
  const estilo = version === undefined ? { ...base.estilo } : { ...base.estilo, version };
  return { ...base, version: VERSION_CATALOGO, generado_en: ahora, estilo, paquetes, retirados };
}

/** Todos los archivos que el catálogo referencia. */
export function archivosDe(catalogo) {
  return new Set(catalogo.paquetes.flatMap((p) => (p.partes ?? []).map((parte) => parte.archivo)));
}

/** [{ archivo, desde }] ordenado: los archivos que `previo` tenía y `nuevo` ya no, más los que ya estaban retirados. */
function retiradosDe(previo, nuevo, ahora) {
  const vigentes = archivosDe(nuevo);
  const desde = new Map();
  for (const r of previo?.retirados ?? []) if (!vigentes.has(r.archivo)) desde.set(r.archivo, r.desde);
  if (previo) {
    for (const archivo of archivosDe(previo)) {
      if (!vigentes.has(archivo) && !desde.has(archivo)) desde.set(archivo, ahora);
    }
  }
  return [...desde]
    .map(([archivo, cuando]) => ({ archivo, desde: cuando }))
    .sort((a, b) => (a.archivo < b.archivo ? -1 : a.archivo > b.archivo ? 1 : 0));
}

/**
 * Saca de `retirados` lo que ya no hace falta recordar: los archivos que se acaban de borrar y los
 * que ya no están en el bucket (`publicados`: [{ ruta, actualizado_en }]).
 */
export function podarRetirados(catalogo, { borrados, publicados }) {
  const hay = new Set(publicados.map((a) => a.ruta));
  const fuera = new Set(borrados);
  return {
    ...catalogo,
    retirados: (catalogo.retirados ?? []).filter((r) => hay.has(r.archivo) && !fuera.has(r.archivo)),
  };
}

/**
 * Lista de errores del catálogo; vacía si está bien.
 * `exigirAmbito: false` solo para un simulacro sin clave, que no puede leer public.ciudad.
 */
export function validar(catalogo, { maxBytes = MAX_BYTES, exigirAmbito = true } = {}) {
  const errores = [];
  const falla = (msg) => errores.push(msg);

  if (catalogo?.version !== VERSION_CATALOGO) falla(`version debe ser ${VERSION_CATALOGO}`);
  if (typeof catalogo?.generado_en !== 'string' || !FECHA_ISO.test(catalogo.generado_en)) {
    falla('generado_en debe ser una fecha ISO 8601 en UTC');
  }
  if (typeof catalogo?.estilo?.url !== 'string') falla('estilo.url falta');
  if (!/^[0-9a-f]{64}$/.test(catalogo?.estilo?.version ?? '')) {
    falla('estilo.version falta o no es un SHA-256 (publicá el estilo: --solo estilo)');
  }
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
    // Privacidad: un paquete de zona publicado en el catálogo público muestra dónde trabaja cada equipo.
    if (p.nivel === 'zona') falla(`${donde}: los paquetes de zona no van en el catálogo público (se enlazan desde public.zona.paquete_mapa)`);
    if (p.ambito_id !== null && typeof p.ambito_id !== 'string') falla(`${donde}: ambito_id`);
    // La app elige su paquete por ambito_id: una ciudad sin él no la encontraría nadie.
    if (exigirAmbito && p.nivel === 'ciudad' && !p.ambito_id) falla(`${donde}: ambito_id falta (el id de public.ciudad)`);
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

  if (catalogo.retirados !== undefined) {
    if (!Array.isArray(catalogo.retirados)) {
      falla('retirados debe ser una lista');
    } else {
      const vigentes = archivosDe(catalogo);
      for (const r of catalogo.retirados) {
        const donde = `retirado ${r?.archivo ?? '(sin archivo)'}`;
        if (typeof r.archivo !== 'string' || r.archivo.startsWith('/') || r.archivo.includes('..')) {
          falla(`${donde}: archivo debe ser una ruta relativa al catálogo`);
        }
        if (typeof r.desde !== 'string' || !FECHA_ISO.test(r.desde)) falla(`${donde}: desde debe ser una fecha ISO 8601 en UTC`);
        if (vigentes.has(r.archivo)) falla(`${donde}: está retirado y a la vez en un paquete`);
      }
    }
  }
  return errores;
}

export const DIAS_DE_GRACIA = 7;

/**
 * Archivos de `publicados` ([{ ruta, actualizado_en }]) que se pueden borrar: los que el catálogo
 * no referencia y ya pasó el período de gracia.
 *
 * El período se cuenta desde que el archivo SALIÓ del catálogo (`catalogo.retirados[].desde`), no
 * desde que se subió: un mapa viejo que estuvo meses vigente tiene que seguir 7 días más después de
 * que lo reemplacen, porque hay teléfonos con la descarga pausada y el panel lo lee por Range.
 * Un archivo que nunca figuró en un catálogo (se subió pero la publicación se cortó, o lo está
 * subiendo otro publicador en paralelo) no tiene esa fecha: se cuenta desde que se subió.
 */
export function obsoletos(publicados, catalogo, { ahora, diasDeGracia = DIAS_DE_GRACIA }) {
  const vigentes = archivosDe(catalogo);
  const retiradoDesde = new Map((catalogo.retirados ?? []).map((r) => [r.archivo, r.desde]));
  const limite = new Date(ahora).getTime() - diasDeGracia * 86_400_000;
  return publicados
    .filter((a) => {
      if (vigentes.has(a.ruta)) return false;
      return new Date(retiradoDesde.get(a.ruta) ?? a.actualizado_en).getTime() < limite;
    })
    .map((a) => a.ruta);
}
