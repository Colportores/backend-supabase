-- ============================================================================
-- 0033 · Lecturas del panel como RPC: perfil propio, ciudades y zonas de la campaña
--        (backend-supabase#54)
--
-- Origen: decisión de Cristian del 02/10, ADR-013. El BFF se difiere y el panel de coordinadores
-- llama directo a las RPC de Supabase con el JWT del coordinador. ADR-013 no deja que un cliente
-- lea tablas con `.from()` (una pantalla armaría sus datos con varias consultas y la lógica de
-- armado viviría en el panel): lo que antes armaba bff-coordinadores con `select` sobre
-- PostgREST pasa a cuatro RPC. La forma de cada respuesta la fija el contrato del panel
-- (front-coordinadores-web: src/datos/shell/contrato.ts y src/datos/equipo/zonas/contrato.ts).
--
--   mi_perfil()                                        el topbar: nombre y apellido
--   ciudades_de_campania(campania)                     las pestañas de la vista 24
--   ciudades_del_catalogo(campania, texto)             el buscador de «+ Agregar ciudad»
--   zonas_de_ciudad(campania, campania_ciudad)         las zonas de una pestaña de la vista 24
--
-- Lo demás de la vista 24 ya es RPC: agregar_ciudad_a_campania(), guardar_zona() (con
-- p_vista_previa), baja_zona(), asignar_zona(), quitar_zona(), zonas_asignables(),
-- colportores_de_campania() y buscar_candidatos().
--
-- ## Modelo de permisos
--
-- Las cuatro se llaman con el JWT del usuario y el permiso es lo PRIMERO: antes de leer una sola
-- fila de negocio.
--
--   · Sin JWT (anon o sin sesión): 42501.
--   · Un colportor (sin el rol COORDINADOR ni ADMIN): 42501. Los colportores no llaman.
--   · Las tres lecturas de una campaña (ciudades_de_campania, ciudades_del_catalogo y
--     zonas_de_ciudad) comparten UNA sola comprobación, exigir_lectura_de_campania(), que es la
--     de asignar_zona() y de zonas_asignables(): motivo_campania_del_coordinador(). Pasa el
--     ADMIN o el coordinador de ESA campaña (campania.coordinador_id). El coordinador de otra
--     campaña recibe 42501.
--   · Campaña inexistente o dada de baja: CZ001. Campaña no vigente (todavía no empezó o ya
--     terminó, hoy = el día de Montevideo): CZ002. Son los códigos de asignar_zona() y de las
--     lecturas de 0007; inscribir_colportor() usa CI001/CI002 para los mismos casos, pero en
--     la vista 24 el panel traduce la familia CZ (HU-CAM-006).
--   · zonas_de_ciudad() además exige que la ciudad sea una ciudad VIVA de ESA campaña: si no
--     (otra campaña, inexistente o quitada), CZ012. Mismo código que guardar_zona(). Una ciudad
--     ajena y una que no existe contestan igual: no se puede sondear qué ids hay en otras
--     campañas.
--   · SECURITY DEFINER con search_path vacío, como las lecturas de 0007, y no INVOKER: para
--     leer a los colportores de la zona hace falta pasar por encima de la RLS de public.usuario
--     (desde 0015 el coordinador lee solo su fila), y motivo_campania_del_coordinador() es
--     interna, sin EXECUTE para authenticated. Estas funciones no agregan acceso: acotan lo que
--     devuelven (columnas explícitas, nunca `to_jsonb(fila)`).
--   · mi_perfil() es la excepción: SECURITY INVOKER. Solo lee la fila propia de public.usuario
--     (la política usuario_select_propio_o_admin ya lo permite), así que la RLS es suficiente y
--     la función no puede devolver de más.
--   · EXECUTE solo para `authenticated`. Ni anon, ni public, ni service_role: sin JWT las cuatro
--     fallan con 42501 de todos modos, así que al servidor no le sirven. La comprobación común es
--     interna y la ejecuta solo service_role, como los helpers de 0006.
--
-- ## Qué devuelve cada una
--
-- Nunca datos de clientes ni de personas (ADR-003/004, Ley 18.331): ni ubicaciones, ni espacios,
-- ni personas, ni visitas, ni ventas. Lo único con nombre propio son los colportores de la
-- zona (nombre, apellido y si la cuenta está suspendida, como colportores_de_campania(), sin
-- email), y de las ubicaciones solo un NÚMERO.
--
--   mi_perfil() -> (usuario_id, nombre, apellido). Las iniciales las arma el panel.
--
--   ciudades_de_campania(p_campania_id) -> (campania_ciudad_id, ciudad_id, nombre, lat_centro,
--       lon_centro, zoom_inicial, cantidad_zonas). Una fila por ciudad VIVA de la campaña, por
--       nombre. `campania_ciudad_id` es el `id` de la pestaña (lo que reciben guardar_zona() y
--       zonas_de_ciudad()); `ciudad_id` es el del catálogo global (el `catalogoId` del
--       contrato: lo que recibe agregar_ciudad_a_campania()). `cantidad_zonas` cuenta las zonas
--       vivas. Una ciudad que el administrador dio de baja del catálogo sigue en su campaña:
--       el catálogo solo acota lo que se ELIGE al agregar (esquema-datos.md).
--
--   ciudades_del_catalogo(p_campania_id, p_texto) -> (ciudad_id, nombre). Las ciudades VIVAS
--       del catálogo que todavía no están (vivas) en la campaña. Con texto, las cuyo nombre lo
--       contiene, sin distinguir mayúsculas ni tildes (normalizar_busqueda(), la de
--       buscar_candidatos()); sin texto, todas. Primero las que empiezan con lo escrito, después
--       el resto, A-Z (decisión del 02/10 para las listas con búsqueda). El texto es literal: un
--       «%» o un «_» no son comodines. Sin tope: el catálogo es chico y el contrato del panel no
--       pagina; si crece, se pagina con cursor como buscar_candidatos().
--
--   zonas_de_ciudad(p_campania_id, p_campania_ciudad_id) -> (zona_id, nombre, tipo_forma, color,
--       centro_lat, centro_lon, radio_m, poligono_geojson, esquinas, colportores,
--       ubicaciones_registradas). Una fila por zona VIVA, por nombre.
--         · centro_lat, centro_lon y radio_m: solo RADIAL (null en ESQUINAS).
--         · esquinas: solo ESQUINAS (null en RADIAL), jsonb
--           [{orden, lat, lon, calle_a, calle_b}] por `orden`, sin las esquinas dadas de baja.
--         · colportores: jsonb [{usuario_id, nombre, apellido, suspendido}] por apellido, de
--           las inscripciones vivas de la campaña que tienen esa zona. [] si no hay ninguno.
--         · color: el de la zona; null si se guardó sin color (guardar_zona() lo permite).
--         · ubicaciones_registradas: cuántas ubicaciones vivas de la ciudad caen dentro de la
--           zona, la misma cuenta que «Incluye N ubicaciones» de guardar_zona()
--           (zona_ubicaciones_incluidas(), índice GiST). La zona es solo visual: nada de esto
--           cambia ni borra ubicaciones.
--
-- ## Códigos de rechazo (los traduce la fuente de datos del panel, ADR-013)
--
--   42501  sin sesión, sin el rol, o la campaña es de otro coordinador
--   CZ001  la campaña no existe (o está dada de baja)
--   CZ002  la campaña no está vigente
--   CZ012  zonas_de_ciudad(): la ciudad no está en esta campaña
--
-- ## Pendientes (no se deciden acá; P1, P2 y P3 del archivo de pendientes del PR)
--
--   · `provincia` del catálogo (Cristian §3, modelo de datos): el contrato del panel y la HU-CAM-006
--     piden buscar «por nombre y provincia» y devolver `provincia`, pero public.ciudad no tiene esa
--     columna (HU-ADM-005 habla de `departamento`, que tampoco existe). Agregar una columna a una
--     entidad del pull es una decisión de modelo. Hasta entonces ciudades_del_catalogo() busca y
--     devuelve solo por nombre.
--   · Cómo conoce el panel su `campania_id` (Cristian §3, ya abierta en front-coordinadores-web#18:
--     «campaña en curso» y «región» del topbar). Estas RPC reciben la campaña; mi_perfil() no la
--     devuelve y no se suma una RPC de «mis campañas» hasta que se decida.
--   · Campañas futuras y terminadas (Cristian §3, alcance): el criterio de aceptación del issue
--     pide CZ002 para la campaña no vigente, y las lecturas lo cumplen. Pero guardar_zona() sí deja
--     preparar el mapa de una campaña que todavía no empezó (0008), así que la vista 24 no podría
--     abrirla. Si se decide otra cosa, se cambia exigir_lectura_de_campania() a
--     motivo_mapa_de_campania().
--
-- ## Para otros repos
--
--   · front-coordinadores-web#18 (topbar) llama a mi_perfil(); #40 (vista 24) llama a las otras
--     tres. Por PostgREST: POST /rest/v1/rpc/<función> con el JWT del coordinador y los
--     parámetros por nombre (p_campania_id, p_texto, p_campania_ciudad_id).
--   · Son VOLATILE (llaman a lanzar_motivo_zona(), volátil): supabase-js las manda por POST.
--   · No tocan el sync: no hay entidad nueva ni cambia ninguna firma que use la app móvil.
--
-- Forward-only: no se edita una vez aplicada.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. El permiso, una sola vez (interna)
-- ----------------------------------------------------------------------------

-- Lanza el error que corresponda si el usuario autenticado no puede LEER el mapa de p_campania_id
-- como coordinador (o ADMIN). Mismo permiso, mismo orden y mismos códigos que asignar_zona() y
-- zonas_asignables(); solo cambia el texto del 42501, que habla de ver y no de asignar.
create function public.exigir_lectura_de_campania(p_campania_id uuid)
returns void
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_motivo text;
begin
  if auth.uid() is null then
    raise exception 'Hace falta iniciar sesión. Entrá con tu cuenta de coordinador.'
      using errcode = 'insufficient_privilege';
  end if;

  v_motivo := public.motivo_campania_del_coordinador(p_campania_id);

  if v_motivo = 'SIN_PERMISO' then
    raise exception 'Solo el coordinador de la campaña puede ver sus ciudades y zonas. Entrá con la cuenta del coordinador de esta campaña.'
      using errcode = 'insufficient_privilege';
  end if;

  perform public.lanzar_motivo_zona(v_motivo);
end;
$$;

comment on function public.exigir_lectura_de_campania(uuid) is
  'Interna (0033): 42501 si no hay sesión o el usuario no es ADMIN ni el coordinador de '
  'p_campania_id; CZ001 si no existe; CZ002 si no está vigente. La usan las lecturas del panel.';

-- ----------------------------------------------------------------------------
-- 2. mi_perfil(): el topbar
-- ----------------------------------------------------------------------------

-- INVOKER: lee solo la fila propia, que la RLS de public.usuario ya deja leer. Reemplaza a
-- GET /v1/me de bff-coordinadores.
create function public.mi_perfil()
returns table (usuario_id uuid, nombre text, apellido text)
language plpgsql
stable
set search_path = ''
as $$
begin
  if auth.uid() is null then
    raise exception 'Hace falta iniciar sesión. Entrá con tu cuenta de coordinador.'
      using errcode = 'insufficient_privilege';
  end if;

  if not (public.tiene_rol('COORDINADOR') or public.tiene_rol('ADMIN')) then
    raise exception 'Esta cuenta no es de coordinador. Entrá con tu cuenta de coordinador.'
      using errcode = 'insufficient_privilege';
  end if;

  return query
    select u.id, u.nombre, u.apellido
      from public.usuario u
     where u.id = auth.uid() and u.deleted_at is null;
end;
$$;

comment on function public.mi_perfil() is
  'Topbar del panel (0033, ADR-013): nombre y apellido del usuario autenticado. Errores: 42501 sin '
  'sesión o sin el rol COORDINADOR ni ADMIN. Las iniciales las arma el panel.';

-- ----------------------------------------------------------------------------
-- 3. ciudades_de_campania(): las pestañas de la vista 24
-- ----------------------------------------------------------------------------

create function public.ciudades_de_campania(p_campania_id uuid)
returns table (campania_ciudad_id uuid, ciudad_id uuid, nombre text, lat_centro double precision,
               lon_centro double precision, zoom_inicial smallint, cantidad_zonas integer)
language plpgsql
volatile
security definer
set search_path = ''
as $$
begin
  perform public.exigir_lectura_de_campania(p_campania_id);

  return query
    select cc.id, c.id, c.nombre, c.lat_centro, c.lon_centro, c.zoom_inicial,
           (select count(*)::integer
              from public.zona z
             where z.campania_ciudad_id = cc.id and z.deleted_at is null)
      from public.campania_ciudad cc
      join public.ciudad c on c.id = cc.ciudad_id
     where cc.campania_id = p_campania_id
       and cc.deleted_at is null
     order by c.nombre, cc.id;
end;
$$;

comment on function public.ciudades_de_campania(uuid) is
  'Vista 24 (0033): las ciudades vivas de p_campania_id con su centro, zoom y cantidad de zonas '
  'vivas. campania_ciudad_id es el id de la pestaña; ciudad_id, el del catálogo. Errores: 42501 sin '
  'permiso; CZ001 inexistente; CZ002 no vigente.';

-- ----------------------------------------------------------------------------
-- 4. ciudades_del_catalogo(): el buscador de «+ Agregar ciudad»
-- ----------------------------------------------------------------------------

create function public.ciudades_del_catalogo(p_campania_id uuid, p_texto text default null)
returns table (ciudad_id uuid, nombre text)
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_texto text := public.normalizar_busqueda(p_texto);
begin
  perform public.exigir_lectura_de_campania(p_campania_id);

  -- strpos y no LIKE: el texto es literal, un «%» o un «_» no son comodines.
  return query
    select c.id, c.nombre
      from public.ciudad c
     where c.deleted_at is null
       and not exists (select 1
                         from public.campania_ciudad cc
                        where cc.campania_id = p_campania_id
                          and cc.ciudad_id = c.id
                          and cc.deleted_at is null)
       and (v_texto is null or strpos(public.normalizar_busqueda(c.nombre), v_texto) > 0)
     order by (v_texto is not null and strpos(public.normalizar_busqueda(c.nombre), v_texto) = 1) desc,
              c.nombre, c.id;
end;
$$;

comment on function public.ciudades_del_catalogo(uuid, text) is
  'Vista 24, «+ Agregar ciudad» (0033): ciudades vivas del catálogo que no están en p_campania_id, '
  'las que contienen p_texto (sin mayúsculas ni tildes; sin texto, todas), primero las que empiezan '
  'con él y después A-Z. Errores: 42501 sin permiso; CZ001 inexistente; CZ002 no vigente.';

-- ----------------------------------------------------------------------------
-- 5. zonas_de_ciudad(): las zonas de una pestaña de la vista 24
-- ----------------------------------------------------------------------------

create function public.zonas_de_ciudad(p_campania_id uuid, p_campania_ciudad_id uuid)
returns table (zona_id uuid, nombre text, tipo_forma text, color text,
               centro_lat double precision, centro_lon double precision, radio_m integer,
               poligono_geojson jsonb, esquinas jsonb, colportores jsonb,
               ubicaciones_registradas integer)
language plpgsql
volatile
security definer
set search_path = ''
as $$
begin
  perform public.exigir_lectura_de_campania(p_campania_id);

  -- La ciudad tiene que ser de ESTA campaña: una de otra campaña (o inexistente, o quitada)
  -- contesta lo mismo, y el coordinador no puede leer zonas ajenas pasando su campaña.
  if not exists (select 1
                   from public.campania_ciudad cc
                  where cc.id = p_campania_ciudad_id
                    and cc.campania_id = p_campania_id
                    and cc.deleted_at is null) then
    perform public.lanzar_motivo_mapa('CIUDAD_FUERA_DE_CAMPANIA');
  end if;

  return query
    select z.id, z.nombre, z.tipo_forma, z.color, z.centro_lat, z.centro_lon, z.radio_m,
           z.poligono_geojson,
           case when z.tipo_forma = 'ESQUINAS' then
             (select coalesce(jsonb_agg(jsonb_build_object('orden', v.orden, 'lat', v.lat,
                                                           'lon', v.lon, 'calle_a', v.calle_a,
                                                           'calle_b', v.calle_b)
                                        order by v.orden), '[]'::jsonb)
                from public.zona_vertice v
               where v.zona_id = z.id and v.deleted_at is null)
           end,
           (select coalesce(jsonb_agg(jsonb_build_object('usuario_id', u.id, 'nombre', u.nombre,
                                                         'apellido', u.apellido,
                                                         'suspendido', u.suspendido_en is not null)
                                      order by u.apellido, u.nombre, u.id), '[]'::jsonb)
              from public.campania_colportor k
              join public.usuario u on u.id = k.usuario_id
             where k.campania_id = p_campania_id
               and k.zona_id = z.id
               and k.deleted_at is null
               and u.deleted_at is null),
           public.zona_ubicaciones_incluidas(z.campania_ciudad_id, z.poligono_geojson)
      from public.zona z
     where z.campania_ciudad_id = p_campania_ciudad_id
       and z.deleted_at is null
     order by z.nombre, z.id;
end;
$$;

comment on function public.zonas_de_ciudad(uuid, uuid) is
  'Vista 24 (0033): las zonas vivas de una ciudad de p_campania_id con su forma, esquinas (solo '
  'ESQUINAS), colportores asignados (nombre, apellido, suspendido) y cuántas ubicaciones incluye '
  '(un número, sin datos de clientes). Errores: 42501 sin permiso; CZ001 inexistente; CZ002 no '
  'vigente; CZ012 la ciudad no está en esta campaña.';

-- ----------------------------------------------------------------------------
-- 6. Privilegios
-- ----------------------------------------------------------------------------

-- `authenticated` y `service_role` también en el revoke: en una base creada desde cero los default
-- privileges de la imagen les dan EXECUTE sobre cada función nueva de public (ver 0008).
revoke all on function public.mi_perfil(), public.ciudades_de_campania(uuid),
  public.ciudades_del_catalogo(uuid, text), public.zonas_de_ciudad(uuid, uuid),
  public.exigir_lectura_de_campania(uuid)
  from public, anon, authenticated, service_role;

grant execute on function public.mi_perfil(), public.ciudades_de_campania(uuid),
  public.ciudades_del_catalogo(uuid, text), public.zonas_de_ciudad(uuid, uuid)
  to authenticated;

-- Interna: la llaman las funciones SECURITY DEFINER de arriba (corren como su dueño).
grant execute on function public.exigir_lectura_de_campania(uuid) to service_role;
