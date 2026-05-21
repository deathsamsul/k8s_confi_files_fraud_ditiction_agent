# Fraud Detection — Kubernetes Deployment

Production deployment of the fraud detection MLOps pipeline on Kubernetes, using CloudNativePG, MinIO, MLflow, Apache Airflow, and FastAPI.

This repo handles the infrastructure side. The application code lives in [fraud-detection-mlops](../fraud_detection_mlops).

---

## What's running in the cluster

| Service | Namespace | Purpose |
|---|---|---|
| PostgreSQL (CloudNativePG) | `database` | MLflow metadata backend + prediction logs |
| MinIO | `mlops` | S3-compatible artifact storage for MLflow |
| MLflow | `mlflow` | Experiment tracking and model registry |
| Airflow | `airflow` | Retraining DAG orchestration |
| FastAPI | `fraud-api` | Real-time fraud prediction API |

---

## Prerequisites

- Kubernetes cluster (tested on Docker Desktop and kind)
- `kubectl` configured and pointing at your cluster
- `helm` v3+
- The training dataset at `~/projects/fraud_detection_mlops/datasets/fraud_train_data.csv`

---

## Deployment Order

Services have dependencies — deploy in this order.

```
PostgreSQL → MinIO → MLflow → Startup Jobs → FastAPI → Airflow
```

---

## 1. PostgreSQL — CloudNativePG

```bash
cd k8s/cnpg

kubectl apply -f namespace.yaml
kubectl apply --server-side -f https://raw.githubusercontent.com/cloudnative-pg/cloudnative-pg/release-1.23/releases/cnpg-1.23.3.yaml

# Wait for the operator to be ready
kubectl get pods -n cnpg-system

kubectl apply -f secret.yaml
kubectl apply -f postgres-cluster.yaml
```

Wait for the cluster to come up:

```bash
kubectl get cluster -n database
kubectl get pods -n database -w
```

Once all pods show `Running`, apply the init job to create the required databases and users:

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
```

Check the pod and bucket creation:

```bash
kubectl logs -n mlops statefulset/minio
kubectl logs -n mlops job/minio-create-bucket
```

The bucket job creates the `mlflow-artifacts` bucket that MLflow will use as its artifact root.

---

## 3. MLflow

```bash
cd k8s/mlflow

kubectl apply -f namespace.yaml
kubectl apply -f secret.yaml
kubectl apply -f configmap.yaml
kubectl apply -f deployment.yaml
kubectl apply -f service.yaml
```

Verify:

```bash
kubectl get pods -n mlflow
kubectl get deployment -n mlflow
```

MLflow is configured to use PostgreSQL as its metadata backend and MinIO as its artifact store — both need to be healthy before this deployment will start correctly.

---

## 4. Startup Jobs

This step loads the training dataset into the cluster and trains the initial model.

```bash
cd k8s/startup_job

kubectl apply -f namespace.yaml
kubectl apply -f configmap.yaml
kubectl apply -f secret.yaml
kubectl apply -f pvc.yaml
```

### Copy the dataset

Spin up a temporary pod with a shared volume, copy the CSV into it, then delete the pod:

```bash
kubectl apply -f tem_pod.yaml

# Wait for the pod to be Running
kubectl get pod dataset-copy-pod -n fraud-mlops

# Copy dataset into the pod
kubectl cp /home/sam/projects/fraud_detection_mlops/datasets/fraud_train_data.csv \
  fraud-mlops/dataset-copy-pod:/opt/datasets/fraud_train_data.csv \
  -c copy

# Verify the file landed correctly
kubectl exec -n fraud-mlops dataset-copy-pod -- ls -lh /opt/datasets

# Done — clean up the temp pod
kubectl delete pod dataset-copy-pod -n fraud-mlops
```

### Store training data

```bash
kubectl apply -f store-training-data-job.yaml

kubectl get jobs -n fraud-mlops        # 1/1 = complete, 0/1 = running or failed
kubectl logs job/store-training-data -n fraud-mlops
```

### Train the initial model

```bash
kubectl apply -f initial-model-job.yaml

kubectl get jobs -n fraud-mlops
kubectl logs job/initial-model -n fraud-mlops
```

This job trains the baseline model and registers it in MLflow under the `Production` alias.

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

Test locally with port-forward:

```bash
kubectl port-forward svc/fraud-api-service -n fraud-api 8000:80
```

| Endpoint | URL |
|---|---|
| Swagger UI | http://localhost:8000/docs |
| Health check | http://localhost:8000/health |

---

## 6. Airflow

Deployed via the official Helm chart with a custom values file.

```bash
cd ~/projects/fraud-detection-k8s

kubectl config current-context    # confirm you're on the right cluster

helm repo add apache-airflow https://airflow.apache.org
helm repo update

helm upgrade --install airflow apache-airflow/airflow \
  --namespace airflow \
  --create-namespace \
  -f k8s/airflow/airflow-values.yaml
```

Check the rollout:

```bash
helm list -n airflow
kubectl get pods -n airflow
```

The `airflow-values.yaml` configures DAG sync from this repo, Airflow connections to PostgreSQL and MinIO, and the executor type.

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

## Namespaces

| Namespace | Services |
|---|---|
| `cnpg-system` | CloudNativePG operator |
| `database` | PostgreSQL cluster |
| `mlops` | MinIO |
| `mlflow` | MLflow tracking server |
| `fraud-mlops` | Training jobs, dataset storage |
| `fraud-api` | FastAPI inference service |
| `airflow` | Airflow scheduler, webserver, workers |

---

## Teardown

```bash
kubectl delete namespace fraud-api fraud-mlops mlflow mlops database airflow
kubectl delete namespace cnpg-system
```

This removes all workloads and PVCs. MLflow runs and model artifacts stored in MinIO will be lost unless you back up the MinIO volume first.

---

## Notes

- All secrets in this repo use placeholder values. Replace them before deploying to any non-local environment.
- The startup jobs (dataset copy + initial training) are one-time operations. They do not need to re-run unless the PVC is deleted.
- Airflow retraining DAGs will automatically handle model updates after the initial deployment.
