import assert from 'node:assert/strict';
import { execFile } from 'node:child_process';
import { createServer } from 'node:http';
import { test } from 'node:test';
import { fileURLToPath } from 'node:url';
import { ocultar } from '../src/secretos.mjs';

// La clave de servicio no puede salir por la consola: ni en un mensaje, ni en un error HTTP (un servidor o
// un proxy puede devolver los encabezados que recibió, con el Authorization).
const CLAVE = 'eyJhbGciOiJIUzI1NiJ9.clave-de-servicio-que-no-puede-salir.firma-de-prueba';
const CLI = fileURLToPath(new URL('../src/cli.mjs', import.meta.url));

test('ocultar reemplaza cada aparición de un secreto y deja el resto', () => {
  assert.equal(ocultar(`Bearer ${CLAVE} y otra vez ${CLAVE}`, CLAVE), 'Bearer *** y otra vez ***');
  assert.equal(ocultar('sin nada', CLAVE, undefined, ''), 'sin nada');
  assert.equal(ocultar('abc', 'abc'), 'abc', 'un «secreto» demasiado corto para serlo no se toca');
});

/** Un servidor que contesta todo con `estado` y, en el cuerpo, los encabezados que recibió (el peor caso). */
async function servidorQueRepiteLosEncabezados(estado) {
  const peticiones = [];
  const servidor = createServer((req, res) => {
    peticiones.push(`${req.method} ${req.url}`);
    res.writeHead(estado, { 'content-type': 'application/json' });
    // El Authorization va primero: el mensaje de error corta el cuerpo a unos 300 caracteres.
    res.end(JSON.stringify({ authorization: req.headers.authorization, apikey: req.headers.apikey, error: 'rechazado', recibido: req.headers }));
  });
  await new Promise((resolver) => servidor.listen(0, '127.0.0.1', resolver));
  return { url: `http://127.0.0.1:${servidor.address().port}`, peticiones, cerrar: () => servidor.close() };
}

function correr(args, env) {
  return new Promise((resolver) => {
    execFile(process.execPath, [CLI, ...args], { env: { ...process.env, ...env }, timeout: 20_000 }, (error, stdout, stderr) => {
      resolver({ codigo: error ? (error.code ?? 1) : 0, salida: `${stdout}\n${stderr}` });
    });
  });
}

for (const [nombre, args, estado] of [
  ['publicar (el bucket rechaza la clave)', ['publicar', '--solo', 'estilo'], 401],
  ['publicar (la lectura de public.ciudad falla)', ['publicar', '--solo', 'ciudades', '--ciudad', 'montevideo'], 403],
  ['publicar con simulacro', ['publicar', '--solo', 'ciudades', '--dry-run'], 403],
  ['publicar zonas con simulacro (la lectura de public.zona falla)', ['publicar', '--solo', 'zonas', '--dry-run'], 403],
]) {
  test(`${nombre}: la clave no sale en la consola aunque el servidor repita los encabezados`, async () => {
    const servidor = await servidorQueRepiteLosEncabezados(estado);
    try {
      const { codigo, salida } = await correr(args, { SUPABASE_URL: servidor.url, SUPABASE_SERVICE_ROLE_KEY: CLAVE });
      assert.equal(codigo, 1, salida);
      assert.ok(servidor.peticiones.length > 0, 'la clave llegó a viajar al servidor');
      assert.match(salida, /ERROR: .*falló: (401|403)/);
      assert.ok(salida.includes('***'), 'el error traía la clave y se la ocultó');
      assert.ok(!salida.includes(CLAVE), `la clave salió por la consola:\n${salida}`);
      assert.ok(!salida.includes('clave-de-servicio-que-no-puede-salir'), 'ni un pedazo de ella');
    } finally {
      servidor.cerrar();
    }
  });
}

test('verificar no necesita la clave y no la imprime, aunque esté en el entorno y todo falle', async () => {
  const servidor = await servidorQueRepiteLosEncabezados(500);
  try {
    const { codigo, salida } = await correr(['verificar', '--url', `${servidor.url}/storage/v1/object/public/mapas`], {
      SUPABASE_URL: servidor.url,
      SUPABASE_SERVICE_ROLE_KEY: CLAVE,
    });
    assert.equal(codigo, 1, salida);
    assert.match(salida, /FALLA/);
    assert.ok(!salida.includes(CLAVE), `la clave salió por la consola:\n${salida}`);
    assert.ok(!servidor.peticiones.some((p) => p.includes(CLAVE)));
  } finally {
    servidor.cerrar();
  }
});
