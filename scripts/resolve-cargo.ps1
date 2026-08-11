$cargoCommand = Get-Command cargo.exe -ErrorAction SilentlyContinue
if ($cargoCommand) {
    $cargoCommand.Source
    exit 0
}

$userCargo = Join-Path $env:USERPROFILE ".cargo\bin\cargo.exe"
if (Test-Path -LiteralPath $userCargo) {
    $userCargo
    exit 0
}

throw "cargo.exe was not found. Install rustup from https://rustup.rs/."
