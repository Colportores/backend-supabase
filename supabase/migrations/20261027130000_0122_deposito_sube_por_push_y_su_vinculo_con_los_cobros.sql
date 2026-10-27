-- ============================================================================
-- 0122 · El depósito de efectivo sube del teléfono, y el vínculo con los cobros que incluye
--        (backend-supabase#135, BACK-HU-CTA-004; decisión de Cristian del 23/10, «Depósito S11»,
--        front-colportores-mobile#173)
--
-- «Como el canvas, en el S11»: el depósito lleva monto, para qué (casa editora o alquiler), dónde (banco,
-- oficina o retiro por el coordinador) y fecha, y de la migración V2 (backend-supabase#100) se adelanta solo
-- la tabla de depósitos y su vínculo con los cobros. «Acredita V1»: el depósito queda «por validar» y suma a
-- «Depositado» recién cuando el coordinador lo valida (backend-supabase#110), no al registrarlo. Y «Paso
-- ticket»: el depósito se registra al cargar el ticket del banco, un solo paso. Destraba
-- front-colportores-mobile#442 (el registro local y los cobros incluidos) y #443 (la vista 33 D).
--
-- La 0067 (#100) ya creó `deposito` (vacía, de solo lectura) y la 0114 (#111) le sumó `campania_id`. Esta
-- migración SOLO SUMA sobre ella, no la vuelve a crear (decisión del orquestador del 23/10, coherencia).
--
-- ## Qué suma
--
--   1. `deposito` entra al push (contrato §2): `sync.entidad` ('deposito', push, PK `id`, dueño
--      `colportor_id`). Política de INSERT para la dueña. Es una entidad de solo alta desde el teléfono: sin
--      política ni privilegio de UPDATE: un push que la modifique vuelve `invalid` con 42501 (el camino de
--      «corregir» un depósito lo decide el coordinador o el servidor, no el teléfono).
--   2. `deposito_cobro`, el vínculo: una fila por cada cobro EFECTIVO que el depósito incluye («Cobros
--      incluidos»: el teléfono los auto-selecciona hasta llegar al monto, ajustable, y un depósito parcial
--      deja los demás «en mano»). Entidad del push, dueño `colportor_id`. Un cobro entra a un solo depósito
--      (índice único parcial, 23505): lo que no está en ningún depósito vivo es lo que sigue «en mano». El
--      vínculo es una tabla aparte y no una columna de `cobranza`: el cobro ya tiene su propio camino de
--      cambios (anulación, ventana de 72 h: 0072) y acá no se toca.
--   3. Lo que decide el servidor sobre un depósito que llega del teléfono (trigger `deposito_del_cliente`,
--      de alta, solo para `authenticated`):
--        · la dueña sale del JWT (`colportor_id`, default `auth.uid()`, descartado del payload);
--        · la fecha no es futura (día de Montevideo): 23514, `deposito_fecha_no_futura`;
--        · `campania_id`, si viene, es de una campaña donde la colportora está o estuvo inscripta: 42501;
--        · `ticket_id`, si viene, es un ticket SUYO y de tipo DEPOSITO (42501 si es de otra o de otro tipo;
--          23503 si no existe: lo dice la FK);
--        · un retiro por el coordinador no lleva ticket (el comprobante es del banco): 23514, CHECK
--          `deposito_retiro_sin_ticket` (vale para todos, también para el servidor);
--        · un ticket respalda un solo depósito vivo (índice único parcial, 23505): el diagrama del esquema
--          dice «Deposito 0..1 — 1 Ticket».
--      Monto positivo, destino y concepto de la lista y el ALQUILER con campaña ya los cuidan los CHECK de
--      la 0067 y la 0114.
--   4. Lo que decide el servidor sobre un vínculo (trigger `deposito_cobro_del_cliente`, solo para
--      `authenticated`): el cobro existe y es de una venta de la misma colportora (42501), es EFECTIVO
--      (23514), no está anulado (23514) ni dado de baja (23514). Y por RLS el depósito es de ella (42501).
--
-- ## Lo que NO hace (y por qué)
--
--   · No valida ni acredita (backend-supabase#110): no hay estado en `deposito`. Un depósito con ticket
--     queda «por validar» mientras su ticket está PENDIENTE; cómo se valida un retiro por el coordinador
--     (que no tiene ticket) lo decide #110. El registro NO baja la deuda ni suma a «Depositado»: lo hace la
--     validación.
--   · No exige que un depósito de BANCO u OFICINA lleve ticket: el ticket llega en el mismo lote del push
--     («Paso ticket») pero el teléfono puede registrar el depósito primero. Sin ticket el depósito no tiene
--     qué validar el coordinador: pendiente de decisión (archivo de pendientes del carril).
--   · No cruza la suma de los cobros vinculados con el monto del depósito: el monto es lo que se depositó
--     (puede incluir parte de un cobro o más que los cobros en mano) y los vínculos llegan en otro lote del
--     push. Un rechazo por el orden de llegada dejaría el lote atascado en el teléfono.
--   · No permite desvincular un cobro desde el teléfono (sin UPDATE ni baja): si un depósito se corrige, lo
--     hace el servidor.
--   · No lee nada para el coordinador por el pull: lo ve por RLS (como `deposito`, 0067) y las cifras del
--     panel salen de `cuentas_de_campania` (0114).
--
-- ## Los datos
--
-- Solo suma: una tabla nueva (vacía), una función de lectura, tres triggers, tres índices (uno único parcial
-- sobre `deposito`), un CHECK, dos filas en sync.entidad y su columnas_servidor. No hay UPDATE ni DELETE de
-- datos: ningún depósito existente cambia, ni su `sync_version` ni su `xmin_w`. El CHECK nuevo y el índice
-- único sobre filas que ya hubiera salen de una tabla que en producción está vacía; si hubiera datos de
-- prueba que los violen, la migración falla a la vista (nada se corrige a escondidas). Lo prueba
-- supabase/tests_migracion/0122_ok.
--
-- ## Para otros repos
--
--   · front-colportores-mobile#442/#443 y el motor de sync: las entidades `deposito` y `deposito_cobro`
--     (push, la clave local es un uuid por fila; el vínculo apunta a `deposito_id` y `cobranza_id`). El
--     servidor aplica el lote en el orden en que llega: el depósito sube ANTES que sus vínculos (un vínculo
--     de un depósito que todavía no existe vuelve `invalid` 42501). `invalid` con 23514 (fecha futura, retiro con ticket, cobro no
--     efectivo o anulado, monto), 42501 (campaña, ticket o cobro ajeno, o cualquier update o baja), 23505
--     (cobro o ticket ya usado en otro depósito) y 23503 (ticket o cobro inexistente).
--   · backend-supabase#110: el estado «por validar» de un depósito sale del ticket; el retiro del
--     coordinador necesita su propia marca (no está acá).
--   · docs-organizacion: esquema-datos.md (deposito y deposito_cobro), contrato-sync-engine.md §2 (las dos
--     filas), HU-CTA-004 (los cobros incluidos no se «marcan con fecha_deposito»: se vinculan) y
--     plan-sprints.md.
--
-- Forward-only: esta migración no se edita una vez aplicada.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. deposito: la dueña la fija el servidor, un retiro no lleva ticket y un ticket respalda un solo depósito
-- ----------------------------------------------------------------------------

-- Como devolucion (0108) y ticket (0113): el payload no manda `colportor_id`, sale del JWT. Sin JWT queda
-- null y falla el NOT NULL (23502).
alter table public.deposito
  alter column colportor_id set default auth.uid();

-- El nombre va después de los CHECK de 0067 y 0114 (Postgres los evalúa por orden alfabético): un depósito
-- inválido por otra razón sigue dando el error de siempre.
alter table public.deposito
  add constraint deposito_retiro_sin_ticket
  check (destino <> 'RETIRO_COORDINADOR' or ticket_id is null);

-- Un ticket respalda un solo depósito vivo.
create unique index deposito_ticket_unico on public.deposito (ticket_id)
  where ticket_id is not null and deleted_at is null;

-- El delta con la dueña primero, para que el predicado de la RLS entre en el Index Cond (0002 §14).
create index deposito_delta_idx on public.deposito (colportor_id, xmin_w, id);

comment on column public.deposito.ticket_id is
  'El comprobante del depósito (BANCO u OFICINA): un ticket de la misma colportora y de tipo DEPOSITO, que '
  'respalda un solo depósito vivo (0122). Null en un retiro por el coordinador, que no lleva comprobante.';

-- ----------------------------------------------------------------------------
-- 2. deposito_cobro: los cobros en efectivo que incluye un depósito
-- ----------------------------------------------------------------------------

create table public.deposito_cobro (
  id            uuid primary key default public.uuid_generate_v7(),
  deposito_id   uuid not null references public.deposito(id),
  cobranza_id   uuid not null references public.cobranza(id),
  colportor_id  uuid not null default auth.uid() references public.usuario(id),
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  created_by    uuid default auth.uid() references public.usuario(id) on delete set null,
  deleted_at    timestamptz,
  sync_version  bigint not null default 0,
  xmin_w        xid8 not null default pg_current_xact_id()
);

comment on table public.deposito_cobro is
  'Los cobros en efectivo que incluye un depósito (0122, HU-CTA-004): un cobro entra a un solo depósito vivo, y '
  'el que no está en ninguno sigue «en mano». Sin datos del cliente: solo ids. Sube por push (0122).';
comment on column public.deposito_cobro.colportor_id is
  'La colportora dueña del depósito y del cobro. Lo fija el servidor desde el JWT; el payload no lo manda.';

-- Un cobro, un depósito vivo. La baja del vínculo (la hace el servidor) lo libera.
create unique index deposito_cobro_cobro_unico on public.deposito_cobro (cobranza_id)
  where deleted_at is null;
create index deposito_cobro_deposito_idx on public.deposito_cobro (deposito_id);
create index deposito_cobro_delta_idx on public.deposito_cobro (colportor_id, xmin_w, id);

create trigger deposito_cobro_auditoria_insert before insert on public.deposito_cobro
  for each row execute function public.tg_auditoria_insert();
create trigger deposito_cobro_auditoria_update before update on public.deposito_cobro
  for each row execute function public.tg_auditoria_update();

-- ----------------------------------------------------------------------------
-- 3. Qué decide el servidor sobre un depósito que llega del teléfono
-- ----------------------------------------------------------------------------

-- ¿Por qué un ticket no sirve de comprobante para este depósito? null si sirve (o si no existe: ahí habla la
-- FK, 23503). SECURITY DEFINER: la colportora no lee los tickets ajenos por RLS, y con RLS un ticket ajeno se
-- vería igual que uno inexistente.
create function public.ticket_no_sirve_de_deposito(p_ticket_id uuid, p_colportor_id uuid)
returns text
language sql
stable
security definer
set search_path = ''
as $$
  select case
           when t.usuario_id <> p_colportor_id then 'AJENO'
           when t.tipo <> 'DEPOSITO' then 'TIPO'
         end
    from public.ticket t
   where t.id = p_ticket_id;
$$;

comment on function public.ticket_no_sirve_de_deposito(uuid, uuid) is
  'null si el ticket sirve de comprobante de un depósito de esa colportora o no existe; AJENO si es de otro '
  'usuario; TIPO si no es de tipo DEPOSITO (0122). Interna: la llama el trigger de deposito.';

revoke all on function public.ticket_no_sirve_de_deposito(uuid, uuid) from public, anon, authenticated, service_role;
grant execute on function public.ticket_no_sirve_de_deposito(uuid, uuid) to authenticated;

-- ¿Estuvo la colportora inscripta en esa campaña (con la inscripción viva o de baja)? SECURITY DEFINER: las
-- bajas no las lee por RLS.
create function public.estuvo_inscripta_en_campania(p_usuario_id uuid, p_campania_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
      from public.campania_colportor cc
     where cc.usuario_id = p_usuario_id
       and cc.campania_id = p_campania_id
  );
$$;

comment on function public.estuvo_inscripta_en_campania(uuid, uuid) is
  'true si el usuario tiene o tuvo una inscripción (viva o de baja) en la campaña (0122). Interna.';

revoke all on function public.estuvo_inscripta_en_campania(uuid, uuid) from public, anon, authenticated, service_role;
grant execute on function public.estuvo_inscripta_en_campania(uuid, uuid) to authenticated;

create function public.tg_deposito_del_cliente()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_motivo text;
begin
  -- El servidor (service_role, el editor SQL, una función DEFINER) no pasa por acá. El push corre INVOKER
  -- como `authenticated`; una RPC DEFINER corre como su dueño (patrón de 0053, 0100 y 0113).
  if current_user not in ('authenticated', 'anon') then
    return new;
  end if;

  if public.hoy_montevideo(new.fecha) > public.hoy_montevideo() then
    raise exception 'La fecha del depósito no puede ser futura. Revisá el día.'
      using errcode = '23514', constraint = 'deposito_fecha_no_futura';
  end if;

  if new.campania_id is not null
     and not public.estuvo_inscripta_en_campania(new.colportor_id, new.campania_id) then
    raise exception 'No estás inscripto en esa campaña. Elegí una campaña tuya.'
      using errcode = '42501';
  end if;

  if new.ticket_id is not null then
    v_motivo := public.ticket_no_sirve_de_deposito(new.ticket_id, new.colportor_id);
    if v_motivo = 'AJENO' then
      raise exception 'Ese ticket no es tuyo. Cargá el ticket de tu depósito desde tu teléfono.'
        using errcode = '42501';
    elsif v_motivo = 'TIPO' then
      raise exception 'Ese ticket no es de un depósito. Cargá el ticket del banco o de la oficina.'
        using errcode = '42501';
    end if;
  end if;
  return new;
end;
$$;

comment on function public.tg_deposito_del_cliente() is
  'BEFORE INSERT de deposito, solo para authenticated (0122): la fecha no es futura (23514); la campaña, si '
  'viene, es de una inscripción suya y el ticket es suyo y de tipo DEPOSITO (42501). El servidor no pasa por acá.';

revoke all on function public.tg_deposito_del_cliente() from public, anon, authenticated, service_role;

create trigger deposito_del_cliente
  before insert on public.deposito
  for each row execute function public.tg_deposito_del_cliente();

-- ----------------------------------------------------------------------------
-- 4. Qué decide el servidor sobre un vínculo
-- ----------------------------------------------------------------------------

-- ¿Por qué un cobro no puede entrar a un depósito de esta colportora? null si puede o si no existe (ahí habla
-- la FK, 23503). SECURITY DEFINER: lee la venta y el cobro ajenos sin que la RLS los esconda.
create function public.cobro_no_entra_en_deposito(p_cobranza_id uuid, p_colportor_id uuid)
returns text
language sql
stable
security definer
set search_path = ''
as $$
  select case
           when v.colportor_id <> p_colportor_id then 'AJENO'
           when c.deleted_at is not null then 'BAJA'
           when c.anulado_at is not null then 'ANULADO'
           when c.medio <> 'EFECTIVO' then 'MEDIO'
         end
    from public.cobranza c
    join public.venta v on v.id = c.venta_id
   where c.id = p_cobranza_id;
$$;

comment on function public.cobro_no_entra_en_deposito(uuid, uuid) is
  'null si el cobro puede entrar a un depósito de esa colportora o no existe; AJENO (venta de otra), BAJA, '
  'ANULADO o MEDIO (no es EFECTIVO) si no (0122). Interna: la llama el trigger de deposito_cobro.';

revoke all on function public.cobro_no_entra_en_deposito(uuid, uuid) from public, anon, authenticated, service_role;
grant execute on function public.cobro_no_entra_en_deposito(uuid, uuid) to authenticated;

create function public.tg_deposito_cobro_del_cliente()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_motivo text;
begin
  if current_user not in ('authenticated', 'anon') then
    return new;
  end if;

  v_motivo := public.cobro_no_entra_en_deposito(new.cobranza_id, new.colportor_id);
  if v_motivo = 'AJENO' then
    raise exception 'Ese cobro no es de una venta tuya. Incluí en el depósito solo tus cobros.'
      using errcode = '42501';
  elsif v_motivo = 'BAJA' then
    raise exception 'Ese cobro está dado de baja y no se puede incluir en un depósito.'
      using errcode = '23514', constraint = 'deposito_cobro_dado_de_baja';
  elsif v_motivo = 'ANULADO' then
    raise exception 'Ese cobro está anulado y no se puede incluir en un depósito.'
      using errcode = '23514', constraint = 'deposito_cobro_anulado';
  elsif v_motivo = 'MEDIO' then
    raise exception 'Solo los cobros en efectivo se incluyen en un depósito de efectivo.'
      using errcode = '23514', constraint = 'deposito_cobro_en_efectivo';
  end if;
  return new;
end;
$$;

comment on function public.tg_deposito_cobro_del_cliente() is
  'BEFORE INSERT de deposito_cobro, solo para authenticated (0122): el cobro es de una venta suya (42501), es '
  'EFECTIVO, no está anulado ni de baja (23514).';

revoke all on function public.tg_deposito_cobro_del_cliente() from public, anon, authenticated, service_role;

create trigger deposito_cobro_del_cliente
  before insert on public.deposito_cobro
  for each row execute function public.tg_deposito_cobro_del_cliente();

-- ----------------------------------------------------------------------------
-- 5. RLS y privilegios
-- ----------------------------------------------------------------------------

-- deposito: la dueña crea los suyos. Sin UPDATE ni DELETE (ver el encabezado).
create policy deposito_insert_propio on public.deposito
  for insert to authenticated
  with check (colportor_id = (select auth.uid()));

grant insert on public.deposito to authenticated;

-- deposito_cobro: lee quien lee el depósito (la dueña, el ADMIN, quien la coordina); inserta la dueña, de un
-- depósito suyo.
alter table public.deposito_cobro enable row level security;

create policy deposito_cobro_select on public.deposito_cobro
  for select to authenticated
  using (colportor_id = (select auth.uid())
         or (select public.tiene_rol('ADMIN'))
         or public.coordina_al_colportor(colportor_id));

create policy deposito_cobro_insert_propio on public.deposito_cobro
  for insert to authenticated
  with check (colportor_id = (select auth.uid())
              and exists (select 1 from public.deposito d
                           where d.id = deposito_id and d.colportor_id = (select auth.uid())));

revoke all on public.deposito_cobro from anon, authenticated;
grant select, insert on public.deposito_cobro to authenticated;
grant all on public.deposito_cobro to service_role;

-- ----------------------------------------------------------------------------
-- 6. El registro en el motor de sync (contrato §2: push, sin alsoPull)
-- ----------------------------------------------------------------------------

-- El pull baja solo lo del usuario (columna_duenio), aunque algún día la RLS de lectura se amplíe: el
-- coordinador los lee por las cifras del panel, no por el pull.
insert into sync.entidad (nombre, tabla, columna_pk, permite_push, columna_duenio) values
  ('deposito',       'public.deposito'::regclass,       'id', true, 'colportor_id'),
  ('deposito_cobro', 'public.deposito_cobro'::regclass, 'id', true, 'colportor_id');

-- colportor_id decide qué filas ve el usuario: se descarta del payload (la RLS ya impide escribirlo a nombre
-- de otro, pero así un cliente no cree que se aplicó).
update sync.entidad
   set columnas_servidor = columnas_servidor || array['colportor_id']
 where nombre in ('deposito', 'deposito_cobro');
