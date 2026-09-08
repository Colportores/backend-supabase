#!/usr/bin/env bash
# Falla si hay SQL versionado fuera de supabase/.
#
# Por qué existe: `supabase migration up` (db-migrate.sh, que es lo que corre CI)
# y `supabase db push` (deploy.yml) leen ÚNICAMENTE supabase/migrations/. Un
# árbol de SQL en cualquier otro lado del repo sale verde en CI sin que se haya
# aplicado ni probado una sola línea, y el deploy lo ignora igual.
#
# No es hipotético: el PR #5 subió 14 migraciones y 4 archivos de tests en
# `migrations/` y `test/` en la raíz. CI dio verde. Entre ellos venía un
# `alter table entrega add column notas text` — que el guard de privacidad de
# `supabase/tests/0001_esquema_inicial_test.sql` rechaza sin dudar, pero que
# nunca llegó a evaluarse porque esa migración no la aplicó nadie.
#
# El guard de privacidad estaba bien. Lo que faltaba era que el SQL llegara hasta él.
set -euo pipefail

cd "$(dirname "$0")/.."

sueltos="$(git ls-files '*.sql' | grep -v '^supabase/' || true)"

if [ -n "$sueltos" ]; then
  cat >&2 <<EOF
SQL versionado fuera de supabase/:

$(echo "$sueltos" | sed 's/^/  /')

Ni el CI ni el deploy aplican estos archivos: 'supabase migration up' y
'supabase db push' solo leen supabase/migrations/. Tal como están, no los
verifica nadie.

Las migraciones van en  supabase/migrations/<timestamp>_<nnnn>_<descripcion>.sql
Los tests pgTAP van en  supabase/tests/
Los seeds van en        supabase/seed.sql   (config.toml -> db.seed.sql_paths)
EOF
  exit 1
fi

echo "OK: todo el SQL del repo vive en supabase/"
