// El catálogo lleva, en cada paquete de ciudad, el `ambito_id`: el id de la ciudad en la base
// (public.ciudad.id). Es lo que la app usa para elegir SU paquete (PaqueteTiles.cubre), no el slug ni
// el bbox. El publicador lo lee de la base del proyecto con la clave de servicio (PostgREST) y empareja
// por nombre, en Uruguay. Si no hay una ciudad con ese nombre, o hay más de una, se detiene antes de
// subir nada: nunca se publica un paquete de ciudad sin `ambito_id`.
// Decisión de Cristian del 06/10 («Catálogo»), aplicada en backend-supabase#73.

/** Para comparar nombres: sin tildes, sin mayúsculas y con los espacios normalizados. */
export function normalizar(nombre) {
  return String(nombre)
    .normalize('NFD')
    .replace(/\p{Diacritic}/gu, '')
    .trim()
    .replace(/\s+/g, ' ')
    .toLowerCase();
}

/** Las ciudades (no borradas) del país `pais` (ISO 3166-1 alpha-2) en public.ciudad: [{ id, nombre }]. */
export async function leerCiudades({ url, clave, pais = 'UY', fetchImpl = fetch }) {
  const consulta = `select=id,nombre,pais!inner(iso_code)&pais.iso_code=eq.${pais}&deleted_at=is.null&order=nombre.asc&limit=1000`;
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

/** Las `ciudades` de tiles/ciudades.json, cada una con su `ciudad_id`. Lanza si alguna no tiene exactamente una. */
export function asignarAmbitos(ciudades, filas) {
  return ciudades.map((ciudad) => {
    const buscada = normalizar(ciudad.nombre);
    const coinciden = filas.filter((fila) => normalizar(fila.nombre) === buscada);
    if (coinciden.length === 0) {
      throw new Error(
        `La ciudad «${ciudad.nombre}» (tiles/ciudades.json) no está en public.ciudad del proyecto (país UY). ` +
          'Cargala antes de publicar: sin su ambito_id la app no encontraría su paquete. No se subió nada.',
      );
    }
    if (coinciden.length > 1) {
      throw new Error(
        `Hay ${coinciden.length} ciudades llamadas «${ciudad.nombre}» en public.ciudad (${coinciden.map((f) => f.id).join(', ')}): ` +
          'no sé cuál es. Dejá una sola. No se subió nada.',
      );
    }
    return { ...ciudad, ciudad_id: coinciden[0].id };
  });
}
