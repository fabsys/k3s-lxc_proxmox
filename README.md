# installation argocd
helm dependency build cluster/argocd/
helm upgrade --install argocd cluster/argocd/ --namespace=argocd --create-namespace --wait

# installation des apps
helm upgrade --install argocd-apps cluster/argocd-apps/ --namespace=argocd --wait