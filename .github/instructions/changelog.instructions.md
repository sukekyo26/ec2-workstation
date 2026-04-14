---
applyTo: "CHANGELOG.md,docs/CHANGELOG.ja.md"
---

# CHANGELOG のルール

- `.github/` 配下の変更（instructions, skills, agents, prompts, hooks, workflows 等）は CHANGELOG に記載しない。CHANGELOG はユーザー向けの変更履歴であり、エージェントカスタマイズの内部変更は対象外
- 同一 `## [Unreleased]` 内で追加と削除/変更が相殺する項目は両方記載しない（例: 機能 A を追加 → 同バージョン内で機能 A を削除 → 両エントリとも不要）
