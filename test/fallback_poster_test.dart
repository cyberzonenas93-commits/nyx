import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:nyx/core/services/vault_service.dart';

void main() {
  test('stand-in poster is a 320x180 JPEG', () {
    final bytes = drawFallbackVideoPoster('WEBM');
    final decoded = img.decodeJpg(bytes);
    expect(decoded, isNotNull);
    expect(decoded!.width, 320);
    expect(decoded.height, 180);
    // The play mark is drawn: the centre is much lighter than the corner.
    final centre = decoded.getPixel(160, 78).luminance;
    final corner = decoded.getPixel(4, 4).luminance;
    expect(centre, greaterThan(corner + 100));
  });
}
