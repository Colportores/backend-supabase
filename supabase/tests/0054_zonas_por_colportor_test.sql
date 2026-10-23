-- pgTAP · las zonas de cada colportor para Equipo (migraciones 0047 y 0062, backend-supabase#98, HU-CAM-006)
-- zonas_por_colportor(): forma y privilegios; el permiso primero (sin JWT, anon, colportor, sin rol,
-- rol vencido, coordinador de otra campaña) y que una campaña por empezar o terminada se lee; la
-- zona de hoy con su ciudad y desde cuándo; las casas registradas (no dependen de la zona; tampoco suman las de después del cierre de la campaña); las zonas anteriores con sus fechas, en orden, con el
-- día de Montevideo (también con otra zona horaria de sesión); la misma zona dos veces, la de otra
-- ciudad con el mismo nombre, la dada de baja, el tramo inicial y el tramo dado de baja; quién figura
-- (los mismos inscriptos que colportores_de_campania()) y quién no (inscripción de baja, cuenta
-- borrada); que no se mezclan campañas; que se arma solo con asignar, cambiar y quitar; que leer no
-- escribe nada.
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
  select ('01920000-0000-7000-8000-0000000054' || p_sufijo)::uuid
$$;

-- Hoy en Montevideo (hoy_montevideo() no se ejecuta como authenticated).
create or replace function pg_temp.hoy() returns date language sql stable as $$
  select (now() at time zone 'America/Montevideo')::date
$$;

-- Un instante: hace p_dias días, a la hora p_hora de Montevideo.
create or replace function pg_temp.t(p_dias integer, p_hora time default '12:00') returns timestamptz
language sql stable as $$
  select (pg_temp.hoy() - p_dias + p_hora) at time zone 'America/Montevideo'
$$;

-- SQLSTATE|mensaje del error que da una sentencia ('ok' si no da ninguno).
create or replace function pg_temp.error_de(p_sql text) returns text language plpgsql as $$
begin
  execute p_sql;
  return 'ok';
exception when others then
  return sqlstate || '|' || sqlerrm;
end $$;

-- Un tramo del historial, a mano (como postgres): campaña, colportor, zona, desde, hasta (null =
-- abierto), si es el inicial y si está dado de baja.
create or replace function pg_temp.tramo(p_camp text, p_colp text, p_zona text, p_desde timestamptz,
                                         p_hasta timestamptz, p_inicial boolean default false,
                                         p_baja boolean default false) returns void
language sql as $$
  insert into public.campania_colportor_zona_historial
         (campania_colportor_id, zona_id, desde, hasta, inicial, deleted_at)
  select cc.id, pg_temp.u(p_zona), p_desde, p_hasta, p_inicial, case when p_baja then now() end
    from public.campania_colportor cc
   where cc.campania_id = pg_temp.u(p_camp) and cc.usuario_id = pg_temp.u(p_colp)
$$;

-- La fila de un colportor, como texto:
--   zona|ciudad|desde (días respecto de hoy)|desde es inicial|anteriores
-- y cada anterior: «Zona@Ciudad:desde..hasta», con «!» si es un tramo inicial y «x» si la zona se
-- dio de baja; separadas por coma, en el orden en que vuelven.
create or replace function pg_temp.fila(p_camp text, p_colp text) returns text language sql as $$
  select coalesce((
    select format('%s|%s|%s|%s|%s',
                  coalesce(r.zona_nombre, '-'),
                  coalesce(r.ciudad_nombre, '-'),
                  coalesce((r.zona_desde - pg_temp.hoy())::text, '-'),
                  coalesce(r.zona_desde_inicial::text, '-'),
                  coalesce((select string_agg(format('%s@%s:%s..%s%s%s', a->>'nombre', a->>'ciudad_nombre',
                                                     (a->>'desde')::date - pg_temp.hoy(),
                                                     (a->>'hasta')::date - pg_temp.hoy(),
                                                     case when (a->>'inicial')::boolean then '!' else '' end,
                                                     case when (a->>'eliminada')::boolean then 'x' else '' end),
                                              ',' order by o)
                              from jsonb_array_elements(r.zonas_anteriores) with ordinality t(a, o)),
                           '(ninguna)'))
      from public.zonas_por_colportor(pg_temp.u(p_camp)) r
     where r.colportor_id = pg_temp.u(p_colp)), 'sin fila')
$$;

-- Una ubicación creada por un colportor, hace p_dias días (a las 12:00 de Montevideo), en una ciudad.
create or replace function pg_temp.ubic(p_colp text, p_ciudad text, p_dias integer, p_baja boolean default false)
returns void language sql as $$
  insert into public.ubicacion (tipo, lat, lon, ciudad_id, created_by, created_at, deleted_at)
  values ('CASA', -34.90, -56.16, pg_temp.u(p_ciudad), pg_temp.u(p_colp), pg_temp.t(p_dias),
          case when p_baja then now() end)
$$;

-- Una ubicación creada por un colportor en un instante exacto (p. ej. el borde del último día de una campaña).
create or replace function pg_temp.ubic_en(p_colp text, p_ciudad text, p_cuando timestamptz)
returns void language sql as $$
  insert into public.ubicacion (tipo, lat, lon, ciudad_id, created_by, created_at)
  values ('CASA', -34.90, -56.16, pg_temp.u(p_ciudad), pg_temp.u(p_colp), p_cuando)
$$;

-- Las casas registradas de un colportor en una campaña, como texto.
create or replace function pg_temp.casas(p_camp text, p_colp text) returns text language sql as $$
  select coalesce((select r.casas_registradas::text from public.zonas_por_colportor(pg_temp.u(p_camp)) r
                    where r.colportor_id = pg_temp.u(p_colp)), 'sin fila')
$$;

-- Las casas de toda la lista, como texto: apellido=casas, en el orden en que vuelven.
create or replace function pg_temp.casas_lista(p_camp text) returns text language sql as $$
  select coalesce(string_agg(r.apellido || '=' || r.casas_registradas, ',' order by o), '(vacía)')
    from (select r.*, row_number() over () o from public.zonas_por_colportor(pg_temp.u(p_camp)) r) r
$$;

-- Los apellidos de la lista, en el orden en que vuelven.
create or replace function pg_temp.lista(p_camp text) returns text language sql as $$
  select coalesce(string_agg(r.apellido, ',' order by o), '(vacía)')
    from (select r.*, row_number() over () o from public.zonas_por_colportor(pg_temp.u(p_camp)) r) r
$$;

-- --- fixtures ------------------------------------------------------------------
-- Staff: a1 coordinador de En curso, Cierre, Borrada y Futura; a2 coordinador de Otra; ad admin;
--        a0 colportor; a3 sin ningún rol; a4 coordinador con el rol vencido.
-- Colportores (apellido): b1 Alfa  b2 Bravo  b3 Cruz  b4 Duarte  b5 Eguren  b6 Fuentes (cuenta
--        borrada)  b7 Gómez (inscripción de baja)  b8 Herrera (se fue y volvió)  b9 Ibarra
--        ba Jaramillo  bb Kappa.
-- Campañas: e1 En curso (a1)  e2 Cierre (terminada, a1)  e3 Otra (a2)  e4 Borrada (a1)
--        e5 Futura (empieza en 10 días, a1).
-- Ciudades: c1 Ciudad uno, c2 Ciudad dos. campania_ciudad: 71 En curso/c1  72 En curso/c2
--        73 Cierre/c1  74 Otra/c1  75 Futura/c1.
-- Zonas: d1 Centro (71)  d2 Norte (71)  d3 Puerto (72, dada de baja)  d4 Centro (72)  d5 Vieja (73)
--        d6 Zona futura (75)  d7 Otra zona (74).
-- Historia (días respecto de hoy), En curso:
--   b1  Norte -50..-30 (cierra a las 23:30) · Puerto -30..-20 · Centro desde -15 (23:30), abierto
--   b2  Centro -40..-35 (a las 00:30) · Centro de Ciudad dos -35..-12 · Centro desde -10, abierto
--   b3  sin zona: Puerto -45..-20 · Norte -20..-5
--   b4  nunca tuvo zona   b5  Norte desde -58, tramo inicial, abierto
--   b8  se fue y volvió: Centro -30..-3, sin zona   b9  Norte inicial -58..-8 · Centro desde -8
--       (y un tramo de Puerto dado de baja que no cuenta)
--   ba conserva la zona Puerto, que se dio de baja: figura sin zona   bb Centro, con el tramo
--       abierto dado de baja: la zona sí, el desde no
-- Otras campañas: b1 en Futura con Zona futura desde -1 · b2 en Cierre con Vieja -100..-70, sin zona
--       · b2 en Otra con Otra zona desde -2.
insert into auth.users (id, instance_id, aud, role, email, encrypted_password, confirmed_at, created_at, updated_at)
select pg_temp.u(s), '00000000-0000-0000-0000-000000000000',
       'authenticated', 'authenticated', 'zpc-' || s || '@example.com', 'x', now(), now(), now()
  from unnest(array['a0','a1','a2','a3','a4','ad','b1','b2','b3','b4','b5','b6','b7','b8','b9','ba','bb']) s;

update public.usuario u set nombre = x.n, apellido = x.a
  from (values ('a1','Mariela','Pereyra'), ('a2','Nora','Quiroga'), ('ad','Admin','Zeta'),
               ('b1','Ana','Alfa'), ('b2','Beto','Bravo'), ('b3','Carla','Cruz'),
               ('b4','Diego','Duarte'), ('b5','Elena','Eguren'), ('b6','Fede','Fuentes'),
               ('b7','Gabi','Gómez'), ('b8','Hugo','Herrera'), ('b9','Ines','Ibarra'),
               ('ba','Jose','Jaramillo'), ('bb','Kari','Kappa')) x(s, n, a)
 where u.id = pg_temp.u(x.s);

insert into public.usuario_rol (usuario_id, rol_id)
select pg_temp.u(x.s), r.id
  from (values ('a1','COORDINADOR'), ('a2','COORDINADOR'), ('ad','ADMIN'), ('a0','COLPORTOR'),
               ('b1','COLPORTOR'), ('b2','COLPORTOR')) x(s, codigo)
  join public.rol r on r.codigo = x.codigo;
insert into public.usuario_rol (usuario_id, rol_id, valido_desde, valido_hasta)
select pg_temp.u('a4'), r.id, now() - interval '10 days', now() - interval '1 day'
  from public.rol r where r.codigo = 'COORDINADOR';

insert into public.pais (id, nombre, iso_code) values (pg_temp.u('c0'), 'Pais zpc', 'ZQ');
insert into public.ciudad (id, nombre, pais_id, lat_centro, lon_centro, zoom_inicial) values
  (pg_temp.u('c1'), 'Ciudad uno q98', pg_temp.u('c0'), -34.90, -56.16, 13),
  (pg_temp.u('c2'), 'Ciudad dos q98', pg_temp.u('c0'), -34.91, -56.17, 13),
  (pg_temp.u('c3'), 'Ciudad tres q98', pg_temp.u('c0'), -34.92, -56.18, 13),
  (pg_temp.u('c4'), 'Ciudad cuatro q98', pg_temp.u('c0'), -34.93, -56.19, 13);

insert into public.campania (id, nombre, tipo, fecha_inicio, fecha_fin, coordinador_id, deleted_at) values
  (pg_temp.u('e1'), 'En curso', 'VERANO', pg_temp.hoy() - 60, null,         pg_temp.u('a1'), null),
  (pg_temp.u('e2'), 'Cierre',   'VERANO', '2026-08-03',        '2026-09-30', pg_temp.u('a1'), null),
  (pg_temp.u('e3'), 'Otra',     'VERANO', pg_temp.hoy() - 60, null,         pg_temp.u('a2'), null),
  (pg_temp.u('e4'), 'Borrada',  'VERANO', pg_temp.hoy() - 60, null,         pg_temp.u('a1'), now()),
  (pg_temp.u('e5'), 'Futura',   'VERANO', pg_temp.hoy() + 10, null,         pg_temp.u('a1'), null);
insert into public.campania_ciudad (id, campania_id, ciudad_id) values
  (pg_temp.u('71'), pg_temp.u('e1'), pg_temp.u('c1')),
  (pg_temp.u('72'), pg_temp.u('e1'), pg_temp.u('c2')),
  (pg_temp.u('73'), pg_temp.u('e2'), pg_temp.u('c1')),
  (pg_temp.u('74'), pg_temp.u('e3'), pg_temp.u('c1')),
  (pg_temp.u('75'), pg_temp.u('e5'), pg_temp.u('c1')),
  (pg_temp.u('77'), pg_temp.u('e2'), pg_temp.u('c4'));
-- Ciudad tres estuvo en En curso y se quitó de la campaña (fila dada de baja).
insert into public.campania_ciudad (id, campania_id, ciudad_id, deleted_at)
values (pg_temp.u('76'), pg_temp.u('e1'), pg_temp.u('c3'), now());
insert into public.zona (id, nombre, campania_ciudad_id, tipo_forma, centro_lat, centro_lon, radio_m) values
  (pg_temp.u('d1'), 'Centro',      pg_temp.u('71'), 'RADIAL', -34.90, -56.16, 300),
  (pg_temp.u('d2'), 'Norte',       pg_temp.u('71'), 'RADIAL', -34.88, -56.16, 300),
  (pg_temp.u('d3'), 'Puerto',      pg_temp.u('72'), 'RADIAL', -34.91, -56.17, 300),
  (pg_temp.u('d4'), 'Centro',      pg_temp.u('72'), 'RADIAL', -34.92, -56.17, 300),
  (pg_temp.u('d5'), 'Vieja',       pg_temp.u('73'), 'RADIAL', -34.90, -56.16, 300),
  (pg_temp.u('d6'), 'Zona futura', pg_temp.u('75'), 'RADIAL', -34.90, -56.16, 300),
  (pg_temp.u('d7'), 'Otra zona',   pg_temp.u('74'), 'RADIAL', -34.90, -56.16, 300);

-- Las inscripciones (las que traen zona abren su tramo por el trigger: abajo se reemplazan por los
-- tramos de la historia, con las fechas que pide cada caso).
-- Las de En curso se inscribieron el primer día de la campaña (hace 60 días, a las 12:00).
insert into public.campania_colportor (campania_id, usuario_id, zona_id, deleted_at, created_at)
select pg_temp.u(x.e), pg_temp.u(x.b), case when x.d is null then null else pg_temp.u(x.d) end,
       case when x.baja then now() end,
       case when x.e = 'e1' then pg_temp.t(60)
            when x.e = 'e2' and x.b = 'b3' then timestamptz '2026-08-05 12:00-03'
            else now() end
  from (values ('e1','b1','d1',false), ('e1','b2','d1',false), ('e1','b3',null,false),
               ('e1','b4',null,false), ('e1','b5','d2',false), ('e1','b6','d1',false),
               ('e1','b7',null,true),  ('e1','b9','d1',false),
               ('e1','ba','d3',false), ('e1','bb','d1',false),
               ('e5','b1','d6',false), ('e2','b2',null,false), ('e2','b3',null,false), ('e3','b2','d7',false)) x(e, b, d, baja);

delete from public.campania_colportor_zona_historial h
 using public.campania_colportor cc
 where cc.id = h.campania_colportor_id
   and cc.campania_id in (pg_temp.u('e1'), pg_temp.u('e2'), pg_temp.u('e3'), pg_temp.u('e5'));

-- b1
select pg_temp.tramo('e1', 'b1', 'd2', pg_temp.t(50), pg_temp.t(30, '23:30'));
select pg_temp.tramo('e1', 'b1', 'd3', pg_temp.t(30, '23:30'), pg_temp.t(20));
select pg_temp.tramo('e1', 'b1', 'd1', pg_temp.t(15, '23:30'), null);
-- b2
select pg_temp.tramo('e1', 'b2', 'd1', pg_temp.t(40, '00:30'), pg_temp.t(35, '00:30'));
select pg_temp.tramo('e1', 'b2', 'd4', pg_temp.t(35, '00:30'), pg_temp.t(12));
select pg_temp.tramo('e1', 'b2', 'd1', pg_temp.t(10), null);
-- b3 (sin zona); el tramo más nuevo se inserta primero: el orden no es el de la inserción
select pg_temp.tramo('e1', 'b3', 'd2', pg_temp.t(20), pg_temp.t(5));
select pg_temp.tramo('e1', 'b3', 'd3', pg_temp.t(45), pg_temp.t(20));
-- b5: el tramo inicial sigue abierto
select pg_temp.tramo('e1', 'b5', 'd2', pg_temp.t(58), null, true);
-- b9: el inicial ya cerrado, el actual, y un tramo dado de baja que no cuenta
select pg_temp.tramo('e1', 'b9', 'd2', pg_temp.t(58), pg_temp.t(8), true);
select pg_temp.tramo('e1', 'b9', 'd3', pg_temp.t(30), pg_temp.t(20), false, true);
select pg_temp.tramo('e1', 'b9', 'd1', pg_temp.t(8), null);
-- ba: su zona (Puerto) se dio de baja y la inscripción la conserva; bb: el tramo abierto está dado de baja
select pg_temp.tramo('e1', 'ba', 'd3', pg_temp.t(5), null);
select pg_temp.tramo('e1', 'bb', 'd1', pg_temp.t(5), null, false, true);
-- Casas registradas. b1: tres que cuentan (dos ciudades de la campaña y una de ayer) y cuatro que no
-- (antes de inscribirse, dada de baja, ciudad quitada de la campaña, ciudad ajena a la campaña).
-- b2: una en Ciudad dos y otra creada justo al inscribirse (cuenta: el límite es inclusivo).
-- b3 y b4: una cada uno.
select pg_temp.ubic('b1', 'c1', 30);
select pg_temp.ubic('b1', 'c2', 20);
select pg_temp.ubic('b1', 'c1', 1);
select pg_temp.ubic('b1', 'c1', 61);
select pg_temp.ubic('b1', 'c1', 10, true);
select pg_temp.ubic('b1', 'c3', 10);
select pg_temp.ubic('b1', 'c4', 10);
select pg_temp.ubic('b2', 'c2', 5);
select pg_temp.ubic('b2', 'c1', 60);
select pg_temp.ubic('b3', 'c1', 5);
select pg_temp.ubic('b4', 'c1', 5);
-- b3 también estuvo inscripto en Cierre (03/08 al 30/09) desde el 05/08. En Ciudad cuatro, que es de
-- Cierre y no de En curso: una casa del 15/09 y otra del 30/09 a las 23:30 (último día: cuentan) y una
-- del 01/10 a las 00:30 (el día siguiente al cierre: no cuenta). La de hace 5 días en Ciudad uno (de
-- En curso, también ciudad de Cierre) es de después del cierre: tampoco cuenta en Cierre.
select pg_temp.ubic_en('b3', 'c4', timestamptz '2026-09-15 12:00-03');
select pg_temp.ubic_en('b3', 'c4', timestamptz '2026-09-30 23:30-03');
select pg_temp.ubic_en('b3', 'c4', timestamptz '2026-10-01 00:30-03');
-- Otras campañas
select pg_temp.tramo('e5', 'b1', 'd6', pg_temp.t(1), null);
select pg_temp.tramo('e2', 'b2', 'd5', pg_temp.t(100), pg_temp.t(70));
select pg_temp.tramo('e3', 'b2', 'd7', pg_temp.t(2), null);

-- b8 se fue y volvió, con los triggers de verdad: la baja la deja sin zona y cierra el tramo; al
-- volver (la misma fila) sigue sin zona. Después se fijan las fechas.
insert into public.campania_colportor (campania_id, usuario_id, zona_id)
values (pg_temp.u('e1'), pg_temp.u('b8'), pg_temp.u('d1'));
update public.campania_colportor set deleted_at = now()
 where campania_id = pg_temp.u('e1') and usuario_id = pg_temp.u('b8');
update public.campania_colportor set deleted_at = null
 where campania_id = pg_temp.u('e1') and usuario_id = pg_temp.u('b8');
update public.campania_colportor_zona_historial h
   set desde = pg_temp.t(30), hasta = pg_temp.t(3)
  from public.campania_colportor cc
 where cc.id = h.campania_colportor_id and cc.campania_id = pg_temp.u('e1') and cc.usuario_id = pg_temp.u('b8');

-- La zona Puerto se da de baja (b1, b3 y el tramo de b9 la tuvieron) y la cuenta de b6 se borra.
update public.zona set deleted_at = now() where id = pg_temp.u('d3');
update public.usuario set deleted_at = now() where id = pg_temp.u('b6');

create temporary table antes_historial (n bigint, v numeric, u timestamptz);

-- ---------------------------------------------------------------------------
-- 1. Forma y privilegios
-- ---------------------------------------------------------------------------
select pg_temp.actuar_como(pg_temp.u('a1'));
select is((select array(select k from jsonb_object_keys(
                  (select to_jsonb(r) from public.zonas_por_colportor(pg_temp.u('e1')) r limit 1)) k
                 order by k collate "C")),
          array['apellido','casas_registradas','ciudad_id','ciudad_nombre','colportor_id','nombre','zona_desde',
                'zona_desde_inicial','zona_id','zona_nombre','zonas_anteriores'],
          'la fila trae el nombre, la zona de hoy con su ciudad y desde cuándo, y las anteriores: ni email ni clientes');
select is((select array(select k from jsonb_object_keys(
                  (select r.zonas_anteriores->0 from public.zonas_por_colportor(pg_temp.u('e1')) r
                    where r.colportor_id = pg_temp.u('b1'))) k
                 order by k collate "C")),
          array['ciudad_id','ciudad_nombre','desde','eliminada','hasta','inicial','nombre','zona_id'],
          'cada zona anterior trae la zona, su ciudad, las fechas y dos marcas: ni quién la asignó ni la forma');
select pg_temp.actuar_como_servidor();

select is((select array_agg(format('%s:%s', r, has_function_privilege(r, 'public.zonas_por_colportor(uuid)', 'execute')) order by r)
             from unnest(array['anon','authenticated','service_role']) r),
          array['anon:f','authenticated:t','service_role:f'],
          'solo authenticated la ejecuta');
select is((select prosecdef and proconfig = array['search_path=""'] from pg_proc
            where oid = 'public.zonas_por_colportor(uuid)'::regprocedure),
          true, 'es SECURITY DEFINER con search_path vacío');
select ok(obj_description('public.zonas_por_colportor(uuid)'::regprocedure, 'pg_proc') is not null,
          'tiene su comment on');

-- ---------------------------------------------------------------------------
-- 2. El permiso, antes de mirar nada
-- ---------------------------------------------------------------------------
select pg_temp.actuar_sin_jwt();
select is(split_part(pg_temp.error_de(format('select * from public.zonas_por_colportor(%L)', pg_temp.u('e1'))), '|', 1),
          '42501', 'sin sesión: 42501');
select pg_temp.actuar_como_anon();
select is(split_part(pg_temp.error_de(format('select * from public.zonas_por_colportor(%L)', pg_temp.u('e1'))), '|', 1),
          '42501', 'anon: 42501 (sin EXECUTE)');
select pg_temp.actuar_como(pg_temp.u('a0'));
select is(split_part(pg_temp.error_de(format('select * from public.zonas_por_colportor(%L)', pg_temp.u('e1'))), '|', 1),
          '42501', 'colportor: 42501');
select alike(pg_temp.error_de(format('select * from public.zonas_por_colportor(%L)', pg_temp.u('e1'))),
             '%ver las zonas de su equipo%', 'y el aviso dice que es del coordinador y con qué cuenta entrar');
select pg_temp.actuar_como(pg_temp.u('a3'));
select is(split_part(pg_temp.error_de(format('select * from public.zonas_por_colportor(%L)', pg_temp.u('e1'))), '|', 1),
          '42501', 'sin rol: 42501');
select pg_temp.actuar_como(pg_temp.u('a4'));
select is(split_part(pg_temp.error_de(format('select * from public.zonas_por_colportor(%L)', pg_temp.u('e1'))), '|', 1),
          '42501', 'rol vencido: 42501');
select pg_temp.actuar_como(pg_temp.u('a2'));
select is(split_part(pg_temp.error_de(format('select * from public.zonas_por_colportor(%L)', pg_temp.u('e1'))), '|', 1),
          '42501', 'coordinador de otra campaña: 42501');
select is(split_part(pg_temp.error_de(format('select * from public.zonas_por_colportor(%L)', pg_temp.u('e2'))), '|', 1),
          '42501', 'una campaña ajena y terminada también da 42501 (el permiso va antes que la vigencia)');
select is(split_part(pg_temp.error_de(format('select * from public.zonas_por_colportor(%L)', pg_temp.u('e4'))), '|', 1),
          'CZ001', 'una campaña dada de baja es CZ001 aunque sea ajena (como en las demás lecturas: lo ajeno solo se calla si existe)');

-- Campaña inexistente o dada de baja: CZ001 (para quien tiene rol).
select pg_temp.actuar_como(pg_temp.u('a1'));
select is(split_part(pg_temp.error_de(format('select * from public.zonas_por_colportor(%L)', pg_temp.u('e4'))), '|', 1),
          'CZ001', 'campaña dada de baja: CZ001');
select is(split_part(pg_temp.error_de(format('select * from public.zonas_por_colportor(%L)', pg_temp.u('ff'))), '|', 1),
          'CZ001', 'campaña inexistente: CZ001');
select is(split_part(pg_temp.error_de('select * from public.zonas_por_colportor(null)'), '|', 1),
          'CZ001', 'campaña nula: CZ001');

-- ---------------------------------------------------------------------------
-- 3. La zona de hoy y las anteriores
-- ---------------------------------------------------------------------------
select is(pg_temp.fila('e1', 'b1'),
          'Centro|Ciudad uno q98|-15|false|Norte@Ciudad uno q98:-50..-30,Puerto@Ciudad dos q98:-30..-20x',
          'b1: Centro desde hace 15 días (cambió a las 23:30 de Montevideo: el día de Montevideo, no el de UTC); '
          'antes Norte y Puerto, cada una con sus fechas; un tramo cierra el mismo día en que abre el siguiente; '
          'Puerto se dio de baja (x)');
select is(pg_temp.fila('e1', 'b2'),
          'Centro|Ciudad uno q98|-10|false|Centro@Ciudad uno q98:-40..-35,Centro@Ciudad dos q98:-35..-12',
          'b2: la misma zona dos veces figura dos veces, y la de otra ciudad con el mismo nombre se distingue por la ciudad');
select is(pg_temp.fila('e1', 'b3'),
          '-|-|-|-|Puerto@Ciudad dos q98:-45..-20x,Norte@Ciudad uno q98:-20..-5',
          'b3: sin zona hoy, pero las anteriores se conservan, del más viejo al más nuevo');
select is(pg_temp.fila('e1', 'b4'), '-|-|-|-|(ninguna)', 'b4: nunca tuvo zona: sin zona y sin anteriores');
select is(pg_temp.fila('e1', 'b5'), 'Norte|Ciudad uno q98|-58|true|(ninguna)',
          'b5: el tramo abierto es el inicial: su desde es una cota y viene marcado');
select is(pg_temp.fila('e1', 'b9'), 'Centro|Ciudad uno q98|-8|false|Norte@Ciudad uno q98:-58..-8!',
          'b9: un tramo inicial ya cerrado va marcado (!) y el tramo dado de baja no figura');
select is(pg_temp.fila('e1', 'ba'), '-|-|-|-|(ninguna)',
          'ba: una zona dada de baja no es la zona de hoy (como en colportores_de_campania()), aunque la inscripción la conserve');
select is(pg_temp.fila('e1', 'bb'), 'Centro|Ciudad uno q98|-|-|(ninguna)',
          'bb: la zona figura aunque su tramo abierto esté dado de baja; sin desde');
select is(pg_temp.fila('e1', 'b8'), '-|-|-|-|Centro@Ciudad uno q98:-30..-3',
          'b8: se fue y volvió (triggers de verdad): vuelve sin zona y la de antes figura como anterior');
select is((select r.zonas_anteriores from public.zonas_por_colportor(pg_temp.u('e1')) r
            where r.colportor_id = pg_temp.u('b4')), '[]'::jsonb,
          'sin anteriores: [] y no null');
select is((select jsonb_typeof(r.zonas_anteriores) from public.zonas_por_colportor(pg_temp.u('e1')) r
            where r.colportor_id = pg_temp.u('b3')), 'array', 'zonas_anteriores es un arreglo');
select is((select r.zonas_anteriores->0->>'zona_id' from public.zonas_por_colportor(pg_temp.u('e1')) r
            where r.colportor_id = pg_temp.u('b3')), pg_temp.u('d3')::text,
          'cada anterior trae el id de la zona (Puerto, dada de baja)');
select is((select r.zonas_anteriores->0->>'ciudad_id' from public.zonas_por_colportor(pg_temp.u('e1')) r
            where r.colportor_id = pg_temp.u('b3')), pg_temp.u('c2')::text,
          'y el de su ciudad');
select is((select r.ciudad_id from public.zonas_por_colportor(pg_temp.u('e1')) r
            where r.colportor_id = pg_temp.u('b1')), pg_temp.u('c1'),
          'la ciudad del colportor es la de su zona de hoy');
select is((select r.zona_id from public.zonas_por_colportor(pg_temp.u('e1')) r
            where r.colportor_id = pg_temp.u('b1')), pg_temp.u('d1'), 'zona_id es la de hoy');

-- Quién figura: los mismos que colportores_de_campania(), por apellido.
select is(pg_temp.lista('e1'), 'Alfa,Bravo,Cruz,Duarte,Eguren,Herrera,Ibarra,Jaramillo,Kappa',
          'figuran los inscriptos vivos, por apellido: no la inscripción de baja (Gómez) ni la cuenta borrada (Fuentes)');
select is((select array_agg(r.colportor_id order by r.colportor_id) from public.zonas_por_colportor(pg_temp.u('e1')) r),
          (select array_agg(c.usuario_id order by c.usuario_id) from public.colportores_de_campania(pg_temp.u('e1')) c),
          'son los mismos que devuelve colportores_de_campania()');
select is((select array_agg(r.zona_id order by r.colportor_id) from public.zonas_por_colportor(pg_temp.u('e1')) r),
          (select array_agg(c.zona_id order by c.usuario_id) from public.colportores_de_campania(pg_temp.u('e1')) c),
          'y con la misma zona de hoy');

-- Casas registradas: no dependen de la zona.
select is(pg_temp.casas_lista('e1'), 'Alfa=3,Bravo=2,Cruz=1,Duarte=1,Eguren=0,Herrera=0,Ibarra=0,Jaramillo=0,Kappa=0',
          'casas: b1 tiene 3 (dos ciudades de la campaña, una de ayer); no cuentan la de antes de inscribirse, '
          'la dada de baja, la de una ciudad quitada de la campaña ni la de una ciudad ajena; b2 cuenta la creada justo al inscribirse');
select is(pg_temp.casas('e1', 'b3'), '1',
          'casas: b3 está sin zona hoy y sus anteriores no le restan: la cuenta no mira la zona');
select is(pg_temp.casas('e1', 'b1'), '3',
          'casas: b1 cambió tres veces de zona y conserva las que cargó en las anteriores');

-- ---------------------------------------------------------------------------
-- 4. Cada campaña con lo suyo
-- ---------------------------------------------------------------------------
select is(pg_temp.fila('e5', 'b1'), 'Zona futura|Ciudad uno q98|-1|false|(ninguna)',
          'Futura (todavía no empezó) se lee, y trae solo lo de esa inscripción');
select is(pg_temp.lista('e5'), 'Alfa', 'Futura: solo b1');
select is(pg_temp.casas('e5', 'b1'), '0',
          'casas: b1 se inscribió en Futura hoy: lo que cargó antes (en En curso) no cuenta ahí');
select is(pg_temp.fila('e2', 'b2'), '-|-|-|-|Vieja@Ciudad uno q98:-100..-70',
          'Cierre (terminada) se lee: el historial se consulta también al cierre');
select is(pg_temp.lista('e2'), 'Bravo,Cruz', 'Cierre: b2 y b3');
select is(pg_temp.casas('e2', 'b2'), '0', 'casas: b2 se inscribió en Cierre hoy: lo anterior no cuenta');
select is(pg_temp.casas('e2', 'b3'), '2',
          'casas: Cierre terminó el 30/09: cuentan las de b3 hasta ese día (también la de las 23:30) y no la del 01/10 '
          'ni la de hace 5 días, que son de la campaña siguiente en la misma ciudad');
select is(pg_temp.casas('e1', 'b3'), '1',
          'casas: b3 en En curso (sin fecha de fin): sigue en 1, lo suyo de Cierre es de otra ciudad de campaña');
select is(pg_temp.fila('e1', 'b2'),
          'Centro|Ciudad uno q98|-10|false|Centro@Ciudad uno q98:-40..-35,Centro@Ciudad dos q98:-35..-12',
          'lo de b2 en otras campañas no se mezcla con En curso');
select pg_temp.actuar_como(pg_temp.u('a2'));
select is(pg_temp.fila('e3', 'b2'), 'Otra zona|Ciudad uno q98|-2|false|(ninguna)',
          'el coordinador de Otra lee la suya');
select is(pg_temp.lista('e3'), 'Bravo', 'Otra: solo b2');
select is(pg_temp.casas('e3', 'b2'), '0',
          'casas: b2 se inscribió en Otra hoy: sus casas de En curso (y de la misma ciudad) no cuentan ahí');

-- El ADMIN lee cualquiera, también una terminada.
select pg_temp.actuar_como(pg_temp.u('ad'));
select is(pg_temp.lista('e1'), 'Alfa,Bravo,Cruz,Duarte,Eguren,Herrera,Ibarra,Jaramillo,Kappa', 'el admin lee En curso');
select is(pg_temp.fila('e2', 'b2'), '-|-|-|-|Vieja@Ciudad uno q98:-100..-70', 'y Cierre, que es de otro coordinador');
select is(pg_temp.fila('e3', 'b2'), 'Otra zona|Ciudad uno q98|-2|false|(ninguna)', 'y Otra');

-- ---------------------------------------------------------------------------
-- 5. El día de Montevideo no depende de la zona horaria de la sesión
-- ---------------------------------------------------------------------------
select pg_temp.actuar_como(pg_temp.u('a1'));
select set_config('TimeZone', 'Pacific/Kiritimati', true);
select is(pg_temp.fila('e1', 'b1'),
          'Centro|Ciudad uno q98|-15|false|Norte@Ciudad uno q98:-50..-30,Puerto@Ciudad dos q98:-30..-20x',
          'con la sesión en UTC+14 las fechas son las mismas');
select set_config('TimeZone', 'Etc/GMT+12', true);
select is(pg_temp.fila('e1', 'b2'),
          'Centro|Ciudad uno q98|-10|false|Centro@Ciudad uno q98:-40..-35,Centro@Ciudad dos q98:-35..-12',
          'y con la sesión en UTC-12 también (el tramo de las 00:30 de Montevideo no cambia de día)');
select set_config('TimeZone', 'UTC', true);

-- ---------------------------------------------------------------------------
-- 6. Se arma solo: asignar, cambiar y quitar (los triggers de la 0022, de punta a punta)
-- ---------------------------------------------------------------------------
select is(pg_temp.fila('e1', 'b4'), '-|-|-|-|(ninguna)', 'antes: b4 sin zona y sin historia');
select lives_ok(format('select public.asignar_zona(%L, %L, %L)', pg_temp.u('e1'), pg_temp.u('b4'), pg_temp.u('d1')),
                'el coordinador le asigna Centro a b4');
select is(pg_temp.fila('e1', 'b4'), 'Centro|Ciudad uno q98|0|false|(ninguna)',
          'b4: Centro desde hoy, y todavía sin anteriores');
select is(pg_temp.casas('e1', 'b4'), '1', 'casas: asignarle una zona no cambia las que cargó');
select lives_ok(format('select public.asignar_zona(%L, %L, %L)', pg_temp.u('e1'), pg_temp.u('b4'), pg_temp.u('d2')),
                'se la cambia por Norte');
select is(pg_temp.fila('e1', 'b4'), 'Norte|Ciudad uno q98|0|false|Centro@Ciudad uno q98:0..0',
          'b4: Norte desde hoy, y Centro pasó a anterior (de hoy a hoy)');
select lives_ok(format('select public.quitar_zona(%L, %L)', pg_temp.u('e1'), pg_temp.u('b4')),
                'se la quita');
select is(pg_temp.fila('e1', 'b4'), '-|-|-|-|Centro@Ciudad uno q98:0..0,Norte@Ciudad uno q98:0..0',
          'b4: sin zona, con las dos anteriores en el orden en que las tuvo');
select is(pg_temp.casas('e1', 'b4'), '1', 'casas: cambiarle la zona y quitársela no le resta casas');
select pg_temp.actuar_como_servidor();
select pg_temp.ubic('b4', 'c2', 0);
select pg_temp.actuar_como(pg_temp.u('a1'));
select is(pg_temp.casas('e1', 'b4'), '2', 'casas: una casa nueva, ya sin zona, suma');
select lives_ok(format('select public.asignar_zona(%L, %L, %L)', pg_temp.u('e1'), pg_temp.u('b4'), pg_temp.u('d1')),
                'le vuelve a asignar Centro');
select is(pg_temp.fila('e1', 'b4'), 'Centro|Ciudad uno q98|0|false|Centro@Ciudad uno q98:0..0,Norte@Ciudad uno q98:0..0',
          'b4: Centro de nuevo (la misma zona figura de zona de hoy y de anterior), con las dos de antes');

-- ---------------------------------------------------------------------------
-- 7. Leer no escribe nada
-- ---------------------------------------------------------------------------
select pg_temp.actuar_como_servidor();
-- Las escrituras de la sección 6 cambiaron el historial: la foto se toma después de ellas.
delete from antes_historial;
insert into antes_historial
  select count(*), coalesce(sum(sync_version), 0), max(updated_at) from public.campania_colportor_zona_historial;
select pg_temp.actuar_como(pg_temp.u('a1'));
select ok((select count(*) from public.zonas_por_colportor(pg_temp.u('e1'))) > 0, 'se lee En curso');
select ok((select count(*) from public.zonas_por_colportor(pg_temp.u('e2'))) > 0, 'se lee Cierre');
select ok((select count(*) from public.zonas_por_colportor(pg_temp.u('e5'))) > 0, 'se lee Futura');
select pg_temp.actuar_como_servidor();
select is((select format('%s|%s|%s', n, v, u) from antes_historial),
          (select format('%s|%s|%s', count(*), coalesce(sum(sync_version), 0), max(updated_at))
             from public.campania_colportor_zona_historial),
          'leer no agrega, cambia ni borra ningún tramo del historial');

select * from finish();
rollback;
