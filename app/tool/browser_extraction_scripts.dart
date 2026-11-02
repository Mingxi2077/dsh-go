// dart run tool/browser_extraction_scripts.dart > /tmp/browser-scripts.json
import 'dart:convert';
import 'dart:io';

import 'package:dsh_app/browser/browser_content.dart';

void main() => stdout.writeln(
  jsonEncode({
    'page': BrowserContentReader.extractionScript(),
    'selection': BrowserContentReader.extractionScript(selection: true),
  }),
);
