import { assert, assertEquals, assertNotEquals, assertRejects } from "@std/assert";

import { codificar, codificarRuta, firmarUrl, type ParametrosDeFirma } from "./firma.ts";

/**
 * El vector de pruebas de AWS para URLs prefirmadas de S3 («Authenticating Requests: Using Query Parameters»,
 * ejemplo del GET de `test.txt`): con estas entradas la firma tiene que ser exactamente la que publica AWS. R2 valida con
 * el mismo algoritmo, así que si este caso falla, R2 rechazaría todos los enlaces.
 */
const VECTOR_DE_AWS: ParametrosDeFirma = {
  metodo: "GET",
  host: "examplebucket.s3.amazonaws.com",
  ruta: "/test.txt",
  region: "us-east-1",
  servicio: "s3",
  claveDeAcceso: "AKIAIOSFODNN7EXAMPLE",
  claveSecreta: "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY",
  fecha: new Date("2013-05-24T00:00:00Z"),
  expiraEnSegundos: 86400,
};

function firmaDe(url: string): string {
  return new URL(url).searchParams.get("X-Amz-Signature") ?? "";
}

Deno.test("firma · coincide con el vector de pruebas de AWS", async () => {
  const url = await firmarUrl(VECTOR_DE_AWS);
  assertEquals(
    url,
    "https://examplebucket.s3.amazonaws.com/test.txt?X-Amz-Algorithm=AWS4-HMAC-SHA256" +
      "&X-Amz-Credential=AKIAIOSFODNN7EXAMPLE%2F20130524%2Fus-east-1%2Fs3%2Faws4_request" +
      "&X-Amz-Date=20130524T000000Z&X-Amz-Expires=86400&X-Amz-SignedHeaders=host" +
      "&X-Amz-Signature=aeeed9bbccd4d02ee5c0109b86d86835f995330da4c265957d157751f604d404",
  );
});

const R2: ParametrosDeFirma = {
  metodo: "PUT",
  host: "cuenta123.r2.cloudflarestorage.com",
  ruta: "/fotos-tickets/01920000-0000-7000-8000-000000000001/01920000-0000-7000-8000-0000000000aa.jpg",
  region: "auto",
  servicio: "s3",
  claveDeAcceso: "ACCESO-DE-PRUEBA",
  claveSecreta: "secreto-de-prueba",
  fecha: new Date("2026-10-28T15:00:00Z"),
  expiraEnSegundos: 600,
  cabecerasFirmadas: { "Content-Type": "image/jpeg", "Content-Length": "123456" },
};

Deno.test("firma · una subida ata el tipo y el largo (cabeceras en minúscula, ordenadas) y es determinista", async () => {
  const url = new URL(await firmarUrl(R2));
  assertEquals(url.host, "cuenta123.r2.cloudflarestorage.com");
  assertEquals(url.pathname, R2.ruta);
  assertEquals(url.searchParams.get("X-Amz-SignedHeaders"), "content-length;content-type;host");
  assertEquals(url.searchParams.get("X-Amz-Credential"), "ACCESO-DE-PRUEBA/20261028/auto/s3/aws4_request");
  assertEquals(url.searchParams.get("X-Amz-Date"), "20261028T150000Z");
  assertEquals(url.searchParams.get("X-Amz-Expires"), "600");
  assertEquals(await firmarUrl(R2), await firmarUrl({ ...R2 }));
});

Deno.test("firma · cambiar cualquier cosa que la firma ata, cambia la firma", async () => {
  const base = firmaDe(await firmarUrl(R2));
  const variantes: Partial<ParametrosDeFirma>[] = [
    { metodo: "GET" },
    { ruta: R2.ruta.replace(".jpg", ".png") },
    { fecha: new Date("2026-10-28T15:00:01Z") },
    { expiraEnSegundos: 601 },
    { claveSecreta: "otro-secreto" },
    { claveDeAcceso: "OTRO-ACCESO" },
    { cabecerasFirmadas: { "Content-Type": "image/png", "Content-Length": "123456" } },
    { cabecerasFirmadas: { "Content-Type": "image/jpeg", "Content-Length": "123457" } },
    { cabecerasFirmadas: { "Content-Type": "image/jpeg" } },
    { host: "otra.r2.cloudflarestorage.com" },
  ];
  for (const v of variantes) assertNotEquals(firmaDe(await firmarUrl({ ...R2, ...v })), base, JSON.stringify(v));
});

Deno.test("firma · la clave secreta no aparece en el enlace", async () => {
  const url = await firmarUrl(R2);
  assert(!url.includes(R2.claveSecreta));
});

Deno.test("firma · el vencimiento tiene que estar entre 1 segundo y 7 días", async () => {
  for (const expiraEnSegundos of [0, -1, 604801, 1.5, Number.NaN]) {
    await assertRejects(() => firmarUrl({ ...R2, expiraEnSegundos }), RangeError);
  }
  await firmarUrl({ ...R2, expiraEnSegundos: 1 });
  await firmarUrl({ ...R2, expiraEnSegundos: 604800 });
});

Deno.test("firma · la ruta tiene que empezar con barra", async () => {
  await assertRejects(() => firmarUrl({ ...R2, ruta: "sin-barra" }), RangeError);
});

Deno.test("codificar · lo que RFC 3986 reserva sale con porcentaje", () => {
  assertEquals(codificar("a b/c+d!'()*é"), "a%20b%2Fc%2Bd%21%27%28%29%2A%C3%A9");
  assertEquals(codificarRuta("usuario/ticket 1.jpg"), "usuario/ticket%201.jpg");
});
