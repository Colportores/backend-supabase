// Con la clave anónima (la que lleva la app) el bucket `mapas` se LEE pero no se escribe: ni subir, ni
// borrar, ni pisar el catálogo, ni listar. Sale con código 1 si algo de eso se puede.
// Uso: node acceso-anonimo.mjs <URL pública del bucket>   (con ANON_KEY en el entorno)
import assert from 'node:assert/strict';

const publica = process.argv[2];
const anon = process.env.ANON_KEY;
if (!publica || !anon) {
  console.error('Uso: ANON_KEY=… node acceso-anonimo.mjs <URL pública del bucket>');
  process.exit(2);
}
const raiz = publica.replace('/object/public/mapas', '');
const auth = { authorization: `Bearer ${anon}`, apikey: anon };
const json = { 'content-type': 'application/json' };

const antes = await (await fetch(`${publica}/catalogo.json`)).text();
let fallas = 0;
async function esperar(que, hacer) {
  try {
    await hacer();
    console.log(`ok    ${que}`);
  } catch (error) {
    fallas += 1;
    console.log(`FALLA ${que} — ${error.message.split('\n')[0]}`);
  }
}

await esperar('anon no puede subir un archivo', async () => {
  const r = await fetch(`${raiz}/object/mapas/intruso.json`, { method: 'POST', body: '{}', headers: { ...auth, ...json } });
  assert.ok(r.status >= 400, `HTTP ${r.status}`);
});
await esperar('anon no puede pisar el catálogo (x-upsert)', async () => {
  const r = await fetch(`${raiz}/object/mapas/catalogo.json`, { method: 'POST', body: '{}', headers: { ...auth, ...json, 'x-upsert': 'true' } });
  assert.ok(r.status >= 400, `HTTP ${r.status}`);
});
await esperar('anon no puede borrar', async () => {
  const r = await fetch(`${raiz}/object/mapas/catalogo.json`, { method: 'DELETE', headers: auth });
  assert.ok(r.status >= 400, `HTTP ${r.status}`);
});
await esperar('anon no ve la lista de archivos', async () => {
  const r = await fetch(`${raiz}/object/list/mapas`, { method: 'POST', body: JSON.stringify({ prefix: '' }), headers: { ...auth, ...json } });
  const cuerpo = r.status === 200 ? await r.json() : [];
  assert.deepEqual(cuerpo, []);
});
await esperar('anon no ve la carpeta de los paquetes de zona (su nombre no se puede listar)', async () => {
  const r = await fetch(`${raiz}/object/list/mapas`, { method: 'POST', body: JSON.stringify({ prefix: 'zonas' }), headers: { ...auth, ...json } });
  const cuerpo = r.status === 200 ? await r.json() : [];
  assert.deepEqual(cuerpo, []);
});
await esperar('anon no puede subir un paquete a zonas/', async () => {
  const r = await fetch(`${raiz}/object/mapas/zonas/${'0'.repeat(32)}.pmtiles`, { method: 'POST', body: 'x', headers: { ...auth, 'content-type': 'application/octet-stream' } });
  assert.ok(r.status >= 400, `HTTP ${r.status}`);
});
await esperar('el catálogo quedó intacto', async () => {
  assert.equal(await (await fetch(`${publica}/catalogo.json`)).text(), antes);
});

if (fallas > 0) process.exit(1);
console.log('\nSolo service_role escribe.');
