# installation argocd
helm dependency build cluster/argocd/  
helm upgrade --install argocd cluster/argocd/ --namespace=argocd --create-namespace --wait

# installation des apps
helm upgrade --install argocd-apps cluster/argocd-apps/ --namespace=argocd --wait  


nginx.ingress.kubernetes.io/whitelist-source-range: "192.168.1.0/24,203.0.113.4"