// app.dart
import 'dart:math';
import 'package:characters/characters.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';
import 'logic.dart';
import 'package:share_plus/share_plus.dart';
import 'package:file_picker/file_picker.dart';

const kBg = Color(0xFF0A0A0A);
const kSurface = Color(0xFF141414);
const kBorder = Color(0xFF242424);
const kAccent = Color(0xFFE8D5B0);
const kAccentDim = Color(0x44E8D5B0);
const kTextPrimary = Color(0xFFEEE8DC);
const kTextSecondary = Color(0xFF888070);
const kTextMuted = Color(0xFF444038);
const kSuccess = Color(0xFF6FCF6F);
const kError = Color(0xFFCF6F6F);

class WriterApp extends StatelessWidget {
  const WriterApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          brightness: Brightness.dark,
          scaffoldBackgroundColor: kBg,
          fontFamily: 'monospace',
        ),
        home: const _MainScreen(),
      );
}

class _MainScreen extends StatefulWidget {
  const _MainScreen();
  @override
  State<_MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends State<_MainScreen> {
  OverlayEntry? _toastEntry;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      context.read<AppState>().init();
      context.read<AppState>().addListener(_onStateChange);
    });
  }

  @override
  void dispose() {
    context.read<AppState>().removeListener(_onStateChange);
    _toastEntry?.remove();
    super.dispose();
  }

  void _onStateChange() {
    final state = context.read<AppState>();
    final toast = state.pendingToast;
    if (toast == null) return;
    state.consumeToast();
    _showEmbeddingToast(toast);
  }

  void _showEmbeddingToast(ToastMessage toast) {
    _toastEntry?.remove();
    _toastEntry = null;
    final entry = OverlayEntry(
      builder: (_) => _EmbeddingToast(
        message: toast,
        onDone: () {
          _toastEntry?.remove();
          _toastEntry = null;
        },
      ),
    );
    _toastEntry = entry;
    Overlay.of(context).insert(entry);
  }

  void _openSettings() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: kSurface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(8)),
        side: BorderSide(color: kBorder),
      ),
      builder: (_) => ChangeNotifierProvider.value(
        value: context.read<AppState>(),
        child: const _SettingsSheet(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    if (state.initError != null) {
      return Scaffold(
        backgroundColor: kBg,
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Text(state.initError!,
                style: const TextStyle(color: kError, fontSize: 11),
                textAlign: TextAlign.center),
          ),
        ),
      );
    }
    if (!state.ready) {
      return const Scaffold(
        backgroundColor: kBg,
        body: Center(
          child: SizedBox(
            width: 16,
            height: 16,
            child:
                CircularProgressIndicator(strokeWidth: 1.5, color: kAccentDim),
          ),
        ),
      );
    }
    return Scaffold(
      backgroundColor: kBg,
      body: SafeArea(
        child: Stack(
          children: [
            const _Body(),
            Positioned(
              top: 8,
              right: 12,
              child: GestureDetector(
                onTap: _openSettings,
                child: Container(
                  padding: const EdgeInsets.all(6),
                  decoration: BoxDecoration(
                    color: kBg,
                    border: Border.all(color: kBorder),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Stack(
                    clipBehavior: Clip.none,
                    children: [
                      const Icon(Icons.settings, color: kTextMuted, size: 16),
                      if (state.pendingUploadCount > 0)
                        Positioned(
                          right: -5,
                          top: -5,
                          child: Container(
                            padding: const EdgeInsets.all(2),
                            decoration: const BoxDecoration(
                              color: kAccent,
                              shape: BoxShape.circle,
                            ),
                            child: Text(
                              '${state.pendingUploadCount}',
                              style: const TextStyle(color: kBg, fontSize: 7),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Settings Sheet ────────────────────────────────────────────────────────────

class _SettingsSheet extends StatefulWidget {
  const _SettingsSheet();
  @override
  State<_SettingsSheet> createState() => _SettingsSheetState();
}

class _SettingsSheetState extends State<_SettingsSheet> {
  late TextEditingController _serverUrlCtrl;
  late TextEditingController _apiKeyCtrl;
  late TextEditingController _batchNameCtrl;
  late TextEditingController _modelImportUrlCtrl;
  late bool _autoDelete;

  String? _statusMsg;
  bool _isOk = false;
  bool _loading = false;

  ExportStatus _exportStatus = ExportStatus.idle;
  int _exportedCount = 0;
  String? _exportBatchId;

  ModelImportStatus _importStatus = ModelImportStatus.idle;
  String? _importedVersion;

  @override
  void initState() {
    super.initState();
    final s = context.read<AppState>().settings;
    _serverUrlCtrl = TextEditingController(text: s.serverUrl);
    _apiKeyCtrl = TextEditingController(text: s.apiKey);
    _batchNameCtrl = TextEditingController(text: s.batchName);
    _modelImportUrlCtrl = TextEditingController(
        text: s.modelImportUrl.isNotEmpty ? s.modelImportUrl : s.serverUrl);
    _autoDelete = s.autoDeleteAfterUpload;
  }

  @override
  void dispose() {
    _serverUrlCtrl.dispose();
    _apiKeyCtrl.dispose();
    _batchNameCtrl.dispose();
    _modelImportUrlCtrl.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final appState = context.read<AppState>();
    final updated = appState.settings.copyWith(
      serverUrl: _serverUrlCtrl.text.trim(),
      apiKey: _apiKeyCtrl.text.trim(),
      batchName: _batchNameCtrl.text.trim(),
      modelImportUrl: _modelImportUrlCtrl.text.trim(),
      autoDeleteAfterUpload: _autoDelete,
    );
    await appState.updateSettings(updated);
  }

  Future<void> _exportPrototypes() async {
    setState(() {
      _loading = true;
      _statusMsg = null;
    });
    String? tempPath;
    try {
      tempPath = await context.read<AppState>().exportPrototypesToTemp();
      if (tempPath == null) {
        setState(() {
          _isOk = false;
          _statusMsg = 'export failed';
        });
        return;
      }
      final result = await Share.shareXFiles(
        [XFile(tempPath)],
        subject: 'Prototypes backup',
      );
      setState(() {
        _isOk = true;
        _statusMsg = result.status == ShareResultStatus.dismissed
            ? 'cancelled'
            : 'shared successfully';
      });
    } catch (e) {
      setState(() {
        _isOk = false;
        _statusMsg = 'export failed: $e';
      });
    } finally {
      if (tempPath != null) {
        try {
          File(tempPath).deleteSync();
        } catch (_) {}
      }
      setState(() {
        _loading = false;
      });
    }
  }

  Future<void> _importPrototypes() async {
    setState(() {
      _loading = true;
      _statusMsg = null;
    });
    try {
      final picked = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['json'],
      );
      if (picked == null || picked.files.single.path == null) {
        setState(() {
          _loading = false;
          _statusMsg = 'cancelled';
          _isOk = false;
        });
        return;
      }
      final result = await context
          .read<AppState>()
          .importPrototypesFromFile(picked.files.single.path!);
      setState(() {
        _isOk = result?.success ?? false;
        _statusMsg = result == null
            ? 'import failed'
            : result.success
                ? 'merged ${result.mergedPrototypes} protos · '
                    'added ${result.addedEmbeddings} embeddings'
                : 'import failed: ${result.errorMsg}';
      });
    } catch (e) {
      setState(() {
        _isOk = false;
        _statusMsg = 'import failed: $e';
      });
    } finally {
      setState(() {
        _loading = false;
      });
    }
  }

  Future<void> _testConnection() async {
    await _save();
    setState(() {
      _loading = true;
      _statusMsg = null;
    });
    final ok = await DatasetExportService.testConnection(
      _serverUrlCtrl.text.trim(),
      _apiKeyCtrl.text.trim(),
    );
    setState(() {
      _loading = false;
      _isOk = ok;
      _statusMsg = ok ? 'connected' : 'connection failed';
    });
  }

  Future<void> _exportDataset() async {
    await _save();
    setState(() {
      _exportStatus = ExportStatus.exporting;
      _statusMsg = null;
    });
    final result = await DatasetExportService.exportDataset(
      settings: context.read<AppState>().settings,
    );
    setState(() {
      _exportStatus = result.status;
      _exportedCount = result.uploadedCount;
      _exportBatchId = result.batchId;
      _statusMsg = result.status == ExportStatus.success
          ? 'uploaded ${result.uploadedCount} samples · ${result.batchId}'
          : 'export failed: ${result.errorMsg}';
      _isOk = result.status == ExportStatus.success;
    });
    // ignore: use_build_context_synchronously
    if (mounted) context.read<AppState>().init();
  }

  Future<void> _importEncoder() async {
    await _save();
    setState(() {
      _importStatus = ModelImportStatus.loading;
      _statusMsg = null;
    });
    final s = context.read<AppState>().settings;
    final importUrl = _modelImportUrlCtrl.text.trim().isNotEmpty
        ? _modelImportUrlCtrl.text.trim()
        : _serverUrlCtrl.text.trim();
    final result = await ModelImportService.importEncoder(
      importUrl: importUrl,
      apiKey: s.apiKey,
      currentSettings: s,
    );
    setState(() {
      _importStatus = result.status;
      _importedVersion = result.version;
      _statusMsg = result.status == ModelImportStatus.success
          ? 'encoder imported · ${result.version ?? 'unknown'} · ready'
          : 'import failed: ${result.errorMsg}';
      _isOk = result.status == ModelImportStatus.success;
    });
    if (mounted && result.status == ModelImportStatus.success) {
      context.read<AppState>().updateSettings(
            context.read<AppState>().settings.copyWith(
                  lastImportedModelVersion: result.version,
                  lastImportedAt: DateTime.now(),
                ),
          );
    }
  }

  Future<void> _clearLocalSamples() async {
    await DbService.deleteAllLocalExportSamples();
    if (mounted) {
      setState(() {
        _statusMsg = 'local samples cleared';
        _isOk = true;
      });
      context.read<AppState>().init();
    }
  }

  @override
  Widget build(BuildContext context) {
    final appState = context.watch<AppState>();
    final s = appState.settings;
    final modelHasLocal = EmbeddingEncoder.hasImportedModel();

    return Padding(
      padding:
          EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 20, 16, 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              const Text('Settings',
                  style: TextStyle(
                      color: kTextSecondary, fontSize: 11, letterSpacing: 1.2)),
              const Spacer(),
              GestureDetector(
                onTap: () => Navigator.pop(context),
                child: const Text('Close',
                    style: TextStyle(
                        color: kTextMuted, fontSize: 10, letterSpacing: 0.8)),
              ),
            ]),
            const SizedBox(height: 16),
            Row(children: [
              const Text('stroke width',
                  style: TextStyle(
                      color: kTextMuted, fontSize: 9, letterSpacing: 0.8)),
              Expanded(
                child: SliderTheme(
                  data: SliderTheme.of(context).copyWith(
                    activeTrackColor: kAccent.withOpacity(0.6),
                    inactiveTrackColor: kBorder,
                    thumbColor: kAccent,
                    thumbShape:
                        const RoundSliderThumbShape(enabledThumbRadius: 6),
                    trackHeight: 1.5,
                    overlayShape: SliderComponentShape.noOverlay,
                  ),
                  child: Slider(
                    value: appState.strokeWidth,
                    min: 4.0,
                    max: 24.0,
                    onChanged: (v) => appState.setStrokeWidth(v),
                  ),
                ),
              ),
            ]),
            const SizedBox(height: 10),
            _SettingsField(
                label: 'server url',
                controller: _serverUrlCtrl,
                hint: 'http://localhost:8000'),
            const SizedBox(height: 10),
            _SettingsField(
                label: 'api key',
                controller: _apiKeyCtrl,
                hint: 'optional',
                obscure: true),
            const SizedBox(height: 10),
            _SettingsField(
                label: 'batch name',
                controller: _batchNameCtrl,
                hint: 'batch_001'),
            const SizedBox(height: 10),
            _SettingsField(
                label: 'model import url',
                controller: _modelImportUrlCtrl,
                hint: 'defaults to server url/import'),
            const SizedBox(height: 12),
            Row(children: [
              const Text('auto delete after upload',
                  style: TextStyle(
                      color: kTextSecondary, fontSize: 10, letterSpacing: 0.5)),
              const Spacer(),
              GestureDetector(
                onTap: () => setState(() => _autoDelete = !_autoDelete),
                child: Container(
                  width: 36,
                  height: 18,
                  decoration: BoxDecoration(
                    color: _autoDelete ? kAccentDim : kBorder,
                    borderRadius: BorderRadius.circular(9),
                  ),
                  child: AnimatedAlign(
                    duration: const Duration(milliseconds: 150),
                    alignment: _autoDelete
                        ? Alignment.centerRight
                        : Alignment.centerLeft,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 2),
                      child: Container(
                        width: 14,
                        height: 14,
                        decoration: BoxDecoration(
                          color: _autoDelete ? kAccent : kTextMuted,
                          shape: BoxShape.circle,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ]),
            const SizedBox(height: 16),
            Wrap(spacing: 6, runSpacing: 4, children: [
              _InfoChip(
                  label: 'pending', value: '${appState.pendingUploadCount}'),
              if (s.lastUploadBatchId != null)
                _InfoChip(
                    label: 'last batch',
                    value: s.lastUploadBatchId!
                        .substring(0, min(18, s.lastUploadBatchId!.length))),
              if (s.lastImportedModelVersion != null)
                _InfoChip(
                    label: 'model',
                    value: s.lastImportedModelVersion!,
                    ok: modelHasLocal),
              _PrototypeCountChip(),
            ]),
            const SizedBox(height: 14),
            Row(children: [
              Expanded(
                  child: _SheetBtn(
                      label: _loading ? '…' : 'Test connection',
                      enabled: !_loading,
                      onTap: _testConnection)),
              const SizedBox(width: 8),
              Expanded(
                  child: _SheetBtn(
                      label: _exportStatus == ExportStatus.exporting
                          ? 'Exporting…'
                          : 'Export dataset',
                      enabled: _exportStatus != ExportStatus.exporting,
                      accent: true,
                      onTap: _exportDataset)),
            ]),
            const SizedBox(height: 8),
            Row(children: [
              Expanded(
                  child: _SheetBtn(
                      label: _importStatus == ModelImportStatus.loading
                          ? 'Importing…'
                          : 'Import encoder',
                      enabled: _importStatus != ModelImportStatus.loading,
                      onTap: _importEncoder)),
              const SizedBox(width: 8),
              Expanded(
                  child: _SheetBtn(
                      label: 'Clear local samples',
                      enabled: true,
                      onTap: _clearLocalSamples)),
            ]),
            const SizedBox(height: 8),
            Row(children: [
              Expanded(
                child: _SheetBtn(
                  label: _loading ? '…' : 'Export prototypes',
                  enabled: !_loading,
                  onTap: _exportPrototypes,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _SheetBtn(
                  label: _loading ? '…' : 'Import prototypes',
                  enabled: !_loading,
                  onTap: _importPrototypes,
                ),
              ),
            ]),
            const SizedBox(height: 12),
            if (_statusMsg != null)
              Container(
                width: double.infinity,
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                decoration: BoxDecoration(
                  border: Border.all(
                      color: _isOk
                          ? kSuccess.withOpacity(0.4)
                          : kError.withOpacity(0.4)),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(_statusMsg!,
                    style: TextStyle(
                        color: _isOk ? kSuccess : kError,
                        fontSize: 10,
                        letterSpacing: 0.4)),
              ),
          ],
        ),
      ),
    );
  }
}

class _PrototypeCountChip extends StatelessWidget {
  const _PrototypeCountChip();

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<Map<String, dynamic>>>(
      future: DbService.getAllPrototypes(),
      builder: (ctx, snap) {
        final count = snap.data?.length ?? 0;
        return _InfoChip(
          label: 'prototypes',
          value: '$count',
          ok: count > 0 ? true : false,
        );
      },
    );
  }
}
// ── Settings field ────────────────────────────────────────────────────────────

class _SettingsField extends StatelessWidget {
  final String label;
  final TextEditingController controller;
  final String hint;
  final bool obscure;
  const _SettingsField(
      {required this.label,
      required this.controller,
      this.hint = '',
      this.obscure = false});

  @override
  Widget build(BuildContext context) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(label,
          style: const TextStyle(
              color: kTextMuted, fontSize: 9, letterSpacing: 0.8)),
      const SizedBox(height: 4),
      TextField(
        controller: controller,
        obscureText: obscure,
        style: const TextStyle(color: kTextPrimary, fontSize: 12),
        cursorColor: kAccent,
        decoration: InputDecoration(
          hintText: hint,
          hintStyle: const TextStyle(color: kTextMuted, fontSize: 11),
          isDense: true,
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          filled: true,
          fillColor: kBg,
          border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(4),
              borderSide: const BorderSide(color: kBorder)),
          enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(4),
              borderSide: const BorderSide(color: kBorder)),
          focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(4),
              borderSide: const BorderSide(color: kAccent, width: 1)),
        ),
      ),
    ]);
  }
}

class _InfoChip extends StatelessWidget {
  final String label, value;
  final bool? ok;
  const _InfoChip({required this.label, required this.value, this.ok});

  @override
  Widget build(BuildContext context) {
    final color = ok == null
        ? kTextMuted
        : ok!
            ? kSuccess
            : kError;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
          border: Border.all(color: kBorder),
          borderRadius: BorderRadius.circular(3)),
      child: RichText(
          text: TextSpan(children: [
        TextSpan(
            text: '$label ',
            style: const TextStyle(
                color: kTextMuted, fontSize: 9, letterSpacing: 0.4)),
        TextSpan(
            text: value,
            style: TextStyle(
                color: color,
                fontSize: 9,
                fontWeight: FontWeight.w500,
                letterSpacing: 0.3)),
      ])),
    );
  }
}

class _SheetBtn extends StatelessWidget {
  final String label;
  final bool enabled, accent;
  final VoidCallback onTap;
  const _SheetBtn(
      {required this.label,
      required this.enabled,
      required this.onTap,
      this.accent = false});

  @override
  Widget build(BuildContext context) {
    final fg = enabled ? (accent ? kBg : kTextSecondary) : kTextMuted;
    final bg = accent && enabled ? kAccent : Colors.transparent;
    final border =
        enabled ? (accent ? kAccent : kBorder) : kBorder.withOpacity(0.4);
    return GestureDetector(
      onTap: enabled ? onTap : null,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
        decoration: BoxDecoration(
            color: bg,
            border: Border.all(color: border),
            borderRadius: BorderRadius.circular(4)),
        child: Text(label,
            textAlign: TextAlign.center,
            style: TextStyle(color: fg, fontSize: 10, letterSpacing: 0.8)),
      ),
    );
  }
}

// ── Embedding Toast ───────────────────────────────────────────────────────────

class _EmbeddingToast extends StatefulWidget {
  final ToastMessage message;
  final VoidCallback onDone;
  const _EmbeddingToast({required this.message, required this.onDone});
  @override
  State<_EmbeddingToast> createState() => _EmbeddingToastState();
}

class _EmbeddingToastState extends State<_EmbeddingToast>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  late final Animation<double> _opacity;
  late final Animation<Offset> _slide;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 280));
    _opacity = CurvedAnimation(parent: _ctrl, curve: Curves.easeOut);
    _slide = Tween<Offset>(begin: const Offset(0, 0.3), end: Offset.zero)
        .animate(CurvedAnimation(parent: _ctrl, curve: Curves.easeOut));
    _ctrl.forward();
    Future.delayed(const Duration(milliseconds: 2400), () {
      if (mounted) _ctrl.reverse().then((_) => widget.onDone());
    });
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Positioned(
      bottom: 24,
      right: 16,
      child: FadeTransition(
        opacity: _opacity,
        child: SlideTransition(
          position: _slide,
          child: Material(
            color: Colors.transparent,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                  color: kSurface,
                  border: Border.all(color: kAccentDim, width: 1),
                  borderRadius: BorderRadius.circular(4)),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Column(mainAxisSize: MainAxisSize.min, children: [
                  Text(widget.message.char,
                      style: const TextStyle(
                          color: kAccent,
                          fontSize: 22,
                          fontWeight: FontWeight.w200,
                          height: 1)),
                  const SizedBox(height: 3),
                  Text('#${widget.message.embeddingCount}',
                      style: const TextStyle(
                          color: kTextMuted, fontSize: 9, letterSpacing: 0.5)),
                ]),
                const SizedBox(width: 10),
                Text(widget.message.statusLabel,
                    style: TextStyle(
                        color: widget.message.status == ToastStatus.dbError
                            ? kError
                            : widget.message.status == ToastStatus.savedFallback
                                ? kTextSecondary
                                : kSuccess,
                        fontSize: 9,
                        letterSpacing: 0.8)),
              ]),
            ),
          ),
        ),
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════════
// LAYOUT
// ═══════════════════════════════════════════════════════════════════════════════
//
// KEY DESIGN:
// - _DrawCanvas is the only Expanded child in the canvas column.
// - _BottomBar sits below it as a fixed-size (mainAxisSize.min) Column.
// - This prevents the canvas from shrinking as panels grow.
// - Mobile: TopPanel → Expanded(DrawCanvas) → BottomBar → Expanded(flex:3, InfoArea)
// - Wide:   Left(TopPanel + Expanded(DrawCanvas) + BottomBar) | Right(InfoArea)
//
// ═══════════════════════════════════════════════════════════════════════════════

class _Body extends StatelessWidget {
  const _Body();
  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (ctx, c) {
      final isWide = c.maxWidth > 600;
      if (isWide) {
        return Row(children: [
          Expanded(
            flex: 5,
            child: Column(children: [
              const _TopPanel(),
              const SizedBox(height: 1, child: ColoredBox(color: kBorder)),
              const Expanded(child: _DrawCanvas()),
              const SizedBox(height: 1, child: ColoredBox(color: kBorder)),
              const _BottomBar(),
            ]),
          ),
          const SizedBox(width: 1, child: ColoredBox(color: kBorder)),
          Expanded(flex: 4, child: _InfoArea()),
        ]);
      }
      return Column(children: [
        const _TopPanel(),
        const SizedBox(height: 1, child: ColoredBox(color: kBorder)),
        const Expanded(flex: 9, child: _DrawCanvas()),
        const SizedBox(height: 1, child: ColoredBox(color: kBorder)),
        const _BottomBar(),
        const SizedBox(height: 1, child: ColoredBox(color: kBorder)),
        Expanded(flex: 1, child: _InfoArea()),
      ]);
    });
  }
}

// ── Top panel ─────────────────────────────────────────────────────────────────

class _TopPanel extends StatelessWidget {
  const _TopPanel();
  @override
  Widget build(BuildContext context) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const _SearchBar(),
          const SizedBox(height: 1, child: ColoredBox(color: kBorder)),
          _CanvasControls(),
        ],
      );
}

// ── Bottom bar (fixed height, below canvas) ───────────────────────────────────

class _BottomBar extends StatelessWidget {
  const _BottomBar();
  @override
  Widget build(BuildContext context) => const Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _RealtimePredictionPanel(),
          _SampleBar(),
        ],
      );
}

// ── Realtime Prediction Panel ─────────────────────────────────────────────────

class _RealtimePredictionPanel extends StatelessWidget {
  const _RealtimePredictionPanel();

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final candidates = state.realtimeCandidates;
    final hasStrokes = state.canvas.hasStrokes;

    if (!hasStrokes && candidates.isEmpty) return const SizedBox.shrink();

    String emptyMsg;
    switch (state.realtimeSource) {
      case 'model_no_prototypes':
        emptyMsg = 'Model loaded · no local prototypes yet';
        break;
      case 'proto':
        emptyMsg = '';
        break;
      default:
        emptyMsg = 'No local prototypes';
    }

    return Container(
      width: double.infinity,
      constraints: const BoxConstraints(minHeight: 32),
      decoration: const BoxDecoration(
        border: Border(top: BorderSide(color: kBorder, width: 1)),
      ),
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 4),
      child: candidates.isEmpty
          ? Text(emptyMsg,
              style: const TextStyle(
                  color: kTextMuted, fontSize: 9, letterSpacing: 0.8))
          : Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                _BestMatchGlyph(candidate: candidates.first),
                const SizedBox(width: 10),
                Expanded(
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      children: candidates.skip(1).map((c) {
                        final isSimilar =
                            (candidates.first.score - c.score) <= 0.08;
                        return Padding(
                          padding: const EdgeInsets.only(right: 6),
                          child: _CandidateChip(
                              candidate: c, isSimilar: isSimilar),
                        );
                      }).toList(),
                    ),
                  ),
                ),
              ],
            ),
    );
  }
}

class _BestMatchGlyph extends StatelessWidget {
  final ProtoMatchCandidate candidate;
  const _BestMatchGlyph({required this.candidate});

  @override
  Widget build(BuildContext context) {
    final pct = (candidate.score * 100).round();
    final scoreColor = pct >= 80
        ? kSuccess
        : pct >= 60
            ? kAccent
            : kTextSecondary;
    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.baseline,
      textBaseline: TextBaseline.alphabetic,
      children: [
        Text(candidate.vocabulary,
            style: const TextStyle(
                color: kAccent,
                fontSize: 26,
                fontWeight: FontWeight.w200,
                height: 1)),
        const SizedBox(width: 4),
        Text('$pct%',
            style:
                TextStyle(color: scoreColor, fontSize: 9, letterSpacing: 0.4)),
      ],
    );
  }
}

class _CandidateChip extends StatelessWidget {
  final ProtoMatchCandidate candidate;
  final bool isSimilar;
  const _CandidateChip({required this.candidate, required this.isSimilar});

  @override
  Widget build(BuildContext context) {
    final pct = (candidate.score * 100).round();
    final borderColor = isSimilar ? kAccentDim : kBorder.withOpacity(0.5);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
          border: Border.all(color: borderColor),
          borderRadius: BorderRadius.circular(3)),
      child: RichText(
          text: TextSpan(children: [
        TextSpan(
            text: candidate.vocabulary,
            style: TextStyle(
                color: isSimilar ? kAccent : kTextSecondary,
                fontSize: 14,
                fontWeight: FontWeight.w200,
                height: 1)),
        TextSpan(
            text: ' $pct',
            style: const TextStyle(
                color: kTextMuted, fontSize: 8, letterSpacing: 0.3)),
      ])),
    );
  }
}

// ── Sample bar (only when pinned) ─────────────────────────────────────────────

class _SampleBar extends StatelessWidget {
  const _SampleBar();

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    if (state.pinnedEntry == null) return const SizedBox.shrink();

    return Container(
      decoration: const BoxDecoration(
        border: Border(top: BorderSide(color: kBorder, width: 1)),
      ),
      padding: const EdgeInsets.fromLTRB(12, 5, 12, 6),
      child: Row(children: [
        _StatChip(
          label: 'Samples',
          value: '${state.localSampleCountForPinned}',
          highlight: state.localSampleCountForPinned > 0,
        ),
        const SizedBox(width: 6),
        if (state.pendingUploadCount > 0)
          _StatChip(
            label: 'pending',
            value: '${state.pendingUploadCount}',
            isWarning: state.pendingUploadCount > 50,
          ),
        const Spacer(),
      ]),
    );
  }
}

// ── Draw canvas ───────────────────────────────────────────────────────────────

class _DrawCanvas extends StatelessWidget {
  const _DrawCanvas();
  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    return LayoutBuilder(builder: (ctx, c) {
      final sz = min(c.maxWidth, c.maxHeight);
      return Center(
        child: SizedBox(
          width: sz,
          height: sz,
          child: ClipRect(
            child: GestureDetector(
              onPanStart: (d) {
                final s = kLogicalSize / sz;
                context.read<AppState>().strokeStart(
                    d.localPosition.dx * s, d.localPosition.dy * s);
              },
              onPanUpdate: (d) {
                final s = kLogicalSize / sz;
                context
                    .read<AppState>()
                    .strokeAdd(d.localPosition.dx * s, d.localPosition.dy * s);
              },
              onPanEnd: (_) => context.read<AppState>().strokeEnd(),
              onPanCancel: () => context.read<AppState>().strokeEnd(),
              child: CustomPaint(
                size: Size(sz, sz),
                painter: _CanvasPainter(
                  state.canvas,
                  state.pinnedEntry?.vocabulary,
                  state.strokeWidth,
                  state.showPinnedTemplate,
                ),
              ),
            ),
          ),
        ),
      );
    });
  }
}

class _CanvasPainter extends CustomPainter {
  final CanvasData canvas;
  final String? hint;
  final double strokeWidth;
  final bool showPinnedTemplate;
  _CanvasPainter(
      this.canvas, this.hint, this.strokeWidth, this.showPinnedTemplate);

  @override
  void paint(Canvas c, Size sz) {
    final scale = sz.width / kLogicalSize;
    c.drawRect(Offset.zero & sz, Paint()..color = kSurface);

    final g = Paint()
      ..color = kBorder
      ..strokeWidth = 0.5;
    c.drawLine(Offset(sz.width / 2, 0), Offset(sz.width / 2, sz.height), g);
    c.drawLine(Offset(0, sz.height / 2), Offset(sz.width, sz.height / 2), g);
    final gd = Paint()
      ..color = kBorder.withOpacity(0.35)
      ..strokeWidth = 0.5;
    c.drawLine(const Offset(0, 0), Offset(sz.width, sz.height), gd);
    c.drawLine(Offset(sz.width, 0), Offset(0, sz.height), gd);
    c.drawRect(
      Rect.fromLTWH(0.5, 0.5, sz.width - 1, sz.height - 1),
      Paint()
        ..color = kBorder
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1,
    );

    if (hint != null && (showPinnedTemplate || !canvas.hasStrokes)) {
      final tp = TextPainter(
        text: TextSpan(
            text: hint,
            style: TextStyle(
                color: kAccent.withOpacity(showPinnedTemplate ? 0.18 : 0.12),
                fontSize: sz.width * 0.55,
                fontWeight: FontWeight.w200,
                height: 1)),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(
          c, Offset((sz.width - tp.width) / 2, (sz.height - tp.height) / 2));
    }

    final ink = Paint()
      ..color = kAccent
      ..strokeWidth = strokeWidth * scale
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..style = PaintingStyle.stroke;

    void draw(StrokeData s) {
      if (s.points.isEmpty) return;
      if (s.points.length == 1) {
        c.drawCircle(Offset(s.points.first.x * scale, s.points.first.y * scale),
            5 * scale, ink);
        return;
      }
      final path = Path()
        ..moveTo(s.points.first.x * scale, s.points.first.y * scale);
      for (final pt in s.points.skip(1)) {
        path.lineTo(pt.x * scale, pt.y * scale);
      }
      c.drawPath(path, ink);
    }

    for (final s in canvas.strokes) draw(s);
    if (canvas.active != null) draw(canvas.active!);
  }

  @override
  bool shouldRepaint(_CanvasPainter old) =>
      old.canvas != canvas ||
      old.hint != hint ||
      old.strokeWidth != strokeWidth ||
      old.showPinnedTemplate != showPinnedTemplate;
}

// ── Canvas Controls ───────────────────────────────────────────────────────────

class _CanvasControls extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final isPinned = state.pinnedEntry != null;
    final clearLabel = isPinned ? 'Save+Clear' : 'Clear';
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 6, 12, 8),
      child: Row(children: [
        _Btn(
            label: 'Undo',
            enabled: state.canvas.canUndo,
            onTap: () => context.read<AppState>().undo()),
        const SizedBox(width: 6),
        _Btn(
          label: state.busy ? '…' : clearLabel,
          enabled: state.canvas.hasStrokes && !state.busy,
          accent: isPinned,
          onTap: () async {
            if (isPinned) {
              final ok = await context.read<AppState>().saveAndClearPinned();
              if (!context.mounted) return;
              ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                content: Text(ok ? 'Sample saved' : 'Save failed',
                    style:
                        TextStyle(color: ok ? kSuccess : kError, fontSize: 11)),
                backgroundColor: kSurface,
                duration: const Duration(milliseconds: 1400),
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              ));
            } else {
              context.read<AppState>().clear();
            }
          },
        ),
        const SizedBox(width: 6),
        _Btn(
          label: state.showPinnedTemplate ? 'Template ●' : 'Template',
          enabled: state.pinnedEntry != null,
          onTap: () => context.read<AppState>().togglePinnedTemplate(),
        ),
      ]),
    );
  }
}

// ── Stat chip ─────────────────────────────────────────────────────────────────

class _StatChip extends StatelessWidget {
  final String label, value;
  final bool highlight, isWarning;
  const _StatChip(
      {required this.label,
      required this.value,
      this.highlight = false,
      this.isWarning = false});

  @override
  Widget build(BuildContext context) {
    final color = isWarning
        ? kError
        : highlight
            ? kSuccess
            : kTextMuted;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
          border: Border.all(color: kBorder),
          borderRadius: BorderRadius.circular(3)),
      child: RichText(
          text: TextSpan(children: [
        TextSpan(
            text: '$label ',
            style: const TextStyle(
                color: kTextMuted, fontSize: 9, letterSpacing: 0.5)),
        TextSpan(
            text: value,
            style: TextStyle(
                color: color,
                fontSize: 9,
                fontWeight: FontWeight.w500,
                letterSpacing: 0.5)),
      ])),
    );
  }
}

class _SimilarityBadge extends StatelessWidget {
  final SimilarityResult result;
  const _SimilarityBadge({required this.result});

  @override
  Widget build(BuildContext context) {
    final color = result.isConsistent
        ? kSuccess
        : result.isGood
            ? kAccent
            : kError;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
          border: Border.all(color: color.withOpacity(0.4)),
          borderRadius: BorderRadius.circular(3)),
      child: Text(result.feedback,
          style: TextStyle(color: color, fontSize: 9, letterSpacing: 0.3)),
    );
  }
}

// ── Search bar ────────────────────────────────────────────────────────────────

class _SearchBar extends StatefulWidget {
  const _SearchBar();
  @override
  State<_SearchBar> createState() => _SearchBarState();
}

class _SearchBarState extends State<_SearchBar> {
  final _ctrl = TextEditingController();
  final _focusNode = FocusNode();

  @override
  void dispose() {
    _ctrl.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _dismissKeyboard() {
    _focusNode.unfocus();
    FocusScope.of(context).unfocus();
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    return Column(mainAxisSize: MainAxisSize.min, children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 80, 6),
        child: Row(children: [
          Expanded(
            child: TextField(
              controller: _ctrl,
              focusNode: _focusNode,
              style: const TextStyle(color: kTextPrimary, fontSize: 13),
              cursorColor: kAccent,
              decoration: InputDecoration(
                hintText: '搜尋 pinyin / 漢字…',
                hintStyle: const TextStyle(color: kTextMuted, fontSize: 12),
                isDense: true,
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                filled: true,
                fillColor: kSurface,
                border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(4),
                    borderSide: const BorderSide(color: kBorder)),
                enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(4),
                    borderSide: const BorderSide(color: kBorder)),
                focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(4),
                    borderSide: const BorderSide(color: kAccent, width: 1)),
                suffixIcon: _ctrl.text.isNotEmpty
                    ? GestureDetector(
                        onTap: () {
                          _ctrl.clear();
                          context.read<AppState>().setSearchQuery('');
                        },
                        child: const Icon(Icons.close,
                            color: kTextMuted, size: 14))
                    : null,
              ),
              onChanged: (v) => context.read<AppState>().setSearchQuery(v),
            ),
          ),
          if (state.pinnedEntry != null) ...[
            const SizedBox(width: 8),
            _Btn(
                label: 'reset',
                enabled: true,
                onTap: () => context.read<AppState>().resetPinned()),
          ],
        ]),
      ),
      if (state.searchSuggestions.isNotEmpty)
        Container(
          constraints: const BoxConstraints(maxHeight: 180),
          margin: const EdgeInsets.fromLTRB(12, 0, 12, 6),
          decoration: BoxDecoration(
              color: kSurface,
              border: Border.all(color: kBorder),
              borderRadius: BorderRadius.circular(4)),
          child: ListView.builder(
            shrinkWrap: true,
            itemCount: state.searchSuggestions.length,
            itemBuilder: (ctx, i) {
              final e = state.searchSuggestions[i];
              return GestureDetector(
                onTap: () {
                  _dismissKeyboard();
                  _ctrl.clear();
                  context.read<AppState>().selectSuggestion(e);
                },
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                  decoration: BoxDecoration(
                      border: Border(
                          bottom: BorderSide(color: kBorder.withOpacity(0.5)))),
                  child: Row(children: [
                    Text(e.vocabulary,
                        style: const TextStyle(
                            color: kAccent,
                            fontSize: 20,
                            fontWeight: FontWeight.w200)),
                    const SizedBox(width: 10),
                    Expanded(
                        child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                          if (e.pinyin != null)
                            Text(e.pinyin!,
                                style: const TextStyle(
                                    color: kTextPrimary, fontSize: 12)),
                          if (e.levelCode != null)
                            Text(e.levelCode!,
                                style: const TextStyle(
                                    color: kTextMuted, fontSize: 10)),
                        ])),
                  ]),
                ),
              );
            },
          ),
        ),
    ]);
  }
}

// ── Info area ─────────────────────────────────────────────────────────────────

class _InfoArea extends StatelessWidget {
  const _InfoArea();
  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    if (state.pinnedEntry != null) {
      return SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          // Embeddings chip
          FutureBuilder<int>(
            future: DbService.getEmbeddingCount(state.pinnedEntry!.vocabulary),
            builder: (ctx, snap) => _StatChip(
              label: 'Embeddings',
              value: '${snap.data ?? 0}',
              highlight: (snap.data ?? 0) >= 10,
            ),
          ),
          const Padding(
            padding: EdgeInsets.only(top: 8, bottom: 10),
            child: Divider(color: kBorder, height: 1, thickness: 1),
          ),
          _EntryCard(
              entry: state.pinnedEntry!,
              showStrokeOrder: true,
              showEmbeddingCount: false),
          if (state.similarityResult != null) ...[
            const SizedBox(height: 6),
            _SimilarityBadge(result: state.similarityResult!),
          ],
        ]),
      );
    }
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: const _ResultArea(),
    );
  }
}

// ── Result area ───────────────────────────────────────────────────────────────

class _ResultArea extends StatelessWidget {
  const _ResultArea();
  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    if (state.busy)
      return const Text('Saving…',
          style: TextStyle(color: kTextSecondary, fontSize: 12));

    final r = state.result;
    if (r == null)
      return const Text('Pin chữ rồi vẽ để realtime compare',
          style: TextStyle(color: kTextMuted, fontSize: 12, letterSpacing: 1));
    if (r.error != null)
      return Text(r.error!,
          style: const TextStyle(color: kError, fontSize: 11));
    if (r.matches.isEmpty)
      return const Text('No proto match',
          style: TextStyle(color: kTextMuted, fontSize: 12));
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const Padding(
        padding: EdgeInsets.only(top: 4, bottom: 10),
        child: Divider(color: kBorder, height: 1, thickness: 1),
      ),
      ...r.matches
          .map((e) => _EntryCard(entry: e, showStrokeOrder: true))
          .toList(),
    ]);
  }
}

// ── Entry card ────────────────────────────────────────────────────────────────

class _EntryCard extends StatelessWidget {
  final VocabEntry entry;
  final bool showStrokeOrder, showEmbeddingCount;
  const _EntryCard(
      {required this.entry,
      this.showStrokeOrder = false,
      this.showEmbeddingCount = false});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Column(crossAxisAlignment: CrossAxisAlignment.center, children: [
            Text(entry.vocabulary,
                style: const TextStyle(
                    color: kAccent,
                    fontSize: 48,
                    fontWeight: FontWeight.w200,
                    height: 1)),
            if (showEmbeddingCount)
              _EmbeddingCountBadge(vocabulary: entry.vocabulary),
          ]),
          const SizedBox(width: 14),
          Expanded(
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                if (entry.pinyin != null)
                  Text(entry.pinyin!,
                      style: const TextStyle(
                          color: kTextPrimary,
                          fontSize: 16,
                          letterSpacing: 0.5)),
                if (entry.bopomofo != null)
                  Text(entry.bopomofo!,
                      style:
                          const TextStyle(color: kTextSecondary, fontSize: 13)),
                const SizedBox(height: 4),
                Wrap(spacing: 6, runSpacing: 4, children: [
                  if (entry.levelCode != null) _Tag(entry.levelCode!),
                  if (entry.context != null) _Tag(entry.context!),
                  if (entry.partOfSpeech != null) _Tag(entry.partOfSpeech!),
                ]),
                if (entry.variantGroup != null) ...[
                  const SizedBox(height: 4),
                  Text('異體字 ${entry.variantGroup!}',
                      style: const TextStyle(color: kTextMuted, fontSize: 10)),
                ],
              ])),
        ]),
        if (showStrokeOrder) ...[
          const SizedBox(height: 8),
          _StrokeOrderBtn(char: entry.vocabulary)
        ],
        const SizedBox(height: 4),
        const Divider(color: kBorder, height: 1),
      ]),
    );
  }
}

// ── Embedding Count Badge ─────────────────────────────────────────────────────

class _EmbeddingCountBadge extends StatelessWidget {
  final String vocabulary;
  const _EmbeddingCountBadge({required this.vocabulary});

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<int>(
      future: DbService.getEmbeddingCount(vocabulary),
      builder: (ctx, snap) {
        final count = snap.data ?? 0;
        return Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              border: Border.all(color: count > 0 ? kAccentDim : kBorder),
              borderRadius: BorderRadius.circular(3),
            ),
            child: RichText(
                text: TextSpan(children: [
              TextSpan(
                  text: 'Emb ',
                  style: const TextStyle(
                      color: kTextMuted, fontSize: 8, letterSpacing: 0.5)),
              TextSpan(
                  text: '$count',
                  style: TextStyle(
                      color: count > 0 ? kAccent : kTextMuted,
                      fontSize: 9,
                      fontWeight: FontWeight.w500,
                      letterSpacing: 0.3)),
            ])),
          ),
        );
      },
    );
  }
}

// ── Stroke order button ───────────────────────────────────────────────────────

class _StrokeOrderBtn extends StatelessWidget {
  final String char;
  const _StrokeOrderBtn({required this.char});

  @override
  Widget build(BuildContext context) {
    final c = char.isNotEmpty ? char.characters.first : char;
    final encoded = Uri.encodeComponent(c);
    final url = 'https://hanzii.net/search/word/$encoded?hl=vi';
    return GestureDetector(
      onTap: () async {
        final uri = Uri.parse(url);
        if (await canLaunchUrl(uri))
          await launchUrl(uri, mode: LaunchMode.externalApplication);
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
            border: Border.all(color: kBorder),
            borderRadius: BorderRadius.circular(4)),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          const Text('Stroke order',
              style: TextStyle(
                  color: kTextSecondary, fontSize: 11, letterSpacing: 1)),
          const SizedBox(width: 6),
          Text(c, style: const TextStyle(color: kAccent, fontSize: 13)),
        ]),
      ),
    );
  }
}

// ── Tag ───────────────────────────────────────────────────────────────────────

class _Tag extends StatelessWidget {
  final String label;
  const _Tag(this.label);
  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        decoration: BoxDecoration(
            border: Border.all(color: kBorder),
            borderRadius: BorderRadius.circular(3)),
        child: Text(label,
            style: const TextStyle(
                color: kTextMuted, fontSize: 9, letterSpacing: 0.5)),
      );
}

// ── Button ────────────────────────────────────────────────────────────────────

class _Btn extends StatelessWidget {
  final String label;
  final bool enabled, accent;
  final VoidCallback onTap;
  const _Btn(
      {required this.label,
      required this.enabled,
      required this.onTap,
      this.accent = false});

  @override
  Widget build(BuildContext context) {
    final fg = enabled ? (accent ? kBg : kTextSecondary) : kTextMuted;
    final bg = accent && enabled ? kAccent : Colors.transparent;
    final border =
        enabled ? (accent ? kAccent : kBorder) : kBorder.withOpacity(0.4);
    return GestureDetector(
      onTap: enabled ? onTap : null,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
            color: bg,
            border: Border.all(color: border),
            borderRadius: BorderRadius.circular(4)),
        child: Text(label,
            style: TextStyle(color: fg, fontSize: 11, letterSpacing: 1)),
      ),
    );
  }
}
