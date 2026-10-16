import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { test } from 'node:test';
import {
  archivosDe,
  armarPaquete,
  catalogoVacio,
  fusionar as fusionarSuelto,
  obsoletos,
  podarRetirados,
  rutaArchivo,
  validar,
  versionDe,
} from '../src/catalogo.mjs';

const AHORA = '2026-10-07T12:00:00Z';
const AMBITO = '09990000-0000-7000-8003-000000000001';
const ESTILO_VERSION = 'e'.repeat(64);
const sha = (c) => c.repeat(64).slice(0, 64);

// Casi todos los tests quieren un catálogo con la versión del estilo ya puesta.
const fusionar = (previo, nuevos, opciones) => fusionarSuelto(previo, nuevos, { estiloVersion: ESTILO_VERSION, ...opciones });

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
    ambitoId: AMBITO,
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

test('el estilo lleva su versión en el catálogo, y validar la exige (como la de los paquetes)', () => {
  const sin = fusionarSuelto(null, [paquete()], { ahora: AHORA });
  assert.match(validar(sin).join('\n'), /estilo\.version/);
  const con = fusionarSuelto(null, [paquete()], { ahora: AHORA, estiloVersion: ESTILO_VERSION });
  assert.equal(con.estilo.version, ESTILO_VERSION);
  assert.deepEqual(validar(con), []);
  const corta = { ...con, estilo: { ...con.estilo, version: 'abc' } };
  assert.match(validar(corta).join('\n'), /estilo\.version/, 'tiene que ser un SHA-256');
});

test('fusionar conserva la versión del estilo del catálogo previo si no llega una nueva, y la reemplaza si llega', () => {
  const v1 = fusionarSuelto(null, [paquete()], { ahora: AHORA, estiloVersion: ESTILO_VERSION });
  const igual = fusionarSuelto(v1, [paquete()], { ahora: '2026-10-08T12:00:00Z' });
  assert.equal(igual.estilo.version, ESTILO_VERSION);
  const nueva = fusionarSuelto(v1, [], { ahora: '2026-10-09T12:00:00Z', estiloVersion: 'f'.repeat(64) });
  assert.equal(nueva.estilo.version, 'f'.repeat(64));
  assert.equal(nueva.estilo.url, v1.estilo.url);
});

test('un paquete de ciudad sin ambito_id no es válido (la app elige su paquete por ahí)', () => {
  const sinAmbito = fusionar(null, [paquete({ ambitoId: null })], { ahora: AHORA });
  assert.match(validar(sinAmbito).join('\n'), /ciudad-montevideo: ambito_id falta/);
  assert.deepEqual(validar(sinAmbito, { exigirAmbito: false }), [], 'solo un simulacro sin clave lo deja pasar');
});

test('un paquete de ciudad lleva nivel, ámbito, tamaño, SHA-256 y partes', () => {
  const p = paquete();
  assert.equal(p.id, 'ciudad-montevideo');
  assert.equal(p.nivel, 'ciudad');
  assert.equal(p.ambito_id, AMBITO);
  assert.equal(p.tamano_bytes, 10_920_234);
  assert.equal(p.version, sha('a'));
  assert.equal(p.partes.length, 1);
  assert.equal(p.partes[0].sha256, sha('a'));
});

test('un paquete de zona no puede estar en el catálogo: es público y el archivo de una zona muestra su rectángulo', () => {
  // Decisión de Cristian del 06/10, «Zona pública»: el enlace de cada zona va en public.zona.paquete_mapa.
  const zona = armarPaquete({
    nivel: 'zona',
    clave: '09990000-0000-7000-8003-000000000001',
    ambitoId: '09990000-0000-7000-8003-000000000001',
    zoomMax: 15,
    partes: [parte('c', 4_000_000, 'zona', '09990000-0000-7000-8003-000000000001')],
    build: '20261006',
    ahora: AHORA,
  });
  const errores = validar(fusionar(null, [paquete(), zona], { ahora: AHORA }));
  assert.equal(errores.length, 1);
  assert.match(errores[0], /paquete zona-09990000.*los paquetes de zona no van en el catálogo público.*public\.zona\.paquete_mapa/);
  assert.deepEqual(validar(fusionar(null, [paquete()], { ahora: AHORA })), [], 'y uno de ciudad sigue siendo válido');
});

test('el tamaño de un paquete es la suma de sus partes', () => {
  const p = paquete({ partes: [parte('a', 30_000_000), parte('b', 20_000_000)] });
  assert.equal(p.tamano_bytes, 50_000_000);
  assert.equal(p.version, versionDe(p.partes));
});

test('fusionar reemplaza al paquete de su mismo id, conserva el resto y ordena por nivel', () => {
  const previo = fusionar(null, [paquete(), paquete({ clave: 'salto', nombre: 'Salto' })], { ahora: AHORA });
  const departamento = armarPaquete({
    nivel: 'departamento',
    clave: 'montevideo',
    ambitoId: 'd1',
    zoomMax: 12,
    partes: [parte('d', 1_000_000, 'departamento', 'montevideo')],
    build: '20261006',
    ahora: AHORA,
  });
  const nuevo = fusionar(previo, [departamento, paquete({ partes: [parte('e')] })], { ahora: '2026-10-08T00:00:00Z' });
  assert.deepEqual(
    nuevo.paquetes.map((p) => p.id),
    ['ciudad-montevideo', 'ciudad-salto', 'departamento-montevideo'],
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
  assert.deepEqual(validar({ ...catalogoVacio(AHORA), estilo: { ...catalogoVacio(AHORA).estilo, version: ESTILO_VERSION } }), []);
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

  const retiradoVigente = base();
  retiradoVigente.retirados = [{ archivo: retiradoVigente.paquetes[0].partes[0].archivo, desde: AHORA }];
  assert.match(validar(retiradoVigente).join('\n'), /retirado y a la vez en un paquete/);

  const retiradoSinFecha = base();
  retiradoSinFecha.retirados = [{ archivo: 'paquetes/ciudad/montevideo.viejo.pmtiles', desde: 'hace una semana' }];
  assert.match(validar(retiradoSinFecha).join('\n'), /desde debe ser una fecha/);

  const retiradoAbsoluto = base();
  retiradoAbsoluto.retirados = [{ archivo: '/paquetes/x.pmtiles', desde: AHORA }];
  assert.match(validar(retiradoAbsoluto).join('\n'), /ruta relativa/);

  const retiradosMal = base();
  retiradosMal.retirados = 'ninguno';
  assert.match(validar(retiradosMal).join('\n'), /retirados debe ser una lista/);
});

test('un archivo que nunca figuró en un catálogo se borra pasados 7 días desde que se subió', () => {
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

test('fusionar anota qué archivos salieron del catálogo y desde cuándo', () => {
  const v1 = fusionar(null, [paquete({ partes: [parte('a')] })], { ahora: AHORA });
  assert.deepEqual(v1.retirados, [], 'la primera publicación no retira nada');

  const AHORA2 = '2026-11-06T12:00:00Z';
  const v2 = fusionar(v1, [paquete({ partes: [parte('b')] })], { ahora: AHORA2 });
  assert.deepEqual(v2.retirados, [{ archivo: parte('a').archivo, desde: AHORA2 }]);

  // Una publicación posterior que no cambia nada conserva la fecha en que salió: no se «rejuvenece».
  const v3 = fusionar(v2, [], { ahora: '2026-11-10T12:00:00Z' });
  assert.deepEqual(v3.retirados, [{ archivo: parte('a').archivo, desde: AHORA2 }]);

  // Y si el archivo vuelve a estar en un paquete, deja de estar retirado (y el que sale queda anotado).
  const v4 = fusionar(v3, [paquete({ partes: [parte('a')] })], { ahora: '2026-11-11T12:00:00Z' });
  assert.deepEqual(v4.retirados, [{ archivo: parte('b').archivo, desde: '2026-11-11T12:00:00Z' }]);

  // Sacar un paquete entero (quitar) también retira sus archivos.
  const dos = fusionar(null, [paquete(), paquete({ clave: 'salto', partes: [parte('s', 1_000, 'ciudad', 'salto')] })], { ahora: AHORA });
  const sinSalto = fusionar(dos, [], { quitar: ['ciudad-salto'], ahora: AHORA2 });
  assert.deepEqual(sinSalto.retirados, [{ archivo: parte('s', 1_000, 'ciudad', 'salto').archivo, desde: AHORA2 }]);
});

test('el período de gracia corre desde que el archivo salió del catálogo, no desde que se subió', () => {
  const v1 = fusionar(null, [paquete({ partes: [parte('a')] })], { ahora: '2026-10-07T12:00:00Z' });
  const salio = '2026-11-06T12:00:00Z';
  const v2 = fusionar(v1, [paquete({ partes: [parte('b')] })], { ahora: salio });
  const viejo = parte('a').archivo;
  // Se subió el 07/10 (30 días antes de que lo reemplacen): por su fecha de subida ya «vencería».
  const publicados = [
    { ruta: viejo, actualizado_en: '2026-10-07T12:00:00Z' },
    { ruta: parte('b').archivo, actualizado_en: salio },
  ];

  assert.deepEqual(obsoletos(publicados, v2, { ahora: salio }), [], 'el día que sale, se queda');
  assert.deepEqual(obsoletos(publicados, v2, { ahora: '2026-11-13T11:59:59Z' }), [], 'a los 6 días y 23 h, se queda');
  assert.deepEqual(obsoletos(publicados, v2, { ahora: '2026-11-13T12:00:01Z' }), [viejo], 'recién pasados 7 días fuera del catálogo, se va');
});

test('podarRetirados olvida lo que se borró y lo que ya no está en el bucket', () => {
  const catalogo = {
    ...fusionar(null, [paquete()], { ahora: AHORA }),
    retirados: [
      { archivo: 'paquetes/ciudad/a.pmtiles', desde: AHORA },
      { archivo: 'paquetes/ciudad/b.pmtiles', desde: AHORA },
      { archivo: 'paquetes/ciudad/c.pmtiles', desde: AHORA },
    ],
  };
  const podado = podarRetirados(catalogo, {
    borrados: ['paquetes/ciudad/a.pmtiles'],
    publicados: [{ ruta: 'paquetes/ciudad/a.pmtiles' }, { ruta: 'paquetes/ciudad/b.pmtiles' }],
  });
  assert.deepEqual(podado.retirados.map((r) => r.archivo), ['paquetes/ciudad/b.pmtiles']);
});
