-- pgTAP · migración 0134 (backend-supabase#182, HU-COB-007/009, RF-CO08A): la foto del ticket vive en Cloudflare R2 y
-- los permisos salen de la base.
--   1. Los privilegios de las funciones nuevas (la sesión las llama; el servidor suelta lo vencido).
--   2. Cuándo vence una foto (una sola definición, con su borde).
--   3. Ver: la dueña, el ADMIN y quien coordina la campaña del ticket reciben la ruta; los demás no averiguan nada
--      (mismo error que un ticket inexistente); sin foto, vencida o sin sesión, el aviso que corresponde.
--   4. Subir: la carpeta es la de quien llama; extensiones válidas; nadie sube a la carpeta de otra.
--   5. La base deja de apuntar a la foto vencida: `soltar_fotos_vencidas()` y su tarea diaria en pg_cron.
-- La parte de Storage (las políticas del bucket `tickets` ya no están) está en 0113_bucket_tickets_test.sql. Va en
-- una transacción.
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
create or replace function pg_temp.actuar_sin_sesion() returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', json_build_object('role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', '', true);
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

-- Ids (prefijo 34): usuarios 34b1.., tickets 34c1.., campañas 34e1...
create or replace function pg_temp.u(p text) returns uuid language sql as $$
  select ('01920000-0000-7000-8000-00000000' || '34' || p)::uuid;
$$;
-- La ruta que da ver (o «ERR <sqlstate>» si falla), de un ticket.
create or replace function pg_temp.ver(p_ticket uuid) returns text language plpgsql as $$
begin
  return public.ruta_para_ver_foto_de_ticket(p_ticket);
exception when others then
  return 'ERR ' || sqlstate;
end $$;
-- Lo mismo para subir.
create or replace function pg_temp.subir(p_ticket uuid, p_ext text) returns text language plpgsql as $$
begin
  return public.ruta_para_subir_foto_de_ticket(p_ticket, p_ext);
exception when others then
  return 'ERR ' || sqlstate;
end $$;
-- El mensaje de lo que falla («ok» si anduvo).
create or replace function pg_temp.mensaje_de(p_sql text) returns text language plpgsql as $$
begin
  execute p_sql;
  return 'ok';
exception when others then
  return sqlerrm;
end $$;

-- --- fixtures (como postgres) --------------------------------------------------
-- b1 y b2 colportoras; c1 coordinador de la campaña e1 (con b1), c2 de e2 (con b2); ad ADMIN.
insert into auth.users (id, instance_id, aud, role, email, encrypted_password, confirmed_at, created_at, updated_at)
select pg_temp.u(s), '00000000-0000-0000-0000-000000000000',
       'authenticated', 'authenticated', 'r2-' || s || '@example.com', 'x', now(), now(), now()
  from unnest(array['b1','b2','c1','c2','ad']) s;
insert into public.usuario_rol (usuario_id, rol_id)
select pg_temp.u(x.s), r.id
  from (values ('b1','COLPORTOR'), ('b2','COLPORTOR'), ('c1','COORDINADOR'), ('c2','COORDINADOR'), ('ad','ADMIN')) x(s, codigo)
  join public.rol r on r.codigo = x.codigo;
insert into public.campania (id, nombre, tipo, fecha_inicio, fecha_fin, coordinador_id) values
  (pg_temp.u('e1'), 'e1 r2', 'VERANO', public.hoy_montevideo() - 10, public.hoy_montevideo() + 30, pg_temp.u('c1')),
  (pg_temp.u('e2'), 'e2 r2', 'VERANO', public.hoy_montevideo() - 10, public.hoy_montevideo() + 30, pg_temp.u('c2'));
insert into public.campania_colportor (campania_id, usuario_id, created_at) values
  (pg_temp.u('e1'), pg_temp.u('b1'), now() - interval '8 days'), (pg_temp.u('e2'), pg_temp.u('b2'), now() - interval '8 days');
-- Tickets (todos cobrados hace 2 días, dentro de la ventana de su campaña):
--   c1 de b1 con foto; c2 de b1 sin foto; c3 de b1 con foto, subido hace 5 meses (vencida); c4 de b1 subido hace
--   5 meses cuya ruta ya se soltó; c5 de b1 con foto, subido hace 110 días (todavía vive); c6 de b2 con foto.
insert into public.ticket (id, usuario_id, tipo, subido_en, monto, fecha, estado, url_cloud)
select pg_temp.u(x.t), pg_temp.u(x.b), 'DEPOSITO', now() - x.antiguedad, 1000, now() - interval '2 days', 'PENDIENTE',
       case when x.con_foto then pg_temp.u(x.b)::text || '/' || pg_temp.u(x.t)::text || '.jpg' end
  from (values ('c1', 'b1', interval '2 days', true),
               ('c2', 'b1', interval '2 days', false),
               ('c3', 'b1', interval '5 months', true),
               ('c4', 'b1', interval '5 months', false),
               ('c5', 'b1', interval '110 days', true),
               ('c6', 'b2', interval '2 days', true)) x(t, b, antiguedad, con_foto);

-- --- 1. Privilegios --------------------------------------------------------------
select is(has_function_privilege(r, 'public.ruta_para_ver_foto_de_ticket(uuid)', 'execute'), e,
          format('ruta_para_ver_foto_de_ticket: %s %s', r, case when e then 'sí' else 'no' end))
  from (values ('anon', false), ('authenticated', true), ('service_role', false)) x(r, e);
select is(has_function_privilege(r, 'public.ruta_para_subir_foto_de_ticket(uuid, text)', 'execute'), e,
          format('ruta_para_subir_foto_de_ticket: %s %s', r, case when e then 'sí' else 'no' end))
  from (values ('anon', false), ('authenticated', true), ('service_role', false)) x(r, e);
select is(has_function_privilege(r, 'public.soltar_fotos_vencidas(timestamptz)', 'execute'), e,
          format('soltar_fotos_vencidas: %s %s', r, case when e then 'sí' else 'no' end))
  from (values ('anon', false), ('authenticated', false), ('service_role', true)) x(r, e);
select is(has_function_privilege('anon', 'public.foto_de_ticket_vencida(timestamptz, timestamptz)', 'execute'), false,
          'anon no ejecuta foto_de_ticket_vencida');
select is((select p.prosecdef from pg_proc p where p.oid = 'public.ruta_para_ver_foto_de_ticket(uuid)'::regprocedure), false,
          'ver es SECURITY INVOKER: el permiso lo da la RLS de ticket_select');
select is((select p.prosecdef from pg_proc p where p.oid = 'public.ruta_para_subir_foto_de_ticket(uuid, text)'::regprocedure), false,
          'subir es SECURITY INVOKER');

-- --- 2. Cuándo vence --------------------------------------------------------------
select is(public.foto_de_ticket_vencida(timestamptz '2026-06-28 12:00+00', timestamptz '2026-10-28 12:00+00'), true,
          'justo a los 4 meses ya venció (el borde cuenta)');
select is(public.foto_de_ticket_vencida(timestamptz '2026-06-28 12:00+00', timestamptz '2026-10-28 11:59:59+00'), false,
          'un segundo antes, no');
select is(public.foto_de_ticket_vencida(timestamptz '2026-10-27 12:00+00', timestamptz '2026-10-28 12:00+00'), false,
          'una foto de ayer no venció');
select is(public.foto_de_ticket_vencida(null), false, 'sin fecha de subida no vence (no se adivina)');

-- --- 3. Ver ---------------------------------------------------------------------------
select pg_temp.actuar_como(pg_temp.u('b1'));
select is(pg_temp.ver(pg_temp.u('c1')), pg_temp.u('b1')::text || '/' || pg_temp.u('c1')::text || '.jpg',
          'la dueña recibe la ruta de la foto de su ticket (la clave del objeto en R2)');
select is(pg_temp.ver(pg_temp.u('c5')), pg_temp.u('b1')::text || '/' || pg_temp.u('c5')::text || '.jpg',
          'a los 110 días la foto todavía vive');
select is(pg_temp.ver(pg_temp.u('c6')), 'ERR FT001', 'la foto del ticket de otra colportora: no existe para ella');
select is(pg_temp.ver(pg_temp.u('ff')), 'ERR FT001', 'un ticket que no existe da el mismo error (no se averigua cuáles hay)');
select is(pg_temp.ver(pg_temp.u('c2')), 'ERR FT002', 'un ticket sin foto: todavía no tiene foto');
select is(pg_temp.ver(pg_temp.u('c3')), 'ERR FT003', 'una foto de hace 5 meses: venció, aunque la ruta siga puesta');
select is(pg_temp.ver(pg_temp.u('c4')), 'ERR FT003', 'y si la ruta ya se soltó, también «venció» y no «no tiene»');
select is(pg_temp.ver(null), 'ERR FT001', 'sin ticket, no existe');
select is(pg_temp.mensaje_de($$ select public.ruta_para_ver_foto_de_ticket(pg_temp.u('c3')) $$),
          'La foto de este ticket ya venció: se guarda 4 meses. Los datos del ticket siguen en el historial.',
          'el aviso de la foto vencida dice qué pasó y que los datos siguen');
select is(pg_temp.mensaje_de($$ select public.ruta_para_ver_foto_de_ticket(pg_temp.u('c6')) $$),
          'No encontramos ese ticket o no tenés permiso para ver su foto.', 'el aviso del ticket ajeno');

select pg_temp.actuar_como(pg_temp.u('c1'));
select is(pg_temp.ver(pg_temp.u('c1')), pg_temp.u('b1')::text || '/' || pg_temp.u('c1')::text || '.jpg',
          'el coordinador de la campaña de b1 ve la foto del ticket de b1 (para validar)');
select is(pg_temp.ver(pg_temp.u('c6')), 'ERR FT001', 'no la del ticket de la colportora de otra campaña');
select pg_temp.actuar_como(pg_temp.u('c2'));
select is(pg_temp.ver(pg_temp.u('c1')), 'ERR FT001', 'el coordinador de otra campaña no ve la foto de b1');
select is(pg_temp.ver(pg_temp.u('c6')), pg_temp.u('b2')::text || '/' || pg_temp.u('c6')::text || '.jpg', 'sí la de b2, de su campaña');
select pg_temp.actuar_como(pg_temp.u('b2'));
select is(pg_temp.ver(pg_temp.u('c1')), 'ERR FT001', 'b2 no ve la foto de b1');
select pg_temp.actuar_como(pg_temp.u('ad'));
select is(pg_temp.ver(pg_temp.u('c1')), pg_temp.u('b1')::text || '/' || pg_temp.u('c1')::text || '.jpg', 'el ADMIN ve la de b1');
select is(pg_temp.ver(pg_temp.u('c6')), pg_temp.u('b2')::text || '/' || pg_temp.u('c6')::text || '.jpg', 'y la de b2');

select pg_temp.actuar_sin_sesion();
select is(pg_temp.ver(pg_temp.u('c1')), 'ERR 42501', 'sin sesión (JWT sin usuario): 42501');
select pg_temp.actuar_como_anon();
select is(pg_temp.ver(pg_temp.u('c1')), 'ERR 42501', 'anon no ejecuta la función: 42501');

-- Un coordinador que dio de baja a la colportora de su campaña sigue viendo lo que subió (la ventana cuenta la baja).
select pg_temp.actuar_como_servidor();
update public.campania_colportor set deleted_at = now() where campania_id = pg_temp.u('e1') and usuario_id = pg_temp.u('b1');
select pg_temp.actuar_como(pg_temp.u('c1'));
select is(pg_temp.ver(pg_temp.u('c1')), pg_temp.u('b1')::text || '/' || pg_temp.u('c1')::text || '.jpg',
          'con la colportora de baja, su coordinador sigue viendo lo que subió');
select pg_temp.actuar_como_servidor();

-- --- 4. Subir ---------------------------------------------------------------------------
select pg_temp.actuar_como(pg_temp.u('b1'));
select is(pg_temp.subir(pg_temp.u('c2'), 'jpg'), pg_temp.u('b1')::text || '/' || pg_temp.u('c2')::text || '.jpg',
          'b1 sube la foto de su ticket sin foto: a su carpeta, con el id del ticket');
select is(pg_temp.subir(pg_temp.u('c2'), 'png'), pg_temp.u('b1')::text || '/' || pg_temp.u('c2')::text || '.png', 'también png');
select is(pg_temp.subir(pg_temp.u('c2'), 'webp'), pg_temp.u('b1')::text || '/' || pg_temp.u('c2')::text || '.webp', 'y webp');
select is(pg_temp.subir(pg_temp.u('d1'), 'jpg'), pg_temp.u('b1')::text || '/' || pg_temp.u('d1')::text || '.jpg',
          'la foto puede subir antes que su ticket (el motor sube en el orden que puede)');
select is(pg_temp.subir(pg_temp.u('c2'), 'gif'), 'ERR 22023', 'un gif no');
select is(pg_temp.subir(pg_temp.u('c2'), 'jpeg'), 'ERR 22023', 'la extensión es jpg (la ruta de url_cloud admite .jpeg, la subida no la genera)');
select is(pg_temp.subir(pg_temp.u('c2'), 'JPG'), 'ERR 22023', 'ni en mayúsculas');
select is(pg_temp.subir(pg_temp.u('c2'), null), 'ERR 22023', 'sin extensión no');
select is(pg_temp.subir(null, 'jpg'), 'ERR 22023', 'ni sin ticket');
select is(pg_temp.subir(pg_temp.u('c3'), 'jpg'), 'ERR FT003', 'el ticket de hace 5 meses ya no admite foto');
select is(pg_temp.mensaje_de($$ select public.ruta_para_subir_foto_de_ticket(pg_temp.u('c3'), 'jpg') $$),
          'La foto de este ticket ya venció: se guarda 4 meses. No hace falta subirla.', 'con su aviso');
select pg_temp.actuar_como(pg_temp.u('b2'));
select is(pg_temp.subir(pg_temp.u('c2'), 'jpg'), pg_temp.u('b2')::text || '/' || pg_temp.u('c2')::text || '.jpg',
          'b2 nombrando un ticket de b1 sube a SU carpeta: nunca a la de b1 (la carpeta sale de la sesión)');
select is(pg_temp.subir(pg_temp.u('c3'), 'jpg'), pg_temp.u('b2')::text || '/' || pg_temp.u('c3')::text || '.jpg',
          'b2 nombrando el ticket VENCIDO de b1 recibe su propia ruta: no se entera de que ese ticket existe ni de su edad');
select pg_temp.actuar_como(pg_temp.u('c1'));
select is(pg_temp.subir(pg_temp.u('c2'), 'jpg'), pg_temp.u('c1')::text || '/' || pg_temp.u('c2')::text || '.jpg',
          'tampoco el coordinador sube a la carpeta de la colportora');
select pg_temp.actuar_como(pg_temp.u('ad'));
select is(pg_temp.subir(pg_temp.u('c3'), 'jpg'), pg_temp.u('ad')::text || '/' || pg_temp.u('c3')::text || '.jpg',
          'el ADMIN, que sí ve el ticket vencido de b1, sube a su carpeta y no recibe el aviso del ticket ajeno (la RLS lo deja verlo: el filtro por dueña es explícito)');
select pg_temp.actuar_sin_sesion();
select is(pg_temp.subir(pg_temp.u('c2'), 'jpg'), 'ERR 42501', 'sin sesión no se firma nada');
select pg_temp.actuar_como_anon();
select is(pg_temp.subir(pg_temp.u('c2'), 'jpg'), 'ERR 42501', 'anon tampoco');
select pg_temp.actuar_como_servidor();

-- --- 5. La base deja de apuntar a la foto vencida -------------------------------------------
select is((select array_agg(right(ticket_id::text, 2) order by ticket_id) from public.tickets_con_foto_vencida()),
          array['c3'], 'vencida: solo la de hace 5 meses con ruta (la de 110 días vive; la ya soltada no figura)');
select is((select array_agg(right(ticket_id::text, 2) order by ticket_id)
             from public.tickets_con_foto_vencida(now() + interval '30 days')),
          array['c3', 'c5'], 'con otra hora de corte: 30 días después vence también la de 110 días');

select pg_temp.actuar_como(pg_temp.u('b1'));
select is(pg_temp.mensaje_de($$ select public.soltar_fotos_vencidas() $$) like 'permission denied%', true,
          'la dueña no corre la suelta (no es de la API)');
select pg_temp.actuar_como_servidor();

select is(public.soltar_fotos_vencidas(), 1, 'suelta la foto vencida y cuenta una');
select is((select url_cloud from public.ticket where id = pg_temp.u('c3')), null, 'el ticket queda sin ruta');
select is((select monto from public.ticket where id = pg_temp.u('c3')), 1000::bigint, 'y conserva sus datos');
select is((select estado from public.ticket where id = pg_temp.u('c3')), 'PENDIENTE', 'y su estado');
select is((select count(*)::int from public.ticket where url_cloud is not null and id in (pg_temp.u('c1'), pg_temp.u('c5'), pg_temp.u('c6'))),
          3, 'las fotos que viven siguen apuntadas');
select is(public.soltar_fotos_vencidas(), 0, 'otra vez: no hay nada que soltar (idempotente)');
select is(public.soltar_fotos_vencidas(now() + interval '30 days'), 1, 'con otra hora de corte suelta la de 110 días');

-- La tarea diaria.
select is((select count(*)::int from cron.job where jobname = 'tickets-soltar-fotos-vencidas'), 1,
          'la suelta diaria está agendada en pg_cron');
select is((select schedule from cron.job where jobname = 'tickets-soltar-fotos-vencidas'), '47 4 * * *',
          'a las 4:47 UTC, de madrugada en Uruguay');
select is((select trim(command) from cron.job where jobname = 'tickets-soltar-fotos-vencidas'),
          'select public.soltar_fotos_vencidas();', 'y corre la función');

select * from finish();
rollback;
