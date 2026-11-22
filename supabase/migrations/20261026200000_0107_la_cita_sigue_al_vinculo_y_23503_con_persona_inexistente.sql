-- ============================================================================
-- 0107 · La cita de la agenda sigue al vínculo cuando cambia de espacio, y una cita con persona
--        inexistente da 23503 (backend-supabase#150, seguimiento de #132)
--
-- Decisión del agente de decisiones (25/10), por el mapa de decisiones: coherencia entre pantallas (la
-- cita sigue a su vínculo como la visita, 0069) y aplicar la decisión de Cristian «el backend marca en
-- espera lo que cuelga de un alta en conflicto» (backend-supabase#49).
--
-- ## Qué cambia
--
--   1. Cuando un vínculo (`espacio_persona`) cambia de espacio, sus citas de agenda lo siguen, en un
--      trigger hermano del que mueve las visitas (`espacio_persona_mueve_visitas`, 0069):
--      `espacio_persona_mueve_agendas`. Hoy lo hace la unión de dos casas (el vínculo de B se muda al
--      único de A) y lo corregía, más tarde y por otro camino, `tg_espacio_union_mueve_agendas()`
--      (0068); la columna denormalizada `agenda.espacio_id` tiene que seguir SIEMPRE a su vínculo, no
--      depender de cuándo se funde el espacio. Corre para cualquier colportor (DEFINER): las citas de los
--      demás también se mudan con el vínculo. Se eligió un trigger hermano y no renombrar el de las
--      visitas para no tocar una migración aplicada ni los tests que lo nombran.
--   2. `tg_agenda_union_redirige()` (0068): una cita con persona cuyo vínculo no existe (todavía) se
--      rechaza con `23503` (clave foránea), como la visita (0069), y no con `23502` por un espacio que el
--      trigger no pudo completar. El push lo necesita así: un `23503` de algo que cuelga de un alta en
--      conflicto queda en espera (0017) y no se pierde; un `23502` queda como `invalid`.
--
-- Solo suma: no se borra ni se pierde ninguna cita. Datos: ninguno. Forward-only: la 0068 no se toca.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. La cita con persona sin vínculo: 23503, no 23502
-- ----------------------------------------------------------------------------

-- Igual que en 0068, más el 23503 cuando el vínculo no existe. Corre antes que los otros BEFORE (por el
-- nombre).
create or replace function public.tg_agenda_union_redirige()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_espacio uuid;
begin
  new.espacio_persona_id := public.redirigir_vinculo(new.espacio_persona_id);
  if new.ubicacion_alt_id is not null then
    new.ubicacion_alt_id := public.redirigir_ubicacion(new.ubicacion_alt_id);
  end if;

  -- Con persona, la cita cuelga del espacio de su vínculo (el que mande el teléfono, o ninguno, da
  -- igual).
  if new.espacio_persona_id is not null then
    select ep.espacio_id into v_espacio
      from public.espacio_persona ep
     where ep.id = new.espacio_persona_id;
    if not found then
      -- El vínculo no existe (todavía): es el mismo error de clave foránea de siempre (23503) y no un
      -- NOT NULL del espacio que este trigger no pudo completar (23502). El push lo necesita así: un
      -- 23503 de algo que cuelga de un alta en conflicto queda en espera (0017) y no se pierde.
      raise exception using
        errcode = '23503',
        constraint = 'agenda_espacio_persona_id_fkey',
        message = 'insert or update on table "agenda" violates foreign key constraint "agenda_espacio_persona_id_fkey"';
    end if;
    new.espacio_id := v_espacio;
  end if;

  -- Un espacio fundido en el único de A va al de A (null se queda null: lo dice el NOT NULL).
  new.espacio_id := public.redirigir_espacio(new.espacio_id);
  return new;
end;
$$;

comment on function public.tg_agenda_union_redirige() is
  'BEFORE INSERT / UPDATE OF espacio_persona_id, espacio_id, ubicacion_alt_id de agenda: el vínculo '
  'fundido y la casa alternativa que nombran a B pasan a A (0035); el espacio sale del vínculo si hay '
  'persona y el espacio fundido pasa al de A (0068); un vínculo que no existe da 23503 (0107).';

-- ----------------------------------------------------------------------------
-- 2. Si un vínculo cambia de espacio, sus citas lo siguen
-- ----------------------------------------------------------------------------

-- Igual que tg_espacio_persona_mueve_visitas() (0069), para la agenda: el espacio de una cita con persona
-- es siempre el de su vínculo. Corre para cualquier colportor (DEFINER).
create function public.tg_espacio_persona_mueve_agendas()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  update public.agenda
     set espacio_id = new.espacio_id
   where espacio_persona_id = new.id
     and espacio_id is distinct from new.espacio_id;
  return null;
end;
$$;

comment on function public.tg_espacio_persona_mueve_agendas() is
  'AFTER UPDATE OF espacio_id de espacio_persona: las citas de agenda de ese vínculo pasan a su espacio '
  'nuevo, como las visitas (0107).';

create trigger espacio_persona_mueve_agendas
  after update of espacio_id on public.espacio_persona
  for each row
  when (old.espacio_id is distinct from new.espacio_id)
  execute function public.tg_espacio_persona_mueve_agendas();

-- Los triggers corren sin EXECUTE para nadie (0035): las funciones son internas.
revoke all on function public.tg_espacio_persona_mueve_agendas() from public, anon, authenticated;
