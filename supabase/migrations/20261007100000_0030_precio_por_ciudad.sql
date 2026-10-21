-- ============================================================================
-- 0030 · precio_por_zona pasa a llamarse precio_por_ciudad (backend-supabase#71)
--
-- Decisión de Cristian del 06/10, «Nombre tabla»: renombrar a `precio_por_ciudad`
-- (https://github.com/Colportores/backend-supabase/pull/66#issuecomment-6019008376). 0027 (#26) dejó
-- el precio de venta colgando de la campania_ciudad y la tabla con el nombre de cuando colgaba de la
-- zona, «sin decidir»; la decisión dice que el nombre sigue al modelo. 0027 ya está en `develop`, y
-- una migración aplicada no se edita: el renombre va acá.
--
-- ## Qué cambia: solo nombres
--
--   · La tabla: public.precio_por_zona → public.precio_por_ciudad. Es un `alter table … rename`: no
--     recrea nada ni mueve ninguna fila. Conserva sus datos (incluidos sync_version, xmin_w y las
--     fechas), sus columnas, su RLS, sus privilegios, su pertenencia a la publicación
--     `supabase_realtime` (Postgres la sigue por el OID de la tabla) y su entrada en
--     sync.entidad (`tabla` es un regclass, que también sigue al OID).
--   · Todo objeto cuyo nombre arrastraba el viejo, para que el catálogo no mezcle los dos nombres
--     (el error de una restricción de no solapamiento dice el nombre, y la app lo muestra):
--       restricciones   precio_por_zona_pkey, _producto_id_fkey, _coleccion_id_fkey, _created_by_fkey,
--                       _campania_ciudad_id_fkey, _precio_venta_check, _check y _check1 (los dos
--                       checks de tabla), y las dos de no solapamiento (`_producto_sin_solape` y
--                       `_coleccion_sin_solape`); renombrar una restricción renombra su índice
--                       (pkey y las dos de no solapamiento tienen uno);
--       índices         precio_por_zona_producto_idx, _delta_idx y _campania_ciudad_idx;
--       triggers        precio_por_zona_auditoria_insert y _auditoria_update;
--       políticas       precio_por_zona_select, _insert_staff y _update_staff.
--     Las definiciones no cambian: una política sigue diciendo lo que decía 0027 (lee el ADMIN y quien
--     ve la campania_ciudad; escriben el ADMIN y el COORDINADOR de la campaña).
--   · sync.entidad.nombre: 'precio_por_zona' → 'precio_por_ciudad'. Es el nombre con que el teléfono
--     pide la entidad y con que vuelve en `rows` y en el watermark del pull (contrato de sync §2).
--   · Los comentarios de la tabla y de hoy_montevideo() dicen el nombre nuevo.
--
-- No se tocan 0001, 0002, 0003, 0008 ni 0027: dicen el nombre de su época, que es lo que fue.
--
-- ## Lo que esta migración NO hace: el precio general
--
-- Cristian aclaró al decidir: «renombrá a por ciudad, pero son casos muy específicos, la idea es
-- tener un precio general, y en casos específicos sufren modificaciones». Esta tabla pasa a ser la de
-- los precios por ciudad, es decir, las excepciones. Todavía no hay un precio general: todo precio
-- cuelga de una campania_ciudad (NOT NULL) y un libro sin precio en una ciudad no se ofrece
-- (HU-CAT-005, R-CT05). Quién pone el general y para qué alcance (la campaña o todo el país) es una
-- pregunta de dominio para Cristian («Precio gral.»); hasta que conteste no se suma ninguna tabla ni
-- columna. Dónde vive el general lo propone el carril backend en otro issue, cuando llegue la
-- respuesta.
--
-- ## Los datos
--
-- Se preservan todos: no hay `create table`, `insert`, `update` ni `delete` sobre public.precio_por_*.
-- El único UPDATE es el del registro sync.entidad (una fila, el nombre). Las ventas guardan su propio
-- precio (venta_item.precio_unitario) y no apuntan a esta tabla.
--
-- ## Para otros repos
--
--   · front-coordinadores-web (HU-CAT-005, vista 27, front-coordinadores-web#21): la tabla es
--     `precio_por_ciudad` (`/rest/v1/precio_por_ciudad`). Un precio que se pisa falla con 23P01 y el
--     mensaje nombra la restricción: `precio_por_ciudad_producto_sin_solape` o
--     `precio_por_ciudad_coleccion_sin_solape`. Lo demás (campania_ciudad_id, valido_desde por
--     defecto, quién lee y escribe) queda como en 0027.
--   · front-colportores-mobile y motor de sync (HU-CAT-006, front-colportores-mobile#157): la entidad
--     del pull se llama `precio_por_ciudad`, en el pedido (`entidades`), en `rows` y en el
--     watermark. Un teléfono que pida todavía `precio_por_zona` no recibe nada de esa entidad: el
--     servidor ignora una entidad que no conoce (sync.pull), sin fallar; con el nombre nuevo y sin
--     watermark baja todos los precios que ve. Realtime: `table: 'precio_por_ciudad'` (la tabla sigue
--     publicada). Avisar a @BrunoFCapri en front-colportores-mobile#178: cambia el nombre de la
--     entidad del pull.
--   · docs-organizacion: contrato de sync (§2, la fila de la entidad), esquema-datos.md (nombre de la
--     tabla ya decidido) y HU-CAT-005 y 006.
--
-- Forward-only: esta migración no se edita una vez aplicada.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. La tabla
-- ----------------------------------------------------------------------------

alter table public.precio_por_zona rename to precio_por_ciudad;

-- ----------------------------------------------------------------------------
-- 2. Restricciones (con ellas, el índice que respalda a la clave primaria y a las dos de no solapamiento)
-- ----------------------------------------------------------------------------

alter table public.precio_por_ciudad
  rename constraint precio_por_zona_pkey to precio_por_ciudad_pkey;
alter table public.precio_por_ciudad
  rename constraint precio_por_zona_producto_id_fkey to precio_por_ciudad_producto_id_fkey;
alter table public.precio_por_ciudad
  rename constraint precio_por_zona_coleccion_id_fkey to precio_por_ciudad_coleccion_id_fkey;
alter table public.precio_por_ciudad
  rename constraint precio_por_zona_created_by_fkey to precio_por_ciudad_created_by_fkey;
alter table public.precio_por_ciudad
  rename constraint precio_por_zona_campania_ciudad_id_fkey to precio_por_ciudad_campania_ciudad_id_fkey;
alter table public.precio_por_ciudad
  rename constraint precio_por_zona_precio_venta_check to precio_por_ciudad_precio_venta_check;
alter table public.precio_por_ciudad
  rename constraint precio_por_zona_check to precio_por_ciudad_check;
alter table public.precio_por_ciudad
  rename constraint precio_por_zona_check1 to precio_por_ciudad_check1;
alter table public.precio_por_ciudad
  rename constraint precio_por_zona_producto_sin_solape to precio_por_ciudad_producto_sin_solape;
alter table public.precio_por_ciudad
  rename constraint precio_por_zona_coleccion_sin_solape to precio_por_ciudad_coleccion_sin_solape;

-- ----------------------------------------------------------------------------
-- 3. Índices sueltos
-- ----------------------------------------------------------------------------

alter index public.precio_por_zona_producto_idx rename to precio_por_ciudad_producto_idx;
alter index public.precio_por_zona_delta_idx rename to precio_por_ciudad_delta_idx;
alter index public.precio_por_zona_campania_ciudad_idx rename to precio_por_ciudad_campania_ciudad_idx;

-- ----------------------------------------------------------------------------
-- 4. Triggers y políticas
-- ----------------------------------------------------------------------------

alter trigger precio_por_zona_auditoria_insert on public.precio_por_ciudad
  rename to precio_por_ciudad_auditoria_insert;
alter trigger precio_por_zona_auditoria_update on public.precio_por_ciudad
  rename to precio_por_ciudad_auditoria_update;

alter policy precio_por_zona_select on public.precio_por_ciudad
  rename to precio_por_ciudad_select;
alter policy precio_por_zona_insert_staff on public.precio_por_ciudad
  rename to precio_por_ciudad_insert_staff;
alter policy precio_por_zona_update_staff on public.precio_por_ciudad
  rename to precio_por_ciudad_update_staff;

-- ----------------------------------------------------------------------------
-- 5. El registro de sync: el nombre con que el teléfono pide la entidad
-- ----------------------------------------------------------------------------

update sync.entidad set nombre = 'precio_por_ciudad' where nombre = 'precio_por_zona';

-- ----------------------------------------------------------------------------
-- 6. Comentarios
-- ----------------------------------------------------------------------------

comment on table public.precio_por_ciudad is
  'Precio de venta de un producto o una colección en una ciudad de una campaña (campania_ciudad_id): '
  'los precios por ciudad, que son las excepciones (0027, decisión de Cristian del 29/09; el nombre, '
  '0030, decisión del 06/10; antes se llamaba precio_por_zona). Todavía no hay un precio general: '
  'espera una respuesta de Cristian. Un solo precio vigente a la vez por producto o colección en '
  'cada campania_ciudad. Un precio nuevo vale para las ventas siguientes: venta_item guarda el suyo.';

comment on function public.hoy_montevideo(timestamptz) is
  'El día de p_ahora (por defecto, ahora) en America/Montevideo, sin depender de la zona horaria '
  'de la sesión. Única definición de «hoy» para la vigencia de una campaña (0024) y para el '
  'valido_desde por defecto de precio_por_ciudad (0027, que la evalúa con quien inserta: por eso la '
  'ejecuta authenticated). Pura.';
