import { type ConfiguracionDeR2, manejar } from "./handler.ts";

// SUPABASE_URL y SUPABASE_ANON_KEY los pone el runtime de las Edge Functions. Los secretos de R2 se cargan con
// `supabase secrets set R2_CUENTA=… R2_CLAVE_DE_ACCESO=… R2_CLAVE_SECRETA=… R2_BUCKET=…` (README § «Puesta en marcha»):
// nunca en el código, en el repo ni en un archivo .env versionado.
const urlDeLaApi = Deno.env.get("SUPABASE_URL") ?? "";
const clavePublica = Deno.env.get("SUPABASE_ANON_KEY") ?? "";

const NOMBRES_DE_R2 = ["R2_CUENTA", "R2_CLAVE_DE_ACCESO", "R2_CLAVE_SECRETA", "R2_BUCKET"] as const;

function leerR2(): ConfiguracionDeR2 | null {
  const valores = NOMBRES_DE_R2.map((nombre) => (Deno.env.get(nombre) ?? "").trim());
  const faltan = NOMBRES_DE_R2.filter((_, i) => valores[i] === "");
  if (faltan.length > 0) {
    // Solo los NOMBRES de lo que falta; jamás un valor.
    console.error(JSON.stringify({ evento: "foto-ticket.sin_configurar", faltan }));
    return null;
  }
  const [cuenta, claveDeAcceso, claveSecreta, bucket] = valores;
  return { cuenta, claveDeAcceso, claveSecreta, bucket };
}

Deno.serve((pedido) => manejar(pedido, { fetch, urlDeLaApi, clavePublica, r2: leerR2(), ahora: () => new Date() }));
