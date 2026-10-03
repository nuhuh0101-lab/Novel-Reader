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
  final bool isCover;

  EpubElement({
    required this.type,
    required this.text,
    required this.html,
    this.imageBytes,
    this.isCover = false,

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