-- ============================================================================
-- 0070 · Código del editor en el producto y días de antigüedad de los precios como parámetro global
--      (backend-supabase#137, HU-CAT-006; decisiones de Cristian del 23/10)
--
-- Caso de uso
--   · Ana busca un libro por su código en Precios (vista 26).
--   · Ana lleva 16 días sin señal: ve el aviso fuerte de precios viejos y sigue vendiendo. Los 15 días
--     los cambia Administración.
--
-- Decisiones de Cristian (23/10, front-colportores-mobile#157):
--   · «Código libro»: «Sí, el código del editor». Dato OPCIONAL nuevo en el producto, que carga
--     Administración (guía de carga manual mientras no haya panel). Se busca por nombre o código; sin
--     código se encuentra por nombre.
--   · «Precio viejo»: «Aviso fuerte a los N días»: a los N días desde que la colportora bajó los precios
--     el aviso se pone fuerte y le pide conectarse, pero la deja vender. Los N (15 por defecto) son un
--     parámetro GLOBAL que cambia Administración, y cada cambio queda registrado (quién, cuándo, valor
--     anterior y nuevo).
--
-- ## Qué cambia (solo suma; no se toca ni se borra ninguna fila)
--
--   · `producto.codigo_editor` text, OPCIONAL (null = sin código). Sin otra regla de formato que «sin
--     espacios ni saltos de línea al borde» y 50 caracteres como tope: el código lo asigna la casa
--     editora y no se sabe si lleva letras, guiones o ceros a la izquierda, así que es texto y no
--     número. No es único: dos ediciones del mismo título pueden compartirlo y el teléfono lo busca
--     junto con el nombre. Baja por el pull sin tocar nada más: la entidad `producto` serializa todas
--     las columnas de la tabla (`sync.expresion_json`). Lo escribe el ADMIN, como el resto del producto
--     (política `producto_update_admin`, 0001 §10.1).
--   · Tabla `public.parametro_global`: parámetros de toda la aplicación que cambia Administración.
--     Una fila por parámetro (`clave` única entre las vivas) con un valor ENTERO. Hoy una sola clave,
--     `dias_antiguedad_precios`, con su fila sembrada en 15 por esta misma migración (es un valor de
--     referencia y no un seed de negocio: sin la fila el teléfono no sabría cuándo avisar). El CHECK
--     limita las claves conocidas y el rango de cada una (1 día o más, sin tope: decisión P2 de #137, 25/10): un parámetro nuevo ensancha
--     el CHECK en su propia migración. Forma elegida: una tabla genérica clave-valor y no una columna
--     de `campania` ni de `producto`, porque el valor es de toda la aplicación y porque los próximos
--     parámetros de Administración tienen el mismo lugar donde vivir.
--   · Entra a `sync.entidad` como entidad de SOLO BAJADA (`permite_push = false`), sin filtro por dueño
--     ni por campaña: el valor es el mismo para todos y lo ve todo usuario autenticado (no lleva datos
--     de personas ni de clientes: ADR-003, ADR-004). Así baja con el pull del catálogo y el teléfono
--     calcula el aviso sin conexión. No va a Realtime: no es un cambio urgente.
--
-- ## Permisos
--
--   · LEE todo usuario autenticado (incluidas las bajas lógicas: la app necesita el tombstone).
--   · ESCRIBE solo el servidor (`service_role`) y el SQL Editor de Studio (guía de carga manual § 10).
--     NINGÚN cliente con JWT escribe: ni siquiera el ADMIN, hasta que cada cambio quede registrado en
--     `audit_log` (backend-supabase#136, todavía sin implementar). La HU pide «cada cambio queda
--     registrado: quién, cuándo, valor anterior y nuevo»; con una política de escritura para el ADMIN
--     antes de que exista la auditoría el cambio quedaría sin registro. Cuando `audit_log` exista, el
--     trigger que la escribe y la escritura del ADMIN (RPC) llegan juntos en la migración que lo cierre:
--     queda como pendiente de este issue (criterio «Cada cambio del parámetro queda en audit_log»).
--
-- ## Lo que esta migración NO hace (y por qué)
--
--   · El registro en `audit_log` (depende de #136, ver arriba).
--   · El aviso, su texto y el contador desde que bajó los precios: son del teléfono
--     (front-colportores-mobile#421; el momento de la última bajada de precios es del dispositivo).
--   · Una pantalla de Administración: hasta entonces, guía de carga manual (§ 5 el código, § 10 los días).
--
-- ## Los datos
--
-- Columna nueva en null y tabla nueva con una sola fila: no hay `update` ni `delete` sobre nada que
-- exista. Las filas de `producto` quedan idénticas (ni `sync_version` ni `xmin_w` cambian: el
-- `add column` sin default no reescribe filas).
--
-- ## Para otros repos
--
--   · front-colportores-mobile (#421 y motor de sync #157, #178): `producto.codigo_editor` (nullable) y la
--     entidad nueva `parametro_global` (pull; filas `{id, clave, valor, …}`; la clave
--     `dias_antiguedad_precios` es el N del aviso fuerte; sin la fila, 15). Tabla local de solo lectura.
--   · docs-organizacion: `esquema-datos.md` (la columna y la tabla), HU-CAT-006 y HU-CAT-007 (la entidad
--     entra al pull con el catálogo), `contrato-sync-engine.md` §2 (entidad nueva `parametro_global`, pull,
--     sin filtro) y la guía de carga manual.
--
-- Forward-only: esta migración no se edita una vez aplicada.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. producto.codigo_editor
-- ----------------------------------------------------------------------------

alter table public.producto
  add column codigo_editor text;

-- `\S(.*\S)?` y no btrim(): btrim solo saca espacios, no saltos de línea ni tabuladores del borde.
alter table public.producto
  add constraint producto_codigo_editor_check
  check (codigo_editor is null
         or (codigo_editor ~ '^\S(.*\S)?$' and char_length(codigo_editor) <= 50));

comment on column public.producto.codigo_editor is
  'Código del editor (0070, decisión de Cristian del 23/10): lo asigna la casa editora, es opcional y '
  'no es único. El colportor busca el libro por nombre o por este código; sin código se encuentra por '
  'nombre. Texto de 1 a 50 caracteres, sin espacios ni saltos de línea al borde. Lo carga '
  'Administración (guía de carga manual § 5).';

-- ----------------------------------------------------------------------------
-- 2. La tabla de parámetros globales
-- ----------------------------------------------------------------------------

create table public.parametro_global (
  id            uuid primary key default public.uuid_generate_v7(),
  clave         text not null,
  valor         integer not null,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  created_by    uuid default auth.uid() references public.usuario(id) on delete set null,
  deleted_at    timestamptz,
  sync_version  bigint not null default 0,
  xmin_w        xid8 not null default pg_current_xact_id(),
  -- Las claves conocidas y el rango de cada una. Un parámetro nuevo ensancha este CHECK.
  constraint parametro_global_clave_valor_check
    check (clave = 'dias_antiguedad_precios' and valor >= 1)
);

comment on table public.parametro_global is
  'Parámetros de toda la aplicación que cambia Administración (0070, decisión de Cristian del 23/10, '
  'HU-CAT-006). Una fila por clave, valor entero. Hoy: dias_antiguedad_precios (15 por defecto), los días '
  'desde que el colportor bajó los precios a partir de los cuales el aviso se pone fuerte y le pide '
  'conectarse (la deja vender). Baja por el pull; lo lee todo usuario autenticado; lo escribe solo el '
  'servidor y cada cambio queda en audit_log (0110, backend-supabase#152).';
comment on column public.parametro_global.clave is
  'Nombre del parámetro. Hoy solo dias_antiguedad_precios.';
comment on column public.parametro_global.valor is
  'Valor entero. Para dias_antiguedad_precios: días, 1 o más (sin tope).';
comment on column public.parametro_global.created_by is
  'Quién lo creó, si entró por la API; null si lo creó el servidor o el SQL Editor.';

-- Una sola fila viva por clave: «el valor del parámetro» tiene que ser una. Una baja lógica no cuenta.
create unique index parametro_global_clave_viva_idx
  on public.parametro_global (clave) where deleted_at is null;

-- El cursor del delta (0002 §14).
create index parametro_global_delta_idx on public.parametro_global (xmin_w, id);

create trigger parametro_global_auditoria_insert before insert on public.parametro_global
  for each row execute function public.tg_auditoria_insert();
create trigger parametro_global_auditoria_update before update on public.parametro_global
  for each row execute function public.tg_auditoria_update();

-- ----------------------------------------------------------------------------
-- 3. RLS y privilegios: lee todo autenticado; no escribe ningún cliente
-- ----------------------------------------------------------------------------

alter table public.parametro_global enable row level security;

-- Incluye las bajas lógicas: la app necesita el tombstone para borrar su réplica.
create policy parametro_global_select_autenticado on public.parametro_global
  for select to authenticated using (true);

-- Sin política de INSERT, UPDATE ni DELETE para authenticated (ver «Permisos»): hasta que exista
-- audit_log, el único que lo cambia es el servidor.
revoke all on public.parametro_global from anon, authenticated;
grant select on public.parametro_global to authenticated;
grant all on public.parametro_global to service_role;

-- ----------------------------------------------------------------------------
-- 4. El valor de referencia y el pull
-- ----------------------------------------------------------------------------

insert into public.parametro_global (clave, valor) values ('dias_antiguedad_precios', 15);

-- Solo bajada, sin dueño ni campañas: el valor es el mismo para todos.
insert into sync.entidad (nombre, tabla, columna_pk, permite_push) values
  ('parametro_global', 'public.parametro_global'::regclass, 'id', false);
