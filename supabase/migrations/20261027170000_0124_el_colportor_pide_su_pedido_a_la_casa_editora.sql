-- ============================================================================
-- 0124 · El colportor arma su pedido a la casa editora desde el teléfono: sube por push, el servidor fija el
--        origen, el precio y el aviso del límite, se cancela mientras no esté autorizado, y una lectura le
--        muestra su situación antes de enviar
--        (backend-supabase#102, BACK-HU-STK-009, seguimiento de #100 y #156)
--
-- Origen: cambio de requisitos del 21/10 (reunión del 05/10, docs#69, C5) y las decisiones de Cristian del 25/10
-- «Límite ped.» (el límite avisa y deja enviar: es la deuda con el pedido incluido contra el límite único de la
-- campaña, 0120) y «Costo editora» (`pedido_item.precio_unitario` se copia de `producto.precio_base_compra`;
-- nadie lo tipea). Es V2: se conecta después del 20/11 (plan-sprints §5). Se escribe ahora para no rehacerlo.
--
-- La 0067 (#100) creó `pedido_casa_editora` y `pedido_item` (vacías, de solo lectura) y la 0120 (#156) dejó las
-- funciones que miden el límite. Esta migración SOLO SUMA sobre ellas.
--
-- ## Qué suma
--
--   1. `pedido_casa_editora` y `pedido_item` entran al push Y al pull (contrato §2, dueño `colportor_id`): el
--      pedido se arma sin conexión (cola de sync) y la colportora ve cómo sigue (autorizado, rechazado…) con lo
--      que baja del servidor. `pedido_item` gana `colportor_id` (la dueña, copiada del pedido por un trigger)
--      porque el pull filtra por una columna de la propia tabla; las filas que ya había se completan.
--   2. Qué decide el servidor sobre un pedido que llega del teléfono (trigger `pedido_del_cliente`, solo para
--      `authenticated`; el servidor, un RPC DEFINER o el editor SQL no pasan por él):
--        · nace `PENDIENTE_AUTORIZACION` (23514 si el teléfono manda otro estado) y con `origen = 'COLPORTOR'`;
--        · la dueña sale del JWT, y `coordinador_id`, `monto_total`, `excede_limite` y `fecha_pedido` los pone el
--          servidor (están en `columnas_servidor`: se descartan del payload). `fecha_pedido` es cuándo LLEGÓ
--          («el pedido se envía al sincronizar», HU-STK-009), no cuándo se armó: así la campaña a la que pertenece
--          no depende del reloj del teléfono;
--        · la colportora tiene que estar en una campaña (la ventana de su inscripción contiene la fecha, la misma
--          regla `campania_del_ticket()` con que el coordinador ve el pedido, 0112): si no, 42501 con aviso.
--   3. Qué decide el servidor sobre una línea (trigger `pedido_item_del_cliente`): el pedido es suyo y sigue por
--      autorizar (42501 si es ajeno o no existe; 23514 si ya no se puede cambiar), el producto existe y tiene
--      precio de compra (23503 / 23514), y `precio_unitario` es la foto de `producto.precio_base_compra`,
--      siempre del servidor (también `cantidad_recibida`, que el teléfono no manda). Pide productos, no combos:
--      `pedido_item.producto_id` apunta a `producto`, una colección no tiene fila ahí (HU-CAT-009).
--   4. `monto_total` y `excede_limite` los recalcula el servidor con cada línea que llega del teléfono
--      (`recalcular_pedido_del_colportor()`): la suma de cantidad × precio de sus líneas vivas, y
--      `pedido_excede_limite_de_deuda(colportora, campaña del pedido, monto_total)` de la 0120. SOLO AVISA, no
--      bloquea: el pedido que supera el límite entra igual y decide el coordinador (R-ST06). Las líneas que
--      cargan el servidor o los tests por otro camino no recalculan nada: su `monto_total` es el que se escribió.
--   5. Cancelar: la colportora puede pasar su pedido de `PENDIENTE_AUTORIZACION` a `CANCELADO` con un update del
--      push (privilegios por columna, y un trigger que no deja ningún otro cambio).
--      Una vez autorizado (o rechazado, o cancelado) el teléfono ya no lo toca: 42501 con el aviso de qué hacer
--      (si estaba autorizado, lo cancela el coordinador, HU-STK-002). Si el coordinador lo autorizó mientras
--      tanto, la versión del teléfono quedó vieja y el push vuelve `conflict` con la fila del servidor.
--   6. `situacion_para_pedido(p_items)`: lo que la colportora ve ANTES de enviar (con conexión; sin ella la app
--      lo calcula con lo que bajó): deuda actual, monto del pedido que arma, deuda con el pedido, por cobrar,
--      libros por entregar, límite de deuda de su campaña y cuánto lo supera, y su stock.
--
-- ## Lo que NO hace (y por qué)
--
--   · No autoriza, rechaza, despacha ni recibe (0112 y las historias de recepción), no carga la deuda ni suma el
--     stock, no manda el push al colportor (HU-NOT-003), no exporta el pedido (S65).
--   · No obliga a que el pedido llegue con todas sus líneas a la vez: el teléfono sube el pedido y después sus
--     líneas (el servidor aplica el lote en el orden en que llega; una línea antes que su pedido vuelve `invalid`
--     42501). Durante ese instante el coordinador ve un pedido por autorizar en cero; `autorizar_pedido` (0112)
--     lo frena con PE003 (pedido sin líneas).
--   · No bloquea por el límite ni por el stock, y no limita la cantidad por línea.
--
-- ## Los datos
--
-- Solo suma: una columna (`pedido_item.colportor_id`, completada desde el pedido sin tocar la versión ni la hora
-- de ninguna fila), un trigger, dos índices del delta, políticas, dos filas en sync.entidad y funciones. Ningún
-- pedido ni línea existente cambia. Lo prueba supabase/tests_migracion/0124_ok.
--
-- ## Para otros repos
--
--   · front-colportores-mobile (#102 del móvil, la vista de pedido): entidades `pedido_casa_editora` y
--     `pedido_item` (push + pull). El teléfono manda el pedido con { id, estado: 'PENDIENTE_AUTORIZACION' } y sus
--     líneas con { id, pedido_id, producto_id, cantidad }; todo lo demás lo pone el servidor y vuelve en el pull
--     (`monto_total`, `excede_limite`, `precio_unitario`, `origen`, `fecha_pedido`). Cancelar es un update con
--     { id, estado: 'CANCELADO' } y la `sync_version` que tiene. `invalid` con 23514 (estado, producto sin
--     precio), 23503 (producto inexistente), 42501 (sin campaña, pedido ajeno o ya decidido, cualquier otro
--     cambio) y 23505 (producto repetido en el pedido). Como cada línea sube la versión del pedido, el teléfono
--     tiene que bajar antes de cancelar.
--   · front-coordinadores-web / backend-supabase#104: `excede_limite` sale como lo guardó esta migración.
--   · docs-organizacion: esquema-datos.md, contrato-sync-engine.md §2 (las dos filas) y HU-STK-009.
--
-- Forward-only: esta migración no se edita una vez aplicada.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. pedido_item.colportor_id: la dueña, copiada del pedido
-- ----------------------------------------------------------------------------

alter table public.pedido_item
  add column colportor_id uuid references public.usuario(id);

-- Las líneas que ya hubiera (datos de prueba) toman la dueña de su pedido. Sin el trigger de auditoría: ni la
-- versión ni la hora de ninguna fila cambian (la tabla no estaba en el sync, nadie la bajó).
alter table public.pedido_item disable trigger pedido_item_auditoria_update;
update public.pedido_item i
   set colportor_id = p.colportor_id
  from public.pedido_casa_editora p
 where p.id = i.pedido_id;
alter table public.pedido_item enable trigger pedido_item_auditoria_update;

alter table public.pedido_item
  alter column colportor_id set not null;

comment on column public.pedido_item.colportor_id is
  'La colportora dueña del pedido (0124): la copia del pedido un trigger, en todo camino. Existe para que el '
  'pull de la entidad filtre por una columna de la propia tabla; el teléfono no la manda.';

-- El delta con la dueña primero, para que el predicado entre en el Index Cond (0002 §14).
create index pedido_casa_editora_delta_idx on public.pedido_casa_editora (colportor_id, xmin_w, id);
create index pedido_item_delta_idx on public.pedido_item (colportor_id, xmin_w, id);

-- Por todo camino (el teléfono, el servidor, los tests): la dueña de la línea es la del pedido. DEFINER para
-- leer el pedido aunque la RLS lo esconda (una línea de un pedido ajeno o inexistente queda en null y la frena
-- la RLS o el NOT NULL).
create function public.tg_pedido_item_colportor()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  new.colportor_id := (select p.colportor_id from public.pedido_casa_editora p where p.id = new.pedido_id);
  return new;
end;
$$;

comment on function public.tg_pedido_item_colportor() is
  'BEFORE INSERT de pedido_item (0124): colportor_id es el del pedido, venga de donde venga la línea.';

revoke all on function public.tg_pedido_item_colportor() from public, anon, authenticated, service_role;

create trigger pedido_item_colportor
  before insert on public.pedido_item
  for each row execute function public.tg_pedido_item_colportor();

-- ----------------------------------------------------------------------------
-- 2. Ayudantes para los triggers del teléfono (SECURITY DEFINER, sin recibir al usuario: usan auth.uid())
-- ----------------------------------------------------------------------------

-- ¿Está quien llama en una campaña en p_fecha? La misma regla con que el coordinador ve el pedido (0112).
create function public.tengo_campania_para_pedir(p_fecha timestamptz)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select public.campania_del_ticket((select auth.uid()), p_fecha) is not null;
$$;

comment on function public.tengo_campania_para_pedir(timestamptz) is
  'true si quien llama (auth.uid()) tiene una inscripción cuya ventana contiene p_fecha (campania_del_ticket, '
  '0113): puede pedir libros a la casa editora (0124). Interna: la llama el trigger de pedido_casa_editora.';

revoke all on function public.tengo_campania_para_pedir(timestamptz) from public, anon, authenticated, service_role;
grant execute on function public.tengo_campania_para_pedir(timestamptz) to authenticated;

-- ¿Está suspendida la cuenta de quien llama? (usuario.suspendido_en, 0004). Decisión del 27/10 (mapa §2, igual que
-- USUARIO_SUSPENDIDO de 0005/0006): una cuenta suspendida no pide libros aunque siga inscripta.
create function public.mi_cuenta_esta_suspendida()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce((select u.suspendido_en is not null
                     from public.usuario u
                    where u.id = (select auth.uid())), false);
$$;

comment on function public.mi_cuenta_esta_suspendida() is
  'true si la cuenta de quien llama (auth.uid()) está suspendida (usuario.suspendido_en no es null): no pide libros '
  'a la casa editora (0124). Interna: la llama el trigger de pedido_casa_editora.';

revoke all on function public.mi_cuenta_esta_suspendida() from public, anon, authenticated, service_role;
grant execute on function public.mi_cuenta_esta_suspendida() to authenticated;

-- ¿Por qué no se le pueden sumar líneas a este pedido de QUIEN LLAMA? null si se puede; AJENO si es de otra o no
-- existe (no se distingue); ESTADO si es suyo pero ya no está por autorizar. Toma un candado compartido sobre el
-- pedido hasta el final de la transacción: un coordinador que lo autoriza a la vez espera a que la línea
-- quede, o la línea ve el pedido ya autorizado. Volátil por el candado.
create function public.pedido_no_acepta_lineas(p_pedido_id uuid)
returns text
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_dueno   uuid;
  v_estado  text;
begin
  select p.colportor_id, p.estado into v_dueno, v_estado
    from public.pedido_casa_editora p
   where p.id = p_pedido_id and p.deleted_at is null
     for share;
  if v_dueno is null or v_dueno is distinct from (select auth.uid()) then
    return 'AJENO';
  end if;
  if v_estado <> 'PENDIENTE_AUTORIZACION' then
    return 'ESTADO';
  end if;
  return null;
end;
$$;

comment on function public.pedido_no_acepta_lineas(uuid) is
  'null si a este pedido de quien llama (auth.uid()) se le pueden sumar líneas; AJENO si es de otra o no existe; '
  'ESTADO si ya no está por autorizar (0124). Candado compartido sobre el pedido. Interna: la llama el trigger de '
  'pedido_item.';

revoke all on function public.pedido_no_acepta_lineas(uuid) from public, anon, authenticated, service_role;
grant execute on function public.pedido_no_acepta_lineas(uuid) to authenticated;

-- Recalcula el monto y el aviso del límite de un pedido de QUIEN LLAMA mientras sigue por autorizar. La campaña
-- es la del pedido (campania_del_ticket con su fecha). No bloquea nada: solo informa (R-ST06). Idempotente.
create function public.recalcular_pedido_del_colportor(p_pedido_id uuid)
returns void
language sql
volatile
security definer
set search_path = ''
as $$
  update public.pedido_casa_editora p
     set monto_total = t.monto,
         excede_limite = public.pedido_excede_limite_de_deuda(
                           p.colportor_id, public.campania_del_ticket(p.colportor_id, p.fecha_pedido), t.monto)
    from (select coalesce(sum(i.cantidad::bigint * i.precio_unitario), 0)::bigint as monto
            from public.pedido_item i
           where i.pedido_id = p_pedido_id and i.deleted_at is null) t
   where p.id = p_pedido_id
     and p.colportor_id = (select auth.uid())
     and p.origen = 'COLPORTOR'
     and p.estado = 'PENDIENTE_AUTORIZACION'
     and (p.monto_total is distinct from t.monto
          or p.excede_limite is distinct from public.pedido_excede_limite_de_deuda(
                           p.colportor_id, public.campania_del_ticket(p.colportor_id, p.fecha_pedido), t.monto));
$$;

comment on function public.recalcular_pedido_del_colportor(uuid) is
  'Recalcula monto_total (suma de cantidad × precio_unitario de las líneas vivas) y excede_limite '
  '(pedido_excede_limite_de_deuda de la campaña del pedido) de un pedido por autorizar de quien llama '
  '(auth.uid()) (0124). Solo informa: no bloquea. Interna: la llama el trigger de pedido_item.';

revoke all on function public.recalcular_pedido_del_colportor(uuid) from public, anon, authenticated, service_role;
grant execute on function public.recalcular_pedido_del_colportor(uuid) to authenticated;

-- ----------------------------------------------------------------------------
-- 3. Qué decide el servidor sobre un pedido que llega del teléfono
-- ----------------------------------------------------------------------------

-- Alta. Los BEFORE corren aun para una fila que el push no inserta porque ya existía (INSERT ... ON CONFLICT DO
-- NOTHING): si el pedido ya está, no se valida otra vez (un reintento no vuelve `invalid` lo que ya entró).
create function public.tg_pedido_casa_editora_del_cliente()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  -- El servidor (service_role, el editor SQL, una función DEFINER) no pasa por acá. El push corre INVOKER como
  -- `authenticated` (patrón de 0053, 0100, 0113 y 0122).
  if current_user not in ('authenticated', 'anon') then
    return new;
  end if;

  -- Lo que decide el servidor (también llega descartado del payload: columnas_servidor). Va antes que el
  -- reintento: la RLS de alta mira `origen`, y la mira antes del ON CONFLICT.
  new.origen := 'COLPORTOR';
  new.coordinador_id := null;
  new.monto_total := 0;
  new.excede_limite := false;

  if exists (select 1 from public.pedido_casa_editora p where p.id = new.id) then
    return new;
  end if;

  if new.estado is distinct from 'PENDIENTE_AUTORIZACION' then
    raise exception 'El pedido se envía para que lo autorice tu coordinador. Envialo desde la pantalla de pedidos.'
      using errcode = '23514', constraint = 'pedido_del_colportor_nace_por_autorizar';
  end if;

  if public.mi_cuenta_esta_suspendida() then
    raise exception 'Tu cuenta está suspendida, así que no podés pedir libros. Hablá con el administrador.'
      using errcode = '42501';
  end if;

  if not public.tengo_campania_para_pedir(new.fecha_pedido) then
    raise exception 'No estás en una campaña en curso, así que no podés pedir libros todavía. Hablá con tu coordinador para que te inscriba.'
      using errcode = '42501';
  end if;
  return new;
end;
$$;

comment on function public.tg_pedido_casa_editora_del_cliente() is
  'BEFORE INSERT de pedido_casa_editora, solo para authenticated (0124): nace PENDIENTE_AUTORIZACION (23514), la '
  'colportora no está suspendida y está en una campaña (42501) y el servidor fija origen COLPORTOR, sin coordinador, monto 0 y sin '
  'aviso (los recalcula con cada línea). El servidor no pasa por acá.';

revoke all on function public.tg_pedido_casa_editora_del_cliente() from public, anon, authenticated, service_role;

create trigger pedido_casa_editora_del_cliente
  before insert on public.pedido_casa_editora
  for each row execute function public.tg_pedido_casa_editora_del_cliente();

-- Cancelar: lo único que el teléfono cambia de un pedido es su estado, de PENDIENTE_AUTORIZACION a CANCELADO.
-- Las demás columnas ya las frena el privilegio (UPDATE solo sobre id, estado, created_at y deleted_at); la baja
-- lógica la frena este trigger: un pedido no se borra, se cancela.
create function public.tg_pedido_casa_editora_cancelar_del_cliente()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if current_user not in ('authenticated', 'anon') then
    return new;
  end if;

  if new.deleted_at is distinct from old.deleted_at then
    raise exception 'Un pedido no se borra: se cancela mientras esté por autorizar.'
      using errcode = '42501';
  end if;

  if new.estado is not distinct from old.estado then
    return new;
  end if;

  if new.estado <> 'CANCELADO' then
    raise exception 'Desde el teléfono un pedido solo se puede cancelar.'
      using errcode = '42501';
  end if;

  if old.estado in ('AUTORIZADO', 'DESPACHADO', 'RECIBIDO') then
    raise exception 'Tu coordinador ya autorizó este pedido: pedile a él que lo cancele.'
      using errcode = '42501';
  elsif old.estado <> 'PENDIENTE_AUTORIZACION' then
    raise exception 'Este pedido ya no se puede cancelar: ya no está por autorizar.'
      using errcode = '42501';
  end if;
  return new;
end;
$$;

comment on function public.tg_pedido_casa_editora_cancelar_del_cliente() is
  'BEFORE UPDATE de pedido_casa_editora, solo para authenticated (0124): el teléfono solo cancela un pedido por '
  'autorizar (no lo borra); uno autorizado lo cancela el coordinador (42501). El servidor no pasa por acá.';

revoke all on function public.tg_pedido_casa_editora_cancelar_del_cliente() from public, anon, authenticated, service_role;

create trigger pedido_casa_editora_cancelar_del_cliente
  before update on public.pedido_casa_editora
  for each row execute function public.tg_pedido_casa_editora_cancelar_del_cliente();

-- ----------------------------------------------------------------------------
-- 4. Qué decide el servidor sobre una línea que llega del teléfono
-- ----------------------------------------------------------------------------

create function public.tg_pedido_item_del_cliente()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_motivo  text;
  v_precio  integer;
  v_existe  boolean;
begin
  if current_user not in ('authenticated', 'anon') then
    return new;
  end if;

  -- Un reintento de una línea que ya entró: no se valida de nuevo (el pedido pudo cambiar de estado). El
  -- precio de relleno es solo para el NOT NULL, que se mira antes del ON CONFLICT DO NOTHING; la fila no entra.
  if exists (select 1 from public.pedido_item i where i.id = new.id) then
    new.precio_unitario := 0;
    new.cantidad_recibida := null;
    return new;
  end if;

  v_motivo := public.pedido_no_acepta_lineas(new.pedido_id);
  if v_motivo = 'AJENO' then
    raise exception 'Ese pedido no es tuyo. Sumá productos solo a tus pedidos.'
      using errcode = '42501';
  elsif v_motivo = 'ESTADO' then
    raise exception 'Ese pedido ya no está por autorizar, así que no se le pueden sumar productos. Armá un pedido nuevo.'
      using errcode = '23514', constraint = 'pedido_item_pedido_por_autorizar';
  end if;

  select true, p.precio_base_compra into v_existe, v_precio
    from public.producto p
   where p.id = new.producto_id and p.deleted_at is null;
  if v_existe is null then
    raise exception 'Ese producto ya no está en el catálogo. Sacalo del pedido.'
      using errcode = '23503';
  end if;
  if v_precio is null then
    raise exception 'Ese producto todavía no tiene precio de compra cargado. Sacalo del pedido y avisale a tu coordinador.'
      using errcode = '23514', constraint = 'pedido_item_producto_con_precio';
  end if;

  -- El precio y lo recibido los fija el servidor: nadie los tipea en el pedido.
  new.precio_unitario := v_precio;
  new.cantidad_recibida := null;
  return new;
end;
$$;

comment on function public.tg_pedido_item_del_cliente() is
  'BEFORE INSERT de pedido_item, solo para authenticated (0124): el pedido es suyo y sigue por autorizar (42501 / '
  '23514), el producto existe (23503) y tiene precio de compra (23514), y precio_unitario es la foto de '
  'producto.precio_base_compra. El servidor no pasa por acá.';

revoke all on function public.tg_pedido_item_del_cliente() from public, anon, authenticated, service_role;

create trigger pedido_item_del_cliente
  before insert on public.pedido_item
  for each row execute function public.tg_pedido_item_del_cliente();

-- Después de la línea: el monto y el aviso del límite del pedido. Solo cuando la línea la sube el teléfono; el
-- trigger corre como quien inserta y la función que escribe el pedido es DEFINER.
create function public.tg_pedido_item_recalcular_del_cliente()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if current_user in ('authenticated', 'anon') then
    perform public.recalcular_pedido_del_colportor(new.pedido_id);
  end if;
  return null;
end;
$$;

comment on function public.tg_pedido_item_recalcular_del_cliente() is
  'AFTER INSERT de pedido_item, solo para authenticated (0124): recalcula el monto y el aviso del límite del '
  'pedido. Las líneas que carga el servidor no lo recalculan.';

revoke all on function public.tg_pedido_item_recalcular_del_cliente() from public, anon, authenticated, service_role;

create trigger pedido_item_recalcular_del_cliente
  after insert on public.pedido_item
  for each row execute function public.tg_pedido_item_recalcular_del_cliente();

-- ----------------------------------------------------------------------------
-- 5. RLS y privilegios
-- ----------------------------------------------------------------------------

-- La colportora crea sus pedidos (los del coordinador a su nombre no pasan por acá: los carga el servidor) y
-- cambia solo su estado (cancelar). Sin DELETE.
create policy pedido_casa_editora_insert_propio on public.pedido_casa_editora
  for insert to authenticated
  with check (colportor_id = (select auth.uid())
              and origen = 'COLPORTOR'
              and estado = 'PENDIENTE_AUTORIZACION');

create policy pedido_casa_editora_update_propio on public.pedido_casa_editora
  for update to authenticated
  using (colportor_id = (select auth.uid()))
  with check (colportor_id = (select auth.uid()));

-- Las líneas: la colportora las suma a su pedido (colportor_id lo copia el trigger del pedido). Sin UPDATE ni
-- DELETE: un pedido se cancela entero.
create policy pedido_item_insert_propio on public.pedido_item
  for insert to authenticated
  with check (colportor_id = (select auth.uid()));

-- Privilegios por columna: el teléfono escribe solo lo que el servidor no decide. Una columna que sume un PR
-- futuro (autorizadas, decisión del coordinador) no queda abierta al teléfono por defecto.
grant insert (id, estado, created_at, deleted_at) on public.pedido_casa_editora to authenticated;
grant update (id, estado, created_at, deleted_at) on public.pedido_casa_editora to authenticated;
grant insert (id, pedido_id, producto_id, cantidad, created_at, deleted_at) on public.pedido_item to authenticated;

-- La dueña del pedido por default: el payload no la manda (columnas_servidor), sale del JWT.
alter table public.pedido_casa_editora
  alter column colportor_id set default auth.uid();

-- ----------------------------------------------------------------------------
-- 6. El registro en el motor de sync (contrato §2: push y pull de las propias)
-- ----------------------------------------------------------------------------

insert into sync.entidad (nombre, tabla, columna_pk, permite_push, columna_duenio) values
  ('pedido_casa_editora', 'public.pedido_casa_editora'::regclass, 'id', true, 'colportor_id'),
  ('pedido_item',         'public.pedido_item'::regclass,         'id', true, 'colportor_id');

-- Lo que decide el servidor no se escribe desde el teléfono (se descarta del payload aunque venga). El teléfono
-- manda el pedido con su id y su estado, y la línea con su pedido, su producto y su cantidad.
update sync.entidad
   set columnas_servidor = columnas_servidor
       || array['colportor_id', 'coordinador_id', 'fecha_pedido', 'monto_total', 'origen', 'excede_limite']
 where nombre = 'pedido_casa_editora';

update sync.entidad
   set columnas_servidor = columnas_servidor
       || array['colportor_id', 'precio_unitario', 'cantidad_recibida']
 where nombre = 'pedido_item';

-- ----------------------------------------------------------------------------
-- 7. La situación de la colportora antes de enviar
-- ----------------------------------------------------------------------------

-- p_items = [{"producto_id": uuid, "cantidad": entero > 0}, ...] (la misma forma que productos_devueltos de la
-- 0108; sin repetir producto) o null / [] para consultar sin pedido. Los productos se valúan con
-- `producto.precio_base_compra`, como lo hará el servidor al recibir el pedido.
create function public.situacion_para_pedido(p_items jsonb default null)
returns table (campania_id uuid, deuda_actual bigint, monto_pedido bigint, deuda_con_pedido bigint,
               por_cobrar bigint, libros_por_entregar integer,
               limite_deuda bigint, supera_limite_por bigint, stock jsonb)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_uid       uuid := auth.uid();
  v_monto     bigint := 0;
  v_sin       integer;
  v_campania  uuid;
  v_deuda     bigint;
  v_cobrar    bigint;
begin
  if v_uid is null then
    raise exception 'Entrá con tu cuenta para ver tu situación.'
      using errcode = 'insufficient_privilege';
  end if;

  if p_items is not null and p_items <> '[]'::jsonb then
    if not public.productos_devueltos_validos(p_items) then
      raise exception 'El pedido no tiene la forma esperada: una lista de productos con su cantidad (mayor que cero), sin repetir producto.'
        using errcode = 'invalid_parameter_value';
    end if;
    select coalesce(sum((e ->> 'cantidad')::bigint * pr.precio_base_compra), 0)::bigint,
           count(*) filter (where pr.id is null or pr.deleted_at is not null or pr.precio_base_compra is null)::integer
      into v_monto, v_sin
      from jsonb_array_elements(p_items) e
      left join public.producto pr on pr.id = (e ->> 'producto_id')::uuid and pr.deleted_at is null;
    if v_sin > 0 then
      raise exception 'Hay un producto que ya no está en el catálogo o no tiene precio de compra. Sacalo del pedido.'
        using errcode = 'invalid_parameter_value';
    end if;
  end if;

  select coalesce(cu.deuda_total, 0), coalesce(cu.dinero_por_cobrar, 0)
    into v_deuda, v_cobrar
    from (select 1) x
    left join public.cuenta_colportor cu on cu.usuario_id = v_uid and cu.deleted_at is null;

  v_campania := public.campania_del_ticket(v_uid, now());

  return query
    select v_campania,
           v_deuda,
           v_monto,
           v_deuda + v_monto,
           v_cobrar,
           (select coalesce(sum(en.cantidad), 0)::integer
              from public.venta v
              join public.entrega en on en.venta_id = v.id and en.deleted_at is null and en.pendiente
             where v.colportor_id = v_uid and v.deleted_at is null),
           (select c.limite_deuda from public.campania c where c.id = v_campania and c.deleted_at is null),
           public.supera_limite_de_deuda_por(v_uid, v_campania, v_monto),
           (select coalesce(jsonb_agg(jsonb_build_object('producto_id', s.producto_id,
                                                         'cantidad', s.cantidad_disponible)
                                      order by s.producto_id), '[]'::jsonb)
              from public.stock s
             where s.usuario_id = v_uid and s.deleted_at is null);
end;
$$;

comment on function public.situacion_para_pedido(jsonb) is
  'HU-STK-009 (0124, backend-supabase#102): la situación de quien llama antes de enviar su pedido: deuda actual '
  '(cuenta_colportor.deuda_total; sin cuenta = 0), monto del pedido que arma (p_items valuados con '
  'producto.precio_base_compra; null o [] = sin pedido), deuda con el pedido, por cobrar (dinero_por_cobrar), '
  'libros por entregar (unidades vendidas sin entregar), el límite de deuda de su campaña de hoy y cuánto lo '
  'supera el pedido (null si no lo supera o no hay límite) y su stock [{producto_id, cantidad}]. Solo montos y '
  'cantidades: ni clientes ni cobros. Errores: 42501 sin sesión; 22023 si los productos no tienen la forma '
  'esperada o alguno no existe o no tiene precio.';

revoke all on function public.situacion_para_pedido(jsonb) from public, anon, authenticated, service_role;
grant execute on function public.situacion_para_pedido(jsonb) to authenticated;
