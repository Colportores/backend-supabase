-- ============================================================================
-- 0010 · La zona de cada ubicación sale de su posición (backend-supabase#24)
--
-- Regla 4 del cambio de modelo del 29/09 (vistas de Claude Design «Vistas colportaje»:
-- esquema-datos, vistas 24 del panel y 04/10 de la app).
--
-- ## Qué cambia
--
--   · ubicacion.zona_id la calcula el servidor en todo INSERT y UPDATE, por la posición
--     (ST_Covers sobre zona.poligono_geojson, borde incluido): el valor del cliente se
--     ignora y zona_id pasa a sync.entidad.columnas_servidor. null = fuera de toda zona. El
--     colportor puede registrar fuera de su zona (R-CM04).
--   · house_status.zona_id sigue a su ubicación (trigger en las dos tablas). Cuando una
--     ubicación cambia de zona, por el camino que sea, su house_status y sus espacios salen en
--     el delta de la zona nueva.
--   · tg_zona_propia se va: la zona ahora sale de la posición. Las políticas de INSERT de
--     ubicacion y house_status dejan de exigir que la zona sea propia (R-CM04: registrar una
--     casa que cae en la zona de otro es válido). Mover una casa a otra zona: SOLO casas
--     propias. Una casa que registró otro colportor se corrige dentro de la zona, pero no se
--     manda a la de otro (la política de UPDATE exige que la fila nueva le siga siendo visible;
--     el push queda invalid con 42501). Qué filas puede tocar cada uno (el USING) no cambia.
--   · Lock por ciudad (advisory, hasta el commit): compartido al escribir una ubicación,
--     exclusivo al recalcular las zonas de esa ciudad. Así una casa que entra mientras se
--     guarda una zona no queda con la zona vieja, en ninguno de los dos órdenes.
--     Si un push ya tiene tomada una fila que el recálculo necesita y espera el compartido,
--     Postgres corta el deadlock abortando al que esperaba primero (en la práctica el push,
--     que sale 500 y el motor reintenta).
--   · Al crear una zona, cambiarle la forma o darla de baja (por cualquier camino), se
--     recalculan las ubicaciones de su ciudad que están en la forma vieja o en la nueva, o que
--     tenían esa zona. zona_ubicaciones_que_cambian() deja de devolver null: guardar_zona() y
--     baja_zona() devuelven cuántas cambian, en la vista previa y al guardar.
--   · Al asignar o cambiar la zona de una inscripción (asignar_zona(), o cualquier otro
--     camino), se republican las ubicaciones de esa zona, con su house_status y sus espacios,
--     con un UPDATE nulo (HU-CAM-006 y 0001: «al rotar el colportor, quien toma la zona recibe
--     las casas ya trabajadas con su estado»). Sin eso, las que se cargaron antes del último
--     pull de quien toma la zona quedan detrás de su watermark y el delta no se las entrega.
--     Mismo mecanismo que el mapa en 0008.
--   · Posible duplicado (aviso, no bloqueo): índice espacial (geography + GiST) para los 5 m
--     y posibles_duplicados_de_ubicacion() para el panel y los reportes.
--
-- ## La regla (la app usa la misma: Colportores/front-colportores-mobile#231)
--
-- Candidatas: las zonas vivas que cubren el punto (ST_Covers, cálculo plano en lon/lat, con
-- el borde incluido), de una ciudad viva de una campaña vigente hoy (campania_vigente()),
-- en la misma ciudad que la ubicación. Entre ellas:
--   1. primero las de la campaña preferida (D2, abajo);
--   2. después, la de MENOR id (el UUID comparado como texto en minúsculas: el mismo orden
--      que uuid en Postgres).
-- El desempate por id resuelve el borde compartido: un punto justo en la calle que separa
-- dos zonas, o en la franja de hasta 1 m que 0008 acepta como borde, lo cubren las dos, y
-- queda en la de menor id. Estable: una zona nueva tiene un id mayor (UUID v7), así que no le
-- saca los puntos del borde a la vecina que ya existía. Si ninguna lo cubre, null.
-- Mover un punto a otra zona (o fuera de toda zona) solo vale para casas propias: la app no
-- ofrece mover a otra zona una casa que registró otro colportor.
--
-- ## D2 · De qué campaña es la zona (pendiente de Cristian; acá, la opción (a) provisoria)
--
-- La zona de la campaña vigente hoy que contiene el punto; con dos campañas vigentes en la
-- ciudad, la de la campaña del colportor que registra o mueve el punto. Concretamente, la
-- campaña preferida es:
--   · al crear la ubicación o moverla (cambian lat, lon o ciudad): las campañas vigentes de
--     quien escribe (auth.uid(); sin JWT, created_by);
--   · en cualquier otro UPDATE y en los recálculos: la campaña de la zona que ya tenía (la
--     eligió quien la registró o la movió por última vez), y después las de created_by.
-- Lo que (a) no cubre, y queda para la decisión: el paso del tiempo no recalcula nada solo.
-- Cuando una campaña empieza o termina, cada ubicación toma su zona nueva en su próxima
-- escritura, al cambiar una zona que la cubre, o al asignarle a alguien una zona que la cubre
-- (el republicado de asignar_zona() la recalcula). Una zona de una campaña futura no se aplica
-- al dibujarla, sino en esos momentos. Tampoco recalculan quitar una ciudad de la campaña ni
-- cambiar las fechas de una campaña. Si D2 queda en (a), falta un job diario que recalcule las
-- ciudades con campañas que empiezan o terminan ese día; (b) lo resuelve sin job.
--
-- ## D1 · Dirección única (pendiente de Cristian; acá, todo menos el índice único)
--
-- La normalización de (a) ya está: direccion_normalizada() (trim y minúsculas, vacío = null),
-- y el índice no único ubicacion_direccion_idx reemplaza a ubicacion_dedup_idx (que usaba
-- lower() sin trim). Si D1 queda en (a), la migración que lo cierre:
--   1. revisa los duplicados vivos por (ciudad_id, calle y número normalizados) y aborta
--      listando cada grupo, con qué hacer (criterio 2: no se fusiona ni se borra nada solo);
--   2. crea el único:
--        create unique index ubicacion_direccion_uidx on public.ubicacion
--          (ciudad_id, public.direccion_normalizada(calle), public.direccion_normalizada(numero))
--          where deleted_at is null
--            and public.direccion_normalizada(calle) is not null
--            and public.direccion_normalizada(numero) is not null;
--   3. sync.push devuelve el 23505 de ese índice como conflicto (hoy sale como invalid), para
--      que la app muestre la resolución de la vista 10. Eso es del motor (@BrunoFCapri).
--
-- ## Datos existentes (criterio 2: nada se pierde en silencio)
--
-- zona_id pasa a ser un dato derivado, así que se recalcula para cada ubicación viva. Antes
-- de tocar nada se revisan TODAS: si una ubicación tiene una zona que hoy le abre la casa a
-- alguien (zona viva, de una ciudad viva de una campaña vigente) y por su posición quedaría en
-- otra zona o en ninguna, la migración aborta y lista cada una con qué hacer: el cambio le
-- sacaría la casa del mapa a un colportor. El resto (sin zona, o con una zona que hoy no le
-- abre nada a nadie) se recalcula sin preguntar: nadie deja de ver nada. house_status se
-- alinea con su ubicación. Las filas dadas de baja no se tocan: el tombstone conserva su zona.
--
-- Forward-only: esta migración no se edita una vez aplicada.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. Helpers puros (sin tablas): los usan índices, triggers y la app de lectura
-- ----------------------------------------------------------------------------

create function public.ubicacion_geometria(p_lat double precision, p_lon double precision)
returns extensions.geometry
language sql
immutable
strict
parallel safe
set search_path = ''
as $$
  select extensions.st_setsrid(extensions.st_makepoint(p_lon, p_lat), 4326);
$$;

comment on function public.ubicacion_geometria(double precision, double precision) is
  'El punto (SRID 4326) de una ubicación. Con esta geometría se decide en qué zona cae (ST_Covers).';

create function public.ubicacion_geografia(p_lat double precision, p_lon double precision)
returns extensions.geography
language sql
immutable
strict
parallel safe
set search_path = ''
as $$
  select extensions.geography(extensions.st_setsrid(extensions.st_makepoint(p_lon, p_lat), 4326));
$$;

comment on function public.ubicacion_geografia(double precision, double precision) is
  'El punto de una ubicación como geography: distancias en metros (posible duplicado a 5 m).';

create function public.direccion_normalizada(p_texto text)
returns text
language sql
immutable
parallel safe
set search_path = ''
as $$
  select nullif(lower(btrim(p_texto)), '');
$$;

comment on function public.direccion_normalizada(text) is
  'Calle o número normalizados para comparar direcciones: trim y minúsculas; vacío = null (D1).';

-- ----------------------------------------------------------------------------
-- 2. La regla: en qué zona cae un punto
-- ----------------------------------------------------------------------------

-- Las campañas a preferir (D2): la de p_zona_actual, si hay, y después las vigentes de
-- p_usuario. Interna.
create function public.ubicacion_campanias_preferidas(p_zona_actual uuid, p_usuario uuid)
returns uuid[]
language sql
stable
set search_path = ''
as $$
  select array(select cc.campania_id
                 from public.zona z
                 join public.campania_ciudad cc on cc.id = z.campania_ciudad_id
                where z.id = p_zona_actual)
      || array(select v.campania_id
                 from public.campanias_vigentes_de(p_usuario) v
                order by v.campania_id);
$$;

comment on function public.ubicacion_campanias_preferidas(uuid, uuid) is
  'D2 (a): la campaña de la zona actual y después las vigentes del usuario, en ese orden. Interna.';

-- La zona de un punto con la regla de la cabecera. Los parámetros p_ignorar_zona y
-- p_hipotetica_* arman el mapa «como quedaría» para la vista previa: sin p_ignorar_zona, y con
-- una zona más (id, campania_ciudad y forma). Sin ellos, el mapa tal como está. Interna.
create function public.zona_de_posicion(
  p_lat              double precision,
  p_lon              double precision,
  p_ciudad_id        uuid,
  p_preferidas       uuid[],
  p_ignorar_zona     uuid default null,
  p_hipotetica_id    uuid default null,
  p_hipotetica_cc    uuid default null,
  p_hipotetica_forma jsonb default null
)
returns uuid
language sql
stable
set search_path = ''
as $$
  select x.zona_id
    from (
      select z.id as zona_id, cc.campania_id
        from public.zona z
        join public.campania_ciudad cc on cc.id = z.campania_ciudad_id
        join public.campania c on c.id = cc.campania_id
       where z.deleted_at is null
         and extensions.st_covers(public.zona_geometria(z.poligono_geojson),
                                  public.ubicacion_geometria(p_lat, p_lon))
         and z.id is distinct from p_ignorar_zona
         and cc.ciudad_id = p_ciudad_id
         and cc.deleted_at is null
         and public.campania_vigente(c)
      union all
      select p_hipotetica_id, cc.campania_id
        from public.campania_ciudad cc
        join public.campania c on c.id = cc.campania_id
       where p_hipotetica_forma is not null
         and cc.id = p_hipotetica_cc
         and cc.ciudad_id = p_ciudad_id
         and cc.deleted_at is null
         and public.campania_vigente(c)
         and extensions.st_covers(public.zona_geometria(p_hipotetica_forma),
                                  public.ubicacion_geometria(p_lat, p_lon))
    ) x
   order by array_position(p_preferidas, x.campania_id) nulls last, x.zona_id
   limit 1;
$$;

comment on function public.zona_de_posicion(double precision, double precision, uuid, uuid[], uuid, uuid, uuid, jsonb) is
  'Zona de un punto: zonas vivas de ciudades vivas de campañas vigentes de p_ciudad_id que lo '
  'cubren (ST_Covers); primero las de p_preferidas, después la de menor id. null si ninguna. '
  'Con p_ignorar_zona/p_hipotetica_* calcula sobre el mapa de la vista previa. Interna.';

-- Las ubicaciones vivas de p_ciudad_id que un cambio de p_zona_id puede mover: las que la
-- tienen, y las que caen en su forma vieja o en la nueva (null = no hay). Interna.
create function public.ubicaciones_de_zona_cambiada(p_ciudad_id uuid, p_zona_id uuid,
                                                    p_forma_vieja extensions.geometry,
                                                    p_forma_nueva extensions.geometry)
returns table (id uuid)
language sql
stable
set search_path = ''
as $$
  select u.id from public.ubicacion u
   where p_zona_id is not null and u.zona_id = p_zona_id
     and u.ciudad_id = p_ciudad_id and u.deleted_at is null
  union
  select u.id from public.ubicacion u
   where p_forma_vieja is not null and u.deleted_at is null
     and extensions.st_covers(p_forma_vieja, public.ubicacion_geometria(u.lat, u.lon))
     and u.ciudad_id = p_ciudad_id
  union
  select u.id from public.ubicacion u
   where p_forma_nueva is not null and u.deleted_at is null
     and extensions.st_covers(p_forma_nueva, public.ubicacion_geometria(u.lat, u.lon))
     and u.ciudad_id = p_ciudad_id;
$$;

-- ----------------------------------------------------------------------------
-- 3. Qué ubicaciones no se pueden recalcular sin avisar: se revisa todo antes de cambiar nada
-- ----------------------------------------------------------------------------

do $$
declare
  v_problemas text;
begin
  select string_agg(
           format('  · %s (%s), zona «%s» de «%s»: por su posición (%s, %s) %s Si la posición es '
                  'la correcta, poné la zona a mano (ubicacion.zona_id = %s); si no, corregí lat y '
                  'lon, o el borde de la zona. Después volvé a aplicar la migración.',
                  coalesce(nullif(btrim(concat_ws(' ', u.calle, u.numero)), ''), 'Ubicación sin dirección'),
                  u.id, z.nombre, c.nombre, u.lat, u.lon,
                  case when x.nueva is null
                       then 'cae fuera de toda zona de una campaña vigente, y el colportor de esa zona dejaría de verla.'
                       else format('cae en la zona «%s», y el colportor de «%s» dejaría de verla.',
                                   (select zn.nombre from public.zona zn where zn.id = x.nueva), z.nombre)
                  end,
                  coalesce(quote_literal(x.nueva), 'null')),
           E'\n' order by c.nombre, z.nombre, u.id)
    into v_problemas
    from public.ubicacion u
    join public.zona z on z.id = u.zona_id
    join public.campania_ciudad cc on cc.id = z.campania_ciudad_id
    join public.campania c on c.id = cc.campania_id
    cross join lateral (
      select public.zona_de_posicion(u.lat, u.lon, u.ciudad_id,
                                     public.ubicacion_campanias_preferidas(u.zona_id, u.created_by)) as nueva
    ) x
   where u.deleted_at is null
     and z.deleted_at is null
     and cc.deleted_at is null
     and public.campania_vigente(c)
     and x.nueva is distinct from u.zona_id;

  if v_problemas is not null then
    raise exception using
      message = 'La migración 0010 (la zona de cada ubicación sale de su posición) no se aplicó: hay '
                'ubicaciones que cambiarían de zona y algún colportor dejaría de verlas. No se cambió nada.',
      detail  = v_problemas,
      hint    = 'Resolvé cada ubicación de la lista y volvé a aplicar la migración.';
  end if;
end
$$;

-- ----------------------------------------------------------------------------
-- 4. ubicacion y house_status: la zona la pone el servidor
-- ----------------------------------------------------------------------------

drop trigger ubicacion_zona_propia on public.ubicacion;
drop trigger house_status_zona_propia on public.house_status;
drop function public.tg_zona_propia();

-- BEFORE INSERT/UPDATE de ubicacion. Lo que mande el cliente en zona_id se pisa siempre.
-- Una baja (o una fila ya dada de baja) conserva su zona: su tombstone tiene que llegarle a
-- quien tenía la fila. SECURITY DEFINER: lee zonas de cualquier campaña (la RLS de zona solo
-- muestra las propias) y las inscripciones de created_by.
create function public.tg_ubicacion_zona_por_posicion()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_se_mueve boolean;
begin
  if tg_op = 'UPDATE' and new.deleted_at is not null then
    new.zona_id := old.zona_id;
    return new;
  end if;

  -- Compartido por ciudad: espera a que termine un recálculo de zonas en curso (que lo toma
  -- exclusivo) y, como la sentencia siguiente toma un snapshot nuevo, calcula con el mapa ya
  -- guardado. Sin esto, una casa que entra mientras se guarda una zona queda con la zona vieja.
  perform pg_advisory_xact_lock_shared(hashtextextended('mapa_ciudad:' || new.ciudad_id::text, 0));

  v_se_mueve := tg_op = 'INSERT'
                or (new.lat, new.lon, new.ciudad_id) is distinct from (old.lat, old.lon, old.ciudad_id);

  new.zona_id := public.zona_de_posicion(
    new.lat, new.lon, new.ciudad_id,
    case when v_se_mueve
         then public.ubicacion_campanias_preferidas(null, coalesce(auth.uid(), new.created_by))
         else public.ubicacion_campanias_preferidas(old.zona_id, new.created_by)
    end);
  return new;
end;
$$;

create trigger ubicacion_zona_por_posicion
  before insert or update on public.ubicacion
  for each row execute function public.tg_ubicacion_zona_por_posicion();

-- BEFORE INSERT/UPDATE de house_status: su zona es la de su ubicación. Una baja conserva la
-- suya, como en ubicacion.
create function public.tg_house_status_zona_de_su_ubicacion()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if tg_op = 'UPDATE' and new.deleted_at is not null then
    new.zona_id := old.zona_id;
    return new;
  end if;
  new.zona_id := (select u.zona_id from public.ubicacion u where u.id = new.ubicacion_id);
  return new;
end;
$$;

create trigger house_status_zona_de_su_ubicacion
  before insert or update on public.house_status
  for each row execute function public.tg_house_status_zona_de_su_ubicacion();

-- Cuando la ubicación cambia de zona (por cualquier camino: se mueve, se recalcula una zona, la
-- migración), lo que cuelga de ella tiene que salir en el delta de los colportores de la zona
-- nueva, que empiezan a verlo: su house_status toma la zona (y sube su xmin_w) y sus espacios
-- reciben un UPDATE nulo. AFTER sin «UPDATE OF zona_id»: la zona la cambia el trigger BEFORE,
-- no el SET del comando.
create function public.tg_ubicacion_zona_a_dependientes()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  update public.house_status h
     set zona_id = new.zona_id
   where h.ubicacion_id = new.id
     and h.deleted_at is null
     and h.zona_id is distinct from new.zona_id;

  update public.espacio e
     set deleted_at = e.deleted_at
   where e.ubicacion_id = new.id
     and e.deleted_at is null
     and e.xmin_w <> pg_current_xact_id();
  return null;
end;
$$;

create trigger ubicacion_zona_a_dependientes
  after update on public.ubicacion
  for each row when (old.zona_id is distinct from new.zona_id)
  execute function public.tg_ubicacion_zona_a_dependientes();

-- zona_id la pone el servidor: el push la descarta del payload (contrato §5.4).
update sync.entidad
   set columnas_servidor = columnas_servidor || array['zona_id']
 where nombre in ('ubicacion', 'house_status');

-- Políticas: la zona ya no la elige el cliente, así que no se le exige que sea suya (R-CM04).
-- Qué filas puede tocar cada uno (USING) queda igual que en 0003.
drop policy ubicacion_por_zona_insert on public.ubicacion;
drop policy ubicacion_por_zona_update on public.ubicacion;
drop policy house_status_por_zona_insert on public.house_status;

create policy ubicacion_por_zona_insert on public.ubicacion
  for insert to authenticated
  with check (created_by = (select auth.uid()));

-- Mover a otra zona (o fuera de toda zona): SOLO casas propias. La fila nueva tiene que seguir
-- siendo suya o de una de sus zonas; una casa que registró otro colportor se puede corregir
-- dentro de la zona, pero no mandarla a la de otro (el push queda invalid con 42501). Es una
-- protección: la RLS de SELECT sobre la fila nueva ya lo frenaba; acá queda escrito.
create policy ubicacion_por_zona_update on public.ubicacion
  for update to authenticated
  using (zona_id in (select public.mis_zonas()) or created_by = (select auth.uid()))
  with check (zona_id in (select public.mis_zonas()) or created_by = (select auth.uid()));

-- El estado de una casa que el colportor ve (de su zona, o registrada por él aunque caiga en
-- otra): la subconsulta pasa por la RLS de ubicacion.
create policy house_status_por_zona_insert on public.house_status
  for insert to authenticated
  with check (created_by = (select auth.uid())
              and exists (select 1 from public.ubicacion u where u.id = ubicacion_id));

-- ----------------------------------------------------------------------------
-- 5. Índices: posición (zonas), distancia (5 m) y dirección normalizada
-- ----------------------------------------------------------------------------

create index ubicacion_geometria_idx on public.ubicacion
  using gist (public.ubicacion_geometria(lat, lon))
  where deleted_at is null;
create index ubicacion_geografia_idx on public.ubicacion
  using gist (public.ubicacion_geografia(lat, lon))
  where deleted_at is null;

drop index public.ubicacion_dedup_idx;
create index ubicacion_direccion_idx on public.ubicacion
  (ciudad_id, public.direccion_normalizada(calle), public.direccion_normalizada(numero))
  where deleted_at is null;

comment on index public.ubicacion_direccion_idx is
  'No es único a propósito mientras D1 esté pendiente (ver 0010). Acelera el aviso de dirección repetida.';

-- ----------------------------------------------------------------------------
-- 6. Recálculo al cambiar una zona
-- ----------------------------------------------------------------------------

-- Recalcula (y pone al día) las ubicaciones que el cambio de p_zona_id puede mover. Devuelve
-- cuántas cambiaron. El UPDATE solo toca las que cambian (no republica de más); el trigger
-- BEFORE vuelve a calcular lo mismo. Interna.
create function public.recalcular_zona_de_ubicaciones(p_ciudad_id uuid, p_zona_id uuid,
                                                      p_forma_vieja extensions.geometry,
                                                      p_forma_nueva extensions.geometry)
returns integer
language plpgsql
set search_path = ''
as $$
declare
  v_filas integer;
begin
  update public.ubicacion u
     set zona_id = x.nueva
    from (
      select a.id,
             public.zona_de_posicion(v.lat, v.lon, v.ciudad_id,
                                     public.ubicacion_campanias_preferidas(v.zona_id, v.created_by)) as nueva,
             v.zona_id as actual
        from public.ubicaciones_de_zona_cambiada(p_ciudad_id, p_zona_id, p_forma_vieja, p_forma_nueva) a
        join public.ubicacion v on v.id = a.id
    ) x
   where u.id = x.id
     and x.nueva is distinct from x.actual;
  get diagnostics v_filas = row_count;
  return v_filas;
end;
$$;

-- AFTER INSERT/UPDATE de zona, por cualquier camino (guardar_zona, baja_zona, seed, service_role):
-- si la zona nace, cambia de forma, se da de baja o vuelve. El UPDATE nulo que republica el mapa
-- (0008) no cambia nada de eso y no recalcula. SECURITY DEFINER: escribe ubicaciones de otros.
create function public.tg_zona_recalcular_ubicaciones()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_ciudad uuid;
begin
  if tg_op = 'UPDATE'
     and new.poligono_geojson = old.poligono_geojson
     and new.deleted_at is not distinct from old.deleted_at then
    return null;
  end if;

  select cc.ciudad_id into v_ciudad from public.campania_ciudad cc where cc.id = new.campania_ciudad_id;

  -- Exclusivo por ciudad hasta el commit: espera a las escrituras de ubicaciones en curso de esa
  -- ciudad (tienen el compartido) y frena las que llegan hasta que el mapa nuevo esté guardado.
  -- El recálculo corre después, con un snapshot que ya las ve.
  perform pg_advisory_xact_lock(hashtextextended('mapa_ciudad:' || v_ciudad::text, 0));

  perform public.recalcular_zona_de_ubicaciones(
    v_ciudad, new.id,
    case when tg_op = 'UPDATE' and old.deleted_at is null then public.zona_geometria(old.poligono_geojson) end,
    case when new.deleted_at is null then public.zona_geometria(new.poligono_geojson) end);
  return null;
end;
$$;

create trigger zona_recalcular_ubicaciones
  after insert or update on public.zona
  for each row execute function public.tg_zona_recalcular_ubicaciones();

-- Misma firma que en 0008: la vista previa de guardar_zona() y baja_zona(). Cuántas ubicaciones
-- cambiarían de zona si p_zona_id (null = zona nueva) pasa a tener p_poligono (null = baja), con
-- la misma regla que el recálculo, sobre el mapa como quedaría. guardar_zona() y baja_zona() la
-- llaman bajo el lock del mapa, así que al guardar devuelve lo que el trigger cambia. Una zona
-- nueva todavía no tiene id: se simula con el UUID más alto (un UUID v7 nuevo es mayor que los
-- existentes, así que desempata igual). Interna.
create or replace function public.zona_ubicaciones_que_cambian(p_zona_id uuid, p_campania_ciudad_id uuid,
                                                               p_poligono jsonb)
returns integer
language sql
stable
set search_path = ''
as $$
  select count(*)::integer
    from public.campania_ciudad cc
    cross join lateral public.ubicaciones_de_zona_cambiada(
      cc.ciudad_id, p_zona_id,
      (select public.zona_geometria(z.poligono_geojson) from public.zona z
        where z.id = p_zona_id and z.deleted_at is null),
      case when p_poligono is not null then public.zona_geometria(p_poligono) end) a
    join public.ubicacion u on u.id = a.id
   where cc.id = p_campania_ciudad_id
     and public.zona_de_posicion(
           u.lat, u.lon, u.ciudad_id,
           public.ubicacion_campanias_preferidas(u.zona_id, u.created_by),
           p_zona_id,
           coalesce(p_zona_id, 'ffffffff-ffff-ffff-ffff-ffffffffffff'::uuid),
           p_campania_ciudad_id,
           p_poligono)
         is distinct from u.zona_id;
$$;

comment on function public.zona_ubicaciones_que_cambian(uuid, uuid, jsonb) is
  'Ubicaciones que cambiarían de zona si p_zona_id (null = nueva) pasa a p_poligono (null = baja), '
  'con la regla de 0010 sobre el mapa como quedaría. Interna.';

-- ----------------------------------------------------------------------------
-- 7. Republicar la zona al asignarla (rotación de colportores)
-- ----------------------------------------------------------------------------

-- AFTER INSERT/UPDATE de campania_colportor: cuando una inscripción viva pasa a tener una zona
-- (asignar_zona(), un alta con zona, una reactivación), UPDATE nulo sobre las ubicaciones de esa
-- zona (las que la tienen y las que caen en su forma: al pasar por el trigger BEFORE se
-- recalcula su zona, por si su campaña recién empezó), y sobre el house_status y los espacios de
-- las que quedan en ella. Así le llegan en el próximo delta a quien la toma, aunque se hayan
-- cargado antes de su último pull. Costo: se les vuelven a entregar a todos los que trabajan
-- esa zona. Lo ya republicado en esta transacción no se vuelve a tocar.
-- SECURITY DEFINER: escribe filas que la RLS de quien asigna no deja tocar.
create function public.tg_campania_colportor_republicar_zona()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_ciudad uuid;
  v_forma  extensions.geometry;
begin
  if new.zona_id is null or new.deleted_at is not null then
    return null;
  end if;
  if tg_op = 'UPDATE' and old.deleted_at is null
     and new.zona_id is not distinct from old.zona_id
     and new.campania_id = old.campania_id and new.usuario_id = old.usuario_id then
    return null;
  end if;

  select cc.ciudad_id, public.zona_geometria(z.poligono_geojson)
    into v_ciudad, v_forma
    from public.zona z
    join public.campania_ciudad cc on cc.id = z.campania_ciudad_id
   where z.id = new.zona_id;

  update public.ubicacion u
     set deleted_at = u.deleted_at
   where u.id in (select a.id from public.ubicaciones_de_zona_cambiada(v_ciudad, new.zona_id, v_forma, null) a)
     and u.xmin_w <> pg_current_xact_id();

  update public.house_status h
     set deleted_at = h.deleted_at
    from public.ubicacion u
   where u.id = h.ubicacion_id
     and u.zona_id = new.zona_id and u.deleted_at is null
     and h.deleted_at is null
     and h.xmin_w <> pg_current_xact_id();

  update public.espacio e
     set deleted_at = e.deleted_at
    from public.ubicacion u
   where u.id = e.ubicacion_id
     and u.zona_id = new.zona_id and u.deleted_at is null
     and e.deleted_at is null
     and e.xmin_w <> pg_current_xact_id();

  return null;
end;
$$;

comment on function public.tg_campania_colportor_republicar_zona() is
  'AFTER INSERT/UPDATE de campania_colportor: al asignar una zona, UPDATE nulo sobre sus '
  'ubicaciones, house_status y espacios para que entren en el próximo delta de quien la toma.';

create trigger campania_colportor_republicar_zona
  after insert or update of zona_id, deleted_at, campania_id, usuario_id on public.campania_colportor
  for each row execute function public.tg_campania_colportor_republicar_zona();

-- ----------------------------------------------------------------------------
-- 8. Posible duplicado (aviso, no bloqueo)
-- ----------------------------------------------------------------------------

-- Las ubicaciones vivas que el usuario ve (SECURITY INVOKER: decide la RLS) que son posible
-- duplicado de una dirección: misma calle, número y ciudad (normalizados), o a menos de 5 m.
-- p_excluir_id: la propia ubicación, si ya existe. La app calcula lo mismo offline
-- (front-colportores-mobile#207); esto es para el panel y los reportes.
create function public.posibles_duplicados_de_ubicacion(
  p_ciudad_id  uuid,
  p_calle      text,
  p_numero     text,
  p_lat        double precision,
  p_lon        double precision,
  p_excluir_id uuid default null
)
returns table (ubicacion_id uuid, calle text, numero text, distancia_m double precision,
               misma_direccion boolean)
language sql
stable
set search_path = ''
as $$
  select u.id, u.calle, u.numero,
         extensions.st_distance(public.ubicacion_geografia(u.lat, u.lon),
                                public.ubicacion_geografia(p_lat, p_lon)),
         coalesce(u.ciudad_id = p_ciudad_id
                  and public.direccion_normalizada(u.calle) = public.direccion_normalizada(p_calle)
                  and public.direccion_normalizada(u.numero) = public.direccion_normalizada(p_numero),
                  false)
    from public.ubicacion u
   where u.deleted_at is null
     and u.id is distinct from p_excluir_id
     and ((u.ciudad_id = p_ciudad_id
           and public.direccion_normalizada(u.calle) = public.direccion_normalizada(p_calle)
           and public.direccion_normalizada(u.numero) = public.direccion_normalizada(p_numero))
          or (extensions.st_dwithin(public.ubicacion_geografia(u.lat, u.lon),
                                    public.ubicacion_geografia(p_lat, p_lon), 5.0::double precision)
              and extensions.st_distance(public.ubicacion_geografia(u.lat, u.lon),
                                         public.ubicacion_geografia(p_lat, p_lon)) < 5.0))
   order by 4, 1;
$$;

comment on function public.posibles_duplicados_de_ubicacion(uuid, text, text, double precision, double precision, uuid) is
  'Posible duplicado (aviso, no bloqueo): ubicaciones vivas visibles con la misma dirección '
  'normalizada en la ciudad, o a menos de 5 m. SECURITY INVOKER.';

-- ----------------------------------------------------------------------------
-- 9. Datos: cada ubicación viva toma la zona de su posición (la revisión de la sección 3 ya
--    pasó) y cada house_status la de su ubicación
-- ----------------------------------------------------------------------------

update public.ubicacion u
   set zona_id = x.nueva
  from (
    select v.id,
           public.zona_de_posicion(v.lat, v.lon, v.ciudad_id,
                                   public.ubicacion_campanias_preferidas(v.zona_id, v.created_by)) as nueva
      from public.ubicacion v
     where v.deleted_at is null
  ) x
 where u.id = x.id
   and u.zona_id is distinct from x.nueva;

update public.house_status h
   set zona_id = u.zona_id
  from public.ubicacion u
 where u.id = h.ubicacion_id
   and h.deleted_at is null
   and h.zona_id is distinct from u.zona_id;

-- ----------------------------------------------------------------------------
-- 10. Privilegios
-- ----------------------------------------------------------------------------

-- `authenticated` también: en una base creada desde cero los default privileges de la imagen
-- le dan EXECUTE sobre cada función nueva de public (ver 0008).
revoke all on function
  public.ubicacion_geometria(double precision, double precision),
  public.ubicacion_geografia(double precision, double precision),
  public.direccion_normalizada(text),
  public.ubicacion_campanias_preferidas(uuid, uuid),
  public.zona_de_posicion(double precision, double precision, uuid, uuid[], uuid, uuid, uuid, jsonb),
  public.ubicaciones_de_zona_cambiada(uuid, uuid, extensions.geometry, extensions.geometry),
  public.recalcular_zona_de_ubicaciones(uuid, uuid, extensions.geometry, extensions.geometry),
  public.tg_ubicacion_zona_por_posicion(),
  public.tg_house_status_zona_de_su_ubicacion(),
  public.tg_ubicacion_zona_a_dependientes(),
  public.tg_zona_recalcular_ubicaciones(),
  public.tg_campania_colportor_republicar_zona(),
  public.posibles_duplicados_de_ubicacion(uuid, text, text, double precision, double precision, uuid)
  from public, anon, authenticated;

-- Puras, sin datos: las evalúan los índices de ubicacion como quien escribe la fila, y
-- posibles_duplicados_de_ubicacion() como quien la llama.
grant execute on function
  public.ubicacion_geometria(double precision, double precision),
  public.ubicacion_geografia(double precision, double precision),
  public.direccion_normalizada(text)
  to authenticated, service_role;

-- Lectura para el panel y los reportes (la RLS decide qué filas).
grant execute on function
  public.posibles_duplicados_de_ubicacion(uuid, text, text, double precision, double precision, uuid)
  to authenticated, service_role;

-- Internas: solo service_role (y el dueño, que es quien corre adentro de los triggers y RPC).
grant execute on function
  public.ubicacion_campanias_preferidas(uuid, uuid),
  public.zona_de_posicion(double precision, double precision, uuid, uuid[], uuid, uuid, uuid, jsonb),
  public.ubicaciones_de_zona_cambiada(uuid, uuid, extensions.geometry, extensions.geometry),
  public.recalcular_zona_de_ubicaciones(uuid, uuid, extensions.geometry, extensions.geometry)
  to service_role;
