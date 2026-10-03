import 'dart:typed_data';

import 'package:epub_view/epub_view.dart' as epubx;
import 'package:html/dom.dart' as dom;

class ReaderItem {
  final String type;
  final String? text;
  final Uint8List? image;

  ReaderItem({
    required this.type,
    this.text,
    this.image,
  });
}



class EpubContentExtractor {
  List<ReaderItem> extractContent(
  dom.Document document,
  epubx.EpubBook book,
) {
 
  List<ReaderItem> items = [];

  void processNode(dom.Node node) {

    if (node is! dom.Element) return;

    final tag = node.localName?.toLowerCase();
    final className = node.attributes['class'];


if ([
  'h1',
  'h2',
  'h3',
  'h4',
  'h5',
  'h6',
].contains(tag)) {
  final text = node.text.trim();

  if (text.isNotEmpty) {
    items.add(
      ReaderItem(
        type: 'title',
        text: text,
      ),
    );
  }
}

else if (tag == 'p') {
  final text = node.text.trim();

  if (text.isNotEmpty) {
    items.add(
      ReaderItem(
        type: 'text',
        text: text,
      ),
    );
  }
}

    // Images
    else if (tag == 'img') {

      final src = node.attributes['src'];

      if (src != null) {

        final image =
            book.Content?.Images?[src];

        if (image?.Content != null) {

          items.add(
            ReaderItem(
              type: 'image',
              image: Uint8List.fromList(image!.Content!),
            ),
          );
        }
      }
    }

    else if (tag == 'div') {
  final text = node.text.trim();

  if (text.isNotEmpty) {
    print(
      'DIV TEXT: $text | '
      'CHILDREN: ${node.children.map((e) => e.localName).toList()}',
    );
  }

  final hasMeaningfulChild = node.children.any(
    (child) => [
      'p',
      'h1',
      'h2',
      'h3',
      'h4',
      'h5',
      'h6',
      'img',
    ].contains(child.localName?.toLowerCase()),
  );

  if (!hasMeaningfulChild) {
    if (text.isNotEmpty) {
      items.add(
        ReaderItem(
          type: 'text',
          text: text,
        ),
      );
    }
  }
}

    // Continue through children
    for (var child in node.children) {
      processNode(child);
    }
  }

  processNode(document.body!);

  return items;
}
}