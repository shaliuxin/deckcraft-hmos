#!/usr/bin/env python3
"""Patch the vendored storytold/egui fork with a host-installed UI text translator.

DeckCraft 0.15.0 has no i18n catalog: ~1,050 English UI literals are spread over
117 files in `crates/ui-egui/src` plus the engine command specs. Rather than
patching the upstream application crate (which would break the "upstream sources
untouched" rule), we hook the two choke points every visible string passes:

 1. `egui::RichText::new` / `From<…> for WidgetText` — all label/button/menu/
    tooltip/command-label widgets built through egui's widget API.
 2. `epaint::Fonts::layout_job` — the one place ALL text layout converges,
    including `Painter::text` / `layout_no_wrap` used by DeckCraft's Ribbon tabs,
    status bar, custom toolbar buttons and canvas placeholder text (those never
    construct a WidgetText). Both measurement and painting go through it, so
    Chinese strings also get correct widths.

The translator lives in `epaint` (the lowest common layer); `egui::i18n`
re-exports it so the host only calls `egui::i18n::install_translator`. The host
installs `fn(&str) -> Option<String>` once at startup and switches languages at
runtime with an atomic flag inside it. Re-running this script is idempotent.

Also rewrites `[patch.crates-io]` in `native/rust/Cargo.toml` so the whole egui
crate family resolves to this vendored tree (a single path source keeps all
`epaint`/`egui` types identical across crate boundaries).
"""

from __future__ import annotations

import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parents[1]
FORK = ROOT / "third_party" / "egui-6d518fc"
EGUI_SRC = FORK / "crates" / "egui" / "src"
EPAINT_SRC = FORK / "crates" / "epaint" / "src"
CARGO = ROOT / "native" / "rust" / "Cargo.toml"

EPAINT_I18N_RS = """//! Host-installed UI text translator (HarmonyOS DeckCraft port).
//!
//! Upstream DeckCraft 0.15.0 has no string catalog: every interface string is an
//! English literal. The host installs a translator here, and every text layout
//! passes through it. `Fonts::layout_job` is the single choke point for both
//! `Painter::text` (Ribbon tabs, status bar, canvas placeholders) and widget
//! text, so translating here also fixes width measurement of Chinese labels.
//!
//! The translator is installed exactly once. Runtime language switching is done
//! inside the host translator (an atomic flag), so no re-registration is needed.

use std::sync::OnceLock;

use crate::text::{ByteRange, ByteRangeExt, LayoutJob};

/// A translator returns `Some(translated)` when it wants to replace `text`,
/// or `None` to leave the original text alone (the common, zero-allocation path).
pub type Translator = fn(&str) -> Option<String>;

static TRANSLATOR: OnceLock<Translator> = OnceLock::new();

/// Install the host translator. The first install wins; later calls are ignored.
pub fn install_translator(translator: Translator) {
    let _ = TRANSLATOR.set(translator);
}

#[inline]
pub fn translate(text: &str) -> Option<String> {
    TRANSLATOR.get().and_then(|f| f(text))
}

/// Translate a layout job in place, before it is cached or rasterized.
///
/// Only single-section jobs covering the whole text are rewritten; rich
/// multi-section jobs keep their byte ranges intact (their pieces were already
/// translated by `egui::WidgetText`/`RichText`).
pub fn translate_job(job: &mut LayoutJob) {
    let Some(translated) = translate(&job.text) else {
        return;
    };
    if job.sections.len() != 1 {
        return;
    }
    job.text = translated;
    job.sections[0].byte_range = <ByteRange as ByteRangeExt>::full(&job.text);
}
"""

EGUI_I18N_RS = """//! Host-installed UI text translator (HarmonyOS DeckCraft port).
//!
//! The shared translator state lives in `epaint` so that text drawn directly via
//! `Painter::text` (which never builds a `WidgetText`) is translated too.
//! `egui::i18n` re-exports it for the host and for `widget_text.rs`.

pub use epaint::i18n::{Translator, install_translator, translate};
"""

WIDGET_PAIRS: list[tuple[str, str]] = [
    (
        """impl RichText {
    #[inline]
    pub fn new(text: impl Into<String>) -> Self {
        Self {
            text: text.into(),
            ..Default::default()
        }
    }
""",
        """impl RichText {
    #[inline]
    pub fn new(text: impl Into<String>) -> Self {
        let text = text.into();
        let text = crate::i18n::translate(&text).unwrap_or(text);
        Self {
            text,
            ..Default::default()
        }
    }
""",
    ),
    (
        """impl From<&str> for WidgetText {
    #[inline]
    fn from(text: &str) -> Self {
        Self::Text(text.to_owned())
    }
}
""",
        """impl From<&str> for WidgetText {
    #[inline]
    fn from(text: &str) -> Self {
        Self::Text(crate::i18n::translate(text).unwrap_or_else(|| text.to_owned()))
    }
}
""",
    ),
    (
        """impl From<&String> for WidgetText {
    #[inline]
    fn from(text: &String) -> Self {
        Self::Text(text.clone())
    }
}
""",
        """impl From<&String> for WidgetText {
    #[inline]
    fn from(text: &String) -> Self {
        Self::Text(crate::i18n::translate(text.as_str()).unwrap_or_else(|| text.clone()))
    }
}
""",
    ),
    (
        """impl From<String> for WidgetText {
    #[inline]
    fn from(text: String) -> Self {
        Self::Text(text)
    }
}
""",
        """impl From<String> for WidgetText {
    #[inline]
    fn from(text: String) -> Self {
        Self::Text(crate::i18n::translate(&text).unwrap_or(text))
    }
}
""",
    ),
    (
        """impl From<&Box<str>> for WidgetText {
    #[inline]
    fn from(text: &Box<str>) -> Self {
        Self::Text(text.to_string())
    }
}
""",
        """impl From<&Box<str>> for WidgetText {
    #[inline]
    fn from(text: &Box<str>) -> Self {
        Self::Text(crate::i18n::translate(text.as_ref()).unwrap_or_else(|| text.to_string()))
    }
}
""",
    ),
    (
        """impl From<Box<str>> for WidgetText {
    #[inline]
    fn from(text: Box<str>) -> Self {
        Self::Text(text.into())
    }
}
""",
        """impl From<Box<str>> for WidgetText {
    #[inline]
    fn from(text: Box<str>) -> Self {
        let text: String = text.into();
        Self::Text(crate::i18n::translate(&text).unwrap_or(text))
    }
}
""",
    ),
    (
        """impl From<Cow<'_, str>> for WidgetText {
    #[inline]
    fn from(text: Cow<'_, str>) -> Self {
        Self::Text(text.into_owned())
    }
}
""",
        """impl From<Cow<'_, str>> for WidgetText {
    #[inline]
    fn from(text: Cow<'_, str>) -> Self {
        let text = text.into_owned();
        Self::Text(crate::i18n::translate(&text).unwrap_or(text))
    }
}
""",
    ),
]

LAYOUT_JOB_OLD = """    pub fn layout_job(&mut self, job: LayoutJob) -> Arc<Galley> {
        *self.used_since_begin_pass = true;
"""
LAYOUT_JOB_NEW = """    pub fn layout_job(&mut self, mut job: LayoutJob) -> Arc<Galley> {
        *self.used_since_begin_pass = true;
        // HarmonyOS port: translate UI text at the single layout choke point.
        crate::i18n::translate_job(&mut job);
"""


def patch_fork() -> None:
    if not EGUI_SRC.is_dir() or not EPAINT_SRC.is_dir():
        sys.exit(f"missing vendored egui/epaint fork: {FORK}")

    # 1. Translator state in epaint (lowest common layer).
    (EPAINT_SRC / "i18n.rs").write_text(EPAINT_I18N_RS, encoding="utf-8")
    epaint_lib = EPAINT_SRC / "lib.rs"
    src = epaint_lib.read_text(encoding="utf-8")
    if "pub mod i18n;" not in src:
        marker = "pub mod text;"
        if src.count(marker) != 1:
            sys.exit("cannot locate `pub mod text;` in epaint/lib.rs")
        src = src.replace(
            marker,
            marker + "\n/// Host-installed UI text translator (HarmonyOS port).\npub mod i18n;",
        )
        epaint_lib.write_text(src, encoding="utf-8")

    fonts = EPAINT_SRC / "text" / "fonts.rs"
    src = fonts.read_text(encoding="utf-8")
    if "crate::i18n::translate_job" not in src:
        if src.count(LAYOUT_JOB_OLD) != 1:
            sys.exit("Fonts::layout_job anchor mismatch")
        fonts.write_text(src.replace(LAYOUT_JOB_OLD, LAYOUT_JOB_NEW), encoding="utf-8")

    # 2. egui re-export + WidgetText/RichText hooks.
    (EGUI_SRC / "i18n.rs").write_text(EGUI_I18N_RS, encoding="utf-8")
    lib = EGUI_SRC / "lib.rs"
    src = lib.read_text(encoding="utf-8")
    if "pub mod i18n;" not in src:
        marker = "pub mod widget_text;"
        if src.count(marker) != 1:
            sys.exit("cannot locate `pub mod widget_text;` in egui/lib.rs")
        lib.write_text(
            src.replace(
                marker,
                marker + "\n/// Host-installed UI text translator (HarmonyOS port).\npub mod i18n;",
            ),
            encoding="utf-8",
        )

    widget = EGUI_SRC / "widget_text.rs"
    src = widget.read_text(encoding="utf-8")
    if "crate::i18n::translate" not in src:
        for old, new in WIDGET_PAIRS:
            if src.count(old) != 1:
                sys.exit(f"widget_text.rs anchor mismatch: {old.splitlines()[0]}")
            src = src.replace(old, new)
        widget.write_text(src, encoding="utf-8")
    print(f"egui/epaint fork patched: {FORK}")


def patch_cargo() -> None:
    lines = CARGO.read_text(encoding="utf-8").splitlines()
    out: list[str] = []
    changed = 0
    pattern = re.compile(
        r'^(\s*)([A-Za-z0-9_-]+)\s*=\s*\{ git = "https://github\.com/storytold/egui\.git", rev = "[^"]+" \}'
    )
    for line in lines:
        m = pattern.match(line)
        if not m:
            out.append(line)
            continue
        name = m.group(2)
        target = FORK / "crates" / name
        if not target.is_dir():
            sys.exit(f"egui fork has no crate {name} ({target})")
        out.append(
            f'{m.group(1)}{name} = {{ path = "../../third_party/egui-6d518fc/crates/{name}" }}'
        )
        changed += 1
    CARGO.write_text("\n".join(out) + "\n", encoding="utf-8")
    print(f"Cargo.toml: {changed} egui git patches rewritten to vendored paths")


if __name__ == "__main__":
    patch_fork()
    patch_cargo()
