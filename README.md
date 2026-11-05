# dba-reports-setup

Schedule DBA compliance reports from a Linux jump box. One read-only IAM role (`dbops_compliance_role`) in every account; the jump box assumes it; cron runs the reports and mails results.

Reports this kit wires up:

| Report | Tool folder | Script |
|--------|-------------|--------|
| Patch compliance | `rds-patch-compliance` | `rds_patch_compliance_report.sh` (+ optional summary) |
| Backup compliance | `rds-backup-compliance` | `rds_backup_compliance_report.sh` |
| Inventory explorer | `rds-inventory-explorer` | `rds_inventory_explorer.sh` |

GitHub releases ship as `<tool>.zip` + `<tool>.zip.sha256` from `manideepgrandhi/<tool>`.

## 1. Create the role in each account

Files in `iam/`:

- `dbops_compliance_role-policy.json` — read-only permissions
- `dbops_compliance_role-trust.json` — trusts only your jump box role (placeholder `JUMPBOX_ROLE_ARN`)
- `jumpbox-assume-policy.json` — attach to the jump box role so it can assume `dbops_compliance_role` in any account
- `create_role.sh` — create or update the role from an admin profile

```bash
# Once per account (admin credentials / profile):
./iam/create_role.sh --profile prod \
  --jumpbox-role-arn arn:aws:iam::JUMPBOX_ACCOUNT:role/YOUR_JUMPBOX_ROLE

# Preview without calling AWS:
./iam/create_role.sh --profile prod --jumpbox-role-arn arn:aws:iam::123456789012:role/jumpbox --dry-run
```

**Manual console steps** (if you prefer not to use the script):

1. IAM → Roles → Create role → Custom trust policy → paste `dbops_compliance_role-trust.json` with `JUMPBOX_ROLE_ARN` replaced by your jump box role ARN.
2. Name the role `dbops_compliance_role`. Max session duration 1 hour.
3. Add an inline policy named `dbops_compliance_role_policy` using `dbops_compliance_role-policy.json`.
4. On the jump box role, attach `jumpbox-assume-policy.json` (or merge its statement).

## 2. Set up the jump box

```bash
sudo ./setup/setup_jumpbox.sh          # or --dry-run first
```

Creates user `dbareports` (nologin, no sudo) and `/opt/dba-reports/{tools,conf,bin,output,data,logs}`. Checks for AWS CLI v2, `jq`, `flock`, `unzip`, `mailx`.

Install tools (after each release):

```bash
sudo -u dbareports ./setup/install_tool.sh --tool rds-patch-compliance --version v1.5.1
sudo -u dbareports ./setup/install_tool.sh --tool rds-backup-compliance --version vX.Y.Z
sudo -u dbareports ./setup/install_tool.sh --tool rds-inventory-explorer --version vX.Y.Z
```

Copy `bin/run_reports.sh` and `bin/check_logs.sh` into `/opt/dba-reports/bin/`, and `conf/run_reports.conf.example` to `/opt/dba-reports/conf/run_reports.conf` (chmod 640). Uncomment what you need — every setting starts commented out.

## 3. AWS profiles

Copy `setup/aws_config.example` to `~dbareports/.aws/config`. Uncomment one `[profile …]` block per account. No access keys on disk — the jump box role assumes `dbops_compliance_role`.

## 4. Cron + mail + log check

1. Uncomment `profiles = …` and `alert_emails = …` in `run_reports.conf`.
2. Test by hand: `/opt/dba-reports/bin/run_reports.sh daily`
3. Install `cron/dbareports.crontab.example` for user `dbareports` (uncomment the lines you want).

Defaults: daily 06:00 (patch + backup), weekly Mon 07:00 (inventory), log checks 30 minutes later. `CRON_TZ=Asia/Kolkata`.

Each run writes `logs/run_<schedule>_<YYYYMMDD_HHMMSS>.log`, prints every output file’s full path, and (when `alert_emails` is set) sends one `mailx` summary. Attachments stay off until you set `mail_attach = yes`.

`check_logs.sh` mails only on problems: missing today’s run, failed status, `ERROR` / `AccessDenied` / `ExpiredToken` in the log, or missing output files. Set `check_mail_on_ok = yes` for a daily OK mail.

## IAM actions in the role

| Action | Used by |
|--------|---------|
| `rds:Describe*` | All three tools (clusters, instances, snapshots, globals, engine versions, parameters, certificates, pending maintenance, …) |
| `rds:ListTagsForResource` | Reserved (tags today come inside Describe responses) |
| `docdb:DescribeDBEngineVersions` | Patch (DocumentDB engine lookup) |
| `neptune:DescribeDBEngineVersions` | Patch (Neptune engine lookup) |
| `backup:ListBackupVaults` | Backup |
| `backup:ListRecoveryPointsByBackupVault` | Backup |
| `backup:ListBackupPlans` | Reserved for other / future reports |
| `backup:GetBackupPlan` | Reserved for other / future reports |
| `backup:ListProtectedResources` | Reserved for other / future reports |
| `sts:GetCallerIdentity` | All three |
| `iam:ListAccountAliases` | Patch (account display name) |
| `ec2:DescribeRegions` | All three (`-A` / `--all-regions`) |

No write actions. Mapped from each tool’s `aws <service> <operation>` calls.

## Layout

```
/opt/dba-reports/
  tools/<tool>/<version>/   installed releases
  tools/<tool>/current ->   active version
  conf/run_reports.conf
  bin/run_reports.sh
  bin/check_logs.sh
  output/<report>/YYYY/MM/  HTML + CSV (names include account number)
  data/                     optional --save-data JSON
  logs/                     run_*.log + run_*.status + cron.log
```

## Safety

- Role is read-only; no long-term keys on the jump box.
- Config is parsed as `key = value` (never `source` / `eval`).
- Retention deletes only under `output/` and `logs/`, and only when you set a positive day count.
- Mail body goes to `mailx` on stdin; content is never passed through a shell.
