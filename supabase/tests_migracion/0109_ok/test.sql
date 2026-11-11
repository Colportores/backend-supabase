-- pgTAP · 0109 carga el catálogo de Uruguay de OpenStreetMap sin perder ni duplicar nada. Ver
-- scripts/db-test-migracion.sh y los datos de datos.sql.
begin;
select * from no_plan();

-- --- los datos de antes siguen --------------------------------------------------------------
select is((select count(*)::int from public.ciudad c join public.prueba_0109_ciudad s using (id)), 6,
          'las 6 ciudades de antes siguen: no se perdió ninguna');
select is((select count(*)::int from public.zona z join public.prueba_0109_zona s using (id)
            where to_jsonb(z) = to_jsonb(s)), 1, 'la zona quedó idéntica en todas sus columnas');
select is((select count(*)::int from public.campania_ciudad cc join public.prueba_0109_campania_ciudad s using (id)
            where to_jsonb(cc) = to_jsonb(s)), 2, 'las dos ciudades de la campaña siguen idénticas');

-- Las que no casan y la de otro país: idénticas en todo, sync_version y xmin_w incluidos (los teléfonos ni se enteran),
-- salvo la columna nueva.
select is((select count(*)::int
             from public.ciudad c join public.prueba_0109_ciudad s using (id)
            where c.id in ('01920000-0000-7000-8000-0000000109c3', '01920000-0000-7000-8000-0000000109c4',
                           '01920000-0000-7000-8000-0000000109c5', '01920000-0000-7000-8000-0000000109c6')
              and (to_jsonb(c) - 'origen') is distinct from to_jsonb(s)), 0,
          'Pueblo Aparte, Rivera sin departamento, la dada de baja y la de Chile quedaron idénticas, sync_version y xmin_w incluidos');
select is((select array_agg(origen order by id) from public.ciudad
            where id in ('01920000-0000-7000-8000-0000000109c3', '01920000-0000-7000-8000-0000000109c4',
                         '01920000-0000-7000-8000-0000000109c6')),
          array['MANUAL', 'MANUAL', 'MANUAL'], 'y las que no figuran en la lista quedan MANUAL');
select is((select deleted_at is not null from public.ciudad where id = '01920000-0000-7000-8000-0000000109c5'), true,
          'Maldonado sigue de baja');
select is((select count(*)::int from public.ciudad
            where pais_id = '01920000-0000-7000-8000-0000000109a1' and deleted_at is null
              and public.normalizar_busqueda(nombre) = 'maldonado'
              and public.normalizar_busqueda(departamento) = 'maldonado'), 0,
          'y no se creó otra Maldonado: lo que se dio de baja a propósito no se recrea');

-- --- las que casan ---------------------------------------------------------------------------------
select is((select origen from public.ciudad where id = '01920000-0000-7000-8000-0000000109c1'), 'OSM', 'Montevideo quedó OSM');
select is((select (bbox_oeste, bbox_sur, bbox_este, bbox_norte)::text from public.ciudad where id = '01920000-0000-7000-8000-0000000109c1'),
          '(-56.433,-34.945,-55.948,-34.701)', 'y conserva SU rectángulo, no el de la lista');
select is((select (nombre, lat_centro, lon_centro, zoom_inicial)::text from public.ciudad where id = '01920000-0000-7000-8000-0000000109c1'),
          '(Montevideo,-34.9011,-56.1645,13)', 'y su nombre, su centro y su zoom');
select is((select origen from public.ciudad where id = '01920000-0000-7000-8000-0000000109c2'), 'OSM', 'Salto casó sin tildes ni mayúsculas');
select is((select departamento from public.ciudad where id = '01920000-0000-7000-8000-0000000109c2'), 'Salto',
          'y su departamento quedó escrito como en la lista');
select is((select (nombre, lat_centro, lon_centro)::text from public.ciudad where id = '01920000-0000-7000-8000-0000000109c2'),
          '(Salto,-31.3833,-57.9667)', 'sin tocar su nombre ni su centro');

-- --- la lista entera, sin duplicados ----------------------------------------------------------------
select is((select count(*)::int
             from public.filas_del_catalogo(public.catalogo_osm_uruguay()) l
            where not (l.nombre_n = 'maldonado' and l.departamento_n = 'maldonado')
              and (select count(*) from public.ciudad c
                    where c.pais_id = '01920000-0000-7000-8000-0000000109a1' and c.deleted_at is null
                      and public.normalizar_busqueda(c.nombre) = l.nombre_n
                      and public.normalizar_busqueda(c.departamento) = l.departamento_n) <> 1), 0,
          'cada ciudad de la lista está exactamente una vez, viva (menos la dada de baja)');
select is((select count(*)::int from public.ciudad where pais_id = '01920000-0000-7000-8000-0000000109a1'),
          5 + (select count(*)::int from public.filas_del_catalogo(public.catalogo_osm_uruguay()) l
                where not exists (select 1 from public.prueba_0109_ciudad s
                                   where s.pais_id = '01920000-0000-7000-8000-0000000109a1'
                                     and public.normalizar_busqueda(s.nombre) = l.nombre_n
                                     and public.normalizar_busqueda(s.departamento) = l.departamento_n)),
          'las de Uruguay: las 5 de antes y solo las de la lista que faltaban');
select is((select count(*)::int from public.ciudad where pais_id = '01920000-0000-7000-8000-0000000109a2'), 1,
          'Chile no recibió ninguna');
select is((select count(*)::int from public.ciudad
            where pais_id = '01920000-0000-7000-8000-0000000109a1' and origen = 'OSM' and bbox_oeste is not null
              and not (lon_centro between bbox_oeste and bbox_este and lat_centro between bbox_sur and bbox_norte)), 0,
          'ninguna quedó con el centro fuera de su rectángulo');
select ok((select count(*) from public.ciudad where origen = 'OSM' and bbox_oeste is null) >= 1,
          'las que OSM no delimita quedaron sin rectángulo: no se inventó ninguno');

-- --- volver a cargar no cambia nada y avisa de las que no casan ---------------------------------------
create temp table antes as select id, to_jsonb(c) as fila from public.ciudad c;
create temp table respuesta as select public.cargar_catalogo_ciudades() as r;
select is((select (r ->> 'insertadas')::int from respuesta), 0, 'volver a correr no agrega nada');
select is((select (r ->> 'actualizadas')::int from respuesta), 0, 'ni cambia nada');
select is((select count(*)::int from public.ciudad c join antes a using (id) where to_jsonb(c) is distinct from a.fila), 0,
          'ninguna fila cambió, sync_version y xmin_w incluidos');
select is((select count(*)::int from public.ciudad) , (select count(*)::int from antes), 'y no hay filas nuevas');
select is((select array_agg(e ->> 'nombre' order by e ->> 'nombre') from respuesta, jsonb_array_elements(r -> 'sin_pareja') e),
          array['Pueblo Aparte', 'Rivera'], 'las que ya estaban y no casan se avisan en sin_pareja: Pueblo Aparte y Rivera sin departamento');

select * from finish();
rollback;
