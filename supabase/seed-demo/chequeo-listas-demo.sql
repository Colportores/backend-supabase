-- ============================================================================
-- Chequeo de las listas largas de la demo (solo lectura): cuántos registros ve cada lista desplazable (backend-supabase#289)
--
-- Corre cada lista tal como la ve la cuenta de la demo: las RPC y las tablas del panel con la sesión de coordinador.demo, y
-- las de la app con la de colportor.demo (rol `authenticated` con su JWT, así que cuenta lo que dejan pasar las políticas
-- RLS). Cada fila es (orden, quien, lista, fuente, filas, minimo, ok): `ok` es true cuando la lista tiene al menos el mínimo
-- (26) y vacío cuando la lista no se puede sembrar desde la nube. Una fila con `filas` = -1 es una RPC que falló.
--
-- Se corre con `scripts/db-seed-demo.sh [--remoto] --chequeo-listas` (o pegándolo en el SQL Editor), DESPUÉS de cargar
-- la base, --coordinador, --colportor, --volumen y --listas. Si la cuenta no existe en la base, sus listas no se miden.
-- No cambia nada: todo corre en la misma transacción de la sentencia y vuelve al rol original.
-- ============================================================================

create temp table if not exists chequeo_listas_demo (orden serial, quien text, lista text, fuente text, filas bigint, minimo int, ok boolean);
truncate chequeo_listas_demo;

do $chequeo$
declare
  v_camp  constant uuid := '5eed0000-0000-7000-8003-000000000001';  -- la campaña de verano de la demo
  v_coord uuid;
  v_col   uuid;
  v_mvd   uuid;
  v_res   jsonb := '[]'::jsonb;
  r       record;
begin
  -- Cuenta las filas de una consulta; -1 si falla (la causa va en el aviso).
  create or replace function pg_temp.contar_lista(p_sql text) returns bigint language plpgsql as $f$
  declare v bigint;
  begin
    execute 'select count(*) from (' || p_sql || ') q' into v;
    return v;
  exception when others then
    raise notice 'Falla % -> %', p_sql, sqlerrm;
    return -1;
  end $f$;

  select u.id into v_coord from public.usuario u
   where lower(u.email) = 'coordinador.demo@example.com' and u.deleted_at is null;
  select u.id into v_col from public.usuario u
   where lower(u.email) = 'colportor.demo@example.com' and u.deleted_at is null;
  select cc.id into v_mvd
    from public.campania_ciudad cc join public.ciudad ci on ci.id = cc.ciudad_id
   where cc.campania_id = v_camp and cc.deleted_at is null and ci.nombre = 'Montevideo' order by cc.created_at limit 1;

  -- ------------------------------------------------------------------------------------------------
  -- Panel de coordinadores (coordinador.demo)
  -- ------------------------------------------------------------------------------------------------
  if v_coord is not null then
    perform set_config('request.jwt.claims', json_build_object('sub', v_coord, 'role', 'authenticated')::text, true);
    perform set_config('request.jwt.claim.sub', v_coord::text, true);
    perform set_config('request.jwt.claim.role', 'authenticated', true);
    set local role authenticated;

    for r in
      select * from (values
        ('Inicio · Ciudades de la campaña',                     'ciudades_de_campania',                      $q$select * from public.ciudades_de_campania('5eed0000-0000-7000-8003-000000000001')$q$),
        ('Ciudades · Ciudades de la campaña',                   'ciudades_de_campania',                      $q$select * from public.ciudades_de_campania('5eed0000-0000-7000-8003-000000000001')$q$),
        ('Ciudades · Zonas de Montevideo',                      'zonas_de_ciudad',                           format($q$select * from public.zonas_de_ciudad('5eed0000-0000-7000-8003-000000000001', %L)$q$, v_mvd)),
        ('Ciudades · Zonas para asignar',                       'zonas_asignables',                          $q$select * from public.zonas_asignables('5eed0000-0000-7000-8003-000000000001')$q$),
        ('Ciudades · Catálogo de ciudades para sumar',          'ciudades_del_catalogo',                     $q$select * from public.ciudades_del_catalogo('5eed0000-0000-7000-8003-000000000001', null)$q$),
        ('Ciudades · Precios de Montevideo',                    'precios_de_la_ciudad',                      format($q$select * from public.precios_de_la_ciudad(%L, date '2026-11-17')$q$, v_mvd)),
        ('Equipo · Colportores',                                'colportores_de_campania',                   $q$select * from public.colportores_de_campania('5eed0000-0000-7000-8003-000000000001')$q$),
        ('Equipo · Zonas por colportor',                        'zonas_por_colportor',                       $q$select * from public.zonas_por_colportor('5eed0000-0000-7000-8003-000000000001')$q$),
        ('Equipo · Becas',                                      'becas_de_campania',                         $q$select * from public.becas_de_campania('5eed0000-0000-7000-8003-000000000001')$q$),
        ('Equipo · Acompañamientos por colportor',              'acompaniamientos_por_colportor',            $q$select * from public.acompaniamientos_por_colportor('5eed0000-0000-7000-8003-000000000001')$q$),
        ('Equipo · Historial de acompañamientos (campaña)',     'historial_de_acompaniamientos',             $q$select * from public.historial_de_acompaniamientos('5eed0000-0000-7000-8003-000000000001')$q$),
        ('Equipo · Historial de acompañamientos (un colportor)','historial_de_acompaniamientos',             $q$select * from public.historial_de_acompaniamientos('5eed0000-0000-7000-8003-000000000001', (select h.colportor_id from public.historial_de_acompaniamientos('5eed0000-0000-7000-8003-000000000001') h group by 1 order by count(*) desc, 1 limit 1))$q$),
        ('Equipo · Jornadas cerradas (un colportor)',          'jornadas_cerradas_de_colportor',            $q$select * from public.jornadas_cerradas_de_colportor('5eed0000-0000-7000-8003-000000000001', (select h.colportor_id from public.historial_de_acompaniamientos('5eed0000-0000-7000-8003-000000000001') h group by 1 order by count(*) desc, 1 limit 1))$q$),
        ('Equipo · Acompañantes (coordinadores y administración)','acompaniantes_del_panel',                 $q$select * from public.acompaniantes_del_panel('5eed0000-0000-7000-8003-000000000001')$q$),
        ('Equipo · Añadir colportor, búsqueda «a» (tres páginas de 10)', 'buscar_candidatos', $q$with p1 as (select * from public.buscar_candidatos('5eed0000-0000-7000-8003-000000000001', 'a') with ordinality),
             p2 as (select * from public.buscar_candidatos('5eed0000-0000-7000-8003-000000000001', 'a', (select usuario_id from p1 order by ordinality desc limit 1)) with ordinality),
             p3 as (select * from public.buscar_candidatos('5eed0000-0000-7000-8003-000000000001', 'a', (select usuario_id from p2 order by ordinality desc limit 1)) with ordinality)
             select usuario_id from p1 union all select usuario_id from p2 union all select usuario_id from p3$q$),
        ('Cuentas · Cuentas de los colportores',                'cuentas_de_campania',                       $q$select * from public.cuentas_de_campania('5eed0000-0000-7000-8003-000000000001')$q$),
        ('Cuentas · Validar tickets: todos',                    'tickets_de_campania',                       $q$select * from public.tickets_de_campania('5eed0000-0000-7000-8003-000000000001', null, null, null, null, null, 500, 0)$q$),
        ('Cuentas · Validar tickets: por validar',              'tickets_de_campania(PENDIENTE)',            $q$select * from public.tickets_de_campania('5eed0000-0000-7000-8003-000000000001', 'PENDIENTE', null, null, null, null, 500, 0)$q$),
        ('Cuentas · Validar tickets: validados',                'tickets_de_campania(VALIDADO)',             $q$select * from public.tickets_de_campania('5eed0000-0000-7000-8003-000000000001', 'VALIDADO', null, null, null, null, 500, 0)$q$),
        ('Cuentas · Validar tickets: rechazados',               'tickets_de_campania(RECHAZADO)',            $q$select * from public.tickets_de_campania('5eed0000-0000-7000-8003-000000000001', 'RECHAZADO', null, null, null, null, 500, 0)$q$),
        ('Cuentas · Retiros del coordinador: todos',            'retiros_de_campania',                       $q$select * from public.retiros_de_campania('5eed0000-0000-7000-8003-000000000001', null, null, null, null, null, 500, 0)$q$),
        ('Cuentas · Retiros: por confirmar',                    'retiros_de_campania(PENDIENTE)',            $q$select * from public.retiros_de_campania('5eed0000-0000-7000-8003-000000000001', 'PENDIENTE', null, null, null, null, 500, 0)$q$),
        ('Cuentas · Retiros: confirmados',                      'retiros_de_campania(VALIDADO)',             $q$select * from public.retiros_de_campania('5eed0000-0000-7000-8003-000000000001', 'VALIDADO', null, null, null, null, 500, 0)$q$),
        ('Cuentas · Retiros: rechazados',                       'retiros_de_campania(RECHAZADO)',            $q$select * from public.retiros_de_campania('5eed0000-0000-7000-8003-000000000001', 'RECHAZADO', null, null, null, null, 500, 0)$q$),
        ('Reportes · Horas por ciudad y colportor',             'horas_por_ciudad_y_colportor',              $q$select * from public.horas_por_ciudad_y_colportor('5eed0000-0000-7000-8003-000000000001', date '2026-09-14', date '2026-11-17', 'semana')$q$),
        ('Reportes · Ventas por ciudad y colportor',            'ventas_por_ciudad_y_colportor',             $q$select * from public.ventas_por_ciudad_y_colportor('5eed0000-0000-7000-8003-000000000001', date '2026-09-14', date '2026-11-17', 'semana')$q$),
        ('Reportes · Ventas con monto acordado',                'ventas_con_motivo_de_campania',             $q$select * from public.ventas_con_motivo_de_campania('5eed0000-0000-7000-8003-000000000001', date '2026-09-14', date '2026-11-17')$q$),
        ('Stock · Stock por ciudad y producto',                 'stock_por_ciudad',                          $q$select * from public.stock_por_ciudad('5eed0000-0000-7000-8003-000000000001')$q$),
        ('Pedidos · Pedidos: todos',                            'pedidos_de_campania',                       $q$select * from public.pedidos_de_campania('5eed0000-0000-7000-8003-000000000001')$q$),
        ('Pedidos · Pedidos por autorizar',                     'pedidos_de_campania(PENDIENTE_AUTORIZACION)', $q$select * from public.pedidos_de_campania('5eed0000-0000-7000-8003-000000000001') where estado = 'PENDIENTE_AUTORIZACION'$q$),
        ('Pedidos · Pedidos autorizados',                       'pedidos_de_campania(AUTORIZADO)',           $q$select * from public.pedidos_de_campania('5eed0000-0000-7000-8003-000000000001') where estado = 'AUTORIZADO'$q$),
        ('Pedidos · Pedidos despachados',                       'pedidos_de_campania(DESPACHADO)',           $q$select * from public.pedidos_de_campania('5eed0000-0000-7000-8003-000000000001') where estado = 'DESPACHADO'$q$),
        ('Pedidos · Pedidos recibidos',                         'pedidos_de_campania(RECIBIDO)',             $q$select * from public.pedidos_de_campania('5eed0000-0000-7000-8003-000000000001') where estado = 'RECIBIDO'$q$),
        ('Pedidos · Pedidos rechazados',                        'pedidos_de_campania(RECHAZADO)',            $q$select * from public.pedidos_de_campania('5eed0000-0000-7000-8003-000000000001') where estado = 'RECHAZADO'$q$),
        ('Pedidos · Transferencias: todas',                     'transferencias_de_campania',                $q$select * from public.transferencias_de_campania('5eed0000-0000-7000-8003-000000000001')$q$),
        ('Pedidos · Transferencias por autorizar',              'transferencias_de_campania(PENDIENTE_AUTORIZACION)', $q$select * from public.transferencias_de_campania('5eed0000-0000-7000-8003-000000000001') where estado = 'PENDIENTE_AUTORIZACION'$q$),
        ('Pedidos · Transferencias autorizadas',                'transferencias_de_campania(AUTORIZADO)',    $q$select * from public.transferencias_de_campania('5eed0000-0000-7000-8003-000000000001') where estado = 'AUTORIZADO'$q$),
        ('Pedidos · Transferencias rechazadas',                 'transferencias_de_campania(RECHAZADO)',     $q$select * from public.transferencias_de_campania('5eed0000-0000-7000-8003-000000000001') where estado = 'RECHAZADO'$q$)
      ) v(lista, fuente, consulta)
    loop
      v_res := v_res || jsonb_build_object('quien', 'coordinador.demo', 'lista', r.lista, 'fuente', r.fuente, 'filas', pg_temp.contar_lista(r.consulta), 'minimo', 26);
    end loop;
    reset role;
  else
    raise notice 'coordinador.demo no existe en esta base: no se miden las listas del panel.';
  end if;

  -- ------------------------------------------------------------------------------------------------
  -- App del colportor (colportor.demo): lo que baja a su teléfono (RLS) y las RPC que lee
  -- ------------------------------------------------------------------------------------------------
  if v_col is not null then
    perform set_config('request.jwt.claims', json_build_object('sub', v_col, 'role', 'authenticated')::text, true);
    perform set_config('request.jwt.claim.sub', v_col::text, true);
    perform set_config('request.jwt.claim.role', 'authenticated', true);
    set local role authenticated;

    for r in
      select * from (values
        ('Mapa · Ciudades de la campaña (y mapas sin conexión)', 'mis_campania_ciudades()',   $q$select * from public.mis_campania_ciudades()$q$),
        ('Mapa · Lista de casas',                                'ubicacion',                 $q$select * from public.ubicacion$q$),
        ('Nueva venta · Catálogo de productos',                  'producto',                  $q$select * from public.producto where deleted_at is null and es_misionero = false$q$),
        ('Precios · Productos con precio general',               'producto + precio_general', $q$select * from public.producto p join public.precio_general pg on pg.producto_id = p.id and pg.deleted_at is null where p.deleted_at is null and p.es_misionero = false$q$),
        ('Jornadas',                                             'jornada',                   $q$select * from public.jornada where deleted_at is null$q$),
        ('Visitas',                                              'visita',                    $q$select * from public.visita where deleted_at is null$q$),
        ('Ventas',                                               'venta',                     $q$select * from public.venta where deleted_at is null$q$),
        ('Cobros · Ventas con saldo',                            'venta + cobranza',          $q$select * from public.venta v where v.deleted_at is null and v.monto_total > coalesce((select sum(c.monto) from public.cobranza c where c.venta_id = v.id and c.anulado_at is null and c.deleted_at is null), 0)$q$),
        ('Mi plata · Cobros',                                    'cobranza',                  $q$select * from public.cobranza where deleted_at is null$q$),
        ('Mi plata · Depósitos',                                 'deposito',                  $q$select * from public.deposito where deleted_at is null$q$),
        ('Entregas pendientes',                                  'entrega(pendiente)',        $q$select * from public.entrega where deleted_at is null and pendiente$q$),
        ('Devolución · Entregas hechas',                         'entrega(entregada)',        $q$select * from public.entrega where deleted_at is null and not pendiente$q$),
        ('Agenda · Cobranzas',                                   'agenda(COBRANZA)',          $q$select * from public.agenda where deleted_at is null and tipo = 'COBRANZA'$q$),
        ('Agenda · Entregas',                                    'agenda(ENTREGA)',           $q$select * from public.agenda where deleted_at is null and tipo = 'ENTREGA'$q$),
        ('Agenda · Entrevistas',                                 'agenda(ENTREVISTA)',        $q$select * from public.agenda where deleted_at is null and tipo = 'ENTREVISTA'$q$),
        ('Mi deuda con la casa · Pedidos con saldo',             'mi_deuda_con_la_casa_editora()', $q$select * from jsonb_array_elements(public.mi_deuda_con_la_casa_editora() -> 'pedidos')$q$),
        ('Pedidos a la casa editora',                            'pedido_casa_editora',       $q$select * from public.pedido_casa_editora where deleted_at is null$q$),
        ('Stock · Títulos en stock',                             'stock',                     $q$select * from public.stock where deleted_at is null$q$),
        ('Stock · Movimientos',                                  'movimiento_stock',          $q$select * from public.movimiento_stock where deleted_at is null$q$)
      ) v(lista, fuente, consulta)
    loop
      v_res := v_res || jsonb_build_object('quien', 'colportor.demo', 'lista', r.lista, 'fuente', r.fuente, 'filas', pg_temp.contar_lista(r.consulta), 'minimo', 26);
    end loop;
    reset role;
  else
    raise notice 'colportor.demo no existe en esta base: no se miden las listas de la app.';
  end if;

  -- Lo que no se puede sembrar desde la nube (ADR-018): vive solo en el teléfono.
  v_res := v_res
    || jsonb_build_object('quien', 'colportor.demo', 'lista', 'Personas, notas, duplicados y «con quién»', 'fuente', 'solo del teléfono (ADR-018)', 'filas', null, 'minimo', null)
    || jsonb_build_object('quien', 'colportor.demo', 'lista', 'Centro de notificaciones', 'fuente', 'historial local de avisos (lo arma la app)', 'filas', null, 'minimo', null);

  -- Sin sesión de nuevo (un cobro o un retiro con sesión de colportor no se da de baja desde el servidor: CB007).
  perform set_config('request.jwt.claims', '', true);
  perform set_config('request.jwt.claim.sub', '', true);
  perform set_config('request.jwt.claim.role', '', true);

  insert into chequeo_listas_demo (quien, lista, fuente, filas, minimo, ok)
  select e ->> 'quien', e ->> 'lista', e ->> 'fuente', (e ->> 'filas')::bigint, (e ->> 'minimo')::int,
         case when e ->> 'minimo' is null then null else (e ->> 'filas')::bigint >= (e ->> 'minimo')::int end
    from jsonb_array_elements(v_res) with ordinality as t(e, n)
   order by n;
end
$chequeo$;

select orden, quien, lista, fuente, filas, minimo, ok from chequeo_listas_demo order by orden;
select count(*) filter (where ok is false) as listas_que_no_llegan, count(*) filter (where ok) as listas_ok, count(*) filter (where ok is null) as no_sembrables
  from chequeo_listas_demo;
