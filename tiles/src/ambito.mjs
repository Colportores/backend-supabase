// Qué ciudades se publican y con qué rectángulo: lo dice la base, no el repo.
//
// Decisión de Cristian del 06/10 («Área ciudad», backend-supabase#42 etapa 2): cada ciudad guarda su
// rectángulo en `public.ciudad` (bbox_oeste, bbox_sur, bbox_este, bbox_norte; migración 0031) y el
// publicador publica **las ciudades que lo tienen**, sin ninguna lista en el repo. El publicador lee
// `public.ciudad` por PostgREST con la clave de servicio.
//
// El catálogo lleva, en cada paquete de ciudad, el `ambito_id`: el id de la ciudad en la base. Es lo que la
// app usa para elegir SU paquete (PaqueteTiles.cubre), no el slug ni el bbox. Nunca se publica un paquete de
// ciudad sin él: al leerlo de la fila, no puede faltar.

/** Para comparar nombres: sin tildes, sin mayúsculas y con los espacios normalizados. */
export function normalizar(nombre) {
  return String(nombre)
    .normalize('NFD')
    .replace(/\p{Diacritic}/gu, '')
    .trim()
    .replace(/\s+/g, ' ')
    .toLowerCase();
}

/** El slug de una ciudad: su nombre normalizado, en minúsculas y con guiones (`San José` → `san-jose`). */
export function slugDe(nombre) {
  return normalizar(nombre)
    .replace(/[^a-z0-9]+/g, '-')
    .replace(/^-+|-+$/g, '');
}

const COLUMNAS = 'id,nombre,lat_centro,lon_centro,bbox_oeste,bbox_sur,bbox_este,bbox_norte';

/**
 * Las ciudades (no borradas) del país `pais` (ISO 3166-1 alpha-2) en public.ciudad, con su rectángulo si lo
 * tienen: [{ id, nombre, lat_centro, lon_centro, bbox_oeste, bbox_sur, bbox_este, bbox_norte }].
 */
export async function leerCiudades({ url, clave, pais = 'UY', fetchImpl = fetch }) {
  const consulta = `select=${COLUMNAS},pais!inner(iso_code)&pais.iso_code=eq.${pais}&deleted_at=is.null&order=nombre.asc&limit=1000`;
  let respuesta;
  try {
    respuesta = await fetchImpl(`${url.replace(/\/+$/, '')}/rest/v1/ciudad?${consulta}`, {
      headers: { apikey: clave, authorization: `Bearer ${clave}`, accept: 'application/json' },
    });
  } catch (error) {
    throw new Error(`No pude leer public.ciudad (${error.cause?.code ?? error.message})`);
  }
  if (!respuesta.ok) {
    const texto = await respuesta.text().catch(() => '');
    throw new Error(`Leer public.ciudad falló: ${respuesta.status} ${texto.slice(0, 300)}`);
  }
  return respuesta.json();
}

const tieneRectangulo = (fila) =>
  [fila.bbox_oeste, fila.bbox_sur, fila.bbox_este, fila.bbox_norte].every((n) => typeof n === 'number' && Number.isFinite(n));

/**
 * De las filas de public.ciudad, las que se publican y las que no.
 *
 * Devuelve `{ publicables: [{ ciudad_id, slug, nombre, bbox }], sinRectangulo: [nombre] }`. Una ciudad sin
 * rectángulo no se publica (no tiene mapa propio) y se lista para que se vea. Lanza, **antes de que se suba
 * nada**, si dos ciudades con rectángulo darían el mismo slug (el nombre del archivo y el `id` del paquete):
 * no hay forma de saber cuál es cuál sin que alguien lo decida.
 */
export function ciudadesPublicables(filas) {
  const publicables = [];
  const sinRectangulo = [];
  const porSlug = new Map();
  for (const fila of filas) {
    if (!tieneRectangulo(fila)) {
      sinRectangulo.push(fila.nombre);
      continue;
    }
    const slug = slugDe(fila.nombre);
    if (slug === '') {
      throw new Error(`La ciudad ${fila.id} (${JSON.stringify(fila.nombre)}) no tiene un nombre con letras o números: no se puede armar su paquete. No se subió nada.`);
    }
    if (porSlug.has(slug)) {
      const otra = porSlug.get(slug);
      throw new Error(
        `Hay dos ciudades con rectángulo que dan el mismo paquete «${slug}»: ${otra.id} («${otra.nombre}») y ${fila.id} («${fila.nombre}»). ` +
          'No sé cuál es. Dejá una sola (dar de baja la otra o sacarle el rectángulo). No se subió nada.',
      );
    }
    porSlug.set(slug, fila);
    publicables.push({
      ciudad_id: fila.id,
      slug,
      nombre: fila.nombre,
      bbox: [fila.bbox_oeste, fila.bbox_sur, fila.bbox_este, fila.bbox_norte],
    });
  }
  return { publicables, sinRectangulo };
}

/**
 * Avisos sobre los paquetes de ciudad que el catálogo ya publicó y que esta corrida no vuelve a publicar:
 * la ciudad ya no existe (o está dada de baja) o ya no tiene rectángulo. **No se retiran solos**: el
 * paquete sigue en el catálogo hasta que alguien lo decida (retirar un mapa a los teléfonos es una decisión
 * de producto). Solo se avisa.
 */
export function avisosDeCiudades(catalogo, filas) {
  const porId = new Map(filas.map((f) => [f.id, f]));
  const avisos = [];
  for (const paquete of catalogo?.paquetes ?? []) {
    if (paquete.nivel !== 'ciudad') continue;
    const fila = porId.get(paquete.ambito_id);
    if (!fila) {
      avisos.push(`${paquete.id} sigue en el catálogo, pero su ciudad (${paquete.ambito_id}) ya no está en public.ciudad o está dada de baja`);
    } else if (!tieneRectangulo(fila)) {
      avisos.push(`${paquete.id} sigue en el catálogo, pero la ciudad «${fila.nombre}» ya no tiene rectángulo`);
    }
  }
  return avisos;
}
