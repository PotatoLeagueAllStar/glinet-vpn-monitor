# manage.ps1 — Windows management menu for GL.iNet WireGuard Monitor
# Run from PowerShell: .\manage.ps1
# Requires: OpenSSH (built into Windows 10/11) or Git Bash on PATH

param(
    [string]$RouterIP   = "",
    [string]$SSHKeyPath = ""
)

$ErrorActionPreference = "Stop"

# ── Resolve script directory ──────────────────────────────────────────────────
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

# ── Load saved settings (if present) ─────────────────────────────────────────
$SettingsFile = Join-Path $ScriptDir ".router-settings.ps1"
if (Test-Path $SettingsFile) {
    . $SettingsFile
}

# ── Prompt for missing settings ───────────────────────────────────────────────
function Get-RouterSettings {
    if (-not $script:RouterIP) {
        $script:RouterIP = Read-Host "  Router IP address (e.g. 192.168.8.1)"
    }
    if (-not $script:SSHKeyPath) {
        $default = "$env:USERPROFILE\.ssh\glinet_key"
        $input   = Read-Host "  SSH private key path [default: $default]"
        $script:SSHKeyPath = if ($input) { $input } else { $default }
    }
}

function Save-RouterSettings {
    @"
`$script:RouterIP   = '$($script:RouterIP)'
`$script:SSHKeyPath = '$($script:SSHKeyPath)'
"@ | Set-Content $SettingsFile
    Write-Host "  Settings saved to .router-settings.ps1" -ForegroundColor DarkGray
}

# ── SSH helper ────────────────────────────────────────────────────────────────
function Invoke-SSH {
    param([string]$RemoteCmd)
    ssh -o StrictHostKeyChecking=accept-new -i $script:SSHKeyPath "root@$($script:RouterIP)" $RemoteCmd
}

function Send-FileToRouter {
    param([string]$LocalFile, [string]$RemotePath)
    Get-Content $LocalFile -Raw | ssh -o StrictHostKeyChecking=accept-new `
        -i $script:SSHKeyPath "root@$($script:RouterIP)" "cat > $RemotePath"
}

# ── Colour helpers ────────────────────────────────────────────────────────────
function Write-Header {
    param([string]$Text)
    Write-Host ""
    Write-Host "═══════════════════════════════════════════" -ForegroundColor Cyan
    Write-Host "  $Text" -ForegroundColor Cyan
    Write-Host "═══════════════════════════════════════════" -ForegroundColor Cyan
}

function Write-Step {
    param([string]$Text)
    Write-Host "==> $Text" -ForegroundColor Yellow
}

function Write-OK {
    param([string]$Text)
    Write-Host "  [OK] $Text" -ForegroundColor Green
}

function Write-Err {
    param([string]$Text)
    Write-Host "  [ERROR] $Text" -ForegroundColor Red
}

# ══════════════════════════════════════════════════════════════════════════════
#  ACTIONS
# ══════════════════════════════════════════════════════════════════════════════

function Deploy-All {
    Write-Header "Full Deploy"
    Get-RouterSettings

    Write-Step "Creating /etc/vpn-monitor on router..."
    Invoke-SSH "mkdir -p /etc/vpn-monitor /tmp/vpn-monitor"

    $configFile = Join-Path $ScriptDir "config"
    if (-not (Test-Path $configFile)) {
        Write-Err "config file not found. Copy config.example to config and fill in your values."
        return
    }

    Write-Step "Uploading config..."
    Send-FileToRouter $configFile "/etc/vpn-monitor/config"
    Invoke-SSH "chmod 600 /etc/vpn-monitor/config"

    Write-Step "Uploading check-vpn.sh..."
    Send-FileToRouter (Join-Path $ScriptDir "check-vpn.sh") "/etc/vpn-monitor/check-vpn.sh"

    Write-Step "Uploading netflow-monitor.sh..."
    Send-FileToRouter (Join-Path $ScriptDir "netflow-monitor.sh") "/etc/vpn-monitor/netflow-monitor.sh"

    Write-Step "Uploading maintenance.sh..."
    Send-FileToRouter (Join-Path $ScriptDir "maintenance.sh") "/etc/vpn-monitor/maintenance.sh"

    Write-Step "Setting permissions and registering cron jobs..."
    Invoke-SSH @'
chmod +x /etc/vpn-monitor/check-vpn.sh /etc/vpn-monitor/netflow-monitor.sh /etc/vpn-monitor/maintenance.sh

sysctl -w net.netfilter.nf_conntrack_acct=1 > /dev/null 2>&1

if [ ! -f /etc/sysctl.d/10-conntrack-acct.conf ]; then
  echo "net.netfilter.nf_conntrack_acct=1" > /etc/sysctl.d/10-conntrack-acct.conf
fi

if ! crontab -l 2>/dev/null | grep -q "check-vpn.sh"; then
  (crontab -l 2>/dev/null; echo "* * * * * /bin/sh /etc/vpn-monitor/check-vpn.sh") | crontab -
  echo "  check-vpn cron added."
fi

if ! crontab -l 2>/dev/null | grep -q "netflow-monitor.sh"; then
  (crontab -l 2>/dev/null; echo "*/5 * * * * /bin/sh /etc/vpn-monitor/netflow-monitor.sh") | crontab -
  echo "  netflow cron added."
fi

if ! crontab -l 2>/dev/null | grep -q "maintenance.sh start"; then
  (crontab -l 2>/dev/null; echo "55 2 * * 1,4 /bin/sh /etc/vpn-monitor/maintenance.sh start") | crontab -
fi
if ! crontab -l 2>/dev/null | grep -q "maintenance.sh stop"; then
  (crontab -l 2>/dev/null; echo "15 3 * * 1,4 /bin/sh /etc/vpn-monitor/maintenance.sh stop") | crontab -
fi

echo "--- Current crontab ---"
crontab -l
'@

    Write-Step "Installing boot-time resume script..."
    Invoke-SSH @'
cat > /etc/init.d/vpn-monitor-resume << 'EOF'
#!/bin/sh /etc/rc.common
START=99
start() {
    sleep 30
    /bin/sh /etc/vpn-monitor/maintenance.sh stop
}
EOF
chmod +x /etc/init.d/vpn-monitor-resume
/etc/init.d/vpn-monitor-resume enable
echo "  Boot-time resume script installed."
'@

    Write-Step "Running check-vpn.sh once to verify..."
    Invoke-SSH "/bin/sh /etc/vpn-monitor/check-vpn.sh && echo 'Script ran OK.'"

    Write-OK "Deploy complete. Watch healthchecks.io — tunnels should turn green within 2 minutes."
}

function Update-Config {
    Write-Header "Update Config Only"
    Get-RouterSettings

    $configFile = Join-Path $ScriptDir "config"
    if (-not (Test-Path $configFile)) {
        Write-Err "config file not found. Copy config.example to config and fill in your values."
        return
    }

    Write-Step "Uploading updated config..."
    Send-FileToRouter $configFile "/etc/vpn-monitor/config"
    Invoke-SSH "chmod 600 /etc/vpn-monitor/config"

    Write-Step "Running script to verify..."
    Invoke-SSH "/bin/sh /etc/vpn-monitor/check-vpn.sh && echo 'Script ran OK.'"

    Write-OK "Config updated. Check healthchecks.io dashboard."
}

function Start-Maintenance {
    Write-Header "Pause Monitoring (Maintenance Start)"
    Get-RouterSettings
    Write-Step "Pausing all healthchecks.io tunnel monitors..."
    Invoke-SSH "/bin/sh /etc/vpn-monitor/maintenance.sh start"
    Write-OK "Monitors paused. Run 'End Maintenance' when done."
}

function Stop-Maintenance {
    Write-Header "Resume Monitoring (Maintenance End)"
    Get-RouterSettings
    Write-Step "Resuming all healthchecks.io tunnel monitors..."
    Invoke-SSH "/bin/sh /etc/vpn-monitor/maintenance.sh stop"
    Write-OK "Monitors resumed."
}

function Invoke-Backup {
    Write-Header "Router Backup"
    Get-RouterSettings

    $USB_MOUNT  = "/tmp/mountd/disk1_part1"
    $REMOTE_DIR = "$USB_MOUNT/router-backups"
    $TIMESTAMP  = Get-Date -Format "yyyyMMdd_HHmmss"
    $REMOTE_FILE = "$REMOTE_DIR/router-backup-$TIMESTAMP.tar.gz"
    $LOCAL_Dir  = Join-Path $ScriptDir "backups"
    $LOCAL_FILE = Join-Path $Local_Dir "router-backup-$TIMESTAMP.tar.gz"

    if (-not (Test-Path $Local_Dir)) { New-Item -ItemType Directory $Local_Dir | Out-Null }

    Write-Step "Ensuring /etc/vpn-monitor is in sysupgrade.conf..."
    Invoke-SSH @"
if ! grep -q 'vpn-monitor' /etc/sysupgrade.conf 2>/dev/null; then
  echo '/etc/vpn-monitor/' >> /etc/sysupgrade.conf
  echo '  sysupgrade.conf updated.'
fi
"@

    Write-Step "Checking USB drive..."
    $mounted = Invoke-SSH "grep -q '$USB_MOUNT' /proc/mounts && echo yes || echo no"
    if ($mounted.Trim() -ne "yes") {
        Write-Err "USB drive not found at $USB_MOUNT — is it plugged in?"
        return
    }
    Invoke-SSH "mkdir -p '$REMOTE_DIR'"

    Write-Step "Creating backup on router USB drive..."
    Invoke-SSH "sysupgrade -b '$REMOTE_FILE'"

    Write-Step "Downloading backup to local machine..."
    $bytes = Invoke-SSH "cat '$REMOTE_FILE'"
    # Write raw bytes via ssh to avoid text encoding issues
    ssh -o StrictHostKeyChecking=accept-new -i $script:SSHKeyPath `
        "root@$($script:RouterIP)" "cat '$REMOTE_FILE'" | Set-Content $LOCAL_FILE -AsByteStream

    # Prune old local backups (keep last 14)
    Get-ChildItem $Local_Dir -Filter "router-backup-*.tar.gz" |
        Sort-Object LastWriteTime -Descending |
        Select-Object -Skip 14 |
        Remove-Item -Force

    Write-OK "Backup saved to: $LOCAL_FILE"
    $count = (Get-ChildItem $Local_Dir -Filter "router-backup-*.tar.gz").Count
    Write-Host "  Local backups on disk: $count" -ForegroundColor DarkGray
}

function Invoke-Diagnose {
    Write-Header "Diagnose"
    Get-RouterSettings

    Write-Step "Checking WireGuard status on router..."
    Invoke-SSH @'
echo "=== WireGuard interfaces ==="
wg show
echo ""
echo "=== Latest handshakes per interface ==="
for iface in wgclient1 wgclient2 wgclient3 wgclient4 wgclient5; do
  echo "--- $iface ---"
  wg show "$iface" latest-handshakes 2>&1
done
echo ""
echo "=== Current time (epoch) ==="
date +%s
echo ""
echo "=== Crontab ==="
crontab -l
'@
}

function Test-GrafanaPush {
    Write-Header "Test Grafana Push"
    Get-RouterSettings

    Write-Step "Copying debug-push.sh to router and running it..."
    Send-FileToRouter (Join-Path $ScriptDir "debug-push.sh") "/tmp/debug-push.sh"
    Invoke-SSH "sh /tmp/debug-push.sh"
}

function Set-RouterCredentials {
    Write-Header "Update Router Settings"
    $script:RouterIP   = Read-Host "  Router IP address"
    $script:SSHKeyPath = Read-Host "  SSH private key path"
    Save-RouterSettings
}

function New-ConfigFromTemplate {
    Write-Header "Create config from template"
    $configFile   = Join-Path $ScriptDir "config"
    $exampleFile  = Join-Path $ScriptDir "config.example"

    if (Test-Path $configFile) {
        $overwrite = Read-Host "  config already exists. Overwrite? (y/N)"
        if ($overwrite -ne "y") { return }
    }

    Copy-Item $exampleFile $configFile
    Write-OK "config created. Opening in Notepad — fill in your values and save."
    Start-Process notepad $configFile -Wait
    Write-OK "config saved. Run 'Full Deploy' or 'Update Config' when ready."
}

# ══════════════════════════════════════════════════════════════════════════════
#  MAIN MENU
# ══════════════════════════════════════════════════════════════════════════════

function Show-Menu {
    Clear-Host
    Write-Host ""
    Write-Host "  ╔══════════════════════════════════════════╗" -ForegroundColor Cyan
    Write-Host "  ║   GL.iNet WireGuard Monitor — Manager   ║" -ForegroundColor Cyan
    Write-Host "  ╚══════════════════════════════════════════╝" -ForegroundColor Cyan
    Write-Host ""

    if ($script:RouterIP) {
        Write-Host "  Router: $($script:RouterIP)   Key: $($script:SSHKeyPath)" -ForegroundColor DarkGray
    } else {
        Write-Host "  Router: (not configured)" -ForegroundColor DarkGray
    }

    Write-Host ""
    Write-Host "  ── Deploy ──────────────────────────────────" -ForegroundColor DarkYellow
    Write-Host "  [1] Full deploy (first-time setup)"
    Write-Host "  [2] Update config only"
    Write-Host "  [3] Create config from template"
    Write-Host ""
    Write-Host "  ── Operations ──────────────────────────────" -ForegroundColor DarkYellow
    Write-Host "  [4] Pause monitoring  (maintenance start)"
    Write-Host "  [5] Resume monitoring (maintenance end)"
    Write-Host "  [6] Backup router config"
    Write-Host ""
    Write-Host "  ── Diagnostics ─────────────────────────────" -ForegroundColor DarkYellow
    Write-Host "  [7] Diagnose tunnels"
    Write-Host "  [8] Test Grafana Cloud push"
    Write-Host ""
    Write-Host "  ── Settings ────────────────────────────────" -ForegroundColor DarkYellow
    Write-Host "  [9] Change router IP / SSH key"
    Write-Host "  [Q] Quit"
    Write-Host ""
}

# ── Entry point ───────────────────────────────────────────────────────────────
if ($RouterIP)   { $script:RouterIP   = $RouterIP }
if ($SSHKeyPath) { $script:SSHKeyPath = $SSHKeyPath }

while ($true) {
    Show-Menu
    $choice = Read-Host "  Select"
    switch ($choice.ToUpper()) {
        "1" { Deploy-All }
        "2" { Update-Config }
        "3" { New-ConfigFromTemplate }
        "4" { Start-Maintenance }
        "5" { Stop-Maintenance }
        "6" { Invoke-Backup }
        "7" { Invoke-Diagnose }
        "8" { Test-GrafanaPush }
        "9" { Set-RouterCredentials }
        "Q" { Write-Host ""; exit 0 }
        default { Write-Host "  Invalid option." -ForegroundColor Red }
    }
    if ($choice.ToUpper() -ne "Q") {
        Write-Host ""
        Read-Host "  Press Enter to return to menu"
    }
}
