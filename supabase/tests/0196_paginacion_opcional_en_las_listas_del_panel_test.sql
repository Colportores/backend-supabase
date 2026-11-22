-- pgTAP · migración 0196 (backend-supabase#290, seguimiento de front-coordinadores-web#192): paginación opcional
-- (p_limite, p_desplazamiento) en las siete RPC de lista del panel que pueden pasar de 1000 filas.
--   1. La forma: la firma nueva de cada función (la vieja ya no está), sus privilegios, el helper interno cerrado.
--   2. Sin parámetros, o con p_limite null y p_desplazamiento 0, cada función devuelve lo de siempre, en el mismo orden.
--   3. Primera página, la siguiente y la última: juntas dan la lista entera, sin repetir ni saltear filas.
--   4. Un desplazamiento pasado del final da la lista vacía; un límite de 1 a 1000 (el max_rows de PostgREST) vale.
--   5. Un límite o un desplazamiento fuera de rango es 22023 (nunca se recorta en silencio); el permiso va antes.
--   6. Datos límite: una lista de 1200 filas se recorre entera por páginas de 1000 y de 500, sin repetir ni perder ninguna.
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

create or replace function pg_temp.u(p text) returns uuid language sql immutable as $$
  select ('01920000-0000-7000-8000-0000000196' || p)::uuid
$$;
create or replace function pg_temp.hoy() returns date language sql stable as $$
  select (now() at time zone 'America/Montevideo')::date
$$;
create or replace function pg_temp.error_de(p_sql text) returns text language plpgsql as $$
begin
  execute p_sql;
  return 'ok';
exception when others then
  return sqlstate;
end $$;

-- Lo que devuelve una función, como «clave,clave,…» en el orden en que sale ('-' si no hay filas).
create or replace function pg_temp.clave_de(p_f text) returns text language sql immutable as $$
  select case p_f
    when 'colportores_de_campania' then 'right(r.usuario_id::text, 2)'
    when 'ciudades_de_campania' then 'right(r.campania_ciudad_id::text, 2)'
    when 'zonas_por_colportor' then 'right(r.colportor_id::text, 2)'
    when 'acompaniamientos_por_colportor' then 'right(r.colportor_id::text, 2)'
    when 'historial_de_acompaniamientos' then 'right(r.jornada_id::text, 2) || '':'' || coalesce(right(r.acompaniante_id::text, 2), ''-'')'
    when 'jornadas_cerradas_de_colportor' then 'right(r.jornada_id::text, 2) || '':'' || coalesce(right(r.acompaniante_id::text, 2), ''-'')'
    when 'becas_de_campania' then 'right(r.usuario_id::text, 2)'
  end
$$;
-- p_f es el nombre de la función; p_args, los argumentos previos a la paginación (ya con comillas); p_pag, por ejemplo
-- «p_limite => 2, p_desplazamiento => 2», o ''.
create or replace function pg_temp.sale(p_f text, p_args text, p_pag text default '') returns text language plpgsql as $$
declare
  v text;
begin
  execute format($f$ select coalesce(string_agg(k, ',' order by ord), '-')
                       from (select %s as k, row_number() over () as ord
                               from public.%s(%s%s) r) x $f$,
                 pg_temp.clave_de(p_f), p_f, p_args, case when p_pag = '' then '' else ', ' || p_pag end)
    into v;
  return v;
end $$;
-- Las filas de una lista (separadas por coma) desde la posición p_desde, p_cuantos como máximo ('-' si no hay).
create or replace function pg_temp.rebanada(p_lista text, p_desde integer, p_cuantos integer) returns text language sql immutable as $$
  select coalesce(nullif(array_to_string((string_to_array(p_lista, ','))[p_desde:p_desde + p_cuantos - 1], ','), ''), '-')
$$;
-- Recorre la lista como lo hace el panel: páginas de p_limite hasta que una venga con menos filas que p_limite.
-- Devuelve «cantidad de páginas|filas juntas».
create or replace function pg_temp.recorrer(p_f text, p_args text, p_limite integer) returns text language plpgsql as $$
declare
  v_pag text;
  v_filas text[] := '{}';
  v_n integer := 0;
  v_cant integer;
begin
  loop
    v_pag := pg_temp.sale(p_f, p_args, format('p_limite => %s, p_desplazamiento => %s', p_limite, v_n * p_limite));
    v_n := v_n + 1;
    v_cant := case when v_pag = '-' then 0 else cardinality(string_to_array(v_pag, ',')) end;
    if v_cant > 0 then
      v_filas := v_filas || string_to_array(v_pag, ',');
    end if;
    exit when v_cant < p_limite or v_n > 50;
  end loop;
  return v_n || '|' || coalesce(nullif(array_to_string(v_filas, ','), ''), '-');
end $$;

-- --- fixtures (como postgres) --------------------------------------------------
-- Staff: c1 coordinador de e1; c2 coordinador de otra campaña (e2). Colportores de e1: b1 Ana Alfa (zona Centro),
-- b2 Beto Bravo, b3 Carla Cruz, b4 Diego Duarte, b5 Elena Eguren (los apellidos fijan el orden).
-- Ciudades de e1: 71 (Ciudad A), 72 (Ciudad B), 73 (Ciudad C; el nombre fija el orden).
-- Jornadas cerradas de b1 (hace 10, 9, 8 y 7 días): f1 con dos acompañantes, b2 y b3 (sale dos veces); f2 con b2; f3 sin
-- acompañante; f4 con b4. b2 tiene f5, acompañada por b1.
insert into auth.users (id, instance_id, aud, role, email, encrypted_password, confirmed_at, created_at, updated_at)
select pg_temp.u(s), '00000000-0000-0000-0000-000000000000',
       'authenticated', 'authenticated', 'pg196-' || s || '@example.com', 'x', now(), now(), now()
  from unnest(array['c1','c2','b1','b2','b3','b4','b5']) s;
update public.usuario u set nombre = x.n, apellido = x.a
  from (values ('b1','Ana','Alfa'), ('b2','Beto','Bravo'), ('b3','Carla','Cruz'),
               ('b4','Diego','Duarte'), ('b5','Elena','Eguren')) x(s, n, a)
 where u.id = pg_temp.u(x.s);
insert into public.usuario_rol (usuario_id, rol_id)
select pg_temp.u(x.s), r.id
  from (values ('c1','COORDINADOR'), ('c2','COORDINADOR'), ('b1','COLPORTOR'), ('b2','COLPORTOR'), ('b3','COLPORTOR'),
               ('b4','COLPORTOR'), ('b5','COLPORTOR')) x(s, codigo)
  join public.rol r on r.codigo = x.codigo;

insert into public.pais (id, nombre, iso_code) values (pg_temp.u('f0'), 'Pais pg196', 'ZU');
insert into public.ciudad (id, nombre, departamento, pais_id, lat_centro, lon_centro, zoom_inicial) values
  (pg_temp.u('91'), 'Ciudad A pg196', 'Departamento uno', pg_temp.u('f0'), -34.91, -56.18, 13),
  (pg_temp.u('92'), 'Ciudad B pg196', 'Departamento dos', pg_temp.u('f0'), -34.91, -56.18, 13),
  (pg_temp.u('93'), 'Ciudad C pg196', 'Departamento tres', pg_temp.u('f0'), -34.91, -56.18, 13);
insert into public.campania (id, nombre, tipo, fecha_inicio, fecha_fin, coordinador_id) values
  (pg_temp.u('e1'), 'e1 pg196', 'VERANO', pg_temp.hoy() - 60, pg_temp.hoy() + 30, pg_temp.u('c1')),
  (pg_temp.u('e2'), 'e2 pg196', 'VERANO', pg_temp.hoy() - 60, pg_temp.hoy() + 30, pg_temp.u('c2'));
insert into public.campania_ciudad (id, campania_id, ciudad_id) values
  (pg_temp.u('71'), pg_temp.u('e1'), pg_temp.u('91')),
  (pg_temp.u('72'), pg_temp.u('e1'), pg_temp.u('92')),
  (pg_temp.u('73'), pg_temp.u('e1'), pg_temp.u('93'));
insert into public.zona (id, nombre, campania_ciudad_id, tipo_forma, color, poligono_geojson) values
  (pg_temp.u('d1'), 'Centro', pg_temp.u('71'), 'ESQUINAS', '#112233',
   '{"type":"Polygon","coordinates":[[[-56.19,-34.92],[-56.17,-34.92],[-56.17,-34.91],[-56.19,-34.91],[-56.19,-34.92]]]}'::jsonb);
insert into public.campania_colportor (campania_id, usuario_id, zona_id, created_at) values
  (pg_temp.u('e1'), pg_temp.u('b1'), pg_temp.u('d1'), now() - interval '200 days'),
  (pg_temp.u('e1'), pg_temp.u('b2'), null, now() - interval '200 days'),
  (pg_temp.u('e1'), pg_temp.u('b3'), null, now() - interval '200 days'),
  (pg_temp.u('e1'), pg_temp.u('b4'), null, now() - interval '200 days'),
  (pg_temp.u('e1'), pg_temp.u('b5'), null, now() - interval '200 days');

insert into public.jornada (id, colportor_id, inicio, fin)
select pg_temp.u(x.id), pg_temp.u(x.colp),
       (pg_temp.hoy() - x.dias + time '09:00') at time zone 'America/Montevideo',
       (pg_temp.hoy() - x.dias + time '09:00') at time zone 'America/Montevideo' + interval '2 hours'
  from (values ('f1','b1',10), ('f2','b1',9), ('f3','b1',8), ('f4','b1',7), ('f5','b2',6)) x(id, colp, dias);
insert into public.jornada_acompaniante (id, jornada_id, colportor_id, acompaniante_id, created_at)
select pg_temp.u(x.id), pg_temp.u(x.j), pg_temp.u(x.colp), pg_temp.u(x.acomp), now() - make_interval(secs => x.orden)
  from (values ('a1','f1','b1','b2', 50), ('a2','f1','b1','b3', 40), ('a3','f2','b1','b2', 30),
               ('a4','f4','b1','b4', 20), ('a5','f5','b2','b1', 10)) x(id, j, colp, acomp, orden);

-- Cada fila: función, argumentos y la lista entera esperada, en el orden de siempre.
create temp table caso (f text, args text, completo text) on commit drop;
grant all on caso to public;
insert into caso values
  ('colportores_de_campania',        format('%L::uuid', pg_temp.u('e1')), 'b1,b2,b3,b4,b5'),
  ('ciudades_de_campania',           format('%L::uuid', pg_temp.u('e1')), '71,72,73'),
  ('zonas_por_colportor',            format('%L::uuid', pg_temp.u('e1')), 'b1,b2,b3,b4,b5'),
  ('acompaniamientos_por_colportor', format('%L::uuid', pg_temp.u('e1')), 'b3,b4,b5,b1,b2'),
  ('historial_de_acompaniamientos',  format('%L::uuid', pg_temp.u('e1')), 'f5:b1,f4:b4,f2:b2,f1:b2,f1:b3'),
  ('jornadas_cerradas_de_colportor', format('%L::uuid, %L::uuid', pg_temp.u('e1'), pg_temp.u('b1')),
                                     'f4:b4,f3:-,f2:b2,f1:b2,f1:b3'),
  ('becas_de_campania',              format('%L::uuid', pg_temp.u('e1')), 'b1,b2,b3,b4,b5');

-- ---------------------------------------------------------------------------
-- 1. La forma
-- ---------------------------------------------------------------------------
select is((select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'public' and p.proname in (select f from pg_temp.caso)), 7::bigint,
          'cada una de las siete es una sola función (la firma vieja ya no está: sería ambigua por nombre)');
select is(pg_get_function_arguments('public.colportores_de_campania(uuid, integer, integer)'::regprocedure),
          'p_campania_id uuid, p_limite integer DEFAULT NULL::integer, p_desplazamiento integer DEFAULT 0',
          'los dos parámetros nuevos van al final y son opcionales');
select is(pg_get_function_arguments('public.historial_de_acompaniamientos(uuid, uuid, integer, integer)'::regprocedure),
          'p_campania_id uuid, p_colportor_id uuid DEFAULT NULL::uuid, p_limite integer DEFAULT NULL::integer, p_desplazamiento integer DEFAULT 0',
          'el historial conserva el filtro por colportor opcional y suma la paginación');
select is((select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'public' and p.proname in (select f from pg_temp.caso)
              and p.prosecdef and p.provolatile = 'v' and p.proconfig = array['search_path=""']), 7::bigint,
          'las siete siguen siendo SECURITY DEFINER, VOLATILE y con search_path vacío');
select is((select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'public' and p.proname in (select f from pg_temp.caso)
              and has_function_privilege('authenticated', p.oid, 'execute')
              and not has_function_privilege('anon', p.oid, 'execute')
              and not has_function_privilege('public', p.oid, 'execute')), 7::bigint,
          'las siete las ejecuta authenticated y no anon ni PUBLIC');
select is((select array_agg(p.proname::text order by p.proname) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'public' and p.proname in (select f from pg_temp.caso)
              and has_function_privilege('service_role', p.oid, 'execute')),
          array['colportores_de_campania']::text[],
          'solo colportores_de_campania sigue abierta a service_role (como desde la 0015)');
select is((select count(*) from unnest(array['authenticated', 'anon', 'service_role']) r
            where has_function_privilege(r, 'public.validar_pagina_de_lista(integer, integer)', 'execute')), 0::bigint,
          'el helper de la validación es interno: nadie lo ejecuta directo');

-- ---------------------------------------------------------------------------
-- 2 a 4. Sin parámetros, primera página, siguiente, última, pasada del final
-- ---------------------------------------------------------------------------
select pg_temp.actuar_como(pg_temp.u('c1'));

select is(pg_temp.sale(f, args), completo, f || ': sin parámetros devuelve la lista entera, en el orden de siempre')
  from pg_temp.caso order by f;
select is(pg_temp.sale(f, args, 'p_limite => null, p_desplazamiento => 0'), completo,
          f || ': con p_limite null y p_desplazamiento 0 es lo mismo')
  from pg_temp.caso order by f;
select is(pg_temp.sale(f, args, 'p_limite => 1000'), completo, f || ': un límite de 1000 (el máximo) alcanza para todas')
  from pg_temp.caso order by f;
select is(pg_temp.sale(f, args, 'p_limite => 2'), pg_temp.rebanada(completo, 1, 2), f || ': la primera página son las dos primeras')
  from pg_temp.caso order by f;
select is(pg_temp.sale(f, args, 'p_limite => 2, p_desplazamiento => 2'), pg_temp.rebanada(completo, 3, 2),
          f || ': la siguiente sigue donde terminó la primera')
  from pg_temp.caso order by f;
select is(pg_temp.sale(f, args, format('p_limite => 2, p_desplazamiento => %s',
                                        ((cardinality(string_to_array(completo, ',')) - 1) / 2) * 2)),
          pg_temp.rebanada(completo, ((cardinality(string_to_array(completo, ',')) - 1) / 2) * 2 + 1, 2),
          f || ': la última página trae lo que queda')
  from pg_temp.caso order by f;
select is(pg_temp.recorrer(f, args, 2),
          ((cardinality(string_to_array(completo, ',')) + 2) / 2) || '|' || completo,
          f || ': pedir páginas hasta una más corta da la lista entera, sin repetir ni saltear filas')
  from pg_temp.caso order by f;
select is(pg_temp.recorrer(f, args, 1),
          (cardinality(string_to_array(completo, ',')) + 1) || '|' || completo,
          f || ': también de a una fila')
  from pg_temp.caso order by f;
select is(pg_temp.sale(f, args, 'p_limite => 1, p_desplazamiento => 1'), pg_temp.rebanada(completo, 2, 1),
          f || ': una fila sola, saltando la primera')
  from pg_temp.caso order by f;
select is(pg_temp.sale(f, args, 'p_desplazamiento => 1'), pg_temp.rebanada(completo, 2, 100),
          f || ': solo el desplazamiento (sin límite) saltea y trae el resto')
  from pg_temp.caso order by f;
select is(pg_temp.sale(f, args, 'p_limite => 5, p_desplazamiento => 100'), '-',
          f || ': un desplazamiento pasado del final da la lista vacía (no es un error)')
  from pg_temp.caso order by f;

-- ---------------------------------------------------------------------------
-- 5. Fuera de rango: 22023 y nunca un recorte en silencio; el permiso va antes
-- ---------------------------------------------------------------------------
select is(pg_temp.error_de(format('select * from public.%s(%s, p_limite => 0)', f, args)), '22023',
          f || ': un límite de 0 es 22023')
  from pg_temp.caso order by f;
select is(pg_temp.error_de(format('select * from public.%s(%s, p_limite => -5)', f, args)), '22023',
          f || ': un límite negativo es 22023')
  from pg_temp.caso order by f;
select is(pg_temp.error_de(format('select * from public.%s(%s, p_limite => 1001)', f, args)), '22023',
          f || ': un límite de 1001 es 22023 (PostgREST cortaría en 1000 sin avisar)')
  from pg_temp.caso order by f;
select is(pg_temp.error_de(format('select * from public.%s(%s, p_desplazamiento => -1)', f, args)), '22023',
          f || ': un desplazamiento negativo es 22023')
  from pg_temp.caso order by f;
select is(pg_temp.error_de(format('select * from public.%s(%s, p_desplazamiento => null)', f, args)), '22023',
          f || ': un desplazamiento null es 22023')
  from pg_temp.caso order by f;
select is(pg_temp.error_de(format('select * from public.%s(%s, p_limite => 1000, p_desplazamiento => 0)', f, args)), 'ok',
          f || ': el límite de 1000 y el desplazamiento 0 pasan')
  from pg_temp.caso order by f;

-- El permiso, antes de mirar la página: el colportor y la coordinadora de otra campaña reciben 42501 aunque pidan mal.
select pg_temp.actuar_como(pg_temp.u('b1'));
select is(pg_temp.error_de(format('select * from public.%s(%s, p_limite => 0)', f, args)), '42501',
          f || ': un colportor recibe 42501, no 22023')
  from pg_temp.caso order by f;
select pg_temp.actuar_como(pg_temp.u('c2'));
select is(pg_temp.error_de(format('select * from public.%s(%s, p_limite => 1001)', f, args)), '42501',
          f || ': la coordinadora de otra campaña recibe 42501, no 22023')
  from pg_temp.caso order by f;
select is(pg_temp.error_de(format('select * from public.%s(%s, p_limite => 2)', f, args)), '42501',
          f || ': y con una página válida también 42501')
  from pg_temp.caso order by f;
select pg_temp.actuar_como(pg_temp.u('c1'));
select is(pg_temp.error_de(format('select * from public.colportores_de_campania(%L::uuid, p_limite => 0)', pg_temp.u('ee'))),
          'CZ001', 'una campaña inexistente sigue dando CZ001 antes de mirar la página');

-- ---------------------------------------------------------------------------
-- 6. Datos límite: 1200 inscriptos se recorren por páginas de 1000 y de 500 sin repetir ni perder ninguno
-- ---------------------------------------------------------------------------
select pg_temp.actuar_como_servidor();
insert into auth.users (id, instance_id, aud, role, email, encrypted_password, confirmed_at, created_at, updated_at)
select ('01920000-0000-7000-8000-0001' || lpad(to_hex(n), 8, '0'))::uuid, '00000000-0000-0000-0000-000000000000',
       'authenticated', 'authenticated', 'pg196-m' || n || '@example.com', 'x', now(), now(), now()
  from generate_series(1, 1200) n;
update public.usuario u set nombre = 'Nombre', apellido = 'Zeta' || lpad(('x' || right(u.id::text, 8))::bit(32)::int::text, 5, '0')
 where u.id::text like '01920000-0000-7000-8000-0001%';
insert into public.campania (id, nombre, tipo, fecha_inicio, fecha_fin, coordinador_id)
values (pg_temp.u('e3'), 'e3 pg196 larga', 'VERANO', pg_temp.hoy() - 60, pg_temp.hoy() + 30, pg_temp.u('c1'));
insert into public.campania_colportor (campania_id, usuario_id, created_at)
select pg_temp.u('e3'), u.id, now() - interval '200 days'
  from public.usuario u where u.id::text like '01920000-0000-7000-8000-0001%';

create temp table larga_esperada on commit drop as
  select array_agg(cc.usuario_id order by u.apellido, u.nombre, u.id) as ids
    from public.campania_colportor cc join public.usuario u on u.id = cc.usuario_id
   where cc.campania_id = pg_temp.u('e3');
grant all on larga_esperada to public;

create or replace function pg_temp.ids_de(p_limite integer, p_desplazamiento integer) returns uuid[] language sql as $$
  select coalesce(array_agg(x.usuario_id order by x.ord), '{}')
    from (select r.usuario_id, row_number() over () as ord
            from public.colportores_de_campania(pg_temp.u('e3'), p_limite, p_desplazamiento) r) x
$$;

select pg_temp.actuar_como(pg_temp.u('c1'));
select is(cardinality((select ids from larga_esperada)), 1200, 'la campaña larga tiene 1200 inscriptos');
select is(cardinality(pg_temp.ids_de(1000, 0)), 1000, 'la primera página de 1000 trae 1000');
select is(cardinality(pg_temp.ids_de(1000, 1000)), 200, 'la segunda trae los 200 que quedan (menos que el límite: es la última)');
select is(pg_temp.ids_de(1000, 0) || pg_temp.ids_de(1000, 1000), (select ids from larga_esperada),
          'juntas son los 1200, en el orden y sin repetir ni perder ninguno');
select is(pg_temp.ids_de(500, 0) || pg_temp.ids_de(500, 500) || pg_temp.ids_de(500, 1000), (select ids from larga_esperada),
          'también de a 500: 500 + 500 + 200');
select is(cardinality(pg_temp.ids_de(1000, 1200)), 0, 'después de la última no hay nada');
select is(cardinality(pg_temp.ids_de(null, 0)), 1200, 'sin límite la función devuelve todas (PostgREST las cortaría en 1000: por eso se pagina)');
select is(pg_temp.ids_de(1, 1199), array[(select ids[1200] from larga_esperada)], 'la última fila sola, por su posición');

select * from finish();
rollback;
