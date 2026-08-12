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

## 2b. Git integration in the Databricks UI vs the real production pattern

Databricks' built-in Git folder integration (clone a GitHub repo, edit
notebooks, "Commit & Push" from the UI) turned out to be unreliable on
Community Edition in this project: after a blocked push (see §6, secret
exposure), the Git panel repeatedly showed "No changed files" even after
edits, and no standalone "Push" action was available in the branch menu
(only Merge branch / Rebase branch / Remote branch history / Reset hard).

**Resolution**: deleting the Git folder entirely and re-cloning from
scratch eventually fixed it — verified with an isolated test (a trivial
edit to an existing file, checked for detection in the Git panel) before
trusting it enough to commit real work again. Until that was confirmed,
notebooks were exported (File → Export → Source File) and
committed/pushed from the local machine using the same Git workflow
already used for `infra/` and `docs/` — a viable fallback that was used
for one round of commits.

**Why this isn't just a workaround — it's closer to how production teams
actually work**: enterprise Databricks usage generally does **not** rely
on the in-browser Git integration for real delivery. The standard pattern
is:
1. Code (notebooks converted to `.py` modules, job configs) lives in the
   engineer's local Git repo / IDE, same as any other codebase
2. **Databricks Asset Bundles (DABs)** define jobs, pipelines, and
   resources as YAML files inside that repo
3. CI/CD (e.g. GitHub Actions) runs `databricks bundle deploy` on every
   push to main — no one manually commits from inside the Databricks UI

This directly parallels the Terraform local-vs-enterprise distinction
noted in `docs/aws_setup.md`: in both cases, the interactive tool (AWS
Console / Databricks UI) is for exploration, and the actual deployment is
driven by CLI/CI-CD from version-controlled config, not manual clicks.
The export-and-commit-locally workflow adopted here is, in that sense,
closer to the real pattern than a working "Commit & Push" button would
have been.

## 2c. Databricks CLI — role in production (for interview context)

The CLI isn't used interactively day-to-day; it's an automation tool:
- **Inside CI/CD pipelines**: `databricks bundle deploy`, run non-interactively
- **Secrets provisioning**: `databricks secrets create-scope` / `put` —
  scripted once during setup, not repeated manually (used in this project,
  see §6)
- **Job orchestration from other tools**: e.g. an Airflow DAG triggering a
  Databricks job via CLI/API instead of a human clicking "Run"
- **Local development via Databricks Connect**: writing/testing PySpark
  code in a local IDE against a remote cluster, without opening the
  browser at all

Same philosophy as Terraform CLI for AWS: the web UI is for exploration
and debugging, the CLI/API is for anything that needs to be repeatable
without human intervention.

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

## 4b. Why Spark was slower than local pandas for iterative column checks

Computing a per-column statistic (e.g. checking near-constant columns)
across 79 columns took roughly 20-25 seconds **per column** when looping
`df.groupBy(col).count()` in Spark — around 30 minutes total. The same
kind of check had been near-instant in local pandas. This looked
counter-intuitive ("isn't Spark supposed to be faster on big data?") but
has a clear explanation:

- **Pandas was fast because the data was read once and stayed in RAM** —
  every subsequent operation reused that in-memory copy
- **Spark is lazy, and without `cache()`/`persist()` (blocked on
  serverless — see §3), every single action re-triggers the full
  computation from the raw file on disk.** Looping over 79 columns meant
  re-reading and reprocessing the 1.1 GB file 79 times, not once
- Distributed execution also carries fixed overhead (task scheduling,
  potential shuffle for `groupBy`, gRPC round-trips via Spark Connect)
  that only pays off when data exceeds a single machine's capacity —
  for a dataset that comfortably fits in memory, that overhead is pure
  cost with no benefit

**Takeaway for the interview**: Spark isn't unconditionally faster than
pandas — it wins when data doesn't fit on one machine, especially with
caching available on a real (non-shared, non-serverless) cluster. Most of
the slowdown observed here is attributable to Community Edition's
specific restrictions, not an inherent Spark limitation.

**Attempted fix — sampling made it worse, not better**: switching from a
full-dataset loop to a 10%-sample loop (`df.sample(0.1)`) did **not**
speed things up, for the same root cause: `.sample()` is also lazy, so
each column's `groupBy` still re-triggered a fresh read-and-resample of
the full raw file. The actual fix was materializing the sample **once**
via `.toPandas()` (forcing a single Spark computation), then doing all 79
per-column checks in pandas against that already-in-memory sample.

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
- Target variable applied in PySpark: 1,303,637 resolved loans out of
  2,260,668 total (1,041,952 Fully Paid / 261,685 default — ~20% default
  rate), matching the logic in `docs/feature_engineering.md` §2
- Leakage columns dropped: 137 columns remaining (145 − 9 leakage + 1
  `target`), later corrected to 43 after §7's fix
- High-missing columns (>50%) dropped: 79 columns remaining (137 − 58)
- Near-constant columns dropped: 74 columns remaining (79 − 5: `pymnt_plan`,
  `acc_now_delinq`, `chargeoff_within_12_mths`, `hardship_flag`,
  `disbursement_method`)
- Correlation-based dedup (threshold 0.85, via `pyspark.ml.stat.Correlation`):
  9 pairs found, 5 columns dropped (`funded_amnt`, `funded_amnt_inv`,
  `num_rev_tl_bal_gt_0`, `total_il_high_credit_limit`, `bc_open_to_buy`) —
  `installment` kept despite 0.95 corr with `loan_amnt` (same reasoning as
  the local pandas pass: it also encodes rate and term)
- Family-based selection (pure column drops, no computation): 47 columns
  remaining
- Additional leakage fix (§7): **43 columns remaining**, final feature set

## 5b. Performance lessons — which Spark APIs scaled and which didn't

This was the most time-consuming part of the whole Databricks phase, and
worth documenting precisely since it's a good interview topic (knowing
*which* Spark tool fits *which* problem, not just that "Spark is
distributed"):

| Task | Approach that was slow | Approach that worked | Why |
|---|---|---|---|
| Missing value ratio (137 cols) | — | Single `df.select([...])` with one expression per column | Already a single pass, fine as-is |
| Near-constant check (79 cols) | Loop of `df.groupBy(c).count().orderBy(...).limit(1)` per column — ~20-25s **each**, ~30 min total | `approx_count_distinct` in one pass to shortlist low-cardinality candidates (23 of 79), then exact `groupBy` only on those | The expensive exact check was reduced from 79 columns to 23 by a cheap approximate pre-filter |
| Near-constant check, first attempt at a shortcut | `df.stat.freqItems()` | — | Wrong tool: returns candidate frequent values, not their coverage ratio — produced false positives (flagged 79/79 columns, including `target`) |
| Correlation matrix (37 numeric cols) | (would have been) one query per column pair | `pyspark.ml.stat.Correlation.corr()` on a `VectorAssembler`-built feature vector — one distributed pass, ~3.5 min total | Purpose-built distributed algorithm instead of a manual pairwise loop |
| Sampling for near-constant check | `df.sample(0.1)` then per-column `groupBy` in a loop | Materializing the sample once via `.toPandas()`, then checking in pandas | `.sample()` is lazy — looping after it still re-triggered the full upstream computation (file read + filters) on every iteration |
| Writing an intermediate Parquet checkpoint | `df.write.parquet("/Workspace/...")` | Not resolved — failed with a Hadoop `Mkdirs` error | Distributed writes need per-executor filesystem access that `/Workspace` doesn't support the way it supports single-process boto3/Python file I/O |

**General takeaway**: manual per-column loops are the main scaling failure
mode on this constrained compute — whenever a purpose-built distributed
Spark API exists for the task (`approx_count_distinct`, `Correlation.corr`),
it was dramatically faster than the equivalent manual loop, even on the
same restricted cluster.

## 6. Security incident — AWS key committed to a notebook, blocked by GitHub

Early in this work, `dbutils.widgets` were used to pass AWS credentials
into the notebook interactively. This turned out to be unsafe: widget
values are serialized into the notebook's `.ipynb` file when committed,
so the access key and secret ended up written into the file at commit
time. GitHub's push protection detected and blocked the push before it
reached the repository.

**Remediation taken**:
1. The exposed access key was deactivated and deleted in AWS IAM
2. A new access key was generated via `terraform apply -replace=...`
   (see `infra/databricks_iam_user.tf`)
3. Credentials were moved to **Databricks Secrets**
   (`dbutils.secrets.get(...)`), which are never serialized into the
   notebook file and print as `[REDACTED]` if accidentally displayed

**Takeaway**: even though the push was rejected, the credential is
treated as compromised — it was transmitted over the network to GitHub's
servers as part of the push attempt, which is enough to warrant rotation
regardless of whether it was ultimately stored.

## 7. Additional leakage found during the Spark port

While porting the feature selection to PySpark, four columns were found
still present after the initial leakage-removal step that shouldn't have
been: `out_prncp`, `total_pymnt`, `recoveries`, `last_pymnt_d`. All are
post-origination fields (outstanding principal, total paid so far,
amount recovered after default, date of last payment) — same category as
the `_inv` variants and `last_pymnt_amnt` that had already been correctly
dropped, but these specific ones were missed when the original leakage
list was written by hand during local pandas exploration. They weren't
caught by the missing-value or near-constant filters because they're
populated for every resolved loan, just not knowable at loan application
time.

**This is also a gap in the local pandas feature set** built earlier in
this project (`docs/feature_engineering.md`) — noted there as well.
Dropped here via:
```python
additional_leakage = ["out_prncp", "total_pymnt", "recoveries", "last_pymnt_d"]
df_lc_resolved = df_lc_resolved.drop(*[c for c in additional_leakage if c in df_lc_resolved.columns])
```

## 8. Writing the Silver layer — S3 write restriction and the pandas fallback

Direct Delta write from Spark to S3 (`df.write.format("delta").save("s3a://...")`)
failed with `CloudAccessDeniedException` (403 Forbidden). Root cause: the
boto3 credentials (via Secrets) authenticate boto3 itself, not Spark —
Spark has no valid S3 credentials on this compute (same underlying gap as
the `fs.s3a.*` config restriction in §3, just surfacing differently here
since Spark did attempt the call rather than rejecting it outright).

**Fallback used** (same boto3 pattern as reading raw data): materialize
to pandas, write Parquet locally to `/Workspace`, then `s3.upload_file()`.

```python
pdf_silver = df_lc_resolved.toPandas()
pdf_silver.attrs.clear()  # see note below — required on Spark Connect
pdf_silver.to_parquet("/Workspace/lc_silver.parquet")
s3.upload_file("/Workspace/lc_silver.parquet", silver_bucket, "lending_club/lending_club_silver.parquet")
```

**Extra Spark Connect quirk hit here**: `pdf.to_parquet()` initially failed
with `TypeError: Object of type PlanMetrics is not JSON serializable`.
Spark Connect attaches non-serializable query-plan metadata to
`.attrs` on the pandas DataFrame returned by `.toPandas()`; `to_parquet()`
tries to serialize `.attrs` into the file metadata and fails on it.
Fix: `pdf.attrs.clear()` before writing.

**Result**: this loses Delta's actual format (transaction log, ACID,
time travel) — the Silver layer is plain Parquet, not Delta. Documented
as a further consequence of the same Community Edition limitations
already noted for Delta Live Tables/Auto Loader/Unity Catalog.

## 9. Cell-execution-order bug — a concrete lesson on notebook state

While finalizing the Silver write, the output column count kept coming
back wrong (47 instead of the expected 43) across several attempts, even
after re-running what looked like the correct fix cell. Root cause: in an
interactive notebook, re-running cells out of their written order (or
re-running an earlier cell after a later one) means the Python variable
(`df_lc_resolved`) reflects whatever sequence of cells actually executed,
not the order they appear in the file. Two different fixes (additional
leakage removal, near-constant removal) had each been applied in
isolation in earlier cells, but a later re-run of an intermediate step
silently reset progress made by one of them.

**Diagnosis approach that worked**: rather than guessing, printing
`sorted(df.columns)` and diffing it against the known-correct 43-column
list pinpointed exactly which 4 columns were still incorrectly present —
faster than re-checking each transformation step's logic, since the logic
itself was already correct and the bug was purely about execution order.

**Practical fix**: once diagnosed, all remaining fixes and the final
write were combined into a single cell, run start-to-finish in one
execution, removing any ambiguity from interleaved cell runs.

**Takeaway for the interview**: this is a real, common notebook
pitfall — interactive execution order and file order can silently
diverge. It's part of why production pipelines don't run as long-lived
interactive notebooks: a script executed top-to-bottom as a whole (via
`databricks bundle` / a scheduled job) doesn't have this failure mode.

## Results — final Silver layer

- **Lending Club Silver**: 1,303,637 rows × 43 columns, written to
  `s3://credit-risk-platform-silver-385ac098/lending_club/lending_club_silver.parquet`
- **GMSC Silver**: 150,000 rows × 11 columns (index column dropped,
  `SeriousDlqin2yrs` renamed to `target` for consistency with the Lending
  Club target naming), written to
  `s3://credit-risk-platform-silver-385ac098/gmsc/gmsc_silver.parquet`
- Both written as plain Parquet (not Delta — see §8) via the pandas/boto3
  fallback pattern

## Current status

- [x] Community Edition connected to S3 (via boto3 workaround, now using
  Databricks Secrets instead of widgets)
- [x] Both raw datasets read successfully into Spark DataFrames
- [x] Target variable + leakage removal ported to PySpark (137 → 43
  columns after the additional leakage fix in §7)
- [x] High-missing column removal ported to PySpark
- [x] Near-constant column removal (via `approx_count_distinct`
  pre-filter + exact check on candidates — see §4b for the performance
  lessons learned)
- [x] Correlation-based dedup via `pyspark.ml.stat.Correlation` (single
  distributed pass, much faster than a per-pair loop)
- [x] Family-based selection (pure column drops, fast)
- [x] Silver layer written for both LCLD and GMSC (Parquet, not Delta —
  see §8)
- [ ] Model training (two variants, with/without int_rate/term — see
  `docs/feature_engineering.md` §6)
- [ ] Delta Live Tables / Auto Loader / Unity Catalog — not available on
  Community Edition, deferred to a possible future AWS trial
