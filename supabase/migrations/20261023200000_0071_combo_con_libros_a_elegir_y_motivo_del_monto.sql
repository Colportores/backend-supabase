-- ============================================================================
-- 0071 · Combo con N libros a elegir, lo que traía el combo al venderlo, motivo del monto manual y
--        talonario único por año (backend-supabase#138, HU-CAT-009 y HU-VEN-001; decisiones de
--        Cristian del 23/10 en front-colportores-mobile#158 y backend-supabase#128, y del
--        orquestador por el mapa: «Talonario por año»)
--
-- Cuatro cambios en la venta, todos aditivos salvo el índice del talonario (que se afloja):
--
--   1. «Colección N» · `coleccion.libros_a_elegir` (integer NOT NULL, default 0, >= 0).
--      Además de lo fijo (`producto_coleccion`), un combo puede sumar «N libros a elegir»: Ana vende
--      una «Colección de 2 libros» y elige los dos al vender. Cada tamaño es UNA colección con su
--      precio (general o de la ciudad, como cualquier combo), así que no hay tabla de tamaños ni de
--      precios nuevos. 0 es un combo fijo, como los de la 0056: ninguna colección existente cambia.
--      `precios_de_la_ciudad()` trae la columna (sección 5) y el pull de `coleccion` la lleva sola
--      (el sync serializa todas las columnas de la tabla).
--
--   2. «Combo vendido» · `venta_item.componentes` (jsonb). Al vender un combo, el teléfono copia en
--      el ítem qué traía: `[{"producto_id": "<uuid>", "cantidad": 2}, …]`, igual que ya copia el
--      precio en `precio_unitario`. Cambiar el combo después (la 0056 permite subir la `cantidad` de
--      un componente) no toca ninguna venta hecha, y el stock de V2 descuenta lo que dice la venta.
--        · Es lo que traía UNA unidad del combo (el ítem multiplica por su `cantidad`): «dos Pack
--          Familiar con 1 libro y 2 revistas» guardan 1 libro y 2 revistas, no 2 y 4. Lo fijo y lo
--          elegido van juntos; lo elegido puede repetirse (el mismo libro en dos elementos, o uno
--          solo con `cantidad` 2: las dos formas valen).
--        · CHECK `venta_item_componentes_solo_en_combo`: obligatorio en un ítem de combo
--          (`coleccion_id` no nulo) y nulo en uno suelto, como `producto_id` y `coleccion_id`.
--        · CHECK `venta_item_componentes_forma`: un arreglo NO vacío de objetos con EXACTAMENTE las
--          claves `producto_id` (uuid en texto canónico) y `cantidad` (entero de 1 a 999999999, sin
--          decimales ni notación científica). Cualquier otra forma es 23514 y el job vuelve
--          `invalid` en el push. La regla vive en `componentes_de_venta_validos(jsonb)` (pura).
--        · NO se valida contra el catálogo: que el producto exista o siga vivo, que sume lo que dice
--          la colección o que respete `libros_a_elegir`. La venta se hace sin conexión con el
--          catálogo del teléfono y una venta hecha nunca se rechaza por el catálogo (no hay FK: un
--          jsonb no la tiene, y es lo que se quiere: el producto puede darse de baja después).
--        · Las columnas escribibles del push salen del catálogo: `componentes` entra sola.
--
--   3. «Monto manual» · `venta.motivo_monto_manual` (text, opcional). Cuando Ana baja el total de
--      $ 8.900 a $ 8.500 escribe «descuento por pago en efectivo»: el texto sube con la venta y lo
--      lee el coordinador. Es una EXCEPCIÓN EXPLÍCITA de Cristian a «Justificar» y a la regla de
--      que ningún texto libre sube al servidor (el 0001 prohíbe `texto`/`notas`): este campo, y solo
--      él. La app avisa antes de guardar («Tu coordinador va a leer este motivo. No pongas datos del
--      cliente.»); el servidor no puede revisarlo.
--        · CHECK `venta_motivo_monto_manual_forma`: null, o un texto sin espacios ni saltos de línea
--          al principio y al final (el mismo `^\S(.*\S)?$` de `ciudad.departamento`, 0066) de hasta
--          500 caracteres (`char_length`, no bytes). Un texto en blanco no entra (se manda null).
--          No se exige cuando el total difiere de la suma de los ítems: el descuento informal sigue
--          sin atarse (0001) y exigirlo sería perder una venta por un motivo que el teléfono ya pide.
--        · El tope de 500 es el de `motivo_rechazo` (0067): el issue no da el número (pendiente §2).
--
--   4. «Talonario por año» · el índice único pasa de (colportor, número) a (colportor, número, AÑO de
--      la fecha de la venta en hora de Uruguay), sobre las ventas vivas. R-VE02: «único por colportor
--      + año». El de la 0001 era más estricto que la HU sin que nadie lo decidiera y rechazaría una
--      venta real del año siguiente. La función `anio_de_la_venta(timestamptz)` es la única
--      definición del «año» (America/Montevideo, no el de la sesión: el 31/12 a las 23:30 en Uruguay
--      ya es el 01/01 en UTC) y es IMMUTABLE para poder estar en el índice.
--
-- ## Los datos
--
--   · `coleccion.libros_a_elegir` y `venta.motivo_monto_manual` se suman con default 0 / null: ninguna
--     fila se reescribe ni cambia de versión de sync.
--   · El índice nuevo es MÁS FLOJO que el viejo (agrega una columna a la clave): todo lo que cumplía
--     el viejo cumple el nuevo, así que no hay datos que arreglar ni filas que tocar.
--   · Los ítems de combo que ya existen (0056, ninguno en producción: hay datos de prueba) no tienen
--     `componentes` y el CHECK los rechazaría. Se completan con la composición VIVA del combo hoy
--     (`producto_coleccion.cantidad`; si no le queda ningún vivo, con la de los vínculos dados de
--     baja): es la mejor foto posible de lo que traía, y esas filas suben su versión de sync una vez
--     para que los teléfonos la reciban (un teléfono con una edición vieja de ese ítem recibe
--     `conflict`, como en la 0068). Si un combo no tuvo NUNCA un componente, su ítem no se puede
--     completar sin inventar: en ese caso el CHECK de «solo en combo» se agrega NOT VALID (rige para
--     toda fila nueva o modificada, y esa fila vieja sigue como estaba) y se avisa con un WARNING; no
--     se borra ni se inventa nada.
--
-- ## Para otros repos
--   · front-colportores-mobile (#425, 27A·01 a 27A·06; #423): la tabla local `coleccion` suma
--     `libros_a_elegir` y `venta_item` suma `componentes` (JSON) y `venta` suma `motivo_monto_manual`;
--     el índice local de talonario pasa a incluir el año de Montevideo. El teléfono arma `componentes`
--     al vender un combo (lo fijo de `producto_coleccion` y los libros elegidos).
--   · front-coordinadores-web: `precios_de_la_ciudad()` trae `libros_a_elegir` (null en un producto).
--     El coordinador NO tiene hoy una lectura de ventas una por una (ve totales por
--     `ventas_por_ciudad_y_colportor`, 0061): ver el archivo de pendientes de esta entrega.
--   · docs-organizacion: `esquema-datos.md` (venta, venta_item, coleccion), `contrato-sync-engine.md`
--     (payload de venta e ítem), HU-CAT-009, HU-VEN-001 y la excepción en la regla «Justificar».
--
-- Forward-only: esta migración no se edita una vez aplicada.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. «Colección N»: cuántos libros elige quien vende
-- ----------------------------------------------------------------------------

alter table public.coleccion
  add column libros_a_elegir integer not null default 0;

alter table public.coleccion
  add constraint coleccion_libros_a_elegir_no_negativo
  check (libros_a_elegir >= 0);

comment on column public.coleccion.libros_a_elegir is
  'Cuántos libros del catálogo elige quien vende, además de lo fijo del combo (producto_coleccion). '
  '0 = combo fijo (0056). Una «Colección de 2 libros» es una colección con 2 aquí y su propio '
  'precio, general o de la ciudad (0071, backend-supabase#138, HU-CAT-009).';

-- ----------------------------------------------------------------------------
-- 2. «Combo vendido»: lo que traía el combo, copiado en el ítem
-- ----------------------------------------------------------------------------

-- La forma de venta_item.componentes. Pura e IMMUTABLE (la usa un CHECK): no mira ninguna tabla.
-- Sin EXECUTE para anon ni public: un CHECK la ejecuta con quien inserta (authenticated por
-- PostgREST, o service_role), y el push con el dueño de sync.push.
create function public.componentes_de_venta_validos(p_componentes jsonb)
returns boolean
language plpgsql
immutable
parallel safe
set search_path = ''
as $$
declare
  v_e  jsonb;
begin
  if p_componentes is null
     or jsonb_typeof(p_componentes) <> 'array'
     or jsonb_array_length(p_componentes) = 0 then
    return false;
  end if;

  for v_e in select e.v from jsonb_array_elements(p_componentes) as e(v) loop
    if jsonb_typeof(v_e) <> 'object'
       or (select count(*) from jsonb_object_keys(v_e)) <> 2
       or not (v_e ? 'producto_id')
       or not (v_e ? 'cantidad') then
      return false;
    end if;
    if jsonb_typeof(v_e -> 'producto_id') <> 'string'
       or (v_e ->> 'producto_id') !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then
      return false;
    end if;
    if jsonb_typeof(v_e -> 'cantidad') <> 'number'
       or (v_e ->> 'cantidad') !~ '^[1-9][0-9]{0,8}$' then
      return false;
    end if;
  end loop;

  return true;
end;
$$;

comment on function public.componentes_de_venta_validos(jsonb) is
  'La forma de venta_item.componentes (0071, backend-supabase#138): un arreglo no vacío de objetos '
  'con exactamente producto_id (uuid en texto) y cantidad (entero de 1 a 999999999). No mira el '
  'catálogo: una venta hecha nunca se rechaza por él. Pura, IMMUTABLE; la usa un CHECK.';

revoke all on function public.componentes_de_venta_validos(jsonb)
  from public, anon, authenticated, service_role;
grant execute on function public.componentes_de_venta_validos(jsonb)
  to authenticated, service_role;

alter table public.venta_item
  add column componentes jsonb;

-- Los ítems de combo de antes: lo que trae el combo hoy (la mejor foto posible de lo que traía).
update public.venta_item i
   set componentes = (
         select jsonb_agg(jsonb_build_object('producto_id', pc.producto_id, 'cantidad', pc.cantidad)
                          order by pc.producto_id)
           from public.producto_coleccion pc
          where pc.coleccion_id = i.coleccion_id
            and pc.deleted_at is null)
 where i.coleccion_id is not null
   and i.componentes is null
   and exists (select 1 from public.producto_coleccion pc
                where pc.coleccion_id = i.coleccion_id and pc.deleted_at is null);

-- Y si al combo no le queda ningún componente vivo, los de los vínculos dados de baja.
update public.venta_item i
   set componentes = (
         select jsonb_agg(jsonb_build_object('producto_id', pc.producto_id, 'cantidad', pc.cantidad)
                          order by pc.producto_id)
           from public.producto_coleccion pc
          where pc.coleccion_id = i.coleccion_id)
 where i.coleccion_id is not null
   and i.componentes is null
   and exists (select 1 from public.producto_coleccion pc where pc.coleccion_id = i.coleccion_id);

alter table public.venta_item
  add constraint venta_item_componentes_forma
  check (componentes is null or public.componentes_de_venta_validos(componentes));

-- «Obligatorio en un ítem de combo y nulo en uno suelto». Si quedó un ítem de combo que nunca tuvo un
-- componente, no se puede completar sin inventar: la regla rige para lo nuevo (NOT VALID) y esa fila
-- queda como estaba, con un aviso. Con los datos completos, la forma normal.
do $mig$
begin
  if exists (select 1 from public.venta_item where coleccion_id is not null and componentes is null) then
    alter table public.venta_item
      add constraint venta_item_componentes_solo_en_combo
      check ((coleccion_id is null) = (componentes is null)) not valid;
    raise warning '0071: hay ítems de combo sin componentes que no se pueden completar (el combo nunca tuvo uno): el CHECK venta_item_componentes_solo_en_combo quedó NOT VALID para no inventar datos.';
  else
    alter table public.venta_item
      add constraint venta_item_componentes_solo_en_combo
      check ((coleccion_id is null) = (componentes is null));
  end if;
end
$mig$;

comment on column public.venta_item.componentes is
  'Lo que traía UNA unidad del combo al venderlo, copiado por el teléfono: [{"producto_id": uuid, '
  '"cantidad": n}, …], lo fijo y lo elegido juntos (lo elegido puede repetirse). Obligatorio si el '
  'ítem es un combo (coleccion_id) y null si es un producto. Cambiar el combo después no toca la '
  'venta; el stock de V2 descuenta esto. No se valida contra el catálogo (0071, backend-supabase#138).';

-- ----------------------------------------------------------------------------
-- 3. «Monto manual»: el motivo, texto libre con tope
-- ----------------------------------------------------------------------------

alter table public.venta
  add column motivo_monto_manual text;

alter table public.venta
  add constraint venta_motivo_monto_manual_forma
  check (motivo_monto_manual is null
         or (motivo_monto_manual ~ '^\S(.*\S)?$' and char_length(motivo_monto_manual) <= 500));

comment on column public.venta.motivo_monto_manual is
  'Por qué el colportor cambió el total a mano (ej. «descuento por pago en efectivo»). Texto libre que '
  'sube con la venta y lee el coordinador: excepción explícita de Cristian (23/10) a «Justificar», solo '
  'para este campo; la app avisa que no se pongan datos del cliente. Null, o hasta 500 caracteres sin '
  'espacios ni saltos de línea en los extremos (0071, backend-supabase#138).';

-- ----------------------------------------------------------------------------
-- 4. «Talonario por año»: único por colportor, número y año de la venta en Uruguay
-- ----------------------------------------------------------------------------

create function public.anio_de_la_venta(p_fecha timestamptz)
returns integer
language sql
immutable
parallel safe
set search_path = ''
as $$
  select extract(year from (p_fecha at time zone 'America/Montevideo'))::integer;
$$;

comment on function public.anio_de_la_venta(timestamptz) is
  'El año de una fecha en America/Montevideo, sin depender de la zona horaria de la sesión (el 31/12 '
  'a las 23:30 en Uruguay ya es el 01/01 en UTC). Única definición del año del talonario (0071, '
  'backend-supabase#138). Pura, IMMUTABLE; la usa el índice único de venta.';

-- La ejecuta quien inserta una venta (el índice la evalúa con el rol de la sesión).
revoke all on function public.anio_de_la_venta(timestamptz)
  from public, anon, authenticated, service_role;
grant execute on function public.anio_de_la_venta(timestamptz)
  to authenticated, service_role;

-- Primero el nuevo, después se suelta el viejo: nunca hay una ventana sin índice. El nuevo es más
-- flojo, así que las filas de hoy lo cumplen.
create unique index venta_talonario_por_colportor_y_anio_idx
  on public.venta (colportor_id, numero_talonario, (public.anio_de_la_venta(fecha)))
  where deleted_at is null;

drop index public.venta_talonario_por_colportor_idx;

-- ----------------------------------------------------------------------------
-- 5. precios_de_la_ciudad() trae libros_a_elegir
-- ----------------------------------------------------------------------------

-- Se cambian las columnas de la función: `drop function` + `create function` + los mismos privilegios
-- (solo `authenticated`). Todo lo demás es el cuerpo de la 0057 sin tocar: se suma `libros_a_elegir`
-- al final (en una COLECCION lo que dice la tabla; en un PRODUCTO, null: no aplica).

drop function public.precios_de_la_ciudad(uuid, date);

create function public.precios_de_la_ciudad(
  p_campania_ciudad_id  uuid,
  p_fecha               date default null
)
returns table (
  tipo               text,
  id                 uuid,
  nombre             text,
  es_bonificable     boolean,
  precio_general     integer,
  precio_modificado  integer,
  precio_vigente     integer,
  origen             text,
  valido_desde       date,
  valido_hasta       date,
  componentes_de_baja  integer,
  libros_a_elegir      integer
)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_cc      public.campania_ciudad;
  v_fecha   date := coalesce(p_fecha, public.hoy_montevideo());
  v_motivo  text;
begin
  -- El permiso primero: antes de mirar ningún dato.
  if auth.uid() is null then
    raise exception 'Hace falta iniciar sesión. Entrá con tu cuenta de coordinador.'
      using errcode = 'insufficient_privilege';
  end if;

  if not (public.tiene_rol('ADMIN') or public.tiene_rol('COORDINADOR')) then
    raise exception 'Esta cuenta no es de coordinador. Entrá con tu cuenta de coordinador.'
      using errcode = 'insufficient_privilege';
  end if;

  select * into v_cc from public.campania_ciudad cc where cc.id = p_campania_ciudad_id;
  if not found then
    raise exception 'La ciudad no está en una campaña o ya se quitó de ella. Recargá las ciudades de la campaña.'
      using errcode = 'CZ012';
  end if;

  -- ADMIN o coordinador de ESA campaña. La campaña terminada se lee: se ignora su motivo.
  v_motivo := public.motivo_mapa_de_campania(v_cc.campania_id);
  if v_motivo = 'SIN_PERMISO' then
    raise exception 'Solo el coordinador de la campaña puede ver sus precios. Entrá con la cuenta del coordinador de esta campaña.'
      using errcode = 'insufficient_privilege';
  end if;
  if v_motivo = 'CAMPANIA_INEXISTENTE' then
    raise exception 'La campaña no existe. Elegí otra campaña.'
      using errcode = 'CZ001';
  end if;

  if v_cc.deleted_at is not null then
    raise exception 'La ciudad no está en una campaña o ya se quitó de ella. Recargá las ciudades de la campaña.'
      using errcode = 'CZ012';
  end if;

  -- Por producto y por colección: el modificado vigente de ESTA ciudad y el general vigente en la
  -- fecha. Las restricciones de no solapamiento (0027, 0034) garantizan a lo sumo un tramo vigente
  -- de cada uno; el order by y el limit son una red de seguridad, como en precio_vigente().
  return query
    select x.tipo, x.item_id, x.item_nombre, x.bonificable,
           x.gen_precio,
           x.mod_precio,
           coalesce(x.mod_precio, x.gen_precio),
           case when x.mod_precio is not null then 'MODIFICADO'
                when x.gen_precio is not null then 'GENERAL' end,
           case when x.mod_precio is not null then x.mod_desde else x.gen_desde end,
           case when x.mod_precio is not null then x.mod_hasta else x.gen_hasta end,
           x.cdb,
           x.lae
      from (
        select 'PRODUCTO'::text as tipo, 1 as orden, pr.id as item_id, pr.nombre as item_nombre,
               pr.es_bonificable as bonificable,
               gen.precio_venta as gen_precio, gen.valido_desde as gen_desde, gen.valido_hasta as gen_hasta,
               pm.precio_venta as mod_precio, pm.valido_desde as mod_desde, pm.valido_hasta as mod_hasta,
               0 as cdb,
               null::integer as lae
          from public.producto pr
          left join lateral (
            select g.precio_venta, g.valido_desde, g.valido_hasta
              from public.precio_general g
             where g.producto_id = pr.id
               and g.deleted_at is null
               and daterange(g.valido_desde, g.valido_hasta, '[]') @> v_fecha
             order by g.valido_desde desc, g.id
             limit 1
          ) gen on true
          left join lateral (
            select p.precio_venta, p.valido_desde, p.valido_hasta
              from public.precio_por_ciudad p
             where p.campania_ciudad_id = v_cc.id
               and p.producto_id = pr.id
               and p.deleted_at is null
               and daterange(p.valido_desde, p.valido_hasta, '[]') @> v_fecha
             order by p.valido_desde desc, p.id
             limit 1
          ) pm on true
         where pr.deleted_at is null
        union all
        select 'COLECCION'::text, 2, co.id, co.nombre,
               null::boolean,
               gen.precio_venta, gen.valido_desde, gen.valido_hasta,
               pm.precio_venta, pm.valido_desde, pm.valido_hasta,
               (select count(*)::integer
                  from public.producto_coleccion pc
                  join public.producto cp on cp.id = pc.producto_id
                 where pc.coleccion_id = co.id
                   and pc.deleted_at is null
                   and cp.deleted_at is not null),
               co.libros_a_elegir
          from public.coleccion co
          left join lateral (
            select g.precio_venta, g.valido_desde, g.valido_hasta
              from public.precio_general g
             where g.coleccion_id = co.id
               and g.deleted_at is null
               and daterange(g.valido_desde, g.valido_hasta, '[]') @> v_fecha
             order by g.valido_desde desc, g.id
             limit 1
          ) gen on true
          left join lateral (
            select p.precio_venta, p.valido_desde, p.valido_hasta
              from public.precio_por_ciudad p
             where p.campania_ciudad_id = v_cc.id
               and p.coleccion_id = co.id
               and p.deleted_at is null
               and daterange(p.valido_desde, p.valido_hasta, '[]') @> v_fecha
             order by p.valido_desde desc, p.id
             limit 1
          ) pm on true
         where co.deleted_at is null
      ) x
     order by x.orden, x.item_nombre, x.item_id;
end;
$$;

comment on function public.precios_de_la_ciudad(uuid, date) is
  'Vista 27 del panel (0037, backend-supabase#84, ADR-013): una fila por producto y por colección '
  'vivos del catálogo con su precio general, el modificado de esta ciudad de la campaña, el que rige '
  '(el modificado si lo hay y, si no, el general: origen MODIFICADO o GENERAL; null si no tiene '
  'precio, R-CT05) y la vigencia de ese precio, en p_fecha (por defecto, hoy en Montevideo). '
  'es_bonificable es null en una colección. componentes_de_baja (0057, backend-supabase#99): cuántos '
  'componentes vivos de un combo son productos dados de baja (0 en un producto o en un combo sin '
  'ninguno); el precio no se quita, quien arma la pantalla avisa que el combo dejó de ofrecerse. '
  'libros_a_elegir (0071, backend-supabase#138): cuántos libros elige quien vende además de lo fijo '
  'de una colección (0 = combo fijo; null en un producto). '
  'Importes en centavos. Productos antes que colecciones, por nombre. Pueden llamarla el ADMIN y el '
  'coordinador de la campaña, también si ya terminó. Errores: 42501 sin sesión, sin rol o campaña de '
  'otro coordinador; CZ012 la ciudad no existe o se quitó de la campaña; CZ001 la campaña no existe. '
  'SECURITY DEFINER, STABLE.';

-- `authenticated` y `service_role` también en el revoke: en una base creada desde cero los default
-- privileges de la imagen les dan EXECUTE sobre cada función nueva de public (ver 0008).
revoke all on function public.precios_de_la_ciudad(uuid, date)
  from public, anon, authenticated, service_role;
grant execute on function public.precios_de_la_ciudad(uuid, date)
  to authenticated;
