-- ============================================================================
-- 0119 · La tabla de plata del colportor pasa a llamarse `cuenta_colportor` (backend-supabase#155,
--        «Nombre cta.» de la decisión de Cristian del 25/10, HU-CTA-001..005 y HU-CTA-007)
--
-- Origen: la tabla `public.estado_cuenta` (0067) comparte nombre con la FUNCIÓN `estado_cuenta()` (0004:
-- devuelve ACTIVA / PENDIENTE_ASIGNACION / SUSPENDIDA, HU-AUTH-008). Dos cosas con el mismo nombre se
-- confunden al leer y al escribir una consulta. Decisión de Cristian (25/10, backend-supabase PR 146): la
-- que cambia de nombre es la TABLA de plata. La función `estado_cuenta()` no se toca.
--
-- ## Qué cambia
--
-- Solo el nombre, con todo lo que cuelga de la tabla: sus constraints (y los índices que las respaldan),
-- los dos triggers de auditoría, la política de lectura y los comentarios. Las columnas, los tipos, los
-- permisos, la RLS y el comportamiento no cambian: una tabla renombrada conserva su OID, así que los
-- GRANT, la RLS y los triggers siguen donde estaban. La tabla está vacía y nadie escribe en ella (el
-- cálculo del snapshot llega con la conexión de V2), por eso no hay nada que migrar.
--
-- Lo que la lee y cambia de nombre con ella: `cuentas_de_campania()` (0114), reescrita abajo con el nombre
-- nuevo y el resto del cuerpo idéntico. Las funciones de 0112 (PR 179: `mover_deuda_casa_editora`,
-- `pedido_contexto`) todavía no están en develop: quien mergee segundo, ese PR o este, las actualiza.
--
-- ## Lo que ya estaba hecho (0114, #111)
--
-- El resto del issue, `deposito.campania_id` (FK a campaña, obligatorio para el concepto ALQUILER) y el
-- saldo de alquiler POR campaña, se resolvió en 0114: cada depósito de alquiler dice a qué campaña paga y
-- el saldo de cada colportor sale de `campania.alquiler_monto` menos sus depósitos validados de esa
-- campaña (`cuentas_de_campania()`: alquiler_monto / pagado / por_validar / debe), así que cambiar el
-- monto de una campaña recalcula solo esa. Esta migración no suma otra tabla de saldos: derivarlo no
-- puede quedar desfasado.
--
-- ## Pendiente
--
-- La columna `deuda_alquiler` del snapshot (una sola cifra por colportor) no se usa y no puede decir «por
-- campaña»; se la deja con el comentario corregido hasta que se decida si se quita (pendiente de este PR).
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. La tabla y todo lo que cuelga de ella
-- ----------------------------------------------------------------------------

alter table public.estado_cuenta rename to cuenta_colportor;

-- Renombrar el constraint renombra también el índice que lo respalda (pkey y unique).
alter table public.cuenta_colportor rename constraint estado_cuenta_pkey to cuenta_colportor_pkey;
alter table public.cuenta_colportor rename constraint estado_cuenta_usuario_key to cuenta_colportor_usuario_key;
alter table public.cuenta_colportor rename constraint estado_cuenta_usuario_id_fkey to cuenta_colportor_usuario_id_fkey;
alter table public.cuenta_colportor rename constraint estado_cuenta_created_by_fkey to cuenta_colportor_created_by_fkey;

alter trigger estado_cuenta_auditoria_insert on public.cuenta_colportor rename to cuenta_colportor_auditoria_insert;
alter trigger estado_cuenta_auditoria_update on public.cuenta_colportor rename to cuenta_colportor_auditoria_update;

alter policy estado_cuenta_select on public.cuenta_colportor rename to cuenta_colportor_select;

comment on table public.cuenta_colportor is
  'Snapshot calculado de la situación financiera del colportor (V2, HU-CTA-001..005): una fila por usuario. '
  'Lo escribe el servidor; esta migración no lo calcula. Lleva un id propio (el esquema decía usuario_id '
  'como clave) porque todas las tablas de public tienen id uuid. Se llamaba estado_cuenta hasta 0119: el '
  'nombre se pisaba con la función estado_cuenta() de 0004 (ACTIVA / PENDIENTE_ASIGNACION / SUSPENDIDA), '
  'que sigue llamándose así. El alquiler se lleva por campaña (cuentas_de_campania(), 0114), no acá.';
comment on column public.cuenta_colportor.deuda_alquiler is
  'No se usa. Una sola cifra por colportor no puede llevar el alquiler POR campaña: el saldo de cada '
  'campaña sale de campania.alquiler_monto y los depósitos ALQUILER de esa campaña (cuentas_de_campania(), '
  '0114). Pendiente de decisión si se quita.';

-- ----------------------------------------------------------------------------
-- 2. La función que la lee (0114), con el nombre nuevo
-- ----------------------------------------------------------------------------

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
  'su ciudad (la de su zona actual), las cuatro cifras de su cuenta (cuenta_colportor, 0 si no tiene fila), '
  'el último depósito de casa editora y el alquiler de ESTA campaña aparte: monto, pagado (tickets '
  'validados), por validar, lo que debe y la fecha del último pago. Ni clientes ni personas visitadas. '
  'Errores: 42501 sin permiso; CZ001 campaña inexistente. Una campaña terminada se lee.';
