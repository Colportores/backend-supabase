-- ============================================================================
-- 0207 · Las preferencias de avisos viajan por el sync: bajan con el pull y suben como trabajo
--        (backend-supabase#313, casilla «Preferencias de avisos sin señal»; decisión de Cristian del 24/11, «Avisos s/red»:
--        https://github.com/Colportores/front-colportores-mobile/issues/516#issuecomment-7089470249)
--
-- ## El caso
--
-- Diego, sin señal en la calle, abre Configuración › Notificaciones y apaga «Tickets» o cambia la hora del aviso de Cuotas.
-- Hasta hoy el cambio pedía conexión (`guardar_mis_preferencias_de_avisos`, 0166) y, sin ella, el interruptor volvía a como
-- estaba. Cristian decidió que se puede cambiar sin señal: el cambio queda en el teléfono y sube después con la sincronización.
-- Y si Diego tiene dos teléfonos, vale el último cambio.
--
-- ## Qué hace
--
--   1. Tabla nueva `preferencia_de_avisos`: **una fila por persona** (su `id` es el de la persona) con `notif_preferences`
--      (el mismo objeto jsonb de `usuario.notif_preferences`, con las mismas reglas de forma: objeto de hasta 4096 caracteres,
--      `hora_cuota` y `hora_agenda` en `HH:MM`; el resto de las claves, como los interruptores booleanos, es de la app). Las
--      reglas son las del CHECK de la 0166, y un cambio que no las cumple es 23514: el push lo devuelve `invalid` sin tumbar
--      el lote, como siempre.
--   2. Entidad de sync **`preferencia_de_avisos`** (bidireccional, cada persona la suya): baja con el pull y sube con el push
--      como cualquier fila (insert/update con `sync_version`). Si hay dos teléfonos rige la regla de siempre del motor
--      (contrato §5, último cambio gana): el segundo en subir recibe `conflict` con la fila del servidor y la resuelve.
--   3. **Una sola fuente para el servidor**: el trabajo que manda los avisos (0166) sigue leyendo `usuario.notif_preferences`.
--      Dos triggers mantienen las dos copias iguales, en las dos direcciones, y cada uno solo escribe si el valor cambia (por
--      eso no se persiguen): lo que el teléfono sube llega a `usuario.notif_preferences`; y lo que se guarda en `usuario` (la RPC
--      `guardar_mis_preferencias_de_avisos`, que desde esta migración escribe en la tabla nueva, o el servidor) llega a la fila
--      de la tabla y baja a los teléfonos.
--   4. **Cada persona tiene su fila desde que existe**: se crea con la persona (trigger al alta del perfil) y, para las que ya
--      existen, en esta migración (con lo que tengan en `usuario.notif_preferences`: ninguna se pierde). Así un teléfono
--      siempre *actualiza* una fila que bajó, y dos teléfonos que cambian algo sin haberse visto chocan como `conflict` en
--      lugar de que el segundo `insert` se descarte en silencio.
--
-- ## Lo que NO cambia
--
--   · `guardar_mis_preferencias_de_avisos(jsonb)`: misma firma, mismos permisos y mismos errores (42501 sin sesión; 23514 forma
--     inválida); `null` vuelve a los valores por defecto. El panel y la app con conexión la pueden seguir llamando.
--   · `usuario.notif_preferences` no se escribe por PATCH (0166): el trigger que descarta ese cambio sigue.
--   · La hora de los avisos del servidor (cuotas y agenda) sigue saliendo de `usuario.notif_preferences`.
--   · Una persona no lee ni escribe la fila de otra (RLS por `id`), y la fila no se da de baja: un `delete` del push no la toca.
--
-- ## Para otros repos
--
--   · front-colportores-mobile: baja y sube la entidad `preferencia_de_avisos`; sin señal el cambio queda en el teléfono (sale
--     de «Necesitás conexión para guardar el cambio»).
--   · docs-organizacion: el contrato del sync (§2, entidad nueva) y `esquema-datos.md`. El issue de docs va en el cuerpo del PR.
--
-- Forward-only: esta migración no se edita una vez aplicada. Lo prueba supabase/tests/0207_… .
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. La tabla
-- ----------------------------------------------------------------------------

create table public.preferencia_de_avisos (
  id                uuid primary key references public.usuario(id) on delete cascade,
  notif_preferences jsonb,
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),
  created_by        uuid default auth.uid() references public.usuario(id) on delete set null,
  deleted_at        timestamptz,
  sync_version      bigint not null default 0,
  xmin_w            xid8 not null default pg_current_xact_id(),
  constraint preferencia_de_avisos_forma
    check (notif_preferences is null
           or (jsonb_typeof(notif_preferences) = 'object'
               and length(notif_preferences::text) <= 4096
               and ((notif_preferences -> 'hora_cuota') is null
                    or (jsonb_typeof(notif_preferences -> 'hora_cuota') = 'string'
                        and (notif_preferences ->> 'hora_cuota') ~ '^([01][0-9]|2[0-3]):[0-5][0-9]$'))
               and ((notif_preferences -> 'hora_agenda') is null
                    or (jsonb_typeof(notif_preferences -> 'hora_agenda') = 'string'
                        and (notif_preferences ->> 'hora_agenda') ~ '^([01][0-9]|2[0-3]):[0-5][0-9]$'))))
);

comment on table public.preferencia_de_avisos is
  'Las preferencias de avisos de cada persona (0207, backend-supabase#313, HU-NOT-004): una fila por persona, con el mismo '
  'objeto que usuario.notif_preferences. Viaja por el sync en las dos direcciones (baja con el pull y sube con el push), así que '
  'se cambian sin señal; si hay dos teléfonos rige el último cambio del motor. Dos triggers la mantienen igual a '
  'usuario.notif_preferences, que es lo que lee el servidor para mandar los avisos. Sin datos personales.';
comment on column public.preferencia_de_avisos.id is
  'El id de la persona (public.usuario.id): una fila por persona. Lo manda el teléfono en el alta, pero la fila ya existe '
  '(se crea con la persona), así que lo normal es un update.';
comment on column public.preferencia_de_avisos.notif_preferences is
  'Un objeto json sin datos personales, de hasta 4096 caracteres. El servidor lee hora_cuota y hora_agenda ("HH:MM", hora '
  'de Montevideo; por defecto 09:00 y 20:00); el resto de las claves es de la app. null = todo por defecto.';

-- El cursor del delta que exige el pull (0002 §14): la fila de la persona, ordenada por xmin_w.
create index preferencia_de_avisos_delta_idx on public.preferencia_de_avisos (xmin_w, id);

create trigger preferencia_de_avisos_auditoria_insert before insert on public.preferencia_de_avisos
  for each row execute function public.tg_auditoria_insert();
create trigger preferencia_de_avisos_auditoria_update before update on public.preferencia_de_avisos
  for each row execute function public.tg_auditoria_update();

-- Una fila de preferencias no se da de baja: el `delete` del push (o un update de deleted_at) no la toca.
create function public.tg_preferencia_de_avisos_no_se_da_de_baja()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.deleted_at is not null and current_user in ('authenticated', 'anon') then
    new.deleted_at := null;
  end if;
  return new;
end;
$$;

comment on function public.tg_preferencia_de_avisos_no_se_da_de_baja() is
  'BEFORE INSERT/UPDATE de preferencia_de_avisos: la baja lógica de authenticated se descarta (0207); la fila vive con la persona.';

revoke all on function public.tg_preferencia_de_avisos_no_se_da_de_baja() from public, anon, authenticated, service_role;

create trigger preferencia_de_avisos_no_se_da_de_baja
  before insert or update of deleted_at on public.preferencia_de_avisos
  for each row execute function public.tg_preferencia_de_avisos_no_se_da_de_baja();

-- ----------------------------------------------------------------------------
-- 2. RLS: cada persona su fila
-- ----------------------------------------------------------------------------

alter table public.preferencia_de_avisos enable row level security;

create policy preferencia_de_avisos_select_propia on public.preferencia_de_avisos
  for select to authenticated
  using (id = (select auth.uid()));

create policy preferencia_de_avisos_insert_propia on public.preferencia_de_avisos
  for insert to authenticated
  with check (id = (select auth.uid()));

create policy preferencia_de_avisos_update_propia on public.preferencia_de_avisos
  for update to authenticated
  using (id = (select auth.uid()))
  with check (id = (select auth.uid()));

-- Sin política de DELETE ni privilegio: la fila vive con la persona.
revoke all on public.preferencia_de_avisos from anon, authenticated;
grant select, insert, update on public.preferencia_de_avisos to authenticated;
grant all on public.preferencia_de_avisos to service_role;

-- ----------------------------------------------------------------------------
-- 3. Las dos copias, iguales en las dos direcciones
-- ----------------------------------------------------------------------------

-- Tabla -> usuario: lo que el teléfono sube (o la RPC guarda) llega a lo que lee el servidor. DEFINER: authenticated no
-- escribe usuario.notif_preferences (0166). Solo escribe si el valor cambia: así el trigger de usuario no la persigue.
create function public.tg_preferencia_de_avisos_a_usuario()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  update public.usuario u
     set notif_preferences = new.notif_preferences
   where u.id = new.id
     and u.deleted_at is null
     and u.notif_preferences is distinct from new.notif_preferences;
  return null;
end;
$$;

comment on function public.tg_preferencia_de_avisos_a_usuario() is
  'AFTER INSERT/UPDATE OF notif_preferences de preferencia_de_avisos: copia el valor a usuario.notif_preferences si cambió (0207).';

revoke all on function public.tg_preferencia_de_avisos_a_usuario() from public, anon, authenticated, service_role;

create trigger preferencia_de_avisos_a_usuario
  after insert or update of notif_preferences on public.preferencia_de_avisos
  for each row execute function public.tg_preferencia_de_avisos_a_usuario();

-- Usuario -> tabla: lo que se guarda en usuario (el servidor, una fixture, la RPC de la 0166 si alguien la reescribe) llega a la
-- fila que baja a los teléfonos. Si la persona no tiene fila, la crea.
create function public.tg_usuario_preferencias_a_la_tabla()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.preferencia_de_avisos as p (id, notif_preferences)
  values (new.id, new.notif_preferences)
  on conflict (id) do update
    set notif_preferences = excluded.notif_preferences
    where p.notif_preferences is distinct from excluded.notif_preferences;
  return null;
end;
$$;

comment on function public.tg_usuario_preferencias_a_la_tabla() is
  'AFTER INSERT / AFTER UPDATE OF notif_preferences de usuario: deja la fila de preferencia_de_avisos de la persona igual a '
  'usuario.notif_preferences, y la crea con la persona (0207).';

revoke all on function public.tg_usuario_preferencias_a_la_tabla() from public, anon, authenticated, service_role;

create trigger usuario_preferencias_a_la_tabla
  after insert or update of notif_preferences on public.usuario
  for each row execute function public.tg_usuario_preferencias_a_la_tabla();

-- Las personas que ya existen tienen su fila, con lo que ya tenían guardado.
insert into public.preferencia_de_avisos (id, notif_preferences)
select u.id, u.notif_preferences
  from public.usuario u
on conflict (id) do nothing;

-- ----------------------------------------------------------------------------
-- 4. La RPC escribe en la tabla (el cambio llega a usuario por el trigger)
-- ----------------------------------------------------------------------------

-- Misma firma, mismos permisos y mismos errores que en la 0166.
create or replace function public.guardar_mis_preferencias_de_avisos(p_preferencias jsonb)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if (select auth.uid()) is null then
    raise exception 'Iniciá sesión para guardar tus preferencias de avisos.' using errcode = '42501';
  end if;

  insert into public.preferencia_de_avisos as p (id, notif_preferences)
  select u.id, p_preferencias
    from public.usuario u
   where u.id = (select auth.uid())
     and u.deleted_at is null
  on conflict (id) do update
    set notif_preferences = excluded.notif_preferences
    where p.notif_preferences is distinct from excluded.notif_preferences;
end;
$$;

comment on function public.guardar_mis_preferencias_de_avisos(jsonb) is
  'Guarda las preferencias de avisos de quien llama (auth.uid()): el objeto ENTERO que arma la pantalla de notificaciones; null '
  'vuelve a los valores por defecto (0166). Desde la 0207 escribe en preferencia_de_avisos (la fila que viaja por el sync) y de ahí '
  'llega a usuario.notif_preferences. Sin sesión: 42501. Forma inválida (no es un objeto, hora_cuota u hora_agenda que no son '
  '"HH:MM", más de 4096 caracteres): 23514.';

-- ----------------------------------------------------------------------------
-- 5. El registro en el motor de sync
-- ----------------------------------------------------------------------------

-- Bidireccional (push + pull), cada persona la suya: `id` es el de la persona, así que es también el dueño (0014).
insert into sync.entidad (nombre, tabla, columna_pk, permite_push, columna_duenio) values
  ('preferencia_de_avisos', 'public.preferencia_de_avisos'::regclass, 'id', true, 'id');
