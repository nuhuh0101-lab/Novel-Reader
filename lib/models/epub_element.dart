import 'dart:typed_data';

enum EpubElementType {
  heading,
  paragraph,
  image,
  other,
}

class EpubElement {
  final EpubElementType type;
  final String text;
  final String html;
  final Uint8List? imageBytes;

  EpubElement({
    required this.type,
    required this.text,
    required this.html,
    this.imageBytes
  });
}

class EpubPageElement {
  final EpubElementType type;
  final String text;
  final Uint8List? imageBytes;

  EpubPageElement({
    required this.type,
    required this.text,
    this.imageBytes,
  });
}

class EpubPage {
   final List<EpubPageElement> elements;

  EpubPage({
    required this.elements,
  });
}