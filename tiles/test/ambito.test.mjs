import assert from 'node:assert/strict';
import { test } from 'node:test';
import { avisosDeCiudades, ciudadesPublicables, leerCiudades, normalizar, normalizarPais, slugDe } from '../src/ambito.mjs';

const ID_1 = '09990000-0000-7000-8003-000000000001';
const ID_2 = '09990000-0000-7000-8003-000000000002';
const ID_3 = '09990000-0000-7000-8003-000000000003';

const MONTEVIDEO = {
  id: ID_1,
  nombre: 'Montevideo',
  lat_centro: -34.9011,
  lon_centro: -56.1645,
  bbox_oeste: -56.433,
  bbox_sur: -34.945,
  bbox_este: -55.948,
  bbox_norte: -34.701,
};
const SALTO_SIN_RECTANGULO = {
  id: ID_2,
  nombre: 'Salto',
  lat_centro: -31.39,
  lon_centro: -57.96,
  bbox_oeste: null,
  bbox_sur: null,
  bbox_este: null,
  bbox_norte: null,
};

test('normalizar compara nombres sin tildes, sin mayúsculas y con los espacios normalizados', () => {
  assert.equal(normalizar('  Paysandú '), 'paysandu');
  assert.equal(normalizar('SAN   JOSÉ'), 'san jose');
});

test('slugDe arma el nombre del paquete con el nombre de la ciudad: minúsculas, sin tildes, con guiones', () => {
  assert.equal(slugDe('Montevideo'), 'montevideo');
  assert.equal(slugDe('  San José de Mayo '), 'san-jose-de-mayo');
  assert.equal(slugDe('Paysandú (Centro)'), 'paysandu-centro');
  assert.equal(slugDe('¿?'), '');
});

test('se publican las ciudades con rectángulo, con su id de public.ciudad; las que no lo tienen se listan y no se publican', () => {
  const { publicables, sinRectangulo } = ciudadesPublicables([MONTEVIDEO, SALTO_SIN_RECTANGULO]);
  assert.deepEqual(publicables, [
    {
      ciudad_id: ID_1,
      slug: 'montevideo',
      nombre: 'Montevideo',
      bbox: [-56.433, -34.945, -55.948, -34.701],
    },
  ]);
  assert.deepEqual(sinRectangulo, ['Salto']);
});

test('el rectángulo sale en el orden de un bbox: oeste, sur, este, norte', () => {
  const [ciudad] = ciudadesPublicables([{ ...MONTEVIDEO, bbox_oeste: -1, bbox_sur: -2, bbox_este: 3, bbox_norte: 4 }]).publicables;
  assert.deepEqual(ciudad.bbox, [-1, -2, 3, 4]);
});

test('un rectángulo a medias (alguna columna nula) cuenta como sin rectángulo: no se corta con la mitad de un dato', () => {
  const { publicables, sinRectangulo } = ciudadesPublicables([{ ...MONTEVIDEO, bbox_norte: null }]);
  assert.deepEqual(publicables, []);
  assert.deepEqual(sinRectangulo, ['Montevideo']);
});

test('no hay ninguna ciudad con rectángulo: no hay nada que publicar y no es un error', () => {
  assert.deepEqual(ciudadesPublicables([SALTO_SIN_RECTANGULO]), { publicables: [], sinRectangulo: ['Salto'] });
  assert.deepEqual(ciudadesPublicables([]), { publicables: [], sinRectangulo: [] });
});

test('dos ciudades con rectángulo que darían el mismo paquete detienen todo y las nombran', () => {
  assert.throws(
    () => ciudadesPublicables([MONTEVIDEO, { ...MONTEVIDEO, id: ID_3, nombre: 'MONTEVIDEO' }]),
    new RegExp(`mismo paquete «montevideo».*${ID_1}.*${ID_3}.*No se subió nada`, 's'),
  );
  // Si una de las dos no tiene rectángulo, no hay choque: solo se publica la que lo tiene.
  const { publicables } = ciudadesPublicables([MONTEVIDEO, { ...SALTO_SIN_RECTANGULO, id: ID_3, nombre: 'Montevideo' }]);
  assert.equal(publicables.length, 1);
});

test('un nombre sin letras ni números no da un paquete: se detiene antes de subir nada', () => {
  assert.throws(() => ciudadesPublicables([{ ...MONTEVIDEO, nombre: '¿?' }]), /no tiene un nombre con letras o números.*No se subió nada/s);
});

test('los paquetes ya publicados cuya ciudad se dio de baja o perdió el rectángulo se avisan, no se retiran', () => {
  const catalogo = {
    paquetes: [
      { id: 'ciudad-montevideo', nivel: 'ciudad', ambito_id: ID_1 },
      { id: 'ciudad-salto', nivel: 'ciudad', ambito_id: ID_2 },
      { id: 'ciudad-baja', nivel: 'ciudad', ambito_id: ID_3 },
    ],
  };
  const avisos = avisosDeCiudades(catalogo, [MONTEVIDEO, SALTO_SIN_RECTANGULO]);
  assert.equal(avisos.length, 2);
  assert.match(avisos[0], /ciudad-salto sigue en el catálogo.*«Salto» ya no tiene rectángulo/);
  assert.match(avisos[1], new RegExp(`ciudad-baja sigue en el catálogo.*${ID_3}.*ya no está en public\\.ciudad o está dada de baja`));
  // Todo aviso dice qué hacer: sacarlo a propósito (con el id exacto) o volver a dejarlo como estaba.
  assert.match(avisos[0], /Si fue a propósito, sacalo con `publicar --solo ciudades --quitar ciudad-salto`; si no, volvé a cargar su rectángulo \(docs\/guia-carga-manual\.md § 2\)\.$/);
  assert.match(avisos[1], /Si fue a propósito, sacalo con `publicar --solo ciudades --quitar ciudad-baja`; si no, volvé a dejarla viva con su rectángulo/);
  assert.deepEqual(avisosDeCiudades(null, [MONTEVIDEO]), [], 'sin catálogo previo, nada que avisar');
  assert.deepEqual(avisosDeCiudades({ paquetes: [{ id: 'departamento-x', nivel: 'departamento', ambito_id: 'x' }] }, []), [], 'solo las ciudades');
});

test('leerCiudades pide a PostgREST las ciudades de Uruguay no borradas, con su rectángulo y la clave de servicio', async () => {
  let pedido;
  const filas = [MONTEVIDEO];
  const fetchImpl = async (url, opciones) => {
    pedido = { url: new URL(url), opciones };
    return new Response(JSON.stringify(filas), { status: 200 });
  };
  const leidas = await leerCiudades({ url: 'https://proyecto.supabase.co/', clave: 'CLAVE-DE-SERVICIO', fetchImpl });
  assert.deepEqual(leidas, filas);
  assert.equal(pedido.url.origin + pedido.url.pathname, 'https://proyecto.supabase.co/rest/v1/ciudad');
  assert.equal(pedido.url.searchParams.get('pais.iso_code'), 'eq.UY');
  assert.equal(pedido.url.searchParams.get('deleted_at'), 'is.null');
  const columnas = pedido.url.searchParams.get('select').split(',');
  for (const c of ['id', 'nombre', 'bbox_oeste', 'bbox_sur', 'bbox_este', 'bbox_norte']) assert.ok(columnas.includes(c), `pide ${c}`);
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

test('leerCiudades pide las de Uruguay si no se le dice el país, y las del país pedido si se le dice (`ar` se lee `AR`)', async () => {
  const pedidos = [];
  const fetchImpl = async (url) => {
    pedidos.push(new URL(url));
    return new Response('[]', { status: 200 });
  };
  const base = { url: 'https://p.supabase.co', clave: 'x'.repeat(20), fetchImpl };
  await leerCiudades(base);
  await leerCiudades({ ...base, pais: 'AR' });
  await leerCiudades({ ...base, pais: 'ar' });
  assert.deepEqual(pedidos.map((p) => p.searchParams.get('pais.iso_code')), ['eq.UY', 'eq.AR', 'eq.AR']);
  for (const p of pedidos) {
    assert.equal(p.searchParams.get('deleted_at'), 'is.null');
    assert.ok(p.searchParams.get('select').includes('pais!inner(iso_code)'), 'filtra por la tabla pais');
  }
});

test('leerCiudades con `pais: null` pide las ciudades vivas de todos los países, sin filtro de país', async () => {
  let pedido;
  const fetchImpl = async (url) => {
    pedido = new URL(url);
    return new Response(JSON.stringify([MONTEVIDEO]), { status: 200 });
  };
  const leidas = await leerCiudades({ url: 'https://p.supabase.co', clave: 'x'.repeat(20), pais: null, fetchImpl });
  assert.deepEqual(leidas, [MONTEVIDEO]);
  assert.equal(pedido.searchParams.get('pais.iso_code'), null);
  assert.equal(pedido.searchParams.get('deleted_at'), 'is.null');
  assert.ok(!pedido.searchParams.get('select').includes('pais'));
});

for (const invalido of ['A', 'ARG', '1R', '', ' AR', 'A-', 'AR&deleted_at=is.null', undefined]) {
  test(`un país inválido (${JSON.stringify(invalido)}) se rechaza nombrando el valor, antes de leer nada`, async () => {
    let pedidos = 0;
    const fetchImpl = async () => {
      pedidos += 1;
      return new Response('[]');
    };
    assert.throws(() => normalizarPais(invalido), /--pais tiene que ser un código de país de dos letras.*llegó/);
    if (invalido !== undefined) {
      await assert.rejects(leerCiudades({ url: 'https://p.supabase.co', clave: 'x'.repeat(20), pais: invalido, fetchImpl }), (error) => {
        assert.ok(error.message.includes(JSON.stringify(invalido)), error.message);
        return true;
      });
    }
    assert.equal(pedidos, 0, 'no llegó a pedirle nada a la base');
  });
}

test('normalizarPais pasa a mayúsculas el código de dos letras', () => {
  assert.equal(normalizarPais('ar'), 'AR');
  assert.equal(normalizarPais('UY'), 'UY');
});
