import { leerCuentaDeServicio } from "./fcm.ts";
import { manejar } from "./handler.ts";

// SUPABASE_URL y SUPABASE_SERVICE_ROLE_KEY los pone el runtime de las Edge Functions. Los otros dos son secretos que se
// cargan con `supabase secrets set PUSH_CLAVE=… FCM_CUENTA_DE_SERVICIO="$(cat cuenta.json)"` (README § «Puesta en
// marcha»): nunca en el código, en el repo ni en un archivo .env versionado.
const urlDeLaApi = Deno.env.get("SUPABASE_URL") ?? "";
const claveDeServicio = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
const clavePush = (Deno.env.get("PUSH_CLAVE") ?? "").trim();
const cuenta = leerCuentaDeServicio(Deno.env.get("FCM_CUENTA_DE_SERVICIO"));

Deno.serve((pedido) =>
  manejar(pedido, { fetch, urlDeLaApi, claveDeServicio, clavePush, cuenta, ahora: () => new Date() })
);
