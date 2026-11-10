#!/usr/bin/env python3
"""Idempotent, minimal upstream hook for slide placeholder prompts.

The two canvas placeholders ("Click to add title" / "Click to add subtitle")
are *document model* strings: `deckcraft_model::PhType::prompt()` builds a
`TextBody` that `deckcraft_render` lays out into glyph runs directly. They never
pass through `egui`/`epaint`, so the host translator installed in
`Fonts::layout_job` cannot see them.

This script adds one tiny, reversible hook to the upstream model crate:

  * `crates/model/src/i18n.rs`  - a `OnceLock<fn(&'static str) -> Option<&'static str>>`
    plus `install_prompt_translator` / `translate_prompt`.
  * `crates/model/src/lib.rs`  - `prompt()` keeps its signature and its whole
    match table; the result is passed through `translate_prompt` on return.

The HarmonyOS adapter installs a translator that consults the same runtime
language flag as the egui hook, so switching the system language also switches
these prompts. No UI code, engine logic or string literal is changed.

Usage:
    python scripts/apply_model_prompt_i18n.py           # apply (idempotent)
    python scripts/apply_model_prompt_i18n.py --revert  # restore originals

The first apply writes `lib.rs.orig` next to the file for a byte-exact revert.
"""

from __future__ import annotations

import pathlib
import shutil
import sys

ROOT = pathlib.Path(__file__).resolve().parents[1]
MODEL = ROOT.parent / "deckcraft" / "crates" / "model" / "src"
LIB = MODEL / "lib.rs"
ORIG = MODEL / "lib.rs.orig"
I18N = MODEL / "i18n.rs"

I18N_RS = '''//! Host-installed translator for empty-placeholder prompts (HarmonyOS port).
//!
//! Upstream `PhType::prompt()` returns a static English literal that the
//! renderer lays out directly into glyph runs, bypassing egui. The host can
//! install a translator here; the language switch itself lives in the host, so
//! no re-registration is needed when the system language changes.

use std::sync::OnceLock;

/// Maps one upstream prompt literal to a translated static literal.
pub type PromptTranslator = fn(&'static str) -> Option<&'static str>;

static PROMPT_TRANSLATOR: OnceLock<PromptTranslator> = OnceLock::new();

/// The first install wins; later calls are ignored.
pub fn install_prompt_translator(translator: PromptTranslator) {
    let _ = PROMPT_TRANSLATOR.set(translator);
}

#[inline]
pub fn translate_prompt(base: &'static str) -> &'static str {
    PROMPT_TRANSLATOR
        .get()
        .and_then(|f| f(base))
        .unwrap_or(base)
}
'''

MOD_ANCHOR = "pub mod anim;\n"
MOD_NEW = "pub mod anim;\npub mod i18n;\n"

PROMPT_HEAD_OLD = """    pub fn prompt(self) -> &'static str {
        match self {
"""
PROMPT_HEAD_NEW = """    pub fn prompt(self) -> &'static str {
        let base = match self {
"""

PROMPT_TAIL_OLD = """            PhType::SlideImage => "",
        }
    }
    /// Footer-row placeholders are not shown on slides unless the deck turns them on.
"""
PROMPT_TAIL_NEW = """            PhType::SlideImage => "",
        };
        i18n::translate_prompt(base)
    }
    /// Footer-row placeholders are not shown on slides unless the deck turns them on.
"""


def revert() -> None:
    if ORIG.exists():
        shutil.copyfile(ORIG, LIB)
        print(f"reverted {LIB}")
    if I18N.exists():
        I18N.unlink()
        print(f"removed {I18N}")
    if not ORIG.exists() and not I18N.exists():
        print("nothing to revert")


def apply() -> None:
    text = LIB.read_text(encoding="utf-8")

    if "i18n::translate_prompt(base)" in text:
        print("prompt hook already present; nothing to do")
    else:
        if not ORIG.exists():
            shutil.copyfile(LIB, ORIG)
            print(f"backup -> {ORIG}")
        for label, old, new in (
            ("mod i18n", MOD_ANCHOR, MOD_NEW),
            ("prompt head", PROMPT_HEAD_OLD, PROMPT_HEAD_NEW),
            ("prompt tail", PROMPT_TAIL_OLD, PROMPT_TAIL_NEW),
        ):
            if text.count(old) != 1:
                raise SystemExit(
                    f"anchor {label!r} matched {text.count(old)} times; "
                    "upstream source changed, refusing to patch"
                )
            text = text.replace(old, new, 1)
            print(f"patched {label}")
        LIB.write_text(text, encoding="utf-8")

    if not I18N.exists() or I18N.read_text(encoding="utf-8") != I18N_RS:
        I18N.write_text(I18N_RS, encoding="utf-8")
        print(f"wrote {I18N}")

    final = LIB.read_text(encoding="utf-8")
    assert "pub mod i18n;" in final
    assert "i18n::translate_prompt(base)" in final
    print("model prompt hook verified")


if __name__ == "__main__":
    if not LIB.is_file():
        raise SystemExit(f"upstream model crate not found: {LIB}")
    if "--revert" in sys.argv:
        revert()
    else:
        apply()
