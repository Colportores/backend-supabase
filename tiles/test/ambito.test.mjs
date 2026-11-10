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

test('dos ciudades con rectángulo que darían el mismo paquete (mismo nombre en el mismo departamento) detienen todo y las nombran', () => {
  const conDepartamento = { ...MONTEVIDEO, departamento: 'Montevideo' };
  assert.throws(
    () => ciudadesPublicables([conDepartamento, { ...conDepartamento, id: ID_3, nombre: 'MONTEVIDEO', departamento: 'MONTEVIDEO' }]),
    new RegExp(`mismo paquete «montevideo-montevideo».*${ID_1}.*${ID_3}.*Dejá una sola.*No se subió nada`, 's'),
  );
  // Si una de las dos no tiene rectángulo, no hay choque: solo se publica la que lo tiene.
  const { publicables } = ciudadesPublicables([MONTEVIDEO, { ...SALTO_SIN_RECTANGULO, id: ID_3, nombre: 'Montevideo' }]);
  assert.equal(publicables.length, 1);
});

const LA_PAZ_CANELONES = { ...MONTEVIDEO, id: ID_2, nombre: 'La Paz', departamento: 'Canelones' };
const LA_PAZ_COLONIA = { ...MONTEVIDEO, id: ID_3, nombre: 'La Paz', departamento: 'Colonia' };

test('dos ciudades del mismo nombre en distintos departamentos se publican las dos: su paquete suma el departamento (#259)', () => {
  const { publicables } = ciudadesPublicables([MONTEVIDEO, LA_PAZ_CANELONES, LA_PAZ_COLONIA]);
  assert.deepEqual(
    publicables.map((c) => [c.ciudad_id, c.slug, c.nombre]),
    [
      [ID_1, 'montevideo', 'Montevideo'],
      [ID_2, 'la-paz-canelones', 'La Paz'],
      [ID_3, 'la-paz-colonia', 'La Paz'],
    ],
  );
  // El departamento se normaliza como el nombre: sin tildes, en minúsculas y con guiones.
  const tilde = ciudadesPublicables([
    { ...LA_PAZ_CANELONES, nombre: 'Cerro Chato', departamento: 'Paysandú' },
    { ...LA_PAZ_COLONIA, nombre: 'Cerro Chato', departamento: 'Treinta y Tres' },
  ]).publicables;
  assert.deepEqual(tilde.map((c) => c.slug), ['cerro-chato-paysandu', 'cerro-chato-treinta-y-tres']);
});

test('una ciudad sin homónima conserva el paquete de siempre, aunque tenga departamento: lo ya publicado no cambia de nombre', () => {
  const { publicables } = ciudadesPublicables([{ ...MONTEVIDEO, departamento: 'Montevideo' }, LA_PAZ_CANELONES]);
  assert.deepEqual(publicables.map((c) => c.slug), ['montevideo', 'la-paz']);
});

test('una homónima sin rectángulo no cuenta: la que lo tiene conserva su paquete sin el departamento', () => {
  const { publicables, sinRectangulo } = ciudadesPublicables([
    LA_PAZ_CANELONES,
    { ...LA_PAZ_COLONIA, bbox_oeste: null, bbox_sur: null, bbox_este: null, bbox_norte: null },
  ]);
  assert.deepEqual(publicables.map((c) => c.slug), ['la-paz']);
  assert.deepEqual(sinRectangulo, ['La Paz']);
});

test('dos homónimas y a una le falta el departamento: se detiene antes de subir nada y dice cómo cargarlo', () => {
  for (const vacio of [null, undefined, '', '  ']) {
    assert.throws(
      () => ciudadesPublicables([LA_PAZ_CANELONES, { ...LA_PAZ_COLONIA, departamento: vacio }]),
      new RegExp(`2 ciudades con rectángulo que se llaman «La Paz» y ${ID_3} no tiene departamento.*Cargá el departamento de la ciudad.*No se subió nada`, 's'),
      `departamento ${JSON.stringify(vacio)}`,
    );
  }
});

test('todo el catálogo de OSM de Uruguay (0109) da un paquete distinto por ciudad: el publicador no se frena por los nombres repetidos (#259)', async () => {
  const { readFile } = await import('node:fs/promises');
  const catalogo = JSON.parse(await readFile(new URL('../datos/uruguay-osm.json', import.meta.url), 'utf8'));
  const filas = catalogo.ciudades.map((c, i) => ({
    id: `09990000-0000-7000-8004-${String(i).padStart(12, '0')}`,
    nombre: c.nombre,
    departamento: c.departamento,
    bbox_oeste: c.bbox?.[0] ?? null,
    bbox_sur: c.bbox?.[1] ?? null,
    bbox_este: c.bbox?.[2] ?? null,
    bbox_norte: c.bbox?.[3] ?? null,
  }));
  const { publicables } = ciudadesPublicables(filas);
  assert.equal(publicables.length, catalogo.ciudades.filter((c) => c.bbox).length);
  assert.equal(new Set(publicables.map((c) => c.slug)).size, publicables.length);
  const repetidas = publicables.filter((c) => c.nombre === 'Las Piedras').map((c) => c.slug).sort();
  assert.deepEqual(repetidas, ['las-piedras-artigas', 'las-piedras-canelones']);
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
  for (const c of ['id', 'nombre', 'departamento', 'bbox_oeste', 'bbox_sur', 'bbox_este', 'bbox_norte']) assert.ok(columnas.includes(c), `pide ${c}`);
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
