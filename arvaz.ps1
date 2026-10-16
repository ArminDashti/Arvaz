# arvaz: lifecycle CLI for the arvaz-webui and arvaz-api Docker Compose apps.
# Usage: arvaz <webui|api|all> <status|run|stop|port|rebuild|update|version|service> [options]
#        arvaz <install|uninstall|version|help>

$ErrorActionPreference = 'Continue'
$CliVersion = '1.0.0'
$Root = $PSScriptRoot
$AppHome = Join-Path $env:LOCALAPPDATA 'arvaz'
$BinDir = Join-Path $AppHome 'bin'
$Network = 't3-net'
$Apps = [ordered]@{
    webui = @{ Dir = 'arvaz-webui'; Service = 'arvaz-webui'; Port = 8080; ContainerPort = 80 }
    api   = @{ Dir = 'arvaz-api'; Service = 'arvaz-api'; Port = 8090; ContainerPort = 8090; Image = 'arvaz-api:latest'; Dockerfile = 'dockerfile' }
}
$TopLevel = 'help', 'install', 'uninstall', 'version'
$Commands = 'status', 'run', 'stop', 'port', 'rebuild', 'update', 'version', 'service'

# Parse args: --key=value, --key value, -y; everything else is positional.
$Pos = @()
$Opt = @{}
for ($i = 0; $i -lt $args.Count; $i++) {
    $a = [string]$args[$i]
    if ($a -match '^--([\w-]+)=(.*)$') { $Opt[$Matches[1]] = $Matches[2] }
    elseif ($a -match '^--([\w-]+)$') {
        if ($i + 1 -lt $args.Count -and [string]$args[$i + 1] -notmatch '^-') { $i++; $Opt[$Matches[1]] = [string]$args[$i] }
        else { $Opt[$Matches[1]] = 'true' }
    }
    elseif ($a -eq '-y') { $Opt['y'] = 'true' }
    else { $Pos += $a }
}

function Show-Help {
    @"
arvaz $CliVersion - lifecycle for arvaz-webui and arvaz-api (Docker)

  arvaz <webui|api|all> status
  arvaz <target> run [--port=N]
  arvaz <target> stop
  arvaz <target> port [--port=N]
  arvaz <target> rebuild [--remove-data=yes|no] [-y]
  arvaz <target> update
  arvaz <target> version
  arvaz <target> service             (exit 2: Docker only)
  arvaz install | uninstall | version | help
"@ | Write-Host
}

function Fail-Usage($msg) {
    Write-Host $msg -ForegroundColor Red
    Show-Help
    exit 2
}

function Get-AppDir($n) { Join-Path $AppHome $n }

function Get-Cfg($n) {
    $f = Join-Path (Get-AppDir $n) 'config.json'
    if (Test-Path $f) { Get-Content $f -Raw | ConvertFrom-Json }
}

function Save-Cfg($n, $cfg) {
    New-Item -ItemType Directory -Force (Get-AppDir $n) | Out-Null
    $cfg | ConvertTo-Json | Set-Content (Join-Path (Get-AppDir $n) 'config.json')
}

function Get-Port($n) {
    $cfg = Get-Cfg $n
    if ($cfg) { [int]$cfg.port } else { [int]$Apps[$n].Port }
}

# Port lives in a generated override so repo compose files stay untouched.
function Write-Override($n) {
    $a = $Apps[$n]
    New-Item -ItemType Directory -Force (Get-AppDir $n) | Out-Null
    $port = Get-Port $n
    @"
services:
  $($a.Service):
    ports:
      - "${port}:$($a.ContainerPort)"
"@ | Set-Content (Join-Path (Get-AppDir $n) 'override.yml')
}

function Get-ComposeArgs($n) {
    Write-Override $n
    @('compose', '-p', "arvaz-$n", '-f', (Join-Path $Root "$($Apps[$n].Dir)\docker-compose.yml"), '-f', (Join-Path (Get-AppDir $n) 'override.yml'))
}

function Compose-Out($n, [string[]]$CmdArgs) {
    $all = @(Get-ComposeArgs $n) + @($CmdArgs)
    & docker @all 2>$null
}

function Invoke-Compose($n, [string[]]$CmdArgs) {
    $all = @(Get-ComposeArgs $n) + @($CmdArgs)
    & docker @all | Out-Host
    if ($LASTEXITCODE -ne 0) { throw "docker compose $($CmdArgs -join ' ') failed for $n" }
}

function Assert-Docker {
    docker info *> $null
    if ($LASTEXITCODE -ne 0) { throw 'Docker daemon not reachable' }
}

function Ensure-Network {
    docker network inspect $Network *> $null
    if ($LASTEXITCODE -ne 0) { docker network create $Network | Out-Host }
}

function Is-Running($n) {
    [bool](Compose-Out $n @('ps', '--status', 'running', '-q') | Where-Object { $_ })
}

function Test-Url($port) {
    try { Invoke-WebRequest -UseBasicParsing -Uri "http://localhost:$port" -TimeoutSec 3 | Out-Null; return $true }
    catch { return [bool]$_.Exception.Response }
}

function Wait-Url($port) {
    $end = (Get-Date).AddSeconds(30)
    while ((Get-Date) -lt $end) {
        if (Test-Url $port) { return $true }
        Start-Sleep -Seconds 1
    }
    $false
}

function Wait-App($n) {
    $port = (Get-Cfg $n).port
    if (Wait-Url $port) { Write-Host "$n up: http://localhost:$port"; return 0 }
    Write-Host "$n not reachable on port $port after 30s" -ForegroundColor Red
    1
}

function Test-PortFree([int]$p) {
    $l = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Any, $p)
    try { $l.Start(); return $true } catch { return $false } finally { $l.Stop() }
}

function Confirm-Action($msg) {
    if ($Opt.ContainsKey('y')) { return }
    if ((Read-Host "$msg Type 'yes' to continue") -ne 'yes') { throw 'aborted' }
}

function Get-SourceVersion {
    $v = git -C $Root describe --tags --always --dirty 2>$null
    if ($LASTEXITCODE -eq 0) { [string]$v } else { 'unknown' }
}

function Show-Status($n) {
    $cfg = Get-Cfg $n
    if (-not $cfg) { Write-Host "${n}: not installed (arvaz $n rebuild)"; return 4 }
    Compose-Out $n @('ps') | ForEach-Object { Write-Host $_ }
    $running = Is-Running $n
    $state = if ($running) { 'running' } else { 'stopped' }
    Write-Host "${n}: $state | port $($cfg.port) | http://localhost:$($cfg.port) | reachable=$(Test-Url $cfg.port) | version $($cfg.version)"
    if ($running) { 0 } else { 3 }
}

function Show-Version($n) {
    $cfg = Get-Cfg $n
    $installed = if ($cfg) { $cfg.version } else { 'not installed' }
    Write-Host "${n}: cli $CliVersion | source $(Get-SourceVersion) | installed $installed"
    if ($cfg -and $cfg.version -ne (Get-SourceVersion)) { Write-Host "${n}: source changed, run 'arvaz $n rebuild'" }
    0
}

function Set-Port($n, $value) {
    $p = 0
    if (-not [int]::TryParse([string]$value, [ref]$p) -or $p -lt 1 -or $p -gt 65535) { Fail-Usage "invalid port '$value' (1-65535)" }
    $cfg = Get-Cfg $n
    $current = if ($cfg) { [int]$cfg.port } else { [int]$Apps[$n].Port }
    if ($p -ne $current -and -not (Test-PortFree $p)) { throw "port $p is in use" }
    $ver = if ($cfg) { $cfg.version } else { $null }
    Save-Cfg $n ([pscustomobject]@{ port = $p; version = $ver })
    if (Is-Running $n) {
        Invoke-Compose $n @('up', '-d')
        Wait-App $n | Out-Null
    }
    else { Write-Host "$n port set to $p" }
}

function Start-App($n) {
    if (-not (Get-Cfg $n)) { Write-Host "${n}: not installed, run 'arvaz $n rebuild' first"; return 4 }
    if ($Opt.ContainsKey('port')) { Set-Port $n $Opt['port'] }
    if (Is-Running $n) { Write-Host "$n already running"; return (Show-Status $n) }
    Ensure-Network
    Invoke-Compose $n @('up', '-d')
    Wait-App $n
}

function Rebuild-App($n, [bool]$removeData) {
    $a = $Apps[$n]
    if ($removeData) {
        Write-Host "DESTRUCTIVE: removes containers, images, named volumes and config for ${n}:"
        Compose-Out $n @('config', '--volumes') | ForEach-Object { Write-Host "  volume $_" }
        Write-Host "  $(Get-AppDir $n)"
        Confirm-Action "Delete all $n data?"
        Invoke-Compose $n @('down', '-v', '--rmi', 'local', '--remove-orphans')
        Remove-Item -Recurse -Force (Get-AppDir $n) -ErrorAction SilentlyContinue
    }
    else {
        Invoke-Compose $n @('down', '--remove-orphans')
    }
    Ensure-Network
    if ($a.Dockerfile) {
        $dir = Join-Path $Root $a.Dir
        & docker build --no-cache --pull -f (Join-Path $dir $a.Dockerfile) -t $a.Image $dir | Out-Host
        if ($LASTEXITCODE -ne 0) { throw "docker build failed for $n" }
    }
    else {
        Invoke-Compose $n @('build', '--no-cache', '--pull')
    }
    Save-Cfg $n ([pscustomobject]@{ port = (Get-Port $n); version = (Get-SourceVersion) })
    Invoke-Compose $n @('up', '-d')
    Wait-App $n
}

function Update-App($n) {
    if (-not $script:Pulled) {
        git -C $Root pull --ff-only | Out-Host
        if ($LASTEXITCODE -ne 0) { throw 'git pull --ff-only failed, nothing rebuilt' }
        $script:Pulled = $true
    }
    Compose-Out $n @('pull') | Out-Host
    Rebuild-App $n $false
}

function Get-UserPath { @([Environment]::GetEnvironmentVariable('Path', 'User') -split ';' | Where-Object { $_ }) }

function Install-Shim {
    New-Item -ItemType Directory -Force $BinDir | Out-Null
    Set-Content -Path (Join-Path $BinDir 'arvaz.cmd') -Encoding ascii -Value "@powershell -NoProfile -ExecutionPolicy Bypass -File `"$Root\arvaz.ps1`" %*"
    $parts = Get-UserPath
    if ($parts -notcontains $BinDir) {
        [Environment]::SetEnvironmentVariable('Path', (@($parts + $BinDir) -join ';'), 'User')
        Write-Host "Added $BinDir to user PATH. Open a new shell."
    }
    else { Write-Host 'Already on user PATH.' }
}

function Uninstall-All {
    Confirm-Action "Remove arvaz containers, CLI shim, PATH entry and $AppHome. Docker data volumes are kept."
    foreach ($n in $Apps.Keys) { Invoke-Compose $n @('down', '--remove-orphans') }
    $parts = @(Get-UserPath | Where-Object { $_ -ne $BinDir })
    [Environment]::SetEnvironmentVariable('Path', ($parts -join ';'), 'User')
    Remove-Item -Recurse -Force $AppHome -ErrorAction SilentlyContinue
    Write-Host 'Uninstalled. Volume arvaz-pgdata kept (remove with: arvaz api rebuild --remove-data=yes).'
}

# Dispatch
try {
    if ($Pos.Count -eq 0) { $Pos = @('help') }
    if ($TopLevel -contains $Pos[0]) {
        switch ($Pos[0]) {
            'help'      { Show-Help }
            'install'   { Install-Shim }
            'uninstall' { Uninstall-All }
            'version'   { Write-Host "arvaz CLI $CliVersion | source $(Get-SourceVersion)" }
        }
        exit 0
    }
    if ($Pos.Count -lt 2) { Fail-Usage 'missing command' }
    if (-not ($Pos[0] -eq 'all' -or $Apps.Contains($Pos[0]))) { Fail-Usage "unknown target '$($Pos[0])'" }
    $names = if ($Pos[0] -eq 'all') { @($Apps.Keys) } else { @($Pos[0]) }
    $cmd = $Pos[1]
    if ($Commands -notcontains $cmd) { Fail-Usage "unknown command '$cmd'" }
    $removeData = [string]($Opt['remove-data']) -eq 'yes'
    if ($Opt.ContainsKey('remove-data') -and $Opt['remove-data'] -notin 'yes', 'no') { Fail-Usage "--remove-data must be yes or no" }

    if ($cmd -ne 'service') { Assert-Docker }
    $rc = 0
    foreach ($n in $names) {
        $code = switch ($cmd) {
            'status'  { Show-Status $n }
            'run'     { Start-App $n }
            'stop'    { Invoke-Compose $n @('stop'); 0 }
            'port'    { if ($Opt.ContainsKey('port')) { Set-Port $n $Opt['port'] } else { Write-Host "$n port: $(Get-Port $n)" }; 0 }
            'rebuild' { Rebuild-App $n $removeData }
            'update'  { Update-App $n }
            'version' { Show-Version $n }
            'service' { Write-Host "${n}: service mode not used (Docker only)"; 2 }
        }
        if ($code -gt $rc) { $rc = $code }
    }
    exit $rc
}
catch {
    Write-Host "error: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}
