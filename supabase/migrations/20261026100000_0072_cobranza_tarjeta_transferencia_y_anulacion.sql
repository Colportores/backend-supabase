-- ============================================================================
-- 0072 · Cobranza: datos de la tarjeta y de la transferencia, y anulación con fecha, motivo y ventana
--        de 72 h (backend-supabase#133, HU-COB-002, HU-COB-003 y HU-COB-006; decisiones de Cristian
--        del 23/10 «Datos cobro», «Anulación» y «Anular 72 h», front-colportores-mobile#164 y #168)
--
-- ## Qué cambia
--
--   1. «Datos cobro» · el cobro guarda lo que el ticket de la tarjeta (V2) va a tomar de ahí. Columnas
--      opcionales nuevas de `public.cobranza` (la migración solo suma; ninguna fila existente cambia):
--        · `tarjeta_tipo`      'CREDITO' | 'DEBITO'              (los mismos valores que `ticket`)
--        · `tarjeta_marca`     texto, 1 a 40 caracteres          (Visa, Mastercard, OCA, Otra…)
--        · `numero_aprobacion` texto, 1 a 40 caracteres          (lo dice el ticket del POS)
--        · `referencia_transferencia` texto, 1 a 40 caracteres   (el número de operación)
--        · `banco_origen`      texto, 1 a 60 caracteres          (texto, no una lista cerrada: sumar un
--                              banco no cambia el modelo; el canvas ofrece BROU, Itaú, Santander,
--                              Scotiabank, BBVA y «Otro»)
--        · `ticket_id`         FK opcional a `ticket` (ya figuraba en esquema-datos.md; lo llena la
--                              conexión de V2, #108/#110 y mobile HU-COB-007). Hoy nadie lo escribe.
--      Un CHECK (`cobranza_datos_segun_medio`) cuida la coherencia: los datos de tarjeta solo van en un
--      cobro con TARJETA y la referencia y el banco solo en uno con TRANSFERENCIA. Los datos de tarjeta
--      y de transferencia son opcionales (HU-COB-002: «Marca y aprobación son opcionales en V1»).
--   2. «Anulación» · `anulado_at` (timestamptz) y `motivo_anulacion` (texto de la lista del canvas):
--      'Monto equivocado', 'Cliente equivocado', 'Lo registré dos veces', 'Otro'. Van juntos o no va
--      ninguno (`cobranza_anulacion_completa`). Lo que escribe quien eligió «Otro» NO sube: queda en el
--      teléfono («Justificar»). Anular no es dar de baja: `deleted_at` sigue siendo otra cosa.
--   3. «Anular 72 h» · el servidor aplica la ventana de 72 horas desde el cobro (`fecha`) a la colportora
--      y al coordinador, y con el ticket validado la colportora no anula: se lo pide al coordinador.
--      Trigger `cobranza_anulacion` (BEFORE INSERT OR UPDATE):
--        · CB001 · pasaron más de 72 h desde el cobro (el reloj es el del SERVIDOR al escribir: `now()`
--          contra `fecha` + 72 h, inclusive). Sin excepciones para nadie con sesión.
--        · CB002 · la colportora quiere anular un cobro cuyo ticket ya validó el coordinador (el
--          `ticket_id` del cobro apunta a un ticket VALIDADO). El mensaje le dice que se lo pida a él.
--        · CB003 · un cobro anulado no se reabre ni cambia su fecha ni su motivo. Mandar de nuevo el mismo
--          valor es idempotente (un reintento del push no falla).
--      Sin sesión (service_role, migraciones, `postgres`) el trigger no controla nada: es la salida del
--      servidor para corregir un dato a mano, como en el resto de los triggers de control.
--   4. `anular_cobro(p_cobranza_id, p_motivo)` · la anulación del coordinador desde el panel (RPC,
--      SECURITY DEFINER). Lo puede hacer un ADMIN o el coordinador de una campaña en la que el colportor
--      de la venta esté inscripto (inscripción viva); a cualquier otro, o si el cobro no existe o está
--      dado de baja, le da el mismo CB004 (no se averigua qué cobros hay). Pone `anulado_at = now()` y el
--      motivo de la lista (22023 si falta o no está); la ventana de 72 h la aplica el trigger (CB001).
--      Un cobro ya anulado devuelve `ya_estaba` true y no se toca (un doble toque no sube dos veces la
--      versión de sync). El UPDATE sube `sync_version`: un push viejo del teléfono de ese cobro vuelve
--      `conflict`; como `cobranza` no baja al teléfono, la colportora se entera por el coordinador.
--   5. Lo que lee el servidor no cuenta lo anulado: el tope de la cuota (AG002, 0068) mide el saldo con
--      los cobros vivos Y no anulados (`tg_agenda_origen`, el único lugar del servidor que suma
--      `cobranza.monto`). Las lecturas del panel de hoy (tablero, ventas por ciudad, horas) no suman
--      cobros (el «por cobrar» es null hasta V2, 0061): cuando entren, filtran `anulado_at is null`.
--   6. El push: CB001, CB002 y CB003 vuelven `invalid` con su código, sin tumbar el lote
--      (`sync.aplicar_job`, igual que 0068 más estos tres).
--
-- ## Los datos
--
-- Solo se agregan columnas opcionales: ningún cobro cambia, ningún `sync_version` ni `xmin_w` se
-- mueve, ningún teléfono re-descarga ni re-sube nada. Lo prueba `tests_migracion/0072_ok`.
--
-- ## Para otros repos
--
--   · front-colportores-mobile#396 (esquema Drift y subida de los campos de la tarjeta y la
--     transferencia), #422 y #424 (la anulación: 30B-06 «pasaron las 72 h», 30B-07 «pedíselo a tu
--     coordinador»): la app sube `tarjeta_tipo`, `tarjeta_marca`, `numero_aprobacion`,
--     `referencia_transferencia`, `banco_origen`, `anulado_at` y `motivo_anulacion` en el mismo upsert
--     del cobro y traduce CB001/CB002/CB003 del `invalid` a un aviso. «Otro» sube como 'Otro'.
--   · front-coordinadores-web (junto a #69): «Anular cobro» llama a `anular_cobro(cobranza_id, motivo)`.
--   · docs-organizacion: `esquema-datos.md` (columnas de `cobranza`), `contrato-sync-engine.md` (la fila
--     de `cobranza` y los tres códigos nuevos del push), HU-COB-002, HU-COB-003 y HU-COB-006.
--
-- Forward-only: esta migración no se edita una vez aplicada.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. Las columnas
-- ----------------------------------------------------------------------------

alter table public.cobranza
  add column tarjeta_tipo              text,
  add column tarjeta_marca             text,
  add column numero_aprobacion         text,
  add column referencia_transferencia  text,
  add column banco_origen              text,
  add column ticket_id                 uuid references public.ticket(id),
  add column anulado_at                timestamptz,
  add column motivo_anulacion          text;

alter table public.cobranza
  add constraint cobranza_tarjeta_tipo_check
    check (tarjeta_tipo is null or tarjeta_tipo in ('CREDITO', 'DEBITO')),
  add constraint cobranza_tarjeta_marca_check
    check (tarjeta_marca is null or (btrim(tarjeta_marca) <> '' and char_length(tarjeta_marca) <= 40)),
  add constraint cobranza_numero_aprobacion_check
    check (numero_aprobacion is null or (btrim(numero_aprobacion) <> '' and char_length(numero_aprobacion) <= 40)),
  add constraint cobranza_referencia_transferencia_check
    check (referencia_transferencia is null
           or (btrim(referencia_transferencia) <> '' and char_length(referencia_transferencia) <= 40)),
  add constraint cobranza_banco_origen_check
    check (banco_origen is null or (btrim(banco_origen) <> '' and char_length(banco_origen) <= 60)),
  add constraint cobranza_motivo_anulacion_check
    check (motivo_anulacion is null
           or motivo_anulacion in ('Monto equivocado', 'Cliente equivocado', 'Lo registré dos veces', 'Otro')),
  add constraint cobranza_anulacion_completa
    check ((anulado_at is null) = (motivo_anulacion is null)),
  add constraint cobranza_datos_segun_medio
    check ((medio = 'TARJETA' or (tarjeta_tipo is null and tarjeta_marca is null and numero_aprobacion is null))
           and (medio = 'TRANSFERENCIA' or (referencia_transferencia is null and banco_origen is null)));

create index cobranza_ticket_idx on public.cobranza (ticket_id) where ticket_id is not null;

comment on column public.cobranza.tarjeta_tipo is
  'CREDITO | DEBITO; solo en un cobro con TARJETA (0072, decisión de Cristian del 23/10, «Datos cobro»). Opcional.';
comment on column public.cobranza.tarjeta_marca is
  'Marca de la tarjeta («Visa», «Mastercard», «OCA», o la que escriba); solo con TARJETA; 1 a 40 caracteres (0072). Opcional.';
comment on column public.cobranza.numero_aprobacion is
  'Número de aprobación del ticket de la tarjeta; solo con TARJETA; 1 a 40 caracteres (0072). Opcional en V1.';
comment on column public.cobranza.referencia_transferencia is
  'Número de operación de la transferencia; solo con TRANSFERENCIA; 1 a 40 caracteres (0072). Opcional.';
comment on column public.cobranza.banco_origen is
  'Banco de origen de la transferencia, como texto (no una lista cerrada); solo con TRANSFERENCIA; 1 a 60 caracteres (0072). Opcional.';
comment on column public.cobranza.ticket_id is
  'Ticket de la tarjeta de este cobro (V2, HU-COB-007). Si está VALIDADO, la colportora ya no anula el cobro: lo '
  'anula el coordinador (CB002, 0072). Hoy nadie lo escribe; lo conecta #108/#110.';
comment on column public.cobranza.anulado_at is
  'Cuándo se anuló el cobro (0072, «Anulación»). Un cobro anulado no cuenta: ni en el saldo de la venta ni en las '
  'lecturas del panel. Va junto con motivo_anulacion. No se reabre (CB003).';
comment on column public.cobranza.motivo_anulacion is
  'Motivo de la lista del canvas: «Monto equivocado», «Cliente equivocado», «Lo registré dos veces» u «Otro». '
  'El texto que la colportora escribe con «Otro» no sube.';

-- ----------------------------------------------------------------------------
-- 2. La ventana de 72 h, el ticket validado y «no se reabre»
-- ----------------------------------------------------------------------------

create function public.tg_cobranza_anulacion()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_dueno          uuid;
  v_inicio         timestamptz;
  v_ticket_viejo   uuid;
begin
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
    v_inicio := old.fecha;
    v_ticket_viejo := old.ticket_id;
  else
    v_inicio := new.fecha;
  end if;
  if now() > v_inicio + interval '72 hours' then
    raise exception using
      errcode = 'CB001',
      message = 'Pasaron más de 72 horas desde el cobro: ya no se puede anular.';
  end if;

  select v.colportor_id into v_dueno from public.venta v where v.id = new.venta_id;

  if v_dueno is not distinct from auth.uid() then
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
  'BEFORE INSERT / UPDATE de cobranza (0072): al anular, ventana de 72 h desde la fecha del cobro con el reloj del '
  'servidor (CB001), la colportora no anula con el ticket validado (CB002), un cobro anulado no se reabre ni cambia '
  '(CB003). Sin sesión (service_role, migraciones) no controla nada. Un alta que ya existe se deja pasar (replay idempotente).';

-- Antes de la auditoría (orden alfabético: cobranza_anulacion < cobranza_auditoria_*).
create trigger cobranza_anulacion
  before insert or update on public.cobranza
  for each row execute function public.tg_cobranza_anulacion();

revoke all on function public.tg_cobranza_anulacion() from public, anon, authenticated;

-- ----------------------------------------------------------------------------
-- 3. anular_cobro(): la anulación del coordinador
-- ----------------------------------------------------------------------------

create function public.anular_cobro(p_cobranza_id uuid, p_motivo text)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_cobro     public.cobranza;
  v_es_admin  boolean := public.tiene_rol('ADMIN');
begin
  if auth.uid() is null or not (v_es_admin or public.tiene_rol('COORDINADOR')) then
    raise exception using
      errcode = '42501',
      message = 'Solo un coordinador o un administrador puede anular un cobro. Entrá con tu cuenta de coordinador.';
  end if;

  if p_motivo is null or p_motivo not in ('Monto equivocado', 'Cliente equivocado', 'Lo registré dos veces', 'Otro') then
    raise exception using
      errcode = '22023',
      message = 'Elegí el motivo de la anulación: Monto equivocado, Cliente equivocado, Lo registré dos veces u Otro.';
  end if;

  -- Un cobro que no existe, que está dado de baja o que no es de un colportor de su campaña da el mismo
  -- error: no se averigua qué cobros hay.
  select c.* into v_cobro
    from public.cobranza c
    join public.venta v on v.id = c.venta_id
   where c.id = p_cobranza_id
     and c.deleted_at is null
     and (v_es_admin
          or exists (select 1
                       from public.campania_colportor cc
                       join public.campania ca on ca.id = cc.campania_id
                      where cc.usuario_id = v.colportor_id
                        and cc.deleted_at is null
                        and ca.deleted_at is null
                        and ca.coordinador_id = auth.uid()))
     for update of c;
  if not found then
    raise exception using
      errcode = 'CB004',
      message = 'No encontramos ese cobro entre los de tu equipo.';
  end if;

  if v_cobro.anulado_at is not null then
    return jsonb_build_object(
      'cobranza_id', v_cobro.id, 'anulado_at', v_cobro.anulado_at,
      'motivo', v_cobro.motivo_anulacion, 'ya_estaba', true);
  end if;

  update public.cobranza
     set anulado_at = now(), motivo_anulacion = p_motivo
   where id = v_cobro.id
  returning anulado_at into v_cobro.anulado_at;

  return jsonb_build_object(
    'cobranza_id', v_cobro.id, 'anulado_at', v_cobro.anulado_at, 'motivo', p_motivo, 'ya_estaba', false);
end;
$$;

comment on function public.anular_cobro(uuid, text) is
  'La anulación del coordinador (0072, decisión de Cristian del 23/10, «Anular 72 h»): ADMIN o el coordinador de una '
  'campaña con el colportor de la venta inscripto. Motivo de la lista (22023); dentro de las 72 h desde el cobro '
  '(CB001); CB004 si el cobro no existe, está de baja o no es de su equipo; idempotente (ya_estaba). Devuelve '
  '{cobranza_id, anulado_at, motivo, ya_estaba}.';

revoke all on function public.anular_cobro(uuid, text) from public, anon, authenticated, service_role;
grant execute on function public.anular_cobro(uuid, text) to authenticated;

-- ----------------------------------------------------------------------------
-- 4. El saldo de la cuota no cuenta los cobros anulados
-- ----------------------------------------------------------------------------

-- Igual que en 0068 (la misma función, el mismo trigger), con una condición más: el saldo de la venta que
-- mide AG002 suma los cobros vivos y NO anulados. Sus privilegios y su trigger siguen (create or replace).
create or replace function public.tg_agenda_origen()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_venta_dueno    uuid;
  v_venta_total    integer;
  v_entrega_venta  uuid;
  v_entrega_dueno  uuid;
  v_cobrado        bigint;
  v_saldo          bigint;
  v_cuotas         integer;
  v_cambia         boolean;
begin
  -- Reenvío de un alta que ya está: el push la resuelve como `duplicate` (contrato §7, «replay
  -- idempotente»: nunca INVALID). Los BEFORE triggers corren antes del `on conflict do nothing`, así que
  -- si el saldo bajó desde que se creó, medirla de nuevo la volvería invalid y el colportor la vería en
  -- la cola de error. Sale antes de medir nada: no se inserta.
  if tg_op = 'INSERT' and exists (select 1 from public.agenda a where a.id = new.id) then
    return new;
  end if;

  -- La venta y la entrega son de quien agenda. La clave foránea no mira la RLS: sin esto alcanzaría
  -- con saber el id de una venta ajena para colgarle una cita (y probar su saldo con los topes).
  if new.venta_id is not null then
    select v.colportor_id, v.monto_total into v_venta_dueno, v_venta_total
      from public.venta v
     where v.id = new.venta_id;
    if found and v_venta_dueno is distinct from new.colportor_id then
      raise exception using
        errcode = '42501',
        message = 'Esa venta es de otra persona: no se puede agendar sobre ella.';
    end if;
  end if;

  if new.entrega_id is not null then
    select e.venta_id, v.colportor_id into v_entrega_venta, v_entrega_dueno
      from public.entrega e
      join public.venta v on v.id = e.venta_id
     where e.id = new.entrega_id;
    if found then
      if v_entrega_dueno is distinct from new.colportor_id then
        raise exception using
          errcode = '42501',
          message = 'Esa entrega es de otra persona: no se puede agendar sobre ella.';
      end if;
      if new.venta_id is not null and new.venta_id <> v_entrega_venta then
        raise exception using
          errcode = '23514',
          constraint = 'agenda_entrega_de_la_venta',
          message = 'La entrega es de otra venta: la cita nombra una venta y una entrega que no van juntas.';
      end if;
    end if;
  end if;

  -- El teléfono sube la FILA ENTERA en cada update y el push arma el SET con todas las claves del
  -- payload: la lista del `UPDATE OF` del trigger se cumple siempre. Por eso se compara old con new: mover
  -- la fecha de una cuota que ya estaba no la vuelve a medir (su monto pudo quedar por encima del saldo
  -- porque entró un cobro después, y moverla no lo agrava). Solo cuenta lo que cambia lo que se mide.
  v_cambia := true;
  if tg_op = 'UPDATE' then
    -- (`old` no existe en un INSERT: va en su propio `if`, no en un OR.)
    v_cambia := (old.tipo, old.venta_id, old.monto_previsto, old.estado, old.deleted_at)
                is distinct from (new.tipo, new.venta_id, new.monto_previsto, new.estado, new.deleted_at);
  end if;

  -- Una cuota: cita de cobranza, con venta y con monto, viva.
  if v_cambia
     and new.monto_previsto is not null
     and new.tipo = 'COBRANZA'
     and new.venta_id is not null
     and v_venta_total is not null
     and new.deleted_at is null then
    -- Dos cuotas de la misma venta no se cuentan a la vez (los cobros entran con FOR KEY SHARE: no
    -- esperan).
    perform 1 from public.venta v where v.id = new.venta_id for no key update;

    if new.estado in ('PROGRAMADA', 'CUMPLIDA') then
      select count(*) into v_cuotas
        from public.agenda a
       where a.venta_id = new.venta_id
         and a.tipo = 'COBRANZA'
         and a.monto_previsto is not null
         and a.deleted_at is null
         and a.estado in ('PROGRAMADA', 'CUMPLIDA')
         and a.id <> new.id;
      if v_cuotas >= 12 then
        raise exception using
          errcode = 'AG001',
          message = 'Una venta admite hasta 12 cuotas y esta ya las tiene. Cancelá alguna cuota o usá una de las que ya hay.';
      end if;
    end if;

    if new.estado = 'PROGRAMADA' then
      select coalesce(sum(c.monto), 0) into v_cobrado
        from public.cobranza c
       where c.venta_id = new.venta_id
         and c.deleted_at is null
         and c.anulado_at is null;
      v_saldo := v_venta_total - v_cobrado;
      if new.monto_previsto > v_saldo then
        raise exception using
          errcode = 'AG002',
          message = format(
            'La cuota de %s supera lo que falta cobrar de la venta (%s). Bajá el monto de la cuota.',
            trim(to_char(new.monto_previsto / 100.0, 'FM9999999990.00')),
            trim(to_char(greatest(v_saldo, 0) / 100.0, 'FM9999999990.00')));
      end if;

      if tg_op = 'INSERT'
         and public.hoy_montevideo(new.fecha_programada)
             < public.hoy_montevideo(coalesce(new.created_at, now())) then
        raise exception using
          errcode = 'AG003',
          message = 'La cuota tiene una fecha que ya pasó. Elegí hoy o un día más adelante.';
      end if;
    end if;
  end if;

  return new;
end;
$$;

comment on function public.tg_agenda_origen() is
  'BEFORE INSERT / UPDATE OF tipo, venta_id, entrega_id, monto_previsto, estado, deleted_at de agenda: '
  'la venta y la entrega son de quien agenda (42501), la entrega es de la venta (23514) y los topes del '
  'reparto de cuotas: hasta 12 por venta (AG001), ninguna supera el saldo (AG002; el saldo no cuenta los '
  'cobros anulados, 0072), no se crea una con el día ya pasado (AG003). Los topes solo se miden si cambia '
  'tipo, venta, monto, estado o baja (old vs new) y no en el reenvío de un alta que ya existe (0068).';

-- ----------------------------------------------------------------------------
-- 5. El push: CB001, CB002 y CB003 vuelven invalid, sin tumbar el lote
-- ----------------------------------------------------------------------------

-- Igual que en 0068, más CB001 a CB003. Sus privilegios siguen (create or replace los conserva).
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
  -- CB003, 0072): códigos propios, que la app traduce a un aviso. INVALID como el resto, sin tumbar el lote.
  when sqlstate 'UB001' or sqlstate 'UB002' or sqlstate 'CG001' or sqlstate 'UB005'
    or sqlstate 'AG001' or sqlstate 'AG002' or sqlstate 'AG003'
    or sqlstate 'CB001' or sqlstate 'CB002' or sqlstate 'CB003' then
    return jsonb_build_object(
      'client_op_id', v_id,
      'outcome', 'invalid',
      'code', sqlstate,
      'message', sqlerrm
    );
end;
$$;
