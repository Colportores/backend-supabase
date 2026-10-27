-- ============================================================================
-- 0115 · El servidor frena la jornada antes del inicio de la campaña, como la venta
--        (backend-supabase#165, seguimiento de #142 / PR #164)
--
-- Decisión de Cristian (23/10), «Cuenta antes» (backend-supabase#103, comentario 6371163825): hasta que
-- empieza la campaña no hay jornada ni venta. Decisión del orquestador (26/10), por el mapa de decisiones,
-- pendiente P2 de #142 (PR #164, comentario 6421235386): la 0102 frenó la venta en el servidor; la jornada
-- lleva el mismo freno, con el mismo criterio, en este issue de seguimiento.
--
-- Caso de uso: Agustín está inscripto en una campaña que empieza el 1/12 y el 20/11 inicia una jornada
-- desde un teléfono desactualizado o por la API. Hoy la jornada entra (la única política de `jornada` es
-- `jornada_propio`, colportor_id = auth.uid(), 0003).
--
-- ## La regla (la misma que la venta, 0102)
--
-- Una política RESTRICTIVA de INSERT sobre `jornada`, `jornada_no_antes_del_inicio`, rechaza (42501, que el
-- push devuelve como `invalid`) la jornada cuyo día cae antes del inicio de todas las campañas del
-- colportor. El día es el de la jornada (`jornada.inicio`, en America/Montevideo) y no el del servidor: así
-- una jornada que ya está en el teléfono y se sincroniza tarde no se pierde. Es
-- `venta_antes_del_inicio(inicio)` de la 0102, que ya mira:
--   · se rechaza si el colportor tiene una inscripción VIVA en una campaña (no borrada) que empieza
--     DESPUÉS de ese día, y
--   · no se rechaza si tiene alguna inscripción (viva o dada de baja) en una campaña que ya había empezado
--     ese día y a la que no le pasó el plazo de 15 días desde su fin (0020; sin `fecha_fin` es abierta).
-- Quien no tiene inscripciones por empezar (ninguna, o solo en campañas terminadas o borradas) no cambia.
-- Una inscripción dada de baja cuenta como cobertura: la jornada de entonces se acepta.
--
-- ## Cómo
--
-- Solo el alta: cerrar una jornada (poner `fin`), cargar el acompañamiento o corregirla sigue igual, como
-- con la venta. La política solo rige para `authenticated` (el push corre INVOKER); las funciones
-- SECURITY DEFINER y el servidor no pasan por acá. No hay función nueva: la política llama a
-- `venta_antes_del_inicio(timestamptz)` (0102), que ya está concedida a authenticated y service_role.
--
-- ## Los datos
--
-- No toca ninguna fila ni función: suma una política. Las jornadas que ya están en la base siguen valiendo.
--
-- Depende de la 0102 (PR #164): hasta que esté en develop, esta migración no aplica.
-- Forward-only: esta migración no se edita una vez aplicada.
-- ============================================================================

-- RESTRICTIVE: se suma a jornada_propio (colportor_id = auth.uid()), no la reemplaza.
create policy jornada_no_antes_del_inicio on public.jornada
  as restrictive
  for insert
  to authenticated
  with check (not public.venta_antes_del_inicio(inicio));

comment on policy jornada_no_antes_del_inicio on public.jornada is
  'El servidor no acepta una jornada que empieza antes del inicio de la campaña del colportor, por el día '
  'de jornada.inicio en America/Montevideo, con el mismo criterio que venta_no_antes_del_inicio (0115, '
  'backend-supabase#165, decisión de Cristian del 23/10 «Cuenta antes»).';
