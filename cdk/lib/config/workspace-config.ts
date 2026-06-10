import * as fs from 'fs';
import * as path from 'path';

/**
 * ワークスペース設定
 * 各ユーザーの環境を管理するための設定ファイル
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
  /** CPU使用率閾値（%）- この値以下が続くと停止（デフォルト: 5） */
  readonly cpuThreshold: number;
  /** CPU監視期間（分）- この期間低負荷が続くと停止（デフォルト: 10） */
  readonly cpuEvaluationMinutes: number;
  /** 定時停止時刻（時、0-23、Asia/Tokyo）（デフォルト: 23） */
  readonly scheduledStopHour: number;
  /** 定時停止時刻（分、0-59）（デフォルト: 0） */
  readonly scheduledStopMinute: number;
}

/**
 * 個人のワークスペース設定
 */
export interface WorkspaceUserConfig {
  /** ユーザー名（英数字、ハイフン、アンダースコアのみ） */
  readonly username: string;
  /** 表示名（オプション） */
  readonly displayName?: string;
  /** インスタンス設定（オプション、デフォルト値を使用） */
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
 * デフォルトのインスタンス設定
 */
export const DEFAULT_INSTANCE_CONFIG: InstanceConfig = {
  instanceType: 't3.medium',
  volumeSize: 80,
  volumeType: 'gp3',
};

/**
 * デフォルトの自動停止設定
 */
export const DEFAULT_AUTO_STOP_CONFIG: AutoStopConfig = {
  cpuThreshold: 5,
  cpuEvaluationMinutes: 10,
  scheduledStopHour: 23,
  scheduledStopMinute: 0,
};

/**
 * プロジェクトのデフォルト設定
 */
export const DEFAULT_PROJECT_CONFIG: Omit<ProjectConfig, 'users'> = {
  projectName: 'ec2-remote-workspace',
  environment: 'dev',
  vpcCidr: '10.0.0.0/16',
  defaultInstanceConfig: DEFAULT_INSTANCE_CONFIG,
  autoStopConfig: DEFAULT_AUTO_STOP_CONFIG,
  enableElasticIp: false,
};

/**
 * ユーザー名のバリデーション
 */
export function validateUsername(username: string): boolean {
  const pattern = /^[a-z0-9][a-z0-9_-]{1,30}[a-z0-9]$/;
  return pattern.test(username);
}

/**
 * ユーザー設定をマージしてインスタンス設定を取得
 */
export function getInstanceConfig(
  userConfig: WorkspaceUserConfig,
  defaultConfig: InstanceConfig = DEFAULT_INSTANCE_CONFIG
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
  projectDefault: boolean = false
): boolean {
  return userConfig.enableElasticIp ?? projectDefault;
}

/**
 * 設定ファイルのデフォルトパス（リポジトリルート直下、cwd 非依存）
 */
const DEFAULT_CONFIG_PATH = path.join(__dirname, '../../../workspace-config.json');

/**
 * 設定ファイルからプロジェクト設定を読み込む
 *
 * @param configPath 設定ファイルのパス（オプション、デフォルト: リポジトリルートの workspace-config.json）
 * @returns プロジェクト設定
 * @throws 設定ファイルが見つからない、またはパースできない場合
 */
export function loadProjectConfig(configPath?: string): ProjectConfig {
  const resolvedPath = configPath || DEFAULT_CONFIG_PATH;

  if (!fs.existsSync(resolvedPath)) {
    throw new Error(
      `Configuration file not found: ${resolvedPath}\n` +
      'Please create a workspace-config.json file in the project root.\n' +
      'See workspace-config.json.example for reference.'
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

  return validateAndParseConfig(rawConfig);
}

/**
 * 設定オブジェクトのバリデーションとパース
 */
export function validateAndParseConfig(rawConfig: unknown): ProjectConfig {
  if (typeof rawConfig !== 'object' || rawConfig === null) {
    throw new Error('Configuration must be an object');
  }

  const config = rawConfig as Record<string, unknown>;

  // 必須フィールドのチェック
  if (!Array.isArray(config.users) || config.users.length === 0) {
    throw new Error(
      'Configuration must have at least one user defined in "users" array.\n' +
      'Example:\n' +
      '{\n' +
      '  "users": [\n' +
      '    { "username": "developer1" }\n' +
      '  ]\n' +
      '}'
    );
  }

  // ユーザー名のバリデーション
  const users: WorkspaceUserConfig[] = [];
  for (const user of config.users) {
    if (typeof user !== 'object' || user === null) {
      throw new Error('Each user must be an object');
    }

    const userObj = user as Record<string, unknown>;
    if (typeof userObj.username !== 'string') {
      throw new Error('Each user must have a "username" string property');
    }

    if (!validateUsername(userObj.username)) {
      throw new Error(
        `Invalid username: ${userObj.username}\n` +
        'Username must be 3-32 characters, lowercase alphanumeric with hyphens/underscores, ' +
        'starting and ending with alphanumeric.'
      );
    }

    users.push({
      username: userObj.username,
      displayName: typeof userObj.displayName === 'string' ? userObj.displayName : undefined,
      instanceConfig:
        typeof userObj.instanceConfig === 'object' && userObj.instanceConfig !== null
          ? (userObj.instanceConfig as Partial<InstanceConfig>)
          : undefined,
      enableElasticIp:
        typeof userObj.enableElasticIp === 'boolean' ? userObj.enableElasticIp : undefined,
    });
  }

  // デフォルトインスタンス設定のマージ
  const defaultInstanceConfig: InstanceConfig = {
    ...DEFAULT_INSTANCE_CONFIG,
    ...(typeof config.defaultInstanceConfig === 'object' && config.defaultInstanceConfig !== null
      ? (config.defaultInstanceConfig as Partial<InstanceConfig>)
      : {}),
  };

  // 自動停止設定のマージ
  const autoStopConfig: AutoStopConfig = {
    ...DEFAULT_AUTO_STOP_CONFIG,
    ...(typeof config.autoStopConfig === 'object' && config.autoStopConfig !== null
      ? (config.autoStopConfig as Partial<AutoStopConfig>)
      : {}),
  };

  return {
    projectName:
      typeof config.projectName === 'string'
        ? config.projectName
        : DEFAULT_PROJECT_CONFIG.projectName,
    environment:
      typeof config.environment === 'string'
        ? config.environment
        : DEFAULT_PROJECT_CONFIG.environment,
    vpcCidr:
      typeof config.vpcCidr === 'string' ? config.vpcCidr : DEFAULT_PROJECT_CONFIG.vpcCidr,
    defaultInstanceConfig,
    autoStopConfig,
    enableElasticIp:
      typeof config.enableElasticIp === 'boolean'
        ? config.enableElasticIp
        : DEFAULT_PROJECT_CONFIG.enableElasticIp,
    users,
  };
}
