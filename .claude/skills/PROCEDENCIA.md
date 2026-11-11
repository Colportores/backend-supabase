# Procedencia de las skills de este repo

Skills de dominio instaladas para trabajar sobre Supabase/Postgres, tal como las publica el propio equipo de Supabase — no son de autoría del equipo de Colportores.

| Skill | Fuente oficial | Versión / commit al instalar | Licencia |
|---|---|---|---|
| `supabase` | [supabase/agent-skills](https://github.com/supabase/agent-skills) → `skills/supabase` | v0.1.2 · commit `8331f91` (2026-08-12) | MIT |
| `supabase-postgres-best-practices` | [supabase/agent-skills](https://github.com/supabase/agent-skills) → `skills/supabase-postgres-best-practices` | v1.1.1 · commit `8331f91` (2026-08-12) | MIT |

## Por qué estas dos

- `supabase`: guía general del producto (CLI, MCP, Auth, RLS, Storage, Realtime, Edge Functions) — cubre todo lo que toca este repo salvo el detalle fino de SQL.
- `supabase-postgres-best-practices`: reglas de Postgres puro (índices, locking, particionado, RLS performante) — el complemento natural para migraciones y RPCs.

No se instaló ninguna otra skill del catálogo de terceros de la organización (Next.js, Cloudflare, Flutter): no aplican al dominio de `backend-supabase`.

## Cómo refrescarlas

```sh
git clone --depth 1 https://github.com/supabase/agent-skills /tmp/supabase-agent-skills
for s in supabase supabase-postgres-best-practices; do
  rm -rf .claude/skills/$s
  cp -r /tmp/supabase-agent-skills/skills/$s .claude/skills/$s
  cp /tmp/supabase-agent-skills/LICENSE .claude/skills/$s/LICENSE
done
```

Revisar el diff antes de commitear — Supabase las actualiza seguido (ver su `CHANGELOG.md` por skill).
