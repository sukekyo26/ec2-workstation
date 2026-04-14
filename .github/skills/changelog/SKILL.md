---
name: changelog
description: 'CHANGELOG 記載ルールと更新手順。changelog, 変更履歴, CHANGELOG更新, Unreleased に追記するときに使う。Triggers: "changelog", "変更履歴", "CHANGELOG", "Unreleased".'
---

# changelog

## 対象ファイル

| ファイル | 言語 |
|:---------|:-----|
| `CHANGELOG.md` | 英語 |
| `docs/CHANGELOG.ja.md` | 日本語 |

両ファイルは常に同期させること（同じ内容を各言語で記載する）。

## フォーマット

[Keep a Changelog](https://keepachangelog.com/en/1.0.0/) に準拠。

- `## [Unreleased]` セクションへ追記する
- カテゴリは `Added` / `Changed` / `Deprecated` / `Removed` / `Fixed` / `Security` を使用する
- 各エントリは動詞で始める（英語: Add / Change / Fix …、日本語: 追加 / 変更 / 修正 …）

## 記載対象

**ユーザーの動作に影響する変更のみ**を記載する。

### 記載する

- 機能の追加・変更・削除（`lib/`・`plugins/`・`config/` 配下の変更）
- CLI オプション・引数の変更（`generate-workspace.sh`・`setup-docker.sh` 等）
- スキーマファイルの変更（`schemas/` 配下）
- `workspace.toml` の設定フォーマット変更
- バグ修正
- 依存ツール・パッケージの更新でユーザー影響があるもの

### 記載しない

- `.github/` 配下の変更（instructions, skills, agents, prompts, hooks, workflows 等）
- テスト・CI のみの変更（`tests/`・`.github/workflows/` 配下）
- 外部動作に影響しないリファクタリング
- CHANGELOG 自体の修正

## 同一バージョン内の整理

`[Unreleased]` セクションは**前回リリースからの差分**を表す。追記時に既存エントリと重複・矛盾がないか確認し、整理する。

- A→B→A のように元に戻った変更は、差分ゼロなのでエントリを**削除**する
- A→B→C と変遷した場合は最終状態のみ記載する（A→C）
- Added した機能を同バージョン内で Removed した場合は両方**削除**する

## 手順

1. 変更が記載対象かどうかを判断する（対象外なら更新しない）
2. `CHANGELOG.md` の `## [Unreleased]` セクションを確認し、既存エントリとの重複・矛盾を整理したうえで英語で追記する
3. `docs/CHANGELOG.ja.md` の `## [Unreleased]` セクションも同様に整理・追記する
