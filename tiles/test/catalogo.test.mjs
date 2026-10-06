import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { test } from 'node:test';
import {
  archivosDe,
  armarPaquete,
  catalogoVacio,
  fusionar,
  obsoletos,
  rutaArchivo,
  validar,
  versionDe,
} from '../src/catalogo.mjs';

const AHORA = '2026-10-07T12:00:00Z';
const sha = (c) => c.repeat(64).slice(0, 64);

function parte(letra, bytes = 10_920_234, nivel = 'ciudad', clave = 'montevideo') {
  return {
    archivo: rutaArchivo({ nivel, clave, sha256: sha(letra) }),
    tamano_bytes: bytes,
    sha256: sha(letra),
  };
}

function paquete(sobrescribir = {}) {
  return armarPaquete({
    nivel: 'ciudad',
    clave: 'montevideo',
    ambitoId: null,
    nombre: 'Montevideo',
    bbox: [-56.433, -34.945, -55.948, -34.701],
    zoomMax: 15,
    partes: [parte('a')],
    build: '20261006',
    ahora: AHORA,
    ...sobrescribir,
  });
}

test('el archivo lleva el SHA-256 en el nombre: un contenido distinto nunca pisa a otro', () => {
  assert.equal(
    rutaArchivo({ nivel: 'ciudad', clave: 'montevideo', sha256: sha('a') }),
    'paquetes/ciudad/montevideo.aaaaaaaaaaaa.pmtiles',
  );
  assert.equal(
    rutaArchivo({ nivel: 'ciudad', clave: 'salto', parte: 2, total: 2, sha256: sha('b') }),
    'paquetes/ciudad/salto.parte2de2.bbbbbbbbbbbb.pmtiles',
  );
});

test('la versión de un paquete de un archivo es su SHA-256; la de varios, el de sus SHA-256 en orden', () => {
  assert.equal(versionDe([{ sha256: sha('a') }]), sha('a'));
  const dos = versionDe([{ sha256: sha('a') }, { sha256: sha('b') }]);
  assert.equal(dos, createHash('sha256').update(`${sha('a')}\n${sha('b')}`).digest('hex'));
  assert.notEqual(dos, versionDe([{ sha256: sha('b') }, { sha256: sha('a') }]), 'el orden importa');
});

test('un paquete de ciudad lleva nivel, ámbito, tamaño, SHA-256 y partes', () => {
  const p = paquete();
  assert.equal(p.id, 'ciudad-montevideo');
  assert.equal(p.nivel, 'ciudad');
  assert.equal(p.ambito_id, null);
  assert.equal(p.tamano_bytes, 10_920_234);
  assert.equal(p.version, sha('a'));
  assert.equal(p.partes.length, 1);
  assert.equal(p.partes[0].sha256, sha('a'));
});

test('un paquete de zona no publica nombre ni bbox: el catálogo es público', () => {
  const p = armarPaquete({
    nivel: 'zona',
    clave: '09990000-0000-7000-8003-000000000001',
    ambitoId: '09990000-0000-7000-8003-000000000001',
    zoomMax: 15,
    partes: [parte('c', 4_000_000, 'zona', '09990000-0000-7000-8003-000000000001')],
    build: '20261006',
    ahora: AHORA,
  });
  assert.equal('nombre' in p, false);
  assert.equal('bbox' in p, false);
});

test('el tamaño de un paquete es la suma de sus partes', () => {
  const p = paquete({ partes: [parte('a', 30_000_000), parte('b', 20_000_000)] });
  assert.equal(p.tamano_bytes, 50_000_000);
  assert.equal(p.version, versionDe(p.partes));
});

test('fusionar reemplaza al paquete de su mismo id, conserva el resto y ordena por nivel', () => {
  const previo = fusionar(null, [paquete(), paquete({ clave: 'salto', nombre: 'Salto' })], { ahora: AHORA });
  const zona = armarPaquete({
    nivel: 'zona',
    clave: 'z1',
    ambitoId: 'z1',
    zoomMax: 15,
    partes: [parte('d', 1_000_000, 'zona', 'z1')],
    build: '20261006',
    ahora: AHORA,
  });
  const nuevo = fusionar(previo, [zona, paquete({ partes: [parte('e')] })], { ahora: '2026-10-08T00:00:00Z' });
  assert.deepEqual(
    nuevo.paquetes.map((p) => p.id),
    ['zona-z1', 'ciudad-montevideo', 'ciudad-salto'],
  );
  assert.equal(nuevo.paquetes.find((p) => p.id === 'ciudad-montevideo').version, sha('e'));
  assert.equal(nuevo.generado_en, '2026-10-08T00:00:00Z');
});

test('fusionar puede sacar paquetes', () => {
  const previo = fusionar(null, [paquete(), paquete({ clave: 'salto' })], { ahora: AHORA });
  const nuevo = fusionar(previo, [], { quitar: ['ciudad-salto'], ahora: AHORA });
  assert.deepEqual(nuevo.paquetes.map((p) => p.id), ['ciudad-montevideo']);
});

test('un catálogo bien armado valida', () => {
  assert.deepEqual(validar(fusionar(null, [paquete()], { ahora: AHORA })), []);
  assert.deepEqual(validar(catalogoVacio(AHORA)), []);
});

test('validar rechaza lo que la app no podría usar', () => {
  const base = () => fusionar(null, [paquete()], { ahora: AHORA });

  const grande = base();
  grande.paquetes[0].partes[0].tamano_bytes = 50_000_001;
  grande.paquetes[0].tamano_bytes = 50_000_001;
  assert.match(validar(grande).join('\n'), /el tope es 50000000/);

  const suma = base();
  suma.paquetes[0].tamano_bytes += 1;
  assert.match(validar(suma).join('\n'), /no es la suma de sus partes/);

  const absoluta = base();
  absoluta.paquetes[0].partes[0].archivo = '/paquetes/x.pmtiles';
  assert.match(validar(absoluta).join('\n'), /ruta relativa/);

  const arriba = base();
  arriba.paquetes[0].partes[0].archivo = '../secreto.pmtiles';
  assert.match(validar(arriba).join('\n'), /ruta relativa/);

  const hash = base();
  hash.paquetes[0].partes[0].sha256 = 'XYZ';
  assert.match(validar(hash).join('\n'), /sha256 inválido/);

  const version = base();
  version.paquetes[0].version = sha('f');
  assert.match(validar(version).join('\n'), /version no coincide/);

  const nivel = base();
  nivel.paquetes[0].nivel = 'barrio';
  assert.match(validar(nivel).join('\n'), /nivel inválido/);

  const repetido = base();
  repetido.paquetes.push(structuredClone(repetido.paquetes[0]));
  assert.match(validar(repetido).join('\n'), /id repetido/);

  const sinPartes = base();
  sinPartes.paquetes[0].partes = [];
  assert.match(validar(sinPartes).join('\n'), /sin partes/);

  const fecha = base();
  fecha.generado_en = 'ayer';
  assert.match(validar(fecha).join('\n'), /generado_en/);
});

test('un archivo obsoleto se borra solo pasado el período de gracia de 7 días', () => {
  const catalogo = fusionar(null, [paquete()], { ahora: AHORA });
  const vigente = catalogo.paquetes[0].partes[0].archivo;
  assert.deepEqual([...archivosDe(catalogo)], [vigente]);

  const publicados = [
    { ruta: vigente, actualizado_en: '2026-01-01T00:00:00Z' },
    { ruta: 'paquetes/ciudad/montevideo.viejo.pmtiles', actualizado_en: '2026-09-01T00:00:00Z' },
    { ruta: 'paquetes/ciudad/montevideo.reciente.pmtiles', actualizado_en: '2026-10-05T00:00:00Z' },
  ];
  assert.deepEqual(obsoletos(publicados, catalogo, { ahora: AHORA }), ['paquetes/ciudad/montevideo.viejo.pmtiles']);
});
