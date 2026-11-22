-- ============================================================================
-- 0173 · casas_de_zona() devuelve la fecha del último cambio de estado de cada casa
--        (backend-supabase#247, seguimiento de front-coordinadores-web#44)
--
-- Origen: la tarjeta de la casa en la vista 24 del panel (artboard 24P·03) muestra «Último cambio:
-- 18/10» y `casas_de_zona()` (0039) no devolvía ninguna fecha. Esta migración solo suma: una
-- columna al final, `ultimo_cambio`.
--
--   casas_de_zona(p_campania_id, p_zona_id, p_despues_de, p_limite)
--     -> (ubicacion_id, lat, lon, tipo, estado, ultimo_cambio)
--
--   ultimo_cambio  el `updated_at` del `house_status` vivo de la ubicación: cuándo se tocó por
--                  última vez su estado. `null` cuando la casa no tiene estado (el mismo caso que
--                  `estado` null: «Sin visita»), sea porque nadie la visitó, porque la app aún no lo
--                  subió o porque su `house_status` está dado de baja.
--
-- Siguen igual: el permiso (primero, 42501), los códigos CZ001 / CZ011 / CZ004 y 22023, el orden
-- por `ubicacion_id`, el cursor `p_despues_de`, el tamaño de página, SECURITY DEFINER con
-- search_path vacío, VOLATILE y EXECUTE solo para `authenticated`. Sigue sin devolver personas,
-- importes ni dirección: una fecha no es ninguna de las tres.
--
-- ## Qué es «la fecha del último cambio»
--
-- `updated_at` de `house_status` lo pone el servidor (`tg_auditoria_update`, 0002/0011) en CADA
-- UPDATE de la fila. Lo único que NO lo mueve es el republicado del servidor
-- (`colportores.republicar`, cuando se corrige la posición de la ubicación). La fecha se mueve,
-- entonces, cuando cambia el color, el punto o el tipo de la casa (decisión del 05/11, regla R4:
-- es un cálculo sobre lo que ya se guarda, «lo último que pasó»; no hay columna nueva). El
-- teléfono no sube el `house_status` sin cambios (`house_status_updater_drift.dart`: compara
-- color, punto y tipo), así que una visita que deja el mismo estado no mueve la fecha. Cambiar el
-- punto o el tipo es un cambio real de la casa, y también cuenta como «último cambio».
--
-- ## Para otros repos
--
--   · front-coordinadores-web#138 muestra la fecha en la tarjeta (artboard 24P·03). La columna
--     nueva es la última de la fila, así que una app que lee las anteriores sigue andando.
--   · No toca el sync: no hay entidad nueva ni cambia ninguna firma de la app móvil.
--
-- Forward-only: no se edita una vez aplicada.
-- ============================================================================

-- Cambia el tipo de lo que devuelve: no hay `create or replace`.
drop function public.casas_de_zona(uuid, uuid, uuid, integer);

create function public.casas_de_zona(p_campania_id uuid, p_zona_id uuid,
                                     p_despues_de uuid default null,
                                     p_limite integer default 1000)
returns table (ubicacion_id uuid, lat double precision, lon double precision, tipo text,
               estado text, ultimo_cambio timestamptz)
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_limite   integer := coalesce(p_limite, 1000);
  v_ciudad   uuid;
  v_poligono jsonb;
begin
  perform public.exigir_lectura_de_campania(p_campania_id);

  -- La zona tiene que ser de ESTA campaña (y estar viva, con su ciudad viva).
  select cc.ciudad_id, z.poligono_geojson
    into v_ciudad, v_poligono
    from public.zona z
    join public.campania_ciudad cc on cc.id = z.campania_ciudad_id
   where z.id = p_zona_id
     and z.deleted_at is null
     and cc.campania_id = p_campania_id
     and cc.deleted_at is null;
  if not found then
    perform public.lanzar_motivo_mapa('ZONA_INEXISTENTE');
  end if;

  if v_limite < 1 or v_limite > 5000 then
    raise exception 'El tamaño de la página tiene que estar entre 1 y 5000 casas. Pedí una página más chica y seguí con la siguiente.'
      using errcode = 'invalid_parameter_value';
  end if;

  -- Una zona sin forma no incluye nada: zona_geometria() es strict y st_covers(null, …) no
  -- devuelve filas.
  return query
    select u.id, u.lat, u.lon, u.tipo, h.color, h.updated_at
      from public.ubicacion u
      left join public.house_status h
             on h.ubicacion_id = u.id and h.deleted_at is null
     where u.ciudad_id = v_ciudad
       and u.deleted_at is null
       and (p_despues_de is null or u.id > p_despues_de)
       and extensions.st_covers(public.zona_geometria(v_poligono),
                                public.ubicacion_geometria(u.lat, u.lon))
     order by u.id
     limit v_limite;
end;
$$;

comment on function public.casas_de_zona(uuid, uuid, uuid, integer) is
  'Vista 24, puntos de las casas (0039, backend-supabase#72; 0173, #247): las ubicaciones vivas de '
  'la ciudad de p_zona_id que caen dentro de su forma, con lat, lon, tipo, estado (el color de '
  'house_status, los siete; null si no tiene) y ultimo_cambio (el updated_at de ese house_status: '
  'cuándo se tocó su estado; null si no tiene). Sin personas, cobros, importes ni dirección. De a '
  'p_limite (1 a 5000, 1000 por defecto) por ubicacion_id; la siguiente página, con p_despues_de = '
  'el último ubicacion_id. Errores: 42501 sin permiso; CZ001 campaña inexistente; CZ011 terminada; '
  'CZ004 la zona no existe, está de baja o no es de esa campaña; 22023 p_limite fuera de rango.';

-- `authenticated` y `service_role` también en el revoke: en una base creada desde cero los
-- default privileges de la imagen les dan EXECUTE sobre cada función nueva de public (0008).
revoke all on function public.casas_de_zona(uuid, uuid, uuid, integer)
  from public, anon, authenticated, service_role;
grant execute on function public.casas_de_zona(uuid, uuid, uuid, integer) to authenticated;
