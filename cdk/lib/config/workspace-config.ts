import * as fs from 'fs';
import * as path from 'path';
import Ajv from 'ajv';

/**
 * ワークスペース設定
 * 各ユーザーの環境を管理するための設定ファイル
 *
 * 設定の仕様（必須項目・型・値域・命名規則）は workspace-config.schema.json が
 * 唯一の定義であり、ここではスキーマ検証のみ行う。個別のバリデーションや
 * デフォルト値の適用は実装しない。
 */

/**
 * EC2インスタンスのスペック設定
 */
export interface InstanceConfig {
  /** インスタンスタイプ (例: t3.medium) */
  readonly instanceType: string;
  /** EBSボリュームサイズ (GB) */
  readonly volumeSize: number;
  /** EBSボリュームタイプ */
  readonly volumeType: 'gp3' | 'gp2';
}

/**
 * 自動停止設定
 */
export interface AutoStopConfig {
  /** CPU使用率閾値（%）- この値以下が続くと停止 */
  readonly cpuThreshold: number;
  /** CPU監視期間（分）- この期間低負荷が続くと停止 */
  readonly cpuEvaluationMinutes: number;
  /** 定時停止時刻（時、0-23、Asia/Tokyo） */
  readonly scheduledStopHour: number;
  /** 定時停止時刻（分、0-59） */
  readonly scheduledStopMinute: number;
}

/**
 * 個人のワークスペース設定
 */
export interface WorkspaceUserConfig {
  /** ユーザー名（小文字英数字、ハイフン、アンダースコア） */
  readonly username: string;
  /** 表示名（オプション） */
  readonly displayName?: string;
  /** ユーザー固有のインスタンス設定（オプション、デフォルトを項目単位で上書き） */
  readonly instanceConfig?: Partial<InstanceConfig>;
  /** Elastic IP を有効にするか（プロジェクトデフォルトを上書き） */
  readonly enableElasticIp?: boolean;
}

/**
 * プロジェクト全体の設定
 */
export interface ProjectConfig {
  /** プロジェクト名（リソース命名に使用） */
  readonly projectName: string;
  /** 環境名 (dev, staging, prod) */
  readonly environment: string;
  /** VPC CIDR */
  readonly vpcCidr: string;
  /** デフォルトのインスタンス設定 */
  readonly defaultInstanceConfig: InstanceConfig;
  /** 自動停止設定 */
  readonly autoStopConfig: AutoStopConfig;
  /** Elastic IP のデフォルト有効化設定 */
  readonly enableElasticIp: boolean;
  /** ワークスペースユーザー一覧 */
  readonly users: WorkspaceUserConfig[];
}

/**
 * ユーザー設定をマージしてインスタンス設定を取得
 */
export function getInstanceConfig(
  userConfig: WorkspaceUserConfig,
  defaultConfig: InstanceConfig
): InstanceConfig {
  return {
    ...defaultConfig,
    ...userConfig.instanceConfig,
  };
}

/**
 * ユーザーの Elastic IP 有効化状態を解決する
 * ユーザー設定 > プロジェクトデフォルト の優先順位
 */
export function resolveElasticIp(
  userConfig: WorkspaceUserConfig,
  projectDefault: boolean
): boolean {
  return userConfig.enableElasticIp ?? projectDefault;
}

/**
 * 設定ファイル・スキーマのパス（リポジトリルート直下、cwd 非依存）
 */
const DEFAULT_CONFIG_PATH = path.join(__dirname, '../../../workspace-config.json');
const SCHEMA_PATH = path.join(__dirname, '../../../workspace-config.schema.json');

// スキーマは fs ではなく require で読む（テストの fs モックの影響を受けない）
// eslint-disable-next-line @typescript-eslint/no-var-requires
const schema = require(SCHEMA_PATH);
const ajv = new Ajv({ allErrors: true });
const validateSchema = ajv.compile(schema);

/**
 * 設定ファイルからプロジェクト設定を読み込み、JSON スキーマで検証する
 *
 * @param configPath 設定ファイルのパス（オプション、デフォルト: リポジトリルートの workspace-config.json）
 * @returns プロジェクト設定
 * @throws 設定ファイルが見つからない、パースできない、またはスキーマ違反の場合
 */
export function loadProjectConfig(configPath?: string): ProjectConfig {
  const resolvedPath = configPath || DEFAULT_CONFIG_PATH;

  if (!fs.existsSync(resolvedPath)) {
    throw new Error(
      `Configuration file not found: ${resolvedPath}\n` +
      'Please create a workspace-config.json file in the project root.\n' +
      'See workspace-config.schema.json for the required structure.'
    );
  }

  let rawConfig: unknown;
  try {
    const content = fs.readFileSync(resolvedPath, 'utf-8');
    rawConfig = JSON.parse(content);
  } catch (error) {
    throw new Error(
      `Failed to parse configuration file: ${resolvedPath}\n` +
      `Error: ${error instanceof Error ? error.message : String(error)}`
    );
  }

  if (!validateSchema(rawConfig)) {
    const details = (validateSchema.errors ?? [])
      .map((e) => `  - ${e.instancePath || '(root)'}: ${e.message}`)
      .join('\n');
    throw new Error(
      `Configuration file violates workspace-config.schema.json: ${resolvedPath}\n` +
      `${details}\n` +
      'Fix workspace-config.json according to the schema.'
    );
  }

  return rawConfig as ProjectConfig;
}
