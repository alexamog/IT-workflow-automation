<#
    Shared console look-and-feel for every Desk Side tool.

    This is deliberately its OWN small file, with no other dependencies, so both
    the main toolkit (via lib\Common.ps1, which dot-sources this) and the Jira
    console (which dot-sources it directly) share exactly one style. Change a
    colour or a box character here and every menu and header changes together.
#>

# One place for the colours. Change these and the whole toolkit re-themes.
$Global:ADToolTheme = @{
    Border  = 'DarkCyan'   # boxes and rules
    Title   = 'Cyan'       # the name inside a banner
    Heading = 'Cyan'       # section headings
    Key     = 'White'      # the number/letter you press
    Label   = 'Gray'       # the menu text
    Hint    = 'DarkGray'   # secondary notes and prompts
    Width   = 54           # default banner width
}

# Box-drawing characters are built from their code points, NOT typed as glyphs,
# so this file stays plain ASCII and works no matter how it is saved or copied.
# They only render on a UTF-8 console, so ask for one here (harmless, and reset
# when the shell ends).
$Global:ADToolBox = @{
    H  = [char]0x2500; V = [char]0x2502
    TL = [char]0x256D; TR = [char]0x256E; BL = [char]0x2570; BR = [char]0x256F
}
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

# Pastel colours (the sign-off quote uses these) are 24-bit, which the 16 named
# console colours cannot do. That needs "virtual terminal" mode switched on.
# Windows Terminal has it on already; older console windows need this nudge.
# If it cannot be turned on (or output is being captured to a file), the flag
# stays false and the quote falls back to an ordinary colour - never garbage.
$Global:ADToolTrueColor = $false
try {
    if (-not ('DeskSideConsole.Vt' -as [type])) {
        Add-Type -Namespace DeskSideConsole -Name Vt -ErrorAction Stop -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("kernel32.dll", SetLastError=true)] public static extern System.IntPtr GetStdHandle(int nStdHandle);
[System.Runtime.InteropServices.DllImport("kernel32.dll", SetLastError=true)] public static extern bool GetConsoleMode(System.IntPtr hConsoleHandle, out uint lpMode);
[System.Runtime.InteropServices.DllImport("kernel32.dll", SetLastError=true)] public static extern bool SetConsoleMode(System.IntPtr hConsoleHandle, uint dwMode);
'@
    }
    $stdout = [DeskSideConsole.Vt]::GetStdHandle(-11)   # STD_OUTPUT_HANDLE
    $mode   = [uint32]0
    if ([DeskSideConsole.Vt]::GetConsoleMode($stdout, [ref]$mode)) {
        # 0x0004 = ENABLE_VIRTUAL_TERMINAL_PROCESSING
        if ([DeskSideConsole.Vt]::SetConsoleMode($stdout, $mode -bor 0x0004)) { $Global:ADToolTrueColor = $true }
    }
} catch { $Global:ADToolTrueColor = $false }

# Soft pastel colours (R,G,B). One is chosen at random for each sign-off quote,
# so the colour is different (almost) every time you exit a tool.
$Global:ADToolPastels = @(
    @(255, 179, 186),  # pink
    @(255, 205, 178),  # peach
    @(255, 234, 179),  # butter
    @(198, 246, 213),  # mint
    @(186, 225, 255),  # sky
    @(215, 196, 255),  # lavender
    @(255, 198, 236),  # blossom
    @(191, 244, 235),  # aqua
    @(214, 232, 180),  # sage
    @(230, 204, 255),  # lilac
    @(179, 224, 255)   # baby blue
)

# A centred title inside a rounded box. Pass one or more lines.
#   Write-ToolBanner 'Desk Side Toolkit'
function Write-ToolBanner {
    param(
        [Parameter(Mandatory)][string[]]$Lines,
        [int]$Width = $Global:ADToolTheme.Width
    )
    $b = $Global:ADToolBox
    # Grow the box if a line is wider than the default.
    $longest = ($Lines | Measure-Object -Property Length -Maximum).Maximum
    $inner   = [Math]::Max($Width - 2, $longest + 4)

    $bar = [string]$b.H * $inner
    Write-Host ''
    Write-Host ("{0}{1}{2}" -f $b.TL, $bar, $b.TR) -ForegroundColor $Global:ADToolTheme.Border
    foreach ($line in $Lines) {
        $pad = $inner - $line.Length
        $l   = [int][Math]::Floor($pad / 2)
        $r   = $pad - $l
        Write-Host ([string]$b.V) -ForegroundColor $Global:ADToolTheme.Border -NoNewline
        Write-Host ((' ' * $l) + $line + (' ' * $r)) -ForegroundColor $Global:ADToolTheme.Title -NoNewline
        Write-Host ([string]$b.V) -ForegroundColor $Global:ADToolTheme.Border
    }
    Write-Host ("{0}{1}{2}" -f $b.BL, $bar, $b.BR) -ForegroundColor $Global:ADToolTheme.Border
}

# A section heading with a trailing rule. Renders like:  -- Accounts --------
function Write-ToolHeader {
    param([Parameter(Mandatory)][string]$Text, [int]$Width = $Global:ADToolTheme.Width)
    $h    = [string]$Global:ADToolBox.H
    $lead = "$h$h $Text "
    $fill = [Math]::Max(0, $Width - $lead.Length)
    Write-Host ''
    Write-Host ($lead + ($h * $fill)) -ForegroundColor $Global:ADToolTheme.Heading
}

# One menu row:  "   1  Reset a user's password        (extra note)"
# $Key is what the user types (a number or a letter like B). -Disabled dims the
# whole row (used for options the signed-in account is not allowed to run).
function Write-ToolMenuItem {
    param(
        [Parameter(Mandatory)][string]$Key,
        [Parameter(Mandatory)][string]$Label,
        [string]$Note,
        [switch]$Disabled
    )
    if ($Disabled) {
        Write-Host ("  {0,3}  {1}" -f $Key, $Label) -ForegroundColor $Global:ADToolTheme.Hint -NoNewline
        if ($Note) { Write-Host "   $Note" -ForegroundColor $Global:ADToolTheme.Hint -NoNewline }
        Write-Host ''
        return
    }
    Write-Host ("  {0,3}  " -f $Key) -ForegroundColor $Global:ADToolTheme.Key -NoNewline
    Write-Host $Label -ForegroundColor $Global:ADToolTheme.Label -NoNewline
    if ($Note) { Write-Host "   $Note" -ForegroundColor $Global:ADToolTheme.Hint -NoNewline }
    Write-Host ''
}

# Wrap text onto lines no wider than $Width, breaking on spaces.
function ConvertTo-WrappedLines {
    param([Parameter(Mandatory)][string]$Text, [int]$Width = 66)
    $out = New-Object System.Collections.Generic.List[string]
    $cur = ''
    foreach ($word in ($Text -split '\s+' | Where-Object { $_ -ne '' })) {
        if     ($cur -eq '')                              { $cur = $word }
        elseif (($cur.Length + 1 + $word.Length) -le $Width) { $cur = "$cur $word" }
        else   { $out.Add($cur); $cur = $word }
    }
    if ($cur -ne '') { $out.Add($cur) }
    $out.ToArray()
}

# --- Sign-off quote ----------------------------------------------------------
# The send-off shown when you exit a tool: clear the screen, then place one
# random quote (from lib\Quotes.psd1, the single place they live) in the middle
# of the window, framed and in a random pastel colour. Both the main toolkit and
# the Jira console call this, so the quotes AND their look live in one place.
function Show-DeskSideSignoff {
    $path = Join-Path $PSScriptRoot 'Quotes.psd1'
    if (-not (Test-Path $path)) { return }          # no quotes file - exit quietly
    try { $quotes = @((Import-PowerShellDataFile -Path $path).Quotes) } catch { return }
    if ($quotes.Count -eq 0) { return }

    # A quote is a plain string. (Older files used @{ Text = ... }; still honour
    # that so an out-of-date edition doesn't break.)
    $pick = $quotes[(Get-Random -Maximum $quotes.Count)]
    $text = if ($pick -is [string]) { $pick } else { [string]$pick.Text }
    if (-not $text) { return }

    # Window size, with sensible fallbacks when it can't be read (redirected).
    $width = 80; $height = 25
    try { if ([Console]::WindowWidth  -gt 0) { $width  = [Console]::WindowWidth  } } catch { }
    try { if ([Console]::WindowHeight -gt 0) { $height = [Console]::WindowHeight } } catch { }

    # Clear to a blank screen for the send-off - but not when output is being
    # captured (tests / piping into a file), where clearing makes no sense.
    $interactive = $false
    try { $interactive = -not [Console]::IsOutputRedirected } catch { }
    if ($interactive) { try { Clear-Host } catch { $interactive = $false } }

    # Wrap the quote to a comfortable column, and frame it with a slim rule the
    # width of the widest line.
    $wrapW  = [Math]::Max(20, [Math]::Min(66, $width - 8))
    $lines  = @(ConvertTo-WrappedLines -Text $text -Width $wrapW)
    $frameW = [int](($lines | Measure-Object -Property Length -Maximum).Maximum)
    $rule   = [string]$Global:ADToolBox.H * $frameW

    # One pastel for the whole quote.
    $rgb   = $Global:ADToolPastels[(Get-Random -Maximum $Global:ADToolPastels.Count)]
    $named = @('White', 'Cyan', 'Green', 'Yellow', 'Magenta', 'Gray')[(Get-Random -Maximum 6)]
    $esc   = [char]27
    $useTrue = [bool]$Global:ADToolTrueColor

    # Centre one line in the window, colouring it pastel (or, for the frame, dim).
    $emit = {
        param([string]$Str, [switch]$Dim)
        $left   = [Math]::Max(0, [int](($width - $Str.Length) / 2))
        $prefix = ' ' * $left
        if     ($Dim)     { Write-Host ($prefix + $Str) -ForegroundColor $Global:ADToolTheme.Hint }
        elseif ($useTrue) { Write-Host ("{0}{1}[38;2;{2};{3};{4}m{5}{1}[0m" -f $prefix, $esc, $rgb[0], $rgb[1], $rgb[2], $Str) }
        else              { Write-Host ($prefix + $Str) -ForegroundColor $named }
    }

    # Place it a little ABOVE the true middle when we cleared the screen - dead
    # centre reads as too low once the shell prompt returns underneath. Block =
    # rule + blank + quote lines + blank + rule + blank.
    $block = $lines.Count + 5
    if ($interactive) {
        $top = [int]($height * 0.40) - [int]($block / 2)
        for ($i = 0; $i -lt [Math]::Max(0, $top); $i++) { Write-Host '' }
    }
    else { Write-Host '' }

    & $emit $rule -Dim
    Write-Host ''
    foreach ($ln in $lines) { & $emit $ln }
    Write-Host ''
    & $emit $rule -Dim
    Write-Host ''
}
