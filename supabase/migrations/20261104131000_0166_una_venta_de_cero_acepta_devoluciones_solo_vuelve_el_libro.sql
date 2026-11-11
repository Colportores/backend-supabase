-- ============================================================================
-- 0166 · Una venta de $ 0 acepta devoluciones: solo vuelve el libro
--        (backend-supabase#243, casilla «Devol. $ 0»; decisión de Cristian del 04/11, «Sí, solo vuelve el libro», en
--        backend-supabase#234; seguimiento de la 0157)
--
-- ## El caso
--
-- Ana vendió una colección a $ 0 (un regalo: descuento total con motivo, decisión «Monto $ 0») y Pedro devuelve un libro.
-- La 0157 rechazaba toda devolución sobre una venta de saldo 0, y una venta de $ 0 nace con saldo 0: Pedro no podía devolver
-- ni el libro. Cristian decidió que sí: la devolución se acepta, anota los libros que volvieron y los repone en el stock;
-- no mueve plata (no hay nada que devolver ni nada que cobrar).
--
-- ## Qué cambia
--
-- `tg_devolucion_venta_con_saldo()` (misma firma, `create or replace`; el trigger no cambia): el rechazo 23514 «Esta venta ya
-- está saldada…» sigue para una venta con saldo 0 **y total mayor que 0** (la compra se pagó entera: «compra cerrada no
-- acepta devoluciones»). Una venta cuyo `monto_total` es 0 no se juzga.
--
-- No hay que tocar nada más: el stock de la devolución lo reponen los triggers de la 0136/0142, que no miran el dinero;
-- el saldo de la venta ya es una cuenta pura que nunca baja de 0 (`saldo_de_la_venta`), así que una venta de $ 0 con
-- devoluciones queda en 0 y nunca a favor del cliente.
--
-- ## Los datos
--
-- Una función reemplazada: ningún insert, update ni delete, ningún cambio de esquema. Forward-only.
--
-- ## Para otros repos
--
--   · front-colportores-mobile: una devolución sobre una venta de $ 0 ya no vuelve `invalid`; el teléfono la puede ofrecer.
--   · docs-organizacion: HU-VEN-004 y la regla de la devolución sobre venta saldada.
--
-- Forward-only: esta migración no se edita una vez aplicada.
-- ============================================================================

create or replace function public.tg_devolucion_venta_con_saldo()
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
  -- Una venta de $ 0 (regalo) acepta la devolución: solo anota los libros y repone el stock, sin plata (0166).
  if not exists (select 1 from public.venta v
                  where v.id = new.venta_id and v.colportor_id = auth.uid() and v.monto_total > 0) then
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
  'BEFORE INSERT de devolucion (0157, «Devol. saldo»; 0166, «Devol. $ 0»): una devolución viva de una venta de la '
  'colportora con total mayor que 0 y saldo 0 (saldo_de_la_venta) se rechaza con 23514 (el push la vuelve invalid). Una '
  'venta de $ 0 acepta devoluciones (solo vuelve el libro, sin plata). No juzga la que entra ya anulada, el reintento de '
  'una fila que ya existe ni lo que no viene de una sesión. DEFINER para medir con todos los cobros.';
