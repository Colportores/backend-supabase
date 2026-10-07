// El bucket `mapas` está definido en tres lados que tienen que decir lo mismo. Si uno cambia y los
// otros no, este test lo avisa en CI.
import assert from 'node:assert/strict';
import { readFile, readdir } from 'node:fs/promises';
import { join } from 'node:path';
import { test } from 'node:test';
import { fileURLToPath } from 'node:url';
import { BUCKET, cacheControlDe, tipoDe } from '../src/bucket.mjs';

const REPO = fileURLToPath(new URL('../..', import.meta.url));

const lista = (texto) => [...texto.matchAll(/'([^']+)'|"([^"]+)"/g)].map((m) => m[1] ?? m[2]);
const leer = async (...partes) => (await readFile(join(REPO, ...partes), 'utf8')).replaceAll('\r\n', '\n');

async function migracion() {
  const dir = join(REPO, 'supabase', 'migrations');
  const archivo = (await readdir(dir)).find((f) => /_0029_bucket_mapas\.sql$/.test(f));
  assert.ok(archivo, 'falta la migración 0029_bucket_mapas');
  return leer('supabase', 'migrations', archivo);
}

test('la migración 0029 crea el bucket como dice bucket.mjs', async () => {
  const sql = await migracion();
  const insert = /insert into storage\.buckets[\s\S]*?on conflict/.exec(sql)?.[0];
  assert.ok(insert, 'no encuentro el insert en storage.buckets');
  assert.match(insert, /'mapas',\s*'mapas',\s*true,/, 'id, name y public = true');
  assert.match(insert, new RegExp(`${BUCKET.file_size_limit},`));
  const mime = /array\[([\s\S]*?)\]/.exec(insert)[1].replace(/--.*$/gm, '');
  assert.deepEqual(lista(mime), [...BUCKET.allowed_mime_types]);
});

test('config.toml tiene el mismo bucket para el Supabase local', async () => {
  const toml = await leer('supabase', 'config.toml');
  const bloque = /^\[storage\.buckets\.mapas\]\n([\s\S]*?)(?=^\[|(?![\s\S]))/m.exec(toml)?.[1];
  assert.ok(bloque, 'falta [storage.buckets.mapas] en config.toml');
  assert.match(bloque, /^public = true$/m);
  assert.match(bloque, /^file_size_limit = "50MiB"$/m);
  const mime = /^allowed_mime_types = \[(.*)\]$/m.exec(bloque)[1];
  assert.deepEqual(lista(mime), [...BUCKET.allowed_mime_types]);
  assert.equal(BUCKET.file_size_limit, 50 * 1024 * 1024);
});

test('la migración no agrega políticas sobre storage.objects: solo escribe la clave de servicio', async () => {
  const sql = (await migracion()).replace(/--.*$/gm, '');
  assert.doesNotMatch(sql, /create policy/i);
  assert.doesNotMatch(sql, /\bgrant\b/i);
});

test('los paquetes (de ciudad y de zona) se cachean un año; el catálogo y el estilo, un minuto', () => {
  const unAnio = 'public, max-age=31536000, immutable';
  assert.equal(cacheControlDe('paquetes/ciudad/montevideo.aaaaaaaaaaaa.pmtiles'), unAnio);
  assert.equal(cacheControlDe(`zonas/${'0123456789abcdef'.repeat(2)}.pmtiles`), unAnio, 'el nombre de una zona es nuevo en cada versión: nunca se reescribe');
  assert.equal(cacheControlDe('catalogo.json'), 'public, max-age=60');
  assert.equal(cacheControlDe('estilo/colportores.json'), 'public, max-age=60');
  assert.equal(cacheControlDe('estilo/glyphs/NotoSans-Regular/0-255.pbf'), 'public, max-age=86400');
  assert.equal(tipoDe(`zonas/${'0123456789abcdef'.repeat(2)}.pmtiles`), 'application/octet-stream');
});
