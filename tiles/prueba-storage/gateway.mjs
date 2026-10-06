// Hace de gateway de Supabase (Kong) delante de un storage-api suelto: /storage/v1/* → storage:5000/*.
// Imita el plugin `cors` de Kong con su configuración por defecto, que es la que el gateway hosteado
// le pone al Storage: Access-Control-Allow-Origin: *, el preflight lo contesta el gateway (200, con
// los headers pedidos reflejados) y no hay Access-Control-Expose-Headers.
//
// Es una IMITACIÓN: lo que el gateway del proyecto real hace de verdad lo dice `cli.mjs verificar`
// después de la primera publicación. Con CORS=0 no agrega nada: se ve lo que dice el storage-api solo.
import http from 'node:http';

const conCors = process.env.CORS !== '0';

http
  .createServer((req, res) => {
    if (!req.url.startsWith('/storage/v1/')) {
      res.writeHead(404);
      return res.end('solo /storage/v1');
    }
    if (conCors && req.method === 'OPTIONS' && req.headers.origin && req.headers['access-control-request-method']) {
      res.writeHead(200, {
        'access-control-allow-origin': '*',
        'access-control-allow-methods': 'GET,HEAD,PUT,PATCH,POST,DELETE,OPTIONS,TRACE,CONNECT',
        'access-control-allow-headers': req.headers['access-control-request-headers'] ?? '',
        'content-length': '0',
      });
      return res.end();
    }
    const arriba = http.request(
      { host: 'storage', port: 5000, method: req.method, path: req.url.slice('/storage/v1'.length), headers: { ...req.headers, host: 'storage:5000' } },
      (respuesta) => {
        const headers = { ...respuesta.headers };
        if (conCors && req.headers.origin) headers['access-control-allow-origin'] = '*';
        res.writeHead(respuesta.statusCode, headers);
        respuesta.pipe(res);
      },
    );
    arriba.on('error', (error) => {
      res.writeHead(502);
      res.end(String(error));
    });
    req.pipe(arriba);
  })
  .listen(8000, () => console.log(`gateway listo en :8000 (cors=${conCors})`));
