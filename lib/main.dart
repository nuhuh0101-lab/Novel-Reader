import 'dart:io';
import 'dart:typed_data';
import 'package:epubx/epubx.dart' as epubx;
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'basic_info.dart';
import 'package:image/image.dart' as img;
import 'package:archive/archive.dart';
import 'package:xml/xml.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: MainPage(),
    );
  }
}

class MainPage extends StatefulWidget {
  const MainPage({super.key});

  @override
  State<MainPage> createState() => _MainPageState();
}

class _MainPageState extends State<MainPage> {
  List<String> _savedFilePaths = [];
  List<BasicInfo> books = [];

  @override
  void initState() {
    super.initState();
    _loadSavedFiles(); // Automatically retrieve files on app startup
  }

  Future<BasicInfo?> loadBook(String path) async {
  BasicInfo? book;

  try {
    final epubBook = await loadEpubBook(path);

    Uint8List? coverBytes;

    coverBytes = getCoverFromMetadata(epubBook);

    coverBytes ??= getFirstPageImage(epubBook);

    if (coverBytes == null && epubBook.CoverImage != null) {
      coverBytes = Uint8List.fromList(
        img.encodeJpg(epubBook.CoverImage!),
      );
    }

    if (coverBytes == null &&
        epubBook.Content?.Images != null &&
        epubBook.Content!.Images!.isNotEmpty) {
      final firstImage =
          epubBook.Content!.Images!.values.first;

      if (firstImage.Content != null) {
        coverBytes = Uint8List.fromList(
          firstImage.Content!,
        );
      }
    }

    book = BasicInfo(
      path: path,
      title: epubBook.Title ?? "Unknown Title",
      authorName: epubBook.Author ?? "Unknown Author",
      cover: coverBytes,
    );
  } catch (e) {
    print('epubx failed for $path');
    print(e);

    book = await loadBrokenEpub(path);
  }

  return book;
}

  Future<BasicInfo?> loadBrokenEpub(String filePath) async {
  try {
    final file = File(filePath);
    final bytes = await file.readAsBytes();

    final archive = ZipDecoder().decodeBytes(bytes);

    ArchiveFile? findFile(String path) {
      final normalizedPath = path.replaceAll('\\', '/');

      for (final file in archive) {
        if (file.isFile &&
            file.name.replaceAll('\\', '/') == normalizedPath) {
          return file;
        }
      }

      return null;
    }

    // ------------------------------------------------------------
    // 1. Find the OPF file from META-INF/container.xml
    // ------------------------------------------------------------

    final containerFile = findFile('META-INF/container.xml');

    if (containerFile == null) {
      return null;
    }

    final containerXml = XmlDocument.parse(
      String.fromCharCodes(containerFile.content),
    );

    final rootfile = containerXml
        .findAllElements('rootfile')
        .firstOrNull;

    if (rootfile == null) {
      return null;
    }

    final opfPath = rootfile.getAttribute('full-path');

    if (opfPath == null) {
      return null;
    }

    // ------------------------------------------------------------
    // 2. Read content.opf
    // ------------------------------------------------------------

    final opfFile = findFile(opfPath);

    if (opfFile == null) {
      return null;
    }

    final opfXml = XmlDocument.parse(
      String.fromCharCodes(opfFile.content),
    );

    // ------------------------------------------------------------
    // 3. Get title
    // ------------------------------------------------------------

    String title = 'Unknown Title';

    final titleElement =
        opfXml.findAllElements('title').firstOrNull;

    if (titleElement != null && titleElement.innerText.isNotEmpty) {
      title = titleElement.innerText;
    }

    // ------------------------------------------------------------
    // 4. Get author
    // ------------------------------------------------------------

    String author = 'Unknown Author';

    final creatorElement =
        opfXml.findAllElements('creator').firstOrNull;

    if (creatorElement != null &&
        creatorElement.innerText.isNotEmpty) {
      author = creatorElement.innerText;
    }

    // ------------------------------------------------------------
    // 5. Find the cover ID from metadata
    // ------------------------------------------------------------

    String? coverId;

    for (final meta in opfXml.findAllElements('meta')) {
      final name = meta.getAttribute('name');

      if (name?.toLowerCase() == 'cover') {
        coverId = meta.getAttribute('content');
        break;
      }
    }

    Uint8List? coverBytes;

    // ------------------------------------------------------------
    // 6. Find the cover image in the manifest
    // ------------------------------------------------------------

    if (coverId != null) {
      String? coverHref;

      for (final item in opfXml.findAllElements('item')) {
        if (item.getAttribute('id') == coverId) {
          coverHref = item.getAttribute('href');
          break;
        }
      }

      if (coverHref != null) {
        final opfDirectory = opfPath.contains('/')
            ? opfPath.substring(
                0,
                opfPath.lastIndexOf('/'),
              )
            : '';

        final coverPath = opfDirectory.isEmpty
            ? coverHref
            : '$opfDirectory/$coverHref';

        final coverFile = findFile(coverPath);

        if (coverFile != null) {
          coverBytes = coverFile.content;
        }
      }
    }

    // ------------------------------------------------------------
    // 7. Last fallback: find the first image in the EPUB
    // ------------------------------------------------------------

    if (coverBytes == null) {
      for (final file in archive) {
        if (!file.isFile) {
          continue;
        }

        final name = file.name.toLowerCase();

        if (name.endsWith('.jpg') ||
            name.endsWith('.jpeg') ||
            name.endsWith('.png') ||
            name.endsWith('.gif') ||
            name.endsWith('.webp')) {
          coverBytes = file.content;
          break;
        }
      }
    }

    return BasicInfo(
      path: filePath,
      title: title,
      authorName: author,
      cover: coverBytes,
    );
  } catch (e) {
    print('Broken EPUB fallback failed: $e');
    return null;
  }
}

  Uint8List? getCoverFromMetadata(epubx.EpubBook epubBook) {
    final metaItems = epubBook.Schema?.Package?.Metadata?.MetaItems;
    final manifestItems = epubBook.Schema?.Package?.Manifest?.Items;
    final content = epubBook.Content;

    if (metaItems == null ||
        manifestItems == null ||
        content == null) {
      return null;
    }

    String? coverId;

    // Find the cover ID from the metadata.
    for (final meta in metaItems) {
      if (meta.Name?.toLowerCase() == 'cover') {
        coverId = meta.Content;
        break;
      }
    }

    if (coverId == null) {
      return null;
    }

    String? coverHref;

    // Find the manifest item using that ID.
    for (final item in manifestItems) {
      if (item.Id?.toLowerCase() == coverId.toLowerCase()) {
        coverHref = item.Href;
        break;
      }
    }

    if (coverHref == null) {
      return null;
    }

    String normalize(String value) {
      return Uri.decodeComponent(
        value.replaceAll('\\', '/'),
      ).replaceFirst(RegExp(r'^/+'), '');
    }

    String fileName(String value) {
      return normalize(value).split('/').last;
    }

    final wantedPath = normalize(coverHref);
    final wantedName = fileName(coverHref);

    // First try Content.Images.
    final images = content.Images;

    if (images != null) {
      for (final entry in images.entries) {
        final currentPath = normalize(entry.key);

        if (currentPath == wantedPath ||
            currentPath.endsWith('/$wantedPath') ||
            fileName(currentPath) == wantedName) {
          final bytes = entry.value.Content;

          if (bytes != null) {
            return Uint8List.fromList(bytes);
          }
        }
      }
    }

    // If Images didn't find it, try AllFiles.
    final allFiles = content.AllFiles;

    if (allFiles != null) {
      for (final entry in allFiles.entries) {
        final currentPath = normalize(entry.key);

        if (currentPath == wantedPath ||
            currentPath.endsWith('/$wantedPath') ||
            fileName(currentPath) == wantedName) {
          final file = entry.value;

          if (file is epubx.EpubByteContentFile &&
              file.Content != null) {
            return Uint8List.fromList(file.Content!);
          }
        }
      }
    }

    return null;
  }



  Uint8List? getFirstPageImage(epubx.EpubBook epubBook) {
  final spineItems = epubBook.Schema?.Package?.Spine?.Items;
  final manifestItems = epubBook.Schema?.Package?.Manifest?.Items;
  final htmlFiles = epubBook.Content?.Html;
  final images = epubBook.Content?.Images;

  if (spineItems == null ||
      spineItems.isEmpty ||
      manifestItems == null ||
      htmlFiles == null ||
      images == null) {
    return null;
  }

  // Get the first item in the reading order.
  final firstSpineItem = spineItems.first;

  if (firstSpineItem.IdRef == null) {
    return null;
  }

  // Find the manifest item referred to by the spine.
  epubx.EpubManifestItem? firstDocument;

  for (final item in manifestItems) {
    if (item.Id == firstSpineItem.IdRef) {
      firstDocument = item;
      break;
    }
  }

  if (firstDocument == null || firstDocument.Href == null) {
    return null;
  }

  // Find the corresponding XHTML file.
  epubx.EpubTextContentFile? htmlFile;

  for (final entry in htmlFiles.entries) {
    if (entry.key == firstDocument.Href ||
        entry.value.FileName == firstDocument.Href) {
      htmlFile = entry.value;
      break;
    }
  }

  if (htmlFile == null || htmlFile.Content == null) {
    return null;
  }

  // Find the first <img src="..."> in that XHTML.
  final imgRegex = RegExp(
    r'''<(?:img|image)\b[^>]*?(?:src|xlink:href)\s*=\s*["']([^"']+)["']''',
    caseSensitive: false,
    );

  final match = imgRegex.firstMatch(htmlFile.Content!);

  if (match == null) {
    return null;
  }

  final imageSrc = match.group(1);

  if (imageSrc == null) {
    return null;
  }

  // Resolve the image path relative to the XHTML file.
  final imagePath = Uri.parse(
    htmlFile.FileName ?? firstDocument.Href!,
  ).resolve(imageSrc).path;

  final cleanPath = Uri.decodeFull(
    imagePath.startsWith('/') ? imagePath.substring(1) : imagePath,
  );

  // Find the actual image bytes.
  for (final entry in images.entries) {
    final key = Uri.decodeFull(entry.key);

    if (key == cleanPath ||
        entry.value.FileName == cleanPath) {
      final content = entry.value.Content;

      if (content != null) {
        return Uint8List.fromList(content);
      }
    }
  }

  return null;
}



  Future<void> _loadSavedFiles() async {
  final prefs = await SharedPreferences.getInstance();
  setState(() {
    _savedFilePaths = prefs.getStringList('saved_files') ?? [];
  });

  await loadBooks();

  setState(() {});
  }

  Future<epubx.EpubBook> loadEpubBook(String filePath) async{
    final file = File(filePath);
    final bytes = await file.readAsBytes();

    return await epubx.EpubReader.readBook(bytes);
  }



  Future<void> loadBooks() async {
  books.clear();

  for (final path in _savedFilePaths) {
    final book = await loadBook(path);

    if (book != null) {
      books.add(book);
    }
  }

  setState(() {});
}

  Future<void> pickAndSaveFile() async {
  List<PlatformFile> selectedFiles = await FilePicker.pickFiles(
    type: FileType.custom,
    allowedExtensions: ['epub'],
  );

  if (selectedFiles.isEmpty) {
    print('User canceled the multiple selection.');
    return;
  }

  final Directory appDocDir =
      await getApplicationDocumentsDirectory();

  final prefs = await SharedPreferences.getInstance();

  List<String> updatedPaths = List.from(_savedFilePaths);
  List<String> newPaths = [];

  for (PlatformFile file in selectedFiles) {
    if (file.path != null) {
      String permanentPath =
          '${appDocDir.path}/${file.name}';

      if (await File(permanentPath).exists()) {
        continue;
      }

      final File cachedFile = File(file.path!);

      await cachedFile.copy(permanentPath);

      updatedPaths.add(permanentPath);
      newPaths.add(permanentPath);
    }
  }

  await prefs.setStringList(
    'saved_files',
    updatedPaths,
  );

  List<BasicInfo> newBooks = [];

  for (final path in newPaths) {
    final book = await loadBook(path);

    if (book != null) {
      newBooks.add(book);
    }
  }

  setState(() {
    _savedFilePaths = updatedPaths;
    books.addAll(newBooks);
  });
}

  Future<void> deleteAllFiles() async {
  for (final path in _savedFilePaths) {
    final file = File(path);

    if (await file.exists()) {
      await file.delete();
    }
  }

  final prefs = await SharedPreferences.getInstance();
  await prefs.remove('saved_files');

  setState(() {
    _savedFilePaths.clear();
    books.clear();
  });
}

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.cyanAccent,
      floatingActionButton: FloatingActionButton(
        shape: CircleBorder(),
        elevation: 2,
        backgroundColor: const Color.fromARGB(255, 255, 140, 69),
        onPressed: pickAndSaveFile,
        child: Icon(Icons.add, color: Colors.white,),
        ),
        
      drawer: Drawer(
        child: ElevatedButton(onPressed: (){
          deleteAllFiles();
        }, 
        child: Icon(Icons.delete, size: 100,)),
      ),
      appBar: AppBar(
        title: Text("Folk Reader", style: TextStyle(color: Colors.white),),
        shadowColor: Colors.grey,
        elevation: 1,
        backgroundColor: Color.fromARGB(255, 213, 108, 171),
      ),
      body: SafeArea(
        child: ListView.builder(
        itemCount: books.length,
        scrollCacheExtent: ScrollCacheExtent.pixels(500),
        itemBuilder: (context, index){

          return 
              Container(
                height: 180,
                margin: EdgeInsets.only(bottom: 10),
                decoration: BoxDecoration(
                  gradient: LinearGradient(colors: [const Color.fromARGB(255, 123, 241, 33), const Color.fromARGB(255, 255, 139, 253)])
                  
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.start,
                  children: [
                    if(books[index].cover != null)
                      Image.memory(
                      books[index].cover!,
                      width: 120,
                      height: 180,
                      fit: BoxFit.cover,
                      )
                    else
                      Image.asset(
                        'assets/place_holder_image.png',
                        width: 120,
                        height: 180,
                        fit: BoxFit.cover,),

                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.all(5.0),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              books[index].title,
                              style: TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.bold,
                                color: Colors.white
                              ),
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              ),
                            
                            SizedBox(height: 5,),

                            Text(
                              books[index].authorName,
                              style: TextStyle(
                                color: const Color.fromARGB(255, 136, 136, 137),
                                fontSize: 12
                              ),
                            ),

                            SizedBox(height: 5,),

                          ],
                        ),
                      ),
                    )
                    
                  ],
                
                ),
              );
        }
            
      )),
    );
  }

}
