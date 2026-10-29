terraform {
  backend "s3" {
    # bucket / key / region はリポジトリに置かず、scripts/tofu-init.sh が
    # tofu init の -backend-config で注入する (partial configuration)。
    # use_lockfile: S3 ネイティブロック (OpenTofu 1.10+)。DynamoDB テーブル不要。
    use_lockfile = true
  }
}
