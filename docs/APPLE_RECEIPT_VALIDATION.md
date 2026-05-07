# Apple receipt validation (Nyx)

Apple expects you to **verify purchases on your own server** using the receipt (or StoreKit 2 JWS). Do **not** embed your App-Specific Shared Secret in the app.

## What the app does

1. On a successful **App Store** purchase or restore, `in_app_purchase` exposes a base64 receipt in  
   `purchase.verificationData.serverVerificationData`.
2. If you set **`APPSTORE_RECEIPT_VALIDATE_URL`** at build time, the app **POSTs** that receipt to your URL as JSON:

   ```json
   { "receipt_data": "<base64>" }
   ```

3. Premium is granted only if your server responds with **HTTP 200** and either:
   - `"valid": true`, or  
   - `"status": 0` (Apple-style verifyReceipt success).

If the URL is **not** set, the app behaves as before (trusts StoreKit only).

## Build / run

```bash
flutter run --dart-define=APPSTORE_RECEIPT_VALIDATE_URL=https://your-api.example.com/apple/validate-receipt
```

Optional Bearer token for your API:

```bash
--dart-define=APPSTORE_RECEIPT_VALIDATE_AUTH=your-server-secret-token
```

Release IPA:

```bash
flutter build ipa --dart-define=APPSTORE_RECEIPT_VALIDATE_URL=https://your-api.example.com/apple/validate-receipt
```

In **Xcode**, add the same flags under **Runner → Build Settings → User-Defined** or in the archive scheme’s **Arguments Passed On Launch** is not correct for dart-define; for Flutter use `FLUTTER_BUILD_ARGS` or set in CI. Easiest: build from terminal with `--dart-define=...` or use `flutter build ipa` with defines.

## App Store Connect

1. Open [App Store Connect](https://appstoreconnect.apple.com) → your app.
2. **App Information** (or **Subscriptions** area) → **App-Specific Shared Secret** → generate and copy it (use only on the server).

## Backend: verify with Apple

Apple’s legacy endpoint (still widely used):

- Production: `POST https://buy.itunes.apple.com/verifyReceipt`
- Sandbox: `POST https://sandbox.itunes.apple.com/verifyReceipt`

Request JSON:

```json
{
  "receipt-data": "<paste base64 from client>",
  "password": "<app-specific shared secret>",
  "exclude-old-transactions": true
}
```

If `status` is **21007**, retry the **same** receipt against the **sandbox** URL (test user / sandbox purchase).

Successful verification returns `status: 0` in the JSON.

### Minimal Node.js example

```js
import express from 'express';
import fetch from 'node-fetch';

const APPLE_SHARED_SECRET = process.env.APPLE_SHARED_SECRET;
const app = express();
app.use(express.json({ limit: '2mb' }));

app.post('/apple/validate-receipt', async (req, res) => {
  const receipt = req.body.receipt_data;
  if (!receipt) return res.status(400).json({ valid: false });

  let r = await fetch('https://buy.itunes.apple.com/verifyReceipt', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({
      'receipt-data': receipt,
      password: APPLE_SHARED_SECRET,
      'exclude-old-transactions': true,
    }),
  });
  let j = await r.json();
  if (j.status === 21007) {
    r = await fetch('https://sandbox.itunes.apple.com/verifyReceipt', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        'receipt-data': receipt,
        password: APPLE_SHARED_SECRET,
        'exclude-old-transactions': true,
      }),
    });
    j = await r.json();
  }
  if (j.status === 0) return res.json({ valid: true });
  return res.status(200).json({ valid: false, apple_status: j.status });
});

app.listen(3000);
```

Check the decoded receipt’s `in_app` (or latest_receipt_info) for your product IDs (`nyx_unlimited_monthly`, `nyx_unlimited_yearly`) and active subscription state.

## StoreKit 2 / JWS

Newer `in_app_purchase` builds may use StoreKit 2 where `serverVerificationData` can be a **JWS** string instead of the classic receipt. If you migrate to JWS verification, your server should verify the JWS per Apple’s [documentation](https://developer.apple.com/documentation/storekit/verifying-a-transaction) instead of (or in addition to) `verifyReceipt`.

## Security

- Use **HTTPS** only in production.
- Validate **Authorization** / session on your endpoint.
- Rate-limit the validate endpoint.
