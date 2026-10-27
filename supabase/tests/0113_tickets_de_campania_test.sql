-- pgTAP · migración 0113 (backend-supabase#108, HU-COB-008/009, vista 29): tickets_de_campania().
--   1. La forma y los privilegios (solo authenticated, VOLATILE, DEFINER).
--   2. El permiso primero: sin JWT, anon, colportor, sin rol, rol vencido, coordinador de otra campaña (42501);
--      campaña inexistente (CZ001); el coordinador de la campaña, el ADMIN y una campaña terminada leen.
--   3. Qué tickets salen: los de los inscriptos (también el dado de baja), no los de otra campaña ni de
--      quien no está inscripto, no los dados de baja; cada campaña ve lo suyo.
--   4. Las columnas: colportor, ciudad de la zona actual («sin ciudad» si no hay), el depósito, la foto.
--   5. Los filtros (estado, colportor, ciudad, fechas) y su validación (22023).
--   6. El orden y la paginación.
--   7. Los datos límite: sin tickets, montos grandes, fecha vacía.
--   8. De qué campaña es un ticket (decisión del 26/10, #101 y #179): un ticket, una campaña, por la fecha del
--      ticket y la ventana de la inscripción (alta a baja; sin baja, fin + 15 días; gana la más nueva).
--      Lo prueban el historial, la lectura de la tabla por RLS (ticket_select) y campania_del_ticket().
begin;
select * from no_plan();

create or replace function pg_temp.actuar_como(p_uid uuid) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', json_build_object('sub', p_uid, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', p_uid::text, true);
  perform set_config('request.jwt.claim.role', 'authenticated', true);
  perform set_config('role', 'authenticated', true);
end $$;
create or replace function pg_temp.actuar_como_servidor() returns void language plpgsql as $$
begin
  perform set_config('role', 'postgres', true);
  perform set_config('request.jwt.claims', '', true);
  perform set_config('request.jwt.claim.sub', '', true);
  perform set_config('request.jwt.claim.role', '', true);
end $$;
create or replace function pg_temp.actuar_sin_jwt() returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', '', true);
  perform set_config('request.jwt.claim.sub', '', true);
  perform set_config('request.jwt.claim.role', '', true);
  perform set_config('role', 'authenticated', true);
end $$;
create or replace function pg_temp.actuar_como_anon() returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', json_build_object('role', 'anon')::text, true);
  perform set_config('request.jwt.claim.sub', '', true);
  perform set_config('request.jwt.claim.role', 'anon', true);
  perform set_config('role', 'anon', true);
end $$;

create or replace function pg_temp.u(p text) returns uuid language sql immutable as $$
  select ('01920000-0000-7000-8000-0000000113' || p)::uuid
$$;
-- Los ids de los tickets de la campaña e1, en el orden en que salen, como «t1,t2,…» (sufijo de dos letras).
create or replace function pg_temp.salen(p_camp text, p_extra text default '') returns text language plpgsql as $$
declare
  v text;
begin
  execute format($f$ select coalesce(string_agg(right(ticket_id::text, 2), ',' order by ord), '-')
                       from (select r.*, row_number() over () as ord
                               from public.tickets_de_campania(%L::uuid %s) r) x $f$,
                 pg_temp.u(p_camp), case when p_extra = '' then '' else ', ' || p_extra end)
    into v;
  return v;
end $$;

-- --- fixtures ------------------------------------------------------------------
-- Staff: c1 coordinador de e1; c2 coordinador de e2; ad ADMIN; x0 sin rol; x1 coordinador con el rol vencido.
-- Colportores: b1 Ana Alfa (zona Centro, ciudad k1), b2 Beto Bravo (zona Costa, ciudad k2), b3 Cruz (sin zona),
--   b4 Duarte (de baja en e1, con zona Centro), b5 Eguren (en e2), b6 Fuentes (en ninguna campaña).
--   Para la sección 8: b7 Gaspar y b8 Hugo pasaron de e4 (terminada, de c1) a e5 (en curso, de c2); b9 Ines se
--   fue de e4. Las inscripciones tienen alta anterior a los tickets (un ticket cuenta desde el alta).
insert into auth.users (id, instance_id, aud, role, email, encrypted_password, confirmed_at, created_at, updated_at)
select pg_temp.u(s), '00000000-0000-0000-0000-000000000000',
       'authenticated', 'authenticated', 'tc13-' || s || '@example.com', 'x', now(), now(), now()
  from unnest(array['c1','c2','ad','f1','f2','b1','b2','b3','b4','b5','b6','b7','b8','b9']) s;
update public.usuario u set nombre = x.n, apellido = x.a
  from (values ('b1','Ana','Alfa'), ('b2','Beto','Bravo'), ('b3','Carla','Cruz'),
               ('b4','Diego','Duarte'), ('b5','Elena','Eguren'), ('b6','Fede','Fuentes'),
               ('b7','Gaspar','Gomez'), ('b8','Hugo','Herrera'), ('b9','Ines','Ibarra')) x(s, n, a)
 where u.id = pg_temp.u(x.s);
insert into public.usuario_rol (usuario_id, rol_id)
select pg_temp.u(x.s), r.id
  from (values ('c1','COORDINADOR'), ('c2','COORDINADOR'), ('ad','ADMIN'),
               ('b1','COLPORTOR'), ('b2','COLPORTOR'), ('b3','COLPORTOR'), ('b4','COLPORTOR'),
               ('b5','COLPORTOR'), ('b6','COLPORTOR'), ('b7','COLPORTOR'), ('b8','COLPORTOR'), ('b9','COLPORTOR')) x(s, codigo)
  join public.rol r on r.codigo = x.codigo;
insert into public.usuario_rol (usuario_id, rol_id, valido_desde, valido_hasta)
select pg_temp.u('f2'), r.id, now() - interval '10 days', now() - interval '1 day'
  from public.rol r where r.codigo = 'COORDINADOR';

insert into public.pais (id, nombre, iso_code) values (pg_temp.u('f0'), 'Pais tc13', 'ZW');
insert into public.ciudad (id, nombre, departamento, pais_id, lat_centro, lon_centro, zoom_inicial) values
  (pg_temp.u('91'), 'Ciudad uno tc13', 'Departamento uno', pg_temp.u('f0'), -34.91, -56.18, 13),
  (pg_temp.u('92'), 'Ciudad dos tc13', 'Departamento dos', pg_temp.u('f0'), -34.91, -56.18, 13);
insert into public.campania (id, nombre, tipo, fecha_inicio, fecha_fin, coordinador_id) values
  (pg_temp.u('e1'), 'e1 tc13', 'VERANO', public.hoy_montevideo() - 30, public.hoy_montevideo() + 30, pg_temp.u('c1')),
  (pg_temp.u('e2'), 'e2 tc13', 'VERANO', public.hoy_montevideo() - 30, public.hoy_montevideo() + 30, pg_temp.u('c2')),
  (pg_temp.u('e3'), 'e3 tc13 terminada', 'VERANO', public.hoy_montevideo() - 90, public.hoy_montevideo() - 20, pg_temp.u('c1')),
  (pg_temp.u('e4'), 'e4 tc13 terminada', 'VERANO', public.hoy_montevideo() - 90, public.hoy_montevideo() - 40, pg_temp.u('c1')),
  (pg_temp.u('e5'), 'e5 tc13', 'VERANO', public.hoy_montevideo() - 30, public.hoy_montevideo() + 30, pg_temp.u('c2'));
insert into public.campania_ciudad (id, campania_id, ciudad_id) values
  (pg_temp.u('71'), pg_temp.u('e1'), pg_temp.u('91')),
  (pg_temp.u('72'), pg_temp.u('e1'), pg_temp.u('92'));
insert into public.zona (id, nombre, campania_ciudad_id, tipo_forma, color, poligono_geojson) values
  (pg_temp.u('d1'), 'Centro', pg_temp.u('71'), 'ESQUINAS', '#112233',
   '{"type":"Polygon","coordinates":[[[-56.19,-34.92],[-56.17,-34.92],[-56.17,-34.91],[-56.19,-34.91],[-56.19,-34.92]]]}'::jsonb),
  (pg_temp.u('d2'), 'Costa', pg_temp.u('72'), 'ESQUINAS', '#445566',
   '{"type":"Polygon","coordinates":[[[-56.19,-34.90],[-56.17,-34.90],[-56.17,-34.89],[-56.19,-34.89],[-56.19,-34.90]]]}'::jsonb);
-- `created_at` explícito: lo que un colportor hizo cuenta desde el día en que se inscribió en la campaña.
insert into public.campania_colportor (campania_id, usuario_id, zona_id, created_at) values
  (pg_temp.u('e1'), pg_temp.u('b1'), pg_temp.u('d1'), now() - interval '30 days'),
  (pg_temp.u('e1'), pg_temp.u('b2'), pg_temp.u('d2'), now() - interval '100 days'),
  (pg_temp.u('e1'), pg_temp.u('b3'), null, now() - interval '100 days'),
  (pg_temp.u('e1'), pg_temp.u('b4'), pg_temp.u('d1'), now() - interval '100 days'),
  (pg_temp.u('e2'), pg_temp.u('b5'), null, now() - interval '100 days'),
  (pg_temp.u('e3'), pg_temp.u('b1'), null, now() - interval '120 days'),
  (pg_temp.u('e4'), pg_temp.u('b7'), null, now() - interval '80 days'),
  (pg_temp.u('e5'), pg_temp.u('b7'), null, now() - interval '20 days'),
  (pg_temp.u('e4'), pg_temp.u('b8'), null, now() - interval '80 days'),
  (pg_temp.u('e5'), pg_temp.u('b8'), null, now() - interval '30 days'),
  (pg_temp.u('e4'), pg_temp.u('b9'), null, now() - interval '80 days');
update public.campania_colportor set deleted_at = now() where campania_id = pg_temp.u('e1') and usuario_id = pg_temp.u('b4');
update public.campania_colportor set deleted_at = now() - interval '50 days' where campania_id = pg_temp.u('e4') and usuario_id = pg_temp.u('b9');

-- Tickets (hoy = h). t1..: «subido_en» distinto en cada uno para fijar el orden.
--   a1 b1 PENDIENTE tarjeta, subido hace 3 días, fecha hace 3 días, con foto
--   a2 b2 PENDIENTE depósito, subido hace 5 días, fecha hace 5 días, sin foto (con depósito BANCO / ALQUILER)
--   a3 b3 PENDIENTE tarjeta, subido hace 1 día, fecha hace 1 día
--   a4 b1 VALIDADO, subido hace 10 días, fecha hace 10 días
--   a5 b2 RECHAZADO con motivo, subido hace 7 días, fecha hace 7 días
--   a6 b4 (de baja) PENDIENTE, subido hace 2 días
--   a7 b5 (campaña e2) PENDIENTE
--   a8 b6 (sin campaña) PENDIENTE
--   a9 b1 PENDIENTE dado de baja (deleted_at): no sale
--   aa b1 VALIDADO sin fecha (fecha null) subido hace 20 días: la fecha es la de subida
--   ae b1 PENDIENTE de hace 40 días: b1 se inscribió en e1 hace 30, así que es de e3 (la terminada)
--   (los de la sección 8, b7 a b9, van aparte)
insert into public.ticket (id, usuario_id, tipo, url_cloud, subido_en, monto, fecha, numero_autorizacion, tarjeta_tipo,
                           tarjeta_marca, estado, revisado_por, revisado_en, motivo_rechazo, deleted_at) values
  (pg_temp.u('a1'), pg_temp.u('b1'), 'COBRO_TARJETA', pg_temp.u('b1')::text || '/' || pg_temp.u('a1')::text || '.jpg',
   now() - interval '3 days', 480000, now() - interval '3 days', '004512', 'DEBITO', 'VISA', 'PENDIENTE', null, null, null, null),
  (pg_temp.u('a2'), pg_temp.u('b2'), 'DEPOSITO', null,
   now() - interval '5 days', 950000, now() - interval '5 days', 'OP-77', null, null, 'PENDIENTE', null, null, null, null),
  (pg_temp.u('a3'), pg_temp.u('b3'), 'COBRO_TARJETA', null,
   now() - interval '1 day', 120000, now() - interval '1 day', '000333', 'CREDITO', null, 'PENDIENTE', null, null, null, null),
  (pg_temp.u('a4'), pg_temp.u('b1'), 'COBRO_TARJETA', null,
   now() - interval '10 days', 300000, now() - interval '10 days', '000111', 'CREDITO', 'OCA', 'VALIDADO',
   pg_temp.u('c1'), now() - interval '9 days', null, null),
  (pg_temp.u('a5'), pg_temp.u('b2'), 'COBRO_TARJETA', null,
   now() - interval '7 days', 90000, now() - interval '7 days', '000222', 'DEBITO', null, 'RECHAZADO',
   pg_temp.u('c1'), now() - interval '6 days', 'No se lee el número de autorización', null),
  (pg_temp.u('a6'), pg_temp.u('b4'), 'DEPOSITO', null,
   now() - interval '2 days', 50000, now() - interval '2 days', null, null, null, 'PENDIENTE', null, null, null, null),
  (pg_temp.u('a7'), pg_temp.u('b5'), 'DEPOSITO', null,
   now() - interval '2 days', 70000, now() - interval '2 days', null, null, null, 'PENDIENTE', null, null, null, null),
  (pg_temp.u('a8'), pg_temp.u('b6'), 'DEPOSITO', null,
   now() - interval '2 days', 80000, now() - interval '2 days', null, null, null, 'PENDIENTE', null, null, null, null),
  (pg_temp.u('a9'), pg_temp.u('b1'), 'DEPOSITO', null,
   now() - interval '4 days', 60000, now() - interval '4 days', null, null, null, 'PENDIENTE', null, null, null, now()),
  (pg_temp.u('aa'), pg_temp.u('b1'), 'OTRO', null,
   now() - interval '20 days', 10, null, null, null, null, 'VALIDADO', pg_temp.u('c1'), now() - interval '19 days', null, null),
  (pg_temp.u('ae'), pg_temp.u('b1'), 'DEPOSITO', null,
   now() - interval '40 days', 25000, now() - interval '40 days', null, null, null, 'PENDIENTE', null, null, null, null);
insert into public.deposito (colportor_id, monto, destino, concepto, ticket_id)
values (pg_temp.u('b2'), 950000, 'BANCO', 'ALQUILER', pg_temp.u('a2'));

-- ---------------------------------------------------------------------------
-- 1. La forma y los privilegios
-- ---------------------------------------------------------------------------
select has_function('public', 'tickets_de_campania', array['uuid', 'text', 'uuid', 'uuid', 'date', 'date', 'integer', 'integer'],
                    'existe tickets_de_campania');
select is((select prosecdef from pg_proc where oid = 'public.tickets_de_campania(uuid, text, uuid, uuid, date, date, integer, integer)'::regprocedure),
          true, 'es SECURITY DEFINER');
select is((select provolatile from pg_proc where oid = 'public.tickets_de_campania(uuid, text, uuid, uuid, date, date, integer, integer)'::regprocedure),
          'v', 'y VOLATILE (llama a lanzar_motivo_mapa)');
select is((select proconfig from pg_proc where oid = 'public.tickets_de_campania(uuid, text, uuid, uuid, date, date, integer, integer)'::regprocedure),
          array['search_path=""'], 'con search_path vacío');
select is(has_function_privilege('authenticated', 'public.tickets_de_campania(uuid, text, uuid, uuid, date, date, integer, integer)', 'execute'),
          true, 'authenticated la ejecuta');
select is(has_function_privilege('anon', 'public.tickets_de_campania(uuid, text, uuid, uuid, date, date, integer, integer)', 'execute'),
          false, 'anon no');
select is(has_function_privilege('service_role', 'public.tickets_de_campania(uuid, text, uuid, uuid, date, date, integer, integer)', 'execute'),
          false, 'service_role tampoco: el panel entra con el JWT del coordinador');
select is((select pg_get_function_result('public.tickets_de_campania(uuid, text, uuid, uuid, date, date, integer, integer)'::regprocedure)),
          'TABLE(ticket_id uuid, colportor_id uuid, nombre text, apellido text, de_baja boolean, ciudad_id uuid, ciudad_nombre text, departamento text, tipo text, monto bigint, fecha timestamp with time zone, numero_autorizacion text, tarjeta_tipo text, tarjeta_marca text, estado text, motivo_rechazo text, subido_en timestamp with time zone, revisado_por uuid, revisado_en timestamp with time zone, tiene_foto boolean, foto_ruta text, deposito_destino text, deposito_concepto text)',
          'la forma de la respuesta');

-- Las funciones de la regla «un ticket, una campaña»: DEFINER con search_path vacío; la interna no la ejecuta nadie
-- con JWT; las dos de la política, solo authenticated.
select is((select count(*)::int
             from pg_proc p where p.pronamespace = 'public'::regnamespace
              and p.proname in ('campania_del_ticket', 'puede_ver_ticket_de', 'puede_ver_foto_de_ticket')
              and p.prosecdef and p.proconfig = array['search_path=""']),
          3, 'las tres son SECURITY DEFINER con search_path vacío');
select is(has_function_privilege('authenticated', 'public.campania_del_ticket(uuid, timestamptz)', 'execute'), false,
          'campania_del_ticket es interna: authenticated no la ejecuta');
select is(has_function_privilege('anon', 'public.puede_ver_ticket_de(uuid, timestamptz)', 'execute'), false, 'anon no ejecuta puede_ver_ticket_de');
select is(has_function_privilege('authenticated', 'public.puede_ver_ticket_de(uuid, timestamptz)', 'execute'), true,
          'authenticated sí (la llama la política ticket_select)');
select is(has_function_privilege('anon', 'public.puede_ver_foto_de_ticket(text)', 'execute'), false, 'anon no ejecuta puede_ver_foto_de_ticket');
select is(has_function_privilege('authenticated', 'public.puede_ver_foto_de_ticket(text)', 'execute'), true,
          'authenticated sí (la llama la política tickets_ver del bucket)');

-- ---------------------------------------------------------------------------
-- 2. El permiso
-- ---------------------------------------------------------------------------
select throws_ok($$ select * from public.tickets_de_campania('01920000-0000-7000-8000-0000000113e1') $$,
  '42501', null, 'sin JWT (el servidor) falla');
select pg_temp.actuar_sin_jwt();
select throws_ok($$ select * from public.tickets_de_campania('01920000-0000-7000-8000-0000000113e1') $$,
  '42501', null, 'authenticated sin sesión falla');
select pg_temp.actuar_como_anon();
select throws_ok($$ select * from public.tickets_de_campania('01920000-0000-7000-8000-0000000113e1') $$,
  '42501', null, 'anon no la llama');
select pg_temp.actuar_como(pg_temp.u('b1'));
select throws_ok($$ select * from public.tickets_de_campania('01920000-0000-7000-8000-0000000113e1') $$,
  '42501', null, 'un colportor inscripto en la campaña no ve los tickets de sus compañeros');
select pg_temp.actuar_como(pg_temp.u('f1'));
select throws_ok($$ select * from public.tickets_de_campania('01920000-0000-7000-8000-0000000113e1') $$,
  '42501', null, 'un usuario sin ningún rol no la llama');
select pg_temp.actuar_como(pg_temp.u('f2'));
select throws_ok($$ select * from public.tickets_de_campania('01920000-0000-7000-8000-0000000113e1') $$,
  '42501', null, 'con el rol de coordinador vencido falla');
select pg_temp.actuar_como(pg_temp.u('c2'));
select throws_ok($$ select * from public.tickets_de_campania('01920000-0000-7000-8000-0000000113e1') $$,
  '42501', 'Solo el coordinador de la campaña o un administrador puede ver sus tickets. Entrá con la cuenta del coordinador de esta campaña.',
  'el coordinador de otra campaña no ve estos tickets, y el mensaje dice quién puede');
select throws_ok($$ select * from public.tickets_de_campania('01920000-0000-7000-8000-0000000113ff') $$,
  'CZ001', null, 'una campaña que no existe: CZ001 para el coordinador');
select pg_temp.actuar_como(pg_temp.u('b1'));
select throws_ok($$ select * from public.tickets_de_campania('01920000-0000-7000-8000-0000000113ff') $$,
  '42501', null, 'y 42501 para un colportor (no se entera de qué campañas existen)');

select pg_temp.actuar_como(pg_temp.u('c1'));
select ok((select count(*) from public.tickets_de_campania(pg_temp.u('e1'))) > 0, 'el coordinador de la campaña la lee');
select pg_temp.actuar_como(pg_temp.u('ad'));
select ok((select count(*) from public.tickets_de_campania(pg_temp.u('e1'))) > 0, 'el ADMIN también');
select pg_temp.actuar_como(pg_temp.u('c1'));
select lives_ok($$ select * from public.tickets_de_campania('01920000-0000-7000-8000-0000000113e3') $$,
  'una campaña terminada se lee (para cerrar lo que quedó por validar)');

-- ---------------------------------------------------------------------------
-- 3. Qué tickets salen
-- ---------------------------------------------------------------------------
select pg_temp.actuar_como(pg_temp.u('c1'));
-- Pendientes primero (el que espera hace más, primero): a2 (5 días), a1 (3), a6 (2), a3 (1); después el más nuevo
-- primero: a5 (7 días), a4 (10), aa (20).
select is(pg_temp.salen('e1'), 'a2,a1,a6,a3,a5,a4,aa',
          'salen los de los inscriptos (también el dado de baja), pendientes primero; no el de otra campaña, el de quien no está inscripto ni el dado de baja');
select pg_temp.actuar_como(pg_temp.u('c2'));
select is(pg_temp.salen('e2'), 'a7', 'la otra campaña ve solo lo suyo');
select pg_temp.actuar_como(pg_temp.u('ad'));
select is(pg_temp.salen('e1'), 'a2,a1,a6,a3,a5,a4,aa', 'el ADMIN ve lo mismo que el coordinador');
select pg_temp.actuar_como(pg_temp.u('c1'));
select is(pg_temp.salen('e3'), 'ae', 'la campaña terminada trae los tickets de su ventana (b1 hasta que entró a e1), no los de e1 ni el dado de baja');
select pg_temp.actuar_como(pg_temp.u('ad'));

-- Un ticket que se da de baja deja de salir; el servidor puede dar de baja.
select pg_temp.actuar_como_servidor();
update public.ticket set deleted_at = now() where id = pg_temp.u('a3');
select pg_temp.actuar_como(pg_temp.u('c1'));
select is(pg_temp.salen('e1'), 'a2,a1,a6,a5,a4,aa', 'un ticket dado de baja deja de salir');
select pg_temp.actuar_como_servidor();
update public.ticket set deleted_at = null where id = pg_temp.u('a3');

-- ---------------------------------------------------------------------------
-- 4. Las columnas
-- ---------------------------------------------------------------------------
select pg_temp.actuar_como(pg_temp.u('c1'));
select is((select row(r.colportor_id, r.nombre, r.apellido, r.de_baja, r.ciudad_id, r.ciudad_nombre, r.departamento)::text
             from public.tickets_de_campania(pg_temp.u('e1')) r where r.ticket_id = pg_temp.u('a1')),
          row(pg_temp.u('b1'), 'Ana', 'Alfa', false, pg_temp.u('91'), 'Ciudad uno tc13', 'Departamento uno')::text,
          'a1: el colportor y la ciudad de su zona');
select is((select row(r.tipo, r.monto, r.numero_autorizacion, r.tarjeta_tipo, r.tarjeta_marca, r.estado, r.motivo_rechazo)::text
             from public.tickets_de_campania(pg_temp.u('e1')) r where r.ticket_id = pg_temp.u('a1')),
          row('COBRO_TARJETA', 480000::bigint, '004512', 'DEBITO', 'VISA', 'PENDIENTE', null::text)::text,
          'a1: lo que dice el ticket');
select is((select r.fecha from public.tickets_de_campania(pg_temp.u('e1')) r where r.ticket_id = pg_temp.u('a1')),
          (select t.fecha from public.ticket t where t.id = pg_temp.u('a1')), 'a1: su fecha');
select is((select row(r.tiene_foto, r.foto_ruta)::text from public.tickets_de_campania(pg_temp.u('e1')) r where r.ticket_id = pg_temp.u('a1')),
          row(true, pg_temp.u('b1')::text || '/' || pg_temp.u('a1')::text || '.jpg')::text,
          'a1: tiene foto y la ruta para pedir la URL firmada');
select is((select row(r.tiene_foto, r.foto_ruta)::text from public.tickets_de_campania(pg_temp.u('e1')) r where r.ticket_id = pg_temp.u('a2')),
          row(false, null::text)::text, 'a2: sin foto (venció o todavía no llegó)');
select is((select row(r.deposito_destino, r.deposito_concepto)::text from public.tickets_de_campania(pg_temp.u('e1')) r where r.ticket_id = pg_temp.u('a2')),
          row('BANCO', 'ALQUILER')::text, 'a2: el depósito al que pertenece');
select is((select row(r.deposito_destino, r.deposito_concepto)::text from public.tickets_de_campania(pg_temp.u('e1')) r where r.ticket_id = pg_temp.u('a1')),
          row(null::text, null::text)::text, 'a1: no es de un depósito');
select is((select row(r.ciudad_id, r.ciudad_nombre, r.departamento)::text from public.tickets_de_campania(pg_temp.u('e1')) r where r.ticket_id = pg_temp.u('a3')),
          row(null::uuid, null::text, null::text)::text, 'a3: b3 no tiene zona: sin ciudad (null)');
select is((select row(r.nombre, r.apellido, r.de_baja, r.ciudad_nombre)::text from public.tickets_de_campania(pg_temp.u('e1')) r where r.ticket_id = pg_temp.u('a6')),
          row('Diego', 'Duarte', true, null::text)::text,
          'a6: el colportor dado de baja sigue figurando, marcado, y sin ciudad (su inscripción ya no cuenta)');
select is((select row(r.estado, r.motivo_rechazo, r.revisado_por, (r.revisado_en is not null))::text
             from public.tickets_de_campania(pg_temp.u('e1')) r where r.ticket_id = pg_temp.u('a5')),
          row('RECHAZADO', 'No se lee el número de autorización', pg_temp.u('c1'), true)::text,
          'a5: rechazado con su motivo y quién lo revisó');
select is((select row(r.estado, r.revisado_por)::text from public.tickets_de_campania(pg_temp.u('e1')) r where r.ticket_id = pg_temp.u('a4')),
          row('VALIDADO', pg_temp.u('c1'))::text, 'a4: validado por c1');
select is((select r.ciudad_nombre from public.tickets_de_campania(pg_temp.u('e1')) r where r.ticket_id = pg_temp.u('a2')),
          'Ciudad dos tc13', 'a2: b2 está en la zona Costa, de la ciudad dos');

-- La ciudad sigue a la zona actual: si b1 pasa a la zona Costa, sus tickets cuentan para la ciudad dos.
select pg_temp.actuar_como_servidor();
update public.campania_colportor set zona_id = pg_temp.u('d2') where campania_id = pg_temp.u('e1') and usuario_id = pg_temp.u('b1');
select pg_temp.actuar_como(pg_temp.u('c1'));
select is((select r.ciudad_nombre from public.tickets_de_campania(pg_temp.u('e1')) r where r.ticket_id = pg_temp.u('a1')),
          'Ciudad dos tc13', 'si b1 cambia de zona, el ticket sigue a su zona actual');
select pg_temp.actuar_como_servidor();
update public.campania_colportor set zona_id = pg_temp.u('d1') where campania_id = pg_temp.u('e1') and usuario_id = pg_temp.u('b1');
-- Una zona dada de baja: sin ciudad.
update public.zona set deleted_at = now() where id = pg_temp.u('d1');
select pg_temp.actuar_como(pg_temp.u('c1'));
select is((select r.ciudad_nombre from public.tickets_de_campania(pg_temp.u('e1')) r where r.ticket_id = pg_temp.u('a1')),
          null, 'una zona dada de baja: sin ciudad (no hay donde ponerlo)');
select pg_temp.actuar_como_servidor();
update public.zona set deleted_at = null where id = pg_temp.u('d1');

-- ---------------------------------------------------------------------------
-- 5. Los filtros
-- ---------------------------------------------------------------------------
select pg_temp.actuar_como(pg_temp.u('c1'));
select is(pg_temp.salen('e1', $$ p_estado => 'PENDIENTE' $$), 'a2,a1,a6,a3', 'estado PENDIENTE');
select is(pg_temp.salen('e1', $$ p_estado => 'VALIDADO' $$), 'a4,aa', 'estado VALIDADO');
select is(pg_temp.salen('e1', $$ p_estado => 'RECHAZADO' $$), 'a5', 'estado RECHAZADO');
select is(pg_temp.salen('e1', format($$ p_colportor_id => %L $$, pg_temp.u('b1'))), 'a1,a4,aa', 'por colportor');
select is(pg_temp.salen('e1', format($$ p_colportor_id => %L $$, pg_temp.u('b4'))), 'a6', 'por colportor dado de baja');
select is(pg_temp.salen('e1', format($$ p_colportor_id => %L $$, pg_temp.u('b5'))), '-', 'por un colportor que no es de la campaña: nada');
select is(pg_temp.salen('e1', format($$ p_ciudad_id => %L $$, pg_temp.u('91'))), 'a1,a4,aa', 'por ciudad uno (b1; b4 de baja no cuenta en ninguna)');
select is(pg_temp.salen('e1', format($$ p_ciudad_id => %L $$, pg_temp.u('92'))), 'a2,a5', 'por ciudad dos (b2)');
select is(pg_temp.salen('e1', $$ p_desde => public.hoy_montevideo() - 3 $$), 'a1,a6,a3',
          'desde hace 3 días (el día cuenta entero): a1, a6 y a3; a1 es del borde');
select is(pg_temp.salen('e1', $$ p_hasta => public.hoy_montevideo() - 7 $$), 'a5,a4,aa', 'hasta hace 7 días (el día cuenta entero)');
select is(pg_temp.salen('e1', $$ p_desde => public.hoy_montevideo() - 7, p_hasta => public.hoy_montevideo() - 3 $$), 'a2,a1,a5',
          'un rango');
select is(pg_temp.salen('e1', $$ p_desde => public.hoy_montevideo() - 30, p_hasta => public.hoy_montevideo() - 15 $$), 'aa',
          'sin fecha en el ticket, cuenta el día en que se subió');
select is(pg_temp.salen('e1', $$ p_estado => 'PENDIENTE', p_desde => public.hoy_montevideo() - 3 $$), 'a1,a6,a3', 'filtros combinados');
select is(pg_temp.salen('e1', $$ p_estado => 'VALIDADO', p_ciudad_id => null, p_colportor_id => null $$), 'a4,aa', 'los filtros en null no filtran');

select throws_ok($$ select * from public.tickets_de_campania('01920000-0000-7000-8000-0000000113e1', 'PAGADO') $$,
  '22023', 'El estado del ticket es PENDIENTE, VALIDADO o RECHAZADO.', 'un estado que no existe: 22023');
select throws_ok($$ select * from public.tickets_de_campania('01920000-0000-7000-8000-0000000113e1', null, null, null, '2026-10-02', '2026-10-01') $$,
  '22023', 'La fecha desde no puede ser posterior a la fecha hasta.', 'desde después de hasta: 22023');
select throws_ok($$ select * from public.tickets_de_campania('01920000-0000-7000-8000-0000000113e1', p_limite => 0) $$,
  '22023', 'El límite de tickets es de 1 a 500.', 'límite 0: 22023');
select throws_ok($$ select * from public.tickets_de_campania('01920000-0000-7000-8000-0000000113e1', p_limite => 501) $$,
  '22023', null, 'límite 501: 22023');
select throws_ok($$ select * from public.tickets_de_campania('01920000-0000-7000-8000-0000000113e1', p_limite => null) $$,
  '22023', null, 'límite null: 22023');
select throws_ok($$ select * from public.tickets_de_campania('01920000-0000-7000-8000-0000000113e1', p_desplazamiento => -1) $$,
  '22023', 'El desplazamiento no puede ser negativo.', 'desplazamiento negativo: 22023');
select lives_ok($$ select * from public.tickets_de_campania('01920000-0000-7000-8000-0000000113e1', p_limite => 500) $$, 'límite 500 sí');

-- ---------------------------------------------------------------------------
-- 6. Orden y paginación
-- ---------------------------------------------------------------------------
select is(pg_temp.salen('e1', 'p_limite => 3'), 'a2,a1,a6', 'la primera página de 3');
select is(pg_temp.salen('e1', 'p_limite => 3, p_desplazamiento => 3'), 'a3,a5,a4', 'la segunda');
select is(pg_temp.salen('e1', 'p_limite => 3, p_desplazamiento => 6'), 'aa', 'la última, con uno solo');
select is(pg_temp.salen('e1', 'p_limite => 3, p_desplazamiento => 9'), '-', 'más allá del final, vacía');

-- ---------------------------------------------------------------------------
-- 7. Datos límite
-- ---------------------------------------------------------------------------
select pg_temp.actuar_como_servidor();
insert into public.ticket (id, usuario_id, tipo, subido_en, monto, fecha, estado)
values (pg_temp.u('ab'), pg_temp.u('b3'), 'DEPOSITO', now() - interval '30 days', 9007199254740993, now() - interval '30 days', 'PENDIENTE');
select pg_temp.actuar_como(pg_temp.u('c1'));
select is((select r.monto from public.tickets_de_campania(pg_temp.u('e1')) r where r.ticket_id = pg_temp.u('ab')),
          9007199254740993::bigint, 'un monto más grande que lo que un double guarda se devuelve entero (bigint)');
select is(pg_temp.salen('e1', $$ p_estado => 'PENDIENTE' $$), 'ab,a2,a1,a6,a3', 'y el pendiente más viejo va primero');
select pg_temp.actuar_como(pg_temp.u('c2'));
select is(pg_temp.salen('e2', $$ p_estado => 'VALIDADO' $$), '-', 'una campaña sin tickets validados: vacía, sin error');

-- ---------------------------------------------------------------------------
-- 8. De qué campaña es un ticket: un ticket, una campaña (decisión del 26/10, #101 y #179)
-- ---------------------------------------------------------------------------
-- Gaspar (b7): e4 (de c1, terminó hace 40 días; alta hace 80) y desde hace 20 días e5 (de c2).
-- Hugo (b8): e4 (alta hace 80) y e5 desde hace 30 días. Ines (b9): e4 y se fue hace 50 días.
-- La ventana de e4 va hasta el fin + 15 = hace 25 días (sin baja) y la de Ines hasta su baja (hace 50).
--   31 b7 hace 60 días                      -> e4 (la de entonces)
--   32 b7 hace 2 días                       -> e5
--   33 b7 con fecha de hace 40 días (el último día de e4) y subido ayer: sube tarde pero es de e4
--   34 b8 hace 28 días: cae en la ventana de e4 (hasta hace 25) Y en la de e5 (desde hace 30) -> gana e5, la más nueva
--   35 b8 hace 35 días                      -> e4 (e5 todavía no)
--   36 b8 hace 10 días                      -> e5 (la ventana de e4 ya cerró)
--   37 b9 hace 60 días, antes de su baja    -> e4 (lo que subió antes de irse sigue por validar)
--   38 b9 hace 45 días, después de su baja  -> de ninguna campaña
select pg_temp.actuar_como_servidor();
insert into public.ticket (id, usuario_id, tipo, subido_en, monto, fecha, estado) values
  (pg_temp.u('37'), pg_temp.u('b9'), 'DEPOSITO', now() - interval '61 days', 1000, now() - interval '60 days', 'PENDIENTE'),
  (pg_temp.u('31'), pg_temp.u('b7'), 'DEPOSITO', now() - interval '60 days', 1000, now() - interval '60 days', 'PENDIENTE'),
  (pg_temp.u('38'), pg_temp.u('b9'), 'DEPOSITO', now() - interval '45 days', 1000, now() - interval '45 days', 'PENDIENTE'),
  (pg_temp.u('35'), pg_temp.u('b8'), 'DEPOSITO', now() - interval '35 days', 1000, now() - interval '35 days', 'PENDIENTE'),
  (pg_temp.u('34'), pg_temp.u('b8'), 'DEPOSITO', now() - interval '28 days', 1000, now() - interval '28 days', 'PENDIENTE'),
  (pg_temp.u('36'), pg_temp.u('b8'), 'DEPOSITO', now() - interval '10 days', 1000, now() - interval '10 days', 'PENDIENTE'),
  (pg_temp.u('32'), pg_temp.u('b7'), 'DEPOSITO', now() - interval '2 days', 1000, now() - interval '2 days', 'PENDIENTE'),
  (pg_temp.u('33'), pg_temp.u('b7'), 'DEPOSITO', now() - interval '1 day', 1000, now() - interval '40 days', 'PENDIENTE');

-- El historial: cada coordinadora ve lo de su campaña, ni uno de la otra.
select pg_temp.actuar_como(pg_temp.u('c1'));
select is(pg_temp.salen('e4'), '37,31,35,33',
          'e4 (c1): lo de e4 de cada uno, también el que sube tarde (33) y lo de antes de la baja (37); nada de e5 ni el 34 que cae en las dos');
select pg_temp.actuar_como(pg_temp.u('c2'));
select is(pg_temp.salen('e5'), '34,36,32',
          'e5 (c2): lo de e5; el 34 cae en las dos ventanas y es de la inscripción más nueva');
select is(pg_temp.salen('e5', format($$ p_colportor_id => %L $$, pg_temp.u('b9'))), '-',
          'e5 no tiene a Ines, ni el 38 que no es de ninguna campaña');
select pg_temp.actuar_como(pg_temp.u('ad'));
select is(pg_temp.salen('e4'), '37,31,35,33', 'el ADMIN ve en e4 lo mismo que c1');
select is(pg_temp.salen('e5'), '34,36,32', 'y en e5 lo mismo que c2');
select pg_temp.actuar_como(pg_temp.u('c1'));
select is(pg_temp.salen('e4', format($$ p_colportor_id => %L $$, pg_temp.u('b9'))), '37',
          'el 38 (después de la baja de Ines) no sale en ninguna campaña');
-- El borde del plazo: el último día de e4 + 15 (hace 25 días) es de e4; al día siguiente ya no es de nadie.
select pg_temp.actuar_como_servidor();
select is(public.campania_del_ticket(pg_temp.u('b7'), now() - interval '25 days'), pg_temp.u('e4'),
          'el día fin + 15 todavía es de la campaña');
select is(public.campania_del_ticket(pg_temp.u('b7'), now() - interval '24 days'), null,
          'el día siguiente ya no es de e4 y todavía no de e5 (b7 entró a e5 hace 20 días): de ninguna');
select is(public.campania_del_ticket(pg_temp.u('b7'), now() - interval '20 days'), pg_temp.u('e5'),
          'desde el alta en e5 es de e5');
select is(public.campania_del_ticket(pg_temp.u('b7'), now() - interval '21 days'), null,
          'un día antes del alta en e5, de ninguna');
select is(public.campania_del_ticket(pg_temp.u('b7'), now() - interval '81 days'), null,
          'antes del alta en e4, de ninguna');
select is(public.campania_del_ticket(pg_temp.u('b8'), now() - interval '28 days'), pg_temp.u('e5'), 'solapado: la más nueva');
select is(public.campania_del_ticket(pg_temp.u('b8'), now() - interval '35 days'), pg_temp.u('e4'), 'b8 antes de e5: e4');
select is(public.campania_del_ticket(pg_temp.u('b9'), now() - interval '51 days'), pg_temp.u('e4'), 'b9 antes de la baja: e4');
select is(public.campania_del_ticket(pg_temp.u('b9'), now() - interval '49 days'), null, 'b9 después de la baja: de ninguna');
select is(public.campania_del_ticket(pg_temp.u('b7'), null), null, 'sin fecha: de ninguna');
select is(public.campania_del_ticket(pg_temp.u('b6'), now()), null, 'quien no está inscripto en nada: de ninguna');
-- Un hueco (tramos_afuera) no cuenta: b9 tiene uno entre hace 70 y 65 días (antes de su baja, hace 50).
update public.campania_colportor set tramos_afuera = array[tstzrange(now() - interval '70 days', now() - interval '65 days')]
 where campania_id = pg_temp.u('e4') and usuario_id = pg_temp.u('b9');
select is(public.campania_del_ticket(pg_temp.u('b9'), now() - interval '68 days'), null, 'dentro de un hueco de la inscripción: de ninguna');
select is(public.campania_del_ticket(pg_temp.u('b9'), now() - interval '60 days'), pg_temp.u('e4'), 'pasado el hueco: de e4');
update public.campania_colportor set tramos_afuera = '{}'
 where campania_id = pg_temp.u('e4') and usuario_id = pg_temp.u('b9');

-- La lectura de la tabla (RLS): la coordinadora de otra campaña, aunque haya coordinado al colportor, no ve el ticket.
select pg_temp.actuar_como(pg_temp.u('c1'));
select is((select coalesce(string_agg(right(id::text, 2), ',' order by id), '-') from public.ticket
            where usuario_id in (pg_temp.u('b7'), pg_temp.u('b8'), pg_temp.u('b9'))),
          '31,33,35,37', 'c1 lee por RLS solo los tickets de e4 de Gaspar, Hugo e Ines (no el 32, 34, 36 ni el 38)');
select pg_temp.actuar_como(pg_temp.u('c2'));
select is((select coalesce(string_agg(right(id::text, 2), ',' order by id), '-') from public.ticket
            where usuario_id in (pg_temp.u('b7'), pg_temp.u('b8'), pg_temp.u('b9'))),
          '32,34,36', 'c2 lee por RLS solo los de e5');
select pg_temp.actuar_como(pg_temp.u('ad'));
select is((select count(*)::int from public.ticket where usuario_id in (pg_temp.u('b7'), pg_temp.u('b8'), pg_temp.u('b9'))),
          8, 'el ADMIN lee los 8, también el que no es de ninguna campaña');
select pg_temp.actuar_como(pg_temp.u('b7'));
select is((select coalesce(string_agg(right(id::text, 2), ',' order by id), '-') from public.ticket), '31,32,33',
          'Gaspar lee los suyos (los tres), sea cual sea la campaña');
select pg_temp.actuar_como(pg_temp.u('b9'));
select is((select coalesce(string_agg(right(id::text, 2), ',' order by id), '-') from public.ticket), '37,38',
          'e Ines los dos suyos, también el que no es de ninguna campaña');
select pg_temp.actuar_como(pg_temp.u('c2'));
select is((select count(*)::int from public.ticket where id = pg_temp.u('31')), 0,
          'c2 pidiendo el 31 por id: no hay fila');

-- Si Gaspar se da de baja de e5 ayer, lo que subió antes (el 32, de hace 2 días) sigue siendo de e5: la baja corta
-- solo lo posterior.
select pg_temp.actuar_como_servidor();
update public.campania_colportor set deleted_at = now() - interval '1 day'
 where campania_id = pg_temp.u('e5') and usuario_id = pg_temp.u('b7');
select pg_temp.actuar_como(pg_temp.u('c2'));
select is(pg_temp.salen('e5', format($$ p_colportor_id => %L $$, pg_temp.u('b7'))), '32',
          'Gaspar se dio de baja de e5 ayer: el 32 (de hace 2 días) sigue siendo de e5');
select pg_temp.actuar_como_servidor();
select is(public.campania_del_ticket(pg_temp.u('b7'), now()), null,
          'y lo de hoy, después de la baja, no es de ninguna campaña');

-- Una baja DESPUÉS del fin + 15 días: la ventana de una inscripción con baja va hasta la baja, no hasta el fin + 15.
-- (Ines se va de e4 hace 10 días, cuando e4 ya había terminado hace 30.)
select pg_temp.actuar_como_servidor();
update public.campania_colportor set deleted_at = now() - interval '10 days'
 where campania_id = pg_temp.u('e4') and usuario_id = pg_temp.u('b9');
select is(public.campania_del_ticket(pg_temp.u('b9'), now() - interval '20 days'), pg_temp.u('e4'),
          'con baja posterior al fin + 15, lo hecho hasta la baja es de la campaña');
select is(public.campania_del_ticket(pg_temp.u('b9'), now() - interval '9 days'), null, 'y lo posterior a la baja, de ninguna');
-- Una campaña dada de baja no tiene tickets.
update public.campania set deleted_at = now() where id = pg_temp.u('e4');
select is(public.campania_del_ticket(pg_temp.u('b8'), now() - interval '35 days'), null,
          'una campaña dada de baja no se queda con tickets');
update public.campania set deleted_at = null where id = pg_temp.u('e4');

-- puede_ver_ticket_de(), llamada directa por cada quien (la usan ticket_select y la foto del bucket).
-- El ticket mirado: lo que Gaspar (b7) hizo hace 60 días, de e4 (la campaña de c1).
select pg_temp.actuar_como(pg_temp.u('b7'));
select is(public.puede_ver_ticket_de(pg_temp.u('b7'), now() - interval '60 days'), true, 'la dueña lo ve');
select is(public.puede_ver_ticket_de(pg_temp.u('b7'), now() - interval '90 days'), true,
          'la dueña ve también el que no es de ninguna campaña');
select is(public.puede_ver_ticket_de(pg_temp.u('b8'), now() - interval '60 days'), false, 'y no el de otro colportor');
select pg_temp.actuar_como(pg_temp.u('ad'));
select is(public.puede_ver_ticket_de(pg_temp.u('b7'), now() - interval '60 days'), true, 'el ADMIN lo ve');
select is(public.puede_ver_ticket_de(pg_temp.u('b7'), now() - interval '90 days'), true, 'también el que no es de ninguna campaña');
select pg_temp.actuar_como(pg_temp.u('c1'));
select is(public.puede_ver_ticket_de(pg_temp.u('b7'), now() - interval '60 days'), true, 'c1, coordinador de e4, lo ve');
select is(public.puede_ver_ticket_de(pg_temp.u('b7'), now() - interval '10 days'), false,
          'pero no el de e5 de la misma persona, aunque coordine a Gaspar en e4');
select is(public.puede_ver_ticket_de(pg_temp.u('b7'), now() - interval '90 days'), false, 'ni el que no es de ninguna campaña');
select pg_temp.actuar_como(pg_temp.u('c2'));
select is(public.puede_ver_ticket_de(pg_temp.u('b7'), now() - interval '60 days'), false, 'c2 no ve el de e4');
select is(public.puede_ver_ticket_de(pg_temp.u('b7'), null), false, 'sin fecha, no se ve (no hay a qué campaña pertenecer)');
-- Quien figura como coordinador de la campaña pero con el rol vencido (f2) no lo ve.
select pg_temp.actuar_como_servidor();
update public.campania set coordinador_id = pg_temp.u('f2') where id = pg_temp.u('e5');
select pg_temp.actuar_como(pg_temp.u('f2'));
select is(public.puede_ver_ticket_de(pg_temp.u('b8'), now() - interval '10 days'), false,
          'con el rol de coordinador vencido, aunque figure como coordinador de la campaña, no lo ve');
select pg_temp.actuar_como_servidor();
update public.campania set coordinador_id = pg_temp.u('c2') where id = pg_temp.u('e5');

select * from finish();
rollback;
