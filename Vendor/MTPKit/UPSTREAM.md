# Upstream source

- Project: MTPKit
- Release: `0.1.4`
- Revision: `7ad0c0f3a0a6443408f2b3721a58594a1641d242`
- Source: https://github.com/5j54d93/MTPKit/tree/0.1.4

This directory contains the source for that release. One packaging adaptation is applied in `MTPError+Message.swift`: a signed macOS app checks `Contents/Resources` for MTPKit's localization bundle before using SwiftPM's generated development-build lookup.
