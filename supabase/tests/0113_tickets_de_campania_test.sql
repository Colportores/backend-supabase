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
insert into auth.users (id, instance_id, aud, role, email, encrypted_password, confirmed_at, created_at, updated_at)
select pg_temp.u(s), '00000000-0000-0000-0000-000000000000',
       'authenticated', 'authenticated', 'tc13-' || s || '@example.com', 'x', now(), now(), now()
  from unnest(array['c1','c2','ad','f1','f2','b1','b2','b3','b4','b5','b6']) s;
update public.usuario u set nombre = x.n, apellido = x.a
  from (values ('b1','Ana','Alfa'), ('b2','Beto','Bravo'), ('b3','Carla','Cruz'),
               ('b4','Diego','Duarte'), ('b5','Elena','Eguren'), ('b6','Fede','Fuentes')) x(s, n, a)
 where u.id = pg_temp.u(x.s);
insert into public.usuario_rol (usuario_id, rol_id)
select pg_temp.u(x.s), r.id
  from (values ('c1','COORDINADOR'), ('c2','COORDINADOR'), ('ad','ADMIN'),
               ('b1','COLPORTOR'), ('b2','COLPORTOR'), ('b3','COLPORTOR'), ('b4','COLPORTOR'),
               ('b5','COLPORTOR'), ('b6','COLPORTOR')) x(s, codigo)
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
  (pg_temp.u('e3'), 'e3 tc13 terminada', 'VERANO', public.hoy_montevideo() - 90, public.hoy_montevideo() - 20, pg_temp.u('c1'));
insert into public.campania_ciudad (id, campania_id, ciudad_id) values
  (pg_temp.u('71'), pg_temp.u('e1'), pg_temp.u('91')),
  (pg_temp.u('72'), pg_temp.u('e1'), pg_temp.u('92'));
insert into public.zona (id, nombre, campania_ciudad_id, tipo_forma, color, poligono_geojson) values
  (pg_temp.u('d1'), 'Centro', pg_temp.u('71'), 'ESQUINAS', '#112233',
   '{"type":"Polygon","coordinates":[[[-56.19,-34.92],[-56.17,-34.92],[-56.17,-34.91],[-56.19,-34.91],[-56.19,-34.92]]]}'::jsonb),
  (pg_temp.u('d2'), 'Costa', pg_temp.u('72'), 'ESQUINAS', '#445566',
   '{"type":"Polygon","coordinates":[[[-56.19,-34.90],[-56.17,-34.90],[-56.17,-34.89],[-56.19,-34.89],[-56.19,-34.90]]]}'::jsonb);
insert into public.campania_colportor (campania_id, usuario_id, zona_id) values
  (pg_temp.u('e1'), pg_temp.u('b1'), pg_temp.u('d1')),
  (pg_temp.u('e1'), pg_temp.u('b2'), pg_temp.u('d2')),
  (pg_temp.u('e1'), pg_temp.u('b3'), null),
  (pg_temp.u('e1'), pg_temp.u('b4'), pg_temp.u('d1')),
  (pg_temp.u('e2'), pg_temp.u('b5'), null),
  (pg_temp.u('e3'), pg_temp.u('b1'), null);
update public.campania_colportor set deleted_at = now() where campania_id = pg_temp.u('e1') and usuario_id = pg_temp.u('b4');

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
   now() - interval '20 days', 10, null, null, null, null, 'VALIDADO', pg_temp.u('c1'), now() - interval '19 days', null, null);
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
select is(pg_temp.salen('e3'), 'a1,a4,aa', 'la campaña terminada trae los tickets de su inscripta (b1), sin el dado de baja');
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

select * from finish();
rollback;
