# OpenTofu

設定はリポジトリルートの `workstation-config.json` から読み込みます。

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

**SSH 秘密鍵が state ファイルに平文で記録されます**
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

apply 後の運用（VS Code Remote-SSH 設定・EC2 起動）は `../scripts/` のスクリプトを使います:

```bash
../scripts/setup-remote-ssh.sh <instance-id> <region>
```

スクリプトは SSM Parameter Store の `/ec2/keypair/{key_pair_id}` から秘密鍵を取得します。
