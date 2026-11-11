// Los paquetes de mapa de las ZONAS (backend-supabase#42, etapa 2).
//
// Decisión de Cristian del 06/10, «Zona pública»: los paquetes de zona NO van al catálogo público. El archivo
// de una zona lleva su rectángulo en el encabezado y en los tiles, y cualquiera que lo baje vería dónde trabaja
// cada equipo. Entonces:
//
//   · cada zona guarda el enlace a su paquete en `public.zona.paquete_mapa` (migración 0031), que le llega
//     al colportor con su zona por el sync (y solo a quien ve esa zona: la política de zona);
//   · el archivo vive en el bucket público `mapas`, en `zonas/<32 hex al azar>.pmtiles`: un nombre que no se
//     puede adivinar (128 bits) y que no figura en ningún listado (el bucket no se puede listar sin la clave
//     de servicio). El nombre NO deriva del id de la zona ni de su contenido;
//   · el publicador (esto) es el único que lo escribe, con la clave de servicio, por PostgREST.
//
// Forma de `paquete_mapa` (la documenta la migración 0031):
//   { archivo, tamano_bytes, sha256, zoom_max, region_sha256, actualizado_en, anteriores: [{ archivo, desde }] }
//
// Cuándo se vuelve a cortar una zona: cuando cambia su polígono (`region_sha256`), cuando no tiene paquete o
// cuando el archivo que nombra no está en el bucket. NO cuando Protomaps saca un build nuevo (a diario): como
// con las ciudades, un mapa nuevo solo porque cambió la fecha de la fuente le haría bajar el mapa de nuevo a
// cada teléfono. Para forzarlo: `--regenerar`.
//
// Todo lo que toca el mundo (Storage, PostgREST, el recorte, el disco) llega por parámetro: se prueba sin red
// (tiles/test/zonas.test.mjs).

import { createHash, randomBytes } from 'node:crypto';
import { readFile, writeFile } from 'node:fs/promises';
import { join } from 'node:path';
import { cacheControlDe, tipoDe } from './bucket.mjs';
import { DIAS_DE_GRACIA } from './catalogo.mjs';
import { MAX_BYTES, ZOOM_PISO, ZOOM_TOPE } from './politica.mjs';
import { sha256DeArchivo } from './recorte.mjs';
import { tapar } from './storage.mjs';

export const PREFIJO_ZONAS = 'zonas';

/** Días después del fin de su campaña en que una zona sigue con su mapa (las escrituras tienen 15 días de gracia: 0020). */
export const DIAS_TRAS_FIN_DE_CAMPANIA = 15;

/** Lo único que el publicador borra bajo `zonas/`: un nombre como los que él pone. Nada más. */
export const NOMBRE_DE_PAQUETE = /^zonas\/[0-9a-f]{32}\.pmtiles$/;

const ISO_FECHA = /^\d{4}-\d{2}-\d{2}$/;
const DIA_MS = 86_400_000;

/** Fecha ISO 8601 en UTC, sin milisegundos. */
const ahoraIso = (fecha = new Date()) => fecha.toISOString().replace(/\.\d{3}Z$/, 'Z');

/** El día de hoy en Montevideo (`AAAA-MM-DD`): el de `public.hoy_montevideo()`, no el de la máquina que corre. */
export function hoyEnMontevideo(fecha = new Date()) {
  return new Intl.DateTimeFormat('en-CA', { timeZone: 'America/Montevideo', year: 'numeric', month: '2-digit', day: '2-digit' }).format(fecha);
}

/** `AAAA-MM-DD` menos `dias` días. */
export function restarDias(dia, dias) {
  return new Date(Date.parse(`${dia}T00:00:00Z`) - dias * DIA_MS).toISOString().slice(0, 10);
}

/**
 * ¿Esta zona tiene que tener su mapa? Está viva, y su campaña (y la ciudad de su campaña) también, y la
 * campaña no terminó hace más de DIAS_TRAS_FIN_DE_CAMPANIA días (la campaña sin fecha de fin no termina).
 * `zona.campania_ciudad` viene de PostgREST: `{ deleted_at, campania: { fecha_fin, deleted_at } }`.
 */
export function esActiva(zona, hoy = hoyEnMontevideo()) {
  if (zona.deleted_at) return false;
  const campaniaCiudad = zona.campania_ciudad;
  const campania = campaniaCiudad?.campania;
  if (!campaniaCiudad || campaniaCiudad.deleted_at || !campania || campania.deleted_at) return false;
  if (campania.fecha_fin == null) return true;
  if (!ISO_FECHA.test(campania.fecha_fin)) return false;
  return campania.fecha_fin >= restarDias(hoy, DIAS_TRAS_FIN_DE_CAMPANIA);
}

/** Un nombre de archivo nuevo, al azar (128 bits): no se puede adivinar ni se repite. */
export function nuevoArchivo(bytesAleatorios = randomBytes) {
  return `${PREFIJO_ZONAS}/${bytesAleatorios(16).toString('hex')}.pmtiles`;
}

/**
 * La geometría de la zona y su huella. `poligono_geojson` es un Polygon (a veces un Feature): se recorta por
 * él, no por su rectángulo. La huella (`region_sha256`) es el SHA-256 de la geometría con claves en orden
 * fijo: cambia si y solo si se movió una esquina.
 */
export function regionDe(zona) {
  let geometria = zona.poligono_geojson;
  if (geometria?.type === 'Feature') geometria = geometria.geometry;
  if (!['Polygon', 'MultiPolygon'].includes(geometria?.type) || !Array.isArray(geometria.coordinates)) {
    throw new Error('el polígono de la zona no es un Polygon ni un MultiPolygon');
  }
  const canonica = { type: geometria.type, coordinates: geometria.coordinates };
  return { geometria: canonica, sha256: createHash('sha256').update(JSON.stringify(canonica)).digest('hex') };
}

/** `paquete` sin su archivo vigente, que pasa a `anteriores` con la fecha en que dejó de serlo. */
export function retirarVigente(paquete, ahora) {
  const { archivo, tamano_bytes, sha256, zoom_max, region_sha256, ...resto } = paquete; // eslint-disable-line no-unused-vars
  return { ...resto, anteriores: [...(paquete.anteriores ?? []), { archivo, desde: ahora }], actualizado_en: ahora };
}

/**
 * Saca de `anteriores` lo que ya pasó el período de gracia (los teléfonos con la descarga pausada tienen
 * 7 días para terminarla). Devuelve `{ paquete, borrar }`: el paquete como queda (`null` si no queda nada
 * que recordar) y los archivos a borrar.
 */
export function podarAnteriores(paquete, ahora, diasDeGracia = DIAS_DE_GRACIA) {
  const limite = new Date(ahora).getTime() - diasDeGracia * DIA_MS;
  const todos = paquete?.anteriores ?? [];
  const vencidos = todos.filter((a) => new Date(a.desde).getTime() < limite);
  if (vencidos.length === 0) return { paquete, borrar: [] };
  const restantes = todos.filter((a) => !vencidos.includes(a));
  const nuevo = { ...paquete, anteriores: restantes };
  return { paquete: !nuevo.archivo && restantes.length === 0 ? null : nuevo, borrar: vencidos.map((a) => a.archivo) };
}

/** Todos los archivos que las zonas nombran (el vigente y los anteriores). */
export function archivosEnUso(zonas) {
  const usados = new Set();
  for (const z of zonas) {
    const p = z.paquete_mapa;
    if (p?.archivo) usados.add(p.archivo);
    for (const a of p?.anteriores ?? []) usados.add(a.archivo);
  }
  return usados;
}

const COLUMNAS = 'id,poligono_geojson,paquete_mapa,sync_version,deleted_at,campania_ciudad(deleted_at,campania(fecha_fin,deleted_at))';
const PAGINA = 500;

/**
 * El acceso del publicador a `public.zona` (PostgREST, con la clave de servicio): leer todas las zonas y
 * escribir el `paquete_mapa` de una. La escritura es optimista: solo si la zona sigue en la `sync_version`
 * que se leyó, así que no pisa a un coordinador que la editó mientras se cortaba el mapa.
 */
export function clienteZonas({ url, clave, fetchImpl = fetch }) {
  const base = `${url.replace(/\/+$/, '')}/rest/v1/zona`;
  const cabeceras = { apikey: clave, authorization: `Bearer ${clave}`, accept: 'application/json' };

  async function pedir(destino, opciones, que) {
    let respuesta;
    try {
      respuesta = await fetchImpl(destino, opciones);
    } catch (error) {
      throw new Error(`${que}: no pude conectar (${error.cause?.code ?? error.message})`);
    }
    if (!respuesta.ok) {
      const texto = await respuesta.text().catch(() => '');
      // PostgREST repite la fila que no pudo escribir: trae `paquete_mapa.archivo`, la llave del mapa de la zona.
      throw new Error(`${que} falló: ${respuesta.status} ${tapar(texto.slice(0, 300))}`);
    }
    return respuesta.json();
  }

  return {
    /** Todas las zonas (vivas o no: hace falta ver todas para saber qué archivos siguen en uso). */
    async leer() {
      const zonas = [];
      for (let desde = 0; ; desde += PAGINA) {
        const pagina = await pedir(
          `${base}?select=${COLUMNAS}&order=id.asc&limit=${PAGINA}&offset=${desde}`,
          { headers: cabeceras },
          'Leer public.zona',
        );
        zonas.push(...pagina);
        if (pagina.length < PAGINA) return zonas;
      }
    },

    /** Guarda `paquete` (o null) en la zona si sigue en `version`. Devuelve `{ sync_version }` o `null` si la zona cambió. */
    async guardarPaquete(id, version, paquete) {
      const filas = await pedir(
        `${base}?id=eq.${encodeURIComponent(id)}&sync_version=eq.${encodeURIComponent(version)}&select=sync_version`,
        {
          method: 'PATCH',
          headers: { ...cabeceras, 'content-type': 'application/json', prefer: 'return=representation' },
          body: JSON.stringify({ paquete_mapa: paquete }),
        },
        'Guardar el paquete de la zona',
      );
      return filas.length === 1 ? filas[0] : null;
    },
  };
}

/** Recorta la zona con el zoom más alto que entre en `maxBytes` (15, o 14). Una zona no se parte: si no entra, falla. */
async function recortar({ zona, geometria, extraer, tmp, maxBytes, log }) {
  const region = join(tmp, `zona-${zona.id}.geojson`);
  await writeFile(region, JSON.stringify({ type: 'Feature', properties: {}, geometry: geometria }));
  for (let zoom = ZOOM_TOPE; zoom >= ZOOM_PISO; zoom--) {
    const destino = join(tmp, `zona-${zona.id}-z${zoom}.pmtiles`);
    const bytes = await extraer({ region, zoomMax: zoom, destino });
    log(`zona ${zona.id}: zoom ${zoom} → ${(bytes / 1e6).toFixed(1)} MB`);
    if (bytes <= maxBytes) return { destino, bytes, zoomMax: zoom };
  }
  throw new Error(
    `la zona ${zona.id} no entra en ${maxBytes} bytes ni con zoom máximo ${ZOOM_PISO}: es demasiado grande para un solo archivo. ` +
      'Pedile al coordinador que la achique o la divida en dos zonas; mientras tanto, el colportor usa el mapa de la ciudad.',
  );
}

/**
 * Deja los paquetes de las zonas al día.
 *
 * Por cada zona:
 *   · activa (viva, de una campaña vigente): si su polígono cambió, o no tiene paquete, o el archivo no está
 *     en el bucket, se corta, se sube con un nombre al azar y, **recién después**, se guarda el enlace en la zona
 *     (así el teléfono nunca recibe un enlace a algo que todavía no está). El archivo anterior queda en
 *     `anteriores` con la fecha de hoy;
 *   · inactiva (dada de baja, o su campaña terminó): su archivo vigente pasa a `anteriores`, sin vigente;
 *   · de `anteriores` se sacan los de más de 7 días y se borran.
 * Y los archivos de `zonas/` que ninguna zona nombra, subidos hace más de 7 días, se borran.
 *
 * Una zona que falla no frena a las demás: se anota en `fallas` y la corrida sigue.
 *
 * @param {object} p
 * @param {object} p.storage   clienteStorage(): existe, subir, listar, borrar
 * @param {object} p.repo      clienteZonas(): leer, guardarPaquete
 * @param {(o: {region: string, zoomMax: number, destino: string}) => Promise<number>} p.extraer  devuelve bytes
 * @param {string[]} [p.solo]  ids de zona: solo esas (las demás no se tocan)
 * @param {boolean} [p.regenerar]  volver a cortar aunque el polígono no haya cambiado
 */
export async function publicarZonas({
  storage,
  repo,
  extraer,
  tmp,
  ahora = ahoraIso(),
  hoy = hoyEnMontevideo(new Date(ahora)),
  dryRun = false,
  log = () => {},
  solo = [],
  regenerar = false,
  maxBytes = MAX_BYTES,
  archivoNuevo = nuevoArchivo,
}) {
  const zonas = await repo.leer();
  const resultado = { publicadas: [], sinCambios: [], retiradas: [], conflictos: [], fallas: [], borrados: [] };
  const borrar = [];

  /** Guarda el paquete de la zona (y deja anotado el estado nuevo); false si la zona cambió mientras tanto. */
  async function guardar(zona, paquete) {
    if (dryRun) {
      zona.paquete_mapa = paquete;
      return true;
    }
    const guardada = await repo.guardarPaquete(zona.id, zona.sync_version, paquete);
    if (!guardada) {
      if (!resultado.conflictos.includes(zona.id)) resultado.conflictos.push(zona.id);
      log(`zona ${zona.id}: cambió mientras se publicaba; se reintenta en la próxima corrida`);
      return false;
    }
    zona.sync_version = guardada.sync_version;
    zona.paquete_mapa = paquete;
    return true;
  }

  async function atender(zona) {
    const paquete = zona.paquete_mapa ?? null;

    if (!esActiva(zona, hoy)) {
      if (paquete?.archivo && (await guardar(zona, retirarVigente(paquete, ahora)))) {
        resultado.retiradas.push(zona.id);
        log(`zona ${zona.id}: ya no está activa, su mapa pasa a anteriores (se borra a los ${DIAS_DE_GRACIA} días)`);
      }
      return;
    }

    const { geometria, sha256: region } = regionDe(zona);
    const enBucket = paquete?.archivo ? await storage.existe(paquete.archivo) : false;
    if (paquete?.archivo && !enBucket) log(`zona ${zona.id}: el archivo que nombra no está en el bucket, se vuelve a publicar`);
    if (!regenerar && paquete?.archivo && enBucket && paquete.region_sha256 === region) {
      resultado.sinCambios.push(zona.id);
      log(`zona ${zona.id}: sin cambios`);
      return;
    }

    const cortado = await recortar({ zona, geometria, extraer, tmp, maxBytes, log });
    const sha256 = await sha256DeArchivo(cortado.destino);

    if (paquete?.archivo && enBucket && paquete.sha256 === sha256) {
      // El mismo mapa (por ejemplo, un polígono que se movió dentro de los mismos tiles): no hay archivo
      // nuevo ni versión nueva, solo se anota la región de la que salió.
      if (paquete.region_sha256 !== region) await guardar(zona, { ...paquete, region_sha256: region });
      resultado.sinCambios.push(zona.id);
      log(`zona ${zona.id}: mismo mapa (${sha256.slice(0, 12)})`);
      return;
    }

    const archivo = archivoNuevo();
    if (dryRun) {
      log(`zona ${zona.id}: [dry-run] subiría un paquete nuevo de ${cortado.bytes} bytes`);
    } else {
      await storage.subir(archivo, await readFile(cortado.destino), { contentType: tipoDe(archivo), cacheControl: cacheControlDe(archivo) });
    }
    const anteriores = [...(paquete?.anteriores ?? [])];
    if (paquete?.archivo && enBucket) anteriores.push({ archivo: paquete.archivo, desde: ahora });
    const nuevo = {
      archivo,
      tamano_bytes: cortado.bytes,
      sha256,
      zoom_max: cortado.zoomMax,
      region_sha256: region,
      actualizado_en: ahora,
      anteriores,
    };
    if (await guardar(zona, nuevo)) {
      resultado.publicadas.push(zona.id);
      log(`zona ${zona.id}: publicada (${sha256.slice(0, 12)}, ${cortado.bytes} bytes)`);
    }
  }

  async function podar(zona) {
    const { paquete, borrar: vencidos } = podarAnteriores(zona.paquete_mapa, ahora);
    if (vencidos.length === 0) return;
    // Primero se saca el enlace y después se borra el archivo: si algo falla en el medio queda un archivo sin
    // dueño (lo junta la limpieza de huérfanos), nunca un enlace a algo que ya no está.
    if (await guardar(zona, paquete)) borrar.push(...vencidos);
  }

  for (const zona of zonas) {
    if (solo.length > 0 && !solo.includes(zona.id)) continue;
    try {
      await atender(zona);
      await podar(zona);
    } catch (error) {
      // El mensaje de un error de Storage o de la red puede traer la ruta de un archivo de zona: se tapa.
      const mensaje = tapar(error.message);
      resultado.fallas.push({ id: zona.id, error: mensaje });
      log(`zona ${zona.id}: FALLA — ${mensaje}`);
    }
  }

  // Huérfanos: archivos de zonas/ que ninguna zona nombra y se subieron hace más de 7 días (hay una subida
  // reciente que todavía puede estar esperando su enlace, o la de otro publicador en curso).
  // Una lectura sin zonas no autoriza a borrar nada: ante una base vacía por error, los mapas siguen.
  if (zonas.length > 0) {
    const usados = archivosEnUso(zonas);
    const limite = new Date(ahora).getTime() - DIAS_DE_GRACIA * DIA_MS;
    for (const objeto of await storage.listar(PREFIJO_ZONAS)) {
      if (usados.has(objeto.ruta) || !NOMBRE_DE_PAQUETE.test(objeto.ruta)) continue;
      if (new Date(objeto.actualizado_en).getTime() < limite) borrar.push(objeto.ruta);
    }
  }

  const unicos = [...new Set(borrar)].filter((ruta) => NOMBRE_DE_PAQUETE.test(ruta));
  if (unicos.length > 0) {
    if (dryRun) {
      log(`[dry-run] borraría ${unicos.length} archivos de zonas (más de ${DIAS_DE_GRACIA} días fuera de uso)`);
    } else {
      await storage.borrar(unicos);
      resultado.borrados = unicos;
      log(`borrados ${unicos.length} archivos de zonas (más de ${DIAS_DE_GRACIA} días fuera de uso)`);
    }
  }

  log(
    `zonas: ${resultado.publicadas.length} publicadas, ${resultado.sinCambios.length} sin cambios, ` +
      `${resultado.retiradas.length} retiradas, ${resultado.conflictos.length} en conflicto, ${resultado.fallas.length} con falla`,
  );
  return resultado;
}
