# OpenTofu

使い方は [README.md](../README.md) にあります。
ここには、stack と state の分け方だけを書きます。

| stack | 持つもの | state の key |
|-------|----------|--------------|
| `stacks/network/` | VPC・サブネット・IGW・Flow Logs（全員で使う） | `<projectName>/<environment>/network.tfstate` |
| `stacks/workstations/` | 1 人のユーザーのインスタンス・データボリューム・SG・IAM など。workspace がユーザー（名前はユーザー名）です。VPC とサブネットは Name タグで引きます | `<projectName>/<environment>/users/<username>/<projectName>/<environment>/workstation.tfstate` |

- workstations の key は、S3 backend が `workspace_key_prefix`・workspace・`key` をつないだ形です。
- `projectName`・`environment` は、リポジトリのルートの `workstation-config.json` から取ります。
- init（bucket と key を渡す）は `scripts/tofu-init.sh` だけが行います。
- state のバケットには SSH の秘密鍵が平文で入ります。
