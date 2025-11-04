# Convert CRLF to LF for init scripts to avoid 'bash\r' errors inside Linux containers

$paths = @(
    "docker/postgres-init/10_airflow_init.sh",
    "docker/postgres-init/20_restaurant_init.sh"
)

foreach ($p in $paths) {
    if (-Not (Test-Path -LiteralPath $p)) {
        Write-Host "Skipping: $p not found"
        continue
    }

    # Read raw content and replace Windows CRLF with Unix LF
    $raw = Get-Content -LiteralPath $p -Raw
    $lf = $raw -replace "`r`n", "`n"

    # Write back using UTF-8 (no BOM)
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($p, $lf, $utf8NoBom)

    Write-Host "Converted line endings to LF for $p"
}
