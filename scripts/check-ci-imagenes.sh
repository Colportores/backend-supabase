#!/usr/bin/env bash
# Comprueba que scripts/ci-imagenes.txt (digest y espejos de las imágenes de CI) no se desfase de lo que
# realmente usan compose.dev.yml y tiles/prueba-storage/correr.sh. Sin Docker: es grep.
#   - toda imagen de ghcr.io que nombran esos dos archivos tiene que estar en la tabla;
#   - toda imagen de la tabla tiene que nombrarse en alguno de los dos.
# Si cambiás un tag y no la fila, CI seguiría cacheando la imagen vieja y bajaría la nueva sin espejo.
set -euo pipefail

cd "$(dirname "$0")/.."
USADORES=(compose.dev.yml tiles/prueba-storage/correr.sh)
TABLA="$(tr -d '\r' <scripts/ci-imagenes.txt | awk '!/^[[:space:]]*#/ && NF { print $2 }' | sort -u)"
[ -n "$TABLA" ] || { echo "FALLO: scripts/ci-imagenes.txt no tiene filas" >&2; exit 1; }

fallo=0
while read -r imagen; do
  [ -n "$imagen" ] || continue
  if ! grep -qxF "$imagen" <<<"$TABLA"; then
    echo "FALLO: $imagen se usa en ${USADORES[*]} pero no está en scripts/ci-imagenes.txt" >&2
    fallo=1
  fi
done < <(grep -ohE 'ghcr\.io/[a-z0-9/_.-]+:[A-Za-z0-9_-][A-Za-z0-9._-]*[A-Za-z0-9_]' "${USADORES[@]}" | sort -u)

while read -r imagen; do
  if ! grep -qF "$imagen" "${USADORES[@]}"; then
    echo "FALLO: $imagen está en scripts/ci-imagenes.txt pero ya no la nombra ${USADORES[*]}" >&2
    fallo=1
  fi
done <<<"$TABLA"

[ "$fallo" = 0 ] || exit 1
echo "scripts/ci-imagenes.txt coincide con las imágenes de compose.dev.yml y correr.sh"
