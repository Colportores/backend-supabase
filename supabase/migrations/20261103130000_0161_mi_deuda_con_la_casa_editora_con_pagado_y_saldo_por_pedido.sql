-- ============================================================================
-- 0161 · RPC «mi deuda con la casa editora»: el total y cada pedido con su pagado y su saldo
--        (backend-supabase#235, BACK-HU-CTA-002; desbloquea front-colportores-mobile#441, vista 33B;
--        decisiones de Cristian del 03/11 «Pagado ped.» y «Leer deuda», front-colportores-mobile#441)
--
-- ## El caso
--
-- Ana abre «Deuda con la casa editora» desde Mi Cuenta (vista 33B). El canvas 33B-01 le muestra arriba el TOTAL y
-- debajo los «pedidos con saldo»: «Pedido del 02/10 · Salud y Hogar × 10 · Nuestros Hijos × 6», con lo que valía y lo que ya
-- pagó. Hasta hoy la base no tenía cómo decírselo: la cuenta (`cuenta_colportor`) lleva UN solo número corrido
-- (`deuda_total`), el depósito no nombra a qué pedido paga (desde el 28/10, backend-supabase#193) y la cuenta no baja
-- por el sync. Cristian decidió dos cosas:
--
--   · «Pagado ped.»: los depósitos validados pagan primero el pedido más viejo; de ahí salen el «pagado» y el «saldo» de
--     cada pedido.
--   · «Leer deuda»: un RPC propio devuelve el total y cada pedido; el teléfono guarda la última respuesta con su hora y
--     la muestra sin conexión (eso es de front-colportores-mobile#441). La cuenta se hace en UN solo lugar: el servidor.
--
-- ## Lo que suma
--
--   mi_deuda_con_la_casa_editora()  -> jsonb   (SECURITY DEFINER, STABLE, EXECUTE solo para `authenticated`)
--
--   {
--     "deuda_total":         bigint,   -- la deuda REAL: `cuenta_colportor.deuda_total` (0 sin cuenta o con la cuenta de baja).
--                                      --   Puede ser negativa (queda a favor: se pagó de más, lo trasladó el alquiler o una
--                                      --   transferencia).
--     "suma_de_saldos":      bigint,   -- la suma de los saldos de los pedidos (todos, también los que no se listan: es
--                                      --   la de los que tienen saldo, los demás valen 0). Si no coincide con
--                                      --   `deuda_total`, la pantalla lo aclara: algo movió la deuda sin ser un pedido o un
--                                      --   depósito (transferencia de stock, alquiler pagado de más, ajustes).
--     "depositos_validados": bigint,   -- lo que sumaron los depósitos validados a la casa editora (con lo que se repartió).
--     "pedidos": [                     -- solo los pedidos con saldo > 0, el más viejo primero
--       { "pedido_id": uuid, "numero": bigint, "fecha_pedido": timestamptz, "estado": text,
--         "monto": bigint,             -- lo que vale para la deuda: `monto_autorizado`, o `monto_total` si no se redujo
--         "pagado": bigint, "saldo": bigint,
--         "lineas": [ { "producto_id": uuid, "nombre": text, "cantidad": integer } ] }  -- por nombre
--     ]
--   }
--
-- ## La cuenta
--
--   · Pedidos que cuentan: los de la colportora (vivos) que ya cargaron la deuda: AUTORIZADO, DESPACHADO y RECIBIDO
--     (la deuda entra al autorizar, `autorizar_pedido`, 0112). No cuentan los por autorizar, los borradores, los rechazados
--     ni los cancelados. El monto de cada uno es `monto_autorizado` y, si no se redujo, `monto_total`.
--   · Lo pagado: la suma de los depósitos vivos con concepto CASA_EDITORA y `validado_en` (los por validar, los retiros
--     rechazados y los de ALQUILER no pagan pedidos). Es de TODA la colportora, no de una campaña: la deuda es una por
--     colportora.
--   · El reparto: los pedidos se ordenan por `fecha_pedido`, luego `numero` (el más viejo primero) y lo pagado los va
--     cubriendo de a uno: `pagado` = lo que cabe del pedido en lo que sobra, `saldo` = `monto` menos `pagado`. Lo que
--     sobra después del último pedido no se muestra (queda en `depositos_validados`).
--   · Los pedidos sin saldo no se listan (HU-CTA-002: «lista de pedidos con saldo > 0»), pero cuentan para el reparto.
--   · Las líneas de cada pedido son las vivas, con `cantidad_autorizada` si el coordinador la redujo (y se omiten las
--     que quedaron en cero): son los libros que entran en la deuda.
--
-- ## Quién lo ve
--
-- Cada usuario ve SOLO lo suyo: la función no recibe ningún id, usa `auth.uid()`; un administrador o un coordinador
-- que la llaman ven su propia cuenta (vacía, si no piden libros). Sin sesión: `42501` («Iniciá sesión…»); `anon` y PUBLIC no
-- pueden ejecutarla. No devuelve clientes, cobros ni personas: solo montos, pedidos y los nombres de los productos.
--
-- ## Lo que NO hace (y por qué)
--
--   · No hace pagar pedidos a los cobros con tarjeta validados (ticket `COBRO_TARJETA`, S66), que también bajan
--     `deuda_total` pero no son depósitos: la decisión de Cristian dice «los depósitos validados». Aparece en
--     `deuda_total` y, si no coincide con la suma de saldos, la pantalla lo aclara. Queda como pendiente de decisión.
--   · No ajusta un pedido recibido incompleto (HU-STK-002) ni resta lo cancelado después de autorizar: la deuda real
--     la manda `cuenta_colportor`, que tampoco lo hace todavía.
--   · No baja por el sync ni cambia `cuenta_colportor`: es una lectura del momento (el teléfono guarda la última).
--
-- ## Los datos
--
-- Una función nueva: ningún insert, update ni delete, ningún cambio de esquema. Forward-only.
--
-- ## Para otros repos
--
--   · front-colportores-mobile#441: `supabase.rpc('mi_deuda_con_la_casa_editora')` devuelve el jsonb de arriba (sin
--     parámetros). Guardar la respuesta con la hora del teléfono; el error 42501 es «sin sesión».
--   · docs-organizacion: la fila del RPC en el contrato (casilla del cuerpo del PR) y el esquema de datos.
--
-- Forward-only: esta migración no se edita una vez aplicada.
-- ============================================================================

create function public.mi_deuda_con_la_casa_editora()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_uid       uuid := auth.uid();
  v_deuda     bigint;
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
  select coalesce(sum(d.monto), 0)::bigint into v_pagado
    from public.deposito d
   where d.colportor_id = v_uid and d.deleted_at is null
     and d.concepto = 'CASA_EDITORA' and d.validado_en is not null;

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
    'depositos_validados', v_pagado,
    'pedidos', v_pedidos);
end;
$$;

comment on function public.mi_deuda_con_la_casa_editora() is
  'Vista 33B, HU-CTA-002 (0161, backend-supabase#235): la deuda de la colportora autenticada con la casa editora. '
  'Devuelve jsonb: deuda_total (la real, cuenta_colportor), suma_de_saldos, depositos_validados y pedidos (solo '
  'los de saldo > 0, el más viejo primero, con monto, pagado, saldo y lineas). Los depósitos validados a la casa '
  'editora pagan primero el pedido más viejo (decisión «Pagado ped.», 03/11); los pedidos son los AUTORIZADO, '
  'DESPACHADO y RECIBIDO con monto_autorizado (o monto_total). Si deuda_total no coincide con suma_de_saldos, algo '
  'más la movió (transferencia, alquiler, tarjeta). Solo lo suyo (auth.uid()); 42501 sin sesión.';

revoke all on function public.mi_deuda_con_la_casa_editora()
  from public, anon, authenticated, service_role;
grant execute on function public.mi_deuda_con_la_casa_editora() to authenticated;
