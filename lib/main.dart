import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:audioplayers/audioplayers.dart';
import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_picker/file_picker.dart';

// ─────────────────────────────────────────────────────────────
// 1. 全动态代理管理器 (自动探测 Windows 系统代理 / 自定义 / 纯直连)
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
      ..findProxy = (uri) {
        return AppProxyManager.instance.getProxyString(uri);
      };
  }
}

void main() {
  HttpOverrides.global = DynamicHttpOverrides();
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const TtsReaderApp());
}

// ─────────────────────────────────────────────────────────────
// 2. 日志管理系统
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
// 3. 通用自定义 TTS 引擎数据结构
// ─────────────────────────────────────────────────────────────
enum AudioResponseType { binaryStream, jsonBase64, jsonUrl }

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
        responseType: AudioResponseType.values[j['responseType'] ?? 0],
        jsonExtractPath: j['jsonExtractPath'] ?? '',
        voices: (j['voices'] as List<dynamic>?)?.map((v) => TtsVoice.fromJson(v)).toList() ?? [TtsVoice(id: "default", name: "默认音色")],
      );
}

// ─────────────────────────────────────────────────────────────
// 4. 通用 TTS 执行器 (内存流控)
// ─────────────────────────────────────────────────────────────
class UniversalTtsExecutor {
  static Future<Uint8List> synthesize({
    required CustomTtsEngine engine,
    required String text,
    required String voiceId,
    required double speed,
    required int bitrate,
  }) async {
    LogManager.instance.log("EXEC", "调用引擎 [${engine.name}]，发音人: $voiceId，目标倍速: ${speed.toStringAsFixed(2)}x");

    String replaceVars(String input, {bool isUrl = false}) {
      final safeText = isUrl ? Uri.encodeComponent(text) : jsonEncode(text).replaceFirst(RegExp(r'^"'), '').replaceFirst(RegExp(r'"$'), '');
      return input
          .replaceAll('{{text}}', safeText)
          .replaceAll('{{voice}}', voiceId)
          .replaceAll('{{speed}}', speed.toStringAsFixed(2)) // 真实动态替换语速
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
      throw Exception("网络连接超时或断开 ($e)。\n提示：若访问海外直连，请检查顶部【🌐 代理设置】！");
    }

    if (res.statusCode < 200 || res.statusCode >= 300) {
      final errBody = utf8.decode(res.bodyBytes, allowMalformed: true);
      throw Exception("HTTP ${res.statusCode}: $errBody");
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
          throw Exception("无法从 JSON 路径 [${engine.jsonExtractPath}] 提取 Base64 音频");
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
// 5. 主程序与 UI 交互
// ─────────────────────────────────────────────────────────────
class TtsReaderApp extends StatelessWidget {
  const TtsReaderApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '万能 TTS 朗读与发音人评测工具 (真正物理倍速版)',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple),
        useMaterial3: true,
      ),
      home: const ReaderHomePage(),
    );
  }
}

class ReaderHomePage extends StatefulWidget {
  const ReaderHomePage({super.key});

  @override
  State<ReaderHomePage> createState() => _ReaderHomePageState();
}

class _ReaderHomePageState extends State<ReaderHomePage> {
  final TextEditingController _textController = TextEditingController();
  final ScrollController _logScrollController = ScrollController();
  final AudioPlayer _audioPlayer = AudioPlayer();

  late List<CustomTtsEngine> _engines;
  late CustomTtsEngine _currentEngine;
  late TtsVoice _currentVoice;

  double _speed = 1.75;
  int _bitrate = 64;
  int _preloadCount = 4;
  int _concurrency = 2;
  int _sentenceGapMs = 250;

  List<String> _sentences = [];
  int _currentSentenceIndex = -1;
  bool _isPlaying = false;
  bool _isPaused = false;
  int _playSessionId = 0;

  final Map<int, Uint8List> _ramAudioCache = {};
  final Set<int> _inFlightFetches = {};

  @override
  void initState() {
    super.initState();
    _loadConfig();
    _initAudioPlayer();
  }

  File get _localConfigFile => File('tts_config.json');

  void _loadConfig() {
    try {
      if (_localConfigFile.existsSync()) {
        final content = _localConfigFile.readAsStringSync();
        final Map<String, dynamic> data = jsonDecode(content);
        _speed = (data['speed'] as num?)?.toDouble() ?? 1.75;
        _bitrate = data['bitrate'] ?? 64;
        _preloadCount = data['preloadCount'] ?? 4;
        _concurrency = data['concurrency'] ?? 2;
        _sentenceGapMs = data['sentenceGapMs'] ?? 250;

        AppProxyManager.instance.mode = data['proxyMode'] ?? "auto";
        AppProxyManager.instance.customHost = data['proxyHost'] ?? "127.0.0.1";
        AppProxyManager.instance.customPort = data['proxyPort'] ?? 7890;

        final list = (data['engines'] as List<dynamic>?)?.map((e) => CustomTtsEngine.fromJson(e)).toList();
        if (list != null && list.isNotEmpty) {
          _engines = list;
          _currentEngine = _engines.first;
          _currentVoice = _currentEngine.voices.isNotEmpty ? _currentEngine.voices.first : TtsVoice(id: '', name: '默认');
          LogManager.instance.log("CONFIG", "已自动加载本地持久化设置 tts_config.json");
          return;
        }
      }
    } catch (e) {
      LogManager.instance.log("CONFIG-ERR", "加载本地配置失败: $e，启用内置预设");
    }
    _initDefaultEngines();
  }

  void _saveConfig() {
    try {
      final data = {
        'speed': _speed,
        'bitrate': _bitrate,
        'preloadCount': _preloadCount,
        'concurrency': _concurrency,
        'sentenceGapMs': _sentenceGapMs,
        'proxyMode': AppProxyManager.instance.mode,
        'proxyHost': AppProxyManager.instance.customHost,
        'proxyPort': AppProxyManager.instance.customPort,
        'engines': _engines.map((e) => e.toJson()).toList(),
      };
      _localConfigFile.writeAsStringSync(const JsonEncoder.withIndent("  ").convert(data));
      LogManager.instance.log("CONFIG", "配置已保存至本地 tts_config.json");
    } catch (e) {
      LogManager.instance.log("CONFIG-ERR", "自动保存失败: $e");
    }
  }

  void _initDefaultEngines() {
    _engines = [
      CustomTtsEngine(
        id: "cf_worker_template",
        name: "Cloudflare 中转引擎 (国内直连)",
        method: "GET",
        // 关键修复：URL 动态透传 speed
        urlTemplate: "https://tts.yzwww.ggff.net/tts?token=你的访问密码&text={{text}}&voice={{voice}}&speed={{speed}}&bitrate={{bitrate}}",
        headers: {},
        bodyTemplate: "",
        responseType: AudioResponseType.binaryStream,
        jsonExtractPath: "",
        voices: [
          TtsVoice(id: "a688f2129bea41d1ae6042462892ecf8", name: "通用小说男声"),
          TtsVoice(id: "cf71d823861b4e0eadff1672d646da36", name: "几何知性女声"),
        ],
      ),
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
        // 关键修复：将硬编码的 1.75 彻底替换为动态占位符 {{speed}}
        bodyTemplate: jsonEncode({
          "text": "{{text}}",
          "reference_id": "{{voice}}",
          "format": "mp3",
          "mp3_bitrate": 64,
          "chunk_length": 100,
          "latency": "balanced",
          "prosody": {"speed": "{{speed}}"}
        }).replaceAll('"{{speed}}"', '{{speed}}'), // 输出为数字而非字符串
        responseType: AudioResponseType.binaryStream,
        jsonExtractPath: "",
        voices: [
          TtsVoice(id: "a688f2129bea41d1ae6042462892ecf8", name: "通用男声"),
        ],
      ),
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
            {"role": "user", "content": "请以约 {{speed}} 倍速快节奏朗读，声音清晰自然"},
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
    _currentEngine = _engines.first;
    _currentVoice = _currentEngine.voices.first;
  }

  // ──────────────── 全局网络代理配置弹窗 ────────────────
  void _openProxySettingsDialog() {
    final hostCtrl = TextEditingController(text: AppProxyManager.instance.customHost);
    final portCtrl = TextEditingController(text: AppProxyManager.instance.customPort.toString());
    String currentMode = AppProxyManager.instance.mode;

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDlgState) {
          final detected = AppProxyManager.instance.detectSystemProxy(forceRefresh: true);

          return AlertDialog(
            title: const Row(
              children: [
                Icon(Icons.lan, color: Colors.deepPurple),
                SizedBox(width: 8),
                Text("全局网络与代理配置", style: TextStyle(fontWeight: FontWeight.bold)),
              ],
            ),
            content: SizedBox(
              width: 500,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text("选择软件请求海外 API 时采用的网络路由模式：", style: TextStyle(fontSize: 12, color: Colors.grey)),
                  const SizedBox(height: 12),
                  RadioListTile<String>(
                    value: "auto",
                    groupValue: currentMode,
                    title: const Text("🟢 自动检测系统代理 (自适应任意软件端口)", style: TextStyle(fontWeight: FontWeight.bold)),
                    subtitle: Text(
                      detected != null ? "已自动嗅探到当前 Windows 生效代理：$detected" : "未检测到系统代理（若开启了代理软件，请确认开启【系统代理】开关）",
                      style: TextStyle(color: detected != null ? Colors.green.shade700 : Colors.orange.shade800, fontSize: 11),
                    ),
                    onChanged: (v) => setDlgState(() => currentMode = v!),
                  ),
                  RadioListTile<String>(
                    value: "custom",
                    groupValue: currentMode,
                    title: const Text("🟡 自定义代理端口 (完全自主掌控)", style: TextStyle(fontWeight: FontWeight.bold)),
                    subtitle: const Text("自由输入 IP 与端口 (支持 Clash 7890、v2rayN 10809、SS 1080 等)", style: TextStyle(fontSize: 11)),
                    onChanged: (v) => setDlgState(() => currentMode = v!),
                  ),
                  if (currentMode == "custom")
                    Padding(
                      padding: const EdgeInsets.only(left: 28, right: 16, top: 6, bottom: 6),
                      child: Row(
                        children: [
                          Expanded(
                            flex: 3,
                            child: TextField(controller: hostCtrl, decoration: const InputDecoration(labelText: "代理 IP", isDense: true, border: OutlineInputBorder())),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            flex: 2,
                            child: TextField(controller: portCtrl, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: "端口", isDense: true, border: OutlineInputBorder())),
                          ),
                        ],
                      ),
                    ),
                  RadioListTile<String>(
                    value: "direct",
                    groupValue: currentMode,
                    title: const Text("🔴 纯直连模式 (不使用代理)", style: TextStyle(fontWeight: FontWeight.bold)),
                    subtitle: const Text("适合已开启 TUN 虚拟网卡，或使用 Cloudflare 中转域名的用户", style: TextStyle(fontSize: 11)),
                    onChanged: (v) => setDlgState(() => currentMode = v!),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx), child: const Text("取消")),
              ElevatedButton(
                onPressed: () {
                  AppProxyManager.instance.mode = currentMode;
                  AppProxyManager.instance.customHost = hostCtrl.text.trim();
                  AppProxyManager.instance.customPort = int.tryParse(portCtrl.text.trim()) ?? 7890;
                  _saveConfig();
                  Navigator.pop(ctx);
                  LogManager.instance.log("PROXY", "代理已切换为: $currentMode (${AppProxyManager.instance.getProxyString(Uri())})");
                },
                child: const Text("保存并立即生效"),
              ),
            ],
          );
        },
      ),
    );
  }

  // ──────────────── 音频解码播放 (核心修复：物理倍速注入) ────────────────
  Future<void> _playAudioFromRam(Uint8List bytes) async {
    try {
      await _audioPlayer.stop();
      await _audioPlayer.setVolume(1.0);
      
      // 关键修复 1：在启动音频前，将播放器底层倍速强制同步为设定语速
      await _audioPlayer.setPlaybackRate(_speed);
      await _audioPlayer.play(BytesSource(bytes, mimeType: 'audio/mpeg'));
      // 关键修复 2：Windows Media Foundation 加载数据后，再次锚定倍速，确保 100% 硬件变速
      await _audioPlayer.setPlaybackRate(_speed);
      
      LogManager.instance.log("AUDIO", "扬声器正在以真实 [${_speed.toStringAsFixed(2)}x] 语速物理播放音频");
    } catch (e) {
      final dataUri = Uri.dataFromBytes(bytes, mimeType: 'audio/mpeg').toString();
      await _audioPlayer.setPlaybackRate(_speed);
      await _audioPlayer.play(UrlSource(dataUri));
      await _audioPlayer.setPlaybackRate(_speed);
    }
  }

  void _initAudioPlayer() {
    _audioPlayer.onPlayerComplete.listen((_) async {
      if (!_isPlaying || _isPaused) return;
      await Future.delayed(Duration(milliseconds: _sentenceGapMs));
      if (!_isPlaying || _isPaused) return;

      if (_currentSentenceIndex + 1 < _sentences.length) {
        setState(() => _currentSentenceIndex++);
        _playCurrentSentence();
      } else {
        _stopPlayback("全文朗读已全部完成！");
      }
    });
  }

  @override
  void dispose() {
    _audioPlayer.dispose();
    _textController.dispose();
    _logScrollController.dispose();
    super.dispose();
  }

  // ──────────────── 发音人试听 ────────────────
  Future<void> _previewVoice(CustomTtsEngine engine, TtsVoice voice) async {
    LogManager.instance.log("PREVIEW", "正在以 [${_speed.toStringAsFixed(2)}x] 倍速试听发音人: [${voice.name}]...");
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("正在生成 [${voice.name}] 的试听音频..."), duration: const Duration(seconds: 2)));

    try {
      final bytes = await UniversalTtsExecutor.synthesize(
        engine: engine,
        text: "你好，这是一条试听语音。正在验证发音人：${voice.name} 在当前倍速下的发音效果。",
        voiceId: voice.id,
        speed: _speed,
        bitrate: _bitrate,
      );
      await _playAudioFromRam(bytes);
    } catch (e) {
      LogManager.instance.log("PREVIEW-ERR", "试听失败: $e");
      if (mounted) {
        showDialog(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text("❌ 试听失败"),
            content: Text("错误原因：\n$e\n\n排查建议：\n1. 海外官方直连请检查顶部【🌐】代理设置；\n2. 检查 API Key 或密码。"),
            actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text("好"))],
          ),
        );
      }
    }
  }

  // ──────────────── 引擎连通性测试 ────────────────
  Future<void> _testEngineConnectivity(CustomTtsEngine engine) async {
    final sw = Stopwatch()..start();
    LogManager.instance.log("PING", "正在对引擎 [${engine.name}] 进行连通性测试...");

    try {
      final voiceId = engine.voices.isNotEmpty ? engine.voices.first.id : "default";
      final bytes = await UniversalTtsExecutor.synthesize(
        engine: engine,
        text: "网络连通性测试成功，语音合成服务正常！",
        voiceId: voiceId,
        speed: _speed,
        bitrate: 64,
      );
      sw.stop();
      await _playAudioFromRam(bytes);

      if (mounted) {
        showDialog(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text("🎉 连通性测试成功！"),
            content: Text(
              "• 引擎名称: ${engine.name}\n"
              "• 网络往返耗时: ${(sw.elapsedMilliseconds / 1000).toStringAsFixed(2)} 秒\n"
              "• 音频体积: ${(bytes.lengthInBytes / 1024).toStringAsFixed(1)} KB\n"
              "• 播放倍速: ${_speed.toStringAsFixed(2)}x\n"
              "• 当前代理状态: ${AppProxyManager.instance.getProxyString(Uri())}\n\n"
              "扬声器已播放试听音频，能听到声音且倍速明显加快说明一切正常！",
            ),
            actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text("确定"))],
          ),
        );
      }
    } catch (e) {
      sw.stop();
      LogManager.instance.log("PING-ERR", "测试失败: $e");
      if (mounted) {
        showDialog(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text("❌ 连通性测试失败"),
            content: Text("错误详情：\n$e\n\n排查指南：\n• 如果提示超时，请点击顶栏【🌐】切换代理端口或自动检测；\n• 如果提示 401，请检查密钥是否填写正确。"),
            actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text("知道了"))],
          ),
        );
      }
    }
  }

  // ──────────────── 朗读管线 ────────────────
  void _splitSentences() {
    final text = _textController.text;
    if (text.trim().isEmpty) {
      _sentences = [];
      return;
    }
    final regex = RegExp(r'[^。！？；\n\r]*[。！？；…]+|[^。！？；\n\r]+');
    _sentences = regex
        .allMatches(text)
        .map((m) => m.group(0)!.trim())
        .where((s) => s.isNotEmpty && RegExp(r'[\w\u4e00-\u9fa5]').hasMatch(s))
        .toList();
    LogManager.instance.log("TEXT", "文本已切分为 ${_sentences.length} 句");
  }

  void _schedulePreload(int currentIndex, int sessionId) {
    if (sessionId != _playSessionId) return;
    final targetEnd = (currentIndex + _preloadCount + 1).clamp(0, _sentences.length);
    for (int i = currentIndex; i < targetEnd; i++) {
      if (_ramAudioCache.containsKey(i) || _inFlightFetches.contains(i)) continue;
      if (_inFlightFetches.length >= _concurrency) break;
      _fetchToRam(i, sessionId);
    }
  }

  Future<void> _fetchToRam(int index, int sessionId) async {
    _inFlightFetches.add(index);
    try {
      final audioBytes = await UniversalTtsExecutor.synthesize(
        engine: _currentEngine,
        text: _sentences[index],
        voiceId: _currentVoice.id,
        speed: _speed,
        bitrate: _bitrate,
      );
      if (sessionId == _playSessionId) {
        _ramAudioCache[index] = audioBytes;
      }
    } catch (e) {
      LogManager.instance.log("ERROR", "第 ${index + 1} 句拉取失败: $e");
    } finally {
      _inFlightFetches.remove(index);
      if (_isPlaying && sessionId == _playSessionId) {
        _schedulePreload(_currentSentenceIndex, sessionId);
      }
    }
  }

  Future<void> _playCurrentSentence() async {
    final idx = _currentSentenceIndex;
    final sessionId = _playSessionId;
    _schedulePreload(idx, sessionId);

    int waitCounter = 0;
    while (!_ramAudioCache.containsKey(idx)) {
      if (!_isPlaying || sessionId != _playSessionId) return;
      if (!_inFlightFetches.contains(idx)) _fetchToRam(idx, sessionId);
      await Future.delayed(const Duration(milliseconds: 60));
      waitCounter++;
      if (waitCounter > 300) {
        _stopPlayback("第 ${idx + 1} 句加载超时中断");
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            backgroundColor: Colors.red,
            content: Text("朗读中断：未能获取到音频。请点击右上角【🌐】检查代理或查看日志！"),
          ));
        }
        return;
      }
    }

    if (!_isPlaying || sessionId != _playSessionId) return;
    await _playAudioFromRam(_ramAudioCache[idx]!);
  }

  void _startPlayback() {
    if (_textController.text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("请先输入或拖入小说文本！")));
      return;
    }
    _splitSentences();
    if (_sentences.isEmpty) return;

    _playSessionId++;
    _ramAudioCache.clear();
    _inFlightFetches.clear();

    setState(() {
      _isPlaying = true;
      _isPaused = false;
      _currentSentenceIndex = 0;
    });

    _playCurrentSentence();
  }

  void _togglePause() {
    if (!_isPlaying) return;
    setState(() => _isPaused = !_isPaused);
    if (_isPaused) {
      _audioPlayer.pause();
      LogManager.instance.log("CTRL", "朗读已暂停");
    } else {
      _audioPlayer.resume();
      LogManager.instance.log("CTRL", "朗读已恢复");
    }
  }

  void _stopPlayback([String? reason]) {
    _playSessionId++;
    _audioPlayer.stop();
    setState(() {
      _isPlaying = false;
      _isPaused = false;
      _currentSentenceIndex = -1;
    });
    _ramAudioCache.clear();
    _inFlightFetches.clear();
    LogManager.instance.log("CTRL", reason ?? "朗读停止");
  }

  Future<void> _exportAudio() async {
    if (_textController.text.trim().isEmpty) return;
    final savePath = await FilePicker.platform.saveFile(
      dialogTitle: '选择保存音频文件',
      fileName: 'TTS_Export_${DateTime.now().millisecondsSinceEpoch}.mp3',
      type: FileType.custom,
      allowedExtensions: ['mp3'],
    );
    if (savePath == null) return;

    _splitSentences();
    final exportBytes = BytesBuilder();
    for (int i = 0; i < _sentences.length; i++) {
      try {
        final b = await UniversalTtsExecutor.synthesize(
          engine: _currentEngine,
          text: _sentences[i],
          voiceId: _currentVoice.id,
          speed: _speed,
          bitrate: _bitrate,
        );
        exportBytes.add(b);
      } catch (e) {
        LogManager.instance.log("EXPORT-ERR", "第 ${i + 1} 句失败: $e");
      }
    }
    await File(savePath).writeAsBytes(exportBytes.toBytes());
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("音频已成功导出至：$savePath")));
  }

  // ──────────────── 引擎管理弹窗 ────────────────
  void _openEngineManagerDialog() {
    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDlgState) => AlertDialog(
          title: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text("⚙️ TTS 引擎管理与自由定义", style: TextStyle(fontWeight: FontWeight.bold)),
              ElevatedButton.icon(
                icon: const Icon(Icons.add, size: 16),
                label: const Text("新增引擎"),
                onPressed: () async {
                  final newEngine = await _showEditEngineDialog();
                  if (newEngine != null) {
                    setDlgState(() {
                      _engines.add(newEngine);
                      _currentEngine = newEngine;
                      _currentVoice = newEngine.voices.first;
                    });
                    _saveConfig();
                    setState(() {});
                  }
                },
              ),
            ],
          ),
          content: SizedBox(
            width: 740,
            height: 460,
            child: ListView.separated(
              itemCount: _engines.length,
              separatorBuilder: (_, __) => const Divider(),
              itemBuilder: (c, idx) {
                final eng = _engines[idx];
                return ListTile(
                  title: Text(eng.name, style: const TextStyle(fontWeight: FontWeight.bold)),
                  subtitle: Text("${eng.method}  |  ${eng.urlTemplate}\n发音人: ${eng.voices.map((v) => v.name).join(', ')}"),
                  isThreeLine: true,
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        icon: const Icon(Icons.network_check, color: Colors.teal),
                        tooltip: "测试该引擎连通性与倍速发声",
                        onPressed: () => _testEngineConnectivity(eng),
                      ),
                      IconButton(
                        icon: const Icon(Icons.edit, color: Colors.blue),
                        tooltip: "编辑规则与发音人",
                        onPressed: () async {
                          final updated = await _showEditEngineDialog(existing: eng);
                          if (updated != null) {
                            setDlgState(() {
                              _engines[idx] = updated;
                              if (_currentEngine.id == eng.id) _currentEngine = updated;
                            });
                            _saveConfig();
                            setState(() {});
                          }
                        },
                      ),
                      IconButton(
                        icon: const Icon(Icons.delete, color: Colors.red),
                        tooltip: "删除引擎",
                        onPressed: _engines.length <= 1 ? null : () {
                          setDlgState(() {
                            _engines.removeAt(idx);
                            if (_currentEngine.id == eng.id) _currentEngine = _engines.first;
                          });
                          _saveConfig();
                          setState(() {});
                        },
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
          actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text("关闭"))],
        ),
      ),
    );
  }

  Future<CustomTtsEngine?> _showEditEngineDialog({CustomTtsEngine? existing}) async {
    final nameCtrl = TextEditingController(text: existing?.name ?? "自定义 TTS 引擎");
    final urlCtrl = TextEditingController(text: existing?.urlTemplate ?? "https://api.your-tts.com/v1/tts");
    final headersCtrl = TextEditingController(
      text: existing != null ? const JsonEncoder.withIndent("  ").convert(existing.headers) : '{\n  "Authorization": "Bearer 密钥",\n  "Content-Type": "application/json"\n}',
    );
    final bodyCtrl = TextEditingController(
      text: existing?.bodyTemplate ?? '{\n  "text": "{{text}}",\n  "voice": "{{voice}}",\n  "speed": {{speed}}\n}',
    );
    final jsonPathCtrl = TextEditingController(text: existing?.jsonExtractPath ?? "");

    String method = existing?.method ?? "POST";
    AudioResponseType respType = existing?.responseType ?? AudioResponseType.binaryStream;
    List<TtsVoice> voices = List.from(existing?.voices ?? [TtsVoice(id: "default", name: "默认音色")]);

    return showDialog<CustomTtsEngine>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSubState) => AlertDialog(
          title: Text(existing == null ? "新增自定义 TTS 引擎" : "编辑规则: ${existing.name}"),
          content: SizedBox(
            width: 700,
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  TextField(controller: nameCtrl, decoration: const InputDecoration(labelText: "引擎名称")),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      DropdownButton<String>(
                        value: method,
                        items: ["POST", "GET"].map((m) => DropdownMenuItem(value: m, child: Text(m))).toList(),
                        onChanged: (v) => setSubState(() => method = v ?? "POST"),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: TextField(
                          controller: urlCtrl,
                          decoration: const InputDecoration(labelText: "接口 URL (支持 {{text}}, {{voice}}, {{speed}} 占位符)"),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  const Text("请求头 Headers (JSON 格式):", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
                  TextField(controller: headersCtrl, maxLines: 4, decoration: const InputDecoration(border: OutlineInputBorder())),
                  const SizedBox(height: 10),
                  const Text("请求体 Body 模板 (POST 时生效):", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
                  TextField(controller: bodyCtrl, maxLines: 4, decoration: const InputDecoration(border: OutlineInputBorder())),
                  const SizedBox(height: 10),
                  const Text("音频响应解析格式:", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
                  DropdownButton<AudioResponseType>(
                    value: respType,
                    isExpanded: true,
                    items: const [
                      DropdownMenuItem(value: AudioResponseType.binaryStream, child: Text("直接返回二进制音频流 (如 Fish.audio, Edge, 通用中转代理)")),
                      DropdownMenuItem(value: AudioResponseType.jsonBase64, child: Text("从 JSON 中提取 Base64 音频 (如 小米 MiMo, OpenAI)")),
                      DropdownMenuItem(value: AudioResponseType.jsonUrl, child: Text("从 JSON 中提取音频下载链接 URL")),
                    ],
                    onChanged: (t) => setSubState(() => respType = t ?? AudioResponseType.binaryStream),
                  ),
                  if (respType != AudioResponseType.binaryStream) ...[
                    const SizedBox(height: 8),
                    TextField(controller: jsonPathCtrl, decoration: const InputDecoration(labelText: "JSON 音频提取路径", border: OutlineInputBorder())),
                  ],
                  const Divider(height: 25),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text("发音人列表 (支持试听与管理):", style: TextStyle(fontWeight: FontWeight.bold)),
                      ElevatedButton.icon(
                        icon: const Icon(Icons.add, size: 16),
                        label: const Text("添加发音人"),
                        onPressed: () async {
                          final v = await _showAddVoiceDialog();
                          if (v != null) setSubState(() => voices.add(v));
                        },
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Container(
                    height: 120,
                    decoration: BoxDecoration(border: Border.all(color: Colors.grey.shade300), borderRadius: BorderRadius.circular(6)),
                    child: ListView.builder(
                      itemCount: voices.length,
                      itemBuilder: (c, i) => ListTile(
                        dense: true,
                        title: Text(voices[i].name),
                        subtitle: Text("ID: ${voices[i].id}"),
                        trailing: IconButton(
                          icon: const Icon(Icons.delete, size: 18, color: Colors.red),
                          onPressed: () => setSubState(() => voices.removeAt(i)),
                        ),
                      ),
                    ),
                  )
                ],
              ),
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text("取消")),
            ElevatedButton(
              onPressed: () {
                Map<String, String> parsedHeaders = {};
                try {
                  final decoded = jsonDecode(headersCtrl.text);
                  if (decoded is Map) decoded.forEach((k, v) => parsedHeaders[k.toString()] = v.toString());
                } catch (_) {}

                final res = CustomTtsEngine(
                  id: existing?.id ?? DateTime.now().millisecondsSinceEpoch.toString(),
                  name: nameCtrl.text.trim(),
                  method: method,
                  urlTemplate: urlCtrl.text.trim(),
                  headers: parsedHeaders,
                  bodyTemplate: bodyCtrl.text.trim(),
                  responseType: respType,
                  jsonExtractPath: jsonPathCtrl.text.trim(),
                  voices: voices.isNotEmpty ? voices : [TtsVoice(id: "default", name: "默认音色")],
                );
                Navigator.pop(ctx, res);
              },
              child: const Text("保存引擎"),
            ),
          ],
        ),
      ),
    );
  }

  Future<TtsVoice?> _showAddVoiceDialog() async {
    final nameCtrl = TextEditingController();
    final idCtrl = TextEditingController();
    return showDialog<TtsVoice>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text("添加发音人"),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(controller: nameCtrl, decoration: const InputDecoration(labelText: "发音人名称")),
            const SizedBox(height: 8),
            TextField(controller: idCtrl, decoration: const InputDecoration(labelText: "发音人 ID")),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text("取消")),
          ElevatedButton(
            onPressed: () {
              if (nameCtrl.text.isNotEmpty && idCtrl.text.isNotEmpty) {
                Navigator.pop(ctx, TtsVoice(id: idCtrl.text.trim(), name: nameCtrl.text.trim()));
              }
            },
            child: const Text("添加"),
          )
        ],
      ),
    );
  }

  // ──────────────── 页面主布局 ────────────────
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("万能 TTS 朗读与发音人评测工具 (纯内存版)"),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        actions: [
          IconButton(
            tooltip: "全局网络与代理配置 (自动检测/自定义端口)",
            icon: const Icon(Icons.lan, color: Colors.indigo),
            onPressed: _openProxySettingsDialog,
          ),
          IconButton(
            tooltip: "自定义/添加/修改 TTS 引擎规则",
            icon: const Icon(Icons.tune),
            onPressed: _openEngineManagerDialog,
          ),
          IconButton(
            tooltip: "批量合成导出为 MP3 文件",
            icon: const Icon(Icons.save_alt),
            onPressed: _exportAudio,
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: Row(
        children: [
          Expanded(
            flex: 6,
            child: Column(
              children: [
                _buildTopControlBar(),
                _buildDragAndDropTextArea(),
              ],
            ),
          ),
          Container(
            width: 320,
            decoration: BoxDecoration(color: Colors.grey.shade100, border: Border(left: BorderSide(color: Colors.grey.shade300))),
            child: Column(
              children: [
                _buildSidebarSettings(),
                const Divider(height: 1),
                _buildLiveLogConsole(),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTopControlBar() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      color: Colors.grey.shade200,
      child: Wrap(
        spacing: 12,
        runSpacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          DropdownButton<CustomTtsEngine>(
            value: _currentEngine,
            items: _engines.map((e) => DropdownMenuItem(value: e, child: Text(e.name, style: const TextStyle(fontWeight: FontWeight.bold)))).toList(),
            onChanged: (e) {
              if (e != null) {
                setState(() {
                  _currentEngine = e;
                  _currentVoice = e.voices.isNotEmpty ? e.voices.first : TtsVoice(id: "", name: "无");
                });
                _saveConfig();
              }
            },
          ),
          DropdownButton<TtsVoice>(
            value: _currentEngine.voices.contains(_currentVoice) ? _currentVoice : _currentEngine.voices.firstOrNull,
            items: _currentEngine.voices.map((v) => DropdownMenuItem(value: v, child: Text(v.name))).toList(),
            onChanged: (v) {
              if (v != null) {
                setState(() => _currentVoice = v);
                _saveConfig();
              }
            },
          ),
          // 发音人试听按钮
          ElevatedButton.icon(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.deepPurple, foregroundColor: Colors.white),
            icon: const Icon(Icons.volume_up, size: 16),
            label: const Text("试听"),
            onPressed: () => _previewVoice(_currentEngine, _currentVoice),
          ),
          // 关键修复：滑块拖动实时动态生效，边拖边变速
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text("语速: "),
              SizedBox(
                width: 80,
                child: Slider(
                  value: _speed,
                  min: 0.5,
                  max: 2.0,
                  divisions: 6,
                  label: "${_speed}x",
                  onChanged: (val) {
                    setState(() => _speed = val);
                    // 核心：直接向播放器发送实时变速指令
                    _audioPlayer.setPlaybackRate(val);
                    _saveConfig();
                  },
                ),
              ),
              Text("${_speed.toStringAsFixed(2)}x"),
            ],
          ),
          DropdownButton<int>(
            value: _bitrate,
            items: const [DropdownMenuItem(value: 64, child: Text("省流 64k")), DropdownMenuItem(value: 128, child: Text("高清 128k"))],
            onChanged: (b) {
              setState(() => _bitrate = b ?? 64);
              _saveConfig();
            },
          ),
          ElevatedButton.icon(
            style: ElevatedButton.styleFrom(backgroundColor: _isPlaying ? Colors.grey : Colors.green, foregroundColor: Colors.white),
            icon: const Icon(Icons.play_arrow),
            label: const Text("开始"),
            onPressed: _isPlaying ? null : _startPlayback,
          ),
          ElevatedButton.icon(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.orange, foregroundColor: Colors.white),
            icon: Icon(_isPaused ? Icons.play_arrow : Icons.pause),
            label: Text(_isPaused ? "继续" : "暂停"),
            onPressed: _isPlaying ? _togglePause : null,
          ),
          ElevatedButton.icon(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red, foregroundColor: Colors.white),
            icon: const Icon(Icons.stop),
            label: const Text("停止"),
            onPressed: _isPlaying ? () => _stopPlayback("手动停止") : null,
          ),
        ],
      ),
    );
  }

  Widget _buildDragAndDropTextArea() {
    return Expanded(
      child: DropTarget(
        onDragDone: (detail) async {
          final file = detail.files.first;
          if (file.path.endsWith('.txt') || file.path.endsWith('.md')) {
            final content = await File(file.path).readAsString();
            setState(() => _textController.text = content);
            LogManager.instance.log("FILE", "成功拖入文档: ${file.name} (大小: ${content.length} 字符)");
          } else {
            ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("仅支持拖入 .txt 和 .md 格式文件！")));
          }
        },
        child: Container(
          color: Colors.white,
          padding: const EdgeInsets.all(12),
          child: Column(
            children: [
              if (_sentences.isNotEmpty && _currentSentenceIndex >= 0)
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(color: Colors.amber.shade100, borderRadius: BorderRadius.circular(4)),
                  child: Text(
                    "▶ 当前正读 [${_currentSentenceIndex + 1}/${_sentences.length}]: ${_sentences[_currentSentenceIndex]}",
                    style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.brown),
                  ),
                ),
              const SizedBox(height: 6),
              Expanded(
                child: TextField(
                  controller: _textController,
                  maxLines: null,
                  expands: true,
                  textAlignVertical: TextAlignVertical.top,
                  decoration: const InputDecoration(
                    hintText: "【快捷提示】\n1. 支持直接拖入 .txt/.md 小说或 Ctrl+V 粘贴文本\n2. 语速滑块支持在播放中【边播边拉】，实时变速不变调\n3. 点击发音人右侧【试听】直接发声验证\n4. 点击右上角【🌐】可一键切换代理模式",
                    border: InputBorder.none,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSidebarSettings() {
    return Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text("⚙️ 朗读流水线控制", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
          const SizedBox(height: 8),
          Text("预读缓冲深度: $_preloadCount 句 (纯 RAM 缓冲)"),
          Slider(
            value: _preloadCount.toDouble(),
            min: 1,
            max: 8,
            divisions: 7,
            onChanged: (v) {
              setState(() => _preloadCount = v.toInt());
              _saveConfig();
            },
          ),
          Text("并发网络线程: $_concurrency 条"),
          Slider(
            value: _concurrency.toDouble(),
            min: 1,
            max: 4,
            divisions: 3,
            onChanged: (v) {
              setState(() => _concurrency = v.toInt());
              _saveConfig();
            },
          ),
          Text("句子停顿间隔: ${_sentenceGapMs}ms"),
          Slider(
            value: _sentenceGapMs.toDouble(),
            min: 0,
            max: 1000,
            divisions: 10,
            onChanged: (v) {
              setState(() => _sentenceGapMs = v.toInt());
              _saveConfig();
            },
          ),
        ],
      ),
    );
  }

  Widget _buildLiveLogConsole() {
    return Expanded(
      child: Container(
        color: const Color(0xFF1E1E1E),
        child: Column(
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              color: Colors.black54,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text("实时调试日志", style: TextStyle(color: Colors.white70, fontSize: 12, fontWeight: FontWeight.bold)),
                  Row(
                    children: [
                      IconButton(
                        icon: const Icon(Icons.save_as, size: 16, color: Colors.white70),
                        tooltip: "保存调试日志到文件",
                        onPressed: () async {
                          final path = await LogManager.instance.exportLogsToFile();
                          if (path != null && mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("日志已保存至: $path")));
                          }
                        },
                      ),
                      IconButton(
                        icon: const Icon(Icons.clear_all, size: 16, color: Colors.white70),
                        tooltip: "清空日志",
                        onPressed: () => LogManager.instance.clear(),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            Expanded(
              child: StreamBuilder<List<String>>(
                stream: LogManager.instance.stream,
                builder: (context, snapshot) {
                  final logs = snapshot.data ?? [];
                  WidgetsBinding.instance.addPostFrameCallback((_) {
                    if (_logScrollController.hasClients) {
                      _logScrollController.jumpTo(_logScrollController.position.maxScrollExtent);
                    }
                  });
                  return ListView.builder(
                    controller: _logScrollController,
                    itemCount: logs.length,
                    itemBuilder: (ctx, idx) => Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                      child: Text(logs[idx], style: const TextStyle(color: Colors.lightGreenAccent, fontFamily: "Consolas", fontSize: 11)),
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
}
