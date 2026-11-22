-- ============================================================================
-- 0174 · Una campaña puede tener varios coordinadores: la tabla que los junta
--        (backend-supabase#254, casilla «Coord. camp.»; decisión de Cristian del 05/11 en backend-supabase#249:
--        «una campaña puede tener varios coordinadores; tabla nueva que los junta; cambian los permisos y el panel»)
--
-- ## El caso
--
-- Luis y Daniel Ruiz coordinan la campaña de Verano. Hoy la campaña guarda UN solo coordinador
-- (`campania.coordinador_id`) y todo permiso del coordinador (ver las cuentas, validar un depósito, autorizar un pedido,
-- dibujar el mapa, fijar las becas…) compara con esa columna: Daniel no puede nada. Cristian pidió que una campaña tenga
-- varios, que los dos puedan todo lo del coordinador, y que el que hoy figura no se pierda.
--
-- ## Qué hace esta migración (la tabla; los permisos se mudan en la 0175)
--
--   1. `campania_coordinador`: una fila por (campaña, coordinador) con alta y baja lógica. Una baja (`deleted_at`) deja la
--      historia; volver a sumar al mismo coordinador es una fila nueva. Un índice único parcial impide dos vigentes de la
--      misma pareja. Guarda también el nombre y el apellido del coordinador (copia que mantiene un trigger): la lista de
--      «¿Quién te acompaña?» del teléfono baja con la sincronización y no puede leer la tabla de usuarios (0178).
--   2. Los coordinadores que ya existían pasan a la tabla: una fila por cada `campania.coordinador_id` (campañas de baja
--      incluidas), con la fecha de alta de la campaña. No se pierde ninguno.
--   3. `campania.coordinador_id` **se conserva** como «el primer coordinador vigente» (el más antiguo), para lo que todavía
--      la lee (el panel de antes, los reportes). Deja de mandar: ningún permiso la mira (0175). Dos triggers la mantienen
--      de acuerdo con la tabla:
--        · escribir `campania.coordinador_id` (el panel de antes: «asignar coordinador») suma ese coordinador a la tabla y
--          da de baja al anterior, o sea que **reasignar sigue siendo reasignar** (dejarla en null da de baja al que
--          figuraba y la columna vuelve a ser el primero que quede en la tabla);
--        · sumar o dar de baja filas de la tabla recalcula la columna.
--   4. `coordina_la_campania(campania)`: el predicado único «quien llama coordina esta campaña», que reemplaza a
--      `campania.coordinador_id = auth.uid()` en cada política, función y trigger (0175).
--
-- ## Quién escribe
--
-- Solo un ADMIN, como hoy lo hace con la columna (`campania_update_admin`): por la API (insert, y update de `deleted_at`)
-- o con el servidor. La identidad de una fila (campaña y coordinador) no se cambia (`CC001`): se da de baja y se suma
-- otra. Lee la tabla el ADMIN, el propio coordinador y, desde la 0178, quienes ven esa campaña.
--
-- ## Los datos
--
-- Solo se agregan filas (una por campaña con coordinador); `campania.coordinador_id` no cambia de valor y las campañas no
-- se tocan (`sync_version` igual). Lo prueba supabase/tests_migracion/0174_ok. Forward-only.
--
-- ## Para otros repos
--
--   · front-coordinadores-web#144: «Coordinadores» de la campaña lee y escribe `campania_coordinador` (no la columna).
--   · docs-organizacion#172: `esquema-datos.md` (tabla nueva, columna conservada) y el contrato.
--
-- Forward-only: esta migración no se edita una vez aplicada.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. La tabla
-- ----------------------------------------------------------------------------

create table public.campania_coordinador (
  id            uuid primary key default public.uuid_generate_v7(),
  campania_id   uuid not null references public.campania(id) on delete cascade,
  usuario_id    uuid not null references public.usuario(id) on delete cascade,
  nombre        text not null default '',
  apellido      text not null default '',
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  created_by    uuid default auth.uid() references public.usuario(id) on delete set null,
  deleted_at    timestamptz,
  sync_version  bigint not null default 0,
  xmin_w        xid8 not null default pg_current_xact_id()
);

comment on table public.campania_coordinador is
  'Los coordinadores de cada campaña (0174, backend-supabase#254, «Coord. camp.»): una fila por (campaña, coordinador) '
  'con alta y baja lógica. Una campaña puede tener varios y cada uno puede todo lo del coordinador (coordina_la_campania). '
  'La escribe un ADMIN. nombre y apellido son una copia del perfil que mantiene un trigger, para la lista del teléfono. '
  'campania.coordinador_id queda como el primer coordinador vigente, solo de lectura para quien todavía la usa.';
comment on column public.campania_coordinador.nombre is
  'Copia del nombre del coordinador (usuario.nombre): la mantiene un trigger. Para la lista «¿Quién te acompaña?» del '
  'teléfono, que no lee la tabla de usuarios.';
comment on column public.campania_coordinador.apellido is
  'Copia del apellido del coordinador (usuario.apellido): la mantiene un trigger.';

-- Un coordinador vigente por campaña y persona; la baja deja la historia y se puede volver a sumar.
create unique index campania_coordinador_vigente_uidx
  on public.campania_coordinador (campania_id, usuario_id) where deleted_at is null;
-- «¿De qué campañas soy coordinador?»: lo que consulta casi cada permiso.
create index campania_coordinador_usuario_idx
  on public.campania_coordinador (usuario_id, campania_id) where deleted_at is null;
-- El cursor del delta.
create index campania_coordinador_delta_idx on public.campania_coordinador (xmin_w, id);

create trigger campania_coordinador_auditoria_insert
  before insert on public.campania_coordinador
  for each row execute function public.tg_auditoria_insert();
create trigger campania_coordinador_auditoria_update
  before update on public.campania_coordinador
  for each row execute function public.tg_auditoria_update();

-- ----------------------------------------------------------------------------
-- 2. El nombre y la identidad
-- ----------------------------------------------------------------------------

-- La copia del nombre sale del perfil; el cliente no la pone. La identidad de la fila no se cambia.
create function public.tg_campania_coordinador_nombre()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if tg_op = 'UPDATE'
     and (new.campania_id is distinct from old.campania_id or new.usuario_id is distinct from old.usuario_id) then
    raise exception 'A un coordinador no se le cambia la campaña ni la persona. Dalo de baja y sumá a quien corresponda.'
      using errcode = 'CC001';
  end if;

  select u.nombre, u.apellido into new.nombre, new.apellido
    from public.usuario u where u.id = new.usuario_id;
  return new;
end;
$$;

comment on function public.tg_campania_coordinador_nombre() is
  'BEFORE INSERT o UPDATE de campania_coordinador (0174): copia nombre y apellido del perfil (el cliente no los elige) y '
  'rechaza con CC001 cambiar la campaña o la persona de una fila.';

revoke all on function public.tg_campania_coordinador_nombre() from public, anon, authenticated, service_role;

create trigger campania_coordinador_nombre
  before insert or update on public.campania_coordinador
  for each row execute function public.tg_campania_coordinador_nombre();

-- Si la persona cambia de nombre, la copia la sigue (cada fila nueva viaja al teléfono por el delta).
create function public.tg_usuario_nombre_a_campania_coordinador()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  update public.campania_coordinador cc
     set nombre = new.nombre,
         apellido = new.apellido
   where cc.usuario_id = new.id
     and (cc.nombre is distinct from new.nombre or cc.apellido is distinct from new.apellido);
  return null;
end;
$$;

comment on function public.tg_usuario_nombre_a_campania_coordinador() is
  'AFTER UPDATE de nombre o apellido en usuario (0174): refresca la copia que guarda campania_coordinador.';

revoke all on function public.tg_usuario_nombre_a_campania_coordinador() from public, anon, authenticated, service_role;

create trigger usuario_nombre_a_campania_coordinador
  after update of nombre, apellido on public.usuario
  for each row
  when (old.nombre is distinct from new.nombre or old.apellido is distinct from new.apellido)
  execute function public.tg_usuario_nombre_a_campania_coordinador();

-- ----------------------------------------------------------------------------
-- 3. RLS y privilegios: lee el ADMIN y el propio coordinador; escribe solo un ADMIN
-- ----------------------------------------------------------------------------

alter table public.campania_coordinador enable row level security;

revoke all on public.campania_coordinador from anon, authenticated;
grant select, insert, update on public.campania_coordinador to authenticated;
grant all on public.campania_coordinador to service_role;

create policy campania_coordinador_select on public.campania_coordinador
  for select to authenticated
  using ((select public.tiene_rol('ADMIN')) or usuario_id = (select auth.uid()));

create policy campania_coordinador_insert_admin on public.campania_coordinador
  for insert to authenticated
  with check ((select public.tiene_rol('ADMIN')));

create policy campania_coordinador_update_admin on public.campania_coordinador
  for update to authenticated
  using ((select public.tiene_rol('ADMIN')))
  with check ((select public.tiene_rol('ADMIN')));

-- ----------------------------------------------------------------------------
-- 4. El predicado único: «quien llama coordina esta campaña»
-- ----------------------------------------------------------------------------

-- DEFINER: se usa dentro de políticas y funciones, y la tabla tiene su propia RLS. No mira el rol: cada permiso sigue
-- exigiendo tiene_rol('COORDINADOR') o tiene_rol('ADMIN') por su lado, como antes.
create function public.coordina_la_campania(p_campania_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (select 1
                   from public.campania_coordinador cc
                  where cc.campania_id = p_campania_id
                    and cc.usuario_id = auth.uid()
                    and cc.deleted_at is null);
$$;

comment on function public.coordina_la_campania(uuid) is
  'true si quien llama (auth.uid()) es uno de los coordinadores vigentes de la campaña (0174, «Coord. camp.»). Reemplaza '
  'a campania.coordinador_id = auth.uid(): una campaña puede tener varios coordinadores. No mira el rol (cada permiso '
  'exige además tiene_rol(COORDINADOR) o ADMIN, como antes) ni si la campaña está de baja. Interna.';

revoke all on function public.coordina_la_campania(uuid) from public, anon, authenticated, service_role;
grant execute on function public.coordina_la_campania(uuid) to authenticated, service_role;

-- ----------------------------------------------------------------------------
-- 5. Los coordinadores de hoy pasan a la tabla
-- ----------------------------------------------------------------------------

insert into public.campania_coordinador (campania_id, usuario_id, created_at)
select c.id, c.coordinador_id, c.created_at
  from public.campania c
 where c.coordinador_id is not null;

-- ----------------------------------------------------------------------------
-- 6. campania.coordinador_id: el primer coordinador vigente, de acuerdo con la tabla
-- ----------------------------------------------------------------------------

-- (a) Escribir la columna (el panel de antes): suma al nuevo y da de baja al anterior.
create function public.tg_campania_coordinador_desde_la_columna()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  -- Lo que escribe el otro trigger (la columna recalculada desde la tabla) no vuelve a la tabla.
  if current_setting('colportores.coordinador_espejo', true) = 'on' then
    return null;
  end if;

  -- Con un coordinador nuevo en la columna, esa columna manda: mientras se acomoda la tabla, el otro trigger no la
  -- recalcula. Sin él (null), la columna se recalcula desde lo que queda en la tabla.
  if new.coordinador_id is not null then
    perform set_config('colportores.coordinador_columna', 'on', true);
  end if;

  if new.coordinador_id is not null then
    insert into public.campania_coordinador (campania_id, usuario_id, created_at)
    values (new.id, new.coordinador_id, clock_timestamp())
    on conflict (campania_id, usuario_id) where deleted_at is null do nothing;
  end if;

  if tg_op = 'UPDATE' and old.coordinador_id is not null and old.coordinador_id is distinct from new.coordinador_id then
    update public.campania_coordinador cc
       set deleted_at = now()
     where cc.campania_id = new.id and cc.usuario_id = old.coordinador_id and cc.deleted_at is null;
  end if;

  perform set_config('colportores.coordinador_columna', 'off', true);
  return null;
end;
$$;

comment on function public.tg_campania_coordinador_desde_la_columna() is
  'AFTER INSERT o UPDATE de campania.coordinador_id (0174): suma ese coordinador a campania_coordinador y, si cambió, da '
  'de baja al anterior (reasignar sigue siendo reasignar). Ignora lo que escribe el espejo de la tabla a la columna.';

revoke all on function public.tg_campania_coordinador_desde_la_columna() from public, anon, authenticated, service_role;

create trigger campania_coordinador_desde_la_columna
  after insert or update of coordinador_id on public.campania
  for each row execute function public.tg_campania_coordinador_desde_la_columna();

-- (b) Sumar o dar de baja filas de la tabla: la columna pasa a ser el primer coordinador vigente.
create function public.tg_campania_coordinador_a_la_columna()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_campania uuid := coalesce(new.campania_id, old.campania_id);
  v_primero  uuid;
begin
  if current_setting('colportores.coordinador_columna', true) = 'on' then
    return null;
  end if;

  select cc.usuario_id into v_primero
    from public.campania_coordinador cc
   where cc.campania_id = v_campania and cc.deleted_at is null
   order by cc.created_at, cc.id
   limit 1;

  if exists (select 1 from public.campania c
              where c.id = v_campania and c.coordinador_id is distinct from v_primero) then
    perform set_config('colportores.coordinador_espejo', 'on', true);
    update public.campania c set coordinador_id = v_primero where c.id = v_campania;
    perform set_config('colportores.coordinador_espejo', 'off', true);
  end if;
  return null;
end;
$$;

comment on function public.tg_campania_coordinador_a_la_columna() is
  'AFTER INSERT, UPDATE de deleted_at o DELETE en campania_coordinador (0174): deja campania.coordinador_id en el primer '
  'coordinador vigente (el más antiguo) o en null si no queda ninguno. Solo escribe si cambia.';

revoke all on function public.tg_campania_coordinador_a_la_columna() from public, anon, authenticated, service_role;

create trigger campania_coordinador_a_la_columna
  after insert or delete or update of deleted_at on public.campania_coordinador
  for each row execute function public.tg_campania_coordinador_a_la_columna();

comment on column public.campania.coordinador_id is
  'El primer coordinador vigente de la campaña (el más antiguo de campania_coordinador), o null si no tiene ninguno. '
  'Desde la 0174 una campaña puede tener varios y el permiso mira la tabla (coordina_la_campania), no esta columna: se '
  'conserva para quien todavía la lee. Escribirla suma ese coordinador a la tabla y da de baja al anterior.';
