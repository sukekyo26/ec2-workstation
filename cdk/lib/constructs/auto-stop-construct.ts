import * as cdk from 'aws-cdk-lib';
import * as cloudwatch from 'aws-cdk-lib/aws-cloudwatch';
import * as cloudwatchActions from 'aws-cdk-lib/aws-cloudwatch-actions';
import * as ec2 from 'aws-cdk-lib/aws-ec2';
import * as iam from 'aws-cdk-lib/aws-iam';
import * as scheduler from 'aws-cdk-lib/aws-scheduler';
import { Construct } from 'constructs';

/**
 * Auto Stop Constructのプロパティ
 */
export interface AutoStopConstructProps {
    /** EC2インスタンス */
    readonly instance: ec2.Instance;
    /** プロジェクト名 */
    readonly projectName: string;
    /** 環境名 */
    readonly environment: string;
    /** ユーザー名 */
    readonly username: string;
    /** CPU使用率閾値（%）- この値以下が続くと停止 */
    readonly cpuThreshold?: number;
    /** CPU監視期間（分）- この期間低負荷が続くと停止 */
    readonly cpuEvaluationPeriods?: number;
    /** 定時停止時刻（Asia/Tokyo、0-23） */
    readonly scheduledStopHour?: number;
    /** 定時停止分（0-59） */
    readonly scheduledStopMinute?: number;
}

/**
 * Auto Stop Construct
 * EC2インスタンスの自動停止機能を提供
 * - CPU使用率が低い状態が続くと自動停止（CloudWatch Alarm）
 * - 毎日指定時刻に自動停止（EventBridge Scheduler）
 */
export class AutoStopConstruct extends Construct {
    /** CPU監視用CloudWatch Alarm */
    public readonly cpuAlarm: cloudwatch.Alarm;
    /** 定時停止用EventBridge Schedule */
    public readonly stopSchedule: scheduler.CfnSchedule;
    /** EventBridge Scheduler用IAMロール */
    public readonly schedulerRole: iam.Role;

    constructor(scope: Construct, id: string, props: AutoStopConstructProps) {
        super(scope, id);

        const resourcePrefix = `${props.projectName}-${props.environment}-${props.username}`;
        const cpuThreshold = props.cpuThreshold ?? 5;
        const cpuEvaluationPeriods = props.cpuEvaluationPeriods ?? 2; // 2期間 x 5分 = 10分
        const scheduledStopHour = props.scheduledStopHour ?? 23;
        const scheduledStopMinute = props.scheduledStopMinute ?? 0;

        // ============================================
        // CPU監視による自動停止（CloudWatch Alarm + EC2 Stop Action）
        // ============================================

        // CPU使用率メトリクス
        const cpuMetric = new cloudwatch.Metric({
            namespace: 'AWS/EC2',
            metricName: 'CPUUtilization',
            dimensionsMap: {
                InstanceId: props.instance.instanceId,
            },
            period: cdk.Duration.minutes(5),
            statistic: 'Average',
        });

        // CloudWatch Alarm: CPU使用率が閾値以下で発火
        this.cpuAlarm = new cloudwatch.Alarm(this, 'CpuLowAlarm', {
            alarmName: `${resourcePrefix}-cpu-low-alarm`,
            alarmDescription: `Stop EC2 instance when CPU < ${cpuThreshold}% for ${cpuEvaluationPeriods * 5} minutes`,
            metric: cpuMetric,
            threshold: cpuThreshold,
            evaluationPeriods: cpuEvaluationPeriods,
            comparisonOperator: cloudwatch.ComparisonOperator.LESS_THAN_THRESHOLD,
            treatMissingData: cloudwatch.TreatMissingData.NOT_BREACHING,
        });

        // Alarm Action: EC2インスタンスを停止
        this.cpuAlarm.addAlarmAction(
            new cloudwatchActions.Ec2Action(cloudwatchActions.Ec2InstanceAction.STOP)
        );

        // ============================================
        // 定時停止（EventBridge Scheduler）
        // ============================================

        // EventBridge Scheduler用IAMロール
        this.schedulerRole = new iam.Role(this, 'SchedulerRole', {
            roleName: `${resourcePrefix}-scheduler-role`,
            assumedBy: new iam.ServicePrincipal('scheduler.amazonaws.com'),
            description: `IAM role for EventBridge Scheduler to stop EC2 instance for ${props.username}`,
        });

        // EC2停止権限を付与
        this.schedulerRole.addToPolicy(
            new iam.PolicyStatement({
                effect: iam.Effect.ALLOW,
                actions: ['ec2:StopInstances'],
                resources: [
                    `arn:aws:ec2:${cdk.Stack.of(this).region}:${cdk.Stack.of(this).account}:instance/${props.instance.instanceId}`,
                ],
            })
        );

        // EventBridge Schedule: 毎日指定時刻に停止
        // cron式: 分 時 日 月 曜日 年 (UTCではなくタイムゾーン指定)
        this.stopSchedule = new scheduler.CfnSchedule(this, 'StopSchedule', {
            name: `${resourcePrefix}-daily-stop`,
            description: `Stop EC2 instance daily at ${scheduledStopHour}:${scheduledStopMinute.toString().padStart(2, '0')} JST for ${props.username}`,
            scheduleExpression: `cron(${scheduledStopMinute} ${scheduledStopHour} * * ? *)`,
            scheduleExpressionTimezone: 'Asia/Tokyo',
            flexibleTimeWindow: {
                mode: 'OFF',
            },
            state: 'ENABLED',
            target: {
                arn: `arn:aws:scheduler:::aws-sdk:ec2:stopInstances`,
                roleArn: this.schedulerRole.roleArn,
                input: JSON.stringify({
                    InstanceIds: [props.instance.instanceId],
                }),
            },
        });

        // タグ付け
        cdk.Tags.of(this.cpuAlarm).add('Owner', props.username);
        cdk.Tags.of(this.schedulerRole).add('Owner', props.username);
    }
}
