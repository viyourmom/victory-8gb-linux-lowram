param(
    [Parameter(Mandatory = $true)]
    [string]$Exe,
    [int]$DropMips = 2,
    [string]$Resolution = "1920x1080",
    [switch]$Borderless
)

$repoRoot = Split-Path -Parent $PSScriptRoot
$victory = Join-Path $repoRoot "target\release\victory.exe"

if (-not (Test-Path $victory)) {
    Write-Error "Release binary not found at $victory. Build it first with: cargo build --release --bin victory"
    exit 1
}

Remove-Item Env:VICTORY_SKIP_PIPELINES, Env:VICTORY_BAKE_TEXTURES_MS, Env:VICTORY_CARD_FETCH_INFLIGHT -ErrorAction SilentlyContinue
Remove-Item Env:VICTORY_LEVELS_ON_DEMAND, Env:VICTORY_REFRESH_ONCE, Env:VICTORY_AMBIENT -ErrorAction SilentlyContinue
Remove-Item Env:VICTORY_VIEW_KNOWN, Env:VICTORY_FRAME_LOG, Env:VICTORY_CARD_METER, Env:VICTORY_PROFILE -ErrorAction SilentlyContinue

if ($Resolution) {
    $env:VICTORY_RESOLUTION = $Resolution
} else {
    Remove-Item Env:VICTORY_RESOLUTION -ErrorAction SilentlyContinue
}
if ($Borderless) {
    $env:VICTORY_BORDERLESS = "1"
} else {
    Remove-Item Env:VICTORY_BORDERLESS -ErrorAction SilentlyContinue
}

$env:VICTORY_ASYNC_SUBMIT = "1"
$env:VICTORY_QUEUE2 = "1"
$env:VICTORY_INDIRECT_WINDOW = "1"
$env:VICTORY_INDIRECT_WINDOW_DRAWS = "1"
$env:VICTORY_INDIRECT_GATHER = "1"
$env:VICTORY_CLAMP_WAITS = "0"
$env:VICTORY_JOIN_PARTS = "1"
$env:VICTORY_BACK_OWN_VIEW = "1"
$env:VICTORY_GUARD_HOLES_FRAME = "1"
$env:VICTORY_HEAP_WORKER = "1"
$env:VICTORY_ALIAS_ONCE = "1"
$env:VICTORY_TEXTURE_NO_WAIT = "1"
$env:VICTORY_COPY_PLAIN = "1"
$env:VICTORY_SKIP_WC_COMPARE = "1"
$env:VICTORY_WIDE_TEXTURES = "1"
$env:VICTORY_TEXTURE_DROP_MIPS = "$DropMips"
$env:VICTORY_DISK_CORES = "slow"
$env:VICTORY_XMEM_PERSISTENT_VIEW = "1"

& $victory run --execute $Exe
