//! 鸿蒙宿主的系统 locale 与 CJK 字体来源。
//!
//! 已核对上游 `deckcraft` commit `c4674f24`（workspace 0.15.0）：
//! - `crates/ui-egui/src` 下没有 `craft_i18n` / `sys_locale` / `set_system_locales` /
//!   `*_LANGUAGE` 之类的语言环境变量读取，界面字符串是英文源码字面量。因此本文件
//!   **不**伪造 `DECKCRAFT_LANGUAGE` 之类的上游接口；设置 `LANG`/`LC_ALL` 只是为了
//!   让依赖树里读 POSIX locale 的 crate（`chrono` 等）拿到系统区域。
//! - 界面字体由 `crates/ui-egui/src/app/frame.rs::ui_setup` 调用
//!   `theme::install_fonts_with(ctx, &self.ui_fonts.faces)` 安装，`uifonts::UiFonts::faces`
//!   是公开的追加字体入口。宿主把鸿蒙系统 CJK 面做成 `FontFace` 追加进去，
//!   上游每次 `set_fonts` 都会带上它（见 `native/rust/src/lib.rs` 的 `install_cjk_face`）。
//! - `crates/fonts/build.rs` 的 `CRAFT_FONTS_DIR` 是**编译期**输入，未设置时
//!   `CRAFT_FONTS` 为空，界面退回 egui 自带字体；运行时 `system_font_dirs()` 在
//!   `target_os = "linux"`（含 OHOS）分支扫 `$HOME/.fonts` 等固定目录，鸿蒙沙箱里没有。

use std::path::Path;

const SYSTEM_FONTS: &str = "/system/fonts";

/// 系统 locale 的 BCP-47 形式（`zh_CN` → `zh-CN`）。缺失时退回 `language`。
fn system_tag(locale: &str, language: &str) -> Option<String> {
    let tag = [locale, language].into_iter().map(str::trim).find(|tag| !tag.is_empty())?;
    Some(tag.chars().map(|c| if c == '_' { '-' } else { c }).collect())
}

/// 按系统区域挑 CJK 字体面；鸿蒙没有日/韩专用面，非繁体一律用 SC。
fn cjk_face(tag: &str) -> &'static str {
    if tag.starts_with("zh-TW") || tag.starts_with("zh-HK") || tag.starts_with("zh-Hant") {
        "HarmonyOS_Sans_TC.ttf"
    } else {
        "HarmonyOS_Sans_SC.ttf"
    }
}

/// 在 `dc_init` 里、任何 UI 建立之前调用一次。
pub fn install(files_dir: &str, locale: &str, language: &str) {
    if let Some(tag) = system_tag(locale, language) {
        // sys-locale 按 LANGUAGE → LC_ALL → LC_MESSAGES → LANG 取值；先清掉可能残留的
        // 高优先级变量，再统一写 LANG（与桌面 Linux 用法一致）。
        for key in ["LANGUAGE", "LC_ALL", "LC_MESSAGES"] {
            std::env::remove_var(key);
        }
        std::env::set_var("LANG", &tag);
        log::info!("locale: LANG={tag}");
    }
    // FontDb::global() 的 system_font_dirs() 读 HOME；指向应用沙箱可让字体扫描限定在
    // 可写目录内，避免扫到沙箱外的系统路径（GridCraft 实测这些路径在鸿蒙不可用）。
    let prior_home = std::env::var_os("HOME").map(|s| s.to_string_lossy().into_owned());
    std::env::set_var("HOME", files_dir);
    log::info!("locale: prior HOME={prior_home:?} -> now {files_dir}");
}

/// 读取鸿蒙系统 CJK 字体字节；由 `lib.rs` 转成 `FontFace` 注入上游。
/// 文件不存在时返回 `None`，宿主只记诊断日志、不阻塞首帧。
pub fn cjk_font_bytes(locale: &str, language: &str) -> Option<Vec<u8>> {
    let tag = system_tag(locale, language).unwrap_or_default();
    let face = cjk_face(&tag);
    let path = Path::new(SYSTEM_FONTS).join(face);
    match std::fs::read(&path) {
        Ok(bytes) if !bytes.is_empty() => {
            log::info!("locale: CJK face {} -> {} bytes", path.display(), bytes.len());
            Some(bytes)
        }
        Ok(_) => {
            log::warn!("locale: CJK face {} is empty", path.display());
            None
        }
        Err(error) => {
            log::warn!("locale: cannot read {}: {error}", path.display());
            None
        }
    }
}
