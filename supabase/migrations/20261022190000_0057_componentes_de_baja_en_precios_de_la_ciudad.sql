-- ============================================================================
-- 0057 · precios_de_la_ciudad() avisa cuántos componentes de un combo están dados de baja
--        (backend-supabase#99, HU-CAT-009; decisión §2 del agente de decisiones sobre
--        backend-supabase-99-impl-261022-2334.md, P2)
--
-- HU-CAT-009: «si un componente se da de baja, el combo deja de ofrecerse hasta corregirlo, y se avisa
-- qué combos quedaron afectados». Quién ofrece (el teléfono) lo decide con lo que baja por el pull
-- (`producto.deleted_at` y `producto_coleccion`); el servidor nunca rechaza una venta por el catálogo.
-- Para la pantalla de precios de la coordinadora (y la de Administración) la lectura suma:
--
--   componentes_de_baja integer  (columna nueva, al final de precios_de_la_ciudad())
--
--   · En una COLECCION: cuántos vínculos vivos de `producto_coleccion` apuntan a un producto dado de
--     baja. 0 si no hay ninguno, y 0 también en un combo sin componentes (esa regla, «sin
--     componentes vivos», la aplica el teléfono con el pull).
--   · En un PRODUCTO: siempre 0.
--   · El precio NO se quita: el combo con un componente de baja sigue saliendo con su precio general,
--     su modificado y el que rige. Solo se suma el aviso.
--
-- Se cambian las columnas de la función: `drop function` + `create function` + los mismos privilegios
-- (solo `authenticated`). Todo lo demás (permisos, códigos de rechazo, orden, vigencias) es el cuerpo de
-- la 0037 sin tocar. Ninguna tabla, columna ni dato cambia.
--
-- ## Para otros repos
--   · front-coordinadores-web (vista 27): la fila de un combo trae `componentes_de_baja`; > 0 = avisar que
--     el combo dejó de ofrecerse hasta corregirlo.
--   · front-colportores-mobile: no ofrecer un combo con un componente de baja (o sin componentes vivos),
--     usando `producto.deleted_at` y `producto_coleccion` del pull.
--   · front-admin-web (HU-CAT-009): el aviso «qué combos quedaron afectados» sale de esta columna; hasta
--     entonces, la consulta de `docs/guia-carga-manual.md` § 7b.
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
  componentes_de_baja  integer
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
           x.cdb
      from (
        select 'PRODUCTO'::text as tipo, 1 as orden, pr.id as item_id, pr.nombre as item_nombre,
               pr.es_bonificable as bonificable,
               gen.precio_venta as gen_precio, gen.valido_desde as gen_desde, gen.valido_hasta as gen_hasta,
               pm.precio_venta as mod_precio, pm.valido_desde as mod_desde, pm.valido_hasta as mod_hasta,
               0 as cdb
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
                   and cp.deleted_at is not null)
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
