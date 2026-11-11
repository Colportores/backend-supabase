import assert from 'node:assert/strict';
import { test } from 'node:test';
import { MAX_BYTES, ZOOM_PISO, ZOOM_TOPE, partirBbox, planificar } from '../src/politica.mjs';

const MONTEVIDEO = [-56.433, -34.945, -55.948, -34.701];

/** Un `medir` de mentira: el tamaño depende solo del zoom y de qué fracción del bbox original cubre. */
function medidorDe(bytesPorZoom, original = MONTEVIDEO) {
  const area = ([o, s, e, n]) => (e - o) * (n - s);
  const llamadas = [];
  const medir = async (bbox, zoom) => {
    llamadas.push({ bbox, zoom });
    return Math.round(bytesPorZoom[zoom] * (area(bbox) / area(original)));
  };
  return { medir, llamadas };
}

test('la ciudad que entra con el zoom máximo se publica con ese zoom, y se mide una sola vez', async () => {
  const { medir, llamadas } = medidorDe({ 15: 10_920_234, 14: 3_500_000 });
  const plan = await planificar(MONTEVIDEO, medir);
  assert.equal(plan.partes.length, 1);
  assert.equal(plan.partes[0].zoom_max, ZOOM_TOPE);
  assert.equal(plan.partes[0].bytes, 10_920_234);
  assert.equal(llamadas.length, 1);
});

test('si pasa de 50 MB baja el zoom máximo de a uno', async () => {
  const { medir } = medidorDe({ 15: 80_000_000, 14: 30_000_000 });
  const plan = await planificar(MONTEVIDEO, medir);
  assert.deepEqual(
    plan.partes.map((p) => [p.zoom_max, p.bytes]),
    [[14, 30_000_000]],
  );
});

test('exactamente 50 MB entra; un byte más, no', async () => {
  const justo = await planificar(MONTEVIDEO, async () => MAX_BYTES);
  assert.equal(justo.partes[0].zoom_max, ZOOM_TOPE);
  const pasado = await planificar(MONTEVIDEO, async (bbox) => (bbox === MONTEVIDEO ? MAX_BYTES + 1 : 1000));
  assert.equal(pasado.partes.length, 2);
});

test('si no entra ni en el piso, se parte en dos archivos con el mismo zoom y sin dejar huecos', async () => {
  const { medir } = medidorDe({ 15: 300_000_000, 14: 90_000_000 });
  const plan = await planificar(MONTEVIDEO, medir);
  assert.equal(plan.partes.length, 2);
  assert.equal(new Set(plan.partes.map((p) => p.zoom_max)).size, 1, 'las dos partes con el mismo zoom');
  assert.equal(plan.partes[0].zoom_max, ZOOM_PISO);
  const [a, b] = plan.partes.map((p) => p.bbox);
  const union = [Math.min(a[0], b[0]), Math.min(a[1], b[1]), Math.max(a[2], b[2]), Math.max(a[3], b[3])];
  assert.deepEqual(union, MONTEVIDEO);
  assert.ok(plan.partes.every((p) => p.bytes <= MAX_BYTES));
});

test('partida, busca el zoom más alto en el que las dos mitades entran', async () => {
  // Entera nunca entra; cada mitad pesa la mitad: a zoom 15 son 60 MB (no), a zoom 14 son 40 MB (sí).
  const { medir } = medidorDe({ 15: 120_000_000, 14: 80_000_000 });
  const plan = await planificar(MONTEVIDEO, medir);
  assert.equal(plan.partes.length, 2);
  assert.equal(plan.partes[0].zoom_max, 14);
});

test('si ni partida entra, falla en voz alta (no son tres archivos: eso lo decide Cristian)', async () => {
  const { medir } = medidorDe({ 15: 900_000_000, 14: 600_000_000 });
  await assert.rejects(planificar(MONTEVIDEO, medir), /No entra en 50000000 bytes ni partido en dos/);
});

test('partirBbox corta por el lado más largo, en metros y no en grados', () => {
  // Más ancho que alto: corta en longitud.
  const [oeste, este] = partirBbox([-57, -35, -55, -34.5]);
  assert.deepEqual(oeste, [-57, -35, -56, -34.5]);
  assert.deepEqual(este, [-56, -35, -55, -34.5]);
  // Más alto que ancho: corta en latitud.
  const [sur, norte] = partirBbox([-56, -36, -55.9, -34]);
  assert.deepEqual(sur, [-56, -36, -55.9, -35]);
  assert.deepEqual(norte, [-56, -35, -55.9, -34]);
  // 1° de longitud mide ~0,82 de 1° de latitud a esta latitud: un cuadrado en grados es más alto en metros que ancho.
  const [abajo, arriba] = partirBbox([-56, -35, -55, -34]);
  assert.deepEqual(abajo, [-56, -35, -55, -34.5]);
  assert.deepEqual(arriba, [-56, -34.5, -55, -34]);
});

test('un piso mayor que el tope es un error de configuración', async () => {
  await assert.rejects(planificar(MONTEVIDEO, async () => 1, { zoomPiso: 16, zoomTope: 15 }), /zoomPiso/);
});
