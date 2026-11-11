-- ============================================================================
-- 0167 · Lo pagado del alquiler de una baja tiene tres destinos: devolver al colportor, a cuenta del próximo depósito
--        o se lo queda el coordinador
--        (backend-supabase#243, casilla «Alq. baja»; decisión de Cristian del 04/11 en backend-supabase#234: «El
--        coordinador debe elegir si devuelve al colportor (se anula los pagos), queda a c/c para siguiente deposito, o se
--        lo queda el coordinador»; seguimiento de la 0159; desbloquea front-coordinadores-web#132)
--
-- ## El caso
--
-- Luis abre «Cuentas» y ve a Ana, dada de baja, que pagó $ 70.000 de alquiler. La 0159 le dejaba dos opciones y podía
-- repartir en partes. Cristian pidió tres destinos y que Luis elija UNO para todo lo pagado, sin repartir:
--
--   · `DEVOLVER_AL_COLPORTOR` (nuevo): la plata vuelve a Ana. Sus pagos de alquiler quedan **anulados** (nunca
--     borrados) y dejan de contar: no suman a lo pagado del alquiler, ni a «Depositado», y el efectivo vuelve a figurar
--     «en mano» (lo tiene ella). No se deshace: la plata ya volvió.
--   · `A_CUENTA_PROXIMO_DEPOSITO` (lo que era `TRASLADAR_A_LA_DEUDA`): baja su deuda con la casa editora.
--   · `SE_LO_QUEDA_EL_COORDINADOR` (lo que era `DEJAR_A_FAVOR`): queda con el coordinador; la deuda no se mueve.
--
-- ## Qué cambia
--
--   1. `deposito.anulado_at` y `deposito.anulado_por` (las pone el servidor; el teléfono no las manda): un pago de alquiler
--      ya validado que se devolvió. Solo un depósito de concepto ALQUILER y validado se anula. Una vez anulado no se edita
--      (DP007), igual que uno validado (DP001) o un retiro rechazado (DP005). Las columnas bajan al teléfono con la fila.
--   2. `alquiler_decision.decision` pasa a los tres valores de arriba. Las decisiones que ya había se renombran
--      (`TRASLADAR_A_LA_DEUDA` → `A_CUENTA_PROXIMO_DEPOSITO`, `DEJAR_A_FAVOR` → `SE_LO_QUEDA_EL_COORDINADOR`): no cambia
--      ningún monto ni la deuda de nadie.
--   3. `alquiler_calculado()` y `efectivo_en_mano()` no cuentan los depósitos anulados (`create or replace`, misma firma).
--   4. `decidir_alquiler_pagado(usuario, campania, decision)`: **ya no recibe `p_monto`**. Se decide todo lo que está por
--      decidir, de una vez. Misma tabla de salida. Sin nada por decidir (un doble toque, o lo decidió otra persona un
--      instante antes) no hace nada y devuelve `ya_estaba = true`. Errores: `42501` sin permiso o decidiendo lo propio;
--      `AQ001` la campaña no existe, no es de sus campañas o la persona no tiene alquiler en ella; `AQ002` decisión
--      desconocida; `AQ004` el alquiler de esa persona no se decide; **`AQ005` nuevo**: devolver no se puede si parte de lo
--      pagado ya se decidió antes (a cuenta o se lo queda): habría que anular también esa parte y deshacer una decisión
--      tomada. (`AQ003`, monto, ya no existe.)
--   5. Devolver anula todos los pagos de alquiler validados de esa persona en esa campaña, resta lo anulado de
--      `cuenta_colportor.dinero_depositado` (lo que `validar_ticket` había sumado), deja la decisión registrada con el
--      monto devuelto y un evento `alquiler_pagado_decidido` con la cantidad de pagos anulados.
--   6. Si la persona se reactiva o la campaña empieza a cobrar alquiler, se deshacen «a cuenta» y «se lo queda» como hasta
--      ahora (se dan de baja las decisiones); **«devolver» no se deshace**: sus pagos siguen anulados y su decisión,
--      vigente en el registro.
--
-- ## Lo que NO hace
--
--   · No reparte en partes ni elige por el coordinador. Los pagos todavía por validar no se tocan: cuando se validen,
--     quedan por decidir.
--   · No toca la deuda con la casa editora al devolver (lo devuelto nunca fue a la deuda).
--
-- ## Los datos
--
--   Se renombran los valores de `alquiler_decision.decision` de las filas que ya existen (datos simulados hasta
--   diciembre). Ningún depósito, cobro ni cuenta se toca. Lo prueba supabase/tests_migracion/0167_ok.
--
-- ## Para otros repos
--
--   · front-coordinadores-web#132: la acción «por decidir» de la vista 36 llama a
--     `decidir_alquiler_pagado(usuario, campania, decision)` con uno de los tres valores y sin monto; el aviso de AQ005
--     dice qué hacer. Lee `alquiler_por_decidir`, `alquiler_a_favor` («se lo queda») y `alquiler_trasladado` («a cuenta»)
--     de `cuentas_de_campania()`.
--   · front-colportores-mobile: `deposito.anulado_at` baja con la fila; un depósito anulado no cuenta como depositado
--     ni descuenta el efectivo «en mano».
--   · docs-organizacion: HU-CTA-003/004/006 y `esquema-datos.md` (`alquiler_decision`, `deposito`).
--
-- Forward-only: esta migración no se edita una vez aplicada.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. deposito: el pago anulado
-- ----------------------------------------------------------------------------

alter table public.deposito
  add column anulado_at  timestamptz,
  add column anulado_por uuid references public.usuario(id);

alter table public.deposito
  -- Solo se anula un pago de alquiler ya validado (devuelto a la persona).
  add constraint deposito_anulado_solo_de_alquiler_check
    check (anulado_at is null or (concepto = 'ALQUILER' and validado_en is not null)),
  add constraint deposito_anulado_por_check
    check (anulado_por is null or anulado_at is not null);

create index deposito_anulado_por_idx on public.deposito (anulado_por) where anulado_por is not null;

comment on column public.deposito.anulado_at is
  'Cuándo se anuló este pago de alquiler porque el coordinador lo devolvió a la persona (0167, «Alq. baja»). Queda como '
  'historia: no cuenta como pagado, ni como depositado, ni descuenta el efectivo en mano. Solo un depósito de alquiler '
  'ya validado. Lo pone el servidor.';
comment on column public.deposito.anulado_por is
  'El coordinador (o ADMIN) que devolvió el pago (0167). Lo pone el servidor.';

-- El teléfono no manda la anulación: se descarta del push.
update sync.entidad
   set columnas_servidor = columnas_servidor || array['anulado_at', 'anulado_por']
 where nombre = 'deposito';

-- La alta del teléfono no trae ni la validación (0129), ni el rechazo (0152), ni la anulación.
create or replace function public.tg_deposito_validado_del_servidor()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  -- El servidor (service_role, el editor SQL, una función DEFINER) no pasa por acá. El push corre INVOKER como
  -- `authenticated` (patrón de 0053, 0100 y 0122).
  if current_user in ('authenticated', 'anon') then
    if new.validado_en is not null or new.validado_por is not null then
      raise exception 'Un depósito lo valida tu coordinador, no se carga desde el teléfono. Registralo sin validar y esperá su confirmación.'
        using errcode = '42501';
    end if;
    if new.rechazado_en is not null or new.rechazado_por is not null or new.motivo_rechazo is not null then
      raise exception 'Un retiro lo rechaza tu coordinador, no se carga desde el teléfono. Registralo sin rechazar.'
        using errcode = '42501';
    end if;
    if new.anulado_at is not null or new.anulado_por is not null then
      raise exception 'Un pago de alquiler lo devuelve tu coordinador, no se carga desde el teléfono. Registralo sin anular.'
        using errcode = '42501';
    end if;
  end if;
  return new;
end;
$$;

comment on function public.tg_deposito_validado_del_servidor() is
  'BEFORE INSERT de deposito, solo para authenticated (0129, 0152, 0167): ni la validación (validado_en, validado_por), ni '
  'el rechazo (rechazado_en, rechazado_por, motivo_rechazo), ni la anulación (anulado_at, anulado_por) los manda el '
  'teléfono (42501). El servidor no pasa por acá.';

-- Un pago anulado queda como historia: no se edita ni se da de baja.
create function public.tg_deposito_anulado_no_se_edita()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if old.anulado_at is not null
     and (new.colportor_id, new.monto, new.fecha, new.ticket_id, new.destino, new.concepto, new.campania_id,
          new.validado_en, new.validado_por, new.anulado_at, new.anulado_por, new.deleted_at)
         is distinct from
         (old.colportor_id, old.monto, old.fecha, old.ticket_id, old.destino, old.concepto, old.campania_id,
          old.validado_en, old.validado_por, old.anulado_at, old.anulado_por, old.deleted_at) then
    raise exception 'Un pago anulado queda como historia: no se edita ni se da de baja.'
      using errcode = 'DP007';
  end if;
  return new;
end;
$$;

comment on function public.tg_deposito_anulado_no_se_edita() is
  'BEFORE UPDATE de deposito (0167): un pago de alquiler anulado conserva todos sus datos y no se da de baja (DP007); solo '
  'cambia la auditoría. Vale también para el servidor.';

revoke all on function public.tg_deposito_anulado_no_se_edita() from public, anon, authenticated, service_role;

create trigger deposito_anulado_no_se_edita
  before update on public.deposito
  for each row execute function public.tg_deposito_anulado_no_se_edita();

-- Anular un pago refresca la cuenta del alquiler, como validarlo o darlo de baja.
drop trigger deposito_cuenta_alquiler on public.deposito;
create trigger deposito_cuenta_alquiler
  after insert or delete or update of colportor_id, monto, ticket_id, concepto, campania_id, validado_en, rechazado_en, anulado_at, deleted_at
  on public.deposito
  for each row execute function public.tg_deposito_cuenta_alquiler();

-- ----------------------------------------------------------------------------
-- 2. «En mano»: un pago anulado vuelve a la persona
-- ----------------------------------------------------------------------------

create or replace function public.efectivo_en_mano(p_usuario_id uuid, p_excepto uuid default null)
returns bigint
language sql
stable
security definer
set search_path = ''
as $$
  select greatest(
           coalesce((select sum(c.monto)
                       from public.cobranza c
                       join public.venta v on v.id = c.venta_id
                      where v.colportor_id = p_usuario_id and v.deleted_at is null
                        and c.medio = 'EFECTIVO' and c.deleted_at is null and c.anulado_at is null), 0)
         - coalesce((select sum(d.monto)
                       from public.deposito d
                       left join public.ticket t on t.id = d.ticket_id
                      where d.colportor_id = p_usuario_id and d.deleted_at is null
                        and d.rechazado_en is null
                        and d.anulado_at is null
                        and t.estado is distinct from 'RECHAZADO'
                        and d.id is distinct from p_excepto), 0),
         0)::bigint;
$$;

comment on function public.efectivo_en_mano(uuid, uuid) is
  '«En mano» (0152, «Cobro en dep.»; 0167): lo cobrado en efectivo (cobros vivos y no anulados) menos lo depositado '
  '(depósitos vivos por validar o validados, sin los retiros rechazados, los pagos de alquiler anulados ni los de un '
  'ticket rechazado), sin bajar de 0. p_excepto deja afuera un depósito. Interna.';

-- ----------------------------------------------------------------------------
-- 3. alquiler_decision: los tres destinos
-- ----------------------------------------------------------------------------

alter table public.alquiler_decision drop constraint alquiler_decision_decision_check;

update public.alquiler_decision
   set decision = case decision
                    when 'TRASLADAR_A_LA_DEUDA' then 'A_CUENTA_PROXIMO_DEPOSITO'
                    when 'DEJAR_A_FAVOR' then 'SE_LO_QUEDA_EL_COORDINADOR'
                  end
 where decision in ('TRASLADAR_A_LA_DEUDA', 'DEJAR_A_FAVOR');

alter table public.alquiler_decision
  add constraint alquiler_decision_decision_check
    check (decision in ('DEVOLVER_AL_COLPORTOR', 'A_CUENTA_PROXIMO_DEPOSITO', 'SE_LO_QUEDA_EL_COORDINADOR'));

comment on table public.alquiler_decision is
  'Lo que el coordinador (o un ADMIN) decidió hacer con lo pagado del alquiler de quien se dio de baja o de una '
  'campaña sin alquiler (0159, backend-supabase#234; 0167, #243): devolverlo a la persona (se anulan sus pagos), '
  'dejarlo a cuenta del próximo depósito (baja su deuda con la casa editora) o quedárselo el coordinador. Una decisión '
  'por todo lo pagado, sin repartir. Lo escribe únicamente decidir_alquiler_pagado(). La cuenta vigente es la de '
  'alquiler_calculado(): una decisión «a cuenta» o «se lo queda» de una cuenta que ya no está por decidir se da de baja '
  '(deleted_at, refrescar_cuenta_alquiler) y queda como historia; «devolver» no se deshace. No viaja por el sync.';
comment on column public.alquiler_decision.decision is
  'DEVOLVER_AL_COLPORTOR: los pagos de alquiler quedan anulados (deposito.anulado_at) y la plata vuelve a la persona. '
  'A_CUENTA_PROXIMO_DEPOSITO: se descontó de cuenta_colportor.deuda_total. SE_LO_QUEDA_EL_COORDINADOR: queda con el '
  'coordinador, sin tocar la deuda.';
comment on column public.alquiler_decision.monto is 'Centavos decididos (mayor que 0): todo lo que estaba por decidir.';
comment on column public.cuenta_alquiler.alquiler_a_favor is
  'Lo pagado que el coordinador decidió quedarse (SE_LO_QUEDA_EL_COORDINADOR, 0159/0167): vigente solo mientras la '
  'cuenta siga por decidir.';

-- ----------------------------------------------------------------------------
-- 4. La cuenta del alquiler: sin los pagos anulados y con los nombres nuevos
-- ----------------------------------------------------------------------------

create or replace function public.alquiler_calculado(p_usuario_id uuid, p_campania_id uuid)
returns table (monto bigint, debido bigint, pagado bigint, por_validar bigint, debe bigint, trasladado bigint,
               ultimo_pago timestamptz, a_favor bigint, por_decidir bigint, decide_coordinador boolean)
language sql
stable
security definer
set search_path = ''
as $$
  select c.alquiler_monto,
         d.debido,
         s.pagado,
         s.por_validar,
         case when d.debido is null then null else greatest(d.debido - s.pagado, 0) end,
         x.auto + x.trasladar,
         s.ultimo_pago,
         x.favor,
         x.sin_dueno - x.trasladar - x.favor,
         d.decide
    from public.campania c
    left join public.campania_colportor i on i.campania_id = c.id and i.usuario_id = p_usuario_id
    cross join lateral (
      select case when c.alquiler_monto is null then null
                  when i.deleted_at is not null then 0::bigint
                  else c.alquiler_monto end as debido,
             (c.alquiler_monto is null or i.deleted_at is not null) as decide
    ) d
    cross join lateral (
      select coalesce(sum(dep.monto) filter (where dep.validado_en is not null), 0)::bigint as pagado,
             coalesce(sum(dep.monto) filter (where dep.validado_en is null and dep.rechazado_en is null
                                               and (t.id is null or t.estado = 'PENDIENTE')), 0)::bigint
               as por_validar,
             max(dep.fecha) filter (where dep.validado_en is not null) as ultimo_pago
        from public.deposito dep
        left join public.ticket t on t.id = dep.ticket_id
       where dep.colportor_id = p_usuario_id and dep.deleted_at is null
         and dep.anulado_at is null
         and dep.concepto = 'ALQUILER' and dep.campania_id = p_campania_id
    ) s
    cross join lateral (
      select coalesce(sum(ad.monto) filter (where ad.decision = 'A_CUENTA_PROXIMO_DEPOSITO'), 0)::bigint as dec_trasladar,
             coalesce(sum(ad.monto) filter (where ad.decision = 'SE_LO_QUEDA_EL_COORDINADOR'), 0)::bigint as dec_favor
        from public.alquiler_decision ad
       where ad.usuario_id = p_usuario_id and ad.campania_id = p_campania_id and ad.deleted_at is null
    ) dd
    cross join lateral (
      -- «Alquiler fav» (0152): el sobrante de una inscripción viva en una campaña que cobra va solo a la deuda.
      -- Si la cuenta la decide el coordinador (baja o campaña sin alquiler), todo lo pagado es «sin dueño» y se
      -- reparte según lo decidido, sin pasarse de lo pagado: primero lo dejado a cuenta y con el resto lo que se queda
      -- el coordinador. Lo devuelto (0167) no está acá: sus pagos están anulados y no cuentan como pagados.
      select case when d.decide then 0::bigint else greatest(s.pagado - coalesce(d.debido, 0), 0) end as auto,
             case when d.decide then s.pagado else 0::bigint end as sin_dueno,
             case when d.decide then least(dd.dec_trasladar, s.pagado) else 0::bigint end as trasladar,
             case when d.decide then least(dd.dec_favor, s.pagado - least(dd.dec_trasladar, s.pagado))
                  else 0::bigint end as favor
    ) x
   where c.id = p_campania_id;
$$;

comment on function public.alquiler_calculado(uuid, uuid) is
  'La cuenta del alquiler de un colportor en una campaña (0132, backend-supabase#202; 0152; 0159, #234; 0167, #243): '
  'monto de la campaña, lo debido (0 si la inscripción está de baja, null si no cobra), pagado (depósitos validados, sin '
  'los pagos anulados por devolución), por validar (sin los retiros rechazados), debe (debido menos pagado, sin bajar de '
  '0), trasladado (el sobrante de una inscripción viva más lo que el coordinador dejó a cuenta del próximo depósito: va '
  'a la deuda con la casa editora), fecha del último pago, a_favor (lo que se queda el coordinador), por_decidir (lo '
  'pagado sin decidir) y decide_coordinador (true si la inscripción está de baja o la campaña no cobra: lo pagado lo '
  'decide el coordinador). Las decisiones cuentan solo mientras la cuenta siga por decidir y hasta lo pagado. La usan '
  'cuentas_de_campania(), cuenta_alquiler, decidir_alquiler_pagado() y validacion_calculada(). Interna.';

-- ----------------------------------------------------------------------------
-- 5. Quien la mantiene: «devolver» no se deshace
-- ----------------------------------------------------------------------------

create or replace function public.refrescar_cuenta_alquiler(p_campania_id uuid, p_usuario_id uuid)
returns void
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  r        record;
  v_viejo  bigint;
begin
  perform pg_advisory_xact_lock(hashtextextended('cuenta_alquiler:' || p_campania_id::text, 0));

  for r in
    select i.usuario_id, a.monto, a.pagado, a.por_validar, a.debe, a.trasladado, a.ultimo_pago, a.a_favor,
           a.por_decidir, a.decide_coordinador
      from public.campania_colportor i
      cross join lateral public.alquiler_calculado(i.usuario_id, i.campania_id) a
     where i.campania_id = p_campania_id
       and (p_usuario_id is null or i.usuario_id = p_usuario_id)
     order by i.usuario_id
  loop
    select ca.alquiler_trasladado into v_viejo
      from public.cuenta_alquiler ca
     where ca.usuario_id = r.usuario_id and ca.campania_id = p_campania_id;

    insert into public.cuenta_alquiler as ca
           (usuario_id, campania_id, alquiler_monto, alquiler_pagado, alquiler_por_validar, alquiler_debe,
            alquiler_trasladado, alquiler_ultimo_pago_fecha, alquiler_a_favor, alquiler_por_decidir)
    values (r.usuario_id, p_campania_id, r.monto, r.pagado, r.por_validar, r.debe, r.trasladado, r.ultimo_pago,
            r.a_favor, r.por_decidir)
    on conflict (usuario_id, campania_id) do update
       set alquiler_monto = excluded.alquiler_monto,
           alquiler_pagado = excluded.alquiler_pagado,
           alquiler_por_validar = excluded.alquiler_por_validar,
           alquiler_debe = excluded.alquiler_debe,
           alquiler_trasladado = excluded.alquiler_trasladado,
           alquiler_ultimo_pago_fecha = excluded.alquiler_ultimo_pago_fecha,
           alquiler_a_favor = excluded.alquiler_a_favor,
           alquiler_por_decidir = excluded.alquiler_por_decidir
     where (ca.alquiler_monto, ca.alquiler_pagado, ca.alquiler_por_validar, ca.alquiler_debe,
            ca.alquiler_trasladado, ca.alquiler_ultimo_pago_fecha, ca.alquiler_a_favor, ca.alquiler_por_decidir)
           is distinct from
           (excluded.alquiler_monto, excluded.alquiler_pagado, excluded.alquiler_por_validar, excluded.alquiler_debe,
            excluded.alquiler_trasladado, excluded.alquiler_ultimo_pago_fecha, excluded.alquiler_a_favor,
            excluded.alquiler_por_decidir);

    -- Lo trasladado a la deuda sigue a la cuenta: el sobrante de una inscripción viva y lo que el coordinador dejó a
    -- cuenta del próximo depósito. Si baja (la persona vuelve a deber, o se pierde lo que se podía decidir), se devuelve.
    if r.trasladado is distinct from coalesce(v_viejo, 0) then
      perform public.trasladar_alquiler_a_la_deuda(r.usuario_id, r.trasladado - coalesce(v_viejo, 0));
    end if;

    -- Si la cuenta ya no se decide (la persona volvió a estar inscripta, o la campaña pasó a cobrar alquiler), lo
    -- decidido «a cuenta» o «se lo queda» deja de valer: se da de baja y, si se vuelve a dar de baja a la persona, se
    -- decide de nuevo. La historia queda en el registro y en audit_log. «Devolver» no se deshace: la plata ya volvió a
    -- la persona y sus pagos siguen anulados.
    if not r.decide_coordinador then
      update public.alquiler_decision ad
         set deleted_at = now()
       where ad.usuario_id = r.usuario_id and ad.campania_id = p_campania_id and ad.deleted_at is null
         and ad.decision <> 'DEVOLVER_AL_COLPORTOR';
    end if;
  end loop;
end;
$$;

comment on function public.refrescar_cuenta_alquiler(uuid, uuid) is
  'Recalcula cuenta_alquiler de un colportor de una campaña (o de todos sus inscriptos con p_usuario_id null) '
  'con alquiler_calculado() y escribe solo lo que cambia (0132); mueve a cuenta_colportor.deuda_total la diferencia de '
  'lo trasladado (alquiler_trasladado: el sobrante de una inscripción viva, 0152, y lo que el coordinador dejó a cuenta '
  'del próximo depósito, 0159/0167). Guarda también lo que se queda el coordinador y lo que falta decidir. Si la cuenta '
  'ya no se decide, da de baja las decisiones «a cuenta» y «se lo queda» (no la de devolver). Toma un candado por '
  'campaña. La llaman los triggers de depósito, ticket, campaña e inscripción y decidir_alquiler_pagado(), en la '
  'transacción del cambio. Interna.';

-- ----------------------------------------------------------------------------
-- 6. decidir_alquiler_pagado: una decisión para todo lo pagado
-- ----------------------------------------------------------------------------

drop function public.decidir_alquiler_pagado(uuid, uuid, text, bigint);

create function public.decidir_alquiler_pagado(p_usuario_id uuid, p_campania_id uuid, p_decision text)
returns table (usuario_id uuid, campania_id uuid, decision text, monto_decidido bigint, por_decidir bigint,
               trasladado bigint, a_favor bigint, ya_estaba boolean)
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_c         public.campania;
  v_a         record;
  v_monto     bigint;
  v_cuenta    uuid;
  v_anulados  integer := 0;
  v_metadata  jsonb;
begin
  if auth.uid() is null or not (public.tiene_rol('ADMIN') or public.tiene_rol('COORDINADOR')) then
    raise exception 'Solo el coordinador de la campaña o un administrador puede decidir qué hacer con el alquiler pagado. Entrá con la cuenta del coordinador de esta campaña.'
      using errcode = 'insufficient_privilege';
  end if;

  select * into v_c from public.campania c where c.id = p_campania_id and c.deleted_at is null;
  if not found
     or not (public.tiene_rol('ADMIN') or v_c.coordinador_id = auth.uid())
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
    -- Devolver anula TODOS los pagos validados: si parte de lo pagado ya se decidió antes, habría que deshacer esa
    -- decisión, y eso no lo decide esta acción.
    if v_a.por_decidir < v_a.pagado then
      raise exception 'Una parte de lo que pagó ya se decidió antes (a cuenta o te la quedaste), así que no se puede devolver todo. Dejá lo que falta a cuenta del próximo depósito o quedátelo.'
        using errcode = 'AQ005';
    end if;

    -- Los pagos quedan anulados, nunca borrados, y dejan de contar. Lo que había sumado «Depositado» se resta.
    with anulados as (
      update public.deposito d
         set anulado_at = now(),
             anulado_por = auth.uid()
       where d.colportor_id = p_usuario_id and d.campania_id = p_campania_id
         and d.concepto = 'ALQUILER' and d.validado_en is not null
         and d.deleted_at is null and d.anulado_at is null
      returning d.monto
    )
    select count(*)::integer, coalesce(sum(an.monto), 0)::bigint into v_anulados, v_monto from anulados an;

    update public.cuenta_colportor cu
       set dinero_depositado = greatest(cu.dinero_depositado - v_monto, 0),
           actualizado_en = now()
     where cu.usuario_id = p_usuario_id and cu.deleted_at is null;

    v_metadata := jsonb_build_object('campania_id', p_campania_id, 'decision', p_decision, 'monto', v_monto,
                                     'por_decidir_antes', v_a.por_decidir, 'depositos_anulados', v_anulados);
  end if;

  insert into public.alquiler_decision (usuario_id, campania_id, decision, monto, decidido_por)
  values (p_usuario_id, p_campania_id, p_decision, v_monto, auth.uid());

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
  '«Alq. baja» (0159, backend-supabase#234; 0167, #243): el coordinador de la campaña (o el ADMIN) decide qué hacer con '
  'TODO lo pagado del alquiler por quien se dio de baja, o en una campaña sin alquiler: DEVOLVER_AL_COLPORTOR (sus pagos '
  'quedan anulados y dejan de contar), A_CUENTA_PROXIMO_DEPOSITO (se descuenta de la deuda con la casa editora) o '
  'SE_LO_QUEDA_EL_COORDINADOR (la deuda no se mueve). Una decisión por todo lo que estaba por decidir, sin repartir '
  '(idempotente: sin nada por decidir devuelve ya_estaba = true y no cambia nada). Queda en alquiler_decision y en '
  'audit_log (alquiler_pagado_decidido: ids, decisión y montos). Errores: 42501 sin permiso o decidiendo lo propio; '
  'AQ001 (campaña o persona inexistente o no es de sus campañas); AQ002 (decisión desconocida); AQ004 (el alquiler de '
  'esa persona no se decide: inscripción viva en una campaña que cobra); AQ005 (devolver cuando parte de lo pagado ya '
  'se decidió).';

revoke all on function public.decidir_alquiler_pagado(uuid, uuid, text)
  from public, anon, authenticated, service_role;
grant execute on function public.decidir_alquiler_pagado(uuid, uuid, text) to authenticated;
