#!/usr/bin/env python3
"""
Config to Environment Variables Converter
Reads config.json and generates environment variables for Docker Compose.
"""

import json
import sys
from pathlib import Path

def load_config(config_path: str):
    """Load configuration from JSON file."""
    try:
        with open(config_path, 'r') as f:
            return json.load(f)
    except Exception as e:
        print(f"Error loading config: {e}", file=sys.stderr)
        sys.exit(1)

def config_to_env_vars(config: dict):
    """Convert config dictionary to environment variables."""
    env_vars = {}
    
    # System configuration
    env_vars['HOST_PROJECT_ROOT'] = str(Path.cwd().absolute())
    
    # Database configuration
    if 'database' in config:
        db = config['database']
        env_vars['DATABASE_URL'] = f"postgresql://{db['user']}:{db['password']}@{db['host']}:{db['port']}/{db['database']}"
        env_vars['DATABASE_HOST'] = db['host']
        env_vars['DATABASE_PORT'] = str(db['port'])
        env_vars['DATABASE_NAME'] = db['database']
        env_vars['DATABASE_USER'] = db['user']
        env_vars['DATABASE_PASSWORD'] = db['password']
    
    # MQTT configuration
    if 'mqtt' in config:
        mqtt = config['mqtt']
        env_vars['MQTT_HOST'] = mqtt['host']
        env_vars['MQTT_PORT'] = str(mqtt['port'])
        env_vars['MQTT_BROKER'] = mqtt.get('broker') or mqtt['host']
        env_vars['MQTT_USERNAME'] = mqtt.get('username', '')
        env_vars['MQTT_PASSWORD'] = mqtt.get('password', '')

    # SQL browser (pgweb) configuration
    if 'sql_browser' in config:
        sql_browser = config['sql_browser']
        env_vars['PGWEB_AUTH_USER'] = sql_browser.get('auth_user', '')
        env_vars['PGWEB_AUTH_PASS'] = sql_browser.get('auth_pass', '')
    
    # OTA configuration
    if 'ota' in config:
        ota = config['ota']
        env_vars['OTA_GITHUB_REPO'] = ota.get('github_repo', '')
        env_vars['OTA_HTTP_SERVER_PORT'] = str(ota.get('http_server_port', 8080))
        env_vars['OTA_API_SERVER_PORT'] = str(ota.get('api_server_port', 8000))
        env_vars['OTA_LOG_LEVEL'] = ota.get('log_level', 'INFO')
        env_vars['OTA_UPDATE_CHECK_INTERVAL'] = str(ota.get('update_check_interval', 3600))
        env_vars['OTA_MAX_CONCURRENT_UPDATES'] = str(ota.get('max_concurrent_updates', 5))
        env_vars['OTA_RETRY_ATTEMPTS'] = str(ota.get('retry_attempts', 3))
        env_vars['OTA_ROLLBACK_TIMEOUT'] = str(ota.get('rollback_timeout', 300))
        env_vars['OTA_UPDATE_TIMEOUT'] = str(ota.get('update_timeout', 600))
        env_vars['FIRMWARE_STORAGE_PATH'] = ota.get('firmware_storage_path', '/app/firmware')
        env_vars['OTA_GITHUB_TOKEN'] = ota.get('github_token', '')
    
    # HTTP uploader configuration
    if 'http_uploader' in config:
        http = config['http_uploader']
        env_vars['HTTP_WORKERS'] = str(http.get('workers', 3))
        env_vars['HTTP_BATCH_SIZE'] = str(http.get('batch_size', 500))
        env_vars['HTTP_RETRY_DELAY'] = str(http.get('retry_delay', 60))
        env_vars['HTTP_MAX_RETRIES'] = str(http.get('max_retries', 5))
    else:
        # Fallback to old config structure for backward compatibility
        env_vars['HTTP_WORKERS'] = str(config.get('http_workers', 3))
        env_vars['HTTP_BATCH_SIZE'] = str(config.get('endpoint_batch_size', 500))
        env_vars['HTTP_RETRY_DELAY'] = str(config.get('http_retry_delay', 60))
        env_vars['HTTP_MAX_RETRIES'] = str(config.get('http_max_retries', 5))
    
    # Service intervals configuration
    if 'service_intervals' in config:
        intervals = config['service_intervals']
        env_vars['CONFIG_CHECK_INTERVAL'] = str(intervals.get('config_check_interval', 10))
        env_vars['DEVICE_MONITOR_SYNC_INTERVAL'] = str(intervals.get('device_monitor_sync_interval', 5))
    
    # NTP configuration
    if 'ntp_config' in config:
        ntp = config['ntp_config']
        env_vars['NTP_SERVERS'] = ntp['servers']
    
    # Logging configuration
    if 'logging' in config:
        logging = config['logging']
        env_vars['LOG_DRIVER'] = logging.get('driver', 'json-file')
        env_vars['LOG_MAX_SIZE'] = logging.get('max_size', '10m')
        env_vars['LOG_MAX_FILES'] = str(logging.get('max_files', 3))
    
    # WiFi manager configuration
    env_vars['WIFI_SCAN_INTERVAL'] = str(config.get('wifi_scan_interval', 30))
    env_vars['WIFI_CONNECTION_TIMEOUT'] = str(config.get('wifi_connection_timeout', 20))
    
    # Device configuration
    if config.get('device_serial'):
        env_vars['DEVICE_SERIAL'] = config['device_serial']
    if config.get('device_name'):
        env_vars['DEVICE_NAME'] = config['device_name']
    if config.get('device_mac'):
        env_vars['DEVICE_MAC'] = config['device_mac']
    
    # Default Timer Group
    env_vars['DEFAULT_TIMER_GROUP_ID'] = str(config.get('default_timer_group_id', 1))

    # Default Mesh
    env_vars['DEFAULT_MESH_ID'] = str(config.get('default_mesh_id', '4F:53:41:33:BE:EF'))

    # Status event configuration
    env_vars['STATUS_EVENT_FREQUENCY'] = str(config.get('status_event_frequency', 300))
    env_vars['STATUS_EVENT_ENABLED'] = str(config.get('status_event_enabled', True)).lower()

    # Host project mount (default to repository root for cross-platform support)
    env_vars['PROJECT_ROOT'] = "."

    # RPI host/IP for OTA download URLs (fallback to localhost)
    env_vars['RPI_HOST'] = (
        config.get('rpi_host')
        or config.get('device_ip')
        or config.get('device_name')
        or 'localhost'
    )
    
    return env_vars

def generate_docker_env_file(config_path: str, output_path: str = '.env'):
    """Generate .env file for Docker Compose."""
    config = load_config(config_path)
    env_vars = config_to_env_vars(config)
    
    with open(output_path, 'w') as f:
        f.write("# Auto-generated environment variables from config.json\n")
        f.write("# Do not edit this file directly - edit config.json instead\n\n")
        
        for key, value in sorted(env_vars.items()):
            f.write(f"{key}={value}\n")
    
    print(f"Generated {output_path} with {len(env_vars)} environment variables")

def print_env_vars(config_path: str):
    """Print environment variables to stdout."""
    config = load_config(config_path)
    env_vars = config_to_env_vars(config)
    
    for key, value in sorted(env_vars.items()):
        print(f"{key}={value}")

def main():
    import argparse
    import os
    
    # Default to fixed system location
    default_config = '/opt/mishka/config.json'
    # Fallback to relative path if fixed location doesn't exist
    if not os.path.exists(default_config):
        default_config = 'config.json'
    
    parser = argparse.ArgumentParser(description='Convert config.json to environment variables')
    parser.add_argument('config', nargs='?', default=default_config, 
                        help=f'Path to config.json file (default: {default_config})')
    parser.add_argument('--output', '-o', help='Output .env file path (default: .env)')
    parser.add_argument('--print', '-p', action='store_true', help='Print to stdout instead of file')
    
    args = parser.parse_args()
    
    if args.print:
        print_env_vars(args.config)
    else:
        output_path = args.output or '.env'
        generate_docker_env_file(args.config, output_path)

if __name__ == '__main__':
    main()
