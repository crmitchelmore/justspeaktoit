# Sparkle Auto-Update Setup

This document describes how to set up Sparkle auto-updates for Just Speak to It.

## Overview

The app uses [Sparkle](https://sparkle-project.org/) to provide automatic updates. When a new version is released:

1. The release workflow generates a signed `appcast.xml`
2. The appcast is uploaded as an asset on the GitHub Release
3. `https://justspeaktoit.com/appcast.xml` redirects to the latest non-prerelease GitHub asset
4. The app periodically checks the appcast for updates
5. Users can also manually check via **Just Speak to It → Check for Updates…**

## One-Time Setup (Required)

### 1. Generate Sparkle Signing Keys

Run locally (once):

```bash
# Download Sparkle tools
curl -sL "https://github.com/sparkle-project/Sparkle/releases/download/2.8.1/Sparkle-2.8.1.tar.xz" | tar xJ -C /tmp

# Generate key pair
/tmp/Sparkle.framework/Resources/bin/generate_keys
```

This outputs:
- **Private key**: A base64-encoded EdDSA private key (keep SECRET)
- **Public key**: A base64-encoded EdDSA public key (embed in app)

### 2. Add GitHub Secrets

Add the following secret to the repository:

| Secret Name | Value |
|-------------|-------|
| `SPARKLE_PRIVATE_KEY` | The base64-encoded private key from step 1 |

### 3. Update Info.plist with Public Key

Edit `Config/AppInfo.plist` and replace the placeholder:

```xml
<key>SUPublicEDKey</key>
<string>YOUR_PUBLIC_KEY_HERE</string>
```

Replace `SPARKLE_PUBLIC_KEY_PLACEHOLDER` with your actual public key.

## How It Works

### App Side
- `UpdaterManager.swift` - Manages Sparkle's `SPUUpdater`
- `SpeakApp.swift` - Adds "Check for Updates…" menu item
- Info.plist contains `SUFeedURL` pointing to `https://justspeaktoit.com/appcast.xml`

### Release Workflow
- `scripts/generate-appcast.sh` - Generates signed appcast XML
- The workflow signs the DMG with the private key
- Uploads appcast.xml to GitHub Releases
- GitHub's latest-release URL makes the new appcast available without writing to protected `main`

### Appcast Location
The app checks `https://justspeaktoit.com/appcast.xml`. Cloudflare Pages redirects that stable URL to:

`https://github.com/crmitchelmore/justspeaktoit/releases/latest/download/appcast.xml`

GitHub resolves `latest` to the newest non-draft, non-prerelease release, so test or prerelease tags do not replace the production feed.

## Testing

1. Build and run the app locally
2. Check **Just Speak to It → Check for Updates…** appears in menu
3. The button should be enabled when not already checking

To test without changing the production feed:
1. Set up the secrets as described above
2. Publish the test artifact only as a draft or prerelease; do not use an ordinary `mac-v*` test release
3. Verify the prerelease's direct `/releases/download/<tag>/appcast.xml` asset URL
4. Reserve checks of `https://justspeaktoit.com/appcast.xml` for an intentional production release
5. During that production release, verify the stable URL resolves to the intended release asset before testing an older app

## Troubleshooting

### "Check for Updates" is always disabled
- Ensure `SUFeedURL` is set in Info.plist
- Ensure `SUPublicEDKey` is set (not the placeholder)

### Updates fail signature verification
- Ensure `SPARKLE_PRIVATE_KEY` matches the public key in Info.plist
- The key pair must be generated together

### Appcast not updating
- Check the release workflow logs for errors
- Verify the `SPARKLE_PRIVATE_KEY` secret is set
- Verify the GitHub release is neither a draft nor a prerelease
- Verify the exact `/appcast.xml` redirect is the first rule in `landing-page/_redirects`, before the `/index.html` rewrite
