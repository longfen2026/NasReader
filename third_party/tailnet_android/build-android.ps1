param(
    [string]$AndroidSdk = $env:ANDROID_HOME,
    [string]$Output = (Join-Path $PSScriptRoot "tailnetandroid.aar"),
    [string]$GoMobileVersion = "v0.0.0-20260821190718-4776eadac327"
)

$ErrorActionPreference = "Stop"

if ([string]::IsNullOrWhiteSpace($AndroidSdk)) {
    throw "Set ANDROID_HOME or pass -AndroidSdk with the Android SDK directory."
}

$env:ANDROID_HOME = $AndroidSdk
$env:ANDROID_NDK_HOME = Join-Path $AndroidSdk "ndk\28.2.13676358"
$env:GOTOOLCHAIN = "go1.26.0+auto"

go install "golang.org/x/mobile/cmd/gomobile@$GoMobileVersion"
if ($LASTEXITCODE -ne 0) {
    throw "Unable to install the locked gomobile version."
}

go get -tool "golang.org/x/mobile/cmd/gobind@$GoMobileVersion"
if ($LASTEXITCODE -ne 0) {
    throw "Unable to add the locked Go Mobile binding tool."
}

$goMobile = Join-Path (go env GOPATH) "bin\gomobile.exe"
& $goMobile init
if ($LASTEXITCODE -ne 0) {
    throw "Unable to initialize gomobile for the configured Android SDK."
}

& $goMobile bind `
    -target=android/arm64 `
    -androidapi=24 `
    -o $Output `
    .
if ($LASTEXITCODE -ne 0) {
    throw "Unable to build the Tailnet Android AAR."
}