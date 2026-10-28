-- pgTAP · migración 0116 (backend-supabase#173, seguimiento de front-coordinadores-web#96): quién cargó el
-- acompañamiento (jornada.acompaniamiento_cargado_por), para que el panel diga «cargado por vos» o «por X».
--   1. La forma: columna, FK, CHECK, columna del servidor, lecturas con tres columnas más, privilegios.
--   2. La RPC la pone con auth.uid() (coordinador o ADMIN, «Yo» u otro colportor); el reintento idempotente, un
--      error y el que no tiene permiso no la tocan.
--   3. Las lecturas (historial y jornadas cerradas) la traen con el nombre; lo anterior y lo del celular, en null.
--   4. El cliente (UPDATE, INSERT, sync_push) no la elige; el servidor la limpia si se quita al acompañante.
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

create or replace function pg_temp.u(p_sufijo text) returns uuid language sql immutable as $$
  select ('01920000-0000-7000-8000-0000000116' || p_sufijo)::uuid
$$;

create or replace function pg_temp.hoy() returns date language sql stable as $$
  select (now() at time zone 'America/Montevideo')::date
$$;

-- Agregar un acompañamiento, como texto: ya_estaba|acompañante (o SQLSTATE|mensaje).
create or replace function pg_temp.agregar(p_camp text, p_jor text, p_acomp text default null)
returns text language plpgsql as $$
declare
  r record;
begin
  select * into r from public.agregar_acompaniamiento(pg_temp.u(p_camp), pg_temp.u(p_jor),
                                                      case when p_acomp is null then null else pg_temp.u(p_acomp) end);
  return format('%s|%s', r.ya_estaba::text, r.acompaniante_nombre);
exception when others then
  return sqlstate || '|' || sqlerrm;
end $$;
create or replace function pg_temp.cod(p_camp text, p_jor text, p_acomp text default null)
returns text language sql as $$
  select split_part(pg_temp.agregar(p_camp, p_jor, p_acomp), '|', 1)
$$;

-- Lo guardado en una jornada: acompañante|origen|quién cargó (con 'null' por vacío; el nombre de quien cargó).
create or replace function pg_temp.guardado(p_jor text) returns text language sql security definer as $$
  select format('%s|%s|%s', coalesce((select u.nombre from public.usuario u where u.id = j.acompaniante_id), 'null'),
                coalesce(d.origen, 'null'),
                coalesce((select u.nombre from public.usuario u where u.id = j.acompaniamiento_cargado_por), 'null'))
    from public.jornada j
    left join public.jornada_acompaniamiento d on d.jornada_id = j.id
   where j.id = pg_temp.u(p_jor)
$$;

-- El historial de un colportor: día|acompañante|nombre de quien cargó|apellido (un renglón por jornada).
create or replace function pg_temp.historial(p_camp text, p_colp text) returns text language sql as $$
  select coalesce(string_agg(format('%s|%s|%s|%s', r.dia - pg_temp.hoy(), r.acompaniante_nombre,
                                    coalesce(r.acompaniamiento_cargado_por_nombre, 'null'),
                                    coalesce(r.acompaniamiento_cargado_por_apellido, 'null')),
                             ';'), '(vacío)')
    from public.historial_de_acompaniamientos(pg_temp.u(p_camp), pg_temp.u(p_colp)) r
$$;

-- Las jornadas cerradas de un colportor: día|acompañante|nombre de quien cargó.
create or replace function pg_temp.jornadas(p_camp text, p_colp text) returns text language sql as $$
  select coalesce(string_agg(format('%s|%s|%s', r.dia - pg_temp.hoy(), coalesce(r.acompaniante_nombre, 'null'),
                                    coalesce(r.acompaniamiento_cargado_por_nombre, 'null')),
                             ';'), '(vacío)')
    from public.jornadas_cerradas_de_colportor(pg_temp.u(p_camp), pg_temp.u(p_colp)) r
$$;

create or replace function pg_temp.sobre() returns jsonb language sql as $$
  select jsonb_build_object('device_id', '01920000-0000-7000-8000-0000000116d0',
                            'app_version', '1.4.2', 'schema_version', 1);
$$;
create or replace function pg_temp.push(p_jobs jsonb) returns jsonb language sql as $$
  select public.sync_push(jsonb_build_object('device', pg_temp.sobre(), 'jobs', p_jobs));
$$;

-- --- fixtures (como postgres) --------------------------------------------------
-- Staff: a1 Mariela Pereyra (coordinadora de En curso), a2 Nora Quiroga (de Otra), ad Samuel Soto (ADMIN).
-- Colportores de En curso (desde hace 200 días): b1 Ana Alfa, b2 Beto Bravo, b3 Carla Cruz.
insert into auth.users (id, instance_id, aud, role, email, encrypted_password, confirmed_at, created_at, updated_at)
select pg_temp.u(s), '00000000-0000-0000-0000-000000000000',
       'authenticated', 'authenticated', 'cargadopor116-' || s || '@example.com', 'x', now(), now(), now()
  from unnest(array['a1','a2','ad','b1','b2','b3']) s;

update public.usuario u set nombre = x.n, apellido = x.a
  from (values ('a1','Mariela','Pereyra'), ('a2','Nora','Quiroga'), ('ad','Samuel','Soto'),
               ('b1','Ana','Alfa'), ('b2','Beto','Bravo'), ('b3','Carla','Cruz')) x(s, n, a)
 where u.id = pg_temp.u(x.s);

insert into public.usuario_rol (usuario_id, rol_id)
select pg_temp.u(x.s), r.id
  from (values ('a1','COORDINADOR'), ('a2','COORDINADOR'), ('ad','ADMIN'),
               ('b1','COLPORTOR'), ('b2','COLPORTOR'), ('b3','COLPORTOR')) x(s, codigo)
  join public.rol r on r.codigo = x.codigo;

insert into public.campania (id, nombre, tipo, fecha_inicio, fecha_fin, coordinador_id) values
  (pg_temp.u('e1'), 'En curso', 'VERANO', pg_temp.hoy() - 60, null, pg_temp.u('a1')),
  (pg_temp.u('e4'), 'Otra',     'VERANO', pg_temp.hoy() - 60, null, pg_temp.u('a2'));

insert into public.campania_colportor (campania_id, usuario_id, created_at)
select pg_temp.u('e1'), pg_temp.u(s), now() - interval '200 days' from unnest(array['b1','b2','b3']) s;

-- Jornadas (id, colportor, hace cuántos días, acompañante). Siempre a las 09:00 de Montevideo y de 2 horas.
--   b1: f1 hace 10, f2 hace 9, f3 hace 8, f4 hace 7, f5 hace 6, f6 hace 5 (libres) · f7 hace 4 (con b2 de antes de la
--       0116: el servidor la dejó con origen COORDINADOR y sin quién cargó)
--   b2: f8 hace 3 (libre) · b3: f9 hace 2 (libre, para el teléfono)
insert into public.jornada (id, colportor_id, inicio, fin, acompaniante_id)
select pg_temp.u(x.id), pg_temp.u(x.colp),
       (pg_temp.hoy() - x.dias + time '09:00') at time zone 'America/Montevideo',
       (pg_temp.hoy() - x.dias + time '09:00') at time zone 'America/Montevideo' + interval '2 hours',
       case when x.acomp is null then null else pg_temp.u(x.acomp) end
  from (values
    ('f1', 'b1', 10, null), ('f2', 'b1', 9, null), ('f3', 'b1', 8, null), ('f4', 'b1', 7, null),
    ('f5', 'b1', 6, null), ('f6', 'b1', 5, null), ('f7', 'b1', 4, 'b2'),
    ('f8', 'b2', 3, null), ('f9', 'b3', 2, null)
  ) x(id, colp, dias, acomp);
-- Desde la 0133 el origen vive en jornada_acompaniamiento: el trigger dejó f7 como COLPORTOR y acá pasa a COORDINADOR.
update public.jornada_acompaniamiento set origen = 'COORDINADOR' where jornada_id = pg_temp.u('f7');

-- ---------------------------------------------------------------------------
-- 1. La forma
-- ---------------------------------------------------------------------------
select pg_temp.actuar_como_servidor();
select is((select format_type(a.atttypid, a.atttypmod) || ':' || a.attnotnull::text
             from pg_attribute a
            where a.attrelid = 'public.jornada'::regclass and a.attname = 'acompaniamiento_cargado_por'),
          'uuid:false', 'jornada suma acompaniamiento_cargado_por: uuid y opcional');
select is((select pg_get_constraintdef(c.oid) from pg_constraint c
            where c.conrelid = 'public.jornada'::regclass and c.contype = 'f'
              and c.conkey = array[(select attnum from pg_attribute
                                     where attrelid = 'public.jornada'::regclass and attname = 'acompaniamiento_cargado_por')]),
          'FOREIGN KEY (acompaniamiento_cargado_por) REFERENCES usuario(id) ON DELETE SET NULL',
          'es una FK a usuario que se vacía si el usuario se borra');
select is((select count(*) from pg_constraint where conrelid = 'public.jornada'::regclass
              and conname = 'jornada_acompaniamiento_cargado_por_con_acompaniante'), 1::bigint,
          'el CHECK que ata quién cargó al acompañante existe (0133: ya no al origen)');
select is((select columnas_servidor @> array['acompaniamiento_cargado_por'] from sync.entidad where nombre = 'jornada'),
          true, 'es una columna del servidor: el push la descarta');
select is('acompaniamiento_cargado_por' = any (sync.columnas_escribibles('jornada')), false,
          'y por eso no está entre las que el cliente puede escribir');
select is((select columnas_servidor && array['acompaniamiento_origen', 'acompaniamiento_nota']
             from sync.entidad where nombre = 'jornada'), false, 'las de la 0100 salieron de jornada con la 0133');
-- Una sola de cada función (no quedó la sobrecarga de antes) y con los privilegios de siempre.
select is((select count(*) from pg_proc where pronamespace = 'public'::regnamespace
              and proname in ('historial_de_acompaniamientos', 'jornadas_cerradas_de_colportor', 'agregar_acompaniamiento')),
          3::bigint, 'hay una sola historial_de_acompaniamientos, una jornadas_cerradas_de_colportor y una agregar_acompaniamiento');
select is((select array_agg(format('%s:%s:%s', f, r, has_function_privilege(r, f, 'execute')::text) order by f, r)
             from unnest(array['public.historial_de_acompaniamientos(uuid,uuid)',
                               'public.jornadas_cerradas_de_colportor(uuid,uuid)',
                               'public.agregar_acompaniamiento(uuid,uuid,uuid,text)']) f,
                  unnest(array['anon','authenticated','service_role']) r),
          array['public.agregar_acompaniamiento(uuid,uuid,uuid,text):anon:false',
                'public.agregar_acompaniamiento(uuid,uuid,uuid,text):authenticated:true',
                'public.agregar_acompaniamiento(uuid,uuid,uuid,text):service_role:false',
                'public.historial_de_acompaniamientos(uuid,uuid):anon:false',
                'public.historial_de_acompaniamientos(uuid,uuid):authenticated:true',
                'public.historial_de_acompaniamientos(uuid,uuid):service_role:false',
                'public.jornadas_cerradas_de_colportor(uuid,uuid):anon:false',
                'public.jornadas_cerradas_de_colportor(uuid,uuid):authenticated:true',
                'public.jornadas_cerradas_de_colportor(uuid,uuid):service_role:false'],
          'solo authenticated ejecuta las tres, como antes');
select is((select bool_and(prosecdef and proconfig = array['search_path=""']) from pg_proc
            where pronamespace = 'public'::regnamespace
              and proname in ('historial_de_acompaniamientos', 'jornadas_cerradas_de_colportor', 'agregar_acompaniamiento')),
          true, 'las tres siguen SECURITY DEFINER con search_path vacío');
select is((select proargnames::text[] from pg_proc where oid = 'public.agregar_acompaniamiento(uuid,uuid,uuid,text)'::regprocedure),
          array['p_campania_id','p_jornada_id','p_acompaniante_id','p_nota','jornada_id','colportor_id','dia',
                'acompaniante_id','acompaniante_nombre','acompaniante_apellido','ya_estaba',
                'acompaniamiento_origen','acompaniamiento_nota'],
          'agregar_acompaniamiento() conserva su firma y sus columnas (quien la llama no se rompe)');
select is((select pg_get_function_result(oid) from pg_proc where oid = 'public.historial_de_acompaniamientos(uuid,uuid)'::regprocedure),
          'TABLE(jornada_id uuid, colportor_id uuid, nombre text, apellido text, dia date, horas numeric, en_curso boolean, acompaniante_id uuid, acompaniante_nombre text, acompaniante_apellido text, acompaniamiento_origen text, acompaniamiento_nota text, acompaniamiento_cargado_por uuid, acompaniamiento_cargado_por_nombre text, acompaniamiento_cargado_por_apellido text)',
          'el historial suma las tres columnas al final');
select is((select pg_get_function_result(oid) from pg_proc where oid = 'public.jornadas_cerradas_de_colportor(uuid,uuid)'::regprocedure),
          'TABLE(jornada_id uuid, dia date, horas numeric, acompaniante_id uuid, acompaniante_nombre text, acompaniante_apellido text, acompaniamiento_origen text, acompaniamiento_nota text, acompaniamiento_cargado_por uuid, acompaniamiento_cargado_por_nombre text, acompaniamiento_cargado_por_apellido text)',
          'y las jornadas cerradas, también');

-- La forma del CHECK (desde el servidor, que no pasa por el trigger de los clientes).
create or replace function pg_temp.upd(p_set text, p_jor text default 'f1') returns text language plpgsql as $$
begin
  execute format('update public.jornada set %s where id = %L', p_set, pg_temp.u(p_jor));
  return 'ok';
exception when others then
  return sqlstate;
end $$;
select is(pg_temp.upd(format('acompaniamiento_cargado_por = %L', pg_temp.u('a1'))), 'ok',
          'quién cargó en una jornada sin acompañante: el trigger lo deja en null (no hay a quién atribuírselo)');
select is(pg_temp.guardado('f1'), 'null|null|null', 'y no queda guardado');
select is(pg_temp.upd(format('acompaniante_id = %L, acompaniamiento_cargado_por = %L',
                             pg_temp.u('b2'), pg_temp.u('a1'))), 'ok', 'con acompañante entra');
select is(pg_temp.guardado('f1'), 'Beto|COLPORTOR|Mariela', 'y queda guardado (el origen lo pone el trigger de la tabla interna)');
select is(pg_temp.upd(format('acompaniamiento_cargado_por = %L', gen_random_uuid())), '23503', 'un usuario que no existe, no');
select is(pg_temp.upd('acompaniamiento_cargado_por = null'), 'ok', 'null (no se sabe) siempre entra');
-- Sin acompañante no hay quien cargó: el servidor lo limpia.
select is(pg_temp.upd(format('acompaniamiento_cargado_por = %L', pg_temp.u('ad'))), 'ok', 'sanity: se vuelve a poner');
select is(pg_temp.upd('acompaniante_id = null'), 'ok', 'quitar al acompañante desde el servidor no falla');
select is(pg_temp.guardado('f1'), 'null|null|null', 'y se lleva el origen y quien cargó');

-- ---------------------------------------------------------------------------
-- 2. La RPC la pone: quien llama
-- ---------------------------------------------------------------------------
create temp table antes on commit drop as
  select id, sync_version, acompaniante_id, acompaniamiento_cargado_por from public.jornada;
select pg_temp.actuar_como(pg_temp.u('a1'));
-- Yo, sin parámetro.
select is(pg_temp.agregar('e1', 'f1'), 'false|Mariela', 'a1 se anota como acompañante de f1 («Yo»)');
select pg_temp.actuar_como_servidor();
select is(pg_temp.guardado('f1'), 'Mariela|COORDINADOR|Mariela', 'quien lo cargó es a1');
select is((select acompaniamiento_cargado_por from public.jornada where id = pg_temp.u('f1')), pg_temp.u('a1'), 'por id, no por nombre');
-- Otro colportor: quien lo cargó sigue siendo quien llama, no el acompañante.
select pg_temp.actuar_como(pg_temp.u('a1'));
select is(pg_temp.agregar('e1', 'f2', 'b2'), 'false|Beto', 'a1 anota a b2 como acompañante de f2');
select pg_temp.actuar_como_servidor();
select is(pg_temp.guardado('f2'), 'Beto|COORDINADOR|Mariela', 'quien lo cargó es a1, no b2');
-- El ADMIN.
select pg_temp.actuar_como(pg_temp.u('ad'));
select is(pg_temp.agregar('e1', 'f3', 'b3'), 'false|Carla', 'el ADMIN anota a b3 en f3');
select is(pg_temp.agregar('e1', 'f4'), 'false|Samuel', 'y se anota a sí mismo en f4');
select pg_temp.actuar_como_servidor();
select is(pg_temp.guardado('f3'), 'Carla|COORDINADOR|Samuel', 'quien lo cargó es el ADMIN');
select is(pg_temp.guardado('f4'), 'Samuel|COORDINADOR|Samuel', 'también cuando el acompañante es él');

-- Reintento idempotente: no cambia la fila ni quien la cargó, aunque lo repita otra persona.
select is((select j.sync_version - a.sync_version from public.jornada j join antes a using (id) where j.id = pg_temp.u('f1')),
          1::bigint, 'sanity: f1 subió una versión al cargarse');
select pg_temp.actuar_como(pg_temp.u('ad'));
select is(pg_temp.agregar('e1', 'f3', 'b3'), 'true|Carla', 'el mismo ADMIN repite f3: ya_estaba');
select pg_temp.actuar_como(pg_temp.u('a1'));
select is(pg_temp.agregar('e1', 'f3', 'b3'), 'true|Carla', 'a1 repite el mismo acompañamiento de f3: ya_estaba');
select pg_temp.actuar_como_servidor();
select is(pg_temp.guardado('f3'), 'Carla|COORDINADOR|Samuel', 'y quien lo cargó sigue siendo el primero (el ADMIN), no a1');
select is((select j.sync_version - a.sync_version from public.jornada j join antes a using (id) where j.id = pg_temp.u('f3')),
          1::bigint, 'ni subió la versión otra vez');
-- Quien lo cargó primero no cambia aunque el otro coordinador intente con otra persona: JO003.
select pg_temp.actuar_como(pg_temp.u('a1'));
select is(pg_temp.cod('e1', 'f3', 'b2'), 'JO003', 'con otra persona en una ya acompañada: JO003');
select pg_temp.actuar_como_servidor();
select is(pg_temp.guardado('f3'), 'Carla|COORDINADOR|Samuel', 'y no se pisa nada');

-- Los errores y el que no tiene permiso no escriben la columna.
select pg_temp.actuar_como(pg_temp.u('a1'));
select is(pg_temp.cod('e1', 'f5', 'a2'), 'JO005', 'un coordinador que no está inscripto: JO005');
select is(pg_temp.cod('e1', 'f5', 'b1'), 'JO004', 'el dueño de la jornada: JO004');
select is(pg_temp.cod('e1', 'f0'), 'JO001', 'una jornada que no existe: JO001');
select pg_temp.actuar_como(pg_temp.u('a2'));
select is(pg_temp.cod('e1', 'f5'), '42501', 'otro coordinador, sin permiso sobre la campaña: 42501');
select pg_temp.actuar_como(pg_temp.u('b1'));
select is(pg_temp.cod('e1', 'f8'), '42501', 'un colportor no puede llamar a la RPC: 42501');
select pg_temp.actuar_como_servidor();
select is(pg_temp.guardado('f5'), 'null|null|null', 'ninguno de los errores tocó la jornada f5');
select is(pg_temp.guardado('f8'), 'null|null|null', 'ni la f8');
select is((select count(*) from public.jornada j join antes a using (id)
            where j.id in (pg_temp.u('f5'), pg_temp.u('f6'), pg_temp.u('f7'), pg_temp.u('f8'), pg_temp.u('f9'))
              and (j.sync_version is distinct from a.sync_version
                   or j.acompaniamiento_cargado_por is distinct from a.acompaniamiento_cargado_por)), 0::bigint,
          'las jornadas que no se cargaron conservan su versión y su columna');

-- ---------------------------------------------------------------------------
-- 3. Las lecturas
-- ---------------------------------------------------------------------------
select pg_temp.actuar_como(pg_temp.u('a1'));
-- b1: f1 (a1 cargó), f2 (a1, con b2), f3 (el ADMIN), f4 (el ADMIN, él mismo), f7 (de antes: nadie), f5 y f6 libres.
select is(pg_temp.historial('e1', 'b1'),
          '-4|Beto|null|null;-7|Samuel|Samuel|Soto;-8|Carla|Samuel|Soto;-9|Beto|Mariela|Pereyra;-10|Mariela|Mariela|Pereyra',
          'el historial trae el nombre y el apellido de quien cargó cada uno; null en lo de antes de la 0116');
select is(pg_temp.jornadas('e1', 'b1'),
          '-4|Beto|null;-5|null|null;-6|null|null;-7|Samuel|Samuel;-8|Carla|Samuel;-9|Beto|Mariela;-10|Mariela|Mariela',
          'las jornadas cerradas de b1, también (las libres, sin quien cargó)');
select is((select r.acompaniamiento_cargado_por from public.historial_de_acompaniamientos(pg_temp.u('e1'), pg_temp.u('b1')) r
            where r.jornada_id = pg_temp.u('f1')), pg_temp.u('a1'),
          'el historial devuelve el uuid de quien cargó: el panel lo compara con el suyo para decir «vos»');
select is((select r.acompaniamiento_cargado_por from public.jornadas_cerradas_de_colportor(pg_temp.u('e1'), pg_temp.u('b1')) r
            where r.jornada_id = pg_temp.u('f3')), pg_temp.u('ad'), 'y las jornadas cerradas, también');
-- Sin p_colportor_id: el historial de todos.
select is((select count(*) from public.historial_de_acompaniamientos(pg_temp.u('e1')) r
            where r.acompaniamiento_cargado_por is not null), 4::bigint, 'el historial de toda la campaña: cuatro con quien cargó');
-- Otro coordinador: sigue sin permiso.
select pg_temp.actuar_como(pg_temp.u('a2'));
select throws_ok(format('select * from public.historial_de_acompaniamientos(%L)', pg_temp.u('e1')), '42501', null,
                 'el historial de una campaña ajena sigue dando 42501');
select throws_ok(format('select * from public.jornadas_cerradas_de_colportor(%L, %L)', pg_temp.u('e1'), pg_temp.u('b1')),
                 '42501', null, 'y las jornadas cerradas, también');
select pg_temp.actuar_como_servidor();

-- ---------------------------------------------------------------------------
-- 4. El cliente no la elige
-- ---------------------------------------------------------------------------
-- El teléfono marca «me acompañaron»: nunca elige quién cargó.
select pg_temp.actuar_como(pg_temp.u('b3'));
update public.jornada set acompaniante_id = pg_temp.u('a1') where id = pg_temp.u('f9');
select pg_temp.actuar_como_servidor();
select is(pg_temp.guardado('f9'), 'Mariela|COLPORTOR|null', 'el colportor marcó a a1 en su celular: origen COLPORTOR y nadie cargó');
select pg_temp.actuar_como(pg_temp.u('b3'));
update public.jornada set acompaniante_id = pg_temp.u('a1'), acompaniamiento_cargado_por = pg_temp.u('a2')
 where id = pg_temp.u('f9');
select pg_temp.actuar_como_servidor();
select is(pg_temp.guardado('f9'), 'Mariela|COLPORTOR|null', 'si manda quien cargó en la fila, el servidor lo descarta');
-- El historial lo muestra como del celular: sin nombre.
select pg_temp.actuar_como(pg_temp.u('a1'));
select is(pg_temp.historial('e1', 'b3'), '-2|Mariela|null|null', 'y el historial no inventa quién cargó lo del celular');
select pg_temp.actuar_como_servidor();
-- Otra columna de una jornada cargada por el coordinador: nada se mueve, ni siquiera si el cliente manda otro valor.
select pg_temp.actuar_como(pg_temp.u('b1'));
update public.jornada set total_visitas = 3, acompaniamiento_cargado_por = pg_temp.u('a2') where id = pg_temp.u('f1');
select pg_temp.actuar_como_servidor();
select is(pg_temp.guardado('f1'), 'Mariela|COORDINADOR|Mariela', 'tocar otra columna no cambia quien cargó, ni aunque el cliente mande otro');
select is((select total_visitas from public.jornada where id = pg_temp.u('f1')), 3, 'y la otra columna sí cambió');
-- Cambiar al acompañante desde el teléfono: es del colportor y quien cargó se va.
select pg_temp.actuar_como(pg_temp.u('b1'));
update public.jornada set acompaniante_id = pg_temp.u('a2') where id = pg_temp.u('f1');
select pg_temp.actuar_como_servidor();
select is(pg_temp.guardado('f1'), 'Nora|COLPORTOR|null', 'si el colportor cambia al acompañante, pasa a COLPORTOR y nadie cargó');
select pg_temp.actuar_como(pg_temp.u('b1'));
update public.jornada set acompaniante_id = null where id = pg_temp.u('f2');
select pg_temp.actuar_como_servidor();
select is(pg_temp.guardado('f2'), 'null|null|null', 'si lo quita, no queda origen ni quien cargó');
-- Un INSERT del cliente.
select pg_temp.actuar_como(pg_temp.u('b1'));
insert into public.jornada (id, colportor_id, inicio, fin, acompaniante_id, acompaniamiento_cargado_por)
values (pg_temp.u('c1'), pg_temp.u('b1'), (pg_temp.hoy() - 6 + time '10:00') at time zone 'America/Montevideo',
        (pg_temp.hoy() - 6 + time '11:00') at time zone 'America/Montevideo', pg_temp.u('a1'), pg_temp.u('a1'));
insert into public.jornada (id, colportor_id, inicio, fin, acompaniamiento_cargado_por)
values (pg_temp.u('c2'), pg_temp.u('b1'), (pg_temp.hoy() - 6 + time '12:00') at time zone 'America/Montevideo',
        (pg_temp.hoy() - 6 + time '13:00') at time zone 'America/Montevideo', pg_temp.u('a1'));
select pg_temp.actuar_como_servidor();
select is(pg_temp.guardado('c1'), 'Mariela|COLPORTOR|null', 'un INSERT del cliente con acompañante: COLPORTOR y nadie cargó');
select is(pg_temp.guardado('c2'), 'null|null|null', 'y sin acompañante no queda nada, aunque mande quien cargó');
-- Por sync_push.
select pg_temp.actuar_como(pg_temp.u('b1'));
select is((pg_temp.push(jsonb_build_array(
             jsonb_build_object('client_op_id', pg_temp.u('c3'), 'entity', 'jornada', 'op', 'insert',
               'sync_version', null, 'payload', jsonb_build_object(
                 'id', pg_temp.u('c3'), 'inicio', (pg_temp.hoy() - 6 + time '14:00') at time zone 'America/Montevideo',
                 'fin', (pg_temp.hoy() - 6 + time '15:00') at time zone 'America/Montevideo',
                 'acompaniante_id', pg_temp.u('a1'),
                 'acompaniamiento_cargado_por', pg_temp.u('a1'), 'created_at', now()))
           )) -> 'results' -> 0 ->> 'outcome'), 'accepted', 'el teléfono sube una jornada con acompañante (y un quien cargó inventado)');
select pg_temp.actuar_como_servidor();
select is(pg_temp.guardado('c3'), 'Mariela|COLPORTOR|null', 'el push lo descartó: COLPORTOR y nadie cargó');
-- Un push viejo del teléfono no le pisa nada al coordinador.
select pg_temp.actuar_como(pg_temp.u('a1'));
select is(pg_temp.agregar('e1', 'f6', 'b2'), 'false|Beto', 'a1 anota a b2 en f6');
select pg_temp.actuar_como(pg_temp.u('b1'));
select is((pg_temp.push(jsonb_build_array(
             jsonb_build_object('client_op_id', pg_temp.u('c4'), 'entity', 'jornada', 'op', 'update', 'sync_version', 0,
               'payload', jsonb_build_object(
                 'id', pg_temp.u('f6'), 'inicio', (pg_temp.hoy() - 5 + time '09:00') at time zone 'America/Montevideo',
                 'fin', (pg_temp.hoy() - 5 + time '11:00') at time zone 'America/Montevideo',
                 'acompaniante_id', null, 'created_at', now()))
           )) -> 'results' -> 0 ->> 'outcome'), 'conflict', 'el push viejo del teléfono da conflict y gana el servidor');
select pg_temp.actuar_como_servidor();
select is(pg_temp.guardado('f6'), 'Beto|COORDINADOR|Mariela', 'y el acompañamiento sigue con quien lo cargó');

-- ---------------------------------------------------------------------------
-- 5. Si quien cargó se va, la jornada queda
-- ---------------------------------------------------------------------------
-- (El ADMIN de arriba tiene eventos en audit_log, que no se borran: se prueba con a2, que no tiene ninguno.)
update public.jornada set acompaniante_id = pg_temp.u('b1'), acompaniamiento_cargado_por = pg_temp.u('a2')
 where id = pg_temp.u('f8');
update public.jornada_acompaniamiento set origen = 'COORDINADOR' where jornada_id = pg_temp.u('f8');
select is(pg_temp.guardado('f8'), 'Ana|COORDINADOR|Nora', 'sanity: f8 quedó cargada por a2');
delete from public.usuario where id = pg_temp.u('a2');
select is(pg_temp.guardado('f8'), 'Ana|COORDINADOR|null', 'si se borra a quien cargó, el acompañamiento queda y quien cargó pasa a null');
select pg_temp.actuar_como(pg_temp.u('a1'));
select is((select count(*) from public.historial_de_acompaniamientos(pg_temp.u('e1')) r
            where r.jornada_id = pg_temp.u('f8') and r.acompaniamiento_cargado_por is null
              and r.acompaniamiento_cargado_por_nombre is null), 1::bigint,
          'y el historial lo sigue mostrando, sin nombre');

select * from finish();
rollback;
