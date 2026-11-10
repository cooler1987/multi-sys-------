import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:file_picker/file_picker.dart';

// ─────────────────────────────────────────────────────────────
// 1. 日志管理系统
// ─────────────────────────────────────────────────────────────
class LogManager {
  static final LogManager instance = LogManager._();
  LogManager._();

  final List<String> logs = [];
  final StreamController<List<String>> _controller = StreamController<List<String>>.broadcast();
  Stream<List<String>> get stream => _controller.stream;

  void log(String tag, String message) {
    final now = DateTime.now().toIso8601String().substring(11, 19);
    final entry = "[$now][$tag] $message";
    logs.add(entry);
    if (logs.length > 500) logs.removeAt(0);
    _controller.add(List.from(logs));
  }

  void clear() {
    logs.clear();
    _controller.add([]);
  }

  Future<String?> exportLogsToFile() async {
    if (logs.isEmpty) return null;
    final savePath = await FilePicker.platform.saveFile(
      dialogTitle: '保存调试日志',
      fileName: 'tts_log_${DateTime.now().millisecondsSinceEpoch}.txt',
      type: FileType.custom,
      allowedExtensions: ['txt', 'log'],
    );
    if (savePath != null) {
      await File(savePath).writeAsString(logs.join('\r\n'));
      return savePath;
    }
    return null;
  }
}

// ─────────────────────────────────────────────────────────────
// 2. 网络代理管理器 (自动探测 Windows 注册表)
// ─────────────────────────────────────────────────────────────
class AppProxyManager {
  static final AppProxyManager instance = AppProxyManager._();
  AppProxyManager._();

  String mode = "auto"; // "auto" 自动检测 | "custom" 自定义 | "direct" 纯直连
  String customHost = "127.0.0.1";
  int customPort = 7890;

  String? _lastDetectedProxy;
  DateTime? _lastDetectTime;

  String getProxyString(Uri uri) {
    if (mode == "direct") {
      return "DIRECT";
    } else if (mode == "custom") {
      return "PROXY $customHost:$customPort; DIRECT";
    } else {
      final detected = detectSystemProxy();
      return detected != null ? "PROXY $detected; DIRECT" : "DIRECT";
    }
  }

  String? detectSystemProxy({bool forceRefresh = false}) {
    if (!forceRefresh && _lastDetectedProxy != null && _lastDetectTime != null) {
      if (DateTime.now().difference(_lastDetectTime!) < const Duration(seconds: 3)) {
        return _lastDetectedProxy;
      }
    }

    final env = Platform.environment;
    final envProxy = env['HTTPS_PROXY'] ?? env['https_proxy'] ?? env['HTTP_PROXY'] ?? env['http_proxy'] ?? env['ALL_PROXY'];
    if (envProxy != null && envProxy.isNotEmpty) {
      final clean = envProxy.replaceAll(RegExp(r'^https?://'), '');
      _lastDetectedProxy = clean;
      _lastDetectTime = DateTime.now();
      return clean;
    }

    if (Platform.isWindows) {
      try {
        final queryEnabled = Process.runSync('reg', [
          'query',
          r'HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings',
          '/v',
          'ProxyEnable',
        ]);
        if (queryEnabled.stdout.toString().contains('0x1')) {
          final queryServer = Process.runSync('reg', [
            'query',
            r'HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings',
            '/v',
            'ProxyServer',
          ]);
          final out = queryServer.stdout.toString();
          final match = RegExp(r'ProxyServer\s+REG_SZ\s+(.+)').firstMatch(out);
          if (match != null) {
            String server = match.group(1)!.trim();
            if (server.contains('https=')) {
              server = RegExp(r'https=([^;]+)').firstMatch(server)?.group(1) ?? server;
            } else if (server.contains('=')) {
              server = server.split('=').last;
            }
            _lastDetectedProxy = server;
            _lastDetectTime = DateTime.now();
            return server;
          }
        }
      } catch (_) {}
    }

    _lastDetectedProxy = null;
    return null;
  }
}

class DynamicHttpOverrides extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) {
    return super.createHttpClient(context)
      ..findProxy = (uri) => AppProxyManager.instance.getProxyString(uri);
  }
}

// ─────────────────────────────────────────────────────────────
// 3. 数据模型：通用发音人与引擎规则
// ─────────────────────────────────────────────────────────────
enum AudioResponseType {
  binaryStream, // 二进制流 (Fish Audio, Edge, 各种反代)
  jsonBase64,   // JSON 中提取 Base64 音频 (小米 MiMo, OpenAI)
  jsonUrl,      // JSON 中提取音频下载链接
  namiAi,       // 纳米AI 专用协议 (带动态时间戳、签名、MID 校验)
}

class TtsVoice {
  String id;
  String name;
  TtsVoice({required this.id, required this.name});

  Map<String, dynamic> toJson() => {'id': id, 'name': name};
  factory TtsVoice.fromJson(Map<String, dynamic> j) => TtsVoice(id: j['id'] ?? '', name: j['name'] ?? '');
}

class CustomTtsEngine {
  String id;
  String name;
  String method;
  String urlTemplate;
  Map<String, String> headers;
  String bodyTemplate;
  AudioResponseType responseType;
  String jsonExtractPath;
  List<TtsVoice> voices;

  CustomTtsEngine({
    required this.id,
    required this.name,
    required this.method,
    required this.urlTemplate,
    required this.headers,
    required this.bodyTemplate,
    required this.responseType,
    required this.jsonExtractPath,
    required this.voices,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'method': method,
        'urlTemplate': urlTemplate,
        'headers': headers,
        'bodyTemplate': bodyTemplate,
        'responseType': responseType.index,
        'jsonExtractPath': jsonExtractPath,
        'voices': voices.map((v) => v.toJson()).toList(),
      };

  factory CustomTtsEngine.fromJson(Map<String, dynamic> j) => CustomTtsEngine(
        id: j['id'] ?? DateTime.now().millisecondsSinceEpoch.toString(),
        name: j['name'] ?? '未命名引擎',
        method: j['method'] ?? 'POST',
        urlTemplate: j['urlTemplate'] ?? '',
        headers: (j['headers'] as Map<String, dynamic>?)?.map((k, v) => MapEntry(k, v.toString())) ?? {},
        bodyTemplate: j['bodyTemplate'] ?? '',
        responseType: AudioResponseType.values[(j['responseType'] ?? 0).clamp(0, AudioResponseType.values.length - 1)],
        jsonExtractPath: j['jsonExtractPath'] ?? '',
        voices: (j['voices'] as List<dynamic>?)?.map((v) => TtsVoice.fromJson(v)).toList() ?? [TtsVoice(id: "default", name: "默认音色")],
      );
}

// ─────────────────────────────────────────────────────────────
// 4. 纳米AI (bot.n.cn) 动态签名算法生成器
// ─────────────────────────────────────────────────────────────
class NamiSigner {
  static String _mid = "";

  static String _md5Str(String text) {
    return md5.convert(utf8.encode(text)).toString();
  }

  static String getMid() {
    if (_mid.isNotEmpty) return _mid;
    final seed = "${DateTime.now().millisecondsSinceEpoch}_${Platform.localHostname}_nami";
    _mid = _md5Str(seed);
    return _mid;
  }

  static String getISO8601Time() {
    final now = DateTime.now();
    final y = now.year.toString().padLeft(4, '0');
    final m = now.month.toString().padLeft(2, '0');
    final d = now.day.toString().padLeft(2, '0');
    final h = now.hour.toString().padLeft(2, '0');
    final min = now.minute.toString().padLeft(2, '0');
    final s = now.second.toString().padLeft(2, '0');
    return "$y-$m-${d}T$h:$min:$s+08:00";
  }

  static Map<String, String> generateHeaders({Map<String, String>? extraHeaders}) {
    const ua = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/117.0.0.0 Safari/537.36";
    const device = "Web";
    const ver = "1.2";
    final time = getISO8601Time();
    final mid = getMid();
    final zmUa = _md5Str(ua);
    final zmToken = _md5Str("$device$time$ver$mid$zmUa");

    final h = <String, String>{
      'Content-Type': 'application/x-www-form-urlencoded',
      'device-platform': device,
      'timestamp': time,
      'access-token': mid,
      'zm-token': zmToken,
      'zm-ver': ver,
      'zm-ua': zmUa,
      'func-ver': '1',
      'nami-platform': 'web',
      'mid': mid,
      'sid': mid,
      'User-Agent': ua,
    };

    if (extraHeaders != null) {
      if (extraHeaders.containsKey('Cookie') && extraHeaders['Cookie']!.isNotEmpty) {
        h['Cookie'] = extraHeaders['Cookie']!;
      }
      if (extraHeaders.containsKey('Auth-Token') && extraHeaders['Auth-Token']!.isNotEmpty) {
        h['Auth-Token'] = extraHeaders['Auth-Token']!;
      }
    }

    return h;
  }
}

// ─────────────────────────────────────────────────────────────
// 5. 通用 TTS 请求派发器 (纯内存流转，绝不落盘)
// ─────────────────────────────────────────────────────────────
class UniversalTtsExecutor {
  static Future<Uint8List> synthesize({
    required CustomTtsEngine engine,
    required String text,
    required String voiceId,
    required double speed,
    required int bitrate,
  }) async {
    LogManager.instance.log("EXEC", "调用引擎 [${engine.name}]，发音人: $voiceId，字数: ${text.length}");

    // ── 模式 1：纳米AI (bot.n.cn) 动态签名协议 ──
    if (engine.responseType == AudioResponseType.namiAi) {
      final role = voiceId.isNotEmpty ? voiceId : 'DeepSeek';
      final url = Uri.parse("https://bot.n.cn/api/tts/v1?roleid=$role");
      final headers = NamiSigner.generateHeaders(extraHeaders: engine.headers);
      final body = "text=${Uri.encodeQueryComponent(text)}&audio_type=mp3&format=stream&ttsIndex=0";

      final res = await http.post(url, headers: headers, body: body).timeout(const Duration(seconds: 35));

      final contentType = res.headers['content-type'] ?? '';
      if (contentType.toLowerCase().contains('json')) {
        try {
          final errJson = jsonDecode(utf8.decode(res.bodyBytes));
          throw Exception("纳米AI服务器拦截: code=${errJson['code']}, msg=${errJson['msg']}");
        } catch (e) {
          if (e.toString().contains("纳米AI服务器拦截")) rethrow;
          throw Exception("纳米AI返回异常: ${utf8.decode(res.bodyBytes)}");
        }
      }

      if (res.statusCode != 200 || res.bodyBytes.isEmpty) {
        throw Exception("纳米AI请求失败 (HTTP ${res.statusCode})");
      }
      LogManager.instance.log("RAM", "纳米AI音频已入内存 (${(res.bodyBytes.lengthInBytes / 1024).toStringAsFixed(1)} KB)");
      return res.bodyBytes;
    }

    // ── 模式 2：通用规则替换协议 (Fish Audio, MiMo, Cloudflare等) ──
    String replaceVars(String input, {bool isUrl = false}) {
      final safeText = isUrl ? Uri.encodeComponent(text) : jsonEncode(text).replaceFirst(RegExp(r'^"'), '').replaceFirst(RegExp(r'"$'), '');
      return input
          .replaceAll('{{text}}', safeText)
          .replaceAll('{{voice}}', voiceId)
          .replaceAll('{{speed}}', speed.toStringAsFixed(2))
          .replaceAll('{{bitrate}}', bitrate.toString());
    }

    final targetUrl = Uri.parse(replaceVars(engine.urlTemplate, isUrl: true));
    final processedHeaders = <String, String>{};
    engine.headers.forEach((k, v) => processedHeaders[k] = replaceVars(v));

    http.Response res;
    try {
      if (engine.method.toUpperCase() == 'POST') {
        res = await http.post(targetUrl, headers: processedHeaders, body: replaceVars(engine.bodyTemplate)).timeout(const Duration(seconds: 35));
      } else {
        res = await http.get(targetUrl, headers: processedHeaders).timeout(const Duration(seconds: 35));
      }
    } catch (e) {
      throw Exception("网络连接超时或断开 ($e)。\n提示：海外直连请检查顶部【🌐 代理设置】！");
    }

    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw Exception("HTTP ${res.statusCode}: ${utf8.decode(res.bodyBytes, allowMalformed: true)}");
    }

    switch (engine.responseType) {
      case AudioResponseType.binaryStream:
        if (res.bodyBytes.isEmpty) throw Exception("接口返回空数据");
        LogManager.instance.log("RAM", "二进制流已进入内存 (${(res.bodyBytes.lengthInBytes / 1024).toStringAsFixed(1)} KB)");
        return res.bodyBytes;

      case AudioResponseType.jsonBase64:
        final jsonObj = jsonDecode(utf8.decode(res.bodyBytes));
        final b64 = _extractByPath(jsonObj, engine.jsonExtractPath);
        if (b64 == null || b64 is! String || b64.isEmpty) {
          throw Exception("无法从 JSON [${engine.jsonExtractPath}] 提取 Base64 音频");
        }
        return base64Decode(b64.replaceAll(RegExp(r'\s+'), ''));

      case AudioResponseType.jsonUrl:
        final jsonObj = jsonDecode(utf8.decode(res.bodyBytes));
        final audioUrl = _extractByPath(jsonObj, engine.jsonExtractPath);
        if (audioUrl == null || audioUrl is! String || audioUrl.isEmpty) {
          throw Exception("无法从 JSON 提取音频下载 URL");
        }
        final dl = await http.get(Uri.parse(audioUrl));
        return dl.bodyBytes;

      default:
        return res.bodyBytes;
    }
  }

  static dynamic _extractByPath(dynamic root, String path) {
    if (path.trim().isEmpty) return root;
    dynamic current = root;
    for (var seg in path.split('.')) {
      if (seg.contains('[') && seg.endsWith(']')) {
        final key = seg.substring(0, seg.indexOf('['));
        final idx = int.tryParse(seg.substring(seg.indexOf('[') + 1, seg.length - 1)) ?? 0;
        if (key.isNotEmpty) current = current[key];
        current = current[idx];
      } else {
        current = current[seg];
      }
      if (current == null) return null;
    }
    return current;
  }
}

// ─────────────────────────────────────────────────────────────
// 6. 默认预设引擎集合 (开箱即用)
// ─────────────────────────────────────────────────────────────
class DefaultEnginePresets {
  static List<CustomTtsEngine> get() {
    return [
      // 1. 纳米AI 原生集成
      CustomTtsEngine(
        id: "nami_ai_preset",
        name: "纳米AI (无需Key/免密)",
        method: "POST",
        urlTemplate: "https://bot.n.cn/api/tts/v1?roleid={{voice}}",
        headers: {
          "Cookie": "",      // 可选：填入登录后的 Cookie
          "Auth-Token": "",  // 可选：填入 Auth-Token
        },
        bodyTemplate: "",
        responseType: AudioResponseType.namiAi,
        jsonExtractPath: "",
        voices: [
          TtsVoice(id: "DeepSeek", name: "DeepSeek (深思沉稳)"),
          TtsVoice(id: "默认", name: "纳米默认 (自然旁白)"),
          TtsVoice(id: "智囊", name: "智囊角色 (知性清晰)"),
          TtsVoice(id: "小艾", name: "小艾 (温柔甜美)"),
          TtsVoice(id: "小楠", name: "小楠 (青年活力)"),
        ],
      ),

      // 2. Cloudflare 中转
      CustomTtsEngine(
        id: "cf_worker_template",
        name: "Cloudflare 中转引擎 (国内直连)",
        method: "GET",
        urlTemplate: "https://xxx.xxx.CF地址xxx.xxx/tts?token=你的访问密码&text={{text}}&voice={{voice}}&speed={{speed}}&bitrate={{bitrate}}",
        headers: {},
        bodyTemplate: "",
        responseType: AudioResponseType.binaryStream,
        jsonExtractPath: "",
        voices: [
          TtsVoice(id: "a688f2129bea41d1ae6042462892ecf8", name: "通用小说男声"),
          TtsVoice(id: "cf71d823861b4e0eadff1672d646da36", name: "几何知性女声"),
        ],
      ),

      // 3. Fish Audio 官方直连
      CustomTtsEngine(
        id: "fish_audio_official",
        name: "Fish.Audio 官方直连 (需填Key)",
        method: "POST",
        urlTemplate: "https://api.fish.audio/v1/tts",
        headers: {
          "Authorization": "Bearer 填入你的FishAudio密钥",
          "Content-Type": "application/json",
          "model": "s2.1-pro-free"
        },
        bodyTemplate: jsonEncode({
          "text": "{{text}}",
          "reference_id": "{{voice}}",
          "format": "mp3",
          "mp3_bitrate": 64,
          "chunk_length": 100,
          "latency": "balanced",
          "prosody": {"speed": "{{speed}}"}
        }).replaceAll('"{{speed}}"', '{{speed}}'),
        responseType: AudioResponseType.binaryStream,
        jsonExtractPath: "",
        voices: [
          TtsVoice(id: "a688f2129bea41d1ae6042462892ecf8", name: "通用男声"),
        ],
      ),

      // 4. 小米 MiMo-TTS
      CustomTtsEngine(
        id: "mimo_official",
        name: "小米 MiMo-TTS (需填Key)",
        method: "POST",
        urlTemplate: "https://api.xiaomimimo.com/v1/chat/completions",
        headers: {
          "Authorization": "Bearer 填入你的MIMO密钥",
          "Content-Type": "application/json"
        },
        bodyTemplate: jsonEncode({
          "model": "mimo-v2.5-tts",
          "messages": [
            {"role": "user", "content": "请以自然清晰的语速朗读"},
            {"role": "assistant", "content": "{{text}}"}
          ],
          "audio": {"voice": "{{voice}}", "format": "mp3"}
        }),
        responseType: AudioResponseType.jsonBase64,
        jsonExtractPath: "choices[0].message.audio.data",
        voices: [
          TtsVoice(id: "茉莉", name: "茉莉 (知性成熟)"),
          TtsVoice(id: "冰糖", name: "冰糖 (清甜少女)"),
          TtsVoice(id: "苏打", name: "苏打 (活力青年)"),
          TtsVoice(id: "白桦", name: "白桦 (磁性低沉)"),
        ],
      ),
    ];
  }
}
