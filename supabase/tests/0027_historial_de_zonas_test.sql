-- pgTAP · migración 0022 (backend-supabase#57): el historial de zonas se llena solo al asignar,
-- cambiar, quitar o dar de baja la zona de una inscripción, o dar de baja la inscripción (que la deja
-- sin zona): zona, desde, hasta y quién. Lo leen el ADMIN y el coordinador de la campaña; nadie lo
-- escribe directo. Borrar al usuario que asignó o cerró un tramo no se traba.
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

create or replace function pg_temp.actuar_como_anon() returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', '', true);
  perform set_config('request.jwt.claim.sub', '', true);
  perform set_config('role', 'anon', true);
end $$;

-- El historial de un colportor en la campaña e1 (o la que se pida), en orden:
-- «Zona asignó>cerró», con «*» si el tramo sigue abierto y «-» si lo hizo un proceso del servidor.
create or replace function pg_temp.historial_de(p_usuario text, p_campania text default 'e1')
returns text language sql as $$
  select coalesce(string_agg(
           z.nombre || ' ' || coalesce(right(h.created_by::text, 2), '-') || '>'
             || case when h.hasta is null then '*' else coalesce(right(h.cerrada_por::text, 2), '-') end,
           ' | ' order by h.desde, h.hasta nulls last, h.id), '')
    from public.campania_colportor_zona_historial h
    join public.campania_colportor cc on cc.id = h.campania_colportor_id
    join public.zona z on z.id = h.zona_id
   where cc.usuario_id = ('01920000-0000-7000-8000-0000000027' || p_usuario)::uuid
     and cc.campania_id = ('01920000-0000-7000-8000-0000000027' || p_campania)::uuid;
$$;

create or replace function pg_temp.tramos_de(p_usuario text, p_campania text default 'e1')
returns bigint language sql as $$
  select count(*) from public.campania_colportor_zona_historial h
    join public.campania_colportor cc on cc.id = h.campania_colportor_id
   where cc.usuario_id = ('01920000-0000-7000-8000-0000000027' || p_usuario)::uuid
     and cc.campania_id = ('01920000-0000-7000-8000-0000000027' || p_campania)::uuid;
$$;

-- --- fixtures (como postgres) --------------------------------------------------
-- Verano (e1, coordina a1) y Otra (e2, coordina a2) en Montevideo. ad es ADMIN.
-- Zonas de Verano: d1 Norte, d2 Sur, d3 Oeste, d5 Este. d4 «Otra zona», de Otra.
-- Inscripciones en Verano: b1 sin zona; b2 con Norte; b3 y b4 con Oeste; b5 con Sur pero la
-- inscripción dada de baja (como las que había antes de 0022, que conservaban la zona); b6
-- suspendida y sin zona. En Otra: b7 sin zona.
insert into auth.users (id, instance_id, aud, role, email, encrypted_password, confirmed_at, created_at, updated_at)
select ('01920000-0000-7000-8000-0000000027' || s)::uuid, '00000000-0000-0000-0000-000000000000',
       'authenticated', 'authenticated', 'hz-' || s || '@example.com', 'x', now(), now(), now()
  from unnest(array['a1','a2','ad','b1','b2','b3','b4','b5','b6','b7','b8']) s;
insert into public.usuario_rol (usuario_id, rol_id)
select ('01920000-0000-7000-8000-0000000027' || x.s)::uuid, r.id
  from (values ('a1','COORDINADOR'), ('a2','COORDINADOR'), ('ad','ADMIN')) x(s, codigo)
  join public.rol r on r.codigo = x.codigo;
update public.usuario set suspendido_en = now() where id = '01920000-0000-7000-8000-0000000027b6';

insert into public.pais (id, nombre, iso_code) values ('01920000-0000-7000-8000-0000000027c0', 'Pais historial', 'ZH');
insert into public.ciudad (id, nombre, pais_id, lat_centro, lon_centro) values
  ('01920000-0000-7000-8000-0000000027c1', 'Montevideo historial', '01920000-0000-7000-8000-0000000027c0', -34.90, -56.16);
insert into public.campania (id, nombre, tipo, fecha_inicio, fecha_fin, coordinador_id) values
  ('01920000-0000-7000-8000-0000000027e1', 'Verano', 'VERANO',     current_date - 10, current_date + 30, '01920000-0000-7000-8000-0000000027a1'),
  ('01920000-0000-7000-8000-0000000027e2', 'Otra',   'PERMANENTE', current_date - 10, null,              '01920000-0000-7000-8000-0000000027a2');
insert into public.campania_ciudad (id, campania_id, ciudad_id) values
  ('01920000-0000-7000-8000-0000000027f1', '01920000-0000-7000-8000-0000000027e1', '01920000-0000-7000-8000-0000000027c1'),
  ('01920000-0000-7000-8000-0000000027f2', '01920000-0000-7000-8000-0000000027e2', '01920000-0000-7000-8000-0000000027c1');
insert into public.zona (id, nombre, campania_ciudad_id, tipo_forma, centro_lat, centro_lon, radio_m) values
  ('01920000-0000-7000-8000-0000000027d1', 'Norte',      '01920000-0000-7000-8000-0000000027f1', 'RADIAL', -34.88, -56.16, 300),
  ('01920000-0000-7000-8000-0000000027d2', 'Sur',        '01920000-0000-7000-8000-0000000027f1', 'RADIAL', -34.92, -56.16, 300),
  ('01920000-0000-7000-8000-0000000027d3', 'Oeste',      '01920000-0000-7000-8000-0000000027f1', 'RADIAL', -34.90, -56.20, 300),
  ('01920000-0000-7000-8000-0000000027d4', 'Otra zona',  '01920000-0000-7000-8000-0000000027f2', 'RADIAL', -34.90, -56.16, 300),
  ('01920000-0000-7000-8000-0000000027d5', 'Este',       '01920000-0000-7000-8000-0000000027f1', 'RADIAL', -34.90, -56.12, 300);

-- Altas del servidor: las que traen zona abren su primer tramo (sin nadie que la «asigne»).
insert into public.campania_colportor (campania_id, usuario_id, zona_id, deleted_at)
select ('01920000-0000-7000-8000-0000000027' || x.e)::uuid, ('01920000-0000-7000-8000-0000000027' || x.b)::uuid,
       ('01920000-0000-7000-8000-0000000027' || x.d)::uuid, case when x.baja then now() end
  from (values ('e1','b1',null,false), ('e1','b2','d1',false), ('e1','b3','d3',false), ('e1','b4','d3',false),
               ('e1','b5','d2',true), ('e1','b6',null,false), ('e2','b7',null,false)) x(e, b, d, baja);

-- ---------------------------------------------------------------------------
-- 1. La tabla: estructura, privilegios y RLS
-- ---------------------------------------------------------------------------
select has_table('public', 'campania_colportor_zona_historial', 'existe el historial de zonas');
select has_column('public', 'campania_colportor_zona_historial', c, 'columna ' || c)
  from unnest(array['campania_colportor_id','zona_id','desde','hasta','cerrada_por','inicial','created_by']) c;
select col_not_null('public', 'campania_colportor_zona_historial', 'desde', 'desde es obligatorio');
select col_is_null('public', 'campania_colportor_zona_historial', 'hasta', 'hasta es null mientras el tramo sigue vigente');
select ok(obj_description('public.campania_colportor_zona_historial'::regclass, 'pg_class') is not null,
          'la tabla tiene su comment on');
select is((select count(*)::integer from pg_attribute a
            where a.attrelid = 'public.campania_colportor_zona_historial'::regclass and a.attnum > 0
              and not a.attisdropped and col_description(a.attrelid, a.attnum) is null
              and a.attname in ('campania_colportor_id','zona_id','desde','hasta','cerrada_por','inicial','created_by')),
          0, 'y cada columna propia tiene el suyo');
select ok((select relrowsecurity from pg_class where oid = 'public.campania_colportor_zona_historial'::regclass),
          'RLS habilitada');
select has_trigger('public', 'campania_colportor', 'campania_colportor_historial_de_zona_insert', 'trigger de las altas con zona');
select has_trigger('public', 'campania_colportor', 'campania_colportor_historial_de_zona_update', 'trigger del cambio de zona');
select has_trigger('public', 'campania_colportor', 'campania_colportor_zona_sale_con_la_baja', 'trigger de la baja de la inscripción');
select has_trigger('public', 'campania_colportor_zona_historial', 'campania_colportor_zona_historial_sin_usuario',
                   'trigger que suelta al usuario borrado');
select ok(not exists (select 1 from sync.entidad where nombre = 'campania_colportor_zona_historial'),
          'no está en sync.entidad: no va al pull ni al push, vive solo en la nube');

select ok(has_table_privilege('authenticated', 'public.campania_colportor_zona_historial', 'select'), 'authenticated lee (la RLS decide qué)');
select ok(not has_table_privilege('authenticated', 'public.campania_colportor_zona_historial', 'insert'), 'authenticated no inserta');
select ok(not has_table_privilege('authenticated', 'public.campania_colportor_zona_historial', 'update'), 'ni actualiza');
select ok(not has_table_privilege('authenticated', 'public.campania_colportor_zona_historial', 'delete'), 'ni borra');
select ok(not has_table_privilege('anon', 'public.campania_colportor_zona_historial', 'select'), 'anon no lee');
select ok(not has_function_privilege('authenticated', 'public.tg_campania_colportor_historial_de_zona()', 'execute'),
          'el trigger no se ejecuta con JWT');
select ok(not has_function_privilege('authenticated', 'public.tg_campania_colportor_baja_sin_zona()', 'execute')
          and not has_function_privilege('authenticated', 'public.tg_campania_colportor_zona_historial_sin_usuario()', 'execute'),
          'ni los otros dos');
select ok(obj_description('public.tg_campania_colportor_baja_sin_zona()'::regprocedure, 'pg_proc') is not null
          and obj_description('public.tg_campania_colportor_zona_historial_sin_usuario()'::regprocedure, 'pg_proc') is not null,
          'todas las funciones nuevas llevan su comment on');

-- ---------------------------------------------------------------------------
-- 2. Las altas del servidor con zona abren su primer tramo
-- ---------------------------------------------------------------------------
select is(pg_temp.historial_de('b2'), 'Norte ->*', 'alta con zona: un tramo abierto, sin quién (proceso del servidor)');
select is(pg_temp.historial_de('b3'), 'Oeste ->*', 'b3, con Oeste');
select is(pg_temp.historial_de('b5'), 'Sur ->*',
          'una inscripción que ya estaba dada de baja con zona (como antes de 0022): el historial sigue a zona_id');
select is(pg_temp.historial_de('b1'), '', 'sin zona, sin tramos');
select is(pg_temp.historial_de('b6'), '', 'b6 (suspendida), sin zona, sin tramos');
select is((select h.inicial from public.campania_colportor_zona_historial h
             join public.campania_colportor cc on cc.id = h.campania_colportor_id
            where cc.usuario_id = '01920000-0000-7000-8000-0000000027b2'),
          false, 'un tramo del trigger no es «inicial» (eso es de la migración)');
select ok((select h.desde is not null and h.hasta is null and h.cerrada_por is null
             from public.campania_colportor_zona_historial h
             join public.campania_colportor cc on cc.id = h.campania_colportor_id
            where cc.usuario_id = '01920000-0000-7000-8000-0000000027b2'),
          'con desde, y sin hasta ni quién cerró');

-- ---------------------------------------------------------------------------
-- 3. Asignar, cambiar y quitar: desde, hasta y quién
-- ---------------------------------------------------------------------------
-- a1 (coordinador de Verano) le asigna Norte a b1.
select pg_temp.actuar_como('01920000-0000-7000-8000-0000000027a1');
select lives_ok(
  $$ select public.asignar_zona('01920000-0000-7000-8000-0000000027e1', '01920000-0000-7000-8000-0000000027b1',
                                '01920000-0000-7000-8000-0000000027d1') $$,
  'a1 le asigna Norte a b1');
select pg_temp.actuar_como_servidor();
select is(pg_temp.historial_de('b1'), 'Norte a1>*', 'asignar: abre el tramo y queda quién la asignó');

-- Se la cambia por Sur: cierra Norte (a1 hizo el cambio) y abre Sur.
select pg_temp.actuar_como('01920000-0000-7000-8000-0000000027a1');
select lives_ok(
  $$ select public.asignar_zona('01920000-0000-7000-8000-0000000027e1', '01920000-0000-7000-8000-0000000027b1',
                                '01920000-0000-7000-8000-0000000027d2') $$,
  'a1 se la cambia por Sur');
select pg_temp.actuar_como_servidor();
select is(pg_temp.historial_de('b1'), 'Norte a1>a1 | Sur a1>*', 'cambiar: cierra la anterior y abre la nueva');
select ok((select a.hasta = b.desde
             from public.campania_colportor_zona_historial a, public.campania_colportor_zona_historial b
            where a.zona_id = '01920000-0000-7000-8000-0000000027d1' and b.zona_id = '01920000-0000-7000-8000-0000000027d2'
              and a.campania_colportor_id = b.campania_colportor_id
              and a.campania_colportor_id = (select id from public.campania_colportor
                                              where usuario_id = '01920000-0000-7000-8000-0000000027b1')),
          'la anterior termina en el mismo instante en que empieza la nueva, sin hueco');

-- El ADMIN la cambia por Oeste: el que cierra Sur (ad) no es el que la asignó (a1).
select pg_temp.actuar_como('01920000-0000-7000-8000-0000000027ad');
select lives_ok(
  $$ select public.asignar_zona('01920000-0000-7000-8000-0000000027e1', '01920000-0000-7000-8000-0000000027b1',
                                '01920000-0000-7000-8000-0000000027d3') $$,
  'el ADMIN se la cambia por Oeste');
select pg_temp.actuar_como_servidor();
select is(pg_temp.historial_de('b1'), 'Norte a1>a1 | Sur a1>ad | Oeste ad>*',
          'cada tramo guarda quién la asignó y quién la cerró');

-- Asignar la que ya tiene no escribe nada.
select pg_temp.actuar_como('01920000-0000-7000-8000-0000000027ad');
select lives_ok(
  $$ select public.asignar_zona('01920000-0000-7000-8000-0000000027e1', '01920000-0000-7000-8000-0000000027b1',
                                '01920000-0000-7000-8000-0000000027d3') $$,
  'asignarle la zona que ya tiene');
select pg_temp.actuar_como_servidor();
select is(pg_temp.tramos_de('b1'), 3::bigint, 'no agrega ni cierra ningún tramo');

-- «Quitar»: cierra el tramo y no abre otro.
select pg_temp.actuar_como('01920000-0000-7000-8000-0000000027a1');
select lives_ok(
  $$ select public.quitar_zona('01920000-0000-7000-8000-0000000027e1', '01920000-0000-7000-8000-0000000027b1') $$,
  'a1 le quita la zona a b1');
select pg_temp.actuar_como_servidor();
select is(pg_temp.historial_de('b1'), 'Norte a1>a1 | Sur a1>ad | Oeste ad>a1',
          'quitar: cierra el tramo (quién: a1) y no queda ninguno abierto');

-- Quitarla de nuevo, a quien no tiene: nada.
select pg_temp.actuar_como('01920000-0000-7000-8000-0000000027a1');
select lives_ok(
  $$ select public.quitar_zona('01920000-0000-7000-8000-0000000027e1', '01920000-0000-7000-8000-0000000027b1') $$,
  'quitarle la zona a quien no tiene');
select pg_temp.actuar_como_servidor();
select is(pg_temp.tramos_de('b1'), 3::bigint, 'no escribe nada');

-- Volver a una zona anterior es un tramo nuevo, no reabre el viejo.
select pg_temp.actuar_como('01920000-0000-7000-8000-0000000027a1');
select lives_ok(
  $$ select public.asignar_zona('01920000-0000-7000-8000-0000000027e1', '01920000-0000-7000-8000-0000000027b1',
                                '01920000-0000-7000-8000-0000000027d1') $$,
  'a1 le vuelve a asignar Norte');
select pg_temp.actuar_como_servidor();
select is(pg_temp.historial_de('b1'), 'Norte a1>a1 | Sur a1>ad | Oeste ad>a1 | Norte a1>*',
          'volver a una zona anterior abre un tramo nuevo: el viejo queda como estaba');
select ok((select a.hasta < b.desde
             from public.campania_colportor_zona_historial a, public.campania_colportor_zona_historial b
            where a.zona_id = '01920000-0000-7000-8000-0000000027d3' and b.zona_id = '01920000-0000-7000-8000-0000000027d1'
              and b.hasta is null and a.campania_colportor_id = b.campania_colportor_id),
          'y entre el «Quitar» y la nueva asignación queda el período sin zona');

-- ---------------------------------------------------------------------------
-- 4. Lo que no debe escribir nada
-- ---------------------------------------------------------------------------
-- Otra columna de la inscripción (meta_libros) no es un cambio de zona.
select pg_temp.actuar_como('01920000-0000-7000-8000-0000000027a1');
update public.campania_colportor set meta_libros = 10
 where usuario_id = '01920000-0000-7000-8000-0000000027b2' and campania_id = '01920000-0000-7000-8000-0000000027e1';
select pg_temp.actuar_como_servidor();
select is(pg_temp.historial_de('b2'), 'Norte ->*', 'cambiar meta_libros no toca el historial');

-- Un rechazo pasa antes del UPDATE: no queda nada a medias.
select pg_temp.actuar_como('01920000-0000-7000-8000-0000000027a1');
select throws_ok(
  $$ select public.asignar_zona('01920000-0000-7000-8000-0000000027e1', '01920000-0000-7000-8000-0000000027b6',
                                '01920000-0000-7000-8000-0000000027d1') $$,
  'CZ014', null, 'una cuenta suspendida no recibe zona (CZ014)');
select throws_ok(
  $$ select public.asignar_zona('01920000-0000-7000-8000-0000000027e1', '01920000-0000-7000-8000-0000000027b2',
                                '01920000-0000-7000-8000-0000000027d4') $$,
  'CZ006', null, 'una zona de otra campaña se rechaza (CZ006)');
select pg_temp.actuar_como('01920000-0000-7000-8000-0000000027a2');
select throws_ok(
  $$ select public.asignar_zona('01920000-0000-7000-8000-0000000027e1', '01920000-0000-7000-8000-0000000027b2',
                                '01920000-0000-7000-8000-0000000027d2') $$,
  '42501', null, 'el coordinador de otra campaña no asigna (42501)');
select pg_temp.actuar_como_servidor();
select is(pg_temp.historial_de('b6'), '', 'la cuenta suspendida sigue sin tramos');
select is(pg_temp.historial_de('b2'), 'Norte ->*', 'y b2 sigue con su tramo abierto, sin cambios');

-- ---------------------------------------------------------------------------
-- 5. Dar de baja la zona: los asignados quedan sin zona y su tramo se cierra
-- ---------------------------------------------------------------------------
-- Oeste (d3): b3 y b4 (altas del servidor); b1 estuvo y ya no.
select pg_temp.actuar_como('01920000-0000-7000-8000-0000000027ad');
select lives_ok(
  $$ select public.baja_zona('01920000-0000-7000-8000-0000000027d3') $$,
  'el ADMIN da de baja la zona Oeste');
select pg_temp.actuar_como_servidor();
select is(pg_temp.historial_de('b3'), 'Oeste ->ad', 'baja de la zona: el tramo de b3 se cierra y dice quién la dio de baja');
select is(pg_temp.historial_de('b4'), 'Oeste ->ad', 'y el de b4');
select is(pg_temp.historial_de('b2'), 'Norte ->*', 'quien tiene otra zona no se toca');
select is(pg_temp.historial_de('b1'), 'Norte a1>a1 | Sur a1>ad | Oeste ad>a1 | Norte a1>*',
          'ni b1, que ya no estaba en Oeste');

-- Una inscripción que ya estaba dada de baja con zona (el estado de antes de 0022) la conserva, y su
-- tramo, aunque la zona se dé de baja (0012): el historial sigue a zona_id.
select pg_temp.actuar_como('01920000-0000-7000-8000-0000000027a1');
select lives_ok(
  $$ select public.baja_zona('01920000-0000-7000-8000-0000000027d2') $$,
  'a1 da de baja la zona Sur (b5 la conserva en su inscripción dada de baja)');
select pg_temp.actuar_como_servidor();
select is(pg_temp.historial_de('b5'), 'Sur ->*', 'la inscripción dada de baja conserva la zona y su tramo abierto');
select is((select cc.zona_id from public.campania_colportor cc where cc.usuario_id = '01920000-0000-7000-8000-0000000027b5'),
          '01920000-0000-7000-8000-0000000027d2'::uuid, 'porque su zona_id sigue ahí');

-- ---------------------------------------------------------------------------
-- 5b. Dar de baja la inscripción la deja sin zona y cierra el tramo (decisión de Cristian, 02/10)
-- ---------------------------------------------------------------------------
-- a1 (coordinador, con JWT y por UPDATE directo) saca a b2 de la campaña.
select pg_temp.actuar_como('01920000-0000-7000-8000-0000000027a1');
select lives_ok(
  $$ update public.campania_colportor set deleted_at = now()
      where usuario_id = '01920000-0000-7000-8000-0000000027b2' and campania_id = '01920000-0000-7000-8000-0000000027e1' $$,
  'el coordinador da de baja la inscripción de b2 (que tiene Norte)');
select pg_temp.actuar_como_servidor();
select is((select cc.zona_id from public.campania_colportor cc where cc.usuario_id = '01920000-0000-7000-8000-0000000027b2'),
          null, 'queda sin zona');
select ok((select cc.deleted_at is not null from public.campania_colportor cc where cc.usuario_id = '01920000-0000-7000-8000-0000000027b2'),
          'y la inscripción dada de baja');
select is(pg_temp.historial_de('b2'), 'Norte ->a1', 'el tramo se cierra con quién la sacó (a1) y no abre ninguno');
select ok((select h.hasta is not null and h.hasta >= h.desde from public.campania_colportor_zona_historial h
             join public.campania_colportor cc on cc.id = h.campania_colportor_id
            where cc.usuario_id = '01920000-0000-7000-8000-0000000027b2'),
          'con cuándo (hasta)');

-- Vuelve (el camino del servidor: con JWT, 0005 no deja reactivar): vuelve sin zona y sin tramo.
update public.campania_colportor set deleted_at = null
 where usuario_id = '01920000-0000-7000-8000-0000000027b2' and campania_id = '01920000-0000-7000-8000-0000000027e1';
select is((select cc.zona_id from public.campania_colportor cc where cc.usuario_id = '01920000-0000-7000-8000-0000000027b2'),
          null, 'al reactivarla vuelve sin zona: aparece en «Sin zona», como con «Quitar»');
select is(pg_temp.historial_de('b2'), 'Norte ->a1', 'y reactivar no abre ningún tramo');
select pg_temp.actuar_como('01920000-0000-7000-8000-0000000027b2');
select is((select count(*) from public.mis_zonas()), 0::bigint, 'y no se le abre ninguna zona');
select pg_temp.actuar_como('01920000-0000-7000-8000-0000000027a1');
select lives_ok(
  $$ select public.asignar_zona('01920000-0000-7000-8000-0000000027e1', '01920000-0000-7000-8000-0000000027b2',
                                '01920000-0000-7000-8000-0000000027d1') $$,
  'el coordinador le asigna una zona: vuelve a ser un colportor como cualquiera');
select pg_temp.actuar_como_servidor();
select is(pg_temp.historial_de('b2'), 'Norte ->a1 | Norte a1>*', 'y se abre un tramo nuevo, con quién la asignó');

-- La baja que hace el servidor (sin JWT) también la deja sin zona; el tramo se cierra sin quién.
update public.campania_colportor set deleted_at = now()
 where usuario_id = '01920000-0000-7000-8000-0000000027b1' and campania_id = '01920000-0000-7000-8000-0000000027e1';
select is((select cc.zona_id from public.campania_colportor cc where cc.usuario_id = '01920000-0000-7000-8000-0000000027b1'),
          null, 'la baja del servidor también deja sin zona');
select is(pg_temp.historial_de('b1'), 'Norte a1>a1 | Sur a1>ad | Oeste ad>a1 | Norte a1>-',
          'y cierra el tramo vigente (sin quién: «-»)');
update public.campania_colportor set deleted_at = null
 where usuario_id = '01920000-0000-7000-8000-0000000027b1' and campania_id = '01920000-0000-7000-8000-0000000027e1';

-- Dar de baja a quien no tiene zona no escribe nada; dar de baja de nuevo a la que ya estaba de baja, tampoco.
update public.campania_colportor set deleted_at = now()
 where usuario_id = '01920000-0000-7000-8000-0000000027b6' and campania_id = '01920000-0000-7000-8000-0000000027e1';
select is(pg_temp.tramos_de('b6'), 0::bigint, 'dar de baja una inscripción sin zona no toca el historial');
update public.campania_colportor set deleted_at = null
 where usuario_id = '01920000-0000-7000-8000-0000000027b6' and campania_id = '01920000-0000-7000-8000-0000000027e1';
update public.campania_colportor set deleted_at = now() + interval '1 minute'
 where usuario_id = '01920000-0000-7000-8000-0000000027b5' and campania_id = '01920000-0000-7000-8000-0000000027e1';
select is(pg_temp.historial_de('b5'), 'Sur ->*', 'y la inscripción que ya estaba de baja con zona no se toca');
select is((select cc.zona_id from public.campania_colportor cc where cc.usuario_id = '01920000-0000-7000-8000-0000000027b5'),
          '01920000-0000-7000-8000-0000000027d2'::uuid, 'ni su zona');

-- ---------------------------------------------------------------------------
-- 6. Cualquier otro camino del servidor
-- ---------------------------------------------------------------------------
-- b7 (Otra) sin zona: el servidor le pone una y después se la saca.
update public.campania_colportor set zona_id = '01920000-0000-7000-8000-0000000027d4'
 where usuario_id = '01920000-0000-7000-8000-0000000027b7';
select is(pg_temp.historial_de('b7', 'e2'), 'Otra zona ->*', 'un UPDATE del servidor abre el tramo (sin quién)');
update public.campania_colportor set zona_id = null
 where usuario_id = '01920000-0000-7000-8000-0000000027b7';
select is(pg_temp.historial_de('b7', 'e2'), 'Otra zona ->-', 'y otro lo cierra (sin quién: «-»)');

-- Un reloj que retrocede no tumba el cambio de zona: el tramo abierto con un desde en el futuro
-- se cierra en su propio desde (hasta >= desde, el CHECK).
update public.campania_colportor set zona_id = '01920000-0000-7000-8000-0000000027d4'
 where usuario_id = '01920000-0000-7000-8000-0000000027b7';
update public.campania_colportor_zona_historial set desde = now() + interval '1 hour'
 where hasta is null and campania_colportor_id = (select id from public.campania_colportor
                                                   where usuario_id = '01920000-0000-7000-8000-0000000027b7');
select lives_ok(
  $$ update public.campania_colportor set zona_id = null where usuario_id = '01920000-0000-7000-8000-0000000027b7' $$,
  'cambiar la zona con un tramo abierto que empieza en el futuro no viola el CHECK');
select ok((select h.hasta = h.desde from public.campania_colportor_zona_historial h
            where h.desde > now() + interval '30 minutes' and h.campania_colportor_id = (select id from public.campania_colportor
                                                                   where usuario_id = '01920000-0000-7000-8000-0000000027b7')),
          'y lo cierra en su propio desde');

-- Con el reloj retrocedido, el cambio a OTRA zona: el tramo nuevo no empieza antes de que termine el
-- anterior (b4, que no tiene zona: Norte con un desde en el futuro, y después Este).
update public.campania_colportor set zona_id = '01920000-0000-7000-8000-0000000027d1'
 where usuario_id = '01920000-0000-7000-8000-0000000027b4' and campania_id = '01920000-0000-7000-8000-0000000027e1';
update public.campania_colportor_zona_historial set desde = now() + interval '2 hours'
 where hasta is null and campania_colportor_id = (select id from public.campania_colportor
                                                   where usuario_id = '01920000-0000-7000-8000-0000000027b4');
select lives_ok(
  $$ update public.campania_colportor set zona_id = '01920000-0000-7000-8000-0000000027d5'
      where usuario_id = '01920000-0000-7000-8000-0000000027b4' and campania_id = '01920000-0000-7000-8000-0000000027e1' $$,
  'cambiar a otra zona con un tramo abierto que empieza en el futuro');
select ok((select n.desde >= v.hasta and n.hasta is null
             from public.campania_colportor_zona_historial v, public.campania_colportor_zona_historial n
            where v.campania_colportor_id = n.campania_colportor_id and v.zona_id = '01920000-0000-7000-8000-0000000027d1'
              and v.desde > now() + interval '90 minutes' and n.zona_id = '01920000-0000-7000-8000-0000000027d5'
              and v.campania_colportor_id = (select id from public.campania_colportor
                                              where usuario_id = '01920000-0000-7000-8000-0000000027b4')),
          'el tramo nuevo empieza donde cierra el anterior, no antes');
select is(pg_temp.historial_de('b4'), 'Oeste ->ad | Norte ->- | Este ->*',
          'y el último, por orden de fecha, es el abierto');

-- ---------------------------------------------------------------------------
-- 7. El historial es coherente con la zona actual
-- ---------------------------------------------------------------------------
select is((select count(*)::integer from public.campania_colportor cc
            where cc.zona_id is distinct from (select h.zona_id from public.campania_colportor_zona_historial h
                                                where h.campania_colportor_id = cc.id and h.hasta is null)),
          0, 'toda inscripción tiene abierto exactamente el tramo de su zona actual (o ninguno si no tiene)');
select is((select count(*)::integer from (
             select lead(h.desde) over (partition by h.campania_colportor_id order by h.desde, h.hasta nulls last, h.id) as siguiente, h.hasta
               from public.campania_colportor_zona_historial h) x
            where x.siguiente is not null and (x.hasta is null or x.siguiente < x.hasta)),
          0, 'ningún tramo se superpone con el siguiente');

-- A lo sumo uno abierto por inscripción; el orden y el cierre se validan.
select throws_ok(
  $$ insert into public.campania_colportor_zona_historial (campania_colportor_id, zona_id, desde)
     select id, '01920000-0000-7000-8000-0000000027d1', now() from public.campania_colportor
      where usuario_id = '01920000-0000-7000-8000-0000000027b2' $$,
  '23505', null, 'un segundo tramo abierto para la misma inscripción se rechaza');
select throws_ok(
  $$ insert into public.campania_colportor_zona_historial (campania_colportor_id, zona_id, desde, hasta)
     select id, '01920000-0000-7000-8000-0000000027d1', now(), now() - interval '1 day' from public.campania_colportor
      where usuario_id = '01920000-0000-7000-8000-0000000027b2' $$,
  '23514', null, 'hasta no puede ser anterior a desde');
select throws_ok(
  $$ insert into public.campania_colportor_zona_historial (campania_colportor_id, zona_id, desde, cerrada_por)
     select id, '01920000-0000-7000-8000-0000000027d1', now(), '01920000-0000-7000-8000-0000000027a1'
       from public.campania_colportor where usuario_id = '01920000-0000-7000-8000-0000000027b1' $$,
  '23514', null, 'quién cerró solo tiene sentido en un tramo cerrado');

-- ---------------------------------------------------------------------------
-- 8. Quién lo lee: el ADMIN y el coordinador de la campaña
-- ---------------------------------------------------------------------------
create temp table esperado on commit drop as
select
  (select count(*) from public.campania_colportor_zona_historial h
     join public.campania_colportor cc on cc.id = h.campania_colportor_id
    where cc.campania_id = '01920000-0000-7000-8000-0000000027e1') as e1,
  (select count(*) from public.campania_colportor_zona_historial h
     join public.campania_colportor cc on cc.id = h.campania_colportor_id
    where cc.campania_id = '01920000-0000-7000-8000-0000000027e2') as e2;
grant select on esperado to authenticated;

select pg_temp.actuar_como('01920000-0000-7000-8000-0000000027a1');
select is((select count(*) from public.campania_colportor_zona_historial h
             join public.campania_colportor cc on cc.id = h.campania_colportor_id
            where cc.campania_id = '01920000-0000-7000-8000-0000000027e1'),
          (select e1 from esperado), 'a1 lee el historial de todas las inscripciones de su campaña');
select is((select count(*) from public.campania_colportor_zona_historial h
             join public.campania_colportor cc on cc.id = h.campania_colportor_id
            where cc.campania_id = '01920000-0000-7000-8000-0000000027e2'),
          0::bigint, 'y nada del de otra campaña');

select pg_temp.actuar_como('01920000-0000-7000-8000-0000000027a2');
select is((select count(*) from public.campania_colportor_zona_historial h
             join public.campania_colportor cc on cc.id = h.campania_colportor_id
            where cc.campania_id = '01920000-0000-7000-8000-0000000027e2'),
          (select e2 from esperado), 'a2 lee el de su campaña');
select is((select count(*) from public.campania_colportor_zona_historial h
             join public.campania_colportor cc on cc.id = h.campania_colportor_id
            where cc.campania_id = '01920000-0000-7000-8000-0000000027e1'),
          0::bigint, 'y nada del de Verano');

select pg_temp.actuar_como('01920000-0000-7000-8000-0000000027ad');
select is((select count(*) from public.campania_colportor_zona_historial),
          (select e1 + e2 from esperado), 'el ADMIN lee todo');

select pg_temp.actuar_como('01920000-0000-7000-8000-0000000027b1');
select is((select count(*) from public.campania_colportor_zona_historial),
          0::bigint, 'un colportor no lee el historial, ni el suyo');
select is((select count(*) from public.campania_colportor where usuario_id = '01920000-0000-7000-8000-0000000027b1'),
          1::bigint, 'aunque sí su inscripción');

select pg_temp.actuar_como_anon();
select throws_ok($$ select count(*) from public.campania_colportor_zona_historial $$,
                 '42501', null, 'anon no lee (sin privilegio)');

-- Nadie escribe directo, tampoco el coordinador ni el ADMIN.
select pg_temp.actuar_como('01920000-0000-7000-8000-0000000027a1');
select throws_ok(
  $$ insert into public.campania_colportor_zona_historial (campania_colportor_id, zona_id, desde)
     select id, '01920000-0000-7000-8000-0000000027d1', now() from public.campania_colportor
      where usuario_id = '01920000-0000-7000-8000-0000000027b1' $$,
  '42501', null, 'el coordinador no inserta en el historial');
select throws_ok(
  $$ update public.campania_colportor_zona_historial set hasta = now() $$,
  '42501', null, 'ni lo actualiza');
select throws_ok(
  $$ delete from public.campania_colportor_zona_historial $$,
  '42501', null, 'ni lo borra');
select pg_temp.actuar_como('01920000-0000-7000-8000-0000000027ad');
select throws_ok(
  $$ update public.campania_colportor_zona_historial set zona_id = '01920000-0000-7000-8000-0000000027d1' $$,
  '42501', null, 'el ADMIN tampoco lo reescribe');

-- ---------------------------------------------------------------------------
-- 9. Si la inscripción se elimina (la persona se borra), su historial cae con ella
-- ---------------------------------------------------------------------------
select pg_temp.actuar_como_servidor();
insert into public.campania_colportor (campania_id, usuario_id, zona_id) values
  ('01920000-0000-7000-8000-0000000027e1', '01920000-0000-7000-8000-0000000027b8', '01920000-0000-7000-8000-0000000027d1');
select is(pg_temp.historial_de('b8'), 'Norte ->*', 'b8 entra con Norte');
delete from public.campania_colportor where usuario_id = '01920000-0000-7000-8000-0000000027b8';
select is((select count(*)::integer from public.campania_colportor_zona_historial h
            where not exists (select 1 from public.campania_colportor cc where cc.id = h.campania_colportor_id)),
          0, 'borrar la inscripción borra su historial: no queda ningún tramo huérfano');

-- ---------------------------------------------------------------------------
-- 10. Borrar al usuario que asignó y después cambió la zona (revisión del PR #60)
-- ---------------------------------------------------------------------------
-- Con created_by y cerrada_por en el mismo tramo, el borrado fallaba con 23503: tg_auditoria_update
-- deshacía el ON DELETE SET NULL de created_by y el de cerrada_por revisaba todas las FK de la fila.
insert into auth.users (id, instance_id, aud, role, email, encrypted_password, confirmed_at, created_at, updated_at)
select ('01920000-0000-7000-8000-0000000027' || s)::uuid, '00000000-0000-0000-0000-000000000000',
       'authenticated', 'authenticated', 'hz-' || s || '@example.com', 'x', now(), now(), now()
  from unnest(array['ae','af','b9','ba']) s;
insert into public.usuario_rol (usuario_id, rol_id)
select ('01920000-0000-7000-8000-0000000027' || x.s)::uuid, r.id
  from (values ('ae'), ('af')) x(s) join public.rol r on r.codigo = 'ADMIN';
insert into public.campania_colportor (campania_id, usuario_id, zona_id) values
  ('01920000-0000-7000-8000-0000000027e1', '01920000-0000-7000-8000-0000000027b9', '01920000-0000-7000-8000-0000000027d1'),
  ('01920000-0000-7000-8000-0000000027e1', '01920000-0000-7000-8000-0000000027ba', '01920000-0000-7000-8000-0000000027d1');

-- ae le cambia la zona a b9 dos veces: el tramo Este lo asignó y lo cerró él.
select pg_temp.actuar_como('01920000-0000-7000-8000-0000000027ae');
select lives_ok(
  $$ select public.asignar_zona('01920000-0000-7000-8000-0000000027e1', '01920000-0000-7000-8000-0000000027b9',
                                '01920000-0000-7000-8000-0000000027d5') $$,
  'ae le cambia a b9 la zona a Este');
select lives_ok(
  $$ select public.asignar_zona('01920000-0000-7000-8000-0000000027e1', '01920000-0000-7000-8000-0000000027b9',
                                '01920000-0000-7000-8000-0000000027d1') $$,
  'y después otra vez a Norte');
select pg_temp.actuar_como_servidor();
select is(pg_temp.historial_de('b9'), 'Norte ->ae | Este ae>ae | Norte ae>*', 'el tramo Este lo asignó y lo cerró ae');
select lives_ok($$ delete from auth.users where id = '01920000-0000-7000-8000-0000000027ae' $$,
                'se puede borrar al usuario que asignó y cerró tramos');
select is(pg_temp.historial_de('b9'), 'Norte ->- | Este ->- | Norte ->*',
          'sus tramos siguen, con created_by y cerrada_por en null');
select is((select count(*)::integer from public.campania_colportor_zona_historial h
            where h.created_by = '01920000-0000-7000-8000-0000000027ae' or h.cerrada_por = '01920000-0000-7000-8000-0000000027ae'),
          0, 'ningún tramo apunta a un usuario que ya no existe');

-- Lo mismo si el usuario cerró un tramo y abrió otro distinto, y después cae el colportor.
select pg_temp.actuar_como('01920000-0000-7000-8000-0000000027af');
select lives_ok(
  $$ select public.asignar_zona('01920000-0000-7000-8000-0000000027e1', '01920000-0000-7000-8000-0000000027ba',
                                '01920000-0000-7000-8000-0000000027d5') $$,
  'af le cambia a ba la zona');
select pg_temp.actuar_como_servidor();
select lives_ok($$ delete from auth.users where id = '01920000-0000-7000-8000-0000000027af' $$,
                'se puede borrar al usuario que cerró un tramo y abrió otro');
select is(pg_temp.historial_de('ba'), 'Norte ->- | Este ->*',
          'los tramos de ba siguen, sin quién (null) y el vigente abierto');
select lives_ok($$ delete from auth.users where id = '01920000-0000-7000-8000-0000000027ba' $$,
                'y después se puede borrar al colportor');
select is((select count(*)::integer from public.campania_colportor_zona_historial h
            where not exists (select 1 from public.campania_colportor cc where cc.id = h.campania_colportor_id)),
          0, 'y no queda ningún tramo huérfano');

select * from finish();
rollback;
