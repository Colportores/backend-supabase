-- ============================================================================
-- 0034 · Precio general de venta (Administración) y búsqueda «modificado o, si no hay, general»
--      (backend-supabase#78, HU-CAT-004, HU-CAT-005 y HU-CAT-006)
--
-- Decisión de Cristian del 06/10, «Precio gral.»
-- (https://github.com/Colportores/backend-supabase/pull/66#issuecomment-6026767874): «Es
-- Administracion pone un precio general, que eso queda para todos y en caso de alguien quiera puede
-- hacer una modificacion para una campaña en especifico». Coincide con el nombre que ya decidió para
-- la tabla de las excepciones (0030, `precio_por_ciudad`: «son casos muy específicos, la idea es tener
-- un precio general, y en casos específicos sufren modificaciones»).
--
-- ## Qué cambia
--
--   · Tabla nueva `public.precio_general`: el precio de venta de un producto o de una colección que
--     pone Administración y vale para TODAS las campañas del país (V1 es solo Uruguay: no lleva
--     pais_id ni moneda, igual que `precio_por_ciudad`). En centavos, con `valido_desde` y
--     `valido_hasta` (historial) y un solo precio vigente a la vez por producto o colección: las
--     mismas dos restricciones de no solapamiento de 0027, sin la ciudad. Forma elegida: una tabla
--     aparte y no una columna de `producto`, porque la vigencia y el historial piden una fila por
--     tramo, y la colección también tiene general. `precio_por_ciudad` NO se toca.
--   · Función `public.precio_vigente(campania_ciudad, producto, colección, fecha)`: devuelve el
--     precio modificado vigente de esa ciudad de la campaña o, si no hay, el general vigente, y dice
--     de cuál sale (`origen`: 'MODIFICADO' o 'GENERAL'). Sin ninguno de los dos: ninguna fila (el
--     producto no se ofrece, R-CT05 cambia así: solo se retira si no tiene ni modificado ni general).
--
-- ## Modelo de permisos
--
--   · ESCRIBE el general solo el ADMIN (insert y update; la baja es `deleted_at`, no hay DELETE).
--     Ni el coordinador ni el colportor: el coordinador modifica en `precio_por_ciudad`, que sigue
--     igual (escribe el ADMIN o el coordinador de esa campaña).
--   · LEE el general el ADMIN y quien hoy lee precios con una campaña: el que la coordina (aunque
--     haya terminado) y el colportor inscripto en una que no terminó (`mis_campanias_del_mapa()`,
--     0013, la misma regla que deja ver las ciudades de la campaña y con ellas `precio_por_ciudad`).
--     Un colportor sin campaña, o con la inscripción dada de baja o en una campaña terminada, no lo
--     lee. Las bajas lógicas se incluyen (la app necesita el tombstone para borrar su réplica).
--   · La tabla no tiene datos de personas ni de clientes: producto o colección, importe y fechas
--     (ADR-003, ADR-004: el coordinador ve montos, no clientes).
--   · `precio_vigente` es SECURITY INVOKER: la RLS sigue siendo la única autoridad (ADR-012) y la
--     función no repite ninguna regla de permisos. Para quien llama, la ciudad de la campaña tiene
--     que ser visible (política de `campania_ciudad`) y cada precio que lee pasa por la política de
--     su tabla. Una ciudad que no ve, o dada de baja, no devuelve nada: no devuelve el general
--     como si ahí no hubiera modificado, que sería una respuesta falsa. El ADMIN la usa para
--     cualquier ciudad y service_role (validaciones del servidor) para cualquiera, por RLS. Un
--     producto y una colección no se mezclan: pasa uno de los dos; la pertenencia del producto a una
--     colección no se resuelve (tampoco lo hacía `precio_por_ciudad`).
--   · `EXECUTE` de la función: authenticated y service_role; ni PUBLIC ni anon.
--
-- ## «Hoy» y las vigencias
--
-- Una fecha vale si cae en `daterange(valido_desde, valido_hasta, '[]')`: los dos extremos incluidos,
-- el mismo rango de las restricciones de no solapamiento. Sin fecha, la función usa
-- `public.hoy_montevideo()` (0024), no el `current_date` de la sesión (UTC). El `valido_desde` por
-- defecto de la tabla es también el día de Montevideo (la 0027 ya dio EXECUTE de esa función a
-- authenticated, que es quien inserta). Un precio nuevo vale para las ventas que se registren
-- después de guardarlo; las anteriores conservan el suyo en `venta_item.precio_unitario`: ni esta
-- tabla ni esa se tocan entre sí (no hay FK de la venta al precio).
--
-- ## Lo que esta migración NO hace (y por qué)
--
--   · Sync. El teléfono necesita el general para vender sin señal, pero el contrato de sync no se
--     toca acá (decisión de Cristian: va en un PR de docs aparte desde `main`, que revisa Bruno,
--     como pasó con `precio_por_ciudad`). La tabla NO se registra en `sync.entidad` hasta ese OK;
--     queda lista para el pull (columna `xmin_w` que exigen los triggers de auditoría, e índice del
--     delta `precio_general_delta_idx`), así que registrarla después es un `insert` en
--     `sync.entidad` más lo que diga el contrato (¿`sigue_campanias`? ¿filtro de alcance?).
--   · Realtime. La publicación `supabase_realtime` es hoy producto, coleccion, producto_coleccion y
--     precio_por_ciudad (test 0001 §8; ADR-012: «solo en tablas de catálogo y autorizaciones»):
--     sumar `precio_general` es parte del mismo PR de docs.
--   · La pantalla de Administración (después del 20/11): hasta entonces el general se carga con los
--     seeds y con docs/guia-carga-manual.md §8.
--   · `precio_por_ciudad` ni `venta_item` ni `producto.precio_base_compra` (el precio de COMPRA que
--     define Administración, HU-CAT-004 en su versión vieja): cambian cero filas.
--
-- ## Los datos
--
-- Tabla nueva y vacía: no hay `update` ni `delete` sobre nada que exista. No se migra ningún precio
-- (los precios por ciudad que ya hay siguen siendo las modificaciones).
--
-- ## Para otros repos
--
--   · front-coordinadores-web (vista 27, front-coordinadores-web#21): el panel NO lee
--     `precio_general` ni `precio_por_ciudad` con `.from()` (ADR-013: los clientes no hacen select
--     sobre tablas). La búsqueda de UN precio es `rpc/precio_vigente` con `p_campania_ciudad_id`,
--     `p_producto_id` o `p_coleccion_id` (uno solo) y, si se quiere, `p_fecha`; devuelve 0 o 1 fila
--     con `origen`, `precio_id`, `precio_venta` (centavos), `valido_desde` y `valido_hasta`.
--     Argumentos que no cierran (sin ciudad, sin producto ni colección, o los dos): 22023. Para
--     LISTAR los precios de una ciudad de la campaña la vista 27 va a necesitar una RPC de lectura
--     que todavía no existe (llamar a `precio_vigente()` producto por producto sería el N+1 que
--     ADR-013 descarta): issue de seguimiento backend-supabase#84 (S7), sin implementar acá.
--   · front-colportores-mobile y motor de sync (front-colportores-mobile#157 y #178): hasta el PR de
--     docs del contrato, el general no baja al teléfono; sigue bajando `precio_por_ciudad`. Avisar a
--     @BrunoFCapri.
--   · docs-organizacion: HU-CAT-004 (Administración), HU-CAT-005, HU-CAT-006, R-CT05, R-VE01 y
--     esquema-datos.md (la tabla `precio_general`), en el próximo PR de docs; contrato de sync (§2) y
--     ADR-012 si la entidad entra al pull y a Realtime.
--
-- Forward-only: esta migración no se edita una vez aplicada.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. La tabla
-- ----------------------------------------------------------------------------

create table public.precio_general (
  id            uuid primary key default public.uuid_generate_v7(),
  producto_id   uuid references public.producto(id),
  coleccion_id  uuid references public.coleccion(id),
  precio_venta  integer not null,                                  -- centavos
  valido_desde  date not null default public.hoy_montevideo(),
  valido_hasta  date,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  -- Quién lo cargó (el ADMIN que insertó, por la API); null si lo cargó el servidor o el SQL Editor.
  created_by    uuid default auth.uid() references public.usuario(id) on delete set null,
  deleted_at    timestamptz,
  sync_version  bigint not null default 0,
  xmin_w        xid8 not null default pg_current_xact_id(),
  -- Exactamente uno de producto_id / coleccion_id, como precio_por_ciudad.
  constraint precio_general_producto_o_coleccion_check
    check ((producto_id is null) <> (coleccion_id is null)),
  constraint precio_general_precio_venta_check
    check (precio_venta >= 0),
  constraint precio_general_vigencia_check
    check (valido_hasta is null or valido_hasta >= valido_desde)
);

comment on table public.precio_general is
  'Precio de venta general de un producto o una colección: lo pone Administración y vale para todas '
  'las campañas del país (0034, decisión de Cristian del 06/10, «Precio gral.»). Las campañas lo '
  'modifican por ciudad en precio_por_ciudad. Centavos, con vigencia e historial: un solo precio '
  'vigente a la vez por producto o colección. Un precio nuevo vale para las ventas siguientes: '
  'venta_item guarda el suyo. Lo escribe solo el ADMIN; lo lee quien hoy lee precios con una '
  'campaña. Todavía no baja al teléfono (espera el contrato de sync).';
comment on column public.precio_general.precio_venta is
  'Importe en centavos, entero y >= 0 (el ejemplar misionero va a 0: se entrega, no se vende).';
comment on column public.precio_general.valido_desde is
  'Primer día en que vale (inclusive), según el día de Montevideo.';
comment on column public.precio_general.valido_hasta is
  'Último día en que vale (inclusive); null = vigente hasta nuevo aviso.';
comment on column public.precio_general.created_by is
  'El ADMIN que lo cargó, si entró por la API; lo fija el DEFAULT. null si lo cargó el servidor.';

-- Sin dos precios generales vigentes a la vez para lo mismo: «el precio general actual» tiene que
-- ser una sola fila. Una por producto y otra por colección (el check de la tabla garantiza que solo
-- una de las dos columnas está cargada). Un precio dado de baja (deleted_at) no cuenta. Los dos
-- índices GiST que respaldan estas restricciones también sirven la búsqueda por producto o colección
-- y fecha, y cubren las FK.
alter table public.precio_general
  add constraint precio_general_producto_sin_solape
  exclude using gist (
    producto_id with =,
    daterange(valido_desde, valido_hasta, '[]') with &&
  ) where (deleted_at is null and producto_id is not null);

alter table public.precio_general
  add constraint precio_general_coleccion_sin_solape
  exclude using gist (
    coleccion_id with =,
    daterange(valido_desde, valido_hasta, '[]') with &&
  ) where (deleted_at is null and coleccion_id is not null);

-- El cursor del delta, para cuando el contrato de sync la registre (0002 §14). Hoy nadie lo usa.
create index precio_general_delta_idx on public.precio_general (xmin_w, id);

create trigger precio_general_auditoria_insert before insert on public.precio_general
  for each row execute function public.tg_auditoria_insert();
create trigger precio_general_auditoria_update before update on public.precio_general
  for each row execute function public.tg_auditoria_update();

-- ----------------------------------------------------------------------------
-- 2. RLS: lee quien ve precios con una campaña; escribe solo el ADMIN
-- ----------------------------------------------------------------------------

alter table public.precio_general enable row level security;

-- Incluye las bajas lógicas: la app necesita el tombstone. `exists (…)` no depende de la fila: el
-- planner lo evalúa una vez por consulta (InitPlan), como las llamadas envueltas en (select …).
create policy precio_general_select on public.precio_general
  for select to authenticated
  using ((select public.tiene_rol('ADMIN'))
         or exists (select 1 from public.mis_campanias_del_mapa()));

create policy precio_general_insert_admin on public.precio_general
  for insert to authenticated
  with check ((select public.tiene_rol('ADMIN')));

-- USING = lo que ve para modificar; WITH CHECK = lo que puede dejar escrito (0021).
create policy precio_general_update_admin on public.precio_general
  for update to authenticated
  using ((select public.tiene_rol('ADMIN')))
  with check ((select public.tiene_rol('ADMIN')));

-- Sin política de DELETE ni privilegio: una baja es `deleted_at`. Los grants van explícitos: los
-- default privileges de `public` dependen de cómo se creó el schema (0008).
revoke all on public.precio_general from anon, authenticated;
grant select, insert, update on public.precio_general to authenticated;
grant all on public.precio_general to service_role;

-- ----------------------------------------------------------------------------
-- 3. La búsqueda «modificado o, si no hay, general»
-- ----------------------------------------------------------------------------

create function public.precio_vigente(
  p_campania_ciudad_id  uuid,
  p_producto_id         uuid default null,
  p_coleccion_id        uuid default null,
  p_fecha               date default null
)
returns table (
  origen        text,
  precio_id     uuid,
  precio_venta  integer,
  valido_desde  date,
  valido_hasta  date
)
language plpgsql
stable
set search_path = ''
as $$
declare
  v_fecha date := coalesce(p_fecha, public.hoy_montevideo());
begin
  if p_campania_ciudad_id is null
     or (p_producto_id is null) = (p_coleccion_id is null) then
    raise exception 'precio_vigente pide la ciudad de la campaña y, o un producto, o una colección (uno solo de los dos).'
      using errcode = '22023',
            hint = 'Pasá p_campania_ciudad_id y p_producto_id, o p_campania_ciudad_id y p_coleccion_id.';
  end if;

  return query
    select x.origen, x.precio_id, x.precio_venta, x.valido_desde, x.valido_hasta
      from (
        -- La ciudad de la campaña tiene que existir y verla quien llama (la RLS de campania_ciudad).
        with ciudad as (
          select cc.id
            from public.campania_ciudad cc
           where cc.id = p_campania_ciudad_id
             and cc.deleted_at is null
        )
        select 'MODIFICADO'::text as origen, 1 as orden,
               p.id as precio_id, p.precio_venta, p.valido_desde, p.valido_hasta
          from ciudad c
          join public.precio_por_ciudad p on p.campania_ciudad_id = c.id
         where p.deleted_at is null
           and (p.producto_id = p_producto_id or p.coleccion_id = p_coleccion_id)
           and daterange(p.valido_desde, p.valido_hasta, '[]') @> v_fecha
        union all
        select 'GENERAL'::text, 2,
               g.id, g.precio_venta, g.valido_desde, g.valido_hasta
          from ciudad c
         cross join public.precio_general g
         where g.deleted_at is null
           and (g.producto_id = p_producto_id or g.coleccion_id = p_coleccion_id)
           and daterange(g.valido_desde, g.valido_hasta, '[]') @> v_fecha
      ) x
     -- El modificado gana al general; las restricciones de no solapamiento garantizan que hay a lo
     -- sumo uno de cada uno, el orden y el límite son una red de seguridad.
     order by x.orden, x.valido_desde desc, x.precio_id
     limit 1;
end;
$$;

comment on function public.precio_vigente(uuid, uuid, uuid, date) is
  'El precio de venta de un producto o de una colección en una ciudad de una campaña en una fecha '
  '(por defecto, hoy en Montevideo): el modificado vigente de precio_por_ciudad o, si no hay, el '
  'general vigente de precio_general; origen dice de cuál sale (MODIFICADO o GENERAL). Sin ninguno '
  'de los dos, o con una ciudad que quien llama no ve o que está dada de baja: ninguna fila (el '
  'producto no se ofrece, R-CT05). Pasar la ciudad y uno solo de producto o colección (22023 si no). '
  'SECURITY INVOKER: la RLS decide qué ve cada uno (0034, backend-supabase#78).';

revoke all on function public.precio_vigente(uuid, uuid, uuid, date)
  from public, anon, authenticated;
grant execute on function public.precio_vigente(uuid, uuid, uuid, date)
  to authenticated, service_role;
