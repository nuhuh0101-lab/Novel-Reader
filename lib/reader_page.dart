import 'dart:io';
import 'package:epub_reader/basic_info.dart';
import 'package:epub_view/epub_view.dart';
import 'package:flutter/material.dart';
import 'dart:convert';
import 'dart:typed_data';
import 'package:archive/archive.dart';
import 'package:epubx/epubx.dart' as epubx;
import 'package:xml/xml.dart';

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
  late EpubController controller;

  @override
  void initState(){
    super.initState();
    controller = EpubController(
  document: loadReaderBook(widget.book.path),
);
  }


Future<epubx.EpubBook> loadReaderBook(String path) async {
  final file = File(path);

  final bytes = await file.readAsBytes();

  try {
    
    final book = await epubx.EpubReader.readBook(bytes);

    return book;
  } catch (e) {

    final repairedBytes = await repairMissingNcx(bytes);

    final book = await epubx.EpubReader.readBook(
      repairedBytes,
    );

    return book;
  }
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


  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.book.title),
      ),
      body: SafeArea(
        child: EpubView(
          controller: controller,
          builders: EpubViewBuilders<DefaultBuilderOptions>(
            options: DefaultBuilderOptions(

            ),
            chapterDividerBuilder: (_) =>  SizedBox.shrink(),
          ),
        )
      ),
    );
  }
}