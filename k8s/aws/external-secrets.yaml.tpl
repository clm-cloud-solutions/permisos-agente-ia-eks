# AWS: la contraseña de orders-api vive en Secrets Manager (${SECRET_NAME}) y
# External Secrets la copia al Secret orders-db-credentials cada minuto. Lee con
# su propia identidad de Pod Identity (rol ${NAME}-eso), que solo puede leer ese
# secreto. scripts/aws-up.sh sustituye las variables.
apiVersion: external-secrets.io/v1
kind: ClusterSecretStore
metadata:
  name: secretos
spec:
  provider:
    aws:
      service: SecretsManager
      region: ${AWS_REGION}
---
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: orders-db-credentials
  namespace: shop-backend
  labels: {app.kubernetes.io/part-of: kubeshop}
spec:
  refreshInterval: 1m
  secretStoreRef: {kind: ClusterSecretStore, name: secretos}
  target:
    name: orders-db-credentials   # claves username y password, como espera orders-api
    creationPolicy: Owner
  dataFrom:
    - extract: {key: ${SECRET_NAME}}
