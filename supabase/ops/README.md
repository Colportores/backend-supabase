# Operaciones de datos de un solo ambiente

SQL que se corre **a mano** contra un proyecto de Supabase concreto. **No son migraciones**: `supabase db push` y CI no los aplican, y no deben llegar a staging ni a producción. Viven en `supabase/` porque `scripts/check-sql-layout.sh` no deja SQL versionado en otro lado, y cada uno tiene su test pgTAP en `supabase/tests/` (CI lo corre contra una base con datos de prueba armados).

## `retirar-demo-argentina.sql` (backend-supabase#216)

Retira del proyecto de **desarrollo** (`ohdsavwpasfpapbyutrv`) los datos de la demo de Libertador San Martín (Argentina) que se sembraron el 28/10. Todo con baja lógica (`deleted_at = now()`, nunca `DELETE`); las bajas suben `sync_version` y los teléfonos las reciben en el próximo pull. Lo de Uruguay no se toca. Antes del 20/11/2026.

### Orden

1. **Mapa primero** (necesita las credenciales del bucket `mapas`; ver `docs/mapas-tiles.md`):
   `node tiles/src/cli.mjs publicar --solo ciudades --quitar ciudad-libertador-san-martin`
   (o el workflow «Mapas»). Saca el paquete del `catalogo.json` y deja el archivo en `retirados` con 7 días de gracia; pasada la gracia el publicador lo borra.
2. **Vista previa de los datos**: pegar `retirar-demo-argentina.sql` entero en el SQL Editor de Studio del proyecto de desarrollo y correrlo tal cual. Devuelve el conteo por tabla (primer renglón: `VISTA PREVIA`) y no cambia nada. Revisar que las cifras coinciden con el issue (1 país, 1 ciudad, 1 campaña, 3 zonas, 9 productos, 2 colecciones, 21 ubicaciones, etc.). Si el script se frena con «Retiro frenado», la demo y el dominio comparten filas: no se fuerza, se decide a mano.
3. **Aplicar**: descomentar la línea `select set_config('retiro.aplicar', 'si', true);` del principio y correrlo de nuevo. Primer renglón del resultado: `APLICADO`. Es un solo `DO`: o aplica todo o no aplica nada. Se puede correr otra vez (da todo en cero).
4. **Comprobar** (los criterios de aceptación de #216 ya los verifica el script al final; esto es lo que no puede ver):
   - El renglón `auth.users (login bloqueado)` tiene 1 (`banned_until` de colportor2.demo en 2999). En una base sin esa columna da 0.
   - `colportor.demo` y `coordinador.demo` entran.
   - `catalogo.json` del bucket `mapas` ya no nombra `ciudad-libertador-san-martin`.

### Qué retira y cómo lo encuentra

- **Por estructura, desde el país**: todo país que no sea `UY` → sus ciudades → las campañas que cuelgan de ellas → zonas, inscripciones (con su historial de zonas y cuentas de alquiler), ubicaciones, espacios, personas del espacio, y desde ahí las visitas, ventas (con renglones), entregas, cobranzas y agenda.
- **Por colportor2.demo**: sus jornadas y depósitos (con los cobros que incluyen), su usuario, su rol y su login de Auth.
- **Por id**: lo único que no cuelga de nada geográfico, el catálogo de la demo (`dede0000-0000-7000-8005-…01..09` productos, `…8006-…01..02` colecciones, `…801e-…01..03` carreras) y, de ahí, sus precios, componentes, metas de beca, pedidos, renglones, movimientos de stock y stock.
- **La cuenta de saldo** (`cuenta_colportor`) de colportor2.demo. La de colportor.demo **no se toca**: el usuario se queda y `mover_deuda_casa_editora()` no reactiva una cuenta dada de baja (la deuda nueva se perdería en una fila oculta). Si su saldo quedó con cifras de la demo de Argentina, se corrige a mano.
- No se borra nada de verdad, tampoco las cuentas de Auth.

### Qué NO hace

- No toca Montevideo. Si hace falta volver a armar la demo de Uruguay: reactivar la inscripción del colportor demo con `inscribir_colportor()` (no con `UPDATE`) y devolver el `coordinador_id` de la campaña de Montevideo al coordinador demo.
- No publica ni retira mapas (paso 1).
- No fuerza un depósito ya validado: la regla `DP001` lo impide y el script se frena, que es lo correcto.
