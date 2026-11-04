-- ============================================================================
-- 0165 · El cobro con tarjeta validado paga los pedidos como un depósito
--        (backend-supabase#243, casilla «Tarjeta ped.»; decisión de Cristian del 04/11, «Sí, como un depósito», en
--        backend-supabase#235; seguimiento de la 0164)
--
-- ## El caso
--
-- Ana cobra $ 30.000 con tarjeta, el coordinador valida el ticket (`COBRO_TARJETA`) y ella mira cada pedido en «Deuda con
-- la casa editora». La 0164 solo hacía pagar pedidos a los depósitos validados: la tarjeta bajaba `deuda_total` pero
-- ningún pedido, y la pantalla tenía que aclarar que la suma de saldos no coincidía con el total. Cristian dijo que
-- la tarjeta paga igual que un depósito.
--
-- ## Qué cambia
--
-- `mi_deuda_con_la_casa_editora()` (misma firma, `create or replace`): lo pagado que se reparte entre los pedidos,
-- del más viejo al más nuevo, es la suma de los depósitos validados a la casa editora MÁS la de los tickets
-- `COBRO_TARJETA` validados de la colportora (`ticket.monto`, el mismo monto que `validar_ticket` acredita en la
-- cuenta). Un ticket pendiente, rechazado o dado de baja no paga.
--
-- Una clave nueva en la respuesta: `tarjetas_validadas` (bigint), lo que sumaron los tickets de tarjeta validados.
-- `depositos_validados` sigue siendo solo lo de los depósitos: ningún cliente que ya la leía cambia de significado.
-- Lo repartido entre los pedidos es la suma de las dos.
--
-- ## Lo que NO hace
--
--   · No cambia `cuenta_colportor` ni la validación: la tarjeta ya bajaba la deuda (0129). Es solo la lectura.
--   · Los cobros con tarjeta sin ticket validado (todavía pendientes) no cuentan, igual que un depósito por validar.
--
-- ## Los datos
--
-- Una función reemplazada: ningún insert, update ni delete, ningún cambio de esquema. Forward-only.
--
-- ## Para otros repos
--
--   · front-colportores-mobile#441: la respuesta suma la clave `tarjetas_validadas`; el aviso «algo más movió tu
--     deuda» ya no debe esperarse por una tarjeta.
--   · docs-organizacion: la fila del RPC en el contrato (casilla del cuerpo del PR).
--
-- Forward-only: esta migración no se edita una vez aplicada.
-- ============================================================================

create or replace function public.mi_deuda_con_la_casa_editora()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_uid       uuid := auth.uid();
  v_deuda     bigint;
  v_depositos bigint;
  v_tarjetas  bigint;
  v_pagado    bigint;
  v_suma      bigint;
  v_pedidos   jsonb;
begin
  if v_uid is null then
    raise exception 'Iniciá sesión para ver tu deuda con la casa editora.' using errcode = '42501';
  end if;

  -- La deuda real: la de la cuenta (una cuenta dada de baja no debe nada).
  select cu.deuda_total into v_deuda
    from public.cuenta_colportor cu
   where cu.usuario_id = v_uid and cu.deleted_at is null;
  v_deuda := coalesce(v_deuda, 0);

  -- Lo que pagaron los depósitos validados a la casa editora.
  select coalesce(sum(d.monto), 0)::bigint into v_depositos
    from public.deposito d
   where d.colportor_id = v_uid and d.deleted_at is null
     and d.concepto = 'CASA_EDITORA' and d.validado_en is not null;

  -- Y los cobros con tarjeta validados (0165): pagan como un depósito.
  select coalesce(sum(t.monto), 0)::bigint into v_tarjetas
    from public.ticket t
   where t.usuario_id = v_uid and t.deleted_at is null
     and t.tipo = 'COBRO_TARJETA' and t.estado = 'VALIDADO';

  v_pagado := v_depositos + v_tarjetas;

  -- Los pedidos que cargaron la deuda, del más viejo al más nuevo, con lo que cubrió lo pagado.
  with pedidos as (
    select p.id, p.numero, p.fecha_pedido, p.estado,
           coalesce(p.monto_autorizado, p.monto_total) as monto,
           coalesce(sum(coalesce(p.monto_autorizado, p.monto_total))
                      over (order by p.fecha_pedido, p.numero, p.id
                            rows between unbounded preceding and 1 preceding), 0) as antes
      from public.pedido_casa_editora p
     where p.colportor_id = v_uid and p.deleted_at is null
       and p.estado in ('AUTORIZADO', 'DESPACHADO', 'RECIBIDO')
  ),
  repartido as (
    select q.*,
           least(q.monto, greatest(v_pagado - q.antes, 0)) as pagado
      from pedidos q
  ),
  con_saldo as (
    select r.*, r.monto - r.pagado as saldo
      from repartido r
  )
  select coalesce(sum(s.saldo), 0)::bigint,
         coalesce(jsonb_agg(
           jsonb_build_object(
             'pedido_id', s.id,
             'numero', s.numero,
             'fecha_pedido', s.fecha_pedido,
             'estado', s.estado,
             'monto', s.monto,
             'pagado', s.pagado,
             'saldo', s.saldo,
             'lineas', coalesce((
               select jsonb_agg(jsonb_build_object('producto_id', i.producto_id,
                                                   'nombre', pr.nombre,
                                                   'cantidad', coalesce(i.cantidad_autorizada, i.cantidad))
                                order by pr.nombre, i.producto_id)
                 from public.pedido_item i
                 join public.producto pr on pr.id = i.producto_id
                where i.pedido_id = s.id and i.deleted_at is null
                  and coalesce(i.cantidad_autorizada, i.cantidad) > 0
             ), '[]'::jsonb))
           order by s.fecha_pedido, s.numero, s.id) filter (where s.saldo > 0), '[]'::jsonb)
    into v_suma, v_pedidos
    from con_saldo s;

  return jsonb_build_object(
    'deuda_total', v_deuda,
    'suma_de_saldos', v_suma,
    'depositos_validados', v_depositos,
    'tarjetas_validadas', v_tarjetas,
    'pedidos', v_pedidos);
end;
$$;

comment on function public.mi_deuda_con_la_casa_editora() is
  'Vista 33B, HU-CTA-002 (0164, backend-supabase#235; 0165, #243): la deuda de la colportora autenticada con la casa '
  'editora. Devuelve jsonb: deuda_total (la real, cuenta_colportor), suma_de_saldos, depositos_validados, '
  'tarjetas_validadas y pedidos (solo los de saldo > 0, el más viejo primero, con monto, pagado, saldo y lineas). '
  'Los depósitos validados a la casa editora y los cobros con tarjeta validados pagan primero el pedido más viejo '
  '(decisiones «Pagado ped.», 03/11, y «Tarjeta ped.», 04/11); los pedidos son los AUTORIZADO, DESPACHADO y RECIBIDO '
  'con monto_autorizado (o monto_total). Si deuda_total no coincide con suma_de_saldos, algo más la movió '
  '(transferencia, alquiler). Solo lo suyo (auth.uid()); 42501 sin sesión.';
