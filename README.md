# EC2 Remote Workspace

Windows PC（管理者権限なし）からSessionManager経由でEC2 Linux開発環境に接続し、DevContainerで開発を行うためのインフラ構築プロジェクト。

## 📋 プロジェクト概要

### 背景・課題
- ローカルWindows PCに管理者権限がなく、WSLを有効化できない
- SSH接続はセキュリティ上の理由で禁止
- チーム開発のため環境差分を最小化したい

### 解決策
- AWS EC2上にLinux開発環境を構築
- SessionManager経由でセキュアに接続
- DevContainerを使用してチーム間の環境を統一

---

## 🏗️ 実装計画

### アーキテクチャ概要

```
┌─────────────────────────────────────────────────────────────────┐
│                           AWS Cloud                              │
│  ┌───────────────────────────────────────────────────────────┐  │
│  │                         VPC                                │  │
│  │  ┌─────────────────────────────────────────────────────┐  │  │
│  │  │                  Public Subnet                       │  │  │
│  │  │  ┌─────────────────────────────────────────────┐    │  │  │
│  │  │  │            EC2 Instance (Dev Env)            │    │  │  │
│  │  │  │  ┌───────────────────────────────────────┐  │    │  │  │
│  │  │  │  │  - Ubuntu 24.04 LTS                   │  │    │  │  │
│  │  │  │  │  - Docker & Docker Compose            │  │    │  │  │
│  │  │  │  │  - SSM Agent                          │  │    │  │  │
│  │  │  │  │  - Git, Node.js, Python, etc.         │  │    │  │  │
│  │  │  │  └───────────────────────────────────────┘  │    │  │  │
│  │  │  │                                             │    │  │  │
│  │  │  │  Security Group:                            │    │  │  │
│  │  │  │  - Inbound:  ALL BLOCKED (SSH含む)          │    │  │  │
│  │  │  │  - Outbound: HTTPS(443) only                │    │  │  │
│  │  │  └─────────────────────────────────────────────┘    │  │  │
│  │  │                         │                            │  │  │
│  │  └─────────────────────────┼────────────────────────────┘  │  │
│  │                            │                               │  │
│  │  ┌─────────────────────────┼────────────────────────────┐  │  │
│  │  │      Internet Gateway   │                            │  │  │
│  │  └─────────────────────────┼────────────────────────────┘  │  │
│  └────────────────────────────┼───────────────────────────────┘  │
└───────────────────────────────┼──────────────────────────────────┘
                                │
                    ┌───────────┴───────────┐
                    │   AWS SSM Endpoints   │
                    │   (Public Endpoints)  │
                    └───────────┬───────────┘
                                │ SessionManager
                                │ (HTTPS/443)
                    ┌───────────┴───────────┐
                    │      Windows PC       │
                    │  (管理者権限なし)      │
                    │  VS Code + AWS Toolkit│
                    └───────────────────────┘
```

### 技術スタック

| カテゴリ | 技術選定 | 理由 |
|---------|---------|------|
| IaC | AWS CDK (TypeScript) | 型安全性、再利用性、CloudFormation生成も可能 |
| OS | **Ubuntu 24.04 LTS** | 最新パッケージ、開発者に馴染み深い、2029年までサポート |
| インスタンス | t3.large | 2vCPU/8GB RAM、開発に十分なスペック |
| ストレージ | EBS gp3 100GB | 高速I/O、コスト効率が良い |
| ネットワーク | **Public Subnet** | セキュリティグループで保護、NAT Gateway不要でコスト削減 |
| 接続方式 | SSM SessionManager | SSH不要、IAM認証、監査ログ対応 |

### Public Subnet採用の理由（セキュリティ考慮）

Private Subnet + NAT Gatewayは一般的なベストプラクティスですが、以下の理由でPublic Subnetを採用：

| 項目 | 説明 |
|-----|------|
| **コスト削減** | NAT Gateway ($45/月) + VPC Endpoints ($30/月) = **月$75削減** |
| **セキュリティ担保** | セキュリティグループで全インバウンドをブロック（パブリックIPがあっても接続不可） |
| **IAM認証** | SessionManagerはIAM認証必須。IPだけでは接続できない |
| **監査ログ** | 全セッションはCloudWatch Logsに記録 |

⚠️ **重要**: SSH(22)を含む**全インバウンドトラフィックをブロック**することで、Private Subnet同等のセキュリティを実現

---

## 🌐 ネットワーク共有設計について

### 共有ネットワーク vs 個別ネットワーク

本プロジェクトでは、**VPC/Subnetをチームメンバー間で共有**し、**EC2インスタンスのみ個人ごとに分離**する設計を採用します。

| リソース | 共有 or 分離 | 理由 |
|---------|-------------|------|
| **VPC** | 共有（1つ） | コスト削減、管理容易 |
| **Public Subnet** | 共有（1つ） | 個別作成の必要なし |
| **Internet Gateway** | 共有（1つ） | VPCに1つで十分 |
| **EC2インスタンス** | **個別（人数分）** | 完全に独立した開発環境 |
| **セキュリティグループ** | **個別（人数分）** | インスタンスごとの通信制御 |
| **IAMロール** | **個別（人数分）** | 最小権限の原則 |

### セキュリティ分離の仕組み

同じVPC内にいても、**セキュリティグループ**でインスタンス間の通信を完全に制御できます：

```
┌──────────────────────────────────────────────────────────┐
│                      VPC (共有)                           │
│  ┌────────────────────────────────────────────────────┐  │
│  │          Public Subnet (共有)                       │  │
│  │                                                     │  │
│  │  ┌─────────────────┐      ┌─────────────────┐     │  │
│  │  │  田中さんのEC2   │      │  佐藤さんのEC2   │     │  │
│  │  │  IP: 10.0.1.10  │      │  IP: 10.0.1.20  │     │  │
│  │  │                 │      │                 │     │  │
│  │  │  SG-tanaka:     │      │  SG-sato:       │     │  │
│  │  │  In: ❌ ALL     │  ❌   │  In: ❌ ALL     │     │  │
│  │  │  Out: HTTPS     │      │  Out: HTTPS     │     │  │
│  │  └─────────────────┘      └─────────────────┘     │  │
│  │         ↑                         ↑               │  │
│  │         │                         │               │  │
│  │         └─────────────────────────┘               │  │
│  │            お互いに通信できない                     │  │
│  └────────────────────────────────────────────────────┘  │
└──────────────────────────────────────────────────────────┘
```

#### セキュリティグループによる分離

| ルール | 説明 | 効果 |
|--------|------|------|
| **インバウンド: 全拒否** | 外部からもVPC内からも接続不可 | 他のメンバーのインスタンスから接続できない |
| **アウトバウンド: HTTPS許可** | 外部への通信のみ可能 | インターネットアクセスは可能 |

### 共有ネットワークのメリット

| メリット | 説明 | 効果 |
|---------|------|------|
| **コスト削減** | VPC/IGW等は追加料金なし | 1ユーザーでも10ユーザーでも同じ |
| **管理容易** | ネットワーク設定は1回だけ | 新メンバー追加時もワークスペーススタックのみデプロイ |
| **IP枯渇回避** | Subnet（/24）で254個のIPアドレス | 10-20人程度なら十分 |
| **統一された構成** | 全員が同じネットワーク構成 | トラブルシューティングが容易 |

### アクセス制御（3層の防御）

| 層 | 仕組み | 保護対象 |
|----|--------|---------|
| **1. IAM認証** | SessionManager接続時にIAM認証が必須 | 他のメンバーのインスタンスに接続できない |
| **2. リソースタグ** | IAMポリシーで自分のインスタンスのみ許可 | 誤って他のメンバーの環境にアクセス不可 |
| **3. セキュリティグループ** | ネットワークレベルでインスタンス間通信をブロック | VPC内でも通信できない |

### IAMポリシー例（個人のインスタンスのみアクセス可能）

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "ssm:StartSession"
      ],
      "Resource": [
        "arn:aws:ec2:ap-northeast-1:*:instance/*"
      ],
      "Condition": {
        "StringEquals": {
          "ssm:resourceTag/Owner": "${aws:username}"
        }
      }
    }
  ]
}
```

→ 自分の `Owner` タグが付いたインスタンスにしか接続できない

### 完全分離が必要なケース

以下の場合は個別VPCを検討してください：

| ケース | 理由 | 対応 |
|--------|------|------|
| **本番環境も構築する** | 開発と本番の完全分離 | VPCを分ける |
| **機密性の高いデータ** | コンプライアンス要件 | VPCを分ける + Private Subnet |
| **顧客ごとの環境** | マルチテナント | VPC Peeringまたは Transit Gateway |
| **異なるネットワーク要件** | チームごとに異なるCIDR | VPCを分ける |

→ 今回のような**チーム内の開発環境**であれば、共有VPCで全く問題ありません

---

## 📁 ディレクトリ構成（予定）

```
ec2-remote-workspace/
├── README.md
├── workspace-config.json         # ユーザー・プロジェクト設定
├── workspace-config.schema.json  # 設定ファイルのJSONスキーマ
├── bin/
│   └── ec2-remote-workspace.ts   # CDKアプリエントリポイント
├── lib/
│   ├── constructs/
│   │   ├── vpc-construct.ts      # VPC構成
│   │   ├── security-construct.ts # セキュリティグループ・IAM
│   │   └── ec2-construct.ts      # EC2インスタンス
│   ├── stacks/
│   │   ├── network-stack.ts      # 共有ネットワーク（1つ）
│   │   └── workspace-stack.ts    # 個人用ワークスペース（人数分）
│   ├── config/
│   │   └── workspace-config.ts   # 設定ファイル読み込み・バリデーション
│   ├── scripts/
│   │   └── user-data.sh          # EC2初期化スクリプト
│   └── index.ts                  # エクスポート
├── scripts/
│   └── connect.sh                # 接続用ヘルパースクリプト
├── test/                         # テストコード
├── cdk.json
├── package.json
└── tsconfig.json
```

---

## 🚀 使用方法

### 前提条件

以下のツールがインストールされていること：

- **Node.js 22+** - [ダウンロード](https://nodejs.org/)
- **pnpm** - `npm install -g pnpm`
- **AWS CLI v2** - [インストールガイド](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html)
- **AWS CDK CLI** - `npm install -g aws-cdk`
- **Session Manager Plugin** - [インストールガイド](https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-install-plugin.html)

### インストール

```bash
# リポジトリをクローン
git clone <repository-url>
cd ec2-remote-workspace

# 依存関係をインストール
pnpm install
```

### 設定

`workspace-config.json` を編集してユーザーとプロジェクト設定を定義します：

```json
{
  "$schema": "./workspace-config.schema.json",
  "projectName": "ec2-remote-workspace",
  "environment": "dev",
  "vpcCidr": "10.0.0.0/16",
  "defaultInstanceConfig": {
    "instanceType": "t3.large",
    "volumeSize": 100,
    "volumeType": "gp3"
  },
  "users": [
    {
      "username": "developer1",
      "displayName": "Developer One"
    },
    {
      "username": "developer2",
      "displayName": "Developer Two"
    }
  ]
}
```

#### 設定項目

| 項目 | 必須 | デフォルト | 説明 |
|------|------|-----------|------|
| `projectName` | - | `ec2-remote-workspace` | プロジェクト名（リソース命名に使用） |
| `environment` | - | `dev` | 環境名 (dev, staging, prod) |
| `vpcCidr` | - | `10.0.0.0/16` | VPC CIDR |
| `defaultInstanceConfig.instanceType` | - | `t3.large` | EC2インスタンスタイプ |
| `defaultInstanceConfig.volumeSize` | - | `100` | EBSボリュームサイズ (GB) |
| `defaultInstanceConfig.volumeType` | - | `gp3` | EBSボリュームタイプ |
| `users` | ✅ | - | ユーザー配列（1人以上必須） |
| `users[].username` | ✅ | - | ユーザー名（小文字英数字、ハイフン、アンダースコア） |
| `users[].displayName` | - | - | 表示名 |
| `users[].instanceConfig` | - | - | ユーザー個別のインスタンス設定 |

### ビルド

```bash
# TypeScriptをコンパイル
pnpm build
```

### テスト

```bash
# テストを実行
pnpm test
```

### デプロイ

```bash
# AWS認証情報を設定
aws configure

# CDK Bootstrap（初回のみ）
cdk bootstrap

# 全スタックをデプロイ
cdk deploy --all

# 特定のスタックのみデプロイ
cdk deploy ec2-remote-workspace-dev-network
cdk deploy ec2-remote-workspace-dev-developer1
```

### 接続

デプロイ完了後、SessionManager経由でEC2インスタンスに接続できます：

```bash
# 接続スクリプトを使用（推奨）
./scripts/connect.sh -u developer1

# または直接AWS CLIで接続
# まずインスタンスIDを取得
aws ec2 describe-instances \
  --filters "Name=tag:Owner,Values=developer1" \
  --query 'Reservations[].Instances[].InstanceId' \
  --output text

# SessionManager経由で接続
aws ssm start-session --target i-xxxxxxxxxxxx
```

### VS Code Remote接続

1. VS Code に **Remote - SSH** 拡張機能をインストール
2. **AWS Toolkit** 拡張機能をインストール
3. SSH configを設定（`~/.ssh/config`）：

```
Host ec2-workspace-*
    ProxyCommand aws ssm start-session --target %h --document-name AWS-StartSSHSession --parameters portNumber=%p
    User ubuntu
    IdentityFile ~/.ssh/your-key.pem
```

4. VS Codeから接続

### スタックの削除

```bash
# 全スタックを削除
cdk destroy --all

# 特定のスタックのみ削除
cdk destroy ec2-remote-workspace-dev-developer1
```

---

## 🔧 実装フェーズ

### Phase 1: 基盤構築（CDKプロジェクトセットアップ）
- [x] CDKプロジェクト初期化
- [x] 共通設定・型定義
- [x] VPC Construct作成（Public Subnetのみ、Internet Gateway）
- [x] セキュリティグループ作成（全インバウンドブロック、アウトバウンドHTTPS許可）

### Phase 2: セキュリティ構成
- [x] IAMロール作成（EC2用、SSM接続権限）
- [x] セキュリティグループ作成（インバウンドSSH禁止）
- [x] インスタンスプロファイル設定

### Phase 3: EC2ワークスペース構成
- [x] EC2 Construct作成
- [x] User Dataスクリプト作成（Docker, Git等のインストール）
- [x] EBS設定（gp3 100GB）
- [x] 個人用スタックのパラメータ化

### Phase 4: 接続・運用ツール
- [x] SessionManager接続用スクリプト
- [ ] VS Code Remote接続設定ガイド
- [ ] 自動起動/停止スケジュール（コスト削減）

### Phase 5: ドキュメント・テスト
- [x] テストコード作成
- [ ] セットアップガイド作成
- [ ] トラブルシューティングガイド
- [ ] CloudFormationテンプレート出力

---

## 💰 コスト見積もり

### 前提条件
- 使用時間: 平日8時間 × 月20日 = **160時間/月**
- リージョン: ap-northeast-1（東京）
- インスタンス停止時はEC2料金は発生しない（EBSは継続課金）

### 月額コスト（1ユーザーあたり）

| リソース | スペック | 単価 | 月額コスト |
|---------|---------|------|-----------|
| **EC2 (t3.large)** | 2vCPU / 8GB RAM | $0.1088/時間 | **$17.41** (160時間) |
| **EBS (gp3)** | 100GB | $0.096/GB/月 | **$9.60** |
| **EBS IOPS** | 3000 IOPS (無料枠内) | $0 | **$0** |
| **EBS スループット** | 125 MB/s (無料枠内) | $0 | **$0** |
| **データ転送 (Out)** | 10GB想定 | $0.114/GB | **$1.14** |

※ Public Subnet採用によりNAT Gateway/VPC Endpointsのコストは不要

### 月額合計

| パターン | 構成 | 月額コスト (USD) | 月額コスト (JPY) |
|---------|------|-----------------|-----------------|
| **1ユーザー** | 個人利用 | **約 $28** | **約 ¥4,200** |
| **5ユーザー** | チーム利用 | **約 $141** | **約 ¥21,150** |
| **10ユーザー** | チーム利用 | **約 $282** | **約 ¥42,300** |

※ 1 USD = 150 JPY で計算

### コスト最適化オプション

| オプション | 効果 | 削減額（月） |
|-----------|------|-------------|
| **Savings Plans (1年)** | EC2 30%割引 | -$5.22/ユーザー |
| **スポットインスタンス** | 最大70%割引（中断リスクあり） | -$12/ユーザー |
| **自動停止スケジュール** | 平日18時以降停止 | -$0 (既に想定済み) |
| **t3.medium に変更** | 4GB RAMで十分な場合 | -$8.70/ユーザー |

---

## 🖥️ EC2 インスタンススペック詳細

### 推奨構成: t3.large

| 項目 | スペック |
|------|---------|
| vCPU | 2 |
| メモリ | 8 GB |
| ネットワーク | 最大 5 Gbps |
| EBS帯域幅 | 最大 2,085 Mbps |
| OS | **Ubuntu 24.04 LTS** |

### プリインストールソフトウェア

```bash
# User Dataで自動インストール
- SSM Agent (SessionManager接続用)
- Docker & Docker Compose
- Git
- Node.js (via nvm)
- Python 3.x
- AWS CLI v2
- VS Code Server (自動接続用)
- 開発に必要な基本ツール (vim, curl, wget, jq等)
```

---

## 🔐 セキュリティ設計

### ネットワークセキュリティ
- ✅ EC2はPublic Subnetに配置（パブリックIP付与）
- ✅ SSH (Port 22) を含む**全インバウンドトラフィックを完全にブロック**
- ✅ アウトバウンドはHTTPS(443)のみ許可
  - `git clone`, `apt install`, `docker pull` 等は全てアウトバウンド通信なので問題なく動作
  - セキュリティグループはステートフルなので、リクエストへのレスポンスは自動的に許可
- ✅ Internet Gateway経由で外部通信可能（SessionManager接続もHTTPS経由）

### IAM設計
- ✅ EC2インスタンスプロファイルに最小権限のIAMロール
- ✅ SSM接続に必要な権限のみ付与
- ✅ ユーザーごとに接続許可をIAMポリシーで制御可能

### 監査・ログ
- ✅ SessionManagerのセッションログをCloudWatch Logsに記録
- ✅ CloudTrailでAPI操作を記録

---

## 📝 次のステップ

この実装計画が承認されたら、以下の順序で実装を進めます：

1. **CDKプロジェクトの初期化**
2. **ネットワークスタックの実装**
3. **ワークスペーススタックの実装**
4. **接続スクリプト・ドキュメントの作成**
5. **テスト・デプロイ**

---

## 📚 参考資料

- [AWS Systems Manager Session Manager](https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager.html)
- [VS Code Remote - SSH with SSM](https://docs.aws.amazon.com/toolkit-for-vscode/latest/userguide/remote-development.html)
- [AWS CDK Documentation](https://docs.aws.amazon.com/cdk/v2/guide/home.html)