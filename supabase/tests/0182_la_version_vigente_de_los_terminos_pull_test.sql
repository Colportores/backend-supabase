-- pgTAP · migración 0182 (backend-supabase#254, casilla «Términos»), el pull: la versión vigente de los Términos baja con
-- `parametro_global` a todas las personas, y `consentimiento_terminos` baja solo la propia (colportora, coordinador y
-- administrador, cada uno la suya), por el delta; solo bajada: el teléfono no escribe un consentimiento.
-- Como 0145, NO va en una transacción (el delta solo sirve lo commiteado). Inserta los consentimientos directo, como el servidor
-- (no pasa por aceptar_terminos(), que deja eventos en audit_log, que solo se agrega). Limpia al empezar y al final.

select * from no_plan();

create or replace function pg_temp.actuar_como(p_uid uuid) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', json_build_object('sub', p_uid, 'role', 'authenticated')::text, false);
  perform set_config('request.jwt.claim.sub', p_uid::text, false);
  perform set_config('role', 'authenticated', false);
end $$;

create or replace function pg_temp.como_servidor() returns void language plpgsql as $$
begin
  perform set_config('role', 'postgres', false);
  perform set_config('request.jwt.claims', '', false);
  perform set_config('request.jwt.claim.sub', '', false);
end $$;

create or replace function pg_temp.u(p_sufijo text) returns uuid language sql as $$
  select ('01920000-0000-7000-8000-0000000183' || p_sufijo)::uuid;
$$;

create or replace function pg_temp.limpiar() returns void language plpgsql as $$
declare v uuid[] := array[pg_temp.u('b1'), pg_temp.u('c1'), pg_temp.u('ad')];
begin
  delete from public.consentimiento_terminos where usuario_id = any (v);
  delete from public.usuario_rol where usuario_id = any (v);
  delete from auth.users where id = any (v);
end $$;

-- Lo que bajó de consentimiento_terminos: «versión,…».
create or replace function pg_temp.consentimientos(p_delta jsonb) returns text language sql as $$
  select coalesce(string_agg(e ->> 'version', ',' order by e ->> 'version'), '-')
    from jsonb_array_elements(coalesce(p_delta -> 'rows' -> 'consentimiento_terminos', '[]'::jsonb)) e
$$;

create or replace function pg_temp.pull_de(p text, p_entidades text[], p_marca jsonb default '{}'::jsonb) returns jsonb
language plpgsql as $$
declare d jsonb;
begin
  perform pg_temp.actuar_como(pg_temp.u(p));
  d := sync.pull(p_entidades, p_marca, 1000);
  perform pg_temp.como_servidor();
  return d;
end $$;

select pg_temp.limpiar();
insert into auth.users (id, instance_id, aud, role, email, encrypted_password, confirmed_at, created_at, updated_at)
select pg_temp.u(s), '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
       'terminos183-' || s || '@example.com', 'x', now(), now(), now()
  from unnest(array['b1','c1','ad']) s;
insert into public.usuario_rol (usuario_id, rol_id)
select pg_temp.u(x.s), r.id
  from (values ('b1','COLPORTOR'), ('c1','COORDINADOR'), ('ad','ADMIN')) x(s, codigo)
  join public.rol r on r.codigo = x.codigo;
insert into public.consentimiento_terminos (usuario_id, version, created_by) values
  (pg_temp.u('b1'), 'v1', pg_temp.u('b1')),
  (pg_temp.u('ad'), 'v1', pg_temp.u('ad'));

create temp table p1 as select pg_temp.pull_de('b1', array['parametro_global', 'consentimiento_terminos']) as d;
select is((select (e ->> 'valor')::int from p1, jsonb_array_elements(d -> 'rows' -> 'parametro_global') e where e ->> 'clave' = 'terminos_version_vigente'),
          1, 'Ana baja la versión vigente con parametro_global (1 = v1)');
select is(pg_temp.consentimientos((select d from p1)), 'v1', 'y su consentimiento: solo el suyo');
select ok((select bool_and((e ->> 'usuario_id') = pg_temp.u('b1')::text and not (e ? 'xmin_w'))
             from p1, jsonb_array_elements(d -> 'rows' -> 'consentimiento_terminos') e), 'es suyo y sin la maquinaria del delta');

create temp table p2 as select pg_temp.pull_de('ad', array['consentimiento_terminos']) as d;
select is(pg_temp.consentimientos((select d from p2)), 'v1', 'el administrador baja el suyo');
create temp table p3 as select pg_temp.pull_de('c1', array['parametro_global', 'consentimiento_terminos']) as d;
select is(pg_temp.consentimientos((select d from p3)), '-', 'el coordinador, que no aceptó, no baja ninguno (ni el de otra persona)');
select is((select count(*)::int from p3, jsonb_array_elements(d -> 'rows' -> 'parametro_global') e where e ->> 'clave' = 'terminos_version_vigente'), 1,
          'pero también baja la versión vigente');

-- Ana acepta la v2 (la inserta el servidor): baja por el delta, solo a ella.
insert into public.consentimiento_terminos (usuario_id, version, created_by) values (pg_temp.u('b1'), 'v2', pg_temp.u('b1'));
select is(pg_temp.consentimientos(pg_temp.pull_de('b1', array['consentimiento_terminos'], (select d -> 'watermark' from p1))), 'v2',
          'al aceptar la v2, baja por el delta');
select is(pg_temp.consentimientos(pg_temp.pull_de('ad', array['consentimiento_terminos'], (select d -> 'watermark' from p2))), '-',
          'y no le llega al administrador');

-- Solo bajada: el teléfono no escribe un consentimiento.
select pg_temp.actuar_como(pg_temp.u('b1'));
select is(
  sync.push(jsonb_build_array(jsonb_build_object(
    'client_op_id', '01920000-0000-7000-8000-000000183b01', 'entity', 'consentimiento_terminos', 'op', 'insert',
    'payload', jsonb_build_object('id', pg_temp.u('f1'), 'usuario_id', pg_temp.u('b1'), 'version', 'v1'))))
    #>> '{results,0,code}',
  'ENTIDAD_DE_SOLO_LECTURA', 'subir un consentimiento se rechaza (la réplica es de solo lectura)');
select pg_temp.como_servidor();
select is((select count(*)::int from public.consentimiento_terminos where id = pg_temp.u('f1')), 0, 'y no quedó escrito');

drop table p1, p2, p3;
select pg_temp.limpiar();
select is((select count(*)::int from public.consentimiento_terminos where usuario_id in (pg_temp.u('b1'), pg_temp.u('c1'), pg_temp.u('ad'))), 0,
          'limpieza: no queda nada de la prueba');

select * from finish();
