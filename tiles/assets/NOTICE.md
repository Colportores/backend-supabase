# Glyphs y sprites del mapa

Lo que hay en esta carpeta se publica tal cual en el bucket `mapas`, bajo `estilo/glyphs/` y
`estilo/sprites/` (ver `docs/mapas-tiles.md`). Salen de
[protomaps/basemaps-assets](https://github.com/protomaps/basemaps-assets), fijado al commit
`028c18f713baecad011301ff7a69acc39bcc2ae7` (31/10/2025), la misma familia de assets que usa
`@protomaps/basemaps` 5.7.2, el paquete que arma las capas del estilo.

## Glyphs (`glyphs/`)

- Fuente: Noto Sans (Regular, Medium e Italic), convertida a PBF con
  [font-maker](https://github.com/maplibre/font-maker).
- Licencia: SIL Open Font License 1.1, en `glyphs/OFL.txt`.
- Las carpetas se llaman `NotoSans-Regular`, `NotoSans-Medium` y `NotoSans-Italic` (el original lleva
  espacios: «Noto Sans Regular»). El estilo usa esos nombres, y así ninguna ruta del bucket lleva espacios.
- Solo los rangos que necesita un mapa en español: `0-255` (latín básico y Latin-1: tildes, ñ, ¿, ¡),
  `256-511` (latín extendido) y `8192-8447` (puntuación general: comillas, rayas, puntos suspensivos).
  Un nombre en otro alfabeto no se dibuja: el pedido de su rango da 404 y el texto sale sin esos caracteres.

## Sprites (`sprites/`)

- Hoja `grayscale` (v4), a 1x y 2x, con su índice JSON: flechas de calles de un solo sentido, escudos de
  ruta y las marcas de capital y de localidad. No trae los íconos de los puntos de interés, por eso el
  estilo no dibuja esa capa (ver `paleta.json`, `sin_capas`).
- Licencia: derivados de [tangrams/icons](https://github.com/tangrams/icons), MIT:

  > The MIT License (MIT)
  >
  > Copyright (c) 2017 Mapzen
  >
  > Permission is hereby granted, free of charge, to any person obtaining a copy of this software and
  > associated documentation files (the "Software"), to deal in the Software without restriction,
  > including without limitation the rights to use, copy, modify, merge, publish, distribute,
  > sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is
  > furnished to do so, subject to the following conditions:
  >
  > The above copyright notice and this permission notice shall be included in all copies or
  > substantial portions of the Software.
  >
  > THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT
  > NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
  > NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM,
  > DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT
  > OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

## Los datos del mapa

No están acá: son los PMTiles que se cortan de los builds de [Protomaps](https://protomaps.com/), con
datos de OpenStreetMap (© OpenStreetMap contributors, ODbL 1.0). La atribución viaja en el estilo
(`sources.protomaps.attribution`) y en el catálogo (`fuente`).
