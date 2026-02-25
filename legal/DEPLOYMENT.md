## Deploying `nyx.app/privacy` and `nyx.app/terms`

This repo includes static legal pages:

- `legal/privacy/index.html`  → host at `https://nyx.app/privacy`
- `legal/terms/index.html`    → host at `https://nyx.app/terms`

You can deploy them with any static hosting (recommended options below).

### Option A — Existing `nyx.app` website host (fastest)

If you already have a website for `nyx.app`, add two routes:

- `/privacy` → serve `legal/privacy/index.html`
- `/terms` → serve `legal/terms/index.html`

### Option B — Netlify (drag & drop)

1. Create a folder on your computer containing:
   - `privacy/index.html` (copy from `legal/privacy/index.html`)
   - `terms/index.html` (copy from `legal/terms/index.html`)
2. In Netlify, deploy that folder (drag & drop).
3. Add a custom domain for `nyx.app` (or subdomain), and configure DNS.
4. Ensure the final URLs are:
   - `https://nyx.app/privacy`
   - `https://nyx.app/terms`

### Option C — Cloudflare Pages / Vercel / GitHub Pages

Any static site host works. You can host the `legal/` folder as the site root, or set it as the output directory.

### After deploy

In App Store Connect set:

- Privacy Policy URL: `https://nyx.app/privacy`
- Add to app description:
  - Terms of Use (EULA): `https://www.apple.com/legal/internet-services/itunes/dev/stdeula/`
  - Privacy Policy: `https://nyx.app/privacy`

