-- ============================================================================
-- Da a colportor.demo ciudad, campaña, zona, precios, stock y dos semanas de actividad (backend-supabase#286)
--
-- Por qué: los evaluadores entraron a la app con colportor.demo y «no había ciudades»: la cuenta existe en el proyecto
-- (la crea Auth, no el seed), pero no estaba inscripta en ninguna campaña viva, y sin inscripción el teléfono no baja
-- ninguna ciudad ni zona. Es el espejo de sumar-coordinador-demo.sql, para el lado del colportor.
--
-- Qué hace (solo si colportor.demo@example.com existe, está vivo y tiene el rol COLPORTOR, y la demo base ya está cargada):
--   · la inscribe en la campaña de verano de la demo (Verano 2026-27, la de Montevideo, Maldonado y Salto), en la zona
--     Pocitos de Montevideo. Con eso la app ve la campaña, sus ciudades con su mapa, la zona y los precios (el general y
--     los de la ciudad que tenga la campaña). La fecha de alta es el 14/09 (como la de los demás colportores de la
--     demo), no la de la carga, y el primer tramo del historial de zonas empieza ese mismo día.
--   · le deja stock inicial (ajuste STOCK_INICIAL, el mismo movimiento que registra la app) para poder cargar una venta
--     con entrega: 12 ejemplares de cada libro, 20 de cada revista, 20 folletos y 12 devocionales.
--   · le arma dos semanas de trabajo (hasta el 17/11, de lunes a sábado): jornadas, visitas a las casas de Pocitos,
--     unas pocas ventas con sus renglones y cobros en efectivo (al contado o en parte, con clientes que quedan debiendo),
--     y suma esos cobros a la cuenta de saldo de la colportora si la tiene viva (si no tiene cuenta, la crea).
--
-- Reglas: solo agrega (INSERT … ON CONFLICT DO NOTHING; el único UPDATE es el de la cuenta de saldo y el del primer tramo
-- del historial de zona de la inscripción recién creada); nunca DELETE, TRUNCATE ni cambios de esquema. Todo lo que crea
-- lleva el prefijo de la demo (5eed0000-0000-7000-8…), así que retirar-demo-datos.sql lo da de baja con el resto de la
-- demo (el usuario colportor.demo, que no es de la demo generada, se queda). Idempotente: si ya hay jornadas de esta carga,
-- avisa y no hace nada. Si colportor.demo ya tiene inscripción (viva o dada de baja) en la campaña de verano, no la toca:
-- avisa y se detiene (una baja se revierte con inscribir_colportor(), no con un INSERT). Sin colportor.demo (la base local,
-- CI) no hace nada. No toca contraseñas ni Auth.
--
-- Cómo se corre: scripts/db-seed-demo.sh [--remoto] --colportor (en remoto, solo el proyecto de demo).
-- ============================================================================

do $colportor_demo$
declare
  v_usr     uuid;
  v_camp    constant uuid := '5eed0000-0000-7000-8003-000000000001';  -- campaña de verano de la demo
  v_zona    constant uuid := '5eed0000-0000-7000-8004-000000000001';  -- Pocitos (Montevideo)
  v_ins     constant uuid := '5eed0000-0000-7000-800b-000000990001';
  v_corte   constant timestamptz := timestamptz '2026-11-17 23:59:00+00';
  v_d0      constant date := date '2026-09-14';
  v_en_mano bigint;
  v_cobrar  bigint;
  v_nj      int;
  v_nv      int;
begin
  create or replace function pg_temp.cdid(p_tabla int, p_n bigint) returns uuid
    language sql immutable as $f$
      select ('5eed0000-0000-7000-8' || lpad(to_hex(p_tabla), 3, '0') || '-' || lpad(to_hex(p_n), 12, '0'))::uuid
    $f$;
  create or replace function pg_temp.crnd(p_clave text) returns double precision
    language sql immutable as $f$
      select (('x' || substr(md5(p_clave), 1, 7))::bit(28)::int)::double precision / 268435456.0
    $f$;

  -- Dos cargas a la vez no deben pasar juntas las guardas: la segunda espera a la primera y ve lo que dejó.
  perform pg_advisory_xact_lock(hashtext('colportores.seed-demo'));

  select u.id into v_usr
    from public.usuario u
   where lower(u.email) = 'colportor.demo@example.com'
     and u.deleted_at is null
     and exists (select 1
                   from public.usuario_rol ur
                   join public.rol r on r.id = ur.rol_id
                  where ur.usuario_id = u.id and ur.deleted_at is null and r.codigo = 'COLPORTOR');
  if v_usr is null then
    raise notice 'colportor.demo no existe o no es colportor en esta base: no se carga nada.';
    return;
  end if;
  if not exists (select 1 from public.campania c where c.id = v_camp and c.deleted_at is null)
     or not exists (select 1 from public.zona z where z.id = v_zona and z.deleted_at is null) then
    raise notice 'Falta la demo base (campaña de verano y zona Pocitos): cargá demo-datos.sql primero. No se cambió nada.';
    return;
  end if;
  if exists (select 1 from public.jornada j where j.id = pg_temp.cdid(15, 99000001)) then
    raise notice 'colportor.demo ya tiene su actividad de demo cargada. No se cambió nada.';
    return;
  end if;
  if exists (select 1 from public.campania_colportor cc where cc.campania_id = v_camp and cc.usuario_id = v_usr) then
    raise notice 'colportor.demo ya tiene inscripción (viva o dada de baja) en la campaña de verano de la demo: no se toca. Si está de baja, se revierte con inscribir_colportor().';
    return;
  end if;

  -- --------------------------------------------------------------------------------------------------
  -- 1. Inscripción: campaña, ciudad y zona (la fecha de alta es el primer día, no la de la carga)
  -- --------------------------------------------------------------------------------------------------
  insert into public.campania_colportor (id, campania_id, usuario_id, zona_id, created_at)
  values (v_ins, v_camp, v_usr, v_zona, v_d0::timestamp at time zone 'America/Montevideo')
  on conflict do nothing;
  -- El trigger del historial (0022) abre el primer tramo de zona con la hora de la carga: empieza el mismo día.
  update public.campania_colportor_zona_historial h
     set desde = v_d0::timestamp at time zone 'America/Montevideo'
   where h.campania_colportor_id = v_ins
     and h.deleted_at is null
     and h.desde > v_d0::timestamp at time zone 'America/Montevideo'
     and not exists (select 1 from public.campania_colportor_zona_historial h2
                      where h2.campania_colportor_id = h.campania_colportor_id and h2.desde < h.desde);

  -- --------------------------------------------------------------------------------------------------
  -- 2. Stock inicial: el ajuste que registra la app (el disparador suma al stock y audita)
  -- --------------------------------------------------------------------------------------------------
  insert into public.movimiento_stock (id, usuario_id, producto_id, tipo, cantidad, fecha, motivo)
  select pg_temp.cdid(25, 99000000 + p.code), v_usr, pg_temp.cdid(5, p.code), 'AJUSTE_ENTRADA',
         case when p.code in (7, 8, 10) then 20 else 12 end, timestamptz '2026-09-14 15:00:00+00', 'STOCK_INICIAL'
    from generate_series(1, 10) p(code)
   where exists (select 1 from public.producto pr where pr.id = pg_temp.cdid(5, p.code) and pr.deleted_at is null)
  on conflict do nothing;

  -- --------------------------------------------------------------------------------------------------
  -- 3. Dos semanas de trabajo en Pocitos (lunes a sábado hasta el 17/11): jornadas y visitas
  -- --------------------------------------------------------------------------------------------------
  create temp table tc_jor (id uuid primary key, dia date, dn int, inicio timestamptz, fin timestamptz, nvis int) on commit drop;
  insert into tc_jor (id, dia, dn, inicio, fin, nvis)
  select pg_temp.cdid(15, 99000000 + d.n), d.dia, d.n,
         (d.dia::timestamp + interval '12 hours 30 minutes' + (floor(pg_temp.crnd('cji' || d.n) * 60) || ' minutes')::interval) at time zone 'UTC',
         (d.dia::timestamp + interval '12 hours 30 minutes' + (floor(pg_temp.crnd('cji' || d.n) * 60) || ' minutes')::interval
            + ((200 + floor(pg_temp.crnd('cjf' || d.n) * 100)) || ' minutes')::interval) at time zone 'UTC',
         5 + floor(pg_temp.crnd('cjn' || d.n) * 4)::int
    from (select row_number() over (order by g.dia)::int n, g.dia
            from generate_series(date '2026-11-02', date '2026-11-17', interval '1 day') x(ts)
            cross join lateral (select x.ts::date as dia) g
           where extract(dow from g.dia) <> 0) d;

  create temp table tc_vis (id uuid primary key, jor uuid, fecha timestamptz, esp bigint, res text) on commit drop;
  insert into tc_vis (id, jor, fecha, esp, res)
  select pg_temp.cdid(14, 99000000 + j.dn * 100 + k.k), j.id,
         j.inicio + ((k.k - 1) * 30 || ' minutes')::interval + (floor(pg_temp.crnd('cvm' || j.id || k.k) * 8) || ' minutes')::interval,
         (100 + u.j) * 10 + case when u.j % 9 = 0 then 1 + floor(pg_temp.crnd('cve' || j.id || k.k) * 3)::int else 1 end,
         case when pg_temp.crnd('cvr' || j.id || k.k) < 0.25 then 'VENTA'
              when pg_temp.crnd('cvr' || j.id || k.k) < 0.40 then 'ENTREVISTA'
              when pg_temp.crnd('cvr' || j.id || k.k) < 0.55 then 'RECHAZO'
              else 'NO_CONTESTO' end
    from tc_jor j
    cross join lateral generate_series(1, j.nvis) k(k)
    cross join lateral (select 1 + floor(pg_temp.crnd('cvu' || j.id || k.k) * 36)::int as j) u
   where exists (select 1 from public.espacio e where e.id = pg_temp.cdid(13, (100 + u.j) * 10 + 1));
  -- (las casas son las de la zona Pocitos de la demo base: ubicación (100 + j), espacio 1 de cada una, hasta 3 en los edificios)
  delete from tc_vis v where not exists (select 1 from public.espacio e where e.id = pg_temp.cdid(13, v.esp));

  insert into public.espacio_persona (id, espacio_id, persona_id)
  select pg_temp.cdid(46, e.esp), pg_temp.cdid(13, e.esp), pg_temp.cdid(47, e.esp)
    from (select distinct esp from tc_vis) e
  on conflict do nothing;

  insert into public.jornada (id, colportor_id, inicio, fin, total_visitas, total_ventas)
  select j.id, v_usr, j.inicio, j.fin,
         (select count(*) from tc_vis v where v.jor = j.id), (select count(*) from tc_vis v where v.jor = j.id and v.res = 'VENTA')
    from tc_jor j
  on conflict do nothing;

  insert into public.visita (id, espacio_persona_id, fecha, tipo_resultado, colportor_id, jornada_id, espacio_id, entrevista_entrada, entrevista_salida)
  select v.id, pg_temp.cdid(46, v.esp), v.fecha, v.res, v_usr, v.jor, pg_temp.cdid(13, v.esp),
         case when v.res = 'ENTREVISTA' then v.fecha end,
         case when v.res = 'ENTREVISTA' then v.fecha + ((15 + floor(pg_temp.crnd('cvs' || v.id) * 25)) || ' minutes')::interval end
    from tc_vis v
  on conflict do nothing;

  -- --------------------------------------------------------------------------------------------------
  -- 4. Ventas (precio general de ese día), renglones y cobros en efectivo (al contado o la mitad)
  -- --------------------------------------------------------------------------------------------------
  create temp table tc_vta (id uuid primary key, vis uuid, fecha timestamptz, rn int, esp bigint, total int) on commit drop;
  insert into tc_vta (id, vis, fecha, rn, esp)
  select pg_temp.cdid(10, 99000000 + v.rn), v.id, v.fecha + interval '12 minutes', v.rn, v.esp
    from (select t.*, row_number() over (order by t.fecha, t.id)::int rn from tc_vis t where t.res = 'VENTA') v;

  create temp table tc_item (id uuid primary key, venta uuid, code int, cant int, precio int, subtotal int) on commit drop;
  insert into tc_item (id, venta, code, cant, precio, subtotal)
  select pg_temp.cdid(11, 99000000 + row_number() over (order by x.rn, x.k)), x.id, x.code, x.cant, x.precio, x.cant * x.precio
    from (
      select b.id, b.rn, b.k, b.code,
             case when b.code in (7, 8) then 1 + floor(pg_temp.crnd('cq' || b.id || b.k) * 3)::int else 1 end as cant,
             (select pgl.precio_venta from public.precio_general pgl
               where pgl.deleted_at is null and pgl.producto_id = pg_temp.cdid(5, b.code)
                 and b.fecha::date between pgl.valido_desde and coalesce(pgl.valido_hasta, date '2999-12-31') limit 1) as precio
        from (select va.*, k.k, 1 + floor(power(pg_temp.crnd('cp' || va.id || k.k), 1.35) * 10)::int as code
                from tc_vta va
                cross join lateral generate_series(1, 1 + (pg_temp.crnd('cn' || va.id) > 0.50)::int) k(k)) b
    ) x
   where x.precio is not null;
  delete from tc_item i using tc_item j where i.venta = j.venta and i.code = j.code and i.id > j.id;
  update tc_vta v set total = s.suma from (select i.venta, sum(i.subtotal)::int suma from tc_item i group by i.venta) s where s.venta = v.id;
  delete from tc_vta where total is null;

  insert into public.venta (id, espacio_persona_id, numero_talonario, monto_total, fecha, colportor_id, visita_id)
  select v.id, pg_temp.cdid(46, v.esp), 'CD-' || lpad(v.rn::text, 4, '0'), v.total, v.fecha, v_usr, v.vis
    from tc_vta v on conflict do nothing;
  insert into public.venta_item (id, venta_id, producto_id, cantidad, precio_unitario, subtotal)
  select i.id, i.venta, pg_temp.cdid(5, i.code), i.cant, i.precio, i.subtotal from tc_item i
   where exists (select 1 from tc_vta v where v.id = i.venta) on conflict do nothing;

  create temp table tc_cob (id uuid primary key, venta uuid, monto int, fecha timestamptz) on commit drop;
  insert into tc_cob (id, venta, monto, fecha)
  select pg_temp.cdid(13, 99000000 + v.rn), v.id,
         case when pg_temp.crnd('cce' || v.id) < 0.60 then v.total else (floor(v.total / 2 / 100) * 100)::int end,
         v.fecha + interval '5 minutes'
    from tc_vta v where v.total > 0 and v.fecha + interval '5 minutes' <= v_corte;
  delete from tc_cob where monto <= 0;
  insert into public.cobranza (id, venta_id, monto, medio, fecha)
  select c.id, c.venta, c.monto, 'EFECTIVO', c.fecha from tc_cob c on conflict do nothing;

  -- --------------------------------------------------------------------------------------------------
  -- 5. Cuenta de saldo: lo cobrado en efectivo queda en mano y lo que falta, por cobrar (si la cuenta está dada de baja, no se toca)
  -- --------------------------------------------------------------------------------------------------
  select coalesce(sum(c.monto), 0) into v_en_mano from tc_cob c;
  select coalesce(sum(v.total), 0) - v_en_mano into v_cobrar from tc_vta v;
  if exists (select 1 from public.cuenta_colportor cu where cu.usuario_id = v_usr and cu.deleted_at is null) then
    update public.cuenta_colportor cu
       set dinero_en_mano = cu.dinero_en_mano + v_en_mano, dinero_por_cobrar = cu.dinero_por_cobrar + v_cobrar
     where cu.usuario_id = v_usr and cu.deleted_at is null;
  elsif not exists (select 1 from public.cuenta_colportor cu where cu.usuario_id = v_usr) then
    insert into public.cuenta_colportor (id, usuario_id, deuda_total, dinero_depositado, dinero_en_mano, dinero_por_cobrar)
    values (pg_temp.cdid(21, 99000001), v_usr, 0, 0, v_en_mano, v_cobrar) on conflict do nothing;
  else
    raise notice 'La cuenta de saldo de colportor.demo está dada de baja: no se toca (mover_deuda_casa_editora() no la reactiva).';
  end if;

  select count(*) into v_nj from tc_jor;
  select count(*) into v_nv from tc_vta;
  raise notice 'colportor.demo inscripto en la campaña de verano (zona Pocitos, Montevideo): % jornadas y % ventas de demo.', v_nj, v_nv;
end
$colportor_demo$;

-- Resultado (solo lectura): la inscripción y lo que ve la app de colportor.demo.
select u.email,
       c.nombre as campania,
       ci.nombre as ciudad,
       z.nombre as zona,
       (select count(*) from public.jornada j where j.colportor_id = u.id and j.deleted_at is null) as jornadas,
       (select count(*) from public.venta v where v.colportor_id = u.id and v.deleted_at is null) as ventas,
       (select coalesce(sum(s.cantidad_disponible), 0) from public.stock s where s.usuario_id = u.id and s.deleted_at is null) as ejemplares_en_stock
  from public.usuario u
  join public.campania_colportor cc on cc.usuario_id = u.id and cc.deleted_at is null
  join public.campania c on c.id = cc.campania_id and c.deleted_at is null
  left join public.zona z on z.id = cc.zona_id
  left join public.campania_ciudad cca on cca.id = z.campania_ciudad_id
  left join public.ciudad ci on ci.id = cca.ciudad_id
 where lower(u.email) = 'colportor.demo@example.com'
 order by c.fecha_inicio desc;
