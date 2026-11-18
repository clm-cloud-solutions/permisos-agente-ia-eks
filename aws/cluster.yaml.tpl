# Configuración de eksctl del clúster del laboratorio. scripts/aws-up.sh
# sustituye las ${...} con las salidas de la pila de CloudFormation y tu IP, y
# deja el resultado en .lab/cluster.yaml. No lo apliques a mano.
#
# - Nodos en subredes privadas; el endpoint público de la API de Kubernetes solo
#   acepta tu IP (${OPERATOR_CIDR}). Si tu IP cambia, vuelve a lanzar `make up`.
# - Pod Identity, no IRSA: External Secrets y, si lo instalas, el backend de
#   KubeBolt open source reciben credenciales de AWS por su ServiceAccount.
# - EBS CSI con su asociación de Pod Identity por defecto: solo lo usa KubeBolt
#   open source (sus volúmenes), y no cuesta nada si no lo instalas.
apiVersion: eksctl.io/v1alpha5
kind: ClusterConfig

metadata:
  name: ${NAME}
  region: ${AWS_REGION}
  version: "${EKS_VERSION}"
  tags: {Project: permisos-agente-ia-eks}

iam:
  withOIDC: false

autoModeConfig:
  enabled: false

accessConfig:
  authenticationMode: API
  bootstrapClusterCreatorAdminPermissions: true

vpc:
  id: ${VPC_ID}
  subnets:
    public:
      ${AZ_A}: {id: ${PUBLIC_SUBNET_A}}
      ${AZ_B}: {id: ${PUBLIC_SUBNET_B}}
    private:
      ${AZ_A}: {id: ${PRIVATE_SUBNET_A}}
      ${AZ_B}: {id: ${PRIVATE_SUBNET_B}}
  clusterEndpoints: {publicAccess: true, privateAccess: true}
  publicAccessCIDRs: ["${OPERATOR_CIDR}"]

addons:
  - name: vpc-cni
  - name: coredns
  - name: kube-proxy
  - name: eks-pod-identity-agent
  - name: metrics-server
  - name: aws-ebs-csi-driver
    useDefaultPodIdentityAssociations: true

managedNodeGroups:
  - name: ng
    instanceType: ${NODE_TYPE}
    amiFamily: AmazonLinux2023
    desiredCapacity: ${NODE_COUNT}
    minSize: ${NODE_COUNT}
    maxSize: ${NODE_COUNT}
    volumeSize: 30
    privateNetworking: true
    tags: {Project: permisos-agente-ia-eks}
