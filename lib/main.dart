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
// 2. 数据模型：发音人与引擎配置
// ─────────────────────────────────────────────────────────────
class TtsVoice {
  String id;
  String name;
  TtsVoice({required this.id, required this.name});
}

class TtsEngine {
  String id;
  String name;
  String type; // 'fish_audio' | 'mimo'
  String endpoint;
  String apiKey;
  List<TtsVoice> voices;

  TtsEngine({
    required this.id,
    required this.name,
    required this.type,
    required this.endpoint,
    required this.apiKey,
    required this.voices,
  });
}

// ─────────────────────────────────────────────────────────────
// 3. 内存 TTS 网络调度引擎 (完全不触碰硬盘)
// ─────────────────────────────────────────────────────────────
class TtsService {
  static Future<Uint8List> synthesize({
    required TtsEngine engine,
    required String text,
    required String voiceId,
    required double speed,
    required int bitrate,
  }) async {
    LogManager.instance.log("TTS-REQ", "正在请求 [${engine.name}] 引擎, 发音人ID: $voiceId, 字数: ${text.length}");

    if (engine.type == 'fish_audio') {
      return await _requestFishAudio(engine, text, voiceId, speed, bitrate);
    } else if (engine.type == 'mimo') {
      return await _requestMimo(engine, text, voiceId, speed, bitrate);
    } else {
      throw Exception("未知的引擎类型: ${engine.type}");
    }
  }

  static Future<Uint8List> _requestFishAudio(
    TtsEngine engine,
    String text,
    String voiceId,
    double speed,
    int bitrate,
  ) async {
    final uri = Uri.parse(engine.endpoint.isNotEmpty ? engine.endpoint : "https://api.fish.audio/v1/tts");
    final body = jsonEncode({
      "text": text,
      "reference_id": voiceId,
      "format": "mp3",
      "mp3_bitrate": bitrate,
      "chunk_length": 100,
      "latency": "balanced",
      "prosody": {"speed": speed}
    });

    final res = await http.post(
      uri,
      headers: {
        "Authorization": "Bearer ${engine.apiKey.trim()}",
        "Content-Type": "application/json",
        "model": "s2.1-pro-free",
      },
      body: body,
    );

    if (res.statusCode == 200) {
      LogManager.instance.log("TTS-RAM", "Fish.Audio 数据已接收进 RAM，大小: ${(res.bodyBytes.lengthInBytes / 1024).toStringAsFixed(1)} KB");
      return res.bodyBytes;
    } else {
      throw Exception("Fish Audio 错误 (${res.statusCode}): ${utf8.decode(res.bodyBytes)}");
    }
  }

  static Future<Uint8List> _requestMimo(
    TtsEngine engine,
    String text,
    String voiceId,
    double speed,
    int bitrate,
  ) async {
    final uri = Uri.parse(engine.endpoint.isNotEmpty ? engine.endpoint : "https://api.xiaomimimo.com/v1/chat/completions");
    
    final messages = [
      if ((speed - 1.0).abs() >= 0.05)
        {"role": "user", "content": "请以约 ${speed.toStringAsFixed(2)} 倍的较快语速朗读，吐字清晰流利。"},
      {"role": "assistant", "content": text}
    ];

    final body = jsonEncode({
      "model": "mimo-v2.5-tts",
      "messages": messages,
      "audio": {
        "voice": voiceId,
        "format": "mp3"
      }
    });

    final res = await http.post(
      uri,
      headers: {
        "Authorization": "Bearer ${engine.apiKey.trim()}",
        "Content-Type": "application/json",
      },
      body: body,
    );

    if (res.statusCode == 200) {
      final jsonResp = jsonDecode(utf8.decode(res.bodyBytes));
      final audioBase64 = jsonResp["choices"]?[0]?["message"]?["audio"]?["data"];
      if (audioBase64 == null) {
        throw Exception("MiMo 响应未找到音频数据");
      }
      final bytes = base64Decode(audioBase64);
      LogManager.instance.log("TTS-RAM", "MiMo 音频已 Base64 解码至 RAM，大小: ${(bytes.lengthInBytes / 1024).toStringAsFixed(1)} KB");
      return bytes;
    } else {
      throw Exception("MiMo 接口错误 (${res.statusCode}): ${utf8.decode(res.bodyBytes)}");
    }
  }
}

// ─────────────────────────────────────────────────────────────
// 4. 主界面
// ─────────────────────────────────────────────────────────────
class TtsReaderApp extends StatelessWidget {
  const TtsReaderApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '多音色 TTS 朗读工具 (Win10 原生纯内存版)',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.indigo),
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

  late List<TtsEngine> _engines;
  late TtsEngine _currentEngine;
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
    _initEngines();
    _initAudioPlayer();
  }

  void _initEngines() {
    _engines = [
      TtsEngine(
        id: "fish",
        name: "Fish.Audio (官方/中转)",
        type: "fish_audio",
        endpoint: "https://api.fish.audio/v1/tts",
        apiKey: "",
        voices: [
          TtsVoice(id: "a688f2129bea41d1ae6042462892ecf8", name: "推荐主力男声"),
          TtsVoice(id: "cf71d823861b4e0eadff1672d646da36", name: "几何女声(知性自然)"),
          TtsVoice(id: "ef078859f29145918ddaf061fc1ce479", name: "刘湘湘(中年自然)"),
          TtsVoice(id: "6116079467e945f5b0c9b51859c29a02", name: "男声财经(专业快速)"),
        ],
      ),
      TtsEngine(
        id: "mimo",
        name: "小米 MiMo-TTS",
        type: "mimo",
        endpoint: "https://api.xiaomimimo.com/v1/chat/completions",
        apiKey: "",
        voices: [
          TtsVoice(id: "茉莉", name: "茉莉 (温柔知性)"),
          TtsVoice(id: "冰糖", name: "冰糖 (清澈甜美)"),
          TtsVoice(id: "苏打", name: "苏打 (阳光男声)"),
          TtsVoice(id: "白桦", name: "白桦 (磁性深沉)"),
        ],
      ),
    ];
    _currentEngine = _engines.first;
    _currentVoice = _currentEngine.voices.first;
  }

  void _initAudioPlayer() {
    _audioPlayer.onPlayerComplete.listen((_) async {
      if (!_isPlaying || _isPaused) return;

      LogManager.instance.log("PLAYER", "第 ${_currentSentenceIndex + 1} 句播放完毕，等待 ${_sentenceGapMs}ms 间隔");
      await Future.delayed(Duration(milliseconds: _sentenceGapMs));

      if (!_isPlaying || _isPaused) return;

      if (_currentSentenceIndex + 1 < _sentences.length) {
        setState(() {
          _currentSentenceIndex++;
        });
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
    LogManager.instance.log("TEXT", "文本已分句，共计 ${_sentences.length} 句");
  }

  void _schedulePreload(int currentIndex, int sessionId) {
    if (sessionId != _playSessionId) return;

    final targetEnd = (currentIndex + _preloadCount + 1).clamp(0, _sentences.length);
    for (int i = currentIndex; i < targetEnd; i++) {
      if (_ramAudioCache.containsKey(i) || _inFlightFetches.contains(i)) continue;

      if (_inFlightFetches.length >= _concurrency) {
        break;
      }

      _fetchToRam(i, sessionId);
    }
  }

  Future<void> _fetchToRam(int index, int sessionId) async {
    _inFlightFetches.add(index);
    final sentenceText = _sentences[index];

    try {
      final audioData = await TtsService.synthesize(
        engine: _currentEngine,
        text: sentenceText,
        voiceId: _currentVoice.id,
        speed: _speed,
        bitrate: _bitrate,
      );

      if (sessionId == _playSessionId) {
        _ramAudioCache[index] = audioData;
        LogManager.instance.log("PIPELINE", "第 ${index + 1} 句预读就绪，当前 RAM 缓存条数: ${_ramAudioCache.length}");
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
        LogManager.instance.log("TIMEOUT", "第 ${idx + 1} 句加载超时");
        _stopPlayback("第 ${idx + 1} 句音频加载超时，已停止。");
        return;
      }
    }

    if (!_isPlaying || sessionId != _playSessionId) return;

    final Uint8List audioBytes = _ramAudioCache[idx]!;
    LogManager.instance.log("AUDIO", "▶️ 正在通过 RAM 播放第 ${idx + 1}/${_sentences.length} 句: ${_sentences[idx]}");
    await _audioPlayer.play(BytesSource(audioBytes));
  }

  void _startPlayback() {
    if (_textController.text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("请先输入或拖入文本内容！")));
      return;
    }
    if (_currentEngine.apiKey.trim().isEmpty) {
      _showEngineConfigDialog();
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
    setState(() {
      _isPaused = !_isPaused;
    });
    if (_isPaused) {
      _audioPlayer.pause();
      LogManager.instance.log("CONTROL", "朗读已暂停");
    } else {
      _audioPlayer.resume();
      LogManager.instance.log("CONTROL", "朗读已继续");
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
    LogManager.instance.log("CONTROL", reason ?? "朗读已停止，RAM 缓存已释放");
  }

  Future<void> _exportAudio() async {
    if (_textController.text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("没有可导出的正文！")));
      return;
    }
    if (_currentEngine.apiKey.trim().isEmpty) {
      _showEngineConfigDialog();
      return;
    }

    final savePath = await FilePicker.platform.saveFile(
      dialogTitle: '选择导出的音频文件保存路径',
      fileName: 'TTS_Export_${DateTime.now().millisecondsSinceEpoch}.mp3',
      type: FileType.custom,
      allowedExtensions: ['mp3'],
    );

    if (savePath == null) return;

    _splitSentences();
    LogManager.instance.log("EXPORT", "开始批量合成导出，目标路径: $savePath");

    final exportBytes = BytesBuilder();
    for (int i = 0; i < _sentences.length; i++) {
      LogManager.instance.log("EXPORT", "正在合成第 ${i + 1}/${_sentences.length} 句...");
      try {
        final b = await TtsService.synthesize(
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
    LogManager.instance.log("EXPORT", "🎉 导出完成！总大小: ${(file.lengthSync() / 1024).toStringAsFixed(1)} KB");
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("音频已成功导出至：$savePath")));
    }
  }

  void _showEngineConfigDialog() {
    final apiKeyController = TextEditingController(text: _currentEngine.apiKey);
    final endpointController = TextEditingController(text: _currentEngine.endpoint);

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDlgState) => AlertDialog(
          title: Text("配置当前引擎：${_currentEngine.name}"),
          content: SizedBox(
            width: 580,
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  TextField(
                    controller: endpointController,
                    decoration: const InputDecoration(labelText: "API 端点 / 代理 URL", border: OutlineInputBorder()),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: apiKeyController,
                    decoration: const InputDecoration(labelText: "API Key (密钥)", border: OutlineInputBorder()),
                  ),
                  const Divider(height: 30),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text("发音人列表：", style: TextStyle(fontWeight: FontWeight.bold)),
                      ElevatedButton.icon(
                        icon: const Icon(Icons.add, size: 16),
                        label: const Text("新增发音人"),
                        onPressed: () async {
                          final newV = await _showAddVoiceDialog();
                          if (newV != null) {
                            setDlgState(() {
                              _currentEngine.voices.add(newV);
                            });
                            setState(() {});
                          }
                        },
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Container(
                    height: 160,
                    decoration: BoxDecoration(border: Border.all(color: Colors.grey.shade300), borderRadius: BorderRadius.circular(8)),
                    child: ListView.separated(
                      itemCount: _currentEngine.voices.length,
                      separatorBuilder: (_, __) => const Divider(height: 1),
                      itemBuilder: (c, i) {
                        final v = _currentEngine.voices[i];
                        return ListTile(
                          dense: true,
                          title: Text(v.name, style: const TextStyle(fontWeight: FontWeight.bold)),
                          subtitle: Text("ID: ${v.id}"),
                          trailing: IconButton(
                            icon: const Icon(Icons.delete_outline, size: 18, color: Colors.red),
                            onPressed: () {
                              setDlgState(() {
                                _currentEngine.voices.removeAt(i);
                                if (_currentVoice.id == v.id && _currentEngine.voices.isNotEmpty) {
                                  _currentVoice = _currentEngine.voices.first;
                                }
                              });
                              setState(() {});
                            },
                          ),
                        );
                      },
                    ),
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () {
                _currentEngine.apiKey = apiKeyController.text.trim();
                _currentEngine.endpoint = endpointController.text.trim();
                Navigator.pop(ctx);
                setState(() {});
              },
              child: const Text("保存并关闭"),
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
            TextField(controller: idCtrl, decoration: const InputDecoration(labelText: "发音人 ID (如: a688f212... 或 茉莉)")),
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("Flutter TTS 原生朗读器 (Windows 10)"),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        actions: [
          IconButton(
            tooltip: "配置当前引擎密钥与发音人",
            icon: const Icon(Icons.settings),
            onPressed: _showEngineConfigDialog,
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

  Widget _buildTopControlBar() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, pady: 8),
      color: Colors.grey.shade200,
      child: Wrap(
        spacing: 12,
        runSpacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          DropdownButton<TtsEngine>(
            value: _currentEngine,
            items: _engines
                .map((e) => DropdownMenuItem(value: e, child: Text(e.name, style: const TextStyle(fontWeight: FontWeight.bold))))
                .toList(),
            onChanged: (e) {
              if (e != null) {
                setState(() {
                  _currentEngine = e;
                  _currentVoice = e.voices.first;
                });
              }
            },
          ),
          DropdownButton<TtsVoice>(
            value: _currentEngine.voices.contains(_currentVoice) ? _currentVoice : _currentEngine.voices.first,
            items: _currentEngine.voices
                .map((v) => DropdownMenuItem(value: v, child: Text(v.name)))
                .toList(),
            onChanged: (v) {
              if (v != null) setState(() => _currentVoice = v);
            },
          ),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text("语速: "),
              SizedBox(
                width: 90,
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
          DropdownButton<int>(
            value: _bitrate,
            items: const [
              DropdownMenuItem(value: 64, child: Text("省流 64k")),
              DropdownMenuItem(value: 128, child: Text("高清 128k")),
            ],
            onChanged: (b) => setState(() => _bitrate = b ?? 64),
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
            setState(() {
              _textController.text = content;
            });
            LogManager.instance.log("FILE", "成功拖入文件: ${file.name} (大小: ${content.length} 字符)");
          } else {
            ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("仅支持拖拽 .txt 和 .md 格式文件！")));
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
                    hintText: "【操作提示】\n1. 可直接按 Ctrl+V 粘贴任意文字\n2. 可直接从桌面上拖拽 .txt 或 .md 文档进本窗口\n3. 点击上方【开始】即可体验纯 RAM 流畅阅读",
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
          const Text("⚙️ 朗读微调参数", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
          const SizedBox(height: 8),
          Text("预读数量: $_preloadCount 句 (RAM 缓冲)"),
          Slider(
            value: _preloadCount.toDouble(),
            min: 1,
            max: 8,
            divisions: 7,
            onChanged: (v) => setState(() => _preloadCount = v.toInt()),
          ),
          Text("并发线程: $_concurrency (网络拉取)"),
          Slider(
            value: _concurrency.toDouble(),
            min: 1,
            max: 4,
            divisions: 3,
            onChanged: (v) => setState(() => _concurrency = v.toInt()),
          ),
          Text("句子间隔停顿: ${_sentenceGapMs}ms"),
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
              padding: const EdgeInsets.symmetric(horizontal: 8, pady: 4),
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
