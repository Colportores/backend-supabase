-- ============================================================================
-- 0172 · Anular una devolución: las 24 h con la hora del teléfono y los 15 días de gracia también en el servidor
--        (backend-supabase#246, BACK-HU-VEN-004; seguimiento de #172 / 0121; decisión «Anular offline» de Cristian
--        del 27/10, regla R7 y la decisión del 26/10 en #134; docs-organizacion#170)
--
-- ## El caso
--
-- Lucía registra una devolución sin señal y la anula a las 20 h; la anulación sube a las 30 h. La app aplica las
-- 24 h para anular una devolución (ADR-002, «Efectos» 6), pero hasta hoy el servidor aceptaba cualquier baja de
-- `devolucion` (0121 dejó esa parte esperando «Anular offline»). Cristian respondió: la hora del teléfono, con 15
-- días de gracia. La devolución usa el MISMO criterio que la anulación de un cobro (0151), con su plazo de 24 h.
--
-- ## Qué cambia
--
-- Un trigger nuevo, BEFORE INSERT / UPDATE OF deleted_at en `devolucion`, que juzga la hora de la baja
-- (`deleted_at`, la del teléfono) cuando la dueña de la devolución anula con sesión:
--
--   · DV002 · la hora no es de fiar: es del futuro (con los 5 minutos de margen del reloj adelantado de 0151) o
--     anterior a `fecha_devolucion`. Revisá la fecha y la hora del teléfono.
--   · DV001 · pasaron más de 24 h (inclusive) desde `fecha_devolucion` hasta la hora en que se anuló. Mide la hora
--     del teléfono, no la de subida: anulada a las 20 h y subida a las 30 h pasa.
--   · DV003 · la anulación subió fuera de la gracia de 15 días. Es la regla de los cobros (`cobro_fuera_de_gracia`,
--     0151) tomando la fecha de la devolución: si la gracia de la campaña de la venta estaba abierta cuando se
--     registró la devolución, rige mientras esa campaña admita escrituras; si la venta no tiene campaña o la gracia
--     ya estaba vencida entonces, la anulación sube dentro de los 15 días desde la devolución.
--
-- La fila rechazada no cambia y no deja `devolucion_anulada` en `audit_log` (el rechazo deshace la sentencia). Un
-- alta que ya llega anulada (registrada y anulada sin señal, sube todo junto) se juzga igual. Un reenvío de un alta
-- que ya está no se vuelve a juzgar (replay idempotente, como en cobranza), ni una baja repetida (la fila ya estaba
-- anulada). No se juzga lo que no es de la dueña: el coordinador y el ADMIN no tienen hoy política de escritura
-- sobre `devolucion` (la devolución del coordinador pasadas las 72 h es de otro issue), y sin sesión (service_role,
-- migraciones, el editor SQL) el servidor no controla nada.
--
-- `sync.aplicar_job` agrega DV001 a DV003 a los códigos propios que vuelven `invalid` sin tumbar el lote. Es el
-- cuerpo de 0131 más esos tres.
--
-- ## Los datos
--
-- Solo funciones y un trigger: ninguna fila cambia, ningún `sync_version` ni `xmin_w` se mueve. Las devoluciones ya
-- anuladas quedan como están (el trigger solo mira la baja que pasa de null a una fecha). Datos simulados hasta
-- diciembre: sin migración de limpieza.
--
-- ## Para otros repos
--
--   · front-colportores-mobile: la app traduce DV001 («Pasaron más de 24 horas desde que registraste la
--     devolución: ya no se puede anular»), DV002 («Revisá la fecha y la hora de tu teléfono») y DV003 («Pasaron
--     más de 15 días: pedile a tu coordinador que lo revise»). `invalid`, sin reintento: la baja local queda
--     marcada para que la colportora la vea.
--   · docs-organizacion#170: esquema-datos.md y HU-VEN-004 dejan de decir que el servidor espera «Anular offline».
--
-- Forward-only: esta migración no se edita una vez aplicada.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. El trigger
-- ----------------------------------------------------------------------------

create function public.tg_devolucion_anulacion_a_tiempo()
returns trigger
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_dueno       uuid;
  v_venta_fecha timestamptz;
  v_fuera       text;
begin
  -- Solo la baja que se está haciendo: la fila entra anulada, o pasa de viva a anulada. Una baja repetida (ya estaba
  -- anulada) o cualquier otro UPDATE no se juzga. (`old` no existe en un INSERT: se lee en su propio `if`.)
  if new.deleted_at is null then
    return new;
  end if;
  if tg_op = 'UPDATE' and old.deleted_at is not null then
    return new;
  end if;

  -- Reenvío de un alta que ya está: el push la resuelve como `duplicate` (contrato §7); los BEFORE triggers corren
  -- antes del `on conflict do nothing` y no deben juzgar de nuevo una anulación vieja.
  if tg_op = 'INSERT' and exists (select 1 from public.devolucion d where d.id = new.id) then
    return new;
  end if;

  -- Sin sesión (service_role, migraciones, el editor SQL) no hay control: es la salida para corregir un dato a
  -- mano. Con sesión de otra persona que la dueña, la política de escritura es la que decide.
  if auth.uid() is null or auth.uid() is distinct from new.colportor_id then
    return new;
  end if;

  -- Lo que falta lo dicen su propio error (NOT NULL, FK o la política): acá no se opina.
  if new.fecha_devolucion is null or new.venta_id is null then
    return new;
  end if;

  -- «Anular offline»: la hora que cuenta es la del teléfono en que se anuló. Del futuro (5 minutos de margen para un
  -- reloj adelantado, como en los cobros) o anterior a la devolución no es de fiar.
  if new.deleted_at > now() + interval '5 minutes' or new.deleted_at < new.fecha_devolucion then
    raise exception using
      errcode = 'DV002',
      message = 'La hora de la anulación no es válida: no puede ser del futuro ni anterior a la devolución. Revisá la fecha y la hora de tu teléfono.';
  end if;

  -- Las 24 h son desde que se registró la devolución hasta que se anuló, las dos con la hora del teléfono.
  if new.deleted_at > new.fecha_devolucion + interval '24 hours' then
    raise exception using
      errcode = 'DV001',
      message = 'Pasaron más de 24 horas desde que registraste la devolución: ya no se puede anular.';
  end if;

  -- La gracia de 15 días: la misma regla que la anulación de un cobro, con la fecha de la devolución.
  select v.colportor_id, v.fecha into v_dueno, v_venta_fecha from public.venta v where v.id = new.venta_id;
  if found then
    v_fuera := public.cobro_fuera_de_gracia(v_dueno, v_venta_fecha, new.fecha_devolucion);
    if v_fuera is not null then
      raise exception using
        errcode = 'DV003',
        message = case v_fuera
          when 'CAMPANIA' then 'La campaña de esta venta terminó hace más de 15 días: la devolución ya no se puede anular. Pedile a tu coordinador que lo revise.'
          else 'Pasaron más de 15 días desde la devolución: ya no se puede anular. Pedile a tu coordinador que lo revise.'
        end;
    end if;
  end if;

  return new;
end;
$$;

comment on function public.tg_devolucion_anulacion_a_tiempo() is
  'BEFORE INSERT / UPDATE OF deleted_at de devolucion (0172, #246, «Anular offline»): la dueña anula con la hora del '
  'teléfono (deleted_at): ni del futuro (5 minutos de margen) ni anterior a la devolución (DV002), dentro de las 24 h '
  'desde fecha_devolucion (DV001) y dentro de la gracia de 15 días de la campaña de la venta, o 15 días desde la '
  'devolución si la venta no tiene campaña o su gracia ya estaba vencida entonces (DV003, cobro_fuera_de_gracia). '
  'Se juzga la baja que pasa de null a una fecha, también la de un alta que ya llega anulada; una baja repetida o un '
  'reenvío del alta no. Sin sesión, o con la sesión de otra persona, no controla nada. Nunca deja devolucion_anulada.';

revoke all on function public.tg_devolucion_anulacion_a_tiempo() from public, anon, authenticated, service_role;

create trigger devolucion_anulacion_a_tiempo
  before insert or update of deleted_at on public.devolucion
  for each row execute function public.tg_devolucion_anulacion_a_tiempo();

-- La nota de 0121 decía que las 24 h esperaban «Anular offline»: ya se aplican.
comment on function public.tg_devolucion_auditar_baja() is
  'AFTER UPDATE OF deleted_at en devolucion, cuando pasa de null a una fecha (0121, backend-supabase#172, '
  'HU-VEN-004, ADR-002): deja devolucion_anulada en audit_log con el mismo detalle que la alta. Una baja '
  'repetida o otro UPDATE no registran nada. Las 24 h con la hora del teléfono y los 15 días de gracia los juzga '
  'antes tg_devolucion_anulacion_a_tiempo (0172): una anulación rechazada no deja evento.';

-- ----------------------------------------------------------------------------
-- 2. El push: DV001 a DV003 vuelven invalid, sin tumbar el lote
-- ----------------------------------------------------------------------------

-- Igual que en 0131, más DV001, DV002 y DV003 (0172). Sus privilegios siguen (create or replace los conserva).
create or replace function sync.aplicar_job(p_job jsonb)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_id          uuid;
  v_restriccion text;
begin
  -- El cast va adentro del bloque protegido: un client_op_id malformado es un
  -- payload inválido, no un 500.
  begin
    v_id := (p_job ->> 'client_op_id')::uuid;
  exception when data_exception then
    v_id := null;
  end;

  return sync.aplicar_job_interno(v_id, p_job);
exception
  -- Clase 22, clase 23 y 42501: el payload está mal o la RLS rechazó la fila. INVALID, sin
  -- reintento automático, y sin tumbar al resto del lote (ver 0002).
  --
  -- Menos D1 (0017): misma dirección a menos de 100 m de otra ubicación viva. No es un payload
  -- roto: la fila es buena y la resuelve el colportor en la vista 10. Vuelve como conflicto, sin
  -- server_row (no hay fila del servidor que aplicar), y no entra al cache de client_op_id.
  when data_exception or integrity_constraint_violation or insufficient_privilege then
    get stacked diagnostics v_restriccion = constraint_name;
    if sqlstate = '23505' and v_restriccion = 'ubicacion_direccion_unica' then
      return jsonb_build_object(
        'client_op_id', v_id,
        'outcome', 'conflict',
        'code', sqlstate,
        'constraint', v_restriccion,
        'message', sqlerrm
      );
    end if;
    return jsonb_build_object(
      'client_op_id', v_id,
      'outcome', 'invalid',
      'code', sqlstate,
      'message', sqlerrm
    );
  -- La baja de una casa con ventas o con visitas de otro colportor (0018), la corrección ajena en la
  -- gracia (CG001, 0021), reactivar una casa que se unió a otra (UB005, 0051) y los topes de las cuotas
  -- (AG001 a AG003, 0068) y anular un cobro fuera de plazo, con el ticket validado o ya anulado (CB001 a
  -- CB003, CB005 y CB006, 0072), el cobro que ya no se puede cambiar, la hora de anulación inválida y la anulación fuera de la
  -- gracia (CB007 a CB009, 0131), anular una devolución pasadas las 24 h, con una hora inválida o fuera de la gracia
  -- (DV001 a DV003, 0172) y la unión de duplicados con A de baja o con B = A (UB003 y UB004, 0101): códigos propios, que la
  -- app traduce a un aviso. INVALID como el resto, sin tumbar el lote.
  when sqlstate 'UB001' or sqlstate 'UB002' or sqlstate 'UB003' or sqlstate 'UB004' or sqlstate 'CG001' or sqlstate 'UB005'
    or sqlstate 'AG001' or sqlstate 'AG002' or sqlstate 'AG003'
    or sqlstate 'CB001' or sqlstate 'CB002' or sqlstate 'CB003' or sqlstate 'CB005' or sqlstate 'CB006'
    or sqlstate 'CB007' or sqlstate 'CB008' or sqlstate 'CB009'
    or sqlstate 'DV001' or sqlstate 'DV002' or sqlstate 'DV003' then
    return jsonb_build_object(
      'client_op_id', v_id,
      'outcome', 'invalid',
      'code', sqlstate,
      'message', sqlerrm
    );
end;
$$;
