// app.dart
// Full UI layer: app shell, theme, all widgets, layout, canvas interaction.
// No business logic here — all data/state is in logic.dart via AppState.

import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import 'logic.dart';

// ══════════════════════════════════════════════════════════════════════════════
// THEME CONSTANTS
// ══════════════════════════════════════════════════════════════════════════════

const kPrimaryOrange = Color(0xFFFF4A00);
const kOrangeGlow = Color(0x33FF4A00);
const kBgMain = Color(0xFF080705);
const kBgCard = Color(0xFF161310);
const kBgCard2 = Color(0xFF1A1714);
const kBgCanvas = Color(0xFF0F0E0A);
const kTextMain = Color(0xFFF0E6D0);
const kTextSub = Color(0xFFB09070);
const kTextMuted = Color(0xFF705040);
const kBorderColor = Color(0xFF2A2018);
const kBorderAccent = Color(0x4DB4783C);
const kSuccessColor = Color(0xFF79D97C);

// ══════════════════════════════════════════════════════════════════════════════
// ROOT APP
// ══════════════════════════════════════════════════════════════════════════════

class TocflApp extends StatefulWidget {
  const TocflApp({super.key});

  @override
  State<TocflApp> createState() => _TocflAppState();
}

class _TocflAppState extends State<TocflApp> {
  @override
  void initState() {
    super.initState();
    // Init DB and state after first frame
    WidgetsBinding.instance.addPostFrameCallback((_) {
      context.read<AppState>().init();
    });
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'TOCFL Writer',
      debugShowCheckedModeBanner: false,
      theme: _buildTheme(),
      home: const _HomeScreen(),
    );
  }

  ThemeData _buildTheme() {
    return ThemeData(
      brightness: Brightness.dark,
      scaffoldBackgroundColor: kBgMain,
      colorScheme: const ColorScheme.dark(
        primary: kPrimaryOrange,
        secondary: kPrimaryOrange,
        surface: kBgCard,
        background: kBgMain,
      ),
      fontFamily: 'Roboto',
      textTheme: const TextTheme(
        bodyMedium: TextStyle(color: kTextMain, fontSize: 14),
        bodySmall: TextStyle(color: kTextSub, fontSize: 12),
      ),
      dividerColor: kBorderColor,
      cardColor: kBgCard,
      splashColor: kOrangeGlow,
      highlightColor: Colors.transparent,
    );
  }
}

// ══════════════════════════════════════════════════════════════════════════════
// HOME SCREEN — adaptive landscape/portrait layout
// ══════════════════════════════════════════════════════════════════════════════

class _HomeScreen extends StatelessWidget {
  const _HomeScreen();

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();

    if (!state.dbReady) {
      return const _SplashScreen();
    }

    return Scaffold(
      backgroundColor: kBgMain,
      body: SafeArea(
        child: OrientationBuilder(
          builder: (context, orientation) {
            if (orientation == Orientation.landscape) {
              return const _LandscapeLayout();
            } else {
              return const _PortraitLayout();
            }
          },
        ),
      ),
    );
  }
}

// ══════════════════════════════════════════════════════════════════════════════
// SPLASH
// ══════════════════════════════════════════════════════════════════════════════

class _SplashScreen extends StatefulWidget {
  const _SplashScreen();

  @override
  State<_SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<_SplashScreen>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  late final Animation<double> _anim;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 1200))
      ..repeat(reverse: true);
    _anim = CurvedAnimation(parent: _ctrl, curve: Curves.easeInOut);
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      color: kBgMain,
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            FadeTransition(
              opacity: _anim,
              child: const Text(
                '漢字',
                style: TextStyle(
                  color: kPrimaryOrange,
                  fontSize: 72,
                  fontWeight: FontWeight.w100,
                ),
              ),
            ),
            const SizedBox(height: 24),
            const Text(
              'TOCFL WRITER',
              style: TextStyle(
                color: kTextMuted,
                fontSize: 12,
                letterSpacing: 6,
                fontFamily: 'monospace',
              ),
            ),
            const SizedBox(height: 32),
            SizedBox(
              width: 120,
              child: LinearProgressIndicator(
                backgroundColor: kBorderColor,
                valueColor: const AlwaysStoppedAnimation<Color>(kPrimaryOrange),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ══════════════════════════════════════════════════════════════════════════════
// LANDSCAPE LAYOUT — left: search+list, right: practice panel
// ══════════════════════════════════════════════════════════════════════════════

class _LandscapeLayout extends StatelessWidget {
  const _LandscapeLayout();

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // ── Left panel: search + filter + list ──
        SizedBox(
          width: 300,
          child: Container(
            decoration: const BoxDecoration(
              color: kBgCard,
              border: Border(right: BorderSide(color: kBorderColor)),
            ),
            child: const _LeftPanel(),
          ),
        ),
        // ── Right panel: practice area ──
        const Expanded(
          child: _PracticePanel(),
        ),
      ],
    );
  }
}

// ══════════════════════════════════════════════════════════════════════════════
// PORTRAIT LAYOUT
// ══════════════════════════════════════════════════════════════════════════════

class _PortraitLayout extends StatefulWidget {
  const _PortraitLayout();

  @override
  State<_PortraitLayout> createState() => _PortraitLayoutState();
}

class _PortraitLayoutState extends State<_PortraitLayout> {
  bool _showList = true;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        // Toggle tabs
        _PortraitTabBar(
          showList: _showList,
          onToggle: (v) => setState(() => _showList = v),
        ),
        Expanded(
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 200),
            child: _showList
                ? const _LeftPanel(key: ValueKey('list'))
                : const _PracticePanel(key: ValueKey('practice')),
          ),
        ),
      ],
    );
  }
}

class _PortraitTabBar extends StatelessWidget {
  final bool showList;
  final ValueChanged<bool> onToggle;

  const _PortraitTabBar({required this.showList, required this.onToggle});

  @override
  Widget build(BuildContext context) {
    return Container(
      color: kBgCard,
      child: Row(
        children: [
          _Tab(
            label: '字 詞庫',
            selected: showList,
            onTap: () => onToggle(true),
          ),
          _Tab(
            label: '✍ 練習',
            selected: !showList,
            onTap: () => onToggle(false),
          ),
        ],
      ),
    );
  }
}

class _Tab extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _Tab(
      {required this.label, required this.selected, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 12),
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(
                color: selected ? kPrimaryOrange : Colors.transparent,
                width: 2,
              ),
            ),
          ),
          child: Text(
            label,
            textAlign: TextAlign.center,
            style: TextStyle(
              color: selected ? kPrimaryOrange : kTextMuted,
              fontSize: 13,
              fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
              letterSpacing: 1,
            ),
          ),
        ),
      ),
    );
  }
}

// ══════════════════════════════════════════════════════════════════════════════
// LEFT PANEL — search, filters, vocab list
// ══════════════════════════════════════════════════════════════════════════════

class _LeftPanel extends StatefulWidget {
  const _LeftPanel({super.key});

  @override
  State<_LeftPanel> createState() => _LeftPanelState();
}

class _LeftPanelState extends State<_LeftPanel> {
  final _searchCtrl = TextEditingController();
  final _scrollCtrl = ScrollController();

  @override
  void initState() {
    super.initState();
    _scrollCtrl.addListener(_onScroll);
  }

  void _onScroll() {
    if (_scrollCtrl.position.pixels >=
        _scrollCtrl.position.maxScrollExtent - 200) {
      context.read<AppState>().loadMore();
    }
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    _scrollCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _AppTitleBar(),
        _SearchBar(
          controller: _searchCtrl,
          onChanged: (v) => context.read<AppState>().setSearchQuery(v),
          onClear: () {
            _searchCtrl.clear();
            context.read<AppState>().setSearchQuery('');
          },
        ),
        _FilterRow(state: state),
        Expanded(
          child: _VocabList(
            entries: state.vocabList,
            selectedEntry: state.selectedEntry,
            scrollController: _scrollCtrl,
            loading: state.loadingList,
            onSelect: (e) {
              context.read<AppState>().selectEntry(e);
            },
          ),
        ),
      ],
    );
  }
}

class _AppTitleBar extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: kBorderColor)),
      ),
      child: Row(
        children: [
          const Text(
            '漢',
            style: TextStyle(
              color: kPrimaryOrange,
              fontSize: 28,
              fontWeight: FontWeight.w100,
            ),
          ),
          const SizedBox(width: 10),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: const [
              Text(
                'TOCFL WRITER',
                style: TextStyle(
                  color: kTextMain,
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 3,
                ),
              ),
              Text(
                '練習寫字',
                style: TextStyle(
                  color: kTextMuted,
                  fontSize: 10,
                  letterSpacing: 2,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _SearchBar extends StatelessWidget {
  final TextEditingController controller;
  final ValueChanged<String> onChanged;
  final VoidCallback onClear;

  const _SearchBar({
    required this.controller,
    required this.onChanged,
    required this.onClear,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
      child: TextField(
        controller: controller,
        onChanged: onChanged,
        style: const TextStyle(color: kTextMain, fontSize: 14),
        cursorColor: kPrimaryOrange,
        decoration: InputDecoration(
          hintText: '搜尋字詞 / pinyin…',
          hintStyle: const TextStyle(color: kTextMuted, fontSize: 13),
          prefixIcon: const Icon(Icons.search, color: kTextMuted, size: 18),
          suffixIcon: controller.text.isNotEmpty
              ? GestureDetector(
                  onTap: onClear,
                  child: const Icon(Icons.close, color: kTextMuted, size: 18),
                )
              : null,
          filled: true,
          fillColor: kBgCard2,
          contentPadding:
              const EdgeInsets.symmetric(vertical: 10, horizontal: 12),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: const BorderSide(color: kBorderColor),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: const BorderSide(color: kBorderColor),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: const BorderSide(color: kPrimaryOrange, width: 1.5),
          ),
        ),
      ),
    );
  }
}

class _FilterRow extends StatelessWidget {
  final AppState state;

  const _FilterRow({required this.state});

  @override
  Widget build(BuildContext context) {
    final appState = context.read<AppState>();
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: Row(
        children: [
          Expanded(
            child: _DropdownFilter<String?>(
              value: state.selectedLevel,
              hint: '級別',
              items: [
                const DropdownMenuItem(value: null, child: Text('全部級別')),
                ...state.levels.map((l) => DropdownMenuItem(
                      value: l,
                      child: Text(
                        '${levelLabel(l)} $l',
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 12),
                      ),
                    )),
              ],
              onChanged: (v) => appState.setLevel(v),
            ),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: _DropdownFilter<String?>(
              value: state.selectedContext,
              hint: '主題',
              items: [
                const DropdownMenuItem(value: null, child: Text('全部主題')),
                ...state.contexts.map((c) => DropdownMenuItem(
                      value: c,
                      child: Text(
                        c,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 12),
                      ),
                    )),
              ],
              onChanged: (v) => appState.setContext(v),
            ),
          ),
          const SizedBox(width: 6),
          _IconBtn(
            icon: Icons.shuffle,
            tooltip: '隨機',
            onTap: () => appState.randomEntry(),
          ),
          if (state.selectedLevel != null || state.selectedContext != null)
            _IconBtn(
              icon: Icons.filter_alt_off,
              tooltip: '清除篩選',
              onTap: () => appState.clearFilters(),
            ),
        ],
      ),
    );
  }
}

class _DropdownFilter<T> extends StatelessWidget {
  final T value;
  final String hint;
  final List<DropdownMenuItem<T>> items;
  final ValueChanged<T> onChanged;

  const _DropdownFilter({
    required this.value,
    required this.hint,
    required this.items,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 36,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      decoration: BoxDecoration(
        color: kBgCard2,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: kBorderColor),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<T>(
          value: value,
          hint: Text(
            hint,
            style: const TextStyle(color: kTextMuted, fontSize: 12),
          ),
          dropdownColor: kBgCard2,
          iconEnabledColor: kTextMuted,
          iconSize: 16,
          style: const TextStyle(color: kTextMain, fontSize: 12),
          isExpanded: true,
          items: items,
          onChanged: (v) => onChanged(v as T),
        ),
      ),
    );
  }
}

class _IconBtn extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;

  const _IconBtn(
      {required this.icon, required this.tooltip, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: Material(
        color: kBgCard2,
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(8),
          child: Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              border: Border.all(color: kBorderColor),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(icon, color: kTextSub, size: 18),
          ),
        ),
      ),
    );
  }
}

class _VocabList extends StatelessWidget {
  final List<VocabEntry> entries;
  final VocabEntry? selectedEntry;
  final ScrollController scrollController;
  final bool loading;
  final ValueChanged<VocabEntry> onSelect;

  const _VocabList({
    required this.entries,
    required this.selectedEntry,
    required this.scrollController,
    required this.loading,
    required this.onSelect,
  });

  @override
  Widget build(BuildContext context) {
    if (entries.isEmpty && !loading) {
      return const Center(
        child: Text(
          '沒有符合的字詞',
          style: TextStyle(color: kTextMuted, fontSize: 13),
        ),
      );
    }

    return ListView.builder(
      controller: scrollController,
      padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 8),
      itemCount: entries.length + (loading ? 1 : 0),
      itemBuilder: (context, index) {
        if (index == entries.length) {
          return const Padding(
            padding: EdgeInsets.all(16),
            child: Center(
              child: SizedBox(
                width: 24,
                height: 24,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: kPrimaryOrange,
                ),
              ),
            ),
          );
        }
        final entry = entries[index];
        final isSelected = selectedEntry?.id == entry.id;
        return _VocabCard(
          entry: entry,
          isSelected: isSelected,
          onTap: () => onSelect(entry),
        );
      },
    );
  }
}

class _VocabCard extends StatelessWidget {
  final VocabEntry entry;
  final bool isSelected;
  final VoidCallback onTap;

  const _VocabCard({
    required this.entry,
    required this.isSelected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final lc = levelColor(entry.levelCode);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Material(
        color: isSelected ? kBgCard2 : Colors.transparent,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(12),
          splashColor: kOrangeGlow,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: isSelected ? kPrimaryOrange : kBorderColor,
                width: isSelected ? 1.5 : 1,
              ),
              color: isSelected
                  ? kPrimaryOrange.withOpacity(0.08)
                  : kBgCard.withOpacity(0.5),
            ),
            child: Row(
              children: [
                SizedBox(
                  width: 52,
                  child: Text(
                    entry.vocabulary,
                    style: const TextStyle(
                      color: kTextMain,
                      fontSize: 28,
                      fontWeight: FontWeight.w300,
                      height: 1,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (entry.pinyin != null)
                        Text(
                          entry.pinyin!,
                          style: const TextStyle(
                            color: kTextSub,
                            fontSize: 12,
                            fontStyle: FontStyle.italic,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      if (entry.context != null)
                        Text(
                          entry.context!,
                          style: const TextStyle(
                            color: kTextMuted,
                            fontSize: 10,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                    ],
                  ),
                ),
                if (entry.levelCode != null)
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color: lc.withOpacity(0.12),
                      borderRadius: BorderRadius.circular(4),
                      border: Border.all(color: lc.withOpacity(0.4)),
                    ),
                    child: Text(
                      levelLabel(entry.levelCode),
                      style: TextStyle(
                        color: lc,
                        fontSize: 9,
                        fontWeight: FontWeight.w600,
                        letterSpacing: 0.5,
                      ),
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

// ══════════════════════════════════════════════════════════════════════════════
// PRACTICE PANEL — right side (landscape) or main panel (portrait)
// ══════════════════════════════════════════════════════════════════════════════

class _PracticePanel extends StatelessWidget {
  const _PracticePanel({super.key});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final entry = state.selectedEntry;

    if (entry == null) {
      return const _PracticeEmptyState();
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final isWide = constraints.maxWidth > 500;
        if (isWide) {
          return _PracticeWide(entry: entry);
        } else {
          return _PracticeNarrow(entry: entry);
        }
      },
    );
  }
}

class _PracticeEmptyState extends StatelessWidget {
  const _PracticeEmptyState();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            '選字開始練習',
            style: TextStyle(
              color: kTextMuted.withOpacity(0.4),
              fontSize: 16,
              letterSpacing: 3,
            ),
          ),
          const SizedBox(height: 16),
          Text(
            '← 從左側選擇一個字',
            style: TextStyle(
              color: kTextMuted.withOpacity(0.3),
              fontSize: 12,
              letterSpacing: 1,
            ),
          ),
        ],
      ),
    );
  }
}

class _PracticeWide extends StatelessWidget {
  final VocabEntry entry;

  const _PracticeWide({required this.entry});

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            flex: 5,
            child: Column(
              children: [
                const _CanvasWidget(),
                const SizedBox(height: 12),
                const _CanvasButtons(),
                const SizedBox(height: 12),
                const _RecognitionSection(),
              ],
            ),
          ),
          const SizedBox(width: 20),
          Expanded(
            flex: 4,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _CharInfoCard(entry: entry),
                const SizedBox(height: 12),
                const _NavButtons(),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _PracticeNarrow extends StatelessWidget {
  final VocabEntry entry;

  const _PracticeNarrow({required this.entry});

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _CharInfoCard(entry: entry),
          const SizedBox(height: 12),
          const _CanvasWidget(),
          const SizedBox(height: 12),
          const _CanvasButtons(),
          const SizedBox(height: 12),
          const _RecognitionSection(),
          const SizedBox(height: 8),
          const _NavButtons(),
        ],
      ),
    );
  }
}

// ══════════════════════════════════════════════════════════════════════════════
// CHARACTER INFO CARD
// ══════════════════════════════════════════════════════════════════════════════

class _CharInfoCard extends StatelessWidget {
  final VocabEntry entry;

  const _CharInfoCard({required this.entry});

  @override
  Widget build(BuildContext context) {
    final state = context.read<AppState>();
    final isFav = state.isFavorite(entry.id);
    final lc = levelColor(entry.levelCode);

    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: kBgCard,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: kBorderColor),
        boxShadow: [
          BoxShadow(
            color: kPrimaryOrange.withOpacity(0.04),
            blurRadius: 20,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Text(
                  entry.vocabulary,
                  style: const TextStyle(
                    color: kTextMain,
                    fontSize: 88,
                    fontWeight: FontWeight.w100,
                    height: 1,
                  ),
                ),
              ),
              GestureDetector(
                onTap: () => context.read<AppState>().toggleFavorite(entry.id),
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 200),
                  child: Icon(
                    isFav ? Icons.favorite : Icons.favorite_border,
                    key: ValueKey(isFav),
                    color: isFav ? kPrimaryOrange : kTextMuted,
                    size: 22,
                  ),
                ),
              ),
            ],
          ),
          if (entry.pinyin != null) ...[
            const SizedBox(height: 4),
            Text(
              entry.pinyin!,
              style: const TextStyle(
                color: kPrimaryOrange,
                fontSize: 22,
                letterSpacing: 1,
                fontStyle: FontStyle.italic,
              ),
            ),
          ],
          if (entry.bopomofo != null) ...[
            const SizedBox(height: 4),
            Text(
              entry.bopomofo!,
              style: const TextStyle(
                color: kTextSub,
                fontSize: 16,
                letterSpacing: 2,
              ),
            ),
          ],
          const SizedBox(height: 16),
          const Divider(color: kBorderColor, height: 1),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              if (entry.levelCode != null)
                _InfoChip(
                  label: '級別',
                  value: '${levelLabel(entry.levelCode)} · ${entry.levelCode}',
                  valueColor: lc,
                ),
              if (entry.context != null)
                _InfoChip(label: '主題', value: entry.context!),
              if (entry.partOfSpeech != null)
                _InfoChip(label: '詞性', value: entry.partOfSpeech!),
              if (entry.sheetName != null)
                _InfoChip(label: '出處', value: entry.sheetName!),
            ],
          ),
          if (entry.variantGroup != null) ...[
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: kBgCard2,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: kBorderAccent),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text(
                    '異體字：',
                    style: TextStyle(
                      color: kTextMuted,
                      fontSize: 11,
                      letterSpacing: 1,
                    ),
                  ),
                  Text(
                    entry.variantGroup!,
                    style: const TextStyle(
                      color: kTextSub,
                      fontSize: 15,
                      letterSpacing: 2,
                    ),
                  ),
                ],
              ),
            ),
          ],
          const SizedBox(height: 8),
          Text(
            'ID ${entry.id}${entry.sourceId != null ? " · src ${entry.sourceId}" : ""}',
            style: const TextStyle(color: kTextMuted, fontSize: 10),
          ),
        ],
      ),
    );
  }
}

class _InfoChip extends StatelessWidget {
  final String label;
  final String value;
  final Color? valueColor;

  const _InfoChip({required this.label, required this.value, this.valueColor});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: kBgCard2,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: kBorderColor),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            label,
            style: const TextStyle(
              color: kTextMuted,
              fontSize: 9,
              letterSpacing: 1.5,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            value,
            style: TextStyle(
              color: valueColor ?? kTextSub,
              fontSize: 12,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }
}

// ══════════════════════════════════════════════════════════════════════════════
// CANVAS WIDGET
// ══════════════════════════════════════════════════════════════════════════════

class _CanvasWidget extends StatelessWidget {
  const _CanvasWidget();

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final entry = state.selectedEntry;
    final canvasState = state.canvasState;
    final placeholder = entry?.vocabulary ?? '写';

    return LayoutBuilder(
      builder: (context, constraints) {
        final size = min(constraints.maxWidth, 480.0);

        return Center(
          child: Container(
            width: size,
            height: size,
            decoration: BoxDecoration(
              border: Border.all(color: kBorderAccent, width: 1.5),
              boxShadow: [
                BoxShadow(
                  color: kPrimaryOrange.withOpacity(0.06),
                  blurRadius: 30,
                  spreadRadius: 2,
                ),
                BoxShadow(
                  color: Colors.black.withOpacity(0.4),
                  blurRadius: 20,
                  offset: const Offset(0, 4),
                ),
              ],
            ),
            child: ClipRect(
              child: GestureDetector(
                onPanStart: (d) {
                  final local = _toLogical(d.localPosition, size);
                  context
                      .read<AppState>()
                      .canvasStartStroke(local.dx, local.dy);
                },
                onPanUpdate: (d) {
                  final local = _toLogical(d.localPosition, size);
                  context.read<AppState>().canvasAddPoint(local.dx, local.dy);
                },
                onPanEnd: (_) => context.read<AppState>().canvasEndStroke(),
                onPanCancel: () => context.read<AppState>().canvasEndStroke(),
                child: RepaintBoundary(
                  child: CustomPaint(
                    size: Size(size, size),
                    painter: HandwritingPainter(
                      state: canvasState,
                      placeholderChar: placeholder,
                      size: kCanvasLogicalSize,
                    ),
                    isComplex: true,
                    willChange: true,
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Offset _toLogical(Offset pos, double widgetSize) {
    final scale = kCanvasLogicalSize / widgetSize;
    return Offset(pos.dx * scale, pos.dy * scale);
  }
}

// ══════════════════════════════════════════════════════════════════════════════
// CANVAS BUTTONS
// ══════════════════════════════════════════════════════════════════════════════

class _CanvasButtons extends StatelessWidget {
  const _CanvasButtons();

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final cs = state.canvasState;

    return Wrap(
      alignment: WrapAlignment.center,
      spacing: 10,
      runSpacing: 8,
      children: [
        _CanvasBtn(
          label: '清除',
          icon: Icons.delete_outline,
          enabled: cs.hasStrokes,
          onTap: () => context.read<AppState>().canvasClear(),
          accent: false,
        ),
        _CanvasBtn(
          label: '撤銷',
          icon: Icons.undo,
          enabled: cs.canUndo,
          onTap: () => context.read<AppState>().canvasUndo(),
          accent: false,
        ),
        _CanvasBtn(
          label: '重做',
          icon: Icons.redo,
          enabled: cs.canRedo,
          onTap: () => context.read<AppState>().canvasRedo(),
          accent: false,
        ),
      ],
    );
  }
}

class _CanvasBtn extends StatelessWidget {
  final String label;
  final IconData icon;
  final bool enabled;
  final VoidCallback onTap;
  final bool accent;

  const _CanvasBtn({
    required this.label,
    required this.icon,
    required this.enabled,
    required this.onTap,
    required this.accent,
  });

  @override
  Widget build(BuildContext context) {
    final baseColor = accent ? kPrimaryOrange : kBorderAccent;
    final textColor =
        enabled ? (accent ? kBgMain : kTextSub) : kTextMuted.withOpacity(0.4);

    return GestureDetector(
      onTap: enabled ? onTap : null,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        decoration: BoxDecoration(
          color: accent && enabled
              ? kPrimaryOrange
              : kBgCard2.withOpacity(enabled ? 1 : 0.6),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: enabled ? baseColor : kBorderColor.withOpacity(0.5),
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: textColor, size: 16),
            const SizedBox(width: 6),
            Text(
              label,
              style: TextStyle(
                color: textColor,
                fontSize: 12,
                fontFamily: 'monospace',
                letterSpacing: 1,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ══════════════════════════════════════════════════════════════════════════════
// RECOGNITION SECTION
// ══════════════════════════════════════════════════════════════════════════════

class _RecognitionSection extends StatelessWidget {
  const _RecognitionSection();

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();

    String modelStatus;
    Color modelColor;

    if (state.recognitionModelDownloading) {
      modelStatus = 'Downloading';
      modelColor = kPrimaryOrange;
    } else if (state.recognitionModelReady) {
      modelStatus = 'Ready';
      modelColor = kSuccessColor;
    } else {
      modelStatus = 'Not downloaded';
      modelColor = kTextMuted;
    }

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: kBgCard,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: kBorderColor),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.gesture_rounded,
                  color: kPrimaryOrange, size: 18),
              const SizedBox(width: 8),
              const Expanded(
                child: Text(
                  'Handwriting Recognition',
                  style: TextStyle(
                    color: kTextMain,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 0.6,
                  ),
                ),
              ),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                decoration: BoxDecoration(
                  color: modelColor.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(999),
                  border: Border.all(color: modelColor.withOpacity(0.35)),
                ),
                child: Text(
                  modelStatus,
                  style: TextStyle(
                    color: modelColor,
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
          if (!state.recognitionModelReady) ...[
            const SizedBox(height: 10),
            const Text(
              '模型只需下載一次，之後可離線辨識手寫字。',
              style: TextStyle(
                color: kTextSub,
                fontSize: 12,
              ),
            ),
          ],
          const SizedBox(height: 12),
          Wrap(
            spacing: 10,
            runSpacing: 8,
            children: [
              _ActionPill(
                label: state.recognitionModelDownloading ? '下載中…' : '下載模型',
                icon: Icons.download_rounded,
                enabled: !state.recognitionModelReady &&
                    !state.recognitionModelDownloading &&
                    !state.recognitionBusy,
                accent: false,
                onTap: () =>
                    context.read<AppState>().downloadRecognitionModel(),
              ),
              _ActionPill(
                label: state.recognitionBusy ? 'Checking…' : 'Check',
                icon: Icons.spellcheck_rounded,
                enabled: state.canRecognize,
                accent: true,
                onTap: () => context.read<AppState>().recognizeCurrentStrokes(),
              ),
            ],
          ),
          const SizedBox(height: 12),
          const _RecognitionResultCard(),
        ],
      ),
    );
  }
}

class _ActionPill extends StatelessWidget {
  final String label;
  final IconData icon;
  final bool enabled;
  final bool accent;
  final VoidCallback onTap;

  const _ActionPill({
    required this.label,
    required this.icon,
    required this.enabled,
    required this.accent,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final bg = accent && enabled ? kPrimaryOrange : kBgCard2;
    final fg =
        enabled ? (accent ? kBgMain : kTextSub) : kTextMuted.withOpacity(0.45);

    final border = enabled
        ? (accent ? kPrimaryOrange : kBorderAccent)
        : kBorderColor.withOpacity(0.5);

    return GestureDetector(
      onTap: enabled ? onTap : null,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: border),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: fg, size: 16),
            const SizedBox(width: 6),
            Text(
              label,
              style: TextStyle(
                color: fg,
                fontSize: 12,
                fontWeight: accent ? FontWeight.w700 : FontWeight.w500,
                letterSpacing: 0.5,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _RecognitionResultCard extends StatelessWidget {
  const _RecognitionResultCard();

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final result = state.lastRecognition;

    if (state.recognitionBusy) {
      return Container(
        width: double.infinity,
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: kBgCard2,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: kBorderColor),
        ),
        child: const Row(
          children: [
            SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: kPrimaryOrange,
              ),
            ),
            SizedBox(width: 10),
            Text(
              '正在辨識手寫字…',
              style: TextStyle(color: kTextSub, fontSize: 12),
            ),
          ],
        ),
      );
    }

    if (result == null) {
      return Container(
        width: double.infinity,
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: kBgCard2,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: kBorderColor),
        ),
        child: const Text(
          '畫好之後按 Check 查看辨識結果。',
          style: TextStyle(
            color: kTextMuted,
            fontSize: 12,
          ),
        ),
      );
    }

    if (result.error != null && result.error!.trim().isNotEmpty) {
      return Container(
        width: double.infinity,
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: kBgCard2,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: kBorderColor),
        ),
        child: Text(
          result.error!,
          style: const TextStyle(
            color: kTextSub,
            fontSize: 12,
          ),
        ),
      );
    }

    Color verdictColor;
    String verdictText;

    switch (state.recognitionVerdict) {
      case 'correct':
        verdictColor = kSuccessColor;
        verdictText = '正確';
        break;
      case 'near':
        verdictColor = kPrimaryOrange;
        verdictText = '接近答案';
        break;
      default:
        verdictColor = const Color(0xFFFF8C6A);
        verdictText = '不正確';
        break;
    }

    final top5 = result.candidates.take(5).toList();

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: kBgCard2,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: verdictColor.withOpacity(0.35),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            verdictText,
            style: TextStyle(
              color: verdictColor,
              fontSize: 22,
              fontWeight: FontWeight.w700,
              letterSpacing: 1.2,
            ),
          ),
          if (top5.isNotEmpty) ...[
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: top5.map((c) {
                final isTarget = c.text.trim() ==
                    (state.selectedEntry?.vocabulary.trim() ?? '');
                return Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                  decoration: BoxDecoration(
                    color: isTarget
                        ? kPrimaryOrange.withOpacity(0.12)
                        : kBgMain.withOpacity(0.35),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(
                      color: isTarget
                          ? kPrimaryOrange.withOpacity(0.45)
                          : kBorderColor,
                    ),
                  ),
                  child: Text(
                    c.score != null
                        ? '${c.text}  (${c.score!.toStringAsFixed(2)})'
                        : c.text,
                    style: TextStyle(
                      color: isTarget ? kPrimaryOrange : kTextMain,
                      fontSize: 13,
                      fontWeight: isTarget ? FontWeight.w700 : FontWeight.w500,
                    ),
                  ),
                );
              }).toList(),
            ),
          ] else ...[
            const SizedBox(height: 8),
            const Text(
              '沒有候選結果',
              style: TextStyle(color: kTextMuted, fontSize: 12),
            ),
          ],
        ],
      ),
    );
  }
}

// ══════════════════════════════════════════════════════════════════════════════
// NAV BUTTONS (prev / next / random)
// ══════════════════════════════════════════════════════════════════════════════

class _NavButtons extends StatelessWidget {
  const _NavButtons();

  @override
  Widget build(BuildContext context) {
    return Wrap(
      alignment: WrapAlignment.center,
      spacing: 10,
      runSpacing: 8,
      children: [
        _NavBtn(
          label: '上一個',
          icon: Icons.arrow_back_ios_new,
          onTap: () => context.read<AppState>().prevEntry(),
        ),
        _NavBtn(
          label: '隨機',
          icon: Icons.shuffle,
          onTap: () => context.read<AppState>().randomEntry(),
          accent: true,
        ),
        _NavBtn(
          label: '下一個',
          icon: Icons.arrow_forward_ios,
          onTap: () => context.read<AppState>().nextEntry(),
          iconTrailing: true,
        ),
      ],
    );
  }
}

class _NavBtn extends StatelessWidget {
  final String label;
  final IconData icon;
  final VoidCallback onTap;
  final bool accent;
  final bool iconTrailing;

  const _NavBtn({
    required this.label,
    required this.icon,
    required this.onTap,
    this.accent = false,
    this.iconTrailing = false,
  });

  @override
  Widget build(BuildContext context) {
    final bg = accent ? kPrimaryOrange : kBgCard2;
    final fg = accent ? kBgMain : kTextSub;
    final border = accent ? kPrimaryOrange : kBorderColor;

    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 11),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: border),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (!iconTrailing) ...[
              Icon(icon, color: fg, size: 14),
              const SizedBox(width: 6),
            ],
            Text(
              label,
              style: TextStyle(
                color: fg,
                fontSize: 13,
                fontWeight: accent ? FontWeight.w600 : FontWeight.normal,
                letterSpacing: 0.5,
              ),
            ),
            if (iconTrailing) ...[
              const SizedBox(width: 6),
              Icon(icon, color: fg, size: 14),
            ],
          ],
        ),
      ),
    );
  }
}
