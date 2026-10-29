# OpenTofu

設定はリポジトリルートの `workstation-config.json` から読み込みます。

## 前提条件

- OpenTofu 1.10 以降（S3 ネイティブロック `use_lockfile` を使用）
- AWS CLI（認証設定済み）
- state 保存用 S3 バケット

### State バケットの作成（初回のみ）

state のバケットは `ap-northeast-1` に作ります（`scripts/lib/tofu-common.sh` の `STATE_REGION`）。デプロイ先のリージョン（`workstation-config.json` の `awsRegion`）とは別です。

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

state は、network の 1 つと、ユーザーごとの workstations に分かれています。

| ルート | 持つもの | state の key |
|---|---|---|
| `stacks/network/` | VPC・サブネット・IGW・Flow Logs（全員で使う） | `<projectName>/<environment>/network.tfstate` |
| `stacks/workstations/` | 1 人のユーザーのインスタンス・データボリューム・SG・IAM など。workspace がユーザー（名前はユーザー名）で、その人の分だけを持つ。VPC とサブネットは Name タグで引く | `<projectName>/<environment>/users/<username>/<projectName>/<environment>/workstation.tfstate`（S3 backend が `workspace_key_prefix`・workspace・`key` をつなげた形） |

`projectName`・`environment` はリポジトリルートの `workstation-config.json` から取ります。init（bucket・key の注入）は `scripts/tofu-init.sh` だけが行います。

```bash
export TF_STATE_BUCKET=<your-state-bucket>

# デプロイ（network → workstations。各段は plan が通ったときだけ、保存した plan を apply する。端末なら変更のある段ごとに yes を待つ）
../scripts/tofu-deploy.sh

# 1 人分の差分を見る・1 人分だけ apply する（tofu-init.sh がその人の workspace を選ぶ）
../scripts/tofu-init.sh workstations <username> && tofu -chdir=stacks/workstations plan
tofu -chdir=stacks/workstations apply

# 出力確認（選んでいる workspace の 1 人分。インスタンス ID・SSM 接続コマンド等）
tofu -chdir=stacks/workstations output workstations

# 全部を削除（workstations → network）
../scripts/tofu-destroy.sh
```

ユーザーの追加・変更・削除はリポジトリルートの `workstation-config.json` を編集して `scripts/tofu-deploy.sh` を実行します。
state はユーザーごとなので、1 人の apply がほかの人のリソースに触れることはありません。設定から消したユーザーは、`scripts/tofu-deploy.sh` が destroy し、その人の workspace（state）を消します。

## 接続

apply 後の運用（VS Code Remote-SSH 設定・EC2 起動）は `../scripts/` のスクリプトを使います:

```bash
../scripts/setup-remote-ssh.sh   # Name タグ (tofu output workstations の instance_name) を対話入力
```

スクリプトは SSM Parameter Store の `/ec2/keypair/{key_pair_id}` から秘密鍵を取得します。
