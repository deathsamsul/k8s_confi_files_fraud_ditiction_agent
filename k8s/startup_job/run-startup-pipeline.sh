#!/bin/bash
set -e

NAMESPACE=fraud-mlops

echo "Running store-training-data Job..."
kubectl apply -f store-training-data-job.yaml

echo "Waiting for store-training-data to complete..."
kubectl wait --for=condition=complete job/store-training-data -n $NAMESPACE --timeout=600s

echo "Store training data logs:"
kubectl logs job/store-training-data -n $NAMESPACE

echo "Running initial-model Job..."
kubectl apply -f initial-model-job.yaml

echo "Waiting for initial-model to complete..."
kubectl wait --for=condition=complete job/initial-model -n $NAMESPACE --timeout=1200s

echo "Initial model logs:"
kubectl logs job/initial-model -n $NAMESPACE

echo "Pipeline completed successfully."