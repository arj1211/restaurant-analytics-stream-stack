# Troubleshooting Guide

This guide helps resolve common issues with the Restaurant Analytics Stream Stack deployment.

## 🚨 Quick Diagnostics

### Check Overall Status
```bash
# Check all services
docker-compose ps

# Check service health
docker-compose exec postgres pg_isready -U postgres_admin
curl -f http://localhost:8000/health
curl -f http://localhost:8081/health
```

### View Logs
```bash
# All services
docker-compose logs

# Specific service
docker-compose logs -f postgres
docker-compose logs -f airflow-scheduler
docker-compose logs -f restaurant-api
```

## 🐛 Common Issues

### 1. Services Won't Start

**Symptoms:**
- `docker-compose up` fails
- Services show as "Exited" or "Restarting"

**Solutions:**

```bash
# Check Docker daemon is running
docker version

# Check available resources
docker system df
docker system prune -f  # Clean up if needed

# Check port conflicts
netstat -tulpn | grep -E ':(5432|8080|8081|3000|8000)'

# Restart with fresh state
docker-compose down -v
docker-compose up -d
```

### 2. Database Connection Errors

**Symptoms:**
- "Connection refused" errors
- "Role does not exist" errors
- Airflow can't connect to database

**Solutions:**

```bash
# Check database initialization
docker-compose logs db-init

# Verify database users exist
docker-compose exec postgres psql -U postgres_admin -c "\du"

# Check database exists
docker-compose exec postgres psql -U postgres_admin -c "\l"

# Re-run database initialization
docker-compose restart db-init
```

### 3. Airflow Issues

**Symptoms:**
- Airflow UI not loading
- DAGs not appearing
- Tasks failing with connection errors

**Solutions:**

```bash
# Check Airflow initialization
docker-compose logs airflow-init

# Restart Airflow services
docker-compose restart airflow-webserver airflow-scheduler

# Check DAG folder permissions
ls -la data/airflow/dags/

# Verify connections in Airflow
docker-compose exec airflow-webserver airflow connections list

# Re-create connections
docker-compose restart airflow-init
```

### 4. No Data Flowing

**Symptoms:**
- No events in database
- Empty dashboards
- API returning no events

**Solutions:**

```bash
# Check API is generating data
curl http://localhost:8000/events

# Check SSE stream
curl -H "Accept: text/event-stream" http://localhost:8000/stream

# Check Airflow variables
docker-compose exec airflow-webserver airflow variables get restaurant_stream_offset

# Check database for events
docker-compose exec postgres psql -U restaurant_user -d restaurant_analytics -c "SELECT COUNT(*) FROM raw_data.events_raw;"

# Reset offset if needed
docker-compose exec airflow-webserver airflow variables set restaurant_stream_offset 0
```

### 5. Metabase Connection Issues

**Symptoms:**
- Can't connect to database from Metabase
- "Unknown database" error

**Solutions:**

Database Connection Settings:
- **Host**: `postgres` (not localhost)
- **Port**: `5432`
- **Database**: `restaurant_analytics`
- **Username**: `analytics_reader`
- **Password**: Check `.env` file for `ANALYTICS_READONLY_PASSWORD`

```bash
# Verify analytics user can connect
docker-compose exec postgres psql -U analytics_reader -d restaurant_analytics -c "SELECT 1;"

# Check Metabase logs
docker-compose logs metabase
```

### 6. PgAdmin Issues

**Symptoms:**
- Can't log into PgAdmin
- Can't add PostgreSQL server

**Solutions:**

```bash
# Check PgAdmin credentials in .env
grep PGADMIN .env

# Add server in PgAdmin:
# Name: Restaurant Analytics
# Host: postgres
# Port: 5432
# Username: Check .env file
# Password: Check .env file
```

### 7. Performance Issues

**Symptoms:**
- Slow query responses
- High memory usage
- Container crashes

**Solutions:**

```bash
# Check resource usage
docker stats

# Adjust PostgreSQL settings in .env
POSTGRES_MAX_CONNECTIONS=50
POSTGRES_SHARED_BUFFERS=128MB
POSTGRES_EFFECTIVE_CACHE_SIZE=512MB

# Restart with new settings
docker-compose down && docker-compose up -d
```

## 🔧 Advanced Troubleshooting

### Database Deep Dive

```bash
# Connect as superuser
docker-compose exec postgres psql -U postgres_admin

# Check database sizes
SELECT datname, pg_size_pretty(pg_database_size(datname)) FROM pg_database;

# Check table sizes
\c restaurant_analytics
SELECT schemaname, tablename, pg_size_pretty(pg_total_relation_size(schemaname||'.'||tablename)) FROM pg_tables WHERE schemaname IN ('analytics', 'raw_data');

# Check recent activity
SELECT * FROM raw_data.events_raw ORDER BY ingested_at DESC LIMIT 10;
```

### Airflow Deep Dive

```bash
# Check DAG details
docker-compose exec airflow-webserver airflow dags show restaurant_realtime_stream

# Check task instances
docker-compose exec airflow-webserver airflow tasks list restaurant_realtime_stream

# Test connection
docker-compose exec airflow-webserver airflow connections test postgres_restaurant
```

### Network Issues

```bash
# Check internal network
docker network ls
docker network inspect restaurant-analytics-stream-stack_default

# Test internal connectivity
docker-compose exec airflow-webserver ping postgres
docker-compose exec airflow-webserver curl http://restaurant-api:8000/health
```

## 🏥 Health Monitoring

### Automated Health Check Script

Create `health-check.sh`:
```bash
#!/bin/bash

echo "=== Health Check Report ==="
echo "Timestamp: $(date)"
echo

# Service status
echo "--- Service Status ---"
docker-compose ps

# API Health
echo -e "\n--- API Health ---"
curl -s http://localhost:8000/health | jq '.' || echo "API not responding"

# Database connectivity
echo -e "\n--- Database Health ---"
docker-compose exec -T postgres pg_isready -U postgres_admin && echo "PostgreSQL: OK" || echo "PostgreSQL: FAILED"

# Recent events count
echo -e "\n--- Data Flow ---"
EVENTS=$(docker-compose exec -T postgres psql -U restaurant_user -d restaurant_analytics -t -c "SELECT COUNT(*) FROM raw_data.events_raw WHERE ingested_at > NOW() - INTERVAL '5 minutes';" | tr -d ' ')
echo "Recent events (5 min): $EVENTS"

# Airflow status
echo -e "\n--- Airflow Status ---"
curl -s http://localhost:8081/health | jq '.' || echo "Airflow not responding"

echo -e "\n=== End Health Check ==="
```

### Monitoring Queries

```sql
-- Check ingestion rate
SELECT
    date_trunc('minute', ingested_at) as minute,
    COUNT(*) as events_per_minute
FROM raw_data.events_raw
WHERE ingested_at > NOW() - INTERVAL '1 hour'
GROUP BY date_trunc('minute', ingested_at)
ORDER BY minute DESC;

-- Check data quality
SELECT analytics.validate_data_consistency();

-- Check system health
SELECT analytics.health_check();
```

## 🔄 Recovery Procedures

### Complete Reset

```bash
# Stop everything and remove volumes
docker-compose down -v

# Remove all data
rm -rf data/

# Re-initialize
python init_data_dir.py
docker-compose up -d
```

### Partial Reset

```bash
# Reset just the database
docker-compose stop postgres
docker volume rm restaurant-analytics-stream-stack_postgres-data
docker-compose up -d postgres

# Reset Airflow metadata
docker-compose stop airflow-webserver airflow-scheduler
docker volume rm restaurant-analytics-stream-stack_airflow-data
docker-compose up -d
```

### Data-Only Reset

```bash
# Keep configuration, reset data
docker-compose exec postgres psql -U postgres_admin -d restaurant_analytics -c "TRUNCATE TABLE raw_data.events_raw CASCADE;"
docker-compose exec airflow-webserver airflow variables set restaurant_stream_offset 0
```

## 📞 Getting Help

### Log Collection

```bash
# Collect all logs
mkdir troubleshooting-logs
docker-compose logs > troubleshooting-logs/all-services.log
docker-compose logs postgres > troubleshooting-logs/postgres.log
docker-compose logs airflow-scheduler > troubleshooting-logs/airflow.log
docker-compose logs restaurant-api > troubleshooting-logs/api.log

# System information
docker version > troubleshooting-logs/docker-version.txt
docker-compose version > troubleshooting-logs/compose-version.txt
cat .env > troubleshooting-logs/environment.txt  # Remove passwords first!
```

### Support Checklist

Before seeking help, please provide:

1. **Environment Information**
   - Operating System and version
   - Docker and Docker Compose versions
   - Available RAM and disk space

2. **Error Details**
   - Exact error messages
   - Steps to reproduce
   - When the issue started

3. **Configuration**
   - Modified settings in `.env`
   - Custom changes to `docker-compose.yml`
   - Network/firewall configurations

4. **Logs**
   - Relevant service logs
   - Browser console errors (for UI issues)
   - Database error logs

### Common Solutions Summary

| Issue | Quick Fix |
|-------|-----------|
| Port conflicts | Change ports in `.env` |
| Permissions | `chmod +x setup.sh` |
| Out of disk | `docker system prune -f` |
| Connection refused | `docker-compose restart` |
| Missing data | Check offset, restart DAGs |
| Slow performance | Reduce batch sizes |
| Memory issues | Increase Docker memory limit |

Remember: Most issues can be resolved by restarting services or checking configuration files! 🔄