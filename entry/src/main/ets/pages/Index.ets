import native from 'libdeckcraft.so';
import { common } from '@kit.AbilityKit';
import { fileIo, fileUri, picker } from '@kit.CoreFileKit';
import { i18n } from '@kit.LocalizationKit';
import { BusinessError, deviceInfo } from '@kit.BasicServicesKit';
import { display } from '@kit.ArkUI';
import { inputMethod } from '@kit.IMEKit';
import { SYSTEM_THEME_DARK, SYSTEM_THEME_LIGHT } from '../SystemTheme';

// Mirrors the Rust `Config` deserialized in native/rust/src/lib.rs.
class NativeConfig {
  files: string;
  documents: string;
  scale: number;
  language: string;
  systemLocale: string;
  displayP3: boolean;
  systemTheme: string;
  fullscreen: boolean;
  deviceType: string;
  widthVp: number;
  constructor(files: string, documents: string, scale: number, language: string, systemLocale: string,
              displayP3: boolean, systemTheme: string, fullscreen: boolean, deviceType: string, widthVp: number) {
    this.files = files;
    this.documents = documents;
    this.scale = scale;
    this.language = language;
    this.systemLocale = systemLocale;
    this.displayP3 = displayP3;
    this.systemTheme = systemTheme;
    this.fullscreen = fullscreen;
    this.deviceType = deviceType;
    this.widthVp = widthVp;
  }
}

/**
 * 系统语言的完整 BCP-47 标签（如 `zh-Hans-CN`）：Rust 侧据此挑选注入的 CJK 字体面，
 * 并写入 LANG 供依赖 crate 读取（上游 0.15.0 无 UI i18n，界面字符串为英文）。
 * getSystemLocale 在个别设备上可能不可用，退回只带语言的 getSystemLanguage。
 */
function systemLocaleTag(): string {
  try {
    const locale = i18n.System.getSystemLocale();
    if (locale && locale.length > 0) {
      return locale;
    }
  } catch (error) {
    console.info(`System locale unavailable: ${(error as Error).message}`);
  }
  return i18n.System.getSystemLanguage();
}

/**
 * 对文件名或 file:// URI 里的百分号（%xx）解码，得到真实可读名（如 文档1）。
 * deckcraft 用回传路径的末段（file_stem）作文档标题，若不先解码，标题/信息页/最近列表
 * 会显示原始百分号串（%E6%96%87…）。
 * - 含 `://`（完整 URI）：只解码各路径段，保留 scheme 与分隔符。
 * - 其余（裸文件名）：整体解码。
 * 解码失败则原样返回，绝不影响原值。
 */
function percentDecodeName(s: string): string {
  if (!s || s.length === 0) { return s; }
  try {
    if (s.includes('://')) {
      const parts = s.split('/');
      for (let i = 1; i < parts.length; i++) { parts[i] = decodeURIComponent(parts[i]); }
      return parts.join('/');
    }
    return decodeURIComponent(s);
  } catch (error) {
    return s;
  }
}

/**
 * 把 file:// URI 各路径段重新百分号编码（保留 scheme 与分隔符），用于把「解码后的名」
 * 还原成 picker 原始 URI 形式，供 fileIo.openSync 打开写入（兜底：若解码形式打不开则用此）。
 */
function percentEncodePath(uri: string): string {
  try {
    const parts = uri.split('/');
    for (let i = 1; i < parts.length; i++) { parts[i] = encodeURIComponent(parts[i]); }
    return parts.join('/');
  } catch (error) {
    return uri;
  }
}

class NativeMessage { kind: string = ''; text: string = ''; }

@Entry
@Component
struct Index {
  @State private failure: string = '';
  @State private initialized: boolean = false;
  @State private startupVisible: boolean = true;
  @State private startupOpacity: number = 1;
  private alive: boolean = false;
  private generation: number = 0;
  private context: common.UIAbilityContext = this.getUIContext().getHostContext() as common.UIAbilityContext;
  @State private deviceScale: number = 1;
  // 中文输入法：鸿蒙软键盘走 InputMethod 框架。官方「自定义编辑框」方案要求先有一个
  // 获得焦点的 ArkUI 组件作为编辑代理（XComponent 原生表面的焦点不被输入法框架认可），
  // 再 attach 绑定输入法；组合/确认文本经框架回调回传 Rust 转成 egui 的 IME 事件。
  private imeController: inputMethod.InputMethodController | undefined = undefined;
  private imeAttached: boolean = false;
  private imeShown: boolean = false;
  private imeInComposition: boolean = false;
  // 事件监听器只在 attach 成功后注册一次（未附加时注册会抛 12800009）。
  private imeBound: boolean = false;
  // Rust 侧最近一次请求的软键盘状态（show/hide），用于锚点失焦等异常后判断是否需要重连。
  private imeWanted: boolean = false;
  // 热启动的「打开方式」URI 由 onNewWant 写入 AppStorage；页面必须订阅才会收到。
  @StorageLink('deckcraftOpenWant') @Watch('onOpenWantChange') wantUri: string = '';

  private onOpenWantChange(): void {
    if (this.wantUri && this.wantUri.length > 0) {
      const uri = this.wantUri;
      AppStorage.setOrCreate('deckcraftOpenWant', '');
      this.openWant(uri);
    }
  }

  aboutToAppear(): void {
    console.info('DeckCraft native page appearing');
    this.alive = true;
    this.generation++;
    this.initializeHost(this.generation);
    // 启动兜底：遮罩盖在 XComponent 之上，若首帧通知因任何原因没到，它会永久遮住原生画面
    // （表现为满屏漆黑）。到点必须揭开。
    setTimeout((): void => { this.hideStartup(); }, 4000);
  }

  aboutToDisappear(): void {
    this.alive = false;
    this.generation++;
    this.initialized = false;
    native.active(false);
  }

  private async initializeHost(generation: number): Promise<void> {
    try {
      let scale: number = this.getUIContext().vp2px(1);
      this.deviceScale = scale;
      let systemTheme = AppStorage.get<string>('deckcraftSystemTheme') ?? '';
      if (systemTheme !== SYSTEM_THEME_DARK && systemTheme !== SYSTEM_THEME_LIGHT) {
        systemTheme = '';
      }
      const filesDir = this.context.filesDir;
      const documents = filesDir + '/Documents';
      try { fileIo.mkdirSync(documents, true); } catch (e) { /* exists */ }
      native.init(JSON.stringify(new NativeConfig(
          filesDir, documents, scale, i18n.System.getSystemLanguage(), systemLocaleTag(), false, systemTheme,
          false, deviceInfo.deviceType, this.getUIContext().px2vp(display.getDefaultDisplaySync().width))),
        (id: number, message: string, data: ArrayBuffer): void => { this.receive(id, message, data); });
      this.initialized = true;
      this.failure = '';
      // A file launched from the system shares its URI through onNewWant.
      const want = AppStorage.get<string>('deckcraftOpenWant');
      if (want && want.length > 0) {
        AppStorage.setOrCreate('deckcraftOpenWant', '');
        this.openWant(want);
      }
    } catch (error) {
      if (this.alive && generation === this.generation) { this.failure = (error as Error).message; }
    }
  }

  private openWant(uri: string): void {
    try {
      // picker / want 给的是 URI 级临时读授权：优先用原始 URI 打开，失败再回退解码路径。
      const path = new fileUri.FileUri(uri).path;
      const name = percentDecodeName(path.length > 0 ? path.substring(path.lastIndexOf('/') + 1) : 'presentation.pptx');
      let bytes: ArrayBuffer;
      try {
        const file = fileIo.openSync(uri, fileIo.OpenMode.READ_ONLY);
        bytes = this.readAll(file.fd);
        fileIo.closeSync(file);
      } catch (uriErr) {
        console.warn('DeckCraft open want: URI open failed, trying decoded path');
        const file = fileIo.openSync(path, fileIo.OpenMode.READ_ONLY);
        bytes = this.readAll(file.fd);
        fileIo.closeSync(file);
      }
      native.open(name, bytes);
    } catch (error) {
      console.error(`DeckCraft open want failed: ${(error as Error).message}`);
    }
  }

  private readAll(fd: number): ArrayBuffer {
    const chunks: ArrayBuffer[] = [];
    let total = 0;
    const bufSize = 1024 * 1024;
    while (true) {
      const buf = new ArrayBuffer(bufSize);
      const n = fileIo.readSync(fd, buf);
      if (n <= 0) { break; }
      chunks.push(n === bufSize ? buf : buf.slice(0, n));
      total += n;
    }
    const out = new Uint8Array(total);
    let offset = 0;
    for (const c of chunks) {
      out.set(new Uint8Array(c), offset);
      offset += c.byteLength;
    }
    return out.buffer;
  }

  private receive(id: number, message: string, data: ArrayBuffer): void {
    const request = JSON.parse(message) as NativeMessage;
    console.info(`DeckCraft native ${request.kind}: ${request.text}`);
    if (!this.alive) {
      if (id > 0) { native.reply(id, false, 'cancelled', new ArrayBuffer(0)); }
      return;
    }
    if (request.kind === 'error') {
      this.failure = request.text;
    } else if (request.kind === 'ready' || request.kind === 'first_frame') {
      this.failure = '';
      if (request.kind === 'first_frame') { this.revealEditor(); }
    } else if (request.kind === 'close') {
      this.context.terminateSelf();
    } else if (request.kind === 'url') {
      this.context.startAbility({ action: 'ohos.want.action.viewData', uri: request.text })
        .catch((error: BusinessError) => { console.error(`External link: ${error.message}`); });
    } else if (request.kind === 'open' || request.kind === 'file') {
      this.pickDocument(id, false);
    } else if (request.kind === 'save') {
      this.pickSave(id, request.text);
    } else if (request.kind === 'hostsave' || request.kind === 'download') {
      // 上游 host_save / download 传的是「建议文件名 + 字节」，不是可写 URI：
      // 鸿蒙必须自己弹 DocumentViewPicker.save 取得授权 URI 再写盘。
      this.saveBytes(id, request.text, data);
    } else if (request.kind === 'ime') {
      // Rust 通知：egui 文本字段获得/失去焦点 → 弹起/收起软键盘。
      this.setImeKeyboard(request.text === 'show');
    }
  }

  // ===================== 中文输入法（IME） =====================
  // 鸿蒙软键盘中文输入法走 InputMethod 框架，不经 XComponent 原始按键事件。
  // 文本字段获焦时（Rust 通知 "ime":"show"）先让锚点组件获焦再 attach 绑起软键盘；
  // 组合文本 / 确认文本经框架回调回传 Rust，转成 egui 的 IME 事件以正确合成中文。
  // 关键顺序（实测）：监听器必须在 attach() 成功之后注册，未附加时注册会抛
  // 12800009「input method client detached. need to be attached first」。

  private controller(): inputMethod.InputMethodController | undefined {
    if (this.imeController) {
      return this.imeController;
    }
    try {
      const controller: inputMethod.InputMethodController = inputMethod.getController();
      this.imeController = controller;
      return controller;
    } catch (error) {
      console.error(`DeckCraft IME controller failed: ${(error as Error).message}`);
      return undefined;
    }
  }

  /**
   * attach 成功之后安装一次输入法事件监听（监听器挂在 controller 上，detach/attach 后可复用）：
   *   insertText         = 已确认上屏的文本（中文候选/字母）
   *   setPreviewText     = 拼音组合态（text 即当前组合串；空串表示清除组合）
   *   finishTextPreview  = 组合结束
   *   deleteLeft         = 退格（组合态内由键盘经 setPreviewText 自行处理，这里仅非组合时转发）
   *   sendFunctionKey    = 回车 / 功能键
   *   sendKeyboardStatus = 键盘显隐状态
   */
  private bindImeListeners(controller: inputMethod.InputMethodController): void {
    if (this.imeBound) {
      return;
    }
    try {
      controller.on('insertText', (text: string): void => { this.sendIme('commit', text); });
      controller.on('setPreviewText', (text: string, _range: inputMethod.Range): void => {
        this.imeInComposition = (text.length > 0);
        this.sendIme('preedit', text);
      });
      controller.on('finishTextPreview', (): void => { this.imeInComposition = false; this.sendIme('preedit', ''); });
      controller.on('deleteLeft', (length: number): void => {
        // 组合态内退格由键盘经 setPreviewText 处理，不要重复删 egui 已提交文本。
        if (!this.imeInComposition) { this.sendIme('delete', String(length)); }
      });
      controller.on('sendFunctionKey', (_key: inputMethod.FunctionKey): void => { this.sendIme('enter', ''); });
      controller.on('sendKeyboardStatus', (status: inputMethod.KeyboardStatus): void => {
        this.imeShown = (status === inputMethod.KeyboardStatus.SHOW);
      });
      this.imeBound = true;
      console.info('DeckCraft IME listeners bound');
    } catch (error) {
      console.warn(`DeckCraft IME bind failed: ${(error as Error).message}`);
    }
  }

  private async setImeKeyboard(show: boolean): Promise<void> {
    if (!this.alive) {
      return;
    }
    this.imeWanted = show;
    const controller = this.controller();
    if (!controller) {
      return;
    }
    if (show) {
      // 官方自定义编辑框调用序（developer.huawei.com use-inputmethod-in-custom-edit-box）：
      // 1) 先让锚点组件获得焦点——系统由此判断「这是可输入文本的位置」；
      // 2) 再 attach 绑定输入法，showKeyboard=true 拉起软键盘；
      // 3) attach 成功后才注册事件监听。
      // 缺少第 1 步时 attach 报 12800003（编辑框未获焦），键盘不弹。
      // 注意：showSoftKeyboard/hideSoftKeyboard 是系统应用专用（需 CONNECT_IME_ABILITY 权限，
      // 普通应用调用抛 201），显隐必须走公开的 attach / showTextInput / hideTextInput / detach。
      try {
        this.getUIContext().getFocusController().requestFocus('deckcraft-ime-anchor');
      } catch (error) {
        console.warn(`DeckCraft IME anchor focus failed: ${(error as Error).message}`);
      }
      try {
        await controller.attach(true, this.imeTextConfig());
        this.imeAttached = true;
        this.imeShown = true;
        console.info('DeckCraft IME attached');
      } catch (error) {
        console.warn(`DeckCraft IME attach failed: ${(error as Error).message}`);
        // 兜底：仍处绑定态（重复 attach 场景）时显式请求拉起键盘。
        try {
          await controller.showTextInput(inputMethod.RequestKeyboardReason.OTHER);
          this.imeAttached = true;
          this.imeShown = true;
        } catch (e2) {
          console.warn(`DeckCraft IME show failed: ${(e2 as Error).message}`);
        }
      }
      if (this.imeAttached) {
        // attach(true) 在 PC 多窗口/外接键盘模式下可能只弹「输入法悬浮工具栏」而不展开
        // 键盘面板；再显式以 TOUCH 原因请求一次，强制展开软键盘。
        try {
          await controller.showTextInput(inputMethod.RequestKeyboardReason.TOUCH);
        } catch (error) {
          console.warn(`DeckCraft IME showTextInput failed: ${(error as Error).message}`);
        }
        this.bindImeListeners(controller);
      }
    } else {
      this.imeInComposition = false;
      try {
        if (this.imeAttached) {
          await controller.hideTextInput();
        }
      } catch (error) {
        console.warn(`DeckCraft IME hide failed: ${(error as Error).message}`);
      }
      try {
        if (this.imeAttached) {
          await controller.detach();
        }
      } catch (error) {
        // 未绑定 / 重复 detach：忽略。
      }
      this.imeAttached = false;
      this.imeShown = false;
    }
  }

  private imeTextConfig(): inputMethod.TextConfig {
    return {
      inputAttribute: {
        textInputType: inputMethod.TextInputType.TEXT,
        enterKeyType: inputMethod.EnterKeyType.NEWLINE,
        consumeKeyEvents: true,
      },
    };
  }

  private sendIme(op: string, text: string): void {
    if (!this.alive) {
      return;
    }
    native.input(JSON.stringify({ kind: 'ime', op, text }));
  }

  private async pickDocument(id: number, _gallery: boolean): Promise<void> {
    const generation = this.generation;
    try {
      const uris = await new picker.DocumentViewPicker(this.context).select(new picker.DocumentSelectOptions());
      if (!this.alive || generation !== this.generation || uris.length === 0) {
        console.info(`DeckCraft pick open: cancelled (alive=${this.alive} gen ${generation}!=${this.generation} n=${uris.length})`);
        native.reply(id, false, 'cancelled', new ArrayBuffer(0));
        return;
      }
      const uriStr = uris[0];
      const info = new fileUri.FileUri(uriStr);
      // 文件名先解码，落沙箱的临时名与 deckcraft 显示的文档名都应是真实可读名（而非 %xx 串）。
      const baseName = percentDecodeName(info.name || uriStr.substring(uriStr.lastIndexOf('/') + 1) || 'document');
      console.info(`DeckCraft pick open: uri=${uriStr} path=${info.path} name=${baseName}`);

      // 把 picker 授权的文件复制进沙箱 .inbox，Rust 侧再用 std::fs 按路径读取。
      // 关键：fileIo.copyFileSync 原生支持 picker 返回的 file:// URI（含非 ASCII 名），
      // 直接完成 URI→沙箱复制；不要自己 open+writeSync 循环——writeSync 的 buffer 参数
      // 必须是 ArrayBuffer/string，传 Uint8Array 视图会触发 "Invalid arraybuffer or options"。
      const inbox = this.context.filesDir + '/.inbox';
      try {
        fileIo.mkdirSync(inbox, true);
      } catch (e) {
        // 目录已存在。
      }
      // 用真实文件名：加时间戳前缀会污染文档标题（GridCraft 实测）。
      const dst = inbox + '/' + baseName;
      try { fileIo.unlinkSync(dst); } catch (e) { /* not present */ }
      try {
        fileIo.copyFileSync(uriStr, dst);
      } catch (uriErr) {
        // 极少数情况下按 URI 复制失败，退回用解码后的真实路径复制。
        console.warn(`DeckCraft pick open: copySync by URI failed (${(uriErr as Error).message}); trying decoded path`);
        fileIo.copyFileSync(info.path, dst);
      }
      const size = fileIo.statSync(dst).size;
      console.info(`DeckCraft pick open: copied ${size} bytes -> ${dst}`);
      // 把沙箱路径回传给 Rust（open/file 读此路径，save 写此路径）。
      native.reply(id, true, dst, new ArrayBuffer(0));
    } catch (error) {
      const err = error as Error;
      console.error(`DeckCraft pick open FAILED: ${err.message}\n${err.stack ?? ''}`);
      native.reply(id, false, String(err.message ?? error), new ArrayBuffer(0));
    }
  }

  // 另存为：弹系统保存位置选择器（DocumentViewPicker.save），把用户选的 file:// URI 回传上游作为
  // 「保存路径」；真正写盘由 hostsave（上游 host_save）经该 URI + fd 完成——OHOS 沙箱外位置只能经
  // picker 授权 URI 访问，Rust std::fs 写不了，故走 host_save。
  private async pickSave(id: number, suggested: string): Promise<void> {
    const generation = this.generation;
    try {
      if (!this.alive || generation !== this.generation) {
        native.reply(id, false, 'cancelled', new ArrayBuffer(0));
        return;
      }
      const suggestedName = suggested.length > 0 ? suggested : 'Presentation.pptx';
      const options = new picker.DocumentSaveOptions();
      options.newFileNames = [suggestedName];
      const uris = await new picker.DocumentViewPicker(this.context).save(options);
      if (!this.alive || generation !== this.generation || !uris || uris.length === 0) {
        console.info(`DeckCraft save: picker cancelled (alive=${this.alive} n=${uris ? uris.length : 0})`);
        native.reply(id, false, 'cancelled', new ArrayBuffer(0));
        return;
      }
      const uri = uris[0];
      // 回传解码后的名：deckcraft 用末段作标题/落盘名，解码后即为真实文件名（文档1 而非 %E6%96%87…）。
      // 真正的写入由 hostsave 完成，writeSave 会先按此 URI 打开、打不开再回退到编码形式。
      const name = percentDecodeName(uri);
      console.info(`DeckCraft save: picker -> ${uri} (name=${name})`);
      native.reply(id, true, name, new ArrayBuffer(0));
    } catch (error) {
      const err = error as Error;
      console.error(`DeckCraft save picker FAILED: ${err.message}`);
      native.reply(id, false, String(err.message ?? error), new ArrayBuffer(0));
    }
  }

  // 上游保存/导出：弹系统保存选择器，把字节写进用户所选的授权 URI。
  // Rust worker 阻塞等 native.reply，故成功、取消、异常三条路径都必须回包。
  private async saveBytes(id: number, suggested: string, bytes: ArrayBuffer): Promise<void> {
    try {
      const name = suggested && suggested.length > 0 ? suggested : 'Presentation.pptx';
      const options = new picker.DocumentSaveOptions();
      options.newFileNames = [name];
      const uris = await new picker.DocumentViewPicker(this.context).save(options);
      if (!this.alive || !uris || uris.length === 0) {
        console.info('DeckCraft save: picker cancelled');
        native.reply(id, false, 'cancelled', new ArrayBuffer(0));
        return;
      }
      const uri = uris[0];
      const file = fileIo.openSync(uri, fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
      try {
        fileIo.writeSync(file.fd, bytes ?? new ArrayBuffer(0));
      } finally {
        fileIo.closeSync(file);
      }
      console.info(`DeckCraft save: wrote ${bytes?.byteLength ?? 0} bytes -> ${uri}`);
      native.reply(id, true, uri, new ArrayBuffer(0));
    } catch (error) {
      const message = String((error as Error).message ?? error);
      console.error(`DeckCraft save FAILED: ${message}`);
      native.reply(id, false, message, new ArrayBuffer(0));
    }
  }

  // 兼容路径：picker 先把保存位置回传给 Rust（首版 pick_save 未启用，保留备用）。
  // host_save 落盘：把字节写到 picker 授权的 URI（沙箱外位置）。ArrayBuffer 恰为字节长度（见 C++ CallJS）。
  private writeSave(id: number, uri: string, bytes: ArrayBuffer): void {
    if (!uri || uri.length === 0) {
      native.reply(id, false, 'no save target uri', new ArrayBuffer(0));
      return;
    }
    // pickSave 回传的是「解码后的名」（便于 deckcraft 正确显示标题/落盘名）。写入时优先按此 URI 打开；
    // 若系统 fileIo 要求 picker 原始的百分号形式，则回退到编码形式重试——两条都试，保证写盘成功。
    const targets: string[] = [uri];
    const enc = percentEncodePath(uri);
    if (enc !== uri) { targets.push(enc); }
    let lastErr = '';
    for (const target of targets) {
      try {
        const file = fileIo.openSync(target, fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
        try {
          fileIo.writeSync(file.fd, bytes);
        } finally {
          fileIo.closeSync(file);
        }
        console.info(`DeckCraft save: wrote ${bytes.byteLength} bytes -> ${target}`);
        native.reply(id, true, target, new ArrayBuffer(0));
        return;
      } catch (error) {
        lastErr = String((error as Error).message ?? error);
        console.warn(`DeckCraft save write: openSync failed for ${target}: ${lastErr}`);
      }
    }
    console.error(`DeckCraft save write FAILED: ${lastErr}`);
    native.reply(id, false, lastErr, new ArrayBuffer(0));
  }

  private hideStartup(): void {
    if (!this.alive || !this.startupVisible) { return; }
    this.startupOpacity = 0;
    this.startupVisible = false;
  }

  private revealEditor(): void {
    if (!this.startupVisible) { return; }
    // 遮罩必须无条件消失：动画在任何环节失败都不能把原生画面永久盖住。
    try {
      this.getUIContext().animateTo({ duration: 320, curve: Curve.EaseOut, onFinish: (): void => this.hideStartup() },
        (): void => { this.startupOpacity = 0; });
    } catch (error) {
      console.warn(`Reveal animation failed: ${(error as Error).message}`);
      this.hideStartup();
    }
    // 兜底：动画若被系统丢弃（回调线程/丢帧），首帧之后必须让原生画面露出来。
    setTimeout((): void => this.hideStartup(), 600);
  }

  build() {
    Stack() {
      if (this.initialized) {
        XComponent({ id: 'deckcraft-native', type: XComponentType.SURFACE, libraryname: 'deckcraft' })
          .width('100%').height('100%')
          .onLoad((): void => {
            try { this.getUIContext().getFocusController().requestFocus('deckcraft-editor'); } catch (e) {}
          })
          // 不设 focusOnTouch：打字期间点击画布若把焦点抢回 XComponent（非编辑代理），
          // 会断开输入法绑定导致键盘收起；触摸/指针事件不经 ArkUI 焦点，不受影响。
          .id('deckcraft-editor').focusable(true).defaultFocus(true)
      }
      // 隐藏的 IME 锚点：鸿蒙输入法框架只认「获得焦点的编辑组件」为可输入位置。
      // 官方自定义编辑框方案用普通 Text + focusControl.requestFocus 即可充当编辑代理，
      // attach 前必须先聚焦它，否则软键盘不弹。1×1 全透明且不参与命中测试，用户不可见。
      Text('')
        .id('deckcraft-ime-anchor')
        .focusable(true)
        .width(1).height(1)
        .opacity(0)
        .hitTestBehavior(HitTestMode.None)
        .onBlur((): void => {
          // 焦点被系统弹窗等夺走时绑定失效：重置状态，Rust 下一次 ime 请求会重新聚焦+attach。
          if (this.imeAttached) {
            this.imeAttached = false;
            this.imeShown = false;
            console.info('DeckCraft IME anchor blurred, binding reset');
          }
        })
      if (this.startupVisible) {
        Column() {
          Column({ space: 18 }) {
            Image($r('app.media.app_icon')).width(76).height(76).borderRadius(18)
            Text('DeckCraft').fontSize(30).fontWeight(FontWeight.Medium).fontColor('#F4F4F5')
            Row({ space: 10 }) {
              LoadingProgress().width(18).height(18).color('#A5BFFF')
              Text(this.initialized ? '正在启动编辑器…' : '正在准备文档目录…')
                .fontSize(14).fontColor('#B8BAC2')
            }
          }
        }
        .width('100%').height('100%').justifyContent(FlexAlign.Center)
        .backgroundColor('#10203F').opacity(this.startupOpacity)
        .hitTestBehavior(HitTestMode.Block)
      }
      if (this.failure.length > 0) {
        Column() {
          Text('DeckCraft 原生运行错误').fontSize(20).fontColor('#FFFFFF')
          Text(this.failure).fontSize(14).fontColor('#FFFFFF').margin({ top: 12 })
          if (!this.initialized) {
            Button('重试').onClick((): void => { this.failure = ''; this.initializeHost(this.generation); })
          } else {
            Button('关闭提示').onClick((): void => { this.failure = ''; })
          }
        }.padding(24).backgroundColor('#DD262626').borderRadius(8).width('80%')
      }
    }.width('100%').height('100%').backgroundColor('#262626')
  }
}
