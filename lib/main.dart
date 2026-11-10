import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_picker/file_picker.dart';

// 引入独立的 TTS 引擎模块
import 'tts_engine.dart';

void main() {
  HttpOverrides.global = DynamicHttpOverrides();
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const TtsReaderApp());
}

class TtsReaderApp extends StatelessWidget {
  const TtsReaderApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '万能 TTS 朗读与发音人评测工具',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF5E35B1),
          brightness: Brightness.light,
        ),
        scaffoldBackgroundColor: const Color(0xFFF7F8FA),
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

class _ReaderHomePageState extends State<ReaderHomePage> with SingleTickerProviderStateMixin {
  final TextEditingController _textController = TextEditingController();
  final ScrollController _logScrollController = ScrollController();
  final AudioPlayer _audioPlayer = AudioPlayer();

  late TabController _tabController;
  late List<CustomTtsEngine> _engines;
  late CustomTtsEngine _currentEngine;
  late TtsVoice _currentVoice;

  double _speed = 1.75;
  int _bitrate = 64;
  int _preloadCount = 4;
  int _concurrency = 2;
  int _sentenceGapMs = 200;

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
    _tabController = TabController(length: 3, vsync: this);
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
        _sentenceGapMs = data['sentenceGapMs'] ?? 200;

        AppProxyManager.instance.mode = data['proxyMode'] ?? "auto";
        AppProxyManager.instance.customHost = data['proxyHost'] ?? "127.0.0.1";
        AppProxyManager.instance.customPort = data['proxyPort'] ?? 7890;

        final list = (data['engines'] as List<dynamic>?)?.map((e) => CustomTtsEngine.fromJson(e)).toList();
        if (list != null && list.isNotEmpty) {
          _engines = list;
          _currentEngine = _engines.first;
          _currentVoice = _currentEngine.voices.isNotEmpty ? _currentEngine.voices.first : TtsVoice(id: '', name: '默认');
          LogManager.instance.log("CONFIG", "已自动恢复本地持久化配置");
          return;
        }
      }
    } catch (e) {
      LogManager.instance.log("CONFIG-ERR", "加载本地配置失败: $e，初始化默认引擎库");
    }
    _engines = DefaultEnginePresets.get();
    _currentEngine = _engines.first;
    _currentVoice = _currentEngine.voices.first;
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
      LogManager.instance.log("CONFIG", "配置已成功保存至本地 tts_config.json");
    } catch (e) {
      LogManager.instance.log("CONFIG-ERR", "自动保存失败: $e");
    }
  }

  // ──────────────── 音频解码与物理倍速 ────────────────
  Future<void> _playAudioFromRam(Uint8List bytes) async {
    try {
      await _audioPlayer.stop();
      await _audioPlayer.setVolume(1.0);
      await _audioPlayer.setPlaybackRate(_speed);
      await _audioPlayer.play(BytesSource(bytes, mimeType: 'audio/mpeg'));
      await _audioPlayer.setPlaybackRate(_speed); // 保证 Windows 硬件级强制变速
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
    _tabController.dispose();
    _audioPlayer.dispose();
    _textController.dispose();
    _logScrollController.dispose();
    super.dispose();
  }

  // ──────────────── 发音人即时试听 ────────────────
  Future<void> _previewVoice(CustomTtsEngine engine, TtsVoice voice) async {
    LogManager.instance.log("PREVIEW", "正在以 [${_speed.toStringAsFixed(2)}x] 倍速试听发音人: [${voice.name}]...");
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text("正在生成 [${voice.name}] 的试听音频..."),
      duration: const Duration(seconds: 2),
    ));

    try {
      final bytes = await UniversalTtsExecutor.synthesize(
        engine: engine,
        text: "你好，这是一条试听语音。正在验证发音人：${voice.name} 的朗读效果。",
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
            content: Text("错误信息：\n$e"),
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
              "• 往返耗时: ${(sw.elapsedMilliseconds / 1000).toStringAsFixed(2)} 秒\n"
              "• 音频大小: ${(bytes.lengthInBytes / 1024).toStringAsFixed(1)} KB\n"
              "• 生效倍速: ${_speed.toStringAsFixed(2)}x\n"
              "• 代理状态: ${AppProxyManager.instance.getProxyString(Uri())}\n\n"
              "扬声器已播放试听音频，能听到声音说明整条链路完全通畅！",
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
            content: Text("错误原因：\n$e"),
            actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text("知道了"))],
          ),
        );
      }
    }
  }

  // ──────────────── 朗读流程 ────────────────
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
    LogManager.instance.log("TEXT", "正文已切分为 ${_sentences.length} 个独立句子");
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
            content: Text("朗读中断：未能获取到音频。请检查引擎配置或查看日志！"),
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
        LogManager.instance.log("EXPORT-ERR", "第 ${i + 1} 句导出失败: $e");
      }
    }
    await File(savePath).writeAsBytes(exportBytes.toBytes());
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("音频已成功导出至：$savePath")));
  }

  // ──────────────── 全局网络代理弹窗 ────────────────
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
                Icon(Icons.lan, color: Color(0xFF5E35B1)),
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
                  RadioListTile<String>(
                    value: "auto",
                    groupValue: currentMode,
                    title: const Text("🟢 自动检测系统代理 (推荐)", style: TextStyle(fontWeight: FontWeight.bold)),
                    subtitle: Text(
                      detected != null ? "自动嗅探到 Windows 生效代理: $detected" : "未检测到系统代理（若开了代理软件请确认开启【系统代理】）",
                      style: TextStyle(color: detected != null ? Colors.green.shade700 : Colors.orange.shade800, fontSize: 11),
                    ),
                    onChanged: (v) => setDlgState(() => currentMode = v!),
                  ),
                  RadioListTile<String>(
                    value: "custom",
                    groupValue: currentMode,
                    title: const Text("🟡 自定义代理端口", style: TextStyle(fontWeight: FontWeight.bold)),
                    subtitle: const Text("支持 Clash 7890、v2rayN 10809、SS 1080 等任意端口", style: TextStyle(fontSize: 11)),
                    onChanged: (v) => setDlgState(() => currentMode = v!),
                  ),
                  if (currentMode == "custom")
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 6),
                      child: Row(
                        children: [
                          Expanded(flex: 3, child: TextField(controller: hostCtrl, decoration: const InputDecoration(labelText: "代理 IP", isDense: true, border: OutlineInputBorder()))),
                          const SizedBox(width: 8),
                          Expanded(flex: 2, child: TextField(controller: portCtrl, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: "端口", isDense: true, border: OutlineInputBorder()))),
                        ],
                      ),
                    ),
                  RadioListTile<String>(
                    value: "direct",
                    groupValue: currentMode,
                    title: const Text("🔴 纯直连模式", style: TextStyle(fontWeight: FontWeight.bold)),
                    subtitle: const Text("国内网络裸连（适合 Cloudflare 中转域名或已开启 TUN 网卡）", style: TextStyle(fontSize: 11)),
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
                  LogManager.instance.log("PROXY", "代理切换为: $currentMode (${AppProxyManager.instance.getProxyString(Uri())})");
                },
                child: const Text("保存生效"),
              ),
            ],
          );
        },
      ),
    );
  }

  // ──────────────── 引擎规则配置弹窗 ────────────────
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
                label: const Text("新增自定义引擎"),
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
                        tooltip: "连通性测试与试听",
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
          actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text("完成"))],
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
                      DropdownMenuItem(value: AudioResponseType.namiAi, child: Text("纳米AI 专用协议 (带时间戳、动态签名、MID 校验)")),
                    ],
                    onChanged: (t) => setSubState(() => respType = t ?? AudioResponseType.binaryStream),
                  ),
                  if (respType == AudioResponseType.jsonBase64 || respType == AudioResponseType.jsonUrl) ...[
                    const SizedBox(height: 8),
                    TextField(controller: jsonPathCtrl, decoration: const InputDecoration(labelText: "JSON 音频提取路径", border: OutlineInputBorder())),
                  ],
                  const Divider(height: 25),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text("发音人列表:", style: TextStyle(fontWeight: FontWeight.bold)),
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
        title: Row(
          children: [
            const Icon(Icons.record_voice_over, color: Color(0xFF5E35B1)),
            const SizedBox(width: 10),
            const Text("TTS 小说朗读工具", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
            const SizedBox(width: 12),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: BoxDecoration(color: const Color(0xFFEDE7F6), borderRadius: BorderRadius.circular(12)),
              child: Text("当前引擎: ${_currentEngine.name}", style: const TextStyle(fontSize: 12, color: Color(0xFF5E35B1), fontWeight: FontWeight.bold)),
            ),
          ],
        ),
        backgroundColor: Colors.white,
        elevation: 0.5,
        actions: [
          IconButton(
            tooltip: "全局网络与代理配置",
            icon: const Icon(Icons.lan, color: Color(0xFF5E35B1)),
            onPressed: _openProxySettingsDialog,
          ),
          IconButton(
            tooltip: "自定义 TTS 引擎库",
            icon: const Icon(Icons.tune, color: Color(0xFF5E35B1)),
            onPressed: _openEngineManagerDialog,
          ),
          IconButton(
            tooltip: "批量合成导出 MP3",
            icon: const Icon(Icons.save_alt, color: Color(0xFF5E35B1)),
            onPressed: _exportAudio,
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: Column(
        children: [
          _buildModernTopBar(),
          Expanded(
            child: Row(
              children: [
                Expanded(flex: 7, child: _buildReadingCanvas()),
                Container(
                  width: 340,
                  decoration: BoxDecoration(
                    color: Colors.white,
                    border: Border(left: BorderSide(color: Colors.grey.shade200)),
                  ),
                  child: _buildRightTabbedConsole(),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // 现代轻量化顶部播控栏
  Widget _buildModernTopBar() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border(bottom: BorderSide(color: Colors.grey.shade200)),
      ),
      child: Row(
        children: [
          // 引擎下拉
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10),
            decoration: BoxDecoration(color: Colors.grey.shade100, borderRadius: BorderRadius.circular(8)),
            child: DropdownButtonHideUnderline(
              child: DropdownButton<CustomTtsEngine>(
                value: _currentEngine,
                items: _engines.map((e) => DropdownMenuItem(value: e, child: Text(e.name, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold)))).toList(),
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
            ),
          ),
          const SizedBox(width: 8),
          // 发音人下拉
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10),
            decoration: BoxDecoration(color: Colors.grey.shade100, borderRadius: BorderRadius.circular(8)),
            child: DropdownButtonHideUnderline(
              child: DropdownButton<TtsVoice>(
                value: _currentEngine.voices.contains(_currentVoice) ? _currentVoice : _currentEngine.voices.firstOrNull,
                items: _currentEngine.voices.map((v) => DropdownMenuItem(value: v, child: Text(v.name, style: const TextStyle(fontSize: 13)))).toList(),
                onChanged: (v) {
                  if (v != null) {
                    setState(() => _currentVoice = v);
                    _saveConfig();
                  }
                },
              ),
            ),
          ),
          const SizedBox(width: 6),
          // 试听
          IconButton(
            icon: const Icon(Icons.volume_up, color: Color(0xFF5E35B1)),
            tooltip: "试听当前发音人",
            onPressed: () => _previewVoice(_currentEngine, _currentVoice),
          ),
          const VerticalDivider(width: 24, thickness: 1, indent: 8, endIndent: 8),

          // 物理倍速滑动器 (支持边播边拉)
          Row(
            children: [
              const Text("语速:", style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
              SizedBox(
                width: 100,
                child: Slider(
                  value: _speed,
                  min: 0.5,
                  max: 2.0,
                  divisions: 6,
                  label: "${_speed}x",
                  onChanged: (val) {
                    setState(() => _speed = val);
                    _audioPlayer.setPlaybackRate(val);
                    _saveConfig();
                  },
                ),
              ),
              Text("${_speed.toStringAsFixed(2)}x", style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Color(0xFF5E35B1))),
            ],
          ),
          const SizedBox(width: 10),

          // 码率
          DropdownButton<int>(
            value: _bitrate,
            underline: const SizedBox(),
            items: const [DropdownMenuItem(value: 64, child: Text("64k", style: TextStyle(fontSize: 12))), DropdownMenuItem(value: 128, child: Text("128k", style: TextStyle(fontSize: 12)))],
            onChanged: (b) {
              setState(() => _bitrate = b ?? 64);
              _saveConfig();
            },
          ),
          const Spacer(),

          // 播控按钮组
          FilledButton.icon(
            style: FilledButton.styleFrom(backgroundColor: _isPlaying ? Colors.grey : const Color(0xFF2E7D32)),
            icon: const Icon(Icons.play_arrow, size: 18),
            label: const Text("开始"),
            onPressed: _isPlaying ? null : _startPlayback,
          ),
          const SizedBox(width: 6),
          FilledButton.tonalIcon(
            icon: Icon(_isPaused ? Icons.play_arrow : Icons.pause, size: 18),
            label: Text(_isPaused ? "继续" : "暂停"),
            onPressed: _isPlaying ? _togglePause : null,
          ),
          const SizedBox(width: 6),
          FilledButton.icon(
            style: FilledButton.styleFrom(backgroundColor: const Color(0xFFC62828)),
            icon: const Icon(Icons.stop, size: 18),
            label: const Text("停止"),
            onPressed: _isPlaying ? () => _stopPlayback("手动停止") : null,
          ),
        ],
      ),
    );
  }

  // 类纸质阅读体验主视窗
  Widget _buildReadingCanvas() {
    return DropTarget(
      onDragDone: (detail) async {
        final file = detail.files.first;
        if (file.path.endsWith('.txt') || file.path.endsWith('.md')) {
          final content = await File(file.path).readAsString();
          setState(() => _textController.text = content);
          LogManager.instance.log("FILE", "成功拖入文件: ${file.name} (大小: ${content.length} 字符)");
        } else {
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("仅支持拖入 .txt 和 .md 格式文件！")));
        }
      },
      child: Container(
        color: const Color(0xFFF9F9F8),
        padding: const EdgeInsets.all(20),
        child: Column(
          children: [
            // 正读句子进度条高亮卡片
            if (_sentences.isNotEmpty && _currentSentenceIndex >= 0)
              Container(
                margin: const EdgeInsets.only(bottom: 12),
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                decoration: BoxDecoration(
                  color: const Color(0xFFFFF8E1),
                  border: Border.all(color: const Color(0xFFFFE082)),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.volume_up, color: Color(0xFFE65100), size: 20),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        "正在朗读 [${_currentSentenceIndex + 1}/${_sentences.length}]: ${_sentences[_currentSentenceIndex]}",
                        style: const TextStyle(color: Color(0xFF4E342E), fontWeight: FontWeight.bold, fontSize: 13),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ),

            // 主文本编辑阅读区域
            Expanded(
              child: Container(
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(10),
                  boxShadow: [
                    BoxShadow(color: Colors.black.withOpacity(0.02), blurRadius: 6, offset: const Offset(0, 2))
                  ],
                ),
                padding: const EdgeInsets.all(16),
                child: TextField(
                  controller: _textController,
                  maxLines: null,
                  expands: true,
                  textAlignVertical: TextAlignVertical.top,
                  style: const TextStyle(fontSize: 15, height: 1.6, color: Color(0xFF263238)),
                  decoration: const InputDecoration(
                    hintText: "【阅读指引】\n• 直接在此处粘贴任意文本，或将 .txt / .md 小说文件拖入本窗口\n• 默认已内置免密的 [纳米AI] 与 [Cloudflare 中转]，开箱即用\n• 点击顶部【开始】启动朗读，支持在阅读中直接拖动【语速】实时物理变速",
                    border: InputBorder.none,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // 右侧现代化三标签控制台
  Widget _buildRightTabbedConsole() {
    return Column(
      children: [
        TabBar(
          controller: _tabController,
          labelColor: const Color(0xFF5E35B1),
          unselectedLabelColor: Colors.grey,
          indicatorColor: const Color(0xFF5E35B1),
          tabs: const [
            Tab(text: "流水线调优"),
            Tab(text: "实时日志"),
            Tab(text: "网络状态"),
          ],
        ),
        Expanded(
          child: TabBarView(
            controller: _tabController,
            children: [
              _buildPipelineSettingsTab(),
              _buildLiveLogTab(),
              _buildNetworkStatusTab(),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildPipelineSettingsTab() {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: ListView(
        children: [
          const Text("预读深度 (RAM 内存缓冲)", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
          Slider(
            value: _preloadCount.toDouble(),
            min: 1,
            max: 8,
            divisions: 7,
            label: "$_preloadCount 句",
            onChanged: (v) {
              setState(() => _preloadCount = v.toInt());
              _saveConfig();
            },
          ),
          const SizedBox(height: 8),
          const Text("网络并发拉取线程数", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
          Slider(
            value: _concurrency.toDouble(),
            min: 1,
            max: 4,
            divisions: 3,
            label: "$_concurrency 条",
            onChanged: (v) {
              setState(() => _concurrency = v.toInt());
              _saveConfig();
            },
          ),
          const SizedBox(height: 8),
          const Text("句子间停顿时间", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
          Slider(
            value: _sentenceGapMs.toDouble(),
            min: 0,
            max: 1000,
            divisions: 10,
            label: "${_sentenceGapMs}ms",
            onChanged: (v) {
              setState(() => _sentenceGapMs = v.toInt());
              _saveConfig();
            },
          ),
          const Divider(height: 32),
          OutlinedButton.icon(
            icon: const Icon(Icons.file_download, size: 16),
            label: const Text("导出当前所有配置备份"),
            onPressed: () async {
              final savePath = await FilePicker.platform.saveFile(
                dialogTitle: '导出配置',
                fileName: 'tts_config_backup.json',
                type: FileType.custom,
                allowedExtensions: ['json'],
              );
              if (savePath != null) {
                _saveConfig();
                await File(_localConfigFile.path).copy(savePath);
                if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("已备份至: $savePath")));
              }
            },
          ),
        ],
      ),
    );
  }

  Widget _buildLiveLogTab() {
    return Column(
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          color: Colors.grey.shade100,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text("输出监控", style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
              Row(
                children: [
                  IconButton(
                    icon: const Icon(Icons.save_as, size: 16),
                    tooltip: "保存日志文件",
                    onPressed: () async {
                      final path = await LogManager.instance.exportLogsToFile();
                      if (path != null && mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("日志已存至: $path")));
                    },
                  ),
                  IconButton(
                    icon: const Icon(Icons.clear_all, size: 16),
                    tooltip: "清空",
                    onPressed: () => LogManager.instance.clear(),
                  ),
                ],
              )
            ],
          ),
        ),
        Expanded(
          child: Container(
            color: const Color(0xFF1E1E1E),
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
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                    child: Text(logs[idx], style: const TextStyle(color: Colors.lightGreenAccent, fontFamily: "Consolas", fontSize: 11)),
                  ),
                );
              },
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildNetworkStatusTab() {
    final currentProxy = AppProxyManager.instance.getProxyString(Uri());
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text("当前全局网络模式", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
          const SizedBox(height: 8),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(color: const Color(0xFFEDE7F6), borderRadius: BorderRadius.circular(8)),
            child: Text("路由策略: ${AppProxyManager.instance.mode}\n当前通道: $currentProxy", style: const TextStyle(color: Color(0xFF5E35B1), fontWeight: FontWeight.bold, fontSize: 12)),
          ),
          const SizedBox(height: 16),
          FilledButton.tonalIcon(
            icon: const Icon(Icons.settings_ethernet, size: 16),
            label: const Text("修改代理模式与端口"),
            onPressed: _openProxySettingsDialog,
          ),
        ],
      ),
    );
  }
}
