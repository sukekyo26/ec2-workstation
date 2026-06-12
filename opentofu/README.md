# OpenTofu Implementation

AWS CDK 実装（`../cdk/`）と同じインフラを OpenTofu で構築する実装です。
設定はリポジトリルートの `workstation-config.json` を CDK と共有します。

## ⚠️ CDK との排他利用

**同一 AWS アカウント・同一 `projectName`/`environment` に対して CDK と OpenTofu の両方を apply しないでください。**

両実装は同じ物理リソース名（IAM ロール名・セキュリティグループ名・キーペア名・ロググループ名）を使うため、二重 apply は名前衝突で失敗します。ただし衝突検出までに一部リソースが作成されることがあります。OpenTofu 版を試す場合は次のいずれかにしてください:

- `workstation-config.json` の `environment` を変える（例: `dev` → `dev-tofu`）
- 別の AWS アカウントを使う

## 前提条件

- OpenTofu 1.10 以降（S3 ネイティブロック `use_lockfile` を使用）
- AWS CLI（認証設定済み）
- state 保存用 S3 バケット

### State バケットの作成（初回のみ）

```bash
aws s3 mb s3://<your-state-bucket> --region ap-northeast-1
aws s3api put-bucket-versioning \
  --bucket <your-state-bucket> \
  --versioning-configuration Status=Enabled
```

## 🔐 State の保護（重要）

CDK 実装と異なり、OpenTofu 実装では **SSH 秘密鍵が state ファイルに平文で記録されます**
（`tls_private_key` リソースの仕様）。最低限、以下を必ず実施してください:

1. state バケットへのアクセスを必要最小限の IAM プリンシパルに制限する
2. バケットのデフォルト暗号化（SSE-S3 / SSE-KMS）を有効にする
3. 可能なら OpenTofu の [state encryption](https://opentofu.org/docs/language/state/encryption/) を有効にする:

```hcl
# 例: backend.tf に追記（passphrase は TF_VAR や環境変数で注入し、コミットしない）
terraform {
  encryption {
    key_provider "pbkdf2" "passphrase" {
      passphrase = var.state_passphrase # 16 文字以上
    }

    method "aes_gcm" "default" {
      keys = key_provider.pbkdf2.passphrase
    }

    state {
      method   = method.aes_gcm.default
      enforced = true
    }
  }
}
```

## 使い方

```bash
cd opentofu

# 初期化（backend 設定はアカウント固有のため -backend-config で注入）
tofu init \
  -backend-config="bucket=<your-state-bucket>" \
  -backend-config="key=ec2-workstation/dev/terraform.tfstate" \
  -backend-config="region=ap-northeast-1"

# 差分確認
tofu plan

# 適用
tofu apply

# 出力確認（インスタンス ID・SSM 接続コマンド等）
tofu output workstations
```

ユーザーの追加・変更はリポジトリルートの `workstation-config.json` を編集して `tofu apply` します。
ユーザー名がリソースのキーになっているため、ユーザーの追加・削除は他ユーザーのリソースに影響しません。

## 接続

apply 後の運用（VS Code Remote-SSH 設定・EC2 起動）は CDK 版と同じ `../scripts/` のスクリプトがそのまま使えます:

```bash
../scripts/setup-remote-ssh.sh <instance-id> <region>
```

秘密鍵は CDK 版と同じ SSM Parameter Store パス（`/ec2/keypair/{key_pair_id}`）に保存されるため、スクリプトの変更は不要です。

## CDK 実装との対応

| OpenTofu | CDK |
|----------|-----|
| `modules/network/` | `cdk/lib/stacks/network-stack.ts` + `vpc-construct.ts` |
| `modules/workstation/main.tf` | `security-construct.ts` + `ec2-construct.ts` |
| `modules/workstation/keypair.tf` | `ec2.KeyPair`（ED25519 + SSM 保存） |
| `modules/workstation/autostop.tf` | `auto-stop-construct.ts` |
| `locals.tf` | `cdk/lib/config/workstation-config.ts`（デフォルト適用・マージ） |

### 挙動の差異

- **AMI の固定方法**: CDK はローカルの `cdk.context.json`（アカウント固有値のため git 管理外）にキャッシュ、OpenTofu は `lifecycle { ignore_changes = [ami] }` で初回解決後に固定。ただし CDK を GitHub Actions などキャッシュを持たない環境からデプロイすると毎回最新 AMI を再解決するため、新 AMI 公開後の再デプロイでインスタンスが再作成される（ルート EBS が失われる）可能性があります。既存インスタンスを保持したい場合はローカルの `cdk.context.json` を使ってデプロイしてください。
- **秘密鍵の保存場所**: CDK は AWS が生成し SSM のみに保存。OpenTofu は `tls_private_key` で生成するため state にも記録されます（上記「State の保護」参照）。
