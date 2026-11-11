-- ============================================================================
-- Datos de DEMO simulados: una campaña de verano en curso (Montevideo, Maldonado y Salto) y una de invierno ya
-- terminada, con catálogo, precios, colportores, casas visitadas, ventas, cobros, deudas, depósitos, pedidos y stock.
--
-- NO es una migración ni el seed de ejemplo (supabase/seed.sql): es un generador que se corre a mano contra el
-- proyecto de DEMO (ohdsavwpasfpapbyutrv) o contra una base local, con scripts/db-seed-demo.sh. Staging y producción
-- no lo reciben. Todo es FICTICIO: nombres, correos @example.com, direcciones con números inventados, montos.
-- Qué NO hay, a propósito: personas con nombre, teléfono o notas (`persona` es local-only, ADR-018: en la nube solo
-- viven los ids de `espacio_persona`); ni un solo dato real.
--
-- Cómo funciona
--   · Un solo DO: o carga todo o no carga nada. No usa DELETE, TRUNCATE ni toca el esquema: solo INSERT.
--   · Todas las filas que crea llevan un id determinístico con el prefijo 5eed0000-0000-7000-8… (ver pg_temp.did).
--     Eso las distingue de todo lo demás y es lo que usa supabase/seed-demo/retirar-demo-datos.sql para retirarlas.
--     Los usuarios son @example.com con el correo demo.<nombre>.<apellido>@example.com.
--   · Idempotente: si la campaña de verano de la demo (id fijo) ya existe, avisa y no hace nada. Cada INSERT lleva
--     además `on conflict do nothing`, así que un reintento tras un corte nunca duplica.
--   · La historia está anclada en fechas absolutas (hoy = 04/11/2026): el verano empezó el 14/09, el invierno terminó
--     el 28/08. Los números salen de una función hash (pg_temp.rnd), no de random(): dos corridas dan lo mismo.
--   · La plata va en centavos de peso uruguayo (como el resto del esquema).
--   · Las cifras de `cuenta_colportor` se calculan de las mismas filas (pedidos, depósitos validados, tickets de
--     tarjeta validados, cobros y saldos), así que cierran con lo que muestran el panel y la app.
--   · Los colportores NO tienen contraseña (no se puede entrar con ellos) salvo que scripts/db-seed-demo.sh (solo
--     en local) la reciba por la variable DEMO_PASSWORD; la contraseña nunca se escribe acá. En el proyecto de demo
--     se les pone desde Supabase Studio (ver supabase/seed-demo/README.md).
--
-- Las migraciones tienen que estar aplicadas (la última que usa es la 0169).
-- ============================================================================

do $seed$
declare
  v_corte   constant timestamptz := timestamptz '2026-11-03 23:59:00+00';
  v_hoy     constant date := date '2026-11-04';
  v_pais    uuid;
  v_coord   uuid;
  v_n       bigint;
  r         record;
  v_run     bigint;
  v_dep_cum bigint;
  v_need    bigint;
  v_monto   bigint;
  v_fecha   timestamptz;
begin
  -- --------------------------------------------------------------------------------------------------
  -- 0. Funciones de ayuda (viven solo en esta sesión) y guarda de idempotencia
  -- --------------------------------------------------------------------------------------------------
  create or replace function pg_temp.did(p_tabla int, p_n bigint) returns uuid
    language sql immutable as $f$
      select ('5eed0000-0000-7000-8' || lpad(to_hex(p_tabla), 3, '0') || '-' || lpad(to_hex(p_n), 12, '0'))::uuid
    $f$;
  create or replace function pg_temp.rnd(p_clave text) returns double precision
    language sql immutable as $f$
      select (('x' || substr(md5(p_clave), 1, 7))::bit(28)::int)::double precision / 268435456.0
    $f$;

  -- Dos cargas a la vez no deben pasar juntas la guarda (los movimientos de stock no tienen id fijo): la segunda espera
  -- a que la primera termine y entonces ve la campaña.
  perform pg_advisory_xact_lock(hashtext('colportores.seed-demo'));

  if exists (select 1 from public.campania c where c.id = pg_temp.did(3, 1)) then
    raise notice 'La demo de datos ya está cargada (campaña %). No se cambió nada.', pg_temp.did(3, 1);
    return;
  end if;
  if not exists (select 1 from public.rol where codigo = 'COLPORTOR') or not exists (select 1 from public.rol where codigo = 'COORDINADOR') then
    raise exception 'Faltan los roles COLPORTOR/COORDINADOR: aplicá las migraciones antes de cargar la demo.';
  end if;

  v_coord := pg_temp.did(0, 0);

  -- --------------------------------------------------------------------------------------------------
  -- 1. Geografía: Uruguay y tres ciudades (las del catálogo si ya están; si no, se crean con id de la demo)
  -- --------------------------------------------------------------------------------------------------
  select p.id into v_pais from public.pais p where p.iso_code = 'UY' and p.deleted_at is null order by p.created_at limit 1;
  if v_pais is null then
    v_pais := pg_temp.did(1, 1);
    insert into public.pais (id, nombre, iso_code) values (v_pais, 'Uruguay', 'UY') on conflict do nothing;
  end if;

  create temp table t_ciu (idx int primary key, id uuid, nombre text, depto text, lat double precision, lon double precision) on commit drop;
  insert into t_ciu (idx, id, nombre, depto, lat, lon)
  select v.idx, coalesce(
           (select c.id from public.ciudad c where c.pais_id = v_pais and c.nombre = v.nombre and c.departamento = v.depto
               and c.deleted_at is null order by c.created_at limit 1),
           pg_temp.did(2, v.idx)), v.nombre, v.depto, v.lat, v.lon
    from (values (1, 'Montevideo', 'Montevideo', -34.9011, -56.1645),
                 (2, 'Maldonado',  'Maldonado',  -34.9087, -54.9583),
                 (3, 'Salto',      'Salto',      -31.3889, -57.9609)) v(idx, nombre, depto, lat, lon);
  insert into public.ciudad (id, nombre, departamento, pais_id, lat_centro, lon_centro, zoom_inicial)
  select t.id, t.nombre, t.depto, v_pais, t.lat, t.lon, 13 from t_ciu t
   where not exists (select 1 from public.ciudad c where c.id = t.id)
  on conflict do nothing;

  -- --------------------------------------------------------------------------------------------------
  -- 2. Personas del sistema: un coordinador y diez colportores (con su Auth, sin contraseña)
  -- --------------------------------------------------------------------------------------------------
  create temp table t_usr (idx int primary key, id uuid, nombre text, apellido text, rol text, email text) on commit drop;
  insert into t_usr (idx, id, nombre, apellido, rol, email)
  select v.idx, pg_temp.did(0, v.idx), v.nombre, v.apellido, v.rol,
         'demo.' || lower(v.nombre) || '.' || lower(v.apellido) || '@example.com'
    from (values (0, 'Gustavo',   'Ferreira', 'COORDINADOR'),
                 (1, 'Martin',    'Techera',  'COLPORTOR'),
                 (2, 'Lucia',     'Pereyra',  'COLPORTOR'),
                 (3, 'Santiago',  'Olivera',  'COLPORTOR'),
                 (4, 'Camila',    'Sosa',     'COLPORTOR'),
                 (5, 'Joaquin',   'Barrios',  'COLPORTOR'),
                 (6, 'Valentina', 'Acosta',   'COLPORTOR'),
                 (7, 'Nicolas',   'Duarte',   'COLPORTOR'),
                 (8, 'Agustina',  'Cabrera',  'COLPORTOR'),
                 (9, 'Federico',  'Silveira', 'COLPORTOR'),
                 (10, 'Rocio',    'Machado',  'COLPORTOR')) v(idx, nombre, apellido, rol);

  insert into auth.users (instance_id, id, aud, role, email, encrypted_password, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
  select '00000000-0000-0000-0000-000000000000'::uuid, u.id, 'authenticated', 'authenticated', u.email, null,
         '{"provider":"email","providers":["email"]}'::jsonb,
         jsonb_build_object('nombre', u.nombre, 'apellido', u.apellido, 'demo', true),
         timestamptz '2026-09-01 12:00:00+00', timestamptz '2026-09-01 12:00:00+00'
    from t_usr u
  on conflict do nothing;
  -- Columnas de Auth que no existen en la base local de pruebas: solo si están.
  if exists (select 1 from information_schema.columns where table_schema = 'auth' and table_name = 'users' and column_name = 'email_confirmed_at') then
    update auth.users set email_confirmed_at = coalesce(email_confirmed_at, created_at)
     where id in (select id from t_usr);
  end if;
  for r in select c.column_name from information_schema.columns c
            where c.table_schema = 'auth' and c.table_name = 'users'
              and c.column_name in ('confirmation_token', 'recovery_token', 'email_change_token_new', 'email_change',
                                    'email_change_token_current', 'phone_change', 'phone_change_token', 'reauthentication_token')
  loop
    execute format('update auth.users set %1$I = '''' where %1$I is null and id in (select id from pg_temp.t_usr)', r.column_name);
  end loop;

  -- El disparador de Auth crea `usuario`; si no corrió (usuario ya existente) se completa.
  insert into public.usuario (id, email, nombre, apellido, created_by)
  select u.id, u.email, u.nombre, u.apellido, u.id from t_usr u on conflict (id) do nothing;

  insert into public.usuario_rol (id, usuario_id, rol_id)
  select pg_temp.did(31, u.idx), u.id, (select r2.id from public.rol r2 where r2.codigo = u.rol) from t_usr u
  on conflict do nothing;

  -- --------------------------------------------------------------------------------------------------
  -- 3. Carreras y metas de beca (las del verano)
  -- --------------------------------------------------------------------------------------------------
  insert into public.carrera (id, nombre) values
    (pg_temp.did(30, 1), 'Licenciatura en Nutrición'),
    (pg_temp.did(30, 2), 'Ingeniería Industrial'),
    (pg_temp.did(30, 3), 'Profesorado de Inglés')
  on conflict do nothing;
  insert into public.meta_beca (id, carrera_id, tipo_campania, meta_media, meta_completa, meta_media_monto, meta_completa_monto) values
    (pg_temp.did(32, 1), pg_temp.did(30, 1), 'VERANO', 30, 60, 2000000, 4000000),
    (pg_temp.did(32, 2), pg_temp.did(30, 2), 'VERANO', 40, 80, 2500000, 5000000),
    (pg_temp.did(32, 3), pg_temp.did(30, 3), 'VERANO', 25, 50, 1500000, 3000000)
  on conflict do nothing;
  update public.usuario u set carrera_id = pg_temp.did(30, v.carrera), carrera_elegida_en = timestamptz '2026-09-10 15:00:00+00'
    from (values (2, 1), (3, 2), (4, 3), (6, 1), (7, 2), (9, 3)) v(usr, carrera)
   where u.id = pg_temp.did(0, v.usr) and u.carrera_id is null;

  -- --------------------------------------------------------------------------------------------------
  -- 4. Catálogo (dos casas editoras ficticias), colecciones y precios
  -- --------------------------------------------------------------------------------------------------
  create temp table t_prod (code int primary key, id uuid, nombre text, descripcion text, categoria text, tipo text,
                            bonif boolean, venta int, compra int, casa text, peso int) on commit drop;
  insert into t_prod (code, id, nombre, descripcion, categoria, tipo, bonif, venta, compra, casa, peso)
  select v.code, pg_temp.did(5, v.code), v.nombre, v.descripcion, v.categoria, v.tipo, v.bonif, v.venta, v.compra, v.casa, v.peso
    from (values
      (1,  'Esperanza para Hoy',                   'Libro ilustrado de tapa dura',            'BONIFICABLES', 'LIBRO',    true,  145000, 72000, 'Casa Editora del Sur (demo)',   14),
      (2,  'El Gran Conflicto Ilustrado',          'Edición ilustrada, dos tomos',            'BONIFICABLES', 'LIBRO',    true,  168000, 84000, 'Casa Editora del Sur (demo)',   12),
      (3,  'Salud Integral para la Familia',       'Guía de salud del hogar',                 'BONIFICABLES', 'LIBRO',    true,   98000, 49000, 'Casa Editora del Sur (demo)',   16),
      (4,  'Cocina Saludable Paso a Paso',         'Recetario con fotografías',               'BONIFICABLES', 'LIBRO',    true,   89000, 44500, 'Ediciones Horizonte (demo)',    12),
      (5,  'Niños Felices: Historias Bíblicas',    'Libro infantil ilustrado',                'BONIFICABLES', 'LIBRO',    true,  112000, 56000, 'Ediciones Horizonte (demo)',    10),
      (6,  'El Camino a la Paz Interior',          'Libro de bolsillo',                       'BONIFICABLES', 'LIBRO',    true,   39000, 19500, 'Casa Editora del Sur (demo)',    8),
      (7,  'Revista Vida y Salud',                 'Revista mensual',                         'REVISTAS',     'REVISTA',  false,  18000,  8500, 'Ediciones Horizonte (demo)',     8),
      (8,  'Revista Hogar Feliz',                  'Revista mensual',                         'REVISTAS',     'REVISTA',  false,  16000,  7500, 'Ediciones Horizonte (demo)',     6),
      (9,  'Devocional Mañanas con Esperanza',     'Devocional diario',                       'ESPIRITUALES', 'LIBRO',    false,  52000, 26000, 'Casa Editora del Sur (demo)',     6),
      (10, 'Folleto Descubre la Biblia',           'Material de estudio bíblico',             'MATERIAL',     'MATERIAL', false,   9000,  4000, 'Casa Editora del Sur (demo)',     4)
    ) v(code, nombre, descripcion, categoria, tipo, bonif, venta, compra, casa, peso);

  insert into public.producto (id, nombre, descripcion, tipo, es_bonificable, es_misionero, precio_base_compra, casa_editora, codigo_editor, categoria)
  select t.id, t.nombre, t.descripcion, t.tipo, t.bonif, false, t.compra, t.casa, 'DEMO26-' || lpad(t.code::text, 3, '0'), t.categoria
    from t_prod t
  on conflict do nothing;
  insert into public.producto (id, nombre, descripcion, tipo, es_bonificable, es_misionero, precio_base_compra, casa_editora, codigo_editor, categoria)
  values (pg_temp.did(5, 11), 'Ejemplar misionero Un Mensaje de Esperanza', 'Se entrega sin costo al visitado', 'MISIONERO', false, true, null,
          'Ediciones Horizonte (demo)', 'DEMO26-011', 'MISIONEROS')
  on conflict do nothing;

  insert into public.coleccion (id, nombre, libros_a_elegir) values
    (pg_temp.did(6, 1), 'Combo Familia (Salud Integral + 2 revistas Vida y Salud)', 0),
    (pg_temp.did(6, 2), 'Colección de 2 libros a elegir', 2)
  on conflict do nothing;
  insert into public.producto_coleccion (id, producto_id, coleccion_id, cantidad) values
    (pg_temp.did(33, 1), pg_temp.did(5, 3), pg_temp.did(6, 1), 1),
    (pg_temp.did(33, 2), pg_temp.did(5, 7), pg_temp.did(6, 1), 2)
  on conflict do nothing;

  -- Precio general (todo el país). Los combos tienen su propio precio.
  insert into public.precio_general (id, producto_id, coleccion_id, precio_venta, valido_desde)
  select pg_temp.did(34, t.code), t.id, null::uuid, t.venta, date '2026-06-01' from t_prod t
  union all select pg_temp.did(34, 101), null, pg_temp.did(6, 1), 125000, date '2026-06-01'
  union all select pg_temp.did(34, 102), null, pg_temp.did(6, 2), 210000, date '2026-06-01'
  union all select pg_temp.did(34, 11), pg_temp.did(5, 11), null, 0, date '2026-06-01'
  on conflict do nothing;

  -- --------------------------------------------------------------------------------------------------
  -- 5. Campañas, ciudades de la campaña, precios por ciudad y zonas
  -- --------------------------------------------------------------------------------------------------
  create temp table t_camp (idx int primary key, id uuid, nombre text, tipo text, ini date, fin date, alq bigint, limite bigint) on commit drop;
  insert into t_camp values
    (1, pg_temp.did(3, 1), 'Campaña Verano 2026-27 (demo)',   'VERANO',   date '2026-09-14', date '2027-03-13', 300000, 4000000),
    (2, pg_temp.did(3, 2), 'Campaña Invierno 2026 (demo)',    'INVIERNO', date '2026-07-13', date '2026-08-28', 250000, null);
  insert into public.campania (id, nombre, tipo, fecha_inicio, fecha_fin, coordinador_id, alquiler_monto, limite_deuda)
  select c.id, c.nombre, c.tipo, c.ini, c.fin, v_coord, c.alq, c.limite from t_camp c on conflict do nothing;

  create temp table t_cc (idx int primary key, id uuid, camp int, ciu int) on commit drop;
  insert into t_cc values (1, pg_temp.did(9, 1), 1, 1), (2, pg_temp.did(9, 2), 1, 2), (3, pg_temp.did(9, 3), 1, 3), (4, pg_temp.did(9, 4), 2, 1);
  insert into public.campania_ciudad (id, campania_id, ciudad_id)
  select cc.id, (select id from t_camp where idx = cc.camp), (select id from t_ciu where idx = cc.ciu) from t_cc cc on conflict do nothing;

  -- Precios de la ciudad: Maldonado (temporada) un 10 % más caro; Salto un 5 % más barato en los libros grandes.
  insert into public.precio_por_ciudad (id, producto_id, coleccion_id, precio_venta, valido_desde, campania_ciudad_id)
  select pg_temp.did(35, 1000 + t.code), t.id, null::uuid, (t.venta * 1.10 / 1000)::int * 1000, date '2026-09-14', (select id from t_cc where idx = 2)
    from t_prod t where t.code in (1, 2, 3, 5)
  union all
  select pg_temp.did(35, 2000 + t.code), t.id, null::uuid, (t.venta * 0.95 / 1000)::int * 1000, date '2026-09-14', (select id from t_cc where idx = 3)
    from t_prod t where t.code in (1, 2)
  union all
  select pg_temp.did(35, 1101), null, pg_temp.did(6, 1), 139000, date '2026-09-14', (select id from t_cc where idx = 2)
  on conflict do nothing;

  create temp table t_zona (idx int primary key, id uuid, cc int, nombre text, lat double precision, lon double precision, radio int, color text) on commit drop;
  insert into t_zona (idx, id, cc, nombre, lat, lon, radio, color)
  select v.idx, pg_temp.did(4, v.idx), v.cc, v.nombre, v.lat, v.lon, v.radio, v.color
    from (values
      (1,  1, 'Pocitos',            -34.9150, -56.1500,  900, '#3A7BD5'),
      (2,  1, 'Cordón',             -34.9040, -56.1760,  800, '#E07B39'),
      (3,  1, 'La Unión',           -34.8870, -56.1450, 1000, '#3AA675'),
      (4,  1, 'Prado',              -34.8680, -56.1900, 1000, '#8E5BD0'),
      (5,  2, 'Maldonado Centro',   -34.9090, -54.9580,  700, '#3A7BD5'),
      (6,  2, 'Punta del Este',     -34.9650, -54.9500,  800, '#E07B39'),
      (7,  3, 'Salto Centro',       -31.3889, -57.9609,  800, '#3AA675'),
      (8,  3, 'Salto Norte',        -31.3600, -57.9650,  900, '#8E5BD0'),
      (9,  4, 'Pocitos',            -34.9150, -56.1500,  900, '#3A7BD5'),
      (10, 4, 'Cordón',             -34.9040, -56.1760,  800, '#E07B39')
    ) v(idx, cc, nombre, lat, lon, radio, color);
  insert into public.zona (id, nombre, poligono_geojson, campania_ciudad_id, tipo_forma, centro_lat, centro_lon, radio_m, color)
  select z.id, z.nombre, '{}'::jsonb, (select id from t_cc where idx = z.cc), 'RADIAL', z.lat, z.lon, z.radio, z.color from t_zona z
  on conflict do nothing;

  -- --------------------------------------------------------------------------------------------------
  -- 6. Inscripciones: quién trabaja dónde, desde cuándo y con qué ritmo (hab = habilidad: el mejor 1,3, la más floja 0,35)
  -- --------------------------------------------------------------------------------------------------
  create temp table t_ins (no int primary key, camp int, usr int, zona int, d0 date, d1 date, hab double precision,
                           tipo_beca text, cierre boolean) on commit drop;
  insert into t_ins values
    (1,  1, 1,  1, date '2026-09-14', date '2026-11-03', 1.30, null,       false),
    (2,  1, 2,  2, date '2026-09-14', date '2026-11-03', 1.10, 'COMPLETA', false),
    (3,  1, 3,  3, date '2026-09-14', date '2026-11-03', 0.85, 'MEDIA',    false),
    (4,  1, 4,  4, date '2026-09-14', date '2026-11-03', 0.60, 'MEDIA',    false),
    (5,  1, 5,  3, date '2026-09-28', date '2026-11-03', 0.35, null,       false),
    (6,  1, 6,  5, date '2026-09-14', date '2026-11-03', 1.00, 'MEDIA',    false),
    (7,  1, 7,  6, date '2026-09-14', date '2026-11-03', 0.70, 'COMPLETA', false),
    (8,  1, 8,  5, date '2026-09-21', date '2026-11-03', 0.45, null,       false),
    (9,  1, 9,  7, date '2026-09-14', date '2026-11-03', 0.90, 'COMPLETA', false),
    (10, 1, 10, 8, date '2026-10-05', date '2026-11-03', 0.50, null,       false),
    (11, 2, 1,  9, date '2026-07-13', date '2026-08-28', 1.20, null,       true),
    (12, 2, 2, 10, date '2026-07-13', date '2026-08-28', 1.00, null,       true),
    (13, 2, 3,  9, date '2026-07-20', date '2026-08-28', 0.80, null,       true);
  -- La fecha de alta es el primer día de la inscripción (d0, 00:00 de Montevideo), no la de la carga: Inicio y Reportes
  -- (tablero_de_inicio, horas_/ventas_por_ciudad_y_colportor, 0106) solo cuentan lo que pasó con la inscripción vigente.
  insert into public.campania_colportor (id, campania_id, usuario_id, zona_id, tipo_beca, created_at)
  select pg_temp.did(11, i.no), (select id from t_camp where idx = i.camp), pg_temp.did(0, i.usr), pg_temp.did(4, i.zona), i.tipo_beca,
         i.d0::timestamp at time zone 'America/Montevideo'
    from t_ins i
  on conflict do nothing;
  -- El trigger del historial (0022) abre el primer tramo de zona con la hora de la carga: empieza el mismo día que la
  -- inscripción, así la ciudad de cada jornada y venta sale de su zona.
  update public.campania_colportor_zona_historial h
     set desde = i.d0::timestamp at time zone 'America/Montevideo'
    from t_ins i
   where h.campania_colportor_id = pg_temp.did(11, i.no)
     and h.deleted_at is null
     and h.desde > i.d0::timestamp at time zone 'America/Montevideo'
     and not exists (select 1 from public.campania_colportor_zona_historial h2
                      where h2.campania_colportor_id = h.campania_colportor_id and h2.desde < h.desde);
  -- La meta de cada beca sale de la meta de su carrera (la misma regla de asignar_beca).
  update public.campania_colportor cc
     set meta_libros    = case cc.tipo_beca when 'MEDIA' then mb.meta_media else mb.meta_completa end,
         meta_monto_ces = case cc.tipo_beca when 'MEDIA' then mb.meta_media_monto else mb.meta_completa_monto end
    from public.usuario u join public.meta_beca mb on mb.carrera_id = u.carrera_id and mb.tipo_campania = 'VERANO' and mb.deleted_at is null
   where cc.id::text like '5eed0000-0000-7000-8%' and cc.tipo_beca is not null and cc.meta_libros is null and u.id = cc.usuario_id;

  -- --------------------------------------------------------------------------------------------------
  -- 7. Casas: ubicaciones, espacios (y su ciudad) por zona
  -- --------------------------------------------------------------------------------------------------
  create temp table t_ubi (no bigint primary key, zona int, j int, id uuid, tipo text, calle text, numero text, lat double precision, lon double precision, nesp int) on commit drop;
  insert into t_ubi (no, zona, j, id, tipo, calle, numero, lat, lon, nesp)
  select z.idx * 100 + g.j, z.idx, g.j, pg_temp.did(12, z.idx * 100 + g.j),
         case when g.j % 9 = 0 then 'EDIFICIO' when g.j % 7 = 0 then 'NEGOCIO' else 'CASA' end,
         (array[
            case cc.ciu when 1 then 'Av. Brasil' when 2 then 'Av. Roosevelt' else 'Uruguay' end,
            case cc.ciu when 1 then 'Bulevar Artigas' when 2 then 'Calle Sarandí' else 'Artigas' end,
            case cc.ciu when 1 then 'Av. Italia' when 2 then 'Calle 25' else 'Larrañaga' end,
            case cc.ciu when 1 then 'Gonzalo Ramírez' when 2 then 'Av. Italia' else 'Brasil' end,
            case cc.ciu when 1 then 'Av. 8 de Octubre' when 2 then 'Calle Treinta y Tres' else 'Rivera' end,
            case cc.ciu when 1 then 'Rivera' when 2 then 'Calle Florida' else 'Sarandí' end
          ])[1 + g.j % 6],
         (g.j * 17 + z.idx * 7)::text,
         z.lat + (z.radio * 0.92 * sqrt(pg_temp.rnd('ur' || z.idx || '-' || g.j)) * cos(2 * pi() * pg_temp.rnd('ua' || z.idx || '-' || g.j))) / 111320.0,
         z.lon + (z.radio * 0.92 * sqrt(pg_temp.rnd('ur' || z.idx || '-' || g.j)) * sin(2 * pi() * pg_temp.rnd('ua' || z.idx || '-' || g.j)))
                 / (111320.0 * cos(radians(z.lat))),
         case when g.j % 9 = 0 then 3 else 1 end
    from t_zona z
    join t_cc cc on cc.idx = z.cc
    cross join lateral generate_series(1, case when z.idx >= 9 then 24 else 36 end) g(j);

  insert into public.ubicacion (id, tipo, calle, numero, lat, lon, ciudad_id)
  select u.id, u.tipo, u.calle, u.numero, u.lat, u.lon, (select ciu.id from t_ciu ciu where ciu.idx = cc.ciu)
    from t_ubi u join t_zona z on z.idx = u.zona join t_cc cc on cc.idx = z.cc
  on conflict do nothing;

  create temp table t_esp (no bigint primary key, ubi bigint, e int, id uuid) on commit drop;
  insert into t_esp (no, ubi, e, id)
  select u.no * 10 + e.e, u.no, e.e, pg_temp.did(13, u.no * 10 + e.e) from t_ubi u cross join lateral generate_series(1, u.nesp) e(e);
  insert into public.espacio (id, ubicacion_id, numero_depto, piso)
  select e.id, u.id, case when u.tipo = 'EDIFICIO' then (e.e * 100 + 1 + e.e)::text end, case when u.tipo = 'EDIFICIO' then e.e::text end
    from t_esp e join t_ubi u on u.no = e.ubi
  on conflict do nothing;

  -- --------------------------------------------------------------------------------------------------
  -- 8. Jornadas y visitas (el ritmo de cada colportor)
  -- --------------------------------------------------------------------------------------------------
  create temp table t_jor (id uuid primary key, ins int, usr int, dia date, dn int, inicio timestamptz, fin timestamptz, nvis int) on commit drop;
  insert into t_jor (id, ins, usr, dia, dn, inicio, fin, nvis)
  select pg_temp.did(15, i.no * 1000000 + (d.dia - i.d0) + 1), i.no, i.usr, d.dia, (d.dia - i.d0) + 1,
         (d.dia::timestamp + interval '12 hours 30 minutes' + (floor(pg_temp.rnd('ji' || i.no || d.dia) * 90) || ' minutes')::interval) at time zone 'UTC',
         (d.dia::timestamp + interval '12 hours 30 minutes' + (floor(pg_temp.rnd('ji' || i.no || d.dia) * 90) || ' minutes')::interval
            + ((190 + floor(pg_temp.rnd('jf' || i.no || d.dia) * 110)) || ' minutes')::interval) at time zone 'UTC',
         4 + floor(pg_temp.rnd('jn' || i.no || d.dia) * 5)::int
    from t_ins i
    cross join lateral generate_series(0, i.d1 - i.d0) g(n)
    cross join lateral (select i.d0 + g.n as dia) d
   where extract(dow from d.dia) <> 0
     and pg_temp.rnd('jw' || i.no || d.dia) < 0.36 + 0.30 * i.hab / 1.30;

  create temp table t_vis (id uuid primary key, ins int, usr int, jor uuid, fecha timestamptz, esp bigint, ubi bigint, res text, zona int) on commit drop;
  insert into t_vis (id, ins, usr, jor, fecha, esp, ubi, res, zona)
  select pg_temp.did(14, j.ins * 1000000 + j.dn * 100 + k.k), j.ins, j.usr, j.id,
         j.inicio + ((k.k - 1) * 30 || ' minutes')::interval + (floor(pg_temp.rnd('vm' || j.id || k.k) * 8) || ' minutes')::interval,
         u.no * 10 + case when u.nesp > 1 then 1 + floor(pg_temp.rnd('ve' || j.id || k.k) * u.nesp)::int else 1 end,
         u.no,
         case when pg_temp.rnd('vr' || j.id || k.k) < 0.17 * i.hab then 'VENTA'
              when pg_temp.rnd('vr' || j.id || k.k) < 0.17 * i.hab + 0.10 then 'ENTREVISTA'
              when pg_temp.rnd('vr' || j.id || k.k) < 0.17 * i.hab + 0.10 + 0.13 then 'RECHAZO'
              else 'NO_CONTESTO' end,
         i.zona
    from t_jor j
    join t_ins i on i.no = j.ins
    cross join lateral generate_series(1, j.nvis) k(k)
    join t_ubi u on u.zona = i.zona
     and u.j = 1 + floor(pg_temp.rnd('vu' || j.id || k.k) * (select count(*) from t_ubi x where x.zona = i.zona))::int;

  insert into public.espacio_persona (id, espacio_id, persona_id)
  select pg_temp.did(46, e.no), e.id, pg_temp.did(47, e.no)
    from t_esp e where e.no in (select esp from t_vis)
  on conflict do nothing;

  insert into public.jornada (id, colportor_id, inicio, fin, total_visitas, total_ventas)
  select j.id, pg_temp.did(0, j.usr), j.inicio, j.fin,
         (select count(*) from t_vis v where v.jor = j.id), (select count(*) from t_vis v where v.jor = j.id and v.res = 'VENTA')
    from t_jor j
  on conflict do nothing;

  insert into public.visita (id, espacio_persona_id, fecha, tipo_resultado, colportor_id, jornada_id, espacio_id, entrevista_entrada, entrevista_salida)
  select v.id, pg_temp.did(46, v.esp), v.fecha, v.res, pg_temp.did(0, v.usr), v.jor, e.id,
         case when v.res = 'ENTREVISTA' then v.fecha end,
         case when v.res = 'ENTREVISTA' then v.fecha + ((15 + floor(pg_temp.rnd('vs' || v.id) * 25)) || ' minutes')::interval end
    from t_vis v join t_esp e on e.no = v.esp
  on conflict do nothing;

  -- --------------------------------------------------------------------------------------------------
  -- 9. Ventas y sus renglones (precio de la ciudad si hay, si no el general)
  -- --------------------------------------------------------------------------------------------------
  create temp table t_w (code int primary key, kind text, w int, lo int, hi int) on commit drop;
  insert into t_w (code, kind, w, lo, hi)
  select q.code, q.kind, q.w, sum(q.w) over (order by q.ord) - q.w, sum(q.w) over (order by q.ord)
    from (select code, 'P'::text kind, peso w, code ord from t_prod
          union all select 101, 'C', 6, 101 union all select 102, 'C', 4, 102) q;

  create temp table t_vta (id uuid primary key, ins int, usr int, vis uuid, fecha timestamptz, rn int, esp bigint, ubi bigint, zona int, cc int,
                           camp int, d1 date) on commit drop;
  insert into t_vta (id, ins, usr, vis, fecha, rn, esp, ubi, zona, cc, camp, d1)
  select pg_temp.did(10, v.ins * 1000000 + v.rn), v.ins, v.usr, v.id, v.fecha + interval '12 minutes', v.rn, v.esp, v.ubi, v.zona,
         z.cc, i.camp, i.d1
    from (select t.*, row_number() over (partition by t.ins order by t.fecha, t.id)::int rn from t_vis t where t.res = 'VENTA') v
    join t_ins i on i.no = v.ins
    join t_zona z on z.idx = v.zona;

  create temp table t_item (id uuid primary key, venta uuid, ins int, fecha timestamptz, code int, kind text, prod uuid, col uuid,
                            cant int, precio int, subtotal int, componentes jsonb, pa int, pb int) on commit drop;
  insert into t_item (id, venta, ins, fecha, code, kind, prod, col, cant, precio, subtotal, componentes, pa, pb)
  select pg_temp.did(11, x.ins * 1000000 + row_number() over (partition by x.ins order by x.rn, x.k)),
         x.id, x.ins, x.fecha, x.code, x.kind,
         case when x.kind = 'P' then pg_temp.did(5, x.code) end,
         case when x.kind = 'C' then pg_temp.did(6, x.code - 100) end,
         x.cant, x.precio, x.cant * x.precio,
         case when x.code = 101 then jsonb_build_array(jsonb_build_object('producto_id', pg_temp.did(5, 3), 'cantidad', 1),
                                                       jsonb_build_object('producto_id', pg_temp.did(5, 7), 'cantidad', 2))
              when x.code = 102 then jsonb_build_array(jsonb_build_object('producto_id', pg_temp.did(5, x.pa), 'cantidad', 1),
                                                       jsonb_build_object('producto_id', pg_temp.did(5, x.pb), 'cantidad', 1)) end,
         x.pa, x.pb
    from (
      select b.id, b.ins, b.fecha, b.rn, b.k, w.code, w.kind,
             case when w.kind = 'C' then 1
                  when p.categoria = 'REVISTAS' then 1 + floor(pg_temp.rnd('iq' || b.id || b.k) * 3)::int
                  when p.categoria = 'MATERIAL' then 2
                  when pg_temp.rnd('iq' || b.id || b.k) > 0.80 then 2 else 1 end as cant,
             coalesce(
               (select ppc.precio_venta from public.precio_por_ciudad ppc
                 where ppc.campania_ciudad_id = (select c.id from t_cc c where c.idx = b.cc)
                   and ppc.deleted_at is null and b.fecha::date between ppc.valido_desde and coalesce(ppc.valido_hasta, date '2999-12-31')
                   and ((w.kind = 'P' and ppc.producto_id = pg_temp.did(5, w.code)) or (w.kind = 'C' and ppc.coleccion_id = pg_temp.did(6, w.code - 100)))
                 limit 1),
               (select pgl.precio_venta from public.precio_general pgl
                 where pgl.deleted_at is null and b.fecha::date between pgl.valido_desde and coalesce(pgl.valido_hasta, date '2999-12-31')
                   and ((w.kind = 'P' and pgl.producto_id = pg_temp.did(5, w.code)) or (w.kind = 'C' and pgl.coleccion_id = pg_temp.did(6, w.code - 100)))
                 limit 1)) as precio,
             1 + floor(pg_temp.rnd('ia' || b.id || b.k) * 6)::int as pa,
             1 + ((1 + floor(pg_temp.rnd('ia' || b.id || b.k) * 6)::int) + floor(pg_temp.rnd('ib' || b.id || b.k) * 5)::int) % 6 as pb
        from (select va.*, k.k from t_vta va
                cross join lateral generate_series(1, 1 + (pg_temp.rnd('in' || va.id) > 0.50)::int + (pg_temp.rnd('in2' || va.id) > 0.85)::int) k(k)) b
        join t_w w on pg_temp.rnd('ip' || b.id || b.k) * (select sum(w2.w) from t_w w2) >= w.lo
                  and pg_temp.rnd('ip' || b.id || b.k) * (select sum(w2.w) from t_w w2) < w.hi
        left join t_prod p on w.kind = 'P' and p.code = w.code
    ) x;
  -- el segundo libro del combo «2 a elegir» sale distinto del primero (el módulo ya lo garantiza salvo pa = pb)
  update t_item set pb = 1 + pa % 6 where code = 102 and pa = pb;
  update t_item set componentes = jsonb_build_array(jsonb_build_object('producto_id', pg_temp.did(5, pa), 'cantidad', 1),
                                                    jsonb_build_object('producto_id', pg_temp.did(5, pb), 'cantidad', 1))
   where code = 102;

  -- El total de la venta es la suma de sus renglones; algunas llevan un descuento acordado (con su motivo).
  alter table t_vta add column suma int, add column total int, add column motivo text, add column nit int;
  update t_vta v set suma = s.suma, nit = s.nit,
         total = case when s.nit > 1 and pg_temp.rnd('dto' || v.id) < 0.06 then (floor(s.suma * 0.93 / 1000) * 1000)::int else s.suma end,
         motivo = case when s.nit > 1 and pg_temp.rnd('dto' || v.id) < 0.06 then 'Descuento acordado con el cliente por llevar varios títulos' end
    from (select i.venta, sum(i.subtotal)::int suma, count(*)::int nit from t_item i group by i.venta) s
   where s.venta = v.id;

  insert into public.venta (id, espacio_persona_id, numero_talonario, monto_total, fecha, colportor_id, visita_id, motivo_monto_manual)
  select v.id, pg_temp.did(46, v.esp), 'T' || lpad(v.ins::text, 2, '0') || '-' || lpad(v.rn::text, 4, '0'), v.total, v.fecha, pg_temp.did(0, v.usr), v.vis, v.motivo
    from t_vta v on conflict do nothing;
  insert into public.venta_item (id, venta_id, producto_id, cantidad, precio_unitario, subtotal, coleccion_id, componentes)
  select i.id, i.venta, i.prod, i.cant, i.precio, i.subtotal, i.col, i.componentes from t_item i on conflict do nothing;

  -- --------------------------------------------------------------------------------------------------
  -- 10. Entregas: lo vendido sale del stock (las de los últimos días quedan pendientes de entregar)
  -- --------------------------------------------------------------------------------------------------
  create temp table t_ent (id uuid primary key, venta uuid, ins int, usr int, prod int, cant int, pend boolean, fecha timestamptz, esp bigint) on commit drop;
  insert into t_ent (id, venta, ins, usr, prod, cant, pend, fecha, esp)
  select pg_temp.did(12, q.ins * 1000000 + row_number() over (partition by q.ins order by q.venta, q.item, q.sub)),
         q.venta, q.ins, v.usr, q.prod, q.cant,
         (v.fecha >= timestamptz '2026-10-26 00:00:00+00' and pg_temp.rnd('pe' || q.venta) < 0.20), v.fecha, v.esp
    from (
      select i.venta, i.ins, i.id item, 1 sub, i.code prod, i.cant from t_item i where i.code <= 10
      union all select i.venta, i.ins, i.id, 1, 3, i.cant from t_item i where i.code = 101
      union all select i.venta, i.ins, i.id, 2, 7, i.cant * 2 from t_item i where i.code = 101
      union all select i.venta, i.ins, i.id, 1, i.pa, i.cant from t_item i where i.code = 102
      union all select i.venta, i.ins, i.id, 2, i.pb, i.cant from t_item i where i.code = 102
    ) q join t_vta v on v.id = q.venta;

  -- --------------------------------------------------------------------------------------------------
  -- 11. Cobros: contado o en cuotas cada 14 días; algunos clientes dejan de pagar (deuda por cliente)
  -- --------------------------------------------------------------------------------------------------
  create temp table t_cuota (venta uuid, ins int, usr int, camp int, k int, n int, monto int, fecha timestamptz, paga boolean, medio text,
                             moroso boolean, esp bigint) on commit drop;
  insert into t_cuota (venta, ins, usr, camp, k, n, monto, fecha, paga, medio, moroso, esp)
  select v.id, v.ins, v.usr, v.camp, g.k, p.n,
         case when g.k < p.n then (floor(v.total / p.n / 100) * 100)::int else (v.total - floor(v.total / p.n / 100) * 100 * (p.n - 1))::int end,
         case when g.k = 1 then v.fecha + interval '5 minutes'
              when v.camp = 1 then ((v.fecha::date + 14 * (g.k - 1))::timestamp + interval '14 hours'
                                    + (floor(pg_temp.rnd('cf' || v.id || g.k) * 240) || ' minutes')::interval) at time zone 'UTC'
              else (least(v.fecha::date + 10 * (g.k - 1), v.d1 + 2)::timestamp + interval '14 hours'
                    + (floor(pg_temp.rnd('cf' || v.id || g.k) * 240) || ' minutes')::interval) at time zone 'UTC' end,
         false,
         case when p.n = 1 then (case when pg_temp.rnd('cm' || v.id) < 0.60 then 'EFECTIVO' when pg_temp.rnd('cm' || v.id) < 0.85 then 'TARJETA' else 'TRANSFERENCIA' end)
              when g.k = 1 then (case when pg_temp.rnd('cm' || v.id) < 0.70 then 'EFECTIVO' else 'TRANSFERENCIA' end)
              else (case when pg_temp.rnd('cm' || v.id || g.k) < 0.80 then 'EFECTIVO' else 'TRANSFERENCIA' end) end,
         (v.camp = 1 and pg_temp.rnd('mo' || v.id) < 0.14), v.esp
    from t_vta v
    cross join lateral (select case when pg_temp.rnd('cn' || v.id) < 0.55 then 1 else 2 + floor(pg_temp.rnd('cq' || v.id) * 3)::int end as n) p
    cross join lateral generate_series(1, p.n) g(k)
   where v.total > 0;
  update t_cuota set paga = (k = 1 or (not moroso and fecha <= v_corte));

  create temp table t_cob (id uuid primary key, venta uuid, ins int, usr int, camp int, monto int, medio text, fecha timestamptz,
                           ticket uuid, anulada boolean, n int) on commit drop;
  insert into t_cob (id, venta, ins, usr, camp, monto, medio, fecha, ticket, anulada, n)
  select pg_temp.did(13, c.ins * 1000000 + c.rn), c.venta, c.ins, c.usr, c.camp, c.monto, c.medio, c.fecha,
         case when c.medio = 'TARJETA' then pg_temp.did(28, c.ins * 1000000 + c.rn) end, false, c.rn
    from (select cu.*, row_number() over (partition by cu.ins order by cu.fecha, cu.venta, cu.k)::int rn from t_cuota cu where cu.paga) c;
  -- Unos pocos cobros cargados dos veces y anulados por la colportora (no cuentan en ningún saldo).
  insert into t_cob (id, venta, ins, usr, camp, monto, medio, fecha, ticket, anulada, n)
  select pg_temp.did(13, c.ins * 1000000 + 500000 + c.n), c.venta, c.ins, c.usr, c.camp, c.monto, 'EFECTIVO', c.fecha + interval '3 minutes', null, true, 500000 + c.n
    from t_cob c where c.medio = 'EFECTIVO' and pg_temp.rnd('an' || c.id) < 0.012;

  create temp table t_tkt (id uuid primary key, usr int, ins int, tipo text, monto bigint, fecha timestamptz, estado text, motivo text,
                           marca text, tipo_tarjeta text, aut text, camp int) on commit drop;
  insert into t_tkt (id, usr, ins, tipo, monto, fecha, estado, motivo, marca, tipo_tarjeta, aut, camp)
  select c.ticket, c.usr, c.ins, 'COBRO_TARJETA', c.monto, c.fecha,
         case when c.fecha > timestamptz '2026-10-29 23:59:00+00' then 'PENDIENTE'
              when pg_temp.rnd('tr' || c.id) < 0.05 then 'RECHAZADO' else 'VALIDADO' end,
         null,
         (array['Visa', 'Mastercard', 'OCA', 'Visa'])[1 + floor(pg_temp.rnd('tm' || c.id) * 4)::int],
         case when pg_temp.rnd('tt' || c.id) < 0.7 then 'CREDITO' else 'DEBITO' end,
         lpad((100000 + floor(pg_temp.rnd('ta' || c.id) * 899999))::bigint::text, 6, '0'), c.camp
    from t_cob c where c.ticket is not null;
  update t_tkt set motivo = 'El comprobante no coincide con el monto cobrado' where estado = 'RECHAZADO';

  -- --------------------------------------------------------------------------------------------------
  -- 12. Depósitos: cada lunes el colportor deposita lo de la semana anterior (los flojos se atrasan), más el alquiler
  -- --------------------------------------------------------------------------------------------------
  create temp table t_dep (id uuid primary key, usr int, ins int, camp uuid, monto bigint, fecha timestamptz, destino text, concepto text,
                           ticket uuid, validado boolean) on commit drop;
  create temp table t_sem (ins int, ws date, cash bigint, card bigint) on commit drop;
  insert into t_sem (ins, ws, cash, card)
  select i.no, (date_trunc('week', i.d0::timestamp)::date + 7 * g.n),
         coalesce((select sum(c.monto) from t_cob c where c.ins = i.no and not c.anulada and c.medio <> 'TARJETA'
                      and c.fecha::date between (date_trunc('week', i.d0::timestamp)::date + 7 * g.n) and (date_trunc('week', i.d0::timestamp)::date + 7 * g.n + 6)), 0),
         coalesce((select sum(c.monto) from t_cob c where c.ins = i.no and not c.anulada and c.medio = 'TARJETA'
                      and c.fecha::date between (date_trunc('week', i.d0::timestamp)::date + 7 * g.n) and (date_trunc('week', i.d0::timestamp)::date + 7 * g.n + 6)), 0)
    from t_ins i
    cross join lateral generate_series(0, (i.d1 - date_trunc('week', i.d0::timestamp)::date) / 7) g(n);

  v_run := -1; v_dep_cum := 0; v_need := 0; v_n := 0;
  for r in select s.*, i.usr, i.camp, i.hab, i.cierre
             from t_sem s join t_ins i on i.no = s.ins order by s.ins, s.ws
  loop
    if r.ins <> v_run then v_run := r.ins; v_dep_cum := 0; v_need := 0; v_n := 0; end if;
    v_need := v_need + greatest((round((0.55 * (r.cash + r.card)) / 100) * 100)::bigint - r.card, 0);
    v_fecha := ((r.ws + 7)::timestamp + interval '15 hours' + (floor(pg_temp.rnd('df' || r.ins || r.ws) * 180) || ' minutes')::interval) at time zone 'UTC';
    if v_fecha <= v_corte
       and (r.cierre or pg_temp.rnd('sk' || r.ins || r.ws) >= 0.05 + 0.35 * (1 - r.hab / 1.30))
       and v_need - v_dep_cum >= 10000 then
      v_n := v_n + 1;
      v_monto := v_need - v_dep_cum;
      insert into t_dep (id, usr, ins, camp, monto, fecha, destino, concepto, ticket, validado)
      values (pg_temp.did(27, r.ins * 1000000 + v_n), r.usr, r.ins, null, v_monto, v_fecha,
              case when pg_temp.rnd('dd' || r.ins || r.ws) < 0.50 then 'BANCO' when pg_temp.rnd('dd' || r.ins || r.ws) < 0.75 then 'OFICINA' else 'RETIRO_COORDINADOR' end,
              'CASA_EDITORA', null, v_fecha <= timestamptz '2026-10-29 23:59:00+00');
      v_dep_cum := v_dep_cum + v_monto;
    end if;
  end loop;
  -- Alquiler de la campaña: los que rinden pagan entero, los demás parte o nada (la más floja no pagó).
  insert into t_dep (id, usr, ins, camp, monto, fecha, destino, concepto, ticket, validado)
  select pg_temp.did(27, i.no * 1000000 + 900 + q.n), i.usr, i.no, (select c.id from t_camp c where c.idx = i.camp),
         (case when i.camp = 1 then 150000 else 125000 end)::bigint,
         ((i.d0 + q.dias)::timestamp + interval '16 hours' + (floor(pg_temp.rnd('af' || i.no || q.n) * 120) || ' minutes')::interval) at time zone 'UTC',
         'BANCO', 'ALQUILER', null, (i.d0 + q.dias) <= date '2026-10-29'
    from t_ins i
    cross join lateral (values (1, case when i.camp = 1 then 7 else 3 end), (2, case when i.camp = 1 then 28 else 25 end)) q(n, dias)
   where (i.camp = 2 or (q.n = 1 and i.hab >= 0.40) or (q.n = 2 and i.hab >= 0.70));

  -- Tickets de los depósitos con comprobante (banco u oficina)
  insert into t_tkt (id, usr, ins, tipo, monto, fecha, estado, motivo, marca, tipo_tarjeta, aut, camp)
  select pg_temp.did(28, d.ins * 1000000 + 800000 + row_number() over (partition by d.ins order by d.fecha, d.id)),
         d.usr, d.ins, 'DEPOSITO', d.monto, d.fecha, case when d.validado then 'VALIDADO' else 'PENDIENTE' end, null, null, null, null, null
    from t_dep d where d.destino <> 'RETIRO_COORDINADOR';
  update t_dep d set ticket = t.id
    from (select td.id, td.ins, td.fecha, td.monto from t_tkt td where td.tipo = 'DEPOSITO') t
   where d.destino <> 'RETIRO_COORDINADOR' and t.ins = d.ins and t.fecha = d.fecha and t.monto = d.monto;

  -- --------------------------------------------------------------------------------------------------
  -- 13. Pedidos a la casa editora y stock. El inventario sale de lo que cada colportor vendió (más un 10 % de colchón):
  --     dos pedidos recibidos por inscripción (al arrancar y a mitad de campaña) y, para algunos, uno autorizado que
  --     todavía no llegó, uno por autorizar y uno rechazado.
  -- --------------------------------------------------------------------------------------------------
  create temp table t_ped (id uuid primary key, usr int, ins int, pn int, fecha timestamptz, estado text, origen text, decidido timestamptz,
                           motivo text, monto bigint default 0, excede boolean default false) on commit drop;
  create temp table t_pit (ped uuid, usr int, ins int, pn int, prod int, cant int, precio int) on commit drop;

  insert into t_ped (id, usr, ins, pn, fecha, estado, origen, decidido)
  select pg_temp.did(16, i.no * 10 + 1), i.usr, i.no, 1,
         ((i.d0 - 1)::timestamp + interval '14 hours') at time zone 'UTC', 'RECIBIDO', 'COORDINADOR',
         ((i.d0 - 1)::timestamp + interval '14 hours') at time zone 'UTC'
    from t_ins i
  union all
  select pg_temp.did(16, i.no * 10 + 2), i.usr, i.no, 2,
         ((i.d0 + case when i.camp = 1 then 24 else 20 end)::timestamp + interval '14 hours') at time zone 'UTC', 'RECIBIDO', 'COLPORTOR',
         ((i.d0 + case when i.camp = 1 then 24 else 20 end + 1)::timestamp + interval '10 hours') at time zone 'UTC'
    from t_ins i
  union all
  select pg_temp.did(16, i.no * 10 + 3), i.usr, i.no, 3, timestamptz '2026-10-30 14:00:00+00', 'AUTORIZADO', 'COLPORTOR', timestamptz '2026-10-31 10:00:00+00'
    from t_ins i where i.camp = 1 and i.hab >= 0.60
  union all
  select pg_temp.did(16, i.no * 10 + 4), i.usr, i.no, 4, timestamptz '2026-11-03 15:00:00+00', 'PENDIENTE_AUTORIZACION', 'COLPORTOR', null
    from t_ins i where i.no in (4, 5, 8)
  union all
  select pg_temp.did(16, i.no * 10 + 5), i.usr, i.no, 5, timestamptz '2026-10-15 14:00:00+00', 'RECHAZADO', 'COLPORTOR', timestamptz '2026-10-16 10:00:00+00'
    from t_ins i where i.no = 10;
  update t_ped set motivo = 'Primero regularizá el depósito pendiente de la semana anterior' where estado = 'RECHAZADO';

  -- Lo recibido: 60 % al arrancar y el resto a mitad de campaña, por producto vendido y entregado.
  insert into t_pit (ped, usr, ins, pn, prod, cant, precio)
  select pg_temp.did(16, d.ins * 10 + q.pn), d.usr, d.ins, q.pn, d.prod,
         case when q.pn = 1 then ceil(d.entra * 0.60)::int else d.entra - ceil(d.entra * 0.60)::int end, p.compra
    from (select e.ins, e.usr, e.prod, ceil(sum(e.cant) * 1.10)::int + 1 as entra from t_ent e where not e.pend group by e.ins, e.usr, e.prod) d
    join t_prod p on p.code = d.prod
    cross join (values (1), (2)) q(pn)
   where case when q.pn = 1 then ceil(d.entra * 0.60)::int else d.entra - ceil(d.entra * 0.60)::int end > 0;
  -- Lo que pidieron y no llegó (autorizado), lo que espera autorización y lo rechazado: dos títulos de los libros.
  insert into t_pit (ped, usr, ins, pn, prod, cant, precio)
  select p.id, p.usr, p.ins, p.pn, c.code, 6 + floor(pg_temp.rnd('pq' || p.id || c.n) * 9)::int, t.compra
    from t_ped p
    cross join lateral (values (1, 1 + floor(pg_temp.rnd('pa' || p.id) * 6)::int),
                               (2, 1 + (floor(pg_temp.rnd('pa' || p.id) * 6)::int + 1 + floor(pg_temp.rnd('pb' || p.id) * 5)::int) % 6)) c(n, code)
    join t_prod t on t.code = c.code
   where p.pn >= 3;
  update t_ped p set monto = coalesce((select sum(i.cant::bigint * i.precio) from t_pit i where i.ped = p.id), 0);
  delete from t_ped where monto = 0;

  -- --------------------------------------------------------------------------------------------------
  -- 14. Cuentas de los colportores: se calculan de las mismas filas que se cargan abajo
  -- --------------------------------------------------------------------------------------------------
  create temp table t_cta (usr int primary key, ped bigint, dce bigint, dval bigint, tval bigint, efec bigint, dtot bigint, porcobrar bigint,
                           deuda bigint, depositado bigint, en_mano bigint) on commit drop;
  insert into t_cta (usr, ped, dce, dval, tval, efec, dtot, porcobrar)
  select u.idx,
         coalesce((select sum(p.monto) from t_ped p where p.usr = u.idx and p.estado in ('AUTORIZADO', 'DESPACHADO', 'RECIBIDO')), 0),
         coalesce((select sum(d.monto) from t_dep d where d.usr = u.idx and d.concepto = 'CASA_EDITORA' and d.validado), 0),
         coalesce((select sum(d.monto) from t_dep d where d.usr = u.idx and d.validado), 0),
         coalesce((select sum(t.monto) from t_tkt t where t.usr = u.idx and t.tipo = 'COBRO_TARJETA' and t.estado = 'VALIDADO'), 0),
         coalesce((select sum(c.monto) from t_cob c where c.usr = u.idx and not c.anulada and c.medio = 'EFECTIVO'), 0),
         coalesce((select sum(d.monto) from t_dep d where d.usr = u.idx), 0),
         coalesce((select sum(q.monto) from t_cuota q where q.usr = u.idx and not q.paga), 0)
    from t_usr u where u.rol = 'COLPORTOR';
  update t_cta set deuda = ped - dce - tval, depositado = dval + tval, en_mano = greatest(efec - dtot, 0);
  -- El pedido por autorizar que haría pasar el límite de deuda de la campaña queda marcado.
  update t_ped p set excede = true
    from t_cta c, t_camp ca
   where p.estado = 'PENDIENTE_AUTORIZACION' and c.usr = p.usr and ca.idx = 1 and ca.limite is not null
     and c.deuda + p.monto > ca.limite;

  -- --------------------------------------------------------------------------------------------------
  -- 15. A la base: pedidos, stock, tickets, cobros, depósitos, entregas, agenda, casas coloreadas y cuentas
  -- --------------------------------------------------------------------------------------------------
  insert into public.pedido_casa_editora (id, colportor_id, coordinador_id, fecha_pedido, estado, monto_total, origen, excede_limite,
                                          monto_autorizado, decidido_por, decidido_en, motivo_rechazo)
  select p.id, pg_temp.did(0, p.usr), case when p.decidido is not null then v_coord end, p.fecha, p.estado, p.monto, p.origen, p.excede,
         case when p.estado in ('AUTORIZADO', 'RECIBIDO') then p.monto end,
         case when p.decidido is not null then v_coord end, p.decidido, p.motivo
    from t_ped p on conflict do nothing;
  insert into public.pedido_item (id, pedido_id, producto_id, cantidad, precio_unitario, cantidad_recibida, colportor_id, cantidad_autorizada)
  select pg_temp.did(17, (i.ins * 10 + i.pn) * 100 + i.prod), i.ped, pg_temp.did(5, i.prod), i.cant, i.precio,
         case when p.estado = 'RECIBIDO' then i.cant end, pg_temp.did(0, i.usr),
         case when p.estado in ('AUTORIZADO', 'RECIBIDO') then i.cant end
    from t_pit i join t_ped p on p.id = i.ped on conflict do nothing;

  -- El stock arranca con todo lo recibido; las entregas (abajo) lo van descontando y dejan sus movimientos.
  insert into public.stock (id, usuario_id, producto_id, cantidad_disponible, cantidad_reservada)
  select pg_temp.did(25, i.usr * 100 + i.prod), pg_temp.did(0, i.usr), pg_temp.did(5, i.prod), sum(i.cant), 0
    from t_pit i join t_ped p on p.id = i.ped where p.estado = 'RECIBIDO'
   group by i.usr, i.prod
  on conflict do nothing;
  insert into public.movimiento_stock (usuario_id, producto_id, tipo, cantidad, fecha, pedido_id)
  select pg_temp.did(0, i.usr), pg_temp.did(5, i.prod), 'ENTRADA_PEDIDO', i.cant, p.fecha + interval '1 day', p.id
    from t_pit i join t_ped p on p.id = i.ped where p.estado = 'RECIBIDO';

  insert into public.ticket (id, usuario_id, tipo, subido_en, revisado_por, revisado_en, monto, fecha, numero_autorizacion, tarjeta_tipo,
                             tarjeta_marca, estado, motivo_rechazo, campania_validadora_id)
  select t.id, pg_temp.did(0, t.usr), t.tipo, t.fecha + interval '20 minutes',
         case when t.estado <> 'PENDIENTE' then v_coord end, case when t.estado <> 'PENDIENTE' then t.fecha + interval '26 hours' end,
         t.monto, t.fecha, t.aut, t.tipo_tarjeta, t.marca, t.estado, t.motivo,
         case when t.estado <> 'PENDIENTE' then (select ca.id from t_camp ca join t_ins i on i.camp = ca.idx where i.no = t.ins) end
    from t_tkt t on conflict do nothing;

  insert into public.cobranza (id, venta_id, monto, medio, fecha, tarjeta_tipo, tarjeta_marca, numero_aprobacion, referencia_transferencia,
                               banco_origen, ticket_id, anulado_at, motivo_anulacion)
  select c.id, c.venta, c.monto, c.medio, c.fecha, t.tipo_tarjeta, t.marca, t.aut,
         case when c.medio = 'TRANSFERENCIA' then 'TR-' || lpad((100000 + floor(pg_temp.rnd('tn' || c.id) * 899999))::bigint::text, 6, '0') end,
         case when c.medio = 'TRANSFERENCIA' then (array['BROU', 'Itaú', 'Santander', 'Scotiabank'])[1 + floor(pg_temp.rnd('tb' || c.id) * 4)::int] end,
         c.ticket, case when c.anulada then c.fecha + interval '1 hour' end, case when c.anulada then 'Lo registré dos veces' end
    from t_cob c left join t_tkt t on t.id = c.ticket on conflict do nothing;

  insert into public.deposito (id, colportor_id, monto, fecha, ticket_id, destino, concepto, campania_id, validado_en, validado_por)
  select d.id, pg_temp.did(0, d.usr), d.monto, d.fecha, d.ticket, d.destino, d.concepto, d.camp,
         case when d.validado then d.fecha + interval '27 hours' end, case when d.validado then v_coord end
    from t_dep d on conflict do nothing;

  insert into public.entrega (id, venta_id, producto_id, cantidad, fecha_entrega, pendiente, fecha_prevista)
  select e.id, e.venta, pg_temp.did(5, e.prod), e.cant, case when not e.pend then e.fecha end, e.pend,
         case when e.pend then e.fecha + ((3 + floor(pg_temp.rnd('pp' || e.id) * 5)) || ' days')::interval end
    from t_ent e on conflict do nothing;

  -- Agenda: la próxima cuota de cada cliente que debe, las entregas pendientes y algunas entrevistas de seguimiento.
  -- Las altas llevan created_at = el día de la historia (hoy = 04/11): tg_agenda_origen (AG003) mide la fecha programada contra
  -- created_at, y sin él una carga posterior rechazaría toda cuota PROGRAMADA que ya pasó.
  create temp table t_ag_ent (vis uuid primary key, ins int, usr int, esp bigint, ubi bigint, fecha timestamptz) on commit drop;
  insert into t_ag_ent (vis, ins, usr, esp, ubi, fecha)
  select v.id, v.ins, v.usr, v.esp, v.ubi, greatest(v.fecha + interval '7 days', timestamptz '2026-11-05 15:00:00+00')
    from t_vis v where v.res = 'ENTREVISTA' and v.fecha >= timestamptz '2026-10-24 00:00:00+00' and pg_temp.rnd('ag' || v.id) < 0.50;

  insert into public.agenda (id, espacio_persona_id, tipo, fecha_programada, estado, colportor_id, espacio_id, venta_id, monto_previsto, created_at)
  select pg_temp.did(26, q.ins * 1000000 + row_number() over (partition by q.ins order by q.fecha, q.venta)), pg_temp.did(46, q.esp), 'COBRANZA', q.fecha,
         case when q.fecha < timestamptz '2026-11-04 00:00:00+00' then 'NO_CUMPLIDA' else 'PROGRAMADA' end,
         pg_temp.did(0, q.usr), e.id, q.venta, q.monto, timestamptz '2026-11-04 12:00:00+00'
    from (select distinct on (c.venta) c.* from t_cuota c where not c.paga order by c.venta, c.k) q
    join t_esp e on e.no = q.esp
  on conflict do nothing;
  insert into public.agenda (id, espacio_persona_id, tipo, fecha_programada, estado, colportor_id, espacio_id, venta_id, entrega_id, created_at)
  select pg_temp.did(26, 300000 + row_number() over (order by en.id)), pg_temp.did(46, en.esp), 'ENTREGA',
         en.fecha + ((3 + floor(pg_temp.rnd('pp' || en.id) * 5)) || ' days')::interval,
         case when en.fecha + ((3 + floor(pg_temp.rnd('pp' || en.id) * 5)) || ' days')::interval < timestamptz '2026-11-04 00:00:00+00' then 'NO_CUMPLIDA' else 'PROGRAMADA' end,
         pg_temp.did(0, en.usr), e.id, en.venta, en.id, timestamptz '2026-11-04 12:00:00+00'
    from t_ent en join t_esp e on e.no = en.esp where en.pend
  on conflict do nothing;
  insert into public.agenda (id, espacio_persona_id, tipo, fecha_programada, estado, colportor_id, espacio_id, visita_id, created_at)
  select pg_temp.did(26, 600000 + row_number() over (order by a.vis)), pg_temp.did(46, a.esp), 'ENTREVISTA', a.fecha, 'PROGRAMADA',
         pg_temp.did(0, a.usr), e.id, null, timestamptz '2026-11-04 12:00:00+00'
    from t_ag_ent a join t_esp e on e.no = a.esp
  on conflict do nothing;

  -- Color de cada casa visitada en el mapa (ADR-010)
  insert into public.house_status (ubicacion_id, lat, lon, tipo_ubicacion, color, prioridad)
  select u.id, u.lat, u.lon, u.tipo, f.color,
         case f.color when 'ENTREGA_Y_COBRANZA_PENDIENTE' then 1 when 'COBRANZA_PENDIENTE' then 2 when 'ENTREVISTA_PROGRAMADA' then 3
                      when 'VENTA_COMPLETA' then 4 when 'ENTREVISTA_SIN_VENTA' then 5 when 'SIN_CONTESTAR' then 6 else 7 end
    from t_ubi u
    cross join lateral (
      select case
        when exists (select 1 from t_ent e where e.pend and e.esp / 10 = u.no) then 'ENTREGA_Y_COBRANZA_PENDIENTE'
        when exists (select 1 from t_cuota c where not c.paga and c.esp / 10 = u.no) then 'COBRANZA_PENDIENTE'
        when exists (select 1 from t_ag_ent a where a.ubi = u.no) then 'ENTREVISTA_PROGRAMADA'
        else (select case l.res when 'VENTA' then 'VENTA_COMPLETA' when 'ENTREVISTA' then 'ENTREVISTA_SIN_VENTA'
                              when 'NO_CONTESTO' then 'SIN_CONTESTAR' else 'RECHAZO' end
                from t_vis l where l.ubi = u.no order by l.fecha desc, l.id limit 1) end as color
    ) f
   where f.color is not null
  on conflict do nothing;

  -- Cuenta de cada colportor (sus cuatro cifras) y la deuda que figuraba hace una semana (cuenta_deuda_historial)
  insert into public.cuenta_colportor (id, usuario_id, deuda_total, dinero_depositado, dinero_en_mano, dinero_por_cobrar)
  select pg_temp.did(21, c.usr), pg_temp.did(0, c.usr), c.deuda, c.depositado, c.en_mano, c.porcobrar from t_cta c on conflict do nothing;
  insert into public.cuenta_deuda_historial (id, usuario_id, deuda, desde)
  select pg_temp.did(22, c.usr), pg_temp.did(0, c.usr),
         coalesce((select sum(p.monto) from t_ped p where p.usr = c.usr and p.estado in ('AUTORIZADO', 'DESPACHADO', 'RECIBIDO')
                      and p.decidido <= timestamptz '2026-10-27 12:00:00+00'), 0)
         - coalesce((select sum(d.monto) from t_dep d where d.usr = c.usr and d.concepto = 'CASA_EDITORA' and d.validado
                      and d.fecha + interval '27 hours' <= timestamptz '2026-10-27 12:00:00+00'), 0)
         - coalesce((select sum(t.monto) from t_tkt t where t.usr = c.usr and t.tipo = 'COBRO_TARJETA' and t.estado = 'VALIDADO'
                      and t.fecha + interval '26 hours' <= timestamptz '2026-10-27 12:00:00+00'), 0),
         timestamptz '2026-10-27 12:00:00+00'
    from t_cta c on conflict do nothing;

  raise notice 'Demo cargada: % colportores, % jornadas, % visitas, % ventas, % cobros, % depósitos, % pedidos.',
    (select count(*) from t_cta), (select count(*) from t_jor), (select count(*) from t_vis), (select count(*) from t_vta),
    (select count(*) from t_cob), (select count(*) from t_dep), (select count(*) from t_ped);
end
$seed$;
