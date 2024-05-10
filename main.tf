terraform {
  required_providers {
    kubectl = {
      source  = "gavinbunney/kubectl"
    }
  }
}

provider "kubernetes" {
  config_path    = var.k8s-config-path
  config_context = var.k8s-config-context
}

provider "kubectl" {
  config_path = var.k8s-config-path
  config_context = var.k8s-config-context
}

provider "helm" {
  kubernetes {
    config_path    = var.k8s-config-path
    config_context = var.k8s-config-context
  }
}

provider "vault" {
  token   = "root"
  address = "http://localhost:8200"
}

resource "helm_release" "vault" {
  name             = "vault"
  namespace        = "vault"
  create_namespace = true

  repository = "https://helm.releases.hashicorp.com"
  chart      = "vault"

  set {
    name  = "injector.enabled"
    value = "true"
  }

  set {
    name = "server.dev.enabled"
    value = "true"
  }

  set {
    name = "server.dev.devRootToken"
    value = "root"
  }

  set {
    name = "ui.enabled"
    value = "true"
  }

  set {
    name = "ui.serviceType"
    value = "LoadBalancer"
  }

  set {
    name = "ui.serviceNodePort"
    value = "null"
  }

  set {
    name = "ui.externalPort"
    value = "8200"
  }
}

resource "helm_release" "mongodb" {
  name = "community-operator"
  namespace = "mongodb"
  create_namespace = true

  repository = "https://mongodb.github.io/helm-charts"
  chart = "community-operator"
}

resource "kubernetes_secret" "tmp-password" {
  depends_on = [ helm_release.mongodb ]
  metadata {
    name = "tmp-password"
    namespace = "mongodb"
  }
  data = {
    password = var.mongo-pass
  }
}

resource "kubectl_manifest" "mongodb" {
  depends_on = [ kubernetes_secret.tmp-password ]
  yaml_body = <<-EOY
    apiVersion: mongodbcommunity.mongodb.com/v1
    kind: MongoDBCommunity
    metadata:
      name: mongodb
      namespace: mongodb
    spec:
      members: 1
      type: ReplicaSet
      version: "6.0.13"
      security:
        authentication:
          modes: [ "SCRAM" ]
      users:
      - name: admin
        db: admin
        passwordSecretRef:
          name: tmp-password
        roles:
        - name: clusterAdmin
          db: admin
        - name: userAdminAnyDatabase
          db: admin
        scramCredentialsSecretName: admin
      - name: tekton
        db: admin
        passwordSecretRef:
          name: tmp-password
        roles:
        - name: readWrite
          db: tekton-chains
        scramCredentialsSecretName: tekton
      additionalMongodConfig:
        storage.wiredTiger.engineConfig.journalCompressor: zlib
  EOY
  wait = true
}

resource "null_resource" "wait_mongodb" {
  depends_on = [ kubectl_manifest.mongodb ]
  provisioner "local-exec" {
    command = <<EOF
while [[ -z $(kubectl -n mongodb get statefulset mongodb 2>/dev/null) ]]; do
  echo "waiting..."
  sleep 1
done
kubectl -n mongodb rollout status statefulset/mongodb
EOF
  }
}

resource "kubernetes_secret" "vault-token" {
  type = "kubernetes.io/service-account-token"
  metadata {
    name      = "vault-token"
    namespace = helm_release.vault.namespace
    annotations = {
      "kubernetes.io/service-account.name" = "vault"
    }
  }
}

resource "vault_auth_backend" "k8s" {
  depends_on = [ helm_release.vault ]
  type = "kubernetes"
}

data "kubernetes_secret" "vault-token" {
  depends_on = [kubernetes_secret.vault-token]
  metadata {
    name      = kubernetes_secret.vault-token.metadata[0].name
    namespace = kubernetes_secret.vault-token.metadata[0].namespace
  }
}

resource "vault_kubernetes_auth_backend_config" "auth" {
  backend                = vault_auth_backend.k8s.path
  kubernetes_host        = "https://kubernetes.default.svc"
  kubernetes_ca_cert     = data.kubernetes_secret.vault-token.data["ca.crt"]
  token_reviewer_jwt     = data.kubernetes_secret.vault-token.data.token
  disable_iss_validation = true
  disable_local_ca_jwt   = true
}

resource "vault_kv_secret_v2" "secret" {
  depends_on = [ helm_release.vault ]
  mount = "secret"
  name  = "tekton/mongodb-creds"
  data_json = jsonencode(
    {
      username = "tekton"
      password = var.mongo-pass
    }
  )
}

resource "vault_policy" "tekton-policy" {
  name   = "tekton-policy"
  policy = <<EOT
path "${vault_kv_secret_v2.secret.mount}/data/${vault_kv_secret_v2.secret.name}" {
  capabilities = ["read", "list"]
}
EOT
}

resource "vault_mount" "transit" {
  depends_on = [ helm_release.vault ]
  path = "transit"
  type = "transit"
}

resource "vault_transit_secret_backend_key" "tekton-key" {
  depends_on = [ vault_mount.transit ]
  backend = "transit"
  name = "tekton-key"
  type = "ecdsa-p521"
  deletion_allowed = true
}

resource "vault_policy" "transit-policy" {
  name   = "transit-policy"
  policy = <<EOT
path "${vault_mount.transit.path}/*" {
  capabilities = ["read"]
}
path "${vault_mount.transit.path}/sign/${vault_transit_secret_backend_key.tekton-key.name}" {
  capabilities = ["create", "read", "update"]
}
path "${vault_mount.transit.path}/sign/${vault_transit_secret_backend_key.tekton-key.name}/*" {
  capabilities = ["read", "update"]
}
path "${vault_mount.transit.path}/verify/${vault_transit_secret_backend_key.tekton-key.name}" {
  capabilities = ["create", "read", "update"]
}
path "${vault_mount.transit.path}/verify/${vault_transit_secret_backend_key.tekton-key.name}/*" {
  capabilities = ["read", "update"]
}
EOT
}

resource "vault_kubernetes_auth_backend_role" "role" {
  backend                          = vault_kubernetes_auth_backend_config.auth.backend
  role_name                        = var.v-role-name
  bound_service_account_names      = ["tekton-chains-controller"]
  bound_service_account_namespaces = ["tekton-chains"]
  token_ttl                        = 300
  token_policies                   = [vault_policy.tekton-policy.name, vault_policy.transit-policy.name]
}

resource "null_resource" "tekton_pipeline_kustomize" {
  depends_on = [ vault_kubernetes_auth_backend_role.role ]
  triggers = {
    kustomize_path = sha256("pipeline/kustomization.yaml")
  }
  provisioner "local-exec" {
    command  = "kubectl apply -k pipeline"
  }
}

resource "null_resource" "wait_tekton_pipeline" {
  depends_on = [ null_resource.tekton_pipeline_kustomize ]
  provisioner "local-exec" {
    command = <<EOF
kubectl -n tekton-pipelines rollout status deploy/tekton-pipelines-controller deploy/tekton-pipelines-webhook deploy/tekton-events-controller
kubectl -n tekton-pipelines-resolvers rollout status deploy/tekton-pipelines-remote-resolvers
EOF
  }
}

resource "null_resource" "tekton_chains_kustomize" {
  depends_on = [ null_resource.wait_tekton_pipeline, null_resource.wait_mongodb ]
  triggers = {
    kustomize_path = sha256("chains/kustomization.yaml")
  }
  provisioner "local-exec" {
    command     = "kubectl apply -k chains"
  }
}

resource "null_resource" "wait_tekton_chains" {
  depends_on = [ null_resource.tekton_chains_kustomize ]
  provisioner "local-exec" {
    command = <<EOF
kubectl -n tekton-chains rollout status deploy/tekton-chains-controller
EOF
  }
}

resource "kubernetes_manifest" "busybox" {
  depends_on = [ null_resource.wait_tekton_chains ]
  manifest = yamldecode(templatefile("busybox.yaml", {
    vault-secret-mount = vault_kv_secret_v2.secret.mount
    vault-secret-path = vault_kv_secret_v2.secret.name
    vault-role = var.v-role-name
  }))
}
