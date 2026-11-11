// Cliente mínimo de la API REST de Supabase Storage (sin dependencias: usa `fetch`).
// Escribe con la clave de servicio (service_role / secret key), que nunca va al repo: sale de
// variables de entorno (ver docs/mapas-tiles.md § «Credenciales»). Lo que el publicador necesita
// leer para decidir (el catálogo, si un paquete ya está) lo pide por el endpoint autenticado, con la
// misma clave. Ese endpoint también puede pasar por el CDN y devolver una copia de hasta un minuto
// (backend-supabase#271): por eso `bajarJson` compara lo que bajó con el eTag que da el listado del
// bucket (un POST a la base, sin caché) y, si no coinciden, espera y vuelve a leer; si no consigue la
// copia vigente, falla. Sin clave (un simulacro) cae a la URL pública, sin esa comprobación.

import { createHash } from 'node:crypto';

const REINTENTOS = 3;

// El nombre del archivo del mapa de una zona (`zonas/<32 hex>.pmtiles`) es la única llave de ese mapa
// (docs/mapas-tiles.md § Privacidad): no puede salir en ningún mensaje, ni en el de un error. Todo lo que este
// cliente dice de una ruta, de una URL o de lo que contestó el servidor pasa por `tapar`.
const NOMBRE_DE_ZONA = /(?:zonas(?:\/|%2F))?[0-9a-f]{32}\.pmtiles/gi;
export const tapar = (texto) => String(texto).replace(NOMBRE_DE_ZONA, 'zonas/<paquete de zona>');

const dormir = (ms) => new Promise((r) => setTimeout(r, ms));

/** El eTag sin comillas ni prefijo débil: `W/"abc"` y `"abc"` son `abc`. */
const normalizarEtag = (etag) => String(etag).trim().replace(/^W\//, '').replace(/"/g, '');

/**
 * `esperaVigenteMs` × (`intentosVigente` − 1) tiene que pasar los 60 s del `max-age` del catálogo (bucket.mjs):
 * es lo que tarda el CDN en soltar la copia vieja. `esperar` se cambia en los tests para no dormir de verdad; `avisar`
 * recibe un mensaje por cada espera (el CLI lo imprime).
 */
export function clienteStorage({
  url,
  clave,
  bucket = 'mapas',
  fetchFn = fetch,
  esperaMs = 500,
  esperaVigenteMs = 15_000,
  intentosVigente = 6,
  esperar = dormir,
  avisar = () => {},
}) {
  if (!url) throw new Error('Falta SUPABASE_URL');
  const raiz = `${url.replace(/\/+$/, '')}/storage/v1`;
  const autorizacion = clave ? { Authorization: `Bearer ${clave}`, apikey: clave } : {};

  const codificar = (ruta) => ruta.split('/').map(encodeURIComponent).join('/');
  const urlPublica = (ruta) => `${raiz}/object/public/${bucket}/${codificar(ruta)}`;
  const urlAutenticada = (ruta) => `${raiz}/object/authenticated/${bucket}/${codificar(ruta)}`;
  const urlDeLectura = (ruta) => (clave ? urlAutenticada(ruta) : urlPublica(ruta));

  async function pedir(metodo, destino, { headers = {}, body } = {}) {
    let ultimo;
    for (let intento = 1; intento <= REINTENTOS; intento++) {
      try {
        const respuesta = await fetchFn(destino, { method: metodo, headers, body });
        if (respuesta.status < 500) return respuesta;
        ultimo = new Error(`${metodo} ${tapar(destino)} → ${respuesta.status}`);
      } catch (error) {
        const mensaje = tapar(error?.message ?? error);
        ultimo = mensaje === error?.message ? error : new Error(mensaje, { cause: error?.cause && { code: error.cause.code } });
      }
      if (esperaMs > 0) await esperar(esperaMs * intento);
    }
    throw ultimo;
  }

  async function exigir(respuesta, que) {
    if (respuesta.ok) return respuesta;
    const texto = await respuesta.text().catch(() => '');
    throw new Error(`${tapar(que)} falló: ${respuesta.status} ${tapar(texto.slice(0, 300))}`);
  }

  /** { datos, etag } del JSON en `ruta`, o null si no existe. El eTag es el de la respuesta o, si no vino, el MD5 del cuerpo. */
  async function leerJson(ruta) {
    const respuesta = await pedir('GET', urlDeLectura(ruta), {
      headers: { ...autorizacion, 'cache-control': 'no-cache' },
    });
    // Storage responde 400 o 404 según la versión cuando el objeto no existe.
    if (respuesta.status === 404 || respuesta.status === 400) return null;
    await exigir(respuesta, `Bajar ${ruta}`);
    const bytes = Buffer.from(await respuesta.arrayBuffer());
    const cabecera = respuesta.headers.get('etag');
    const etag = cabecera ? normalizarEtag(cabecera) : createHash('md5').update(bytes).digest('hex');
    return { datos: JSON.parse(bytes.toString('utf8')), etag };
  }

  /** El eTag de `ruta` según el listado del bucket (sin caché), o null si no está. */
  async function etagListado(ruta) {
    const corte = ruta.lastIndexOf('/');
    const carpeta = corte === -1 ? '' : ruta.slice(0, corte);
    const nombre = ruta.slice(corte + 1);
    const respuesta = await pedir('POST', `${raiz}/object/list/${bucket}`, {
      headers: { ...autorizacion, 'content-type': 'application/json' },
      body: JSON.stringify({ prefix: carpeta, search: nombre, limit: 100, offset: 0, sortBy: { column: 'name', order: 'asc' } }),
    });
    await exigir(respuesta, `Listar ${carpeta || 'la raíz del bucket'}`);
    // `search` busca por comienzo del nombre: puede traer otros (`catalogo.json.bak`); las carpetas vienen sin id.
    const objeto = (await respuesta.json()).find((o) => o.id && o.name === nombre);
    if (!objeto) return null;
    const etag = objeto.metadata?.eTag;
    if (!etag) throw new Error(`El listado del Storage no trae el eTag de ${tapar(ruta)}: no se puede comprobar que lo leído es lo vigente.`);
    return normalizarEtag(etag);
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

    /**
     * El JSON publicado en `ruta`, o null si no existe todavía; con clave, siempre la copia VIGENTE
     * (backend-supabase#271). El endpoint autenticado puede contestar con lo que el CDN guardó hasta 60 s
     * (`max-age=60`), y un publicador que fusiona sobre un catálogo viejo borra lo que publicó la corrida
     * anterior sin anotarlo en `retirados`. El listado del bucket no pasa por el CDN: lo leído vale si su
     * eTag es el del listado (y si el listado dice que no está, la lectura también). Si no coinciden, espera
     * a que venza la copia y vuelve a leer; si después de `intentosVigente` lecturas sigue sin la vigente, falla.
     */
    async bajarJson(ruta) {
      if (!clave) return (await leerJson(ruta))?.datos ?? null;
      for (let intento = 1; ; intento++) {
        const vigente = await etagListado(ruta);
        const leido = await leerJson(ruta);
        if (vigente === null && leido === null) return null;
        if (vigente !== null && leido !== null && leido.etag === vigente) return leido.datos;
        if (intento >= intentosVigente) {
          const que = vigente === null ? 'el bucket no lo tiene' : leido === null ? 'no lo encontró' : 'trajo una copia vieja';
          throw new Error(
            `No se pudo leer la copia vigente de ${tapar(ruta)}: después de ${intento} lecturas en ` +
              `${Math.round(((intento - 1) * esperaVigenteMs) / 1000)} s, el Storage ${que} (eTag del listado: ${vigente ?? 'ninguno'}, ` +
              `de lo leído: ${leido?.etag ?? 'ninguno'}). Es la caché del CDN: esperá un par de minutos y volvé a correr.`,
          );
        }
        avisar(`${tapar(ruta)}: el Storage devolvió una copia que no es la vigente (caché del CDN); espero ${Math.round(esperaVigenteMs / 1000)} s y vuelvo a leer`);
        await esperar(esperaVigenteMs);
      }
    },

    /**
     * Si el objeto existe. Solo «no está» (404, o 400 como contesta Storage según la versión) vale como falso:
     * cualquier otra respuesta (429, 401, 403…) es un error, no un «no está». Quien pregunta decide con esto si
     * vuelve a subir algo o retira un mapa, y un límite de pedidos no puede hacerle creer que el archivo no existe.
     */
    async existe(ruta) {
      const respuesta = await pedir('HEAD', urlDeLectura(ruta), { headers: autorizacion });
      if (respuesta.ok) return true;
      if (respuesta.status === 404 || respuesta.status === 400) return false;
      throw new Error(`Comprobar ${tapar(ruta)} falló: ${respuesta.status}`);
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
