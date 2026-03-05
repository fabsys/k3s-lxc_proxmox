# Creation du rclone.conf
```
kubectl create secret generic rclone-config \
--from-file=rclone.conf=/chemin/vers/ton/rclone.conf \
-n paperless --dry-run=client -o yaml \
| kubeseal -o yaml -n paperless \
> cluster/apps/paperless/rclone-secret.yaml
```



# Creation du secret restic
```
kubectl create secret generic restic-secret \
--from-literal=RESTIC_PASSWORD='un-mot-de-passe-fort-a-garder-
precieusement' \
-n paperless --dry-run=client -o yaml \
| kubeseal -o yaml -n paperless \
> cluster/apps/paperless/restic-secret.yaml
```

