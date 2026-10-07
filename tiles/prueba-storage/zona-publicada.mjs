// Después de publicar las zonas: lo que cada parte ve y lo que no.
//   · public.zona.paquete_mapa de la zona trae el enlace, con un nombre de 128 bits al azar bajo zonas/;
//   · el archivo está en el bucket público y es el que dice el enlace (mismo tamaño y mismo SHA-256);
//   · el catálogo público NO nombra ningún paquete de zona ni la carpeta zonas/;
//   · la clave anónima no puede listar la carpeta (el nombre del archivo es la única llave).
// Uso (con SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, ANON_KEY y ZONA en el entorno): node prueba-storage/zona-publicada.mjs <URL pública del bucket>
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';

const publica = process.argv[2]?.replace(/\/+$/, '');
const { SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY: clave, ANON_KEY: anon, ZONA: zona } = process.env;
if (!publica || !SUPABASE_URL || !clave || !anon || !zona) {
  console.error('Uso: SUPABASE_URL=… SUPABASE_SERVICE_ROLE_KEY=… ANON_KEY=… ZONA=<uuid> node prueba-storage/zona-publicada.mjs <url pública del bucket>');
  process.exit(2);
}

const respuesta = await fetch(`${SUPABASE_URL}/rest/v1/zona?id=eq.${zona}&select=paquete_mapa,sync_version`, {
  headers: { apikey: clave, authorization: `Bearer ${clave}` },
});
assert.equal(respuesta.status, 200);
const [fila] = await respuesta.json();
assert.ok(fila?.paquete_mapa, 'la zona tiene paquete_mapa');
const p = fila.paquete_mapa;
assert.match(p.archivo, /^zonas\/[0-9a-f]{32}\.pmtiles$/, 'el nombre es de 128 bits al azar');
assert.ok(p.archivo.indexOf(zona) === -1, 'y no deriva del id de la zona');
for (const campo of ['tamano_bytes', 'sha256', 'zoom_max', 'region_sha256', 'actualizado_en']) assert.ok(p[campo] !== undefined, `trae ${campo}`);
assert.deepEqual(p.anteriores, [], 'una primera publicación no tiene anteriores');
console.log(`ok    public.zona.paquete_mapa: zoom ${p.zoom_max}, ${p.tamano_bytes} bytes (sync_version ${fila.sync_version})`);

const archivo = await fetch(`${publica}/${p.archivo}`);
assert.equal(archivo.status, 200, `el archivo se baja por la URL pública (HTTP ${archivo.status})`);
const bytes = Buffer.from(await archivo.arrayBuffer());
assert.equal(bytes.length, p.tamano_bytes, 'mismo tamaño');
assert.equal(createHash('sha256').update(bytes).digest('hex'), p.sha256, 'mismo SHA-256');
assert.equal(bytes.subarray(0, 7).toString(), 'PMTiles', 'es un PMTiles');
assert.equal(archivo.headers.get('cache-control'), 'public, max-age=31536000, immutable');
console.log('ok    el archivo está en el bucket, es un PMTiles y es el que dice el enlace');

const catalogo = await (await fetch(`${publica}/catalogo.json`)).text();
assert.ok(!catalogo.includes('zonas/') && !catalogo.includes('"zona"'), 'el catálogo público no nombra paquetes de zona');
console.log('ok    el catálogo público no nombra la zona ni la carpeta zonas/');

const lista = await fetch(`${publica.replace('/object/public/mapas', '')}/object/list/mapas`, {
  method: 'POST',
  headers: { apikey: anon, authorization: `Bearer ${anon}`, 'content-type': 'application/json' },
  body: JSON.stringify({ prefix: 'zonas' }),
});
assert.deepEqual(lista.status === 200 ? await lista.json() : [], [], 'la clave anónima no lista zonas/');
console.log('ok    sin la clave de servicio no se puede listar la carpeta zonas/');
