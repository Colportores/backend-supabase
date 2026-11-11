// La lista de Uruguay vive en dos lugares: `datos/uruguay-osm.json` (la lee el publicador) y la función
// `public.catalogo_osm_uruguay()` de la base (la leen la carga de ciudades y el alta a mano). Si difieren, el panel
// ofrecería un departamento o una ciudad con un nombre que el mapa que baja el colportor no tiene. Este test las ata.
import assert from 'node:assert/strict';
import { readFile, readdir } from 'node:fs/promises';
import { join } from 'node:path';
import { test } from 'node:test';
import { fileURLToPath } from 'node:url';
import { departamentosPublicables, funcionSql, leerCatalogo, serializar, uruguayPublicable } from '../src/uruguay.mjs';

const RAIZ = fileURLToPath(new URL('..', import.meta.url));
const ARCHIVO = join(RAIZ, 'datos', 'uruguay-osm.json');
const MIGRACIONES = join(RAIZ, '..', 'supabase', 'migrations');

/** La última migración que define la función (una lista nueva va en una migración nueva con `create or replace`). */
async function migracionDeLaLista() {
  const archivos = (await readdir(MIGRACIONES)).filter((a) => a.endsWith('.sql')).sort();
  let ultima = null;
  for (const archivo of archivos) {
    const texto = (await readFile(join(MIGRACIONES, archivo), 'utf8')).replace(/\r\n/g, '\n');
    if (texto.includes('function public.catalogo_osm_uruguay()')) ultima = { archivo, texto };
  }
  assert.ok(ultima, 'ninguna migración define public.catalogo_osm_uruguay()');
  return ultima;
}

test('la lista del repo es válida y trae su fuente, su fecha y la atribución de OSM', async () => {
  const catalogo = await leerCatalogo(ARCHIVO);
  assert.equal(catalogo.departamentos.length, 19);
  assert.match(catalogo.fuente.atribucion, /OpenStreetMap contributors/);
  assert.equal(catalogo.fuente.licencia, 'ODbL 1.0');
  assert.match(catalogo.fuente.datos_osm_de, /^\d{4}-\d{2}-\d{2}T/);
  assert.ok(catalogo.ciudades.length >= 100, 'cientos de ciudades, pueblos y villas');
  assert.ok(catalogo.ciudades.some((c) => c.nombre === 'Montevideo' && c.departamento === 'Montevideo'));
  assert.ok(catalogo.ciudades.some((c) => c.bbox === null), 'las que OSM no delimita quedan sin rectángulo');
});

test('está guardada como la escribe el comando: un diff muestra solo lo que cambió', async () => {
  const texto = (await readFile(ARCHIVO, 'utf8')).replace(/\r\n/g, '\n');
  assert.equal(texto, serializar(JSON.parse(texto)));
});

test('la función de la base lleva exactamente la misma lista', async () => {
  const catalogo = await leerCatalogo(ARCHIVO);
  const { archivo, texto } = await migracionDeLaLista();
  assert.ok(texto.includes(funcionSql(catalogo)), `${archivo}: catalogo_osm_uruguay() no es la lista de tiles/datos/uruguay-osm.json. Corré «node src/cli.mjs catalogo-uruguay --funcion-sql <archivo>» y pegalo en una migración nueva, o restaurá el JSON`);
  const literal = texto.match(/\$catalogo\$([\s\S]*)\$catalogo\$::jsonb/)[1];
  assert.deepEqual(JSON.parse(literal), catalogo);
});

test('el publicador corta un paquete por departamento más el de todo Uruguay, con los rectángulos de la lista', async () => {
  const catalogo = await leerCatalogo(ARCHIVO);
  const departamentos = departamentosPublicables(catalogo);
  assert.equal(departamentos.length, 19);
  assert.equal(new Set(departamentos.map((d) => d.slug)).size, 19, 'un archivo por departamento');
  assert.equal(new Set(departamentos.map((d) => d.ambito_id)).size, 19, 'un ámbito por departamento');
  assert.ok(departamentos.every((d) => /^[a-z ]+$/.test(d.ambito_id)), 'el ámbito es el nombre normalizado');
  const uruguay = uruguayPublicable(catalogo);
  for (const d of departamentos) {
    // El país es de la frontera marítima: contiene el rectángulo de cada departamento.
    assert.ok(d.bbox[0] >= uruguay.bbox[0] - 1e-6 && d.bbox[2] <= uruguay.bbox[2] + 1e-6, `${d.nombre} cabe en el rectángulo del país (este-oeste)`);
    assert.ok(d.bbox[1] >= uruguay.bbox[1] - 1e-6 && d.bbox[3] <= uruguay.bbox[3] + 1e-6, `${d.nombre} cabe en el rectángulo del país (norte-sur)`);
  }
});

test('toda ciudad con rectángulo lo tiene bien formado y con su centro adentro (lo que exige la base)', async () => {
  const catalogo = await leerCatalogo(ARCHIVO);
  for (const c of catalogo.ciudades.filter((x) => x.bbox)) {
    const [oeste, sur, este, norte] = c.bbox;
    assert.ok(oeste < este && sur < norte, `${c.nombre}: rectángulo al revés`);
    assert.ok(c.lon >= oeste && c.lon <= este && c.lat >= sur && c.lat <= norte, `${c.nombre}: el centro cae afuera`);
  }
});
