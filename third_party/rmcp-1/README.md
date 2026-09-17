# Vendored rmcp security backport

This directory contains `rmcp` and `rmcp-macros` from the upstream Rust SDK
release tag `rmcp-v2.0.0`, backported to the lockfile-compatible `1.8.0`
package version required by the pinned Codex and Nanocodex dependencies.

The lockfile retains the existing dependency set, while the crates.io patch
redirects both packages to this fixed source tree.
