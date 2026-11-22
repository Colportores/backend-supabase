-- ============================================================================
-- 0139 · La transferencia de stock se crea de dos formas: el colportor la pide desde el teléfono (push, como el
--        pedido a la casa editora) y el coordinador la arma desde el panel con «Pedir prestado» (una RPC)
--        (backend-supabase#201, seguimiento de #106 / 0126; decisión de Cristian del 27/10, «Quién pide»:
--        «los dos»)
--
-- 0126 y 0127 dejaron la bandeja, autorizar, rechazar y el número visible, pero NADA creaba una transferencia
-- (la fila la escribía el servidor). Las dos formas de crearla quedan por autorizar; las decide el coordinador
-- de la campaña (o el administrador) con lo de 0126.
--
-- ## 1. El colportor la pide desde el teléfono (push, entidades `transferencia_stock` y `transferencia_item`)
--
-- Ana necesita 2 libros y se los pide prestados a Beto; o Beto le ofrece los suyos a Ana (HU-STK-005: «solicitar
-- transferirle stock a otro colportor o recibir stock de él»). Quien la pide es UNA de las dos puntas:
--
--   · `transferencia_stock` y `transferencia_item` entran al push Y al pull (contrato §2): la transferencia se
--     arma sin conexión (cola de sync) y quien la pidió ve cómo sigue (autorizada, rechazada con su motivo) con lo
--     que baja del servidor. El pull baja SOLO las del solicitante (`solicitante_id`, `columna_duenio`); la otra
--     punta no la recibe por el pull (el aviso a los dos colportores es de HU-NOT).
--   · `solicitante_id` (nueva, en las dos tablas): quién la pidió desde el teléfono. Lo fija el servidor desde el
--     JWT y tiene que ser `origen_id` o `destino_id` (42501 si no: nadie pide una transferencia entre dos
--     terceros). Es null en la que arma el coordinador. En la línea la copia un trigger del encabezado (como
--     `pedido_item.colportor_id`, 0124) para que el pull filtre por una columna de la propia tabla.
--   · El teléfono manda la transferencia con { id, origen_id, destino_id, estado: 'PENDIENTE_AUTORIZACION' } y sus
--     líneas con { id, transferencia_id, producto_id, cantidad }; todo lo demás lo pone el servidor y vuelve en el
--     pull: `solicitante_id`, `numero` (el «T-18» de 0127), `fecha_solicitud` (cuándo LLEGÓ: así la campaña a la
--     que pertenece no depende del reloj del teléfono, como el pedido), `coordinador_id`, `monto_deuda`,
--     `decidido_en`, `motivo_rechazo` y el `precio_unitario` de cada línea (se fija al autorizar).
--   · Qué decide el servidor sobre el encabezado (trigger `transferencia_stock_del_cliente`, solo para
--     `authenticated`; el servidor y las RPC DEFINER no pasan por él):
--       - nace `PENDIENTE_AUTORIZACION` (23514 si el teléfono manda otro estado);
--       - quien llama es una de las dos puntas (42501);
--       - la otra punta es un compañero de la campaña: los dos inscriptos, sin baja, en una campaña que no terminó
--         (42501 con aviso). Lo pedido antes del inicio de la campaña entra igual: lo decide el administrador
--         (decisión «Campaña tr.», 0140).
--   · Qué decide sobre una línea (trigger `transferencia_item_del_cliente`): la transferencia es suya y sigue por
--     autorizar (42501 si es ajena, no existe o ya no se puede cambiar), el producto existe (23503, FK), la
--     cantidad es mayor que cero (23514, CHECK de 0067) y no se repite el producto (23505, unique de 0067). El
--     `precio_unitario` es siempre del servidor.
--   · Privilegios: el teléfono INSERTA solo (id, origen_id, destino_id, estado, created_at, deleted_at) en el
--     encabezado y (id, transferencia_id, producto_id, cantidad, created_at, deleted_at) en la línea; no actualiza
--     nada (una transferencia por autorizar no se edita desde el teléfono; cancelarla no está pedido todavía).
--   · Un reintento (replay del push, `ON CONFLICT DO NOTHING`) no se vuelve a validar: los BEFORE corren aun para
--     filas que no entran, así que lo que ya está no vuelve `invalid`.
--
-- ## 2. El coordinador la arma desde el panel: pedir_transferencia_de_stock
--
--   pedir_transferencia_de_stock(p_origen_id, p_destino_id, p_items jsonb)
--     -> (transferencia_id, numero, estado, fecha_solicitud)
--
--   «Pedir prestado» (vista 34): `p_items` = [{"producto_id": uuid, "cantidad": entero > 0}, ...], sin repetir
--   producto. Quien da y quien recibe tienen que ser dos colportores distintos, inscriptos sin baja en una
--   campaña de quien llama (o cualquiera si es ADMIN): el mismo permiso con que decide
--   (`coordina_la_transferencia(.., now(), true)`), así no arma lo que después no puede decidir. Queda por
--   autorizar, con `solicitante_id` null y `created_by` = quien la armó. No mueve stock ni deuda hasta que se
--   autoriza (0126). Deja el evento `transferencia_pedida` en audit_log (ids y números).
--   Errores: 42501 sin permiso (con aviso de qué hacer); TR007 la transferencia no tiene la forma: puntas iguales,
--   sin líneas, un producto repetido, una cantidad que no sirve o un producto que no existe.
--
-- ## Lo que NO hace
--
--   · No avisa a los colportores ni al coordinador (HU-NOT). No cancela desde el teléfono. No mira el stock de
--     quien da al pedirla (lo mira TR003 al autorizar, con el stock de ese momento).
--   · El texto libre «motivo» de HU-STK-005 no existe: ningún texto libre del teléfono sube sin decisión.
--
-- ## Los datos
--
-- Solo suma: dos columnas opcionales, tres índices, triggers, políticas, grants por columna, dos filas de
-- sync.entidad y dos funciones. Ninguna fila existente cambia (las tablas no estaban en el sync).
--
-- ## Para otros repos
--
--   · front-colportores-mobile#512 (espera diseño): entidades `transferencia_stock` y `transferencia_item`
--     (push + pull de las propias). `invalid` con 23514 (estado, puntas iguales, cantidad), 23503 (producto),
--     23505 (producto repetido) y 42501 (punta ajena, compañero fuera de la campaña, transferencia ya decidida).
--   · front-coordinadores-web#91 («Pedir prestado»): POST /rest/v1/rpc/pedir_transferencia_de_stock.
--   · docs-organizacion: HU-STK-005, esquema-datos.md y contrato-sync-engine.md §2: docs-organizacion#113.
--
-- Forward-only: esta migración no se edita una vez aplicada.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. solicitante_id
-- ----------------------------------------------------------------------------

alter table public.transferencia_stock
  add column solicitante_id uuid references public.usuario(id);

alter table public.transferencia_item
  add column solicitante_id uuid references public.usuario(id);

comment on column public.transferencia_stock.solicitante_id is
  'Quién pidió la transferencia desde el teléfono: origen_id o destino_id. Lo fija el servidor desde el JWT. null '
  'en la que arma el coordinador con «Pedir prestado» (0139). Es el dueño de la fila en el pull.';
comment on column public.transferencia_item.solicitante_id is
  'El solicitante de la transferencia, copiado del encabezado por un trigger (0139). Existe para que el pull filtre '
  'por una columna de la propia tabla; el teléfono no la manda.';

-- El delta con el dueño primero, para que el predicado entre en el Index Cond (0002 §14).
create index transferencia_stock_delta_idx on public.transferencia_stock (solicitante_id, xmin_w, id);
create index transferencia_item_delta_idx on public.transferencia_item (solicitante_id, xmin_w, id);
create index transferencia_item_transferencia_idx on public.transferencia_item (transferencia_id);

-- Por todo camino (el teléfono, el servidor, los tests): el dueño de la línea es el del encabezado. DEFINER para
-- leer el encabezado aunque la RLS lo esconda (una línea de una transferencia ajena o inexistente queda en null y
-- la frena la RLS o la FK).
create function public.tg_transferencia_item_solicitante()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  new.solicitante_id := (select t.solicitante_id from public.transferencia_stock t where t.id = new.transferencia_id);
  return new;
end;
$$;

comment on function public.tg_transferencia_item_solicitante() is
  'BEFORE INSERT de transferencia_item (0139): solicitante_id es el de la transferencia, venga de donde venga la línea.';

revoke all on function public.tg_transferencia_item_solicitante() from public, anon, authenticated, service_role;

create trigger transferencia_item_solicitante
  before insert on public.transferencia_item
  for each row execute function public.tg_transferencia_item_solicitante();

-- ----------------------------------------------------------------------------
-- 2. Ayudantes para los triggers del teléfono (SECURITY DEFINER, sin recibir al usuario: usan auth.uid())
-- ----------------------------------------------------------------------------

-- ¿Puede quien llama pedirle una transferencia a este colportor (o él a quien llama)? Los dos inscriptos, sin
-- baja, en una misma campaña que no terminó. DEFINER porque un colportor no lee la inscripción de otro. Lo
-- inexistente y lo ajeno dan lo mismo: false.
create function public.somos_companieros_de_campania(p_otro_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
      from public.campania c
      join public.campania_colportor a on a.campania_id = c.id and a.usuario_id = auth.uid()
      join public.campania_colportor b on b.campania_id = c.id and b.usuario_id = p_otro_id
     where c.deleted_at is null
       and a.deleted_at is null
       and b.deleted_at is null
       and (c.fecha_fin is null or public.hoy_montevideo(now()) <= c.fecha_fin));
$$;

comment on function public.somos_companieros_de_campania(uuid) is
  'true si quien llama (auth.uid()) y p_otro_id están inscriptos, sin baja, en una misma campaña que no terminó '
  '(0139): pueden pedirse una transferencia de stock. Interna: la llama el trigger de transferencia_stock.';

revoke all on function public.somos_companieros_de_campania(uuid) from public, anon, authenticated, service_role;
grant execute on function public.somos_companieros_de_campania(uuid) to authenticated;

-- ¿Por qué no se le pueden sumar líneas a esta transferencia de QUIEN LLAMA? null si se puede; AJENA si no es
-- suya o no existe (no se distingue); ESTADO si es suya pero ya no está por autorizar. Toma un candado
-- compartido sobre la transferencia hasta el final de la transacción: un coordinador que la autoriza a la vez
-- espera a que la línea quede, o la línea ve la transferencia ya decidida.
create function public.transferencia_no_acepta_lineas(p_transferencia_id uuid)
returns text
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_solicitante uuid;
  v_estado      text;
begin
  select t.solicitante_id, t.estado into v_solicitante, v_estado
    from public.transferencia_stock t
   where t.id = p_transferencia_id and t.deleted_at is null
     for share;
  if v_solicitante is null or v_solicitante is distinct from (select auth.uid()) then
    return 'AJENA';
  end if;
  if v_estado <> 'PENDIENTE_AUTORIZACION' then
    return 'ESTADO';
  end if;
  return null;
end;
$$;

comment on function public.transferencia_no_acepta_lineas(uuid) is
  'null si a esta transferencia de quien llama (auth.uid()) se le pueden sumar líneas; AJENA si es de otro o no '
  'existe; ESTADO si ya no está por autorizar (0139). Candado compartido sobre la transferencia. Interna.';

revoke all on function public.transferencia_no_acepta_lineas(uuid) from public, anon, authenticated, service_role;
grant execute on function public.transferencia_no_acepta_lineas(uuid) to authenticated;

-- ----------------------------------------------------------------------------
-- 3. Qué decide el servidor sobre una transferencia que llega del teléfono
-- ----------------------------------------------------------------------------

-- Alta. Los BEFORE corren aun para una fila que el push no inserta porque ya existía (INSERT ... ON CONFLICT DO
-- NOTHING): si la transferencia ya está, no se valida otra vez.
create function public.tg_transferencia_stock_del_cliente()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_otro uuid;
begin
  -- El servidor (service_role, el editor SQL, una función DEFINER) no pasa por acá. El push corre INVOKER como
  -- `authenticated` (patrón de 0053, 0100, 0113, 0122 y 0124).
  if current_user not in ('authenticated', 'anon') then
    return new;
  end if;

  -- Lo que decide el servidor (también llega descartado del payload: columnas_servidor). Va antes que el
  -- reintento: la RLS de alta mira `solicitante_id`, y la mira antes del ON CONFLICT.
  new.solicitante_id := auth.uid();
  new.coordinador_id := null;
  new.monto_deuda := null;
  new.decidido_en := null;
  new.motivo_rechazo := null;
  new.fecha_solicitud := now();

  if exists (select 1 from public.transferencia_stock t where t.id = new.id) then
    return new;
  end if;

  if new.estado is distinct from 'PENDIENTE_AUTORIZACION' then
    raise exception 'La transferencia se pide para que la autorice tu coordinador. Pedila desde la pantalla de transferencias.'
      using errcode = '23514', constraint = 'transferencia_del_colportor_nace_por_autorizar';
  end if;

  if new.origen_id is distinct from auth.uid() and new.destino_id is distinct from auth.uid() then
    raise exception 'Solo podés pedir una transferencia en la que vos das o recibís los libros.'
      using errcode = '42501';
  end if;

  v_otro := case when new.origen_id = auth.uid() then new.destino_id else new.origen_id end;
  if v_otro is not distinct from auth.uid() then
    return new;   -- las dos puntas son la misma persona: lo dice el CHECK de la tabla (23514)
  end if;

  if not public.somos_companieros_de_campania(v_otro) then
    raise exception 'Solo podés pedir una transferencia a un compañero de tu campaña (los dos inscriptos, sin baja, en una campaña que no terminó). Elegí otro colportor o hablá con tu coordinador.'
      using errcode = '42501';
  end if;
  return new;
end;
$$;

comment on function public.tg_transferencia_stock_del_cliente() is
  'BEFORE INSERT de transferencia_stock, solo para authenticated (0139): nace PENDIENTE_AUTORIZACION (23514), '
  'quien llama es una de las dos puntas y la otra es un compañero de su campaña (42501), y el servidor fija '
  'solicitante, fecha de solicitud y deja en blanco coordinador, deuda, decisión y motivo. El servidor no pasa '
  'por acá.';

revoke all on function public.tg_transferencia_stock_del_cliente() from public, anon, authenticated, service_role;

create trigger transferencia_stock_del_cliente
  before insert on public.transferencia_stock
  for each row execute function public.tg_transferencia_stock_del_cliente();

-- Línea. La transferencia es de quien llama y sigue por autorizar.
create function public.tg_transferencia_item_del_cliente()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_motivo text;
begin
  if current_user not in ('authenticated', 'anon') then
    return new;
  end if;

  new.precio_unitario := null;

  if exists (select 1 from public.transferencia_item i where i.id = new.id) then
    return new;
  end if;

  v_motivo := public.transferencia_no_acepta_lineas(new.transferencia_id);
  if v_motivo = 'AJENA' then
    raise exception 'Esa transferencia no es tuya o no existe. Pedila de nuevo desde la pantalla de transferencias.'
      using errcode = '42501';
  elsif v_motivo = 'ESTADO' then
    raise exception 'Esa transferencia ya no está por autorizar, así que no se le pueden sumar libros. Pedí una nueva.'
      using errcode = '42501';
  end if;
  return new;
end;
$$;

comment on function public.tg_transferencia_item_del_cliente() is
  'BEFORE INSERT de transferencia_item, solo para authenticated (0139): la transferencia es de quien llama y sigue '
  'por autorizar (42501), y el precio de cada línea es del servidor. El servidor no pasa por acá.';

revoke all on function public.tg_transferencia_item_del_cliente() from public, anon, authenticated, service_role;

create trigger transferencia_item_del_cliente
  before insert on public.transferencia_item
  for each row execute function public.tg_transferencia_item_del_cliente();

-- ----------------------------------------------------------------------------
-- 4. RLS y privilegios
-- ----------------------------------------------------------------------------

-- El colportor crea sus pedidos de transferencia (los del coordinador no pasan por acá: los carga la RPC).
create policy transferencia_stock_insert_propia on public.transferencia_stock
  for insert to authenticated
  with check (solicitante_id = (select auth.uid())
              and (origen_id = (select auth.uid()) or destino_id = (select auth.uid()))
              and estado = 'PENDIENTE_AUTORIZACION');

create policy transferencia_item_insert_propia on public.transferencia_item
  for insert to authenticated
  with check (solicitante_id = (select auth.uid()));

-- Privilegios por columna: el teléfono escribe solo lo que el servidor no decide. Una columna que sume un PR
-- futuro no queda abierta al teléfono por defecto. Sin UPDATE ni DELETE.
grant insert (id, origen_id, destino_id, estado, created_at, deleted_at) on public.transferencia_stock to authenticated;
grant insert (id, transferencia_id, producto_id, cantidad, created_at, deleted_at) on public.transferencia_item to authenticated;

-- ----------------------------------------------------------------------------
-- 5. El registro en el motor de sync (contrato §2: push y pull de las propias)
-- ----------------------------------------------------------------------------

insert into sync.entidad (nombre, tabla, columna_pk, permite_push, columna_duenio) values
  ('transferencia_stock', 'public.transferencia_stock'::regclass, 'id', true, 'solicitante_id'),
  ('transferencia_item',  'public.transferencia_item'::regclass,  'id', true, 'solicitante_id');

-- Lo que decide el servidor no se escribe desde el teléfono (se descarta del payload aunque venga).
update sync.entidad
   set columnas_servidor = columnas_servidor
       || array['solicitante_id', 'coordinador_id', 'fecha_solicitud', 'numero', 'monto_deuda', 'decidido_en',
                'motivo_rechazo']
 where nombre = 'transferencia_stock';

update sync.entidad
   set columnas_servidor = columnas_servidor || array['solicitante_id', 'precio_unitario']
 where nombre = 'transferencia_item';

-- ----------------------------------------------------------------------------
-- 6. «Pedir prestado»: la arma el coordinador desde el panel
-- ----------------------------------------------------------------------------

create function public.pedir_transferencia_de_stock(p_origen_id uuid, p_destino_id uuid, p_items jsonb)
returns table (transferencia_id uuid, numero bigint, estado text, fecha_solicitud timestamptz)
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_id        uuid;
  v_numero    bigint;
  v_fecha     timestamptz;
  v_unidades  bigint;
begin
  if auth.uid() is null or not (public.tiene_rol('ADMIN') or public.tiene_rol('COORDINADOR')) then
    raise exception 'Solo el coordinador de la campaña o un administrador puede armar una transferencia. Entrá con la cuenta del coordinador de esta campaña.'
      using errcode = 'insufficient_privilege';
  end if;

  if p_origen_id is null or p_destino_id is null or p_origen_id = p_destino_id then
    raise exception 'Elegí dos colportores distintos: el que da los libros y el que los recibe.'
      using errcode = 'TR007';
  end if;

  if not public.productos_devueltos_validos(p_items) then
    raise exception 'La transferencia tiene que llevar una lista de libros con su cantidad (mayor que cero), sin repetir ninguno. Corregí la lista y volvé a intentar.'
      using errcode = 'TR007';
  end if;

  if exists (select 1
               from jsonb_array_elements(p_items) e
              where not exists (select 1 from public.producto pr
                                 where pr.id = (e ->> 'producto_id')::uuid and pr.deleted_at is null)) then
    raise exception 'Hay un libro que ya no está en el catálogo. Sacalo de la transferencia y volvé a intentar.'
      using errcode = 'TR007';
  end if;

  -- El mismo permiso con que después la decide: los dos inscriptos sin baja en una campaña de quien llama (o
  -- cualquiera si es ADMIN). Sin esto armaría algo que no puede autorizar ni rechazar.
  if not public.coordina_la_transferencia(p_origen_id, p_destino_id, now(), true) then
    raise exception 'No podés armar esta transferencia: los dos colportores tienen que estar inscriptos, sin baja, en una campaña tuya que siga abierta. Si es un error, pedile a un administrador que la arme.'
      using errcode = 'insufficient_privilege';
  end if;

  insert into public.transferencia_stock as t (origen_id, destino_id)
  values (p_origen_id, p_destino_id)
  returning t.id, t.numero, t.fecha_solicitud into v_id, v_numero, v_fecha;

  insert into public.transferencia_item (transferencia_id, producto_id, cantidad)
  select v_id, (e ->> 'producto_id')::uuid, (e ->> 'cantidad')::integer
    from jsonb_array_elements(p_items) e;

  select coalesce(sum((e ->> 'cantidad')::bigint), 0) into v_unidades
    from jsonb_array_elements(p_items) e;

  perform auditoria.registrar(
    'transferencia_pedida', 'transferencia_stock', v_id, p_destino_id,
    jsonb_build_object('origen_id', p_origen_id,
                       'destino_id', p_destino_id,
                       'productos', jsonb_array_length(p_items),
                       'unidades', v_unidades,
                       'desde', 'panel'));

  return query select v_id, v_numero, 'PENDIENTE_AUTORIZACION'::text, v_fecha;
end;
$$;

comment on function public.pedir_transferencia_de_stock(uuid, uuid, jsonb) is
  'Vista 34 «Pedir prestado», HU-STK-005 (0139, backend-supabase#201, decisión «Quién pide» del 27/10): arma una '
  'transferencia de stock por autorizar de p_origen_id a p_destino_id con las líneas p_items '
  '[{producto_id, cantidad}]. Los dos tienen que estar inscriptos, sin baja, en una campaña de quien llama (o de '
  'cualquiera si es ADMIN). No mueve stock ni deuda hasta autorizarla. Deja transferencia_pedida en audit_log. '
  'Errores: 42501 sin permiso; TR007 puntas iguales, lista que no sirve o libro inexistente.';

revoke all on function public.pedir_transferencia_de_stock(uuid, uuid, jsonb)
  from public, anon, authenticated, service_role;
grant execute on function public.pedir_transferencia_de_stock(uuid, uuid, jsonb) to authenticated;
