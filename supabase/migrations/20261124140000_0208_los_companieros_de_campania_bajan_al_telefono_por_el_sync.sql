-- ============================================================================
-- 0208 · Los compañeros de campaña bajan al teléfono por el sync
--        (backend-supabase#313, casilla «Compañeros de campaña en el teléfono»; decisión de Cristian del 24/11, «Nombres camp.»:
--        «Los de su campaña (la recomendada): bajan con la sincronización»:
--        https://github.com/Colportores/front-colportores-mobile/issues/512#issuecomment-7141968242)
--
-- ## El caso
--
-- Juan toca «Elegir colportor» (40A·02) para pedirle libros a Ana. El teléfono tiene que mostrarle a Ana Pereira, Bruno Techera y
-- Valentina Silva, los colportores de su campaña, con el nombre y la ciudad. Y en la lista de transferencias (40B·01), «LE PEDISTE
-- A ANA PEREIRA». Hasta hoy el teléfono no tenía de dónde sacar esos nombres: la RLS de `usuario` y de `campania_colportor` es
-- «propio o personal de la coordinación», y las transferencias bajan con ids. Para el teléfono solo bajaban los coordinadores
-- (`campania_coordinador`, 0178).
--
-- ## Qué hace
--
--   1. Tabla nueva **`campania_companiero`**: una fila por (campaña, colportor inscripto) con **solo** `usuario_id`, `nombre`,
--      `apellido` y `ciudad_id` (la ciudad de la zona que tiene hoy en esa campaña; sin zona, null). Nunca lleva correo, teléfono,
--      cédula, stock ni nada más del perfil: la tabla no tiene esas columnas. Es una copia que mantiene el servidor (el cliente no
--      la escribe), como `campania_coordinador` (0174).
--   2. Tres triggers la mantienen:
--        · una inscripción nueva, un cambio de zona o una baja de `campania_colportor` crean o ajustan la fila (la baja la deja con
--          `deleted_at`, y baja al teléfono como baja: el compañero ya no está en la campaña; la vuelta lo reactiva);
--        · un cambio de nombre o apellido de la persona refresca sus copias.
--      Las inscripciones que ya existen pasan a la tabla en esta migración (las dadas de baja, con su baja).
--   3. Entidad de sync **`campania_companiero`** (solo bajada, `sigue_campanias`): cada persona baja las filas de las campañas en
--      las que está inscripta y que no terminaron (`mis_inscripciones_no_terminadas()`), incluida la suya. Si se suma o sale de una
--      campaña, la entidad baja completa (la huella de las campañas, 0013).
--
-- ## Quién lee
--
-- Solo quien tiene hoy una inscripción viva en esa campaña (y la cuenta activa), y cada persona su propia fila. **Ni el ADMIN ni el
-- coordinador** la leen por esta tabla (ya ven a los colportores de sus campañas por las RPC del panel, con otros datos): si la
-- leyeran, el pull de un ADMIN que usa la app bajaría a todos los colportores de todas las campañas. Nadie la escribe con su JWT.
--
-- ## Lo que NO cambia
--
--   · `usuario` y `campania_colportor`: ninguna política ni columna nueva. Quién ve qué de ellas sigue igual.
--   · `campania_coordinador` (los coordinadores) y la lista «¿Quién te acompaña?» de la 0178.
--
-- ## Para otros repos
--
--   · front-colportores-mobile#769: adaptador de «colportores de mi campaña» sobre la entidad `campania_companiero` (solo bajada).
--   · docs-organizacion: el contrato del sync (§2, entidad nueva, solo bajada) y `esquema-datos.md`. El issue de docs va en el
--     cuerpo del PR.
--
-- Forward-only: esta migración no se edita una vez aplicada. Lo prueba supabase/tests/0208_… .
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. La tabla
-- ----------------------------------------------------------------------------

create table public.campania_companiero (
  id            uuid primary key default public.uuid_generate_v7(),
  campania_id   uuid not null references public.campania(id) on delete cascade,
  usuario_id    uuid not null references public.usuario(id) on delete cascade,
  nombre        text not null default '',
  apellido      text not null default '',
  ciudad_id     uuid references public.ciudad(id) on delete set null,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  created_by    uuid default auth.uid() references public.usuario(id) on delete set null,
  deleted_at    timestamptz,
  sync_version  bigint not null default 0,
  xmin_w        xid8 not null default pg_current_xact_id(),
  constraint campania_companiero_campania_usuario_key unique (campania_id, usuario_id)
);

comment on table public.campania_companiero is
  'Los colportores de cada campaña, para que el teléfono muestre con quién se puede pedir una transferencia (0208, '
  'backend-supabase#313, HU-STK-005; decisión de Cristian del 24/11, «Nombres camp.»): una fila por (campaña, inscripto) con '
  'solo nombre, apellido y la ciudad de su zona. Copia que mantiene el servidor desde campania_colportor y usuario; nunca lleva '
  'correo, teléfono, cédula ni stock. Baja al teléfono por el sync (solo bajada, sigue las campañas): la persona lee las de las '
  'campañas en las que está inscripta. La baja de la inscripción deja la fila con deleted_at.';
comment on column public.campania_companiero.ciudad_id is
  'La ciudad de la zona que tiene hoy el colportor en esa campaña (campania_colportor.zona_id → zona → campania_ciudad); null '
  'si no tiene zona o la zona ya no tiene ciudad.';

create index campania_companiero_usuario_idx on public.campania_companiero (usuario_id);
-- El cursor del delta del pull (0002 §14).
create index campania_companiero_delta_idx on public.campania_companiero (xmin_w, id);

create trigger campania_companiero_auditoria_insert before insert on public.campania_companiero
  for each row execute function public.tg_auditoria_insert();
create trigger campania_companiero_auditoria_update before update on public.campania_companiero
  for each row execute function public.tg_auditoria_update();

-- ----------------------------------------------------------------------------
-- 2. Quién la lee: la persona inscripta en esa campaña (y cada una su fila)
-- ----------------------------------------------------------------------------

-- Con cualquier otra campaña da false: no sirve para averiguar quién está en una campaña ajena.
create function public.puedo_ver_a_los_companieros(p_campania_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (select 1 from public.mis_inscripciones_no_terminadas() i where i.campania_id = p_campania_id);
$$;

comment on function public.puedo_ver_a_los_companieros(uuid) is
  'true si la persona autenticada tiene una inscripción viva en esa campaña, que no terminó, con la cuenta activa (0208). La usa '
  'la política de lectura de campania_companiero. Una cuenta sin sesión o sin inscripción en la campaña da false.';

revoke all on function public.puedo_ver_a_los_companieros(uuid) from public, anon, authenticated, service_role;
grant execute on function public.puedo_ver_a_los_companieros(uuid) to authenticated, service_role;

alter table public.campania_companiero enable row level security;

create policy campania_companiero_select on public.campania_companiero
  for select to authenticated
  using (usuario_id = (select auth.uid())
         or (select public.puedo_ver_a_los_companieros(campania_id)));

-- Sin política de escritura y sin el privilegio: la mantienen los triggers de abajo (DEFINER) y el servidor.
revoke all on public.campania_companiero from anon, authenticated;
grant select on public.campania_companiero to authenticated;
grant all on public.campania_companiero to service_role;

-- ----------------------------------------------------------------------------
-- 3. Quien la mantiene
-- ----------------------------------------------------------------------------

-- Crea o ajusta la fila de una inscripción. Solo escribe si algo cambia (cada escritura es una fila nueva en el delta).
create function public.tg_campania_colportor_a_companiero()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_nombre   text;
  v_apellido text;
  v_ciudad   uuid;
begin
  select u.nombre, u.apellido into v_nombre, v_apellido
    from public.usuario u where u.id = new.usuario_id;

  select cc.ciudad_id into v_ciudad
    from public.zona z
    join public.campania_ciudad cc on cc.id = z.campania_ciudad_id and cc.deleted_at is null
   where z.id = new.zona_id
     and z.deleted_at is null;

  insert into public.campania_companiero as c (campania_id, usuario_id, nombre, apellido, ciudad_id, deleted_at)
  values (new.campania_id, new.usuario_id, coalesce(v_nombre, ''), coalesce(v_apellido, ''), v_ciudad, new.deleted_at)
  on conflict (campania_id, usuario_id) do update
    set nombre = excluded.nombre,
        apellido = excluded.apellido,
        ciudad_id = excluded.ciudad_id,
        deleted_at = excluded.deleted_at
    where (c.nombre, c.apellido, c.ciudad_id, c.deleted_at)
          is distinct from (excluded.nombre, excluded.apellido, excluded.ciudad_id, excluded.deleted_at);
  return null;
end;
$$;

comment on function public.tg_campania_colportor_a_companiero() is
  'AFTER INSERT / AFTER UPDATE OF zona_id, deleted_at de campania_colportor (0208): crea o ajusta la fila de campania_companiero '
  'de la inscripción (nombre y apellido del perfil, ciudad de su zona, baja si la inscripción está dada de baja).';

revoke all on function public.tg_campania_colportor_a_companiero() from public, anon, authenticated, service_role;

create trigger campania_colportor_a_companiero
  after insert or update of zona_id, deleted_at on public.campania_colportor
  for each row execute function public.tg_campania_colportor_a_companiero();

-- Si la persona cambia de nombre, sus copias la siguen.
create function public.tg_usuario_nombre_a_campania_companiero()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  update public.campania_companiero c
     set nombre = new.nombre,
         apellido = new.apellido
   where c.usuario_id = new.id
     and (c.nombre is distinct from new.nombre or c.apellido is distinct from new.apellido);
  return null;
end;
$$;

comment on function public.tg_usuario_nombre_a_campania_companiero() is
  'AFTER UPDATE de nombre o apellido en usuario (0208): refresca las copias que guarda campania_companiero.';

revoke all on function public.tg_usuario_nombre_a_campania_companiero() from public, anon, authenticated, service_role;

create trigger usuario_nombre_a_campania_companiero
  after update of nombre, apellido on public.usuario
  for each row
  when (old.nombre is distinct from new.nombre or old.apellido is distinct from new.apellido)
  execute function public.tg_usuario_nombre_a_campania_companiero();

-- Las inscripciones que ya existen (las dadas de baja, con su baja).
insert into public.campania_companiero (campania_id, usuario_id, nombre, apellido, ciudad_id, deleted_at)
select i.campania_id, i.usuario_id, u.nombre, u.apellido,
       (select cc.ciudad_id
          from public.zona z
          join public.campania_ciudad cc on cc.id = z.campania_ciudad_id and cc.deleted_at is null
         where z.id = i.zona_id and z.deleted_at is null),
       i.deleted_at
  from public.campania_colportor i
  join public.usuario u on u.id = i.usuario_id
on conflict (campania_id, usuario_id) do nothing;

-- ----------------------------------------------------------------------------
-- 4. El registro del sync
-- ----------------------------------------------------------------------------

insert into sync.entidad (nombre, tabla, columna_pk, permite_push, sigue_campanias)
values ('campania_companiero', 'public.campania_companiero'::regclass, 'id', false, true);
