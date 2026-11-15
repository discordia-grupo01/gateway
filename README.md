# gateway

API gateway de Discordia, hecho con Kong.

## Tabla de contenidos

- [Introducción](#introducción)
- [Pre-requisitos](#pre-requisitos)
- [Cómo correr](#cómo-correr)
- [Variables de entorno](#variables-de-entorno)
- [Comandos Docker](#comandos-docker)
- [Tests](#tests)
- [Más documentación](#más-documentación)

## Introducción

El gateway es el único punto de entrada a Discordia: los clientes (la web, la app y el backoffice) solo hablan con él, y él reparte cada pedido al servicio que corresponde. Hace tres cosas:

- **Enruta:** cada ruta (`/v1/login`, `/v1/servers`, `/v1/admin/...`) va a su servicio.
- **Valida el JWT:** rechaza con `401` los pedidos sin token o con el token vencido. Las rutas públicas (registro, login, recupero de contraseña, unirse por invitación, los health checks y el webhook de Mercado Pago) no lo exigen.
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

## Tests

Este repositorio no tiene tests propios. El CI valida el template en cada pull request: reemplaza las variables, lo renderiza y lo verifica con `kong config parse`, así que una ruta mal escrita o una variable con un nombre que no termina en `_UPSTREAM_URL` hace fallar el pipeline.

La prueba más rápida a mano es la de la sección [Cómo correr](#cómo-correr): sin token, una ruta protegida responde `401`.

## Más documentación

- [`kong/kong.yml.template`](kong/kong.yml.template): toda la configuración del gateway, con sus rutas, plugins y topes de velocidad.
