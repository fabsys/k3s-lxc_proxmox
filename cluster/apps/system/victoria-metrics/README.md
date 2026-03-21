# victoria-metrics

Stack de monitoring légère pour le cluster k3s mono-noeud.
Remplace kube-prometheus-stack par une solution 3-4x moins gourmande en RAM.

## Composants déployés

| Composant | URL | Description |
|---|---|---|
| Grafana | https://grafana.int.fabsys.ovh | Dashboards |
| VictoriaMetrics | https://vm.int.fabsys.ovh | Stockage métriques + requêtes PromQL |
| Alertmanager | https://alertmanager.int.fabsys.ovh | Gestion des alertes |

VictoriaMetrics expose une API 100% compatible PromQL — les dashboards Grafana
conçus pour Prometheus fonctionnent sans modification.

## Avant de déployer

### 0. Récupérer le certificat sealed-secrets (sealed-secrets-fixed-key.pem)

Le fichier `sealed-secrets-fixed-key.pem` est le certificat public du contrôleur
sealed-secrets. Il est nécessaire pour chiffrer les secrets avec `kubeseal`.

**Méthode simple via kubeseal :**
```bash
kubeseal --fetch-cert \
  --controller-name=sealed-secrets-controller \
  --controller-namespace=kube-system \
> sealed-secrets-fixed-key.pem
```

**Méthode alternative via kubectl :**
```bash
kubectl get secret -n kube-system \
  -l sealedsecrets.bitnami.com/sealed-secrets-key=active \
  -o jsonpath='{.items[0].data.tls\.crt}' \
  | base64 -d > sealed-secrets-fixed-key.pem
```

Ce fichier est public (c'est un certificat, pas une clé privée), il peut être
commité dans le repo si besoin, mais ne l'est pas ici par convention.

### 1. Vérifier et mettre à jour la version du chart

```bash
helm repo add victoriametrics https://victoriametrics.github.io/helm-charts/
helm repo update
helm search repo victoriametrics/victoria-metrics-k8s-stack
```

Mettre à jour la version dans `Chart.yaml`, puis générer le Chart.lock :
```bash
helm dependency update cluster/apps/system/victoria-metrics/
```

### 2. Générer le SealedSecret Grafana (mot de passe admin)

```bash
kubectl create secret generic grafana-admin-secret \
  --from-literal=admin-user=admin \
  --from-literal=admin-password='TON_MOT_DE_PASSE' \
  -n monitoring --dry-run=client -o yaml \
| kubeseal --cert sealed-secrets-fixed-key.pem -o yaml \
> cluster/apps/system/victoria-metrics/templates/grafana-admin-secret.yaml
```

### 3. Générer le SealedSecret Alertmanager (config Telegram)

Obtenir les credentials Telegram :
- Bot token : parler à **@BotFather** → `/newbot`
- Chat ID : parler à **@userinfobot**

Créer un fichier temporaire `alertmanager.yaml` **(ne pas committer)** :
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

Sceller et nettoyer :
```bash
kubectl create secret generic alertmanager-config \
  --from-file=alertmanager.yaml=./alertmanager.yaml \
  -n monitoring --dry-run=client -o yaml \
| kubeseal --cert sealed-secrets-fixed-key.pem -o yaml \
> cluster/apps/system/victoria-metrics/templates/alertmanager-secret.yaml

rm alertmanager.yaml
```

### 4. Supprimer l'ancien dossier kube-prometheus-stack

```bash
rm -rf cluster/apps/system/kube-prometheus-stack/
```

L'entrée ArgoCD a déjà été mise à jour dans `argocd-apps/values.yaml`.

## Dashboards Grafana recommandés

Importer via Dashboards → Import → ID :

| Dashboard | ID | Description |
|---|---|---|
| Node Exporter Full | `1860` | CPU, RAM, disque, réseau du noeud |
| VictoriaMetrics | `10229` | Métriques internes de VM |
| Kubernetes cluster | `7249` | Vue globale du cluster k3s |

## Consommation RAM estimée

| Composant | RAM |
|---|---|
| VictoriaMetrics single | ~100-200MB |
| VMAgent | ~50MB |
| VMAlert | ~30MB |
| Alertmanager | ~50MB |
| Grafana | ~150MB |
| **Total** | **~400-500MB** |

## PVCs créés

| Composant | Taille |
|---|---|
| VictoriaMetrics data | 5Gi |
| Grafana data | 2Gi |
| Alertmanager data | 1Gi |

Stockage class utilisée : `local-path` (défaut k3s)

## Notes k3s

Les composants `kubeControllerManager`, `kubeScheduler`, `kubeEtcd` et `kubeProxy`
sont désactivés — ils tournent en mode embarqué dans k3s et génèrent des alertes
"down" permanentes si activés.
