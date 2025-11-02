#!/bin/bash

# =============================================================================
# Restaurant Analytics Stream Stack - Setup Script
# =============================================================================
# This script automates the initial setup and deployment of the complete stack

set -e  # Exit on any error

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$SCRIPT_DIR/.env"
EXAMPLE_ENV_FILE="$SCRIPT_DIR/.env.example"

# =============================================================================
# Helper Functions
# =============================================================================

log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

check_requirements() {
    log_info "Checking system requirements..."

    # Check Docker
    if ! command -v docker &> /dev/null; then
        log_error "Docker is not installed. Please install Docker and try again."
        exit 1
    fi

    # Check Docker Compose
    if ! command -v docker-compose &> /dev/null && ! docker compose version &> /dev/null; then
        log_error "Docker Compose is not installed. Please install Docker Compose and try again."
        exit 1
    fi

    # Check Python for data directory initialization
    if ! command -v python3 &> /dev/null && ! command -v python &> /dev/null; then
        log_error "Python is not installed. Please install Python and try again."
        exit 1
    fi

    # Check available memory (at least 4GB recommended)
    if command -v free &> /dev/null; then
        MEMORY_GB=$(free -g | awk 'NR==2{printf "%.1f", $2/1}')
        if (( $(echo "$MEMORY_GB < 4" | bc -l 2>/dev/null || echo "0") )); then
            log_warning "Less than 4GB RAM detected. System may run slowly."
        fi
    fi

    log_success "System requirements check passed"
}

setup_environment() {
    log_info "Setting up environment configuration..."

    if [[ -f "$ENV_FILE" ]]; then
        log_warning "Environment file already exists at $ENV_FILE"
        read -p "Do you want to overwrite it? (y/N): " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            log_info "Using existing environment file"
            return
        fi
    fi

    if [[ ! -f "$EXAMPLE_ENV_FILE" ]]; then
        log_error "Example environment file not found at $EXAMPLE_ENV_FILE"
        exit 1
    fi

    # Copy example to actual env file
    cp "$EXAMPLE_ENV_FILE" "$ENV_FILE"

    # Generate secure passwords
    log_info "Generating secure passwords..."

    # Function to generate random password
    generate_password() {
        openssl rand -base64 32 | tr -d "=+/" | cut -c1-16
    }

    # Replace password placeholders
    sed -i.bak "s/admin_secure_password_123/$(generate_password)/g" "$ENV_FILE"
    sed -i.bak "s/restaurant_secure_pass_456/$(generate_password)/g" "$ENV_FILE"
    sed -i.bak "s/airflow_secure_pass_789/$(generate_password)/g" "$ENV_FILE"
    sed -i.bak "s/analytics_readonly_pass_012/$(generate_password)/g" "$ENV_FILE"
    sed -i.bak "s/airflow_web_admin_345/$(generate_password)/g" "$ENV_FILE"
    sed -i.bak "s/pgadmin_secure_678/$(generate_password)/g" "$ENV_FILE"
    sed -i.bak "s/metabase_admin_901/$(generate_password)/g" "$ENV_FILE"

    # Clean up backup file
    rm -f "$ENV_FILE.bak"

    log_success "Environment configuration created with secure passwords"
    log_info "You can customize settings in $ENV_FILE"
}

initialize_data_directories() {
    log_info "Initializing data directories..."

    # Use Python to initialize directories
    if command -v python3 &> /dev/null; then
        python3 "$SCRIPT_DIR/init_data_dir.py"
    else
        python "$SCRIPT_DIR/init_data_dir.py"
    fi

    log_success "Data directories initialized"
}

check_port_availability() {
    log_info "Checking port availability..."

    # Default ports to check
    PORTS=(5432 8000 8080 8081 3000)

    for port in "${PORTS[@]}"; do
        if lsof -Pi :$port -sTCP:LISTEN -t >/dev/null 2>&1; then
            log_warning "Port $port is already in use. You may need to stop the conflicting service or change the port in .env"
        fi
    done
}

deploy_stack() {
    log_info "Deploying the restaurant analytics stack..."

    # Pull latest images
    log_info "Pulling Docker images..."
    docker-compose pull

    # Build custom images
    log_info "Building custom images..."
    docker-compose build

    # Start the stack
    log_info "Starting services..."
    docker-compose up -d

    # Wait for services to be healthy
    log_info "Waiting for services to be ready..."

    # Wait for PostgreSQL
    log_info "Waiting for PostgreSQL to be ready..."
    timeout 120 bash -c 'until docker-compose exec -T postgres pg_isready -U postgres_admin; do sleep 2; done'

    # Wait for Airflow webserver
    log_info "Waiting for Airflow to be ready..."
    timeout 180 bash -c 'until curl -f http://localhost:8081/health >/dev/null 2>&1; do sleep 5; done'

    log_success "All services are running!"
}

show_service_status() {
    log_info "Service Status:"
    echo "==================="

    # Check Docker Compose services
    docker-compose ps

    echo ""
    log_info "Service URLs:"
    echo "==================="
    echo "🎯 Airflow:        http://localhost:8081"
    echo "📊 Metabase:       http://localhost:3000"
    echo "🗄️  PgAdmin:        http://localhost:8080"
    echo "🚀 Restaurant API: http://localhost:8000"
    echo ""

    log_info "Default Credentials:"
    echo "===================="
    echo "Airflow:  Check .env file for AIRFLOW_ADMIN_USER and AIRFLOW_ADMIN_PASSWORD"
    echo "PgAdmin:  Check .env file for PGADMIN_DEFAULT_EMAIL and PGADMIN_DEFAULT_PASSWORD"
    echo "Metabase: Setup required on first access"
}

run_health_checks() {
    log_info "Running health checks..."

    # Check API health
    if curl -f http://localhost:8000/health >/dev/null 2>&1; then
        log_success "✓ Restaurant API is healthy"
    else
        log_error "✗ Restaurant API health check failed"
    fi

    # Check Airflow
    if curl -f http://localhost:8081/health >/dev/null 2>&1; then
        log_success "✓ Airflow is healthy"
    else
        log_warning "⚠ Airflow may still be starting up"
    fi

    # Check database connectivity
    if docker-compose exec -T postgres pg_isready -U postgres_admin >/dev/null 2>&1; then
        log_success "✓ PostgreSQL is healthy"
    else
        log_error "✗ PostgreSQL health check failed"
    fi

    # Check if data is flowing
    log_info "Checking data ingestion..."
    sleep 10  # Wait for some data to be generated

    EVENT_COUNT=$(docker-compose exec -T postgres psql -U restaurant_user -d restaurant_analytics -t -c "SELECT COUNT(*) FROM raw_data.events_raw;" 2>/dev/null | tr -d ' ' || echo "0")

    if [[ "$EVENT_COUNT" -gt 0 ]]; then
        log_success "✓ Data is flowing ($EVENT_COUNT events ingested)"
    else
        log_warning "⚠ No events detected yet, data may still be initializing"
    fi
}

show_next_steps() {
    echo ""
    log_success "🎉 Restaurant Analytics Stack deployment completed!"
    echo ""
    log_info "Next Steps:"
    echo "==========="
    echo "1. 🔐 Access Airflow at http://localhost:8081"
    echo "   - Enable and monitor the 'restaurant_realtime_stream' DAG"
    echo "   - Check data ingestion in the 'restaurant_stream_ingest_polling' DAG (fallback)"
    echo ""
    echo "2. 📊 Set up Metabase at http://localhost:3000"
    echo "   - Create admin account"
    echo "   - Connect to PostgreSQL database:"
    echo "     Host: postgres"
    echo "     Database: restaurant_analytics"
    echo "     User: analytics_reader"
    echo "     Password: (check .env file)"
    echo ""
    echo "3. 🗄️ Access PgAdmin at http://localhost:8080"
    echo "   - Add server connection to explore data"
    echo ""
    echo "4. 📈 Start building dashboards and exploring your data!"
    echo ""
    log_info "💡 Tip: Check README.md for detailed usage instructions and troubleshooting"
}

cleanup_on_error() {
    log_error "Setup failed. Cleaning up..."
    docker-compose down -v 2>/dev/null || true
    exit 1
}

# =============================================================================
# Main Execution
# =============================================================================

main() {
    echo "🍕 Restaurant Analytics Stream Stack Setup"
    echo "=========================================="
    echo ""

    # Set up error handling
    trap cleanup_on_error ERR

    # Run setup steps
    check_requirements
    setup_environment
    initialize_data_directories
    check_port_availability
    deploy_stack

    # Wait a bit for services to stabilize
    log_info "Allowing services to stabilize..."
    sleep 15

    show_service_status
    run_health_checks
    show_next_steps

    log_success "Setup completed successfully! 🎉"
}

# Handle command line arguments
case "${1:-}" in
    "cleanup")
        log_info "Cleaning up deployment..."
        docker-compose down -v
        docker system prune -f
        log_success "Cleanup completed"
        ;;
    "status")
        show_service_status
        run_health_checks
        ;;
    "restart")
        log_info "Restarting services..."
        docker-compose restart
        log_success "Services restarted"
        ;;
    "logs")
        docker-compose logs -f "${2:-}"
        ;;
    *)
        main
        ;;
esac