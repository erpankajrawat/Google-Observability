# dataflow/log_processing_pipeline.py
#!/usr/bin/env python3
"""
Central Observability Platform - Log Processing Pipeline
========================================================

This Dataflow pipeline processes logs from multiple workload projects
and stores them in BigQuery for analysis.
"""

import json
import logging
import argparse
from datetime import datetime
from typing import Dict, Any, Iterator

import apache_beam as beam
from apache_beam.options.pipeline_options import PipelineOptions, StandardOptions
from apache_beam.io import ReadFromPubSub, WriteToBigQuery
from apache_beam.io.gcp.bigquery import BigQueryDisposition
from apache_beam.transforms import window
from apache_beam.transforms.window import FixedWindows

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

class ParseLogEntry(beam.DoFn):
    """Parse and validate log entries from Pub/Sub"""
    
    def __init__(self):
        self.parse_errors = beam.metrics.Metrics.counter('pipeline', 'parse_errors')
        self.valid_logs = beam.metrics.Metrics.counter('pipeline', 'valid_logs')
    
    def process(self, element) -> Iterator[Dict[str, Any]]:
        try:
            # Parse JSON from Pub/Sub
            if isinstance(element, bytes):
                element = element.decode('utf-8')
            
            log_data = json.loads(element) if isinstance(element, str) else element
            
            # Extract standard fields
            processed_log = {
                'timestamp': log_data.get('timestamp'),
                'severity': log_data.get('severity', 'INFO'),
                'message': log_data.get('textPayload', log_data.get('message', '')),
                'resource_type': log_data.get('resource', {}).get('type', 'unknown'),
                'project_id': log_data.get('resource', {}).get('labels', {}).get('project_id', 'unknown'),
                'trace_id': log_data.get('trace'),
                'span_id': log_data.get('spanId'),
                'labels': log_data.get('labels', {}),
                'resource_name': log_data.get('resource', {}).get('labels', {}).get('container_name', ''),
                'source_location': log_data.get('sourceLocation', {})
            }
            
            self.valid_logs.inc()
            yield processed_log
            
        except Exception as e:
            logger.error(f"Failed to parse log entry: {e}")
            self.parse_errors.inc()

class EnrichLogs(beam.DoFn):
    """Enrich logs with additional metadata"""
    
    def process(self, element) -> Iterator[Dict[str, Any]]:
        # Add processing metadata
        element['ingestion_time'] = datetime.utcnow().isoformat()
        element['pipeline_version'] = '1.0.0'
        
        # Truncate long messages
        if len(element.get('message', '')) > 1000:
            element['message'] = element['message'][:1000] + '...[TRUNCATED]'
        
        yield element

class DetermineShardTable(beam.DoFn):
    """Determine which BigQuery shard table to use"""
    
    def process(self, element) -> Iterator[tuple]:
        # Simple hash-based sharding
        project_hash = hash(element.get('project_id', ''))
        shard_num = (project_hash % 4) + 1
        table_name = f"real_time_logs_shard_{shard_num}"
        
        yield (table_name, element)

def create_bigquery_schema():
    """Define BigQuery table schema"""
    from google.cloud import bigquery
    
    return [
        bigquery.SchemaField("timestamp", "TIMESTAMP"),
        bigquery.SchemaField("severity", "STRING"),
        bigquery.SchemaField("message", "STRING"),
        bigquery.SchemaField("resource_type", "STRING"),
        bigquery.SchemaField("project_id", "STRING"),
        bigquery.SchemaField("trace_id", "STRING"),
        bigquery.SchemaField("span_id", "STRING"),
        bigquery.SchemaField("labels", "JSON"),
        bigquery.SchemaField("resource_name", "STRING"),
        bigquery.SchemaField("source_location", "JSON"),
        bigquery.SchemaField("ingestion_time", "TIMESTAMP"),
        bigquery.SchemaField("pipeline_version", "STRING"),
    ]

def run_pipeline(argv=None):
    """Main pipeline execution"""
    
    parser = argparse.ArgumentParser()
    parser.add_argument('--input_subscription', required=True)
    parser.add_argument('--output_dataset', required=True)
    parser.add_argument('--project_id', required=True)
    
    known_args, pipeline_args = parser.parse_known_args(argv)
    
    pipeline_options = PipelineOptions(pipeline_args)
    pipeline_options.view_as(StandardOptions).streaming = True
    
    with beam.Pipeline(options=pipeline_options) as pipeline:
        
        # Read from Pub/Sub
        raw_logs = (
            pipeline
            | 'Read from Pub/Sub' >> ReadFromPubSub(
                subscription=known_args.input_subscription
            )
        )
        
        # Process logs
        processed_logs = (
            raw_logs
            | 'Parse Log Entries' >> beam.ParDo(ParseLogEntry())
            | 'Enrich Logs' >> beam.ParDo(EnrichLogs())
            | 'Window into 1-minute intervals' >> beam.WindowInto(FixedWindows(60))
            | 'Determine Shard Table' >> beam.ParDo(DetermineShardTable())
        )
        
        # Write to BigQuery shards
        bq_schema = create_bigquery_schema()
        
        for shard_num in range(1, 5):
            table_name = f"real_time_logs_shard_{shard_num}"
            (
                processed_logs
                | f'Filter Shard {shard_num}' >> beam.Filter(
                    lambda x, shard=shard_num: x[0] == f"real_time_logs_shard_{shard}"
                )
                | f'Extract Rows Shard {shard_num}' >> beam.Map(lambda x: x[1])
                | f'Write to BigQuery Shard {shard_num}' >> WriteToBigQuery(
                    table=f"{known_args.project_id}:{known_args.output_dataset}.{table_name}",
                    schema=bq_schema,
                    create_disposition=BigQueryDisposition.CREATE_NEVER,
                    write_disposition=BigQueryDisposition.WRITE_APPEND,
                    additional_bq_parameters={
                        'timePartitioning': {
                            'type': 'DAY',
                            'field': 'timestamp'
                        },
                        'clustering': {
                            'fields': ['severity', 'resource_type', 'project_id']
                        }
                    }
                )
            )

if __name__ == '__main__':
    logging.getLogger().setLevel(logging.INFO)
    run_pipeline()