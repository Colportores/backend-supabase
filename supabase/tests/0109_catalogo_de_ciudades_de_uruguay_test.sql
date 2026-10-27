-- pgTAP · el catálogo de ciudades y departamentos de Uruguay desde OpenStreetMap, ciudad.origen y el alta a mano
-- (migración 0109, backend-supabase#139, HU-ADM-005; decisiones de Cristian del 23/10, «Área depto» y «Fuera de OSM»)
--
-- La columna origen (OSM / MANUAL); la lista embebida (catalogo_osm_uruguay: 19 departamentos con su rectángulo,
-- ciudades que cuadran con la base); departamentos_de_uruguay(); la carga de cargar_catalogo_ciudades() SIN duplicar
-- ni borrar (se prueba con un catálogo chico, de cifras exactas, y con el real: sin duplicados e idempotente); el
-- alta a mano (solo nombre y departamento de la lista, aviso de parecido que no frena); y los privilegios.
-- Que la migración misma cargue sobre datos de antes y no pierda ni una fila: supabase/tests_migracion/0109_ok.
begin;
select * from no_plan();

create or replace function pg_temp.u(p_sufijo text) returns uuid language sql immutable as $$
  select ('01920000-0000-7000-8000-0000000109' || p_sufijo)::uuid
$$;

create or replace function pg_temp.actuar_como_authenticated() returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', json_build_object('sub', pg_temp.u('9a'), 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', pg_temp.u('9a')::text, true);
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

-- Una sentencia con el trigger del departamento apagado: arma una ciudad «vieja» (sin departamento).
create or replace function pg_temp.sin_trigger(p_sql text) returns void language plpgsql as $$
begin
  alter table public.ciudad disable trigger ciudad_departamento_obligatorio;
  begin
    execute p_sql;
  exception when others then
    alter table public.ciudad enable trigger ciudad_departamento_obligatorio;
    raise;
  end;
  alter table public.ciudad enable trigger ciudad_departamento_obligatorio;
end $$;

-- ============================================================================
-- 1. ciudad.origen
-- ============================================================================

select has_column('public', 'ciudad', 'origen', 'ciudad tiene origen');
select col_type_is('public', 'ciudad', 'origen', 'text', 'origen es text');
select col_not_null('public', 'ciudad', 'origen', 'origen es obligatorio');
select col_default_is('public', 'ciudad', 'origen', 'MANUAL', 'origen vale MANUAL si nadie dice otra cosa: lo que ya estaba se cargó a mano');

insert into public.pais (id, nombre, iso_code) values (pg_temp.u('a1'), 'Uruguay', 'UY');

select lives_ok($$ insert into public.ciudad (id, nombre, departamento, pais_id, lat_centro, lon_centro)
                   values (pg_temp.u('c0'), 'Ciudad de prueba', 'Salto', pg_temp.u('a1'), -31.0, -57.0) $$,
                'una ciudad sin decir su origen se carga');
select is((select origen from public.ciudad where id = pg_temp.u('c0')), 'MANUAL', 'y queda MANUAL');
select throws_ok($$ update public.ciudad set origen = 'GOOGLE' where id = pg_temp.u('c0') $$, '23514', null,
                 'solo OSM o MANUAL (ciudad_origen_check)');
select throws_ok($$ update public.ciudad set origen = null where id = pg_temp.u('c0') $$, '23502', null, 'y nunca vacío');
select lives_ok($$ update public.ciudad set origen = 'OSM' where id = pg_temp.u('c0') $$, 'OSM es válido');
delete from public.ciudad where id = pg_temp.u('c0');

-- ============================================================================
-- 2. La lista embebida y los departamentos
-- ============================================================================

select is(jsonb_array_length(public.catalogo_osm_uruguay() -> 'departamentos'), 19, 'la lista trae los 19 departamentos de Uruguay');
select is(public.catalogo_osm_uruguay() #>> '{pais,iso_code}', 'UY', 'y el país');
select is(jsonb_array_length(public.catalogo_osm_uruguay() #> '{pais,bbox}'), 4, 'con su rectángulo [oeste, sur, este, norte]');
select matches(public.catalogo_osm_uruguay() #>> '{fuente,atribucion}', 'OpenStreetMap', 'lleva la atribución de OSM');
select is(public.catalogo_osm_uruguay() #>> '{fuente,licencia}', 'ODbL 1.0', 'y la licencia');
select matches(public.catalogo_osm_uruguay() #>> '{fuente,datos_osm_de}', '^\d{4}-\d{2}-\d{2}T', 'y de qué día son los datos de OSM');
select cmp_ok(jsonb_array_length(public.catalogo_osm_uruguay() -> 'ciudades'), '>=', 100, 'y cientos de ciudades, pueblos y villas');

select is((select count(*)::int
             from jsonb_to_recordset(public.catalogo_osm_uruguay() -> 'departamentos') as d(nombre text, bbox jsonb)
            where jsonb_array_length(d.bbox) = 4
              and (d.bbox ->> 0)::float8 < (d.bbox ->> 2)::float8 and (d.bbox ->> 1)::float8 < (d.bbox ->> 3)::float8), 19,
          'cada departamento trae un rectángulo bien formado');

select is((select count(*)::int
             from jsonb_to_recordset(public.catalogo_osm_uruguay() -> 'ciudades') as c(nombre text, departamento text)
            where c.departamento not in (select public.departamentos_de_uruguay())), 0,
          'toda ciudad de la lista está en uno de los 19 departamentos, escrito como en la lista');
select is((select count(*)::int
             from public.filas_del_catalogo(public.catalogo_osm_uruguay())), jsonb_array_length(public.catalogo_osm_uruguay() -> 'ciudades'),
          'no hay dos ciudades con el mismo nombre en el mismo departamento (sin tildes ni mayúsculas)');
select is((select count(*)::int
             from public.filas_del_catalogo(public.catalogo_osm_uruguay())
            where oeste is not null and not (lon between oeste and este and lat between sur and norte)), 0,
          'el centro de cada ciudad cae adentro de su rectángulo (la base lo exige)');
select ok(exists (select 1 from public.filas_del_catalogo(public.catalogo_osm_uruguay()) where nombre_n = 'montevideo' and departamento_n = 'montevideo'),
          'Montevideo está');
select ok(exists (select 1 from public.filas_del_catalogo(public.catalogo_osm_uruguay()) where oeste is null),
          'y hay ciudades sin límite en OSM: quedan sin rectángulo');

select results_eq(
  $$ select public.departamentos_de_uruguay() $$,
  $$ select d.nombre from jsonb_to_recordset(public.catalogo_osm_uruguay() -> 'departamentos') as d(nombre text)
      order by public.normalizar_busqueda(d.nombre), d.nombre $$,
  'departamentos_de_uruguay() devuelve los 19 A-Z');
select ok(exists (select 1 from public.departamentos_de_uruguay() d where d = 'Paysandú'), 'con tilde, como en la lista (Paysandú)');
select ok(exists (select 1 from public.departamentos_de_uruguay() d where d = 'Río Negro'), 'y con espacio (Río Negro)');
select ok(exists (select 1 from public.departamentos_de_uruguay() d where d = 'Treinta y Tres'), 'y Treinta y Tres');

-- ============================================================================
-- 3. La distancia de edición
-- ============================================================================

select is(public.distancia_de_edicion('kitten', 'sitting'), 3, 'kitten → sitting: 3');
select is(public.distancia_de_edicion('salto', 'salto'), 0, 'iguales: 0');
select is(public.distancia_de_edicion('salto', 'salta'), 1, 'una letra: 1');
select is(public.distancia_de_edicion('', 'abc'), 3, 'vacío contra abc: 3');
select is(public.distancia_de_edicion(null, 'ab'), 2, 'null cuenta como vacío');
select is(public.distancia_de_edicion('abc', null), 3, 'en los dos sentidos');
select is(public.distancia_de_edicion('flaw', 'lawn'), 2, 'flaw → lawn: 2');

-- ============================================================================
-- 4. La carga, con un catálogo chico (cifras exactas)
-- ============================================================================

-- Lo que había antes de la carga:
--   c1 Montevideo / Montevideo, con su rectángulo (0031) y el centro adentro        -> casa; conserva su rectángulo
--   c2 salto / salto (minúsculas), sin rectángulo, centro adentro del de la lista   -> casa; recibe el rectángulo y «Salto»
--   c3 Rivera / Rivera, sin rectángulo, centro AFUERA del de la lista               -> casa; no recibe rectángulo
--   c4 Pueblo Aparte / Rivera                                                       -> no casa: no se toca
--   c5 Colonia, SIN departamento (una vieja)                                        -> no casa: no se toca
--   c6 San José / San José, dada de baja                                            -> casa con una baja: no se vuelve a crear
--   c7 Otro País City / Salto, de OTRO país                                         -> otro país: ni se mira
-- (7 filas, 6 de Uruguay)
insert into public.pais (id, nombre, iso_code) values (pg_temp.u('a2'), 'Chile', 'CL');
insert into public.ciudad (id, nombre, departamento, pais_id, lat_centro, lon_centro, bbox_oeste, bbox_sur, bbox_este, bbox_norte, zoom_inicial, deleted_at) values
  (pg_temp.u('c1'), 'Montevideo',   'Montevideo', pg_temp.u('a1'), -34.9011, -56.1645, -56.433, -34.945, -55.948, -34.701, 13, null),
  (pg_temp.u('c2'), 'salto',        'salto',      pg_temp.u('a1'), -31.3833, -57.9667, null, null, null, null, 14, null),
  (pg_temp.u('c3'), 'Rivera',       'Rivera',     pg_temp.u('a1'), -10.0,    -10.0,    null, null, null, null, 13, null),
  (pg_temp.u('c4'), 'Pueblo Aparte','Rivera',     pg_temp.u('a1'), -31.0,    -55.5,    null, null, null, null, 13, null),
  (pg_temp.u('c6'), 'San José',     'San José',   pg_temp.u('a1'), -34.3,    -56.7,    null, null, null, null, 13, '2026-05-01 10:00:00+00'),
  (pg_temp.u('c7'), 'Otro País City','Salto',     pg_temp.u('a2'), -33.0,    -70.0,    null, null, null, null, 13, null);
select pg_temp.sin_trigger($$ insert into public.ciudad (id, nombre, pais_id, lat_centro, lon_centro)
                              values (pg_temp.u('c5'), 'Colonia', pg_temp.u('a1'), -34.47, -57.84) $$);

create temporary table foto_ciudad on commit drop as select * from public.ciudad;
grant select on foto_ciudad to public;

create temporary table catalogo_chico on commit drop as
select $c$
{"version":1,
 "ciudades":[
  {"nombre":"Montevideo","departamento":"Montevideo","tipo":"city","osm":"node/1","lat":-34.9,"lon":-56.2,"bbox":[-56.43,-34.94,-56.02,-34.70]},
  {"nombre":"Salto","departamento":"Salto","tipo":"city","osm":"node/2","lat":-31.38,"lon":-57.96,"bbox":[-58.1,-31.5,-57.8,-31.3]},
  {"nombre":"Rivera","departamento":"Rivera","tipo":"city","osm":"node/3","lat":-30.9,"lon":-55.54,"bbox":[-55.6,-31.0,-55.5,-30.8]},
  {"nombre":"San José","departamento":"San José","tipo":"city","osm":"node/4","lat":-34.34,"lon":-56.71,"bbox":null},
  {"nombre":"San José","departamento":"Colonia","tipo":"village","osm":"node/5","lat":-34.2,"lon":-57.5,"bbox":null},
  {"nombre":"Tranqueras","departamento":"Rivera","tipo":"town","osm":"node/6","lat":-31.19,"lon":-55.76,"bbox":null},
  {"nombre":"Villa Con Límite","departamento":"Rivera","tipo":"village","osm":"node/7","lat":-31.5,"lon":-55.5,"bbox":[-55.6,-31.6,-55.4,-31.4]},
  {"nombre":"Tranqueras","departamento":"Rivera","tipo":"village","osm":"node/8","lat":-31.19,"lon":-55.76,"bbox":null}
 ]}
$c$::jsonb as j;
grant select on catalogo_chico to public;

create temporary table resultado_1 on commit drop as
select public.cargar_catalogo_ciudades((select j from catalogo_chico)) as r;
grant select on resultado_1 to public;

select is((select r ->> 'pais' from resultado_1), 'true', 'la carga encontró el país Uruguay');
select is((select (r ->> 'emparejadas')::int from resultado_1), 4,
          'emparejó 4 de la lista: Montevideo, Salto, Rivera y la San José dada de baja (la repetida Tranqueras cuenta una vez)');
select is((select (r ->> 'insertadas')::int from resultado_1), 3,
          'y agregó 3: San José de Colonia, Tranqueras y la villa con límite');
select is((select (r ->> 'actualizadas')::int from resultado_1), 3, 'tocó 3 de las que estaban: Montevideo (origen), Salto y Rivera');

-- Nada se borró ni se duplicó.
select is((select count(*)::int from public.ciudad where id in (select id from foto_ciudad)), 7, 'ninguna de las 7 de antes desapareció');
select is((select count(*)::int from public.ciudad where pais_id = pg_temp.u('a1')), 6 + 3, 'las de Uruguay: las 6 de antes y 3 nuevas');
select is((select count(*)::int
             from (select public.normalizar_busqueda(nombre), public.normalizar_busqueda(departamento)
                     from public.ciudad where pais_id = pg_temp.u('a1') and deleted_at is null and departamento is not null
                    group by 1, 2 having count(*) > 1) d), 0,
          'ningún nombre repetido en un mismo departamento');

-- Las que casan.
select is((select origen from public.ciudad where id = pg_temp.u('c1')), 'OSM', 'Montevideo quedó OSM');
select is((select (bbox_oeste, bbox_sur, bbox_este, bbox_norte)::text from public.ciudad where id = pg_temp.u('c1')),
          '(-56.433,-34.945,-55.948,-34.701)', 'y conserva su rectángulo de la 0031: el de OSM no lo pisa');
select is((select (lat_centro, lon_centro, zoom_inicial, nombre)::text from public.ciudad where id = pg_temp.u('c1')),
          '(-34.9011,-56.1645,13,Montevideo)', 'y su centro, su zoom y su nombre');
select is((select origen from public.ciudad where id = pg_temp.u('c2')), 'OSM', 'salto quedó OSM');
select is((select departamento from public.ciudad where id = pg_temp.u('c2')), 'Salto', 'con el departamento escrito como en la lista');
select is((select nombre from public.ciudad where id = pg_temp.u('c2')), 'salto', 'pero su nombre no se toca');
select is((select (bbox_oeste, bbox_sur, bbox_este, bbox_norte)::text from public.ciudad where id = pg_temp.u('c2')),
          '(-58.1,-31.5,-57.8,-31.3)', 'y, como no tenía rectángulo y su centro cae adentro del de OSM, lo recibe');
select is((select origen from public.ciudad where id = pg_temp.u('c3')), 'OSM', 'Rivera quedó OSM');
select is((select bbox_oeste from public.ciudad where id = pg_temp.u('c3')), null,
          'pero con el centro afuera del rectángulo de OSM no se le carga (la base lo rechazaría, y no se pisa lo suyo)');
select is((select deleted_at is not null and origen = 'MANUAL' from public.ciudad where id = pg_temp.u('c6')), true,
          'la San José dada de baja sigue de baja y no se tocó: no se vuelve a crear lo que Administración dio de baja');
select is((select count(*)::int from public.ciudad where pais_id = pg_temp.u('a1') and nombre = 'San José' and departamento = 'San José' and deleted_at is null), 0,
          'ni hay una San José viva en el departamento San José');

-- Las que faltan.
select is((select origen from public.ciudad where nombre = 'San José' and departamento = 'Colonia'), 'OSM', 'San José de Colonia se agregó, OSM (hay dos San José)');
select is((select (departamento, lat_centro, lon_centro, bbox_oeste is null)::text from public.ciudad where nombre = 'Tranqueras'),
          '(Rivera,-31.19,-55.76,t)', 'Tranqueras: con el centro de OSM y SIN rectángulo (OSM no trae su límite; no se inventa uno)');
select is((select (bbox_oeste, bbox_sur, bbox_este, bbox_norte)::text from public.ciudad where nombre = 'Villa Con Límite'),
          '(-55.6,-31.6,-55.4,-31.4)', 'la villa con límite en OSM lo trae');
select is((select count(*)::int from public.ciudad where public.normalizar_busqueda(nombre) = 'tranqueras'), 1,
          'dos filas de la lista con el mismo nombre en el mismo departamento son una sola ciudad');

-- Las que no casan: avisadas, no tocadas.
select is((select jsonb_array_length(r -> 'sin_pareja') from resultado_1), 2, 'dos ciudades de antes no figuran en la lista');
select ok((select (r -> 'sin_pareja') @> jsonb_build_array(jsonb_build_object('ciudad_id', pg_temp.u('c4'), 'nombre', 'Pueblo Aparte', 'departamento', 'Rivera')) from resultado_1),
          'se avisa Pueblo Aparte (nombre que no está en la lista)');
select ok((select (r -> 'sin_pareja') @> jsonb_build_array(jsonb_build_object('ciudad_id', pg_temp.u('c5'), 'nombre', 'Colonia', 'departamento', null)) from resultado_1),
          'y Colonia, que no tiene departamento: se completa con la guía de carga manual');
select is((select count(*)::int
             from public.ciudad c join foto_ciudad f using (id)
            where c.id in (pg_temp.u('c4'), pg_temp.u('c5'), pg_temp.u('c7'), pg_temp.u('c6'))
              and to_jsonb(c) is distinct from to_jsonb(f)), 0,
          'las que no casan, la de baja y la de otro país quedaron idénticas, sync_version incluido: ni un UPDATE');

-- Idempotente.
create temporary table suma_antes on commit drop as
select count(*) as n, sum(sync_version) as versiones, max(xmin_w::text::bigint) as xmin_max from public.ciudad;
grant select on suma_antes to public;
create temporary table resultado_2 on commit drop as
select public.cargar_catalogo_ciudades((select j from catalogo_chico)) as r;
grant select on resultado_2 to public;
select is((select (r ->> 'insertadas')::int from resultado_2), 0, 'una segunda corrida no agrega nada');
select is((select (r ->> 'actualizadas')::int from resultado_2), 0, 'ni toca nada');
select is((select (r ->> 'emparejadas')::int from resultado_2), 7, 'y ahora la lista entera ya estaba (7 filas distintas)');
select is(((select count(*) || '/' || sum(sync_version) || '/' || max(xmin_w::text::bigint) from public.ciudad) = (select n || '/' || versiones || '/' || xmin_max from suma_antes)), true,
          'ninguna fila subió su sync_version: los teléfonos no bajan nada');

-- Una de baja que no figura en la lista no se avisa (ya no está: nadie la tiene que revisar).
insert into public.ciudad (id, nombre, departamento, pais_id, lat_centro, lon_centro, deleted_at)
values (pg_temp.u('c8'), 'Ciudad Borrada', 'Salto', pg_temp.u('a1'), -31.0, -57.0, now());
select is((select count(*)::int from jsonb_array_elements(public.cargar_catalogo_ciudades((select j from catalogo_chico)) -> 'sin_pareja') e
            where (e ->> 'ciudad_id')::uuid = pg_temp.u('c8')), 0,
          'una dada de baja que no figura en la lista no se avisa');
delete from public.ciudad where id = pg_temp.u('c8');

-- Sin país Uruguay no hay dónde colgarlas.
update public.pais set deleted_at = now() where id = pg_temp.u('a1');
select is((select public.cargar_catalogo_ciudades((select j from catalogo_chico)) ->> 'pais'), 'false', 'sin país Uruguay vivo no carga nada y lo dice');
select is((select count(*)::int from public.ciudad where pais_id = pg_temp.u('a1')), 9, 'y no cambió ninguna ciudad');
update public.pais set deleted_at = null where id = pg_temp.u('a1');

-- ============================================================================
-- 5. El alta a mano
-- ============================================================================

create temporary table antes_alta on commit drop as select count(*)::int as n from public.ciudad;
grant select on antes_alta to public;

create temporary table alta_1 on commit drop as
select * from public.agregar_ciudad_a_mano('  Zyxwv   Qlibri  ', 'rivera');
grant select on alta_1 to public;

select is((select nombre from public.ciudad where id = (select ciudad_id from alta_1)), 'Zyxwv Qlibri', 'el alta guarda el nombre sin espacios de más');
select is((select departamento from public.ciudad where id = (select ciudad_id from alta_1)), 'Rivera', 'y el departamento como está en la lista (Rivera), aunque lo hayan pasado en minúsculas');
select is((select origen from public.ciudad where id = (select ciudad_id from alta_1)), 'MANUAL', 'queda cargada a mano');
select is((select bbox_oeste is null and bbox_sur is null and bbox_este is null and bbox_norte is null from public.ciudad where id = (select ciudad_id from alta_1)), true,
          'sin rectángulo: sin mapa propio hasta tener su área');
select is((select (lat_centro, lon_centro)::text from public.ciudad where id = (select ciudad_id from alta_1)),
          (select (((d.bbox ->> 1)::float8 + (d.bbox ->> 3)::float8) / 2, ((d.bbox ->> 0)::float8 + (d.bbox ->> 2)::float8) / 2)::text
             from jsonb_to_recordset(public.catalogo_osm_uruguay() -> 'departamentos') as d(nombre text, bbox jsonb) where d.nombre = 'Rivera'),
          'con el centro del departamento (la columna es obligatoria y no hay otro dato del que partir)');
select is((select zoom_inicial from public.ciudad where id = (select ciudad_id from alta_1)), 13::smallint, 'y el zoom de siempre');
select is((select deleted_at is null from public.ciudad where id = (select ciudad_id from alta_1)), true, 'viva');
select is((select jsonb_typeof(parecidas) from alta_1), 'array', 'devuelve la lista de parecidas');
select is((select count(*)::int from public.ciudad), (select n from antes_alta) + 1, 'y agregó una sola ciudad');

-- Lo que ya estaba y se le parece NO frena: se avisa.
create temporary table alta_2 on commit drop as select * from public.agregar_ciudad_a_mano('Zyxwv Qlíbri', 'Rivera');
grant select on alta_2 to public;
select is((select count(*)::int from public.ciudad where public.normalizar_busqueda(nombre) = 'zyxwv qlibri' and departamento = 'Rivera'), 2,
          'el mismo nombre en el mismo departamento (sin tildes) se agrega igual: el aviso no frena');
select is((select parecidas -> 0 ->> 'motivo' from alta_2), 'IGUAL', 'y avisa que es IGUAL');
select is((select parecidas -> 0 ->> 'ciudad_id' from alta_2), (select ciudad_id::text from alta_1), 'diciendo cuál');
select is((select parecidas -> 0 ->> 'origen' from alta_2), 'MANUAL', 'y de dónde salió');
select is((select jsonb_array_length(parecidas) from alta_2), 1, 'y no se encuentra a sí misma');

create temporary table alta_3 on commit drop as select * from public.agregar_ciudad_a_mano('Zyxwv Qlibri', 'Salto');
grant select on alta_3 to public;
select ok((select parecidas @> jsonb_build_array(jsonb_build_object('motivo', 'MISMO_NOMBRE_OTRO_DEPARTAMENTO', 'departamento', 'Rivera')) from (
             select jsonb_agg(jsonb_build_object('motivo', e ->> 'motivo', 'departamento', e ->> 'departamento')) as parecidas
               from alta_3, jsonb_array_elements(alta_3.parecidas) e) t),
          'el mismo nombre en otro departamento se avisa distinto (hay dos «San José»): MISMO_NOMBRE_OTRO_DEPARTAMENTO');
select is((select (parecidas -> 0 ->> 'motivo') from alta_3), 'MISMO_NOMBRE_OTRO_DEPARTAMENTO', 'y va primero que un parecido');

create temporary table alta_4 on commit drop as select * from public.agregar_ciudad_a_mano('Zyxwv Qlibr', 'Durazno');
grant select on alta_4 to public;
select ok((select exists (select 1 from alta_4, jsonb_array_elements(alta_4.parecidas) e where e ->> 'motivo' = 'PARECIDO' and e ->> 'nombre' = 'Zyxwv Qlibri')),
          'una letra de diferencia es PARECIDO');

create temporary table alta_5 on commit drop as select * from public.agregar_ciudad_a_mano('Grande Wxyzzy Pueblo', 'Durazno');
grant select on alta_5 to public;
select is((select jsonb_array_length(parecidas) from alta_5), 0, 'un nombre sin parecidos no avisa nada (palabras en otro orden no cuentan)');

create temporary table alta_6 on commit drop as select * from public.agregar_ciudad_a_mano('Qlibri', 'Durazno');
grant select on alta_6 to public;
select ok((select exists (select 1 from alta_6, jsonb_array_elements(alta_6.parecidas) e where e ->> 'motivo' = 'PARECIDO' and e ->> 'nombre' = 'Zyxwv Qlibri')),
          'un nombre contenido en otro (Qlibri en Zyxwv Qlibri) es PARECIDO');

-- Una dada de baja no se avisa.
update public.ciudad set deleted_at = now() where id = (select ciudad_id from alta_4);
create temporary table alta_7 on commit drop as select * from public.agregar_ciudad_a_mano('Zyxwv Qlibr', 'Durazno');
grant select on alta_7 to public;
select is((select count(*)::int from alta_7, jsonb_array_elements(alta_7.parecidas) e where (e ->> 'ciudad_id')::uuid = (select ciudad_id from alta_4)), 0,
          'las dadas de baja no se avisan');

-- Cuántas letras de diferencia son «parecido»: una en los nombres cortos, dos si el más corto tiene 8 o más.
select lives_ok($$ select * from public.agregar_ciudad_a_mano('Zkvjnb', 'Flores') $$, 'base corta (6 letras)');
select lives_ok($$ select * from public.agregar_ciudad_a_mano('Mxplqwerty', 'Flores') $$, 'base larga (10 letras)');
select ok((select exists (select 1 from public.agregar_ciudad_a_mano('Zkvjnc', 'Durazno') a, jsonb_array_elements(a.parecidas) e
                           where e ->> 'nombre' = 'Zkvjnb' and e ->> 'motivo' = 'PARECIDO')),
          'corto: una letra de diferencia es PARECIDO');
select ok((select not exists (select 1 from public.agregar_ciudad_a_mano('Zkxxnb', 'Durazno') a, jsonb_array_elements(a.parecidas) e
                               where e ->> 'nombre' = 'Zkvjnb')),
          'corto: dos letras de diferencia ya no avisan');
select ok((select exists (select 1 from public.agregar_ciudad_a_mano('Mxplqwertx', 'Durazno') a, jsonb_array_elements(a.parecidas) e
                           where e ->> 'nombre' = 'Mxplqwerty' and e ->> 'motivo' = 'PARECIDO')),
          'largo: una letra de diferencia es PARECIDO');
select ok((select exists (select 1 from public.agregar_ciudad_a_mano('Mxplqwerxx', 'Durazno') a, jsonb_array_elements(a.parecidas) e
                           where e ->> 'nombre' = 'Mxplqwerty' and e ->> 'motivo' = 'PARECIDO')),
          'largo: dos letras de diferencia también');
select ok((select not exists (select 1 from public.agregar_ciudad_a_mano('Mxplqwexxx', 'Durazno') a, jsonb_array_elements(a.parecidas) e
                               where e ->> 'nombre' = 'Mxplqwerty')),
          'largo: tres letras de diferencia ya no avisan');

-- Contenido en los dos sentidos: el nuevo dentro del que estaba (arriba, Qlibri) y el que estaba dentro del nuevo.
select ok((select exists (select 1 from public.agregar_ciudad_a_mano('Zyxwv Qlíbri Norte', 'Durazno') a, jsonb_array_elements(a.parecidas) e
                           where e ->> 'nombre' = 'Zyxwv Qlibri' and e ->> 'motivo' = 'PARECIDO')),
          'el que estaba, contenido en el nuevo (Zyxwv Qlibri en Zyxwv Qlibri Norte), es PARECIDO');

-- El orden de los avisos: primero IGUAL, después el mismo nombre en otro departamento, después los parecidos.
create temporary table alta_8 on commit drop as select * from public.agregar_ciudad_a_mano('Zyxwv Qlibri', 'Rivera');
grant select on alta_8 to public;
select is((select parecidas -> 0 ->> 'motivo' from alta_8), 'IGUAL', 'IGUAL va primero');
select ok((select exists (select 1 from alta_8, jsonb_array_elements(alta_8.parecidas) e where e ->> 'motivo' = 'MISMO_NOMBRE_OTRO_DEPARTAMENTO')),
          'y la de otro departamento también se avisa');
select ok((select (select min(o) from jsonb_array_elements(alta_8.parecidas) with ordinality t(e, o) where e ->> 'motivo' = 'IGUAL')
                < (select min(o) from jsonb_array_elements(alta_8.parecidas) with ordinality t(e, o) where e ->> 'motivo' = 'MISMO_NOMBRE_OTRO_DEPARTAMENTO')
            from alta_8),
          'todas las IGUAL antes que las de otro departamento');

-- Como mucho 10.
do $$
begin
  for i in 1 .. 12 loop
    perform public.agregar_ciudad_a_mano('Lugar Repetido ' || chr(96 + i), 'Flores');
  end loop;
end $$;
select is((select jsonb_array_length(parecidas) from public.agregar_ciudad_a_mano('Lugar Repetido', 'Flores')), 10, 'avisa de a lo sumo 10 parecidas');

-- Los errores no agregan nada.
create temporary table antes_errores on commit drop as select count(*)::int as n from public.ciudad;
grant select on antes_errores to public;
select throws_ok($$ select * from public.agregar_ciudad_a_mano('   ', 'Rivera') $$, 'CD002', 'Escribí el nombre de la ciudad (hasta 100 caracteres)', 'un nombre en blanco se rechaza');
select throws_ok($$ select * from public.agregar_ciudad_a_mano(null, 'Rivera') $$, 'CD002', null, 'y uno null');
select throws_ok($$ select * from public.agregar_ciudad_a_mano(repeat('a', 101), 'Rivera') $$, 'CD002', null, 'y uno de más de 100 caracteres');
select lives_ok($$ select * from public.agregar_ciudad_a_mano(repeat('b', 100), 'Rivera') $$, 'uno de 100 se agrega');
select throws_ok($$ select * from public.agregar_ciudad_a_mano('Pueblo X', 'Atlantida') $$, 'CD003', 'Elegí el departamento de la lista', 'un departamento que no es de la lista se rechaza');
select throws_ok($$ select * from public.agregar_ciudad_a_mano('Pueblo X', null) $$, 'CD003', null, 'y sin departamento también');
select throws_ok($$ select * from public.agregar_ciudad_a_mano('Pueblo X', '') $$, 'CD003', null, 'y en blanco');
select throws_ok($$ select * from public.agregar_ciudad_a_mano('Pueblo X', 'Río  Negrito') $$, 'CD003', null, 'ni uno parecido: se elige de la lista');
select lives_ok($$ select * from public.agregar_ciudad_a_mano('Pueblo Z', 'rio negro') $$, 'sin tildes ni mayúsculas sí, se guarda como en la lista');
select is((select departamento from public.ciudad where nombre = 'Pueblo Z'), 'Río Negro', 'Río Negro');
select is((select count(*)::int from public.ciudad), (select n from antes_errores) + 2, 'los errores no agregaron ninguna ciudad (solo la de 100 y Pueblo Z)');
update public.pais set deleted_at = now() where id = pg_temp.u('a1');
select throws_ok($$ select * from public.agregar_ciudad_a_mano('Pueblo X', 'Salto') $$, 'CD004', 'Falta cargar el país Uruguay', 'sin país Uruguay se rechaza');
update public.pais set deleted_at = null where id = pg_temp.u('a1');

-- ============================================================================
-- 7. La lista real
-- ============================================================================

-- Sin duplicados y de una pasada: una fila viva por cada ciudad de la lista (la San José dada de baja de la prueba
-- impide la de su mismo nombre y departamento: no se vuelve a crear lo que Administración dio de baja).
select lives_ok($$ select public.cargar_catalogo_ciudades() $$, 'la lista real se carga');
select is((select count(*)::int
             from public.filas_del_catalogo(public.catalogo_osm_uruguay()) l
            where not (l.nombre_n = 'san jose' and l.departamento_n = 'san jose')
              and (select count(*) from public.ciudad c
                    where c.pais_id = pg_temp.u('a1') and c.deleted_at is null
                      and public.normalizar_busqueda(c.nombre) = l.nombre_n
                      and public.normalizar_busqueda(c.departamento) = l.departamento_n) <> 1), 0,
          'cada ciudad de la lista está exactamente una vez, viva');
select is((select count(*)::int
             from (select public.normalizar_busqueda(nombre), public.normalizar_busqueda(departamento)
                     from public.ciudad where pais_id = pg_temp.u('a1') and deleted_at is null and origen = 'OSM'
                    group by 1, 2 having count(*) > 1) d), 0,
          'y ninguna de las de OSM repite nombre en su departamento (las repetidas a mano que dejó el alta se avisaron, no se frenaron)');
select is((select (public.cargar_catalogo_ciudades() ->> 'insertadas')::int), 0, 'volver a correr la lista real no agrega nada');
select is((select (public.cargar_catalogo_ciudades() ->> 'actualizadas')::int), 0, 'ni cambia nada');
select is((select count(*)::int from public.ciudad where origen = 'OSM' and bbox_oeste is not null
              and not (lon_centro between bbox_oeste and bbox_este and lat_centro between bbox_sur and bbox_norte)), 0,
          'ninguna ciudad quedó con el centro fuera de su rectángulo');
select is((select count(*)::int from public.ciudad where origen = 'OSM' and departamento not in (select public.departamentos_de_uruguay())), 0,
          'todas las OSM tienen un departamento de la lista');

-- ============================================================================
-- 6. Privilegios: solo el servidor
-- ============================================================================

select is(has_function_privilege('anon', 'public.departamentos_de_uruguay()', 'execute'), false, 'anon no lee los departamentos');
select is(has_function_privilege('authenticated', 'public.departamentos_de_uruguay()', 'execute'), true, 'authenticated sí: los selectores del panel');
select is(has_function_privilege('service_role', 'public.departamentos_de_uruguay()', 'execute'), true, 'y service_role');
select is(has_function_privilege('authenticated', 'public.catalogo_osm_uruguay()', 'execute'), false, 'la lista entera es interna');
select is(has_function_privilege('service_role', 'public.catalogo_osm_uruguay()', 'execute'), true, 'del servidor');
select is(has_function_privilege('authenticated', 'public.cargar_catalogo_ciudades(jsonb)', 'execute'), false, 'cargar el catálogo no es de authenticated');
select is(has_function_privilege('anon', 'public.cargar_catalogo_ciudades(jsonb)', 'execute'), false, 'ni de anon');
select is(has_function_privilege('service_role', 'public.cargar_catalogo_ciudades(jsonb)', 'execute'), true, 'es del servidor');
select is(has_function_privilege('authenticated', 'public.agregar_ciudad_a_mano(text, text)', 'execute'), false, 'el alta a mano no es de authenticated (hasta que haya panel de Administración)');
select is(has_function_privilege('anon', 'public.agregar_ciudad_a_mano(text, text)', 'execute'), false, 'ni de anon');
select is(has_function_privilege('service_role', 'public.agregar_ciudad_a_mano(text, text)', 'execute'), true, 'es del servidor');
select is(has_function_privilege('authenticated', 'public.filas_del_catalogo(jsonb)', 'execute'), false, 'las auxiliares no las ejecuta nadie de afuera');
select is(has_function_privilege('service_role', 'public.filas_del_catalogo(jsonb)', 'execute'), false, 'ni el servidor');
select is(has_function_privilege('service_role', 'public.distancia_de_edicion(text, text)', 'execute'), false, 'ni la distancia de edición');

select pg_temp.actuar_como_authenticated();
select throws_ok($$ select * from public.agregar_ciudad_a_mano('Intruso', 'Salto') $$, '42501', null, 'authenticated no agrega una ciudad');
select throws_ok($$ select public.cargar_catalogo_ciudades() $$, '42501', null, 'ni carga el catálogo');
select lives_ok($$ select count(*) from public.departamentos_de_uruguay() $$, 'pero sí lee los departamentos');
select pg_temp.actuar_como_servidor();
select is((select count(*)::int from public.ciudad where nombre = 'Intruso'), 0, 'y no quedó nada');

select * from finish();
rollback;
