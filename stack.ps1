[CmdletBinding()]
param(
  [Parameter(Mandatory = $true, Position = 0)]
  [ValidateSet('Reset','Clean','Up','Check','Trigger','Verify','Ps','Logs','Down','Destroy','Help')]
  [string]$Action
)

$ErrorActionPreference = 'Stop'

if ($PSScriptRoot) {
  Set-Location $PSScriptRoot
}

function Write-Section($text) { Write-Host "=== $text ===" -ForegroundColor Cyan }

function Clean {
  Write-Section "Cleaning Airflow logs, PgAdmin data, Postgres data, and Python caches"
  $paths = @("data/airflow/logs","data/pgadmin","data/postgres")
  foreach ($p in $paths) {
    if (Test-Path $p) {
      Get-ChildItem -Path $p -Force | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
    }
    New-Item -ItemType Directory -Path $p -Force | Out-Null
  }
  Get-ChildItem -Path . -Recurse -Directory -Filter "__pycache__" -Force -ErrorAction SilentlyContinue | ForEach-Object {
    Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction SilentlyContinue
  }
  Write-Host "Clean complete."
}

function Up {
  Write-Section "Bringing up stack"
  & docker compose up -d
}

function Ps {
  Write-Section "Container status"
  & docker compose ps
}

function Logs {
  Write-Section "Tailing logs"
  & docker compose logs --tail=200 --follow
}

function Check {
  Write-Section "Checking container status"
  & docker compose ps

  Write-Section "Checking Restaurant API health"
  & docker compose exec webserver bash -lc "curl -s http://restaurant-api:8000/health || true"

  Write-Section "Checking Airflow SQL Alchemy connection"
  & docker compose exec webserver bash -lc "airflow config get-value database sql_alchemy_conn || true"

  Write-Section "Checking Airflow connections"
  & docker compose exec webserver bash -lc "airflow connections list | grep -E 'postgres_restaurant|restaurant_api' || true"

  Write-Section "Checking Postgres databases exist (airflow_db, restaurant_analytics)"
  $sqlDb = "SELECT datname FROM pg_database WHERE datname IN ('airflow_db','restaurant_analytics');"
  & docker compose exec postgres psql -U postgres -d postgres -v ON_ERROR_STOP=1 -c "$sqlDb"

  Write-Section "Checking Postgres roles exist (airflow_user, restaurant_user)"
  $sqlRoles = "SELECT rolname FROM pg_roles WHERE rolname IN ('airflow_user','restaurant_user');"
  & docker compose exec postgres psql -U postgres -d postgres -v ON_ERROR_STOP=1 -c "$sqlRoles"

  Write-Section "Pre-ingestion events_raw count (should be 0 on fresh reset)"
  $sqlPre = "SELECT COUNT(*) AS events_raw_count FROM raw_data.events_raw;"
  try {
    & docker compose exec postgres psql -U postgres -d restaurant_analytics -v ON_ERROR_STOP=1 -c "$sqlPre"
  } catch {
    Write-Warning "Pre-ingestion count check failed (database may not be ready yet)."
  }
}

function Trigger {
  Write-Section "Triggering realtime DAG"
  & docker compose exec webserver bash -lc "airflow dags trigger restaurant_realtime_stream && sleep 8 && airflow dags list-runs -d restaurant_realtime_stream | tail -n 10"
}

function Verify {
  Write-Section "Verifying row counts in key tables"
  $q1 = "SELECT COUNT(*) AS events_raw_count FROM raw_data.events_raw;"
  $q2 = "SELECT COUNT(*) AS orders_count FROM analytics.orders;"
  $q3 = "SELECT COUNT(*) AS payments_count FROM analytics.payments;"
  $q4 = "SELECT COUNT(*) AS audit_count FROM analytics.audit_log;"
  $q5 = "SELECT MAX(ingested_at) AS last_ingested FROM raw_data.events_raw;"
  & docker compose exec postgres psql -U postgres -d restaurant_analytics -v ON_ERROR_STOP=1 -c "$q1" -c "$q2" -c "$q3" -c "$q4" -c "$q5"
}

function Down {
  Write-Section "Stopping stack"
  & docker compose down
}

function Destroy {
  Write-Section "Destroying stack and local volumes"
  & docker compose down -v
  Clean
  Write-Host "Stack destroyed and local data cleaned."
}

function Help {
@"
Usage:
  powershell -ExecutionPolicy Bypass -File .\stack.ps1 -Action <Action>

Actions:
  Reset     Clean local data/caches, bring up the stack, and run basic checks
  Clean     Remove Airflow logs, PgAdmin data, Postgres data, and __pycache__
  Up        docker compose up -d
  Check     Verify containers, API health, Airflow config/connections, DBs/roles
  Trigger   Trigger the realtime DAG and show recent runs
  Verify    Row counts for key tables and last ingestion timestamp
  Ps        Container status
  Logs      Tail logs for all services
  Down      docker compose down
  Destroy   docker compose down -v and local data cleanup
  Help      Show this help
"@ | Write-Host
}

switch ($Action) {
  'Reset'   { Clean; Up; Check }
  'Clean'   { Clean }
  'Up'      { Up }
  'Check'   { Check }
  'Trigger' { Trigger }
  'Verify'  { Verify }
  'Ps'      { Ps }
  'Logs'    { Logs }
  'Down'    { Down }
  'Destroy' { Destroy }
  default   { Help }
}
