-- RLS: el camino directo (Realtime, §6) no puede filtrar datos entre
-- colportores.
--
-- Va aparte de sync_test.sql porque necesita crear roles y cambiar de identidad,
-- y eso no se puede hacer dentro de la misma transacción que el resto.

\set QUIET on
\set ON_ERROR_STOP on

create or replace function assert(p_cond boolean, p_msg text)
returns void language plpgsql as $$
begin
  -- `is not true` y no `not p_cond`: con p_cond NULL, `not NULL` es NULL, el
  -- IF no entra y el assert pasa en silencio. Y NULL es justo lo que devuelve
  -- una comparación contra un campo que no vino —`jsonb_array_length(NULL) = 2`
  -- da NULL, no false— así que la forma ingenua deja pasar exactamente los
  -- fallos que este archivo existe para encontrar.
  if p_cond is not true then raise exception 'FALLÓ: %', p_msg; end if;
end $$;

insert into jornada (id, pk_usuario, inicio) values
  ('018f2c4e-6b7d-7a11-9f3c-0000000000a1','11111111-1111-4111-8111-111111111111', now()),
  ('018f2c4e-6b7d-7a11-9f3c-0000000000a2','22222222-2222-4222-8222-222222222222', now());

insert into ubicacion (id, pk_usuario, estado) values
  ('018f2c4e-6b7d-7a22-9f3c-0000000000a1','11111111-1111-4111-8111-111111111111','VENDIDA'),
  ('018f2c4e-6b7d-7a22-9f3c-0000000000a2','22222222-2222-4222-8222-222222222222','VENDIDA');

-- El rol con el que Realtime y PostgREST leen en nombre de un usuario.
do $$ begin
  if not exists (select 1 from pg_roles where rolname = 'authenticated') then
    create role authenticated nologin;
  end if;
end $$;
grant usage on schema public to authenticated;
grant select on jornada, ubicacion to authenticated;

-- ---------------------------------------------------------------------------
do $$
declare v_jornadas int; v_ubicaciones int;
begin
  set local role authenticated;
  set local request.jwt.claim.sub = '11111111-1111-4111-8111-111111111111';

  select count(*) into v_jornadas from jornada;
  select count(*) into v_ubicaciones from ubicacion;

  perform assert(v_jornadas = 1, 'un colportor ve solo su jornada, vio ' || v_jornadas);
  perform assert(v_ubicaciones = 1, 'y solo su ubicación');
  raise notice 'OK  el camino directo solo muestra lo propio';
end $$;

-- ---------------------------------------------------------------------------
do $$
declare v_n int;
begin
  set local role authenticated;
  -- Sin identidad: un token sin `sub`, o una suscripción anónima.
  select count(*) into v_n from jornada;
  perform assert(v_n = 0, 'sin identidad no se ve nada, vio ' || v_n);
  raise notice 'OK  sin identidad no se ve nada';
end $$;

-- ---------------------------------------------------------------------------
do $$
declare v_falló boolean := false;
begin
  set local role authenticated;
  set local request.jwt.claim.sub = '11111111-1111-4111-8111-111111111111';
  begin
    -- §2: la app nunca escribe las tablas del cloud. Todo entra por sync.push,
    -- que es donde viven la idempotencia, el LWW y el descarte de columnas
    -- server-authoritative; una escritura directa se saltearía las tres.
    insert into jornada (id, pk_usuario, inicio)
      values ('018f2c4e-6b7d-7a11-9f3c-0000000000ff',
              '11111111-1111-4111-8111-111111111111', now());
  exception when insufficient_privilege then
    v_falló := true;
  end;
  perform assert(v_falló, 'escribir por el camino directo tiene que fallar');
  raise notice 'OK  el camino directo es de solo lectura';
end $$;

-- ---------------------------------------------------------------------------
do $$
declare v_n int;
begin
  -- El BFF sigue funcionando: sync.pull es security definer y filtra por el
  -- pk_usuario que sacó del JWT verificado.
  select jsonb_array_length(
    sync.pull('22222222-2222-4222-8222-222222222222'::uuid, array['jornada'])
      -> 'rows' -> 'jornada') into v_n;
  perform assert(v_n = 1, 'el BFF ve la jornada del usuario que pidió');
  raise notice 'OK  el camino del BFF no lo afecta la RLS';
end $$;

-- ---------------------------------------------------------------------------
do $$
declare r record; v_sin_rls text := '';
begin
  -- Toda entidad registrada para sync tiene que tener RLS. Si mañana se agrega
  -- una tabla al registro y nadie se acuerda de las políticas, esto lo frena.
  for r in select e.nombre, c.relrowsecurity
           from sync.entidad e join pg_class c on c.oid = e.tabla loop
    if not r.relrowsecurity then
      v_sin_rls := v_sin_rls || r.nombre || ' ';
    end if;
  end loop;
  perform assert(v_sin_rls = '',
    'entidades sincronizables sin RLS: ' || v_sin_rls ||
    '— por el camino directo de Realtime se filtran entre colportores');
  raise notice 'OK  toda entidad sincronizable tiene RLS';
end $$;

delete from jornada where id in ('018f2c4e-6b7d-7a11-9f3c-0000000000a1','018f2c4e-6b7d-7a11-9f3c-0000000000a2');
delete from ubicacion where id in ('018f2c4e-6b7d-7a22-9f3c-0000000000a1','018f2c4e-6b7d-7a22-9f3c-0000000000a2');
