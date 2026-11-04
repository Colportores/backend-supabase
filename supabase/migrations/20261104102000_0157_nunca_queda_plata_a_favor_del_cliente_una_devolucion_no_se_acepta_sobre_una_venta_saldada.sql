-- ============================================================================
-- 0157 · Nunca queda plata a favor del cliente: una venta saldada no acepta devoluciones y lo descontado llega
--        hasta el saldo (backend-supabase#234, casilla «Devol. saldo»; respuestas de Cristian del 03/11 en
--        front-colportores-mobile#589: «si la compra está cerrada (pagó toda la deuda) no se aceptan
--        devoluciones» y «igual que la anterior»)
--
-- ## El caso
--
--   Pedro compró dos libros ($ 4.500) y ya pagó los $ 4.500. Devuelve uno de $ 1.900. Antes (ADR-002, 0108) la plata de
--   más quedaba «a favor» del cliente y la colportora elegía: «Lo retengo» (`dinero_retenido`), «Se lo devuelvo ahora»
--   (`monto_reembolsado`) o «Se lo devuelvo después» («Debo al cliente»). Ahora esa situación no existe:
--
--     · Una venta SALDADA (el cliente pagó todo lo que se queda comprando) no acepta más devoluciones.
--     · Una venta CON SALDO acepta la devolución, y lo que se descuenta de la venta llega hasta ese saldo y no más:
--       nunca queda plata a favor del cliente. Pedro debe $ 2.600 por dos libros ($ 2.600 y $ 1.900) y devuelve el de
--       $ 1.900: el saldo baja de $ 2.600 a $ 700.
--
-- ## Qué hace esta migración
--
--   1. Se sacan `devolucion.dinero_retenido` y `devolucion.monto_reembolsado` (con sus CHECK). Sin ellas el saldo de la
--      venta es una cuenta pura: monto, menos lo cobrado, menos lo devuelto. «Se lo devuelvo ahora», «Lo retengo» y
--      «Debo al cliente» desaparecen; «En mano» (`efectivo_en_mano()`, 0152) nunca las leyó.
--   2. `devolucion_detalle_de_auditoria()` (0121) deja de copiar esos dos montos al `audit_log`. Los eventos ya
--      escritos quedan como están.
--   3. Dos funciones internas, las únicas cuentas del saldo de una venta en el servidor:
--
--        valor_devuelto_de_la_venta(venta, excepto)   lo que valen los libros que volvieron en devoluciones vivas:
--                                                     por renglón, las unidades devueltas por el precio unitario
--                                                     del renglón. Un renglón suelto: las unidades de su libro. Un
--                                                     combo: las veces que volvió ENTERO (las que alcanzan todos sus
--                                                     componentes), nunca más que las vendidas. Lo mismo que calcula
--                                                     el teléfono (`ReglasDeDevolucion`).
--        saldo_de_la_venta(venta, excepto)            monto_total − cobros vivos y no anulados − valor devuelto, sin
--                                                     bajar de 0. Devolver todo deja la venta en cero aunque el
--                                                     monto no coincida con la suma de sus renglones. El «sin bajar
--                                                     de 0» es el «lo descontado llega hasta el saldo».
--
--      `excepto` deja afuera una devolución (para medir una devolución contra lo que había ANTES de ella).
--
--   4. El trigger `devolucion_venta_con_saldo` (BEFORE INSERT): una devolución viva que sube de un teléfono sobre una
--      venta de la colportora con saldo 0 se rechaza con 23514 (el push la vuelve `invalid`). Una devolución que entra
--      ya dada de baja (registrada y anulada sin conexión), un reintento (la fila ya existe) y todo lo que no viene de
--      una sesión (migraciones, service_role, el editor SQL) pasan sin juicio. Se mide contra los cobros que el
--      servidor ya tiene: el teléfono sube sus cambios en el orden en que ocurrieron, así que el cobro que dejó la
--      venta saldada llega antes que la devolución.
--
-- ## Lo que NO hace
--
--   · No guarda el descuento: se calcula (`saldo_de_la_venta`). Una venta no se anula ni se toca: la devolución se anota
--     aparte (ADR-002).
--   · No mira la ventana de 72 h ni compara cantidades con lo vendido (siguen en la app, 0108/0136).
--   · Una venta de $ 0 (descuento total con motivo, decisión «Monto $ 0») nace saldada: tampoco acepta devoluciones.
--     Está anotado en el archivo de pendientes de esta entrega.
--
-- ## Los datos
--
--   Datos simulados hasta diciembre: las dos columnas se pierden con su contenido (no se migran a ningún otro lado
--   porque la regla nueva los hace innecesarios). Ninguna devolución, venta ni cobro se toca ni cambia su
--   `sync_version`. Lo prueba supabase/tests_migracion/0157_ok.
--
-- ## Para otros repos
--
--   · front-colportores-mobile#609: deja de mandar `dinero_retenido` y `monto_reembolsado` (el push las ignora si
--     llegan: `sync.columnas_escribibles` solo deja pasar las columnas que existen) y no ofrece «Lo retengo», «Debo al
--     cliente», «Se lo devuelvo ahora» ni agendar la devolución del dinero. Una devolución sobre una venta saldada vuelve
--     `invalid` con 23514 («Esta venta ya está saldada…»).
--   · docs-organizacion: HU-VEN-004, ADR-002, `esquema-datos.md` (devolucion) y `contrato-sync-engine.md` §2.
--
-- Forward-only: esta migración no se edita una vez aplicada.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. La auditoría deja de copiar los dos montos, y las columnas se van
-- ----------------------------------------------------------------------------

-- Primero la función (su cuerpo lee las columnas que se van: plpgsql/SQL no lo detectan al soltarlas).
create or replace function public.devolucion_detalle_de_auditoria(p_fila public.devolucion)
returns jsonb
language sql
immutable
set search_path = ''
as $$
  select jsonb_build_object(
           'venta_id', p_fila.venta_id,
           'productos_distintos', jsonb_array_length(p_fila.productos_devueltos),
           'unidades_devueltas', (select sum((e ->> 'cantidad')::bigint)
                                    from jsonb_array_elements(p_fila.productos_devueltos) e),
           'fecha_devolucion', p_fila.fecha_devolucion);
$$;

comment on function public.devolucion_detalle_de_auditoria(public.devolucion) is
  'El metadata de devolucion_registrada y devolucion_anulada (0121; 0157): la venta, cuántos productos distintos y '
  'cuántas unidades y la fecha. Desde 0157 no lleva montos (la devolución no guarda dinero). Tamaño fijo: la lista de '
  'productos no se copia (audit_log.metadata admite 4000 caracteres) y se lee de la fila.';

comment on function public.tg_devolucion_auditar_alta() is
  'AFTER INSERT en devolucion (0121, backend-supabase#172, HU-VEN-004, ADR-002; 0157): deja devolucion_registrada en '
  'audit_log con la venta, cuántos productos y unidades y la fecha; y devolucion_anulada si la fila ya entra dada de '
  'baja. Nunca texto libre.';

alter table public.devolucion
  drop column dinero_retenido,
  drop column monto_reembolsado;

comment on table public.devolucion is
  'Devolución de una venta (ADR-002, HU-VEN-004): los productos y las cantidades que vuelven, de qué renglón sale cada '
  'libro y el motivo opcional. No guarda dinero (0157): el saldo de la venta se calcula con saldo_de_la_venta() y '
  'nunca queda plata a favor del cliente. La venta original no se toca. Sin datos del cliente. Solo la colportora '
  'dueña la lee y la escribe. Sube por push (0108).';

-- ----------------------------------------------------------------------------
-- 2. El saldo de una venta, en el servidor
-- ----------------------------------------------------------------------------

-- Lo que valen los libros que volvieron de la venta en devoluciones vivas. Un renglón suelto: las unidades de su libro
-- devueltas de ESE renglón. Un combo: las veces que volvió entero (el mínimo, entre sus componentes, de lo devuelto
-- sobre la cantidad del componente por combo), sin pasar de las vendidas. Las filas viejas de dos claves (0108, sin
-- renglón) no se pueden valuar y no suman. Interna.
create function public.valor_devuelto_de_la_venta(p_venta_id uuid, p_excepto uuid default null)
returns bigint
language sql
stable
security definer
set search_path = ''
as $$
  with libros as (
    select lower(e ->> 'venta_item_id')::uuid as item_id,
           (e ->> 'producto_id')::uuid as producto_id,
           sum((e ->> 'cantidad')::bigint) as devuelto
      from public.devolucion d
     cross join lateral jsonb_array_elements(d.productos_devueltos) e
     where d.venta_id = p_venta_id
       and d.deleted_at is null
       and d.id is distinct from p_excepto
       and public.devolucion_renglones_validos(d.productos_devueltos)
     group by 1, 2
  )
  select coalesce(sum(
           i.precio_unitario::bigint * least(
             i.cantidad::bigint,
             case when i.componentes is null then
                    coalesce((select l.devuelto from libros l
                               where l.item_id = i.id and l.producto_id = i.producto_id), 0)
                  else
                    coalesce((select min(coalesce(l.devuelto, 0) / c.por_combo)
                                from (select (x ->> 'producto_id')::uuid as producto_id,
                                             sum((x ->> 'cantidad')::bigint) as por_combo
                                        from jsonb_array_elements(i.componentes) x
                                       group by 1) c
                                left join libros l on l.item_id = i.id and l.producto_id = c.producto_id), 0)
             end)), 0)::bigint
    from public.venta_item i
   where i.venta_id = p_venta_id;
$$;

comment on function public.valor_devuelto_de_la_venta(uuid, uuid) is
  'Lo que valen, en centavos, los libros devueltos de una venta en devoluciones vivas (0157): por renglón, las unidades '
  'devueltas (un combo cuenta las veces que volvió entero) por el precio unitario, sin pasar de las vendidas. '
  'p_excepto deja afuera una devolución. Interna.';

revoke all on function public.valor_devuelto_de_la_venta(uuid, uuid) from public, anon, authenticated, service_role;

-- Lo que le falta pagar al cliente: monto_total menos los cobros vivos y no anulados menos lo devuelto, sin bajar de 0
-- (nunca queda plata a favor del cliente). Una venta inexistente tiene saldo 0. Interna.
create function public.saldo_de_la_venta(p_venta_id uuid, p_excepto uuid default null)
returns bigint
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce((select greatest(
                            v.monto_total::bigint
                            - coalesce((select sum(c.monto)
                                          from public.cobranza c
                                         where c.venta_id = v.id and c.deleted_at is null and c.anulado_at is null), 0)
                            - public.valor_devuelto_de_la_venta(v.id, p_excepto),
                            0)
                     from public.venta v
                    where v.id = p_venta_id), 0)::bigint;
$$;

comment on function public.saldo_de_la_venta(uuid, uuid) is
  'Lo que le falta pagar al cliente de una venta, en centavos (0157): monto_total menos los cobros vivos y no anulados '
  'menos lo que valen los libros devueltos (valor_devuelto_de_la_venta), sin bajar de 0: lo descontado llega hasta el '
  'saldo y nunca queda plata a favor del cliente. p_excepto deja afuera una devolución. Interna.';

revoke all on function public.saldo_de_la_venta(uuid, uuid) from public, anon, authenticated, service_role;

-- ----------------------------------------------------------------------------
-- 3. Una venta saldada no acepta devoluciones
-- ----------------------------------------------------------------------------

-- DEFINER: mide el saldo con todos los cobros y devoluciones de la venta, los vea o no quien escribe (la RLS de
-- devolucion solo deja ver las propias). Solo mira ventas de quien escribe: sobre una venta ajena no opina (la RLS o la
-- FK dirán lo suyo) y no cuenta nada de ella. «Cliente o servidor» por la sesión: sin `auth.uid()` (migraciones,
-- service_role, el editor SQL) no juzga. Va después de `devolucion_productos` (por el nombre).
create function public.tg_devolucion_venta_con_saldo()
returns trigger
language plpgsql
volatile
security definer
set search_path = ''
as $$
begin
  if auth.uid() is null or new.deleted_at is not null then
    return new;
  end if;
  -- Un reintento del push (`INSERT … ON CONFLICT DO NOTHING`) corre los BEFORE aunque la fila ya exista: no se
  -- vuelve a juzgar (la venta pudo quedar saldada justamente por esta devolución).
  if exists (select 1 from public.devolucion d where d.id = new.id) then
    return new;
  end if;
  if not exists (select 1 from public.venta v where v.id = new.venta_id and v.colportor_id = auth.uid()) then
    return new;
  end if;

  if public.saldo_de_la_venta(new.venta_id) <= 0 then
    raise exception 'Esta venta ya está saldada: el cliente pagó todo lo que se queda comprando, así que no se puede devolver nada. Si hay un error, pedile a tu coordinador que lo revise.'
      using errcode = '23514', constraint = 'devolucion_venta_con_saldo';
  end if;
  return new;
end;
$$;

comment on function public.tg_devolucion_venta_con_saldo() is
  'BEFORE INSERT de devolucion (0157, «Devol. saldo»): una devolución viva de una venta de la colportora cuyo saldo es '
  '0 (saldo_de_la_venta) se rechaza con 23514 (el push la vuelve invalid). No juzga la que entra ya anulada, el '
  'reintento de una fila que ya existe ni lo que no viene de una sesión. DEFINER para medir con todos los cobros.';

revoke all on function public.tg_devolucion_venta_con_saldo() from public, anon, authenticated, service_role;

create trigger devolucion_venta_con_saldo
  before insert on public.devolucion
  for each row execute function public.tg_devolucion_venta_con_saldo();
