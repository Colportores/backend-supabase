-- pgTAP · migración 0100 (backend-supabase#140, seguimiento de #97, decisiones de Cristian del 23/10):
-- acompañamientos con otro colportor, nota y origen, 15 días tras el cierre, tramo afuera y «contado desde».
--   1. La forma: columnas, CHECK, columnas del servidor, una sola agregar_acompaniamiento y sus privilegios.
--   2. «Quién acompaña»: «Yo» (sin parámetro o el propio) y otro colportor inscripto vivo de la campaña; el
--      que no lo es (de otra campaña, dado de baja, un coordinador, inexistente) da JO005; el dueño de la
--      jornada, JO004; lo ya registrado, idempotente o JO003.
--   3. Nota y origen: la RPC pone COORDINADOR y la nota recortada; el cliente (UPDATE, INSERT, sync_push) no
--      elige ninguno de los dos; las lecturas los devuelven; el CHECK de la forma; la auditoría no copia la nota.
--   4. Los 15 días: el día 15 entra, el 16 da CZ011; las lecturas leen cualquier campaña terminada.
--   5. El tramo afuera: la reactivación lo escribe (varias veces, sin hueco vacío), el cliente no; la ventana
--      (`inscripcion_cubre_el_instante`) y las cuatro RPC no cuentan lo del hueco.
--   6. «Días sin acompañar» de quien nunca fue acompañado: desde que se sumó o volvió, nunca antes del inicio.
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

-- El uuid de un personaje del test.
create or replace function pg_temp.u(p_sufijo text) returns uuid language sql immutable as $$
  select ('01920000-0000-7000-8000-0000000100' || p_sufijo)::uuid
$$;

-- Hoy en Montevideo (hoy_montevideo() no se ejecuta como authenticated).
create or replace function pg_temp.hoy() returns date language sql stable as $$
  select (now() at time zone 'America/Montevideo')::date
$$;

create or replace function pg_temp.error_de(p_sql text) returns text language plpgsql as $$
begin
  execute p_sql;
  return 'ok';
exception when others then
  return sqlstate || '|' || sqlerrm;
end $$;

-- Agregar un acompañamiento, como texto: ya_estaba|acompañante|origen|nota (o SQLSTATE|mensaje).
create or replace function pg_temp.agregar_u(p_camp text, p_jor text, p_acomp uuid, p_nota text default null)
returns text language plpgsql as $$
declare
  r record;
begin
  select * into r from public.agregar_acompaniamiento(pg_temp.u(p_camp), pg_temp.u(p_jor), p_acomp, p_nota);
  return format('%s|%s|%s|%s', r.ya_estaba::text, r.acompaniante_nombre || ' ' || r.acompaniante_apellido,
                coalesce(r.acompaniamiento_origen, 'null'), coalesce(r.acompaniamiento_nota, 'null'));
exception when others then
  return sqlstate || '|' || sqlerrm;
end $$;
create or replace function pg_temp.agregar(p_camp text, p_jor text, p_acomp text default null, p_nota text default null)
returns text language sql as $$
  select pg_temp.agregar_u(p_camp, p_jor, case when p_acomp is null then null else pg_temp.u(p_acomp) end, p_nota)
$$;
-- Solo el SQLSTATE.
create or replace function pg_temp.cod(p_camp text, p_jor text, p_acomp text default null, p_nota text default null)
returns text language sql as $$
  select split_part(pg_temp.agregar(p_camp, p_jor, p_acomp, p_nota), '|', 1)
$$;

-- Lo guardado en una jornada: acompañante|origen|nota (con 'null' por vacío). Desde la 0133 el origen y la nota
-- viven en jornada_acompaniamiento.
create or replace function pg_temp.guardado(p_jor text) returns text language sql security definer as $$
  select format('%s|%s|%s', coalesce((select u.nombre from public.usuario u where u.id = j.acompaniante_id), 'null'),
                coalesce(d.origen, 'null'), coalesce(d.nota, 'null'))
    from public.jornada j
    left join public.jornada_acompaniamiento d on d.jornada_id = j.id
   where j.id = pg_temp.u(p_jor)
$$;

-- La fila de la tabla de un colportor: acompañamientos|último|días sin|contado desde.
create or replace function pg_temp.fila(p_camp text, p_colp text) returns text language sql as $$
  select coalesce((
    select format('%s|%s|%s|%s', r.acompaniamientos, coalesce(r.ultimo_dia::text, 'null'), r.dias_sin_acompaniar,
                  r.contado_desde)
      from public.acompaniamientos_por_colportor(pg_temp.u(p_camp)) r
     where r.colportor_id = pg_temp.u(p_colp)), 'sin fila')
$$;

-- El historial de un colportor: día|acompañante|origen|nota (un renglón por jornada, separados por ';').
create or replace function pg_temp.historial(p_camp text, p_colp text) returns text language sql as $$
  select coalesce(string_agg(format('%s|%s|%s|%s', r.dia - pg_temp.hoy(), r.acompaniante_nombre,
                                    coalesce(r.acompaniamiento_origen, 'null'), coalesce(r.acompaniamiento_nota, 'null')),
                             ';'), '(vacío)')
    from public.historial_de_acompaniamientos(pg_temp.u(p_camp), pg_temp.u(p_colp)) r
$$;

-- Las jornadas cerradas de un colportor: día|acompañante|origen|nota.
create or replace function pg_temp.jornadas(p_camp text, p_colp text) returns text language sql as $$
  select coalesce(string_agg(format('%s|%s|%s|%s', r.dia - pg_temp.hoy(), coalesce(r.acompaniante_nombre, 'null'),
                                    coalesce(r.acompaniamiento_origen, 'null'), coalesce(r.acompaniamiento_nota, 'null')),
                             ';'), '(vacío)')
    from public.jornadas_cerradas_de_colportor(pg_temp.u(p_camp), pg_temp.u(p_colp)) r
$$;

-- sync_push, como en 0069.
create or replace function pg_temp.sobre() returns jsonb language sql as $$
  select jsonb_build_object('device_id', '01920000-0000-7000-8000-0000000100d0',
                            'app_version', '1.4.2', 'schema_version', 1);
$$;
create or replace function pg_temp.push(p_jobs jsonb) returns jsonb language sql as $$
  select public.sync_push(jsonb_build_object('device', pg_temp.sobre(), 'jobs', p_jobs));
$$;
create or replace function pg_temp.job(p_op text, p_entidad text, p_payload jsonb) returns jsonb language sql as $$
  select jsonb_build_object('client_op_id', pg_temp.u(p_op), 'entity', p_entidad, 'op', 'insert',
                            'sync_version', null, 'payload', p_payload);
$$;

-- --- fixtures (como postgres) --------------------------------------------------
-- Staff: a1 coordinador de En curso, Día 15, Día 16 y Futura; a2 coordinador de Otra.
-- Colportores (todos inscriptos hace 200 días salvo que se diga otra cosa):
--   En curso (e1, desde hoy - 60, sin fin): b1 Ana Alfa · b2 Beto Bravo · b3 Carla Cruz (de baja) ·
--     b4 Diego Duarte (con un hueco de hace 30 a hace 10 días) · b6 Gonzalo Gómez (se sumó hace 20 días) ·
--     b9 Julia Jara · b11 Laura Lopez (hueco de hace 25 a hace 10 días) · b10 Kevin Kent (de baja hace 5 días).
--   Día 15 (e2, de hoy - 80 a hoy - 15): b7 Hugo Herrera.  Día 16 (e3, de hoy - 80 a hoy - 16): b8 Iris Ibarra.
--   Otra (e4, a2): b5 Elena Eguren.  Futura (e5, desde hoy + 10): b3 (se sumó hace 5 días).
insert into auth.users (id, instance_id, aud, role, email, encrypted_password, confirmed_at, created_at, updated_at)
select pg_temp.u(s), '00000000-0000-0000-0000-000000000000',
       'authenticated', 'authenticated', 'acomp100-' || s || '@example.com', 'x', now(), now(), now()
  from unnest(array['a1','a2','b1','b2','b3','b4','b5','b6','b7','b8','b9','ba','bb','bc']) s;

update public.usuario u set nombre = x.n, apellido = x.a
  from (values ('a1','Mariela','Pereyra'), ('a2','Nora','Quiroga'),
               ('b1','Ana','Alfa'), ('b2','Beto','Bravo'), ('b3','Carla','Cruz'), ('b4','Diego','Duarte'),
               ('b5','Elena','Eguren'), ('b6','Gonzalo','Gómez'), ('b7','Hugo','Herrera'), ('b8','Iris','Ibarra'),
               ('b9','Julia','Jara'), ('ba','Kevin','Kent'), ('bb','Laura','Lopez'), ('bc','Mario','Mena')) x(s, n, a)
 where u.id = pg_temp.u(x.s);

insert into public.usuario_rol (usuario_id, rol_id)
select pg_temp.u(x.s), r.id
  from (values ('a1','COORDINADOR'), ('a2','COORDINADOR'),
               ('b1','COLPORTOR'), ('b2','COLPORTOR'), ('b4','COLPORTOR')) x(s, codigo)
  join public.rol r on r.codigo = x.codigo;

insert into public.campania (id, nombre, tipo, fecha_inicio, fecha_fin, coordinador_id) values
  (pg_temp.u('e1'), 'En curso', 'VERANO', pg_temp.hoy() - 60, null,                pg_temp.u('a1')),
  (pg_temp.u('e2'), 'Dia 15',   'VERANO', pg_temp.hoy() - 80, pg_temp.hoy() - 15, pg_temp.u('a1')),
  (pg_temp.u('e3'), 'Dia 16',   'VERANO', pg_temp.hoy() - 80, pg_temp.hoy() - 16, pg_temp.u('a1')),
  (pg_temp.u('e4'), 'Otra',     'VERANO', pg_temp.hoy() - 60, null,                pg_temp.u('a2')),
  (pg_temp.u('e5'), 'Futura',   'VERANO', pg_temp.hoy() + 10, null,                pg_temp.u('a1'));

insert into public.campania_colportor (campania_id, usuario_id, created_at)
select x.c, pg_temp.u(x.s), x.alta
  from (values
    (pg_temp.u('e1'), 'b1', now() - interval '200 days'),
    (pg_temp.u('e1'), 'b2', now() - interval '200 days'),
    (pg_temp.u('e1'), 'b3', now() - interval '200 days'),
    (pg_temp.u('e1'), 'b4', now() - interval '200 days'),
    (pg_temp.u('e1'), 'b6', now() - interval '20 days'),
    (pg_temp.u('e1'), 'b9', now() - interval '200 days'),
    (pg_temp.u('e1'), 'ba', now() - interval '200 days'),
    (pg_temp.u('e1'), 'bb', now() - interval '200 days'),
    (pg_temp.u('e2'), 'b7', now() - interval '200 days'),
    (pg_temp.u('e3'), 'b8', now() - interval '200 days'),
    (pg_temp.u('e4'), 'b5', now() - interval '200 days'),
    (pg_temp.u('e5'), 'b3', now() - interval '5 days')) x(c, s, alta);

-- b3 está de baja en En curso. b10 (ba) también, desde hace 5 días: lo reactivamos al final con el RPC.
update public.campania_colportor set deleted_at = now() - interval '40 days'
 where campania_id = pg_temp.u('e1') and usuario_id = pg_temp.u('b3');
update public.campania_colportor set deleted_at = now() - interval '5 days'
 where campania_id = pg_temp.u('e1') and usuario_id = pg_temp.u('ba');
-- Los huecos de b4 y bb, como los dejaría una reactivación (la columna la escribe el servidor).
update public.campania_colportor
   set tramos_afuera = array[tstzrange(now() - interval '30 days', now() - interval '10 days', '[)')]
 where campania_id = pg_temp.u('e1') and usuario_id = pg_temp.u('b4');
update public.campania_colportor
   set tramos_afuera = array[tstzrange(now() - interval '25 days', now() - interval '10 days', '[)')]
 where campania_id = pg_temp.u('e1') and usuario_id = pg_temp.u('bb');

-- Jornadas (id, colportor, hace cuántos días, horas, acompañante). Siempre a las 09:00 de Montevideo.
--   b1: f1 hace 10, f2 hace 9 y fc hace 4 (libres) · f3 hace 8 (con a2) · fd hace 2 y fe hace 1 (libres, para el teléfono)
--   b2: f4 hace 7 (libre)
--   b4 (hueco de hace 30 a hace 10 días): f6 hace 40 (con a1), f7 hace 20 (con a1, en el hueco), f9 hace 25 (libre,
--       en el hueco), f8 hace 5 (con a1) y fa hace 3 (libre): las dos últimas son de después de la vuelta.
--   bb (hueco de hace 25 a hace 10 días, nunca acompañado de verdad): fb hace 15 (con a1, en el hueco)
--   b7 (Día 15): d1 hace 20, libre.   b8 (Día 16): d2 hace 25, libre.   b5 (Otra): d3 hace 10, libre.
insert into public.jornada (id, colportor_id, inicio, fin, acompaniante_id)
select pg_temp.u(x.id), pg_temp.u(x.colp),
       (pg_temp.hoy() - x.dias + time '09:00') at time zone 'America/Montevideo',
       (pg_temp.hoy() - x.dias + time '09:00') at time zone 'America/Montevideo' + interval '2 hours',
       case when x.acomp is null then null else pg_temp.u(x.acomp) end
  from (values
    ('f1', 'b1', 10, null), ('f2', 'b1', 9, null), ('f3', 'b1', 8, 'a2'), ('fc', 'b1', 4, null),
    ('fd', 'b1', 2, null), ('fe', 'b1', 1, null),
    ('f4', 'b2', 7, null),
    ('f6', 'b4', 40, 'a1'), ('f7', 'b4', 20, 'a1'), ('f9', 'b4', 25, null), ('f8', 'b4', 5, 'a1'), ('fa', 'b4', 3, null),
    ('fb', 'bb', 15, 'a1'),
    ('d1', 'b7', 20, null), ('d2', 'b8', 25, null), ('d3', 'b5', 10, null)
  ) x(id, colp, dias, acomp);
-- Las jornadas acompañadas de la fixture son «de antes de la 0100»: sin origen ni nota (desde la 0133 el trigger de
-- jornada les pone una fila COLPORTOR; se borra para volver a ese caso).
delete from public.jornada_acompaniamiento;

-- ---------------------------------------------------------------------------
-- 1. La forma
-- ---------------------------------------------------------------------------
select pg_temp.actuar_como_servidor();
select is((select array_agg(format('%s:%s', a.attname, format_type(a.atttypid, a.atttypmod)) order by a.attname)
             from pg_attribute a
            where a.attrelid = 'public.jornada_acompaniamiento'::regclass and a.attnum > 0 and not a.attisdropped
              and a.attname in ('origen', 'nota')),
          array['nota:text', 'origen:text'], 'el origen y la nota (opcionales) viven en jornada_acompaniamiento (0133)');
select is((select format_type(a.atttypid, a.atttypmod) || ':' || a.attnotnull::text || ':' || pg_get_expr(d.adbin, d.adrelid)
             from pg_attribute a join pg_attrdef d on d.adrelid = a.attrelid and d.adnum = a.attnum
            where a.attrelid = 'public.campania_colportor'::regclass and a.attname = 'tramos_afuera'),
          'tstzrange[]:true:''{}''::tstzrange[]', 'campania_colportor suma tramos_afuera: arreglo de rangos, no nulo, vacío por defecto');
select is((select columnas_servidor && array['acompaniamiento_origen', 'acompaniamiento_nota']
             from sync.entidad where nombre = 'jornada'), false, 'jornada ya no las tiene entre las columnas del servidor (0133)');
select is((select 'acompaniamiento_origen' = any (sync.columnas_escribibles('jornada'))
              or 'acompaniamiento_nota' = any (sync.columnas_escribibles('jornada'))), false,
          'ni entre las columnas que el cliente puede escribir');
select is((select count(*) from pg_proc where proname = 'agregar_acompaniamiento' and pronamespace = 'public'::regnamespace),
          1::bigint, 'hay una sola agregar_acompaniamiento (no quedó la de dos argumentos)');
select is((select pg_get_function_arguments(oid) from pg_proc
            where proname = 'agregar_acompaniamiento' and pronamespace = 'public'::regnamespace),
          'p_campania_id uuid, p_jornada_id uuid, p_acompaniante_id uuid DEFAULT NULL::uuid, p_nota text DEFAULT NULL::text',
          'con los dos parámetros opcionales');
select is((select array_agg(format('%s:%s', r, has_function_privilege(r, 'public.agregar_acompaniamiento(uuid,uuid,uuid,text)', 'execute')::text) order by r)
             from unnest(array['anon','authenticated','service_role']) r),
          array['anon:false', 'authenticated:true', 'service_role:false'], 'solo authenticated la ejecuta');
select is((select array_agg(format('%s:%s', r, has_function_privilege(r, 'public.inscripcion_cubre_el_instante(timestamptz,timestamptz,tstzrange[],timestamptz)', 'execute')::text) order by r)
             from unnest(array['anon','authenticated','service_role']) r),
          array['anon:false', 'authenticated:false', 'service_role:false'], 'la ventana de la inscripción es interna');
select is((select prosecdef and proconfig = array['search_path=""'] from pg_proc
            where oid = 'public.agregar_acompaniamiento(uuid,uuid,uuid,text)'::regprocedure),
          true, 'agregar sigue siendo SECURITY DEFINER con search_path vacío');
select is((select count(*) from pg_trigger where tgrelid = 'public.jornada'::regclass and tgname = 'jornada_acompaniamiento_servidor'),
          1::bigint, 'el trigger de quién cargó está en jornada');
select is((select count(*) from pg_trigger where tgrelid = 'public.campania_colportor'::regclass and tgname = 'campania_colportor_tramos_afuera'),
          1::bigint, 'y el del hueco en campania_colportor');

-- La forma del CHECK de jornada_acompaniamiento (desde el servidor). f1 no tiene acompañante: se le pone uno y el
-- trigger deja la fila con origen COLPORTOR.
create or replace function pg_temp.upd(p_set text, p_jor text default 'f1') returns text language plpgsql as $$
begin
  execute format('update public.jornada_acompaniamiento set %s where jornada_id = %L', p_set, pg_temp.u(p_jor));
  return 'ok';
exception when others then
  return sqlstate;
end $$;
update public.jornada set acompaniante_id = pg_temp.u('a1') where id = pg_temp.u('f1');
select is(pg_temp.guardado('f1'), 'Mariela|COLPORTOR|null', 'sanity: un acompañante puesto por el servidor deja la fila COLPORTOR');
select is(pg_temp.upd('origen = ''COORDINADOR'''), 'ok', 'origen COORDINADOR con acompañante');
select is(pg_temp.upd('origen = ''COLPORTOR'''), 'ok', 'origen COLPORTOR con acompañante');
select is(pg_temp.upd('origen = ''OTRO'''), '23514', 'un origen inventado se rechaza');
select is(pg_temp.upd('origen = ''coordinador'''), '23514', 'y en minúsculas, también');
select is(pg_temp.upd('origen = null'), '23502', 'y el origen no es opcional');
select is(pg_temp.upd('origen = ''COORDINADOR'', nota = ''Trabajamos juntos'''), 'ok', 'una nota con origen COORDINADOR');
select is(pg_temp.upd('origen = ''COLPORTOR'''), '23514', 'una nota con origen COLPORTOR se rechaza');
select is(pg_temp.upd('nota = '' con espacio'''), '23514', 'una nota con espacio al principio se rechaza');
select is(pg_temp.upd('nota = ''con espacio '''), '23514', 'y al final, también');
select is(pg_temp.upd('nota = E''salto\n'''), '23514', 'y con un salto de línea al final');
select is(pg_temp.upd('nota = '''''), '23514', 'una nota vacía no existe (es null)');
select is(pg_temp.upd(format('nota = %L', repeat('á', 500))), 'ok', '500 caracteres (acentuados: son caracteres, no bytes) entran');
select is(pg_temp.upd(format('nota = %L', repeat('á', 501))), '23514', '501, no');
select is(pg_temp.upd(format('nota = %L', 'uno' || chr(10) || 'dos')), 'ok', 'una nota de dos renglones entra');
-- Sin acompañante no hay origen ni nota: el trigger borra la fila.
update public.jornada set acompaniante_id = null where id = pg_temp.u('f1');
select is(pg_temp.guardado('f1'), 'null|null|null', 'quitar al acompañante desde el servidor se lleva el origen y la nota');
select is((select count(*) from public.jornada_acompaniamiento where jornada_id = pg_temp.u('f1')), 0::bigint,
          'porque la fila se borra');
select is((select count(*) from pg_constraint where conrelid = 'public.jornada_acompaniamiento'::regclass
              and conname = 'jornada_acompaniamiento_jornada_key'), 1::bigint,
          'y hay una sola fila por jornada (UNIQUE)');

-- ---------------------------------------------------------------------------
-- 2. «Quién acompaña»
-- ---------------------------------------------------------------------------
select pg_temp.actuar_como(pg_temp.u('a1'));
-- Yo, sin parámetro.
select is(pg_temp.agregar('e1', 'f1'), 'false|Mariela Pereyra|COORDINADOR|null', 'sin parámetro es «Yo»: a1, origen COORDINADOR, sin nota');
select is(pg_temp.guardado('f1'), 'Mariela|COORDINADOR|null', 'y la jornada lo guardó');
-- Yo, con el propio id: a1 no está inscripto y no hace falta.
select is(pg_temp.agregar('e1', 'f2', 'a1'), 'false|Mariela Pereyra|COORDINADOR|null', 'con el propio id también es «Yo» (el coordinador no se inscribe)');
-- Otro colportor de la misma campaña.
select is(pg_temp.agregar('e1', 'f4', 'b1'), 'false|Ana Alfa|COORDINADOR|null', 'otro colportor inscripto: b1 acompaña la jornada de b2');
select pg_temp.actuar_como_servidor();
select is(pg_temp.guardado('f4'), 'Ana|COORDINADOR|null', 'la jornada de b2 guarda a b1 como acompañante');
select is((select acompaniante_id from public.jornada where id = pg_temp.u('f4')), pg_temp.u('b1'), 'por id, no por nombre');
select pg_temp.actuar_como(pg_temp.u('a1'));

-- Los que no valen: JO005, y la jornada queda como estaba.
select pg_temp.actuar_como_servidor();
create temp table antes on commit drop as
  select j.id, j.sync_version, j.acompaniante_id, d.origen, d.nota
    from public.jornada j left join public.jornada_acompaniamiento d on d.jornada_id = j.id;
create temp table eventos_antes on commit drop as select count(*) as n from auditoria.audit_log;
select pg_temp.actuar_como(pg_temp.u('a1'));
select is(pg_temp.cod('e1', 'f9', 'b5'), 'JO001', 'sanity: f9 está en el hueco de b4 (JO001 va antes que el acompañante)');
select is(pg_temp.cod('e1', 'fc', 'b5'), 'JO005', 'un colportor de otra campaña: JO005');
select is(pg_temp.cod('e1', 'fc', 'b3'), 'JO005', 'un colportor dado de baja de esta campaña: JO005');
select is(pg_temp.cod('e1', 'fc', 'a2'), 'JO005', 'un coordinador que no está inscripto: JO005');
select is(pg_temp.cod('e1', 'fc', 'ba'), 'JO005', 'uno con la inscripción de baja (b10): JO005');
select is(pg_temp.agregar_u('e1', 'fc', gen_random_uuid()), (select pg_temp.agregar('e1', 'fc', 'b5')), 'un uuid que no existe contesta igual que uno de otra campaña');
select alike(pg_temp.agregar('e1', 'fc', 'b5'), '%no está inscripto en esta campaña. Elegí a alguien de su equipo%',
             'y el aviso dice qué hacer');
select is(pg_temp.cod('e1', 'fc', 'b1'), 'JO004', 'el dueño de la jornada como acompañante: JO004');
select alike(pg_temp.agregar('e1', 'fc', 'b1'), '%no puede figurar como acompañante de su propia jornada%', 'con su propio aviso');
select is(pg_temp.cod('e1', 'f3', 'b2'), 'JO003', 'una jornada que ya acompañó otra persona: JO003, también si eligen a otro');
select is(pg_temp.cod('e1', 'f3', 'b5'), 'JO003', 'y si el elegido tampoco es de la campaña, gana JO003 (nada se puede hacer)');
select is(pg_temp.cod('e1', 'f1', 'b2'), 'JO003', 'f1 ya figura con a1: otro colportor no la pisa');
select alike(pg_temp.agregar('e1', 'f1', 'b2'), '%Mariela Pereyra%', 'y el aviso dice quién');
select is(pg_temp.cod('e1', 'fc', null, repeat('x', 501)), '22023', 'una nota de 501 caracteres: 22023, antes de tocar nada');
select pg_temp.actuar_como_servidor();
select is((select count(*) from public.jornada j join antes a using (id)
            left join public.jornada_acompaniamiento d on d.jornada_id = j.id
            where j.sync_version is distinct from a.sync_version
               or j.acompaniante_id is distinct from a.acompaniante_id
               or d.origen is distinct from a.origen
               or d.nota is distinct from a.nota), 0::bigint,
          'ningún error tocó una jornada (JO001..JO005, 22023)');
select is((select count(*) from auditoria.audit_log) - (select n from eventos_antes), 0::bigint, 'ni dejó un evento en la auditoría');

-- Idempotente con otro colportor: la misma persona no vuelve a escribir, y la nota nueva no pisa la vieja.
select pg_temp.actuar_como(pg_temp.u('a1'));
select is(pg_temp.agregar('e1', 'fc', 'b2', 'Sector norte'), 'false|Beto Bravo|COORDINADOR|Sector norte', 'b2 acompaña a b1 en fc, con nota');
select is(pg_temp.agregar('e1', 'fc', 'b2', 'Otra nota'), 'true|Beto Bravo|COORDINADOR|Sector norte',
          'el segundo toque es ya_estaba y devuelve la nota guardada, no la nueva');
select is((select r.acompaniante_id from public.agregar_acompaniamiento(pg_temp.u('e1'), pg_temp.u('f4'), pg_temp.u('b1')) r),
          pg_temp.u('b1'), 'la respuesta lleva el id de quien acompañó (b1), no el de quien llama (a1)');
select pg_temp.actuar_como_servidor();
select is((select j.sync_version - a.sync_version from public.jornada j join antes a using (id) where j.id = pg_temp.u('fc')),
          1::bigint, 'y la versión no subió otra vez');
select is((select count(*) from auditoria.audit_log) - (select n from eventos_antes), 1::bigint, 'ni dejó un segundo evento');

-- ---------------------------------------------------------------------------
-- 3. Nota y origen
-- ---------------------------------------------------------------------------
select pg_temp.actuar_como(pg_temp.u('a1'));
select is(pg_temp.agregar('e1', 'fd', null, E'  \n Trabajamos juntos el sector norte \t '), 'false|Mariela Pereyra|COORDINADOR|Trabajamos juntos el sector norte',
          'la nota se recorta (espacios y saltos de los extremos) y queda con origen COORDINADOR');
select is(pg_temp.agregar('e1', 'fe', null, E' \n \t '), 'false|Mariela Pereyra|COORDINADOR|null', 'una nota solo de espacios es sin nota');
select pg_temp.actuar_como_servidor();
select is(pg_temp.guardado('fe'), 'Mariela|COORDINADOR|null', 'y se guarda null, no vacío');
select pg_temp.actuar_como(pg_temp.u('a1'));
select is(pg_temp.agregar('e1', 'f2', 'a1', 'otra'), 'true|Mariela Pereyra|COORDINADOR|null', 'repetir sin nota ni cambio: ya_estaba y la nota sigue sin existir');
select pg_temp.actuar_como_servidor();
update public.jornada set acompaniante_id = null where id in (pg_temp.u('fd'), pg_temp.u('fe'), pg_temp.u('f2'), pg_temp.u('f1'), pg_temp.u('fc'));
select pg_temp.actuar_como(pg_temp.u('a1'));
select is(pg_temp.agregar('e1', 'fd', null, repeat('á', 500)), 'false|Mariela Pereyra|COORDINADOR|' || repeat('á', 500), 'una nota de 500 caracteres acentuados entra');
select is(pg_temp.cod('e1', 'fe', null, repeat('á', 501)), '22023', 'una de 501, no');
select alike(pg_temp.agregar('e1', 'fe', null, repeat('á', 501)), '%hasta 500 caracteres y esta tiene 501%', 'y el aviso dice cuántos tiene');
select is(pg_temp.guardado('fe'), 'null|null|null', 'sin tocar la jornada');
select pg_temp.actuar_como_servidor();
update public.jornada set acompaniante_id = null where id = pg_temp.u('fd');

-- Las lecturas devuelven el origen y la nota.
select pg_temp.actuar_como(pg_temp.u('a1'));
select is(pg_temp.agregar('e1', 'f1', null, 'Buena presentación'), 'false|Mariela Pereyra|COORDINADOR|Buena presentación', 'a1 deja nota en f1 (b1, hace 10)');
select is(pg_temp.historial('e1', 'b1'), '-8|Nora|null|null;-10|Mariela|COORDINADOR|Buena presentación',
          'el historial de b1 trae el origen y la nota (f3 es anterior a la 0100: origen null)');
select is(pg_temp.jornadas('e1', 'b1'),
          '-1|null|null|null;-2|null|null|null;-4|null|null|null;-8|Nora|null|null;-9|null|null|null;-10|Mariela|COORDINADOR|Buena presentación',
          'las jornadas cerradas de b1 también (y las libres, sin origen)');

-- El teléfono marca «me acompañaron»: nunca elige el origen ni la nota.
select pg_temp.actuar_como(pg_temp.u('b1'));
update public.jornada set acompaniante_id = pg_temp.u('a2') where id = pg_temp.u('fe');
select pg_temp.actuar_como_servidor();
select is(pg_temp.guardado('fe'), 'Nora|COLPORTOR|null', 'el colportor marcó a a2 en su celular: origen COLPORTOR, sin nota');
select pg_temp.actuar_como(pg_temp.u('b1'));
update public.jornada set acompaniante_id = pg_temp.u('a1') where id = pg_temp.u('fe');
select pg_temp.actuar_como_servidor();
select is(pg_temp.guardado('fe'), 'Mariela|COLPORTOR|null', 'si cambia al acompañante, sigue COLPORTOR y sin nota');
-- Otra columna de una jornada con nota: nada se mueve.
select pg_temp.actuar_como(pg_temp.u('b1'));
update public.jornada set total_visitas = 3 where id = pg_temp.u('f1');
select pg_temp.actuar_como_servidor();
select is(pg_temp.guardado('f1'), 'Mariela|COORDINADOR|Buena presentación', 'tocar otra columna no cambia el origen ni la nota del coordinador');
select is((select total_visitas from public.jornada where id = pg_temp.u('f1')), 3, 'y la otra columna sí cambió');
-- Cambiar al acompañante desde el teléfono: es del colportor y la nota se va.
select pg_temp.actuar_como(pg_temp.u('b1'));
update public.jornada set acompaniante_id = pg_temp.u('a2') where id = pg_temp.u('f1');
select pg_temp.actuar_como_servidor();
select is(pg_temp.guardado('f1'), 'Nora|COLPORTOR|null', 'si el colportor cambia al acompañante, pasa a COLPORTOR y la nota (del coordinador) se va');
select pg_temp.actuar_como(pg_temp.u('b1'));
update public.jornada set acompaniante_id = null where id = pg_temp.u('f1');
select pg_temp.actuar_como_servidor();
select is(pg_temp.guardado('f1'), 'null|null|null', 'y si lo quita, no queda origen ni nota');
-- Un INSERT del cliente.
select pg_temp.actuar_como(pg_temp.u('b1'));
insert into public.jornada (id, colportor_id, inicio, fin, acompaniante_id)
values (pg_temp.u('c1'), pg_temp.u('b1'), (pg_temp.hoy() - 6 + time '10:00') at time zone 'America/Montevideo',
        (pg_temp.hoy() - 6 + time '11:00') at time zone 'America/Montevideo', pg_temp.u('a1'));
insert into public.jornada (id, colportor_id, inicio, fin)
values (pg_temp.u('c2'), pg_temp.u('b1'), (pg_temp.hoy() - 6 + time '12:00') at time zone 'America/Montevideo',
        (pg_temp.hoy() - 6 + time '13:00') at time zone 'America/Montevideo');
select pg_temp.actuar_como_servidor();
select is(pg_temp.guardado('c1'), 'Mariela|COLPORTOR|null', 'un INSERT del cliente con acompañante: COLPORTOR y sin nota');
select is(pg_temp.guardado('c2'), 'null|null|null', 'y sin acompañante no queda ninguno');
-- Por sync_push.
select pg_temp.actuar_como(pg_temp.u('b1'));
select is((pg_temp.push(jsonb_build_array(
             pg_temp.job('c3', 'jornada', jsonb_build_object(
               'id', pg_temp.u('c3'), 'inicio', (pg_temp.hoy() - 6 + time '14:00') at time zone 'America/Montevideo',
               'fin', (pg_temp.hoy() - 6 + time '15:00') at time zone 'America/Montevideo',
               'acompaniante_id', pg_temp.u('a1'), 'created_at', now()))
           )) -> 'results' -> 0 ->> 'outcome'), 'accepted', 'el teléfono sube una jornada con acompañante');
select pg_temp.actuar_como_servidor();
select is(pg_temp.guardado('c3'), 'Mariela|COLPORTOR|null', 'el push la dejó COLPORTOR y sin nota');
-- El coordinador completa una jornada y un push viejo del teléfono (con la versión de antes) no le pisa nada.
select pg_temp.actuar_como(pg_temp.u('a1'));
select is(pg_temp.agregar('e1', 'fd', null, 'Nota de a1'), 'false|Mariela Pereyra|COORDINADOR|Nota de a1', 'a1 completa fd con una nota');
select pg_temp.actuar_como(pg_temp.u('b1'));
select is((pg_temp.push(jsonb_build_array(
             jsonb_build_object('client_op_id', pg_temp.u('c4'), 'entity', 'jornada', 'op', 'update', 'sync_version', 0,
               'payload', jsonb_build_object(
                 'id', pg_temp.u('fd'), 'inicio', (pg_temp.hoy() - 2 + time '09:00') at time zone 'America/Montevideo',
                 'fin', (pg_temp.hoy() - 2 + time '11:00') at time zone 'America/Montevideo',
                 'acompaniante_id', null, 'created_at', now()))
           )) -> 'results' -> 0 ->> 'outcome'), 'conflict', 'el push viejo del teléfono da conflict y gana el servidor');
select pg_temp.actuar_como_servidor();
select is(pg_temp.guardado('fd'), 'Mariela|COORDINADOR|Nota de a1', 'y el acompañamiento, el origen y la nota siguen como los dejó el coordinador');

-- La auditoría: el acompañante y si hubo nota, nunca el texto.
select is((select a.metadata from auditoria.audit_log a where a.event_type = 'acompaniamiento_agregado'
             and a.fila_id = pg_temp.u('fc')),
          jsonb_build_object('campania_id', pg_temp.u('e1'), 'dia', pg_temp.hoy() - 4, 'acompaniante_id', pg_temp.u('b2'), 'con_nota', true),
          'el evento de fc lleva quién acompañó (b2) y con_nota true');
select is((select a.actor_user_id from auditoria.audit_log a where a.event_type = 'acompaniamiento_agregado'
             and a.fila_id = pg_temp.u('fc') limit 1), pg_temp.u('a1'), 'el actor es el coordinador que lo cargó, no el acompañante');
select is((select count(*) from auditoria.audit_log a
            where to_jsonb(a)::text ~* 'Sector norte|Buena presentación|Trabajamos juntos|Nota de a1|Cierre'), 0::bigint,
          'el texto de ninguna nota está en la auditoría');
select is((select a.metadata ->> 'con_nota' from auditoria.audit_log a where a.event_type = 'acompaniamiento_agregado'
             and a.fila_id = pg_temp.u('f2') order by a.created_at, a.id limit 1), 'false', 'y una sin nota dice con_nota false');

-- ---------------------------------------------------------------------------
-- 4. Los 15 días tras el cierre
-- ---------------------------------------------------------------------------
select pg_temp.actuar_como(pg_temp.u('a1'));
select is(pg_temp.agregar('e2', 'd1', null, 'Cierre'), 'false|Mariela Pereyra|COORDINADOR|Cierre',
          'Día 15: la campaña terminó hace 15 días y todavía se registra');
select is(pg_temp.cod('e3', 'd2'), 'CZ011', 'Día 16: la campaña terminó hace 16 días: CZ011');
select alike(pg_temp.agregar('e3', 'd2'), '%terminó hace más de 15 días y sus acompañamientos quedan como están%', 'con un aviso que dice por qué');
select alike(pg_temp.agregar('e3', 'd2'), '%en curso o que haya terminado hace 15 días o menos%', 'y qué hacer');
select pg_temp.actuar_como_servidor();
select is(pg_temp.guardado('d2'), 'null|null|null', 'Día 16 no tocó la jornada');
-- La regla es la de las ventas: la misma función decide las dos.
select is((select public.escritura_dentro_de_plazo(pg_temp.hoy() - 15)), true, 'sanity: la función de las ventas acepta fecha_fin = hoy - 15');
select is((select public.escritura_dentro_de_plazo(pg_temp.hoy() - 16)), false, 'y rechaza hoy - 16: es el mismo día 15 / 16');
select is(prosrc ~ 'escritura_dentro_de_plazo' and prosrc !~ '\+ ?15', true, 'agregar_acompaniamiento() usa esa función y no repite el número')
  from pg_proc where oid = 'public.agregar_acompaniamiento(uuid,uuid,uuid,text)'::regprocedure;
-- El permiso va antes que el plazo.
select pg_temp.actuar_como(pg_temp.u('a2'));
select is(pg_temp.cod('e2', 'd1'), '42501', 'otro coordinador, aunque esté en la gracia: 42501');
select pg_temp.actuar_como(pg_temp.u('a1'));
-- Las lecturas leen cualquier campaña terminada.
select is(pg_temp.historial('e2', 'b7'), '-20|Mariela|COORDINADOR|Cierre', 'el historial de la campaña en gracia se lee');
select is((select count(*) from public.acompaniamientos_por_colportor(pg_temp.u('e3'))), 1::bigint, 'y la de Día 16 también, aunque ya no se escriba');
select is(pg_temp.jornadas('e3', 'b8'), '-25|null|null|null', 'y sus jornadas');

-- ---------------------------------------------------------------------------
-- 5. El tramo afuera
-- ---------------------------------------------------------------------------
-- La ventana, sola: alta, baja y dos huecos.
create or replace function pg_temp.cubre(p_instante text) returns boolean language sql as $$
  select public.inscripcion_cubre_el_instante(
    '2026-01-10 00:00:00+00', '2026-09-01 00:00:00+00',
    array[tstzrange('2026-03-01 00:00:00+00', '2026-03-10 00:00:00+00', '[)'),
          tstzrange('2026-05-01 00:00:00+00', '2026-05-05 00:00:00+00', '[)')],
    p_instante::timestamptz)
$$;
select pg_temp.actuar_como_servidor();
select is(pg_temp.cubre('2026-01-09 23:59:59+00'), false, 'ventana: antes del alta no');
select is(pg_temp.cubre('2026-01-10 00:00:00+00'), true, 'el instante del alta sí');
select is(pg_temp.cubre('2026-02-15 12:00:00+00'), true, 'entre el alta y el primer hueco sí');
select is(pg_temp.cubre('2026-03-01 00:00:00+00'), false, 'el instante de la baja (inicio del hueco) no');
select is(pg_temp.cubre('2026-03-05 12:00:00+00'), false, 'adentro del hueco no');
select is(pg_temp.cubre('2026-03-09 23:59:59+00'), false, 'el último segundo del hueco no');
select is(pg_temp.cubre('2026-03-10 00:00:00+00'), true, 'el instante de la vuelta sí');
select is(pg_temp.cubre('2026-04-15 12:00:00+00'), true, 'entre los dos huecos sí');
select is(pg_temp.cubre('2026-05-03 12:00:00+00'), false, 'el segundo hueco también cuenta');
select is(pg_temp.cubre('2026-05-05 00:00:00+00'), true, 'después del segundo hueco sí');
select is(pg_temp.cubre('2026-08-31 23:59:59+00'), true, 'hasta un segundo antes de la baja de la inscripción sí');
select is(pg_temp.cubre('2026-09-01 00:00:00+00'), false, 'el instante de la baja no');
select is(public.inscripcion_cubre_el_instante('2026-01-10 00:00:00+00', null, '{}', '2030-01-01 00:00:00+00'), true,
          'sin baja ni huecos, cualquier instante posterior al alta');

-- b4: hueco de hace 30 a hace 10 días. f6 (hace 40) y f8 (hace 5) cuentan; f7 (hace 20) no.
select pg_temp.actuar_como(pg_temp.u('a1'));
select is(pg_temp.fila('e1', 'b4'), format('2|%s|5|%s', pg_temp.hoy() - 5, pg_temp.hoy() - 5),
          'b4: 2 acompañamientos (antes de la baja y después de la vuelta), el de adentro del hueco no cuenta');
select is(pg_temp.jornadas('e1', 'b4'), '-3|null|null|null;-5|Mariela|null|null;-40|Mariela|null|null',
          'las jornadas cerradas de b4 no traen las del hueco (hace 20 y hace 25)');
select is(pg_temp.cod('e1', 'f9'), 'JO001', 'agregar sobre una jornada del hueco (libre): JO001');
select is(pg_temp.cod('e1', 'f7'), 'JO001', 'y sobre una del hueco ya acompañada: JO001, no JO003');
select is(pg_temp.cod('e1', 'fa'), 'false', 'una posterior a la vuelta se puede completar');
select is(pg_temp.cod('e1', 'fa'), 'true', 'e idempotente');
select is(pg_temp.fila('e1', 'b4'), format('3|%s|3|%s', pg_temp.hoy() - 3, pg_temp.hoy() - 3), 'la tabla refleja lo escrito');

-- bb: su único acompañamiento está en el hueco, así que es como si nunca lo hubieran acompañado.
select is(pg_temp.fila('e1', 'bb'), format('0|null|10|%s', pg_temp.hoy() - 10),
          'bb: el acompañamiento del hueco no cuenta y los días se cuentan desde que volvió (hace 10 días)');
select is(pg_temp.historial('e1', 'bb'), '(vacío)', 'su historial está vacío');

-- El trigger de la reactivación (el RPC real). ba (Kevin) está de baja desde hace 5 días.
select pg_temp.actuar_como(pg_temp.u('a1'));
select is((select count(*) from public.acompaniamientos_por_colportor(pg_temp.u('e1')) r where r.colportor_id = pg_temp.u('ba')),
          0::bigint, 'ba, de baja, no sale en la tabla');
select is(pg_temp.error_de(format('select public.inscribir_colportor(%L, %L)', pg_temp.u('e1'), pg_temp.u('ba'))), 'ok',
          'a1 reactiva la inscripción de ba con inscribir_colportor()');
select pg_temp.actuar_como_servidor();
select is((select cardinality(tramos_afuera) from public.campania_colportor
            where campania_id = pg_temp.u('e1') and usuario_id = pg_temp.u('ba')), 1, 'la reactivación dejó un hueco');
select is((select upper(tramos_afuera[1]) = now() and lower(tramos_afuera[1]) = now() - interval '5 days'
                  and lower_inc(tramos_afuera[1]) and not upper_inc(tramos_afuera[1])
             from public.campania_colportor where campania_id = pg_temp.u('e1') and usuario_id = pg_temp.u('ba')),
          true, 'de la baja (hace 5 días) a la vuelta (ahora), cerrado a la izquierda y abierto a la derecha');
select is((select deleted_at is null from public.campania_colportor
            where campania_id = pg_temp.u('e1') and usuario_id = pg_temp.u('ba')), true, 'y la inscripción volvió');
-- Otra baja y otra vuelta: se suma, no se pisa.
update public.campania_colportor set deleted_at = now() - interval '1 hour'
 where campania_id = pg_temp.u('e1') and usuario_id = pg_temp.u('ba');
select is((select cardinality(tramos_afuera) from public.campania_colportor
            where campania_id = pg_temp.u('e1') and usuario_id = pg_temp.u('ba')), 1, 'dar de baja no agrega nada: el hueco se escribe al volver');
update public.campania_colportor set deleted_at = null
 where campania_id = pg_temp.u('e1') and usuario_id = pg_temp.u('ba');
select is((select cardinality(tramos_afuera) from public.campania_colportor
            where campania_id = pg_temp.u('e1') and usuario_id = pg_temp.u('ba')), 2, 'la segunda vuelta suma el segundo hueco: son dos');
select is((select lower(tramos_afuera[1]) = now() - interval '5 days' and lower(tramos_afuera[2]) = now() - interval '1 hour'
             from public.campania_colportor where campania_id = pg_temp.u('e1') and usuario_id = pg_temp.u('ba')),
          true, 'en orden, y el primero intacto');
-- Baja y vuelta en el mismo instante: no hay hueco.
update public.campania_colportor set deleted_at = now() where campania_id = pg_temp.u('e1') and usuario_id = pg_temp.u('ba');
update public.campania_colportor set deleted_at = null where campania_id = pg_temp.u('e1') and usuario_id = pg_temp.u('ba');
select is((select cardinality(tramos_afuera) from public.campania_colportor
            where campania_id = pg_temp.u('e1') and usuario_id = pg_temp.u('ba')), 2, 'una baja y vuelta en el mismo instante no guarda un hueco vacío');
-- Cambiar otra columna de una inscripción viva no toca el arreglo.
update public.campania_colportor set meta_libros = 5 where campania_id = pg_temp.u('e1') and usuario_id = pg_temp.u('ba');
select is((select cardinality(tramos_afuera) from public.campania_colportor
            where campania_id = pg_temp.u('e1') and usuario_id = pg_temp.u('ba')), 2, 'otra columna no mueve los huecos');

-- Un cliente no los escribe: ni el coordinador por UPDATE, ni al insertar.
select pg_temp.actuar_como(pg_temp.u('a1'));
update public.campania_colportor set tramos_afuera = '{}' where campania_id = pg_temp.u('e1') and usuario_id = pg_temp.u('b4');
update public.campania_colportor set tramos_afuera = array[tstzrange(now() - interval '100 days', now(), '[)')]
 where campania_id = pg_temp.u('e1') and usuario_id = pg_temp.u('b1');
select pg_temp.actuar_como_servidor();
select is((select cardinality(tramos_afuera) from public.campania_colportor where campania_id = pg_temp.u('e1') and usuario_id = pg_temp.u('b4')),
          1, 'el coordinador no puede vaciar el hueco de b4');
select is((select cardinality(tramos_afuera) from public.campania_colportor where campania_id = pg_temp.u('e1') and usuario_id = pg_temp.u('b1')),
          0, 'ni inventarle uno a b1');

-- ---------------------------------------------------------------------------
-- 6. «Días sin acompañar» de quien nunca fue acompañado
-- ---------------------------------------------------------------------------
select pg_temp.actuar_como(pg_temp.u('a1'));
select is(pg_temp.fila('e1', 'b6'), format('0|null|20|%s', pg_temp.hoy() - 20),
          'b6 se sumó hace 20 días: «Nunca» y 20 días desde que se sumó (no 60)');
select is(pg_temp.fila('e1', 'b9'), format('0|null|60|%s', pg_temp.hoy() - 60),
          'b9, inscripto desde antes de la campaña: 60 días desde el inicio');
select is(pg_temp.fila('e1', 'ba'), format('0|null|0|%s', pg_temp.hoy()),
          'ba volvió hoy: 0 días, contados desde hoy');
select is(pg_temp.fila('e5', 'b3'), format('0|null|0|%s', pg_temp.hoy() + 10),
          'una campaña por empezar: contado desde su inicio (no desde la inscripción), 0 días, nunca negativo');
select is(pg_temp.fila('e1', 'b3'), 'sin fila', 'b3, de baja en En curso, no sale');
-- Con un acompañamiento, manda el último.
select is(pg_temp.fila('e1', 'b2'), format('1|%s|7|%s', pg_temp.hoy() - 7, pg_temp.hoy() - 7), 'b2, con el acompañamiento de f4: manda el último (el contado_desde es ese día)');
select is(pg_temp.fila('e1', 'b1'), format('5|%s|1|%s', pg_temp.hoy() - 1, pg_temp.hoy() - 1), 'b1: f3, fe, c1, c3 y fd; el último, hace 1 día');
-- El orden: más días sin acompañar primero.
select is((select string_agg(r.apellido || ':' || r.dias_sin_acompaniar, ',')
             from public.acompaniamientos_por_colportor(pg_temp.u('e1')) r),
          'Jara:60,Gómez:20,Lopez:10,Bravo:7,Duarte:3,Alfa:1,Kent:0',
          'el orden: el que nunca fue acompañado desde hace más, primero; entre iguales por apellido');
-- El día de Montevideo, no el de la sesión.
select pg_temp.actuar_como_servidor();
select set_config('TimeZone', 'Pacific/Kiritimati', true);
select pg_temp.actuar_como(pg_temp.u('a1'));
select is(pg_temp.fila('e1', 'b6'), format('0|null|20|%s', pg_temp.hoy() - 20), 'con la sesión en Kiritimati, lo mismo');
select pg_temp.actuar_como_servidor();
select set_config('TimeZone', 'UTC', true);

-- Con dos huecos manda la última vuelta, esté donde esté en el arreglo (b6, el más nuevo primero).
select pg_temp.actuar_como_servidor();
update public.campania_colportor
   set tramos_afuera = array[tstzrange(now() - interval '12 days', now() - interval '8 days', '[)'),
                             tstzrange(now() - interval '19 days', now() - interval '15 days', '[)')]
 where campania_id = pg_temp.u('e1') and usuario_id = pg_temp.u('b6');
select pg_temp.actuar_como(pg_temp.u('a1'));
select is(pg_temp.fila('e1', 'b6'), format('0|null|8|%s', pg_temp.hoy() - 8),
          'b6 con dos huecos: los días se cuentan desde la última vuelta (hace 8 días)');
select pg_temp.actuar_como_servidor();

-- Una inscripción nueva (bc, por el RPC real) arranca sin huecos: el arreglo es del servidor y vacío.
select pg_temp.actuar_como(pg_temp.u('a1'));
select is(pg_temp.error_de(format('select public.inscribir_colportor(%L, %L)', pg_temp.u('e1'), pg_temp.u('bc'))), 'ok', 'a1 inscribe a bc');
select pg_temp.actuar_como_servidor();
select is((select tramos_afuera from public.campania_colportor where campania_id = pg_temp.u('e1') and usuario_id = pg_temp.u('bc')),
          '{}'::tstzrange[], 'y empieza sin huecos');
select pg_temp.actuar_como(pg_temp.u('a1'));
select is(pg_temp.fila('e1', 'bc'), format('0|null|0|%s', pg_temp.hoy()), 'y sin acompañar desde hoy (se sumó hoy): 0 días');

select * from finish();
rollback;
