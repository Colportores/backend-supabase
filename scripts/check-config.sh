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

# Redirecciones permitidas de Auth (backend-supabase#299): direcciones completas, sin comodines. Un `*`
# dejaría que el enlace del correo termine en cualquier sitio que coincida con el patrón.
if redirecciones="$(awk '/^additional_redirect_urls[[:space:]]*=/{e=1} e{print} e&&/\]/{exit}' supabase/config.toml)" && [ -n "$redirecciones" ]; then
  if printf '%s' "$redirecciones" | grep -q '\*'; then
    echo "supabase/config.toml: additional_redirect_urls lleva un comodín (*). Cada dirección va completa y exacta." >&2
    exit 1
  fi
  for dir in "http://localhost:3000/acceso/nueva-contrasena" "http://127.0.0.1:3000/acceso/nueva-contrasena"; do
    if ! printf '%s' "$redirecciones" | grep -qF "\"$dir\""; then
      echo "supabase/config.toml: falta $dir en additional_redirect_urls (el enlace de «Olvidé mi contraseña» del panel cae en site_url)." >&2
      exit 1
    fi
  done
  echo "OK: additional_redirect_urls sin comodines y con la dirección de «Nueva contraseña» del panel"
else
  echo "supabase/config.toml no define additional_redirect_urls." >&2
  exit 1
fi

# Correo de «Olvidé mi contraseña» (backend-supabase#313): el enlace lleva su propio código de un solo uso (`token_hash`), no el
# `ConfirmationURL` con PKCE, que solo abre en el navegador donde se pidió. Tiene que estar la plantilla en config.toml, el archivo
# tiene que existir y su enlace usar `.TokenHash` (con `type=recovery`) y no `.ConfirmationURL`.
plantilla="$(awk '/^\[auth\.email\.template\.recovery\]/{e=1;next} /^\[/{e=0} e && /^content_path[[:space:]]*=/{print; exit}' supabase/config.toml | sed -n 's/^content_path[[:space:]]*=[[:space:]]*"\(.*\)".*$/\1/p')"
if [ -z "$plantilla" ]; then
  echo "supabase/config.toml no define [auth.email.template.recovery] con su content_path (el correo de «Olvidé mi contraseña» con enlace de un solo uso)." >&2
  exit 1
fi
if [ ! -f "$plantilla" ]; then
  echo "supabase/config.toml: la plantilla de recuperación $plantilla no existe." >&2
  exit 1
fi
if ! grep -q '{{ *\.TokenHash *}}' "$plantilla" || ! grep -q 'type=recovery' "$plantilla"; then
  echo "$plantilla: el enlace tiene que llevar {{ .TokenHash }} y type=recovery (el código de un solo uso que se abre en cualquier navegador)." >&2
  exit 1
fi
if grep -q '\.ConfirmationURL' "$plantilla"; then
  echo "$plantilla: no usar {{ .ConfirmationURL }} (PKCE: solo abre en el navegador donde se pidió el correo)." >&2
  exit 1
fi
echo "OK: el correo de recuperación usa el enlace de un solo uso ($plantilla)"
