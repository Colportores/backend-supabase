-- ============================================================================
-- 0109 · El catálogo de ciudades y departamentos de Uruguay desde OpenStreetMap, ciudad.origen y el alta a mano
--        (backend-supabase#139, seguimiento de #68; HU-ADM-005, HU-SYNC-010)
--
-- Decisiones de Cristian del 23/10:
--
--   · «Área depto» (https://github.com/Colportores/backend-supabase/pull/125#issuecomment-6371155243): «Lista fija
--     con el publicador», con su nota: «Lista fija, pero todos los departamentos y ciudades de Uruguay que ya se
--     carguen de OSM, así los nombres coinciden, no hay malos typos». Los nombres de ciudades y departamentos salen
--     de esa lista y ya no se escriben a mano; el departamento se elige, nunca se tipea. Sigue siendo un dato de la
--     ciudad (`ciudad.departamento`, 0066), con el nombre de la lista.
--   · «Fuera de OSM» (https://github.com/Colportores/backend-supabase/issues/68#issuecomment-6371724248): «A mano,
--     con el departamento de la lista». Si un pueblo o barrio no está en la lista de OSM, Administración lo agrega
--     escribiendo solo su nombre; el departamento se elige de la lista. Si el nombre se parece a uno que ya está,
--     se avisa sin frenar. Queda marcado como cargado a mano y sin mapa propio hasta tener su área.
--
-- La lista se arma con `node tiles/src/cli.mjs catalogo-uruguay` desde OpenStreetMap (Overpass) y vive en
-- `tiles/datos/uruguay-osm.json` con su fuente, la fecha de los datos y la atribución de OSM (© OpenStreetMap
-- contributors, ODbL 1.0). El publicador de mapas corta con ella el paquete de cada departamento y el de todo Uruguay;
-- la función de abajo (`catalogo_osm_uruguay()`) es la misma lista, copiada con el comando
-- `catalogo-uruguay --funcion-sql`, y un test del publicador (tiles/test/catalogo-en-la-base.test.mjs) falla si
-- las dos difieren.
--
-- ## Qué cambia
--
--   · public.ciudad.origen (text, not null, 'OSM' | 'MANUAL'): de dónde salió la ciudad. Las que ya estaban se
--     cargaron a mano: nacen 'MANUAL' y la carga de abajo marca 'OSM' a las que encuentra en la lista. Una
--     ciudad 'MANUAL' nueva no trae rectángulo, así que no tiene mapa propio (el publicador solo publica las que
--     tienen uno). Baja en el pull con la ciudad (el pull manda todas las columnas de la entidad).
--   · public.catalogo_osm_uruguay() -> jsonb: la lista (país, 19 departamentos con su rectángulo y las ciudades,
--     pueblos y villas con su departamento, su centro y su rectángulo cuando OSM trae el límite). Interna.
--   · public.departamentos_de_uruguay() -> setof text: los nombres de los 19 departamentos, A-Z. Es lo que
--     leen los selectores de departamento (front-coordinadores-web#80): nunca texto libre.
--   · public.cargar_catalogo_ciudades(p_catalogo jsonb default null) -> jsonb: carga la lista en `ciudad` SIN
--     borrar ni duplicar (ver «La carga»). Idempotente: una segunda corrida no cambia nada.
--   · public.agregar_ciudad_a_mano(p_nombre, p_departamento) -> (ciudad_id, parecidas): el alta a mano (ver «El
--     alta a mano»).
--   · public.distancia_de_edicion(a, b): la distancia de Levenshtein, interna, para el aviso de parecido.
--
-- ## La carga (cargar_catalogo_ciudades, y esta migración la corre una vez)
--
--   · Se empareja por NOMBRE NORMALIZADO y DEPARTAMENTO NORMALIZADO (public.normalizar_busqueda(): sin tildes, sin
--     mayúsculas, espacios colapsados). Mirando también las ciudades dadas de baja: una ciudad que Administración dio
--     de baja a propósito no se vuelve a crear.
--   · Las que ya estaban y casan: se marcan origen 'OSM' y toman el nombre del departamento tal como está en la
--     lista (misma ortografía, con tilde: «Paysandú»). Su nombre, su centro y su rectángulo NO se tocan, salvo que no
--     tuvieran rectángulo y el de OSM contenga a su centro: entonces se les carga ese (así Montevideo, que ya tiene
--     el suyo de la 0031, lo conserva).
--   · Las de la lista que no están: se agregan, origen 'OSM'. El centro es el de OSM; el rectángulo, el del límite
--     que trae OSM. Una ciudad sin límite en OSM queda SIN rectángulo (no se inventa uno) y sin mapa de ciudad.
--   · Las que ya estaban y NO casan (el nombre no está en la lista, o está pero con otro departamento, o sin
--     departamento): NO se borran ni se tocan. Se avisan: un NOTICE con las primeras y la lista entera en la
--     respuesta (`sin_pareja`). Quedan 'MANUAL'. Una ciudad vieja sin departamento no casa por definición: se completa
--     con docs/guia-carga-manual.md § 2.
--   · Si la base no tiene el país Uruguay (una base recién creada, sin siembra), no hay dónde colgar las ciudades: no
--     se carga nada y se avisa. Se carga después con `select public.cargar_catalogo_ciudades();` en cuanto exista el
--     país (docs/guia-carga-manual.md § 1 y § 2). Las pruebas de la base parten de cero y arman su propio país, por eso
--     la migración no lo inserta.
--
-- ## El alta a mano (agregar_ciudad_a_mano)
--
-- Lleva SOLO el nombre y el departamento. El departamento tiene que ser uno de los 19 (se compara sin tildes ni
-- mayúsculas, pero se guarda como está en la lista); si no, CD003. El nombre no puede estar en blanco ni pasar de 100
-- caracteres (CD002). Como a la ciudad todavía no se le conoce el área:
--
--   · origen 'MANUAL', sin rectángulo (sin mapa propio hasta tener su área);
--   · el centro es el del departamento elegido (el de su rectángulo en la lista): la columna es obligatoria y no hay
--     otro dato del que partir; se corrige con un UPDATE (docs/guia-carga-manual.md § 2).
--
-- El aviso de parecido NO frena: la función siempre crea la ciudad y devuelve en `parecidas` las que ya estaban y se
-- le parecen (máximo 10), cada una con su `motivo`: 'IGUAL' (mismo nombre en el mismo departamento),
-- 'MISMO_NOMBRE_OTRO_DEPARTAMENTO' (hay dos «San José», es válido) o 'PARECIDO' (el nombre difiere en una letra, o
-- dos si pasa de 8, o uno contiene al otro). Quien la usa tiene que mostrarlas y, si es una repetida, dar de baja la
-- sobrante (`deleted_at`). Mientras no haya panel de Administración se corre desde el SQL Editor
-- (docs/guia-carga-manual.md § 2); solo `service_role` (y el dueño) pueden ejecutarla.
--
-- ## Los datos
--
-- Se preservan todos: `add column` con valor por defecto constante (sin reescribir la tabla) y, en la carga, un UPDATE
-- por fila que casa y que cambia algo (nunca borra) y los INSERT de las que faltan. El UPDATE pasa por el trigger de
-- auditoría: sube `sync_version` y llega a los teléfonos por delta.
--
-- ## Para otros repos
--
--   · front-coordinadores-web#80: «+ Agregar ciudad» y los filtros leen `ciudades_del_catalogo()` (con el
--     departamento) y `departamentos_de_uruguay()`; sin texto libre para el departamento.
--   · front-colportores-mobile: `ciudad` trae `origen` en el pull; la app lo puede ignorar.
--   · docs-organizacion: esquema-datos.md §ciudad, HU-ADM-005, HU-SYNC-010 (issue aparte).
--
-- Forward-only: esta migración no se edita una vez aplicada. Para actualizar la lista se corre
-- `catalogo-uruguay --funcion-sql` y se pega el resultado en una migración nueva junto con
-- `select public.cargar_catalogo_ciudades();`.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. ciudad.origen
-- ----------------------------------------------------------------------------

alter table public.ciudad
  add column origen text not null default 'MANUAL';

alter table public.ciudad
  add constraint ciudad_origen_check check (origen in ('OSM', 'MANUAL'));

comment on column public.ciudad.origen is
  'De dónde salió la ciudad (0109, backend-supabase#139): ''OSM'' = está en el catálogo de Uruguay de OpenStreetMap '
  '(tiles/datos/uruguay-osm.json); ''MANUAL'' = la cargó Administración a mano (docs/guia-carga-manual.md § 2) y '
  'no tiene mapa propio hasta tener su rectángulo. Las que ya estaban nacen ''MANUAL''; cargar_catalogo_ciudades() '
  'marca ''OSM'' las que encuentra en la lista. Baja en el pull con la ciudad.';

-- ----------------------------------------------------------------------------
-- 2. La lista de OpenStreetMap
-- ----------------------------------------------------------------------------

create or replace function public.catalogo_osm_uruguay()
returns jsonb
language sql
immutable
set search_path = ''
as $f$ select $catalogo${
  "version": 1,
  "fuente": {"nombre":"OpenStreetMap","atribucion":"© OpenStreetMap contributors","licencia":"ODbL 1.0","licencia_url":"https://www.openstreetmap.org/copyright","via":"Overpass API (https://overpass-api.de/api/interpreter)","datos_osm_de":"2026-10-26T20:01:50Z","generado_en":"2026-10-26T20:22:06Z"},
  "pais": {"nombre":"Uruguay","iso_code":"UY","osm":"relation/287072","bbox":[-58.494773,-35.782483,-53.075583,-30.085396]},
  "departamentos": [
    {"nombre":"Artigas","iso_3166_2":"UY-AR","osm":"relation/1617618","bbox":[-57.890031,-31.082665,-55.989596,-30.085396]},
    {"nombre":"Canelones","iso_3166_2":"UY-CA","osm":"relation/1625171","bbox":[-56.493956,-34.879642,-55.393216,-34.207024]},
    {"nombre":"Cerro Largo","iso_3166_2":"UY-CL","osm":"relation/1656175","bbox":[-55.35584,-33.029397,-53.182265,-31.651142]},
    {"nombre":"Colonia","iso_3166_2":"UY-CO","osm":"relation/1650769","bbox":[-58.432251,-34.476233,-56.982647,-33.76466]},
    {"nombre":"Durazno","iso_3166_2":"UY-DU","osm":"relation/1646018","bbox":[-57.200321,-33.507299,-55.005739,-32.408958]},
    {"nombre":"Flores","iso_3166_2":"UY-FS","osm":"relation/1645684","bbox":[-57.360867,-33.984787,-56.396481,-33.119016]},
    {"nombre":"Florida","iso_3166_2":"UY-FD","osm":"relation/1635164","bbox":[-56.536345,-34.426433,-55.098206,-33.10169]},
    {"nombre":"Lavalleja","iso_3166_2":"UY-LA","osm":"relation/1635124","bbox":[-55.624629,-34.635569,-54.128967,-33.318793]},
    {"nombre":"Maldonado","iso_3166_2":"UY-MA","osm":"relation/1635117","bbox":[-55.484339,-35.031576,-54.463979,-33.928748]},
    {"nombre":"Montevideo","iso_3166_2":"UY-MO","osm":"relation/1634207","bbox":[-56.4314,-34.938056,-56.017202,-34.701853]},
    {"nombre":"Paysandú","iso_3166_2":"UY-PA","osm":"relation/1662387","bbox":[-58.206822,-32.595618,-56.238432,-31.452405]},
    {"nombre":"Río Negro","iso_3166_2":"UY-RN","osm":"relation/1662476","bbox":[-58.441346,-33.440866,-56.546619,-32.342564]},
    {"nombre":"Rivera","iso_3166_2":"UY-RV","osm":"relation/1627812","bbox":[-56.185017,-32.110373,-54.451622,-30.832926]},
    {"nombre":"Rocha","iso_3166_2":"UY-RO","osm":"relation/1653142","bbox":[-54.57912,-34.801803,-53.369418,-33.150826]},
    {"nombre":"Salto","iso_3166_2":"UY-SA","osm":"relation/1614733","bbox":[-58.083357,-31.871202,-56.009807,-30.741539]},
    {"nombre":"San José","iso_3166_2":"UY-SJ","osm":"relation/1635189","bbox":[-57.152613,-34.784082,-56.341547,-33.832148]},
    {"nombre":"Soriano","iso_3166_2":"UY-SO","osm":"relation/1646600","bbox":[-58.494773,-33.955603,-57.089342,-33.000118]},
    {"nombre":"Tacuarembó","iso_3166_2":"UY-TA","osm":"relation/1662265","bbox":[-56.683674,-32.866562,-54.667501,-31.230709]},
    {"nombre":"Treinta y Tres","iso_3166_2":"UY-TT","osm":"relation/1640982","bbox":[-55.158854,-33.460251,-53.29292,-32.69709]}
  ],
  "ciudades": [
    {"nombre":"Artigas","departamento":"Artigas","tipo":"city","osm":"node/416470120","lat":-30.398414,"lon":-56.463808,"bbox":[-56.498424,-30.430438,-56.44475,-30.385254]},
    {"nombre":"Baltasar Brum","departamento":"Artigas","tipo":"town","osm":"node/1365723914","lat":-30.72015,"lon":-57.330794,"bbox":[-57.339603,-30.730503,-57.318076,-30.707213]},
    {"nombre":"Bella Unión","departamento":"Artigas","tipo":"city","osm":"node/415689707","lat":-30.26123,"lon":-57.6059,"bbox":[-57.615959,-30.277996,-57.582948,-30.241946]},
    {"nombre":"Bernabé Rivera","departamento":"Artigas","tipo":"village","osm":"node/1365717080","lat":-30.29917,"lon":-56.970124,"bbox":[-56.974652,-30.30215,-56.964886,-30.294229]},
    {"nombre":"Cainsa","departamento":"Artigas","tipo":"village","osm":"node/1365630009","lat":-30.38933,"lon":-57.612435,"bbox":[-57.618633,-30.391664,-57.609678,-30.382251]},
    {"nombre":"Cerro Ejido","departamento":"Artigas","tipo":"village","osm":"node/1364983774","lat":-30.426911,"lon":-56.465721,"bbox":[-56.468688,-30.428629,-56.463036,-30.424735]},
    {"nombre":"Cerro San Eugenio","departamento":"Artigas","tipo":"village","osm":"node/1364983775","lat":-30.427433,"lon":-56.471101,"bbox":[-56.476174,-30.429133,-56.467657,-30.423241]},
    {"nombre":"Colonia Palma","departamento":"Artigas","tipo":"village","osm":"node/1365630006","lat":-30.584171,"lon":-57.678993,"bbox":[-57.682518,-30.586026,-57.674602,-30.58]},
    {"nombre":"Coronado","departamento":"Artigas","tipo":"village","osm":"node/1364940282","lat":-30.276196,"lon":-57.602868,"bbox":[-57.626418,-30.30892,-57.578221,-30.271351]},
    {"nombre":"Cuareim","departamento":"Artigas","tipo":"village","osm":"node/1364992661","lat":-30.226282,"lon":-57.568492,"bbox":[-57.581411,-30.250333,-57.558065,-30.213082]},
    {"nombre":"Franquia","departamento":"Artigas","tipo":"village","osm":"node/1364940277","lat":-30.221401,"lon":-57.596765,"bbox":[-57.645135,-30.247229,-57.561033,-30.187703]},
    {"nombre":"Las Piedras","departamento":"Artigas","tipo":"town","osm":"node/1364992658","lat":-30.245205,"lon":-57.582775,"bbox":[-57.588676,-30.252071,-57.578333,-30.240296]},
    {"nombre":"Mones Quintela","departamento":"Artigas","tipo":"village","osm":"node/1183091469","lat":-30.373568,"lon":-57.663773,"bbox":[-57.66685,-30.37737,-57.660228,-30.371957]},
    {"nombre":"Paso Campamento","departamento":"Artigas","tipo":"village","osm":"node/1306015311","lat":-30.788001,"lon":-56.782232,"bbox":[-56.785874,-30.79077,-56.778177,-30.784414]},
    {"nombre":"Pintadito","departamento":"Artigas","tipo":"town","osm":"node/2632544951","lat":-30.433734,"lon":-56.457934,"bbox":[-56.466003,-30.436035,-56.453609,-30.431889]},
    {"nombre":"Portones de Hierro y Campodónico","departamento":"Artigas","tipo":"village","osm":"node/1364940295","lat":-30.273299,"lon":-57.570337,"bbox":[-57.590328,-30.299788,-57.549405,-30.247596]},
    {"nombre":"Sequeira","departamento":"Artigas","tipo":"town","osm":"node/1306015173","lat":-31.001338,"lon":-56.877117,"bbox":[-56.894935,-31.009752,-56.846593,-30.982721]},
    {"nombre":"Tomás Gomensoro","departamento":"Artigas","tipo":"town","osm":"node/1365629990","lat":-30.430411,"lon":-57.435025,"bbox":[-57.449019,-30.439728,-57.427367,-30.422129]},
    {"nombre":"18 de Mayo","departamento":"Canelones","tipo":"city","osm":"node/9975030399","lat":-34.698646,"lon":-56.215851,"bbox":[-56.24546,-34.723074,-56.194608,-34.683049]},
    {"nombre":"Aguas Corrientes","departamento":"Canelones","tipo":"town","osm":"node/445970574","lat":-34.522704,"lon":-56.394118,"bbox":[-56.404592,-34.527555,-56.379524,-34.513859]},
    {"nombre":"Argentino","departamento":"Canelones","tipo":"village","osm":"node/884640140","lat":-34.788915,"lon":-55.453868,"bbox":[-55.459456,-34.794181,-55.432517,-34.778004]},
    {"nombre":"Atlántida","departamento":"Canelones","tipo":"town","osm":"node/1983316578","lat":-34.774389,"lon":-55.760588,"bbox":[-55.773174,-34.781953,-55.743025,-34.744051]},
    {"nombre":"Barrio Cópola","departamento":"Canelones","tipo":"village","osm":"node/428954613","lat":-34.752945,"lon":-56.242885,"bbox":[-56.24558,-34.755921,-56.237893,-34.750702]},
    {"nombre":"Barrio La Lucha","departamento":"Canelones","tipo":"village","osm":"node/428960954","lat":-34.747937,"lon":-56.24237,"bbox":[-56.243829,-34.74992,-56.240562,-34.744692]},
    {"nombre":"Barros Blancos","departamento":"Canelones","tipo":"city","osm":"node/1296548565","lat":-34.752023,"lon":-56.000281,"bbox":[-56.0373,-34.782805,-55.953217,-34.723932]},
    {"nombre":"Bello Horizonte","departamento":"Canelones","tipo":"town","osm":"node/1901108303","lat":-34.771795,"lon":-55.64528,"bbox":[-55.655807,-34.779698,-55.635252,-34.751198]},
    {"nombre":"Campo Militar","departamento":"Canelones","tipo":"village","osm":"node/445970576","lat":-34.577923,"lon":-56.393263,"bbox":[-56.399036,-34.581451,-56.387985,-34.57744]},
    {"nombre":"Canelones","departamento":"Canelones","tipo":"city","osm":"node/302610933","lat":-34.524237,"lon":-56.281752,"bbox":[-56.298856,-34.553172,-56.26369,-34.496424]},
    {"nombre":"Carrasco del Sauce","departamento":"Canelones","tipo":"village","osm":"node/13030803733","lat":-34.681548,"lon":-56.112918,"bbox":[-56.121481,-34.693096,-56.105941,-34.679992]},
    {"nombre":"Castellanos","departamento":"Canelones","tipo":"village","osm":"node/445971725","lat":-34.380426,"lon":-55.952189,"bbox":[-55.959431,-34.385364,-55.9421,-34.372549]},
    {"nombre":"City Golf","departamento":"Canelones","tipo":"town","osm":"node/1902763918","lat":-34.758821,"lon":-55.7735,"bbox":[-55.780083,-34.767908,-55.765513,-34.752243]},
    {"nombre":"Ciudad de la Costa","departamento":"Canelones","tipo":"city","osm":"node/1987919961","lat":-34.825583,"lon":-55.958956,"bbox":[-56.040856,-34.879642,-55.861852,-34.775083]},
    {"nombre":"Costa Azul","departamento":"Canelones","tipo":"town","osm":"node/1901108309","lat":-34.768784,"lon":-55.656707,"bbox":[-55.668235,-34.777723,-55.650175,-34.736986]},
    {"nombre":"Costa y Guillamón","departamento":"Canelones","tipo":"village","osm":"node/428959443","lat":-34.760236,"lon":-56.237975,"bbox":[-56.239829,-34.761479,-56.236552,-34.758945]},
    {"nombre":"Cruz de los Caminos","departamento":"Canelones","tipo":"village","osm":"node/445971735","lat":-34.633711,"lon":-55.962943,"bbox":[-55.970043,-34.639327,-55.952092,-34.628241]},
    {"nombre":"Cuchilla Alta","departamento":"Canelones","tipo":"town","osm":"node/927500310","lat":-34.793544,"lon":-55.494379,"bbox":[-55.504808,-34.798846,-55.489021,-34.781874]},
    {"nombre":"El Galeón","departamento":"Canelones","tipo":"village","osm":"node/881202303","lat":-34.79408,"lon":-55.486682,"bbox":[-55.49351,-34.798882,-55.476578,-34.786467]},
    {"nombre":"Empalme Olmos","departamento":"Canelones","tipo":"town","osm":"node/445006416","lat":-34.695458,"lon":-55.894868,"bbox":[-55.913364,-34.701776,-55.882735,-34.682071]},
    {"nombre":"Estación Atlántida","departamento":"Canelones","tipo":"town","osm":"node/445148964","lat":-34.741619,"lon":-55.762978,"bbox":[-55.771448,-34.75229,-55.753092,-34.731052]},
    {"nombre":"Estación La Floresta","departamento":"Canelones","tipo":"town","osm":"node/1983452170","lat":-34.734688,"lon":-55.683864,"bbox":[-55.691537,-34.740982,-55.675014,-34.727228]},
    {"nombre":"Estación Tapia","departamento":"Canelones","tipo":"village","osm":"node/445971726","lat":-34.565736,"lon":-55.75055,"bbox":[-55.754672,-34.571832,-55.748103,-34.56058]},
    {"nombre":"Estanque de Pando","departamento":"Canelones","tipo":"village","osm":"node/445971732","lat":-34.694192,"lon":-55.970466,"bbox":[-55.973585,-34.695987,-55.967779,-34.692489]},
    {"nombre":"Fortín de Santa Rosa","departamento":"Canelones","tipo":"village","osm":"node/1289585735","lat":-34.771943,"lon":-55.805602,"bbox":[-55.819896,-34.7797,-55.792619,-34.766797]},
    {"nombre":"Fraccionamiento Camino del Andaluz y Ruta 84","departamento":"Canelones","tipo":"town","osm":"node/432513934","lat":-34.757278,"lon":-56.072094,"bbox":[-56.09424,-34.777816,-56.052863,-34.739772]},
    {"nombre":"Fraccionamiento Ruta 74","departamento":"Canelones","tipo":"town","osm":"node/1293353292","lat":-34.715933,"lon":-56.048987,"bbox":[-56.056892,-34.721912,-56.043494,-34.709203]},
    {"nombre":"General Liber Seregni","departamento":"Canelones","tipo":"city","osm":"node/5356903787","lat":-34.819868,"lon":-56.007987,"bbox":[-56.055052,-34.840878,-55.965663,-34.751984]},
    {"nombre":"Guazú-Virá","departamento":"Canelones","tipo":"village","osm":"node/1901108313","lat":-34.767704,"lon":-55.613668,"bbox":null},
    {"nombre":"Jardines de Pando","departamento":"Canelones","tipo":"village","osm":"node/445971731","lat":-34.686127,"lon":-55.966302,"bbox":[-55.968052,-34.688877,-55.962548,-34.681964]},
    {"nombre":"Jaureguiberry","departamento":"Canelones","tipo":"village","osm":"node/884640150","lat":-34.782812,"lon":-55.401332,"bbox":[-55.455197,-34.79193,-55.394657,-34.768954]},
    {"nombre":"Joaquín Suárez","departamento":"Canelones","tipo":"town","osm":"node/2022358004","lat":-34.735516,"lon":-56.035064,"bbox":[-56.051121,-34.74669,-56.014965,-34.725089]},
    {"nombre":"Juanicó","departamento":"Canelones","tipo":"town","osm":"node/447148850","lat":-34.595268,"lon":-56.255238,"bbox":[-56.258873,-34.599197,-56.247965,-34.592001]},
    {"nombre":"La Floresta","departamento":"Canelones","tipo":"town","osm":"node/1901108317","lat":-34.753769,"lon":-55.675739,"bbox":[-55.711504,-34.767492,-55.662562,-34.731408]},
    {"nombre":"La Montañesa","departamento":"Canelones","tipo":"village","osm":"node/441915958","lat":-34.720026,"lon":-55.880307,"bbox":[-55.883217,-34.72263,-55.878087,-34.716928]},
    {"nombre":"La Paz","departamento":"Canelones","tipo":"city","osm":"node/427239178","lat":-34.763265,"lon":-56.223696,"bbox":[-56.241316,-34.770102,-56.214708,-34.738719]},
    {"nombre":"La Tuna","departamento":"Canelones","tipo":"village","osm":"node/884668311","lat":-34.782896,"lon":-55.560519,"bbox":[-55.564933,-34.78573,-55.558625,-34.77363]},
    {"nombre":"Las Brujas","departamento":"Canelones","tipo":"village","osm":"node/460032537","lat":-34.690674,"lon":-56.3996,"bbox":[-56.413089,-34.699816,-56.365864,-34.670334]},
    {"nombre":"Las Piedras","departamento":"Canelones","tipo":"city","osm":"node/422918346","lat":-34.72749,"lon":-56.216498,"bbox":[-56.249489,-34.749755,-56.18158,-34.704347]},
    {"nombre":"Las Toscas","departamento":"Canelones","tipo":"town","osm":"node/1904628432","lat":-34.773005,"lon":-55.738799,"bbox":[-55.754038,-34.777797,-55.728163,-34.756643]},
    {"nombre":"Los Cerrillos","departamento":"Canelones","tipo":"town","osm":"node/445970575","lat":-34.607148,"lon":-56.359034,"bbox":[-56.375842,-34.614199,-56.350047,-34.601488]},
    {"nombre":"Los Titanes","departamento":"Canelones","tipo":"village","osm":"node/884668306","lat":-34.779983,"lon":-55.566777,"bbox":[-55.56974,-34.78436,-55.563388,-34.773761]},
    {"nombre":"Marindia","departamento":"Canelones","tipo":"town","osm":"node/1585185996","lat":-34.774285,"lon":-55.826689,"bbox":[-55.83342,-34.783006,-55.810181,-34.762197]},
    {"nombre":"Migues","departamento":"Canelones","tipo":"town","osm":"node/445971728","lat":-34.488505,"lon":-55.630224,"bbox":[-55.637354,-34.49275,-55.617921,-34.478019]},
    {"nombre":"Mirador de la Tahona","departamento":"Canelones","tipo":"village","osm":"node/13030662902","lat":-34.776451,"lon":-55.964015,"bbox":[-55.9718,-34.77959,-55.959356,-34.77048]},
    {"nombre":"Montes","departamento":"Canelones","tipo":"town","osm":"node/445971729","lat":-34.492732,"lon":-55.561799,"bbox":[-55.577654,-34.508248,-55.551255,-34.48502]},
    {"nombre":"Neptunia","departamento":"Canelones","tipo":"town","osm":"node/2029243794","lat":-34.788026,"lon":-55.871871,"bbox":[-55.902997,-34.796469,-55.858262,-34.759207]},
    {"nombre":"Olmos","departamento":"Canelones","tipo":"village","osm":"node/445968233","lat":-34.698313,"lon":-55.929122,"bbox":[-55.932531,-34.70298,-55.926297,-34.696868]},
    {"nombre":"Pando","departamento":"Canelones","tipo":"city","osm":"node/445968232","lat":-34.721323,"lon":-55.959447,"bbox":[-55.996763,-34.743796,-55.936853,-34.70285]},
    {"nombre":"Parada Cabrera","departamento":"Canelones","tipo":"village","osm":"node/1280617709","lat":-34.624553,"lon":-56.255603,"bbox":[-56.265537,-34.628213,-56.243053,-34.61192]},
    {"nombre":"Parque del Plata","departamento":"Canelones","tipo":"city","osm":"node/447149962","lat":-34.765726,"lon":-55.717943,"bbox":[-55.736138,-34.772434,-55.697967,-34.737762]},
    {"nombre":"Paso Carrasco","departamento":"Canelones","tipo":"city","osm":"node/429627866","lat":-34.862115,"lon":-56.052501,"bbox":[-56.060779,-34.870434,-56.022979,-34.844976]},
    {"nombre":"Paso Espinosa","departamento":"Canelones","tipo":"village","osm":"node/445970577","lat":-34.494656,"lon":-56.283056,"bbox":[-56.285899,-34.497297,-56.279553,-34.491941]},
    {"nombre":"Paso Palomeque","departamento":"Canelones","tipo":"village","osm":"node/445970578","lat":-34.516564,"lon":-56.259527,"bbox":[-56.266426,-34.520979,-56.255152,-34.513918]},
    {"nombre":"Piedra del Toro","departamento":"Canelones","tipo":"village","osm":"node/445005063","lat":-34.702303,"lon":-55.887627,"bbox":[-55.895775,-34.704725,-55.874897,-34.697384]},
    {"nombre":"Pinamar","departamento":"Canelones","tipo":"town","osm":"node/1331515361","lat":-34.781953,"lon":-55.851518,"bbox":[-55.867058,-34.795982,-55.845167,-34.755232]},
    {"nombre":"Progreso","departamento":"Canelones","tipo":"city","osm":"node/415635916","lat":-34.679864,"lon":-56.215473,"bbox":[-56.24028,-34.686229,-56.199696,-34.650574]},
    {"nombre":"Salinas","departamento":"Canelones","tipo":"city","osm":"node/1585175688","lat":-34.781802,"lon":-55.837011,"bbox":[-55.852415,-34.790185,-55.8271,-34.759598]},
    {"nombre":"San Antonio","departamento":"Canelones","tipo":"town","osm":"node/445970626","lat":-34.451301,"lon":-56.080255,"bbox":[-56.089279,-34.460743,-56.075996,-34.438569]},
    {"nombre":"San Bautista","departamento":"Canelones","tipo":"town","osm":"node/445970625","lat":-34.441021,"lon":-55.959511,"bbox":[-55.974103,-34.447777,-55.949976,-34.432565]},
    {"nombre":"San Jacinto","departamento":"Canelones","tipo":"town","osm":"node/2028668919","lat":-34.543585,"lon":-55.87103,"bbox":[-55.885768,-34.552491,-55.857619,-34.535941]},
    {"nombre":"San Luis","departamento":"Canelones","tipo":"town","osm":"node/884668294","lat":-34.767717,"lon":-55.590331,"bbox":[-55.604013,-34.783978,-55.568794,-34.758109]},
    {"nombre":"San Ramón","departamento":"Canelones","tipo":"town","osm":"node/1377191828","lat":-34.290069,"lon":-55.957446,"bbox":[-55.978111,-34.310959,-55.936225,-34.267631]},
    {"nombre":"Santa Ana","departamento":"Canelones","tipo":"village","osm":"node/881202307","lat":-34.791492,"lon":-55.472238,"bbox":[-55.478663,-34.796078,-55.459275,-34.783254]},
    {"nombre":"Santa Lucía","departamento":"Canelones","tipo":"city","osm":"node/302610183","lat":-34.455093,"lon":-56.389301,"bbox":[-56.41953,-34.508932,-56.342965,-34.408298]},
    {"nombre":"Santa Lucía del Este","departamento":"Canelones","tipo":"village","osm":"node/884668291","lat":-34.788179,"lon":-55.537706,"bbox":[-55.548648,-34.796775,-55.52431,-34.781467]},
    {"nombre":"Santa Rosa","departamento":"Canelones","tipo":"town","osm":"node/445970624","lat":-34.498233,"lon":-56.040947,"bbox":[-56.052439,-34.50738,-56.025755,-34.486034]},
    {"nombre":"Sauce","departamento":"Canelones","tipo":"town","osm":"node/428444552","lat":-34.649666,"lon":-56.064965,"bbox":[-56.0784,-34.665909,-56.052867,-34.63618]},
    {"nombre":"Seis Hermanos","departamento":"Canelones","tipo":"village","osm":"node/1290373404","lat":-34.712866,"lon":-56.06907,"bbox":[-56.07332,-34.716197,-56.064134,-34.710016]},
    {"nombre":"Soca","departamento":"Canelones","tipo":"town","osm":"node/445965368","lat":-34.683436,"lon":-55.704475,"bbox":[-55.714998,-34.689118,-55.688938,-34.679201]},
    {"nombre":"Tala","departamento":"Canelones","tipo":"town","osm":"node/433995987","lat":-34.344296,"lon":-55.761758,"bbox":[-55.781045,-34.358228,-55.751821,-34.328154]},
    {"nombre":"Toledo","departamento":"Canelones","tipo":"town","osm":"node/429655452","lat":-34.739804,"lon":-56.089292,"bbox":[-56.104093,-34.756133,-56.076612,-34.724554]},
    {"nombre":"Totoral del Sauce","departamento":"Canelones","tipo":"town","osm":"node/445971734","lat":-34.660711,"lon":-55.993237,"bbox":[-56.002311,-34.669668,-55.982473,-34.653416]},
    {"nombre":"Viejo Molino San Bernardo","departamento":"Canelones","tipo":"village","osm":"node/445971733","lat":-34.70103,"lon":-55.965665,"bbox":[-55.970692,-34.702997,-55.96086,-34.699644]},
    {"nombre":"Villa Arejo","departamento":"Canelones","tipo":"village","osm":"node/1272113731","lat":-34.594463,"lon":-56.16827,"bbox":[-56.173055,-34.599055,-56.164497,-34.590635]},
    {"nombre":"Villa Argentina","departamento":"Canelones","tipo":"town","osm":"node/1902763923","lat":-34.768633,"lon":-55.776455,"bbox":[-55.783332,-34.772233,-55.772666,-34.760775]},
    {"nombre":"Villa Crespo y San Andrés","departamento":"Canelones","tipo":"city","osm":"node/2612364486","lat":-34.741373,"lon":-56.108733,"bbox":[-56.126902,-34.751566,-56.089212,-34.72067]},
    {"nombre":"Villa Felicidad","departamento":"Canelones","tipo":"town","osm":"node/445971736","lat":-34.641788,"lon":-56.240774,"bbox":[-56.249091,-34.64784,-56.235615,-34.639002]},
    {"nombre":"Villa Hadita","departamento":"Canelones","tipo":"village","osm":"node/1291840060","lat":-34.709303,"lon":-56.050381,"bbox":[-56.059303,-34.713558,-56.046256,-34.707516]},
    {"nombre":"Villa Instituto Adventista","departamento":"Canelones","tipo":"village","osm":"node/1280584708","lat":-34.628661,"lon":-56.25358,"bbox":[-56.257456,-34.632214,-56.246733,-34.627341]},
    {"nombre":"Villa Paz S.A.","departamento":"Canelones","tipo":"village","osm":"node/428656259","lat":-34.749311,"lon":-56.234447,"bbox":[-56.235772,-34.751079,-56.233215,-34.745578]},
    {"nombre":"Villa Porvenir","departamento":"Canelones","tipo":"village","osm":"node/1291863239","lat":-34.724717,"lon":-56.085182,"bbox":[-56.091503,-34.731192,-56.081546,-34.722375]},
    {"nombre":"Villa San Cono","departamento":"Canelones","tipo":"village","osm":"node/1272123571","lat":-34.671272,"lon":-56.167475,"bbox":[-56.171805,-34.673874,-56.165211,-34.670436]},
    {"nombre":"Villa San Felipe","departamento":"Canelones","tipo":"village","osm":"node/1291733306","lat":-34.708429,"lon":-56.057013,"bbox":[-56.059627,-34.712161,-56.053185,-34.70779]},
    {"nombre":"Villa San José","departamento":"Canelones","tipo":"town","osm":"node/1291755677","lat":-34.716429,"lon":-56.074173,"bbox":[-56.079896,-34.721262,-56.068371,-34.711736]},
    {"nombre":"Aceguá","departamento":"Cerro Largo","tipo":"town","osm":"node/2396838728","lat":-31.871832,"lon":-54.162778,"bbox":[-54.168824,-31.878892,-54.156878,-31.867585]},
    {"nombre":"Arbolito","departamento":"Cerro Largo","tipo":"village","osm":"node/1377860050","lat":-32.610598,"lon":-54.211257,"bbox":[-54.215388,-32.615673,-54.205156,-32.605171]},
    {"nombre":"Arévalo","departamento":"Cerro Largo","tipo":"village","osm":"node/1377925283","lat":-32.639001,"lon":-55.078385,"bbox":[-55.081813,-32.641125,-55.076543,-32.637131]},
    {"nombre":"Bañado de Medina","departamento":"Cerro Largo","tipo":"village","osm":"node/1377810824","lat":-32.403435,"lon":-54.35038,"bbox":[-54.35474,-32.406167,-54.345357,-32.398201]},
    {"nombre":"Barrio López Benítez","departamento":"Cerro Largo","tipo":"village","osm":"node/1377810804","lat":-32.363479,"lon":-54.210277,"bbox":[-54.212649,-32.365313,-54.208477,-32.358972]},
    {"nombre":"Cerro de las Cuentas","departamento":"Cerro Largo","tipo":"village","osm":"node/1377820060","lat":-32.620149,"lon":-54.593813,"bbox":[-54.598109,-32.631174,-54.588808,-32.617242]},
    {"nombre":"Fraile Muerto","departamento":"Cerro Largo","tipo":"town","osm":"node/617894021","lat":-32.51327,"lon":-54.523443,"bbox":[-54.543839,-32.521713,-54.510228,-32.503875]},
    {"nombre":"Isidoro Noblía","departamento":"Cerro Largo","tipo":"town","osm":"node/1377148463","lat":-31.960638,"lon":-54.122894,"bbox":[-54.135899,-31.969626,-54.114001,-31.953589]},
    {"nombre":"Lago Merín","departamento":"Cerro Largo","tipo":"village","osm":"node/1377855696","lat":-32.741672,"lon":-53.261206,"bbox":[-53.270463,-32.752866,-53.254664,-32.732303]},
    {"nombre":"Melo","departamento":"Cerro Largo","tipo":"city","osm":"node/617428620","lat":-32.368085,"lon":-54.169715,"bbox":[-54.205013,-32.393515,-54.135977,-32.341581]},
    {"nombre":"Plácido Rosas","departamento":"Cerro Largo","tipo":"village","osm":"node/1377855695","lat":-32.757019,"lon":-53.718924,"bbox":[-53.723088,-32.764123,-53.707412,-32.746301]},
    {"nombre":"Río Branco","departamento":"Cerro Largo","tipo":"city","osm":"node/1377855698","lat":-32.588689,"lon":-53.378083,"bbox":[-53.404447,-32.613405,-53.360678,-32.571113]},
    {"nombre":"Toledo","departamento":"Cerro Largo","tipo":"village","osm":"node/1377815704","lat":-32.52959,"lon":-54.529423,"bbox":[-54.536432,-32.533035,-54.52278,-32.527748]},
    {"nombre":"Tupambaé","departamento":"Cerro Largo","tipo":"town","osm":"node/617894020","lat":-32.836365,"lon":-54.763265,"bbox":[-54.773488,-32.841957,-54.752761,-32.826845]},
    {"nombre":"Britópolis","departamento":"Colonia","tipo":"village","osm":"node/1382175284","lat":-34.431865,"lon":-57.271174,"bbox":[-57.274868,-34.435735,-57.261681,-34.427688]},
    {"nombre":"Campana","departamento":"Colonia","tipo":"village","osm":"node/1382098113","lat":-34.032615,"lon":-57.90291,"bbox":[-57.905857,-34.035435,-57.894256,-34.029844]},
    {"nombre":"Carmelo","departamento":"Colonia","tipo":"city","osm":"node/332605466","lat":-33.996783,"lon":-58.283648,"bbox":[-58.306604,-34.020626,-58.25909,-33.972581]},
    {"nombre":"Colonia del Sacramento","departamento":"Colonia","tipo":"city","osm":"node/1382089438","lat":-34.469859,"lon":-57.843368,"bbox":[-57.889301,-34.476233,-57.788529,-34.423332]},
    {"nombre":"Colonia Valdense","departamento":"Colonia","tipo":"town","osm":"node/429019679","lat":-34.340022,"lon":-57.262805,"bbox":[-57.286303,-34.360172,-57.247412,-34.328072]},
    {"nombre":"Conchillas","departamento":"Colonia","tipo":"village","osm":"node/698340727","lat":-34.164327,"lon":-58.03328,"bbox":[-58.037768,-34.16774,-58.025979,-34.157126]},
    {"nombre":"Cufré","departamento":"Colonia","tipo":"village","osm":"node/1382138699","lat":-34.19644,"lon":-57.105864,"bbox":[-57.11188,-34.202864,-57.102039,-34.193361]},
    {"nombre":"El Cerro","departamento":"Colonia","tipo":"village","osm":"node/2510278667","lat":-33.988024,"lon":-58.23732,"bbox":[-58.238772,-33.993004,-58.234766,-33.985239]},
    {"nombre":"El Semillero","departamento":"Colonia","tipo":"village","osm":"node/1382112603","lat":-34.337767,"lon":-57.689114,"bbox":[-57.698696,-34.341194,-57.687147,-34.330397]},
    {"nombre":"Estanzuela","departamento":"Colonia","tipo":"village","osm":"node/1382112639","lat":-34.328634,"lon":-57.72548,"bbox":null},
    {"nombre":"Florencio Sánchez","departamento":"Colonia","tipo":"town","osm":"node/1156306882","lat":-33.876372,"lon":-57.370348,"bbox":[-57.382113,-33.891404,-57.355555,-33.873632]},
    {"nombre":"Juan Lacaze","departamento":"Colonia","tipo":"city","osm":"node/429019695","lat":-34.434266,"lon":-57.438043,"bbox":[-57.461098,-34.442536,-57.428621,-34.404078]},
    {"nombre":"La Paz","departamento":"Colonia","tipo":"village","osm":"node/429019688","lat":-34.347157,"lon":-57.309232,"bbox":[-57.314097,-34.35375,-57.30016,-34.342067]},
    {"nombre":"Los Pinos","departamento":"Colonia","tipo":"village","osm":"node/1378039339","lat":-34.433832,"lon":-57.243681,"bbox":[-57.251076,-34.437387,-57.23349,-34.430032]},
    {"nombre":"Miguelete","departamento":"Colonia","tipo":"village","osm":"node/698360778","lat":-34.00685,"lon":-57.647281,"bbox":[-57.654684,-34.012573,-57.640132,-33.997462]},
    {"nombre":"Minas de Narancio","departamento":"Colonia","tipo":"village","osm":"node/698409448","lat":-34.139471,"lon":-57.96903,"bbox":null},
    {"nombre":"Nueva Helvecia","departamento":"Colonia","tipo":"city","osm":"node/429019682","lat":-34.284969,"lon":-57.233673,"bbox":[-57.259416,-34.321741,-57.215273,-34.272397]},
    {"nombre":"Nueva Palmira","departamento":"Colonia","tipo":"city","osm":"node/332605307","lat":-33.871091,"lon":-58.406888,"bbox":[-58.422635,-33.924989,-58.384395,-33.840033]},
    {"nombre":"Ombúes de Lavalle","departamento":"Colonia","tipo":"town","osm":"node/697315226","lat":-33.940575,"lon":-57.808363,"bbox":[-57.822464,-33.945725,-57.794928,-33.928307]},
    {"nombre":"Pueblo Gil","departamento":"Colonia","tipo":"village","osm":"node/2261926924","lat":-34.152503,"lon":-58.029658,"bbox":[-58.03175,-34.154534,-58.026934,-34.151019]},
    {"nombre":"Radial Hernández","departamento":"Colonia","tipo":"village","osm":"node/698376430","lat":-34.120775,"lon":-58.007888,"bbox":[-58.011256,-34.1247,-58.00419,-34.114957]},
    {"nombre":"Rosario","departamento":"Colonia","tipo":"city","osm":"node/415719961","lat":-34.311559,"lon":-57.351292,"bbox":[-57.367309,-34.339755,-57.334028,-34.297338]},
    {"nombre":"Santa Ana","departamento":"Colonia","tipo":"village","osm":"node/1382067498","lat":-34.421413,"lon":-57.59345,"bbox":[-57.602015,-34.425587,-57.582378,-34.413119]},
    {"nombre":"Tarariras","departamento":"Colonia","tipo":"town","osm":"node/697315225","lat":-34.264828,"lon":-57.614342,"bbox":[-57.62924,-34.278638,-57.602408,-34.255683]},
    {"nombre":"Zagarzazú","departamento":"Colonia","tipo":"village","osm":"node/1382098112","lat":-33.964705,"lon":-58.332245,"bbox":[-58.336554,-33.968439,-58.327081,-33.958056]},
    {"nombre":"Blanquillo","departamento":"Durazno","tipo":"town","osm":"node/1335909482","lat":-32.886808,"lon":-55.615383,"bbox":[-55.623988,-32.895376,-55.609645,-32.878507]},
    {"nombre":"Carlos Reyles","departamento":"Durazno","tipo":"town","osm":"node/1335836184","lat":-33.05713,"lon":-56.476676,"bbox":[-56.493908,-33.066393,-56.464789,-33.047124]},
    {"nombre":"Carmen","departamento":"Durazno","tipo":"town","osm":"node/1195770129","lat":-33.241037,"lon":-56.013145,"bbox":[-56.01971,-33.250029,-55.989812,-33.223424]},
    {"nombre":"Centenario","departamento":"Durazno","tipo":"town","osm":"node/1335836152","lat":-32.828319,"lon":-56.498647,"bbox":[-56.507622,-32.8392,-56.490312,-32.820664]},
    {"nombre":"Durazno","departamento":"Durazno","tipo":"city","osm":"node/416492912","lat":-33.380125,"lon":-56.522499,"bbox":[-56.556067,-33.422993,-56.491953,-33.333975]},
    {"nombre":"La Paloma","departamento":"Durazno","tipo":"town","osm":"node/1335909499","lat":-32.727674,"lon":-55.579665,"bbox":[-55.593038,-32.736756,-55.570981,-32.717351]},
    {"nombre":"San Jorge","departamento":"Durazno","tipo":"village","osm":"node/1335963058","lat":-32.844651,"lon":-55.89638,"bbox":[-55.899498,-32.847893,-55.891357,-32.837188]},
    {"nombre":"Sarandí del Yi","departamento":"Durazno","tipo":"town","osm":"node/1335909712","lat":-33.344214,"lon":-55.631325,"bbox":[-55.646817,-33.356165,-55.613498,-33.315126]},
    {"nombre":"Andresito","departamento":"Flores","tipo":"village","osm":"node/1345262413","lat":-33.167717,"lon":-57.130218,"bbox":[-57.134812,-33.171215,-57.126409,-33.16191]},
    {"nombre":"Ismael Cortinas","departamento":"Flores","tipo":"town","osm":"node/1160516484","lat":-33.96025,"lon":-57.090371,"bbox":[-57.09595,-33.968845,-57.078714,-33.955559]},
    {"nombre":"Trinidad","departamento":"Flores","tipo":"city","osm":"node/302608615","lat":-33.517348,"lon":-56.897972,"bbox":[-56.913874,-33.536635,-56.885186,-33.502569]},
    {"nombre":"25 de Agosto","departamento":"Florida","tipo":"town","osm":"node/471564639","lat":-34.41233,"lon":-56.400164,"bbox":[-56.421098,-34.420265,-56.393104,-34.405349]},
    {"nombre":"25 de Mayo","departamento":"Florida","tipo":"town","osm":"node/1345247254","lat":-34.199093,"lon":-56.342687,"bbox":[-56.349807,-34.206914,-56.325117,-34.184551]},
    {"nombre":"Alejandro Gallinal","departamento":"Florida","tipo":"town","osm":"node/1341368850","lat":-33.861735,"lon":-55.543973,"bbox":[-55.553479,-33.870015,-55.533469,-33.854675]},
    {"nombre":"Capilla del Sauce","departamento":"Florida","tipo":"village","osm":"node/1324391748","lat":-33.469439,"lon":-55.630689,"bbox":[-55.641583,-33.473446,-55.620006,-33.460727]},
    {"nombre":"Cardal","departamento":"Florida","tipo":"town","osm":"node/1345247250","lat":-34.291402,"lon":-56.391608,"bbox":[-56.402705,-34.299646,-56.385966,-34.285034]},
    {"nombre":"Casupá","departamento":"Florida","tipo":"town","osm":"node/433995990","lat":-34.100588,"lon":-55.651417,"bbox":[-55.663007,-34.110352,-55.632357,-34.090809]},
    {"nombre":"Chamizo","departamento":"Florida","tipo":"village","osm":"node/1324391647","lat":-34.243601,"lon":-55.91701,"bbox":[-55.921711,-34.247788,-55.913047,-34.238351]},
    {"nombre":"Florida","departamento":"Florida","tipo":"city","osm":"node/1324391734","lat":-34.101363,"lon":-56.214752,"bbox":[-56.243139,-34.115451,-56.202749,-34.076118]},
    {"nombre":"Fray Marcos","departamento":"Florida","tipo":"town","osm":"node/433995989","lat":-34.19608,"lon":-55.739522,"bbox":[-55.746844,-34.207275,-55.727657,-34.188728]},
    {"nombre":"Goñi","departamento":"Florida","tipo":"village","osm":"node/1337576036","lat":-33.520228,"lon":-56.411688,"bbox":[-56.417961,-33.524209,-56.407986,-33.516422]},
    {"nombre":"Independencia","departamento":"Florida","tipo":"village","osm":"node/1337500065","lat":-34.354141,"lon":-56.398495,"bbox":[-56.402306,-34.357216,-56.394388,-34.351117]},
    {"nombre":"La Cruz","departamento":"Florida","tipo":"village","osm":"node/1337556535","lat":-33.930212,"lon":-56.2368,"bbox":[-56.244921,-33.936701,-56.229042,-33.924926]},
    {"nombre":"Mendoza","departamento":"Florida","tipo":"village","osm":"node/1324391641","lat":-34.282305,"lon":-56.21449,"bbox":[-56.219555,-34.286168,-56.2093,-34.276353]},
    {"nombre":"Mendoza Chico","departamento":"Florida","tipo":"village","osm":"node/1324391880","lat":-34.239474,"lon":-56.21652,"bbox":[-56.222162,-34.247663,-56.213482,-34.234102]},
    {"nombre":"Nico Pérez","departamento":"Florida","tipo":"town","osm":"node/1341652585","lat":-33.481529,"lon":-55.15425,"bbox":[-55.162659,-33.48793,-55.142057,-33.460542]},
    {"nombre":"Puntas de Maciel","departamento":"Florida","tipo":"village","osm":"node/1337575974","lat":-33.622385,"lon":-56.362481,"bbox":[-56.365776,-33.626663,-56.360133,-33.617781]},
    {"nombre":"Reboledo","departamento":"Florida","tipo":"village","osm":"node/433995991","lat":-33.993981,"lon":-55.648883,"bbox":[-55.652039,-34.002977,-55.642807,-33.988555]},
    {"nombre":"Sarandí Grande","departamento":"Florida","tipo":"town","osm":"node/1337575966","lat":-33.722821,"lon":-56.327396,"bbox":[-56.34078,-33.748618,-56.316082,-33.700327]},
    {"nombre":"Barrio La Coronilla - ANCAP","departamento":"Lavalleja","tipo":"village","osm":"node/1309547683","lat":-34.396908,"lon":-55.299279,"bbox":[-55.306396,-34.397866,-55.291869,-34.390718]},
    {"nombre":"José Batlle y Ordóñez","departamento":"Lavalleja","tipo":"town","osm":"node/433999769","lat":-33.473334,"lon":-55.146936,"bbox":[-55.154889,-33.486905,-55.137693,-33.461912]},
    {"nombre":"José Pedro Varela","departamento":"Lavalleja","tipo":"town","osm":"node/618975428","lat":-33.456469,"lon":-54.535345,"bbox":[-54.551176,-33.469425,-54.520785,-33.437749]},
    {"nombre":"Mariscala","departamento":"Lavalleja","tipo":"town","osm":"node/1309587789","lat":-34.041882,"lon":-54.777037,"bbox":[-54.78237,-34.053104,-54.761492,-34.032756]},
    {"nombre":"Minas","departamento":"Lavalleja","tipo":"city","osm":"node/347693883","lat":-34.377399,"lon":-55.238214,"bbox":[-55.283217,-34.403513,-55.204799,-34.34956]},
    {"nombre":"Pirarajá","departamento":"Lavalleja","tipo":"village","osm":"node/1309460900","lat":-33.740851,"lon":-54.757301,"bbox":[-54.778666,-33.74525,-54.746793,-33.732986]},
    {"nombre":"Solís de Mataojo","departamento":"Lavalleja","tipo":"town","osm":"node/1309563669","lat":-34.599162,"lon":-55.466568,"bbox":[-55.473369,-34.61223,-55.444501,-34.583245]},
    {"nombre":"Villa Serrana","departamento":"Lavalleja","tipo":"village","osm":"node/1309563671","lat":-34.322367,"lon":-54.989361,"bbox":[-55.011977,-34.338468,-54.968917,-34.305078]},
    {"nombre":"Zapicán","departamento":"Lavalleja","tipo":"village","osm":"node/1309596706","lat":-33.527633,"lon":-54.939537,"bbox":[-54.949286,-33.536018,-54.933121,-33.509647]},
    {"nombre":"Aiguá","departamento":"Maldonado","tipo":"town","osm":"node/703548126","lat":-34.201967,"lon":-54.767157,"bbox":[-54.779146,-34.216438,-54.747462,-34.195069]},
    {"nombre":"Balnerario Solís","departamento":"Maldonado","tipo":"village","osm":"node/1301120794","lat":-34.792373,"lon":-55.383716,"bbox":null},
    {"nombre":"Bella Vista","departamento":"Maldonado","tipo":"village","osm":"node/1301120999","lat":-34.802103,"lon":-55.357452,"bbox":[-55.378606,-34.81127,-55.336916,-34.796013]},
    {"nombre":"Buenos Aires","departamento":"Maldonado","tipo":"town","osm":"node/1307994987","lat":-34.890092,"lon":-54.794371,"bbox":[-54.811261,-34.902922,-54.776736,-34.875878]},
    {"nombre":"Canteras de Marelli","departamento":"Maldonado","tipo":"village","osm":"node/1306395708","lat":-34.843629,"lon":-54.943225,"bbox":[-54.948516,-34.846164,-54.939434,-34.842399]},
    {"nombre":"Cerros Azules","departamento":"Maldonado","tipo":"village","osm":"node/1300087387","lat":-34.765803,"lon":-55.36491,"bbox":[-55.369415,-34.770569,-55.361321,-34.762625]},
    {"nombre":"El Chorro","departamento":"Maldonado","tipo":"town","osm":"node/1307994999","lat":-34.900407,"lon":-54.81274,"bbox":[-54.824063,-34.906821,-54.803271,-34.877345]},
    {"nombre":"El Pejerrey","departamento":"Maldonado","tipo":"village","osm":"node/3916526588","lat":-34.855027,"lon":-55.118607,"bbox":[-55.133555,-34.864185,-55.106119,-34.847049]},
    {"nombre":"El Tesoro","departamento":"Maldonado","tipo":"town","osm":"node/1307994905","lat":-34.901052,"lon":-54.868391,"bbox":[-54.87893,-34.911283,-54.856254,-34.887083]},
    {"nombre":"Estación Las Flores","departamento":"Maldonado","tipo":"village","osm":"node/1300087393","lat":-34.789315,"lon":-55.32766,"bbox":[-55.336422,-34.797948,-55.315183,-34.785606]},
    {"nombre":"Gerona","departamento":"Maldonado","tipo":"village","osm":"node/1300087395","lat":-34.767562,"lon":-55.254814,"bbox":[-55.261697,-34.772604,-55.246213,-34.759164]},
    {"nombre":"Gregorio Aznarez","departamento":"Maldonado","tipo":"town","osm":"node/1300064179","lat":-34.747473,"lon":-55.399324,"bbox":[-55.41077,-34.752144,-55.391784,-34.740958]},
    {"nombre":"Hipódromo","departamento":"Maldonado","tipo":"town","osm":"node/1306395706","lat":-34.86152,"lon":-54.944825,"bbox":null},
    {"nombre":"La Barra","departamento":"Maldonado","tipo":"town","osm":"node/440187993","lat":-34.914587,"lon":-54.861413,"bbox":[-54.872732,-34.919042,-54.839244,-34.897635]},
    {"nombre":"La Capuera","departamento":"Maldonado","tipo":"town","osm":"node/1307170596","lat":-34.852516,"lon":-55.127614,"bbox":[-55.144313,-34.865531,-55.120067,-34.841852]},
    {"nombre":"La Juanita","departamento":"Maldonado","tipo":"village","osm":"node/4803954891","lat":-34.835493,"lon":-54.655898,"bbox":[-54.671866,-34.840855,-54.642423,-34.828347]},
    {"nombre":"Las Flores","departamento":"Maldonado","tipo":"village","osm":"node/1301120645","lat":-34.810537,"lon":-55.331923,"bbox":[-55.340927,-34.819611,-55.319363,-34.806383]},
    {"nombre":"Maldonado","departamento":"Maldonado","tipo":"city","osm":"node/302611004","lat":-34.908716,"lon":-54.958272,"bbox":[-55.013886,-34.932988,-54.8723,-34.853542]},
    {"nombre":"Manantiales","departamento":"Maldonado","tipo":"village","osm":"node/1307994896","lat":-34.905909,"lon":-54.823862,"bbox":[-54.836409,-34.909098,-54.817148,-34.900035]},
    {"nombre":"Ocean Park","departamento":"Maldonado","tipo":"village","osm":"node/1307255337","lat":-34.870755,"lon":-55.120258,"bbox":[-55.129437,-34.879354,-55.080243,-34.862873]},
    {"nombre":"Pan de Azúcar","departamento":"Maldonado","tipo":"town","osm":"node/1300100178","lat":-34.77556,"lon":-55.224032,"bbox":[-55.243987,-34.783578,-55.212735,-34.762354]},
    {"nombre":"Piriápolis","departamento":"Maldonado","tipo":"city","osm":"node/730574254","lat":-34.868904,"lon":-55.272447,"bbox":[-55.297064,-34.893282,-55.257077,-34.834567]},
    {"nombre":"Playa Grande","departamento":"Maldonado","tipo":"town","osm":"node/1306993743","lat":-34.845655,"lon":-55.29591,"bbox":[-55.30443,-34.855712,-55.286802,-34.831792]},
    {"nombre":"Playa Hermosa","departamento":"Maldonado","tipo":"town","osm":"node/1301132813","lat":-34.83325,"lon":-55.30273,"bbox":[-55.313179,-34.842866,-55.292652,-34.821358]},
    {"nombre":"Playa Verde","departamento":"Maldonado","tipo":"village","osm":"node/1301132814","lat":-34.823316,"lon":-55.313972,"bbox":[-55.328194,-34.83319,-55.307324,-34.815741]},
    {"nombre":"Punta Ballena","departamento":"Maldonado","tipo":"town","osm":"node/1307795202","lat":-34.890144,"lon":-55.040114,"bbox":[-55.081611,-34.917299,-55.000295,-34.846192]},
    {"nombre":"Punta Colorada","departamento":"Maldonado","tipo":"village","osm":"node/1307064733","lat":-34.90024,"lon":-55.258077,"bbox":[-55.262304,-34.904509,-55.234629,-34.881095]},
    {"nombre":"Punta del Este","departamento":"Maldonado","tipo":"city","osm":"node/302611023","lat":-34.963234,"lon":-54.943998,"bbox":[-54.957097,-34.973934,-54.866143,-34.911602]},
    {"nombre":"Punta Negra","departamento":"Maldonado","tipo":"village","osm":"node/1307087679","lat":-34.890347,"lon":-55.218728,"bbox":[-55.228164,-34.894915,-55.21186,-34.878987]},
    {"nombre":"San Carlos","departamento":"Maldonado","tipo":"city","osm":"node/321555240","lat":-34.792045,"lon":-54.92075,"bbox":[-54.938091,-34.807619,-54.901025,-34.768564]},
    {"nombre":"Santa Mónica","departamento":"Maldonado","tipo":"village","osm":"node/1306394024","lat":-34.847297,"lon":-54.704203,"bbox":[-54.740056,-34.867563,-54.674276,-34.841076]},
    {"nombre":"Sauce de Portezuelo","departamento":"Maldonado","tipo":"village","osm":"node/1307255306","lat":-34.871706,"lon":-55.138241,"bbox":[-55.157869,-34.881819,-55.127819,-34.863738]},
    {"nombre":"Montevideo","departamento":"Montevideo","tipo":"city","osm":"node/296140043","lat":-34.905892,"lon":-56.191309,"bbox":[-56.4314,-34.938056,-56.017202,-34.701853]},
    {"nombre":"Beisso","departamento":"Paysandú","tipo":"village","osm":"node/1376333995","lat":-32.318554,"lon":-57.052549,"bbox":[-57.058163,-32.324085,-57.048703,-32.309176]},
    {"nombre":"Casablanca","departamento":"Paysandú","tipo":"village","osm":"node/1376316068","lat":-32.397164,"lon":-58.156586,"bbox":[-58.163721,-32.406038,-58.151455,-32.393477]},
    {"nombre":"Cerro Chato","departamento":"Paysandú","tipo":"village","osm":"node/1376859236","lat":-31.871285,"lon":-57.537087,"bbox":[-57.546124,-31.875811,-57.528329,-31.84256]},
    {"nombre":"Chacras de Paysandú","departamento":"Paysandú","tipo":"town","osm":"node/1376316097","lat":-32.343862,"lon":-58.008669,"bbox":[-58.064837,-32.427815,-57.919199,-32.269848]},
    {"nombre":"Chapicuy","departamento":"Paysandú","tipo":"village","osm":"node/1376859174","lat":-31.660619,"lon":-57.888687,"bbox":[-57.892188,-31.666738,-57.884492,-31.65606]},
    {"nombre":"Constancia","departamento":"Paysandú","tipo":"village","osm":"node/1376859331","lat":-32.203907,"lon":-58.005885,"bbox":[-58.013597,-32.212041,-58.001397,-32.202268]},
    {"nombre":"El Eucaliptus","departamento":"Paysandú","tipo":"village","osm":"node/1376859330","lat":-31.902225,"lon":-57.267573,"bbox":[-57.270705,-31.910676,-57.253339,-31.894702]},
    {"nombre":"Esperanza","departamento":"Paysandú","tipo":"village","osm":"node/1376316062","lat":-32.352443,"lon":-57.952563,"bbox":[-57.958589,-32.354284,-57.947085,-32.346483]},
    {"nombre":"Gallinal","departamento":"Paysandú","tipo":"village","osm":"node/1376859184","lat":-31.883681,"lon":-57.478253,"bbox":[-57.484727,-31.88858,-57.469478,-31.880899]},
    {"nombre":"Guichón","departamento":"Paysandú","tipo":"town","osm":"node/1370545820","lat":-32.360382,"lon":-57.200298,"bbox":[-57.211405,-32.369242,-57.185713,-32.348144]},
    {"nombre":"Lorenzo Geyres","departamento":"Paysandú","tipo":"village","osm":"node/1376859300","lat":-32.079071,"lon":-57.919112,"bbox":[-57.923651,-32.08496,-57.913195,-32.074314]},
    {"nombre":"Morató","departamento":"Paysandú","tipo":"village","osm":"node/1376339286","lat":-32.378608,"lon":-56.703047,"bbox":[-56.70674,-32.381823,-56.694838,-32.374741]},
    {"nombre":"Nuevo Paysandú","departamento":"Paysandú","tipo":"town","osm":"node/1376334001","lat":-32.270209,"lon":-58.083776,"bbox":[-58.098854,-32.294828,-58.034644,-32.23225]},
    {"nombre":"Orgoroso","departamento":"Paysandú","tipo":"village","osm":"node/1370545830","lat":-32.380286,"lon":-57.517759,"bbox":[-57.520273,-32.386045,-57.514057,-32.377671]},
    {"nombre":"Paysandú","departamento":"Paysandú","tipo":"city","osm":"node/302608039","lat":-32.321726,"lon":-58.089214,"bbox":[-58.107845,-32.347333,-58.050359,-32.290028]},
    {"nombre":"Piedras Coloradas","departamento":"Paysandú","tipo":"town","osm":"node/1370545835","lat":-32.373004,"lon":-57.60871,"bbox":[-57.613465,-32.378199,-57.600331,-32.368407]},
    {"nombre":"Porvenir","departamento":"Paysandú","tipo":"town","osm":"node/1376316066","lat":-32.393204,"lon":-57.967888,"bbox":[-57.975466,-32.398211,-57.96417,-32.389323]},
    {"nombre":"Quebracho","departamento":"Paysandú","tipo":"town","osm":"node/1376859169","lat":-31.935564,"lon":-57.90054,"bbox":[-57.908525,-31.943399,-57.884066,-31.928331]},
    {"nombre":"San Félix","departamento":"Paysandú","tipo":"town","osm":"node/1376293967","lat":-32.351118,"lon":-58.101682,"bbox":[-58.111481,-32.355289,-58.089249,-32.335651]},
    {"nombre":"Algorta","departamento":"Río Negro","tipo":"village","osm":"node/1361732096","lat":-32.423098,"lon":-57.392484,"bbox":[-57.401488,-32.425673,-57.38752,-32.420114]},
    {"nombre":"Barrio Anglo","departamento":"Río Negro","tipo":"village","osm":"node/1370564872","lat":-33.119277,"lon":-58.327015,"bbox":[-58.336545,-33.12793,-58.319653,-33.116]},
    {"nombre":"Bellaco","departamento":"Río Negro","tipo":"village","osm":"node/1370494498","lat":-32.763295,"lon":-57.881223,"bbox":[-57.882011,-32.767204,-57.87927,-32.7629]},
    {"nombre":"Fray Bentos","departamento":"Río Negro","tipo":"city","osm":"node/313943603","lat":-33.116517,"lon":-58.313098,"bbox":[-58.322055,-33.14554,-58.275813,-33.108044]},
    {"nombre":"Grecco","departamento":"Río Negro","tipo":"village","osm":"node/1370538354","lat":-32.815622,"lon":-57.043081,"bbox":[-57.054678,-32.822682,-57.033485,-32.810781]},
    {"nombre":"Las Cañas","departamento":"Río Negro","tipo":"village","osm":"node/1370506418","lat":-33.164637,"lon":-58.355935,"bbox":[-58.360487,-33.18063,-58.351906,-33.158396]},
    {"nombre":"Los Arrayanes","departamento":"Río Negro","tipo":"village","osm":"node/1370506421","lat":-33.236175,"lon":-58.038236,"bbox":[-58.042556,-33.240224,-58.020432,-33.221616]},
    {"nombre":"Los Mellizos","departamento":"Río Negro","tipo":"village","osm":"node/1370559708","lat":-32.52001,"lon":-57.161461,"bbox":[-57.166246,-32.524867,-57.156288,-32.517927]},
    {"nombre":"Merinos","departamento":"Río Negro","tipo":"village","osm":"node/2412142715","lat":-32.387549,"lon":-56.907344,"bbox":[-56.913115,-32.389421,-56.901762,-32.386883]},
    {"nombre":"Nuevo Berlín","departamento":"Río Negro","tipo":"town","osm":"node/332595126","lat":-32.980345,"lon":-58.056946,"bbox":[-58.066016,-32.994214,-58.024696,-32.966864]},
    {"nombre":"San Javier","departamento":"Río Negro","tipo":"town","osm":"node/1338520866","lat":-32.666427,"lon":-58.133043,"bbox":[-58.140288,-32.674639,-58.123795,-32.657166]},
    {"nombre":"Villa General Borges","departamento":"Río Negro","tipo":"village","osm":"node/1370549899","lat":-32.55823,"lon":-57.388302,"bbox":[-57.393812,-32.56244,-57.382919,-32.555437]},
    {"nombre":"Young","departamento":"Río Negro","tipo":"city","osm":"node/302608467","lat":-32.699532,"lon":-57.634199,"bbox":[-57.665892,-32.722612,-57.61595,-32.684699]},
    {"nombre":"Ataques","departamento":"Rivera","tipo":"village","osm":"node/2414011470","lat":-31.207419,"lon":-55.358533,"bbox":[-55.36543,-31.21365,-55.352452,-31.195516]},
    {"nombre":"Lagos del Norte","departamento":"Rivera","tipo":"village","osm":"node/1324273302","lat":-30.983393,"lon":-55.498933,"bbox":[-55.504336,-30.989992,-55.4874,-30.974977]},
    {"nombre":"Lapuente","departamento":"Rivera","tipo":"village","osm":"node/1326819148","lat":-31.468795,"lon":-54.963145,"bbox":[-54.977407,-31.482273,-54.955744,-31.464713]},
    {"nombre":"Las Flores","departamento":"Rivera","tipo":"village","osm":"node/1327853937","lat":-31.782284,"lon":-55.198231,"bbox":[-55.203276,-31.789299,-55.18061,-31.775734]},
    {"nombre":"Masoller","departamento":"Rivera","tipo":"village","osm":"node/1316796507","lat":-31.083952,"lon":-56.00273,"bbox":[-56.013203,-31.086655,-55.992677,-31.081564]},
    {"nombre":"Minas de Corrales","departamento":"Rivera","tipo":"town","osm":"node/1326660491","lat":-31.569161,"lon":-55.473023,"bbox":[-55.485864,-31.584324,-55.461723,-31.563393]},
    {"nombre":"Moirones","departamento":"Rivera","tipo":"village","osm":"node/1326769284","lat":-31.604134,"lon":-54.983954,"bbox":[-54.987377,-31.60702,-54.974944,-31.601873]},
    {"nombre":"Paso Hospital","departamento":"Rivera","tipo":"village","osm":"node/1326819161","lat":-31.654542,"lon":-54.62026,"bbox":[-54.62378,-31.657571,-54.617899,-31.64678]},
    {"nombre":"Rivera","departamento":"Rivera","tipo":"city","osm":"node/886601234","lat":-30.900058,"lon":-55.540815,"bbox":[-55.599484,-30.944727,-55.507987,-30.869216]},
    {"nombre":"Tranqueras","departamento":"Rivera","tipo":"town","osm":"node/416475285","lat":-31.192619,"lon":-55.76296,"bbox":[-55.77848,-31.205785,-55.745273,-31.178658]},
    {"nombre":"Vichadero","departamento":"Rivera","tipo":"town","osm":"node/1326819128","lat":-31.778955,"lon":-54.692358,"bbox":[-54.701212,-31.787441,-54.682968,-31.767667]},
    {"nombre":"18 de Julio","departamento":"Rocha","tipo":"town","osm":"node/1321056502","lat":-33.684473,"lon":-53.554707,"bbox":[-53.562712,-33.688951,-53.541093,-33.677358]},
    {"nombre":"Aguas Dulces","departamento":"Rocha","tipo":"village","osm":"node/850125032","lat":-34.276636,"lon":-53.781496,"bbox":[-53.794565,-34.286264,-53.77329,-34.268854]},
    {"nombre":"Arachania","departamento":"Rocha","tipo":"village","osm":"node/1324050202","lat":-34.615764,"lon":-54.152343,"bbox":[-54.162372,-34.62421,-54.143579,-34.609606]},
    {"nombre":"Barra de Valizas","departamento":"Rocha","tipo":"village","osm":"node/440376476","lat":-34.336982,"lon":-53.792813,"bbox":[-53.805275,-34.344113,-53.78825,-34.327188]},
    {"nombre":"Barra del Chuy","departamento":"Rocha","tipo":"village","osm":"node/1323136291","lat":-33.755135,"lon":-53.389002,"bbox":[-53.398652,-33.759866,-53.369546,-33.743283]},
    {"nombre":"Barrio Pereira","departamento":"Rocha","tipo":"village","osm":"node/1324180386","lat":-33.883883,"lon":-53.521107,"bbox":[-53.523748,-33.892144,-53.517024,-33.881301]},
    {"nombre":"Capacho","departamento":"Rocha","tipo":"village","osm":"node/1323144157","lat":-33.894928,"lon":-53.52882,"bbox":[-53.533217,-33.897406,-53.524894,-33.892224]},
    {"nombre":"Castillos","departamento":"Rocha","tipo":"town","osm":"node/2550696128","lat":-34.200302,"lon":-53.860836,"bbox":[-53.883503,-34.206998,-53.836551,-34.185151]},
    {"nombre":"Cebollatí","departamento":"Rocha","tipo":"town","osm":"node/1323120066","lat":-33.268253,"lon":-53.796058,"bbox":[-53.802106,-33.276289,-53.785162,-33.260473]},
    {"nombre":"Chuy","departamento":"Rocha","tipo":"city","osm":"node/429433844","lat":-33.693795,"lon":-53.456111,"bbox":[-53.479964,-33.703534,-53.439344,-33.691447]},
    {"nombre":"La Aguada - Costa Azul","departamento":"Rocha","tipo":"town","osm":"node/1324050051","lat":-34.638864,"lon":-54.157345,"bbox":[-54.165659,-34.646228,-54.149464,-34.620858]},
    {"nombre":"La Coronilla","departamento":"Rocha","tipo":"village","osm":"node/1323144154","lat":-33.896136,"lon":-53.515474,"bbox":[-53.524464,-33.905409,-53.501557,-33.883723]},
    {"nombre":"La Esmeralda","departamento":"Rocha","tipo":"village","osm":"node/1323118285","lat":-34.158977,"lon":-53.688992,"bbox":[-53.720322,-34.180591,-53.665992,-34.137343]},
    {"nombre":"La Paloma","departamento":"Rocha","tipo":"town","osm":"node/332286942","lat":-34.663181,"lon":-54.155092,"bbox":[-54.218326,-34.669343,-54.139631,-34.632102]},
    {"nombre":"La Pedrera","departamento":"Rocha","tipo":"village","osm":"node/440377108","lat":-34.591495,"lon":-54.126862,"bbox":[-54.135672,-34.598657,-54.119929,-34.582995]},
    {"nombre":"Lascano","departamento":"Rocha","tipo":"town","osm":"node/1323105786","lat":-33.673845,"lon":-54.207854,"bbox":[-54.215393,-33.690443,-54.195842,-33.654059]},
    {"nombre":"Puimayen","departamento":"Rocha","tipo":"town","osm":"node/1323136297","lat":-33.763788,"lon":-53.401335,"bbox":[-53.419503,-33.779611,-53.389266,-33.756919]},
    {"nombre":"Punta del Diablo","departamento":"Rocha","tipo":"town","osm":"node/427855531","lat":-34.04491,"lon":-53.539809,"bbox":[-53.574063,-34.056777,-53.533511,-34.028443]},
    {"nombre":"Rocha","departamento":"Rocha","tipo":"city","osm":"node/321555078","lat":-34.481009,"lon":-54.336561,"bbox":[-54.357766,-34.504078,-54.294231,-34.455066]},
    {"nombre":"San Luis al Medio","departamento":"Rocha","tipo":"village","osm":"node/1321263338","lat":-33.60432,"lon":-53.717148,"bbox":[-53.724919,-33.609696,-53.709465,-33.598356]},
    {"nombre":"San Sebastián de La Pedrera","departamento":"Rocha","tipo":"village","osm":"node/7428240401","lat":-34.59747,"lon":-54.134322,"bbox":[-54.14026,-34.602222,-54.127675,-34.593296]},
    {"nombre":"Velázquez","departamento":"Rocha","tipo":"village","osm":"node/1323105790","lat":-34.037697,"lon":-54.282138,"bbox":[-54.288672,-34.043751,-54.272506,-34.022676]},
    {"nombre":"Albisu","departamento":"Salto","tipo":"village","osm":"node/1366056572","lat":-31.384231,"lon":-57.814646,"bbox":[-57.817239,-31.386422,-57.81257,-31.381998]},
    {"nombre":"Belén","departamento":"Salto","tipo":"town","osm":"node/1306015362","lat":-30.789358,"lon":-57.779073,"bbox":[-57.786359,-30.795061,-57.766858,-30.777674]},
    {"nombre":"Biassini","departamento":"Salto","tipo":"village","osm":"node/1306016716","lat":-31.277624,"lon":-57.1263,"bbox":[-57.12889,-31.280823,-57.11641,-31.273482]},
    {"nombre":"Campo de Todos","departamento":"Salto","tipo":"village","osm":"node/2613811247","lat":-31.559294,"lon":-57.614582,"bbox":[-57.626185,-31.578079,-57.6091,-31.552085]},
    {"nombre":"Colonia 18 de Julio","departamento":"Salto","tipo":"village","osm":"node/1366070401","lat":-31.356332,"lon":-57.873987,"bbox":[-57.876798,-31.362273,-57.86965,-31.351984]},
    {"nombre":"Colonia Itapebí","departamento":"Salto","tipo":"village","osm":"node/1366168574","lat":-31.33696,"lon":-57.407957,"bbox":[-57.410735,-31.341106,-57.402369,-31.335375]},
    {"nombre":"Constitución","departamento":"Salto","tipo":"town","osm":"node/1366168572","lat":-31.067196,"lon":-57.849363,"bbox":[-57.862705,-31.079052,-57.83945,-31.060831]},
    {"nombre":"Garibaldi","departamento":"Salto","tipo":"village","osm":"node/1366070394","lat":-31.339418,"lon":-57.828909,"bbox":[-57.830674,-31.344328,-57.823036,-31.333744]},
    {"nombre":"Pueblo Fernández","departamento":"Salto","tipo":"village","osm":"node/1366782017","lat":-31.178299,"lon":-56.366854,"bbox":[-56.387195,-31.196102,-56.356804,-31.17164]},
    {"nombre":"Pueblo Lavalleja","departamento":"Salto","tipo":"town","osm":"node/1306015226","lat":-31.095832,"lon":-57.024975,"bbox":[-57.065591,-31.107013,-57.018697,-31.092457]},
    {"nombre":"Rincón de Valentín","departamento":"Salto","tipo":"village","osm":"node/1306016844","lat":-31.282168,"lon":-57.199226,"bbox":[-57.20297,-31.286039,-57.195409,-31.279986]},
    {"nombre":"Salto","departamento":"Salto","tipo":"city","osm":"node/332268980","lat":-31.38889,"lon":-57.960888,"bbox":[-57.996522,-31.416169,-57.879176,-31.362902]},
    {"nombre":"San Antonio","departamento":"Salto","tipo":"village","osm":"node/1366056518","lat":-31.357402,"lon":-57.766915,"bbox":[-57.774924,-31.364374,-57.754024,-31.347611]},
    {"nombre":"Saucedo","departamento":"Salto","tipo":"village","osm":"node/1366168561","lat":-31.107206,"lon":-57.529144,"bbox":[-57.535433,-31.109363,-57.526675,-31.105723]},
    {"nombre":"Termas del Daymán","departamento":"Salto","tipo":"village","osm":"node/1366168599","lat":-31.452502,"lon":-57.908361,"bbox":[-57.918088,-31.45947,-57.902393,-31.442135]},
    {"nombre":"18 de Julio","departamento":"San José","tipo":"village","osm":"node/471564637","lat":-34.441572,"lon":-56.443369,"bbox":[-56.45412,-34.445587,-56.438909,-34.438122]},
    {"nombre":"Capurro","departamento":"San José","tipo":"village","osm":"node/471564640","lat":-34.434041,"lon":-56.464716,"bbox":[-56.469914,-34.439061,-56.456845,-34.420035]},
    {"nombre":"Ciudad del Plata","departamento":"San José","tipo":"city","osm":"node/2102107935","lat":-34.751531,"lon":-56.420575,"bbox":[-56.467975,-34.783213,-56.347637,-34.724353]},
    {"nombre":"Cololó Tinosa","departamento":"San José","tipo":"village","osm":"node/470781781","lat":-34.61493,"lon":-56.655726,"bbox":[-56.659572,-34.616909,-56.653392,-34.612129]},
    {"nombre":"Ecilda Paullier","departamento":"San José","tipo":"town","osm":"node/471550935","lat":-34.360695,"lon":-57.050105,"bbox":[-57.0646,-34.368104,-57.039089,-34.345154]},
    {"nombre":"González","departamento":"San José","tipo":"village","osm":"node/471558448","lat":-34.22918,"lon":-56.876151,"bbox":[-56.88308,-34.237886,-56.87084,-34.226224]},
    {"nombre":"Ituzaingó","departamento":"San José","tipo":"village","osm":"node/471564638","lat":-34.420459,"lon":-56.423666,"bbox":[-56.431838,-34.425254,-56.419547,-34.415785]},
    {"nombre":"Juan Soler","departamento":"San José","tipo":"town","osm":"node/471558446","lat":-34.322568,"lon":-56.805487,"bbox":[-56.809396,-34.328801,-56.794311,-34.31938]},
    {"nombre":"Kiyú - Ordeig","departamento":"San José","tipo":"village","osm":"node/471550937","lat":-34.698971,"lon":-56.735965,"bbox":[-56.770312,-34.707964,-56.691546,-34.689536]},
    {"nombre":"Las Violetas","departamento":"San José","tipo":"village","osm":"node/11675734131","lat":-34.745258,"lon":-56.42246,"bbox":null},
    {"nombre":"Libertad","departamento":"San José","tipo":"city","osm":"node/470781780","lat":-34.631016,"lon":-56.61649,"bbox":[-56.64231,-34.652303,-56.599783,-34.619483]},
    {"nombre":"Mal Abrigo","departamento":"San José","tipo":"village","osm":"node/471558447","lat":-34.146399,"lon":-56.952873,"bbox":null},
    {"nombre":"Playa Linda","departamento":"San José","tipo":"village","osm":"node/11675734132","lat":-34.747941,"lon":-56.425807,"bbox":null},
    {"nombre":"Puntas de Valdez","departamento":"San José","tipo":"town","osm":"node/470781776","lat":-34.58584,"lon":-56.700682,"bbox":[-56.710597,-34.590796,-56.691835,-34.580014]},
    {"nombre":"Radial Ruta 3","departamento":"San José","tipo":"village","osm":"node/470781777","lat":-34.551412,"lon":-56.758189,"bbox":[-56.764008,-34.554805,-56.750037,-34.543432]},
    {"nombre":"Rafael Perazza","departamento":"San José","tipo":"town","osm":"node/470781778","lat":-34.523837,"lon":-56.796984,"bbox":[-56.801951,-34.528319,-56.787552,-34.51861]},
    {"nombre":"Raigón","departamento":"San José","tipo":"village","osm":"node/471558449","lat":-34.340571,"lon":-56.66421,"bbox":[-56.674186,-34.345559,-56.659454,-34.335606]},
    {"nombre":"Rincón del Pino","departamento":"San José","tipo":"village","osm":"node/471550932","lat":-34.503131,"lon":-56.834155,"bbox":[-56.838623,-34.505754,-56.832478,-34.500566]},
    {"nombre":"Rodríguez","departamento":"San José","tipo":"town","osm":"node/471561334","lat":-34.380674,"lon":-56.539069,"bbox":[-56.54741,-34.388131,-56.528252,-34.369204]},
    {"nombre":"San José","departamento":"San José","tipo":"city","osm":"node/302608868","lat":-34.339537,"lon":-56.713993,"bbox":[-56.739301,-34.361633,-56.686976,-34.315024]},
    {"nombre":"San Luis","departamento":"San José","tipo":"village","osm":"node/11675734135","lat":-34.729326,"lon":-56.460333,"bbox":null},
    {"nombre":"Santa Maria","departamento":"San José","tipo":"village","osm":"node/11675734134","lat":-34.741391,"lon":-56.43729,"bbox":null},
    {"nombre":"Villa María","departamento":"San José","tipo":"village","osm":"node/470781779","lat":-34.51422,"lon":-56.760592,"bbox":[-56.769032,-34.518977,-56.758724,-34.511143]},
    {"nombre":"Agraciada","departamento":"Soriano","tipo":"village","osm":"node/1969333020","lat":-33.808454,"lon":-58.26543,"bbox":[-58.271208,-33.814081,-58.26207,-33.807497]},
    {"nombre":"Cañada Nieto","departamento":"Soriano","tipo":"village","osm":"node/698623074","lat":-33.698565,"lon":-58.109437,"bbox":[-58.116441,-33.702042,-58.102619,-33.695843]},
    {"nombre":"Cardona","departamento":"Soriano","tipo":"town","osm":"node/1156306843","lat":-33.870754,"lon":-57.367137,"bbox":[-57.38172,-33.878679,-57.354796,-33.859871]},
    {"nombre":"Chacras de Dolores","departamento":"Soriano","tipo":"town","osm":"node/1328856205","lat":-33.550905,"lon":-58.215285,"bbox":[-58.240264,-33.593893,-58.175625,-33.514338]},
    {"nombre":"Dolores","departamento":"Soriano","tipo":"city","osm":"node/332601915","lat":-33.53007,"lon":-58.217067,"bbox":[-58.23441,-33.549499,-58.199163,-33.516866]},
    {"nombre":"Egaña","departamento":"Soriano","tipo":"village","osm":"node/415726431","lat":-33.601464,"lon":-57.629233,"bbox":[-57.633029,-33.61137,-57.610181,-33.596874]},
    {"nombre":"José Enrique Rodó","departamento":"Soriano","tipo":"town","osm":"node/415725946","lat":-33.698049,"lon":-57.532023,"bbox":[-57.545666,-33.7084,-57.515242,-33.690421]},
    {"nombre":"Mercedes","departamento":"Soriano","tipo":"city","osm":"node/332598161","lat":-33.24842,"lon":-58.029867,"bbox":[-58.058588,-33.272415,-58.002415,-33.237876]},
    {"nombre":"Palmar","departamento":"Soriano","tipo":"village","osm":"node/1328820928","lat":-33.062623,"lon":-57.460298,"bbox":[-57.46536,-33.073642,-57.45325,-33.057118]},
    {"nombre":"Palmitas","departamento":"Soriano","tipo":"town","osm":"node/750508811","lat":-33.509189,"lon":-57.800666,"bbox":[-57.813069,-33.515301,-57.790178,-33.500325]},
    {"nombre":"Risso","departamento":"Soriano","tipo":"village","osm":"node/415726287","lat":-33.623312,"lon":-57.571732,"bbox":[-57.57523,-33.62924,-57.568191,-33.618209]},
    {"nombre":"Sacachispas","departamento":"Soriano","tipo":"village","osm":"node/1328820921","lat":-33.117428,"lon":-57.633116,"bbox":[-57.641547,-33.123728,-57.621237,-33.11471]},
    {"nombre":"Santa Catalina","departamento":"Soriano","tipo":"town","osm":"node/415725702","lat":-33.792414,"lon":-57.485704,"bbox":[-57.496004,-33.799254,-57.479246,-33.782985]},
    {"nombre":"Villa Soriano","departamento":"Soriano","tipo":"town","osm":"node/718466201","lat":-33.393906,"lon":-58.319761,"bbox":[-58.328194,-33.406977,-58.314079,-33.389344]},
    {"nombre":"Achar","departamento":"Tacuarembó","tipo":"village","osm":"node/1366920073","lat":-32.407401,"lon":-56.182341,"bbox":[-56.186734,-32.410197,-56.173766,-32.398172]},
    {"nombre":"Ansina","departamento":"Tacuarembó","tipo":"town","osm":"node/353721371","lat":-31.878069,"lon":-55.46259,"bbox":[-55.472743,-31.884628,-55.45184,-31.871799]},
    {"nombre":"Balneario Iporá","departamento":"Tacuarembó","tipo":"village","osm":"node/1367063989","lat":-31.668282,"lon":-55.956481,"bbox":[-55.967883,-31.672018,-55.950562,-31.662615]},
    {"nombre":"Cruz de los Caminos","departamento":"Tacuarembó","tipo":"village","osm":"node/2405521209","lat":-32.232389,"lon":-54.966021,"bbox":[-54.988654,-32.238455,-54.962778,-32.215648]},
    {"nombre":"Cuchilla de Peralta","departamento":"Tacuarembó","tipo":"village","osm":"node/1366820613","lat":-32.493915,"lon":-56.355579,"bbox":[-56.358636,-32.497533,-56.352282,-32.487033]},
    {"nombre":"Curtina","departamento":"Tacuarembó","tipo":"town","osm":"node/1366919634","lat":-32.149611,"lon":-56.11716,"bbox":[-56.120848,-32.155423,-56.110926,-32.137247]},
    {"nombre":"Las Toscas de Caraguatá","departamento":"Tacuarembó","tipo":"town","osm":"node/1367166577","lat":-32.185046,"lon":-55.008905,"bbox":null},
    {"nombre":"Paso Bonilla","departamento":"Tacuarembó","tipo":"village","osm":"node/1366919779","lat":-31.808515,"lon":-55.97716,"bbox":[-55.978978,-31.81203,-55.975701,-31.802065]},
    {"nombre":"Paso de los Toros","departamento":"Tacuarembó","tipo":"city","osm":"node/671778599","lat":-32.810809,"lon":-56.517495,"bbox":[-56.540668,-32.822489,-56.494964,-32.787839]},
    {"nombre":"Paso del Cerro","departamento":"Tacuarembó","tipo":"village","osm":"node/1369151062","lat":-31.479052,"lon":-55.832233,"bbox":[-55.838327,-31.482922,-55.827598,-31.473351]},
    {"nombre":"San Gregorio de Polanco","departamento":"Tacuarembó","tipo":"town","osm":"node/1335909480","lat":-32.618052,"lon":-55.834555,"bbox":[-55.852101,-32.624299,-55.809088,-32.586673]},
    {"nombre":"Tacuarembó","departamento":"Tacuarembó","tipo":"city","osm":"node/302666274","lat":-31.711018,"lon":-55.978876,"bbox":[-56.042473,-31.751054,-55.932332,-31.682281]},
    {"nombre":"Tambores","departamento":"Tacuarembó","tipo":"town","osm":"node/8295489019","lat":-31.872889,"lon":-56.245137,"bbox":[-56.252057,-31.889268,-56.238432,-31.869498]},
    {"nombre":"Cerro Chato","departamento":"Treinta y Tres","tipo":"village","osm":"node/8310185667","lat":-33.104469,"lon":-55.134686,"bbox":[-55.141515,-33.111304,-55.131748,-33.10169]},
    {"nombre":"La Charqueada","departamento":"Treinta y Tres","tipo":"town","osm":"node/1374865146","lat":-33.205385,"lon":-53.805936,"bbox":[-53.814329,-33.210551,-53.797647,-33.19646]},
    {"nombre":"Rincón","departamento":"Treinta y Tres","tipo":"village","osm":"node/1354019486","lat":-32.833524,"lon":-53.83249,"bbox":[-53.835705,-32.838284,-53.819015,-32.825188]},
    {"nombre":"Santa Clara de Olimar","departamento":"Treinta y Tres","tipo":"town","osm":"node/1354055747","lat":-32.923541,"lon":-54.944498,"bbox":[-54.964642,-32.930683,-54.916481,-32.914238]},
    {"nombre":"Treinta y Tres","departamento":"Treinta y Tres","tipo":"city","osm":"node/1374267802","lat":-33.231571,"lon":-54.386259,"bbox":[-54.409115,-33.26539,-54.335655,-33.196478]},
    {"nombre":"Vergara","departamento":"Treinta y Tres","tipo":"town","osm":"node/1374937529","lat":-32.937673,"lon":-53.937754,"bbox":[-53.95753,-32.953528,-53.925051,-32.933981]},
    {"nombre":"Villa Sara","departamento":"Treinta y Tres","tipo":"town","osm":"node/1374975038","lat":-33.253978,"lon":-54.414073,"bbox":[-54.427581,-33.26479,-54.400154,-33.238156]}
  ],
  "descartados": [
    {"osm":"node/1969333020","nombre":"Agraciada","motivo":"está en varios departamentos; queda en Soriano, no en Colonia"},
    {"osm":"node/2412142715","nombre":"Merinos","motivo":"está en varios departamentos; queda en Río Negro, no en Paysandú"},
    {"osm":"node/8295489019","nombre":"Tambores","motivo":"está en varios departamentos; queda en Tacuarembó, no en Paysandú"},
    {"osm":"node/8310185667","nombre":"Cerro Chato","motivo":"está en varios departamentos; queda en Treinta y Tres, no en Durazno"},
    {"osm":"node/8310185667","nombre":"Cerro Chato","motivo":"está en varios departamentos; queda en Treinta y Tres, no en Florida"}
  ]
}
$catalogo$::jsonb $f$;

comment on function public.catalogo_osm_uruguay() is
  'El catálogo de Uruguay de OpenStreetMap (0109, backend-supabase#139): país, 19 departamentos con su rectángulo y '
  'ciudades, pueblos y villas con su departamento, su centro y su rectángulo si OSM trae el límite. Es la copia en '
  'la base de tiles/datos/uruguay-osm.json (© OpenStreetMap contributors, ODbL 1.0; la fuente y la fecha de los '
  'datos van en `fuente`). Interna: la usan cargar_catalogo_ciudades(), departamentos_de_uruguay() y '
  'agregar_ciudad_a_mano().';

revoke all on function public.catalogo_osm_uruguay()
  from public, anon, authenticated, service_role;
grant execute on function public.catalogo_osm_uruguay() to service_role;

create function public.departamentos_de_uruguay()
returns setof text
language sql
stable
security definer
set search_path = ''
as $$
  select d.nombre
    from jsonb_to_recordset(public.catalogo_osm_uruguay() -> 'departamentos') as d(nombre text)
   order by public.normalizar_busqueda(d.nombre), d.nombre;
$$;

comment on function public.departamentos_de_uruguay() is
  'Los 19 departamentos de Uruguay, A-Z, con el nombre de la lista de OpenStreetMap (0109, backend-supabase#139). '
  'Lo que leen los selectores de departamento: el departamento se elige, nunca se escribe.';

revoke all on function public.departamentos_de_uruguay()
  from public, anon, authenticated, service_role;
grant execute on function public.departamentos_de_uruguay() to authenticated, service_role;

-- ----------------------------------------------------------------------------
-- 3. La distancia de edición (para el aviso de parecido)
-- ----------------------------------------------------------------------------

create function public.distancia_de_edicion(p_a text, p_b text)
returns integer
language plpgsql
immutable
set search_path = ''
as $$
declare
  v_a      text := left(coalesce(p_a, ''), 100);
  v_b      text := left(coalesce(p_b, ''), 100);
  v_la     integer := char_length(v_a);
  v_lb     integer := char_length(v_b);
  v_previa integer[];
  v_actual integer[];
  v_costo  integer;
begin
  if v_la = 0 then
    return v_lb;
  end if;
  if v_lb = 0 then
    return v_la;
  end if;

  -- Levenshtein por filas: v_previa[j + 1] = distancia entre los primeros i - 1 de a y los primeros j de b.
  v_previa := array(select generate_series(0, v_lb));
  for i in 1 .. v_la loop
    v_actual := array[i];
    for j in 1 .. v_lb loop
      v_costo := case when substr(v_a, i, 1) = substr(v_b, j, 1) then 0 else 1 end;
      v_actual := v_actual || least(v_actual[j] + 1, v_previa[j + 1] + 1, v_previa[j] + v_costo);
    end loop;
    v_previa := v_actual;
  end loop;
  return v_previa[v_lb + 1];
end;
$$;

comment on function public.distancia_de_edicion(text, text) is
  'Distancia de Levenshtein entre dos textos (hasta 100 caracteres de cada uno). Interna (0109): '
  'agregar_ciudad_a_mano() la usa para avisar de un nombre parecido.';

revoke all on function public.distancia_de_edicion(text, text)
  from public, anon, authenticated, service_role;

-- ----------------------------------------------------------------------------
-- 4. La carga del catálogo en ciudad
-- ----------------------------------------------------------------------------

-- La lista como filas: una por (nombre, departamento) normalizados, con las claves de comparación ya calculadas.
create function public.filas_del_catalogo(p_catalogo jsonb)
returns table (nombre_n text, departamento_n text, nombre text, departamento text,
               lat double precision, lon double precision,
               oeste double precision, sur double precision, este double precision, norte double precision)
language sql
immutable
set search_path = ''
as $$
  select distinct on (public.normalizar_busqueda(x.nombre), public.normalizar_busqueda(x.departamento))
         public.normalizar_busqueda(x.nombre),
         public.normalizar_busqueda(x.departamento),
         x.nombre, x.departamento, x.lat, x.lon,
         (x.bbox ->> 0)::double precision, (x.bbox ->> 1)::double precision,
         (x.bbox ->> 2)::double precision, (x.bbox ->> 3)::double precision
    from jsonb_to_recordset(p_catalogo -> 'ciudades')
           as x(nombre text, departamento text, lat double precision, lon double precision, bbox jsonb)
   where public.normalizar_busqueda(x.nombre) is not null
     and public.normalizar_busqueda(x.departamento) is not null
   order by public.normalizar_busqueda(x.nombre), public.normalizar_busqueda(x.departamento), x.nombre, x.departamento, x.lat, x.lon;
$$;

comment on function public.filas_del_catalogo(jsonb) is
  'Las ciudades de un catálogo (catalogo_osm_uruguay()) como filas, una por nombre y departamento normalizados, con '
  'el rectángulo en cuatro columnas (null si OSM no trae el límite). Interna (0109): la usa cargar_catalogo_ciudades().';

revoke all on function public.filas_del_catalogo(jsonb)
  from public, anon, authenticated, service_role;

create function public.cargar_catalogo_ciudades(p_catalogo jsonb default null)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_catalogo     jsonb := coalesce(p_catalogo, public.catalogo_osm_uruguay());
  v_pais         uuid;
  v_emparejadas  integer;
  v_actualizadas integer;
  v_insertadas   integer;
  v_sin_pareja   jsonb;
  v_cantidad     integer;
  v_primeras     text;
begin
  select p.id
    into v_pais
    from public.pais p
   where p.iso_code = 'UY'
     and p.deleted_at is null;

  if v_pais is null then
    raise notice 'cargar_catalogo_ciudades: la base no tiene el país Uruguay (public.pais, iso_code UY): no se cargó ninguna ciudad. Cargá el país (docs/guia-carga-manual.md § 1) y corré: select public.cargar_catalogo_ciudades();';
    return jsonb_build_object('pais', false, 'emparejadas', 0, 'actualizadas', 0, 'insertadas', 0, 'sin_pareja', '[]'::jsonb);
  end if;

  -- Cuántas de la lista ya estaban (vivas o dadas de baja).
  select count(*)
    into v_emparejadas
    from public.filas_del_catalogo(v_catalogo) l
   where exists (select 1
                   from public.ciudad c
                  where c.pais_id = v_pais
                    and public.normalizar_busqueda(c.nombre) = l.nombre_n
                    and public.normalizar_busqueda(c.departamento) = l.departamento_n);

  -- Las vivas que casan: origen OSM, el departamento escrito como en la lista y, si no tenían rectángulo y el de OSM
  -- contiene a su centro, ese. Solo se toca la fila que cambia algo (una segunda corrida no sube ninguna versión).
  with candidatas as (
    select c.id, c.origen, c.departamento as departamento_actual, l.departamento, l.oeste, l.sur, l.este, l.norte,
           (c.bbox_oeste is null and l.oeste is not null
            and c.lon_centro between l.oeste and l.este and c.lat_centro between l.sur and l.norte) as pone_rectangulo
      from public.ciudad c
      join public.filas_del_catalogo(v_catalogo) l
        on public.normalizar_busqueda(c.nombre) = l.nombre_n
       and public.normalizar_busqueda(c.departamento) = l.departamento_n
     where c.pais_id = v_pais
       and c.deleted_at is null
  ),
  cambios as (
    update public.ciudad c
       set origen       = 'OSM',
           departamento = k.departamento,
           bbox_oeste   = case when k.pone_rectangulo then k.oeste  else c.bbox_oeste end,
           bbox_sur     = case when k.pone_rectangulo then k.sur    else c.bbox_sur end,
           bbox_este    = case when k.pone_rectangulo then k.este   else c.bbox_este end,
           bbox_norte   = case when k.pone_rectangulo then k.norte  else c.bbox_norte end
      from candidatas k
     where c.id = k.id
       and (k.origen is distinct from 'OSM'
            or k.departamento_actual is distinct from k.departamento
            or k.pone_rectangulo)
    returning c.id
  )
  select count(*) into v_actualizadas from cambios;

  -- Las que faltan.
  with nuevas as (
    insert into public.ciudad (nombre, departamento, pais_id, lat_centro, lon_centro,
                               bbox_oeste, bbox_sur, bbox_este, bbox_norte, origen)
    select l.nombre, l.departamento, v_pais, l.lat, l.lon, l.oeste, l.sur, l.este, l.norte, 'OSM'
      from public.filas_del_catalogo(v_catalogo) l
     where not exists (select 1
                         from public.ciudad c
                        where c.pais_id = v_pais
                          and public.normalizar_busqueda(c.nombre) = l.nombre_n
                          and public.normalizar_busqueda(c.departamento) = l.departamento_n)
    returning id
  )
  select count(*) into v_insertadas from nuevas;

  -- Las que ya estaban y no casan: se avisan, no se tocan.
  select coalesce(jsonb_agg(jsonb_build_object('ciudad_id', c.id, 'nombre', c.nombre, 'departamento', c.departamento)
                            order by public.normalizar_busqueda(c.nombre), c.id), '[]'::jsonb)
    into v_sin_pareja
    from public.ciudad c
   where c.pais_id = v_pais
     and c.deleted_at is null
     and not exists (select 1
                       from public.filas_del_catalogo(v_catalogo) l
                      where l.nombre_n = public.normalizar_busqueda(c.nombre)
                        and l.departamento_n = public.normalizar_busqueda(c.departamento));

  v_cantidad := jsonb_array_length(v_sin_pareja);
  if v_cantidad > 0 then
    select string_agg(format('%s (%s)', t.e ->> 'nombre', coalesce(t.e ->> 'departamento', 'sin departamento')), ', ')
      into v_primeras
      from (select j.e from jsonb_array_elements(v_sin_pareja) as j(e) limit 20) t;
    raise notice 'cargar_catalogo_ciudades: % ciudades que ya estaban no figuran en la lista de OpenStreetMap (con ese nombre y departamento); no se borraron ni se tocaron: %',
      v_cantidad, v_primeras || case when v_cantidad > 20 then ' ... (la lista entera está en la respuesta, «sin_pareja»)' else '' end;
  end if;

  return jsonb_build_object('pais', true, 'emparejadas', v_emparejadas, 'actualizadas', v_actualizadas,
                            'insertadas', v_insertadas, 'sin_pareja', v_sin_pareja);
end;
$$;

comment on function public.cargar_catalogo_ciudades(jsonb) is
  'Carga el catálogo de Uruguay de OpenStreetMap en public.ciudad sin borrar ni duplicar (0109, backend-supabase#139). '
  'Empareja por nombre y departamento normalizados (también con las dadas de baja); las que casan quedan origen OSM; '
  'las que faltan se agregan; las que ya estaban y no casan se avisan en `sin_pareja` y no se tocan. Idempotente. '
  'Sin país UY no carga nada y avisa. Solo service_role. Devuelve {pais, emparejadas, actualizadas, insertadas, sin_pareja}.';

revoke all on function public.cargar_catalogo_ciudades(jsonb)
  from public, anon, authenticated, service_role;
grant execute on function public.cargar_catalogo_ciudades(jsonb) to service_role;

-- ----------------------------------------------------------------------------
-- 5. El alta a mano
-- ----------------------------------------------------------------------------

create function public.agregar_ciudad_a_mano(p_nombre text, p_departamento text)
returns table (ciudad_id uuid, parecidas jsonb)
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_nombre       text := btrim(regexp_replace(coalesce(p_nombre, ''), '\s+', ' ', 'g'));
  v_nombre_n     text := public.normalizar_busqueda(p_nombre);
  v_departamento text;
  v_dep_n        text;
  v_bbox         jsonb;
  v_pais         uuid;
  v_id           uuid;
  v_parecidas    jsonb;
begin
  if v_nombre = '' or char_length(v_nombre) > 100 then
    raise exception using
      errcode = 'CD002',
      message = 'Escribí el nombre de la ciudad (hasta 100 caracteres)',
      hint = 'El alta a mano lleva solo el nombre y el departamento de la lista (HU-ADM-005).';
  end if;

  select d.nombre, d.bbox
    into v_departamento, v_bbox
    from jsonb_to_recordset(public.catalogo_osm_uruguay() -> 'departamentos') as d(nombre text, bbox jsonb)
   where public.normalizar_busqueda(d.nombre) = public.normalizar_busqueda(p_departamento);

  if v_departamento is null then
    raise exception using
      errcode = 'CD003',
      message = 'Elegí el departamento de la lista',
      hint = 'El departamento se elige de los 19 de Uruguay (public.departamentos_de_uruguay()), nunca se escribe.';
  end if;
  v_dep_n := public.normalizar_busqueda(v_departamento);

  select p.id
    into v_pais
    from public.pais p
   where p.iso_code = 'UY'
     and p.deleted_at is null;

  if v_pais is null then
    raise exception using
      errcode = 'CD004',
      message = 'Falta cargar el país Uruguay',
      hint = 'Cargá el país (docs/guia-carga-manual.md § 1) y volvé a agregar la ciudad.';
  end if;

  -- Las que ya estaban y se le parecen (se mira ANTES de agregarla, para no encontrarse a sí misma).
  select coalesce(jsonb_agg(jsonb_build_object('ciudad_id', t.id, 'nombre', t.nombre, 'departamento', t.departamento,
                                               'origen', t.origen, 'motivo', t.motivo)
                            order by t.prioridad, t.distancia, t.nombre_n, t.id), '[]'::jsonb)
    into v_parecidas
    from (select c.id, c.nombre, c.departamento, c.origen, f.nombre_n,
                 case when f.nombre_n = v_nombre_n and f.dep_n = v_dep_n then 'IGUAL'
                      when f.nombre_n = v_nombre_n then 'MISMO_NOMBRE_OTRO_DEPARTAMENTO'
                      else 'PARECIDO' end as motivo,
                 case when f.nombre_n = v_nombre_n and f.dep_n = v_dep_n then 1
                      when f.nombre_n = v_nombre_n then 2
                      else 3 end as prioridad,
                 f.distancia
            from public.ciudad c
           cross join lateral (select public.normalizar_busqueda(c.nombre)       as nombre_n,
                                      public.normalizar_busqueda(c.departamento) as dep_n,
                                      case when abs(char_length(public.normalizar_busqueda(c.nombre)) - char_length(v_nombre_n)) <= 2
                                           then public.distancia_de_edicion(public.normalizar_busqueda(c.nombre), v_nombre_n)
                                           else 99 end as distancia) f
           where c.pais_id = v_pais
             and c.deleted_at is null
             and f.nombre_n is not null
             and (f.nombre_n = v_nombre_n
                  or f.distancia <= case when least(char_length(f.nombre_n), char_length(v_nombre_n)) >= 8 then 2 else 1 end
                  or (least(char_length(f.nombre_n), char_length(v_nombre_n)) >= 4
                      and (strpos(f.nombre_n, v_nombre_n) > 0 or strpos(v_nombre_n, f.nombre_n) > 0)))
           order by prioridad, f.distancia, f.nombre_n, c.id
           limit 10) t;

  -- Sin rectángulo (sin mapa propio hasta tener su área); el centro es el del departamento.
  insert into public.ciudad (nombre, departamento, pais_id, lat_centro, lon_centro, origen)
  values (v_nombre, v_departamento, v_pais,
          ((v_bbox ->> 1)::double precision + (v_bbox ->> 3)::double precision) / 2,
          ((v_bbox ->> 0)::double precision + (v_bbox ->> 2)::double precision) / 2,
          'MANUAL')
  returning id into v_id;

  return query select v_id, v_parecidas;
end;
$$;

comment on function public.agregar_ciudad_a_mano(text, text) is
  'El alta a mano de una ciudad que no figura en la lista de OpenStreetMap (0109, backend-supabase#139, decisión de '
  'Cristian del 23/10, «Fuera de OSM»): solo el nombre y el departamento, que tiene que ser uno de los 19 de la lista '
  '(CD003). origen MANUAL, sin rectángulo, con el centro del departamento. El aviso de parecido NO frena: crea la '
  'ciudad y devuelve en `parecidas` las que ya estaban y se le parecen. CD002 nombre en blanco o de más de 100 '
  'caracteres; CD004 sin país UY. Solo service_role (desde el SQL Editor, docs/guia-carga-manual.md § 2).';

revoke all on function public.agregar_ciudad_a_mano(text, text)
  from public, anon, authenticated, service_role;
grant execute on function public.agregar_ciudad_a_mano(text, text) to service_role;

-- ----------------------------------------------------------------------------
-- 6. La carga de esta migración
-- ----------------------------------------------------------------------------

do $$
declare
  v_resumen jsonb;
begin
  v_resumen := public.cargar_catalogo_ciudades();
  raise notice 'catálogo de ciudades: % emparejadas, % actualizadas, % agregadas, % sin pareja (no se tocaron)',
    v_resumen ->> 'emparejadas', v_resumen ->> 'actualizadas', v_resumen ->> 'insertadas',
    jsonb_array_length(v_resumen -> 'sin_pareja');
end
$$;
