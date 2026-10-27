-- ============================================================================
-- 0129 · Validar el ticket acredita el depósito y baja la deuda (backend-supabase#110, BACK-HU-COB-008,
--        HU-COB-008, HU-CTA-003, HU-CTA-004 y HU-CTA-006, vista 29 «Validar tickets»)
--
-- Origen: cambio de requisitos del 21/10 (reunión del 05/10, docs#69, C6) y las decisiones de Cristian del 23/10
-- («Acredita V1»: validar acredita desde el S10, un cobro con tarjeta o un depósito quedan «por validar» y suman a
-- «Depositado» recién cuando el coordinador los valida) y del 25/10 («Pago de más»: lo pagado de más queda a
-- favor y se ve, y se descuenta de la próxima deuda del mismo concepto; «Retiro coord»: el retiro lo carga el
-- colportor y se valida en el panel). El alcance de este issue lo fijó el orquestador el 27/10 (#183 P3, #193
-- P2 y P3). Esta migración SOLO SUMA sobre la tabla `ticket` (0067, 0113) y `deposito` (0067, 0114, 0122).
--
-- ## Qué suma
--
--   1. `deposito.validado_en` y `deposito.validado_por`: el depósito lleva su propia validación. Vale para el
--      que respalda un ticket (se valida con el ticket) y para el retiro por el coordinador, que no tiene ticket
--      (lo confirma el coordinador cuando retira el efectivo, HU-CTA-004 / S70). Las pone el servidor: el
--      teléfono no las manda (`columnas_servidor`, y por la API directa un valor es 42501). Un depósito
--      validado no se edita ni se da de baja (DP001): una corrección es un movimiento nuevo (HU-COB-008).
--   2. `cuentas_de_campania` (0114, 0119) cuenta como alquiler pagado solo lo que tiene `validado_en`; lo que no
--      se validó y no fue rechazado (sin ticket, o con el ticket pendiente) sigue en `alquiler_por_validar`. El
--      saldo a favor del alquiler es `alquiler_pagado - alquiler_monto` cuando es positivo (el debe no baja de 0).
--   3. Tres RPC que deciden (SECURITY DEFINER, VOLATILE, EXECUTE solo para `authenticated`) y dos que leen:
--
--        validacion_de_ticket(p_ticket_id)            antes de confirmar: lo que va a pasar
--        validacion_de_retiro(p_deposito_id)          lo mismo para un retiro sin ticket
--          -> (ticket_id, deposito_id, colportor_id, tipo, concepto, destino, campania_id, monto_ticket, monto,
--              cobros_vinculados, diferencia, deuda_antes, deuda_despues, supera_deuda, a_favor_despues)
--        validar_ticket(p_ticket_id)
--        confirmar_retiro(p_deposito_id)
--          -> (ticket_id, deposito_id, estado, validado_en, monto, cobros_vinculados, diferencia, deuda_antes,
--              deuda_despues, supera_deuda, a_favor_despues, ya_estaba)
--        rechazar_ticket(p_ticket_id, p_motivo)
--          -> (ticket_id, estado, revisado_en, cobros_liberados, ya_estaba)
--
--      · `monto` es lo que se acredita: el del depósito (ticket de depósito) o el del ticket (cobro con
--        tarjeta). `cobros_vinculados` es la suma de los cobros que el depósito incluye (`deposito_cobro`) o que
--        apuntan al ticket de tarjeta (`cobranza.ticket_id`), sin los anulados ni dados de baja. `diferencia`
--        = monto - cobros_vinculados: es el AVISO de «Pago de más», no frena nada (P3 de #193).
--      · `deuda_antes`, `deuda_despues`, `supera_deuda` y `a_favor_despues` son la cuenta del concepto ANTES de
--        validar: casa editora (`cuenta_colportor.deuda_total`, que puede quedar negativa = a favor) o alquiler
--        de la campaña del depósito (alquiler_monto menos lo ya validado, sin bajar de 0; null si la campaña no
--        cobra alquiler). `supera_deuda` = lo que de este monto excede la deuda (0 si no la excede):
--        «Supera la deuda de $U 5.000: quedan $U 3.000 a favor». Ya validado, esas cuatro columnas son null.
--
--   · validar_ticket: PENDIENTE -> VALIDADO (revisado_por / revisado_en) y, en la MISMA transacción:
--        - ticket de DEPOSITO: valida el depósito del ticket y acredita su monto con su concepto. Si el depósito
--          todavía no llegó del teléfono, se bloquea (TV005): el push puede traer el ticket antes.
--        - ticket de COBRO_TARJETA: acredita el monto del ticket como casa editora (S66: el cobro con tarjeta
--          cuenta como depositado al validarlo; HU-COB-008: validar baja la deuda).
--        - ticket de OTRO: queda validado sin acreditar nada (pendiente).
--      Acreditar es sumar a `cuenta_colportor.dinero_depositado` y, si el concepto es casa editora, restar de
--      `deuda_total` (puede quedar negativa: lo pagado de más queda a favor y se descuenta de la próxima
--      deuda). El alquiler no tiene saldo guardado: sale de los depósitos validados de la campaña. `dinero_en_mano`
--      no se toca (lo calcula el snapshot de V2, que no existe todavía; pendiente).
--   · confirmar_retiro: el mismo efecto para un depósito RETIRO_COORDINADOR (sin ticket).
--   · rechazar_ticket: PENDIENTE -> RECHAZADO con motivo (no en blanco, hasta 500, recortado; el CHECK de 0067).
--        No toca la cuenta (la deuda no cambia). Si era el ticket de un depósito, libera los cobros que el
--        depósito incluía (baja de sus vínculos, que hace el servidor: 0122) para que el colportor los incluya
--        en el depósito nuevo que sube con el ticket corregido. El depósito rechazado queda como estaba.
--   · Un reintento no acredita dos veces: validar un ticket que YO ya validé, o rechazar uno que YO ya rechacé
--     con el mismo motivo, o confirmar un retiro que YO ya confirmé, devuelve el estado con `ya_estaba = true` sin
--     tocar nada. Dos coordinadores a la vez: la fila se bloquea (FOR UPDATE) y el segundo recibe TV002 / DP004.
--
-- ## Permiso
--
--   ADMIN, o COORDINADOR de la campaña a la que pertenece el ticket por su fecha (`campania_del_ticket`, 0113)
--   o, en un retiro, la campaña del depósito (o la de su fecha). Nadie valida lo suyo: un coordinador que
--   también es colportor no valida sus propios tickets (42501). Un ticket o retiro que no existe y uno de otra
--   campaña dan el mismo error (TV001 / DP002): no se averigua qué hay.
--
-- ## Errores (todos con mensaje que dice qué hacer)
--
--   42501  sin permiso; el ticket o el retiro es del propio usuario; un valor de validación mandado por el teléfono.
--   TV001  el ticket no existe o no es de un colportor de tus campañas.
--   TV002  el ticket ya no está pendiente (otra persona lo resolvió).
--   TV003  el motivo del rechazo falta, está en blanco o pasa de 500 caracteres.
--   TV004  el ticket no tiene monto: no hay qué acreditar.
--   TV005  el depósito del ticket todavía no llegó del teléfono del colportor.
--   DP001  un depósito validado no se edita ni se da de baja.
--   DP002  el retiro no existe o no es de un colportor de tus campañas.
--   DP003  el depósito no es un retiro sin ticket (se valida desde su ticket).
--   DP004  otra persona ya confirmó el retiro.
--
-- ## Auditoría (HU-ADM-007, en la misma transacción; ids, montos y estados, nunca el motivo escrito)
--
--   `ticket_validado`, `ticket_rechazado` (tabla ticket) y `retiro_confirmado` (tabla deposito).
--
-- ## Lo que NO hace (y por qué)
--
--   · No rechaza un retiro sin ticket: la HU solo dice confirmar (pendiente).
--   · No avisa por push al colportor ni al coordinador (HU-NOT-003, Edge Function): el cambio de estado le llega
--     por el sync (el ticket y el depósito suben de versión).
--   · No calcula `dinero_en_mano` ni «Por cobrar» del snapshot, ni lo recalcula entero: suma y resta sobre lo que
--     hay (la conexión de V2 lo calcula). No lleva el saldo a favor del alquiler a otra campaña.
--   · No deshace una validación: una corrección es un movimiento nuevo (HU-COB-008).
--
-- ## Los datos
--
-- Dos columnas opcionales y un backfill: los depósitos cuyo ticket ya estaba VALIDADO pasan a tener
-- `validado_en` (la fecha de revisión del ticket) y `validado_por`, para que el alquiler que ya se contaba como
-- pagado lo siga siendo con el predicado nuevo. Ese UPDATE sube `sync_version` y `xmin_w` de esas filas a
-- propósito: el teléfono tiene que enterarse de que su depósito está validado. Los retiros sin ticket que ya
-- hubiera siguen por validar. Nada se borra. Lo prueba supabase/tests_migracion/0129_ok.
--
-- ## Para otros repos
--
--   · front-coordinadores-web#69 (vista 29): POST /rest/v1/rpc/<nombre> con los parámetros de arriba; los
--     errores llegan en `code` del cuerpo de PostgREST. Los retiros por confirmar se leen de `deposito`
--     (destino = 'RETIRO_COORDINADOR' y validado_en null).
--   · front-colportores-mobile#431/#438: el depósito baja con `validado_en` / `validado_por` por el pull; el ticket,
--     con su estado y su motivo. «Depositado» suma solo lo validado.
--   · docs-organizacion: esquema-datos.md (deposito, errores TV y DP) y HU-COB-008 en un issue aparte.
--
-- Forward-only: esta migración no se edita una vez aplicada.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. deposito: su propia validación
-- ----------------------------------------------------------------------------

alter table public.deposito
  add column validado_en  timestamptz,
  add column validado_por uuid references public.usuario(id);

-- Quien validó va con la fecha. No al revés: un depósito que ya estaba validado por un ticket VALIDADO cargado
-- por el servidor sin revisor (los tests de 0114) conserva la fecha sin quién.
alter table public.deposito
  add constraint deposito_validado_por_con_fecha_check
  check (validado_por is null or validado_en is not null);

create index deposito_validado_por_idx on public.deposito (validado_por) where validado_por is not null;

comment on column public.deposito.validado_en is
  'Cuándo se validó el depósito (0129): al validar su ticket o, en un retiro sin ticket, al confirmar el '
  'coordinador que retiró el efectivo. null = por validar. Lo pone el servidor. Solo lo validado acredita: '
  'suma a «Depositado» y baja la deuda del concepto.';
comment on column public.deposito.validado_por is
  'El coordinador (o ADMIN) que validó el depósito (0129). Lo pone el servidor.';

-- Los depósitos que ya tenían el ticket validado quedan validados (el alquiler pagado sigue pagado).
update public.deposito d
   set validado_en = coalesce(t.revisado_en, t.updated_at),
       validado_por = t.revisado_por
  from public.ticket t
 where t.id = d.ticket_id
   and t.estado = 'VALIDADO'
   and d.validado_en is null;

-- El teléfono no manda la validación: se descarta del push.
update sync.entidad
   set columnas_servidor = columnas_servidor || array['validado_en', 'validado_por']
 where nombre = 'deposito';

-- ----------------------------------------------------------------------------
-- 2. Quién escribe la validación y qué pasa con un depósito validado
-- ----------------------------------------------------------------------------

create function public.tg_deposito_validado_del_servidor()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  -- El servidor (service_role, el editor SQL, una función DEFINER) no pasa por acá. El push corre INVOKER como
  -- `authenticated` (patrón de 0053, 0100 y 0122).
  if current_user in ('authenticated', 'anon')
     and (new.validado_en is not null or new.validado_por is not null) then
    raise exception 'Un depósito lo valida tu coordinador, no se carga desde el teléfono. Registralo sin validar y esperá su confirmación.'
      using errcode = '42501';
  end if;
  return new;
end;
$$;

comment on function public.tg_deposito_validado_del_servidor() is
  'BEFORE INSERT de deposito, solo para authenticated (0129): validado_en y validado_por no los manda el '
  'teléfono (42501). El servidor no pasa por acá.';

revoke all on function public.tg_deposito_validado_del_servidor() from public, anon, authenticated, service_role;

create trigger deposito_validado_del_servidor
  before insert on public.deposito
  for each row execute function public.tg_deposito_validado_del_servidor();

create function public.tg_deposito_validado_no_se_edita()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if old.validado_en is not null
     and (new.colportor_id, new.monto, new.fecha, new.ticket_id, new.destino, new.concepto, new.campania_id,
          new.validado_en, new.validado_por, new.deleted_at)
         is distinct from
         (old.colportor_id, old.monto, old.fecha, old.ticket_id, old.destino, old.concepto, old.campania_id,
          old.validado_en, old.validado_por, old.deleted_at) then
    raise exception 'Un depósito validado no se edita ni se da de baja: una corrección es un movimiento nuevo.'
      using errcode = 'DP001';
  end if;
  return new;
end;
$$;

comment on function public.tg_deposito_validado_no_se_edita() is
  'BEFORE UPDATE de deposito (0129): un depósito validado conserva todos sus datos y no se da de baja (DP001); '
  'solo cambia la auditoría. Vale también para el servidor.';

revoke all on function public.tg_deposito_validado_no_se_edita() from public, anon, authenticated, service_role;

create trigger deposito_validado_no_se_edita
  before update on public.deposito
  for each row execute function public.tg_deposito_validado_no_se_edita();

-- Un vínculo que llega después de que el ticket de su depósito ya fue rechazado. El teléfono puede subir el ticket,
-- el coordinador rechazarlo, y recién entonces llegar el depósito y sus vínculos (otro lote, sin señal). rechazar_ticket
-- solo da de baja los vínculos que ya existen; este trigger hace que el que llega tarde nazca dado de baja, así el
-- cobro queda libre para el depósito corregido (el índice único deposito_cobro_cobro_unico solo mira los vivos) y el
-- teléfono no ve un invalid. Vale para el cliente y para el servidor.
create function public.tg_deposito_cobro_de_ticket_rechazado()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.deleted_at is null
     and exists (select 1
                   from public.deposito d
                   join public.ticket t on t.id = d.ticket_id
                  where d.id = new.deposito_id and t.estado = 'RECHAZADO') then
    new.deleted_at := clock_timestamp();
  end if;
  return new;
end;
$$;

comment on function public.tg_deposito_cobro_de_ticket_rechazado() is
  'BEFORE INSERT de deposito_cobro (0129): si el ticket de su depósito ya está RECHAZADO, el vínculo nace dado de '
  'baja y el cobro queda libre para el depósito corregido.';

revoke all on function public.tg_deposito_cobro_de_ticket_rechazado() from public, anon, authenticated, service_role;

create trigger deposito_cobro_de_ticket_rechazado
  before insert on public.deposito_cobro
  for each row execute function public.tg_deposito_cobro_de_ticket_rechazado();

-- ----------------------------------------------------------------------------
-- 3. Piezas internas
-- ----------------------------------------------------------------------------

-- Acredita en la cuenta del colportor: suma a «Depositado» y, si es de la casa editora, resta de la deuda (puede
-- quedar negativa = a favor). Crea la cuenta si no existe; si estaba dada de baja, la reactiva desde cero en las
-- dos cifras que toca. Interna.
create function public.acreditar_en_la_cuenta(p_usuario_id uuid, p_monto bigint, p_baja_deuda boolean)
returns void
language sql
volatile
security definer
set search_path = ''
as $$
  insert into public.cuenta_colportor as cu (usuario_id, dinero_depositado, deuda_total)
  values (p_usuario_id, p_monto, case when p_baja_deuda then -p_monto else 0 end)
  on conflict (usuario_id) do update
    set dinero_depositado = case when cu.deleted_at is null then cu.dinero_depositado else 0 end
                            + excluded.dinero_depositado,
        deuda_total = case when cu.deleted_at is null then cu.deuda_total else 0 end + excluded.deuda_total,
        deleted_at = null,
        actualizado_en = now();
$$;

comment on function public.acreditar_en_la_cuenta(uuid, bigint, boolean) is
  'Suma p_monto a cuenta_colportor.dinero_depositado y, con p_baja_deuda, lo resta de deuda_total (crea o reactiva '
  'la cuenta). La llaman validar_ticket() y confirmar_retiro() (0129). Interna.';

revoke all on function public.acreditar_en_la_cuenta(uuid, bigint, boolean)
  from public, anon, authenticated, service_role;

-- Lo que va a pasar al validar: el monto que se acredita, contra qué cobros se compara y cómo queda la cuenta del
-- concepto. Se le pasa EL ticket o EL depósito (uno solo). No comprueba permisos: la llaman los RPC de abajo, que
-- sí. Interna.
create function public.validacion_calculada(p_ticket_id uuid, p_deposito_id uuid)
returns table (ticket_id uuid, deposito_id uuid, colportor_id uuid, tipo text, concepto text, destino text,
               campania_id uuid, monto_ticket bigint, monto bigint, cobros_vinculados bigint, diferencia bigint,
               deuda_antes bigint, deuda_despues bigint, supera_deuda bigint, a_favor_despues bigint)
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
  v_pendiente boolean;
  v_antes     bigint;
  v_despues   bigint;
  v_alquiler  bigint;
  v_pagado    bigint;
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
    v_pendiente := v_d.validado_en is null and v_d.deleted_at is null;
  end if;

  if v_t.id is null or v_t.tipo = 'DEPOSITO' then
    -- Un depósito (con ticket, o un retiro sin ticket): el monto es el del depósito.
    v_monto := v_d.monto;
    v_concepto := v_d.concepto;
    if v_d.id is not null then
      select coalesce(sum(c.monto), 0)::bigint into v_cobros
        from public.deposito_cobro dc
        join public.cobranza c on c.id = dc.cobranza_id
       where dc.deposito_id = v_d.id and dc.deleted_at is null
         and c.deleted_at is null and c.anulado_at is null;
    end if;
  elsif v_t.tipo = 'COBRO_TARJETA' then
    -- El cobro con tarjeta: el monto es el del ticket, y es plata de la casa editora (S66).
    v_monto := v_t.monto;
    v_concepto := 'CASA_EDITORA';
    select coalesce(sum(c.monto), 0)::bigint into v_cobros
      from public.cobranza c
     where c.ticket_id = v_t.id and c.deleted_at is null and c.anulado_at is null;
  end if;

  if v_monto is not null and v_pendiente then
    if v_concepto = 'CASA_EDITORA' then
      select cu.deuda_total into v_antes
        from public.cuenta_colportor cu
       where cu.usuario_id = v_colportor and cu.deleted_at is null;
      v_antes := coalesce(v_antes, 0);
      v_despues := v_antes - v_monto;
    elsif v_concepto = 'ALQUILER' then
      select ca.alquiler_monto into v_alquiler from public.campania ca where ca.id = v_d.campania_id;
      if v_alquiler is not null then
        select coalesce(sum(d.monto), 0)::bigint into v_pagado
          from public.deposito d
         where d.colportor_id = v_colportor and d.campania_id = v_d.campania_id
           and d.concepto = 'ALQUILER' and d.deleted_at is null and d.validado_en is not null;
        v_antes := greatest(v_alquiler - v_pagado, 0);
        v_despues := v_alquiler - v_pagado - v_monto;
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
           v_monto - v_cobros,
           v_antes,
           case when v_despues is null then null else greatest(v_despues, 0) end,
           case when v_antes is null then null else greatest(v_monto - greatest(v_antes, 0), 0) end,
           case when v_despues is null then null else greatest(-v_despues, 0) end;
end;
$$;

comment on function public.validacion_calculada(uuid, uuid) is
  'Qué pasa al validar un ticket (p_ticket_id) o un retiro sin ticket (p_deposito_id): monto que se acredita, '
  'cobros vinculados y diferencia, y la deuda del concepto antes y después (casa editora: deuda_total; alquiler: '
  'el de la campaña del depósito). Ya validado, las cifras de la deuda son null. Sin permisos: interna (0129).';

revoke all on function public.validacion_calculada(uuid, uuid) from public, anon, authenticated, service_role;

-- El ticket de p_ticket_id con el permiso comprobado: ADMIN, o COORDINADOR de la campaña a la que pertenece por su
-- fecha; nunca el propio. Con p_escribir bloquea la fila. TV001 si no existe o no es de sus campañas (el mismo
-- error: no se averigua qué tickets hay). Interna.
create function public.ticket_para_validar(p_ticket_id uuid, p_escribir boolean)
returns public.ticket
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_t public.ticket;
begin
  if auth.uid() is null or not (public.tiene_rol('ADMIN') or public.tiene_rol('COORDINADOR')) then
    raise exception 'Solo el coordinador de la campaña o un administrador puede validar tickets. Entrá con la cuenta del coordinador de esta campaña.'
      using errcode = 'insufficient_privilege';
  end if;

  select * into v_t from public.ticket t where t.id = p_ticket_id and t.deleted_at is null;
  if not found
     or not (public.tiene_rol('ADMIN')
             or exists (select 1
                          from public.campania ca
                         where ca.id = public.campania_del_ticket(v_t.usuario_id, coalesce(v_t.fecha, v_t.subido_en))
                           and ca.coordinador_id = auth.uid())) then
    raise exception 'El ticket no existe o no es de un colportor de tus campañas. Recargá la lista de tickets.'
      using errcode = 'TV001';
  end if;
  if v_t.usuario_id = auth.uid() then
    raise exception 'No podés validar ni rechazar tu propio ticket. Pedile a otro coordinador o a un administrador que lo haga.'
      using errcode = 'insufficient_privilege';
  end if;

  if p_escribir then
    select * into v_t from public.ticket t where t.id = p_ticket_id for update;
  end if;
  return v_t;
end;
$$;

comment on function public.ticket_para_validar(uuid, boolean) is
  'El ticket con el permiso comprobado (0129): ADMIN o el coordinador de la campaña del ticket, nunca el propio. '
  'Con p_escribir bloquea la fila. 42501 sin permiso; TV001 si no existe o no es de sus campañas. Interna.';

revoke all on function public.ticket_para_validar(uuid, boolean) from public, anon, authenticated, service_role;

-- Lo mismo para un retiro sin ticket: la campaña es la del depósito, o la de su fecha si no la dice.
create function public.retiro_para_confirmar(p_deposito_id uuid, p_escribir boolean)
returns public.deposito
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_d public.deposito;
begin
  if auth.uid() is null or not (public.tiene_rol('ADMIN') or public.tiene_rol('COORDINADOR')) then
    raise exception 'Solo el coordinador de la campaña o un administrador puede confirmar un retiro. Entrá con la cuenta del coordinador de esta campaña.'
      using errcode = 'insufficient_privilege';
  end if;

  select * into v_d from public.deposito d where d.id = p_deposito_id and d.deleted_at is null;
  if not found
     or not (public.tiene_rol('ADMIN')
             or exists (select 1
                          from public.campania ca
                         where ca.id = coalesce(v_d.campania_id, public.campania_del_ticket(v_d.colportor_id, v_d.fecha))
                           and ca.coordinador_id = auth.uid())) then
    raise exception 'El retiro no existe o no es de un colportor de tus campañas. Recargá la lista.'
      using errcode = 'DP002';
  end if;
  if v_d.colportor_id = auth.uid() then
    raise exception 'No podés confirmar tu propio retiro. Pedile a otro coordinador o a un administrador que lo haga.'
      using errcode = 'insufficient_privilege';
  end if;
  if v_d.destino <> 'RETIRO_COORDINADOR' or v_d.ticket_id is not null then
    raise exception 'Este depósito tiene ticket: se valida desde su ticket, en la lista de tickets.'
      using errcode = 'DP003';
  end if;

  if p_escribir then
    select * into v_d from public.deposito d where d.id = p_deposito_id for update;
  end if;
  return v_d;
end;
$$;

comment on function public.retiro_para_confirmar(uuid, boolean) is
  'El retiro sin ticket con el permiso comprobado (0129): ADMIN o el coordinador de la campaña del depósito, nunca '
  'el propio. 42501 sin permiso; DP002 si no existe o no es de sus campañas; DP003 si no es un retiro sin ticket. '
  'Interna.';

revoke all on function public.retiro_para_confirmar(uuid, boolean) from public, anon, authenticated, service_role;

-- ----------------------------------------------------------------------------
-- 4. Lo que lee el panel antes de confirmar
-- ----------------------------------------------------------------------------

create function public.validacion_de_ticket(p_ticket_id uuid)
returns table (ticket_id uuid, deposito_id uuid, colportor_id uuid, tipo text, concepto text, destino text,
               campania_id uuid, monto_ticket bigint, monto bigint, cobros_vinculados bigint, diferencia bigint,
               deuda_antes bigint, deuda_despues bigint, supera_deuda bigint, a_favor_despues bigint)
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
  'Vista 29 (0129, backend-supabase#110): lo que pasa si el coordinador valida este ticket: monto que se '
  'acredita, concepto, cobros vinculados y diferencia, y la deuda del concepto antes y después (supera_deuda y '
  'a_favor_despues para el aviso «Pago de más»). No cambia nada. Errores: 42501 sin permiso o ticket propio; '
  'TV001 ticket inexistente o de otra campaña.';

revoke all on function public.validacion_de_ticket(uuid) from public, anon, authenticated, service_role;
grant execute on function public.validacion_de_ticket(uuid) to authenticated;

create function public.validacion_de_retiro(p_deposito_id uuid)
returns table (ticket_id uuid, deposito_id uuid, colportor_id uuid, tipo text, concepto text, destino text,
               campania_id uuid, monto_ticket bigint, monto bigint, cobros_vinculados bigint, diferencia bigint,
               deuda_antes bigint, deuda_despues bigint, supera_deuda bigint, a_favor_despues bigint)
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
  'Lo que pasa si el coordinador confirma este retiro sin ticket (0129): lo mismo que validacion_de_ticket. No '
  'cambia nada. Errores: 42501 sin permiso o retiro propio; DP002 inexistente o de otra campaña; DP003 si tiene '
  'ticket.';

revoke all on function public.validacion_de_retiro(uuid) from public, anon, authenticated, service_role;
grant execute on function public.validacion_de_retiro(uuid) to authenticated;

-- ----------------------------------------------------------------------------
-- 5. Lo que decide el coordinador
-- ----------------------------------------------------------------------------

create function public.validar_ticket(p_ticket_id uuid)
returns table (ticket_id uuid, deposito_id uuid, estado text, validado_en timestamptz, monto bigint,
               cobros_vinculados bigint, diferencia bigint, deuda_antes bigint, deuda_despues bigint,
               supera_deuda bigint, a_favor_despues bigint, ya_estaba boolean)
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
                        v_c.diferencia, v_c.deuda_antes, v_c.deuda_despues, v_c.supera_deuda,
                        v_c.a_favor_despues, true;
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
                       'deuda_antes', v_c.deuda_antes,
                       'deuda_despues', v_c.deuda_despues));

  return query select v_t.id, v_c.deposito_id, 'VALIDADO'::text, v_ahora, v_c.monto, v_c.cobros_vinculados,
                      v_c.diferencia, v_c.deuda_antes, v_c.deuda_despues, v_c.supera_deuda,
                      v_c.a_favor_despues, false;
end;
$$;

comment on function public.validar_ticket(uuid) is
  'Vista 29, HU-COB-008 (0129, backend-supabase#110): el coordinador valida el ticket. Un ticket de depósito '
  'valida su depósito y lo acredita (Depositado sube; la deuda del concepto baja, y lo de más queda a favor); '
  'uno de tarjeta acredita su monto como casa editora; uno de otro tipo solo queda validado. diferencia es el '
  'aviso de «Pago de más», no frena. ya_estaba = true si YO ya lo validé. Errores: 42501; TV001; TV002 (ya '
  'resuelto); TV004 (sin monto); TV005 (el depósito no llegó).';

revoke all on function public.validar_ticket(uuid) from public, anon, authenticated, service_role;
grant execute on function public.validar_ticket(uuid) to authenticated;

create function public.confirmar_retiro(p_deposito_id uuid)
returns table (ticket_id uuid, deposito_id uuid, estado text, validado_en timestamptz, monto bigint,
               cobros_vinculados bigint, diferencia bigint, deuda_antes bigint, deuda_despues bigint,
               supera_deuda bigint, a_favor_despues bigint, ya_estaba boolean)
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

  if v_d.validado_en is not null then
    if v_d.validado_por is not distinct from auth.uid() then
      return query select null::uuid, v_d.id, 'VALIDADO'::text, v_d.validado_en, v_c.monto, v_c.cobros_vinculados,
                          v_c.diferencia, v_c.deuda_antes, v_c.deuda_despues, v_c.supera_deuda,
                          v_c.a_favor_despues, true;
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
                       'deuda_antes', v_c.deuda_antes,
                       'deuda_despues', v_c.deuda_despues));

  return query select null::uuid, v_d.id, 'VALIDADO'::text, v_ahora, v_c.monto, v_c.cobros_vinculados,
                      v_c.diferencia, v_c.deuda_antes, v_c.deuda_despues, v_c.supera_deuda,
                      v_c.a_favor_despues, false;
end;
$$;

comment on function public.confirmar_retiro(uuid) is
  'HU-CTA-004 / S70 (0129, backend-supabase#110): el coordinador confirma que retiró el efectivo de un depósito '
  'RETIRO_COORDINADOR (sin ticket): se acredita igual que un ticket validado. ya_estaba = true si YO ya lo '
  'confirmé. Errores: 42501; DP002 (inexistente o de otra campaña); DP003 (tiene ticket); DP004 (lo confirmó '
  'otra persona).';

revoke all on function public.confirmar_retiro(uuid) from public, anon, authenticated, service_role;
grant execute on function public.confirmar_retiro(uuid) to authenticated;

create function public.rechazar_ticket(p_ticket_id uuid, p_motivo text)
returns table (ticket_id uuid, estado text, revisado_en timestamptz, cobros_liberados integer, ya_estaba boolean)
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_t       public.ticket;
  v_motivo  text;
  v_ahora   timestamptz := clock_timestamp();
  v_liberados integer := 0;
begin
  v_t := public.ticket_para_validar(p_ticket_id, true);
  v_motivo := regexp_replace(coalesce(p_motivo, ''), '^\s+|\s+$', '', 'g');

  -- Un reintento de quien ya lo rechazó, con el mismo motivo, no cambia nada.
  if v_t.estado = 'RECHAZADO' and v_t.revisado_por = auth.uid() and v_t.motivo_rechazo = v_motivo then
    return query select v_t.id, v_t.estado, v_t.revisado_en, 0, true;
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

  -- Los cobros que el depósito rechazado incluía vuelven a estar en mano: el colportor los incluye en el depósito
  -- nuevo que sube con el ticket corregido. Los vínculos que lleguen después de este rechazo nacen dados de baja
  -- (trigger deposito_cobro_de_ticket_rechazado).
  if v_t.tipo = 'DEPOSITO' then
    update public.deposito_cobro dc
       set deleted_at = v_ahora
     where dc.deleted_at is null
       and dc.deposito_id in (select d.id from public.deposito d
                               where d.ticket_id = v_t.id and d.deleted_at is null);
    get diagnostics v_liberados = row_count;
  end if;

  perform auditoria.registrar(
    'ticket_rechazado', 'ticket', v_t.id, v_t.usuario_id,
    jsonb_build_object('tipo', v_t.tipo, 'cobros_liberados', v_liberados));

  return query select v_t.id, 'RECHAZADO'::text, v_ahora, v_liberados, false;
end;
$$;

comment on function public.rechazar_ticket(uuid, text) is
  'Vista 29, HU-COB-008 (0129, backend-supabase#110): el coordinador rechaza el ticket con un motivo (no en '
  'blanco, hasta 500, recortado). La deuda no cambia. Si era de un depósito, sus cobros vuelven a estar en mano '
  '(baja de los vínculos). ya_estaba = true si YO ya lo rechacé con el mismo motivo. Errores: 42501; TV001; TV002; '
  'TV003 (motivo). El motivo escrito no se copia a audit_log.';

revoke all on function public.rechazar_ticket(uuid, text) from public, anon, authenticated, service_role;
grant execute on function public.rechazar_ticket(uuid, text) to authenticated;

-- ----------------------------------------------------------------------------
-- 6. El alquiler pagado es lo validado (cuentas_de_campania, 0114 y 0119)
-- ----------------------------------------------------------------------------

-- Igual que la de 0119 salvo la subconsulta `alq`: lo pagado y el último pago salen de `validado_en`, no del
-- estado del ticket; por validar es lo que no se validó y no se rechazó (sin ticket, o con el ticket pendiente).
-- La firma no cambia: los privilegios se conservan.
create or replace function public.cuentas_de_campania(p_campania_id uuid)
returns table (colportor_id uuid, nombre text, apellido text, de_baja boolean,
               ciudad_id uuid, ciudad_nombre text, departamento text,
               deuda_total bigint, dinero_depositado bigint, dinero_en_mano bigint,
               dinero_por_cobrar bigint,
               ultimo_deposito_fecha timestamptz, ultimo_deposito_monto bigint,
               alquiler_monto bigint, alquiler_pagado bigint, alquiler_por_validar bigint,
               alquiler_debe bigint, alquiler_ultimo_pago_fecha timestamptz)
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_motivo    text;
  v_campania  public.campania;
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

  select * into v_campania from public.campania c where c.id = p_campania_id;

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
           case when vg.vigente then coalesce(cu.dinero_en_mano, 0) end,
           case when vg.vigente then coalesce(cu.dinero_por_cobrar, 0) end,
           ult.fecha,
           ult.monto,
           v_campania.alquiler_monto,
           alq.pagado,
           alq.por_validar,
           case when v_campania.alquiler_monto is null then null
                else greatest(v_campania.alquiler_monto - alq.pagado, 0) end,
           alq.ultimo_pago
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
      cross join lateral (
        select coalesce(sum(d.monto) filter (where d.validado_en is not null), 0)::bigint as pagado,
               coalesce(sum(d.monto) filter (where d.validado_en is null and (t.id is null or t.estado = 'PENDIENTE')), 0)::bigint
                 as por_validar,
               max(d.fecha) filter (where d.validado_en is not null) as ultimo_pago
          from public.deposito d
          left join public.ticket t on t.id = d.ticket_id
         where d.colportor_id = i.usuario_id and d.deleted_at is null
           and d.concepto = 'ALQUILER' and d.campania_id = p_campania_id
      ) alq
     where i.campania_id = p_campania_id
     order by ciu.nombre nulls last, usr.apellido, usr.nombre, i.usuario_id;
end;
$$;


comment on function public.cuentas_de_campania(uuid) is
  'Vista 36, HU-CTA-005 y HU-CTA-007 (0114, backend-supabase#111; 0129, #110): una fila por colportor de la '
  'campaña con su ciudad (la de su zona actual), las cuatro cifras de su cuenta (cuenta_colportor, 0 si no '
  'tiene fila), el último depósito de casa editora y el alquiler de ESTA campaña aparte: monto, pagado '
  '(depósitos validados), por validar, lo que debe y la fecha del último pago. El saldo a favor es pagado menos '
  'monto cuando es positivo. Ni clientes ni personas visitadas. Errores: 42501 sin permiso; CZ001 campaña '
  'inexistente. Una campaña terminada se lee.';
