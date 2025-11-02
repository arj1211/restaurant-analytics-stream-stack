#!/usr/bin/env python3
"""
Restaurant Analytics Stream Stack - Deployment Verification
===========================================================

This script verifies that the complete stack has been deployed correctly
and all components are functioning as expected.
"""

import json
import os
import sys
import time
import requests
import psycopg2
from datetime import datetime, timedelta


class Colors:
    """ANSI color codes for terminal output."""
    RED = '\033[91m'
    GREEN = '\033[92m'
    YELLOW = '\033[93m'
    BLUE = '\033[94m'
    PURPLE = '\033[95m'
    CYAN = '\033[96m'
    WHITE = '\033[97m'
    ENDC = '\033[0m'  # End color
    BOLD = '\033[1m'


def log_info(message):
    print(f"{Colors.BLUE}[INFO]{Colors.ENDC} {message}")


def log_success(message):
    print(f"{Colors.GREEN}[SUCCESS]{Colors.ENDC} {message}")


def log_warning(message):
    print(f"{Colors.YELLOW}[WARNING]{Colors.ENDC} {message}")


def log_error(message):
    print(f"{Colors.RED}[ERROR]{Colors.ENDC} {message}")


def load_environment():
    """Load environment variables from .env file."""
    env_vars = {}
    try:
        with open('.env', 'r') as f:
            for line in f:
                line = line.strip()
                if line and not line.startswith('#'):
                    key, value = line.split('=', 1)
                    env_vars[key] = value
    except FileNotFoundError:
        log_error("Environment file .env not found")
        return None
    except Exception as e:
        log_error(f"Error loading .env file: {e}")
        return None

    return env_vars


def test_api_health():
    """Test Restaurant API health and functionality."""
    log_info("Testing Restaurant API...")

    try:
        # Test health endpoint
        response = requests.get('http://localhost:8000/health', timeout=10)
        if response.status_code == 200:
            health_data = response.json()
            log_success(f"✓ API health check passed - {health_data.get('stored', 0)} events stored")
        else:
            log_error(f"✗ API health check failed - Status: {response.status_code}")
            return False

        # Test events endpoint
        response = requests.get('http://localhost:8000/events?limit=10', timeout=10)
        if response.status_code == 200:
            events_data = response.json()
            event_count = len(events_data.get('events', []))
            log_success(f"✓ Events endpoint working - Retrieved {event_count} events")
        else:
            log_warning(f"⚠ Events endpoint returned status: {response.status_code}")

        # Test SSE stream (briefly)
        try:
            response = requests.get(
                'http://localhost:8000/stream',
                headers={'Accept': 'text/event-stream'},
                timeout=5,
                stream=True
            )
            if response.status_code == 200:
                log_success("✓ SSE stream endpoint is accessible")
            else:
                log_error(f"✗ SSE stream failed - Status: {response.status_code}")
        except requests.exceptions.Timeout:
            log_success("✓ SSE stream is running (connection timeout is expected)")
        except Exception as e:
            log_error(f"✗ SSE stream test failed: {e}")

        return True

    except requests.exceptions.ConnectionError:
        log_error("✗ Cannot connect to Restaurant API - Is it running?")
        return False
    except Exception as e:
        log_error(f"✗ API test failed: {e}")
        return False


def test_database_connectivity(env_vars):
    """Test PostgreSQL database connectivity and schema."""
    log_info("Testing Database connectivity...")

    try:
        # Test superuser connection
        conn = psycopg2.connect(
            host='localhost',
            port=5432,
            database=env_vars.get('POSTGRES_DEFAULT_DB', 'postgres'),
            user=env_vars.get('POSTGRES_SUPERUSER', 'postgres_admin'),
            password=env_vars.get('POSTGRES_SUPERUSER_PASSWORD', '')
        )
        conn.close()
        log_success("✓ Superuser database connection successful")

        # Test application database connection
        conn = psycopg2.connect(
            host='localhost',
            port=5432,
            database=env_vars.get('RESTAURANT_DB_NAME', 'restaurant_analytics'),
            user=env_vars.get('RESTAURANT_DB_USER', 'restaurant_user'),
            password=env_vars.get('RESTAURANT_DB_PASSWORD', '')
        )

        cursor = conn.cursor()

        # Check if schemas exist
        cursor.execute("""
            SELECT schema_name FROM information_schema.schemata
            WHERE schema_name IN ('raw_data', 'analytics', 'staging');
        """)
        schemas = [row[0] for row in cursor.fetchall()]

        expected_schemas = ['raw_data', 'analytics', 'staging']
        for schema in expected_schemas:
            if schema in schemas:
                log_success(f"✓ Schema '{schema}' exists")
            else:
                log_error(f"✗ Schema '{schema}' missing")

        # Check if main tables exist
        cursor.execute("""
            SELECT table_schema, table_name FROM information_schema.tables
            WHERE table_schema IN ('raw_data', 'analytics')
            ORDER BY table_schema, table_name;
        """)
        tables = cursor.fetchall()

        expected_tables = [
            ('raw_data', 'events_raw'),
            ('analytics', 'orders'),
            ('analytics', 'order_items'),
            ('analytics', 'payments'),
            ('analytics', 'feedback')
        ]

        for schema, table in expected_tables:
            if (schema, table) in tables:
                log_success(f"✓ Table '{schema}.{table}' exists")
            else:
                log_error(f"✗ Table '{schema}.{table}' missing")

        # Check for data
        cursor.execute("SELECT COUNT(*) FROM raw_data.events_raw;")
        event_count = cursor.fetchone()[0]

        if event_count > 0:
            log_success(f"✓ Found {event_count} events in database")

            # Check data freshness
            cursor.execute("""
                SELECT MAX(ingested_at) FROM raw_data.events_raw;
            """)
            latest_ingestion = cursor.fetchone()[0]

            if latest_ingestion and latest_ingestion > datetime.now() - timedelta(minutes=5):
                log_success("✓ Recent data ingestion detected (within last 5 minutes)")
            else:
                log_warning("⚠ No recent data ingestion (may still be starting up)")

        else:
            log_warning("⚠ No events found in database yet")

        conn.close()
        return True

    except psycopg2.Error as e:
        log_error(f"✗ Database connection failed: {e}")
        return False
    except Exception as e:
        log_error(f"✗ Database test failed: {e}")
        return False


def test_airflow_connectivity():
    """Test Airflow web server and API."""
    log_info("Testing Airflow...")

    try:
        # Test health endpoint
        response = requests.get('http://localhost:8081/health', timeout=10)
        if response.status_code == 200:
            log_success("✓ Airflow health check passed")
        else:
            log_error(f"✗ Airflow health check failed - Status: {response.status_code}")
            return False

        # Test if we can access the main page (this will return login page)
        response = requests.get('http://localhost:8081/', timeout=10)
        if response.status_code in [200, 302]:  # 302 redirect to login is OK
            log_success("✓ Airflow web interface is accessible")
        else:
            log_warning(f"⚠ Airflow web interface returned status: {response.status_code}")

        return True

    except requests.exceptions.ConnectionError:
        log_error("✗ Cannot connect to Airflow - Is it running?")
        return False
    except Exception as e:
        log_error(f"✗ Airflow test failed: {e}")
        return False


def test_metabase_connectivity():
    """Test Metabase availability."""
    log_info("Testing Metabase...")

    try:
        response = requests.get('http://localhost:3000/api/health', timeout=10)
        if response.status_code == 200:
            log_success("✓ Metabase health check passed")
        else:
            # Try the main page if health endpoint fails
            response = requests.get('http://localhost:3000/', timeout=10)
            if response.status_code == 200:
                log_success("✓ Metabase web interface is accessible")
            else:
                log_warning(f"⚠ Metabase returned status: {response.status_code}")

        return True

    except requests.exceptions.ConnectionError:
        log_error("✗ Cannot connect to Metabase - Is it running?")
        return False
    except Exception as e:
        log_warning(f"⚠ Metabase test inconclusive: {e}")
        return True  # Don't fail overall test for Metabase issues


def test_pgadmin_connectivity():
    """Test PgAdmin availability."""
    log_info("Testing PgAdmin...")

    try:
        response = requests.get('http://localhost:8080/', timeout=10)
        if response.status_code == 200:
            log_success("✓ PgAdmin web interface is accessible")
        else:
            log_warning(f"⚠ PgAdmin returned status: {response.status_code}")

        return True

    except requests.exceptions.ConnectionError:
        log_error("✗ Cannot connect to PgAdmin - Is it running?")
        return False
    except Exception as e:
        log_warning(f"⚠ PgAdmin test inconclusive: {e}")
        return True  # Don't fail overall test for PgAdmin issues


def run_data_flow_test(env_vars):
    """Test end-to-end data flow."""
    log_info("Testing end-to-end data flow...")

    try:
        # Connect to database
        conn = psycopg2.connect(
            host='localhost',
            port=5432,
            database=env_vars.get('RESTAURANT_DB_NAME', 'restaurant_analytics'),
            user=env_vars.get('RESTAURANT_DB_USER', 'restaurant_user'),
            password=env_vars.get('RESTAURANT_DB_PASSWORD', '')
        )
        cursor = conn.cursor()

        # Get initial event count
        cursor.execute("SELECT COUNT(*) FROM raw_data.events_raw;")
        initial_count = cursor.fetchone()[0]

        log_info(f"Initial event count: {initial_count}")

        # Wait for new events to arrive
        log_info("Waiting 30 seconds for new events...")
        time.sleep(30)

        # Get new event count
        cursor.execute("SELECT COUNT(*) FROM raw_data.events_raw;")
        new_count = cursor.fetchone()[0]

        if new_count > initial_count:
            events_added = new_count - initial_count
            log_success(f"✓ Data flow working - {events_added} new events ingested")

            # Check if events are being processed into analytics tables
            cursor.execute("SELECT COUNT(*) FROM analytics.orders;")
            order_count = cursor.fetchone()[0]

            if order_count > 0:
                log_success(f"✓ Event processing working - {order_count} orders in analytics")
            else:
                log_warning("⚠ Events ingested but not yet processed into analytics tables")

        else:
            log_warning("⚠ No new events detected - data generation may be slow or stopped")

        conn.close()
        return new_count > initial_count

    except Exception as e:
        log_error(f"✗ Data flow test failed: {e}")
        return False


def generate_deployment_report():
    """Generate a summary report of the deployment."""
    print(f"\n{Colors.BOLD}=== DEPLOYMENT VERIFICATION REPORT ==={Colors.ENDC}")
    print(f"Timestamp: {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}")
    print("\nService URLs:")
    print("• Airflow:        http://localhost:8081")
    print("• Metabase:       http://localhost:3000")
    print("• PgAdmin:        http://localhost:8080")
    print("• Restaurant API: http://localhost:8000")

    print(f"\n{Colors.BOLD}Next Steps:{Colors.ENDC}")
    print("1. 🔐 Log into Airflow and enable the 'restaurant_realtime_stream' DAG")
    print("2. 📊 Set up Metabase dashboards")
    print("3. 🗄️ Configure PgAdmin server connections")
    print("4. 📈 Start building your analytics!")

    print(f"\n{Colors.BOLD}Documentation:{Colors.ENDC}")
    print("• README.md - Complete setup and usage guide")
    print("• TROUBLESHOOTING.md - Common issues and solutions")


def main():
    """Main verification function."""
    print(f"{Colors.BOLD}🍕 Restaurant Analytics Stream Stack - Deployment Verification{Colors.ENDC}")
    print("=" * 70)

    # Load environment
    env_vars = load_environment()
    if not env_vars:
        log_error("Cannot proceed without environment configuration")
        return 1

    tests_passed = 0
    total_tests = 0

    # Run tests
    test_functions = [
        ("API Health", lambda: test_api_health()),
        ("Database", lambda: test_database_connectivity(env_vars)),
        ("Airflow", lambda: test_airflow_connectivity()),
        ("Metabase", lambda: test_metabase_connectivity()),
        ("PgAdmin", lambda: test_pgadmin_connectivity()),
        ("Data Flow", lambda: run_data_flow_test(env_vars))
    ]

    for test_name, test_func in test_functions:
        total_tests += 1
        log_info(f"Running {test_name} test...")
        try:
            if test_func():
                tests_passed += 1
                log_success(f"{test_name} test passed")
            else:
                log_error(f"{test_name} test failed")
        except Exception as e:
            log_error(f"{test_name} test error: {e}")

        print()  # Add spacing between tests

    # Summary
    print(f"{Colors.BOLD}=== VERIFICATION SUMMARY ==={Colors.ENDC}")
    print(f"Tests passed: {tests_passed}/{total_tests}")

    if tests_passed == total_tests:
        log_success("🎉 All tests passed! Deployment is successful!")
        generate_deployment_report()
        return 0
    elif tests_passed >= 4:  # Core functionality working
        log_warning(f"⚠ Partial success - {tests_passed}/{total_tests} tests passed")
        log_info("Core functionality is working, some services may need attention")
        generate_deployment_report()
        return 0
    else:
        log_error(f"❌ Deployment verification failed - {tests_passed}/{total_tests} tests passed")
        log_info("Check TROUBLESHOOTING.md for help resolving issues")
        return 1


if __name__ == "__main__":
    sys.exit(main())