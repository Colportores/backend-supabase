import assert from 'node:assert/strict';
import { test } from 'node:test';
import { BUCKET, cacheControlDe, tipoDe } from '../src/bucket.mjs';
import { clienteStorage, tapar } from '../src/storage.mjs';

const URL = 'https://proyecto.supabase.co';

/** Un fetch de mentira: contesta lo que diga `responder(llamada)` y anota todas las llamadas. */
function fetchFalso(responder) {
  const llamadas = [];
  const fn = async (url, opciones = {}) => {
    const llamada = { url, metodo: opciones.method, headers: opciones.headers ?? {}, body: opciones.body };
    llamadas.push(llamada);
    return responder(llamada, llamadas.length);
  };
  return { fn, llamadas };
}

const json = (cuerpo, status = 200) => new Response(JSON.stringify(cuerpo), { status, headers: { 'content-type': 'application/json' } });

function cliente(fetchFn, extra = {}) {
  return clienteStorage({ url: `${URL}/`, clave: 'CLAVE-DE-SERVICIO', fetchFn, esperaMs: 0, ...extra });
}

test('sube con la clave de servicio, upsert, tipo y caché, a la ruta codificada', async () => {
  const { fn, llamadas } = fetchFalso(() => json({ Key: 'x' }));
  await cliente(fn).subir('paquetes/ciudad/mi ciudad.pmtiles', Buffer.from('datos'), {
    contentType: 'application/octet-stream',
    cacheControl: 'public, max-age=31536000, immutable',
  });
  const [l] = llamadas;
  assert.equal(l.metodo, 'POST');
  assert.equal(l.url, `${URL}/storage/v1/object/mapas/paquetes/ciudad/mi%20ciudad.pmtiles`);
  assert.equal(l.headers.Authorization, 'Bearer CLAVE-DE-SERVICIO');
  assert.equal(l.headers.apikey, 'CLAVE-DE-SERVICIO');
  assert.equal(l.headers['x-upsert'], 'true');
  assert.equal(l.headers['content-type'], 'application/octet-stream');
  assert.equal(l.headers['cache-control'], 'public, max-age=31536000, immutable');
});

test('un error al subir dice qué archivo y qué contestó el servidor', async () => {
  const { fn } = fetchFalso(() => json({ message: 'The object exceeded the maximum allowed size' }, 413));
  await assert.rejects(
    cliente(fn).subir('paquetes/ciudad/x.pmtiles', Buffer.from('x'), { contentType: 'application/octet-stream', cacheControl: 'x' }),
    /Subir paquetes\/ciudad\/x\.pmtiles falló: 413 .*exceeded/,
  );
});

test('reintenta los 5xx y los cortes de red, y se rinde a la tercera', async () => {
  let intentos = 0;
  const { fn } = fetchFalso(() => {
    intentos += 1;
    if (intentos === 1) throw new TypeError('fetch failed');
    return intentos === 2 ? new Response('', { status: 503 }) : json({ ok: true });
  });
  assert.equal(await cliente(fn).existe('catalogo.json'), true);
  assert.equal(intentos, 3);

  const siempre = fetchFalso(() => new Response('', { status: 500 }));
  await assert.rejects(cliente(siempre.fn).existe('catalogo.json'));
  assert.equal(siempre.llamadas.length, 3);
});

test('no reintenta un 4xx', async () => {
  const { fn, llamadas } = fetchFalso(() => json({ error: 'nope' }, 403));
  await assert.rejects(cliente(fn).borrar(['x']));
  assert.equal(llamadas.length, 1);
});

test('lee el catálogo por el endpoint autenticado, con la clave (no por la URL pública, que pasa por la caché), y devuelve null si todavía no existe', async () => {
  const { fn, llamadas } = fetchFalso(() => json({ version: 1 }));
  assert.deepEqual(await cliente(fn).bajarJson('catalogo.json'), { version: 1 });
  assert.equal(llamadas[0].url, `${URL}/storage/v1/object/authenticated/mapas/catalogo.json`);
  assert.equal(llamadas[0].headers.Authorization, 'Bearer CLAVE-DE-SERVICIO');
  assert.equal(llamadas[0].headers['cache-control'], 'no-cache');

  for (const status of [404, 400]) {
    const ausente = fetchFalso(() => json({ error: 'Object not found' }, status));
    assert.equal(await cliente(ausente.fn).bajarJson('catalogo.json'), null);
  }
  const roto = fetchFalso(() => json({ error: 'boom' }, 403));
  await assert.rejects(cliente(roto.fn).bajarJson('catalogo.json'), /403/);
});

test('sin clave (un simulacro) lee por la URL pública, sin credenciales', async () => {
  const { fn, llamadas } = fetchFalso(() => json({ version: 1 }));
  const sinClave = cliente(fn, { clave: undefined });
  assert.deepEqual(await sinClave.bajarJson('catalogo.json'), { version: 1 });
  assert.equal(await sinClave.existe('catalogo.json'), true);
  assert.equal(llamadas[0].url, `${URL}/storage/v1/object/public/mapas/catalogo.json`);
  assert.equal(llamadas[0].headers.Authorization, undefined);
  assert.equal(llamadas[1].url, `${URL}/storage/v1/object/public/mapas/catalogo.json`);
});

test('pregunta si un paquete ya está por el endpoint autenticado (HEAD), con la clave', async () => {
  const { fn, llamadas } = fetchFalso((l) => new Response('', { status: l.url.endsWith('ya-esta.pmtiles') ? 200 : 400 }));
  const c = cliente(fn);
  assert.equal(await c.existe('paquetes/ciudad/ya-esta.pmtiles'), true);
  assert.equal(await c.existe('paquetes/ciudad/no-esta.pmtiles'), false);
  assert.equal(llamadas[0].metodo, 'HEAD');
  assert.equal(llamadas[0].url, `${URL}/storage/v1/object/authenticated/mapas/paquetes/ciudad/ya-esta.pmtiles`);
  assert.equal(llamadas[0].headers.Authorization, 'Bearer CLAVE-DE-SERVICIO');
});

test('existe solo dice «no está» con 404 o 400: un límite de pedidos o un permiso caído es un error, no un archivo ausente', async () => {
  for (const status of [404, 400]) {
    const { fn } = fetchFalso(() => new Response('', { status }));
    assert.equal(await cliente(fn).existe('paquetes/ciudad/x.pmtiles'), false, `estado ${status}`);
  }
  for (const status of [429, 401, 403]) {
    const { fn, llamadas } = fetchFalso(() => new Response('', { status }));
    await assert.rejects(cliente(fn).existe('paquetes/ciudad/x.pmtiles'), new RegExp(`falló: ${status}`), `estado ${status}`);
    assert.equal(llamadas.length, 1, 'un 4xx no se reintenta');
  }
});

// El nombre del archivo del mapa de una zona es la llave de ese mapa: no sale en ningún error, venga de donde venga.
const LLAVE_HEX = '0123456789abcdef'.repeat(2);
const LLAVE = `zonas/${LLAVE_HEX}.pmtiles`;
const sinLlave = (error) => {
  const dicho = `${error.message} ${JSON.stringify(error.cause ?? '')}`;
  assert.ok(!dicho.includes(LLAVE_HEX), `el error nombra el archivo de la zona: ${dicho}`);
  return true;
};

test('el nombre del archivo de una zona no sale en el error de un 5xx, ni al preguntar (HEAD) ni al subir (POST)', async () => {
  const caido = fetchFalso(() => new Response('', { status: 503 }));
  await assert.rejects(cliente(caido.fn).existe(LLAVE), (e) => sinLlave(e) && /HEAD .* → 503/.test(e.message));
  assert.equal(caido.llamadas.length, 3, 'reintentó');
  assert.ok(caido.llamadas[0].url.includes(LLAVE_HEX), 'el pedido sí lleva el nombre: es lo que se está comprobando');

  const subida = fetchFalso(() => new Response('', { status: 503 }));
  await assert.rejects(
    cliente(subida.fn).subir(LLAVE, Buffer.from('x'), { contentType: 'application/octet-stream', cacheControl: 'x' }),
    (e) => sinLlave(e) && /POST .* → 503/.test(e.message),
  );
});

test('el nombre del archivo de una zona no sale cuando el servidor lo repite en un error 4xx, ni en un corte de red', async () => {
  const eco = fetchFalso((l) => json({ message: `The resource ${LLAVE} already exists`, url: l.url }, 413));
  await assert.rejects(
    cliente(eco.fn).subir(LLAVE, Buffer.from('x'), { contentType: 'application/octet-stream', cacheControl: 'x' }),
    (e) => sinLlave(e) && /Subir zonas\/<paquete de zona> falló: 413 .*already exists/.test(e.message),
  );
  await assert.rejects(cliente(eco.fn).bajarJson(LLAVE), (e) => sinLlave(e) && /falló: 413/.test(e.message));

  const corte = fetchFalso((l) => {
    throw new TypeError(`fetch failed ${l.url}`);
  });
  await assert.rejects(cliente(corte.fn).existe(LLAVE), (e) => sinLlave(e) && /fetch failed/.test(e.message));
  await assert.rejects(cliente(corte.fn).subir(LLAVE, Buffer.from('x'), { contentType: 'a', cacheControl: 'b' }), sinLlave);
});

test('tapar cambia solo los nombres de los archivos de zona (con o sin carpeta, escritos o codificados) y deja lo demás', () => {
  assert.equal(tapar(`HEAD https://p.supabase.co/storage/v1/object/authenticated/mapas/${LLAVE} → 503`), 'HEAD https://p.supabase.co/storage/v1/object/authenticated/mapas/zonas/<paquete de zona> → 503');
  assert.equal(tapar(`${LLAVE_HEX.toUpperCase()}.pmtiles y zonas%2F${LLAVE_HEX}.pmtiles`), 'zonas/<paquete de zona> y zonas/<paquete de zona>');
  for (const intacto of ['paquetes/ciudad/montevideo.0123456789ab.pmtiles', 'catalogo.json', 'estilo/colportores.json', 'sin nada']) {
    assert.equal(tapar(intacto), intacto);
  }
});

test('lista paginando de a 100 y sin contar las carpetas', async () => {
  const pagina = (desde, n) => Array.from({ length: n }, (_, i) => ({ id: `id${desde + i}`, name: `f${desde + i}.pmtiles`, updated_at: '2026-10-01T00:00:00Z' }));
  const { fn, llamadas } = fetchFalso((_, n) => json(n === 1 ? pagina(0, 100) : [...pagina(100, 3), { id: null, name: 'subcarpeta' }]));
  const objetos = await cliente(fn).listar('paquetes/ciudad');
  assert.equal(objetos.length, 103);
  assert.equal(objetos[0].ruta, 'paquetes/ciudad/f0.pmtiles');
  assert.deepEqual(JSON.parse(llamadas[1].body).offset, 100);
});

test('borrar no hace nada si no hay qué borrar', async () => {
  const { fn, llamadas } = fetchFalso(() => json([]));
  await cliente(fn).borrar([]);
  assert.equal(llamadas.length, 0);
  await cliente(fn).borrar(['a', 'b']);
  assert.deepEqual(JSON.parse(llamadas[0].body), { prefixes: ['a', 'b'] });
  assert.equal(llamadas[0].metodo, 'DELETE');
});

test('asegurarBucket crea el bucket si no existe', async () => {
  const { fn, llamadas } = fetchFalso((l) => (l.metodo === 'GET' ? json({ error: 'Bucket not found' }, 404) : json({ name: 'mapas' })));
  assert.equal(await cliente(fn).asegurarBucket(BUCKET), 'creado');
  const creada = JSON.parse(llamadas[1].body);
  assert.deepEqual(creada, {
    id: 'mapas',
    name: 'mapas',
    public: true,
    file_size_limit: 52_428_800,
    allowed_mime_types: [...BUCKET.allowed_mime_types],
  });
});

test('asegurarBucket no toca un bucket que ya está bien, y corrige el que difiere', async () => {
  const igual = { id: 'mapas', public: true, file_size_limit: 52_428_800, allowed_mime_types: [...BUCKET.allowed_mime_types].reverse() };
  const a = fetchFalso(() => json(igual));
  assert.equal(await cliente(a.fn).asegurarBucket(BUCKET), 'igual');
  assert.equal(a.llamadas.length, 1);

  const privado = fetchFalso((l) => (l.metodo === 'GET' ? json({ ...igual, public: false }) : json({ message: 'ok' })));
  assert.equal(await cliente(privado.fn).asegurarBucket(BUCKET), 'actualizado');
  assert.equal(privado.llamadas[1].metodo, 'PUT');
  assert.equal(JSON.parse(privado.llamadas[1].body).public, true);
});

test('el bucket es público, de 50 MiB, y solo acepta lo que se publica', () => {
  assert.equal(BUCKET.id, 'mapas');
  assert.equal(BUCKET.public, true);
  assert.equal(BUCKET.file_size_limit, 50 * 1024 * 1024);
  for (const ruta of ['a.pmtiles', 'a.json', 'a.pbf', 'a.png', 'OFL.txt']) {
    assert.ok(BUCKET.allowed_mime_types.includes(tipoDe(ruta)), ruta);
  }
  assert.throws(() => tipoDe('a.exe'), /no permitido/);
  assert.throws(() => tipoDe('sinextension'), /no permitido/);
});

test('los paquetes son inmutables; el catálogo y el estilo, de vida corta', () => {
  assert.match(cacheControlDe('paquetes/ciudad/montevideo.aaaaaaaaaaaa.pmtiles'), /immutable/);
  assert.equal(cacheControlDe('catalogo.json'), 'public, max-age=60');
  assert.equal(cacheControlDe('estilo/colportores.json'), 'public, max-age=60');
  assert.equal(cacheControlDe('estilo/glyphs/NotoSans-Regular/0-255.pbf'), 'public, max-age=86400');
});

test('exige la URL del proyecto', () => {
  assert.throws(() => clienteStorage({ url: '', clave: 'x' }), /SUPABASE_URL/);
});
