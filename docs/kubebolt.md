# Conectar el laboratorio a KubeBolt

[KubeBolt](https://kubebolt.io/) es una plataforma de operaciones para Kubernetes: el mapa del clúster, métricas, insights, seguridad y **Kobi**, un agente que investiga incidentes contigo (**Kobi Copilot**, el chat) o solo (**Kobi Autopilot**). Los ejercicios necesitan uno de estos dos caminos, que eliges con `KUBEBOLT` en `lab.env`:

| | KubeBolt Cloud (`KUBEBOLT=cloud`) | KubeBolt open source (`KUBEBOLT=oss`) |
|---|---|---|
| Dónde corre | En [app.kubebolt.io](https://app.kubebolt.io/); en tu clúster, solo el agente | Dentro del clúster del laboratorio |
| Kobi Copilot | Incluido: 100 créditos de IA al mes en el plan Free | Con tu propia clave de LLM: Anthropic o cualquier API compatible con OpenAI |
| Conector de AWS (ejercicio 1 en AWS) | Desde el plan Team | Incluido |
| Kobi Autopilot (ejercicio 5) | Beta abierta, en todos los planes | No está |
| Precio | [Free sin tarjeta](https://app.kubebolt.io/signup); [Team y demás planes](https://kubebolt.io/pricing/) | Apache-2.0 |

La interfaz de KubeBolt está en inglés.

## Qué ejercicio funciona con cada combinación

| Ejercicio | AWS + Cloud Free | AWS + Cloud Team | AWS + open source | Local + Cloud Free | Local + open source |
|---|---|---|---|---|---|
| 1 · Investigación | Kobi ve el clúster | Y además el `RotateSecret` en CloudTrail | Igual que Team | Kobi ve el clúster | Kobi ve el clúster |
| 2 · La contraseña | ✅ | ✅ | ✅ | ✅ (RBAC) | ✅ (RBAC) |
| 3 y 4 · Logs que dan órdenes | ✅ | ✅ | ✅ | ✅ | ✅ |
| 5 · Autopilot | ✅ | ✅ | — | ✅ | — |
| 6 · El rastro | CloudTrail, sin llamadas de Kobi | CloudTrail completo | CloudTrail completo | Auditoría de kind | Auditoría de kind |

Sin el conector de AWS, Kobi llega igual a la causa del ejercicio 1, porque ve en el clúster el `28P01`, el ExternalSecret recién sincronizado y unos pods más viejos que la contraseña. Lo que no puede es confirmar en CloudTrail quién rotó el secreto y cuándo.

## KubeBolt Cloud

1. **Crea tu cuenta gratis** en **[app.kubebolt.io/signup](https://app.kubebolt.io/signup)**. Sin tarjeta.
2. En el asistente **Connect cluster**, ponle nombre al clúster (`permisos-ia`, por ejemplo) y copia el **token de ingesta**. Se muestra una sola vez.
3. Lánzalo:

   ```bash
   make kubebolt
   ```

   Te pide el token sin mostrarlo, lo guarda en el Secret `kubebolt-system/kubebolt-agent-token` y en `.lab/kubebolt-token` (permisos 600), e instala el agente apuntando a `agent.kubebolt.io:443`. Si ya ejecutaste el bloque del asistente, el token ya está en el Secret y no lo pide.
4. En un par de minutos el clúster aparece en **Fleet**.

**Por qué `operator`.** El bloque del asistente instala el agente en modo `reader`, de solo lectura. `make kubebolt` lo instala en `operator`, porque sin escritura ni la tarjeta de reinicio de Kobi (ejercicio 1) ni Autopilot (ejercicio 5) pueden actuar. Es un permiso amplio sobre el clúster. Lo que lo limita es que nada se ejecuta sin que una persona lo apruebe con su propio rol de KubeBolt; el ejercicio 2 lo enseña. Más detalles en [Connecting clusters](https://kubebolt.io/es/docs/connect-clusters/).

**Autopilot (ejercicio 5).** Viene apagado: actívalo para tu organización en **Administration › AI & Autopilot › Kobi Autopilot** (hace falta el rol Admin). Arranca en **Suggest only**, que investiga y recomienda; los demás modos y sus salvaguardas están en [KubeBolt Cloud](https://kubebolt.io/es/docs/cloud/).

**Más:** [primeros pasos en KubeBolt Cloud](https://kubebolt.io/es/docs/cloud-onboarding/) · [el agente](https://kubebolt.io/es/docs/agent/) · [precios](https://kubebolt.io/pricing/).

## KubeBolt open source

```bash
# en lab.env: KUBEBOLT=oss (y, si no usas Anthropic, KUBEBOLT_AI_PROVIDER=openai
# con KUBEBOLT_AI_BASE_URL y KUBEBOLT_AI_MODEL)
make kubebolt
make ui                 # http://localhost:3000, usuario admin; la contraseña la imprime make ui
```

`make kubebolt` hace tres cosas:
- Te pide la API key de tu proveedor de LLM y la guarda en `kubebolt/kubebolt-llm` y en `.lab/llm-api-key`.
- Instala el chart oficial (`oci://ghcr.io/clm-cloud-solutions/kubebolt/helm/kubebolt`, versión 2.6.5) con Kobi activado.
- Instala el agente apuntando al backend dentro del clúster. Se identifica con un token de su ServiceAccount (`tokenreview`).

En AWS, además, crea la asociación de Pod Identity del backend con el rol `permisos-ia-kubebolt-api`.

Necesita recursos: en AWS, `NODE_TYPE=t4g.large`; en local, 6 GB de memoria y 15 GB de disco en Docker.

**Más:** [repositorio](https://github.com/clm-cloud-solutions/kubebolt) · [releases](https://github.com/clm-cloud-solutions/kubebolt/releases) · [instalación](https://kubebolt.io/es/docs/installation/) · [activar Kobi con tu clave](https://kubebolt.io/es/docs/enabling-kobi/) · [kind y Docker Desktop](https://kubebolt.io/es/docs/docker-desktop/). También hay [Homebrew, krew, binarios y Docker Compose](https://github.com/clm-cloud-solutions/kubebolt#quick-start) para usarlo fuera del clúster.

## El conector de AWS (solo con LAB_MODE=aws)

Con el conector, Kobi lee la cuenta de AWS con el rol `permisos-ia-kubebolt-readonly` que creó `make up`. Su política es la que recomienda KubeBolt; la explica [aws.md](aws.md#el-rol-de-kubebolt). El rol confía en un principal y exige el External ID de tu organización. Los dos los dicta KubeBolt:

1. Abre el conector:
   - en Cloud, en **Administration › AI & Autopilot › Connectors**;
   - en open source, en **Administration › AI (Kobi) › Connectors**.

   Elige **Amazon Web Services** y **IAM role**. El panel imprime la política de confianza con el principal de KubeBolt y el External ID de tu organización.
2. Cópialos a `lab.env`:

   ```bash
   KUBEBOLT_AWS_PRINCIPAL_ARN=arn:aws:iam::…   # el Principal de la política de confianza
   KUBEBOLT_EXTERNAL_ID=…                       # el sts:ExternalId
   ```

   - **Cloud:** el principal es el de KubeBolt Cloud.
   - **Open source dentro del clúster:** el principal es el rol `permisos-ia-kubebolt-api`, que el chart recibe en `mcpConnectors.aws.principalArn`. Puedes dejar `KUBEBOLT_AWS_PRINCIPAL_ARN` vacío; el External ID sí hay que copiarlo.
3. `make up` otra vez. Solo actualiza la confianza del rol.
4. En el panel, pega el ARN del rol y elige la región del laboratorio (`us-east-2`) y la ubicación del AWS MCP Server. Pulsa **Test connection** y luego **Save and enable**.

   ```bash
   aws iam get-role --role-name permisos-ia-kubebolt-readonly --query Role.Arn --output text
   ```

Cloud comprueba cada hora que el rol exige el External ID: lo intenta asumir sin él y AWS lo tiene que rechazar. En CloudTrail verás esos `AssumeRole` denegados con la sesión `kubebolt-external-id-check`; es lo esperado.

Cada llamada de Kobi queda en CloudTrail con la sesión `kubebolt-kobi`, y las de Autopilot con `kubebolt-autopilot`. En KubeBolt queda un registro `mcp_tool_call` por llamada, en el historial de acciones. Más en [Cloud connectors](https://kubebolt.io/es/docs/cloud-connectors/).

## Quitarlo

```bash
make kubebolt-quitar
```

Desinstala el agente y, si está, KubeBolt open source con sus volúmenes. En KubeBolt Cloud, borra el clúster de **Fleet** y revoca su token.

## ¿Lo quieres en tu equipo?

- **[Empieza gratis en KubeBolt Cloud →](https://app.kubebolt.io/signup)**
- Planes y precios: [kubebolt.io/pricing](https://kubebolt.io/pricing/)
- Documentación en español: [kubebolt.io/es/docs](https://kubebolt.io/es/docs/)
- Open source: [github.com/clm-cloud-solutions/kubebolt](https://github.com/clm-cloud-solutions/kubebolt)
- Una demo con tu caso: [kubebolt.io/demo](https://kubebolt.io/demo/) o [hello@kubebolt.io](mailto:hello@kubebolt.io)
