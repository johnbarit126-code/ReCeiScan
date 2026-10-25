import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:image_picker/image_picker.dart';
import 'package:camera/camera.dart' as cm;
import 'package:face_detection_tflite/face_detection_tflite.dart' as fd;
import 'package:shared_preferences/shared_preferences.dart';
import 'splash_page.dart';

// Temporary debug line to trace userId, role, count and sum of transactions
const bool kDebugLoad = false;

class ApiService {
  // ============================================================
  // API BASE URL
  // ============================================================
  static const String baseUrl =
      'https://orange-dunlin-410464.hostingersite.com/api.php';

  // Dapat PAREHO ng 'app_token' sa config.php ng server.
  // PALITAN ng bagong random na string (at ilagay din sa config.php).
  static const String appToken =
      '6ee116e2f51da1e8fcf4cd9678fe620008cffad500016c49';

  // Session token na galing sa login. Ipinapadala sa bawat tawag para
  // malaman ng server kung sino ang naka-login (hindi na ang user_id).
  static String sessionToken = '';

  // ============================================================
  // HELPER: SEND POST REQUEST
  // ============================================================
  // Ang POST ay hindi awtomatikong sumusunod sa redirect (hal. HTTP 307).
  // Dito, manu-mano nating sinusundan (hanggang 5 beses) at inuulit ang
  // POST sa bagong address para hindi mawala ang laman ng request.
  static Future<http.Response> _postFollowingRedirects(
    Uri url,
    Map<String, String> body,
  ) async {
    final client = http.Client();
    try {
      var current = url;

      for (var i = 0; i < 5; i++) {
        final req = http.Request('POST', current)
          ..followRedirects = false
          ..headers['ngrok-skip-browser-warning'] = 'true'
          ..bodyFields = body;

        final res = await http.Response.fromStream(await client.send(req));

        if (res.statusCode >= 300 && res.statusCode < 400) {
          final loc = res.headers['location'];
          if (loc == null || loc.isEmpty) {
            throw Exception(
              'The server answered HTTP ${res.statusCode} (redirect) from '
              '$current without saying where to go. Check the baseUrl.',
            );
          }
          current = current.resolve(loc);
          continue;
        }

        return res;
      }

      throw Exception(
        'The server keeps redirecting (last: $current). '
        'Check the baseUrl in ApiService.',
      );
    } finally {
      client.close();
    }
  }

  static Future<Map<String, dynamic>> _post(
    Map<String, String> body, {
    Duration timeout = const Duration(seconds: 20),
  }) async {
    try {
      final response = await _postFollowingRedirects(Uri.parse(baseUrl), {
        if (sessionToken.isNotEmpty) 'session_token': sessionToken,
        ...body,
        'app_token': appToken,
      }).timeout(timeout);

      if (response.statusCode != 200) {
        throw Exception(
          'Server returned HTTP ${response.statusCode} '
          '(${response.request?.url ?? baseUrl})',
        );
      }

      if (response.body.trimLeft().startsWith('<')) {
        // Ipakita ang simula ng isinagot ng server para malaman kung bakit
        final preview = response.body.trim().replaceAll(RegExp(r'\s+'), ' ');
        final shown = preview.length > 300
            ? preview.substring(0, 300)
            : preview;
        throw Exception(
          'The server returned a web page instead of data: $shown',
        );
      }

      final decoded = jsonDecode(response.body);

      if (decoded is! Map<String, dynamic>) {
        throw Exception('Invalid server response.');
      }

      return decoded;
    } catch (e) {
      debugPrint('API ERROR: $e');
      throw Exception('Unable to connect to server: $e');
    }
  }

  // ============================================================
  // LOGIN (nagbabalik ng session token)
  // ============================================================
  static Future<Map<String, dynamic>> login({
    required String email,
    required String password,
  }) async {
    return await _post({
      'action': 'login',
      'email': email,
      'password': password,
    });
  }

  // LOGOUT: burahin ang session sa server at sa phone
  static Future<void> logout() async {
    final token = sessionToken;
    sessionToken = '';
    if (token.isEmpty) return;
    try {
      await _post({'action': 'logout', 'session_token': token});
    } catch (e) {
      debugPrint('LOGOUT ERROR: $e');
    }
  }

  // PIN: nasa server, isa lang kada account at hindi na mapapalitan
  static Future<Map<String, dynamic>> setPin({
    required String email,
    required String password,
    required String pin,
  }) => _post({
    'action': 'set_pin',
    'email': email,
    'password': password,
    'pin': pin,
  });

  static Future<Map<String, dynamic>> verifyPin({
    required String email,
    required String password,
    required String pin,
  }) => _post({
    'action': 'verify_pin',
    'email': email,
    'password': password,
    'pin': pin,
  });

  // ============================================================
  // REGISTER / SIGN UP
  // ============================================================
  static Future<Map<String, dynamic>> register({
    required String name,
    required String email,
    required String password,
    String role = 'staff',
    String setupCode = '',
    String branchId = '',
    String branchPassword = '',
    String ownerCode = '',
  }) async {
    return await _post({
      'action': 'signup',
      'owner_code': ownerCode,
      'name': name,
      'email': email,
      'password': password,
      'role': role,
      'setup_code': setupCode,
      'branch_id': branchId,
      'branch_password': branchPassword,
    });
  }

  // ============================================================
  // BRANCHES
  // ============================================================
  // Naka-login: mga branch ng Owner niya. Sign up: kailangan ang ownerCode.
  static Future<List<Map<String, dynamic>>> listBranches({
    int userId = 0,
    String ownerCode = '',
    bool freeForAdmin = false, // Admin sign up: mga branch na wala pang Admin
  }) => _list(
    'list_branches',
    'branches',
    extra: {
      if (userId > 0) 'user_id': userId.toString(),
      if (ownerCode.isNotEmpty) 'owner_code': ownerCode,
      if (freeForAdmin) 'free_for_admin': '1',
    },
  );

  static Future<Map<String, dynamic>> addBranch({
    required int userId,
    required String name,
    required String password,
  }) async {
    return await _post({
      'action': 'add_branch',
      'user_id': userId.toString(),
      'name': name,
      'password': password,
    });
  }

  // Staff na wala pang branch: pumili ng branch gamit ang password nito
  static Future<Map<String, dynamic>> setBranch({
    required int userId,
    required String branchId,
    String branchPassword = '',
  }) async {
    return await _post({
      'action': 'set_branch',
      'user_id': userId.toString(),
      'branch_id': branchId,
      'branch_password': branchPassword,
    });
  }

  // Owner: palitan ang password ng isang branch
  static Future<Map<String, dynamic>> changeBranchPassword({
    required int userId,
    required String branchId,
    required String newPassword,
  }) async {
    return await _post({
      'action': 'change_branch_password',
      'user_id': userId.toString(),
      'branch_id': branchId,
      'new_password': newPassword,
    });
  }

  // ============================================================
  // ADD TRANSACTION
  // ============================================================
  static Future<Map<String, dynamic>> addTransaction({
    required int userId,
    required String customerName,
    required String dateTime,
    required double amount,
    required String referenceNo,
    required String status,
    required String receiptType,
    required String rawText,
    String senderNumber = '',
    String receiptImageBase64 = '',
  }) async {
    return await _post({
      'action': 'add_transaction',
      'sender_number': senderNumber,
      'receipt_image': receiptImageBase64,
      'user_id': userId.toString(),
      'customer_name': customerName,
      'date_time': dateTime,
      'amount': amount.toStringAsFixed(2),
      'reference_no': referenceNo,
      'status': status,
      'receipt_type': receiptType,
      'raw_text': rawText,
    }, timeout: const Duration(seconds: 90));
  }

  // ============================================================
  // AI PARSE RECEIPT (Gemini, sa server ang tawag)
  // Ibinabalik: isGcash, name, senderNumber, amount, reference
  // ============================================================
  static Future<Map<String, dynamic>> aiParseReceipt({
    required int userId,
    required String imageBase64,
  }) => _post({
    'action': 'ai_parse_receipt',
    'user_id': userId.toString(),
    'receipt_image': imageBase64,
  }, timeout: const Duration(seconds: 60));

  // Mga pagtatangkang mag-duplicate (Owner/Admin)
  static Future<List<Map<String, dynamic>>> getDuplicates(int userId) => _list(
    'get_duplicates',
    'duplicates',
    extra: {'user_id': userId.toString()},
  );

  // ============================================================
  // GET RECEIPT IMAGE (ang na-scan na larawan ng isang transaction)
  // ============================================================
  static Future<Map<String, dynamic>> getReceiptImage({
    required int userId,
    required String transactionId,
  }) async {
    return await _post({
      'action': 'get_receipt_image',
      'user_id': userId.toString(),
      'transaction_id': transactionId,
    }, timeout: const Duration(seconds: 60));
  }

  // ============================================================
  // GET TRANSACTIONS
  //   all = true  -> Owner/Admin: lahat (Admin: branch niya lang)
  //   all = false -> Staff: sarili lang nilang transaction
  // ============================================================
  static Future<List<Map<String, dynamic>>> getTransactions({
    required int userId,
    bool all = false,
  }) async {
    final data = await _post({
      'action': 'get_transactions',
      'user_id': userId.toString(),
      'scope': all ? 'all' : 'mine',
    });

    if (data['success'] != true) {
      throw Exception(data['message'] ?? 'Failed to load transactions.');
    }

    final transactions = data['transactions'];

    if (transactions is! List) {
      return [];
    }

    return transactions
        .whereType<Map>()
        .map((item) => Map<String, dynamic>.from(item))
        .toList();
  }

  // ============================================================
  // DELETE ONE TRANSACTION
  // ============================================================
  // Kasama ang reference number para iyon mismong resibo ang mabura
  static Future<Map<String, dynamic>> deleteTransaction({
    required int userId,
    required int transactionId,
    String referenceNo = '',
  }) async {
    return await _post({
      'action': 'delete_transaction',
      'user_id': userId.toString(),
      'id': transactionId.toString(),
      'reference_no': referenceNo,
    });
  }

  // ============================================================
  // DELETE ALL TRANSACTIONS
  // ============================================================
  static Future<Map<String, dynamic>> deleteAllTransactions({
    required int userId,
  }) async {
    return await _post({
      'action': 'delete_all_transactions',
      'user_id': userId.toString(),
    });
  }

  // ============================================================
  // LISTAHAN (users, attendance, logs)
  // ============================================================
  static Future<List<Map<String, dynamic>>> _list(
    String action,
    String key, {
    Map<String, String> extra = const {},
  }) async {
    final data = await _post({'action': action, ...extra});

    if (data['success'] != true) {
      throw Exception(data['message'] ?? 'Request failed.');
    }

    final items = data[key];
    if (items is! List) return [];

    return items
        .whereType<Map>()
        .map((item) => Map<String, dynamic>.from(item))
        .toList();
  }

  // Ang server ang magsasala: Owner = lahat, Admin = branch niya lang,
  // Staff = sarili lang.
  static Future<List<Map<String, dynamic>>> listUsers(int userId) =>
      _list('list_users', 'users', extra: {'user_id': userId.toString()});

  // Staff: humiling na lumipat ng branch (kailangan ng approval)
  static Future<Map<String, dynamic>> requestBranchChange({
    required int userId,
    required String branchId,
    required String branchPassword,
  }) async {
    return await _post({
      'action': 'request_branch_change',
      'user_id': userId.toString(),
      'branch_id': branchId,
      'branch_password': branchPassword,
    });
  }

  // Staff: ang pinakahuling request niya (status: pending/approved/rejected/cancelled)
  static Future<Map<String, dynamic>> getMyBranchRequest(int userId) async {
    return await _post({
      'action': 'get_my_branch_request',
      'user_id': userId.toString(),
    });
  }

  static Future<Map<String, dynamic>> cancelBranchRequest({
    required int userId,
    required int requestId,
  }) async {
    return await _post({
      'action': 'cancel_branch_request',
      'user_id': userId.toString(),
      'request_id': requestId.toString(),
    });
  }

  // Owner / Admin: mga pending request (Admin: papunta sa branch niya lang)
  static Future<List<Map<String, dynamic>>> listBranchRequests(int userId) =>
      _list(
        'list_branch_requests',
        'requests',
        extra: {'user_id': userId.toString()},
      );

  // Owner o Admin ng pupuntahang branch: approve o reject
  static Future<Map<String, dynamic>> decideBranchRequest({
    required int userId,
    required int requestId,
    required bool approve,
  }) async {
    return await _post({
      'action': 'decide_branch_request',
      'user_id': userId.toString(),
      'request_id': requestId.toString(),
      'decision': approve ? 'approve' : 'reject',
    });
  }

  // Owner lang: ilagay / ilipat ang Admin o Staff sa isang branch
  static Future<Map<String, dynamic>> assignBranch({
    required int userId,
    required int targetId,
    required String branchId,
  }) async {
    return await _post({
      'action': 'assign_branch',
      'user_id': userId.toString(),
      'target_id': targetId.toString(),
      'branch_id': branchId,
    });
  }

  // Ang server ang magsasala: Owner = lahat, Admin = branch niya lang,
  // Staff = sarili lang.
  static Future<List<Map<String, dynamic>>> getAttendance(int userId) => _list(
    'get_attendance',
    'attendance',
    extra: {'user_id': userId.toString()},
  );

  static Future<List<Map<String, dynamic>>> getLogs(int userId) =>
      _list('get_logs', 'logs', extra: {'user_id': userId.toString()});

  static Future<Map<String, dynamic>> saveAttendance({
    required int userId,
    required String email,
    required String date,
    required String status,
    required String clockIn,
    required String clockOut,
    required int lateMinutes,
    required int overtimeMinutes,
    required String remarks,
  }) async {
    return await _post({
      'action': 'save_attendance',
      'user_id': userId.toString(),
      'email': email,
      'date': date,
      'status': status,
      'clock_in': clockIn,
      'clock_out': clockOut,
      'late_minutes': lateMinutes.toString(),
      'overtime_minutes': overtimeMinutes.toString(),
      'remarks': remarks,
    });
  }

  static Future<Map<String, dynamic>> addLog({
    required String action,
    required String description,
    required String userName,
    int userId = 0,
  }) async {
    return await _post({
      'action': 'add_log',
      'user_id': userId.toString(),
      'log_action': action,
      'description': description,
      'user_name': userName,
    });
  }

  // ============================================================
  // FORGOT PASSWORD (code sa email)
  // ============================================================
  static Future<Map<String, dynamic>> forgotRequest(String email) async {
    return await _post({'action': 'forgot_request', 'email': email});
  }

  static Future<Map<String, dynamic>> forgotReset({
    required String email,
    required String code,
    required String newPassword,
  }) => _post({
    'action': 'forgot_reset',
    'email': email,
    'code': code,
    'new_password': newPassword,
  });

  // Owner/Admin: mga request na magpalit ng password
  static Future<List<Map<String, dynamic>>> listPasswordRequests(int userId) =>
      _list(
        'list_password_requests',
        'requests',
        extra: {'user_id': userId.toString()},
      );

  static Future<Map<String, dynamic>> dismissPasswordRequest({
    required int userId,
    required int requestId,
  }) => _post({
    'action': 'dismiss_password_request',
    'user_id': userId.toString(),
    'request_id': requestId.toString(),
  });

  // Owner/Admin: i-reset ang password ng staff (o admin, kung Owner)
  static Future<Map<String, dynamic>> resetStaffPassword({
    required int userId,
    required int targetId,
    required String newPassword,
  }) => _post({
    'action': 'reset_staff_password',
    'user_id': userId.toString(),
    'target_id': targetId.toString(),
    'new_password': newPassword,
  });

  // ============================================================
  // CHANGE PASSWORD
  // ============================================================
  static Future<Map<String, dynamic>> changePassword({
    required int userId,
    required String currentPassword,
    required String newPassword,
  }) async {
    return await _post({
      'action': 'change_password',
      'user_id': userId.toString(),
      'current_password': currentPassword,
      'new_password': newPassword,
    });
  }
}

// ============================================================
// FACE RECOGNITION
// Kumukuha ng "face embedding" gamit ang front camera, tapos ikinukumpara
// sa naka-register na mukha. Sa PHONE lang naka-save ang face data.
// ============================================================

// I-set sa false kung gusto mong i-bypass ang face check habang nagte-test
const bool kRequireFace = false;

// PIN pagkatapos mag-login. Huwag i-false: kailangan ng server na
// ma-verify ang PIN bago gumana ang ibang feature ng app.
const bool kRequirePin = true;

// Gaano kahigpit ang pagtutugma (0.0 - 1.0). Mas mataas = mas mahigpit.
const double kFaceMatchThreshold = 0.6;

// Ipakita ang score sa mensahe habang nagte-tune. I-set sa false pagkatapos.
const bool kShowFaceScore = true;

class FaceCapture {
  final List<double>? embedding;
  final String? error;

  FaceCapture.ok(List<double> e) : embedding = e, error = null;
  FaceCapture.fail(String m) : embedding = null, error = m;
}

class FaceService {
  static fd.FaceDetector? _detector;

  static Future<fd.FaceDetector> _getDetector() async {
    _detector ??= await fd.FaceDetector.create();
    return _detector!;
  }

  // Bubuksan ang camera screen at ibabalik ang face embedding
  static Future<FaceCapture> capture(BuildContext context, String title) async {
    final result = await Navigator.of(context).push<FaceCapture>(
      MaterialPageRoute(builder: (_) => FaceCameraPage(title: title)),
    );
    return result ?? FaceCapture.fail('Face scan was cancelled.');
  }

  // Hanapin ang mukha sa litrato at gawing embedding
  static Future<FaceCapture> process(String path) async {
    try {
      final detector = await _getDetector();
      final bytes = await File(path).readAsBytes();
      final faces = await detector.detectFacesFromBytes(bytes);

      if (faces.isEmpty) {
        return FaceCapture.fail(
          'No face detected. Face the camera straight, in good light, and try again.',
        );
      }
      if (faces.length > 1) {
        return FaceCapture.fail(
          'More than one face detected. Only one person should be in front of the camera.',
        );
      }

      final vector = await detector.getFaceEmbedding(faces.first, bytes);
      return FaceCapture.ok(vector.toList());
    } catch (e) {
      debugPrint('FACE ERROR: $e');
      return FaceCapture.fail('Face scan failed: $e');
    } finally {
      // Burahin ang litrato; embedding lang ang itatago
      try {
        await File(path).delete();
      } catch (_) {}
    }
  }

  // Cosine similarity ng dalawang mukha (mas mataas = mas magkahawig)
  static double similarity(List<double> a, List<double> b) {
    return fd.FaceDetector.compareFaces(
      Float32List.fromList(a),
      Float32List.fromList(b),
    );
  }
}

class FaceCameraPage extends StatefulWidget {
  final String title;
  const FaceCameraPage({super.key, required this.title});

  @override
  State<FaceCameraPage> createState() => _FaceCameraPageState();
}

class _FaceCameraPageState extends State<FaceCameraPage> {
  static const int maxAttempts = 8;

  cm.CameraController? controller;
  String? error; // malalang error (walang camera, atbp.)
  String? message; // mensahe habang naghahanap (walang nakitang mukha, atbp.)
  bool busy = false;
  bool done = false;
  bool gaveUp = false;
  int attempts = 0;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    try {
      final cameras = await cm.availableCameras();
      if (cameras.isEmpty) {
        if (!mounted) return;
        setState(() => error = 'No camera found on this phone.');
        return;
      }

      final front = cameras.firstWhere(
        (c) => c.lensDirection == cm.CameraLensDirection.front,
        orElse: () => cameras.first,
      );

      final c = cm.CameraController(
        front,
        cm.ResolutionPreset.high,
        enableAudio: false,
      );
      await c.initialize();

      if (!mounted) {
        await c.dispose();
        return;
      }
      setState(() => controller = c);

      // Awtomatikong magsisimula ang scan, walang pipindutin
      _autoScan();
    } catch (e) {
      if (!mounted) return;
      setState(() => error = 'Unable to open the camera: $e');
    }
  }

  @override
  void dispose() {
    done = true;
    controller?.dispose();
    super.dispose();
  }

  // Awtomatikong kukuha ng litrato at susuriin ang mukha.
  // Uulit hanggang may makitang mukha (hanggang maxAttempts).
  Future<void> _autoScan() async {
    setState(() {
      gaveUp = false;
      attempts = 0;
      message = null;
    });

    // Bigyan ng sandali ang user para ayusin ang posisyon
    await Future.delayed(const Duration(milliseconds: 1800));

    while (mounted && !done && attempts < maxAttempts) {
      final c = controller;
      if (c == null) return;

      setState(() {
        busy = true;
        attempts++;
      });

      try {
        final file = await c.takePicture();
        final result = await FaceService.process(file.path);

        if (!mounted || done) return;

        if (result.embedding != null) {
          done = true;
          Navigator.pop(context, result);
          return;
        }

        setState(() {
          busy = false;
          message = result.error;
        });
      } catch (e) {
        if (!mounted) return;
        setState(() {
          busy = false;
          message = 'Scan failed: $e';
        });
      }

      await Future.delayed(const Duration(milliseconds: 1500));
    }

    if (mounted && !done) {
      setState(() {
        busy = false;
        gaveUp = true;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = controller;

    Widget body;
    if (error != null) {
      body = Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            error!,
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.white),
          ),
        ),
      );
    } else if (c == null || !c.value.isInitialized) {
      body = const Center(child: CircularProgressIndicator());
    } else {
      body = Column(
        children: [
          Expanded(
            child: Stack(
              alignment: Alignment.center,
              children: [
                Center(child: cm.CameraPreview(c)),
                IgnorePointer(
                  child: Container(
                    width: 240,
                    height: 320,
                    decoration: BoxDecoration(
                      border: Border.all(
                        color: busy ? Colors.lightGreenAccent : Colors.white,
                        width: 3,
                      ),
                      borderRadius: const BorderRadius.all(
                        Radius.elliptical(240, 320),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 4),
            child: Text(
              gaveUp
                  ? 'Could not detect your face. Make sure your face is inside the oval and well lit, then tap Try Again.'
                  : (message ??
                        'Place your face inside the oval and look straight at the camera. The scan starts automatically.'),
              textAlign: TextAlign.center,
              style: TextStyle(
                color: (gaveUp || message != null)
                    ? Colors.amberAccent
                    : Colors.white70,
              ),
            ),
          ),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: gaveUp
                  ? SizedBox(
                      width: double.infinity,
                      height: 52,
                      child: FilledButton.icon(
                        onPressed: _autoScan,
                        icon: const Icon(Icons.refresh),
                        label: const Text('Try Again'),
                      ),
                    )
                  : Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                        const SizedBox(width: 12),
                        Text(
                          busy ? 'Scanning your face...' : 'Get ready...',
                          style: const TextStyle(color: Colors.white),
                        ),
                      ],
                    ),
            ),
          ),
        ],
      );
    }

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(title: Text(widget.title)),
      body: body,
    );
  }
}

// ============================================================
// PIN DIALOG
// ============================================================
Future<String?> askPin(
  BuildContext context, {
  required String title,
  String? message,
  bool confirm = false,
}) {
  return showDialog<String>(
    context: context,
    barrierDismissible: false,
    builder: (_) => PinDialog(title: title, message: message, confirm: confirm),
  );
}

class PinDialog extends StatefulWidget {
  final String title;
  final String? message;
  final bool confirm;

  const PinDialog({
    super.key,
    required this.title,
    this.message,
    this.confirm = false,
  });

  @override
  State<PinDialog> createState() => _PinDialogState();
}

class _PinDialogState extends State<PinDialog> {
  final pin = TextEditingController();
  final again = TextEditingController();
  String? error;

  @override
  void dispose() {
    pin.dispose();
    again.dispose();
    super.dispose();
  }

  void submit() {
    final p = pin.text;
    if (p.length < 4) {
      setState(() => error = 'PIN must be at least 4 digits.');
      return;
    }
    if (widget.confirm && p != again.text) {
      setState(() => error = 'PINs do not match.');
      return;
    }
    Navigator.pop(context, p);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (widget.message != null) ...[
              Text(
                widget.message!,
                style: const TextStyle(color: Color(0xFF58728F), fontSize: 13),
              ),
              const SizedBox(height: 12),
            ],
            TextField(
              controller: pin,
              autofocus: true,
              obscureText: true,
              keyboardType: TextInputType.number,
              maxLength: 6,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              decoration: const InputDecoration(
                labelText: 'PIN',
                counterText: '',
              ),
              onSubmitted: (_) {
                if (!widget.confirm) submit();
              },
            ),
            if (widget.confirm) ...[
              const SizedBox(height: 10),
              TextField(
                controller: again,
                obscureText: true,
                keyboardType: TextInputType.number,
                maxLength: 6,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                decoration: const InputDecoration(
                  labelText: 'Confirm PIN',
                  counterText: '',
                ),
                onSubmitted: (_) => submit(),
              ),
            ],
            if (error != null) ...[
              const SizedBox(height: 10),
              Text(
                error!,
                style: const TextStyle(color: Colors.red, fontSize: 12),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(onPressed: submit, child: const Text('OK')),
      ],
    );
  }
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final store = ReceiScanStore();
  await store.init();
  runApp(ReceiScanApp(store: store));
}

class ReceiScanApp extends StatefulWidget {
  final ReceiScanStore store;
  const ReceiScanApp({super.key, required this.store});

  @override
  State<ReceiScanApp> createState() => _ReceiScanAppState();
}

class _ReceiScanAppState extends State<ReceiScanApp> {
  UserAccount? user;
  bool splashDone = false;
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'ReceiScan',
      theme: ThemeData(
        useMaterial3: true,
        fontFamily: 'Arial',
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF0869EE)),
        scaffoldBackgroundColor: const Color(0xFFF4F9FF),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: const Color(0xFFFBFDFF),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide: const BorderSide(color: Color(0xFFCFE3F8)),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide: const BorderSide(color: Color(0xFFCFE3F8)),
          ),
        ),
      ),
      home: !splashDone
          ? SplashPage(onDone: () => setState(() => splashDone = true))
          : user == null
          ? LoginPage(
              store: widget.store,
              onLogin: (u) => setState(() => user = u),
            )
          : HomeShell(
              key: ValueKey(user!.id),
              store: widget.store,
              user: user!,
              onLogout: () {
                // Burahin ang session sa server (hindi na hinihintay)
                ApiService.logout();
                widget.store.clearSession();
                setState(() => user = null);
              },
            ),
    );
  }
}

// -----------------------------------------------------------------------------
// MODELS
// -----------------------------------------------------------------------------

String formatRole(String role) {
  final r = role.trim().toLowerCase();
  if (r == 'owner') return 'OWNER';
  if (r == 'admin') return 'ADMIN';
  if (r == 'staff') return 'STAFF';
  return role.toUpperCase();
}

class UserAccount {
  String id;
  String name;
  String email;
  String password;
  String role;
  String createdAt;
  String branch;
  String ownerCode; // unique Owner ID (para sa Owner lang)
  bool hasPin; // may PIN na ba sa server

  String get displayRole => formatRole(role);

  UserAccount({
    this.id = '',
    required this.name,
    required this.email,
    required this.password,
    required this.role,
    this.createdAt = '',
    this.branch = '',
    this.ownerCode = '',
    this.hasPin = false,
  });

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'email': email,
    'password': password,
    'role': role,
    'createdAt': createdAt,
    'ownerCode': ownerCode,
    'hasPin': hasPin,
  };

  factory UserAccount.fromJson(Map<String, dynamic> j) => UserAccount(
    id: j['id'] ?? '',
    name: j['name'] ?? '',
    email: j['email'] ?? '',
    password: j['password'] ?? '',
    role: j['role'] ?? 'staff',
    createdAt: j['createdAt'] ?? '',
    ownerCode: j['ownerCode'] ?? '',
    hasPin: j['hasPin'] == true,
  );
}

// Pang-dagdag sa id ng record na walang id (hal. lumang data sa phone)
int _nextLocalId = 0;

class TransactionRecord {
  String id;
  String accountName;
  String reference;
  double amount;
  String date;
  String time;
  String status;
  String receiptType;
  String rawText;
  String scannedBy; // pangalan ng nag-scan (galing sa server)
  String senderNumber; // number ng sender (galing sa receipt)
  String branch; // branch kung saan na-scan
  bool hasImage; // may na-save bang larawan ng na-scan na receipt
  String createdAt; // kung kailan na-save sa server (YYYY-MM-DD HH:MM:SS)

  // Araw ng PAG-SCAN (kung kailan na-save), hindi ang petsa sa resibo.
  String get scanDate {
    final c = createdAt.trim();
    if (c.length >= 10 && RegExp(r'^\d{4}-\d{2}-\d{2}').hasMatch(c)) {
      return c.substring(0, 10);
    }
    return date;
  }

  TransactionRecord({
    required this.id,
    required this.accountName,
    required this.reference,
    required this.amount,
    required this.date,
    required this.time,
    this.status = 'confirmed',
    this.receiptType = 'GCash',
    this.rawText = '',
    this.scannedBy = '',
    this.senderNumber = '',
    this.branch = '',
    this.hasImage = false,
    this.createdAt = '',
  });

  Map<String, dynamic> toJson() => {
    'id': id,
    'accountName': accountName,
    'senderNumber': senderNumber,
    'reference': reference,
    'amount': amount,
    'date': date,
    'time': time,
    'status': status,
    'receiptType': receiptType,
    'rawText': rawText,
  };

  factory TransactionRecord.fromJson(Map<String, dynamic> j) =>
      TransactionRecord(
        // Laging unique ang id (para isa-isa ang pagpili sa Transactions)
        id: (j['id']?.toString() ?? '').trim().isNotEmpty
            ? j['id'].toString()
            : 'local-${j['reference'] ?? ''}-${_nextLocalId++}',
        accountName: j['accountName'] ?? '',
        reference: j['reference'] ?? '',
        amount: (j['amount'] as num?)?.toDouble() ?? 0,
        date: j['date'] ?? '',
        time: j['time'] ?? '',
        status: j['status'] ?? 'confirmed',
        receiptType: j['receiptType'] ?? 'GCash',
        rawText: j['rawText'] ?? '',
        scannedBy: j['scannedBy']?.toString() ?? '',
        senderNumber: j['senderNumber']?.toString() ?? '',
        branch: j['branch']?.toString() ?? '',
        hasImage: j['hasImage'] == true || j['hasImage'] == 1,
        createdAt: j['createdAt']?.toString() ?? '',
      );
}

class AttendanceRecord {
  String email;
  String date;
  String status;
  String clockIn;
  String clockOut;
  int lateMinutes;
  int overtimeMinutes;
  String remarks;

  AttendanceRecord({
    required this.email,
    required this.date,
    required this.status,
    this.clockIn = '',
    this.clockOut = '',
    this.lateMinutes = 0,
    this.overtimeMinutes = 0,
    this.remarks = '',
  });

  Map<String, dynamic> toJson() => {
    'email': email,
    'date': date,
    'status': status,
    'clockIn': clockIn,
    'clockOut': clockOut,
    'lateMinutes': lateMinutes,
    'overtimeMinutes': overtimeMinutes,
    'remarks': remarks,
  };

  factory AttendanceRecord.fromJson(Map<String, dynamic> j) => AttendanceRecord(
    email: j['email'] ?? '',
    date: j['date'] ?? '',
    status: j['status'] ?? 'Absent',
    clockIn: j['clockIn'] ?? '',
    clockOut: j['clockOut'] ?? '',
    lateMinutes: j['lateMinutes'] ?? 0,
    overtimeMinutes: j['overtimeMinutes'] ?? 0,
    remarks: j['remarks'] ?? '',
  );
}

// -----------------------------------------------------------------------------
// LOCAL STORAGE
// -----------------------------------------------------------------------------

class ReceiScanStore {
  static const usersKey = 'receiscan_users';
  static const txKey = 'receiscan_transactions';
  static const logsKey = 'receiscan_logs';
  static const attendanceKey = 'receiscan_attendance';

  // Isang-gamit na filter na itinatakda ng Dashboard bago buksan ang Transactions
  String pendingTxStatus = 'All';
  String pendingTxPeriod = 'All';

  static const facesKey = 'receiscan_faces';

  late SharedPreferences prefs;

  // Mga naka-register na mukha (email -> face embedding), sa phone lang
  Map<String, List<double>> _faces() {
    final raw = prefs.getString(facesKey) ?? '{}';
    final decoded = jsonDecode(raw) as Map<String, dynamic>;
    return decoded.map(
      (k, v) =>
          MapEntry(k, (v as List).map((e) => (e as num).toDouble()).toList()),
    );
  }

  List<double>? getFace(String email) => _faces()[email.trim().toLowerCase()];

  bool hasFace(String email) => getFace(email) != null;

  Future<void> saveFace(String email, List<double> embedding) async {
    final all = _faces();
    all[email.trim().toLowerCase()] = embedding;
    await prefs.setString(facesKey, jsonEncode(all));
  }

  // ---- Profile picture (naka-save sa phone, kada email) ----
  String _avatarKey(String email) =>
      'receiscan_avatar_${email.trim().toLowerCase()}';

  Uint8List? getAvatar(String email) {
    final raw = prefs.getString(_avatarKey(email));
    if (raw == null || raw.isEmpty) return null;
    try {
      return base64Decode(raw);
    } catch (_) {
      return null;
    }
  }

  Future<void> saveAvatar(String email, Uint8List bytes) async {
    await prefs.setString(_avatarKey(email), base64Encode(bytes));
  }

  Future<void> removeAvatar(String email) async {
    await prefs.remove(_avatarKey(email));
  }

  Future<void> init() async {
    prefs = await SharedPreferences.getInstance();
  }

  // ---------------------------------------------------------------
  // DATA MULA SA SERVER (MySQL)
  // Naka-cache sa memory para mabilis ang pagbasa ng mga page.
  // ---------------------------------------------------------------
  List<UserAccount> _users = [];
  List<TransactionRecord> _txs = [];
  List<Map<String, dynamic>> _logs = [];
  List<AttendanceRecord> _attendance = [];

  // ID ng naka-login na user
  int currentUserId = 0;

  // Role ng naka-login na user.
  String currentRole = '';

  // Session guard: binabago sa bawat login/logout para ibasura ang
  // mga async response mula sa lumang session.
  int _sessionId = 0;

  // Huling error text mula sa server para sa transactions
  String? lastTransactionsError;

  void setSession(int userId, String role) {
    _sessionId++;
    currentUserId = userId;
    currentRole = role;
    lastTransactionsError = null;
    _txs = [];
    _users = [];
    _logs = [];
    _attendance = [];
    _branchRequests = [];
    _pwRequests = [];
  }

  bool get isOwner => currentRole == 'owner';

  bool get isAdmin => currentRole == 'admin';

  // Owner: receipts ng lahat ng branch. Admin: branch niya lang.
  bool get canSeeReceipts => currentRole == 'owner' || currentRole == 'admin';

  // True kung hindi naabot ang server sa huling refresh
  bool offline = false;

  List<UserAccount> getUsers() => List<UserAccount>.from(_users);

  List<TransactionRecord> getTransactions() =>
      List<TransactionRecord>.from(_txs);

  List<Map<String, dynamic>> getLogs() =>
      List<Map<String, dynamic>>.from(_logs);

  List<AttendanceRecord> getAttendance() =>
      List<AttendanceRecord>.from(_attendance);

  String _display12h(String value) {
    final d = parseTime(value);
    if (d == null) return value;
    final h = d.hour == 0 ? 12 : (d.hour > 12 ? d.hour - 12 : d.hour);
    final ap = d.hour >= 12 ? 'PM' : 'AM';
    return '${h.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')} $ap';
  }

  Future<void> refreshUsers() async {
    final captureSession = _sessionId;
    final captureUid = currentUserId;
    if (captureUid <= 0) return;
    final rows = await ApiService.listUsers(captureUid);
    if (captureSession != _sessionId || captureUid != currentUserId) return;
    _users = rows
        .map(
          (j) => UserAccount(
            id: j['id']?.toString() ?? '',
            name: j['name']?.toString() ?? '',
            email: j['email']?.toString() ?? '',
            password: '',
            role: j['role']?.toString() ?? 'staff',
            createdAt: j['createdAt']?.toString() ?? '',
            branch: j['branch']?.toString() ?? '',
          ),
        )
        // Staff at Admin lang (hindi kasama ang Owner)
        .where((u) => u.role.toLowerCase() != 'owner')
        .toList();
  }

  // Owner/Admin: lahat ng makikita nila. Staff: sarili lang.
  Future<void> refreshTransactions() async {
    final captureSession = _sessionId;
    final captureUid = currentUserId;
    final captureRole = currentRole;

    if (captureUid <= 0) {
      if (captureSession == _sessionId) {
        _txs = [];
      }
      return;
    }

    try {
      final rows = await ApiService.getTransactions(
        userId: captureUid,
        all: canSeeReceipts,
      );

      // Session guard: ibasura kung nag-logout o nagpalit ng account habang naghihintay
      if (captureSession != _sessionId || captureUid != currentUserId) return;

      _txs = rows.map((j) {
        final t = TransactionRecord.fromJson(j);
        t.time = _display12h(t.time);
        return t;
      }).toList();
      lastTransactionsError = null;

      if (kDebugLoad) {
        final sum = _txs.fold<double>(0, (s, t) => s + t.amount);
        debugPrint(
          '[ReceiScanLoad] userId=$captureUid, role=$captureRole, count=${_txs.length}, total=$sum',
        );
      }
    } catch (e) {
      if (captureSession == _sessionId && captureUid == currentUserId) {
        lastTransactionsError = e.toString().replaceFirst('Exception: ', '');
      }
      rethrow;
    }
  }

  Future<void> refreshAttendance() async {
    final captureSession = _sessionId;
    final captureUid = currentUserId;
    if (captureUid <= 0) return;
    final rows = await ApiService.getAttendance(captureUid);
    if (captureSession != _sessionId || captureUid != currentUserId) return;
    _attendance = rows.map(AttendanceRecord.fromJson).toList();
  }

  Future<void> refreshLogs() async {
    final captureSession = _sessionId;
    final captureUid = currentUserId;
    if (!canSeeReceipts || captureUid <= 0) {
      if (captureSession == _sessionId) {
        _logs = [];
      }
      return;
    }
    final rows = await ApiService.getLogs(captureUid);
    if (captureSession != _sessionId || captureUid != currentUserId) return;
    // Lahat ng logs na ibinigay ng server (wala nang nakatagong lumang logs)
    _logs = rows;
  }

  // Mga pending na request ng staff na lumipat ng branch
  // (Owner: lahat. Admin: papunta sa branch niya lang.)
  List<Map<String, dynamic>> _branchRequests = [];

  List<Map<String, dynamic>> getBranchRequests() =>
      List<Map<String, dynamic>>.from(_branchRequests);

  Future<void> refreshBranchRequests() async {
    final captureSession = _sessionId;
    final captureUid = currentUserId;
    if (!canSeeReceipts || captureUid <= 0) {
      if (captureSession == _sessionId) {
        _branchRequests = [];
      }
      return;
    }
    final rows = await ApiService.listBranchRequests(captureUid);
    if (captureSession != _sessionId || captureUid != currentUserId) return;
    _branchRequests = rows;
  }

  // Mga request na magpalit ng password (Owner/Admin)
  List<Map<String, dynamic>> _pwRequests = [];

  List<Map<String, dynamic>> getPasswordRequests() =>
      List<Map<String, dynamic>>.from(_pwRequests);

  Future<void> refreshPasswordRequests() async {
    final captureSession = _sessionId;
    final captureUid = currentUserId;
    if (!canSeeReceipts || captureUid <= 0) {
      if (captureSession == _sessionId) {
        _pwRequests = [];
      }
      return;
    }
    final rows = await ApiService.listPasswordRequests(captureUid);
    if (captureSession != _sessionId || captureUid != currentUserId) return;
    _pwRequests = rows;
  }

  // Kunin lahat mula sa server; ibabalik kung nagtagumpay
  Future<bool> refreshAll() async {
    final captureSession = _sessionId;
    final captureUid = currentUserId;

    if (captureUid <= 0) return false;

    var allOk = true;
    Future<void> safe(Future<void> Function() job, String label) async {
      try {
        if (captureSession != _sessionId || captureUid != currentUserId) return;
        await job();
      } catch (e) {
        allOk = false;
        debugPrint('REFRESH ERROR ($label): $e');
      }
    }

    // Ang Transactions ang una at mag-isa. May ilang ulit na subok kapag pumalya.
    String? txError;
    for (var attempt = 0; attempt < 3; attempt++) {
      if (captureSession != _sessionId || captureUid != currentUserId) {
        return false;
      }
      try {
        await refreshTransactions();
        txError = null;
        break;
      } catch (e) {
        txError = e.toString().replaceFirst('Exception: ', '');
        debugPrint('REFRESH ERROR (transactions, try ${attempt + 1}): $e');
        if (attempt == 2) {
          allOk = false;
        } else {
          await Future.delayed(const Duration(milliseconds: 700));
        }
      }
    }

    if (captureSession != _sessionId || captureUid != currentUserId) {
      return false;
    }

    if (txError != null) {
      lastTransactionsError = txError;
    }

    await Future.wait([
      safe(refreshUsers, 'users'),
      safe(refreshAttendance, 'attendance'),
      safe(refreshLogs, 'logs'),
      safe(refreshBranchRequests, 'branch requests'),
      safe(refreshPasswordRequests, 'password requests'),
    ]);

    if (captureSession != _sessionId || captureUid != currentUserId) {
      return false;
    }

    offline = !allOk;
    return allOk;
  }

  // Ligtas na bersyon (hindi nagta-throw)
  Future<void> syncTransactions() async {
    final captureSession = _sessionId;
    final captureUid = currentUserId;
    if (captureUid <= 0) return;
    try {
      await refreshTransactions();
    } catch (e) {
      if (captureSession == _sessionId && captureUid == currentUserId) {
        lastTransactionsError = e.toString().replaceFirst('Exception: ', '');
      }
      debugPrint('SYNC TRANSACTIONS ERROR: $e');
    }
  }

  Future<void> syncAttendance() async {
    final captureSession = _sessionId;
    final captureUid = currentUserId;
    if (captureUid <= 0) return;
    try {
      await refreshAttendance();
    } catch (e) {
      if (captureSession == _sessionId && captureUid == currentUserId) {
        debugPrint('SYNC ATTENDANCE ERROR: $e');
      }
    }
  }

  Future<void> addLog(String action, String description, String user) async {
    _logs.insert(0, {
      'action': action,
      'description': description,
      'type': action.toLowerCase(),
      'user': user,
      'role': currentRole,
      'branch': '',
      'created': DateTime.now().toString(),
    });

    try {
      await ApiService.addLog(
        action: action,
        description: description,
        userName: user,
        userId: currentUserId,
      );
    } catch (e) {
      debugPrint('LOG ERROR: $e');
    }
  }

  // Linisin ang cache pag nag-logout
  void clearSession() {
    _sessionId++;
    currentUserId = 0;
    currentRole = '';
    _users = [];
    _txs = [];
    _logs = [];
    _attendance = [];
    _branchRequests = [];
    _pwRequests = [];
    lastTransactionsError = null;
  }

  // ---------------------------------------------------------------
  // LUMANG DATA NA NAKA-SAVE SA PHONE (bago lumipat sa database)
  // ---------------------------------------------------------------
  List<TransactionRecord> localOldTransactions() {
    final raw = prefs.getString(txKey);
    if (raw == null) return [];
    try {
      return (jsonDecode(raw) as List)
          .map((e) => TransactionRecord.fromJson(Map<String, dynamic>.from(e)))
          .where((t) => !const {'1', '2', '3', '4'}.contains(t.id))
          .toList();
    } catch (_) {
      return [];
    }
  }

  List<AttendanceRecord> localOldAttendance() {
    final raw = prefs.getString(attendanceKey);
    if (raw == null) return [];
    try {
      return (jsonDecode(raw) as List)
          .map((e) => AttendanceRecord.fromJson(Map<String, dynamic>.from(e)))
          .toList();
    } catch (_) {
      return [];
    }
  }

  Future<void> clearOldLocalData() async {
    await prefs.remove(txKey);
    await prefs.remove(attendanceKey);
  }
}

// -----------------------------------------------------------------------------
// LOGIN
// -----------------------------------------------------------------------------

class LoginPage extends StatefulWidget {
  final ReceiScanStore store;
  final ValueChanged<UserAccount> onLogin;

  const LoginPage({super.key, required this.store, required this.onLogin});

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final email = TextEditingController();
  final password = TextEditingController();
  bool obscure = true;
  bool loading = false;

  @override
  void dispose() {
    email.dispose();
    password.dispose();
    super.dispose();
  }

  Future<void> login() async {
    final e = email.text.trim().toLowerCase();
    final p = password.text;

    if (e.isEmpty || p.isEmpty) {
      snack(context, 'Please enter email and password.');
      return;
    }

    setState(() => loading = true);

    try {
      final result = await ApiService.login(email: e, password: p);

      if (!mounted) return;

      if (result['success'] != true) {
        setState(() => loading = false);

        snack(context, result['message'] ?? 'Invalid email or password.');

        return;
      }

      // Paalala kung luma pa ang api.php sa server
      if ((int.tryParse(result['apiVersion']?.toString() ?? '') ?? 0) < 7) {
        setState(() => loading = false);
        await showDialog<void>(
          context: context,
          builder: (dialogContext) => AlertDialog(
            title: const Text('Server is outdated'),
            content: const Text(
              'The api.php on your server is not the latest version. '
              'Upload the newest api.php and config.php, then log in again.',
            ),
            actions: [
              FilledButton(
                onPressed: () => Navigator.pop(dialogContext),
                child: const Text('OK'),
              ),
            ],
          ),
        );
        return;
      }

      // Itago ang session token para sa lahat ng susunod na tawag
      ApiService.sessionToken = result['token']?.toString() ?? '';

      final userData = result['user'];

      if (userData == null || ApiService.sessionToken.isEmpty) {
        setState(() => loading = false);

        snack(
          context,
          'Login succeeded but the server did not return a session.',
        );

        return;
      }

      final found = UserAccount(
        id: userData['id'].toString(),
        name: userData['name']?.toString() ?? '',
        email: userData['email']?.toString() ?? e,
        password: p,
        role: userData['role']?.toString() ?? 'staff',
        branch: userData['branch']?.toString() ?? '',
        ownerCode: userData['ownerCode']?.toString() ?? '',
        hasPin: userData['hasPin'] == true,
        createdAt:
            userData['createdAt']?.toString() ??
            DateTime.now().toIso8601String(),
      );

      setState(() => loading = false);

      // Staff na wala pang branch: pumili muna ng branch
      if (found.role.trim().toLowerCase() == 'staff' &&
          (userData['branch']?.toString() ?? '').isEmpty) {
        final picked = await showDialog<String>(
          context: context,
          barrierDismissible: false,
          builder: (_) => BranchPickDialog(userId: int.tryParse(found.id) ?? 0),
        );
        if (!mounted) return;
        if (picked == null) {
          await ApiService.logout();
          if (!mounted) return;
          snack(context, 'Please choose your branch to continue.');
          return;
        }
        found.branch = picked;
      }

      // Face recognition check bago makapasok sa account
      if (kRequireFace) {
        final faceOk = await _faceCheck(found.email);
        if (!mounted) return;
        if (!faceOk) {
          await ApiService.logout();
          return;
        }
      }

      // PIN check pagkatapos ng face recognition
      if (kRequirePin) {
        final pinOk = await _pinCheck(found);
        if (!mounted) return;
        if (!pinOk) {
          await ApiService.logout();
          return;
        }
      }

      widget.store.setSession(
        int.tryParse(found.id) ?? 0,
        found.role.trim().toLowerCase(),
      );

      if (kDebugLoad) {
        debugPrint(
          '[ReceiScanLoad] Login start userId=${widget.store.currentUserId}, role=${widget.store.currentRole}',
        );
      }

      // Kunin na ang mga receipt bago buksan ang Dashboard para hindi 0 ang Total
      await widget.store.refreshAll();
      if (!mounted) return;

      if (kDebugLoad) {
        final txs = widget.store.getTransactions();
        final sum = txs.fold<double>(0, (s, t) => s + t.amount);
        debugPrint(
          '[ReceiScanLoad] Login end userId=${widget.store.currentUserId}, count=${txs.length}, total=$sum',
        );
      }

      await widget.store.addLog(
        'Login',
        '${found.name} logged in.',
        found.name,
      );

      if (!mounted) return;

      widget.onLogin(found);
    } catch (error) {
      if (!mounted) return;

      setState(() => loading = false);

      snack(context, errorText(error));
    }
  }

  // Face check: i-register muna kung wala pa, o i-verify kung meron na
  Future<bool> _faceCheck(String accountEmail) async {
    final saved = widget.store.getFace(accountEmail);

    // Wala pang naka-register na mukha sa phone na ito
    if (saved == null) {
      final cap = await FaceService.capture(context, 'Register Your Face');
      if (!mounted) return false;
      if (cap.embedding == null) {
        snack(context, cap.error ?? 'Face scan failed.');
        return false;
      }
      await widget.store.saveFace(accountEmail, cap.embedding!);
      if (!mounted) return false;
      snack(
        context,
        'Face registered. It will be used the next time you log in.',
      );
      return true;
    }

    final cap = await FaceService.capture(context, 'Verify Your Face');
    if (!mounted) return false;
    if (cap.embedding == null) {
      snack(context, cap.error ?? 'Face scan failed.');
      return false;
    }

    final score = FaceService.similarity(saved, cap.embedding!);
    final matched = score >= kFaceMatchThreshold;
    final scoreText = kShowFaceScore
        ? ' (score ${score.toStringAsFixed(2)})'
        : '';

    snack(
      context,
      matched
          ? 'Face verified$scoreText.'
          : 'Face does not match$scoreText. Please try again.',
    );
    return matched;
  }

  // PIN check (nasa server): gumawa muna kung wala pa, o i-verify kung meron na.
  // Pareho ang PIN ng account sa kahit anong phone at hindi na mapapalitan.
  Future<bool> _pinCheck(UserAccount acc) async {
    try {
      if (!acc.hasPin) {
        final newPin = await askPin(
          context,
          title: 'Create Your PIN',
          message:
              'Choose a 4 to 6 digit PIN. It will be used on every phone and '
              'cannot be changed later.',
          confirm: true,
        );
        if (!mounted) return false;
        if (newPin == null) {
          snack(context, 'A PIN is required to continue.');
          return false;
        }
        final res = await ApiService.setPin(
          email: acc.email,
          password: acc.password,
          pin: newPin,
        );
        if (!mounted) return false;
        if (res['success'] != true) {
          snack(context, res['message']?.toString() ?? 'Unable to save PIN.');
          return false;
        }
        snack(context, 'PIN created.');
        return true;
      }

      for (var attempt = 1; attempt <= 5; attempt++) {
        final entered = await askPin(
          context,
          title: 'Enter Your PIN',
          message: attempt == 1 ? null : 'Wrong PIN. Attempt $attempt of 5.',
        );
        if (!mounted) return false;
        if (entered == null) {
          snack(context, 'A PIN is required to continue.');
          return false;
        }
        final res = await ApiService.verifyPin(
          email: acc.email,
          password: acc.password,
          pin: entered,
        );
        if (!mounted) return false;
        if (res['success'] == true) return true;
        if (res['locked'] == true) {
          snack(context, res['message']?.toString() ?? 'PIN locked.');
          return false;
        }
      }

      snack(context, 'Too many wrong PIN attempts. Please log in again.');
      return false;
    } catch (e) {
      if (!mounted) return false;
      snack(context, errorText(e));
      return false;
    }
  }

  void register() {
    showDialog(
      context: context,
      builder: (_) => RegisterDialog(store: widget.store),
    );
  }

  // Forgot Password: code sa email
  void forgotPassword() {
    showDialog(
      context: context,
      builder: (_) => ForgotPasswordDialog(initialEmail: email.text.trim()),
    );
  }

  // Owner: bagong grupo (walang Owner ID na kailangan)
  Future<void> registerPrivileged() async {
    if (!mounted) return;
    showDialog(
      context: context,
      builder: (_) => RegisterDialog(store: widget.store, role: 'owner'),
    );
  }

  // Admin: kailangan ang Owner ID at isang branch na wala pang Admin
  Future<void> registerAdmin() async {
    if (!mounted) return;
    showDialog(
      context: context,
      builder: (_) => RegisterDialog(store: widget.store, role: 'admin'),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            colors: [Color(0xFF12B9E7), Color(0xFF0875EE), Color(0xFF052E6D)],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
        ),
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 430),
              child: Card(
                elevation: 18,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(30),
                ),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(28, 34, 28, 26),
                  child: Column(
                    children: [
                      Container(
                        width: 78,
                        height: 78,
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(22),
                          gradient: const LinearGradient(
                            colors: [Color(0xFFEAF7FF), Colors.white],
                          ),
                        ),
                        child: const Icon(
                          Icons.receipt_long_rounded,
                          color: Color(0xFF0869EE),
                          size: 42,
                        ),
                      ),
                      const SizedBox(height: 15),
                      const Text(
                        'Welcome Back',
                        style: TextStyle(
                          fontSize: 27,
                          fontWeight: FontWeight.w800,
                          color: Color(0xFF0A3974),
                        ),
                      ),
                      const SizedBox(height: 5),
                      const Text(
                        'Sign in to your ReceiScan account',
                        style: TextStyle(color: Color(0xFF7890AA)),
                      ),
                      const SizedBox(height: 24),
                      TextField(
                        controller: email,
                        keyboardType: TextInputType.emailAddress,
                        decoration: const InputDecoration(
                          labelText: 'Email',
                          prefixIcon: Icon(Icons.email_outlined),
                        ),
                      ),
                      const SizedBox(height: 14),
                      TextField(
                        controller: password,
                        obscureText: obscure,
                        decoration: InputDecoration(
                          labelText: 'Password',
                          prefixIcon: const Icon(Icons.lock_outline),
                          suffixIcon: IconButton(
                            onPressed: () => setState(() => obscure = !obscure),
                            icon: Icon(
                              obscure
                                  ? Icons.visibility_outlined
                                  : Icons.visibility_off_outlined,
                            ),
                          ),
                        ),
                      ),
                      Align(
                        alignment: Alignment.centerRight,
                        child: TextButton(
                          onPressed: loading ? null : forgotPassword,
                          child: const Text('Forgot Password?'),
                        ),
                      ),
                      const SizedBox(height: 6),
                      SizedBox(
                        width: double.infinity,
                        height: 50,
                        child: FilledButton(
                          onPressed: loading ? null : login,
                          child: loading
                              ? const SizedBox(
                                  height: 22,
                                  width: 22,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    color: Colors.white,
                                  ),
                                )
                              : const Text('Login'),
                        ),
                      ),
                      const SizedBox(height: 12),
                      SizedBox(
                        width: double.infinity,
                        height: 48,
                        child: OutlinedButton.icon(
                          onPressed: register,
                          icon: const Icon(Icons.person_add_alt_1),
                          label: const Text('Create Staff Account'),
                        ),
                      ),
                      const SizedBox(height: 10),
                      // Create Admin at Create Owner: magkatabi
                      Row(
                        children: [
                          Expanded(
                            child: SizedBox(
                              height: 48,
                              child: OutlinedButton.icon(
                                onPressed: registerAdmin,
                                icon: const Icon(
                                  Icons.admin_panel_settings_outlined,
                                  size: 20,
                                ),
                                label: const FittedBox(
                                  fit: BoxFit.scaleDown,
                                  child: Text('Create Admin'),
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: SizedBox(
                              height: 48,
                              child: OutlinedButton.icon(
                                onPressed: registerPrivileged,
                                icon: const Icon(
                                  Icons.shield_outlined,
                                  size: 20,
                                ),
                                label: const FittedBox(
                                  fit: BoxFit.scaleDown,
                                  child: Text('Create Owner'),
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// Paggawa ng account: 'staff', 'admin' o 'owner'
//   Staff: Owner ID + branch + password ng branch
//   Admin: Owner ID + branch na wala pang Admin + password ng branch
//   Owner: panibagong grupo (walang Owner ID)
class RegisterDialog extends StatefulWidget {
  final ReceiScanStore store;
  final String role;

  const RegisterDialog({super.key, required this.store, this.role = 'staff'});

  // Owner: hindi na kailangan ng Owner ID at branch
  bool get privileged => role == 'owner';

  bool get isAdmin => role == 'admin';

  @override
  State<RegisterDialog> createState() => _RegisterDialogState();
}

class _RegisterDialogState extends State<RegisterDialog> {
  final name = TextEditingController();
  final email = TextEditingController();
  final pass = TextEditingController();
  final confirm = TextEditingController();

  // Owner ID code (unique) ng Owner kung saan napapabilang ang Staff
  final ownerCode = TextEditingController();

  // Password ng napiling branch
  final branchPass = TextEditingController();
  bool hideBranchPass = true;

  // Mga branch ng Owner (lalabas kapag tama na ang Owner ID)
  List<Map<String, dynamic>> branches = [];
  String? selectedBranchId;
  bool loadingBranches = false;
  String? branchError;
  String _loadedCode = '';
  Timer? _debounce;

  @override
  void initState() {
    super.initState();
    ownerCode.addListener(_onOwnerCodeChanged);
  }

  @override
  void dispose() {
    _debounce?.cancel();
    ownerCode.removeListener(_onOwnerCodeChanged);
    name.dispose();
    email.dispose();
    pass.dispose();
    confirm.dispose();
    ownerCode.dispose();
    branchPass.dispose();
    super.dispose();
  }

  // Kapag nailagay na ang buong Owner ID (OWN-XXXXXX), kunin ang mga branch
  void _onOwnerCodeChanged() {
    final code = ownerCode.text.trim().toUpperCase();
    if (code == _loadedCode) return;

    _debounce?.cancel();

    if (!RegExp(r'^OWN-[A-Z0-9]{6}$').hasMatch(code)) {
      if (branches.isNotEmpty ||
          selectedBranchId != null ||
          branchError != null) {
        setState(() {
          branches = [];
          selectedBranchId = null;
          branchError = null;
          _loadedCode = '';
        });
      }
      return;
    }

    _debounce = Timer(
      const Duration(milliseconds: 400),
      () => _loadBranches(code),
    );
  }

  Future<void> _loadBranches(String code) async {
    setState(() {
      loadingBranches = true;
      branchError = null;
      branches = [];
      selectedBranchId = null;
    });

    try {
      // Admin: mga branch na wala pang Admin lang
      final rows = await ApiService.listBranches(
        ownerCode: code,
        freeForAdmin: widget.isAdmin,
      );
      if (!mounted || ownerCode.text.trim().toUpperCase() != code) return;
      setState(() {
        branches = rows;
        _loadedCode = code;
        loadingBranches = false;
        branchError = rows.isEmpty
            ? (widget.isAdmin
                  ? 'All branches of this owner already have an Admin.'
                  : 'This owner has no branches yet. Ask your owner to add one.')
            : null;
      });
    } catch (e) {
      if (!mounted || ownerCode.text.trim().toUpperCase() != code) return;
      setState(() {
        loadingBranches = false;
        _loadedCode = '';
        branchError = 'Owner ID not found. Please check the code.';
      });
    }
  }

  Future<void> create() async {
    final n = name.text.trim();
    final e = email.text.trim().toLowerCase();
    final p = pass.text;
    final c = confirm.text;

    if (n.isEmpty || e.isEmpty || p.isEmpty || c.isEmpty) {
      snack(context, 'Please complete all fields.');
      return;
    }

    if (p.length < 6) {
      snack(context, 'Password must be at least 6 characters.');
      return;
    }

    if (p != c) {
      snack(context, 'Passwords do not match.');
      return;
    }

    // Staff/Admin: kailangang may Owner ID
    final needsOwner = !widget.privileged;
    if (needsOwner && ownerCode.text.trim().isEmpty) {
      snack(context, 'Please enter your Owner ID.');
      return;
    }

    // Staff/Admin: kailangang pumili ng branch at ilagay ang password nito
    if (needsOwner && selectedBranchId == null) {
      snack(context, 'Please choose your branch.');
      return;
    }

    if (needsOwner && branchPass.text.trim().isEmpty) {
      snack(context, 'Please enter the branch password.');
      return;
    }

    // Kailangang i-scan ang mukha para makagawa ng account
    List<double>? faceVector;
    if (kRequireFace) {
      final cap = await FaceService.capture(context, 'Register Your Face');
      if (!mounted) return;
      if (cap.embedding == null) {
        snack(context, cap.error ?? 'Face scan failed.');
        return;
      }
      faceVector = cap.embedding;
    }

    try {
      final result = await ApiService.register(
        name: n.toUpperCase(),
        email: e,
        password: p,
        role: widget.role,
        ownerCode: needsOwner ? ownerCode.text.trim().toUpperCase() : '',
        branchId: needsOwner ? (selectedBranchId ?? '') : '',
        branchPassword: needsOwner ? branchPass.text.trim() : '',
      );

      if (!mounted) return;

      if (result['success'] != true) {
        snack(context, result['message'] ?? 'Unable to create account.');
        return;
      }

      if (faceVector != null) {
        await widget.store.saveFace(e, faceVector);
        if (!mounted) return;
      }

      // Bagong Owner: ipakita ang unique Owner ID para ibigay sa staff
      final newCode = result['user']?['ownerCode']?.toString() ?? '';
      if (newCode.isNotEmpty) {
        await showDialog<void>(
          context: context,
          barrierDismissible: false,
          builder: (dialogContext) => AlertDialog(
            title: const Text('Your Owner ID'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SelectableText(
                  newCode,
                  style: const TextStyle(
                    fontSize: 26,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 2,
                  ),
                ),
                const SizedBox(height: 10),
                const Text(
                  'Give this unique ID to your admins and staff. They need '
                  'it to create an account under you. You can see it again '
                  'in your Profile.',
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () =>
                    Clipboard.setData(ClipboardData(text: newCode)),
                child: const Text('Copy'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(dialogContext),
                child: const Text('OK'),
              ),
            ],
          ),
        );
        if (!mounted) return;
      }

      Navigator.pop(context);

      snack(context, 'Account created successfully. You can now log in.');
    } catch (error) {
      if (!mounted) return;

      snack(context, errorText(error));
    }
  }

  Widget _ownerDropdown() {
    return TextField(
      controller: ownerCode,
      textCapitalization: TextCapitalization.characters,
      decoration: const InputDecoration(
        labelText: 'Owner ID',
        hintText: 'OWN-XXXXXX',
        prefixIcon: Icon(Icons.badge_outlined),
        helperText: 'Ask your owner for their unique Owner ID.',
      ),
    );
  }

  // Pagpili ng branch (lalabas kapag tama na ang Owner ID)
  Widget _branchPicker() {
    if (loadingBranches) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 8),
        child: Row(
          children: [
            SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            SizedBox(width: 10),
            Text('Loading branches...'),
          ],
        ),
      );
    }

    if (branchError != null) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Text(
          branchError!,
          style: const TextStyle(color: Colors.red, fontSize: 12.5),
        ),
      );
    }

    if (branches.isEmpty) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 4),
        child: Text(
          'Enter your Owner ID to see the branches.',
          style: TextStyle(color: Color(0xFF6E86A4), fontSize: 12.5),
        ),
      );
    }

    return Column(
      children: [
        DropdownButtonFormField<String>(
          key: ValueKey('branches-$_loadedCode'),
          initialValue: selectedBranchId,
          isExpanded: true,
          decoration: const InputDecoration(
            labelText: 'Branch',
            prefixIcon: Icon(Icons.store_outlined),
          ),
          items: [
            for (final b in branches)
              DropdownMenuItem(
                value: b['id'].toString(),
                child: Text((b['display'] ?? b['name']).toString()),
              ),
          ],
          onChanged: (v) => setState(() => selectedBranchId = v),
        ),
        const SizedBox(height: 10),
        TextField(
          controller: branchPass,
          obscureText: hideBranchPass,
          decoration: InputDecoration(
            labelText: 'Branch Password',
            prefixIcon: const Icon(Icons.lock_outline),
            helperText: 'Ask your owner for the branch password.',
            suffixIcon: IconButton(
              onPressed: () => setState(() => hideBranchPass = !hideBranchPass),
              icon: Icon(
                hideBranchPass
                    ? Icons.visibility_outlined
                    : Icons.visibility_off_outlined,
              ),
            ),
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(
        widget.privileged
            ? 'Create Owner Account'
            : widget.isAdmin
            ? 'Create Admin Account'
            : 'Create Staff Account',
      ),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (!widget.privileged) ...[
              _ownerDropdown(),
              const SizedBox(height: 10),
              _branchPicker(),
              const SizedBox(height: 10),
            ],
            TextField(
              controller: name,
              decoration: const InputDecoration(labelText: 'Full Name'),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: email,
              keyboardType: TextInputType.emailAddress,
              decoration: const InputDecoration(labelText: 'Email'),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: pass,
              obscureText: true,
              decoration: const InputDecoration(labelText: 'Password'),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: confirm,
              obscureText: true,
              decoration: const InputDecoration(labelText: 'Confirm Password'),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(onPressed: create, child: const Text('Create Account')),
      ],
    );
  }
}

// Forgot Password (Owner, Admin at Staff): 1) ilagay ang email, 2) ilagay ang
// 6-digit code na ipinadala sa email at ang bagong password.
class ForgotPasswordDialog extends StatefulWidget {
  final String initialEmail;
  const ForgotPasswordDialog({super.key, this.initialEmail = ''});

  @override
  State<ForgotPasswordDialog> createState() => _ForgotPasswordDialogState();
}

class _ForgotPasswordDialogState extends State<ForgotPasswordDialog> {
  late final TextEditingController email = TextEditingController(
    text: widget.initialEmail,
  );
  final code = TextEditingController();
  final pass = TextEditingController();
  final confirm = TextEditingController();
  bool codeSent = false;
  bool busy = false;
  String? note;

  @override
  void dispose() {
    email.dispose();
    code.dispose();
    pass.dispose();
    confirm.dispose();
    super.dispose();
  }

  Future<void> _sendCode() async {
    final e = email.text.trim().toLowerCase();
    if (e.isEmpty || !e.contains('@')) {
      snack(context, 'Please enter a valid email address.');
      return;
    }
    setState(() => busy = true);
    try {
      final res = await ApiService.forgotRequest(e);
      if (!mounted) return;
      if (res['success'] == true) {
        setState(() {
          busy = false;
          codeSent = true;
          note = res['message']?.toString();
        });
      } else {
        setState(() => busy = false);
        snack(context, res['message']?.toString() ?? 'Unable to send code.');
      }
    } catch (err) {
      if (!mounted) return;
      setState(() => busy = false);
      snack(context, errorText(err));
    }
  }

  Future<void> _reset() async {
    if (code.text.trim().length != 6) {
      snack(context, 'Please enter the 6-digit code.');
      return;
    }
    if (pass.text.length < 6) {
      snack(context, 'Password must be at least 6 characters.');
      return;
    }
    if (pass.text != confirm.text) {
      snack(context, 'Passwords do not match.');
      return;
    }
    setState(() => busy = true);
    try {
      final res = await ApiService.forgotReset(
        email: email.text.trim().toLowerCase(),
        code: code.text.trim(),
        newPassword: pass.text,
      );
      if (!mounted) return;
      if (res['success'] == true) {
        Navigator.pop(context);
        snack(context, 'Password changed. You can now log in.');
      } else {
        setState(() => busy = false);
        snack(context, res['message']?.toString() ?? 'Unable to reset.');
      }
    } catch (err) {
      if (!mounted) return;
      setState(() => busy = false);
      snack(context, errorText(err));
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Forgot Password'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              codeSent
                  ? (note ?? 'A 6-digit code was sent to your email.')
                  : 'Enter your email. We will send a 6-digit code to it.',
            ),
            const SizedBox(height: 12),
            TextField(
              controller: email,
              enabled: !codeSent,
              keyboardType: TextInputType.emailAddress,
              decoration: const InputDecoration(labelText: 'Email'),
            ),
            if (codeSent) ...[
              const SizedBox(height: 10),
              TextField(
                controller: code,
                keyboardType: TextInputType.number,
                maxLength: 6,
                decoration: const InputDecoration(
                  labelText: '6-digit code',
                  counterText: '',
                ),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: pass,
                obscureText: true,
                decoration: const InputDecoration(labelText: 'New Password'),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: confirm,
                obscureText: true,
                decoration: const InputDecoration(
                  labelText: 'Confirm New Password',
                ),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: busy ? null : () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: busy ? null : (codeSent ? _reset : _sendCode),
          child: Text(
            busy
                ? 'Please wait...'
                : (codeSent ? 'Change Password' : 'Send Code'),
          ),
        ),
      ],
    );
  }
}

// Hihingi ng isang password (ginagamit para sa branch)
class PasswordPromptDialog extends StatefulWidget {
  final String title;
  final String message;

  const PasswordPromptDialog({
    super.key,
    required this.title,
    required this.message,
  });

  @override
  State<PasswordPromptDialog> createState() => _PasswordPromptDialogState();
}

class _PasswordPromptDialogState extends State<PasswordPromptDialog> {
  final input = TextEditingController();
  bool obscure = true;

  @override
  void dispose() {
    input.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            widget.message,
            style: const TextStyle(color: Color(0xFF58728F), fontSize: 13),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: input,
            autofocus: true,
            obscureText: obscure,
            onSubmitted: (_) => Navigator.pop(context, input.text),
            decoration: InputDecoration(
              labelText: 'Password',
              prefixIcon: const Icon(Icons.lock_outline),
              suffixIcon: IconButton(
                onPressed: () => setState(() => obscure = !obscure),
                icon: Icon(
                  obscure
                      ? Icons.visibility_outlined
                      : Icons.visibility_off_outlined,
                ),
              ),
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, input.text),
          child: const Text('OK'),
        ),
      ],
    );
  }
}

// Staff na wala pang branch: pumili ng branch, tapos password ng branch
class BranchPickDialog extends StatefulWidget {
  final int userId;
  const BranchPickDialog({super.key, required this.userId});

  @override
  State<BranchPickDialog> createState() => _BranchPickDialogState();
}

class _BranchPickDialogState extends State<BranchPickDialog> {
  List<Map<String, dynamic>> branches = [];
  bool loading = true;
  bool busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      // Mga branch lang ng Owner ng user
      final rows = await ApiService.listBranches(userId: widget.userId);
      if (!mounted) return;
      setState(() => branches = rows);
    } catch (e) {
      if (!mounted) return;
      snack(context, errorText(e));
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  Future<void> _pick(Map<String, dynamic> b) async {
    final passCtrl = TextEditingController();
    bool hidePass = true;
    final enteredPassword = await showDialog<String>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: Text('Join ${b['name']}'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Enter the branch password for ${b['name']} to continue. You can get this password from your Owner or branch Admin.',
                style: const TextStyle(fontSize: 13, color: Color(0xFF5A6E85)),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: passCtrl,
                obscureText: hidePass,
                decoration: InputDecoration(
                  labelText: 'Branch Password',
                  prefixIcon: const Icon(Icons.lock_outline),
                  suffixIcon: IconButton(
                    icon: Icon(
                      hidePass ? Icons.visibility_off : Icons.visibility,
                    ),
                    onPressed: () => setDialogState(() => hidePass = !hidePass),
                  ),
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              onPressed: () {
                final p = passCtrl.text.trim();
                if (p.isEmpty) {
                  snack(ctx, 'Branch password is required.');
                  return;
                }
                Navigator.pop(ctx, p);
              },
              child: const Text('Confirm'),
            ),
          ],
        ),
      ),
    );

    if (enteredPassword == null || enteredPassword.isEmpty || !mounted) return;

    setState(() => busy = true);
    try {
      final res = await ApiService.setBranch(
        userId: widget.userId,
        branchId: b['id'].toString(),
        branchPassword: enteredPassword,
      );
      if (!mounted) return;

      if (res['success'] != true) {
        snack(context, res['message']?.toString() ?? 'Unable to set branch.');
      } else {
        Navigator.pop(context, b['name'].toString());
        return;
      }
    } catch (e) {
      if (!mounted) return;
      snack(context, errorText(e));
    }
    if (mounted) setState(() => busy = false);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Choose Your Branch'),
      content: SizedBox(
        width: 360,
        child: loading
            ? const Padding(
                padding: EdgeInsets.all(24),
                child: Center(child: CircularProgressIndicator()),
              )
            : SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text(
                      'Tap your branch.',
                      style: TextStyle(color: Color(0xFF58728F), fontSize: 13),
                    ),
                    const SizedBox(height: 8),
                    for (final b in branches)
                      ListTile(
                        enabled: !busy,
                        leading: const Icon(Icons.store_outlined),
                        title: Text((b['display'] ?? b['name']).toString()),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: () => _pick(b),
                      ),
                  ],
                ),
              ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Later'),
        ),
      ],
    );
  }
}

// Owner: tingnan, dagdagan at palitan ang password ng mga branch
class BranchesDialog extends StatefulWidget {
  final ReceiScanStore store;
  final String actorName;
  const BranchesDialog({
    super.key,
    required this.store,
    required this.actorName,
  });

  @override
  State<BranchesDialog> createState() => _BranchesDialogState();
}

class _BranchesDialogState extends State<BranchesDialog> {
  final name = TextEditingController();
  final pass = TextEditingController();
  List<Map<String, dynamic>> branches = [];
  bool busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    name.dispose();
    pass.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final rows = await ApiService.listBranches(
        userId: widget.store.currentUserId,
      );
      if (!mounted) return;
      setState(() => branches = rows);
    } catch (e) {
      if (!mounted) return;
      snack(context, errorText(e));
    }
  }

  Future<void> _changePass(Map<String, dynamic> b) async {
    final newPass = await showDialog<String>(
      context: context,
      builder: (_) => PasswordPromptDialog(
        title: 'New password for ${b['name']}',
        message: 'At least 6 characters.',
      ),
    );
    if (newPass == null || !mounted) return;

    if (newPass.length < 6) {
      snack(context, 'Password must be at least 6 characters.');
      return;
    }

    try {
      final res = await ApiService.changeBranchPassword(
        userId: widget.store.currentUserId,
        branchId: b['id'].toString(),
        newPassword: newPass,
      );
      if (!mounted) return;

      if (res['success'] != true) {
        snack(
          context,
          res['message']?.toString() ?? 'Unable to change password.',
        );
        return;
      }

      await widget.store.addLog(
        'Branch Password Changed',
        '${widget.actorName} changed the password of ${b['name']}.',
        widget.actorName,
      );
      if (!mounted) return;
      snack(context, 'Branch password changed.');
    } catch (e) {
      if (!mounted) return;
      snack(context, errorText(e));
    }
  }

  Future<void> _add() async {
    final n = name.text.trim();
    if (n.isEmpty || pass.text.length < 6) {
      snack(context, 'Enter a branch name and a password (min 6 characters).');
      return;
    }

    setState(() => busy = true);
    try {
      final res = await ApiService.addBranch(
        userId: widget.store.currentUserId,
        name: n,
        password: pass.text,
      );
      if (!mounted) return;

      if (res['success'] != true) {
        snack(context, res['message']?.toString() ?? 'Unable to add branch.');
      } else {
        await widget.store.addLog(
          'Branch Added',
          '${widget.actorName} added branch ${n.toUpperCase()}.',
          widget.actorName,
        );
        name.clear();
        pass.clear();
        await _load();
        if (!mounted) return;
        snack(context, 'Branch added.');
      }
    } catch (e) {
      if (!mounted) return;
      snack(context, errorText(e));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Manage Branches'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final b in branches)
              ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.store_outlined),
                title: Text(b['name'].toString()),
                trailing: IconButton(
                  tooltip: 'Change password',
                  icon: const Icon(Icons.key_outlined),
                  onPressed: () => _changePass(b),
                ),
              ),
            const Divider(height: 24),
            const Text(
              'Add New Branch',
              style: TextStyle(fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: name,
              textCapitalization: TextCapitalization.characters,
              decoration: const InputDecoration(labelText: 'Branch Name'),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: pass,
              obscureText: true,
              decoration: const InputDecoration(labelText: 'Branch Password'),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Close'),
        ),
        FilledButton(
          onPressed: busy ? null : _add,
          child: const Text('Add Branch'),
        ),
      ],
    );
  }
}

// -----------------------------------------------------------------------------
// MAIN SHELL
// -----------------------------------------------------------------------------

class HomeShell extends StatefulWidget {
  final ReceiScanStore store;
  final UserAccount user;
  final VoidCallback onLogout;

  const HomeShell({
    super.key,
    required this.store,
    required this.user,
    required this.onLogout,
  });

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int index = 0;

  @override
  void initState() {
    super.initState();
    _sync(showError: widget.store.getTransactions().isEmpty);
  }

  // Kunin ang pinakabagong data mula sa database
  Future<void> _sync({bool showError = false}) async {
    final ok = await widget.store.refreshAll();
    if (!mounted) return;
    setState(() {});
    if (!ok && showError) {
      final err = widget.store.lastTransactionsError;
      snack(
        context,
        err != null && err.isNotEmpty
            ? 'Server error: $err'
            : 'Cannot reach the server. Showing the last loaded data.',
      );
    }
  }

  // Mga page na pwedeng buksan ng naka-login na user.
  // Owner: walang Scan. Admin: may Scan (sa branch niya mapupunta).
  // Staff: Scan, Records, Attendance at Profile.
  List<int> _allowedPages() {
    if (isOwnerUser(widget.user)) {
      return [0, 2, if (canViewAttendance(widget.user)) 3, 4, 5, 6];
    }
    if (isAdminUser(widget.user)) {
      return [0, 1, 2, if (canViewAttendance(widget.user)) 3, 4, 5, 6];
    }
    return [0, 1, 2, if (canViewAttendance(widget.user)) 3, 6];
  }

  static List<NavigationRailDestination> _filterRail(
    List<int> allowed,
    List<NavigationRailDestination> all,
  ) => [for (final p in allowed) all[p]];

  // Listahan ng mga account (Owner/Admin lang)
  void _openStaffAccounts() {
    if (!isManagerUser(widget.user)) return;
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) =>
            StaffAccountsPage(store: widget.store, user: widget.user),
      ),
    );
  }

  // Mga request ng staff na lumipat ng branch (Owner/Admin lang)
  Future<void> _openBranchRequests() async {
    if (!isManagerUser(widget.user)) return;
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) =>
            BranchRequestsPage(store: widget.store, user: widget.user),
      ),
    );
    if (!mounted) return;
    _sync();
  }

  // Lumipat ng page at i-refresh ang data
  void _go(int v) {
    final target = _allowedPages().contains(v) ? v : 0;
    setState(() => index = target);
    _sync();
  }

  final titles = const [
    'Dashboard',
    'Scan Receipt',
    'Transactions',
    'Attendance',
    'Reports',
    'Activity Logs',
    'Profile',
  ];

  Future<void> _logoutFromMore() async {
    final ok = await confirmDialog(
      context,
      'Log Out',
      'Are you sure you want to log out?',
    );
    if (!ok || !mounted) return;

    await widget.store.addLog(
      'Logout',
      '${widget.user.name} logged out.',
      widget.user.name,
    );
    widget.onLogout();
  }

  NavigationDestination _navDestination(int page) {
    switch (page) {
      case 0:
        return const NavigationDestination(
          icon: Icon(Icons.dashboard_outlined),
          selectedIcon: Icon(Icons.dashboard),
          label: 'Home',
        );
      case 1:
        return const NavigationDestination(
          icon: Icon(Icons.document_scanner_outlined),
          selectedIcon: Icon(Icons.document_scanner),
          label: 'Scan',
        );
      case 2:
        return const NavigationDestination(
          icon: Icon(Icons.swap_horiz),
          selectedIcon: Icon(Icons.swap_horiz),
          label: 'Records',
        );
      case 3:
        return const NavigationDestination(
          icon: Icon(Icons.access_time_outlined),
          selectedIcon: Icon(Icons.access_time_filled),
          label: 'Attendance',
        );
      default:
        return const NavigationDestination(
          icon: Icon(Icons.bar_chart_outlined),
          selectedIcon: Icon(Icons.bar_chart),
          label: 'Reports',
        );
    }
  }

  void _showMore() {
    final user = widget.user;
    final avatar = widget.store.getAvatar(user.email);
    final name = user.name.trim();
    final initial = name.isEmpty ? '?' : name[0].toUpperCase();

    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      builder: (sheetContext) {
        void open(int page) {
          Navigator.pop(sheetContext);
          _go(page);
        }

        return SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // ---------- HEADER ----------
                InkWell(
                  onTap: () => open(6),
                  borderRadius: BorderRadius.circular(18),
                  child: Padding(
                    padding: const EdgeInsets.all(8),
                    child: Row(
                      children: [
                        CircleAvatar(
                          radius: 28,
                          backgroundColor: const Color(0xFFEAF5FF),
                          backgroundImage: avatar == null
                              ? null
                              : MemoryImage(avatar),
                          child: avatar == null
                              ? Text(
                                  initial,
                                  style: const TextStyle(
                                    fontSize: 24,
                                    fontWeight: FontWeight.w800,
                                    color: Color(0xFF0869EE),
                                  ),
                                )
                              : null,
                        ),
                        const SizedBox(width: 14),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                name.isEmpty ? 'Account' : name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontSize: 18,
                                  fontWeight: FontWeight.w800,
                                  color: Color(0xFF0D2D57),
                                ),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                user.email,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontSize: 12.5,
                                  color: Color(0xFF6E86A4),
                                ),
                              ),
                              const SizedBox(height: 6),
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 10,
                                  vertical: 3,
                                ),
                                decoration: BoxDecoration(
                                  color: const Color(0xFFEAF5FF),
                                  borderRadius: BorderRadius.circular(20),
                                ),
                                child: Text(
                                  formatRole(user.role),
                                  style: const TextStyle(
                                    fontSize: 10.5,
                                    fontWeight: FontWeight.w800,
                                    color: Color(0xFF0869EE),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                        const Icon(
                          Icons.chevron_right,
                          color: Color(0xFF9AAEC6),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                const Divider(height: 1),
                const SizedBox(height: 8),

                // ---------- MGA PAGE ----------
                if (isManagerUser(user)) ...[
                  _MoreTile(
                    icon: Icons.history_rounded,
                    title: 'Activity Logs',
                    subtitle: 'System activity and history',
                    color: const Color(0xFFEAF5FF),
                    foreground: const Color(0xFF0869EE),
                    active: index == 5,
                    onTap: () => open(5),
                  ),
                  _MoreTile(
                    icon: Icons.groups_rounded,
                    title: 'Staff Accounts',
                    subtitle: 'All accounts and their branches',
                    color: const Color(0xFFEAF5FF),
                    foreground: const Color(0xFF0869EE),
                    active: false,
                    onTap: () {
                      Navigator.pop(sheetContext);
                      _openStaffAccounts();
                    },
                  ),
                  _MoreTile(
                    icon: Icons.swap_horiz_rounded,
                    title: 'Branch Requests',
                    subtitle:
                        '${widget.store.getBranchRequests().length} pending approval(s)',
                    color: const Color(0xFFEAF5FF),
                    foreground: const Color(0xFF0869EE),
                    active: false,
                    onTap: () {
                      Navigator.pop(sheetContext);
                      _openBranchRequests();
                    },
                  ),
                  if (canViewAttendance(user))
                    _MoreTile(
                      icon: Icons.access_time_rounded,
                      title: 'Attendance',
                      subtitle: 'Staff attendance and history',
                      color: const Color(0xFFEAF5FF),
                      foreground: const Color(0xFF0869EE),
                      active: index == 3,
                      onTap: () => open(3),
                    ),
                ],
                _MoreTile(
                  icon: Icons.person_rounded,
                  title: 'Profile',
                  subtitle: 'Account, PIN and face recognition',
                  color: const Color(0xFFEAF5FF),
                  foreground: const Color(0xFF0869EE),
                  active: index == 6,
                  onTap: () => open(6),
                ),

                const SizedBox(height: 8),
                const Divider(height: 1),
                const SizedBox(height: 8),

                // ---------- LOG OUT ----------
                _MoreTile(
                  icon: Icons.logout_rounded,
                  title: 'Log Out',
                  subtitle: 'Sign out of this account',
                  color: const Color(0xFFFDEAEA),
                  foreground: const Color(0xFFD32F2F),
                  showChevron: false,
                  onTap: () {
                    Navigator.pop(sheetContext);
                    _logoutFromMore();
                  },
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final canAttendance = canViewAttendance(widget.user);
    final isManager = isManagerUser(widget.user);
    final allowed = _allowedPages();
    // Bottom bar.
    // Owner: Home, Reports, Records, More (walang Scan)
    // Admin: Home, Records, Scan, Reports, More
    // Staff: Home, Records, Scan, Attendance, More
    final navPages = isOwnerUser(widget.user)
        ? <int>[0, 4, 2]
        : isAdminUser(widget.user)
        ? <int>[0, 2, 1, 4]
        : <int>[0, 2, 1, if (canAttendance) 3];
    final moreNavIndex = navPages.length;
    final navSelected = navPages.contains(index)
        ? navPages.indexOf(index)
        : moreNavIndex;
    final pages = [
      DashboardPage(
        store: widget.store,
        user: widget.user,
        onScan: () => _go(1),
        onViewAll: () => _go(2),
        onRefresh: () => _sync(showError: true),
        onViewStaff: isManager ? _openStaffAccounts : null,
        onViewLogs: isManager ? () => _go(5) : null,
        onViewRequests: isManager ? _openBranchRequests : null,
      ),
      ScanPage(store: widget.store, user: widget.user, onSaved: () => _go(2)),
      TransactionsPage(store: widget.store, user: widget.user),
      AttendancePage(store: widget.store, user: widget.user),
      ReportsPage(store: widget.store),
      LogsPage(store: widget.store),
      ProfilePage(
        store: widget.store,
        user: widget.user,
        onLogout: widget.onLogout,
      ),
    ];

    return LayoutBuilder(
      builder: (context, c) {
        final desktop = c.maxWidth >= 900;

        if (desktop) {
          return Scaffold(
            body: Row(
              children: [
                NavigationRail(
                  extended: true,
                  minExtendedWidth: 235,
                  selectedIndex: allowed.contains(index)
                      ? allowed.indexOf(index)
                      : 0,
                  onDestinationSelected: (v) => _go(allowed[v]),
                  backgroundColor: Colors.white,
                  leading: Padding(
                    padding: const EdgeInsets.all(18),
                    child: Row(
                      children: const [
                        Icon(
                          Icons.receipt_long_rounded,
                          color: Color(0xFF0869EE),
                          size: 34,
                        ),
                        SizedBox(width: 10),
                        Text(
                          'ReceiScan',
                          style: TextStyle(
                            fontWeight: FontWeight.w800,
                            fontSize: 20,
                            color: Color(0xFF0A3D78),
                          ),
                        ),
                      ],
                    ),
                  ),
                  destinations: _filterRail(allowed, const [
                    NavigationRailDestination(
                      icon: Icon(Icons.dashboard_outlined),
                      selectedIcon: Icon(Icons.dashboard),
                      label: Text('Dashboard'),
                    ),
                    NavigationRailDestination(
                      icon: Icon(Icons.document_scanner_outlined),
                      selectedIcon: Icon(Icons.document_scanner),
                      label: Text('Scan Receipt'),
                    ),
                    NavigationRailDestination(
                      icon: Icon(Icons.swap_horiz),
                      selectedIcon: Icon(Icons.swap_horiz),
                      label: Text('Transactions'),
                    ),
                    NavigationRailDestination(
                      icon: Icon(Icons.access_time_outlined),
                      selectedIcon: Icon(Icons.access_time_filled),
                      label: Text('Attendance'),
                    ),
                    NavigationRailDestination(
                      icon: Icon(Icons.bar_chart_outlined),
                      selectedIcon: Icon(Icons.bar_chart),
                      label: Text('Reports'),
                    ),
                    NavigationRailDestination(
                      icon: Icon(Icons.receipt_long_outlined),
                      selectedIcon: Icon(Icons.receipt_long),
                      label: Text('Activity Logs'),
                    ),
                    NavigationRailDestination(
                      icon: Icon(Icons.person_outline),
                      selectedIcon: Icon(Icons.person),
                      label: Text('Profile'),
                    ),
                  ]),
                ),
                Expanded(child: pages[index]),
              ],
            ),
          );
        }

        return Scaffold(
          appBar: AppBar(
            title: Text(titles[index]),
            backgroundColor: Colors.white,
            elevation: 0,
          ),
          body: pages[index],
          bottomNavigationBar: NavigationBar(
            selectedIndex: navSelected,
            onDestinationSelected: (v) {
              if (v == moreNavIndex) {
                _showMore();
              } else {
                _go(navPages[v]);
              }
            },
            destinations: [
              ...navPages.map(_navDestination),
              const NavigationDestination(
                icon: Icon(Icons.more_horiz),
                selectedIcon: Icon(Icons.more_horiz),
                label: 'More',
              ),
            ],
          ),
        );
      },
    );
  }
}

// -----------------------------------------------------------------------------
// DASHBOARD
// -----------------------------------------------------------------------------

class DashboardPage extends StatelessWidget {
  final ReceiScanStore store;
  final UserAccount user;
  final VoidCallback onScan;
  final VoidCallback onViewAll;
  final Future<void> Function() onRefresh;
  final VoidCallback? onViewStaff; // Owner/Admin lang
  final VoidCallback? onViewLogs; // Owner/Admin lang
  final VoidCallback? onViewRequests; // Owner/Admin lang

  const DashboardPage({
    super.key,
    required this.store,
    required this.user,
    required this.onScan,
    required this.onViewAll,
    required this.onRefresh,
    this.onViewStaff,
    this.onViewLogs,
    this.onViewRequests,
  });

  // Halimbawa: "Oct 19"
  String _calendarLabel() {
    const m = [
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'May',
      'Jun',
      'Jul',
      'Aug',
      'Sep',
      'Oct',
      'Nov',
      'Dec',
    ];
    final n = DateTime.now();
    return '${m[n.month - 1]} ${n.day}';
  }

  String _greeting() {
    final h = DateTime.now().hour;
    if (h < 12) return 'Good morning';
    if (h < 18) return 'Good afternoon';
    return 'Good evening';
  }

  String _firstName() {
    final n = user.name.trim();
    if (n.isEmpty) return '';
    final first = n.split(' ').first;
    return first[0].toUpperCase() + first.substring(1).toLowerCase();
  }

  @override
  Widget build(BuildContext context) {
    final txs = store.getTransactions();
    final total = txs.fold<double>(0, (s, t) => s + t.amount);
    final confirmed = txs.where((t) => t.status == 'confirmed').length;
    final avatar = store.getAvatar(user.email);
    final isManager = isManagerUser(user);
    final name = _firstName();

    // Branch ng naka-login (galing sa server)
    var myBranch = '';
    for (final u in store.getUsers()) {
      if (u.id == user.id) {
        myBranch = u.branch;
        break;
      }
    }
    if (myBranch.isEmpty) myBranch = user.branch;

    return PageFrame(
      title: 'Dashboard',
      subtitle: 'Welcome back, ${user.name}',
      child: RefreshIndicator(
        onRefresh: onRefresh,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 96),
          children: [
            Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 900),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (store.offline ||
                        store.lastTransactionsError != null) ...[
                      Container(
                        margin: const EdgeInsets.only(bottom: 16),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 14,
                          vertical: 10,
                        ),
                        decoration: BoxDecoration(
                          color: const Color(0xFFFFF3CD),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: const Color(0xFFFFEEBA)),
                        ),
                        child: Row(
                          children: [
                            const Icon(
                              Icons.cloud_off,
                              size: 20,
                              color: Color(0xFF856404),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Text(
                                store.lastTransactionsError != null &&
                                        store.lastTransactionsError!.isNotEmpty
                                    ? store.lastTransactionsError!
                                    : 'Server is unreachable. Please check your internet connection.',
                                style: const TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600,
                                  color: Color(0xFF856404),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],

                    // ---------- HEADER (Staff lang) ----------
                    if (!isManager) ...[
                      Container(
                        padding: const EdgeInsets.all(16),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(22),
                          border: Border.all(color: const Color(0xFFD6E6FA)),
                        ),
                        child: Row(
                          children: [
                            CircleAvatar(
                              radius: 28,
                              backgroundColor: const Color(0xFFEAF5FF),
                              backgroundImage: avatar == null
                                  ? null
                                  : MemoryImage(avatar),
                              child: avatar == null
                                  ? Text(
                                      name.isEmpty ? '?' : name[0],
                                      style: const TextStyle(
                                        fontSize: 22,
                                        fontWeight: FontWeight.w800,
                                        color: Color(0xFF0869EE),
                                      ),
                                    )
                                  : null,
                            ),
                            const SizedBox(width: 14),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    _greeting(),
                                    style: const TextStyle(
                                      fontSize: 14,
                                      fontWeight: FontWeight.w700,
                                      color: Color(0xFF2B3F5C),
                                    ),
                                  ),
                                  Text(
                                    name.isEmpty ? 'Welcome' : name,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      fontSize: 22,
                                      fontWeight: FontWeight.w800,
                                      color: Color(0xFF0B1B33),
                                    ),
                                  ),
                                  const SizedBox(height: 2),
                                  Row(
                                    children: [
                                      const Icon(
                                        Icons.store_outlined,
                                        size: 15,
                                        color: Color(0xFF0869EE),
                                      ),
                                      const SizedBox(width: 4),
                                      Flexible(
                                        child: Text(
                                          myBranch.isEmpty
                                              ? 'No branch yet'
                                              : myBranch,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: const TextStyle(
                                            fontSize: 13,
                                            fontWeight: FontWeight.w700,
                                            color: Color(0xFF0869EE),
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                ],
                              ),
                            ),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 12,
                                vertical: 6,
                              ),
                              decoration: BoxDecoration(
                                color: const Color(0xFFEAF5FF),
                                borderRadius: BorderRadius.circular(20),
                              ),
                              child: Text(
                                formatRole(user.role),
                                style: const TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.w800,
                                  color: Color(0xFF0869EE),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 28),
                    ],

                    // ---------- HERO + STATS: Owner/Admin lang ----------
                    if (isManager) ...[
                      Material(
                        borderRadius: BorderRadius.circular(26),
                        clipBehavior: Clip.antiAlias,
                        child: InkWell(
                          onTap: onViewAll,
                          child: Ink(
                            width: double.infinity,
                            padding: const EdgeInsets.fromLTRB(24, 24, 24, 24),
                            decoration: BoxDecoration(
                              color: const Color(0xFF0869EE),
                              borderRadius: BorderRadius.circular(26),
                              border: Border.all(
                                color: const Color(0xFF0869EE),
                                width: 1.5,
                              ),
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                // ---------- PANGALAN + ROLE ----------
                                Row(
                                  children: [
                                    CircleAvatar(
                                      radius: 24,
                                      backgroundColor: Colors.white24,
                                      backgroundImage: avatar == null
                                          ? null
                                          : MemoryImage(avatar),
                                      child: avatar == null
                                          ? Text(
                                              name.isEmpty ? '?' : name[0],
                                              style: const TextStyle(
                                                fontSize: 20,
                                                fontWeight: FontWeight.w800,
                                                color: Colors.white,
                                              ),
                                            )
                                          : null,
                                    ),
                                    const SizedBox(width: 12),
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Text(
                                            _greeting(),
                                            style: const TextStyle(
                                              fontSize: 13,
                                              fontWeight: FontWeight.w700,
                                              color: Color(0xFFD6E6FA),
                                            ),
                                          ),
                                          Text(
                                            name.isEmpty ? 'Welcome' : name,
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: const TextStyle(
                                              fontSize: 20,
                                              fontWeight: FontWeight.w800,
                                              color: Colors.white,
                                            ),
                                          ),
                                          // Admin: ipakita ang branch niya
                                          if (isAdminUser(user))
                                            Text(
                                              myBranch.isEmpty
                                                  ? 'No branch yet'
                                                  : myBranch,
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                              style: const TextStyle(
                                                fontSize: 13,
                                                fontWeight: FontWeight.w700,
                                                color: Color(0xFFD6E6FA),
                                              ),
                                            ),
                                        ],
                                      ),
                                    ),
                                    Container(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 12,
                                        vertical: 6,
                                      ),
                                      decoration: BoxDecoration(
                                        color: Colors.white24,
                                        borderRadius: BorderRadius.circular(20),
                                      ),
                                      child: Text(
                                        formatRole(user.role),
                                        style: const TextStyle(
                                          fontSize: 11,
                                          fontWeight: FontWeight.w800,
                                          color: Colors.white,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 18),
                                const Text(
                                  'Total Received',
                                  style: TextStyle(
                                    color: Color(0xFFD6E6FA),
                                    fontSize: 15,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                                const SizedBox(height: 10),
                                FittedBox(
                                  fit: BoxFit.scaleDown,
                                  alignment: Alignment.centerLeft,
                                  child: Text(
                                    '₱${money(total)}',
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 40,
                                      fontWeight: FontWeight.w800,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 14),

                      // ---------- MGA STAT ----------
                      Row(
                        children: [
                          Expanded(
                            child: _MiniStat(
                              label: 'Transactions',
                              value: '${txs.length}',
                              icon: Icons.receipt_long_outlined,
                              color: Colors.white,
                              foreground: const Color(0xFF0869EE),
                              onTap: onViewAll,
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: _MiniStat(
                              label: 'Confirmed',
                              value: '$confirmed',
                              icon: Icons.verified_outlined,
                              color: Colors.white,
                              foreground: const Color(0xFF0869EE),
                              onTap: () {
                                store.pendingTxStatus = 'confirmed';
                                onViewAll();
                              },
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: _MiniStat(
                              label: 'Calendar',
                              value: _calendarLabel(),
                              icon: Icons.calendar_month_outlined,
                              color: Colors.white,
                              foreground: const Color(0xFF0869EE),
                              onTap: () => showCalendarDialog(context),
                            ),
                          ),
                        ],
                      ),
                    ] else ...[
                      // ---------- STAFF: sarili nilang scan ----------
                      if (txs.isNotEmpty) ...[
                        Material(
                          borderRadius: BorderRadius.circular(22),
                          clipBehavior: Clip.antiAlias,
                          child: InkWell(
                            onTap: onViewAll,
                            child: Ink(
                              width: double.infinity,
                              padding: const EdgeInsets.fromLTRB(
                                22,
                                20,
                                22,
                                18,
                              ),
                              decoration: BoxDecoration(
                                color: const Color(0xFF0869EE),
                                borderRadius: BorderRadius.circular(22),
                                border: Border.all(
                                  color: const Color(0xFF0869EE),
                                  width: 1.5,
                                ),
                              ),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  const Text(
                                    'Total Received',
                                    style: TextStyle(
                                      color: Color(0xFFD6E6FA),
                                      fontSize: 15,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                  const SizedBox(height: 6),
                                  FittedBox(
                                    fit: BoxFit.scaleDown,
                                    alignment: Alignment.centerLeft,
                                    child: Text(
                                      '₱${money(total)}',
                                      style: const TextStyle(
                                        color: Colors.white,
                                        fontSize: 34,
                                        fontWeight: FontWeight.w800,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(height: 14),
                      ],
                      Row(
                        children: [
                          Expanded(
                            child: _MiniStat(
                              label: 'My Scans',
                              value: '${txs.length}',
                              icon: Icons.receipt_long_outlined,
                              color: Colors.white,
                              foreground: const Color(0xFF0869EE),
                              onTap: onViewAll,
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: _MiniStat(
                              label: 'Calendar',
                              value: _calendarLabel(),
                              icon: Icons.calendar_month_outlined,
                              color: Colors.white,
                              foreground: const Color(0xFF0869EE),
                              onTap: () => showCalendarDialog(context),
                            ),
                          ),
                        ],
                      ),
                    ],

                    // ---------- OWNER / ADMIN ----------
                    if (isManager) ...[
                      const SizedBox(height: 28),
                      Row(
                        children: [
                          Expanded(
                            child: OverviewBox(
                              title: 'Staff Accounts',
                              value:
                                  '${store.getUsers().where((u) => u.role == 'staff').length}',
                              onTap: onViewStaff,
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: OverviewBox(
                              title: 'Activity Logs',
                              value: '${store.getLogs().length}',
                              onTap: onViewLogs,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          Expanded(
                            child: OverviewBox(
                              title: 'Branch Requests',
                              value: '${store.getBranchRequests().length}',
                              onTap: onViewRequests,
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: OverviewBox(
                              title: 'Password Requests',
                              value: '${store.getPasswordRequests().length}',
                              onTap: onViewStaff,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _MiniStat extends StatelessWidget {
  final String label;
  final String value;
  final IconData icon;
  final Color color;
  final Color foreground;
  final VoidCallback? onTap;

  const _MiniStat({
    required this.label,
    required this.value,
    required this.icon,
    required this.color,
    required this.foreground,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: color,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(18),
        side: const BorderSide(color: Color(0xFFD6E6FA)),
      ),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(18),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: const Color(0xFFEAF5FF),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(icon, color: foreground, size: 20),
              ),
              const SizedBox(height: 14),
              FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerLeft,
                child: Text(
                  value,
                  style: const TextStyle(
                    color: Color(0xFF0B1B33),
                    fontSize: 24,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
              const SizedBox(height: 4),
              Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: Color(0xFF2B3F5C),
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// -----------------------------------------------------------------------------
// SCAN RECEIPT
// -----------------------------------------------------------------------------

class ScanPage extends StatefulWidget {
  final ReceiScanStore store;
  final UserAccount user;
  final VoidCallback onSaved;

  const ScanPage({
    super.key,
    required this.store,
    required this.user,
    required this.onSaved,
  });

  @override
  State<ScanPage> createState() => _ScanPageState();
}

class _ScanPageState extends State<ScanPage> with WidgetsBindingObserver {
  final picker = ImagePicker();
  File? image;
  bool processing = false;
  String ocrText = '';
  String accountName = '';
  String senderNumber = '';
  String amount = '';
  String reference = '';
  String date = '';
  String time = '';
  // Nabasa ba talaga sa receipt ang petsa at oras (hindi default)?
  bool dateFound = false;
  bool timeFound = false;

  // GCash receipt ba ang na-scan? (GCash lang ang pwedeng i-save)
  bool isGcash = false;

  // Mga field ng OCR Review. Nasa state na sila (hindi ginagawa ulit sa
  // bawat build), kaya hindi na tumatalon ang cursor habang nagta-type.
  final nameCtl = TextEditingController();
  final senderCtl = TextEditingController();
  final amountCtl = TextEditingController();
  final refCtl = TextEditingController();

  // Binabasa ng AI (Gemini) ang larawan
  bool aiBusy = false;

  // Live camera
  cm.CameraController? controller;
  String? cameraError;
  bool _initializing = false;
  bool _capturing = false;

  // Auto-scan (kusang kukuha ng litrato, walang pipindutin)
  bool _autoRunning = false;
  String autoHint =
      'Point the camera at a GCash receipt. It scans automatically.';

  bool get _cameraReady => controller?.value.isInitialized == true;

  bool get _landscape =>
      MediaQuery.orientationOf(context) == Orientation.landscape;

  // Mas mababa ang camera/larawan pag naka-landscape para hindi mag-overflow
  double get _previewHeight {
    if (!_landscape) return 420;
    final h = MediaQuery.sizeOf(context).height * 0.55;
    return h.clamp(160.0, 420.0);
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initCamera();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    controller?.dispose();
    nameCtl.dispose();
    senderCtl.dispose();
    amountCtl.dispose();
    refCtl.dispose();
    super.dispose();
  }

  // Ilagay sa mga field ang kasalukuyang nabasa (OCR o AI)
  void _fillControllers() {
    nameCtl.text = accountName;
    senderCtl.text = senderNumber;
    amountCtl.text = amount;
    refCtl.text = reference;
  }

  // Patayin ang camera pag umalis sa app, buksan ulit pag bumalik
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused) {
      final c = controller;
      if (c != null) {
        controller = null;
        c.dispose();
        if (mounted) setState(() {});
      }
    } else if (state == AppLifecycleState.resumed) {
      if (controller == null) _initCamera();
    }
  }

  Future<void> _initCamera() async {
    if (_initializing) return;
    _initializing = true;
    try {
      final cameras = await cm.availableCameras();
      if (cameras.isEmpty) {
        if (!mounted) return;
        setState(() => cameraError = 'No camera found on this phone.');
        return;
      }

      final back = cameras.firstWhere(
        (c) => c.lensDirection == cm.CameraLensDirection.back,
        orElse: () => cameras.first,
      );

      final c = cm.CameraController(
        back,
        cm.ResolutionPreset.high,
        enableAudio: false,
      );
      await c.initialize();

      if (!mounted) {
        await c.dispose();
        return;
      }
      setState(() {
        controller = c;
        cameraError = null;
      });

      // Awtomatikong magsisimula ang scan, walang pipindutin
      if (image == null) _startAutoScan();
    } catch (e) {
      if (!mounted) return;
      setState(() => cameraError = 'Unable to open the camera: $e');
    } finally {
      _initializing = false;
    }
  }

  // Simulan ang auto-scan (isang loop lang ang tatakbo)
  void _startAutoScan() {
    if (_autoRunning) return;
    _autoLoop();
  }

  // Kusang kukuha ng litrato kada ~1.2 segundo at babasahin ng OCR.
  // Titigil kapag may nakitang kumpletong Amount at Reference.
  Future<void> _autoLoop() async {
    _autoRunning = true;

    // Bigyan ng sandali ang user na itutok ang camera
    await Future.delayed(const Duration(milliseconds: 1500));

    while (mounted && image == null && controller != null && _cameraReady) {
      if (processing || _capturing) {
        await Future.delayed(const Duration(milliseconds: 300));
        continue;
      }

      final c = controller!;
      String? path;
      var found = false;
      _capturing = true;
      try {
        final x = await c.takePicture();
        path = x.path;
        found = await _process(File(x.path), auto: true);
      } catch (e) {
        debugPrint('AUTO SCAN ERROR: $e');
      } finally {
        _capturing = false;
      }

      if (found) break; // may nakuha na, huminto na

      // Burahin ang litratong walang nabasa
      if (path != null) {
        try {
          await File(path).delete();
        } catch (_) {}
      }

      await Future.delayed(const Duration(milliseconds: 1200));
    }

    _autoRunning = false;
  }

  // Pumili ng larawan sa gallery
  Future<void> pickFromGallery() async {
    final x = await picker.pickImage(
      source: ImageSource.gallery,
      imageQuality: 92,
      maxWidth: 2000,
    );
    if (x == null) return;
    await _process(File(x.path));
  }

  // Bumalik sa live camera para kumuha ulit
  void retake() {
    setState(() {
      image = null;
      ocrText = '';
      accountName = '';
      senderNumber = '';
      amount = '';
      reference = '';
      date = '';
      time = '';
      isGcash = false;
      autoHint = 'Point the camera at a GCash receipt. It scans automatically.';
      _fillControllers();
    });
    if (controller == null) {
      _initCamera();
    } else {
      _startAutoScan();
    }
  }

  // auto = true: hindi ipapakita ang larawan hangga't walang kumpletong
  // Amount at Reference. Ibabalik kung may nakita.
  Future<bool> _process(File file, {bool auto = false}) async {
    if (!auto) {
      setState(() {
        image = file;
        processing = true;
        ocrText = '';
      });
    }

    try {
      final recognizer = TextRecognizer(script: TextRecognitionScript.latin);
      final result = await recognizer.processImage(InputImage.fromFile(file));
      await recognizer.close();

      final text = result.text;
      final parsed = ReceiptParser.parseBest(
        text,
        ReceiptParser.rowsFrom(result),
      );

      if (!mounted) return false;

      if (auto && (parsed.amount.isEmpty || parsed.reference.isEmpty)) {
        setState(() {
          autoHint = text.trim().isEmpty
              ? 'No receipt detected. Point the camera at the receipt.'
              : 'Hold steady, fill the frame with the receipt...';
        });
        return false;
      }

      // GCash lang ang tinatanggap
      final gcash = ReceiptParser.isGcashReceipt(text, parsed.reference);

      if (!gcash) {
        if (auto) {
          setState(() {
            autoHint =
                'Only GCash receipts can be scanned. '
                'Point the camera at a GCash receipt.';
          });
        } else {
          setState(() {
            image = null;
            processing = false;
            ocrText = '';
            isGcash = false;
          });
          snack(
            context,
            'This is not a GCash receipt. Only GCash receipts can be scanned.',
          );
          // Ituloy ang live camera
          if (controller != null) _startAutoScan();
        }
        return false;
      }

      setState(() {
        image = file;
        processing = false;
        // Gawing "*" ang mga bullet (•, ●, °, atbp.) para kapareho ng nasa receipt
        ocrText = ReceiptParser.cleanRaw(text, parsed);
        accountName = parsed.name;
        senderNumber = parsed.senderNumber;
        amount = parsed.amount;
        reference = parsed.reference;
        dateFound = parsed.date.isNotEmpty;
        timeFound = parsed.time.isNotEmpty;
        isGcash = true;
        // Ang petsa at oras ay ang PAG-SCAN (ngayon), hindi ang nasa resibo
        date = dateKey(DateTime.now());
        time = timeNow();
        _fillControllers();
      });
      return true;
    } catch (e) {
      if (!mounted) return false;
      setState(() => processing = false);
      if (!auto) snack(context, 'OCR failed: $e');
      return false;
    }
  }

  // ---------------------------------------------------------------
  // READ WITH AI (Gemini, sa server)
  // Pinupunan lang ang mga field na may nabasa ang AI. Kailangan pa ring
  // tingnan ng staff bago i-save.
  // ---------------------------------------------------------------
  Future<void> readWithAi() async {
    if (image == null || aiBusy) return;
    setState(() => aiBusy = true);
    try {
      final bytes = await image!.readAsBytes();
      if (bytes.length > 6 * 1024 * 1024) {
        if (mounted) snack(context, 'The image is too large for AI reading.');
        return;
      }
      final res = await ApiService.aiParseReceipt(
        userId: widget.store.currentUserId,
        imageBase64: base64Encode(bytes),
      );
      if (!mounted) return;
      if (res['success'] != true) {
        snack(context, res['message']?.toString() ?? 'AI could not read it.');
        return;
      }

      String pick(Object? ai, String old) {
        final v = (ai ?? '').toString().trim();
        return v.isEmpty ? old : v;
      }

      setState(() {
        accountName = pick(res['name'], accountName);
        senderNumber = pick(res['senderNumber'], senderNumber);
        amount = pick(res['amount'], amount);
        reference = pick(res['reference'], reference);
        isGcash = isGcash || res['isGcash'] == true;
        _fillControllers();
      });
      snack(context, 'Read with AI. Please check the fields before saving.');
    } catch (e) {
      if (mounted) snack(context, errorText(e));
    } finally {
      if (mounted) setState(() => aiBusy = false);
    }
  }

  // ---------------------------------------------------------------
  // ACCURACY NG SCAN (%)
  //   Amount 25 • Reference (13 digits) 25 • Name 20 • Number 15 •
  //   Petsa/Oras ng pag-scan 15  = 100
  // ---------------------------------------------------------------
  Widget _accuracyCard() {
    var score = 0;
    final issues = <String>[];

    final amt = double.tryParse(amount.replaceAll(',', '')) ?? 0;
    if (amt > 0) {
      score += 25;
    } else {
      issues.add('Amount');
    }

    final ref = reference.trim();
    if (RegExp(r'^[0-9]{13}$').hasMatch(ref)) {
      score += 25;
    } else if (ref.length >= 8) {
      score += 12;
      issues.add('Reference (not 13 digits)');
    } else {
      issues.add('Reference');
    }

    final nm = accountName.trim();
    if (nm.length >= 3 && nm != '*') {
      score += 20;
    } else {
      issues.add('Name');
    }

    final phone = senderNumber.trim();
    if (RegExp(
      r'^(\+63|0)\s?[0-9*]{3}\s[0-9*]{3}\s[0-9]{4}$',
    ).hasMatch(phone)) {
      score += 15;
    } else if (phone.isNotEmpty) {
      score += 7;
      issues.add('Number (incomplete)');
    } else {
      issues.add('Number');
    }

    // Petsa at oras ng pag-scan: laging kumpleto
    score += 15;

    final Color fg = score >= 90
        ? const Color(0xFF07976F)
        : score >= 70
        ? const Color(0xFFB76A00)
        : const Color(0xFFC62828);
    final Color bg = score >= 90
        ? const Color(0xFFE2FAF2)
        : score >= 70
        ? const Color(0xFFFFF0DC)
        : const Color(0xFFFFE9E9);

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(18),
      ),
      child: Row(
        children: [
          Text(
            '$score%',
            style: TextStyle(
              color: fg,
              fontSize: 30,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Scan accuracy',
                  style: TextStyle(
                    color: fg,
                    fontWeight: FontWeight.w800,
                    fontSize: 14,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  issues.isEmpty
                      ? '100% - all fields were read correctly.'
                      : 'Please check: ${issues.join(', ')}. '
                            'You can tap "Read with AI".',
                  style: TextStyle(color: fg, fontSize: 12),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Future<void> save() async {
    final parsedAmount =
        double.tryParse(amount.replaceAll(RegExp(r'[^0-9.]'), '')) ?? 0;

    if (accountName.trim().isEmpty ||
        parsedAmount <= 0 ||
        reference.trim().isEmpty) {
      snack(context, 'Please complete Name, Amount and Reference.');
      return;
    }

    // GCash lang: dapat GCash ang na-scan at 13 digits ang reference
    if (!isGcash) {
      snack(context, 'Only GCash receipts can be saved.');
      return;
    }

    if (!RegExp(r'^[0-9]{13}$').hasMatch(reference.trim())) {
      snack(context, 'A GCash reference number must be exactly 13 digits.');
      return;
    }

    // Larawan ng na-scan na receipt (para makita sa Transactions)
    var imageB64 = '';
    try {
      if (image != null) {
        final bytes = await image!.readAsBytes();
        if (bytes.length <= 6 * 1024 * 1024) imageB64 = base64Encode(bytes);
      }
    } catch (_) {}

    // I-save sa database (ang server ang huling tagasuri ng duplicate)
    try {
      final result = await ApiService.addTransaction(
        userId: widget.store.currentUserId,
        customerName: accountName.trim(),
        // Petsa at oras ng pag-save ngayon (hindi ang nasa resibo)
        dateTime: toSqlDateTime(dateKey(DateTime.now()), timeNow()),
        amount: parsedAmount,
        referenceNo: reference.trim(),
        status: 'confirmed',
        receiptType: 'GCash',
        rawText: ocrText,
        senderNumber: senderNumber.trim(),
        receiptImageBase64: imageB64,
      );

      if (result['success'] != true) {
        final msg =
            result['message']?.toString() ?? 'Unable to save the transaction.';
        if (!mounted) return;
        snack(context, msg);
        return;
      }
    } catch (e) {
      if (!mounted) return;
      snack(context, 'Unable to reach the server. The receipt was not saved.');
      return;
    }

    await widget.store.syncTransactions();
    await widget.store.addLog(
      'Receipt Confirmed',
      '${widget.user.name} saved ₱${money(parsedAmount)} from $accountName.',
      widget.user.name,
    );

    if (!mounted) return;
    snack(context, 'Transaction saved successfully.');
    widget.onSaved();

    setState(() {
      image = null;
      ocrText = '';
      accountName = '';
      senderNumber = '';
      amount = '';
      reference = '';
      isGcash = false;
      _fillControllers();
    });

    // Ituloy ang auto-scan para sa susunod na receipt
    if (mounted && controller != null) _startAutoScan();
  }

  // Live camera preview (auto-scan, walang shutter button)
  Widget _cameraView() {
    final c = controller;
    Widget inner;

    if (cameraError != null) {
      inner = Center(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                cameraError!,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white),
              ),
              const SizedBox(height: 12),
              OutlinedButton.icon(
                style: OutlinedButton.styleFrom(
                  foregroundColor: Colors.white,
                  side: const BorderSide(color: Colors.white38),
                ),
                onPressed: () {
                  setState(() => cameraError = null);
                  _initCamera();
                },
                icon: const Icon(Icons.refresh),
                label: const Text('Try Again'),
              ),
            ],
          ),
        ),
      );
    } else if (c == null || !c.value.isInitialized) {
      inner = const Center(child: CircularProgressIndicator());
    } else {
      final size = c.value.previewSize!;
      final pw = _landscape ? size.width : size.height;
      final ph = _landscape ? size.height : size.width;
      inner = ClipRect(
        child: FittedBox(
          fit: BoxFit.cover,
          child: SizedBox(width: pw, height: ph, child: cm.CameraPreview(c)),
        ),
      );
    }

    return ClipRRect(
      borderRadius: BorderRadius.circular(18),
      child: Container(
        height: _previewHeight,
        width: double.infinity,
        color: Colors.black,
        child: Stack(
          fit: StackFit.expand,
          children: [
            inner,
            if (_cameraReady) ...[
              IgnorePointer(
                child: Center(
                  child: Container(
                    margin: const EdgeInsets.all(22),
                    decoration: BoxDecoration(
                      border: Border.all(color: Colors.white70, width: 2),
                      borderRadius: BorderRadius.circular(16),
                    ),
                  ),
                ),
              ),
              Positioned(
                left: 12,
                right: 12,
                bottom: 12,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 8,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.black54,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      ),
                      const SizedBox(width: 10),
                      Flexible(
                        child: Text(
                          autoHint,
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 12.5,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // Owner lang ang walang Scan. Ang Admin at Staff ay nag-i-scan.
    if (isOwnerUser(widget.user)) {
      return const PageFrame(
        title: 'Scan Receipt',
        subtitle: 'Restricted',
        child: Center(
          child: Text('The Owner cannot scan receipts. Admin and Staff can.'),
        ),
      );
    }
    return PageFrame(
      title: 'Scan Receipt',
      subtitle: widget.user.branch.isEmpty
          ? 'Capture or upload a receipt and extract transaction details.'
          : 'Scans are saved to ${widget.user.branch}.',
      child: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 900),
              child: Column(
                children: [
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(18),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(26),
                      gradient: const LinearGradient(
                        colors: [Color(0xFF07182F), Color(0xFF0C4566)],
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                      ),
                    ),
                    child: Column(
                      children: [
                        if (image != null)
                          ClipRRect(
                            borderRadius: BorderRadius.circular(18),
                            child: Image.file(
                              image!,
                              height: _previewHeight,
                              width: double.infinity,
                              fit: BoxFit.contain,
                            ),
                          )
                        else
                          _cameraView(),
                        if (processing) ...[
                          const SizedBox(height: 14),
                          const LinearProgressIndicator(),
                          const SizedBox(height: 8),
                          const Text(
                            'Reading receipt with OCR...',
                            style: TextStyle(color: Colors.white),
                          ),
                        ],
                        const SizedBox(height: 15),
                        Row(
                          children: [
                            if (image != null) ...[
                              Expanded(
                                child: FilledButton.icon(
                                  onPressed: (processing || aiBusy)
                                      ? null
                                      : retake,
                                  icon: const Icon(Icons.refresh),
                                  label: const Text('Retake'),
                                ),
                              ),
                              const SizedBox(width: 10),
                            ],
                            Expanded(
                              child: OutlinedButton.icon(
                                style: OutlinedButton.styleFrom(
                                  foregroundColor: Colors.white,
                                  side: const BorderSide(color: Colors.white38),
                                ),
                                onPressed: (processing || aiBusy)
                                    ? null
                                    : pickFromGallery,
                                icon: const Icon(Icons.photo_library_outlined),
                                label: const Text('Upload Image'),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  if (image != null) ...[
                    const SizedBox(height: 20),
                    SectionCard(
                      title: 'OCR Review',
                      child: Column(
                        children: [
                          TextField(
                            controller: nameCtl,
                            onChanged: (v) => setState(() => accountName = v),
                            decoration: const InputDecoration(
                              labelText: 'Account Name',
                            ),
                          ),
                          const SizedBox(height: 12),
                          TextField(
                            controller: senderCtl,
                            keyboardType: TextInputType.phone,
                            onChanged: (v) => setState(() => senderNumber = v),
                            decoration: const InputDecoration(
                              labelText: 'Sender Number',
                              prefixIcon: Icon(Icons.phone_outlined),
                            ),
                          ),
                          const SizedBox(height: 12),
                          TextField(
                            controller: amountCtl,
                            keyboardType: const TextInputType.numberWithOptions(
                              decimal: true,
                            ),
                            onChanged: (v) => setState(() => amount = v),
                            decoration: const InputDecoration(
                              labelText: 'Amount',
                              prefixText: '₱ ',
                            ),
                          ),
                          const SizedBox(height: 12),
                          TextField(
                            controller: refCtl,
                            keyboardType: TextInputType.number,
                            onChanged: (v) => setState(() => reference = v),
                            decoration: const InputDecoration(
                              labelText: 'Reference Number',
                            ),
                          ),
                          const SizedBox(height: 12),
                          Row(
                            children: [
                              Expanded(
                                // Hindi mababago: petsa ng pag-scan
                                child: TextField(
                                  controller: TextEditingController(text: date),
                                  readOnly: true,
                                  decoration: const InputDecoration(
                                    labelText: 'Date Scanned',
                                    prefixIcon: Icon(Icons.event_outlined),
                                  ),
                                ),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: TextField(
                                  controller: TextEditingController(text: time),
                                  readOnly: true,
                                  decoration: const InputDecoration(
                                    labelText: 'Time Scanned',
                                    prefixIcon: Icon(Icons.schedule_outlined),
                                  ),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 18),
                          // AI: basahin ulit ang larawan gamit ang Gemini
                          SizedBox(
                            width: double.infinity,
                            child: OutlinedButton.icon(
                              onPressed: aiBusy ? null : readWithAi,
                              icon: aiBusy
                                  ? const SizedBox(
                                      width: 16,
                                      height: 16,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                      ),
                                    )
                                  : const Icon(Icons.auto_awesome),
                              label: Text(
                                aiBusy ? 'Reading with AI...' : 'Read with AI',
                              ),
                            ),
                          ),
                          const SizedBox(height: 10),
                          SizedBox(
                            width: double.infinity,
                            child: FilledButton.icon(
                              onPressed: aiBusy ? null : save,
                              icon: const Icon(Icons.check_circle_outline),
                              label: const Text('Confirm & Save Transaction'),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 20),
                    _accuracyCard(),
                    const SizedBox(height: 20),
                    SectionCard(
                      title: 'Raw OCR Text',
                      child: SelectableText(
                        ocrText.isEmpty ? 'No OCR text detected.' : ocrText,
                        style: const TextStyle(
                          fontSize: 12,
                          color: Color(0xFF506A85),
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class ReceiptParserResult {
  final String name;
  final String senderNumber;
  final String amount;
  final String reference;
  final String date;
  final String time;

  ReceiptParserResult({
    this.name = '',
    this.senderNumber = '',
    this.amount = '',
    this.reference = '',
    this.date = '',
    this.time = '',
  });
}

class ReceiptParser {
  // ------------------------------------------------------------
  // GCASH LANG ANG TINATANGGAP
  // Ang GCash receipt ay may nakasulat na "GCash" at 13-digit na
  // reference number. Kapag wala ang alinman, hindi ito GCash receipt.
  // ------------------------------------------------------------
  static final RegExp _gcashWord = RegExp(
    r'g\s*[-.]?\s*c\s*a\s*s\s*h',
    caseSensitive: false,
  );

  static bool isGcashReceipt(String text, String reference) {
    if (!_gcashWord.hasMatch(text)) return false;
    return RegExp(r'^[0-9]{13}$').hasMatch(reference.trim());
  }

  // Phone number ba ito? (09xx / +63 9xx) -- hindi ito reference number
  static bool _isPhoneLike(String digits) {
    if (digits.length == 11 && digits.startsWith('09')) return true;
    if (digits.length == 12 && digits.startsWith('639')) return true;
    return false;
  }

  static String _digitsOnly(String s) => s.replaceAll(RegExp(r'[^0-9]'), '');

  // Ayusin ang mga letrang madalas mapagkamalang digit ng OCR
  static String _fixDigits(String s) => s
      .replaceAll(RegExp(r'[Oo]'), '0')
      .replaceAll(RegExp(r'[Il|]'), '1')
      .replaceAll('S', '5')
      .replaceAll('B', '8');

  // Kunin ang reference number mula sa isang piraso ng text
  // (tinatanggap ang espasyo/dash sa gitna, hal. 7034 692 117384)
  static String _refFromChunk(String chunk) {
    final m = RegExp(r'((?:[0-9OoIl][ \-]?){8,26})').firstMatch(chunk);
    if (m != null) {
      final raw = m.group(1)!;
      if (RegExp(r'[0-9]').allMatches(raw).length >= 6) {
        final d = _digitsOnly(_fixDigits(raw));
        if (d.length >= 9 && d.length <= 22 && !_isPhoneLike(d)) return d;
      }
    }

    // Alphanumeric na reference (hal. sa Maya / bangko)
    for (final t in RegExp(r'[A-Za-z0-9]{8,30}').allMatches(chunk)) {
      final tok = t.group(0)!;
      if (RegExp(r'[0-9]').allMatches(tok).length >= 4) return tok;
    }
    return '';
  }

  // Reference number ng GCash ay 13 digits. Kung sumobra ang nabasa ng OCR
  // (dagdag na digit galing sa kalapit na text), 13 digits lang ang kukunin.
  static String _findReference(String text, List<String> lines) {
    final ref = _findReferenceRaw(text, lines);
    if (RegExp(r'^[0-9]+$').hasMatch(ref) && ref.length > 13) {
      return ref.substring(0, 13);
    }
    return ref;
  }

  static String _findReferenceRaw(String text, List<String> lines) {
    // 1) May label (kahit mali ng kaunti ang basa): Ref No., Reference
    //    Number, Transaction ID, Trace No., atbp. Tinitingnan ang parehong
    //    linya at ang sunod na 2 linya.
    final label = RegExp(
      r'(?:\br[ec]f(?:erence)?\b\.?|transaction\s*(?:id|no|number|#)|'
      r'trace\s*(?:no|number)|confirmation\s*(?:no|number|code)|'
      r'control\s*(?:no|number)|invoice\s*(?:no|number))'
      r'\s*(?:no|number|num|id|code|#)?\.?[\s:#.\-]*',
      caseSensitive: false,
    );
    for (var i = 0; i < lines.length; i++) {
      final m = label.firstMatch(lines[i]);
      if (m == null) continue;

      final rest = lines[i].substring(m.end);
      var found = _refFromChunk(rest);
      if (found.isNotEmpty) return found;

      for (var k = 1; k <= 2 && i + k < lines.length; k++) {
        found = _refFromChunk(lines[i + k]);
        if (found.isNotEmpty) return found;
      }
    }

    // 2) Walang label: linyang puro numero (hal. "7034 692 117384")
    for (final l in lines) {
      final t = l.trim();
      if (!RegExp(r'^[0-9][0-9 \-]{8,28}[0-9]$').hasMatch(t)) continue;
      final d = _digitsOnly(t);
      if (d.length >= 10 && d.length <= 20 && !_isPhoneLike(d)) return d;
    }

    // 3) Walang label: mahabang tuloy-tuloy na numero (10-20 digits)
    for (final m in RegExp(r'\b[0-9]{10,20}\b').allMatches(text)) {
      final d = m.group(0)!;
      if (!_isPhoneLike(d)) return d;
    }

    // 4) Walang label: numerong may espasyo, hal. 7034 692 117384
    for (final m in RegExp(
      r'\b[0-9]{3,5}[ \-][0-9]{3,5}[ \-][0-9]{3,8}\b',
    ).allMatches(text)) {
      final d = _digitsOnly(m.group(0)!);
      if (d.length >= 10 && d.length <= 20 && !_isPhoneLike(d)) return d;
    }

    return '';
  }

  // ------------------------------------------------------------
  // AMOUNT
  // ------------------------------------------------------------
  static String _normAmount(String whole, String? dec) {
    final w = whole.replaceAll(',', '');
    return dec == null || dec.isEmpty ? w : '$w.$dec';
  }

  static String _findAmount(String text, List<String> lines) {
    final skip = RegExp(
      r'balance|fee|charge|\bref|trace|account\s*(?:no|number)',
      caseSensitive: false,
    );
    // 1,000.00  |  100.00  |  1,000,00 (kuwit na mali ang basa)
    final decimal = RegExp(
      r'(?<![\d.,])(\d{1,3}(?:,\d{3})+|\d+)[.,]\s?(\d{2})(?!\d)',
    );

    double val(String a) => double.tryParse(a) ?? 0;

    // 1) Linyang may "Amount" / "Total" / "Sent": una sa itaas ang pipiliin
    for (final l in lines) {
      if (skip.hasMatch(l)) continue;
      if (!RegExp(
        r'amount|total|sent|paid|payment',
        caseSensitive: false,
      ).hasMatch(l)) {
        continue;
      }
      for (final m in decimal.allMatches(l)) {
        final a = _normAmount(m.group(1)!, m.group(2));
        if (val(a) > 0) return a;
      }
    }

    // 2) May simbolo: ₱ / PHP / P / £ / $ (madalas mabasa ng OCR ang ₱ bilang P)
    final symbol = RegExp(
      r'(?:₱|PHP|Php|(?<![A-Za-z])P|£|\$)\s?([0-9][0-9,]*(?:[.,]\d{1,2})?)',
    );
    for (final l in lines) {
      if (skip.hasMatch(l)) continue;
      for (final m in symbol.allMatches(l)) {
        var raw = m.group(1)!;
        // "1,000,00" -> 1,000.00
        raw = raw.replaceFirstMapped(
          RegExp(r',(\d{2})$'),
          (x) => '.${x.group(1)}',
        );
        final a = raw.replaceAll(',', '');
        if (val(a) > 0) return a;
      }
    }

    // 3) Walang label/simbolo: pinakamadalas lumabas na halagang may sentimo
    final counts = <String, int>{};
    final order = <String>[];
    for (final l in lines) {
      if (skip.hasMatch(l)) continue;
      for (final m in decimal.allMatches(l)) {
        final a = _normAmount(m.group(1)!, m.group(2));
        if (val(a) <= 0) continue;
        if (!counts.containsKey(a)) order.add(a);
        counts[a] = (counts[a] ?? 0) + 1;
      }
    }
    if (order.isNotEmpty) {
      var best = order.first;
      for (final a in order) {
        if (counts[a]! > counts[best]!) best = a;
      }
      return best;
    }

    // 4) Buong halagang may kuwit (hal. 1,500)
    final whole = RegExp(r'\b[0-9]{1,3}(?:,[0-9]{3})+\b').firstMatch(text);
    if (whole != null) return whole.group(0)!.replaceAll(',', '');

    return '';
  }

  // ------------------------------------------------------------
  // PANGALAN NG ACCOUNT / SENDER
  // ------------------------------------------------------------

  // Mga salitang label/header ng receipt na HINDI pangalan
  static final RegExp _labelWords = RegExp(
    r'\b(express\s*send|send\s*money|sent\s*(via|to|from)|transfer(red)?|'
    r'successful(ly)?|success|receipt|total|amount|fee|balance|ref(erence)?|'
    r'transaction|trace|invoice|date|time|number|account|message|powered|'
    r'share|save|view|details|payment|paid|instapay|pesonet|wallet|thank)\b',
    caseSensitive: false,
  );

  // Pangalan ng app/bank: hindi pangalan kung ito lang ang laman ng linya
  static const Set<String> _brands = {
    'gcash',
    'gotyme',
    'maya',
    'paymaya',
    'grabpay',
    'bdo',
    'bpi',
    'metrobank',
    'unionbank',
    'rcbc',
    'landbank',
  };

  static final RegExp _maskChars = RegExp(r'[•·●○◦∙*°＊✱∗¤]');

  // Mga simbolong madalas mabasa ng OCR sa halip na "*"
  static final RegExp _strayMask = RegExp(r'[#+"^~`<>«»¢×=]');

  // Phone number na may mask: +63 9•• ••• 4597
  static final RegExp _phone = RegExp(
    r'(?<!\d)(?:\+?\s?63|0)\s?9[^A-Za-z]{3,14}\d{3,4}(?!\d)',
  );

  // Maluwag na bersyon, kung mali ang basa ng OCR sa mga bullet
  static final RegExp _phoneLoose = RegExp(
    r'^\s*(?:\+\s?63|09).{3,20}\d{3,4}\s*$',
  );

  // Gaano ka-posibleng pangalan ang linya (mas mataas = mas posible)
  static int _nameScore(String raw) {
    final t = raw.trim();
    if (t.length < 3 || t.length > 45) return -100;
    if (_labelWords.hasMatch(t)) return -100;

    final lettersOnly = t.toLowerCase().replaceAll(RegExp(r'[^a-z]'), '');
    if (_brands.contains(lettersOnly)) return -100;

    if (RegExp(r'[₱:@/\\%_]').hasMatch(t)) return -100;

    final compact = t.replaceAll(RegExp(r'\s'), '');
    if (compact.isEmpty) return -100;

    final letters = RegExp(r'[A-Za-z]').allMatches(compact).length;
    final digits = RegExp(r'[0-9]').allMatches(compact).length;
    final okChars =
        RegExp(r"[A-Za-z•·●○◦∙*°＊✱∗¤.\-']").allMatches(compact).length +
        _strayMask.allMatches(compact).length;

    if (letters < 2 || digits > 1) return -100;
    if (okChars / compact.length < 0.85) return -100;

    var score = 10;
    if (_maskChars.hasMatch(compact)) score += 25;
    if (t == t.toUpperCase()) score += 8;
    if (RegExp(r'\s[A-Za-z]\.?$').hasMatch(t)) score += 8;

    final words = t.split(RegExp(r'\s+')).length;
    if (words >= 2) score += 6;
    if (words > 5) score -= 10;

    return score;
  }

  static String _cleanName(String v) {
    var s = v
        .replaceAll(RegExp(r'^[^A-Za-z•·●○◦∙*°＊✱∗¤]+'), '')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();

    // Gayahin ang nasa GCash: bawat bullet ay isang "*"
    s = s.replaceAll(RegExp(r'[•·●○◦∙°＊✱∗¤]'), '*');

    // Mga simbolong mali ang basa ng OCR sa "*" (#, +, ", ^, ~, atbp.)
    s = s.replaceAll(_strayMask, '*');

    // Ang masked na pangalan ay malalaking letra (hal. MO***A R.).
    // Kung ang isang salita ay may 2 o higit pang malalaking letra at may
    // maliliit na letra (hal. JOeN), ang maliliit ay maling basa ng OCR sa "*".
    s = s
        .split(' ')
        .map((w) {
          final caps = RegExp(r'[A-Z]').allMatches(w).length;
          return caps >= 2 ? w.replaceAll(RegExp(r'[a-z]'), '*') : w;
        })
        .join(' ');

    // Idikit ang mga pirasong pinaghiwalay ng espasyo ng OCR:
    //   "JO ***N D."  -> "JO***N D."
    //   "JO*** N D."  -> "JO***N D."
    //   "JO * * * N"  -> "JO***N"
    final tokens = s.split(' ');
    final out = <String>[];
    for (var i = 0; i < tokens.length; i++) {
      final w = tokens[i];
      if (out.isNotEmpty) {
        final prev = out.last;
        final onlyStars = RegExp(r'^\*+$').hasMatch(w);
        final startsStar = w.startsWith('*');
        final prevShort = RegExp(r'^[A-Za-z*]{1,4}$').hasMatch(prev);
        final singleLetter = RegExp(r'^[A-Z]$').hasMatch(w);
        final notLast = i < tokens.length - 1;

        if (onlyStars ||
            (startsStar && prevShort) ||
            (prev.endsWith('*') && singleLetter && notLast)) {
          out[out.length - 1] = prev + w;
          continue;
        }
      }
      out.add(w);
    }
    s = out.join(' ');

    // Panghuling linis: letra, "*" at espasyo lang. Ang tuldok ay iniiwan
    // lang sa inisyal (hal. "R.").
    s = s
        .split(' ')
        .where((w) => w.isNotEmpty)
        .map((w) {
          final dot = w.endsWith('.') && w.length > 1;
          final core = dot ? w.substring(0, w.length - 1) : w;
          var x = core.replaceAll(RegExp(r'[^A-Za-z*]'), '*');
          if (x.contains('*')) {
            x = x.replaceAll(RegExp(r'[a-z]'), '*');
          }
          if (RegExp(r'^[A-Za-z]$').hasMatch(x)) x = x.toUpperCase();
          return dot && !x.contains('*') ? '$x.' : x;
        })
        .join(' ');

    return s.replaceAll(RegExp(r'\s+'), ' ').trim();
  }

  // ------------------------------------------------------------
  // NUMBER NG SENDER: buo (0917 123 4567) o may mask (+63 9** *** 4597).
  // Tinatanggap ang letra/simbolo sa gitna dahil madalas mabasa ng OCR
  // ang bullet bilang "e", "o", "x", ".", atbp.
  // ------------------------------------------------------------
  static final RegExp _phoneAny = RegExp(
    r'(?<![\d])(?:\+\s?63|63|0)\s?9[0-9A-Za-z*•·●○◦∙°＊✱∗¤.,#\s\-]{3,18}?\d{4}(?![\d])',
  );

  static String _tidyNumber(String raw) {
    // Digit at "*" lang. Anumang ibang simbolo/letra ay maling basa ng OCR
    var t = raw.trim().replaceAll(RegExp(r'[\s\-]+'), '');
    t = t.replaceAll(RegExp(r'[^0-9+]'), '*');

    final pm = RegExp(r'^(\+?63|0)').firstMatch(t);
    if (pm == null) return t;

    final prefix = pm.group(1)!;
    final rest = t.substring(prefix.length);

    // Dapat 10 ang bahagi pagkatapos ng prefix: 9XX XXX XXXX
    if (rest.length < 5 || !RegExp(r'\d{4}$').hasMatch(rest)) return t;

    final last4 = rest.substring(rest.length - 4);
    var middle = rest.substring(0, rest.length - 4);
    if (!middle.startsWith('9')) return t;

    // Ayusin ang bilang ng "*" sa gitna para laging 10 ang kabuuan
    while (middle.length > 6) {
      final i = middle.lastIndexOf('*');
      if (i <= 0) break;
      middle = middle.substring(0, i) + middle.substring(i + 1);
    }
    while (middle.length < 6) {
      middle += '*';
    }
    if (middle.length != 6) return t;

    final digits = middle + last4;
    final first = digits.substring(0, 3);
    final second = digits.substring(3, 6);
    if (prefix == '0') return '0$first $second $last4';
    return '+63 $first $second $last4';
  }

  static String _findSenderNumber(List<String> lines) {
    final skip = RegExp(
      r'\bref|trace|transaction|invoice|amount|total|fee|balance',
      caseSensitive: false,
    );

    // 1) Buong number (11 digits) o masked
    for (final l in lines) {
      if (skip.hasMatch(l)) continue;
      final m = _phoneAny.firstMatch(l);
      if (m != null) {
        final t = _tidyNumber(m.group(0)!);
        final n = t.replaceAll(RegExp(r'[^0-9*]'), '').length;
        final lineDigits = _digitsOnly(l).length;
        if (n >= 9 && n <= 13 && lineDigits <= 16) return t;
      }
    }

    // 2) Kapag may label na Mobile / Phone / Number / Sender
    final label = RegExp(
      r'(?:mobile|phone|contact|number|sender)\b[^0-9+]{0,12}([+0-9][0-9*\s\-+]{8,20})',
      caseSensitive: false,
    );
    for (final l in lines) {
      if (skip.hasMatch(l)) continue;
      final m = label.firstMatch(l);
      if (m != null) return _tidyNumber(m.group(1)!);
    }

    // 3) Maluwag: buong linya ay mukhang number
    for (final l in lines) {
      if (skip.hasMatch(l)) continue;
      if (_phoneLoose.hasMatch(l) && l.length <= 24) return _tidyNumber(l);
    }

    return '';
  }

  static String _findName(String text, List<String> lines) {
    bool isPhone(String l) =>
        _phone.hasMatch(l) || _phoneAny.hasMatch(l) || _phoneLoose.hasMatch(l);

    // 1) May label: "Account Name: ...", "Recipient: ...", "Sender: ..."
    final labeled = RegExp(
      r'^(?:account\s*name|recipient(?:\s*name)?|receiver|beneficiary|'
      r'sender(?:\s*name)?|name)\b\s*[:\-]?\s*(.*)$',
      caseSensitive: false,
    );
    for (var i = 0; i < lines.length; i++) {
      final m = labeled.firstMatch(lines[i]);
      if (m == null) continue;

      final rest = (m.group(1) ?? '').trim();
      if (_nameScore(rest) > 0) return _cleanName(rest);

      if (rest.isEmpty &&
          i + 1 < lines.length &&
          _nameScore(lines[i + 1]) > 0) {
        return _cleanName(lines[i + 1]);
      }
    }

    // 2) Hanapin ang phone number: nasa itaas (o ibaba) nito ang pangalan
    for (var i = 0; i < lines.length; i++) {
      if (!isPhone(lines[i])) continue;

      final before = lines[i]
          .split(_phone.hasMatch(lines[i]) ? _phone : _phoneAny)
          .first
          .trim();
      if (_nameScore(before) > 0) return _cleanName(before);

      // Itaas muna; mas gusto ang pinakamalapit
      var best = '';
      var bestScore = 0;
      for (var k = 1; k <= 3 && i - k >= 0; k++) {
        final base = _nameScore(lines[i - k]);
        if (base <= 0) continue;
        final s = base - (k - 1) * 4;
        if (s > bestScore) {
          best = lines[i - k];
          bestScore = s;
        }
      }
      if (best.isNotEmpty) return _cleanName(best);

      // Kung wala sa itaas, subukan ang ibaba
      for (var k = 1; k <= 2 && i + k < lines.length; k++) {
        if (_nameScore(lines[i + k]) > 0) return _cleanName(lines[i + k]);
      }
    }

    // 3) Walang phone number: linyang may mask (• o *) sa taas ng receipt
    var maskedBest = '';
    var maskedScore = 0;
    for (final l in lines.take(15)) {
      final s = _nameScore(l);
      if (s > 30 && s > maskedScore) {
        maskedBest = l;
        maskedScore = s;
      }
    }
    if (maskedBest.isNotEmpty) return _cleanName(maskedBest);

    // 4) "Sent via ...": pangalan ay malapit sa itaas o ibaba nito
    final via = RegExp(r'sent\s*via', caseSensitive: false);
    for (var j = 0; j < lines.length; j++) {
      if (!via.hasMatch(lines[j])) continue;

      for (var k = 1; k <= 4 && j - k >= 0; k++) {
        if (_nameScore(lines[j - k]) > 0) return _cleanName(lines[j - k]);
      }
      for (var k = 1; k <= 3 && j + k < lines.length; k++) {
        if (_nameScore(lines[j + k]) > 0) return _cleanName(lines[j + k]);
      }
    }

    // Hindi sigurado: iwanang blangko para ikaw ang magtama
    return '';
  }

  // Buuin ang text ayon sa HILERA (row) ng receipt gamit ang posisyon ng
  // bawat linya, para magkasama ang label at halaga sa isang linya.
  static String rowsFrom(RecognizedText r) {
    final all = <TextLine>[];
    for (final b in r.blocks) {
      all.addAll(b.lines);
    }
    if (all.isEmpty) return r.text;

    all.sort(
      (a, b) => a.boundingBox.center.dy.compareTo(b.boundingBox.center.dy),
    );

    final rows = <List<TextLine>>[];
    final rowY = <double>[];
    final rowH = <double>[];

    for (final l in all) {
      final cy = l.boundingBox.center.dy;
      final h = l.boundingBox.height <= 0 ? 1.0 : l.boundingBox.height;

      if (rows.isNotEmpty &&
          (cy - rowY.last).abs() <= 0.5 * (h < rowH.last ? h : rowH.last)) {
        rows.last.add(l);
        rowY[rowY.length - 1] = (rowY.last + cy) / 2;
      } else {
        rows.add([l]);
        rowY.add(cy);
        rowH.add(h);
      }
    }

    return rows
        .map((row) {
          row.sort((a, b) => a.boundingBox.left.compareTo(b.boundingBox.left));
          return row.map((l) => l.text.trim()).join(' ');
        })
        .join('\n');
  }

  // Subukan ang row-based na text at ang orihinal; kunin ang mas kumpleto.
  static ReceiptParserResult parseBest(String rawText, String rowsText) {
    final a = parse(rowsText);
    final b = parse(rawText);

    String pick(String x, String y) => x.isNotEmpty ? x : y;

    return ReceiptParserResult(
      name: (a.name.isNotEmpty && a.name != '*')
          ? a.name
          : pick(b.name, a.name),
      senderNumber: pick(a.senderNumber, b.senderNumber),
      amount: pick(a.amount, b.amount),
      reference: pick(a.reference, b.reference),
      date: pick(a.date, b.date),
      time: pick(a.time, b.time),
    );
  }

  // Linisin ang Raw OCR Text: ang linya ng pangalan at ng number ay gagawing
  // kapareho ng nasa receipt (bullet/maling basa -> "*").
  static String cleanRaw(String text, ReceiptParserResult parsed) {
    final skip = RegExp(
      r'\bref|trace|transaction|invoice|amount|total|fee|balance',
      caseSensitive: false,
    );

    final out = <String>[];
    for (final line in text.split(RegExp(r'\r?\n'))) {
      var l = line.replaceAll(RegExp(r'[•·●○◦∙°＊✱∗¤]'), '*');
      final t = l.trim();

      if (t.isNotEmpty && !skip.hasMatch(t)) {
        // Number ng sender
        final m = _phoneAny.firstMatch(l);
        if (m != null) {
          final n = _tidyNumber(m.group(0)!);
          final cnt = n.replaceAll(RegExp(r'[^0-9*]'), '').length;
          if (cnt >= 9 && cnt <= 13) {
            out.add(l.replaceRange(m.start, m.end, n));
            continue;
          }
        }

        // Pangalan (masked)
        if (_nameScore(t) > 0) {
          final c = _cleanName(t);
          final maskedLine =
              line.contains(_maskChars) ||
              (parsed.name.contains('*') && c == parsed.name);
          if (c.contains('*') && maskedLine) {
            out.add(c);
            continue;
          }
        }
      }
      out.add(l);
    }
    return out.join('\n');
  }

  static ReceiptParserResult parse(String text) {
    final lines = text
        .split(RegExp(r'\r?\n'))
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList();

    final amount = _findAmount(text, lines);
    final reference = _findReference(text, lines);

    String date = '';
    final d = RegExp(
      r'\b(20\d{2})[-/](\d{1,2})[-/](\d{1,2})\b',
    ).firstMatch(text);
    if (d != null) {
      date =
          '${d.group(1)}-${d.group(2)!.padLeft(2, '0')}-${d.group(3)!.padLeft(2, '0')}';
    }

    // Format na "Oct 03, 2026" (GCash)
    if (date.isEmpty) {
      const monthNumbers = {
        'jan': 1,
        'feb': 2,
        'mar': 3,
        'apr': 4,
        'may': 5,
        'jun': 6,
        'jul': 7,
        'aug': 8,
        'sep': 9,
        'oct': 10,
        'nov': 11,
        'dec': 12,
      };
      final md = RegExp(
        r'\b(Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)[a-z]*\.?\s+(\d{1,2}),?\s+(20\d{2})\b',
        caseSensitive: false,
      ).firstMatch(text);
      if (md != null) {
        final monthNo = monthNumbers[md.group(1)!.toLowerCase()]!;
        date =
            '${md.group(3)}-${monthNo.toString().padLeft(2, '0')}-${md.group(2)!.padLeft(2, '0')}';
      }
    }

    String time = '';
    final tm =
        RegExp(
          r'\b(\d{1,2}:\d{2}(?::\d{2})?\s*(?:AM|PM))\b',
          caseSensitive: false,
        ).firstMatch(text) ??
        RegExp(r'\b(\d{1,2}:\d{2}(?::\d{2})?)\b').firstMatch(text);
    if (tm != null) time = tm.group(1)!;

    final foundName = _findName(text, lines);
    final name = foundName.isEmpty ? '*' : foundName;
    final senderNumber = _findSenderNumber(lines);

    return ReceiptParserResult(
      name: name,
      senderNumber: senderNumber,
      amount: amount,
      reference: reference,
      date: date,
      time: time,
    );
  }
}

// -----------------------------------------------------------------------------
// TRANSACTIONS
// -----------------------------------------------------------------------------

class TransactionsPage extends StatefulWidget {
  final ReceiScanStore store;
  final UserAccount user;

  const TransactionsPage({super.key, required this.store, required this.user});

  @override
  State<TransactionsPage> createState() => _TransactionsPageState();
}

class _TransactionsPageState extends State<TransactionsPage> {
  final search = TextEditingController();
  String status = 'All';
  String period = 'All';
  String branchFilter = 'All'; // Owner lang
  bool selectMode = false;
  bool deleting = false; // habang nagbubura
  final selected = <String>{};

  static const _periods = ['All', 'Today', 'This Week', 'This Month'];

  @override
  void initState() {
    super.initState();
    // Kunin ang filter na itinakda ng Dashboard (isang beses lang)
    status = 'All'; // walang Status filter na
    period = widget.store.pendingTxPeriod;
    widget.store.pendingTxStatus = 'All';
    widget.store.pendingTxPeriod = 'All';
    _loadBranchNames();
  }

  // Lahat ng branch ng Owner (kahit wala pang scan)
  List<String> _allBranchNames = [];

  Future<void> _loadBranchNames() async {
    // Admin: sariling branch lang ang ipapakita
    if (isAdminUser(widget.user)) {
      if (widget.user.branch.isNotEmpty) {
        _allBranchNames = [widget.user.branch];
      }
      return;
    }
    // Owner: nakakakita ng lahat ng branch
    if (!isOwnerUser(widget.user)) return;
    try {
      final rows = await ApiService.listBranches(
        userId: widget.store.currentUserId,
      );
      if (!mounted) return;
      setState(() {
        _allBranchNames = [for (final r in rows) r['name'].toString()];
      });
    } catch (e) {
      debugPrint('RECORDS BRANCHES ERROR: $e');
    }
  }

  @override
  void dispose() {
    search.dispose();
    super.dispose();
  }

  String _branchLabel(TransactionRecord t) =>
      t.branch.trim().isEmpty ? 'No Branch' : t.branch.trim();

  bool get _hasFilters => period != 'All' || branchFilter != 'All';

  void _clearFilters() {
    setState(() {
      status = 'All';
      period = 'All';
      branchFilter = 'All';
    });
  }

  bool _inPeriod(String date) {
    if (period == 'All') return true;
    final d = DateTime.tryParse(date);
    if (d == null) return false;

    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final day = DateTime(d.year, d.month, d.day);

    switch (period) {
      case 'Today':
        return day == today;
      case 'This Week':
        final monday = today.subtract(Duration(days: today.weekday - 1));
        return !day.isBefore(monday) &&
            day.isBefore(monday.add(const Duration(days: 7)));
      case 'This Month':
        return day.year == today.year && day.month == today.month;
      default:
        return true;
    }
  }

  String _dayLabel(String date) {
    final d = DateTime.tryParse(date);
    if (d == null) return date.isEmpty ? 'No date' : date;
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final day = DateTime(d.year, d.month, d.day);
    if (day == today) return 'Today';
    if (day == today.subtract(const Duration(days: 1))) return 'Yesterday';
    return date;
  }

  // Natatanging susi ng BAWAT resibo sa pagpili. Hindi lang id ang gamit
  // (kasama ang reference at oras), para kahit magkapareho ang id ng
  // ilang resibo sa database, isa-isa pa rin ang pagpili.
  String _k(TransactionRecord t) =>
      '${t.id}|${t.reference}|${t.createdAt}|${t.amount}';

  void _toggle(String key) {
    setState(() {
      if (!selected.remove(key)) selected.add(key);
    });
  }

  void _exitSelectMode() {
    setState(() {
      selectMode = false;
      selected.clear();
    });
  }

  Future<void> deleteSelected() async {
    if (selected.isEmpty) {
      snack(context, 'Select transactions first.');
      return;
    }

    final ok = await confirmDialog(
      context,
      'Delete Selected',
      'Delete ${selected.length} selected transaction(s)?',
    );
    if (!ok || !mounted) return;

    setState(() => deleting = true);
    final total = selected.length;
    var failed = 0;
    var firstError = '';
    try {
      // Ang mga napiling resibo lang (ayon sa susi ng bawat isa)
      final picked = widget.store
          .getTransactions()
          .where((t) => selected.contains(_k(t)))
          .toList();
      for (final t in picked) {
        final res = await ApiService.deleteTransaction(
          userId: widget.store.currentUserId,
          transactionId: int.tryParse(t.id) ?? 0,
          referenceNo: t.reference,
        );
        if (res['success'] != true) {
          failed++;
          if (firstError.isEmpty) firstError = res['message']?.toString() ?? '';
        }
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => deleting = false);
      snack(context, 'Unable to reach the server. Delete was not completed.');
      await widget.store.syncTransactions();
      if (!mounted) return;
      setState(() {});
      return;
    }

    await widget.store.syncTransactions();
    if (!mounted) return;
    setState(() {
      deleting = false;
      selected.clear();
      selectMode = false;
    });

    if (failed == 0) {
      snack(context, '$total transaction(s) deleted.');
    } else {
      snack(
        context,
        '$failed of $total could not be deleted'
        '${firstError.isEmpty ? '.' : ': $firstError'}',
      );
    }
  }

  Future<void> deleteAll() async {
    final ok = await confirmDialog(
      context,
      'Delete All History',
      'This will delete all transaction history.',
    );
    if (!ok) return;

    try {
      final res = await ApiService.deleteAllTransactions(
        userId: widget.store.currentUserId,
      );
      if (res['success'] != true) {
        if (!mounted) return;
        snack(context, res['message']?.toString() ?? 'Nothing was deleted.');
        return;
      }
    } catch (e) {
      if (!mounted) return;
      snack(context, 'Unable to reach the server. Nothing was deleted.');
      return;
    }

    await widget.store.syncTransactions();
    selected.clear();
    selectMode = false;
    if (!mounted) return;
    setState(() {});
  }

  // Isang receipt sa listahan (pindot = detalye; long-press = pumili)
  Widget _txRow(TransactionRecord t, bool canManage) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onLongPress: canManage
          ? () => setState(() {
              selectMode = true;
              selected.add(_k(t));
            })
          : null,
      onTap: (canManage && selectMode)
          ? () => _toggle(_k(t))
          : () => showTransactionDetail(context, widget.store.currentUserId, t),
      child: TransactionTile(
        t,
        showScanner: canManage,
        selected: selected.contains(_k(t)),
        onSelected: (canManage && selectMode) ? (_) => _toggle(_k(t)) : null,
      ),
    );
  }

  // Owner: lahat ng na-scan, nakapangkat kada BRANCH kung saan ito na-scan.
  Widget _branchGroups(
    List<TransactionRecord> all,
    List<TransactionRecord> filtered,
    bool canManage,
  ) {
    final searching = search.text.trim().isNotEmpty || period != 'All';
    final names = {
      if (!searching) ..._allBranchNames,
      for (final t in filtered) _branchLabel(t),
    }.toList()..sort();

    if (names.isEmpty) {
      return EmptyState(
        text: searching ? 'No matching transactions.' : 'No branches yet.',
      );
    }

    int newestFirst(TransactionRecord a, TransactionRecord b) {
      // Pinakabagong na-scan muna (ayon sa oras ng pag-save)
      final c = b.createdAt.compareTo(a.createdAt);
      return c != 0
          ? c
          : (int.tryParse(b.id) ?? 0).compareTo(int.tryParse(a.id) ?? 0);
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final b in names)
          Builder(
            builder: (context) {
              final items = filtered.where((t) => _branchLabel(t) == b).toList()
                ..sort(newestFirst);
              final sum = items.fold<double>(0, (s, t) => s + t.amount);
              return Container(
                margin: const EdgeInsets.only(top: 10),
                decoration: BoxDecoration(
                  color: const Color(0xFFF4F8FC),
                  borderRadius: BorderRadius.circular(16),
                ),
                child: ExpansionTile(
                  key: PageStorageKey('records-branch-$b'),
                  shape: const Border(),
                  collapsedShape: const Border(),
                  initiallyExpanded: items.isNotEmpty,
                  tilePadding: const EdgeInsets.symmetric(horizontal: 12),
                  childrenPadding: const EdgeInsets.fromLTRB(10, 0, 10, 8),
                  leading: const CircleAvatar(
                    backgroundColor: Color(0xFFEAF5FF),
                    child: Icon(Icons.store_outlined, color: Color(0xFF0869EE)),
                  ),
                  title: Text(
                    b,
                    style: const TextStyle(fontWeight: FontWeight.w800),
                  ),
                  subtitle: Text(
                    '${items.length} receipt(s) • ₱${money(sum)}',
                    style: const TextStyle(
                      fontWeight: FontWeight.w700,
                      color: Color(0xFF07976F),
                      fontSize: 12.5,
                    ),
                  ),
                  children: [
                    if (items.isEmpty)
                      const Padding(
                        padding: EdgeInsets.all(12),
                        child: Text(
                          'No scans from this branch yet.',
                          style: TextStyle(
                            color: Color(0xFF71819A),
                            fontSize: 12,
                          ),
                        ),
                      )
                    else ...[
                      for (final t in items) _txRow(t, canManage),
                      Align(
                        alignment: Alignment.centerRight,
                        child: TextButton(
                          onPressed: () => setState(() => branchFilter = b),
                          child: Text('View only $b'),
                        ),
                      ),
                    ],
                  ],
                ),
              );
            },
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    // Owner/Admin lang ang pwedeng magbura. Ang staff ay view-only.
    final canManage = isManagerUser(widget.user);
    final all = widget.store.getTransactions();
    final q = search.text.toLowerCase();

    // Mga branch na pagpipilian (Owner lang)
    final branchOptions = <String>[
      'All',
      ...{..._allBranchNames, for (final t in all) _branchLabel(t)}.toList()
        ..sort(),
    ];
    if (!branchOptions.contains(branchFilter)) branchFilter = 'All';

    final filtered = all.where((t) {
      final matchesSearch =
          q.isEmpty ||
          t.accountName.toLowerCase().contains(q) ||
          t.senderNumber.toLowerCase().contains(q) ||
          t.branch.toLowerCase().contains(q) ||
          t.scannedBy.toLowerCase().contains(q) ||
          t.reference.toLowerCase().contains(q);
      final matchesStatus = status == 'All' || t.status == status.toLowerCase();
      final matchesPeriod = _inPeriod(t.scanDate);
      final matchesBranch =
          !canManage ||
          branchFilter == 'All' ||
          _branchLabel(t) == branchFilter;
      return matchesSearch && matchesStatus && matchesPeriod && matchesBranch;
    }).toList();

    // Total Amount at bilang: HINDI apektado ng search.
    final summaryList = all.where((t) {
      final matchesStatus = status == 'All' || t.status == status.toLowerCase();
      final matchesPeriod = _inPeriod(t.scanDate);
      final matchesBranch =
          !canManage ||
          branchFilter == 'All' ||
          _branchLabel(t) == branchFilter;
      return matchesStatus && matchesPeriod && matchesBranch;
    }).toList();
    final total = summaryList.fold<double>(0, (s, t) => s + t.amount);

    // Owner: nakapangkat kada branch. Admin/Staff: kada araw.
    final pickBranchFirst = isOwnerUser(widget.user) && branchFilter == 'All';

    // Igrupo kada araw
    final groups = <String, List<TransactionRecord>>{};
    for (final t in filtered) {
      groups
          .putIfAbsent(t.scanDate.isEmpty ? 'No date' : t.scanDate, () => [])
          .add(t);
    }
    final dayKeys = groups.keys.toList()..sort((a, b) => b.compareTo(a));

    return PageFrame(
      title: 'Transaction History',
      subtitle: isAdminUser(widget.user)
          ? 'Your branch: ${widget.user.branch.isEmpty ? 'none yet' : widget.user.branch}'
          : canManage
          ? 'All branches'
          : 'Your scanned receipts',
      child: RefreshIndicator(
        onRefresh: () async {
          await widget.store.syncTransactions();
          if (!mounted) return;
          setState(() {});
        },
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 40),
          children: [
            Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 900),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // ---------- SUMMARY ----------
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(20),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(22),
                        gradient: const LinearGradient(
                          colors: [Color(0xFF0874EE), Color(0xFF0C5FD0)],
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                        ),
                      ),
                      child: Row(
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const Text(
                                  'Total Amount',
                                  style: TextStyle(
                                    color: Colors.white70,
                                    fontSize: 12,
                                  ),
                                ),
                                const SizedBox(height: 4),
                                FittedBox(
                                  fit: BoxFit.scaleDown,
                                  alignment: Alignment.centerLeft,
                                  child: Text(
                                    '₱${money(total)}',
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 28,
                                      fontWeight: FontWeight.w800,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                          Container(
                            width: 1,
                            height: 44,
                            color: Colors.white24,
                          ),
                          const SizedBox(width: 18),
                          Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text(
                                'Transactions',
                                style: TextStyle(
                                  color: Colors.white70,
                                  fontSize: 12,
                                ),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                '${summaryList.length}',
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 28,
                                  fontWeight: FontWeight.w800,
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 14),

                    // ---------- SEARCH + MENU ----------
                    Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: search,
                            onChanged: (_) => setState(() {}),
                            decoration: const InputDecoration(
                              hintText: 'Search name or reference...',
                              prefixIcon: Icon(Icons.search),
                              isDense: true,
                            ),
                          ),
                        ),
                        if (canManage) ...[
                          const SizedBox(width: 8),
                          // Kitang-kitang button para pumili ng buburahin
                          IconButton.filledTonal(
                            tooltip: selectMode
                                ? 'Cancel selection'
                                : 'Select to delete',
                            // Walang napipili sa simula; isa-isang pindutin
                            onPressed: () => selectMode
                                ? _exitSelectMode()
                                : setState(() {
                                    selected.clear();
                                    selectMode = true;
                                  }),
                            icon: Icon(
                              selectMode ? Icons.close : Icons.checklist_rtl,
                            ),
                          ),
                          PopupMenuButton<String>(
                            icon: const Icon(Icons.more_vert),
                            onSelected: (v) {
                              if (v == 'select') {
                                setState(() {
                                  selected.clear();
                                  selectMode = true;
                                });
                              } else if (v == 'delete_all') {
                                deleteAll();
                              }
                            },
                            itemBuilder: (_) => const [
                              PopupMenuItem(
                                value: 'select',
                                child: Text('Select transactions'),
                              ),
                              PopupMenuItem(
                                value: 'delete_all',
                                child: Text('Delete all history'),
                              ),
                            ],
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: 10),

                    // ---------- FILTER PILLS ----------
                    SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: Row(
                        children: [
                          if (isOwnerUser(widget.user)) ...[
                            _FilterPill(
                              label: 'Branch',
                              value: branchFilter,
                              options: branchOptions,
                              onChanged: (v) =>
                                  setState(() => branchFilter = v),
                            ),
                            const SizedBox(width: 8),
                          ],
                          _FilterPill(
                            label: 'Period',
                            value: period,
                            options: _periods,
                            onChanged: (v) => setState(() => period = v),
                          ),
                          if (_hasFilters) ...[
                            const SizedBox(width: 4),
                            TextButton(
                              onPressed: _clearFilters,
                              child: const Text('Clear'),
                            ),
                          ],
                        ],
                      ),
                    ),

                    // ---------- SELECTION BAR ----------
                    if (canManage && selectMode) ...[
                      const SizedBox(height: 10),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 4,
                        ),
                        decoration: BoxDecoration(
                          color: const Color(0xFFEAF5FF),
                          borderRadius: BorderRadius.circular(14),
                        ),
                        child: Row(
                          children: [
                            IconButton(
                              onPressed: _exitSelectMode,
                              icon: const Icon(Icons.close),
                            ),
                            Expanded(
                              child: Text(
                                '${selected.length} selected',
                                style: const TextStyle(
                                  fontWeight: FontWeight.w800,
                                  color: Color(0xFF0D2D57),
                                ),
                              ),
                            ),
                            // "All": pipiliin/aalisin LAHAT. Para isa-isa,
                            // pindutin ang bawat resibo sa listahan.
                            InkWell(
                              borderRadius: BorderRadius.circular(8),
                              onTap: filtered.isEmpty
                                  ? null
                                  : () => setState(() {
                                      final allOn = filtered.every(
                                        (e) => selected.contains(_k(e)),
                                      );
                                      if (allOn) {
                                        selected.removeAll(filtered.map(_k));
                                      } else {
                                        selected.addAll(filtered.map(_k));
                                      }
                                    }),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  IgnorePointer(
                                    child: Checkbox(
                                      value:
                                          filtered.isNotEmpty &&
                                          filtered.every(
                                            (e) => selected.contains(_k(e)),
                                          ),
                                      onChanged: (_) {},
                                    ),
                                  ),
                                  const Text('All'),
                                  const SizedBox(width: 6),
                                ],
                              ),
                            ),
                            FilledButton.icon(
                              style: FilledButton.styleFrom(
                                backgroundColor: Colors.red,
                                foregroundColor: Colors.white,
                              ),
                              onPressed: (selected.isEmpty || deleting)
                                  ? null
                                  : deleteSelected,
                              icon: deleting
                                  ? const SizedBox(
                                      width: 16,
                                      height: 16,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                        color: Colors.white,
                                      ),
                                    )
                                  : const Icon(Icons.delete_outline, size: 18),
                              label: Text('Delete (${selected.length})'),
                            ),
                          ],
                        ),
                      ),
                      const Padding(
                        padding: EdgeInsets.only(top: 6, left: 4),
                        child: Text(
                          'Tap each receipt you want to delete, '
                          'or tick "All" to select everything.',
                          style: TextStyle(
                            fontSize: 12,
                            color: Color(0xFF6E86A4),
                          ),
                        ),
                      ),
                    ],
                    const SizedBox(height: 14),

                    // ---------- BALIK SA LISTAHAN NG BRANCH ----------
                    if (isOwnerUser(widget.user) && branchFilter != 'All') ...[
                      Align(
                        alignment: Alignment.centerLeft,
                        child: TextButton.icon(
                          onPressed: () => setState(() => branchFilter = 'All'),
                          icon: const Icon(Icons.arrow_back, size: 18),
                          label: Text('All branches  •  $branchFilter'),
                        ),
                      ),
                    ],

                    // ---------- LISTAHAN ----------
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(22),
                        border: Border.all(color: const Color(0xFFE5EBF4)),
                      ),
                      child: pickBranchFirst
                          ? _branchGroups(all, filtered, canManage)
                          : filtered.isEmpty
                          ? const EmptyState(text: 'No matching transactions.')
                          : Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                for (final day in dayKeys) ...[
                                  Padding(
                                    padding: const EdgeInsets.only(
                                      top: 12,
                                      bottom: 4,
                                    ),
                                    child: Row(
                                      children: [
                                        Expanded(
                                          child: Text(
                                            _dayLabel(day),
                                            style: const TextStyle(
                                              fontWeight: FontWeight.w800,
                                              fontSize: 13,
                                              color: Color(0xFF6E86A4),
                                            ),
                                          ),
                                        ),
                                        Text(
                                          '₱${money(groups[day]!.fold<double>(0, (s, t) => s + t.amount))}',
                                          style: const TextStyle(
                                            fontWeight: FontWeight.w700,
                                            fontSize: 13,
                                            color: Color(0xFF6E86A4),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                  for (final t in groups[day]!)
                                    _txRow(t, canManage),
                                ],
                              ],
                            ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _FilterPill extends StatelessWidget {
  final String label;
  final String value;
  final List<String> options;
  final ValueChanged<String> onChanged;

  const _FilterPill({
    required this.label,
    required this.value,
    required this.options,
    required this.onChanged,
  });

  String _pretty(String s) =>
      s.isEmpty ? s : s[0].toUpperCase() + s.substring(1);

  @override
  Widget build(BuildContext context) {
    final active = value != 'All';
    final fg = active ? Colors.white : const Color(0xFF0D2D57);

    return PopupMenuButton<String>(
      onSelected: onChanged,
      itemBuilder: (_) => options
          .map((o) => PopupMenuItem(value: o, child: Text(_pretty(o))))
          .toList(),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
        decoration: BoxDecoration(
          color: active ? const Color(0xFF0869EE) : Colors.white,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: active ? const Color(0xFF0869EE) : const Color(0xFFCFE3F8),
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              active ? _pretty(value) : label,
              style: TextStyle(
                color: fg,
                fontWeight: FontWeight.w600,
                fontSize: 13,
              ),
            ),
            const SizedBox(width: 4),
            Icon(Icons.keyboard_arrow_down, size: 18, color: fg),
          ],
        ),
      ),
    );
  }
}

// -----------------------------------------------------------------------------
// ATTENDANCE
//   Owner/Admin: listahan ng Staff (Admin: branch niya lang) at pwedeng i-edit.
//   Staff: sariling Clock In / Clock Out.
// -----------------------------------------------------------------------------

class AttendancePage extends StatefulWidget {
  final ReceiScanStore store;
  final UserAccount user;

  const AttendancePage({super.key, required this.store, required this.user});

  @override
  State<AttendancePage> createState() => _AttendancePageState();
}

class _AttendancePageState extends State<AttendancePage> {
  bool busy = false;

  String get today => dateKey(DateTime.now());

  static const _months = [
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'May',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Oct',
    'Nov',
    'Dec',
  ];
  static const _weekdaysLong = [
    'Monday',
    'Tuesday',
    'Wednesday',
    'Thursday',
    'Friday',
    'Saturday',
    'Sunday',
  ];

  String _prettyDate(DateTime d) =>
      '${_weekdaysLong[d.weekday - 1]}, ${_months[d.month - 1]} ${d.day}, ${d.year}';

  AttendanceRecord? recordFor(String email) =>
      _findAttendance(widget.store.getAttendance(), email, today);

  Future<void> _run(Future<void> Function() job) async {
    if (busy) return;
    setState(() => busy = true);
    try {
      await job();
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _refresh() async {
    await widget.store.syncAttendance();
    try {
      await widget.store.refreshUsers();
    } catch (_) {}
    if (!mounted) return;
    setState(() {});
  }

  // I-save ang isang attendance record sa database
  Future<bool> _saveRecord(AttendanceRecord r) async {
    try {
      final result = await ApiService.saveAttendance(
        userId: widget.store.currentUserId,
        email: r.email,
        date: r.date,
        status: r.status,
        clockIn: r.clockIn,
        clockOut: r.clockOut,
        lateMinutes: r.lateMinutes,
        overtimeMinutes: r.overtimeMinutes,
        remarks: r.remarks,
      );

      if (result['success'] != true) {
        if (mounted) {
          snack(
            context,
            result['message']?.toString() ?? 'Unable to save attendance.',
          );
        }
        return false;
      }
    } catch (e) {
      if (mounted) {
        snack(context, 'Unable to reach the server. Attendance was not saved.');
      }
      return false;
    }

    await widget.store.syncAttendance();
    if (mounted) setState(() {});
    return true;
  }

  Future<void> clockIn() async {
    final existing = recordFor(widget.user.email);
    if (existing != null && existing.clockIn.isNotEmpty) {
      snack(context, 'You are already clocked in today.');
      return;
    }

    final now = DateTime.now();
    final lateMin = (now.hour * 60 + now.minute) - (8 * 60);

    final ok = await _saveRecord(
      AttendanceRecord(
        email: widget.user.email,
        date: today,
        status: lateMin > 0 ? 'Late' : 'Present',
        clockIn: timeNow(),
        lateMinutes: lateMin > 0 ? lateMin : 0,
      ),
    );
    if (!ok) return;

    await widget.store.addLog(
      'Clock In',
      '${widget.user.name} clocked in.',
      widget.user.name,
    );
  }

  Future<void> clockOut() async {
    final r = recordFor(widget.user.email);
    if (r == null || r.clockIn.isEmpty) {
      snack(context, 'Clock in first.');
      return;
    }

    final ok = await _saveRecord(
      AttendanceRecord(
        email: r.email,
        date: r.date,
        status: r.status,
        clockIn: r.clockIn,
        clockOut: timeNow(),
        lateMinutes: r.lateMinutes,
        overtimeMinutes: r.overtimeMinutes,
        remarks: r.remarks,
      ),
    );
    if (!ok) return;

    await widget.store.addLog(
      'Clock Out',
      '${widget.user.name} clocked out.',
      widget.user.name,
    );
  }

  String hours(String a, String b) {
    final pa = parseTime(a);
    final pb = parseTime(b);
    if (pa == null || pb == null) return '—';
    var diff = pb.difference(pa).inMinutes;
    if (diff < 0) diff = 0;
    return '${diff ~/ 60}h ${diff % 60}m';
  }

  Future<void> editRecord(UserAccount staffUser) async {
    final existing = _findAttendance(
      widget.store.getAttendance(),
      staffUser.email,
      today,
    );

    final result = await showDialog<AttendanceRecord>(
      context: context,
      builder: (_) => AttendanceEditDialog(
        staffName: staffUser.name,
        date: today,
        existing: existing,
      ),
    );

    if (result == null) return;

    result.email = staffUser.email;
    final ok = await _saveRecord(result);
    if (!ok) return;

    await widget.store.addLog(
      'Attendance Edited',
      '${widget.user.name} updated attendance for ${staffUser.name} ($today).',
      widget.user.name,
    );

    if (!mounted) return;
    snack(context, 'Attendance updated.');
  }

  // ---------------------------------------------------------------
  // BUILD
  // ---------------------------------------------------------------
  @override
  Widget build(BuildContext context) {
    if (!canViewAttendance(widget.user)) return _restricted();

    // Owner at Admin: listahan ng Staff. Staff: sariling attendance.
    final isManager = isManagerUser(widget.user);

    return PageFrame(
      title: 'Attendance',
      subtitle: isManager
          ? 'Tap a staff member to edit'
          : 'Your daily attendance',
      child: RefreshIndicator(
        onRefresh: _refresh,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 40),
          children: [
            Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 900),
                child: isManager ? _managerView() : _staffView(),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _restricted() {
    return PageFrame(
      title: 'Attendance',
      subtitle: 'Restricted',
      child: const Center(
        child: Padding(
          padding: EdgeInsets.all(30),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.lock_outline, size: 54, color: Color(0xFF71819A)),
              SizedBox(height: 14),
              Text(
                'Attendance is restricted.',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
              ),
              SizedBox(height: 6),
              Text(
                'Only approved accounts can view attendance.',
                textAlign: TextAlign.center,
                style: TextStyle(color: Color(0xFF71819A)),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ---------------------------------------------------------------
  // STAFF VIEW
  // ---------------------------------------------------------------
  Widget _staffView() {
    final my = recordFor(widget.user.email);
    final hasIn = my?.clockIn.isNotEmpty == true;
    final hasOut = my?.clockOut.isNotEmpty == true;
    final late = my?.lateMinutes ?? 0;

    final statusText = !hasIn
        ? 'Not clocked in'
        : (hasOut ? 'Shift completed' : 'Currently working');

    final total = hasOut
        ? hours(my!.clockIn, my.clockOut)
        : (hasIn ? 'Ongoing' : '—');

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(22),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(24),
            gradient: const LinearGradient(
              colors: [Color(0xFF0874EE), Color(0xFF0C5FD0)],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                _prettyDate(DateTime.now()),
                style: const TextStyle(color: Colors.white70, fontSize: 13),
              ),
              const SizedBox(height: 6),
              Text(
                statusText,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 24,
                  fontWeight: FontWeight.w800,
                ),
              ),
              if (late > 0)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    'Late by $late min',
                    style: const TextStyle(
                      color: Colors.amberAccent,
                      fontSize: 13,
                    ),
                  ),
                ),
              const SizedBox(height: 18),
              Row(
                children: [
                  Expanded(
                    child: _AttTimeBox(
                      label: 'Clock In',
                      value: hasIn ? my!.clockIn : '—',
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: _AttTimeBox(
                      label: 'Clock Out',
                      value: hasOut ? my!.clockOut : '—',
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: _AttTimeBox(label: 'Total', value: total),
                  ),
                ],
              ),
              const SizedBox(height: 18),
              SizedBox(
                width: double.infinity,
                height: 50,
                child: _mainButton(hasIn, hasOut),
              ),
            ],
          ),
        ),
        const SizedBox(height: 20),
        AttendanceLogCard(store: widget.store, people: [widget.user]),
      ],
    );
  }

  Widget _mainButton(bool hasIn, bool hasOut) {
    final style = FilledButton.styleFrom(
      backgroundColor: Colors.white,
      foregroundColor: const Color(0xFF0869EE),
      disabledBackgroundColor: Colors.white24,
      disabledForegroundColor: Colors.white70,
    );

    if (hasOut) {
      return FilledButton.icon(
        style: style,
        onPressed: null,
        icon: const Icon(Icons.check_circle_outline),
        label: const Text('Done for today'),
      );
    }

    if (!hasIn) {
      return FilledButton.icon(
        style: style,
        onPressed: busy ? null : () => _run(clockIn),
        icon: const Icon(Icons.login),
        label: Text(busy ? 'Saving...' : 'Clock In'),
      );
    }

    return FilledButton.icon(
      style: style,
      onPressed: busy ? null : () => _run(clockOut),
      icon: const Icon(Icons.logout),
      label: Text(busy ? 'Saving...' : 'Clock Out'),
    );
  }

  // ---------------------------------------------------------------
  // OWNER / ADMIN VIEW
  // ---------------------------------------------------------------
  Widget _managerView() {
    final staff = widget.store
        .getUsers()
        .where((u) => u.role == 'staff')
        .toList();
    final all = widget.store.getAttendance();
    final day = today;

    var present = 0;
    var late = 0;
    var leave = 0;
    var notIn = 0;

    for (final u in staff) {
      final r = _findAttendance(all, u.email, day);
      switch (r?.status) {
        case 'Present':
          present++;
          break;
        case 'Late':
          late++;
          break;
        case 'On Leave':
        case 'Half Day':
          leave++;
          break;
        default:
          notIn++;
      }
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          _prettyDate(DateTime.now()),
          style: const TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w800,
            color: Color(0xFF0D2D57),
          ),
        ),
        const SizedBox(height: 4),
        const Text(
          'Tap a staff member to edit their attendance.',
          style: TextStyle(fontSize: 12.5, color: Color(0xFF6E86A4)),
        ),
        const SizedBox(height: 14),
        Row(
          children: [
            Expanded(
              child: _AttStat(
                label: 'Present',
                value: present,
                fg: const Color(0xFF07976F),
                bg: const Color(0xFFE2FAF2),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: _AttStat(
                label: 'Late',
                value: late,
                fg: const Color(0xFFB76A00),
                bg: const Color(0xFFFFF0DC),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: _AttStat(
                label: 'On leave',
                value: leave,
                fg: const Color(0xFF7047C8),
                bg: const Color(0xFFF0EAFF),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: _AttStat(
                label: 'Not in',
                value: notIn,
                fg: const Color(0xFF71819A),
                bg: const Color(0xFFF1F4F9),
              ),
            ),
          ],
        ),
        const SizedBox(height: 18),
        SectionCard(
          title: 'Staff Today',
          child: staff.isEmpty
              ? const EmptyState(text: 'No staff accounts yet.')
              : Column(
                  children: staff.map((u) {
                    final r = _findAttendance(all, u.email, day);
                    final label = r?.status ?? 'Not yet';
                    return _AttRow(
                      leading: _attAvatar(u.name, label),
                      title: u.name,
                      subtitle: _attTimes(r),
                      label: label,
                      onEdit: () => editRecord(u),
                    );
                  }).toList(),
                ),
        ),
        const SizedBox(height: 18),
        AttendanceLogCard(store: widget.store, people: staff),
      ],
    );
  }
}

// -----------------------------------------------------------------------------
// ATTENDANCE LOG (huling 7 araw)
// -----------------------------------------------------------------------------

class AttendanceLogCard extends StatelessWidget {
  final ReceiScanStore store;
  final List<UserAccount> people;
  final int days;

  const AttendanceLogCard({
    super.key,
    required this.store,
    required this.people,
    this.days = 7,
  });

  static const _weekdays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

  @override
  Widget build(BuildContext context) {
    final records = store.getAttendance();
    final now = DateTime.now();
    final todayKey = dateKey(now);
    final dates = List.generate(days, (i) => now.subtract(Duration(days: i)));

    Widget body;

    if (people.isEmpty) {
      body = const EmptyState(text: 'No accounts to show.');
    } else if (people.length == 1) {
      // Isang tao lang: patag na listahan kada araw
      body = Column(
        children: dates.map((date) {
          final day = dateKey(date);
          final isToday = day == todayKey;
          final r = _findAttendance(records, people.first.email, day);
          final label = r?.status ?? (isToday ? 'Not yet' : 'Absent');

          return _AttRow(
            leading: _DateBadge(date: date, highlight: isToday),
            title: isToday ? 'Today' : '${_weekdays[date.weekday - 1]}, $day',
            subtitle: _attTimes(r),
            label: label,
          );
        }).toList(),
      );
    } else {
      // Marami: nakapangkat kada araw, mabubuksan para makita ang bawat isa
      body = Column(
        children: dates.map((date) {
          final day = dateKey(date);
          final isToday = day == todayKey;
          var clockedIn = 0;
          final rows = <Widget>[];

          for (final u in people) {
            final r = _findAttendance(records, u.email, day);
            if (r?.clockIn.isNotEmpty == true) clockedIn++;
            final label = r?.status ?? (isToday ? 'Not yet' : 'Absent');

            rows.add(
              _AttRow(
                leading: _attAvatar(u.name, label),
                title: u.name,
                subtitle: _attTimes(r),
                label: label,
              ),
            );
          }

          return ExpansionTile(
            shape: const Border(),
            collapsedShape: const Border(),
            tilePadding: EdgeInsets.zero,
            initiallyExpanded: isToday,
            leading: _DateBadge(date: date, highlight: isToday),
            title: Text(
              isToday ? 'Today' : '${_weekdays[date.weekday - 1]}, $day',
              style: const TextStyle(fontWeight: FontWeight.w800),
            ),
            subtitle: Text('$clockedIn of ${people.length} clocked in'),
            children: rows,
          );
        }).toList(),
      );
    }

    return SectionCard(title: 'Last $days Days', child: body);
  }
}

// -----------------------------------------------------------------------------
// MGA MALILIIT NA PIRASO NG ATTENDANCE UI
// -----------------------------------------------------------------------------

class _AttStyle {
  final Color fg;
  final Color bg;
  final IconData icon;
  const _AttStyle(this.fg, this.bg, this.icon);
}

_AttStyle _attStyleFor(String label) {
  switch (label) {
    case 'Present':
      return const _AttStyle(
        Color(0xFF07976F),
        Color(0xFFE2FAF2),
        Icons.check_circle,
      );
    case 'Late':
      return const _AttStyle(
        Color(0xFFB76A00),
        Color(0xFFFFF0DC),
        Icons.schedule,
      );
    case 'On Leave':
    case 'Half Day':
      return const _AttStyle(
        Color(0xFF7047C8),
        Color(0xFFF0EAFF),
        Icons.beach_access,
      );
    case 'Absent':
      return const _AttStyle(
        Color(0xFFD32F2F),
        Color(0xFFFDEAEA),
        Icons.cancel,
      );
    default:
      return const _AttStyle(
        Color(0xFF71819A),
        Color(0xFFF1F4F9),
        Icons.hourglass_empty,
      );
  }
}

AttendanceRecord? _findAttendance(
  List<AttendanceRecord> list,
  String email,
  String day,
) {
  final e = email.trim().toLowerCase();
  for (final r in list) {
    if (r.email.trim().toLowerCase() == e && r.date == day) return r;
  }
  return null;
}

String _attTimes(AttendanceRecord? r) {
  final inT = (r?.clockIn.isNotEmpty == true) ? r!.clockIn : '—';
  final outT = (r?.clockOut.isNotEmpty == true) ? r!.clockOut : '—';
  final late = r?.lateMinutes ?? 0;
  final lateText = late > 0 ? ' • Late $late min' : '';
  return 'In: $inT • Out: $outT$lateText';
}

Widget _attAvatar(String name, String label) {
  final s = _attStyleFor(label);
  final n = name.trim();
  return CircleAvatar(
    radius: 20,
    backgroundColor: s.bg,
    child: Text(
      n.isEmpty ? '?' : n[0].toUpperCase(),
      style: TextStyle(color: s.fg, fontWeight: FontWeight.w800),
    ),
  );
}

class _AttPill extends StatelessWidget {
  final String label;
  const _AttPill(this.label);

  @override
  Widget build(BuildContext context) {
    final s = _attStyleFor(label);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: s.bg,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(s.icon, size: 13, color: s.fg),
          const SizedBox(width: 4),
          Text(
            label,
            style: TextStyle(
              color: s.fg,
              fontSize: 12,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}

class _AttRow extends StatelessWidget {
  final Widget leading;
  final String title;
  final String subtitle;
  final String label;
  final VoidCallback? onEdit;

  const _AttRow({
    required this.leading,
    required this.title,
    required this.subtitle,
    required this.label,
    this.onEdit,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onEdit,
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Row(
          children: [
            leading,
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontWeight: FontWeight.w800,
                      color: Color(0xFF12233F),
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    style: const TextStyle(
                      fontSize: 12,
                      color: Color(0xFF71819A),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            _AttPill(label),
            if (onEdit != null) ...[
              const SizedBox(width: 6),
              const Icon(
                Icons.edit_outlined,
                size: 18,
                color: Color(0xFF71819A),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _AttStat extends StatelessWidget {
  final String label;
  final int value;
  final Color fg;
  final Color bg;

  const _AttStat({
    required this.label,
    required this.value,
    required this.fg,
    required this.bg,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '$value',
            style: TextStyle(
              color: fg,
              fontSize: 22,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: fg, fontSize: 11.5),
          ),
        ],
      ),
    );
  }
}

class _AttTimeBox extends StatelessWidget {
  final String label;
  final String value;

  const _AttTimeBox({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: .14),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: const TextStyle(color: Colors.white70, fontSize: 11),
          ),
          const SizedBox(height: 4),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(
              value,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 15,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _DateBadge extends StatelessWidget {
  final DateTime date;
  final bool highlight;

  const _DateBadge({required this.date, this.highlight = false});

  static const _wd = ['MON', 'TUE', 'WED', 'THU', 'FRI', 'SAT', 'SUN'];

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 44,
      height: 44,
      decoration: BoxDecoration(
        color: highlight ? const Color(0xFF0869EE) : const Color(0xFFF1F4F9),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(
            '${date.day}',
            style: TextStyle(
              fontSize: 16,
              height: 1.1,
              fontWeight: FontWeight.w800,
              color: highlight ? Colors.white : const Color(0xFF0D2D57),
            ),
          ),
          Text(
            _wd[date.weekday - 1],
            style: TextStyle(
              fontSize: 9,
              fontWeight: FontWeight.w700,
              color: highlight ? Colors.white70 : const Color(0xFF6E86A4),
            ),
          ),
        ],
      ),
    );
  }
}

class AttendanceEditDialog extends StatefulWidget {
  final String staffName;
  final String date;
  final AttendanceRecord? existing;

  const AttendanceEditDialog({
    super.key,
    required this.staffName,
    required this.date,
    required this.existing,
  });

  @override
  State<AttendanceEditDialog> createState() => _AttendanceEditDialogState();
}

class _AttendanceEditDialogState extends State<AttendanceEditDialog> {
  late String status;
  late TextEditingController clockIn;
  late TextEditingController clockOut;
  late TextEditingController lateMinutes;
  late TextEditingController overtimeMinutes;
  late TextEditingController remarks;

  static const statuses = ['Present', 'Late', 'Absent', 'On Leave', 'Half Day'];

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    status = statuses.contains(e?.status) ? e!.status : 'Present';
    clockIn = TextEditingController(text: e?.clockIn ?? '');
    clockOut = TextEditingController(text: e?.clockOut ?? '');
    lateMinutes = TextEditingController(text: '${e?.lateMinutes ?? 0}');
    overtimeMinutes = TextEditingController(text: '${e?.overtimeMinutes ?? 0}');
    remarks = TextEditingController(text: e?.remarks ?? '');
  }

  @override
  void dispose() {
    clockIn.dispose();
    clockOut.dispose();
    lateMinutes.dispose();
    overtimeMinutes.dispose();
    remarks.dispose();
    super.dispose();
  }

  void save() {
    final record = AttendanceRecord(
      email: '',
      date: widget.date,
      status: status,
      clockIn: clockIn.text.trim(),
      clockOut: clockOut.text.trim(),
      lateMinutes: int.tryParse(lateMinutes.text.trim()) ?? 0,
      overtimeMinutes: int.tryParse(overtimeMinutes.text.trim()) ?? 0,
      remarks: remarks.text.trim(),
    );
    Navigator.pop(context, record);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('Edit Attendance — ${widget.staffName}'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(widget.date, style: const TextStyle(color: Color(0xFF71819A))),
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              initialValue: status,
              decoration: const InputDecoration(labelText: 'Status'),
              items: statuses
                  .map((s) => DropdownMenuItem(value: s, child: Text(s)))
                  .toList(),
              onChanged: (v) => setState(() => status = v ?? 'Present'),
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: clockIn,
                    decoration: const InputDecoration(
                      labelText: 'Clock In',
                      hintText: '08:00 AM',
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: TextField(
                    controller: clockOut,
                    decoration: const InputDecoration(
                      labelText: 'Clock Out',
                      hintText: '05:00 PM',
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: lateMinutes,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(labelText: 'Late (mins)'),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: TextField(
                    controller: overtimeMinutes,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      labelText: 'Overtime (mins)',
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            TextField(
              controller: remarks,
              maxLines: 2,
              decoration: const InputDecoration(labelText: 'Remarks'),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(onPressed: save, child: const Text('Save')),
      ],
    );
  }
}

// -----------------------------------------------------------------------------
// REPORTS (Owner: lahat ng branch. Admin: branch niya lang)
//   1. Pili ng saklaw: Daily (14 araw) / Monthly (12 buwan) / Yearly (5 taon)
//   2. Total Received + pagbabago kumpara sa nakaraang araw/buwan/taon
//   3. KPI: bilang ng resibo, average, pinakamataas, duplicates
//   4. Bar chart (pindutin ang bar para makita ang detalye)
//   5. Kada branch at Top scanners
//   6. Duplicate Receipts at Daily Transaction Summary
// -----------------------------------------------------------------------------

class ReportsPage extends StatefulWidget {
  final ReceiScanStore store;
  const ReportsPage({super.key, required this.store});

  @override
  State<ReportsPage> createState() => _ReportsPageState();
}

// Kabuuan at bilang ng isang grupo ng resibo
class _Agg {
  double total = 0;
  int count = 0;

  void add(double amount) {
    total += amount;
    count++;
  }
}

class _ReportsPageState extends State<ReportsPage> {
  ReceiScanStore get store => widget.store;

  static const _ink = Color(0xFF0B1B33);
  static const _sub = Color(0xFF6E86A4);
  static const _blue = Color(0xFF0869EE);
  static const _green = Color(0xFF07976F);
  static const _red = Color(0xFFC62828);
  static const _line = Color(0xFFE5EBF4);

  static const _monthsShort = [
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'May',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Oct',
    'Nov',
    'Dec',
  ];

  // Daily / Monthly / Yearly
  String overviewMode = 'Daily';

  // Napiling branch sa Daily Transaction Summary ('All' = lahat)
  String selectedBranch = 'All';

  // Pinindot na bar sa chart (null = pinakabago)
  String? _selectedBar;

  // Mga branch ng Owner (galing sa server)
  List<String> _branchNames = [];

  // Mga pagtatangkang mag-duplicate (galing sa server)
  List<Map<String, dynamic>> _dupRows = [];

  @override
  void initState() {
    super.initState();
    _loadBranchNames();
    _loadDuplicates();
  }

  Future<void> _loadBranchNames() async {
    try {
      final rows = await ApiService.listBranches(userId: store.currentUserId);
      if (!mounted) return;
      setState(() {
        _branchNames = [for (final r in rows) r['name'].toString()];
      });
    } catch (e) {
      debugPrint('REPORT BRANCHES ERROR: $e');
    }
  }

  Future<void> _loadDuplicates() async {
    try {
      final rows = await ApiService.getDuplicates(store.currentUserId);
      if (!mounted) return;
      setState(() => _dupRows = rows);
    } catch (e) {
      debugPrint('REPORT DUPLICATES ERROR: $e');
    }
  }

  Future<void> _refresh() async {
    await store.syncTransactions();
    await _loadDuplicates();
    if (!mounted) return;
    setState(() {});
  }

  // Branch ng naka-login na admin (galing sa server)
  String get _myBranch {
    for (final u in store.getUsers()) {
      if (u.id == store.currentUserId.toString() && u.branch.isNotEmpty) {
        return u.branch;
      }
    }
    return '';
  }

  String _branchOf(TransactionRecord t) =>
      t.branch.trim().isEmpty ? 'No Branch' : t.branch.trim();

  // ---------------------------------------------------------------
  // SAKLAW NG PANAHON
  // ---------------------------------------------------------------

  // key ng bucket ayon sa napiling Daily / Monthly / Yearly
  String _keyOf(String date) {
    if (date.length < 4) return '';
    if (overviewMode == 'Yearly') return date.substring(0, 4);
    if (overviewMode == 'Monthly') {
      return date.length >= 7 ? date.substring(0, 7) : '';
    }
    return date.length >= 10 ? date.substring(0, 10) : '';
  }

  // Mga bucket na ipapakita (pinakabago muna)
  List<String> _bucketKeys() {
    final now = DateTime.now();
    if (overviewMode == 'Daily') {
      return [
        for (var i = 0; i < 14; i++)
          dateKey(DateTime(now.year, now.month, now.day - i)),
      ];
    }
    if (overviewMode == 'Monthly') {
      return [
        for (var i = 0; i < 12; i++)
          () {
            final d = DateTime(now.year, now.month - i, 1);
            return '${d.year}-${d.month.toString().padLeft(2, '0')}';
          }(),
      ];
    }
    return [for (var i = 0; i < 5; i++) '${now.year - i}'];
  }

  // Mahabang pangalan ng bucket (hal. "Oct 25, 2026", "October 2026")
  String _bucketLabel(String k) {
    if (overviewMode == 'Yearly') return k;
    final mo = int.tryParse(k.length >= 7 ? k.substring(5, 7) : '') ?? 1;
    if (overviewMode == 'Monthly') {
      return '${_monthsShort[mo - 1]} ${k.substring(0, 4)}';
    }
    final day = int.tryParse(k.length >= 10 ? k.substring(8, 10) : '') ?? 0;
    final today = dateKey(DateTime.now());
    if (k == today) return 'Today, ${_monthsShort[mo - 1]} $day';
    return '${_monthsShort[mo - 1]} $day, ${k.substring(0, 4)}';
  }

  // Maikling label sa ilalim ng bawat bar
  String _barLabel(String k) {
    if (overviewMode == 'Yearly') return k;
    final mo = int.tryParse(k.length >= 7 ? k.substring(5, 7) : '') ?? 1;
    if (overviewMode == 'Monthly') return _monthsShort[mo - 1];
    return '${int.tryParse(k.length >= 10 ? k.substring(8, 10) : '') ?? 0}';
  }

  String get _rangeText => overviewMode == 'Daily'
      ? 'Last 14 days'
      : overviewMode == 'Monthly'
      ? 'Last 12 months'
      : 'Last 5 years';

  String get _compareText => overviewMode == 'Daily'
      ? 'vs yesterday'
      : overviewMode == 'Monthly'
      ? 'vs last month'
      : 'vs last year';

  String get _currentText => overviewMode == 'Daily'
      ? 'Today'
      : overviewMode == 'Monthly'
      ? 'This month'
      : 'This year';

  // Maikling halaga (1.2K, 3.4M)
  String _shortMoney(double v) {
    if (v >= 1000000) return '${(v / 1000000).toStringAsFixed(1)}M';
    if (v >= 1000) return '${(v / 1000).toStringAsFixed(1)}K';
    return v.toStringAsFixed(0);
  }

  // ---------------------------------------------------------------
  // MGA PIRASO NG UI
  // ---------------------------------------------------------------

  Widget _card({required Widget child, EdgeInsets? padding}) {
    return Container(
      width: double.infinity,
      padding: padding ?? const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: _line),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: .04),
            blurRadius: 24,
            offset: const Offset(0, 10),
          ),
        ],
      ),
      child: child,
    );
  }

  Widget _cardTitle(String title, {String? subtitle, Widget? trailing}) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: const TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.w800,
                  color: _ink,
                ),
              ),
              if (subtitle != null) ...[
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  style: const TextStyle(fontSize: 12.5, color: _sub),
                ),
              ],
            ],
          ),
        ),
        ?trailing,
      ],
    );
  }

  // Pagbabago (pataas = berde, pababa = pula)
  Widget _changeChip(double now, double before, {bool onDark = false}) {
    String text;
    IconData icon;
    Color fg;

    if (before <= 0 && now <= 0) {
      text = 'No change';
      icon = Icons.remove;
      fg = onDark ? Colors.white70 : _sub;
    } else if (before <= 0) {
      text = 'New';
      icon = Icons.trending_up;
      fg = onDark ? Colors.white : _green;
    } else {
      final pct = (now - before) / before * 100;
      final up = pct >= 0;
      text = '${up ? '+' : ''}${pct.toStringAsFixed(pct.abs() >= 10 ? 0 : 1)}%';
      icon = up ? Icons.trending_up : Icons.trending_down;
      fg = onDark ? Colors.white : (up ? _green : _red);
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: onDark
            ? Colors.white.withValues(alpha: .18)
            : fg.withValues(alpha: .10),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 15, color: fg),
          const SizedBox(width: 4),
          Text(
            text,
            style: TextStyle(
              color: fg,
              fontWeight: FontWeight.w800,
              fontSize: 12,
            ),
          ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------
  // 1. PILI NG SAKLAW
  // ---------------------------------------------------------------
  Widget _periodSelector() {
    return SizedBox(
      width: double.infinity,
      child: SegmentedButton<String>(
        showSelectedIcon: false,
        segments: const [
          ButtonSegment(value: 'Daily', label: Text('Daily')),
          ButtonSegment(value: 'Monthly', label: Text('Monthly')),
          ButtonSegment(value: 'Yearly', label: Text('Yearly')),
        ],
        selected: {overviewMode},
        onSelectionChanged: (s) => setState(() {
          overviewMode = s.first;
          _selectedBar = null;
        }),
      ),
    );
  }

  // ---------------------------------------------------------------
  // 2. HERO: TOTAL RECEIVED
  // ---------------------------------------------------------------
  Widget _heroCard({
    required double rangeTotal,
    required int rangeCount,
    required double currentTotal,
    required double previousTotal,
  }) {
    final scope = store.isOwner
        ? 'All branches'
        : (_myBranch.isEmpty ? 'Your branch' : _myBranch);

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(22, 20, 22, 20),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(24),
        gradient: const LinearGradient(
          colors: [Color(0xFF0874EE), Color(0xFF0B4FB8)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        boxShadow: [
          BoxShadow(
            color: _blue.withValues(alpha: .25),
            blurRadius: 26,
            offset: const Offset(0, 12),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(
                Icons.account_balance_wallet_outlined,
                color: Colors.white70,
                size: 18,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  'Total Received • $_rangeText',
                  style: const TextStyle(
                    color: Colors.white70,
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 4,
                ),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: .16),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(
                  scope,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 11,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(
              '₱${money(rangeTotal)}',
              style: const TextStyle(
                color: Colors.white,
                fontSize: 38,
                fontWeight: FontWeight.w800,
                letterSpacing: -0.5,
              ),
            ),
          ),
          const SizedBox(height: 4),
          Text(
            '$rangeCount receipt(s)',
            style: const TextStyle(color: Colors.white70, fontSize: 13),
          ),
          const SizedBox(height: 16),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: .10),
              borderRadius: BorderRadius.circular(16),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        _currentText,
                        style: const TextStyle(
                          color: Colors.white70,
                          fontSize: 12,
                        ),
                      ),
                      const SizedBox(height: 2),
                      FittedBox(
                        fit: BoxFit.scaleDown,
                        alignment: Alignment.centerLeft,
                        child: Text(
                          '₱${money(currentTotal)}',
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 18,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    _changeChip(currentTotal, previousTotal, onDark: true),
                    const SizedBox(height: 4),
                    Text(
                      _compareText,
                      style: const TextStyle(
                        color: Colors.white70,
                        fontSize: 11,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------
  // 3. KPI CARDS
  // ---------------------------------------------------------------
  Widget _kpiCard({
    required IconData icon,
    required Color color,
    required String label,
    required String value,
    String? note,
    VoidCallback? onTap,
  }) {
    return Material(
      color: Colors.white,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(18),
        side: const BorderSide(color: _line),
      ),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(18),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                padding: const EdgeInsets.all(7),
                decoration: BoxDecoration(
                  color: color.withValues(alpha: .10),
                  borderRadius: BorderRadius.circular(11),
                ),
                child: Icon(icon, size: 19, color: color),
              ),
              const SizedBox(height: 12),
              FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerLeft,
                child: Text(
                  value,
                  style: const TextStyle(
                    color: _ink,
                    fontSize: 20,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
              const SizedBox(height: 2),
              Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: Color(0xFF2B3F5C),
                  fontSize: 12.5,
                  fontWeight: FontWeight.w700,
                ),
              ),
              if (note != null) ...[
                const SizedBox(height: 2),
                Text(
                  note,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: _sub, fontSize: 11.5),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _kpiGrid(List<Widget> cards) {
    return LayoutBuilder(
      builder: (context, c) {
        final perRow = c.maxWidth >= 700 ? 4 : 2;
        const gap = 12.0;
        final w = (c.maxWidth - gap * (perRow - 1)) / perRow;
        return Wrap(
          spacing: gap,
          runSpacing: gap,
          children: [for (final k in cards) SizedBox(width: w, child: k)],
        );
      },
    );
  }

  // ---------------------------------------------------------------
  // 4. BAR CHART (pindutin ang bar)
  // ---------------------------------------------------------------
  Widget _chartCard(List<String> keys, Map<String, _Agg> byBucket) {
    double totalOf(String k) => byBucket[k]?.total ?? 0;
    final maxTotal = keys.fold<double>(
      0,
      (a, k) => totalOf(k) > a ? totalOf(k) : a,
    );
    final sel = (_selectedBar != null && keys.contains(_selectedBar))
        ? _selectedBar!
        : keys.first;
    final selAgg = byBucket[sel] ?? _Agg();
    const chartH = 150.0;

    return _card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _cardTitle(
            'Income',
            subtitle: '$_rangeText • tap a bar to see details',
          ),
          const SizedBox(height: 14),

          // Detalye ng napiling bar
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
              color: const Color(0xFFF2F7FF),
              borderRadius: BorderRadius.circular(14),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    _bucketLabel(sel),
                    style: const TextStyle(
                      color: Color(0xFF2B3F5C),
                      fontWeight: FontWeight.w700,
                      fontSize: 13,
                    ),
                  ),
                ),
                Text(
                  '₱${money(selAgg.total)}',
                  style: const TextStyle(
                    color: _ink,
                    fontWeight: FontWeight.w800,
                    fontSize: 15,
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  '${selAgg.count} rcpt',
                  style: const TextStyle(color: _sub, fontSize: 12),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),

          // Ang chart
          SizedBox(
            height: chartH + 26,
            child: Stack(
              children: [
                // Mga guhit sa likod
                for (final f in const [1.0, 0.5, 0.0])
                  Positioned(
                    left: 0,
                    right: 0,
                    top: (1 - f) * chartH,
                    child: Row(
                      children: [
                        Expanded(child: Container(height: 1, color: _line)),
                        SizedBox(
                          width: 40,
                          child: Text(
                            maxTotal <= 0 ? '' : _shortMoney(maxTotal * f),
                            textAlign: TextAlign.right,
                            style: const TextStyle(color: _sub, fontSize: 9.5),
                          ),
                        ),
                      ],
                    ),
                  ),
                // Mga bar (pinakaluma sa kaliwa, pinakabago sa kanan)
                Padding(
                  padding: const EdgeInsets.only(right: 44),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      for (final k in keys.reversed)
                        Expanded(
                          child: GestureDetector(
                            behavior: HitTestBehavior.opaque,
                            onTap: () => setState(() => _selectedBar = k),
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.end,
                              children: [
                                AnimatedContainer(
                                  duration: const Duration(milliseconds: 250),
                                  margin: const EdgeInsets.symmetric(
                                    horizontal: 3,
                                  ),
                                  height: maxTotal <= 0
                                      ? 3
                                      : (totalOf(k) / maxTotal * chartH).clamp(
                                          3.0,
                                          chartH,
                                        ),
                                  decoration: BoxDecoration(
                                    color: totalOf(k) <= 0
                                        ? const Color(0xFFDDE7F3)
                                        : (k == sel
                                              ? _blue
                                              : _blue.withValues(alpha: .35)),
                                    borderRadius: const BorderRadius.vertical(
                                      top: Radius.circular(6),
                                    ),
                                  ),
                                ),
                                const SizedBox(height: 6),
                                SizedBox(
                                  height: 20,
                                  child: FittedBox(
                                    fit: BoxFit.scaleDown,
                                    child: Text(
                                      _barLabel(k),
                                      style: TextStyle(
                                        color: k == sel ? _blue : _sub,
                                        fontSize: 10.5,
                                        fontWeight: k == sel
                                            ? FontWeight.w800
                                            : FontWeight.w500,
                                      ),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------
  // 5a. KADA BRANCH
  // ---------------------------------------------------------------
  Widget _branchCard(Map<String, _Agg> byBranch, double rangeTotal) {
    final names = store.isOwner
        ? <String>{..._branchNames, ...byBranch.keys}.toList()
        : <String>[_myBranch.isEmpty ? 'No Branch' : _myBranch];
    names.sort(
      (a, b) => (byBranch[b]?.total ?? 0).compareTo(byBranch[a]?.total ?? 0),
    );

    return _card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _cardTitle(
            store.isOwner ? 'By Branch' : 'Your Branch',
            subtitle: _rangeText,
          ),
          const SizedBox(height: 12),
          if (names.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 8),
              child: Text('No branches yet.', style: TextStyle(color: _sub)),
            ),
          for (final b in names)
            Builder(
              builder: (_) {
                final a = byBranch[b] ?? _Agg();
                final share = rangeTotal <= 0 ? 0.0 : a.total / rangeTotal;
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          const Icon(
                            Icons.store_outlined,
                            size: 17,
                            color: _blue,
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              b,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: _ink,
                                fontWeight: FontWeight.w800,
                                fontSize: 14,
                              ),
                            ),
                          ),
                          Text(
                            '₱${money(a.total)}',
                            style: const TextStyle(
                              color: _ink,
                              fontWeight: FontWeight.w800,
                              fontSize: 14,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 7),
                      ClipRRect(
                        borderRadius: BorderRadius.circular(10),
                        child: LinearProgressIndicator(
                          value: share.clamp(0.0, 1.0),
                          minHeight: 8,
                          backgroundColor: const Color(0xFFEAF1FA),
                          valueColor: const AlwaysStoppedAnimation(_blue),
                        ),
                      ),
                      const SizedBox(height: 5),
                      Text(
                        '${a.count} receipt(s) • '
                        '${(share * 100).toStringAsFixed(0)}% of total',
                        style: const TextStyle(color: _sub, fontSize: 11.5),
                      ),
                    ],
                  ),
                );
              },
            ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------
  // 5b. TOP SCANNERS
  // ---------------------------------------------------------------
  Widget _scannersCard(Map<String, _Agg> byScanner) {
    final names = byScanner.keys.toList()
      ..sort((a, b) => byScanner[b]!.total.compareTo(byScanner[a]!.total));
    final top = names.take(5).toList();
    final best = top.isEmpty ? 0.0 : byScanner[top.first]!.total;

    const medal = [Color(0xFFE6A700), Color(0xFF8F9BB3), Color(0xFFB0703C)];

    return _card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _cardTitle('Top Scanners', subtitle: '$_rangeText • by amount'),
          const SizedBox(height: 12),
          if (top.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 8),
              child: Text('No scans yet.', style: TextStyle(color: _sub)),
            ),
          for (var i = 0; i < top.length; i++)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 7),
              child: Row(
                children: [
                  CircleAvatar(
                    radius: 15,
                    backgroundColor: i < 3
                        ? medal[i].withValues(alpha: .15)
                        : const Color(0xFFF1F4F9),
                    child: Text(
                      '${i + 1}',
                      style: TextStyle(
                        color: i < 3 ? medal[i] : _sub,
                        fontWeight: FontWeight.w800,
                        fontSize: 13,
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                top[i],
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  color: _ink,
                                  fontWeight: FontWeight.w800,
                                  fontSize: 13.5,
                                ),
                              ),
                            ),
                            Text(
                              '₱${money(byScanner[top[i]]!.total)}',
                              style: const TextStyle(
                                color: _ink,
                                fontWeight: FontWeight.w800,
                                fontSize: 13.5,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 5),
                        ClipRRect(
                          borderRadius: BorderRadius.circular(10),
                          child: LinearProgressIndicator(
                            value: best <= 0
                                ? 0
                                : (byScanner[top[i]]!.total / best).clamp(
                                    0.0,
                                    1.0,
                                  ),
                            minHeight: 6,
                            backgroundColor: const Color(0xFFEAF1FA),
                            valueColor: const AlwaysStoppedAnimation(_green),
                          ),
                        ),
                        const SizedBox(height: 3),
                        Text(
                          '${byScanner[top[i]]!.count} receipt(s)',
                          style: const TextStyle(color: _sub, fontSize: 11.5),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------
  // 6a. DUPLICATE RECEIPTS
  //   Maikling card lang. Pindutin para makita ang buong listahan.
  // ---------------------------------------------------------------
  Map<String, List<Map<String, dynamic>>> _dupGroups() {
    final groups = <String, List<Map<String, dynamic>>>{};
    for (final r in _dupRows) {
      groups.putIfAbsent(r['reference'].toString(), () => []).add(r);
    }
    return groups;
  }

  Widget _duplicatesCard() {
    final groups = _dupGroups();
    final count = groups.length;
    final clear = count == 0;
    final color = clear ? _green : _red;

    return Material(
      color: Colors.white,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(22),
        side: const BorderSide(color: _line),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(22),
        onTap: clear ? null : _openDuplicates,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: color.withValues(alpha: .10),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Icon(
                  clear ? Icons.verified_outlined : Icons.content_copy_rounded,
                  color: color,
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      store.isAdmin && _myBranch.isNotEmpty
                          ? 'Duplicate Receipts • $_myBranch'
                          : 'Duplicate Receipts',
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w800,
                        color: _ink,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      clear
                          ? 'All clear, no receipt was saved twice'
                          : '${_dupRows.length} attempt(s) on $count receipt(s) • tap to view',
                      style: const TextStyle(fontSize: 12.5, color: _sub),
                    ),
                  ],
                ),
              ),
              if (!clear) ...[
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: _red.withValues(alpha: .10),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Text(
                    '$count',
                    style: const TextStyle(
                      color: _red,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
                const SizedBox(width: 4),
                const Icon(Icons.chevron_right_rounded, color: _sub),
              ],
            ],
          ),
        ),
      ),
    );
  }

  // Buong listahan ng duplicates (lalabas mula sa ibaba)
  void _openDuplicates() {
    final groups = _dupGroups();
    final refs = groups.keys.toList()
      ..sort((a, b) => groups[b]!.length.compareTo(groups[a]!.length));

    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: .6,
        minChildSize: .35,
        maxChildSize: .92,
        builder: (ctx, scroll) => Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 10),
              child: _cardTitle(
                'Duplicate Receipts',
                subtitle:
                    '${_dupRows.length} attempt(s) on ${refs.length} receipt(s)',
              ),
            ),
            Expanded(
              child: ListView.builder(
                controller: scroll,
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
                itemCount: refs.length,
                itemBuilder: (ctx, i) {
                  final ref = refs[i];
                  final rows = groups[ref]!;
                  final first = rows.first;
                  final amount = (first['amount'] is num)
                      ? (first['amount'] as num).toDouble()
                      : double.tryParse(first['amount'].toString()) ?? 0;
                  final scanners = {
                    for (final x in rows)
                      if (x['scanner'].toString().isNotEmpty)
                        x['scanner'].toString(),
                  }.join(', ');

                  return Container(
                    margin: const EdgeInsets.only(bottom: 10),
                    decoration: BoxDecoration(
                      color: const Color(0xFFFFF8F8),
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(color: const Color(0xFFF6D6D6)),
                    ),
                    child: ExpansionTile(
                      shape: const Border(),
                      collapsedShape: const Border(),
                      title: Text(
                        ref,
                        style: const TextStyle(
                          color: _ink,
                          fontWeight: FontWeight.w800,
                          fontSize: 14,
                        ),
                      ),
                      subtitle: Text(
                        '${first['customer']} • ₱${money(amount)}'
                        '${scanners.isEmpty ? '' : '\nScanned by: $scanners'}',
                        style: const TextStyle(
                          color: Color(0xFF2B3F5C),
                          fontSize: 12,
                        ),
                      ),
                      trailing: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 4,
                        ),
                        decoration: BoxDecoration(
                          color: const Color(0xFFFFE9E9),
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: Text(
                          '${rows.length}x',
                          style: const TextStyle(
                            color: _red,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ),
                      children: [
                        for (final r in rows)
                          ListTile(
                            dense: true,
                            leading: const Icon(
                              Icons.content_copy,
                              size: 18,
                              color: _red,
                            ),
                            title: Text(
                              '${r['scanner'] == '' ? 'Unknown' : r['scanner']}'
                              '${(r['branch'] ?? '').toString().isEmpty ? '' : ' • ${r['branch']}'}',
                              style: const TextStyle(fontSize: 13),
                            ),
                            subtitle: Text(r['createdAt'].toString()),
                          ),
                      ],
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ---------------------------------------------------------------
  // 6b. DAILY TRANSACTION SUMMARY
  // ---------------------------------------------------------------

  // Igrupo ang mga transaction ng isang araw ayon sa branch kung saan na-scan
  List<Widget> _branchSections(
    BuildContext context,
    List<TransactionRecord> dayList,
  ) {
    final byBranch = <String, List<TransactionRecord>>{};
    for (final t in dayList) {
      byBranch.putIfAbsent(_branchOf(t), () => []).add(t);
    }

    final names = store.isOwner
        ? <String>[
            ..._branchNames,
            ...byBranch.keys.where(
              (b) => !_branchNames.contains(b) && b != 'No Branch',
            ),
            if (byBranch.containsKey('No Branch')) 'No Branch',
          ]
        : <String>[_myBranch.isEmpty ? 'No Branch' : _myBranch];

    return names.map((b) {
      final items = byBranch[b] ?? <TransactionRecord>[];
      final sum = items.fold<double>(0, (s, t) => s + t.amount);

      return Container(
        margin: const EdgeInsets.only(bottom: 8),
        decoration: BoxDecoration(
          color: const Color(0xFFF4F8FC),
          borderRadius: BorderRadius.circular(14),
        ),
        child: ExpansionTile(
          shape: const Border(),
          collapsedShape: const Border(),
          tilePadding: const EdgeInsets.symmetric(horizontal: 12),
          childrenPadding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
          leading: Icon(
            b == 'No Branch' ? Icons.help_outline : Icons.store_outlined,
            color: _blue,
          ),
          title: Text(
            b,
            style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 14),
          ),
          subtitle: Text(
            '${items.length} transaction(s)',
            style: const TextStyle(fontSize: 12),
          ),
          trailing: Text(
            '₱${money(sum)}',
            style: const TextStyle(fontWeight: FontWeight.w800, color: _green),
          ),
          children: items.isEmpty
              ? const [
                  Padding(
                    padding: EdgeInsets.all(12),
                    child: Text(
                      'No scans from this branch.',
                      style: TextStyle(color: Color(0xFF71819A), fontSize: 12),
                    ),
                  ),
                ]
              : items
                    .map(
                      (t) => GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: () => showTransactionDetail(
                          context,
                          store.currentUserId,
                          t,
                        ),
                        child: TransactionTile(t, showScanner: true),
                      ),
                    )
                    .toList(),
        ),
      );
    }).toList();
  }

  Widget _dailySummaryCard(List<TransactionRecord> txs) {
    final branchChoices = <String>[
      'All',
      if (store.isOwner) ..._branchNames,
      if (store.isOwner) ...{
        for (final t in txs)
          if (!_branchNames.contains(_branchOf(t))) _branchOf(t),
      },
    ];
    if (!branchChoices.contains(selectedBranch)) selectedBranch = 'All';

    final summaryTxs = selectedBranch == 'All'
        ? txs
        : txs.where((t) => _branchOf(t) == selectedBranch).toList();
    final todayKey = dateKey(DateTime.now());
    final byDate = <String, List<TransactionRecord>>{};
    for (final t in summaryTxs) {
      final key = t.scanDate.isEmpty ? 'No date' : t.scanDate;
      byDate.putIfAbsent(key, () => []).add(t);
    }
    final summaryDates = byDate.keys.toList()..sort((a, b) => b.compareTo(a));

    return _card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _cardTitle(
            'Daily Transaction Summary',
            subtitle: 'Every receipt, grouped by the day it was scanned',
          ),
          const SizedBox(height: 12),
          if (store.isOwner)
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  for (final b in branchChoices)
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: ChoiceChip(
                        avatar: Icon(
                          b == 'All'
                              ? Icons.apps_rounded
                              : Icons.store_outlined,
                          size: 16,
                        ),
                        label: Text(b),
                        selected: selectedBranch == b,
                        showCheckmark: false,
                        onSelected: (_) => setState(() => selectedBranch = b),
                      ),
                    ),
                ],
              ),
            ),
          if (selectedBranch != 'All') ...[
            const SizedBox(height: 10),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: const Color(0xFFEAF5FF),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text(
                '$selectedBranch: ${summaryTxs.length} transaction(s) • '
                '₱${money(summaryTxs.fold<double>(0, (s, t) => s + t.amount))}',
                style: const TextStyle(
                  fontWeight: FontWeight.w800,
                  color: Color(0xFF0869D8),
                ),
              ),
            ),
          ],
          const SizedBox(height: 8),
          if (summaryDates.isEmpty)
            EmptyState(
              text: selectedBranch == 'All'
                  ? 'No transactions yet.'
                  : 'No scans yet for $selectedBranch.',
            )
          else
            for (final day in summaryDates)
              Builder(
                builder: (context) {
                  final list = byDate[day]!;
                  final dayTotal = list.fold<double>(0, (s, t) => s + t.amount);
                  final isToday = day == todayKey;

                  return ExpansionTile(
                    shape: const Border(),
                    collapsedShape: const Border(),
                    tilePadding: EdgeInsets.zero,
                    initiallyExpanded: isToday,
                    leading: Container(
                      width: 40,
                      height: 40,
                      decoration: BoxDecoration(
                        color: isToday ? _blue : const Color(0xFFF1F4F9),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Icon(
                        Icons.calendar_today_outlined,
                        size: 18,
                        color: isToday ? Colors.white : _sub,
                      ),
                    ),
                    title: Text(
                      isToday ? '$day (Today)' : day,
                      style: const TextStyle(fontWeight: FontWeight.w800),
                    ),
                    subtitle: Text(
                      '${list.length} transaction(s)',
                      style: const TextStyle(fontSize: 12),
                    ),
                    trailing: Text(
                      '₱${money(dayTotal)}',
                      style: const TextStyle(
                        fontWeight: FontWeight.w800,
                        color: _green,
                      ),
                    ),
                    children: selectedBranch == 'All'
                        ? _branchSections(context, list)
                        : list
                              .map(
                                (t) => GestureDetector(
                                  behavior: HitTestBehavior.opaque,
                                  onTap: () => showTransactionDetail(
                                    context,
                                    store.currentUserId,
                                    t,
                                  ),
                                  child: TransactionTile(t, showScanner: true),
                                ),
                              )
                              .toList(),
                  );
                },
              ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------
  // BUILD
  // ---------------------------------------------------------------
  @override
  Widget build(BuildContext context) {
    if (!store.canSeeReceipts) {
      return const PageFrame(
        title: 'Reports',
        subtitle: 'Transaction and receipt summary',
        child: Center(child: Text('Only the Owner or Admin can view reports.')),
      );
    }

    final txs = store.getTransactions();
    final keys = _bucketKeys();
    final keySet = keys.toSet();

    // Mga resibo sa napiling saklaw
    final rangeTxs = <TransactionRecord>[];
    final byBucket = <String, _Agg>{};
    final byBranch = <String, _Agg>{};
    final byScanner = <String, _Agg>{};

    for (final t in txs) {
      final k = _keyOf(t.scanDate);
      if (!keySet.contains(k)) continue;
      rangeTxs.add(t);
      byBucket.putIfAbsent(k, () => _Agg()).add(t.amount);
      byBranch.putIfAbsent(_branchOf(t), () => _Agg()).add(t.amount);
      final who = t.scannedBy.trim().isEmpty ? 'Unknown' : t.scannedBy.trim();
      byScanner.putIfAbsent(who, () => _Agg()).add(t.amount);
    }

    final rangeTotal = rangeTxs.fold<double>(0, (s, t) => s + t.amount);
    final rangeCount = rangeTxs.length;
    final avg = rangeCount == 0 ? 0.0 : rangeTotal / rangeCount;
    final current = byBucket[keys[0]]?.total ?? 0;
    final previous = byBucket[keys[1]]?.total ?? 0;

    // Pinakamataas na araw/buwan/taon
    String? bestKey;
    for (final k in keys) {
      final v = byBucket[k]?.total ?? 0;
      if (v > 0 && (bestKey == null || v > (byBucket[bestKey]?.total ?? 0))) {
        bestKey = k;
      }
    }

    // Pinakamalaking isang resibo sa saklaw
    final bestBucket = bestKey;

    TransactionRecord? biggest;
    for (final t in rangeTxs) {
      if (biggest == null || t.amount > biggest.amount) biggest = t;
    }

    // Duplicates sa saklaw
    final dupInRange = _dupRows.where((r) {
      final c = r['createdAt']?.toString() ?? '';
      return keySet.contains(_keyOf(c.length >= 10 ? c.substring(0, 10) : c));
    }).length;

    return PageFrame(
      title: 'Reports',
      subtitle: 'Transaction and receipt summary',
      child: RefreshIndicator(
        onRefresh: _refresh,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 40),
          children: [
            Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 900),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _periodSelector(),
                    const SizedBox(height: 16),
                    _heroCard(
                      rangeTotal: rangeTotal,
                      rangeCount: rangeCount,
                      currentTotal: current,
                      previousTotal: previous,
                    ),
                    const SizedBox(height: 14),
                    _kpiGrid([
                      _kpiCard(
                        icon: Icons.receipt_long_outlined,
                        color: _blue,
                        label: 'Receipts',
                        value: '$rangeCount',
                        note: _rangeText,
                      ),
                      _kpiCard(
                        icon: Icons.functions_rounded,
                        color: const Color(0xFF7047C8),
                        label: 'Average per receipt',
                        value: '₱${money(avg)}',
                        note: 'Total ÷ receipts',
                      ),
                      _kpiCard(
                        icon: Icons.emoji_events_outlined,
                        color: const Color(0xFFE6A700),
                        label: overviewMode == 'Daily'
                            ? 'Best day'
                            : overviewMode == 'Monthly'
                            ? 'Best month'
                            : 'Best year',
                        value: bestBucket == null
                            ? '—'
                            : '₱${_shortMoney(byBucket[bestBucket]!.total)}',
                        note: bestBucket == null
                            ? 'No scans yet'
                            : _bucketLabel(bestBucket),
                        onTap: bestBucket == null
                            ? null
                            : () => setState(() => _selectedBar = bestBucket),
                      ),
                      _kpiCard(
                        icon: Icons.content_copy_rounded,
                        color: dupInRange > 0 ? _red : _green,
                        label: 'Duplicate attempts',
                        value: '$dupInRange',
                        note: biggest == null
                            ? _rangeText
                            : 'Biggest: ₱${money(biggest.amount)}',
                      ),
                    ]),
                    const SizedBox(height: 14),
                    _chartCard(keys, byBucket),
                    const SizedBox(height: 14),
                    LayoutBuilder(
                      builder: (context, c) {
                        final wide = c.maxWidth >= 700;
                        final branch = _branchCard(byBranch, rangeTotal);
                        final scanners = _scannersCard(byScanner);
                        if (!wide) {
                          return Column(
                            children: [
                              branch,
                              const SizedBox(height: 14),
                              scanners,
                            ],
                          );
                        }
                        return Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Expanded(child: branch),
                            const SizedBox(width: 14),
                            Expanded(child: scanners),
                          ],
                        );
                      },
                    ),
                    const SizedBox(height: 14),
                    _duplicatesCard(),
                    const SizedBox(height: 14),
                    _dailySummaryCard(txs),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// -----------------------------------------------------------------------------
// LOGS
// -----------------------------------------------------------------------------

class LogsPage extends StatefulWidget {
  final ReceiScanStore store;
  const LogsPage({super.key, required this.store});

  @override
  State<LogsPage> createState() => _LogsPageState();
}

class _LogsPageState extends State<LogsPage> {
  final search = TextEditingController();
  String category = 'All';
  String branchFilter = 'All';

  static const _categories = [
    'All',
    'Account',
    'Receipts',
    'Duplicate',
    'Other',
  ];

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  @override
  void dispose() {
    search.dispose();
    super.dispose();
  }

  Future<void> _refresh() async {
    try {
      await widget.store.refreshLogs();
    } catch (e) {
      debugPrint('LOGS REFRESH ERROR: $e');
    }
    if (!mounted) return;
    setState(() {});
  }

  DateTime? _parse(dynamic v) => DateTime.tryParse(v?.toString() ?? '');

  String _dayLabel(DateTime? d) {
    if (d == null) return 'Unknown date';
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final day = DateTime(d.year, d.month, d.day);
    if (day == today) return 'Today';
    if (day == today.subtract(const Duration(days: 1))) return 'Yesterday';
    return dateKey(d);
  }

  Widget _row(Map<String, dynamic> l) {
    final d = _parse(l['created']);
    return _LogRow(
      action: l['action']?.toString() ?? 'Activity',
      description: l['description']?.toString() ?? '',
      user: l['user']?.toString() ?? '',
      role: l['role']?.toString() ?? '',
      branch: l['branch']?.toString() ?? '',
      time: d == null ? '' : _logTime12(d),
    );
  }

  @override
  Widget build(BuildContext context) {
    final all = widget.store.getLogs();
    final q = search.text.trim().toLowerCase();
    final todayKey = dateKey(DateTime.now());

    final filtered = all.where((l) {
      final action = l['action']?.toString() ?? '';
      final desc = l['description']?.toString() ?? '';
      final user = l['user']?.toString() ?? '';
      final branch = l['branch']?.toString() ?? '';
      final matchesCat =
          category == 'All' || _logCategoryOf(action) == category;
      final matchesBranch = branchFilter == 'All' || branch == branchFilter;
      final matchesSearch =
          q.isEmpty ||
          action.toLowerCase().contains(q) ||
          desc.toLowerCase().contains(q) ||
          branch.toLowerCase().contains(q) ||
          user.toLowerCase().contains(q);
      return matchesCat && matchesBranch && matchesSearch;
    }).toList();

    final branchOptions = <String>[
      'All',
      ...{
        for (final l in all)
          if ((l['branch']?.toString() ?? '').isNotEmpty)
            l['branch'].toString(),
      },
    ];

    // Igrupo kada araw (nakaayos na ang listahan: pinakabago muna)
    final groups = <String, List<Map<String, dynamic>>>{};
    for (final l in filtered) {
      final d = _parse(l['created']);
      final key = d == null ? 'unknown' : dateKey(d);
      groups.putIfAbsent(key, () => []).add(l);
    }

    final todayCount = all.where((l) {
      final d = _parse(l['created']);
      return d != null && dateKey(d) == todayKey;
    }).length;
    final receiptCount = all
        .where(
          (l) => _logCategoryOf(l['action']?.toString() ?? '') == 'Receipts',
        )
        .length;

    return PageFrame(
      title: 'Activity Logs',
      subtitle: widget.store.isAdmin
          ? 'Activity in your branch only'
          : 'System activity and history',
      child: RefreshIndicator(
        onRefresh: _refresh,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 40),
          children: [
            Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 900),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // ---------- BILANG ----------
                    Row(
                      children: [
                        Expanded(
                          child: _LogStat(
                            label: 'Total',
                            value: '${all.length}',
                            fg: const Color(0xFF0869D8),
                            bg: const Color(0xFFE7F4FF),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: _LogStat(
                            label: 'Today',
                            value: '$todayCount',
                            fg: const Color(0xFF0869D8),
                            bg: const Color(0xFFE7F4FF),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: _LogStat(
                            label: 'Receipts',
                            value: '$receiptCount',
                            fg: const Color(0xFF0869D8),
                            bg: const Color(0xFFE7F4FF),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 14),

                    // ---------- SEARCH ----------
                    TextField(
                      controller: search,
                      onChanged: (_) => setState(() {}),
                      decoration: InputDecoration(
                        hintText: 'Search activity, name, details...',
                        prefixIcon: const Icon(Icons.search),
                        isDense: true,
                        suffixIcon: search.text.isEmpty
                            ? null
                            : IconButton(
                                icon: const Icon(Icons.close),
                                onPressed: () {
                                  search.clear();
                                  setState(() {});
                                },
                              ),
                      ),
                    ),
                    const SizedBox(height: 10),

                    // ---------- FILTER ----------
                    SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: Row(
                        children: [
                          for (final c in _categories)
                            Padding(
                              padding: const EdgeInsets.only(right: 8),
                              child: ChoiceChip(
                                label: Text(c),
                                selected: category == c,
                                showCheckmark: false,
                                onSelected: (_) => setState(() => category = c),
                              ),
                            ),
                        ],
                      ),
                    ),
                    if (branchOptions.length > 1) ...[
                      const SizedBox(height: 8),
                      SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        child: Row(
                          children: [
                            for (final b in branchOptions)
                              Padding(
                                padding: const EdgeInsets.only(right: 8),
                                child: ChoiceChip(
                                  avatar: const Icon(
                                    Icons.store_outlined,
                                    size: 16,
                                  ),
                                  label: Text(b),
                                  selected: branchFilter == b,
                                  showCheckmark: false,
                                  onSelected: (_) =>
                                      setState(() => branchFilter = b),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ],
                    const SizedBox(height: 14),

                    // ---------- LISTAHAN ----------
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(22),
                        border: Border.all(color: const Color(0xFFE5EBF4)),
                      ),
                      child: filtered.isEmpty
                          ? EmptyState(
                              text: all.isEmpty
                                  ? 'No activity logs yet.'
                                  : 'No matching activity.',
                            )
                          : Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                for (final key in groups.keys) ...[
                                  Padding(
                                    padding: const EdgeInsets.only(
                                      top: 14,
                                      bottom: 4,
                                    ),
                                    child: Row(
                                      children: [
                                        Text(
                                          _dayLabel(
                                            _parse(
                                              groups[key]!.first['created'],
                                            ),
                                          ),
                                          style: const TextStyle(
                                            fontWeight: FontWeight.w800,
                                            fontSize: 13,
                                            color: Color(0xFF6E86A4),
                                          ),
                                        ),
                                        const SizedBox(width: 8),
                                        Text(
                                          '${groups[key]!.length}',
                                          style: const TextStyle(
                                            fontWeight: FontWeight.w700,
                                            fontSize: 12,
                                            color: Color(0xFF9AAEC6),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                  for (
                                    var i = 0;
                                    i < groups[key]!.length;
                                    i++
                                  ) ...[
                                    if (i > 0)
                                      const Divider(
                                        height: 1,
                                        color: Color(0xFFEFF3F8),
                                      ),
                                    _row(groups[key]![i]),
                                  ],
                                ],
                              ],
                            ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// -----------------------------------------------------------------------------
// MGA PIRASO NG ACTIVITY LOGS UI
// -----------------------------------------------------------------------------

class _LogStyle {
  final IconData icon;
  final Color fg;
  final Color bg;
  const _LogStyle(this.icon, this.fg, this.bg);
}

_LogStyle _logStyleFor(String action) {
  final a = action.toLowerCase();
  if (a.contains('logout')) {
    return const _LogStyle(
      Icons.logout_rounded,
      Color(0xFF71819A),
      Color(0xFFF1F4F9),
    );
  }
  if (a.contains('login')) {
    return const _LogStyle(
      Icons.login_rounded,
      Color(0xFF0869D8),
      Color(0xFFE7F4FF),
    );
  }
  if (a.contains('duplicate')) {
    return const _LogStyle(
      Icons.content_copy_rounded,
      Color(0xFFC62828),
      Color(0xFFFFE9E9),
    );
  }
  if (a.contains('receipt')) {
    return const _LogStyle(
      Icons.receipt_long_rounded,
      Color(0xFF07976F),
      Color(0xFFE2FAF2),
    );
  }
  if (a.contains('clock in')) {
    return const _LogStyle(
      Icons.access_time_filled,
      Color(0xFF07976F),
      Color(0xFFE2FAF2),
    );
  }
  if (a.contains('clock out')) {
    return const _LogStyle(
      Icons.timer_outlined,
      Color(0xFFB76A00),
      Color(0xFFFFF0DC),
    );
  }
  if (a.contains('attendance')) {
    return const _LogStyle(
      Icons.edit_calendar_outlined,
      Color(0xFF7047C8),
      Color(0xFFF0EAFF),
    );
  }
  return const _LogStyle(
    Icons.history_rounded,
    Color(0xFF0869D8),
    Color(0xFFE7F4FF),
  );
}

String _logCategoryOf(String action) {
  final a = action.toLowerCase();
  if (a.contains('login') || a.contains('logout')) return 'Account';
  if (a.contains('duplicate')) return 'Duplicate';
  if (a.contains('receipt')) return 'Receipts';
  return 'Other';
}

String _logTime12(DateTime d) {
  final h = d.hour == 0 ? 12 : (d.hour > 12 ? d.hour - 12 : d.hour);
  final ap = d.hour >= 12 ? 'PM' : 'AM';
  return '$h:${d.minute.toString().padLeft(2, '0')} $ap';
}

class _LogRow extends StatelessWidget {
  final String action;
  final String description;
  final String user;
  final String role;
  final String branch;
  final String time;

  const _LogRow({
    required this.action,
    required this.description,
    required this.user,
    this.role = '',
    this.branch = '',
    required this.time,
  });

  @override
  Widget build(BuildContext context) {
    final s = _logStyleFor(action);

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 42,
            height: 42,
            decoration: BoxDecoration(
              color: s.bg,
              borderRadius: BorderRadius.circular(13),
            ),
            child: Icon(s.icon, color: s.fg, size: 22),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        action,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontWeight: FontWeight.w800,
                          fontSize: 14.5,
                          color: Color(0xFF12233F),
                        ),
                      ),
                    ),
                    if (time.isNotEmpty)
                      Text(
                        time,
                        style: const TextStyle(
                          fontSize: 12,
                          color: Color(0xFF9AAEC6),
                        ),
                      ),
                  ],
                ),
                if (description.isNotEmpty) ...[
                  const SizedBox(height: 3),
                  Text(
                    description,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 12.5,
                      color: Color(0xFF506A85),
                    ),
                  ),
                ],
                if (user.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      const Icon(
                        Icons.person_outline,
                        size: 13,
                        color: Color(0xFF9AAEC6),
                      ),
                      const SizedBox(width: 4),
                      Flexible(
                        child: Text(
                          [
                            user,
                            if (role.isNotEmpty) formatRole(role),
                            if (branch.isNotEmpty) branch,
                          ].join(' • '),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 11.5,
                            color: Color(0xFF9AAEC6),
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _LogStat extends StatelessWidget {
  final String label;
  final String value;
  final Color fg;
  final Color bg;

  const _LogStat({
    required this.label,
    required this.value,
    required this.fg,
    required this.bg,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(
              value,
              style: TextStyle(
                color: fg,
                fontSize: 22,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
          const SizedBox(height: 2),
          Text(label, style: TextStyle(color: fg, fontSize: 12)),
        ],
      ),
    );
  }
}

// -----------------------------------------------------------------------------
// PROFILE
// -----------------------------------------------------------------------------

class ProfilePage extends StatefulWidget {
  final ReceiScanStore store;
  final UserAccount user;
  final VoidCallback onLogout;

  const ProfilePage({
    super.key,
    required this.store,
    required this.user,
    required this.onLogout,
  });

  @override
  State<ProfilePage> createState() => _ProfilePageState();
}

class _ProfilePageState extends State<ProfilePage> {
  // Pinakahuling request ng staff na lumipat ng branch (kung meron)
  Map<String, dynamic>? myRequest;

  @override
  void initState() {
    super.initState();
    _loadMyRequest();
  }

  String _currentBranch() {
    for (final u in widget.store.getUsers()) {
      if (u.id == widget.user.id && u.branch.isNotEmpty) return u.branch;
    }
    return widget.user.branch;
  }

  Future<void> _loadMyRequest() async {
    if (isManagerUser(widget.user)) return;
    try {
      final res = await ApiService.getMyBranchRequest(
        widget.store.currentUserId,
      );
      // Para makita agad ang bagong branch kapag na-approve na
      await widget.store.refreshUsers();
      if (!mounted) return;
      setState(() {
        myRequest = res['request'] is Map
            ? Map<String, dynamic>.from(res['request'] as Map)
            : null;
      });
    } catch (e) {
      debugPrint('MY BRANCH REQUEST ERROR: $e');
    }
  }

  String _branchSubtitle() {
    final current = _currentBranch();
    final r = myRequest;
    final status = r?['status']?.toString() ?? '';
    final to = r?['toBranch']?.toString() ?? '';

    if (status == 'pending') {
      return 'Waiting for approval to move to $to';
    }
    if (status == 'rejected') {
      return 'Your last request to $to was rejected. Current: $current';
    }
    return current.isEmpty ? 'No branch yet' : 'Current branch: $current';
  }

  Future<void> changeBranch() async {
    final current = _currentBranch();

    // Wala pang branch: pumili gamit ang password ng branch
    if (current.isEmpty) {
      final picked = await showDialog<String>(
        context: context,
        barrierDismissible: false,
        builder: (_) => BranchPickDialog(userId: widget.store.currentUserId),
      );
      if (picked != null) await _loadMyRequest();
      if (mounted) setState(() {});
      return;
    }

    final status = myRequest?['status']?.toString() ?? '';

    await showDialog<bool>(
      context: context,
      builder: (_) => ChangeBranchDialog(
        store: widget.store,
        user: widget.user,
        currentBranch: current,
        pending: status == 'pending' ? myRequest : null,
      ),
    );

    await _loadMyRequest();
    if (mounted) setState(() {});
  }

  Future<void> changePassword() async {
    final current = TextEditingController();
    final next = TextEditingController();
    final confirm = TextEditingController();

    final result = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Change Password'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: current,
                obscureText: true,
                decoration: const InputDecoration(
                  labelText: 'Current Password',
                ),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: next,
                obscureText: true,
                decoration: const InputDecoration(labelText: 'New Password'),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: confirm,
                obscureText: true,
                decoration: const InputDecoration(
                  labelText: 'Confirm New Password',
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Save'),
          ),
        ],
      ),
    );

    if (result != true) return;
    if (!mounted) return;

    if (next.text.length < 6 || next.text != confirm.text) {
      snack(context, 'Check the new password fields.');
      return;
    }

    try {
      final res = await ApiService.changePassword(
        userId: widget.store.currentUserId,
        currentPassword: current.text,
        newPassword: next.text,
      );

      if (!mounted) return;

      if (res['success'] != true) {
        snack(
          context,
          res['message']?.toString() ?? 'Unable to change the password.',
        );
        return;
      }

      widget.user.password = next.text;
      snack(context, 'Password changed successfully.');
      setState(() {});
    } catch (e) {
      if (!mounted) return;
      snack(context, 'Unable to reach the server.');
    }
  }

  Future<void> pickAvatar(ImageSource source) async {
    try {
      final x = await ImagePicker().pickImage(
        source: source,
        maxWidth: 512,
        maxHeight: 512,
        imageQuality: 80,
        preferredCameraDevice: CameraDevice.front,
      );
      if (x == null) return;

      final bytes = await x.readAsBytes();
      await widget.store.saveAvatar(widget.user.email, bytes);

      if (!mounted) return;
      setState(() {});
      snack(context, 'Profile photo updated.');
    } catch (e) {
      if (!mounted) return;
      snack(context, 'Unable to update photo: $e');
    }
  }

  Future<void> removeAvatar() async {
    await widget.store.removeAvatar(widget.user.email);
    if (!mounted) return;
    setState(() {});
    snack(context, 'Profile photo removed.');
  }

  void showAvatarOptions() {
    final hasPhoto = widget.store.getAvatar(widget.user.email) != null;

    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.camera_alt_outlined),
              title: const Text('Take Photo'),
              onTap: () {
                Navigator.pop(sheetContext);
                pickAvatar(ImageSource.camera);
              },
            ),
            ListTile(
              leading: const Icon(Icons.photo_library_outlined),
              title: const Text('Choose from Gallery'),
              onTap: () {
                Navigator.pop(sheetContext);
                pickAvatar(ImageSource.gallery);
              },
            ),
            if (hasPhoto)
              ListTile(
                leading: const Icon(Icons.delete_outline, color: Colors.red),
                title: const Text('Remove Photo'),
                onTap: () {
                  Navigator.pop(sheetContext);
                  removeAvatar();
                },
              ),
          ],
        ),
      ),
    );
  }

  // I-upload sa database ang mga lumang resibo at attendance na naka-save sa phone
  Future<void> uploadPhoneData() async {
    final oldTx = widget.store.localOldTransactions();
    final oldAtt = widget.store.localOldAttendance();

    if (oldTx.isEmpty && oldAtt.isEmpty) {
      snack(context, 'No old data on this phone to upload.');
      return;
    }

    final ok = await confirmDialog(
      context,
      'Upload Phone Data',
      'Upload ${oldTx.length} receipt(s) and ${oldAtt.length} attendance '
          'record(s) saved on this phone to the server?',
    );
    if (!ok) return;

    var sent = 0;
    var skipped = 0;
    var failed = 0;

    try {
      for (final t in oldTx) {
        final res = await ApiService.addTransaction(
          userId: widget.store.currentUserId,
          customerName: t.accountName.isEmpty ? 'Unknown' : t.accountName,
          dateTime: toSqlDateTime(t.date, t.time),
          amount: t.amount,
          referenceNo: t.reference,
          status: t.status,
          receiptType: t.receiptType,
          rawText: t.rawText,
          senderNumber: t.senderNumber,
        );

        if (res['success'] == true) {
          sent++;
        } else if ((res['message']?.toString() ?? '').contains(
          'already exists',
        )) {
          skipped++;
        } else {
          failed++;
        }
      }

      for (final a in oldAtt) {
        final res = await ApiService.saveAttendance(
          userId: widget.store.currentUserId,
          email: a.email,
          date: a.date,
          status: a.status,
          clockIn: a.clockIn,
          clockOut: a.clockOut,
          lateMinutes: a.lateMinutes,
          overtimeMinutes: a.overtimeMinutes,
          remarks: a.remarks,
        );
        if (res['success'] == true) {
          sent++;
        } else {
          failed++;
        }
      }
    } catch (e) {
      if (!mounted) return;
      snack(context, 'Unable to reach the server. Upload stopped.');
      return;
    }

    if (failed == 0) {
      await widget.store.clearOldLocalData();
    }

    await widget.store.refreshAll();
    if (!mounted) return;
    setState(() {});

    snack(
      context,
      failed == 0
          ? 'Uploaded $sent item(s). Skipped $skipped duplicate(s).'
          : 'Uploaded $sent, skipped $skipped, failed $failed. Old data was kept.',
    );
  }

  Future<void> logout() async {
    final ok = await confirmDialog(
      context,
      'Log Out',
      'Are you sure you want to log out?',
    );
    if (!ok) return;

    await widget.store.addLog(
      'Logout',
      '${widget.user.name} logged out.',
      widget.user.name,
    );
    widget.onLogout();
  }

  @override
  Widget build(BuildContext context) {
    return PageFrame(
      title: 'Profile',
      subtitle: 'Account information and security',
      child: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          SectionCard(
            title: 'Account',
            child: Column(
              children: [
                Builder(
                  builder: (_) {
                    final avatar = widget.store.getAvatar(widget.user.email);
                    final initial = widget.user.name.isEmpty
                        ? '?'
                        : widget.user.name.substring(0, 1);

                    return GestureDetector(
                      onTap: showAvatarOptions,
                      child: Stack(
                        children: [
                          CircleAvatar(
                            radius: 48,
                            backgroundColor: const Color(0xFFEAF5FF),
                            backgroundImage: avatar == null
                                ? null
                                : MemoryImage(avatar),
                            child: avatar == null
                                ? Text(
                                    initial,
                                    style: const TextStyle(
                                      fontSize: 34,
                                      fontWeight: FontWeight.bold,
                                      color: Color(0xFF0869EE),
                                    ),
                                  )
                                : null,
                          ),
                          Positioned(
                            right: 0,
                            bottom: 0,
                            child: Container(
                              padding: const EdgeInsets.all(6),
                              decoration: const BoxDecoration(
                                color: Color(0xFF0869EE),
                                shape: BoxShape.circle,
                              ),
                              child: const Icon(
                                Icons.camera_alt,
                                color: Colors.white,
                                size: 16,
                              ),
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                ),
                const SizedBox(height: 12),
                Text(
                  widget.user.name,
                  style: const TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                Text(widget.user.email),
                if (isOwnerUser(widget.user) &&
                    widget.user.ownerCode.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: InkWell(
                      onTap: () {
                        Clipboard.setData(
                          ClipboardData(text: widget.user.ownerCode),
                        );
                        snack(context, 'Owner ID copied.');
                      },
                      child: Text(
                        'Owner ID: ${widget.user.ownerCode}  (tap to copy)',
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),
                    ),
                  ),
                const SizedBox(height: 8),
                Chip(label: Text(formatRole(widget.user.role))),
                const Divider(height: 30),
                const ListTile(
                  leading: Icon(Icons.dialpad),
                  title: Text('PIN'),
                  subtitle: Text('Saved to your account - cannot be changed'),
                ),
                if (widget.store.localOldTransactions().isNotEmpty ||
                    widget.store.localOldAttendance().isNotEmpty)
                  ListTile(
                    leading: const Icon(Icons.cloud_upload_outlined),
                    title: const Text('Upload Phone Data to Server'),
                    subtitle: const Text(
                      'Move old receipts and attendance saved on this phone',
                    ),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: uploadPhoneData,
                  ),
                // Admin: branch niya (ang Owner lang ang makakapaglipat)
                if (isAdminUser(widget.user))
                  ListTile(
                    leading: const Icon(Icons.store_outlined),
                    title: const Text('My Branch'),
                    subtitle: Text(
                      _currentBranch().isEmpty
                          ? 'No branch yet. Ask the Owner to assign you.'
                          : '${_currentBranch()} (only the Owner can change it)',
                    ),
                  ),
                if (isOwnerUser(widget.user))
                  ListTile(
                    leading: const Icon(Icons.store_mall_directory_outlined),
                    title: const Text('Manage Branches'),
                    subtitle: const Text(
                      'Add branches and change branch passwords',
                    ),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => showDialog(
                      context: context,
                      builder: (_) => BranchesDialog(
                        store: widget.store,
                        actorName: widget.user.name,
                      ),
                    ),
                  ),
                if (!isManagerUser(widget.user))
                  ListTile(
                    leading: const Icon(Icons.swap_horiz_rounded),
                    title: const Text('Change Branch'),
                    subtitle: Text(_branchSubtitle()),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: changeBranch,
                  ),
                ListTile(
                  leading: const Icon(Icons.lock_outline),
                  title: const Text('Change Password'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: changePassword,
                ),
                ListTile(
                  leading: const Icon(Icons.logout, color: Colors.red),
                  title: const Text('Log Out'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: logout,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// -----------------------------------------------------------------------------
// UI COMPONENTS
// -----------------------------------------------------------------------------

class PageFrame extends StatelessWidget {
  final String title;
  final String subtitle;
  final Widget child;

  const PageFrame({
    super.key,
    required this.title,
    required this.subtitle,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          colors: [Color(0xFFF7FBFF), Color(0xFFEDF7FF), Color(0xFFF8FBFF)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
      ),
      child: SafeArea(
        child: Column(
          children: [
            if (MediaQuery.sizeOf(context).width >= 900)
              Padding(
                padding: const EdgeInsets.fromLTRB(30, 24, 30, 0),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Row(
                    children: [
                      Text(
                        title,
                        style: const TextStyle(
                          fontSize: 28,
                          fontWeight: FontWeight.w800,
                          color: Color(0xFF0D2D57),
                        ),
                      ),
                      const SizedBox(width: 14),
                      Text(
                        subtitle,
                        style: const TextStyle(color: Color(0xFF6E86A4)),
                      ),
                    ],
                  ),
                ),
              ),
            Expanded(child: child),
          ],
        ),
      ),
    );
  }
}

class GradientHeader extends StatelessWidget {
  final String title;
  final String subtitle;

  const GradientHeader({
    super.key,
    required this.title,
    required this.subtitle,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(24),
        gradient: const LinearGradient(
          colors: [Color(0xFF0874EE), Color(0xFF0A91F5), Color(0xFF0C66D7)],
        ),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF0869EE).withValues(alpha: .18),
            blurRadius: 28,
            offset: const Offset(0, 15),
          ),
        ],
      ),
      child: Row(
        children: [
          const Icon(Icons.receipt_long_rounded, color: Colors.white, size: 44),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 22,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 5),
                Text(subtitle, style: const TextStyle(color: Colors.white70)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class StatCard extends StatelessWidget {
  final String title;
  final String value;
  final IconData icon;
  final Color color;
  final Color foreground;
  final VoidCallback? onTap;

  const StatCard({
    super.key,
    required this.title,
    required this.value,
    required this.icon,
    required this.color,
    required this.foreground,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: MediaQuery.sizeOf(context).width >= 900 ? 220 : double.infinity,
      child: Material(
        color: color,
        borderRadius: BorderRadius.circular(20),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(20),
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(icon, color: foreground, size: 28),
                    const Spacer(),
                    if (onTap != null)
                      Icon(
                        Icons.arrow_forward_ios_rounded,
                        size: 14,
                        color: foreground,
                      ),
                  ],
                ),
                const SizedBox(height: 12),
                Text(title, style: TextStyle(color: foreground)),
                const SizedBox(height: 4),
                Text(
                  value,
                  style: TextStyle(
                    color: foreground,
                    fontSize: 25,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class SectionCard extends StatelessWidget {
  final String title;
  final Widget child;
  final Widget? action;
  final EdgeInsetsGeometry padding;

  const SectionCard({
    super.key,
    required this.title,
    required this.child,
    this.action,
    this.padding = const EdgeInsets.all(22),
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: padding,
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: const Color(0xFFE5EBF4)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: .045),
            blurRadius: 30,
            offset: const Offset(0, 12),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  title,
                  style: const TextStyle(
                    fontSize: 19,
                    fontWeight: FontWeight.w800,
                    color: Color(0xFF12233F),
                  ),
                ),
              ),
              ?action,
            ],
          ),
          const SizedBox(height: 12),
          child,
        ],
      ),
    );
  }
}

// -----------------------------------------------------------------------------
// TRANSACTION DETAIL: ang record at ang na-scan na larawan ng receipt
// -----------------------------------------------------------------------------

Future<void> showTransactionDetail(
  BuildContext context,
  int userId,
  TransactionRecord tx,
) {
  return showDialog<void>(
    context: context,
    builder: (_) => _TransactionDetailDialog(userId: userId, tx: tx),
  );
}

class _TransactionDetailDialog extends StatefulWidget {
  final int userId;
  final TransactionRecord tx;
  const _TransactionDetailDialog({required this.userId, required this.tx});

  @override
  State<_TransactionDetailDialog> createState() =>
      _TransactionDetailDialogState();
}

class _TransactionDetailDialogState extends State<_TransactionDetailDialog> {
  Uint8List? imageBytes;
  bool loading = false;
  String error = '';

  @override
  void initState() {
    super.initState();
    if (widget.tx.hasImage) _load();
  }

  Future<void> _load() async {
    setState(() {
      loading = true;
      error = '';
    });
    try {
      final res = await ApiService.getReceiptImage(
        userId: widget.userId,
        transactionId: widget.tx.id,
      );
      if (!mounted) return;
      if (res['success'] == true && res['image'] != null) {
        setState(() {
          imageBytes = base64Decode(res['image'].toString());
          loading = false;
        });
      } else {
        setState(() {
          error = res['message']?.toString() ?? 'Unable to load the receipt.';
          loading = false;
        });
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        error = 'Unable to load the receipt image.';
        loading = false;
      });
    }
  }

  Widget _row(String label, String value) {
    if (value.trim().isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 100,
            child: Text(
              label,
              style: const TextStyle(color: Color(0xFF71819A), fontSize: 13),
            ),
          ),
          Expanded(
            child: SelectableText(
              value,
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final tx = widget.tx;
    return AlertDialog(
      title: const Text('Transaction Record'),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _row('Account Name', tx.accountName),
              _row('Sender Number', tx.senderNumber),
              _row('Amount', '₱${money(tx.amount)}'),
              _row('Reference No.', tx.reference),
              _row('Date', tx.date),
              _row('Time', tx.time),
              _row('Scanned by', tx.scannedBy),
              _row('Branch', tx.branch),
              const SizedBox(height: 8),
              const Text(
                'Scanned Receipt',
                style: TextStyle(fontWeight: FontWeight.w800),
              ),
              const SizedBox(height: 8),
              if (!tx.hasImage)
                const Text(
                  'No receipt image was saved for this transaction.',
                  style: TextStyle(color: Color(0xFF71819A)),
                )
              else if (loading)
                const Center(
                  child: Padding(
                    padding: EdgeInsets.all(24),
                    child: CircularProgressIndicator(),
                  ),
                )
              else if (error.isNotEmpty)
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(error, style: const TextStyle(color: Colors.red)),
                    TextButton(onPressed: _load, child: const Text('Retry')),
                  ],
                )
              else if (imageBytes != null)
                GestureDetector(
                  onTap: () => showDialog<void>(
                    context: context,
                    builder: (_) => Dialog(
                      child: InteractiveViewer(
                        child: Image.memory(imageBytes!),
                      ),
                    ),
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(12),
                    child: Image.memory(imageBytes!, fit: BoxFit.contain),
                  ),
                ),
              if (imageBytes != null)
                const Padding(
                  padding: EdgeInsets.only(top: 6),
                  child: Text(
                    'Tap the image to zoom.',
                    style: TextStyle(color: Color(0xFF71819A), fontSize: 12),
                  ),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Close'),
        ),
      ],
    );
  }
}

class TransactionTile extends StatelessWidget {
  final TransactionRecord tx;
  final bool selected;
  final ValueChanged<bool>? onSelected;
  final bool showScanner; // Owner/Admin: ipakita kung sino ang nag-scan

  const TransactionTile(
    this.tx, {
    super.key,
    this.selected = false,
    this.onSelected,
    this.showScanner = false,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 5),
      padding: const EdgeInsets.symmetric(vertical: 8),
      decoration: BoxDecoration(
        color: selected ? const Color(0xFFF0F7FF) : Colors.transparent,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        children: [
          if (onSelected != null)
            Checkbox(
              value: selected,
              onChanged: (v) => onSelected!(v ?? false),
            ),
          Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(
              color: const Color(0xFFEAF5FF),
              borderRadius: BorderRadius.circular(14),
            ),
            child: const Icon(Icons.receipt_long, color: Color(0xFF0869EE)),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  tx.accountName.isEmpty ? 'Unknown' : tx.accountName,
                  style: const TextStyle(fontWeight: FontWeight.w800),
                ),
                const SizedBox(height: 3),
                Text(
                  '${tx.date} ${tx.time}\nRef: ${tx.reference}'
                  '${tx.senderNumber.isNotEmpty ? '\nSender No.: ${tx.senderNumber}' : ''}'
                  '${showScanner && tx.scannedBy.isNotEmpty ? '\nScanned by: ${tx.scannedBy}' : ''}'
                  '${showScanner && tx.branch.isNotEmpty ? '\nBranch: ${tx.branch}' : ''}',
                  style: const TextStyle(
                    color: Color(0xFF71819A),
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                '₱${money(tx.amount)}',
                style: const TextStyle(
                  fontWeight: FontWeight.w800,
                  color: Color(0xFF07976F),
                ),
              ),
              if (tx.hasImage)
                const Padding(
                  padding: EdgeInsets.only(top: 4),
                  child: Icon(
                    Icons.image_outlined,
                    size: 16,
                    color: Color(0xFF0869EE),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

// -----------------------------------------------------------------------------
// CALENDAR (para sa lahat ng role)
// -----------------------------------------------------------------------------

Future<void> showCalendarDialog(BuildContext context) {
  return showDialog<void>(
    context: context,
    builder: (ctx) => Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 380),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CalendarDatePicker(
              initialDate: DateTime.now(),
              firstDate: DateTime(2020),
              lastDate: DateTime(2100),
              onDateChanged: (_) {},
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
              child: Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: const Text('Close'),
                ),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

// -----------------------------------------------------------------------------
// STAFF ACCOUNTS (Owner/Admin lang)
// -----------------------------------------------------------------------------

class StaffAccountsPage extends StatefulWidget {
  final ReceiScanStore store;
  final UserAccount user;
  const StaffAccountsPage({super.key, required this.store, required this.user});

  @override
  State<StaffAccountsPage> createState() => _StaffAccountsPageState();
}

class _StaffAccountsPageState extends State<StaffAccountsPage> {
  final search = TextEditingController();
  String roleFilter = 'All';

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  @override
  void dispose() {
    search.dispose();
    super.dispose();
  }

  Future<void> _refresh() async {
    try {
      await widget.store.refreshUsers();
      await widget.store.refreshPasswordRequests();
    } catch (e) {
      debugPrint('USERS REFRESH ERROR: $e');
    }
    if (!mounted) return;
    setState(() {});
  }

  Future<void> _dismissRequest(Map<String, dynamic> r) async {
    try {
      await ApiService.dismissPasswordRequest(
        userId: widget.store.currentUserId,
        requestId: int.tryParse(r['id'].toString()) ?? 0,
      );
      await _refresh();
    } catch (e) {
      if (!mounted) return;
      snack(context, errorText(e));
    }
  }

  // Owner lang: ilagay / ilipat ang Staff o Admin sa isang branch
  Future<void> _assignBranch(UserAccount target) async {
    if (!isOwnerUser(widget.user)) return;
    final tRole = target.role.toLowerCase();
    if (tRole != 'staff' && tRole != 'admin') return;

    List<Map<String, dynamic>> branches;
    try {
      branches = await ApiService.listBranches(
        userId: widget.store.currentUserId,
      );
    } catch (e) {
      if (!mounted) return;
      snack(context, errorText(e));
      return;
    }
    if (!mounted) return;

    // id ng napiling branch; '0' = alisin sa branch
    final picked = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
                child: Text(
                  'Assign ${target.name} to a branch',
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w800,
                    color: Color(0xFF12233F),
                  ),
                ),
              ),
              for (final b in branches)
                ListTile(
                  leading: const Icon(Icons.store_outlined),
                  title: Text(b['name'].toString()),
                  trailing: target.branch == b['name'].toString()
                      ? const Icon(Icons.check_circle, color: Color(0xFF07976F))
                      : null,
                  onTap: () => Navigator.pop(sheetContext, b['id'].toString()),
                ),
              if (target.branch.isNotEmpty)
                ListTile(
                  leading: const Icon(Icons.link_off, color: Colors.red),
                  title: const Text(
                    'Remove from branch',
                    style: TextStyle(color: Colors.red),
                  ),
                  onTap: () => Navigator.pop(sheetContext, '0'),
                ),
            ],
          ),
        ),
      ),
    );
    if (picked == null || !mounted) return;

    try {
      final res = await ApiService.assignBranch(
        userId: widget.store.currentUserId,
        targetId: int.tryParse(target.id) ?? 0,
        branchId: picked,
      );
      if (!mounted) return;

      if (res['success'] != true) {
        snack(
          context,
          res['message']?.toString() ?? 'Unable to assign branch.',
        );
        return;
      }

      final bn = res['branch']?.toString() ?? '';
      await widget.store.addLog(
        'Branch Assigned',
        bn.isEmpty
            ? '${widget.user.name} removed ${target.name} from their branch.'
            : '${widget.user.name} assigned ${target.name} to $bn.',
        widget.user.name,
      );
      await _refresh();
      if (!mounted) return;
      snack(context, bn.isEmpty ? 'Removed from branch.' : 'Assigned to $bn.');
    } catch (e) {
      if (!mounted) return;
      snack(context, errorText(e));
    }
  }

  // Pwede bang i-reset ng naka-login ang password ng account na ito?
  bool _canReset(UserAccount t) {
    final role = t.role.toLowerCase();
    if (t.id == widget.user.id || role == 'owner') return false;
    // Owner: Admin at Staff. Admin: Staff lang (sa branch niya).
    if (isOwnerUser(widget.user)) return true;
    return isAdminUser(widget.user) && role == 'staff';
  }

  Future<void> _resetPassword(UserAccount target) async {
    final pass1 = TextEditingController();
    final pass2 = TextEditingController();
    final newPass = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('Reset password: ${target.name}'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: pass1,
              obscureText: true,
              decoration: const InputDecoration(labelText: 'New Password'),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: pass2,
              obscureText: true,
              decoration: const InputDecoration(labelText: 'Confirm Password'),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              if (pass1.text.length < 6) {
                snack(dialogContext, 'Password must be at least 6 characters.');
                return;
              }
              if (pass1.text != pass2.text) {
                snack(dialogContext, 'Passwords do not match.');
                return;
              }
              Navigator.pop(dialogContext, pass1.text);
            },
            child: const Text('Reset'),
          ),
        ],
      ),
    );
    if (newPass == null || !mounted) return;

    try {
      final res = await ApiService.resetStaffPassword(
        userId: widget.store.currentUserId,
        targetId: int.tryParse(target.id) ?? 0,
        newPassword: newPass,
      );
      if (!mounted) return;
      if (res['success'] != true) {
        snack(context, res['message']?.toString() ?? 'Unable to reset.');
        return;
      }
      await widget.store.addLog(
        'Password Reset',
        '${widget.user.name} reset the password of ${target.name}.',
        widget.user.name,
      );
      if (!mounted) return;
      await _refresh();
      if (!mounted) return;
      snack(
        context,
        'Password reset. Give the new password to ${target.name}.',
      );
    } catch (e) {
      if (!mounted) return;
      snack(context, errorText(e));
    }
  }

  @override
  Widget build(BuildContext context) {
    // Staff ay hindi dapat makakita nito
    if (!isManagerUser(widget.user)) {
      return const Scaffold(
        body: Center(child: Text('Only the Owner or Admin can view accounts.')),
      );
    }

    final q = search.text.trim().toLowerCase();
    // Hindi kasama ang sarili sa listahan
    final all = widget.store
        .getUsers()
        .where((u) => u.id != widget.user.id)
        .toList();
    final list = all.where((u) {
      final role = u.role.toLowerCase();
      final okRole = roleFilter == 'All' || role == roleFilter.toLowerCase();
      final okSearch =
          q.isEmpty ||
          u.name.toLowerCase().contains(q) ||
          u.email.toLowerCase().contains(q) ||
          u.branch.toLowerCase().contains(q);
      return okRole && okSearch;
    }).toList();

    Color roleColor(String r) {
      switch (r.toLowerCase()) {
        case 'owner':
          return const Color(0xFF7047C8);
        case 'admin':
          return const Color(0xFF0869EE);
        default:
          return const Color(0xFF07976F);
      }
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('Staff Accounts'),
        backgroundColor: Colors.white,
        elevation: 0,
      ),
      body: RefreshIndicator(
        onRefresh: _refresh,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 40),
          children: [
            Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 900),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // ---------- MGA REQUEST NA MAGPALIT NG PASSWORD ----------
                    if (widget.store.getPasswordRequests().isNotEmpty) ...[
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(14),
                        margin: const EdgeInsets.only(bottom: 16),
                        decoration: BoxDecoration(
                          color: const Color(0xFFFFF6E5),
                          borderRadius: BorderRadius.circular(18),
                          border: Border.all(color: const Color(0xFFF3D9A4)),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text(
                              'Password Requests',
                              style: TextStyle(
                                fontWeight: FontWeight.w800,
                                fontSize: 15,
                              ),
                            ),
                            const SizedBox(height: 4),
                            for (final r in widget.store.getPasswordRequests())
                              ListTile(
                                contentPadding: EdgeInsets.zero,
                                title: Text(
                                  r['name'].toString(),
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                                subtitle: Text(
                                  '${r['email']}\n'
                                  '${r['role'].toString().toUpperCase()}'
                                  '${r['branch'].toString().isEmpty ? '' : ' • ${r['branch']}'}',
                                  style: const TextStyle(fontSize: 12),
                                ),
                                isThreeLine: true,
                                trailing: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    IconButton(
                                      tooltip: 'Dismiss',
                                      icon: const Icon(Icons.close),
                                      onPressed: () => _dismissRequest(r),
                                    ),
                                    FilledButton(
                                      onPressed: () => _resetPassword(
                                        UserAccount(
                                          id: r['userId'].toString(),
                                          name: r['name'].toString(),
                                          email: r['email'].toString(),
                                          password: '',
                                          role: r['role'].toString(),
                                        ),
                                      ),
                                      child: const Text('Reset'),
                                    ),
                                  ],
                                ),
                              ),
                          ],
                        ),
                      ),
                    ],
                    TextField(
                      controller: search,
                      onChanged: (_) => setState(() {}),
                      decoration: const InputDecoration(
                        hintText: 'Search name, email or branch...',
                        prefixIcon: Icon(Icons.search),
                        isDense: true,
                      ),
                    ),
                    const SizedBox(height: 10),
                    SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: Row(
                        children: [
                          for (final r in [
                            'All',
                            'Staff',
                            if (isOwnerUser(widget.user)) 'Admin',
                          ])
                            Padding(
                              padding: const EdgeInsets.only(right: 8),
                              child: ChoiceChip(
                                label: Text(r),
                                selected: roleFilter == r,
                                showCheckmark: false,
                                onSelected: (_) =>
                                    setState(() => roleFilter = r),
                              ),
                            ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 14),
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 6,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(22),
                        border: Border.all(color: const Color(0xFFE5EBF4)),
                      ),
                      child: list.isEmpty
                          ? const EmptyState(text: 'No accounts found.')
                          : Column(
                              children: [
                                for (var i = 0; i < list.length; i++) ...[
                                  if (i > 0)
                                    const Divider(
                                      height: 1,
                                      color: Color(0xFFEFF3F8),
                                    ),
                                  ListTile(
                                    contentPadding: EdgeInsets.zero,
                                    leading: CircleAvatar(
                                      backgroundColor: roleColor(
                                        list[i].role,
                                      ).withValues(alpha: 0.12),
                                      child: Text(
                                        list[i].name.trim().isEmpty
                                            ? '?'
                                            : list[i].name
                                                  .trim()[0]
                                                  .toUpperCase(),
                                        style: TextStyle(
                                          color: roleColor(list[i].role),
                                          fontWeight: FontWeight.w800,
                                        ),
                                      ),
                                    ),
                                    title: Text(
                                      list[i].name,
                                      style: const TextStyle(
                                        fontWeight: FontWeight.w800,
                                      ),
                                    ),
                                    subtitle: Text(
                                      '${list[i].email}\n'
                                      '${list[i].branch.isEmpty ? 'No branch yet' : 'Branch: ${list[i].branch}'}',
                                      style: const TextStyle(fontSize: 12),
                                    ),
                                    isThreeLine: true,
                                    // Owner lang ang makakapaglipat ng branch
                                    onTap:
                                        (isOwnerUser(widget.user) &&
                                            list[i].role.toLowerCase() !=
                                                'owner')
                                        ? () => _assignBranch(list[i])
                                        : null,
                                    trailing: Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        if (_canReset(list[i]))
                                          IconButton(
                                            tooltip: 'Reset password',
                                            icon: const Icon(Icons.lock_reset),
                                            onPressed: () =>
                                                _resetPassword(list[i]),
                                          ),
                                        Column(
                                          mainAxisAlignment:
                                              MainAxisAlignment.center,
                                          crossAxisAlignment:
                                              CrossAxisAlignment.end,
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            Text(
                                              formatRole(list[i].role),
                                              style: TextStyle(
                                                fontSize: 11,
                                                fontWeight: FontWeight.w800,
                                                color: roleColor(list[i].role),
                                              ),
                                            ),
                                            if (isOwnerUser(widget.user) &&
                                                list[i].role.toLowerCase() !=
                                                    'owner')
                                              const Padding(
                                                padding: EdgeInsets.only(
                                                  top: 4,
                                                ),
                                                child: Icon(
                                                  Icons.edit_outlined,
                                                  size: 16,
                                                  color: Color(0xFF9AAEC6),
                                                ),
                                              ),
                                          ],
                                        ),
                                      ],
                                    ),
                                  ),
                                ],
                              ],
                            ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// Staff: humiling na lumipat ng branch. Kailangan ng approval ng admin
// ng pupuntahang branch (o ng Owner).
class ChangeBranchDialog extends StatefulWidget {
  final ReceiScanStore store;
  final UserAccount user;
  final String currentBranch;
  final Map<String, dynamic>? pending;

  const ChangeBranchDialog({
    super.key,
    required this.store,
    required this.user,
    required this.currentBranch,
    this.pending,
  });

  @override
  State<ChangeBranchDialog> createState() => _ChangeBranchDialogState();
}

class _ChangeBranchDialogState extends State<ChangeBranchDialog> {
  List<Map<String, dynamic>> branches = [];
  bool loading = true;
  bool busy = false;

  int get _uid => widget.store.currentUserId;

  @override
  void initState() {
    super.initState();
    if (widget.pending == null) {
      _load();
    } else {
      loading = false;
    }
  }

  Future<void> _load() async {
    try {
      final rows = await ApiService.listBranches(userId: _uid);
      if (!mounted) return;
      setState(() => branches = rows);
    } catch (e) {
      if (!mounted) return;
      snack(context, errorText(e));
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  Future<void> _send(Map<String, dynamic> b) async {
    // Lilipat ng branch: hihingin ang password ng pupuntahang branch.
    // Pagkatapos, kailangan pa rin ng approval ng admin ng branch na iyon.
    final pass = await showDialog<String>(
      context: context,
      builder: (_) => PasswordPromptDialog(
        title: 'Move to ${b['name']}',
        message:
            'Enter the password of this branch. The '
            'branch admin or owner must still approve your request.',
      ),
    );
    if (pass == null || !mounted) return;

    setState(() => busy = true);
    try {
      final res = await ApiService.requestBranchChange(
        userId: _uid,
        branchId: b['id'].toString(),
        branchPassword: pass,
      );
      if (!mounted) return;

      if (res['success'] != true) {
        snack(context, res['message']?.toString() ?? 'Unable to send request.');
        setState(() => busy = false);
        return;
      }

      await widget.store.addLog(
        'Branch Request',
        '${widget.user.name} requested to move from '
            '${widget.currentBranch} to ${b['name']}.',
        widget.user.name,
      );
      if (!mounted) return;
      snack(context, res['message']?.toString() ?? 'Request sent.');
      Navigator.pop(context, true);
    } catch (e) {
      if (!mounted) return;
      snack(context, errorText(e));
      setState(() => busy = false);
    }
  }

  Future<void> _cancel() async {
    final id = int.tryParse(widget.pending?['id']?.toString() ?? '') ?? 0;
    setState(() => busy = true);
    try {
      final res = await ApiService.cancelBranchRequest(
        userId: _uid,
        requestId: id,
      );
      if (!mounted) return;
      snack(context, res['message']?.toString() ?? 'Request cancelled.');
      Navigator.pop(context, true);
    } catch (e) {
      if (!mounted) return;
      snack(context, errorText(e));
      setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.pending;

    return AlertDialog(
      title: const Text('Change Branch'),
      content: SizedBox(
        width: 360,
        child: loading
            ? const Padding(
                padding: EdgeInsets.all(24),
                child: Center(child: CircularProgressIndicator()),
              )
            : SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Current branch: ${widget.currentBranch}',
                      style: const TextStyle(
                        fontWeight: FontWeight.w800,
                        color: Color(0xFF12233F),
                      ),
                    ),
                    const SizedBox(height: 10),
                    if (p != null) ...[
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(14),
                        decoration: BoxDecoration(
                          color: const Color(0xFFFFF0DC),
                          borderRadius: BorderRadius.circular(14),
                        ),
                        child: Text(
                          'Your request to move to ${p['toBranch']} is '
                          'waiting for approval from the branch admin or owner.',
                          style: const TextStyle(
                            color: Color(0xFFB76A00),
                            fontSize: 13,
                          ),
                        ),
                      ),
                    ] else ...[
                      const Text(
                        'Choose the branch you want to move to. You will need '
                        'that branch\'s password, and the branch admin or owner must approve your request.',
                        style: TextStyle(
                          color: Color(0xFF58728F),
                          fontSize: 13,
                        ),
                      ),
                      const SizedBox(height: 8),
                      for (final b in branches)
                        if (b['name'].toString() != widget.currentBranch)
                          ListTile(
                            enabled: !busy,
                            contentPadding: EdgeInsets.zero,
                            leading: const Icon(Icons.store_outlined),
                            title: Text(b['name'].toString()),
                            trailing: const Icon(Icons.chevron_right),
                            onTap: () => _send(b),
                          ),
                    ],
                  ],
                ),
              ),
      ),
      actions: [
        if (p != null)
          TextButton(
            onPressed: busy ? null : _cancel,
            child: const Text(
              'Cancel Request',
              style: TextStyle(color: Colors.red),
            ),
          ),
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Close'),
        ),
      ],
    );
  }
}

// Owner / Admin: mga request ng staff na lumipat ng branch.
// Admin: papunta sa branch niya lang. Owner: lahat.
class BranchRequestsPage extends StatefulWidget {
  final ReceiScanStore store;
  final UserAccount user;
  const BranchRequestsPage({
    super.key,
    required this.store,
    required this.user,
  });

  @override
  State<BranchRequestsPage> createState() => _BranchRequestsPageState();
}

class _BranchRequestsPageState extends State<BranchRequestsPage> {
  bool busy = false;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    try {
      await widget.store.refreshBranchRequests();
    } catch (e) {
      debugPrint('BRANCH REQUESTS ERROR: $e');
    }
    if (!mounted) return;
    setState(() {});
  }

  Future<void> _decide(Map<String, dynamic> r, bool approve) async {
    final name = r['name']?.toString() ?? '';
    final to = r['toBranch']?.toString() ?? '';

    final ok = await confirmDialog(
      context,
      approve ? 'Approve Request' : 'Reject Request',
      approve
          ? 'Allow $name to move to $to? They will join this branch right away.'
          : 'Reject the request of $name to move to $to?',
    );
    if (!ok || !mounted) return;

    setState(() => busy = true);
    try {
      final res = await ApiService.decideBranchRequest(
        userId: widget.store.currentUserId,
        requestId: int.tryParse(r['id'].toString()) ?? 0,
        approve: approve,
      );
      if (!mounted) return;

      if (res['success'] != true) {
        snack(context, res['message']?.toString() ?? 'Unable to save.');
      } else {
        await widget.store.addLog(
          approve ? 'Branch Request Approved' : 'Branch Request Rejected',
          '${widget.user.name} ${approve ? 'approved' : 'rejected'} '
          '$name moving to $to.',
          widget.user.name,
        );
        if (!mounted) return;
        snack(context, approve ? 'Request approved.' : 'Request rejected.');
      }
    } catch (e) {
      if (!mounted) return;
      snack(context, errorText(e));
    }

    await _refresh();
    try {
      await widget.store.refreshUsers();
    } catch (_) {}
    if (mounted) setState(() => busy = false);
  }

  @override
  Widget build(BuildContext context) {
    if (!isManagerUser(widget.user)) {
      return const Scaffold(
        body: Center(
          child: Text('Only the Owner or Admin can view branch requests.'),
        ),
      );
    }

    final list = widget.store.getBranchRequests();

    return Scaffold(
      appBar: AppBar(
        title: const Text('Branch Requests'),
        backgroundColor: Colors.white,
        elevation: 0,
      ),
      body: RefreshIndicator(
        onRefresh: _refresh,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 40),
          children: [
            Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 700),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      isOwnerUser(widget.user)
                          ? 'Staff waiting to move to another branch.'
                          : 'Staff who want to join your branch.',
                      style: const TextStyle(
                        color: Color(0xFF6E86A4),
                        fontSize: 13,
                      ),
                    ),
                    const SizedBox(height: 12),
                    if (list.isEmpty)
                      Container(
                        width: double.infinity,
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(22),
                          border: Border.all(color: const Color(0xFFE5EBF4)),
                        ),
                        child: const EmptyState(text: 'No pending requests.'),
                      ),
                    for (final r in list)
                      Container(
                        width: double.infinity,
                        margin: const EdgeInsets.only(bottom: 12),
                        padding: const EdgeInsets.all(16),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(18),
                          border: Border.all(color: const Color(0xFFD6E6FA)),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              r['name']?.toString() ?? '',
                              style: const TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.w800,
                                color: Color(0xFF12233F),
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              r['email']?.toString() ?? '',
                              style: const TextStyle(
                                fontSize: 12,
                                color: Color(0xFF71819A),
                              ),
                            ),
                            const SizedBox(height: 10),
                            Row(
                              children: [
                                const Icon(
                                  Icons.store_outlined,
                                  size: 16,
                                  color: Color(0xFF0869EE),
                                ),
                                const SizedBox(width: 6),
                                Flexible(
                                  child: Text(
                                    (r['fromBranch']?.toString() ?? '').isEmpty
                                        ? 'No branch  →  ${r['toBranch']}'
                                        : '${r['fromBranch']}  →  ${r['toBranch']}',
                                    style: const TextStyle(
                                      fontWeight: FontWeight.w700,
                                      color: Color(0xFF0869EE),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 4),
                            Text(
                              'Requested: ${r['createdAt'] ?? ''}',
                              style: const TextStyle(
                                fontSize: 11.5,
                                color: Color(0xFF9AAEC6),
                              ),
                            ),
                            const SizedBox(height: 12),
                            Row(
                              children: [
                                Expanded(
                                  child: OutlinedButton(
                                    onPressed: busy
                                        ? null
                                        : () => _decide(r, false),
                                    child: const Text('Reject'),
                                  ),
                                ),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: FilledButton(
                                    onPressed: busy
                                        ? null
                                        : () => _decide(r, true),
                                    child: const Text('Approve'),
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class OverviewBox extends StatelessWidget {
  final String title;
  final String value;
  final VoidCallback? onTap;

  const OverviewBox({
    super.key,
    required this.title,
    required this.value,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final box = Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: const Color(0xFFD6E6FA)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            value,
            style: const TextStyle(
              fontSize: 30,
              fontWeight: FontWeight.w800,
              color: Color(0xFF0B1B33),
            ),
          ),
          const SizedBox(height: 4),
          Row(
            children: [
              Expanded(
                child: Text(
                  title,
                  style: const TextStyle(
                    color: Color(0xFF2B3F5C),
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              if (onTap != null)
                const Icon(
                  Icons.chevron_right,
                  size: 18,
                  color: Color(0xFF9AAEC6),
                ),
            ],
          ),
        ],
      ),
    );

    if (onTap == null) return box;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onTap,
        child: box,
      ),
    );
  }
}

class ReportMini extends StatelessWidget {
  final String title;
  final String value;

  const ReportMini({super.key, required this.title, required this.value});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 170,
      padding: const EdgeInsets.all(17),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: .12),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white.withValues(alpha: .15)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: const TextStyle(color: Colors.white70, fontSize: 12),
          ),
          const SizedBox(height: 5),
          Text(
            value,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 21,
              fontWeight: FontWeight.w800,
            ),
          ),
        ],
      ),
    );
  }
}

class EmptyState extends StatelessWidget {
  final String text;
  const EmptyState({super.key, required this.text});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(25),
      child: Center(
        child: Text(text, style: const TextStyle(color: Color(0xFF71819A))),
      ),
    );
  }
}

// -----------------------------------------------------------------------------
// HELPERS
// -----------------------------------------------------------------------------

// Owner at Admin: nakikita ang receipt/transaction at pwedeng magbura.
//   Owner: lahat ng branch. Admin: branch niya lang (ang server ang nagsasala).
// Staff: sarili lang nilang scan ang nakikita, view-only.
bool isManagerUser(UserAccount u) {
  final r = u.role.trim().toLowerCase();
  return r == 'owner' || r == 'admin';
}

// Owner lang: lahat ng branch, Manage Branches, paglipat ng account.
bool isOwnerUser(UserAccount u) => u.role.trim().toLowerCase() == 'owner';

// Admin lang (may sariling branch)
bool isAdminUser(UserAccount u) => u.role.trim().toLowerCase() == 'admin';

// Attendance: para na sa lahat ng role (dati ay dalawang email lang).
//   Owner: lahat ng Staff. Admin: Staff ng branch niya. Staff: sarili.
// Ang server ang nagsasala kung kaninong attendance ang makikita.
bool canViewAttendance(UserAccount u) => u.role.trim().isNotEmpty;

// Gawing "YYYY-MM-DD HH:MM:00" (24-oras) para sa database
String toSqlDateTime(String date, String time) {
  final d = date.trim().isEmpty ? dateKey(DateTime.now()) : date.trim();
  final t = parseTime(time);
  final hh = t == null ? '00' : t.hour.toString().padLeft(2, '0');
  final mm = t == null ? '00' : t.minute.toString().padLeft(2, '0');
  return '$d $hh:$mm:00';
}

String money(double value) {
  return value
      .toStringAsFixed(2)
      .replaceAllMapped(RegExp(r'(\d)(?=(\d{3})+\.)'), (m) => '${m[1]},');
}

String dateKey(DateTime d) {
  return '${d.year.toString().padLeft(4, '0')}-'
      '${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')}';
}

String timeNow() {
  final d = DateTime.now();
  final h = d.hour == 0 ? 12 : (d.hour > 12 ? d.hour - 12 : d.hour);
  final ap = d.hour >= 12 ? 'PM' : 'AM';
  return '${h.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')} $ap';
}

DateTime? parseTime(String value) {
  if (value.trim().isEmpty) return null;
  final m = RegExp(
    r'(\d{1,2}):(\d{2})\s*(AM|PM)?',
    caseSensitive: false,
  ).firstMatch(value);
  if (m == null) return null;
  var h = int.parse(m.group(1)!);
  final min = int.parse(m.group(2)!);
  final ap = m.group(3)?.toUpperCase();
  if (ap == 'PM' && h < 12) h += 12;
  if (ap == 'AM' && h == 12) h = 0;
  final now = DateTime.now();
  return DateTime(now.year, now.month, now.day, h, min);
}

// Alisin ang paulit-ulit na "Exception: " sa mensahe ng error
String errorText(Object e) => e.toString().replaceAll('Exception: ', '');

void snack(BuildContext context, String message) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(message)));
}

Future<bool> confirmDialog(
  BuildContext context,
  String title,
  String message,
) async {
  return await showDialog<bool>(
        context: context,
        builder: (_) => AlertDialog(
          title: Text(title),
          content: Text(message),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Confirm'),
            ),
          ],
        ),
      ) ??
      false;
}

class _MoreTile extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final Color color;
  final Color foreground;
  final bool active;
  final bool showChevron;
  final VoidCallback onTap;

  const _MoreTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.color,
    required this.foreground,
    required this.onTap,
    this.active = false,
    this.showChevron = true,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: active ? const Color(0xFFF0F7FF) : Colors.transparent,
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
          child: Row(
            children: [
              Container(
                width: 46,
                height: 46,
                decoration: BoxDecoration(
                  color: color,
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Icon(icon, color: foreground),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: TextStyle(
                        fontSize: 15.5,
                        fontWeight: FontWeight.w800,
                        color: foreground == const Color(0xFFD32F2F)
                            ? foreground
                            : const Color(0xFF12233F),
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      style: const TextStyle(
                        fontSize: 12,
                        color: Color(0xFF71819A),
                      ),
                    ),
                  ],
                ),
              ),
              if (showChevron)
                const Icon(Icons.chevron_right, color: Color(0xFF9AAEC6)),
            ],
          ),
        ),
      ),
    );
  }
}
