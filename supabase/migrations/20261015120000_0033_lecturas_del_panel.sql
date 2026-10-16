-- ============================================================================
-- 0033 · Lecturas del panel como RPC: perfil propio, ciudades y zonas de la campaña
--        (backend-supabase#54)
--
-- Origen: decisión de Cristian del 02/10, ADR-013. El BFF se difiere y el panel de coordinadores
-- llama directo a las RPC de Supabase con el JWT del coordinador. ADR-013 no deja que un cliente
-- lea tablas con `.from()` (una pantalla armaría sus datos con varias consultas y la lógica de
-- armado viviría en el panel): lo que antes armaba bff-coordinadores con `select` sobre
-- PostgREST pasa a cinco RPC. La forma de cada respuesta la fija el contrato del panel
-- (front-coordinadores-web: src/datos/shell/contrato.ts y src/datos/equipo/zonas/contrato.ts).
--
--   mi_perfil()                                        el topbar: nombre y apellido
--   campanias_del_coordinador()                        las campañas propias que no terminaron
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
-- Las cinco se llaman con el JWT del usuario y el permiso es lo PRIMERO: antes de leer una sola
-- fila de negocio.
--
--   · Sin JWT (anon o sin sesión): 42501.
--   · Un colportor (sin el rol COORDINADOR ni ADMIN): 42501. Los colportores no llaman. Para
--     ellos y para quien no tiene el rol, el permiso va antes que la existencia de la campaña:
--     contestan siempre 42501.
--   · Las tres lecturas de una campaña (ciudades_de_campania, ciudades_del_catalogo y
--     zonas_de_ciudad) comparten UNA sola comprobación, exigir_lectura_de_campania(), que es la
--     que deja CAMBIAR el mapa de la campaña (guardar_zona() y agregar_ciudad_a_campania()):
--     motivo_mapa_de_campania(). Pasa el ADMIN o el coordinador de ESA campaña
--     (campania.coordinador_id). El coordinador de otra campaña recibe 42501 si la campaña
--     existe; si no existe o está dada de baja recibe CZ001 (el orden de existencia y dueño es
--     el de asignar_zona() y compañía: con ids UUIDv7 no se puede sondear qué campañas hay).
--     La vigencia va después del permiso: una campaña ajena y terminada da 42501.
--   · Campaña inexistente o dada de baja: CZ001. Campaña TERMINADA (hoy = el día de
--     Montevideo): CZ011. Una campaña que todavía no empezó SÍ se lee: la vista 24 prepara el
--     mapa antes del inicio y guardar_zona() ya lo permite (decisión del orquestador del 15/10,
--     por el mapa de decisiones y la de Cristian del 30/09 en backend-supabase#39: si el
--     coordinador cambia zonas antes del inicio, el pull siguiente trae el mapa actualizado).
--     CZ001 y CZ011 son los de las escrituras del mapa; inscribir_colportor() usa CI001/CI002
--     para casos parecidos, pero en la vista 24 el panel traduce la familia CZ (HU-CAM-006).
--   · zonas_de_ciudad() además exige que la ciudad sea una ciudad VIVA de ESA campaña: si no
--     (otra campaña, inexistente o quitada), CZ012. Mismo código que guardar_zona(). Una ciudad
--     ajena y una que no existe contestan igual: no se puede sondear qué ids hay en otras
--     campañas.
--   · SECURITY DEFINER con search_path vacío, como las lecturas de 0007, y no INVOKER: para
--     leer a los colportores de la zona hace falta pasar por encima de la RLS de public.usuario
--     (desde 0015 el coordinador lee solo su fila), y motivo_mapa_de_campania() es interna,
--     sin EXECUTE para authenticated. Estas funciones no agregan acceso: acotan lo que
--     devuelven (columnas explícitas, nunca `to_jsonb(fila)`).
--   · mi_perfil() y campanias_del_coordinador() son la excepción: SECURITY INVOKER. La primera
--     solo lee la fila propia de public.usuario (la política usuario_select_propio_o_admin ya lo
--     permite); la segunda filtra por coordinador_id = auth.uid() sobre public.campania, que
--     lee todo autenticado (tabla de pull). No pueden devolver de más.
--   · EXECUTE solo para `authenticated`. Ni anon, ni public, ni service_role: sin JWT las cinco
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
--   campanias_del_coordinador() -> (id, nombre, tipo, fecha_inicio, fecha_fin). Las campañas
--       vivas de las que quien llama es el COORDINADOR y que no terminaron (en curso o por
--       empezar; fecha_fin null = sin fin; hoy = el día de Montevideo, y el último día todavía
--       cuenta). Primero las en curso, la que empezó más tarde primero; después las por empezar,
--       la más próxima primero; a igual fecha, por id. Es el `campania_id` que piden las otras
--       tres, sin que el panel lea `campania` con `.from()` (ADR-013). Un ADMIN ve solo las que
--       coordina él, no todas. Sin ciudades ni zonas: eso es de las otras.
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
--   42501  sin sesión, sin el rol, o la campaña es de otro coordinador (y existe)
--   CZ001  la campaña no existe (o está dada de baja)
--   CZ011  la campaña ya terminó (una que todavía no empezó se lee)
--   CZ012  zonas_de_ciudad(): la ciudad no está en esta campaña
--
-- ## Decididas (15/10, por el mapa de decisiones; el archivo de pendientes del PR las registra)
--
--   · Cómo conoce el panel su `campania_id` (antes pendiente): campanias_del_coordinador(). Cuál de
--     ellas se muestra en el topbar («campaña en curso» y «región», front-coordinadores-web#18)
--     sigue siendo una pregunta del panel: esta lista sirve para cualquier respuesta, una sola o un
--     selector, y no se rehace. mi_perfil() queda como está.
--   · Campañas futuras y terminadas (antes pendiente): las tres lecturas de campaña usan
--     motivo_mapa_de_campania(); en curso o por empezar se leen, la terminada es CZ011. No se abre
--     la lectura de campañas terminadas (sería otra función).
--
-- ## Pendientes (no se deciden acá; P1 del archivo de pendientes del PR)
--
--   · `provincia` del catálogo (Cristian §3, modelo de datos): el contrato del panel y la HU-CAM-006
--     piden buscar «por nombre y provincia» y devolver `provincia`, pero public.ciudad no tiene esa
--     columna (HU-ADM-005 habla de `departamento`, que tampoco existe). Agregar una columna a una
--     entidad del pull es una decisión de modelo. Hasta entonces ciudades_del_catalogo() busca y
--     devuelve solo por nombre.
--
-- ## Para otros repos
--
--   · front-coordinadores-web#18 (topbar) llama a mi_perfil() y a campanias_del_coordinador(); #40
--     (vista 24) llama a las otras tres. Por PostgREST: POST /rest/v1/rpc/<función> con el JWT del
--     coordinador y los parámetros por nombre (p_campania_id, p_texto, p_campania_ciudad_id).
--   · Dos `null` que el contrato del panel tipa como `string` y el adaptador de #40 tiene que
--     cubrir: `zonas_de_ciudad().color` (una zona se puede guardar sin color) y
--     `esquinas[].calle_a` / `calle_b` (columnas nulables; los polígonos que 0008 convirtió a
--     ESQUINAS no tienen calles).
--   · Son VOLATILE las que llaman a lanzar_motivo_*() (volátiles) y STABLE mi_perfil() y
--     campanias_del_coordinador(): supabase-js manda las VOLATILE por POST.
--   · No tocan el sync: no hay entidad nueva ni cambia ninguna firma que use la app móvil.
--
-- Forward-only: no se edita una vez aplicada.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. El permiso, una sola vez (interna)
-- ----------------------------------------------------------------------------

-- Lanza el error que corresponda si el usuario autenticado no puede LEER el mapa de p_campania_id
-- como coordinador (o ADMIN). Mismo permiso, mismo orden y mismos códigos que las escrituras del
-- mapa (guardar_zona() y agregar_ciudad_a_campania()): una campaña en curso o por empezar se lee,
-- una terminada es CZ011. Solo cambia el texto del 42501, que habla de ver y no de cambiar.
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

  v_motivo := public.motivo_mapa_de_campania(p_campania_id);

  if v_motivo = 'SIN_PERMISO' then
    raise exception 'Solo el coordinador de la campaña puede ver sus ciudades y zonas. Entrá con la cuenta del coordinador de esta campaña.'
      using errcode = 'insufficient_privilege';
  end if;

  -- null no hace nada; CAMPANIA_INEXISTENTE -> CZ001, CAMPANIA_TERMINADA -> CZ011.
  perform public.lanzar_motivo_mapa(v_motivo);
end;
$$;

comment on function public.exigir_lectura_de_campania(uuid) is
  'Interna (0033): 42501 si no hay sesión o el usuario no es ADMIN ni el coordinador de '
  'p_campania_id; CZ001 si no existe; CZ011 si ya terminó (una por empezar se lee). La usan las '
  'lecturas del panel.';

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
-- 2b. campanias_del_coordinador(): las campañas propias que no terminaron
-- ----------------------------------------------------------------------------

-- INVOKER: filtra por coordinador_id = auth.uid() sobre public.campania (lectura abierta a todo
-- autenticado). Es de donde el panel saca el `campania_id` que piden las otras tres lecturas, sin
-- leer `campania` con `.from()` (ADR-013). «No terminó» es el criterio de las lecturas del mapa
-- (motivo_mapa_de_campania(), 0024): el día se cuenta en America/Montevideo y el último día
-- todavía cuenta. En curso primero (la que empezó más tarde, primero) y después las por empezar
-- (la más próxima, primero): |fecha_inicio - hoy| ordena a las dos del lado que corresponde.
create function public.campanias_del_coordinador()
returns table (id uuid, nombre text, tipo text, fecha_inicio date, fecha_fin date)
language plpgsql
stable
set search_path = ''
as $$
declare
  v_hoy date := public.hoy_montevideo();
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
    select c.id, c.nombre, c.tipo, c.fecha_inicio, c.fecha_fin
      from public.campania c
     where c.coordinador_id = auth.uid()
       and c.deleted_at is null
       and (c.fecha_fin is null or c.fecha_fin >= v_hoy)
     order by (c.fecha_inicio > v_hoy), abs(c.fecha_inicio - v_hoy), c.id;
end;
$$;

comment on function public.campanias_del_coordinador() is
  'Panel (0033, ADR-013): las campañas vivas que coordina el usuario autenticado y que no '
  'terminaron (en curso o por empezar; hoy = el día de Montevideo). Primero las en curso, la que '
  'empezó más tarde primero; después las por empezar, la más próxima primero. Errores: 42501 sin '
  'sesión o sin el rol COORDINADOR ni ADMIN. Un ADMIN ve solo las que coordina.';

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
  'permiso; CZ001 inexistente; CZ011 terminada.';

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
  'con él y después A-Z. Errores: 42501 sin permiso; CZ001 inexistente; CZ011 terminada.';

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
  '(un número, sin datos de clientes). Errores: 42501 sin permiso; CZ001 inexistente; CZ011 '
  'terminada; CZ012 la ciudad no está en esta campaña.';

-- ----------------------------------------------------------------------------
-- 6. Privilegios
-- ----------------------------------------------------------------------------

-- `authenticated` y `service_role` también en el revoke: en una base creada desde cero los default
-- privileges de la imagen les dan EXECUTE sobre cada función nueva de public (ver 0008).
revoke all on function public.mi_perfil(), public.campanias_del_coordinador(),
  public.ciudades_de_campania(uuid),
  public.ciudades_del_catalogo(uuid, text), public.zonas_de_ciudad(uuid, uuid),
  public.exigir_lectura_de_campania(uuid)
  from public, anon, authenticated, service_role;

grant execute on function public.mi_perfil(), public.campanias_del_coordinador(),
  public.ciudades_de_campania(uuid),
  public.ciudades_del_catalogo(uuid, text), public.zonas_de_ciudad(uuid, uuid)
  to authenticated;

-- Interna: la llaman las funciones SECURITY DEFINER de arriba (corren como su dueño).
grant execute on function public.exigir_lectura_de_campania(uuid) to service_role;
