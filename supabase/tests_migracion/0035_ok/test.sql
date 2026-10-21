-- pgTAP · 0035 suma el registro de la unión y los triggers que redirigen SIN tocar los datos de antes:
-- ubicaciones, espacios, vínculos, visitas, ventas, agendas y decisiones quedan idénticos (con sus
-- versiones de sync); las dos tablas nuevas nacen vacías; y un par unido después con los datos de antes
-- no pierde nada y deja su registro. Ver scripts/db-test-migracion.sh y los datos de datos.sql.
begin;
select * from no_plan();

-- --- los datos de antes siguen ----------------------------------------------------------------
select is((select count(*)::int from public.ubicacion), 4, 'las 4 ubicaciones siguen: no se perdió ninguna');
select is((select count(*)::int from public.ubicacion u join public.prueba_0035_ubicacion s using (id)
            where to_jsonb(u) is distinct from to_jsonb(s)), 0,
          'y quedaron idénticas en todas sus columnas, sync_version y xmin_w incluidos: ni se enteran los teléfonos');
select is((select count(*)::int from public.espacio e join public.prueba_0035_espacio s using (id)
            where to_jsonb(e) is distinct from to_jsonb(s)), 0, 'los 2 espacios, idénticos');
select is((select count(*)::int from public.espacio_persona e join public.prueba_0035_espacio_persona s using (id)
            where to_jsonb(e) is distinct from to_jsonb(s)), 0, 'los 3 vínculos, idénticos');
select is((select count(*)::int from public.visita e join public.prueba_0035_visita s using (id)
            where to_jsonb(e) is distinct from to_jsonb(s)), 0, 'la visita, idéntica');
select is((select count(*)::int from public.venta e join public.prueba_0035_venta s using (id)
            where to_jsonb(e) is distinct from to_jsonb(s)), 0, 'la venta, idéntica');
select is((select count(*)::int from public.agenda e join public.prueba_0035_agenda s using (id)
            where to_jsonb(e) is distinct from to_jsonb(s)), 0, 'la agenda, idéntica');
select is((select count(*)::int from public.ubicacion_par_decidido e join public.prueba_0035_par s using (id)
            where to_jsonb(e) is distinct from to_jsonb(s)), 0, 'la decisión sobre el par, idéntica');
select is((select deleted_at is not null from public.ubicacion where id = '01920000-0000-7000-8000-0000000035e4'), true,
          'la dada de baja sigue de baja');
select is((select sync_version from public.ubicacion where id = '01920000-0000-7000-8000-0000000035e2'), 1::bigint,
          'la corregida conserva su versión de sync');
select is((select count(*)::int from sync.entidad), 23, 'sync.entidad sigue con sus 23 entidades (las tablas nuevas no van al sync)');

-- --- lo nuevo ------------------------------------------------------------------------------------
select is((select count(*)::int from public.ubicacion_union), 0, 'ubicacion_union nace vacía');
select is((select count(*)::int from public.espacio_union), 0, 'espacio_union nace vacía');
select has_function('public', 'ubicacion_vigente', array['uuid'], 'ubicacion_vigente existe');
select has_trigger('public', 'espacio_persona', 'espacio_persona_0_union_redirige', 'y el trigger de los vínculos');

-- --- unir un par con los datos de antes -----------------------------------------------------------
-- B (e2) se une a A (e1) como lo hacía la 0026: la persona 1 está en las dos, la 2 solo en B.
select is(public.marcar_como_duplicado('01920000-0000-7000-8000-0000000035e2', '01920000-0000-7000-8000-0000000035e1'),
          jsonb_build_object('duplicada_id', '01920000-0000-7000-8000-0000000035e2',
                             'conservada_id', '01920000-0000-7000-8000-0000000035e1',
                             'destino_id', '01920000-0000-7000-8000-0000000035e1',
                             'ya_unida', false, 'espacios_pasados', 0, 'espacios_unidos', 1,
                             'personas', 2, 'visitas', 1, 'ventas', 1, 'cobranzas', 0,
                             'tipo_conservada', 'CASA', 'paso_a_edificio', false),
          'la unión con datos de antes responde lo de siempre, más el destino y el tipo');
select is((select count(*)::int from public.ubicacion_union
            where duplicada_id = '01920000-0000-7000-8000-0000000035e2' and conservada_id = '01920000-0000-7000-8000-0000000035e1'), 1,
          'deja su registro');
select is((select count(*)::int from public.espacio_union
            where espacio_id = '01920000-0000-7000-8000-0000000035f2' and destino_id = '01920000-0000-7000-8000-0000000035f1'), 1,
          'y el del único fundido');
select is((select espacio_persona_id from public.venta where id = '01920000-0000-7000-8000-000000003521'),
          '01920000-0000-7000-8000-000000003501'::uuid, 'la venta pasó al vínculo de A, sin perderse');
select is((select deleted_at is null from public.venta where id = '01920000-0000-7000-8000-000000003521'), true, 'y sigue viva');
select is((select espacio_persona_id from public.visita where id = '01920000-0000-7000-8000-000000003511'),
          '01920000-0000-7000-8000-000000003501'::uuid, 'la visita también');
select is((select espacio_id from public.espacio_persona where id = '01920000-0000-7000-8000-000000003503'),
          '01920000-0000-7000-8000-0000000035f1'::uuid, 'la persona que solo estaba en B pasó al único de A, con su mismo vínculo');
select is((select ubicacion_cobranza_alt_id from public.espacio_persona where id = '01920000-0000-7000-8000-000000003503'),
          '01920000-0000-7000-8000-0000000035e1'::uuid, 'y su cobranza alternativa, que nombraba a B, nombra a A');
select is((select ubicacion_alt_id from public.agenda where id = '01920000-0000-7000-8000-000000003531'),
          '01920000-0000-7000-8000-0000000035e1'::uuid, 'la casa alternativa de la agenda, también');
select results_eq(
  $$ select ubicacion_a_id, ubicacion_b_id, deleted_at is null from public.ubicacion_par_decidido
      where id = '01920000-0000-7000-8000-000000003541' $$,
  $$ values ('01920000-0000-7000-8000-0000000035e1'::uuid, '01920000-0000-7000-8000-0000000035e3'::uuid, true) $$,
  'la decisión sobre (B, X) pasó a (A, X), viva');
select is((select count(*)::int from public.venta), 1, 'ninguna venta se perdió');
select is((select count(*)::int from public.espacio_persona where deleted_at is null), 2,
          'quedan 2 vínculos vivos: la persona 1 y la persona 2, en A (el de la persona 1 en B se fundió)');

select * from finish();
rollback;
