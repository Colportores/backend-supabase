import { manejar } from "./handler.ts";

// SUPABASE_URL y SUPABASE_ANON_KEY los pone el runtime de las Edge Functions; no hay que configurar nada.
const urlDeLaApi = Deno.env.get("SUPABASE_URL") ?? "";
const clavePublica = Deno.env.get("SUPABASE_ANON_KEY") ?? "";

Deno.serve((pedido) => manejar(pedido, { fetch, urlDeLaApi, clavePublica, ahora: () => new Date() }));
