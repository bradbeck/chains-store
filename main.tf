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

###
data "http" "tekton-pipeline" {
  url = "https://storage.googleapis.com/tekton-releases/pipeline/previous/v0.56.2/release.yaml"
}

locals {
  p_m = {
    for i, value in [
      for yaml in split(
        "\n---\n",
        "\n${replace(data.http.tekton-pipeline.response_body, "/(?m)^---[[:blank:]]*(#.*)?$/", "---")}\n"
      ) :
      yamldecode(yaml)
      if trimspace(replace(yaml, "/(?m)(^[[:blank:]]*(#.*)?$)+/", "")) != ""
    ] : tostring(i) => value
  }
  # n_keys = compact([for i, m in local.p_m : m.kind == "Namespace" ? i : ""])
  namespaces = [for key in compact([for i, m in local.p_m : m.kind == "Namespace" ? i : ""]) : lookup(local.p_m, key)]
  sas = [for key in compact([for i, m in local.p_m : m.kind == "ServiceAccount" ? i : ""]) : lookup(local.p_m, key)]
  crs = [for key in compact([for i, m in local.p_m : m.kind == "ClusterRole" ? i : ""]) : lookup(local.p_m, key)]
  crbs = [for key in compact([for i, m in local.p_m : m.kind == "ClusterRoleBinding" ? i : ""]) : lookup(local.p_m, key)]
  rs = [for key in compact([for i, m in local.p_m : m.kind == "Role" ? i : ""]) : lookup(local.p_m, key)]
  rbs = [for key in compact([for i, m in local.p_m : m.kind == "RoleBinding" ? i : ""]) : lookup(local.p_m, key)]
  ss = [for key in compact([for i, m in local.p_m : m.kind == "Secret" ? i : ""]) : lookup(local.p_m, key)]
  cms = [for key in compact([for i, m in local.p_m : m.kind == "ConfigMap" ? i : ""]) : lookup(local.p_m, key)]
  ds = [for key in compact([for i, m in local.p_m : m.kind == "Deployment" ? i : ""]) : lookup(local.p_m, key)]
  svcs = [for key in compact([for i, m in local.p_m : m.kind == "Service" ? i : ""]) : lookup(local.p_m, key)]

  hpas = [for key in compact([for i, m in local.p_m : m.kind == "HorizontalPodAutoscaler" ? i : ""]) : lookup(local.p_m, key)]
  crds = [for key in compact([for i, m in local.p_m : m.kind == "CustomResourceDefinition" ? i : ""]) : lookup(local.p_m, key)]
  vwcs = [for key in compact([for i, m in local.p_m : m.kind == "ValidatingWebhookConfiguration" ? i : ""]) : lookup(local.p_m, key)]
}

resource "kubectl_manifest" "pipeline_ns" {
  depends_on = [ vault_kubernetes_auth_backend_role.role ]
  count = length(local.namespaces)
  yaml_body = yamlencode(element(local.namespaces, count.index))
}

resource "kubectl_manifest" "pipeline_sa" {
  depends_on = [ kubectl_manifest.pipeline_ns ]
  count = length(local.sas)
  yaml_body = yamlencode(element(local.sas, count.index))
}

resource "kubectl_manifest" "pipeline_cr" {
  depends_on = [ kubectl_manifest.pipeline_sa ]
  count = length(local.crs)
  yaml_body = yamlencode(element(local.crs, count.index))
}

resource "kubectl_manifest" "pipeline_crb" {
  depends_on = [ kubectl_manifest.pipeline_cr ]
  count = length(local.crbs)
  yaml_body = yamlencode(element(local.crbs, count.index))
}

resource "kubectl_manifest" "pipeline_r" {
  depends_on = [ kubectl_manifest.pipeline_crb ]
  count = length(local.rs)
  yaml_body = yamlencode(element(local.rs, count.index))
}

resource "kubectl_manifest" "pipeline_rb" {
  depends_on = [ kubectl_manifest.pipeline_r ]
  count = length(local.rbs)
  yaml_body = yamlencode(element(local.rbs, count.index))
}

resource "kubectl_manifest" "pipeline_s" {
  depends_on = [ kubectl_manifest.pipeline_rb ]
  count = length(local.ss)
  yaml_body = yamlencode(element(local.ss, count.index))
}

resource "kubectl_manifest" "pipeline_cm" {
  depends_on = [ kubectl_manifest.pipeline_s ]
  count = length(local.cms)
  yaml_body = yamlencode(element(local.cms, count.index))
}

resource "kubectl_manifest" "pipeline_d" {
  depends_on = [ kubectl_manifest.pipeline_cm ]
  count = length(local.ds)
  yaml_body = yamlencode(element(local.ds, count.index))
}

resource "kubectl_manifest" "pipeline_svc" {
  depends_on = [ kubectl_manifest.pipeline_d ]
  count = length(local.svcs)
  yaml_body = yamlencode(element(local.svcs, count.index))
}

data "http" "tekton-chains" {
  url = "https://storage.googleapis.com/tekton-releases/chains/previous/v0.20.1/release.yaml"
}

data "kubectl_file_documents" "tekton-chains" {
  content = data.http.tekton-chains.response_body
}

resource "kubectl_manifest" "tekton-chains" {
  depends_on = [ kubectl_manifest.pipeline_svc ]
  count     = length(data.kubectl_file_documents.tekton-chains.documents)
  yaml_body = element(data.kubectl_file_documents.tekton-chains.documents, count.index)
}

# resource "kubernetes_manifest" "busybox" {
#   depends_on = [ vault_kubernetes_auth_backend_role.role, vault_transit_secret_backend_key.tekton-key ]
#   manifest = yamldecode(templatefile("busybox.yaml", {
#     vault-secret-mount = vault_kv_secret_v2.secret.mount
#     vault-secret-path = vault_kv_secret_v2.secret.name
#     vault-role = var.v-role-name
#   }))
# }

# resource "kubectl_manifest" "busybox" {
#   depends_on = [ vault_kubernetes_auth_backend_role.role, vault_transit_secret_backend_key.tekton-key ]
#   yaml_body = templatefile("busybox.yaml", {
#     vault-secret-mount = vault_kv_secret_v2.secret.mount
#     vault-secret-path = vault_kv_secret_v2.secret.name
#     vault-role = var.v-role-name
#   })
# }
