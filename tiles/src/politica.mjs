// Política de tamaño de un paquete: hasta 50 MB (plan Free de Supabase, decisión de Cristian
// del 06/10, backend-supabase#42). Funciones puras: no tocan disco ni red.
//
//   1. Se recorta con el zoom máximo nativo de los tiles de Protomaps (15).
//   2. Si pasa del tope, se baja el zoom máximo de a uno, hasta el piso.
//   3. Si no entra ni en el piso, se parte la ciudad en dos archivos (mitad más larga) y se busca
//      el zoom más alto en el que las dos mitades entran.
//   4. Si ni partida entra, se falla en voz alta: tres archivos no es lo que se decidió.

/** 50 MB decimales: queda por debajo de los 50 MiB (52 428 800 bytes) que acepta el plan Free. */
export const MAX_BYTES = 50_000_000;

/** El máximo zoom con datos de los tiles de Protomaps (más allá, el cliente sobreescala). */
export const ZOOM_TOPE = 15;

/** Por debajo de este zoom máximo las calles pierden el detalle que el colportor necesita. */
export const ZOOM_PISO = 14;

/**
 * Parte un bbox [oeste, sur, este, norte] en dos por el lado más largo (en metros, no en grados:
 * un grado de longitud mide menos que uno de latitud lejos del ecuador).
 */
export function partirBbox([oeste, sur, este, norte]) {
  const latMedia = ((sur + norte) / 2) * (Math.PI / 180);
  const ancho = (este - oeste) * Math.cos(latMedia);
  const alto = norte - sur;
  if (ancho >= alto) {
    const medio = redondear((oeste + este) / 2);
    return [
      [oeste, sur, medio, norte],
      [medio, sur, este, norte],
    ];
  }
  const medio = redondear((sur + norte) / 2);
  return [
    [oeste, sur, este, medio],
    [oeste, medio, este, norte],
  ];
}

function redondear(n) {
  return Math.round(n * 1e6) / 1e6;
}

/**
 * Decide cómo recortar `bbox` para que cada archivo entre en `maxBytes`.
 *
 * `medir(bbox, zoomMax)` recorta de verdad (o estima) y devuelve el tamaño en bytes. Se llama lo
 * mínimo necesario. Devuelve `{ partes: [{ bbox, zoom_max, bytes }] }` con una o dos partes.
 * Todas las partes llevan el mismo zoom máximo, para que el mapa no cambie de detalle en el corte.
 */
export async function planificar(
  bbox,
  medir,
  { maxBytes = MAX_BYTES, zoomTope = ZOOM_TOPE, zoomPiso = ZOOM_PISO } = {},
) {
  if (zoomPiso > zoomTope) throw new Error('zoomPiso no puede superar a zoomTope');

  for (let zoom = zoomTope; zoom >= zoomPiso; zoom--) {
    const bytes = await medir(bbox, zoom);
    if (bytes <= maxBytes) return { partes: [{ bbox, zoom_max: zoom, bytes }] };
  }

  const mitades = partirBbox(bbox);
  for (let zoom = zoomTope; zoom >= zoomPiso; zoom--) {
    const partes = [];
    for (const mitad of mitades) {
      const bytes = await medir(mitad, zoom);
      if (bytes > maxBytes) break;
      partes.push({ bbox: mitad, zoom_max: zoom, bytes });
    }
    if (partes.length === mitades.length) return { partes };
  }

  throw new Error(
    `No entra en ${maxBytes} bytes ni partido en dos con zoom máximo ${zoomPiso} (bbox ${bbox.join(',')}). ` +
      'Hace falta una decisión: bajar el piso, achicar el recorte o pasar a Pro (backend-supabase#68).',
  );
}
