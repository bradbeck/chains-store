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
  name  = "example/config"
  data_json = jsonencode(
    {
      username = "exampleUser"
      password = "examplePass"
    }
  )
}

resource "vault_policy" "example-policy" {
  name   = "example-policy"
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
  bound_service_account_names      = ["default"]
  bound_service_account_namespaces = ["default"]
  token_ttl                        = 300
  token_policies                   = [vault_policy.example-policy.name, vault_policy.transit-policy.name]
}

# data "http" "tekton-pipeline" {
#   url = "https://storage.googleapis.com/tekton-releases/pipeline/previous/v0.56.2/release.yaml"
# }

# data "kubectl_file_documents" "tekton-pipeline" {
#   content = data.http.tekton-pipeline.response_body
# }

# resource "kubectl_manifest" "tekton-pipeline" {
#   count     = length(data.kubectl_file_documents.tekton-pipeline.documents)
#   yaml_body = element(data.kubectl_file_documents.tekton-pipeline.documents, count.index)
# }

# resource "kubectl_manifest" "tekton-pipeline" {
#   yaml_body = file("pipeline-release.yaml")
# }

resource "kubectl_manifest" "busybox" {
  depends_on = [ vault_kubernetes_auth_backend_role.role, vault_transit_secret_backend_key.tekton-key ]
  yaml_body = templatefile("busybox.yaml", {
    vault-secret-mount = vault_kv_secret_v2.secret.mount
    vault-secret-path = vault_kv_secret_v2.secret.name
    vault-role = var.v-role-name
  })
}
