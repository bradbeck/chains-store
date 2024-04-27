# Chains Attestation Storage Example

## Setup

```shell
alias k=kubectl

colima start -c 6 -m 16 -k

terraform init --upgrade
terraform apply -auto-approve -compact-warnings
```

## Debug

```shell
k get clusterrolebinding vault-server-binding -o yaml
k run curl --rm -it --restart=Never --image quay.io/curl/curl:latest -- sh

export VAULT_ADDR='http://0.0.0.0:8200'
vault login root
vault auth list
vault policy list
vault secrets list
vault policy read transit-policy

k -n vault describe sa vault

k exec -it -c busybox deploy/busybox -- sh
ls -al /home/nonroot
cat /home/nonroot/config && echo
```

## Cleanup

```shell
terraform apply -destroy -auto-approve -compact-warnings
k delete crd --all
colima delete -f
rm -rf .terraform* terraform*
```

## References

- <https://github.com/hashicorp/vault-helm>
- <https://github.com/jacobmammoliti/vault-terraform-demo>
- <https://github.com/filhodanuvem/from-dev-to-ops/blob/master/5-secrets/tf/kubernetes.tf#L19>
- <https://github.com/buildpacks/ci/blob/main/k8s/tekton.tf#L34>
