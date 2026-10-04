import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_epub_viewer/flutter_epub_viewer.dart';
import 'package:epub_reader/epub_repair.dart';

class EpubReaderPage extends StatefulWidget {
  final String epubPath;

  const EpubReaderPage({
    super.key,
    required this.epubPath,
  });

  @override
  State<EpubReaderPage> createState() => _EpubReaderPageState();
}

class _EpubReaderPageState extends State<EpubReaderPage> {
  final EpubController _epubController = EpubController();

  Future<Uint8List> _loadAndRepairEpub() async {
    final bytes = await File(widget.epubPath).readAsBytes();

    final repairer = EpubRepair();

    return await repairer.repairEpub(bytes);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('EPUB Test'),
      ),
      body: SafeArea(
        child: FutureBuilder<Uint8List>(
          future: _loadAndRepairEpub(),
          builder: (context, snapshot) {
            if (!snapshot.hasData) {
              return const Center(
                child: CircularProgressIndicator(),
              );
            }
        
            return EpubViewer(
              epubController: _epubController,
              epubSource: EpubSource.fromData(
                snapshot.data!,
              ),
              displaySettings: EpubDisplaySettings(
                flow: EpubFlow.paginated,
                snap: true,
                fontSize: 18,
                spread: EpubSpread.auto,
                useSnapAnimationAndroid: true,
                theme: EpubTheme.custom(
                  customCss: {
                    'div' : {
                      'color': 'green',
                      'margin-top': '0',
                      'margin-bottom': '30px'
                    },
                    'p' : {
                      'color' : 'green',
                      'line-height' : '1.1',     
                      'margin-top': '0',
                      'margin-bottom': '30px'                 
                    }
                  }
                )
              ),
            );
          },
        ),
      ),
    );
  }
}