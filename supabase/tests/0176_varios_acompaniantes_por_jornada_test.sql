-- pgTAP · migración 0176 (backend-supabase#254, casillas «Dos acomp.» y «Valida acomp»): varios acompañantes por jornada.
--   1. La forma: la tabla jornada_acompaniante (RLS, tres políticas, sin DELETE, sin anon), el único vigente por
--      (jornada, persona), la entidad de sync (push, con la dueña en colportor_id) y las columnas que el teléfono no escribe.
--   2. El push: el teléfono sube cada acompañante como una fila. El servidor pone el dueño (de la jornada) y no deja elegir
--      quién cargó. NO controla al acompañante: cualquier cuenta existente (un colportor de otra campaña, un coordinador, un
--      administrador) entra; una cuenta que no existe se rechaza. Una persona repetida o la jornada de otro se rechazan.
--   3. La columna jornada.acompaniante_id sigue siendo «el primer acompañante vigente» sin subir la versión de la jornada
--      (el push de la jornada que el teléfono tenga pendiente no da conflicto), y las horas acompañadas cuentan una vez.
--   4. El teléfono de antes: sube jornada.acompaniante_id y queda anotado en la tabla; si lo cambia, el de antes se da de baja.
--   5. La baja de un acompañante recalcula la columna y se lleva su origen y su nota.
--   6. Lo que ve cada uno: solo las filas de sus jornadas.
--   7. El teléfono sube la jornada entera: su columna vieja no da de baja ni revive a nadie (revisión de #255).

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
create or replace function pg_temp.u(p text) returns uuid language sql as $$
  select ('01920000-0000-7000-8000-0000000176' || p)::uuid;
$$;
create or replace function pg_temp.sobre() returns jsonb language sql as $$
  select jsonb_build_object('device_id', '01920000-0000-7000-8000-0000000176d0',
                            'app_version', '1.4.2', 'schema_version', 1);
$$;
create or replace function pg_temp.push(p_jobs jsonb) returns jsonb language sql as $$
  select public.sync_push(jsonb_build_object('device', pg_temp.sobre(), 'jobs', p_jobs));
$$;
-- Un job de insert de un acompañante: (id de la fila, jornada, persona) más campos extra del payload.
create or replace function pg_temp.job_acomp(p_op text, p_jornada text, p_persona uuid, p_extra jsonb default '{}'::jsonb)
returns jsonb language sql as $$
  select jsonb_build_object('client_op_id', pg_temp.u(p_op), 'entity', 'jornada_acompaniante', 'op', 'insert',
                            'sync_version', null,
                            'payload', jsonb_build_object('id', pg_temp.u(p_op), 'jornada_id', pg_temp.u(p_jornada),
                                                          'acompaniante_id', p_persona) || p_extra);
$$;
-- «resultado/código» del job i de la respuesta.
create or replace function pg_temp.res(p_r jsonb, p_i integer default 0) returns text language sql as $$
  select (p_r -> 'results' -> p_i ->> 'outcome') || '/' || coalesce(p_r -> 'results' -> p_i ->> 'code', '-');
$$;
create or replace function pg_temp.error_de(p_sql text) returns text language plpgsql as $$
begin
  execute p_sql;
  return 'ok';
exception when others then
  return sqlstate;
end $$;
-- Lo guardado de una jornada: acompañante de la columna | quién cargó.
create or replace function pg_temp.columna(p_jor text) returns text language sql security definer as $$
  select coalesce(right(j.acompaniante_id::text, 2), 'null') || '|' || coalesce(right(j.acompaniamiento_cargado_por::text, 2), 'null')
    from public.jornada j where j.id = pg_temp.u(p_jor)
$$;
-- Los acompañantes vigentes de una jornada, por antigüedad: sufijos separados por coma.
create or replace function pg_temp.vigentes(p_jor text) returns text language sql security definer as $$
  select coalesce(string_agg(right(a.acompaniante_id::text, 2), ',' order by a.created_at, a.id), '(ninguno)')
    from public.jornada_acompaniante a where a.jornada_id = pg_temp.u(p_jor) and a.deleted_at is null
$$;
-- El origen y la nota de la tabla interna de una jornada, por acompañante: «persona=origen/nota».
create or replace function pg_temp.detalle(p_jor text) returns text language sql security definer as $$
  select coalesce(string_agg(right(d.acompaniante_id::text, 2) || '=' || d.origen || '/' || coalesce(d.nota, '-'), ',' order by d.acompaniante_id), '(sin filas)')
    from public.jornada_acompaniamiento d where d.jornada_id = pg_temp.u(p_jor) and d.deleted_at is null
$$;

-- --- fixtures (como postgres) --------------------------------------------------
-- Colportores de la campaña e1 (de a1): b1 (dueña de las jornadas), b2, b3. e2 es de otro coordinador (c2) y tiene a bx.
-- ad es administrador. Jornadas: j1 y j2 de b1 (cerradas), j3 de b2.
insert into auth.users (id, instance_id, aud, role, email, encrypted_password, confirmed_at, created_at, updated_at)
select pg_temp.u(s), '00000000-0000-0000-0000-000000000000',
       'authenticated', 'authenticated', 't0176-' || s || '@example.com', 'x', now(), now(), now()
  from unnest(array['a1','c2','ad','b1','b2','b3','be']) s;
insert into public.usuario_rol (usuario_id, rol_id)
select pg_temp.u(x.s), r.id
  from (values ('a1','COORDINADOR'), ('c2','COORDINADOR'), ('ad','ADMIN'),
               ('b1','COLPORTOR'), ('b2','COLPORTOR'), ('b3','COLPORTOR'), ('be','COLPORTOR')) x(s, codigo)
  join public.rol r on r.codigo = x.codigo;
insert into public.campania (id, nombre, tipo, fecha_inicio, fecha_fin, coordinador_id) values
  (pg_temp.u('e1'), 'e1 t0176', 'VERANO', public.hoy_montevideo() - 30, null, pg_temp.u('a1')),
  (pg_temp.u('e2'), 'e2 t0176', 'VERANO', public.hoy_montevideo() - 30, null, pg_temp.u('c2'));
insert into public.campania_colportor (campania_id, usuario_id, created_at) values
  (pg_temp.u('e1'), pg_temp.u('b1'), now() - interval '100 days'),
  (pg_temp.u('e1'), pg_temp.u('b2'), now() - interval '100 days'),
  (pg_temp.u('e1'), pg_temp.u('b3'), now() - interval '100 days'),
  (pg_temp.u('e2'), pg_temp.u('be'), now() - interval '100 days');
insert into public.jornada (id, colportor_id, inicio, fin)
select pg_temp.u(x.id), pg_temp.u(x.colp),
       (public.hoy_montevideo() - x.dias + time '09:00') at time zone 'America/Montevideo',
       (public.hoy_montevideo() - x.dias + time '09:00') at time zone 'America/Montevideo' + interval '2 hours'
  from (values ('a1', 'b1', 5), ('a2', 'b1', 4), ('a3', 'b2', 3)) x(id, colp, dias);

create temp table antes on commit drop as select id, sync_version, xmin_w from public.jornada;
grant select on pg_temp.antes to authenticated;

-- ---------------------------------------------------------------------------
-- 1. La forma
-- ---------------------------------------------------------------------------
select has_table('public', 'jornada_acompaniante', 'existe jornada_acompaniante');
select is((select relrowsecurity from pg_class where oid = 'public.jornada_acompaniante'::regclass), true, 'con RLS');
select is((select count(*)::int from pg_policies where tablename = 'jornada_acompaniante'), 3, 'tres políticas: select, insert, update');
select is(has_table_privilege('authenticated', 'public.jornada_acompaniante', 'delete'), false, 'sin DELETE');
select is(has_table_privilege('anon', 'public.jornada_acompaniante', 'select'), false, 'anon no lee');
select is((select permite_push from sync.entidad where nombre = 'jornada_acompaniante'), true, 'es una entidad de push');
select is((select columna_duenio from sync.entidad where nombre = 'jornada_acompaniante'), 'colportor_id', 'con la dueña en colportor_id');
select ok(not ('colportor_id' = any (sync.columnas_escribibles('jornada_acompaniante'))), 'el teléfono no escribe colportor_id');
select ok(not ('cargado_por' = any (sync.columnas_escribibles('jornada_acompaniante'))), 'ni cargado_por');
select ok('jornada_id' = any (sync.columnas_escribibles('jornada_acompaniante')), 'jornada_id sí');
select ok('acompaniante_id' = any (sync.columnas_escribibles('jornada_acompaniante')), 'y acompaniante_id');
select has_index('public', 'jornada_acompaniante', 'jornada_acompaniante_vigente_uidx', 'hay un único vigente por jornada y persona');
select has_index('public', 'jornada_acompaniante', 'jornada_acompaniante_delta_idx', array['colportor_id', 'xmin_w', 'id'],
                 'y el índice del delta, con la dueña primero');
select is(has_function_privilege('authenticated', 'public.refrescar_acompaniante_de_la_jornada(uuid, boolean)', 'execute'), false,
          'la función interna no la llama nadie con JWT');
select is(has_function_privilege('authenticated', 'public.tg_jornada_acompaniante_detalle_y_espejo()', 'execute'), false,
          'ni el trigger');
select is((select count(*) from public.jornada_acompaniante), 0::bigint, 'sin acompañantes previos en la fixture');

-- ---------------------------------------------------------------------------
-- 2. El push de la dueña
-- ---------------------------------------------------------------------------
select pg_temp.actuar_como(pg_temp.u('b1'));
create temp table r1 as
  select pg_temp.push(jsonb_build_array(pg_temp.job_acomp('01', 'a1', pg_temp.u('b2')))) as r;
grant select on r1 to authenticated;
select is((select pg_temp.res(r) from r1), 'accepted/-', 'b1 sube a b2 como acompañante de su jornada a1');
select pg_temp.actuar_como_servidor();
select is(pg_temp.vigentes('a1'), 'b2', 'queda un acompañante vigente');
select is((select colportor_id from public.jornada_acompaniante where id = pg_temp.u('01')), pg_temp.u('b1'), 'el servidor puso a la dueña de la jornada');
select is(pg_temp.columna('a1'), 'b2|null', 'la columna de la jornada es b2 y nadie lo cargó desde el panel');
select is((select j.sync_version - a.sync_version from public.jornada j join antes a using (id) where j.id = pg_temp.u('a1')), 0::bigint,
          'y la versión de la jornada no subió (el push de la jornada que el teléfono tenga pendiente no da conflicto)');
select is(pg_temp.detalle('a1'), 'b2=COLPORTOR/-', 'el origen y la nota internos: COLPORTOR y sin nota');

-- Un segundo y un tercer acompañante: el servidor no controla a quién.
select pg_temp.actuar_como(pg_temp.u('b1'));
create temp table r2 as
  select pg_temp.push(jsonb_build_array(
    pg_temp.job_acomp('02', 'a1', pg_temp.u('c2')),      -- un coordinador de otra campaña
    pg_temp.job_acomp('03', 'a1', pg_temp.u('be')),      -- un colportor de otra campaña
    pg_temp.job_acomp('04', 'a1', pg_temp.u('ad')))) as r; -- un administrador
grant select on r2 to authenticated;
select is((select array[pg_temp.res(r, 0), pg_temp.res(r, 1), pg_temp.res(r, 2)] from r2),
          array['accepted/-', 'accepted/-', 'accepted/-'],
          'un coordinador de otra campaña, un colportor de otra campaña y un administrador entran (JO005 no aplica al push)');
select pg_temp.actuar_como_servidor();
select is(pg_temp.vigentes('a1'), 'b2,c2,be,ad', 'la jornada queda con cuatro acompañantes, por orden de alta');
select is(pg_temp.columna('a1'), 'b2|null', 'la columna sigue en el primero');
select is(pg_temp.detalle('a1'), 'ad=COLPORTOR/-,b2=COLPORTOR/-,be=COLPORTOR/-,c2=COLPORTOR/-', 'y cada uno tiene su origen');
select is((select count(*) from public.jornadas_acompaniadas_de_campania(pg_temp.u('e1')) where jornada_id = pg_temp.u('a1')), 1::bigint,
          'una jornada acompañada cuenta una sola vez aunque tenga cuatro acompañantes');
select is((select j.sync_version - a.sync_version from public.jornada j join antes a using (id) where j.id = pg_temp.u('a1')), 0::bigint,
          'y la versión de la jornada no se movió');

-- El teléfono no elige la dueña ni quién cargó.
select pg_temp.actuar_como(pg_temp.u('b1'));
create temp table r3 as
  select pg_temp.push(jsonb_build_array(
    pg_temp.job_acomp('05', 'a2', pg_temp.u('b3'),
      jsonb_build_object('colportor_id', pg_temp.u('b2'), 'cargado_por', pg_temp.u('a1'))))) as r;
grant select on r3 to authenticated;
select is((select pg_temp.res(r) from r3), 'accepted/-', 'subir colportor_id y cargado_por no rompe: el servidor los descarta');
select pg_temp.actuar_como_servidor();
select is((select colportor_id from public.jornada_acompaniante where id = pg_temp.u('05')), pg_temp.u('b1'), 'la dueña sigue siendo la de la jornada');
select is((select cargado_por from public.jornada_acompaniante where id = pg_temp.u('05')), null, 'y nadie figura como quien lo cargó desde el panel');
select is(pg_temp.columna('a2'), 'b3|null', 'la columna de la jornada a2 es b3');

-- Lo que se rechaza.
select pg_temp.actuar_como(pg_temp.u('b1'));
create temp table r4 as
  select pg_temp.push(jsonb_build_array(
    pg_temp.job_acomp('06', 'a1', pg_temp.u('b2')),                       -- la misma persona otra vez
    pg_temp.job_acomp('07', 'a1', '01920000-0000-7000-8000-000000000999'), -- una cuenta que no existe
    pg_temp.job_acomp('08', 'a3', pg_temp.u('b3')),                       -- la jornada de otra persona
    pg_temp.job_acomp('09', 'f0', pg_temp.u('b3')))) as r;                 -- una jornada que no existe
grant select on r4 to authenticated;
select is((select left(pg_temp.res(r, 0), 7) from r4), 'invalid', 'la misma persona vigente otra vez se rechaza (único)');
select is((select left(pg_temp.res(r, 1), 7) from r4), 'invalid', 'una cuenta que no existe se rechaza');
select is((select left(pg_temp.res(r, 2), 7) from r4), 'invalid', 'la jornada de otra persona se rechaza (RLS)');
select is((select left(pg_temp.res(r, 3), 7) from r4), 'invalid', 'y una jornada que no existe, también');
select pg_temp.actuar_como_servidor();
select is(pg_temp.vigentes('a1'), 'b2,c2,be,ad', 'nada de eso cambió la jornada a1');
select is(pg_temp.vigentes('a3'), '(ninguno)', 'ni la jornada de b2');
select is((select count(*) from public.jornada_acompaniante where id in (pg_temp.u('06'), pg_temp.u('07'), pg_temp.u('08'), pg_temp.u('09'))),
          0::bigint, 'ninguna de las rechazadas dejó una fila');

-- b2 no puede anotar acompañantes en la jornada de b1 (ni leerlos).
select pg_temp.actuar_como(pg_temp.u('b2'));
select is(pg_temp.error_de(format($$insert into public.jornada_acompaniante (jornada_id, acompaniante_id) values (%L, %L)$$,
                                  pg_temp.u('a2'), pg_temp.u('b3'))), '42501', 'b2 no inserta en una jornada de b1 (RLS)');
select is((select count(*) from public.jornada_acompaniante), 0::bigint, 'y b2 no lee las filas de b1');
select is(pg_temp.error_de(format($$update public.jornada_acompaniante set deleted_at = now() where id = %L$$, pg_temp.u('01'))), 'ok',
          'el update de una fila ajena no falla pero no toca nada (RLS lo filtra)');
select pg_temp.actuar_como_servidor();
select is(pg_temp.vigentes('a1'), 'b2,c2,be,ad', 'y la fila ajena sigue vigente');

-- ---------------------------------------------------------------------------
-- 3. Lo que no se cambia en una fila
-- ---------------------------------------------------------------------------
select pg_temp.actuar_como(pg_temp.u('b1'));
select is(pg_temp.error_de(format($$update public.jornada_acompaniante set acompaniante_id = %L where id = %L$$, pg_temp.u('b3'), pg_temp.u('01'))),
          '23514', 'a una fila no se le cambia la persona');
select is(pg_temp.error_de(format($$update public.jornada_acompaniante set jornada_id = %L where id = %L$$, pg_temp.u('a2'), pg_temp.u('01'))),
          '23514', 'ni la jornada');
select pg_temp.actuar_como_servidor();
select is(pg_temp.vigentes('a1'), 'b2,c2,be,ad', 'y todo sigue como estaba');

-- ---------------------------------------------------------------------------
-- 4. La baja de un acompañante
-- ---------------------------------------------------------------------------
select pg_temp.actuar_como(pg_temp.u('b1'));
select is(pg_temp.error_de(format($$update public.jornada_acompaniante set deleted_at = now() where id = %L$$, pg_temp.u('01'))), 'ok',
          'b1 da de baja a b2 (el primero)');
select pg_temp.actuar_como_servidor();
select is(pg_temp.vigentes('a1'), 'c2,be,ad', 'quedan tres');
select is(pg_temp.columna('a1'), 'c2|null', 'la columna pasa al siguiente (c2)');
select is(pg_temp.detalle('a1'), 'ad=COLPORTOR/-,be=COLPORTOR/-,c2=COLPORTOR/-', 'y el origen y la nota de b2 se van con él');
select is((select j.sync_version - a.sync_version from public.jornada j join antes a using (id) where j.id = pg_temp.u('a1')), 0::bigint,
          'sin subir la versión de la jornada');
-- Dar de baja a todos deja la jornada sin acompañante.
update public.jornada_acompaniante set deleted_at = now() where jornada_id = pg_temp.u('a1') and deleted_at is null;
select is(pg_temp.vigentes('a1'), '(ninguno)', 'sin acompañantes vigentes');
select is(pg_temp.columna('a1'), 'null|null', 'la columna queda en null');
select is(pg_temp.detalle('a1'), '(sin filas)', 'y no queda origen ni nota');
select is((select count(*) from public.jornadas_acompaniadas_de_campania(pg_temp.u('e1')) where jornada_id = pg_temp.u('a1')), 0::bigint,
          'la jornada ya no cuenta como acompañada');
-- Se puede volver a sumar a la misma persona después de la baja.
select pg_temp.actuar_como(pg_temp.u('b1'));
create temp table r5 as select pg_temp.push(jsonb_build_array(pg_temp.job_acomp('0a', 'a1', pg_temp.u('b2')))) as r;
grant select on r5 to authenticated;
select is((select pg_temp.res(r) from r5), 'accepted/-', 'se vuelve a sumar a b2 tras su baja (el único es de los vigentes)');
select pg_temp.actuar_como_servidor();
select is(pg_temp.vigentes('a1'), 'b2', 'queda b2');
select is(pg_temp.columna('a1'), 'b2|null', 'y la columna lo refleja');

-- ---------------------------------------------------------------------------
-- 5. El teléfono de antes: sube jornada.acompaniante_id
-- ---------------------------------------------------------------------------
select pg_temp.actuar_como(pg_temp.u('b2'));
update public.jornada set acompaniante_id = pg_temp.u('b3') where id = pg_temp.u('a3');
select pg_temp.actuar_como_servidor();
select is(pg_temp.vigentes('a3'), 'b3', 'el teléfono de antes marca a b3 en la jornada: queda anotado en la tabla');
select is(pg_temp.detalle('a3'), 'b3=COLPORTOR/-', 'con su origen COLPORTOR');
select is((select colportor_id from public.jornada_acompaniante where jornada_id = pg_temp.u('a3') and deleted_at is null), pg_temp.u('b2'),
          'y la dueña es la de la jornada');
select pg_temp.actuar_como(pg_temp.u('b2'));
update public.jornada set acompaniante_id = pg_temp.u('b1') where id = pg_temp.u('a3');
select pg_temp.actuar_como_servidor();
select is(pg_temp.vigentes('a3'), 'b1', 'si lo cambia por otro, el de antes se da de baja (el reemplazo de antes)');
select is(pg_temp.columna('a3'), 'b1|null', 'y la columna es el nuevo');
select is(pg_temp.detalle('a3'), 'b1=COLPORTOR/-', 'el origen del de antes se fue con su baja');
select is((select count(*) from public.jornada_acompaniante where jornada_id = pg_temp.u('a3')), 2::bigint, 'pero la historia queda: dos filas, una de baja');
select pg_temp.actuar_como(pg_temp.u('b2'));
update public.jornada set acompaniante_id = null where id = pg_temp.u('a3');
select pg_temp.actuar_como_servidor();
select is(pg_temp.vigentes('a3'), '(ninguno)', 'si lo quita, no queda ninguno vigente');
select is(pg_temp.columna('a3'), 'null|null', 'y la columna queda en null');
select is(pg_temp.detalle('a3'), '(sin filas)', 'sin origen ni nota');

-- Un colportor que ya tiene un acompañante en la tabla y sube la jornada con la misma columna no duplica nada.
select pg_temp.actuar_como(pg_temp.u('b1'));
update public.jornada set total_visitas = coalesce(total_visitas, 0) + 1 where id = pg_temp.u('a1');
select pg_temp.actuar_como_servidor();
select is(pg_temp.vigentes('a1'), 'b2', 'tocar otra columna de la jornada no cambia sus acompañantes');

-- ---------------------------------------------------------------------------
-- 6. El teléfono manda la jornada entera: una columna vieja no pisa la lista (revisión de #255, ronda 1)
-- ---------------------------------------------------------------------------
insert into public.jornada (id, colportor_id, inicio, fin)
select pg_temp.u(x.id), pg_temp.u('b1'),
       (public.hoy_montevideo() - x.dias + time '09:00') at time zone 'America/Montevideo',
       (public.hoy_montevideo() - x.dias + time '09:00') at time zone 'America/Montevideo' + interval '2 hours'
  from (values ('a4', 8), ('a5', 9)) x(id, dias);
-- El push de la jornada entera, como lo arma la app: con la columna que el teléfono tiene (p_acomp).
create or replace function pg_temp.job_jornada(p_op text, p_jornada text, p_acomp uuid)
returns jsonb language sql security definer as $$
  select jsonb_build_object('client_op_id', pg_temp.u(p_op), 'entity', 'jornada', 'op', 'update',
                            'sync_version', j.sync_version,
                            'payload', jsonb_build_object('id', j.id, 'inicio', j.inicio, 'fin', j.fin,
                                                          'acompaniante_id', p_acomp, 'created_at', now()))
    from public.jornada j where j.id = pg_temp.u(p_jornada)
$$;
grant execute on function pg_temp.job_jornada(text, text, uuid) to authenticated;

-- Escenario 1: la dueña sube b2 y b3 y después cierra la jornada con su columna local todavía en null.
select pg_temp.actuar_como(pg_temp.u('b1'));
create temp table r6 as
  select pg_temp.push(jsonb_build_array(pg_temp.job_acomp('b1', 'a4', pg_temp.u('b2')),
                                        pg_temp.job_acomp('b2', 'a4', pg_temp.u('b3')))) as r;
grant select on r6 to authenticated;
select pg_temp.actuar_como_servidor();
select is(pg_temp.vigentes('a4'), 'b2,b3', 'a4 tiene dos acompañantes por la tabla');
select is(pg_temp.columna('a4'), 'b2|null', 'y la columna es el primero');
select pg_temp.actuar_como(pg_temp.u('b1'));
create temp table r7 as select pg_temp.push(jsonb_build_array(pg_temp.job_jornada('b3', 'a4', null))) as r;
grant select on r7 to authenticated;
select is((select pg_temp.res(r) from r7), 'accepted/-', 'el push de la jornada con la columna vieja (null) se acepta');
select pg_temp.actuar_como_servidor();
select is(pg_temp.vigentes('a4'), 'b2,b3', 'y no da de baja a nadie: sigue b2,b3');
select is(pg_temp.columna('a4'), 'b2|null', 'la columna vuelve al primero de la lista');
select is(pg_temp.detalle('a4'), 'b2=COLPORTOR/-,b3=COLPORTOR/-', 'con el origen y la nota de cada uno');
select is((select count(*) from public.jornada_acompaniante where jornada_id = pg_temp.u('a4') and deleted_at is not null), 0::bigint,
          'ninguna fila de baja');

-- Escenario 2: sube b2 y b3, quita b2 (un delete de su fila) y después sube la jornada con la columna que bajó antes (b2).
select pg_temp.actuar_como(pg_temp.u('b1'));
create temp table r8 as
  select pg_temp.push(jsonb_build_array(pg_temp.job_acomp('b4', 'a5', pg_temp.u('b2')),
                                        pg_temp.job_acomp('b5', 'a5', pg_temp.u('b3')))) as r;
grant select on r8 to authenticated;
select pg_temp.actuar_como_servidor();
select is(pg_temp.vigentes('a5'), 'b2,b3', 'a5 tiene b2,b3');
select pg_temp.actuar_como(pg_temp.u('b1'));
create temp table r9 as
  select pg_temp.push(jsonb_build_array(jsonb_build_object(
    'client_op_id', pg_temp.u('b6'), 'entity', 'jornada_acompaniante', 'op', 'delete', 'sync_version', 0,
    'payload', jsonb_build_object('id', pg_temp.u('b4'))))) as r;
grant select on r9 to authenticated;
select is((select pg_temp.res(r) from r9), 'accepted/-', 'la dueña quita a b2 (delete de su fila)');
select pg_temp.actuar_como_servidor();
select is(pg_temp.vigentes('a5'), 'b3', 'queda b3');
select is(pg_temp.columna('a5'), 'b3|null', 'y la columna pasa a b3');
select pg_temp.actuar_como(pg_temp.u('b1'));
create temp table r10 as select pg_temp.push(jsonb_build_array(pg_temp.job_jornada('b7', 'a5', pg_temp.u('b2')))) as r;
grant select on r10 to authenticated;
select is((select pg_temp.res(r) from r10), 'accepted/-', 'el push de la jornada con la columna que bajó antes (b2) se acepta');
select pg_temp.actuar_como_servidor();
select is(pg_temp.vigentes('a5'), 'b3', 'y no revive a b2 ni da de baja a b3: sigue b3');
select is(pg_temp.columna('a5'), 'b3|null', 'la columna sigue en b3');
select is(pg_temp.detalle('a5'), 'b3=COLPORTOR/-', 'y el origen de b2 sigue fuera');

-- La primera marca del teléfono de antes por el push (una jornada que nunca tuvo filas) sigue anotándose.
select pg_temp.actuar_como(pg_temp.u('b1'));
create temp table r11 as select pg_temp.push(jsonb_build_array(pg_temp.job_jornada('b8', 'a2', pg_temp.u('b3')))) as r;
grant select on r11 to authenticated;
select is((select pg_temp.res(r) from r11), 'accepted/-', 'el teléfono de antes marca a b3 en una jornada sin filas');
select pg_temp.actuar_como_servidor();
select is(pg_temp.vigentes('a2'), 'b3', 'la primera marca queda anotada en la tabla');
select is(pg_temp.detalle('a2'), 'b3=COLPORTOR/-', 'con su origen COLPORTOR');

select * from finish();
rollback;
