-- pgTAP · migración 0133 (backend-supabase#204, seguimiento de #140, decisión de Cristian del 27/10 «Nota visible»):
-- la nota del acompañamiento (y su origen) sale de `jornada` y la leen solo coordinación y Administración.
--   1. La forma: la tabla jornada_acompaniamiento, su RLS y sus privilegios; jornada sin las dos columnas.
--   2. La RPC deja la nota y el origen en la tabla nueva; el teléfono que marca deja la fila COLPORTOR.
--   3. El colportor acompañado no la ve: ni la tabla, ni su fila de jornada, ni el conflicto del push, ni el pull.
--   4. Quién la lee: el coordinador de la campaña (en la ventana de la inscripción) y el ADMIN; no el de otra.
--   5. Casos límite: cambiar, quitar y volver a poner al acompañante; el doble toque; una nota de 500 y de 501;
--      otra columna de la jornada; borrar la jornada.
begin;
select * from no_plan();

create or replace function pg_temp.actuar_como(p_uid uuid) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', json_build_object('sub', p_uid, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', p_uid::text, true);
  perform set_config('request.jwt.claim.role', 'authenticated', true);
  perform set_config('role', 'authenticated', true);
end $$;

create or replace function pg_temp.actuar_como_anon() returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', json_build_object('role', 'anon')::text, true);
  perform set_config('request.jwt.claim.sub', '', true);
  perform set_config('request.jwt.claim.role', 'anon', true);
  perform set_config('role', 'anon', true);
end $$;

create or replace function pg_temp.actuar_como_servidor() returns void language plpgsql as $$
begin
  perform set_config('role', 'postgres', true);
  perform set_config('request.jwt.claims', '', true);
  perform set_config('request.jwt.claim.sub', '', true);
  perform set_config('request.jwt.claim.role', '', true);
end $$;

create or replace function pg_temp.u(p_sufijo text) returns uuid language sql immutable as $$
  select ('01920000-0000-7000-8000-0000000133' || p_sufijo)::uuid
$$;

create or replace function pg_temp.hoy() returns date language sql stable as $$
  select (now() at time zone 'America/Montevideo')::date
$$;

create or replace function pg_temp.error_de(p_sql text) returns text language plpgsql as $$
begin
  execute p_sql;
  return 'ok';
exception when others then
  return sqlstate;
end $$;

-- Agregar un acompañamiento, como texto: ya_estaba|origen|nota (o SQLSTATE).
create or replace function pg_temp.agregar(p_jor text, p_acomp text default null, p_nota text default null)
returns text language plpgsql as $$
declare
  r record;
begin
  select * into r from public.agregar_acompaniamiento(pg_temp.u('e1'), pg_temp.u(p_jor),
                         case when p_acomp is null then null else pg_temp.u(p_acomp) end, p_nota);
  return format('%s|%s|%s', r.ya_estaba::text, coalesce(r.acompaniamiento_origen, 'null'),
                coalesce(r.acompaniamiento_nota, 'null'));
exception when others then
  return sqlstate;
end $$;

-- Lo guardado de una jornada en la tabla interna: origen|nota ('sin fila' si no hay).
create or replace function pg_temp.guardado(p_jor text) returns text language sql security definer as $$
  select coalesce((select format('%s|%s', d.origen, coalesce(d.nota, 'null'))
                     from public.jornada_acompaniamiento d where d.jornada_id = pg_temp.u(p_jor)), 'sin fila')
$$;

create or replace function pg_temp.sobre() returns jsonb language sql as $$
  select jsonb_build_object('device_id', '01920000-0000-7000-8000-0000000133d0',
                            'app_version', '1.4.2', 'schema_version', 1);
$$;
create or replace function pg_temp.push(p_jobs jsonb) returns jsonb language sql as $$
  select public.sync_push(jsonb_build_object('device', pg_temp.sobre(), 'jobs', p_jobs));
$$;

-- --- fixtures (como postgres) --------------------------------------------------
-- Staff: a1 Mariela (coordinadora de En curso), a2 Nora (de Otra), ad Samuel (ADMIN).
-- Colportores de En curso: b1 Ana, b2 Beto, b3 Carla (de baja hace 5 días). De Otra: b5 Elena.
insert into auth.users (id, instance_id, aud, role, email, encrypted_password, confirmed_at, created_at, updated_at)
select pg_temp.u(s), '00000000-0000-0000-0000-000000000000',
       'authenticated', 'authenticated', 'nota133-' || s || '@example.com', 'x', now(), now(), now()
  from unnest(array['a1','a2','ad','b1','b2','b3','b5']) s;

update public.usuario u set nombre = x.n, apellido = x.a
  from (values ('a1','Mariela','Pereyra'), ('a2','Nora','Quiroga'), ('ad','Samuel','Soto'),
               ('b1','Ana','Alfa'), ('b2','Beto','Bravo'), ('b3','Carla','Cruz'), ('b5','Elena','Eguren')) x(s, n, a)
 where u.id = pg_temp.u(x.s);

insert into public.usuario_rol (usuario_id, rol_id)
select pg_temp.u(x.s), r.id
  from (values ('a1','COORDINADOR'), ('a2','COORDINADOR'), ('ad','ADMIN'),
               ('b1','COLPORTOR'), ('b2','COLPORTOR'), ('b3','COLPORTOR'), ('b5','COLPORTOR')) x(s, codigo)
  join public.rol r on r.codigo = x.codigo;

insert into public.campania (id, nombre, tipo, fecha_inicio, fecha_fin, coordinador_id) values
  (pg_temp.u('e1'), 'En curso', 'VERANO', pg_temp.hoy() - 60, null, pg_temp.u('a1')),
  (pg_temp.u('e4'), 'Otra',     'VERANO', pg_temp.hoy() - 60, null, pg_temp.u('a2'));

insert into public.campania_colportor (campania_id, usuario_id, created_at)
select pg_temp.u(x.c), pg_temp.u(x.s), now() - interval '200 days'
  from (values ('e1','b1'), ('e1','b2'), ('e1','b3'), ('e4','b5')) x(c, s);
update public.campania_colportor set deleted_at = now() - interval '5 days'
 where campania_id = pg_temp.u('e1') and usuario_id = pg_temp.u('b3');

-- Jornadas (id, colportor, hace cuántos días), de 2 horas, a las 09:00 de Montevideo.
--   b1: f1 hace 10, f2 hace 9, f3 hace 8 · b2: f4 hace 7 · b3 (baja hace 5 días): f5 hace 10 y f6 hace 2 · b5: f7 hace 5
insert into public.jornada (id, colportor_id, inicio, fin)
select pg_temp.u(x.id), pg_temp.u(x.colp),
       (pg_temp.hoy() - x.dias + time '09:00') at time zone 'America/Montevideo',
       (pg_temp.hoy() - x.dias + time '09:00') at time zone 'America/Montevideo' + interval '2 hours'
  from (values ('f1','b1',10), ('f2','b1',9), ('f3','b1',8), ('f4','b2',7), ('f5','b3',10), ('f6','b3',2), ('f7','b5',5))
       x(id, colp, dias);

-- ---------------------------------------------------------------------------
-- 1. La forma
-- ---------------------------------------------------------------------------
select pg_temp.actuar_como_servidor();
select has_table('public', 'jornada_acompaniamiento', 'existe la tabla jornada_acompaniamiento');
select is((select relrowsecurity from pg_class where oid = 'public.jornada_acompaniamiento'::regclass), true, 'tiene RLS');
select ok(has_table_privilege('authenticated', 'public.jornada_acompaniamiento', 'select')
          and not has_table_privilege('authenticated', 'public.jornada_acompaniamiento', 'insert')
          and not has_table_privilege('authenticated', 'public.jornada_acompaniamiento', 'update')
          and not has_table_privilege('authenticated', 'public.jornada_acompaniamiento', 'delete')
          and not has_table_privilege('anon', 'public.jornada_acompaniamiento', 'select'),
          'authenticated solo lee (la escribe el servidor) y anon no ve nada');
select is((select count(*) from pg_policies where schemaname = 'public' and tablename = 'jornada_acompaniamiento'),
          1::bigint, 'una sola política: la de lectura');
select is((select cmd || ':' || roles::text from pg_policies
            where schemaname = 'public' and tablename = 'jornada_acompaniamiento'),
          'SELECT:{authenticated}', 'y es de SELECT para authenticated');
select is((select count(*) from pg_attribute where attrelid = 'public.jornada'::regclass and not attisdropped
              and attname in ('acompaniamiento_origen', 'acompaniamiento_nota')),
          0::bigint, 'jornada ya no tiene el origen ni la nota');
select is((select columnas_servidor && array['acompaniamiento_origen', 'acompaniamiento_nota']
             from sync.entidad where nombre = 'jornada'), false, 'ni quedan entre las columnas del servidor del push');
select is((select count(*) from sync.entidad where nombre = 'jornada_acompaniamiento'), 0::bigint,
          'la tabla no viaja por el sync');
select is((select pg_get_constraintdef(c.oid) from pg_constraint c
            where c.conrelid = 'public.jornada_acompaniamiento'::regclass and c.contype = 'f'
              and c.confrelid = 'public.jornada'::regclass),
          'FOREIGN KEY (jornada_id) REFERENCES jornada(id) ON DELETE CASCADE', 'va atada a su jornada y se va con ella');
select is((select array_agg(format('%s:%s', r, has_function_privilege(r, 'public.puede_leer_el_acompaniamiento(uuid)', 'execute')::text) order by r)
             from unnest(array['anon','authenticated','service_role']) r),
          array['anon:false', 'authenticated:true', 'service_role:false'], 'la función de la política la ejecuta solo authenticated');
select is((select prosecdef and proconfig = array['search_path=""'] from pg_proc
            where oid = 'public.puede_leer_el_acompaniamiento(uuid)'::regprocedure),
          true, 'y es SECURITY DEFINER con search_path vacío');
select is((select array_agg(format('%s:%s', r, has_function_privilege(r, 'public.tg_jornada_acompaniamiento_detalle()', 'execute')::text) order by r)
             from unnest(array['anon','authenticated','service_role']) r),
          array['anon:false', 'authenticated:false', 'service_role:false'], 'el trigger que la mantiene no lo ejecuta nadie a mano');
select is((select count(*) from pg_trigger where tgrelid = 'public.jornada'::regclass
              and tgname in ('jornada_acompaniamiento_detalle_insert', 'jornada_acompaniamiento_detalle_update')),
          2::bigint, 'jornada tiene los dos triggers que la mantienen (insert y cambio de acompañante)');
select is((select count(*) from pg_trigger where tgrelid = 'public.jornada_acompaniamiento'::regclass
              and tgname in ('jornada_acompaniamiento_auditoria_insert', 'jornada_acompaniamiento_auditoria_update')),
          2::bigint, 'y la tabla, los de auditoría');

-- ---------------------------------------------------------------------------
-- 2. La RPC y el teléfono la dejan en la tabla nueva
-- ---------------------------------------------------------------------------
select pg_temp.actuar_como(pg_temp.u('a1'));
select is(pg_temp.agregar('f1', null, 'Le costó arrancar; mejoró a la tarde'),
          'false|COORDINADOR|Le costó arrancar; mejoró a la tarde', 'Mariela deja la nota en la jornada de Ana');
select is(pg_temp.agregar('f4', 'b1', null), 'false|COORDINADOR|null', 'y anota a Ana como acompañante de Beto, sin nota');
select pg_temp.actuar_como_servidor();
select is(pg_temp.guardado('f1'), 'COORDINADOR|Le costó arrancar; mejoró a la tarde', 'la tabla guarda el origen y la nota');
select is(pg_temp.guardado('f4'), 'COORDINADOR|null', 'y la de Beto, sin nota');
select is((select count(*) from public.jornada_acompaniamiento), 2::bigint, 'dos filas');
select is((select to_jsonb(j) ? 'acompaniamiento_nota' or to_jsonb(j) ? 'acompaniamiento_origen'
             from public.jornada j where j.id = pg_temp.u('f1')), false, 'la fila de la jornada no lleva la nota ni el origen');
select is((select j.acompaniamiento_cargado_por from public.jornada j where j.id = pg_temp.u('f1')), pg_temp.u('a1'),
          'y quien cargó (0116) sigue en la jornada');

-- ---------------------------------------------------------------------------
-- 3. El colportor acompañado nunca la ve
-- ---------------------------------------------------------------------------
-- (Las entidades del sync las lee el servidor: el colportor no tiene permiso sobre ese esquema.)
create temp table todas_las_entidades on commit drop as select jsonb_agg(nombre) as nombres from sync.entidad;
grant select on todas_las_entidades to authenticated;
select pg_temp.actuar_como(pg_temp.u('b1'));
select is((select count(*) from public.jornada_acompaniamiento), 0::bigint, 'Ana no lee ninguna fila de la tabla (ni la de su jornada)');
select is((select count(*) from public.jornada where id = pg_temp.u('f1')), 1::bigint, 'sí lee su jornada');
select is((select to_jsonb(j) ? 'acompaniamiento_nota' or to_jsonb(j) ? 'acompaniamiento_origen'
             from public.jornada j where j.id = pg_temp.u('f1')), false, 'y esa fila no trae la nota ni el origen');
select is(pg_temp.error_de('select acompaniamiento_nota from public.jornada'), '42703', 'pedir la columna de la jornada da error: no existe');
select is(pg_temp.error_de(format('insert into public.jornada_acompaniamiento (jornada_id, origen, nota) values (%L, ''COORDINADOR'', ''x'')', pg_temp.u('f2'))),
          '42501', 'Ana no escribe la tabla');
select is(pg_temp.error_de(format('update public.jornada_acompaniamiento set nota = ''x'' where jornada_id = %L', pg_temp.u('f1'))),
          '42501', 'ni la actualiza');
select is(pg_temp.error_de(format('delete from public.jornada_acompaniamiento where jornada_id = %L', pg_temp.u('f1'))),
          '42501', 'ni la borra');
select pg_temp.actuar_como(pg_temp.u('b2'));
select is((select count(*) from public.jornada_acompaniamiento), 0::bigint, 'Beto, dueño de la jornada f4, tampoco');
select pg_temp.actuar_como_anon();
select is(pg_temp.error_de('select count(*) from public.jornada_acompaniamiento'), '42501', 'anon no tiene permiso sobre la tabla');

-- Un push viejo del teléfono (con la versión de antes) da conflict y la fila del servidor no trae la nota.
select pg_temp.actuar_como(pg_temp.u('b1'));
create temp table respuesta_push on commit drop as
  select pg_temp.push(jsonb_build_array(
           jsonb_build_object('client_op_id', pg_temp.u('c4'), 'entity', 'jornada', 'op', 'update', 'sync_version', 0,
             'payload', jsonb_build_object(
               'id', pg_temp.u('f1'), 'inicio', (pg_temp.hoy() - 10 + time '09:00') at time zone 'America/Montevideo',
               'fin', (pg_temp.hoy() - 10 + time '11:00') at time zone 'America/Montevideo',
               'acompaniante_id', null, 'created_at', now())))) as r;
grant select on respuesta_push to authenticated;
select is((select r -> 'results' -> 0 ->> 'outcome' from respuesta_push), 'conflict', 'el push viejo del teléfono da conflict');
select isnt((select r -> 'results' -> 0 -> 'server_row' from respuesta_push), null::jsonb, 'con la fila del servidor');
select is((select (r -> 'results' -> 0 -> 'server_row') ? 'acompaniamiento_nota'
              or (r -> 'results' -> 0 -> 'server_row') ? 'acompaniamiento_origen' from respuesta_push), false,
          'que no trae la nota ni el origen');
select is((select position('mejoró a la tarde' in r::text) from respuesta_push), 0, 'y la nota no aparece en ningún lado de la respuesta');
select is((select position('COORDINADOR' in r::text) from respuesta_push), 0, 'ni el origen');
-- Un push nuevo que sí entra: la respuesta tampoco la trae.
select is((pg_temp.push(jsonb_build_array(
             jsonb_build_object('client_op_id', pg_temp.u('c5'), 'entity', 'jornada', 'op', 'insert',
               'sync_version', null, 'payload', jsonb_build_object(
                 'id', pg_temp.u('c5'), 'inicio', (pg_temp.hoy() - 3 + time '14:00') at time zone 'America/Montevideo',
                 'fin', (pg_temp.hoy() - 3 + time '15:00') at time zone 'America/Montevideo',
                 'acompaniante_id', pg_temp.u('a1'), 'created_at', now()))
           )) -> 'results' -> 0 ->> 'outcome'), 'accepted', 'el teléfono sube una jornada con acompañante');
-- El pull: ni el de jornada ni el de todas las entidades que el colportor baja traen la nota.
create or replace function pg_temp.pull_texto(p_entidades jsonb) returns text language plpgsql as $$
begin
  return public.sync_pull(jsonb_build_object('device', pg_temp.sobre(), 'entities', p_entidades))::text;
exception when others then
  return 'error ' || sqlstate;
end $$;
select isnt(left(pg_temp.pull_texto('["jornada"]'::jsonb), 5), 'error', 'sanity: el colportor puede hacer el pull de jornada');
select is(position('mejoró a la tarde' in pg_temp.pull_texto('["jornada"]'::jsonb)), 0, 'el pull de jornada no trae la nota');
select is(position('acompaniamiento_nota' in pg_temp.pull_texto((select nombres from todas_las_entidades))), 0,
          'ni el pull de todas las entidades trae la columna');
select is(position('mejoró a la tarde' in pg_temp.pull_texto((select nombres from todas_las_entidades))), 0,
          'ni el texto de la nota');
select pg_temp.actuar_como_servidor();
select is(pg_temp.guardado('c5'), 'COLPORTOR|null', 'lo que sube el teléfono queda como COLPORTOR y sin nota');
select is(pg_temp.guardado('f1'), 'COORDINADOR|Le costó arrancar; mejoró a la tarde', 'y el push viejo no le tocó nada a la nota del coordinador');

-- ---------------------------------------------------------------------------
-- 4. Quién la lee
-- ---------------------------------------------------------------------------
select pg_temp.actuar_como(pg_temp.u('a1'));
select is((select count(*) from public.jornada_acompaniamiento
            where jornada_id in (pg_temp.u('f1'), pg_temp.u('f4'))), 2::bigint, 'Mariela lee las filas de las jornadas de su campaña');
select is((select nota from public.jornada_acompaniamiento where jornada_id = pg_temp.u('f1')),
          'Le costó arrancar; mejoró a la tarde', 'con el texto de la nota');
select is((select r.acompaniamiento_nota from public.jornadas_cerradas_de_colportor(pg_temp.u('e1'), pg_temp.u('b1')) r
            where r.jornada_id = pg_temp.u('f1')), 'Le costó arrancar; mejoró a la tarde',
          'y la lectura del panel la toma de su lugar nuevo (jornadas cerradas)');
select is((select r.acompaniamiento_nota from public.historial_de_acompaniamientos(pg_temp.u('e1'), pg_temp.u('b1')) r
            where r.jornada_id = pg_temp.u('f1')), 'Le costó arrancar; mejoró a la tarde', 'también el historial');
select is((select r.acompaniamiento_origen from public.historial_de_acompaniamientos(pg_temp.u('e1')) r
            where r.jornada_id = pg_temp.u('f4')), 'COORDINADOR', 'con el origen');
select pg_temp.actuar_como(pg_temp.u('a2'));
select is((select count(*) from public.jornada_acompaniamiento), 0::bigint, 'Nora, coordinadora de otra campaña, no lee ninguna');
select pg_temp.actuar_como(pg_temp.u('ad'));
select ok((select count(*) from public.jornada_acompaniamiento where jornada_id in (pg_temp.u('f1'), pg_temp.u('f4'))) = 2,
          'Samuel, ADMIN, lee todas');
select pg_temp.actuar_como(pg_temp.u('b5'));
select is((select count(*) from public.jornada_acompaniamiento), 0::bigint, 'y un colportor de otra campaña, ninguna');

-- La ventana de la inscripción: b3 se dio de baja hace 5 días; f5 (hace 10) es de la campaña, f6 (hace 2) no.
select pg_temp.actuar_como_servidor();
update public.jornada set acompaniante_id = pg_temp.u('b2') where id in (pg_temp.u('f5'), pg_temp.u('f6'));
select is((select count(*) from public.jornada_acompaniamiento where jornada_id in (pg_temp.u('f5'), pg_temp.u('f6'))),
          2::bigint, 'sanity: el servidor tiene las dos filas');
select pg_temp.actuar_como(pg_temp.u('a1'));
select is((select array_agg(jornada_id order by jornada_id) from public.jornada_acompaniamiento
            where jornada_id in (pg_temp.u('f5'), pg_temp.u('f6'))), array[pg_temp.u('f5')],
          'Mariela lee la de antes de la baja y no la de después (ya no es de su campaña)');

-- ---------------------------------------------------------------------------
-- 5. Casos límite
-- ---------------------------------------------------------------------------
-- El doble toque: la misma persona otra vez no toca la fila ni cambia la nota.
select pg_temp.actuar_como_servidor();
create temp table fila_antes on commit drop as
  select jornada_id, sync_version, updated_at, nota from public.jornada_acompaniamiento;
select pg_temp.actuar_como(pg_temp.u('a1'));
select is(pg_temp.agregar('f1', null, 'Otra nota'), 'true|COORDINADOR|Le costó arrancar; mejoró a la tarde',
          'el segundo toque es ya_estaba y devuelve la nota guardada');
select is(pg_temp.agregar('f1'), 'true|COORDINADOR|Le costó arrancar; mejoró a la tarde', 'y uno sin nota, también');
select is(pg_temp.agregar('f1', 'b2', 'Otra'), 'JO003', 'otra persona en una ya acompañada: JO003');
select pg_temp.actuar_como_servidor();
select is((select count(*) from public.jornada_acompaniamiento d join fila_antes a using (jornada_id)
            where d.sync_version is distinct from a.sync_version or d.nota is distinct from a.nota), 0::bigint,
          'ni el reintento ni el error tocaron ninguna fila');

-- Una nota de 500 caracteres entra y una de 501 no, sin tocar nada.
select pg_temp.actuar_como(pg_temp.u('a1'));
select is(pg_temp.agregar('f2', null, repeat('á', 500)), 'false|COORDINADOR|' || repeat('á', 500), 'una nota de 500 caracteres acentuados entra');
select is(pg_temp.agregar('f3', null, repeat('á', 501)), '22023', 'una de 501, no');
select pg_temp.actuar_como_servidor();
select is(pg_temp.guardado('f3'), 'sin fila', 'y f3 quedó sin acompañante ni fila');

-- Otra columna de la jornada: la fila de la nota no se mueve (ni su versión).
select pg_temp.actuar_como(pg_temp.u('b2'));
update public.jornada set total_visitas = 3 where id = pg_temp.u('f4');
select pg_temp.actuar_como_servidor();
select is((select count(*) from public.jornada_acompaniamiento d join fila_antes a using (jornada_id)
            where d.jornada_id = pg_temp.u('f4') and d.sync_version = a.sync_version), 1::bigint,
          'tocar otra columna de la jornada no toca la fila de la nota');

-- El teléfono cambia al acompañante: pasa a COLPORTOR y la nota del coordinador se va.
select pg_temp.actuar_como(pg_temp.u('b1'));
update public.jornada set acompaniante_id = pg_temp.u('a2') where id = pg_temp.u('f1');
select pg_temp.actuar_como_servidor();
select is(pg_temp.guardado('f1'), 'COLPORTOR|null', 'si el colportor cambia al acompañante, pasa a COLPORTOR y la nota se va');
-- Lo quita: no queda fila.
select pg_temp.actuar_como(pg_temp.u('b1'));
update public.jornada set acompaniante_id = null where id = pg_temp.u('f1');
select pg_temp.actuar_como_servidor();
select is(pg_temp.guardado('f1'), 'sin fila', 'y si lo quita, no queda fila');
-- Volver atrás y reentrar: el coordinador lo vuelve a cargar con otra nota.
select pg_temp.actuar_como(pg_temp.u('a1'));
select is(pg_temp.agregar('f1', null, 'Segunda nota'), 'false|COORDINADOR|Segunda nota', 'el coordinador vuelve a anotarlo, con otra nota');
select pg_temp.actuar_como_servidor();
select is(pg_temp.guardado('f1'), 'COORDINADOR|Segunda nota', 'y la fila queda con la nota nueva');
select is((select count(*) from public.jornada_acompaniamiento where jornada_id = pg_temp.u('f1')), 1::bigint, 'una sola fila por jornada');

-- Dos acciones seguidas sobre la misma jornada (el colportor cambia y el coordinador reanota): gana la última.
select pg_temp.actuar_como(pg_temp.u('b1'));
update public.jornada set acompaniante_id = null where id = pg_temp.u('f1');
select pg_temp.actuar_como(pg_temp.u('a1'));
select is(pg_temp.agregar('f1', 'b2', 'Con Beto'), 'false|COORDINADOR|Con Beto', 'quitar y volver a poner con otro acompañante en seguida');
select pg_temp.actuar_como_servidor();
select is(pg_temp.guardado('f1'), 'COORDINADOR|Con Beto', 'deja la fila de la última acción');

-- Borrar la jornada se lleva su fila.
delete from public.jornada where id = pg_temp.u('f4');
select is(pg_temp.guardado('f4'), 'sin fila', 'al borrar la jornada se va su fila');

select * from finish();
rollback;
