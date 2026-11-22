-- ============================================================================
-- 0175 · Los permisos del coordinador miran a todos los coordinadores de la campaña
--        (backend-supabase#254, casilla «Coord. camp.»; sigue a la 0174)
--
-- ## El caso
--
-- Con la 0174 una campaña tiene varios coordinadores. Esta migración mueve cada permiso que comparaba con
-- `campania.coordinador_id = auth.uid()` a `coordina_la_campania(campania)`, o sea «soy uno de sus coordinadores
-- vigentes». Daniel Ruiz, segundo coordinador de la campaña de Luis, puede lo mismo que Luis: ver sus cuentas, validar
-- depósitos y tickets, anular cobros, autorizar transferencias de sus colportores, dibujar el mapa, fijar becas, decidir el
-- alquiler de quien se dio de baja, leer los acompañamientos y guardar los precios de sus ciudades.
--
-- ## Qué cambia (y qué no)
--
-- Solo el predicado. Cada función se reemplaza con `create or replace`, misma firma y mismo cuerpo salvo la comparación
-- con la columna; los comentarios, los privilegios y los errores quedan como estaban. Las cuatro políticas de lectura y
-- escritura que miraban la columna (precios de la ciudad, historial de zonas, cuenta y decisiones del alquiler) hacen lo
-- mismo con `alter policy`. Nadie gana ni pierde permiso sobre la campaña de un único coordinador: `campania_coordinador`
-- trae el mismo coordinador que la columna (0174). Quien dejó de ser coordinador pierde el permiso al instante.
--
-- Las comparaciones con `transferencia_stock.coordinador_id` y `pedido_casa_editora.coordinador_id` (quien decidió esa
-- transferencia o ese pedido) no se tocan: son el autor de la decisión, no el coordinador de una campaña.
--
-- ## Los datos
--
-- No se toca ninguna fila. Lo prueba supabase/tests/0175_… (dos coordinadores en la misma campaña). Forward-only.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. Funciones
-- ----------------------------------------------------------------------------

-- anular_cobro
create or replace function public.anular_cobro(p_cobranza_id uuid, p_motivo text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $$
declare
  v_cobro     public.cobranza;
  v_es_admin  boolean := public.tiene_rol('ADMIN');
begin
  if auth.uid() is null or not (v_es_admin or public.tiene_rol('COORDINADOR')) then
    raise exception using
      errcode = '42501',
      message = 'Solo un coordinador o un administrador puede anular un cobro. Entrá con tu cuenta de coordinador.';
  end if;

  if p_motivo is null or p_motivo not in ('Monto equivocado', 'Cliente equivocado', 'Lo registré dos veces', 'Otro') then
    raise exception using
      errcode = '22023',
      message = 'Elegí el motivo de la anulación: Monto equivocado, Cliente equivocado, Lo registré dos veces u Otro.';
  end if;

  -- Un cobro que no existe, que está dado de baja o que no es de un colportor de su campaña da el mismo
  -- error: no se averigua qué cobros hay.
  select c.* into v_cobro
    from public.cobranza c
    join public.venta v on v.id = c.venta_id
   where c.id = p_cobranza_id
     and c.deleted_at is null
     and (v_es_admin
          or exists (select 1
                       from public.campania_colportor cc
                       join public.campania ca on ca.id = cc.campania_id
                      where cc.usuario_id = v.colportor_id
                        and cc.deleted_at is null
                        and ca.deleted_at is null
                        and public.coordina_la_campania(ca.id)))
     for update of c;
  if not found then
    raise exception using
      errcode = 'CB004',
      message = 'No encontramos ese cobro entre los de tu equipo.';
  end if;

  if v_cobro.anulado_at is not null then
    return jsonb_build_object(
      'cobranza_id', v_cobro.id, 'anulado_at', v_cobro.anulado_at,
      'motivo', v_cobro.motivo_anulacion, 'ya_estaba', true);
  end if;

  update public.cobranza
     set anulado_at = now(), motivo_anulacion = p_motivo
   where id = v_cobro.id
  returning anulado_at into v_cobro.anulado_at;

  return jsonb_build_object(
    'cobranza_id', v_cobro.id, 'anulado_at', v_cobro.anulado_at, 'motivo', p_motivo, 'ya_estaba', false);
end;
$$;

-- campanias_del_coordinador
create or replace function public.campanias_del_coordinador()
 RETURNS TABLE(id uuid, nombre text, tipo text, fecha_inicio date, fecha_fin date)
 LANGUAGE plpgsql
 STABLE
 SET search_path TO ''
AS $$
declare
  v_hoy date := public.hoy_montevideo();
begin
  if auth.uid() is null then
    raise exception 'Hace falta iniciar sesión. Entrá con tu cuenta de coordinador.'
      using errcode = 'insufficient_privilege';
  end if;

  if not (public.tiene_rol('COORDINADOR') or public.tiene_rol('ADMIN')) then
    raise exception 'Esta cuenta no es de coordinador. Entrá con tu cuenta de coordinador.'
      using errcode = 'insufficient_privilege';
  end if;

  return query
    select c.id, c.nombre, c.tipo, c.fecha_inicio, c.fecha_fin
      from public.campania c
     where public.coordina_la_campania(c.id)
       and c.deleted_at is null
       and (c.fecha_fin is null or c.fecha_fin >= v_hoy)
     order by (c.fecha_inicio > v_hoy), abs(c.fecha_inicio - v_hoy), c.id;
end;
$$;

-- coordina_al_colportor
create or replace function public.coordina_al_colportor(p_usuario_id uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $$
  select public.tiene_rol('COORDINADOR')
     and exists (select 1
                   from public.campania_colportor cc
                   join public.campania c on c.id = cc.campania_id
                  where cc.usuario_id = p_usuario_id
                    and public.coordina_la_campania(c.id));
$$;

-- coordina_la_transferencia
create or replace function public.coordina_la_transferencia(p_origen_id uuid, p_destino_id uuid, p_fecha timestamp with time zone, p_para_decidir boolean)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $$
  select public.tiene_rol('ADMIN')
      or (public.tiene_rol('COORDINADOR')
          and exists (select 1
                        from public.campania c
                        join public.campania_colportor io
                          on io.campania_id = c.id and io.usuario_id = p_origen_id
                        join public.campania_colportor idd
                          on idd.campania_id = c.id and idd.usuario_id = p_destino_id
                       where c.deleted_at is null
                         and public.coordina_la_campania(c.id)
                         and public.inscripcion_cubre_el_instante(io.created_at, io.deleted_at, io.tramos_afuera, p_fecha)
                         and public.inscripcion_cubre_el_instante(idd.created_at, idd.deleted_at, idd.tramos_afuera, p_fecha)
                         and public.hoy_montevideo(p_fecha) >= c.fecha_inicio
                         and public.hoy_montevideo(p_fecha) <= coalesce(c.fecha_fin, 'infinity'::date)
                         and (not p_para_decidir
                              or (io.deleted_at is null and idd.deleted_at is null
                                  and public.escritura_dentro_de_plazo(c.fecha_fin)))));
$$;

-- decidir_alquiler_pagado
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

-- mis_campanias_del_mapa
create or replace function public.mis_campanias_del_mapa()
 RETURNS SETOF uuid
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $$
  select cc.campania_id
    from public.campania_coordinador cc
    join public.usuario u on u.id = cc.usuario_id
   where cc.usuario_id = auth.uid() and cc.deleted_at is null
     and u.deleted_at is null and u.suspendido_en is null
  union
  select i.campania_id from public.mis_inscripciones_no_terminadas() i;
$$;

-- motivo_campania_del_coordinador
create or replace function public.motivo_campania_del_coordinador(p_campania_id uuid)
 RETURNS text
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $$
declare
  v_campania public.campania;
  v_es_admin boolean := public.tiene_rol('ADMIN');
begin
  if auth.uid() is null or not (v_es_admin or public.tiene_rol('COORDINADOR')) then
    return 'SIN_PERMISO';
  end if;

  select * into v_campania from public.campania c where c.id = p_campania_id;
  if not found or v_campania.deleted_at is not null then
    return 'CAMPANIA_INEXISTENTE';
  end if;

  if not v_es_admin and not public.coordina_la_campania(p_campania_id) then
    return 'SIN_PERMISO';
  end if;

  if v_campania.fecha_fin is not null and v_campania.fecha_fin < public.hoy_montevideo() then
    return 'CAMPANIA_NO_VIGENTE';
  end if;

  return null;
end;
$$;

-- motivo_mapa_de_campania
create or replace function public.motivo_mapa_de_campania(p_campania_id uuid)
 RETURNS text
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $$
declare
  v_campania public.campania;
  v_es_admin boolean := public.tiene_rol('ADMIN');
begin
  if auth.uid() is null or not (v_es_admin or public.tiene_rol('COORDINADOR')) then
    return 'SIN_PERMISO';
  end if;

  select * into v_campania from public.campania c where c.id = p_campania_id;
  if not found or v_campania.deleted_at is not null then
    return 'CAMPANIA_INEXISTENTE';
  end if;

  if not v_es_admin and not public.coordina_la_campania(p_campania_id) then
    return 'SIN_PERMISO';
  end if;

  if v_campania.fecha_fin is not null and v_campania.fecha_fin < public.hoy_montevideo() then
    return 'CAMPANIA_TERMINADA';
  end if;

  return null;
end;
$$;

-- puede_decidir_pedido_de
create or replace function public.puede_decidir_pedido_de(p_colportor_id uuid, p_fecha_pedido timestamp with time zone)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $$
  select public.tiene_rol('ADMIN')
      or (public.tiene_rol('COORDINADOR')
          and exists (select 1
                        from public.campania_colportor cc
                        join public.campania c on c.id = cc.campania_id
                       where cc.usuario_id = p_colportor_id
                         and cc.deleted_at is null
                         and c.deleted_at is null
                         and public.coordina_la_campania(c.id)
                         and c.id = public.campania_del_ticket(p_colportor_id, p_fecha_pedido)
                         and public.escritura_dentro_de_plazo(c.fecha_fin)));
$$;

-- puede_leer_el_acompaniamiento
create or replace function public.puede_leer_el_acompaniamiento(p_jornada_id uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $$
  select public.tiene_rol('ADMIN')
      or (public.tiene_rol('COORDINADOR')
          and exists (
            select 1
              from public.jornada j
              join public.campania_colportor i on i.usuario_id = j.colportor_id
              join public.campania c on c.id = i.campania_id
             where j.id = p_jornada_id
               and public.coordina_la_campania(c.id)
               and c.deleted_at is null
               and public.inscripcion_cubre_el_instante(i.created_at, i.deleted_at, i.tramos_afuera, j.inicio)
               and public.hoy_montevideo(j.inicio) >= c.fecha_inicio
               and public.hoy_montevideo(j.inicio) <= coalesce(c.fecha_fin, 'infinity'::date)))
$$;

-- puede_ver_pedido_de
create or replace function public.puede_ver_pedido_de(p_colportor_id uuid, p_fecha_pedido timestamp with time zone)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $$
  select public.tiene_rol('ADMIN')
      or (public.tiene_rol('COORDINADOR')
          and exists (select 1
                        from public.campania c
                       where c.id = public.campania_del_ticket(p_colportor_id, p_fecha_pedido)
                         and public.coordina_la_campania(c.id)));
$$;

-- puede_ver_ticket
create or replace function public.puede_ver_ticket(p_ticket_id uuid, p_usuario_id uuid, p_fecha timestamp with time zone)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $$
  select p_usuario_id = auth.uid()
      or public.tiene_rol('ADMIN')
      or (public.tiene_rol('COORDINADOR')
          and exists (select 1
                        from public.campania c
                       where c.id = public.campania_que_valida_el_ticket(p_ticket_id, p_usuario_id, p_fecha)
                         and public.coordina_la_campania(c.id)));
$$;

-- retiro_para_confirmar
create or replace function public.retiro_para_confirmar(p_deposito_id uuid, p_escribir boolean)
 RETURNS deposito
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $$
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
                           and public.coordina_la_campania(ca.id))) then
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

-- tg_campania_colportor_beca_y_limite
create or replace function public.tg_campania_colportor_beca_y_limite()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $$
begin
  if auth.uid() is null then
    return new;
  end if;

  if new.tipo_beca is not distinct from old.tipo_beca
     and new.meta_libros is not distinct from old.meta_libros
     and new.meta_monto_ces is not distinct from old.meta_monto_ces then
    return new;
  end if;

  if current_setting('colportores.recalculo_de_metas', true) = 'on' then
    return new;
  end if;

  if public.tiene_rol('ADMIN')
     or (public.tiene_rol('COORDINADOR')
         and exists (select 1 from public.campania c
                      where c.id = new.campania_id and public.coordina_la_campania(c.id))) then
    return new;
  end if;

  raise exception 'La beca y la meta las fija el coordinador de la campaña'
    using errcode = '42501';
end;
$$;

-- ticket_para_validar
create or replace function public.ticket_para_validar(p_ticket_id uuid, p_escribir boolean)
 RETURNS ticket
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $$
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
                         where ca.id = public.campania_que_valida_el_ticket(v_t.id, v_t.usuario_id, coalesce(v_t.fecha, v_t.subido_en))
                           and public.coordina_la_campania(ca.id))) then
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

-- ----------------------------------------------------------------------------
-- 2. Políticas
-- ----------------------------------------------------------------------------

alter policy precio_por_ciudad_insert_staff on public.precio_por_ciudad
  with check (
    (select public.tiene_rol('ADMIN'))
    or ((select public.tiene_rol('COORDINADOR'))
        and exists (select 1
                      from public.campania_ciudad cc
                      join public.campania c on c.id = cc.campania_id
                     where cc.id = precio_por_ciudad.campania_ciudad_id
                       and public.coordina_la_campania(c.id))));

alter policy precio_por_ciudad_update_staff on public.precio_por_ciudad
  using (
    (select public.tiene_rol('ADMIN'))
    or ((select public.tiene_rol('COORDINADOR'))
        and exists (select 1
                      from public.campania_ciudad cc
                      join public.campania c on c.id = cc.campania_id
                     where cc.id = precio_por_ciudad.campania_ciudad_id
                       and public.coordina_la_campania(c.id))))
  with check (
    (select public.tiene_rol('ADMIN'))
    or ((select public.tiene_rol('COORDINADOR'))
        and exists (select 1
                      from public.campania_ciudad cc
                      join public.campania c on c.id = cc.campania_id
                     where cc.id = precio_por_ciudad.campania_ciudad_id
                       and public.coordina_la_campania(c.id))));

alter policy campania_colportor_zona_historial_select on public.campania_colportor_zona_historial
  using (
    (select public.tiene_rol('ADMIN'))
    or ((select public.tiene_rol('COORDINADOR'))
        and exists (select 1
                      from public.campania_colportor cc
                      join public.campania c on c.id = cc.campania_id
                     where cc.id = campania_colportor_zona_historial.campania_colportor_id
                       and public.coordina_la_campania(c.id))));

alter policy cuenta_alquiler_select on public.cuenta_alquiler
  using (
    usuario_id = (select auth.uid())
    or (select public.tiene_rol('ADMIN'))
    or ((select public.tiene_rol('COORDINADOR'))
        and public.coordina_la_campania(cuenta_alquiler.campania_id)));

alter policy alquiler_decision_select on public.alquiler_decision
  using (
    usuario_id = (select auth.uid())
    or (select public.tiene_rol('ADMIN'))
    or ((select public.tiene_rol('COORDINADOR'))
        and public.coordina_la_campania(alquiler_decision.campania_id)));
