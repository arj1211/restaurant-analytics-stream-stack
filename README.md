# Restaurant Analytics Stream Stack

A complete real-time analytics platform for restaurant data, featuring streaming ingestion, data warehousing, and visualization capabilities.

## 🏗️ Architecture Overview

```
Restaurant API (SSE) → Airflow ETL → PostgreSQL → Metabase
      ↓                    ↓            ↓          ↓
[Event Generator]   [Stream Processor] [Data Warehouse] [Analytics UI]
```

## ✨ Key Features

- **🔄 Real-time Streaming**: Server-Sent Events (SSE) for sub-second data latency
- **🛡️ Security**: Role-based database access with proper user separation
- **📊 Analytics Ready**: Pre-built dashboards and KPI tracking
- **🐳 Containerized**: Complete Docker Compose deployment
- **⚡ High Performance**: Optimized batch processing and indexing
- **📈 Scalable**: Designed for production workloads

## 🚀 Quick Start

### Prerequisites
- Docker and Docker Compose
- 8GB+ RAM recommended
- 10GB+ disk space

### 1. Clone and Setup
```bash
git clone <repository-url>
cd restaurant-analytics-stream-stack

# Copy and configure environment
cp .env.example .env
# Edit .env with your preferred passwords and settings
```

### 2. Initialize Data Directories
```bash
python init_data_dir.py
```

### 3. Deploy the Stack
```bash
docker-compose up -d
```

### 4. Access Services
- **Airflow**: http://localhost:8081 (admin/admin_password)
- **Metabase**: http://localhost:3000 (setup required)
- **PgAdmin**: http://localhost:8080 (admin@restaurant-analytics.local)
- **Restaurant API**: http://localhost:8000 (health check: /health)

## 🛠️ Configuration

### Environment Variables

Copy `.env.example` to `.env` and customize:

```bash
# Key configurations
POSTGRES_SUPERUSER=postgres_admin
POSTGRES_SUPERUSER_PASSWORD=your_secure_password

RESTAURANT_DB_USER=restaurant_user
RESTAURANT_DB_PASSWORD=your_app_password

AIRFLOW_ADMIN_USER=airflow_admin
AIRFLOW_ADMIN_PASSWORD=your_airflow_password
```

### Port Configuration
If you need to change ports (to avoid conflicts):
```bash
POSTGRES_EXTERNAL_PORT=5433
AIRFLOW_EXTERNAL_PORT=8082
METABASE_EXTERNAL_PORT=3001
```

## 📊 Data Architecture

### Database Structure
- **`postgres`**: System/default database
- **`restaurant_analytics`**: Application data
- **`airflow_db`**: Airflow metadata

### Schema Organization
- **`raw_data`**: Raw event streams and audit logs
- **`analytics`**: Processed business intelligence tables
- **`staging`**: Temporary ETL processing tables

### Key Tables
```sql
-- Analytics schema
analytics.orders          -- Order facts and financials
analytics.order_items     -- Line item details
analytics.payments        -- Payment transactions
analytics.feedback        -- Customer satisfaction data

-- Raw data schema
raw_data.events_raw       -- Complete event audit trail
```

## 🔄 Data Processing

### Real-time Streaming (Recommended)
- **DAG**: `restaurant_realtime_stream`
- **Method**: Server-Sent Events (SSE)
- **Latency**: Sub-second
- **Throughput**: 1000+ events/second

### Legacy Polling (Fallback)
- **DAG**: `restaurant_stream_ingest_polling`
- **Method**: REST API polling
- **Frequency**: Every 2 minutes
- **Use Case**: Fallback or batch processing

## 👥 User Management

### Database Roles
- **`postgres_admin`**: Superuser for administrative tasks
- **`restaurant_user`**: Application read/write access
- **`airflow_user`**: ETL operations and metadata
- **`analytics_reader`**: Read-only access for BI tools

### Airflow Access
- **Admin**: Full DAG management and configuration
- **Viewer**: Read-only dashboard access

## 📈 Monitoring & Analytics

### Built-in Analytics Views
```sql
-- Sales performance
SELECT * FROM analytics.daily_sales WHERE day >= CURRENT_DATE - 7;

-- Menu performance
SELECT * FROM analytics.menu_performance ORDER BY total_revenue DESC;

-- Customer satisfaction
SELECT * FROM analytics.satisfaction_summary WHERE day >= CURRENT_DATE - 30;
```

### System Health Checks
```sql
-- Check recent data ingestion
SELECT analytics.health_check();

-- Data quality validation
SELECT analytics.validate_data_consistency();
```

### Metabase Dashboards
After setup, create dashboards for:
- **Real-time Sales**: Live transaction monitoring
- **Performance KPIs**: Revenue, AOV, customer satisfaction
- **Operational Insights**: Peak hours, popular items, service performance

## 🔧 Development & Debugging

### Hot Reload
Enable development mode in `.env`:
```bash
API_HOT_RELOAD=true
AIRFLOW_LOAD_EXAMPLES=true
```

### Logs and Debugging
```bash
# View service logs
docker-compose logs -f airflow-scheduler
docker-compose logs -f restaurant-api

# Database access
docker-compose exec postgres psql -U restaurant_user -d restaurant_analytics

# Airflow shell
docker-compose exec airflow-webserver airflow dags list
```

### Custom Event Processing
Add custom processors in `data/airflow/plugins/sse_operator.py`:
```python
@create_custom_event_processor
def my_custom_processor(cursor, event, payload):
    # Custom event processing logic
    pass

# Use in DAG
custom_processors = {
    'custom_event_type': my_custom_processor
}
```

## 🚨 Troubleshooting

### Common Issues

**Services won't start**
```bash
# Check service status
docker-compose ps

# Restart problematic services
docker-compose restart postgres
docker-compose restart airflow-init
```

**Database connection errors**
```bash
# Verify database initialization
docker-compose logs db-init

# Check user creation
docker-compose exec postgres psql -U postgres_admin -c "\\du"
```

**Airflow DAGs not appearing**
```bash
# Check DAG folder permissions
ls -la data/airflow/dags/

# Restart scheduler
docker-compose restart airflow-scheduler
```

**No data flowing**
```bash
# Check API health
curl http://localhost:8000/health

# Verify SSE stream
curl -H "Accept: text/event-stream" http://localhost:8000/stream

# Check Airflow variables
docker-compose exec airflow-webserver airflow variables get restaurant_stream_offset
```

### Performance Tuning

**Database Performance**
```bash
# Adjust PostgreSQL settings in .env
POSTGRES_MAX_CONNECTIONS=200
POSTGRES_SHARED_BUFFERS=512MB
POSTGRES_EFFECTIVE_CACHE_SIZE=2GB
```

**Airflow Performance**
```bash
# Increase parallelism
AIRFLOW_PARALLELISM=32
AIRFLOW_DAG_CONCURRENCY=16
```

## 📋 Production Deployment

### Security Checklist
- [ ] Change all default passwords
- [ ] Use environment-specific .env files
- [ ] Enable SSL/TLS for web interfaces
- [ ] Configure firewall rules
- [ ] Set up backup procedures
- [ ] Enable audit logging
- [ ] Review user permissions

### Backup Strategy
```bash
# Database backups
docker-compose exec postgres pg_dump -U postgres_admin restaurant_analytics > backup.sql

# Configuration backups
tar -czf config-backup.tar.gz .env docker-compose.yml sql/
```

### Scaling Considerations
- **Horizontal scaling**: Add Airflow workers
- **Database scaling**: Consider read replicas for analytics
- **Storage**: Monitor disk usage for raw events
- **Monitoring**: Implement application monitoring (Prometheus, Grafana)

## 🤝 Contributing

### Development Setup
1. Fork the repository
2. Create feature branch
3. Make changes with tests
4. Submit pull request

### Code Standards
- Follow PEP 8 for Python code
- Document new features and APIs
- Include tests for new functionality
- Update documentation

## 📄 License

This project is licensed under the MIT License - see the LICENSE file for details.

## 🆘 Support

- **Issues**: GitHub Issues
- **Documentation**: This README and inline code docs
- **Community**: GitHub Discussions

---

**Built with ❤️ for restaurant analytics and real-time data processing.**