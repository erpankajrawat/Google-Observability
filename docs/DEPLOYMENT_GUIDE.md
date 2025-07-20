# docs/DEPLOYMENT_GUIDE.md

# Central Observability Platform - Deployment Guide

## Prerequisites

1. **GCP Account** with appropriate permissions
2. **Billing Account** configured
3. **Terraform** v1.5+ installed
4. **gcloud CLI** installed and authenticated
5. **Docker** for building sample applications

## Quick Start Deployment

### 1. Clone and Setup
```bash
git clone <repository-url>
cd central-observability-platform
```

### 2. Configure Environment
```bash
export BILLING_ACCOUNT_ID="your-billing-account-id"
export ORG_ID="your-organization-id"
```

### 3. Deploy Platform
```bash
chmod +x scripts/deploy-observability-platform.sh
./scripts/deploy-observability-platform.sh
```

### 4. Verify Deployment
```bash
# Check BigQuery tables
bq ls --project_id=<observability-project-id> central_logs

# Check Dataflow jobs
gcloud dataflow jobs list --project=<observability-project-id>

# Generate test logs
curl https://<sample-app-url>/generate-logs?count=100
```

## Manual Deployment Steps

### Step 1: Deploy Observability Project
```bash
cd terraform/observability-project
terraform init
terraform apply -var="billing_account_id=<your-billing-account>"
```

### Step 2: Deploy Dataflow Pipeline
```bash
cd ../../dataflow
python log_processing_pipeline.py \
  --runner DataflowRunner \
  --project <observability-project-id> \
  --region australia-southeast2 \
  --input_subscription <subscription-path> \
  --output_dataset central_logs \
  --streaming
```

### Step 3: Deploy Workload Project
```bash
cd ../terraform/workload-project
terraform apply \
  -var="central_observability_project_id=<obs-project-id>" \
  -var="billing_account_id=<billing-account>"
```

### Step 4: Deploy Sample Applications
```bash
cd ../../sample-apps
docker build -t gcr.io/<project-id>/sample-app .
docker push gcr.io/<project-id>/sample-app
gcloud run deploy sample-app --image gcr.io/<project-id>/sample-app
```

## Architecture Overview

The platform consists of:

1. **Central Observability Project**
   - BigQuery dataset with 4 sharded tables
   - Pub/Sub topic for log ingestion
   - Dataflow pipeline for processing
   - Cloud Storage for staging

2. **Workload Projects**
   - Sample applications generating logs
   - Log sinks forwarding to central platform
   - GKE cluster for containerized apps

3. **Processing Pipeline**
   - Real-time log processing
   - Intelligent sharding
   - Data validation and enrichment

## Cost Estimation

For 1TB daily log volume:
- BigQuery: ~$200/month
- Pub/Sub: ~$40/month  
- Dataflow: ~$300/month
- Cloud Storage: ~$20/month
- **Total: ~$560/month**

## Monitoring and Alerting

Access monitoring dashboards:
- BigQuery: https://console.cloud.google.com/bigquery
- Dataflow: https://console.cloud.google.com/dataflow
- Logs Explorer: https://console.cloud.google.com/logs

## Troubleshooting

### Common Issues

1. **Permission Denied**: Ensure service accounts have proper IAM roles
2. **Dataflow Job Fails**: Check staging bucket permissions
3. **No Logs in BigQuery**: Verify log sink configuration
4. **High Costs**: Review BigQuery partition expiration settings

### Debug Commands
```bash
# Check Dataflow job logs
gcloud dataflow jobs show <job-id> --region=australia-southeast2

# Test Pub/Sub publishing
gcloud pubsub topics publish <topic-name> --message="test log"

# Query BigQuery tables
bq query "SELECT COUNT(*) FROM central_logs.real_time_logs_shard_1"
```

## Security Considerations

1. **IAM**: Principle of least privilege
2. **Encryption**: KMS keys for data at rest
3. **Network**: VPC controls and private endpoints
4. **Audit**: Cloud Audit Logs enabled

## Scaling Considerations

- **Dataflow**: Auto-scales from 1-100 workers
- **BigQuery**: Partitioned tables for performance
- **Pub/Sub**: Regional message storage
- **Sharding**: 4 shards handle up to 5TB daily

## Next Steps

1. Configure custom dashboards in Cloud Monitoring
2. Set up alerting policies for operational metrics
3. Implement log retention policies per compliance requirements
4. Add ML-based anomaly detection (future enhancement)