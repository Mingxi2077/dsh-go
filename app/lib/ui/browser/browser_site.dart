// How 网页 names and marks a site: its host without `www.`, and a round mark.
// The mark is the site's own favicon when browserSiteIconProvider finds one
// (only the site's origin is asked, never the page's full address), else its
// first letter in an identity colour picked by the host.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../browser/browser_site_icons.dart';
import '../theme/app_icons.dart';
import '../theme/theme.dart';

/// A site as people read it: the host without `www.`.
String browserSite(Uri url) {
  final host = url.host.toLowerCase();
  return host.startsWith('www.') ? host.substring(4) : host;
}

/// [title], or the site when the page has none.
String browserTitle(String title, Uri url) => title.trim().isEmpty ? browserSite(url) : title.trim();

/// The part of [url] its icon is looked up by: scheme, host and port only.
Uri? browserSiteOrigin(Uri url) {
  if ((url.scheme != 'https' && url.scheme != 'http') || url.host.isEmpty) return null;
  return Uri(scheme: url.scheme, host: url.host.toLowerCase(), port: url.hasPort ? url.port : null, path: '/');
}

class BrowserSiteMark extends ConsumerWidget {
  const BrowserSiteMark({super.key, this.url, this.size = 32});

  /// Null: the home page.
  final Uri? url;
  final double size;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final url = this.url;
    if (url == null) {
      return SizedBox.square(
        dimension: size,
        child: DecoratedBox(
          decoration: ShapeDecoration(color: scheme.onSurface.withValues(alpha: 0.06), shape: const CircleBorder()),
          child: Icon(AppIcons.home, size: size * 0.56, color: scheme.onSurfaceVariant),
        ),
      );
    }
    final origin = browserSiteOrigin(url);
    final icon = origin == null ? null : ref.watch(browserSiteIconProvider(origin)).value;
    final letter = _Letter(url: url, size: size);
    if (icon == null) return letter;
    return ExcludeSemantics(
      child: SizedBox.square(
        dimension: size,
        child: DecoratedBox(
          decoration: ShapeDecoration(
            color: scheme.surfaceContainerLowest,
            shape: CircleBorder(side: BorderSide(color: scheme.outlineVariant.withValues(alpha: 0.5), width: 0.5)),
          ),
          child: Padding(
            padding: EdgeInsets.all(size * 0.18),
            child: Image.memory(
              icon,
              gaplessPlayback: true,
              filterQuality: FilterQuality.medium,
              errorBuilder: (_, _, _) => letter,
            ),
          ),
        ),
      ),
    );
  }
}

class _Letter extends StatelessWidget {
  const _Letter({required this.url, required this.size});

  final Uri url;
  final double size;

  @override
  Widget build(BuildContext context) {
    final colors = DshColors.of(context);
    final site = browserSite(url);
    final tint = site.codeUnits.fold<int>(0, (a, c) => (a * 31 + c) & 0x7fffffff) % colors.identity.length;
    final letter = site.isEmpty ? '?' : String.fromCharCode(site.runes.first).toUpperCase();
    return ExcludeSemantics(
      child: SizedBox.square(
        dimension: size,
        child: DecoratedBox(
          decoration: ShapeDecoration(color: colors.identity[tint], shape: const CircleBorder()),
          child: Center(
            child: Text(
              letter,
              textScaler: TextScaler.noScaling,
              style: TextStyle(
                fontSize: size * 0.44,
                height: 1,
                fontWeight: FontWeight.w600,
                color: colors.onIdentity[tint],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
