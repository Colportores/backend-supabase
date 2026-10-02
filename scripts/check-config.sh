#!/usr/bin/env bash
# Falla si supabase/config.toml baja el mínimo de contraseña por debajo del de la app.
#
# Por qué existe: el servidor tiene que exigir al menos lo que exige la app (HU-AUTH-001, S1: 8
# caracteres). Con menos, cualquier cliente que le hable directo a Auth puede registrar una
# contraseña que la app rechaza. El valor del proyecto hosteado no sale de este archivo (va por
# `supabase config push` o por el panel), pero este es el que se versiona y el que se copia al
# desplegar: que no se vuelva atrás sin que CI lo note. No necesita Docker.
#
# `password_requirements` queda vacío a propósito: la mayúscula (cualquier letra mayúscula Unicode)
# la valida la app, y las opciones de Supabase no la cubren.
set -euo pipefail

cd "$(dirname "$0")/.."

MINIMO=8
valor="$(sed -n 's/^[[:space:]]*minimum_password_length[[:space:]]*=[[:space:]]*\([0-9][0-9]*\).*$/\1/p' supabase/config.toml | head -n 1)"

if [ -z "$valor" ]; then
  echo "supabase/config.toml no define minimum_password_length (el default de Supabase es 6, menos que el de la app)." >&2
  exit 1
fi

if [ "$valor" -lt "$MINIMO" ]; then
  echo "supabase/config.toml: minimum_password_length = $valor, y la app exige $MINIMO (HU-AUTH-001)." >&2
  echo "Subilo a $MINIMO o más; en el proyecto hosteado va por 'supabase config push' o por el panel." >&2
  exit 1
fi

echo "OK: minimum_password_length = $valor (la app exige $MINIMO)"
