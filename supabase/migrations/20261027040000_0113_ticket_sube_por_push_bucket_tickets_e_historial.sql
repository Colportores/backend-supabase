-- ============================================================================
-- 0113 · El ticket de tarjeta y de depósito sube del teléfono: tabla en el push, bucket privado `tickets`,
--        historial del coordinador y vencimiento de la foto a los 4 meses (backend-supabase#108,
--        HU-COB-007, HU-COB-008, HU-COB-009)
--
-- Decisión de Cristian del 23/10, «Ticket S10» (front-colportores-mobile#426): «El ticket completo ya»:
-- foto, fecha, número de autorización, tarjeta, monto e historial entran en el S10, adelantados de V2.
-- Y la decisión del orquestador del mismo día (coherencia): la 0067 (backend-supabase#100) ya creó la
-- tabla `ticket` con todas sus columnas, vacía y de solo lectura; esta migración SOLO SUMA sobre ella, no
-- la vuelve a crear. Destraba front-colportores-mobile#426 y #427 (subir el ticket) y
-- front-coordinadores-web#69 (la vista 29). Validar el ticket y que acredite (HU-COB-008) es
-- backend-supabase#110, no esto.
--
-- ## Qué suma
--
--   1. El ticket sube por el push (contrato §2): `sync.entidad` ('ticket', push, PK `id`, dueño
--      `usuario_id`). La HU lo pide así (HU-COB-007: «sin red queda en `sync_queue`»); la colportora lo
--      baja de nuevo con su historial, que se ve sin conexión (HU-COB-009). Política de INSERT y de
--      UPDATE para la dueña, y un trigger que decide qué puede hacer el teléfono (abajo).
--   2. La foto vive en el bucket PRIVADO `tickets` de Supabase Storage (ADR-012) y se mira con una URL
--      firmada de corta duración. Ruta: `<usuario_id>/<ticket_id>` con extensión opcional
--      (.jpg, .jpeg, .png o .webp). Políticas de `storage.objects`: la colportora sube y ve las suyas; el
--      ADMIN y el coordinador del colportor ven las del colportor. Nadie con JWT pisa ni borra una foto.
--   3. `tickets_de_campania(...)`: el historial del panel (HU-COB-009) con filtros por ciudad, colportor,
--      estado y fecha, los pendientes primero.
--   4. `tickets_con_foto_vencida()` y `soltar_foto_de_ticket()`: la foto se conserva 4 meses (RF-CO08A);
--      pasado el plazo el ticket conserva sus datos y deja de mostrar la foto. Solo las usa el servidor.
--   5. Una guarda en `cobranza`: el `ticket_id` de un cobro tiene que ser un ticket de quien hizo la venta.
--
-- ## Lo que el teléfono puede hacer con un ticket (trigger `ticket_del_cliente`, solo para `authenticated`)
--
--   · Crear uno. Nace siempre PENDIENTE y sin revisión: `estado`, `revisado_por`, `revisado_en`,
--     `motivo_rechazo`, `subido_en` y `usuario_id` los pone el servidor (`columnas_servidor` los descarta
--     del push; por la API directa, un valor ajeno es 42501). La dueña sale del JWT.
--   · Con los datos que la HU pide, o vuelve `invalid` con 23514 y un mensaje que dice qué completar:
--     monto (mayor que cero, CHECK de 0067), fecha (no futura, el día de Montevideo) y, si es el ticket
--     de un cobro con tarjeta, el número de autorización y si la tarjeta es de crédito o de débito. La
--     marca («cuál») queda opcional: el canvas de la vista 38 todavía no la dibuja. El ticket de un
--     depósito no pide tarjeta ni autorización; si el banco da un número de operación, va en
--     `numero_autorizacion` (el canvas 38A-01 lo muestra ahí; la HU lo llama «referencia»: pendiente).
--   · Después de subirlo, lo único que cambia es la foto: de vacía a su ruta, una sola vez. Cualquier otro
--     cambio, la baja y cambiar o quitar una foto ya puesta son 42501 («pedile al coordinador que lo
--     rechace y cargalo de nuevo»). Un ticket validado o rechazado no lo toca nadie desde el teléfono (la
--     política de UPDATE lo deja fuera; el servidor sigue con TK001 de 0067).
--   · La foto de un ticket tiene que estar en la carpeta de su dueña y con el id del ticket
--     (`ticket_foto_en_tu_carpeta`, 23514): no se puede apuntar a la foto de otro.
--
-- El servidor (service_role, el editor SQL, las funciones DEFINER) no pasa por este trigger.
--
-- ## El bucket
--
--   · `tickets`: privado, 2 MiB por archivo, solo imágenes (JPEG, PNG, WebP). El tope y los tipos son los
--     de una foto comprimida (≈200 KB de objetivo blando, la legibilidad gana: HU-COB-007); un cifrado
--     de la foto con la clave de la colportora la volvería ilegible para el panel (pendiente).
--   · Las tablas de `storage` las crea el servicio Storage, no la imagen de Postgres: si no existen al
--     migrar (la base del job `migraciones` de CI, o un `supabase start` que migra antes de que Storage
--     arranque) la migración avisa y sigue, igual que la 0029. En local, el bucket sale además de
--     `[storage.buckets.tickets]` de config.toml; las políticas, de esta migración (README § Tickets).
--     El job `storage` de CI las prueba contra un storage-api real (supabase/tests/0113_bucket_tickets_test.sql).
--   · Subir no exige que el ticket ya exista: el motor puede subir la foto antes o después del ticket.
--
-- ## Lo que NO hace (y por qué)
--
--   · No valida ni acredita (backend-supabase#110), no avisa al coordinador (HU-NOT-003, Edge Function) ni
--     programa el vencimiento: `tickets_con_foto_vencida()` dice qué fotos vencieron y
--     `soltar_foto_de_ticket()` las suelta, pero quién las corre y borra el archivo del Storage queda
--     pendiente.
--   · No crea `deposito` en el push ni el vínculo ticket-depósito del teléfono (otro issue).
--   · No cifra la foto: el cifrado con la clave de la colportora y la copia local son del móvil (#426);
--     el cifrado y la vista del coordinador chocan y está en el archivo de pendientes.
--
-- ## Los datos
--
-- Solo suma: una columna con default, dos políticas, un índice, tres triggers, funciones, una fila en
-- sync.entidad y su columnas_servidor. No hay UPDATE ni DELETE de datos: ninguna fila existente cambia, ni
-- su `sync_version` ni su `xmin_w` (los teléfonos no bajan nada de nuevo). Lo prueba
-- supabase/tests_migracion/0113_ok.
--
-- ## Para otros repos
--
--   · front-colportores-mobile#426/#427 y el motor de sync: la entidad `ticket` (push; la clave local es un
--     uuid por fila). El servidor responde `invalid` con 23514 si falta el monto, la fecha, la autorización
--     o el tipo de tarjeta del cobro, o si la fecha es futura, y 42501 si se intenta cambiar un ticket ya
--     subido; un update sobre un ticket ya resuelto vuelve `conflict` (la política no lo ve) y la app baja
--     la fila del servidor. La foto sube al bucket `tickets` en `<usuario_id>/<ticket_id>.jpg` y su ruta
--     va en `url_cloud` (en el mismo insert, o en un update después de subirla).
--   · front-coordinadores-web#69: POST /rest/v1/rpc/tickets_de_campania; la foto se pide con
--     `createSignedUrl(foto_ruta, 60)` del bucket `tickets`.
--   · docs-organizacion: contrato-sync-engine.md §2 (la fila `ticket`), esquema-datos.md (ticket) y
--     HU-COB-007 (bucket de Supabase Storage y no R2: ADR-012).
--
-- Forward-only: esta migración no se edita una vez aplicada.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. La dueña la fija el servidor
-- ----------------------------------------------------------------------------

-- Como devolucion (0108): el payload no manda `usuario_id`, sale del JWT. Sin JWT queda null y falla el
-- NOT NULL (23502).
alter table public.ticket
  alter column usuario_id set default auth.uid();

-- El delta con el dueño primero, para que el predicado de la RLS entre en el Index Cond (0002 §14).
create index ticket_delta_idx on public.ticket (usuario_id, xmin_w, id);

-- ----------------------------------------------------------------------------
-- 2. Qué puede hacer el teléfono con un ticket
-- ----------------------------------------------------------------------------

create function public.tg_ticket_del_cliente()
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
      new.deleted_at)
     is distinct from
     (old.usuario_id, old.tipo, old.subido_en, old.revisado_por, old.revisado_en, old.monto, old.fecha,
      old.numero_autorizacion, old.tarjeta_tipo, old.tarjeta_marca, old.estado, old.motivo_rechazo,
      old.deleted_at) then
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

comment on function public.tg_ticket_del_cliente() is
  'BEFORE INSERT / UPDATE de ticket, solo para authenticated (0113): un ticket nuevo nace PENDIENTE con el '
  'monto, la fecha (no futura) y, si es de un cobro con tarjeta, la autorización y el tipo de tarjeta (23514); '
  'después solo se completa la foto, una vez, en la carpeta de la dueña (42501 / 23514). El servidor no pasa por acá.';

revoke all on function public.tg_ticket_del_cliente() from public, anon, authenticated, service_role;

-- El nombre empieza antes que `ticket_resuelto_no_se_edita` (0067): el aviso claro sale primero que TK001.
create trigger ticket_del_cliente
  before insert or update on public.ticket
  for each row execute function public.tg_ticket_del_cliente();

-- ----------------------------------------------------------------------------
-- 3. RLS y privilegios: la dueña crea sus tickets y completa la foto de los que están por validar
-- ----------------------------------------------------------------------------

create policy ticket_insert_propio on public.ticket
  for insert to authenticated
  with check (usuario_id = (select auth.uid()));

-- USING = lo que ve para cambiar: solo los suyos por validar y vivos; así un ticket ya resuelto vuelve
-- `conflict` en el push y la app baja la fila del servidor. WITH CHECK = lo que deja: sigue siendo suyo.
create policy ticket_update_propio on public.ticket
  for update to authenticated
  using (usuario_id = (select auth.uid()) and estado = 'PENDIENTE' and deleted_at is null)
  with check (usuario_id = (select auth.uid()) and estado = 'PENDIENTE');

-- Sin DELETE ni política: una baja es del servidor.
grant insert, update on public.ticket to authenticated;

-- ----------------------------------------------------------------------------
-- 4. El registro en el motor de sync (contrato §2: push)
-- ----------------------------------------------------------------------------

-- El pull baja solo los tickets del usuario (columna_duenio), aunque algún día la RLS de lectura se
-- amplíe: el coordinador los lee por tickets_de_campania(), no por el pull.
insert into sync.entidad (nombre, tabla, columna_pk, permite_push, columna_duenio) values
  ('ticket', 'public.ticket'::regclass, 'id', true, 'usuario_id');

-- Lo que decide el servidor no se escribe desde el teléfono: la dueña, el estado y la revisión, y
-- cuándo llegó. La foto (url_cloud) sí.
update sync.entidad
   set columnas_servidor = columnas_servidor
       || array['usuario_id', 'subido_en', 'estado', 'revisado_por', 'revisado_en', 'motivo_rechazo']
 where nombre = 'ticket';

-- ----------------------------------------------------------------------------
-- 5. El ticket de un cobro es del que hizo la venta
-- ----------------------------------------------------------------------------

-- ¿Existe el ticket y es de otro colportor que el de la venta? SECURITY DEFINER: la colportora no lee los
-- tickets ajenos por RLS, y con RLS un ticket ajeno se vería igual que uno inexistente. Un ticket o una
-- venta que no existen dan false: ahí hablan la FK (23503) y la RLS (42501), no esta guarda.
create function public.ticket_ajeno_a_la_venta(p_ticket_id uuid, p_venta_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
      from public.ticket t
      join public.venta v on v.id = p_venta_id
     where t.id = p_ticket_id
       and t.usuario_id <> v.colportor_id
  );
$$;

comment on function public.ticket_ajeno_a_la_venta(uuid, uuid) is
  'true si el ticket existe y es de otro colportor que el de la venta (0113). Para la guarda de cobranza.ticket_id.';

revoke all on function public.ticket_ajeno_a_la_venta(uuid, uuid) from public, anon, authenticated, service_role;
grant execute on function public.ticket_ajeno_a_la_venta(uuid, uuid) to authenticated;

create function public.tg_cobranza_ticket_propio()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  -- Solo el camino del teléfono (el servidor corrige a mano lo que haga falta) y solo si el ticket cambia.
  if current_user not in ('authenticated', 'anon') or new.ticket_id is null then
    return new;
  end if;
  if tg_op = 'UPDATE' and new.ticket_id is not distinct from old.ticket_id then
    return new;
  end if;
  if public.ticket_ajeno_a_la_venta(new.ticket_id, new.venta_id) then
    raise exception 'Ese ticket no es de quien hizo esta venta. Cargá el ticket de tu cobro desde tu teléfono.'
      using errcode = '42501';
  end if;
  return new;
end;
$$;

comment on function public.tg_cobranza_ticket_propio() is
  'BEFORE INSERT / UPDATE OF ticket_id de cobranza, solo para authenticated (0113): el ticket de un cobro es '
  'de quien hizo la venta (42501). Un ticket inexistente lo rechaza la FK (23503).';

revoke all on function public.tg_cobranza_ticket_propio() from public, anon, authenticated, service_role;

create trigger cobranza_ticket_propio
  before insert or update of ticket_id on public.cobranza
  for each row execute function public.tg_cobranza_ticket_propio();

-- ----------------------------------------------------------------------------
-- 6. El historial del coordinador (HU-COB-009, vista 29)
-- ----------------------------------------------------------------------------

create function public.tickets_de_campania(
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
      join public.ticket t on t.usuario_id = ins.usuario_id and t.deleted_at is null
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
  '22023 filtro inválido. Una campaña terminada se lee.';

revoke all on function public.tickets_de_campania(uuid, text, uuid, uuid, date, date, integer, integer)
  from public, anon, authenticated, service_role;
grant execute on function public.tickets_de_campania(uuid, text, uuid, uuid, date, date, integer, integer)
  to authenticated;

-- ----------------------------------------------------------------------------
-- 7. La foto se conserva 4 meses (RF-CO08A)
-- ----------------------------------------------------------------------------

-- Los tickets cuya foto ya pasó el plazo, contado desde que se subió el ticket. Solo la lee el servidor,
-- que borra cada archivo del Storage por su API (borrar la fila de storage.objects por SQL no borra el
-- archivo) y después suelta la ruta con soltar_foto_de_ticket(). Incluye tickets dados de baja.
create function public.tickets_con_foto_vencida(p_ahora timestamptz default now())
returns table (ticket_id uuid, ruta text)
language sql
stable
set search_path = ''
as $$
  select t.id, t.url_cloud
    from public.ticket t
   where t.url_cloud is not null
     and t.subido_en <= p_ahora - interval '4 months'
   order by t.subido_en, t.id;
$$;

comment on function public.tickets_con_foto_vencida(timestamptz) is
  'Tickets con foto en el bucket tickets subidos hace 4 meses o más (0113, RF-CO08A): id y ruta. Solo service_role. '
  'Después de borrar el archivo por la API de Storage, soltar_foto_de_ticket() libera la ruta.';

create function public.soltar_foto_de_ticket(p_ticket_id uuid)
returns boolean
language plpgsql
volatile
set search_path = ''
as $$
declare
  v_filas integer;
begin
  -- El ticket conserva sus datos y deja de mostrar la foto. TK001 (0067) deja pasar url_cloud en un ticket
  -- resuelto. El UPDATE sube sync_version: la colportora ve «la foto ya no está» en su historial.
  update public.ticket set url_cloud = null where id = p_ticket_id and url_cloud is not null;
  get diagnostics v_filas = row_count;
  return v_filas > 0;
end;
$$;

comment on function public.soltar_foto_de_ticket(uuid) is
  'Deja el ticket sin foto (url_cloud = null) una vez borrado el archivo del Storage (0113, RF-CO08A). Solo '
  'service_role. true si había foto; false si ya no (idempotente).';

revoke all on function public.tickets_con_foto_vencida(timestamptz) from public, anon, authenticated, service_role;
revoke all on function public.soltar_foto_de_ticket(uuid) from public, anon, authenticated, service_role;
grant execute on function public.tickets_con_foto_vencida(timestamptz) to service_role;
grant execute on function public.soltar_foto_de_ticket(uuid) to service_role;

-- ----------------------------------------------------------------------------
-- 8. El bucket privado `tickets` y sus políticas
-- ----------------------------------------------------------------------------

-- Las tablas de `storage` las crea el servicio Storage; si todavía no existen, no hay dónde insertar y la
-- migración no puede fallar, porque rompería todo lo demás (ver 0029). Avisa y sigue: el job `storage` de CI
-- corre estas políticas contra un storage-api real y falla si se saltearon.
do $tickets$
begin
  if to_regclass('storage.buckets') is null or to_regclass('storage.objects') is null then
    raise notice '0113: no existe storage.buckets / storage.objects (la base no tiene el servicio Storage); no se crea el bucket tickets ni sus politicas desde esta migracion.';
    return;
  end if;

  -- Privado: la foto se mira con una URL firmada de corta duración. 2 MiB por archivo y solo imágenes.
  insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
  values ('tickets', 'tickets', false, 2097152, array['image/jpeg', 'image/png', 'image/webp'])
  on conflict (id) do update
    set public             = excluded.public,
        file_size_limit    = excluded.file_size_limit,
        allowed_mime_types = excluded.allowed_mime_types;

  -- Subir: solo a su carpeta y con el nombre de un ticket (<usuario_id>/<ticket_id>[.jpg|.jpeg|.png|.webp]).
  -- Sin política de UPDATE ni de DELETE: una foto subida no se pisa ni se borra desde el teléfono (es la
  -- prueba del ticket); el vencimiento lo borra el servidor.
  drop policy if exists tickets_subir_propia on storage.objects;
  create policy tickets_subir_propia on storage.objects
    for insert to authenticated
    with check (
      bucket_id = 'tickets'
      and split_part(name, '/', 1) = (select auth.uid())::text
      and name ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}(\.(jpg|jpeg|png|webp))?$'
    );

  -- Ver (y pedir la URL firmada): la dueña, el ADMIN y quien coordina al colportor de la carpeta. El cast a
  -- uuid va dentro del CASE: Postgres no garantiza el orden de un AND.
  drop policy if exists tickets_ver on storage.objects;
  create policy tickets_ver on storage.objects
    for select to authenticated
    using (
      bucket_id = 'tickets'
      and (
        split_part(name, '/', 1) = (select auth.uid())::text
        or (select public.tiene_rol('ADMIN'))
        or case
             when split_part(name, '/', 1) ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
               then public.coordina_al_colportor(split_part(name, '/', 1)::uuid)
             else false
           end
      )
    );
end
$tickets$;
