-- ============================================================================
-- 0031 · El rectángulo de cada ciudad y el enlace al paquete de mapa de cada zona (backend-supabase#42, etapa 2)
--
-- Decisiones de Cristian del 06/10, «Área ciudad» y «Zona pública»
-- (https://github.com/Colportores/backend-supabase/pull/73#issuecomment-6026881182):
--
--   · «Área ciudad»: cada ciudad guarda su rectángulo en `public.ciudad`, y el publicador de mapas
--     publica las ciudades que lo tienen, sin ninguna lista en el repo. Hasta hoy el rectángulo
--     (`bbox`) de Montevideo vivía en un archivo del repo (tiles/ciudades.json, que esta etapa
--     retira) y `public.ciudad` solo sabía el centro y el zoom (HU-ADM-005 pide que cada ciudad
--     traiga su `bbox`).
--   · «Zona pública»: los paquetes de mapa de las zonas NO van al catálogo público (el archivo de una
--     zona muestra su rectángulo a quien lo baje). Cada zona guarda el enlace a su paquete, que le
--     llega al colportor con su zona por el sync, y el archivo tiene un nombre que no se puede adivinar.
--
-- ## Qué cambia
--
--   · public.ciudad: cuatro columnas, `bbox_oeste`, `bbox_sur`, `bbox_este` y `bbox_norte` (grados,
--     WGS84; el orden de siempre de un bbox: [oeste, sur, este, norte]). Son opcionales: una ciudad
--     sin rectángulo (las ciudades de ejemplo del seed, o una recién cargada) no tiene mapa propio, y
--     el publicador lo avisa. Cuatro restricciones las cuidan: el rectángulo viene entero o no viene,
--     cada valor está en su rango, el oeste queda antes que el este y el sur antes que el norte, y
--     el centro de la ciudad cae adentro (así un lat/lon cargado al revés no pasa).
--   · Montevideo: si la base ya la tiene (una sola, viva, del país UY, sin rectángulo y con su centro
--     adentro del rectángulo de abajo), se le carga el suyo. Es el mismo que tenía el archivo del repo,
--     que deja de ser la fuente. El UPDATE pasa por el trigger de auditoría: sube su `sync_version` y
--     llega a los teléfonos por delta. Si la base no la tiene, no se inventa una fila: se carga con
--     docs/guia-carga-manual.md §2 (que ya trae el bloque con el rectángulo) o con el seed local.
--   · public.zona.paquete_mapa (jsonb, opcional): el enlace al paquete de mapa de la zona. Lo escribe
--     solo el publicador de mapas (tiles/), con la clave de servicio: `authenticated` ya no tiene
--     INSERT ni UPDATE sobre zona (0008) y esta columna no lo cambia. Lo lee quien ya ve la zona
--     (política zona_select) y viaja en el pull con ella, como cualquier otra columna de zona. Forma:
--
--         {
--           "archivo":        "zonas/<32 hex al azar>.pmtiles",  ruta dentro del bucket `mapas`
--           "tamano_bytes":   4812345,
--           "sha256":         "<64 hex>",      la versión: si cambia, hay un mapa nuevo
--           "zoom_max":       15,
--           "region_sha256":  "<64 hex>",      del recorte; lo usa el publicador para saber si regenerar
--           "actualizado_en": "2026-10-08T12:00:00Z",
--           "anteriores":     [{ "archivo": "zonas/<…>.pmtiles", "desde": "2026-10-08T12:00:00Z" }]
--         }
--
--     `anteriores` es del publicador: los archivos que dejaron de ser el vigente y todavía no se
--     borraron (se borran a los 7 días, como los del catálogo: hay teléfonos con la descarga
--     pausada). Un teléfono no los necesita. Sin paquete vigente, falta `archivo` y la app no
--     muestra descarga de zona. Un NULL es una zona que todavía no se publicó.
--
-- ## Los datos
--
-- Se preservan todos: son `add column` opcionales (instantáneos, sin reescribir la tabla) y no hay
-- `delete` ni `insert`. El único UPDATE es el del rectángulo de Montevideo, y solo si estaba vacío.
-- Las columnas nuevas de `ciudad` también bajan en el pull (el pull manda todas las columnas de la
-- entidad, sync.expresion_json): la app las puede ignorar hasta que las use.
--
-- ## Para otros repos
--
--   · tiles/ (este repo): el publicador lee de `public.ciudad` las ciudades con rectángulo y de
--     `public.zona` las zonas vivas de campañas que no terminaron; escribe `zona.paquete_mapa`.
--   · front-colportores-mobile y motor de sync (HU-SYNC-010, front-colportores-mobile#178): `ciudad`
--     trae `bbox_oeste`, `bbox_sur`, `bbox_este` y `bbox_norte` y `zona` trae `paquete_mapa`, en el
--     pull. La URL del paquete es `<SUPABASE_URL>/storage/v1/object/public/mapas/<archivo>`.
--     La columna de `zona` va al contrato de sync en un PR de docs aparte, que revisa @BrunoFCapri.
--   · front-coordinadores-web (HU-ADM-005): la ciudad lleva su rectángulo; hoy se carga a mano
--     (docs/guia-carga-manual.md §2).
--   · docs-organizacion: esquema-datos.md (las dos tablas) y HU-SYNC-010.
--
-- Forward-only: esta migración no se edita una vez aplicada.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. ciudad: el rectángulo
-- ----------------------------------------------------------------------------

alter table public.ciudad
  add column bbox_oeste double precision,
  add column bbox_sur   double precision,
  add column bbox_este  double precision,
  add column bbox_norte double precision;

alter table public.ciudad
  add constraint ciudad_bbox_completo_check check (
    (bbox_oeste is null) = (bbox_sur is null)
    and (bbox_oeste is null) = (bbox_este is null)
    and (bbox_oeste is null) = (bbox_norte is null)
  ),
  add constraint ciudad_bbox_rango_check check (
    bbox_oeste between -180 and 180 and bbox_este between -180 and 180
    and bbox_sur between -90 and 90 and bbox_norte between -90 and 90
  ),
  add constraint ciudad_bbox_orden_check check (bbox_oeste < bbox_este and bbox_sur < bbox_norte),
  -- Solo mira el centro si el rectángulo tiene su orden; uno al revés lo dice ciudad_bbox_orden_check
  -- (Postgres evalúa las restricciones por orden alfabético y esta va antes).
  add constraint ciudad_bbox_contiene_centro_check check (
    not (bbox_oeste < bbox_este and bbox_sur < bbox_norte)
    or (lon_centro between bbox_oeste and bbox_este and lat_centro between bbox_sur and bbox_norte)
  );

comment on column public.ciudad.bbox_oeste is
  'Rectángulo de la ciudad (WGS84, grados): oeste (longitud mínima). Los cuatro bbox_* vienen juntos o '
  'ninguno; sin ellos la ciudad no tiene mapa propio. Con él el publicador de mapas (tiles/) recorta el '
  'paquete de la ciudad. El centro (lat_centro, lon_centro) tiene que caer adentro (0031, backend-supabase#42).';
comment on column public.ciudad.bbox_sur is 'Rectángulo de la ciudad: sur (latitud mínima). Ver bbox_oeste.';
comment on column public.ciudad.bbox_este is 'Rectángulo de la ciudad: este (longitud máxima). Ver bbox_oeste.';
comment on column public.ciudad.bbox_norte is 'Rectángulo de la ciudad: norte (latitud máxima). Ver bbox_oeste.';

-- Montevideo, si ya está cargada y es una sola. El rectángulo es el que tenía la etapa 1 en el repo.
do $$
declare
  v_ids uuid[];
begin
  select array_agg(c.id)
    into v_ids
    from public.ciudad c
    join public.pais p on p.id = c.pais_id
   where p.iso_code = 'UY'
     and c.nombre = 'Montevideo'
     and c.deleted_at is null
     and c.bbox_oeste is null
     and c.lon_centro between -56.433 and -55.948
     and c.lat_centro between -34.945 and -34.701;

  if cardinality(v_ids) = 1 then
    update public.ciudad
       set bbox_oeste = -56.433, bbox_sur = -34.945, bbox_este = -55.948, bbox_norte = -34.701
     where id = v_ids[1];
  end if;
end
$$;

-- ----------------------------------------------------------------------------
-- 2. zona: el enlace al paquete de mapa
-- ----------------------------------------------------------------------------

alter table public.zona
  add column paquete_mapa jsonb;

alter table public.zona
  add constraint zona_paquete_mapa_objeto_check check (
    paquete_mapa is null or jsonb_typeof(paquete_mapa) = 'object'
  );

comment on column public.zona.paquete_mapa is
  'Enlace al paquete de mapa de la zona (0031, backend-supabase#42; decisión de Cristian del 06/10, «Zona pública»): '
  '{archivo, tamano_bytes, sha256, zoom_max, region_sha256, actualizado_en, anteriores}. El archivo vive en el bucket '
  'público `mapas` con un nombre al azar (no está en catalogo.json) y la zona lo lleva al colportor por el sync. Lo '
  'escribe solo el publicador de mapas (tiles/) con la clave de servicio; `authenticated` no tiene UPDATE sobre zona. '
  'NULL: todavía no se publicó. Sin `archivo`: no hay paquete vigente (`anteriores` espera su borrado a los 7 días).';
