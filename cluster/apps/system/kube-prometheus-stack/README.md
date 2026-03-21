# kube-prometheus-stack

Stack de monitoring complète pour le cluster k3s mono-noeud.

## Composants déployés

| Composant | URL | Description |
|---|---|---|
| Grafana | https://grafana.int.fabsys.ovh | Dashboards |
| Prometheus | https://prometheus.int.fabsys.ovh | Métriques & requêtes |
| Alertmanager | https://alertmanager.int.fabsys.ovh | Gestion des alertes |

## Avant de déployer

### 1. Mettre à jour la version du chart

Vérifier la dernière version disponible :
```bash
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update
helm search repo prometheus-community/kube-prometheus-stack
```
Mettre à jour `Chart.yaml` avec la version trouvée, puis :
```bash
helm dependency update cluster/apps/system/kube-prometheus-stack/
```

### 2. Générer le SealedSecret Grafana (mot de passe admin)

```bash
kubectl create secret generic grafana-admin-secret \
  --from-literal=admin-user=admin \
  --from-literal=admin-password='TON_MOT_DE_PASSE' \
  -n monitoring --dry-run=client -o yaml \
| kubeseal --cert sealed-secrets-fixed-key.pem -o yaml \
> cluster/apps/system/kube-prometheus-stack/templates/grafana-admin-secret.yaml
```

### 3. Générer le SealedSecret Alertmanager (config Telegram)

Créer un fichier temporaire `alertmanager.yaml` (ne pas committer) :
```yaml
global:
  resolve_timeout: 5m
route:
  group_by: ['alertname', 'namespace']
  group_wait: 10s
  group_interval: 5m
  repeat_interval: 12h
  receiver: 'telegram'
receivers:
  - name: 'telegram'
    telegram_configs:
      - bot_token: 'TON_BOT_TOKEN'
        chat_id: TON_CHAT_ID
        parse_mode: HTML
inhibit_rules:
  - source_matchers:
      - severity="critical"
    target_matchers:
      - severity="warning"
    equal: ['alertname', 'namespace']
```

Obtenir un bot Telegram : parler à [@BotFather](https://t.me/BotFather) → `/newbot`
Obtenir ton chat_id : parler à [@userinfobot](https://t.me/userinfobot)

Sceller le secret :
```bash
kubectl create secret generic alertmanager-config \
  --from-file=alertmanager.yaml=./alertmanager.yaml \
  -n monitoring --dry-run=client -o yaml \
| kubeseal --cert sealed-secrets-fixed-key.pem -o yaml \
> cluster/apps/system/kube-prometheus-stack/templates/alertmanager-secret.yaml

# Supprimer le fichier temporaire
rm alertmanager.yaml
```

### 4. Ajouter l'app dans ArgoCD

Déjà fait dans `cluster/argocd-apps/values.yaml`.

## Dashboards Grafana recommandés

Ces dashboards sont inclus par défaut via `defaultDashboardsEnabled: true` :
- Kubernetes / Compute Resources / Cluster
- Kubernetes / Compute Resources / Node
- Kubernetes / Compute Resources / Pod
- Node Exporter / Nodes

Dashboards supplémentaires à importer manuellement (Dashboards → Import) :
- **Node Exporter Full** : ID `1860`

## Notes k3s

Les composants `kubeControllerManager`, `kubeScheduler`, `kubeEtcd` et `kubeProxy`
sont désactivés car ils tournent en mode embarqué dans k3s et ne sont pas accessibles
via les endpoints standards. Les laisser activés génère des alertes "down" permanentes.

## PVCs créés

| Nom | Taille | Namespace |
|---|---|---|
| prometheus-data | 10Gi | monitoring |
| grafana-data | 2Gi | monitoring |
| alertmanager-data | 1Gi | monitoring |

Stockage class utilisée : `local-path` (défaut k3s)
