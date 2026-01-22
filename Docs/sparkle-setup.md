# Sparkle Auto-Update Setup

This document describes how to set up Sparkle auto-updates for Just Speak to It.

## Overview

The app uses [Sparkle](https://sparkle-project.org/) to provide automatic updates. When a new version is released:

1. The release workflow generates a signed `appcast.xml`
2. The appcast is uploaded to GitHub Releases and committed to `landing-page/appcast.xml`
3. The app periodically checks the appcast for updates
4. Users can also manually check via **Just Speak to It → Check for Updates…**

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
- Commits updated appcast to `landing-page/` for Cloudflare Pages

### Appcast Location
The appcast is hosted at `https://justspeaktoit.com/appcast.xml` via Cloudflare Pages.

## Testing

1. Build and run the app locally
2. Check **Just Speak to It → Check for Updates…** appears in menu
3. The button should be enabled when not already checking

To test the full flow:
1. Set up the secrets as described above
2. Create a test release tag
3. Verify the appcast.xml is generated and deployed
4. Install an older version and verify it detects the update

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
