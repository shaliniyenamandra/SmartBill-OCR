import 'dart:io';

import 'package:dio/dio.dart' as dio;
import 'package:file_selector/file_selector.dart' as fs;
import 'package:flutter/material.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:image_picker/image_picker.dart';

void main() {
  runApp(const BillReaderApp());
}

class BillReaderApp extends StatelessWidget {
  const BillReaderApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Bill Reader OCR',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.deepPurple,
        ),
        useMaterial3: true,
      ),
      home: const HomeScreen(),
    );
  }
}

enum SelectedInputType {
  none,
  image,
  pdf,
}


class OfflineBillDraft {
  final String id;
  final SelectedInputType inputType;
  final String imagePath;
  final String pdfPath;
  final String pdfName;
  String rawText;
  String detectedDate;
  String detectedAmount;
  String detectedType;
  String comments;
  String reason;
  String status;
  final DateTime createdAt;

  OfflineBillDraft({
    required this.id,
    this.inputType = SelectedInputType.image,
    required this.imagePath,
    this.pdfPath = '',
    this.pdfName = '',
    required this.rawText,
    required this.detectedDate,
    required this.detectedAmount,
    required this.detectedType,
    this.comments = '',
    required this.reason,
    this.status = 'waiting',
    required this.createdAt,
  });

  bool get isFinished => status == 'finished';
  bool get isProcessing => status == 'processing';
  bool get isWaiting => status == 'waiting';
}

class OfflineDraftStore {
  static final List<OfflineBillDraft> drafts = [];
  static final ValueNotifier<int> revision = ValueNotifier<int>(0);

  static void add(OfflineBillDraft draft) {
    drafts.insert(0, draft);
    notify();
  }

  static void remove(String id) {
    drafts.removeWhere((draft) => draft.id == id);
    notify();
  }

  static void notify() {
    revision.value++;
  }
}

class DraftsScreen extends StatefulWidget {
  const DraftsScreen({super.key});

  @override
  State<DraftsScreen> createState() => _DraftsScreenState();
}

class _DraftsScreenState extends State<DraftsScreen> {
  static const String _paddleApiUrl = 'http://127.0.0.1:8000/ocr/paddle';
  final ImagePicker _picker = ImagePicker();

  Future<void> _showAddDraftOptions() async {
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      builder: (context) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  'Add to Drafts',
                  style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 12),
                ListTile(
                  leading: const Icon(Icons.photo_library_outlined),
                  title: const Text('Select multiple images'),
                  subtitle: const Text('Each image will be processed in the background'),
                  onTap: () {
                    Navigator.pop(context);
                    _addMultipleImages();
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.picture_as_pdf_outlined),
                  title: const Text('Select PDFs'),
                  subtitle: const Text('PDFs are saved in drafts for later processing'),
                  onTap: () {
                    Navigator.pop(context);
                    _addMultiplePdfs();
                  },
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Future<void> _addMultipleImages() async {
    try {
      final List<XFile> pickedImages = await _picker.pickMultiImage(
        imageQuality: 85,
      );

      if (pickedImages.isEmpty) {
        return;
      }

      for (final XFile image in pickedImages) {
        final OfflineBillDraft draft = OfflineBillDraft(
          id: DateTime.now().microsecondsSinceEpoch.toString(),
          inputType: SelectedInputType.image,
          imagePath: image.path,
          rawText: '',
          detectedDate: '',
          detectedAmount: '',
          detectedType: 'Other',
          comments: '',
          reason: 'Queued for OCR processing.',
          status: 'processing',
          createdAt: DateTime.now(),
        );

        OfflineDraftStore.add(draft);
        _processImageDraft(draft);
      }
    } catch (e) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to add images: $e')),
      );
    }
  }

  Future<void> _addMultiplePdfs() async {
    try {
      const fs.XTypeGroup pdfTypeGroup = fs.XTypeGroup(
        label: 'PDF files',
        extensions: <String>['pdf'],
        mimeTypes: <String>['application/pdf'],
      );

      final List<fs.XFile> pickedPdfs = await fs.openFiles(
        acceptedTypeGroups: <fs.XTypeGroup>[pdfTypeGroup],
      );

      if (pickedPdfs.isEmpty) {
        return;
      }

      for (final fs.XFile pdf in pickedPdfs) {
        final OfflineBillDraft draft = OfflineBillDraft(
          id: DateTime.now().microsecondsSinceEpoch.toString(),
          inputType: SelectedInputType.pdf,
          imagePath: '',
          pdfPath: pdf.path,
          pdfName: pdf.name,
          rawText: '',
          detectedDate: '',
          detectedAmount: '',
          detectedType: 'Other',
          comments: 'PDF saved to Drafts. PDF-to-image OCR will be added next.',
          reason: 'PDF saved. Waiting for PDF-to-image OCR support.',
          status: 'waiting',
          createdAt: DateTime.now(),
        );

        OfflineDraftStore.add(draft);
      }
    } catch (e) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to add PDFs: $e')),
      );
    }
  }

  Future<void> _processImageDraft(OfflineBillDraft draft) async {
    draft.status = 'processing';
    draft.reason = 'Running Google ML Kit OCR...';
    OfflineDraftStore.notify();

    final TextRecognizer textRecognizer = TextRecognizer(
      script: TextRecognitionScript.latin,
    );

    try {
      final InputImage inputImage = InputImage.fromFilePath(draft.imagePath);
      final RecognizedText recognizedText =
          await textRecognizer.processImage(inputImage);

      final String rawText = recognizedText.text.trim();
      draft.rawText = rawText;
      draft.comments = rawText.isEmpty ? 'No readable OCR text detected.' : rawText;

      final bool phoneOnline = await _phoneHasInternet();

      if (phoneOnline) {
        draft.reason = 'Phone online. Trying PaddleOCR backend...';
        OfflineDraftStore.notify();

        final bool paddleWorked = await _tryPaddleForDraft(draft);
        if (paddleWorked) {
          OfflineDraftStore.notify();
          return;
        }
      }

      _finalizeDraftWithGoogleParser(draft, rawText);
    } catch (e) {
      draft.status = 'waiting';
      draft.reason = 'OCR failed. Waiting for internet/backend retry.';
      draft.comments = 'Draft OCR failed: $e';
      OfflineDraftStore.notify();
    } finally {
      await textRecognizer.close();
    }
  }

  Future<bool> _tryPaddleForDraft(OfflineBillDraft draft) async {
    if (draft.imagePath.trim().isEmpty) {
      return false;
    }

    try {
      final dio.Dio client = dio.Dio(
        dio.BaseOptions(
          connectTimeout: const Duration(seconds: 8),
          sendTimeout: const Duration(seconds: 20),
          receiveTimeout: const Duration(seconds: 60),
        ),
      );

      final dio.FormData formData = dio.FormData.fromMap({
        'file': await dio.MultipartFile.fromFile(
          draft.imagePath,
          filename: 'draft_bill.jpg',
        ),
      });

      final dio.Response response = await client.post(
        _paddleApiUrl,
        data: formData,
      );

      final dynamic responseData = response.data;

      if (responseData is! Map || responseData['success'] != true) {
        return false;
      }

      final Map data = responseData;
      final bool isFake = data['isFake'] == true;

      final String paddleText = (data['rawText'] ?? '').toString().trim();
      final String backendAmount = (data['amount'] ?? '').toString().trim();
      final String backendDate =
          (data['date'] ??
                  data['detectedDate'] ??
                  data['billDate'] ??
                  data['invoiceDate'] ??
                  data['receiptDate'] ??
                  '')
              .toString()
              .trim();
      final String backendType =
          (data['reimbursementType'] ?? '').toString().trim();
      final String backendComments = (data['comments'] ?? '').toString().trim();

      draft.rawText = paddleText.isNotEmpty ? paddleText : draft.rawText;
      draft.comments = backendComments.isNotEmpty
          ? backendComments
          : (draft.rawText.isEmpty ? draft.comments : draft.rawText);

      if (isFake) {
        draft.detectedType = 'Other';
        draft.detectedDate = '';
        draft.detectedAmount = '';
        draft.status = 'finished';
        draft.reason = 'Bill authenticity check completed.';
        draft.comments = backendComments.isNotEmpty
            ? backendComments
            : 'Bill is detected to be fake.';
        return true;
      }

      draft.detectedAmount = backendAmount;
      draft.detectedDate = backendDate;
      draft.detectedType = backendType.isNotEmpty ? backendType : 'Other';
      draft.status = 'finished';
      draft.reason = 'Finished using PaddleOCR backend.';
      return true;
    } catch (_) {
      return false;
    }
  }

  void _finalizeDraftWithGoogleParser(OfflineBillDraft draft, String rawText) {
    final String lowerText = rawText.toLowerCase();
    final String detectedType = LocalBillParser.guessReimbursementType(lowerText);
    final String detectedDate = LocalBillParser.detectDate(rawText);
    final String detectedAmount = LocalBillParser.detectAmount(rawText);

    draft.detectedType = detectedType;
    draft.detectedDate = detectedDate;
    draft.detectedAmount = detectedAmount;
    draft.comments = rawText.trim().isEmpty
        ? 'No readable OCR text detected.'
        : rawText.trim();

    final int wordCount = rawText
        .split(RegExp(r'\s+'))
        .where((word) => word.trim().isNotEmpty)
        .length;

    if (wordCount >= 5 && detectedDate.isNotEmpty && detectedAmount.isNotEmpty) {
      draft.status = 'finished';
      draft.reason = 'Finished offline using Google ML Kit.';
    } else {
      draft.status = 'waiting';
      if (wordCount < 5) {
        draft.reason = 'OCR text is too low. Waiting for internet/backend.';
      } else if (detectedDate.isEmpty && detectedAmount.isEmpty) {
        draft.reason = 'Amount and date not confidently detected. Waiting for internet/backend.';
      } else if (detectedAmount.isEmpty) {
        draft.reason = 'Amount not confidently detected. Waiting for internet/backend.';
      } else {
        draft.reason = 'Date not confidently detected. Waiting for internet/backend.';
      }
    }

    OfflineDraftStore.notify();
  }

  Future<bool> _phoneHasInternet() async {
    try {
      final List<InternetAddress> result = await InternetAddress.lookup(
        'example.com',
      ).timeout(const Duration(seconds: 2));

      return result.isNotEmpty && result.first.rawAddress.isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  Widget _buildStatusIcon(OfflineBillDraft draft) {
    if (draft.isFinished) {
      return const CircleAvatar(
        backgroundColor: Colors.green,
        radius: 16,
        child: Icon(Icons.check, color: Colors.white, size: 18),
      );
    }

    if (draft.isProcessing) {
      return const CircleAvatar(
        backgroundColor: Colors.amber,
        radius: 16,
        child: SizedBox(
          width: 16,
          height: 16,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    }

    return const CircleAvatar(
      backgroundColor: Colors.orange,
      radius: 16,
      child: Icon(Icons.hourglass_bottom, color: Colors.white, size: 18),
    );
  }

  Widget _buildDraftThumbnail(OfflineBillDraft draft) {
    if (draft.inputType == SelectedInputType.image && draft.imagePath.isNotEmpty) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: Image.file(
          File(draft.imagePath),
          width: 78,
          height: 78,
          fit: BoxFit.cover,
          errorBuilder: (_, __, ___) => const Icon(Icons.image_not_supported),
        ),
      );
    }

    return Container(
      width: 78,
      height: 78,
      decoration: BoxDecoration(
        color: Colors.red.shade50,
        borderRadius: BorderRadius.circular(12),
      ),
      child: const Icon(Icons.picture_as_pdf, color: Colors.red, size: 40),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF7F4FF),
      appBar: AppBar(
        title: const Text('Drafts'),
        centerTitle: true,
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: _showAddDraftOptions,
        child: const Icon(Icons.add),
      ),
      body: ValueListenableBuilder<int>(
        valueListenable: OfflineDraftStore.revision,
        builder: (context, _, __) {
          final drafts = OfflineDraftStore.drafts;

          if (drafts.isEmpty) {
            return const Center(
              child: Text(
                'No drafts yet. Tap + to add multiple bills.',
                style: TextStyle(fontSize: 16),
                textAlign: TextAlign.center,
              ),
            );
          }

          return ListView.builder(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 90),
            itemCount: drafts.length,
            itemBuilder: (context, index) {
              final draft = drafts[index];

              return Card(
                margin: const EdgeInsets.only(bottom: 14),
                child: InkWell(
                  borderRadius: BorderRadius.circular(12),
                  onTap: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => DraftDetailScreen(draft: draft),
                      ),
                    );
                  },
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Row(
                      children: [
                        _buildDraftThumbnail(draft),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                draft.inputType == SelectedInputType.pdf
                                    ? (draft.pdfName.isEmpty ? 'PDF Draft' : draft.pdfName)
                                    : 'Bill Draft',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                draft.reason,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                              ),
                              const SizedBox(height: 4),
                              Text(
                                '₹ ${draft.detectedAmount.isEmpty ? "--" : draft.detectedAmount}   |   ${draft.detectedDate.isEmpty ? "No date" : draft.detectedDate}',
                                style: const TextStyle(fontSize: 13),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 8),
                        _buildStatusIcon(draft),
                        const SizedBox(width: 4),
                        IconButton(
                          tooltip: 'Remove draft',
                          icon: const Icon(Icons.delete_outline),
                          onPressed: () {
                            OfflineDraftStore.remove(draft.id);
                          },
                        ),
                      ],
                    ),
                  ),
                ),
              );
            },
          );
        },
      ),
    );
  }
}

class DraftDetailScreen extends StatefulWidget {
  final OfflineBillDraft draft;

  const DraftDetailScreen({super.key, required this.draft});

  @override
  State<DraftDetailScreen> createState() => _DraftDetailScreenState();
}

class _DraftDetailScreenState extends State<DraftDetailScreen> {
  late final TextEditingController _typeController;
  late final TextEditingController _dateController;
  late final TextEditingController _amountController;
  late final TextEditingController _commentsController;

  @override
  void initState() {
    super.initState();
    _typeController = TextEditingController(text: widget.draft.detectedType);
    _dateController = TextEditingController(text: widget.draft.detectedDate);
    _amountController = TextEditingController(text: widget.draft.detectedAmount);
    _commentsController = TextEditingController(
      text: widget.draft.comments.isNotEmpty
          ? widget.draft.comments
          : widget.draft.rawText,
    );
  }

  @override
  void dispose() {
    _typeController.dispose();
    _dateController.dispose();
    _amountController.dispose();
    _commentsController.dispose();
    super.dispose();
  }

  Widget _buildLargePreview() {
    final draft = widget.draft;

    if (draft.inputType == SelectedInputType.image && draft.imagePath.isNotEmpty) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(16),
        child: Image.file(
          File(draft.imagePath),
          fit: BoxFit.contain,
          errorBuilder: (_, __, ___) => const Center(
            child: Text('Image file could not be opened'),
          ),
        ),
      );
    }

    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        const Icon(Icons.picture_as_pdf, size: 90, color: Colors.red),
        const SizedBox(height: 14),
        Text(
          draft.pdfName.isEmpty ? 'PDF Draft' : draft.pdfName,
          textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 8),
        Text(
          draft.pdfPath,
          textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 12, color: Colors.black54),
        ),
      ],
    );
  }

  void _saveEdits() {
    widget.draft.detectedType = _typeController.text.trim();
    widget.draft.detectedDate = _dateController.text.trim();
    widget.draft.detectedAmount = _amountController.text.trim();
    widget.draft.comments = _commentsController.text.trim();
    OfflineDraftStore.notify();
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Draft details updated.')),
    );
  }

  @override
  Widget build(BuildContext context) {
    final draft = widget.draft;

    return Scaffold(
      backgroundColor: const Color(0xFFF7F4FF),
      appBar: AppBar(
        title: const Text('Draft Details'),
        centerTitle: true,
        actions: [
          IconButton(
            icon: const Icon(Icons.save_outlined),
            onPressed: _saveEdits,
          ),
        ],
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: Column(
            children: [
              SizedBox(
                height: 260,
                child: Container(
                  width: double.infinity,
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: Colors.deepPurple.withOpacity(0.2)),
                  ),
                  child: _buildLargePreview(),
                ),
              ),
              const SizedBox(height: 12),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: draft.isFinished ? const Color(0xFFE8F5E9) : const Color(0xFFFFF8E1),
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: draft.isFinished ? Colors.green : Colors.orange),
                ),
                child: Text(
                  draft.reason,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontWeight: FontWeight.w600,
                    color: draft.isFinished ? Colors.green.shade900 : Colors.orange.shade900,
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: Colors.deepPurple.withOpacity(0.2)),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Expense Details',
                      style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(height: 14),
                    TextField(
                      controller: _typeController,
                      decoration: const InputDecoration(
                        labelText: 'Reimbursement Type',
                        border: OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: _dateController,
                      decoration: const InputDecoration(
                        labelText: 'Date',
                        border: OutlineInputBorder(),
                        suffixIcon: Icon(Icons.calendar_today),
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: _amountController,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(
                        labelText: 'Amount',
                        border: OutlineInputBorder(),
                        suffixText: '₹',
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: _commentsController,
                      maxLines: 6,
                      decoration: const InputDecoration(
                        labelText: 'Comments',
                        border: OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 12),
                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton.icon(
                        icon: const Icon(Icons.save_outlined),
                        label: const Text('Save Draft Details'),
                        onPressed: _saveEdits,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class LocalBillParser {
  static String guessReimbursementType(String lowerText) {
    if (_containsAny(lowerText, ['hotel', 'room', 'stay', 'lodging', 'accommodation', 'oyo', 'airbnb', 'resort', 'inn'])) {
      return 'Accommodation / Stay';
    }

    if (_containsAny(lowerText, ['xerox', 'notary', 'franking', 'spiral binding', 'lamination', 'scanning', 'cartridge refill', 'd.t.p', 'photo print', 'online services', 'photocopy', 'stationery', 'printer', 'paper', 'binding'])) {
      return 'Office Supplies / Miscellaneous';
    }

    if (_containsAny(lowerText, ['restaurant', 'cafe', 'food', 'meal', 'swiggy', 'zomato', 'tea', 'coffee', 'pizza', 'burger', 'biryani', 'dosa', 'idli', 'kitchen', 'bakery', 'canteen', 'dining', 'mcdonald', 'kfc', 'domino', 'subway', 'cold drink'])) {
      return 'Food / Meals';
    }

    if (_containsAny(lowerText, ['uber', 'ola', 'rapido', 'bus', 'train', 'railway', 'flight', 'airlines', 'taxi', 'cab', 'fuel', 'petrol', 'diesel', 'parking', 'toll', 'metro', 'ticket', 'boarding', 'pushpak', 'depot', 'airport to', 'fare'])) {
      return 'Travel Expenses';
    }

    if (_containsAny(lowerText, ['laptop', 'keyboard', 'mouse', 'monitor', 'charger', 'adapter', 'software', 'hardware', 'ssd', 'hdd', 'ram', 'router', 'cable', 'pendrive', 'printer cartridge', 'electronics'])) {
      return 'IT Equipment for work';
    }

    if (_containsAny(lowerText, ['client', 'meeting', 'visit', 'business visit', 'customer', 'conference room'])) {
      return 'Client Visit Expenses';
    }

    if (_containsAny(lowerText, ['course', 'training', 'certification', 'workshop', 'seminar', 'webinar', 'exam fee', 'learning'])) {
      return 'Training / Certification Fees';
    }

    return 'Other';
  }

  static bool _containsAny(String text, List<String> keywords) {
    for (final keyword in keywords) {
      if (text.contains(keyword)) {
        return true;
      }
    }
    return false;
  }

  static String detectDate(String rawText) {
    final List<String> lines = rawText
        .split('\n')
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty)
        .toList();

    int normalizeYear(int year) {
      if (year < 100) {
        return year <= 79 ? 2000 + year : 1900 + year;
      }
      return year;
    }

    String validDate(int day, int month, int year) {
      final int normalizedYear = normalizeYear(year);
      if (normalizedYear < 2000 || normalizedYear > 2100) {
        return '';
      }

      try {
        final DateTime parsed = DateTime(normalizedYear, month, day);
        if (parsed.day != day || parsed.month != month || parsed.year != normalizedYear) {
          return '';
        }
        return '${day.toString().padLeft(2, '0')}-${month.toString().padLeft(2, '0')}-$normalizedYear';
      } catch (_) {
        return '';
      }
    }

    List<String> extractDates(String line) {
      final List<String> found = [];
      final RegExp normal = RegExp(r'(?<![A-Za-z0-9])(\d{1,2})\s*[\/\-.]\s*(\d{1,2})\s*[\/\-.]\s*(\d{2,4})(?![A-Za-z0-9])');
      for (final Match match in normal.allMatches(line)) {
        final String value = validDate(
          int.tryParse(match.group(1) ?? '') ?? -1,
          int.tryParse(match.group(2) ?? '') ?? -1,
          int.tryParse(match.group(3) ?? '') ?? -1,
        );
        if (value.isNotEmpty) {
          found.add(value);
        }
      }
      return found;
    }

    for (int i = 0; i < lines.length; i++) {
      final String line = lines[i];
      if (line.toLowerCase().contains('date')) {
        final List<String> sameLine = extractDates(line);
        if (sameLine.isNotEmpty) {
          return sameLine.first;
        }
        if (i + 1 < lines.length) {
          final List<String> nextLine = extractDates(lines[i + 1]);
          if (nextLine.isNotEmpty) {
            return nextLine.first;
          }
        }
      }
    }

    for (final String line in lines) {
      final String lower = line.toLowerCase();
      if (lower.contains('gstin') || lower.contains('receipt') || lower.contains('phone') || lower.contains('pin code')) {
        continue;
      }
      final List<String> dates = extractDates(line);
      if (dates.isNotEmpty) {
        return dates.first;
      }
    }

    return '';
  }

  static String detectAmount(String rawText) {
    final List<String> lines = rawText
        .split('\n')
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty)
        .toList();

    if (lines.isEmpty) {
      return '';
    }

    final List<String> strongWords = [
      'grand total', 'net total', 'total amount', 'amount paid', 'amount payable',
      'total payable', 'balance due', 'paid amount', 'cash paid', 'card paid',
      'upi paid', 'card', 'cash', 'upi', 'payment', 'fare', 'total', 'amount',
      'price', 'rs', 'inr', '₹'
    ];

    final List<String> rejectWords = [
      'cgst', 'sgst', 'igst', 'taxable', 'tax amount', 'total tax', 'subtotal',
      'sub total', 'rounding', 'round off', 'change', 'tendered', 'gstin',
      'gst no', 'receipt no', 'bill no', 'invoice no', 'order no', 'token',
      'phone', 'mobile', 'contact', 'pin code', 'pincode', 'date', 'time',
      'qty', 'quantity'
    ];

    bool isTableHeader(String line) {
      final String lower = line.toLowerCase();
      return lower.contains('price') && lower.contains('total') &&
          (lower.contains('qty') || lower.contains('quantity'));
    }

    bool hasStrongContext(String line) {
      final String lower = line.toLowerCase();
      return strongWords.any((word) => lower.contains(word));
    }

    bool hasRejectContext(String line) {
      final String lower = line.toLowerCase();
      if (lower.contains('grand total') || lower.contains('net total') ||
          lower.contains('total amount') || lower.contains('amount paid') ||
          lower.contains('amount payable') || lower.contains('total payable') ||
          lower.contains('balance due') || lower == 'total' || lower == 'card' ||
          lower == 'cash' || lower == 'upi' || lower.contains('fare')) {
        return false;
      }
      return rejectWords.any((word) => lower.contains(word));
    }

    List<double> numbersFromLine(String line) {
      final List<double> values = [];
      final String cleanedLine = line
          .replaceAll('₹', ' Rs ')
          .replaceAll('/-', ' ')
          .replaceAll('=00', '.00')
          .replaceAll('=0', '.0');

      final RegExp numberPattern = RegExp(
        r'(?<![A-Za-z0-9])(?:rs\.?|inr)?\s*(\d{1,6}(?:,\d{2,3})*(?:\.\d{1,2})?)(?![A-Za-z0-9])',
        caseSensitive: false,
      );

      for (final Match match in numberPattern.allMatches(cleanedLine)) {
        final String valueText = (match.group(1) ?? '').trim().replaceAll(',', '');
        final double? value = double.tryParse(valueText);
        if (value == null) {
          continue;
        }
        if (value <= 1 || value > 200000) {
          continue;
        }
        final String lower = line.toLowerCase();
        if (value >= 2000 && value <= 2100 && lower.contains('date')) {
          continue;
        }
        if (valueText.length >= 7) {
          continue;
        }
        values.add(value);
      }

      return values;
    }

    String formatAmount(double value) => value.toStringAsFixed(2);

    for (int i = 0; i < lines.length; i++) {
      final String line = lines[i];
      final String lower = line.toLowerCase();
      if (isTableHeader(line) || !hasStrongContext(line) || hasRejectContext(line)) {
        continue;
      }

      final List<double> sameLineValues = numbersFromLine(line);
      if (sameLineValues.isNotEmpty) {
        sameLineValues.sort();
        return formatAmount(sameLineValues.last);
      }

      final bool canLookAhead = lower == 'total' || lower == 'card' || lower == 'cash' ||
          lower == 'upi' || lower.contains('grand total') || lower.contains('net total') ||
          lower.contains('total amount') || lower.contains('amount paid') ||
          lower.contains('total payable') || lower.contains('fare');

      if (!canLookAhead) {
        continue;
      }

      for (int j = i + 1; j < lines.length && j <= i + 3; j++) {
        final String nextLine = lines[j];
        if (isTableHeader(nextLine) || hasRejectContext(nextLine)) {
          continue;
        }
        final List<double> nextValues = numbersFromLine(nextLine);
        if (nextValues.isNotEmpty) {
          nextValues.sort();
          return formatAmount(nextValues.last);
        }
      }
    }

    for (final String line in lines) {
      if (isTableHeader(line) || hasRejectContext(line)) {
        continue;
      }
      final List<double> values = numbersFromLine(line);
      if (values.length >= 2) {
        values.sort();
        return formatAmount(values.last);
      }
    }

    final Set<String> uniqueValues = <String>{};
    for (final String line in lines) {
      if (isTableHeader(line) || hasRejectContext(line)) {
        continue;
      }
      for (final double value in numbersFromLine(line)) {
        uniqueValues.add(value.toStringAsFixed(2));
      }
    }

    if (uniqueValues.length == 1) {
      return uniqueValues.first;
    }

    return '';
  }
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final ImagePicker _picker = ImagePicker();

  File? _selectedImage;
  fs.XFile? _selectedPdf;
  SelectedInputType _selectedInputType = SelectedInputType.none;

  String _status = 'Status: Ready for image/PDF input setup';

  void _comingSoon(BuildContext context, String feature) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('$feature will be added in the next step.'),
      ),
    );
  }

  Future<void> _pickImageFromCamera() async {
    try {
      setState(() {
        _status = 'Status: Opening camera...';
      });

      final XFile? pickedFile = await _picker.pickImage(
        source: ImageSource.camera,
        imageQuality: 85,
      );

      if (pickedFile == null) {
        setState(() {
          _status = 'Status: No photo captured';
        });
        return;
      }

      setState(() {
        _selectedImage = File(pickedFile.path);
        _selectedPdf = null;
        _selectedInputType = SelectedInputType.image;
        _status = 'Status: Camera image captured successfully';
      });
    } catch (e) {
      setState(() {
        _status = 'Status: Failed to capture image: $e';
      });
    }
  }

  Future<void> _pickImageFromGallery() async {
    try {
      setState(() {
        _status = 'Status: Opening gallery...';
      });

      final XFile? pickedFile = await _picker.pickImage(
        source: ImageSource.gallery,
        imageQuality: 85,
      );

      if (pickedFile == null) {
        setState(() {
          _status = 'Status: No image selected';
        });
        return;
      }

      setState(() {
        _selectedImage = File(pickedFile.path);
        _selectedPdf = null;
        _selectedInputType = SelectedInputType.image;
        _status = 'Status: Image selected successfully';
      });
    } catch (e) {
      setState(() {
        _status = 'Status: Failed to pick image: $e';
      });
    }
  }

  Future<void> _pickPdf() async {
    try {
      setState(() {
        _status = 'Status: Opening PDF picker...';
      });

      const fs.XTypeGroup pdfTypeGroup = fs.XTypeGroup(
        label: 'PDF files',
        extensions: <String>['pdf'],
        mimeTypes: <String>['application/pdf'],
      );

      final fs.XFile? pickedPdf = await fs.openFile(
        acceptedTypeGroups: <fs.XTypeGroup>[pdfTypeGroup],
      );

      if (pickedPdf == null) {
        setState(() {
          _status = 'Status: No PDF selected';
        });
        return;
      }

      setState(() {
        _selectedPdf = pickedPdf;
        _selectedImage = null;
        _selectedInputType = SelectedInputType.pdf;
        _status = 'Status: PDF selected successfully';
      });
    } catch (e) {
      setState(() {
        _status = 'Status: Failed to pick PDF: $e';
      });
    }
  }

  void _removeSelectedFile() {
    setState(() {
      _selectedImage = null;
      _selectedPdf = null;
      _selectedInputType = SelectedInputType.none;
      _status = 'Status: Selected file removed';
    });
  }

  void _goToPreviewScreen() {
    if (_selectedInputType == SelectedInputType.none) {
      setState(() {
        _status = 'Status: Please select or scan a bill first';
      });
      return;
    }

    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => ResultPreviewScreen(
          selectedInputType: _selectedInputType,
          imageFile: _selectedImage,
          pdfFile: _selectedPdf,
        ),
      ),
    );
  }

  Widget _buildSelectedFilePreview() {
    if (_selectedInputType == SelectedInputType.none) {
      return const Center(
        child: Text(
          'No bill image or PDF selected yet',
          style: TextStyle(fontSize: 16),
        ),
      );
    }

    if (_selectedInputType == SelectedInputType.image &&
        _selectedImage != null) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(16),
        child: Image.file(
          _selectedImage!,
          fit: BoxFit.contain,
        ),
      );
    }

    if (_selectedInputType == SelectedInputType.pdf && _selectedPdf != null) {
      return Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(
              Icons.picture_as_pdf,
              size: 80,
              color: Colors.red,
            ),
            const SizedBox(height: 16),
            const Text(
              'PDF selected',
              style: TextStyle(
                fontSize: 22,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 12),
            Text(
              _selectedPdf!.name,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 15),
            ),
            const SizedBox(height: 8),
            Text(
              _selectedPdf!.path,
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontSize: 12,
                color: Colors.black54,
              ),
            ),
          ],
        ),
      );
    }

    return const Center(
      child: Text('Unsupported file selected'),
    );
  }

  @override
  Widget build(BuildContext context) {
    final bool hasSelectedFile = _selectedInputType != SelectedInputType.none;

    return Scaffold(
      backgroundColor: const Color(0xFFF7F4FF),
      appBar: AppBar(
        title: const Text('Bill Reader OCR'),
        centerTitle: true,
        actions: [
          IconButton(
            icon: const Icon(Icons.drafts_outlined),
            tooltip: 'Drafts',
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => const DraftsScreen(),
                ),
              );
            },
          ),
        ],
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            children: [
              const Icon(
                Icons.receipt_long,
                size: 60,
                color: Colors.deepPurple,
              ),
              const SizedBox(height: 8),
              const Text(
                'Smart Bill Reader',
                style: TextStyle(
                  fontSize: 24,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 6),
              const Text(
                'Scan bills, upload images/PDFs, detect fake bills, and save drafts.',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 14),
              ),
              const SizedBox(height: 18),
              SizedBox(
                width: double.infinity,
                height: 50,
                child: ElevatedButton.icon(
                  icon: const Icon(Icons.camera_alt),
                  label: const Text('Scan Bill with Camera'),
                  onPressed: _pickImageFromCamera,
                ),
              ),
              const SizedBox(height: 10),
              SizedBox(
                width: double.infinity,
                height: 50,
                child: ElevatedButton.icon(
                  icon: const Icon(Icons.image_outlined),
                  label: const Text('Upload Image'),
                  onPressed: _pickImageFromGallery,
                ),
              ),
              const SizedBox(height: 10),
              SizedBox(
                width: double.infinity,
                height: 50,
                child: OutlinedButton.icon(
                  icon: const Icon(Icons.picture_as_pdf),
                  label: const Text('Upload PDF'),
                  onPressed: _pickPdf,
                ),
              ),
              const SizedBox(height: 16),
              Expanded(
                child: Container(
                  width: double.infinity,
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(
                      color: Colors.deepPurple.withOpacity(0.2),
                    ),
                  ),
                  child: _buildSelectedFilePreview(),
                ),
              ),
              const SizedBox(height: 12),
              if (hasSelectedFile) ...[
                SizedBox(
                  width: double.infinity,
                  height: 48,
                  child: ElevatedButton.icon(
                    icon: const Icon(Icons.arrow_forward),
                    label: const Text('Continue to Preview'),
                    onPressed: _goToPreviewScreen,
                  ),
                ),
                const SizedBox(height: 10),
                SizedBox(
                  width: double.infinity,
                  height: 48,
                  child: OutlinedButton.icon(
                    icon: const Icon(Icons.delete_outline),
                    label: const Text('Remove Selected File'),
                    onPressed: _removeSelectedFile,
                  ),
                ),
              ],
              const SizedBox(height: 12),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Text(
                  _status,
                  textAlign: TextAlign.center,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class ResultPreviewScreen extends StatefulWidget {
  final SelectedInputType selectedInputType;
  final File? imageFile;
  final fs.XFile? pdfFile;

  const ResultPreviewScreen({
    super.key,
    required this.selectedInputType,
    required this.imageFile,
    required this.pdfFile,
  });

  @override
  State<ResultPreviewScreen> createState() => _ResultPreviewScreenState();
}

class _ResultPreviewScreenState extends State<ResultPreviewScreen> {
  static const String _paddleApiUrl = 'http://127.0.0.1:8000/ocr/paddle';

  final TextEditingController _reimbursementTypeController =
      TextEditingController();
  final TextEditingController _dateController = TextEditingController();
  final TextEditingController _projectController = TextEditingController();
  final TextEditingController _amountController = TextEditingController();
  final TextEditingController _commentsController = TextEditingController();

  final List<String> _reimbursementTypes = [
    'Travel Expenses',
    'Food / Meals',
    'IT Equipment for work',
    'Office Supplies / Miscellaneous',
    'Client Visit Expenses',
    'Training / Certification Fees',
    'Accommodation / Stay',
    'Other',
  ];

  String? _selectedReimbursementType;

  String _status = 'Status: Ready for bill analysis';
  String _ocrText = '';
  String _fieldConfidenceMessage = '';
  bool _isProcessing = false;
  bool _isPaddleProcessing = false;
  bool _hasAnalyzed = false;

  Future<void> _startBillAnalysis() async {
    if (widget.selectedInputType == SelectedInputType.pdf) {
      setState(() {
        _status =
            'Status: PDF selected. PDF-to-image conversion will be added in the next step.';
        _commentsController.text =
            'PDF selected. PDF-to-image conversion will be added in the next step.';
        _hasAnalyzed = true;
      });
      return;
    }

    if (widget.imageFile == null) {
      setState(() {
        _status = 'Status: No image found for OCR';
      });
      return;
    }

    final stopwatch = Stopwatch()..start();

    setState(() {
      _isProcessing = true;
      _ocrText = '';
      _fieldConfidenceMessage = '';
      _status = 'Status: Reading bill...';
      _hasAnalyzed = false;
      _amountController.clear();
    });

    final TextRecognizer textRecognizer = TextRecognizer(
      script: TextRecognitionScript.latin,
    );

    try {
      final InputImage inputImage = InputImage.fromFile(widget.imageFile!);
      final RecognizedText recognizedText =
          await textRecognizer.processImage(inputImage);

      stopwatch.stop();

      final String rawText = recognizedText.text.trim();

      setState(() {
        _ocrText = rawText.isEmpty ? 'No readable text detected.' : rawText;
        _status =
            'Status: Quick scan completed in ${stopwatch.elapsedMilliseconds} ms';
        _hasAnalyzed = true;
      });

      _autoFillQuickFields(rawText);

      final bool phoneOnline = await _phoneHasInternet();

      if (phoneOnline) {
        debugPrint('PHONE ONLINE: Trying existing PaddleOCR flow first.');
        final bool paddleWorked = await _runPaddleOcrFallback();

        if (!paddleWorked) {
          debugPrint(
            'PADDLE NOT REACHABLE: Using Google ML parser as safe fallback.',
          );
          _runOfflineGoogleMlFinalizer(rawText);
        }
      } else {
        debugPrint('PHONE OFFLINE: Using Google ML offline parser.');
        _runOfflineGoogleMlFinalizer(rawText);
      }
    } catch (e) {
      setState(() {
        _status = 'Status: OCR failed: $e';
        _commentsController.text = 'OCR failed: $e';
        _hasAnalyzed = true;
      });
    } finally {
      await textRecognizer.close();

      if (mounted) {
        setState(() {
          _isProcessing = false;
        });
      }
    }
  }

Future<bool> _phoneHasInternet() async {
    try {
      final List<InternetAddress> result = await InternetAddress.lookup(
        'example.com',
      ).timeout(const Duration(seconds: 2));

      return result.isNotEmpty && result.first.rawAddress.isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  void _runOfflineGoogleMlFinalizer(String rawText) {
    final String lowerText = rawText.toLowerCase();
    final String detectedType = _guessReimbursementType(lowerText);
    final String detectedDate = _detectDate(rawText);
    final String detectedAmount = _detectOfflineAmount(rawText);

    final int wordCount = rawText
        .split(RegExp(r'\s+'))
        .where((word) => word.trim().isNotEmpty)
        .length;

    final bool readableText = wordCount >= 5;
    final bool hasReliableAmount = detectedAmount.trim().isNotEmpty;
    final bool hasReliableDate = detectedDate.trim().isNotEmpty;

    if (readableText && hasReliableAmount && hasReliableDate) {
      setState(() {
        _selectedReimbursementType = detectedType;
        _reimbursementTypeController.text = detectedType;

        _dateController.value = TextEditingValue(
          text: detectedDate,
          selection: TextSelection.collapsed(offset: detectedDate.length),
        );

        _amountController.value = TextEditingValue(
          text: detectedAmount,
          selection: TextSelection.collapsed(offset: detectedAmount.length),
        );

        _commentsController.text = rawText.trim().isEmpty
            ? 'Offline OCR completed, but no readable text was found.'
            : rawText.trim();

        _status = 'Status: Offline OCR completed successfully';
        _fieldConfidenceMessage =
            'Offline result extracted using Google ML Kit. Please verify before saving.';
        _hasAnalyzed = true;
      });

      return;
    }

    String reason = 'Offline OCR could not confidently extract required fields.';

    if (!readableText) {
      reason = 'OCR text is too low or unreadable.';
    } else if (!hasReliableAmount && !hasReliableDate) {
      reason = 'Amount and date were not confidently detected.';
    } else if (!hasReliableAmount) {
      reason = 'Amount was not confidently detected.';
    } else if (!hasReliableDate) {
      reason = 'Date was not confidently detected.';
    }

    _saveWaitingDraft(
      rawText: rawText,
      detectedDate: detectedDate,
      detectedAmount: detectedAmount,
      detectedType: detectedType,
      reason: reason,
    );
  }

  void _saveWaitingDraft({
    required String rawText,
    required String detectedDate,
    required String detectedAmount,
    required String detectedType,
    required String reason,
  }) {
    final String imagePath = widget.imageFile?.path ?? '';

    if (imagePath.trim().isEmpty) {
      setState(() {
        _status = 'Status: Could not save draft because image path is missing.';
        _fieldConfidenceMessage =
            'Offline OCR failed and draft could not be saved.';
        _hasAnalyzed = true;
      });
      return;
    }

    final OfflineBillDraft draft = OfflineBillDraft(
      id: DateTime.now().microsecondsSinceEpoch.toString(),
      imagePath: imagePath,
      rawText: rawText,
      detectedDate: detectedDate,
      detectedAmount: detectedAmount,
      detectedType: detectedType,
      reason: reason,
      createdAt: DateTime.now(),
    );

    OfflineDraftStore.add(draft);

    setState(() {
      _selectedReimbursementType = detectedType;
      _reimbursementTypeController.text = detectedType;

      if (detectedDate.isNotEmpty) {
        _dateController.text = detectedDate;
      }

      if (detectedAmount.isNotEmpty) {
        _amountController.text = detectedAmount;
      } else {
        _amountController.clear();
      }

      _commentsController.text = rawText.trim().isEmpty
          ? 'Saved to Drafts. Waiting for internet because OCR text was not readable.'
          : rawText.trim();

      _status = 'Status: Saved to Drafts. Waiting for internet.';
      _fieldConfidenceMessage =
          'Saved to Drafts because offline extraction was incomplete.';
      _hasAnalyzed = true;
    });
  }

  String _detectOfflineAmount(String rawText) {
    final List<String> lines = rawText
        .split('\n')
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty)
        .toList();

    if (lines.isEmpty) {
      return '';
    }

    final List<String> strongWords = [
      'grand total',
      'net total',
      'total amount',
      'amount paid',
      'amount payable',
      'total payable',
      'balance due',
      'paid amount',
      'cash paid',
      'card paid',
      'upi paid',
      'card',
      'cash',
      'upi',
      'payment',
      'fare',
      'total',
      'amount',
      'price',
      'rs',
      'inr',
      '₹',
    ];

    final List<String> rejectWords = [
      'cgst',
      'sgst',
      'igst',
      'taxable',
      'tax amount',
      'total tax',
      'subtotal',
      'sub total',
      'rounding',
      'round off',
      'change',
      'tendered',
      'gstin',
      'gst no',
      'receipt no',
      'bill no',
      'invoice no',
      'order no',
      'token',
      'phone',
      'mobile',
      'contact',
      'pin code',
      'pincode',
      'date',
      'time',
      'qty',
      'quantity',
    ];

    bool isTableHeader(String line) {
      final String lower = line.toLowerCase();
      return lower.contains('price') &&
          lower.contains('total') &&
          (lower.contains('qty') || lower.contains('quantity'));
    }

    bool hasStrongContext(String line) {
      final String lower = line.toLowerCase();

      for (final word in strongWords) {
        if (lower.contains(word)) {
          return true;
        }
      }

      return false;
    }

    bool hasRejectContext(String line) {
      final String lower = line.toLowerCase();

      if (lower.contains('grand total') ||
          lower.contains('net total') ||
          lower.contains('total amount') ||
          lower.contains('amount paid') ||
          lower.contains('amount payable') ||
          lower.contains('total payable') ||
          lower.contains('balance due') ||
          lower == 'total' ||
          lower == 'card' ||
          lower == 'cash' ||
          lower == 'upi' ||
          lower.contains('fare')) {
        return false;
      }

      for (final word in rejectWords) {
        if (lower.contains(word)) {
          return true;
        }
      }

      return false;
    }

    List<double> numbersFromLine(String line) {
      final List<double> values = [];

      final String cleanedLine = line
          .replaceAll('₹', ' Rs ')
          .replaceAll('/-', ' ')
          .replaceAll('=00', '.00')
          .replaceAll('=0', '.0');

      final RegExp numberPattern = RegExp(
        r'(?<![A-Za-z0-9])(?:rs\.?|inr)?\s*(\d{1,6}(?:,\d{2,3})*(?:\.\d{1,2})?)(?![A-Za-z0-9])',
        caseSensitive: false,
      );

      for (final Match match in numberPattern.allMatches(cleanedLine)) {
        String valueText = (match.group(1) ?? '').trim().replaceAll(',', '');
        final double? value = double.tryParse(valueText);

        if (value == null) {
          continue;
        }

        if (value <= 1 || value > 200000) {
          continue;
        }

        final String lower = line.toLowerCase();

        if (value >= 2000 && value <= 2100 && lower.contains('date')) {
          continue;
        }

        if (valueText.length >= 7) {
          continue;
        }

        values.add(value);
      }

      return values;
    }

    String formatAmount(double value) {
      return value.toStringAsFixed(2);
    }

    // First priority: explicit payment/final total labels.
    for (int i = 0; i < lines.length; i++) {
      final String line = lines[i];
      final String lower = line.toLowerCase();

      if (isTableHeader(line)) {
        continue;
      }

      if (!hasStrongContext(line)) {
        continue;
      }

      if (hasRejectContext(line)) {
        continue;
      }

      final List<double> sameLineValues = numbersFromLine(line);
      if (sameLineValues.isNotEmpty) {
        sameLineValues.sort();
        return formatAmount(sameLineValues.last);
      }

      final bool canLookAhead = lower == 'total' ||
          lower == 'card' ||
          lower == 'cash' ||
          lower == 'upi' ||
          lower.contains('grand total') ||
          lower.contains('net total') ||
          lower.contains('total amount') ||
          lower.contains('amount paid') ||
          lower.contains('total payable') ||
          lower.contains('fare');

      if (!canLookAhead) {
        continue;
      }

      for (int j = i + 1; j < lines.length && j <= i + 3; j++) {
        final String nextLine = lines[j];

        if (isTableHeader(nextLine) || hasRejectContext(nextLine)) {
          continue;
        }

        final List<double> nextLineValues = numbersFromLine(nextLine);
        if (nextLineValues.isNotEmpty) {
          nextLineValues.sort();
          return formatAmount(nextLineValues.last);
        }
      }
    }

    // Second priority: item rows with repeated price/total, e.g. Cold Drink 100.00 100.00 1.
    for (final String line in lines) {
      if (isTableHeader(line) || hasRejectContext(line)) {
        continue;
      }

      final List<double> values = numbersFromLine(line);
      if (values.length >= 2) {
        values.sort();
        return formatAmount(values.last);
      }
    }

    // Last safe fallback: exactly one safe amount-like number in the whole OCR text.
    final List<double> looseSafeNumbers = [];

    for (final String line in lines) {
      if (isTableHeader(line) || hasRejectContext(line)) {
        continue;
      }

      final List<double> values = numbersFromLine(line);
      for (final double value in values) {
        looseSafeNumbers.add(value);
      }
    }

    final Set<String> uniqueValues = looseSafeNumbers
        .map((value) => value.toStringAsFixed(2))
        .toSet();

    if (uniqueValues.length == 1 && uniqueValues.isNotEmpty) {
      return uniqueValues.first;
    }

    return '';
  }

  String _extractBackendDateFromResponse(Map data, String paddleText) {
    final List<String> possibleKeys = [
      'date',
      'detectedDate',
      'billDate',
      'invoiceDate',
      'receiptDate',
    ];

    for (final String key in possibleKeys) {
      final String value = (data[key] ?? '').toString().trim();

      if (value.isNotEmpty) {
        return value;
      }
    }

    final String fallbackDate = _detectDate(paddleText);

    if (fallbackDate.trim().isNotEmpty) {
      return fallbackDate.trim();
    }

    return '';
  }

 Future<bool> _runPaddleOcrFallback() async {
  if (widget.imageFile == null) {
    return false;
  }

  setState(() {
    _isPaddleProcessing = true;
    _status = 'Status: Finalizing details...';
    _fieldConfidenceMessage = 'Finalizing details...';
  });

  debugPrint('PADDLE CALL STARTED');
  debugPrint('PADDLE API URL: $_paddleApiUrl');
  debugPrint('IMAGE PATH: ${widget.imageFile?.path}');

  final stopwatch = Stopwatch()..start();

  try {
    final dio.Dio client = dio.Dio(
      dio.BaseOptions(
        connectTimeout: const Duration(seconds: 10),
        sendTimeout: const Duration(seconds: 20),
        receiveTimeout: const Duration(seconds: 60),
      ),
    );

    final dio.FormData formData = dio.FormData.fromMap({
      'file': await dio.MultipartFile.fromFile(
        widget.imageFile!.path,
        filename: 'bill_image.jpg',
      ),
    });

    final dio.Response response = await client.post(
      _paddleApiUrl,
      data: formData,
    );

    debugPrint('PADDLE RESPONSE RAW: ${response.data}');

    stopwatch.stop();

    final dynamic responseData = response.data;

    if (responseData is Map && responseData['success'] == true) {
      final Map data = responseData;

      final bool isFake = data['isFake'] == true;

      final String paddleText = (data['rawText'] ?? '').toString().trim();
      final String backendAmount = (data['amount'] ?? '').toString().trim();

      final String backendDate =
          (data['date'] ??
                  data['detectedDate'] ??
                  data['billDate'] ??
                  data['invoiceDate'] ??
                  data['receiptDate'] ??
                  '')
              .toString()
              .trim();

      final String backendType =
          (data['reimbursementType'] ?? '').toString().trim();

      final String backendComments =
          (data['comments'] ?? '').toString().trim();

      debugPrint('BACKEND AMOUNT FINAL: $backendAmount');
      debugPrint('BACKEND DATE FINAL: $backendDate');
      debugPrint('BACKEND TYPE FINAL: $backendType');

      final int serverTimeMs =
          int.tryParse((data['processingTimeMs'] ?? '').toString()) ??
              stopwatch.elapsedMilliseconds;

      if (isFake) {
        setState(() {
          _ocrText = paddleText;

          _selectedReimbursementType = null;
          _reimbursementTypeController.clear();
          _dateController.clear();
          _projectController.clear();
          _amountController.clear();

          _commentsController.text = backendComments.isNotEmpty
              ? backendComments
              : 'Bill is detected to be fake.';

          _status = 'Status: Bill authenticity check completed';
          _fieldConfidenceMessage = 'Bill authenticity check completed.';
          _hasAnalyzed = true;
        });
        return true;
      }

      setState(() {
        if (paddleText.isNotEmpty) {
          _ocrText = paddleText;
        }

        _status = 'Status: Details finalized in ${serverTimeMs} ms';
        _fieldConfidenceMessage =
            'Details extracted. Please verify before saving.';
        _hasAnalyzed = true;

        if (backendAmount.isNotEmpty) {
          _amountController.value = TextEditingValue(
            text: backendAmount,
            selection: TextSelection.collapsed(offset: backendAmount.length),
          );
        }

        if (backendDate.isNotEmpty) {
          _dateController.value = TextEditingValue(
            text: backendDate,
            selection: TextSelection.collapsed(offset: backendDate.length),
          );
        }

        if (backendType.isNotEmpty &&
            _reimbursementTypes.contains(backendType)) {
          _selectedReimbursementType = backendType;
          _reimbursementTypeController.text = backendType;
        }

        if (backendComments.isNotEmpty) {
          _commentsController.text = backendComments;
        }
      });

      // Extra force-write after the UI frame finishes.
      // This prevents the date field from being overwritten by earlier quick OCR state.
      if (backendDate.isNotEmpty) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) {
            return;
          }

          _dateController.value = TextEditingValue(
            text: backendDate,
            selection: TextSelection.collapsed(offset: backendDate.length),
          );

          debugPrint('DATE FIELD FORCE SET TO: ${_dateController.text}');
        });
      }

      return true;
    } else {
      setState(() {
        _status = 'Status: Details extracted. Please verify before saving.';
        _fieldConfidenceMessage =
            'Details extracted. Please verify before saving.';
        _hasAnalyzed = true;
      });
      return false;
    }
  } catch (e) {
    debugPrint('PADDLE ERROR: $e');

    setState(() {
      _status = 'Status: Details extracted. Please verify before saving.';
      _fieldConfidenceMessage =
          'Details extracted. Please verify before saving.';
      _hasAnalyzed = true;
    });
    return false;
  } finally {
    if (mounted) {
      setState(() {
        _isPaddleProcessing = false;
      });
    }
  }
}
  void _autoFillQuickFields(String rawText) {
    final String lowerText = rawText.toLowerCase();

    final String reimbursementType = _guessReimbursementType(lowerText);
    final String detectedDate = _detectDate(rawText);

    setState(() {
      _selectedReimbursementType = reimbursementType;
      _reimbursementTypeController.text = reimbursementType;

      if (detectedDate.isNotEmpty) {
        _dateController.text = detectedDate;
      }

      if (_projectController.text.trim().isEmpty) {
        _projectController.text = '';
      }

      _fieldConfidenceMessage = 'Details extracted. Please verify before saving.';

      _commentsController.text = rawText.trim().isEmpty
          ? 'No readable OCR text detected.'
          : rawText.trim();
    });
  }

  String _guessReimbursementType(String lowerText) {
    if (_containsAny(lowerText, [
      'hotel',
      'room',
      'stay',
      'lodging',
      'accommodation',
      'oyo',
      'airbnb',
      'resort',
      'inn',
    ])) {
      return 'Accommodation / Stay';
    }

    if (_containsAny(lowerText, [
      'xerox',
      'notary',
      'franking',
      'spiral binding',
      'lamination',
      'scanning',
      'cartridge refill',
      'd.t.p',
      'photo print',
      'online services',
      'photocopy',
      'stationery',
      'printer',
      'paper',
      'binding',
    ])) {
      return 'Office Supplies / Miscellaneous';
    }

    if (_containsAny(lowerText, [
      'restaurant',
      'cafe',
      'food',
      'meal',
      'swiggy',
      'zomato',
      'tea',
      'coffee',
      'pizza',
      'burger',
      'biryani',
      'dosa',
      'idli',
      'kitchen',
      'bakery',
      'canteen',
      'dining',
      'mcdonald',
      'kfc',
      'domino',
      'subway',
    ])) {
      return 'Food / Meals';
    }

    if (_containsAny(lowerText, [
      'uber',
      'ola',
      'rapido',
      'bus',
      'train',
      'railway',
      'flight',
      'airlines',
      'taxi',
      'cab',
      'fuel',
      'petrol',
      'diesel',
      'parking',
      'toll',
      'metro',
      'ticket',
      'boarding',
      'pushpak',
      'depot',
      'airport to',
      'fare',
    ])) {
      return 'Travel Expenses';
    }

    if (_containsAny(lowerText, [
      'laptop',
      'keyboard',
      'mouse',
      'monitor',
      'charger',
      'adapter',
      'software',
      'hardware',
      'ssd',
      'hdd',
      'ram',
      'router',
      'cable',
      'pendrive',
      'printer cartridge',
      'electronics',
    ])) {
      return 'IT Equipment for work';
    }

    if (_containsAny(lowerText, [
      'pen',
      'paper',
      'stationery',
      'printer',
      'notebook',
      'file',
      'folder',
      'office',
      'supplies',
      'miscellaneous',
      'xerox',
      'photocopy',
      'stapler',
    ])) {
      return 'Office Supplies / Miscellaneous';
    }

    if (_containsAny(lowerText, [
      'client',
      'meeting',
      'visit',
      'business visit',
      'customer',
      'conference room',
    ])) {
      return 'Client Visit Expenses';
    }

    if (_containsAny(lowerText, [
      'course',
      'training',
      'certification',
      'workshop',
      'seminar',
      'webinar',
      'exam fee',
      'learning',
    ])) {
      return 'Training / Certification Fees';
    }

    return 'Other';
  }

  bool _containsAny(String text, List<String> keywords) {
    for (final keyword in keywords) {
      if (text.contains(keyword)) {
        return true;
      }
    }
    return false;
  }

  String _detectDate(String rawText) {
    final List<String> lines = rawText
        .split('\n')
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty)
        .toList();

    final List<String> rejectLineWords = [
      'address',
      'beside',
      'hotel',
      'road',
      'street',
      'colony',
      'nagar',
      'punjagutta',
      'hyderabad',
      'pincode',
      'pin code',
      'pin:',
      'cell',
      'phone',
      'mobile',
      'contact',
      'email',
      'gstin',
      'receipt no',
      'bill no',
      'invoice no',
      'order no',
      'transaction',
      'txn',
    ];

    int normalizeYear(int year) {
      if (year < 100) {
        if (year <= 79) {
          return 2000 + year;
        }
        return 1900 + year;
      }
      return year;
    }

    String validDate(int day, int month, int year) {
      final int normalizedYear = normalizeYear(year);

      if (normalizedYear < 2000 || normalizedYear > 2100) {
        return '';
      }

      try {
        final DateTime parsed = DateTime(normalizedYear, month, day);

        if (parsed.day != day ||
            parsed.month != month ||
            parsed.year != normalizedYear) {
          return '';
        }

        final String dd = day.toString().padLeft(2, '0');
        final String mm = month.toString().padLeft(2, '0');

        return '$dd-$mm-$normalizedYear';
      } catch (_) {
        return '';
      }
    }

    bool lineIsBadContext(String line) {
      final String lower = line.toLowerCase();

      if (rejectLineWords.any((word) => lower.contains(word)) &&
          !lower.contains('date')) {
        return true;
      }

      if (line.contains('#') && !lower.contains('date')) {
        return true;
      }

      return false;
    }

    List<String> extractDatesFromLine(String line) {
      final List<String> found = [];

      final RegExp numericPattern = RegExp(
        r'(?<![A-Za-z0-9])(\d{1,2})\s*[\/\-.]\s*(\d{1,2})\s*[\/\-.]\s*(\d{2,4})(?![A-Za-z0-9])',
      );

      for (final Match match in numericPattern.allMatches(line)) {
        final int day = int.tryParse(match.group(1) ?? '') ?? -1;
        final int month = int.tryParse(match.group(2) ?? '') ?? -1;
        final int year = int.tryParse(match.group(3) ?? '') ?? -1;

        final String normalized = validDate(day, month, year);
        if (normalized.isNotEmpty) {
          found.add(normalized);
        }
      }

      final RegExp ymdPattern = RegExp(
        r'(?<![A-Za-z0-9])(\d{4})\s*[\/\-.]\s*(\d{1,2})\s*[\/\-.]\s*(\d{1,2})(?![A-Za-z0-9])',
      );

      for (final Match match in ymdPattern.allMatches(line)) {
        final int year = int.tryParse(match.group(1) ?? '') ?? -1;
        final int month = int.tryParse(match.group(2) ?? '') ?? -1;
        final int day = int.tryParse(match.group(3) ?? '') ?? -1;

        final String normalized = validDate(day, month, year);
        if (normalized.isNotEmpty) {
          found.add(normalized);
        }
      }

      return found;
    }

    for (int i = 0; i < lines.length; i++) {
      final String line = lines[i];
      final String lower = line.toLowerCase();

      if (lower.contains('date')) {
        final List<String> dates = extractDatesFromLine(line);

        if (dates.isNotEmpty) {
          return dates.first;
        }

        if (i + 1 < lines.length) {
          final String nextLine = lines[i + 1];

          if (!lineIsBadContext(nextLine)) {
            final List<String> nextDates = extractDatesFromLine(nextLine);

            if (nextDates.isNotEmpty) {
              return nextDates.first;
            }
          }
        }
      }
    }

    for (final String line in lines) {
      if (lineIsBadContext(line)) {
        continue;
      }

      final List<String> dates = extractDatesFromLine(line);

      if (dates.isNotEmpty) {
        return dates.first;
      }
    }

    return '';
  }

  Widget _buildPreviewContent() {
    if (widget.selectedInputType == SelectedInputType.image &&
        widget.imageFile != null) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(16),
        child: Image.file(
          widget.imageFile!,
          fit: BoxFit.contain,
        ),
      );
    }

    if (widget.selectedInputType == SelectedInputType.pdf &&
        widget.pdfFile != null) {
      return Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(
              Icons.picture_as_pdf,
              size: 90,
              color: Colors.red,
            ),
            const SizedBox(height: 16),
            const Text(
              'PDF ready for processing',
              style: TextStyle(
                fontSize: 22,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 12),
            Text(
              widget.pdfFile!.name,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 15),
            ),
            const SizedBox(height: 8),
            Text(
              widget.pdfFile!.path,
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontSize: 12,
                color: Colors.black54,
              ),
            ),
          ],
        ),
      );
    }

    return const Center(
      child: Text('No valid file found'),
    );
  }

  Widget _buildOcrResultBox() {
    if (_ocrText.isEmpty) {
      return const SizedBox.shrink();
    }

    return Container(
      width: double.infinity,
      height: 150,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: Colors.deepPurple.withOpacity(0.2),
        ),
      ),
      child: SingleChildScrollView(
        child: Text(
          _ocrText,
          style: const TextStyle(fontSize: 14),
        ),
      ),
    );
  }

  Widget _buildConfidenceBox() {
    if (!_hasAnalyzed || _fieldConfidenceMessage.isEmpty) {
      return const SizedBox.shrink();
    }

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFFE8F5E9),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: Colors.green,
        ),
      ),
      child: Text(
        _fieldConfidenceMessage,
        textAlign: TextAlign.center,
        style: TextStyle(
          color: Colors.green.shade900,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }

  Widget _buildAmountSuffixIcon() {
    if (!_isPaddleProcessing) {
      return const SizedBox.shrink();
    }

    return const Padding(
      padding: EdgeInsets.all(12),
      child: SizedBox(
        width: 18,
        height: 18,
        child: CircularProgressIndicator(strokeWidth: 2),
      ),
    );
  }

  Widget _buildEditableExpenseFields() {
    if (!_hasAnalyzed) {
      return const SizedBox.shrink();
    }

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: Colors.deepPurple.withOpacity(0.2),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Expense Details',
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 14),
          DropdownButtonFormField<String>(
            value: _selectedReimbursementType,
            isExpanded: true,
            decoration: const InputDecoration(
              labelText: 'Reimbursement Type',
              border: OutlineInputBorder(),
            ),
            items: _reimbursementTypes.map((type) {
              return DropdownMenuItem<String>(
                value: type,
                child: Text(type),
              );
            }).toList(),
            onChanged: (value) {
              setState(() {
                _selectedReimbursementType = value;
                _reimbursementTypeController.text = value ?? '';
              });
            },
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _dateController,
            decoration: const InputDecoration(
              labelText: 'Date',
              hintText: 'Select Date',
              border: OutlineInputBorder(),
              suffixIcon: Icon(Icons.calendar_today),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _projectController,
            decoration: const InputDecoration(
              labelText: 'Project',
              hintText: 'Select Project',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _amountController,
            keyboardType: TextInputType.number,
            decoration: InputDecoration(
              labelText: 'Amount',
              hintText: _isPaddleProcessing ? 'Finalizing...' : 'Enter amount',
              border: const OutlineInputBorder(),
              suffixText: _isPaddleProcessing ? null : '₹',
              suffixIcon: _isPaddleProcessing ? _buildAmountSuffixIcon() : null,
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _commentsController,
            maxLines: 5,
            decoration: const InputDecoration(
              labelText: 'Comments',
              hintText: 'Enter comment here...',
              border: OutlineInputBorder(),
            ),
          ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    _reimbursementTypeController.dispose();
    _dateController.dispose();
    _projectController.dispose();
    _amountController.dispose();
    _commentsController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final bool isImageInput =
        widget.selectedInputType == SelectedInputType.image;

    return Scaffold(
      backgroundColor: const Color(0xFFF7F4FF),
      appBar: AppBar(
        title: const Text('Bill Preview'),
        centerTitle: true,
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: Column(
            children: [
              SizedBox(
                height: 260,
                child: Container(
                  width: double.infinity,
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(
                      color: Colors.deepPurple.withOpacity(0.2),
                    ),
                  ),
                  child: _buildPreviewContent(),
                ),
              ),
              const SizedBox(height: 12),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Text(
                  _status,
                  textAlign: TextAlign.center,
                ),
              ),
              const SizedBox(height: 12),
              _buildOcrResultBox(),
              const SizedBox(height: 12),
              _buildConfidenceBox(),
              const SizedBox(height: 12),
              _buildEditableExpenseFields(),
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                height: 52,
                child: ElevatedButton.icon(
                  icon: _isProcessing
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.verified_outlined),
                  label: Text(
                    _isProcessing
                        ? 'Analyzing...'
                        : isImageInput
                            ? 'Start Offline OCR'
                            : 'Start PDF Analysis',
                  ),
                  onPressed: _isProcessing ? null : _startBillAnalysis,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}