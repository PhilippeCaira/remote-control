# ============================================================================
# windows-setup.ps1 — configure a Windows VM to connect to the
# support.internal test stack.
#
# Run this AS ADMINISTRATOR in the VM win11, in a PowerShell window.
# The script is idempotent — safe to re-run.
#
# Inputs expected:
#   - This script itself.
#   - caddy-local-ca.crt                      (Caddy local CA, PEM)
#   - SupportInternal-windows-x64-*.msi       (MSI installer from CI)
# All three should be placed in the SAME directory before running.
# ============================================================================

$ErrorActionPreference = 'Stop'

# -- IP of the Debian server VM on the LAN (macvtap bridge) ------------------
$SRV_IP = '192.168.0.54'

# Locate script directory — the CA and MSI must sit next to this file
$here = Split-Path -Parent $MyInvocation.MyCommand.Path

Write-Host "=== 1/4 Ajout des entrees hosts vers $SRV_IP ==="
$hostsFile = 'C:\Windows\System32\drivers\etc\hosts'
$marker = '# BEGIN remote-control-supportint'
$content = Get-Content $hostsFile -Raw
if ($content -notmatch [regex]::Escape($marker)) {
    $block = @"

$marker
$SRV_IP rdv.support.internal
$SRV_IP api.support.internal
$SRV_IP dl.support.internal
# END remote-control-supportint
"@
    Add-Content -Path $hostsFile -Value $block
    Write-Host "  -> entrees ajoutees"
} else {
    Write-Host "  -> deja present, skip"
}
ipconfig /flushdns | Out-Null

Write-Host ""
Write-Host "=== 2/4 Import CA Caddy dans LocalMachine\Root ==="
$caPath = Join-Path $here 'caddy-local-ca.crt'
if (-not (Test-Path $caPath)) { throw "CA introuvable: $caPath" }
$cert = Import-Certificate -FilePath $caPath -CertStoreLocation Cert:\LocalMachine\Root
Write-Host "  -> thumbprint: $($cert.Thumbprint)"
Write-Host "  -> subject:    $($cert.Subject)"

Write-Host ""
Write-Host "=== 3/4 Test resolution + TLS vers api.support.internal ==="
try {
    $r = Invoke-WebRequest -Uri 'https://api.support.internal/api/version' -UseBasicParsing -TimeoutSec 10
    Write-Host "  -> HTTP $($r.StatusCode)  body: $($r.Content.Trim())"
} catch {
    Write-Host "  -> ECHEC: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "     verifier que la VM serveur est allumee et que le LAN est joignable."
}

Write-Host ""
Write-Host "=== 4/4 Installation du MSI SupportInternal ==="
$msi = Get-ChildItem -Path $here -Filter 'SupportInternal-windows-x64-*.msi' | Select-Object -First 1
if (-not $msi) {
    Write-Host "  -> aucun MSI trouve a cote de ce script; skip l'installation." -ForegroundColor Yellow
    Write-Host "     deposer SupportInternal-windows-x64-*.msi dans: $here"
    return
}
Unblock-File -Path $msi.FullName
Write-Host "  -> installation de $($msi.Name) (msiexec /qn)..."
$proc = Start-Process msiexec.exe -Wait -PassThru -ArgumentList @(
    '/i', ('"' + $msi.FullName + '"'),
    '/qn',
    '/l*v', ('"' + (Join-Path $here 'msi-install.log') + '"')
)
if ($proc.ExitCode -ne 0) {
    Write-Host "  -> msiexec exit code: $($proc.ExitCode)" -ForegroundColor Red
    Write-Host "     voir msi-install.log" -ForegroundColor Yellow
} else {
    Write-Host "  -> MSI installe (exit 0)"
}

Write-Host ""
Write-Host "============================================================================"
Write-Host "  Pret. Ouvrir Edge -> https://api.support.internal/_admin/"
Write-Host "  Admin initial : admin / i96XmtfY  (a changer au 1er login)"
Write-Host "  Client : menu Demarrer -> SupportInternal"
Write-Host "============================================================================"
