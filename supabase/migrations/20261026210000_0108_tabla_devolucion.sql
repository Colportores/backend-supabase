-- ============================================================================
-- 0108 · Tabla devolucion: lo devuelto y el reembolso en el momento, en la entidad del push
--        (backend-supabase#134, BACK-HU-VEN-004)
--
-- ADR-002 (una venta no se anula: se corrige con una devolución parcial libre) y la decisión de
-- Cristian del 23/10, «Reembolso» (front-colportores-mobile#161): «Dentro de la devolución». La
-- devolución guarda cuánto se le devolvió al cliente en el momento («Se lo devuelvo ahora»), sube con
-- ella y «En mano» lo resta. Destraba front-colportores-mobile#417 (la tabla local y el saldo) y #420
-- (la vista 31). La tabla `devolucion` solo estaba en el ADR-002: no existía en el esquema, ni en las
-- migraciones ni en el contrato §2.
--
-- ## Qué crea
--
--   · public.devolucion, una fila por devolución. La venta original NO se toca ni se anula: la
--     devolución se anota aparte y el saldo lo recalcula el teléfono con ella.
--
--       venta_id             la venta a la que se aplica (FK a venta; una venta puede tener varias
--                            devoluciones parciales).
--       productos_devueltos  jsonb `[{"producto_id": uuid, "cantidad": entero > 0}, ...]`, como el
--                            ADR-002: los productos y las cantidades que vuelven. Un arreglo con al
--                            menos un producto, sin repetir producto y con esas dos claves y nada más
--                            (CHECK con `productos_devueltos_validos()`, 23514). Cada producto_id
--                            tiene que existir en `producto` (trigger, 23503: una referencia dentro
--                            de un JSON no tiene FK). No guarda precios: salen de `venta_item`. En V1
--                            no hay stock ni beca (docs#69, front-colportores-mobile#161 P1): se
--                            guardan igual los productos y las cantidades, para que V2 recalcule
--                            stock y beca sin perder nada.
--       dinero_retenido      centavos, no negativo, 0 si no retiene nada: lo que la colportora se
--                            queda cuando el cliente pagó de más y elige «Lo retengo» (el saldo queda
--                            en cero). ADR-002; sin él, el saldo de un teléfono reinstalado no cierra.
--       monto_reembolsado    centavos, OPCIONAL (null = no devolvió plata): lo que se le devolvió al
--                            cliente en el momento, «Se lo devuelvo ahora». La mayoría de las
--                            devoluciones no devuelven plata (decisión «Debo cliente», 23/10): la
--                            columna va vacía. «En mano» lo resta. «Se lo devuelvo después» no
--                            guarda nada acá: el saldo negativo es «Debo al cliente».
--       fecha_devolucion     cuándo se registró, según el teléfono (sin default: puede subir días
--                            después, y el servidor no la inventa).
--       colportor_id         quién la registra: la colportora dueña de la venta. Lo fija el servidor
--                            desde el JWT (default auth.uid()) y se descarta del payload, como en
--                            venta (0002 §13).
--
--     Más las columnas de siempre (id, created_at, updated_at, created_by, deleted_at, sync_version,
--     xmin_w). Una devolución mal cargada se da de baja con `deleted_at` (anulación de una
--     devolución, ADR-002); nunca se borra.
--
--   · RLS: solo la colportora dueña (colportor_id = auth.uid()) y solo sobre una venta suya (el
--     WITH CHECK mira venta.colportor_id): no se anota una devolución sobre la venta de otra. Ni el
--     coordinador ni el ADMIN la leen por la tabla; la lectura del panel (devoluciones del equipo,
--     sin datos del cliente, ADR-004) y la devolución del coordinador pasadas las 72 h son de otros
--     issues. Sin DELETE.
--
--   · sync.entidad: ('devolucion', push, PK `id`, dueño `colportor_id`), sin alsoPull, contrato §2.
--     El pull de recover() baja las propias. Índice del delta con el dueño primero.
--
-- ## Lo que NO hace (y por qué)
--
--   · No guarda `motivo`. El ADR-002 lo prevé como texto libre y opcional, pero un texto libre que
--     puede nombrar a una persona no sube al servidor (0104; el «Otro» de 0072 tampoco). Queda como
--     pendiente de decisión de Cristian; sumarlo después es una migración que solo suma.
--   · No aplica la ventana de 72 h: la aplica la app (31-08) y la devolución del coordinador después
--     de las 72 h todavía no tiene su camino en el servidor.
--   · No compara los productos con los `venta_item` de la venta, ni el reembolso con lo cobrado: los
--     ítems y los cobros de la venta pueden llegar en otro lote del push, y rechazar una devolución
--     válida por el orden de llegada la dejaría atascada en el teléfono.
--   · No recalcula `house_status` (lo calcula el teléfono, ADR-003) ni toca stock o beca (V2).
--
-- ## Los datos
--
-- Solo suma: una tabla nueva (vacía), una función, un trigger, índices, una fila en sync.entidad y su
-- columnas_servidor. No hay UPDATE ni DELETE de datos: ninguna fila existente cambia, ni su
-- `sync_version` ni su `xmin_w` (los teléfonos no bajan nada de nuevo). Lo prueba
-- supabase/tests_migracion/0108_ok.
--
-- ## Para otros repos
--
--   · front-colportores-mobile#417 y el motor de sync: la entidad `devolucion` (push, sin alsoPull) y
--     sus columnas; la clave local debe ser un uuid por fila. El servidor responde `invalid` con
--     23514 si `productos_devueltos` no es un arreglo válido o un monto es negativo, 23503 si un
--     producto no existe, 42501 si la venta no existe o no es de la colportora (como en cobranza:
--     la política no la encuentra) y 23502 si falta la fecha. La fila viaja entera en el pull
--     (xmin_w no).
--   · docs-organizacion: esquema-datos.md (la tabla), contrato-sync-engine.md §2 (la fila) y
--     HU-VEN-004.
--
-- Forward-only: esta migración no se edita una vez aplicada.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. productos_devueltos_validos(): la forma del JSON
-- ----------------------------------------------------------------------------

-- Inmutable: la usa un CHECK. SQL puro, sin errores de cast: lo que no tiene la forma da false (23514),
-- no una excepción de otra clase. El grant a authenticated y service_role es de la función en un CHECK.
create function public.productos_devueltos_validos(p_productos jsonb)
returns boolean
language sql
immutable
parallel safe
set search_path = ''
as $$
  select p_productos is not null
     and jsonb_typeof(p_productos) = 'array'
     and jsonb_array_length(p_productos) >= 1
     and not exists (
           select 1
             from jsonb_array_elements(p_productos) e
            where not case
                        when jsonb_typeof(e) <> 'object' then false
                        else (select count(*) from jsonb_object_keys(e)) = 2
                             and jsonb_typeof(e -> 'producto_id') is not distinct from 'string'
                             and (e ->> 'producto_id') ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
                             and jsonb_typeof(e -> 'cantidad') is not distinct from 'number'
                             and (e ->> 'cantidad') ~ '^[1-9][0-9]{0,8}$'
                      end)
     -- Sin repetir producto: dos renglones del mismo producto son un renglón con la suma.
     and (select count(distinct lower(e ->> 'producto_id')) from jsonb_array_elements(p_productos) e)
         = jsonb_array_length(p_productos);
$$;

comment on function public.productos_devueltos_validos(jsonb) is
  'devolucion.productos_devueltos (0108): un arreglo de al menos un {producto_id uuid, cantidad entero > 0}, '
  'con esas dos claves y nada más, sin repetir producto. false si no; el CHECK lo vuelve 23514.';

revoke all on function public.productos_devueltos_validos(jsonb) from public, anon, authenticated, service_role;
grant execute on function public.productos_devueltos_validos(jsonb) to authenticated, service_role;

-- ----------------------------------------------------------------------------
-- 2. La tabla
-- ----------------------------------------------------------------------------

create table public.devolucion (
  id                   uuid primary key default public.uuid_generate_v7(),
  venta_id             uuid not null references public.venta(id),
  productos_devueltos  jsonb not null,
  dinero_retenido      integer not null default 0,           -- centavos
  monto_reembolsado    integer,                              -- centavos; null = no devolvió plata
  -- Sin default: la fecha de la devolución es la del teléfono (puede subir días después).
  fecha_devolucion     timestamptz not null,
  colportor_id         uuid not null default auth.uid() references public.usuario(id),
  created_at           timestamptz not null default now(),
  updated_at           timestamptz not null default now(),
  created_by           uuid default auth.uid() references public.usuario(id) on delete set null,
  deleted_at           timestamptz,
  sync_version         bigint not null default 0,
  xmin_w               xid8 not null default pg_current_xact_id(),
  constraint devolucion_productos_validos
    check (public.productos_devueltos_validos(productos_devueltos)),
  constraint devolucion_dinero_retenido_no_negativo
    check (dinero_retenido >= 0),
  constraint devolucion_monto_reembolsado_no_negativo
    check (monto_reembolsado is null or monto_reembolsado >= 0)
);

comment on table public.devolucion is
  'Devolución de una venta (ADR-002, HU-VEN-004): los productos y las cantidades que vuelven, el dinero que '
  'la colportora retiene y el que le devolvió al cliente en el momento. La venta original no se toca. Sin '
  'datos del cliente ni texto libre. Solo la colportora dueña la lee y la escribe. Sube por push (0108).';
comment on column public.devolucion.productos_devueltos is
  'jsonb [{producto_id, cantidad}], sin precios (salen de venta_item). Al menos un producto, sin repetir.';
comment on column public.devolucion.dinero_retenido is
  'Centavos que la colportora retiene cuando el cliente pagó de más («Lo retengo»). 0 si no retiene nada.';
comment on column public.devolucion.monto_reembolsado is
  'Centavos devueltos al cliente en el momento («Se lo devuelvo ahora»); «En mano» los resta. null = no devolvió plata.';
comment on column public.devolucion.fecha_devolucion is
  'Cuándo se registró la devolución, según el teléfono (puede subir días después).';
comment on column public.devolucion.colportor_id is
  'La colportora dueña de la venta y de la devolución. Lo fija el servidor desde el JWT; el payload no lo manda.';

create index devolucion_venta_idx on public.devolucion (venta_id);

-- El delta: el predicado de la RLS (colportor_id) primero, para que entre en el Index Cond (0002 §14).
create index devolucion_delta_idx on public.devolucion (colportor_id, xmin_w, id);

create trigger devolucion_auditoria_insert before insert on public.devolucion
  for each row execute function public.tg_auditoria_insert();
create trigger devolucion_auditoria_update before update on public.devolucion
  for each row execute function public.tg_auditoria_update();

-- ----------------------------------------------------------------------------
-- 3. Cada producto devuelto existe
-- ----------------------------------------------------------------------------

-- Un producto_id dentro del JSON no tiene FK: este trigger hace de ella (23503, como una FK, que el push
-- vuelve `invalid`). Corre como quien escribe (el catálogo lo lee todo autenticado). Solo mira que
-- exista, no que esté en la venta (ver el encabezado).
create function public.tg_devolucion_productos()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_faltante text;
begin
  -- Un JSON sin la forma no se juzga acá: lo rechaza el CHECK (23514) con su mensaje. (Los BEFORE triggers
  -- corren antes que los CHECK, y castear un id que no es uuid daría otro error.)
  if not public.productos_devueltos_validos(new.productos_devueltos) then
    return new;
  end if;

  select e ->> 'producto_id'
    into v_faltante
    from jsonb_array_elements(new.productos_devueltos) e
   where not exists (select 1 from public.producto p where p.id = (e ->> 'producto_id')::uuid)
   limit 1;

  if v_faltante is not null then
    raise exception using
      errcode = '23503',
      message = format('El producto %s de la devolución no existe en el catálogo.', v_faltante),
      constraint = 'devolucion_producto_existe';
  end if;
  return new;
end;
$$;

comment on function public.tg_devolucion_productos() is
  'BEFORE INSERT / UPDATE OF productos_devueltos de devolucion (0108): cada producto_id del JSON existe en '
  'producto (23503, como una FK). Si el JSON no tiene la forma, no opina: lo rechaza el CHECK.';

revoke all on function public.tg_devolucion_productos() from public, anon, authenticated, service_role;

create trigger devolucion_productos
  before insert or update of productos_devueltos on public.devolucion
  for each row execute function public.tg_devolucion_productos();

-- ----------------------------------------------------------------------------
-- 4. RLS: solo la colportora dueña, y sobre una venta suya
-- ----------------------------------------------------------------------------

alter table public.devolucion enable row level security;

create policy devolucion_select_propia on public.devolucion
  for select to authenticated
  using (colportor_id = (select auth.uid()));

create policy devolucion_insert_propia on public.devolucion
  for insert to authenticated
  with check (colportor_id = (select auth.uid())
              and exists (select 1 from public.venta v
                           where v.id = venta_id and v.colportor_id = (select auth.uid())));

-- USING = lo que ve; WITH CHECK = lo que escribe (0021): no se pasa una devolución a otra venta ajena.
create policy devolucion_update_propia on public.devolucion
  for update to authenticated
  using (colportor_id = (select auth.uid()))
  with check (colportor_id = (select auth.uid())
              and exists (select 1 from public.venta v
                           where v.id = venta_id and v.colportor_id = (select auth.uid())));

-- Sin política de DELETE ni privilegio: una baja es `deleted_at`.
revoke all on public.devolucion from anon, authenticated;
grant select, insert, update on public.devolucion to authenticated;
grant all on public.devolucion to service_role;

-- ----------------------------------------------------------------------------
-- 5. El registro en el motor de sync (contrato §2: push, sin alsoPull)
-- ----------------------------------------------------------------------------

-- Como venta (0002 §13), con el dueño nombrado: el pull baja solo las del usuario aunque algún día la RLS
-- se amplíe (columna_duenio, 0014).
insert into sync.entidad (nombre, tabla, columna_pk, permite_push, columna_duenio) values
  ('devolucion', 'public.devolucion'::regclass, 'id', true, 'colportor_id');

-- colportor_id decide qué filas ve el usuario: se descarta del payload (la RLS ya impide escribirlo a
-- nombre de otro, pero así un cliente no cree que se aplicó).
update sync.entidad
   set columnas_servidor = columnas_servidor || array['colportor_id']
 where nombre = 'devolucion';
