-- ============================================================================
-- 0037 · Lectura de los precios de una ciudad de la campaña para el panel (vista 27)
--        (backend-supabase#84, HU-CAT-005; ADR-013)
--
-- La vista 27 del panel de coordinadores (front-coordinadores-web#21) tiene que mostrar, para una
-- ciudad de la campaña, el precio que rige de cada producto y de cada colección: el GENERAL que
-- carga Administración y, si lo hay, el MODIFICADO de la coordinadora (`precio_por_ciudad`).
-- `precio_vigente()` (0034) contesta UN precio de UN producto: armar la vista con ella sería el N+1
-- que ADR-013 descarta, y leer `precio_general` / `precio_por_ciudad` con `.from()` tampoco se puede
-- (ADR-013: los clientes no hacen select, insert ni update sobre tablas). Esta migración suma la
-- RPC de LECTURA que faltaba:
--
--   precios_de_la_ciudad(p_campania_ciudad_id, p_fecha default null)
--
-- Solo la lectura. No cambia ninguna tabla ni el sync. La escritura del modificado (la
-- coordinadora) y del general (Administración) desde el panel es otra pregunta: hoy son políticas
-- sobre las tablas, sin RPC.
--
-- ## Decidido (16/10, por el mapa de decisiones y la regla de Cristian del 06/10, «Precio gral.»)
--
-- Las tres bifurcaciones del issue las resolvió el agente de decisiones (archivo de pendientes
-- backend-supabase-84-impl-261016-1630.md; comentario del issue
-- https://github.com/Colportores/backend-supabase/issues/84#issuecomment-6223168891):
--
--   · Qué devuelve: UNA FILA POR PRODUCTO Y POR COLECCIÓN DEL CATÁLOGO VIVO, con el general, el
--     modificado, el que rige y de cuál sale; sin historial. La que traía solo lo que ya tiene
--     precio escondía el producto sin precio, que es justo el que dispara la alerta «Productos
--     bonificables sin precio en X» de la HU-CAT-005; el historial no lo pide ninguna vista. Si el
--     rediseño de la vista 27 pide más, se suma otra migración: lo de acá no se rehace.
--   · Quién la llama: el ADMIN y el coordinador DE ESA campaña, también si la campaña ya terminó
--     (ver qué precios tuvo tiene sentido; es el criterio con que la 0034 deja leer el general).
--     Cualquier otro, 42501, y el colportor también: él lee los precios por el sync.
--   · Forma técnica: SECURITY DEFINER con search_path vacío, el permiso primero, STABLE y EXECUTE
--     solo para `authenticated`, como las lecturas del panel de la 0033.
--
-- ## Qué devuelve
--
--   precios_de_la_ciudad(p_campania_ciudad_id uuid, p_fecha date default null) ->
--     (tipo, id, nombre, es_bonificable, precio_general, precio_modificado, precio_vigente, origen,
--      valido_desde, valido_hasta)
--
--   · Una fila por cada PRODUCTO vivo y por cada COLECCIÓN viva del catálogo, tenga o no precio en
--     la ciudad. Primero los productos y después las colecciones; dentro de cada grupo, por nombre
--     y por id. Sin tope: el catálogo es chico y un tope escondería filas (el contrato del panel no
--     pagina).
--   · tipo: 'PRODUCTO' o 'COLECCION'. id y nombre: los del producto o de la colección.
--   · es_bonificable: el del producto (para contar la alerta); null en una colección, que no lo es.
--   · precio_general: el importe del general vigente en la fecha (precio_general), en centavos;
--     null si no hay.
--   · precio_modificado: el importe del modificado vigente EN ESTA ciudad de la campaña
--     (precio_por_ciudad), en centavos; null si no hay. Aparece aunque el producto no tenga general.
--   · precio_vigente y origen: el que rige, el modificado si lo hay y, si no, el general: la misma
--     regla que precio_vigente() (0034). origen es 'MODIFICADO' o 'GENERAL'; sin ninguno de los dos,
--     precio_vigente y origen son null: el producto no se ofrece en esa ciudad (R-CT05) y es la fila
--     que cuenta la alerta de bonificables sin precio.
--   · valido_desde y valido_hasta: la vigencia del precio que rige (la del modificado o la del
--     general, nunca mezcladas); null si no hay precio. valido_hasta null con precio = sin fin.
--   · p_fecha: el día para el que se piden los precios; sin fecha, hoy en Montevideo
--     (hoy_montevideo(), no el current_date de la sesión). Las dos fechas de un tramo valen
--     (daterange '[]', como las restricciones de no solapamiento de 0027 y 0034). Un tramo vencido,
--     futuro o dado de baja no cuenta. Una fecha de otro día sirve para ver qué precios regían o
--     van a regir.
--   · Un producto o una colección dados de baja no aparecen (aunque tengan precios históricos). La
--     pertenencia del producto a una colección no se resuelve (tampoco la resuelve precio_vigente()).
--   · Nada de personas ni de clientes (ADR-003, ADR-004): producto o colección, importes y fechas.
--
-- ## Modelo de permisos y códigos de rechazo
--
-- Se llama con el JWT del usuario y el permiso es lo PRIMERO: antes de leer una sola fila de
-- precios. El orden es el de guardar_zona() y zonas_de_ciudad() (0008, 0033):
--
--   1. 42501  sin sesión (auth.uid() null: anon o sin JWT).
--   2. 42501  sin el rol ADMIN ni COORDINADOR: un colportor, un usuario sin rol, con el rol vencido
--             o dado de baja. Para ellos el permiso va antes que la existencia de la ciudad.
--   3. CZ012  la ciudad de la campaña no existe (p_campania_ciudad_id no es de ninguna).
--   4. 42501  existe y la campaña es de OTRO coordinador (el ADMIN pasa siempre).
--      CZ001  existe, pero su campaña no existe o está dada de baja.
--   5. CZ012  la ciudad de la campaña existe pero se quitó de ella (deleted_at).
--
-- Una campaña TERMINADA se lee: a diferencia de las lecturas que preparan el mapa (0033, CZ011), acá
-- no hay rechazo por vigencia. Una campaña que todavía no empezó se lee, como en la 0033.
-- Reutiliza motivo_mapa_de_campania() (0008, 0024: ADMIN o coordinador de la campaña, día de
-- Montevideo) y descarta su 'CAMPANIA_TERMINADA'. Con ids UUIDv7 no se puede sondear qué ciudades de
-- campaña hay; los códigos ya distinguen existencia y dueño como lo hacen guardar_zona() y las
-- lecturas de la 0033.
--
-- SECURITY DEFINER (y no INVOKER como precio_vigente()): el permiso lo decide la función y no la
-- RLS de cada tabla, así quien no puede leer recibe un error con su motivo y no filas vacías (que
-- el panel confundiría con «no hay precios»). No agrega acceso: acota lo que devuelve (columnas
-- explícitas, nunca `to_jsonb(fila)`) y no devuelve nada que no pudiera ver quien la llama con la
-- RLS de las tablas (el ADMIN lee todo; el coordinador de la campaña lee su ciudad y el general,
-- 0034). STABLE: solo lee. No llama a ninguna función volátil.
--
-- EXECUTE solo para `authenticated`. Ni anon, ni public, ni service_role: sin JWT falla con 42501 de
-- todos modos, así que al servidor no le sirve (el servidor usa precio_vigente(), 0034).
--
-- ## Lo que esta migración NO hace
--
--   · Ninguna tabla, columna, política ni entidad de sync nueva o cambiada: precio_general y
--     precio_por_ciudad quedan como están (0027, 0030, 0034). Sync y Realtime no se tocan.
--   · La escritura de precios desde el panel (otro issue).
--   · El historial de precios (todas las vigencias): ninguna vista lo pide hoy.
--
-- ## Los datos
--
-- Solo se crea una función: no hay `update` ni `delete` sobre nada que exista.
--
-- ## Para otros repos
--
--   · front-coordinadores-web (vista 27, front-coordinadores-web#21; pestañas por ciudad, a rediseñar
--     en Claude Design): una llamada por pestaña, POST /rest/v1/rpc/precios_de_la_ciudad con el JWT
--     del coordinador y los parámetros por nombre: {"p_campania_ciudad_id": "<id de la pestaña>",
--     "p_fecha": "2026-03-01"} (p_fecha es opcional). El `p_campania_ciudad_id` es el
--     `campania_ciudad_id` que devuelve ciudades_de_campania() (0033). Cada fila trae los dos
--     importes en centavos (enteros): el panel los formatea. El contrato simulado de la pestaña
--     Equipo (src/datos/equipo/contrato.ts, PreciosDeCiudad) usa precioBase = precio_general y
--     precioCiudad = precio_vigente (o precio_modificado si solo quiere la excepción).
--   · Dos `null` que el panel tiene que cubrir: `es_bonificable` en una colección, y todo
--     (precio_vigente, origen, valido_desde, valido_hasta) en un producto sin precio. «Productos
--     bonificables sin precio en X» = filas con tipo = 'PRODUCTO', es_bonificable y origen null.
--   · Errores que el panel traduce (ADR-013): 42501 sin permiso, CZ001 la campaña no existe, CZ012
--     la ciudad no existe o se quitó de la campaña. Un error no es una lista vacía.
--   · front-colportores-mobile y el motor de sync: no cambia nada.
--   · docs-organizacion: HU-CAT-005 puede apuntar a precios_de_la_ciudad() como la lectura de la
--     vista 27.
--
-- Forward-only: esta migración no se edita una vez aplicada.
-- ============================================================================

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
  valido_hasta       date
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
           case when x.mod_precio is not null then x.mod_hasta else x.gen_hasta end
      from (
        select 'PRODUCTO'::text as tipo, 1 as orden, pr.id as item_id, pr.nombre as item_nombre,
               pr.es_bonificable as bonificable,
               gen.precio_venta as gen_precio, gen.valido_desde as gen_desde, gen.valido_hasta as gen_hasta,
               pm.precio_venta as mod_precio, pm.valido_desde as mod_desde, pm.valido_hasta as mod_hasta
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
               pm.precio_venta, pm.valido_desde, pm.valido_hasta
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
  'es_bonificable es null en una colección. Importes en centavos. Productos antes que colecciones, '
  'por nombre. Pueden llamarla el ADMIN y el coordinador de la campaña, también si ya terminó. '
  'Errores: 42501 sin sesión, sin rol o campaña de otro coordinador; CZ012 la ciudad no existe o se '
  'quitó de la campaña; CZ001 la campaña no existe. SECURITY DEFINER, STABLE.';

-- `authenticated` y `service_role` también en el revoke: en una base creada desde cero los default
-- privileges de la imagen les dan EXECUTE sobre cada función nueva de public (ver 0008).
revoke all on function public.precios_de_la_ciudad(uuid, date)
  from public, anon, authenticated, service_role;
grant execute on function public.precios_de_la_ciudad(uuid, date)
  to authenticated;
