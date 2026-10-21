// Imprime "<anon> <service_role>": dos JWT HS256 firmados con el secreto dado, para el storage-api de prueba.
// Uso: node jwt.mjs <secreto>
import { createHmac } from 'node:crypto';

const secreto = process.argv[2];
if (!secreto) {
  console.error('Uso: node jwt.mjs <secreto>');
  process.exit(2);
}
const base64 = (objeto) => Buffer.from(JSON.stringify(objeto)).toString('base64url');
const jwt = (role) => {
  const cuerpo = `${base64({ alg: 'HS256', typ: 'JWT' })}.${base64({ role, iss: 'prueba-local', iat: 1_700_000_000, exp: 4_000_000_000 })}`;
  return `${cuerpo}.${createHmac('sha256', secreto).update(cuerpo).digest('base64url')}`;
};
console.log(jwt('anon'), jwt('service_role'));
