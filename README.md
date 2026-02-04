# Comment Keyboard

一款适用于 Flutter 的**评论/聊天输入键盘组件**，支持系统键盘与自定义表情面板切换、多图选择、@ 插入，带蒙版收起与高度记忆，适配 iOS / Android，可直接嵌入评论页、详情页等任意界面。

---

## 功能特性

- **双键盘切换**：系统键盘 ⇄ 自定义表情面板，一键切换，支持最近使用表情
- **多图选择**：从相册多选图片，选图前后焦点与键盘状态可保持一致
- **@ 插入**：工具栏一键插入 `@`，便于 @ 用户
- **蒙版收起**：键盘/表情展开时，点击上方内容区域蒙版可收起，输入区与按钮不被蒙版遮挡（预留安全高度）
- **高度记忆**：使用 SharedPreferences 缓存表情面板与系统键盘高度，下次打开更顺滑
- **性能优化**：`didChangeMetrics` 节流、输入框 `onChanged` 防抖、切换键盘焦点延后到下一帧，减轻卡顿与系统手势/IME 超时

---

## 环境要求

- Flutter SDK **^3.9.2**（或与你项目兼容的 3.x）
- Dart **^3.9.2**
- iOS / Android 真机或模拟器（推荐真机测试键盘与相册）

---

## 安装

### 1. 克隆或下载本仓库

```bash
git clone https://github.com/<你的用户名>/<仓库名>.git
cd <仓库名>
```

### 2. 安装依赖

```bash
flutter pub get
```

### 3. 运行示例

```bash
flutter run
```

示例在 `lib/main.dart`，为一个带消息列表的评论页，可直接运行查看效果。

---

## 快速使用

在需要评论/输入的地方，用 `CommentKeyboard` 包住上方内容（如列表），并传入发送回调与可选文案即可。

```dart
CommentKeyboard(
  hintText: '分享你此刻的想法',
  sendButtonText: '发送',
  onSend: (String text, List<String> imagePaths) {
    // 处理发送：文案 + 图片路径列表
  },
  child: YourContentWidget(), // 例如 ListView、单页内容等
)
```

### 参数说明

| 参数 | 类型 | 必填 | 说明 |
|------|------|------|------|
| `child` | `Widget` | ✅ | 键盘上方的内容区域（如评论列表）。点击该区域上的蒙版会收起键盘。 |
| `onSend` | `void Function(String text, List<String> imagePaths)?` | ❌ | 发送回调：文案 + 本地图片路径列表。不传则仅清空输入，不回调。 |
| `hintText` | `String` | ❌ | 输入框占位文案，默认 `'分享你此刻的想法'`。 |
| `sendButtonText` | `String` | ❌ | 发送按钮文案，默认 `'发送'`。 |

### 获取当前键盘实例（可选）

若需要在外层控制键盘（如主动收起），可通过静态 getter 获取当前活跃实例：

```dart
final instance = CommentKeyboard.activeInstance;
// 类型为 Object?，可用于与内部逻辑配合（如有暴露收起接口可在此使用）
```

---

## 项目结构

```
lib/
├── main.dart                 # 示例：评论页 + 消息列表
└── keyboard/
    ├── comment_keyboard.dart  # 核心组件 CommentKeyboard
    └── emoji_category.dart   # 表情分类与数据（表情/手势/动物/食物等）

assets/
└── icons/                    # 工具栏图标：图片、@、表情、系统键盘
    ├── image.png
    ├── at.png
    ├── phiz.png
    └── keyboard.png
```

---

## 依赖

| 依赖 | 用途 |
|------|------|
| `image_picker` | 相册多选图片 |
| `shared_preferences` | 缓存表情/键盘高度 |
| `cached_network_image` | （示例或扩展用） |
| `photo_view` | （示例或扩展用） |

仅做键盘组件集成时，核心依赖为 **image_picker** 与 **shared_preferences**。

---

## 平台说明

- **iOS**：需在 `Info.plist` 中配置相册权限（如 `NSPhotoLibraryUsageDescription`），否则选图会无权限。切换键盘按钮已做 44pt 触控区与 `HitTestBehavior.opaque`，以减轻“难以触发”的问题。
- **Android**：需配置存储/相册权限（如 `READ_EXTERNAL_STORAGE` / `READ_MEDIA_IMAGES`，视 targetSdk 而定）。

---

## 常见问题

1. **荣耀/部分机型：键盘弹出后蒙版遮住输入框和按钮**  
   已通过“蒙板预留输入条高度”处理：未测量到输入条高度时使用 140 逻辑像素预留，避免首帧蒙版压住输入区。

2. **iOS：切换键盘按钮很难点到**  
   已做：44pt 最小触控区、`HitTestBehavior.opaque`、焦点操作延后到下一帧，减少与系统手势/IME 竞争。

3. **选图返回后键盘不回来**  
   逻辑为：跳转选图前若有焦点则先 unfocus，返回后仅 `requestFocus()` 恢复，不在返回时再做 unfocus。

---

## 许可证

本项目采用 **publish_to: 'none'**，仅作代码分享使用。若需在项目中使用或二次开发，请遵守仓库所标许可证（若有）。

---

## 贡献

欢迎提 Issue 与 Pull Request（功能建议、Bug 反馈、文档与示例改进等）。

---

## 上传到 GitHub 前准备

按下面清单检查后再推送，可避免常见问题。

### 必须项

1. **确认 `.gitignore` 已生效**  
   根目录已有 `.gitignore`，确保以下内容**不会被提交**：
   - `/build/`
   - `.dart_tool/`
   - `*.iml`、`.idea/`
   - `pubspec.lock` 是否提交可自定（提交则别人 `flutter pub get` 版本一致；不提交则更灵活）

2. **检查敏感信息**  
   - 全局搜索 `api_key`、`secret`、密码、token、个人路径等，不要提交到仓库。
   - 若有 `*.env` 或本地配置，应加入 `.gitignore`。

3. **确认资源与依赖**  
   - `pubspec.yaml` 里 `assets` 已包含 `assets/icons/`，且仓库中确实存在 `assets/icons/` 下的 `image.png`、`at.png`、`phiz.png`、`keyboard.png`。
   - 在项目根目录执行 `flutter pub get` 能成功，无红字。

4. **保留 `publish_to: 'none'`**  
   若仅做 GitHub 分享、不发布到 pub.dev，请保留 `pubspec.yaml` 中的 `publish_to: 'none'`。

### 可选项

5. **LICENSE 文件**  
   在仓库根目录添加 `LICENSE`（如 MIT、Apache 2.0），方便他人使用与二次开发。可在 GitHub 新建仓库时选择“Add a license”。

6. **Podfile.lock（iOS）**  
   `ios/Podfile.lock` 一般**建议提交**，便于他人 `flutter run` 时 CocoaPods 版本一致，减少环境差异。

7. **仓库描述与标签**  
   在 GitHub 仓库的 About 里写一句简介（如：Flutter 评论/聊天输入键盘，支持表情、多图、双键盘切换），并加上标签如 `flutter`、`keyboard`、`comment`、`emoji` 等，便于搜索。

### 建议首次推送前本地自检

```bash
# 在项目根目录
flutter clean
flutter pub get
flutter run
# 在真机或模拟器上点一遍：输入、切换表情、选图、发送、蒙版收起
```

确认无报错、无敏感信息、README 中的用法与当前代码一致后，再执行：


