# Android tsnet module

This module is the Android-compatible replacement for the unavailable
`libtailscale` C archive. It is built with Go Mobile into an `arm64-v8a` AAR.

The Tailscale dependency is pinned to `v1.94.1`; the build script pins Go
Mobile to `v0.0.0-20260821190718-4776eadac327`, which requires Go 1.26. Build
with:

```powershell
.\build-android.ps1 -AndroidSdk C:\path\to\Android\Sdk
```

`tailnetandroid.aar` is generated output and must not be committed.
