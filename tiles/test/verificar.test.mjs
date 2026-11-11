import assert from 'node:assert/strict';
import { test } from 'node:test';
import { armarPaquete, fusionar, rutaArchivo } from '../src/catalogo.mjs';
import { ORIGENES, verificar } from '../src/verificar.mjs';
import { estiloDePrueba } from './ayudas.mjs';

const BASE = 'https://proyecto.supabase.co/storage/v1/object/public/mapas';
const SHA = 'a'.repeat(64);
const ARCHIVO = rutaArchivo({ nivel: 'ciudad', clave: 'montevideo', sha256: SHA });
const CONTENIDO = Buffer.concat([Buffer.from('PMTiles'), Buffer.alloc(993, 3)]); // 1000 bytes

const catalogo = fusionar(
  null,
  [
    armarPaquete({
      nivel: 'ciudad',
      clave: 'montevideo',
      ambitoId: '09990000-0000-7000-8003-000000000001',
      nombre: 'Montevideo',
      zoomMax: 15,
      partes: [{ archivo: ARCHIVO, tamano_bytes: CONTENIDO.length, sha256: SHA }],
      build: '20261006',
      ahora: '2026-10-07T12:00:00Z',
    }),
  ],
  { ahora: '2026-10-07T12:00:00Z', estiloVersion: 'e'.repeat(64) },
);
const estilo = estiloDePrueba();

/**
 * Un servidor de Storage de mentira. `fallas` apaga una propiedad a la vez:
 *   sinCors, sinPreflight, sinRange, privado, pesoDistinto.
 */
function servidor(fallas = {}) {
  return async (url, { method = 'GET', headers = {} } = {}) => {
    const ruta = url.replace(`${BASE}/`, '');
    const cors = fallas.sinCors ? {} : { 'access-control-allow-origin': '*' };
    if (fallas.privado) return new Response('{"error":"not found"}', { status: 400, headers: cors });
    if (method === 'OPTIONS') {
      if (fallas.sinPreflight || fallas.sinCors) return new Response('{}', { status: 404 });
      return new Response(null, {
        status: 204,
        headers: { ...cors, 'access-control-allow-headers': headers['access-control-request-headers'] ?? '' },
      });
    }

    const json = (cuerpo) => new Response(JSON.stringify(cuerpo), { status: 200, headers: { 'content-type': 'application/json', ...cors } });
    if (ruta === 'catalogo.json') return json(catalogo);
    if (ruta === 'estilo/colportores.json') return json(estilo);
    if (ruta === 'estilo/glyphs/NotoSans-Regular/0-255.pbf') return new Response('pbf', { status: 200, headers: cors });
    if (ruta === 'estilo/sprites/grayscale.json') return json({});
    if (ruta === 'estilo/sprites/grayscale@2x.png') return new Response('png', { status: 200, headers: cors });

    if (ruta === ARCHIVO) {
      const largo = fallas.pesoDistinto ? CONTENIDO.length + 1 : CONTENIDO.length;
      if (method === 'HEAD') return new Response(null, { status: 200, headers: { 'content-length': String(largo), ...cors } });
      const rango = /^bytes=(\d+)-(\d+)$/.exec(headers.range ?? '');
      if (rango && !fallas.sinRange) {
        const [, desde, hasta] = rango.map(Number);
        return new Response(CONTENIDO.subarray(desde, hasta + 1), {
          status: 206,
          headers: { 'content-range': `bytes ${desde}-${hasta}/${CONTENIDO.length}`, ...cors },
        });
      }
      return new Response(CONTENIDO, { status: 200, headers: cors });
    }
    return new Response('no existe', { status: 404, headers: cors });
  };
}

const fallidas = (resultados) => resultados.filter((r) => !r.ok).map((r) => r.que);

test('un bucket bien publicado pasa todas las comprobaciones, sin credenciales', async () => {
  const resultados = await verificar({ urlPublica: BASE, fetchFn: servidor() });
  assert.deepEqual(fallidas(resultados), []);
  const que = resultados.map((r) => r.que).join('\n');
  assert.match(que, /catalogo\.json se lee sin login/);
  assert.match(que, /el estilo se lee sin login/);
  assert.match(que, /ciudad-montevideo: Range responde 206/);
  assert.match(que, /ciudad-montevideo: empieza con la firma de PMTiles/);
  for (const origen of ORIGENES) assert.match(que, new RegExp(`CORS ${origen}`));
  for (const origen of ORIGENES) assert.match(que, new RegExp(`preflight ${origen} acepta Range`));
});

test('si el preflight no se contesta, falla aunque el GET traiga CORS', async () => {
  const resultados = await verificar({ urlPublica: BASE, fetchFn: servidor({ sinPreflight: true }) });
  const fallas = fallidas(resultados);
  assert.ok(fallas.includes('ciudad-montevideo: preflight http://localhost:3000 acepta Range'));
  assert.ok(fallas.includes('ciudad-montevideo: preflight https://colportores.github.io acepta Range'));
  assert.equal(fallas.filter((f) => f.startsWith('CORS')).length, 0);
});

test('un preflight que no deja pasar Range falla; si falta If-Match solo avisa', async () => {
  const sinRange = async (url, opciones) => {
    const r = await servidor()(url, opciones);
    if (opciones?.method !== 'OPTIONS') return r;
    return new Response(null, { status: 204, headers: { 'access-control-allow-origin': '*', 'access-control-allow-headers': 'content-type' } });
  };
  assert.ok(fallidas(await verificar({ urlPublica: BASE, fetchFn: sinRange })).some((f) => f.includes('preflight')));

  const sinIfMatch = async (url, opciones) => {
    const r = await servidor()(url, opciones);
    if (opciones?.method !== 'OPTIONS') return r;
    return new Response(null, { status: 204, headers: { 'access-control-allow-origin': '*', 'access-control-allow-headers': 'range' } });
  };
  const resultados = await verificar({ urlPublica: BASE, fetchFn: sinIfMatch });
  assert.deepEqual(fallidas(resultados), []);
  assert.ok(resultados.some((r) => r.aviso && r.que.includes('If-Match')));
});

test('sin CORS falla, para localhost y para GitHub Pages', async () => {
  const resultados = await verificar({ urlPublica: BASE, fetchFn: servidor({ sinCors: true }) });
  const fallas = fallidas(resultados).join('\n');
  assert.match(fallas, /CORS http:\/\/localhost:3000 → catalogo\.json/);
  assert.match(fallas, /CORS https:\/\/colportores\.github\.io → paquetes\/ciudad\//);
});

test('un servidor que ignora Range (200 en vez de 206) falla', async () => {
  const resultados = await verificar({ urlPublica: BASE, fetchFn: servidor({ sinRange: true }) });
  assert.ok(fallidas(resultados).includes('ciudad-montevideo: Range responde 206'));
});

test('un tamaño distinto del que dice el catálogo falla', async () => {
  const resultados = await verificar({ urlPublica: BASE, fetchFn: servidor({ pesoDistinto: true }) });
  assert.ok(fallidas(resultados).includes('ciudad-montevideo: pesa lo que dice el catálogo'));
});

test('un bucket privado (o inexistente) se nota enseguida', async () => {
  const resultados = await verificar({ urlPublica: BASE, fetchFn: servidor({ privado: true }) });
  assert.deepEqual(fallidas(resultados), ['catalogo.json se lee sin login']);
});

test('un archivo que no es PMTiles falla aunque conteste 206', async () => {
  const fetchFn = async (url, opciones) => {
    const r = await servidor()(url, opciones);
    if (url.endsWith(ARCHIVO) && opciones?.headers?.range === 'bytes=0-15') {
      return new Response(Buffer.alloc(16, 65), { status: 206, headers: r.headers });
    }
    return r;
  };
  const resultados = await verificar({ urlPublica: BASE, fetchFn });
  assert.ok(fallidas(resultados).includes('ciudad-montevideo: empieza con la firma de PMTiles'));
});
