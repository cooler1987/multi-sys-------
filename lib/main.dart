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
// 1. 日志管理系统 (RAM Log Stream)
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
}

// ─────────────────────────────────────────────────────────────
// 2. 通用自定义 TTS 引擎模型 (支持用户自由拓展任何协议)
// ─────────────────────────────────────────────────────────────
enum AudioResponseType {
  binaryStream, // 直接返回二进制音频数据流 (如 Fish.audio, Edge-TTS, 自建中转)
  jsonBase64,   // 从 JSON 的指定路径提取 Base64 编码 (如 MiMo, OpenAI)
  jsonUrl,      // 从 JSON 的指定路径提取音频下载 URL
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
  String method; // 'GET' 或 'POST'
  String urlTemplate; // 支持 {{text}}, {{voice}}, {{speed}}, {{bitrate}}
  Map<String, String> headers;
  String bodyTemplate; // POST 请求体模板，支持占位符
  AudioResponseType responseType;
  String jsonExtractPath; // 如 choices[0].message.audio.data
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
}

// ─────────────────────────────────────────────────────────────
// 3. 通用网络执行器 (纯 RAM 处理，绝不写硬盘)
// ─────────────────────────────────────────────────────────────
class UniversalTtsExecutor {
  static Future<Uint8List> synthesize({
    required CustomTtsEngine engine,
    required String text,
    required String voiceId,
    required double speed,
    required int bitrate,
  }) async {
    LogManager.instance.log("EXEC", "正在调用引擎 [${engine.name}]，发音人: $voiceId，字数: ${text.length}");

    // 占位符安全替换
    String replacePlaceholders(String input, {bool isUrl = false}) {
      String processedText = isUrl ? Uri.encodeComponent(text) : jsonEncode(text).replaceFirst(RegExp(r'^"'), '').replaceFirst(RegExp(r'"$'), '');
      return input
          .replaceAll('{{text}}', processedText)
          .replaceAll('{{voice}}', voiceId)
          .replaceAll('{{speed}}', speed.toStringAsFixed(2))
          .replaceAll('{{bitrate}}', bitrate.toString());
    }

    final targetUrl = Uri.parse(replacePlaceholders(engine.urlTemplate, isUrl: true));
    final processedHeaders = <String, String>{};
    engine.headers.forEach((k, v) {
      processedHeaders[k] = replacePlaceholders(v);
    });

    http.Response res;
    if (engine.method.toUpperCase() == 'POST') {
      final processedBody = replacePlaceholders(engine.bodyTemplate);
      res = await http.post(targetUrl, headers: processedHeaders, body: processedBody);
    } else {
      res = await http.get(targetUrl, headers: processedHeaders);
    }

    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw Exception("接口返回错误 (HTTP ${res.statusCode}):\n${utf8.decode(res.bodyBytes, allowMalformed: true)}");
    }

    // 根据用户配置的响应规则提取音频进入内存
    switch (engine.responseType) {
      case AudioResponseType.binaryStream:
        LogManager.instance.log("RAM", "二进制音频流已载入内存，大小: ${(res.bodyBytes.lengthInBytes / 1024).toStringAsFixed(1)} KB");
        return res.bodyBytes;

      case AudioResponseType.jsonBase64:
        final jsonObj = jsonDecode(utf8.decode(res.bodyBytes));
        final base64Str = _extractByPath(jsonObj, engine.jsonExtractPath);
        if (base64Str == null || base64Str is! String || base64Str.isEmpty) {
          throw Exception("无法从 JSON 路径 [${engine.jsonExtractPath}] 提取到有效的 Base64 音频数据");
        }
        final bytes = base64Decode(base64Str.replaceAll(RegExp(r'\s+'), ''));
        LogManager.instance.log("RAM", "Base64 解码至内存完毕，大小: ${(bytes.lengthInBytes / 1024).toStringAsFixed(1)} KB");
        return bytes;

      case AudioResponseType.jsonUrl:
        final jsonObj = jsonDecode(utf8.decode(res.bodyBytes));
        final audioUrl = _extractByPath(jsonObj, engine.jsonExtractPath);
        if (audioUrl == null || audioUrl is! String || audioUrl.isEmpty) {
          throw Exception("无法从 JSON 路径 [${engine.jsonExtractPath}] 提取到音频下载链接");
        }
        LogManager.instance.log("NET", "正在从提取到的 URL 下载音频到 RAM: $audioUrl");
        final dlRes = await http.get(Uri.parse(audioUrl));
        return dlRes.bodyBytes;
    }
  }

  // 简易层级属性提取器 (支持 data.audio 以及 choices[0].message 等路径格式)
  static dynamic _extractByPath(dynamic root, String path) {
    if (path.trim().isEmpty) return root;
    final segments = path.split('.');
    dynamic current = root;

    for (var seg in segments) {
      if (seg.contains('[') && seg.endsWith(']')) {
        final key = seg.substring(0, seg.indexOf('['));
        final indexStr = seg.substring(seg.indexOf('[') + 1, seg.length - 1);
        if (key.isNotEmpty) current = current[key];
        final idx = int.tryParse(indexStr) ?? 0;
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
// 4. 主程序界面
// ─────────────────────────────────────────────────────────────
class TtsReaderApp extends StatelessWidget {
  const TtsReaderApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '多音色 TTS 自由配置朗读工具 (Windows 10 纯内存版)',
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

  // 动态引擎列表（用户可自由在此增删改查任何新 TTS）
  late List<CustomTtsEngine> _engines;
  late CustomTtsEngine _currentEngine;
  late TtsVoice _currentVoice;

  // 调节参数
  double _speed = 1.75;
  int _bitrate = 64;
  int _preloadCount = 4;
  int _concurrency = 2;
  int _sentenceGapMs = 200;

  // 播放调度
  List<String> _sentences = [];
  int _currentSentenceIndex = -1;
  bool _isPlaying = false;
  bool _isPaused = false;
  int _playSessionId = 0;

  // 纯 RAM 内存池
  final Map<int, Uint8List> _ramAudioCache = {};
  final Set<int> _inFlightFetches = {};

  @override
  void initState() {
    super.initState();
    _initDefaultEngines();
    _initAudioPlayer();
  }

  // 初始化内置预设（仅作为范例，用户可随时在界面上编辑、新增其他任何 TTS）
  void _initDefaultEngines() {
    _engines = [
      CustomTtsEngine(
        id: "fish_audio_template",
        name: "Fish.Audio 官方/中转模板",
        method: "POST",
        urlTemplate: "https://api.fish.audio/v1/tts",
        headers: {
          "Authorization": "Bearer 你的FishAudio密钥",
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
          "prosody": {"speed": 1.75}
        }),
        responseType: AudioResponseType.binaryStream,
        jsonExtractPath: "",
        voices: [
          TtsVoice(id: "a688f2129bea41d1ae6042462892ecf8", name: "通用小说男声"),
          TtsVoice(id: "cf71d823861b4e0eadff1672d646da36", name: "几何知性女声"),
        ],
      ),
      CustomTtsEngine(
        id: "mimo_template",
        name: "小米 MiMo-TTS 模板",
        method: "POST",
        urlTemplate: "https://api.xiaomimimo.com/v1/chat/completions",
        headers: {
          "Authorization": "Bearer 你的MIMO密钥",
          "Content-Type": "application/json"
        },
        bodyTemplate: jsonEncode({
          "model": "mimo-v2.5-tts",
          "messages": [
            {"role": "user", "content": "请以较快语速朗读，声音清晰自然"},
            {"role": "assistant", "content": "{{text}}"}
          ],
          "audio": {"voice": "{{voice}}", "format": "mp3"}
        }),
        responseType: AudioResponseType.jsonBase64,
        jsonExtractPath: "choices[0].message.audio.data",
        voices: [
          TtsVoice(id: "茉莉", name: "茉莉 (温柔女声)"),
          TtsVoice(id: "冰糖", name: "冰糖 (甜美女声)"),
          TtsVoice(id: "苏打", name: "苏打 (活力男声)"),
          TtsVoice(id: "白桦", name: "白桦 (磁性男声)"),
        ],
      ),
    ];
    _currentEngine = _engines.first;
    _currentVoice = _currentEngine.voices.first;
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
        _stopPlayback("全文朗读已顺利完成！");
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

  void _splitSentences() {
    final text = _textController.text;
    if (text.trim().isEmpty) {
      _sentences = [];
      return;
    }
    final regex = RegExp(r'[^。！？；\n\r]*[。！？；…]+|[^。！？；\n\r]+');
    final matches = regex.allMatches(text);
    _sentences = matches
        .map((m) => m.group(0)!.trim())
        .where((s) => s.isNotEmpty && RegExp(r'[\w\u4e00-\u9fa5]').hasMatch(s))
        .toList();
    LogManager.instance.log("TEXT", "文本成功切分为 ${_sentences.length} 个独立句子");
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
    final sentenceText = _sentences[index];

    try {
      final audioBytes = await UniversalTtsExecutor.synthesize(
        engine: _currentEngine,
        text: sentenceText,
        voiceId: _currentVoice.id,
        speed: _speed,
        bitrate: _bitrate,
      );

      if (sessionId == _playSessionId) {
        _ramAudioCache[index] = audioBytes;
        LogManager.instance.log("PIPELINE", "第 ${index + 1} 句预读就绪，当前内存缓冲条数: ${_ramAudioCache.length}");
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
      if (waitCounter > 350) {
        _stopPlayback("第 ${idx + 1} 句加载超时中断");
        return;
      }
    }

    if (!_isPlaying || sessionId != _playSessionId) return;

    final Uint8List audioBytes = _ramAudioCache[idx]!;
    LogManager.instance.log("AUDIO", "▶️ 正在通过 RAM 播放第 ${idx + 1}/${_sentences.length} 句");
    await _audioPlayer.play(BytesSource(audioBytes));
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
    LogManager.instance.log("CTRL", reason ?? "朗读已停止，RAM 音频已彻底释放");
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
    LogManager.instance.log("EXPORT", "开始批量合成并导出文件: $savePath");

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
        LogManager.instance.log("EXPORT-ERR", "第 ${i + 1} 句导出失败: $e");
      }
    }

    final file = File(savePath);
    await file.writeAsBytes(exportBytes.toBytes());
    LogManager.instance.log("EXPORT", "🎉 导出全部完成！大小: ${(file.lengthSync() / 1024).toStringAsFixed(1)} KB");
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("音频已成功导出至：$savePath")));
    }
  }

  // ─────────────────────────────────────────────────────────────
  // 5. 核心：万能引擎与发音人管理器 (支持用户自由增删改任何 TTS)
  // ─────────────────────────────────────────────────────────────
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
                icon: const Icon(Icons.add),
                label: const Text("新增自定义 TTS 引擎"),
                onPressed: () async {
                  final newEngine = await _showEditEngineDialog();
                  if (newEngine != null) {
                    setDlgState(() {
                      _engines.add(newEngine);
                      _currentEngine = newEngine;
                      _currentVoice = newEngine.voices.isNotEmpty ? newEngine.voices.first : TtsVoice(id: "", name: "无发音人");
                    });
                    setState(() {});
                  }
                },
              ),
            ],
          ),
          content: SizedBox(
            width: 720,
            height: 480,
            child: ListView.separated(
              itemCount: _engines.length,
              separatorBuilder: (_, __) => const Divider(),
              itemBuilder: (c, idx) {
                final eng = _engines[idx];
                return ListTile(
                  title: Text(eng.name, style: const TextStyle(fontWeight: FontWeight.bold)),
                  subtitle: Text("${eng.method}  |  ${eng.urlTemplate}\n发音人数量: ${eng.voices.length}"),
                  isThreeLine: true,
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        icon: const Icon(Icons.edit, color: Colors.blue),
                        tooltip: "编辑此引擎规则/修改发音人",
                        onPressed: () async {
                          final updated = await _showEditEngineDialog(existing: eng);
                          if (updated != null) {
                            setDlgState(() {
                              _engines[idx] = updated;
                              if (_currentEngine.id == eng.id) {
                                _currentEngine = updated;
                                _currentVoice = updated.voices.isNotEmpty ? updated.voices.first : TtsVoice(id: "", name: "无发音人");
                              }
                            });
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
                          setState(() {});
                        },
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text("完成")),
          ],
        ),
      ),
    );
  }

  // 自由编辑/新增任何 TTS 引擎规则弹窗
  Future<CustomTtsEngine?> _showEditEngineDialog({CustomTtsEngine? existing}) async {
    final nameCtrl = TextEditingController(text: existing?.name ?? "我的自定义 TTS 引擎");
    final urlCtrl = TextEditingController(text: existing?.urlTemplate ?? "https://api.your-tts.com/v1/tts");
    final headersCtrl = TextEditingController(
      text: existing != null ? const JsonEncoder.withIndent("  ").convert(existing.headers) : '{\n  "Authorization": "Bearer 填入密钥",\n  "Content-Type": "application/json"\n}',
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
          title: Text(existing == null ? "新增自定义 TTS 引擎" : "编辑引擎规则: ${existing.name}"),
          content: SizedBox(
            width: 680,
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  TextField(controller: nameCtrl, decoration: const InputDecoration(labelText: "引擎名称 (如: 阿里/百度/我的代理)")),
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
                  const Text("请求体 Body 模板 (POST 时生效，支持 {{text}}, {{voice}}, {{speed}}):", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
                  TextField(controller: bodyCtrl, maxLines: 4, decoration: const InputDecoration(border: OutlineInputBorder())),
                  const SizedBox(height: 10),
                  const Text("音频响应解析方式:", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
                  DropdownButton<AudioResponseType>(
                    value: respType,
                    isExpanded: true,
                    items: const [
                      DropdownMenuItem(value: AudioResponseType.binaryStream, child: Text("直接返回二进制音频流 (如 Fish.audio, Edge, 通用代理)")),
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
                        labelText: "JSON 音频提取路径 (例如: choices[0].message.audio.data)",
                        border: OutlineInputBorder(),
                      ),
                    ),
                  ],
                  const Divider(height: 25),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text("发音人列表管理 (可随时添加/修改):", style: TextStyle(fontWeight: FontWeight.bold)),
                      ElevatedButton.icon(
                        icon: const Icon(Icons.add, size: 16),
                        label: const Text("添加发音人"),
                        onPressed: () async {
                          final v = await _showAddVoiceDialog();
                          if (v != null) {
                            setSubState(() => voices.add(v));
                          }
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
                          icon: const Icon(Icons.delete, size: 16, color: Colors.red),
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
            TextField(controller: nameCtrl, decoration: const InputDecoration(labelText: "发音人显示名称 (如: 甜美小姐姐)")),
            const SizedBox(height: 8),
            TextField(controller: idCtrl, decoration: const InputDecoration(labelText: "发音人 ID (填入 API 需要的标识符)")),
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

  // ──────────────── 界面布局构建 ────────────────
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("万能 TTS 朗读器 (Windows 10 原生纯内存版)"),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        actions: [
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

  Widget _buildTopControlBar() {
    return Container(
      // 标准的 Flutter 垂直与水平内边距
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      color: Colors.grey.shade200,
      child: Wrap(
        spacing: 12,
        runSpacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          // 引擎自由选择
          DropdownButton<CustomTtsEngine>(
            value: _currentEngine,
            items: _engines
                .map((e) => DropdownMenuItem(value: e, child: Text(e.name, style: const TextStyle(fontWeight: FontWeight.bold))))
                .toList(),
            onChanged: (e) {
              if (e != null) {
                setState(() {
                  _currentEngine = e;
                  _currentVoice = e.voices.isNotEmpty ? e.voices.first : TtsVoice(id: "", name: "无发音人");
                });
              }
            },
          ),

          // 发音人选择
          DropdownButton<TtsVoice>(
            value: _currentEngine.voices.contains(_currentVoice) ? _currentVoice : _currentEngine.voices.firstOrNull,
            items: _currentEngine.voices
                .map((v) => DropdownMenuItem(value: v, child: Text(v.name)))
                .toList(),
            onChanged: (v) {
              if (v != null) setState(() => _currentVoice = v);
            },
          ),

          // 语速调节
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text("语速: "),
              SizedBox(
                width: 85,
                child: Slider(
                  value: _speed,
                  min: 0.5,
                  max: 2.0,
                  divisions: 6,
                  label: "${_speed}x",
                  onChanged: (val) => setState(() => _speed = val),
                ),
              ),
              Text("${_speed.toStringAsFixed(2)}x"),
            ],
          ),

          // 码率选择
          DropdownButton<int>(
            value: _bitrate,
            items: const [
              DropdownMenuItem(value: 64, child: Text("省流 64k")),
              DropdownMenuItem(value: 128, child: Text("高清 128k")),
            ],
            onChanged: (b) => setState(() => _bitrate = b ?? 64),
          ),

          // 控制按钮组
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
            LogManager.instance.log("FILE", "成功拖入文件: ${file.name} (共 ${content.length} 字符)");
          } else {
            ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("仅支持拖入 .txt 和 .md 文件！")));
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
                    "▶ 当前朗读 [${_currentSentenceIndex + 1}/${_sentences.length}]: ${_sentences[_currentSentenceIndex]}",
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
                    hintText: "【操作提示】\n1. 支持直接拖入 .txt / .md 小说文档\n2. 支持 Ctrl+V 随意粘贴长文本\n3. 点击右上角【⚙️ 调节图标】可自由添加任何第三方的 TTS 引擎 API！",
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
          Text("预读缓冲深度: $_preloadCount 句 (纯 RAM 缓存)"),
          Slider(
            value: _preloadCount.toDouble(),
            min: 1,
            max: 8,
            divisions: 7,
            onChanged: (v) => setState(() => _preloadCount = v.toInt()),
          ),
          Text("并发网络线程: $_concurrency 条"),
          Slider(
            value: _concurrency.toDouble(),
            min: 1,
            max: 4,
            divisions: 3,
            onChanged: (v) => setState(() => _concurrency = v.toInt()),
          ),
          Text("句子停顿间隔: ${_sentenceGapMs}ms"),
          Slider(
            value: _sentenceGapMs.toDouble(),
            min: 0,
            max: 1000,
            divisions: 10,
            onChanged: (v) => setState(() => _sentenceGapMs = v.toInt()),
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
                  IconButton(
                    icon: const Icon(Icons.clear_all, size: 16, color: Colors.white70),
                    onPressed: () => LogManager.instance.clear(),
                    tooltip: "清空日志",
                  )
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
