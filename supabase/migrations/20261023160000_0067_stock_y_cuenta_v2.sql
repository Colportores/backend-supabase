-- ============================================================================
-- 0067 · Stock y cuenta (V2): alquiler, beca con monto, límite de pedido, pedidos a la casa editora,
--        stock, transferencias, depósitos, tickets y el snapshot de la cuenta (backend-supabase#100)
--
-- Decisiones de Cristian del 21/10 (reunión del 05/10 con los coordinadores de Uruguay,
-- docs-organizacion#69, C4 a C8): ver `esquema-datos.md` → «Stock y cuenta (V2)» y las HU-STK-001..010,
-- HU-CTA-004/007, HU-COB-007..009 y HU-BEC-006. Es V2: se conecta después del 20/11 (plan-sprints §5).
-- Se escribe ahora para no rehacerlo. Esta migración es SOLO ESQUEMA: ninguna regla de negocio corre
-- todavía (ni la deuda al autorizar, ni el stock al recibir, ni validar un ticket).
--
-- ## Qué suma a lo que ya existe (solo columnas opcionales; ninguna fila se toca)
--
--   · `campania.alquiler_monto` (bigint, centavos, null = la campaña no cobra alquiler, >= 0).
--   · `campania_colportor.tipo_beca` (null | 'MEDIA' | 'COMPLETA'), `meta_monto_ces` (bigint, centavos,
--     >= 0) y `limite_pedido` (bigint, centavos, >= 0, null = sin límite). Van al pull del colportor con
--     su inscripción (la entidad serializa las columnas de la tabla, sin lista aparte): así la app sabe
--     su meta y su límite sin conexión. Solo las cambian el ADMIN o el coordinador DE ESA campaña
--     (trigger `campania_colportor_beca_y_limite`, 42501): la política de UPDATE de 0003 deja a
--     cualquier coordinador tocar cualquier inscripción y acá no se agranda ese hueco con dinero.
--
-- ## Tablas nuevas (todas vacías; nada que migrar)
--
--   · `stock` — inventario en mano del colportor: una fila por colportor y producto.
--   · `pedido_casa_editora` + `pedido_item` — el pedido del colportor (o registrado por el coordinador a
--     su nombre) con `origen` y `excede_limite`; las líneas guardan la foto de `precio_base_compra`.
--   · `movimiento_stock` — histórico: entrada por pedido recibido, salida por entrega o transferencia.
--   · `transferencia_stock` + `transferencia_item` — entre colportores, con autorización.
--   · `deposito` — con `destino` (BANCO / OFICINA / RETIRO_COORDINADOR) y `concepto` (CASA_EDITORA /
--     ALQUILER).
--   · `ticket` — comprobante con foto, fecha, número de autorización, tarjeta (crédito/débito y marca),
--     monto y estado PENDIENTE / VALIDADO / RECHAZADO. Es también SU HISTORIAL (HU-COB-009): un ticket
--     resuelto no se vuelve a abrir (rechazado = se sube uno nuevo; validado = una corrección es un
--     movimiento nuevo), así que cada fila ya es la historia completa de ese comprobante y no hace
--     falta una tabla de cambios de estado. El registro de quién cambió qué es el `audit_log` de la nube
--     (RA-SE05), que todavía no existe.
--   · `estado_cuenta` — el snapshot de la deuda, con `deuda_alquiler` aparte de la deuda con la casa
--     editora. OJO con el nombre: ya existe la FUNCIÓN `estado_cuenta()` (0004, devuelve ACTIVA /
--     PENDIENTE_ASIGNACION / SUSPENDIDA). Conviven (una es tabla, la otra función, no se pisan), pero
--     conviene renombrar una de las dos: pendiente de decisión.
--
-- ## Estados (el esquema y la HU no coincidían: ver el archivo de pendientes de esta entrega)
--
-- `esquema-datos.md` decía PENDIENTE / AUTORIZADO / DESPACHADO / RECIBIDO / CANCELADO; las HU-STK-001..009
-- y el canvas de la vista 35 dicen «Por autorizar» / «Autorizado» / «Despachado» / «Recibido» /
-- «Rechazado» (más BORRADOR para el pedido que registra el coordinador, HU-STK-001). Gana el canvas y,
-- donde no dice, la HU (mapa de decisiones §1.3); CANCELADO se queda porque la HU-STK-002 y la
-- HU-STK-009 cancelan pedidos. Como las tablas son nuevas, no se renombra ni se quita nada:
--   · pedido: BORRADOR, PENDIENTE_AUTORIZACION, AUTORIZADO, DESPACHADO, RECIBIDO, RECHAZADO, CANCELADO.
--   · transferencia: PENDIENTE_AUTORIZACION, AUTORIZADO, EJECUTADO, RECHAZADO, CANCELADO.
--   · ticket: PENDIENTE, VALIDADO, RECHAZADO (S66: RECHAZADO absorbe a INCONSISTENTE).
--
-- ## Permisos (ante la duda se bloquea)
--
--   · LEE: el dueño (el colportor), el ADMIN y el coordinador de una campaña donde el colportor está
--     inscripto (`coordina_al_colportor()`, incluidas las inscripciones dadas de baja: la deuda de quien
--     se fue no desaparece). Una transferencia la ven las dos puntas. Las bajas lógicas se incluyen.
--   · ESCRIBE: nadie con JWT. No hay política de INSERT ni de UPDATE, ni privilegio: quién crea un pedido,
--     quién autoriza, quién valida un ticket y por qué camino (sync o RPC) es la conexión de V2 y todavía
--     no está decidido. Escribe el servidor (service_role).
--   · Ninguna tabla va a `sync.entidad` ni a Realtime: el contrato de sync no se toca acá (decisión de
--     Cristian: un PR de docs aparte), igual que `precio_general` (0034).
--   · El coordinador ve montos y estados, nunca datos de clientes: ninguna tabla los tiene.
--
-- ## Lo que NO hace (y por qué)
--
--   · No calcula `excede_limite` ni lo compara con nada: el esquema dice «el monto superaba el límite»,
--     el canvas dice «la deuda total con el pedido supera el límite» y S64 deja abierta la unidad.
--   · No carga la deuda al autorizar, no suma el stock al recibir, no descuenta al entregar ni al
--     transferir, no acredita al validar un ticket, no recalcula `estado_cuenta` (HU-STK-002/007,
--     HU-COB-008, HU-CTA-*).
--   · No deriva `meta_libros` ni `meta_monto_ces` del `tipo_beca` (necesita `carrera` y `meta_beca`,
--     Becas V2, HU-BEC-001).
--   · No toca `cobranza` (el esquema le suma `ticket_id`; cobranza es una entidad de push y cambiarla
--     es parte de la conexión del sync).
--
-- ## Los datos
--
-- Solo se agregan columnas opcionales a `campania` y `campania_colportor`: ninguna fila se modifica,
-- ningún `sync_version` ni `xmin_w` cambia, ningún teléfono re-descarga nada. Lo prueba el caso
-- `tests_migracion/0067_ok`.
--
-- ## Para otros repos
--
--   · front-colportores-mobile: el pull de `campania` y de `campania_colportor` trae las columnas
--     nuevas (null hasta que alguien las cargue); la tabla local tiene que tolerarlas.
--   · docs-organizacion: `esquema-datos.md` (estados del pedido y de la transferencia, `pedido_item`,
--     `transferencia_item`, `estado_cuenta.id`, ticket sin `url_local`), contrato del sync cuando estas
--     tablas entren.
--
-- Forward-only: esta migración no se edita una vez aplicada.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. Alquiler de la campaña
-- ----------------------------------------------------------------------------

alter table public.campania
  add column alquiler_monto bigint;

alter table public.campania
  add constraint campania_alquiler_monto_check
  check (alquiler_monto is null or alquiler_monto >= 0);

comment on column public.campania.alquiler_monto is
  'Alquiler de la campaña en centavos: monto fijo y único para todos los colportores inscriptos '
  '(decisión de Cristian, 21/10, docs#69, HU-CTA-007). null = la campaña no cobra alquiler. Es una deuda '
  'aparte de la de la casa editora y no bloquea nada.';

-- ----------------------------------------------------------------------------
-- 2. Beca con monto y límite de pedido, por inscripción
-- ----------------------------------------------------------------------------

alter table public.campania_colportor
  add column tipo_beca       text,
  add column meta_monto_ces  bigint,
  add column limite_pedido   bigint;

alter table public.campania_colportor
  add constraint campania_colportor_tipo_beca_check
  check (tipo_beca is null or tipo_beca in ('MEDIA', 'COMPLETA')),
  add constraint campania_colportor_meta_monto_ces_check
  check (meta_monto_ces is null or meta_monto_ces >= 0),
  add constraint campania_colportor_limite_pedido_check
  check (limite_pedido is null or limite_pedido >= 0);

comment on column public.campania_colportor.tipo_beca is
  'Tipo de beca que le asigna el coordinador (HU-BEC-006): null (sin beca), MEDIA o COMPLETA.';
comment on column public.campania_colportor.meta_monto_ces is
  'Meta de compra a la casa editora (CES) en centavos, copia de la meta de su beca al asignarla '
  '(HU-BEC-006). null = sin meta.';
comment on column public.campania_colportor.limite_pedido is
  'Límite de pedido del colportor en esta campaña, en centavos; null = sin límite. Solo AVISA: no bloquea '
  'ni al colportor al armar el pedido ni al coordinador al autorizarlo (R-ST06). Qué se compara con él '
  '(el monto del pedido o la deuda total con el pedido) está pendiente de decisión (S64).';

-- Solo el ADMIN o el coordinador de la campaña cambian estos tres. El servidor (auth.uid() null:
-- service_role, migraciones, seeds) no tiene restricción. Falla con 42501 en vez de coercionar en
-- silencio: un cambio ignorado sin avisar sería peor.
create function public.tg_campania_colportor_beca_y_limite()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if auth.uid() is null then
    return new;
  end if;

  if new.tipo_beca is not distinct from old.tipo_beca
     and new.meta_monto_ces is not distinct from old.meta_monto_ces
     and new.limite_pedido is not distinct from old.limite_pedido then
    return new;
  end if;

  if public.tiene_rol('ADMIN')
     or (public.tiene_rol('COORDINADOR')
         and exists (select 1 from public.campania c
                      where c.id = new.campania_id and c.coordinador_id = auth.uid())) then
    return new;
  end if;

  raise exception 'La beca, la meta y el límite de pedido los fija el coordinador de la campaña'
    using errcode = '42501';
end;
$$;

comment on function public.tg_campania_colportor_beca_y_limite() is
  'BEFORE UPDATE OF tipo_beca, meta_monto_ces, limite_pedido en campania_colportor: solo el ADMIN o el '
  'coordinador de esa campaña los cambian con un JWT (42501); el servidor, sin restricción.';

revoke all on function public.tg_campania_colportor_beca_y_limite() from public, anon, authenticated;

create trigger campania_colportor_beca_y_limite
  before update of tipo_beca, meta_monto_ces, limite_pedido on public.campania_colportor
  for each row execute function public.tg_campania_colportor_beca_y_limite();

-- ----------------------------------------------------------------------------
-- 3. Quién coordina a un colportor (para las políticas de lectura)
-- ----------------------------------------------------------------------------

-- ¿El usuario autenticado coordina una campaña donde p_usuario_id está o estuvo inscripto? SECURITY
-- DEFINER para no depender de la RLS de las tablas que mira (la usan las políticas de abajo); no recibe
-- al que pregunta: sale de auth.uid().
create function public.coordina_al_colportor(p_usuario_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select public.tiene_rol('COORDINADOR')
     and exists (select 1
                   from public.campania_colportor cc
                   join public.campania c on c.id = cc.campania_id
                  where cc.usuario_id = p_usuario_id
                    and c.coordinador_id = auth.uid());
$$;

comment on function public.coordina_al_colportor(uuid) is
  'true si el usuario autenticado es COORDINADOR de una campaña donde p_usuario_id tiene o tuvo una '
  'inscripción (campania_colportor, aun dada de baja). Para las políticas de lectura de stock y cuenta (V2).';

revoke all on function public.coordina_al_colportor(uuid) from public, anon;
grant execute on function public.coordina_al_colportor(uuid) to authenticated, service_role;

-- ----------------------------------------------------------------------------
-- 4. stock
-- ----------------------------------------------------------------------------

create table public.stock (
  id                    uuid primary key default public.uuid_generate_v7(),
  usuario_id            uuid not null references public.usuario(id),
  producto_id           uuid not null references public.producto(id),
  cantidad_disponible   integer not null default 0,
  cantidad_reservada    integer not null default 0,
  created_at            timestamptz not null default now(),
  updated_at            timestamptz not null default now(),
  created_by            uuid default auth.uid() references public.usuario(id) on delete set null,
  deleted_at            timestamptz,
  sync_version          bigint not null default 0,
  xmin_w                xid8 not null default pg_current_xact_id(),
  constraint stock_usuario_producto_key unique (usuario_id, producto_id),
  constraint stock_cantidad_reservada_check check (cantidad_reservada >= 0)
);

create index stock_producto_idx on public.stock (producto_id);

comment on table public.stock is
  'Inventario en mano del colportor, por producto (V2, R-ST01). Los combos no tienen stock propio. '
  'Solo lo escribe el servidor.';
comment on column public.stock.cantidad_disponible is
  'Unidades que tiene. SIN restricción de signo a propósito: entregar más de lo registrado se permite y '
  'queda como inconsistencia (S46); una venta o entrega nunca se rechaza por el stock.';

-- ----------------------------------------------------------------------------
-- 5. pedido_casa_editora y pedido_item
-- ----------------------------------------------------------------------------

create table public.pedido_casa_editora (
  id              uuid primary key default public.uuid_generate_v7(),
  colportor_id    uuid not null references public.usuario(id),
  coordinador_id  uuid references public.usuario(id),
  fecha_pedido    timestamptz not null default now(),
  estado          text not null,
  monto_total     bigint not null default 0,
  origen          text not null,
  excede_limite   boolean not null default false,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  created_by      uuid default auth.uid() references public.usuario(id) on delete set null,
  deleted_at      timestamptz,
  sync_version    bigint not null default 0,
  xmin_w          xid8 not null default pg_current_xact_id(),
  constraint pedido_casa_editora_estado_check
    check (estado in ('BORRADOR', 'PENDIENTE_AUTORIZACION', 'AUTORIZADO', 'DESPACHADO',
                      'RECIBIDO', 'RECHAZADO', 'CANCELADO')),
  constraint pedido_casa_editora_origen_check
    check (origen in ('COLPORTOR', 'COORDINADOR')),
  constraint pedido_casa_editora_monto_total_check
    check (monto_total >= 0)
);

create index pedido_casa_editora_colportor_idx on public.pedido_casa_editora (colportor_id, fecha_pedido desc);
create index pedido_casa_editora_coordinador_idx on public.pedido_casa_editora (coordinador_id)
  where coordinador_id is not null;

comment on table public.pedido_casa_editora is
  'Pedido de libros a la casa editora (V2): lo arma el colportor desde el teléfono (origen COLPORTOR, llega '
  'PENDIENTE_AUTORIZACION, HU-STK-009) o lo registra el coordinador a su nombre (origen COORDINADOR, nace '
  'BORRADOR, HU-STK-001). Usa producto.precio_base_compra. La deuda entra al pasar a AUTORIZADO y el stock '
  'al pasar a RECIBIDO (docs-organizacion#17); esta migración no implementa ninguna de las dos.';
comment on column public.pedido_casa_editora.coordinador_id is
  'El coordinador que lo registró o lo autorizó; null mientras nadie lo tocó.';
comment on column public.pedido_casa_editora.monto_total is
  'Suma de cantidad × precio_unitario de sus líneas, en centavos. No se recalcula acá.';
comment on column public.pedido_casa_editora.excede_limite is
  'true si el pedido superaba campania_colportor.limite_pedido al enviarlo. Solo informa, no bloquea. '
  'Quién lo calcula y contra qué (monto del pedido o deuda total con el pedido) está pendiente (S64).';

create table public.pedido_item (
  id                 uuid primary key default public.uuid_generate_v7(),
  pedido_id          uuid not null references public.pedido_casa_editora(id),
  producto_id        uuid not null references public.producto(id),
  cantidad           integer not null,
  precio_unitario    bigint not null,
  cantidad_recibida  integer,
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now(),
  created_by         uuid default auth.uid() references public.usuario(id) on delete set null,
  deleted_at         timestamptz,
  sync_version       bigint not null default 0,
  xmin_w             xid8 not null default pg_current_xact_id(),
  constraint pedido_item_pedido_producto_key unique (pedido_id, producto_id),
  constraint pedido_item_cantidad_check check (cantidad > 0),
  constraint pedido_item_precio_unitario_check check (precio_unitario >= 0),
  constraint pedido_item_cantidad_recibida_check check (cantidad_recibida is null or cantidad_recibida >= 0)
);

create index pedido_item_producto_idx on public.pedido_item (producto_id);

comment on table public.pedido_item is
  'Línea de un pedido a la casa editora: un producto (nunca un combo, HU-CAT-009) y su cantidad.';
comment on column public.pedido_item.precio_unitario is
  'La foto de producto.precio_base_compra al pedir, en centavos: un cambio posterior no toca pedidos hechos.';
comment on column public.pedido_item.cantidad_recibida is
  'Lo que el colportor confirma al recibir (null mientras no recibió). Si llega incompleto, el stock suma '
  'esto y la deuda se ajusta a esto (HU-STK-001, HU-STK-002).';

-- ----------------------------------------------------------------------------
-- 6. transferencia_stock y transferencia_item
-- ----------------------------------------------------------------------------

create table public.transferencia_stock (
  id                uuid primary key default public.uuid_generate_v7(),
  origen_id         uuid not null references public.usuario(id),
  destino_id        uuid not null references public.usuario(id),
  coordinador_id    uuid references public.usuario(id),
  fecha_solicitud   timestamptz not null default now(),
  estado            text not null default 'PENDIENTE_AUTORIZACION',
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),
  created_by        uuid default auth.uid() references public.usuario(id) on delete set null,
  deleted_at        timestamptz,
  sync_version      bigint not null default 0,
  xmin_w            xid8 not null default pg_current_xact_id(),
  constraint transferencia_stock_estado_check
    check (estado in ('PENDIENTE_AUTORIZACION', 'AUTORIZADO', 'EJECUTADO', 'RECHAZADO', 'CANCELADO')),
  constraint transferencia_stock_puntas_distintas_check
    check (origen_id <> destino_id)
);

create index transferencia_stock_origen_idx on public.transferencia_stock (origen_id);
create index transferencia_stock_destino_idx on public.transferencia_stock (destino_id);

comment on table public.transferencia_stock is
  'Transferencia de stock entre dos colportores (V2, HU-STK-005/006): de origen_id a destino_id, con '
  'autorización del coordinador. Al autorizar, el stock y la deuda de esos libros pasan de uno al otro '
  '(vista 35); esta migración no mueve nada.';

create table public.transferencia_item (
  id                 uuid primary key default public.uuid_generate_v7(),
  transferencia_id   uuid not null references public.transferencia_stock(id),
  producto_id        uuid not null references public.producto(id),
  cantidad           integer not null,
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now(),
  created_by         uuid default auth.uid() references public.usuario(id) on delete set null,
  deleted_at         timestamptz,
  sync_version       bigint not null default 0,
  xmin_w             xid8 not null default pg_current_xact_id(),
  constraint transferencia_item_transferencia_producto_key unique (transferencia_id, producto_id),
  constraint transferencia_item_cantidad_check check (cantidad > 0)
);

create index transferencia_item_producto_idx on public.transferencia_item (producto_id);

comment on table public.transferencia_item is
  'Línea de una transferencia: un producto y la cantidad que pasa de origen_id a destino_id.';

-- ----------------------------------------------------------------------------
-- 7. movimiento_stock
-- ----------------------------------------------------------------------------

create table public.movimiento_stock (
  id                uuid primary key default public.uuid_generate_v7(),
  usuario_id        uuid not null references public.usuario(id),
  producto_id       uuid not null references public.producto(id),
  tipo              text not null,
  cantidad          integer not null,
  fecha             timestamptz not null default now(),
  pedido_id         uuid references public.pedido_casa_editora(id),
  transferencia_id  uuid references public.transferencia_stock(id),
  entrega_id        uuid references public.entrega(id),
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),
  created_by        uuid default auth.uid() references public.usuario(id) on delete set null,
  deleted_at        timestamptz,
  sync_version      bigint not null default 0,
  xmin_w            xid8 not null default pg_current_xact_id(),
  constraint movimiento_stock_tipo_check
    check (tipo in ('ENTRADA_PEDIDO', 'SALIDA_ENTREGA', 'SALIDA_TRANSFERENCIA', 'ENTRADA_TRANSFERENCIA')),
  constraint movimiento_stock_cantidad_check check (cantidad > 0),
  -- A lo sumo un origen del movimiento: un pedido, una transferencia o una entrega.
  constraint movimiento_stock_un_origen_check
    check (num_nonnulls(pedido_id, transferencia_id, entrega_id) <= 1)
);

create index movimiento_stock_usuario_idx on public.movimiento_stock (usuario_id, fecha desc);
create index movimiento_stock_producto_idx on public.movimiento_stock (producto_id);
create index movimiento_stock_pedido_idx on public.movimiento_stock (pedido_id) where pedido_id is not null;
create index movimiento_stock_transferencia_idx on public.movimiento_stock (transferencia_id)
  where transferencia_id is not null;
create index movimiento_stock_entrega_idx on public.movimiento_stock (entrega_id) where entrega_id is not null;

comment on table public.movimiento_stock is
  'Histórico de cambios de stock del colportor (V2): entrada por pedido recibido, salida por entrega o '
  'por transferencia. La cantidad es siempre positiva y el tipo dice para qué lado va.';

-- ----------------------------------------------------------------------------
-- 8. ticket y deposito
-- ----------------------------------------------------------------------------

create table public.ticket (
  id                    uuid primary key default public.uuid_generate_v7(),
  usuario_id            uuid not null references public.usuario(id),
  tipo                  text not null,
  url_cloud             text,
  subido_en             timestamptz not null default now(),
  revisado_por          uuid references public.usuario(id),
  revisado_en           timestamptz,
  monto                 bigint,
  fecha                 timestamptz,
  numero_autorizacion   text,
  tarjeta_tipo          text,
  tarjeta_marca         text,
  estado                text not null default 'PENDIENTE',
  motivo_rechazo        text,
  created_at            timestamptz not null default now(),
  updated_at            timestamptz not null default now(),
  created_by            uuid default auth.uid() references public.usuario(id) on delete set null,
  deleted_at            timestamptz,
  sync_version          bigint not null default 0,
  xmin_w                xid8 not null default pg_current_xact_id(),
  constraint ticket_tipo_check check (tipo in ('COBRO_TARJETA', 'DEPOSITO', 'OTRO')),
  constraint ticket_estado_check check (estado in ('PENDIENTE', 'VALIDADO', 'RECHAZADO')),
  constraint ticket_monto_check check (monto is null or monto > 0),
  constraint ticket_tarjeta_tipo_check check (tarjeta_tipo is null or tarjeta_tipo in ('CREDITO', 'DEBITO')),
  constraint ticket_numero_autorizacion_check
    check (numero_autorizacion is null or (btrim(numero_autorizacion) <> '' and length(numero_autorizacion) <= 40)),
  constraint ticket_tarjeta_marca_check
    check (tarjeta_marca is null or (btrim(tarjeta_marca) <> '' and length(tarjeta_marca) <= 40)),
  -- Rechazar exige un motivo (HU-COB-008, S66); el motivo solo existe en un ticket rechazado.
  constraint ticket_motivo_rechazo_check
    check ((estado = 'RECHAZADO'
              and motivo_rechazo is not null and btrim(motivo_rechazo) <> '' and length(motivo_rechazo) <= 500)
           or (estado <> 'RECHAZADO' and motivo_rechazo is null))
);

create index ticket_usuario_idx on public.ticket (usuario_id, subido_en desc);
create index ticket_revisado_por_idx on public.ticket (revisado_por) where revisado_por is not null;
create index ticket_pendientes_idx on public.ticket (subido_en) where estado = 'PENDIENTE' and deleted_at is null;

comment on table public.ticket is
  'Comprobante que sube el colportor (V2, HU-COB-007): cobro con tarjeta, depósito u otro. Foto, fecha, '
  'número de autorización, tarjeta (crédito o débito y marca) y monto. Validarlo lo acredita y baja la '
  'deuda (HU-COB-008, no implementado acá). Un ticket resuelto (VALIDADO o RECHAZADO) no se vuelve a abrir: '
  'es su propio historial (HU-COB-009).';
comment on column public.ticket.url_cloud is
  'Ruta de la foto en la nube. Se vacía a los 4 meses (RF-CO08A): el ticket conserva sus datos y deja de '
  'mostrar la foto. La ruta local del teléfono no se guarda en la nube.';
comment on column public.ticket.revisado_por is 'El coordinador que lo validó o rechazó.';
comment on column public.ticket.motivo_rechazo is
  'Por qué se rechazó («El monto no coincide con el cobro»); obligatorio si estado = RECHAZADO.';

-- Un ticket resuelto no se edita: todo lo suyo queda congelado salvo la foto (que vence), la baja lógica
-- y la auditoría. Corregir = ticket nuevo. Vale también para el servidor. TK001.
create function public.tg_ticket_resuelto_no_se_edita()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if old.estado <> 'PENDIENTE'
     and (new.usuario_id, new.tipo, new.subido_en, new.revisado_por, new.revisado_en, new.monto,
          new.fecha, new.numero_autorizacion, new.tarjeta_tipo, new.tarjeta_marca, new.estado,
          new.motivo_rechazo)
         is distinct from
         (old.usuario_id, old.tipo, old.subido_en, old.revisado_por, old.revisado_en, old.monto,
          old.fecha, old.numero_autorizacion, old.tarjeta_tipo, old.tarjeta_marca, old.estado,
          old.motivo_rechazo) then
    raise exception 'Un ticket validado o rechazado no se edita: subí uno nuevo'
      using errcode = 'TK001';
  end if;
  return new;
end;
$$;

comment on function public.tg_ticket_resuelto_no_se_edita() is
  'BEFORE UPDATE en ticket: un ticket VALIDADO o RECHAZADO conserva todos sus datos (TK001); solo cambian '
  'url_cloud, deleted_at y la auditoría.';

revoke all on function public.tg_ticket_resuelto_no_se_edita() from public, anon, authenticated;

create trigger ticket_resuelto_no_se_edita
  before update on public.ticket
  for each row execute function public.tg_ticket_resuelto_no_se_edita();

create table public.deposito (
  id            uuid primary key default public.uuid_generate_v7(),
  colportor_id  uuid not null references public.usuario(id),
  monto         bigint not null,
  fecha         timestamptz not null default now(),
  ticket_id     uuid references public.ticket(id),
  destino       text not null,
  concepto      text not null,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  created_by    uuid default auth.uid() references public.usuario(id) on delete set null,
  deleted_at    timestamptz,
  sync_version  bigint not null default 0,
  xmin_w        xid8 not null default pg_current_xact_id(),
  constraint deposito_monto_check check (monto > 0),
  constraint deposito_destino_check check (destino in ('BANCO', 'OFICINA', 'RETIRO_COORDINADOR')),
  constraint deposito_concepto_check check (concepto in ('CASA_EDITORA', 'ALQUILER'))
);

create index deposito_colportor_idx on public.deposito (colportor_id, fecha desc);
create index deposito_ticket_idx on public.deposito (ticket_id) where ticket_id is not null;

comment on table public.deposito is
  'Depósito de efectivo del colportor (V2, HU-CTA-004): monto, fecha, a dónde fue y para qué era. '
  'Un depósito tiene un solo concepto (S68): para pagar los dos, dos depósitos.';
comment on column public.deposito.destino is
  'BANCO | OFICINA | RETIRO_COORDINADOR (el coordinador pasa a retirar el efectivo donde no hay dónde '
  'depositar: Artigas, Bella Unión). Con RETIRO_COORDINADOR no hay ticket.';
comment on column public.deposito.concepto is
  'CASA_EDITORA | ALQUILER: lo elige el colportor al depositar y decide contra qué deuda cuenta (HU-CTA-007).';
comment on column public.deposito.ticket_id is
  'El comprobante del depósito (BANCO u OFICINA); null en un retiro por el coordinador.';

-- ----------------------------------------------------------------------------
-- 9. estado_cuenta (snapshot)
-- ----------------------------------------------------------------------------

create table public.estado_cuenta (
  id                  uuid primary key default public.uuid_generate_v7(),
  usuario_id          uuid not null references public.usuario(id),
  deuda_total         bigint not null default 0,
  dinero_depositado   bigint not null default 0,
  dinero_en_mano      bigint not null default 0,
  dinero_por_cobrar   bigint not null default 0,
  deuda_alquiler      bigint not null default 0,
  actualizado_en      timestamptz not null default now(),
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now(),
  created_by          uuid default auth.uid() references public.usuario(id) on delete set null,
  deleted_at          timestamptz,
  sync_version        bigint not null default 0,
  xmin_w              xid8 not null default pg_current_xact_id(),
  constraint estado_cuenta_usuario_key unique (usuario_id)
);

comment on table public.estado_cuenta is
  'Snapshot calculado de la situación financiera del colportor (V2, HU-CTA-001..005): una fila por usuario. '
  'Lo escribe el servidor; esta migración no lo calcula. Lleva un id propio (el esquema decía usuario_id '
  'como clave) porque todas las tablas de public tienen id uuid. No confundir con la función '
  'estado_cuenta() de 0004 (ACTIVA / PENDIENTE_ASIGNACION / SUSPENDIDA).';
comment on column public.estado_cuenta.deuda_total is
  'Deuda con la casa editora, en centavos. NO incluye el alquiler.';
comment on column public.estado_cuenta.deuda_alquiler is
  'Deuda de alquiler en centavos: campania.alquiler_monto menos los depósitos validados con concepto '
  'ALQUILER (HU-CTA-007). Aparte de deuda_total; no bloquea nada.';

-- ----------------------------------------------------------------------------
-- 10. Auditoría, RLS y privilegios (las nueve tablas)
-- ----------------------------------------------------------------------------

do $$
declare
  t text;
begin
  foreach t in array array['stock', 'pedido_casa_editora', 'pedido_item', 'transferencia_stock',
                           'transferencia_item', 'movimiento_stock', 'ticket', 'deposito', 'estado_cuenta']
  loop
    execute format(
      'create trigger %I before insert on public.%I for each row execute function public.tg_auditoria_insert()',
      t || '_auditoria_insert', t);
    execute format(
      'create trigger %I before update on public.%I for each row execute function public.tg_auditoria_update()',
      t || '_auditoria_update', t);
    execute format('alter table public.%I enable row level security', t);
    execute format('revoke all on public.%I from anon, authenticated', t);
    execute format('grant select on public.%I to authenticated', t);
    execute format('grant all on public.%I to service_role', t);
  end loop;
end
$$;

-- LEE: el dueño, el ADMIN y quien coordina al colportor. Sin políticas de INSERT ni de UPDATE: no
-- escribe nadie con JWT hasta que se decida el camino de la conexión de V2.
create policy stock_select on public.stock
  for select to authenticated
  using (usuario_id = (select auth.uid())
         or (select public.tiene_rol('ADMIN'))
         or public.coordina_al_colportor(usuario_id));

create policy movimiento_stock_select on public.movimiento_stock
  for select to authenticated
  using (usuario_id = (select auth.uid())
         or (select public.tiene_rol('ADMIN'))
         or public.coordina_al_colportor(usuario_id));

create policy pedido_casa_editora_select on public.pedido_casa_editora
  for select to authenticated
  using (colportor_id = (select auth.uid())
         or (select public.tiene_rol('ADMIN'))
         or public.coordina_al_colportor(colportor_id));

-- Las líneas se ven si se ve el pedido (la RLS del pedido se aplica a quien consulta).
create policy pedido_item_select on public.pedido_item
  for select to authenticated
  using (exists (select 1 from public.pedido_casa_editora p where p.id = pedido_item.pedido_id));

create policy transferencia_stock_select on public.transferencia_stock
  for select to authenticated
  using (origen_id = (select auth.uid())
         or destino_id = (select auth.uid())
         or (select public.tiene_rol('ADMIN'))
         or public.coordina_al_colportor(origen_id)
         or public.coordina_al_colportor(destino_id));

create policy transferencia_item_select on public.transferencia_item
  for select to authenticated
  using (exists (select 1 from public.transferencia_stock s where s.id = transferencia_item.transferencia_id));

create policy ticket_select on public.ticket
  for select to authenticated
  using (usuario_id = (select auth.uid())
         or (select public.tiene_rol('ADMIN'))
         or public.coordina_al_colportor(usuario_id));

create policy deposito_select on public.deposito
  for select to authenticated
  using (colportor_id = (select auth.uid())
         or (select public.tiene_rol('ADMIN'))
         or public.coordina_al_colportor(colportor_id));

create policy estado_cuenta_select on public.estado_cuenta
  for select to authenticated
  using (usuario_id = (select auth.uid())
         or (select public.tiene_rol('ADMIN'))
         or public.coordina_al_colportor(usuario_id));
