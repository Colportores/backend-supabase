-- ============================================================================
-- 0152 · El depósito no marca qué cobros incluye, rechazar un retiro con motivo y el alquiler pagado de más va a la
--        deuda con la casa editora (backend-supabase#220, seguimiento de #135 / PR 193, #110 / PR 199 y #200;
--        respuestas de Cristian del 28/10 «Cobro en dep.», «Rechazo ret.» y «Alquiler fav»)
--
-- ## 1. «Cobro en dep.»: el depósito no marca qué cobros incluye
--
--   Ana junta $ 1.800 en efectivo y los deposita: carga el monto, no elige los cobros. La plata va de «por cobrar» a
--   «en mano» al cobrar y de «en mano» a «en cuenta» cuando la coordinadora valida el depósito.
--
--   · Se retira `deposito_cobro` (0122) del push y del modelo: la tabla, su fila en `sync.entidad`, sus dos triggers
--     (`deposito_cobro_del_cliente`, `deposito_cobro_de_ticket_rechazado`) y las funciones que los servían. Datos
--     simulados hasta diciembre: ningún cobro ni depósito se pierde (un vínculo solo decía qué cobros iban en qué
--     depósito; el cobro y el depósito siguen donde estaban).
--   · «En mano» es lo cobrado en efectivo (cobros vivos, no anulados) menos lo depositado: depósitos vivos, sin los
--     rechazados (un retiro rechazado, o un depósito cuyo ticket se rechazó) y contando los por validar y los
--     validados. `efectivo_en_mano(usuario, excepto)` es la única cuenta; `cuentas_de_campania()` la usa en vez del
--     `dinero_en_mano` guardado (que nadie mantenía).
--   · La validación compara el monto del depósito con lo que la colportora tiene en mano ANTES de ese depósito y la
--     diferencia avisa sin frenar (regla R4). Reemplaza a «la suma de los cobros vinculados» del 27/10:
--     `validacion_de_ticket`, `validacion_de_retiro`, `validar_ticket` y `confirmar_retiro` devuelven `en_mano` y
--     `diferencia = monto - en_mano`. `cobros_vinculados` queda solo para el cobro con tarjeta (los cobros que
--     apuntan al ticket); en un depósito es null.
--   · `rechazar_ticket` ya no libera cobros (no hay vínculos): deja de devolver `cobros_liberados`.
--   · Corregir o anular un cobro sigue con las 72 h de siempre.
--
-- ## 2. «Rechazo ret.»: rechazar un retiro con motivo
--
--   Marta recibió $U 5.000 de Lucía, pero Lucía cargó el retiro por $U 6.000. `rechazar_retiro(deposito, motivo)`,
--   para la coordinadora de la campaña (o el ADMIN), como `rechazar_ticket`: el retiro pasa a rechazado con el motivo
--   (no en blanco, hasta 500, recortado), queda como historia (no se borra, no se edita), no baja la deuda ni suma a
--   «en cuenta» y no cuenta como depositado (vuelve a estar «en mano»), y baja al teléfono con el motivo: Lucía carga
--   uno nuevo.
--
--   · `deposito.rechazado_en`, `rechazado_por` y `motivo_rechazo`: las pone el servidor (como `validado_en`); el
--     teléfono no las manda (`columnas_servidor`, y por la API directa un valor es 42501). Solo un retiro sin ticket
--     se rechaza por acá; el depósito con ticket se rechaza con su ticket. Un rechazado no se valida, no se edita y no
--     se da de baja (DP005); uno validado no se rechaza (DP004).
--   · Un reintento de quien ya lo rechazó, con el mismo motivo, devuelve `ya_estaba = true` sin tocar nada. Con la
--     fila bloqueada (FOR UPDATE), dos coordinadoras a la vez: la segunda recibe DP004 / DP005.
--   · Auditoría: `retiro_rechazado` (tabla deposito; ids, monto y concepto, nunca el motivo escrito).
--
-- ## 3. «Alquiler fav»: lo pagado de más del alquiler va a la deuda con la casa editora
--
--   Lucía pagó $U 3.000 de un alquiler de $U 2.500 en la campaña de verano. Los $U 500 de más se descuentan de la
--   deuda con la casa editora (la única, que pasa de campaña en campaña); el alquiler de esa campaña queda en 0 y el
--   traslado queda registrado y se lee, para que ni Lucía ni las coordinadoras vean plata que aparece o desaparece
--   sin explicación.
--
--   · `alquiler_calculado()` devuelve `trasladado` (= lo pagado que excede lo debido; antes `a_favor`); la fila
--     guardada de `cuenta_alquiler` lo llama `alquiler_trasladado` (renombra a `alquiler_a_favor`) y es lo que YA se
--     pasó a la deuda.
--   · `refrescar_cuenta_alquiler()` (la que mantienen los triggers de depósito, ticket, campaña e inscripción, 0132)
--     compara lo trasladado que tenía la fila con el que corresponde ahora y mueve la diferencia a
--     `cuenta_colportor.deuda_total` (resta) en la MISMA transacción. Así el traslado sigue a lo que cambia la
--     cuenta: validar un depósito de alquiler pasado el monto lo suma; quien se da de baja traslada todo lo que
--     pagó; si se reactiva y vuelve a deber, el traslado se deshace (regla R7); y un cambio del monto del alquiler lo
--     recalcula. No hay un segundo camino que pueda desfasarse.
--   · `cuenta_colportor.alquiler_trasladado`: el total que se pasó a la deuda en todas las campañas (informativo; baja
--     al teléfono por el sync). `cuentas_de_campania()` devuelve `alquiler_trasladado` de ESA campaña (reemplaza a
--     `alquiler_a_favor`, que ya no existe: lo de más no queda «a favor» del alquiler).
--   · La vista previa de validar (`validacion_calculada`): para un depósito de alquiler, `supera_deuda` y la nueva
--     `a_la_casa_editora` son lo que se pasa a la deuda con la casa editora; `a_favor_despues` es 0.
--   · `por_validar` del alquiler deja de contar los retiros rechazados.
--
-- ## Los datos
--
--   Se borra la tabla de vínculos (vacía en la práctica: ningún teléfono la subía) y, con la regla nueva, se recalcula
--   `cuenta_alquiler` de todas las campañas: lo que ya estaba pagado de más se traslada a la deuda en esta
--   migración (datos simulados hasta diciembre). Lo prueba supabase/tests_migracion/0152_ok.
--
-- ## Códigos de error nuevos
--
--   DP005  el retiro ya está rechazado (no se confirma, no se rechaza otra vez, no se edita) o lo rechazó otra persona.
--   DP006  el motivo del rechazo del retiro falta, está en blanco o pasa de 500 caracteres.
--
-- ## Para otros repos
--
--   · front-coordinadores-web#122: `rechazar_retiro`; los retiros por confirmar se leen de `deposito`
--     (destino = 'RETIRO_COORDINADOR', validado_en y rechazado_en null); `en_mano`, `diferencia` y `a_la_casa_editora`
--     en las vistas previas; `alquiler_trasladado` en lugar de `alquiler_a_favor`; `rechazar_ticket` sin `cobros_liberados`.
--   · front-colportores-mobile#442 / #443: el depósito no lleva cobros (`deposito_cobro` ya no es entidad del push); un
--     retiro rechazado baja con `rechazado_en` y `motivo_rechazo`; `cuenta_colportor.alquiler_trasladado`.
--   · docs-organizacion: HU-COB-001, HU-CTA-003/004/006, `esquema-datos.md`, `contrato-sync-engine.md` §2 (sin
--     `deposito_cobro`).
--
-- Forward-only: esta migración no se edita una vez aplicada.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. Se retira deposito_cobro
-- ----------------------------------------------------------------------------

delete from sync.entidad where nombre = 'deposito_cobro';

-- Con la tabla se van sus triggers, sus políticas y sus índices.
drop table public.deposito_cobro;

drop function public.tg_deposito_cobro_del_cliente();
drop function public.tg_deposito_cobro_de_ticket_rechazado();
drop function public.cobro_no_entra_en_deposito(uuid);

-- ----------------------------------------------------------------------------
-- 2. deposito: el rechazo de un retiro
-- ----------------------------------------------------------------------------

alter table public.deposito
  add column rechazado_en  timestamptz,
  add column rechazado_por uuid references public.usuario(id),
  add column motivo_rechazo text;

alter table public.deposito
  -- Un rechazo va completo: la fecha y el motivo (quién, si lo hizo una persona).
  add constraint deposito_rechazo_completo_check
    check ((rechazado_en is null and rechazado_por is null and motivo_rechazo is null)
           or (rechazado_en is not null and motivo_rechazo is not null
               and btrim(motivo_rechazo) <> '' and char_length(motivo_rechazo) <= 500)),
  -- Validado o rechazado, no las dos.
  add constraint deposito_rechazado_o_validado_check
    check (rechazado_en is null or validado_en is null),
  -- Solo un retiro sin ticket se rechaza por acá; el depósito con ticket, con su ticket.
  add constraint deposito_rechazo_solo_de_retiro_check
    check (rechazado_en is null or (destino = 'RETIRO_COORDINADOR' and ticket_id is null));

create index deposito_rechazado_por_idx on public.deposito (rechazado_por) where rechazado_por is not null;

comment on column public.deposito.rechazado_en is
  'Cuándo rechazó el coordinador este retiro sin ticket (0152, «Rechazo ret.»). El retiro queda como historia: no baja '
  'la deuda, no suma a «en cuenta» y no cuenta como depositado. Lo pone el servidor.';
comment on column public.deposito.rechazado_por is
  'El coordinador (o ADMIN) que rechazó el retiro (0152). Lo pone el servidor.';
comment on column public.deposito.motivo_rechazo is
  'El motivo que escribió quien rechazó el retiro (0152): no en blanco, hasta 500 caracteres. Baja al teléfono para que '
  'la colportora cargue uno nuevo. Lo pone el servidor.';

-- El teléfono no manda el rechazo: se descarta del push.
update sync.entidad
   set columnas_servidor = columnas_servidor || array['rechazado_en', 'rechazado_por', 'motivo_rechazo']
 where nombre = 'deposito';

-- La alta del teléfono no trae ni la validación (0129) ni el rechazo.
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
  end if;
  return new;
end;
$$;

comment on function public.tg_deposito_validado_del_servidor() is
  'BEFORE INSERT de deposito, solo para authenticated (0129, 0152): ni la validación (validado_en, validado_por) ni el '
  'rechazo (rechazado_en, rechazado_por, motivo_rechazo) los manda el teléfono (42501). El servidor no pasa por acá.';

create function public.tg_deposito_rechazado_no_se_edita()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if old.rechazado_en is not null
     and (new.colportor_id, new.monto, new.fecha, new.ticket_id, new.destino, new.concepto, new.campania_id,
          new.validado_en, new.validado_por, new.rechazado_en, new.rechazado_por, new.motivo_rechazo, new.deleted_at)
         is distinct from
         (old.colportor_id, old.monto, old.fecha, old.ticket_id, old.destino, old.concepto, old.campania_id,
          old.validado_en, old.validado_por, old.rechazado_en, old.rechazado_por, old.motivo_rechazo, old.deleted_at) then
    raise exception 'Un retiro rechazado queda como historia: no se edita ni se da de baja. Que la colportora cargue uno nuevo.'
      using errcode = 'DP005';
  end if;
  return new;
end;
$$;

comment on function public.tg_deposito_rechazado_no_se_edita() is
  'BEFORE UPDATE de deposito (0152): un retiro rechazado conserva todos sus datos y no se da de baja (DP005); solo '
  'cambia la auditoría. Vale también para el servidor.';

revoke all on function public.tg_deposito_rechazado_no_se_edita() from public, anon, authenticated, service_role;

create trigger deposito_rechazado_no_se_edita
  before update on public.deposito
  for each row execute function public.tg_deposito_rechazado_no_se_edita();

-- ----------------------------------------------------------------------------
-- 3. «En mano»: lo cobrado en efectivo menos lo depositado
-- ----------------------------------------------------------------------------

-- El efectivo que la colportora tiene encima: lo cobrado en efectivo (cobros vivos y no anulados de sus ventas) menos
-- lo depositado (depósitos vivos, por validar o validados; no los retiros rechazados ni los depósitos cuyo ticket se
-- rechazó), sin bajar de 0. `p_excepto` deja afuera un depósito (para comparar su monto con lo que había en mano antes
-- de él). Interna.
create function public.efectivo_en_mano(p_usuario_id uuid, p_excepto uuid default null)
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
                        and t.estado is distinct from 'RECHAZADO'
                        and d.id is distinct from p_excepto), 0),
         0)::bigint;
$$;

comment on function public.efectivo_en_mano(uuid, uuid) is
  '«En mano» (0152, «Cobro en dep.»): lo cobrado en efectivo (cobros vivos y no anulados) menos lo depositado '
  '(depósitos vivos por validar o validados, sin los retiros rechazados ni los de un ticket rechazado), sin bajar de 0. '
  'p_excepto deja afuera un depósito. Interna.';

revoke all on function public.efectivo_en_mano(uuid, uuid) from public, anon, authenticated, service_role;

-- ----------------------------------------------------------------------------
-- 4. El alquiler pagado de más va a la deuda con la casa editora
-- ----------------------------------------------------------------------------

alter table public.cuenta_colportor
  add column alquiler_trasladado bigint not null default 0;

comment on column public.cuenta_colportor.alquiler_trasladado is
  'Lo que se pasó a la deuda con la casa editora por haber pagado de más el alquiler, sumado en todas las campañas '
  '(0152, «Alquiler fav»). Informativo: ya está descontado de deuda_total. Lo escribe el servidor al refrescar '
  'cuenta_alquiler.';

alter table public.cuenta_alquiler
  rename column alquiler_a_favor to alquiler_trasladado;

comment on column public.cuenta_alquiler.alquiler_trasladado is
  'Lo pagado que excede lo debido (si está de baja, todo lo pagado): se descontó de la deuda con la casa editora '
  '(cuenta_colportor.deuda_total) en la misma transacción (0152, «Alquiler fav»).';
comment on table public.cuenta_alquiler is
  'El saldo de alquiler de cada colportor en cada campaña en la que tiene o tuvo inscripción (0132, '
  'backend-supabase#202, «Deuda alq.», 27/10; 0152): monto de la campaña, pagado (depósitos validados), por validar, '
  'lo que debe, lo que se trasladó a la deuda con la casa editora por pagar de más y la fecha del último pago. Lo '
  'escribe SOLO el servidor, en la misma transacción que cada depósito, ticket, cambio del monto o inscripción que lo '
  'mueve (refrescar_cuenta_alquiler); la cuenta es la de alquiler_calculado(), la misma de cuentas_de_campania(). '
  'Quien se da de baja debe 0 y todo lo pagado se traslada. No viaja por el sync.';

-- La cuenta del alquiler, con `trasladado` (antes `a_favor`) y sin contar los retiros rechazados. Cambia el nombre de
-- una columna de salida: drop + create (la llaman funciones plpgsql, que se resuelven al ejecutar).
drop function public.alquiler_calculado(uuid, uuid);

create function public.alquiler_calculado(p_usuario_id uuid, p_campania_id uuid)
returns table (monto bigint, debido bigint, pagado bigint, por_validar bigint, debe bigint, trasladado bigint,
               ultimo_pago timestamptz)
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
         greatest(s.pagado - coalesce(d.debido, 0), 0),
         s.ultimo_pago
    from public.campania c
    left join public.campania_colportor i on i.campania_id = c.id and i.usuario_id = p_usuario_id
    cross join lateral (
      select case when c.alquiler_monto is null then null
                  when i.deleted_at is not null then 0::bigint
                  else c.alquiler_monto end as debido
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
   where c.id = p_campania_id;
$$;

comment on function public.alquiler_calculado(uuid, uuid) is
  'La cuenta del alquiler de un colportor en una campaña (0132, backend-supabase#202; 0152): monto de la campaña, lo '
  'debido (0 si la inscripción está de baja, null si no cobra), pagado (depósitos validados), por validar (sin los '
  'retiros rechazados), debe (debido menos pagado, sin bajar de 0), trasladado (lo pagado que excede lo debido: va a '
  'la deuda con la casa editora) y fecha del último pago. La usan cuentas_de_campania(), cuenta_alquiler y '
  'validacion_calculada(). Interna.';

revoke all on function public.alquiler_calculado(uuid, uuid) from public, anon, authenticated, service_role;

-- Mueve plata a la deuda con la casa editora por el alquiler: p_monto positivo la baja, negativo la deshace. Crea la
-- cuenta si no existe; si estaba dada de baja, la reactiva desde cero en las cifras que toca. Interna.
create function public.trasladar_alquiler_a_la_deuda(p_usuario_id uuid, p_monto bigint)
returns void
language sql
volatile
security definer
set search_path = ''
as $$
  insert into public.cuenta_colportor as cu (usuario_id, deuda_total, alquiler_trasladado)
  values (p_usuario_id, -p_monto, greatest(p_monto, 0))
  on conflict (usuario_id) do update
    set deuda_total = case when cu.deleted_at is null then cu.deuda_total else 0 end + excluded.deuda_total,
        alquiler_trasladado = case when cu.deleted_at is null then cu.alquiler_trasladado else 0 end + p_monto,
        deleted_at = null,
        actualizado_en = now();
$$;

comment on function public.trasladar_alquiler_a_la_deuda(uuid, bigint) is
  'Descuenta p_monto de cuenta_colportor.deuda_total (o lo devuelve, si es negativo) y lo suma a '
  'alquiler_trasladado: lo pagado de más del alquiler (0152). La llama refrescar_cuenta_alquiler(). Interna.';

revoke all on function public.trasladar_alquiler_a_la_deuda(uuid, bigint) from public, anon, authenticated, service_role;

-- Recalcula la fila de un colportor de una campaña (p_usuario_id) o de todos los inscriptos (null), escribe solo lo que
-- cambia y mueve a la deuda la diferencia de lo trasladado. El candado por campaña va ANTES de la cuenta (0132).
-- Interna.
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
    select i.usuario_id, a.monto, a.pagado, a.por_validar, a.debe, a.trasladado, a.ultimo_pago
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
            alquiler_trasladado, alquiler_ultimo_pago_fecha)
    values (r.usuario_id, p_campania_id, r.monto, r.pagado, r.por_validar, r.debe, r.trasladado, r.ultimo_pago)
    on conflict (usuario_id, campania_id) do update
       set alquiler_monto = excluded.alquiler_monto,
           alquiler_pagado = excluded.alquiler_pagado,
           alquiler_por_validar = excluded.alquiler_por_validar,
           alquiler_debe = excluded.alquiler_debe,
           alquiler_trasladado = excluded.alquiler_trasladado,
           alquiler_ultimo_pago_fecha = excluded.alquiler_ultimo_pago_fecha
     where (ca.alquiler_monto, ca.alquiler_pagado, ca.alquiler_por_validar, ca.alquiler_debe,
            ca.alquiler_trasladado, ca.alquiler_ultimo_pago_fecha)
           is distinct from
           (excluded.alquiler_monto, excluded.alquiler_pagado, excluded.alquiler_por_validar, excluded.alquiler_debe,
            excluded.alquiler_trasladado, excluded.alquiler_ultimo_pago_fecha);

    -- «Alquiler fav»: lo pagado de más se descuenta de la deuda con la casa editora; si el traslado baja (la persona
    -- vuelve a deber, o sube el monto), se devuelve.
    if r.trasladado is distinct from coalesce(v_viejo, 0) then
      perform public.trasladar_alquiler_a_la_deuda(r.usuario_id, r.trasladado - coalesce(v_viejo, 0));
    end if;
  end loop;
end;
$$;

comment on function public.refrescar_cuenta_alquiler(uuid, uuid) is
  'Recalcula cuenta_alquiler de un colportor de una campaña (o de todos sus inscriptos con p_usuario_id null) '
  'con alquiler_calculado() y escribe solo lo que cambia (0132); mueve a cuenta_colportor.deuda_total la diferencia de '
  'lo pagado de más (alquiler_trasladado, 0152). Toma un candado por campaña. La llaman los triggers de depósito, '
  'ticket, campaña e inscripción, en la transacción del cambio. Interna.';

-- Un retiro que se rechaza deja de contar como «por validar»: el trigger de depósito también mira rechazado_en.
drop trigger deposito_cuenta_alquiler on public.deposito;

create trigger deposito_cuenta_alquiler
  after insert or delete or update of colportor_id, monto, ticket_id, concepto, campania_id, validado_en, rechazado_en, deleted_at
  on public.deposito
  for each row execute function public.tg_deposito_cuenta_alquiler();

-- Lo que ya estaba pagado de más se traslada ahora: la cuenta guardada se pone en 0 («nada trasladado todavía») y se
-- recalcula, que mueve la diferencia a la deuda.
update public.cuenta_alquiler set alquiler_trasladado = 0 where alquiler_trasladado <> 0;
select public.refrescar_cuenta_alquiler(c.id, null) from public.campania c;

-- ----------------------------------------------------------------------------
-- 5. La vista previa de validar
-- ----------------------------------------------------------------------------

-- Cambia la forma de salida (cobros_vinculados sigue solo para la tarjeta; en_mano y a_la_casa_editora son nuevas): drop
-- + create de ella y de las cuatro que la devuelven, con los mismos privilegios.
drop function public.validacion_de_ticket(uuid);
drop function public.validacion_de_retiro(uuid);
drop function public.validar_ticket(uuid);
drop function public.confirmar_retiro(uuid);
drop function public.rechazar_ticket(uuid, text);
drop function public.validacion_calculada(uuid, uuid);

create function public.validacion_calculada(p_ticket_id uuid, p_deposito_id uuid)
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
      select a.debido, a.pagado into v_alquiler, v_pagado
        from public.alquiler_calculado(v_colportor, v_d.campania_id) a;
      if v_alquiler is not null then
        v_antes := greatest(v_alquiler - v_pagado, 0);
        v_despues := v_alquiler - v_pagado - v_monto;
        v_traslada := greatest(v_monto - v_antes, 0);
      else
        -- La campaña no cobra alquiler: todo lo que se valida pasa a la deuda con la casa editora.
        v_traslada := v_monto;
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
  'depósito de alquiler, lo que excede lo debido (supera_deuda = a_la_casa_editora) se pasa a la deuda con la casa '
  'editora y a_favor_despues es 0. Ya validado, las cifras de la deuda son null. Sin permisos: interna (0129, 0132, '
  '0152).';

revoke all on function public.validacion_calculada(uuid, uuid) from public, anon, authenticated, service_role;

create function public.validacion_de_ticket(p_ticket_id uuid)
returns table (ticket_id uuid, deposito_id uuid, colportor_id uuid, tipo text, concepto text, destino text,
               campania_id uuid, monto_ticket bigint, monto bigint, cobros_vinculados bigint, en_mano bigint,
               diferencia bigint, deuda_antes bigint, deuda_despues bigint, supera_deuda bigint,
               a_favor_despues bigint, a_la_casa_editora bigint)
language plpgsql
volatile
security definer
set search_path = ''
as $$
begin
  perform public.ticket_para_validar(p_ticket_id, false);
  return query select vc.* from public.validacion_calculada(p_ticket_id, null) vc;
end;
$$;

comment on function public.validacion_de_ticket(uuid) is
  'Vista 29 (0129, backend-supabase#110; 0152): lo que pasa si el coordinador valida este ticket: monto que se '
  'acredita, concepto, lo que la colportora tenía en mano y la diferencia (aviso, no frena) o, en un cobro con tarjeta, '
  'los cobros del ticket, y la deuda del concepto antes y después (supera_deuda y a_favor_despues para el aviso «Pago '
  'de más»; a_la_casa_editora, lo que un alquiler pagado de más pasa a la deuda con la casa editora). No cambia nada. '
  'Errores: 42501 sin permiso o ticket propio; TV001 ticket inexistente o de otra campaña.';

revoke all on function public.validacion_de_ticket(uuid) from public, anon, authenticated, service_role;
grant execute on function public.validacion_de_ticket(uuid) to authenticated;

create function public.validacion_de_retiro(p_deposito_id uuid)
returns table (ticket_id uuid, deposito_id uuid, colportor_id uuid, tipo text, concepto text, destino text,
               campania_id uuid, monto_ticket bigint, monto bigint, cobros_vinculados bigint, en_mano bigint,
               diferencia bigint, deuda_antes bigint, deuda_despues bigint, supera_deuda bigint,
               a_favor_despues bigint, a_la_casa_editora bigint)
language plpgsql
volatile
security definer
set search_path = ''
as $$
begin
  perform public.retiro_para_confirmar(p_deposito_id, false);
  return query select vc.* from public.validacion_calculada(null, p_deposito_id) vc;
end;
$$;

comment on function public.validacion_de_retiro(uuid) is
  'Lo que pasa si el coordinador confirma este retiro sin ticket (0129; 0152): lo mismo que validacion_de_ticket. No '
  'cambia nada. Un retiro ya rechazado no tiene cifras de deuda. Errores: 42501 sin permiso o retiro propio; DP002 '
  'inexistente o de otra campaña; DP003 si tiene ticket.';

revoke all on function public.validacion_de_retiro(uuid) from public, anon, authenticated, service_role;
grant execute on function public.validacion_de_retiro(uuid) to authenticated;

-- ----------------------------------------------------------------------------
-- 6. Lo que decide el coordinador
-- ----------------------------------------------------------------------------

create function public.validar_ticket(p_ticket_id uuid)
returns table (ticket_id uuid, deposito_id uuid, estado text, validado_en timestamptz, monto bigint,
               cobros_vinculados bigint, en_mano bigint, diferencia bigint, deuda_antes bigint,
               deuda_despues bigint, supera_deuda bigint, a_favor_despues bigint, a_la_casa_editora bigint,
               ya_estaba boolean)
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_t     public.ticket;
  v_c     record;
  v_ahora timestamptz := clock_timestamp();
begin
  v_t := public.ticket_para_validar(p_ticket_id, true);
  select * into v_c from public.validacion_calculada(v_t.id, null);

  -- Un reintento de quien ya lo validó no acredita dos veces.
  if v_t.estado = 'VALIDADO' and v_t.revisado_por = auth.uid() then
    return query select v_t.id, v_c.deposito_id, v_t.estado, v_t.revisado_en, v_c.monto, v_c.cobros_vinculados,
                        v_c.en_mano, v_c.diferencia, v_c.deuda_antes, v_c.deuda_despues, v_c.supera_deuda,
                        v_c.a_favor_despues, v_c.a_la_casa_editora, true;
    return;
  end if;

  if v_t.estado <> 'PENDIENTE' then
    raise exception 'Este ticket ya no está pendiente: otra persona lo resolvió. Recargá la lista para ver cómo quedó.'
      using errcode = 'TV002';
  end if;
  if v_t.tipo = 'DEPOSITO' and v_c.deposito_id is null then
    raise exception 'Todavía no llegó el depósito de este ticket: el teléfono del colportor tiene que sincronizar. Probá de nuevo más tarde.'
      using errcode = 'TV005';
  end if;
  if v_t.tipo in ('DEPOSITO', 'COBRO_TARJETA') and v_c.monto is null then
    raise exception 'El ticket no tiene monto, no hay nada para acreditar. Rechazalo con un motivo para que el colportor lo cargue de nuevo.'
      using errcode = 'TV004';
  end if;

  update public.ticket t
     set estado = 'VALIDADO',
         revisado_por = auth.uid(),
         revisado_en = v_ahora
   where t.id = v_t.id;

  -- Validar un depósito de alquiler refresca cuenta_alquiler (trigger) y traslada a la deuda lo pagado de más.
  if v_c.deposito_id is not null then
    update public.deposito d
       set validado_en = v_ahora,
           validado_por = auth.uid()
     where d.id = v_c.deposito_id;
  end if;

  if v_c.monto is not null then
    perform public.acreditar_en_la_cuenta(v_t.usuario_id, v_c.monto, v_c.concepto = 'CASA_EDITORA');
  end if;

  perform auditoria.registrar(
    'ticket_validado', 'ticket', v_t.id, v_t.usuario_id,
    jsonb_build_object('tipo', v_t.tipo,
                       'deposito_id', v_c.deposito_id,
                       'concepto', v_c.concepto,
                       'monto', v_c.monto,
                       'cobros_vinculados', v_c.cobros_vinculados,
                       'en_mano', v_c.en_mano,
                       'deuda_antes', v_c.deuda_antes,
                       'deuda_despues', v_c.deuda_despues));

  return query select v_t.id, v_c.deposito_id, 'VALIDADO'::text, v_ahora, v_c.monto, v_c.cobros_vinculados,
                      v_c.en_mano, v_c.diferencia, v_c.deuda_antes, v_c.deuda_despues, v_c.supera_deuda,
                      v_c.a_favor_despues, v_c.a_la_casa_editora, false;
end;
$$;

comment on function public.validar_ticket(uuid) is
  'Vista 29, HU-COB-008 (0129, backend-supabase#110; 0152): el coordinador valida el ticket. Un ticket de depósito '
  'valida su depósito y lo acredita (Depositado sube; la deuda del concepto baja, y lo de más queda a favor; en un '
  'alquiler, lo de más pasa a la deuda con la casa editora); uno de tarjeta acredita su monto como casa editora; uno '
  'de otro tipo solo queda validado. diferencia es el aviso contra lo que tenía en mano, no frena. ya_estaba = true '
  'si YO ya lo validé. Errores: 42501; TV001; TV002 (ya resuelto); TV004 (sin monto); TV005 (el depósito no llegó).';

revoke all on function public.validar_ticket(uuid) from public, anon, authenticated, service_role;
grant execute on function public.validar_ticket(uuid) to authenticated;

create function public.confirmar_retiro(p_deposito_id uuid)
returns table (ticket_id uuid, deposito_id uuid, estado text, validado_en timestamptz, monto bigint,
               cobros_vinculados bigint, en_mano bigint, diferencia bigint, deuda_antes bigint,
               deuda_despues bigint, supera_deuda bigint, a_favor_despues bigint, a_la_casa_editora bigint,
               ya_estaba boolean)
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_d     public.deposito;
  v_c     record;
  v_ahora timestamptz := clock_timestamp();
begin
  v_d := public.retiro_para_confirmar(p_deposito_id, true);
  select * into v_c from public.validacion_calculada(null, v_d.id);

  if v_d.rechazado_en is not null then
    raise exception 'Este retiro ya se rechazó: no se puede confirmar. Pedile a la colportora que cargue uno nuevo.'
      using errcode = 'DP005';
  end if;

  if v_d.validado_en is not null then
    if v_d.validado_por is not distinct from auth.uid() then
      return query select null::uuid, v_d.id, 'VALIDADO'::text, v_d.validado_en, v_c.monto, v_c.cobros_vinculados,
                          v_c.en_mano, v_c.diferencia, v_c.deuda_antes, v_c.deuda_despues, v_c.supera_deuda,
                          v_c.a_favor_despues, v_c.a_la_casa_editora, true;
      return;
    end if;
    raise exception 'Este retiro ya lo confirmó otra persona. Recargá la lista para ver cómo quedó.'
      using errcode = 'DP004';
  end if;

  update public.deposito d
     set validado_en = v_ahora,
         validado_por = auth.uid()
   where d.id = v_d.id;

  perform public.acreditar_en_la_cuenta(v_d.colportor_id, v_c.monto, v_c.concepto = 'CASA_EDITORA');

  perform auditoria.registrar(
    'retiro_confirmado', 'deposito', v_d.id, v_d.colportor_id,
    jsonb_build_object('concepto', v_c.concepto,
                       'monto', v_c.monto,
                       'cobros_vinculados', v_c.cobros_vinculados,
                       'en_mano', v_c.en_mano,
                       'deuda_antes', v_c.deuda_antes,
                       'deuda_despues', v_c.deuda_despues));

  return query select null::uuid, v_d.id, 'VALIDADO'::text, v_ahora, v_c.monto, v_c.cobros_vinculados,
                      v_c.en_mano, v_c.diferencia, v_c.deuda_antes, v_c.deuda_despues, v_c.supera_deuda,
                      v_c.a_favor_despues, v_c.a_la_casa_editora, false;
end;
$$;

comment on function public.confirmar_retiro(uuid) is
  'HU-CTA-004 / S70 (0129, backend-supabase#110; 0152): el coordinador confirma que retiró el efectivo de un depósito '
  'RETIRO_COORDINADOR (sin ticket): se acredita igual que un ticket validado. ya_estaba = true si YO ya lo '
  'confirmé. Errores: 42501; DP002 (inexistente o de otra campaña); DP003 (tiene ticket); DP004 (lo confirmó '
  'otra persona); DP005 (ya está rechazado).';

revoke all on function public.confirmar_retiro(uuid) from public, anon, authenticated, service_role;
grant execute on function public.confirmar_retiro(uuid) to authenticated;

-- Rechazar un ticket ya no libera cobros: no hay vínculos que dar de baja.
create function public.rechazar_ticket(p_ticket_id uuid, p_motivo text)
returns table (ticket_id uuid, estado text, revisado_en timestamptz, ya_estaba boolean)
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_t       public.ticket;
  v_motivo  text;
  v_ahora   timestamptz := clock_timestamp();
begin
  v_t := public.ticket_para_validar(p_ticket_id, true);
  v_motivo := regexp_replace(coalesce(p_motivo, ''), '^\s+|\s+$', '', 'g');

  -- Un reintento de quien ya lo rechazó, con el mismo motivo, no cambia nada.
  if v_t.estado = 'RECHAZADO' and v_t.revisado_por = auth.uid() and v_t.motivo_rechazo = v_motivo then
    return query select v_t.id, v_t.estado, v_t.revisado_en, true;
    return;
  end if;

  if v_motivo = '' or length(v_motivo) > 500 then
    raise exception 'Escribí el motivo del rechazo (hasta 500 caracteres) para que el colportor sepa qué corregir.'
      using errcode = 'TV003';
  end if;
  if v_t.estado <> 'PENDIENTE' then
    raise exception 'Este ticket ya no está pendiente: otra persona lo resolvió. Recargá la lista para ver cómo quedó.'
      using errcode = 'TV002';
  end if;

  update public.ticket t
     set estado = 'RECHAZADO',
         motivo_rechazo = v_motivo,
         revisado_por = auth.uid(),
         revisado_en = v_ahora
   where t.id = v_t.id;

  perform auditoria.registrar(
    'ticket_rechazado', 'ticket', v_t.id, v_t.usuario_id,
    jsonb_build_object('tipo', v_t.tipo));

  return query select v_t.id, 'RECHAZADO'::text, v_ahora, false;
end;
$$;

comment on function public.rechazar_ticket(uuid, text) is
  'Vista 29, HU-COB-008 (0129, backend-supabase#110; 0152): el coordinador rechaza el ticket con un motivo (no en '
  'blanco, hasta 500, recortado). La deuda no cambia; un depósito rechazado deja de contar como depositado (vuelve a '
  'estar en mano). ya_estaba = true si YO ya lo rechacé con el mismo motivo. Errores: 42501; TV001; TV002; '
  'TV003 (motivo). El motivo escrito no se copia a audit_log.';

revoke all on function public.rechazar_ticket(uuid, text) from public, anon, authenticated, service_role;
grant execute on function public.rechazar_ticket(uuid, text) to authenticated;

-- «Rechazo ret.»: el retiro sin ticket que no coincide con lo que recibió la coordinadora.
create function public.rechazar_retiro(p_deposito_id uuid, p_motivo text)
returns table (deposito_id uuid, rechazado_en timestamptz, ya_estaba boolean)
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_d       public.deposito;
  v_motivo  text;
  v_ahora   timestamptz := clock_timestamp();
begin
  v_d := public.retiro_para_confirmar(p_deposito_id, true);
  v_motivo := regexp_replace(coalesce(p_motivo, ''), '^\s+|\s+$', '', 'g');

  -- Un reintento de quien ya lo rechazó, con el mismo motivo, no cambia nada.
  if v_d.rechazado_en is not null and v_d.rechazado_por is not distinct from auth.uid()
     and v_d.motivo_rechazo = v_motivo then
    return query select v_d.id, v_d.rechazado_en, true;
    return;
  end if;

  if v_motivo = '' or length(v_motivo) > 500 then
    raise exception 'Escribí el motivo del rechazo (hasta 500 caracteres) para que la colportora sepa qué corregir.'
      using errcode = 'DP006';
  end if;
  if v_d.rechazado_en is not null then
    raise exception 'Este retiro ya lo rechazó otra persona. Recargá la lista para ver cómo quedó.'
      using errcode = 'DP005';
  end if;
  if v_d.validado_en is not null then
    raise exception 'Este retiro ya lo confirmó otra persona. Recargá la lista para ver cómo quedó.'
      using errcode = 'DP004';
  end if;

  update public.deposito d
     set rechazado_en = v_ahora,
         rechazado_por = auth.uid(),
         motivo_rechazo = v_motivo
   where d.id = v_d.id;

  perform auditoria.registrar(
    'retiro_rechazado', 'deposito', v_d.id, v_d.colportor_id,
    jsonb_build_object('concepto', v_d.concepto, 'monto', v_d.monto));

  return query select v_d.id, v_ahora, false;
end;
$$;

comment on function public.rechazar_retiro(uuid, text) is
  '«Rechazo ret.» (0152, backend-supabase#220): el coordinador de la campaña (o el ADMIN) rechaza un retiro sin ticket '
  'con un motivo (no en blanco, hasta 500, recortado). El retiro queda como historia (no se borra ni se edita), no baja '
  'la deuda ni suma a «en cuenta», vuelve a estar en mano y baja al teléfono con el motivo. ya_estaba = true si YO lo '
  'rechacé con el mismo motivo. Errores: 42501 sin permiso o retiro propio; DP002 (inexistente o de otra campaña); '
  'DP003 (tiene ticket); DP004 (ya lo confirmó alguien); DP005 (ya lo rechazó otra persona); DP006 (motivo). El motivo '
  'escrito no se copia a audit_log.';

revoke all on function public.rechazar_retiro(uuid, text) from public, anon, authenticated, service_role;
grant execute on function public.rechazar_retiro(uuid, text) to authenticated;

-- ----------------------------------------------------------------------------
-- 7. cuentas_de_campania: «en mano» calculado y el alquiler trasladado
-- ----------------------------------------------------------------------------

drop function public.cuentas_de_campania(uuid);

create function public.cuentas_de_campania(p_campania_id uuid)
returns table (colportor_id uuid, nombre text, apellido text, de_baja boolean,
               ciudad_id uuid, ciudad_nombre text, departamento text,
               deuda_total bigint, dinero_depositado bigint, dinero_en_mano bigint,
               dinero_por_cobrar bigint,
               ultimo_deposito_fecha timestamptz, ultimo_deposito_monto bigint,
               alquiler_monto bigint, alquiler_pagado bigint, alquiler_por_validar bigint,
               alquiler_debe bigint, alquiler_ultimo_pago_fecha timestamptz, alquiler_trasladado bigint)
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
           alq.trasladado
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
  'Vista 36, HU-CTA-005 y HU-CTA-007 (0114, backend-supabase#111; 0129, #110; 0132, #202; 0152, #220): una fila por '
  'colportor de la campaña con su ciudad (la de su zona actual), las cuatro cifras de su cuenta (deuda, depositado y '
  'por cobrar de cuenta_colportor; «en mano» = lo cobrado en efectivo menos lo depositado), el último depósito de casa '
  'editora y el alquiler de ESTA campaña aparte: monto, pagado (depósitos validados), por validar, lo que debe, la '
  'fecha del último pago y lo trasladado: lo pagado de más, que ya se descontó de la deuda con la casa editora. Quien '
  'está de baja debe 0 y todo lo pagado se traslada. Ni clientes ni personas visitadas. Errores: 42501 sin permiso; '
  'CZ001 campaña inexistente. Una campaña terminada se lee.';

revoke all on function public.cuentas_de_campania(uuid)
  from public, anon, authenticated, service_role;
grant execute on function public.cuentas_de_campania(uuid) to authenticated;
