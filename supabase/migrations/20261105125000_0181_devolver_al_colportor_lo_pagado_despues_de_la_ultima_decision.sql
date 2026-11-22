-- ============================================================================
-- 0181 · Devolver al colportor lo pagado DESPUÉS de la última decisión, sin deshacer lo ya decidido
--        (backend-supabase#254, casilla «Devolver tras decidir»; decisión de Cristian del 05/11 en docs-organizacion#76,
--        seguimiento de la 0167 / backend-supabase#243)
--
-- ## El caso
--
-- Ana se dio de baja y había pagado $ 40.000 de alquiler. Luis, su coordinador, dejó esos $ 40.000 «a cuenta del próximo
-- depósito». Después Ana pagó $ 10.000 más y esos $ 10.000 quedaron «por decidir». Luis quiere devolverle los $ 10.000 nuevos.
-- Hasta hoy la 0167 se lo impedía con `AQ005`: «una parte de lo que pagó ya se decidió antes», porque devolver anulaba TODOS
-- los pagos y habría que deshacer una decisión tomada.
--
-- ## Qué cambia
--
-- `decidir_alquiler_pagado(usuario, campania, 'DEVOLVER_AL_COLPORTOR')` con una decisión anterior vigente anula **solo los
-- pagos validados después de la última decisión** (`deposito.anulado_at`, `anulado_por`; nunca se borran). Lo decidido antes
-- no se toca: los $ 40.000 siguen «a cuenta» y la deuda con la casa editora queda como estaba. `AQ005` deja de existir para
-- devolver. Sin decisiones vigentes devuelve todos los pagos validados, como hasta ahora.
--
--   · «Después de la última decisión» = `deposito.validado_en` posterior al `created_at` de la última `alquiler_decision`
--     vigente (no dada de baja) de esa persona en esa campaña. Cada decisión se guarda ahora con la hora real de su
--     transacción, tomada con el candado de la cuenta puesto, así que un pago que la decisión ya incluyó nunca queda «después».
--   · Lo devuelto es siempre lo que estaba por decidir. Si los pagos de después no suman eso (datos que no deberían existir),
--     no se anula nada y se avisa (`XX001`, error interno), en vez de devolver de más o de menos.
--   · «Depositado» baja solo por lo anulado; el efectivo vuelve a figurar «en mano» por lo anulado; el evento de auditoría
--     lleva `monto` (lo devuelto), `por_decidir_antes` y `depositos_anulados`.
--   · Siguen igual: los demás errores (`42501`, `AQ001`, `AQ002`, `AQ004`), el doble toque (`ya_estaba = true`), los otros dos
--     destinos y que lo anulado no se edita (DP007).
--
-- ## Los datos
--
-- Solo se reemplaza una función. Ningún depósito, decisión ni cuenta cambia al aplicarla. Lo prueba
-- supabase/tests/0181_… y el caso de Ana en supabase/tests/0167_… . Forward-only.
--
-- ## Para otros repos
--
--   · front-coordinadores-web#144: la acción «Devolver al colportor» de la vista 36 ya no pasa por `AQ005`: se puede elegir con
--     una decisión anterior y devuelve solo lo nuevo (el aviso del tooltip cambia). `monto_decidido` trae lo devuelto.
--   · docs-organizacion#172: HU-CTA-003/004/006 y el contrato (los códigos de `decidir_alquiler_pagado` pierden `AQ005`).
--
-- Forward-only: esta migración no se edita una vez aplicada.
-- ============================================================================

create or replace function public.decidir_alquiler_pagado(p_usuario_id uuid, p_campania_id uuid, p_decision text)
 RETURNS TABLE(usuario_id uuid, campania_id uuid, decision text, monto_decidido bigint, por_decidir bigint, trasladado bigint, a_favor bigint, ya_estaba boolean)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $$
declare
  v_c         public.campania;
  v_a         record;
  v_monto     bigint;
  v_cuenta    uuid;
  v_anulados  integer := 0;
  v_ultima    timestamptz;
  v_metadata  jsonb;
begin
  if auth.uid() is null or not (public.tiene_rol('ADMIN') or public.tiene_rol('COORDINADOR')) then
    raise exception 'Solo el coordinador de la campaña o un administrador puede decidir qué hacer con el alquiler pagado. Entrá con la cuenta del coordinador de esta campaña.'
      using errcode = 'insufficient_privilege';
  end if;

  select * into v_c from public.campania c where c.id = p_campania_id and c.deleted_at is null;
  if not found
     or not (public.tiene_rol('ADMIN') or public.coordina_la_campania(p_campania_id))
     or not exists (select 1 from public.campania_colportor i
                     where i.campania_id = p_campania_id and i.usuario_id = p_usuario_id) then
    raise exception 'No encontramos ese alquiler en tus campañas. Recargá la lista de cuentas.'
      using errcode = 'AQ001';
  end if;
  if p_usuario_id = auth.uid() then
    raise exception 'No podés decidir qué hacer con tu propio alquiler. Pedile a otro coordinador o a un administrador que lo haga.'
      using errcode = 'insufficient_privilege';
  end if;
  if p_decision is null
     or p_decision not in ('DEVOLVER_AL_COLPORTOR', 'A_CUENTA_PROXIMO_DEPOSITO', 'SE_LO_QUEDA_EL_COORDINADOR') then
    raise exception 'Elegí qué hacer con lo pagado: devolverlo al colportor, dejarlo a cuenta del próximo depósito o quedártelo.'
      using errcode = 'AQ002';
  end if;

  -- El mismo candado que la cuenta (refrescar_cuenta_alquiler): dos coordinadores a la vez no se pisan.
  perform pg_advisory_xact_lock(hashtextextended('cuenta_alquiler:' || p_campania_id::text, 0));

  select * into v_a from public.alquiler_calculado(p_usuario_id, p_campania_id) a;
  if not v_a.decide_coordinador then
    raise exception 'El alquiler de esta persona sigue vigente: lo que pagó de más pasa solo a la deuda con la casa editora. No hay nada que decidir.'
      using errcode = 'AQ004';
  end if;

  -- Si ya no queda nada por decidir (un doble toque, o lo decidió otra persona un instante antes), no se hace nada y
  -- se avisa con ya_estaba.
  if v_a.por_decidir = 0 then
    return query select p_usuario_id, p_campania_id, p_decision, 0::bigint, v_a.por_decidir, v_a.trasladado,
                        v_a.a_favor, true;
    return;
  end if;

  v_monto := v_a.por_decidir;
  v_metadata := jsonb_build_object('campania_id', p_campania_id, 'decision', p_decision, 'monto', v_monto,
                                   'por_decidir_antes', v_a.por_decidir);

  if p_decision = 'DEVOLVER_AL_COLPORTOR' then
    -- Devolver anula los pagos validados DESPUÉS de la última decisión que sigue vigente (0181, «Alq. baja», Ana: $ 40.000 a
    -- cuenta y $ 10.000 nuevos). Lo de antes ya se decidió (a cuenta o se lo quedó el coordinador) y no se toca: una decisión
    -- tomada no se deshace. Sin decisiones vigentes, todos los pagos validados.
    select max(ad.created_at) into v_ultima
      from public.alquiler_decision ad
     where ad.usuario_id = p_usuario_id and ad.campania_id = p_campania_id and ad.deleted_at is null;

    -- Los pagos quedan anulados, nunca borrados, y dejan de contar. Lo que había sumado «Depositado» se resta.
    with anulados as (
      update public.deposito d
         set anulado_at = now(),
             anulado_por = auth.uid()
       where d.colportor_id = p_usuario_id and d.campania_id = p_campania_id
         and d.concepto = 'ALQUILER' and d.validado_en is not null
         and d.deleted_at is null and d.anulado_at is null
         and (v_ultima is null or d.validado_en > v_ultima)
      returning d.monto
    )
    select count(*)::integer, coalesce(sum(an.monto), 0)::bigint into v_anulados, v_monto from anulados an;

    -- Lo anulado es lo que faltaba decidir. Si no coincide, algo está mal en los datos: no se anula nada.
    if v_monto <> v_a.por_decidir then
      raise exception 'No pudimos separar lo que pagó después de la última decisión. Recargá la lista de cuentas y avisá a Administración.'
        using errcode = 'XX001';
    end if;

    update public.cuenta_colportor cu
       set dinero_depositado = greatest(cu.dinero_depositado - v_monto, 0),
           actualizado_en = now()
     where cu.usuario_id = p_usuario_id and cu.deleted_at is null;

    v_metadata := jsonb_build_object('campania_id', p_campania_id, 'decision', p_decision, 'monto', v_monto,
                                     'por_decidir_antes', v_a.por_decidir, 'depositos_anulados', v_anulados);
  end if;

  -- created_at con el reloj real, tomado con el candado puesto: todo pago validado antes de esta decisión (y ya incluido en
  -- ella) queda con validado_en anterior, así que la próxima vez no se confunde con uno nuevo.
  insert into public.alquiler_decision (usuario_id, campania_id, decision, monto, decidido_por, created_at)
  values (p_usuario_id, p_campania_id, p_decision, v_monto, auth.uid(), clock_timestamp());

  -- Mueve a la deuda lo que corresponda y deja la cuenta guardada al día.
  perform public.refrescar_cuenta_alquiler(p_campania_id, p_usuario_id);

  select ca.id into v_cuenta
    from public.cuenta_alquiler ca
   where ca.usuario_id = p_usuario_id and ca.campania_id = p_campania_id;

  perform auditoria.registrar('alquiler_pagado_decidido', 'cuenta_alquiler', v_cuenta, p_usuario_id, v_metadata);

  select * into v_a from public.alquiler_calculado(p_usuario_id, p_campania_id) a;
  return query select p_usuario_id, p_campania_id, p_decision, v_monto, v_a.por_decidir, v_a.trasladado,
                      v_a.a_favor, false;
end;
$$;

comment on function public.decidir_alquiler_pagado(uuid, uuid, text) is
  '«Alq. baja» (0159, backend-supabase#234; 0167, #243; 0181, #254): el coordinador de la campaña (o el ADMIN) decide qué '
  'hacer con TODO lo pagado del alquiler por quien se dio de baja, o en una campaña sin alquiler, y que todavía no se decidió: '
  'DEVOLVER_AL_COLPORTOR (los pagos validados después de la última decisión vigente quedan anulados y dejan de contar; lo '
  'decidido antes no se toca), A_CUENTA_PROXIMO_DEPOSITO (se descuenta de la deuda con la casa editora) o '
  'SE_LO_QUEDA_EL_COORDINADOR (la deuda no se mueve). Una decisión por todo lo que estaba por decidir, sin repartir '
  '(idempotente: sin nada por decidir devuelve ya_estaba = true y no cambia nada). Queda en alquiler_decision y en '
  'audit_log (alquiler_pagado_decidido: ids, decisión y montos). Errores: 42501 sin permiso o decidiendo lo propio; '
  'AQ001 (campaña o persona inexistente o no es de sus campañas); AQ002 (decisión desconocida); AQ004 (el alquiler de '
  'esa persona no se decide: inscripción viva en una campaña que cobra); XX001 (los pagos de después de la última '
  'decisión no suman lo que falta decidir: datos inconsistentes, no se anula nada).';
