[CmdletBinding(DefaultParameterSetName = "File")]
param(
    [Parameter(Mandatory = $true, ParameterSetName = "File")]
    [string]$MessageFile,

    [Parameter(Mandatory = $true, ParameterSetName = "Text")]
    [AllowEmptyString()]
    [string]$Message
)

$ErrorActionPreference = "Stop"

if ($PSCmdlet.ParameterSetName -eq "File") {
    $Message = Get-Content -Raw -Encoding utf8 $MessageFile
}

$normalized = $Message.Replace("`r`n", "`n").Replace("`r", "`n")
$lines = @($normalized -split "`n" | Where-Object { -not $_.StartsWith("#") })
while ($lines.Count -gt 0 -and [string]::IsNullOrWhiteSpace($lines[-1])) {
    if ($lines.Count -eq 1) {
        $lines = @()
    }
    else {
        $lines = @($lines[0..($lines.Count - 2)])
    }
}

if ($lines.Count -eq 0) {
    throw "Commit message policy failed: the message is empty."
}

$subject = $lines[0]
if ($subject -match '^Merge\s+') {
    Write-Host "Generated merge commit message accepted."
    exit 0
}

$errors = [System.Collections.Generic.List[string]]::new()
$subjectPattern = '^(feat|fix|refactor|perf|test|docs|build|ci|chore|revert)(\([a-z0-9][a-z0-9-]*\))?(!)?: [a-z0-9][^\r\n]*$'

if ($subject -notmatch $subjectPattern) {
    $errors.Add("subject must match 'type(scope): lowercase imperative summary'")
}
if ($subject.Length -gt 72) {
    $errors.Add("subject is $($subject.Length) characters; maximum is 72")
}
if ($subject.EndsWith(".")) {
    $errors.Add("subject must not end with a period")
}
if ($subject -match '^(WIP|fixup!|squash!)') {
    $errors.Add("WIP, fixup!, and squash! commits cannot enter shared history")
}
if ($lines.Count -lt 3 -or $lines[1] -ne "") {
    $errors.Add("add one blank line between the subject and body")
}

$body = if ($lines.Count -ge 3) { $lines[2..($lines.Count - 1)] } else { @() }
foreach ($heading in @("Why:", "What:", "Evidence:")) {
    if (-not ($body -ccontains $heading)) {
        $errors.Add("body must contain the exact heading '$heading'")
    }
}

$headingIndexes = @{}
for ($index = 0; $index -lt $body.Count; $index++) {
    if ($body[$index] -in @("Why:", "What:", "Evidence:")) {
        $headingIndexes[$body[$index]] = $index
    }
}
if ($headingIndexes.Count -eq 3) {
    if (-not (
        $headingIndexes["Why:"] -lt $headingIndexes["What:"] -and
        $headingIndexes["What:"] -lt $headingIndexes["Evidence:"]
    )) {
        $errors.Add("required headings must appear in Why, What, Evidence order")
    }

    foreach ($heading in @("Why:", "What:", "Evidence:")) {
        $start = $headingIndexes[$heading] + 1
        $nextIndexes = @($headingIndexes.Values | Where-Object { $_ -gt $headingIndexes[$heading] })
        $end = if ($nextIndexes.Count -gt 0) {
            ($nextIndexes | Measure-Object -Minimum).Minimum - 1
        } else {
            $body.Count - 1
        }
        $content = if ($start -le $end) { @($body[$start..$end]) } else { @() }
        if (-not ($content | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })) {
            $errors.Add("section '$heading' must contain evidence-bearing content")
        }
    }
}

if ($subject -match '!:' -and $normalized -notmatch '(?m)^BREAKING CHANGE:\s+\S') {
    $errors.Add("a breaking subject requires a 'BREAKING CHANGE:' paragraph")
}

if ($errors.Count -gt 0) {
    $details = $errors | ForEach-Object { "- $_" }
    throw "Commit message policy failed:`n$($details -join "`n")"
}

Write-Host "Commit message policy passed: $subject"
