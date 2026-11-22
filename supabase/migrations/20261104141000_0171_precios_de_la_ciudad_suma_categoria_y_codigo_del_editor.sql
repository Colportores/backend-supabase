-- ============================================================================
-- 0171 · precios_de_la_ciudad() suma categoria y codigo_editor
--        (backend-supabase#248, HU-CAT-005; decisión P2 del agente de decisiones del 04/11 sobre
--        front-coordinadores-web#64, por las reglas R1 y R4)
--
-- La tabla de precios de la vista 27 agrupa por LIBROS / REVISTAS / MATERIALES / COLECCIONES, muestra
-- el código del editor y la insignia «Misionero» (27G). Las dos columnas ya existen en `producto`
-- (`codigo_editor`, 0070; `categoria`, 0149): es dato de más en la lectura, nada nuevo en el modelo.
--
--   categoria      text  (al final)  producto.categoria: BONIFICABLES | MISIONEROS | REVISTAS |
--                                    ESPIRITUALES | MATERIAL. null en una COLECCION.
--   codigo_editor  text  (al final)  producto.codigo_editor; null si el producto no tiene y en una
--                                    COLECCION.
--
-- No se usa `producto_tipo`, que sale con backend-supabase#233. Sin ninguna regla de agrupación
-- acá: el panel agrupa con la categoría (BONIFICABLES, MISIONEROS y ESPIRITUALES a LIBROS; REVISTAS a
-- REVISTAS; MATERIAL a MATERIALES; las colecciones a COLECCIONES) y la insignia «Misionero» sale de
-- `categoria = 'MISIONEROS'`.
--
-- Se cambian las columnas de la función: `drop function` + `create function` + los mismos privilegios
-- (solo `authenticated`). Solo suma: todo lo demás (permisos, códigos de rechazo, orden, vigencias y
-- las columnas anteriores) es el cuerpo de la 0071 sin tocar. Ninguna tabla, columna ni dato cambia.
--
-- ## Para otros repos
--   · front-coordinadores-web (front-coordinadores-web#139): mapear las dos columnas en `aItem` y
--     ajustar `grupoDe` y `etiquetasDe` a la categoría. Una fila de COLECCION trae las dos en null.
--   · front-colportores-mobile y el motor de sync: no cambia nada.
--
-- Forward-only: esta migración no se edita una vez aplicada.
-- ============================================================================

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
  libros_a_elegir      integer,
  categoria            text,
  codigo_editor        text
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
           x.lae,
           x.categoria,
           x.codigo_editor
      from (
        select 'PRODUCTO'::text as tipo, 1 as orden, pr.id as item_id, pr.nombre as item_nombre,
               pr.es_bonificable as bonificable,
               gen.precio_venta as gen_precio, gen.valido_desde as gen_desde, gen.valido_hasta as gen_hasta,
               pm.precio_venta as mod_precio, pm.valido_desde as mod_desde, pm.valido_hasta as mod_hasta,
               0 as cdb,
               null::integer as lae,
               pr.categoria as categoria,
               pr.codigo_editor as codigo_editor
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
               co.libros_a_elegir,
               null::text,
               null::text
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
  'de una colección (0 = combo fijo; null en un producto). categoria y codigo_editor (0171, '
  'backend-supabase#248): los del producto (categoria, 0149; codigo_editor, 0070, null si no tiene); '
  'null en una colección. '
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
