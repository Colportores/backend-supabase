-- ============================================================================
-- 0159 · Lo pagado del alquiler por quien se da de baja, o en una campaña sin alquiler, lo decide el coordinador
--        (backend-supabase#234, casilla «Baja y alq.»; decisión de Cristian del 03/11 en backend-supabase#230,
--        corrige lo que la 0152 hacía solo)
--
-- La 0152 pasaba sola a la deuda con la casa editora todo lo pagado del alquiler por quien se daba de baja y todo
-- lo pagado en una campaña que no cobra alquiler. Desde esta migración eso queda **por decidir**: no se mueve nada
-- hasta que el coordinador de la campaña (o un ADMIN) elige, con una persona a la vez:
--
--   · «Trasladar a la deuda»: lo decidido se descuenta de la deuda con la casa editora (`deuda_total`);
--   · «Dejar a favor»: lo decidido queda como saldo a favor del alquiler de esa campaña; la deuda no se mueve.
--
-- Cada decisión queda registrada (`alquiler_decision`, solo se agrega) y deja un evento en `audit_log`
-- (`alquiler_pagado_decidido`). Se decide por monto y se acumula: se puede trasladar una parte y dejar el resto a
-- favor; sin monto, se decide todo lo que queda por decidir.
--
-- **Lo que NO cambia** («Alquiler fav», 0152): el sobrante sobre el alquiler de una inscripción **viva** en una
-- campaña que cobra sigue pasando solo a la deuda. Quien se da de baja y vuelve a anotarse, o la campaña que pasa a
-- cobrar alquiler, deja de estar «por decidir» y el pagado vuelve a cubrir el alquiler: lo decidido antes ya no
-- cuenta (se recalcula y, si había movido plata a la deuda, se devuelve, regla R7). Las decisiones de antes se dan
-- de baja (`deleted_at`) y quedan como historia; si la persona vuelve a darse de baja, se decide de nuevo.
--
-- ## Qué cambia en las lecturas
--
--   · `alquiler_calculado()` devuelve además `a_favor` (lo decidido a favor, vigente), `por_decidir` (lo pagado
--     que todavía no se decidió) y `decide_coordinador` (si lo pagado de esa cuenta lo decide el coordinador).
--     `trasladado` = el sobrante de una inscripción viva + lo decidido a trasladar.
--   · `cuenta_alquiler` guarda `alquiler_a_favor` y `alquiler_por_decidir`. `cuentas_de_campania()` los devuelve
--     (`alquiler_a_favor`, `alquiler_por_decidir`).
--   · La vista previa de validar (`validacion_calculada`) mantiene su forma: para un depósito de alquiler de quien
--     está de baja o de una campaña sin alquiler, `a_la_casa_editora` es 0 (no se mueve nada al validar) y
--     `supera_deuda` es lo que quedará por decidir.
--
-- ## RPC
--
--   `decidir_alquiler_pagado(p_usuario_id, p_campania_id, p_decision, p_monto default null)` — ver el comentario de
--   la función. Errores: 42501 sin permiso o decidiendo lo propio; AQ001 la campaña no existe, no es de sus
--   campañas o la persona no tiene alquiler en ella (todas contestan igual); AQ002 decisión desconocida; AQ003
--   monto cero, negativo o mayor que lo que queda por decidir; AQ004 el alquiler de esa persona no se decide (la
--   inscripción está viva en una campaña que cobra: lo de más ya pasa solo a la deuda).
--
-- ## Los datos
--
--   Se recalcula la cuenta de todas las campañas: lo que la 0152 había pasado solo a la deuda por una baja o por una
--   campaña sin alquiler vuelve a la deuda y queda **por decidir** (ningún depósito ni cobro se toca; datos
--   simulados hasta diciembre). Lo prueba supabase/tests_migracion/0159_ok.
--
-- ## Para otros repos
--   · front-coordinadores-web#132: la acción «por decidir» de la vista 36 llama a `decidir_alquiler_pagado`; lee
--     `alquiler_por_decidir`, `alquiler_a_favor` y `alquiler_trasladado` de `cuentas_de_campania()`.
--   · front-colportores-mobile: `cuenta_colportor.alquiler_trasladado` baja solo con lo trasladado de verdad.
--   · docs-organizacion: HU-CTA-003/004/006 y `esquema-datos.md` (`alquiler_decision`).
--
-- Forward-only: esta migración no se edita una vez aplicada.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. El registro de decisiones
-- ----------------------------------------------------------------------------

create table public.alquiler_decision (
  id            uuid primary key default public.uuid_generate_v7(),
  usuario_id    uuid not null references public.usuario(id) on delete cascade,
  campania_id   uuid not null references public.campania(id) on delete cascade,
  decision      text not null,
  monto         bigint not null,
  decidido_por  uuid references public.usuario(id) on delete set null,
  decidido_en   timestamptz not null default now(),
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  created_by    uuid default auth.uid() references public.usuario(id) on delete set null,
  deleted_at    timestamptz,
  sync_version  bigint not null default 0,
  xmin_w        xid8 not null default pg_current_xact_id(),
  constraint alquiler_decision_decision_check
    check (decision in ('TRASLADAR_A_LA_DEUDA', 'DEJAR_A_FAVOR')),
  constraint alquiler_decision_monto_check check (monto > 0)
);

create index alquiler_decision_cuenta_idx on public.alquiler_decision (campania_id, usuario_id);
create index alquiler_decision_decidido_por_idx on public.alquiler_decision (decidido_por) where decidido_por is not null;

comment on table public.alquiler_decision is
  'Lo que el coordinador (o un ADMIN) decidió hacer con lo pagado del alquiler de quien se dio de baja o de una '
  'campaña sin alquiler (0159, backend-supabase#234): trasladarlo a la deuda con la casa editora o dejarlo a favor, '
  'por monto y acumulando. Lo escribe únicamente decidir_alquiler_pagado(). La cuenta vigente es la de '
  'alquiler_calculado(): una decisión de una cuenta que ya no está por decidir se da de baja (deleted_at, '
  'refrescar_cuenta_alquiler) y queda como historia. No viaja por el sync.';
comment on column public.alquiler_decision.decision is
  'TRASLADAR_A_LA_DEUDA: se descontó de cuenta_colportor.deuda_total. DEJAR_A_FAVOR: queda a favor del alquiler de '
  'la campaña, sin tocar la deuda.';
comment on column public.alquiler_decision.monto is 'Centavos decididos en este paso (mayor que 0).';

create trigger alquiler_decision_auditoria_insert
  before insert on public.alquiler_decision
  for each row execute function public.tg_auditoria_insert();
create trigger alquiler_decision_auditoria_update
  before update on public.alquiler_decision
  for each row execute function public.tg_auditoria_update();

alter table public.alquiler_decision enable row level security;
revoke all on public.alquiler_decision from anon, authenticated;
grant select on public.alquiler_decision to authenticated;
grant all on public.alquiler_decision to service_role;

-- LEE: la persona (sabe qué se decidió con su plata), el ADMIN y quien coordina ESA campaña. Sin políticas de
-- escritura: no escribe nadie con JWT.
create policy alquiler_decision_select on public.alquiler_decision
  for select to authenticated
  using (usuario_id = (select auth.uid())
         or (select public.tiene_rol('ADMIN'))
         or ((select public.tiene_rol('COORDINADOR'))
             and exists (select 1 from public.campania c
                          where c.id = alquiler_decision.campania_id
                            and c.coordinador_id = (select auth.uid()))));

-- ----------------------------------------------------------------------------
-- 2. La cuenta guardada
-- ----------------------------------------------------------------------------

alter table public.cuenta_alquiler
  add column alquiler_a_favor bigint not null default 0,
  add column alquiler_por_decidir bigint not null default 0,
  add constraint cuenta_alquiler_decision_check check (alquiler_a_favor >= 0 and alquiler_por_decidir >= 0);

comment on column public.cuenta_alquiler.alquiler_a_favor is
  'Lo pagado que el coordinador decidió dejar a favor (0159): vigente solo mientras la cuenta siga por decidir.';
comment on column public.cuenta_alquiler.alquiler_por_decidir is
  'Lo pagado por quien está de baja, o en una campaña sin alquiler, que el coordinador todavía no decidió (0159). No '
  'se mueve a ningún lado hasta que decida.';
comment on column public.cuenta_alquiler.alquiler_trasladado is
  'Lo que se descontó de la deuda con la casa editora por este alquiler: el sobrante de una inscripción viva '
  '(«Alquiler fav», 0152) más lo que el coordinador decidió trasladar (0159). Se descontó de '
  'cuenta_colportor.deuda_total en la misma transacción.';

-- ----------------------------------------------------------------------------
-- 3. La cuenta del alquiler
-- ----------------------------------------------------------------------------

drop function public.alquiler_calculado(uuid, uuid);

create function public.alquiler_calculado(p_usuario_id uuid, p_campania_id uuid)
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
         and dep.concepto = 'ALQUILER' and dep.campania_id = p_campania_id
    ) s
    cross join lateral (
      select coalesce(sum(ad.monto) filter (where ad.decision = 'TRASLADAR_A_LA_DEUDA'), 0)::bigint as dec_trasladar,
             coalesce(sum(ad.monto) filter (where ad.decision = 'DEJAR_A_FAVOR'), 0)::bigint as dec_favor
        from public.alquiler_decision ad
       where ad.usuario_id = p_usuario_id and ad.campania_id = p_campania_id and ad.deleted_at is null
    ) dd
    cross join lateral (
      -- «Alquiler fav» (0152): el sobrante de una inscripción viva en una campaña que cobra va solo a la deuda.
      -- Si la cuenta la decide el coordinador (baja o campaña sin alquiler), todo lo pagado es «sin dueño» y se
      -- reparte según lo decidido, sin pasarse de lo pagado: primero lo trasladado y con el resto lo dejado a favor.
      select case when d.decide then 0::bigint else greatest(s.pagado - coalesce(d.debido, 0), 0) end as auto,
             case when d.decide then s.pagado else 0::bigint end as sin_dueno,
             case when d.decide then least(dd.dec_trasladar, s.pagado) else 0::bigint end as trasladar,
             case when d.decide then least(dd.dec_favor, s.pagado - least(dd.dec_trasladar, s.pagado))
                  else 0::bigint end as favor
    ) x
   where c.id = p_campania_id;
$$;

comment on function public.alquiler_calculado(uuid, uuid) is
  'La cuenta del alquiler de un colportor en una campaña (0132, backend-supabase#202; 0152; 0159, #234): monto de la '
  'campaña, lo debido (0 si la inscripción está de baja, null si no cobra), pagado (depósitos validados), por validar '
  '(sin los retiros rechazados), debe (debido menos pagado, sin bajar de 0), trasladado (el sobrante de una '
  'inscripción viva más lo que el coordinador decidió trasladar: va a la deuda con la casa editora), fecha del último '
  'pago, a_favor (lo decidido a favor), por_decidir (lo pagado sin decidir) y decide_coordinador (true si la '
  'inscripción está de baja o la campaña no cobra: lo pagado lo decide el coordinador). Las decisiones cuentan solo '
  'mientras la cuenta siga por decidir y hasta lo pagado. La usan cuentas_de_campania(), cuenta_alquiler, '
  'decidir_alquiler_pagado() y validacion_calculada(). Interna.';

revoke all on function public.alquiler_calculado(uuid, uuid) from public, anon, authenticated, service_role;

-- ----------------------------------------------------------------------------
-- 4. Quien la mantiene: también guarda lo decidido y lo que falta decidir
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

    -- Lo trasladado a la deuda sigue a la cuenta: el sobrante de una inscripción viva y lo que el coordinador decidió
    -- trasladar. Si baja (la persona vuelve a deber, o se pierde lo que se podía decidir), se devuelve.
    if r.trasladado is distinct from coalesce(v_viejo, 0) then
      perform public.trasladar_alquiler_a_la_deuda(r.usuario_id, r.trasladado - coalesce(v_viejo, 0));
    end if;

    -- Si la cuenta ya no se decide (la persona volvió a estar inscripta, o la campaña pasó a cobrar alquiler), lo
    -- decidido antes deja de valer: se da de baja y, si se vuelve a dar de baja a la persona, se decide de nuevo.
    -- La historia queda en el registro y en audit_log.
    if not r.decide_coordinador then
      update public.alquiler_decision ad
         set deleted_at = now()
       where ad.usuario_id = r.usuario_id and ad.campania_id = p_campania_id and ad.deleted_at is null;
    end if;
  end loop;
end;
$$;

comment on function public.refrescar_cuenta_alquiler(uuid, uuid) is
  'Recalcula cuenta_alquiler de un colportor de una campaña (o de todos sus inscriptos con p_usuario_id null) '
  'con alquiler_calculado() y escribe solo lo que cambia (0132); mueve a cuenta_colportor.deuda_total la diferencia de '
  'lo trasladado (alquiler_trasladado: el sobrante de una inscripción viva, 0152, y lo que el coordinador decidió '
  'trasladar, 0159). Guarda también lo decidido a favor y lo que falta decidir. Toma un candado por campaña. La '
  'llaman los triggers de depósito, ticket, campaña e inscripción y decidir_alquiler_pagado(), en la transacción del '
  'cambio. Interna.';

-- Lo que la 0152 pasó solo a la deuda por una baja o por una campaña sin alquiler vuelve a la deuda y queda por
-- decidir: se recalcula todo con la regla nueva (la diferencia de lo trasladado se mueve en la misma transacción).
select public.refrescar_cuenta_alquiler(c.id, null) from public.campania c;

-- ----------------------------------------------------------------------------
-- 5. decidir_alquiler_pagado: la decisión del coordinador
-- ----------------------------------------------------------------------------

create function public.decidir_alquiler_pagado(p_usuario_id uuid, p_campania_id uuid, p_decision text,
                                               p_monto bigint default null)
returns table (usuario_id uuid, campania_id uuid, decision text, monto_decidido bigint, por_decidir bigint,
               trasladado bigint, a_favor bigint, ya_estaba boolean)
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_c      public.campania;
  v_a      record;
  v_monto  bigint;
  v_cuenta uuid;
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
  if p_decision is null or p_decision not in ('TRASLADAR_A_LA_DEUDA', 'DEJAR_A_FAVOR') then
    raise exception 'Elegí qué hacer con lo pagado: trasladarlo a la deuda con la casa editora o dejarlo a favor.'
      using errcode = 'AQ002';
  end if;

  -- El mismo candado que la cuenta (refrescar_cuenta_alquiler): dos coordinadores a la vez no se pisan.
  perform pg_advisory_xact_lock(hashtextextended('cuenta_alquiler:' || p_campania_id::text, 0));

  select * into v_a from public.alquiler_calculado(p_usuario_id, p_campania_id) a;
  if not v_a.decide_coordinador then
    raise exception 'El alquiler de esta persona sigue vigente: lo que pagó de más pasa solo a la deuda con la casa editora. No hay nada que decidir.'
      using errcode = 'AQ004';
  end if;

  -- Sin monto, se decide todo lo que queda. Si ya no queda nada (un doble toque, o lo decidió otra persona un
  -- instante antes), no se hace nada y se avisa con ya_estaba.
  if p_monto is null and v_a.por_decidir = 0 then
    return query select p_usuario_id, p_campania_id, p_decision, 0::bigint, v_a.por_decidir, v_a.trasladado,
                        v_a.a_favor, true;
    return;
  end if;

  v_monto := coalesce(p_monto, v_a.por_decidir);
  if v_monto <= 0 or v_monto > v_a.por_decidir then
    raise exception 'El monto tiene que ser mayor que cero y no pasar de lo que queda por decidir. Recargá la lista para ver cuánto queda.'
      using errcode = 'AQ003';
  end if;

  insert into public.alquiler_decision (usuario_id, campania_id, decision, monto, decidido_por)
  values (p_usuario_id, p_campania_id, p_decision, v_monto, auth.uid());

  -- Mueve a la deuda lo que corresponda y deja la cuenta guardada al día.
  perform public.refrescar_cuenta_alquiler(p_campania_id, p_usuario_id);

  select ca.id into v_cuenta
    from public.cuenta_alquiler ca
   where ca.usuario_id = p_usuario_id and ca.campania_id = p_campania_id;

  perform auditoria.registrar(
    'alquiler_pagado_decidido', 'cuenta_alquiler', v_cuenta, p_usuario_id,
    jsonb_build_object('campania_id', p_campania_id, 'decision', p_decision, 'monto', v_monto,
                       'por_decidir_antes', v_a.por_decidir));

  select * into v_a from public.alquiler_calculado(p_usuario_id, p_campania_id) a;
  return query select p_usuario_id, p_campania_id, p_decision, v_monto, v_a.por_decidir, v_a.trasladado,
                      v_a.a_favor, false;
end;
$$;

comment on function public.decidir_alquiler_pagado(uuid, uuid, text, bigint) is
  '«Baja y alq.» (0159, backend-supabase#234): el coordinador de la campaña (o el ADMIN) decide qué hacer con lo '
  'pagado del alquiler por quien se dio de baja, o en una campaña sin alquiler: TRASLADAR_A_LA_DEUDA (se descuenta '
  'de la deuda con la casa editora) o DEJAR_A_FAVOR (queda a favor del alquiler de la campaña). Por monto y '
  'acumulando; sin p_monto se decide todo lo que queda por decidir (idempotente: sin nada por decidir devuelve '
  'ya_estaba = true y no cambia nada). Queda en alquiler_decision y en audit_log (alquiler_pagado_decidido: ids, '
  'decisión y montos). Errores: 42501 sin permiso o decidiendo lo propio; AQ001 (campaña o persona inexistente o '
  'no es de sus campañas); AQ002 (decisión desconocida); AQ003 (monto cero, negativo o mayor que lo que queda por '
  'decidir); AQ004 (el alquiler de esa persona no se decide: inscripción viva en una campaña que cobra).';

revoke all on function public.decidir_alquiler_pagado(uuid, uuid, text, bigint)
  from public, anon, authenticated, service_role;
grant execute on function public.decidir_alquiler_pagado(uuid, uuid, text, bigint) to authenticated;

-- ----------------------------------------------------------------------------
-- 6. La vista previa de validar
-- ----------------------------------------------------------------------------

-- Misma forma de salida que la de la 0152: create or replace (los privilegios y las cuatro funciones que la llaman
-- quedan como están).
create or replace function public.validacion_calculada(p_ticket_id uuid, p_deposito_id uuid)
returns table (ticket_id uuid, deposito_id uuid, colportor_id uuid, tipo text, concepto text, destino text,
               campania_id uuid, monto_ticket bigint, monto bigint, cobros_vinculados bigint, en_mano bigint,
               diferencia bigint, deuda_antes bigint, deuda_despues bigint, supera_deuda bigint,
               a_favor_despues bigint, a_la_casa_editora bigint)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_t         public.ticket;
  v_d         public.deposito;
  v_colportor uuid;
  v_concepto  text;
  v_monto     bigint;
  v_cobros    bigint;
  v_en_mano   bigint;
  v_base      bigint;
  v_pendiente boolean;
  v_antes     bigint;
  v_despues   bigint;
  v_alquiler  bigint;
  v_pagado    bigint;
  v_traslada  bigint;
  v_decide    boolean;
begin
  if p_ticket_id is not null then
    select * into v_t from public.ticket t where t.id = p_ticket_id;
    select * into v_d
      from public.deposito d
     where d.ticket_id = p_ticket_id and d.deleted_at is null
     order by d.created_at, d.id
     limit 1;
    v_colportor := v_t.usuario_id;
    v_pendiente := v_t.estado = 'PENDIENTE';
  else
    select * into v_d from public.deposito d where d.id = p_deposito_id;
    v_colportor := v_d.colportor_id;
    v_pendiente := v_d.validado_en is null and v_d.rechazado_en is null and v_d.deleted_at is null;
  end if;

  if v_t.id is null or v_t.tipo = 'DEPOSITO' then
    -- Un depósito (con ticket, o un retiro sin ticket): el monto es el del depósito y se compara con lo que la
    -- colportora tenía en mano antes de él («Cobro en dep.»).
    v_monto := v_d.monto;
    v_concepto := v_d.concepto;
    if v_d.id is not null then
      v_en_mano := public.efectivo_en_mano(v_colportor, v_d.id);
      v_base := v_en_mano;
    end if;
  elsif v_t.tipo = 'COBRO_TARJETA' then
    -- El cobro con tarjeta: el monto es el del ticket, y es plata de la casa editora (S66).
    v_monto := v_t.monto;
    v_concepto := 'CASA_EDITORA';
    select coalesce(sum(c.monto), 0)::bigint into v_cobros
      from public.cobranza c
     where c.ticket_id = v_t.id and c.deleted_at is null and c.anulado_at is null;
    v_base := v_cobros;
  end if;

  if v_monto is not null and v_pendiente then
    if v_concepto = 'CASA_EDITORA' then
      select cu.deuda_total into v_antes
        from public.cuenta_colportor cu
       where cu.usuario_id = v_colportor and cu.deleted_at is null;
      v_antes := coalesce(v_antes, 0);
      v_despues := v_antes - v_monto;
    elsif v_concepto = 'ALQUILER' then
      -- v_alquiler es lo DEBIDO (0132): el monto de la campaña, 0 si la inscripción está de baja, null si no cobra.
      select a.debido, a.pagado, a.decide_coordinador into v_alquiler, v_pagado, v_decide
        from public.alquiler_calculado(v_colportor, v_d.campania_id) a;
      if v_alquiler is not null then
        v_antes := greatest(v_alquiler - v_pagado, 0);
        v_despues := v_alquiler - v_pagado - v_monto;
        -- El sobrante de una inscripción viva pasa solo a la deuda («Alquiler fav»); si la persona está de baja,
        -- lo que se valida queda por decidir y no se mueve nada (0159).
        v_traslada := case when v_decide then 0 else greatest(v_monto - v_antes, 0) end;
      else
        -- La campaña no cobra alquiler: lo que se valida queda por decidir por el coordinador (0159).
        v_traslada := 0;
      end if;
    end if;
  end if;

  return query
    select v_t.id,
           v_d.id,
           v_colportor,
           v_t.tipo,
           v_concepto,
           v_d.destino,
           v_d.campania_id,
           v_t.monto,
           v_monto,
           v_cobros,
           v_en_mano,
           v_monto - v_base,
           v_antes,
           case when v_despues is null then null else greatest(v_despues, 0) end,
           case when v_antes is null then null else greatest(v_monto - greatest(v_antes, 0), 0) end,
           case when v_despues is null then null
                when v_concepto = 'ALQUILER' then 0::bigint
                else greatest(-v_despues, 0) end,
           v_traslada;
end;
$$;

comment on function public.validacion_calculada(uuid, uuid) is
  'Qué pasa al validar un ticket (p_ticket_id) o un retiro sin ticket (p_deposito_id): monto que se acredita; para un '
  'depósito, lo que la colportora tenía en mano antes de él (en_mano) y la diferencia con el monto (aviso, no frena); '
  'para un cobro con tarjeta, los cobros del ticket; y la deuda del concepto antes y después (casa editora: '
  'deuda_total; alquiler: lo debido de la campaña según alquiler_calculado(): quien está de baja no debe nada). En un '
  'depósito de alquiler de una inscripción viva, lo que excede lo debido (supera_deuda = a_la_casa_editora) se pasa '
  'a la deuda con la casa editora y a_favor_despues es 0; si la persona está de baja o la campaña no cobra, '
  'a_la_casa_editora es 0 (no se mueve nada) y supera_deuda es lo que quedará por decidir (0159). Ya validado, las '
  'cifras de la deuda son null. Sin permisos: interna (0129, 0132, 0152, 0159).';

-- ----------------------------------------------------------------------------
-- 7. cuentas_de_campania: lo dejado a favor y lo que queda por decidir
-- ----------------------------------------------------------------------------

drop function public.cuentas_de_campania(uuid);

create function public.cuentas_de_campania(p_campania_id uuid)
returns table (colportor_id uuid, nombre text, apellido text, de_baja boolean,
               ciudad_id uuid, ciudad_nombre text, departamento text,
               deuda_total bigint, dinero_depositado bigint, dinero_en_mano bigint,
               dinero_por_cobrar bigint,
               ultimo_deposito_fecha timestamptz, ultimo_deposito_monto bigint,
               alquiler_monto bigint, alquiler_pagado bigint, alquiler_por_validar bigint,
               alquiler_debe bigint, alquiler_ultimo_pago_fecha timestamptz, alquiler_trasladado bigint,
               alquiler_a_favor bigint, alquiler_por_decidir bigint)
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_motivo    text;
begin
  -- El permiso, antes de mirar nada más. Una campaña terminada se lee; lo demás es lo de siempre.
  v_motivo := public.motivo_mapa_de_campania(p_campania_id);
  if v_motivo = 'SIN_PERMISO' then
    raise exception 'Solo el coordinador de la campaña o un administrador puede ver sus cuentas. Entrá con la cuenta del coordinador de esta campaña.'
      using errcode = 'insufficient_privilege';
  end if;
  if v_motivo is distinct from 'CAMPANIA_TERMINADA' then
    perform public.lanzar_motivo_mapa(v_motivo);
  end if;

  return query
    select i.usuario_id,
           usr.nombre,
           usr.apellido,
           (i.deleted_at is not null),
           ciu.id,
           ciu.nombre,
           ciu.departamento,
           case when vg.vigente then coalesce(cu.deuda_total, 0) end,
           case when vg.vigente then coalesce(cu.dinero_depositado, 0) end,
           -- «En mano»: lo cobrado en efectivo menos lo depositado (0152), no la cifra guardada.
           case when vg.vigente then public.efectivo_en_mano(i.usuario_id) end,
           case when vg.vigente then coalesce(cu.dinero_por_cobrar, 0) end,
           ult.fecha,
           ult.monto,
           alq.monto,
           alq.pagado,
           alq.por_validar,
           alq.debe,
           alq.ultimo_pago,
           alq.trasladado,
           alq.a_favor,
           alq.por_decidir
      from public.campania_colportor i
      join public.usuario usr on usr.id = i.usuario_id
      left join public.zona z
             on z.id = i.zona_id and z.deleted_at is null and i.deleted_at is null
      left join public.campania_ciudad cc
             on cc.id = z.campania_ciudad_id and cc.deleted_at is null
      left join public.ciudad ciu on ciu.id = cc.ciudad_id
      left join public.cuenta_colportor cu
             on cu.usuario_id = i.usuario_id and cu.deleted_at is null
      -- ¿Esta es la campaña vigente del colportor hoy? (la ventana de su inscripción, 0113). Las cuatro cifras
      -- no tienen campaña: solo se muestran a quien coordina la campaña en la que el colportor está ahora.
      cross join lateral (
        select (public.campania_del_ticket(i.usuario_id, now()) = p_campania_id) as vigente
      ) vg
      left join lateral (
        select d.fecha, d.monto
          from public.deposito d
         where d.colportor_id = i.usuario_id and d.deleted_at is null
           and d.concepto = 'CASA_EDITORA'
           -- Solo los de ESTA campaña: el que lleva campania_id, o el que no la lleva y su fecha cae en la
           -- ventana de esta inscripción (campania_del_ticket, 0113). Lo que el colportor hace en otra campaña
           -- no se le muestra a este coordinador.
           and coalesce(d.campania_id, public.campania_del_ticket(d.colportor_id, d.fecha)) = p_campania_id
         order by d.fecha desc, d.id
         limit 1
      ) ult on true
      -- El alquiler de ESTA campaña, por la cuenta única (quien está de baja debe 0; lo pagado de más se traslada).
      cross join lateral public.alquiler_calculado(i.usuario_id, p_campania_id) alq
     where i.campania_id = p_campania_id
     order by ciu.nombre nulls last, usr.apellido, usr.nombre, i.usuario_id;
end;
$$;

comment on function public.cuentas_de_campania(uuid) is
  'Vista 36, HU-CTA-005 y HU-CTA-007 (0114, backend-supabase#111; 0129, #110; 0132, #202; 0152, #220; 0159, #234): una fila por '
  'colportor de la campaña con su ciudad (la de su zona actual), las cuatro cifras de su cuenta (deuda, depositado y '
  'por cobrar de cuenta_colportor; «en mano» = lo cobrado en efectivo menos lo depositado), el último depósito de casa '
  'editora y el alquiler de ESTA campaña aparte: monto, pagado (depósitos validados), por validar, lo que debe, la '
  'fecha del último pago, lo trasladado (el sobrante de una inscripción viva y lo que el coordinador decidió trasladar: '
  'ya se descontó de la deuda con la casa editora), lo dejado a favor y lo que queda por decidir (0159). Quien está '
  'de baja debe 0 y lo pagado queda por decidir. Ni clientes ni personas visitadas. Errores: 42501 sin permiso; '
  'CZ001 campaña inexistente. Una campaña terminada se lee.';

revoke all on function public.cuentas_de_campania(uuid)
  from public, anon, authenticated, service_role;
grant execute on function public.cuentas_de_campania(uuid) to authenticated;
