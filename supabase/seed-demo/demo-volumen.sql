-- ============================================================================
-- Datos de DEMO simulados, segunda tanda: VOLUMEN para las pruebas de los evaluadores (backend-supabase#285)
--
-- Qué suma, sobre la campaña de verano que ya cargó demo-datos.sql (la misma, con su coordinador y sus precios):
--   · 150 ciudades más (del catálogo de Uruguay que carga la migración 0109), cada una con su ciudad de campaña y dos
--     zonas radiales; 50 de ellas con precios propios (por ciudad) distintos del general.
--   · 54 colportores nuevos (3 por ciudad en las 18 primeras), cada uno inscripto en una zona, con jornadas de seis
--     semanas (28/09 a 17/11, de lunes a sábado), visitas, ventas con sus renglones, cobros (al contado, en parte
--     o en dos cuotas), casas coloreadas en el mapa y su cuenta.
--   Con eso Inicio, Equipo, Ciudades y Reportes del panel muestran listas largas, barras de ciudades llenas y reportes con
--   volumen (front-coordinadores-web#186 y #188).
--
-- Qué NO suma, a propósito: entregas, stock, pedidos ni depósitos (la tanda base ya ejercita esos flujos) y, como en la
-- base, ninguna persona con nombre o teléfono (`persona` es solo del teléfono, ADR-018).
--
-- NO es una migración ni el seed de ejemplo (supabase/seed.sql): es un generador que se corre a mano, con
-- scripts/db-seed-demo.sh --volumen, contra la base local o contra el proyecto de demo. Todo es FICTICIO: nombres,
-- correos @example.com, direcciones con números inventados, montos.
--
-- Cómo funciona (igual que demo-datos.sql)
--   · Requiere que demo-datos.sql ya esté cargado (usa su campaña, su coordinador y su catálogo de productos); si no,
--     se detiene con un mensaje y no cambia nada.
--   · Un solo DO: o carga todo o no carga nada. Solo INSERT; nunca DELETE, TRUNCATE ni cambios de esquema.
--   · Las filas que crea llevan el prefijo de la demo (5eed0000-0000-7000-8…), con el código de tabla corrido 256
--     lugares respecto de demo-datos.sql (hexadecimal 1xx): así no chocan con la tanda base y retirar-demo-datos.sql las
--     retira junto con el resto. Los usuarios son demo.<nombre>.<apellido>.<n>@example.com.
--   · Idempotente: si la primera ciudad de esta tanda ya está en la campaña, avisa y no hace nada; cada INSERT lleva
--     además `on conflict do nothing`.
--   · Determinístico: sin random(); los "azares" salen de un hash (pg_temp.vrnd). La historia está anclada en fechas
--     absolutas (hasta el 17/11/2026), no depende del día en que se corre.
--   · Si la base no tiene todavía las ciudades del catálogo, corre public.cargar_catalogo_ciudades() (la carga de la 0109:
--     no borra ni duplica, es idempotente).
--   · Sin contraseña para los colportores nuevos (no se entra con ellos): mismo criterio que la tanda base.
--
-- Las migraciones tienen que estar aplicadas (la última que usa es la 0185).
-- ============================================================================

do $vol$
declare
  v_corte   constant timestamptz := timestamptz '2026-11-17 23:59:00+00';
  v_ciudades constant int := 150;   -- ciudades nuevas en la campaña
  v_conciudad constant int := 18;   -- las primeras tantas ciudades llevan colportores
  v_porciudad constant int := 3;    -- colportores por ciudad con colportores
  v_ubi     constant int := 24;     -- casas por zona con colportores
  v_camp    uuid;
  v_pais    uuid;
  v_n       int;
begin
  -- --------------------------------------------------------------------------------------------------
  -- 0. Ayudas de la sesión y guardas
  -- --------------------------------------------------------------------------------------------------
  -- Mismos ids de la demo con el código de tabla corrido 256 lugares (ver cabecera).
  create or replace function pg_temp.vdid(p_tabla int, p_n bigint) returns uuid
    language sql immutable as $f$
      select ('5eed0000-0000-7000-8' || lpad(to_hex(p_tabla + 256), 3, '0') || '-' || lpad(to_hex(p_n), 12, '0'))::uuid
    $f$;
  create or replace function pg_temp.bdid(p_tabla int, p_n bigint) returns uuid
    language sql immutable as $f$
      select ('5eed0000-0000-7000-8' || lpad(to_hex(p_tabla), 3, '0') || '-' || lpad(to_hex(p_n), 12, '0'))::uuid
    $f$;
  create or replace function pg_temp.vrnd(p_clave text) returns double precision
    language sql immutable as $f$
      select (('x' || substr(md5(p_clave), 1, 7))::bit(28)::int)::double precision / 268435456.0
    $f$;

  perform pg_advisory_xact_lock(hashtext('colportores.seed-demo'));

  v_camp := pg_temp.bdid(3, 1);
  if not exists (select 1 from public.campania c where c.id = v_camp and c.deleted_at is null) then
    raise exception 'Falta la demo base: cargá supabase/seed-demo/demo-datos.sql (scripts/db-seed-demo.sh) antes de esta tanda.';
  end if;
  if exists (select 1 from public.campania_ciudad cc where cc.id = pg_temp.vdid(9, 1)) then
    raise notice 'El volumen de demo ya está cargado (ciudad de campaña %). No se cambió nada.', pg_temp.vdid(9, 1);
    return;
  end if;
  if not exists (select 1 from public.rol where codigo = 'COLPORTOR') then
    raise exception 'Falta el rol COLPORTOR: aplicá las migraciones antes de cargar la demo.';
  end if;

  -- --------------------------------------------------------------------------------------------------
  -- 1. Ciudades: las del catálogo de Uruguay (si no están cargadas, se carga el catálogo)
  -- --------------------------------------------------------------------------------------------------
  select p.id into v_pais from public.pais p where p.iso_code = 'UY' and p.deleted_at is null order by p.created_at limit 1;
  if v_pais is null then
    raise exception 'Falta el país Uruguay: cargá demo-datos.sql antes de esta tanda.';
  end if;
  select count(*) into v_n from public.ciudad c where c.pais_id = v_pais and c.deleted_at is null and c.origen = 'OSM';
  if v_n < v_ciudades + 10 then
    perform public.cargar_catalogo_ciudades();
  end if;

  -- Orden fijo por un hash del nombre y el departamento (no del id, que cambia entre bases); sin las que la campaña ya tiene.
  create temp table tv_ciu (idx int primary key, id uuid, nombre text, depto text, lat double precision, lon double precision) on commit drop;
  insert into tv_ciu (idx, id, nombre, depto, lat, lon)
  select (row_number() over (order by md5(c.nombre || '|' || coalesce(c.departamento, ''))))::int, c.id, c.nombre, c.departamento, c.lat_centro, c.lon_centro
    from public.ciudad c
   where c.pais_id = v_pais and c.deleted_at is null and c.origen = 'OSM'
     and c.lat_centro is not null and c.lon_centro is not null
     and not exists (select 1 from public.campania_ciudad x where x.campania_id = v_camp and x.ciudad_id = c.id);
  delete from tv_ciu where idx > v_ciudades;
  select count(*) into v_n from tv_ciu;
  if v_n < v_conciudad then
    raise exception 'El catálogo de ciudades tiene solo % ciudades libres: hacen falta al menos %.', v_n, v_conciudad;
  end if;

  insert into public.campania_ciudad (id, campania_id, ciudad_id)
  select pg_temp.vdid(9, t.idx), v_camp, t.id from tv_ciu t on conflict do nothing;

  -- Dos zonas radiales por ciudad: el centro de la ciudad y un barrio hacia el norte.
  create temp table tv_zona (idx int primary key, id uuid, ciu int, nombre text, lat double precision, lon double precision, radio int, color text) on commit drop;
  insert into tv_zona (idx, id, ciu, nombre, lat, lon, radio, color)
  select t.idx * 2 + z.k, pg_temp.vdid(4, t.idx * 2 + z.k), t.idx, z.nombre,
         t.lat + z.dlat, t.lon, z.radio, z.color
    from tv_ciu t
    cross join (values (0, 'Centro', 0.0::double precision, 600, '#3A7BD5'),
                       (1, 'Zona Norte', 0.0045::double precision, 500, '#E07B39')) z(k, nombre, dlat, radio, color);
  insert into public.zona (id, nombre, poligono_geojson, campania_ciudad_id, tipo_forma, centro_lat, centro_lon, radio_m, color)
  select z.id, z.nombre, '{}'::jsonb, pg_temp.vdid(9, z.ciu), 'RADIAL', z.lat, z.lon, z.radio, z.color from tv_zona z
  on conflict do nothing;

  -- Precios propios en una de cada tres ciudades: tres libros entre un 6 % más baratos y un 6 % más caros que el general.
  insert into public.precio_por_ciudad (id, producto_id, coleccion_id, precio_venta, valido_desde, campania_ciudad_id)
  select pg_temp.vdid(35, t.idx * 10 + p.code), pg_temp.bdid(5, p.code), null::uuid,
         (pg.precio_venta * (1 + ((t.idx % 5) - 2) * 0.03) / 1000)::int * 1000, date '2026-09-14', pg_temp.vdid(9, t.idx)
    from tv_ciu t
    cross join (values (1), (2), (3)) p(code)
    join public.precio_general pg on pg.producto_id = pg_temp.bdid(5, p.code) and pg.deleted_at is null
   where t.idx % 3 = 0
  on conflict do nothing;

  -- --------------------------------------------------------------------------------------------------
  -- 2. Colportores nuevos (con su Auth, sin contraseña) y sus inscripciones
  -- --------------------------------------------------------------------------------------------------
  create temp table tv_usr (idx int primary key, id uuid, nombre text, apellido text, email text, ciu int, zona int, d0 date, hab double precision) on commit drop;
  insert into tv_usr (idx, id, nombre, apellido, email, ciu, zona, d0, hab)
  select g.n, pg_temp.vdid(0, g.n), nm.nombre, ap.apellido,
         'demo.' || lower(nm.nombre) || '.' || lower(ap.apellido) || '.' || g.n || '@example.com',
         (g.n - 1) / v_porciudad + 1,
         ((g.n - 1) / v_porciudad + 1) * 2 + case when (g.n - 1) % v_porciudad = v_porciudad - 1 then 1 else 0 end,
         date '2026-09-28' + ((g.n * 5) % 15),
         0.35 + 0.95 * pg_temp.vrnd('hab' || g.n)
    from generate_series(1, v_conciudad * v_porciudad) g(n)
    join (select row_number() over (order by n) rn, n as nombre
            from unnest(array['Mateo','Valentina','Santiago','Camila','Joaquin','Lucia','Benjamin','Martina','Thiago','Sofia',
                              'Bruno','Emilia','Facundo','Julieta','Nicolas','Agustina','Lautaro','Florencia','Maximiliano','Catalina',
                              'Ignacio','Victoria','Tomas','Abril','Gonzalo','Renata','Franco','Antonella','Ramiro','Micaela']) n) nm
      on nm.rn = 1 + (g.n * 7) % 30
    join (select row_number() over (order by a) rn, a as apellido
            from unnest(array['Rodriguez','Gonzalez','Fernandez','Silva','Pereira','Martinez','Lopez','Diaz','Rodrigues','Sosa',
                              'Rivero','Castro','Romero','Suarez','Alvarez','Mendez','Benitez','Cardozo','Vazquez','Ramos',
                              'Correa','Cabrera','Moreira','Nunez','Ferreira','Gutierrez','Pintos','Acuna','Techera','Olivera']) a) ap
      on ap.rn = 1 + (g.n * 11) % 30;

  insert into auth.users (instance_id, id, aud, role, email, encrypted_password, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
  select '00000000-0000-0000-0000-000000000000'::uuid, u.id, 'authenticated', 'authenticated', u.email, null,
         '{"provider":"email","providers":["email"]}'::jsonb,
         jsonb_build_object('nombre', u.nombre, 'apellido', u.apellido, 'demo', true),
         timestamptz '2026-09-20 12:00:00+00', timestamptz '2026-09-20 12:00:00+00'
    from tv_usr u
  on conflict do nothing;
  if exists (select 1 from information_schema.columns where table_schema = 'auth' and table_name = 'users' and column_name = 'email_confirmed_at') then
    update auth.users set email_confirmed_at = coalesce(email_confirmed_at, created_at)
     where id in (select id from tv_usr);
  end if;
  declare r record;
  begin
    for r in select c.column_name from information_schema.columns c
              where c.table_schema = 'auth' and c.table_name = 'users'
                and c.column_name in ('confirmation_token', 'recovery_token', 'email_change_token_new', 'email_change',
                                      'email_change_token_current', 'phone_change', 'phone_change_token', 'reauthentication_token')
    loop
      execute format('update auth.users set %1$I = '''' where %1$I is null and id in (select id from pg_temp.tv_usr)', r.column_name);
    end loop;
  end;

  insert into public.usuario (id, email, nombre, apellido, created_by)
  select u.id, u.email, u.nombre, u.apellido, u.id from tv_usr u on conflict (id) do nothing;
  insert into public.usuario_rol (id, usuario_id, rol_id)
  select pg_temp.vdid(31, u.idx), u.id, (select r2.id from public.rol r2 where r2.codigo = 'COLPORTOR') from tv_usr u
  on conflict do nothing;

  -- La fecha de alta es el primer día de la inscripción (00:00 de Montevideo), no la de la carga: Inicio y Reportes solo
  -- cuentan lo que pasó con la inscripción vigente y en la zona de ese día.
  insert into public.campania_colportor (id, campania_id, usuario_id, zona_id, created_at)
  select pg_temp.vdid(11, u.idx), v_camp, u.id, pg_temp.vdid(4, u.zona), u.d0::timestamp at time zone 'America/Montevideo'
    from tv_usr u on conflict do nothing;
  -- El trigger del historial (0022) abre el primer tramo de zona con la hora de la carga: empieza el mismo día.
  update public.campania_colportor_zona_historial h
     set desde = u.d0::timestamp at time zone 'America/Montevideo'
    from tv_usr u
   where h.campania_colportor_id = pg_temp.vdid(11, u.idx)
     and h.deleted_at is null
     and h.desde > u.d0::timestamp at time zone 'America/Montevideo'
     and not exists (select 1 from public.campania_colportor_zona_historial h2
                      where h2.campania_colportor_id = h.campania_colportor_id and h2.desde < h.desde);

  -- --------------------------------------------------------------------------------------------------
  -- 3. Casas: ubicaciones y espacios en las zonas que tienen colportores
  -- --------------------------------------------------------------------------------------------------
  create temp table tv_ubi (no bigint primary key, zona int, j int, id uuid, tipo text, calle text, numero text, lat double precision,
                           lon double precision, nesp int, ciu int) on commit drop;
  insert into tv_ubi (no, zona, j, id, tipo, calle, numero, lat, lon, nesp, ciu)
  select z.idx * 100 + g.j, z.idx, g.j, pg_temp.vdid(12, z.idx * 100 + g.j),
         case when g.j % 9 = 0 then 'EDIFICIO' when g.j % 7 = 0 then 'NEGOCIO' else 'CASA' end,
         (array['Calle Artigas', 'Av. Italia', 'Calle Rivera', 'Av. Brasil', 'Calle Sarandí', 'Calle 18 de Julio', 'Calle Treinta y Tres',
                'Av. Luis Alberto de Herrera'])[1 + (g.j + z.idx) % 8],
         (100 + z.idx * 40 + g.j)::text,
         z.lat + (z.radio * 0.92 * sqrt(pg_temp.vrnd('ur' || z.idx || '-' || g.j)) * cos(2 * pi() * pg_temp.vrnd('ua' || z.idx || '-' || g.j))) / 111320.0,
         z.lon + (z.radio * 0.92 * sqrt(pg_temp.vrnd('ur' || z.idx || '-' || g.j)) * sin(2 * pi() * pg_temp.vrnd('ua' || z.idx || '-' || g.j)))
                 / (111320.0 * cos(radians(z.lat))),
         case when g.j % 9 = 0 then 3 else 1 end,
         z.ciu
    from tv_zona z
    cross join lateral generate_series(1, v_ubi) g(j)
   where z.idx in (select distinct zona from tv_usr);
  create index on tv_ubi (zona, j);

  insert into public.ubicacion (id, tipo, calle, numero, lat, lon, ciudad_id)
  select u.id, u.tipo, u.calle, u.numero, u.lat, u.lon, (select c.id from tv_ciu c where c.idx = u.ciu) from tv_ubi u
  on conflict do nothing;

  create temp table tv_esp (no bigint primary key, ubi bigint, e int, id uuid) on commit drop;
  insert into tv_esp (no, ubi, e, id)
  select u.no * 10 + e.e, u.no, e.e, pg_temp.vdid(13, u.no * 10 + e.e) from tv_ubi u cross join lateral generate_series(1, u.nesp) e(e);
  insert into public.espacio (id, ubicacion_id, numero_depto, piso)
  select e.id, u.id, case when u.tipo = 'EDIFICIO' then (e.e * 100 + 1 + e.e)::text end, case when u.tipo = 'EDIFICIO' then e.e::text end
    from tv_esp e join tv_ubi u on u.no = e.ubi
  on conflict do nothing;

  -- --------------------------------------------------------------------------------------------------
  -- 4. Jornadas (lunes a sábado, según la habilidad de cada colportor) y visitas
  -- --------------------------------------------------------------------------------------------------
  create temp table tv_jor (id uuid primary key, usr int, dia date, dn int, inicio timestamptz, fin timestamptz, nvis int) on commit drop;
  insert into tv_jor (id, usr, dia, dn, inicio, fin, nvis)
  select pg_temp.vdid(15, u.idx * 1000 + (d.dia - u.d0) + 1), u.idx, d.dia, (d.dia - u.d0) + 1,
         (d.dia::timestamp + interval '12 hours 30 minutes' + (floor(pg_temp.vrnd('ji' || u.idx || d.dia) * 90) || ' minutes')::interval) at time zone 'UTC',
         (d.dia::timestamp + interval '12 hours 30 minutes' + (floor(pg_temp.vrnd('ji' || u.idx || d.dia) * 90) || ' minutes')::interval
            + ((190 + floor(pg_temp.vrnd('jf' || u.idx || d.dia) * 110)) || ' minutes')::interval) at time zone 'UTC',
         4 + floor(pg_temp.vrnd('jn' || u.idx || d.dia) * 5)::int
    from tv_usr u
    cross join lateral generate_series(0, date '2026-11-17' - u.d0) g(n)
    cross join lateral (select u.d0 + g.n as dia) d
   where extract(dow from d.dia) <> 0
     and pg_temp.vrnd('jw' || u.idx || d.dia) < 0.36 + 0.30 * u.hab / 1.30;

  create temp table tv_vis (id uuid primary key, usr int, jor uuid, fecha timestamptz, esp bigint, ubi bigint, res text, zona int) on commit drop;
  insert into tv_vis (id, usr, jor, fecha, esp, ubi, res, zona)
  select pg_temp.vdid(14, j.usr * 100000 + j.dn * 100 + k.k), j.usr, j.id,
         j.inicio + ((k.k - 1) * 30 || ' minutes')::interval + (floor(pg_temp.vrnd('vm' || j.id || k.k) * 8) || ' minutes')::interval,
         u.no * 10 + case when u.nesp > 1 then 1 + floor(pg_temp.vrnd('ve' || j.id || k.k) * u.nesp)::int else 1 end,
         u.no,
         case when pg_temp.vrnd('vr' || j.id || k.k) < 0.17 * us.hab then 'VENTA'
              when pg_temp.vrnd('vr' || j.id || k.k) < 0.17 * us.hab + 0.10 then 'ENTREVISTA'
              when pg_temp.vrnd('vr' || j.id || k.k) < 0.17 * us.hab + 0.10 + 0.13 then 'RECHAZO'
              else 'NO_CONTESTO' end,
         us.zona
    from tv_jor j
    join tv_usr us on us.idx = j.usr
    cross join lateral generate_series(1, j.nvis) k(k)
    join tv_ubi u on u.zona = us.zona
     and u.j = 1 + floor(pg_temp.vrnd('vu' || j.id || k.k) * v_ubi)::int;

  insert into public.espacio_persona (id, espacio_id, persona_id)
  select pg_temp.vdid(46, e.no), e.id, pg_temp.vdid(47, e.no)
    from tv_esp e where e.no in (select esp from tv_vis)
  on conflict do nothing;

  insert into public.jornada (id, colportor_id, inicio, fin, total_visitas, total_ventas)
  select j.id, pg_temp.vdid(0, j.usr), j.inicio, j.fin,
         (select count(*) from tv_vis v where v.jor = j.id), (select count(*) from tv_vis v where v.jor = j.id and v.res = 'VENTA')
    from tv_jor j
  on conflict do nothing;

  insert into public.visita (id, espacio_persona_id, fecha, tipo_resultado, colportor_id, jornada_id, espacio_id, entrevista_entrada, entrevista_salida)
  select v.id, pg_temp.vdid(46, v.esp), v.fecha, v.res, pg_temp.vdid(0, v.usr), v.jor, e.id,
         case when v.res = 'ENTREVISTA' then v.fecha end,
         case when v.res = 'ENTREVISTA' then v.fecha + ((15 + floor(pg_temp.vrnd('vs' || v.id) * 25)) || ' minutes')::interval end
    from tv_vis v join tv_esp e on e.no = v.esp
  on conflict do nothing;

  -- --------------------------------------------------------------------------------------------------
  -- 5. Ventas y sus renglones (precio de la ciudad si hay, si no el general; títulos sueltos, sin combos)
  -- --------------------------------------------------------------------------------------------------
  create temp table tv_vta (id uuid primary key, usr int, vis uuid, fecha timestamptz, rn int, esp bigint, ciu int) on commit drop;
  insert into tv_vta (id, usr, vis, fecha, rn, esp, ciu)
  select pg_temp.vdid(10, v.usr * 100000 + v.rn), v.usr, v.id, v.fecha + interval '12 minutes', v.rn, v.esp, us.ciu
    from (select t.*, row_number() over (partition by t.usr order by t.fecha, t.id)::int rn from tv_vis t where t.res = 'VENTA') v
    join tv_usr us on us.idx = v.usr;

  create temp table tv_item (id uuid primary key, venta uuid, usr int, code int, cant int, precio int, subtotal int) on commit drop;
  insert into tv_item (id, venta, usr, code, cant, precio, subtotal)
  select pg_temp.vdid(11, x.usr * 100000 + row_number() over (partition by x.usr order by x.rn, x.k)),
         x.id, x.usr, x.code, x.cant, x.precio, x.cant * x.precio
    from (
      select b.id, b.usr, b.rn, b.k, b.code,
             case when b.code in (7, 8) then 1 + floor(pg_temp.vrnd('iq' || b.id || b.k) * 3)::int
                  when b.code = 10 then 2
                  when pg_temp.vrnd('iq' || b.id || b.k) > 0.80 then 2 else 1 end as cant,
             coalesce(
               (select ppc.precio_venta from public.precio_por_ciudad ppc
                 where ppc.campania_ciudad_id = pg_temp.vdid(9, b.ciu) and ppc.producto_id = pg_temp.bdid(5, b.code)
                   and ppc.deleted_at is null and b.fecha::date between ppc.valido_desde and coalesce(ppc.valido_hasta, date '2999-12-31')
                 limit 1),
               (select pgl.precio_venta from public.precio_general pgl
                 where pgl.deleted_at is null and pgl.producto_id = pg_temp.bdid(5, b.code)
                   and b.fecha::date between pgl.valido_desde and coalesce(pgl.valido_hasta, date '2999-12-31')
                 limit 1)) as precio
        from (select va.*, k.k, 1 + floor(power(pg_temp.vrnd('ip' || va.id || k.k), 1.35) * 10)::int as code
                from tv_vta va
                cross join lateral generate_series(1, 1 + (pg_temp.vrnd('in' || va.id) > 0.50)::int + (pg_temp.vrnd('in2' || va.id) > 0.85)::int) k(k)) b
    ) x;
  -- El segundo renglón con el mismo título que el primero se junta en uno solo (la venta no repite el producto).
  delete from tv_item i using tv_item j where i.venta = j.venta and i.code = j.code and i.id > j.id;

  alter table tv_vta add column total int, add column nit int;
  update tv_vta v set total = s.suma, nit = s.nit
    from (select i.venta, sum(i.subtotal)::int suma, count(*)::int nit from tv_item i group by i.venta) s
   where s.venta = v.id;

  insert into public.venta (id, espacio_persona_id, numero_talonario, monto_total, fecha, colportor_id, visita_id)
  select v.id, pg_temp.vdid(46, v.esp), 'V' || lpad(v.usr::text, 3, '0') || '-' || lpad(v.rn::text, 4, '0'), v.total, v.fecha, pg_temp.vdid(0, v.usr), v.vis
    from tv_vta v where v.total is not null on conflict do nothing;
  insert into public.venta_item (id, venta_id, producto_id, cantidad, precio_unitario, subtotal)
  select i.id, i.venta, pg_temp.bdid(5, i.code), i.cant, i.precio, i.subtotal from tv_item i on conflict do nothing;

  -- --------------------------------------------------------------------------------------------------
  -- 6. Cobros en efectivo: 70 % al contado, 20 % dejan la mitad y 10 % pagan en dos cuotas (la segunda a los 14 días, si ya pasó)
  -- --------------------------------------------------------------------------------------------------
  create temp table tv_cob (id uuid primary key, venta uuid, usr int, monto int, fecha timestamptz) on commit drop;
  insert into tv_cob (id, venta, usr, monto, fecha)
  select pg_temp.vdid(13, c.usr * 1000000 + c.rn * 10 + c.k), c.id, c.usr, c.monto, c.fecha
    from (
      select v.id, v.usr, v.rn, 1 as k, v.fecha + interval '5 minutes' as fecha,
             case when e.esc < 0.70 then v.total else (floor(v.total / 2 / 100) * 100)::int end as monto
        from tv_vta v cross join lateral (select pg_temp.vrnd('ce' || v.id) as esc) e where v.total > 0
      union all
      select v.id, v.usr, v.rn, 2, v.fecha + interval '14 days',
             (v.total - floor(v.total / 2 / 100) * 100)::int
        from tv_vta v cross join lateral (select pg_temp.vrnd('ce' || v.id) as esc) e
       where v.total > 0 and e.esc >= 0.90 and v.fecha + interval '14 days' <= v_corte
    ) c where c.monto > 0;
  insert into public.cobranza (id, venta_id, monto, medio, fecha)
  select c.id, c.venta, c.monto, 'EFECTIVO', c.fecha from tv_cob c on conflict do nothing;

  -- --------------------------------------------------------------------------------------------------
  -- 7. Color de cada casa visitada en el mapa y cuenta de cada colportor
  -- --------------------------------------------------------------------------------------------------
  insert into public.house_status (ubicacion_id, lat, lon, tipo_ubicacion, color, prioridad)
  select u.id, u.lat, u.lon, u.tipo, f.color,
         case f.color when 'COBRANZA_PENDIENTE' then 2 when 'VENTA_COMPLETA' then 4 when 'ENTREVISTA_SIN_VENTA' then 5
                      when 'SIN_CONTESTAR' then 6 else 7 end
    from tv_ubi u
    cross join lateral (
      select case
        when exists (select 1 from tv_vta v where v.esp / 10 = u.no and v.total is not null
                      and v.total > coalesce((select sum(c.monto) from tv_cob c where c.venta = v.id), 0)) then 'COBRANZA_PENDIENTE'
        else (select case l.res when 'VENTA' then 'VENTA_COMPLETA' when 'ENTREVISTA' then 'ENTREVISTA_SIN_VENTA'
                              when 'NO_CONTESTO' then 'SIN_CONTESTAR' else 'RECHAZO' end
                from tv_vis l where l.ubi = u.no order by l.fecha desc, l.id limit 1) end as color
    ) f
   where f.color is not null
  on conflict do nothing;

  -- Sin pedidos ni depósitos: deuda con la casa editora y depositado en cero; el efectivo en mano es todo lo cobrado.
  insert into public.cuenta_colportor (id, usuario_id, deuda_total, dinero_depositado, dinero_en_mano, dinero_por_cobrar)
  select pg_temp.vdid(21, u.idx), u.id, 0, 0,
         coalesce((select sum(c.monto) from tv_cob c where c.usr = u.idx), 0),
         coalesce((select sum(v.total) from tv_vta v where v.usr = u.idx and v.total is not null), 0)
           - coalesce((select sum(c.monto) from tv_cob c where c.usr = u.idx), 0)
    from tv_usr u
  on conflict do nothing;

  raise notice 'Volumen cargado: % ciudades, % zonas, % colportores, % jornadas, % visitas, % ventas, % cobros.',
    (select count(*) from tv_ciu), (select count(*) from tv_zona), (select count(*) from tv_usr), (select count(*) from tv_jor),
    (select count(*) from tv_vis), (select count(*) from tv_vta), (select count(*) from tv_cob);
end
$vol$;
