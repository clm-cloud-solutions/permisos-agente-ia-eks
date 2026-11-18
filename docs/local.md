# El laboratorio en tu máquina (kind)

Sin cuenta de AWS. Un clúster [kind](https://kind.sigs.k8s.io/) con la misma tienda y el mismo incidente que en EKS. Secrets Manager lo reemplaza una «bóveda»: un namespace cuyo Secret es la fuente de la contraseña, que External Secrets copia al clúster igual que en AWS.

## Requisitos

- **Docker** (Docker Desktop, Rancher Desktop, OrbStack o Docker Engine), con al menos **4 GB de memoria y 10 GB de disco libres** para el laboratorio. Con KubeBolt open source dentro del clúster, cuenta con 6 GB de memoria y 15 GB de disco.
- **kind** ≥ 0.27, **kubectl** ≥ 1.30, **helm** ≥ 3.14 y **python3** ≥ 3.9 (solo la biblioteca estándar).
- Salida a internet: imágenes de `public.ecr.aws` y `ghcr.io`, y PyPI (las APIs instalan su driver de PostgreSQL al arrancar).

Probado el 18 de noviembre de 2026 con kind 0.31 (Kubernetes 1.35), Docker Desktop en macOS (arm64) y External Secrets 2.15.

## Crearlo

```bash
cp lab.env.example lab.env      # LAB_MODE=local ya viene por defecto
make up
```

En unos 3 minutos:

1. **El clúster** `permisos-ia`, de un solo nodo, con la auditoría del API server activada ([local/audit-policy.yaml](../local/audit-policy.yaml), nivel `Metadata`: quién, qué y con qué resultado, nunca el contenido). Es el equivalente local de CloudTrail para el ejercicio 6.
2. **External Secrets.**
3. **PostgreSQL 16** en `shop-data`, con la contraseña del administrador en un Secret que genera el script, y **la bóveda**: el namespace `boveda`, su Secret `orders-db` (la contraseña de `orders-api`) y una ServiceAccount de External Secrets que solo puede leer ese namespace.
4. **La tienda**: el esquema y los datos, un rol de base de datos por API, y `shop-web`, `orders-api`, `catalog-api` y un generador de tráfico.

El kubeconfig del laboratorio queda en `.lab/kubeconfig`; tu `~/.kube/config` no se toca. Para usar `kubectl` tú mismo:

```bash
eval "$(make -s env)"           # export KUBECONFIG=…/.lab/kubeconfig
make tienda                     # la tienda en http://localhost:8080
```

## Conectarlo a KubeBolt

```bash
make kubebolt
```

Con `KUBEBOLT=cloud` (por defecto) instala el agente y lo conecta a KubeBolt Cloud: crea tu cuenta en [app.kubebolt.io/signup](https://app.kubebolt.io/signup), abre el asistente **Connect cluster** y pega el token de ingesta cuando `make kubebolt` lo pida. El agente solo hace conexiones de salida, a `agent.kubebolt.io:443`: funciona desde tu portátil sin abrir nada.

Con `KUBEBOLT=oss` instala KubeBolt open source en el propio clúster y te pide la clave de tu proveedor de LLM para Kobi. La interfaz, con `make ui` en `http://localhost:3000`.

Los detalles y qué ejercicios funcionan con cada opción, en [kubebolt.md](kubebolt.md).

## El incidente

```bash
make romper
```

Hace a mano lo que en AWS hace la función de rotación:

```
ALTER ROLE orders_app PASSWORD '<nueva>'                       (en PostgreSQL)
SELECT pg_terminate_backend(pid) … WHERE usename = 'orders_app' (cierra sus sesiones)
boveda/orders-db ← la contraseña nueva                          (la «Secrets Manager» local)
```

External Secrets copia la contraseña nueva a `shop-backend/orders-db-credentials` en menos de un minuto. Pero `orders-api` la leyó de una variable de entorno al arrancar: no vuelve a entrar en la base (`28P01`, *password authentication failed*), su readiness falla, sus pods salen del Service y la tienda da 503. `make estado` lo resume; `make reparar` fuerza la sincronización y reinicia `orders-api`.

En la prueba del 18 de noviembre: pods sin Ready a los 14 s de la rotación, y reparado en 37 s.

## Lo que cambia frente a AWS

| Ejercicio | En AWS | En local |
|---|---|---|
| 1 | Con el conector de AWS, Kobi encuentra el `RotateSecret` en CloudTrail | Kobi ve el `28P01`, el ExternalSecret recién sincronizado y los pods que arrancaron antes; la rotación la deduce del clúster |
| 2 | El simulador de IAM: el rol de KubeBolt no puede leer el secreto (`explicitDeny`) | `kubectl auth can-i`: las identidades de KubeBolt sí pueden leer Secrets; la barrera es la redacción de KubeBolt, no el RBAC |
| 6 | CloudTrail: quién rotó, qué leyó el rol de KubeBolt y quién leyó el secreto | La auditoría del API server: quién cambió la bóveda y qué pidió cada identidad de KubeBolt |

El ejercicio 2 en local es el más incómodo, y por eso vale la pena: en Kubernetes, un agente que puede reiniciar un deployment suele poder leer sus Secrets. Lo que impide que el valor llegue al modelo no es el RBAC sino el producto, y eso es una barrera de otra clase. [ejercicios.md](ejercicios.md) lo cuenta con detalle.

## Borrarlo

```bash
make down
```

Borra el clúster kind y su kubeconfig. Si lo conectaste a KubeBolt Cloud, el clúster queda allí como desconectado: bórralo desde **Fleet** y revoca su token de ingesta.

## Si algo falla

| Síntoma | Qué mirar |
|---|---|
| `make up` se queda en «Starting control-plane» | Memoria de Docker: el laboratorio necesita unos 2 GB libres. |
| PostgreSQL entra en *recovery mode* (`57P03`) o los pods quedan en `Evicted` | Disco de Docker lleno (`docker system df`). Libera espacio y repite `make up`. |
| `External Secrets no sincronizó orders-db-credentials` | `kubectl -n shop-backend describe externalsecret orders-db-credentials` y `kubectl get clustersecretstore secretos`. |
| `orders-api` no arranca | `kubectl -n shop-backend logs deploy/orders-api`: suele ser `pip` sin salida a PyPI. |
| El agente no se registra | `kubectl -n kubebolt-system logs ds/kubebolt-agent`: token mal copiado (vuelve a ejecutar el bloque del asistente) o sin salida a `agent.kubebolt.io:443`. |
