import 'package:flutter/material.dart';
import '../../../app/theme.dart';
import '../../../shared/widgets/secure_button.dart';
import '../../../features/subscription/pages/subscription_setup_page.dart';

/// Detailed onboarding tutorial for Nyx - first-time user experience
class OnboardingPage extends StatefulWidget {
  final bool
      isTutorialMode; // If true, just show tutorial without completing onboarding

  const OnboardingPage({super.key, this.isTutorialMode = false});

  @override
  State<OnboardingPage> createState() => _OnboardingPageState();
}

class _OnboardingPageState extends State<OnboardingPage> {
  final PageController _pageController = PageController();
  int _currentPage = 0;
  bool _hasScrolledToBottom =
      false; // Track if current page is scrolled to bottom

  final List<OnboardingStep> _steps = [
    OnboardingStep(
      title: 'Welcome to Nyx',
      description:
          'Nyx is your private vault for photos, videos, and files. Access is protected with your unlock method, and imported files stay in app-managed storage on your device.',
      icon: Icons.security,
      detailed: true,
    ),
    OnboardingStep(
      title: 'PIN Protection',
      description:
          'Access your vault with a PIN only you know:\n\n1. Enter your PIN on the unlock screen\n2. Your vault opens with your private files\n3. The app locks automatically when you leave\n\nOnly you can access your vault.',
      icon: Icons.lock,
      detailed: true,
    ),
    OnboardingStep(
      title: 'Primary Vault',
      description:
          'The first vault you create becomes your Primary Vault:\n\n• Your Primary Vault manages all your vaults\n• You can create additional vaults from within your Primary Vault\n• Each vault has its own trigger code and PIN\n• Access different vaults by entering their unique trigger codes\n• Recover trigger codes and PINs from your Primary Vault\n\nYour Primary Vault is your master control center!',
      icon: Icons.folder_special,
      detailed: true,
    ),
    OnboardingStep(
      title: 'Your Private Vault',
      description:
          'Store and organize your files:\n\n• Import photos, videos, and documents\n• Create albums to organize content\n• Swipe between files\n• Capture photos and videos directly\n\nFiles are stored securely on your device.',
      icon: Icons.folder_outlined,
      detailed: true,
    ),
    OnboardingStep(
      title: 'Built-in Browser',
      description:
          'Private browser with essential features:\n\n• Download videos and audio from websites\n• Bookmark your favorite sites\n• Tab management\n• Session persistence\n\nDownloads are saved directly to your vault.',
      icon: Icons.language,
      detailed: true,
    ),
    OnboardingStep(
      title: 'File Transfer',
      description:
          'Transfer files wirelessly:\n\n• Share files between phone and computer\n• Works on the same WiFi network\n• Simple web interface\n• QR code for quick access\n\nPerfect for large files and backups.',
      icon: Icons.wifi,
      detailed: true,
    ),
    OnboardingStep(
      title: 'Media Tools',
      description:
          'Powerful media features:\n\n• Play videos and audio directly in vault\n• Media converter - convert videos to audio\n• Organize with albums and folders\n• View photos in full screen\n• Swipe between media files\n\nAll tools work directly in your vault.',
      icon: Icons.play_circle_outline,
      detailed: true,
    ),
    OnboardingStep(
      title: 'Organize & Manage',
      description:
          'Keep your vault organized:\n\n• Create folders to organize files\n• Use albums to filter by type\n• Long-press to select multiple files\n• Move files between folders\n• Download files back to device\n• Track downloads in Downloads page\n\nFull control over your files!',
      icon: Icons.folder_outlined,
      detailed: true,
    ),
    OnboardingStep(
      title: 'Security & Settings',
      description:
          'Advanced security features:\n\n• Change PIN anytime\n• Update trigger code\n• Panic switch - lock when device face-down\n• Storage location selection (iCloud/Local)\n• Auto-lock when app goes to background\n• Lock vault manually anytime\n\nYour privacy is protected!',
      icon: Icons.security,
      detailed: true,
    ),
    OnboardingStep(
      title: 'You\'re All Set!',
      description:
          'Nyx is ready to protect your privacy.\n\nRemember:\n• Enter your PIN on the unlock screen to open your vault\n• Files are stored securely on your device\n• Primary vault manages all vaults\n• Premium users can create multiple vaults\n• All features work offline\n\nTap "Get Started" to begin!',
      icon: Icons.check_circle_outline,
      detailed: true,
    ),
  ];

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  void _nextPage() {
    if (_currentPage < _steps.length - 1) {
      _pageController.nextPage(
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeInOut,
      );
    } else {
      _completeOnboarding();
    }
  }

  void _previousPage() {
    if (_currentPage > 0) {
      _pageController.previousPage(
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeInOut,
      );
    }
  }

  void _skipOnboarding() {
    _completeOnboarding();
  }

  Future<void> _completeOnboarding() async {
    if (widget.isTutorialMode) {
      // Tutorial mode - just go back to settings
      if (mounted) {
        Navigator.of(context).pop();
      }
    } else {
      // Real onboarding - navigate to subscription setup
      if (mounted) {
        Navigator.of(context).pushReplacement(
          MaterialPageRoute(
            builder: (context) => const SubscriptionSetupPage(),
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop:
          widget.isTutorialMode, // Allow back navigation only in tutorial mode
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop || widget.isTutorialMode) return;
        // During onboarding, prevent going back - user must complete setup
        // Show a dialog to confirm if they want to exit
        final shouldExit = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            backgroundColor: AppTheme.surface,
            title: const Text(
              'Exit Setup?',
              style: TextStyle(color: AppTheme.text),
            ),
            content: Text(
              'You need to complete the setup to use the app. Are you sure you want to exit?',
              style: TextStyle(color: AppTheme.text.withOpacity(0.7)),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(false),
                child: const Text('Cancel',
                    style: TextStyle(color: AppTheme.text)),
              ),
              TextButton(
                onPressed: () => Navigator.of(context).pop(true),
                child: const Text('Exit',
                    style: TextStyle(color: AppTheme.warning)),
              ),
            ],
          ),
        );

        if (shouldExit == true && mounted) {
          // Exit the app or stay on onboarding
          // For now, just prevent navigation
        }
      },
      child: Scaffold(
        backgroundColor: AppTheme.primary,
        body: SafeArea(
          child: Column(
            children: [
              // Header with skip
              Padding(
                padding: const EdgeInsets.all(16),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    if (_currentPage > 0)
                      TextButton.icon(
                        onPressed: _previousPage,
                        icon:
                            const Icon(Icons.arrow_back, color: AppTheme.text),
                        label: const Text(
                          'Back',
                          style: TextStyle(color: AppTheme.text),
                        ),
                      )
                    else
                      const SizedBox(width: 80),
                    if (_currentPage < _steps.length - 1)
                      TextButton(
                        onPressed: _skipOnboarding,
                        child: const Text(
                          'Skip',
                          style: TextStyle(color: AppTheme.text),
                        ),
                      )
                    else
                      const SizedBox(width: 80),
                  ],
                ),
              ),

              // Page content
              Expanded(
                child: PageView.builder(
                  controller: _pageController,
                  onPageChanged: (index) {
                    setState(() {
                      _currentPage = index;
                      _hasScrolledToBottom =
                          false; // Reset scroll state on page change
                    });
                    // Trigger scroll check for new page after a brief delay
                    Future.delayed(const Duration(milliseconds: 100), () {
                      if (mounted) {
                        // This will be handled by the widget's post-frame callback
                      }
                    });
                  },
                  itemCount: _steps.length,
                  itemBuilder: (context, index) {
                    final step = _steps[index];
                    return _OnboardingStepWidget(
                      step: step,
                      onScrollToBottomChanged: (hasScrolled) {
                        if (mounted && _currentPage == index) {
                          setState(() {
                            _hasScrolledToBottom = hasScrolled;
                          });
                        }
                      },
                    );
                  },
                ),
              ),

              // Page indicators
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 16),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: List.generate(
                    _steps.length,
                    (index) => Container(
                      margin: const EdgeInsets.symmetric(horizontal: 4),
                      width: _currentPage == index ? 24 : 8,
                      height: 8,
                      decoration: BoxDecoration(
                        color: _currentPage == index
                            ? AppTheme.accent
                            : AppTheme.surfaceVariant,
                        borderRadius: BorderRadius.circular(4),
                      ),
                    ),
                  ),
                ),
              ),

              // Navigation buttons
              Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 32, vertical: 16),
                child: Row(
                  children: [
                    if (_currentPage > 0)
                      Expanded(
                        child: OutlinedButton(
                          onPressed: () {
                            _previousPage();
                          },
                          style: OutlinedButton.styleFrom(
                            padding: const EdgeInsets.symmetric(vertical: 16),
                          ),
                          child: const Text('Previous'),
                        ),
                      ),
                    if (_currentPage > 0) const SizedBox(width: 16),
                    Expanded(
                      flex: _currentPage == 0 ? 1 : 1,
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          SecureButton(
                            text: _currentPage < _steps.length - 1
                                ? 'Next'
                                : 'Get Started',
                            icon: _currentPage < _steps.length - 1
                                ? Icons.arrow_forward
                                : Icons.check,
                            onPressed: _hasScrolledToBottom
                                ? () {
                                    _nextPage();
                                  }
                                : null,
                          ),
                          if (!_hasScrolledToBottom) ...[
                            const SizedBox(height: 8),
                            Text(
                              'Scroll to the bottom to continue',
                              style: TextStyle(
                                fontSize: 12,
                                color: AppTheme.text.withOpacity(0.6),
                                fontStyle: FontStyle.italic,
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 16),
            ],
          ),
        ),
      ),
    );
  }
}

class _OnboardingStepWidget extends StatefulWidget {
  final OnboardingStep step;
  final ValueChanged<bool>? onScrollToBottomChanged;

  const _OnboardingStepWidget({
    required this.step,
    this.onScrollToBottomChanged,
  });

  @override
  State<_OnboardingStepWidget> createState() => _OnboardingStepWidgetState();
}

class _OnboardingStepWidgetState extends State<_OnboardingStepWidget> {
  final ScrollController _scrollController = ScrollController();
  bool _showScrollIndicator = true;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_checkScrollPosition);
    // Check initial scroll position after build
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _checkScrollPosition();
      // Also check after a short delay to ensure layout is complete
      Future.delayed(const Duration(milliseconds: 200), () {
        if (mounted) {
          _checkScrollPosition();
        }
      });
    });
  }

  @override
  void dispose() {
    _scrollController.removeListener(_checkScrollPosition);
    _scrollController.dispose();
    super.dispose();
  }

  void _checkScrollPosition() {
    if (!_scrollController.hasClients) return;

    final maxScroll = _scrollController.position.maxScrollExtent;
    final currentScroll = _scrollController.position.pixels;
    final isAtBottom = currentScroll >= maxScroll - 10; // 10px threshold
    final isScrollable = maxScroll > 0;

    if (mounted) {
      setState(() {
        _showScrollIndicator = !isAtBottom && isScrollable;
      });

      // Notify parent about scroll state
      // If content is not scrollable (fits on screen), consider it as "read"
      widget.onScrollToBottomChanged?.call(isAtBottom || !isScrollable);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        LayoutBuilder(
          builder: (context, constraints) {
            return SingleChildScrollView(
              controller: _scrollController,
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  minHeight: constraints.maxHeight,
                ),
                child: Padding(
                  padding: const EdgeInsets.all(32),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      const SizedBox(height: 32),

                      Center(
                        child: Container(
                          padding: const EdgeInsets.all(32),
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: AppTheme.surface,
                            boxShadow: [
                              BoxShadow(
                                color: AppTheme.accent.withOpacity(0.3),
                                blurRadius: 30,
                                spreadRadius: 5,
                              ),
                            ],
                          ),
                          child: Icon(
                            widget.step.icon,
                            size: 64,
                            color: AppTheme.accent,
                          ),
                        ),
                      ),

                      const SizedBox(height: 48),

                      Center(
                        child: Text(
                          widget.step.title,
                          style: const TextStyle(
                            fontSize: 28,
                            fontWeight: FontWeight.w600,
                            color: AppTheme.text,
                          ),
                          textAlign: TextAlign.center,
                        ),
                      ),

                      const SizedBox(height: 32),

                      Center(
                        child: Text(
                          widget.step.description,
                          style: TextStyle(
                            fontSize: 16,
                            color: AppTheme.text.withOpacity(0.8),
                            height: 1.6,
                          ),
                          textAlign: TextAlign.center,
                        ),
                      ),

                      // Extra padding at bottom to ensure scroll indicator is visible
                      const SizedBox(height: 40),
                    ],
                  ),
                ),
              ),
            );
          },
        ),

        // Subtle scroll indicator - just a fade gradient
        if (_showScrollIndicator)
          Positioned(
            bottom: 0,
            left: 0,
            right: 0,
            child: IgnorePointer(
              child: Container(
                height: 60,
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      AppTheme.primary.withOpacity(0.0),
                      AppTheme.primary.withOpacity(0.6),
                      AppTheme.primary,
                    ],
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

class OnboardingStep {
  final String title;
  final String description;
  final IconData icon;
  final bool detailed;

  OnboardingStep({
    required this.title,
    required this.description,
    required this.icon,
    this.detailed = false,
  });
}
