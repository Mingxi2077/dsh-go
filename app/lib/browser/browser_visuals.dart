import 'package:flutter/services.dart';

/// Native, in-memory images only. This channel is never exposed to web pages.
abstract class BrowserVisualPlatform {
  static BrowserVisualPlatform instance = MethodChannelBrowserVisualPlatform();
  static const maxBytes = 2 * 1024 * 1024;
  Future<Uint8List?> capture(int id, Uri expectedUrl, int width);
  Future<Uint8List?> icon(int id, Uri expectedUrl);
}

class MethodChannelBrowserVisualPlatform extends BrowserVisualPlatform {
  MethodChannelBrowserVisualPlatform([MethodChannel? channel])
    : _channel = channel ?? const MethodChannel('dsh/islands');
  final MethodChannel _channel;

  Future<Uint8List?> _image(String method, int id, Uri url, {int? width}) async {
    try {
      final bytes = await _channel.invokeMethod<Object>(method, {'id': id, 'url': url.toString(), 'width': ?width});
      return bytes is Uint8List && bytes.isNotEmpty && bytes.length <= BrowserVisualPlatform.maxBytes ? bytes : null;
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }

  @override
  Future<Uint8List?> capture(int id, Uri expectedUrl, int width) =>
      _image('browserPreview', id, expectedUrl, width: width.clamp(160, 600));
  @override
  Future<Uint8List?> icon(int id, Uri expectedUrl) => _image('browserSiteIcon', id, expectedUrl);
}
