// Cómo tiene que estar el bucket `mapas`. La misma definición está en tres lados y
// tiles/test/bucket.test.mjs comprueba que dicen lo mismo:
//   - supabase/migrations/20261006090000_0029_bucket_mapas.sql (el proyecto hosteado, por `db push`)
//   - supabase/config.toml, [storage.buckets.mapas]            (el Supabase local)
//   - esto, que `asegurarBucket()` usa en la primera publicación si el bucket todavía no existe.

export const BUCKET = Object.freeze({
  id: 'mapas',
  public: true,
  /** 50 MiB: el tope de archivo del plan Free de Supabase. */
  file_size_limit: 52_428_800,
  allowed_mime_types: Object.freeze([
    'application/json', // catalogo.json, estilo, índices de sprites
    'application/octet-stream', // .pmtiles
    'application/x-protobuf', // glyphs (.pbf)
    'image/png', // sprites
    'text/plain', // licencias que acompañan a las fuentes (OFL.txt)
  ]),
});

/** Content-Type y Cache-Control con los que se sube cada tipo de archivo. */
export const TIPOS = Object.freeze({
  '.pmtiles': { contentType: 'application/octet-stream' },
  '.json': { contentType: 'application/json' },
  '.pbf': { contentType: 'application/x-protobuf' },
  '.png': { contentType: 'image/png' },
  '.txt': { contentType: 'text/plain' },
});

export function tipoDe(ruta) {
  const punto = ruta.lastIndexOf('.');
  const tipo = punto === -1 ? undefined : TIPOS[ruta.slice(punto).toLowerCase()];
  if (!tipo) throw new Error(`Tipo de archivo no permitido en el bucket mapas: ${ruta}`);
  return tipo.contentType;
}

/**
 * Cache-Control según qué tan mutable es el archivo:
 *   - paquetes: el nombre lleva el SHA-256, nunca cambian → 1 año, immutable;
 *   - catálogo y estilo: cambian en cada publicación → 60 s (el CDN de Supabase los renueva solo);
 *   - glyphs y sprites: salen de una versión fija de Protomaps → 1 día.
 */
export function cacheControlDe(ruta) {
  if (ruta.startsWith('paquetes/')) return 'public, max-age=31536000, immutable';
  if (ruta === 'catalogo.json' || ruta === 'estilo/colportores.json') return 'public, max-age=60';
  return 'public, max-age=86400';
}
