-- ============================================================================
-- 0058 · Sumar colportores y asignar zona desde que la campaña existe
--        (backend-supabase#103, decisión de Cristian del 21/10, «Antes inicio»)
--
-- El caso: Marta suma a Agustín y le asigna zona el 20/11 en una campaña que empieza el 1/12, para
-- que él baje el mapa y las casas con wifi antes del primer día (decisiones del 30/09, backend#39, y
-- del 02/10, backend#45 / HU-SYNC-011). Hasta hoy `inscribir_colportor()` y `asignar_zona()` exigían
-- que la campaña ya hubiera empezado y no hubiera terminado (`campania_vigente()`, CI002 / CZ002 en
-- una por empezar). Cristian lo cambió el 21/10: «Sí, desde que la campaña existe» (backend-supabase
-- #82, pendiente `backend-supabase-54-rev-261015-2356.md` P2). La regla pasa a ser «la campaña no
-- terminó».
--
-- ## Qué cambia
--
--   1. `motivo_campania_del_coordinador(campania)` (0006): el permiso es el mismo, pero ya no pide
--      que la campaña haya empezado: solo que no haya terminado (`fecha_fin < hoy_montevideo()`,
--      el mismo criterio de `motivo_mapa_de_campania()`, 0024). Sigue devolviendo
--      `CAMPANIA_NO_VIGENTE` para la terminada, así que el aviso de una campaña terminada no cambia
--      (CI002 «La campaña no está activa…» al inscribir y buscar, CZ002 «La campaña no está
--      activa.» al asignar y quitar la zona). Lo que deja de salir es ese mismo aviso en una campaña
--      por empezar. Es la regla compartida por cinco funciones, que cambian juntas (mismo caso, misma
--      regla):
--        · `inscribir_colportor()` y `buscar_candidatos()` (vista 23, «Añadir colportor»), por
--          `motivo_rechazo_inscripcion()`;
--        · `asignar_zona()` (por `motivo_rechazo_zona()`) y `quitar_zona()` (vista 24): quien puede
--          asignar una zona antes del inicio también puede quitarla.
--      `colportores_de_campania()` y `zonas_asignables()` ya leían con el criterio del mapa desde la
--      0033: no se tocan (una campaña por empezar ahora lista a sus inscriptos en vez de una lista
--      vacía).
--   2. `motivo_rechazo_inscripcion()` (0028): la regla de la otra campaña (R-CM02, «una sola
--      campaña activa a la vez») pasa de «ya está en otra campaña vigente» a «ya está en otra
--      campaña del mismo momento»:
--        · una campaña en curso (empezó y no terminó) y otra por empezar se pueden tener a la vez:
--          un colportor que sigue en una campaña en curso se puede sumar a la que empieza después;
--        · dos en curso a la vez siguen sin poderse (CI007, «Está en campaña X. Reasignar primero.»);
--        · dos por empezar a la vez tampoco: la decisión de Cristian habla de «una en curso y otra por
--          empezar» y no dice nada de dos por empezar; ante la duda se bloquea y queda como pendiente
--          (`backend-supabase-103-impl-261022-*.md` P1). Se destraba sacando una comparación.
--      La campaña en conflicto es siempre otra campaña no terminada y no borrada en la que el usuario
--      tiene una inscripción viva; si hay más de una, la que empezó más tarde.
--
-- ## Lo que NO cambia
--
--   · `campania_vigente()`, `campanias_vigentes_de()` y `mis_campanias_vigentes()` siguen diciendo
--     «en curso» (empezó y no terminó): de ellas salen el estado de la cuenta (`estado_cuenta()`,
--     `colportores_de_campania().estado`, `buscar_candidatos()`), `mis_zonas()` y la RLS. Un colportor
--     inscripto solo en una campaña por empezar sigue en `PENDIENTE_ASIGNACION` hasta que ella
--     empiece: eso es lo que NO está decidido y queda como pendiente (P2 del mismo archivo).
--   · Los códigos y los textos de rechazo: CI001..CI007 y CZ001..CZ006, CZ014 como estaban.
--   · El resto de las reglas de inscribir y asignar: permiso, usuario existente, email verificado,
--     no suspendido, no inscripto ya, zona viva de una ciudad viva de esa campaña.
--   · El lock por usuario de `inscribir_colportor()` (dos coordinadores a la vez), la reactivación de
--     una inscripción dada de baja (0028) y el orden de los locks de `asignar_zona()`.
--
-- ## Los datos
--
-- No toca ninguna fila: solo redefine funciones (`create or replace`, misma firma, mismos privilegios
-- y mismos comentarios salvo los que describían «campaña vigente»). Las inscripciones y las zonas de
-- hoy siguen valiendo. Ningún camino borra del teléfono ubicaciones, espacios, personas ni ventas.
--
-- ## Para otros repos
--
--   · front-coordinadores-web (vista 23, #41): «Añadir colportor» deja de recibir CI002 en una
--     campaña por empezar y puede recibir CI007 si el colportor ya está en otra campaña del mismo
--     momento; el aviso de «no está activa» queda solo para la terminada.
--   · docs-organizacion (HU-CAM-004, docs#72): «mi campaña activa» pasa a «una campaña de la que soy
--     coordinador y que no terminó».
--
-- Forward-only: esta migración no se edita una vez aplicada.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. El permiso compartido: la campaña no terminó
-- ----------------------------------------------------------------------------

-- Igual que en 0006, salvo la última regla: antes `not campania_vigente()` (no empezó o terminó),
-- ahora solo la que ya terminó, según el día de Montevideo (0024).
create or replace function public.motivo_campania_del_coordinador(p_campania_id uuid)
returns text
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_campania public.campania;
  v_es_admin boolean := public.tiene_rol('ADMIN');
begin
  if auth.uid() is null or not (v_es_admin or public.tiene_rol('COORDINADOR')) then
    return 'SIN_PERMISO';
  end if;

  select * into v_campania from public.campania c where c.id = p_campania_id;
  if not found or v_campania.deleted_at is not null then
    return 'CAMPANIA_INEXISTENTE';
  end if;

  if not v_es_admin and v_campania.coordinador_id is distinct from auth.uid() then
    return 'SIN_PERMISO';
  end if;

  if v_campania.fecha_fin is not null and v_campania.fecha_fin < public.hoy_montevideo() then
    return 'CAMPANIA_NO_VIGENTE';
  end if;

  return null;
end;
$$;

comment on function public.motivo_campania_del_coordinador(uuid) is
  'null si el usuario autenticado es ADMIN o el coordinador de p_campania_id y la campaña no '
  'terminó (en curso o por empezar; el día se cuenta en America/Montevideo, 0024, 0058); si no, '
  'SIN_PERMISO | CAMPANIA_INEXISTENTE | CAMPANIA_NO_VIGENTE (terminada). Interna: la usan '
  'motivo_rechazo_inscripcion(), motivo_rechazo_zona(), quitar_zona() y buscar_candidatos().';

-- ----------------------------------------------------------------------------
-- 2. Inscribir: una en curso y otra por empezar sí; dos del mismo momento no
-- ----------------------------------------------------------------------------

-- Igual que en 0028, salvo EN_OTRA_CAMPANIA: antes cualquier inscripción viva en una campaña en
-- curso (campanias_vigentes_de()); ahora cualquier inscripción viva en otra campaña no terminada que
-- esté en el mismo momento que esta (las dos en curso, o las dos por empezar).
create or replace function public.motivo_rechazo_inscripcion(
  p_campania_id uuid, p_usuario_id uuid,
  out motivo text, out campania_en_conflicto uuid)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_usuario  public.usuario;
  v_campania public.campania;
  v_hoy      date := public.hoy_montevideo();
begin
  motivo := public.motivo_campania_del_coordinador(p_campania_id);
  if motivo is not null then
    return;
  end if;

  select * into v_usuario from public.usuario u where u.id = p_usuario_id;
  if not found or v_usuario.deleted_at is not null then
    motivo := 'USUARIO_INEXISTENTE'; return;
  end if;

  -- confirmed_at y no email_confirmed_at: ver 0005.
  if not exists (select 1 from auth.users au
                  where au.id = p_usuario_id and au.confirmed_at is not null) then
    motivo := 'EMAIL_NO_VERIFICADO'; return;
  end if;

  if v_usuario.suspendido_en is not null then
    motivo := 'USUARIO_SUSPENDIDO'; return;
  end if;

  if exists (select 1 from public.campania_colportor cc
              where cc.campania_id = p_campania_id and cc.usuario_id = p_usuario_id
                and cc.deleted_at is null) then
    motivo := 'YA_INSCRIPTO'; return;
  end if;

  -- Una inscripción dada de baja en esta campaña no rechaza: inscribir_colportor() la reactiva
  -- (0028). Solo cuenta lo que pasa con las inscripciones vivas en OTRAS campañas que no terminaron:
  -- en curso con en curso, o por empezar con por empezar (R-CM02, 0058). Una en curso y otra por
  -- empezar a la vez se puede. La campaña existe y no terminó: lo acaba de decir el permiso.
  select c.* into v_campania from public.campania c where c.id = p_campania_id;

  select c.id into campania_en_conflicto
    from public.campania_colportor cc
    join public.campania c on c.id = cc.campania_id
   where cc.usuario_id = p_usuario_id
     and cc.deleted_at is null
     and c.deleted_at is null
     and c.id <> p_campania_id
     and (c.fecha_fin is null or c.fecha_fin >= v_hoy)
     and (c.fecha_inicio <= v_hoy) = (v_campania.fecha_inicio <= v_hoy)
   order by c.fecha_inicio desc, c.id
   limit 1;
  if found then
    motivo := 'EN_OTRA_CAMPANIA'; return;
  end if;
end;
$$;

comment on function public.motivo_rechazo_inscripcion(uuid, uuid) is
  'HU-CAM-004: motivo null si el usuario autenticado puede inscribir a p_usuario_id en '
  'p_campania_id (o reactivar su inscripción dada de baja en ella, 0028) mientras la campaña no '
  'terminó (en curso o por empezar, 0058); si no, el motivo (SIN_PERMISO, CAMPANIA_INEXISTENTE, '
  'CAMPANIA_NO_VIGENTE, USUARIO_INEXISTENTE, EMAIL_NO_VERIFICADO, USUARIO_SUSPENDIDO, '
  'YA_INSCRIPTO, EN_OTRA_CAMPANIA; con este último, campania_en_conflicto: otra campaña no '
  'terminada en el mismo momento, las dos en curso o las dos por empezar). Única definición de las '
  'reglas. Interna: la llaman inscribir_colportor() y buscar_candidatos().';

-- ----------------------------------------------------------------------------
-- 3. Comentarios que decían «campaña vigente»
-- ----------------------------------------------------------------------------

comment on function public.motivo_rechazo_zona(uuid, uuid, uuid) is
  'HU-CAM-006: null si el usuario autenticado puede asignar p_zona_id a p_usuario_id en '
  'p_campania_id, mientras la campaña no terminó (en curso o por empezar, 0058); si no, '
  'SIN_PERMISO | CAMPANIA_INEXISTENTE | CAMPANIA_NO_VIGENTE (terminada) | NO_INSCRIPTO | '
  'USUARIO_SUSPENDIDO | ZONA_INEXISTENTE | ZONA_DE_OTRA_CIUDAD | ZONA_DE_OTRA_CAMPANIA. Interna: la '
  'llama asignar_zona().';

comment on function public.inscribir_colportor(uuid, uuid) is
  'HU-CAM-004: inscribe a p_usuario_id en p_campania_id y devuelve la fila de campania_colportor; si '
  'tenía una inscripción dada de baja en esa campaña, la reactiva (la misma fila, sin zona, 0028). '
  'Vale en una campaña en curso o por empezar (0058); una terminada es CI002. Errores: 42501 sin '
  'permiso; CI001..CI007 por regla (ver 0005; CI007: ya está en otra campaña del mismo momento). '
  'La cuenta pasa a ACTIVA sola cuando la campaña está en curso.';

comment on function public.asignar_zona(uuid, uuid, uuid) is
  'HU-CAM-006: asigna p_zona_id a la inscripción de p_usuario_id en p_campania_id y devuelve la '
  'fila de campania_colportor, en una campaña en curso o por empezar (0058). Errores: 42501 sin '
  'permiso; CZ001..CZ006 por regla (CZ002: la campaña terminó); CZ014 cuenta suspendida (conserva '
  'la zona que tenía).';

comment on function public.quitar_zona(uuid, uuid) is
  'HU-CAM-006, «Quitar» en la vista 24 (decisión del 30/09, front-coordinadores-web#20): deja sin '
  'zona la inscripción de p_usuario_id en p_campania_id y devuelve la fila de campania_colportor, en '
  'una campaña en curso o por empezar (0058). Sin zona ya, la devuelve igual. Errores: 42501 sin '
  'permiso; CZ001 campaña inexistente; CZ002 terminada; CZ003 no inscripto.';

comment on function public.buscar_candidatos(uuid, text, uuid) is
  'HU-CAM-004, vista 23: cuentas para añadir a p_campania_id. Sin texto, los sugeridos (hasta 5 '
  'PENDIENTE_ASIGNACION, más nuevas primero, una sola página); con texto, las que contienen el '
  'texto en el nombre completo o el email (sin mayúsculas ni tildes), primero las que empiezan '
  'con él y después alfabético, de a 10 por página: p_despues_de es el usuario_id de la última '
  'de la página anterior. Devuelve estado, campaña vigente (en curso) y motivo_bloqueo (el de '
  'inscribir_colportor(), null si se puede). Errores: 42501 sin permiso; CI001 campaña '
  'inexistente; CI002 terminada (una por empezar se busca, 0058); 22023 cursor desconocido (0015).';
