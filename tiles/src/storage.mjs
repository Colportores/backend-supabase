// Cliente mínimo de la API REST de Supabase Storage (sin dependencias: usa `fetch`).
// Escribe con la clave de servicio (service_role / secret key), que nunca va al repo: sale de
// variables de entorno (ver docs/mapas-tiles.md § «Credenciales»). Lee por la URL pública.

const REINTENTOS = 3;

export function clienteStorage({ url, clave, bucket = 'mapas', fetchFn = fetch, esperaMs = 500 }) {
  if (!url) throw new Error('Falta SUPABASE_URL');
  const raiz = `${url.replace(/\/+$/, '')}/storage/v1`;
  const autorizacion = clave ? { Authorization: `Bearer ${clave}`, apikey: clave } : {};

  const codificar = (ruta) => ruta.split('/').map(encodeURIComponent).join('/');
  const urlPublica = (ruta) => `${raiz}/object/public/${bucket}/${codificar(ruta)}`;

  async function pedir(metodo, destino, { headers = {}, body } = {}) {
    let ultimo;
    for (let intento = 1; intento <= REINTENTOS; intento++) {
      try {
        const respuesta = await fetchFn(destino, { method: metodo, headers, body });
        if (respuesta.status < 500) return respuesta;
        ultimo = new Error(`${metodo} ${destino} → ${respuesta.status}`);
      } catch (error) {
        ultimo = error;
      }
      if (esperaMs > 0) await new Promise((r) => setTimeout(r, esperaMs * intento));
    }
    throw ultimo;
  }

  async function exigir(respuesta, que) {
    if (respuesta.ok) return respuesta;
    const texto = await respuesta.text().catch(() => '');
    throw new Error(`${que} falló: ${respuesta.status} ${texto.slice(0, 300)}`);
  }

  return {
    urlPublica,

    /**
     * Deja el bucket como dice `definicion` (tiles/src/bucket.mjs): lo crea si no existe y corrige
     * lo que difiera. Devuelve 'creado', 'actualizado' o 'igual'. Es lo mismo que hace la migración
     * 0029; está acá para la primera publicación contra un proyecto al que todavía no le llegó.
     */
    async asegurarBucket(definicion) {
      const cuerpo = {
        public: definicion.public,
        file_size_limit: definicion.file_size_limit,
        allowed_mime_types: [...definicion.allowed_mime_types],
      };
      const json = { 'content-type': 'application/json' };
      const respuesta = await pedir('GET', `${raiz}/bucket/${definicion.id}`, {
        headers: autorizacion,
      });
      if (respuesta.status === 404 || respuesta.status === 400) {
        const creada = await pedir('POST', `${raiz}/bucket`, {
          headers: { ...autorizacion, ...json },
          body: JSON.stringify({ id: definicion.id, name: definicion.id, ...cuerpo }),
        });
        await exigir(creada, `Crear el bucket ${definicion.id}`);
        return 'creado';
      }
      await exigir(respuesta, `Leer el bucket ${definicion.id}`);
      const actual = await respuesta.json();
      const mismosTipos =
        JSON.stringify([...(actual.allowed_mime_types ?? [])].sort()) ===
        JSON.stringify([...cuerpo.allowed_mime_types].sort());
      if (
        actual.public === cuerpo.public &&
        Number(actual.file_size_limit) === cuerpo.file_size_limit &&
        mismosTipos
      ) {
        return 'igual';
      }
      const corregida = await pedir('PUT', `${raiz}/bucket/${definicion.id}`, {
        headers: { ...autorizacion, ...json },
        body: JSON.stringify(cuerpo),
      });
      await exigir(corregida, `Corregir el bucket ${definicion.id}`);
      return 'actualizado';
    },

    /** Sube (o reemplaza) un objeto. `contenido` es un Buffer o Uint8Array. */
    async subir(ruta, contenido, { contentType, cacheControl }) {
      const respuesta = await pedir('POST', `${raiz}/object/${bucket}/${codificar(ruta)}`, {
        headers: {
          ...autorizacion,
          'content-type': contentType,
          'cache-control': cacheControl,
          'x-upsert': 'true',
        },
        body: contenido,
      });
      await exigir(respuesta, `Subir ${ruta}`);
    },

    /** El JSON publicado en `ruta`, o null si no existe todavía. */
    async bajarJson(ruta) {
      const respuesta = await pedir('GET', urlPublica(ruta), {
        headers: { 'cache-control': 'no-cache' },
      });
      // Storage responde 400 o 404 según la versión cuando el objeto no existe.
      if (respuesta.status === 404 || respuesta.status === 400) return null;
      await exigir(respuesta, `Bajar ${ruta}`);
      return respuesta.json();
    },

    /** Si el objeto público existe. */
    async existe(ruta) {
      const respuesta = await pedir('HEAD', urlPublica(ruta));
      return respuesta.ok;
    },

    /** Objetos bajo `prefijo` (un solo nivel): [{ ruta, actualizado_en }]. */
    async listar(prefijo) {
      const objetos = [];
      for (let offset = 0; ; offset += 100) {
        const respuesta = await pedir('POST', `${raiz}/object/list/${bucket}`, {
          headers: { ...autorizacion, 'content-type': 'application/json' },
          body: JSON.stringify({
            prefix: prefijo,
            limit: 100,
            offset,
            sortBy: { column: 'name', order: 'asc' },
          }),
        });
        await exigir(respuesta, `Listar ${prefijo}`);
        const pagina = await respuesta.json();
        for (const o of pagina) {
          // Las carpetas vienen sin id: no son objetos.
          if (o.id) {
            objetos.push({ ruta: `${prefijo}/${o.name}`, actualizado_en: o.updated_at ?? o.created_at });
          }
        }
        if (pagina.length < 100) return objetos;
      }
    },

    async borrar(rutas) {
      if (rutas.length === 0) return;
      const respuesta = await pedir('DELETE', `${raiz}/object/${bucket}`, {
        headers: { ...autorizacion, 'content-type': 'application/json' },
        body: JSON.stringify({ prefixes: rutas }),
      });
      await exigir(respuesta, 'Borrar objetos');
    },
  };
}
