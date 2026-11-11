// Después de publicar: el catálogo que ve la app trae, para Montevideo, el id que la ciudad tiene en
// public.ciudad (la app elige el paquete por ahí), y la versión del estilo (SHA-256 del archivo publicado).
// Uso: node prueba-storage/ambito-del-catalogo.mjs <URL pública del bucket>   (AMBITO_ESPERADO en el entorno)
import { createHash } from 'node:crypto';

const base = process.argv[2]?.replace(/\/+$/, '');
const esperado = process.env.AMBITO_ESPERADO;
if (!base || !esperado) {
  console.error('Uso: AMBITO_ESPERADO=<uuid> node prueba-storage/ambito-del-catalogo.mjs <url pública del bucket>');
  process.exit(2);
}

const catalogo = await (await fetch(`${base}/catalogo.json`)).json();
const ciudades = catalogo.paquetes.filter((p) => p.nivel === 'ciudad');
if (ciudades.length === 0) throw new Error('el catálogo no trae ningún paquete de ciudad');
for (const paquete of ciudades) {
  if (paquete.ambito_id !== esperado) {
    throw new Error(`«${paquete.nombre}»: ambito_id ${paquete.ambito_id} en el catálogo; la base dice ${esperado}`);
  }
}

// `estilo.url` es relativa a la URL del catálogo.
const urlDelEstilo = new URL(catalogo.estilo.url, `${base}/catalogo.json`);
const archivoDelEstilo = Buffer.from(await (await fetch(urlDelEstilo)).arrayBuffer());
const version = createHash('sha256').update(archivoDelEstilo).digest('hex');
if (catalogo.estilo.version !== version) {
  throw new Error(`estilo.version ${catalogo.estilo.version} no es el SHA-256 del estilo publicado (${version})`);
}
console.log(`ok: ${ciudades.length} paquete(s) de ciudad con ambito_id ${esperado}; estilo.version = SHA-256 del estilo publicado`);
