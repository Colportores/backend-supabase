-- pgTAP · acompañamientos del coordinador (migración 0043, backend-supabase#97, HU-JOR-004)
-- agregar_acompaniamiento(), acompaniamientos_por_colportor(), historial_de_acompaniamientos():
-- forma y privilegios; el permiso primero (sin JWT, anon, colportor, sin rol, rol vencido,
-- coordinador de otra campaña) y que las lecturas leen una campaña terminada o por empezar y la
-- escritura no; qué cuenta como un acompañamiento de la campaña (fechas, baja de la inscripción,
-- jornadas abiertas o dadas de baja, el día de Montevideo); los días sin acompañar (desde el
-- último o desde el inicio de la campaña) y el orden; el historial; cada error de la escritura
-- (JO001..JO004, CZ011, 22023) sin tocar la fila; la idempotencia; que las lecturas reflejan lo
-- escrito; que no se devuelve nada de más.
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

-- El rol `authenticated` pero sin sesión: auth.uid() es null.
create or replace function pg_temp.actuar_sin_jwt() returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', '', true);
  perform set_config('request.jwt.claim.sub', '', true);
  perform set_config('request.jwt.claim.role', '', true);
  perform set_config('role', 'authenticated', true);
end $$;

create or replace function pg_temp.actuar_como_anon() returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', '', true);
  perform set_config('request.jwt.claim.sub', '', true);
  perform set_config('request.jwt.claim.role', 'anon', true);
  perform set_config('role', 'anon', true);
end $$;

-- El uuid de un personaje del test.
create or replace function pg_temp.u(p_sufijo text) returns uuid language sql immutable as $$
  select ('01920000-0000-7000-8000-0000000052' || p_sufijo)::uuid
$$;

-- Hoy en Montevideo (hoy_montevideo() no se ejecuta como authenticated).
create or replace function pg_temp.hoy() returns date language sql stable as $$
  select (now() at time zone 'America/Montevideo')::date
$$;

-- SQLSTATE|mensaje del error que da una sentencia ('ok' si no da ninguno).
create or replace function pg_temp.error_de(p_sql text) returns text language plpgsql as $$
begin
  execute p_sql;
  return 'ok';
exception when others then
  return sqlstate || '|' || sqlerrm;
end $$;

-- Agregar un acompañamiento, como texto: ya_estaba|acompañante|día (o el error).
create or replace function pg_temp.agregar(p_camp text, p_jor text) returns text language plpgsql as $$
declare
  r record;
begin
  select * into r from public.agregar_acompaniamiento(pg_temp.u(p_camp), pg_temp.u(p_jor));
  return format('%s|%s|%s', r.ya_estaba::text, r.acompaniante_nombre || ' ' || r.acompaniante_apellido, r.dia);
exception when others then
  return sqlstate || '|' || sqlerrm;
end $$;

-- Las jornadas cerradas de un colportor, como texto: día|horas|acompañante (separadas por ';').
create or replace function pg_temp.jornadas(p_camp text, p_colp text) returns text language sql as $$
  select coalesce(string_agg(format('%s|%s|%s', r.dia - pg_temp.hoy(), r.horas,
                                    coalesce(r.acompaniante_nombre, 'null')), ';'), '(vacío)')
    from public.jornadas_cerradas_de_colportor(pg_temp.u(p_camp), pg_temp.u(p_colp)) r
$$;

-- La fila de la tabla de un colportor: acompañamientos|último|días sin|contado desde|ciudad.
create or replace function pg_temp.fila(p_camp text, p_colp text) returns text language sql as $$
  select coalesce((
    select format('%s|%s|%s|%s|%s', r.acompaniamientos, coalesce(r.ultimo_dia::text, 'null'), r.dias_sin_acompaniar,
                  r.contado_desde, coalesce(r.ciudad_nombre, '(sin ciudad)'))
      from public.acompaniamientos_por_colportor(pg_temp.u(p_camp)) r
     where r.colportor_id = pg_temp.u(p_colp)), 'sin fila')
$$;

-- El historial de un colportor, como texto: día|horas|en_curso|acompañante (un renglón por jornada,
-- separados por ';', en el orden en que vuelven).
create or replace function pg_temp.historial(p_camp text, p_colp text) returns text language sql as $$
  select coalesce(string_agg(format('%s|%s|%s|%s', r.dia - pg_temp.hoy(), coalesce(r.horas::text, 'null'),
                                    r.en_curso::text, r.acompaniante_nombre), ';'), '(vacío)')
    from public.historial_de_acompaniamientos(pg_temp.u(p_camp), pg_temp.u(p_colp)) r
$$;

-- --- fixtures ------------------------------------------------------------------
-- Staff: a1 coordinador de En curso, Cierre, Borrada y Futura; a2 coordinador de Otra;
--        ad admin (y colportor inscripto en En curso, con su propia jornada); a0 colportor;
--        a3 sin ningún rol; a4 coordinador con el rol vencido.
-- Colportores: b1 Alfa (zona Centro, ciudad c1)  b2 Bravo (Centro)  b3 Cruz (sin zona)
--        b4 Duarte (inscripción de baja hace 30 días)  b5 Eguren (NO inscripto en En curso; sí en
--        Otra)  b6 Fuentes (su zona se dio de baja).
-- Campañas: e1 En curso (desde hoy - 60, sin fin, a1)  e2 Cierre (03/08/2026 a 30/09/2026, a1)
--        e3 Otra (a2)  e4 Borrada (a1)  e5 Futura (desde hoy + 10, a1, con b3 inscripto)
--        e6 Borde (de hoy - 20 a hoy, a1; b5 inscripto): para el primer y el último día
--        e7 Reasignada (desde hoy - 60, a1): b7 se inscribió hace 10 días (venía de otra campaña)
insert into auth.users (id, instance_id, aud, role, email, encrypted_password, confirmed_at, created_at, updated_at)
select pg_temp.u(s), '00000000-0000-0000-0000-000000000000',
       'authenticated', 'authenticated', 'acomp-' || s || '@example.com', 'x', now(), now(), now()
  from unnest(array['a0','a1','a2','a3','a4','ad','b1','b2','b3','b4','b5','b6','b7']) s;

update public.usuario u set nombre = x.n, apellido = x.a
  from (values ('a1','Mariela','Pereyra'), ('a2','Nora','Quiroga'), ('ad','Admin','Zeta'),
               ('b1','Ana','Alfa'), ('b2','Beto','Bravo'), ('b3','Carla','Cruz'),
               ('b4','Diego','Duarte'), ('b5','Elena','Eguren'), ('b6','Fede','Fuentes'),
               ('b7','Gabi','Gómez')) x(s, n, a)
 where u.id = pg_temp.u(x.s);

insert into public.usuario_rol (usuario_id, rol_id)
select pg_temp.u(x.s), r.id
  from (values ('a1','COORDINADOR'), ('a2','COORDINADOR'), ('ad','ADMIN'), ('a0','COLPORTOR'),
               ('b1','COLPORTOR'), ('b2','COLPORTOR'), ('b3','COLPORTOR')) x(s, codigo)
  join public.rol r on r.codigo = x.codigo;
insert into public.usuario_rol (usuario_id, rol_id, valido_desde, valido_hasta)
select pg_temp.u('a4'), r.id, now() - interval '10 days', now() - interval '1 day'
  from public.rol r where r.codigo = 'COORDINADOR';

insert into public.pais (id, nombre, iso_code) values (pg_temp.u('c0'), 'Pais acomp', 'ZR');
insert into public.ciudad (id, nombre, departamento, pais_id, lat_centro, lon_centro, zoom_inicial) values
  (pg_temp.u('c1'), 'Ciudad uno q97', 'Departamento de prueba', pg_temp.u('c0'), -34.91, -56.18, 13);

insert into public.campania (id, nombre, tipo, fecha_inicio, fecha_fin, coordinador_id, deleted_at) values
  (pg_temp.u('e1'), 'En curso', 'VERANO', pg_temp.hoy() - 60, null,         pg_temp.u('a1'), null),
  (pg_temp.u('e2'), 'Cierre',   'VERANO', '2026-08-03',        '2026-09-30', pg_temp.u('a1'), null),
  (pg_temp.u('e3'), 'Otra',     'VERANO', pg_temp.hoy() - 60, null,         pg_temp.u('a2'), null),
  (pg_temp.u('e4'), 'Borrada',  'VERANO', pg_temp.hoy() - 60, null,         pg_temp.u('a1'), now()),
  (pg_temp.u('e5'), 'Futura',   'VERANO', pg_temp.hoy() + 10, null,         pg_temp.u('a1'), null),
  (pg_temp.u('e6'), 'Borde',    'VERANO', pg_temp.hoy() - 20, pg_temp.hoy(), pg_temp.u('a1'), null),
  (pg_temp.u('e7'), 'Reasignada', 'VERANO', pg_temp.hoy() - 60, null,        pg_temp.u('a1'), null);
insert into public.campania_ciudad (id, campania_id, ciudad_id) values
  (pg_temp.u('71'), pg_temp.u('e1'), pg_temp.u('c1'));
insert into public.zona (id, nombre, campania_ciudad_id, tipo_forma, color, poligono_geojson) values
  (pg_temp.u('d1'), 'Centro', pg_temp.u('71'), 'ESQUINAS', '#112233',
   '{"type":"Polygon","coordinates":[[[-56.19,-34.92],[-56.17,-34.92],[-56.17,-34.91],[-56.19,-34.91],[-56.19,-34.92]]]}'::jsonb),
  (pg_temp.u('d2'), 'Baja',   pg_temp.u('71'), 'ESQUINAS', null,
   '{"type":"Polygon","coordinates":[[[-56.19,-34.95],[-56.17,-34.95],[-56.17,-34.94],[-56.19,-34.94],[-56.19,-34.95]]]}'::jsonb);

-- Todas inscriptas hace 200 días (antes que cualquier jornada), salvo b7 en Reasignada.
insert into public.campania_colportor (campania_id, usuario_id, zona_id, created_at)
select x.*, now() - interval '200 days' from (values
  (pg_temp.u('e1'), pg_temp.u('b1'), pg_temp.u('d1')),
  (pg_temp.u('e1'), pg_temp.u('b2'), pg_temp.u('d1')),
  (pg_temp.u('e1'), pg_temp.u('b3'), null),
  (pg_temp.u('e1'), pg_temp.u('b4'), null),
  (pg_temp.u('e1'), pg_temp.u('b6'), pg_temp.u('d2')),
  (pg_temp.u('e1'), pg_temp.u('ad'), null),
  (pg_temp.u('e3'), pg_temp.u('b5'), null),
  (pg_temp.u('e5'), pg_temp.u('b3'), null),
  (pg_temp.u('e6'), pg_temp.u('b5'), null)) x;
-- b7 estaba en otra campaña y hace 10 días lo inscribieron en Reasignada (e7).
insert into public.campania_colportor (campania_id, usuario_id, zona_id, created_at)
values (pg_temp.u('e7'), pg_temp.u('b7'), null, now() - interval '10 days');
update public.zona set deleted_at = now() where id = pg_temp.u('d2');
update public.campania_colportor set deleted_at = now() - interval '30 days'
 where campania_id = pg_temp.u('e1') and usuario_id = pg_temp.u('b4');

-- Jornadas (id, colportor, hace cuántos días, hora de inicio en Montevideo, horas, acompañante, baja):
--   b1: f1 hace 10 días, 4 h, con a1 · f2 hace 3, 2,5 h, con a2 · f3 hace 20, 3 h, sin acompañante ·
--       f4 hace 5, ABIERTA, con a1 · f5 hace 70 (antes de la campaña), con a1 · f6 hace 8, con a1,
--       dada de baja.
--   b2: f7 hace 2, 3 h · f8 hace 1, 1 h · fd hace 6 a las 23:00, 3 h (cruza la medianoche) ·
--       fe hace 4, ABIERTA: las cuatro sin acompañante.
--   b4 (inscripción de baja hace 30 días): f9 hace 40 (antes de la baja) y fa hace 20 (después),
--       las dos con a1.
--   b5 (no inscripto en En curso): fb hace 5, con a1.   b6: fc hace 4, 2 h, sin acompañante.
--   ad (colportor inscripto en En curso): ff hace 3, 2 h, sin acompañante.
--   b5 en Borde (de hoy - 20 a hoy; además de fb): 81 el primer día y 83 el último, con a1; 82 el día anterior y
--       84 el día siguiente, con a1 (no cuentan); 85 el primer día y 86 el último, sin acompañante;
--       87 el día anterior y 88 el siguiente, sin acompañante (no se pueden agregar).
insert into public.jornada (id, colportor_id, inicio, fin, acompaniante_id, deleted_at)
select pg_temp.u(x.id), pg_temp.u(x.colp),
       (pg_temp.hoy() - x.dias + x.hora) at time zone 'America/Montevideo',
       case when x.horas is null then null
            else (pg_temp.hoy() - x.dias + x.hora) at time zone 'America/Montevideo'
                 + make_interval(secs => (x.horas * 3600)::double precision) end,
       case when x.acomp is null then null else pg_temp.u(x.acomp) end,
       x.baja
  from (values
    ('f1', 'b1', 10, time '09:00', 4.0::numeric, 'a1', null::timestamptz),
    ('f2', 'b1',  3, time '09:00', 2.5,          'a2', null),
    ('f3', 'b1', 20, time '09:00', 3.0,          null, null),
    ('f4', 'b1',  5, time '09:00', null,         'a1', null),
    ('f5', 'b1', 70, time '09:00', 2.0,          'a1', null),
    ('f6', 'b1',  8, time '09:00', 2.0,          'a1', now()),
    ('f7', 'b2',  2, time '09:00', 3.0,          null, null),
    ('f8', 'b2',  1, time '09:00', 1.0,          null, null),
    ('fd', 'b2',  6, time '23:00', 3.0,          null, null),
    ('fe', 'b2',  4, time '09:00', null,         null, null),
    ('f9', 'b4', 40, time '09:00', 2.0,          'a1', null),
    ('fa', 'b4', 20, time '09:00', 2.0,          'a1', null),
    ('fb', 'b5',  5, time '09:00', 2.0,          'a1', null),
    ('fc', 'b6',  4, time '09:00', 2.0,          null, null),
    ('ff', 'ad',  3, time '09:00', 2.0,          null, null),
    ('91', 'b7', 30, time '09:00', 5.0,          'a2', null),
    ('92', 'b7', 20, time '09:00', 2.0,          null, null),
    ('93', 'b7',  5, time '09:00', 1.0,          null, null),
    ('81', 'b5', 20, time '09:00', 2.0,          'a1', null),
    ('82', 'b5', 21, time '09:00', 2.0,          'a1', null),
    ('83', 'b5',  0, time '00:30', 0.5,          'a1', null),
    ('84', 'b5', -1, time '09:00', 2.0,          'a1', null),
    ('85', 'b5', 20, time '15:00', 1.0,          null, null),
    ('86', 'b5',  0, time '01:30', 0.5,          null, null),
    ('87', 'b5', 21, time '15:00', 1.0,          null, null),
    ('88', 'b5', -1, time '15:00', 1.0,          null, null)
  ) x(id, colp, dias, hora, horas, acomp, baja);

-- ---------------------------------------------------------------------------
-- 1. Forma y privilegios
-- ---------------------------------------------------------------------------
select pg_temp.actuar_como(pg_temp.u('a1'));
select is((select array(select k from jsonb_object_keys(
                  (select to_jsonb(r) from public.acompaniamientos_por_colportor(pg_temp.u('e1')) r limit 1)) k
                 order by k collate "C")),
          array['acompaniamientos','apellido','ciudad_id','ciudad_nombre','colportor_id','contado_desde',
                'dias_sin_acompaniar','nombre','ultimo_dia'],
          'la tabla trae solo totales, el día del último y la ciudad: ni clientes ni email');
select is((select array(select k from jsonb_object_keys(
                  (select to_jsonb(r) from public.historial_de_acompaniamientos(pg_temp.u('e1')) r limit 1)) k
                 order by k collate "C")),
          array['acompaniamiento_nota','acompaniamiento_origen','acompaniante_apellido','acompaniante_id',
                'acompaniante_nombre','apellido','colportor_id','dia','en_curso','horas','jornada_id','nombre'],
          'el historial trae el día, las horas, quién acompañó, de dónde salió el dato y la nota: ni la hora de inicio, ni clientes, ni email');
select is((select array(select k from jsonb_object_keys(
                  (select to_jsonb(r) from public.jornadas_cerradas_de_colportor(pg_temp.u('e1'), pg_temp.u('b1')) r limit 1)) k
                 order by k collate "C")),
          array['acompaniamiento_nota','acompaniamiento_origen','acompaniante_apellido','acompaniante_id',
                'acompaniante_nombre','dia','horas','jornada_id'],
          'las jornadas traen el día, las horas, quién acompañó, el origen y la nota: ni la hora de inicio ni clientes');
select is((select array(select k from jsonb_object_keys(
                  (select to_jsonb(r) from public.agregar_acompaniamiento(pg_temp.u('e1'), pg_temp.u('f7')) r limit 1)) k
                 order by k collate "C")),
          array['acompaniamiento_nota','acompaniamiento_origen','acompaniante_apellido','acompaniante_id',
                'acompaniante_nombre','colportor_id','dia','jornada_id','ya_estaba'],
          'agregar devuelve la jornada, el día, quién acompañó, el origen y la nota');
select pg_temp.actuar_como_servidor();
-- El anterior agregó a7 a f7: lo deshago para que los casos de abajo partan de las fixtures.
update public.jornada set acompaniante_id = null where id = pg_temp.u('f7');

select is((select array_agg(p order by p collate "C") from (
            select format('%s:%s:%s', f, has_function_privilege(r, f, 'execute'), r) p
              from unnest(array['public.acompaniamientos_por_colportor(uuid)',
                                'public.historial_de_acompaniamientos(uuid,uuid)',
                                'public.agregar_acompaniamiento(uuid,uuid,uuid,text)',
                                'public.jornadas_cerradas_de_colportor(uuid,uuid)']) f
             cross join unnest(array['anon','authenticated','service_role']) r) q),
          array[
            'public.acompaniamientos_por_colportor(uuid):f:anon',
            'public.acompaniamientos_por_colportor(uuid):f:service_role',
            'public.acompaniamientos_por_colportor(uuid):t:authenticated',
            'public.agregar_acompaniamiento(uuid,uuid,uuid,text):f:anon',
            'public.agregar_acompaniamiento(uuid,uuid,uuid,text):f:service_role',
            'public.agregar_acompaniamiento(uuid,uuid,uuid,text):t:authenticated',
            'public.historial_de_acompaniamientos(uuid,uuid):f:anon',
            'public.historial_de_acompaniamientos(uuid,uuid):f:service_role',
            'public.historial_de_acompaniamientos(uuid,uuid):t:authenticated',
            'public.jornadas_cerradas_de_colportor(uuid,uuid):f:anon',
            'public.jornadas_cerradas_de_colportor(uuid,uuid):f:service_role',
            'public.jornadas_cerradas_de_colportor(uuid,uuid):t:authenticated'],
          'las cuatro son solo para authenticated');
select is((select array_agg(format('%s:%s', r, has_function_privilege(r, 'public.jornadas_acompaniadas_de_campania(uuid)', 'execute')) order by r)
             from unnest(array['anon','authenticated','service_role']) r),
          array['anon:f','authenticated:f','service_role:f'],
          'la interna no la ejecuta nadie desde afuera');
select is((select prosecdef and proconfig = array['search_path=""'] from pg_proc
            where oid = 'public.agregar_acompaniamiento(uuid,uuid,uuid,text)'::regprocedure),
          true, 'agregar es SECURITY DEFINER con search_path vacío');

-- ---------------------------------------------------------------------------
-- 2. El permiso, antes de mirar nada
-- ---------------------------------------------------------------------------
select pg_temp.actuar_sin_jwt();
select is(split_part(pg_temp.error_de(format('select * from public.acompaniamientos_por_colportor(%L)', pg_temp.u('e1'))), '|', 1),
          '42501', 'sin sesión: la tabla da 42501');
select is(split_part(pg_temp.error_de(format('select * from public.historial_de_acompaniamientos(%L)', pg_temp.u('e1'))), '|', 1),
          '42501', 'sin sesión: el historial da 42501');
select is(split_part(pg_temp.agregar('e1', 'f7'), '|', 1), '42501', 'sin sesión: agregar da 42501');
select is(split_part(pg_temp.error_de(format('select * from public.jornadas_cerradas_de_colportor(%L, %L)', pg_temp.u('e1'), pg_temp.u('b1'))), '|', 1),
          '42501', 'sin sesión: las jornadas dan 42501');
select pg_temp.actuar_como_anon();
select is(split_part(pg_temp.error_de(format('select * from public.acompaniamientos_por_colportor(%L)', pg_temp.u('e1'))), '|', 1),
          '42501', 'anon: la tabla da 42501 (sin EXECUTE)');
select is(split_part(pg_temp.agregar('e1', 'f7'), '|', 1), '42501', 'anon: agregar da 42501 (sin EXECUTE)');

select pg_temp.actuar_como(pg_temp.u('a0'));
select is(split_part(pg_temp.error_de(format('select * from public.acompaniamientos_por_colportor(%L)', pg_temp.u('e1'))), '|', 1),
          '42501', 'colportor: la tabla da 42501');
select is(split_part(pg_temp.error_de(format('select * from public.historial_de_acompaniamientos(%L)', pg_temp.u('e1'))), '|', 1),
          '42501', 'colportor: el historial da 42501');
select is(split_part(pg_temp.agregar('e1', 'f7'), '|', 1), '42501', 'colportor: agregar da 42501');
select alike(pg_temp.agregar('e1', 'f7'), '%registrar acompañamientos%', 'y el aviso dice que es del coordinador');
select pg_temp.actuar_como(pg_temp.u('a3'));
select is(split_part(pg_temp.agregar('e1', 'f7'), '|', 1), '42501', 'sin rol: agregar da 42501');
select is(split_part(pg_temp.error_de(format('select * from public.acompaniamientos_por_colportor(%L)', pg_temp.u('e1'))), '|', 1),
          '42501', 'sin rol: la tabla da 42501');
select pg_temp.actuar_como(pg_temp.u('a4'));
select is(split_part(pg_temp.agregar('e1', 'f7'), '|', 1), '42501', 'rol vencido: agregar da 42501');
select is(split_part(pg_temp.error_de(format('select * from public.acompaniamientos_por_colportor(%L)', pg_temp.u('e1'))), '|', 1),
          '42501', 'rol vencido: la tabla da 42501');
select pg_temp.actuar_como(pg_temp.u('a2'));
select is(split_part(pg_temp.agregar('e1', 'f7'), '|', 1), '42501', 'coordinador de otra campaña: agregar da 42501');
select is(split_part(pg_temp.error_de(format('select * from public.historial_de_acompaniamientos(%L)', pg_temp.u('e1'))), '|', 1),
          '42501', 'coordinador de otra campaña: el historial da 42501');
select is(split_part(pg_temp.error_de(format('select * from public.jornadas_cerradas_de_colportor(%L, %L)', pg_temp.u('e1'), pg_temp.u('b1'))), '|', 1),
          '42501', 'coordinador de otra campaña: las jornadas dan 42501');
select is(split_part(pg_temp.error_de(format('select * from public.acompaniamientos_por_colportor(%L)', pg_temp.u('e2'))), '|', 1),
          '42501', 'una campaña ajena y terminada también da 42501 (el permiso va antes que la vigencia)');
select is(split_part(pg_temp.agregar('e3', 'f1'), '|', 1), 'JO001',
          'el coordinador de Otra no alcanza una jornada de otra campaña: JO001');
select is((select count(*) from public.jornada), 0::bigint, 'un coordinador no lee jornadas por RLS');

-- Campaña inexistente o dada de baja: CZ001 (para quien tiene rol).
select pg_temp.actuar_como(pg_temp.u('a1'));
select is(split_part(pg_temp.error_de(format('select * from public.acompaniamientos_por_colportor(%L)', pg_temp.u('e4'))), '|', 1),
          'CZ001', 'campaña dada de baja: la tabla da CZ001');
select is(split_part(pg_temp.error_de(format('select * from public.historial_de_acompaniamientos(%L)', pg_temp.u('e4'))), '|', 1),
          'CZ001', 'campaña dada de baja: el historial da CZ001');
select is(split_part(pg_temp.agregar('e4', 'f7'), '|', 1), 'CZ001', 'campaña dada de baja: agregar da CZ001');
select is(split_part(pg_temp.error_de(format('select * from public.jornadas_cerradas_de_colportor(%L, %L)', pg_temp.u('e4'), pg_temp.u('b1'))), '|', 1),
          'CZ001', 'campaña dada de baja: las jornadas dan CZ001');
select is(split_part(pg_temp.error_de(format('select * from public.acompaniamientos_por_colportor(%L)', pg_temp.u('99'))), '|', 1),
          'CZ001', 'campaña inexistente: la tabla da CZ001');
select is(split_part(pg_temp.error_de('select * from public.acompaniamientos_por_colportor(null)'), '|', 1),
          'CZ001', 'campaña nula: CZ001');

-- Las lecturas leen una campaña terminada y una por empezar; la escritura, no.
select is((select count(*) from public.acompaniamientos_por_colportor(pg_temp.u('e2'))), 0::bigint,
          'una campaña terminada se lee (sin inscriptos, lista vacía)');
select is(split_part(pg_temp.error_de(format('select * from public.historial_de_acompaniamientos(%L)', pg_temp.u('e2'))), '|', 1),
          'ok', 'una campaña terminada: el historial se lee');
select is(split_part(pg_temp.error_de(format('select * from public.acompaniamientos_por_colportor(%L)', pg_temp.u('e5'))), '|', 1),
          'ok', 'una campaña por empezar se lee');
select is(pg_temp.jornadas('e2', 'b1'), '(vacío)', 'una campaña terminada: las jornadas se leen (b1 no es de Cierre: vacío)');
select is(split_part(pg_temp.agregar('e2', 'f7'), '|', 1), 'CZ011', 'agregar en una campaña terminada: CZ011');
select alike(pg_temp.agregar('e2', 'f7'), '%sus acompañamientos quedan como están%',
             'y el aviso habla de acompañamientos y dice qué hacer');
select pg_temp.actuar_como_servidor();
select is((select acompaniante_id from public.jornada where id = pg_temp.u('f7')),
          null::uuid, 'y no tocó la jornada');
select pg_temp.actuar_como(pg_temp.u('a1'));

-- ---------------------------------------------------------------------------
-- 3. La tabla: total, último, días sin acompañar y orden
-- ---------------------------------------------------------------------------
-- b1: f1 (hace 10), f2 (hace 3, con otra coordinadora) y f4 (hace 5, abierta) cuentan; f3 sin
-- acompañante, f5 antes de la campaña y f6 dada de baja, no.
select is(pg_temp.fila('e1', 'b1'),
          format('3|%s|3|%s|Ciudad uno q97', pg_temp.hoy() - 3, pg_temp.hoy() - 3),
          'b1: 3 acompañamientos, el último hace 3 días (de cualquier coordinador, abierta incluida)');
select is(pg_temp.fila('e1', 'b2'),
          format('0|null|60|%s|Ciudad uno q97', pg_temp.hoy() - 60),
          'b2 nunca fue acompañado: null, y 60 días desde el inicio de la campaña');
select is(pg_temp.fila('e1', 'b3'), format('0|null|60|%s|(sin ciudad)', pg_temp.hoy() - 60),
          'b3 sin zona: sin ciudad, y 60 días desde el inicio');
select is(pg_temp.fila('e1', 'b6'), format('0|null|60|%s|(sin ciudad)', pg_temp.hoy() - 60),
          'b6 con la zona dada de baja: sin ciudad');
select is(pg_temp.fila('e1', 'b4'), 'sin fila', 'b4, con la inscripción de baja, no sale en la tabla');
select is(pg_temp.fila('e1', 'b5'), 'sin fila', 'b5, que no es de la campaña, no sale');
select is((select string_agg(r.apellido || ':' || r.dias_sin_acompaniar, ',')
             from public.acompaniamientos_por_colportor(pg_temp.u('e1')) r),
          'Bravo:60,Cruz:60,Fuentes:60,Zeta:60,Alfa:3',
          'el orden: más días sin acompañar primero, y entre iguales por apellido');
select is((select count(*) from public.acompaniamientos_por_colportor(pg_temp.u('e1'))), 5::bigint,
          'cinco inscripciones vivas');
select is((select count(*) from public.acompaniamientos_por_colportor(pg_temp.u('e5'))), 1::bigint,
          'la campaña por empezar tiene su inscripto');
select is((select dias_sin_acompaniar from public.acompaniamientos_por_colportor(pg_temp.u('e5'))), 0,
          'una campaña por empezar da 0 días (no negativos)');
-- Los bordes de la campaña: el primer y el último día cuentan, el anterior y el siguiente no.
select is(pg_temp.fila('e6', 'b5'), format('3|%s|0|%s|(sin ciudad)', pg_temp.hoy(), pg_temp.hoy()),
          'Borde: cuentan el primer y el último día de la campaña (y fb), no el anterior ni el siguiente');
select is(pg_temp.historial('e6', 'b5'), '0|0.50|false|Mariela;-5|2.00|false|Mariela;-20|2.00|false|Mariela',
          'Borde: el historial trae los mismos tres');

-- El día es el de Montevideo, no el de la zona de la sesión.
select pg_temp.actuar_como_servidor();
select set_config('TimeZone', 'Pacific/Kiritimati', true);
select pg_temp.actuar_como(pg_temp.u('a1'));
select is(pg_temp.fila('e1', 'b1'),
          format('3|%s|3|%s|Ciudad uno q97', pg_temp.hoy() - 3, pg_temp.hoy() - 3),
          'con la sesión en Kiritimati la tabla da lo mismo');
select pg_temp.actuar_como_servidor();
select set_config('TimeZone', 'UTC', true);
select pg_temp.actuar_como(pg_temp.u('a1'));

-- ---------------------------------------------------------------------------
-- 4. El historial
-- ---------------------------------------------------------------------------
select is(pg_temp.historial('e1', 'b1'),
          '-3|2.50|false|Nora;-5|null|true|Mariela;-10|4.00|false|Mariela',
          'b1: la más nueva primero, con horas, si sigue abierta y quién acompañó');
select is(pg_temp.historial('e1', 'b2'), '(vacío)', 'b2, sin acompañamientos, da la lista vacía');
select is(pg_temp.historial('e1', 'b4'), '-40|2.00|false|Mariela',
          'b4: solo lo anterior a la baja de la inscripción (hace 40 días), no lo de hace 20');
select is(pg_temp.historial('e1', 'b5'), '(vacío)', 'un colportor que no es de la campaña: lista vacía, sin error');
select is((select count(*) from public.historial_de_acompaniamientos(pg_temp.u('e1'))), 4::bigint,
          'sin colportor, el de todos: 3 de b1 y 1 de b4');
select is((select count(*) from public.historial_de_acompaniamientos(pg_temp.u('e1'), null)), 4::bigint,
          'con colportor null, también');
select is((select count(*) from public.historial_de_acompaniamientos(pg_temp.u('e1')) h
             where h.jornada_id in (select jornada_id from public.historial_de_acompaniamientos(pg_temp.u('e1'), pg_temp.u('b1')))),
          3::bigint, 'el historial de b1 es parte del de todos');
select is((select sum(acompaniamientos) from public.acompaniamientos_por_colportor(pg_temp.u('e1'))), 3::bigint,
          'el total de la tabla coincide con las jornadas del historial de los inscriptos vivos');
select is((select count(*) from public.historial_de_acompaniamientos(pg_temp.u('e2'))), 0::bigint,
          'la campaña terminada, sin inscriptos: historial vacío');

-- ---------------------------------------------------------------------------
-- 4b. Las jornadas entre las que elegir
-- ---------------------------------------------------------------------------
-- b1: cerradas f2 (hace 3, con a2), f1 (hace 10, con a1) y f3 (hace 20, sin acompañante); no la
-- abierta f4, ni f5 (antes de la campaña) ni f6 (de baja).
select is(pg_temp.jornadas('e1', 'b1'), '-3|2.50|Nora;-10|4.00|Mariela;-20|3.00|null',
          'b1: sus jornadas cerradas de la campaña, la más nueva primero, con quién la acompañó o null');
select is(pg_temp.jornadas('e1', 'b4'), '-40|2.00|Mariela', 'b4: solo lo anterior a la baja de su inscripción');
select is(pg_temp.jornadas('e1', 'b5'), '(vacío)', 'un colportor que no es de la campaña: lista vacía');
select is((select count(*) from public.jornadas_cerradas_de_colportor(pg_temp.u('e1'), null)), 0::bigint, 'colportor null: lista vacía');
select is(pg_temp.jornadas('e1', 'b2'), '-1|1.00|null;-2|3.00|null;-6|3.00|null',
          'b2: la abierta no sale, y la que cruza la medianoche está en el día en que empezó');
select is(pg_temp.jornadas('e6', 'b5'), '0|0.50|null;0|0.50|Mariela;-5|2.00|Mariela;-20|1.00|null;-20|2.00|Mariela',
          'Borde: el primer y el último día entran; el anterior y el siguiente no; el orden dentro del día es por hora');

-- Reasignación (HU-CAM-005): b7 trabajó en otra campaña (91 con a2, hace 30 días; 92 libre, hace
-- 20) y hace 10 días entró a Reasignada. Lo anterior a su inscripción no es de esta campaña.
select is(pg_temp.jornadas('e7', 'b7'), '-5|1.00|null',
          'Reasignada: solo la jornada posterior a la inscripción (93), no 91 ni 92');
select is(pg_temp.historial('e7', 'b7'), '(vacío)',
          'Reasignada: el acompañamiento de la otra campaña (91) no aparece en el historial');
-- 0100 («Días acomp.», decisión del 23/10): quien nunca fue acompañado se cuenta desde que se sumó (hace 10
-- días), no desde el inicio de la campaña (hace 60).
select is(pg_temp.fila('e7', 'b7'), format('0|null|10|%s|(sin ciudad)', pg_temp.hoy() - 10),
          'Reasignada: el acompañamiento de la otra campaña no cuenta, y los días se cuentan desde que se sumó');
select is((select count(*) from public.historial_de_acompaniamientos(pg_temp.u('e7'))), 0::bigint,
          'Reasignada: tampoco en el historial de todos');

-- ---------------------------------------------------------------------------
-- 5. Agregar un acompañamiento
-- ---------------------------------------------------------------------------
select pg_temp.actuar_como_servidor();
create temp table pg_temp.antes on commit drop as
  select id, sync_version, updated_at, created_by, acompaniante_id from public.jornada;
grant select on pg_temp.antes to authenticated;
select pg_temp.actuar_como(pg_temp.u('a1'));

-- Los errores de la jornada, y que ninguno toca nada.
select is(split_part(pg_temp.agregar('e1', 'f2'), '|', 1), 'JO003', 'f2 ya está acompañada por otra persona: JO003');
select alike(pg_temp.agregar('e1', 'f2'), '%Nora Quiroga%', 'y el aviso dice quién');
select is(split_part(pg_temp.agregar('e1', 'fe'), '|', 1), 'JO002', 'una jornada abierta sin acompañante: JO002');
select is(split_part(pg_temp.agregar('e1', 'f4'), '|', 1), 'JO002', 'una jornada abierta ya acompañada por mí: JO002 (la abierta va primero)');
select is(split_part(pg_temp.agregar('e1', 'f5'), '|', 1), 'JO001', 'una jornada de antes de la campaña: JO001');
select is(split_part(pg_temp.agregar('e1', 'f6'), '|', 1), 'JO001', 'una jornada dada de baja: JO001');
select is(split_part(pg_temp.agregar('e1', 'fa'), '|', 1), 'JO001', 'una jornada posterior a la baja de la inscripción: JO001');
select is(split_part(pg_temp.agregar('e1', 'fb'), '|', 1), 'JO001', 'una jornada de un colportor que no es de la campaña: JO001');
select is(split_part(pg_temp.agregar('e1', '99'), '|', 1), 'JO001', 'una jornada inexistente: JO001');
select is(split_part(pg_temp.agregar('e6', '87'), '|', 1), 'JO001', 'Borde: la jornada del día anterior a la campaña: JO001');
select is(split_part(pg_temp.agregar('e6', '88'), '|', 1), 'JO001', 'Borde: la jornada del día siguiente al fin: JO001');
select is(split_part(pg_temp.agregar('e7', '92'), '|', 1), 'JO001', 'Reasignada: una jornada anterior a la inscripción (libre): JO001');
select is(split_part(pg_temp.agregar('e7', '91'), '|', 1), 'JO001', 'Reasignada: una jornada anterior a la inscripción (ya acompañada): JO001, no JO003');
select is(pg_temp.agregar('e1', 'fb'), pg_temp.agregar('e1', '99'),
          'la ajena y la inexistente contestan igual (no se averigua qué jornadas hay)');
select is(split_part(pg_temp.error_de(format('select * from public.agregar_acompaniamiento(%L, null)', pg_temp.u('e1'))), '|', 1),
          '22023', 'sin jornada: 22023');
select pg_temp.actuar_como(pg_temp.u('ad'));
select is(split_part(pg_temp.agregar('e1', 'ff'), '|', 1), 'JO004', 'la jornada del propio coordinador (ADMIN que también es colportor): JO004');
select pg_temp.actuar_como_servidor();
select is((select count(*) from public.jornada j join pg_temp.antes a using (id)
            where j.sync_version is distinct from a.sync_version
               or j.acompaniante_id is distinct from a.acompaniante_id), 0::bigint,
          'ninguno de los errores tocó una jornada');

-- Agregar de verdad.
select pg_temp.actuar_como(pg_temp.u('a1'));
select is(pg_temp.agregar('e1', 'f7'), 'false|Mariela Pereyra|' || (pg_temp.hoy() - 2),
          'f7 (b2, hace 2 días) queda acompañada por a1: ya_estaba false');
select pg_temp.actuar_como_servidor();
select is((select acompaniante_id from public.jornada where id = pg_temp.u('f7')), pg_temp.u('a1'),
          'la jornada guarda a quien llama como acompañante');
select is((select j.sync_version - a.sync_version from public.jornada j join pg_temp.antes a using (id) where j.id = pg_temp.u('f7')),
          1::bigint, 'y subió una versión (el push viejo del teléfono daría conflicto y no pisaría)');
select is((select j.created_by is not distinct from a.created_by from public.jornada j join pg_temp.antes a using (id) where j.id = pg_temp.u('f7')),
          true, 'created_by no cambia');

-- El doble toque: idempotente y sin subir la versión otra vez.
select pg_temp.actuar_como(pg_temp.u('a1'));
select is(pg_temp.agregar('e1', 'f7'), 'true|Mariela Pereyra|' || (pg_temp.hoy() - 2),
          'el segundo toque: ya_estaba true');
select pg_temp.actuar_como_servidor();
select is((select j.sync_version - a.sync_version from public.jornada j join pg_temp.antes a using (id) where j.id = pg_temp.u('f7')),
          1::bigint, 'y la versión no sube otra vez');

-- Otro coordinador (el ADMIN) ya no puede pisarla.
select pg_temp.actuar_como(pg_temp.u('ad'));
select is(split_part(pg_temp.agregar('e1', 'f7'), '|', 1), 'JO003', 'el ADMIN no pisa el acompañamiento de a1: JO003');
-- ...pero sí agrega el suyo en una jornada libre, y es el que queda.
select is(pg_temp.agregar('e1', 'f8'), 'false|Admin Zeta|' || (pg_temp.hoy() - 1), 'el ADMIN agrega el suyo en f8');
-- La jornada que cruza la medianoche cuenta en el día en que empezó (hace 6 días, no hace 5).
select is(pg_temp.agregar('e1', 'fd'), 'false|Admin Zeta|' || (pg_temp.hoy() - 6), 'fd: el día es el de su inicio en Montevideo');
select pg_temp.actuar_como(pg_temp.u('a1'));
-- Los bordes de la campaña se pueden completar.
select is(split_part(pg_temp.agregar('e6', '85'), '|', 1), 'false', 'Borde: el primer día se completa');
select is(split_part(pg_temp.agregar('e6', '86'), '|', 1), 'false', 'Borde: el último día se completa');
-- f3 (b1, hace 20 días, sin acompañante) también.
select is(split_part(pg_temp.agregar('e1', 'f3'), '|', 1), 'false', 'f3 se completa');

-- ---------------------------------------------------------------------------
-- 6. Las lecturas reflejan lo escrito
-- ---------------------------------------------------------------------------
-- b2: f7 (hace 2, a1), f8 (hace 1, ad) y fd (hace 6, ad) -> 3, el último hace 1 día.
select is(pg_temp.fila('e1', 'b2'),
          format('3|%s|1|%s|Ciudad uno q97', pg_temp.hoy() - 1, pg_temp.hoy() - 1),
          'b2 ahora tiene 3 acompañamientos y el último hace 1 día');
select is(pg_temp.historial('e1', 'b2'),
          '-1|1.00|false|Admin;-2|3.00|false|Mariela;-6|3.00|false|Admin',
          'el historial de b2, con la de la medianoche el día en que empezó');
select is(pg_temp.jornadas('e1', 'b2'), '-1|1.00|Admin;-2|3.00|Mariela;-6|3.00|Admin',
          'y las jornadas de b2 muestran ahora quién las acompañó');
-- b1: f3 (hace 20) entra y queda entre las anteriores.
select is(pg_temp.fila('e1', 'b1'),
          format('4|%s|3|%s|Ciudad uno q97', pg_temp.hoy() - 3, pg_temp.hoy() - 3),
          'b1 pasó de 3 a 4 con f3, el último sigue siendo hace 3 días');
select is((select string_agg(r.apellido || ':' || r.dias_sin_acompaniar, ',')
             from public.acompaniamientos_por_colportor(pg_temp.u('e1')) r),
          'Cruz:60,Fuentes:60,Zeta:60,Alfa:3,Bravo:1',
          'el orden se reacomoda con lo escrito');

select * from finish();
rollback;
