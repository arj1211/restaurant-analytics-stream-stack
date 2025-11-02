@echo off
REM =============================================================================
REM Restaurant Analytics Stream Stack - Windows Setup Script
REM =============================================================================

setlocal EnableDelayedExpansion

echo 🍕 Restaurant Analytics Stream Stack Setup (Windows)
echo ==========================================
echo.

REM Check if Docker is installed
where docker >nul 2>&1
if errorlevel 1 (
    echo [ERROR] Docker is not installed or not in PATH
    echo Please install Docker Desktop and try again
    pause
    exit /b 1
)

REM Check if Docker Compose is available
docker compose version >nul 2>&1
if errorlevel 1 (
    docker-compose --version >nul 2>&1
    if errorlevel 1 (
        echo [ERROR] Docker Compose is not available
        echo Please ensure Docker Desktop is properly installed
        pause
        exit /b 1
    )
)

echo [INFO] Docker requirements satisfied
echo.

REM Check if Python is installed
where python >nul 2>&1
if errorlevel 1 (
    echo [WARNING] Python is not installed or not in PATH
    echo You may need to manually create data directories
) else (
    echo [INFO] Python found
)

REM Setup environment file
echo [INFO] Setting up environment configuration...
if exist ".env" (
    echo [WARNING] Environment file .env already exists
    set /p "overwrite=Do you want to overwrite it? (y/N): "
    if /i not "!overwrite!"=="y" (
        echo [INFO] Using existing environment file
        goto skip_env_setup
    )
)

if not exist ".env.example" (
    echo [ERROR] Example environment file .env.example not found
    pause
    exit /b 1
)

copy ".env.example" ".env" >nul
echo [SUCCESS] Environment file created from template
echo [INFO] Please review and customize .env file with your preferred passwords

:skip_env_setup

REM Initialize data directories
echo [INFO] Initializing data directories...
where python >nul 2>&1
if not errorlevel 1 (
    python init_data_dir.py
    echo [SUCCESS] Data directories initialized
) else (
    echo [INFO] Creating directories manually...
    mkdir "data\airflow\dags" 2>nul
    mkdir "data\airflow\logs" 2>nul
    mkdir "data\airflow\plugins" 2>nul
    mkdir "data\postgres" 2>nul
    mkdir "data\pgadmin" 2>nul
    mkdir "data\metabase" 2>nul
    echo [SUCCESS] Data directories created
)

REM Check for port conflicts (simplified check)
echo [INFO] Checking for potential port conflicts...
netstat -an | findstr ":5432" >nul
if not errorlevel 1 echo [WARNING] Port 5432 (PostgreSQL) may be in use

netstat -an | findstr ":8081" >nul
if not errorlevel 1 echo [WARNING] Port 8081 (Airflow) may be in use

netstat -an | findstr ":3000" >nul
if not errorlevel 1 echo [WARNING] Port 3000 (Metabase) may be in use

echo.

REM Deploy the stack
echo [INFO] Deploying the restaurant analytics stack...
echo [INFO] This may take several minutes on first run...
echo.

REM Pull images
echo [INFO] Pulling Docker images...
docker-compose pull

REM Build custom images
echo [INFO] Building custom images...
docker-compose build

REM Start services
echo [INFO] Starting services...
docker-compose up -d

if errorlevel 1 (
    echo [ERROR] Failed to start services
    echo Check docker-compose logs for details
    pause
    exit /b 1
)

echo.
echo [SUCCESS] Services started successfully!
echo.

REM Wait for services to be ready
echo [INFO] Waiting for services to be ready (this may take a few minutes)...
timeout /t 30 /nobreak >nul

REM Show service status
echo [INFO] Service Status:
echo ===================
docker-compose ps

echo.
echo [INFO] Service URLs:
echo ===================
echo 🎯 Airflow:        http://localhost:8081
echo 📊 Metabase:       http://localhost:3000
echo 🗄️ PgAdmin:        http://localhost:8080
echo 🚀 Restaurant API: http://localhost:8000
echo.

echo [INFO] Default Credentials:
echo ====================
echo Airflow:  Check .env file for AIRFLOW_ADMIN_USER and AIRFLOW_ADMIN_PASSWORD
echo PgAdmin:  Check .env file for PGLADMIN_DEFAULT_EMAIL and PGLADMIN_DEFAULT_PASSWORD
echo Metabase: Setup required on first access
echo.

REM Basic health checks
echo [INFO] Running basic health checks...

REM Check API (using PowerShell for HTTP request)
powershell -Command "try { $response = Invoke-WebRequest -Uri 'http://localhost:8000/health' -TimeoutSec 5; if ($response.StatusCode -eq 200) { Write-Host '[SUCCESS] ✓ Restaurant API is healthy' } } catch { Write-Host '[WARNING] ⚠ Restaurant API may still be starting' }"

REM Check Airflow (using PowerShell for HTTP request)
powershell -Command "try { $response = Invoke-WebRequest -Uri 'http://localhost:8081/health' -TimeoutSec 5; if ($response.StatusCode -eq 200) { Write-Host '[SUCCESS] ✓ Airflow is healthy' } } catch { Write-Host '[WARNING] ⚠ Airflow may still be starting' }"

echo.
echo [SUCCESS] 🎉 Restaurant Analytics Stack deployment completed!
echo.
echo [INFO] Next Steps:
echo ===========
echo 1. 🔐 Access Airflow at http://localhost:8081
echo    - Enable and monitor the 'restaurant_realtime_stream' DAG
echo    - Check data ingestion in the 'restaurant_stream_ingest_polling' DAG (fallback)
echo.
echo 2. 📊 Set up Metabase at http://localhost:3000
echo    - Create admin account
echo    - Connect to PostgreSQL database:
echo      Host: postgres
echo      Database: restaurant_analytics
echo      User: analytics_reader
echo      Password: (check .env file)
echo.
echo 3. 🗄️ Access PgAdmin at http://localhost:8080
echo    - Add server connection to explore data
echo.
echo 4. 📈 Start building dashboards and exploring your data!
echo.
echo [INFO] 💡 Tip: Check README.md for detailed usage instructions and troubleshooting
echo.
echo Setup completed successfully! 🎉
echo.
echo Press any key to exit...
pause >nul