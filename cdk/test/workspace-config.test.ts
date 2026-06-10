import {
    getInstanceConfig,
    resolveElasticIp,
    loadProjectConfig,
    InstanceConfig,
    WorkspaceUserConfig,
} from '../lib/config/workspace-config';
import * as fs from 'fs';

// fsモジュールをモック（スキーマ自体は require で読まれるためモックの影響を受けない）
jest.mock('fs');
const mockedFs = jest.mocked(fs);

const DEFAULT_INSTANCE: InstanceConfig = {
    instanceType: 't3.medium',
    volumeSize: 80,
    volumeType: 'gp3',
};

/** スキーマを満たす完全な設定を返す */
function validConfig(): Record<string, unknown> {
    return {
        projectName: 'my-project',
        environment: 'prod',
        vpcCidr: '172.16.0.0/16',
        defaultInstanceConfig: {
            instanceType: 't3.medium',
            volumeSize: 80,
            volumeType: 'gp3',
        },
        autoStopConfig: {
            cpuThreshold: 5,
            cpuEvaluationMinutes: 10,
            scheduledStopHour: 23,
            scheduledStopMinute: 0,
        },
        enableElasticIp: false,
        users: [
            { username: 'developer1', displayName: 'Dev One' },
            { username: 'developer2' },
        ],
    };
}

/** 指定の設定オブジェクトを読み込ませて loadProjectConfig を実行する */
function loadConfig(config: unknown) {
    mockedFs.existsSync.mockReturnValue(true);
    mockedFs.readFileSync.mockReturnValue(JSON.stringify(config));
    return loadProjectConfig('/path/to/config.json');
}

describe('loadProjectConfig', () => {
    beforeEach(() => {
        jest.clearAllMocks();
    });

    test('スキーマを満たす設定を読み込む', () => {
        const config = loadConfig(validConfig());

        expect(config.projectName).toBe('my-project');
        expect(config.environment).toBe('prod');
        expect(config.vpcCidr).toBe('172.16.0.0/16');
        expect(config.defaultInstanceConfig.instanceType).toBe('t3.medium');
        expect(config.autoStopConfig.cpuThreshold).toBe(5);
        expect(config.enableElasticIp).toBe(false);
        expect(config.users).toHaveLength(2);
        expect(config.users[0].username).toBe('developer1');
        expect(config.users[0].displayName).toBe('Dev One');
    });

    test('$schema キーを含む設定を受け入れる', () => {
        const config = loadConfig({
            $schema: './workspace-config.schema.json',
            ...validConfig(),
        });

        expect(config.projectName).toBe('my-project');
    });

    test('ユーザー個別の instanceConfig の部分指定を受け入れる', () => {
        const raw = validConfig();
        raw.users = [
            { username: 'developer1', instanceConfig: { instanceType: 't3.xlarge' } },
        ];

        const config = loadConfig(raw);

        expect(config.users[0].instanceConfig?.instanceType).toBe('t3.xlarge');
    });

    test('設定ファイルが見つからない場合エラー', () => {
        mockedFs.existsSync.mockReturnValue(false);

        expect(() => loadProjectConfig('/path/to/config.json')).toThrow(
            'Configuration file not found'
        );
    });

    test('設定ファイルのパースエラー時にエラー', () => {
        mockedFs.existsSync.mockReturnValue(true);
        mockedFs.readFileSync.mockReturnValue('{ invalid json }');

        expect(() => loadProjectConfig('/path/to/config.json')).toThrow(
            'Failed to parse configuration file'
        );
    });

    describe('スキーマ違反', () => {
        test.each([
            'projectName',
            'environment',
            'vpcCidr',
            'defaultInstanceConfig',
            'autoStopConfig',
            'enableElasticIp',
            'users',
        ])('必須項目 %s の欠落でエラー', (key) => {
            const raw = validConfig();
            delete raw[key];

            expect(() => loadConfig(raw)).toThrow('violates workspace-config.schema.json');
        });

        test('users が空配列の場合エラー', () => {
            const raw = validConfig();
            raw.users = [];

            expect(() => loadConfig(raw)).toThrow('violates workspace-config.schema.json');
        });

        test('username のパターン違反でエラー', () => {
            const raw = validConfig();
            raw.users = [{ username: 'Invalid-User' }];

            expect(() => loadConfig(raw)).toThrow('violates workspace-config.schema.json');
        });

        test('username が無いユーザーはエラー', () => {
            const raw = validConfig();
            raw.users = [{ displayName: 'Dev One' }];

            expect(() => loadConfig(raw)).toThrow('violates workspace-config.schema.json');
        });

        test('未知のキー（typo）はエラー', () => {
            const raw = { ...validConfig(), enableElasticIP: true };

            expect(() => loadConfig(raw)).toThrow('violates workspace-config.schema.json');
        });

        test('型違反（enableElasticIp が文字列）はエラー', () => {
            const raw = validConfig();
            raw.enableElasticIp = 'yes';

            expect(() => loadConfig(raw)).toThrow('violates workspace-config.schema.json');
        });

        test('明示的な null はエラー', () => {
            const raw = validConfig();
            raw.defaultInstanceConfig = null;

            expect(() => loadConfig(raw)).toThrow('violates workspace-config.schema.json');
        });

        test('environment の enum 違反でエラー', () => {
            const raw = validConfig();
            raw.environment = 'production';

            expect(() => loadConfig(raw)).toThrow('violates workspace-config.schema.json');
        });

        test('autoStopConfig の必須項目欠落でエラー', () => {
            const raw = validConfig();
            raw.autoStopConfig = { cpuThreshold: 5 };

            expect(() => loadConfig(raw)).toThrow('violates workspace-config.schema.json');
        });

        test('volumeSize の範囲違反でエラー', () => {
            const raw = validConfig();
            raw.defaultInstanceConfig = {
                instanceType: 't3.medium',
                volumeSize: 10,
                volumeType: 'gp3',
            };

            expect(() => loadConfig(raw)).toThrow('violates workspace-config.schema.json');
        });

        test('エラーメッセージに違反箇所のパスが含まれる', () => {
            const raw = validConfig();
            raw.users = [{ username: 'Invalid-User' }];

            expect(() => loadConfig(raw)).toThrow('/users/0/username');
        });
    });
});

describe('getInstanceConfig', () => {
    test('デフォルト設定を返す（ユーザー設定なし）', () => {
        const userConfig: WorkspaceUserConfig = {
            username: 'testuser',
        };

        const result = getInstanceConfig(userConfig, DEFAULT_INSTANCE);

        expect(result).toEqual(DEFAULT_INSTANCE);
    });

    test('ユーザー設定で一部をオーバーライド', () => {
        const userConfig: WorkspaceUserConfig = {
            username: 'testuser',
            instanceConfig: {
                instanceType: 't3.small',
            },
        };

        const result = getInstanceConfig(userConfig, DEFAULT_INSTANCE);

        expect(result.instanceType).toBe('t3.small');
        expect(result.volumeSize).toBe(80); // デフォルト
        expect(result.volumeType).toBe('gp3'); // デフォルト
    });

    test('ユーザー設定で全てをオーバーライド', () => {
        const userConfig: WorkspaceUserConfig = {
            username: 'testuser',
            instanceConfig: {
                instanceType: 't3.xlarge',
                volumeSize: 200,
                volumeType: 'gp2',
            },
        };

        const result = getInstanceConfig(userConfig, DEFAULT_INSTANCE);

        expect(result.instanceType).toBe('t3.xlarge');
        expect(result.volumeSize).toBe(200);
        expect(result.volumeType).toBe('gp2');
    });
});

describe('resolveElasticIp', () => {
    test('ユーザー設定なし、プロジェクトデフォルト false → false', () => {
        const userConfig: WorkspaceUserConfig = { username: 'testuser' };
        expect(resolveElasticIp(userConfig, false)).toBe(false);
    });

    test('ユーザー設定なし、プロジェクトデフォルト true → true', () => {
        const userConfig: WorkspaceUserConfig = { username: 'testuser' };
        expect(resolveElasticIp(userConfig, true)).toBe(true);
    });

    test('ユーザー true、プロジェクトデフォルト false → true', () => {
        const userConfig: WorkspaceUserConfig = { username: 'testuser', enableElasticIp: true };
        expect(resolveElasticIp(userConfig, false)).toBe(true);
    });

    test('ユーザー false、プロジェクトデフォルト true → false', () => {
        const userConfig: WorkspaceUserConfig = { username: 'testuser', enableElasticIp: false };
        expect(resolveElasticIp(userConfig, true)).toBe(false);
    });
});
