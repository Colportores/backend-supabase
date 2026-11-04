-- ============================================================================
-- 0158 · La venta dice cuántos ítems lleva y el motivo del total se exige en los dos sentidos
--        (backend-supabase#234, casilla «Total arriba»; decisión de Cristian del 03/11 en
--        backend-supabase#228, cierra el hueco que dejó la 0150)
--
-- La 0150 exigía el motivo (`motivo_monto_manual`) solo cuando el total de la venta quedaba POR DEBAJO de la suma
-- de los subtotales de sus ítems. El otro sentido (total por encima) no se podía decidir: el servidor no sabe
-- cuándo llegó el último ítem, y en toda venta normal el total supera a la suma parcial entre que entra la venta y
-- entra su último ítem. La decisión de Cristian: la venta lleva cuántos ítems tiene.
--
--   · Columna nueva `venta.items_esperados` (integer, opcional, 1 o más): cuántos renglones vivos lleva la venta
--     cuando el teléfono la termina de armar. Es una columna del push (el teléfono la manda con la venta).
--   · Con todos los ítems llegados (la cantidad de ítems vivos de la venta es igual o mayor que `items_esperados`),
--     si la suma de sus subtotales difiere del total en CUALQUIER sentido y no hay `motivo_monto_manual`, el
--     servidor rechaza con 23514 (`invalid` en el push), con el mismo mensaje guiado de siempre.
--   · Sin `items_esperados` (null: una venta anterior o un teléfono que todavía no lo manda) rige solo la regla de
--     la 0150, total por debajo. Nada de lo ya guardado se toca y ningún teléfono viejo deja de poder subir.
--
-- ## Cuándo corre
--
-- Los mismos disparadores AFTER de fila de la 0150 (la venta y sus ítems suben como jobs distintos, y un lote
-- puede cortar entre una y otros), más `items_esperados` en la lista de columnas de la venta:
--   · llega un ítem (o cambia su subtotal, su venta o se revive): si con ese ítem ya están todos y la suma no
--     cierra con el total, ese ítem vuelve `invalid` (los anteriores quedan guardados);
--   · cambia el total, el motivo, la baja o `items_esperados` de una venta que ya tiene todos sus ítems.
-- Con ítems por llegar, «la suma es menor que el total» no se juzga: es lo normal entre ítem e ítem.
-- Un ítem dado de baja no dispara el chequeo (solo achica la cantidad; el trigger de la venta lo cubre cuando
-- cambia la propia venta).
--
-- ## Los datos
--
-- Columna nueva, opcional, sin default: las ventas que ya existen quedan con null y sin cambios (ni su
-- sync_version ni su xmin_w). No hay migración de limpieza.
--
-- ## Para otros repos
--   · front-colportores-mobile: mandar `items_esperados` con cada venta nueva (la cantidad de renglones que lleva)
--     y mostrar el motivo como obligatorio también cuando el total queda por encima de la suma.
--   · docs-organizacion: contrato del push (`venta.items_esperados`), HU-VEN-001 y `esquema-datos.md`.
--
-- Forward-only: esta migración no se edita una vez aplicada.
-- ============================================================================

alter table public.venta
  add column items_esperados integer,
  add constraint venta_items_esperados_positivo check (items_esperados is null or items_esperados >= 1);

comment on column public.venta.items_esperados is
  'Cuántos renglones (venta_item vivos) lleva la venta cuando el teléfono la termina de armar (0158, '
  'backend-supabase#234). Opcional: sin él solo rige la regla de total por debajo de la suma (0150). Con todos los '
  'ítems llegados, el servidor exige motivo_monto_manual si el total difiere de la suma en cualquier sentido.';

create or replace function public.tg_venta_exige_motivo_si_el_total_baja()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_venta_id  uuid;
  v_total     integer;
  v_motivo    text;
  v_baja      timestamptz;
  v_esperados integer;
  v_suma      bigint;
  v_cuantos   integer;
begin
  if tg_table_name = 'venta_item' then
    -- Un ítem dado de baja solo puede achicar la suma y la cantidad.
    if new.deleted_at is not null then
      return null;
    end if;
    v_venta_id := new.venta_id;
  else
    v_venta_id := new.id;
  end if;

  -- DEFINER: la suma y la cuenta son las de TODOS los ítems vivos de la venta, los vea o no quien escribe.
  select v.monto_total, v.motivo_monto_manual, v.deleted_at, v.items_esperados,
         (select coalesce(sum(i.subtotal), 0)
            from public.venta_item i
           where i.venta_id = v.id and i.deleted_at is null),
         (select count(*)::integer
            from public.venta_item i
           where i.venta_id = v.id and i.deleted_at is null)
    into v_total, v_motivo, v_baja, v_esperados, v_suma, v_cuantos
    from public.venta v
   where v.id = v_venta_id;

  if found and v_baja is null and v_motivo is null
     and (v_suma > v_total
          or (v_esperados is not null and v_cuantos >= v_esperados and v_suma <> v_total)) then
    raise exception 'El total de la venta no coincide con la suma de sus productos y falta el motivo. Escribí por qué cambiaste el total (por ejemplo, «descuento por pago en efectivo») y guardá de nuevo.'
      using errcode = '23514';
  end if;
  return null;
end;
$$;

comment on function public.tg_venta_exige_motivo_si_el_total_baja() is
  'AFTER de fila sobre venta (monto_total, motivo_monto_manual, deleted_at, items_esperados) y venta_item (alta, '
  'subtotal, venta_id, baja) (0150 y 0158, backend-supabase#206 y #234): si una venta viva no tiene '
  'motivo_monto_manual y el total es menor que la suma de los subtotales de sus ítems vivos, 23514; con '
  'items_esperados y todos los ítems llegados, también si el total es mayor. DEFINER para sumar todos los ítems '
  'sin importar la RLS.';

drop trigger venta_exige_motivo_si_el_total_baja on public.venta;
create trigger venta_exige_motivo_si_el_total_baja
  after insert or update of monto_total, motivo_monto_manual, deleted_at, items_esperados on public.venta
  for each row execute function public.tg_venta_exige_motivo_si_el_total_baja();
