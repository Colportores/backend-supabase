-- pgTAP · el catálogo de carreras con sus metas para la pestaña «Becas» (migración 0186,
-- front-coordinadores-web#181, HU-BEC-001/006, vista 33).
-- carreras_de_beca(): privilegios (solo authenticated; anon no), SECURITY DEFINER con search_path fijo; permiso
-- (sin sesión, colportor, sin rol y coordinador de otra campaña: 42501; el coordinador y el ADMIN sí); CZ001 y
-- BC001; la forma de la respuesta; solo carreras vivas; la meta del tipo de la campaña (y null si no hay, o si
-- está de baja, o en una PERMANENTE); el orden por nombre sin mayúsculas.
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

create or replace function pg_temp.actuar_sin_jwt() returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', '', true);
  perform set_config('request.jwt.claim.sub', '', true);
  perform set_config('request.jwt.claim.role', '', true);
  perform set_config('role', 'authenticated', true);
end $$;

-- 'ok' o el SQLSTATE.
create or replace function pg_temp.cod(p_sql text) returns text language plpgsql as $$
begin
  execute p_sql;
  return 'ok';
exception when others then
  return sqlstate;
end $$;

create or replace function pg_temp.u(p_sufijo text) returns uuid language sql immutable as $$
  select ('01920000-0000-7000-8000-0000000186' || p_sufijo)::uuid
$$;

-- El catálogo de una campaña como una línea (solo las carreras del test, en el orden de la RPC):
-- sufijo:media:media_monto:completa:completa_monto.
create or replace function pg_temp.catalogo(p_camp text) returns text language sql as $$
  select string_agg(format('%s:%s:%s:%s:%s', right(r.carrera_id::text, 2),
                           coalesce(r.meta_media::text, '-'), coalesce(r.meta_media_monto::text, '-'),
                           coalesce(r.meta_completa::text, '-'), coalesce(r.meta_completa_monto::text, '-')),
                    ';' order by r.ord)
    from (select x.*, row_number() over () as ord
            from public.carreras_de_beca(pg_temp.u(p_camp)) x) r
   where r.carrera_id::text like '01920000-0000-7000-8000-0000000186%'
$$;

-- --- fixtures ------------------------------------------------------------------
-- Staff: a1 coordinador de Verano, Terminada y Permanente; a2 coordinador de Invierno; ad admin; a3 sin rol;
--        b1 colportor.
-- Carreras: c1 Teología (Verano e Invierno) c2 sistemas, en minúscula (sin metas) c3 Enfermería (solo Invierno)
--        c4 Derecho (dada de baja, con meta de Verano) c5 Medicina (Verano dada de baja, Invierno viva).
insert into auth.users (id, instance_id, aud, role, email, encrypted_password, confirmed_at, created_at, updated_at)
select pg_temp.u(s), '00000000-0000-0000-0000-000000000000',
       'authenticated', 'authenticated', 'catalogo-' || s || '@example.com', 'x', now(), now(), now()
  from unnest(array['a1','a2','a3','ad','b1']) s;

insert into public.usuario_rol (usuario_id, rol_id)
select pg_temp.u(x.s), r.id
  from (values ('a1','COORDINADOR'), ('a2','COORDINADOR'), ('ad','ADMIN'), ('b1','COLPORTOR')) x(s, codigo)
  join public.rol r on r.codigo = x.codigo;

insert into public.campania (id, nombre, tipo, fecha_inicio, fecha_fin, coordinador_id, deleted_at) values
  (pg_temp.u('e1'), 'Verano q186',     'VERANO',     '2026-08-03', '2099-12-31', pg_temp.u('a1'), null),
  (pg_temp.u('e2'), 'Invierno q186',   'INVIERNO',   '2100-01-01', null,         pg_temp.u('a2'), null),
  (pg_temp.u('e3'), 'Terminada q186',  'VERANO',     '2026-04-01', '2026-06-30', pg_temp.u('a1'), null),
  (pg_temp.u('e5'), 'Permanente q186', 'PERMANENTE', '2026-08-03', null,         pg_temp.u('a1'), null);

insert into public.carrera (id, nombre, deleted_at) values
  (pg_temp.u('c1'), 'Teología q186',   null),
  (pg_temp.u('c2'), 'sistemas q186',   null),
  (pg_temp.u('c3'), 'Enfermería q186', null),
  (pg_temp.u('c4'), 'Derecho q186',    now()),
  (pg_temp.u('c5'), 'Medicina q186',   null);

insert into public.meta_beca (id, carrera_id, tipo_campania, meta_media, meta_completa, meta_media_monto, meta_completa_monto, deleted_at) values
  (pg_temp.u('f1'), pg_temp.u('c1'), 'VERANO',   60, 120, 3000000, 6000000, null),
  (pg_temp.u('f2'), pg_temp.u('c1'), 'INVIERNO', 50, 100, 2500000, 5000000, null),
  (pg_temp.u('f3'), pg_temp.u('c3'), 'INVIERNO', 40,  80, 2000000, 4000000, null),
  (pg_temp.u('f4'), pg_temp.u('c4'), 'VERANO',   10,  20,  500000, 1000000, null),
  (pg_temp.u('f5'), pg_temp.u('c5'), 'VERANO',   70, 140, 3500000, 7000000, now()),
  (pg_temp.u('f6'), pg_temp.u('c5'), 'INVIERNO', 30,  60, 1500000, 3000000, null);

-- ---------------------------------------------------------------------------
-- 1. La función: forma, seguridad y privilegios
-- ---------------------------------------------------------------------------
select has_function('public', 'carreras_de_beca', array['uuid'], 'existe carreras_de_beca(uuid)');
select is((select prosecdef from pg_proc where oid = 'public.carreras_de_beca(uuid)'::regprocedure), true,
          'carreras_de_beca es SECURITY DEFINER');
select ok((select proconfig from pg_proc where oid = 'public.carreras_de_beca(uuid)'::regprocedure)
          @> array['search_path=""'], 'carreras_de_beca fija search_path vacío');
select ok(has_function_privilege('authenticated', 'public.carreras_de_beca(uuid)', 'execute'),
          'authenticated ejecuta carreras_de_beca');
select ok(not has_function_privilege('anon', 'public.carreras_de_beca(uuid)', 'execute'),
          'anon no ejecuta carreras_de_beca');
select ok(not has_function_privilege('public', 'public.carreras_de_beca(uuid)', 'execute'),
          'PUBLIC no ejecuta carreras_de_beca');
select is(
  (select array_agg(format('%s %s', a.name, a.typ) order by a.ord)
     from pg_proc p,
          unnest(p.proargnames, p.proargmodes::text[], p.proallargtypes::regtype[]) with ordinality a(name, mode, typ, ord)
    where p.oid = 'public.carreras_de_beca(uuid)'::regprocedure and a.mode = 't'),
  array['carrera_id uuid', 'nombre text', 'meta_media integer', 'meta_media_monto bigint',
        'meta_completa integer', 'meta_completa_monto bigint'],
  'la respuesta tiene la forma que espera el panel');

-- ---------------------------------------------------------------------------
-- 2. Quién la llama
-- ---------------------------------------------------------------------------
select pg_temp.actuar_sin_jwt();
select is(pg_temp.cod(format('select * from public.carreras_de_beca(%L)', pg_temp.u('e1'))), '42501',
          'sin sesión: 42501');
select pg_temp.actuar_como(pg_temp.u('b1'));
select is(pg_temp.cod(format('select * from public.carreras_de_beca(%L)', pg_temp.u('e1'))), '42501',
          'un colportor: 42501');
select pg_temp.actuar_como(pg_temp.u('a3'));
select is(pg_temp.cod(format('select * from public.carreras_de_beca(%L)', pg_temp.u('e1'))), '42501',
          'un usuario sin rol: 42501');
select pg_temp.actuar_como(pg_temp.u('a2'));
select is(pg_temp.cod(format('select * from public.carreras_de_beca(%L)', pg_temp.u('e1'))), '42501',
          'el coordinador de otra campaña: 42501');
select pg_temp.actuar_como(pg_temp.u('a1'));
select is(pg_temp.cod(format('select * from public.carreras_de_beca(%L)', pg_temp.u('ee'))), 'CZ001',
          'campaña inexistente: CZ001');
select is(pg_temp.cod(format('select * from public.carreras_de_beca(%L)', pg_temp.u('e3'))), 'BC001',
          'campaña terminada: BC001');

-- anon ni siquiera llega a la función.
select pg_temp.actuar_como_servidor();
set local role anon;
select is(pg_temp.cod(format('select * from public.carreras_de_beca(%L)', pg_temp.u('e1'))), '42501',
          'anon: sin permiso de EXECUTE (42501)');
reset role;

-- ---------------------------------------------------------------------------
-- 3. Qué devuelve
-- ---------------------------------------------------------------------------
-- Verano: Enfermería sin meta de Verano, Medicina con la de Verano de baja (sin meta), sistemas sin metas,
-- Teología con la de Verano; Derecho (de baja) no sale. Orden por nombre sin mayúsculas.
select pg_temp.actuar_como(pg_temp.u('a1'));
select is(pg_temp.catalogo('e1'),
          'c3:-:-:-:-;c5:-:-:-:-;c2:-:-:-:-;c1:60:3000000:120:6000000',
          'Verano (coordinador): carreras vivas, meta de Verano o null, por nombre sin mayúsculas');

select is(pg_temp.catalogo('e5'),
          'c3:-:-:-:-;c5:-:-:-:-;c2:-:-:-:-;c1:-:-:-:-',
          'Permanente: todas sin meta');

select pg_temp.actuar_como(pg_temp.u('a2'));
select is(pg_temp.catalogo('e2'),
          'c3:40:2000000:80:4000000;c5:30:1500000:60:3000000;c2:-:-:-:-;c1:50:2500000:100:5000000',
          'Invierno por empezar (su coordinador): la meta de Invierno');

select pg_temp.actuar_como(pg_temp.u('ad'));
select is(pg_temp.catalogo('e1'),
          'c3:-:-:-:-;c5:-:-:-:-;c2:-:-:-:-;c1:60:3000000:120:6000000',
          'el ADMIN ve el catálogo de cualquier campaña');

-- Las cuatro columnas de la meta van juntas: o todas o ninguna.
select is((select count(*)::int from public.carreras_de_beca(pg_temp.u('e1')) r
            where num_nulls(r.meta_media, r.meta_media_monto, r.meta_completa, r.meta_completa_monto) not in (0, 4)),
          0, 'la meta viene entera o en null');

select * from finish();
rollback;
