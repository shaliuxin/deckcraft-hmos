# DeckCraft（HarmonyOS 移植工程）

把 [DeckCraft](https://github.com/storytold/deckcraft)（纯 Rust 的演示文稿 / 幻灯片编辑器）
移植到 HarmonyOS，产出 DevEco Studio 工程与可签名的 `.hap`。

- **上游**：`storytold/deckcraft`，对齐 commit `c4674f24fb11eda1cdb440253c88fac686cbbafe`，
  其 `[workspace.package] version` 为 `0.15.0`（`Cargo.toml`）。
- **方法**：复用 `wordcraft-hmos` 的三层架构蓝本，并按
  `craft-鸿蒙移植通用检查清单.md` 中 PhotoCraft / GridCraft / VectorCraft 的实测经验改名与补缝；
  除下述**一处 3 行的占位符提示钩子**（由幂等脚本管理、可一键还原）外，上游源码零改动，
  所有鸿蒙逻辑都在独立的 `native/rust` 适配层 workspace 内。
- **应用名与版本**：显示名 `DeckCraft`（不带平台后缀）；
  `versionName = 0.15.0`、`versionCode = 1500`（`0×10000 + 15×100 + 0`）。
- **专属包名**：`io.github.shaliuxin.deckcraft.hmos`，不复用任何其它 craft 项目的
  bundleName / 签名 profile。

> 一句话定位：通过 **ArkTS → C++ N-API → Rust 适配层** 三层桥接，用 wgpu 的 GLES 后端
> 把 egui 直接画在鸿蒙 `NativeWindow` 上，不经 eframe / winit。

---

## 架构

```
ArkTS (UIAbility + XComponent)
   │  N-API: init / input / reply / open / drop / dropFile / active / close / command
   ▼
C++ N-API 桥 (entry/src/main/cpp/bridge.cpp) → 链接 libdeckcraft_hmos.a
   │
   ▼
Rust 适配层 (native/rust, staticlib "deckcraft_hmos", path 依赖上游 crate)
   │
   ▼
deckcraft-ui-egui (SlideApp) + deckcraft-engine + deckcraft-fonts
   + egui / egui-wgpu 0.37 + wgpu 30 (gles, vendored wgpu-hal 30.0.1)
```

上游 `SlideApp` 已原生暴露宿主缝，宿主按桌面 `apps/deckcraft/src/main.rs` 的顺序调用：

1. `deckcraft_ui_egui::install_ime_pass_hooks(&ctx)`（首个 `run_ui` 之前）；
2. `SlideApp::new(Session::new(), services)`；
3. 每帧 `raw_input_hook(ctx, raw)` → `logic(ctx)` → `ui(ui)`。

FFI 前缀 `dc_`（13 个 Rust 导出）：`dc_init / dc_input / dc_reply / dc_open / dc_drop /
dc_drop_file / dc_command / dc_attach / dc_resize / dc_detach / dc_frame / dc_active /
dc_close`；C++ 侧另提供 `dc_hilog`、`dc_request_vsync`、`dc_set_window_color_space`。

---

## 关键适配点

| 主题 | 做法 |
| --- | --- |
| 渲染 | wgpu GLES 后端直接绘制到 `NativeWindow`；vendored `wgpu-hal-30.0.1` 提供鸿蒙所需的 GLES uniform-block 修补。 |
| 双 ABI | `arm64-v8a` + `x86_64`；`CMakeLists.txt`、`scripts/build_native.sh`、`scripts/verify_native.py`、`entry/build-profile.json5` 四处一致。 |
| 设备形态 | ArkTS 上报 `deviceType` / `widthVp`，Rust `form_factor.rs` 映射 Compact / Medium / Expanded。 |
| 文件打开 | ArkTS 把 picker / 系统「打开方式」的授权 URI 复制进沙箱 `.inbox`（用真实文件名），回传**真实路径**；`pick_open` + `read` 按路径工作，`open_into_app` 调 `SlideApp::open_path`。冷启动 `onCreate(want)` 与热启动 `onNewWant(want)` 两条入口都已接线。 |
| 文件保存 | `pick_save` 留空（picker 返回的是 `file://` URI，不能交给 `std::fs`）；`host_save` / `download` 把字节交给 ArkTS，由 `DocumentViewPicker.save` + `fileIo.writeSync` 落盘，成功 / 取消 / 异常三条路径都 `native.reply` 唤醒 Rust worker。 |
| 关闭确认 | 系统标题栏 X 经 `windowWillClose` 拦截并转发 `native.close()`；上游 `SlideApp::logic` 对未保存文档发 `CancelClose` 并弹 quit 对话框，宿主只看 `CancelClose` / `Close` 两个 `ViewportCommand`。 |
| CJK 字体 | 上游 `ui_setup` 用 `install_fonts_with(ctx, &app.ui_fonts.faces)` 安装界面字体；宿主读 `/system/fonts/HarmonyOS_Sans_SC.ttf`（繁体环境用 `_TC`），经 `deckcraft_fonts::FontDb` 注册后追加到 `ui_fonts.faces`，上游每次 `set_fonts` 都带上面。 |
| 中文界面 / 语言自适应 | 上游 0.15.0 无 i18n catalog（约 1,050 条英文字面量）。三处文本入口统一装宿主 translator：① vendored `storytold/egui` fork 的 `RichText::new` / `From<…> for WidgetText`；② `epaint::Fonts::layout_job`（Ribbon 标签、状态栏、工具栏等 `Painter::text` 直接绘制的文本与宽度测量都汇聚于此）；③ 上游 `deckcraft-model` 的 `PhType::prompt()`（画布空占位符提示由独立渲染层画成 glyph，绕过 egui；`scripts/apply_model_prompt_i18n.py` 幂等注入 3 行钩子，是**唯一**上游改动，可用 `--revert` 还原）。`native/rust/src/i18n.rs` 提供 803 条翻译映射（624 精确 + 171 词级 + 8 动态规则）、`AtomicBool` 控制开关。`dc_init` 读 ArkTS 上报的 `language` / `systemLocale`；运行时系统语言变化由 `EntryAbility.onConfigurationUpdate` / `onForeground` 发 `native.command('host.setLocale')`，Rust 翻开关 + `ctx.request_repaint()`，**不重启应用、不重建 Context**。中文软键盘输入经 HarmonyOS `InputMethod` 框架接入（ArkTS 注册输入客户端 → `insertText`/`setComposingText` 转 egui `Event::Ime`，软键盘随文本焦点弹起/收起），详见《移植报告》7.8。 |
| 包名 / 图标 / 版本 | 专属 bundleName；应用图标取自上游 `assets/app-icon/deckcraft-1024.png`（`scripts/make_icon.py` 写入两处 `app_icon.png`）；版本跟随上游 workspace。 |

---

## 目录

```
AppScope/                 app.json5（bundleName / 版本）+ app_icon.png + app_name
entry/                    DevEco 模块
  src/main/cpp/           bridge.cpp / CMakeLists.txt / display_color.h / types/libdeckcraft
  src/main/ets/           EntryAbility.ets / pages/Index.ets / SystemTheme.ets
  src/main/module.json5   deviceTypes / FileOpen skill / UTD 类型
  resources/rawfile/...   utd.json5（.pptx/.ppt/.potx/.ppsx/.deckcraft）
native/rust/              独立适配层 workspace（Cargo.toml + src/*.rs + .cargo/config.toml）
                          src/i18n.rs = 中文翻译表与语言开关；src/locale.rs = locale/CJK 字体
third_party/              vendored wgpu-hal-30.0.1（GLES 修补）+ egui-6d518fc（文本翻译钩子）
scripts/                  build_native.sh / verify_native.py / make_icon.py /
                          make_deckcraft_signing.sh / encrypt_pwd.js / run_on_device.sh /
                          apply_egui_i18n_patch.py（egui/epaint 钩子）/
                          apply_model_prompt_i18n.py（model 占位符钩子，--revert 可还原）/
                          device_smoke.py（真机冒烟）
signing/                  本地签名材料（已被 .gitignore 排除）
```

## 构建

环境：DevEco Studio（`C:\Program Files\Huawei\DevEco Studio`，SDK 26.0.0 / API 26）、
Rust 的 `aarch64-unknown-linux-ohos` 与 `x86_64-unknown-linux-ohos` 目标。

```bash
DEV="/c/Program Files/Huawei/DevEco Studio"
export DEVECO_SDK_HOME="$DEV/sdk"
export JAVA_HOME="$DEV/jbr"
export PATH="$DEV/jbr/bin:$DEV/tools/node:$DEV/tools/hvigor/bin:$PATH"

# 1) 双 ABI Rust 静态库（Windows 需 C:\ohosnative junction，脚本会自动创建）
# 0) 幂等注入上游 model 占位符提示钩子（首次构建前跑一次；--revert 可还原上游）
python scripts/apply_model_prompt_i18n.py
python scripts/apply_egui_i18n_patch.py     # vendored egui fork 的文本钩子

# 1) 双 ABI Rust 静态库
bash scripts/build_native.sh

# 2) hvigor 打包（SignHap 依赖 build-profile.json5 的 material）
"$DEV/tools/node/node.exe" "$DEV/tools/hvigor/bin/hvigorw.js" --mode module \
  -p module=entry@default -p product=default assembleHap --no-daemon

# 3) 校验
python scripts/verify_native.py entry/build/default/outputs/default/entry-default-signed.hap \
  --expected-bundle io.github.shaliuxin.deckcraft.hmos

# 4) 归档（统一交付目录，文件名 = 显示名 + versionName）
cp entry/build/default/outputs/default/entry-default-signed.hap \
   "/c/Users/mingh/OneDrive/HAP/DeckCraft-0.15.0.hap"
md5sum entry/build/default/outputs/default/entry-default-signed.hap \
       "/c/Users/mingh/OneDrive/HAP/DeckCraft-0.15.0.hap"
```

> 最终交付 `DeckCraft-0.15.0.hap`：**85,400,367 B**，MD5 `e9d86fc424a6e7f20a41cf1f39398662`
> （中文界面 + 系统语言自适应版；AGC 自动签名重打包并覆盖归档，字节数 + MD5 + `cmp` 三重一致）。
> 真机 `46G0225429001073`：中文界面、中→英→中运行时切换、Ribbon / 编辑 / 形状 / 放映 /
> 文件打开与保存 / 关闭确认均已实测。详见 `移植报告.md` 第 7 节。

> `DEVECO_SDK_HOME` 必须是这个名字；`PackageHap` 会 `spawn java`，因此 JBR 必须在 PATH 里。
> `hvigor` 解密口令用的是 `storeFile` 同级的 `signing/material/`，换口令要用
> `node scripts/encrypt_pwd.js <password>` 重新生成 hex。

## 签名说明（已完成）

- `scripts/make_deckcraft_signing.sh` 生成本地 CA 链（`issuer=pki_internal`），
  bundle-name 绑定 `io.github.shaliuxin.deckcraft.hmos`，只能让 `SignHap` 通过、验证打包链路。
  实测 `hdc install -r -d` 会被 `9568257 fail to verify pkcs7 file` 拒绝。
- **真机安装必须使用 AGC 调试 profile**：在 DevEco Studio 打开本工程 →
  `File → Project Structure → Signing Configs` 勾选自动签名，让 AGC 为这个新包名签发
  `issuer=app_gallery` 的调试 profile 并回写 `build-profile.json5`，再重新 `assembleHap`。
  本工程已于 2026-11-09 完成这一步：`~/.ohos/config/default_deckcraft-hmos_xP0vG-….{cer,p12,p7b}`，
  profile 内 `"type":"debug"` / `"issuer":"app_gallery"` / `"bundle-name":"io.github.shaliuxin.deckcraft.hmos"`
  / `debug-info.device-ids` 绑定本机 UDID。重打包后 `install bundle successfully`。
- **换 Profile 后必须重打包 + 重新归档**：同版本重编直接覆盖 `OneDrive\HAP\DeckCraft-0.15.0.hap`，
  并复核字节数 + MD5 + `cmp`；旧包里的仍是本地 CA 链，不能当交付物。
  本地未跟踪备份见 `signing/build-profile.local.json5`。

## 真机验证（2026-11-09）

### 中文界面与系统语言自适应

- 中文系统下 Ribbon 标签（文件 / 开始 / 插入 / 绘图 / 设计 / 切换 / 动画 / 幻灯片放映 /
  录制 / 审阅 / 视图）、工具栏、状态栏「第 1 张，共 1 张」、文档名「演示文稿1」、
  画布「单击此处添加标题 / 副标题 / 备注」全部中文，无豆腐块、无布局错位。
- `hilog`：`i18n: locale=zh-hans-cn -> zh-Hans`。
- 系统设置切到 English：**同一应用进程（pid 57140）界面实时变英文**（`File/Home/Insert`、
  `Slide 1 of 1`），日志 `i18n: locale=en-latn-cn -> en` + `zh=false`；切回简体中文后
  日志 `zh=true`，界面恢复中文。全程**未重启应用、未重建 egui Context**。
- 注意：shell 用户 `param set persist.global.language` 会报 `errNum 1001`（SELinux 拒绝），
  语言切换必须走系统设置 UI 或由用户手动完成。

### 中文输入法（IME，2026-11-09 真机通过）

按 HarmonyOS 官方「自定义编辑框」方案接入，顺序不可颠倒：

1. 1×1 透明锚点 `Text('').id('deckcraft-ime-anchor').focusable(true)` 必须先 `requestFocus`；
2. 再 `await inputMethod.getController().attach(true, textConfig)`；
3. **attach 成功之后**才注册 `insertText/setPreviewText/finishTextPreview/deleteLeft/sendFunctionKey` 监听
   （提前注册抛 `12800009 detached`，键盘完全不弹——首版即此错）。

XComponent 已去掉 `.focusOnTouch(true)`，避免点画布抢走锚点焦点。真机实测：点文本框 → `ime: show` →
`IME attached` → `listeners bound` → 悬浮输入法栏 → 点 ⌨ → `aaa` + 拼音「醋嘎哈」→ 画布与缩略图显示
`aaa醋嘎哈`；点空白 → `ime: hide`。

> 该平板处于 PC 多窗口 + 外接物理键盘时，系统不自动展开软键盘面板（系统「备忘录」同样如此），
> 需点右下角悬浮栏的 ⌨ 展开——这是系统策略，应用侧无法强制。

### 功能冒烟（真机）

| 项 | 结果 |
| --- | --- |
| 10 个 Ribbon 标签切换 | 每个标签工具栏内容随之变化，标签全中文 |
| 新建幻灯片 | 缩略图 1 → 2，状态栏「第 2 张，共 2 张」 |
| 文本编辑 + 缩略图同步 | 双击输入 ASCII，画布与缩略图同步；标题栏「演示文稿1 — 已编辑」 |
| 形状面板 / 插入形状 | 弹出线条 / 矩形 / 基本形状分类，插入后画布与缩略图同步 |
| 撤销 | 回退上一次输入 |
| 放映（Presenter View） | 进入演讲者视图，显示当前幻灯片、备注区与中文工具条 |
| 文件 → 打开 → Browse | 拉起 `DocumentViewPicker`，URI 拷贝失败后 decoded path 回退成功，写入沙箱 `.inbox` 并交给 `SlideApp::open_path` |
| 文件 → 另存为 → 保存 | 写出 `Presentation1.pptx`（22,778 B），`DeckCraft save: wrote 22778 bytes` |
| 关闭确认 | 点标题栏 X 被 `windowWillClose` 拦截，弹出未保存更改确认（按钮中文） |

> 截图证据在 `.verify/`：`zh_final2.jpeg`、`lang_en_1.jpeg`、`lang_back_confirm.jpeg`、
> `ribbon_all.jpeg`、`func_*.jpeg`、`close_confirm.jpeg`。


```bash
HDC="$DEV/sdk/default/openharmony/toolchains/hdc.exe"
D=46G0225429001073
B=io.github.shaliuxin.deckcraft.hmos
"$HDC" -t $D install -r -d entry/build/default/outputs/default/entry-default-signed.hap
"$HDC" -t $D shell "aa start -b $B -a EntryAbility -m entry"
"$HDC" -t $D shell "hilog -x | grep -i -E 'DeckCraft|first_frame|present'"
```

实测：Maleoon 916 / GLES 适配器 → `ready` → `first_frame`，EGL present 2002×1268、连续多帧
`shapes=379`，无崩溃；截图（`.verify/ui.jpeg`）显示完整 Ribbon、幻灯片画布、缩略图与状态栏。
`uitest uiInput` 点击标题占位符会选中形状并带出 `Shape Format` 上下文标签，双击进入文本编辑，
输入 `Hello` 后画布与缩略图同步更新。

## 已知限制

| 项 | 说明 |
| --- | --- |
| 界面语言 | 主界面（Ribbon / 工具栏 / 画布占位符 / 状态栏 / 文档名 / 常用按钮 / 退出确认正文与按钮）已中文，624 条精确串 + 171 词级兜底 + 8 动态规则。少数长尾项仍可能英文：backstage 空列表提示、图表/主题色等专业对话框、个别品牌名（SmartArt / Harbor / Ember 等）。中文显示依赖注入的鸿蒙 CJK 面。 |
| 剪贴板 / 音频 / 第二屏 | `Services.clipboard_*` / `audio_out` / `displays` / `presenter` 留空：跨应用剪贴板、媒体播放声音、Presenter View 双屏降级。 |
| 首选项持久化 | 宿主未实现 eframe storage 等价物，设置重启回默认。 |
| 手写笔 / 子窗口 | 触摸 + 鼠标近似；单 XComponent 主窗口。 |
| 中文输入 / CJK 面 | 鸿蒙系统 CJK 字体已注入 `ui_fonts.faces`；软键盘中文合成已按官方「自定义编辑框」方案接通并**真机验证**（`aaa醋嘎哈` 上屏，见上节）。PC 多窗口/外接键盘时系统不自动弹面板，需点悬浮栏 ⌨。 |
| sRGB framebuffer | `egui_wgpu` 提示 `Rgba8UnormSrgb` 为 sRGBA aware framebuffer；真机观感正常，未做色彩校正。 |
| Present / 双屏演示 | `Services.presenter` 留空，Presenter View 与外接屏未接。 |

## 许可与上游

上游 DeckCraft 为 `MIT OR Apache-2.0`（仓库含 `LICENSE-MIT` / `LICENSE-APACHE`）。
本工程原创部分（适配层、C++ 桥、ArkTS、脚本、文档）建议以相同许可标注。

## 参考资料（MLA）

- storytold. *DeckCraft*. GitHub, 2026, github.com/storytold/deckcraft.
- “PhotoCraft 鸿蒙移植经验 → 通用移植检查清单.” *craft-鸿蒙移植通用检查清单.md*,
  本地工作区, 2026.
- “WordCraft 鸿蒙（HarmonyOS）移植报告.” *移植报告.md*, 本地工作区, 2026.
