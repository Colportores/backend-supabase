-- pgTAP · 0100 sobre los datos de antes: las jornadas y las inscripciones no cambian (salvo las columnas
-- nuevas: origen y nota en null, tramos afuera vacíos), ni su versión de sync, y lo nuevo anda sobre ellas: el
-- coordinador suma a otro colportor con una nota a una jornada de antes, y el origen lo pone el servidor.
-- Ver scripts/db-test-migracion.sh y datos.sql.
begin;
select * from no_plan();

-- Nada se pierde.
select is((select count(*)::int from public.jornada), 3, 'las 3 jornadas siguen');
select is((select count(*)::int from public.campania_colportor), 3, 'y las 3 inscripciones, también la de baja');
select is((select count(*)::int from public.jornada j join public.prueba_0100_jornada s using (id)
            where to_jsonb(j) - 'acompaniamiento_origen' - 'acompaniamiento_nota' is distinct from to_jsonb(s)), 0,
          'las jornadas quedaron idénticas (versión de sync, updated_at y xmin_w incluidos) salvo las columnas nuevas');
select is((select count(*)::int from public.campania_colportor c join public.prueba_0100_inscripcion s
              on s.campania_id = c.campania_id and s.usuario_id = c.usuario_id
            where to_jsonb(c) - 'tramos_afuera' is distinct from to_jsonb(s)), 0,
          'las inscripciones quedaron idénticas (también la de baja) salvo la columna nueva');
select is((select count(*)::int from public.jornada
            where acompaniamiento_origen is not null or acompaniamiento_nota is not null), 0,
          'ninguna jornada trae origen ni nota: de las de antes no se sabe quién las puso, y no se inventa');
select is((select count(*)::int from public.campania_colportor where tramos_afuera <> '{}'::tstzrange[]), 0,
          'y ninguna inscripción trae tramos afuera: las bajas de antes no dejaron huella');
select is((select sync_version from public.jornada where id = '01920000-0000-7000-8000-000000010101'), 1::bigint,
          'la jornada corregida conserva su versión de sync (1): ningún teléfono re-sube nada');
select is((select acompaniante_id from public.jornada where id = '01920000-0000-7000-8000-000000010102'),
          '01920000-0000-7000-8000-0000000100b2'::uuid, 'y cada acompañante de antes sigue donde estaba');

-- Lo nuevo anda sobre los datos de antes, con la sesión del coordinador.
select set_config('request.jwt.claims', json_build_object('sub', '01920000-0000-7000-8000-0000000100a1', 'role', 'authenticated')::text, true);
select set_config('request.jwt.claim.sub', '01920000-0000-7000-8000-0000000100a1', true);
select set_config('request.jwt.claim.role', 'authenticated', true);
select set_config('role', 'authenticated', true);
select is((select r.acompaniamiento_origen || '|' || r.acompaniamiento_nota || '|' || r.acompaniante_id::text
             from public.agregar_acompaniamiento('01920000-0000-7000-8000-0000000100e1', '01920000-0000-7000-8000-000000010103',
                                                 '01920000-0000-7000-8000-0000000100b3', 'Buena presentación') r),
          'COORDINADOR|Buena presentación|01920000-0000-7000-8000-0000000100b3',
          'el coordinador suma a b3 con una nota a una jornada de antes: origen COORDINADOR');
select throws_ok($$ select * from public.agregar_acompaniamiento('01920000-0000-7000-8000-0000000100e1',
                    '01920000-0000-7000-8000-000000010102', '01920000-0000-7000-8000-0000000100b3') $$,
                 'JO003', null, 'y la que ya tenía a b2 no se pisa');
select is((select count(*)::int from public.agregar_acompaniamiento('01920000-0000-7000-8000-0000000100e1',
              '01920000-0000-7000-8000-000000010103', '01920000-0000-7000-8000-0000000100b3')), 1,
          'repetir el mismo acompañamiento es idempotente');
select set_config('role', 'postgres', true);
select is((select acompaniamiento_origen is null and acompaniamiento_nota is null from public.jornada
            where id = '01920000-0000-7000-8000-000000010101'), true,
          'y las otras jornadas de antes siguen sin origen');

-- La vuelta de b2 a la campaña deja el hueco; lo de antes no se toca.
update public.campania_colportor set deleted_at = null where usuario_id = '01920000-0000-7000-8000-0000000100b2';
select is((select cardinality(tramos_afuera) from public.campania_colportor where usuario_id = '01920000-0000-7000-8000-0000000100b2'), 1,
          'al reactivarse, b2 deja el hueco de sus 5 días afuera');
select is((select count(*)::int from public.campania_colportor where tramos_afuera <> '{}'::tstzrange[]), 1, 'y solo b2');

select * from finish();
rollback;
