import 'dart:io';
import 'package:epub_reader/basic_info.dart';
import 'package:epub_reader/models/epub_element.dart';
import 'package:epub_view/epub_view.dart' as epub;
import 'package:flutter/material.dart';
import 'dart:convert';
import 'dart:typed_data';
import 'package:archive/archive.dart';
import 'package:epubx/epubx.dart' as epubx;
import 'package:flutter_html/flutter_html.dart';
import 'package:xml/xml.dart';
import 'package:image/image.dart' as img;

class ReaderPage extends StatefulWidget {
  final BasicInfo book;
  const ReaderPage({
    super.key,
    required this.book,
    });
  @override
  State<ReaderPage> createState() => _ReaderPageState();
}

class _ReaderPageState extends State<ReaderPage> {
  late epub.EpubController controller;

  final textStyle = TextStyle(
    fontSize: 18,
    fontFamily: 'Roboto',
    fontWeight: FontWeight.normal,
    letterSpacing: 0,
    height: 1.0,
  );

  final headingStyle = TextStyle(
    fontSize: 24,
    fontFamily: 'Roboto',
    fontWeight: FontWeight.bold,
    letterSpacing: 0,
    height: 1.0,
  );

  final paragraphSpacing = 12.0;
  final headingSpacing = 16.0;


  @override
  void initState(){
    super.initState();
    print('READER PAGE INITSTATE');
    controller = epub.EpubController(
    document: loadReaderBook(widget.book.path),
  );
   loadElements();
  }

  Future<epubx.EpubBook> loadReaderBook(String path) async {
  final file = File(path);

  final bytes = await file.readAsBytes();

 try {
  final book = await epubx.EpubReader.readBook(bytes);

final image = book.Content?.Images?['Images/image_rsrc34F.jpg'];

print('IMAGE OBJECT: $image');
print('IMAGE RUNTIME TYPE: ${image.runtimeType}');
print('IMAGE BYTES: ${image?.Content?.length}');


if (image != null) {
  print('FIRST 10 BYTES: ${image.Content!.take(10).toList()}');
}

  final allElements = <EpubElement>[];

  for (final chapter in book.Chapters!) {
    final chapterElements = getChapterElements(chapter, book.Content?.Images);    

    allElements.addAll(chapterElements);
  }

  elements = allElements;

  print('TOTAL ELEMENTS: ${elements.length}');

  return book;
} catch (e) {
    final repairedBytes = await repairMissingNcx(bytes);

    final book = await epubx.EpubReader.readBook(
      repairedBytes,
    );



    return book;
  }
}

List<XmlElement> parseChapterElements(String htmlContent) {
  final document = XmlDocument.parse(htmlContent);

  final images = document.findAllElements('img');

  for (final image in images) {
    print('IMAGE: ${image.outerXml}');
  }

  return document
      .findAllElements('body')
      .expand((body) => body.children.whereType<XmlElement>())
      .toList();
}

List<EpubElement> getChapterElements(
  epubx.EpubChapter chapter,
  Map<String, epubx.EpubByteContentFile>? images,
  ) {
  final xmlElements = parseChapterElements(
    chapter.HtmlContent!,
  );

  return xmlElements
      .map((element) => convertToEpubElement(element, images))
      .toList();
}

EpubElement convertToEpubElement(
  XmlElement element,
  Map<String, epubx.EpubByteContentFile>? images,
) {

  final isImage = element.name.local == 'img';

  final imageElements = element.findElements('img');
  final containsImage = imageElements.isNotEmpty;
  if (containsImage) {
    print('DIV CONTAINS IMAGE: ${imageElements.first.outerXml}');
  }

  final className = element.getAttribute('class');

  EpubElementType type;

  if (isImage || containsImage) {
    type = EpubElementType.image;
  } else if (className == 'heading_s5M') {
    type = EpubElementType.heading;
  } else if (className == 'class_s5P' ||
            className == 'class_s5S') {
    type = EpubElementType.paragraph;
  } else {
    type = EpubElementType.other;
  }

  Uint8List? imageBytes;

  if (isImage || containsImage) {
    final imgElement = isImage
        ? element
        : imageElements.first;

    final src = imgElement.getAttribute('src');

    if (src != null) {
      final imagePath = src.replaceFirst('../', '');

      final content = images?[imagePath]?.Content;

      if (content != null) {
        imageBytes = Uint8List.fromList(content);
      }
    }
  }

  if (imageBytes != null) {
    print('IMAGE BYTES FOUND: ${imageBytes.length}');
  }


  return EpubElement(
    type: type,
    text: element.innerText.trim(),
    html: element.outerXml,
    imageBytes: imageBytes,

  );
}

Future<Uint8List> repairMissingNcx(Uint8List epubBytes) async {
  final archive = ZipDecoder().decodeBytes(epubBytes);
  

  ArchiveFile? findFile(String path) {
    final wanted = normalizeZipPath(path).toLowerCase();

    for (final file in archive) {
      if (!file.isFile) {
        continue;
      }

      if (normalizeZipPath(file.name).toLowerCase() == wanted) {
        return file;
      }
    }

    return null;
  }

  // ------------------------------------------------------------
  // 1. Find content.opf
  // ------------------------------------------------------------

  final containerFile = findFile('META-INF/container.xml');

  if (containerFile == null) {
    throw Exception('container.xml not found');
  }

  final containerXml = XmlDocument.parse(
    utf8.decode(containerFile.content),
  );

  XmlElement? rootFileElement;

  for (final element
      in containerXml.descendants.whereType<XmlElement>()) {
    if (element.name.local == 'rootfile') {
      rootFileElement = element;
      break;
    }
  }

  if (rootFileElement == null) {
    throw Exception('No rootfile found in container.xml');
  }

final opfFileName = rootFileElement.getAttribute('full-path');

if (opfFileName == null) {
  throw Exception('OPF path not found');
}

String opfPath = normalizeZipPath(opfFileName);

ArchiveFile? opfFile = findFile(opfPath);

if (opfFile == null) {
  print('Declared root file not found: $opfPath');
  print('Searching for another OPF file...');

  for (final file in archive) {
    if (!file.isFile) {
      continue;
    }

    if (file.name.toLowerCase().endsWith('.opf')) {
      opfFile = file;
      break;
    }
  }
}

if (opfFile == null) {
  throw Exception('No OPF file found in archive');
}

  opfPath = normalizeZipPath(opfFile.name);

  rootFileElement.setAttribute(
    'full-path',
    opfPath,
  );

final opfXml = XmlDocument.parse(
  utf8.decode(opfFile.content),
);

  final opfDirectory = directoryOf(opfPath);

  // ------------------------------------------------------------
// Repair missing cover image
// ------------------------------------------------------------

Uint8List? coverBytesToAdd;

final existingCover = findFile(
      joinZipPath(opfDirectory, 'image.jpeg'),
    ) ??
    findFile(
      joinZipPath(opfDirectory, 'images/image.jpeg'),
    );

if (existingCover != null) {
  coverBytesToAdd = Uint8List.fromList(
    existingCover.content,
  );
}

  // ------------------------------------------------------------
  // 2. Find spine
  // ------------------------------------------------------------

  XmlElement? spine;

  for (final element
      in opfXml.descendants.whereType<XmlElement>()) {
    if (element.name.local == 'spine') {
      spine = element;
      break;
    }
  }

  if (spine == null) {
    throw Exception('Spine not found');
  }

  final tocId = spine.getAttribute('toc');

  if (tocId == null || tocId.isEmpty) {
    throw Exception('Spine does not contain a TOC ID');
  }

  // ------------------------------------------------------------
  // 3. Remove manifest items whose files don't exist
  // ------------------------------------------------------------

  String? coverId;

  final metaItems = opfXml
      .descendants
      .whereType<XmlElement>()
      .where((element) => element.name.local == 'meta');

  for (final meta in metaItems) {
    if (meta.getAttribute('name')?.toLowerCase() == 'cover') {
      coverId = meta.getAttribute('content');
      break;
    }
  }

  final validManifestIds = <String>{tocId};

  final manifestElements = opfXml
      .descendants
      .whereType<XmlElement>()
      .where((element) => element.name.local == 'item')
      .toList();

  for (final item in manifestElements) {
    final id = item.getAttribute('id');
    final href = item.getAttribute('href');

    if (id == tocId) {
      // Keep the NCX manifest entry because we are going
      // to generate that file ourselves.
      continue;
    }

    if (id == null || href == null) {
      item.remove();
      continue;
    }

    final resolvedPath = joinZipPath(
      opfDirectory,
      Uri.decodeComponent(href),
    );

    final actualFile = findFile(resolvedPath);

  if (actualFile == null) {
    if (id == coverId && coverBytesToAdd != null) {
      print('Preserving missing cover manifest item: $id');
      validManifestIds.add(id);
    } else {
      print('Removing missing EPUB file: $resolvedPath');
      item.remove();
    }
  } else {
    validManifestIds.add(id);
  }
  }

  // ------------------------------------------------------------
  // 4. Remove spine entries pointing to removed files
  // ------------------------------------------------------------

  final spineItems = spine.children
      .whereType<XmlElement>()
      .where((element) => element.name.local == 'itemref')
      .toList();

  for (final itemref in spineItems) {
    final idref = itemref.getAttribute('idref');

    if (idref == null ||
        !validManifestIds.contains(idref)) {
      itemref.remove();
    }
  }

  // ------------------------------------------------------------
  // 5. Rebuild manifest map AFTER removing bad entries
  // ------------------------------------------------------------

  final manifestItems = <String, XmlElement>{};

  for (final item in opfXml
      .descendants
      .whereType<XmlElement>()
      .where((element) => element.name.local == 'item')) {
    final id = item.getAttribute('id');

    if (id != null) {
      manifestItems[id] = item;
    }
  }

  // ------------------------------------------------------------
  // 6. Find the TOC location
  // ------------------------------------------------------------

  final tocManifestItem = manifestItems[tocId];

  if (tocManifestItem == null) {
    throw Exception('TOC manifest item not found');
  }

  final tocHref = tocManifestItem.getAttribute('href');

  if (tocHref == null) {
    throw Exception('TOC href not found');
  }

  final tocPath = joinZipPath(
    opfDirectory,
    Uri.decodeComponent(tocHref),
  );

  // ------------------------------------------------------------
  // 7. Generate NCX
  // ------------------------------------------------------------

  final ncx = StringBuffer();

  ncx.write(
    '<?xml version="1.0" encoding="UTF-8"?>',
  );

  ncx.write(
    '<ncx '
    'xmlns="http://www.daisy.org/z3986/2005/ncx/" '
    'version="2005-1">',
  );

  ncx.write('<head></head>');

  ncx.write(
    '<docTitle>'
    '<text>Book</text>'
    '</docTitle>',
  );

  ncx.write('<navMap>');

  int playOrder = 1;

  final currentSpineItems = spine.children
      .whereType<XmlElement>()
      .where((element) => element.name.local == 'itemref')
      .toList();

  for (final itemref in currentSpineItems) {
    final idref = itemref.getAttribute('idref');

    if (idref == null) {
      continue;
    }

    final manifestItem = manifestItems[idref];

    if (manifestItem == null) {
      continue;
    }

    final href = manifestItem.getAttribute('href');

    if (href == null) {
      continue;
    }

    final documentPath = joinZipPath(
      opfDirectory,
      Uri.decodeComponent(href),
    );

    // Extra safety check.
    final documentFile = findFile(documentPath);

    if (documentFile == null) {
      continue;
    }

    final src = relativeZipPath(
      directoryOf(tocPath),
      documentPath,
    );

    final title = getChapterLabel(
      archive,
      documentPath,
      href,
    );

    ncx.write(
      '<navPoint '
      'id="navPoint-$playOrder" '
      'playOrder="$playOrder">',
    );

    ncx.write(
      '<navLabel>'
      '<text>${escapeXml(title)}</text>'
      '</navLabel>',
    );

    ncx.write(
      '<content src="${escapeXml(src)}"/>',
    );

    ncx.write('</navPoint>');

    playOrder++;
  }

  ncx.write('</navMap>');
  ncx.write('</ncx>');

// ------------------------------------------------------------
// 8. Build a NEW repaired archive
// ------------------------------------------------------------

final repairedArchive = Archive();

final opfPathLower = normalizeZipPath(opfPath).toLowerCase();
final containerPathLower = 'meta-inf/container.xml';
final tocPathLower = normalizeZipPath(tocPath).toLowerCase();

final coverPath = joinZipPath(
  opfDirectory,
  'cover.jpeg',
);

final coverPathLower = normalizeZipPath(
  coverPath,
).toLowerCase();


// ------------------------------------------------------------
// 9. Add mimetype FIRST and without compression
// ------------------------------------------------------------

final originalMimetype = findFile('mimetype');

if (originalMimetype != null) {
  final mimetypeBytes = originalMimetype.content;

  final mimetypeFile = ArchiveFile.noCompress(
    'mimetype',
    mimetypeBytes.length,
    mimetypeBytes,
  );

  repairedArchive.addFile(mimetypeFile);
}


// ------------------------------------------------------------
// 10. Copy the remaining original files
// ------------------------------------------------------------

for (final file in archive.files) {
  if (!file.isFile) {
    continue;
  }

  final filePath = normalizeZipPath(
    file.name,
  ).toLowerCase();

  // Skip files that we are going to replace.
  if (filePath == 'mimetype' ||
      filePath == containerPathLower ||
      filePath == opfPathLower ||
      filePath == tocPathLower ||
      filePath == coverPathLower) {
    continue;
  }

  final content = file.content;

  final copiedFile = ArchiveFile(
    file.name,
    content.length,
    content,
  );

  copiedFile.compress = file.compress;
  copiedFile.lastModTime = file.lastModTime;
  copiedFile.mode = file.mode;

  repairedArchive.addFile(copiedFile);
}


// ------------------------------------------------------------
// 11. Add repaired container.xml
// ------------------------------------------------------------

final repairedContainerBytes = utf8.encode(
  containerXml.toXmlString(),
);

repairedArchive.addFile(
  ArchiveFile(
    'META-INF/container.xml',
    repairedContainerBytes.length,
    repairedContainerBytes,
  ),
);


// ------------------------------------------------------------
// 12. Add repaired content.opf
// ------------------------------------------------------------

final repairedOpfBytes = utf8.encode(
  opfXml.toXmlString(),
);

repairedArchive.addFile(
  ArchiveFile(
    opfPath,
    repairedOpfBytes.length,
    repairedOpfBytes,
  ),
);


// ------------------------------------------------------------
// 13. Add generated toc.ncx
// ------------------------------------------------------------

final ncxBytes = utf8.encode(
  ncx.toString(),
);

repairedArchive.addFile(
  ArchiveFile(
    tocPath,
    ncxBytes.length,
    ncxBytes,
  ),
);


// ------------------------------------------------------------
// 14. Add repaired cover if we found one
// ------------------------------------------------------------

if (coverBytesToAdd != null) {
  repairedArchive.addFile(
    ArchiveFile(
      coverPath,
      coverBytesToAdd!.length,
      coverBytesToAdd!,
    ),
  );

  print(
    'Added repaired cover: $coverPath',
  );
}


// ------------------------------------------------------------
// 15. Encode repaired EPUB
// ------------------------------------------------------------

final encoded = ZipEncoder().encode(
  repairedArchive,
);

if (encoded == null) {
  throw Exception(
    'Failed to encode repaired EPUB',
  );
}

  return Uint8List.fromList(encoded);
}

  String normalizeZipPath(String path) {
  path = Uri.decodeComponent(
    path.replaceAll('\\', '/'),
  );

  final parts = <String>[];

  for (final part in path.split('/')) {
    if (part.isEmpty || part == '.') {
      continue;
    }

    if (part == '..') {
      if (parts.isNotEmpty) {
        parts.removeLast();
      }
    } else {
      parts.add(part);
    }
  }

  return parts.join('/');
  }

  

  String directoryOf(String path) {
  final normalized = normalizeZipPath(path);
  final index = normalized.lastIndexOf('/');

  if (index == -1) {
    return '';
  }

  return normalized.substring(0, index);
  }



  String joinZipPath(String directory, String path) {
  if (directory.isEmpty) {
    return normalizeZipPath(path);
  }

  return normalizeZipPath('$directory/$path');
  }



  String relativeZipPath(String fromDirectory, String targetPath) {
  final fromParts = normalizeZipPath(
    fromDirectory,
  ).split('/').where((e) => e.isNotEmpty).toList();

  final targetParts = normalizeZipPath(
    targetPath,
  ).split('/').where((e) => e.isNotEmpty).toList();

  int common = 0;

  while (common < fromParts.length &&
      common < targetParts.length &&
      fromParts[common] == targetParts[common]) {
    common++;
  }

  final result = <String>[];

  for (int i = common; i < fromParts.length; i++) {
    result.add('..');
  }

  result.addAll(targetParts.sublist(common));

  return result.join('/');
  }



  String escapeXml(String value) {
  return value
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;')
      .replaceAll('"', '&quot;')
      .replaceAll("'", '&apos;');
  }



  String getChapterLabel(
  Archive archive,
  String documentPath,
  String fallbackHref,
) {
  ArchiveFile? file;

  final wanted = normalizeZipPath(
    documentPath,
  ).toLowerCase();

  for (final entry in archive) {
    if (normalizeZipPath(entry.name).toLowerCase() == wanted) {
      file = entry;
      break;
    }
  }

  if (file != null) {
    try {
      final document = XmlDocument.parse(
        utf8.decode(file.content),
      );

      for (final element
          in document.descendants.whereType<XmlElement>()) {
        if (element.name.local == 'title') {
          final title = element.innerText.trim();

          if (title.isNotEmpty) {
            return title;
          }
        }
      }

      for (final heading in ['h1', 'h2', 'h3']) {
        for (final element
            in document.descendants.whereType<XmlElement>()) {
          if (element.name.local == heading) {
            final text = element.innerText.trim();

            if (text.isNotEmpty) {
              return text;
            }
          }
        }
      }
    } catch (_) {
      // Fall back to filename.
    }
  }

  final fileName = fallbackHref.split('/').last;

  return fileName
      .replaceFirst(RegExp(r'\.[^.]+$'), '')
      .replaceAll('_', ' ');
  }

  @override
  void dispose() {
  controller.dispose();
  super.dispose();
  }

  List<EpubElement> elements = [];
  List<EpubPage> pages = [];
  int currentPage = 0;
  bool isPaginating = false;
  double? lastPageWidth;
  double? lastPageHeight;


String getTextThatFits(
  String text,
  double pageWidth,
  double pageHeight,
  TextStyle style,
  BuildContext context,
) {
  final painter = TextPainter(
    text: TextSpan(
      text: text,
      style: style,
    ),
    textDirection: TextDirection.ltr,
    textScaler: MediaQuery.textScalerOf(context),
  );

  painter.layout(maxWidth: pageWidth);

  final lines = painter.computeLineMetrics();

  int endOffset = 0;
  double usedHeight = 0;

  for (final line in lines) {
    final lineHeight = line.height;

    if (usedHeight + lineHeight <= pageHeight) {
      usedHeight += lineHeight;

      final position = painter.getPositionForOffset(
         Offset(0, line.baseline - line.height / 2),
      );

      final boundary = painter.getLineBoundary(position);

      endOffset = boundary.end;
    } else {
      break;
    }
  }

  return text.substring(0, endOffset);
}

List<String> paginateText(
  String text,
  double pageWidth,
  double firstPageHeight,
  double pageHeight,
  TextStyle style,
  BuildContext context,
) {
  final List<String> pages = [];

  int startOffset = 0;
  double availableHeight = firstPageHeight;

  while (startOffset < text.length) {
    final remainingText = text.substring(startOffset);

    final pageText = getTextThatFits(
      remainingText,
      pageWidth,
      availableHeight,
      style,
      context,
    );

    if (pageText.isEmpty) {
      break;
    }

    pages.add(pageText);
    startOffset += pageText.length;

    availableHeight = pageHeight;
  }

  return pages;
}

double getTextHeight(
  String text,
  double pageWidth,
  TextStyle style,
  BuildContext context,
) {
  final painter = TextPainter(
    text: TextSpan(
      text: text,
      style: style,
    ),
    textDirection: TextDirection.ltr,
    textScaler: MediaQuery.textScalerOf(context),
  );

  painter.layout(maxWidth: pageWidth);

  return painter.height;
}

  bool textFits(
    String text,
    double pageWidth,
    double remainingHeight,
    TextStyle style,
    double spacing,
    BuildContext context,
  ) {
    final height = getTextHeight(
      text,
      pageWidth,
      style,
      context,
    );

    return height + spacing <= remainingHeight;
  }

  

 List<EpubPage> paginateElements(
  List<EpubElement> elements,
  double pageWidth,
  double pageHeight,
  TextStyle style,
  BuildContext context,
) {
  final List<EpubPage> pages = [];
  List<EpubPageElement> currentPageElements = [];

  double remainingHeight = pageHeight;
  bool isFirstElementOnPage = true;
  EpubElementType? previousElementType;

  for (final element in elements) {


    final elementStyle =
        element.type == EpubElementType.heading
            ? headingStyle
            : textStyle;

    if (element.type != EpubElementType.paragraph &&
        element.type != EpubElementType.heading &&
        element.type != EpubElementType.image) {
      continue;
    }

    if (element.type == EpubElementType.image) {

      final imageWidth = (getImageWidth(element.imageBytes) ?? pageWidth)
        .clamp(0, pageWidth)
        .toDouble();

      final imageHeight = getImageHeightForWidth(
        element.imageBytes,
        imageWidth,
      );

      if (imageHeight == null) {
        continue;
      }

      print(
        'IMAGE: height=$imageHeight, '
        'remaining=$remainingHeight',
      );

      if (imageHeight <= remainingHeight) {
        currentPageElements.add(
          EpubPageElement(
            type: element.type,
            text: '',
            imageBytes: element.imageBytes,
          ),
        );

        remainingHeight -= imageHeight;
        isFirstElementOnPage = false;
        previousElementType = EpubElementType.image;
      } else {
        if (currentPageElements.isNotEmpty) {
          pages.add(
            EpubPage(
              elements: currentPageElements,
            ),
          );
        }

        currentPageElements = [
          EpubPageElement(
            type: element.type,
            text: '',
            imageBytes: element.imageBytes,
          ),
        ];

        remainingHeight = pageHeight - imageHeight;
        isFirstElementOnPage = false;
        previousElementType = EpubElementType.image;
      }

      continue;
    }

    // Headings always start on a new page
    if (element.type == EpubElementType.heading) {
      if (currentPageElements.isNotEmpty) {
        pages.add(
          EpubPage(
            elements: currentPageElements,
          ),
        );

        currentPageElements = [];
        isFirstElementOnPage = true;
        previousElementType = null;
      }

      currentPageElements.add(
        EpubPageElement(
          type: element.type,
          text: element.text,
          imageBytes: element.imageBytes,
        ),
      );

      remainingHeight = pageHeight -
          getTextHeight(
            element.text,
            pageWidth,
            elementStyle,
            context,
          );

      isFirstElementOnPage = false;
      previousElementType = EpubElementType.heading;

      continue;
    }

    // Paragraph handling
    final textHeight = getTextHeight(
      element.text,
      pageWidth,
      elementStyle,
      context,
    );

double spacing = 0;

if (!isFirstElementOnPage) {
  if (previousElementType == EpubElementType.heading) {
    spacing = headingSpacing;
  } else if (previousElementType == EpubElementType.paragraph) {
    spacing = paragraphSpacing;
  }
}

final requiredHeight = textHeight + spacing;


    if (requiredHeight <= remainingHeight) {
      currentPageElements.add(
        EpubPageElement(
          type: element.type,
          text: element.text,
          imageBytes: element.imageBytes,
        ),
      );

      remainingHeight -= requiredHeight;

      isFirstElementOnPage = false;
      previousElementType = EpubElementType.paragraph;

    } else {

      final availableHeight = remainingHeight - spacing;

      final textPages = paginateText(
        element.text,
        pageWidth,
        availableHeight,
        pageHeight,
        elementStyle,
        context,
      );


      if (textPages.isEmpty) {
        if (currentPageElements.isNotEmpty) {
          pages.add(
            EpubPage(
              elements: currentPageElements,
            ),
          );

          currentPageElements = [];
          isFirstElementOnPage = true;
          previousElementType = null;
        }

        final newTextPages = paginateText(
          element.text,
          pageWidth,
          pageHeight,
          pageHeight,
          elementStyle,
          context,
        );

        for (int i = 0; i < newTextPages.length; i++) {
          if (i < newTextPages.length - 1) {
            pages.add(
              EpubPage(
                elements: [
                  EpubPageElement(
                    type: element.type,
                    text: newTextPages[i],
                    imageBytes: element.imageBytes,
                  ),
                ],
              ),
            );
          } else {
            currentPageElements.add(
              EpubPageElement(
                type: element.type,
                text: newTextPages[i],
                imageBytes: element.imageBytes,
              ),
            );

            remainingHeight = pageHeight -
                getTextHeight(
                  newTextPages[i],
                  pageWidth,
                  elementStyle,
                  context,
                );

            isFirstElementOnPage = false;
            previousElementType = EpubElementType.paragraph;
          }
        }

        continue;
      }

      // First part uses the remaining space
      currentPageElements.add(
        EpubPageElement(
          type: element.type,
          text: textPages[0],
          imageBytes: element.imageBytes,
        ),
      );

      previousElementType = EpubElementType.paragraph;

      // Current page is now full
      pages.add(
        EpubPage(
          elements: currentPageElements,
        ),
      );

      currentPageElements = [];
      isFirstElementOnPage = true;
      previousElementType = null;

      // Remaining parts each get their own full page
      for (int i = 1; i < textPages.length; i++) {
        if (i < textPages.length - 1) {
          pages.add(
            EpubPage(
              elements: [
                EpubPageElement(
                  type: element.type,
                  text: textPages[i],
                  imageBytes: element.imageBytes,
                ),
              ],
            ),
          );
        } else {
          currentPageElements.add(
            EpubPageElement(
              type: element.type,
              text: textPages[i],
              imageBytes: element.imageBytes,
            ),
          );

          remainingHeight = pageHeight -
              getTextHeight(
                textPages[i],
                pageWidth,
                elementStyle,
                context,
              );

          isFirstElementOnPage = false;
          previousElementType = EpubElementType.paragraph;
        }
      }
    }
  }

  if (currentPageElements.isNotEmpty) {
    pages.add(
      EpubPage(
        elements: currentPageElements,
      ),
    );
  }

  return pages;
}


Future<void> loadElements() async {
  await loadReaderBook(widget.book.path);

  setState(() {
    pages = [];
    isPaginating = false;
  });
}

int? getImageWidth(Uint8List? imageBytes) {
  if (imageBytes == null) {
    return null;
  }

  final image = img.decodeImage(imageBytes);

  return image?.width;
}

int? getImageHeight(Uint8List? imageBytes) {
  if (imageBytes == null) {
    return null;
  }

  final image = img.decodeImage(imageBytes);

  return image?.height;
}

double? getImageHeightForWidth(
  Uint8List? imageBytes,
  double pageWidth,
) {
  final imageWidth = getImageWidth(imageBytes);
  final imageHeight = getImageHeight(imageBytes);

  if (imageWidth == null || imageHeight == null) {
    return null;
  }

  final displayWidth =
      imageWidth < pageWidth ? imageWidth.toDouble() : pageWidth;

  return displayWidth * imageHeight / imageWidth;
}

  @override
  Widget build(BuildContext context) {
 
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.book.title),
      ),

      body: SafeArea(
  child: Column(
    children: [
      Expanded(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final pageWidth = constraints.maxWidth;
            final pageHeight = constraints.maxHeight;


           if (
            !isPaginating &&
            (
              pages.isEmpty ||
              pageWidth != lastPageWidth ||
              pageHeight != lastPageHeight
            )
          ) {
            isPaginating = true;

            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (!mounted) return;

              final newPages = paginateElements(
                elements,
                pageWidth,
                pageHeight,
                textStyle,
                context,
              );

              print('PAGES GENERATED: ${newPages.length}');

              setState(() {
                pages = newPages;
                lastPageWidth = pageWidth;
                lastPageHeight = pageHeight;
                isPaginating = false;
              });
            });
          }

          if (pages.isEmpty) {
            return const Center(
              child: CircularProgressIndicator(),
            );
          }

          return ListView.builder(
            itemCount: pages.length,
            itemBuilder: (context, pageIndex) {
              final page = pages[pageIndex];

            double renderedHeight = 0;

            for (int i = 0; i < page.elements.length; i++) {
              final element = page.elements[i];
          
              renderedHeight += getTextHeight(
                element.text,
                pageWidth,
                element.type == EpubElementType.heading
                    ? headingStyle
                    : textStyle,
                context,
              );

              if (i < page.elements.length - 1 &&
                  element.type == EpubElementType.heading &&
                  page.elements[i + 1].type == EpubElementType.paragraph) {
                renderedHeight += headingSpacing;
              }

              if (i < page.elements.length - 1 &&
                  element.type == EpubElementType.paragraph &&
                  page.elements[i + 1].type == EpubElementType.paragraph) {
                renderedHeight += paragraphSpacing;
              }
            }

            return Column(
              children: [
                SizedBox(
                  height: pageHeight,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      for (int i = 0; i < page.elements.length; i++) ...[
                      if (page.elements[i].type == EpubElementType.image)
                        Image.memory(
                          page.elements[i].imageBytes!,
                          width: (getImageWidth(page.elements[i].imageBytes) ?? pageWidth)
                              .clamp(0, pageWidth)
                              .toDouble(),
                        )
                      else
                        Text(
                          page.elements[i].text,
                          style: page.elements[i].type == EpubElementType.heading
                              ? headingStyle
                              : textStyle,
                          textScaler: MediaQuery.textScalerOf(context),
                        ),

                        if (i < page.elements.length - 1 &&
                          page.elements[i].type == EpubElementType.heading &&
                          page.elements[i + 1].type == EpubElementType.paragraph)
                          SizedBox(height: headingSpacing),

                        if (i < page.elements.length - 1 &&
                          page.elements[i].type == EpubElementType.paragraph &&
                          page.elements[i + 1].type == EpubElementType.paragraph)
                          SizedBox(height: paragraphSpacing),
                      ],
                    ],
                  ),
                ),
                const Divider(),
              ],
            );
          },
        );
      },
    ),
  ),
],),
),
);
}
}