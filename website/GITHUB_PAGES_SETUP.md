# GitHub Pages Setup for Nyx Support Website

## Step-by-Step Guide

### Step 1: Create a GitHub Repository

1. Go to [github.com](https://github.com) and sign in
2. Click the "+" icon in the top right
3. Select "New repository"
4. Name it: `nyx-support` (or `nyx-app-support`)
5. Make it **Public** (required for free GitHub Pages)
6. **DO NOT** initialize with README, .gitignore, or license
7. Click "Create repository"

### Step 2: Upload the HTML File

**Option A: Using GitHub Web Interface**

1. In your new repository, click "uploading an existing file"
2. Drag and drop the `index.html` file from the `website/` folder
3. Click "Commit changes"

**Option B: Using Git (if you have Git installed)**

```bash
cd "/Users/angelonartey/Privacy app/website"
git init
git add index.html
git commit -m "Initial commit: Nyx support page"
git branch -M main
git remote add origin https://github.com/YOUR_USERNAME/nyx-support.git
git push -u origin main
```

Replace `YOUR_USERNAME` with your GitHub username.

### Step 3: Enable GitHub Pages

1. Go to your repository on GitHub
2. Click **Settings** (top menu)
3. Scroll down to **Pages** (in the left sidebar)
4. Under **Source**, select:
   - **Branch:** `main` (or `master`)
   - **Folder:** `/ (root)`
5. Click **Save**
6. Wait a few minutes for GitHub to build your site

### Step 4: Get Your Website URL

Your website will be available at:
```
https://YOUR_USERNAME.github.io/nyx-support/
```

For example, if your username is `angelonartey`:
```
https://angelonartey.github.io/nyx-support/
```

### Step 5: Use in App Store Connect

Copy your GitHub Pages URL and paste it into App Store Connect as the **Support URL**.

## Custom Domain (Optional)

If you want to use a custom domain like `support.angelonartey.com`:

1. In GitHub Pages settings, enter your custom domain
2. Add a CNAME file in your repository with your domain name
3. Update your DNS records to point to GitHub Pages

## Updating Your Website

To update the support page later:

1. Edit `index.html`
2. Upload the new file to GitHub (or commit and push)
3. Changes appear within a few minutes

## Troubleshooting

**Website not loading?**
- Wait 5-10 minutes after enabling Pages
- Check that the repository is Public
- Verify `index.html` is in the root directory
- Check the GitHub Pages settings page for any errors

**Need help?**
- GitHub Pages documentation: https://docs.github.com/en/pages
- GitHub Support: https://support.github.com

## Quick Checklist

- [ ] Created GitHub repository (Public)
- [ ] Uploaded `index.html` to repository
- [ ] Enabled GitHub Pages in Settings
- [ ] Waited for site to build
- [ ] Tested the URL in a browser
- [ ] Added URL to App Store Connect

That's it! Your free support website will be live at `https://YOUR_USERNAME.github.io/nyx-support/`
