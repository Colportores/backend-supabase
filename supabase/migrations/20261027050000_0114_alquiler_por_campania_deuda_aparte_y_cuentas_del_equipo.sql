-- ============================================================================
-- 0114 · Alquiler como deuda aparte, por campaña, y las cuentas del equipo para el panel:
--        deposito.campania_id, el monto del alquiler que cambia el coordinador (con su registro en
--        audit_log) y cuentas_de_campania() (backend-supabase#111, HU-CTA-007, HU-CTA-005, HU-CAM-001/002,
--        vista 36 «Cuentas»)
--
-- Origen: cambio de requisitos del 21/10 (reunión del 05/10, docs#69, C7) y la decisión de Cristian del
-- 25/10 «Alq. campaña» (el alquiler se lleva POR CAMPAÑA: cada depósito de alquiler dice a qué campaña
-- paga y el saldo es uno por campaña; si cambia el monto de una, solo se recalcula esa). Es V2: se
-- conecta después del 20/11 (plan-sprints §5). Se escribe ahora para no rehacerlo.
--
-- Lo que ya estaba (0067): `campania.alquiler_monto` (centavos, null = la campaña no cobra alquiler),
-- `deposito.concepto` (CASA_EDITORA | ALQUILER) y `estado_cuenta` con la deuda con la casa editora. El
-- alquiler es una deuda APARTE: no se suma a `deuda_total` y NO bloquea nada (ni pedidos, ni ventas, ni la
-- campaña): ninguna función de esta migración, ni de las que ya existían, mira el alquiler para dejar o no
-- dejar hacer algo.
--
-- ## 1. deposito.campania_id
--
-- La decisión «Alq. campaña» dice que la columna `deposito.campania_id` va en backend-supabase#155; este
-- issue la usa para saber cuánto pagó cada colportor de ESTA campaña. Se suma acá, sola y sin el resto de
-- #155 (el renombre de `estado_cuenta` a `cuenta_colportor` sigue siendo de #155): FK a campaña, y el
-- CHECK que pide la decisión: un depósito con concepto ALQUILER dice a qué campaña paga. Uno de casa
-- editora puede llevarla o no (no se usa). La tabla no tiene camino de escritura todavía (#135 le suma el
-- push); las bases tienen datos simulados hasta diciembre, así que no hay nada que migrar.
-- Si #155 llega después de esta migración, su migración parte de la columna ya creada.
--
-- ## 2. El monto del alquiler y su registro
--
--   definir_alquiler_de_campania(p_campania_id, p_monto) -> (alquiler_monto, cambio)
--
-- El coordinador de la campaña (o un ADMIN) cambia el monto desde «Editar» de la vista 36: p_monto en
-- centavos, >= 0, o null para que la campaña deje de cobrar alquiler. Vale para los colportores ya
-- inscriptos y para los que se inscriban después (el monto es de la campaña, no de cada uno). Lo ya
-- depositado como alquiler no se toca: el saldo de cada colportor se recalcula solo (HU-CAM-002: con
-- $U 1.500 y $U 500 pagados, pasar a $U 1.800 deja $U 1.300 por pagar). Idempotente: el mismo valor no
-- cambia nada ni deja registro (`cambio` = false). Errores: 42501 sin permiso; CZ001 campaña
-- inexistente; CZ011 campaña terminada (ver «Pendiente»); 22023 monto negativo.
--
-- Cada cambio queda en `audit_log` (HU-CAM-002) como `alquiler_de_campania_cambiado`: lo escribe un
-- TRIGGER de campania, no la función, para que quede también si un ADMIN cambia el monto por otro camino
-- (el UPDATE directo que su política le permite). Quién = el actor; sobre qué = la fila de la campaña; el
-- detalle lleva solo el monto anterior y el nuevo (números o null), nunca texto.
--
-- ## 3. cuentas_de_campania(p_campania_id)
--
-- Lo que dibuja la vista 36 (pestañas «Casa editora» y «Alquiler»): una fila por colportor de la campaña
--
--   colportor_id, nombre, apellido, de_baja     el colportor (sin email ni nada más de la persona);
--                                                de_baja = su inscripción en ESTA campaña está dada de
--                                                baja. Sigue saliendo: su deuda no desaparece.
--   ciudad_id, ciudad_nombre, departamento      la ciudad de su zona actual en esta campaña (la misma
--                                                regla que 0111/0060/0061; sin zona o de baja, los tres null)
--   deuda_total, dinero_depositado,             las cuatro cifras de HU-CTA-001, del snapshot
--   dinero_en_mano, dinero_por_cobrar           `estado_cuenta` (0 si el colportor todavía no tiene fila).
--                                                «En mano» es una referencia: lo cobrado y no depositado,
--                                                sin descontar gastos del día (dicho en la reunión).
--                                                Son del colportor, no de la campaña.
--   ultimo_deposito_fecha, _monto               «Últ. depósito»: el último depósito de CASA_EDITORA
--                                                (el mismo criterio que pedido_contexto, 0112).
--   alquiler_monto                              lo que cobra la campaña por colportor (null = no cobra).
--   alquiler_pagado                             depósitos de ALQUILER de ESTA campaña con el ticket
--                                                VALIDADO («validar acredita», R-CT05).
--   alquiler_por_validar                        los de ALQUILER de esta campaña que todavía no cuentan:
--                                                sin ticket o con el ticket PENDIENTE. Uno con el ticket
--                                                RECHAZADO no cuenta en ninguno de los dos.
--   alquiler_debe                               alquiler_monto menos alquiler_pagado, sin bajar de 0
--                                                (null si la campaña no cobra). Si pagó de más se ve
--                                                porque alquiler_pagado supera a alquiler_monto.
--   alquiler_ultimo_pago_fecha                  fecha del último depósito de alquiler validado («Último
--                                                pago»); null si no hay.
--
-- Permiso y errores: los de las demás lecturas del panel (0033/0111). Sin JWT, colportor, sin rol, rol
-- vencido o coordinador de otra campaña: 42501, antes de mirar nada más. ADMIN: cualquier campaña.
-- Campaña inexistente o dada de baja: CZ001. Una campaña terminada se lee. SECURITY DEFINER con
-- search_path vacío (el coordinador no lee `estado_cuenta`, `deposito` ni `ticket` ajenos por RLS en
-- todos los casos), columnas explícitas, VOLATILE (llama a lanzar_motivo_mapa(); supabase-js la manda por
-- POST), EXECUTE solo para authenticated. Ni clientes ni personas visitadas: los montos son del
-- colportor (R-RP01).
--
-- ## Para otros repos
--
--   · front-coordinadores-web (vista 36): POST /rest/v1/rpc/cuentas_de_campania con { p_campania_id } y
--     POST /rest/v1/rpc/definir_alquiler_de_campania con { p_campania_id, p_monto }. «Alquiler de la
--     campaña: $U 18.500 por colportor» es `alquiler_monto` (centavos); la lista se puede ordenar por
--     `alquiler_debe` (HU-CTA-005).
--   · front-colportores-mobile (HU-CTA-007, «Mi alquiler», #389): la campaña (con `alquiler_monto`) ya
--     viaja por el pull; los depósitos viajan con #135 y llevan `campania_id` desde esta migración.
--   · backend-supabase#155: cuando renombre `estado_cuenta` a `cuenta_colportor`, actualiza
--     cuentas_de_campania() (lee `estado_cuenta`) igual que las funciones de 0112.
--
-- ## Pendiente (archivo de pendientes de esta entrega)
--
--   · «CERRADA»: la campaña no tiene una columna de estado; se toma «terminada» (fecha_fin ya pasó) como la
--     usan las demás RPC del panel. El cierre explícito de HU-CAM-002 no existe todavía.
--   · Qué pasa con el alquiler de quien se da de baja de la campaña: hoy se calcula igual que a los demás.
--   · Cómo se valida un depósito sin ticket (el retiro por el coordinador): hoy no cuenta como pagado
--     hasta que #110 lo defina.
--
-- Forward-only: no se edita una vez aplicada.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. deposito.campania_id
-- ----------------------------------------------------------------------------

alter table public.deposito
  add column campania_id uuid references public.campania(id);

-- El nombre va después de los CHECK de 0067 (Postgres los evalúa por orden alfabético): un depósito
-- inválido por otra razón sigue dando el error de siempre.
alter table public.deposito
  add constraint deposito_pago_de_alquiler_con_campania_check
  check (concepto <> 'ALQUILER' or campania_id is not null);

create index deposito_campania_idx on public.deposito (campania_id) where campania_id is not null;

comment on column public.deposito.campania_id is
  'La campaña a la que paga el depósito (decisión «Alq. campaña», 25/10): obligatoria si el concepto es '
  'ALQUILER (el saldo de alquiler es uno por campaña); en uno de casa editora puede ir o no. La app pone '
  'la campaña en curso y, si el colportor está en dos, él elige.';

-- ----------------------------------------------------------------------------
-- 2. El cambio del monto del alquiler queda en audit_log
-- ----------------------------------------------------------------------------

create function public.tg_campania_alquiler_auditar()
returns trigger
language plpgsql
volatile
security definer
set search_path = ''
as $$
begin
  -- Quién: auth.uid() lo pone auditoria.registrar(). El detalle, solo los dos montos (centavos o null).
  perform auditoria.registrar(
    'alquiler_de_campania_cambiado', 'campania', new.id, null,
    jsonb_build_object('monto_anterior', old.alquiler_monto, 'monto_nuevo', new.alquiler_monto));
  return null;
end;
$$;

comment on function public.tg_campania_alquiler_auditar() is
  'AFTER UPDATE OF alquiler_monto en campania (0114, backend-supabase#111, HU-CAM-002): deja el evento '
  'alquiler_de_campania_cambiado en audit_log con el monto anterior y el nuevo.';

revoke all on function public.tg_campania_alquiler_auditar() from public, anon, authenticated, service_role;

create trigger campania_alquiler_auditar
  after update of alquiler_monto on public.campania
  for each row
  when (old.alquiler_monto is distinct from new.alquiler_monto)
  execute function public.tg_campania_alquiler_auditar();

-- ----------------------------------------------------------------------------
-- 3. definir_alquiler_de_campania
-- ----------------------------------------------------------------------------

create function public.definir_alquiler_de_campania(p_campania_id uuid, p_monto bigint)
returns table (alquiler_monto bigint, cambio boolean)
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_motivo    text;
  v_anterior  bigint;
begin
  -- El permiso, antes de mirar nada más.
  v_motivo := public.motivo_mapa_de_campania(p_campania_id);
  if v_motivo = 'SIN_PERMISO' then
    raise exception 'Solo el coordinador de la campaña o un administrador puede cambiar su alquiler. Entrá con la cuenta del coordinador de esta campaña.'
      using errcode = 'insufficient_privilege';
  end if;
  if v_motivo = 'CAMPANIA_TERMINADA' then
    raise exception 'La campaña ya terminó y su alquiler queda como estaba. Elegí una campaña en curso.'
      using errcode = 'CZ011';
  end if;
  perform public.lanzar_motivo_mapa(v_motivo);

  if p_monto is not null and p_monto < 0 then
    raise exception 'El alquiler no puede ser negativo. Escribí un monto de cero o más, o dejalo vacío si la campaña no cobra alquiler.'
      using errcode = 'invalid_parameter_value';
  end if;

  -- Con candado: el doble toque y dos coordinadores se serializan acá.
  select c.alquiler_monto into v_anterior
    from public.campania c
   where c.id = p_campania_id
     for update;

  if v_anterior is distinct from p_monto then
    update public.campania c set alquiler_monto = p_monto where c.id = p_campania_id;
  end if;

  return query select p_monto, (v_anterior is distinct from p_monto);
end;
$$;

comment on function public.definir_alquiler_de_campania(uuid, bigint) is
  'Vista 36, HU-CAM-002 (0114, backend-supabase#111): el coordinador de la campaña (o un ADMIN) cambia el '
  'monto fijo del alquiler (centavos, >= 0; null = la campaña no cobra). Vale para los inscriptos y los '
  'que se inscriban después; lo ya depositado no se toca y el saldo se recalcula. Idempotente (cambio = '
  'false si no cambia nada). El cambio queda en audit_log (trigger campania_alquiler_auditar). Errores: '
  '42501 sin permiso; CZ001 campaña inexistente; CZ011 campaña terminada; 22023 monto negativo.';

revoke all on function public.definir_alquiler_de_campania(uuid, bigint)
  from public, anon, authenticated, service_role;
grant execute on function public.definir_alquiler_de_campania(uuid, bigint) to authenticated;

-- ----------------------------------------------------------------------------
-- 4. cuentas_de_campania
-- ----------------------------------------------------------------------------

create function public.cuentas_de_campania(p_campania_id uuid)
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
           coalesce(cu.deuda_total, 0),
           coalesce(cu.dinero_depositado, 0),
           coalesce(cu.dinero_en_mano, 0),
           coalesce(cu.dinero_por_cobrar, 0),
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
      left join public.estado_cuenta cu
             on cu.usuario_id = i.usuario_id and cu.deleted_at is null
      left join lateral (
        select d.fecha, d.monto
          from public.deposito d
         where d.colportor_id = i.usuario_id and d.deleted_at is null
           and d.concepto = 'CASA_EDITORA'
         order by d.fecha desc, d.id
         limit 1
      ) ult on true
      cross join lateral (
        select coalesce(sum(d.monto) filter (where t.estado = 'VALIDADO'), 0)::bigint as pagado,
               coalesce(sum(d.monto) filter (where t.id is null or t.estado = 'PENDIENTE'), 0)::bigint
                 as por_validar,
               max(d.fecha) filter (where t.estado = 'VALIDADO') as ultimo_pago
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
  'Vista 36, HU-CTA-005 y HU-CTA-007 (0114, backend-supabase#111): una fila por colportor de la campaña con '
  'su ciudad (la de su zona actual), las cuatro cifras de su cuenta (estado_cuenta, 0 si no tiene fila), '
  'el último depósito de casa editora y el alquiler de ESTA campaña aparte: monto, pagado (tickets '
  'validados), por validar, lo que debe y la fecha del último pago. Ni clientes ni personas visitadas. '
  'Errores: 42501 sin permiso; CZ001 campaña inexistente. Una campaña terminada se lee.';

revoke all on function public.cuentas_de_campania(uuid)
  from public, anon, authenticated, service_role;
grant execute on function public.cuentas_de_campania(uuid) to authenticated;
