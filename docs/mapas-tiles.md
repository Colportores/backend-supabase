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
Un mapa nuevo es un archivo nuevo, y el catálogo —que se sube al final— pasa a apuntarle. El archivo viejo
no se borra enseguida: queda en el bucket **7 días contados desde que el catálogo dejó de nombrarlo**
([§ Qué se borra y cuándo](#qué-se-borra-y-cuándo)). Por eso un teléfono que estaba bajando el mapa viejo, o que
retoma una descarga pausada con `Range`, termina bien; y por eso los paquetes se sirven con
`Cache-Control: public, max-age=31536000, immutable`.

## Cómo se consume (contrato para la app y el panel)

1. **Leer el catálogo**: `GET <SUPABASE_URL>/storage/v1/object/public/mapas/catalogo.json`. Todas las rutas
   que trae (`estilo.url`, `partes[].archivo`) son **relativas a la URL del catálogo**. El campo `retirados` es
   del publicador (cuenta los 7 días de gracia): la app y el panel lo ignoran.
2. **Elegir el paquete de la ciudad por `ambito_id`**: es el id de la ciudad en `public.ciudad`, el mismo que la
   app ya tiene en su réplica local (`nivel: "ciudad"`). **Siempre viene**: el publicador lo lee de la base de ese
   proyecto (por nombre, en Uruguay) y se detiene sin subir nada si la ciudad no está o si hay más de una con ese
   nombre. `id` (`ciudad-montevideo`) es solo el identificador del paquete dentro del catálogo.
3. **Descargar** cada `partes[].archivo` y comprobar `tamano_bytes` y `sha256`. La descarga se puede reanudar con
   `Range`. Un paquete cabe en el plan Free, así que cada parte pesa menos de 50 MB.
4. **El estilo** es uno solo: `estilo/colportores.json`. Su fuente de tiles viene con un valor a completar:
   `sources.protomaps.url = "pmtiles://REEMPLAZAR"`. El cliente lo cambia por el archivo del paquete que
   tiene (`pmtiles://<URL o ruta local del .pmtiles>`). Glyphs y sprites ya vienen con URL absoluta del bucket
   (`glyphs` y `sprite` del estilo), que es lo que necesita el panel.
   Un paquete **de varias partes** necesita una fuente por parte, con las capas repetidas apuntando a cada una
   (MapLibre no une dos archivos en una fuente).
   **La app, para el mapa sin conexión ([front-colportores-mobile#286](https://github.com/Colportores/front-colportores-mobile/issues/286)),
   tiene que reemplazar también `glyphs` y `sprite`** por copias que viajen dentro de la app, igual que
   `sources.protomaps.url`: si los deja, MapLibre los pide al bucket y, sin red, no dibuja rótulos ni íconos aunque
   el mapa esté bajado. Lo que hay que copiar: `estilo/glyphs/<fuente>/<rango>.pbf` (NotoSans-Regular, -Medium e
   -Italic; los rangos `0-255`, `256-511` y `8192-8447`) y `estilo/sprites/grayscale{,@2x}.{json,png}`; están en
   [`tiles/assets/`](../tiles/assets) (con sus licencias) y son los mismos que se publican. `glyphs` queda como
   `<local>/glyphs/{fontstack}/{range}.pbf` y `sprite` como `<local>/sprites/grayscale`.
5. **¿Hay mapa nuevo?** Comparar el `version` del paquete con el que se bajó: es el SHA-256 de la parte (o,
   con varias, el de sus SHA-256 en orden). Es lo que usa `hayActualizacion`.
   **El estilo se compara igual**: `estilo.version` es el SHA-256 de `estilo/colportores.json`. Si es distinto del
   que la app guardó, vuelve a pedir el estilo (~240 KB); si es igual, no lo pide. Cambia cuando se publica la
   paleta nueva (`publicar --solo estilo`, que sube el estilo **y el catálogo**).
6. **Atribución visible**: «© OpenStreetMap» (ODbL). Viene en `sources.protomaps.attribution` y en `fuente` del catálogo.

El panel (navegador) lee lo mismo directo del bucket: por eso el CORS ([§ CORS y Range](#cors-y-range)).

## El catálogo

```json
{
  "version": 1,
  "generado_en": "2026-10-06T15:32:09Z",
  "fuente": { "proveedor": "Protomaps (datos de OpenStreetMap)", "atribucion": "© OpenStreetMap contributors", "licencia": "ODbL 1.0" },
  "estilo": { "url": "estilo/colportores.json", "fuente_de_tiles": "protomaps",
              "version": "3b5d5c3712955042212316173ccf37be800e3d2f4c0e1e6c4b2d7a9f8e1c0a64" },
  "paquetes": [
    {
      "id": "ciudad-montevideo",
      "nivel": "ciudad",
      "ambito_id": "0199a3f0-7c1e-7a4b-9d3e-5f2b8c6a1d40",
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
  ],
  "retirados": [
    { "archivo": "paquetes/ciudad/montevideo.0a1b2c3d4e5f.pmtiles", "desde": "2026-10-06T15:32:09Z" }
  ]
}
```

| campo | qué es |
|---|---|
| `version` (raíz) | versión del **formato** del catálogo (hoy 1); un cambio incompatible la sube |
| `generado_en` | cuándo se publicó el catálogo (ISO 8601, UTC) |
| `estilo.version` | SHA-256 del `estilo/colportores.json` publicado; si cambia, la app vuelve a pedir el estilo |
| `paquetes[].nivel` | `zona` < `ciudad` < `departamento` < `uruguay` (como `NivelCobertura` de la app) |
| `paquetes[].ambito_id` | id de la ciudad (`public.ciudad`) o de la zona en la base; **obligatorio en las ciudades**, la app elige el paquete por él |
| `paquetes[].zoom_min/zoom_max` | zooms que trae el archivo; más allá, MapLibre amplía el último |
| `paquetes[].tamano_bytes` | suma de las partes |
| `paquetes[].version` | qué cambió: SHA-256 de la parte única, o de los SHA-256 de las partes unidos con `\n` |
| `paquetes[].partes[]` | `archivo` (relativo al catálogo), `tamano_bytes`, `sha256` y, en ciudades, su `bbox` |
| `fuente_build` | build de Protomaps del que se cortó (`AAAAMMDD`) |
| `actualizado_en` | cuándo se cortó ese paquete |
| `retirados[]` | **solo para el publicador.** Archivos que el catálogo dejó de nombrar y todavía no se borraron: `archivo` y `desde` (cuándo salieron). De ahí se cuentan los 7 días de gracia. La app y el panel lo ignoran |

**Privacidad**: el catálogo es público. Los paquetes de zona **no llevan `nombre`, `bbox` ni `partes[].bbox`**; la app
ya conoce sus zonas por la réplica local y le alcanza con el id. Pero eso **no** esconde dónde trabaja cada equipo:
el archivo `.pmtiles` de una zona, que está en el bucket público, lleva su rectángulo en el encabezado y en los
tiles que trae, y cualquiera que lo baje lo ve. **Por eso no se publica ningún paquete de zona** hasta que Cristian
conteste la pregunta «Zona pública» (quién puede ver dónde están las zonas; pendiente `backend-42-zona-publica`).
Las ciudades no tienen este problema: son públicas.

Lo valida `tiles/src/catalogo.mjs` (`validar`) antes de subirlo: versión, ids únicos, rutas relativas, tamaños,
SHA-256, que `version` coincida con las partes, que el estilo traiga su `estilo.version` (un SHA-256), que cada
ciudad traiga su `ambito_id` y que un archivo no esté a la vez en un paquete y en `retirados`. Un catálogo inválido
no se publica.

El publicador **lee el catálogo anterior y pregunta si un paquete ya está por la API autenticada del Storage**
(`/storage/v1/object/authenticated/…`, con la clave de servicio), no por la URL pública: así decide con lo que
hay en el bucket y no con una copia que el CDN guardó hasta 60 s (el catálogo se sirve con `max-age=60`). Sin
clave (`--dry-run`) lee por la URL pública.

## El estilo

`tiles/paleta.json` + las capas de [`@protomaps/basemaps`](https://github.com/protomaps/basemaps) 5.7.2 dan
**un** estilo MapLibre (`estilo/colportores.json`), con la paleta del canvas de Claude Design (tierra
`#F6F5F0`, parques `#DDE8D3`, calles `#FFFFFF` y avenidas `#FBF1D6`), rótulos en español
(`name:es`), tipografía Noto Sans y la atribución de OSM. Lo genera `node src/cli.mjs estilo` (o `publicar`)
de forma determinista: la misma paleta da el mismo archivo.

Los rótulos que se leen (calles menores y mayores, barrios y números de puerta) van en `#5B6B82`, el «texto
atenuado» del canvas: **4,97:1 sobre su halo, AA**. Los grises que el canvas usa para esos rótulos dan 3,41:1 y
2,85:1 sobre la tierra y no llegan a 4,5:1; en este caso gana la accesibilidad (decisión del 06/10) y lo vigila
`tiles/test/estilo.test.mjs`. Los rótulos de provincia y de país (`state_label`, `country_label`) siguen en el gris
del canvas (`#8A93A0`): solo se ven con el mapa muy alejado y la decisión no los incluyó.

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
así que no hace falta bajar el zoom ni partirla. **El piso es el zoom 14**: es el último en el que todavía se
distingue una manzana (a 13 se pierden las puertas), así que antes de bajar de ahí la ciudad se parte en dos
archivos. El 15 es solo el primer intento, no un piso. Una ciudad partida pide que front-colportores-mobile#189 use
una fuente por parte.
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
lectura sin login, la lectura autenticada del publicador y que `anon` y `authenticated` no escriben ni borran. Ese Storage suelto no contesta CORS ni el preflight (de eso se ocupa el
gateway), así que la prueba pone delante un gateway mínimo que imita el plugin `cors` de Kong; lo que contesta el
proyecto real lo dice `verificar`. Si el CORS del proyecto no alcanzara, es un pendiente para Cristian: el gateway es
de Supabase y no se resuelve desde este repo.

## Seguridad

- El bucket es público para **leer**; no hay ninguna política sobre `storage.objects` para él, así que `anon` y
  `authenticated` no pueden subir, pisar, borrar ni listar. Solo `service_role` escribe, y lo prueban
  `supabase/tests/0036_bucket_mapas_test.sql` y `tiles/prueba-storage/acceso-anonimo.mjs`.
- La clave de servicio **no está en el repo**. Sale de los secretos del environment de GitHub ([§ Publicar](#publicar)).
  Tampoco sale por la consola: `publicar` y `verificar` pasan todo lo que imprimen por `ocultar`
  (`tiles/src/secretos.mjs`), también el cuerpo de un error HTTP (un servidor o un proxy puede devolver los
  encabezados que recibió, con el `Authorization`). Lo vigila `tiles/test/secretos.test.mjs`, con un servidor que
  hace justamente eso.
- Borrar: el Storage trae un trigger (`protect_objects_delete`) que rechaza con `42501` todo `DELETE` directo a
  `storage.objects`, salvo el que hace la propia API de Storage. Una política `for delete` demasiado abierta solo
  sería explotable por la API; aun así pgTAP 0036 activa `storage.allow_delete_query` para que el test vigile las
  políticas y no dependa de ese trigger.
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
1. lee de `public.ciudad` (PostgREST, con la clave de servicio) el id de cada ciudad a publicar. Si una no está, o
   hay más de una con ese nombre, **se detiene antes de subir nada** y dice cuál es: nunca publica un `ambito_id`
   nulo en una ciudad;
2. crea o ajusta el bucket `mapas` (público, 50 MiB, tipos permitidos);
3. sube el estilo, glyphs y sprites;
4. corta cada ciudad según la política de tamaño y sube sus partes **solo si ese SHA-256 todavía no está**;
5. valida y sube el catálogo, **último**; los archivos que el catálogo nuevo ya no nombra quedan anotados en
   `retirados`, con la fecha de esta corrida;
6. borra los archivos retirados hace más de **7 días** ([§ Qué se borra y cuándo](#qué-se-borra-y-cuándo)).

Repetir `publicar` con los mismos datos no sube nada nuevo («sin cambios»). Si los mapas no cambiaron pero sí
el nombre de la ciudad, su `bbox` o su `ambito_id`, el paquete conserva sus archivos y su `version` y el catálogo
se actualiza («datos del catálogo actualizados»). `--dry-run` hace todo menos escribir; sin clave de servicio no
puede leer la base, lo avisa y sigue sin `ambito_id` (solo el simulacro lo permite).

`--solo estilo` sube el estilo **y también el catálogo**, con la `estilo.version` nueva y los paquetes como
estaban: así los teléfonos se enteran de que el estilo cambió. `--solo ciudades` exige que el catálogo ya tenga
`estilo.version` (o sea, que el estilo ya se haya publicado): la primera vez, `publicar` sin `--solo`.

### Qué se borra y cuándo

Un archivo publicado puede seguir en uso un buen rato después de que el catálogo dejó de nombrarlo: un teléfono
con la descarga pausada la retoma por `Range` sobre el archivo que empezó (HU-SYNC-010), y un panel abierto lee su
PMTiles por `Range` directo del bucket. Por eso **los 7 días se cuentan desde que el archivo salió del catálogo, no
desde que se subió**:

- cuando una corrida publica un catálogo que ya no nombra un archivo, lo anota en `retirados` con `desde` = ese
  momento; si en una corrida posterior sigue sin nombrarse y pasaron más de 7 días desde `desde`, se borra;
- qué se borra se decide **antes** de subir el catálogo, y el catálogo se sube **antes** de borrar: lo que está por
  borrarse ya sale de `retirados` en ese catálogo. Si el borrado falla, el catálogo ya quedó publicado y la
  corrida siguiente junta lo que quedó, por su fecha de subida (que es más vieja que su fecha de retiro, así que
  ya pasaron los 7 días);
- un archivo que **nunca figuró** en ningún catálogo (una subida que no llegó a publicarse, o la de otro publicador
  en curso) no tiene `desde`: para ese vale la fecha de subida como piso, también 7 días.

Con la fecha de subida a secas (lo primero que se hizo) un mapa subido el 07/10 y reemplazado el 06/11 se borraba
en la misma corrida del 06/11, sin gracia alguna; lo reproduce y lo vigila la prueba de `tiles/test/publicar.test.mjs`
«republicar semanas después no borra en la misma corrida el mapa que acaba de dejar de ser el vigente».

### Con GitHub Actions

Workflow **Mapas** (`.github/workflows/tiles.yml`, `workflow_dispatch`): elegir environment (`develop`,
`staging`, `production`), qué publicar, y opcionalmente una ciudad y un build. Corre las pruebas, publica y
después `verificar`. Un solo publicador por environment a la vez (`concurrency`), porque todos reescriben el
mismo `catalogo.json`.

No pide secretos nuevos: usa `SUPABASE_PROJECT_ID` (de ahí sale `https://<id>.supabase.co`) y
`SUPABASE_ACCESS_TOKEN`, los de `deploy.yml`, y con el token el CLI de Supabase pide la clave de servicio, que
no se guarda en ningún lado (`supabase projects api-keys`; **sin probar contra el proyecto real**). Si el
environment define `SUPABASE_SERVICE_ROLE_KEY` o `SUPABASE_URL` (por ejemplo, un dominio propio), se usan
esos. Los secretos llegan solo al paso «Publicar»; `npm ci`, `npm test` y la verificación no los ven (la
verificación solo recibe la dirección del proyecto, que no es secreta).

Como cualquier `workflow_dispatch`, aparece en Actions cuando el archivo está en la rama por defecto
(`production`). Hasta entonces: a mano.

**Etapa 2:** cuando el workflow tenga un `schedule` (cada hora, para los paquetes de zona), correrá desde
`production`, y ahí no hay quién elija el environment. Cada corrida tiene que decir **a qué environment publica**:
una variable de repo por environment (como `DEPLOY_DEVELOP`) que lo encienda; sin ella, esa corrida no publica en
ese environment. Hoy el workflow es solo manual.

### Publicar a mano

Es la primera publicación (decisión del 06/10): la hace Cristian a mano el jueves 08/10, desde PowerShell, en un
checkout de `develop`. Necesita `SUPABASE_URL` y la clave de servicio (`SUPABASE_SERVICE_ROLE_KEY`, de Project
Settings → API). **Nunca** a un archivo del repo, ni escrita en el comando, ni en el historial de la consola: son
tres líneas.

```powershell
# 1. Con la clave de servicio copiada al portapapeles:
$env:SUPABASE_SERVICE_ROLE_KEY = Get-Clipboard

# 2. El comando de Docker, con -e SUPABASE_SERVICE_ROLE_KEY SIN valor (Docker toma el de la sesión):
docker run --rm -v "${PWD}/tiles:/app" -w /app -e SUPABASE_URL=https://<proyecto>.supabase.co -e SUPABASE_SERVICE_ROLE_KEY node:22-bookworm sh -c "npm ci && node src/cli.mjs publicar && node src/cli.mjs verificar"

# 3. Al terminar, que la clave no quede en la sesión:
Remove-Item Env:SUPABASE_SERVICE_ROLE_KEY
```

(`node:22-bookworm` y no `-slim`: `pmtiles` necesita los certificados de la imagen completa.)

Antes de publicar:
- el PR #73 mergeado (con el período de gracia contado desde el retiro y el `ambito_id` leído de la base);
- **Montevideo cargada en `public.ciudad` del proyecto de la demo**, y la campaña de la demo con Montevideo (los
  seeds traen ciudades ficticias): sin ella el publicador se detiene sin subir nada;
- la migración 0029 en el proyecto (`db push`), o el publicador crea el bucket solo.

Después, el `verificar` del mismo comando confirma CORS, `Range` y el *preflight* contra el proyecto real, que es
lo que no se pudo probar sin credenciales. Más adelante, el workflow «Mapas», cuando llegue a `production`.

### Verificar

`node src/cli.mjs verificar` no necesita ninguna clave (prueba lo que ve cualquiera) y sale con código 1 si algo falla.
Un «aviso» no es un error: hoy es que el gateway no expone `Content-Range` al navegador, que pmtiles.js no necesita.

## Cómo se actualiza

| qué cambia | qué se hace | qué ven los teléfonos |
|---|---|---|
| un build nuevo de Protomaps (diario) | **nada** por defecto. Re-cortar cada vez le haría bajar a todos ~11 MB de mapa casi idéntico. Se publica a mano cuando el mapa de OSM cambió lo que importa (calles nuevas, un barrio) | un `version` nuevo en el paquete → «hay actualización» |
| la paleta | editar `tiles/paleta.json`, probar, y publicar con `--solo estilo` (sube el estilo y el catálogo) | un `estilo.version` nuevo → la app vuelve a pedir el estilo |
| una ciudad nueva | que exista en `public.ciudad`, agregarla a `tiles/ciudades.json` (`slug`, `nombre`, `bbox`) y publicar con `--ciudad <slug>` ([§ Qué falta](#qué-falta-etapa-2): dónde se guarda su `bbox` está pendiente) | una entrada nueva en el catálogo |
| una ciudad que no entra en 50 MB | nada: la política baja el zoom o la parte en dos | `partes` con dos archivos |
| quitar una ciudad | sacarla de `ciudades.json` y del catálogo (a mano: `fusionar` con `quitar`); sus archivos se borran a los 7 días de haber salido del catálogo | desaparece del catálogo |

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

**Decidido el 06/10** (opción del `schedule`, sin webhook ni token en Vault): lo anterior se implementa en la etapa 2,
con dos condiciones: cada corrida dice a qué environment publica ([§ Con GitHub Actions](#con-github-actions)) y **no se
publica ningún paquete de zona** hasta que Cristian conteste «Zona pública» ([§ Privacidad](#el-catálogo)). Mientras
tanto el colportor no se queda sin mapa: el paquete de su ciudad cubre su zona.

Demora: hasta una hora desde que el coordinador guarda hasta que el paquete nuevo está en el bucket.
La alternativa más rápida (un webhook de la base, con `pg_net`, que dispare el workflow al guardar una zona) **implica
un token de GitHub en Vault**: se descartó para no sumar un secreto.

## Probar contra un Storage real

La base de CI no trae el servicio Storage (el schema `storage` está vacío), así que **la migración
`0029_bucket_mapas.sql` se saltea** ahí y **pgTAP 0036 también** (con un `skip` explícito). Para probarlas de
verdad, y el publicador de punta a punta, sin credenciales ni proyecto en la nube:

```sh
bash tiles/prueba-storage/correr.sh
```

Levanta la base de `compose.dev.yml`, el `storage-api` oficial, un PostgREST y un gateway que imita el CORS de
Supabase; aplica las migraciones (la 0029 crea el bucket), corre pgTAP 0036 completo, carga Montevideo en
`public.ciudad`, comprueba que **sin esa ciudad el publicador se detiene y no sube nada**, publica el estilo y
Montevideo (recorte real, necesita red), comprueba que el `ambito_id` del catálogo es el de la base y que
`estilo.version` es el SHA-256 del estilo publicado (`tiles/prueba-storage/ambito-del-catalogo.mjs`), corre
`verificar`, comprueba que el publicador lee por la API autenticada (`tiles/prueba-storage/lectura-autenticada.mjs`),
publica de nuevo (tiene que dar «sin cambios») y comprueba que con la clave anónima no se escribe. Con `SOLO_BASE=1` se detiene después de pgTAP 0036 (sin red ni recorte). Baja
imágenes la primera vez (`storage-api` ~1,4 GB, `node:22-bookworm` ~1,6 GB) y no construye ninguna.

**CI no ejercita nada de esto.** Sus jobs usan un Postgres sin el servicio Storage: la 0029 y pgTAP 0036 se saltean
(el job de migraciones las corre y las marca como salteadas) y el job **tiles** (`npm ci && npm test`) prueba el
publicador contra un Storage de mentira. Sumar un job con un Storage real a CI es el issue de seguimiento
[backend-supabase#75](https://github.com/Colportores/backend-supabase/issues/75), **a hacer antes de cualquier otra
migración que toque `storage.objects`**; hasta entonces, `correr.sh` se corre a mano cuando se toca la 0029, la 0036
o el publicador.

## Qué falta (etapa 2)

- **Las demás ciudades** (lista y `bbox` en `tiles/ciudades.json`; hoy solo Montevideo), medidas una por una.
- **Paquetes por zona** y su regeneración (propuesta arriba): leer las zonas, `region_sha256`, y sacar `partes[].bbox`
  del catálogo público para ellas. **No se publican hasta la respuesta a «Zona pública»** (pendiente
  `backend-42-zona-publica`): el archivo de una zona muestra su rectángulo a quien lo baje.
- **Dónde se guarda el rectángulo (`bbox`) de cada ciudad.** Hoy está en `tiles/ciudades.json`, y solo el de
  Montevideo; `public.ciudad` guarda el centro y el zoom inicial, no un rectángulo, y HU-ADM-005 dice que cada ciudad
  lo trae. Hasta que Cristian conteste «Área ciudad» (pendiente `backend-42-area-ciudad`) no se suman ciudades ni
  columnas.
- Que front-colportores-mobile#189 soporte paquetes de **varias partes** (una fuente por parte) si alguna ciudad lo
  necesita.

## Pendientes de decisión

Quedan escritos con su opción conservadora en el PR de backend-supabase#73 (marcados «Cristian §3» o «mapa §2»).
Los que esta guía nombra:

- **Área ciudad** (`backend-42-area-ciudad`): dónde se guarda el rectángulo de cada ciudad. Conservadora: solo
  Montevideo, con `tiles/ciudades.json`; su `ambito_id` sale de `public.ciudad`.
- **Zona pública** (`backend-42-zona-publica`): quién puede ver dónde están las zonas. Conservadora: no se publican
  paquetes de zona.

## Licencias y atribución

- Datos: © OpenStreetMap contributors, **ODbL 1.0**, vía los builds de [Protomaps](https://protomaps.com/).
  La atribución va en el estilo y en el catálogo; la app y el panel tienen que mostrarla.
- Capas del estilo: `@protomaps/basemaps` (BSD-3-Clause). Tipografía Noto Sans (OFL) y sprites (MIT): ver
  [`tiles/assets/NOTICE.md`](../tiles/assets/NOTICE.md).
