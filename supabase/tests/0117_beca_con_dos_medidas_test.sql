-- pgTAP · beca con dos medidas: la carrera del colportor, las metas por carrera y la asignación por el
-- coordinador (migración 0117, backend-supabase#112, HU-BEC-006, HU-BEC-001, vista 33 «Equipo»)
-- carrera y meta_beca (forma, checks, únicos, privilegios); usuario.carrera_id (un cliente no la cambia: 42501;
-- el ADMIN y el servidor sí; queda en audit_log); elegir_carrera() (permiso, campaña, inscripción, carrera,
-- una sola vez, el ADMIN la corrige, idempotente, sigue a la persona a otra campaña); asignar_beca() (permiso,
-- validaciones, todo o nada, metas copiadas, cambio de tipo, varios a la vez, «sin beca», idempotencia sin
-- escritura de más, copia que no cambia al editar meta_beca, campaña PERMANENTE, auditoría);
-- becas_de_campania() (la forma, el permiso, quiénes salen); y que meta_libros ya no lo cambia cualquier
-- coordinador.
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

-- 'ok' o el SQLSTATE: lo que importa de un rechazo es el código.
create or replace function pg_temp.cod(p_sql text) returns text language plpgsql as $$
begin
  execute p_sql;
  return 'ok';
exception when others then
  return sqlstate;
end $$;

-- 'ok' o 'SQLSTATE: mensaje', para los textos que guían.
create or replace function pg_temp.error_de(p_sql text) returns text language plpgsql as $$
begin
  execute p_sql;
  return 'ok';
exception when others then
  return sqlstate || ': ' || sqlerrm;
end $$;

-- El uuid de un personaje del test (sufijo de dos caracteres HEX).
create or replace function pg_temp.u(p_sufijo text) returns uuid language sql immutable as $$
  select ('01920000-0000-7000-8000-0000000117' || p_sufijo)::uuid
$$;

-- elegir_carrera como una línea: usuario:carrera:cambio.
create or replace function pg_temp.eleg(p_camp text, p_usuario text, p_carrera text) returns text language sql as $$
  select format('%s:%s:%s', right(r.usuario_id::text, 2), coalesce(right(r.carrera_id::text, 2), '-'),
                case when r.cambio then 'S' else 'N' end)
    from public.elegir_carrera(pg_temp.u(p_camp), pg_temp.u(p_usuario), pg_temp.u(p_carrera)) r
$$;

-- asignar_beca como una línea por colportor (en orden de id): usuario:tipo:libros:monto:cambio.
create or replace function pg_temp.asig(p_camp text, p_us text[], p_tipo text) returns text language sql as $$
  select string_agg(format('%s:%s:%s:%s:%s', right(r.usuario_id::text, 2), coalesce(r.tipo_beca, '-'),
                           coalesce(r.meta_libros::text, '-'), coalesce(r.meta_monto_ces::text, '-'),
                           case when r.cambio then 'S' else 'N' end), ';' order by r.usuario_id)
    from public.asignar_beca(pg_temp.u(p_camp), (select array_agg(pg_temp.u(x)) from unnest(p_us) x), p_tipo) r
$$;

-- La beca de un colportor en una campaña: tipo|libros|monto|sync_version. SECURITY DEFINER: se lee sin RLS.
create or replace function pg_temp.beca(p_camp text, p_us text) returns text language sql security definer as $$
  select format('%s|%s|%s|%s', coalesce(cc.tipo_beca, '-'), coalesce(cc.meta_libros::text, '-'),
                coalesce(cc.meta_monto_ces::text, '-'), cc.sync_version)
    from public.campania_colportor cc
   where cc.campania_id = pg_temp.u(p_camp) and cc.usuario_id = pg_temp.u(p_us)
$$;

-- Cuántos eventos de auditoría de un tipo sobre un colportor (con el detalle que contiene el filtro).
-- SECURITY DEFINER: audit_log no la lee nadie con JWT.
create or replace function pg_temp.eventos(p_evento text, p_us text, p_filtro jsonb default '{}'::jsonb)
returns integer language sql security definer as $$
  select count(*)::int from auditoria.audit_log a
   where a.event_type = p_evento and a.target_user_id = pg_temp.u(p_us) and a.metadata @> p_filtro
$$;

create or replace function pg_temp.actor_del_ultimo(p_evento text, p_us text)
returns uuid language sql security definer as $$
  select a.actor_user_id from auditoria.audit_log a
   where a.event_type = p_evento and a.target_user_id = pg_temp.u(p_us)
   order by a.created_at desc, a.id desc limit 1
$$;

-- La carrera de un usuario, sin RLS.
create or replace function pg_temp.carrera_de(p_us text) returns text language sql security definer as $$
  select coalesce(right(u.carrera_id::text, 2), '-') from public.usuario u where u.id = pg_temp.u(p_us)
$$;

-- Filas que toca un UPDATE (la RLS que no deja ver una fila no falla: toca 0).
create or replace function pg_temp.filas(p_sql text) returns integer language plpgsql as $$
declare n integer;
begin
  execute p_sql;
  get diagnostics n = row_count;
  return n;
end $$;

-- --- fixtures ------------------------------------------------------------------
-- Staff: a1 coordinador de Verano, Terminada y Permanente; a2 coordinador de Invierno; ad admin; a3 sin rol.
-- Colportores: b1 (Verano e Invierno, sin carrera) b2 (Verano, Teología) b3 (Verano, Medicina: solo tiene meta de Invierno)
--        b4 (Verano, inscripción de baja) b5 (Verano, sin carrera) b6 (Permanente, Teología) b7 (sin campaña)
--        b8 (Verano, cuenta dada de baja).
-- Carreras: c1 Teología (metas de Verano e Invierno) c2 Sistemas (sin metas) c3 Enfermería (solo Invierno)
--        c4 Derecho (dada de baja) c5 Medicina (solo Invierno).
-- Campañas: e1 Verano (a1, hasta 2099)  e2 Invierno (a2, desde 2100)  e3 Terminada (a1, VERANO, terminó el 30/06)
--        e4 Borrada  e5 Permanente (a1).
insert into auth.users (id, instance_id, aud, role, email, encrypted_password, confirmed_at, created_at, updated_at)
select pg_temp.u(s), '00000000-0000-0000-0000-000000000000',
       'authenticated', 'authenticated', 'beca-' || s || '@example.com', 'x', now(), now(), now()
  from unnest(array['a1','a2','a3','ad','b1','b2','b3','b4','b5','b6','b7','b8']) s;

update public.usuario u set nombre = x.n, apellido = x.a
  from (values ('b1','Ana','Alfa'), ('b2','Beto','Bravo'), ('b3','Carla','Cruz'), ('b4','Diego','Duarte'),
               ('b5','Elena','Aguirre'), ('b6','Fede','Fuentes'), ('b7','Gabi','Gómez'), ('b8','Hugo','Herrera')) x(s, n, a)
 where u.id = pg_temp.u(x.s);

insert into public.usuario_rol (usuario_id, rol_id)
select pg_temp.u(x.s), r.id
  from (values ('a1','COORDINADOR'), ('a2','COORDINADOR'), ('ad','ADMIN'),
               ('b1','COLPORTOR'), ('b2','COLPORTOR'), ('b3','COLPORTOR'), ('b4','COLPORTOR'),
               ('b5','COLPORTOR'), ('b6','COLPORTOR'), ('b7','COLPORTOR'), ('b8','COLPORTOR')) x(s, codigo)
  join public.rol r on r.codigo = x.codigo;

insert into public.pais (id, nombre, iso_code) values (pg_temp.u('d0'), 'Pais beca', 'ZB');
insert into public.ciudad (id, nombre, departamento, pais_id, lat_centro, lon_centro, zoom_inicial) values
  (pg_temp.u('d1'), 'Ciudad beca q117', 'Departamento de prueba beca', pg_temp.u('d0'), -34.91, -56.18, 13);

insert into public.campania (id, nombre, tipo, fecha_inicio, fecha_fin, coordinador_id, deleted_at) values
  (pg_temp.u('e1'), 'Verano',     'VERANO',     '2026-08-03', '2099-12-31', pg_temp.u('a1'), null),
  (pg_temp.u('e2'), 'Invierno',   'INVIERNO',   '2100-01-01', null,         pg_temp.u('a2'), null),
  (pg_temp.u('e3'), 'Terminada',  'VERANO',     '2026-04-01', '2026-06-30', pg_temp.u('a1'), null),
  (pg_temp.u('e4'), 'Borrada',    'VERANO',     '2026-08-03', null,         pg_temp.u('a1'), now()),
  (pg_temp.u('e5'), 'Permanente', 'PERMANENTE', '2026-08-03', null,         pg_temp.u('a1'), null);

insert into public.carrera (id, nombre, deleted_at) values
  (pg_temp.u('c1'), 'Teología',   null),
  (pg_temp.u('c2'), 'Sistemas',   null),
  (pg_temp.u('c3'), 'Enfermería', null),
  (pg_temp.u('c4'), 'Derecho',    now()),
  (pg_temp.u('c5'), 'Medicina',   null);

-- Teología: Verano 60 libros o 30.000 pesos / 120 o 60.000 (en centavos); Invierno 50 / 100 libros.
insert into public.meta_beca (id, carrera_id, tipo_campania, meta_media, meta_completa, meta_media_monto, meta_completa_monto) values
  (pg_temp.u('f1'), pg_temp.u('c1'), 'VERANO',   60, 120, 3000000, 6000000),
  (pg_temp.u('f2'), pg_temp.u('c1'), 'INVIERNO', 50, 100, 2500000, 5000000),
  (pg_temp.u('f3'), pg_temp.u('c3'), 'INVIERNO', 40,  80, 2000000, 4000000),
  (pg_temp.u('f4'), pg_temp.u('c5'), 'INVIERNO', 30,  60, 1500000, 3000000);

insert into public.campania_colportor (campania_id, usuario_id, created_at) values
  (pg_temp.u('e1'), pg_temp.u('b1'), '2026-08-01 10:00-03'),
  (pg_temp.u('e1'), pg_temp.u('b2'), '2026-08-01 10:00-03'),
  (pg_temp.u('e1'), pg_temp.u('b3'), '2026-08-01 10:00-03'),
  (pg_temp.u('e1'), pg_temp.u('b4'), '2026-08-01 10:00-03'),
  (pg_temp.u('e1'), pg_temp.u('b5'), '2026-08-01 10:00-03'),
  (pg_temp.u('e1'), pg_temp.u('b8'), '2026-08-01 10:00-03'),
  (pg_temp.u('e2'), pg_temp.u('b1'), '2026-07-01 10:00-03'),
  (pg_temp.u('e3'), pg_temp.u('b2'), '2026-03-20 10:00-03'),
  (pg_temp.u('e5'), pg_temp.u('b6'), '2026-08-01 10:00-03');
update public.campania_colportor set deleted_at = '2026-09-15 12:00:00+00'
 where campania_id = pg_temp.u('e1') and usuario_id = pg_temp.u('b4');

update public.usuario set carrera_id = pg_temp.u('c1') where id in (pg_temp.u('b2'), pg_temp.u('b6'));
update public.usuario set carrera_id = pg_temp.u('c5') where id = pg_temp.u('b3');
-- b8 tiene la cuenta dada de baja (la inscripción sigue viva): no cuenta para nadie.
update public.usuario set carrera_id = pg_temp.u('c1'), deleted_at = now() where id = pg_temp.u('b8');

-- ---------------------------------------------------------------------------
-- 1. Las tablas: forma, checks, únicos y privilegios
-- ---------------------------------------------------------------------------
select has_table('public', 'carrera', 'existe carrera');
select has_table('public', 'meta_beca', 'existe meta_beca');
select has_column('public', 'usuario', 'carrera_id', 'usuario.carrera_id existe');
select col_is_fk('public', 'usuario', 'carrera_id', 'usuario.carrera_id es FK a carrera');
select col_is_null('public', 'usuario', 'carrera_id', 'usuario.carrera_id es opcional');
select has_column('public', 'usuario', 'carrera_elegida_en', 'usuario.carrera_elegida_en existe');
select col_is_null('public', 'usuario', 'carrera_elegida_en', 'usuario.carrera_elegida_en es opcional');
select col_is_fk('public', 'meta_beca', 'carrera_id', 'meta_beca.carrera_id es FK a carrera');
select is((select relrowsecurity from pg_class where oid = 'public.carrera'::regclass), true, 'carrera tiene RLS');
select is((select relrowsecurity from pg_class where oid = 'public.meta_beca'::regclass), true, 'meta_beca tiene RLS');
select ok(has_table_privilege('authenticated', 'public.carrera', 'select')
          and has_table_privilege('authenticated', 'public.meta_beca', 'select'),
          'authenticated lee carrera y meta_beca');
select ok(not has_table_privilege('authenticated', 'public.carrera', 'insert')
          and not has_table_privilege('authenticated', 'public.carrera', 'update')
          and not has_table_privilege('authenticated', 'public.meta_beca', 'insert')
          and not has_table_privilege('authenticated', 'public.meta_beca', 'update')
          and not has_table_privilege('authenticated', 'public.meta_beca', 'delete'),
          'authenticated NO escribe carrera ni meta_beca');
select ok(not has_table_privilege('anon', 'public.carrera', 'select')
          and not has_table_privilege('anon', 'public.meta_beca', 'select'),
          'anon no lee carrera ni meta_beca');

select is(pg_temp.cod($$ insert into public.carrera (nombre) values ('Teología') $$), '23505',
          'carrera: el nombre no se repite');
select is(pg_temp.cod($$ insert into public.carrera (nombre) values ('  teología ') $$), '23505',
          'carrera: ni con otras mayúsculas o espacios de más');
select is(pg_temp.cod($$ insert into public.carrera (nombre) values ('   ') $$), '23514',
          'carrera: el nombre no puede estar en blanco');
select is(pg_temp.cod($$ insert into public.carrera (nombre) values ('Derecho') $$), 'ok',
          'carrera: el nombre de una dada de baja se puede volver a usar');
select is(pg_temp.cod($$ insert into public.meta_beca (carrera_id, tipo_campania, meta_media, meta_completa, meta_media_monto, meta_completa_monto)
            values ('01920000-0000-7000-8000-0000000117c1', 'VERANO', 1, 2, 1, 2) $$), '23505',
          'meta_beca: una sola meta viva por carrera y tipo de campaña');
select is(pg_temp.cod($$ insert into public.meta_beca (carrera_id, tipo_campania, meta_media, meta_completa, meta_media_monto, meta_completa_monto)
            values ('01920000-0000-7000-8000-0000000117c2', 'PERMANENTE', 1, 2, 1, 2) $$), '23514',
          'meta_beca: el tipo de campaña es VERANO o INVIERNO');
select is(pg_temp.cod($$ insert into public.meta_beca (carrera_id, tipo_campania, meta_media, meta_completa, meta_media_monto, meta_completa_monto)
            values ('01920000-0000-7000-8000-0000000117c2', 'VERANO', 10, 5, 1, 2) $$), '23514',
          'meta_beca: la completa no es menor que la media (libros)');
select is(pg_temp.cod($$ insert into public.meta_beca (carrera_id, tipo_campania, meta_media, meta_completa, meta_media_monto, meta_completa_monto)
            values ('01920000-0000-7000-8000-0000000117c2', 'VERANO', 1, 2, 10, 5) $$), '23514',
          'meta_beca: la completa no es menor que la media (monto)');
select is(pg_temp.cod($$ insert into public.meta_beca (carrera_id, tipo_campania, meta_media, meta_completa, meta_media_monto, meta_completa_monto)
            values ('01920000-0000-7000-8000-0000000117c2', 'VERANO', -1, 2, 1, 2) $$), '23514',
          'meta_beca: nada negativo');
select is(pg_temp.cod($$ insert into public.meta_beca (carrera_id, tipo_campania, meta_media, meta_completa, meta_media_monto, meta_completa_monto)
            values ('01920000-0000-7000-8000-0000000117fe', 'VERANO', 1, 2, 1, 2) $$), '23503',
          'meta_beca: la carrera tiene que existir');
select is(pg_temp.cod($$ insert into public.meta_beca (carrera_id, tipo_campania, meta_media, meta_completa, meta_media_monto, meta_completa_monto)
            values ('01920000-0000-7000-8000-0000000117c3', 'VERANO', 0, 0, 0, 0) $$), 'ok',
          'meta_beca: una meta en cero es válida (media = completa)');
-- Un cliente no escribe las metas.
select pg_temp.actuar_como(pg_temp.u('a1'));
select is(pg_temp.cod($$ insert into public.carrera (nombre) values ('Intrusa') $$), '42501',
          'el coordinador no agrega carreras');
select is(pg_temp.cod($$ update public.meta_beca set meta_media = 1 $$), '42501',
          'el coordinador no cambia las metas');
select is((select count(*)::int from public.carrera c where c.deleted_at is null), 5,
          'el coordinador lee el catálogo (las vivas)');
select pg_temp.actuar_como_servidor();

-- Las funciones: privilegios.
select ok(has_function_privilege('authenticated', 'public.elegir_carrera(uuid, uuid, uuid)', 'execute')
          and has_function_privilege('authenticated', 'public.asignar_beca(uuid, uuid[], text)', 'execute')
          and has_function_privilege('authenticated', 'public.becas_de_campania(uuid)', 'execute'),
          'authenticated ejecuta las tres RPC');
select ok(not has_function_privilege('anon', 'public.elegir_carrera(uuid, uuid, uuid)', 'execute')
          and not has_function_privilege('anon', 'public.asignar_beca(uuid, uuid[], text)', 'execute')
          and not has_function_privilege('anon', 'public.becas_de_campania(uuid)', 'execute')
          and not has_function_privilege('service_role', 'public.asignar_beca(uuid, uuid[], text)', 'execute'),
          'anon y service_role NO las ejecutan');
select is((select count(*)::int
             from pg_proc p, aclexplode(p.proacl) a
            where a.grantee = 0 and a.privilege_type = 'EXECUTE'
              and p.oid in ('public.elegir_carrera(uuid, uuid, uuid)'::regprocedure,
                            'public.asignar_beca(uuid, uuid[], text)'::regprocedure,
                            'public.becas_de_campania(uuid)'::regprocedure,
                            'public.exigir_coordinador_de_campania_para_beca(uuid)'::regprocedure,
                            'public.tg_usuario_carrera_servidor()'::regprocedure,
                            'public.tg_usuario_carrera_auditar()'::regprocedure,
                            'public.tg_campania_colportor_beca_auditar()'::regprocedure)),
          0, 'ninguna tiene EXECUTE para PUBLIC');
select ok(not has_function_privilege('authenticated', 'public.exigir_coordinador_de_campania_para_beca(uuid)', 'execute')
          and not has_function_privilege('authenticated', 'public.tg_usuario_carrera_auditar()', 'execute')
          and not has_function_privilege('authenticated', 'public.tg_campania_colportor_beca_auditar()', 'execute'),
          'el permiso común y las funciones de los triggers no se llaman desde afuera');
select is((select count(*)::int from pg_proc p
            where p.pronamespace = 'public'::regnamespace
              and p.proname in ('elegir_carrera', 'asignar_beca', 'becas_de_campania')),
          3, 'hay una sola firma de cada RPC');
select is((select bool_and(p.prosecdef) from pg_proc p
            where p.pronamespace = 'public'::regnamespace
              and p.proname in ('elegir_carrera', 'asignar_beca', 'becas_de_campania')),
          true, 'las tres son SECURITY DEFINER');
select is((select bool_and(p.proconfig = array['search_path=""']) from pg_proc p
            where p.pronamespace = 'public'::regnamespace
              and p.proname in ('elegir_carrera', 'asignar_beca', 'becas_de_campania')),
          true, 'las tres fijan search_path vacío');
select is((select p.prosecdef from pg_proc p where p.oid = 'public.tg_usuario_carrera_servidor()'::regprocedure),
          false, 'el trigger que cuida la carrera es INVOKER (mira current_user)');

-- ---------------------------------------------------------------------------
-- 2. usuario.carrera_id: un cliente no la cambia a mano
-- ---------------------------------------------------------------------------
select pg_temp.actuar_como(pg_temp.u('b1'));
select is(pg_temp.error_de($$ update public.usuario set carrera_id = '01920000-0000-7000-8000-0000000117c1'
                              where id = '01920000-0000-7000-8000-0000000117b1' $$),
          '42501: La carrera la elige el coordinador de la campaña en Becas y solo un administrador la corrige.',
          'el colportor no se pone su carrera');
select is(pg_temp.cod($$ update public.usuario set carrera_id = carrera_id, nombre = 'Ana'
                         where id = '01920000-0000-7000-8000-0000000117b1' $$), 'ok',
          'mandar la fila entera con la misma carrera no falla (no cambia nada)');
select pg_temp.actuar_como(pg_temp.u('a1'));
select is(pg_temp.cod($$ update public.usuario set carrera_id = '01920000-0000-7000-8000-0000000117c1'
                         where id = '01920000-0000-7000-8000-0000000117a1' $$), '42501',
          'el coordinador no se la pone ni a sí mismo');
select is(pg_temp.filas($$ update public.usuario set carrera_id = '01920000-0000-7000-8000-0000000117c1'
                           where id = '01920000-0000-7000-8000-0000000117b1' $$), 0,
          'el coordinador no llega a la fila de un colportor por un UPDATE (la RLS la esconde)');
select pg_temp.actuar_como(pg_temp.u('ad'));
select is(pg_temp.cod($$ update public.usuario set carrera_id = '01920000-0000-7000-8000-0000000117c1'
                         where id = '01920000-0000-7000-8000-0000000117b7' $$), 'ok',
          'el ADMIN corrige la carrera de cualquiera');
select pg_temp.actuar_como_servidor();
select is(pg_temp.carrera_de('b7'), 'c1', 'y quedó');
select is((select carrera_elegida_en from public.usuario where id = pg_temp.u('b7')), now(),
          'y la fecha de la elección quedó estampada');
select is(pg_temp.eventos('carrera_del_colportor_cambiada', 'b7',
                          jsonb_build_object('carrera_nueva', pg_temp.u('c1'))), 1,
          'el cambio del ADMIN queda en audit_log');
select is(pg_temp.actor_del_ultimo('carrera_del_colportor_cambiada', 'b7'), pg_temp.u('ad'),
          'con el ADMIN como actor');
select is(pg_temp.cod($$ update public.usuario set carrera_id = null where id = '01920000-0000-7000-8000-0000000117b7' $$), 'ok',
          'el servidor la cambia sin restricción');
select is(pg_temp.carrera_de('b7'), '-', 'b7 sin carrera otra vez');
select is((select carrera_elegida_en is null from public.usuario where id = pg_temp.u('b7')), true,
          'quitar la carrera borra también su fecha');
select is(pg_temp.cod($$ update public.usuario set carrera_id = '01920000-0000-7000-8000-0000000117fe'
                         where id = '01920000-0000-7000-8000-0000000117b7' $$), '23503',
          'una carrera que no existe se rechaza');
-- La fecha de la elección: un cliente no la escribe, y con la carrera nunca viaja una a mano.
select pg_temp.actuar_como(pg_temp.u('b1'));
select is(pg_temp.cod($$ update public.usuario set carrera_elegida_en = '2020-01-01 00:00+00'
                         where id = '01920000-0000-7000-8000-0000000117b1' $$), '42501',
          'el colportor no se pone la fecha de su carrera');
select pg_temp.actuar_como(pg_temp.u('ad'));
select is(pg_temp.cod($$ update public.usuario set carrera_id = '01920000-0000-7000-8000-0000000117c1',
                                carrera_elegida_en = '2020-01-01 00:00+00'
                         where id = '01920000-0000-7000-8000-0000000117b7' $$), 'ok',
          'el ADMIN cambia la carrera mandando también una fecha');
select pg_temp.actuar_como_servidor();
select is((select carrera_elegida_en from public.usuario where id = pg_temp.u('b7')), now(),
          'la fecha mandada a mano se pisa con la de ahora');
update public.usuario set carrera_id = null where id = pg_temp.u('b7');

-- ---------------------------------------------------------------------------
-- 3. elegir_carrera
-- ---------------------------------------------------------------------------
select pg_temp.actuar_como_servidor();
select is(pg_temp.cod($$ select * from public.elegir_carrera('01920000-0000-7000-8000-0000000117e1', '01920000-0000-7000-8000-0000000117b1', '01920000-0000-7000-8000-0000000117c1') $$),
          '42501', 'elegir: sin JWT (el servidor) falla');
select pg_temp.actuar_sin_jwt();
select is(pg_temp.cod($$ select * from public.elegir_carrera('01920000-0000-7000-8000-0000000117e1', '01920000-0000-7000-8000-0000000117b1', '01920000-0000-7000-8000-0000000117c1') $$),
          '42501', 'elegir: authenticated sin sesión falla');
select pg_temp.actuar_como(pg_temp.u('b1'));
select is(pg_temp.error_de($$ select * from public.elegir_carrera('01920000-0000-7000-8000-0000000117e1', '01920000-0000-7000-8000-0000000117b1', '01920000-0000-7000-8000-0000000117c1') $$),
          '42501: Solo el coordinador de la campaña o un administrador puede ver y asignar sus becas. Entrá con la cuenta del coordinador de esta campaña.',
          'elegir: el colportor no elige su carrera');
select pg_temp.actuar_como(pg_temp.u('a3'));
select is(pg_temp.cod($$ select * from public.elegir_carrera('01920000-0000-7000-8000-0000000117e1', '01920000-0000-7000-8000-0000000117b1', '01920000-0000-7000-8000-0000000117c1') $$),
          '42501', 'elegir: sin ningún rol falla');
select pg_temp.actuar_como(pg_temp.u('a2'));
select is(pg_temp.cod($$ select * from public.elegir_carrera('01920000-0000-7000-8000-0000000117e1', '01920000-0000-7000-8000-0000000117b1', '01920000-0000-7000-8000-0000000117c1') $$),
          '42501', 'elegir: el coordinador de otra campaña falla');

select pg_temp.actuar_como(pg_temp.u('a1'));
select is(pg_temp.cod($$ select * from public.elegir_carrera('01920000-0000-7000-8000-0000000117e4', '01920000-0000-7000-8000-0000000117b1', '01920000-0000-7000-8000-0000000117c1') $$),
          'CZ001', 'elegir: una campaña dada de baja no existe');
select is(pg_temp.cod($$ select * from public.elegir_carrera('01920000-0000-7000-8000-0000000117fe', '01920000-0000-7000-8000-0000000117b1', '01920000-0000-7000-8000-0000000117c1') $$),
          'CZ001', 'elegir: una campaña inexistente no existe');
select is(pg_temp.cod($$ select * from public.elegir_carrera(null, '01920000-0000-7000-8000-0000000117b1', '01920000-0000-7000-8000-0000000117c1') $$),
          'CZ001', 'elegir: sin campaña, CZ001');
select is(pg_temp.cod($$ select * from public.elegir_carrera('01920000-0000-7000-8000-0000000117e3', '01920000-0000-7000-8000-0000000117b2', '01920000-0000-7000-8000-0000000117c1') $$),
          'BC001', 'elegir: una campaña terminada ya no cambia');
select is(pg_temp.cod($$ select * from public.elegir_carrera('01920000-0000-7000-8000-0000000117e1', '01920000-0000-7000-8000-0000000117b7', '01920000-0000-7000-8000-0000000117c1') $$),
          'CZ003', 'elegir: un colportor sin inscripción en la campaña');
select is(pg_temp.cod($$ select * from public.elegir_carrera('01920000-0000-7000-8000-0000000117e1', '01920000-0000-7000-8000-0000000117b4', '01920000-0000-7000-8000-0000000117c1') $$),
          'CZ003', 'elegir: ni uno cuya inscripción está dada de baja');
select is(pg_temp.cod($$ select * from public.elegir_carrera('01920000-0000-7000-8000-0000000117e1', '01920000-0000-7000-8000-0000000117b6', '01920000-0000-7000-8000-0000000117c1') $$),
          'CZ003', 'elegir: ni uno que está en otra campaña');
select is(pg_temp.cod($$ select * from public.elegir_carrera('01920000-0000-7000-8000-0000000117e1', '01920000-0000-7000-8000-0000000117fe', '01920000-0000-7000-8000-0000000117c1') $$),
          'CZ003', 'elegir: ni un usuario que no existe');
select is(pg_temp.cod($$ select * from public.elegir_carrera('01920000-0000-7000-8000-0000000117e1', '01920000-0000-7000-8000-0000000117b8', '01920000-0000-7000-8000-0000000117c2') $$),
          'CZ003', 'elegir: ni uno cuya cuenta está dada de baja');
select is(pg_temp.cod($$ select * from public.elegir_carrera('01920000-0000-7000-8000-0000000117e1', '01920000-0000-7000-8000-0000000117b1', null) $$),
          'BC002', 'elegir: sin carrera, BC002');
select is(pg_temp.cod($$ select * from public.elegir_carrera('01920000-0000-7000-8000-0000000117e1', '01920000-0000-7000-8000-0000000117b1', '01920000-0000-7000-8000-0000000117fe') $$),
          'BC002', 'elegir: una carrera que no existe');
select is(pg_temp.cod($$ select * from public.elegir_carrera('01920000-0000-7000-8000-0000000117e1', '01920000-0000-7000-8000-0000000117b1', '01920000-0000-7000-8000-0000000117c4') $$),
          'BC002', 'elegir: ni una dada de baja');
select is(pg_temp.carrera_de('b1'), '-', 'ningún intento fallido le puso carrera a b1');

select is(pg_temp.eleg('e1', 'b1', 'c1'), 'b1:c1:S', 'elegir: b1 queda con Teología (cambio)');
select is(pg_temp.carrera_de('b1'), 'c1', 'la carrera quedó en la cuenta');
select is(pg_temp.eventos('carrera_del_colportor_cambiada', 'b1',
                          jsonb_build_object('carrera_nueva', pg_temp.u('c1'), 'carrera_anterior', null)), 1,
          'queda en audit_log, de la carrera anterior (ninguna) a la nueva');
select is(pg_temp.actor_del_ultimo('carrera_del_colportor_cambiada', 'b1'), pg_temp.u('a1'),
          'con la coordinadora como actor');
select is((select r.carrera_elegida_en from public.becas_de_campania(pg_temp.u('e1')) r where r.usuario_id = pg_temp.u('b1')),
          now(), 'la coordinadora lee en Becas cuándo se eligió la carrera');
select pg_temp.actuar_como_servidor();
update public.usuario set carrera_elegida_en = '2026-09-01 10:00-03' where id = pg_temp.u('b1');
select pg_temp.actuar_como(pg_temp.u('a1'));
select is(pg_temp.eleg('e1', 'b1', 'c1'), 'b1:c1:N', 'elegir: el reintento (doble toque) no cambia nada');
select is(pg_temp.eventos('carrera_del_colportor_cambiada', 'b1'), 1, 'y no suma un segundo registro');
select is(pg_temp.cod($$ select * from public.elegir_carrera('01920000-0000-7000-8000-0000000117e1', '01920000-0000-7000-8000-0000000117b1', '01920000-0000-7000-8000-0000000117c2') $$),
          'BC005', 'elegir: la coordinadora no la cambia una vez elegida');
select is(pg_temp.carrera_de('b1'), 'c1', 'y la carrera sigue siendo la elegida');
select is((select r.carrera_elegida_en from public.becas_de_campania(pg_temp.u('e1')) r where r.usuario_id = pg_temp.u('b1')),
          '2026-09-01 10:00-03'::timestamptz, 'el reintento y el intento rechazado no tocan la fecha');
select is(pg_temp.error_de($$ select * from public.elegir_carrera('01920000-0000-7000-8000-0000000117e1', '01920000-0000-7000-8000-0000000117b2', '01920000-0000-7000-8000-0000000117c2') $$) like 'BC005: La carrera de este colportor ya está elegida%Si fue un error, pedile a un administrador que la corrija.',
          true, 'el aviso dice qué pasó y a quién pedirle que la corrija');

select pg_temp.actuar_como(pg_temp.u('ad'));
select is(pg_temp.eleg('e1', 'b1', 'c2'), 'b1:c2:S', 'elegir: el ADMIN la corrige');
select is(pg_temp.eleg('e1', 'b1', 'c1'), 'b1:c1:S', 'y la vuelve a cambiar');
select pg_temp.actuar_como_servidor();
select is(pg_temp.eventos('carrera_del_colportor_cambiada', 'b1'), 3, 'cada cambio queda en audit_log');
select is((select carrera_elegida_en from public.usuario where id = pg_temp.u('b1')), now(),
          'y cada corrección del ADMIN estampa la fecha otra vez');

-- La carrera sigue a la persona: en la otra campaña ya está elegida.
select pg_temp.actuar_como(pg_temp.u('a2'));
select is(pg_temp.eleg('e2', 'b1', 'c1'), 'b1:c1:N', 'elegir: en la próxima campaña la carrera ya estaba (no cambia)');
select is(pg_temp.cod($$ select * from public.elegir_carrera('01920000-0000-7000-8000-0000000117e2', '01920000-0000-7000-8000-0000000117b1', '01920000-0000-7000-8000-0000000117c2') $$),
          'BC005', 'y tampoco la cambia el otro coordinador');
select is(pg_temp.cod($$ select * from public.elegir_carrera('01920000-0000-7000-8000-0000000117e1', '01920000-0000-7000-8000-0000000117b2', '01920000-0000-7000-8000-0000000117c1') $$),
          '42501', 'ni elige en la campaña de otro');
select pg_temp.actuar_como_servidor();

-- ---------------------------------------------------------------------------
-- 4. asignar_beca
-- ---------------------------------------------------------------------------
-- Estado: b1 Teología, b2 Teología, b3 Medicina (sin meta de Verano), b5 sin carrera, b6 Teología (Permanente).
select pg_temp.actuar_como_servidor();
select is(pg_temp.cod($$ select * from public.asignar_beca('01920000-0000-7000-8000-0000000117e1', array['01920000-0000-7000-8000-0000000117b1']::uuid[], 'MEDIA') $$),
          '42501', 'asignar: sin JWT (el servidor) falla');
select pg_temp.actuar_sin_jwt();
select is(pg_temp.cod($$ select * from public.asignar_beca('01920000-0000-7000-8000-0000000117e1', array['01920000-0000-7000-8000-0000000117b1']::uuid[], 'MEDIA') $$),
          '42501', 'asignar: authenticated sin sesión falla');
select pg_temp.actuar_como(pg_temp.u('b1'));
select is(pg_temp.cod($$ select * from public.asignar_beca('01920000-0000-7000-8000-0000000117e1', array['01920000-0000-7000-8000-0000000117b1']::uuid[], 'COMPLETA') $$),
          '42501', 'asignar: el colportor no se asigna la beca');
select pg_temp.actuar_como(pg_temp.u('a3'));
select is(pg_temp.cod($$ select * from public.asignar_beca('01920000-0000-7000-8000-0000000117e1', array['01920000-0000-7000-8000-0000000117b1']::uuid[], 'MEDIA') $$),
          '42501', 'asignar: sin ningún rol falla');
select pg_temp.actuar_como(pg_temp.u('a2'));
select is(pg_temp.cod($$ select * from public.asignar_beca('01920000-0000-7000-8000-0000000117e1', array['01920000-0000-7000-8000-0000000117b1']::uuid[], 'MEDIA') $$),
          '42501', 'asignar: el coordinador de otra campaña falla');

select pg_temp.actuar_como(pg_temp.u('a1'));
select is(pg_temp.cod($$ select * from public.asignar_beca('01920000-0000-7000-8000-0000000117e4', array['01920000-0000-7000-8000-0000000117b1']::uuid[], 'MEDIA') $$),
          'CZ001', 'asignar: una campaña dada de baja no existe');
select is(pg_temp.cod($$ select * from public.asignar_beca(null, array['01920000-0000-7000-8000-0000000117b1']::uuid[], 'MEDIA') $$),
          'CZ001', 'asignar: sin campaña, CZ001');
select is(pg_temp.cod($$ select * from public.asignar_beca('01920000-0000-7000-8000-0000000117e3', array['01920000-0000-7000-8000-0000000117b2']::uuid[], 'MEDIA') $$),
          'BC001', 'asignar: una campaña terminada ya no cambia');
select is(pg_temp.cod($$ select * from public.asignar_beca('01920000-0000-7000-8000-0000000117e1', array['01920000-0000-7000-8000-0000000117b1']::uuid[], 'ORO') $$),
          '22023', 'asignar: un tipo que no existe');
select is(pg_temp.cod($$ select * from public.asignar_beca('01920000-0000-7000-8000-0000000117e1', array['01920000-0000-7000-8000-0000000117b1']::uuid[], 'media') $$),
          '22023', 'asignar: el tipo va en mayúsculas, como lo guarda la tabla');
select is(pg_temp.cod($$ select * from public.asignar_beca('01920000-0000-7000-8000-0000000117e1', null, 'MEDIA') $$),
          '22023', 'asignar: sin lista de colportores');
select is(pg_temp.cod($$ select * from public.asignar_beca('01920000-0000-7000-8000-0000000117e1', array[]::uuid[], 'MEDIA') $$),
          '22023', 'asignar: con la lista vacía');
select is(pg_temp.cod($$ select * from public.asignar_beca('01920000-0000-7000-8000-0000000117e1', array[null]::uuid[], 'MEDIA') $$),
          '22023', 'asignar: con una lista de nulos');
select is(pg_temp.error_de($$ select * from public.asignar_beca('01920000-0000-7000-8000-0000000117e1', array[]::uuid[], 'MEDIA') $$),
          '22023: Elegí al menos un colportor para asignarle la beca.', 'y el aviso dice qué hacer');

-- Los que no están en la campaña, y todo o nada.
select is(pg_temp.cod($$ select * from public.asignar_beca('01920000-0000-7000-8000-0000000117e1', array['01920000-0000-7000-8000-0000000117b7']::uuid[], 'MEDIA') $$),
          'CZ003', 'asignar: un colportor sin inscripción en la campaña');
select is(pg_temp.cod($$ select * from public.asignar_beca('01920000-0000-7000-8000-0000000117e1', array['01920000-0000-7000-8000-0000000117b4']::uuid[], 'MEDIA') $$),
          'CZ003', 'asignar: ni uno cuya inscripción está dada de baja');
select is(pg_temp.cod($$ select * from public.asignar_beca('01920000-0000-7000-8000-0000000117e1',
            array['01920000-0000-7000-8000-0000000117b1', '01920000-0000-7000-8000-0000000117b6']::uuid[], 'MEDIA') $$),
          'CZ003', 'asignar: si uno de varios no es de la campaña, falla');
select is(pg_temp.cod($$ select * from public.asignar_beca('01920000-0000-7000-8000-0000000117e1', array['01920000-0000-7000-8000-0000000117b8']::uuid[], 'MEDIA') $$),
          'CZ003', 'asignar: ni uno cuya cuenta está dada de baja');
select is(pg_temp.beca('e1', 'b1'), '-|-|-|0', 'y b1 no cambió: todo o nada');

-- Falta la carrera o falta la meta.
select is(pg_temp.error_de($$ select * from public.asignar_beca('01920000-0000-7000-8000-0000000117e1', array['01920000-0000-7000-8000-0000000117b5']::uuid[], 'MEDIA') $$),
          'BC003: Falta elegir la carrera de 1 colportor(es). Elegila en Becas y volvé a asignar la beca.',
          'asignar: a b5 le falta la carrera, y el aviso dice cómo seguir');
select is(pg_temp.cod($$ select * from public.asignar_beca('01920000-0000-7000-8000-0000000117e1',
            array['01920000-0000-7000-8000-0000000117b1', '01920000-0000-7000-8000-0000000117b5']::uuid[], 'MEDIA') $$),
          'BC003', 'asignar: si a uno de varios le falta la carrera, falla');
select is(pg_temp.beca('e1', 'b1'), '-|-|-|0', 'y b1 tampoco cambió');
select is(pg_temp.error_de($$ select * from public.asignar_beca('01920000-0000-7000-8000-0000000117e1', array['01920000-0000-7000-8000-0000000117b3']::uuid[], 'COMPLETA') $$),
          'BC004: Falta configurar la meta de esta carrera. Avisale al administrador para que la cargue y volvé a asignar la beca.',
          'asignar: la carrera de b3 no tiene meta cargada para Verano; el aviso pide avisar al administrador');
select is(pg_temp.cod($$ select * from public.asignar_beca('01920000-0000-7000-8000-0000000117e1',
            array['01920000-0000-7000-8000-0000000117b1', '01920000-0000-7000-8000-0000000117b3']::uuid[], 'MEDIA') $$),
          'BC004', 'asignar: si la carrera de uno de varios no tiene meta, falla');
select is(pg_temp.beca('e1', 'b1'), '-|-|-|0', 'y b1 sigue sin beca');
-- «Sin beca» no necesita carrera ni meta.
select is(pg_temp.asig('e1', array['b3'], null), 'b3:-:-:-:N', 'asignar: «sin beca» a quien ya no tiene no toca nada');
select is(pg_temp.asig('e1', array['b5'], null), 'b5:-:-:-:N', 'asignar: «sin beca» sin carrera tampoco falla');

-- Asignar.
select is(pg_temp.asig('e1', array['b1'], 'MEDIA'), 'b1:MEDIA:60:3000000:S',
          'asignar: media beca de Teología en Verano = 60 libros y 3.000.000 centavos');
select is(pg_temp.beca('e1', 'b1'), 'MEDIA|60|3000000|1', 'la inscripción guarda el tipo y las dos metas');
select is(pg_temp.eventos('beca_asignada', 'b1',
                          jsonb_build_object('campania_id', pg_temp.u('e1'), 'tipo_nuevo', 'MEDIA',
                                             'meta_libros', 60, 'meta_monto_ces', 3000000)), 1,
          'queda en audit_log con el tipo y las metas');
select is(pg_temp.actor_del_ultimo('beca_asignada', 'b1'), pg_temp.u('a1'), 'con la coordinadora como actor');
select is(pg_temp.asig('e1', array['b1'], 'MEDIA'), 'b1:MEDIA:60:3000000:N', 'asignar: el reintento no cambia nada');
select is(pg_temp.beca('e1', 'b1'), 'MEDIA|60|3000000|1', 'y no sube sync_version: ningún teléfono re-descarga por nada');
select is(pg_temp.eventos('beca_asignada', 'b1'), 1, 'ni suma un segundo registro');
select is(pg_temp.asig('e1', array['b1'], 'COMPLETA'), 'b1:COMPLETA:120:6000000:S',
          'asignar: de media a completa recalcula las dos metas');
select is(pg_temp.eventos('beca_asignada', 'b1', jsonb_build_object('tipo_anterior', 'MEDIA', 'tipo_nuevo', 'COMPLETA')), 1,
          'y el registro dice de qué a qué');
-- Varios a la vez.
select is(pg_temp.asig('e1', array['b1', 'b2'], 'MEDIA'), 'b1:MEDIA:60:3000000:S;b2:MEDIA:60:3000000:S',
          'asignar: varios a la vez, cada uno con sus metas');
select is(pg_temp.asig('e1', array['b1', 'b2'], 'MEDIA'), 'b1:MEDIA:60:3000000:N;b2:MEDIA:60:3000000:N',
          'asignar: el reintento de varios no cambia a nadie');
select is(pg_temp.asig('e1', array['b2', 'b1', 'b2'], 'COMPLETA'), 'b1:COMPLETA:120:6000000:S;b2:COMPLETA:120:6000000:S',
          'asignar: un colportor repetido en la lista se cuenta una vez');
select is(pg_temp.beca('e1', 'b2'), 'COMPLETA|120|6000000|2', 'b2 se actualizó dos veces, no tres');
-- La beca de la otra campaña de la misma persona no se toca, y la meta sale del tipo de ESA campaña.
select pg_temp.actuar_como(pg_temp.u('a2'));
select is(pg_temp.asig('e2', array['b1'], 'MEDIA'), 'b1:MEDIA:50:2500000:S',
          'asignar: en Invierno la meta es la de Invierno (50 libros)');
select pg_temp.actuar_como_servidor();
select is(pg_temp.beca('e1', 'b1'), 'COMPLETA|120|6000000|4', 'y la beca de b1 en Verano quedó como estaba');
select pg_temp.actuar_como(pg_temp.u('a1'));
-- Sin beca.
select is(pg_temp.asig('e1', array['b1'], null), 'b1:-:-:-:S', 'asignar: «sin beca» deja el tipo y las dos metas en nada');
select is(pg_temp.beca('e1', 'b1'), '-|-|-|5', 'la inscripción lo guarda');
select is(pg_temp.eventos('beca_asignada', 'b1', jsonb_build_object('tipo_anterior', 'COMPLETA', 'tipo_nuevo', null, 'meta_libros', null)), 1,
          'y queda en audit_log');
select is(pg_temp.asig('e1', array['b1'], null), 'b1:-:-:-:N', 'asignar: «sin beca» repetido no cambia nada');
-- El ADMIN también.
select pg_temp.actuar_como(pg_temp.u('ad'));
select is(pg_temp.asig('e1', array['b2'], 'MEDIA'), 'b2:MEDIA:60:3000000:S', 'asignar: el ADMIN asigna en cualquier campaña');
select pg_temp.actuar_como(pg_temp.u('a1'));
-- Una campaña PERMANENTE no tiene meta (pendiente): avisa en vez de inventar.
select is(pg_temp.cod($$ select * from public.asignar_beca('01920000-0000-7000-8000-0000000117e5', array['01920000-0000-7000-8000-0000000117b6']::uuid[], 'MEDIA') $$),
          'BC004', 'asignar: en una campaña permanente no hay meta (BC004)');
select is(pg_temp.asig('e5', array['b6'], null), 'b6:-:-:-:N', 'pero «sin beca» sí se puede');

-- La copia: editar meta_beca después no cambia las becas ya asignadas (S50).
select pg_temp.actuar_como_servidor();
update public.meta_beca set meta_media = 70 where id = pg_temp.u('f1');
select is(pg_temp.beca('e1', 'b2')::text like 'MEDIA|60|3000000|%', true,
          'editar la meta de la carrera no cambia la beca ya asignada (sigue en 60)');
select pg_temp.actuar_como(pg_temp.u('a1'));
select is(pg_temp.asig('e1', array['b2'], 'MEDIA'), 'b2:MEDIA:70:3000000:S',
          'volver a asignar el mismo tipo copia la meta vigente');
select is(pg_temp.asig('e1', array['b2'], 'MEDIA'), 'b2:MEDIA:70:3000000:N', 'y ahí queda quieta');
-- Cambia solo el monto (los libros iguales): también se vuelve a copiar.
select pg_temp.actuar_como_servidor();
update public.meta_beca set meta_media_monto = 3100000 where id = pg_temp.u('f1');
select pg_temp.actuar_como(pg_temp.u('a1'));
select is(pg_temp.asig('e1', array['b2'], 'MEDIA'), 'b2:MEDIA:70:3100000:S', 'si cambia solo el monto, se vuelve a copiar');
select pg_temp.actuar_como_servidor();
update public.meta_beca set meta_media_monto = 3000000 where id = pg_temp.u('f1');
select pg_temp.actuar_como(pg_temp.u('a1'));
select is(pg_temp.asig('e1', array['b2'], 'MEDIA'), 'b2:MEDIA:70:3000000:S', 'y al volver el monto, vuelve');
select pg_temp.actuar_como_servidor();
-- Una meta dada de baja equivale a no tener meta.
update public.meta_beca set deleted_at = now() where id = pg_temp.u('f1');
select pg_temp.actuar_como(pg_temp.u('a1'));
select is(pg_temp.cod($$ select * from public.asignar_beca('01920000-0000-7000-8000-0000000117e1', array['01920000-0000-7000-8000-0000000117b2']::uuid[], 'COMPLETA') $$),
          'BC004', 'asignar: una meta dada de baja no cuenta');
select is(pg_temp.beca('e1', 'b2')::text like 'MEDIA|70|3000000|%', true, 'y la beca de b2 sigue como estaba');
select is((select r.meta_configurada from public.becas_de_campania(pg_temp.u('e1')) r where r.usuario_id = pg_temp.u('b2')),
          false, 'becas: con la meta dada de baja, la carrera figura sin meta cargada');
-- Cargan una meta nueva en su lugar: manda la viva, no la dada de baja.
select pg_temp.actuar_como_servidor();
insert into public.meta_beca (id, carrera_id, tipo_campania, meta_media, meta_completa, meta_media_monto, meta_completa_monto)
values (pg_temp.u('f5'), pg_temp.u('c1'), 'VERANO', 80, 160, 3500000, 7000000);
-- Y una dada de baja más nueva todavía (otra vieja edición): tampoco cuenta.
insert into public.meta_beca (id, carrera_id, tipo_campania, meta_media, meta_completa, meta_media_monto, meta_completa_monto, deleted_at)
values (pg_temp.u('f6'), pg_temp.u('c1'), 'VERANO', 99, 199, 9900000, 19900000, now()),
       (pg_temp.u('f7'), pg_temp.u('c1'), 'VERANO', 98, 198, 9800000, 19800000, now()),
       (pg_temp.u('f8'), pg_temp.u('c1'), 'VERANO', 97, 197, 9700000, 19700000, now());
select pg_temp.actuar_como(pg_temp.u('a1'));
select is(pg_temp.asig('e1', array['b2'], 'MEDIA'), 'b2:MEDIA:80:3500000:S',
          'asignar: con una meta dada de baja y otra viva para la misma carrera y tipo, usa la viva');
select pg_temp.actuar_como_servidor();
delete from public.meta_beca where id in (pg_temp.u('f5'), pg_temp.u('f6'), pg_temp.u('f7'), pg_temp.u('f8'));
update public.meta_beca set deleted_at = null where id = pg_temp.u('f1');
select pg_temp.actuar_como(pg_temp.u('a1'));
select is(pg_temp.asig('e1', array['b2'], 'MEDIA'), 'b2:MEDIA:70:3000000:S', 'y al volver la anterior, vuelve a copiar la suya');
select pg_temp.actuar_como_servidor();

-- ---------------------------------------------------------------------------
-- 5. becas_de_campania
-- ---------------------------------------------------------------------------
select pg_temp.actuar_como(pg_temp.u('a1'));
select is((select array(select k from jsonb_object_keys(
                  (select to_jsonb(r) from public.becas_de_campania(pg_temp.u('e1')) r limit 1)) k
                 order by k collate "C")),
          (select array(select k from unnest(array['apellido','carrera_elegida_en','carrera_id','carrera_nombre','meta_configurada','meta_libros',
                'meta_monto_ces','nombre','tipo_beca','usuario_id']) k order by k collate "C")),
          'becas_de_campania: la forma de la respuesta, sin emails ni clientes');
select is((select count(*)::int from public.becas_de_campania(pg_temp.u('e1'))), 4,
          'becas: los 4 inscriptos vivos de Verano (el de baja no sale)');
select is((select array_agg(right(s.usuario_id::text, 2))
             from (select r.usuario_id from public.becas_de_campania(pg_temp.u('e1')) r offset 0) s),
          array['b5','b1','b2','b3'], 'becas: por apellido');
select is((select format('%s|%s|%s|%s|%s', r.carrera_nombre, coalesce(r.tipo_beca, '-'), coalesce(r.meta_libros::text, '-'),
                         coalesce(r.meta_monto_ces::text, '-'), r.meta_configurada)
             from public.becas_de_campania(pg_temp.u('e1')) r where r.usuario_id = pg_temp.u('b2')),
          'Teología|MEDIA|70|3000000|t', 'becas: b2, con Teología, media beca y las dos metas');
select is((select format('%s|%s', r.carrera_nombre, r.meta_configurada)
             from public.becas_de_campania(pg_temp.u('e1')) r where r.usuario_id = pg_temp.u('b3')),
          'Medicina|f', 'becas: la carrera de b3 no tiene meta para el tipo de la campaña (el panel lo avisa antes de asignar)');
select is((select format('%s|%s|%s', coalesce(r.carrera_nombre, '-'), r.meta_configurada, coalesce(r.tipo_beca, '-'))
             from public.becas_de_campania(pg_temp.u('e1')) r where r.usuario_id = pg_temp.u('b5')),
          '-|f|-', 'becas: b5 sin carrera, sin beca');
select is((select r.carrera_elegida_en from public.becas_de_campania(pg_temp.u('e1')) r where r.usuario_id = pg_temp.u('b2')),
          now(), 'becas: b2 con la fecha en que se eligio su carrera (para elegida el 01/09)');
select is((select r.carrera_elegida_en is null from public.becas_de_campania(pg_temp.u('e1')) r where r.usuario_id = pg_temp.u('b5')),
          true, 'becas: b5, sin carrera, sin fecha');
select pg_temp.actuar_como(pg_temp.u('a2'));
select is((select format('%s|%s|%s|%s', r.carrera_nombre, r.meta_configurada, r.tipo_beca, r.meta_libros)
             from public.becas_de_campania(pg_temp.u('e2')) r where r.usuario_id = pg_temp.u('b1')),
          'Teología|t|MEDIA|50', 'becas: la misma persona en Invierno, con su carrera y la meta de Invierno');
select is(pg_temp.cod($$ select * from public.becas_de_campania('01920000-0000-7000-8000-0000000117e1') $$), '42501',
          'becas: el coordinador de otra campaña no las ve');
select pg_temp.actuar_como(pg_temp.u('b1'));
select is(pg_temp.cod($$ select * from public.becas_de_campania('01920000-0000-7000-8000-0000000117e1') $$), '42501',
          'becas: un colportor no las ve');
select pg_temp.actuar_sin_jwt();
select is(pg_temp.cod($$ select * from public.becas_de_campania('01920000-0000-7000-8000-0000000117e1') $$), '42501',
          'becas: sin sesión no hay lectura');
select pg_temp.actuar_como(pg_temp.u('a1'));
select is(pg_temp.cod($$ select * from public.becas_de_campania('01920000-0000-7000-8000-0000000117e4') $$), 'CZ001',
          'becas: una campaña dada de baja no existe');
select is(pg_temp.cod($$ select * from public.becas_de_campania('01920000-0000-7000-8000-0000000117e3') $$), 'BC001',
          'becas: una campaña terminada');
select pg_temp.actuar_como(pg_temp.u('ad'));
select is((select count(*)::int from public.becas_de_campania(pg_temp.u('e1'))), 4, 'becas: el ADMIN las lee');
select pg_temp.actuar_como_servidor();

-- ---------------------------------------------------------------------------
-- 6. meta_libros ya no la cambia cualquier coordinador
-- ---------------------------------------------------------------------------
select pg_temp.actuar_como(pg_temp.u('a2'));
select is(pg_temp.error_de($$ update public.campania_colportor set meta_libros = 1
                              where campania_id = '01920000-0000-7000-8000-0000000117e1' and usuario_id = '01920000-0000-7000-8000-0000000117b2' $$),
          '42501: La beca y la meta las fija el coordinador de la campaña',
          'el coordinador de otra campaña no cambia meta_libros por un UPDATE directo');
select is(pg_temp.cod($$ update public.campania_colportor set tipo_beca = 'COMPLETA'
                         where campania_id = '01920000-0000-7000-8000-0000000117e1' and usuario_id = '01920000-0000-7000-8000-0000000117b2' $$),
          '42501', 'ni el tipo de beca');
select pg_temp.actuar_como(pg_temp.u('a1'));
select is(pg_temp.cod($$ update public.campania_colportor set meta_libros = 71
                         where campania_id = '01920000-0000-7000-8000-0000000117e1' and usuario_id = '01920000-0000-7000-8000-0000000117b2' $$),
          'ok', 'la coordinadora de la campaña sí');
select is(pg_temp.eventos('beca_asignada', 'b2', jsonb_build_object('meta_libros', 71)), 1,
          'y el cambio a mano también queda en audit_log');
select pg_temp.actuar_como_servidor();
select is(pg_temp.cod($$ update public.campania_colportor set meta_libros = 72
                         where campania_id = '01920000-0000-7000-8000-0000000117e1' and usuario_id = '01920000-0000-7000-8000-0000000117b2' $$),
          'ok', 'el servidor, sin restricción');

-- ---------------------------------------------------------------------------
-- 7. La auditoría no lleva datos personales
-- ---------------------------------------------------------------------------
select is((select count(*)::int from auditoria.audit_log a
            where a.event_type in ('beca_asignada', 'carrera_del_colportor_cambiada')
              and (a.metadata::text like '%@%'
                   or a.metadata::text ~* 'mail|nombre|apellido|Ana|Alfa|Bravo|Teolog|Sistemas')),
          0, 'los registros de la beca y la carrera llevan solo ids, tipos y números');
select is((select array_agg(distinct k order by k) from auditoria.audit_log a, jsonb_object_keys(a.metadata) k
            where a.event_type = 'beca_asignada'),
          array['campania_id','meta_libros','meta_monto_ces','tipo_anterior','tipo_nuevo'],
          'beca_asignada: las claves del detalle');
select is((select array_agg(distinct k order by k) from auditoria.audit_log a, jsonb_object_keys(a.metadata) k
            where a.event_type = 'carrera_del_colportor_cambiada'),
          array['carrera_anterior','carrera_nueva'],
          'carrera_del_colportor_cambiada: las claves del detalle');

select * from finish();
rollback;
