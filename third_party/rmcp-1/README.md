# Vendored rmcp security backport

This directory contains `rmcp` and `rmcp-macros` from the upstream Rust SDK
release tag `rmcp-v2.0.0`, backported to the lockfile-compatible `1.8.0`
package version required by the pinned Codex and Nanocodex dependencies.

The lockfile retains the existing dependency set, while the crates.io patch
redirects both packages to this fixed source tree.

It also backports the `rmcp-v2.1.0` redirect policy change for
GHSA-9g45-5xwm-f3wc: streamable HTTP clients do not automatically follow
redirects, so caller-supplied custom headers cannot be forwarded to another
origin.
