-- ============================================================================
-- 0146 · El ticket que baja al teléfono dice quién lo valida (backend-supabase#209, seguimiento de #200 y
--        «Ticket libre», decisión de Cristian del 27/10; decisión del agente de decisiones del 28/10, regla R1)
--
-- El caso: Ana sube el ticket de una cuota cobrada con tarjeta y la venta no cae en ninguna campaña, así que lo
-- valida Administración. El teléfono tiene que decirle «lo revisa Administración» (front-colportores-mobile#427),
-- pero no lo puede saber: las inscripciones y sus huecos viven en el servidor y la app no adivina estados.
--
-- ## Qué hace
--
--   1. `ticket.campania_validadora_id` (uuid, FK a `campania`, nulo por defecto): la campaña cuya coordinadora
--      valida el ticket. **Nulo = lo valida Administración** (la venta del cobro, o la fecha del ticket si no hay
--      cobro, no cae en ninguna inscripción). Lo calcula el servidor con `campania_que_valida_el_ticket()` (0131) y
--      baja al teléfono con el resto de la fila del ticket, en el pull y en el `server_row` de un conflicto: es un
--      id, sin texto libre, sin datos de clientes, y no cambia quién ve qué (el ticket sigue siendo de su dueña, del
--      ADMIN y de la coordinadora de esa campaña; la columna es un dato más de la fila que ya ven).
--   2. Es una columna de verdad (no un cálculo al leer) para que se mantenga cierta: cuando algo la cambia, sube la
--      versión de sync del ticket y el teléfono la baja por delta; si el cálculo da lo mismo, la fila ni se toca
--      (no sube `sync_version`, para no darle un `conflict` de balde al teléfono que está completando la foto).
--      Se recalcula, solo para los tickets POR VALIDAR y vivos, cuando cambia:
--        · el ticket nace (por la fecha del ticket; si el cobro llega después, lo recalcula el punto siguiente);
--        · un cobro lo apunta, deja de apuntarlo, se da de baja o se reactiva, o cambia de venta;
--        · la venta de un cobro que lo apunta cambia de fecha o de colportora;
--        · una inscripción de la colportora: alta, baja, reactivación, un tramo afuera, o el cambio de su campaña;
--        · el fin o la baja de una campaña donde está inscripta la colportora (la gracia de 15 días).
--      Un ticket VALIDADO o RECHAZADO ya no se recalcula: conserva la campaña que lo resolvió (y TK001 no se
--      tropieza). Un ticket de antes de esta migración se calcula una vez acá.
--   3. El teléfono no la escribe: se suma a `sync.entidad.columnas_servidor` (el push la descarta) y, por la API
--      directa, un valor distinto del que tiene la fila es 42501 (`tg_ticket_del_cliente`, que ya compara el resto
--      de las columnas). Un ticket nuevo siempre la recibe del servidor, venga lo que venga en el payload.
--
-- ## Permisos
--
--   · Todas las funciones nuevas son internas: sin EXECUTE para nadie (los triggers corren igual). Es lo que evita
--     abrir `campania_que_valida_el_ticket()` como una RPC que averigua la campaña de un ticket ajeno.
--   · Los triggers son SECURITY DEFINER (leen cobros, ventas e inscripciones que la dueña no ve por RLS) y
--     actualizan el ticket con la auditoría de siempre (`sync_version`, `updated_at`, `xmin_w`).
--
-- ## Los datos
--
-- Los tickets que ya había se calculan una vez: sube su versión de sync y los teléfonos los bajan de nuevo con la
-- columna. Nada se borra ni cambia de otra forma. Datos simulados hasta diciembre: sin migración de limpieza.
--
-- ## Para otros repos
--
--   · front-colportores-mobile#427: la fila `ticket` del pull trae `campania_validadora_id` (uuid o null). Nulo =
--     «lo revisa Administración»; con un id, lo revisa la coordinadora de esa campaña. Puede cambiar con el tiempo
--     (se baja por delta como cualquier otra columna) mientras el ticket esté por validar.
--   · docs-organizacion: contrato del sync (la fila `ticket`) y esquema de datos (docs-organizacion#113, «Ticket
--     libre»).
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. La columna
-- ----------------------------------------------------------------------------

alter table public.ticket
  add column campania_validadora_id uuid references public.campania (id) on delete set null;

comment on column public.ticket.campania_validadora_id is
  'La campaña cuya coordinadora valida el ticket (campania_que_valida_el_ticket, 0131); nulo = lo valida '
  'Administración. La calcula el servidor y baja al teléfono para que diga «lo revisa Administración» (0146, '
  'backend-supabase#209). Se mantiene sola mientras el ticket está por validar; resuelto, queda como estaba.';

-- Para que dar de baja una campaña (ON DELETE SET NULL) no recorra la tabla entera.
create index ticket_campania_validadora_idx
  on public.ticket (campania_validadora_id)
  where campania_validadora_id is not null;

-- ----------------------------------------------------------------------------
-- 2. Recalcular los tickets por validar
-- ----------------------------------------------------------------------------

-- Recalcula la columna de los tickets por validar y vivos que nombra la lista de tickets o la de colportoras. Solo
-- toca el que cambia de verdad: `is distinct from` evita subir `sync_version` por nada. Interna.
create function public.recalcular_quien_valida_tickets(p_tickets uuid[], p_colportoras uuid[])
returns void
language sql
security definer
set search_path = ''
as $$
  with calculo as (
    select t.id,
           public.campania_que_valida_el_ticket(t.id, t.usuario_id, coalesce(t.fecha, t.subido_en)) as campania_id
      from public.ticket t
     where t.estado = 'PENDIENTE'
       and t.deleted_at is null
       and (t.id = any (p_tickets) or t.usuario_id = any (p_colportoras))
  )
  update public.ticket t
     set campania_validadora_id = c.campania_id
    from calculo c
   where t.id = c.id
     and t.campania_validadora_id is distinct from c.campania_id;
$$;

comment on function public.recalcular_quien_valida_tickets(uuid[], uuid[]) is
  'Recalcula ticket.campania_validadora_id (campania_que_valida_el_ticket, 0131) de los tickets por validar y vivos '
  'nombrados por id o por colportora; solo toca los que cambian (0146). Interna: la llaman los triggers.';

revoke all on function public.recalcular_quien_valida_tickets(uuid[], uuid[])
  from public, anon, authenticated, service_role;

-- ----------------------------------------------------------------------------
-- 3. Un ticket nuevo nace con su campaña
-- ----------------------------------------------------------------------------

-- Por la fecha del ticket (todavía no hay un cobro que lo apunte). Pase lo que pase con el payload, el valor es el del
-- servidor. El nombre va DESPUÉS de `ticket_del_cliente` (0113), que fija `subido_en` del teléfono.
create function public.tg_ticket_quien_lo_valida()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  new.campania_validadora_id :=
    public.campania_que_valida_el_ticket(new.id, new.usuario_id, coalesce(new.fecha, new.subido_en));
  return new;
end;
$$;

comment on function public.tg_ticket_quien_lo_valida() is
  'BEFORE INSERT de ticket: fija campania_validadora_id con el cálculo del servidor, ignorando lo que traiga la fila (0146).';

revoke all on function public.tg_ticket_quien_lo_valida() from public, anon, authenticated, service_role;

create trigger ticket_quien_lo_valida
  before insert on public.ticket
  for each row execute function public.tg_ticket_quien_lo_valida();

-- ----------------------------------------------------------------------------
-- 4. El teléfono no la escribe
-- ----------------------------------------------------------------------------

-- Igual que en 0113, más `campania_validadora_id` en lo que el teléfono no puede cambiar de un ticket ya subido. El
-- push ya la descarta (columnas_servidor, más abajo); esto cierra la API directa. Sus privilegios siguen.
create or replace function public.tg_ticket_del_cliente()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_base text;
begin
  -- El servidor (service_role, el editor SQL, una función DEFINER) no pasa por acá. El push corre INVOKER
  -- como `authenticated`; una RPC DEFINER corre como su dueño (patrón de 0053 y 0100).
  if current_user not in ('authenticated', 'anon') then
    return new;
  end if;

  -- La única ruta de foto válida: la carpeta de la dueña y el id del ticket, con o sin extensión de imagen.
  v_base := new.usuario_id::text || '/' || new.id::text;

  if tg_op = 'INSERT' then
    if new.estado is distinct from 'PENDIENTE'
       or new.revisado_por is not null or new.revisado_en is not null or new.motivo_rechazo is not null then
      raise exception 'Un ticket nuevo entra siempre por validar: lo valida o lo rechaza tu coordinador.'
        using errcode = '42501';
    end if;
    -- Cuándo llegó lo cuenta el servidor, no el teléfono.
    new.subido_en := now();

    if new.monto is null then
      raise exception 'Ingresá el monto del ticket.'
        using errcode = '23514', constraint = 'ticket_monto_obligatorio';
    end if;
    if new.fecha is null then
      raise exception 'Ingresá la fecha del ticket.'
        using errcode = '23514', constraint = 'ticket_fecha_obligatoria';
    end if;
    if public.hoy_montevideo(new.fecha) > public.hoy_montevideo() then
      raise exception 'La fecha del ticket no puede ser futura. Revisá el día.'
        using errcode = '23514', constraint = 'ticket_fecha_no_futura';
    end if;
    if new.tipo = 'COBRO_TARJETA' then
      if new.numero_autorizacion is null then
        raise exception 'Ingresá el número de autorización del ticket.'
          using errcode = '23514', constraint = 'ticket_autorizacion_obligatoria';
      end if;
      if new.tarjeta_tipo is null then
        raise exception 'Elegí si la tarjeta es de crédito o de débito.'
          using errcode = '23514', constraint = 'ticket_tarjeta_obligatoria';
      end if;
    end if;
    if new.url_cloud is not null
       and new.url_cloud not in (v_base, v_base || '.jpg', v_base || '.jpeg', v_base || '.png', v_base || '.webp') then
      raise exception 'La foto del ticket tiene que estar en tu carpeta, con el id del ticket.'
        using errcode = '23514', constraint = 'ticket_foto_en_tu_carpeta';
    end if;
    return new;
  end if;

  -- UPDATE: de un ticket ya subido el teléfono solo completa la foto.
  if (new.usuario_id, new.tipo, new.subido_en, new.revisado_por, new.revisado_en, new.monto, new.fecha,
      new.numero_autorizacion, new.tarjeta_tipo, new.tarjeta_marca, new.estado, new.motivo_rechazo,
      new.deleted_at, new.campania_validadora_id)
     is distinct from
     (old.usuario_id, old.tipo, old.subido_en, old.revisado_por, old.revisado_en, old.monto, old.fecha,
      old.numero_autorizacion, old.tarjeta_tipo, old.tarjeta_marca, old.estado, old.motivo_rechazo,
      old.deleted_at, old.campania_validadora_id) then
    raise exception 'Un ticket que ya subiste no se puede cambiar ni dar de baja. Si tiene un error, pedile a tu coordinador que lo rechace y cargalo de nuevo.'
      using errcode = '42501';
  end if;
  if new.url_cloud is distinct from old.url_cloud then
    if old.url_cloud is not null then
      raise exception 'La foto de un ticket ya subido no se cambia ni se quita.'
        using errcode = '42501';
    end if;
    if new.url_cloud is not null
       and new.url_cloud not in (v_base, v_base || '.jpg', v_base || '.jpeg', v_base || '.png', v_base || '.webp') then
      raise exception 'La foto del ticket tiene que estar en tu carpeta, con el id del ticket.'
        using errcode = '23514', constraint = 'ticket_foto_en_tu_carpeta';
    end if;
  end if;
  return new;
end;
$$;

update sync.entidad
   set columnas_servidor = columnas_servidor || array['campania_validadora_id']
 where nombre = 'ticket';

-- ----------------------------------------------------------------------------
-- 5. Los tickets de antes, una vez
-- ----------------------------------------------------------------------------

-- Todos los vivos (también los ya resueltos: la columna no entra en el congelado de TK001). Sube su versión de sync:
-- los teléfonos los bajan de nuevo con la columna.
with calculo as (
  select t.id,
         public.campania_que_valida_el_ticket(t.id, t.usuario_id, coalesce(t.fecha, t.subido_en)) as campania_id
    from public.ticket t
   where t.deleted_at is null
)
update public.ticket t
   set campania_validadora_id = c.campania_id
  from calculo c
 where t.id = c.id
   and t.campania_validadora_id is distinct from c.campania_id;

-- ----------------------------------------------------------------------------
-- 6. Mantenerla cierta
-- ----------------------------------------------------------------------------

-- Un cobro apunta a un ticket, lo suelta, se da de baja, se reactiva o cambia de venta.
create function public.tg_cobranza_avisa_al_ticket()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if tg_op = 'INSERT' then
    perform public.recalcular_quien_valida_tickets(array[new.ticket_id], null);
  elsif tg_op = 'DELETE' then
    perform public.recalcular_quien_valida_tickets(array[old.ticket_id], null);
  elsif (new.ticket_id, new.venta_id, new.deleted_at) is distinct from (old.ticket_id, old.venta_id, old.deleted_at) then
    perform public.recalcular_quien_valida_tickets(array[old.ticket_id, new.ticket_id], null);
  end if;
  return null;
end;
$$;

comment on function public.tg_cobranza_avisa_al_ticket() is
  'AFTER INSERT / UPDATE OF ticket_id, venta_id, deleted_at / DELETE de cobranza: recalcula quién valida el ticket al '
  'que apuntaba y al que apunta (0146).';

create trigger cobranza_avisa_al_ticket
  after insert or update of ticket_id, venta_id, deleted_at or delete on public.cobranza
  for each row execute function public.tg_cobranza_avisa_al_ticket();

-- La venta de un cobro que apunta a un ticket cambia de fecha o de colportora.
create function public.tg_venta_avisa_al_ticket()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform public.recalcular_quien_valida_tickets(
    array(select c.ticket_id from public.cobranza c
           where c.venta_id = new.id and c.ticket_id is not null and c.deleted_at is null),
    null);
  return null;
end;
$$;

comment on function public.tg_venta_avisa_al_ticket() is
  'AFTER UPDATE OF fecha, colportor_id de venta (cuando cambia): recalcula quién valida los tickets de sus cobros (0146).';

create trigger venta_avisa_al_ticket
  after update of fecha, colportor_id on public.venta
  for each row
  when ((old.fecha, old.colportor_id) is distinct from (new.fecha, new.colportor_id))
  execute function public.tg_venta_avisa_al_ticket();

-- La inscripción de una colportora cambia (alta, baja, reactivación, tramo afuera, campaña).
create function public.tg_inscripcion_avisa_al_ticket()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if tg_op = 'INSERT' then
    perform public.recalcular_quien_valida_tickets(null, array[new.usuario_id]);
  elsif tg_op = 'DELETE' then
    perform public.recalcular_quien_valida_tickets(null, array[old.usuario_id]);
  elsif (new.usuario_id, new.campania_id, new.created_at, new.deleted_at, new.tramos_afuera)
        is distinct from (old.usuario_id, old.campania_id, old.created_at, old.deleted_at, old.tramos_afuera) then
    perform public.recalcular_quien_valida_tickets(null, array[old.usuario_id, new.usuario_id]);
  end if;
  return null;
end;
$$;

comment on function public.tg_inscripcion_avisa_al_ticket() is
  'AFTER INSERT / UPDATE / DELETE de campania_colportor: recalcula quién valida los tickets por validar de la '
  'colportora (0146).';

create trigger campania_colportor_avisa_al_ticket
  after insert or update of usuario_id, campania_id, created_at, deleted_at, tramos_afuera or delete
  on public.campania_colportor
  for each row execute function public.tg_inscripcion_avisa_al_ticket();

-- Una campaña termina más tarde o más temprano, o se da de baja: cambia la gracia de 15 días de sus inscriptas.
create function public.tg_campania_avisa_al_ticket()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform public.recalcular_quien_valida_tickets(
    null,
    array(select cc.usuario_id from public.campania_colportor cc where cc.campania_id = new.id));
  return null;
end;
$$;

comment on function public.tg_campania_avisa_al_ticket() is
  'AFTER UPDATE OF fecha_fin, deleted_at de campania (cuando cambia): recalcula quién valida los tickets por validar de '
  'las inscriptas (0146).';

create trigger campania_avisa_al_ticket
  after update of fecha_fin, deleted_at on public.campania
  for each row
  when ((old.fecha_fin, old.deleted_at) is distinct from (new.fecha_fin, new.deleted_at))
  execute function public.tg_campania_avisa_al_ticket();

-- Un trigger corre igual sin EXECUTE: ni siquiera authenticated.
revoke all on function
  public.tg_cobranza_avisa_al_ticket(),
  public.tg_venta_avisa_al_ticket(),
  public.tg_inscripcion_avisa_al_ticket(),
  public.tg_campania_avisa_al_ticket()
  from public, anon, authenticated, service_role;
