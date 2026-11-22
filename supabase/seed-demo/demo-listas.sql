-- ============================================================================
-- Datos de DEMO simulados, tercera tanda: LISTAS LARGAS (backend-supabase#289)
--
-- Para qué: que toda lista desplazable del panel de coordinadores (coordinador.demo) y de la app del colportor
-- (colportor.demo) tenga más de 25 registros, con estados, fechas de varias semanas y nombres distintos, y así se vea
-- cómo se comporta con volumen (scroll, carga, paginación: front-coordinadores-web#192 y front-colportores-mobile#720).
-- El inventario de listas y de qué tabla o RPC sale cada una está en supabase/seed-demo/README.md; la verificación,
-- en supabase/seed-demo/chequeo-listas-demo.sql.
--
-- Qué suma (todo ficticio, todo con el prefijo de la demo):
--   · Catálogo: 16 productos más (27 en total), con su precio general.
--   · 24 coordinadores más (la lista de acompañantes del panel) y 30 cuentas de colportor sin campaña (las que
--     «Añadir colportor» sugiere y busca).
--   · 26 zonas radiales más en Montevideo (los barrios).
--   · De los 54 colportores del volumen: un depósito por semana (a la cuenta, en la oficina o con retiro del coordinador),
--     con sus tickets y retiros por validar, validados y rechazados; cuatro pedidos a la casa editora cada uno (dos
--     recibidos con su stock de los 26 productos, y dos más: por autorizar o autorizado, rechazado o despachado);
--     transferencias de stock entre los de una misma ciudad (por autorizar, autorizadas y rechazadas); acompañamientos
--     del coordinador a sus jornadas; 40 ventas con un monto acordado y su motivo; y sus cuentas al día.
--   · De colportor.demo (si ya corrió --colportor): su historia desde el 14/09 (jornadas, visitas, ventas, cobros,
--     entregas hechas y pendientes, la agenda de cobranzas, entregas y entrevistas), un depósito por día hábil con sus
--     tickets y retiros, 39 pedidos a la casa editora con su deuda y su stock; y su cuenta al día.
--
-- Qué NO se puede sembrar desde la nube (ADR-018): personas, notas y duplicados (viven solo en el teléfono) y el historial
-- de avisos (lo arma la app al recibir cada aviso). Esas listas se llenan usando la app.
--
-- NO es una migración ni el seed de ejemplo (supabase/seed.sql): es un generador que se corre a mano, con
-- scripts/db-seed-demo.sh --listas, contra la base local o contra el proyecto de demo, DESPUÉS de la carga base, de
-- --coordinador, de --colportor y de --volumen (en ese orden; sin la base o sin el volumen se detiene con un mensaje).
--
-- Cómo funciona (igual que demo-datos.sql y demo-volumen.sql)
--   · Un solo DO: o carga todo o no carga nada. Solo INSERT, salvo las cuentas de saldo (que se actualizan con lo que
--     sumó esta carga) y el contador de visitas de las jornadas donde se agrega una venta; nunca DELETE, TRUNCATE ni
--     cambios de esquema.
--   · Las filas que crea llevan el prefijo de la demo (5eed0000-0000-7000-8…), con el código de tabla corrido 512 lugares
--     (hexadecimal 2xx), así que retirar-demo-datos.sql las retira junto con el resto. Los productos nuevos usan el
--     código de tabla de la base (8005) con los números 12 a 27.
--   · Idempotente: lo común (catálogo, cuentas, barrios, colportores del volumen) lo guarda el producto 12 del catálogo y la historia de
--     colportor.demo, su primera jornada: si colportor.demo no estaba lista, repetir --listas después de --colportor carga solo su
--     historia; si ya está todo, avisa y no hace nada. Cada INSERT lleva además `on conflict do nothing`.
--   · Determinístico: sin random(); los "azares" salen de un hash. Anclado en fechas absolutas (hasta el 17/11/2026).
--   · Sin contraseña para las cuentas nuevas (no se entra con ellas).
--
-- Las migraciones tienen que estar aplicadas (la última que usa es la 0185).
-- ============================================================================

do $listas$
declare
  v_corte   constant timestamptz := timestamptz '2026-11-17 23:59:00+00';
  v_camp    uuid;
  v_coord   uuid;      -- el coordinador de la campaña de la demo (el generado)
  v_acomp   uuid;      -- quien acompaña: coordinador.demo si existe, si no el coordinador de la campaña
  v_cd      uuid;      -- colportor.demo, si está inscripta con su actividad
  v_cd_ins  uuid;
  v_cd_zona constant uuid := '5eed0000-0000-7000-8004-000000000001';  -- Pocitos
  v_mvd     uuid;      -- ciudad de campaña de Montevideo
  v_n       int;
  v_base_hecha boolean;  -- los catálogos, las cuentas, los barrios y los colportores del volumen ya están (producto 12)
begin
  -- --------------------------------------------------------------------------------------------------
  -- 0. Ayudas de la sesión y guardas
  -- --------------------------------------------------------------------------------------------------
  -- Ids de esta tanda: el código de tabla corrido 512 lugares.
  create or replace function pg_temp.ldid(p_tabla int, p_n bigint) returns uuid
    language sql immutable as $f$
      select ('5eed0000-0000-7000-8' || lpad(to_hex(p_tabla + 512), 3, '0') || '-' || lpad(to_hex(p_n), 12, '0'))::uuid
    $f$;
  -- Ids de la base (8005 productos, 8003 campañas, 8004 zonas, 8000 usuarios…) y del volumen (corrido 256).
  create or replace function pg_temp.bdid(p_tabla int, p_n bigint) returns uuid
    language sql immutable as $f$
      select ('5eed0000-0000-7000-8' || lpad(to_hex(p_tabla), 3, '0') || '-' || lpad(to_hex(p_n), 12, '0'))::uuid
    $f$;
  create or replace function pg_temp.vdid(p_tabla int, p_n bigint) returns uuid
    language sql immutable as $f$
      select ('5eed0000-0000-7000-8' || lpad(to_hex(p_tabla + 256), 3, '0') || '-' || lpad(to_hex(p_n), 12, '0'))::uuid
    $f$;
  create or replace function pg_temp.lrnd(p_clave text) returns double precision
    language sql immutable as $f$
      select (('x' || substr(md5(p_clave), 1, 7))::bit(28)::int)::double precision / 268435456.0
    $f$;

  perform pg_advisory_xact_lock(hashtext('colportores.seed-demo'));

  v_camp := pg_temp.bdid(3, 1);
  if not exists (select 1 from public.campania c where c.id = v_camp and c.deleted_at is null) then
    raise exception 'Falta la demo base: cargá supabase/seed-demo/demo-datos.sql (scripts/db-seed-demo.sh) antes de esta tanda.';
  end if;
  if not exists (select 1 from public.campania_ciudad cc where cc.id = pg_temp.vdid(9, 1)) then
    raise exception 'Falta el volumen: corré scripts/db-seed-demo.sh --volumen antes de esta tanda.';
  end if;
  v_base_hecha := exists (select 1 from public.producto p where p.id = pg_temp.bdid(5, 12));
  if not exists (select 1 from public.rol where codigo = 'COLPORTOR') or not exists (select 1 from public.rol where codigo = 'COORDINADOR') then
    raise exception 'Faltan los roles COLPORTOR y COORDINADOR: aplicá las migraciones antes de cargar la demo.';
  end if;

  select c.coordinador_id into v_coord from public.campania c where c.id = v_camp;
  select u.id into v_acomp
    from public.usuario u
   where lower(u.email) = 'coordinador.demo@example.com' and u.deleted_at is null
     and exists (select 1 from public.usuario_rol ur join public.rol r on r.id = ur.rol_id
                  where ur.usuario_id = u.id and ur.deleted_at is null and r.codigo = 'COORDINADOR');
  v_acomp := coalesce(v_acomp, v_coord);

  -- colportor.demo: solo si ya corrió --colportor (inscripta, con su actividad) y no se le cargó esta tanda.
  select u.id into v_cd
    from public.usuario u
   where lower(u.email) = 'colportor.demo@example.com' and u.deleted_at is null
     and exists (select 1 from public.jornada j where j.id = pg_temp.bdid(15, 99000001) and j.colportor_id = u.id)
     and exists (select 1 from public.campania_colportor cc
                  where cc.usuario_id = u.id and cc.campania_id = v_camp and cc.deleted_at is null and cc.zona_id = v_cd_zona);
  -- Su historia tiene su propia guarda (la primera jornada de esta tanda): si colportor.demo no estaba lista en la primera
  -- pasada (sin --colportor), basta repetir --listas después de correrlo y se le carga solo la suya.
  if v_cd is not null and exists (select 1 from public.jornada j where j.id = pg_temp.ldid(15, 90000001)) then
    v_cd := null;
  end if;
  if v_base_hecha and v_cd is null then
    raise notice 'Las listas largas de la demo ya están cargadas (producto %) y no falta la historia de colportor.demo. No se cambió nada.', pg_temp.bdid(5, 12);
    return;
  end if;

  if not v_base_hecha then
  -- --------------------------------------------------------------------------------------------------
  -- 1. Catálogo: 16 productos más (códigos 12 a 27), cada uno con su precio general
  -- --------------------------------------------------------------------------------------------------
  create temp table tl_prod (code int primary key, id uuid, nombre text, descripcion text, categoria text,
                             bonif boolean, venta int, compra int, casa text) on commit drop;
  insert into tl_prod (code, id, nombre, descripcion, categoria, bonif, venta, compra, casa)
  select v.code, pg_temp.bdid(5, v.code), v.nombre, v.descripcion, v.categoria, v.bonif, v.venta, v.compra, v.casa
    from (values
      (12, 'Un Hogar Lleno de Paz',                    'Libro de convivencia familiar',          'BONIFICABLES', true,  118000, 59000, 'Casa Editora del Sur (demo)'),
      (13, 'Los Secretos de la Longevidad',            'Hábitos de vida saludable',              'BONIFICABLES', true,  132000, 66000, 'Ediciones Horizonte (demo)'),
      (14, 'Mi Primer Libro de Animales',              'Cuentos con ilustraciones a color',      'BONIFICABLES', true,   76000, 38000, 'Ediciones Horizonte (demo)'),
      (15, 'Cocina sin Carne para Todos los Días',     'Recetario vegetariano',                  'BONIFICABLES', true,   92000, 46000, 'Casa Editora del Sur (demo)'),
      (16, 'Vencer la Ansiedad',                       'Guía práctica de bienestar emocional',   'BONIFICABLES', true,   84000, 42000, 'Casa Editora del Sur (demo)'),
      (17, 'La Familia Feliz',                         'Edición de lujo, tapa dura',             'BONIFICABLES', true,  156000, 78000, 'Casa Editora del Sur (demo)'),
      (18, 'Atlas de la Biblia',                       'Mapas e historia de los pueblos',        'BONIFICABLES', true,  128000, 64000, 'Ediciones Horizonte (demo)'),
      (19, 'Camino a Cristo',                          'Clásico de bolsillo',                    'BONIFICABLES', true,   34000, 17000, 'Casa Editora del Sur (demo)'),
      (20, 'Revista Niños en Casa',                    'Revista mensual',                        'REVISTAS',     false,  15000,  7000, 'Ediciones Horizonte (demo)'),
      (21, 'Revista Mujer Sana',                       'Revista mensual',                        'REVISTAS',     false,  17000,  8000, 'Ediciones Horizonte (demo)'),
      (22, 'Revista Jóvenes en Acción',                'Revista mensual',                        'REVISTAS',     false,  15500,  7200, 'Ediciones Horizonte (demo)'),
      (23, 'Revista Salud al Día (edición especial)',  'Número especial',                        'REVISTAS',     false,  21000, 10000, 'Casa Editora del Sur (demo)'),
      (24, 'Devocional Noches de Paz',                 'Devocional para la noche',               'ESPIRITUALES', false,  48000, 24000, 'Casa Editora del Sur (demo)'),
      (25, 'Folleto Vivir Mejor',                      'Material de salud',                      'MATERIAL',     false,   8500,  3800, 'Ediciones Horizonte (demo)'),
      (26, 'Folleto Los Sueños de Daniel',             'Material de estudio bíblico',            'MATERIAL',     false,   9500,  4200, 'Casa Editora del Sur (demo)'),
      (27, 'Folleto Cómo Dormir Bien',                 'Material de salud',                      'MATERIAL',     false,   8000,  3600, 'Ediciones Horizonte (demo)')
    ) v(code, nombre, descripcion, categoria, bonif, venta, compra, casa);

  insert into public.producto (id, nombre, descripcion, es_bonificable, es_misionero, precio_base_compra, casa_editora, codigo_editor, categoria)
  select t.id, t.nombre, t.descripcion, t.bonif, false, t.compra, t.casa, 'DEMO26-' || lpad(t.code::text, 3, '0'), t.categoria
    from tl_prod t
  on conflict do nothing;
  insert into public.precio_general (id, producto_id, coleccion_id, precio_venta, valido_desde)
  select pg_temp.bdid(34, t.code), t.id, null::uuid, t.venta, date '2026-06-01' from tl_prod t
  on conflict do nothing;

  -- --------------------------------------------------------------------------------------------------
  -- 2. Cuentas sueltas: 24 coordinadores (los acompañantes del panel) y 30 colportores sin campaña (los que «Añadir» sugiere)
  -- --------------------------------------------------------------------------------------------------
  create temp table tl_ext (n int primary key, id uuid, nombre text, apellido text, email text, rol text) on commit drop;
  insert into tl_ext (n, id, nombre, apellido, email, rol)
  select g.n, pg_temp.ldid(0, g.n), nm.nombre, ap.apellido,
         case when g.n <= 24 then 'demo.coord.' else 'demo.aspirante.' end || lower(nm.nombre) || '.' || lower(ap.apellido) || '.' || g.n || '@example.com',
         case when g.n <= 24 then 'COORDINADOR' else 'COLPORTOR' end
    from generate_series(1, 54) g(n)
    join (select row_number() over (order by n) rn, n as nombre
            from unnest(array['Andres','Carolina','Diego','Elena','Fabian','Gabriela','Hernan','Irene','Julian','Karina',
                              'Leandro','Mariana','Nahuel','Olivia','Pablo','Romina','Sebastian','Tamara','Ulises','Veronica',
                              'Walter','Ximena','Yamila','Zoe','Alvaro','Belen','Cecilia','Dario','Esteban','Fiorella']) n) nm
      on nm.rn = 1 + (g.n * 7) % 30
    join (select row_number() over (order by a) rn, a as apellido
            from unnest(array['Aguirre','Bentancor','Cardoso','Delgado','Echeverria','Fagundez','Garcia','Hernandez','Iglesias','Jimenez',
                              'Klein','Lemos','Maidana','Nieto','Ortiz','Pacheco','Quintana','Rey','Salvo','Tabarez',
                              'Urrutia','Viera','Weiss','Yanez','Zunino','Altez','Berrutti','Collazo','Dutra','Estevez']) a) ap
      on ap.rn = 1 + (g.n * 11) % 30;

  insert into auth.users (instance_id, id, aud, role, email, encrypted_password, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
  select '00000000-0000-0000-0000-000000000000'::uuid, u.id, 'authenticated', 'authenticated', u.email, null,
         '{"provider":"email","providers":["email"]}'::jsonb,
         jsonb_build_object('nombre', u.nombre, 'apellido', u.apellido, 'demo', true),
         timestamptz '2026-09-20 12:00:00+00', timestamptz '2026-09-20 12:00:00+00'
    from tl_ext u
  on conflict do nothing;
  if exists (select 1 from information_schema.columns where table_schema = 'auth' and table_name = 'users' and column_name = 'email_confirmed_at') then
    update auth.users set email_confirmed_at = coalesce(email_confirmed_at, created_at)
     where id in (select id from tl_ext);
  end if;
  -- En la base local `confirmed_at` es una columna común (en Supabase la calcula Auth a partir de email_confirmed_at): sin ella
  -- «Añadir colportor» no sugiere ni encuentra las cuentas.
  if exists (select 1 from information_schema.columns
              where table_schema = 'auth' and table_name = 'users' and column_name = 'confirmed_at' and is_generated = 'NEVER') then
    execute 'update auth.users set confirmed_at = coalesce(confirmed_at, created_at) where id in (select id from pg_temp.tl_ext)';
  end if;
  declare r record;
  begin
    for r in select c.column_name from information_schema.columns c
              where c.table_schema = 'auth' and c.table_name = 'users'
                and c.column_name in ('confirmation_token', 'recovery_token', 'email_change_token_new', 'email_change',
                                      'email_change_token_current', 'phone_change', 'phone_change_token', 'reauthentication_token')
    loop
      execute format('update auth.users set %1$I = '''' where %1$I is null and id in (select id from pg_temp.tl_ext)', r.column_name);
    end loop;
  end;
  insert into public.usuario (id, email, nombre, apellido, created_by)
  select u.id, u.email, u.nombre, u.apellido, u.id from tl_ext u on conflict (id) do nothing;
  insert into public.usuario_rol (id, usuario_id, rol_id)
  select pg_temp.ldid(31, u.n), u.id, (select r2.id from public.rol r2 where r2.codigo = u.rol) from tl_ext u
  on conflict do nothing;

  -- --------------------------------------------------------------------------------------------------
  -- 3. Zonas: 26 barrios de Montevideo (radiales, como las del volumen)
  -- --------------------------------------------------------------------------------------------------
  select cc.id into v_mvd
    from public.campania_ciudad cc join public.ciudad ci on ci.id = cc.ciudad_id
   where cc.campania_id = v_camp and cc.deleted_at is null and ci.nombre = 'Montevideo' and ci.deleted_at is null
   order by cc.created_at limit 1;
  if v_mvd is not null then
    insert into public.zona (id, nombre, poligono_geojson, campania_ciudad_id, tipo_forma, centro_lat, centro_lon, radio_m, color)
    select pg_temp.ldid(4, b.n), b.nombre, '{}'::jsonb, v_mvd, 'RADIAL',
           -34.9011 + ((b.n - 1) / 6 - 2) * 0.0105 + (b.n % 2) * 0.0018,
           -56.1645 + ((b.n - 1) % 6 - 2.5) * 0.0125,
           450 + (b.n % 4) * 60,
           (array['#3A7BD5', '#E07B39', '#4CAF7A', '#9B59B6', '#D64F6A', '#2BA3B5'])[1 + b.n % 6]
      from (select row_number() over (order by nombre)::int as n, nombre
              from unnest(array['Carrasco', 'Malvín', 'Buceo', 'Punta Gorda', 'Parque Rodó', 'Cordón Norte', 'Centro', 'Ciudad Vieja',
                                'Aguada', 'Palermo', 'Barrio Sur', 'Tres Cruces', 'La Blanqueada', 'Unión', 'Malvín Norte',
                                'Cerro', 'La Teja', 'Prado Norte', 'Capurro', 'Sayago', 'Colón', 'Lezica', 'Peñarol', 'Piedras Blancas',
                                'Manga', 'Casavalle']) nombre) b
    on conflict do nothing;
  else
    raise notice 'La campaña de la demo no tiene Montevideo: no se suman los barrios.';
  end if;

  -- --------------------------------------------------------------------------------------------------
  -- 4. Los 54 colportores del volumen: ventas con monto acordado, depósitos, pedidos, transferencias, acompañamientos, cuentas
  -- --------------------------------------------------------------------------------------------------
  create temp table tl_vcol (idx int primary key, id uuid, ins uuid, d0 date, hab double precision) on commit drop;
  insert into tl_vcol (idx, id, ins, d0, hab)
  select (('x' || lpad(right(u.id::text, 12), 16, '0'))::bit(64)::bigint)::int, u.id, cc.id, public.hoy_montevideo(cc.created_at),
         0.35 + 0.95 * pg_temp.lrnd('hab' || u.id::text)
    from public.usuario u
    join public.campania_colportor cc on cc.usuario_id = u.id and cc.campania_id = v_camp and cc.deleted_at is null
   where u.id::text like '5eed0000-0000-7000-8100-%' and u.deleted_at is null;
  select count(*) into v_n from tl_vcol;
  if v_n = 0 then
    raise exception 'El volumen no dejó colportores inscriptos en la campaña de la demo: corré --volumen antes de esta tanda.';
  end if;

  -- 4a. 40 ventas con un monto acordado (la lista «ventas con motivo» del panel): una por colportor, en una de sus
  --     jornadas, con dos títulos, un 10 % menos que la suma de sus renglones y cobrada al contado.
  create temp table tl_mv (n int primary key, usr int, uid uuid, jor uuid, fecha timestamptz, esp_persona uuid, espacio uuid,
                           pa int, pb int, ppa int, ppb int, total int) on commit drop;
  insert into tl_mv (n, usr, uid, jor, fecha, esp_persona, espacio, pa, pb)
  select (row_number() over (order by c.idx))::int, c.idx, c.id, j.id, j.fin - interval '20 minutes', v.espacio_persona_id, v.espacio_id,
         1 + (c.idx % 6), 7 + (c.idx % 3)
    from tl_vcol c
    cross join lateral (select jj.id, jj.fin from public.jornada jj
                         where jj.colportor_id = c.id and jj.fin is not null and jj.deleted_at is null
                         order by jj.inicio offset 4 limit 1) j
    cross join lateral (select vv.espacio_persona_id, vv.espacio_id from public.visita vv
                         where vv.jornada_id = j.id and vv.deleted_at is null order by vv.fecha, vv.id limit 1) v
   where c.idx <= 40;
  update tl_mv m set ppa = (select pg.precio_venta from public.precio_general pg where pg.producto_id = pg_temp.bdid(5, m.pa) and pg.deleted_at is null
                              and m.fecha::date between pg.valido_desde and coalesce(pg.valido_hasta, date '2999-12-31') limit 1),
                     ppb = (select pg.precio_venta from public.precio_general pg where pg.producto_id = pg_temp.bdid(5, m.pb) and pg.deleted_at is null
                              and m.fecha::date between pg.valido_desde and coalesce(pg.valido_hasta, date '2999-12-31') limit 1);
  delete from tl_mv where ppa is null or ppb is null;
  update tl_mv set total = (floor((ppa + ppb) * 0.90 / 100) * 100)::int;

  insert into public.visita (id, espacio_persona_id, fecha, tipo_resultado, colportor_id, jornada_id, espacio_id)
  select pg_temp.ldid(14, m.n), m.esp_persona, m.fecha, 'VENTA', m.uid, m.jor, m.espacio from tl_mv m on conflict do nothing;
  insert into public.venta (id, espacio_persona_id, numero_talonario, monto_total, fecha, colportor_id, visita_id, motivo_monto_manual)
  select pg_temp.ldid(10, m.n), m.esp_persona, 'L' || lpad(m.usr::text, 3, '0') || '-' || lpad(m.n::text, 4, '0'), m.total, m.fecha, m.uid,
         pg_temp.ldid(14, m.n),
         (array['Descuento acordado con el cliente', 'Promoción de fin de mes', 'Precio de campaña para un vecino de la zona',
                'Pago al contado con descuento'])[1 + m.n % 4]
    from tl_mv m on conflict do nothing;
  insert into public.venta_item (id, venta_id, producto_id, cantidad, precio_unitario, subtotal)
  select pg_temp.ldid(11, m.n * 10 + q.k), pg_temp.ldid(10, m.n), pg_temp.bdid(5, q.code), 1, q.precio, q.precio
    from tl_mv m cross join lateral (values (1, m.pa, m.ppa), (2, m.pb, m.ppb)) q(k, code, precio)
  on conflict do nothing;
  insert into public.cobranza (id, venta_id, monto, medio, fecha)
  select pg_temp.ldid(13, m.n), pg_temp.ldid(10, m.n), m.total, 'EFECTIVO', m.fecha + interval '5 minutes' from tl_mv m on conflict do nothing;
  update public.jornada j set total_visitas = j.total_visitas + 1, total_ventas = j.total_ventas + 1
   where j.id in (select jor from tl_mv);

  -- 4b. Depósitos: cada lunes, el 60 % de lo que cobró en efectivo la semana anterior (algunas semanas se saltea). Un 30 %
  --     va al banco, un 30 % a la oficina (con ticket) y un 40 % es un retiro del coordinador. Los tickets de las dos últimas
  --     semanas esperan validación, y una parte de los anteriores se rechazó; de los retiros, unos esperan, otros se
  --     confirmaron y otros se rechazaron.
  create temp table tl_dep (id uuid primary key, usr int, uid uuid, k int, monto bigint, fecha timestamptz, destino text, estado text, ticket uuid) on commit drop;
  insert into tl_dep (id, usr, uid, k, monto, fecha, destino, estado, ticket)
  select pg_temp.ldid(27, s.idx * 1000 + s.k), s.idx, s.uid, s.k, s.monto, s.fecha, s.destino, s.estado,
         case when s.destino <> 'RETIRO_COORDINADOR' then pg_temp.ldid(28, s.idx * 1000 + s.k) end
    from (
      select w.idx, w.uid, (row_number() over (partition by w.idx order by w.ws))::int as k, w.monto, w.fecha, w.destino,
             case when w.destino = 'RETIRO_COORDINADOR' then case when w.r2 < 0.30 then 'PENDIENTE' when w.r2 < 0.75 then 'VALIDADO' else 'RECHAZADO' end
                  when w.fecha > timestamptz '2026-11-02 23:59:00+00' then 'PENDIENTE'
                  when w.r2 < 0.25 then 'RECHAZADO' else 'VALIDADO' end as estado
        from (
          select x.idx, x.uid, x.ws, (floor(x.cash * 0.60 / 100) * 100)::bigint as monto,
                 ((x.ws + 7)::timestamp + interval '15 hours' + (floor(pg_temp.lrnd('df' || x.idx || x.ws) * 180) || ' minutes')::interval) at time zone 'UTC' as fecha,
                 case when pg_temp.lrnd('dd' || x.idx || x.ws) < 0.30 then 'BANCO' when pg_temp.lrnd('dd' || x.idx || x.ws) < 0.60 then 'OFICINA'
                      else 'RETIRO_COORDINADOR' end as destino,
                 pg_temp.lrnd('es' || x.idx || x.ws) as r2,
                 pg_temp.lrnd('sk' || x.idx || x.ws) as r3
            from (
              select c.idx, c.id as uid, g.ws,
                     coalesce((select sum(cb.monto) from public.cobranza cb join public.venta v on v.id = cb.venta_id
                                where v.colportor_id = c.id and cb.medio = 'EFECTIVO' and cb.anulado_at is null and cb.deleted_at is null
                                  and public.hoy_montevideo(cb.fecha) between g.ws and g.ws + 6), 0) as cash
                from tl_vcol c
                cross join lateral (select gs::date as ws
                                      from generate_series(date_trunc('week', c.d0::timestamp), timestamp '2026-11-09', interval '7 days') gs) g
            ) x
        ) w
       where w.monto >= 10000 and w.r3 >= 0.06 and w.fecha <= v_corte
    ) s;

  insert into public.ticket (id, usuario_id, tipo, subido_en, revisado_por, revisado_en, monto, fecha, estado, motivo_rechazo, campania_validadora_id)
  select d.ticket, d.uid, 'DEPOSITO', d.fecha + interval '20 minutes',
         case when d.estado <> 'PENDIENTE' then v_coord end, case when d.estado <> 'PENDIENTE' then d.fecha + interval '26 hours' end,
         d.monto, d.fecha, d.estado,
         case when d.estado = 'RECHAZADO' then 'No se lee el comprobante: sacá otra foto con buena luz.' end,
         case when d.estado <> 'PENDIENTE' then v_camp end
    from tl_dep d where d.ticket is not null
  on conflict do nothing;
  insert into public.deposito (id, colportor_id, monto, fecha, ticket_id, destino, concepto, campania_id, validado_en, validado_por,
                               rechazado_en, rechazado_por, motivo_rechazo)
  select d.id, d.uid, d.monto, d.fecha, d.ticket, d.destino, 'CASA_EDITORA', null,
         case when d.estado = 'VALIDADO' then d.fecha + interval '27 hours' end, case when d.estado = 'VALIDADO' then v_coord end,
         case when d.estado = 'RECHAZADO' and d.destino = 'RETIRO_COORDINADOR' then d.fecha + interval '27 hours' end,
         case when d.estado = 'RECHAZADO' and d.destino = 'RETIRO_COORDINADOR' then v_coord end,
         case when d.estado = 'RECHAZADO' and d.destino = 'RETIRO_COORDINADOR' then 'El efectivo no coincide con lo declarado: contalo de nuevo.' end
    from tl_dep d on conflict do nothing;

  -- 4c. Pedidos a la casa editora: cuatro por colportor. El primero (el kit de arranque con los 26 títulos) y el segundo
  --     (una reposición) llegaron; el tercero está por autorizar (los pares) o autorizado (los impares); el cuarto fue
  --     rechazado (pares) o despachado (impares).
  create temp table tl_ped (id uuid primary key, usr int, uid uuid, pn int, fecha timestamptz, estado text, origen text, decidido timestamptz,
                            motivo text, monto bigint default 0) on commit drop;
  create temp table tl_pit (ped uuid, usr int, uid uuid, pn int, prod int, cant int, precio int) on commit drop;
  insert into tl_ped (id, usr, uid, pn, fecha, estado, origen, decidido, motivo)
  select pg_temp.ldid(16, c.idx * 10 + p.pn), c.idx, c.id, p.pn, p.fecha, p.estado, p.origen, p.decidido, p.motivo
    from tl_vcol c
    cross join lateral (values
      (1, ((c.d0 - 1)::timestamp + interval '14 hours') at time zone 'UTC', 'RECIBIDO', 'COORDINADOR',
          ((c.d0 - 1)::timestamp + interval '14 hours') at time zone 'UTC', null::text),
      (2, ((c.d0 + 20)::timestamp + interval '14 hours') at time zone 'UTC', 'RECIBIDO', 'COLPORTOR',
          ((c.d0 + 21)::timestamp + interval '10 hours') at time zone 'UTC', null::text),
      (3, timestamptz '2026-11-12 14:00:00+00', case when c.idx % 2 = 0 then 'PENDIENTE_AUTORIZACION' else 'AUTORIZADO' end, 'COLPORTOR',
          case when c.idx % 2 = 0 then null else timestamptz '2026-11-13 10:00:00+00' end, null::text),
      (4, case when c.idx % 2 = 0 then timestamptz '2026-11-05 14:00:00+00' else timestamptz '2026-11-09 14:00:00+00' end,
          case when c.idx % 2 = 0 then 'RECHAZADO' else 'DESPACHADO' end, 'COLPORTOR',
          case when c.idx % 2 = 0 then timestamptz '2026-11-06 10:00:00+00' else timestamptz '2026-11-10 10:00:00+00' end,
          case when c.idx % 2 = 0 then 'Primero regularizá el depósito pendiente de la semana anterior' end)
    ) p(pn, fecha, estado, origen, decidido, motivo);
  -- Kit de arranque: los 26 títulos con precio de costo (el misionero no se pide).
  insert into tl_pit (ped, usr, uid, pn, prod, cant, precio)
  select pg_temp.ldid(16, c.idx * 10 + 1), c.idx, c.id, 1, pr.code, 6 + floor(pg_temp.lrnd('k' || c.idx || '-' || pr.code) * 7)::int, pr.compra
    from tl_vcol c
    cross join (select ('x' || lpad(right(p.id::text, 12), 16, '0'))::bit(64)::bigint::int as code, p.precio_base_compra::int as compra
                  from public.producto p
                 where p.id::text like '5eed0000-0000-7000-8005-%' and p.deleted_at is null and p.precio_base_compra is not null) pr;
  -- Reposición (tres títulos) y los dos pedidos restantes (dos títulos).
  insert into tl_pit (ped, usr, uid, pn, prod, cant, precio)
  select pg_temp.ldid(16, c.idx * 10 + q.pn), c.idx, c.id, q.pn, q.code, q.cant, p.precio_base_compra::int
    from tl_vcol c
    cross join lateral (values
      (2, 1 + c.idx % 10,          3 + floor(pg_temp.lrnd('r1' || c.idx) * 4)::int),
      (2, 1 + (c.idx + 3) % 10,    3 + floor(pg_temp.lrnd('r2' || c.idx) * 4)::int),
      (2, 12 + c.idx % 16,         3 + floor(pg_temp.lrnd('r3' || c.idx) * 4)::int),
      (3, 1 + c.idx % 6,           5 + floor(pg_temp.lrnd('r4' || c.idx) * 6)::int),
      (3, 12 + (c.idx + 5) % 16,   5 + floor(pg_temp.lrnd('r5' || c.idx) * 6)::int),
      (4, 1 + (c.idx + 2) % 6,     5 + floor(pg_temp.lrnd('r6' || c.idx) * 6)::int),
      (4, 12 + (c.idx + 9) % 16,   5 + floor(pg_temp.lrnd('r7' || c.idx) * 6)::int)) q(pn, code, cant)
    join public.producto p on p.id = pg_temp.bdid(5, q.code);
  update tl_ped p set monto = coalesce((select sum(i.cant::bigint * i.precio) from tl_pit i where i.ped = p.id), 0);

  insert into public.pedido_casa_editora (id, colportor_id, coordinador_id, fecha_pedido, estado, monto_total, origen, excede_limite,
                                          monto_autorizado, decidido_por, decidido_en, motivo_rechazo)
  select p.id, p.uid, case when p.decidido is not null then v_coord end, p.fecha, p.estado, p.monto, p.origen, false,
         case when p.estado in ('AUTORIZADO', 'DESPACHADO', 'RECIBIDO') then p.monto end,
         case when p.decidido is not null then v_coord end, p.decidido, p.motivo
    from tl_ped p on conflict do nothing;
  insert into public.pedido_item (id, pedido_id, producto_id, cantidad, precio_unitario, cantidad_recibida, colportor_id, cantidad_autorizada)
  select pg_temp.ldid(17, (i.usr * 10 + i.pn) * 100 + i.prod), i.ped, pg_temp.bdid(5, i.prod), i.cant, i.precio,
         case when p.estado = 'RECIBIDO' then i.cant end, i.uid,
         case when p.estado in ('AUTORIZADO', 'DESPACHADO', 'RECIBIDO') then i.cant end
    from tl_pit i join tl_ped p on p.id = i.ped on conflict do nothing;

  -- Lo recibido entra al stock (como en la tanda base: la fila de stock y el movimiento de entrada).
  insert into public.stock (id, usuario_id, producto_id, cantidad_disponible, cantidad_reservada)
  select pg_temp.ldid(25, i.usr * 100 + i.prod), i.uid, pg_temp.bdid(5, i.prod), sum(i.cant), 0
    from tl_pit i join tl_ped p on p.id = i.ped where p.estado = 'RECIBIDO'
   group by i.usr, i.uid, i.prod
  on conflict do nothing;
  insert into public.movimiento_stock (usuario_id, producto_id, tipo, cantidad, fecha, pedido_id)
  select i.uid, pg_temp.bdid(5, i.prod), 'ENTRADA_PEDIDO', i.cant, p.fecha + interval '1 day', p.id
    from tl_pit i join tl_ped p on p.id = i.ped where p.estado = 'RECIBIDO';

  -- 4d. Transferencias de stock entre los colportores de una misma ciudad (de a tres): un tercio por autorizar, un tercio
  --     autorizadas (mueven el stock y la deuda) y un tercio rechazadas.
  create temp table tl_tr (id uuid primary key, a int, b int, ua uuid, ub uuid, code int, cant int, estado text, fecha timestamptz, costo int, monto bigint) on commit drop;
  insert into tl_tr (id, a, b, ua, ub, code, cant, estado, fecha)
  select pg_temp.ldid(29, ca.idx * 100 + cb.idx), ca.idx, cb.idx, ca.id, cb.id, 1 + (ca.idx + cb.idx) % 10, 1 + (ca.idx * cb.idx) % 2,
         case when pg_temp.lrnd('ts' || ca.idx || '-' || cb.idx) < 0.34 then 'PENDIENTE_AUTORIZACION'
              when pg_temp.lrnd('ts' || ca.idx || '-' || cb.idx) < 0.67 then 'AUTORIZADO' else 'RECHAZADO' end,
         timestamptz '2026-11-08 14:00:00+00' + (floor(pg_temp.lrnd('tf' || ca.idx || '-' || cb.idx) * 8 * 24) || ' hours')::interval
    from tl_vcol ca join tl_vcol cb on (ca.idx - 1) / 3 = (cb.idx - 1) / 3 and ca.idx <> cb.idx;
  update tl_tr t set costo = (select p.precio_base_compra::int from public.producto p where p.id = pg_temp.bdid(5, t.code));
  update tl_tr set monto = cant::bigint * costo;
  insert into public.transferencia_stock (id, origen_id, destino_id, coordinador_id, fecha_solicitud, estado, monto_deuda, decidido_en, motivo_rechazo, solicitante_id)
  select t.id, t.ua, t.ub, case when t.estado <> 'PENDIENTE_AUTORIZACION' then v_coord end, t.fecha, t.estado,
         case when t.estado = 'AUTORIZADO' then t.monto end,
         case when t.estado <> 'PENDIENTE_AUTORIZACION' then t.fecha + interval '20 hours' end,
         case when t.estado = 'RECHAZADO' then 'Quien da necesita ese stock para sus visitas de la semana' end,
         t.ua
    from tl_tr t on conflict do nothing;
  insert into public.transferencia_item (id, transferencia_id, producto_id, cantidad, precio_unitario)
  select pg_temp.ldid(30, t.a * 100 + t.b), t.id, pg_temp.bdid(5, t.code), t.cant, case when t.estado = 'AUTORIZADO' then t.costo end
    from tl_tr t on conflict do nothing;
  update public.stock s set cantidad_disponible = s.cantidad_disponible - t.cant
    from tl_tr t where t.estado = 'AUTORIZADO' and s.usuario_id = t.ua and s.producto_id = pg_temp.bdid(5, t.code);
  update public.stock s set cantidad_disponible = s.cantidad_disponible + t.cant
    from tl_tr t where t.estado = 'AUTORIZADO' and s.usuario_id = t.ub and s.producto_id = pg_temp.bdid(5, t.code);
  insert into public.movimiento_stock (usuario_id, producto_id, tipo, cantidad, fecha, transferencia_id)
  select x.uid, pg_temp.bdid(5, t.code), x.tipo, t.cant, t.fecha + interval '20 hours', t.id
    from tl_tr t cross join lateral (values (t.ua, 'SALIDA_TRANSFERENCIA'), (t.ub, 'ENTRADA_TRANSFERENCIA')) x(uid, tipo)
   where t.estado = 'AUTORIZADO';

  -- 4e. Acompañamientos: el coordinador acompañó una de cada cuatro jornadas de cada colportor (todas las de los que
  --     tienen 26 o más); en una de cada doce también fue otro coordinador.
  insert into public.jornada_acompaniante (id, jornada_id, colportor_id, acompaniante_id, cargado_por, created_at)
  select pg_temp.ldid(33, j.n * 10 + q.k), j.id, j.colportor_id, q.acomp, q.acomp, j.fin + interval '2 hours'
    from (select jj.id, jj.colportor_id, jj.fin,
                 (row_number() over (order by jj.colportor_id, jj.inicio))::bigint as n,
                 (row_number() over (partition by jj.colportor_id order by jj.inicio))::int as rn,
                 (count(*) over (partition by jj.colportor_id))::int as tot
            from public.jornada jj
           where jj.colportor_id in (select id from tl_vcol) and jj.fin is not null and jj.deleted_at is null) j
    cross join lateral (values (1, v_acomp), (2, pg_temp.ldid(0, 1 + (j.rn / 4) % 24))) q(k, acomp)
   where (j.rn % 4 = 0 or j.tot >= 26) and (q.k = 1 or j.rn % 12 = 0)
  on conflict do nothing;

  -- 4f. Las cuentas de saldo, al día con lo que sumó esta carga: deuda (pedidos y transferencias menos lo pagado), depositado
  --     (depósitos confirmados), efectivo en mano (los cobros nuevos menos lo depositado que no se rechazó: lo que calcula efectivo_en_mano()).
  update public.cuenta_colportor cu
     set deuda_total = cu.deuda_total + x.d_deuda,
         dinero_depositado = cu.dinero_depositado + x.d_depositado,
         dinero_en_mano = greatest(cu.dinero_en_mano + x.d_cobrado - x.d_depositos, 0)
    from (
      select c.id as uid,
             coalesce((select sum(p.monto) from tl_ped p where p.uid = c.id and p.estado in ('AUTORIZADO', 'DESPACHADO', 'RECIBIDO')), 0)
             - coalesce((select sum(d.monto) from tl_dep d where d.uid = c.id and d.estado = 'VALIDADO'), 0)
             + coalesce((select sum(t.monto) from tl_tr t where t.ub = c.id and t.estado = 'AUTORIZADO'), 0)
             - coalesce((select sum(t.monto) from tl_tr t where t.ua = c.id and t.estado = 'AUTORIZADO'), 0) as d_deuda,
             coalesce((select sum(d.monto) from tl_dep d where d.uid = c.id and d.estado = 'VALIDADO'), 0) as d_depositado,
             coalesce((select sum(m.total) from tl_mv m where m.uid = c.id), 0) as d_cobrado,
             coalesce((select sum(d.monto) from tl_dep d where d.uid = c.id and d.estado <> 'RECHAZADO'), 0) as d_depositos
        from tl_vcol c
    ) x
   where cu.usuario_id = x.uid and cu.deleted_at is null;

  end if;  -- not v_base_hecha

  -- --------------------------------------------------------------------------------------------------
  -- 5. colportor.demo: su historia desde el 14/09 (la de las dos últimas semanas ya la dejó --colportor)
  -- --------------------------------------------------------------------------------------------------
  if v_cd is not null then
    -- 5a. Stock de los 26 títulos (un conteo para los diez de antes y el stock inicial de los nuevos).
    insert into public.movimiento_stock (id, usuario_id, producto_id, tipo, cantidad, fecha, motivo)
    select pg_temp.ldid(25, 90000000 + p.code), v_cd, pg_temp.bdid(5, p.code), 'AJUSTE_ENTRADA', case when p.code <= 10 then 60 else 20 end,
           timestamptz '2026-09-14 15:30:00+00', case when p.code <= 10 then 'CONTEO' else 'STOCK_INICIAL' end
      from generate_series(1, 27) p(code)
     where p.code <> 11 and exists (select 1 from public.producto pr where pr.id = pg_temp.bdid(5, p.code) and pr.deleted_at is null)
    on conflict do nothing;

    -- 5b. Jornadas (lunes a sábado, del 14/09 al 31/10) y visitas a las casas de Pocitos.
    create temp table tl_cj (id uuid primary key, dia date, dn int, inicio timestamptz, fin timestamptz, nvis int) on commit drop;
    insert into tl_cj (id, dia, dn, inicio, fin, nvis)
    select pg_temp.ldid(15, 90000000 + d.n), d.dia, d.n,
           (d.dia::timestamp + interval '12 hours 30 minutes' + (floor(pg_temp.lrnd('cji' || d.n) * 60) || ' minutes')::interval) at time zone 'UTC',
           (d.dia::timestamp + interval '12 hours 30 minutes' + (floor(pg_temp.lrnd('cji' || d.n) * 60) || ' minutes')::interval
              + ((200 + floor(pg_temp.lrnd('cjf' || d.n) * 100)) || ' minutes')::interval) at time zone 'UTC',
           5 + floor(pg_temp.lrnd('cjn' || d.n) * 5)::int
      from (select (row_number() over (order by g.dia))::int as n, g.dia
              from (select x.ts::date as dia from generate_series(timestamp '2026-09-14', timestamp '2026-10-31', interval '1 day') x(ts)) g
             where extract(dow from g.dia) <> 0 and pg_temp.lrnd('cjd' || g.dia) < 0.74) d;

    create temp table tl_cv (id uuid primary key, jor uuid, fecha timestamptz, esp bigint, res text) on commit drop;
    insert into tl_cv (id, jor, fecha, esp, res)
    select pg_temp.ldid(14, 90000000 + j.dn * 100 + k.k), j.id,
           j.inicio + ((k.k - 1) * 30 || ' minutes')::interval + (floor(pg_temp.lrnd('cvm' || j.id || k.k) * 8) || ' minutes')::interval,
           (100 + u.j) * 10 + case when u.j % 9 = 0 then 1 + floor(pg_temp.lrnd('cve' || j.id || k.k) * 3)::int else 1 end,
           case when pg_temp.lrnd('cvr' || j.id || k.k) < 0.27 then 'VENTA'
                when pg_temp.lrnd('cvr' || j.id || k.k) < 0.49 then 'ENTREVISTA'
                when pg_temp.lrnd('cvr' || j.id || k.k) < 0.63 then 'RECHAZO'
                else 'NO_CONTESTO' end
      from tl_cj j
      cross join lateral generate_series(1, j.nvis) k(k)
      cross join lateral (select 1 + floor(pg_temp.lrnd('cvu' || j.id || k.k) * 36)::int as j) u;
    delete from tl_cv v where not exists (select 1 from public.espacio e where e.id = pg_temp.bdid(13, v.esp));

    insert into public.espacio_persona (id, espacio_id, persona_id)
    select pg_temp.bdid(46, e.esp), pg_temp.bdid(13, e.esp), pg_temp.bdid(47, e.esp)
      from (select distinct esp from tl_cv) e
    on conflict do nothing;
    insert into public.jornada (id, colportor_id, inicio, fin, total_visitas, total_ventas)
    select j.id, v_cd, j.inicio, j.fin,
           (select count(*) from tl_cv v where v.jor = j.id), (select count(*) from tl_cv v where v.jor = j.id and v.res = 'VENTA')
      from tl_cj j on conflict do nothing;
    insert into public.visita (id, espacio_persona_id, fecha, tipo_resultado, colportor_id, jornada_id, espacio_id, entrevista_entrada, entrevista_salida)
    select v.id, pg_temp.bdid(46, v.esp), v.fecha, v.res, v_cd, v.jor, pg_temp.bdid(13, v.esp),
           case when v.res = 'ENTREVISTA' then v.fecha end,
           case when v.res = 'ENTREVISTA' then v.fecha + ((15 + floor(pg_temp.lrnd('cvs' || v.id) * 25)) || ' minutes')::interval end
      from tl_cv v on conflict do nothing;

    -- 5c. Ventas (precio general de ese día, los 26 títulos con más peso en los primeros) y cobros: un 35 % al contado,
    --     un 40 % deja la mitad y un 25 % queda sin cobrar (los que más tarde piden cuotas y cobranza).
    create temp table tl_cvt (id uuid primary key, vis uuid, fecha timestamptz, rn int, esp bigint, total int) on commit drop;
    insert into tl_cvt (id, vis, fecha, rn, esp)
    select pg_temp.ldid(10, 90000000 + v.rn), v.id, v.fecha + interval '12 minutes', v.rn, v.esp
      from (select t.*, (row_number() over (order by t.fecha, t.id))::int as rn from tl_cv t where t.res = 'VENTA') v;
    create temp table tl_ci (id uuid primary key, venta uuid, code int, cant int, precio int, subtotal int) on commit drop;
    insert into tl_ci (id, venta, code, cant, precio, subtotal)
    select pg_temp.ldid(11, 90000000 + row_number() over (order by x.rn, x.k)), x.id, x.code, x.cant, x.precio, x.cant * x.precio
      from (
        select b.id, b.rn, b.k, b.code,
               case when b.code in (7, 8, 20, 21, 22, 23) then 1 + floor(pg_temp.lrnd('cq' || b.id || b.k) * 3)::int else 1 end as cant,
               (select pgl.precio_venta from public.precio_general pgl
                 where pgl.deleted_at is null and pgl.producto_id = pg_temp.bdid(5, b.code)
                   and b.fecha::date between pgl.valido_desde and coalesce(pgl.valido_hasta, date '2999-12-31') limit 1) as precio
          from (select va.*, k.k,
                       case when c0.code = 11 then 12 else c0.code end as code
                  from tl_cvt va
                  cross join lateral generate_series(1, 1 + (pg_temp.lrnd('cn' || va.id) > 0.50)::int + (pg_temp.lrnd('cn2' || va.id) > 0.85)::int) k(k)
                  cross join lateral (select 1 + floor(power(pg_temp.lrnd('cp' || va.id || k.k), 1.6) * 27)::int as code) c0) b
      ) x
     where x.precio is not null;
    delete from tl_ci i using tl_ci j where i.venta = j.venta and i.code = j.code and i.id > j.id;
    update tl_cvt v set total = s.suma from (select i.venta, sum(i.subtotal)::int suma from tl_ci i group by i.venta) s where s.venta = v.id;
    delete from tl_cvt where total is null;

    insert into public.venta (id, espacio_persona_id, numero_talonario, monto_total, fecha, colportor_id, visita_id)
    select v.id, pg_temp.bdid(46, v.esp), 'CL-' || lpad(v.rn::text, 4, '0'), v.total, v.fecha, v_cd, v.vis from tl_cvt v on conflict do nothing;
    insert into public.venta_item (id, venta_id, producto_id, cantidad, precio_unitario, subtotal)
    select i.id, i.venta, pg_temp.bdid(5, i.code), i.cant, i.precio, i.subtotal from tl_ci i
     where exists (select 1 from tl_cvt v where v.id = i.venta) on conflict do nothing;

    create temp table tl_cc (id uuid primary key, venta uuid, monto int, fecha timestamptz) on commit drop;
    insert into tl_cc (id, venta, monto, fecha)
    select pg_temp.ldid(13, 90000000 + v.rn), v.id,
           case when pg_temp.lrnd('cce' || v.id) < 0.35 then v.total else (floor(v.total / 2 / 100) * 100)::int end,
           v.fecha + interval '5 minutes'
      from tl_cvt v where v.total > 0 and pg_temp.lrnd('cce' || v.id) < 0.75;
    delete from tl_cc where monto <= 0;
    insert into public.cobranza (id, venta_id, monto, medio, fecha)
    select c.id, c.venta, c.monto, 'EFECTIVO', c.fecha from tl_cc c on conflict do nothing;

    -- 5d. Entregas: cada renglón de venta sin entrega (las nuevas y las de las dos últimas semanas) sale en el momento o queda
    --     pendiente (la mayoría de lo vendido desde el 12/10).
    create temp table tl_ce (id uuid primary key, venta uuid, prod uuid, cant int, pend boolean, fecha timestamptz, esp uuid) on commit drop;
    insert into tl_ce (id, venta, prod, cant, pend, fecha, esp)
    select pg_temp.ldid(12, 90000000 + row_number() over (order by v.fecha, vi.id)), v.id, vi.producto_id, vi.cantidad,
           (v.fecha >= timestamptz '2026-10-12 00:00:00+00' and pg_temp.lrnd('cpe' || vi.id) < 0.60), v.fecha, v.espacio_persona_id
      from public.venta v
      join public.venta_item vi on vi.venta_id = v.id and vi.deleted_at is null
     where v.colportor_id = v_cd and v.deleted_at is null
       and not exists (select 1 from public.entrega e where e.venta_id = v.id);
    insert into public.entrega (id, venta_id, producto_id, cantidad, fecha_entrega, pendiente, fecha_prevista)
    select e.id, e.venta, e.prod, e.cant, case when not e.pend then e.fecha + interval '1 hour' end, e.pend,
           case when e.pend then e.fecha + ((3 + floor(pg_temp.lrnd('cpp' || e.id) * 6)) || ' days')::interval end
      from tl_ce e on conflict do nothing;

    -- 5e. Agenda: la cobranza de cada venta con saldo, cada entrega pendiente y las entrevistas de seguimiento. Las fechas
    --     anteriores al 18/11 quedan «no cumplidas» (el alta es del 17/11: AG003 no deja programar hacia atrás).
    insert into public.agenda (id, espacio_persona_id, tipo, fecha_programada, estado, colportor_id, espacio_id, venta_id, monto_previsto, created_at)
    select pg_temp.ldid(26, 90000000 + q.rn), q.ep, 'COBRANZA', q.fecha,
           case when q.fecha < timestamptz '2026-11-18 00:00:00+00' then 'NO_CUMPLIDA' else 'PROGRAMADA' end,
           v_cd, ep.espacio_id, q.venta, q.saldo::int, timestamptz '2026-11-17 12:00:00+00'
      from (select (row_number() over (order by v.fecha, v.id))::int rn, v.id as venta, v.espacio_persona_id as ep, v.fecha + interval '14 days' as fecha,
                   v.monto_total - coalesce((select sum(c.monto) from public.cobranza c where c.venta_id = v.id and c.anulado_at is null and c.deleted_at is null), 0) as saldo
              from public.venta v where v.colportor_id = v_cd and v.deleted_at is null) q
      join public.espacio_persona ep on ep.id = q.ep
     where q.saldo > 0
    on conflict do nothing;
    insert into public.agenda (id, espacio_persona_id, tipo, fecha_programada, estado, colportor_id, espacio_id, venta_id, entrega_id, created_at)
    select pg_temp.ldid(26, 91000000 + q.rn), q.esp, 'ENTREGA', q.prevista,
           case when q.prevista < timestamptz '2026-11-18 00:00:00+00' then 'NO_CUMPLIDA' else 'PROGRAMADA' end,
           v_cd, ep.espacio_id, q.venta, q.id, timestamptz '2026-11-17 12:00:00+00'
      from (select (row_number() over (order by e.fecha, e.id))::int rn, e.id, e.venta, e.esp,
                   e.fecha + ((3 + floor(pg_temp.lrnd('cpp' || e.id) * 6)) || ' days')::interval as prevista
              from tl_ce e where e.pend) q
      join public.espacio_persona ep on ep.id = q.esp
    on conflict do nothing;
    insert into public.agenda (id, espacio_persona_id, tipo, fecha_programada, estado, colportor_id, espacio_id, created_at)
    select pg_temp.ldid(26, 92000000 + q.rn), q.ep, 'ENTREVISTA',
           timestamptz '2026-11-18 13:00:00+00' + ((q.rn % 28) || ' days')::interval + ((q.rn % 5) || ' hours')::interval,
           'PROGRAMADA', v_cd, ep.espacio_id, timestamptz '2026-11-17 12:00:00+00'
      from (select (row_number() over (order by vi.fecha, vi.id))::int rn, vi.espacio_persona_id as ep
              from public.visita vi where vi.colportor_id = v_cd and vi.deleted_at is null and vi.tipo_resultado = 'ENTREVISTA') q
      join public.espacio_persona ep on ep.id = q.ep
    on conflict do nothing;

    -- 5f. Depósitos: cada día hábil deja el 60 % de lo cobrado en efectivo el día anterior (el lunes, desde el viernes). Mismos
    --     destinos y estados que en el volumen; los tickets desde el 10/11 esperan validación.
    create temp table tl_cd (id uuid primary key, k int, monto bigint, fecha timestamptz, destino text, estado text, ticket uuid) on commit drop;
    insert into tl_cd (id, k, monto, fecha, destino, estado, ticket)
    select pg_temp.ldid(27, 90000000 + s.k), s.k, s.monto, s.fecha, s.destino, s.estado,
           case when s.destino <> 'RETIRO_COORDINADOR' then pg_temp.ldid(28, 90000000 + s.k) end
      from (
        select (row_number() over (order by w.dia))::int as k, w.monto, w.fecha, w.destino,
               case when w.destino = 'RETIRO_COORDINADOR' then case when w.r2 < 0.30 then 'PENDIENTE' when w.r2 < 0.75 then 'VALIDADO' else 'RECHAZADO' end
                    when w.fecha > timestamptz '2026-11-09 23:59:00+00' then 'PENDIENTE'
                    when w.r2 < 0.20 then 'RECHAZADO' else 'VALIDADO' end as estado
          from (
            select x.dia, (floor(x.cash * 0.60 / 100) * 100)::bigint as monto,
                   (x.dia::timestamp + interval '15 hours' + (floor(pg_temp.lrnd('cdf' || x.dia) * 180) || ' minutes')::interval) at time zone 'UTC' as fecha,
                   case when pg_temp.lrnd('cdd' || x.dia) < 0.30 then 'BANCO' when pg_temp.lrnd('cdd' || x.dia) < 0.60 then 'OFICINA'
                        else 'RETIRO_COORDINADOR' end as destino,
                   pg_temp.lrnd('ces' || x.dia) as r2
              from (select g.dia,
                           coalesce((select sum(cb.monto) from public.cobranza cb join public.venta v on v.id = cb.venta_id
                                      where v.colportor_id = v_cd and cb.medio = 'EFECTIVO' and cb.anulado_at is null and cb.deleted_at is null
                                        and public.hoy_montevideo(cb.fecha) between g.dia - case when extract(dow from g.dia) = 1 then 3 else 1 end and g.dia - 1), 0) as cash
                      from (select x.ts::date as dia from generate_series(timestamp '2026-09-15', timestamp '2026-11-17', interval '1 day') x(ts)
                             where extract(dow from x.ts) between 1 and 5) g) x
          ) w
         where w.monto >= 5000 and w.fecha <= v_corte
      ) s;
    insert into public.ticket (id, usuario_id, tipo, subido_en, revisado_por, revisado_en, monto, fecha, estado, motivo_rechazo, campania_validadora_id)
    select d.ticket, v_cd, 'DEPOSITO', d.fecha + interval '20 minutes',
           case when d.estado <> 'PENDIENTE' then v_coord end, case when d.estado <> 'PENDIENTE' then d.fecha + interval '26 hours' end,
           d.monto, d.fecha, d.estado,
           case when d.estado = 'RECHAZADO' then 'No se lee el comprobante: sacá otra foto con buena luz.' end,
           case when d.estado <> 'PENDIENTE' then v_camp end
      from tl_cd d where d.ticket is not null
    on conflict do nothing;
    insert into public.deposito (id, colportor_id, monto, fecha, ticket_id, destino, concepto, campania_id, validado_en, validado_por,
                                 rechazado_en, rechazado_por, motivo_rechazo)
    select d.id, v_cd, d.monto, d.fecha, d.ticket, d.destino, 'CASA_EDITORA', null,
           case when d.estado = 'VALIDADO' then d.fecha + interval '27 hours' end, case when d.estado = 'VALIDADO' then v_coord end,
           case when d.estado = 'RECHAZADO' and d.destino = 'RETIRO_COORDINADOR' then d.fecha + interval '27 hours' end,
           case when d.estado = 'RECHAZADO' and d.destino = 'RETIRO_COORDINADOR' then v_coord end,
           case when d.estado = 'RECHAZADO' and d.destino = 'RETIRO_COORDINADOR' then 'El efectivo no coincide con lo declarado: contalo de nuevo.' end
      from tl_cd d on conflict do nothing;

    -- 5g. Pedidos a la casa editora: uno por día entre el 14/09 y el 4/11 (autorizados y despachados), tres por autorizar y dos
    --     rechazados. Los depósitos confirmados pagan los más viejos; el resto es la deuda con la casa que ve la app.
    create temp table tl_cp (id uuid primary key, pn int, fecha timestamptz, estado text, decidido timestamptz, motivo text, monto bigint default 0) on commit drop;
    insert into tl_cp (id, pn, fecha, estado, decidido, motivo)
    select pg_temp.ldid(16, 90000000 + g.pn), g.pn, f.fecha, f.estado,
           case when f.estado <> 'PENDIENTE_AUTORIZACION' then f.fecha + interval '20 hours' end,
           case when f.estado = 'RECHAZADO' then 'Primero regularizá el depósito pendiente de la semana anterior' end
      from generate_series(1, 49) g(pn)
      cross join lateral (select case when g.pn <= 44 then timestamptz '2026-09-14 14:00:00+00' + (floor((g.pn - 1) * 1.15) || ' days')::interval
                                      else timestamptz '2026-11-11 14:00:00+00' + (((g.pn - 45) % 5) || ' days')::interval end as fecha,
                                 case when g.pn <= 44 then case when g.pn % 2 = 1 then 'AUTORIZADO' else 'DESPACHADO' end
                                      when g.pn <= 47 then 'PENDIENTE_AUTORIZACION' else 'RECHAZADO' end as estado) f;
    create temp table tl_cpi (ped uuid, pn int, prod int, cant int, precio int) on commit drop;
    insert into tl_cpi (ped, pn, prod, cant, precio)
    select p.id, p.pn, q.code, 2 + floor(pg_temp.lrnd('cpq' || p.id || q.code) * 3)::int, pr.precio_base_compra::int
      from tl_cp p
      cross join lateral (values (1 + p.pn % 10), (1 + (p.pn + 4) % 10), (12 + p.pn % 16)) q(code)
      join public.producto pr on pr.id = pg_temp.bdid(5, q.code);
    update tl_cp p set monto = coalesce((select sum(i.cant::bigint * i.precio) from tl_cpi i where i.ped = p.id), 0);
    insert into public.pedido_casa_editora (id, colportor_id, coordinador_id, fecha_pedido, estado, monto_total, origen, excede_limite,
                                            monto_autorizado, decidido_por, decidido_en, motivo_rechazo)
    select p.id, v_cd, case when p.decidido is not null then v_coord end, p.fecha, p.estado, p.monto, 'COLPORTOR', false,
           case when p.estado in ('AUTORIZADO', 'DESPACHADO') then p.monto end,
           case when p.decidido is not null then v_coord end, p.decidido, p.motivo
      from tl_cp p on conflict do nothing;
    insert into public.pedido_item (id, pedido_id, producto_id, cantidad, precio_unitario, cantidad_recibida, colportor_id, cantidad_autorizada)
    select pg_temp.ldid(17, 90000000 + i.pn * 100 + i.prod), i.ped, pg_temp.bdid(5, i.prod), i.cant, i.precio, null, v_cd,
           case when p.estado in ('AUTORIZADO', 'DESPACHADO') then i.cant end
      from tl_cpi i join tl_cp p on p.id = i.ped on conflict do nothing;

    -- 5h. Su cuenta de saldo, al día con lo que sumó esta carga.
    update public.cuenta_colportor cu
       set deuda_total = cu.deuda_total
                         + coalesce((select sum(p.monto) from tl_cp p where p.estado in ('AUTORIZADO', 'DESPACHADO')), 0)
                         - coalesce((select sum(d.monto) from tl_cd d where d.estado = 'VALIDADO'), 0),
           dinero_depositado = cu.dinero_depositado + coalesce((select sum(d.monto) from tl_cd d where d.estado = 'VALIDADO'), 0),
           dinero_en_mano = greatest(cu.dinero_en_mano + coalesce((select sum(c.monto) from tl_cc c), 0)
                                     - coalesce((select sum(d.monto) from tl_cd d where d.estado <> 'RECHAZADO'), 0), 0),
           dinero_por_cobrar = cu.dinero_por_cobrar + coalesce((select sum(v.total) from tl_cvt v), 0) - coalesce((select sum(c.monto) from tl_cc c), 0)
     where cu.usuario_id = v_cd and cu.deleted_at is null;
  end if;

  raise notice 'Listas largas: % (catálogo, cuentas sueltas, barrios y colportores del volumen); %.',
    case when v_base_hecha then 'ya estaban cargadas' else 'cargadas ahora' end,
    case when v_cd is not null then 'se cargó la historia de colportor.demo'
         else 'colportor.demo no está lista (corré --colportor y repetí --listas: se le carga solo su historia)' end;
end
$listas$;
