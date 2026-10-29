# discordia-gateway (Kong, DB-less)

Punto unico de entrada a la plataforma. Enruta hacia cada servicio, valida JWT
y aplica rate limiting -- los tres requisitos que pide el RNF de API Gateway.

## Por que DB-less
Kong normalmente guarda su config en su propia Postgres/Cassandra. En modo
DB-less, la config vive en un solo archivo YAML (`kong/kong.yml`) versionado
en este repo -- sin sumar otra base de datos al stack, algo importante dado
el limite de RAM del VM de despliegue.

## Setup local
```bash
cp .env.example .env
docker compose up -d
```
La API queda expuesta en `http://localhost:8000`. El admin API (para debug)
en `http://localhost:8001` -- NO exponer este puerto en producción.

## Agregar un servicio nuevo
Sumar una entrada en `services:` dentro de `kong/kong.yml`, con su `url`
interna (nombre del contenedor Docker) y las rutas (`paths`) que atiende.
Despues de editar, correr:
```bash
docker compose restart kong
```

## Rutas publicas (sin JWT)
Estas NO deben llevar el plugin `jwt`: registro, login, recupero de
contraseña, login federado, unirse a servidor via invitacion. Si agregan el
plugin JWT a nivel de un service completo, revisen que ninguna ruta publica
quede atrapada por error.

## Rutas de admin (backoffice)
`/v1/admin/**` (`GET`, `POST`, `DELETE`) se enruta a `discordia-admin`
(`admin-service`, variable `ADMIN_UPSTREAM_URL`) conservando el path. Todas
las rutas exigen JWT valido y no vencido; ninguna es publica y `/livez` /
`/readyz` de admin no se exponen por Kong.

Modelo de seguridad: Kong solo valida la firma y el `exp` del token. Quien es
staff lo decide admin en cada request (tabla `staff_members`): sin token o con
token vencido Kong responde `401`; con token valido de un usuario que no es
staff, admin responde `403 FORBIDDEN`. Kong no sabe nada de suspensiones.
Si admin esta caido, Kong devuelve `502/503` y el resto de los servicios no
se ve afectado.

## Rate limiting
Configurado por IP en: `/v1/login` (60 req/min -- ver mas abajo por que no es
10 como en el resto), `/v1/pin/login`, `/v1/oauth/google` y `/v1/refresh`
(10 req/min cada uno). `/v1/password-recovery` no tiene rate-limiting a nivel
gateway; identify-service ya limita ese endpoint por email a nivel de
aplicacion (ver su README, seccion de recuperacion de contraseña).

`GET /v1/servers/:id/messages/search` (busqueda de mensajes de messaging) tiene
120 req/min: el cliente busca mientras se escribe, con debounce, y el texto se
busca con una regex que recorre los mensajes de los canales del servidor.

`/v1/login` se subio de 10 a 60 req/min porque dejo de ser la unica defensa
contra fuerza bruta: identify-service ahora bloquea intentos fallidos por
`(email, ip)` (ver su README) -- a Kong solo le queda la proteccion gruesa
contra volumen por IP, para la que 10/min bloqueaba de mas a cualquier grupo
de usuarios legitimos compartiendo una IP (encontrado con una prueba de carga
con k6, ver `infrastructure/load-test/README.md`).

## Varias instancias de messaging
`MESSAGING_UPSTREAM_URL` puede ser un nombre que resuelva a más de una IP: Kong reparte
las peticiones (y las conexiones del socket) entre todas. En local se prueba con
`infrastructure/docker-compose.multi.yml` (ver su README).

`messaging-service` tiene `connect_timeout: 3000`. Con el valor por defecto (60 s), cuando
una instancia muere Kong sigue mandándole una parte del tráfico hasta que expira su caché de
DNS, y cada intento se cuelga un minuto antes de reintentar en la instancia viva. El ticket
del socket dura 30 s, así que un cliente que se reconectaba en ese momento llegaba con el
ticket vencido y no podía entrar. Con 3 s, reconectar tarda ~3 s en el peor caso (se probó
matando una instancia con `docker kill`).

En producción se mantiene **una sola instancia** de `messaging` (indicación de la cátedra:
verificar que escala, pero no escalarlo), y `MESSAGING_UPSTREAM_URL` es una sola IP de Tailscale.
Si algún día se suman instancias, hay que apuntarla a un nombre que resuelva a todas, o definir
un `upstream` de Kong con un `target` por instancia.

## Notifications
`notifications-service` (`NOTIFICATIONS_UPSTREAM_URL`) expone dos rutas: `POST
/v1/notifications/socket-tickets` (con `jwt`, igual que el ticket de messaging) y el
WebSocket `/notifications/socket`, que va sin `jwt` porque el navegador no puede mandar
headers: se autentica con el ticket de un solo uso. Si `NOTIFICATIONS_UPSTREAM_URL` no está
en el `.env`, `docker-compose.yml` usa una URL de relleno para que Kong arranque igual y esas
dos rutas respondan 502 hasta que se configure.

## Deploy a producción

`docker-compose.yml` renderiza `kong/kong.yml.template` con `envsubst`
(`kong-config`, en vez de usar el `kong/kong.yml` ya commiteado -- ese
queda solo para el chequeo de sintaxis del CI) y suma `caddy` para TLS
automático delante de Kong.

`identity`, `servers`, `messaging`, `notifications`, `metrics` y `admin` corren en sus propias VMs (no en este
compose) — `IDENTITY_UPSTREAM_URL`/`SERVERS_UPSTREAM_URL`/
`MESSAGING_UPSTREAM_URL`/`NOTIFICATIONS_UPSTREAM_URL`/`METRICS_UPSTREAM_URL`/`ADMIN_UPSTREAM_URL` en `.env` apuntan a sus IPs de Tailscale. Ver
`.env.example` para la lista completa.

**Deploy automático**: un push a `main` (después de que pase `validate`)
dispara el job `deploy` en `.github/workflows/ci.yml`, que por SSH hace
`git pull` + `docker compose up -d --force-recreate kong-config gateway
caddy` en la VM de Oracle (usa el `.env` que ya está en la VM, no lo toca).
Necesita estos secrets en **Settings → Secrets and variables → Actions**:

| Secret | Valor |
|---|---|
| `ORACLE_HOST` | IP pública de la VM |
| `ORACLE_USER` | usuario SSH (ej. `ubuntu`) |
| `ORACLE_SSH_KEY` | clave privada SSH de despliegue |

**Primera vez en la VM** (manual, una sola vez):
```bash
git clone -b main https://github.com/discordia-grupo01/gateway.git
cd gateway

cp .env.example .env
nano .env   # completar JWT_SECRET, DOMAIN, IDENTITY/SERVERS/MESSAGING/ADMIN_UPSTREAM_URL
docker compose up -d
```
