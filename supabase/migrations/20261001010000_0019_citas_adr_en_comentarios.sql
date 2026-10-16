-- ============================================================================
-- 0019 · Citas de ADR en los comentarios del catálogo (backend-supabase#43, pendiente de #50)
--
-- #50 tradujo a la numeración de docs-organizacion (renumeración del 23/09, tabla de
-- equivalencias en docs/decisiones/README.md) las citas de ADR de los comentarios `--` de 0001
-- y 0002. Las que viven en el catálogo (comment on) no se podían tocar ahí: 0001 y 0002 ya están
-- aplicadas, y cambiarlas dejaba una base nueva distinta de las desplegadas (revisión de #50).
-- Van acá:
--   · espacio.numero_depto (0001): los ADR-012 y ADR-018 viejos → ADR-004 (el viejo ADR-012 se
--     fusionó en ADR-004, que dejó su política como opción descartada);
--   · el esquema sync (0002): el ADR-017 §4 viejo (el paquete sync_engine) → ADR-008.
-- El comment on table public.ubicacion de 0001 citaba el ADR-018 viejo, pero 0011 ya lo
-- reemplazó con la cita nueva (ADR-004).
-- Citas viejas adentro de cuerpos de función (pg_proc.prosrc): la de sync.aplicar_job() (0002,
-- ADR-013 viejo) ya no está, porque 0017 y 0018 la redefinen sin ese comentario. La de
-- public.tiene_rol() (0001, ADR-011 viejo → ADR-005) no se toca: reescribir la función de roles
-- para cambiar un comentario no vale el riesgo.
--
-- Datos: ninguno; solo comentarios del catálogo.
-- Forward-only: esta migración no se edita una vez aplicada.
-- ============================================================================

comment on column public.espacio.numero_depto is
  'Va al cloud siempre. ADR-004 descartó propagarlo solo con operaciones financieras: va con '
  'la casa, igual que calle/numero.';

comment on schema sync is
  'Maquinaria de sincronización (ADR-008). No se expone en la Data API: config.toml '
  'lista solo public y graphql_public. Se llega por los RPC, con el JWT del usuario.';
