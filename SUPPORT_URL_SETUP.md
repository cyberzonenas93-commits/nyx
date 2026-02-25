# Support URL Setup for App Store Connect

## Requirement
App Store Connect requires a **Support URL** for your app. This can be:
- A website URL
- An email address (mailto: link)
- A support page

## Options for Nyx

### Option 1: Use Email Address (Easiest)
**Support URL:**
```
mailto:support@angelonartey.com
```
or
```
mailto:nyx@angelonartey.com
```

**Pros:**
- No website needed
- Works immediately
- Simple to set up

**Cons:**
- Less professional than a dedicated page
- Users need to open email app

### Option 2: Create Simple Support Page

#### Option 2a: GitHub Pages (Free)
1. Create a new GitHub repository: `nyx-support`
2. Create `index.html` with support information
3. Enable GitHub Pages in repository settings
4. Support URL: `https://[your-username].github.io/nyx-support`

#### Option 2b: Simple HTML Page
Create a basic HTML page and host it anywhere:
- Your existing website
- Netlify (free)
- Vercel (free)
- Any web hosting service

### Option 3: Use Existing Website
If you have a website at `angelonartey.com`:
```
https://angelonartey.com/nyx/support
```

## Recommended: Simple Support Page Template

Here's a basic HTML template you can use:

```html
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Nyx - Support</title>
    <style>
        body {
            font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
            max-width: 800px;
            margin: 0 auto;
            padding: 20px;
            background: #0E0E11;
            color: #FFFFFF;
            line-height: 1.6;
        }
        h1 { color: #2EE6A6; }
        a { color: #2EE6A6; text-decoration: none; }
        a:hover { text-decoration: underline; }
        .section { margin: 30px 0; }
    </style>
</head>
<body>
    <h1>Nyx Support</h1>
    
    <div class="section">
        <h2>Contact Us</h2>
        <p>For support, questions, or feedback about Nyx, please contact us:</p>
        <p><strong>Email:</strong> <a href="mailto:support@angelonartey.com">support@angelonartey.com</a></p>
    </div>
    
    <div class="section">
        <h2>Frequently Asked Questions</h2>
        
        <h3>How do I access my vault?</h3>
        <p>Double-tap anywhere on the calculator screen or long-press the "=" button to unlock your vault.</p>
        
        <h3>What if I forget my PIN?</h3>
        <p>Unfortunately, if you forget your PIN, your data cannot be recovered due to zero-knowledge encryption. Please store your PIN securely.</p>
        
        <h3>How do I upgrade to Unlimited?</h3>
        <p>Open the app, go to Settings, and tap "Manage Subscription" to upgrade to unlimited storage.</p>
        
        <h3>Is my data secure?</h3>
        <p>Yes. All data is encrypted on your device using AES-256-GCM encryption. We never see your files, passwords, or encryption keys.</p>
        
        <h3>What file types are supported?</h3>
        <p>Nyx supports photos, videos, and documents including PDF, Excel, Word, and Pages files.</p>
    </div>
    
    <div class="section">
        <h2>Privacy</h2>
        <p>Your privacy is our priority. Nyx uses zero-knowledge encryption, meaning we cannot access your data even if we wanted to.</p>
        <p><a href="[PRIVACY_POLICY_URL]">View Privacy Policy</a></p>
    </div>
    
    <div class="section">
        <p><small>© 2025 Nyx. All rights reserved.</small></p>
    </div>
</body>
</html>
```

## Quick Setup Steps

### If using email:
1. Use: `mailto:support@angelonartey.com`
2. Paste into App Store Connect Support URL field
3. Done!

### If creating a support page:
1. Save the HTML template above as `index.html`
2. Host it on GitHub Pages, Netlify, or your web server
3. Use the URL in App Store Connect

## Current Recommendation

**For immediate use, use email:**
```
mailto:support@angelonartey.com
```

**For a more professional setup, create a simple support page** using the template above.

## App Store Connect Entry

In App Store Connect, paste your chosen Support URL in the **Support URL** field under App Information.
