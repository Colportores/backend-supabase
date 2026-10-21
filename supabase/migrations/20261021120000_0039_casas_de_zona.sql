-- ============================================================================
-- 0039 · Casas de una zona para el panel: punto, tipo y estado, sin personas ni cobros
--        (backend-supabase#72)
--
-- Origen: decisión de Cristian del 06/10, «Puntos panel» (front-coordinadores-web#40): el
-- coordinador, en la vista 24 (zonas de la campaña), ve sobre las calles los puntos de las casas
-- de la zona con el estado de cada una. Es la supervisión de ADR-003 y ADR-004. Y «Cobro panel»
-- (docs-organizacion#44): los puntos llevan LOS SIETE estados de `house_status`, también los de
-- cobranza pendiente y el de venta pagada. El límite es «sin montos ni personas».
--
--   casas_de_zona(p_campania_id, p_zona_id, p_despues_de, p_limite)
--     -> (ubicacion_id, lat, lon, tipo, estado)
--
-- ## Qué devuelve
--
-- Una fila por ubicación VIVA de la ciudad de la zona que cae dentro de su forma (ST_Covers, el
-- borde cuenta: la misma regla de «Incluye N ubicaciones» y de `zonas_de_ciudad().
-- ubicaciones_registradas`, así que la cantidad de puntos de una zona es ese número). La zona es
-- solo visual (decisión del 29/09): no hay `zona_id` en la ubicación; los puntos salen de la
-- posición, igual que lo que baja del pull.
--
--   ubicacion_id  el id de la ubicación (la clave para pedir la página siguiente).
--   lat, lon      su punto.
--   tipo          CASA | NEGOCIO | EDIFICIO (el de la ubicación).
--   estado        el `color` de su `house_status`: ENTREGA_Y_COBRANZA_PENDIENTE, COBRANZA_PENDIENTE,
--                 ENTREVISTA_PROGRAMADA, VENTA_COMPLETA, ENTREVISTA_SIN_VENTA, SIN_CONTESTAR o
--                 RECHAZO (ADR-003, prioridades 1 a 7). `null` si la ubicación todavía no tiene
--                 estado (nadie la visitó, o la app aún no lo subió): el punto está, el panel
--                 decide cómo dibujarlo (el canvas de la vista 24 no lo define: ver el archivo de
--                 pendientes del PR).
--
-- Nunca devuelve personas, `espacio_persona`, notas, visitas, agendas, ventas ni cobranzas, ni
-- importes, ni la dirección (calle y número): ADR-004 deja leerla al coordinador, pero se suma
-- solo si el artboard de la vista 24 la pide, no antes. Columnas explícitas, nunca `to_jsonb`.
--
-- ## Tope y paginado (un tope no esconde resultados)
--
-- Orden fijo por `ubicacion_id`. `p_limite` (por defecto 1000, de 1 a 5000) es el tamaño de la
-- página: si vuelven `p_limite` filas puede haber más, y se pide la siguiente con
-- `p_despues_de` = el `ubicacion_id` de la última fila; una página con menos filas que `p_limite`
-- es la última. Un `p_limite` fuera de rango es un error (22023), no se recorta en silencio: si
-- se recortara, el panel creería que la página corta es la última. `p_despues_de` es una clave
-- de orden, no hace falta que exista: pasa lo mismo si esa casa se dio de baja entre dos páginas.
--
-- ## Modelo de permisos
--
-- Mismo que las demás lecturas de la vista 24 (0033): el permiso es lo PRIMERO.
--
--   · Sin JWT, colportor, sin rol o coordinador de otra campaña: 42501 (exigir_lectura_de_
--     campania()). Los colportores no llaman y no averiguan qué campañas hay.
--   · Campaña inexistente o dada de baja: CZ001. Terminada: CZ011. Por empezar: se lee.
--   · La zona tiene que estar viva y ser de una ciudad viva de ESA campaña: si no, CZ004. Una
--     zona ajena, inexistente o dada de baja contestan igual: no se puede sondear qué zonas hay
--     en otras campañas pasando la propia.
--   · p_limite fuera de 1..5000: 22023.
--   · SECURITY DEFINER con search_path vacío: el coordinador no lee `ubicacion` ni `house_status`
--     con `.from()` (la RLS es por zona descargada); la función acota lo que devuelve.
--   · VOLATILE (llama a exigir_lectura_de_campania(), volátil): supabase-js la manda por POST.
--   · EXECUTE solo para `authenticated`.
--
-- ## Para otros repos
--
--   · front-coordinadores-web#44 (los puntos en la vista 24) llama por PostgREST:
--     POST /rest/v1/rpc/casas_de_zona con p_campania_id y p_zona_id (y p_despues_de / p_limite
--     para paginar). Tiene que pedir páginas hasta que una venga con menos filas que p_limite.
--   · No toca el sync: no hay entidad nueva ni cambia ninguna firma de la app móvil.
--
-- Forward-only: no se edita una vez aplicada.
-- ============================================================================

create function public.casas_de_zona(p_campania_id uuid, p_zona_id uuid,
                                     p_despues_de uuid default null,
                                     p_limite integer default 1000)
returns table (ubicacion_id uuid, lat double precision, lon double precision, tipo text,
               estado text)
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
    select u.id, u.lat, u.lon, u.tipo, h.color
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
  'Vista 24, puntos de las casas (0039, backend-supabase#72): las ubicaciones vivas de la ciudad '
  'de p_zona_id que caen dentro de su forma, con lat, lon, tipo y estado (el color de house_status, '
  'los siete; null si no tiene). Sin personas, cobros, importes ni dirección. De a p_limite (1 a '
  '5000, 1000 por defecto) por ubicacion_id; la siguiente página, con p_despues_de = el último '
  'ubicacion_id. Errores: 42501 sin permiso; CZ001 campaña inexistente; CZ011 terminada; CZ004 la '
  'zona no existe, está de baja o no es de esa campaña; 22023 p_limite fuera de rango.';

-- `authenticated` y `service_role` también en el revoke: en una base creada desde cero los
-- default privileges de la imagen les dan EXECUTE sobre cada función nueva de public (0008).
revoke all on function public.casas_de_zona(uuid, uuid, uuid, integer)
  from public, anon, authenticated, service_role;
grant execute on function public.casas_de_zona(uuid, uuid, uuid, integer) to authenticated;
