# Sentry Configuration

This document explains how to configure Sentry crash reporting for the Just Speak to It app.

## Configuration

The Sentry DSN (Data Source Name) is now read from build configuration instead of being hardcoded. This allows for:
- Easy rotation of Sentry keys
- Different DSNs per environment (dev/staging/production)
- No sensitive data committed to the repository

## Setup

1. Add your Sentry DSN to the `.env` file in the project root:
   ```bash
   SENTRY_DSN=https://your-key@your-org.ingest.sentry.io/your-project-id
   ```

2. The `.env` file is already in `.gitignore` to prevent committing secrets.

3. When building the app, the DSN is injected into the Info.plist via build settings.

## Building

### Local Development

The Makefile automatically loads `.env` variables:
```bash
make build
make run
make xcode  # Generates Xcode project with env vars
```

### CI/CD

For CI/CD pipelines, set the `SENTRY_DSN` environment variable in your CI configuration (GitHub Actions, etc.):
```yaml
env:
  SENTRY_DSN: ${{ secrets.SENTRY_DSN }}
```

### Xcode Builds

If building directly in Xcode (not via Makefile):
1. Run `make xcode` to generate the workspace with environment variables loaded
2. Or manually export the environment variable before opening Xcode:
   ```bash
   export SENTRY_DSN="your-dsn-here"
   open "Just Speak to It.xcworkspace"
   ```

## How It Works

1. **Project.swift**: Reads `SENTRY_DSN` from environment and adds it to build settings
2. **AppInfo.plist**: Contains placeholder `$(SENTRY_DSN)` that gets replaced at build time
3. **SentryManager.swift**: Reads the DSN from `Bundle.main.infoDictionary` at runtime

## Debug Builds

Sentry is automatically disabled in DEBUG builds to avoid polluting production data with development errors.

## Validation

If the DSN is not configured or invalid, you'll see a warning in the console:
```
⚠️ Sentry DSN not configured - crash reporting disabled
```

This is safe - the app will run normally but won't send crash reports.

## Environment-Specific DSNs

To use different DSNs for different environments:

1. Create separate `.env` files:
   - `.env.development`
   - `.env.staging`
   - `.env.production`

2. Load the appropriate one based on your build configuration or copy to `.env` before building.
