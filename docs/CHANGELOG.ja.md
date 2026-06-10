# 変更履歴

このプロジェクトに対する注目すべき変更はすべてこのファイルに記載されます。

フォーマットは [Keep a Changelog](https://keepachangelog.com/ja/1.0.0/) に準拠し、
[Semantic Versioning](https://semver.org/lang/ja/spec/v2.0.0.html) に従います。

## [Unreleased]

### Added

- CDK 実装と同じインフラを構築する OpenTofu 実装（`opentofu/`）を追加（`workspace-config.json`・`shared/user-data.sh`・運用スクリプトを共有）

## [0.1.0] - 2026-04-14

### Added

- モジュラー CDK アーキテクチャを追加（VPC・Security・EC2・AutoStop コンストラクトを分離）
- JSON ベースのワークスペース設定（`workspace-config.json`）と JSON Schema バリデーションを追加
- NetworkStack（共有 VPC/Subnet/IGW）と WorkspaceStack（ユーザー別 EC2）の分離構成を追加
- SessionManager 経由のセキュア接続を追加（SSH ポート非公開、IAM 認証）
- セキュリティグループを追加（全インバウンドブロック、アウトバウンドは HTTPS/HTTP/DNS のみ許可）
- EBS の AWS マネージドキー暗号化と IMDSv2 強制を追加
- VPC Flow Logs（REJECT のみ）を追加（保持期間1ヶ月、セキュリティ監査用）
- SSH キーペア生成と SSM Parameter Store への保存を追加（Remote-SSH 接続用）
- VS Code Remote-SSH セットアップスクリプトを追加（Windows 用 PowerShell・Linux/Mac 用シェル）
- ProxyCommand による EC2 自動起動機能を追加（SSH 接続時に停止中のインスタンスを自動起動）
- 自動停止機能を追加（CloudWatch CPU アラーム・EventBridge 定時停止）
- `workspace-config.json` のカスタマイズ可能な自動停止設定（`autoStopConfig`）を追加
- user-data スクリプトを追加（Docker・AWS CLI v2・Git・開発ツールのプリインストール）
- SSH ホストキーチェックスキップ設定を追加（シームレスなリモート接続用）
- ユーザー別インスタンス設定のオーバーライドを追加
- Elastic IP（固定パブリック IP）のオプションサポートを追加（プロジェクトレベルのデフォルト設定とユーザー単位のオーバーライド）
- 全コンストラクト・スタックの包括的なテストカバレッジを追加

### Fixed

- `scripts/start-ec2.sh` のシェル構文エラーを修正（関数の閉じ括弧が `fi` になっていた問題、C-style for ループを while ループに置換）
