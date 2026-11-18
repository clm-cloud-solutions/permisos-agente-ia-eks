# El laboratorio en tu cuenta de AWS (EKS)

La versión completa: la contraseña de `orders-api` vive en Secrets Manager y la rota una Lambda, el clúster es EKS, y KubeBolt lee la cuenta con un rol de IAM de solo lectura. Es la que se usó en la charla.

## Requisitos

- **Una cuenta de AWS de pruebas** y un perfil de AWS CLI con permisos de administrador en ella. El laboratorio crea roles de IAM, una VPC, un NAT gateway, RDS y un clúster EKS. No lo montes en una cuenta con cargas de producción.
- **aws** CLI v2, **eksctl** ≥ 0.200, **kubectl** ≥ 1.30, **helm** ≥ 3.14, **python3** ≥ 3.9 con `pip`, y **curl**.
- Una región con EKS y Graviton (`t4g`): `us-east-2` por defecto.

## Qué crea y cuánto cuesta

| Recurso | Para qué | Coste aproximado (us-east-2) |
|---|---|---|
| VPC con 2 subredes públicas, 2 privadas y un NAT gateway | Los nodos, RDS y la Lambda, sin IPs públicas | 0,045 USD/h más el tráfico |
| EKS 1.35, 2× `t4g.medium` en subredes privadas | El clúster; su API solo acepta tu IP | 0,10 USD/h + 0,067 USD/h |
| RDS PostgreSQL 16, `db.t4g.micro`, privado y con TLS obligatorio | La base de la tienda | 0,016 USD/h |
| Secreto `permisos-ia/orders-db` y la Lambda `permisos-ia-orders-db-rotation` | La contraseña de `orders-api` y su rotación | Céntimos al mes |
| Rol `permisos-ia-eso` | External Secrets lee ese secreto y nada más (Pod Identity) | — |
| Rol `permisos-ia-kubebolt-readonly` | Lo que asume KubeBolt para leer la cuenta | — |
| Rol `permisos-ia-kubebolt-api` | El backend de KubeBolt open source, si lo instalas: solo puede asumir el anterior | — |
| Un bucket `permisos-ia-<cuenta>-<región>` | El paquete de la Lambda | Céntimos |

En total, unos **0,25 USD por hora** mientras exista: alrededor de 6 USD al día. `make down` lo borra todo. Todos los recursos llevan la etiqueta `Project=permisos-agente-ia-eks`.

## Crearlo

En `lab.env`:

```bash
LAB_MODE=aws
AWS_PROFILE=mi-cuenta-de-pruebas
AWS_REGION=us-east-2
```

Y después:

```bash
make up
```

Unos 30 minutos la primera vez, casi todo esperando a CloudFormation y a eksctl:

1. **El paquete de la función de rotación** ([aws/lambda/rotation.py](../aws/lambda/rotation.py), con `pg8000` y la CA de RDS de tu región), en un bucket del laboratorio.
2. **La pila de CloudFormation** [aws/lab.yaml](../aws/lab.yaml): la red, RDS, el secreto con su rotación configurada pero sin rotar todavía, y los roles. Unos 12 minutos, la mayoría de RDS.
3. **El clúster EKS** con eksctl ([aws/cluster.yaml.tpl](../aws/cluster.yaml.tpl)). Su endpoint público solo acepta tu IP; si cambias de red, vuelve a lanzar `make up` y la actualiza. Unos 15 minutos.
4. **External Secrets**, con Pod Identity: su rol solo puede leer `permisos-ia/orders-db`.
5. **La tienda.** La contraseña del administrador de RDS la guarda RDS en su propio secreto, y el script la pasa directo a un Secret de Kubernetes para los jobs de la base. Las APIs hablan con RDS por TLS con `verify-full`: cadena contra la CA de RDS y nombre del host comprobado.

El kubeconfig del laboratorio queda en `.lab/kubeconfig`, con tu perfil dentro; tu `~/.kube/config` no se toca. `eval "$(make -s env)"` para usar `kubectl` tú mismo, y `make tienda` para abrir la tienda en `http://localhost:8080`. La tienda no tiene balanceador público: se abre por `port-forward`.

`make up` se puede repetir: cada paso se salta lo que ya existe.

## El rol de KubeBolt

`permisos-ia-kubebolt-readonly` es lo que asume KubeBolt para leer tu cuenta. Su política es la que recomienda KubeBolt, generada desde el código open source ([aws/kubebolt-policy.json](../aws/kubebolt-policy.json), de [`aws_policy.go`](https://github.com/clm-cloud-solutions/kubebolt/blob/v2.6.5/apps/api/internal/mcpcatalog/aws_policy.go) en la versión 2.6.5), y tiene tres partes:

- **`KubeBoltReadOnly`**: 75 acciones de lectura de metadatos (EC2, EKS, RDS, CloudWatch, CloudTrail `LookupEvents`, Secrets Manager `DescribeSecret`…).
- **`NeverSecretsOrData`**: un `Deny` explícito sobre todo lo que devuelve valores o datos: `secretsmanager:GetSecretValue`, `ssm:GetParameter*`, `kms:Decrypt`, `s3:GetObject*`, `dynamodb:GetItem`… Un `Deny` gana a cualquier `Allow`, así que se mantiene aunque alguien adjunte después una política más amplia al rol.
- **`NothingElseThroughMCP`**: cuando la llamada llega por el AWS MCP Server (la condición `aws:ViaAWSMCPService`), deniega todo lo que no esté en una lista corta de lectura. Es el camino por el que pasan las llamadas de KubeBolt.

Quién puede asumirlo lo dicta KubeBolt: un principal y el External ID de tu organización, que el panel del conector de AWS imprime en la política de confianza. Hasta que los copies, `make up` deja como principal el rol del backend de KubeBolt open source (`permisos-ia-kubebolt-api`) y un External ID provisional en `.lab/external-id`, que no sirve para conectar. Para conectar:

```bash
KUBEBOLT_AWS_PRINCIPAL_ARN=arn:aws:iam::…   # el principal del panel (vacío con open source en el clúster)
KUBEBOLT_EXTERNAL_ID=…                       # el External ID de tu organización
```

Y `make up` otra vez, que solo actualiza la confianza del rol. Los pasos completos, para KubeBolt Cloud (plan Team) y para open source, en [kubebolt.md](kubebolt.md#el-conector-de-aws-solo-con-lab_modeaws).

## El incidente

```bash
make romper
```

1. `aws secretsmanager rotate-secret --secret-id permisos-ia/orders-db`.
2. La función de rotación crea una contraseña nueva, la aplica en RDS (`ALTER ROLE orders_app`), comprueba que entra con ella, la marca como `AWSCURRENT` y, como política de este laboratorio, cierra las sesiones viejas del rol.
3. External Secrets copia la contraseña nueva al clúster en menos de un minuto.
4. `orders-api` la leyó al arrancar: no vuelve a entrar (`28P01`), sus pods salen del Service y la tienda da 503.
5. `make romper` espera a que CloudTrail devuelva el `RotateSecret` (2 a 5 minutos), que es lo que Kobi necesita para encontrar quién y cuándo. `ESPERAR_CLOUDTRAIL=0 make romper` no espera.

`make estado` lo resume; `make reparar` fuerza la sincronización y reinicia `orders-api`.

## Borrarlo

```bash
make down
```

Unos 25 minutos:

1. KubeBolt open source, si está, con sus volúmenes EBS (si no, quedarían huérfanos y cobrando).
2. El clúster EKS.
3. La pila de CloudFormation. La Lambda está en la VPC y AWS tarda en soltar sus interfaces de red: CloudFormation espera solo.
4. Lo que CloudFormation no borra: el secreto sin periodo de recuperación (si no, su nombre queda ocupado 30 días y el siguiente `make up` falla), el grupo de logs de la Lambda y el bucket.
5. Al final lista lo que quede con la etiqueta `Project=permisos-agente-ia-eks`.

Después, en la consola, comprueba que no quedan NAT gateways, volúmenes EBS ni instancias RDS en la región. Si conectaste el clúster a KubeBolt Cloud, bórralo de **Fleet** y revoca su token de ingesta.

## Si algo falla

| Síntoma | Qué mirar |
|---|---|
| `la pila permisos-ia no se creó` | Los eventos que imprime el script, o la consola de CloudFormation. Corrige y repite `make up`. |
| `eksctl` falla al crear el clúster | Su pila `eksctl-permisos-ia-cluster` en CloudFormation. Con versiones viejas de eksctl, actualízalo. |
| `kubectl` da *timeout* | Tu IP cambió: `make up` actualiza el endpoint. |
| `la rotación no terminó` | El log de la función que imprime el script: suele ser la red de la Lambda (NAT) o el rol `orders_app` aún sin crear (el job `app-roles`). |
| `make down` se queda en la pila | Las interfaces de la Lambda tardan en liberarse; si pasa de 40 minutos, mira los eventos de la pila. |
