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
