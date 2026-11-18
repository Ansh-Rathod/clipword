import 'package:flutter/cupertino.dart' show CupertinoIcons;
import 'package:flutter/material.dart' show Icons;
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:super_sliver_list/super_sliver_list.dart';

import '../app/controller.dart';
import '../native/models.dart';
import '../theme/tokens.dart';
import 'widgets.dart';

class PalettePage extends StatefulWidget {
  const PalettePage({
    super.key,
    required this.controller,
    required this.palette,
  });
  final ClipwordController controller;
  final ClipPalette palette;

  @override
  State<PalettePage> createState() => _PalettePageState();
}

class _PalettePageState extends State<PalettePage> {
  late final TextEditingController _search;
  late final FocusNode _searchFocus;
  late final FocusNode _pageFocus;
  final _listController = ListController();
  final _scrollController = ScrollController();
  final _selectedRowKey = GlobalKey();
  String _windowMode = '';
  String _listSource = '';
  String? _overlay;
  bool _restoringScroll = false;

  ClipwordController get c => widget.controller;
  ClipPalette get p => widget.palette;

  @override
  void initState() {
    super.initState();
    _search = TextEditingController(text: c.snapshot.searchQuery);
    _searchFocus = FocusNode(onKeyEvent: _onKeyEvent);
    _pageFocus = FocusNode(onKeyEvent: _onKeyEvent);
    _windowMode = c.windowMode;
    _listSource = c.snapshot.source;
    _overlay = c.overlay;
    c.addListener(_onController);
    _focusSearch();
  }

  KeyEventResult _onKeyEvent(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    if (c.menuTracking || c.dialogOpen) {
      return KeyEventResult.ignored;
    }
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.arrowDown) {
      _move(1);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowUp) {
      _move(-1);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.pageDown) {
      _move(8);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.pageUp) {
      _move(-8);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.home) {
      _move(-99999);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.end) {
      _moveToEnd();
      return KeyEventResult.handled;
    }
    if ((key == LogicalKeyboardKey.slash ||
            key == LogicalKeyboardKey.numpadDivide) &&
        HardwareKeyboard.instance.isMetaPressed) {
      _focusSearch();
      return KeyEventResult.handled;
    }
    if (_handleItemShortcut(key)) {
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  bool _handleItemShortcut(LogicalKeyboardKey key) {
    if (c.dialogOpen || c.menuTracking) return false;
    final meta = HardwareKeyboard.instance.isMetaPressed;
    final alt = HardwareKeyboard.instance.isAltPressed;
    final shift = HardwareKeyboard.instance.isShiftPressed;
    if (meta && !alt) {
      if (key == LogicalKeyboardKey.keyC && !shift) {
        c.copySelection();
        return true;
      }
      if (key == LogicalKeyboardKey.keyE) {
        c.editSelection();
        return true;
      }
      if (key == LogicalKeyboardKey.keyV && shift) {
        c.addSelectionToStack();
        return true;
      }
      if (key == LogicalKeyboardKey.backspace ||
          key == LogicalKeyboardKey.delete) {
        c.deleteSelection();
        return true;
      }
    }
    if (alt && !meta) {
      if (key == LogicalKeyboardKey.keyB) {
        c.toggleBookmarkSelection();
        return true;
      }
      if (key == LogicalKeyboardKey.keyP) {
        c.togglePinSelection();
        return true;
      }
    }
    return false;
  }

  Future<void> _moveToEnd() async {
    await c.loadRemaining();
    _move(99999);
  }

  void _move(int delta) {
    if (_searchFocus.hasPrimaryFocus) {
      _focusList();
    }
    if (delta.abs() <= 1 && _revealIfOffscreen(delta)) {
      return;
    }
    _revealIndex(c.move(delta), delta);
  }

  bool _revealIfOffscreen(int delta) {
    final index = c.selectedIndex;
    if (index < 0 || !_listController.isAttached) return false;
    final range = _listController.visibleRange;
    if (range == null) return false;
    if (index >= range.$1 && index <= range.$2) return false;
    _revealIndex(index, delta);
    return true;
  }

  void _revealIndex(int index, int delta) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (index < 0 ||
          !_listController.isAttached ||
          !_scrollController.hasClients) {
        return;
      }
      final range = _listController.visibleRange;
      if (range != null && index >= range.$1 && index <= range.$2) {
        return;
      }
      final above = range != null && index < range.$1;
      _listController.jumpToItem(
        index: index,
        scrollController: _scrollController,
        alignment: above || delta < 0 ? 0.0 : 1.0,
      );
    });
  }

  void _onController() {
    _syncSearch();
    if (c.windowMode == 'palette' && _windowMode != 'palette') {
      _focusSearch();
    } else if (c.windowMode != 'palette' && _windowMode == 'palette') {
      _searchFocus.unfocus();
    }
    _windowMode = c.windowMode;
    _syncListSource();
    _searchFocus.canRequestFocus = !c.dialogOpen;
    if (_overlay != null && c.overlay == null) {
      _restoreFocusAfterOverlay();
    } else if (c.dialogOpen) {
      _searchFocus.unfocus();
    }
    _overlay = c.overlay;
  }

  void _restoreFocusAfterOverlay() {
    if (c.listFocused) {
      _focusList();
    } else {
      _focusSearch();
    }
  }

  void _syncListSource() {
    final source = c.snapshot.source;
    if (source == _listSource) return;
    _saveScroll();
    _listSource = source;
    c.holdScrollUpdates = true;
    _restoringScroll = true;
    _restoreScrollSoon(attempts: 3);
  }

  void _restoreScrollSoon({required int attempts}) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _restoreScroll();
      if (attempts > 1) {
        _restoreScrollSoon(attempts: attempts - 1);
        return;
      }
      _restoringScroll = false;
      c.holdScrollUpdates = false;
    });
  }

  void _setSource(String source) {
    if (source == c.snapshot.source) return;
    _saveScroll();
    c.holdScrollUpdates = true;
    _restoringScroll = true;
    c.channel.setSource(source);
  }

  void _saveScroll() {
    if (!_scrollController.hasClients) return;
    if (_listSource == 'bookmarks') {
      c.bookmarksScrollOffset = _scrollController.offset;
    } else {
      c.historyScrollOffset = _scrollController.offset;
    }
  }

  void _restoreScroll() {
    if (!_scrollController.hasClients) return;
    final target = c.listScrollOffset;
    final max = _scrollController.position.maxScrollExtent;
    _scrollController.jumpTo(target.clamp(0.0, max));
  }

  void _focusSearch() {
    if (c.listFocused) {
      c.listFocused = false;
      c.refresh();
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || c.windowMode == 'settings') return;
      if (c.dialogOpen) return;
      _searchFocus.requestFocus();
    });
  }

  void _focusList() {
    if (!c.listFocused) {
      c.listFocused = true;
      c.refresh();
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || c.windowMode == 'settings') return;
      if (c.dialogOpen) return;
      _searchFocus.unfocus();
      _pageFocus.requestFocus();
    });
  }

  void _keepArrowKeys() {
    _focusList();
  }

  void _openItemActions({String? kind, String? id}) {
    final box =
        _selectedRowKey.currentContext?.findRenderObject() as RenderBox?;
    Offset? origin;
    if (box != null && box.hasSize && box.attached) {
      origin = box.localToGlobal(Offset.zero);
    }
    c.channel.showItemMenu(
      kind: kind,
      id: id,
      x: origin?.dx,
      y: origin?.dy,
    );
  }

  void _syncSearch() {
    if (_search.text != c.snapshot.searchQuery) {
      _search.value = TextEditingValue(
        text: c.snapshot.searchQuery,
        selection: TextSelection.collapsed(
          offset: c.snapshot.searchQuery.length,
        ),
      );
    }
  }

  @override
  void dispose() {
    _saveScroll();
    c.removeListener(_onController);
    _search.dispose();
    _searchFocus.dispose();
    _pageFocus.dispose();
    _listController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final snap = c.snapshot;
    return Shortcuts(
      shortcuts: {
        if (!c.dialogOpen) ...{
          const SingleActivator(LogicalKeyboardKey.arrowDown):
              const _MoveIntent(1),
          const SingleActivator(LogicalKeyboardKey.arrowUp):
              const _MoveIntent(-1),
          const SingleActivator(LogicalKeyboardKey.enter):
              const _ActivateIntent(),
          const SingleActivator(LogicalKeyboardKey.enter, meta: true):
              const _ActivateIntent(secondary: true),
          const SingleActivator(LogicalKeyboardKey.numpadEnter):
              const _ActivateIntent(),
          const SingleActivator(LogicalKeyboardKey.numpadEnter, meta: true):
              const _ActivateIntent(secondary: true),
          const SingleActivator(LogicalKeyboardKey.keyB, meta: true):
              const _ToggleSourceIntent(),
          const SingleActivator(LogicalKeyboardKey.keyK, meta: true):
              const _ActionsIntent(),
          const SingleActivator(LogicalKeyboardKey.slash, meta: true):
              const _FocusSearchIntent(),
          const SingleActivator(LogicalKeyboardKey.keyC, meta: true):
              const _CopyItemIntent(),
          const SingleActivator(LogicalKeyboardKey.keyE, meta: true):
              const _EditItemIntent(),
          const SingleActivator(
            LogicalKeyboardKey.keyV,
            meta: true,
            shift: true,
          ): const _PasteStackIntent(),
          const SingleActivator(LogicalKeyboardKey.backspace, meta: true):
              const _DeleteItemIntent(),
          const SingleActivator(LogicalKeyboardKey.delete, meta: true):
              const _DeleteItemIntent(),
          const SingleActivator(LogicalKeyboardKey.keyB, alt: true):
              const _BookmarkItemIntent(),
          const SingleActivator(LogicalKeyboardKey.keyP, alt: true):
              const _PinItemIntent(),
        },
        const SingleActivator(LogicalKeyboardKey.escape):
            const _EscapeIntent(),
        const SingleActivator(LogicalKeyboardKey.comma, meta: true):
            const _SettingsIntent(),
        const SingleActivator(LogicalKeyboardKey.keyW, meta: true):
            const _CloseIntent(),
        const SingleActivator(LogicalKeyboardKey.keyQ, meta: true):
            const _QuitIntent(),
      },
      child: Actions(
        actions: {
          _MoveIntent: CallbackAction<_MoveIntent>(
            onInvoke: (i) {
              if (c.menuTracking || c.dialogOpen) return null;
              _move(i.delta);
              return null;
            },
          ),
          _ActivateIntent: CallbackAction<_ActivateIntent>(
            onInvoke: (intent) {
              if (c.menuTracking || c.dialogOpen) return null;
              c.activatePrimary(secondary: intent.secondary);
              return null;
            },
          ),
          _EscapeIntent: CallbackAction<_EscapeIntent>(
            onInvoke: (_) {
              if (c.menuTracking) return null;
              if (c.overlay != null) {
                c.overlay = null;
                c.refresh();
                return null;
              }
              if (snap.searchQuery.isNotEmpty) {
                c.channel.setSearch('');
              } else if (snap.timeFilter.isActive) {
                c.channel.setTimeFilter(TimeFilter('any'));
              } else {
                c.channel.hideWindow();
              }
              return null;
            },
          ),
          _ToggleSourceIntent: CallbackAction<_ToggleSourceIntent>(
            onInvoke: (_) {
              if (c.dialogOpen) return null;
              _setSource(snap.source == 'bookmarks' ? 'history' : 'bookmarks');
              return null;
            },
          ),
          _ActionsIntent: CallbackAction<_ActionsIntent>(
            onInvoke: (_) {
              if (c.dialogOpen) return null;
              _openItemActions();
              return null;
            },
          ),
          _SettingsIntent: CallbackAction<_SettingsIntent>(
            onInvoke: (_) {
              c.channel.showSettings();
              return null;
            },
          ),
          _CloseIntent: CallbackAction<_CloseIntent>(
            onInvoke: (_) {
              c.channel.hideWindow();
              return null;
            },
          ),
          _QuitIntent: CallbackAction<_QuitIntent>(
            onInvoke: (_) {
              c.channel.quit();
              return null;
            },
          ),
          _FocusSearchIntent: CallbackAction<_FocusSearchIntent>(
            onInvoke: (_) {
              if (c.dialogOpen) return null;
              _focusSearch();
              return null;
            },
          ),
          _CopyItemIntent: CallbackAction<_CopyItemIntent>(
            onInvoke: (_) {
              if (c.dialogOpen) return null;
              c.copySelection();
              return null;
            },
          ),
          _EditItemIntent: CallbackAction<_EditItemIntent>(
            onInvoke: (_) {
              if (c.dialogOpen) return null;
              c.editSelection();
              return null;
            },
          ),
          _PasteStackIntent: CallbackAction<_PasteStackIntent>(
            onInvoke: (_) {
              if (c.dialogOpen) return null;
              c.addSelectionToStack();
              return null;
            },
          ),
          _DeleteItemIntent: CallbackAction<_DeleteItemIntent>(
            onInvoke: (_) {
              if (c.dialogOpen) return null;
              c.deleteSelection();
              return null;
            },
          ),
          _BookmarkItemIntent: CallbackAction<_BookmarkItemIntent>(
            onInvoke: (_) {
              if (c.dialogOpen) return null;
              c.toggleBookmarkSelection();
              return null;
            },
          ),
          _PinItemIntent: CallbackAction<_PinItemIntent>(
            onInvoke: (_) {
              if (c.dialogOpen) return null;
              c.togglePinSelection();
              return null;
            },
          ),
        },
        child: Focus(
          focusNode: _pageFocus,
          autofocus: !c.dialogOpen,
          onKeyEvent: _onKeyEvent,
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: p.panel,
              borderRadius: BorderRadius.circular(ClipTokens.panelRadius),
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(ClipTokens.panelRadius),
              child: Column(
                children: [
                  _searchRow(snap),
                  ColoredBox(
                    color: p.divider,
                    child: const SizedBox(height: 1, width: double.infinity),
                  ),
                  Expanded(child: _body(snap)),
                  ColoredBox(
                    color: p.divider,
                    child: const SizedBox(height: 1, width: double.infinity),
                  ),
                  _footer(snap),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _searchRow(ClipSnapshot snap) {
    final bookmarks = snap.source == 'bookmarks';
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
      child: Row(
        children: [
          if (bookmarks)
            GlassIconButton(
              iconData: Icons.arrow_back_ios_new,
              palette: p,
              onTap: () => _setSource('history'),
            )
          else
            Icon(CupertinoIcons.search, size: 18, color: p.secondary),
          const SizedBox(width: 10),
          Expanded(
            child: EditableText(
              controller: _search,
              focusNode: _searchFocus,
              style: TextStyle(fontSize: 17, color: p.label),
              cursorColor: ClipTokens.accent,
              backgroundCursorColor: p.secondary,
              onChanged: c.channel.setSearch,
            ),
          ),
          const SizedBox(width: 10),
          FilterChipButton(
            icon: _filterIcon(snap),
            title: _filterTitle(snap),
            emphasized: snap.category != null ||
                snap.appBundleId != null ||
                snap.timeFilter.isActive,
            palette: p,
            onTap: c.channel.showFilterMenu,
          ),
          const SizedBox(width: 10),
          GlassIconButton(
            icon: 'gearshape',
            palette: p,
            onTap: () => c.channel.showSettings(),
          ),
        ],
      ),
    );
  }

  String _filterIcon(ClipSnapshot snap) {
    if (snap.category != null)
      return categoryIcons[snap.category] ?? 'line.3.horizontal.decrease';
    if (snap.appBundleId != null) return 'app.badge';
    if (snap.timeFilter.isActive) return 'calendar';
    return 'line.3.horizontal.decrease';
  }

  String _filterTitle(ClipSnapshot snap) {
    final parts = <String>[];
    if (snap.timeFilter.isActive) parts.add(snap.timeFilter.label);
    final type = categoryLabels[snap.category];
    if (type != null) parts.add(type);
    final app = snap.apps
        .where((a) => a.bundleId == snap.appBundleId)
        .map((a) => a.name);
    if (app.isNotEmpty) parts.add(app.first);
    if (parts.isEmpty) return 'Filter';
    return parts.join(' · ');
  }

  Widget _body(ClipSnapshot snap) {
    if (c.entries
            .where((e) => e.kind != 'section' && e.kind != 'empty')
            .isEmpty &&
        c.entries.where((e) => e.kind == 'folder').isEmpty &&
        snap.source == 'history' &&
        c.entries.isEmpty) {
      return _empty(snap);
    }
    if (snap.source == 'history' && c.itemCount == 0) return _empty(snap);
    if (snap.source == 'bookmarks' &&
        snap.bookmarks.isEmpty &&
        snap.folders.isEmpty) {
      return _empty(snap);
    }
    return Stack(
      fit: StackFit.expand,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(width: ClipTokens.listIdeal, child: _list(snap)),
            ColoredBox(color: p.divider, child: const SizedBox(width: 1)),
            Expanded(
              child: DetailPane(controller: c, palette: p),
            ),
          ],
        ),
        if (c.toastKind != null)
          Positioned(
            top: 14,
            left: 0,
            right: 0,
            child: IgnorePointer(child: Center(child: _toast(c.toastKind!))),
          ),
        if (c.overlay == 'edit')
          Positioned.fill(
            child: EditSheet(controller: c, palette: p),
          ),
        if (c.overlay == 'folder')
          Positioned.fill(
            child: FolderSheet(controller: c, palette: p),
          ),
      ],
    );
  }

  Widget _list(ClipSnapshot snap) {
    final entries = c.entries;
    return NotificationListener<ScrollNotification>(
      onNotification: (notification) {
        if (!_restoringScroll && notification.metrics.hasPixels) {
          c.setListScrollOffset(notification.metrics.pixels);
        }
        if (notification.metrics.extentAfter < 800) {
          c.loadMore();
        }
        return false;
      },
      child: Listener(
        behavior: HitTestBehavior.translucent,
        onPointerDown: (_) => _keepArrowKeys(),
        child: SuperListView.builder(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          listController: _listController,
          controller: _scrollController,
          primary: false,
          cacheExtent: 320,
          itemCount: entries.length,
          findChildIndexCallback: (key) {
            if (key is! ValueKey<String>) return null;
            final index = entries.indexWhere(
              (entry) => '${entry.kind}:${entry.id}' == key.value,
            );
            return index < 0 ? null : index;
          },
          itemBuilder: (context, index) {
            final entry = entries[index];
            final key = ValueKey('${entry.kind}:${entry.id}');
            if (entry.kind == 'section') {
              return Padding(
                key: key,
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 6),
                child: Text(
                  entry.title ?? '',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: p.secondary,
                  ),
                ),
              );
            }
            if (entry.kind == 'empty') {
              return Padding(
                key: key,
                padding: const EdgeInsets.fromLTRB(36, 6, 16, 6),
                child: Text(
                  'Empty folder',
                  style: TextStyle(color: p.tertiary, fontSize: 13),
                ),
              );
            }
            final selected =
                c.selection?.kind == entry.kind && c.selection?.id == entry.id;
            final emphasized = selected && c.listFocused;
            Color? fill;
            if (emphasized) {
              fill = ClipTokens.accent;
            } else if (selected) {
              fill = p.selectedIdle;
            }
            return KeyedSubtree(
              key: key,
              child: MouseRegion(
                cursor: SystemMouseCursors.click,
                child: GestureDetector(
                  key: selected ? _selectedRowKey : null,
                  onTap: () {
                    c.selectEntry(entry.kind, entry.id ?? '');
                    _keepArrowKeys();
                  },
                  onDoubleTap: () => c.activatePrimary(),
                  onSecondaryTap: () =>
                      c.channel.showItemMenu(kind: entry.kind, id: entry.id),
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: fill,
                      borderRadius: BorderRadius.circular(ClipTokens.rowRadius),
                    ),
                    child: Padding(
                      padding: EdgeInsets.fromLTRB(
                        entry.indented ? 20 : 8,
                        6,
                        10,
                        6,
                      ),
                      child: _row(entry, emphasized),
                    ),
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _row(PaletteEntry entry, bool emphasized) {
    final color = emphasized ? const Color(0xFFFFFFFF) : p.label;
    if (entry.kind == 'folder') {
      return Row(
        children: [
          Icon(
            entry.collapsed ? Icons.chevron_right : Icons.keyboard_arrow_down,
            size: 16,
            color: color,
          ),
          const SizedBox(width: 8),
          SymbolIcon('folder.fill', size: 14, color: color),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              entry.title ?? '',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: color),
            ),
          ),
          Text(
            '${entry.count} items',
            style: TextStyle(
              fontSize: 11,
              color: emphasized ? const Color(0xCCFFFFFF) : p.secondary,
            ),
          ),
        ],
      );
    }
    final icon = entry.history?.icon ?? entry.bookmark?.icon ?? 'doc.text';
    final title = entry.history?.title ?? entry.bookmark?.title ?? '';
    final bookmarked = entry.history?.isBookmarked ?? false;
    final pinned = entry.history?.isPinned ?? false;
    return Row(
      children: [
        if (c.recentlyActedID == entry.id)
          Container(
            width: 3,
            height: 16,
            margin: const EdgeInsets.only(right: 6),
            decoration: BoxDecoration(
              color: ClipTokens.accent,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
        SymbolIcon(icon, size: 14, color: color),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: color),
          ),
        ),
        if (bookmarked)
          SymbolIcon(
            'bookmark.fill',
            size: 10,
            color: emphasized ? const Color(0xF2FFFFFF) : ClipTokens.bookmark,
          ),
        if (pinned) ...[
          const SizedBox(width: 4),
          SymbolIcon(
            'pin.fill',
            size: 10,
            color: emphasized ? const Color(0xF2FFFFFF) : ClipTokens.pin,
          ),
        ],
      ],
    );
  }

  Widget _footer(ClipSnapshot snap) {
    final selection = c.selection;
    String? primary;
    String? secondary;
    if (selection?.kind == 'folder') {
      final collapsed = snap.collapsedFolderIDs.contains(selection!.id);
      primary = collapsed ? 'Expand' : 'Collapse';
    } else if (selection != null) {
      if (snap.prefs.pasteAutomatically) {
        primary = 'Paste';
        secondary = 'Copy';
      } else {
        primary = 'Copy';
        secondary = 'Paste';
      }
    }
    final showActions =
        selection?.kind == 'history' || selection?.kind == 'bookmark';
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Row(
        children: [
          FooterPill(
            palette: p,
            onTap: () => _setSource(
              snap.source == 'bookmarks' ? 'history' : 'bookmarks',
            ),
            child: Row(
              children: [
                Text(snap.source == 'bookmarks' ? 'Recents' : 'Bookmarks'),
                const SizedBox(width: 6),
                Keycap(text: '⌘', palette: p),
                const SizedBox(width: 2),
                Keycap(text: 'B', palette: p),
              ],
            ),
          ),
          const Spacer(),
          if (primary != null || showActions)
            FooterPill(
              palette: p,
              onTap: null,
              child: Row(
                children: [
                  if (primary != null)
                    GestureDetector(
                      onTap: () => c.activatePrimary(),
                      child: Row(
                        children: [
                          Text(primary),
                          const SizedBox(width: 6),
                          Keycap(iconData: Icons.keyboard_return, palette: p),
                        ],
                      ),
                    ),
                  if (secondary != null) ...[
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      child: SizedBox(
                        width: 1,
                        height: 16,
                        child: ColoredBox(
                          color: p.label.withValues(alpha: 0.12),
                        ),
                      ),
                    ),
                    GestureDetector(
                      onTap: () => c.activatePrimary(secondary: true),
                      child: Row(
                        children: [
                          Text(secondary),
                          const SizedBox(width: 6),
                          Keycap(text: '⌘', palette: p),
                          const SizedBox(width: 2),
                          Keycap(iconData: Icons.keyboard_return, palette: p),
                        ],
                      ),
                    ),
                  ],
                  if ((primary != null || secondary != null) && showActions)
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      child: SizedBox(
                        width: 1,
                        height: 16,
                        child: ColoredBox(
                          color: p.label.withValues(alpha: 0.12),
                        ),
                      ),
                    ),
                  if (showActions)
                    GestureDetector(
                      onTap: _openItemActions,
                      child: Row(
                        children: [
                          const Text('Actions'),
                          const SizedBox(width: 6),
                          Keycap(text: '⌘', palette: p),
                          const SizedBox(width: 2),
                          Keycap(text: 'K', palette: p),
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

  Widget _empty(ClipSnapshot snap) {
    final filtering =
        snap.searchQuery.isNotEmpty ||
        snap.category != null ||
        snap.appBundleId != null ||
        snap.timeFilter.isActive;
    final title = snap.source == 'bookmarks'
        ? (filtering ? 'No bookmarks match' : 'No bookmarks yet')
        : (filtering ? 'No items match' : 'No clips yet');
    final icon = filtering
        ? 'line.3.horizontal.decrease.circle'
        : (snap.source == 'bookmarks' ? 'bookmark' : 'doc.on.clipboard');
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SymbolIcon(icon, size: 36, color: p.secondary),
          const SizedBox(height: 12),
          Text(title, style: TextStyle(fontSize: 16, color: p.secondary)),
        ],
      ),
    );
  }

  Widget _toast(String kind) {
    String title = kind;
    String icon = 'checkmark.circle.fill';
    Color color = ClipTokens.success;
    switch (kind) {
      case 'copied':
        title = 'Copied';
      case 'pasted':
        title = 'Pasted';
      case 'bookmarked':
        title = 'Bookmarked';
        icon = 'bookmark.fill';
        color = ClipTokens.accent;
      case 'unbookmarked':
        title = 'Removed bookmark';
        icon = 'bookmark';
        color = p.secondary;
      case 'pinned':
        title = 'Pinned';
        icon = 'pin.fill';
        color = ClipTokens.pin;
      case 'unpinned':
        title = 'Unpinned';
        icon = 'pin';
        color = p.secondary;
    }
    return DecoratedBox(
      decoration: BoxDecoration(
        color: p.window,
        borderRadius: BorderRadius.circular(12),
        boxShadow: const [
          BoxShadow(
            color: Color(0x33000000),
            blurRadius: 10,
            offset: Offset(0, 3),
          ),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            SymbolIcon(icon, size: 14, color: color),
            const SizedBox(width: 8),
            Text(
              title,
              style: TextStyle(color: p.label, fontWeight: FontWeight.w500),
            ),
          ],
        ),
      ),
    );
  }
}

class DetailPane extends StatelessWidget {
  const DetailPane({
    super.key,
    required this.controller,
    required this.palette,
  });
  final ClipwordController controller;
  final ClipPalette palette;

  @override
  Widget build(BuildContext context) {
    final selection = controller.selection;
    if (selection == null) {
      return _unavailable('Select an item', 'doc.on.clipboard');
    }
    if (selection.kind == 'folder') {
      return _unavailable('Folder', 'folder.fill');
    }
    final detail = controller.detail;
    final entry = controller.selectedEntry;
    final image = detail?['image'];
    final text = detail?['plainText'] as String? ?? '';
    final fallbackTitle = entry?.history?.title ?? entry?.bookmark?.title ?? '';
    final preview = controller.preview;
    return Column(
      children: [
        Expanded(
          child: image is Uint8List
              ? SingleChildScrollView(child: Image.memory(image))
              : preview != null && preview['failed'] != true
              ? _linkPreview(preview, text)
              : SingleChildScrollView(
                  padding: const EdgeInsets.all(20),
                  child: Align(
                    alignment: Alignment.topLeft,
                    child: Text(
                      text.isEmpty
                          ? (detail?['title'] as String? ?? fallbackTitle)
                          : text,
                      style: TextStyle(
                        fontFamily: 'Menlo',
                        fontSize: 13,
                        color: palette.label,
                      ),
                    ),
                  ),
                ),
        ),
        ColoredBox(
          color: palette.divider,
          child: const SizedBox(height: 1, width: double.infinity),
        ),
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(20),
            child: detail == null ? _infoPending(entry) : _info(detail),
          ),
        ),
      ],
    );
  }

  Widget _unavailable(String title, String icon) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SymbolIcon(icon, size: 36, color: palette.secondary),
          const SizedBox(height: 12),
          Text(title, style: TextStyle(fontSize: 16, color: palette.secondary)),
        ],
      ),
    );
  }

  Widget _linkPreview(Map<Object?, Object?> preview, String fallback) {
    final image = preview['image'];
    final title = preview['title'] as String? ?? fallback;
    final detail = preview['detail'] as String?;
    final url = preview['url'] as String? ?? '';
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (image is Uint8List)
            GestureDetector(
              onTap: () => controller.channel.openUrl(url),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(10),
                child: Image.memory(image),
              ),
            ),
          const SizedBox(height: 10),
          Text(
            title,
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w600,
              color: palette.label,
            ),
          ),
          if (detail != null) ...[
            const SizedBox(height: 6),
            Text(detail, style: TextStyle(color: palette.secondary)),
          ],
          const SizedBox(height: 8),
          GestureDetector(
            onTap: () => controller.channel.openUrl(url),
            child: Text(url, style: const TextStyle(color: ClipTokens.accent)),
          ),
        ],
      ),
    );
  }

  Widget _infoPending(PaletteEntry? entry) {
    final category = entry?.history?.category ?? entry?.bookmark?.category;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Information',
          style: TextStyle(color: palette.secondary, fontSize: 13),
        ),
        const SizedBox(height: 12),
        if (category != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: 110,
                  child: Text(
                    'Content type',
                    style: TextStyle(color: palette.secondary),
                  ),
                ),
                Expanded(
                  child: Text(
                    categoryLabels[category] ?? category,
                    style: TextStyle(color: palette.label),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }

  Widget _info(Map<Object?, Object?> detail) {
    Widget row(String label, Widget value) {
      return Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 110,
              child: Text(label, style: TextStyle(color: palette.secondary)),
            ),
            Expanded(child: value),
          ],
        ),
      );
    }

    final events = (detail['events'] as List?) ?? const [];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Information',
          style: TextStyle(color: palette.secondary, fontSize: 13),
        ),
        const SizedBox(height: 12),
        row(
          'Source',
          Row(
            children: [
              AppGlyph(detail['applicationBundleId'] as String?),
              const SizedBox(width: 6),
              Text(
                detail['appName'] as String? ?? 'Unknown',
                style: TextStyle(color: palette.label),
              ),
            ],
          ),
        ),
        row(
          'Content type',
          Text(
            categoryLabels[detail['category'] as String?] ??
                (detail['contentType'] as String? ?? ''),
            style: TextStyle(color: palette.label),
          ),
        ),
        if (detail['linkURL'] != null)
          row(
            'Address',
            GestureDetector(
              onTap: () =>
                  controller.channel.openUrl(detail['linkURL'] as String),
              child: Text(
                detail['linkURL'] as String,
                style: const TextStyle(color: ClipTokens.accent),
              ),
            ),
          ),
        if (detail['folderName'] != null)
          row(
            'Folder',
            Text(
              detail['folderName'] as String,
              style: TextStyle(color: palette.label),
            ),
          ),
        row(
          'Characters',
          Text(
            '${detail['charCount'] ?? 0}',
            style: TextStyle(color: palette.label),
          ),
        ),
        row(
          'Words',
          Text(
            '${detail['wordCount'] ?? 0}',
            style: TextStyle(color: palette.label),
          ),
        ),
        if (detail['copyCount'] != null)
          row(
            'Copies',
            Text(
              '${detail['copyCount']}',
              style: TextStyle(color: palette.label),
            ),
          ),
        if (detail['pasteCount'] != null)
          row(
            'Pastes',
            Text(
              '${detail['pasteCount']}',
              style: TextStyle(color: palette.label),
            ),
          ),
        if (events.isNotEmpty) ...[
          const SizedBox(height: 12),
          Text(
            'Activity',
            style: TextStyle(color: palette.secondary, fontSize: 13),
          ),
          const SizedBox(height: 8),
          for (final event in events.whereType<Map>())
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Row(
                children: [
                  SymbolIcon(
                    event['kind'] == 'pasted' ? 'text.insert' : 'doc.on.doc',
                    size: 12,
                    color: palette.secondary,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    event['kind'] == 'pasted' ? 'Pasted' : 'Copied',
                    style: TextStyle(color: palette.label),
                  ),
                ],
              ),
            ),
        ],
      ],
    );
  }
}

class EditSheet extends StatefulWidget {
  const EditSheet({super.key, required this.controller, required this.palette});
  final ClipwordController controller;
  final ClipPalette palette;

  @override
  State<EditSheet> createState() => _EditSheetState();
}

class _EditSheetState extends State<EditSheet> {
  late final TextEditingController _text;
  late final FocusNode _focus;
  late final FocusScopeNode _scope;
  bool _saving = false;
  int _focusTries = 0;

  @override
  void initState() {
    super.initState();
    _text = TextEditingController(text: widget.controller.editText);
    _focus = FocusNode(onKeyEvent: _onKey);
    _scope = FocusScopeNode();
    WidgetsBinding.instance.addPostFrameCallback((_) => _focusField());
  }

  void _focusField() {
    if (!mounted) return;
    _scope.requestFocus(_focus);
    _focus.requestFocus();
    if (!_focus.hasFocus && _focusTries < 8) {
      _focusTries += 1;
      WidgetsBinding.instance.addPostFrameCallback((_) => _focusField());
      return;
    }
    _text.selection = TextSelection(
      baseOffset: 0,
      extentOffset: _text.text.length,
    );
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    if (event.logicalKey == LogicalKeyboardKey.escape) {
      _cancel();
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.enter ||
        event.logicalKey == LogicalKeyboardKey.numpadEnter) {
      if (HardwareKeyboard.instance.isShiftPressed) {
        return KeyEventResult.ignored;
      }
      _save();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  void _cancel() {
    widget.controller.overlay = null;
    widget.controller.refresh();
  }

  Future<void> _save() async {
    if (_saving) return;
    _saving = true;
    await widget.controller.channel.editContent(
      widget.controller.editKind ?? 'history',
      widget.controller.editId ?? '',
      _text.text,
    );
    if (!mounted) return;
    widget.controller.overlay = null;
    await widget.controller.reloadSelectedItem();
  }

  @override
  void dispose() {
    _text.dispose();
    _focus.dispose();
    _scope.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.palette;
    return FocusScope(
      node: _scope,
      autofocus: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: _cancel,
        child: ColoredBox(
          color: const Color(0x66000000),
          child: Center(
            child: GestureDetector(
              onTap: () {},
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: p.window,
                  borderRadius: BorderRadius.circular(16),
                ),
                child: SizedBox(
                  width: 480,
                  child: Padding(
                    padding: const EdgeInsets.all(20),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Edit Content',
                          style: TextStyle(
                            fontSize: 17,
                            fontWeight: FontWeight.w600,
                            color: p.label,
                          ),
                        ),
                        const SizedBox(height: 12),
                        SizedBox(
                          height: 220,
                          child: EditableText(
                            controller: _text,
                            focusNode: _focus,
                            maxLines: null,
                            style: TextStyle(
                              fontFamily: 'Menlo',
                              fontSize: 13,
                              color: p.label,
                            ),
                            cursorColor: ClipTokens.accent,
                            backgroundCursorColor: p.secondary,
                          ),
                        ),
                        const SizedBox(height: 16),
                        _DialogActions(
                          palette: p,
                          confirmLabel: 'Save',
                          onCancel: _cancel,
                          onConfirm: _save,
                        ),
                      ],
                    ),
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

class FolderSheet extends StatefulWidget {
  const FolderSheet({
    super.key,
    required this.controller,
    required this.palette,
  });
  final ClipwordController controller;
  final ClipPalette palette;

  @override
  State<FolderSheet> createState() => _FolderSheetState();
}

class _FolderSheetState extends State<FolderSheet> {
  late final TextEditingController _text;
  late final FocusNode _focus;
  late final FocusScopeNode _scope;
  bool _saving = false;
  int _focusTries = 0;

  @override
  void initState() {
    super.initState();
    _text = TextEditingController(text: widget.controller.folderName);
    _focus = FocusNode(onKeyEvent: _onKey);
    _scope = FocusScopeNode();
    WidgetsBinding.instance.addPostFrameCallback((_) => _focusField());
  }

  void _focusField() {
    if (!mounted) return;
    _scope.requestFocus(_focus);
    _focus.requestFocus();
    if (!_focus.hasFocus && _focusTries < 8) {
      _focusTries += 1;
      WidgetsBinding.instance.addPostFrameCallback((_) => _focusField());
      return;
    }
    _text.selection = TextSelection(
      baseOffset: 0,
      extentOffset: _text.text.length,
    );
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    if (event.logicalKey == LogicalKeyboardKey.escape) {
      _cancel();
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.enter ||
        event.logicalKey == LogicalKeyboardKey.numpadEnter) {
      _save();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  void _cancel() {
    widget.controller.overlay = null;
    widget.controller.refresh();
  }

  Future<void> _save() async {
    if (_saving) return;
    _saving = true;
    final rename = widget.controller.renameFolderId != null;
    if (rename) {
      await widget.controller.channel.renameFolder(
        widget.controller.renameFolderId!,
        _text.text,
      );
    } else {
      await widget.controller.channel.createFolder(
        name: _text.text,
        historyId: widget.controller.folderHistoryId,
        bookmarkId: widget.controller.folderBookmarkId,
      );
    }
    if (!mounted) return;
    widget.controller.overlay = null;
    widget.controller.refresh();
  }

  @override
  void dispose() {
    _text.dispose();
    _focus.dispose();
    _scope.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.palette;
    final rename = widget.controller.renameFolderId != null;
    return FocusScope(
      node: _scope,
      autofocus: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: _cancel,
        child: ColoredBox(
          color: const Color(0x66000000),
          child: Center(
            child: GestureDetector(
              onTap: () {},
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: p.window,
                  borderRadius: BorderRadius.circular(14),
                ),
                child: SizedBox(
                  width: 360,
                  child: Padding(
                    padding: const EdgeInsets.all(20),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          rename ? 'Rename Folder' : 'New Folder',
                          style: TextStyle(
                            fontSize: 17,
                            fontWeight: FontWeight.w600,
                            color: p.label,
                          ),
                        ),
                        const SizedBox(height: 12),
                        EditableText(
                          controller: _text,
                          focusNode: _focus,
                          style: TextStyle(fontSize: 15, color: p.label),
                          cursorColor: ClipTokens.accent,
                          backgroundCursorColor: p.secondary,
                        ),
                        const SizedBox(height: 16),
                        _DialogActions(
                          palette: p,
                          confirmLabel: rename ? 'Rename' : 'Create',
                          onCancel: _cancel,
                          onConfirm: _save,
                        ),
                      ],
                    ),
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

class _DialogActions extends StatelessWidget {
  const _DialogActions({
    required this.palette,
    required this.confirmLabel,
    required this.onCancel,
    required this.onConfirm,
  });

  final ClipPalette palette;
  final String confirmLabel;
  final VoidCallback onCancel;
  final VoidCallback onConfirm;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.end,
      children: [
        MouseRegion(
          cursor: SystemMouseCursors.click,
          child: GestureDetector(
            onTap: onCancel,
            child: Row(
              children: [
                Text('Cancel', style: TextStyle(color: palette.secondary)),
                const SizedBox(width: 6),
                Keycap(text: 'esc', palette: palette),
              ],
            ),
          ),
        ),
        const SizedBox(width: 16),
        MouseRegion(
          cursor: SystemMouseCursors.click,
          child: GestureDetector(
            onTap: onConfirm,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: ClipTokens.accent,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
                child: Row(
                  children: [
                    Text(
                      confirmLabel,
                      style: const TextStyle(
                        color: Color(0xFFFFFFFF),
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(width: 8),
                    DecoratedBox(
                      decoration: BoxDecoration(
                        color: const Color(0x33FFFFFF),
                        borderRadius:
                            BorderRadius.circular(ClipTokens.keycapRadius),
                      ),
                      child: const Padding(
                        padding: EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                        child: Icon(
                          Icons.keyboard_return,
                          size: 12,
                          color: Color(0xFFFFFFFF),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _MoveIntent extends Intent {
  const _MoveIntent(this.delta);
  final int delta;
}

class _ActivateIntent extends Intent {
  const _ActivateIntent({this.secondary = false});
  final bool secondary;
}

class _EscapeIntent extends Intent {
  const _EscapeIntent();
}

class _ToggleSourceIntent extends Intent {
  const _ToggleSourceIntent();
}

class _ActionsIntent extends Intent {
  const _ActionsIntent();
}

class _SettingsIntent extends Intent {
  const _SettingsIntent();
}

class _CloseIntent extends Intent {
  const _CloseIntent();
}

class _FocusSearchIntent extends Intent {
  const _FocusSearchIntent();
}

class _QuitIntent extends Intent {
  const _QuitIntent();
}

class _CopyItemIntent extends Intent {
  const _CopyItemIntent();
}

class _EditItemIntent extends Intent {
  const _EditItemIntent();
}

class _PasteStackIntent extends Intent {
  const _PasteStackIntent();
}

class _DeleteItemIntent extends Intent {
  const _DeleteItemIntent();
}

class _BookmarkItemIntent extends Intent {
  const _BookmarkItemIntent();
}

class _PinItemIntent extends Intent {
  const _PinItemIntent();
}
