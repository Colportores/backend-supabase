#!/usr/bin/env bash
# Deja las imágenes de registros públicos en el Docker local, sin que un registro caído tire el job.
# Lo usa CI (y tiles/prueba-storage/correr.sh) antes de levantar la base. Por cada imagen:
#   1. si ya está en Docker (y, con digest, es la fijada en scripts/ci-imagenes.txt), no hace nada;
#   2. si hay `--cache DIR` y DIR trae su tar (`docker save` de una corrida anterior), la carga: no toca la red;
#   3. si no, la baja recorriendo la cadena de registros de scripts/ci-imagenes.txt (el primario, ghcr.io, y
#      después sus espejos): con digest, por `repo@sha256:…`, así que el registro que la entregue tiene que dar
#      los mismos bits; sin digest (tag que se mueve), por tag. Hasta 3 rondas de toda la cadena, con espera de
#      20 y 60 s entre rondas (CI_PULL_ESPERAS="20 60" las cambia; las pruebas del script usan "0 0");
#   4. con `--cache DIR`, guarda el tar de lo que bajó para la próxima corrida.
# Solo el pull se reintenta: nunca las pruebas. Una imagen que no está en la tabla se baja igual, solo del
# nombre que se pidió (como antes del espejo), con el mismo reintento.
#
# Uso: bash scripts/ci-pull.sh [--cache DIR] (--grupo GRUPO | <imagen>...)
# Variable de prueba: CI_IMAGENES_TABLA (otra tabla en lugar de scripts/ci-imagenes.txt).
set -euo pipefail

AQUI="$(cd "$(dirname "$0")" && pwd)"
TABLA="${CI_IMAGENES_TABLA:-$AQUI/ci-imagenes.txt}"
read -r -a ESPERAS <<<"${CI_PULL_ESPERAS:-20 60}"
RONDAS=3

CACHE=""
GRUPO=""
IMAGENES=()
uso() { echo "uso: $0 [--cache DIR] (--grupo GRUPO | <imagen>...)" >&2; exit 2; }
while [ "$#" -gt 0 ]; do
  case "$1" in
    --cache) [ "$#" -ge 2 ] || uso; CACHE="$2"; shift 2 ;;
    --grupo) [ "$#" -ge 2 ] || uso; GRUPO="$2"; shift 2 ;;
    -*) uso ;;
    *) IMAGENES+=("$1"); shift ;;
  esac
done

# Filas de la tabla sin comentarios ni CR (por si el checkout es de Windows).
filas() { tr -d '\r' <"$TABLA" | awk '!/^[[:space:]]*#/ && NF'; }

if [ -n "$GRUPO" ]; then
  [ "${#IMAGENES[@]}" -eq 0 ] || uso
  mapfile -t IMAGENES < <(filas | awk -v g="$GRUPO" '$1 == g { print $2 }')
  [ "${#IMAGENES[@]}" -gt 0 ] || { echo "FALLO: el grupo '$GRUPO' no tiene imágenes en $TABLA" >&2; exit 1; }
fi
[ "${#IMAGENES[@]}" -gt 0 ] || uso

# La imagen está en Docker. Con digest fijado: o es la fijada, o no registra ninguno (se cargó de un tar, que
# `docker load` no siempre acompaña de sus digests).
presente() { # $1 imagen, $2 digest ("-" si no hay)
  docker image inspect "$1" >/dev/null 2>&1 || return 1
  [ "$2" = "-" ] && return 0
  local digs
  digs="$(docker image inspect --format '{{range .RepoDigests}}{{println .}}{{end}}' "$1")"
  [ -z "$digs" ] || grep -q "@$2\$" <<<"$digs"
}

# Una referencia por línea, en el orden de la cadena.
referencias() { # $1 imagen, $2 digest, $3 espejos
  local repo="${1%:*}" tag="${1##*:}" e
  if [ "$2" = "-" ]; then
    echo "$1"
    for e in $3; do echo "$e:$tag"; done
  else
    echo "$repo@$2"
    for e in $3; do echo "$e@$2"; done
  fi
}

TIMEOUT=()
if command -v timeout >/dev/null 2>&1; then TIMEOUT=(timeout 900); fi
ERR="$(mktemp)"
trap 'rm -f "$ERR"' EXIT

bajar() { # $1 imagen, $2 digest, $3 espejos
  local ronda ref
  local -a refs
  mapfile -t refs < <(referencias "$1" "$2" "$3")
  for ((ronda = 0; ronda < RONDAS; ronda++)); do
    for ref in "${refs[@]}"; do
      if "${TIMEOUT[@]+"${TIMEOUT[@]}"}" docker pull -q "$ref" >/dev/null 2>"$ERR"; then
        if [ "$ref" != "$1" ]; then docker tag "$ref" "$1"; fi
        if presente "$1" "$2"; then
          echo "$1: bajada de $ref"
          return 0
        fi
        echo "$1: lo bajado de $ref no es el digest fijado $2" >&2
      else
        echo "$1: falló el pull de $ref: $(tail -n 1 "$ERR" | cut -c1-300)" >&2
      fi
    done
    if [ "$ronda" -lt $((RONDAS - 1)) ]; then
      echo "$1: ningún registro contestó (ronda $((ronda + 1)) de $RONDAS); reintento en ${ESPERAS[$ronda]:-0} s" >&2
      sleep "${ESPERAS[$ronda]:-0}"
    fi
  done
  return 1
}

for imagen in "${IMAGENES[@]}"; do
  fila="$(filas | awk -v i="$imagen" '$2 == i { print; exit }')"
  if [ -n "$fila" ]; then
    read -r _ _ digest espejos <<<"$fila"
  else
    echo "$imagen: no está en $(basename "$TABLA"); la bajo solo de su registro" >&2
    digest="-"
    espejos=""
  fi
  tar=""
  if [ -n "$CACHE" ]; then tar="$CACHE/$(tr '/:@' '___' <<<"$imagen").tar"; fi

  if presente "$imagen" "$digest"; then
    echo "$imagen: ya está en Docker"
  elif [ -n "$tar" ] && [ -f "$tar" ] && docker load -q -i "$tar" >/dev/null && docker image inspect "$imagen" >/dev/null 2>&1; then
    echo "$imagen: cargada de la caché"
    continue
  else
    if [ -n "$tar" ] && [ -f "$tar" ]; then echo "$imagen: la caché no sirvió; la bajo" >&2; rm -f "$tar"; fi
    bajar "$imagen" "$digest" "$espejos" || { echo "FALLO: no pude bajar $imagen de ningún registro ($imagen $espejos)" >&2; exit 1; }
  fi

  if [ -n "$tar" ] && [ ! -f "$tar" ]; then
    mkdir -p "$CACHE"
    if docker save -o "$tar.tmp" "$imagen"; then mv "$tar.tmp" "$tar"; else rm -f "$tar.tmp"; echo "aviso: no pude guardar $imagen en la caché" >&2; fi
  fi
done
