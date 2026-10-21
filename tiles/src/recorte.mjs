// Recorte de un PMTiles de Protomaps con el CLI oficial (`pmtiles extract`): lee solo los rangos
// que necesita del archivo del planeta (~140 GB) por HTTP, sin bajarlo.

import { spawn } from 'node:child_process';
import { createHash } from 'node:crypto';
import { createReadStream } from 'node:fs';
import { mkdir, rm, stat, chmod, writeFile } from 'node:fs/promises';
import { arch, platform } from 'node:os';
import { join } from 'node:path';

export const PMTILES_VERSION = '1.31.2';

// SHA-256 del tar.gz de https://github.com/protomaps/go-pmtiles/releases/tag/v1.31.2
// (coincide con el `digest` que GitHub publica para el asset: `gh api repos/protomaps/go-pmtiles/releases/tags/v1.31.2`).
const DESCARGAS = {
  'linux-x64': {
    archivo: `go-pmtiles_${PMTILES_VERSION}_Linux_x86_64.tar.gz`,
    sha256: '3ed7dbf4ec2e6dfe5e25b6f70d1ffc932729f93c86db353bf514dd71010a312f',
  },
};

export const FUENTE_PROTOMAPS = (build) => `https://build.protomaps.com/${build}.pmtiles`;

/** SHA-256 en hexadecimal de un archivo, igual que `sha256sum`. */
export function sha256DeArchivo(ruta) {
  return new Promise((resolver, rechazar) => {
    const hash = createHash('sha256');
    createReadStream(ruta)
      .on('error', rechazar)
      .on('data', (trozo) => hash.update(trozo))
      .on('end', () => resolver(hash.digest('hex')));
  });
}

export function sha256DeTexto(texto) {
  return createHash('sha256').update(texto).digest('hex');
}

/** Corre un comando y devuelve el código de salida y las últimas líneas de stderr. */
function correr(comando, args) {
  return new Promise((resolver, rechazar) => {
    const hijo = spawn(comando, args, { stdio: ['ignore', 'pipe', 'pipe'] });
    let cola = '';
    // El CLI dibuja una barra de progreso en stderr: se descarta salvo el final.
    const guardar = (d) => {
      cola = (cola + d.toString()).slice(-4000);
    };
    hijo.stdout.on('data', guardar);
    hijo.stderr.on('data', guardar);
    hijo.on('error', rechazar);
    hijo.on('close', (codigo) => resolver({ codigo, cola }));
  });
}

/**
 * Qué binario `pmtiles` usar: `PMTILES_BIN`, el del PATH o, en Linux x64, el de la release
 * oficial (versión y SHA-256 fijos) descargado a `<cache>/pmtiles`.
 */
export async function asegurarPmtiles({ cache }) {
  if (process.env.PMTILES_BIN) return process.env.PMTILES_BIN;

  const enPath = await correr('pmtiles', ['version']).catch(() => null);
  if (enPath?.codigo === 0) return 'pmtiles';

  const clave = `${platform()}-${arch()}`;
  const descarga = DESCARGAS[clave];
  if (!descarga) {
    throw new Error(
      `No hay un binario pmtiles para ${clave}. Instalalo (https://github.com/protomaps/go-pmtiles/releases, ` +
        `versión ${PMTILES_VERSION}) y pasá PMTILES_BIN=<ruta>.`,
    );
  }

  const binario = join(cache, 'pmtiles');
  if ((await correr(binario, ['version']).catch(() => null))?.codigo === 0) return binario;

  await mkdir(cache, { recursive: true });
  const url = `https://github.com/protomaps/go-pmtiles/releases/download/v${PMTILES_VERSION}/${descarga.archivo}`;
  const respuesta = await fetch(url);
  if (!respuesta.ok) throw new Error(`No se pudo bajar ${url}: ${respuesta.status}`);
  const contenido = Buffer.from(await respuesta.arrayBuffer());
  const obtenido = createHash('sha256').update(contenido).digest('hex');
  if (obtenido !== descarga.sha256) {
    throw new Error(`El SHA-256 de ${descarga.archivo} no coincide: ${obtenido}`);
  }
  const tar = join(cache, descarga.archivo);
  await writeFile(tar, contenido);
  const salida = await correr('tar', ['-xzf', tar, '-C', cache, 'pmtiles']);
  await rm(tar, { force: true });
  if (salida.codigo !== 0) throw new Error(`No se pudo descomprimir pmtiles: ${salida.cola}`);
  await chmod(binario, 0o755);
  return binario;
}

/** El build diario más reciente de Protomaps (prueba hoy y los 6 días anteriores). */
export async function buscarBuild({ hoy = new Date(), fetchFn = fetch } = {}) {
  for (let atras = 0; atras < 7; atras++) {
    const dia = new Date(hoy.getTime() - atras * 86_400_000);
    const build = dia.toISOString().slice(0, 10).replaceAll('-', '');
    const respuesta = await fetchFn(FUENTE_PROTOMAPS(build), { method: 'HEAD' });
    if (respuesta.ok) return build;
  }
  throw new Error('No encontré un build de Protomaps de los últimos 7 días (https://maps.protomaps.com/builds/).');
}

/**
 * Recorta `fuente` (URL o archivo .pmtiles) a `destino`. Con `region` (archivo GeoJSON) recorta
 * por el polígono; si no, por el bbox [oeste, sur, este, norte]. Devuelve el tamaño en bytes.
 */
export async function extraer({ pmtiles, fuente, destino, bbox, region = null, zoomMax }) {
  await rm(destino, { force: true });
  const args = ['extract', fuente, destino, `--maxzoom=${zoomMax}`, '--download-threads=4'];
  args.push(region ? `--region=${region}` : `--bbox=${bbox.join(',')}`);
  const { codigo, cola } = await correr(pmtiles, args);
  if (codigo !== 0) {
    await rm(destino, { force: true });
    throw new Error(`pmtiles extract falló (${codigo}): ${cola.split(/[\r\n]+/).slice(-5).join(' | ')}`);
  }
  return (await stat(destino)).size;
}
