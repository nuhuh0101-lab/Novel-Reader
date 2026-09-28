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

  EpubElement({
    required this.type,
    required this.text,
    required this.html,
  });
}

class EpubPageElement {
  final EpubElementType type;
  final String text;

  EpubPageElement({
    required this.type,
    required this.text,
  });
}

class EpubPage {
   final List<EpubPageElement> elements;

  EpubPage({
    required this.elements,
  });
}