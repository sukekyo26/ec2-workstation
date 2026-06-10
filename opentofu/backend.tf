terraform {
  backend "s3" {
    # bucket / key / region はアカウント固有値のためリポジトリに置かず、
    # tofu init の -backend-config で注入する (partial configuration):
    #
    #   tofu init \
    #     -backend-config="bucket=<your-state-bucket>" \
    #     -backend-config="key=ec2-remote-workspace/dev/terraform.tfstate" \
    #     -backend-config="region=ap-northeast-1"
    #
    # use_lockfile: S3 ネイティブロック (OpenTofu 1.10+)。DynamoDB テーブル不要。
    use_lockfile = true
  }
}
