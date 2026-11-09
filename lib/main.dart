import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:audioplayers/audioplayers.dart';
import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_picker/file_picker.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const TtsReaderApp());
}

// ─────────────────────────────────────────────────────────────
// 1. 日志管理系统 (支持实时显示与文件导出)
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
      dialogTitle: '保存日志文件',
      fileName: 'tts_log_${DateTime.now().millisecondsSinceEpoch}.txt',
      type: FileType.custom,
      allowedExtensions: ['txt', 'log'],
    );
    if (savePath != null) {
      final file = File(savePath);
      await file.writeAsString(logs.join('\r\n'));
      return savePath;
    }
    return null;
  }
}

// ─────────────────────────────────────────────────────────────
// 2. 通用自定义 TTS 引擎数据结构 (支持 JSON 序列化持久化)
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
  String method; // 'GET' 或 'POST'
  String urlTemplate; // 支持 {{text}}, {{voice}}, {{speed}}, {{bitrate}}
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
// 3. 通用 TTS 执行器 (内存流控)
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
      throw Exception("网络连接超时或断开: $e");
    }

    if (res.statusCode < 200 || res.statusCode >= 300) {
      final errBody = utf8.decode(res.bodyBytes, allowMalformed: true);
      throw Exception("HTTP ${res.statusCode}: $errBody");
    }

    switch (engine.responseType) {
      case AudioResponseType.binaryStream:
        if (res.bodyBytes.isEmpty) throw Exception("接口返回空的音频数据流");
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
// 4. 主程序界面与状态持久化
// ─────────────────────────────────────────────────────────────
class TtsReaderApp extends StatelessWidget {
  const TtsReaderApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '万能 TTS 朗读与发音人评测工具 (Windows 10)',
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
    _audioPlayer.setVolume(1.0);
    _loadConfig();
    _initAudioPlayer();
  }

  // ──────────────── 配置持久化管理 (本地自动备份与恢复) ────────────────
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
        final list = (data['engines'] as List<dynamic>?)?.map((e) => CustomTtsEngine.fromJson(e)).toList();
        if (list != null && list.isNotEmpty) {
          _engines = list;
          _currentEngine = _engines.first;
          _currentVoice = _currentEngine.voices.isNotEmpty ? _currentEngine.voices.first : TtsVoice(id: '', name: '默认');
          LogManager.instance.log("CONFIG", "已自动加载本地保存的持久化设置: tts_config.json");
          return;
        }
      }
    } catch (e) {
      LogManager.instance.log("CONFIG-ERR", "加载本地配置失败: $e，使用内置预设");
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
        'engines': _engines.map((e) => e.toJson()).toList(),
      };
      _localConfigFile.writeAsStringSync(const JsonEncoder.withIndent("  ").convert(data));
      LogManager.instance.log("CONFIG", "配置已成功保存至本地 tts_config.json");
    } catch (e) {
      LogManager.instance.log("CONFIG-ERR", "自动保存失败: $e");
    }
  }

  Future<void> _exportBackupDialog() async {
    final savePath = await FilePicker.platform.saveFile(
      dialogTitle: '导出全部配置与发音人备份',
      fileName: 'tts_full_backup_${DateTime.now().millisecondsSinceEpoch}.json',
      type: FileType.custom,
      allowedExtensions: ['json'],
    );
    if (savePath != null) {
      final data = {
        'speed': _speed,
        'bitrate': _bitrate,
        'engines': _engines.map((e) => e.toJson()).toList(),
      };
      await File(savePath).writeAsString(const JsonEncoder.withIndent("  ").convert(data));
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("配置备份已导出至: $savePath")));
    }
  }

  Future<void> _importBackupDialog() async {
    final res = await FilePicker.platform.pickFiles(type: FileType.custom, allowedExtensions: ['json']);
    if (res != null && res.files.single.path != null) {
      try {
        final content = await File(res.files.single.path!).readAsString();
        final data = jsonDecode(content);
        final list = (data['engines'] as List<dynamic>?)?.map((e) => CustomTtsEngine.fromJson(e)).toList();
        if (list != null && list.isNotEmpty) {
          setState(() {
            _engines = list;
            _currentEngine = _engines.first;
            _currentVoice = _currentEngine.voices.first;
          });
          _saveConfig();
          if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("🎉 备份恢复成功！")));
        }
      } catch (e) {
        if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("导入失败: $e")));
      }
    }
  }

  // 内置预设模板 (修复并包含正确的免密与头配置)
  void _initDefaultEngines() {
    _engines = [
      CustomTtsEngine(
        id: "cf_worker_template",
        name: "Cloudflare 中转免密引擎 (推荐)",
        method: "GET",
        urlTemplate: "https://tts.yzwww.ggff.net/tts?text={{text}}&voice={{voice}}&speed={{speed}}&bitrate={{bitrate}}",
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
          "model": "s2.1-pro-free" // 关键：已默认配好免费模型头
        },
        bodyTemplate: jsonEncode({
          "text": "{{text}}",
          "reference_id": "{{voice}}",
          "format": "mp3",
          "mp3_bitrate": 64,
          "chunk_length": 100,
          "latency": "balanced",
          "prosody": {"speed": 1.75}
        }),
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

  // ──────────────── 音频播放核心 (双层 RAM 解码保底，解决 Windows 无声) ────────────────
  Future<void> _playAudioFromRam(Uint8List bytes) async {
    try {
      await _audioPlayer.stop();
      await _audioPlayer.setVolume(1.0);
      // 通道 1：指定精确的 audio/mpeg MIME 类型，Windows Media Foundation 必备
      await _audioPlayer.play(BytesSource(bytes, mimeType: 'audio/mpeg'));
    } catch (e) {
      LogManager.instance.log("WARN", "BytesSource 播放异常 ($e)，启动 Data-URI 纯 RAM 备用通道...");
      final dataUri = Uri.dataFromBytes(bytes, mimeType: 'audio/mpeg').toString();
      await _audioPlayer.play(UrlSource(dataUri));
    }
  }

  void _initAudioPlayer() {
    _audioPlayer.onPlayerComplete.listen((_) async {
      if (!_isPlaying || _isPaused) return;
      LogManager.instance.log("PLAY", "第 ${_currentSentenceIndex + 1} 句播放完毕，停顿 ${_sentenceGapMs}ms");
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

  // ──────────────── 发音人即时试听 ────────────────
  Future<void> _previewVoice(CustomTtsEngine engine, TtsVoice voice) async {
    LogManager.instance.log("PREVIEW", "正在试听发音人: [${voice.name}] (ID: ${voice.id})...");
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text("正在生成 [${voice.name}] 的试听音频..."),
      duration: const Duration(seconds: 2),
    ));

    try {
      final bytes = await UniversalTtsExecutor.synthesize(
        engine: engine,
        text: "你好，这是一条试听语音。当前正在测试发音人：${voice.name} 的朗读效果。",
        voiceId: voice.id,
        speed: _speed,
        bitrate: _bitrate,
      );
      await _playAudioFromRam(bytes);
      LogManager.instance.log("PREVIEW", "试听音频播放成功！");
    } catch (e) {
      LogManager.instance.log("PREVIEW-ERR", "试听失败: $e");
      if (mounted) {
        showDialog(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text("❌ 试听失败"),
            content: Text("接口返回错误：\n$e\n\n排查建议：\n1. 检查该引擎的 API Key 或 URL 是否有效；\n2. 推荐先切换为 [Cloudflare 中转免密引擎] 验证本地发声硬件。"),
            actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text("好"))],
          ),
        );
      }
    }
  }

  // ──────────────── 引擎连通性测试 ────────────────
  Future<void> _testEngineConnectivity(CustomTtsEngine engine) async {
    final sw = Stopwatch()..start();
    LogManager.instance.log("PING", "正在对引擎 [${engine.name}] 进行网络连通性测试...");

    try {
      final voiceId = engine.voices.isNotEmpty ? engine.voices.first.id : "default";
      final bytes = await UniversalTtsExecutor.synthesize(
        engine: engine,
        text: "网络连通性测试成功，语音合成服务正常！",
        voiceId: voiceId,
        speed: 1.0,
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
              "• 网络往返与合成耗时: ${(sw.elapsedMilliseconds / 1000).toStringAsFixed(2)} 秒\n"
              "• 接收音频体积: ${(bytes.lengthInBytes / 1024).toStringAsFixed(1)} KB\n"
              "• 音频已在 RAM 中播放验证，如果您能听到声音，说明该引擎完全正常！",
            ),
            actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text("确定"))],
          ),
        );
      }
    } catch (e) {
      sw.stop();
      LogManager.instance.log("PING-ERR", "连通性测试失败: $e");
      if (mounted) {
        showDialog(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text("❌ 连通性测试失败"),
            content: Text("连接失败详情：\n$e\n\n排查指南：\n• 如果是官方直连，请检查 API Key 是否填写；\n• 检查接口地址 URL 是否有回车换行等非法字符。"),
            actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text("知道了"))],
          ),
        );
      }
    }
  }

  // ──────────────── 朗读流程控制 ────────────────
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
    LogManager.instance.log("TEXT", "文本已切分为 ${_sentences.length} 个独立句子");
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
    final text = _sentences[index];
    try {
      final audioBytes = await UniversalTtsExecutor.synthesize(
        engine: _currentEngine,
        text: text,
        voiceId: _currentVoice.id,
        speed: _speed,
        bitrate: _bitrate,
      );
      if (sessionId == _playSessionId) {
        _ramAudioCache[index] = audioBytes;
        LogManager.instance.log("PIPELINE", "第 ${index + 1} 句预读就绪，RAM 缓存: ${_ramAudioCache.length}");
      }
    } catch (e) {
      LogManager.instance.log("ERROR", "第 ${index + 1} 句获取失败: $e");
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
      if (!_inFlightFetches.contains(idx)) {
        _fetchToRam(idx, sessionId);
      }
      await Future.delayed(const Duration(milliseconds: 60));
      waitCounter++;
      if (waitCounter > 300) {
        _stopPlayback("第 ${idx + 1} 句加载超时");
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            backgroundColor: Colors.red,
            content: Text("朗读中断：未能获取到音频。请检查当前引擎配置、密钥或查看右下角日志！"),
          ));
        }
        return;
      }
    }

    if (!_isPlaying || sessionId != _playSessionId) return;
    final Uint8List audioBytes = _ramAudioCache[idx]!;
    LogManager.instance.log("AUDIO", "▶️ 正在从 RAM 播放第 ${idx + 1}/${_sentences.length} 句");
    await _playAudioFromRam(audioBytes);
  }

  void _startPlayback() {
    if (_textController.text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("请先输入或拖入文本！")));
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
    LogManager.instance.log("CTRL", reason ?? "朗读已停止，RAM 音频已释放");
  }

  Future<void> _exportAudio() async {
    if (_textController.text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("文本为空，无法导出！")));
      return;
    }

    final savePath = await FilePicker.platform.saveFile(
      dialogTitle: '选择导出的音频保存路径',
      fileName: 'TTS_Export_${DateTime.now().millisecondsSinceEpoch}.mp3',
      type: FileType.custom,
      allowedExtensions: ['mp3'],
    );

    if (savePath == null) return;

    _splitSentences();
    LogManager.instance.log("EXPORT", "开始批量合成并导出: $savePath");

    final exportBytes = BytesBuilder();
    for (int i = 0; i < _sentences.length; i++) {
      LogManager.instance.log("EXPORT", "正在合成第 ${i + 1}/${_sentences.length} 句...");
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

    final file = File(savePath);
    await file.writeAsBytes(exportBytes.toBytes());
    LogManager.instance.log("EXPORT", "🎉 导出全部完成！大小: ${(file.lengthSync() / 1024).toStringAsFixed(1)} KB");
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("音频已导出至：$savePath")));
  }

  // ──────────────── 引擎与发音人管理器弹窗 ────────────────
  void _openEngineManagerDialog() {
    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDlgState) => AlertDialog(
          title: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text("⚙️ TTS 引擎管理与自由定义", style: TextStyle(fontWeight: FontWeight.bold)),
              Row(
                children: [
                  OutlinedButton.icon(
                    icon: const Icon(Icons.file_upload, size: 16),
                    label: const Text("恢复备份"),
                    onPressed: () async {
                      Navigator.pop(ctx);
                      await _importBackupDialog();
                    },
                  ),
                  const SizedBox(width: 8),
                  OutlinedButton.icon(
                    icon: const Icon(Icons.file_download, size: 16),
                    label: const Text("导出备份"),
                    onPressed: _exportBackupDialog,
                  ),
                  const SizedBox(width: 8),
                  ElevatedButton.icon(
                    icon: const Icon(Icons.add, size: 16),
                    label: const Text("新增引擎"),
                    onPressed: () async {
                      final newEngine = await _showEditEngineDialog();
                      if (newEngine != null) {
                        setDlgState(() {
                          _engines.add(newEngine);
                          _currentEngine = newEngine;
                          _currentVoice = newEngine.voices.isNotEmpty ? newEngine.voices.first : TtsVoice(id: "", name: "无发音人");
                        });
                        _saveConfig();
                        setState(() {});
                      }
                    },
                  ),
                ],
              ),
            ],
          ),
          content: SizedBox(
            width: 760,
            height: 480,
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
                        tooltip: "测试该引擎连通性与发声",
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
                              if (_currentEngine.id == eng.id) {
                                _currentEngine = updated;
                                _currentVoice = updated.voices.isNotEmpty ? updated.voices.first : TtsVoice(id: "", name: "无");
                              }
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
                            if (_currentEngine.id == eng.id) {
                              _currentEngine = _engines.first;
                              _currentVoice = _currentEngine.voices.first;
                            }
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
          actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text("完成"))],
        ),
      ),
    );
  }

  // 自由编辑/新建引擎规则
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
          title: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(existing == null ? "新增自定义 TTS 引擎" : "编辑规则: ${existing.name}"),
              if (existing != null)
                TextButton.icon(
                  icon: const Icon(Icons.network_check, color: Colors.teal),
                  label: const Text("连通性即时测试"),
                  onPressed: () => _testEngineConnectivity(existing),
                )
            ],
          ),
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
                  const Text("请求体 Body 模板 (POST 时生效，支持 {{text}}, {{voice}}):", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
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
                    TextField(
                      controller: jsonPathCtrl,
                      decoration: const InputDecoration(
                        labelText: "JSON 音频提取路径 (如 choices[0].message.audio.data)",
                        border: OutlineInputBorder(),
                      ),
                    ),
                  ],
                  const Divider(height: 25),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text("发音人列表 (支持试听与增删改):", style: TextStyle(fontWeight: FontWeight.bold)),
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
                    height: 130,
                    decoration: BoxDecoration(border: Border.all(color: Colors.grey.shade300), borderRadius: BorderRadius.circular(6)),
                    child: ListView.builder(
                      itemCount: voices.length,
                      itemBuilder: (c, i) => ListTile(
                        dense: true,
                        title: Text(voices[i].name),
                        subtitle: Text("ID: ${voices[i].id}"),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            IconButton(
                              icon: const Icon(Icons.volume_up, size: 18, color: Colors.deepPurple),
                              tooltip: "试听该音色",
                              onPressed: () {
                                if (existing != null) {
                                  _previewVoice(existing, voices[i]);
                                } else {
                                  ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("请先保存引擎后再试听发音人！")));
                                }
                              },
                            ),
                            IconButton(
                              icon: const Icon(Icons.delete, size: 18, color: Colors.red),
                              onPressed: () => setSubState(() => voices.removeAt(i)),
                            ),
                          ],
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
                  if (decoded is Map) {
                    decoded.forEach((k, v) => parsedHeaders[k.toString()] = v.toString());
                  }
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
            TextField(controller: nameCtrl, decoration: const InputDecoration(labelText: "显示名称 (如: 甜美播音)")),
            const SizedBox(height: 8),
            TextField(controller: idCtrl, decoration: const InputDecoration(labelText: "发音人 ID (填入接口所需值)")),
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

  // ──────────────── 界面布局 ────────────────
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("万能 TTS 朗读与评测工具 (纯内存/零落盘版)"),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        actions: [
          IconButton(
            tooltip: "备份/恢复配置或管理自定义 TTS 引擎",
            icon: const Icon(Icons.tune),
            onPressed: _openEngineManagerDialog,
          ),
          IconButton(
            tooltip: "合成并导出为 MP3 文件",
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
            decoration: BoxDecoration(
              color: Colors.grey.shade100,
              border: Border(left: BorderSide(color: Colors.grey.shade300)),
            ),
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

  // 顶栏控制栏
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
            items: _engines
                .map((e) => DropdownMenuItem(value: e, child: Text(e.name, style: const TextStyle(fontWeight: FontWeight.bold))))
                .toList(),
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
          // 核心功能：发音人一键试听
          ElevatedButton.icon(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.deepPurple, foregroundColor: Colors.white),
            icon: const Icon(Icons.volume_up, size: 16),
            label: const Text("试听"),
            onPressed: () => _previewVoice(_currentEngine, _currentVoice),
          ),
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
                    _saveConfig();
                  },
                ),
              ),
              Text("${_speed.toStringAsFixed(2)}x"),
            ],
          ),
          DropdownButton<int>(
            value: _bitrate,
            items: const [
              DropdownMenuItem(value: 64, child: Text("省流 64k")),
              DropdownMenuItem(value: 128, child: Text("高清 128k")),
            ],
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

  // 文本编辑展示区
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
            ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("仅支持拖入 .txt 和 .md 格式小说文件！")));
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
                    hintText: "【使用提示】\n1. 选中发音人后可点击上方【试听】直接发声\n2. 默认推荐使用 [Cloudflare 中转免密引擎]，开箱即听\n3. 可按 Ctrl+V 粘贴任意文字，或拖拽 .txt / .md 小说进入本区域\n4. 点击右上角【⚙️ 图标】可测试引擎连通性、备份或添加任何新 TTS",
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

  // 右侧参数控制
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

  // 调试日志窗口 (支持文件导出备份)
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
                      child: Text(
                        logs[idx],
                        style: const TextStyle(color: Colors.lightGreenAccent, fontFamily: "Consolas", fontSize: 11),
                      ),
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
