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
Ya configurado en login y recupero de contraseña (10 req/min por IP), como
pide el RNF. Ajustar el numero segun lo que decidan en el ADR de seguridad.

## Deploy a producción

`docker-compose.yml` (raíz) es solo para probar `kong/kong.yml` en local —
no lleva Caddy ni el paso de `envsubst`. El deploy real usa
`docker-compose.prod.yml`, que además:
- Renderiza `kong/kong.yml.template` con `envsubst` (`kong-config`), en vez
  de usar el `kong/kong.yml` ya commiteado.
- Suma `caddy` para TLS automático delante de Kong.

`identity` y `servers` corren en sus propias VMs (no en este compose) —
`IDENTITY_UPSTREAM_URL`/`SERVERS_UPSTREAM_URL` en `.env.prod` apuntan a sus
IPs de Tailscale. Ver `.env.prod.example` para la lista completa.

**Deploy automático**: un push a `main` (después de que pase `validate`)
dispara el job `deploy` en `.github/workflows/ci.yml`, que por SSH hace
`git pull` + `docker compose -f docker-compose.prod.yml --env-file .env.prod
up -d --force-recreate kong-config gateway caddy` en la VM de Oracle.
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
cp .env.prod.example .env.prod
nano .env.prod   # completar JWT_SECRET, DOMAIN, IDENTITY/SERVERS_UPSTREAM_URL
docker compose -f docker-compose.prod.yml --env-file .env.prod up -d
```
