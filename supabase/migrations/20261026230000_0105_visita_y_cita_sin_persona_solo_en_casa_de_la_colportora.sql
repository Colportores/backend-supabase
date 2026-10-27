-- ============================================================================
-- 0105 · La visita y la cita sin persona solo entran en una casa de la colportora, sin plazo
--        (backend-supabase#157, seguimiento de #132, «Visita ajena»)
--
-- Decisión de Cristian (25/10), «Visita ajena»: cerrar sin mirar fechas (backend-supabase#149,
-- comentarios 6396878245 y 6396921534). Caso de uso: una colportora con un teléfono manipulado sube una
-- visita (con o sin persona) o una cita sin persona colgada de un espacio de la casa de otra colportora.
-- Hoy entra, porque la clave foránea no mira la RLS, y esa visita le impide a la dueña dar la casa de baja
-- (UB002, 0018 y 0069).
--
-- ## La regla
--
-- La visita (con o sin persona) y la cita sin persona entran solo si el espacio FINAL (el que queda después
-- de tg_visita_union_redirige() / tg_agenda_union_redirige(): el del vínculo si hay persona, el de A si se
-- fundió) es de una casa que:
--   · la registró la colportora (ubicacion.created_by), o
--   · es de una ciudad de alguna campaña en la que está o estuvo inscripta (una fila de campania_colportor
--     suya, viva o dada de baja, de una campaña vigente, terminada o futura).
-- SIN PLAZO: ninguna visita legítima se pierde por sincronizarse tarde. Por eso no se usa
-- puedo_escribir_en_ubicacion() (0011, 0021): mira la gracia de 15 días de 0020. Si no cumple, se rechaza
-- con 42501.
--
-- ## Cómo
--
-- Una política RESTRICTIVA de INSERT y otra de UPDATE sobre visita, y lo mismo sobre agenda. Las políticas
-- se evalúan sobre la fila que queda DESPUÉS de los triggers BEFORE, o sea, sobre el espacio final; y solo
-- rigen para `authenticated` (el push corre INVOKER): las funciones SECURITY DEFINER que mueven visitas y
-- citas de un espacio a otro (marcar_como_duplicado(), la unión de espacios, el vínculo que se muda) y el
-- servidor no pasan por acá, así que la unión de dos casas sigue moviendo las visitas de los demás.
-- El rechazo sale por el push como `invalid` con SQLSTATE 42501 (aplicar_job atrapa la clase 42501): esa
-- operación no se reintenta y la cola sigue con la que viene.
--
--   · El otro camino: la colportora muda SU vínculo (espacio_persona) a la casa de otra y el trigger
--     espacio_persona_mueve_visitas (0069, DEFINER) lleva sus visitas ahí sin pasar por las políticas.
--     Un trigger BEFORE UPDATE OF espacio_id de espacio_persona, en el camino cliente, rechaza con 42501
--     que el vínculo cambie a un espacio donde no puede dejar visitas (el espacio final, después de la
--     unión). Solo cuando el espacio CAMBIA: corregir el resto del vínculo no se toca. La unión de
--     duplicados (DEFINER) y el servidor siguen mudando vínculos y visitas de los demás.
--   · Un espacio que todavía no existe (o un espacio_id null) pasa: lo dice la clave foránea (23503, que en
--     el push deja en espera lo que cuelga de un alta en conflicto, 0017) o el NOT NULL (23502). Ese caso no
--     deja nada en la casa de nadie.
--   · La cita CON persona no cambia: no frena la baja de la casa (UB001 y UB002 miran ventas y visitas) y
--     no es parte de la decisión.
--   · Una fila que ya estaba (de antes de esta migración) y que la colportora corrige sin tocar su espacio
--     cumple la regla si era legítima; la regla no mira fechas.
--
-- Datos: ninguno; solo funciones, cuatro políticas y un trigger.
-- Forward-only: esta migración no se edita una vez aplicada.
-- ============================================================================

-- Si el usuario autenticado puede dejar una visita (o una cita sin persona) en ese espacio: la casa del
-- espacio la registró él, o es de una ciudad de una campaña en la que está o estuvo inscripto. Sin plazo.
-- Un espacio inexistente o null devuelve true: que lo diga la clave foránea (o el NOT NULL), no la RLS.
-- SECURITY DEFINER: lee la casa y las inscripciones sin pasar por la RLS de lectura.
create function public.puedo_dejar_en_espacio(p_espacio_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select p_espacio_id is null
      or not exists (select 1 from public.espacio e where e.id = p_espacio_id)
      or exists (select 1
                   from public.espacio e
                   join public.ubicacion u on u.id = e.ubicacion_id
                  where e.id = p_espacio_id
                    and (u.created_by = auth.uid()
                         or exists (select 1
                                      from public.campania_ciudad cc
                                      join public.campania_colportor cp on cp.campania_id = cc.campania_id
                                     where cc.ciudad_id = u.ciudad_id
                                       and cp.usuario_id = auth.uid())));
$$;

comment on function public.puedo_dejar_en_espacio(uuid) is
  'Si el usuario autenticado puede dejar una visita o una cita sin persona en ese espacio: la casa la '
  'registró él o es de una ciudad de una campaña en la que está o estuvo inscripto, sin plazo (0105, '
  'decisión de Cristian del 25/10 en #132). Un espacio que no existe o null da true: lo dice la clave '
  'foránea. Las políticas de visita y agenda.';

-- La llaman las políticas, que corren como quien llama; solo mira al usuario autenticado.
revoke all on function public.puedo_dejar_en_espacio(uuid) from public, anon, authenticated, service_role;
grant execute on function public.puedo_dejar_en_espacio(uuid) to authenticated, service_role;

-- ----------------------------------------------------------------------------
-- visita: con o sin persona
-- ----------------------------------------------------------------------------

create policy visita_solo_en_casa_de_la_colportora_insert on public.visita
  as restrictive
  for insert to authenticated
  with check (public.puedo_dejar_en_espacio(espacio_id));

create policy visita_solo_en_casa_de_la_colportora_update on public.visita
  as restrictive
  for update to authenticated
  using (true)
  with check (public.puedo_dejar_en_espacio(espacio_id));

-- ----------------------------------------------------------------------------
-- agenda: la cita sin persona (la que tiene persona no cambia)
-- ----------------------------------------------------------------------------

create policy agenda_sin_persona_solo_en_casa_de_la_colportora_insert on public.agenda
  as restrictive
  for insert to authenticated
  with check (espacio_persona_id is not null or public.puedo_dejar_en_espacio(espacio_id));

create policy agenda_sin_persona_solo_en_casa_de_la_colportora_update on public.agenda
  as restrictive
  for update to authenticated
  using (true)
  with check (espacio_persona_id is not null or public.puedo_dejar_en_espacio(espacio_id));

-- ----------------------------------------------------------------------------
-- espacio_persona: el vínculo propio no se muda a una casa donde no puede dejar visitas
-- ----------------------------------------------------------------------------

-- SECURITY INVOKER a propósito: current_user es authenticated o anon en el camino cliente (el push, o un
-- UPDATE por la API) y otro adentro de una función SECURITY DEFINER (marcar_como_duplicado(), la unión de
-- espacios) o en el servidor, que mudan vínculos sin pasar por acá (como 0053 y 0100: no auth.uid(), que
-- adentro del RPC sigue puesto). Corre después de espacio_persona_0_union_redirige (por el nombre): se mira
-- el espacio final. Sin cambio de espacio no hace nada.
create function public.tg_espacio_persona_no_se_muda_a_casa_ajena()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if current_user in ('authenticated', 'anon')
     and not public.puedo_dejar_en_espacio(new.espacio_id) then
    raise exception using
      errcode = '42501',
      message = 'No se puede mudar este vínculo a un espacio de la casa de otra colportora. El vínculo queda como estaba.',
      hint    = 'Solo se trabaja en las casas que registraste o en las de una ciudad de tus campañas.';
  end if;
  return new;
end;
$$;

comment on function public.tg_espacio_persona_no_se_muda_a_casa_ajena() is
  'BEFORE UPDATE OF espacio_id de espacio_persona (0105, #157): un cliente no muda su vínculo a un espacio '
  'donde no puede dejar visitas (puedo_dejar_en_espacio), porque espacio_persona_mueve_visitas (0069, '
  'DEFINER) llevaría ahí sus visitas. La unión de duplicados y el servidor no pasan por acá.';

revoke all on function public.tg_espacio_persona_no_se_muda_a_casa_ajena() from public, anon, authenticated;

create trigger espacio_persona_1_no_se_muda_a_casa_ajena
  before update of espacio_id on public.espacio_persona
  for each row
  when (old.espacio_id is distinct from new.espacio_id)
  execute function public.tg_espacio_persona_no_se_muda_a_casa_ajena();
