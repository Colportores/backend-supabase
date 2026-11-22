-- ============================================================================
-- 0180 · Las casas de toda la ciudad de la campaña para el panel, también las que no están en ninguna zona
--        (backend-supabase#254, casilla «Casas ciudad»; decisión de Cristian del 05/11 en docs-organizacion#76, seguimiento
--        de backend-supabase#247 y front-coordinadores-web#44)
--
-- ## El caso
--
-- Luis, coordinador de «Verano», abre la vista 24 del panel y quiere ver el mapa de toda la ciudad de Salto, no solo la zona
-- que dibujó: las casas que sus colportores registraron fuera de cualquier zona también cuentan. `casas_de_zona()` (0039, 0173)
-- trae solo las que caen dentro de la forma de UNA zona; no hay forma de listar las que no tienen zona.
--
-- ## Qué suma
--
--   casas_de_la_ciudad(p_campania_id, p_campania_ciudad_id, p_despues_de, p_limite)
--     -> (ubicacion_id, lat, lon, tipo, estado, ultimo_cambio, zona_id, zona_nombre, calle, numero,
--         registrada_por, registrada_por_nombre, registrada_por_apellido)
--
-- Una ciudad de la campaña (la pestaña de la vista 24, la misma `campania_ciudad` que ya recibe `zonas_de_ciudad()`): TODAS las
-- ubicaciones vivas de esa ciudad, estén o no dentro de una zona.
--
--   · `tipo`, `estado` y `ultimo_cambio`: como en `casas_de_zona()` (el color del `house_status` vivo, los siete; la fecha de
--     su último cambio; `null` si la casa no tiene estado: «Sin visita»).
--   · `zona_id` y `zona_nombre`: la zona viva de esa ciudad de la campaña cuya forma cubre el punto de la casa, `null` si no
--     cae en ninguna. Si dos zonas se superponen y cubren la casa, la que figura primero por nombre (y por id si empatan): el
--     panel muestra una sola.
--   · `calle` y `numero`: la dirección de la ubicación, como se guardó (pueden ser `null`: una casa marcada en el mapa sin
--     dirección).
--   · `registrada_por`, `registrada_por_nombre` y `registrada_por_apellido`: el colportor que registró la casa (`created_by`);
--     `null` si no se sabe (la persona se dio de baja del sistema).
--
-- Sigue sin devolver **personas, importes ni notas** (ADR-004): ni quién vive en la casa, ni lo que compró o debe, ni lo que se
-- anotó de ella. La dirección es la del lugar, no de la persona; quien registró la casa es un usuario del sistema (colportor),
-- no un cliente.
--
-- ## Permisos (los de `casas_de_zona()`)
--
-- `exigir_lectura_de_campania()` primero: 42501 sin sesión o sin ser ADMIN ni coordinador de ESA campaña (cualquiera de sus
-- coordinadores, 0175); CZ001 campaña inexistente; CZ011 campaña ya terminada (una por empezar se lee). Después: CZ012 si la
-- ciudad no es una ciudad viva de esta campaña (una de otra campaña, inexistente o quitada contestan lo mismo). 22023 si
-- `p_limite` no está entre 1 y 5000. SECURITY DEFINER, `search_path` vacío, EXECUTE solo para `authenticated`.
--
-- ## Páginas
--
-- De a `p_limite` (1000 por defecto) ordenadas por `ubicacion_id`; la siguiente página se pide con `p_despues_de` = el último
-- `ubicacion_id`. Una ciudad con más casas que eso se baja en varias llamadas, como `casas_de_zona()`.
--
-- ## Los datos
--
-- Solo una función nueva; no toca filas. Lo prueba supabase/tests/0180_… . Forward-only.
--
-- ## Para otros repos
--
--   · front-coordinadores-web#144: la vista 24 llama `casas_de_la_ciudad()` para pintar toda la ciudad (con la zona de cada
--     casa y quién la registró) y deja `casas_de_zona()` para el detalle de una zona.
--   · docs-organizacion#172: la fila de la RPC en el contrato y `esquema-datos.md`.
--
-- Forward-only: esta migración no se edita una vez aplicada.
-- ============================================================================

create function public.casas_de_la_ciudad(p_campania_id uuid, p_campania_ciudad_id uuid,
                                          p_despues_de uuid default null,
                                          p_limite integer default 1000)
returns table (ubicacion_id uuid, lat double precision, lon double precision, tipo text,
               estado text, ultimo_cambio timestamptz, zona_id uuid, zona_nombre text,
               calle text, numero text, registrada_por uuid, registrada_por_nombre text,
               registrada_por_apellido text)
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_limite integer := coalesce(p_limite, 1000);
  v_ciudad uuid;
begin
  perform public.exigir_lectura_de_campania(p_campania_id);

  -- La ciudad tiene que ser una ciudad viva de ESTA campaña.
  select cc.ciudad_id into v_ciudad
    from public.campania_ciudad cc
   where cc.id = p_campania_ciudad_id
     and cc.campania_id = p_campania_id
     and cc.deleted_at is null;
  if not found then
    perform public.lanzar_motivo_mapa('CIUDAD_FUERA_DE_CAMPANIA');
  end if;

  if v_limite < 1 or v_limite > 5000 then
    raise exception 'El tamaño de la página tiene que estar entre 1 y 5000 casas. Pedí una página más chica y seguí con la siguiente.'
      using errcode = 'invalid_parameter_value';
  end if;

  return query
    select u.id, u.lat, u.lon, u.tipo, h.color, h.updated_at,
           z.id, z.nombre,
           u.calle, u.numero,
           reg.id, reg.nombre, reg.apellido
      from public.ubicacion u
      left join public.house_status h
             on h.ubicacion_id = u.id and h.deleted_at is null
      left join public.usuario reg
             on reg.id = u.created_by and reg.deleted_at is null
      left join lateral (
        select zz.id, zz.nombre
          from public.zona zz
         where zz.campania_ciudad_id = p_campania_ciudad_id
           and zz.deleted_at is null
           and extensions.st_covers(public.zona_geometria(zz.poligono_geojson),
                                    public.ubicacion_geometria(u.lat, u.lon))
         order by zz.nombre, zz.id
         limit 1) z on true
     where u.ciudad_id = v_ciudad
       and u.deleted_at is null
       and (p_despues_de is null or u.id > p_despues_de)
     order by u.id
     limit v_limite;
end;
$$;

comment on function public.casas_de_la_ciudad(uuid, uuid, uuid, integer) is
  'Vista 24, todas las casas de la ciudad (0180, backend-supabase#254): las ubicaciones vivas de una ciudad de p_campania_id '
  '(p_campania_ciudad_id, la misma de zonas_de_ciudad), estén o no en una zona, con lat, lon, tipo, estado (el color de '
  'house_status; null si no tiene), ultimo_cambio, zona_id y zona_nombre (la zona viva que cubre el punto; null si no cae en '
  'ninguna; con dos zonas, la primera por nombre), calle y numero (la dirección, que puede faltar) y quién la registró (id, '
  'nombre y apellido del colportor; null si no se sabe). Sin personas, cobros, importes ni notas (ADR-004). De a p_limite (1 a '
  '5000, 1000 por defecto) por ubicacion_id; la siguiente página, con p_despues_de = el último ubicacion_id. Errores: 42501 '
  'sin permiso; CZ001 campaña inexistente; CZ011 terminada; CZ012 la ciudad no es de esta campaña; 22023 p_limite fuera de '
  'rango.';

revoke all on function public.casas_de_la_ciudad(uuid, uuid, uuid, integer)
  from public, anon, authenticated, service_role;
grant execute on function public.casas_de_la_ciudad(uuid, uuid, uuid, integer) to authenticated;
