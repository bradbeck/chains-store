# Tekton Chains Attestation Storage Example

An example of deploying and using Tekton Chains with Hashicorp Vault and MongoDB.

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

k -n mongodb get mdbc mongodb -o json | jq '.status'

k -n tekton-chains logs deploy/tekton-chains-controller -c tekton-chains-controller --tail=-1 -f


k apply -f hello-pr.yaml
tkn pr logs --last -f
k get tr hello-pr-hello -o json | jq .metadata.annotations

k run mongosh --rm -it --restart=Never --image mongo -- sh
mongosh 'mongodb://tekton:foo!bar@mongodb-0.mongodb-svc.mongodb.svc.cluster.local:27017/tekton-chains?authSource=admin&replicaSet=mongodb'
db.getCollection("bar").find({})
db.getCollection("bar").deleteMany({})

k -n tekton-chains logs -c vault-agent-init deploy/busybox --tail=-1
k -n tekton-chains logs -c vault-agent deploy/busybox --tail=-1
k -n tekton-chains exec -it -c busybox deploy/busybox -- sh
ls -al /home/nonroot
cat /home/nonroot/MONGO_SERVER_URL && echo

k -n tekton-chains get cm chains-config -o yaml
k -n tekton-chains edit cm chains-config
k -n tekton-chains get pod 
k -n tekton-chains logs deploy/tekton-chains-controller -c vault-agent -f
k -n tekton-chains exec -it -c vault-agent deploy/tekton-chains-controller -- /bin/sh
ls -al /home/nonroot
k -n tekton-chains exec -it -c tekton-chains-controller deploy/tekton-chains-controller -- /bin/sh
ls -al /home/nonroot
cat /home/nonroot/config && echo
```

## Cleanup

```shell
k delete -f hello-pr.yaml
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
- <https://peterdaugaardrasmussen.com/2021/12/01/terraform-create-resources-from-kubernetes-yaml-files-with-multiple-configurations/>
- <https://github.com/philips-labs/spiffe-vault/blob/main/example/vault/modules/transit/main.tf>
- <https://github.com/GoogleCloudPlatform/cloud-ops-sandbox/blob/main/provisioning/terraform/online-boutique.tf#L59>
- <https://github.com/mongodb/helm-charts/>
- <https://github.com/mongodb/mongodb-kubernetes-operator/blob/master/config/samples/mongodb.com_v1_mongodbcommunity_cr.yaml>
