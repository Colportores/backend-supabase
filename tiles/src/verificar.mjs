// Prueba, contra el bucket público (sin ninguna credencial), lo que la app y el panel van a necesitar:
//   - el catálogo y el estilo se leen sin login y son válidos;
//   - cada paquete contesta Range con 206 y empieza con la firma de PMTiles;
//   - hay CORS para localhost y para GitHub Pages, también en el preflight que manda el navegador
//     cuando el pedido lleva Range (más If-Match, como pmtiles.js).
// Es el «humo» que corre el workflow después de publicar y que se puede correr a mano:
//   node src/cli.mjs verificar

import { validar } from './catalogo.mjs';

/** Orígenes que tienen que poder leer el bucket desde un navegador: desarrollo local y GitHub Pages. */
export const ORIGENES = ['http://localhost:3000', 'https://colportores.github.io'];

const FIRMA_PMTILES = 'PMTiles';

export async function verificar({ urlPublica, fetchFn = fetch, origenes = ORIGENES }) {
  const base = urlPublica.replace(/\/+$/, '');
  const resultados = [];
  const ok = (que, detalle = '') => resultados.push({ ok: true, que, detalle });
  const falla = (que, detalle) => resultados.push({ ok: false, que, detalle });
  const aviso = (que, detalle) => resultados.push({ ok: true, aviso: true, que, detalle });

  async function pedir(ruta, { metodo = 'GET', origen, range, cabeceras = {} } = {}) {
    const headers = { ...cabeceras };
    if (origen) headers.origin = origen;
    if (range) headers.range = range;
    return fetchFn(`${base}/${ruta}`, { method: metodo, headers });
  }

  function exigirCors(respuesta, ruta, origen) {
    const permitido = respuesta.headers.get('access-control-allow-origin');
    if (permitido === '*' || permitido === origen) ok(`CORS ${origen} → ${ruta}`);
    else falla(`CORS ${origen} → ${ruta}`, `access-control-allow-origin: ${permitido ?? '(falta)'}`);
  }

  // --- catálogo -----------------------------------------------------------------------
  let catalogo = null;
  const rCatalogo = await pedir('catalogo.json', { origen: origenes[0] });
  if (rCatalogo.status !== 200) {
    falla('catalogo.json se lee sin login', `HTTP ${rCatalogo.status}`);
    return resultados;
  }
  ok('catalogo.json se lee sin login');
  try {
    catalogo = await rCatalogo.json();
  } catch {
    falla('catalogo.json es JSON', 'no se pudo parsear');
    return resultados;
  }
  const errores = validar(catalogo);
  if (errores.length === 0) ok(`catalogo.json es válido (${catalogo.paquetes.length} paquetes)`);
  else falla('catalogo.json es válido', errores.join('; '));
  for (const origen of origenes) {
    const r = await pedir('catalogo.json', { origen });
    await r.arrayBuffer();
    exigirCors(r, 'catalogo.json', origen);
  }

  // --- estilo, glyphs y sprites -----------------------------------------------------------
  const rEstilo = await pedir(catalogo.estilo?.url ?? 'estilo/colportores.json', { origen: origenes[0] });
  if (rEstilo.status !== 200) {
    falla('el estilo se lee sin login', `HTTP ${rEstilo.status}`);
  } else {
    const estilo = await rEstilo.json().catch(() => null);
    if (!estilo?.layers?.length) {
      falla('el estilo tiene capas', 'sin layers');
    } else {
      ok(`el estilo se lee sin login (${estilo.layers.length} capas)`);
      for (const [campo, plantilla] of [
        ['glyphs', estilo.glyphs?.replace('{fontstack}', 'NotoSans-Regular').replace('{range}', '0-255')],
        ['sprite', estilo.sprite ? `${estilo.sprite}.json` : undefined],
        ['sprite@2x', estilo.sprite ? `${estilo.sprite}@2x.png` : undefined],
      ]) {
        if (!plantilla?.startsWith(`${base}/`)) {
          falla(`el estilo apunta a ${campo} del mismo bucket`, String(plantilla));
          continue;
        }
        const r = await pedir(plantilla.slice(base.length + 1), { origen: origenes[0] });
        if (r.status === 200) ok(`${campo} se lee sin login`);
        else falla(`${campo} se lee sin login`, `HTTP ${r.status} en ${plantilla}`);
      }
    }
  }

  // --- paquetes: tamaño, Range, firma -----------------------------------------------------------
  for (const paquete of catalogo.paquetes ?? []) {
    for (const [i, parte] of paquete.partes.entries()) {
      const etiqueta = `${paquete.id}${paquete.partes.length > 1 ? ` parte ${i + 1}` : ''}`;
      const cabeza = await pedir(parte.archivo, { metodo: 'HEAD', origen: origenes[0] });
      if (cabeza.status !== 200) {
        falla(`${etiqueta}: existe`, `HTTP ${cabeza.status} en ${parte.archivo}`);
        continue;
      }
      const largo = Number(cabeza.headers.get('content-length'));
      if (largo === parte.tamano_bytes) ok(`${etiqueta}: pesa lo que dice el catálogo (${largo} bytes)`);
      else falla(`${etiqueta}: pesa lo que dice el catálogo`, `catálogo ${parte.tamano_bytes}, servidor ${largo}`);

      const inicio = await pedir(parte.archivo, { origen: origenes[0], range: 'bytes=0-15' });
      const bytes = Buffer.from(await inicio.arrayBuffer());
      if (inicio.status !== 206) {
        falla(`${etiqueta}: Range responde 206`, `HTTP ${inicio.status}`);
      } else {
        ok(`${etiqueta}: Range responde 206`);
        const esperado = `bytes 0-15/${parte.tamano_bytes}`;
        const real = inicio.headers.get('content-range');
        if (real === esperado) ok(`${etiqueta}: Content-Range correcto`);
        else falla(`${etiqueta}: Content-Range correcto`, `esperaba «${esperado}», vino «${real}»`);
        if (bytes.length === 16 && bytes.subarray(0, 7).toString('latin1') === FIRMA_PMTILES) {
          ok(`${etiqueta}: empieza con la firma de PMTiles`);
        } else {
          falla(`${etiqueta}: empieza con la firma de PMTiles`, `primeros bytes: ${bytes.subarray(0, 7).toString('latin1')}`);
        }
      }
      const cola = await pedir(parte.archivo, {
        origen: origenes[0],
        range: `bytes=${parte.tamano_bytes - 8}-${parte.tamano_bytes - 1}`,
      });
      await cola.arrayBuffer();
      if (cola.status === 206) ok(`${etiqueta}: Range sobre el final responde 206`);
      else falla(`${etiqueta}: Range sobre el final responde 206`, `HTTP ${cola.status}`);

      for (const origen of origenes) {
        // Preflight: el navegador lo manda antes de un GET con Range + If-Match (pmtiles.js).
        const previo = await pedir(parte.archivo, {
          metodo: 'OPTIONS',
          origen,
          cabeceras: { 'access-control-request-method': 'GET', 'access-control-request-headers': 'range, if-match' },
        });
        await previo.arrayBuffer();
        const permitido = previo.headers.get('access-control-allow-origin');
        const cabecerasOk = (previo.headers.get('access-control-allow-headers') ?? '').toLowerCase();
        const sirve = (cabecera) => cabecerasOk === '*' || cabecerasOk.split(',').map((c) => c.trim()).includes(cabecera);
        if (previo.status >= 200 && previo.status < 300 && (permitido === '*' || permitido === origen) && sirve('range')) {
          ok(`${etiqueta}: preflight ${origen} acepta Range`);
          if (!sirve('if-match')) {
            aviso(`${etiqueta}: preflight ${origen} acepta If-Match`, 'no figura en access-control-allow-headers');
          }
        } else {
          falla(
            `${etiqueta}: preflight ${origen} acepta Range`,
            `HTTP ${previo.status}, access-control-allow-origin: ${permitido ?? '(falta)'}, access-control-allow-headers: ${cabecerasOk || '(falta)'}`,
          );
        }

        const r = await pedir(parte.archivo, { origen, range: 'bytes=0-15' });
        await r.arrayBuffer();
        exigirCors(r, parte.archivo, origen);
        if (origen === origenes[0]) {
          const expuestos = (r.headers.get('access-control-expose-headers') ?? '').toLowerCase();
          if (expuestos !== '*' && !expuestos.includes('content-range')) {
            aviso(
              `${etiqueta}: el navegador puede leer Content-Range`,
              'access-control-expose-headers no lo lista; pmtiles.js no lo necesita, pero conviene saberlo',
            );
          }
        }
      }
    }
  }
  return resultados;
}
