import 'dart:typed_data';

class BasicInfo {
  final String path;
  final String title;
  final String authorName;
  final Uint8List? cover;

  BasicInfo({
    required this.path,
    required this.title,
    required this.authorName,
    this.cover
  });
}