---
name: version-bump
description: 'Bump project version following Semantic Versioning. Use when asked to: (1) Release a new version, (2) Bump major/minor/patch version, (3) Move Unreleased changelog entries to a new release. Triggers: "version bump", "bump version", "release", "バージョンアップ", "バージョン上げ", "リリース", "semver".'
---

# バージョンアップ手順

セマンティックバージョニングに基づきプロジェクトバージョンを更新する。

## バージョン決定基準（SemVer）

| 変更内容 | バージョン |
|:---------|:-----------|
| 破壊的変更（BREAKING） | **major** (X.0.0) |
| 新機能追加（Added） | **minor** (x.Y.0) |
| バグ修正のみ（Fixed/Changed） | **patch** (x.y.Z) |

`CHANGELOG.md` の `## [Unreleased]` セクションの内容から判断する。

## 更新対象ファイル（4箇所）

| # | ファイル | 更新内容 |
|:-:|:---------|:---------|
| 1 | `pyproject.toml` | `version = "x.y.z"` を新バージョンに更新 |
| 2 | `uv.lock` | `uv sync` を実行して lockfile のバージョンを同期 |
| 3 | `CHANGELOG.md` | `## [Unreleased]` の直下に `## [x.y.z] - YYYY-MM-DD` を追加 |
| 4 | `docs/CHANGELOG.ja.md` | 同上 |

## 手順

1. `CHANGELOG.md` の `## [Unreleased]` の内容を確認し、SemVer に従いバージョンを決定
2. **CHANGELOG 相殺チェック**: 同一 Unreleased 内で追加（Added）と削除/変更（Changed/Removed）が相殺する項目を両方削除する（例: 機能Aを追加 → 同バージョン内で機能Aを削除 → 両エントリとも記載しない）
3. 4ファイルを上記の通り更新（`uv sync` の実行を忘れないこと）
4. `## [Unreleased]` 見出しは残す（次の開発用）。見出しの下は空にする
5. コミット: `feat: release vX.Y.Z`

## CHANGELOG フォーマット

```markdown
## [Unreleased]

## [x.y.z] - YYYY-MM-DD

### Added
- ...

### Changed
- ...

### Fixed
- ...
```

`## [Unreleased]` と `## [x.y.z]` の間に空行を1つ入れる。
