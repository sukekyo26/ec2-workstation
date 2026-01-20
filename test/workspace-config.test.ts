import {
    validateUsername,
    getInstanceConfig,
    loadProjectConfig,
    validateAndParseConfig,
    DEFAULT_INSTANCE_CONFIG,
    DEFAULT_AUTO_STOP_CONFIG,
    DEFAULT_PROJECT_CONFIG,
    WorkspaceUserConfig,
} from '../lib/config/workspace-config';
import * as fs from 'fs';
import * as path from 'path';

// fsモジュールをモック
jest.mock('fs');
const mockedFs = jest.mocked(fs);

describe('workspace-config', () => {
    beforeEach(() => {
        jest.clearAllMocks();
    });

    describe('validateUsername', () => {
        test('有効なユーザー名を受け入れる', () => {
            expect(validateUsername('developer1')).toBe(true);
            expect(validateUsername('dev-user')).toBe(true);
            expect(validateUsername('dev_user')).toBe(true);
            expect(validateUsername('abc')).toBe(true);
            expect(validateUsername('user123')).toBe(true);
            expect(validateUsername('a1b2c3')).toBe(true);
        });

        test('無効なユーザー名を拒否する - 短すぎる', () => {
            expect(validateUsername('ab')).toBe(false);
            expect(validateUsername('a')).toBe(false);
            expect(validateUsername('')).toBe(false);
        });

        test('無効なユーザー名を拒否する - 特殊文字で始まる', () => {
            expect(validateUsername('-developer')).toBe(false);
            expect(validateUsername('_developer')).toBe(false);
        });

        test('無効なユーザー名を拒否する - 特殊文字で終わる', () => {
            expect(validateUsername('developer-')).toBe(false);
            expect(validateUsername('developer_')).toBe(false);
        });

        test('無効なユーザー名を拒否する - 禁止文字を含む', () => {
            expect(validateUsername('dev.user')).toBe(false);
            expect(validateUsername('dev@user')).toBe(false);
            expect(validateUsername('dev user')).toBe(false);
            expect(validateUsername('Developer')).toBe(false); // 大文字
        });
    });

    describe('loadProjectConfig', () => {
        test('設定ファイルからプロジェクト設定を読み込む', () => {
            const configContent = JSON.stringify({
                projectName: 'my-project',
                environment: 'prod',
                vpcCidr: '172.16.0.0/16',
                users: [
                    { username: 'developer1', displayName: 'Dev One' },
                    { username: 'developer2' },
                ],
            });

            mockedFs.existsSync.mockReturnValue(true);
            mockedFs.readFileSync.mockReturnValue(configContent);

            const config = loadProjectConfig('/path/to/config.json');

            expect(config.projectName).toBe('my-project');
            expect(config.environment).toBe('prod');
            expect(config.vpcCidr).toBe('172.16.0.0/16');
            expect(config.users).toHaveLength(2);
            expect(config.users[0].username).toBe('developer1');
            expect(config.users[0].displayName).toBe('Dev One');
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
    });

    describe('validateAndParseConfig', () => {
        test('最小限の設定を受け入れる', () => {
            const rawConfig = {
                users: [{ username: 'developer1' }],
            };

            const config = validateAndParseConfig(rawConfig);

            expect(config.projectName).toBe(DEFAULT_PROJECT_CONFIG.projectName);
            expect(config.environment).toBe(DEFAULT_PROJECT_CONFIG.environment);
            expect(config.vpcCidr).toBe(DEFAULT_PROJECT_CONFIG.vpcCidr);
            expect(config.users).toHaveLength(1);
        });

        test('完全な設定を受け入れる', () => {
            const rawConfig = {
                projectName: 'custom-project',
                environment: 'staging',
                vpcCidr: '10.1.0.0/16',
                defaultInstanceConfig: {
                    instanceType: 't3.medium',
                    volumeSize: 50,
                    volumeType: 'gp3',
                },
                users: [
                    { username: 'developer1', displayName: 'Dev One' },
                    { username: 'developer2' },
                ],
            };

            const config = validateAndParseConfig(rawConfig);

            expect(config.projectName).toBe('custom-project');
            expect(config.environment).toBe('staging');
            expect(config.defaultInstanceConfig.instanceType).toBe('t3.medium');
            expect(config.users).toHaveLength(2);
        });

        test('ユーザーが空の場合エラー', () => {
            const rawConfig = { users: [] };

            expect(() => validateAndParseConfig(rawConfig)).toThrow(
                'at least one user'
            );
        });

        test('usersが配列でない場合エラー', () => {
            const rawConfig = { users: 'not-an-array' };

            expect(() => validateAndParseConfig(rawConfig)).toThrow(
                'at least one user'
            );
        });

        test('無効なユーザー名の場合エラー', () => {
            const rawConfig = {
                users: [{ username: 'Invalid-User' }],
            };

            expect(() => validateAndParseConfig(rawConfig)).toThrow(
                'Invalid username'
            );
        });

        test('ユーザーにusernameがない場合エラー', () => {
            const rawConfig = {
                users: [{ displayName: 'Dev One' }],
            };

            expect(() => validateAndParseConfig(rawConfig)).toThrow(
                'username'
            );
        });

        test('設定がオブジェクトでない場合エラー', () => {
            expect(() => validateAndParseConfig(null)).toThrow(
                'Configuration must be an object'
            );
            expect(() => validateAndParseConfig('string')).toThrow(
                'Configuration must be an object'
            );
        });
    });

    describe('getInstanceConfig', () => {
        test('デフォルト設定を返す（ユーザー設定なし）', () => {
            const userConfig: WorkspaceUserConfig = {
                username: 'testuser',
            };

            const result = getInstanceConfig(userConfig);

            expect(result).toEqual(DEFAULT_INSTANCE_CONFIG);
            expect(result.instanceType).toBe('t3.medium');
            expect(result.volumeSize).toBe(80);
            expect(result.volumeType).toBe('gp3');
        });

        test('ユーザー設定で一部をオーバーライド', () => {
            const userConfig: WorkspaceUserConfig = {
                username: 'testuser',
                instanceConfig: {
                    instanceType: 't3.small',
                },
            };

            const result = getInstanceConfig(userConfig);

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

            const result = getInstanceConfig(userConfig);

            expect(result.instanceType).toBe('t3.xlarge');
            expect(result.volumeSize).toBe(200);
            expect(result.volumeType).toBe('gp2');
        });

        test('カスタムデフォルト設定を使用', () => {
            const userConfig: WorkspaceUserConfig = {
                username: 'testuser',
            };

            const customDefault = {
                instanceType: 't3.small',
                volumeSize: 50,
                volumeType: 'gp3' as const,
            };

            const result = getInstanceConfig(userConfig, customDefault);

            expect(result.instanceType).toBe('t3.small');
            expect(result.volumeSize).toBe(50);
        });
    });

    describe('DEFAULT_INSTANCE_CONFIG', () => {
        test('デフォルト値が正しい', () => {
            expect(DEFAULT_INSTANCE_CONFIG.instanceType).toBe('t3.medium');
            expect(DEFAULT_INSTANCE_CONFIG.volumeSize).toBe(80);
            expect(DEFAULT_INSTANCE_CONFIG.volumeType).toBe('gp3');
        });
    });

    describe('DEFAULT_AUTO_STOP_CONFIG', () => {
        test('デフォルト値が正しい', () => {
            expect(DEFAULT_AUTO_STOP_CONFIG.cpuThreshold).toBe(5);
            expect(DEFAULT_AUTO_STOP_CONFIG.cpuEvaluationMinutes).toBe(10);
            expect(DEFAULT_AUTO_STOP_CONFIG.scheduledStopHour).toBe(23);
            expect(DEFAULT_AUTO_STOP_CONFIG.scheduledStopMinute).toBe(0);
        });
    });

    describe('validateAndParseConfig - autoStopConfig', () => {
        test('autoStopConfigが省略された場合デフォルト値を使用', () => {
            const rawConfig = {
                users: [{ username: 'developer1' }],
            };

            const config = validateAndParseConfig(rawConfig);

            expect(config.autoStopConfig).toEqual(DEFAULT_AUTO_STOP_CONFIG);
        });

        test('autoStopConfigの一部を指定した場合、残りはデフォルト値', () => {
            const rawConfig = {
                users: [{ username: 'developer1' }],
                autoStopConfig: {
                    cpuThreshold: 10,
                    scheduledStopHour: 22,
                },
            };

            const config = validateAndParseConfig(rawConfig);

            expect(config.autoStopConfig.cpuThreshold).toBe(10);
            expect(config.autoStopConfig.cpuEvaluationMinutes).toBe(10); // デフォルト
            expect(config.autoStopConfig.scheduledStopHour).toBe(22);
            expect(config.autoStopConfig.scheduledStopMinute).toBe(0); // デフォルト
        });

        test('autoStopConfigを完全に指定', () => {
            const rawConfig = {
                users: [{ username: 'developer1' }],
                autoStopConfig: {
                    cpuThreshold: 15,
                    cpuEvaluationMinutes: 20,
                    scheduledStopHour: 21,
                    scheduledStopMinute: 30,
                },
            };

            const config = validateAndParseConfig(rawConfig);

            expect(config.autoStopConfig.cpuThreshold).toBe(15);
            expect(config.autoStopConfig.cpuEvaluationMinutes).toBe(20);
            expect(config.autoStopConfig.scheduledStopHour).toBe(21);
            expect(config.autoStopConfig.scheduledStopMinute).toBe(30);
        });
    });
});
