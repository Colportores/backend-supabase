// El publicador lee lo que necesita para decidir (el catálogo, si un paquete ya está) por el endpoint
// AUTENTICADO del Storage, con la clave de servicio, y no por la URL pública (que pasa por la caché).
// Esta prueba corre clienteStorage() contra el Storage real. Sale con código 1 si algo falla.
// Uso (con SUPABASE_URL y SUPABASE_SERVICE_ROLE_KEY en el entorno): node prueba-storage/lectura-autenticada.mjs
import assert from 'node:assert/strict';
import { clienteStorage } from '../src/storage.mjs';

const storage = clienteStorage({
  url: process.env.SUPABASE_URL,
  clave: process.env.SUPABASE_SERVICE_ROLE_KEY,
  esperaMs: 0,
});

const catalogo = await storage.bajarJson('catalogo.json');
assert.ok(catalogo && Array.isArray(catalogo.paquetes), 'bajarJson devuelve el catálogo publicado');
assert.ok(catalogo.paquetes.length >= 1, 'el catálogo tiene al menos un paquete');
console.log(`ok    bajarJson('catalogo.json'): ${catalogo.paquetes.length} paquete(s)`);

const archivo = catalogo.paquetes[0].partes[0].archivo;
assert.equal(await storage.existe(archivo), true, `existe(${archivo})`);
console.log(`ok    existe('${archivo}') = true`);

assert.equal(await storage.existe('paquetes/ciudad/no-existe.0000.pmtiles'), false, 'existe() de algo que no está');
console.log("ok    existe('paquetes/ciudad/no-existe.0000.pmtiles') = false");

assert.equal(await storage.bajarJson('no-existe.json'), null, 'bajarJson() de algo que no está');
console.log("ok    bajarJson('no-existe.json') = null");

console.log('\nEl publicador lee por el endpoint autenticado.');
