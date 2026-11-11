-- ============================================================================
-- 0140 · «Deshacer» de 8 segundos para las transferencias de stock, y de qué campaña es una transferencia
--        (backend-supabase#201, seguimiento de #106 / 0126 y 0127; decisiones de Cristian del 27/10,
--        «Deshacer tr.» y «Campaña tr.»)
--
-- ## 1. «Deshacer tr.»: sí, como los pedidos
--
-- Marta autoriza una transferencia por error. Igual que con los pedidos a la casa editora (0112), tiene 8
-- segundos para deshacerla: el stock y la deuda vuelven como estaban, todo en una sola operación.
--
--   deshacer_decision_de_transferencia(p_transferencia_id) -> (transferencia_id, estado, ya_estaba)
--
--   · Dentro de los 8 segundos de lo decidido (el servidor acepta hasta 10: 2 de gracia por la latencia, las
--     mismas funciones `plazo_para_deshacer_pedido()` y `gracia_para_deshacer_pedido()` de los pedidos) y solo
--     por quien lo decidió (`coordinador_id`), una transferencia AUTORIZADA o RECHAZADA vuelve a
--     PENDIENTE_AUTORIZACION.
--   · Si estaba AUTORIZADA, en la MISMA transacción: devuelve a quien dio lo que se le descontó y se lo saca a
--     quien recibió (el stock de quien recibió puede quedar negativo si ya entregó esos libros en esos segundos:
--     el stock negativo es la señal de inconsistencia de siempre, S46), da de baja los dos movimientos
--     (`SALIDA_TRANSFERENCIA` y `ENTRADA_TRANSFERENCIA`: la transferencia queda como si no hubiera pasado),
--     devuelve la deuda de quien recibió a quien dio, y borra el costo fijado de cada línea y `monto_deuda` (la
--     bandeja vuelve a mostrar el costo vigente).
--   · Si estaba RECHAZADA, borra el motivo (no tocó stock ni deuda).
--   · Siempre borra `coordinador_id` y `decidido_en`: espera de nuevo y la puede decidir cualquiera con permiso.
--   · Un reintento sobre una transferencia ya deshecha devuelve `ya_estaba = true` sin tocar nada.
--   · Auditoría: `transferencia_decision_deshecha` (ids, la decisión que se deshizo y el monto), en la misma
--     transacción.
--   · `autorizar_transferencia` y `rechazar_transferencia` devuelven `deshacer_hasta` (decidido_en + 8 s) y
--     `transferencias_de_campania` lo trae en las AUTORIZADAS y RECHAZADAS, como los pedidos: el panel muestra
--     «Deshacer» hasta ese instante. Las tres cambian el tipo de retorno: drop + create y se vuelven a dar los
--     permisos (EXECUTE solo para `authenticated`).
--   · Error nuevo: TR006, la decisión ya no se puede deshacer (pasaron los 8 segundos, siguió su camino o la
--     decidió otra persona).
--
-- ## 2. «Campaña tr.»: la campaña en curso el día que se pidió
--
-- Ana y Beto trabajan en la campaña «Actual» (coordina Marta, termina en 10 días) y ya están inscriptos en
-- «Próxima» (coordina Pablo, empieza en 20 días). Una transferencia que Ana le pide hoy a Beto es de «Actual»:
-- solo Marta la ve y la decide. Hasta ahora la veían las dos y la decidía quien llegara primero.
--
--   · Una transferencia es de la campaña EN CURSO el día que se pidió (`fecha_solicitud`, día de Montevideo): entre
--     `fecha_inicio` y `fecha_fin`, con los dos colportores inscriptos en ella ese día. Es la regla de las
--     jornadas (0100). `coordina_la_transferencia` suma el piso por `fecha_inicio` y `transferencias_de_campania`
--     lo aplica igual.
--   · Lo pedido entre la inscripción y el inicio de una campaña no es de ninguna: no lo ve ningún coordinador y lo
--     decide el administrador (que lo ve y lo decide por `coordina_la_transferencia`, como siempre).
--   · No cambia el tope por el final (el plazo de escritura de 15 días de 0020 para decidir).
--
-- Forward-only: esta migración no se edita una vez aplicada.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. Campaña en curso: quién ve y quién decide
-- ----------------------------------------------------------------------------

-- Igual que en 0126 más el piso por fecha_inicio. Sus privilegios siguen (create or replace los conserva).
create or replace function public.coordina_la_transferencia(p_origen_id uuid, p_destino_id uuid, p_fecha timestamptz,
                                                 p_para_decidir boolean)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select public.tiene_rol('ADMIN')
      or (public.tiene_rol('COORDINADOR')
          and exists (select 1
                        from public.campania c
                        join public.campania_colportor io
                          on io.campania_id = c.id and io.usuario_id = p_origen_id
                        join public.campania_colportor idd
                          on idd.campania_id = c.id and idd.usuario_id = p_destino_id
                       where c.deleted_at is null
                         and c.coordinador_id = auth.uid()
                         and public.inscripcion_cubre_el_instante(io.created_at, io.deleted_at, io.tramos_afuera, p_fecha)
                         and public.inscripcion_cubre_el_instante(idd.created_at, idd.deleted_at, idd.tramos_afuera, p_fecha)
                         and public.hoy_montevideo(p_fecha) >= c.fecha_inicio
                         and public.hoy_montevideo(p_fecha) <= coalesce(c.fecha_fin, 'infinity'::date)
                         and (not p_para_decidir
                              or (io.deleted_at is null and idd.deleted_at is null
                                  and public.escritura_dentro_de_plazo(c.fecha_fin)))));
$$;

comment on function public.coordina_la_transferencia(uuid, uuid, timestamptz, boolean) is
  'true si el usuario autenticado es ADMIN, o COORDINADOR de la campaña EN CURSO el día en que se pidió la '
  'transferencia (p_fecha: entre fecha_inicio y fecha_fin) y donde p_origen_id y p_destino_id estaban inscriptos '
  'ese día (0126, 0140). Lo pedido entre la inscripción y el inicio no es de ninguna campaña: solo el ADMIN. Para '
  'decidir (p_para_decidir) además los dos siguen inscriptos sin baja y el plazo de escritura (fin + 15 días, '
  '0020) sigue abierto. Interna.';


-- ----------------------------------------------------------------------------
-- 2. La bandeja: la campaña en curso y hasta cuándo se puede deshacer
-- ----------------------------------------------------------------------------

drop function public.transferencias_de_campania(uuid);

create function public.transferencias_de_campania(p_campania_id uuid)
returns table (transferencia_id uuid, numero bigint, origen_id uuid, origen_nombre text, origen_apellido text,
               destino_id uuid, destino_nombre text, destino_apellido text,
               ciudad_id uuid, ciudad_nombre text, departamento text,
               estado text, fecha_solicitud timestamptz, productos integer, unidades integer,
               monto_deuda bigint, decidido_en timestamptz, motivo_rechazo text, deshacer_hasta timestamptz)
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_motivo  text;
begin
  v_motivo := public.motivo_mapa_de_campania(p_campania_id);
  if v_motivo = 'SIN_PERMISO' then
    raise exception 'Solo el coordinador de la campaña o un administrador puede ver sus transferencias. Entrá con la cuenta del coordinador de esta campaña.'
      using errcode = 'insufficient_privilege';
  end if;
  if v_motivo is distinct from 'CAMPANIA_TERMINADA' then
    perform public.lanzar_motivo_mapa(v_motivo);
  end if;

  return query
    select t.id,
           t.numero,
           t.origen_id,
           uo.nombre,
           uo.apellido,
           t.destino_id,
           ud.nombre,
           ud.apellido,
           ciu.id,
           ciu.nombre,
           ciu.departamento,
           t.estado,
           t.fecha_solicitud,
           ln.productos,
           ln.unidades,
           coalesce(t.monto_deuda, ln.monto_estimado),
           t.decidido_en,
           t.motivo_rechazo,
           case when t.estado in ('AUTORIZADO', 'RECHAZADO')
                then t.decidido_en + public.plazo_para_deshacer_pedido() end
      from public.campania ca
      join public.campania_colportor io on io.campania_id = ca.id
      join public.transferencia_stock t
        on t.origen_id = io.usuario_id
       and t.deleted_at is null
       and t.estado in ('PENDIENTE_AUTORIZACION', 'AUTORIZADO', 'EJECUTADO', 'RECHAZADO')
      join public.campania_colportor idd
        on idd.campania_id = ca.id and idd.usuario_id = t.destino_id
      join public.usuario uo on uo.id = t.origen_id
      join public.usuario ud on ud.id = t.destino_id
      left join public.zona z
             on z.id = io.zona_id and z.deleted_at is null and io.deleted_at is null
      left join public.campania_ciudad cc
             on cc.id = z.campania_ciudad_id and cc.deleted_at is null
      left join public.ciudad ciu on ciu.id = cc.ciudad_id
     cross join lateral (
       select (count(*))::integer as productos,
              (coalesce(sum(it.cantidad), 0))::integer as unidades,
              case when count(*) = 0 or bool_or(pr.precio_base_compra is null) then null
                   else (sum(it.cantidad::bigint * pr.precio_base_compra))::bigint end as monto_estimado
         from public.transferencia_item it
         join public.producto pr on pr.id = it.producto_id
        where it.transferencia_id = t.id and it.deleted_at is null
     ) ln
     where ca.id = p_campania_id
       and public.inscripcion_cubre_el_instante(io.created_at, io.deleted_at, io.tramos_afuera, t.fecha_solicitud)
       and public.inscripcion_cubre_el_instante(idd.created_at, idd.deleted_at, idd.tramos_afuera, t.fecha_solicitud)
       and public.hoy_montevideo(t.fecha_solicitud) >= ca.fecha_inicio
       and public.hoy_montevideo(t.fecha_solicitud) <= coalesce(ca.fecha_fin, 'infinity'::date)
     order by t.fecha_solicitud desc, t.id;
end;
$$;

comment on function public.transferencias_de_campania(uuid) is
  'Vista 35, HU-STK-005/006 (0126, 0127, 0140, backend-supabase#106 y #201): las transferencias de stock entre '
  'colportores inscriptos en la campaña (los dos, el día que se pidió) pedidas con la campaña en curso, en los '
  'cuatro estados (por autorizar, autorizado, ejecutado, rechazado; sin canceladas), la más reciente primero, con '
  'la ciudad de la zona actual de quien da, lo que se transfiere en productos y unidades, el número visible, la '
  'deuda que pasa (la guardada si ya se autorizó, si no la estimada con el costo vigente; null si falta un costo), '
  'el motivo del rechazo y hasta cuándo se puede deshacer lo decidido (8 segundos, solo AUTORIZADAS y RECHAZADAS). '
  'Errores: 42501 sin permiso; CZ001 campaña inexistente. Una campaña terminada se lee.';

revoke all on function public.transferencias_de_campania(uuid)
  from public, anon, authenticated, service_role;
grant execute on function public.transferencias_de_campania(uuid) to authenticated;


-- ----------------------------------------------------------------------------
-- 3. autorizar y rechazar devuelven hasta cuándo se puede deshacer
-- ----------------------------------------------------------------------------

drop function public.autorizar_transferencia(uuid);

create function public.autorizar_transferencia(p_transferencia_id uuid)
returns table (transferencia_id uuid, estado text, monto_deuda bigint, decidido_en timestamptz,
               deshacer_hasta timestamptz, ya_estaba boolean)
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_t         public.transferencia_stock;
  v_lineas    integer;
  v_sin_costo text;
  v_faltan    text;
  v_monto     bigint;
  v_unidades  bigint;
  v_ahora     timestamptz := clock_timestamp();
  r           record;
begin
  v_t := public.transferencia_para(p_transferencia_id, true);

  -- Un reintento de quien ya la autorizó no mueve nada dos veces.
  if v_t.estado = 'AUTORIZADO' and v_t.coordinador_id = auth.uid() then
    return query select v_t.id, v_t.estado, v_t.monto_deuda, v_t.decidido_en,
                         v_t.decidido_en + public.plazo_para_deshacer_pedido(), true;
    return;
  end if;

  if v_t.estado <> 'PENDIENTE_AUTORIZACION' then
    raise exception 'Esta transferencia ya no está por autorizar: otra persona la decidió o siguió su camino. Recargá la bandeja para ver cómo quedó.'
      using errcode = 'TR002';
  end if;

  select count(*)::integer,
         string_agg(pr.nombre, ', ' order by pr.nombre) filter (where pr.precio_base_compra is null)
    into v_lineas, v_sin_costo
    from public.transferencia_item it
    join public.producto pr on pr.id = it.producto_id
   where it.transferencia_id = v_t.id and it.deleted_at is null;
  if v_lineas = 0 then
    raise exception 'La transferencia no tiene nada que transferir. Rechazala con un motivo para que quede cerrada.'
      using errcode = 'TR005';
  end if;
  if v_sin_costo is not null then
    raise exception 'No se puede autorizar: falta el costo de la casa editora de %. Pedile a administración que lo cargue, o rechazá la transferencia.', v_sin_costo
      using errcode = 'TR005';
  end if;

  -- Las filas de stock de los dos, en un orden fijo, antes de mirar cuánto hay: dos autorizaciones que se cruzan
  -- no se pisan ni se bloquean entre sí.
  perform 1
     from public.stock s
    where s.usuario_id in (v_t.origen_id, v_t.destino_id)
      and s.producto_id in (select it.producto_id from public.transferencia_item it
                             where it.transferencia_id = v_t.id and it.deleted_at is null)
    order by s.usuario_id, s.producto_id
      for update;

  select string_agg(format('%s (tiene %s y hacen falta %s)', pr.nombre, coalesce(sd.cantidad_disponible, 0),
                           it.cantidad), ', ' order by pr.nombre)
    into v_faltan
    from public.transferencia_item it
    join public.producto pr on pr.id = it.producto_id
    left join public.stock sd
           on sd.usuario_id = v_t.origen_id and sd.producto_id = it.producto_id and sd.deleted_at is null
   where it.transferencia_id = v_t.id and it.deleted_at is null
     and coalesce(sd.cantidad_disponible, 0) < it.cantidad;
  if v_faltan is not null then
    raise exception 'Quien da no tiene el stock para esta transferencia: %. Rechazala, o pedile que la vuelva a pedir con lo que tiene.', v_faltan
      using errcode = 'TR003';
  end if;

  for r in
    select it.id as item_id, it.producto_id as prod_id, it.cantidad as cant, pr.precio_base_compra as costo
      from public.transferencia_item it
      join public.producto pr on pr.id = it.producto_id
     where it.transferencia_id = v_t.id and it.deleted_at is null
     order by it.producto_id
  loop
    update public.stock s
       set cantidad_disponible = s.cantidad_disponible - r.cant
     where s.usuario_id = v_t.origen_id and s.producto_id = r.prod_id and s.deleted_at is null;

    -- Una fila de stock dada de baja cuenta como cero: quien recibe arranca de ahí.
    insert into public.stock as s (usuario_id, producto_id, cantidad_disponible)
    values (v_t.destino_id, r.prod_id, r.cant)
    on conflict (usuario_id, producto_id) do update
      set cantidad_disponible = case when s.deleted_at is null then s.cantidad_disponible else 0 end
                                + excluded.cantidad_disponible,
          deleted_at = null;

    insert into public.movimiento_stock (usuario_id, producto_id, tipo, cantidad, fecha, transferencia_id)
    values (v_t.origen_id,  r.prod_id, 'SALIDA_TRANSFERENCIA',  r.cant, v_ahora, v_t.id),
           (v_t.destino_id, r.prod_id, 'ENTRADA_TRANSFERENCIA', r.cant, v_ahora, v_t.id);

    update public.transferencia_item ti
       set precio_unitario = r.costo
     where ti.id = r.item_id;
  end loop;

  select sum(it.cantidad::bigint * it.precio_unitario), sum(it.cantidad)
    into v_monto, v_unidades
    from public.transferencia_item it
   where it.transferencia_id = v_t.id and it.deleted_at is null;

  update public.transferencia_stock t
     set estado = 'AUTORIZADO',
         coordinador_id = auth.uid(),
         decidido_en = v_ahora,
         monto_deuda = v_monto
   where t.id = v_t.id;

  perform public.trasladar_deuda_casa_editora(v_t.origen_id, v_t.destino_id, v_monto);

  perform auditoria.registrar(
    'transferencia_autorizada', 'transferencia_stock', v_t.id, v_t.destino_id,
    jsonb_build_object('origen_id', v_t.origen_id,
                       'destino_id', v_t.destino_id,
                       'productos', v_lineas,
                       'unidades', v_unidades,
                       'monto_deuda', v_monto));

  return query select v_t.id, 'AUTORIZADO'::text, v_monto, v_ahora, v_ahora + public.plazo_para_deshacer_pedido(), false;
end;
$$;

comment on function public.autorizar_transferencia(uuid) is
  'Vista 35, HU-STK-005/006 (0126, 0140, backend-supabase#106 y #201): PENDIENTE_AUTORIZACION -> AUTORIZADO y, en la '
  'misma transacción, descuenta el stock de quien da, se lo suma a quien recibe (dos movimientos), fija el costo '
  'de cada línea y pasa monto_deuda de la deuda de quien da a la de quien recibe. Devuelve hasta cuándo se puede '
  'deshacer (8 segundos). Deja el evento transferencia_autorizada en audit_log. Un reintento de quien ya la '
  'autorizó devuelve ya_estaba = true sin mover nada. Errores: 42501; TR001; TR002 (ya no está por autorizar); '
  'TR003 (quien da no tiene el stock); TR005 (sin líneas o un producto sin costo).';

revoke all on function public.autorizar_transferencia(uuid)
  from public, anon, authenticated, service_role;
grant execute on function public.autorizar_transferencia(uuid) to authenticated;

drop function public.rechazar_transferencia(uuid, text);

create function public.rechazar_transferencia(p_transferencia_id uuid, p_motivo text)
returns table (transferencia_id uuid, estado text, decidido_en timestamptz, deshacer_hasta timestamptz,
               ya_estaba boolean)
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_t        public.transferencia_stock;
  v_motivo   text := regexp_replace(p_motivo, '^\s+|\s+$', '', 'g');
  v_ahora    timestamptz := clock_timestamp();
  v_lineas   integer;
  v_unidades bigint;
begin
  v_t := public.transferencia_para(p_transferencia_id, true);

  if v_motivo is null or v_motivo = '' then
    raise exception 'Escribí el motivo del rechazo: es lo que van a leer los colportores.'
      using errcode = 'TR004';
  end if;
  if length(v_motivo) > 500 then
    raise exception 'El motivo del rechazo pasa de 500 caracteres. Acortalo y volvé a intentar.'
      using errcode = 'TR004';
  end if;

  -- Un reintento de quien ya la rechazó, con el mismo motivo, no hace nada.
  if v_t.estado = 'RECHAZADO' and v_t.coordinador_id = auth.uid() and v_t.motivo_rechazo = v_motivo then
    return query select v_t.id, v_t.estado, v_t.decidido_en, v_t.decidido_en + public.plazo_para_deshacer_pedido(), true;
    return;
  end if;

  if v_t.estado <> 'PENDIENTE_AUTORIZACION' then
    raise exception 'Esta transferencia ya no está por autorizar: otra persona la decidió o siguió su camino. Recargá la bandeja para ver cómo quedó.'
      using errcode = 'TR002';
  end if;

  select count(*)::integer, coalesce(sum(it.cantidad), 0)
    into v_lineas, v_unidades
    from public.transferencia_item it
   where it.transferencia_id = v_t.id and it.deleted_at is null;

  update public.transferencia_stock t
     set estado = 'RECHAZADO',
         motivo_rechazo = v_motivo,
         coordinador_id = auth.uid(),
         decidido_en = v_ahora
   where t.id = v_t.id;

  -- El motivo es texto libre: no se copia a la auditoría, se nombra por tabla y fila_id.
  perform auditoria.registrar(
    'transferencia_rechazada', 'transferencia_stock', v_t.id, v_t.destino_id,
    jsonb_build_object('origen_id', v_t.origen_id,
                       'destino_id', v_t.destino_id,
                       'productos', v_lineas,
                       'unidades', v_unidades));

  return query select v_t.id, 'RECHAZADO'::text, v_ahora, v_ahora + public.plazo_para_deshacer_pedido(), false;
end;
$$;

comment on function public.rechazar_transferencia(uuid, text) is
  'Vista 35, HU-STK-006 (0126, 0140): PENDIENTE_AUTORIZACION -> RECHAZADO con motivo obligatorio (no en blanco, '
  'hasta 500 caracteres, se guarda recortado). No toca el stock ni la deuda. Devuelve hasta cuándo se puede '
  'deshacer (8 segundos). Deja el evento transferencia_rechazada en audit_log, sin el motivo. Un reintento de '
  'quien ya la rechazó con el mismo motivo devuelve ya_estaba = true. Errores: 42501; TR001; TR002; TR004 (motivo).';

revoke all on function public.rechazar_transferencia(uuid, text)
  from public, anon, authenticated, service_role;
grant execute on function public.rechazar_transferencia(uuid, text) to authenticated;


-- ----------------------------------------------------------------------------
-- 4. deshacer_decision_de_transferencia
-- ----------------------------------------------------------------------------

create function public.deshacer_decision_de_transferencia(p_transferencia_id uuid)
returns table (transferencia_id uuid, estado text, ya_estaba boolean)
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_t   public.transferencia_stock;
  r     record;
begin
  v_t := public.transferencia_para(p_transferencia_id, true);

  -- Un reintento de deshacer: ya volvió a esperar y nadie la volvió a decidir.
  if v_t.estado = 'PENDIENTE_AUTORIZACION' and v_t.decidido_en is null then
    return query select v_t.id, v_t.estado, true;
    return;
  end if;

  if v_t.estado not in ('AUTORIZADO', 'RECHAZADO') then
    raise exception 'Esta transferencia ya siguió su camino y no se puede deshacer. Recargá la bandeja para ver cómo quedó.'
      using errcode = 'TR006';
  end if;
  if v_t.coordinador_id is distinct from auth.uid() then
    raise exception 'Solo quien decidió la transferencia puede deshacerla. Recargá la bandeja para ver cómo quedó.'
      using errcode = 'TR006';
  end if;
  if clock_timestamp() > v_t.decidido_en + public.plazo_para_deshacer_pedido()
                          + public.gracia_para_deshacer_pedido() then
    raise exception 'Pasaron más de 8 segundos: la decisión ya no se puede deshacer. Si hace falta, pedile al colportor que la vuelva a pedir.'
      using errcode = 'TR006';
  end if;

  if v_t.estado = 'AUTORIZADO' then
    -- Las filas de stock de los dos, en un orden fijo (el mismo de autorizar), antes de moverlas.
    perform 1
       from public.stock s
      where s.usuario_id in (v_t.origen_id, v_t.destino_id)
        and s.producto_id in (select it.producto_id from public.transferencia_item it
                               where it.transferencia_id = v_t.id and it.deleted_at is null)
      order by s.usuario_id, s.producto_id
        for update;

    for r in
      select it.producto_id as prod_id, it.cantidad as cant
        from public.transferencia_item it
       where it.transferencia_id = v_t.id and it.deleted_at is null
       order by it.producto_id
    loop
      -- A quien dio le vuelve lo que se le descontó (una fila dada de baja cuenta como cero).
      insert into public.stock as s (usuario_id, producto_id, cantidad_disponible)
      values (v_t.origen_id, r.prod_id, r.cant)
      on conflict (usuario_id, producto_id) do update
        set cantidad_disponible = case when s.deleted_at is null then s.cantidad_disponible else 0 end
                                  + excluded.cantidad_disponible,
            deleted_at = null;

      -- A quien recibió se le saca; puede quedar negativo si ya entregó esos libros (S46).
      insert into public.stock as s (usuario_id, producto_id, cantidad_disponible)
      values (v_t.destino_id, r.prod_id, -r.cant)
      on conflict (usuario_id, producto_id) do update
        set cantidad_disponible = case when s.deleted_at is null then s.cantidad_disponible else 0 end
                                  + excluded.cantidad_disponible,
            deleted_at = null;
    end loop;

    -- La transferencia queda como si no hubiera pasado: sus dos movimientos se dan de baja.
    update public.movimiento_stock m
       set deleted_at = clock_timestamp()
     where m.transferencia_id = v_t.id and m.deleted_at is null;

    -- La deuda vuelve de quien recibió a quien dio, y el costo fijado de cada línea se borra.
    perform public.trasladar_deuda_casa_editora(v_t.destino_id, v_t.origen_id, v_t.monto_deuda);

    update public.transferencia_item ti
       set precio_unitario = null
     where ti.transferencia_id = v_t.id and ti.precio_unitario is not null;
  end if;

  update public.transferencia_stock t
     set estado = 'PENDIENTE_AUTORIZACION',
         monto_deuda = null,
         motivo_rechazo = null,
         coordinador_id = null,
         decidido_en = null
   where t.id = v_t.id;

  perform auditoria.registrar(
    'transferencia_decision_deshecha', 'transferencia_stock', v_t.id, v_t.destino_id,
    jsonb_build_object('decision_deshecha', v_t.estado,
                       'origen_id', v_t.origen_id,
                       'destino_id', v_t.destino_id,
                       'monto_deuda', v_t.monto_deuda));

  return query select v_t.id, 'PENDIENTE_AUTORIZACION'::text, false;
end;
$$;

comment on function public.deshacer_decision_de_transferencia(uuid) is
  'Vista 35, HU-STK-005/006 (0140, backend-supabase#201, decisión «Deshacer tr.» del 27/10): vuelve a '
  'PENDIENTE_AUTORIZACION una transferencia AUTORIZADA o RECHAZADA dentro de los 8 segundos de decidida y solo '
  'por quien la decidió. Si estaba autorizada, en la misma transacción devuelve el stock a quien dio y se lo saca '
  'a quien recibió, da de baja los dos movimientos, devuelve la deuda y borra los costos fijados; si estaba '
  'rechazada, borra el motivo. Deja el evento transferencia_decision_deshecha en audit_log. Un reintento sobre '
  'una transferencia ya deshecha devuelve ya_estaba = true. Errores: 42501; TR001; TR006 (fuera de plazo, ya '
  'siguió su camino o la decidió otra persona).';

revoke all on function public.deshacer_decision_de_transferencia(uuid)
  from public, anon, authenticated, service_role;
grant execute on function public.deshacer_decision_de_transferencia(uuid) to authenticated;
