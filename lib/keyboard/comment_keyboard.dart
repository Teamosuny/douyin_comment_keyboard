import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'emoji_category.dart';

/// 输入状态
enum InputState { initial, keyboard, emoji, image }

/// 可在任意界面复用的评论键盘组件：输入框 + 图片选择 + @ + emoji/系统键盘切换 + 发送
///
/// 整个界面只允许存在一个键盘实例（可通过 [CommentKeyboard.activeInstance] 获取当前活跃实例）。
/// [child] 上方内容区域（如列表），点击蒙版会收起键盘
/// [onSend] 发送回调：文案 + 图片路径列表；不传则仅清空不回调
/// [hintText] 输入框占位
/// [sendButtonText] 发送按钮文案
class CommentKeyboard extends StatefulWidget {
  const CommentKeyboard({
    super.key,
    required this.child,
    this.onSend,
    this.hintText = '分享你此刻的想法',
    this.sendButtonText = '发送',
  });

  final Widget child;
  final void Function(String text, List<String> imagePaths)? onSend;
  final String hintText;
  final String sendButtonText;

  /// 当前界面中活跃的键盘状态实例（整个界面只允许一个）
  static Object? get activeInstance => _CommentKeyboardState._activeInstance;

  @override
  State<CommentKeyboard> createState() => _CommentKeyboardState();
}

class _CommentKeyboardState extends State<CommentKeyboard>
    with WidgetsBindingObserver {
  static _CommentKeyboardState? _activeInstance;

  final TextEditingController _textController = TextEditingController();
  final FocusNode _focusNode = FocusNode();
  final GlobalKey _textFieldKey = GlobalKey();
  final GlobalKey _inputAreaKey = GlobalKey();

  InputState _currentState = InputState.initial;
  List<XFile> _selectedImages = [];
  List<String> _recentEmojis = ['🙇', '🎅', '🍎', '🌙', '👍', '🌹', '😂', '😀'];
  bool _showFocusedLayout = false;
  double _systemKeyboardHeight = 0;
  bool _showEmojiLayout = false;
  double _fixedInputAreaBottom = 0;
  double _fixedEmojiPanelHeight = 0;
  bool _emojiPanelLoaded = false;
  double _previousKeyboardHeight = 0;
  double _inputAreaHeight = 0;
  bool _pendingShowSystemKeyboard = false;
  bool _unfocusedToShowEmoji = false;
  /// 跳转选图前主动 unfocus，与「键盘退出」同步失焦，失焦时吞掉不收起
  bool _unfocusingBeforeImagePicker = false;
  bool _emojiKeyboardButtonDisabled = false;
  static const String _cachedEmojiKeyboardHeightKey =
      'cached_emoji_keyboard_height';
  static const String _cachedSystemKeyboardHeightKey =
      'cached_system_keyboard_height';
  /// 蒙板预留输入条高度：_inputAreaHeight 未测量前用的最小值，避免遮住输入框/按钮（如荣耀首帧测量晚）
  static const double _kMaskInputAreaFallbackHeight = 140;

  /// didChangeMetrics 节流：键盘动画时避免每帧 setState
  int _lastMetricsSetStateAt = 0;
  static const int _kMetricsThrottleMs = 80;
  /// 高度缓存保存防抖，避免键盘动画过程中频繁写盘
  Timer? _saveHeightDebounce;
  double? _pendingSaveEmojiHeight;
  double? _pendingSaveSystemHeight;
  /// 输入框 onChanged 节流，减少输入时整树重建
  Timer? _onChangedDebounce;

  double get _effectiveEmojiPanelHeight {
    if (_systemKeyboardHeight > 0) {
      return _systemKeyboardHeight + _kSuggestionBarHeight;
    }
    if (_fixedEmojiPanelHeight > 0) {
      return _fixedEmojiPanelHeight.clamp(
        _kMinEmojiPanelHeight,
        double.infinity,
      );
    }
    return 0;
  }

  @override
  void initState() {
    super.initState();
    if (_activeInstance != null && _activeInstance != this) {
      assert(false, 'CommentKeyboard: 整个界面只允许存在一个键盘实例');
    }
    _activeInstance = this;
    WidgetsBinding.instance.addObserver(this);
    _runFullKeyboardInit();
    _focusNode.addListener(_onFocusChange);
  }

  /// 完整键盘初始化（加载缓存高度等），initState 与每次点击图片时执行
  Future<void> _runFullKeyboardInit() async {
    await _loadCachedEmojiKeyboardHeight();
    if (mounted) setState(() {});
  }

  void _onFocusChange() {
    if (_focusNode.hasFocus) {
      if (_fixedInputAreaBottom == 0) {
        final screenHeight = MediaQuery.of(context).size.height;
        final panelHeight = _effectiveEmojiPanelHeight > 0
            ? _effectiveEmojiPanelHeight
            : (screenHeight * 0.5 + _kSuggestionBarHeight).clamp(
                _kMinEmojiPanelHeight,
                double.infinity,
              );
        if (_fixedEmojiPanelHeight == 0) _fixedEmojiPanelHeight = panelHeight;
        _fixedInputAreaBottom = panelHeight;
      }
      setState(() {
        _currentState = InputState.emoji;
        _showEmojiLayout = true;
        _showFocusedLayout = true;
        if (!_emojiPanelLoaded) _emojiPanelLoaded = true;
      });
    } else {
      if (_pendingShowSystemKeyboard) {
        setState(() => _pendingShowSystemKeyboard = false);
        return;
      }
      if (_unfocusedToShowEmoji) {
        setState(() {
          _unfocusedToShowEmoji = false;
          _currentState = InputState.emoji;
          _showEmojiLayout = true;
          _showFocusedLayout = true;
          if (_fixedInputAreaBottom == 0 && _effectiveEmojiPanelHeight > 0) {
            _fixedInputAreaBottom = _effectiveEmojiPanelHeight;
          }
          if (!_emojiPanelLoaded) _emojiPanelLoaded = true;
        });
        return;
      }
      if (_unfocusingBeforeImagePicker) {
        setState(() => _unfocusingBeforeImagePicker = false);
        return;
      }
      if (_currentState == InputState.keyboard) {
        setState(() {
          _currentState = InputState.initial;
          _showFocusedLayout = false;
          _fixedInputAreaBottom = 0;
          _fixedEmojiPanelHeight = 0;
        });
      } else if (_currentState == InputState.emoji) {
        setState(() => _showFocusedLayout = false);
      }
    }
  }

  void _onInitialInputAreaTap() {
    if (_currentState != InputState.initial) return;
    if (_fixedInputAreaBottom == 0) {
      final screenHeight = MediaQuery.of(context).size.height;
      final panelHeight = _effectiveEmojiPanelHeight > 0
          ? _effectiveEmojiPanelHeight
          : (screenHeight * 0.5 + _kSuggestionBarHeight).clamp(
              _kMinEmojiPanelHeight,
              double.infinity,
            );
      if (_fixedEmojiPanelHeight == 0) _fixedEmojiPanelHeight = panelHeight;
      _fixedInputAreaBottom = panelHeight;
    }
    setState(() {
      _currentState = InputState.emoji;
      _showEmojiLayout = true;
      _showFocusedLayout = true;
      _pendingShowSystemKeyboard = true;
      if (!_emojiPanelLoaded) _emojiPanelLoaded = true;
    });
    Future.delayed(const Duration(milliseconds: 350), () {
      if (!mounted) return;
      _pendingShowSystemKeyboard = false;
      _focusNode.requestFocus();
    });
  }

  @override
  void didChangeMetrics() {
    if (!mounted) return;
    final mq = MediaQuery.of(context);
    final viewInsets = mq.viewInsets;
    final viewPadding = mq.padding;
    final keyboardInset = viewInsets.bottom;
    final bottomSafe = viewPadding.bottom;
    final realKeyboardHeight = keyboardInset + bottomSafe;

    if (keyboardInset != _previousKeyboardHeight) {
      _previousKeyboardHeight = keyboardInset;

      if (keyboardInset > 0 && _focusNode.hasFocus) {
        final newHeight = realKeyboardHeight > _systemKeyboardHeight
            ? realKeyboardHeight
            : _systemKeyboardHeight;
        _systemKeyboardHeight = newHeight;
        final emojiPanelHeight = (newHeight + _kSuggestionBarHeight).clamp(
          _kMinEmojiPanelHeight,
          double.infinity,
        );
        _fixedEmojiPanelHeight = emojiPanelHeight;
        _fixedInputAreaBottom = emojiPanelHeight;
        _pendingSaveEmojiHeight = emojiPanelHeight;
        _pendingSaveSystemHeight = newHeight;
        _debouncedSaveHeights();
      }
      if (keyboardInset == 0 &&
          _focusNode.hasFocus &&
          !_unfocusedToShowEmoji) {
        _focusNode.unfocus();
      }

      final now = DateTime.now().millisecondsSinceEpoch;
      if (now - _lastMetricsSetStateAt >= _kMetricsThrottleMs) {
        _lastMetricsSetStateAt = now;
        setState(() {});
      } else {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          final t = DateTime.now().millisecondsSinceEpoch;
          if (t - _lastMetricsSetStateAt >= _kMetricsThrottleMs) {
            _lastMetricsSetStateAt = t;
            setState(() {});
          }
        });
      }
    }
  }

  void _debouncedSaveHeights() {
    _saveHeightDebounce?.cancel();
    _saveHeightDebounce = Timer(const Duration(milliseconds: 400), () {
      _saveHeightDebounce = null;
      if (_pendingSaveEmojiHeight != null) {
        _saveEmojiKeyboardHeight(_pendingSaveEmojiHeight!);
        _pendingSaveEmojiHeight = null;
      }
      if (_pendingSaveSystemHeight != null) {
        _saveSystemKeyboardHeight(_pendingSaveSystemHeight!);
        _pendingSaveSystemHeight = null;
      }
    });
  }

  static const double _kMinEmojiPanelHeight = 220.0;

  Future<void> _loadCachedEmojiKeyboardHeight() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final cachedPanelHeight = prefs.getDouble(_cachedEmojiKeyboardHeightKey);
      final cachedSystemHeight = prefs.getDouble(
        _cachedSystemKeyboardHeightKey,
      );
      if (cachedPanelHeight != null &&
          cachedPanelHeight >= _kMinEmojiPanelHeight) {
        setState(() {
          _fixedEmojiPanelHeight = cachedPanelHeight;
          if (cachedSystemHeight != null && cachedSystemHeight > 0) {
            _systemKeyboardHeight = cachedSystemHeight;
          }
        });
      }
    } catch (e) {
      debugPrint('加载缓存的键盘高度失败: $e');
    }
  }

  Future<void> _saveEmojiKeyboardHeight(double height) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setDouble(_cachedEmojiKeyboardHeightKey, height);
    } catch (_) {}
  }

  Future<void> _saveSystemKeyboardHeight(double height) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setDouble(_cachedSystemKeyboardHeightKey, height);
    } catch (_) {}
  }

  @override
  void dispose() {
    _saveHeightDebounce?.cancel();
    _onChangedDebounce?.cancel();
    if (_activeInstance == this) _activeInstance = null;
    WidgetsBinding.instance.removeObserver(this);
    _textController.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _showEmojiPanel() {
    final mq = MediaQuery.of(context);
    final keyboardInset = mq.viewInsets.bottom;
    final bottomSafe = mq.padding.bottom;
    final realKeyboardHeight = keyboardInset + bottomSafe;
    if (keyboardInset > 0 && realKeyboardHeight > _systemKeyboardHeight) {
      _systemKeyboardHeight = realKeyboardHeight;
      _fixedEmojiPanelHeight = (realKeyboardHeight + _kSuggestionBarHeight)
          .clamp(_kMinEmojiPanelHeight, double.infinity);
    }

    if (_focusNode.hasFocus) {
      _unfocusedToShowEmoji = true;
      _focusNode.unfocus();
    }

    final screenHeight = mq.size.height;
    final panelHeight = _effectiveEmojiPanelHeight > 0
        ? _effectiveEmojiPanelHeight
        : (screenHeight * 0.5 + _kSuggestionBarHeight).clamp(
            _kMinEmojiPanelHeight,
            double.infinity,
          );

    setState(() {
      _currentState = InputState.emoji;
      _showEmojiLayout = true;
      _showFocusedLayout = true;
      if (_fixedEmojiPanelHeight == 0) _fixedEmojiPanelHeight = panelHeight;
      _fixedInputAreaBottom = panelHeight;
      if (!_emojiPanelLoaded) _emojiPanelLoaded = true;
    });
  }

  void _showImagePicker() async {
    await _runFullKeyboardInit();
    if (!mounted) return;
    final stateBefore = _currentState;
    final hadFocusBefore = _focusNode.hasFocus;
    if (hadFocusBefore) {
      _unfocusingBeforeImagePicker = true;
      _focusNode.unfocus();
      await Future.delayed(const Duration(milliseconds: 80));
      if (!mounted) return;
      _unfocusingBeforeImagePicker = false;
    }
    final ImagePicker picker = ImagePicker();
    final List<XFile> images = await picker.pickMultiImage();

    if (!mounted) return;
    if (images.isNotEmpty) {
      setState(() {
        _selectedImages = images;
        _currentState = InputState.emoji;
        _showEmojiLayout = true;
        _showFocusedLayout = true;
        if (_fixedInputAreaBottom == 0) {
          final screenHeight = MediaQuery.of(context).size.height;
          final panelHeight = _effectiveEmojiPanelHeight > 0
              ? _effectiveEmojiPanelHeight
              : (screenHeight * 0.5 + _kSuggestionBarHeight).clamp(
                  _kMinEmojiPanelHeight,
                  double.infinity,
                );
          if (_fixedEmojiPanelHeight == 0) _fixedEmojiPanelHeight = panelHeight;
          _fixedInputAreaBottom = panelHeight;
        }
        if (!_emojiPanelLoaded) _emojiPanelLoaded = true;
      });
      _applyFocusAndKeyboardAfterImagePicker(hadFocusBefore);
    } else {
      if (_selectedImages.isEmpty) setState(() => _currentState = stateBefore);
      _applyFocusAndKeyboardAfterImagePicker(hadFocusBefore);
    }
  }

  /// 选图返回后：跳转前已同步失焦，这里只 requestFocus 恢复焦点+键盘，绝不在此处 unfocus
  void _applyFocusAndKeyboardAfterImagePicker(bool hadFocusBefore) {
    if (!hadFocusBefore) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (!_focusNode.hasFocus) _focusNode.requestFocus();
    });
  }

  void _removeImage(int index) {
    setState(() {
      _selectedImages.removeAt(index);
      // 图片删光后保持当前展开状态，不退出键盘/输入条
    });
  }

  Future<void> _confirmRemoveImage(int index) async {
    final overlay = Overlay.of(context);
    final completer = Completer<bool>();
    late OverlayEntry entry;
    void dismiss(bool result) {
      if (!completer.isCompleted) completer.complete(result);
      entry.remove();
    }
    entry = OverlayEntry(
      builder: (context) => Stack(
        alignment: Alignment.center,
        children: [
          ModalBarrier(
            dismissible: true,
            color: Colors.black54,
            onDismiss: () => dismiss(false),
          ),
          Material(
            color: Colors.transparent,
            child: Container(
              margin: const EdgeInsets.symmetric(horizontal: 60),
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 20),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text(
                    '确认删除选中的图片吗?',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 14),
                  ),
                  const SizedBox(height: 24),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      TextButton(
                        onPressed: () => dismiss(false),
                        child: const Text('取消', style: TextStyle(color: Colors.grey)),
                      ),
                      const SizedBox(width: 60),
                      TextButton(
                        onPressed: () => dismiss(true),
                        child: const Text('确认'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
    overlay.insert(entry);
    final confirmed = await completer.future;
    if (mounted && confirmed) _removeImage(index);
  }

  void _addMoreImages() async {
    final ImagePicker picker = ImagePicker();
    final List<XFile> images = await picker.pickMultiImage();
    if (images.isNotEmpty) {
      setState(() => _selectedImages.addAll(images));
    }
  }

  void _insertEmoji(String emoji) {
    final text = _textController.text;
    final selection = _textController.selection;
    final newText = text.replaceRange(
      selection.start < 0 ? text.length : selection.start,
      selection.end < 0 ? text.length : selection.end,
      emoji,
    );
    _textController.text = newText;
    _textController.selection = TextSelection.collapsed(
      offset:
          (selection.start < 0 ? text.length : selection.start) + emoji.length,
    );
    setState(() {
      _recentEmojis.remove(emoji);
      _recentEmojis.insert(0, emoji);
      if (_recentEmojis.length > 20) _recentEmojis.removeLast();
    });
  }

  void _insertAtSign() {
    final text = _textController.text;
    final selection = _textController.selection;
    final offset = selection.start < 0 ? text.length : selection.start;
    final newText = text.replaceRange(offset, offset, '@');
    _textController.text = newText;
    _textController.selection = TextSelection.collapsed(offset: offset + 1);
  }

  void _sendMessage() {
    final text = _textController.text.trim();
    if (text.isEmpty && _selectedImages.isEmpty) return;

    final imagePaths = _selectedImages.map((e) => e.path).toList();
    final actualText = text == '[图片]' ? '' : text;

    widget.onSend?.call(actualText, imagePaths);

    setState(() {
      _textController.clear();
      _selectedImages.clear();
      _currentState = InputState.initial;
      _showFocusedLayout = false;
      _showEmojiLayout = false;
      _fixedInputAreaBottom = 0;
      _fixedEmojiPanelHeight = 0;
      _emojiPanelLoaded = false;
    });
    _focusNode.unfocus();
  }

  void _dismissKeyboard() {
    _focusNode.unfocus();
    setState(() {
      _currentState = InputState.initial;
      _showFocusedLayout = false;
      _showEmojiLayout = false;
      _fixedInputAreaBottom = 0;
      _fixedEmojiPanelHeight = 0;
      _emojiPanelLoaded = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final bottomPadding = MediaQuery.of(context).padding.bottom;
    final viewInsets = MediaQuery.of(context).viewInsets;
    final hasKeyboard = viewInsets.bottom > 0 && _focusNode.hasFocus;
    final shouldShowOverlay = hasKeyboard || _currentState == InputState.emoji;

    return Scaffold(
      backgroundColor: const Color(0xFFF5F5F5),
      resizeToAvoidBottomInset: _currentState != InputState.emoji,
      body: SafeArea(
        top: false,
        bottom: false,
        child: Stack(
          children: [
            Column(
              mainAxisSize: MainAxisSize.max,
              children: [
                Expanded(
                  child: Stack(
                    children: [
                      widget.child,
                      if (shouldShowOverlay)
                        Positioned(
                          top: 0,
                          left: 0,
                          right: 0,
                          bottom:
                              (_currentState == InputState.emoji &&
                                  _fixedInputAreaBottom > 0)
                              ? _fixedInputAreaBottom +
                                  (_inputAreaHeight > 0
                                      ? _inputAreaHeight
                                      : _kMaskInputAreaFallbackHeight)
                              : 0,
                          child: GestureDetector(
                            onTap: _dismissKeyboard,
                            child: Container(
                              color: Colors.black.withOpacity(0.2),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
                if (_currentState == InputState.initial ||
                    _currentState == InputState.image) ...[
                  _currentState == InputState.initial
                      ? GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTap: _onInitialInputAreaTap,
                          child: _buildInputArea(bottomPadding),
                        )
                      : _buildInputArea(bottomPadding),
                  if (viewInsets.bottom > 0 && _focusNode.hasFocus)
                    _buildSuggestionBar(),
                ],
              ],
            ),
            if (_currentState == InputState.emoji && _fixedInputAreaBottom > 0)
              Positioned(
                bottom: viewInsets.bottom > 0
                    ? (_systemKeyboardHeight > 0
                          ? _effectiveEmojiPanelHeight
                          : viewInsets.bottom + _kSuggestionBarHeight)
                    : _fixedInputAreaBottom,
                left: 0,
                right: 0,
                child: _buildInputArea(bottomPadding),
              ),
            if (_currentState == InputState.emoji && _fixedInputAreaBottom > 0)
              Positioned(
                bottom: 0,
                left: 0,
                right: 0,
                child: SizedBox(
                  height: _effectiveEmojiPanelHeight > 0
                      ? _effectiveEmojiPanelHeight
                      : _fixedEmojiPanelHeight.clamp(
                          _kMinEmojiPanelHeight,
                          double.infinity,
                        ),
                  child: _buildEmojiPanel(
                    overrideHeight: _effectiveEmojiPanelHeight > 0
                        ? _effectiveEmojiPanelHeight
                        : _fixedEmojiPanelHeight.clamp(
                            _kMinEmojiPanelHeight,
                            double.infinity,
                          ),
                  ),
                ),
              ),
            if (_currentState == InputState.emoji &&
                viewInsets.bottom > 0 &&
                _focusNode.hasFocus)
              Positioned(
                bottom: viewInsets.bottom,
                left: 0,
                right: 0,
                child: _buildSuggestionBar(),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildInputArea(double bottomPadding) {
    final hasFocus = _focusNode.hasFocus;
    final showFocusedLayout =
        (hasFocus && _showFocusedLayout) ||
        (_currentState == InputState.emoji && _showEmojiLayout);
    final hasText = _textController.text.trim().isNotEmpty;
    final hasImages = _selectedImages.isNotEmpty;
    final hasContent = hasText || hasImages;
    final viewInsets = MediaQuery.of(context).viewInsets;
    final actualBottomPadding =
        (_currentState == InputState.emoji || viewInsets.bottom > 0)
        ? 0.0
        : bottomPadding;

    final textField = TextField(
      key: _textFieldKey,
      controller: _textController,
      focusNode: _focusNode,
      style: const TextStyle(fontSize: 15, color: Color(0xFF333333)),
      decoration: InputDecoration(
        hintText: !hasFocus && hasImages && !hasText ? '[图片]' : widget.hintText,
        hintStyle: const TextStyle(fontSize: 15, color: Color(0xFF999999)),
        border: InputBorder.none,
        isDense: true,
      ),
      maxLines: showFocusedLayout && _selectedImages.isEmpty ? 3 : 1,
      minLines: showFocusedLayout && _selectedImages.isEmpty ? 3 : 1,
      textInputAction: TextInputAction.newline,
      onChanged: (_) {
        _onChangedDebounce?.cancel();
        _onChangedDebounce = Timer(const Duration(milliseconds: 80), () {
          _onChangedDebounce = null;
          if (mounted) setState(() {});
        });
      },
    );

    final toolbarButtons = Row(
      children: [
        _buildToolbarIconImage('assets/icons/image.png', _showImagePicker),
        SizedBox(width: showFocusedLayout ? 20 : 5),
        _buildToolbarIconImage('assets/icons/at.png', _insertAtSign),
        SizedBox(width: showFocusedLayout ? 20 : 5),
        _buildEmojiOrKeyboardButton(),
      ],
    );

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final ctx = _inputAreaKey.currentContext;
      if (ctx == null) return;
      final box = ctx.findRenderObject();
      if (box is RenderBox) {
        final height = box.size.height;
        if (height != _inputAreaHeight) {
          setState(() => _inputAreaHeight = height);
        }
      }
    });

    return Container(
      key: _inputAreaKey,
      color: Colors.white,
      padding: EdgeInsets.only(bottom: actualBottomPadding),
      margin: EdgeInsets.zero,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        mainAxisAlignment: MainAxisAlignment.start,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: const Color(0xFFF5F5F5),
              borderRadius: BorderRadius.circular(18),
            ),
            child:
                showFocusedLayout ||
                    (_currentState == InputState.emoji && _showEmojiLayout) ||
                    _currentState == InputState.image
                ? Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      textField,
                      if (_selectedImages.isNotEmpty) _buildImagePreview(),
                    ],
                  )
                : Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      if (hasImages && hasText)
                        Padding(
                          padding: const EdgeInsets.only(right: 4),
                          child: Text(
                            '[图片]',
                            style: const TextStyle(
                              fontSize: 15,
                              color: Color(0xFF333333),
                            ),
                          ),
                        ),
                      Expanded(child: textField),
                      const SizedBox(width: 8),
                      toolbarButtons,
                      const SizedBox(width: 8),
                      if (hasContent)
                        GestureDetector(
                          onTap: () {
                            HapticFeedback.mediumImpact();
                            _sendMessage();
                          },
                          child: Container(
                            height: 32,
                            padding: const EdgeInsets.symmetric(horizontal: 16),
                            decoration: BoxDecoration(
                              color: const Color(0xFFFF2C55),
                              borderRadius: BorderRadius.circular(16),
                            ),
                            alignment: Alignment.center,
                            child: Text(
                              widget.sendButtonText,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 14,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
          ),
          if (showFocusedLayout ||
              (_currentState == InputState.emoji && _showEmojiLayout) ||
              _currentState == InputState.image)
            Container(
              height: 44,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Row(
                children: [
                  toolbarButtons,
                  const Spacer(),
                  if (hasContent)
                    GestureDetector(
                      onTap: () {
                        HapticFeedback.mediumImpact();
                        _sendMessage();
                      },
                      child: Container(
                        height: 32,
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        decoration: BoxDecoration(
                          color: const Color(0xFFFF2C55),
                          borderRadius: BorderRadius.circular(16),
                        ),
                        alignment: Alignment.center,
                        child: Text(
                          widget.sendButtonText,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 14,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ),
                    )
                  else
                    Container(
                      height: 32,
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      decoration: BoxDecoration(
                        color: const Color(0xFFFFFFFF),
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(
                          color: Color(0xFFE5E5E5),
                          width: 0.5,
                        ),
                      ),
                      alignment: Alignment.center,
                      child: Text(
                        widget.sendButtonText,
                        style: const TextStyle(
                          color: Colors.grey,
                          fontSize: 14,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  /// iOS 需要更大点击区域 + opaque 才能稳定触发，否则极易被手势竞技场吞掉
  static const double _kEmojiKeyboardButtonMinTouchTarget = 44;
  /// 切换键盘按钮禁用时长缩短，减轻卡顿感；焦点操作延后到下一帧，避免与手势竞争
  static const int _kEmojiButtonDisableMs = 180;

  Widget _buildEmojiOrKeyboardButton() {
    final showKeyboardIcon =
        _currentState == InputState.emoji && !_focusNode.hasFocus;
    return AbsorbPointer(
      absorbing: _emojiKeyboardButtonDisabled,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () {
          if (_emojiKeyboardButtonDisabled) return;
          HapticFeedback.selectionClick();
          setState(() => _emojiKeyboardButtonDisabled = true);
          if (showKeyboardIcon) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (!mounted) return;
              if (_focusNode.hasFocus) {
                _focusNode.unfocus();
              } else {
                _focusNode.requestFocus();
              }
            });
          } else {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (!mounted) return;
              if (_currentState == InputState.emoji) {
                _focusNode.unfocus();
              } else {
                _showEmojiPanel();
              }
            });
          }
          Future.delayed(
            const Duration(milliseconds: _kEmojiButtonDisableMs),
            () {
              if (!mounted) return;
              setState(() => _emojiKeyboardButtonDisabled = false);
            },
          );
        },
        child: SizedBox(
          width: _kEmojiKeyboardButtonMinTouchTarget,
          height: _kEmojiKeyboardButtonMinTouchTarget,
          child: Center(
            child: showKeyboardIcon
                ? Image.asset(
                    'assets/icons/keyboard.png',
                    width: 20.5,
                    height: 20.5,
                    fit: BoxFit.contain,
                  )
                : Image.asset(
                    'assets/icons/phiz.png',
                    width: 20.5,
                    height: 20.5,
                    fit: BoxFit.contain,
                  ),
          ),
        ),
      ),
    );
  }

  Widget _buildToolbarIconImage(String assetPath, VoidCallback onTap) {
    return GestureDetector(
      onTap: () {
        HapticFeedback.selectionClick();
        onTap();
      },
      child: Container(
        width: 36,
        height: 36,
        alignment: Alignment.center,
        child: Image.asset(
          assetPath,
          width: 20,
          height: 20,
          fit: BoxFit.contain,
        ),
      ),
    );
  }

  Widget _buildImagePreview() {
    return Container(
      height: 80,
      padding: const EdgeInsets.symmetric(vertical: 8),
      margin: const EdgeInsets.only(top: 10),
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        itemCount: _selectedImages.length + 1,
        itemBuilder: (context, index) {
          if (index == _selectedImages.length) {
            return Padding(
              padding: const EdgeInsets.only(left: 8),
              child: GestureDetector(
                onTap: _addMoreImages,
                child: Container(
                  width: 64,
                  height: 64,
                  decoration: BoxDecoration(
                    color: const Color(0xFFFFFFFF),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: const Icon(Icons.add, size: 24, color: Colors.black),
                ),
              ),
            );
          }
          final image = _selectedImages[index];
          return Padding(
            padding: EdgeInsets.only(
              right: index < _selectedImages.length - 1 ? 8 : 0,
            ),
            child: Stack(
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: Image.file(
                    File(image.path),
                    width: 64,
                    height: 64,
                    fit: BoxFit.cover,
                  ),
                ),
                Positioned(
                  top: 2,
                  right: 2,
                  child: GestureDetector(
                    onTap: () => _confirmRemoveImage(index),
                    child: Container(
                      width: 20,
                      height: 20,
                      decoration: const BoxDecoration(
                        color: Colors.black54,
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(
                        Icons.close,
                        size: 14,
                        color: Colors.white,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  static const double _kSuggestionBarHeight = 50;

  Widget _buildSuggestionBar() {
    return Container(
      height: 50,
      margin: EdgeInsets.zero,
      decoration: const BoxDecoration(
        color: Colors.white,
        border: Border(top: BorderSide(color: Color(0xFFE5E5E5), width: 0.5)),
      ),
      child: Container(
        height: 49.5,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: ListView.builder(
          scrollDirection: Axis.horizontal,
          itemCount: _recentEmojis.length,
          itemBuilder: (context, index) {
            return GestureDetector(
              onTap: () {
                HapticFeedback.selectionClick();
                _insertEmoji(_recentEmojis[index]);
              },
              child: Container(
                width: 34,
                height: 34,
                margin: const EdgeInsets.only(right: 8),
                alignment: Alignment.center,
                child: Text(
                  _recentEmojis[index],
                  style: const TextStyle(fontSize: 24),
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _buildEmojiPanel({double? overrideHeight}) {
    final raw =
        overrideHeight ??
        (_effectiveEmojiPanelHeight > 0
            ? _effectiveEmojiPanelHeight
            : (MediaQuery.of(context).size.height * 0.5 +
                  _kSuggestionBarHeight));
    final panelHeight = raw.clamp(_kMinEmojiPanelHeight, double.infinity);

    if (_emojiPanelLoaded) {
      return Container(
        height: panelHeight,
        decoration: const BoxDecoration(
          color: Colors.white,
          border: Border(top: BorderSide(color: Color(0xFFE5E5E5), width: 0.5)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              height: 0,
              decoration: const BoxDecoration(
                border: Border(
                  bottom: BorderSide(color: Color(0xFFE5E5E5), width: 0.5),
                ),
              ),
            ),
            Flexible(
              child: ClipRect(
                child: LayoutBuilder(
                  builder: (_, c) => EmojiPanelContent(
                    recentEmojis: _recentEmojis,
                    onEmojiSelected: _insertEmoji,
                    maxHeight: c.maxHeight,
                  ),
                ),
              ),
            ),
          ],
        ),
      );
    }

    return TweenAnimationBuilder<double>(
      tween: Tween<double>(begin: 0.0, end: 1.0),
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeOutCubic,
      builder: (context, value, child) {
        return Container(
          height: panelHeight,
          decoration: const BoxDecoration(
            color: Colors.white,
            border: Border(
              top: BorderSide(color: Color(0xFFE5E5E5), width: 0.5),
            ),
          ),
          child: ClipRect(
            child: Transform.translate(
              offset: Offset(0, panelHeight * (1 - value)),
              child: Container(
                height: panelHeight,
                color: Colors.white,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      height: 0,
                      decoration: const BoxDecoration(
                        border: Border(
                          bottom: BorderSide(
                            color: Color(0xFFE5E5E5),
                            width: 0.5,
                          ),
                        ),
                      ),
                    ),
                    Flexible(
                      child: LayoutBuilder(
                        builder: (_, c) => ClipRect(
                          child: EmojiPanelContent(
                            recentEmojis: _recentEmojis,
                            onEmojiSelected: _insertEmoji,
                            maxHeight: c.maxHeight,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// Emoji 面板内容（供 CommentKeyboard 内部使用）
class EmojiPanelContent extends StatelessWidget {
  const EmojiPanelContent({
    super.key,
    required this.recentEmojis,
    required this.onEmojiSelected,
    this.maxHeight = double.infinity,
  });

  final List<String> recentEmojis;
  final ValueChanged<String> onEmojiSelected;
  final double maxHeight;

  @override
  Widget build(BuildContext context) {
    final allEmojis = <String>[];
    for (var category in EmojiCategory.categories) {
      allEmojis.addAll(category.emojis);
    }

    return SizedBox(
      height: maxHeight.isFinite ? maxHeight : null,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Flexible(
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 8,
                    ),
                    alignment: Alignment.centerLeft,
                    child: const Text(
                      '最近使用',
                      style: TextStyle(fontSize: 14, color: Color(0xFF999999)),
                    ),
                  ),
                  SizedBox(
                    height: 50,
                    child: _buildRecentEmojiRow(recentEmojis),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 8,
                    ),
                    alignment: Alignment.centerLeft,
                    child: const Text(
                      '全部表情',
                      style: TextStyle(fontSize: 14, color: Color(0xFF999999)),
                    ),
                  ),
                ],
              ),
            ),
          ),
          Flexible(child: _buildEmojiGrid(allEmojis)),
        ],
      ),
    );
  }

  Widget _buildRecentEmojiRow(List<String> emojis) {
    return ListView.builder(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      itemCount: emojis.length,
      itemBuilder: (context, index) {
        return GestureDetector(
          onTap: () {
            HapticFeedback.selectionClick();
            onEmojiSelected(emojis[index]);
          },
          child: Container(
            width: 50,
            alignment: Alignment.center,
            child: Text(
              emojis[index],
              style: const TextStyle(fontSize: 28),
            ),
          ),
        );
      },
    );
  }

  Widget _buildEmojiGrid(List<String> emojis) {
    return GridView.builder(
      padding: const EdgeInsets.only(left: 12, right: 12, top: 10, bottom: 10),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 8,
        mainAxisSpacing: 8,
        crossAxisSpacing: 8,
        childAspectRatio: 1,
      ),
      itemCount: emojis.length,
      itemBuilder: (context, index) {
        return GestureDetector(
          onTap: () {
            HapticFeedback.selectionClick();
            onEmojiSelected(emojis[index]);
          },
          child: Container(
            alignment: Alignment.center,
            child: Text(emojis[index], style: const TextStyle(fontSize: 28)),
          ),
        );
      },
    );
  }
}
