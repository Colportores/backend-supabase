-- ============================================================================
-- 0112 · Bandeja de pedidos del coordinador: ver los pedidos a la casa editora de su campaña, autorizar
--        (con cantidades reducidas), rechazar con motivo y deshacer durante 8 segundos
--        (backend-supabase#104, HU-STK-003, vista 35 «Pedidos y Transferencias», pestaña de pedidos)
--
-- Origen: cambio de requisitos del 21/10 (reunión del 05/10, docs#69, C5) y las decisiones de Cristian
-- del 25/10 «Reducir ped.» (con Reducir y Deshacer), «Costo editora» (el costo es
-- `producto.precio_base_compra` y cada línea guarda su foto en `pedido_item.precio_unitario`; nadie lo
-- tipea en el pedido) y la del agente de decisiones, por R2 (el motivo del rechazo va hasta 500
-- caracteres, obligatorio y no en blanco, el mismo tope que `ticket.motivo_rechazo`). Es V2: se conecta
-- después del 20/11 (plan-sprints §5). Se escribe ahora para no rehacerlo.
--
-- ## Qué suma a lo que existe (solo columnas opcionales; las tablas están vacías)
--
--   · `pedido_item.cantidad_autorizada` (integer, 0 a `cantidad`, null = se autorizó lo pedido). SIN pisar
--     `cantidad`: queda lo que pidió el colportor y lo que autorizó la coordinadora (Reducir).
--   · `pedido_casa_editora.monto_autorizado` (centavos, null mientras nadie autorizó): la suma de
--     cantidad autorizada × `precio_unitario`. ES lo que se cargó a la deuda, así deshacer resta
--     exactamente eso. `monto_total` no cambia: es lo que pidió el colportor.
--   · `pedido_casa_editora.decidido_por` / `decidido_en`: quién autorizó o rechazó y cuándo (el reloj de
--     verdad, `clock_timestamp()`: el plazo de Deshacer corre desde ahí). `coordinador_id` no se toca: es
--     el que REGISTRÓ el pedido (origen COORDINADOR).
--   · `pedido_casa_editora.motivo_rechazo` (hasta 500, obligatorio y no en blanco si estado = RECHAZADO,
--     null en cualquier otro estado). CHECK de la tabla, como en `ticket`.
--
-- ## Lo que lee el panel (todas SECURITY DEFINER, VOLATILE, EXECUTE solo para `authenticated`)
--
--   pedidos_de_campania(p_campania_id)
--     -> (pedido_id, colportor_id, nombre, apellido, ciudad_id, ciudad_nombre, departamento, de_baja,
--         estado, origen, fecha_pedido, productos, unidades, unidades_autorizadas, monto_total,
--         monto_autorizado, excede_limite, decidido_en, motivo_rechazo, deshacer_hasta)
--   pedido_lineas(p_pedido_id)
--     -> (producto_id, producto_nombre, producto_tipo, cantidad, cantidad_autorizada, precio_unitario,
--         subtotal, subtotal_autorizado, stock)
--   pedido_contexto(p_pedido_id)
--     -> (colportor_id, nombre, apellido, estado, monto_total, monto_autorizado, deuda_actual,
--         deuda_con_pedido, por_cobrar, libros_por_entregar, ultimo_deposito_fecha,
--         ultimo_deposito_monto)
--
--   · `pedidos_de_campania`: una fila por pedido de los colportores inscriptos en la campaña (la ciudad
--     es la de su zona actual, la misma regla que `pedidos_por_autorizar_por_ciudad`, 0111; sin zona o con
--     la inscripción de baja, null = «Sin ciudad»). Salen los cinco estados de las pestañas de la vista:
--     PENDIENTE_AUTORIZACION («Por autorizar»), AUTORIZADO, DESPACHADO, RECIBIDO y RECHAZADO. NO salen el
--     BORRADOR (lo que el coordinador todavía arma: no espera a nadie) ni el CANCELADO. Las pestañas y sus
--     números los saca el panel de esta lista. Orden: el más reciente primero. `deshacer_hasta` es el
--     instante hasta el que se puede deshacer lo decidido (decidido_en + 8 s) y solo viene en un pedido
--     AUTORIZADO o RECHAZADO. Una campaña terminada se lee.
--   · `pedido_lineas`: lo que pide (cantidad × costo unitario de la casa editora), lo que se autorizó y
--     el stock que el colportor tiene hoy de ese producto («Stock de estos productos»).
--   · `pedido_contexto`: la cuenta del colportor para decidir. `deuda_actual` es `estado_cuenta.deuda_total`
--     (sin cuenta = 0). `deuda_con_pedido` es la deuda actual MÁS el pedido solo mientras está por
--     autorizar; ya autorizado, el pedido está en la deuda actual. `por_cobrar` es
--     `estado_cuenta.dinero_por_cobrar`: la misma cifra que Cuentas. `libros_por_entregar` son las unidades
--     vendidas todavía no entregadas (como `por_entregar` de 0111). El último depósito es el más reciente
--     vivo, con su fecha y su monto.
--   · De qué campaña es un pedido (decisión del 26/10 de #101, `pedido_en_la_ventana()`): la campaña cuya
--     ventana de inscripción contiene su `fecha_pedido` (desde el alta, antes de la baja, fuera de los
--     `tramos_afuera`, hasta el día de fin de la campaña; sin recortar a `fecha_inicio`). Un colportor que
--     pasó de la campaña A (de Marta) a la B (de Pedro) y pide hoy: el pedido es de B; Marta no lo ve ni
--     lo decide. La misma regla corrige `pedidos_por_autorizar_por_ciudad` (0111), que contaba por
--     colportor solamente.
--   · Permiso de lectura: ADMIN, o COORDINADOR de la campaña a la que pertenece el pedido
--     (`puede_ver_pedido_de()`, aun terminada o con el colportor dado de baja). La lista, por campaña, con
--     el permiso de campaña de las demás lecturas del panel (42501 / CZ001).
--
-- ## Lo que decide (SECURITY DEFINER, VOLATILE, EXECUTE solo para `authenticated`)
--
--   autorizar_pedido(p_pedido_id, p_cantidades jsonb default null)
--     -> (pedido_id, estado, monto_total, monto_autorizado, reducido, decidido_en, deshacer_hasta, ya_estaba)
--   rechazar_pedido(p_pedido_id, p_motivo)
--     -> (pedido_id, estado, decidido_en, deshacer_hasta, ya_estaba)
--   deshacer_decision_de_pedido(p_pedido_id)
--     -> (pedido_id, estado, ya_estaba)
--
--   · Autorizar: PENDIENTE_AUTORIZACION -> AUTORIZADO. `p_cantidades` es opcional: una lista
--     `[{"producto_id": "...", "cantidad": 3}, ...]` con lo que se autoriza de las líneas que se bajan
--     (Reducir); lo que no se nombra se autoriza entero. Cada cantidad va de 0 a lo pedido (nunca más),
--     un producto no se repite y tiene que estar en el pedido; no se puede dejar todo en cero (eso es
--     rechazar). Una cantidad igual a la pedida se guarda como null. SUMA `monto_autorizado` a la deuda del
--     colportor con la casa editora (`estado_cuenta.deuda_total`, la crea si no existe). El límite de deuda
--     solo avisa: no bloquea (R-ST06). El stock no cambia: entra al pasar a RECIBIDO.
--   · Rechazar: PENDIENTE_AUTORIZACION -> RECHAZADO con motivo obligatorio (no en blanco, hasta 500
--     caracteres; se guarda recortado). No toca la deuda.
--   · Deshacer: dentro de los 8 segundos de lo decidido (el servidor acepta hasta 10: 2 de gracia por la
--     latencia; `deshacer_hasta` sigue siendo a los 8) y solo por quien lo decidió, vuelve a
--     PENDIENTE_AUTORIZACION: si estaba AUTORIZADO resta de la deuda lo mismo que sumó y borra
--     `cantidad_autorizada` y `monto_autorizado`; si estaba RECHAZADO borra el motivo. Pasado el plazo, o
--     con el pedido ya despachado, PE005.
--   · Un reintento no suma dos veces: autorizar un pedido que YO ya autoricé con las mismas cantidades,
--     rechazar uno que YO ya rechacé con el mismo motivo y deshacer uno ya deshecho devuelven el estado
--     actual con `ya_estaba = true`, sin tocar nada. Dos coordinadores a la vez: la fila se bloquea
--     (FOR UPDATE) y el segundo recibe PE002.
--   · Permiso de decisión (más estricto que el de lectura, ante la duda se bloquea): ADMIN, o COORDINADOR
--     de la campaña a la que pertenece el pedido (`pedido_en_la_ventana()`) con el colportor inscripto sin
--     baja y cuyo plazo de escritura siga abierto (hasta 15 días después de su fin, 0020). Quien solo
--     coordinó al colportor en una campaña ya cerrada la ve, pero no le autoriza más pedidos; y la
--     coordinadora de la campaña anterior no ve ni decide lo que el colportor pide en la de otro.
--   · Auditoría obligatoria (HU-STK-003): `pedido_autorizado`, `pedido_rechazado` y
--     `pedido_decision_deshecha`, en la misma transacción. El detalle lleva ids, montos y estados; el
--     motivo del rechazo (texto libre) NO se copia: se nombra por tabla y fila_id.
--
-- ## Errores (todos con mensaje que dice qué hacer)
--
--   42501  sin permiso (sin JWT, sin rol, colportor, coordinador ajeno, campaña cerrada para escribir).
--   CZ001  campaña inexistente (la lista por campaña).
--   PE001  el pedido no existe.
--   PE002  el pedido no está por autorizar (otra persona lo decidió o cambió de estado).
--   PE003  las cantidades a autorizar no sirven (forma, producto repetido o ajeno, más de lo pedido,
--          todo en cero, pedido sin líneas).
--   PE004  el motivo del rechazo falta, está en blanco o pasa de 500 caracteres.
--   PE005  ya no se puede deshacer (pasaron los 8 segundos, el pedido siguió su camino o lo decidió otra
--          persona).
--
-- ## Lo que NO hace (y por qué)
--
--   · No compara con el límite de deuda ni lo devuelve: la decisión de Cristian del 25/10 lo pasa a la
--     campaña (`campania.limite_deuda`, backend-supabase#156), que todavía no existe. Cuando llegue, la
--     lectura suma el límite y «supera el límite por $U X» (archivo de pendientes de esta entrega).
--     `excede_limite` sale tal como lo guardó quien envió el pedido (#102).
--   · No despacha ni recibe (DESPACHADO y RECIBIDO son frente a la casa editora y al colportor), no
--     revierte la deuda de un pedido cancelado ni ajusta la de uno recibido incompleto (HU-STK-002), no
--     manda el push al colportor (HU-NOT-003), no toca transferencias (#106).
--   · No va al sync: `pedido_casa_editora` sigue sin estar en `sync.entidad`. El motivo del rechazo y las
--     cantidades autorizadas le llegan al colportor cuando el contrato del sync los incluya.
--
-- ## Para otros repos
--
--   · front-coordinadores-web (vista 35; el panel de Reducir y Deshacer es #93): POST /rest/v1/rpc/<nombre>
--     con los parámetros de arriba. Los errores PE001..PE005 llegan en `code` del cuerpo de PostgREST.
--   · backend-supabase#155 (renombra `estado_cuenta` a `cuenta_colportor`): la deuda se mueve en UNA
--     función, `mover_deuda_casa_editora()`, y las lecturas de `pedido_contexto` leen la tabla por nombre:
--     el renombre cambia esos sitios.
--   · docs-organizacion: `esquema-datos.md` (columnas nuevas, estados, errores PE) en un issue aparte.
--
-- Forward-only: esta migración no se edita una vez aplicada.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. Columnas nuevas
-- ----------------------------------------------------------------------------

alter table public.pedido_item
  add column cantidad_autorizada integer;

alter table public.pedido_item
  add constraint pedido_item_cantidad_autorizada_check
  check (cantidad_autorizada is null or (cantidad_autorizada >= 0 and cantidad_autorizada <= cantidad));

comment on column public.pedido_item.cantidad_autorizada is
  'Lo que autorizó el coordinador de esta línea (0112, Reducir: decisión de Cristian del 25/10): de 0 a '
  '`cantidad`. null = se autorizó lo pedido. No pisa `cantidad`, que es lo que pidió el colportor.';

alter table public.pedido_casa_editora
  add column monto_autorizado  bigint,
  add column decidido_por      uuid references public.usuario(id),
  add column decidido_en       timestamptz,
  add column motivo_rechazo    text;

-- Hasta ahora ninguna función rechazaba un pedido, así que no debería haber rechazados; si hubiera alguno
-- (cargado a mano), se le deja un motivo para que la regla nueva no tire la migración ni se pierda el pedido.
update public.pedido_casa_editora
   set motivo_rechazo = 'Sin motivo registrado'
 where estado = 'RECHAZADO' and (motivo_rechazo is null or motivo_rechazo !~ '\S');

alter table public.pedido_casa_editora
  add constraint pedido_casa_editora_monto_autorizado_check
  check (monto_autorizado is null or monto_autorizado >= 0),
  add constraint pedido_casa_editora_decision_completa_check
  check ((decidido_por is null) = (decidido_en is null)),
  -- Rechazar exige un motivo (HU-STK-003); el motivo solo existe en un pedido rechazado.
  add constraint pedido_casa_editora_motivo_rechazo_check
  check ((estado = 'RECHAZADO'
            and motivo_rechazo is not null and motivo_rechazo ~ '\S' and length(motivo_rechazo) <= 500)
         or (estado <> 'RECHAZADO' and motivo_rechazo is null));

create index pedido_casa_editora_decidido_por_idx on public.pedido_casa_editora (decidido_por)
  where decidido_por is not null;

comment on column public.pedido_casa_editora.monto_autorizado is
  'Lo que se cargó a la deuda al autorizar, en centavos: cantidad autorizada × precio_unitario de sus '
  'líneas (0112). null mientras nadie autorizó. `monto_total` sigue siendo lo que pidió el colportor.';
comment on column public.pedido_casa_editora.decidido_por is
  'Quien autorizó o rechazó el pedido (0112). Distinto de `coordinador_id`, que es quien lo registró.';
comment on column public.pedido_casa_editora.decidido_en is
  'Cuándo se autorizó o rechazó, con el reloj real (clock_timestamp): desde acá corre el plazo de 8 '
  'segundos para deshacer. null mientras el pedido espera.';
comment on column public.pedido_casa_editora.motivo_rechazo is
  'Por qué se rechazó el pedido («Excede capacidad de pago actual»); obligatorio, no en blanco y de hasta '
  '500 caracteres si estado = RECHAZADO, null en cualquier otro estado. Texto libre del coordinador: vive '
  'solo en la nube y no se copia a audit_log.';

-- ----------------------------------------------------------------------------
-- 2. Piezas internas
-- ----------------------------------------------------------------------------

-- El plazo para deshacer lo decidido (decisión de Cristian del 25/10, «Reducir ped.»: 8 s).
create function public.plazo_para_deshacer_pedido()
returns interval
language sql
immutable
set search_path = ''
as $$
  select interval '8 seconds';
$$;

comment on function public.plazo_para_deshacer_pedido() is
  'Cuánto tiempo, desde decidido_en, se puede deshacer un pedido autorizado o rechazado: 8 segundos '
  '(0112, decisión de Cristian del 25/10). Interna.';

revoke all on function public.plazo_para_deshacer_pedido()
  from public, anon, authenticated, service_role;

-- La gracia que el servidor suma a ese plazo (decisión del 26/10, P3): la pantalla oculta «Deshacer» a los 8 s
-- (`deshacer_hasta`), pero el toque a los 7,9 s llega al servidor un poco después; hasta 10 s se acepta.
create function public.gracia_para_deshacer_pedido()
returns interval
language sql
immutable
set search_path = ''
as $$
  select interval '2 seconds';
$$;

comment on function public.gracia_para_deshacer_pedido() is
  'Cuánto más allá de plazo_para_deshacer_pedido() acepta el servidor un Deshacer (2 segundos, por la '
  'latencia de la red: decisión del 26/10, P3 de #104). Interna (0112).';

revoke all on function public.gracia_para_deshacer_pedido()
  from public, anon, authenticated, service_role;

-- La deuda del colportor con la casa editora se mueve acá y solo acá (la crea si no existe). Interna.
create function public.mover_deuda_casa_editora(p_usuario_id uuid, p_delta bigint)
returns void
language sql
volatile
security definer
set search_path = ''
as $$
  insert into public.estado_cuenta as ec (usuario_id, deuda_total)
  values (p_usuario_id, p_delta)
  on conflict (usuario_id) do update
    set deuda_total = ec.deuda_total + excluded.deuda_total,
        actualizado_en = now();
$$;

comment on function public.mover_deuda_casa_editora(uuid, bigint) is
  'Suma (o resta, con p_delta negativo) a estado_cuenta.deuda_total del colportor; crea la cuenta si no '
  'existe. La llaman autorizar_pedido() y deshacer_decision_de_pedido() (0112). Interna.';

revoke all on function public.mover_deuda_casa_editora(uuid, bigint)
  from public, anon, authenticated, service_role;

-- ¿Este pedido es de la inscripción? La regla de la decisión del 26/10 (#101): un pedido es de la campaña cuya
-- ventana de inscripción contiene su fecha_pedido: desde el alta (sin recortar a fecha_inicio: el que pide
-- libros antes de que arranque es de la campaña en la que ya está inscripto), antes de la baja si la hubo, fuera
-- de los huecos (tramos_afuera) y hasta el día en que termina la campaña (días de Montevideo, ambos incluidos).
-- Interna.
create function public.pedido_en_la_ventana(p_alta timestamptz, p_baja timestamptz, p_afuera tstzrange[],
                                            p_fecha_fin date, p_fecha_pedido timestamptz)
returns boolean
language sql
stable
set search_path = ''
as $$
  select public.inscripcion_cubre_el_instante(p_alta, p_baja, p_afuera, p_fecha_pedido)
     and public.hoy_montevideo(p_fecha_pedido) <= coalesce(p_fecha_fin, 'infinity'::date)
$$;

comment on function public.pedido_en_la_ventana(timestamptz, timestamptz, tstzrange[], date, timestamptz) is
  'true si un pedido hecho en p_fecha_pedido es de esta inscripción: dentro de la ventana de la inscripción '
  '(alta, baja, tramos_afuera) y hasta el día de fin de la campaña (Montevideo). Sin recortar a fecha_inicio. '
  'Interna (0112, decisión del 26/10 de #101).';

revoke all on function public.pedido_en_la_ventana(timestamptz, timestamptz, tstzrange[], date, timestamptz)
  from public, anon, authenticated, service_role;

-- ¿El usuario autenticado puede VER el pedido que este colportor hizo en esa fecha? ADMIN, o coordinador de
-- la campaña a cuya inscripción pertenece el pedido (aun terminada o con el colportor dado de baja). Interna.
create function public.puede_ver_pedido_de(p_colportor_id uuid, p_fecha_pedido timestamptz)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select public.tiene_rol('ADMIN')
      or (public.tiene_rol('COORDINADOR')
          and exists (select 1
                        from public.campania_colportor cc
                        join public.campania c on c.id = cc.campania_id
                       where cc.usuario_id = p_colportor_id
                         and c.deleted_at is null
                         and c.coordinador_id = auth.uid()
                         and public.pedido_en_la_ventana(cc.created_at, cc.deleted_at, cc.tramos_afuera,
                                                         c.fecha_fin, p_fecha_pedido)));
$$;

comment on function public.puede_ver_pedido_de(uuid, timestamptz) is
  'true si el usuario autenticado es ADMIN, o COORDINADOR de la campaña a cuya inscripción de '
  'p_colportor_id pertenece un pedido hecho en p_fecha_pedido (pedido_en_la_ventana). No ve lo que el '
  'colportor pidió en la campaña de otro coordinador. Interna (0112).';

revoke all on function public.puede_ver_pedido_de(uuid, timestamptz)
  from public, anon, authenticated, service_role;

-- ¿El usuario autenticado puede AUTORIZAR o RECHAZAR el pedido de este colportor hecho en esa fecha? ADMIN, o
-- coordinador de la campaña a cuya inscripción (sin baja) pertenece el pedido, con el plazo de escritura
-- abierto (0020). Interna.
create function public.puede_decidir_pedido_de(p_colportor_id uuid, p_fecha_pedido timestamptz)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select public.tiene_rol('ADMIN')
      or (public.tiene_rol('COORDINADOR')
          and exists (select 1
                        from public.campania_colportor cc
                        join public.campania c on c.id = cc.campania_id
                       where cc.usuario_id = p_colportor_id
                         and cc.deleted_at is null
                         and c.deleted_at is null
                         and c.coordinador_id = auth.uid()
                         and public.escritura_dentro_de_plazo(c.fecha_fin)
                         and public.pedido_en_la_ventana(cc.created_at, cc.deleted_at, cc.tramos_afuera,
                                                         c.fecha_fin, p_fecha_pedido)));
$$;

comment on function public.puede_decidir_pedido_de(uuid, timestamptz) is
  'true si el usuario autenticado es ADMIN, o COORDINADOR de la campaña a cuya inscripción (sin baja) de '
  'p_colportor_id pertenece un pedido hecho en p_fecha_pedido (pedido_en_la_ventana) y cuyo plazo de '
  'escritura (fin + 15 días, 0020) sigue abierto. Más estricta que puede_ver_pedido_de() a propósito: '
  'ver y decidir no es lo mismo. Interna (0112).';

revoke all on function public.puede_decidir_pedido_de(uuid, timestamptz)
  from public, anon, authenticated, service_role;

-- El pedido, con el permiso ya comprobado. p_escribir = true lo bloquea (FOR UPDATE) y pide el permiso de
-- decisión; false pide el de lectura. Interna: la llaman las RPC de abajo, que son SECURITY DEFINER.
create function public.pedido_para(p_pedido_id uuid, p_escribir boolean)
returns public.pedido_casa_editora
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_pedido  public.pedido_casa_editora;
begin
  if auth.uid() is null or not (public.tiene_rol('ADMIN') or public.tiene_rol('COORDINADOR')) then
    raise exception 'Solo el coordinador de la campaña o un administrador puede ver y decidir los pedidos. Entrá con la cuenta del coordinador de esta campaña.'
      using errcode = 'insufficient_privilege';
  end if;

  if p_escribir then
    select * into v_pedido
      from public.pedido_casa_editora pe
     where pe.id = p_pedido_id and pe.deleted_at is null
       for update;
  else
    select * into v_pedido
      from public.pedido_casa_editora pe
     where pe.id = p_pedido_id and pe.deleted_at is null;
  end if;
  if not found then
    raise exception 'El pedido no existe o ya se dio de baja. Recargá la bandeja de pedidos.'
      using errcode = 'PE001';
  end if;

  if p_escribir then
    if not public.puede_decidir_pedido_de(v_pedido.colportor_id, v_pedido.fecha_pedido) then
      raise exception 'No podés decidir este pedido: no es de una campaña tuya que siga abierta (el colportor tiene que estar inscripto en ella cuando lo pidió). Si es un error, pedile a un administrador que lo decida.'
        using errcode = 'insufficient_privilege';
    end if;
  elsif not public.puede_ver_pedido_de(v_pedido.colportor_id, v_pedido.fecha_pedido) then
    raise exception 'Este pedido no es de un colportor de tus campañas. Elegí uno de la bandeja.'
      using errcode = 'insufficient_privilege';
  end if;

  return v_pedido;
end;
$$;

comment on function public.pedido_para(uuid, boolean) is
  'El pedido de p_pedido_id con el permiso comprobado (0112): lectura = ADMIN o el coordinador de la campaña '
  'a la que pertenece el pedido; escritura = además campaña abierta, y bloquea la fila. 42501 sin permiso; '
  'PE001 si no existe. Interna.';

revoke all on function public.pedido_para(uuid, boolean)
  from public, anon, authenticated, service_role;

-- ----------------------------------------------------------------------------
-- 3. pedidos_de_campania: la bandeja
-- ----------------------------------------------------------------------------

create function public.pedidos_de_campania(p_campania_id uuid)
returns table (pedido_id uuid, colportor_id uuid, nombre text, apellido text,
               ciudad_id uuid, ciudad_nombre text, departamento text, de_baja boolean,
               estado text, origen text, fecha_pedido timestamptz,
               productos integer, unidades integer, unidades_autorizadas integer,
               monto_total bigint, monto_autorizado bigint, excede_limite boolean,
               decidido_en timestamptz, motivo_rechazo text, deshacer_hasta timestamptz)
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
    raise exception 'Solo el coordinador de la campaña o un administrador puede ver sus pedidos. Entrá con la cuenta del coordinador de esta campaña.'
      using errcode = 'insufficient_privilege';
  end if;
  if v_motivo is distinct from 'CAMPANIA_TERMINADA' then
    perform public.lanzar_motivo_mapa(v_motivo);
  end if;

  return query
    select pe.id,
           i.usuario_id,
           usr.nombre,
           usr.apellido,
           ciu.id,
           ciu.nombre,
           ciu.departamento,
           (i.deleted_at is not null),
           pe.estado,
           pe.origen,
           pe.fecha_pedido,
           ln.productos,
           ln.unidades,
           case when pe.monto_autorizado is null then null else ln.unidades_autorizadas end,
           pe.monto_total,
           pe.monto_autorizado,
           pe.excede_limite,
           pe.decidido_en,
           pe.motivo_rechazo,
           case when pe.estado in ('AUTORIZADO', 'RECHAZADO')
                then pe.decidido_en + public.plazo_para_deshacer_pedido() end
      from public.campania_colportor i
      join public.campania ca on ca.id = i.campania_id
      join public.pedido_casa_editora pe
        on pe.colportor_id = i.usuario_id
       and pe.deleted_at is null
       and pe.estado in ('PENDIENTE_AUTORIZACION', 'AUTORIZADO', 'DESPACHADO', 'RECIBIDO', 'RECHAZADO')
       and public.pedido_en_la_ventana(i.created_at, i.deleted_at, i.tramos_afuera, ca.fecha_fin, pe.fecha_pedido)
      join public.usuario usr on usr.id = i.usuario_id
      left join public.zona z
             on z.id = i.zona_id and z.deleted_at is null and i.deleted_at is null
      left join public.campania_ciudad cc
             on cc.id = z.campania_ciudad_id and cc.deleted_at is null
      left join public.ciudad ciu on ciu.id = cc.ciudad_id
     cross join lateral (
       select (count(*))::integer as productos,
              (coalesce(sum(it.cantidad), 0))::integer as unidades,
              (coalesce(sum(coalesce(it.cantidad_autorizada, it.cantidad)), 0))::integer as unidades_autorizadas
         from public.pedido_item it
        where it.pedido_id = pe.id and it.deleted_at is null
     ) ln
     where i.campania_id = p_campania_id
     order by pe.fecha_pedido desc, pe.id;
end;
$$;

comment on function public.pedidos_de_campania(uuid) is
  'Vista 35, HU-STK-003 (0112, backend-supabase#104): los pedidos a la casa editora de los colportores de '
  'la campaña (los que hizo mientras estaba inscripto en ella y hasta que terminó: no los que pidió en la '
  'campaña de otro coordinador) en los cinco estados de las pestañas (por autorizar, autorizado, '
  'despachado, recibido, rechazado; sin borradores ni cancelados), el más reciente primero, con la ciudad de la zona actual del '
  'colportor, lo pedido y lo autorizado, el motivo del rechazo y hasta cuándo se puede deshacer lo '
  'decidido. Errores: 42501 sin permiso; CZ001 campaña inexistente. Una campaña terminada se lee.';

revoke all on function public.pedidos_de_campania(uuid)
  from public, anon, authenticated, service_role;
grant execute on function public.pedidos_de_campania(uuid) to authenticated;

-- ----------------------------------------------------------------------------
-- 4. pedido_lineas y pedido_contexto: el detalle para decidir
-- ----------------------------------------------------------------------------

create function public.pedido_lineas(p_pedido_id uuid)
returns table (producto_id uuid, producto_nombre text, producto_tipo text,
               cantidad integer, cantidad_autorizada integer, precio_unitario bigint,
               subtotal bigint, subtotal_autorizado bigint, stock integer)
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_pedido  public.pedido_casa_editora;
begin
  v_pedido := public.pedido_para(p_pedido_id, false);

  return query
    select it.producto_id,
           pr.nombre,
           pr.tipo,
           it.cantidad,
           it.cantidad_autorizada,
           it.precio_unitario,
           it.cantidad::bigint * it.precio_unitario,
           coalesce(it.cantidad_autorizada, it.cantidad)::bigint * it.precio_unitario,
           coalesce(st.cantidad_disponible, 0)
      from public.pedido_item it
      join public.producto pr on pr.id = it.producto_id
      left join public.stock st
             on st.usuario_id = v_pedido.colportor_id
            and st.producto_id = it.producto_id
            and st.deleted_at is null
     where it.pedido_id = v_pedido.id and it.deleted_at is null
     order by pr.nombre, it.producto_id;
end;
$$;

comment on function public.pedido_lineas(uuid) is
  'Vista 35, HU-STK-003 (0112): las líneas del pedido con su costo unitario de la casa editora (la foto de '
  'precio_base_compra al pedir), lo pedido, lo autorizado (null = lo pedido), los subtotales y el stock que '
  'el colportor tiene hoy de ese producto (puede ser negativo, tal cual). Errores: 42501 sin permiso; '
  'PE001 si el pedido no existe.';

revoke all on function public.pedido_lineas(uuid)
  from public, anon, authenticated, service_role;
grant execute on function public.pedido_lineas(uuid) to authenticated;

create function public.pedido_contexto(p_pedido_id uuid)
returns table (colportor_id uuid, nombre text, apellido text, estado text,
               monto_total bigint, monto_autorizado bigint,
               deuda_actual bigint, deuda_con_pedido bigint, por_cobrar bigint,
               libros_por_entregar integer,
               ultimo_deposito_fecha timestamptz, ultimo_deposito_monto bigint)
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_pedido  public.pedido_casa_editora;
begin
  v_pedido := public.pedido_para(p_pedido_id, false);

  return query
    select v_pedido.colportor_id,
           usr.nombre,
           usr.apellido,
           v_pedido.estado,
           v_pedido.monto_total,
           v_pedido.monto_autorizado,
           coalesce(cu.deuda_total, 0),
           coalesce(cu.deuda_total, 0)
             + case when v_pedido.estado = 'PENDIENTE_AUTORIZACION' then v_pedido.monto_total else 0 end,
           coalesce(cu.dinero_por_cobrar, 0),
           (select coalesce(sum(en.cantidad), 0)::integer
              from public.venta v
              join public.entrega en on en.venta_id = v.id and en.deleted_at is null and en.pendiente
             where v.colportor_id = v_pedido.colportor_id and v.deleted_at is null),
           dep.fecha,
           dep.monto
      from public.usuario usr
      left join public.estado_cuenta cu
             on cu.usuario_id = usr.id and cu.deleted_at is null
      left join lateral (
        select d.fecha, d.monto
          from public.deposito d
         where d.colportor_id = usr.id and d.deleted_at is null
           and d.concepto = 'CASA_EDITORA'
         order by d.fecha desc, d.id
         limit 1
      ) dep on true
     where usr.id = v_pedido.colportor_id;
end;
$$;

comment on function public.pedido_contexto(uuid) is
  'Vista 35, HU-STK-003 (0112): la cuenta del colportor para decidir su pedido: deuda actual '
  '(estado_cuenta.deuda_total), deuda con el pedido (la actual más el pedido mientras está por autorizar), '
  'por cobrar (estado_cuenta.dinero_por_cobrar), unidades vendidas por entregar y su último depósito. Solo '
  'montos y cantidades: ni clientes ni cobros. Errores: 42501 sin permiso; PE001 si el pedido no existe. '
  'El límite de deuda (backend-supabase#156) se suma cuando exista.';

revoke all on function public.pedido_contexto(uuid)
  from public, anon, authenticated, service_role;
grant execute on function public.pedido_contexto(uuid) to authenticated;

-- ----------------------------------------------------------------------------
-- 5. autorizar_pedido
-- ----------------------------------------------------------------------------

create function public.autorizar_pedido(p_pedido_id uuid, p_cantidades jsonb default null)
returns table (pedido_id uuid, estado text, monto_total bigint, monto_autorizado bigint,
               reducido boolean, decidido_en timestamptz, deshacer_hasta timestamptz,
               ya_estaba boolean)
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_pedido     public.pedido_casa_editora;
  v_prods      uuid[] := array[]::uuid[];
  v_cants      integer[] := array[]::integer[];
  v_el         jsonb;
  v_prod       uuid;
  v_cant       integer;
  v_monto      bigint;
  v_unidades   bigint;
  v_igual      boolean;
  v_reducido   boolean;
  v_ahora      timestamptz := clock_timestamp();
begin
  v_pedido := public.pedido_para(p_pedido_id, true);

  -- Lo que se baja (Reducir): una lista de {producto_id, cantidad}. null o [] = autorizar todo.
  if p_cantidades is not null then
    if jsonb_typeof(p_cantidades) <> 'array' then
      raise exception 'Las cantidades a autorizar tienen que ser una lista de {producto_id, cantidad}. Recargá el pedido y volvé a intentar.'
        using errcode = 'PE003';
    end if;
    for v_el in select e.value from jsonb_array_elements(p_cantidades) e loop
      if jsonb_typeof(v_el) <> 'object' then
        raise exception 'Cada cantidad a autorizar tiene que ser {producto_id, cantidad}. Recargá el pedido y volvé a intentar.'
          using errcode = 'PE003';
      end if;
      begin
        v_prod := (v_el ->> 'producto_id')::uuid;
        v_cant := (v_el ->> 'cantidad')::integer;
      exception when invalid_text_representation or numeric_value_out_of_range then
        raise exception 'Cada cantidad a autorizar tiene que traer un producto válido y una cantidad entera. Corregila y volvé a intentar.'
          using errcode = 'PE003';
      end;
      if v_prod is null or v_cant is null or v_cant < 0 then
        raise exception 'Cada cantidad a autorizar tiene que traer un producto y una cantidad de 0 en adelante. Corregila y volvé a intentar.'
          using errcode = 'PE003';
      end if;
      v_prods := v_prods || v_prod;
      v_cants := v_cants || v_cant;
    end loop;

    if cardinality(v_prods) <> (select count(distinct x.p) from unnest(v_prods) x(p)) then
      raise exception 'Un producto aparece dos veces en las cantidades a autorizar. Dejá una sola cantidad por producto.'
        using errcode = 'PE003';
    end if;
    if exists (select 1
                 from unnest(v_prods, v_cants) x(p, c)
                 left join public.pedido_item it
                        on it.pedido_id = v_pedido.id and it.producto_id = x.p and it.deleted_at is null
                where it.id is null or x.c > it.cantidad) then
      raise exception 'No se puede autorizar más de lo que pidió el colportor, ni un producto que no está en el pedido. Bajá la cantidad o sacá el producto y volvé a intentar.'
        using errcode = 'PE003';
    end if;
  end if;

  -- Lo que quedaría autorizado: monto, unidades, si coincide con lo ya autorizado y si baja algo.
  select coalesce(sum(coalesce(x.c, it.cantidad)::bigint * it.precio_unitario), 0),
         coalesce(sum(coalesce(x.c, it.cantidad)), 0),
         coalesce(bool_and(coalesce(x.c, it.cantidad) = coalesce(it.cantidad_autorizada, it.cantidad)), false),
         coalesce(bool_or(coalesce(x.c, it.cantidad) <> it.cantidad), false)
    into v_monto, v_unidades, v_igual, v_reducido
    from public.pedido_item it
    left join unnest(v_prods, v_cants) x(p, c) on x.p = it.producto_id
   where it.pedido_id = v_pedido.id and it.deleted_at is null;

  -- Un reintento de quien ya lo autorizó, con las mismas cantidades, no suma la deuda dos veces.
  if v_pedido.estado = 'AUTORIZADO' and v_pedido.decidido_por = auth.uid() and v_igual then
    return query
      select pe.id, pe.estado, pe.monto_total, pe.monto_autorizado,
             exists (select 1 from public.pedido_item it
                      where it.pedido_id = pe.id and it.deleted_at is null and it.cantidad_autorizada is not null),
             pe.decidido_en, pe.decidido_en + public.plazo_para_deshacer_pedido(), true
        from public.pedido_casa_editora pe
       where pe.id = v_pedido.id;
    return;
  end if;

  if v_pedido.estado <> 'PENDIENTE_AUTORIZACION' then
    raise exception 'Este pedido ya no está por autorizar: otra persona lo decidió o siguió su camino. Recargá la bandeja para ver cómo quedó.'
      using errcode = 'PE002';
  end if;
  if v_unidades = 0 then
    raise exception 'No se puede autorizar un pedido sin nada que autorizar. Para no darle ninguno, rechazalo con un motivo.'
      using errcode = 'PE003';
  end if;

  if cardinality(v_prods) > 0 then
    update public.pedido_item it
       set cantidad_autorizada = (select case when x.c = it.cantidad then null else x.c end
                                    from unnest(v_prods, v_cants) x(p, c)
                                   where x.p = it.producto_id)
     where it.pedido_id = v_pedido.id and it.deleted_at is null and it.producto_id = any (v_prods);
  end if;

  update public.pedido_casa_editora pe
     set estado = 'AUTORIZADO',
         monto_autorizado = v_monto,
         decidido_por = auth.uid(),
         decidido_en = v_ahora
   where pe.id = v_pedido.id;

  perform public.mover_deuda_casa_editora(v_pedido.colportor_id, v_monto);

  perform auditoria.registrar(
    'pedido_autorizado', 'pedido_casa_editora', v_pedido.id, v_pedido.colportor_id,
    jsonb_build_object('monto_total', v_pedido.monto_total,
                       'monto_autorizado', v_monto,
                       'reducido', v_reducido,
                       'excede_limite', v_pedido.excede_limite));

  return query
    select v_pedido.id, 'AUTORIZADO'::text, v_pedido.monto_total, v_monto, v_reducido, v_ahora,
           v_ahora + public.plazo_para_deshacer_pedido(), false;
end;
$$;

comment on function public.autorizar_pedido(uuid, jsonb) is
  'Vista 35, HU-STK-003 (0112, backend-supabase#104): PENDIENTE_AUTORIZACION -> AUTORIZADO. p_cantidades '
  '(opcional) = [{producto_id, cantidad}] con lo que se autoriza de las líneas que se bajan (Reducir); lo '
  'demás se autoriza entero. Suma monto_autorizado a la deuda del colportor y deja el evento '
  'pedido_autorizado en audit_log. El límite de deuda solo avisa. Un reintento de quien ya lo autorizó con '
  'las mismas cantidades devuelve ya_estaba = true sin sumar de nuevo. Errores: 42501; PE001; PE002 (ya no '
  'está por autorizar); PE003 (cantidades).';

revoke all on function public.autorizar_pedido(uuid, jsonb)
  from public, anon, authenticated, service_role;
grant execute on function public.autorizar_pedido(uuid, jsonb) to authenticated;

-- ----------------------------------------------------------------------------
-- 6. rechazar_pedido
-- ----------------------------------------------------------------------------

create function public.rechazar_pedido(p_pedido_id uuid, p_motivo text)
returns table (pedido_id uuid, estado text, decidido_en timestamptz, deshacer_hasta timestamptz,
               ya_estaba boolean)
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_pedido  public.pedido_casa_editora;
  v_motivo  text := regexp_replace(p_motivo, '^\s+|\s+$', '', 'g');
  v_ahora   timestamptz := clock_timestamp();
begin
  v_pedido := public.pedido_para(p_pedido_id, true);

  if v_motivo is null or v_motivo = '' then
    raise exception 'Escribí el motivo del rechazo: es lo que va a leer el colportor.'
      using errcode = 'PE004';
  end if;
  if length(v_motivo) > 500 then
    raise exception 'El motivo del rechazo pasa de 500 caracteres. Acortalo y volvé a intentar.'
      using errcode = 'PE004';
  end if;

  -- Un reintento de quien ya lo rechazó, con el mismo motivo, no hace nada.
  if v_pedido.estado = 'RECHAZADO' and v_pedido.decidido_por = auth.uid()
     and v_pedido.motivo_rechazo = v_motivo then
    return query
      select pe.id, pe.estado, pe.decidido_en, pe.decidido_en + public.plazo_para_deshacer_pedido(), true
        from public.pedido_casa_editora pe
       where pe.id = v_pedido.id;
    return;
  end if;

  if v_pedido.estado <> 'PENDIENTE_AUTORIZACION' then
    raise exception 'Este pedido ya no está por autorizar: otra persona lo decidió o siguió su camino. Recargá la bandeja para ver cómo quedó.'
      using errcode = 'PE002';
  end if;

  update public.pedido_casa_editora pe
     set estado = 'RECHAZADO',
         motivo_rechazo = v_motivo,
         decidido_por = auth.uid(),
         decidido_en = v_ahora
   where pe.id = v_pedido.id;

  -- El motivo es texto libre: no se copia a la auditoría, se nombra por tabla y fila_id.
  perform auditoria.registrar(
    'pedido_rechazado', 'pedido_casa_editora', v_pedido.id, v_pedido.colportor_id,
    jsonb_build_object('monto_total', v_pedido.monto_total,
                       'excede_limite', v_pedido.excede_limite));

  return query
    select v_pedido.id, 'RECHAZADO'::text, v_ahora, v_ahora + public.plazo_para_deshacer_pedido(), false;
end;
$$;

comment on function public.rechazar_pedido(uuid, text) is
  'Vista 35, HU-STK-003 (0112, backend-supabase#104): PENDIENTE_AUTORIZACION -> RECHAZADO con motivo '
  'obligatorio (no en blanco, hasta 500 caracteres, se guarda recortado). No toca la deuda. Deja el evento '
  'pedido_rechazado en audit_log, sin el motivo. Un reintento de quien ya lo rechazó con el mismo motivo '
  'devuelve ya_estaba = true. Errores: 42501; PE001; PE002; PE004 (motivo).';

revoke all on function public.rechazar_pedido(uuid, text)
  from public, anon, authenticated, service_role;
grant execute on function public.rechazar_pedido(uuid, text) to authenticated;

-- ----------------------------------------------------------------------------
-- 7. deshacer_decision_de_pedido
-- ----------------------------------------------------------------------------

create function public.deshacer_decision_de_pedido(p_pedido_id uuid)
returns table (pedido_id uuid, estado text, ya_estaba boolean)
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_pedido  public.pedido_casa_editora;
begin
  v_pedido := public.pedido_para(p_pedido_id, true);

  -- Un reintento de deshacer: ya volvió a esperar y nadie lo volvió a decidir.
  if v_pedido.estado = 'PENDIENTE_AUTORIZACION' and v_pedido.decidido_en is null then
    return query select v_pedido.id, v_pedido.estado, true;
    return;
  end if;

  if v_pedido.estado not in ('AUTORIZADO', 'RECHAZADO') then
    raise exception 'Este pedido ya siguió su camino y no se puede deshacer. Recargá la bandeja para ver cómo quedó.'
      using errcode = 'PE005';
  end if;
  if v_pedido.decidido_por is distinct from auth.uid() then
    raise exception 'Solo quien decidió el pedido puede deshacerlo. Recargá la bandeja para ver cómo quedó.'
      using errcode = 'PE005';
  end if;
  if clock_timestamp() > v_pedido.decidido_en + public.plazo_para_deshacer_pedido()
                          + public.gracia_para_deshacer_pedido() then
    raise exception 'Pasaron más de 8 segundos: la decisión ya no se puede deshacer. Si hace falta, pedile al colportor que lo vuelva a pedir.'
      using errcode = 'PE005';
  end if;

  if v_pedido.estado = 'AUTORIZADO' then
    perform public.mover_deuda_casa_editora(v_pedido.colportor_id, -v_pedido.monto_autorizado);
    update public.pedido_item it
       set cantidad_autorizada = null
     where it.pedido_id = v_pedido.id and it.cantidad_autorizada is not null;
  end if;

  update public.pedido_casa_editora pe
     set estado = 'PENDIENTE_AUTORIZACION',
         monto_autorizado = null,
         motivo_rechazo = null,
         decidido_por = null,
         decidido_en = null
   where pe.id = v_pedido.id;

  perform auditoria.registrar(
    'pedido_decision_deshecha', 'pedido_casa_editora', v_pedido.id, v_pedido.colportor_id,
    jsonb_build_object('decision_deshecha', v_pedido.estado,
                       'monto_total', v_pedido.monto_total,
                       'monto_autorizado', v_pedido.monto_autorizado));

  return query select v_pedido.id, 'PENDIENTE_AUTORIZACION'::text, false;
end;
$$;

comment on function public.deshacer_decision_de_pedido(uuid) is
  'Vista 35, HU-STK-003 (0112, backend-supabase#104, decisión «Reducir ped.» del 25/10): vuelve a '
  'PENDIENTE_AUTORIZACION un pedido AUTORIZADO o RECHAZADO dentro de los 8 segundos de decidido y solo por '
  'quien lo decidió. Si estaba autorizado, resta de la deuda lo que sumó y borra las cantidades '
  'autorizadas; si estaba rechazado, borra el motivo. Deja el evento pedido_decision_deshecha en '
  'audit_log. Un reintento sobre un pedido ya deshecho devuelve ya_estaba = true. Errores: 42501; PE001; '
  'PE005 (fuera de plazo, ya siguió su camino o lo decidió otra persona).';

revoke all on function public.deshacer_decision_de_pedido(uuid)
  from public, anon, authenticated, service_role;
grant execute on function public.deshacer_decision_de_pedido(uuid) to authenticated;

-- ----------------------------------------------------------------------------
-- 8. pedidos_por_autorizar_por_ciudad (0111) con la ventana de la inscripción
-- ----------------------------------------------------------------------------

-- Mismo cuerpo que en 0111, más la ventana: el aviso de Stock cuenta los pedidos de ESTA campaña, no los que el
-- colportor hizo en la de otro coordinador. Los privilegios no cambian (create or replace los conserva).
create or replace function public.pedidos_por_autorizar_por_ciudad(p_campania_id uuid)
returns table (ciudad_id uuid, ciudad_nombre text, departamento text, pedidos integer)
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
    raise exception 'Solo el coordinador de la campaña o un administrador puede ver sus pedidos. Entrá con la cuenta del coordinador de esta campaña.'
      using errcode = 'insufficient_privilege';
  end if;
  if v_motivo is distinct from 'CAMPANIA_TERMINADA' then
    perform public.lanzar_motivo_mapa(v_motivo);
  end if;

  return query
    select ciu.id,
           ciu.nombre,
           ciu.departamento,
           (count(*))::integer
      from public.campania_colportor i
      left join public.zona z
             on z.id = i.zona_id and z.deleted_at is null and i.deleted_at is null
      left join public.campania_ciudad cc
             on cc.id = z.campania_ciudad_id and cc.deleted_at is null
      left join public.ciudad ciu on ciu.id = cc.ciudad_id
      join public.campania ca on ca.id = i.campania_id
      join public.pedido_casa_editora pe
        on pe.colportor_id = i.usuario_id
       and pe.estado = 'PENDIENTE_AUTORIZACION'
       and pe.deleted_at is null
       and public.pedido_en_la_ventana(i.created_at, i.deleted_at, i.tramos_afuera, ca.fecha_fin, pe.fecha_pedido)
     where i.campania_id = p_campania_id
     group by ciu.id, ciu.nombre, ciu.departamento
     order by ciu.nombre nulls last, ciu.id;
end;
$$;

comment on function public.pedidos_por_autorizar_por_ciudad(uuid) is
  'Vista 34, HU-STK-010 (0111, backend-supabase#101, decisión «Pedidos stock» del 25/10): cuántos pedidos a '
  'la casa editora esperan autorización (estado PENDIENTE_AUTORIZACION, vivos) por ciudad de la zona actual '
  'del colportor de la campaña (ciudad null = sin ciudad). Solo las ciudades con al menos uno; solo el '
  'número. Solo los pedidos de esta campaña (0112, decisión del 26/10: los hechos dentro de la ventana de la '
  'inscripción, no los que el colportor pidió en la campaña de otro coordinador). Errores: 42501 sin permiso; '
  'CZ001 campaña inexistente. Una campaña terminada se lee.';
