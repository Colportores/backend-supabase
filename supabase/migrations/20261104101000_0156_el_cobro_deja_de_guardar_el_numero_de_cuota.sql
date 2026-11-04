-- ============================================================================
-- 0156 · El cobro deja de guardar el número de cuota
--        (backend-supabase#234, casilla «N.º de cuota»; decisión de Cristian del 03/11 en
--        front-colportores-mobile#579: «Dejar de guardarlo»)
--
-- Ana le cobra $ 1.000 a María: completa la cuota 2 y adelanta parte de la 3. El cobro guardaba un solo «número de
-- cuota» (la 2), que no decía la verdad cuando un cobro cubre dos. Qué cuotas cubrió cada cobro se calcula con los cobros y
-- las cuotas de la venta (el reparto es del teléfono, `RepartoDeCuotas`); el servidor no lo necesita: ningún tope ni
-- ninguna lectura suya miraba `cobranza.numero_cuota` (AG002 compara el monto de la cuota con el saldo de la venta).
--
--   · Se saca la columna `cobranza.numero_cuota` (smallint, nullable, desde la 0001) y su CHECK.
--   · `tg_cobranza_anulacion()` (0072, 0131, 0151) comparaba la columna entre `new` y `old` para el cobro fijo
--     (CB007): se reescribe sin ella, con el resto del cuerpo igual (sus privilegios y su trigger siguen).
--   · Un push que todavía mande `numero_cuota` en el payload no falla: `sync.columnas_escribibles` solo deja pasar las
--     columnas que existen y descarta el resto.
--
-- ## Los datos
--
--   La columna se pierde con su contenido: es un número de apoyo (qué cuota creía cubrir el cobro) y no un dato de la venta,
--   el cobro, el monto, el medio ni la fecha: ningún cobro ni venta se toca. Datos simulados hasta diciembre.
--
-- ## Para otros repos
--   · front-colportores-mobile#608: deja de mandar `numero_cuota` y de guardarlo; el aviso de baja toma el número de la
--     lista de cuotas. Va después de esta migración.
--   · docs-organizacion: `esquema-datos.md` y `contrato-sync-engine.md` §2 (la fila de `cobranza`): sin `numero_cuota`.
--
-- Forward-only: esta migración no se edita una vez aplicada.
-- ============================================================================

-- El trigger primero: su cuerpo comparaba la columna que se va (plpgsql no lo detecta al soltarla).
create or replace function public.tg_cobranza_anulacion()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_dueno          uuid;
  v_es_duena       boolean;
  v_fecha_cobro    timestamptz;
  v_ticket_viejo   uuid;
  v_venta_fecha    timestamptz;
  v_hora           timestamptz;
  v_con_hora       boolean := false;
  v_fuera          text;
begin
  -- Un cobro nuevo que ya trae su hora de corrección (corregido en el teléfono antes de subir por primera vez) entra
  -- igual y sin juzgar esa hora: en un alta el servidor no ve el cobro original, así que ni las 72 h ni la gracia se
  -- pueden medir, y rechazarlo haría perder un cobro vivo (nunca se pierde una venta). La hora solo cuenta cuando una
  -- corrección llega después, sobre un cobro que ya está (el UPDATE de abajo).

  if tg_op = 'UPDATE' and auth.uid() is not null then
    -- El cobro fijo (CB007): pasado el plazo de 72 h desde el cobro, o con su ticket validado, no cambian monto,
    -- fecha ni medio, ni la venta, ni los datos de la tarjeta o de la transferencia, y no se da de baja ni se reactiva.
    -- El reenvío idéntico no cambia nada y pasa; atarle el ticket (ticket_id) y anular tampoco tocan estas columnas.
    -- Dentro del plazo y sin ticket validado, la dueña corrige monto, medio y esos datos sin más (la fecha, no: CB006).
    if (new.venta_id, new.monto, new.medio, new.fecha, new.deleted_at, new.tarjeta_tipo, new.tarjeta_marca,
        new.numero_aprobacion, new.referencia_transferencia, new.banco_origen)
       is distinct from
       (old.venta_id, old.monto, old.medio, old.fecha, old.deleted_at, old.tarjeta_tipo, old.tarjeta_marca,
        old.numero_aprobacion, old.referencia_transferencia, old.banco_origen) then
      -- «Corregir off»: la hora que cuenta es la del teléfono en que se corrigió, si la app la manda (una hora
      -- nueva); si no, la del servidor, como siempre.
      if new.corregido_at is not null and new.corregido_at is distinct from old.corregido_at then
        v_hora := new.corregido_at;
        v_con_hora := true;
        if v_hora > now() + interval '5 minutes' or v_hora < old.fecha then
          raise exception using
            errcode = 'CB008',
            message = 'La hora de la corrección no es válida: no puede ser del futuro ni anterior al cobro. Revisá la fecha y la hora de tu teléfono.';
        end if;
      else
        v_hora := now();
      end if;

      if v_hora > old.fecha + interval '72 hours'
         or exists (select 1 from public.ticket t
                     where t.id = old.ticket_id and t.estado = 'VALIDADO' and t.deleted_at is null) then
        raise exception using
          errcode = 'CB007',
          message = 'Este cobro ya no se puede cambiar. Si está mal, pedile a tu coordinador que lo revise.';
      end if;

      -- La corrección hecha sin señal también tiene que subir dentro de la gracia (la misma regla que la anulación).
      -- Con la hora del servidor no hace falta: ya está dentro de las 72 h.
      if v_con_hora then
        select v.colportor_id, v.fecha into v_dueno, v_venta_fecha from public.venta v where v.id = old.venta_id;
        if v_dueno is not distinct from auth.uid() then
          v_fuera := public.cobro_fuera_de_gracia(v_dueno, v_venta_fecha, old.fecha);
          if v_fuera is not null then
            raise exception using
              errcode = 'CB009',
              message = case v_fuera
                when 'CAMPANIA' then 'La campaña de esta venta terminó hace más de 15 días: el cobro ya no se puede corregir. Pedile a tu coordinador que lo revise.'
                else 'Pasaron más de 15 días desde el cobro: ya no se puede corregir. Pedile a tu coordinador que lo revise.'
              end;
          end if;
        end if;
      end if;
    end if;

    -- Las dos cosas de las que cuelgan CB001 y CB002 no se mueven con sesión: la fecha del cobro (desde ella
    -- corre la ventana) y el ticket validado (suelto, el cobro dejaría de estar protegido). Sin esto, un UPDATE
    -- anterior que no anula nada las cambiaría y el siguiente anularía (CB005, CB006). Va antes de todo lo
    -- demás: vale para cualquier UPDATE con sesión, anule o no.
    if new.fecha is distinct from old.fecha then
      raise exception using
        errcode = 'CB006',
        message = 'La fecha de un cobro no se puede cambiar. Si te equivocaste, anulalo y cargalo de nuevo.';
    end if;
    if new.ticket_id is distinct from old.ticket_id
       and exists (select 1 from public.ticket t
                    where t.id = old.ticket_id and t.estado = 'VALIDADO' and t.deleted_at is null) then
      raise exception using
        errcode = 'CB005',
        message = 'El coordinador ya validó el ticket de este cobro: no se puede cambiar ni soltar.';
    end if;
  end if;

  -- Nada que controlar: el cobro no está (ni estaba) anulado.
  if new.anulado_at is null and (tg_op = 'INSERT' or old.anulado_at is null) then
    return new;
  end if;

  -- Reenvío de un alta que ya está: el push la resuelve como `duplicate` (contrato §7); los BEFORE
  -- triggers corren antes del `on conflict do nothing` y no deben juzgar de nuevo una anulación vieja.
  if tg_op = 'INSERT' and exists (select 1 from public.cobranza c where c.id = new.id) then
    return new;
  end if;

  -- Sin sesión: el servidor (service_role, migraciones, el editor SQL) no pasa por ningún control; es la salida
  -- para corregir un dato a mano.
  if auth.uid() is null then
    return new;
  end if;

  if tg_op = 'UPDATE' and old.anulado_at is not null then
    -- Ya estaba anulado: lo mismo es un reintento; cambiarlo o borrarlo, no.
    if new.anulado_at is distinct from old.anulado_at
       or new.motivo_anulacion is distinct from old.motivo_anulacion then
      raise exception using
        errcode = 'CB003',
        message = 'Este cobro ya está anulado y no se puede volver a habilitar ni cambiarle el motivo.';
    end if;
    return new;
  end if;

  -- De acá en más, alguien con sesión anula (un cobro nuevo ya anulado, o uno vivo que pasa a anulado).
  -- (`old` no existe en un INSERT: se lee en su propio `if`.)
  if tg_op = 'UPDATE' then
    v_fecha_cobro := old.fecha;
    v_ticket_viejo := old.ticket_id;
  else
    v_fecha_cobro := new.fecha;
  end if;

  select v.colportor_id, v.fecha into v_dueno, v_venta_fecha from public.venta v where v.id = new.venta_id;
  v_es_duena := v_dueno is not distinct from auth.uid();

  -- «Anular offline»: la hora que cuenta es la del teléfono en que se anuló. Una hora del futuro (con 5 minutos de
  -- margen para un reloj adelantado, «Reloj adel.»), o anterior al cobro, no es de fiar: se rechaza con un aviso que
  -- lo dice. Solo a la colportora: el coordinador y el ADMIN anulan con la hora del servidor (`anular_cobro`).
  if v_es_duena and (new.anulado_at > now() + interval '5 minutes' or new.anulado_at < v_fecha_cobro) then
    raise exception using
      errcode = 'CB008',
      message = 'La hora de la anulación no es válida: no puede ser del futuro ni anterior al cobro. Revisá la fecha y la hora de tu teléfono.';
  end if;
  if new.anulado_at > v_fecha_cobro + interval '72 hours' then
    raise exception using
      errcode = 'CB001',
      message = 'Pasaron más de 72 horas desde el cobro: ya no se puede anular.';
  end if;

  -- La gracia de la anulación de la colportora (ver el encabezado, punto 3). El coordinador y el ADMIN no la
  -- tienen: una cuota cobrada tras ella la anulan ellos (dentro de las 72 h).
  if v_es_duena then
    v_fuera := public.cobro_fuera_de_gracia(v_dueno, v_venta_fecha, v_fecha_cobro);
    if v_fuera is not null then
      raise exception using
        errcode = 'CB009',
        message = case v_fuera
          when 'CAMPANIA' then 'La campaña de esta venta terminó hace más de 15 días: el cobro ya no se puede anular. Pedile a tu coordinador que lo revise.'
          else 'Pasaron más de 15 días desde el cobro: ya no se puede anular. Pedile a tu coordinador que lo revise.'
        end;
    end if;
  end if;

  if v_es_duena then
    -- La colportora: con el ticket validado ya no anula sola.
    if exists (
         select 1
           from public.ticket t
          where t.id in (new.ticket_id, v_ticket_viejo)
            and t.estado = 'VALIDADO'
            and t.deleted_at is null) then
      raise exception using
        errcode = 'CB002',
        message = 'El coordinador ya validó el ticket de este cobro. Pedile que lo anule él.';
    end if;
  elsif not (public.tiene_rol('ADMIN') or public.tiene_rol('COORDINADOR')) then
    raise exception using
      errcode = '42501',
      message = 'Ese cobro es de otra persona: no se puede anular.';
  end if;

  return new;
end;
$$;

comment on function public.tg_cobranza_anulacion() is
  'BEFORE INSERT / UPDATE de cobranza (0072, 0131, 0151, 0156): cobro fijo pasadas 72 h o con el ticket validado: no cambian '
  'monto, fecha ni medio ni se da de baja (CB007); la corrección se mide con la hora del teléfono (corregido_at) si la '
  'app la manda, y entonces tiene que subir dentro de la gracia (CB009); la fecha del cobro y un ticket validado no se '
  'mueven (CB006, CB005). Al anular: la hora de la anulación es la del teléfono, ni futura (5 minutos de margen) ni '
  'anterior al cobro (CB008), dentro de las 72 h desde el cobro (CB001) y dentro de la gracia: mientras la campaña de '
  'la venta admite escrituras, o 15 días desde el cobro si la venta no tiene campaña o su gracia ya estaba vencida al '
  'cobrar (CB009; CB008 y CB009 solo para la colportora, no para el coordinador ni el ADMIN); la colportora no anula '
  'con el ticket validado (CB002); un cobro anulado no se reabre ni cambia (CB003). Sin sesión (service_role, '
  'migraciones) no controla nada. Un alta que ya existe se deja pasar (replay idempotente).';

alter table public.cobranza drop column numero_cuota;
