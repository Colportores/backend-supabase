-- pgTAP · 0174 y 0175 sobre los datos de antes: cada coordinador que guardaba una campaña pasa a la tabla (también el de la
-- campaña dada de baja), la campaña sin coordinador no suma nada, las campañas quedan idénticas (la columna se conserva y
-- no sube de versión) y el permiso del coordinador sigue andando para quien ya lo tenía. Ver scripts/db-test-migracion.sh.
begin;
select * from no_plan();

select is((select count(*)::int from public.campania_coordinador), 2, 'una fila por cada campaña que tenía coordinador');
select is((select count(*)::int from public.campania_coordinador cc
            join public.prueba_0174_campania c on c.id = cc.campania_id and c.coordinador_id = cc.usuario_id
           where cc.deleted_at is null), 2, 'cada una con el coordinador que guardaba, vigente');
select is((select count(*)::int from public.campania_coordinador where campania_id = '01920000-0000-7000-8000-0000000174e3'), 0,
          'la campaña sin coordinador no suma ninguno');
select is((select cc.created_at from public.campania_coordinador cc where cc.campania_id = '01920000-0000-7000-8000-0000000174e1'),
          (select c.created_at from public.prueba_0174_campania c where c.id = '01920000-0000-7000-8000-0000000174e1'),
          'el alta del coordinador conserva la fecha de la campaña');
select is((select cc.nombre || ' ' || cc.apellido from public.campania_coordinador cc
            where cc.campania_id = '01920000-0000-7000-8000-0000000174e1'), 'Luis Pérez',
          'y la fila copia su nombre y su apellido');
select is((select count(*)::int from public.campania c join public.prueba_0174_campania s using (id)
            where to_jsonb(c) is distinct from to_jsonb(s)), 0,
          'las tres campañas quedan idénticas, sync_version incluida (la migración no las toca)');

-- Quien ya coordinaba sigue coordinando como antes.
select set_config('request.jwt.claims',
                  json_build_object('sub', '01920000-0000-7000-8000-0000000174c1', 'role', 'authenticated')::text, true);
select set_config('request.jwt.claim.sub', '01920000-0000-7000-8000-0000000174c1', true);
select is((select array_agg(id) from public.campanias_del_coordinador()),
          array['01920000-0000-7000-8000-0000000174e1'::uuid], 'el coordinador sigue viendo su campaña en el selector');

select * from finish();
rollback;
