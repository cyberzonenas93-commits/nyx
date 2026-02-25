import 'dart:convert';
import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart';

/// Ad blocker service with EasyList and uBlock-style filtering
class AdBlockerService {
  static final AdBlockerService _instance = AdBlockerService._internal();
  factory AdBlockerService() => _instance;
  AdBlockerService._internal();

  Set<String> _adDomains = {};
  Set<String> _trackingDomains = {};
  List<String> _adSelectors = [];
  bool _isInitialized = false;

  /// Initialize ad blocker with blocklists
  Future<void> initialize() async {
    if (_isInitialized) return;

    try {
      // Load built-in ad domains (EasyList-style)
      _adDomains = {
        // Google Ads
        'doubleclick.net',
        'googlesyndication.com',
        'googleadservices.com',
        'googleads.g.doubleclick.net',
        'adservice.google',
        'adsafeprotected.com',
        
        // Major ad networks
        'advertising.com',
        'adnxs.com',
        'adform.net',
        'adsrvr.org',
        'adtechus.com',
        '2mdn.net',
        'advertising.com',
        'amazon-adsystem.com',
        'moatads.com',
        'outbrain.com',
        'taboola.com',
        'bidswitch.net',
        'criteo.com',
        'rubiconproject.com',
        'pubmatic.com',
        'openx.net',
        'indexexchange.com',
        'sovrn.com',
        
        // Social media tracking
        'facebook.com/tr',
        'facebook.net',
        'fbcdn.net',
        'analytics.twitter.com',
        'ads-twitter.com',
        'adsapi.snapchat.com',
        
        // Analytics & Tracking
        'google-analytics.com',
        'googletagmanager.com',
        'googletagservices.com',
        'scorecardresearch.com',
        'quantserve.com',
        'quantcast.com',
        
        // Video ads
        'googlevideo.com',
        'youtube.com/api/stats',
        'youtube.com/ptracking',
        
        // Malware & scams
        'malware.com',
        'phishing.com',
      };

      // Tracking domains
      _trackingDomains = {
        'analytics.google.com',
        'www.google-analytics.com',
        'googletagmanager.com',
        'doubleclick.net',
        'facebook.com/tr',
        'ads-twitter.com',
        'scorecardresearch.com',
        'quantserve.com',
      };

      // CSS selectors for ad elements (uBlock-style)
      _adSelectors = [
        // Common ad class/ID patterns
        '[class*="ad"]',
        '[id*="ad"]',
        '[class*="advertisement"]',
        '[id*="advertisement"]',
        '[class*="banner"]',
        '[id*="banner"]',
        '[class*="promo"]',
        '[id*="promo"]',
        '[class*="sponsor"]',
        '[id*="sponsor"]',
        
        // Data attributes
        '[data-ad]',
        '[data-ads]',
        '[data-ad-unit]',
        
        // Common ad containers
        '.ad-wrapper',
        '.ad-container',
        '.ad-box',
        '.ad-banner',
        '#ad-wrapper',
        '#ad-container',
        '#ad-box',
        '#ad-banner',
        
        // Iframes from ad networks
        'iframe[src*="doubleclick"]',
        'iframe[src*="googlesyndication"]',
        'iframe[src*="ads"]',
        'iframe[src*="advertising"]',
        'iframe[src*="adnxs"]',
        'iframe[src*="openx"]',
        'iframe[src*="pubmatic"]',
      ];

      _isInitialized = true;
      debugPrint('[AdBlocker] Initialized with ${_adDomains.length} ad domains');
    } catch (e) {
      debugPrint('[AdBlocker] Error initializing: $e');
    }
  }

  /// Check if URL should be blocked
  bool shouldBlockUrl(String url) {
    if (!_isInitialized) return false;
    
    try {
      final uri = Uri.parse(url);
      final host = uri.host.toLowerCase();
      
      // Check ad domains
      if (_adDomains.any((domain) => host.contains(domain))) {
        return true;
      }
      
      // Check tracking domains
      if (_trackingDomains.any((domain) => host.contains(domain))) {
        return true;
      }
      
      // Check path patterns
      final path = uri.path.toLowerCase();
      if (path.contains('/ads/') ||
          path.contains('/advertisement/') ||
          path.contains('/ad-') ||
          path.contains('/ads?') ||
          path.contains('/tracking') ||
          path.contains('/analytics')) {
        return true;
      }
      
      return false;
    } catch (e) {
      return false;
    }
  }

  /// Get JavaScript for blocking ads
  String getAdBlockerScript() {
    final selectorsJson = jsonEncode(_adSelectors);
    final adDomainsJson = jsonEncode(_adDomains.toList());
    return '''
      (function() {
        try {
          function initAdBlocker() {
            const adSelectors = $selectorsJson;
            const adDomains = $adDomainsJson;
            let adsBlocked = 0;
            
            function blockAds() {
              if (!document || !document.querySelectorAll) return;
              
              try {
                adSelectors.forEach(function(selector) {
                  try {
                    var elements = document.querySelectorAll(selector);
                    for (var i = 0; i < elements.length; i++) {
                      var el = elements[i];
                      if (el && el.style) {
                        el.style.display = 'none';
                        if (el.parentNode) {
                          el.parentNode.removeChild(el);
                        }
                        adsBlocked++;
                      }
                    }
                  } catch (e) {
                    // Ignore selector errors
                  }
                });
              } catch (e) {
                console.log('[AdBlocker] Error blocking ads:', e);
              }
              
              // Block ad iframes
              try {
                var iframes = document.querySelectorAll('iframe');
                for (var i = 0; i < iframes.length; i++) {
                  var iframe = iframes[i];
                  try {
                    var src = iframe.src || iframe.getAttribute('src') || '';
                    if (src.indexOf('doubleclick') !== -1 ||
                        src.indexOf('googlesyndication') !== -1 ||
                        src.indexOf('/ads/') !== -1 ||
                        src.indexOf('advertising') !== -1 ||
                        src.indexOf('adnxs') !== -1 ||
                        src.indexOf('openx') !== -1) {
                      iframe.style.display = 'none';
                      if (iframe.parentNode) {
                        iframe.parentNode.removeChild(iframe);
                      }
                      adsBlocked++;
                    }
                  } catch (e) {}
                }
              } catch (e) {}
            }
            
            // Run immediately if DOM is ready
            if (document.readyState === 'loading') {
              document.addEventListener('DOMContentLoaded', function() {
                blockAds();
              });
            } else {
              blockAds();
            }
            
            // Watch for dynamically added ads
            try {
              if (typeof MutationObserver !== 'undefined') {
                var observer = new MutationObserver(function(mutations) {
                  blockAds();
                });
                
                var target = document.body || document.documentElement;
                if (target) {
                  observer.observe(target, {
                    childList: true,
                    subtree: true,
                    attributes: true,
                    attributeFilter: ['class', 'id', 'src']
                  });
                }
                
                // Run periodically to catch missed ads
                setInterval(blockAds, 1000);
              }
            } catch (e) {
              console.log('[AdBlocker] Error setting up observer:', e);
            }
            
            // Block fetch/XHR requests to ad domains
            try {
              if (window.fetch) {
                var originalFetch = window.fetch;
                window.fetch = function() {
                  var url = arguments[0];
                  if (typeof url === 'string' && adDomains) {
                    for (var i = 0; i < adDomains.length; i++) {
                      if (url.indexOf(adDomains[i]) !== -1) {
                        console.log('[AdBlocker] Blocked fetch:', url);
                        return Promise.reject(new Error('Blocked by ad blocker'));
                      }
                    }
                  }
                  return originalFetch.apply(this, arguments);
                };
              }
              
              if (XMLHttpRequest && XMLHttpRequest.prototype) {
                var originalXHROpen = XMLHttpRequest.prototype.open;
                XMLHttpRequest.prototype.open = function() {
                  var url = arguments[1];
                  if (typeof url === 'string' && adDomains) {
                    for (var i = 0; i < adDomains.length; i++) {
                      if (url.indexOf(adDomains[i]) !== -1) {
                        console.log('[AdBlocker] Blocked XHR:', url);
                        return;
                      }
                    }
                  }
                  return originalXHROpen.apply(this, arguments);
                };
              }
            } catch (e) {
              console.log('[AdBlocker] Error blocking requests:', e);
            }
          }
          
          // Wait for DOM if needed
          if (document.readyState === 'loading') {
            document.addEventListener('DOMContentLoaded', initAdBlocker);
          } else {
            initAdBlocker();
          }
        } catch (e) {
          console.log('[AdBlocker] Error initializing:', e);
        }
      })();
    ''';
  }

  /// Get list of ad domains
  Set<String> get adDomains => _adDomains;
  
  /// Get list of tracking domains
  Set<String> get trackingDomains => _trackingDomains;
  
  /// Get ad selectors
  List<String> get adSelectors => _adSelectors;
}
