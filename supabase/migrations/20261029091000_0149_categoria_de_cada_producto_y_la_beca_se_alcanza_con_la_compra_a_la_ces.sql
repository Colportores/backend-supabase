-- ============================================================================
-- 0149 · Categoría de cada producto y la beca que se alcanza con la compra a la CES
--        (backend-supabase#221, decisiones de Cristian del 28/10 «Categorías», «Meta CES» y «Beca alcanz.»;
--        HU-CAT, HU-BEC-002, S67)
--
-- Esta migración SOLO SUMA o redefine: ninguna fila se pierde. Las filas de `producto` se actualizan una vez (sube
-- su versión) para que la categoría baje al teléfono con el pull del catálogo.
--
-- ## 1. «Categorías»: una categoría por producto
--
-- Caso: Administración carga los productos y Ana los ve en Precios con su etiqueta. Cristian dijo: «categoría para
-- todo, bonificable como bool, facilita el cálculo para la beca teniendo como base la compra del CES». Las
-- categorías son cinco: Bonificables, Misioneros, Revistas, Espirituales y Material (los «jugos, alimentos,
-- Pamplonas» de las HU son nombres de ejemplo de libros bonificables, no productos aparte: «Jugos combo»).
--
--   · `producto.categoria` (obligatoria, una de `BONIFICABLES`, `MISIONEROS`, `REVISTAS`, `ESPIRITUALES`,
--     `MATERIAL`). `es_bonificable` sigue aparte, como sí/no: es lo que cuenta para la beca y para la compra a la
--     CES (§2). La categoría es la etiqueta; el booleano, el cálculo.
--   · Migración de los datos: cada `tipo` pasa a su categoría sin perder filas:
--         MISIONERO → MISIONEROS · REVISTA → REVISTAS · MATERIAL → MATERIAL ·
--         LIBRO bonificable → BONIFICABLES · LIBRO misionero → MISIONEROS · LIBRO común → ESPIRITUALES.
--   · `producto` baja la categoría por el pull del catálogo como cualquier columna (la entidad ya baja la fila
--     entera).
--   · TRANSICIÓN: `tipo` queda como columna heredada, ya sin NOT NULL, y un trigger mantiene las dos en el mismo
--     sentido (quien escribe solo la categoría deja el `tipo` que le corresponde; quien escribe solo el `tipo`, o
--     las pruebas y los scripts de antes, deja la categoría). Las lecturas que devuelven `producto_tipo`
--     (stock por ciudad, bandeja de pedidos y de transferencias) siguen igual. Quitar `tipo` y sus usos es una
--     migración de seguimiento cuando no quede ninguna lectura ni test que lo use (queda en el archivo de
--     pendientes de esta entrega).
--
-- ## 2. «Beca alcanz.»: la beca se alcanza con la compra de bonificables a la CES (HU-BEC-002, S67)
--
-- Caso: Juan lleva 100 de 120 libros bonificables y le compró a la CES $U 185.000 en bonificables, de una meta de
-- $U 180.000: queda «alcanzada». Si le compró $U 190.000 pero parte era de productos que no son bonificables, solo
-- cuenta lo bonificable («Meta CES»).
--
--   · `becas_de_campania()` suma por inscripto, al final de la fila:
--       - `libros_bonificables`: los libros bonificables vendidos en la campaña, menos los devueltos (ADR-002);
--         los de un combo cuentan cada uno por su cantidad (S63). Es la otra forma de ver el avance: NO dice
--         «alcanzada» por sí sola.
--       - `compra_ces`: lo que el colportor le compró a la casa editora en la campaña, en centavos: los pedidos
--         `RECIBIDO` de esa campaña (la de la fecha del pedido, `campania_del_ticket`), SOLO de productos con
--         `es_bonificable`, a la cantidad que recibió (`cantidad_recibida`, o la autorizada, o la pedida) por el
--         `precio_unitario` del pedido (el precio base de compra al pedir).
--       - `estado_beca`: `null` si no tiene tipo de beca asignado ni logró nada (R-BC06); `EN_PROGRESO` si
--         tiene tipo y la compra no llega a `meta_monto_ces`; `ALCANZADA` si la compra la alcanza.
--       - `beca_alcanzada_tipo`: el tipo (`MEDIA` o `COMPLETA`) que alcanzó, o `null`.
--   · «Logro beca»: lo alcanzado no se pierde (0132 §3). Si el coordinador cambia el tipo o las metas de una
--     inscripción que ya había alcanzado su meta (por ejemplo la pasa a «Sin beca», que deja las metas en null),
--     un trigger deja el evento `beca_alcanzada` en `audit_log` (inscripción, campaña, tipo, meta y compra) y
--     `becas_de_campania()` sigue devolviendo `ALCANZADA` con el tipo que alcanzó, aunque las metas de ahora ya no
--     lo muestren (S50).
--   · NO dispara la bonificación ni el push (HU-BEC-005, HU-NOT-003) ni se guarda un estado por inscripción: se
--     calcula al leer, como la cuenta del alquiler. El «Meta ciudad» (#145) no cambia.
--
-- ## Para otros repos
--
--   · front-colportores-mobile (#157 / PR 530): la réplica de `producto` trae `categoria`.
--   · front-coordinadores-web#122: Becas lee `libros_bonificables`, `compra_ces`, `estado_beca` y
--     `beca_alcanzada_tipo` de `becas_de_campania`. Los porcentajes y lo que falta los calcula el panel contra las
--     metas que la misma fila trae.
--   · docs-organizacion: esquema-datos.md (`producto.categoria`, las columnas nuevas de `becas_de_campania`),
--     HU-BEC-002 y S67: se piden en el cuerpo del PR.
--
-- Forward-only: esta migración no se edita una vez aplicada.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. Categoría de cada producto
-- ----------------------------------------------------------------------------

-- De un tipo viejo (y de si el libro es bonificable o misionero) a su categoría. Pura. null si el tipo no es uno
-- de los cuatro.
create function public.categoria_de_producto(p_tipo text, p_es_bonificable boolean, p_es_misionero boolean)
returns text
language sql
immutable
parallel safe
set search_path = ''
as $$
  select case
           when p_tipo = 'MISIONERO' then 'MISIONEROS'
           when p_tipo = 'REVISTA' then 'REVISTAS'
           when p_tipo = 'MATERIAL' then 'MATERIAL'
           when p_tipo = 'LIBRO' and coalesce(p_es_bonificable, false) then 'BONIFICABLES'
           when p_tipo = 'LIBRO' and coalesce(p_es_misionero, false) then 'MISIONEROS'
           when p_tipo = 'LIBRO' then 'ESPIRITUALES'
         end;
$$;

comment on function public.categoria_de_producto(text, boolean, boolean) is
  'La categoría (0149) que le corresponde a un producto con ese tipo viejo: MISIONERO → MISIONEROS, REVISTA → '
  'REVISTAS, MATERIAL → MATERIAL y LIBRO → BONIFICABLES (si es bonificable), MISIONEROS (si es misionero) o '
  'ESPIRITUALES. null si el tipo no es uno de los cuatro.';

-- De una categoría al tipo heredado que se mantiene mientras `tipo` exista.
create function public.tipo_de_categoria(p_categoria text)
returns text
language sql
immutable
parallel safe
set search_path = ''
as $$
  select case p_categoria
           when 'BONIFICABLES' then 'LIBRO'
           when 'ESPIRITUALES' then 'LIBRO'
           when 'MISIONEROS' then 'MISIONERO'
           when 'REVISTAS' then 'REVISTA'
           when 'MATERIAL' then 'MATERIAL'
         end;
$$;

comment on function public.tipo_de_categoria(text) is
  'El tipo heredado (LIBRO, REVISTA, MATERIAL o MISIONERO) que corresponde a una categoría (0149). Mientras exista '
  'producto.tipo, un trigger lo deja coherente con la categoría.';

-- Puras e inofensivas, pero el trigger las llama con los derechos de quien escribe el producto: las ejecuta quien
-- tiene sesión, no el anónimo.
revoke all on function public.categoria_de_producto(text, boolean, boolean) from public, anon, authenticated, service_role;
revoke all on function public.tipo_de_categoria(text) from public, anon, authenticated, service_role;
grant execute on function public.categoria_de_producto(text, boolean, boolean) to authenticated, service_role;
grant execute on function public.tipo_de_categoria(text) to authenticated, service_role;

alter table public.producto
  add column categoria text;

-- Los productos que ya había (también los dados de baja): cada tipo a su categoría. Sube su versión: la categoría
-- baja al teléfono con el próximo pull.
update public.producto
   set categoria = public.categoria_de_producto(tipo, es_bonificable, es_misionero);

alter table public.producto
  alter column categoria set not null;

alter table public.producto
  add constraint producto_categoria_check
  check (categoria in ('BONIFICABLES', 'MISIONEROS', 'REVISTAS', 'ESPIRITUALES', 'MATERIAL'));

-- `tipo` pasa a ser heredado: ya no es obligatorio.
alter table public.producto
  alter column tipo drop not null;

comment on column public.producto.categoria is
  'La categoría del producto (0149, «Categorías» del 28/10): BONIFICABLES, MISIONEROS, REVISTAS, ESPIRITUALES o '
  'MATERIAL. Una por producto, en lugar de `tipo`. `es_bonificable` sigue aparte, como sí/no: es lo que cuenta '
  'para la beca y para la compra a la CES.';
comment on column public.producto.tipo is
  'HEREDADO (0149): reemplazado por `categoria`. Un trigger lo mantiene coherente con ella mientras exista; las '
  'lecturas de antes (producto_tipo) lo siguen usando hasta la migración que lo quite.';

-- Las dos columnas en el mismo sentido. INSERT: si llega la categoría gana (el tipo se deriva de ella); si solo
-- llega el tipo (scripts y pruebas de antes), la categoría se deriva de él. UPDATE: cambia la que se tocó, y si se
-- tocaron las dos gana la categoría.
create function public.tg_producto_categoria_y_tipo()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if tg_op = 'INSERT' then
    if new.categoria is null then
      new.categoria := public.categoria_de_producto(new.tipo, new.es_bonificable, new.es_misionero);
    else
      new.tipo := public.tipo_de_categoria(new.categoria);
    end if;
  elsif new.categoria is distinct from old.categoria then
    new.tipo := public.tipo_de_categoria(new.categoria);
  elsif new.tipo is distinct from old.tipo then
    new.categoria := public.categoria_de_producto(new.tipo, new.es_bonificable, new.es_misionero);
  end if;
  return new;
end;
$$;

comment on function public.tg_producto_categoria_y_tipo() is
  'BEFORE INSERT OR UPDATE OF tipo, categoria de producto (0149): mantiene `categoria` y el `tipo` heredado en el '
  'mismo sentido. Gana la categoría; quien escribe solo el tipo deja la categoría que le corresponde.';

revoke all on function public.tg_producto_categoria_y_tipo() from public, anon, authenticated, service_role;

create trigger producto_categoria_y_tipo
  before insert or update of tipo, categoria on public.producto
  for each row execute function public.tg_producto_categoria_y_tipo();

-- ----------------------------------------------------------------------------
-- 2. La beca se alcanza con la compra de bonificables a la CES
-- ----------------------------------------------------------------------------

-- Lo que el colportor le compró a la casa editora en la campaña, solo de productos bonificables, en centavos: los
-- pedidos RECIBIDO cuya fecha cae en esa campaña (campania_del_ticket), a la cantidad que recibió (la recibida, o
-- la autorizada, o la pedida) por el precio unitario que quedó en el pedido. Interna: la llaman funciones DEFINER.
create function public.compra_a_la_ces(p_usuario_id uuid, p_campania_id uuid)
returns bigint
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(sum(coalesce(i.cantidad_recibida, i.cantidad_autorizada, i.cantidad)::bigint
                      * i.precio_unitario), 0)::bigint
    from public.pedido_casa_editora p
    join public.pedido_item i on i.pedido_id = p.id and i.deleted_at is null
    join public.producto pr on pr.id = i.producto_id and pr.es_bonificable
   where p.colportor_id = p_usuario_id
     and p.estado = 'RECIBIDO'
     and p.deleted_at is null
     and public.campania_del_ticket(p.colportor_id, p.fecha_pedido) = p_campania_id;
$$;

comment on function public.compra_a_la_ces(uuid, uuid) is
  'Lo que p_usuario_id le compró a la casa editora en la campaña, en centavos y solo de productos bonificables '
  '(0149, HU-BEC-002, «Meta CES»): los pedidos RECIBIDO de esa campaña, a la cantidad recibida (o autorizada, o '
  'pedida) por el precio unitario del pedido. Interna.';

revoke all on function public.compra_a_la_ces(uuid, uuid) from public, anon, authenticated, service_role;

-- Los libros bonificables vendidos en la campaña, menos los devueltos (ADR-002). Los de un combo cuentan cada uno
-- por su cantidad (S63). Nunca baja de cero. Interna.
create function public.libros_bonificables_de_la_campania(p_usuario_id uuid, p_campania_id uuid)
returns integer
language sql
stable
security definer
set search_path = ''
as $$
  with ventas as (
    select v.id
      from public.venta v
     where v.colportor_id = p_usuario_id
       and v.deleted_at is null
       and public.campania_del_ticket(v.colportor_id, v.fecha) = p_campania_id
  ),
  vendidos as (
    select vi.cantidad::bigint as cant
      from public.venta_item vi
      join ventas v on v.id = vi.venta_id
      join public.producto pr on pr.id = vi.producto_id and pr.es_bonificable
     where vi.deleted_at is null
    union all
    select vi.cantidad::bigint * (c ->> 'cantidad')::bigint
      from public.venta_item vi
      join ventas v on v.id = vi.venta_id
     cross join lateral jsonb_array_elements(coalesce(vi.componentes, '[]'::jsonb)) c
      join public.producto pr on pr.id = (c ->> 'producto_id')::uuid and pr.es_bonificable
     where vi.deleted_at is null and vi.producto_id is null
  ),
  devueltos as (
    select (e ->> 'cantidad')::bigint as cant
      from public.devolucion d
      join ventas v on v.id = d.venta_id
     cross join lateral jsonb_array_elements(d.productos_devueltos) e
      join public.producto pr on pr.id = (e ->> 'producto_id')::uuid and pr.es_bonificable
     where d.deleted_at is null
  )
  select greatest(coalesce((select sum(cant) from vendidos), 0) - coalesce((select sum(cant) from devueltos), 0), 0)::integer;
$$;

comment on function public.libros_bonificables_de_la_campania(uuid, uuid) is
  'Los libros bonificables que p_usuario_id vendió en la campaña, menos los devueltos (0149, HU-BEC-002): los de '
  'un combo cuentan cada uno por su cantidad (S63). Nunca baja de cero. Interna.';

revoke all on function public.libros_bonificables_de_la_campania(uuid, uuid)
  from public, anon, authenticated, service_role;

-- «Logro beca»: lo alcanzado no se pierde. Antes de que el tipo o la meta de una inscripción cambien (la pasan a
-- «Sin beca», le asignan otro tipo, la carrera corrige la meta), si la compra ya había alcanzado la meta de ahora
-- queda el evento beca_alcanzada. SECURITY DEFINER: corre con el JWT del coordinador y llama funciones internas.
create function public.tg_campania_colportor_beca_alcanzada()
returns trigger
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_compra bigint;
begin
  if old.tipo_beca is null or old.meta_monto_ces is null then
    return new;
  end if;
  if new.tipo_beca is not distinct from old.tipo_beca
     and new.meta_monto_ces is not distinct from old.meta_monto_ces then
    return new;
  end if;

  v_compra := public.compra_a_la_ces(old.usuario_id, old.campania_id);
  if v_compra >= old.meta_monto_ces then
    perform auditoria.registrar(
      'beca_alcanzada', 'campania_colportor', old.id, old.usuario_id,
      jsonb_build_object('campania_id', old.campania_id,
                         'tipo_beca', old.tipo_beca,
                         'meta_monto_ces', old.meta_monto_ces,
                         'compra_ces', v_compra));
  end if;
  return new;
end;
$$;

comment on function public.tg_campania_colportor_beca_alcanzada() is
  'BEFORE UPDATE OF tipo_beca, meta_monto_ces de campania_colportor (0149, «Logro beca»): si el tipo o la meta '
  'cambian y la compra a la CES ya había alcanzado la meta de antes, deja el evento beca_alcanzada en audit_log '
  '(inscripción, campaña, tipo, meta y compra) para que lo alcanzado no se pierda. No bloquea nada.';

revoke all on function public.tg_campania_colportor_beca_alcanzada() from public, anon, authenticated, service_role;

create trigger campania_colportor_beca_alcanzada
  before update of tipo_beca, meta_monto_ces on public.campania_colportor
  for each row execute function public.tg_campania_colportor_beca_alcanzada();

-- becas_de_campania: igual que en 0132 más el avance y el estado. Sumar columnas de salida pide drop + create +
-- los mismos privilegios.
drop function public.becas_de_campania(uuid);

create function public.becas_de_campania(p_campania_id uuid)
returns table (usuario_id uuid, nombre text, apellido text, carrera_id uuid, carrera_nombre text,
               carrera_elegida_en timestamptz, tipo_beca text, meta_libros integer, meta_monto_ces bigint,
               meta_configurada boolean, meta_recalculada_en timestamptz,
               libros_bonificables integer, compra_ces bigint, estado_beca text, beca_alcanzada_tipo text)
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_tipo_campania text;
begin
  perform public.exigir_coordinador_de_campania_para_beca(p_campania_id);

  select c.tipo into v_tipo_campania from public.campania c where c.id = p_campania_id;

  return query
    select u.id, u.nombre, u.apellido, ca.id, ca.nombre, u.carrera_elegida_en,
           cc.tipo_beca, cc.meta_libros, cc.meta_monto_ces,
           exists (select 1 from public.meta_beca mb
                    where mb.carrera_id = u.carrera_id and mb.tipo_campania = v_tipo_campania
                      and mb.deleted_at is null),
           -- La última vez que una corrección de carrera dejó a esta inscripción con la meta que tiene ahora.
           (select max(a.created_at)
              from auditoria.audit_log a
             where a.event_type = 'meta_de_beca_recalculada'
               and a.target_user_id = u.id and a.fila_id = cc.id
               and a.metadata ->> 'tipo_beca' = cc.tipo_beca
               and (a.metadata ->> 'meta_libros')::integer is not distinct from cc.meta_libros
               and (a.metadata ->> 'meta_monto_ces')::bigint is not distinct from cc.meta_monto_ces),
           av.libros, av.compra,
           -- Se alcanza con la compra a la CES; los libros son la otra forma de ver el avance (S67).
           case when av.alcanzada_ahora or av.tipo_previo is not null then 'ALCANZADA'
                when cc.tipo_beca is not null then 'EN_PROGRESO'
           end,
           -- Lo alcanzado no se pierde («Logro beca»): el mayor entre lo que alcanzó ahora y lo que ya había alcanzado
           -- (COMPLETA > MEDIA), aunque después le hayan bajado la beca.
           case when av.alcanzada_ahora and av.tipo_previo is not null
                  then case when 'COMPLETA' in (cc.tipo_beca, av.tipo_previo) then 'COMPLETA' else 'MEDIA' end
                when av.alcanzada_ahora then cc.tipo_beca
                else av.tipo_previo
           end
      from public.campania_colportor cc
      join public.usuario u on u.id = cc.usuario_id
      left join public.carrera ca on ca.id = u.carrera_id
     cross join lateral (
             select public.libros_bonificables_de_la_campania(u.id, cc.campania_id) as libros,
                    public.compra_a_la_ces(u.id, cc.campania_id) as compra) c1
     cross join lateral (
             select c1.libros, c1.compra,
                    (cc.tipo_beca is not null and cc.meta_monto_ces is not null
                     and c1.compra >= cc.meta_monto_ces) as alcanzada_ahora,
                    -- «Logro beca»: lo mejor que alcanzó antes de que le cambiaran el tipo o la meta (COMPLETA > MEDIA).
                    (select a.metadata ->> 'tipo_beca'
                       from auditoria.audit_log a
                      where a.event_type = 'beca_alcanzada' and a.fila_id = cc.id
                      order by (a.metadata ->> 'tipo_beca' = 'COMPLETA') desc, a.created_at desc, a.id desc
                      limit 1) as tipo_previo) av
     where cc.campania_id = p_campania_id
       and cc.deleted_at is null and u.deleted_at is null
     order by u.apellido, u.nombre, u.id;
end;
$$;

comment on function public.becas_de_campania(uuid) is
  'Vista 33, HU-BEC-002/004/006 (0117, 0132, 0149; backend-supabase#112, #202 y #221): los inscriptos vivos de '
  'p_campania_id con su carrera y cuándo se eligió (carrera_elegida_en), el tipo de beca asignado, las dos metas '
  'copiadas (libros y monto en centavos), si la carrera tiene meta cargada para el tipo de la campaña '
  '(meta_configurada), meta_recalculada_en (el aviso «Carrera corregida: meta de <carrera>») y, desde 0149, el '
  'avance: libros_bonificables (vendidos menos devueltos), compra_ces (lo comprado a la casa editora en '
  'bonificables, centavos), estado_beca (null | EN_PROGRESO | ALCANZADA: se alcanza con la compra a la CES) y '
  'beca_alcanzada_tipo (MEDIA | COMPLETA, aunque después le cambien el tipo: lo alcanzado no se pierde). Errores: '
  '42501 sin permiso; CZ001 inexistente; BC001 terminada.';

revoke all on function public.becas_de_campania(uuid) from public, anon, authenticated, service_role;
grant execute on function public.becas_de_campania(uuid) to authenticated;
