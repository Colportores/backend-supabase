-- ============================================================================
-- 0029 · Bucket público `mapas`: los mapas propios (backend-supabase#42)
--
-- Decisión de Cristian del 06/10 («Decisiones de Cristian (06/10)», backend-supabase#42): los mapas
-- salen de Supabase Storage, de un bucket PÚBLICO de solo lectura y SIN login (la app los baja antes
-- de que haya sesión, y el panel y la app los leen con el mismo estilo). Adentro van, junto al
-- catálogo `catalogo.json`:
--
--   catalogo.json                     qué paquetes hay, cuánto pesan y su SHA-256 (docs/mapas-tiles.md)
--   estilo/colportores.json           el estilo de MapLibre, con la paleta del canvas
--   estilo/glyphs/<fuente>/<rango>.pbf, estilo/sprites/*   las fuentes y los íconos del estilo
--   paquetes/<nivel>/<id>.<hash>.pmtiles                   los paquetes PMTiles (Range por HTTP)
--
-- Qué hace esta migración y qué NO:
--
--   · Crea el bucket (o lo deja como debe estar si ya existe: es idempotente) con `public = true`,
--     que es lo que habilita la URL /storage/v1/object/public/mapas/<ruta> sin Authorization.
--   · Límite de 50 MiB por archivo: el tope del plan Free (los paquetes se recortan para entrar,
--     ver tiles/src/politica.mjs). Subirlo es parte de pasar a Pro (backend-supabase#68).
--   · Solo acepta los tipos de archivo que se publican acá.
--   · NO agrega políticas sobre storage.objects, a propósito. Un bucket público se lee por la URL
--     pública sin pasar por RLS; sin políticas, `anon` y `authenticated` no pueden ni listar ni
--     subir ni borrar por la API (solo leen por la URL de un archivo que ya conocen). Escribe
--     únicamente la clave de servicio (`service_role`), desde el workflow de GitHub Actions
--     (.github/workflows/tiles.yml). Una política de lectura sobre storage.objects dejaría listar
--     todo el bucket, y no hace falta: el catálogo ya dice qué hay.
--
-- CORS y Range no se configuran acá: son del servicio Storage (el hosteado responde con
-- `Access-Control-Allow-Origin: *`, vale para localhost y GitHub Pages, y con 206 a los Range).
-- docs/mapas-tiles.md dice cómo se verifica.
-- ============================================================================

-- Las tablas de `storage` las crea el servicio Storage (storage-api) cuando arranca, no la imagen de
-- Postgres: la base de CI (compose.dev.yml, solo `db`) trae el schema `storage` vacío, y un
-- `supabase start` desde cero puede aplicar las migraciones antes de que Storage arranque. En esos
-- casos no hay dónde insertar y la migración no puede fallar, porque rompería todo lo demás: avisa y
-- sigue. Ahí el bucket sale de otro lado, que dice lo mismo: `[storage.buckets.mapas]` de config.toml
-- (local) y `asegurarBucket()` de tiles/src/storage.mjs (la primera publicación, contra el proyecto
-- hosteado). tiles/test/bucket.test.mjs comprueba que las tres definiciones coinciden.
do $mapas$
begin
  if to_regclass('storage.buckets') is null then
    raise notice '0029: no existe storage.buckets (la base no tiene el servicio Storage); no se crea el bucket mapas desde esta migracion.';
    return;
  end if;

  insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
  values (
    'mapas',
    'mapas',
    true,
    52428800, -- 50 MiB
    array[
      'application/json',         -- catalogo.json, estilo, indices de sprites
      'application/octet-stream', -- .pmtiles
      'application/x-protobuf',   -- glyphs (.pbf)
      'image/png',                -- sprites
      'text/plain'                -- licencias que acompañan a las fuentes (OFL.txt)
    ]
  )
  on conflict (id) do update
    set public             = excluded.public,
        file_size_limit    = excluded.file_size_limit,
        allowed_mime_types = excluded.allowed_mime_types;
end
$mapas$;
