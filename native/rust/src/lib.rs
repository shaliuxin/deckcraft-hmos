//! 鸿蒙专属 FFI 边界。编辑器与全部演示文稿逻辑保持在安全 Rust 上游。
//!
//! 上游 `deckcraft` 0.15.0 的 `SlideApp` 原生暴露宿主缝
//! `new(Session, Services)` / `logic(ctx)` / `raw_input_hook(ctx, raw)` / `ui(ui)` /
//! `run(id, params)` / `open_path(path)`，故上游文件零改动。调用序对齐桌面宿主
//! `apps/deckcraft/src/main.rs`：`install_ime_pass_hooks(ctx)` → `SlideApp::new` →
//! 每帧 `raw_input_hook` → `logic` → `ui`。纯 egui 渲染，不涉及 3D 视口深度附件。
#![allow(clippy::needless_lifetimes)]
mod appearance;
mod bridge;
mod display_color;
mod file_open;
mod form_factor;
mod i18n;
mod input;
mod locale;
mod render;

use serde::Deserialize;
use deckcraft_ui_egui::{Services, SlideApp};
use deckcraft_fonts::FontDb;
use std::{
    pin::Pin,
    sync::{
        OnceLock,
        mpsc,
        atomic::{AtomicI8, Ordering},
    },
    task::{Context, Poll, Wake, Waker},
    time::{Duration, Instant},
};
use std::sync::Arc;
use std::sync::Mutex;

/// 把 `log` crate 的记录转到 hilog：wgpu-hal 的 EGL 诊断（平台选择 / surface 创建 / swap 失败）
/// 默认没有 logger 就会被丢掉，设备上完全看不见。
#[cfg(target_env = "ohos")]
mod glog {
    use std::ffi::{CString, c_char};

    unsafe extern "C" {
        fn dc_hilog(level: i32, message: *const c_char);
    }

    struct Hilog;

    impl log::Log for Hilog {
        fn enabled(&self, _: &log::Metadata<'_>) -> bool {
            true
        }

        fn log(&self, record: &log::Record<'_>) {
            let level = match record.level() {
                log::Level::Error => 2,
                log::Level::Warn => 1,
                _ => 0,
            };
            let line = format!("[{}] {}: {}", record.level(), record.target(), record.args());
            if let Ok(text) = CString::new(line) {
                // SAFETY: 有效的 NUL 结尾 C 字符串；dc_hilog 只读该指针。
                unsafe { dc_hilog(level, text.as_ptr()) };
            }
        }

        fn flush(&self) {}
    }

    static LOGGER: Hilog = Hilog;

    pub fn install() {
        if log::set_logger(&LOGGER).is_ok() {
            log::set_max_level(log::LevelFilter::Info);
        }
    }
}

#[derive(Deserialize)]
#[allow(dead_code)]
struct Config {
    files: String,
    #[serde(default)]
    documents: String,
    #[serde(default = "default_scale")]
    scale: f32,
    #[serde(default)]
    language: String,
    /// 系统 locale（`zh-Hans-CN` 这类 BCP-47 标签），决定「跟随系统」解析到哪种语言。
    #[serde(default, rename = "systemLocale")]
    system_locale: String,
    #[serde(default, rename = "displayP3")]
    display_p3: bool,
    #[serde(default, rename = "systemTheme")]
    system_theme: String,
    #[serde(default)]
    fullscreen: bool,
    #[serde(default, rename = "deviceType")]
    device_type: String,
    #[serde(default, rename = "widthVp")]
    width_vp: f32,
}
fn default_scale() -> f32 {
    1.
}

#[allow(dead_code)]
enum Message {
    Attach(usize, u32, u32),
    Resize(u32, u32),
    Detach,
    Frame,
    Active(bool),
    Input(input::Input),
    Open(String, Vec<u8>),
    Drop(String, Vec<u8>, f32, f32),
    DropFile(String, std::fs::File, f32, f32),
    Close,
    Wake(Duration),
    Command(String, serde_json::Value),
}

static SEND: OnceLock<mpsc::Sender<Message>> = OnceLock::new();
fn send(message: Message) {
    if let Some(tx) = SEND.get() {
        let _ = tx.send(message);
    }
}

/// 把 ArkTS 上报的系统主题透传给 appearance 模块。
static SYSTEM_THEME_TOKEN: AtomicI8 = AtomicI8::new(0);

/// # Safety
/// `ptr`/`len` 必须在调用期间指向可读内存；调用方保证。
unsafe fn bytes<'a>(ptr: *const u8, len: usize) -> Option<&'a [u8]> {
    if len > isize::MAX as usize || (ptr.is_null() && len != 0) {
        return None;
    }
    if len == 0 {
        return Some(&[]);
    }
    Some(unsafe { std::slice::from_raw_parts(ptr, len) })
}

fn copy_bytes(data: &[u8]) -> Result<Vec<u8>, String> {
    let mut bytes = Vec::new();
    bytes
        .try_reserve_exact(data.len())
        .map_err(|e| format!("Not enough memory to open file: {e}"))?;
    bytes.extend_from_slice(data);
    Ok(bytes)
}

fn write_temp_file(dir: &str, name: &str, bytes: &[u8]) -> std::io::Result<String> {
    let stamp = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_nanos())
        .unwrap_or(0);
    let safe: String = name
        .chars()
        .map(|c| if c.is_alphanumeric() || c == '.' || c == '-' || c == '_' { c } else { '_' })
        .collect();
    let path = std::path::Path::new(dir).join(format!("{stamp}_{safe}"));
    std::fs::write(&path, bytes)?;
    Ok(path.to_string_lossy().into_owned())
}

// ===================== FFI 导出（C++ 边界调用） =====================

/// # Safety
/// 指针/长度对必须指向可读内存直到本调用返回；notify 回调在进程生命周期内保持有效。
#[unsafe(no_mangle)]
pub unsafe extern "C" fn dc_init(ptr: *const u8, len: usize, notify: bridge::Notify) -> bool {
    let Some(data) = (unsafe { bytes(ptr, len) }) else {
        return false;
    };
    let Ok(config) = serde_json::from_slice::<Config>(data) else {
        return false;
    };
    if !config.scale.is_finite() || config.scale <= 0. || config.scale > 8. {
        return false;
    }
    bridge::init(notify);
    #[cfg(target_env = "ohos")]
    glog::install();
    // 上游 0.15.0 无 i18n 层：POSIX locale / HOME 供依赖 crate 读取；
    // 中文界面由宿主安装的 egui WidgetText 翻译钩子提供，按系统语言在启动时决定是否启用。
    locale::install(&config.files, &config.system_locale, &config.language);
    i18n::install();
    i18n::set_locale(&config.system_locale, &config.language);
    if !config.system_theme.is_empty() {
        let dark = config.system_theme.eq_ignore_ascii_case("dark");
        SYSTEM_THEME_TOKEN.store(if dark { 1 } else { -1 }, Ordering::Release);
        appearance::set_dark(dark);
    }
    let (tx, rx) = mpsc::channel();
    if SEND.set(tx).is_err() {
        return true;
    }
    std::thread::Builder::new()
        .name("deckcraft-native".into())
        .spawn(move || {
            if std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| worker(config, rx)))
                .is_err()
            {
                bridge::notify(0, "error", "Native host initialization failed", &[]);
            }
        })
        .is_ok()
}

/// # Safety
/// 指针/长度对必须可读直到返回。
#[unsafe(no_mangle)]
pub unsafe extern "C" fn dc_input(ptr: *const u8, len: usize) {
    let Some(data) = (unsafe { bytes(ptr, len) }) else { return; };
    let Ok(value) = serde_json::from_slice(data) else { return; };
    send(Message::Input(value));
}

/// # Safety
/// 同 `dc_init`。
#[unsafe(no_mangle)]
pub unsafe extern "C" fn dc_reply(
    id: u64,
    ok: bool,
    text: *const u8,
    text_len: usize,
    data: *const u8,
    len: usize,
) {
    let Some(text) = (unsafe { bytes(text, text_len) }) else {
        bridge::reply(id, Err("Invalid reply text buffer".into()));
        return;
    };
    let Some(data) = (unsafe { bytes(data, len) }) else {
        bridge::reply(id, Err("Invalid reply data buffer".into()));
        return;
    };
    let text = String::from_utf8_lossy(text).into_owned();
    bridge::reply(
        id,
        if ok {
            copy_bytes(data).map(|data| (text, data))
        } else {
            Err(text)
        },
    );
}

/// # Safety
/// 指针/长度对必须可读直到返回。
#[unsafe(no_mangle)]
pub unsafe extern "C" fn dc_open(text: *const u8, n: usize, data: *const u8, len: usize) {
    if let (Some(text), Some(data)) = (unsafe { bytes(text, n) }, unsafe { bytes(data, len) }) {
        match copy_bytes(data) {
            Ok(data) => send(Message::Open(String::from_utf8_lossy(text).into_owned(), data)),
            Err(error) => bridge::notify(0, "error", &error, &[]),
        }
    }
}

/// # Safety
/// 指针/长度对必须可读直到返回。
#[unsafe(no_mangle)]
pub unsafe extern "C" fn dc_drop(
    text: *const u8,
    n: usize,
    data: *const u8,
    len: usize,
    x: f32,
    y: f32,
) {
    if !x.is_finite() || !y.is_finite() {
        return;
    }
    if let (Some(text), Some(data)) = (unsafe { bytes(text, n) }, unsafe { bytes(data, len) }) {
        send(Message::Drop(
            String::from_utf8_lossy(text).into_owned(),
            data.to_vec(),
            x,
            y,
        ));
    }
}

/// # Safety
/// `text`/`n` 必须可读且 `fd` 打开直到返回。
#[unsafe(no_mangle)]
pub unsafe extern "C" fn dc_drop_file(text: *const u8, n: usize, fd: i32, x: f32, y: f32) {
    if !x.is_finite() || !y.is_finite() {
        return;
    }
    let Some(text) = (unsafe { bytes(text, n) }) else {
        return;
    };
    match unsafe { file_open::duplicate(fd) } {
        Ok(file) => send(Message::DropFile(
            String::from_utf8_lossy(text).into_owned(),
            file,
            x,
            y,
        )),
        Err(error) => bridge::notify(0, "error", &error, &[]),
    }
}

/// # Safety
/// `ptr`/`len` 为自由文本命令标识。
#[unsafe(no_mangle)]
pub unsafe extern "C" fn dc_command(ptr: *const u8, len: usize) {
    let Some(data) = (unsafe { bytes(ptr, len) }) else { return; };
    let Ok(v) = serde_json::from_slice::<serde_json::Value>(data) else { return; };
    let Some(id) = v.get("id").and_then(|v| v.as_str()) else { return; };
    send(Message::Command(
        id.into(),
        v.get("params").cloned().unwrap_or_default(),
    ));
}

/// # Safety
/// `window` 必须是存活的 OHNativeWindow，且已获取一个原生引用；该引用所有权转移给 worker 及其 wgpu surface。
#[unsafe(no_mangle)]
pub unsafe extern "C" fn dc_attach(window: usize, w: u32, h: u32) {
    if window != 0 {
        send(Message::Attach(window, w, h));
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn dc_resize(w: u32, h: u32) {
    send(Message::Resize(w, h));
}

#[unsafe(no_mangle)]
pub extern "C" fn dc_detach() {
    bridge::cancel();
    send(Message::Detach);
}

#[unsafe(no_mangle)]
pub extern "C" fn dc_frame() {
    send(Message::Frame);
}

#[unsafe(no_mangle)]
pub extern "C" fn dc_active(active: bool) {
    send(Message::Active(active));
}

#[unsafe(no_mangle)]
pub extern "C" fn dc_close() {
    send(Message::Close);
}

// ===================== 仅 OHOS 宿主逻辑 =====================

#[cfg(target_env = "ohos")]
unsafe extern "C" {
    fn dc_request_vsync();
}

/// 把鸿蒙系统 CJK 面注册进上游字体库，并追加到 `SlideApp.ui_fonts.faces`。
/// 上游 `theme::add_fallback_faces` 会把该面追加到每个字体族链尾，最低优先级兜底。
#[cfg(target_env = "ohos")]
fn install_cjk_face(app: &mut SlideApp, locale: &str, language: &str) {
    let Some(bytes) = locale::cjk_font_bytes(locale, language) else {
        bridge::notify(0, "diagnostic", "no system CJK font found", &[]);
        return;
    };
    let expected_len = bytes.len();
    let db = FontDb::global();
    let added = db.add_font(bytes);
    let face = db.fallback_for_filtered('文', u32::MAX, |f: &deckcraft_fonts::FontFace| f.data().len() == expected_len);
    match face {
        Some(face) => {
            app.ui_fonts.faces.push(face);
            log::info!("[dc] CJK fallback installed (new faces={added}, {expected_len} bytes)");
            bridge::notify(0, "diagnostic", "CJK font injected into ui_fonts.faces", &[]);
        }
        None => {
            log::warn!("[dc] CJK face loaded ({added} new) but no matching fallback was returned");
            bridge::notify(0, "diagnostic", "CJK fallback lookup failed", &[]);
        }
    }
}

#[cfg(target_env = "ohos")]
fn worker(config: Config, rx: mpsc::Receiver<Message>) {
    bridge::notify(0, "stage", "Rust worker entered", &[]);
    let ctx = egui::Context::default();
    // 与上游桌面宿主一致：在首个 run_ui 之前安装 IME pass hooks。
    deckcraft_ui_egui::install_ime_pass_hooks(&ctx);
    let form = form_factor::Form::new(&config.device_type, config.width_vp);
    bridge::notify(
        0,
        "diagnostic",
        &format!(
            "form factor {:?}, {:.0} vp, {:?}",
            form.device_type, form.width_vp, form.width_class
        ),
        &[],
    );

    // 上游桌面宿主用 `Session::new()`（空 session + 起始页）。鸿蒙首屏建一份空白演示文稿，
    // 便于触摸设备立刻进入 ribbon / 画布；失败则保留上游起始页，不阻塞启动。
    let mut session = deckcraft_engine::Session::new();
    match session.execute("file.new", &serde_json::Value::Null) {
        Ok(_) => log::info!("[dc] blank presentation created"),
        Err(error) => log::warn!("[dc] file.new failed, keeping start screen: {error}"),
    }
    let mut app = SlideApp::new(session, services(&config.files));
    // 上游 `ui_setup` 用 `install_fonts_with(ctx, &app.ui_fonts.faces)` 安装界面字体；
    // 把鸿蒙系统 CJK 面追加进去，中文幻灯片文本才不会显示成方块。
    install_cjk_face(&mut app, &config.system_locale, &config.language);
    bridge::notify(0, "stage", "editor ready", &[]);

    // 起始逻辑帧（无用户输入）：让 app 在宿主登记后先跑一次 logic。
    let _ = ctx.run_logic(&egui::RawInput::default(), |ctx| app.logic(ctx));

    let mut render = match render::Render::new(config.display_p3) {
        Ok(render) => render,
        Err(error) => {
            bridge::notify(0, "error", &error, &[]);
            return;
        }
    };
    let mut active = true;
    let mut visible = false;
    let mut deadline: Option<Instant> = None;
    let started = Instant::now();
    let mut events: Vec<egui::Event> = Vec::new();
    let mut input_state = input::State::default();
    let mut close = false;
    // 软键盘是否已由宿主弹起：避免每帧重复 attach/hide，仅在 egui 文本焦点变化时切换。
    let mut ime_shown = false;

    ctx.set_request_repaint_callback(|info| send(Message::Wake(info.delay)));
    bridge::notify(0, "ready", "Native host initialized", &[]);

    loop {
        let wait = deadline.map(|d| d.saturating_duration_since(Instant::now()));
        let message = match wait {
            Some(wait) => match rx.recv_timeout(wait) {
                Ok(m) => m,
                Err(mpsc::RecvTimeoutError::Timeout) => {
                    deadline = None;
                    if active && visible && render.attached() {
                        unsafe { dc_request_vsync() };
                    }
                    continue;
                }
                Err(_) => break,
            },
            None => match rx.recv() {
                Ok(m) => m,
                Err(_) => break,
            },
        };
        let result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(
            || -> Result<(), String> {
                match message {
                    Message::Attach(ptr, w, h) => {
                        visible = w > 0 && h > 0;
                        render.bind(render::Window(ptr), w, h)?;
                        bridge::resume();
                        deadline = Some(Instant::now());
                        // 重连后重置软键盘状态，下一帧按实际焦点重新评估显隐。
                        ime_shown = false;
                        bridge::notify(0, "ready", "Native egui / wgpu GLES", &[]);
                    }
                    Message::Resize(w, h) => {
                        visible = w > 0 && h > 0;
                        render.resize(w, h)?;
                        deadline = Some(Instant::now());
                    }
                    Message::Detach => {
                        visible = false;
                        deadline = None;
                        render.detach();
                        input_state.cancel(&mut events);
                        // 表面销毁时收起软键盘并重置状态，避免重连后状态错乱。
                        ime_shown = false;
                        bridge::notify(0, "ime", "hide", &[]);
                    }
                    Message::Active(value) => {
                        active = value;
                        if active {
                            bridge::resume();
                            deadline = Some(Instant::now());
                        } else {
                            deadline = None;
                            input_state.cancel(&mut events);
                        }
                    }
                    Message::Input(value) => {
                        if value.kind == "system_theme" {
                            let dark = value.text.eq_ignore_ascii_case("dark");
                            appearance::set_dark(dark);
                            deadline = Some(Instant::now());
                            return Ok(());
                        }
                        input_state.push(value, config.scale, &mut events);
                        deadline = Some(Instant::now());
                    }
                    Message::Open(name, data) => {
                        if let Ok(path) = write_temp_file(&config.files, &name, &data) {
                            open_into_app(&mut app, &path);
                        }
                        deadline = Some(Instant::now());
                    }
                    Message::Drop(name, data, _x, _y) => {
                        if let Ok(path) = write_temp_file(&config.files, &name, &data) {
                            open_into_app(&mut app, &path);
                        }
                        deadline = Some(Instant::now());
                    }
                    Message::DropFile(name, file, _x, _y) => {
                        match file_open::read(file) {
                            Ok(data) => {
                                if let Ok(path) = write_temp_file(&config.files, &name, &data) {
                                    open_into_app(&mut app, &path);
                                }
                            }
                            Err(e) => bridge::notify(0, "error", &e, &[]),
                        }
                        deadline = Some(Instant::now());
                    }
                    Message::Close => {
                        bridge::resume();
                        close = true;
                        deadline = Some(Instant::now());
                    }
                    Message::Wake(delay) => {
                        if active && visible {
                            if let Some(next) = Instant::now().checked_add(delay) {
                                deadline = Some(deadline.map_or(next, |d| d.min(next)));
                            }
                        }
                    }
                    Message::Command(id, params) => {
                        // 系统语言在运行时变化时，ArkTS 走 command 通道通知宿主。
                        // 这不是上游命令，不能交给 app.run；改语言标志后请求重绘即可。
                        if id == "host.setLocale" {
                            let locale = params.get("locale").and_then(|v| v.as_str()).unwrap_or("");
                            let language = params.get("language").and_then(|v| v.as_str()).unwrap_or("");
                            i18n::set_locale(locale, language);
                            ctx.request_repaint();
                            bridge::notify(
                                0,
                                "i18n",
                                &format!("locale={locale} language={language} zh={}", i18n::active()),
                                &[],
                            );
                        } else {
                            let result = app.run(&id, params);
                            bridge::notify(
                                0,
                                "command",
                                &format!("{id}: {result:?}"),
                                &[],
                            );
                        }
                        deadline = Some(Instant::now());
                    }
                    Message::Frame => {
                        if !active || !visible {
                            return Ok(());
                        }
                        if !render.attached() {
                            return Ok(());
                        }
                        let size = egui::vec2(
                            render.width as f32 / config.scale,
                            render.height as f32 / config.scale,
                        );
                        let mut raw = egui::RawInput {
                            screen_rect: Some(egui::Rect::from_min_size(egui::Pos2::ZERO, size)),
                            time: Some(started.elapsed().as_secs_f64()),
                            events: std::mem::take(&mut events),
                            system_theme: appearance::current(),
                            ..Default::default()
                        };
                        let viewport = raw.viewports.entry(egui::ViewportId::ROOT).or_default();
                        viewport.native_pixels_per_point = Some(config.scale);
                        viewport.inner_rect = raw.screen_rect;
                        viewport.focused = Some(true);
                        let validating_close = close;
                        if close {
                            viewport.events.push(egui::ViewportEvent::Close);
                            close = false;
                        }
                        // 上游桌面宿主顺序：raw_input_hook(ctx, raw) 先于 logic / ui。
                        app.raw_input_hook(&ctx, &mut raw);
                        let output = editor_frame(&ctx, &mut app, raw);
                        for command in &output.platform_output.commands {
                            if let egui::OutputCommand::OpenUrl(url) = command {
                                bridge::notify(0, "url", &url.url, &[]);
                            }
                        }
                        // 软键盘随文本焦点自动弹起/收起：egui 在有文本字段获得焦点时把
                        // `platform_output.ime` 置为 Some（含该字段的 Id / 几何信息），
                        // 宿主据此调用系统输入法框架显隐软键盘。
                        let ime_wanted = output.platform_output.ime.is_some();
                        if ime_wanted != ime_shown {
                            ime_shown = ime_wanted;
                            bridge::notify(0, "ime", if ime_wanted { "show" } else { "hide" }, &[]);
                        }
                        let mut commands = Vec::new();
                        let mut repaint_delay: Option<Duration> = None;
                        if let Some(v) = output.viewport_output.get(&egui::ViewportId::ROOT) {
                            commands.extend(v.commands.clone());
                            repaint_delay = Some(v.repaint_delay);
                        }
                        match close_action(validating_close, &commands) {
                            CloseAction::Confirm => bridge::notify(0, "close", "", &[]),
                            CloseAction::Request => {
                                close = true;
                                deadline = Some(Instant::now());
                            }
                            CloseAction::Cancel | CloseAction::None => {}
                        }
                        let painted = render.paint(&ctx, output)?;
                        if first_frame_marker(painted) {
                            bridge::notify(0, "first_frame", "Native UI presented", &[]);
                        }
                        // 按 egui 的 `repaint_delay` 排下一帧：视口在动时它是 0（连续重绘），
                        // 静止时是一个很大的值或 MAX（等输入/vsync 唤醒），避免空转耗电。
                        if painted && active && visible && render.attached() {
                            deadline = match repaint_delay {
                                Some(delay) if delay.is_zero() => Some(Instant::now()),
                                Some(delay) if delay < Duration::from_secs(3600) => {
                                    Some(Instant::now() + delay)
                                }
                                _ => None,
                            };
                        }
                    }
                }
                Ok(())
            },
        ));
        let _ = result;
    }
}

#[cfg(target_env = "ohos")]
#[allow(dead_code)]
fn first_frame_marker(painted: bool) -> bool {
    use std::sync::atomic::{AtomicBool, Ordering};
    static FIRST: AtomicBool = AtomicBool::new(false);
    if painted && !FIRST.swap(true, Ordering::AcqRel) {
        true
    } else {
        false
    }
}

#[cfg(target_env = "ohos")]
fn editor_frame(
    ctx: &egui::Context,
    app: &mut SlideApp,
    raw: egui::RawInput,
) -> egui::FullOutput {
    // 与上游宿主一致：每个 pass 的首拍都推进一次 `logic`（内含逐帧 tick），随后把 `ui`
    // 画进 CentralPanel。只跑首帧会让界面停摆。
    ctx.run_ui(raw, |ui| {
        if ui.ctx().current_pass_index() == 0 {
            app.logic(ui.ctx());
        }
        app.ui(ui);
    })
}

#[cfg(target_env = "ohos")]
#[derive(Debug, PartialEq, Eq)]
enum CloseAction {
    None,
    Request,
    Cancel,
    Confirm,
}

/// DeckCraft 自管未保存文档：`SlideApp::logic` 在有脏文档时发 `CancelClose` 并弹 quit 对话框，
/// 用户确认后 `dialogs/body.rs` 发 `ViewportCommand::Close`。宿主只看这两个命令。
#[cfg(target_env = "ohos")]
fn close_action(validating: bool, commands: &[egui::ViewportCommand]) -> CloseAction {
    if commands.contains(&egui::ViewportCommand::CancelClose) {
        CloseAction::Cancel
    } else if validating {
        CloseAction::Confirm
    } else if commands.contains(&egui::ViewportCommand::Close) {
        CloseAction::Request
    } else {
        CloseAction::None
    }
}

/// 文件服务契约（逐字段核对上游 `crates/ui-egui/src/services.rs`）：
/// - open：ArkTS 把 picker / want 的授权文件复制进沙箱 `.inbox`，回传**真实路径**；
///   `pick_open` 与 `read` 都按该路径工作，`open_path_in_background` 直接 `std::fs` 读。
/// - save：`pick_save` 留空（picker 返回 `file://` URI，不能交给 `std::fs` 写）；
///   `host_save` / `download` 把字节交给 ArkTS，由 `DocumentViewPicker.save` + `fileIo` 落盘。
/// - clipboard / audio_out / displays / presenter：鸿蒙首版留空，降级项记入移植报告。
#[cfg(target_env = "ohos")]
fn services(files: &str) -> Services {
    let mut s = Services::default();
    let files = files.to_string();
    s.pick_open = Some(Box::new({
        let files = files.clone();
        move |_purpose: &str| file_picker("open", &files)
    }));
    s.read = Some(Box::new(|path: &str| std::fs::read(path).map_err(|e| e.to_string())));
    s.write = Some(Box::new(|path: &str, bytes: &[u8]| {
        std::fs::write(path, bytes).map_err(|e| e.to_string())
    }));
    // 让上游的 export / save_as_dialog 走 download 分支（pick_save 为 None 时）。
    s.download = Some(Box::new(|name: &str, bytes: &[u8]| {
        match bridge::request("download", name, bytes) {
            Ok(_) => (),
            Err(error) => log::warn!("[dc] download failed: {error}"),
        }
    }));
    // 普通 Save / Save As 走 host_save(name, bytes, save_as)；ArkTS 弹 picker 后写盘。
    s.host_save = Some(Box::new(|name: &str, bytes: &[u8], _save_as: bool| {
        bridge::request("hostsave", name, bytes).map(|_| ()).map_err(|error| {
            log::warn!("[dc] host_save failed: {error}");
            error
        })
    }));
    s
}

/// 把落沙箱的文件路径交给上游 `SlideApp::open_path`（同步读；大文件后台路径由
/// `pick_and_open` 自己走 `open_path_in_background`）。失败只记日志、不中断帧循环。
#[cfg(target_env = "ohos")]
fn open_into_app(app: &mut SlideApp, path: &str) {
    match app.open_path(path) {
        Ok(_) => log::info!("[dc] open_path ok: {path}"),
        Err(e) => log::warn!("[dc] open_path failed for {path}: {e}"),
    }
}

/// 文件选择器：在独立线程里同步向 ArkTS 请求文件，拿到沙箱路径后交给上游 open/save 逻辑。
#[cfg(target_env = "ohos")]
fn file_picker(kind: &str, text: &str) -> Option<String> {
    struct Inner {
        value: Mutex<Option<Option<String>>>,
        waker: Mutex<Option<Waker>>,
    }
    impl Wake for Inner {
        fn wake(self: Arc<Self>) {
            if let Some(w) = self.waker.lock().unwrap().take() {
                w.wake();
            }
        }
    }
    struct Answer {
        inner: Arc<Inner>,
    }
    impl std::future::Future for Answer {
        type Output = Option<String>;
        fn poll(self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<Self::Output> {
            if let Some(v) = self.inner.value.lock().unwrap().take() {
                return Poll::Ready(v);
            }
            *self.inner.waker.lock().unwrap() = Some(cx.waker().clone());
            Poll::Pending
        }
    }
    let inner = Arc::new(Inner {
        value: Mutex::new(None),
        waker: Mutex::new(None),
    });
    let answer = Answer { inner: inner.clone() };
    let kind = kind.to_string();
    let text = text.to_string();
    let join = std::thread::spawn(move || {
        log::info!("[dc] file_picker request kind={kind} text={text:?}");
        let path = match bridge::request(&kind, &text, &[]) {
            // ArkTS 已在沙箱准备好文件；直接把回传路径交给上游 open/save 逻辑。
            Ok((name, _bytes)) if !name.is_empty() => Some(name),
            Ok((name, _bytes)) => {
                log::warn!("[dc] file_picker kind={kind} returned an empty name (len={})", name.len());
                None
            }
            Err(e) => {
                // 用户在系统选择器点「取消」时，ArkTS 以 "cancelled" 回传（个别设备/版本可能是
                // "The user canceled" 之类带 cancel 字样）——这是正常流程，不是错误：只返回 None
                // （deckcraft 视为取消），切勿 notify error，否则 ArkTS 会弹「原生运行错误」框。
                let lower = e.to_ascii_lowercase();
                if lower == "cancelled" || lower.contains("cancel") {
                    log::info!("[dc] file_picker kind={kind} cancelled by user ({e})");
                } else {
                    log::warn!("[dc] file_picker kind={kind} failed: {e}");
                    bridge::notify(0, "error", &e, &[]);
                }
                None
            }
        };
        log::info!("[dc] file_picker kind={kind} resolved path={path:?}");
        *inner.value.lock().unwrap() = Some(path);
        Arc::clone(&inner).wake();
    });
    // Answer 在 worker 写入 inner.value 时即就绪，其 Output 已是 Option<String>，
    // 直接阻塞取回路径；再 join worker 线程确保其退出（清理）。
    let path = pollster::block_on(answer);
    let _ = join.join();
    path
}

#[cfg(not(target_env = "ohos"))]
fn worker(_config: Config, _rx: mpsc::Receiver<Message>) {
    bridge::notify(0, "error", "Native host requires an OHOS target", &[]);
}
