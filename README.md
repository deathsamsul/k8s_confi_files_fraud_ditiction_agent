# Fraud Detection Platform — Kubernetes Infrastructure

Kubernetes deployment manifests for the fraud detection MLOps platform. This repository covers the infrastructure layer only — provisioning, service configuration, and bootstrap jobs.

Application and model training code lives in [`fraud_detection_mlops`](../fraud_detection_mlops).

---

## Architecture

```
CloudNativePG → PostgreSQL init → MinIO → MLflow → Bootstrap jobs → FastAPI → Airflow
```

| Component | Namespace | Responsibility |
|---|---|---|
| CloudNativePG | `database` | PostgreSQL cluster for MLflow metadata and prediction logging |
| MinIO | `mlops` | S3-compatible artifact storage |
| MLflow | `mlflow` | Experiment tracking and model registry |
| Airflow | `airflow` | Scheduled retraining workflows |
| FastAPI | `fraud-api` | Real-time fraud prediction API |

Namespaces are isolated by service boundary to simplify lifecycle management and reduce cross-service coupling.

---

## Design Decisions

**Why CloudNativePG instead of a plain PostgreSQL pod**
A standalone PostgreSQL pod loses data if it restarts without careful PVC management. CloudNativePG handles failover, backup, and connection pooling natively inside Kubernetes — less operational overhead for a stateful workload that everything else depends on.

**Why MinIO instead of cloud object storage**
MinIO exposes an S3-compatible API, so MLflow connects to it with the same boto3 configuration it would use for AWS S3. Swapping to real S3 in production requires changing one environment variable, not rewriting anything.

**Model promotion via aliases**
Models are registered in MLflow and promoted using aliases (`Production`, `Staging`) rather than version pinning. The inference service loads whichever model holds the `Production` alias at startup — so retraining and promotion never require a FastAPI redeployment.

**Dataset bootstrap via temporary pod**
Kubernetes Jobs cannot accept external file input directly. The solution is a short-lived pod with a shared PVC — copy the dataset in via `kubectl cp`, then delete the pod. The data persists on the PVC and is available to subsequent training jobs.

---

## Prerequisites

- Kubernetes cluster — tested on Docker Desktop and kind
- `kubectl` configured against your target cluster
- `helm` v3+
- Training dataset at `~/projects/fraud_detection_mlops/datasets/fraud_train_data.csv`

---

## 1. PostgreSQL — CloudNativePG

```bash
cd k8s/cnpg

kubectl apply -f namespace.yaml
kubectl apply --server-side -f \
  https://raw.githubusercontent.com/cloudnative-pg/cloudnative-pg/release-1.23/releases/cnpg-1.23.3.yaml

# Wait for the operator pod to be Running
kubectl get pods -n cnpg-system

kubectl apply -f secret.yaml
kubectl apply -f postgres-cluster.yaml

# Watch until all cluster pods are Running
kubectl get cluster -n database
kubectl get pods -n database -w
```

Once the cluster is healthy, run the init job to create databases and users:

```bash
kubectl apply -f postgres-init-job.yaml
kubectl logs -n database job/postgres-init-job
```

---

## 2. MinIO

```bash
cd k8s/minio

kubectl apply -f namespace.yaml
kubectl apply -f secret.yaml
kubectl apply -f pvc.yaml
kubectl apply -f service.yaml
kubectl apply -f statefulset.yaml
kubectl apply -f bucket-job.yaml

# Verify
kubectl logs -n mlops statefulset/minio
kubectl logs -n mlops job/minio-create-bucket
```

The bucket job creates `mlflow-artifacts`, which MLflow uses as its artifact root.

---

## 3. MLflow

MLflow requires both PostgreSQL and MinIO to be healthy before it starts. Deploy after both are confirmed running.

```bash
cd k8s/mlflow

kubectl apply -f namespace.yaml
kubectl apply -f secret.yaml
kubectl apply -f configmap.yaml
kubectl apply -f deployment.yaml
kubectl apply -f service.yaml

kubectl get pods -n mlflow
kubectl get deployment -n mlflow
```

---

## 4. Bootstrap Jobs

One-time jobs that load the training dataset and train the initial model. These do not need to run again unless the PVC is deleted.

```bash
cd k8s/startup_job

kubectl apply -f namespace.yaml
kubectl apply -f configmap.yaml
kubectl apply -f secret.yaml
kubectl apply -f pvc.yaml
```

**Copy the dataset into the cluster:**

```bash
kubectl apply -f tem_pod.yaml

# Wait for Running
kubectl get pod dataset-copy-pod -n fraud-mlops

# Copy dataset
kubectl cp /home/sam/projects/fraud_detection_mlops/datasets/fraud_train_data.csv \
  fraud-mlops/dataset-copy-pod:/opt/datasets/fraud_train_data.csv \
  -c copy

# Verify
kubectl exec -n fraud-mlops dataset-copy-pod -- ls -lh /opt/datasets

# Clean up
kubectl delete pod dataset-copy-pod -n fraud-mlops
```

**Store training data to PVC:**

```bash
kubectl apply -f store-training-data-job.yaml
kubectl logs job/store-training-data -n fraud-mlops

# 1/1 = complete — 0/1 = still running or failed
kubectl get jobs -n fraud-mlops
```

**Train and register the initial model:**

```bash
kubectl apply -f initial-model-job.yaml
kubectl logs job/initial-model -n fraud-mlops
kubectl get jobs -n fraud-mlops
```

This registers the baseline model in MLflow under the `Production` alias.

---

## 5. FastAPI — Inference Service

```bash
cd k8s/fastapi

kubectl apply -f namespace.yaml
kubectl apply -f configmap.yaml
kubectl apply -f secret.yaml
kubectl apply -f deployment.yaml
kubectl apply -f service.yaml

kubectl get pods -n fraud-api
```

Test with port-forward:

```bash
kubectl port-forward svc/fraud-api-service -n fraud-api 8000:80
```

| Endpoint | URL |
|---|---|
| Swagger UI | http://localhost:8000/docs |
| Health check | http://localhost:8000/health |

---

## 6. Airflow

Deployed via the official Helm chart with a custom values file that configures connections to PostgreSQL and MinIO.

```bash
cd ~/projects/fraud-detection-k8s

kubectl config current-context

helm repo add apache-airflow https://airflow.apache.org
helm repo update

helm upgrade --install airflow apache-airflow/airflow \
  --namespace airflow \
  --create-namespace \
  -f k8s/airflow/airflow-values.yaml

helm list -n airflow
kubectl get pods -n airflow
```

---

## Repository Layout

```
k8s/
├── cnpg/
│   ├── namespace.yaml
│   ├── secret.yaml
│   ├── postgres-cluster.yaml
│   └── postgres-init-job.yaml
├── minio/
│   ├── namespace.yaml
│   ├── secret.yaml
│   ├── pvc.yaml
│   ├── service.yaml
│   ├── statefulset.yaml
│   └── bucket-job.yaml
├── mlflow/
│   ├── namespace.yaml
│   ├── secret.yaml
│   ├── configmap.yaml
│   ├── deployment.yaml
│   └── service.yaml
├── startup_job/
│   ├── namespace.yaml
│   ├── configmap.yaml
│   ├── secret.yaml
│   ├── pvc.yaml
│   ├── tem_pod.yaml
│   ├── store-training-data-job.yaml
│   └── initial-model-job.yaml
├── fastapi/
│   ├── namespace.yaml
│   ├── configmap.yaml
│   ├── secret.yaml
│   ├── deployment.yaml
│   └── service.yaml
└── airflow/
    └── airflow-values.yaml
```

---

## Teardown

```bash
kubectl delete namespace fraud-api fraud-mlops mlflow mlops database airflow cnpg-system
```

This removes all workloads and PVCs. Back up the MinIO volume first if you want to keep MLflow runs and registered models.

---

## Notes

- Secrets in this repo use placeholder values — replace before deploying outside of a local environment
- Bootstrap jobs are one-time — they do not re-run unless the PVC is deleted
- After initial deployment, Airflow handles all subsequent retraining automatically
