-- ============================================================================
-- 0150 · Tope del número de talonario y motivo obligatorio cuando el total de la venta queda por debajo
--        de la suma de sus ítems (backend-supabase#206, seguimiento de front-colportores-mobile#158,
--        HU-VEN-001; decisiones de Cristian del 27/10 y del 28/10 en front-colportores-mobile#531)
--
-- Dos reglas que la app ya aplica y que el servidor tiene que aplicar igual («el mismo tope en el
-- servidor que en la UI», seguridad barata):
--
--   1. «Talonario» · CHECK `venta_numero_talonario_forma`: entre 1 y 30 caracteres (`char_length`, no
--      bytes), sin espacios ni saltos de línea al principio ni al final (el mismo `^\S(.*\S)?$` de
--      `venta_motivo_monto_manual_forma`, 0071). Hasta hoy el servidor aceptaba cualquier largo
--      (`text not null` desde la 0001). Rechazo: 23514, que el push devuelve como `invalid`.
--
--   2. «Motivo del monto» · si el total de la venta queda POR DEBAJO de la suma de los subtotales de
--      sus ítems vivos y `motivo_monto_manual` es nulo, el servidor rechaza con 23514 (`invalid` en el
--      push). Ana baja el total de $ 8.900 a $ 8.500 y no escribe el motivo: la app no la deja guardar
--      y el servidor tampoco acepta esa venta.
--
-- ## Por qué es un trigger sobre las dos tablas y no un CHECK ni un trigger diferido
--
-- La venta y sus ítems son filas distintas, y el motor las sube como jobs distintos: «un ítem nunca
-- antes que su venta» (la FK), en lotes de hasta 500 jobs o 1 MB. Así que la venta puede entrar en un
-- lote (y un COMMIT) y sus ítems en el siguiente:
--   · un CHECK no puede mirar otras filas;
--   · un trigger DIFERIDO corre en el COMMIT del lote: rechazaría toda venta cuyos ítems vengan en el
--     lote siguiente («el chequeo no puede rechazar una venta porque sus ítems todavía no llegaron») y,
--     peor, un error en el COMMIT tumba el lote ENTERO y no un job (no hay `invalid` por job).
-- Por eso el chequeo es de lo que SIEMPRE es cierto, llegue en el orden que llegue: la suma de los
-- ítems vivos solo crece a medida que llegan, así que «la suma ya supera al total y no hay motivo» no
-- puede arreglarse con lo que falta subir. Se mira en cada escritura que puede provocarlo:
--   · AFTER INSERT/UPDATE de `venta_item` (llega un ítem, cambia su subtotal o su venta, o se revive):
--     el ítem que hace pasar la suma del total vuelve `invalid`; los anteriores quedan.
--   · AFTER INSERT/UPDATE de `venta` (monto_total, motivo_monto_manual, deleted_at): cubre bajar el
--     total o borrar el motivo cuando los ítems ya están.
-- Son AFTER de fila: un reintento del push (`INSERT … ON CONFLICT DO NOTHING`) no inserta nada y no
-- dispara nada, y en un INSERT de varios ítems la suma ya los incluye a todos.
--
-- ## Lo que NO cubre (queda anotado en el archivo de pendientes de esta entrega)
--
-- El otro sentido, total POR ENCIMA de la suma de los ítems sin motivo, no se puede decidir mientras
-- suben: es lo que pasa en cada venta normal entre que entra la venta y entra su último ítem, y el
-- servidor no sabe cuál es el último (la venta no dice cuántos ítems tiene). Se rechazaría una venta
-- buena. Cerrarlo pide un dato nuevo en la venta (cuántos ítems lleva): decisión de modelo de Cristian.
-- Tampoco se rechaza una venta sin ningún ítem: sin ítems no hay con qué compararla.
--
-- ## Los datos
--
--   · El CHECK del talonario se agrega validado si todas las filas lo cumplen; si alguna no (datos
--     simulados hasta diciembre, sin migración de limpieza), queda NOT VALID —rige para toda fila nueva
--     o modificada— y se avisa con un WARNING; no se toca ninguna fila.
--   · El trigger del motivo solo mira filas que se escriben: una venta anterior que ya lo incumple
--     sigue como está (y un cambio en su `espacio_persona_id`, como la unión de duplicados, no lo
--     dispara: solo miran `monto_total`, `motivo_monto_manual` y `deleted_at`).
--
-- ## Para otros repos
--   · front-colportores-mobile: nada que cambiar, la app ya rechaza lo mismo (#158, #531).
--   · docs-organizacion: HU-VEN-001 y `esquema-datos.md` (tope del talonario y motivo obligatorio) y la
--     excepción de la regla «Justificar» (el motivo pasa a ser obligatorio con el total bajado a mano).
--
-- Forward-only: esta migración no se edita una vez aplicada.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. Talonario: entre 1 y 30 caracteres, sin espacios ni saltos de línea en los extremos
-- ----------------------------------------------------------------------------

do $mig$
begin
  if exists (select 1 from public.venta
              where not (char_length(numero_talonario) between 1 and 30
                         and numero_talonario ~ '^\S(.*\S)?$')) then
    alter table public.venta
      add constraint venta_numero_talonario_forma
      check (char_length(numero_talonario) between 1 and 30 and numero_talonario ~ '^\S(.*\S)?$') not valid;
    raise warning '0150: hay ventas con un número de talonario que no cumple la forma (1 a 30 caracteres, sin espacios en los extremos): el CHECK venta_numero_talonario_forma quedó NOT VALID para no tocar datos; rige para toda venta nueva o modificada.';
  else
    alter table public.venta
      add constraint venta_numero_talonario_forma
      check (char_length(numero_talonario) between 1 and 30 and numero_talonario ~ '^\S(.*\S)?$');
  end if;
end
$mig$;

comment on column public.venta.numero_talonario is
  'Número del recibo físico (R-VE02, único por colportor y año, 0071). Entre 1 y 30 caracteres '
  'visibles, sin espacios ni saltos de línea al principio ni al final: el mismo tope que la app '
  '(0150, backend-supabase#206).';

-- ----------------------------------------------------------------------------
-- 2. Motivo del monto: obligatorio si el total queda por debajo de la suma de los ítems
-- ----------------------------------------------------------------------------

create function public.tg_venta_exige_motivo_si_el_total_baja()
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
  v_suma      bigint;
begin
  if tg_table_name = 'venta_item' then
    -- Un ítem dado de baja solo puede achicar la suma.
    if new.deleted_at is not null then
      return null;
    end if;
    v_venta_id := new.venta_id;
  else
    v_venta_id := new.id;
  end if;

  -- DEFINER: la suma es la de TODOS los ítems vivos de la venta, los vea o no quien escribe.
  select v.monto_total, v.motivo_monto_manual, v.deleted_at,
         (select coalesce(sum(i.subtotal), 0)
            from public.venta_item i
           where i.venta_id = v.id and i.deleted_at is null)
    into v_total, v_motivo, v_baja, v_suma
    from public.venta v
   where v.id = v_venta_id;

  if found and v_baja is null and v_motivo is null and v_suma > v_total then
    raise exception 'El total de la venta es menor que la suma de sus productos y falta el motivo. Escribí por qué cambiaste el total (por ejemplo, «descuento por pago en efectivo») y guardá de nuevo.'
      using errcode = '23514';
  end if;
  return null;
end;
$$;

comment on function public.tg_venta_exige_motivo_si_el_total_baja() is
  'AFTER de fila sobre venta (monto_total, motivo_monto_manual, deleted_at) y venta_item (alta, subtotal, '
  'venta_id, baja) (0150, backend-supabase#206): si el total de una venta viva es menor que la suma de '
  'los subtotales de sus ítems vivos y no tiene motivo_monto_manual, 23514. Solo ese sentido: el inverso '
  'no se decide mientras los ítems suben. DEFINER para sumar todos los ítems sin importar la RLS.';

revoke all on function public.tg_venta_exige_motivo_si_el_total_baja()
  from public, anon, authenticated, service_role;

create trigger venta_exige_motivo_si_el_total_baja
  after insert or update of monto_total, motivo_monto_manual, deleted_at on public.venta
  for each row execute function public.tg_venta_exige_motivo_si_el_total_baja();

create trigger venta_item_exige_motivo_si_el_total_baja
  after insert or update of subtotal, venta_id, deleted_at on public.venta_item
  for each row execute function public.tg_venta_exige_motivo_si_el_total_baja();

comment on column public.venta.motivo_monto_manual is
  'Por qué el colportor cambió el total a mano (ej. «descuento por pago en efectivo»). Texto libre que '
  'sube con la venta y lee el coordinador: excepción explícita de Cristian (23/10) a «Justificar», solo '
  'para este campo; la app avisa que no se pongan datos del cliente. Null, o hasta 500 caracteres sin '
  'espacios ni saltos de línea en los extremos (0071). Obligatorio si el total queda por debajo de la '
  'suma de los ítems (0150, backend-supabase#206, decisión de Cristian del 28/10).';
