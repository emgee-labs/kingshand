#Requires -Version 7.0
Set-StrictMode -Version Latest

# Prepares a directory so Claude Code can run in it unattended.
#
# This module exists because herdr cannot pass arguments to claude on Windows. `claude --bg` took
# `--permission-mode bypassPermissions --add-dir <briefdir>` on the command line; herdr's
# equivalent (`agent start ... -- <args>`) launches through Start-Process against a .ps1 and
# fails with "%1 is not a valid Win32 application". So both grants have to be in place on disk
# before the agent starts, and a worker whose directory was not prepared will stop at the first
# permission prompt with nobody there to answer it.
#
# Everything here is a grant. Each one is written where the user can read it back, and each is
# scoped to a single worktree that kingshand created itself from a repo the King registered -
# never to the machine. The one exception to "never the repo" is a worker the King asked to run in
# the project's own checkout, and the section near the end of this file owns how that grant is
# made and taken back.

# Nested imports, WITHOUT -Force - `statute`'s style rules own why. Stop-CheckoutWorker is the only
# caller of either: it stops the worker through Herdr.psm1 and drops the record's index line
# through Index.psm1.
Import-Module (Join-Path $PSScriptRoot 'Herdr.psm1')
Import-Module (Join-Path $PSScriptRoot 'Index.psm1')

# The two grants that used to be command-line flags, written into the worktree.
#
#   defaultMode: bypassPermissions   was --permission-mode bypassPermissions
#   additionalDirectories: [...]     was --add-dir <briefdir>
#
#   hooks.PermissionRequest          the folder-edit grant, never a flag - see below
#
# It must be written INTO THE WORKTREE, not the repo. A worktree is a fresh checkout with no
# .claude directory of its own, and settings.local.json is untracked, so nothing carries across
# from the main checkout.
#
# THE defaultMode GRANT NO LONGER TAKES EFFECT FROM THIS FILE. Claude Code's permission-modes
# documentation: "If you set bypassPermissions in [.claude/settings.json or
# .claude/settings.local.json], it doesn't take effect ... and the session starts in Manual mode."
# It is honoured only from user, --settings or managed settings - the machine, or a command line
# herdr cannot pass. It stays written because a Claude Code that still honours it gets the full
# grant from it. A worker therefore runs in Manual mode, where the user's own allow rules carry
# ordinary edits and a write under .claude\ - a protected path no allow rule pre-approves - stops on
# a menu. The third grant below, the folder-edit hook, is what answers that menu.
function Set-WorkerWorkspaceSettings {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$WorktreePath,
        [string[]]$AdditionalDirectories = @()
    )

    if (-not (Test-Path -LiteralPath $WorktreePath)) {
        throw "Worktree not found, so its settings cannot be written: $WorktreePath"
    }

    $claudeDir = Join-Path $WorktreePath '.claude'
    if (-not (Test-Path -LiteralPath $claudeDir)) {
        New-Item -ItemType Directory -Force -Path $claudeDir | Out-Null
    }

    $settings = [ordered]@{
        permissions = [ordered]@{
            defaultMode           = 'bypassPermissions'
            additionalDirectories = @($AdditionalDirectories)
        }
        hooks       = [ordered]@{
            PermissionRequest = @(New-ClaudeFolderEditHook -ClaudeDir $claudeDir)
        }
    }

    $target = Join-Path $claudeDir 'settings.local.json'
    $settings | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $target -Encoding utf8
    $target
}

# ---------------------------------------------------------------------------------------------
# The folder-edit grant: edits to files under one directory's own .claude folder, with no menu.
#
# Claude Code protects .claude\ from writes in every mode but bypassPermissions, and settings
# allow rules do not pre-approve it - the safety check runs before them. What it documents for a
# session that cannot answer a prompt is a PermissionRequest hook: it runs when Claude Code is
# about to ask, and a decision of "allow" grants the call. So the grant is a hook in the same
# settings.local.json, and the hook's decision is Resolve-WorkerClaudeFolderEdit below.
#
# THE SCOPE IS ONE DIRECTORY. The hook is written with the absolute path of the .claude folder it
# belongs to, and approves only a file tool whose target resolves under that folder - never the
# machine-wide ~\.claude, never another repository. Anything else gets no decision from it, which
# leaves Claude Code's own flow exactly as it was.
# ---------------------------------------------------------------------------------------------

# The file tools whose target is one path. Bash and PowerShell are not here: a shell command names
# its targets in free text, and approving one would mean parsing that.
$script:FolderEditTools = @{ Edit = 'file_path'; MultiEdit = 'file_path'; Write = 'file_path'; NotebookEdit = 'notebook_path' }

# The one file under .claude\ the grant never covers: the file that holds the grants. A worker that
# could rewrite it could widen its own permissions, so that edit is left to the menu.
$script:FolderEditExcludedLeaf = 'settings.local.json'

# The matcher group for one .claude folder, as settings.json's hooks.PermissionRequest takes it.
# Exec form - `args` present, so no shell parses the line - running this module from the
# installation it was loaded from, with the folder's absolute path written in.
function New-ClaudeFolderEditHook {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ClaudeDir)

    $exe    = Join-Path $PSHOME ($IsWindows ? 'pwsh.exe' : 'pwsh')
    $module = Join-Path $PSScriptRoot 'ClaudeWorkspace.psm1'
    $dir    = [IO.Path]::GetFullPath($ClaudeDir)
    $quote  = { param($s) "'" + ($s -replace "'", "''") + "'" }
    $script = "Import-Module $(& $quote $module); " +
              "Resolve-WorkerClaudeFolderEdit -ClaudeDir $(& $quote $dir) " +
              "-InputJson ([Console]::In.ReadToEnd())"

    [ordered]@{
        matcher = (@($script:FolderEditTools.Keys | Sort-Object) -join '|')
        hooks   = @(
            [ordered]@{
                type    = 'command'
                command = $exe
                args    = @('-NoProfile', '-NonInteractive', '-Command', $script)
                timeout = 30
            }
        )
    }
}

# The hook's decision. Reads the PermissionRequest input Claude Code sends on stdin and returns the
# allow decision as JSON, or nothing at all. NOTHING is never a denial - it is no decision, and the
# request then goes on exactly as it would with no hook. Every way of returning nothing writes its
# reason to stderr, so a menu that still appears says why.
function Resolve-WorkerClaudeFolderEdit {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ClaudeDir,
        [AllowEmptyString()][Parameter(Mandatory)][string]$InputJson
    )

    $none = { param($why) [Console]::Error.WriteLine("kingshand folder-edit grant: no decision - $why") }

    try { $in = $InputJson | ConvertFrom-Json -ErrorAction Stop }
    catch { & $none 'the request could not be read as JSON'; return }
    if ($in -isnot [pscustomobject]) { & $none 'the request is not a JSON object'; return }
    $fields = @($in.PSObject.Properties | ForEach-Object Name)
    if ($fields -notcontains 'tool_name' -or $fields -notcontains 'tool_input') {
        & $none 'the request names no tool'; return
    }

    $tool = "$($in.tool_name)"
    if (-not $script:FolderEditTools.ContainsKey($tool)) { & $none "$tool is not a file tool"; return }
    $key = $script:FolderEditTools[$tool]
    if ($in.tool_input -isnot [pscustomobject] -or @($in.tool_input.PSObject.Properties | ForEach-Object Name) -notcontains $key) {
        & $none "the $tool request has no $key"; return
    }
    $target = "$($in.tool_input.$key)"
    if (-not [IO.Path]::IsPathRooted($target)) { & $none "$target is not an absolute path"; return }

    $cmp  = $IsWindows ? [StringComparison]::OrdinalIgnoreCase : [StringComparison]::Ordinal
    $sep  = [IO.Path]::DirectorySeparatorChar
    $root = [IO.Path]::GetFullPath($ClaudeDir).TrimEnd('\', '/')
    $full = [IO.Path]::GetFullPath($target)
    if (-not $full.StartsWith($root + $sep, $cmp)) { & $none "$full is outside $root"; return }
    if ($full.Equals((Join-Path $root $script:FolderEditExcludedLeaf), $cmp)) {
        & $none "$full holds the grants themselves"; return
    }

    # A link anywhere from the folder down to the file would let a path that reads as inside land
    # outside, so every existing step on the way is checked.
    $step = $full
    while ($true) {
        if (Test-Path -LiteralPath $step) {
            $item = Get-Item -LiteralPath $step -Force
            if ($item.LinkType) { & $none "$step is a link"; return }
        }
        if ($step.Equals($root, $cmp)) { break }
        $step = [IO.Path]::GetDirectoryName($step)
        if (-not $step) { & $none "$full did not resolve under $root"; return }
    }

    [ordered]@{
        hookSpecificOutput = [ordered]@{
            hookEventName = 'PermissionRequest'
            decision      = [ordered]@{ behavior = 'allow' }
        }
    } | ConvertTo-Json -Depth 5 -Compress
}

# Records that one worktree path is trusted, so an unattended worker does not stop on Claude
# Code's folder-trust dialog.
#
# `claude --bg --worktree` never met this dialog - it spawned inside an already-trusted session
# and the worktree never got an entry of its own. Confirmed: no worktree-shaped key exists in a
# ~\.claude.json with 41 projects in it. Under herdr the worker is a fresh launch in a directory
# Claude Code has never seen, so it stops and asks, and herdr reports agent_not_ready while the
# agent sits blocked.
#
# The alternative was to let dispatch answer the dialog with a synthetic keystroke. This is
# preferred because it is a written, inspectable record made before launch rather than a blind
# key sent at a security prompt, and because it cannot race. It is still a real grant, so it is
# deliberately narrow: exactly the worktree kingshand just created, never its parent repo.
#
# THE FILE IS EDITED THROUGH JsonNode, NOT ConvertFrom-Json -AsHashtable. A real ~\.claude.json
# seen in the wild contained the same directory twice under 'D:/code' and 'd:/code'. PowerShell hashtables
# are case-insensitive, so an -AsHashtable round trip merges those two keys and writes back a
# file with one of them silently gone - it would destroy a user's project history to save four
# lines. Plain ConvertFrom-Json refuses outright with "keys with different casing", which is the
# same hazard announcing itself.
function Grant-ClaudeFolderTrust {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [string]$ConfigPath
    )

    if (-not $ConfigPath) { $ConfigPath = Join-Path $env:USERPROFILE '.claude.json' }
    if (-not (Test-Path -LiteralPath $ConfigPath)) {
        # No config yet means Claude Code has never run here. Writing a trust file on its behalf
        # would be guessing at a schema we have not seen, so leave it: the worker will stop at
        # the dialog and dispatch reports that plainly.
        return [pscustomobject]@{ granted = $false; reason = 'no-config'; key = $null }
    }

    # Keys are stored with forward slashes and the drive letter preserved.
    $key = ($Path -replace '\\', '/').TrimEnd('/')

    $text = Get-Content -LiteralPath $ConfigPath -Raw
    $root = [System.Text.Json.Nodes.JsonNode]::Parse($text)
    if (-not $root['projects']) {
        return [pscustomobject]@{ granted = $false; reason = 'no-projects'; key = $key }
    }

    $before = $root['projects'].Count
    if ($root['projects'][$key]) {
        return [pscustomobject]@{ granted = $true; reason = 'already'; key = $key }
    }

    $root['projects'][$key] = [System.Text.Json.Nodes.JsonNode]::Parse('{"hasTrustDialogAccepted":true}')

    $opts = [System.Text.Json.JsonSerializerOptions]::new()
    $opts.WriteIndented = $true

    # Written through a temp file and moved into place. This is the user's own Claude Code
    # config; a partial write from an interrupted dispatch would take their whole project list
    # with it.
    $tmp = "$ConfigPath.kingshand-tmp"
    [IO.File]::WriteAllText($tmp, $root.ToJsonString($opts))

    $check = [System.Text.Json.Nodes.JsonNode]::Parse([IO.File]::ReadAllText($tmp))
    if ($check['projects'].Count -ne ($before + 1)) {
        Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
        throw ("Refusing to write $ConfigPath - project count would go from $before to " +
               "$($check['projects'].Count) instead of $($before + 1). Nothing was changed.")
    }

    Move-Item -LiteralPath $tmp -Destination $ConfigPath -Force
    [pscustomobject]@{ granted = $true; reason = 'written'; key = $key }
}

# ---------------------------------------------------------------------------------------------
# A worker in the project's OWN checkout, with no worktree: the `fief` skill's warm worker.
#
# The grants are the same three, and the difference is whose file they land in. A worktree is a
# fresh checkout kingshand made, so its settings.local.json is kingshand's to write whole. A checkout
# is the King's, and its settings.local.json may already hold his own `allow` list and anything else
# he put there. So the file is EDITED rather than written - every key he had survives, the grants
# are set on top - and it is put back exactly as it was when the worker is cleaned up.
#
# FOUR THINGS WENT WRONG WHEN THIS WAS DONE BY HAND, and each is a mechanism here now:
#
#   - The original was not kept. The record below holds the file's exact bytes, taken before the
#     first write, so restoring is a byte copy rather than a reconstruction.
#   - Afterwards nobody could tell whether there had been a file at all. The record says so, and a
#     file that did not exist before is DELETED at cleanup rather than restored as an empty one.
#   - The allow list was dropped. The file is parsed as JSON through JsonNode and only the grant keys
#     are touched, so `allow` and everything else are carried across untouched.
#   - A failed read was built from. `$orig.permissions.allow` on a Get-Content that threw produced
#     `allow: [null]`, which Claude Code meets with a settings-warning prompt the worker then sits
#     blocked on. Here a file that is there and cannot be read, or is not a JSON object, REFUSES -
#     nothing is written from an answer that was never obtained.
#
# The record lives beside the brief, at <briefdir>\checkout-settings.json, never in the checkout,
# where it would be one more untracked file in somebody's working tree.
# ---------------------------------------------------------------------------------------------

$script:CheckoutRecordLeaf = 'checkout-settings.json'

function Get-CheckoutSettingsRecordPath {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$BriefDirectory)
    Join-Path $BriefDirectory $script:CheckoutRecordLeaf
}

# Everything the write will need, worked out WITHOUT writing anything. The dispatcher calls this
# before it creates a single file, so a settings file it cannot honour costs the caller a message
# and nothing else - the same discipline as every other refusal there.
function New-CheckoutSettingsPlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$CheckoutPath,
        [Parameter(Mandatory)][string]$RecordPath,
        [string[]]$AdditionalDirectories = @()
    )

    if (-not (Test-Path -LiteralPath $CheckoutPath -PathType Container)) {
        throw "Checkout not found, so its settings cannot be prepared: $CheckoutPath"
    }
    $claudeDir    = Join-Path $CheckoutPath '.claude'
    $settingsPath = Join-Path $claudeDir 'settings.local.json'

    # The record is the only copy of what the file held before, so it is never overwritten. One
    # already there means an earlier no-worktree worker was never cleaned up, and the settings file
    # on disk is THAT worker's edit - recording it now as "the original" would make the King's real
    # original unrecoverable.
    if (Test-Path -LiteralPath $RecordPath) {
        throw ("A permission-file record already exists at $RecordPath, so an earlier worker in " +
               "this checkout was never cleaned up and $settingsPath still holds its grants. That " +
               "record is the only copy of what the file held before, and it is not overwritten. " +
               "Clean that worker up with Stop-CheckoutWorker first. Nothing was changed.")
    }

    $existed = Test-Path -LiteralPath $settingsPath
    $bytes   = $null
    $root    = $null
    if ($existed) {
        if (Test-Path -LiteralPath $settingsPath -PathType Container) {
            throw "$settingsPath is a directory, so there is no settings file to edit. Nothing was changed."
        }
        try { $bytes = [System.IO.File]::ReadAllBytes($settingsPath) }
        catch {
            throw ("$settingsPath exists and could not be read ($($_.Exception.Message)). Nothing is " +
                   "built from a read that failed - that is how a worker ends up blocked on a " +
                   "settings warning. Fix the file or move it aside. Nothing was changed.")
        }
        $text = [System.Text.Encoding]::UTF8.GetString($bytes).TrimStart([char]0xFEFF)
        $docOptions = [System.Text.Json.JsonDocumentOptions]::new()
        $docOptions.CommentHandling     = [System.Text.Json.JsonCommentHandling]::Skip
        $docOptions.AllowTrailingCommas = $true
        try { $root = [System.Text.Json.Nodes.JsonNode]::Parse($text, $null, $docOptions) }
        catch {
            throw ("$settingsPath is not valid JSON ($($_.Exception.Message)), so the grants cannot " +
                   "be added without losing what it holds. Fix the file or move it aside. " +
                   "Nothing was changed.")
        }
        if ($root -isnot [System.Text.Json.Nodes.JsonObject]) {
            throw ("$settingsPath does not hold a JSON object, so the grants have nowhere to go. " +
                   "Nothing was changed.")
        }
    } else {
        $root = [System.Text.Json.Nodes.JsonObject]::new()
    }

    $perms = $root['permissions']
    if ($null -eq $perms) {
        $perms = [System.Text.Json.Nodes.JsonObject]::new()
        $root['permissions'] = $perms
    } elseif ($perms -isnot [System.Text.Json.Nodes.JsonObject]) {
        throw "$settingsPath has a 'permissions' value that is not an object. Nothing was changed."
    }
    $perms['defaultMode'] = [System.Text.Json.Nodes.JsonValue]::Create('bypassPermissions')

    $dirs = $perms['additionalDirectories']
    if ($null -eq $dirs) {
        $dirs = [System.Text.Json.Nodes.JsonArray]::new()
        $perms['additionalDirectories'] = $dirs
    } elseif ($dirs -isnot [System.Text.Json.Nodes.JsonArray]) {
        throw ("$settingsPath has an 'additionalDirectories' value that is not a list. " +
               "Nothing was changed.")
    }
    $have = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($n in $dirs) {
        if ($null -ne $n -and $n.GetValueKind() -eq [System.Text.Json.JsonValueKind]::String) {
            $null = $have.Add($n.GetValue[string]())
        }
    }
    foreach ($d in @($AdditionalDirectories | Where-Object { $_ })) {
        if ($have.Add($d)) { $dirs.Add([System.Text.Json.Nodes.JsonNode][System.Text.Json.Nodes.JsonValue]::Create($d)) }
    }

    # The folder-edit grant, scoped to this checkout's own .claude folder and appended beside any
    # hook the King already has. The restore is a byte copy of the original, so it goes with the rest.
    $hooks = $root['hooks']
    if ($null -eq $hooks) {
        $hooks = [System.Text.Json.Nodes.JsonObject]::new()
        $root['hooks'] = $hooks
    } elseif ($hooks -isnot [System.Text.Json.Nodes.JsonObject]) {
        throw "$settingsPath has a 'hooks' value that is not an object. Nothing was changed."
    }
    $requests = $hooks['PermissionRequest']
    if ($null -eq $requests) {
        $requests = [System.Text.Json.Nodes.JsonArray]::new()
        $hooks['PermissionRequest'] = $requests
    } elseif ($requests -isnot [System.Text.Json.Nodes.JsonArray]) {
        throw ("$settingsPath has a 'hooks.PermissionRequest' value that is not a list. " +
               "Nothing was changed.")
    }
    $group = New-ClaudeFolderEditHook -ClaudeDir $claudeDir | ConvertTo-Json -Depth 10
    $requests.Add([System.Text.Json.Nodes.JsonNode]::Parse($group))

    $opts = [System.Text.Json.JsonSerializerOptions]::new()
    $opts.WriteIndented = $true

    [pscustomobject]@{
        checkoutPath     = $CheckoutPath
        settingsPath     = $settingsPath
        recordPath       = $RecordPath
        existed          = $existed
        claudeDirExisted = (Test-Path -LiteralPath $claudeDir -PathType Container)
        original         = if ($existed) { [Convert]::ToBase64String($bytes) } else { $null }
        content          = $root.ToJsonString($opts)
    }
}

# Carries out a plan. The RECORD IS WRITTEN FIRST and with CreateNew, so the settings file is never
# changed while nothing holds its original, and two dispatches racing for one record cannot both
# believe they own it - the second one's open fails.
function Set-CheckoutWorkerSettings {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Plan)

    $record = [ordered]@{
        settingsPath     = $Plan.settingsPath
        existed          = [bool]$Plan.existed
        claudeDirCreated = -not [bool]$Plan.claudeDirExisted
        original         = $Plan.original
    } | ConvertTo-Json -Depth 3

    $recordDir = Split-Path -Parent $Plan.recordPath
    if ($recordDir -and -not (Test-Path -LiteralPath $recordDir)) {
        New-Item -ItemType Directory -Force -Path $recordDir | Out-Null
    }
    try {
        $fs = [System.IO.File]::Open($Plan.recordPath, 'CreateNew', 'Write', 'None')
        try {
            $buf = [System.Text.Encoding]::UTF8.GetBytes($record)
            $fs.Write($buf, 0, $buf.Length)
        } finally { $fs.Dispose() }
    } catch {
        throw ("The permission-file record at $($Plan.recordPath) could not be created " +
               "($($_.Exception.Message)), so $($Plan.settingsPath) was not touched.")
    }

    $claudeDir = Split-Path -Parent $Plan.settingsPath
    if (-not (Test-Path -LiteralPath $claudeDir)) {
        New-Item -ItemType Directory -Force -Path $claudeDir | Out-Null
    }
    [System.IO.File]::WriteAllText($Plan.settingsPath, $Plan.content)
    $Plan.settingsPath
}

# Reads a record back, refusing anything it cannot stand behind. A record that is missing, will not
# parse, or names something other than a settings.local.json under a .claude directory is refused
# by name: guessing at "there was probably no file" would delete the King's settings, and a record
# naming some other file would let a cleanup delete a file it never wrote.
function Read-CheckoutSettingsRecord {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RecordPath)

    if (-not (Test-Path -LiteralPath $RecordPath -PathType Leaf)) {
        throw ("There is no permission-file record at $RecordPath, so nothing says whether the " +
               "checkout had a settings file before this worker. Nothing was changed - restore " +
               "it by hand from what you know.")
    }
    try { $r = Get-Content -LiteralPath $RecordPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop }
    catch {
        throw ("The permission-file record at $RecordPath could not be read " +
               "($($_.Exception.Message)). Nothing was changed.")
    }
    $names = @($r.PSObject.Properties.Name)
    foreach ($k in 'settingsPath', 'existed', 'claudeDirCreated', 'original') {
        if ($names -notcontains $k) {
            throw "The permission-file record at $RecordPath has no '$k'. Nothing was changed."
        }
    }
    if ($r.existed -isnot [bool] -or $r.claudeDirCreated -isnot [bool]) {
        throw "The permission-file record at $RecordPath does not say plainly whether a file existed. Nothing was changed."
    }
    $sp = "$($r.settingsPath)"
    if ((Split-Path $sp -Leaf) -ne 'settings.local.json' -or
        (Split-Path (Split-Path $sp -Parent) -Leaf) -ne '.claude') {
        throw ("The permission-file record at $RecordPath names $sp, which is not a " +
               ".claude\settings.local.json. Nothing was changed.")
    }
    $bytes = $null
    if ($r.existed) {
        try { $bytes = [Convert]::FromBase64String("$($r.original)") }
        catch {
            throw ("The permission-file record at $RecordPath says a file existed and its copy of " +
                   "that file is unreadable. Nothing was changed.")
        }
    }
    [pscustomobject]@{
        recordPath       = $RecordPath
        settingsPath     = $sp
        existed          = $r.existed
        claudeDirCreated = $r.claudeDirCreated
        original         = $bytes
    }
}

# Puts the checkout's settings file back the way the record says it was, then removes the record.
function Restore-CheckoutWorkerSettings {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RecordPath)

    $r = Read-CheckoutSettingsRecord -RecordPath $RecordPath
    if ($r.existed) {
        [System.IO.File]::WriteAllBytes($r.settingsPath, $r.original)
        $action = 'restored'
    } else {
        if (Test-Path -LiteralPath $r.settingsPath -PathType Leaf) {
            Remove-Item -LiteralPath $r.settingsPath -Force
        }
        # Only a directory this worker's dispatch created, and only while it is empty - anything
        # else in it is somebody else's.
        $claudeDir = Split-Path -Parent $r.settingsPath
        if ($r.claudeDirCreated -and (Test-Path -LiteralPath $claudeDir -PathType Container) -and
            @(Get-ChildItem -LiteralPath $claudeDir -Force).Count -eq 0) {
            Remove-Item -LiteralPath $claudeDir -Force
        }
        $action = 'deleted'
    }
    Remove-Item -LiteralPath $RecordPath -Force
    [pscustomobject]@{ settingsPath = $r.settingsPath; action = $action }
}

# ---------------------------------------------------------------------------------------------
# What was uncommitted in the checkout before the session's first dispatch.
#
# A session's fixes stay uncommitted until the King says commit, so a worker relaunched mid-session
# finds its own earlier fixes in `git status` beside the King's. The baseline is git's listing taken
# at the FIRST dispatch and kept beside the brief, never in the checkout: on a re-dispatch of the
# same worker on the same branch, only what it lists is the King's, and everything else uncommitted
# is the session's own. Cleanup keeps it, because the session is not over; only -EndSession on
# Stop-CheckoutWorker removes it. One left by a different first dispatch is refused, not reused.
# ---------------------------------------------------------------------------------------------

$script:CheckoutBaselineLeaf = 'checkout-baseline.json'

function Get-CheckoutBaselinePath {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$BriefDirectory)
    Join-Path $BriefDirectory $script:CheckoutBaselineLeaf
}

# Splits what is uncommitted now into the King's and the session's, WITHOUT writing anything. A
# porcelain line is matched to the baseline on its path, so a file whose status letters moved is
# still the one that was there before.
function New-CheckoutBaselinePlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$BriefDirectory,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$CheckoutPath,
        [Parameter(Mandatory)][string]$Branch,
        [AllowEmptyCollection()][string[]]$Dirty = @()
    )

    $path    = Get-CheckoutBaselinePath -BriefDirectory $BriefDirectory
    $dirty   = @($Dirty | Where-Object { $_ })
    $outside = [IO.Path]::GetFullPath($CheckoutPath).TrimEnd('\')
    if (-not (Test-Path -LiteralPath $path)) {
        return [pscustomobject]@{
            path = $path; exists = $false; name = $Name; checkout = $outside; branch = $Branch
            baseline = $dirty; notYours = $dirty; session = @()
        }
    }

    try { $b = Get-Content -LiteralPath $path -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop }
    catch {
        throw ("The checkout baseline at $path could not be read ($($_.Exception.Message)), so " +
               "nothing says which uncommitted files are the King's. Nothing was changed.")
    }
    $names = @($b.PSObject.Properties.Name)
    foreach ($k in 'worker', 'checkout', 'branch', 'dirty') {
        if ($names -notcontains $k) { throw "The checkout baseline at $path has no '$k'. Nothing was changed." }
    }
    $same = "$($b.worker)" -ceq $Name -and "$($b.branch)" -ceq $Branch -and
            "$($b.checkout)".TrimEnd('\').Equals($outside, [System.StringComparison]::OrdinalIgnoreCase)
    if (-not $same) {
        throw ("The checkout baseline at $path belongs to worker $($b.worker) on $($b.branch) in " +
               "$($b.checkout), a different first dispatch, so it says nothing about this one. If " +
               "that session is over, end it with Stop-CheckoutWorker -EndSession. Nothing was changed.")
    }

    $baseline = @(@($b.dirty) | Where-Object { $_ } | ForEach-Object { "$_" })
    $keys = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    foreach ($l in $baseline) { if ($l.Length -gt 3) { $null = $keys.Add($l.Substring(3)) } }
    [pscustomobject]@{
        path = $path; exists = $true; name = $Name; checkout = $outside; branch = $Branch
        baseline = $baseline
        notYours = @($dirty | Where-Object { $_.Length -gt 3 -and $keys.Contains($_.Substring(3)) })
        session  = @($dirty | Where-Object { -not ($_.Length -gt 3 -and $keys.Contains($_.Substring(3))) })
    }
}

# Writes the baseline at the first dispatch, with CreateNew, and does nothing on a re-dispatch.
function Set-CheckoutBaseline {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Plan)

    if ($Plan.exists) { return $false }
    $json = [ordered]@{
        worker = $Plan.name; checkout = $Plan.checkout; branch = $Plan.branch; dirty = @($Plan.baseline)
    } | ConvertTo-Json -Depth 3
    $dir = Split-Path -Parent $Plan.path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    $fs = [System.IO.File]::Open($Plan.path, 'CreateNew', 'Write', 'None')
    try {
        $buf = [System.Text.Encoding]::UTF8.GetBytes($json)
        $fs.Write($buf, 0, $buf.Length)
    } finally { $fs.Dispose() }
    $true
}

# Cleanup for a worker in the project's own checkout. `muster` Step 8b points here rather than
# carrying a second copy of the procedure.
#
# THREE THINGS IN THIS ORDER, and two it never does. Stop the worker, discard its pane, put the
# settings file back. It NEVER deletes the branch and NEVER removes the checkout: there is no
# worktree, the checkout is the King's own working tree, and the branch is where the work lives.
#
# The record is read BEFORE anything is stopped, so a record that cannot be stood behind stops the
# cleanup at the start instead of half way. A worker that does not stop leaves the settings alone:
# it is still running under them.
#
# The baseline beside the record is KEPT, because a cleanup mid-session is followed by a relaunch
# that needs it. -EndSession, at the session's end, removes it too.
function Stop-CheckoutWorker {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$RecordPath,
        # The data root whose index lists the record. Index.psm1's own default unless a caller
        # points it elsewhere, which is what lets a test drive this without the real installation.
        [string]$DataPath = '',
        [switch]$EndSession
    )

    $null = Read-CheckoutSettingsRecord -RecordPath $RecordPath

    $stop = Stop-HerdrAgent -Name $Name
    if (-not $stop.stopped) {
        throw ("Worker $Name did not stop, so its pane and the checkout's settings file were left " +
               "exactly as they are - it is still running under those grants. Nothing else was changed.")
    }
    $paneRemoved = $false
    if ($stop.paneId) { $null = Remove-HerdrPane -PaneId $stop.paneId; $paneRemoved = $true }

    $restored = Restore-CheckoutWorkerSettings -RecordPath $RecordPath

    # The record was indexed when dispatch wrote it, so its line goes with it. A failure here is
    # drift the next digest reports, never a reason to call the cleanup failed.
    $dropped = @($RecordPath)
    $baseline = Get-CheckoutBaselinePath -BriefDirectory (Split-Path -Parent $RecordPath)
    $baselineRemoved = $false
    if ($EndSession -and (Test-Path -LiteralPath $baseline -PathType Leaf)) {
        Remove-Item -LiteralPath $baseline -Force
        $baselineRemoved = $true
        $dropped += $baseline
    }
    foreach ($p in $dropped) {
        try {
            if ($DataPath) { $null = Remove-IndexEntry -Path $p -DataPath $DataPath }
            else           { $null = Remove-IndexEntry -Path $p }
        } catch {
            Write-Warning "The index line for $p could not be dropped ($($_.Exception.Message))."
        }
    }

    [pscustomobject]@{
        stopped         = $true
        paneRemoved     = $paneRemoved
        settings        = $restored.action
        settingsPath    = $restored.settingsPath
        baselineRemoved = $baselineRemoved
    }
}

Export-ModuleMember -Function Set-WorkerWorkspaceSettings, Grant-ClaudeFolderTrust,
                              Resolve-WorkerClaudeFolderEdit,
                              Get-CheckoutSettingsRecordPath, New-CheckoutSettingsPlan,
                              Set-CheckoutWorkerSettings, Read-CheckoutSettingsRecord,
                              Restore-CheckoutWorkerSettings, Stop-CheckoutWorker,
                              Get-CheckoutBaselinePath, New-CheckoutBaselinePlan, Set-CheckoutBaseline
