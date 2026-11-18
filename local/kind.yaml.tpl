# Clúster kind del laboratorio: un solo nodo (el de control), con la auditoría
# del API server activada (local/audit-policy.yaml). scripts/local-up.sh sustituye
# ${LAB_DIR} por la ruta absoluta del repositorio.
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
name: permisos-ia
nodes:
  - role: control-plane
    extraMounts:
      - hostPath: ${LAB_DIR}/local/audit-policy.yaml
        containerPath: /etc/kubernetes/audit/policy.yaml
        readOnly: true
    kubeadmConfigPatches:
      - |
        kind: ClusterConfiguration
        apiServer:
          extraArgs:
            audit-policy-file: /etc/kubernetes/audit/policy.yaml
            audit-log-path: /var/log/kubernetes/audit.log
            audit-log-maxsize: "50"
            audit-log-maxbackup: "2"
          extraVolumes:
            - name: audit-policy
              hostPath: /etc/kubernetes/audit/policy.yaml
              mountPath: /etc/kubernetes/audit/policy.yaml
              readOnly: true
              pathType: File
            - name: audit-log
              hostPath: /var/log/kubernetes
              mountPath: /var/log/kubernetes
              readOnly: false
              pathType: DirectoryOrCreate
