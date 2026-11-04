-- ============================================================================
-- 0168 · «Mi deuda con la casa editora» dice cuánto debía hace 7 días
--        (backend-supabase#243, casilla «Variación semanal»; decisión de Cristian del 04/11, «Del servidor, todo
--        cuenta», en front-colportores-mobile#441; seguimiento de la 0164/0165)
--
-- ## El caso
--
-- Ana mira «Deuda con la casa editora» en Mi Cuenta y el canvas 33A·01 pone «▼ $ 2.100 contra la semana pasada». Para
-- escribir esa línea el teléfono necesita la deuda de hace 7 días. Cristian dijo que la calcula el servidor y que cuenta
-- TODO lo que la movió (pedidos, depósitos, tarjeta, alquiler, transferencias): la deuda de hace 7 días es la que figuraba
-- en la cuenta ese día, sea cual sea la causa del cambio.
--
-- ## Qué suma
--
--   1. `cuenta_deuda_historial`: una fila por cada cambio de la deuda real de una colportora (`cuenta_colportor.deuda_total`;
--      0 mientras la cuenta está dada de baja, como la lee `mi_deuda_con_la_casa_editora`), con la hora en que cambió.
--      La llena un trigger de `cuenta_colportor` (`tg_cuenta_colportor_historial_deuda`): cualquier causa deja su fila,
--      porque lo único que mira es el número. Solo la lee la propia persona o un ADMIN; no escribe nadie con JWT; no
--      viaja por el sync.
--   2. La migración deja una primera fila por cada cuenta que ya existe, con su deuda de hoy: no hay datos de antes de
--      esta fecha y no se inventan. Hasta que pasen 7 días, `deuda_hace_7_dias` vale `null` para esas cuentas (y para las
--      cuentas nuevas, hasta cumplir 7 días); después, el valor de aquel momento (si la deuda no cambió desde la primera
--      fila, es la misma de hoy).
--   3. `mi_deuda_con_la_casa_editora()` (misma firma, `create or replace`): una clave nueva, `deuda_hace_7_dias`
--      (bigint o `null`): la última deuda registrada con hora igual o anterior a hace 7 días exactos (7 × 24 h). `null` si
--      no hay un registro de entonces. Es la misma cifra que `deuda_total` pero de aquel momento (puede ser negativa: a
--      favor). La variación que muestra el teléfono es `deuda_total − deuda_hace_7_dias`.
--
-- ## Lo que NO hace
--
--   · No reconstruye el pasado: sin registro de entonces, `null` (el teléfono no muestra la línea).
--   · No borra historia: el historial crece con cada cambio de la deuda (una fila por cambio, decenas por semana a lo
--     sumo por persona). Si algún día pesa, se poda dejando la última fila anterior a los 7 días.
--
-- ## Los datos
--
-- Una tabla nueva, un trigger y una función reemplazada. La primera fila de cada cuenta es lo único que se inserta. Ninguna
-- cuenta cambia. Lo prueba supabase/tests_migracion/0168_ok. Forward-only.
--
-- ## Para otros repos
--
--   · front-colportores-mobile#441: `deuda_hace_7_dias` (bigint o null) en la respuesta de
--     `supabase.rpc('mi_deuda_con_la_casa_editora')`; la línea «▼ / ▲ $ X contra la semana pasada» sale de
--     `deuda_total − deuda_hace_7_dias` y se oculta si es `null`.
--   · docs-organizacion: la fila del RPC en el contrato y `esquema-datos.md` (`cuenta_deuda_historial`), casilla del cuerpo
--     del PR.
--
-- Forward-only: esta migración no se edita una vez aplicada.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. El historial de la deuda
-- ----------------------------------------------------------------------------

create table public.cuenta_deuda_historial (
  id            uuid primary key default public.uuid_generate_v7(),
  usuario_id    uuid not null references public.usuario(id) on delete cascade,
  deuda         bigint not null,
  desde         timestamptz not null default clock_timestamp(),
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  created_by    uuid default auth.uid() references public.usuario(id) on delete set null,
  deleted_at    timestamptz,
  sync_version  bigint not null default 0,
  xmin_w        xid8 not null default pg_current_xact_id()
);

create index cuenta_deuda_historial_usuario_idx on public.cuenta_deuda_historial (usuario_id, desde desc);

comment on table public.cuenta_deuda_historial is
  'La deuda con la casa editora de cada colportora a lo largo del tiempo (0168, backend-supabase#243, «Variación '
  'semanal»): una fila por cada cambio de cuenta_colportor.deuda_total (0 mientras la cuenta está de baja), con la hora '
  'en que cambió. La llena el trigger de cuenta_colportor, sea cual sea la causa del cambio. La usa '
  'mi_deuda_con_la_casa_editora() para decir cuánto debía hace 7 días. No viaja por el sync; no escribe nadie con JWT.';
comment on column public.cuenta_deuda_historial.deuda is
  'La deuda real en centavos desde `desde` (puede ser negativa: a favor).';
comment on column public.cuenta_deuda_historial.desde is
  'Desde cuándo vale esa deuda (hasta la fila siguiente de la misma persona).';

create trigger cuenta_deuda_historial_auditoria_insert
  before insert on public.cuenta_deuda_historial
  for each row execute function public.tg_auditoria_insert();
create trigger cuenta_deuda_historial_auditoria_update
  before update on public.cuenta_deuda_historial
  for each row execute function public.tg_auditoria_update();

alter table public.cuenta_deuda_historial enable row level security;
revoke all on public.cuenta_deuda_historial from anon, authenticated;
grant select on public.cuenta_deuda_historial to authenticated;
grant all on public.cuenta_deuda_historial to service_role;

-- LEE: la propia persona y el ADMIN. Sin políticas de escritura: no escribe nadie con JWT.
create policy cuenta_deuda_historial_select on public.cuenta_deuda_historial
  for select to authenticated
  using (usuario_id = (select auth.uid()) or (select public.tiene_rol('ADMIN')));

-- ----------------------------------------------------------------------------
-- 2. Quien lo llena
-- ----------------------------------------------------------------------------

-- DEFINER: lo dispara cualquier escritura de la cuenta (RPC, triggers, el servidor) y la tabla no admite escritura con
-- JWT. Solo deja fila si la deuda que se lee (la de la cuenta viva; 0 si está de baja) cambió de verdad.
create function public.tg_cuenta_colportor_historial_deuda()
returns trigger
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_nueva bigint := case when new.deleted_at is null then new.deuda_total else 0 end;
  v_vieja bigint;
begin
  if tg_op = 'UPDATE' then
    v_vieja := case when old.deleted_at is null then old.deuda_total else 0 end;
    if v_vieja = v_nueva then
      return new;
    end if;
  end if;

  insert into public.cuenta_deuda_historial (usuario_id, deuda, desde)
  values (new.usuario_id, v_nueva, clock_timestamp());
  return new;
end;
$$;

comment on function public.tg_cuenta_colportor_historial_deuda() is
  'AFTER INSERT o UPDATE de deuda_total / deleted_at en cuenta_colportor (0168): deja una fila en cuenta_deuda_historial '
  'con la deuda que se lee (0 si la cuenta está de baja) y la hora, solo si cambió. Cualquier causa deja su fila. DEFINER.';

revoke all on function public.tg_cuenta_colportor_historial_deuda() from public, anon, authenticated, service_role;

create trigger cuenta_colportor_historial_deuda
  after insert or update of deuda_total, deleted_at on public.cuenta_colportor
  for each row execute function public.tg_cuenta_colportor_historial_deuda();

-- La primera fila de cada cuenta que ya existe: su deuda de hoy. No hay datos de antes y no se inventan.
insert into public.cuenta_deuda_historial (usuario_id, deuda, desde)
select cu.usuario_id, case when cu.deleted_at is null then cu.deuda_total else 0 end, clock_timestamp()
  from public.cuenta_colportor cu;

-- ----------------------------------------------------------------------------
-- 3. mi_deuda_con_la_casa_editora: la deuda de hace 7 días
-- ----------------------------------------------------------------------------

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
  v_hace_7    bigint;
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

  -- La de hace 7 días exactos (7 × 24 h): la última registrada hasta entonces; null si no hay un registro de aquel momento.
  select h.deuda into v_hace_7
    from public.cuenta_deuda_historial h
   where h.usuario_id = v_uid and h.deleted_at is null
     and h.desde <= now() - interval '7 days'
   order by h.desde desc, h.id desc
   limit 1;

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
    'deuda_hace_7_dias', v_hace_7,
    'suma_de_saldos', v_suma,
    'depositos_validados', v_depositos,
    'tarjetas_validadas', v_tarjetas,
    'pedidos', v_pedidos);
end;
$$;

comment on function public.mi_deuda_con_la_casa_editora() is
  'Vista 33B, HU-CTA-002 (0164, backend-supabase#235; 0165 y 0168, #243): la deuda de la colportora autenticada con la '
  'casa editora. Devuelve jsonb: deuda_total (la real, cuenta_colportor), deuda_hace_7_dias (la que figuraba hace 7 '
  'días exactos según cuenta_deuda_historial, sea cual sea la causa del cambio; null si no hay un registro de aquel '
  'momento), suma_de_saldos, depositos_validados, tarjetas_validadas y pedidos (solo los de saldo > 0, el más viejo '
  'primero, con monto, pagado, saldo y lineas). Los depósitos validados a la casa editora y los cobros con tarjeta '
  'validados pagan primero el pedido más viejo (decisiones «Pagado ped.», 03/11, y «Tarjeta ped.», 04/11); los '
  'pedidos son los AUTORIZADO, DESPACHADO y RECIBIDO con monto_autorizado (o monto_total). Si deuda_total no coincide '
  'con suma_de_saldos, algo más la movió (transferencia, alquiler). Solo lo suyo (auth.uid()); 42501 sin sesión.';
