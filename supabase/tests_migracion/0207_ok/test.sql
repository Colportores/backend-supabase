-- pgTAP · 0207 y 0208 sobre los datos de antes: las personas y las inscripciones no cambian (ni su versión de sync), cada persona tiene su
-- fila de preferencias con lo que ya tenía guardado, y las inscripciones pasan a campania_companiero con su nombre, su ciudad y su baja.
-- Ver scripts/db-test-migracion.sh y datos.sql.
begin;
select * from no_plan();

-- Nada se pierde ni se toca.
select is((select count(*)::int from public.usuario u join public.prueba_0207_usuario s using (id) where to_jsonb(u) is distinct from to_jsonb(s)), 0,
          'las personas quedaron idénticas (versión de sync, updated_at y preferencias incluidas)');
select is((select count(*)::int from public.usuario), (select count(*)::int from public.prueba_0207_usuario), 'y siguen todas');
select is((select count(*)::int from public.campania_colportor i join public.prueba_0207_inscripcion s using (id) where to_jsonb(i) is distinct from to_jsonb(s)), 0,
          'las inscripciones quedaron idénticas (también la dada de baja)');

-- 0207: cada persona tiene su fila de preferencias, con lo que ya tenía.
select is((select count(*)::int from public.preferencia_de_avisos), (select count(*)::int from public.usuario),
          'cada persona tiene su fila de preferencias');
select is((select notif_preferences from public.preferencia_de_avisos where id = '01920000-0000-7000-8000-0000000207b1'),
          '{"hora_cuota": "10:30", "tickets": false}'::jsonb, 'Juan conserva lo que guardó');
select is((select count(*)::int from public.preferencia_de_avisos where notif_preferences is null),
          (select count(*)::int from public.usuario) - 1, 'las demás quedan en null (todo por defecto): no se inventa nada');
select is((select count(*)::int from public.preferencia_de_avisos where sync_version <> 0), 0,
          'las filas de preferencias nacen con la versión 0 del sync (la de cualquier alta)');

-- 0208: las inscripciones pasan a la tabla.
select is((select count(*)::int from public.campania_companiero), 3, 'una fila por inscripción (3), la dada de baja también');
select is((select c.nombre || ' ' || c.apellido || '/' || ci.nombre
             from public.campania_companiero c join public.ciudad ci on ci.id = c.ciudad_id
            where c.usuario_id = '01920000-0000-7000-8000-0000000207b1'),
          'Juan Perez/Ciudad 207', 'Juan, con la ciudad de su zona');
select is((select c.nombre || ' ' || c.apellido || '/' || coalesce(c.ciudad_id::text, 'sin ciudad')
             from public.campania_companiero c where c.usuario_id = '01920000-0000-7000-8000-0000000207b2'),
          'Ana Pereira/sin ciudad', 'Ana, sin zona: sin ciudad');
select is((select deleted_at is not null from public.campania_companiero where usuario_id = '01920000-0000-7000-8000-0000000207b3'),
          true, 'Bruno, dado de baja de la campaña, queda con su baja');
select is((select count(*)::int from public.campania_companiero where usuario_id = '01920000-0000-7000-8000-0000000207d1'), 0,
          'el coordinador no es colportor de la campaña: no figura');

select * from finish();
rollback;
