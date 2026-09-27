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

## Rate limiting
Configurado por IP en: `/v1/login` (60 req/min -- ver mas abajo por que no es
10 como en el resto), `/v1/pin/login`, `/v1/oauth/google` y `/v1/refresh`
(10 req/min cada uno). `/v1/password-recovery` no tiene rate-limiting a nivel
gateway; identify-service ya limita ese endpoint por email a nivel de
aplicacion (ver su README, seccion de recuperacion de contraseña).

`/v1/login` se subio de 10 a 60 req/min porque dejo de ser la unica defensa
contra fuerza bruta: identify-service ahora bloquea intentos fallidos por
`(email, ip)` (ver su README) -- a Kong solo le queda la proteccion gruesa
contra volumen por IP, para la que 10/min bloqueaba de mas a cualquier grupo
de usuarios legitimos compartiendo una IP (encontrado con una prueba de carga
con k6, ver `infrastructure/load-test/README.md`).

## Deploy a producción

`docker-compose.yml` renderiza `kong/kong.yml.template` con `envsubst`
(`kong-config`, en vez de usar el `kong/kong.yml` ya commiteado -- ese
queda solo para el chequeo de sintaxis del CI) y suma `caddy` para TLS
automático delante de Kong.

`identity` y `servers` corren en sus propias VMs (no en este compose) —
`IDENTITY_UPSTREAM_URL`/`SERVERS_UPSTREAM_URL` en `.env` apuntan a sus IPs
de Tailscale. Ver `.env.example` para la lista completa.

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
nano .env   # completar JWT_SECRET, DOMAIN, IDENTITY/SERVERS_UPSTREAM_URL
docker compose up -d
```
