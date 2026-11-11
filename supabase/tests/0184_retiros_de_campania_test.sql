-- pgTAP · migración 0184 (backend-supabase#261, HU-COB-008, vista 29): retiros_de_campania().
--   1. La forma y los privilegios (solo authenticated, VOLATILE, DEFINER, search_path vacío).
--   2. El permiso primero: sin JWT, anon, colportor, sin rol, rol vencido, coordinador de otra campaña (42501);
--      campaña inexistente (CZ001); los coordinadores de la campaña (los dos), el ADMIN y una campaña terminada leen.
--   3. Qué retiros salen: los RETIRO_COORDINADOR de los inscriptos (también el dado de baja); no los depósitos con
--      ticket, los de otra campaña, los de quien no está inscripto ni los dados de baja; la campaña del retiro es su
--      campania_id o la de la inscripción de su fecha (la misma que usa confirmar_retiro).
--   4. Las columnas: colportor, ciudad de la zona actual, estado, motivo, quién y cuándo resolvió, anulado.
--   5. Los filtros (estado, colportor, ciudad, fechas) y su validación (22023).
--   6. El orden (por confirmar primero, el más viejo antes) y la paginación.
--   7. Confirmar y rechazar con las RPC de la vista cambian el estado que se lee acá.
--   8. Datos límite: sin retiros, monto grande.
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
  select ('01920000-0000-7000-8000-0000000184' || p)::uuid
$$;
-- Los ids de los retiros de una campaña, en el orden en que salen, como «r1,r2,…» (sufijo de dos letras).
create or replace function pg_temp.salen(p_camp text, p_extra text default '') returns text language plpgsql as $$
declare
  v text;
begin
  execute format($f$ select coalesce(string_agg(right(deposito_id::text, 2), ',' order by ord), '-')
                       from (select r.*, row_number() over () as ord
                               from public.retiros_de_campania(%L::uuid %s) r) x $f$,
                 pg_temp.u(p_camp), case when p_extra = '' then '' else ', ' || p_extra end)
    into v;
  return v;
end $$;
-- --- fixtures ------------------------------------------------------------------
-- Staff: c1 coordinador de e1; c3 segundo coordinador de e1 (campania_coordinador, 0174); c2 coordinador de e2; ad
-- ADMIN; f1 sin rol; f2 coordinador con el rol vencido.
-- Colportores: b1 Ana Alfa (zona Centro, ciudad 91), b2 Beto Bravo (zona Costa, ciudad 92), b3 Carla Cruz (sin zona),
--   b4 Diego Duarte (de baja en e1, con zona Centro), b5 Elena Eguren (en e2), b6 Fede Fuentes (en ninguna campaña).
--   b1 estuvo antes en e3 (terminada): se inscribió en e1 hace 30 días.
insert into auth.users (id, instance_id, aud, role, email, encrypted_password, confirmed_at, created_at, updated_at)
select pg_temp.u(s), '00000000-0000-0000-0000-000000000000',
       'authenticated', 'authenticated', 'rt184-' || s || '@example.com', 'x', now(), now(), now()
  from unnest(array['c1','c2','c3','ad','f1','f2','b1','b2','b3','b4','b5','b6']) s;
update public.usuario u set nombre = x.n, apellido = x.a
  from (values ('b1','Ana','Alfa'), ('b2','Beto','Bravo'), ('b3','Carla','Cruz'),
               ('b4','Diego','Duarte'), ('b5','Elena','Eguren'), ('b6','Fede','Fuentes')) x(s, n, a)
 where u.id = pg_temp.u(x.s);
insert into public.usuario_rol (usuario_id, rol_id)
select pg_temp.u(x.s), r.id
  from (values ('c1','COORDINADOR'), ('c2','COORDINADOR'), ('c3','COORDINADOR'), ('ad','ADMIN'),
               ('b1','COLPORTOR'), ('b2','COLPORTOR'), ('b3','COLPORTOR'), ('b4','COLPORTOR'),
               ('b5','COLPORTOR'), ('b6','COLPORTOR')) x(s, codigo)
  join public.rol r on r.codigo = x.codigo;
insert into public.usuario_rol (usuario_id, rol_id, valido_desde, valido_hasta)
select pg_temp.u('f2'), r.id, now() - interval '10 days', now() - interval '1 day'
  from public.rol r where r.codigo = 'COORDINADOR';

insert into public.pais (id, nombre, iso_code) values (pg_temp.u('f0'), 'Pais rt184', 'ZU');
insert into public.ciudad (id, nombre, departamento, pais_id, lat_centro, lon_centro, zoom_inicial) values
  (pg_temp.u('91'), 'Ciudad uno rt184', 'Departamento uno', pg_temp.u('f0'), -34.91, -56.18, 13),
  (pg_temp.u('92'), 'Ciudad dos rt184', 'Departamento dos', pg_temp.u('f0'), -34.91, -56.18, 13);
insert into public.campania (id, nombre, tipo, fecha_inicio, fecha_fin, coordinador_id) values
  (pg_temp.u('e1'), 'e1 rt184', 'VERANO', public.hoy_montevideo() - 30, public.hoy_montevideo() + 30, pg_temp.u('c1')),
  (pg_temp.u('e2'), 'e2 rt184', 'VERANO', public.hoy_montevideo() - 30, public.hoy_montevideo() + 30, pg_temp.u('c2')),
  (pg_temp.u('e3'), 'e3 rt184 terminada', 'VERANO', public.hoy_montevideo() - 90, public.hoy_montevideo() - 20, pg_temp.u('c1'));
insert into public.campania_coordinador (campania_id, usuario_id, created_at)
values (pg_temp.u('e1'), pg_temp.u('c3'), clock_timestamp());
insert into public.campania_ciudad (id, campania_id, ciudad_id) values
  (pg_temp.u('71'), pg_temp.u('e1'), pg_temp.u('91')),
  (pg_temp.u('72'), pg_temp.u('e1'), pg_temp.u('92'));
insert into public.zona (id, nombre, campania_ciudad_id, tipo_forma, color, poligono_geojson) values
  (pg_temp.u('d1'), 'Centro', pg_temp.u('71'), 'ESQUINAS', '#112233',
   '{"type":"Polygon","coordinates":[[[-56.19,-34.92],[-56.17,-34.92],[-56.17,-34.91],[-56.19,-34.91],[-56.19,-34.92]]]}'::jsonb),
  (pg_temp.u('d2'), 'Costa', pg_temp.u('72'), 'ESQUINAS', '#445566',
   '{"type":"Polygon","coordinates":[[[-56.19,-34.90],[-56.17,-34.90],[-56.17,-34.89],[-56.19,-34.89],[-56.19,-34.90]]]}'::jsonb);
insert into public.campania_colportor (campania_id, usuario_id, zona_id, created_at) values
  (pg_temp.u('e1'), pg_temp.u('b1'), pg_temp.u('d1'), now() - interval '30 days'),
  (pg_temp.u('e1'), pg_temp.u('b2'), pg_temp.u('d2'), now() - interval '100 days'),
  (pg_temp.u('e1'), pg_temp.u('b3'), null, now() - interval '100 days'),
  (pg_temp.u('e1'), pg_temp.u('b4'), pg_temp.u('d1'), now() - interval '100 days'),
  (pg_temp.u('e2'), pg_temp.u('b5'), null, now() - interval '100 days'),
  (pg_temp.u('e3'), pg_temp.u('b1'), null, now() - interval '120 days');
update public.campania_colportor set deleted_at = now() where campania_id = pg_temp.u('e1') and usuario_id = pg_temp.u('b4');

-- Un depósito con ticket (BANCO): no es un retiro, sale por tickets_de_campania y no acá.
insert into public.ticket (id, usuario_id, tipo, subido_en, monto, fecha, estado)
values (pg_temp.u('aa'), pg_temp.u('b1'), 'DEPOSITO', now() - interval '4 days', 70000, now() - interval '4 days', 'PENDIENTE');

-- Retiros (hoy = h). created_at distinto en cada uno para fijar el orden.
--   r1 b1 por confirmar, llegó hace 3 días, CASA_EDITORA
--   r2 b2 por confirmar, llegó hace 5 días, ALQUILER de e1
--   r3 b3 por confirmar, llegó hace 1 día
--   r4 b1 confirmado por c1, llegó hace 10 días
--   r5 b2 rechazado por c1 con motivo, llegó hace 7 días
--   r6 b4 (de baja) por confirmar, llegó hace 2 días
--   r7 b5 (e2) por confirmar
--   r8 b6 (sin campaña) por confirmar
--   r9 b1 por confirmar dado de baja: no sale
--   rb b1 por confirmar de hace 40 días: b1 entró a e1 hace 30, así que es de e3 (la terminada)
--   rc b1 ALQUILER de hace 2 días con campania_id e3: su campaña es la que dice, no la de la fecha
--   rd b2 ALQUILER de e1 confirmado por c3 y después anulado (devuelto), llegó hace 12 días
--   da b1 BANCO con el ticket aa: no sale
insert into public.deposito (id, colportor_id, monto, fecha, ticket_id, destino, concepto, campania_id, created_at, deleted_at,
                             validado_en, validado_por, rechazado_en, rechazado_por, motivo_rechazo, anulado_at, anulado_por) values
  (pg_temp.u('21'), pg_temp.u('b1'), 40000, now() - interval '3 days', null, 'RETIRO_COORDINADOR', 'CASA_EDITORA', null,
   now() - interval '3 days', null, null, null, null, null, null, null, null),
  (pg_temp.u('22'), pg_temp.u('b2'), 25000, now() - interval '5 days', null, 'RETIRO_COORDINADOR', 'ALQUILER', pg_temp.u('e1'),
   now() - interval '5 days', null, null, null, null, null, null, null, null),
  (pg_temp.u('23'), pg_temp.u('b3'), 12000, now() - interval '1 day', null, 'RETIRO_COORDINADOR', 'CASA_EDITORA', null,
   now() - interval '1 day', null, null, null, null, null, null, null, null),
  (pg_temp.u('24'), pg_temp.u('b1'), 30000, now() - interval '10 days', null, 'RETIRO_COORDINADOR', 'CASA_EDITORA', null,
   now() - interval '10 days', null, now() - interval '9 days', pg_temp.u('c1'), null, null, null, null, null),
  (pg_temp.u('25'), pg_temp.u('b2'), 9000, now() - interval '7 days', null, 'RETIRO_COORDINADOR', 'CASA_EDITORA', null,
   now() - interval '7 days', null, null, null, now() - interval '6 days', pg_temp.u('c1'), 'Recibí 5.000, no 9.000', null, null),
  (pg_temp.u('26'), pg_temp.u('b4'), 5000, now() - interval '2 days', null, 'RETIRO_COORDINADOR', 'CASA_EDITORA', null,
   now() - interval '2 days', null, null, null, null, null, null, null, null),
  (pg_temp.u('27'), pg_temp.u('b5'), 7000, now() - interval '2 days', null, 'RETIRO_COORDINADOR', 'CASA_EDITORA', null,
   now() - interval '2 days', null, null, null, null, null, null, null, null),
  (pg_temp.u('28'), pg_temp.u('b6'), 8000, now() - interval '2 days', null, 'RETIRO_COORDINADOR', 'CASA_EDITORA', null,
   now() - interval '2 days', null, null, null, null, null, null, null, null),
  (pg_temp.u('29'), pg_temp.u('b1'), 6000, now() - interval '4 days', null, 'RETIRO_COORDINADOR', 'CASA_EDITORA', null,
   now() - interval '4 days', now(), null, null, null, null, null, null, null),
  (pg_temp.u('2b'), pg_temp.u('b1'), 2500, now() - interval '40 days', null, 'RETIRO_COORDINADOR', 'CASA_EDITORA', null,
   now() - interval '40 days', null, null, null, null, null, null, null, null),
  (pg_temp.u('2c'), pg_temp.u('b1'), 3500, now() - interval '2 days', null, 'RETIRO_COORDINADOR', 'ALQUILER', pg_temp.u('e3'),
   now() - interval '2 days' + interval '1 minute', null, null, null, null, null, null, null, null),
  (pg_temp.u('2d'), pg_temp.u('b2'), 15000, now() - interval '12 days', null, 'RETIRO_COORDINADOR', 'ALQUILER', pg_temp.u('e1'),
   now() - interval '12 days', null, now() - interval '11 days', pg_temp.u('c3'), null, null, null,
   now() - interval '8 days', pg_temp.u('c3')),
  (pg_temp.u('da'), pg_temp.u('b1'), 70000, now() - interval '4 days', pg_temp.u('aa'), 'BANCO', 'CASA_EDITORA', null,
   now() - interval '4 days', null, null, null, null, null, null, null, null);

-- ---------------------------------------------------------------------------
-- 1. La forma y los privilegios
-- ---------------------------------------------------------------------------
select has_function('public', 'retiros_de_campania', array['uuid', 'text', 'uuid', 'uuid', 'date', 'date', 'integer', 'integer'],
                    'existe retiros_de_campania');
select is((select prosecdef from pg_proc where oid = 'public.retiros_de_campania(uuid, text, uuid, uuid, date, date, integer, integer)'::regprocedure),
          true, 'es SECURITY DEFINER');
select is((select provolatile from pg_proc where oid = 'public.retiros_de_campania(uuid, text, uuid, uuid, date, date, integer, integer)'::regprocedure),
          'v', 'y VOLATILE (llama a lanzar_motivo_mapa)');
select is((select proconfig from pg_proc where oid = 'public.retiros_de_campania(uuid, text, uuid, uuid, date, date, integer, integer)'::regprocedure),
          array['search_path=""'], 'con search_path vacío');
select is(has_function_privilege('authenticated', 'public.retiros_de_campania(uuid, text, uuid, uuid, date, date, integer, integer)', 'execute'),
          true, 'authenticated la ejecuta');
select is(has_function_privilege('anon', 'public.retiros_de_campania(uuid, text, uuid, uuid, date, date, integer, integer)', 'execute'),
          false, 'anon no');
select is(has_function_privilege('service_role', 'public.retiros_de_campania(uuid, text, uuid, uuid, date, date, integer, integer)', 'execute'),
          false, 'service_role tampoco: el panel entra con el JWT del coordinador');
select is((select pg_get_function_result('public.retiros_de_campania(uuid, text, uuid, uuid, date, date, integer, integer)'::regprocedure)),
          'TABLE(deposito_id uuid, colportor_id uuid, nombre text, apellido text, de_baja boolean, ciudad_id uuid, ciudad_nombre text, departamento text, monto bigint, fecha timestamp with time zone, concepto text, estado text, motivo_rechazo text, subido_en timestamp with time zone, revisado_por uuid, revisado_en timestamp with time zone, anulado_en timestamp with time zone)',
          'la forma de la respuesta');
-- Solo suma (R1): tickets_de_campania sigue con su forma.
select is((select pg_get_function_result('public.tickets_de_campania(uuid, text, uuid, uuid, date, date, integer, integer)'::regprocedure)),
          'TABLE(ticket_id uuid, colportor_id uuid, nombre text, apellido text, de_baja boolean, ciudad_id uuid, ciudad_nombre text, departamento text, tipo text, monto bigint, fecha timestamp with time zone, numero_autorizacion text, tarjeta_tipo text, tarjeta_marca text, estado text, motivo_rechazo text, subido_en timestamp with time zone, revisado_por uuid, revisado_en timestamp with time zone, tiene_foto boolean, foto_ruta text, deposito_destino text, deposito_concepto text)',
          'tickets_de_campania no cambia');

-- ---------------------------------------------------------------------------
-- 2. El permiso
-- ---------------------------------------------------------------------------
select throws_ok($$ select * from public.retiros_de_campania('01920000-0000-7000-8000-0000000184e1') $$,
  '42501', null, 'sin JWT (el servidor) falla');
select pg_temp.actuar_sin_jwt();
select throws_ok($$ select * from public.retiros_de_campania('01920000-0000-7000-8000-0000000184e1') $$,
  '42501', null, 'authenticated sin sesión falla');
select pg_temp.actuar_como_anon();
select throws_ok($$ select * from public.retiros_de_campania('01920000-0000-7000-8000-0000000184e1') $$,
  '42501', null, 'anon no la llama');
select pg_temp.actuar_como(pg_temp.u('b1'));
select throws_ok($$ select * from public.retiros_de_campania('01920000-0000-7000-8000-0000000184e1') $$,
  '42501', null, 'un colportor inscripto en la campaña no ve los retiros de sus compañeros');
select pg_temp.actuar_como(pg_temp.u('f1'));
select throws_ok($$ select * from public.retiros_de_campania('01920000-0000-7000-8000-0000000184e1') $$,
  '42501', null, 'un usuario sin ningún rol no la llama');
select pg_temp.actuar_como(pg_temp.u('f2'));
select throws_ok($$ select * from public.retiros_de_campania('01920000-0000-7000-8000-0000000184e1') $$,
  '42501', null, 'con el rol de coordinador vencido falla');
select pg_temp.actuar_como(pg_temp.u('c2'));
select throws_ok($$ select * from public.retiros_de_campania('01920000-0000-7000-8000-0000000184e1') $$,
  '42501', 'Solo el coordinador de la campaña o un administrador puede ver sus retiros. Entrá con la cuenta del coordinador de esta campaña.',
  'el coordinador de otra campaña no ve estos retiros, y el mensaje dice quién puede');
select throws_ok($$ select * from public.retiros_de_campania('01920000-0000-7000-8000-0000000184ff') $$,
  'CZ001', null, 'una campaña que no existe: CZ001 para el coordinador');
select pg_temp.actuar_como(pg_temp.u('b1'));
select throws_ok($$ select * from public.retiros_de_campania('01920000-0000-7000-8000-0000000184ff') $$,
  '42501', null, 'y 42501 para un colportor (no se entera de qué campañas existen)');

select pg_temp.actuar_como(pg_temp.u('c1'));
select ok((select count(*) from public.retiros_de_campania(pg_temp.u('e1'))) > 0, 'el coordinador de la campaña la lee');
select pg_temp.actuar_como(pg_temp.u('c3'));
select ok((select count(*) from public.retiros_de_campania(pg_temp.u('e1'))) > 0, 'el segundo coordinador de la campaña también (0175)');
select pg_temp.actuar_como(pg_temp.u('ad'));
select ok((select count(*) from public.retiros_de_campania(pg_temp.u('e1'))) > 0, 'y el ADMIN');
select pg_temp.actuar_como(pg_temp.u('c1'));
select lives_ok($$ select * from public.retiros_de_campania('01920000-0000-7000-8000-0000000184e3') $$,
  'una campaña terminada se lee (para cerrar lo que quedó por confirmar)');

-- ---------------------------------------------------------------------------
-- 3. Qué retiros salen
-- ---------------------------------------------------------------------------
select pg_temp.actuar_como(pg_temp.u('c1'));
-- Por confirmar primero (el que espera hace más, primero): 22 (5 días), 21 (3), 26 (2), 23 (1); después el más nuevo
-- primero: 25 (7 días), 24 (10), 2d (12).
select is(pg_temp.salen('e1'), '22,21,26,23,25,24,2d',
          'salen los retiros de los inscriptos (también el dado de baja), por confirmar primero; no el depósito con ticket, '
          'el de otra campaña, el de quien no está inscripto ni el dado de baja');
select pg_temp.actuar_como(pg_temp.u('c3'));
select is(pg_temp.salen('e1'), '22,21,26,23,25,24,2d', 'el segundo coordinador ve lo mismo');
select pg_temp.actuar_como(pg_temp.u('ad'));
select is(pg_temp.salen('e1'), '22,21,26,23,25,24,2d', 'el ADMIN ve lo mismo');
select pg_temp.actuar_como(pg_temp.u('c2'));
select is(pg_temp.salen('e2'), '27', 'la otra campaña ve solo lo suyo');
select pg_temp.actuar_como(pg_temp.u('c1'));
select is(pg_temp.salen('e3'), '2b,2c',
          'la terminada trae el retiro de su ventana (b1 antes de entrar a e1) y el de alquiler que dice ser de e3');
select is((select count(*)::int from public.tickets_de_campania(pg_temp.u('e1')) t where t.ticket_id = pg_temp.u('aa')), 1,
          'el depósito con ticket sigue saliendo por tickets_de_campania');

-- Un retiro que se da de baja deja de salir.
select pg_temp.actuar_como_servidor();
update public.deposito set deleted_at = now() where id = pg_temp.u('23');
select pg_temp.actuar_como(pg_temp.u('c1'));
select is(pg_temp.salen('e1'), '22,21,26,25,24,2d', 'un retiro dado de baja deja de salir');
select pg_temp.actuar_como_servidor();
update public.deposito set deleted_at = null where id = pg_temp.u('23');

-- ---------------------------------------------------------------------------
-- 4. Las columnas
-- ---------------------------------------------------------------------------
select pg_temp.actuar_como(pg_temp.u('c1'));
select is((select row(r.colportor_id, r.nombre, r.apellido, r.de_baja, r.ciudad_id, r.ciudad_nombre, r.departamento)::text
             from public.retiros_de_campania(pg_temp.u('e1')) r where r.deposito_id = pg_temp.u('21')),
          row(pg_temp.u('b1'), 'Ana', 'Alfa', false, pg_temp.u('91'), 'Ciudad uno rt184', 'Departamento uno')::text,
          '21: el colportor y la ciudad de su zona');
select is((select row(r.monto, r.concepto, r.estado, r.motivo_rechazo, r.revisado_por, r.revisado_en, r.anulado_en)::text
             from public.retiros_de_campania(pg_temp.u('e1')) r where r.deposito_id = pg_temp.u('21')),
          row(40000::bigint, 'CASA_EDITORA', 'PENDIENTE', null::text, null::uuid, null::timestamptz, null::timestamptz)::text,
          '21: por confirmar, sin quién ni cuándo');
select is((select row(r.fecha, r.subido_en)::text from public.retiros_de_campania(pg_temp.u('e1')) r where r.deposito_id = pg_temp.u('21')),
          (select row(d.fecha, d.created_at)::text from public.deposito d where d.id = pg_temp.u('21')),
          '21: la fecha del retiro y cuándo llegó');
select is((select r.concepto from public.retiros_de_campania(pg_temp.u('e1')) r where r.deposito_id = pg_temp.u('22')),
          'ALQUILER', '22: el concepto alquiler');
select is((select row(r.estado, r.motivo_rechazo, r.revisado_por, r.revisado_en)::text
             from public.retiros_de_campania(pg_temp.u('e1')) r where r.deposito_id = pg_temp.u('24')),
          (select row('VALIDADO', null::text, d.validado_por, d.validado_en)::text from public.deposito d where d.id = pg_temp.u('24')),
          '24: confirmado por c1, con cuándo');
select is((select row(r.estado, r.motivo_rechazo, r.revisado_por, r.revisado_en)::text
             from public.retiros_de_campania(pg_temp.u('e1')) r where r.deposito_id = pg_temp.u('25')),
          (select row('RECHAZADO', 'Recibí 5.000, no 9.000', d.rechazado_por, d.rechazado_en)::text from public.deposito d where d.id = pg_temp.u('25')),
          '25: rechazado con su motivo, quién y cuándo');
select is((select row(r.estado, r.revisado_por, r.anulado_en)::text
             from public.retiros_de_campania(pg_temp.u('e1')) r where r.deposito_id = pg_temp.u('2d')),
          (select row('VALIDADO', pg_temp.u('c3'), d.anulado_at)::text from public.deposito d where d.id = pg_temp.u('2d')),
          '2d: confirmado por el segundo coordinador y después anulado (devuelto), con la fecha');
select is((select row(r.ciudad_id, r.ciudad_nombre, r.departamento)::text from public.retiros_de_campania(pg_temp.u('e1')) r where r.deposito_id = pg_temp.u('23')),
          row(null::uuid, null::text, null::text)::text, '23: b3 no tiene zona: sin ciudad (null)');
select is((select row(r.nombre, r.apellido, r.de_baja, r.ciudad_nombre)::text from public.retiros_de_campania(pg_temp.u('e1')) r where r.deposito_id = pg_temp.u('26')),
          row('Diego', 'Duarte', true, null::text)::text,
          '26: el colportor dado de baja sigue figurando, marcado, y sin ciudad');
select is((select r.ciudad_nombre from public.retiros_de_campania(pg_temp.u('e1')) r where r.deposito_id = pg_temp.u('22')),
          'Ciudad dos rt184', '22: b2 está en la zona Costa, de la ciudad dos');

-- ---------------------------------------------------------------------------
-- 5. Los filtros
-- ---------------------------------------------------------------------------
select is(pg_temp.salen('e1', $$ p_estado => 'PENDIENTE' $$), '22,21,26,23', 'estado PENDIENTE (por confirmar)');
select is(pg_temp.salen('e1', $$ p_estado => 'VALIDADO' $$), '24,2d', 'estado VALIDADO (confirmado)');
select is(pg_temp.salen('e1', $$ p_estado => 'RECHAZADO' $$), '25', 'estado RECHAZADO');
select is(pg_temp.salen('e1', format($$ p_colportor_id => %L $$, pg_temp.u('b1'))), '21,24', 'por colportor');
select is(pg_temp.salen('e1', format($$ p_colportor_id => %L $$, pg_temp.u('b4'))), '26', 'por colportor dado de baja');
select is(pg_temp.salen('e1', format($$ p_colportor_id => %L $$, pg_temp.u('b5'))), '-', 'por un colportor que no es de la campaña: nada');
select is(pg_temp.salen('e1', format($$ p_ciudad_id => %L $$, pg_temp.u('91'))), '21,24', 'por ciudad uno (b1; b4 de baja no cuenta en ninguna)');
select is(pg_temp.salen('e1', format($$ p_ciudad_id => %L $$, pg_temp.u('92'))), '22,25,2d', 'por ciudad dos (b2)');
select is(pg_temp.salen('e1', $$ p_desde => public.hoy_montevideo() - 3 $$), '21,26,23',
          'desde hace 3 días (el día cuenta entero)');
select is(pg_temp.salen('e1', $$ p_hasta => public.hoy_montevideo() - 7 $$), '25,24,2d', 'hasta hace 7 días (el día cuenta entero)');
select is(pg_temp.salen('e1', $$ p_desde => public.hoy_montevideo() - 7, p_hasta => public.hoy_montevideo() - 3 $$), '22,21,25',
          'un rango');
select is(pg_temp.salen('e1', $$ p_estado => 'PENDIENTE', p_desde => public.hoy_montevideo() - 3 $$), '21,26,23', 'filtros combinados');
select is(pg_temp.salen('e1', $$ p_estado => 'VALIDADO', p_ciudad_id => null, p_colportor_id => null $$), '24,2d', 'los filtros en null no filtran');

select throws_ok($$ select * from public.retiros_de_campania('01920000-0000-7000-8000-0000000184e1', 'CONFIRMADO') $$,
  '22023', 'El estado del retiro es PENDIENTE, VALIDADO o RECHAZADO.', 'un estado que no existe: 22023');
select throws_ok($$ select * from public.retiros_de_campania('01920000-0000-7000-8000-0000000184e1', null, null, null, '2026-10-02', '2026-10-01') $$,
  '22023', 'La fecha desde no puede ser posterior a la fecha hasta.', 'desde después de hasta: 22023');
select throws_ok($$ select * from public.retiros_de_campania('01920000-0000-7000-8000-0000000184e1', p_limite => 0) $$,
  '22023', 'El límite de retiros es de 1 a 500.', 'límite 0: 22023');
select throws_ok($$ select * from public.retiros_de_campania('01920000-0000-7000-8000-0000000184e1', p_limite => 501) $$,
  '22023', 'El límite de retiros es de 1 a 500.', 'límite 501: 22023');
select throws_ok($$ select * from public.retiros_de_campania('01920000-0000-7000-8000-0000000184e1', p_limite => null) $$,
  '22023', 'El límite de retiros es de 1 a 500.', 'límite null: 22023');
select throws_ok($$ select * from public.retiros_de_campania('01920000-0000-7000-8000-0000000184e1', p_desplazamiento => -1) $$,
  '22023', 'El desplazamiento no puede ser negativo.', 'desplazamiento negativo: 22023');
select lives_ok($$ select * from public.retiros_de_campania('01920000-0000-7000-8000-0000000184e1', p_limite => 500) $$, 'límite 500 sí');

-- ---------------------------------------------------------------------------
-- 6. Orden y paginación
-- ---------------------------------------------------------------------------
select is(pg_temp.salen('e1', 'p_limite => 3'), '22,21,26', 'la primera página de 3');
select is(pg_temp.salen('e1', 'p_limite => 3, p_desplazamiento => 3'), '23,25,24', 'la segunda');
select is(pg_temp.salen('e1', 'p_limite => 3, p_desplazamiento => 6'), '2d', 'la última, con uno solo');
select is(pg_temp.salen('e1', 'p_limite => 3, p_desplazamiento => 9'), '-', 'más allá del final, vacía');

-- ---------------------------------------------------------------------------
-- 7. Confirmar y rechazar desde la vista
-- ---------------------------------------------------------------------------
select pg_temp.actuar_como(pg_temp.u('c1'));
select lives_ok($$ select public.confirmar_retiro('01920000-0000-7000-8000-000000018421') $$, 'c1 confirma el retiro 21');
select lives_ok($$ select public.rechazar_retiro('01920000-0000-7000-8000-000000018423', '  No me lo dio  ') $$, 'y rechaza el 23');
select is((select row(r.estado, r.revisado_por, (r.revisado_en is not null))::text
             from public.retiros_de_campania(pg_temp.u('e1')) r where r.deposito_id = pg_temp.u('21')),
          row('VALIDADO', pg_temp.u('c1'), true)::text, '21: ahora confirmado por c1');
select is((select row(r.estado, r.motivo_rechazo, r.revisado_por)::text
             from public.retiros_de_campania(pg_temp.u('e1')) r where r.deposito_id = pg_temp.u('23')),
          row('RECHAZADO', 'No me lo dio', pg_temp.u('c1'))::text, '23: ahora rechazado, con el motivo recortado');
-- 21 y 23 salen de la cola por confirmar y pasan a lo resuelto (el más nuevo primero: llegaron hace 3 y 1 día).
select is(pg_temp.salen('e1'), '22,26,23,21,25,24,2d', 'lo resuelto deja la cola de por confirmar');
select is(pg_temp.salen('e1', $$ p_estado => 'PENDIENTE' $$), '22,26', 'quedan dos por confirmar');

-- ---------------------------------------------------------------------------
-- 8. Datos límite
-- ---------------------------------------------------------------------------
select pg_temp.actuar_como(pg_temp.u('c2'));
select is(pg_temp.salen('e2', $$ p_estado => 'RECHAZADO' $$), '-', 'sin retiros en ese estado: vacío, sin error');
select pg_temp.actuar_como_servidor();
insert into public.deposito (id, colportor_id, monto, fecha, destino, concepto, created_at)
values (pg_temp.u('2f'), pg_temp.u('b3'), 9007199254740993, now() - interval '20 days', 'RETIRO_COORDINADOR', 'CASA_EDITORA',
        now() - interval '20 days');
select pg_temp.actuar_como(pg_temp.u('c1'));
select is((select r.monto from public.retiros_de_campania(pg_temp.u('e1')) r where r.deposito_id = pg_temp.u('2f')),
          9007199254740993::bigint, 'un monto más grande que lo que un double guarda se devuelve entero (bigint)');
select is(pg_temp.salen('e1', $$ p_estado => 'PENDIENTE' $$), '2f,22,26', 'y el por confirmar más viejo va primero');

select * from finish();
rollback;
