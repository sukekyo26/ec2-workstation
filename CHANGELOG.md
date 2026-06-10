# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Add OpenTofu implementation (`opentofu/`) that provisions the same infrastructure as the CDK implementation, sharing `workspace-config.json`, `shared/user-data.sh`, and the operation scripts

## [0.1.0] - 2026-04-14

### Added

- Add modular CDK architecture with separate VPC, Security, EC2, and AutoStop constructs
- Add JSON-based workspace configuration (`workspace-config.json`) with JSON Schema validation
- Add NetworkStack (shared VPC/Subnet/IGW) and WorkspaceStack (per-user EC2) separation
- Add SessionManager-based secure connectivity (no SSH port exposure, IAM authentication)
- Add Security Group with all inbound blocked and outbound limited to HTTPS/HTTP/DNS
- Add EBS encryption with AWS managed keys and IMDSv2 enforcement
- Add VPC Flow Logs (REJECT only) with 1-month retention for security audit compliance
- Add SSH key pair generation and storage in SSM Parameter Store for Remote-SSH connectivity
- Add setup scripts for VS Code Remote-SSH (PowerShell for Windows, shell for Linux/Mac)
- Add auto-start feature via ProxyCommand that starts stopped EC2 instances on SSH connection
- Add auto-stop features with CloudWatch CPU alarm and EventBridge scheduled stop
- Add customizable auto-stop configuration (`autoStopConfig`) in `workspace-config.json`
- Add user-data script with Docker, AWS CLI v2, Git, and development tools pre-installation
- Add SSH host key checking skip configuration for seamless remote connections
- Add per-user instance configuration override support
- Add optional Elastic IP (static public IP) support with project-level default and per-user override
- Add comprehensive test coverage for all constructs and stacks

### Fixed

- Fix shell syntax error in `scripts/start-ec2.sh` (`fi` instead of `}` closing a function, C-style for loop replaced with while loop)
