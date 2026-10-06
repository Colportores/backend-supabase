import assert from 'node:assert/strict';
import { test } from 'node:test';
import { asignarAmbitos, leerCiudades, normalizar } from '../src/ambito.mjs';

const MONTEVIDEO = { slug: 'montevideo', nombre: 'Montevideo', bbox: [-56.433, -34.945, -55.948, -34.701] };
const ID_1 = '09990000-0000-7000-8003-000000000001';
const ID_2 = '09990000-0000-7000-8003-000000000002';

test('normalizar compara nombres sin tildes, sin mayúsculas y con los espacios normalizados', () => {
  assert.equal(normalizar('  Paysandú '), 'paysandu');
  assert.equal(normalizar('SAN   JOSÉ'), 'san jose');
});

test('asignarAmbitos completa el ciudad_id con el id de la ciudad de la base (por nombre)', () => {
  const [ciudad] = asignarAmbitos([MONTEVIDEO], [
    { id: ID_2, nombre: 'Salto' },
    { id: ID_1, nombre: 'MONTEVIDEO' },
  ]);
  assert.equal(ciudad.ciudad_id, ID_1);
  assert.equal(ciudad.slug, 'montevideo', 'el resto de la ciudad queda como estaba');
});

test('si la ciudad no está en la base, se detiene y dice cuál es: nunca queda un ambito_id nulo', () => {
  assert.throws(() => asignarAmbitos([MONTEVIDEO], [{ id: ID_2, nombre: 'Salto' }]), /«Montevideo».*no está en public\.ciudad.*No se subió nada/s);
  assert.throws(() => asignarAmbitos([MONTEVIDEO], []), /«Montevideo».*no está en public\.ciudad/s);
});

test('si hay más de una ciudad con ese nombre, se detiene y las nombra', () => {
  assert.throws(
    () =>
      asignarAmbitos([MONTEVIDEO], [
        { id: ID_1, nombre: 'Montevideo' },
        { id: ID_2, nombre: 'montevideo' },
      ]),
    new RegExp(`2 ciudades llamadas «Montevideo».*${ID_1}.*${ID_2}`, 's'),
  );
});

test('leerCiudades pide a PostgREST las ciudades de Uruguay no borradas, con la clave de servicio', async () => {
  let pedido;
  const filas = [{ id: ID_1, nombre: 'Montevideo' }];
  const fetchImpl = async (url, opciones) => {
    pedido = { url: new URL(url), opciones };
    return new Response(JSON.stringify(filas), { status: 200 });
  };
  const leidas = await leerCiudades({ url: 'https://proyecto.supabase.co/', clave: 'CLAVE-DE-SERVICIO', fetchImpl });
  assert.deepEqual(leidas, filas);
  assert.equal(pedido.url.origin + pedido.url.pathname, 'https://proyecto.supabase.co/rest/v1/ciudad');
  assert.equal(pedido.url.searchParams.get('pais.iso_code'), 'eq.UY');
  assert.equal(pedido.url.searchParams.get('deleted_at'), 'is.null');
  assert.equal(pedido.opciones.headers.authorization, 'Bearer CLAVE-DE-SERVICIO');
  assert.equal(pedido.opciones.headers.apikey, 'CLAVE-DE-SERVICIO');
});

test('leerCiudades dice qué falló, con el estado HTTP', async () => {
  const fetchImpl = async () => new Response('permission denied for table ciudad', { status: 403 });
  await assert.rejects(leerCiudades({ url: 'https://p.supabase.co', clave: 'x'.repeat(20), fetchImpl }), /public\.ciudad falló: 403 permission denied/);
  const sinRed = async () => {
    throw Object.assign(new Error('fetch failed'), { cause: { code: 'ECONNREFUSED' } });
  };
  await assert.rejects(leerCiudades({ url: 'https://p.supabase.co', clave: 'x'.repeat(20), fetchImpl: sinRed }), /ECONNREFUSED/);
});
