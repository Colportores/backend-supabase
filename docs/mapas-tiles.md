# Mapas propios (tiles) — HU-SYNC-010 / HU-UBI-003, lado servidor

La app y el panel dibujan el mapa con **archivos PMTiles de OpenStreetMap que viven en un bucket público
de Supabase Storage**, un solo estilo MapLibre compartido y un catálogo que dice qué hay. Sin proveedor
de mapas aparte, sin claves de API y sin login para leer. Decisión de Cristian del 06/10
([comentario en backend-supabase#42](https://github.com/Colportores/backend-supabase/issues/42#issuecomment-6018730476)).

Esta guía cubre la **etapa 1**: bucket, CORS y Range, estilo, glyphs y sprites, catálogo y una ciudad
(Montevideo) medida y publicable. Las demás ciudades y los paquetes por zona son la etapa 2
([§ Qué falta](#qué-falta-etapa-2)). Departamento y Uruguay quedan fuera: backend-supabase#68, con el plan Pro.

## Qué hay en el bucket

Bucket `mapas`: **público y de solo lectura**. Cualquiera lee `…/storage/v1/object/public/mapas/<ruta>` sin
login; solo `service_role` escribe (ver [§ Seguridad](#seguridad)).

```
mapas/
├── catalogo.json                         ← qué paquetes hay; lo escribe el publicador, siempre último
├── estilo/
│   ├── colportores.json                  ← EL estilo MapLibre (app y panel)
│   ├── glyphs/NotoSans-Regular/0-255.pbf …   ← tipografías
│   └── sprites/grayscale{,@2x}.{json,png}    ← íconos
└── paquetes/
    ├── ciudad/montevideo.<sha12>.pmtiles       ← una ciudad entera
    ├── ciudad/<slug>.parte1de2.<sha12>.pmtiles ← si no entra en 50 MB: dos archivos
    └── zona/<id-de-zona>.<sha12>.pmtiles       ← (etapa 2) una zona
```

El nombre de un paquete lleva los primeros 12 caracteres de su SHA-256: **un archivo publicado nunca se pisa**.
Un mapa nuevo es un archivo nuevo, y el catálogo —que se sube al final— pasa a apuntarle. Por eso un
teléfono que justo está bajando el mapa viejo termina bien, y por eso los paquetes se sirven con
`Cache-Control: public, max-age=31536000, immutable`.

## Cómo se consume (contrato para la app y el panel)

1. **Leer el catálogo**: `GET <SUPABASE_URL>/storage/v1/object/public/mapas/catalogo.json`. Todas las rutas
   que trae (`estilo.url`, `partes[].archivo`) son **relativas a la URL del catálogo**.
2. **Elegir el paquete** por `nivel` (`zona`, `ciudad`) y `id` (`ciudad-montevideo`). `ambito_id` es el id de la
   ciudad o de la zona en la base; hoy viene `null` en las ciudades ([§ Pendientes](#pendientes-de-decisión)).
3. **Descargar** cada `partes[].archivo` y comprobar `tamano_bytes` y `sha256`. La descarga se puede reanudar con
   `Range`. Un paquete cabe en el plan Free, así que cada parte pesa menos de 50 MB.
4. **El estilo** es uno solo: `estilo/colportores.json`. Su fuente de tiles viene con un valor a completar:
   `sources.protomaps.url = "pmtiles://REEMPLAZAR"`. El cliente lo cambia por el archivo del paquete que
   tiene (`pmtiles://<URL o ruta local del .pmtiles>`). Glyphs y sprites ya vienen con URL absoluta del bucket.
   Un paquete **de varias partes** necesita una fuente por parte, con las capas repetidas apuntando a cada una
   (MapLibre no une dos archivos en una fuente).
5. **¿Hay mapa nuevo?** Comparar el `version` del paquete con el que se bajó: es el SHA-256 de la parte (o,
   con varias, el de sus SHA-256 en orden). Es lo que usa `hayActualizacion`.
6. **Atribución visible**: «© OpenStreetMap» (ODbL). Viene en `sources.protomaps.attribution` y en `fuente` del catálogo.

El panel (navegador) lee lo mismo directo del bucket: por eso el CORS ([§ CORS y Range](#cors-y-range)).

## El catálogo

```json
{
  "version": 1,
  "generado_en": "2026-10-06T15:32:09Z",
  "fuente": { "proveedor": "Protomaps (datos de OpenStreetMap)", "atribucion": "© OpenStreetMap contributors", "licencia": "ODbL 1.0" },
  "estilo": { "url": "estilo/colportores.json", "fuente_de_tiles": "protomaps" },
  "paquetes": [
    {
      "id": "ciudad-montevideo",
      "nivel": "ciudad",
      "ambito_id": null,
      "nombre": "Montevideo",
      "bbox": [-56.433, -34.945, -55.948, -34.701],
      "zoom_min": 0,
      "zoom_max": 15,
      "tamano_bytes": 10920234,
      "version": "581c301248397e2f6ad764adeb4c13f45a564bf129587731e1629e1c9935022a",
      "partes": [
        { "archivo": "paquetes/ciudad/montevideo.581c30124839.pmtiles", "tamano_bytes": 10920234,
          "sha256": "581c301248397e2f6ad764adeb4c13f45a564bf129587731e1629e1c9935022a",
          "bbox": [-56.433, -34.945, -55.948, -34.701] }
      ],
      "fuente_build": "20261006",
      "actualizado_en": "2026-10-06T15:31:41Z"
    }
  ]
}
```

| campo | qué es |
|---|---|
| `version` (raíz) | versión del **formato** del catálogo (hoy 1); un cambio incompatible la sube |
| `generado_en` | cuándo se publicó el catálogo (ISO 8601, UTC) |
| `paquetes[].nivel` | `zona` < `ciudad` < `departamento` < `uruguay` (como `NivelCobertura` de la app) |
| `paquetes[].ambito_id` | id de la ciudad o zona en la base, o `null` |
| `paquetes[].zoom_min/zoom_max` | zooms que trae el archivo; más allá, MapLibre amplía el último |
| `paquetes[].tamano_bytes` | suma de las partes |
| `paquetes[].version` | qué cambió: SHA-256 de la parte única, o de los SHA-256 de las partes unidos con `\n` |
| `paquetes[].partes[]` | `archivo` (relativo al catálogo), `tamano_bytes`, `sha256` y, en ciudades, su `bbox` |
| `fuente_build` | build de Protomaps del que se cortó (`AAAAMMDD`) |
| `actualizado_en` | cuándo se cortó ese paquete |

**Privacidad**: el catálogo es público. Los paquetes de zona **no llevan `nombre`, `bbox` ni `partes[].bbox`**: dónde
trabaja cada equipo no se publica; la app ya conoce sus zonas por la réplica local y le alcanza con el id.

Lo valida `tiles/src/catalogo.mjs` (`validar`) antes de subirlo: versión, ids únicos, rutas relativas, tamaños,
SHA-256 y que `version` coincida con las partes. Un catálogo inválido no se publica.

## El estilo

`tiles/paleta.json` + las capas de [`@protomaps/basemaps`](https://github.com/protomaps/basemaps) 5.7.2 dan
**un** estilo MapLibre (`estilo/colportores.json`), con la paleta del canvas de Claude Design (tierra
`#F6F5F0`, parques `#DDE8D3`, calles `#FFFFFF` y avenidas `#FBF1D6`, rótulos `#7C8594`), rótulos en español
(`name:es`), tipografía Noto Sans y la atribución de OSM. Lo genera `node src/cli.mjs estilo` (o `publicar`)
de forma determinista: la misma paleta da el mismo archivo.

Las URL de glyphs y sprites tienen que ser absolutas (MapLibre no las resuelve contra la del estilo), así que el
estilo se genera **por proyecto**, con la URL pública de su bucket. Sin los puntos de interés (el sprite no trae
sus íconos; el canvas no los dibuja). Los assets y sus licencias: [`tiles/assets/NOTICE.md`](../tiles/assets/NOTICE.md).

## Tamaño: ningún archivo pasa de 50 MB

El plan Free de Supabase rechaza archivos de más de 50 MB. La política (`tiles/src/politica.mjs`) es:

1. Cortar la ciudad a zoom 15 (calle y manzana). Si pesa ≤ 50 000 000 bytes, listo.
2. Si no, bajar el zoom máximo de a uno hasta 14.
3. Si a zoom 14 tampoco entra, **partirla en dos archivos** por la mitad del lado más largo, y repetir 1 y 2 con cada mitad
   (los dos con el mismo zoom). Si ni así entra, el publicador **se detiene** con un error: nunca sube un archivo
   de más de 50 MB.

Medido el 06/10 con el build `20261006` de Protomaps: **Montevideo pesa 10,9 MB a zoom 15** (3,5 MB a zoom 14 y 1,9 a 13),
así que no hace falta bajar el zoom ni partirla. El zoom 15 es el piso útil para ubicar una puerta; por eso 14 es el mínimo.
Cada descarga de Montevideo son 10,9 MB: conviene mirar en el panel de Supabase el límite mensual de salida
(*egress*) del plan antes de que el piloto tenga muchos teléfonos bajando el mapa.

## CORS y Range

PMTiles lee por rangos de bytes (`Range`), también desde el navegador. Se espera que el CORS lo ponga el gateway
de la API de Supabase para todo lo que sale de `/storage/v1` (sin configuración en el proyecto) y que el Storage
atienda `Range` con `206` y `Content-Range`. **Eso no está confirmado contra el proyecto real** (no hay credenciales
en este repo): lo confirma `verificar` después de la primera publicación ([§ Verificar](#verificar)):

- el catálogo, el estilo, los glyphs y los sprites se leen sin login;
- cada paquete: `HEAD` con el tamaño del catálogo, `Range` con `206` y el `Content-Range` correcto, y que empiece
  con la firma `PMTiles`;
- `Access-Control-Allow-Origin` para `http://localhost:3000` y `https://colportores.github.io`, y el *preflight*
  (`OPTIONS`) que manda el navegador cuando el pedido lleva `Range` e `If-Match`, como hace pmtiles.js.

Lo que sí se probó contra un Storage de verdad (`storage-api` v1.61.10, [§ Probar contra un Storage real](#probar-contra-un-storage-real)):
`Range` con `206` y `Accept-Ranges: bytes`, los `Cache-Control` de cada tipo de archivo tal como se publican, la
lectura sin login y que `anon` no escribe. Ese Storage suelto no contesta CORS ni el preflight (de eso se ocupa el
gateway), así que la prueba pone delante un gateway mínimo que imita el plugin `cors` de Kong; lo que contesta el
proyecto real lo dice `verificar`. Si el CORS del proyecto no alcanzara, es un pendiente para Cristian: el gateway es
de Supabase y no se resuelve desde este repo.

## Seguridad

- El bucket es público para **leer**; no hay ninguna política sobre `storage.objects` para él, así que `anon` y
  `authenticated` no pueden subir, pisar, borrar ni listar. Solo `service_role` escribe, y lo prueban
  `supabase/tests/0036_bucket_mapas_test.sql` y `tiles/prueba-storage/acceso-anonimo.mjs`.
- La clave de servicio **no está en el repo**. Sale de los secretos del environment de GitHub ([§ Publicar](#publicar)).
- Nada de lo publicado es sensible: mapa de OpenStreetMap, una paleta y los ids de las zonas.
- El bucket solo acepta `application/json`, `application/octet-stream`, `application/x-protobuf`, `image/png`
  y `text/plain`, y archivos de hasta 50 MiB.

## Publicar

El código está en [`tiles/`](../tiles) (Node 22; las dependencias son `@protomaps/basemaps` y, para probar,
`@maplibre/maplibre-gl-style-spec`). Usa el CLI de Protomaps
[`go-pmtiles`](https://github.com/protomaps/go-pmtiles) **1.31.2** (se baja solo, con SHA-256 verificado), que lee por
`Range` solo la zona pedida de `https://build.protomaps.com/AAAAMMDD.pmtiles` (el planeta entero pesa ~138 GB: no se
descarga). Cada ciudad se corta con su `bbox` de `tiles/ciudades.json`.

```
node src/cli.mjs estilo     [--url-base URL] [--salida DIR]      # solo escribe el estilo en un archivo
node src/cli.mjs publicar   [--solo estilo|ciudades] [--ciudad SLUG] [--build AAAAMMDD] [--dry-run]
node src/cli.mjs verificar  [--url URL]
```

`publicar`, en este orden, para que el catálogo **nunca apunte a algo que todavía no está**:
1. crea o ajusta el bucket `mapas` (público, 50 MiB, tipos permitidos);
2. sube el estilo, glyphs y sprites;
3. corta cada ciudad según la política de tamaño y sube sus partes **solo si ese SHA-256 todavía no está**;
4. valida y sube el catálogo, **último**;
5. borra los archivos que el catálogo ya no menciona y tienen más de **7 días** (período de gracia para un
   teléfono con una descarga en curso).

Repetir `publicar` con los mismos datos no sube nada nuevo («sin cambios»). `--dry-run` hace todo menos escribir.

### Con GitHub Actions

Workflow **Mapas** (`.github/workflows/tiles.yml`, `workflow_dispatch`): elegir environment (`develop`,
`staging`, `production`), qué publicar, y opcionalmente una ciudad y un build. Corre las pruebas, publica y
después `verificar`. Un solo publicador por environment a la vez (`concurrency`), porque todos reescriben el
mismo `catalogo.json`.

No pide secretos nuevos: usa `SUPABASE_PROJECT_ID` (de ahí sale `https://<id>.supabase.co`) y
`SUPABASE_ACCESS_TOKEN`, los de `deploy.yml`, y con el token el CLI de Supabase pide la clave de servicio, que
no se guarda en ningún lado (`supabase projects api-keys`; **sin probar contra el proyecto real**). Si el
environment define `SUPABASE_SERVICE_ROLE_KEY` o `SUPABASE_URL` (por ejemplo, un dominio propio), se usan
esos.

Como cualquier `workflow_dispatch`, aparece en Actions cuando el archivo está en la rama por defecto
(`production`). Hasta entonces: a mano.

### Publicar a mano

Necesita `SUPABASE_URL` y la clave de servicio (`SUPABASE_SERVICE_ROLE_KEY`, de Project Settings → API). Nunca
a un archivo del repo. Con Docker, sin instalar Node:

```sh
docker run --rm -v "$PWD/tiles:/app" -w /app \
  -e SUPABASE_URL=https://<proyecto>.supabase.co -e SUPABASE_SERVICE_ROLE_KEY \
  node:22-bookworm sh -c "npm ci && node src/cli.mjs publicar && node src/cli.mjs verificar"
```

(`node:22-bookworm` y no `-slim`: `pmtiles` necesita los certificados de la imagen completa.)

### Verificar

`node src/cli.mjs verificar` no necesita ninguna clave (prueba lo que ve cualquiera) y sale con código 1 si algo falla.
Un «aviso» no es un error: hoy es que el gateway no expone `Content-Range` al navegador, que pmtiles.js no necesita.

## Cómo se actualiza

| qué cambia | qué se hace | qué ven los teléfonos |
|---|---|---|
| un build nuevo de Protomaps (diario) | **nada** por defecto. Re-cortar cada vez le haría bajar a todos ~11 MB de mapa casi idéntico. Se publica a mano cuando el mapa de OSM cambió lo que importa (calles nuevas, un barrio) | un `version` nuevo en el paquete → «hay actualización» |
| la paleta | editar `tiles/paleta.json`, probar, y publicar con `--solo estilo` | el estilo nuevo, al volver a pedirlo (`Cache-Control` de 60 s) |
| una ciudad nueva | agregarla a `tiles/ciudades.json` (`slug`, `nombre`, `bbox`) y publicar con `--ciudad <slug>` | una entrada nueva en el catálogo |
| una ciudad que no entra en 50 MB | nada: la política baja el zoom o la parte en dos | `partes` con dos archivos |
| quitar una ciudad | sacarla de `ciudades.json` y del catálogo (a mano: `fusionar` con `quitar`); sus archivos se borran a los 7 días | desaparece del catálogo |

### Cuando un coordinador edita una zona

**Propuesta (sin proveedor nuevo; no está implementada: es la etapa 2).** Los paquetes de zona se regeneran
a partir de lo que ya hay: la base de Supabase, el workflow de GitHub y el bucket.

1. **Qué cambió**: el publicador lee las zonas de la base (PostgREST con la clave de servicio, la misma del
   workflow) y calcula, de cada una, el SHA-256 de su geometría (`region_sha256`). El catálogo guarda el de cada
   paquete de zona; **solo se regeneran las zonas cuyo hash difiere**, las que no están en el catálogo se crean y las
   que ya no están en la base se sacan. No depende de relojes ni de que alguien avise.
2. **Cuándo corre**: un `schedule` del mismo workflow (cada hora), detrás de una variable de repo —igual que
   `DEPLOY_DEVELOP`— para apagarlo sin tocar código, más el disparo manual. El repo es público: los minutos de
   Actions no se pagan. Una corrida sin cambios lee la base, compara hashes y termina sin cortar nada.
3. **Qué corta**: el `bbox` del polígono más un margen, a zoom 15 (una zona pesa un puñado de MB), con la misma
   política de tamaño, y lo publica como cualquier otro paquete (archivo nuevo, catálogo al final).
4. **Qué ve la app**: el `version` de ese paquete cambia, así que `hayActualizacion` da verdadero y baja solo
   esa zona. El catálogo no publica su nombre ni su `bbox`.

Demora: hasta una hora desde que el coordinador guarda hasta que el paquete nuevo está en el bucket.
Alternativa más rápida —**implica un secreto más**—: un webhook de la base (`pg_net`) que dispare el workflow
(`repository_dispatch`) al guardar una zona, con un token de GitHub en Vault. Elegir entre las dos es un pendiente
para Cristian ([§ Pendientes](#pendientes-de-decisión)).

## Probar contra un Storage real

La base de CI no trae el servicio Storage (el schema `storage` está vacío), así que **la migración
`0029_bucket_mapas.sql` se saltea** ahí y **pgTAP 0036 también** (con un `skip` explícito). Para probarlas de
verdad, y el publicador de punta a punta, sin credenciales ni proyecto en la nube:

```sh
bash tiles/prueba-storage/correr.sh
```

Levanta la base de `compose.dev.yml`, el `storage-api` oficial y un gateway que imita el CORS de Supabase; aplica
las migraciones (la 0029 crea el bucket), corre pgTAP 0036 completo, publica el estilo y Montevideo (recorte real,
necesita red), corre `verificar`, publica de nuevo (tiene que dar «sin cambios») y comprueba que con la clave
anónima no se escribe. Baja imágenes la primera vez (`storage-api` ~1,4 GB, `node:22-bookworm` ~1,6 GB) y no construye
ninguna. En CI corre el job **tiles** (`npm ci && npm test`: pruebas del publicador con un Storage de mentira).

## Qué falta (etapa 2)

- **Las demás ciudades** (lista y `bbox` en `tiles/ciudades.json`; hoy solo Montevideo), medidas una por una.
- **Paquetes por zona** y su regeneración (propuesta arriba): leer las zonas, `region_sha256`, y sacar `partes[].bbox`
  del catálogo público para ellas.
- **`ambito_id` de las ciudades** (el id de `public.ciudad`), cuando haya ciudades en la base.
- Que front-colportores-mobile#189 soporte paquetes de **varias partes** (una fuente por parte) si alguna ciudad lo
  necesita.

## Pendientes de decisión

Quedan escritos con su opción conservadora en el PR de backend-supabase#42 (marcados «Cristian §3» o «mapa §2»).

## Licencias y atribución

- Datos: © OpenStreetMap contributors, **ODbL 1.0**, vía los builds de [Protomaps](https://protomaps.com/).
  La atribución va en el estilo y en el catálogo; la app y el panel tienen que mostrarla.
- Capas del estilo: `@protomaps/basemaps` (BSD-3-Clause). Tipografía Noto Sans (OFL) y sprites (MIT): ver
  [`tiles/assets/NOTICE.md`](../tiles/assets/NOTICE.md).
