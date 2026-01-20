# JustSpeakToIt Landing Page

A beautiful, performant landing page for the JustSpeakToIt voice transcription app.

## Development

```bash
# Install dependencies
bun install

# Start development server
bun run dev
# Open http://localhost:3000
```

## Deployment to Cloudflare Pages

### Option 1: Direct Upload (Recommended for quick deploys)

1. Go to [Cloudflare Pages Dashboard](https://dash.cloudflare.com/?to=/:account/pages)
2. Click "Create a project" → "Direct Upload"
3. Drag and drop the `index.html` file (or the entire landing-page folder)
4. Configure custom domain: `justspeaktoit.com`

### Option 2: Git Integration

1. Push this repo to GitHub
2. Go to Cloudflare Pages Dashboard
3. Click "Create a project" → "Connect to Git"
4. Select the repository
5. Configure build settings:
   - **Build command:** leave empty (static site)
   - **Build output directory:** `landing-page`
   - **Root directory:** `landing-page`
6. Deploy and configure custom domain

### Custom Domain Setup

1. In Cloudflare Pages project settings, go to "Custom domains"
2. Add `justspeaktoit.com`
3. If domain is already on Cloudflare:
   - It will auto-configure DNS
4. If domain is elsewhere:
   - Add CNAME record pointing to `<project>.pages.dev`

## Files

- `index.html` - The complete landing page (single file, no build needed)
- `serve.ts` - Bun development server
- `wrangler.toml` - Cloudflare Pages configuration
- `_redirects` - Redirect rules for SPA routing

## Tech Stack

- Pure HTML/CSS/JS (no framework)
- Custom fonts from Fontshare (Satoshi + General Sans)
- CSS animations and scroll reveal effects
- Responsive design
- ~34KB total (uncompressed)
