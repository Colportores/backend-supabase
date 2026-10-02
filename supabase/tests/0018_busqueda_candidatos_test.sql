-- pgTAP · migración 0015 (backend-supabase#41): el coordinador deja de leer public.usuario
-- directo (RLS) y ve cuentas ajenas solo por RPC: buscar_candidatos() (vista 23: sugeridos y
-- búsqueda en el servidor) y colportores_de_campania() (ahora con email y estado).
begin;
select * from no_plan();

-- --- helpers -------------------------------------------------------------------
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

create or replace function pg_temp.u(p_sufijo text) returns uuid language sql as $$
  select ('01920000-0000-7000-8000-0000000018' || p_sufijo)::uuid;
$$;

-- --- fixtures (como postgres) --------------------------------------------------
-- Staff: a1 coordina Verano 2026 (e1), a2 coordina Otoño Norte (e2), ad ADMIN, a0 colportor.
-- Campañas: e1 Verano 2026 y e2 Otoño Norte vigentes; e3 Futura; e4 Vieja (terminada);
--           e5 Borrada.
-- Cuentas (created_at relativo a hoy, en días):
--   b1 Ana Martínez        pendiente                                   +10
--   b2 Anabel Pereira      pendiente, inscripta en Futura (no bloquea) +9
--   b5 Rodrigo Barrios     pendiente, inscripta en Vieja (terminada)   +8
--   ba Noelia Acosta       pendiente, inscripción BORRADA en Verano    +7
--   bd Ignacio Núñez       pendiente                                   +5 (empate con be)
--   be Melina Vázquez      pendiente                                   +5
--   bc Laura Suárez        pendiente, inscripta en Borrada             +3
--   bf Sofía Pérez         pendiente, con la tilde guardada en NFD     +2
--   b0 Adriana Luz         pendiente                                   +1
--   b3 Mariana Olivera     suspendida                                  +20
--   b4 Rodrigo Silva       en Otoño Norte (vigente)                    +20
--   bb Pablo Ferreira      suspendido y en Otoño Norte                 +20
--   b6 Diego Rocha         ya en Verano                                +20
--   b7 Joel Cabrera        ya en Verano, suspendido                    +20
--   b8 Gonzalo Sosa        email sin verificar                         +20
--   b9 Valentina Bentancor dada de baja                                +20
-- Las no pendientes son las más nuevas a propósito: los sugeridos filtran por estado, no por fecha.
insert into auth.users (id, instance_id, aud, role, email, encrypted_password, confirmed_at,
                        raw_user_meta_data, created_at, updated_at)
select pg_temp.u(x.s), '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
       x.email, 'x', case when x.s = 'b8' then null else now() end,
       jsonb_build_object('nombre', x.n, 'apellido', x.a), now(), now()
  from (values
    ('a1', 'coord1@buscar18.test', '', ''),
    ('a2', 'coord2@buscar18.test', '', ''),
    ('ad', 'admin@buscar18.test', '', ''),
    ('a0', 'sin.nombre.luz@buscar18.test', '', ''),
    ('b0', 'aluz@correo.uy', 'Adriana', 'Luz'),
    ('b1', 'ana.martinez@correo.uy', 'Ana', 'Martínez'),
    ('b2', 'anabel.p@correo.uy', 'Anabel', 'Pereira'),
    ('b3', 'mariana.olivera@correo.uy', 'Mariana', 'Olivera'),
    ('b4', 'rodrigo.silva@correo.uy', 'Rodrigo', 'Silva'),
    ('b5', 'rbarrios@correo.uy', 'Rodrigo', 'Barrios'),
    ('b6', 'drocha@equipo18.test', 'Diego', 'Rocha'),
    ('b7', 'jcabrera@equipo18.test', 'Joel', 'Cabrera'),
    ('b8', 'gonza.sosa@correo18.test', 'Gonzalo', 'Sosa'),
    ('b9', 'vbentancor@correo18.test', 'Valentina', 'Bentancor'),
    ('ba', 'nacosta@correo.uy', 'Noelia', 'Acosta'),
    ('bb', 'pferreira@correo.uy', 'Pablo', 'Ferreira'),
    ('bc', 'laura@correo.uy', 'Laura', 'Suárez'),
    ('bd', 'inunez@correo.uy', 'Ignacio', 'Núñez'),
    ('be', 'mvazquez@correo.uy', 'Melina', 'Vázquez'),
    ('bf', 'sperez@correo.uy', U&'Sofi\0301a', 'Pérez')) x(s, email, n, a);  -- «Sofía» con la tilde combinada (NFD)

insert into public.usuario_rol (usuario_id, rol_id)
select pg_temp.u(x.s), r.id
  from (values ('a1','COORDINADOR'), ('a2','COORDINADOR'), ('ad','ADMIN'), ('a0','COLPORTOR')) x(s, codigo)
  join public.rol r on r.codigo = x.codigo;

-- created_at es inmutable por UPDATE (tg_auditoria_update): se apaga el trigger solo acá.
alter table public.usuario disable trigger usuario_auditoria_update;
update public.usuario u set created_at = now() + x.dias * interval '1 day'
  from (values ('b1',10), ('b2',9), ('b5',8), ('ba',7), ('bd',5), ('be',5), ('bc',3), ('bf',2), ('b0',1),
               ('b3',20), ('b4',20), ('bb',20), ('b6',20), ('b7',20), ('b8',20), ('b9',20)) x(s, dias)
 where u.id = pg_temp.u(x.s);
alter table public.usuario enable trigger usuario_auditoria_update;

update public.usuario set suspendido_en = now() where id in (pg_temp.u('b3'), pg_temp.u('bb'), pg_temp.u('b7'));
update public.usuario set deleted_at = now() where id = pg_temp.u('b9');

insert into public.campania (id, nombre, tipo, fecha_inicio, fecha_fin, coordinador_id, deleted_at) values
  (pg_temp.u('e1'), 'Verano 2026', 'VERANO', current_date - 10, current_date + 30, pg_temp.u('a1'), null),
  (pg_temp.u('e2'), 'Otoño Norte', 'PERMANENTE', current_date - 20, null, pg_temp.u('a2'), null),
  (pg_temp.u('e3'), 'Futura', 'INVIERNO', current_date + 5, current_date + 60, pg_temp.u('a1'), null),
  (pg_temp.u('e4'), 'Vieja', 'VERANO', current_date - 90, current_date - 30, pg_temp.u('a1'), null),
  (pg_temp.u('e5'), 'Borrada', 'VERANO', current_date - 10, current_date + 30, pg_temp.u('a1'), now());

insert into public.campania_colportor (campania_id, usuario_id, deleted_at) values
  (pg_temp.u('e3'), pg_temp.u('b2'), null),
  (pg_temp.u('e4'), pg_temp.u('b5'), null),
  (pg_temp.u('e1'), pg_temp.u('ba'), now()),
  (pg_temp.u('e5'), pg_temp.u('bc'), null),
  (pg_temp.u('e2'), pg_temp.u('b4'), null),
  (pg_temp.u('e2'), pg_temp.u('bb'), null),
  (pg_temp.u('e1'), pg_temp.u('b6'), null),
  (pg_temp.u('e1'), pg_temp.u('b7'), null);

-- ---------------------------------------------------------------------------
-- 1. Forma y privilegios
-- ---------------------------------------------------------------------------
select is((select prosecdef from pg_proc where oid = 'public.buscar_candidatos(uuid, text, uuid)'::regprocedure),
          true, 'buscar_candidatos() es SECURITY DEFINER');
select is((select proconfig from pg_proc where oid = 'public.buscar_candidatos(uuid, text, uuid)'::regprocedure),
          array['search_path=""'], 'buscar_candidatos() fija search_path vacío');
select ok(has_function_privilege('authenticated', 'public.buscar_candidatos(uuid, text, uuid)', 'execute'),
          'authenticated ejecuta buscar_candidatos()');
select ok(not has_function_privilege('anon', 'public.buscar_candidatos(uuid, text, uuid)', 'execute'),
          'anon NO ejecuta buscar_candidatos()');
select ok(not has_function_privilege('authenticated', 'public.normalizar_busqueda(text)', 'execute'),
          'normalizar_busqueda() es interna');
select ok(has_function_privilege('authenticated', 'public.colportores_de_campania(uuid)', 'execute'),
          'authenticated sigue ejecutando colportores_de_campania() (recreada)');
select ok(not has_function_privilege('anon', 'public.colportores_de_campania(uuid)', 'execute'),
          'anon NO ejecuta colportores_de_campania() (recreada)');
select ok(not has_function_privilege('anon', 'public.estado_de_cuenta(timestamptz, boolean)', 'execute'),
          'anon NO ejecuta estado_de_cuenta()');
select is((select prosecdef from pg_proc where oid = 'public.estado_cuenta()'::regprocedure),
          false, 'estado_cuenta() sigue SECURITY INVOKER');

-- La precedencia del estado, en un solo lugar.
select is(public.estado_de_cuenta(now(), true), 'SUSPENDIDA', 'suspendida gana sobre la campaña vigente');
select is(public.estado_de_cuenta(null, true), 'ACTIVA', 'con campaña vigente: ACTIVA');
select is(public.estado_de_cuenta(null, false), 'PENDIENTE_ASIGNACION', 'sin campaña vigente: PENDIENTE_ASIGNACION');
select is(public.estado_de_cuenta(null, null), 'PENDIENTE_ASIGNACION', 'null como sin campaña');

-- ---------------------------------------------------------------------------
-- 2. RLS: el coordinador lee solo su fila de usuario
-- ---------------------------------------------------------------------------
select policies_are('public', 'usuario', array['usuario_select_propio_o_admin', 'usuario_update_propio'],
  'usuario_select_propio_o_staff ya no existe; la lectura es propio o ADMIN');

select pg_temp.actuar_como(pg_temp.u('a1'));
select results_eq($$ select id from public.usuario $$, $$ values (pg_temp.u('a1')) $$,
  'el coordinador ve solo su fila de usuario');
select is((select nombre || '|' || email from public.usuario where id = pg_temp.u('a1')), '|coord1@buscar18.test',
  'el coordinador lee su perfil (GET /v1/me)');
select is_empty($$ select 1 from public.usuario where id = pg_temp.u('b6') $$,
  'el coordinador NO lee directo a un colportor de su campaña');
select is_empty($$ select 1 from public.usuario where id = pg_temp.u('b1') $$,
  'el coordinador NO lee directo a un candidato');
select is_empty(
  $$ select u.email from public.campania_colportor cc join public.usuario u on u.id = cc.usuario_id
      where cc.campania_id = pg_temp.u('e1') $$,
  'ni por un join desde campania_colportor (el embed de PostgREST)');
select lives_ok($$ update public.usuario set nombre = 'Pirata' where id = pg_temp.u('b1') $$,
  'un UPDATE de una cuenta ajena no falla, pero no la ve (se comprueba como ADMIN)');

select pg_temp.actuar_como(pg_temp.u('a0'));
select results_eq($$ select id from public.usuario $$, $$ values (pg_temp.u('a0')) $$,
  'el colportor ve solo su fila');

select pg_temp.actuar_como(pg_temp.u('ad'));
select is((select count(*)::int from public.usuario where id::text like '01920000-0000-7000-8000-0000000018%'), 20,
  'el ADMIN lee todas las cuentas');
select is((select nombre from public.usuario where id = pg_temp.u('b1')), 'Ana',
  'el UPDATE del coordinador sobre una cuenta ajena no cambió nada');
select pg_temp.actuar_como_servidor();

-- ---------------------------------------------------------------------------
-- 3. buscar_candidatos: acceso (el permiso primero) y errores de campaña
-- ---------------------------------------------------------------------------
select throws_ok($$ select * from public.buscar_candidatos(pg_temp.u('e1'), 'ana') $$,
  '42501', null, 'sin JWT, buscar_candidatos() falla');

select set_config('role', 'anon', true);
select throws_ok($$ select * from public.buscar_candidatos('01920000-0000-7000-8000-0000000018e1', 'ana') $$,
  '42501', null, 'anon no busca');
select set_config('role', 'postgres', true);

select pg_temp.actuar_como(pg_temp.u('a0'));
select throws_ok($$ select * from public.buscar_candidatos(pg_temp.u('e1'), 'ana') $$,
  '42501', 'Solo el coordinador de la campaña puede buscar cuentas para inscribir en ella.',
  'un colportor no busca');

select pg_temp.actuar_como(pg_temp.u('a2'));
select throws_ok($$ select * from public.buscar_candidatos(pg_temp.u('e1'), 'ana') $$,
  '42501', null, 'el coordinador de otra campaña no busca con esa campaña');
select throws_ok($$ select * from public.buscar_candidatos(pg_temp.u('e1')) $$,
  '42501', null, 'ni pide sus sugeridos');

select pg_temp.actuar_como(pg_temp.u('a1'));
select throws_ok($$ select * from public.buscar_candidatos('01920000-0000-7000-8000-0000000018ff', 'ana') $$,
  'CI001', 'La campaña no existe.', 'campaña inexistente: CI001 (como inscribir)');
select throws_ok($$ select * from public.buscar_candidatos(pg_temp.u('e5'), 'ana') $$,
  'CI001', null, 'campaña borrada: CI001');
select throws_ok($$ select * from public.buscar_candidatos(pg_temp.u('e4'), 'ana') $$,
  'CI002', null, 'campaña terminada: CI002');
select throws_ok($$ select * from public.buscar_candidatos(pg_temp.u('e3'), 'ana') $$,
  'CI002', null, 'campaña futura: CI002');

-- ---------------------------------------------------------------------------
-- 4. Sugeridos: sin texto, las 5 pendientes más nuevas
-- ---------------------------------------------------------------------------
select results_eq(
  $$ select usuario_id, estado, campania_actual, motivo_bloqueo from public.buscar_candidatos(pg_temp.u('e1')) $$,
  $$ values (pg_temp.u('b1'), 'PENDIENTE_ASIGNACION'::text, null::text, null::text),
            (pg_temp.u('b2'), 'PENDIENTE_ASIGNACION', null, null),
            (pg_temp.u('b5'), 'PENDIENTE_ASIGNACION', null, null),
            (pg_temp.u('ba'), 'PENDIENTE_ASIGNACION', null, 'INSCRIPCION_BORRADA'),
            (pg_temp.u('be'), 'PENDIENTE_ASIGNACION', null, null) $$,
  'sugeridos: hasta 5 pendientes, más nuevas primero (empate por id desc: be antes que bd); '
  'sin suspendidas, en otra campaña, ya en el equipo, sin verificar ni dadas de baja aunque sean más nuevas; '
  'una inscripción futura, terminada o borrada no las saca de pendientes'
);
select results_eq($$ select usuario_id from public.buscar_candidatos(pg_temp.u('e1'), null) $$,
                  $$ select usuario_id from public.buscar_candidatos(pg_temp.u('e1')) $$,
                  'texto null = sugeridos');
select results_eq($$ select usuario_id from public.buscar_candidatos(pg_temp.u('e1'), '   ') $$,
                  $$ select usuario_id from public.buscar_candidatos(pg_temp.u('e1'), '') $$,
                  'solo espacios = vacío = sugeridos');
select is((select count(*)::int from public.buscar_candidatos(pg_temp.u('e1'), '')), 5, 'vacío: 5 sugeridos');
select is((select nombre || ' ' || apellido || ' · ' || email from public.buscar_candidatos(pg_temp.u('e1')) limit 1),
          'Ana Martínez · ana.martinez@correo.uy', 'devuelve nombre, apellido y email');
select is((select creada_en::date from public.buscar_candidatos(pg_temp.u('e1')) limit 1),
          (now() + interval '10 days')::date, 'creada_en es la fecha de creación de la cuenta');

-- ---------------------------------------------------------------------------
-- 5. Búsqueda con texto
-- ---------------------------------------------------------------------------
select results_eq(
  $$ select usuario_id, estado, motivo_bloqueo from public.buscar_candidatos(pg_temp.u('e1'), 'ana') $$,
  $$ values (pg_temp.u('b1'), 'PENDIENTE_ASIGNACION'::text, null::text),
            (pg_temp.u('b2'), 'PENDIENTE_ASIGNACION', null),
            (pg_temp.u('b0'), 'PENDIENTE_ASIGNACION', null),
            (pg_temp.u('b3'), 'SUSPENDIDA', 'USUARIO_SUSPENDIDO') $$,
  '«ana»: primero las que empiezan con el texto (Ana, Anabel), después las que lo contienen '
  '(Adriana antes que Mariana), alfabético; la suspendida aparece con su motivo'
);
select results_eq(
  $$ select usuario_id, estado, campania_actual, motivo_bloqueo from public.buscar_candidatos(pg_temp.u('e1'), 'rodrigo') $$,
  $$ values (pg_temp.u('b5'), 'PENDIENTE_ASIGNACION'::text, null::text, null::text),
            (pg_temp.u('b4'), 'ACTIVA', 'Otoño Norte', 'EN_OTRA_CAMPANIA') $$,
  '«rodrigo»: la que está en otra campaña aparece con su campaña («Está en campaña Otoño Norte») y su motivo'
);
select results_eq(
  $$ select usuario_id, estado, campania_actual, motivo_bloqueo from public.buscar_candidatos(pg_temp.u('e1'), 'ferreira') $$,
  $$ values (pg_temp.u('bb'), 'SUSPENDIDA'::text, 'Otoño Norte'::text, 'USUARIO_SUSPENDIDO'::text) $$,
  'suspendida y en otra campaña: estado SUSPENDIDA, su campaña igual, y el motivo que inscribir diría primero'
);
select results_eq($$ select usuario_id from public.buscar_candidatos(pg_temp.u('e1'), '  ANA   MARTÍNEZ ') $$,
                  $$ values (pg_temp.u('b1')) $$,
                  'sin mayúsculas, tildes ni espacios de más; busca en el nombre completo');
select results_eq($$ select usuario_id from public.buscar_candidatos(pg_temp.u('e1'), 'luz') $$,
                  $$ values (pg_temp.u('b0')), (pg_temp.u('a0')) $$,
                  'una cuenta sin nombre que solo lo contiene en el email no pasa adelante de Adriana Luz');
select results_eq($$ select usuario_id from public.buscar_candidatos(pg_temp.u('e1'), 'nunez') $$,
                  $$ values (pg_temp.u('bd')) $$, '«nunez» encuentra a Núñez');
select results_eq($$ select usuario_id from public.buscar_candidatos(pg_temp.u('e1'), 'Suárez') $$,
                  $$ values (pg_temp.u('bc')) $$, 'con tilde en el texto también');
select results_eq($$ select usuario_id from public.buscar_candidatos(pg_temp.u('e1'), U&'MARTI\0301NEZ') $$,
                  $$ values (pg_temp.u('b1')) $$, 'el texto con la tilde combinada (NFD) encuentra a Martínez');
select results_eq($$ select usuario_id from public.buscar_candidatos(pg_temp.u('e1'), 'sofía') $$,
                  $$ values (pg_temp.u('bf')) $$, 'y un nombre guardado en NFD se encuentra con «sofía» y con…');
select results_eq($$ select usuario_id from public.buscar_candidatos(pg_temp.u('e1'), 'sofia') $$,
                  $$ values (pg_temp.u('bf')) $$, '…«sofia»');
select results_eq($$ select usuario_id from public.buscar_candidatos(pg_temp.u('e1'), 'RBARRIOS@') $$,
                  $$ values (pg_temp.u('b5')) $$, 'por email, sin mayúsculas');
select is_empty($$ select * from public.buscar_candidatos(pg_temp.u('e1'), '%') $$,
                '«%» es literal, no comodín');
select is_empty($$ select * from public.buscar_candidatos(pg_temp.u('e1'), 'r_barrios') $$,
                '«_» es literal, no comodín');
select is_empty($$ select * from public.buscar_candidatos(pg_temp.u('e1'), 'zzzz') $$,
                'sin coincidencias: vacío, no error («No hay cuentas que coincidan con tu búsqueda.»)');

-- Lo que NO aparece.
select is_empty($$ select * from public.buscar_candidatos(pg_temp.u('e1'), 'rocha') $$,
                'quien ya está en el equipo no es candidato (lo muestra colportores_de_campania)');
select is_empty($$ select * from public.buscar_candidatos(pg_temp.u('e1'), 'cabrera') $$,
                'tampoco si está suspendido');
select is_empty($$ select * from public.buscar_candidatos(pg_temp.u('e1'), 'sosa') $$,
                'una cuenta con el email sin verificar no aparece');
select is_empty($$ select * from public.buscar_candidatos(pg_temp.u('e1'), 'bentancor') $$,
                'una cuenta dada de baja no aparece');
select results_eq(
  $$ select usuario_id, motivo_bloqueo from public.buscar_candidatos(pg_temp.u('e1'), 'acosta') $$,
  $$ values (pg_temp.u('ba'), 'INSCRIPCION_BORRADA'::text) $$,
  'con una inscripción dada de baja en esta campaña aparece, con su motivo'
);

-- Pocas cuentas: hasta 10.
select results_eq(
  $$ select usuario_id from public.buscar_candidatos(pg_temp.u('e1'), '@correo.uy') $$,
  $$ values (pg_temp.u('b0')), (pg_temp.u('b1')), (pg_temp.u('b2')), (pg_temp.u('bd')), (pg_temp.u('bc')),
            (pg_temp.u('b3')), (pg_temp.u('be')), (pg_temp.u('ba')), (pg_temp.u('bb')), (pg_temp.u('b5')) $$,
  '12 coincidencias: la primera página trae las 10 primeras por nombre completo'
);
select results_eq(
  $$ select usuario_id from public.buscar_candidatos(pg_temp.u('e1'), '@correo.uy', pg_temp.u('b5')) $$,
  $$ values (pg_temp.u('b4')), (pg_temp.u('bf')) $$,
  'la página siguiente (después de b5) trae las 2 que faltan');
select is_empty($$ select * from public.buscar_candidatos(pg_temp.u('e1'), '@correo.uy', pg_temp.u('bf')) $$,
                'y después de la última, nada');

-- El ADMIN busca con cualquier campaña; los candidatos dependen de ESA campaña.
select pg_temp.actuar_como(pg_temp.u('ad'));
select results_eq(
  $$ select usuario_id, estado, campania_actual, motivo_bloqueo from public.buscar_candidatos(pg_temp.u('e2'), 'rocha') $$,
  $$ values (pg_temp.u('b6'), 'ACTIVA'::text, 'Verano 2026'::text, 'EN_OTRA_CAMPANIA'::text) $$,
  'para Otoño Norte, alguien de Verano es candidato bloqueado por estar en otra campaña'
);
select is_empty($$ select * from public.buscar_candidatos(pg_temp.u('e2'), 'rodrigo silva') $$,
                'y quien ya está en Otoño Norte no es candidato de Otoño Norte');

-- ---------------------------------------------------------------------------
-- 5b. Orden y paginación (decisión del 02/10): primero las que empiezan con el texto (nombre,
--     apellido o email), después el resto, alfabético; de a 10, con cursor.
--     22 cuentas con «pag»: c0 (email pag…, Bruno Méndez), c1..cc (Paginada A01..A12), cd (Zoe
--     Pagano, por el apellido) empiezan; d0..d7 (Eva Sinpag01..08) solo lo contienen. Nombres
--     que no cruzan con las búsquedas de las secciones siguientes.
-- ---------------------------------------------------------------------------
select pg_temp.actuar_como_servidor();
insert into auth.users (id, instance_id, aud, role, email, encrypted_password, confirmed_at,
                        raw_user_meta_data, created_at, updated_at)
select pg_temp.u(x.s), '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
       x.email, 'x', now(), jsonb_build_object('nombre', x.n, 'apellido', x.a), now(), now()
  from (
    select 'c0' as s, 'pag.bruno@buscar18.test' as email, 'Bruno' as n, 'Méndez' as a
    union all
    select 'c' || to_hex(i), 'p18-' || i || '@buscar18.test', 'Paginada', 'A' || lpad(i::text, 2, '0')
      from generate_series(1, 12) i
    union all
    select 'cd', 'zoe18@buscar18.test', 'Zoe', 'Pagano'
    union all
    select 'd' || i, 's18-' || i || '@buscar18.test', 'Eva', 'Sinpag' || lpad((i + 1)::text, 2, '0')
      from generate_series(0, 7) i
  ) x;

create temp table pag_esperado on commit drop as
select row_number() over () as n, x.s
  from unnest(array['c0','c1','c2','c3','c4','c5','c6','c7','c8','c9','ca','cb','cc','cd',
                    'd0','d1','d2','d3','d4','d5','d6','d7']) x(s);
grant select on pag_esperado to authenticated;

select pg_temp.actuar_como(pg_temp.u('a1'));
create temp table pag_1 on commit drop as
select row_number() over () as n, c.usuario_id from public.buscar_candidatos(pg_temp.u('e1'), 'pag') c;
create temp table pag_2 on commit drop as
select row_number() over () as n, c.usuario_id
  from public.buscar_candidatos(pg_temp.u('e1'), 'pag', (select usuario_id from pag_1 where n = 10)) c;
create temp table pag_3 on commit drop as
select row_number() over () as n, c.usuario_id
  from public.buscar_candidatos(pg_temp.u('e1'), 'pag', (select usuario_id from pag_2 where n = 10)) c;

select is((select count(*) from pag_1), 10::bigint, 'página 1: 10 cuentas');
select is((select count(*) from pag_2), 10::bigint, 'página 2: 10 cuentas');
select is((select count(*) from pag_3), 2::bigint, 'página 3: las 2 que quedan (menos de 10: es la última)');
select is_empty($$ select * from public.buscar_candidatos(pg_temp.u('e1'), 'pag', (select usuario_id from pag_3 where n = 2)) $$,
                'después de la última, nada');
select results_eq(
  $$ select usuario_id from (select n, usuario_id from pag_1
                             union all select 10 + n, usuario_id from pag_2
                             union all select 20 + n, usuario_id from pag_3) t order by n $$,
  $$ select pg_temp.u(s) from pag_esperado order by n $$,
  'las tres páginas seguidas: primero las que empiezan (email, nombre o apellido), después las que lo contienen; alfabético en cada grupo, sin duplicados ni huecos');
select results_eq(
  $$ select usuario_id from pag_1 order by n limit 2 $$,
  $$ values (pg_temp.u('c0')), (pg_temp.u('c1')) $$,
  'la que empieza por el email (Bruno Méndez) va primero: dentro del grupo es alfabético por nombre');
select is((select usuario_id from pag_2 where n = 4), pg_temp.u('cd'),
          'Zoe Pagano (empieza por el apellido) va antes que las que solo contienen el texto');

-- Estable aunque la lista cambie entre páginas: si una cuenta de la página 1 deja de ser
-- candidata, la página 2 pedida con el mismo cursor es la misma (con offset, una quedaría sin
-- mostrarse). Se da de baja la cuenta para no tocar el equipo de Verano (sección 7).
select pg_temp.actuar_como_servidor();
update public.usuario set deleted_at = now() where id = pg_temp.u('c3');
select pg_temp.actuar_como(pg_temp.u('a1'));
select is((select count(*) from public.buscar_candidatos(pg_temp.u('e1'), 'pag') where usuario_id = pg_temp.u('c3')),
          0::bigint, 'mientras tanto, c3 (de la página 1) deja de ser candidata');
select results_eq(
  $$ select usuario_id from public.buscar_candidatos(pg_temp.u('e1'), 'pag', (select usuario_id from pag_1 where n = 10)) $$,
  $$ select usuario_id from pag_2 order by n $$,
  'la página 2 no cambia: ni duplicados ni huecos');
-- Y si se da de alta una cuenta que va antes del cursor, no aparece en las páginas siguientes.
select pg_temp.actuar_como_servidor();
insert into auth.users (id, instance_id, aud, role, email, encrypted_password, confirmed_at,
                        raw_user_meta_data, created_at, updated_at)
values (pg_temp.u('d8'), '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
        'pag.aaron@buscar18.test', 'x', now(), '{"nombre": "Aarón", "apellido": "Paz"}', now(), now());
select pg_temp.actuar_como(pg_temp.u('a1'));
select results_eq(
  $$ select usuario_id from public.buscar_candidatos(pg_temp.u('e1'), 'pag', (select usuario_id from pag_2 where n = 10)) $$,
  $$ select usuario_id from pag_3 order by n $$,
  'una cuenta nueva que va antes del cursor no se mete en la página 3');
select is((select usuario_id from public.buscar_candidatos(pg_temp.u('e1'), 'pag') limit 1), pg_temp.u('d8'),
          'y aparece al volver a buscar desde el principio');

-- Sin texto, los sugeridos son una sola página.
select is_empty($$ select * from public.buscar_candidatos(pg_temp.u('e1'), null, pg_temp.u('b1')) $$,
                'sin texto, con cursor no devuelve nada (los sugeridos son una página)');
select throws_ok($$ select * from public.buscar_candidatos(pg_temp.u('e1'), 'pag', '01920000-0000-7000-8000-0000000018fe') $$,
  '22023', 'No se encontró la última cuenta de la página anterior. Volvé a buscar desde el principio.',
  'un cursor que no es ninguna cuenta → 22023, con qué hacer');

-- ---------------------------------------------------------------------------
-- 6. motivo_bloqueo es lo que inscribir_colportor() hace
-- ---------------------------------------------------------------------------
select pg_temp.actuar_como(pg_temp.u('a1'));
select throws_ok($$ select public.inscribir_colportor(pg_temp.u('e1'), pg_temp.u('b4')) $$,
  'CI007', 'Está en campaña Otoño Norte. Reasignar primero.', 'EN_OTRA_CAMPANIA → CI007');
select throws_ok($$ select public.inscribir_colportor(pg_temp.u('e1'), pg_temp.u('b3')) $$,
  'CI005', null, 'USUARIO_SUSPENDIDO → CI005');
select throws_ok($$ select public.inscribir_colportor(pg_temp.u('e1'), pg_temp.u('bb')) $$,
  'CI005', null, 'suspendido y en otra campaña → CI005, como dice el motivo');
select throws_ok($$ select public.inscribir_colportor(pg_temp.u('e1'), pg_temp.u('ba')) $$,
  'CI008', null, 'INSCRIPCION_BORRADA → CI008');
select lives_ok($$ select public.inscribir_colportor(pg_temp.u('e1'), c.usuario_id)
                     from public.buscar_candidatos(pg_temp.u('e1'), 'ana') c
                    where c.motivo_bloqueo is null $$,
  'toda cuenta sin motivo se puede inscribir');
select results_eq($$ select usuario_id from public.buscar_candidatos(pg_temp.u('e1'), 'ana') $$,
                  $$ values (pg_temp.u('b3')) $$,
                  'las inscriptas dejan de ser candidatas; queda la suspendida');
select results_eq(
  $$ select usuario_id from public.buscar_candidatos(pg_temp.u('e1')) $$,
  $$ values (pg_temp.u('b5')), (pg_temp.u('ba')), (pg_temp.u('be')), (pg_temp.u('bd')), (pg_temp.u('bc')) $$,
  'los sugeridos se corren: ya no están las inscriptas'
);

-- ---------------------------------------------------------------------------
-- 7. colportores_de_campania: nombre, email y estado
-- ---------------------------------------------------------------------------
select results_eq(
  $$ select usuario_id, nombre, apellido, email, estado, suspendido
       from public.colportores_de_campania(pg_temp.u('e1')) $$,
  $$ values (pg_temp.u('b7'), 'Joel'::text, 'Cabrera'::text, 'jcabrera@equipo18.test'::text, 'SUSPENDIDA'::text, true),
            (pg_temp.u('b0'), 'Adriana', 'Luz', 'aluz@correo.uy', 'ACTIVA', false),
            (pg_temp.u('b1'), 'Ana', 'Martínez', 'ana.martinez@correo.uy', 'ACTIVA', false),
            (pg_temp.u('b2'), 'Anabel', 'Pereira', 'anabel.p@correo.uy', 'ACTIVA', false),
            (pg_temp.u('b6'), 'Diego', 'Rocha', 'drocha@equipo18.test', 'ACTIVA', false) $$,
  'el coordinador ve a los de su campaña con email y estado (la suspendida marcada), por apellido'
);
select pg_temp.actuar_como(pg_temp.u('a2'));
select throws_ok($$ select * from public.colportores_de_campania(pg_temp.u('e1')) $$,
  '42501', null, 'el coordinador de otra campaña sigue sin listar ese equipo');
select pg_temp.actuar_como_servidor();

select * from finish();
rollback;
