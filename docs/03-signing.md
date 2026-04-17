# Code signing

The build workflows produce working binaries without any signing identity,
but distributed binaries should be signed to avoid alarming end users
(Windows SmartScreen, macOS Gatekeeper) and to unlock Play Store
distribution on Android.

This document lists every signing-related secret the workflows accept,
where to obtain the signing identities, and how to encode them for
GitHub Secrets.

All signing steps are **optional and gated**: if the required secrets are
absent, the corresponding step is skipped and the unsigned binary ships
as-is.

## Windows (`build-client-windows.yml`)

| Secret | What |
|---|---|
| `WINDOWS_PFX_BASE64` | base64 of your `.pfx` / `.p12` code-signing certificate |
| `WINDOWS_PFX_PASSWORD` | password protecting the `.pfx` |

The workflow signs (a) every `rustdesk*.exe` and `librustdesk*.dll`
produced by Flutter, then (b) the MSI installer after MSBuild. Both use
`signtool sign /fd SHA256 /tr <timestamp> /td SHA256`.

Override the timestamp authority via the workflow-level `env` map
(`SIGNTOOL_TIMESTAMP_URL`); default is `http://timestamp.digicert.com`.

### Getting a Windows code-signing certificate

SmartScreen will keep warning end users ("Unknown publisher") **even
with an OV certificate**, until reputation is established (weeks to
months). An **EV (Extended Validation)** certificate unlocks reputation
immediately at the cost of ~300-500 EUR/year.

Well-known issuers: Sectigo, DigiCert, Comodo, SSL.com. EV certificates
are typically shipped on a hardware USB token; to use it in CI you
either mirror the cert to a software keystore (vendor-specific) or use
a cloud-based signing service (DigiCert KeyLocker, SSL.com eSigner).

To convert a `.pfx` to base64 for `gh secret set`:

```bash
base64 -w0 cert.pfx > cert.pfx.b64
gh secret set WINDOWS_PFX_BASE64 --repo <owner>/<repo> < cert.pfx.b64
gh secret set WINDOWS_PFX_PASSWORD --repo <owner>/<repo> --body '<password>'
```

## macOS (`build-client-macos.yml`)

| Secret | What |
|---|---|
| `APPLE_DEVELOPER_ID_CERT_BASE64` | base64 of your Developer ID Application `.p12` |
| `APPLE_DEVELOPER_ID_CERT_PASSWORD` | password protecting the `.p12` |
| `APPLE_TEAM_ID` | 10-character Team ID from https://developer.apple.com/account |
| `APPLE_APPLE_ID` | email on the Apple Developer account |
| `APPLE_APP_SPECIFIC_PASSWORD` | app-specific password (appleid.apple.com → Sign-in and Security → App-Specific Passwords) |

The workflow uses `rcodesign` (github.com/indygreg/apple-platform-rs),
not Apple's `codesign`/`notarytool`. Rationale: rcodesign works without
a pre-loaded keychain, which lets the same step run on x86_64-intel or
arm macOS runners interchangeably.

### Getting a Developer ID certificate

- Apple Developer Program: 99 USD/year, at https://developer.apple.com.
- Under Certificates, Identifiers & Profiles → Certificates, create a
  **Developer ID Application** certificate (not "Apple Development").
- Download the `.cer`, import into Keychain, then export as `.p12` with
  a password.

## Android (`build-client-android.yml`)

| Secret | What |
|---|---|
| `ANDROID_KEYSTORE_BASE64` | base64 of your `release.keystore` (JKS or PKCS12) |
| `ANDROID_KEYSTORE_PASSWORD` | store password |
| `ANDROID_KEY_ALIAS` | key alias inside the keystore |
| `ANDROID_KEY_PASSWORD` | alias password (often identical to store password) |

Without these four secrets, the workflow falls back to signing with
Gradle's debug config — the APK installs on a device via `adb install`,
but cannot be uploaded to Google Play.

### Generating a keystore locally

```bash
keytool -genkeypair -v \
    -keystore release.keystore \
    -alias release \
    -keyalg RSA \
    -keysize 4096 \
    -validity 10000 \
    -storepass '<pick-a-strong-password>' \
    -keypass  '<pick-a-strong-password>' \
    -dname 'CN=RemoteControl, O=Example SA, C=BE'
```

Guard the `.keystore` like you guard an Apple Developer cert — **losing
it means Play Store refuses updates for the app forever**. Store a
backup in a password manager or HSM.

### Encode for GitHub Secrets

```bash
base64 -w0 release.keystore > release.keystore.b64
gh secret set ANDROID_KEYSTORE_BASE64 --repo <owner>/<repo> < release.keystore.b64
gh secret set ANDROID_KEYSTORE_PASSWORD --repo <owner>/<repo> --body '<store-password>'
gh secret set ANDROID_KEY_ALIAS         --repo <owner>/<repo> --body 'release'
gh secret set ANDROID_KEY_PASSWORD      --repo <owner>/<repo> --body '<key-password>'
```

### Play App Signing (recommended)

Upload your upload key to Play Console, let Google manage the release
signing key on their side. Your GitHub Secret is then the *upload* key
(much less critical — rotatable if leaked). See
https://support.google.com/googleplay/android-developer/answer/9842756
for the migration path from a self-managed keystore.

## Verifying signed output

- **Windows**: right-click the signed `.exe`/`.msi` → Properties →
  Digital Signatures tab. Or: `signtool verify /pa /v <file>`.
- **macOS**: `codesign --verify --deep --strict --verbose=2 <app>` +
  `spctl -a -t exec -vv <app>` (should say "Notarized Developer ID").
- **Android**: `apksigner verify --verbose --print-certs <apk>`. Should
  list the fingerprint of your release certificate, not the debug one.
