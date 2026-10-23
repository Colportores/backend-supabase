-- ============================================================================
-- 0068 · Agenda única: un tipo con lo que la origina, los estados de la HU, la cita sin persona, el monto
--        previsto de una cuota y la fecha prevista de una entrega (backend-supabase#131)
--
-- Decisiones de Cristian del 23/10 (front-colportores-mobile#151, #166 y #160): «No cumplida» (los
-- cuatro estados de la HU), «Sin persona» (de la casa o el depto), «Plan cuotas» (cada cuota es una cita
-- de cobranza de la agenda), «Reparto» (los topes) y «Entrega día» (fecha prevista y cita de entrega:
-- «la agenda es variable: puede ser para entregas, cobros, presentaciones; ahí debería estar la
-- abstracción»). La agenda es UNA sola tabla con un tipo y con lo que la origina; no hay tablas de plan
-- ni de cuotas. La deuda sigue saliendo de la venta menos sus cobros (HU-COB-005), así que mover una cita
-- no pierde nada.
--
-- ## Qué cambia en `agenda`
--
--   · `estado`: PROGRAMADA / CUMPLIDA / NO_CUMPLIDA / CANCELADA (R-VS02 de la HU), los mismos nombres en
--     el teléfono, el servidor y el panel. Los actuales se renombran: PENDIENTE → PROGRAMADA,
--     COMPLETADA → CUMPLIDA (CANCELADA queda). Default PROGRAMADA. Una cita vencida sin resultado sigue
--     PROGRAMADA (la app la muestra en «Pendientes» hasta que se registre algo): NO_CUMPLIDA es un
--     resultado, no un vencimiento, y no lo pone nadie solo.
--   · `tipo`: ENTREVISTA / COBRANZA / ENTREGA. Para sumar otro tipo (una presentación, una visita de
--     seguimiento…) alcanza con ampliar este CHECK y, si pide origen, con una rama más en la regla de
--     abajo: la tabla, sus índices y el push no se tocan. Se probó la alternativa de un catálogo con
--     clave foránea y se descartó: sumaría una tabla más al pull sin ganar nada (un tipo nuevo igual
--     necesita código en la app).
--   · Lo que la origina, opcional: `venta_id` (la venta de la que sale la cuota) y `entrega_id` (la
--     entrega que se agenda). `entrega_id` solo en una cita ENTREGA; si vienen las dos, la entrega es de
--     esa venta; y una y otra tienen que ser de quien agenda (42501): la clave foránea no mira la RLS y
--     sin esto una cita podría nombrar la venta de otra persona.
--   · `monto_previsto` (centavos): lo que se espera cobrar en esa cita. Solo en una cita COBRANZA con
--     venta, y mayor que cero (CHECK).
--   · `espacio_id` (NOT NULL): la cita cuelga del espacio (la casa o el depto) y `espacio_persona_id`
--     pasa a ser opcional («Sin persona»). Con persona, el espacio es el de su vínculo (el trigger lo
--     completa si falta y lo corrige si no coincide; un teléfono que todavía no manda `espacio_id`
--     sigue funcionando). Sin persona no sube nada de ninguna persona: solo el espacio, que ya sube.
--     Las filas que ya tienen persona toman el espacio de su vínculo.
--
-- ## Los topes del «Reparto» (los aplica el servidor al recibir cada cuota)
--
-- Una cuota es una cita COBRANZA con `venta_id` y `monto_previsto`. Al recibir una (o cambiar su monto,
-- su venta, su estado o volver a programarla), con la venta bloqueada para que dos no se pisen:
--   · AG001: una venta admite hasta 12 cuotas (las citas PROGRAMADA o CUMPLIDA con monto; las
--     canceladas, las no cumplidas y las dadas de baja no cuentan).
--   · AG002: una cuota PROGRAMADA no supera el saldo de la venta (`monto_total` menos sus cobros vivos).
--     Una cuota que llega ya CUMPLIDA no se mira: su cobro puede haber llegado antes y dejado el saldo
--     en cero.
--   · AG003: al crear una cuota PROGRAMADA, su día (en Montevideo) no es anterior al día en que se
--     creó (`created_at` que manda el teléfono): «la primera es hoy o más adelante». No se compara con
--     el reloj del servidor: un teléfono sin conexión sube la cuota días después y se perdería.
-- Los tres vuelven como `invalid` con su código (sin tumbar el lote); las cuentas no se hacen de nuevo.
--
-- Lo que NO verifica el servidor, porque no puede o ya lo hace la app (no hay tabla de plan): el mínimo
-- de 2 cuotas (llegan de a una), la frecuencia semanal o mensual, el reparto en partes iguales con el
-- redondeo en la última y que, si cambia una cuota, las siguientes se repartan lo que queda. Ver el
-- archivo de pendientes de esta entrega.
--
-- ## Cuando dos casas se unen (HU-UBI-006)
--
-- El trigger de unión de agenda (0035) también redirige `espacio_id` (un espacio fundido en el único de
-- A va al de A), y un espacio que se funde (fila nueva de `espacio_union`) lleva con él las citas que
-- colgaban de él, con o sin persona. Nada se pierde ni se rechaza.
--
-- ## `entrega`
--
--   · `fecha_prevista` (opcional): la fecha en que se acordó entregar. `fecha_entrega` queda como la
--     fecha REAL (se guarda al entregar). La cita de la entrega es una fila de `agenda` tipo ENTREGA con
--     `entrega_id`.
--
-- ## Los datos
--
-- Solo se suma o se renombra; no se borra nada. El renombre de los estados y el espacio de cada cita
-- se escriben con un solo UPDATE, así que esas filas suben su `sync_version` una vez (un teléfono con
-- una edición vieja de la cita recibe `conflict` y adopta la del servidor). Lo prueba el caso
-- `tests_migracion/0068_ok`. Las entregas no se tocan.
--
-- ## Para otros repos
--
--   · front-colportores-mobile: la tabla local de `agenda` pasa a los cuatro estados (también su CHECK),
--     suma `espacio_id`, `venta_id`, `entrega_id` y `monto_previsto` y deja `espacio_persona_id` en
--     null; `entrega` suma `fecha_prevista`. Códigos nuevos del push (`invalid`): AG001, AG002, AG003.
--   · docs-organizacion: `esquema-datos.md` (agenda, entrega, estados), `contrato-sync-engine.md`
--     (códigos de `invalid`), HU-VIS-005, HU-COB-004 y HU-VEN-003.
--
-- Forward-only: esta migración no se edita una vez aplicada.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. entrega: la fecha prevista
-- ----------------------------------------------------------------------------

alter table public.entrega add column fecha_prevista timestamptz;

comment on column public.entrega.fecha_prevista is
  'Cuándo se acordó entregar (0068, HU-VEN-003). Opcional: una entrega inmediata no la tiene. La cita de '
  'esa entrega es una fila de agenda tipo ENTREGA con entrega_id.';
comment on column public.entrega.fecha_entrega is
  'La fecha REAL en que se entregó (null mientras está pendiente). La acordada es fecha_prevista (0068).';

-- ----------------------------------------------------------------------------
-- 2. agenda: columnas, estados, tipos y reglas de forma
-- ----------------------------------------------------------------------------

alter table public.agenda drop constraint agenda_estado_check;
alter table public.agenda drop constraint agenda_tipo_check;

alter table public.agenda
  add column espacio_id      uuid references public.espacio(id),
  add column venta_id        uuid references public.venta(id),
  add column entrega_id      uuid references public.entrega(id),
  add column monto_previsto  integer;

-- Un solo UPDATE (una sola subida de sync_version): los estados nuevos y el espacio de cada cita.
update public.agenda a
   set estado = case a.estado
                  when 'PENDIENTE'  then 'PROGRAMADA'
                  when 'COMPLETADA' then 'CUMPLIDA'
                  else a.estado
                end,
       espacio_id = ep.espacio_id
  from public.espacio_persona ep
 where ep.id = a.espacio_persona_id;

alter table public.agenda
  alter column espacio_id set not null,
  alter column espacio_persona_id drop not null,
  alter column estado set default 'PROGRAMADA';

alter table public.agenda
  add constraint agenda_estado_check
    check (estado in ('PROGRAMADA','CUMPLIDA','NO_CUMPLIDA','CANCELADA')),
  add constraint agenda_tipo_check
    check (tipo in ('ENTREVISTA','COBRANZA','ENTREGA')),
  add constraint agenda_monto_previsto_check
    check (monto_previsto is null
           or (monto_previsto > 0 and tipo = 'COBRANZA' and venta_id is not null)),
  add constraint agenda_entrega_solo_en_entregas
    check (entrega_id is null or tipo = 'ENTREGA');

create index agenda_espacio_idx         on public.agenda (espacio_id);
create index agenda_espacio_persona_idx on public.agenda (espacio_persona_id) where espacio_persona_id is not null;
create index agenda_venta_idx           on public.agenda (venta_id)   where venta_id is not null;
create index agenda_entrega_idx         on public.agenda (entrega_id) where entrega_id is not null;

comment on table public.agenda is
  'La agenda del colportor: una sola abstracción con un tipo (ENTREVISTA, COBRANZA, ENTREGA y los que '
  'vengan) y lo que la origina (venta_id, entrega_id). Cuelga del espacio; la persona es opcional (0068).';
comment on column public.agenda.estado is
  'PROGRAMADA, CUMPLIDA, NO_CUMPLIDA o CANCELADA (R-VS02). Una cita vencida sin resultado sigue '
  'PROGRAMADA hasta que se registre algo (0068).';
comment on column public.agenda.tipo is
  'ENTREVISTA, COBRANZA o ENTREGA. Un tipo nuevo se suma ampliando este CHECK (0068).';
comment on column public.agenda.espacio_id is
  'La casa o el depto de la cita (obligatorio). Con persona es el espacio de su vínculo: lo completa el '
  'trigger agenda_0_union_redirige (0068).';
comment on column public.agenda.espacio_persona_id is
  'El vínculo con la persona; opcional: una cita puede colgar solo del espacio (0068). La persona no sube.';
comment on column public.agenda.venta_id is
  'La venta de la que sale la cita (la cuota de un plan es una cita COBRANZA atada a su venta). Opcional.';
comment on column public.agenda.entrega_id is
  'La entrega que se agenda (solo una cita ENTREGA). Opcional.';
comment on column public.agenda.monto_previsto is
  'Lo que se espera cobrar en esta cita, en centavos (solo una cita COBRANZA con venta). La deuda no sale '
  'de acá: sigue siendo la venta menos sus cobros.';

-- ----------------------------------------------------------------------------
-- 3. El espacio de la cita: con persona, el de su vínculo; si se funde, el de A
-- ----------------------------------------------------------------------------

-- Igual que en 0035, más el espacio. Corre antes que los otros BEFORE (por el nombre).
create or replace function public.tg_agenda_union_redirige()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_espacio uuid;
begin
  new.espacio_persona_id := public.redirigir_vinculo(new.espacio_persona_id);
  if new.ubicacion_alt_id is not null then
    new.ubicacion_alt_id := public.redirigir_ubicacion(new.ubicacion_alt_id);
  end if;

  -- Con persona, la cita cuelga del espacio de su vínculo (el que mande el teléfono, o ninguno, da
  -- igual). Si el vínculo no existe, lo dice la clave foránea.
  if new.espacio_persona_id is not null then
    select ep.espacio_id into v_espacio
      from public.espacio_persona ep
     where ep.id = new.espacio_persona_id;
    if found then
      new.espacio_id := v_espacio;
    end if;
  end if;

  -- Un espacio fundido en el único de A va al de A (null se queda null: lo dice el NOT NULL).
  new.espacio_id := public.redirigir_espacio(new.espacio_id);
  return new;
end;
$$;

comment on function public.tg_agenda_union_redirige() is
  'BEFORE INSERT / UPDATE OF espacio_persona_id, espacio_id, ubicacion_alt_id de agenda: el vínculo '
  'fundido y la casa alternativa que nombran a B pasan a A (0035); el espacio sale del vínculo si hay '
  'persona y el espacio fundido pasa al de A (0068).';

drop trigger agenda_0_union_redirige on public.agenda;
create trigger agenda_0_union_redirige
  before insert or update of espacio_persona_id, espacio_id, ubicacion_alt_id on public.agenda
  for each row execute function public.tg_agenda_union_redirige();

-- Un espacio que se funde en el de A lleva con él sus citas (con o sin persona). Las que tienen persona
-- también se reapuntan al vínculo de A por marcar_como_duplicado(); acá se cubre la que no la tiene.
create function public.tg_espacio_union_mueve_agendas()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  update public.agenda
     set espacio_id = new.destino_id
   where espacio_id = new.espacio_id;
  return null;
end;
$$;

comment on function public.tg_espacio_union_mueve_agendas() is
  'AFTER INSERT de espacio_union: las citas que colgaban del espacio fundido pasan al de A (0068).';

create trigger espacio_union_mueve_agendas
  after insert on public.espacio_union
  for each row execute function public.tg_espacio_union_mueve_agendas();

-- ----------------------------------------------------------------------------
-- 4. Lo que origina la cita y los topes del reparto de cuotas
-- ----------------------------------------------------------------------------

create function public.tg_agenda_origen()
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
begin
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

  -- Una cuota: cita de cobranza, con venta y con monto, viva.
  if new.monto_previsto is not null
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
         and c.deleted_at is null;
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
  'reparto de cuotas: hasta 12 por venta (AG001), ninguna supera el saldo (AG002), no se crea una con '
  'el día ya pasado (AG003) (0068).';

-- Después de agenda_0_union_redirige y antes de la auditoría (orden alfabético).
create trigger agenda_1_origen
  before insert or update of tipo, venta_id, entrega_id, monto_previsto, estado, deleted_at on public.agenda
  for each row execute function public.tg_agenda_origen();

-- Los triggers corren sin EXECUTE para nadie (0035): las funciones son internas.
revoke all on function public.tg_agenda_union_redirige() from public, anon, authenticated;
revoke all on function public.tg_espacio_union_mueve_agendas() from public, anon, authenticated;
revoke all on function public.tg_agenda_origen() from public, anon, authenticated;

-- ----------------------------------------------------------------------------
-- 5. El push: AG001, AG002 y AG003 vuelven invalid, sin tumbar el lote
-- ----------------------------------------------------------------------------

-- Igual que en 0051, más AG001 a AG003. Sus privilegios siguen (create or replace los conserva).
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
  -- (AG001 a AG003, 0068): códigos propios, que la app traduce a un aviso. INVALID como el resto, sin
  -- tumbar el lote.
  when sqlstate 'UB001' or sqlstate 'UB002' or sqlstate 'CG001' or sqlstate 'UB005'
    or sqlstate 'AG001' or sqlstate 'AG002' or sqlstate 'AG003' then
    return jsonb_build_object(
      'client_op_id', v_id,
      'outcome', 'invalid',
      'code', sqlstate,
      'message', sqlerrm
    );
end;
$$;
