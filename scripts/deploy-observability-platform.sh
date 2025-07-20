#!/bin/bash
# scripts/deploy-observability-platform.sh

set -e

# Configuration
export PROJECT_PREFIX="observability-stack-1on1"
export REGION="australia-southeast1"
export BILLING_ACCOUNT_ID="${BILLING_ACCOUNT_ID:-my-log-account}"
export ORG_ID="${ORG_ID:-no-organisation}"

echo "🚀 Deploying Central Observability Platform"
echo "============================================="

# Step 1: Deploy observability project
echo "📦 Step 1: Creating central observability project..."
cd terraform/observability-project

terraform init
terraform plan -var="billing_account_id=${BILLING_ACCOUNT_ID}" -var="org_id=${ORG_ID}"
terraform apply -var="billing_account_id=${BILLING_ACCOUNT_ID}" -var="org_id=${ORG_ID}" -auto-approve

# Get outputs
export OBSERVABILITY_PROJECT_ID=$(terraform output -raw observability_project_id)
export PUBSUB_TOPIC=$(terraform output -raw pubsub_topic)
export STAGING_BUCKET=$(terraform output -raw staging_bucket)
export DATAFLOW_SA=$(terraform output -raw dataflow_service_account)

echo "✅ Observability project created: ${OBSERVABILITY_PROJECT_ID}"

# Step 2: Deploy Dataflow pipeline
echo "📊 Step 2: Deploying Dataflow pipeline..."
cd ../../dataflow

# Install dependencies
pip install apache-beam[gcp] google-cloud-bigquery

# Deploy pipeline
python log_processing_pipeline.py \
  --runner DataflowRunner \
  --project ${OBSERVABILITY_PROJECT_ID} \
  --region ${REGION} \
  --temp_location gs://${STAGING_BUCKET}/temp \
  --staging_location gs://${STAGING_BUCKET}/staging \
  --input_subscription ${PUBSUB_TOPIC/topics/subscriptions}-subscription \
  --output_dataset central_logs \
  --job_name central-log-processor-$(date +%Y%m%d-%H%M%S) \
  --streaming \
  --max_num_workers 20 \
  --service_account_email ${DATAFLOW_SA}

echo "✅ Dataflow pipeline deployed"

# Step 3: Deploy sample workload project
echo "🏗️  Step 3: Creating sample workload project..."
cd ../terraform/workload-project

terraform init
terraform plan \
  -var="billing_account_id=${BILLING_ACCOUNT_ID}" \
  -var="central_observability_project_id=${OBSERVABILITY_PROJECT_ID}" \
  -var="central_logs_topic_name=central-logs-topic"

terraform apply \
  -var="billing_account_id=${BILLING_ACCOUNT_ID}" \
  -var="central_observability_project_id=${OBSERVABILITY_PROJECT_ID}" \
  -var="central_logs_topic_name=central-logs-topic" \
  -auto-approve

export WORKLOAD_PROJECT_ID=$(terraform output -raw workload_project_id)

echo "✅ Workload project created: ${WORKLOAD_PROJECT_ID}"

# Step 4: Deploy sample applications
echo "🔧 Step 4: Deploying sample applications..."
cd ../../sample-apps

# Build and deploy log generator
docker build -t gcr.io/${WORKLOAD_PROJECT_ID}/sample-app:latest .
docker push gcr.io/${WORKLOAD_PROJECT_ID}/sample-app:latest

# Deploy to Cloud Run
gcloud run deploy sample-app \
  --image gcr.io/${WORKLOAD_PROJECT_ID}/sample-app:latest \
  --project ${WORKLOAD_PROJECT_ID} \
  --region ${REGION} \
  --allow-unauthenticated

echo "✅ Sample application deployed"

# Step 5: Verification
echo "🔍 Step 5: Verifying deployment..."

echo "Checking BigQuery tables..."
bq ls --project_id=${OBSERVABILITY_PROJECT_ID} central_logs

echo "Checking Pub/Sub subscriptions..."
gcloud pubsub subscriptions list --project=${OBSERVABILITY_PROJECT_ID}

echo "Checking Dataflow jobs..."
gcloud dataflow jobs list --project=${OBSERVABILITY_PROJECT_ID} --region=${REGION}

echo ""
echo "🎉 Deployment Complete!"
echo "======================="
echo "Observability Project: ${OBSERVABILITY_PROJECT_ID}"
echo "Workload Project: ${WORKLOAD_PROJECT_ID}"
echo "BigQuery Console: https://console.cloud.google.com/bigquery?project=${OBSERVABILITY_PROJECT_ID}"
echo "Dataflow Console: https://console.cloud.google.com/dataflow?project=${OBSERVABILITY_PROJECT_ID}"
echo "Logs Explorer: https://console.cloud.google.com/logs/query?project=${OBSERVABILITY_PROJECT_ID}"