-- ============================================================================
-- 0136 · La devolución dice de qué renglón de la venta salió cada libro, lleva su motivo (texto con aviso) y
--        devuelve los libros al stock del colportor
--        (backend-supabase#201, seguimiento de #134 / 0108, BACK-HU-VEN-004, ADR-002; decisiones de Cristian del
--        27/10, «Devol. combo», «Motivo devol.» y «Entrega desh»)
--
-- Caso 1 («Devol. combo»: por renglón). Ana vendió un combo de 2 libros (el renglón 7 de la venta, con
-- «Libro A» y «Libro B» adentro) y, aparte, un «Libro A» suelto (el renglón 8). El cliente devuelve el combo
-- entero: la devolución trae un elemento por libro, y cada uno dice de qué renglón salió:
--
--     [{"producto_id": A, "cantidad": 1, "venta_item_id": 7},
--      {"producto_id": B, "cantidad": 1, "venta_item_id": 7}]
--
-- Devolver el combo entero es devolver todos los libros de ese renglón. El mismo libro puede aparecer dos veces
-- si salió de dos renglones (el A del combo y el A suelto): lo que no se repite es el par (libro, renglón).
--
--   · `productos_devueltos` pasa a tener TRES claves por elemento: `producto_id`, `cantidad` y `venta_item_id`
--     (uuid en texto canónico), con la función nueva `devolucion_renglones_validos()` (la de dos claves,
--     `productos_devueltos_validos()`, queda para `situacion_para_pedido`). Cualquier otra forma es 23514 y el
--     push la vuelve `invalid`. Sigue sin guardar precios (salen de `venta_item`).
--   · El servidor comprueba el renglón (trigger `devolucion_productos`, 23503 / 23514, como una FK):
--       - el renglón existe (23503, `devolucion_renglon_existe`);
--       - es de ESTA venta (23514, `devolucion_renglon_de_la_venta`): no se devuelve contra el renglón de otra;
--       - el libro es el del renglón, o uno de los componentes del combo (23514, `devolucion_libro_del_renglon`).
--     No compara cantidades (no se rechaza una devolución real porque el teléfono y el servidor cuenten distinto:
--     «nunca se pierde una venta»; queda en el archivo de pendientes) ni mira si el renglón sigue vivo.
--   · «No hay datos que migrar» (Cristian): la tabla `devolucion` solo tiene datos de prueba. Las filas viejas
--     (dos claves por elemento) no se tocan; si alguna se vuelve a escribir, el CHECK nuevo la rechaza.
--
-- Caso 2 («Motivo devol.»: sube como texto, con aviso). La devolución gana `motivo`, opcional: texto libre que
-- sube por push y lee la coordinadora, como el motivo del monto manual de la venta (0071, 0128). El teléfono
-- avisa antes de guardar («Tu coordinador va a leer este motivo. No pongas datos del cliente.»); el servidor no
-- puede revisarlo. Mismo largo máximo que ese motivo (regla R2): hasta 500 caracteres, sin espacios ni saltos de
-- línea al principio ni al final, y un texto en blanco no entra (se manda null). El motivo NO se copia a
-- `audit_log` (texto libre: regla de 0073), ni a su detalle (0121).
--
-- Caso 3 («Entrega desh»: la devolución usa el mismo movimiento). Registrar una devolución suma al stock del
-- colportor los libros que vuelven (ADR-002, efecto 2): un movimiento `ENTRADA_DEVOLUCION` por libro (los
-- renglones de un mismo libro se suman) con `devolucion_id`, y el evento `stock_devuelto_por_devolucion` en
-- `audit_log` (ids y números). Una devolución que entra ya dada de baja (registrada y anulada sin conexión) no
-- mueve nada. El push repetido (`ON CONFLICT DO NOTHING`) no dispara el trigger de después: no suma dos veces.
-- La baja de una devolución ya hecha NO resta ese stock (pendiente §2 de esta entrega).
--
-- ## Para otros repos
--
--   · front-colportores-mobile#417 y #420: arman el payload por renglón (`venta_item_id` en cada elemento) y el
--     campo de motivo con su aviso. `invalid` con 23503 (renglón inexistente), 23514 (forma, renglón de otra
--     venta o libro que no es del renglón).
--   · front-coordinadores-web: el motivo de la devolución se lee con la lectura de devoluciones del equipo
--     (otro issue); esta migración solo lo guarda.
--   · docs-organizacion: esquema-datos.md, contrato-sync-engine.md §2, ADR-002 y HU-VEN-004: docs-organizacion#113.
--
-- Forward-only: esta migración no se edita una vez aplicada.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. La forma del JSON: tres claves por elemento
-- ----------------------------------------------------------------------------

-- Función nueva (la vieja, `productos_devueltos_validos`, sigue siendo la forma de dos claves que usa
-- `situacion_para_pedido`, 0124). Inmutable (la usa un CHECK): SQL puro, sin errores de cast. Lo que no tiene la
-- forma da false (23514).
create function public.devolucion_renglones_validos(p_productos jsonb)
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
                        else (select count(*) from jsonb_object_keys(e)) = 3
                             and jsonb_typeof(e -> 'producto_id') is not distinct from 'string'
                             and (e ->> 'producto_id') ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
                             and jsonb_typeof(e -> 'venta_item_id') is not distinct from 'string'
                             and (e ->> 'venta_item_id') ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
                             and jsonb_typeof(e -> 'cantidad') is not distinct from 'number'
                             and (e ->> 'cantidad') ~ '^[1-9][0-9]{0,8}$'
                      end)
     -- Sin repetir el par (libro, renglón): el mismo libro de dos renglones distintos sí vale.
     and (select count(distinct (lower(e ->> 'producto_id'), lower(e ->> 'venta_item_id')))
            from jsonb_array_elements(p_productos) e)
         = jsonb_array_length(p_productos);
$$;

comment on function public.devolucion_renglones_validos(jsonb) is
  'devolucion.productos_devueltos (0136): un arreglo de al menos un {producto_id uuid, cantidad entero > 0, '
  'venta_item_id uuid}, con esas tres claves y nada más, sin repetir el par (libro, renglón). false si no; el '
  'CHECK lo vuelve 23514.';

revoke all on function public.devolucion_renglones_validos(jsonb) from public, anon, authenticated, service_role;
grant execute on function public.devolucion_renglones_validos(jsonb) to authenticated, service_role;

-- El CHECK pasa a la forma nueva. Con filas viejas (de dos claves) no se puede validar sin inventar el renglón
-- de cada una: rige para lo nuevo (NOT VALID) y esas filas quedan como estaban, con un aviso. Sin filas, la forma
-- normal («no hay datos que migrar»).
alter table public.devolucion
  drop constraint devolucion_productos_validos;

do $mig$
begin
  if exists (select 1 from public.devolucion) then
    alter table public.devolucion
      add constraint devolucion_productos_validos
      check (public.devolucion_renglones_validos(productos_devueltos)) not valid;
    raise warning '0136: hay devoluciones sin renglón (de antes): el CHECK devolucion_productos_validos quedó NOT VALID para no inventar datos.';
  else
    alter table public.devolucion
      add constraint devolucion_productos_validos
      check (public.devolucion_renglones_validos(productos_devueltos));
  end if;
end
$mig$;

-- ----------------------------------------------------------------------------
-- 2. Cada libro existe y sale del renglón que dice
-- ----------------------------------------------------------------------------

create or replace function public.tg_devolucion_productos()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_faltante text;
  v_renglon  text;
begin
  -- Un JSON sin la forma no se juzga acá: lo rechaza el CHECK (23514) con su mensaje. (Los BEFORE triggers
  -- corren antes que los CHECK, y castear un id que no es uuid daría otro error.)
  if not public.devolucion_renglones_validos(new.productos_devueltos) then
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

  -- El renglón: existe (como una FK) ...
  select e ->> 'venta_item_id'
    into v_renglon
    from jsonb_array_elements(new.productos_devueltos) e
   where not exists (select 1 from public.venta_item i where i.id = (e ->> 'venta_item_id')::uuid)
   limit 1;

  if v_renglon is not null then
    raise exception using
      errcode = '23503',
      message = format('El renglón %s de la devolución no existe. Elegí de nuevo qué libros devuelve el cliente.', v_renglon),
      constraint = 'devolucion_renglon_existe';
  end if;

  -- Sin venta (o con una que no existe) no hay de qué venta ser: lo dicen el NOT NULL, la FK y la política.
  if new.venta_id is null or not exists (select 1 from public.venta v where v.id = new.venta_id) then
    return new;
  end if;

  -- ... es de ESTA venta ...
  select e ->> 'venta_item_id'
    into v_renglon
    from jsonb_array_elements(new.productos_devueltos) e
    join public.venta_item i on i.id = (e ->> 'venta_item_id')::uuid
   where i.venta_id is distinct from new.venta_id
   limit 1;

  if v_renglon is not null then
    raise exception using
      errcode = '23514',
      message = format('El renglón %s no es de esta venta. Elegí de nuevo qué libros devuelve el cliente.', v_renglon),
      constraint = 'devolucion_renglon_de_la_venta';
  end if;

  -- ... y el libro es el del renglón o un componente del combo.
  select e ->> 'producto_id'
    into v_faltante
    from jsonb_array_elements(new.productos_devueltos) e
    join public.venta_item i on i.id = (e ->> 'venta_item_id')::uuid
   where i.producto_id is distinct from (e ->> 'producto_id')::uuid
     and not exists (select 1
                       from jsonb_array_elements(coalesce(i.componentes, '[]'::jsonb)) c
                      where (c ->> 'producto_id')::uuid = (e ->> 'producto_id')::uuid)
   limit 1;

  if v_faltante is not null then
    raise exception using
      errcode = '23514',
      message = format('El libro %s no es de ese renglón de la venta. Elegí de nuevo qué libros devuelve el cliente.', v_faltante),
      constraint = 'devolucion_libro_del_renglon';
  end if;
  return new;
end;
$$;

comment on function public.tg_devolucion_productos() is
  'BEFORE INSERT / UPDATE OF productos_devueltos, venta_id de devolucion (0108, 0136): cada producto_id del JSON '
  'existe en producto (23503), cada venta_item_id existe (23503) y es de la venta de la devolución (23514), y '
  'el libro es el del renglón o un componente del combo (23514). Si el JSON no tiene la forma, no opina: lo '
  'rechaza el CHECK.';

drop trigger devolucion_productos on public.devolucion;
create trigger devolucion_productos
  before insert or update of productos_devueltos, venta_id on public.devolucion
  for each row execute function public.tg_devolucion_productos();

-- ----------------------------------------------------------------------------
-- 3. El motivo
-- ----------------------------------------------------------------------------

alter table public.devolucion
  add column motivo text;

alter table public.devolucion
  add constraint devolucion_motivo_forma
  check (motivo is null
         or (motivo ~ '^\S(.*\S)?$' and char_length(motivo) <= 500));

comment on column public.devolucion.motivo is
  'Por qué el cliente devuelve (opcional). Texto libre que sube con la devolución y lee el coordinador: igual que '
  'venta.motivo_monto_manual, hasta 500 caracteres y sin espacios ni saltos de línea en los bordes. La app avisa '
  'que no se pongan datos del cliente; el servidor no puede revisarlo. No se copia a audit_log (0136, #201).';

-- ----------------------------------------------------------------------------
-- 4. Los libros devueltos vuelven al stock del colportor
-- ----------------------------------------------------------------------------

-- Un movimiento por libro y devolución, una sola vez (el trigger corre solo para filas que de verdad entraron).
create unique index movimiento_stock_entrada_devolucion_key
  on public.movimiento_stock (devolucion_id, producto_id)
  where tipo = 'ENTRADA_DEVOLUCION' and deleted_at is null;

create function public.tg_devolucion_devuelve_stock()
returns trigger
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  r          record;
  v_despues  integer;
begin
  -- Registrada y anulada sin conexión, y sube todo junto: no hay nada que devolver.
  if new.deleted_at is not null then
    return null;
  end if;

  for r in
    select (e ->> 'producto_id')::uuid as prod_id, (sum((e ->> 'cantidad')::integer))::integer as cant
      from jsonb_array_elements(new.productos_devueltos) e
     group by 1
     order by 1
  loop
    -- Una fila de stock dada de baja cuenta como cero (como en 0126).
    insert into public.stock as s (usuario_id, producto_id, cantidad_disponible)
    values (new.colportor_id, r.prod_id, r.cant)
    on conflict (usuario_id, producto_id)
    do update set cantidad_disponible = case when s.deleted_at is null then s.cantidad_disponible else 0 end
                                        + excluded.cantidad_disponible,
                  deleted_at = null
    returning s.cantidad_disponible into v_despues;

    insert into public.movimiento_stock (usuario_id, producto_id, tipo, cantidad, fecha, devolucion_id)
    values (new.colportor_id, r.prod_id, 'ENTRADA_DEVOLUCION', r.cant, new.fecha_devolucion, new.id);

    perform auditoria.registrar(
      'stock_devuelto_por_devolucion', 'devolucion', new.id, new.colportor_id,
      jsonb_build_object('producto_id', r.prod_id,
                         'cantidad', r.cant,
                         'stock_antes', v_despues - r.cant,
                         'stock_despues', v_despues));
  end loop;
  return null;
end;
$$;

comment on function public.tg_devolucion_devuelve_stock() is
  'AFTER INSERT de devolucion (0136, #201, ADR-002 efecto 2): suma al stock del colportor los libros devueltos '
  '(los renglones de un mismo libro se suman), con un movimiento ENTRADA_DEVOLUCION por libro y el evento '
  'stock_devuelto_por_devolucion en audit_log. Una devolución que entra dada de baja no mueve nada. Nunca '
  'rechaza.';

revoke all on function public.tg_devolucion_devuelve_stock() from public, anon, authenticated, service_role;

create trigger devolucion_devuelve_stock
  after insert on public.devolucion
  for each row execute function public.tg_devolucion_devuelve_stock();
