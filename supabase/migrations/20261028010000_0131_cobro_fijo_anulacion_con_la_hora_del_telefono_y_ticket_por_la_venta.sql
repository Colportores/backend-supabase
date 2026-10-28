-- ============================================================================
-- 0131 · Cobros y tickets: la anulación con la hora del teléfono, el cobro fijo pasado el plazo y el ticket de una
--        cuota por la campaña de la venta (backend-supabase#200, BACK-HU-COB-006 y BACK-HU-COB-007; seguimiento de
--        #133 / PR #159 y #108 / PR #181; decisiones de Cristian del 27/10 «Anular offline», «Cobro fijo» y
--        «Ticket libre»)
--
-- ## Qué cambia
--
--   1. «Anular offline» · la ventana de 72 h se mide con la HORA DEL TELÉFONO en que se anuló (`anulado_at`, que el
--      teléfono ya sube en el mismo upsert del cobro), no con la hora en que el servidor recibe la anulación (0072).
--      Una anulación vale si:
--        · su hora no es del futuro ni anterior al cobro (CB008);
--        · cae dentro de las 72 h desde la `fecha` del cobro, inclusive (CB001);
--        · sube dentro de los 15 días de gracia de las ventas: si la campaña de la venta (la que contiene la fecha de
--          la venta, `campania_del_ticket`, 0113) terminó hace más de 15 días, `escritura_dentro_de_plazo` (0020) dice
--          que no (CB009). La venta no lleva campaña: si su fecha no cae en ninguna inscripción, no hay gracia que medir.
--      El caso: Ana cobra el lunes 14:10 y anula sin señal el miércoles 13:00 (71 h); la anulación sube el jueves (80 h
--      del cobro): vale. Siguen igual CB002 (la colportora no anula con el ticket validado), CB003 (un cobro anulado no
--      se reabre), CB005 y CB006. La anulación del coordinador (`anular_cobro`) pone `anulado_at = now()`: el reloj
--      del servidor, como siempre.
--   2. «Cobro fijo» · dentro de las 72 h desde el cobro, y mientras su ticket no esté VALIDADO, la dueña corrige el
--      monto o el medio sin pedir motivo. Pasado el plazo, o con el ticket validado, el cobro queda fijo: no cambian
--      monto, fecha ni medio y no se da de baja ni se reactiva (`deleted_at`); la única corrección es la anulación
--      dentro del plazo. Siguen permitidos el reenvío idéntico (el teléfono sube la fila entera, también cuando falló
--      la señal) y atarle su ticket (`ticket_id`, con la guarda de CB005). El rechazo es CB007, con un texto que guía.
--      Mientras corre el plazo, la `fecha` no cambia (CB006, sin cambios). Como todos los controles de este trigger,
--      vale para quien tiene sesión; el servidor (service_role, migraciones) corrige a mano.
--   3. «Ticket libre» · el ticket de un cobro lo valida la coordinadora de la campaña DONDE SE HIZO LA VENTA, aunque la
--      cuota se cobre cuando la campaña ya terminó (más allá de sus 15 días de gracia). El ticket de un depósito sigue
--      yendo por la fecha del ticket (0113). Si el ticket de un cobro igual no cae en ninguna campaña (la venta no está
--      en ninguna inscripción), lo ven y lo validan su dueña y el ADMIN, nadie más (lo mismo que ya pasaba con un
--      ticket sin campaña por fecha).
--        · `campania_que_valida_el_ticket(ticket, colportor, fecha)` (interna): si algún cobro vivo apunta al ticket
--          (`cobranza.ticket_id`), la campaña de ese cobro es la de su venta (el primero por alta si hubiera varios);
--          si no, la de la fecha del ticket, como hasta ahora.
--        · Pasan a usarla: `ticket_select` (nueva `puede_ver_ticket`, que reemplaza a `puede_ver_ticket_de`), la foto
--          del bucket `tickets` (`puede_ver_foto_de_ticket`), `tickets_de_campania` y `ticket_para_validar`
--          (validar, rechazar y la previa de la vista 29).
--      Un ticket que sube ANTES de que el cobro lo apunte se ubica por su fecha hasta que el cobro llega; después,
--      por la venta.
--   4. El push: CB007, CB008 y CB009 vuelven `invalid` con su código, sin tumbar el lote (`sync.aplicar_job`).
--
-- ## Los datos
--
-- Solo cambian funciones, una política y un trigger (`create or replace`): ningún cobro ni ticket cambia, ningún
-- `sync_version` ni `xmin_w` se mueve. Datos simulados hasta diciembre: sin migración de limpieza.
--
-- ## Códigos nuevos
--
--   CB007  el cobro ya no se puede cambiar (pasó el plazo de 72 h o su ticket está validado).
--   CB008  la hora de la anulación es del futuro o anterior al cobro.
--   CB009  la anulación sube pasados los 15 días de gracia de la campaña de la venta.
--
-- ## Para otros repos
--
--   · front-colportores-mobile#424 / #427: traducir CB007, CB008 y CB009 del `invalid` a un aviso; la hora de anulación
--     que sube es la del teléfono. #427: el texto «lo revisa Administración» de un ticket que no cae en ninguna campaña.
--   · docs-organizacion: HU-COB-006 y HU-COB-007, `contrato-sync-engine.md` (códigos del push de `cobranza`),
--     `esquema-datos.md` (cobranza: fija pasado el plazo; ticket: la campaña de un cobro es la de su venta).
--
-- Forward-only: esta migración no se edita una vez aplicada.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. El trigger de la anulación y del cobro fijo
-- ----------------------------------------------------------------------------

-- Igual que en 0072, con tres cambios: el cobro fijo (CB007, antes de CB006 y CB005, porque un cobro fijo contesta
-- siempre lo mismo), la hora de la anulación es la del teléfono (CB008, CB001) y la gracia de 15 días (CB009). Sus
-- privilegios y su trigger siguen (create or replace).
create or replace function public.tg_cobranza_anulacion()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_dueno          uuid;
  v_fecha_cobro    timestamptz;
  v_ticket_viejo   uuid;
  v_venta_fecha    timestamptz;
  v_campania       uuid;
  v_fin            date;
begin
  if tg_op = 'UPDATE' and auth.uid() is not null then
    -- El cobro fijo (CB007): pasado el plazo de 72 h desde el cobro, o con su ticket validado, no cambian monto,
    -- fecha ni medio, y no se da de baja ni se reactiva. El reenvío idéntico no cambia nada y pasa; atarle el ticket
    -- (ticket_id) y anular tampoco tocan estas cuatro columnas. Dentro del plazo y sin ticket validado, la dueña
    -- corrige monto y medio sin más (la fecha, no: CB006).
    if (new.monto, new.medio, new.fecha, new.deleted_at) is distinct from (old.monto, old.medio, old.fecha, old.deleted_at)
       and (now() > old.fecha + interval '72 hours'
            or exists (select 1 from public.ticket t
                        where t.id = old.ticket_id and t.estado = 'VALIDADO' and t.deleted_at is null)) then
      raise exception using
        errcode = 'CB007',
        message = 'Este cobro ya no se puede cambiar. Si está mal, pedile a tu coordinador que lo revise.';
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

  -- «Anular offline»: la hora que cuenta es la del teléfono en que se anuló. Una hora del futuro, o anterior al
  -- cobro, no es de fiar (reloj mal puesto): se rechaza con un aviso que lo dice.
  if new.anulado_at > now() or new.anulado_at < v_fecha_cobro then
    raise exception using
      errcode = 'CB008',
      message = 'La hora de la anulación no es válida: no puede ser del futuro ni anterior al cobro. Revisá la fecha y la hora de tu teléfono.';
  end if;
  if new.anulado_at > v_fecha_cobro + interval '72 hours' then
    raise exception using
      errcode = 'CB001',
      message = 'Pasaron más de 72 horas desde el cobro: ya no se puede anular.';
  end if;

  select v.colportor_id, v.fecha into v_dueno, v_venta_fecha from public.venta v where v.id = new.venta_id;

  -- Los 15 días de gracia de las ventas: la anulación tiene que subir mientras la campaña de la venta todavía admite
  -- escrituras. Sin campaña para esa fecha de venta, no hay gracia que medir.
  v_campania := public.campania_del_ticket(v_dueno, v_venta_fecha);
  if v_campania is not null then
    select c.fecha_fin into v_fin from public.campania c where c.id = v_campania;
    if not public.escritura_dentro_de_plazo(v_fin) then
      raise exception using
        errcode = 'CB009',
        message = 'La campaña de esta venta terminó hace más de 15 días: el cobro ya no se puede anular. Pedile a tu coordinador que lo revise.';
    end if;
  end if;

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
  'BEFORE INSERT / UPDATE de cobranza (0072, 0131): cobro fijo pasadas 72 h o con el ticket validado: no cambian monto, '
  'fecha ni medio ni se da de baja (CB007); la fecha del cobro y un ticket validado no se mueven (CB006, CB005). Al '
  'anular: la hora de la anulación es la del teléfono, ni futura ni anterior al cobro (CB008), dentro de las 72 h '
  'desde el cobro (CB001) y mientras la campaña de la venta admite escrituras, 15 días de gracia (CB009); la colportora '
  'no anula con el ticket validado (CB002); un cobro anulado no se reabre ni cambia (CB003). Sin sesión (service_role, '
  'migraciones) no controla nada. Un alta que ya existe se deja pasar (replay idempotente).';

-- ----------------------------------------------------------------------------
-- 2. El push: CB007, CB008 y CB009 vuelven invalid, sin tumbar el lote
-- ----------------------------------------------------------------------------

-- Igual que en 0101, más CB007, CB008 y CB009 (0131). Sus privilegios siguen (create or replace los conserva).
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
  -- gracia (CB007 a CB009, 0131) y la unión de duplicados con A de baja o con B = A (UB003 y UB004, 0101): códigos propios, que la
  -- app traduce a un aviso. INVALID como el resto, sin tumbar el lote.
  when sqlstate 'UB001' or sqlstate 'UB002' or sqlstate 'UB003' or sqlstate 'UB004' or sqlstate 'CG001' or sqlstate 'UB005'
    or sqlstate 'AG001' or sqlstate 'AG002' or sqlstate 'AG003'
    or sqlstate 'CB001' or sqlstate 'CB002' or sqlstate 'CB003' or sqlstate 'CB005' or sqlstate 'CB006'
    or sqlstate 'CB007' or sqlstate 'CB008' or sqlstate 'CB009' then
    return jsonb_build_object(
      'client_op_id', v_id,
      'outcome', 'invalid',
      'code', sqlstate,
      'message', sqlerrm
    );
end;
$$;

-- ----------------------------------------------------------------------------
-- 3. «Ticket libre»: la campaña que valida el ticket de un cobro es la de su venta
-- ----------------------------------------------------------------------------

-- La campaña a la que pertenece un ticket: si algún cobro vivo lo apunta (`cobranza.ticket_id`), la de la VENTA de
-- ese cobro (campania_del_ticket con el colportor y la fecha de la venta; el cobro más antiguo si hubiera varios,
-- aunque esté anulado: anular no lo cambia de campaña); si no hay cobro, la de la fecha del ticket, como en 0113. Si
-- la venta no cae en ninguna inscripción devuelve null y NO se cae a la fecha del ticket: lo ve la Administración
-- (decisión «Ticket libre» del 27/10). Interna: la llaman funciones DEFINER y la política de lectura.
create function public.campania_que_valida_el_ticket(p_ticket_id uuid, p_usuario_id uuid, p_fecha timestamptz)
returns uuid
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_colportor  uuid;
  v_venta_fecha timestamptz;
begin
  select v.colportor_id, v.fecha into v_colportor, v_venta_fecha
    from public.cobranza c
    join public.venta v on v.id = c.venta_id
   where c.ticket_id = p_ticket_id
     and c.deleted_at is null
   order by c.created_at, c.id
   limit 1;
  if found then
    return public.campania_del_ticket(v_colportor, v_venta_fecha);
  end if;
  return public.campania_del_ticket(p_usuario_id, p_fecha);
end;
$$;

comment on function public.campania_que_valida_el_ticket(uuid, uuid, timestamptz) is
  'La campaña cuya coordinadora ve y valida el ticket (0131, «Ticket libre»): la de la venta del cobro que lo apunta '
  '(campania_del_ticket con el colportor y la fecha de la venta; null, sin caer a la fecha del ticket, si no cae en ninguna '
  'inscripción) o, sin cobro, la de la fecha del ticket (p_usuario_id, p_fecha). Interna.';

revoke all on function public.campania_que_valida_el_ticket(uuid, uuid, timestamptz)
  from public, anon, authenticated, service_role;

-- Reemplaza a puede_ver_ticket_de(usuario, fecha) (0113): lo mismo, con la campaña que valida el ticket. No recibe al
-- que pregunta: sale de auth.uid(). La usan `ticket_select` y la política de la foto. Sin ticket (p_ticket_id null)
-- se comporta como la anterior, por la fecha.
create function public.puede_ver_ticket(p_ticket_id uuid, p_usuario_id uuid, p_fecha timestamptz)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select p_usuario_id = auth.uid()
      or public.tiene_rol('ADMIN')
      or (public.tiene_rol('COORDINADOR')
          and exists (select 1
                        from public.campania c
                       where c.id = public.campania_que_valida_el_ticket(p_ticket_id, p_usuario_id, p_fecha)
                         and c.coordinador_id = auth.uid()));
$$;

comment on function public.puede_ver_ticket(uuid, uuid, timestamptz) is
  'true si el usuario autenticado es el dueño (p_usuario_id), ADMIN, o COORDINADOR de la campaña que valida el ticket '
  '(campania_que_valida_el_ticket: la de la venta de su cobro o, sin cobro, la de su fecha). La coordinadora de otra '
  'campaña, aunque haya coordinado antes al colportor, no. Para ticket_select y la foto del bucket (0131).';

revoke all on function public.puede_ver_ticket(uuid, uuid, timestamptz) from public, anon, authenticated, service_role;
grant execute on function public.puede_ver_ticket(uuid, uuid, timestamptz) to authenticated;

-- La lectura de la tabla, con la regla nueva.
drop policy ticket_select on public.ticket;
create policy ticket_select on public.ticket
  for select to authenticated
  using (usuario_id = (select auth.uid())
         or (select public.tiene_rol('ADMIN'))
         or public.puede_ver_ticket(id, usuario_id, coalesce(fecha, subido_en)));

-- La foto del bucket, con la misma regla (create or replace: sus privilegios siguen).
create or replace function public.puede_ver_foto_de_ticket(p_ruta text)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select case
           when split_part(p_ruta, '/', 1) ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
            and regexp_replace(split_part(p_ruta, '/', 2), '\.(jpg|jpeg|png|webp)$', '')
                ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
             then exists (select 1
                            from public.ticket t
                           where t.id = regexp_replace(split_part(p_ruta, '/', 2), '\.(jpg|jpeg|png|webp)$', '')::uuid
                             and t.usuario_id = split_part(p_ruta, '/', 1)::uuid
                             and public.puede_ver_ticket(t.id, t.usuario_id, coalesce(t.fecha, t.subido_en)))
           else false
         end;
$$;

comment on function public.puede_ver_foto_de_ticket(text) is
  'true si el usuario autenticado puede ver el ticket que nombra la ruta <usuario_id>/<ticket_id>[.ext] '
  '(puede_ver_ticket: la campaña de la venta de su cobro o, sin cobro, la de su fecha). Sin ticket o con otra ruta: false. Para la política tickets_ver (0113, 0131).';

drop function public.puede_ver_ticket_de(uuid, timestamptz);

-- El historial del coordinador: el ticket sale en la campaña que lo valida.
create or replace function public.tickets_de_campania(
  p_campania_id uuid,
  p_estado text default null,
  p_colportor_id uuid default null,
  p_ciudad_id uuid default null,
  p_desde date default null,
  p_hasta date default null,
  p_limite integer default 200,
  p_desplazamiento integer default 0)
returns table (ticket_id uuid, colportor_id uuid, nombre text, apellido text, de_baja boolean,
               ciudad_id uuid, ciudad_nombre text, departamento text,
               tipo text, monto bigint, fecha timestamptz, numero_autorizacion text,
               tarjeta_tipo text, tarjeta_marca text,
               estado text, motivo_rechazo text, subido_en timestamptz,
               revisado_por uuid, revisado_en timestamptz,
               tiene_foto boolean, foto_ruta text,
               deposito_destino text, deposito_concepto text)
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_motivo  text;
begin
  -- El permiso, antes de mirar nada más (como las demás lecturas del panel, 0033 a 0111).
  v_motivo := public.motivo_mapa_de_campania(p_campania_id);
  if v_motivo = 'SIN_PERMISO' then
    raise exception 'Solo el coordinador de la campaña o un administrador puede ver sus tickets. Entrá con la cuenta del coordinador de esta campaña.'
      using errcode = 'insufficient_privilege';
  end if;
  if v_motivo is distinct from 'CAMPANIA_TERMINADA' then
    perform public.lanzar_motivo_mapa(v_motivo);
  end if;

  if p_estado is not null and p_estado not in ('PENDIENTE', 'VALIDADO', 'RECHAZADO') then
    raise exception 'El estado del ticket es PENDIENTE, VALIDADO o RECHAZADO.'
      using errcode = '22023';
  end if;
  if p_limite is null or p_limite < 1 or p_limite > 500 then
    raise exception 'El límite de tickets es de 1 a 500.'
      using errcode = '22023';
  end if;
  if p_desplazamiento is null or p_desplazamiento < 0 then
    raise exception 'El desplazamiento no puede ser negativo.'
      using errcode = '22023';
  end if;
  if p_desde is not null and p_hasta is not null and p_desde > p_hasta then
    raise exception 'La fecha desde no puede ser posterior a la fecha hasta.'
      using errcode = '22023';
  end if;

  return query
    with inscripcion as materialized (
      -- Una por colportor de la campaña (unique campania_id, usuario_id), también el dado de baja: lo que
      -- subió antes de irse sigue por validar. La ciudad sale de la zona actual; una zona, una ciudad de
      -- campaña o una inscripción dadas de baja no cuentan (la misma regla que 0111).
      select i.usuario_id,
             (i.deleted_at is not null) as baja,
             ci.ciudad_id as ciudad_k
        from public.campania_colportor i
        left join public.zona z
               on z.id = i.zona_id and z.deleted_at is null and i.deleted_at is null
        left join public.campania_ciudad ci
               on ci.id = z.campania_ciudad_id and ci.deleted_at is null
       where i.campania_id = p_campania_id
    )
    select t.id,
           ins.usuario_id,
           usr.nombre,
           usr.apellido,
           ins.baja,
           ciu.id,
           ciu.nombre,
           ciu.departamento,
           t.tipo,
           t.monto,
           t.fecha,
           t.numero_autorizacion,
           t.tarjeta_tipo,
           t.tarjeta_marca,
           t.estado,
           t.motivo_rechazo,
           t.subido_en,
           t.revisado_por,
           t.revisado_en,
           (t.url_cloud is not null),
           t.url_cloud,
           dep.destino,
           dep.concepto
      from inscripcion ins
      join public.usuario usr on usr.id = ins.usuario_id
      join public.ticket t
        on t.usuario_id = ins.usuario_id
       and t.deleted_at is null
       -- Un ticket, una campaña: el de otra inscripción del mismo colportor no sale acá. El de un cobro, en la de
       -- su venta (0131); el de un depósito, en la de su fecha.
       and public.campania_que_valida_el_ticket(t.id, t.usuario_id, coalesce(t.fecha, t.subido_en)) = p_campania_id
      left join public.ciudad ciu on ciu.id = ins.ciudad_k
      left join lateral (
        select d.destino, d.concepto
          from public.deposito d
         where d.ticket_id = t.id and d.deleted_at is null
         order by d.created_at, d.id
         limit 1
      ) dep on true
     where (p_estado is null or t.estado = p_estado)
       and (p_colportor_id is null or ins.usuario_id = p_colportor_id)
       and (p_ciudad_id is null or ciu.id = p_ciudad_id)
       and (p_desde is null or public.hoy_montevideo(coalesce(t.fecha, t.subido_en)) >= p_desde)
       and (p_hasta is null or public.hoy_montevideo(coalesce(t.fecha, t.subido_en)) <= p_hasta)
     -- Los pendientes primero y, entre ellos, el que espera hace más; después, el más nuevo primero.
     order by (t.estado <> 'PENDIENTE'),
              case when t.estado = 'PENDIENTE' then t.subido_en end,
              t.subido_en desc, t.id
     limit p_limite offset p_desplazamiento;
end;
$$;

comment on function public.tickets_de_campania(uuid, text, uuid, uuid, date, date, integer, integer) is
  'Vista 29, HU-COB-008 y HU-COB-009 (0113, backend-supabase#108): los tickets de los colportores inscriptos en '
  'la campaña (también los dados de baja), con la ciudad de su zona actual (null = sin ciudad), el estado, el '
  'motivo del rechazo, quién y cuándo lo revisó, la ruta de la foto en el bucket tickets (tiene_foto = false '
  'cuando venció: 4 meses) y, si hay depósito, su destino y concepto. Filtros opcionales: estado, colportor, '
  'ciudad y fecha del ticket (día de Montevideo, ambos incluidos). Pendientes primero. Hasta 500 filas '
  '(p_limite, p_desplazamiento). Sin datos de clientes. Errores: 42501 sin permiso; CZ001 campaña inexistente; '
  '22023 filtro inválido. Una campaña terminada se lee. Un ticket sale solo en la campaña que lo valida: la de la '
  'venta de su cobro o, sin cobro, la de su fecha (campania_que_valida_el_ticket, 0131).';

-- Validar, rechazar y la previa de la vista 29: el permiso, por la misma campaña.
create or replace function public.ticket_para_validar(p_ticket_id uuid, p_escribir boolean)
returns public.ticket
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_t public.ticket;
begin
  if auth.uid() is null or not (public.tiene_rol('ADMIN') or public.tiene_rol('COORDINADOR')) then
    raise exception 'Solo el coordinador de la campaña o un administrador puede validar tickets. Entrá con la cuenta del coordinador de esta campaña.'
      using errcode = 'insufficient_privilege';
  end if;

  select * into v_t from public.ticket t where t.id = p_ticket_id and t.deleted_at is null;
  if not found
     or not (public.tiene_rol('ADMIN')
             or exists (select 1
                          from public.campania ca
                         where ca.id = public.campania_que_valida_el_ticket(v_t.id, v_t.usuario_id, coalesce(v_t.fecha, v_t.subido_en))
                           and ca.coordinador_id = auth.uid())) then
    raise exception 'El ticket no existe o no es de un colportor de tus campañas. Recargá la lista de tickets.'
      using errcode = 'TV001';
  end if;
  if v_t.usuario_id = auth.uid() then
    raise exception 'No podés validar ni rechazar tu propio ticket. Pedile a otro coordinador o a un administrador que lo haga.'
      using errcode = 'insufficient_privilege';
  end if;

  if p_escribir then
    select * into v_t from public.ticket t where t.id = p_ticket_id for update;
  end if;
  return v_t;
end;
$$;

comment on function public.ticket_para_validar(uuid, boolean) is
  'El ticket con el permiso comprobado (0129, 0131): ADMIN o el coordinador de la campaña que lo valida (la de la venta de su cobro o, sin cobro, la de su fecha), nunca el propio. '
  'Con p_escribir bloquea la fila. 42501 sin permiso; TV001 si no existe o no es de sus campañas. Interna.';
