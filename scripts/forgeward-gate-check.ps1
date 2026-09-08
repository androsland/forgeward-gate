param(
    [Parameter(Position = 0)]
    [ValidateSet('expansion', 'prompt-submit', 'pretooluse')]
    [string] $Mode = 'pretooluse'
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

try {
    $pluginRoot = $env:PLUGIN_ROOT
    if ([string]::IsNullOrWhiteSpace($pluginRoot)) {
        exit 0
    }

    if ($pluginRoot.StartsWith('\\?\UNC\', [StringComparison]::OrdinalIgnoreCase)) {
        $pluginRoot = '\\' + $pluginRoot.Substring(8)
    }
    elseif ($pluginRoot.StartsWith('\\?\', [StringComparison]::OrdinalIgnoreCase)) {
        $pluginRoot = $pluginRoot.Substring(4)
    }

    $guard = [IO.Path]::Combine($pluginRoot, 'scripts', 'forgeward-gate-check.sh')
    if (-not [IO.File]::Exists($guard)) {
        exit 0
    }

    $bash = $null
    foreach ($git in @(Get-Command git.exe -All -CommandType Application -ErrorAction SilentlyContinue)) {
        $gitDirectory = [IO.Path]::GetDirectoryName($git.Source)
        foreach ($candidate in @(
            [IO.Path]::Combine($gitDirectory, 'bash.exe'),
            [IO.Path]::GetFullPath([IO.Path]::Combine($gitDirectory, '..', 'bin', 'bash.exe')),
            [IO.Path]::GetFullPath([IO.Path]::Combine($gitDirectory, '..', 'usr', 'bin', 'bash.exe'))
        )) {
            if (-not [IO.File]::Exists($candidate)) {
                continue
            }

            & $candidate --noprofile --norc -c 'exit 0' *> $null
            if ($LASTEXITCODE -eq 0) {
                $bash = $candidate
                break
            }
        }

        if ($null -ne $bash) {
            break
        }
    }

    if ($null -eq $bash) {
        exit 0
    }

    # MSYS converts drive-qualified arguments but leaves backslash UNC arguments
    # untouched. Forward slashes preserve both forms and make //server/share
    # addressable by Git Bash.
    $guardForBash = $guard.Replace('\', '/')
    & $bash --noprofile --norc $guardForBash $Mode
    exit $LASTEXITCODE
}
catch {
    # Lifecycle hooks are fast feedback. The git pre-push hook remains the
    # enforcement boundary, so launcher/setup failures must not wedge Codex.
    exit 0
}
