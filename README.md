# installation argocd
helm repo add argo https://argoproj.github.io/argo-helm
helm repo update
helm dependency build cluster/argocd/  
helm upgrade --install argocd cluster/argocd/ --namespace=argocd --create-namespace --wait

# installation des apps
kubectl apply -f cluster/root-app.yaml


~~helm upgrade --install argocd-apps cluster/argocd-apps/ --namespace=argocd --wait~~
