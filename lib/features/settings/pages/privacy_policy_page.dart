import 'package:flutter/material.dart';
import '../../../app/theme.dart';

/// Privacy Policy page
class PrivacyPolicyPage extends StatelessWidget {
  const PrivacyPolicyPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.primary,
      appBar: AppBar(
        title: const Text('Privacy Policy'),
        backgroundColor: AppTheme.surface,
        elevation: 0,
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header
            Container(
              padding: const EdgeInsets.all(24),
              decoration: BoxDecoration(
                color: AppTheme.surface,
                borderRadius: BorderRadius.circular(AppTheme.radius),
              ),
              child: Column(
                children: [
                  Icon(
                    Icons.shield_outlined,
                    size: 64,
                    color: AppTheme.accent,
                  ),
                  const SizedBox(height: 16),
                  const Text(
                    'Nyx Privacy Policy',
                    style: TextStyle(
                      fontSize: 24,
                      fontWeight: FontWeight.w700,
                      color: AppTheme.text,
                    ),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Last Updated: ${DateTime.now().toString().split(' ')[0]}',
                    style: TextStyle(
                      fontSize: 14,
                      color: AppTheme.text.withOpacity(0.6),
                    ),
                  ),
                ],
              ),
            ),

            const SizedBox(height: 32),

            // Introduction
            _PolicySection(
              title: 'Introduction',
              content: '''
Nyx ("we", "our", or "us") is committed to protecting your privacy. This Privacy Policy explains how we collect, use, and safeguard your information when you use our mobile application (the "Service").

By using Nyx, you agree to the collection and use of information in accordance with this policy.
''',
            ),

            // Local privacy model
            _PolicySection(
              title: 'Local Privacy Model',
              content: '''
Nyx is designed to keep your vault data on your device:

• We do not run a Nyx cloud storage service for your vault files
• We do not receive your PIN, pattern, or vault contents
• Unlock credentials are checked locally on your device
• Optional transfer features work over your local network only
• If you forget your unlock method, there is no account-based recovery flow inside Nyx

This local-first design limits what we can access because your files are not uploaded to our servers.
''',
            ),

            // Data Collection
            _PolicySection(
              title: 'Information We Collect',
              content: '''
Nyx collects minimal data necessary for the app to function:

• Subscription Information: If you purchase a subscription, we process payment information through Apple's App Store or Google Play Store. We do not store your payment details - all payment processing is handled by Apple/Google.

• App Usage Data: We may collect anonymous usage statistics to improve the app (e.g., crash reports, feature usage). This data cannot be linked to your identity or files.

• Device Information: We may collect device type, operating system version, and app version for compatibility and support purposes.

We do NOT collect:
• Your files or media content
• Your PIN or passwords
• Your encryption keys
• Personal information beyond what's necessary for app functionality
• Location data
• Contact information
• Browsing history or web activity
''',
            ),

            // Data Storage
            _PolicySection(
              title: 'Data Storage',
              content: '''
All your files are stored locally on your device. We do not:

• Store your files on our servers
• Sync your files to cloud services
• Access your device's storage beyond what's necessary for app functionality
• Share your data with third parties

Your vault files remain on your device unless you explicitly export or transfer them.
''',
            ),

            // Security
            _PolicySection(
              title: 'Security Measures',
              content: '''
Nyx implements multiple layers of security:

• PIN or Pattern Protection: Access to the app is gated by your chosen unlock method
• Secure Storage: Sensitive app secrets are stored in iOS Keychain / Android Keystore-backed storage where available
• Auto-Lock: The app locks when sent to the background
• Tamper Response: Failed-attempt tracking and optional strict wipe protections are available
• Local-Only Handling: Nyx does not upload vault files to its own backend

Despite these measures, no method of transmission or storage is 100% secure. We cannot guarantee absolute security.
''',
            ),

            // How We Use Information
            _PolicySection(
              title: 'How We Use Your Information',
              content: '''
We use the information we collect to:

• Provide and maintain the Service
• Process subscription purchases through Apple/Google
• Improve app functionality and fix bugs
• Provide customer support
• Ensure app security and prevent abuse

We do not use your information for:
• Marketing or advertising
• Selling to third parties
• Building user profiles
• Tracking your activity outside the app
''',
            ),

            // Third-Party Services
            _PolicySection(
              title: 'Third-Party Services',
              content: '''
Nyx uses the following third-party services:

• Apple App Store / Google Play Store: For subscription purchases and app distribution. Payment processing is handled entirely by Apple/Google.

• Device Storage: For storing vault files locally on your device.

• Local Network (WiFi Transfer): When using the WiFi file transfer feature, files are transferred over your local network only. No data is transmitted over the internet.

These services have their own privacy policies. We recommend reviewing Apple's Privacy Policy and Google's Privacy Policy.
These services have their own privacy policies. We recommend reviewing them.
''',
            ),
            // Data Sharing
            _PolicySection(
              title: 'Data Sharing',
              content: '''
We do not share, sell, or rent your personal information to third parties. The only exception is:

• Legal Requirements: We may disclose information if required by law or in response to valid legal requests. Because Nyx does not host your vault files on our servers, we generally do not possess those files to provide.
''',
            ),

            // Your Rights
            _PolicySection(
              title: 'Your Rights',
              content: '''
You have the right to:

• Access your data: All your data is stored on your device - you have full access
• Delete your data: You can delete files individually or wipe all vault data at any time
• Control your data: You decide what files to store in the vault
• Export your data: You can download files from the vault at any time
• Uninstall: You can uninstall the app at any time, which removes all app data from your device

Since we don't store your data on our servers, you have full control over your information.
''',
            ),

            // Data Retention
            _PolicySection(
              title: 'Data Retention',
              content: '''
• Your Files: Stored on your device until you delete them or uninstall the app
• Subscription Information: Retained by Apple/Google according to their policies
• App Usage Data: Anonymous usage data may be retained for app improvement purposes
''',
            ),

            // International Users
            _PolicySection(
              title: 'International Users',
              content: '''
Nyx is designed to work entirely on your device. Your data does not cross international borders because it never leaves your device. All processing happens locally.
Since we don't store your data on our servers, you have full control over your information.
''',
            ),

            // Children's Privacy
            _PolicySection(
              title: 'Children\'s Privacy',
              content: '''
Nyx is not intended for children under the age of 13. We do not knowingly collect personal information from children under 13. If you are a parent or guardian and believe your child has provided us with personal information, please contact us.
''',
            ),

            // Changes to Policy
            _PolicySection(
              title: 'Changes to This Privacy Policy',
              content: '''
We may update our Privacy Policy from time to time. We will notify you of any changes by:

• Posting the new Privacy Policy on this page
• Updating the "Last Updated" date
• In-app notification for significant changes

You are advised to review this Privacy Policy periodically for any changes. Changes to this Privacy Policy are effective when they are posted on this page.
''',
            ),

            // Compliance
            _PolicySection(
              title: 'Compliance',
              content: '''
This Privacy Policy complies with:
• General Data Protection Regulation (GDPR)
• California Consumer Privacy Act (CCPA)
• Children's Online Privacy Protection Act (COPPA)
• Other applicable privacy laws
''',
            ),

            // Disclaimer
            _PolicySection(
              title: 'Disclaimer',
              content: '''
While Nyx implements strong security measures, no system is completely secure. Users are responsible for:
• Keeping their PIN secure
• Not sharing their PIN with others
• Using the app on secure devices
• Understanding that if they forget their PIN, data cannot be recovered
You are advised to review this Privacy Policy periodically for any changes.
''',
            ),
            // Data Sharing
            _PolicySection(
              title: 'Data Sharing',
              content: '''
We do not share, sell, or rent your personal information to third parties. The only exception is:

• Legal Requirements: We may disclose information if required by law or in response to valid legal requests. Because Nyx does not host your vault files on our servers, we generally do not possess those files to provide.
''',
            ),

            // Data Retention
            _PolicySection(
              title: 'Data Retention',
              content: '''
• Your Files: Stored on your device until you delete them or uninstall the app
• Subscription Information: Retained by Apple/Google according to their policies
• App Usage Data: Anonymous usage data may be retained for app improvement purposes
''',
            ),

            // International Users
            _PolicySection(
              title: 'International Users',
              content: '''
Nyx is designed to work entirely on your device. Your data does not cross international borders because it never leaves your device. All processing happens locally.
''',
            ),

            // Contact
            _PolicySection(
              title: 'Contact Us',
              content: '''
If you have any questions about this Privacy Policy, please contact us at:

Email: privacy@nyx.app
Website: https://nyx.app/privacy

We are committed to protecting your privacy and will respond to your inquiries promptly.
''',
            ),

            // Compliance
            _PolicySection(
              title: 'Compliance',
              content: '''
This Privacy Policy complies with:
• General Data Protection Regulation (GDPR)
• California Consumer Privacy Act (CCPA)
• Children's Online Privacy Protection Act (COPPA)
• Other applicable privacy laws
''',
            ),

            // Disclaimer
            _PolicySection(
              title: 'Disclaimer',
              content: '''
While Nyx implements strong security measures, no system is completely secure. Users are responsible for:
• Keeping their PIN secure
• Not sharing their PIN with others
• Using the app on secure devices
• Understanding that if they forget their PIN, data cannot be recovered
We are committed to protecting your privacy and will respond to your inquiries promptly.
''',
            ),

            const SizedBox(height: 32),

            // Footer
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: AppTheme.surfaceVariant,
                borderRadius: BorderRadius.circular(AppTheme.radius),
              ),
              child: Text(
                'By using Nyx, you acknowledge that you have read and understood this Privacy Policy.',
                style: TextStyle(
                  fontSize: 12,
                  color: AppTheme.text.withOpacity(0.7),
                  fontStyle: FontStyle.italic,
                ),
                textAlign: TextAlign.center,
              ),
            ),

            const SizedBox(height: 24),
          ],
        ),
      ),
    );
  }
}

class _PolicySection extends StatelessWidget {
  final String title;
  final String content;

  const _PolicySection({
    required this.title,
    required this.content,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: const TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.w700,
              color: AppTheme.text,
            ),
          ),
          const SizedBox(height: 12),
          Text(
            content.trim(),
            style: TextStyle(
              fontSize: 15,
              color: AppTheme.text.withOpacity(0.9),
              height: 1.6,
            ),
          ),
        ],
      ),
    );
  }
}
