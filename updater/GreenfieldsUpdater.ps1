<#
  Greenfields Updater - keeps the Greenfields WoW addon up to date.

  WoW addons can't update themselves (no file or network access from the game), so this
  small script does it: finds your WoW install, checks the latest release, verifies the
  download's SHA-256 against the release manifest, backs up your current copy and installs
  the new one into every WoW: Forever folder that should have it.

  Usually you just double-click "Update Greenfields.cmd". Options:
    -Check            only report whether an update is available
    -Force            reinstall even if you're up to date
    -Quiet            no prompts or pauses (used by the background schedule)
    -InstallSchedule  check automatically when you log in to Windows and every 6 hours
    -RemoveSchedule   stop the automatic checks
    -WowPath <dir>    your World of Warcraft folder (remembered for next time)
    -ManifestUrl <u>  override the release manifest (testing). Only here, a local file or a
                      http://127.0.0.1 test server is accepted; everything else must be https.

  Exit code: 0 = done / up to date, 1 = something went wrong (details in the log).
  Works with the Windows PowerShell 5.1 that ships with Windows 10/11. Nothing to install.
  Keep this file plain ASCII: Windows PowerShell reads a BOM-less script in the ANSI code page.
#>
[CmdletBinding()]
param(
    [switch]$Check,
    [switch]$Force,
    [switch]$Quiet,
    [switch]$InstallSchedule,
    [switch]$RemoveSchedule,
    [string]$WowPath,
    [string]$ManifestUrl
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$UpdaterVersion = '1.0.1'
$AddonName = 'Greenfields'
$TaskName = 'Greenfields Updater'
$ScriptPath = $MyInvocation.MyCommand.Path
$Here = Split-Path -Parent $ScriptPath
$LocalData = $env:LOCALAPPDATA
if (-not $LocalData) { $LocalData = [Environment]::GetFolderPath('LocalApplicationData') }
$StateDir = Join-Path $LocalData 'GreenfieldsUpdater'
$StateFile = Join-Path $StateDir 'state.json'
$LogFile = Join-Path $StateDir 'update.log'
$BackupDir = Join-Path $StateDir 'backup'
# The schedule runs its own copy from here, so it survives the download folder being moved or deleted
$AppDir = Join-Path $StateDir 'app'
# Flavor folders under the WoW root. The first one always gets the addon; the others are
# only updated when Greenfields is already installed there.
$PrimaryFlavor = '_forever_'
$OtherFlavors = @('_forever_ptr_', '_forever_beta_', '_classic_beta_')
$MaxPackageBytes = 64MB
# Local files and plain-http loopback servers are only for an explicit -ManifestUrl test (set in main)
$AllowLocal = $false
$ManifestIsLocal = $false
$Mutex = $null
$HaveLock = $false
$NotifyOnFail = $false
# The .cmd launchers pause after we exit (so even PowerShell failing to start stays on screen)
$PauseAtEnd = (-not $Quiet) -and (-not $env:GREENFIELDS_UPDATER_CMD)

try { [void][IO.Directory]::CreateDirectory($StateDir) } catch { }
try {
    if ((Test-Path -LiteralPath $LogFile) -and (Get-Item -LiteralPath $LogFile).Length -gt 1MB) {
        Move-Item -LiteralPath $LogFile -Destination (Join-Path $StateDir 'update.old.log') -Force
    }
} catch { }
try {
    # SystemDefault (0) already lets Windows pick TLS 1.2/1.3; older .NET defaults need TLS 1.2 added
    $tls = [Net.ServicePointManager]::SecurityProtocol
    if ([int]$tls -ne 0) { [Net.ServicePointManager]::SecurityProtocol = $tls -bor [Net.SecurityProtocolType]::Tls12 }
} catch { }

# ---------------------------------------------------------------------------- output
function Write-Log([string]$msg) {
    try { Add-Content -LiteralPath $LogFile -Value ("{0}  {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $msg) -Encoding UTF8 } catch { }
}
function Say([string]$msg, [string]$color = 'Gray') {
    Write-Log $msg
    if (-not $Quiet) { Write-Host $msg -ForegroundColor $color }
}
function Unlock-Updater {
    if ($script:HaveLock) {
        try { $script:Mutex.ReleaseMutex() } catch { }
        $script:HaveLock = $false
    }
}
function Finish([int]$code) {
    # let go of the lock first, so a window left open doesn't block the background schedule
    Unlock-Updater
    if ($PauseAtEnd) {
        Write-Host ''
        try { Read-Host 'Press Enter to close' | Out-Null } catch { }
    }
    exit $code
}
function Notify([string]$title, [string]$text) {
    # Quiet (scheduled) runs: a tray balloon so people know an update landed (or needs them)
    if (-not $Quiet) { return }
    try {
        Add-Type -AssemblyName System.Windows.Forms
        Add-Type -AssemblyName System.Drawing
        $n = New-Object System.Windows.Forms.NotifyIcon
        $n.Icon = [System.Drawing.SystemIcons]::Information
        $n.BalloonTipTitle = $title
        $n.BalloonTipText = $text
        $n.Visible = $true
        $n.ShowBalloonTip(8000)
        Start-Sleep -Seconds 9
        $n.Dispose()
    } catch { }
}
function Get-Why($err) {
    # the real reason, without PowerShell's 'Exception calling "Move" with "2" argument(s)' wrapper
    $e = $err
    if ($e -is [Management.Automation.ErrorRecord]) { $e = $e.Exception }
    while ($e.InnerException -and $e -is [Management.Automation.MethodInvocationException]) { $e = $e.InnerException }
    return ([string]$e.Message).Trim()
}
function Test-Denied($err) {
    $e = $err
    if ($e -is [Management.Automation.ErrorRecord]) { $e = $e.Exception }
    while ($e) {
        if ($e -is [UnauthorizedAccessException]) { return $true }
        $e = $e.InnerException
    }
    return ((Get-Why $err) -match 'denied|unauthori')
}

# ---------------------------------------------------------------------------- state
function Get-State {
    try {
        if (Test-Path -LiteralPath $StateFile) {
            $s = [IO.File]::ReadAllText($StateFile) | ConvertFrom-Json
            if ($s -and $s.GetType().FullName -eq 'System.Management.Automation.PSCustomObject') { return $s }
            Write-Log 'state.json was empty or damaged - starting fresh'
        }
    } catch { Write-Log ('state.json was damaged - starting fresh: ' + (Get-Why $_)) }
    return New-Object PSObject
}
function Save-State($state) {
    # write-then-rename, so a crash or power cut never leaves a half-written state.json
    try {
        $tmp = "$StateFile.tmp"
        [IO.File]::WriteAllText($tmp, ($state | ConvertTo-Json -Depth 4), (New-Object Text.UTF8Encoding($false)))
        # [NullString]::Value: a plain $null reaches .NET as "" and Replace() rejects it
        if (Test-Path -LiteralPath $StateFile) { [IO.File]::Replace($tmp, $StateFile, [NullString]::Value) } else { [IO.File]::Move($tmp, $StateFile) }
    } catch { Write-Log ("couldn't save state.json: " + (Get-Why $_)) }
}
function Set-StateValue($state, [string]$name, $value) {
    if ($state.PSObject.Properties[$name]) { $state.$name = $value }
    else { $state | Add-Member -NotePropertyName $name -NotePropertyValue $value }
}

# ---------------------------------------------------------------------------- versions
function ConvertTo-VersionKey([string]$v) {
    # "1.2.3" or "1.2.3-beta" -> comparable number; unknown -> -1
    if ($v -match '^\s*(\d{1,4})\.(\d{1,3})(?:\.(\d{1,3}))?') {
        $patch = 0
        if ($Matches[3]) { $patch = [int]$Matches[3] }
        return ([int]$Matches[1] * 1000000) + ([int]$Matches[2] * 1000) + $patch
    }
    return -1
}
function Test-VersionString([string]$v) {
    return ($v -match '^\d{1,4}\.\d{1,3}(\.\d{1,3})?([-+][0-9A-Za-z.-]+)?$')
}
function Get-TocVersion($lines) {
    foreach ($line in @($lines)) {
        if ($line -match '^\s*##\s*Version:\s*(\S+)') { return $Matches[1] }
    }
    return '0.0.0'
}
function Get-InstalledVersion([string]$addonDir) {
    $toc = Join-Path $addonDir "$AddonName.toc"
    if (-not (Test-Path -LiteralPath $toc -PathType Leaf)) { return $null }
    return (Get-TocVersion (Get-Content -LiteralPath $toc -TotalCount 40))
}
function Get-SafeName([string]$s) {
    # a version string from a local .toc, made safe to use as a folder name
    if (-not $s) { return 'unknown' }
    return ($s -replace '[^0-9A-Za-z._-]', '_')
}
function Get-FlavorName([string]$addonsDir) {
    return (Split-Path -Leaf (Split-Path -Parent (Split-Path -Parent $addonsDir)))
}

# ---------------------------------------------------------------------------- finding WoW
function Test-WowRoot([string]$dir) {
    if (-not $dir) { return $false }
    try {
        if (-not (Test-Path -LiteralPath $dir -PathType Container)) { return $false }
        foreach ($f in @($PrimaryFlavor) + $OtherFlavors + @('_retail_', '_classic_', '_classic_era_')) {
            if (Test-Path -LiteralPath (Join-Path $dir $f) -PathType Container) { return $true }
        }
    } catch { }
    return $false
}
function ConvertTo-WowRoot([string]$dir) {
    # forgive picking _forever_, Interface or AddOns instead of the World of Warcraft folder itself
    if (-not $dir) { return $dir }
    $dir = $dir.Trim().Trim('"').TrimEnd('\', '/')
    for ($i = 0; $i -lt 3 -and $dir; $i++) {
        if (Test-WowRoot $dir) { return $dir }
        if ((Split-Path -Leaf $dir) -match '^(_.+_|Interface|AddOns)$') { $dir = Split-Path -Parent $dir } else { break }
    }
    return $dir
}
function Test-HasForever([string]$root) {
    return ($root -and (Test-Path -LiteralPath (Join-Path $root $PrimaryFlavor) -PathType Container))
}
function Find-WowRoot {
    $candidates = New-Object System.Collections.Generic.List[string]
    $keys = @(
        'HKLM:\SOFTWARE\WOW6432Node\Blizzard Entertainment\World of Warcraft',
        'HKLM:\SOFTWARE\Blizzard Entertainment\World of Warcraft',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\World of Warcraft',
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\World of Warcraft'
    )
    foreach ($k in $keys) {
        try {
            $p = Get-ItemProperty -LiteralPath $k -ErrorAction Stop
            foreach ($field in 'InstallPath', 'InstallLocation', 'GamePath') {
                # InstallPath often points at a flavor folder like ...\_retail_ (ConvertTo-WowRoot walks up)
                if ($p.$field) { $candidates.Add([string]$p.$field) }
            }
        } catch { }
    }
    # fixed disks only: probing a disconnected network drive or empty card reader can hang for ages
    foreach ($drive in [IO.DriveInfo]::GetDrives()) {
        try { if ($drive.DriveType -ne [IO.DriveType]::Fixed -or -not $drive.IsReady) { continue } } catch { continue }
        $r = $drive.RootDirectory.FullName
        foreach ($sub in 'Program Files (x86)\World of Warcraft', 'Program Files\World of Warcraft', 'World of Warcraft',
                         'Games\World of Warcraft', 'Battle.net\World of Warcraft', 'Blizzard\World of Warcraft') {
            $candidates.Add((Join-Path $r $sub))
        }
    }
    $roots = @()
    foreach ($c in $candidates) {
        $c = ConvertTo-WowRoot $c
        if ((Test-WowRoot $c) -and ($roots -notcontains $c)) { $roots += $c }
    }
    # several installs (retail on C:, Forever on D:...): prefer the one that has WoW: Forever
    foreach ($c in $roots) { if (Test-HasForever $c) { return (Get-Item -LiteralPath $c).FullName } }
    if ($roots.Count -gt 0) { return (Get-Item -LiteralPath $roots[0]).FullName }
    return $null
}
function Select-WowRootInteractive {
    if ($Quiet) { return $null }
    Say "Couldn't find WoW: Forever automatically - a window will open: pick your 'World of Warcraft' folder." 'Yellow'
    try {
        Add-Type -AssemblyName System.Windows.Forms
        $owner = New-Object System.Windows.Forms.Form
        $owner.TopMost = $true   # otherwise the picker can open hidden behind this window
        $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
        $dlg.Description = "Select your 'World of Warcraft' folder (the one containing _forever_)"
        $dlg.ShowNewFolderButton = $false
        $ok = $dlg.ShowDialog($owner) -eq [System.Windows.Forms.DialogResult]::OK
        $owner.Dispose()
        if ($ok) {
            $picked = ConvertTo-WowRoot $dlg.SelectedPath
            if (Test-WowRoot $picked) { return $picked }
            Say "That folder doesn't have WoW in it: $($dlg.SelectedPath)" 'Yellow'
        }
    } catch { }
    return $null
}

# ---------------------------------------------------------------------------- downloads
function Test-LocalRef([string]$u) {
    # local drive paths (never UNC shares), and only in an explicit -ManifestUrl test
    if (-not $AllowLocal -or $u -notmatch '^[A-Za-z]:[\\/]') { return $false }
    return (Test-Path -LiteralPath $u -PathType Leaf)
}
function Test-AllowedUri([Uri]$uri) {
    if ($uri.Scheme -eq 'https') { return $true }
    return ($AllowLocal -and $uri.Scheme -eq 'http' -and $uri.IsLoopback)
}
function Test-AllowedUrl([string]$u) {
    if (Test-LocalRef $u) { return $true }
    $uri = $null
    if (-not [Uri]::TryCreate($u, [UriKind]::Absolute, [ref]$uri)) { return $false }
    return (Test-AllowedUri $uri)
}
function Resolve-Ref([string]$ref) {
    # release.py without a base URL writes bare file names: they sit next to the manifest
    if (-not $ref -or $ref -match '^[A-Za-z][A-Za-z0-9+.-]*:' -or $ref.StartsWith('\\') -or $ref.StartsWith('//')) { return $ref }
    if ($ManifestIsLocal) { return (Join-Path (Split-Path -Parent $ManifestUrl) $ref) }
    return (New-Object Uri((New-Object Uri($ManifestUrl)), $ref)).AbsoluteUri
}
function Get-NetProblem($err, [Uri]$uri) {
    $we = $err
    if ($we -is [Management.Automation.ErrorRecord]) { $we = $we.Exception }
    while ($we -and -not ($we -is [Net.WebException])) { $we = $we.InnerException }
    if (-not $we) { return (Get-Why $err) }
    if ([string]$we.Status -in 'TrustFailure', 'SecureChannelFailure') {
        return "Couldn't make a secure connection to $($uri.Host). Check your PC's date and time are right, then try again."
    }
    return "Couldn't reach $($uri.Host) ($($we.Message)). Check your internet connection and try again."
}
function Get-Bytes([string]$u, [long]$maxBytes, [int]$timeoutSec) {
    # Downloads into memory, so there's no file on disk that could change between verifying and
    # installing. Redirects are followed by hand so every hop must be https (GitHub sends release
    # downloads on to objects.githubusercontent.com; Windows PowerShell would happily follow a
    # redirect down to plain http). Returns the raw bytes - Invoke-WebRequest isn't used because
    # Windows PowerShell hands back application/octet-stream (GitHub release assets) as numbers.
    $tooBig = 'The download is bigger than the release says. Nothing was changed - try again later.'
    if (Test-LocalRef $u) {
        $f = Get-Item -LiteralPath $u
        if ($f.Length -gt $maxBytes) { throw $tooBig }
        return , ([IO.File]::ReadAllBytes($f.FullName))
    }
    $uri = New-Object Uri($u)
    for ($hop = 0; $hop -lt 10; $hop++) {
        if (-not (Test-AllowedUri $uri)) { throw "The release server tried to send the download over an insecure ($($uri.Scheme)) connection - refused. Nothing was changed." }
        $req = [Net.WebRequest]::Create($uri)
        $req.AllowAutoRedirect = $false
        $req.UserAgent = "GreenfieldsUpdater/$UpdaterVersion"
        $req.Accept = '*/*'
        $req.Timeout = $timeoutSec * 1000
        $req.ReadWriteTimeout = $timeoutSec * 1000
        $req.CachePolicy = New-Object Net.Cache.RequestCachePolicy([Net.Cache.RequestCacheLevel]::NoCacheNoStore)
        try { if ($req.Proxy) { $req.Proxy.Credentials = [Net.CredentialCache]::DefaultCredentials } } catch { }
        $resp = $null
        try { $resp = $req.GetResponse() }
        catch {
            $we = $_.Exception
            while ($we -and -not ($we -is [Net.WebException])) { $we = $we.InnerException }
            if ($we -and $we.Response) { $resp = $we.Response } else { throw (Get-NetProblem $_ $uri) }
        }
        try {
            $code = [int]$resp.StatusCode
            if ($code -ge 300 -and $code -lt 400) {
                $loc = $resp.GetResponseHeader('Location')
                if (-not $loc) { throw "The release server sent a broken redirect ($($uri.Host)). Try again later." }
                $uri = New-Object Uri($uri, $loc)
                continue
            }
            if ($code -eq 404) { throw "The release file isn't there ($($uri.Host) said 404). If a release was just made, try again in a few minutes." }
            if ($code -ne 200) { throw "The release server had a problem ($($uri.Host) said $code). Try again later." }
            if ($resp.ContentLength -gt $maxBytes) { throw $tooBig }
            $ms = New-Object IO.MemoryStream
            $over = $false
            try {
                $in = $resp.GetResponseStream()
                $buf = New-Object byte[] 65536
                while (($n = $in.Read($buf, 0, $buf.Length)) -gt 0) {
                    $ms.Write($buf, 0, $n)
                    if ($ms.Length -gt $maxBytes) { $over = $true; break }
                }
            } catch { throw (Get-NetProblem $_ $uri) }
            if ($over) { throw $tooBig }
            return , ($ms.ToArray())
        } finally { $resp.Close() }
    }
    throw 'The release server redirected too many times. Try again later.'
}
function Get-Utf8Text([byte[]]$bytes) {
    return ([Text.Encoding]::UTF8.GetString($bytes)).TrimStart([char]0xFEFF)
}
function Assert-Hash([byte[]]$bytes, [string]$expected, [string]$what) {
    if (-not $expected -or $expected -notmatch '^[0-9a-fA-F]{64}$') { throw "The release manifest has no valid SHA-256 for the $what - refusing to install it." }
    $sha = [Security.Cryptography.SHA256]::Create()
    try { $actual = [BitConverter]::ToString($sha.ComputeHash($bytes)) -replace '-', '' } finally { $sha.Dispose() }
    if ($actual -ne $expected) { throw "The downloaded $what doesn't match the release (SHA-256 mismatch). Nothing was changed." }
}

# ---------------------------------------------------------------------------- package + files
function Test-IsLink([string]$path) {
    $item = Get-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
    return [bool]($item -and ($item.Attributes -band [IO.FileAttributes]::ReparsePoint))
}
function Remove-Tree([string]$path) {
    # Deletes a file or folder without ever following a junction/symlink inside it (older Windows
    # PowerShell builds' Remove-Item -Recurse also deletes whatever a link points at).
    $item = Get-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
    if (-not $item) { return }
    $isLink = [bool]($item.Attributes -band [IO.FileAttributes]::ReparsePoint)
    if (-not $isLink -and ($item.Attributes -band [IO.FileAttributes]::ReadOnly)) {
        $item.Attributes = $item.Attributes -band (-bnot [IO.FileAttributes]::ReadOnly)
    }
    if ($item.PSIsContainer) {
        if (-not $isLink) {
            foreach ($child in @(Get-ChildItem -LiteralPath $item.FullName -Force)) { Remove-Tree $child.FullName }
        }
        [IO.Directory]::Delete($item.FullName, $false)
    } else {
        [IO.File]::Delete($item.FullName)
    }
}
function Get-PackageRel($entry) {
    # every entry must sit inside the single top-level Greenfields folder, with a plain relative path
    $name = $entry.FullName -replace '/', '\'
    if (-not $name.StartsWith("$AddonName\", [StringComparison]::OrdinalIgnoreCase)) { throw 'The package has files outside the Greenfields folder. Nothing was changed.' }
    $rel = $name.Substring($AddonName.Length + 1)
    if ($rel.StartsWith('\') -or $rel -match '(^|\\)\.\.(\\|$)' -or $rel -match '[:*?"<>|]' -or
        $rel.IndexOfAny([IO.Path]::GetInvalidPathChars()) -ge 0) {
        throw 'The package has an unsafe file path. Nothing was changed.'
    }
    return $rel
}
function Test-Package($archive) {
    # checks every entry before anything is touched; returns the version in the package's .toc
    $toc = $null
    foreach ($entry in $archive.Entries) {
        $rel = Get-PackageRel $entry
        if ($rel -ieq "$AddonName.toc") { $toc = $entry }
    }
    if (-not $toc) { throw "The package has no $AddonName.toc. Nothing was changed." }
    $reader = New-Object IO.StreamReader($toc.Open(), $true)
    try {
        $lines = @()
        while ($lines.Count -lt 40 -and -not $reader.EndOfStream) { $lines += $reader.ReadLine() }
    } finally { $reader.Dispose() }
    return (Get-TocVersion $lines)
}
function Expand-Package($archive, [string]$destDir) {
    [void][IO.Directory]::CreateDirectory($destDir)
    $root = [IO.Path]::GetFullPath($destDir).TrimEnd('\') + '\'
    foreach ($entry in $archive.Entries) {
        $rel = Get-PackageRel $entry
        if (-not $rel) { continue }
        $target = [IO.Path]::GetFullPath([IO.Path]::Combine($root, $rel))
        # no zip-slip: whatever the entry name, it has to land inside destDir
        if (-not $target.StartsWith($root, [StringComparison]::OrdinalIgnoreCase)) { throw 'The package has an unsafe file path. Nothing was changed.' }
        if ($rel.EndsWith('\')) { [void][IO.Directory]::CreateDirectory($target); continue }
        [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($target))
        [IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $target, $true)
    }
}
function Install-Into([string]$ad, $archive, [string]$latest, [string]$stamp) {
    # Unpack beside the live copy, then swap with two renames in the same folder: WoW never sees a
    # half-copied addon, and if anything is locked or read-only the old copy simply stays put.
    $flavor = Get-FlavorName $ad
    $dest = Join-Path $ad $AddonName
    $id = [guid]::NewGuid().ToString('N').Substring(0, 8)
    $stage = Join-Path $ad "$AddonName.gfupdate-new-$id"
    $old = Join-Path $ad "$AddonName.gfupdate-old-$id"

    # tidy anything an interrupted run left (putting a moved-aside copy back if it never got replaced)
    if (Test-Path -LiteralPath $ad) {
        $left = @(Get-ChildItem -LiteralPath $ad -Force -Filter "$AddonName.gfupdate-*" -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending)
        if (-not (Get-Item -LiteralPath $dest -Force -ErrorAction SilentlyContinue)) {
            $prev = @($left | Where-Object { $_.Name -like "$AddonName.gfupdate-old-*" -and $_.PSIsContainer }) | Select-Object -First 1
            if ($prev) { try { [IO.Directory]::Move($prev.FullName, $dest) } catch { } }
        }
        foreach ($l in $left) { try { Remove-Tree $l.FullName } catch { Write-Log ("couldn't tidy {0}: {1}" -f $l.FullName, (Get-Why $_)) } }
    }

    # back up the current copy (kept in %LOCALAPPDATA% for a manual roll back)
    $hasOld = Test-Path -LiteralPath $dest
    $backup = $null
    if ($hasOld) {
        try {
            $ver = Get-SafeName (Get-InstalledVersion $dest)
            $backup = Join-Path $BackupDir ("{0}\{1}-{2}" -f $flavor, $ver, $stamp)
            for ($n = 2; (Test-Path -LiteralPath $backup); $n++) { $backup = Join-Path $BackupDir ("{0}\{1}-{2}-{3}" -f $flavor, $ver, $stamp, $n) }
            [void][IO.Directory]::CreateDirectory((Split-Path -Parent $backup))
            Copy-Item -LiteralPath $dest -Destination $backup -Recurse -Force
        } catch {
            throw ("Couldn't back up your current Greenfields in {0} ({1}). Nothing was changed." -f $flavor, (Get-Why $_))
        }
    }

    # unpack the verified package
    try {
        [void][IO.Directory]::CreateDirectory($ad)
        Expand-Package $archive $stage
        if ((Get-InstalledVersion $stage) -ne $latest) { throw 'the unpacked copy is incomplete' }
    } catch {
        $why = $_
        try { Remove-Tree $stage } catch { }
        if (Test-Denied $why) {
            throw ("Windows won't let the updater write to {0}. Right-click 'Update Greenfields' and choose 'Run as administrator'. Nothing was changed." -f $ad)
        }
        throw ("Couldn't unpack Greenfields into {0} ({1}). Nothing was changed." -f $flavor, (Get-Why $why))
    }

    # swap
    if ($hasOld) {
        try { [IO.Directory]::Move($dest, $old) }
        catch {
            $why = Get-Why $_
            try { Remove-Tree $stage } catch { }
            throw ("Greenfields in {0} is in use, so it can't be replaced right now ({1}). Close WoW (and anything else that has Greenfields files open), then run Update Greenfields again. Nothing was changed." -f $flavor, $why)
        }
    }
    try { [IO.Directory]::Move($stage, $dest) }
    catch {
        $why = Get-Why $_
        $back = -not $hasOld
        if ($hasOld) { try { [IO.Directory]::Move($old, $dest); $back = $true } catch { } }
        try { Remove-Tree $stage } catch { }
        if ($back) { throw ("Couldn't put the new Greenfields in place in {0} ({1}). Nothing was changed." -f $flavor, $why) }
        throw ("Couldn't put the new Greenfields in place in {0} ({1}). Run Update Greenfields again to finish - your previous copy is safe in {2}." -f $flavor, $why, $old)
    }
    if ((Get-InstalledVersion $dest) -ne $latest) { throw ("The new Greenfields in {0} didn't check out after installing. Run Update Greenfields again." -f $flavor) }
    if ($hasOld) {
        # a file something still has open just means the old copy is tidied next run
        try { Remove-Tree $old } catch { Write-Log ("left {0} to tidy next time: {1}" -f $old, (Get-Why $_)) }
    }
    Say ("  {0,-16} -> {1}" -f $flavor, $latest) 'Green'

    # keep the 3 newest backups per flavor
    $prune = @(Get-ChildItem -LiteralPath (Join-Path $BackupDir $flavor) -Directory -Force -ErrorAction SilentlyContinue |
               Sort-Object CreationTime -Descending | Select-Object -Skip 3)
    foreach ($o in $prune) { try { Remove-Tree $o.FullName } catch { } }
}

# ---------------------------------------------------------------------------- schedule
function Install-Schedule {
    # The task runs a private copy in %LOCALAPPDATA%: it keeps working if this folder is moved,
    # deleted, cleaned out of Downloads, or lives in OneDrive.
    [void][IO.Directory]::CreateDirectory($AppDir)
    $appScript = Join-Path $AppDir 'GreenfieldsUpdater.ps1'
    if ([IO.Path]::GetFullPath($ScriptPath) -ne [IO.Path]::GetFullPath($appScript)) {
        Copy-Item -LiteralPath $ScriptPath -Destination $appScript -Force
        $cfg = Join-Path $Here 'updater.json'
        if (Test-Path -LiteralPath $cfg) { Copy-Item -LiteralPath $cfg -Destination (Join-Path $AppDir 'updater.json') -Force }
    }
    $me = [Security.Principal.WindowsIdentity]::GetCurrent().Name
    $win = $env:SystemRoot
    if (-not $win) { $win = $env:WINDIR }
    $ps = Join-Path $win 'System32\WindowsPowerShell\v1.0\powershell.exe'
    # -File "..." keeps spaces, apostrophes and brackets in the path intact; -NonInteractive means
    # nothing can ever sit waiting for input in the background
    $arg = '-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File "{0}" -Quiet' -f $appScript
    $action = New-ScheduledTaskAction -Execute $ps -Argument $arg -WorkingDirectory $AppDir
    $logon = New-ScheduledTaskTrigger -AtLogOn -User $me
    $logon.Delay = 'PT2M'   # give the network a moment after login
    $every = New-ScheduledTaskTrigger -Once -At ((Get-Date).AddMinutes(5)) -RepetitionInterval (New-TimeSpan -Hours 6) -RepetitionDuration (New-TimeSpan -Days 3650)
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Minutes 10) -MultipleInstances IgnoreNew
    $principal = New-ScheduledTaskPrincipal -UserId $me -LogonType Interactive -RunLevel Limited
    Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger @($logon, $every) -Settings $settings -Principal $principal `
        -Description 'Keeps the Greenfields WoW addon up to date.' -Force | Out-Null
    Say "Automatic updates are ON: checks at Windows login and every 6 hours." 'Green'
    Say "They use a copy of the updater kept in $AppDir, so this folder can be moved or deleted." 'Gray'
}
function Remove-Schedule {
    $task = $null
    try { $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction Stop } catch { }
    if (-not $task) { Say "Automatic updates weren't on." 'Gray'; return }
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
    Say "Automatic updates are OFF." 'Green'
}

# ---------------------------------------------------------------------------- self-update
function Update-Self($manifest) {
    # Returns $true when a newer, hash-verified updater script replaced this one (used next run).
    $u = $manifest.updater
    if (-not $u -or -not $u.version -or -not $u.url) { return $false }
    if (-not (Test-VersionString ([string]$u.version))) { return $false }
    if ((ConvertTo-VersionKey $u.version) -le (ConvertTo-VersionKey $UpdaterVersion)) { return $false }
    $url = Resolve-Ref ([string]$u.url)
    if (-not (Test-AllowedUrl $url)) { Write-Log "self-update skipped: not an https address ($url)"; return $false }
    $new = "$ScriptPath.new"
    try {
        $bytes = Get-Bytes $url 2MB 60
        Assert-Hash $bytes ([string]$u.sha256) 'updater script'
        # read it the way Windows PowerShell will (UTF-8 if it has a BOM, else the ANSI code page)
        # and make sure it parses and really is the promised version - a broken script would
        # strand every guildie on it
        if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
            $text = [Text.Encoding]::UTF8.GetString($bytes, 3, $bytes.Length - 3)
        } else { $text = [Text.Encoding]::Default.GetString($bytes) }
        $tokens = $null; $errors = $null
        [void][Management.Automation.Language.Parser]::ParseInput($text, [ref]$tokens, [ref]$errors)
        if ($errors -and $errors.Count -gt 0) { throw "the new updater script doesn't parse: $($errors[0].Message)" }
        if ($text -notmatch ('\$UpdaterVersion\s*=\s*''{0}''' -f [regex]::Escape([string]$u.version))) { throw "the new updater script isn't version $($u.version)" }
        [IO.File]::WriteAllBytes($new, $bytes)
        # replace in one step, so an interrupted update can't leave a half-written updater
        try { [IO.File]::Replace($new, $ScriptPath, [NullString]::Value) } catch { Move-Item -LiteralPath $new -Destination $ScriptPath -Force }
        Say ("Updater refreshed to {0} (takes effect next run)." -f $u.version) 'Gray'
        return $true
    } catch {
        Write-Log ("self-update skipped: " + (Get-Why $_))
        try { if (Test-Path -LiteralPath $new) { [IO.File]::Delete($new) } } catch { }
        return $false
    }
}

# ============================================================================ main
try {
    $Mutex = New-Object System.Threading.Mutex($false, 'Local\GreenfieldsUpdater')
    try { $HaveLock = $Mutex.WaitOne(0) }
    catch [Threading.AbandonedMutexException] { $HaveLock = $true }   # an earlier run was closed mid-way; the lock is ours now
} catch { $HaveLock = $false }
if (-not $HaveLock) { Say 'Another Greenfields update is already running. Try again in a minute.' 'Yellow'; Finish 0 }

try {
    if (-not $Quiet) {
        Write-Host ''
        Write-Host '  ================================================' -ForegroundColor DarkGreen
        Write-Host '    GREENFIELDS UPDATER        Mandurah  -  WA 6210' -ForegroundColor Green
        Write-Host '  ================================================' -ForegroundColor DarkGreen
        Write-Host ''
    }
    Write-Log ("--- updater {0} started{1}" -f $UpdaterVersion, $(if ($Quiet) { ' (quiet)' } else { '' }))

    if ($RemoveSchedule) { Remove-Schedule; Finish 0 }

    $exitCode = 0
    $state = Get-State

    # -- configuration
    $config = $null
    $configPath = Join-Path $Here 'updater.json'
    if (Test-Path -LiteralPath $configPath) {
        try { $config = Get-Utf8Text ([IO.File]::ReadAllBytes($configPath)) | ConvertFrom-Json }
        catch { throw "updater.json (next to the updater) is damaged. Download GreenfieldsUpdater.zip again from the latest release, or ask your officer." }
    }
    $explicitManifest = $PSBoundParameters.ContainsKey('ManifestUrl')
    if (-not $ManifestUrl) { if ($config -and $config.manifestUrl) { $ManifestUrl = [string]$config.manifestUrl } }
    if (-not $ManifestUrl -or $ManifestUrl -match 'OWNER/REPO') {
        throw "This updater isn't set up yet (no release address in updater.json). Ask your officer for the current updater."
    }
    # local manifests / loopback http are only for testing, and only when passed on the command line
    if ($explicitManifest) {
        if ($ManifestUrl -notmatch '^[A-Za-z][A-Za-z0-9+.-]+://' -and (Test-Path -LiteralPath $ManifestUrl -PathType Leaf)) {
            $ManifestUrl = (Get-Item -LiteralPath $ManifestUrl).FullName
            $AllowLocal = $true
            $ManifestIsLocal = $true
        } elseif ($ManifestUrl -match '^http://(127\.0\.0\.1|localhost|\[::1\])[:/]') {
            $AllowLocal = $true
        }
    }
    if (-not (Test-AllowedUrl $ManifestUrl)) { throw "Release address must be https:// ($ManifestUrl)" }

    # -- WoW folder
    if ($WowPath) {
        $given = $WowPath
        $WowPath = ConvertTo-WowRoot $WowPath
        if (-not (Test-WowRoot $WowPath)) { throw "That doesn't look like a World of Warcraft folder: $given" }
    } elseif ($state.wowPath -and (Test-HasForever ([string]$state.wowPath))) {
        $WowPath = [string]$state.wowPath
    } else {
        $WowPath = Find-WowRoot
        if (-not (Test-HasForever $WowPath)) {
            $picked = Select-WowRootInteractive
            if ($picked) { $WowPath = $picked }
        }
        if (-not $WowPath) { throw "Couldn't find World of Warcraft. Run Update Greenfields again and pick your 'World of Warcraft' folder when asked (see README.txt)." }
    }
    $WowPath = (Get-Item -LiteralPath $WowPath).FullName
    Set-StateValue $state 'wowPath' $WowPath
    Save-State $state
    Say "WoW folder: $WowPath"

    if ($InstallSchedule) {
        try { Install-Schedule }
        catch {
            $exitCode = 1
            Say ("Couldn't turn on automatic updates: " + (Get-Why $_)) 'Red'
            Write-Log ($_ | Out-String)
        }
    }

    # -- targets: _forever_ always; other flavors only where Greenfields already lives
    $targets = @()
    $primary = Join-Path $WowPath $PrimaryFlavor
    if (Test-Path -LiteralPath $primary -PathType Container) { $targets += (Join-Path $primary 'Interface\AddOns') }
    foreach ($f in $OtherFlavors) {
        $ad = Join-Path $WowPath "$f\Interface\AddOns"
        if (Test-Path -LiteralPath (Join-Path $ad $AddonName)) { $targets += $ad }
    }
    if ($targets.Count -eq 0) { throw "No WoW: Forever install found under $WowPath (expected a $PrimaryFlavor folder). Install/launch Forever once first." }

    # -- what's out there
    Say 'Checking for the latest release...'
    $manifest = $null
    $raw = Get-Bytes $ManifestUrl 1MB 30
    try { $manifest = (Get-Utf8Text $raw) | ConvertFrom-Json } catch { }
    if (-not $manifest -or $manifest.GetType().FullName -ne 'System.Management.Automation.PSCustomObject') {
        throw "The release info didn't come through properly (it isn't a Greenfields release manifest). Try again later."
    }
    if (-not $manifest.version -or -not $manifest.url) { throw 'The release manifest is missing version/url.' }
    if ($manifest.name -and $manifest.name -ne $AddonName) { throw "The release manifest is for '$($manifest.name)', not $AddonName." }
    $latest = [string]$manifest.version
    if (-not (Test-VersionString $latest)) { throw "The release manifest has an odd version number ('$latest')." }
    $latestKey = ConvertTo-VersionKey $latest
    $packageUrl = Resolve-Ref ([string]$manifest.url)
    if (-not (Test-AllowedUrl $packageUrl)) { throw "Release download must be https:// ($packageUrl)" }
    $minUpdater = [string]$manifest.minUpdater
    if ((Test-VersionString $minUpdater) -and (ConvertTo-VersionKey $minUpdater) -gt (ConvertTo-VersionKey $UpdaterVersion)) {
        if (Update-Self $manifest) { throw "This release needs a newer updater, and the updater has just refreshed itself. Run Update Greenfields again." }
        throw "This release needs a newer updater ($minUpdater) and it couldn't refresh itself. Download GreenfieldsUpdater.zip from the latest release (or ask your officer)."
    }
    [void](Update-Self $manifest)

    # -- who needs it
    $stale = @()
    $linked = 0
    foreach ($ad in $targets) {
        $flavor = Get-FlavorName $ad
        if (Test-IsLink (Join-Path $ad $AddonName)) {
            # a developer's junction/symlink to their working copy: never overwrite that
            Say ("  {0,-16} linked to another folder (developer copy) - left alone" -f $flavor) 'Yellow'
            $linked++
            continue
        }
        $cur = Get-InstalledVersion (Join-Path $ad $AddonName)
        $label = if ($cur) { $cur } else { 'not installed' }
        Say ("  {0,-16} {1}" -f $flavor, $label)
        $curKey = ConvertTo-VersionKey $cur
        # a pre-release (1.2.0-beta) also moves on to its final release (1.2.0)
        $preToFinal = ($curKey -eq $latestKey -and $cur -match '-' -and $latest -notmatch '-')
        if ($Force -or -not $cur -or $curKey -lt $latestKey -or $preToFinal) { $stale += $ad }
    }
    Say ("Latest release: {0}" -f $latest) 'Cyan'
    if ($stale.Count -eq 0) {
        if ($linked -gt 0) { Say 'Nothing else to update.' 'Green' }
        else { Say "You're up to date. Nah yeah, she'll be right." 'Green' }
        Finish $exitCode
    }
    if ($Check) {
        Say ("Update available: {0}. Run Update Greenfields to install it." -f $latest) 'Yellow'
        Finish $exitCode
    }

    # -- download + verify (all in memory: the bytes that were verified are the bytes installed)
    Say ("Downloading Greenfields {0}..." -f $latest)
    $max = $MaxPackageBytes
    if ($manifest.size) { $max = [long]$manifest.size }
    $bytes = Get-Bytes $packageUrl $max 120
    if ($manifest.size -and $bytes.Length -ne [long]$manifest.size) { throw 'The download is the wrong size. Nothing was changed - try again later.' }
    Assert-Hash $bytes ([string]$manifest.sha256) 'addon package'
    Say 'Download verified (SHA-256 matches the release).' 'Green'

    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $wowRunning = @(Get-Process -Name 'Wow*' -ErrorAction SilentlyContinue).Count -gt 0
    $zipStream = New-Object IO.MemoryStream -ArgumentList (, $bytes)
    $archive = New-Object IO.Compression.ZipArchive -ArgumentList $zipStream, ([IO.Compression.ZipArchiveMode]::Read)
    try {
        $pkgVersion = Test-Package $archive
        if ($pkgVersion -ne $latest) { throw "The package says it's $pkgVersion but the release says $latest. Nothing was changed." }

        # -- install (backup first; the live copy is only swapped once the new one is fully unpacked)
        $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
        $NotifyOnFail = $true
        foreach ($ad in $stale) { Install-Into $ad $archive $latest $stamp }
        $NotifyOnFail = $false
    } finally {
        $archive.Dispose()
        $zipStream.Dispose()
    }

    Set-StateValue $state 'lastInstalled' $latest
    Save-State $state
    if ($manifest.notes) {
        Say ''
        Say "What's new in $($latest):" 'Cyan'
        foreach ($n in @($manifest.notes)) { Say "  - $n" }
    }
    Say ''
    if ($wowRunning) {
        Say 'WoW is running: type /reload in game to load the new version (restart WoW if anything looks missing).' 'Yellow'
    } else {
        Say 'Done. It loads next time you start WoW.' 'Green'
    }
    Notify 'Greenfields updated' ("Greenfields {0} installed. /reload in game to load it." -f $latest)
    Finish $exitCode
} catch {
    Say ("Problem: " + (Get-Why $_)) 'Red'
    Say ("If this keeps happening, send your officer the log: $LogFile") 'Gray'
    Write-Log ($_ | Out-String)
    if ($NotifyOnFail) { Notify "Greenfields didn't update" 'Double-click Update Greenfields to see why.' }
    Finish 1
} finally {
    Unlock-Updater
}
