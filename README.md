# gateway

API gateway de Discordia, hecho con Kong.

## Tabla de contenidos

- [Introducción](#introducción)
- [Pre-requisitos](#pre-requisitos)
- [Cómo correr](#cómo-correr)
- [Variables de entorno](#variables-de-entorno)
- [Comandos Docker](#comandos-docker)
- [Formato de error](#formato-de-error)
- [Tests](#tests)
- [Más documentación](#más-documentación)

## Introducción

El gateway es el único punto de entrada a Discordia: los clientes (la web, la app y el backoffice) solo hablan con él, y él reparte cada pedido al servicio que corresponde. Hace tres cosas:

- **Enruta:** cada ruta (`/v1/login`, `/v1/servers`, `/v1/admin/...`) va a su servicio.
- **Valida el JWT:** rechaza con `401` los pedidos sin token, con firma inválida o con el token vencido (firma HS256 con `JWT_SECRET`; Kong no usa clave RSA). Las rutas públicas (registro, login, recupero de contraseña, unirse por invitación, los health checks y el webhook de Mercado Pago) no lo exigen.
- **Limita la velocidad:** pone un tope de pedidos por minuto y por IP en el login, el refresh y la búsqueda de mensajes.

Kong funciona en modo DB-less: toda su configuración está en un solo archivo, [`kong/kong.yml.template`](kong/kong.yml.template), y no necesita su propia base de datos. Al arrancar, un contenedor reemplaza las variables de ese archivo con `envsubst` y Kong carga el resultado.

En producción, delante de Kong corre Caddy, que pone el HTTPS con un dominio propio. Kong no sabe quién es staff ni quién está suspendido: solo verifica la firma y la fecha del token. Eso lo decide cada servicio.

## Pre-requisitos

- **Docker** y **Docker Compose** v2.24 o más nuevo.
- Los servicios a los que enruta, solo si querés que los pedidos lleguen a algún lado. Sin ellos, Kong arranca igual y responde `502` en las rutas que no encuentran su servicio.

## Cómo correr

### Con Docker Compose

```bash
docker compose up
```

El gateway queda en `http://localhost:8000`. Para comprobar que valida el JWT, un pedido sin token a una ruta protegida tiene que dar `401`:

```bash
curl -i http://localhost:8000/v1/servers
```

Con un JWT válido el pedido pasa el chequeo del gateway. Si el servicio de destino no está levantado, la respuesta es `502`.

Por defecto, Kong busca cada servicio en tu máquina, en estos puertos:

| Servicio | Puerto |
|---|---|
| `identify-service` | 8080 |
| `servers` | 8081 |
| `messaging` | 4000 |
| `notifications` | 4001 |
| `voice-sfu` | 4002 |
| `admin` | 8082 |
| `metrics` | 8083 |
| `billing` | 8084 |

Como casi todos los servicios usan el mismo puerto por defecto, para correr varios a la vez cambiá el de cada uno con su variable `API_PORT` (o `SIGNALING_PORT` en `voice-sfu`) para que coincida con esta tabla. O editá las variables `*_UPSTREAM_URL` del gateway. Para levantar todo junto sin pensar en puertos, usá el compose del repositorio `infrastructure`.

Si querés cambiar algo, copiá el archivo de ejemplo y editalo antes de levantar:

```bash
cp .env.example .env
```

Si tenés un `.env` en este directorio, Docker Compose lo toma solo. Usá `docker compose --env-file /dev/null up` para ignorarlo y partir de los valores por defecto.

### Con HTTPS

Para probar Caddy, que pone el HTTPS con un dominio, levantá el perfil `https`. Necesita un dominio público que apunte a tu máquina y los puertos 80 y 443 libres:

```bash
DOMAIN=tunombre.duckdns.org docker compose --profile https up
```

### Agregar un servicio nuevo

1. Sumar una entrada en `services:` de `kong/kong.yml.template`, con `url: ${NOMBRE_UPSTREAM_URL}` y las rutas que atiende. El nombre de la variable tiene que terminar en `_UPSTREAM_URL`: el CI reemplaza esas variables por una URL de prueba, renderiza el template y lo valida con `kong config parse`.
2. Agregar esa variable al servicio `kong-config` de `docker-compose.yml` y a `.env.example`.
3. Recrear los contenedores:

```bash
docker compose up -d --force-recreate kong-config gateway
```

## Variables de entorno

Se leen del entorno o de un archivo `.env`. El archivo [`.env.example`](.env.example) trae valores listos para correr en local.

| Variable | Default | Descripción |
|---|---|---|
| `JWT_SECRET` | `secreto-jwt-solo-local` | Secreto con el que se valida la firma del JWT. Tiene que ser el mismo que usa `identify-service`. Es un secreto. |
| `IDENTITY_UPSTREAM_URL` | `http://host.docker.internal:8080` | Dónde escucha `identify-service`. |
| `SERVERS_UPSTREAM_URL` | `http://host.docker.internal:8081` | Dónde escucha `servers`. |
| `MESSAGING_UPSTREAM_URL` | `http://host.docker.internal:4000` | Dónde escucha `messaging`. Puede ser un nombre que resuelva a más de una IP: Kong reparte los pedidos. |
| `NOTIFICATIONS_UPSTREAM_URL` | `http://host.docker.internal:4001` | Dónde escucha `notifications`. |
| `VOICE_UPSTREAM_URL` | `http://host.docker.internal:4002` | Dónde escucha `voice-sfu`. |
| `ADMIN_UPSTREAM_URL` | `http://host.docker.internal:8082` | Dónde escucha `admin`. |
| `METRICS_UPSTREAM_URL` | `http://host.docker.internal:8083` | Dónde escucha `metrics`. |
| `BILLING_UPSTREAM_URL` | `http://host.docker.internal:8084` | Dónde escucha `billing`. |
| `WEB_ORIGIN` | `http://localhost:3000` | Único origen que puede subir adjuntos directo desde el navegador (CORS). |
| `GATEWAY_BIND_IP` | `127.0.0.1` | IP en la que se publica el puerto 8000. |
| `DOMAIN` | `localhost` | Dominio público. Solo lo usa Caddy, con el perfil `https`. |
| `OTEL_EXPORTER_OTLP_ENDPOINT` | vacío | Endpoint OTLP al que Kong exporta sus trazas, por ejemplo `https://otlp.nr-data.net` para New Relic. Vacío = no exporta nada. |
| `OTEL_EXPORTER_OTLP_HEADERS` | vacío | Tiene que incluir `api-key=<clave de licencia de ingesta>`. Es un secreto. |
| `OTEL_SERVICE_NAME` | `kong` | Nombre del servicio en New Relic. En producción, `gateway-prod`. |
| `LOG_SHIP_URL` | vacío | Dónde Kong manda sus logs, por ejemplo `https://log-api.newrelic.com/log/v1`. Vacío = no los envía. |
| `LOG_SHIP_API_KEY` | vacío | Clave para los logs. Si está vacía se usa la api-key de `OTEL_EXPORTER_OTLP_HEADERS`. Es un secreto. |

## Observabilidad

Kong manda a New Relic sus **trazas** y sus **logs**, así el gateway aparece como un servicio más (`OTEL_SERVICE_NAME`, en producción `gateway-prod`). Los dos están apagados por defecto y se activan por separado cargando las variables de la tabla de arriba y recreando los contenedores. `kong/render.sh` arma `kong.yml` a partir del template e inserta los plugins que correspondan dentro de la lista `plugins:` (marcador `${OTEL_PLUGINS}`): si faltan las variables, Kong arranca igual y no exporta nada.

**Trazas** (`OTEL_EXPORTER_OTLP_ENDPOINT` y `OTEL_EXPORTER_OTLP_HEADERS`)
- Kong abre la traza de cada pedido, le pasa el `traceparent` al servicio que lo atiende y exporta sus spans por OpenTelemetry. Nunca confía en el `traceparent` que llega de afuera.
- Exporta método, ruta (el patrón de la ruta de Kong), host, código de respuesta y duración. No exporta la dirección completa, la query (tickets de WebSocket, emails) ni la IP del cliente: las borra un plugin `pre-function` en la fase `rewrite`.

**Logs** (`LOG_SHIP_URL`)
- Un log por pedido, enviado en lotes con el plugin `http-log`. Se arma por lista de permitidos: `message` (por ejemplo `GET notifications-health 503`), `level` (`error` desde el 500), `timestamp`, método, tamaños, código de respuesta, nombre de la ruta y del servicio de Kong, latencias, `entity.name` (el nombre del servicio en New Relic) y `trace.id`, que lo enlaza con la traza del mismo pedido.
- No lleva la dirección ni la query, ni encabezados (el token), ni la IP del cliente, ni las IPs de los servicios.
- Cada pedido es una línea: el volumen cuenta para los 100 GB al mes de New Relic. Mirar cuánto ocupa después de un día de uso real.

Los dos filtros se verificaron con un Kong real y un colector local: con un pedido que llevaba un ticket, un email y un token en la query y en el encabezado, ninguno apareció en lo exportado, y una corrida de control sin el filtro de las trazas sí los exportaba.

Para ver el gateway en New Relic, buscá la entidad con el nombre de `OTEL_SERVICE_NAME`. Consultas útiles (NRQL):

```
FROM Span SELECT count(*) WHERE service.name = 'gateway-prod' FACET http.status_code SINCE 1 hour ago
FROM Span SELECT percentile(duration.ms, 50, 95, 99) WHERE service.name = 'gateway-prod' SINCE 1 hour ago TIMESERIES
FROM Log SELECT count(*) WHERE entity.name = 'gateway-prod' FACET response.status SINCE 1 hour ago
FROM Log SELECT percentage(count(*), WHERE level = 'error') WHERE entity.name = 'gateway-prod' SINCE 1 hour ago TIMESERIES
```

## Comandos Docker

Todos desde la raíz del repositorio.

| Qué querés hacer | Comando |
|---|---|
| Levantar el gateway | `docker compose up` |
| Levantar en segundo plano | `docker compose up -d` |
| Levantar también Caddy (HTTPS) | `docker compose --profile https up -d` |
| Ver los logs de Kong | `docker compose logs -f gateway` |
| Ver qué está corriendo | `docker compose ps` |
| Aplicar un cambio del template | `docker compose up -d --force-recreate kong-config gateway` |
| Bajar todo | `docker compose down` |

El puerto de administración de Kong (8001) escucha solo dentro del contenedor y no se publica. No hay que exponerlo en producción.


## Formato de error

Todo error que genera el propio Kong sale con el sobre común de la API, `Content-Type: application/json`:

```json
{ "error": { "code": "UNAUTHORIZED", "message": "Falta el token de acceso o no es válido.", "details": {} } }
```

La regla: un plugin global `post-function` (en `kong/kong.yml.template`) reescribe la respuesta **solo** cuando el error nace en Kong (`kong.response.get_source() ~= "service"`) y el status es 400 o más. Lo que responde un servicio pasa intacto, sin buffering, aunque sea un cuerpo grande o un stream. Además, `KONG_ERROR_DEFAULT_TYPE=application/json` (en `docker-compose.yml`) hace que los errores del núcleo de Kong nunca salgan en texto plano ni HTML, aunque el cliente mande `Accept: text/html`. Los preflight CORS (204) y los `HEAD` no se tocan.

| Situación | Status | `code` | `details` |
|---|---|---|---|
| Plugin `jwt` (sin token, token inválido o vencido) | 401 | `UNAUTHORIZED` | `{}` |
| Plugin `rate-limiting` | 429 | `RATE_LIMITED` | `{"retry_after_seconds": n}` si hay `Retry-After`; se conservan `Retry-After` y `X-RateLimit-*` |
| Ninguna ruta coincide | 404 | `NOT_FOUND` | `{}` |
| El servicio respondió mal / conexión rechazada | 502 | `BAD_GATEWAY` | `{}` |
| Sin servicio disponible en el balanceador | 503 | `SERVICE_UNAVAILABLE` | `{}` |
| El servicio tardó demasiado | 504 | `GATEWAY_TIMEOUT` | `{}` |
| Otros 4xx del núcleo | 400, 403, 405, 408, 413, 414, 415, 431 | `BAD_REQUEST`, `FORBIDDEN`, `METHOD_NOT_ALLOWED`, `REQUEST_TIMEOUT`, `PAYLOAD_TOO_LARGE`, `URI_TOO_LONG`, `UNSUPPORTED_MEDIA_TYPE`, `HEADERS_TOO_LARGE` | `{}` |
| Otros 5xx del núcleo | 5xx | `INTERNAL_ERROR` | `{}` |

El Lua del plugin no puede usar el carácter de dólar: el template pasa por `envsubst`.

## Tests

Este repositorio no tiene tests unitarios. El CI valida el template en cada pull request: reemplaza las variables, lo renderiza y lo verifica con `kong config parse`, así que una ruta mal escrita o una variable con un nombre que no termina en `_UPSTREAM_URL` hace fallar el pipeline.

Además, `scripts/smoke-error-format.sh` (corre en el CI, requiere Docker y curl) levanta Kong con la config real y un upstream de mentira, y verifica el sobre de error en 401, 404, 502 y 429, y que el error de un servicio pase intacto. Se corre con `bash scripts/smoke-error-format.sh`.

La prueba más rápida a mano es la de la sección [Cómo correr](#cómo-correr): sin token, una ruta protegida responde `401`.

## Más documentación

- [`kong/kong.yml.template`](kong/kong.yml.template): toda la configuración del gateway, con sus rutas, plugins y topes de velocidad.
