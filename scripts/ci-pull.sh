#!/usr/bin/env bash
# Baja imágenes con reintento acotado (3 intentos, esperas de 20 s y 60 s). Solo para el pull: lo
# usa CI antes de levantar la base, para que un `toomanyrequests` pasajero de ghcr.io (el registro
# contesta con un límite global por IP aun con login, y en ráfagas) no tire el job. Nunca se usa para
# reintentar pruebas: si algo falla después del pull, falla.
# Uso: bash scripts/ci-pull.sh <imagen>...
set -euo pipefail

[ "$#" -gt 0 ] || { echo "uso: $0 <imagen>..." >&2; exit 2; }

for imagen in "$@"; do
  for intento in 1 2 3; do
    if docker pull -q "$imagen" >/dev/null; then break; fi
    if [ "$intento" = 3 ]; then echo "FALLO: no pude bajar $imagen en 3 intentos" >&2; exit 1; fi
    espera=$(( intento == 1 ? 20 : 60 ))
    echo "pull de $imagen falló (intento $intento de 3); reintento en ${espera} s" >&2
    sleep "$espera"
  done
done
