# sample-apps/app.py
#!/usr/bin/env python3
"""
Sample Application for Log Generation
====================================

This application generates various types of logs to test the
central observability platform.
"""

import os
import json
import time
import random
import logging
from datetime import datetime
from google.cloud import pubsub_v1
from flask import Flask, request, jsonify

app = Flask(__name__)

# Configure logging
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s'
)
logger = logging.getLogger(__name__)

# Configuration
PROJECT_ID = os.environ.get('GOOGLE_CLOUD_PROJECT')
CENTRAL_TOPIC = os.environ.get('CENTRAL_LOGS_TOPIC', 'central-logs-topic')
CENTRAL_PROJECT = os.environ.get('CENTRAL_OBSERVABILITY_PROJECT')

class LogGenerator:
    """Generates various types of logs for testing"""
    
    def __init__(self):
        self.publisher = pubsub_v1.PublisherClient()
        if CENTRAL_PROJECT and CENTRAL_TOPIC:
            self.topic_path = self.publisher.topic_path(CENTRAL_PROJECT, CENTRAL_TOPIC)
        else:
            self.topic_path = None
    
    def generate_application_log(self, level='INFO', message=None):
        """Generate application log entry"""
        
        log_entry = {
            'timestamp': datetime.utcnow().isoformat() + 'Z',
            'severity': level,
            'textPayload': message or f"Sample {level} message from application",
            'resource': {
                'type': 'cloud_run_revision',
                'labels': {
                    'project_id': PROJECT_ID,
                    'service_name': 'sample-app',
                    'revision_name': 'sample-app-v1'
                }
            },
            'labels': {
                'component': 'sample-application',
                'version': '1.0.0'
            },
            'trace': f"projects/{PROJECT_ID}/traces/{self._generate_trace_id()}",
            'spanId': self._generate_span_id()
        }
        
        return log_entry
    
    def _generate_trace_id(self):
        """Generate random trace ID"""
        return ''.join(random.choices('0123456789abcdef', k=32))
    
    def _generate_span_id(self):
        """Generate random span ID"""
        return ''.join(random.choices('0123456789abcdef', k=16))
    
    def send_to_central_logs(self, log_entry):
        """Send log to central observability platform"""
        if self.topic_path:
            try:
                message_data = json.dumps(log_entry).encode('utf-8')
                future = self.publisher.publish(self.topic_path, message_data)
                future.result()  # Wait for publish to complete
                logger.info(f"Log sent to central platform: {log_entry['severity']}")
            except Exception as e:
                logger.error(f"Failed to send log to central platform: {e}")

log_generator = LogGenerator()

@app.route('/')
def home():
    """Health check endpoint"""
    log_generator.send_to_central_logs(
        log_generator.generate_application_log('INFO', 'Health check requested')
    )
    return jsonify({'status': 'healthy', 'timestamp': datetime.utcnow().isoformat()})

@app.route('/generate-logs')
def generate_logs():
    """Generate various types of logs"""
    count = int(request.args.get('count', 10))
    
    for i in range(count):
        # Generate different severity levels
        if i % 10 == 0:
            level = 'ERROR'
            message = f"Sample error message {i}"
        elif i % 5 == 0:
            level = 'WARNING'
            message = f"Sample warning message {i}"
        else:
            level = random.choice(['INFO', 'DEBUG'])
            message = f"Sample {level.lower()} message {i}"
        
        log_entry = log_generator.generate_application_log(level, message)
        log_generator.send_to_central_logs(log_entry)
        
        # Also log locally
        getattr(logger, level.lower())(message)
        
        time.sleep(0.1)  # Small delay between logs
    
    return jsonify({
        'message': f'Generated {count} log entries',
        'timestamp': datetime.utcnow().isoformat()
    })

@app.route('/simulate-traffic')
def simulate_traffic():
    """Simulate realistic application traffic"""
    duration = int(request.args.get('duration', 60))  # seconds
    rate = int(request.args.get('rate', 10))  # logs per second
    
    start_time = time.time()
    log_count = 0
    
    while time.time() - start_time < duration:
        # Simulate different scenarios
        scenario = random.choice(['normal', 'error_burst', 'high_volume'])
        
        if scenario == 'error_burst':
            # Generate burst of errors
            for _ in range(5):
                log_entry = log_generator.generate_application_log(
                    'ERROR', 
                    'Database connection timeout - retrying'
                )
                log_generator.send_to_central_logs(log_entry)
                log_count += 1
        
        elif scenario == 'high_volume':
            # Generate high volume of info logs
            for _ in range(rate * 2):
                log_entry = log_generator.generate_application_log(
                    'INFO', 
                    f'Processing request {log_count}'
                )
                log_generator.send_to_central_logs(log_entry)
                log_count += 1
        
        else:
            # Normal operations
            log_entry = log_generator.generate_application_log(
                'INFO', 
                f'Normal operation - request processed'
            )
            log_generator.send_to_central_logs(log_entry)
            log_count += 1
        
        time.sleep(1.0 / rate)
    
    return jsonify({
        'message': f'Simulated traffic for {duration} seconds',
        'logs_generated': log_count,
        'timestamp': datetime.utcnow().isoformat()
    })

if __name__ == '__main__':
    port = int(os.environ.get('PORT', 8080))
    app.run(host='0.0.0.0', port=port, debug=True)