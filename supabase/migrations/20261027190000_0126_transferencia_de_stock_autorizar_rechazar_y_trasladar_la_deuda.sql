-- ============================================================================
-- 0126 · Transferencia de stock entre colportores: la bandeja del coordinador, autorizar (el stock y la deuda
--        pasan de uno al otro) y rechazar con motivo
--        (backend-supabase#106, HU-STK-005 / HU-STK-006, vista 35 «Pedidos y Transferencias», pestaña
--        «Transferencias»)
--
-- Origen: cambio de requisitos del 21/10 (reunión del 05/10, docs#69) y el canvas de la vista 35 (21/10): en una
-- transferencia, «la deuda de esos libros pasa del que entrega al que recibe al autorizar». Es V2: se conecta
-- después del 20/11 (plan-sprints §5). Se escribe ahora para no rehacerlo.
--
-- ## Qué suma a lo que existe (solo columnas opcionales; las tablas están vacías)
--
--   · `transferencia_item.precio_unitario` (centavos, null hasta que se autoriza): la foto de
--     `producto.precio_base_compra` (el costo de la casa editora, decisión «Costo editora» del 25/10) al
--     autorizar. Antes de autorizar la bandeja muestra el costo vigente; autorizada, queda el que se usó.
--   · `transferencia_stock.monto_deuda` (centavos, null hasta que se autoriza): la suma de cantidad × precio de
--     sus líneas. ES lo que pasó de la deuda de quien da a la de quien recibe.
--   · `transferencia_stock.decidido_en`: cuándo se autorizó o rechazó (reloj real).
--   · `transferencia_stock.motivo_rechazo` (hasta 500, obligatorio y no en blanco si estado = RECHAZADO, null en
--     cualquier otro estado), el mismo CHECK que `pedido_casa_editora` en 0112.
--   · `transferencia_stock.coordinador_id` (ya existía) pasa a ser quien decidió: lo escribe autorizar o rechazar.
--
-- ## Lo que lee el panel (todas SECURITY DEFINER, VOLATILE, EXECUTE solo para `authenticated`)
--
--   transferencias_de_campania(p_campania_id)
--     -> (transferencia_id, origen_id, origen_nombre, origen_apellido, destino_id, destino_nombre,
--         destino_apellido, ciudad_id, ciudad_nombre, departamento, estado, fecha_solicitud, productos,
--         unidades, monto_deuda, decidido_en, motivo_rechazo)
--   transferencia_lineas(p_transferencia_id)
--     -> (producto_id, producto_nombre, producto_tipo, cantidad, precio_unitario, subtotal, tiene_quien_da,
--         debe_entregar_quien_recibe, tiene_quien_recibe)
--
--   · `transferencias_de_campania`: una fila por transferencia entre dos colportores INSCRIPTOS en la campaña
--     (los dos, cuando se pidió: «autorizar transferencias entre colportores de mi campaña», HU-STK-006). La
--     ciudad es la de la zona actual de quien da (el contrato del panel). Salen PENDIENTE_AUTORIZACION,
--     AUTORIZADO, EJECUTADO y RECHAZADO; no el CANCELADO. Orden: la más reciente primero. `monto_deuda` es el
--     guardado si ya se autorizó, y si no la estimación con el costo vigente (null si algún producto no tiene
--     costo cargado). Las pestañas y sus números los saca el panel de esta lista. Una campaña terminada se lee.
--   · `transferencia_lineas`: lo que se transfiere (cantidad × costo de la casa editora) y, para decidir con
--     contexto («Stock de los dos»): cuánto tiene hoy quien da, cuántas unidades de ese producto debe entregar
--     quien recibe (vendidas y todavía no entregadas) y cuánto tiene ya quien recibe.
--   · Permiso de lectura: ADMIN, o COORDINADOR de una campaña donde los dos colportores estaban inscriptos
--     cuando se pidió (aun terminada o con alguno dado de baja). La lista, por campaña, con el permiso de campaña
--     de las demás lecturas del panel (42501 / CZ001).
--
-- ## Lo que decide (SECURITY DEFINER, VOLATILE, EXECUTE solo para `authenticated`)
--
--   autorizar_transferencia(p_transferencia_id)
--     -> (transferencia_id, estado, monto_deuda, decidido_en, ya_estaba)
--   rechazar_transferencia(p_transferencia_id, p_motivo)
--     -> (transferencia_id, estado, decidido_en, ya_estaba)
--
--   · Autorizar: PENDIENTE_AUTORIZACION -> AUTORIZADO, y en la MISMA transacción (todo o nada, HU-STK-006
--     «atómicamente»): descuenta de quien da, suma a quien recibe, deja los dos movimientos
--     (SALIDA_TRANSFERENCIA y ENTRADA_TRANSFERENCIA, con la transferencia como origen), fija el costo de cada
--     línea y pasa `monto_deuda` de la deuda de quien da (`cuenta_colportor.deuda_total`) a la de quien recibe.
--     Autorizar ya ejecuta: no hay un paso EJECUTADO aparte (el canvas termina en «Autorizada»); el estado
--     EJECUTADO queda sin uso. Si una cuenta no existe se crea (y si estaba dada de baja se reactiva: la deuda
--     no puede quedar en una fila que nadie lee).
--   · Se bloquea (ante la duda se bloquea) si quien da no tiene el stock completo (TR003) o si algún producto no
--     tiene costo de la casa editora cargado (TR005): el panel dice cuál y el coordinador rechaza o corrige. Una
--     transferencia sin líneas vivas tampoco se autoriza.
--   · Rechazar: PENDIENTE_AUTORIZACION -> RECHAZADO con motivo obligatorio (no en blanco, hasta 500 caracteres,
--     se guarda recortado). No toca el stock ni la deuda.
--   · Un reintento no mueve dos veces: autorizar una transferencia que YO ya autoricé y rechazar una que YO ya
--     rechacé con el mismo motivo devuelven el estado actual con `ya_estaba = true`, sin tocar nada. Dos
--     coordinadores a la vez: la fila se bloquea (FOR UPDATE) y el segundo recibe TR002.
--   · Permiso de decisión (más estricto que el de lectura): ADMIN, o COORDINADOR de una campaña donde los DOS
--     están inscriptos sin baja (y lo estaban al pedir) y cuyo plazo de escritura siga abierto (hasta 15 días
--     después de su fin, 0020).
--   · Auditoría obligatoria (HU-STK-006): `transferencia_autorizada` y `transferencia_rechazada`, en la misma
--     transacción. El detalle lleva ids, cantidades y montos; el motivo del rechazo (texto libre) NO se copia.
--
-- ## Errores (todos con mensaje que dice qué hacer)
--
--   42501  sin permiso (sin JWT, sin rol, colportor, coordinador ajeno, campaña cerrada para escribir).
--   CZ001  campaña inexistente (la lista por campaña).
--   TR001  la transferencia no existe.
--   TR002  la transferencia no está por autorizar (otra persona la decidió o cambió de estado).
--   TR003  quien da no tiene el stock completo.
--   TR004  el motivo del rechazo falta, está en blanco o pasa de 500 caracteres.
--   TR005  no se puede valorar: sin líneas, o un producto sin costo de la casa editora.
--
-- ## Lo que NO hace (y por qué)
--
--   · No CREA la solicitud: HU-STK-005 dice que la hace el colportor y el canvas 34 («Pedir prestado») abre una
--     transferencia desde el panel; quién la crea y por qué camino (push del teléfono, RPC) no está decidido
--     (archivo de pendientes de esta entrega). Hoy la fila la escribe el servidor.
--   · No tiene «Deshacer»: la decisión del 25/10 de los 8 segundos es de los pedidos.
--   · No manda el push a los dos colportores (HU-NOT) ni va al sync: las tres tablas siguen fuera de
--     `sync.entidad`. El motivo del rechazo le llega al colportor cuando el contrato del sync lo incluya.
--   · No numera la transferencia («T-18» del canvas): igual que el pedido (#180), el número visible es una
--     decisión de modelo de datos; el panel muestra un código corto del uuid.
--   · No toca la tabla `pedido_casa_editora` ni sus funciones (#104).
--
-- ## Para otros repos
--
--   · front-coordinadores-web (vista 35, pestaña Transferencias): POST /rest/v1/rpc/<nombre> con los parámetros
--     de arriba; los errores TR001..TR005 llegan en `code` del cuerpo de PostgREST. El contrato del panel
--     (`EstadoDeTransferencia`) junta AUTORIZADO y EJECUTADO en «Autorizada».
--   · docs-organizacion: HU-STK-005/006 y `esquema-datos.md` (columnas nuevas, la deuda que pasa, errores TR) en
--     un issue aparte.
--
-- Forward-only: esta migración no se edita una vez aplicada.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. Columnas nuevas
-- ----------------------------------------------------------------------------

alter table public.transferencia_item
  add column precio_unitario bigint;

alter table public.transferencia_item
  add constraint transferencia_item_precio_unitario_check
  check (precio_unitario is null or precio_unitario >= 0);

comment on column public.transferencia_item.precio_unitario is
  'La foto de producto.precio_base_compra (el costo de la casa editora) al autorizar la transferencia, en '
  'centavos (0126). null mientras no se autorizó: la bandeja muestra el costo vigente.';

alter table public.transferencia_stock
  add column monto_deuda    bigint,
  add column decidido_en    timestamptz,
  add column motivo_rechazo text;

-- Hasta ahora ninguna función rechazaba una transferencia, así que no debería haber rechazadas; si hubiera
-- alguna (cargada a mano), se le deja un motivo para que la regla nueva no tire la migración.
update public.transferencia_stock
   set motivo_rechazo = 'Sin motivo registrado'
 where estado = 'RECHAZADO' and (motivo_rechazo is null or motivo_rechazo !~ '\S');

alter table public.transferencia_stock
  add constraint transferencia_stock_monto_deuda_check
  check (monto_deuda is null or monto_deuda >= 0),
  -- Rechazar exige un motivo (HU-STK-006); el motivo solo existe en una transferencia rechazada.
  add constraint transferencia_stock_motivo_rechazo_check
  check ((estado = 'RECHAZADO'
            and motivo_rechazo is not null and motivo_rechazo ~ '\S' and length(motivo_rechazo) <= 500)
         or (estado <> 'RECHAZADO' and motivo_rechazo is null));

comment on column public.transferencia_stock.monto_deuda is
  'Lo que pasó de la deuda de quien da a la de quien recibe al autorizar, en centavos (0126): cantidad × '
  'precio_unitario de sus líneas. null mientras no se autorizó.';
comment on column public.transferencia_stock.decidido_en is
  'Cuándo se autorizó o rechazó, con el reloj real (clock_timestamp). null mientras espera (0126).';
comment on column public.transferencia_stock.motivo_rechazo is
  'Por qué se rechazó la transferencia; obligatorio, no en blanco y de hasta 500 caracteres si estado = '
  'RECHAZADO, null en cualquier otro estado (0126). Texto libre del coordinador: vive solo en la nube y no '
  'se copia a audit_log.';
comment on column public.transferencia_stock.coordinador_id is
  'Quien decidió la transferencia (autorizó o rechazó); null mientras espera (0126).';

-- ----------------------------------------------------------------------------
-- 2. Piezas internas
-- ----------------------------------------------------------------------------

-- La deuda con la casa editora pasa de un colportor a otro (crea la cuenta si no existe; si estaba dada de baja,
-- la reactiva). Las dos filas se tocan en un solo INSERT ordenado por usuario, así dos traslados que se cruzan no
-- se bloquean entre sí. Quien da puede quedar con saldo a favor (negativo): pagó libros que ya no tiene. Interna.
create function public.trasladar_deuda_casa_editora(p_de uuid, p_a uuid, p_monto bigint)
returns void
language sql
volatile
security definer
set search_path = ''
as $$
  insert into public.cuenta_colportor as cu (usuario_id, deuda_total)
  select x.usuario_id, x.delta
    from (values (p_de, -p_monto), (p_a, p_monto)) x(usuario_id, delta)
   where p_monto <> 0
   order by x.usuario_id
  on conflict (usuario_id) do update
    set deuda_total = case when cu.deleted_at is null then cu.deuda_total else 0 end + excluded.deuda_total,
        deleted_at = null,
        actualizado_en = now();
$$;

comment on function public.trasladar_deuda_casa_editora(uuid, uuid, bigint) is
  'Resta p_monto de cuenta_colportor.deuda_total de p_de y se lo suma a p_a (crea o reactiva las cuentas). La '
  'llama autorizar_transferencia() (0126). Interna.';

revoke all on function public.trasladar_deuda_casa_editora(uuid, uuid, bigint)
  from public, anon, authenticated, service_role;

-- ¿El usuario autenticado puede VER (p_para_decidir = false) o DECIDIR (true) la transferencia entre estos dos
-- colportores pedida en esa fecha? ADMIN, o COORDINADOR de una campaña (no borrada) donde los DOS estaban
-- inscriptos al pedirla y esa campaña no había terminado ese día. Para decidir además: los dos siguen inscriptos
-- sin baja y el plazo de escritura (0020) sigue abierto. Interna.
create function public.coordina_la_transferencia(p_origen_id uuid, p_destino_id uuid, p_fecha timestamptz,
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
                         and public.hoy_montevideo(p_fecha) <= coalesce(c.fecha_fin, 'infinity'::date)
                         and (not p_para_decidir
                              or (io.deleted_at is null and idd.deleted_at is null
                                  and public.escritura_dentro_de_plazo(c.fecha_fin)))));
$$;

comment on function public.coordina_la_transferencia(uuid, uuid, timestamptz, boolean) is
  'true si el usuario autenticado es ADMIN, o COORDINADOR de una campaña donde p_origen_id y p_destino_id estaban '
  'inscriptos cuando se pidió la transferencia (p_fecha). Para decidir (p_para_decidir) además los dos siguen '
  'inscriptos sin baja y el plazo de escritura (fin + 15 días, 0020) sigue abierto: ver y decidir no es lo '
  'mismo. Interna (0126).';

revoke all on function public.coordina_la_transferencia(uuid, uuid, timestamptz, boolean)
  from public, anon, authenticated, service_role;

-- La transferencia, con el permiso ya comprobado. p_escribir = true la bloquea (FOR UPDATE) y pide el permiso de
-- decisión; false pide el de lectura. Interna: la llaman las RPC de abajo, que son SECURITY DEFINER.
create function public.transferencia_para(p_transferencia_id uuid, p_escribir boolean)
returns public.transferencia_stock
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_t  public.transferencia_stock;
begin
  if auth.uid() is null or not (public.tiene_rol('ADMIN') or public.tiene_rol('COORDINADOR')) then
    raise exception 'Solo el coordinador de la campaña o un administrador puede ver y decidir las transferencias. Entrá con la cuenta del coordinador de esta campaña.'
      using errcode = 'insufficient_privilege';
  end if;

  if p_escribir then
    select * into v_t
      from public.transferencia_stock t
     where t.id = p_transferencia_id and t.deleted_at is null
       for update;
  else
    select * into v_t
      from public.transferencia_stock t
     where t.id = p_transferencia_id and t.deleted_at is null;
  end if;
  if not found then
    raise exception 'La transferencia no existe o ya se dio de baja. Recargá la bandeja de transferencias.'
      using errcode = 'TR001';
  end if;

  if p_escribir then
    if not public.coordina_la_transferencia(v_t.origen_id, v_t.destino_id, v_t.fecha_solicitud, true) then
      raise exception 'No podés decidir esta transferencia: no es entre colportores de una campaña tuya que siga abierta (los dos tienen que estar inscriptos en ella). Si es un error, pedile a un administrador que la decida.'
        using errcode = 'insufficient_privilege';
    end if;
  elsif not public.coordina_la_transferencia(v_t.origen_id, v_t.destino_id, v_t.fecha_solicitud, false) then
    raise exception 'Esta transferencia no es entre colportores de tus campañas. Elegí una de la bandeja.'
      using errcode = 'insufficient_privilege';
  end if;

  return v_t;
end;
$$;

comment on function public.transferencia_para(uuid, boolean) is
  'La transferencia de p_transferencia_id con el permiso comprobado (0126): lectura = ADMIN o el coordinador '
  'de una campaña donde los dos estaban inscriptos; escritura = además campaña abierta y los dos sin baja, y '
  'bloquea la fila. 42501 sin permiso; TR001 si no existe. Interna.';

revoke all on function public.transferencia_para(uuid, boolean)
  from public, anon, authenticated, service_role;

-- ----------------------------------------------------------------------------
-- 3. transferencias_de_campania: la pestaña «Transferencias»
-- ----------------------------------------------------------------------------

create function public.transferencias_de_campania(p_campania_id uuid)
returns table (transferencia_id uuid, origen_id uuid, origen_nombre text, origen_apellido text,
               destino_id uuid, destino_nombre text, destino_apellido text,
               ciudad_id uuid, ciudad_nombre text, departamento text,
               estado text, fecha_solicitud timestamptz, productos integer, unidades integer,
               monto_deuda bigint, decidido_en timestamptz, motivo_rechazo text)
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
           t.motivo_rechazo
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
       and public.hoy_montevideo(t.fecha_solicitud) <= coalesce(ca.fecha_fin, 'infinity'::date)
     order by t.fecha_solicitud desc, t.id;
end;
$$;

comment on function public.transferencias_de_campania(uuid) is
  'Vista 35, HU-STK-005/006 (0126, backend-supabase#106): las transferencias de stock entre colportores '
  'inscriptos en la campaña (los dos, al pedirla) en los cuatro estados (por autorizar, autorizado, ejecutado, '
  'rechazado; sin canceladas), la más reciente primero, con la ciudad de la zona actual de quien da, lo que se '
  'transfiere en productos y unidades, la deuda que pasa (la guardada si ya se autorizó, si no la estimada con '
  'el costo vigente; null si falta un costo) y el motivo del rechazo. Errores: 42501 sin permiso; CZ001 campaña '
  'inexistente. Una campaña terminada se lee.';

revoke all on function public.transferencias_de_campania(uuid)
  from public, anon, authenticated, service_role;
grant execute on function public.transferencias_de_campania(uuid) to authenticated;

-- ----------------------------------------------------------------------------
-- 4. transferencia_lineas: el detalle para decidir
-- ----------------------------------------------------------------------------

create function public.transferencia_lineas(p_transferencia_id uuid)
returns table (producto_id uuid, producto_nombre text, producto_tipo text,
               cantidad integer, precio_unitario bigint, subtotal bigint,
               tiene_quien_da integer, debe_entregar_quien_recibe integer, tiene_quien_recibe integer)
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_t  public.transferencia_stock;
begin
  v_t := public.transferencia_para(p_transferencia_id, false);

  return query
    select it.producto_id,
           pr.nombre,
           pr.tipo,
           it.cantidad,
           coalesce(it.precio_unitario, pr.precio_base_compra)::bigint,
           it.cantidad::bigint * coalesce(it.precio_unitario, pr.precio_base_compra),
           coalesce(sd.cantidad_disponible, 0),
           (select coalesce(sum(en.cantidad), 0)::integer
              from public.venta ve
              join public.entrega en
                on en.venta_id = ve.id and en.deleted_at is null and en.pendiente
               and en.producto_id = it.producto_id
             where ve.colportor_id = v_t.destino_id and ve.deleted_at is null),
           coalesce(sr.cantidad_disponible, 0)
      from public.transferencia_item it
      join public.producto pr on pr.id = it.producto_id
      left join public.stock sd
             on sd.usuario_id = v_t.origen_id and sd.producto_id = it.producto_id and sd.deleted_at is null
      left join public.stock sr
             on sr.usuario_id = v_t.destino_id and sr.producto_id = it.producto_id and sr.deleted_at is null
     where it.transferencia_id = v_t.id and it.deleted_at is null
     order by pr.nombre, it.producto_id;
end;
$$;

comment on function public.transferencia_lineas(uuid) is
  'Vista 35, HU-STK-005/006 (0126): las líneas de la transferencia con su costo unitario de la casa editora (la '
  'foto si ya se autorizó, si no el vigente; null si falta), los subtotales y el stock de los dos: cuánto tiene '
  'hoy quien da, cuántas unidades de ese producto debe entregar quien recibe (vendidas y todavía no entregadas) '
  'y cuánto tiene ya quien recibe (puede ser negativo, tal cual). Errores: 42501 sin permiso; TR001 si no '
  'existe.';

revoke all on function public.transferencia_lineas(uuid)
  from public, anon, authenticated, service_role;
grant execute on function public.transferencia_lineas(uuid) to authenticated;

-- ----------------------------------------------------------------------------
-- 5. autorizar_transferencia
-- ----------------------------------------------------------------------------

create function public.autorizar_transferencia(p_transferencia_id uuid)
returns table (transferencia_id uuid, estado text, monto_deuda bigint, decidido_en timestamptz,
               ya_estaba boolean)
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
    return query select v_t.id, v_t.estado, v_t.monto_deuda, v_t.decidido_en, true;
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

  return query select v_t.id, 'AUTORIZADO'::text, v_monto, v_ahora, false;
end;
$$;

comment on function public.autorizar_transferencia(uuid) is
  'Vista 35, HU-STK-005/006 (0126, backend-supabase#106): PENDIENTE_AUTORIZACION -> AUTORIZADO y, en la misma '
  'transacción, descuenta el stock de quien da, se lo suma a quien recibe (dos movimientos), fija el costo de '
  'cada línea y pasa monto_deuda de la deuda de quien da a la de quien recibe. Deja el evento '
  'transferencia_autorizada en audit_log. Un reintento de quien ya la autorizó devuelve ya_estaba = true sin '
  'mover nada. Errores: 42501; TR001; TR002 (ya no está por autorizar); TR003 (quien da no tiene el stock); '
  'TR005 (sin líneas o un producto sin costo).';

revoke all on function public.autorizar_transferencia(uuid)
  from public, anon, authenticated, service_role;
grant execute on function public.autorizar_transferencia(uuid) to authenticated;

-- ----------------------------------------------------------------------------
-- 6. rechazar_transferencia
-- ----------------------------------------------------------------------------

create function public.rechazar_transferencia(p_transferencia_id uuid, p_motivo text)
returns table (transferencia_id uuid, estado text, decidido_en timestamptz, ya_estaba boolean)
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
    return query select v_t.id, v_t.estado, v_t.decidido_en, true;
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

  return query select v_t.id, 'RECHAZADO'::text, v_ahora, false;
end;
$$;

comment on function public.rechazar_transferencia(uuid, text) is
  'Vista 35, HU-STK-006 (0126, backend-supabase#106): PENDIENTE_AUTORIZACION -> RECHAZADO con motivo obligatorio '
  '(no en blanco, hasta 500 caracteres, se guarda recortado). No toca el stock ni la deuda. Deja el evento '
  'transferencia_rechazada en audit_log, sin el motivo. Un reintento de quien ya la rechazó con el mismo motivo '
  'devuelve ya_estaba = true. Errores: 42501; TR001; TR002; TR004 (motivo).';

revoke all on function public.rechazar_transferencia(uuid, text)
  from public, anon, authenticated, service_role;
grant execute on function public.rechazar_transferencia(uuid, text) to authenticated;
