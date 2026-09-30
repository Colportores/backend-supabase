-- ============================================================================
-- 0011 · La zona se calcula al descargar (backend-supabase#32)
--
-- Decisión de Cristian del 29/09 sobre D2 (backend-supabase#24): la zona es una guía visual, un
-- «trabajá por acá» para el colportor y el coordinador. No hace falta para cargar ubicaciones ni
-- para vender, y las ubicaciones no guardan zona ni campaña. Lo que la zona sí decide es qué
-- casas bajan al teléfono de cada colportor, y eso se calcula al descargar (HU-SYNC-011;
-- contrato-sync-engine.md §2.1; esquema-datos.md, «Qué ubicaciones descarga cada colportor»).
-- Rehace parte de 0010 (PR #31), que ya está aplicada: forward-only, así que va en esta.
--
-- ## Qué se va (todo de 0010)
--
--   · ubicacion.zona_id y house_status.zona_id, con sus índices y sus FK.
--   · El trigger que calculaba la zona por posición, el que la copiaba a house_status y el que
--     republicaba los dependientes al cambiar de zona. Con ellos, la regla de desempate por id y
--     la campaña preferida (D2 (a)): ya no hay nada que desempatar.
--   · El recálculo al crear, redibujar o dar de baja una zona (trigger en zona) y su lock por
--     ciudad. guardar_zona() y baja_zona() ya no recalculan nada.
--   · El republicado al asignar una zona (trigger en campania_colportor). Lo reemplaza la huella
--     del área en el watermark (abajo).
--   · La regla «mover a otra zona: solo casas propias»: sin zona en la fila no hay a dónde mover.
--   · zona_id en sync.entidad.columnas_servidor. Una app vieja que la siga mandando no falla: el
--     push descarta en silencio las columnas que la tabla no tiene.
--
-- Queda de 0010: ubicacion_geometria(), ubicacion_geografia(), direccion_normalizada(), los
-- índices de distancia y de dirección, y posibles_duplicados_de_ubicacion() (el aviso de los
-- 5 m). El índice GiST de la posición pasa a incluir las bajas (lo usa el pull).
--
-- ## Quién ve qué ubicación (RLS)
--
-- El colportor elige en cada pull si baja las casas de su zona o las de toda la ciudad, así que
-- la RLS tiene que dejarle ver la ciudad: la zona deja de ser un permiso. Ve una ubicación si la
-- registró él o si es de una ciudad de sus campañas vigentes (mis_ciudades_de_trabajo(), con la
-- vigencia de mis_zonas()), y la puede corregir en los mismos casos. El coordinador y el ADMIN
-- las ven todas, como antes. espacio y house_status siguen a su ubicación: los ve quien ve la
-- ubicación, y los escribe quien la puede corregir; house_status, además, quien lo escribió.
--
-- ## Qué baja en el pull (sync.pull, parámetro nuevo p_alcance)
--
--   · 'zona' (default): las ubicaciones que registró él, más las que caen dentro del polígono
--     (ST_Covers, borde incluido) de alguna de sus zonas asignadas (mis_zonas()) y son de la
--     ciudad de esa zona. Sin zona asignada, solo las propias.
--   · 'ciudad': las que registró él, más todas las de las ciudades de sus campañas vigentes.
-- Con cada ubicación bajan sus espacios y su house_status (sync.entidad.columna_ubicacion). Las
-- bajas lógicas bajan como las vivas: el tombstone le llega a quien tiene la casa.
-- La parte «zona» sale del índice GiST, una vez por consulta (ubicaciones_de_mi_zona()). Con
-- supabase/bench (60.000 casas en una ciudad, 400 por zona), bajar completa el área de una zona
-- (ubicacion, espacio y house_status) tarda ~60 ms, y un pull sin novedades ~50 ms; la primera
-- página de «ciudad», ~80 ms (supabase/bench/README.md).
--
-- ## Pull completo del área al asignar o redibujar la zona
--
-- El watermark de ubicacion, espacio y house_status guarda la huella del área con la que se
-- calculó ('area': md5 del alcance y de las zonas con su forma, o de las ciudades). Si la que
-- manda la app no coincide con la de ahora (le asignaron otra zona, se la redibujaron, empezó o
-- terminó una campaña, lo reactivaron, cambió de alcance), esa entidad arranca de cero: baja
-- completa el área nueva, también lo que se cargó antes de su último pull. Un watermark sin
-- huella (de antes de 0011) arranca de cero una vez. El watermark sigue siendo opaco para la app.
-- Un pull de estas entidades sin nada nuevo en el área deja el cursor en el horizonte: lo de
-- abajo ya se revisó entero, y el pull siguiente no lo vuelve a recorrer.
--
-- Cuando una ubicación cambia de posición o de ciudad, sus espacios y su house_status se
-- republican: pueden entrar en el área de otro colportor, y sin eso quedarían debajo de su
-- watermark. Republicar sube solo xmin_w, no sync_version ni updated_at (colportores.republicar en
-- tg_auditoria_update): si subiera la versión, el job pendiente de cualquier teléfono sobre esas
-- filas volvería `conflict` y se perdería (el lote [casa movida, estado, piso] daba
-- accepted/conflict/conflict). house_status.lat/lon pasan a ser del servidor: son la posición de
-- su ubicación (el pin), la copia un trigger y el push las descarta.
--
-- ## «Incluye N ubicaciones» (vista 24)
--
-- guardar_zona() y baja_zona() devuelven ubicaciones_incluidas en lugar de
-- ubicaciones_que_cambian: las ubicaciones vivas de la ciudad que caen dentro de la forma,
-- calculado en el momento con PostGIS (índice GiST). Es la regla de la parte «zona» del pull.
--
-- ## Pendientes de Cristian (supuestos de HU-SYNC-011)
--
--   · S60, qué baja si el colportor omite la elección: p_alcance es opcional y su default es
--     'zona', que es lo que bajaba hasta ahora (su zona y lo propio).
--   · S55, cuál es «la ciudad» si la campaña tiene varias, y qué baja sin zona asignada:
--     provisorio, todas las ciudades de sus campañas vigentes, tenga zona o no. Cambiarlo es
--     cambiar mis_ciudades_de_trabajo().
--   · S54, cambiar de alcance después: el servidor ya lo soporta (cambia la huella y baja
--     completo el alcance nuevo). Qué hace la app con las casas que quedan afuera es de
--     front-colportores-mobile#244: el servidor no borra nada por ausencia.
--
-- ## Datos existentes (criterio 2: nada se pierde)
--
-- zona_id era un dato derivado: desde 0010 lo calcula el servidor con la posición, que queda.
-- Ninguna venta, visita, persona ni espacio depende de él. No se toca ninguna fila: ubicacion y
-- house_status no pierden filas ni cambia ninguna otra columna, y su sync_version no sube. Nadie
-- deja de ver una ubicación viva: la zona de cada una es de su ciudad (0010), y esa ciudad es de
-- las campañas vigentes de quien tiene la zona. La primera vez que cada app sincronice después
-- de esto, ubicacion, espacio y house_status bajan completos (su watermark no tiene huella).
--
-- Forward-only: esta migración no se edita una vez aplicada.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. Fuera la zona por posición, su recálculo y el republicado (0010)
-- ----------------------------------------------------------------------------

drop trigger ubicacion_zona_por_posicion on public.ubicacion;
drop trigger ubicacion_zona_a_dependientes on public.ubicacion;
drop trigger house_status_zona_de_su_ubicacion on public.house_status;
drop trigger zona_recalcular_ubicaciones on public.zona;
drop trigger campania_colportor_republicar_zona on public.campania_colportor;

drop function public.tg_ubicacion_zona_por_posicion();
drop function public.tg_ubicacion_zona_a_dependientes();
drop function public.tg_house_status_zona_de_su_ubicacion();
drop function public.tg_zona_recalcular_ubicaciones();
drop function public.tg_campania_colportor_republicar_zona();
drop function public.recalcular_zona_de_ubicaciones(uuid, uuid, extensions.geometry, extensions.geometry);
drop function public.ubicaciones_de_zona_cambiada(uuid, uuid, extensions.geometry, extensions.geometry);
drop function public.zona_de_posicion(double precision, double precision, uuid, uuid[], uuid, uuid, uuid, jsonb);
drop function public.ubicacion_campanias_preferidas(uuid, uuid);

-- ----------------------------------------------------------------------------
-- 2. Fuera ubicacion.zona_id y house_status.zona_id
-- ----------------------------------------------------------------------------

-- Las políticas que leen la columna se van antes que ella (dependen de la columna); las nuevas
-- van en la sección 4. Se van también las de INSERT, para que las nueve queden con el mismo
-- criterio y nombre.
drop policy ubicacion_por_zona_select on public.ubicacion;
drop policy ubicacion_por_zona_insert on public.ubicacion;
drop policy ubicacion_por_zona_update on public.ubicacion;
drop policy espacio_por_zona_select on public.espacio;
drop policy espacio_por_zona_insert on public.espacio;
drop policy espacio_por_zona_update on public.espacio;
drop policy house_status_por_zona_select on public.house_status;
drop policy house_status_por_zona_insert on public.house_status;
drop policy house_status_por_zona_update on public.house_status;

-- Con cada columna se van su índice (ubicacion_zona_idx, house_status_zona_idx) y su FK.
alter table public.ubicacion drop column zona_id;
alter table public.house_status drop column zona_id;

comment on table public.ubicacion is
  'Casa del territorio, con su dirección. Sin datos de persona (ADR-004). No guarda zona ni '
  'campaña (0011): la ve quien trabaja en su ciudad, y qué casas bajan al teléfono lo decide el '
  'alcance del pull (su zona o toda la ciudad, HU-SYNC-011).';

-- ----------------------------------------------------------------------------
-- 3. El registro de entidades: sin zona_id, y qué entidades bajan según el alcance
-- ----------------------------------------------------------------------------

update sync.entidad
   set columnas_servidor = array_remove(columnas_servidor, 'zona_id')
 where 'zona_id' = any (columnas_servidor);

alter table sync.entidad add column columna_ubicacion text;

comment on column sync.entidad.columna_ubicacion is
  'La columna de la fila que es el id de su ubicación. Si no es null, el pull baja la fila solo '
  'si su ubicación está en el alcance del colportor (su zona o toda la ciudad, HU-SYNC-011), y su '
  'watermark lleva la huella del área (0011).';

update sync.entidad set columna_ubicacion = 'id'           where nombre = 'ubicacion';
update sync.entidad set columna_ubicacion = 'ubicacion_id' where nombre in ('espacio', 'house_status');

-- ----------------------------------------------------------------------------
-- 4. RLS: la ciudad, no la zona
-- ----------------------------------------------------------------------------

-- Las ciudades de las campañas vigentes del usuario autenticado (ciudades vivas en la campaña).
-- Misma vigencia que mis_zonas(), sin pedir zona asignada. Es «la ciudad» de HU-SYNC-011, con
-- el supuesto S55 pendiente (ver la cabecera). SECURITY DEFINER y search_path vacío, como
-- mis_zonas(): la usan las políticas y no puede depender de la RLS que ayuda a evaluar.
create function public.mis_ciudades_de_trabajo()
returns setof uuid
language sql
stable
security definer
set search_path = ''
as $$
  select distinct cc.ciudad_id
    from public.mis_campanias_vigentes() v
    join public.campania_ciudad cc on cc.campania_id = v.campania_id
   where cc.deleted_at is null;
$$;

comment on function public.mis_ciudades_de_trabajo() is
  'Ciudades vivas de las campañas vigentes del usuario autenticado. Deciden qué ubicaciones ve y '
  'corrige un colportor, y qué baja con el alcance «ciudad» del pull (HU-SYNC-011, S55 pendiente).';

-- La ve quien la registró, quien trabaja en su ciudad, el coordinador y el ADMIN (como antes).
create policy ubicacion_por_ciudad_select on public.ubicacion
  for select to authenticated
  using (created_by = (select auth.uid())
         or ciudad_id in (select public.mis_ciudades_de_trabajo())
         or (select public.tiene_rol('COORDINADOR'))
         or (select public.tiene_rol('ADMIN')));

-- R-CM04: se puede registrar en cualquier lado (no hay zona que exigir).
create policy ubicacion_por_ciudad_insert on public.ubicacion
  for insert to authenticated
  with check (created_by = (select auth.uid()));

-- La corrige quien la registró o quien trabaja en su ciudad. La fila corregida tiene que seguir
-- cumpliendo lo mismo: una casa ajena no se manda a una ciudad donde no trabaja.
create policy ubicacion_por_ciudad_update on public.ubicacion
  for update to authenticated
  using (created_by = (select auth.uid())
         or ciudad_id in (select public.mis_ciudades_de_trabajo()))
  with check (created_by = (select auth.uid())
              or ciudad_id in (select public.mis_ciudades_de_trabajo()));

-- espacio: lo ve quien ve la ubicación (la subconsulta pasa por la RLS de ubicacion, que ya
-- incluye al coordinador y al ADMIN); lo escribe quien la puede corregir.
create policy espacio_por_ubicacion_select on public.espacio
  for select to authenticated
  using (exists (select 1 from public.ubicacion u where u.id = ubicacion_id));
create policy espacio_por_ubicacion_insert on public.espacio
  for insert to authenticated
  with check (created_by = (select auth.uid())
              and exists (select 1 from public.ubicacion u
                           where u.id = ubicacion_id
                             and (u.created_by = (select auth.uid())
                                  or u.ciudad_id in (select public.mis_ciudades_de_trabajo()))));
create policy espacio_por_ubicacion_update on public.espacio
  for update to authenticated
  using (exists (select 1 from public.ubicacion u
                  where u.id = ubicacion_id
                    and (u.created_by = (select auth.uid())
                         or u.ciudad_id in (select public.mis_ciudades_de_trabajo()))));

-- house_status: igual, y además quien lo escribió.
create policy house_status_por_ubicacion_select on public.house_status
  for select to authenticated
  using (created_by = (select auth.uid())
         or exists (select 1 from public.ubicacion u where u.id = ubicacion_id));
create policy house_status_por_ubicacion_insert on public.house_status
  for insert to authenticated
  with check (created_by = (select auth.uid())
              and exists (select 1 from public.ubicacion u
                           where u.id = ubicacion_id
                             and (u.created_by = (select auth.uid())
                                  or u.ciudad_id in (select public.mis_ciudades_de_trabajo()))));
create policy house_status_por_ubicacion_update on public.house_status
  for update to authenticated
  using (created_by = (select auth.uid())
         or exists (select 1 from public.ubicacion u
                     where u.id = ubicacion_id
                       and (u.created_by = (select auth.uid())
                            or u.ciudad_id in (select public.mis_ciudades_de_trabajo()))));

-- ----------------------------------------------------------------------------
-- 5. Una ubicación que se mueve republica sus espacios y su house_status
-- ----------------------------------------------------------------------------

-- Republicar sin invalidar lo pendiente. Un UPDATE nulo que solo tiene que hacer salir una fila
-- en el delta de alguien más sube el cursor (xmin_w), pero no la versión ni updated_at: la fila
-- no cambió para nadie, y subir sync_version haría que el job pendiente de cualquier teléfono
-- sobre esa fila vuelva `conflict` (LWW: gana el servidor con la misma fila de antes y la acción
-- del colportor se pierde). El republicado lo marca con la GUC local colportores.republicar,
-- solo mientras dura su UPDATE. Mismo cuerpo que en 0002 fuera de eso.
create or replace function public.tg_auditoria_update()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.created_at := old.created_at;
  new.created_by := old.created_by;
  -- Sin esto, una fila actualizada conserva el xid de su INSERT, queda detrás del watermark de
  -- cualquier cliente que ya la bajó, y la modificación no se propaga nunca (0002).
  new.xmin_w := pg_current_xact_id();
  if current_setting('colportores.republicar', true) = 'on' then
    new.updated_at := old.updated_at;
    new.sync_version := old.sync_version;
  else
    new.updated_at := now();
    new.sync_version := old.sync_version + 1;
  end if;
  return new;
end;
$$;

comment on function public.tg_auditoria_update() is
  'BEFORE UPDATE: updated_at = now(), sync_version = old + 1, xmin_w = xid actual; '
  'created_at/created_by inmutables. Con colportores.republicar = on (republicado, 0011) solo sube '
  'xmin_w.';

-- house_status.lat/lon son la copia de la posición de su ubicación: de ahí sale el pin del mapa
-- (ADR-003). Las pone el servidor, como la zona en 0010: el push las descarta
-- (columnas_servidor) y este trigger las copia en todo INSERT y UPDATE. Así el pin no queda en
-- la posición vieja cuando otro corrige la casa, ni vuelve a ella con el push de un teléfono que
-- todavía no se enteró. SECURITY DEFINER: lee la ubicación aunque la RLS no se la muestre.
create function public.tg_house_status_posicion_de_su_ubicacion()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_lat double precision;
  v_lon double precision;
begin
  select u.lat, u.lon into v_lat, v_lon from public.ubicacion u where u.id = new.ubicacion_id;
  if found then
    new.lat := v_lat;
    new.lon := v_lon;
  end if;
  return new;
end;
$$;

comment on function public.tg_house_status_posicion_de_su_ubicacion() is
  'BEFORE INSERT/UPDATE de house_status: lat y lon son las de su ubicación (el pin, ADR-003).';

create trigger house_status_posicion_de_su_ubicacion
  before insert or update on public.house_status
  for each row execute function public.tg_house_status_posicion_de_su_ubicacion();

update sync.entidad
   set columnas_servidor = columnas_servidor || array['lat', 'lon']
 where nombre = 'house_status';

-- AFTER UPDATE de ubicacion, cuando cambia la posición o la ciudad (por cualquier camino). La
-- casa puede entrar en el área de otro colportor: ella misma sale en su delta (el UPDATE le sube
-- el xmin_w), pero sus espacios y su house_status no, y quedarían debajo de su watermark.
-- Republicado (sin subir la versión) de los vivos. Lo ya tocado en esta transacción no se vuelve
-- a tocar, salvo el house_status si su pin quedó en otra posición (el mismo lote del teléfono
-- puede subir el estado antes que la casa movida).
-- SECURITY DEFINER: escribe filas que la RLS de quien mueve la casa puede no dejarle tocar.
create function public.tg_ubicacion_posicion_a_dependientes()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_antes text := current_setting('colportores.republicar', true);
begin
  perform set_config('colportores.republicar', 'on', true);

  -- El trigger de house_status le copia la posición nueva.
  update public.house_status h
     set deleted_at = h.deleted_at
   where h.ubicacion_id = new.id
     and h.deleted_at is null
     and (h.xmin_w <> pg_current_xact_id()
          or (h.lat, h.lon) is distinct from (new.lat, new.lon));

  update public.espacio e
     set deleted_at = e.deleted_at
   where e.ubicacion_id = new.id
     and e.deleted_at is null
     and e.xmin_w <> pg_current_xact_id();

  -- Solo durante el republicado: lo que siga en la transacción (el próximo job del lote) sube
  -- la versión como siempre.
  perform set_config('colportores.republicar', coalesce(v_antes, 'off'), true);
  return null;
end;
$$;

comment on function public.tg_ubicacion_posicion_a_dependientes() is
  'AFTER UPDATE de ubicacion que la mueve (lat, lon o ciudad): republica (xmin_w, sin subir la '
  'versión) sus espacios y su house_status, para que entren en el delta de quien la empieza a '
  'tener en su área sin invalidar lo pendiente de nadie.';

create trigger ubicacion_posicion_a_dependientes
  after update on public.ubicacion
  for each row
  when ((old.lat, old.lon, old.ciudad_id) is distinct from (new.lat, new.lon, new.ciudad_id))
  execute function public.tg_ubicacion_posicion_a_dependientes();

-- ----------------------------------------------------------------------------
-- 6. «Incluye N ubicaciones» (vista 24): guardar_zona() y baja_zona()
-- ----------------------------------------------------------------------------

-- El índice GiST de la posición (0010) era solo de las vivas. La parte «zona» del pull también
-- baja las bajas (su tombstone), así que pasa a cubrirlas: lo usan el pull y este conteo
-- (ADR-018: el mismo índice espacial).
drop index public.ubicacion_geometria_idx;
create index ubicacion_geometria_idx on public.ubicacion
  using gist (public.ubicacion_geometria(lat, lon));

-- Las ubicaciones vivas de la ciudad de p_campania_ciudad_id que caen dentro de p_poligono
-- (ST_Covers, borde incluido). Es la parte «zona» del pull: lo que descargaría quien tenga esa
-- zona, sin contar las casas propias de afuera. Usa ubicacion_geometria_idx (GiST). null si no
-- hay forma. Interna.
create function public.zona_ubicaciones_incluidas(p_campania_ciudad_id uuid, p_poligono jsonb)
returns integer
language sql
stable
set search_path = ''
as $$
  select case when p_poligono is null then null else (
    select count(*)::integer
      from public.campania_ciudad cc
      join public.ubicacion u on u.ciudad_id = cc.ciudad_id
     where cc.id = p_campania_ciudad_id
       and u.deleted_at is null
       and extensions.st_covers(public.zona_geometria(p_poligono),
                                public.ubicacion_geometria(u.lat, u.lon)))
  end;
$$;

comment on function public.zona_ubicaciones_incluidas(uuid, jsonb) is
  '«Incluye N ubicaciones» de la vista 24: ubicaciones vivas de la ciudad dentro de p_poligono, '
  'con la misma regla que la parte «zona» del pull. Interna.';

-- Misma firma y mismo comportamiento que en 0008, salvo el conteo: devuelve
-- ubicaciones_incluidas (las ubicaciones vivas que caen dentro de la forma que se guarda o se
-- previsualiza) en lugar de ubicaciones_que_cambian. No recalcula nada: las ubicaciones no
-- guardan zona.
--
-- Devuelve {"guardada", "zona", "vertices", "poligono_geojson", "superposiciones",
--           "ubicaciones_incluidas"}.
create or replace function public.guardar_zona(
  p_campania_ciudad_id uuid,
  p_nombre             text,
  p_tipo_forma         text,
  p_color              text default null,
  p_centro_lat         double precision default null,
  p_centro_lon         double precision default null,
  p_radio_m            integer default null,
  p_vertices           jsonb default null,
  p_poligono_geojson   jsonb default null,
  p_zona_id            uuid default null,
  p_vista_previa       boolean default false
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_cc        public.campania_ciudad;
  v_zona      public.zona;
  v_nombre    text := nullif(btrim(coalesce(p_nombre, '')), '');
  v_vertices  jsonb := coalesce(p_vertices, '[]'::jsonb);
  v_poligono  jsonb;
  v_problema  text;
  v_v         jsonb;
  v_orden     integer;
  v_ordenes   integer[] := array[]::integer[];
  v_sup       jsonb;
  v_incluidas integer;
begin
  if auth.uid() is null then
    raise exception 'guardar_zona requiere un usuario autenticado'
      using errcode = 'insufficient_privilege';
  end if;

  -- El permiso primero: sin rol de staff, 42501 antes de mirar ningún dato.
  if not (public.tiene_rol('ADMIN') or public.tiene_rol('COORDINADOR')) then
    perform public.lanzar_motivo_mapa('SIN_PERMISO');
  end if;

  select * into v_cc from public.campania_ciudad cc where cc.id = p_campania_ciudad_id;
  if not found then
    perform public.lanzar_motivo_mapa('CIUDAD_FUERA_DE_CAMPANIA');
  end if;
  perform public.lanzar_motivo_mapa(public.motivo_mapa_de_campania(v_cc.campania_id));
  if v_cc.deleted_at is not null then
    perform public.lanzar_motivo_mapa('CIUDAD_FUERA_DE_CAMPANIA');
  end if;

  -- Un guardado a la vez por ciudad de la campaña: la superposición y el nombre se validan
  -- viendo lo último que se guardó.
  perform public.bloquear_mapa(v_cc.id);

  if p_zona_id is not null then
    select * into v_zona from public.zona z where z.id = p_zona_id for update;
    if not found or v_zona.deleted_at is not null then
      perform public.lanzar_motivo_mapa('ZONA_INEXISTENTE');
    end if;
    if v_zona.campania_ciudad_id <> v_cc.id then
      perform public.lanzar_motivo_mapa('ZONA_DE_OTRA_CIUDAD');
    end if;
  end if;

  -- Nombre
  if v_nombre is null then
    raise exception 'La zona necesita un nombre. Escribí uno.' using errcode = 'CZ009';
  end if;
  if exists (select 1 from public.zona z
              where z.campania_ciudad_id = v_cc.id and z.deleted_at is null
                and z.nombre = v_nombre and z.id is distinct from p_zona_id) then
    raise exception 'Ya hay una zona «%» en esta ciudad de la campaña. Elegí otro nombre.', v_nombre
      using errcode = 'CZ009';
  end if;

  -- Color
  if p_color is not null and p_color !~ '^#[0-9A-Fa-f]{6}$' then
    raise exception 'El color tiene que ser #RRGGBB (por ejemplo #3A7BD5). Elegilo de nuevo.'
      using errcode = 'CZ008';
  end if;

  -- Forma
  if p_tipo_forma = 'RADIAL' then
    if p_centro_lat is null or p_centro_lon is null or p_radio_m is null or p_radio_m <= 0 then
      raise exception 'Una zona radial necesita centro y un radio mayor a 0. Marcá el centro en el mapa y elegí el radio.'
        using errcode = 'CZ008';
    end if;
    if p_radio_m > 3000 then
      raise exception 'El radio de la zona es de % m y el máximo es 3000 m. Achicalo, o dividí el área en varias zonas.',
          p_radio_m
        using errcode = 'CZ008';
    end if;
    if p_centro_lat not between -90 and 90 or p_centro_lon not between -180 and 180 then
      raise exception 'El centro de la zona está fuera del mapa. Marcalo de nuevo.'
        using errcode = 'CZ008';
    end if;
    if jsonb_typeof(v_vertices) <> 'array' or jsonb_array_length(v_vertices) > 0 then
      raise exception 'Una zona radial no lleva esquinas. Quitalas o elegí «Por esquinas».'
        using errcode = 'CZ008';
    end if;
    v_poligono := public.zona_circulo_geojson(p_centro_lat, p_centro_lon, p_radio_m);

  elsif p_tipo_forma = 'ESQUINAS' then
    if p_centro_lat is not null or p_centro_lon is not null or p_radio_m is not null then
      raise exception 'Una zona por esquinas no lleva centro ni radio. Quitalos o elegí «Radial».'
        using errcode = 'CZ008';
    end if;
    if jsonb_typeof(v_vertices) <> 'array' or jsonb_array_length(v_vertices) < 3 then
      raise exception 'Una zona por esquinas necesita al menos 3 esquinas (tiene %). Marcá más esquinas en el mapa.',
          case when jsonb_typeof(v_vertices) = 'array' then jsonb_array_length(v_vertices) else 0 end
        using errcode = 'CZ008';
    end if;

    for v_v in select e from jsonb_array_elements(v_vertices) e loop
      if jsonb_typeof(v_v) <> 'object'
         or jsonb_typeof(v_v -> 'orden') is distinct from 'number'
         or jsonb_typeof(v_v -> 'lat') is distinct from 'number'
         or jsonb_typeof(v_v -> 'lon') is distinct from 'number' then
        raise exception 'Una esquina no tiene orden o posición. Volvé a marcar las esquinas.'
          using errcode = 'CZ008';
      end if;
      if (v_v ->> 'orden')::numeric <> trunc((v_v ->> 'orden')::numeric)
         or abs((v_v ->> 'orden')::numeric) > 1000000 then
        raise exception 'El orden de una esquina tiene que ser un número entero. Volvé a marcar las esquinas.'
          using errcode = 'CZ008';
      end if;
      -- Por numeric: un JSON 2.0 llega como el texto «2.0», que ::integer no acepta.
      v_orden := (v_v ->> 'orden')::numeric::integer;
      if v_orden = any (v_ordenes) then
        raise exception 'La esquina % está repetida: cada esquina lleva un orden distinto. Volvé a marcar las esquinas.', v_orden
          using errcode = 'CZ008';
      end if;
      if abs((v_v ->> 'lat')::numeric) > 90 or abs((v_v ->> 'lon')::numeric) > 180 then
        raise exception 'La esquina % está fuera del mapa. Volvé a marcarla.', v_orden
          using errcode = 'CZ008';
      end if;
      v_ordenes := v_ordenes || v_orden;
    end loop;

    -- De acá en adelante el orden va como entero: lo leen los casts de abajo.
    select jsonb_agg(e || jsonb_build_object('orden', (e ->> 'orden')::numeric::integer) order by i)
      into v_vertices
      from jsonb_array_elements(v_vertices) with ordinality x(e, i);

    -- Al menos 3 lugares distintos: una esquina a 1 m o menos de otra de orden menor cuenta
    -- como la misma (la tolerancia con la que se valida el borde, más abajo).
    select count(*) into v_orden
      from jsonb_array_elements(v_vertices) a
     where not exists (
             select 1 from jsonb_array_elements(v_vertices) b
              where (b ->> 'orden')::integer < (a ->> 'orden')::integer
                and extensions.st_dwithin(
                      extensions.geography(extensions.st_setsrid(extensions.st_makepoint(
                        (a ->> 'lon')::double precision, (a ->> 'lat')::double precision), 4326)),
                      extensions.geography(extensions.st_setsrid(extensions.st_makepoint(
                        (b ->> 'lon')::double precision, (b ->> 'lat')::double precision), 4326)),
                      1.0::double precision));
    if v_orden < 3 then
      raise exception 'Una zona por esquinas necesita al menos 3 esquinas en lugares distintos y hay % (dos esquinas a 1 m o menos cuentan como una). Marcá las esquinas que faltan en el mapa.',
          v_orden
        using errcode = 'CZ008';
    end if;

    if p_poligono_geojson is null then
      raise exception 'Falta el borde de la zona, que sigue las calles entre las esquinas. Volvé a cerrar la forma.'
        using errcode = 'CZ008';
    end if;
    v_problema := public.zona_problema_de_forma(p_poligono_geojson);
    if v_problema is not null then
      raise exception 'El borde de la zona no sirve: %. Volvé a cerrar la forma.', v_problema
        using errcode = 'CZ008';
    end if;

    -- El borde tiene que pasar por cada esquina (1 m de tolerancia).
    select min((e ->> 'orden')::integer) into v_orden
      from jsonb_array_elements(v_vertices) e
     where not extensions.st_dwithin(
             extensions.geography(extensions.st_exteriorring(public.zona_geometria(p_poligono_geojson))),
             extensions.geography(extensions.st_setsrid(
               extensions.st_makepoint((e ->> 'lon')::double precision, (e ->> 'lat')::double precision), 4326)),
             1.0::double precision);
    if v_orden is not null then
      raise exception 'El borde no pasa por la esquina %. Volvé a cerrar la forma para que el borde siga las esquinas.', v_orden
        using errcode = 'CZ008';
    end if;
    v_poligono := p_poligono_geojson;

  else
    raise exception 'La forma de la zona tiene que ser RADIAL o ESQUINAS. Elegí «Radial» o «Por esquinas».'
      using errcode = 'CZ008';
  end if;

  select coalesce(jsonb_agg(jsonb_build_object('zona_id', s.zona_id, 'nombre', s.nombre,
                                               'interseccion', s.interseccion)
                            order by s.nombre, s.zona_id), '[]'::jsonb)
    into v_sup
    from public.zona_superposiciones(v_cc.id, v_poligono, p_zona_id) s;

  v_incluidas := public.zona_ubicaciones_incluidas(v_cc.id, v_poligono);

  if p_vista_previa then
    return jsonb_build_object('guardada', false, 'zona', null, 'vertices', null,
                              'poligono_geojson', v_poligono, 'superposiciones', v_sup,
                              'ubicaciones_incluidas', v_incluidas);
  end if;

  perform public.lanzar_superposicion(v_sup);

  if p_zona_id is null then
    insert into public.zona (nombre, campania_ciudad_id, tipo_forma, centro_lat, centro_lon,
                             radio_m, poligono_geojson, color, created_by)
    values (v_nombre, v_cc.id, p_tipo_forma, p_centro_lat, p_centro_lon,
            p_radio_m, v_poligono, p_color, auth.uid())
    returning * into v_zona;
  else
    -- Sin cambios no se toca la fila (no sube sync_version).
    update public.zona z
       set nombre = v_nombre, tipo_forma = p_tipo_forma, centro_lat = p_centro_lat,
           centro_lon = p_centro_lon, radio_m = p_radio_m, poligono_geojson = v_poligono,
           color = p_color
     where z.id = p_zona_id
       and (z.nombre, z.tipo_forma, z.centro_lat, z.centro_lon, z.radio_m, z.poligono_geojson, z.color)
           is distinct from
           (v_nombre, p_tipo_forma, p_centro_lat, p_centro_lon, p_radio_m, v_poligono, p_color)
    returning * into v_zona;
    if not found then
      select * into v_zona from public.zona z where z.id = p_zona_id;
    end if;
  end if;

  -- Vértices: se conserva el id de cada orden que sigue; los que se van quedan como baja.
  update public.zona_vertice v
     set deleted_at = now()
   where v.zona_id = v_zona.id and v.deleted_at is null
     and not (v.orden = any (v_ordenes));

  for v_v in select e from jsonb_array_elements(case when p_tipo_forma = 'ESQUINAS'
                                                     then v_vertices else '[]'::jsonb end) e loop
    update public.zona_vertice v
       set lat = (v_v ->> 'lat')::double precision, lon = (v_v ->> 'lon')::double precision,
           calle_a = v_v ->> 'calle_a', calle_b = v_v ->> 'calle_b'
     where v.zona_id = v_zona.id and v.orden = (v_v ->> 'orden')::integer and v.deleted_at is null
       and (v.lat, v.lon, v.calle_a, v.calle_b) is distinct from
           ((v_v ->> 'lat')::double precision, (v_v ->> 'lon')::double precision,
            v_v ->> 'calle_a', v_v ->> 'calle_b');
    if not exists (select 1 from public.zona_vertice v
                    where v.zona_id = v_zona.id and v.orden = (v_v ->> 'orden')::integer
                      and v.deleted_at is null) then
      insert into public.zona_vertice (zona_id, orden, lat, lon, calle_a, calle_b, created_by)
      values (v_zona.id, (v_v ->> 'orden')::integer, (v_v ->> 'lat')::double precision,
              (v_v ->> 'lon')::double precision, v_v ->> 'calle_a', v_v ->> 'calle_b', auth.uid());
    end if;
  end loop;

  return jsonb_build_object(
    'guardada', true,
    'zona', to_jsonb(v_zona) - 'xmin_w',
    'vertices', (select coalesce(jsonb_agg(to_jsonb(v) - 'xmin_w' order by v.orden), '[]'::jsonb)
                   from public.zona_vertice v
                  where v.zona_id = v_zona.id and v.deleted_at is null),
    'poligono_geojson', v_zona.poligono_geojson,
    'superposiciones', '[]'::jsonb,
    'ubicaciones_incluidas', v_incluidas);
end;
$$;

comment on function public.guardar_zona(uuid, text, text, text, double precision, double precision,
                                        integer, jsonb, jsonb, uuid, boolean) is
  'Vista 24: crea o edita una zona y sus vértices; con p_vista_previa solo devuelve polígono, '
  'superposiciones y cuántas ubicaciones incluye («Incluye N ubicaciones»). Errores: 42501; CZ001, '
  'CZ004, CZ007 (DETAIL con la intersección), CZ008, CZ009, CZ011, CZ012.';

-- Misma firma y mismo comportamiento que en 0009, salvo el conteo: ubicaciones_incluidas son las
-- ubicaciones vivas dentro de la zona que se da de baja. Ninguna cambia: no guardan zona.
create or replace function public.baja_zona(p_zona_id uuid, p_vista_previa boolean default false)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_zona       public.zona;
  v_cc         public.campania_ciudad;
  v_asignados  jsonb;
  v_nombres    text;
  v_incluidas  integer;
begin
  if auth.uid() is null then
    raise exception 'baja_zona requiere un usuario autenticado'
      using errcode = 'insufficient_privilege';
  end if;

  if not (public.tiene_rol('ADMIN') or public.tiene_rol('COORDINADOR')) then
    perform public.lanzar_motivo_mapa('SIN_PERMISO');
  end if;

  select * into v_zona from public.zona z where z.id = p_zona_id;
  if not found then
    perform public.lanzar_motivo_mapa('ZONA_INEXISTENTE');
  end if;
  select * into v_cc from public.campania_ciudad cc where cc.id = v_zona.campania_ciudad_id;
  perform public.lanzar_motivo_mapa(public.motivo_mapa_de_campania(v_cc.campania_id));

  perform public.bloquear_mapa(v_cc.id);
  select * into v_zona from public.zona z where z.id = p_zona_id for update;
  if v_zona.deleted_at is not null then
    perform public.lanzar_motivo_mapa('ZONA_INEXISTENTE');
  end if;

  -- Asignados: las inscripciones vivas con esta zona (la única fuente desde 0009).
  select jsonb_agg(jsonb_build_object('usuario_id', u.id, 'nombre', u.nombre, 'apellido', u.apellido)
                   order by u.apellido, u.nombre, u.id),
         string_agg(coalesce(nullif(btrim(concat_ws(' ', u.nombre, u.apellido)), ''), 'un colportor sin nombre'),
                    ', ' order by u.apellido, u.nombre, u.id)
    into v_asignados, v_nombres
    from public.usuario u
   where u.deleted_at is null
     and exists (select 1 from public.campania_colportor ins
                  where ins.usuario_id = u.id and ins.zona_id = p_zona_id
                    and ins.deleted_at is null);

  v_incluidas := public.zona_ubicaciones_incluidas(v_cc.id, v_zona.poligono_geojson);

  if p_vista_previa then
    return jsonb_build_object('dada_de_baja', false, 'zona', to_jsonb(v_zona) - 'xmin_w',
                              'colportores_asignados', coalesce(v_asignados, '[]'::jsonb),
                              'ubicaciones_incluidas', v_incluidas);
  end if;

  if v_asignados is not null then
    raise exception 'La zona «%» tiene colportores asignados: %. Reasignalos a otra zona antes de darla de baja.',
        v_zona.nombre, v_nombres
      using errcode = 'CZ010',
            detail = jsonb_build_object('colportores_asignados', v_asignados)::text;
  end if;

  update public.zona z set deleted_at = now() where z.id = p_zona_id
  returning * into v_zona;
  update public.zona_vertice v set deleted_at = now()
   where v.zona_id = p_zona_id and v.deleted_at is null;

  return jsonb_build_object('dada_de_baja', true, 'zona', to_jsonb(v_zona) - 'xmin_w',
                            'colportores_asignados', '[]'::jsonb,
                            'ubicaciones_incluidas', v_incluidas);
end;
$$;

-- Reemplazada por zona_ubicaciones_incluidas(): ya no hay ubicaciones que cambien de zona.
drop function public.zona_ubicaciones_que_cambian(uuid, uuid, jsonb);

-- ----------------------------------------------------------------------------
-- 7. El pull con alcance
-- ----------------------------------------------------------------------------

-- Las ubicaciones de la parte «zona» del pull del usuario autenticado: las que registró él, más
-- las que caen dentro del polígono (ST_Covers, borde incluido) de alguna de sus zonas
-- (mis_zonas()) y son de la ciudad de esa zona. Con las bajas: su tombstone también baja.
-- SECURITY DEFINER, como mis_zonas(): con la RLS de por medio, ST_Covers no es LEAKPROOF y el
-- planificador no puede usar el índice GiST (recorre la ciudad entera, ~3 µs por casa). Como
-- dueño lo usa. No devuelve nada que la RLS no le muestre: su zona es de una de sus ciudades.
create function public.ubicaciones_de_mi_zona()
returns setof uuid
language sql
stable
security definer
set search_path = ''
as $$
  select u.id from public.ubicacion u where u.created_by = auth.uid()
  union
  select u.id
    from public.zona z
    join public.campania_ciudad cc on cc.id = z.campania_ciudad_id
    join public.ubicacion u
      on u.ciudad_id = cc.ciudad_id
     and extensions.st_covers(public.zona_geometria(z.poligono_geojson),
                              public.ubicacion_geometria(u.lat, u.lon))
   where z.id in (select public.mis_zonas());
$$;

comment on function public.ubicaciones_de_mi_zona() is
  'Ubicaciones (también las bajas) que registró el usuario autenticado o que caen en sus zonas: '
  'la parte «zona» del pull (HU-SYNC-011). Usa el índice GiST. La llama sync.pull().';

-- La huella del área del pull del usuario autenticado, y las ciudades de «ciudad»:
--   'zona'   md5 de sus zonas (mis_zonas()) con la ciudad y la forma de cada una. Cambia si le
--            asignan otra zona, se la redibujan o deja de tener una.
--   'ciudad' md5 de mis_ciudades_de_trabajo(), que también devuelve en ciudades.
-- SECURITY INVOKER: lee sus zonas con la RLS del mapa, que le muestra las de sus campañas.
-- Interna del pull.
create function sync.area_del_pull(p_alcance text, out ciudades uuid[], out huella text)
language plpgsql
stable
set search_path = ''
as $$
begin
  if p_alcance = 'ciudad' then
    select coalesce(array_agg(c.ciudad_id order by c.ciudad_id), array[]::uuid[]),
           md5('ciudad|' || coalesce(string_agg(c.ciudad_id::text, ',' order by c.ciudad_id), ''))
      into ciudades, huella
      from public.mis_ciudades_de_trabajo() c (ciudad_id);
  else
    ciudades := array[]::uuid[];
    select md5('zona|' || coalesce(string_agg(z.id::text || ':' || cc.ciudad_id::text || ':'
                                              || md5(z.poligono_geojson::text), ',' order by z.id), ''))
      into huella
      from public.zona z
      join public.campania_ciudad cc on cc.id = z.campania_ciudad_id
     where z.id in (select public.mis_zonas());
  end if;
end;
$$;

comment on function sync.area_del_pull(text) is
  'Huella del área del pull del usuario autenticado según el alcance (zona o ciudad), que va en el '
  'watermark de las entidades con columna_ubicacion, y las ciudades de «ciudad» (0011). Interna.';

-- Misma función que en 0002, con un parámetro más al final (los llamados de antes siguen
-- valiendo) y el alcance de las entidades con columna_ubicacion. El resto no cambia.
drop function sync.pull(text[], jsonb, integer, uuid);

create function sync.pull(
  p_entidades text[],
  p_watermark jsonb default '{}'::jsonb,
  p_limite    integer default 500,
  p_device    uuid default null,
  p_alcance   text default 'zona'
)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_entidad   text;
  v_tabla     regclass;
  v_pk_col    text;
  v_col_ubic  text;
  v_desde     jsonb;
  v_lote      jsonb;
  v_filas     jsonb;
  v_rows      jsonb := '{}'::jsonb;
  v_nuevo     jsonb := coalesce(p_watermark, '{}'::jsonb);
  v_hay_mas   boolean := false;
  v_ultima    jsonb;
  v_horizonte xid8;
  v_limite    integer;
  v_arranque  timestamptz := clock_timestamp();
  v_total     integer := 0;
  v_salida    jsonb;
  v_usuario   uuid := auth.uid();
  v_alcance   text := coalesce(p_alcance, 'zona');
  v_ciudades  uuid[];
  v_huella    text;
  v_filtro    text;
  v_marca     jsonb;
begin
  if v_usuario is null then
    raise exception 'sync.pull requiere un usuario autenticado'
      using errcode = 'insufficient_privilege';
  end if;

  -- S60 (qué baja si el colportor no eligió) está pendiente: sin alcance, 'zona', que es lo
  -- que bajaba hasta 0011.
  if v_alcance not in ('zona', 'ciudad') then
    raise exception 'El alcance del pull tiene que ser «zona» o «ciudad», y llegó «%». Actualizá la app.',
        v_alcance
      using errcode = 'invalid_parameter_value';
  end if;

  -- Un límite fuera de rango es un cliente roto o un abuso: se acota y se sigue (0002).
  v_limite := least(greatest(coalesce(p_limite, 500), 1), 1000);

  -- Una sola vez para todas las entidades: el corte es el mismo para todas (0002).
  v_horizonte := pg_snapshot_xmin(pg_current_snapshot());

  foreach v_entidad in array coalesce(p_entidades, array[]::text[]) loop
    select e.tabla, e.columna_pk, e.columna_ubicacion
      into v_tabla, v_pk_col, v_col_ubic
      from sync.entidad e where e.nombre = v_entidad;
    -- Una entidad que el servidor no conoce se ignora (0002).
    continue when v_tabla is null;

    -- Un watermark sin `xid` arranca de cero (0002).
    v_desde := coalesce(p_watermark -> v_entidad, '{}'::jsonb);
    v_filtro := '';
    v_marca := '{}'::jsonb;

    -- Alcance (0011): la fila baja si su ubicación la registró él o está en su área.
    if v_col_ubic is not null then
      if v_huella is null then
        select a.ciudades, a.huella
          into v_ciudades, v_huella
          from sync.area_del_pull(v_alcance) a;
      end if;

      -- Otra área que la del watermark (o un watermark sin huella): esta entidad baja completa.
      if (v_desde ->> 'area') is distinct from v_huella then
        v_desde := '{}'::jsonb;
      end if;
      v_marca := jsonb_build_object('area', v_huella);

      -- 'zona': el conjunto sale una vez por consulta, del índice GiST (ubicaciones_de_mi_zona()).
      -- 'ciudad': por fila, contra la ubicación (su PK).
      v_filtro := case v_alcance
        when 'ciudad' then format(
          'and exists (select 1 from public.ubicacion u where u.id = t.%I'
          ' and (u.created_by = $4 or u.ciudad_id = any ($5)))', v_col_ubic)
        else format('and t.%I in (select public.ubicaciones_de_mi_zona())', v_col_ubic)
      end;
    end if;

    -- Una fila de más para saber si hay más; el xmin_w viaja al lado de la fila (0002).
    execute format($q$
      select coalesce(jsonb_agg(jsonb_build_object('j', j, 'xw', xw::text, 'id', id)
                                order by xw, id), '[]'::jsonb)
      from (
        select %s as j, t.xmin_w as xw, t.%I as id
        from %s t
        where t.xmin_w < $3
          and (t.xmin_w, t.%I) > ($1::xid8, $2::uuid)
          %s
        order by t.xmin_w, t.%I
        limit %s
      ) s
    $q$,
      sync.expresion_json(v_tabla), v_pk_col, v_tabla, v_pk_col, v_filtro, v_pk_col,
      (v_limite + 1)::text)
    into v_lote
    using coalesce(v_desde ->> 'xid', '0'),
          coalesce(v_desde ->> 'id', '00000000-0000-0000-0000-000000000000')::uuid,
          v_horizonte, v_usuario, v_ciudades;

    if jsonb_array_length(v_lote) = 0 then
      -- Con alcance, nada del área debajo del horizonte: todo lo de abajo ya se revisó, así que
      -- el cursor pasa al horizonte (lo que venga tiene un xmin_w mayor o igual) y la huella
      -- queda guardada. Sin esto, un área vacía se recorre entera en cada pull.
      if v_col_ubic is not null then
        v_nuevo := v_nuevo || jsonb_build_object(v_entidad,
          jsonb_build_object('xid', v_horizonte::text, 'id', '00000000-0000-0000-0000-000000000000')
          || v_marca);
      end if;
      continue;
    end if;

    if jsonb_array_length(v_lote) > v_limite then
      v_hay_mas := true;
      v_lote := (select jsonb_agg(e) from (
        select e from jsonb_array_elements(v_lote) e limit v_limite
      ) s);
    end if;

    v_filas := (select jsonb_agg(e -> 'j') from jsonb_array_elements(v_lote) e);

    -- Una entidad ausente de `rows` significa "sin cambios" (0002).
    v_rows := v_rows || jsonb_build_object(v_entidad, v_filas);
    v_total := v_total + jsonb_array_length(v_filas);

    v_ultima := v_lote -> (jsonb_array_length(v_lote) - 1);
    v_nuevo := v_nuevo || jsonb_build_object(v_entidad,
      jsonb_build_object('xid', v_ultima ->> 'xw', 'id', v_ultima ->> 'id') || v_marca);
  end loop;

  v_salida := jsonb_build_object(
    'server_time', to_char(now() at time zone 'utc', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"'),
    'watermark', v_nuevo,
    'has_more', v_hay_mas,
    'rows', v_rows
  );

  -- Un pull sin novedades no escribe nada: tomaría un xid y frenaría el horizonte de todos (0002).
  if v_total > 0 then
    insert into sync.log (device_id, operacion, duracion_ms, entidades, filas, hay_mas, bytes_salida)
    values (p_device, 'pull',
            extract(epoch from clock_timestamp() - v_arranque) * 1000,
            p_entidades, v_total, v_hay_mas, octet_length(v_salida::text));
  end if;

  return v_salida;
end;
$$;

comment on function sync.pull(text[], jsonb, integer, uuid, text) is
  'Delta por (xmin_w, id) con la RLS del que llama (0002). p_alcance (0011, HU-SYNC-011): '
  '''zona'' (default) o ''ciudad''; ubicacion, espacio y house_status bajan según ese alcance, y '
  'bajan completas si cambió el área (huella en el watermark).';

-- ----------------------------------------------------------------------------
-- 8. Privilegios
-- ----------------------------------------------------------------------------

-- `authenticated` también: en una base creada desde cero los default privileges de la imagen le
-- dan EXECUTE sobre cada función nueva de public (ver 0008).
revoke all on function
  public.mis_ciudades_de_trabajo(),
  public.ubicaciones_de_mi_zona(),
  public.tg_ubicacion_posicion_a_dependientes(),
  public.tg_house_status_posicion_de_su_ubicacion(),
  public.zona_ubicaciones_incluidas(uuid, jsonb)
  from public, anon, authenticated;
revoke all on function
  sync.area_del_pull(text),
  sync.pull(text[], jsonb, integer, uuid, text)
  from public, anon;

-- La usan las políticas y el pull, que corren como quien llama. Solo miran al usuario
-- autenticado.
grant execute on function
  public.mis_ciudades_de_trabajo(),
  public.ubicaciones_de_mi_zona()
  to authenticated, service_role;

-- Interna: la llaman guardar_zona() y baja_zona(), que corren como su dueño.
grant execute on function public.zona_ubicaciones_incluidas(uuid, jsonb) to service_role;

-- El pull es SECURITY INVOKER: quien lo llama necesita también su interna (como en 0002).
grant execute on function
  sync.pull(text[], jsonb, integer, uuid, text),
  sync.area_del_pull(text)
  to authenticated, service_role;
