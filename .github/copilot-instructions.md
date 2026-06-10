# GitHub Copilot Instructions

## 設計原則

- **シンプルな実装を最優先する** — 読んで即座に意図が伝わるコードを書く。巧妙なテクニックより明快さを選ぶ。
- **DRY原則** — 同じロジックを2箇所以上に書かない。`cdk/lib/constructs/` の共通コンストラクトを活用し、なければそこに追加する。
- **後方互換性のために実装を複雑にしない** — 非推奨パスや分岐を積み重ねるくらいなら、破壊的変更+マイグレーション手順を選ぶ。互換レイヤーは一時的な措置に留める。
- **べき等性を保つ** — CDKスタックのデプロイ・スクリプトの実行は何度行っても同じ結果になること。既に存在するリソースの二重作成や意図しない上書きを避ける。
- **早期失敗と明確なエラー** — 異常は検出した時点で例外をスローして即座に中断する。エラーメッセージにはユーザーが次に何をすべきかを含める。
- **既存の共通基盤を使う** — `cdk/lib/constructs/` のコンストラクト・`cdk/lib/config/` の設定ローダー・`cdk/lib/index.ts` の re-export を再利用する。車輪の再発明をしない。

## Context7 MCP の利用

- **Context7 MCP を利用する** — タスクの実行や情報の取得に Context7 MCP を活用する。必要な情報があれば、Context7 MCP 経由で取得できないかをまず検討する。

## CHANGELOG の更新

- **コード変更時は必ず CHANGELOG を同時に更新する** — 機能追加・バグ修正・変更を行った場合、コミット前に `CHANGELOG.md` と `docs/CHANGELOG.ja.md` の両方を更新する
- **記載対象**: `lib/`・`bin/`・`scripts/`・`workspace-config.schema.json` など、ユーザーの動作やインフラ構成に影響する変更
- **記載しない**: `.github/` 配下（instructions/skills/agents等）・テストのみの変更・CI のみの変更・外部動作に影響しないリファクタリング
- 詳細な記載ルールは `changelog` スキルを参照すること

## Git コミット

- **タスク完了前に必ずコミットする** — CHANGELOG 更新（対象なら）→ `git add` → `git commit` → `git status` で clean 確認 → タスク完了宣言
- **Conventional Commits 形式** — `feat:`, `fix:`, `docs:`, `chore:` 等のプレフィックス、英語1文
- **論理単位でコミットを分ける** — コンストラクト+テスト、スキーマ+ドキュメント等
- **`.gitignore` 対象はコミットしない**
- **`git commit --amend` は未プッシュのコミットのみ** — amend 前に `git log --oneline origin/develop..HEAD` で対象コミットが含まれるか確認。含まれなければ新規コミットにする
