-- pgTAP · 0117 sobre los datos de antes: ningún usuario ni inscripción cambia (salvo usuario.carrera_id, en
-- null), ni su versión de sync; la beca que ya tenía b1 se conserva; la migración no escribe ningún registro
-- de auditoría; y lo nuevo anda sobre esos datos: el coordinador ve la beca de antes, elige la carrera y asigna
-- la beca con las metas de la carrera. Ver scripts/db-test-migracion.sh y datos.sql.
begin;
select * from no_plan();

-- Nada se pierde ni se mueve.
select is((select count(*)::int from public.usuario), (select count(*)::int from public.prueba_0117_usuario),
          'los usuarios siguen');
select is((select count(*)::int from public.usuario u join public.prueba_0117_usuario s using (id)
            where to_jsonb(u) - 'carrera_id' is distinct from to_jsonb(s)), 0,
          'los usuarios quedaron idénticos (versión de sync, updated_at y xmin_w incluidos) salvo la columna nueva');
select is((select count(*)::int from public.usuario where carrera_id is not null), 0,
          'ninguno trae carrera: no se inventa');
select is((select count(*)::int from public.campania_colportor c join public.prueba_0117_inscripcion s using (id)
            where to_jsonb(c) is distinct from to_jsonb(s)), 0,
          'las inscripciones quedaron idénticas (tipo, metas, versión de sync, updated_at y xmin_w incluidos)');
select is((select count(*)::int from public.carrera) + (select count(*)::int from public.meta_beca), 0,
          'las tablas nuevas arrancan vacías');
select is((select count(*)::int from auditoria.audit_log where event_type in ('beca_asignada', 'carrera_del_colportor_cambiada')), 0,
          'la migración no escribe ningún registro de auditoría');
select is((select format('%s|%s|%s', tipo_beca, meta_libros, meta_monto_ces) from public.campania_colportor
            where usuario_id = '01920000-0000-7000-8000-0000000117b1'),
          'MEDIA|55|2750000', 'la beca que b1 ya tenía se conserva');

-- Lo nuevo anda sobre los datos de antes, con la sesión del coordinador.
select set_config('request.jwt.claims', json_build_object('sub', '01920000-0000-7000-8000-0000000117a1', 'role', 'authenticated')::text, true);
select set_config('request.jwt.claim.sub', '01920000-0000-7000-8000-0000000117a1', true);
select set_config('request.jwt.claim.role', 'authenticated', true);
select set_config('role', 'authenticated', true);

select is((select string_agg(format('%s|%s|%s|%s', r.nombre, coalesce(r.carrera_nombre, 'null'), coalesce(r.tipo_beca, 'null'),
                                    coalesce(r.meta_libros::text, 'null')), ';' order by r.apellido)
             from public.becas_de_campania('01920000-0000-7000-8000-0000000117e1') r),
          'Ana|null|MEDIA|55;Beto|null|null|null',
          'la tabla de Becas lee la beca de antes (b1) y a b2 sin nada; la inscripción de baja no sale');

-- El servidor carga una carrera con su meta.
select set_config('role', 'postgres', true);
insert into public.carrera (id, nombre) values ('01920000-0000-7000-8000-0000000117c1', 'Teología');
insert into public.meta_beca (carrera_id, tipo_campania, meta_media, meta_completa, meta_media_monto, meta_completa_monto)
values ('01920000-0000-7000-8000-0000000117c1', 'VERANO', 60, 120, 3000000, 6000000);
select set_config('role', 'authenticated', true);

select is((select r.cambio from public.elegir_carrera('01920000-0000-7000-8000-0000000117e1',
              '01920000-0000-7000-8000-0000000117b1', '01920000-0000-7000-8000-0000000117c1') r), true,
          'la coordinadora elige la carrera de b1');
select is((select format('%s|%s|%s', r.tipo_beca, r.meta_libros, r.meta_monto_ces)
             from public.asignar_beca('01920000-0000-7000-8000-0000000117e1',
                  array['01920000-0000-7000-8000-0000000117b1']::uuid[], 'COMPLETA') r),
          'COMPLETA|120|6000000', 'y le asigna la beca completa, con las dos metas de la carrera');
select is((select format('%s|%s', r.carrera_nombre, r.meta_libros)
             from public.becas_de_campania('01920000-0000-7000-8000-0000000117e1') r
            where r.usuario_id = '01920000-0000-7000-8000-0000000117b1'),
          'Teología|120', 'la tabla de Becas lo muestra');

select * from finish();
rollback;
