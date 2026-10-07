-- ============================================================================
-- 0032 · Las decisiones sobre los pares de posibles duplicados suben al servidor (backend-supabase#35)
--
-- Decisión 6 de Cristian del 29/09, «Decisiones sobre los pares»
-- (https://github.com/Colportores/front-colportores-mobile/issues/207#issuecomment-5900445953):
-- `ubicacion_par_decidido` se sincroniza por push. Sobrevive a una reinstalación, y R21 (falsos
-- positivos de la regla de posible duplicado, HU-UBI-006) sale de contar los «Conservar ambos»
-- («Son distintos» en la vista 10). Suma una tabla en el backend y su registro en el motor de sync
-- (front-colportores-mobile#178, @BrunoFCapri). Contrato de sync, §2: fila `push`, sin `alsoPull`;
-- esquema-datos.md, «ubicacion_par_decidido».
--
-- ## Qué crea
--
--   · public.ubicacion_par_decidido: lo que un colportor decidió sobre un par de ubicaciones que el
--     scan marcó como posible duplicado. Una fila por colportor y par. Las columnas del teléfono
--     (esquema local v4) son las cuatro de siempre, con el mismo nombre y las mismas restricciones:
--
--       ubicacion_a_id, ubicacion_b_id   el par, ordenado: a < b (el mismo CHECK que la tabla local).
--                                        El orden de un uuid en Postgres es el de sus 16 bytes, que
--                                        es el del texto canónico en minúsculas con el que la app
--                                        ordena el par: el mismo par da el mismo orden de los dos
--                                        lados.
--       decision                         CONSERVAR_AMBOS | IGNORAR («Ignorar» esconde el par 30
--                                        días en el teléfono; «Conservar ambos» lo saca para siempre).
--       decidido_en                      cuándo lo decidió el colportor (la fecha va del teléfono; el
--                                        servidor no la inventa: sin ella el push es inválido).
--
--     Más las columnas de sync que llevan todas las tablas del repo (id, created_at, updated_at,
--     created_by, deleted_at, sync_version, xmin_w). `id` es un uuid como el de toda entidad: el
--     motor identifica cada fila por una columna uuid (`sync.entidad.columna_pk`), y la tabla local
--     tiene hoy como clave el par. Por `sync.push` el `id` TIENE que venir en el payload: sin él, el
--     job vuelve `invalid` con PK_FALTANTE. El default `uuid_generate_v7()` solo vale para un INSERT
--     directo (service_role, pruebas). Qué id manda el teléfono y cómo lo guarda es del contrato con
--     el motor (ver «Para otros repos»).
--     No hay columna `motivo`: ni el esquema local ni esquema-datos.md la tienen.
--
--   · RLS, SIN columna de dueño (ADR-012: la RLS es la autoridad también en el push). El dueño de la
--     decisión es quien la creó: `created_by`, que el servidor fija desde auth.uid() (default) y que
--     tg_auditoria_update no deja cambiar. Es el mismo patrón de espacio_persona (0001, 0003): cada
--     colportor lee y escribe solo las suyas, sin importar su rol, y no hay `colportor_id` que el
--     cliente pueda mandar a nombre de otro (sync.entidad.columnas_servidor ya descarta created_by del
--     payload). Un coordinador o un ADMIN tampoco ve las de otros por la tabla; la métrica va por
--     la función de abajo. Sin DELETE: una baja es un UPDATE de `deleted_at` (tombstone), y la
--     decisión que se pisa o se da de baja queda en la fila, no se borra.
--
--   · Un solo par vivo por colportor (índice único parcial sobre a, b y created_by, donde
--     deleted_at es null): «decidir de nuevo pisa la decisión y la fecha», como en el teléfono. Un
--     segundo alta del mismo par con otro id es un payload inválido (23505), no una fila de más que
--     descuadre la métrica. Los pares dados de baja no estorban.
--
--   · Las dos ubicaciones son FK a public.ubicacion (como toda referencia a una ubicación del
--     repo): una decisión sobre una ubicación que el servidor no conoce se rechaza con 23503. Si esa
--     ubicación es un alta que el servidor no guardó por el choque de dirección única (D1,
--     HU-UBI-006) y viene en el mismo lote, sync.push ya la devuelve `conflict` con
--     ESPERA_ALTA_EN_CONFLICTO (0017, genérico sobre cualquier uuid del payload): el motor la deja en
--     espera y la reintenta cuando se resuelva el par en la vista 10. Nada se borra del teléfono.
--
--   · sync.entidad: ('ubicacion_par_decidido', push, PK `id`, dueño `created_by`), como
--     espacio_persona más el filtro de dueño de 0014. Con la RLS de arriba el pull de la entidad ya
--     baja las decisiones propias y nada más: es lo que devuelve el delta tras reinstalar (fase 3
--     de recover(), contrato §7). `columna_duenio` lo asegura por segunda vez en el propio pull:
--     si algún día la RLS se amplía (por ejemplo para que otro rol lea la métrica por la tabla), al
--     teléfono de ese rol siguen bajando solo sus decisiones. Índice del delta con el dueño primero
--     (created_by, xmin_w, id).
--
--   · public.metrica_r21(): la cuenta de R21. Una fila con las decisiones vivas, cuántas son
--     «Conservar ambos» y cuántas «Ignorar», y la proporción de «Conservar ambos». SOLO el ADMIN la
--     lee (42501 para cualquier otro rol y sin sesión) y solo devuelve números: ninguna ubicación,
--     ningún par ni ningún colportor. SECURITY DEFINER para poder contar las decisiones de todos
--     sin abrirle la tabla a nadie; el permiso es lo primero, como en las lecturas del panel (0007).
--     Cuenta una fila por colportor y par: si dos colportores deciden el mismo par, son dos
--     decisiones (cada uno vio el aviso). Las dadas de baja no cuentan.
--
-- ## Los datos
--
-- Preserva todo: no toca ninguna tabla existente. Crea una tabla nueva (vacía: hasta hoy ningún
-- teléfono la sube), una fila en sync.entidad, índices y una función. No hay UPDATE ni DELETE de
-- datos. El teléfono que ya tiene decisiones locales las sube cuando el motor registre la entidad
-- (el motor las encola recién entonces); lo decidido antes de la subida no se pierde, está en su
-- tabla local.
--
-- ## Para otros repos
--
--   · front-colportores-mobile y motor de sync (front-colportores-mobile#178, @BrunoFCapri):
--     (1) la tabla local v4 tiene como clave el par (a, b) y no tiene `id` ni columnas de auditoría ni
--     `sync_version`; para subirla el motor necesita un `id` uuid por fila en el payload (si no,
--     PK_FALTANTE) y la fila local tiene que poder hacer el round-trip de §8 del contrato: qué id
--     usa el teléfono (uno al azar al decidir, o uno que sale del par) y la migración local que lo
--     agrega son del contrato. Si el id sale del par, tiene que incluir al colportor: dos
--     colportores que deciden el mismo par no pueden compartir id (el insert del segundo daría
--     `duplicate` sin guardar nada). (2) El servidor responde `invalid` 23505 al segundo alta del
--     mismo par con otro id, 23514 si el par llega desordenado o la decisión no es una de las dos, y
--     23503 si una ubicación no existe. (3) La fila viaja entera en el pull: id, par, decision,
--     decidido_en, created_at, updated_at, created_by, deleted_at y sync_version (xmin_w no).
--     Para un mismo colportor y par el pull puede bajar una fila viva y varias dadas de baja con otros
--     ids (baja y alta nueva: el índice parcial lo permite). La clave local (a, b) tiene que
--     colapsarlas sin que la baja de un id viejo borre la decisión viva.
--   · backend-supabase#69 (redirigir B a A): las decisiones sobre B se reapuntan a A («si ya está en
--     el backend»: desde esta migración lo está; la regla entra con #69 y no se hizo acá, que no toca
--     marcar_como_duplicado). Tres cruces para ese issue: (1) el par (A, B) mismo queda (A, A) y
--     viola a < b: se da de baja (deleted_at); (2) si el mismo colportor ya decidió (A, X) y decidió
--     (B, X), el índice único parcial lo impide: dar de baja una de las dos o fundirlas; (3) al
--     reapuntar hay que reordenar el par para que a < b. Los índices por a y por b ya están.
--   · docs-organizacion: esquema-datos.md (la tabla en el cloud, `Cloud: sí (sin PII)`) y la
--     definición de R21 («Son distintos» sobre las decisiones vivas); HU-UBI-006.
--
-- Forward-only: esta migración no se edita una vez aplicada.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. La tabla
-- ----------------------------------------------------------------------------

create table public.ubicacion_par_decidido (
  id              uuid primary key default public.uuid_generate_v7(),
  ubicacion_a_id  uuid not null references public.ubicacion(id),
  ubicacion_b_id  uuid not null references public.ubicacion(id),
  decision        text not null,
  -- Sin default: la fecha de la decisión es la del teléfono (puede subir días después).
  decidido_en     timestamptz not null,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  -- El dueño de la decisión (ver el encabezado): lo fija el servidor desde el JWT.
  created_by      uuid default auth.uid() references public.usuario(id) on delete set null,
  deleted_at      timestamptz,
  sync_version    bigint not null default 0,
  xmin_w          xid8 not null default pg_current_xact_id(),
  constraint ubicacion_par_decidido_decision_valida
    check (decision in ('CONSERVAR_AMBOS', 'IGNORAR')),
  constraint ubicacion_par_decidido_par_ordenado
    check (ubicacion_a_id < ubicacion_b_id)
);

comment on table public.ubicacion_par_decidido is
  'Lo que un colportor decidió sobre un par de posibles duplicados del scan (HU-UBI-006): '
  'CONSERVAR_AMBOS («Son distintos», el par no vuelve) o IGNORAR (lo esconde 30 días en el teléfono). '
  'Solo ids de ubicaciones y la decisión: sin personas. Cada colportor lee y escribe las suyas '
  '(created_by); la métrica R21 sale de public.metrica_r21(), solo ADMIN. Sube por push (0032).';
comment on column public.ubicacion_par_decidido.ubicacion_a_id is
  'La menor de las dos ubicaciones del par (a < b), como en la tabla local.';
comment on column public.ubicacion_par_decidido.decidido_en is
  'Cuándo lo decidió el colportor, según el teléfono. Decidir de nuevo el mismo par pisa la decisión y la fecha.';
comment on column public.ubicacion_par_decidido.created_by is
  'El dueño de la decisión: la RLS compara contra esta columna (no hay colportor_id). Lo fija el servidor.';

-- Un solo par vivo por colportor. Parcial: una decisión dada de baja no estorba a la que la reemplaza.
create unique index ubicacion_par_decidido_par_vivo_uidx
  on public.ubicacion_par_decidido (created_by, ubicacion_a_id, ubicacion_b_id)
  where deleted_at is null;

-- Las FK se indexan (buscar lo que nombra a una ubicación, para backend-supabase#69).
create index ubicacion_par_decidido_ubicacion_a_idx on public.ubicacion_par_decidido (ubicacion_a_id);
create index ubicacion_par_decidido_ubicacion_b_idx on public.ubicacion_par_decidido (ubicacion_b_id);

-- El delta: el predicado de la RLS (created_by) primero, para que entre en el Index Cond (0002 §14).
create index ubicacion_par_decidido_delta_idx
  on public.ubicacion_par_decidido (created_by, xmin_w, id);

create trigger ubicacion_par_decidido_auditoria_insert before insert on public.ubicacion_par_decidido
  for each row execute function public.tg_auditoria_insert();
create trigger ubicacion_par_decidido_auditoria_update before update on public.ubicacion_par_decidido
  for each row execute function public.tg_auditoria_update();

-- ----------------------------------------------------------------------------
-- 2. RLS: cada colportor, lo suyo (sin columna de dueño: created_by)
-- ----------------------------------------------------------------------------

alter table public.ubicacion_par_decidido enable row level security;

create policy ubicacion_par_decidido_select_propio on public.ubicacion_par_decidido
  for select to authenticated
  using (created_by = (select auth.uid()));

create policy ubicacion_par_decidido_insert_propio on public.ubicacion_par_decidido
  for insert to authenticated
  with check (created_by = (select auth.uid()));

-- USING = lo que ve; WITH CHECK = lo que escribe (0021): no se puede pasar una decisión a otro.
create policy ubicacion_par_decidido_update_propio on public.ubicacion_par_decidido
  for update to authenticated
  using (created_by = (select auth.uid()))
  with check (created_by = (select auth.uid()));

-- Sin política de DELETE ni privilegio: una baja es `deleted_at`.
revoke all on public.ubicacion_par_decidido from anon, authenticated;
grant select, insert, update on public.ubicacion_par_decidido to authenticated;
grant all on public.ubicacion_par_decidido to service_role;

-- ----------------------------------------------------------------------------
-- 3. El registro en el motor de sync (contrato §2: push, sin alsoPull)
-- ----------------------------------------------------------------------------

-- Como espacio_persona (0002 §13), sin filtro de alcance por ubicación ni por campaña. La RLS ya deja
-- a cada uno las suyas; columna_duenio (0014) hace que el pull no dependa de eso.
insert into sync.entidad (nombre, tabla, columna_pk, permite_push, columna_duenio) values
  ('ubicacion_par_decidido', 'public.ubicacion_par_decidido'::regclass, 'id', true, 'created_by');

-- ----------------------------------------------------------------------------
-- 4. R21: decisiones y «Conservar ambos», solo para el ADMIN
-- ----------------------------------------------------------------------------

create function public.metrica_r21()
returns table (
  decisiones                  bigint,
  conservar_ambos             bigint,
  ignorar                     bigint,
  proporcion_conservar_ambos  numeric
)
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if auth.uid() is null then
    raise exception 'metrica_r21 requiere un usuario autenticado'
      using errcode = 'insufficient_privilege';
  end if;

  -- El permiso primero. DEFINER salta la RLS de la tabla (que deja a cada uno solo las suyas), así
  -- que esta es la única puerta a la cuenta de todos.
  if not public.tiene_rol('ADMIN') then
    raise exception 'metrica_r21 es solo para el ADMIN'
      using errcode = 'insufficient_privilege';
  end if;

  return query
    select count(*),
           count(*) filter (where d.decision = 'CONSERVAR_AMBOS'),
           count(*) filter (where d.decision = 'IGNORAR'),
           -- Sin decisiones: null, no 0 (no hay nada que medir todavía).
           round(count(*) filter (where d.decision = 'CONSERVAR_AMBOS')::numeric
                 / nullif(count(*), 0), 4)
      from public.ubicacion_par_decidido d
     where d.deleted_at is null;
end;
$$;

comment on function public.metrica_r21() is
  'R21 (falsos positivos de la regla de posible duplicado, HU-UBI-006): una fila con las decisiones '
  'vivas sobre pares, cuántas son CONSERVAR_AMBOS («Son distintos») y cuántas IGNORAR, y la proporción '
  'de CONSERVAR_AMBOS (null si no hay decisiones). Una decisión por colportor y par. Solo ADMIN '
  '(42501 para otro rol o sin sesión); solo números, sin ubicaciones ni personas.';

revoke all on function public.metrica_r21() from public, anon, authenticated;
grant execute on function public.metrica_r21() to authenticated;
