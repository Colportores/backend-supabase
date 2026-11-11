-- ============================================================================
-- 0018 · Espacios: el autor los corrige solo con la campaña vigente; y no se da de baja una casa
--        con ventas o con visitas de otro colportor
--        (backend-supabase#32; decisión de Cristian del 02/10 en backend-supabase#51)
--
-- Decisión de Cristian del 02/10 (backend-supabase#51, comentario 5951900059):
--   «Un colportor corrige o da de baja lo que cargó solo mientras su campaña está vigente (como
--   house_status): fuera de eso, el push vuelve rechazado (42501) y queda visible en la cola de
--   error del teléfono. No se pierden ventas ni personas.
--   Además: un colportor no puede dar de baja una casa en la que haya una visita registrada por
--   otro colportor, ni una casa que tenga cualquier tipo de venta. Va en el servidor (rechazo con
--   un código que la app traduzca a un aviso que guíe) y en la app antes de ofrecer «Dar de
--   baja» (lo que el teléfono sabe aunque no haya subido).»
--
-- ## 1. Corregir o dar de baja un espacio: solo con la campaña vigente, y con un rechazo visible
--
-- Problema (menor de la re-revisión de #36, comentario 5920668801): 0011 le dio a
-- espacio_por_ubicacion_select la rama «lo cargó él» (created_by), que el push necesita por el
-- INSERT ... ON CONFLICT (id), pero el UPDATE pedía solo puedo_escribir_en_ubicacion(). Con la
-- campaña terminada (o la ciudad fuera de ella) el colportor ve su espacio y su UPDATE no toca
-- ninguna fila: sync.aplicar_job lo tomaba por «otro escritor ganó la carrera» y devolvía
-- `conflict` con la misma versión que mandó, y el teléfono pisaba su corrección con la fila del
-- servidor, sin aviso. Con un delete pasaba lo mismo.
--
-- Arreglo, como house_status (0011): la fila vieja pasa si la cargó él o si puede escribir en su
-- casa (USING), y la nueva tiene que ser de una casa en la que puede escribir (WITH CHECK,
-- puedo_escribir_en_ubicacion(): la registró él o es de una ciudad de sus campañas vigentes). Con
-- la campaña terminada, su UPDATE llega a la fila y el WITH CHECK lo rechaza: 42501, que el push
-- devuelve `invalid` (cola de error, sin reintento automático) en vez del `conflict` falso. El
-- delete del push es un UPDATE de deleted_at: lo mismo. Nada se borra del teléfono.
--   · El mismo WITH CHECK impide reapuntar el espacio (ubicacion_id) a una casa en la que no puede
--     escribir: el trigger espacio_no_mover_a_casa_ajena de la versión anterior de esta migración
--     (nunca aplicada) ya no hace falta.
--   · El espacio de otro que ya no ve sigue igual: FILA_INEXISTENTE (`invalid`).
--   · Como en house_status, «puede escribir» incluye las casas que registró él, con campaña o
--     sin ella: es la regla de puedo_escribir_en_ubicacion() (0011), que acá no cambia.
--
-- ## 2. No se da de baja una casa con ventas o con visitas de otro colportor
--
-- Trigger BEFORE UPDATE OF deleted_at en ubicacion, cuando una casa viva pasa a dada de baja (el
-- push la da de baja con un UPDATE; también un UPDATE directo):
--   · UB001 si tiene alguna venta, de cualquier colportor, en alguno de sus espacios;
--   · UB002 si tiene alguna visita registrada por otro colportor (no por quien la da de baja).
-- Cuentan todas las filas, también las dadas de baja (una venta no se anula, ADR-002; una visita
-- dada de baja sigue siendo un registro de otro en esa casa) y las que cuelgan de espacios o
-- vínculos dados de baja: siguen siendo de esa casa. SECURITY DEFINER: tiene que ver las ventas y
-- visitas de los demás, que la RLS le esconde a quien escribe; no devuelve nada de ellas. Sin
-- usuario autenticado (mantenimiento del servidor) no se exige.
-- El push los devuelve `invalid` con su código: sync.aplicar_job (abajo) los suma a los que ya
-- atrapaba. Sin eso, un código propio tumbaba el lote entero (5xx) y el motor lo reintentaba para
-- siempre. La baja no se aplica y la casa queda como estaba.
--
-- ## Para otros repos
--
--   · front-colportores-mobile (#178): corregir o dar de baja un espacio con la campaña terminada
--     vuelve `invalid` 42501 (antes `conflict`). «Dar de baja» una casa vuelve `invalid` con UB001
--     (tiene ventas) o UB002 (tiene visitas de otro colportor): la app lo traduce a un aviso, y
--     antes de ofrecer «Dar de baja» mira lo que tiene local y todavía no subió.
--   · Contrato de sync (docs-organizacion): los códigos UB001 y UB002 del push.
--
-- Datos: ninguno cambia; se reemplaza una política y se suma un trigger.
-- Forward-only: esta migración no se edita una vez aplicada.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. espacio: el UPDATE, como house_status
-- ----------------------------------------------------------------------------

drop policy espacio_por_ubicacion_update on public.espacio;
create policy espacio_por_ubicacion_update on public.espacio
  for update to authenticated
  using (created_by = (select auth.uid())
         or public.puedo_escribir_en_ubicacion(ubicacion_id))
  with check (public.puedo_escribir_en_ubicacion(ubicacion_id));

-- ----------------------------------------------------------------------------
-- 2. ubicacion: la baja de una casa con ventas o con visitas de otro colportor
-- ----------------------------------------------------------------------------

create function public.tg_ubicacion_baja_con_ventas_o_visitas()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if (select auth.uid()) is null then
    return new;
  end if;

  if exists (select 1
               from public.venta v
               join public.espacio_persona ep on ep.id = v.espacio_persona_id
               join public.espacio e on e.id = ep.espacio_id
              where e.ubicacion_id = new.id) then
    raise exception using
      errcode = 'UB001',
      message = 'No se puede dar de baja esta casa: tiene ventas registradas. La casa queda como estaba.',
      hint    = 'Si está repetida, marcala como duplicado de la otra desde la vista 10 (sus personas '
                'y ventas pasan a esa); si se cargó con un error, corregí su dirección o su posición.';
  end if;

  if exists (select 1
               from public.visita vi
               join public.espacio_persona ep on ep.id = vi.espacio_persona_id
               join public.espacio e on e.id = ep.espacio_id
              where e.ubicacion_id = new.id
                and vi.colportor_id <> (select auth.uid())) then
    raise exception using
      errcode = 'UB002',
      message = 'No se puede dar de baja esta casa: otro colportor registró visitas en ella. La casa '
                'queda como estaba.',
      hint    = 'Si se cargó con un error, corregí su dirección o su posición.';
  end if;

  return new;
end;
$$;

comment on function public.tg_ubicacion_baja_con_ventas_o_visitas() is
  'BEFORE UPDATE OF deleted_at de ubicacion: no se da de baja una casa con ventas (UB001) ni con '
  'visitas de otro colportor (UB002). SECURITY DEFINER: ve las ventas y visitas ajenas. Sin usuario '
  'autenticado no se exige (0018, decisión del 02/10).';

create trigger ubicacion_baja_con_ventas_o_visitas
  before update of deleted_at on public.ubicacion
  for each row
  when (old.deleted_at is null and new.deleted_at is not null)
  execute function public.tg_ubicacion_baja_con_ventas_o_visitas();

-- ----------------------------------------------------------------------------
-- 3. El push: UB001 y UB002 vuelven invalid, sin tumbar el lote
-- ----------------------------------------------------------------------------

-- Igual que en 0017, más los dos códigos.
create or replace function sync.aplicar_job(p_job jsonb)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_id          uuid;
  v_restriccion text;
begin
  -- El cast va adentro del bloque protegido: un client_op_id malformado es un
  -- payload inválido, no un 500.
  begin
    v_id := (p_job ->> 'client_op_id')::uuid;
  exception when data_exception then
    v_id := null;
  end;

  return sync.aplicar_job_interno(v_id, p_job);
exception
  -- Clase 22, clase 23 y 42501: el payload está mal o la RLS rechazó la fila. INVALID, sin
  -- reintento automático, y sin tumbar al resto del lote (ver 0002).
  --
  -- Menos D1 (0017): misma dirección a menos de 100 m de otra ubicación viva. No es un payload
  -- roto: la fila es buena y la resuelve el colportor en la vista 10. Vuelve como conflicto, sin
  -- server_row (no hay fila del servidor que aplicar), y no entra al cache de client_op_id.
  when data_exception or integrity_constraint_violation or insufficient_privilege then
    get stacked diagnostics v_restriccion = constraint_name;
    if sqlstate = '23505' and v_restriccion = 'ubicacion_direccion_unica' then
      return jsonb_build_object(
        'client_op_id', v_id,
        'outcome', 'conflict',
        'code', sqlstate,
        'constraint', v_restriccion,
        'message', sqlerrm
      );
    end if;
    return jsonb_build_object(
      'client_op_id', v_id,
      'outcome', 'invalid',
      'code', sqlstate,
      'message', sqlerrm
    );
  -- La baja de una casa con ventas o con visitas de otro colportor (0018): códigos propios, que
  -- la app traduce a un aviso. INVALID como el resto, sin tumbar el lote.
  when sqlstate 'UB001' or sqlstate 'UB002' then
    return jsonb_build_object(
      'client_op_id', v_id,
      'outcome', 'invalid',
      'code', sqlstate,
      'message', sqlerrm
    );
end;
$$;

-- ----------------------------------------------------------------------------
-- 4. Privilegios
-- ----------------------------------------------------------------------------

-- `authenticated` también: en una base creada desde cero los default privileges de la imagen le
-- dan EXECUTE sobre cada función nueva de public (ver 0008). El trigger corre igual sin EXECUTE.
-- sync.aplicar_job conserva los suyos (create or replace no los toca).
revoke all on function public.tg_ubicacion_baja_con_ventas_o_visitas() from public, anon, authenticated;
