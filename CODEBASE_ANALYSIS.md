# Restaurant Analytics Stream Stack - Codebase Analysis

## Overview

This is a **real-time restaurant analytics streaming system** built with modern data engineering tools. The system generates, ingests, and processes restaurant transaction data in real-time for analytics and business intelligence purposes.

## Architecture Overview

This is a **streaming data pipeline** that generates realistic restaurant events and processes them through a complete ETL pipeline. The system consists of:

1. **Data Generator** - A FastAPI service that generates realistic restaurant events
2. **Data Ingestion** - Apache Airflow DAG that streams data into PostgreSQL
3. **Data Storage** - PostgreSQL database with structured analytics tables
4. **Admin Tools** - PgAdmin for database management

## Technology Stack

- **FastAPI** - REST API and real-time event streaming
- **Apache Airflow** - Workflow orchestration and data pipeline management
- **PostgreSQL** - Data warehouse for analytics
- **Docker Compose** - Container orchestration
- **Server-Sent Events (SSE)** - Real-time streaming protocol
- **Python** - Primary programming language

## Project Structure

```
restaurant-analytics-stream-stack/
├── docker-compose.yml                    # Main orchestration file
├── postgres-compose.yml                  # Standalone PostgreSQL setup
├── init_data_dir.py                     # Data directory initialization script
├── restaurant_api/                      # FastAPI streaming data generator
│   ├── app/main.py                      # Core streaming API with synthetic data generation
│   ├── sql/restaurant_ddl.sql           # Database schema definitions
│   ├── Dockerfile                       # API container configuration
│   └── requirements.txt                 # Python dependencies (FastAPI, Uvicorn)
└── data/airflow/dags/                   # Airflow workflows
    └── restaurant_stream_ingest.py      # Main ingestion pipeline
```

## Core Components

### 1. Restaurant API (`restaurant_api/app/main.py`)

**Purpose**: Generates realistic synthetic restaurant transaction data with streaming capabilities.

**Key Features**:
- Continuous event generation with diurnal patterns (higher volume during meal times)
- Multiple event types: `order_created`, `order_item_added`, `payment_captured`, `feedback_submitted`
- Weighted random selection for realistic data distribution
- In-memory event store with offset-based streaming
- REST API (`/events`) and Server-Sent Events streaming (`/stream`) endpoints
- Health check endpoint (`/health`)

**Event Types Generated**:
- **Order Creation**: Service types (dine-in 62%, takeout 23%, delivery 15%)
- **Order Items**: 13 categories with time-based preferences and realistic pricing
- **Payment Processing**: Multiple payment methods (credit 52%, debit 18%, cash 14%, etc.)
- **Customer Feedback**: Ratings and NPS scores (25% response rate)

**Data Generation Logic**:
- **Time-aware patterns**: Coffee/breakfast popular in morning, alcohol/entrees in evening
- **Realistic pricing**: Category-specific price ranges ($2.25-$40.00)
- **Financial accuracy**: Subtotal, 13% HST tax, variable tips by service type
- **Geographic distribution**: 12 Ontario restaurant locations (LOC-ON-001 to LOC-ON-012)

### 2. Database Schema (`restaurant_api/sql/restaurant_ddl.sql`)

The system implements a **star schema** optimized for analytics:

#### Core Tables:
- **`events_raw`**: Raw event log with JSONB payloads for audit trail
- **`orders`**: Normalized order facts (order_id, visit_id, service_type, financials)
- **`order_items`**: Line items with menu details and pricing
- **`payments`**: Payment transactions with methods and providers
- **`feedback`**: Customer ratings, NPS scores, and comments

#### Key Design Patterns:
- UUID primary keys for distributed system compatibility
- TIMESTAMPTZ for proper timezone handling
- JSONB for flexible raw event storage
- Foreign key relationships for data integrity
- Numeric types for precise financial calculations

### 3. Airflow DAG (`data/airflow/dags/restaurant_stream_ingest.py`)

**Purpose**: Continuously ingests streaming data from the API into PostgreSQL for analytics.

**Configuration**:
- **Schedule**: Runs every minute (`*/1 * * * *`)
- **Concurrency**: Single active run to prevent data conflicts
- **Tags**: `["restaurant", "stream", "synthetic"]`

**Processing Logic**:
1. **Watermark Management**: Tracks last processed offset in Airflow Variables
2. **Batch Fetching**: Retrieves up to 1000 new events per run
3. **Dual Storage**: Inserts into both raw events and normalized tables
4. **Event Processing**: Parses different event types into appropriate tables
5. **Idempotency**: Uses `ON CONFLICT DO NOTHING` to prevent duplicates
6. **State Tracking**: Updates watermark after successful processing

### 4. Container Orchestration (`docker-compose.yml`)

**Services Architecture**:
- **postgres**: PostgreSQL 15 database server (port 5432)
- **pgadmin**: Database administration interface (port 8080)
- **restaurant-api**: FastAPI event generator (port 8000)
- **airflow-webserver**: Airflow UI (port 8081)
- **airflow-scheduler**: Workflow execution engine
- **airflow-init**: One-time setup for connections and users
- **db-bootstrap**: Initializes restaurant database schema

**Key Configuration**:
- Health checks for all services
- Volume mounts for data persistence
- Environment variable management
- Service dependencies and startup order
- Development-friendly hot reload capabilities

## Data Flow Architecture

```
Restaurant API → Airflow DAG → PostgreSQL → PgAdmin
    ↓               ↓              ↓          ↓
[Event Generator] [ETL Pipeline] [Data Warehouse] [Analytics UI]
```

### Detailed Flow:
1. **Generation**: FastAPI continuously generates realistic restaurant events in memory
2. **Streaming**: Events available via REST API with offset-based pagination and SSE streaming
3. **Ingestion**: Airflow polls API every minute and loads new data using watermark tracking
4. **Storage**: Events stored both as raw JSONB and in normalized analytics tables
5. **Analysis**: PgAdmin provides SQL interface for business intelligence queries

## Key Features & Design Patterns

### 1. Realistic Data Generation
- **Time-aware patterns**: Different ordering behaviors by time of day
- **Weighted selections**: Realistic distribution of menu items, payment methods
- **Financial calculations**: Proper tax, tip, and total calculations
- **Geographic diversity**: Multiple restaurant locations

### 2. Stream Processing
- **Offset-based watermarking**: Reliable tracking of processed events
- **Batch processing**: Efficient bulk operations with configurable limits
- **Error handling**: Timeout configurations and retry logic
- **Real-time capabilities**: Both polling and push-based streaming

### 3. Data Engineering Best Practices
- **Idempotent operations**: Duplicate-safe insertions
- **Audit trail**: Complete raw event history preservation
- **Health monitoring**: Comprehensive service health checks
- **Configuration management**: Environment-based settings
- **Development workflow**: Hot reload and easy local setup

### 4. Analytics Readiness
- **Star schema design**: Optimized for analytical queries
- **Dual storage approach**: Raw events + normalized tables
- **Time-series optimization**: Proper timestamp indexing
- **Flexible querying**: JSONB for ad-hoc analysis

## Synthetic Data Characteristics

The system generates highly realistic restaurant data including:

### Operational Patterns:
- **12 restaurant locations** across Ontario (LOC-ON-001 to LOC-ON-012)
- **13 menu categories** with realistic pricing ($2.25 to $40.00 range)
- **Time-based ordering patterns**: Coffee in morning, alcohol in evening
- **Service type distribution**: 62% dine-in, 23% takeout, 15% delivery

### Financial Accuracy:
- **Payment method distribution**: 52% credit card, 18% debit, 14% cash, 12% digital wallet, 4% gift card
- **Tax calculations**: 13% HST (Ontario harmonized sales tax)
- **Tip patterns**: Variable by service type (12-24% dine-in, 0-10% takeout, 8-20% delivery)
- **Provider distribution**: Realistic card provider ratios (VISA 48%, Mastercard 42%, Amex 10%)

### Customer Behavior:
- **Feedback response rate**: 25% of orders receive customer feedback
- **Rating distribution**: Weighted toward positive experiences (70% rating 4-5 stars)
- **NPS correlation**: Net Promoter Score aligned with star ratings
- **Order complexity**: 1-4 items per order with realistic distributions

## Getting Started

### Prerequisites:
- Docker and Docker Compose
- Environment variables for database credentials
- Sufficient disk space for PostgreSQL data

### Key Endpoints:
- **Airflow UI**: http://localhost:8081
- **PgAdmin**: http://localhost:8080
- **Restaurant API**: http://localhost:8000
- **API Health Check**: http://localhost:8000/health
- **Event Stream**: http://localhost:8000/stream

### Initial Setup:
1. Run `python init_data_dir.py` to create data directories
2. Configure environment variables (`.env` file)
3. Start services with `docker-compose up`
4. Access Airflow UI to monitor data ingestion
5. Use PgAdmin to query analytics tables

## Use Cases

This system is ideal for:

### Business Intelligence:
- Sales performance analysis by location and time
- Menu item popularity and profitability analysis
- Customer satisfaction tracking and NPS monitoring
- Payment method trends and preferences

### Operational Analytics:
- Peak hour identification for staffing optimization
- Service type performance comparison
- Location-based performance metrics
- Revenue trend analysis

### Technical Demonstrations:
- Real-time streaming data architecture
- Modern ETL pipeline implementation
- Event-driven system design
- Containerized data engineering stack

## Technical Excellence

This codebase demonstrates several advanced patterns:

- **Event Sourcing**: Complete audit trail with raw event storage
- **CQRS Pattern**: Separate read models for different query patterns
- **Microservices Architecture**: Loosely coupled, containerized services
- **Stream Processing**: Real-time and batch processing capabilities
- **Infrastructure as Code**: Complete Docker Compose orchestration
- **Observability**: Health checks and monitoring across all services

This restaurant analytics streaming stack represents a production-ready example of modern data engineering practices, suitable for learning, demonstration, or as a foundation for real restaurant analytics systems.