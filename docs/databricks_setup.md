# Databricks Setup — Credit Risk Data Platform

This document tracks the Databricks side of the project: what was used,
what wasn't available on Community Edition, and the workarounds applied.
It complements `docs/aws_setup.md` (AWS infra) and `docs/feature_engineering.md`
(the transformation logic being ported here).

## 1. Choice: Community Edition vs a full AWS-integrated workspace

Two options were considered:

- **Databricks Trial on AWS** (14 days, full features: Delta Live Tables,
  Auto Loader, Unity Catalog) — matches the Cerved job requirements exactly,
  but requires deploying a workspace into the AWS account (cross-account
  IAM role via CloudFormation) and carries AWS compute costs during the
  trial
- **Databricks Community Edition** (free, permanent) — no cost, but
  significant feature and access limitations, detailed below

**Decision**: used the existing Community Edition account for the
hands-on Spark/PySpark work, since that logic transfers directly to a
real workspace. Delta Live Tables, Auto Loader, and Unity Catalog remain
conceptually understood but not hands-on practiced in this environment —
documented as a known gap, with a real AWS trial as the planned way to
close it later if needed.

## 2. How production companies integrate Databricks with AWS (for interview context)

Databricks is a SaaS platform, not a native AWS service — it deploys into
the customer's own AWS account:

- **Control plane**: managed by Databricks (UI, notebooks, job scheduler)
- **Data plane**: actual Spark clusters, running as EC2 instances **inside
  the customer's AWS account/VPC**
- Deployed via a Databricks-provided CloudFormation template, creating a
  cross-account IAM role (temporary, scoped) that lets Databricks
  orchestrate compute without permanent full access
- **Unity Catalog** (Premium tier+) connects workspaces to S3 via storage
  credentials / external locations, enabling fine-grained governance
  across workspaces
- Billing is split: Databricks bills DBUs (often via AWS Marketplace,
  consolidated into the AWS bill), AWS separately bills the underlying
  EC2/EBS/S3 usage
- Typical enterprise setup: separate dev/staging/prod workspaces, SSO via
  Okta/Azure AD, service principals for CI/CD (not personal credentials),
  workspace itself often managed via the official Databricks Terraform
  provider

This is fundamentally different from Community Edition, which has no
AWS account integration at all — which is exactly why the features below
aren't available there.

## 3. Community Edition limitations encountered (all same root cause)

Community Edition now runs on **serverless compute with Spark Connect**,
which isolates compute heavily for multi-tenant security. This caused a
chain of related restrictions, all hit while trying to read the raw data
from S3:

| Attempted approach | Result | Root cause |
|---|---|---|
| `spark.conf.set("fs.s3a.access.key", ...)` | `CONFIG_NOT_AVAILABLE` error | Spark Connect blocks direct Hadoop-level filesystem config |
| `dbutils.fs.mkdirs("dbfs:/tmp")` | `DBFS_DISABLED` — public DBFS root disabled | Serverless workspaces disable the public DBFS root by default |
| Download to local disk (`/tmp/...`), read via `file://` | `LocalFilesystemAccessDeniedException` | Spark on serverless compute can only read from paths under `/Workspace` |
| Download to `/Workspace/...`, read directly | **Works** | `/Workspace` is the one filesystem path serverless Spark is allowed to access |
| `df.cache()` / `df.persist()` | `NOT_SUPPORTED_WITH_SERVERLESS` | Serverless compute doesn't support persisting data on the cluster |

**Working pattern for reading data from S3 on Community Edition**:
```python
import boto3

s3 = boto3.client("s3", aws_access_key_id=..., aws_secret_access_key=..., region_name="eu-west-1")
s3.download_file(bucket, key, "/Workspace/tmp_filename.csv")  # streams in chunks, not loaded into memory at once

df = spark.read.option("header", "true").option("inferSchema", "true").csv("/Workspace/tmp_filename.csv")
```

This bypasses `fs.s3a.*` entirely (boto3 makes a direct S3 API call, not a
Spark filesystem call) and works around the DBFS/local-filesystem
restrictions by writing to the one path serverless Spark can read from.

**In a real AWS-integrated workspace**, none of this workaround chain
would be necessary — clusters get direct, secure S3 access through the
instance profile / Unity Catalog external location, and `spark.read.csv("s3a://...")`
works natively.

## 4. Pandas vs Spark DataFrame — practical distinction hit directly in this work

- **Pandas**: single-machine, entirely in RAM, eager execution. Used for
  GMSC (7.5 MB) via `boto3.get_object()` + `pd.read_csv()` +
  `spark.createDataFrame()` — fine at this size
- **Spark**: distributed, partitioned, lazy execution with an optimized
  execution plan, triggered only on an action (`.count()`, `.show()`).
  Necessary for Lending Club (2.26M rows, 145 columns, 1.1 GB) — reading
  it the pandas way would risk exceeding driver memory; reading it
  natively with `spark.read.csv()` (once routed through `/Workspace`)
  lets Spark handle partitioning directly

## 5. Results

- GMSC (150,000 rows, 12 columns): read successfully via
  boto3 → pandas → `spark.createDataFrame()`
- Lending Club (2,260,668 rows, 145 columns): read successfully via
  boto3 streaming download to `/Workspace` → native `spark.read.csv()`,
  confirming row/column counts match the earlier local pandas exploration
  exactly
- Read time for Lending Club with `inferSchema=True`: ~53 seconds — slower
  than a production cluster would be, expected given Community Edition's
  deliberately limited shared compute

## Current status

- [x] Community Edition connected to S3 (via boto3 workaround)
- [x] Both raw datasets read successfully into Spark DataFrames
- [ ] Port feature engineering logic (target creation, leakage removal,
  feature selection — see `docs/feature_engineering.md`) from pandas to
  PySpark
- [ ] Write Silver layer (Delta format) back to S3
- [ ] Delta Live Tables / Auto Loader / Unity Catalog — not available on
  Community Edition, deferred to a possible future AWS trial
