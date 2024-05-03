# MongoDB on K8S

## Setup

```shell
alias k=kubectl

colima start -c 6 -m 16 -k

helm upgrade --install community-operator community-operator --repo https://mongodb.github.io/helm-charts --namespace mongodb --create-namespace --wait
k apply -f mongodb/mongodb.yaml
k -n mongodb rollout status statefulset/mongodb
k -n mongodb get all
k -n mongodb get secret
k -n mongodb get secret mongodb-admin-admin -o json | jq -r '.data | with_entries(.value |= @base64d)'
k -n mongodb get secret mongodb-tekton-chains-tekton -o json | jq -r '.data | with_entries(.value |= @base64d)'

k run mongosh --rm -it --restart=Never --image mongo -- sh
mongosh 'mongodb://admin:foo^bar@mongodb-0.mongodb-svc.mongodb.svc.cluster.local:27017/admin?replicaSet=mongodb&ssl=false'
mongosh 'mongodb+srv://admin:foo^bar@mongodb-svc.mongodb.svc.cluster.local/admin?replicaSet=mongodb&ssl=false'
mongosh 'mongodb://tekton:foo^bar@mongodb-0.mongodb-svc.mongodb.svc.cluster.local:27017/tekton-chains?replicaSet=mongodb&ssl=false'
mongosh 'mongodb+srv://tekton:foo^bar@mongodb-svc.mongodb.svc.cluster.local/tekton-chains?replicaSet=mongodb&ssl=false'
```

## Cleanup

```shell
k delete -f mongodb/mongodb.yaml
colima delete -f
```

## References

- <https://github.com/mongodb/mongodb-kubernetes-operator>
- <https://github.com/mongodb/mongodb-kubernetes-operator/blob/master/docs/users.md>
- <https://www.mongodb.com/docs/manual/core/security-scram/>
- <https://www.mongodb.com/docs/manual/reference/built-in-roles/#std-label-self-hosted-built-in-roles>
