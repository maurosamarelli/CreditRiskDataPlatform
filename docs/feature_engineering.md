# Feature Engineering — Credit Risk Data Platform

This document consolidates the exploratory work done locally (pandas,
notebooks/) before porting the logic to PySpark/Databricks. It replaces
three earlier working documents (schema_mapping.md, feature_categorization.md,
feature_family_selection.md), which are superseded by this single source of
truth.

## 1. Data sources

| Source | Rows | Columns (raw) | Role |
|---|---|---|---|
| Give Me Some Credit (GMSC) | 150,000 | 12 | Legacy structured source, clean schema |
| Lending Club Loan Data (LCLD) | 2,260,668 | 145 | Heterogeneous source, requires cleaning and feature reduction |

## 2. Target variable

**Definition**: probability that the loan defaults.

For LCLD, only loans with a **resolved** outcome are used:
- `Fully Paid` → target = 0
- `Charged Off`, `Default` → target = 1
- Excluded: `Current`, `In Grace Period`, `Late (16-30 days)`,
  `Late (31-120 days)` — outcome not yet known, including them would mix
  still-active loans into the default bucket

For GMSC, the target is already provided natively (`SeriousDlqin2yrs`).

**Known limitation — the two targets are not perfectly equivalent**:
GMSC's target flags a serious delinquency episode (90+ days past due) within
2 years — an early risk signal, not necessarily a final outcome. LCLD's
target measures the loan's definitive failure (Charged Off/Default). Both
measure credit risk but at different severity levels. This is a documented
limitation of the unified model, not treated as an exact equivalence.

## 3. Feature reduction pipeline (91 → 38 columns)

| Stage | Columns | What was removed | Why |
|---|---|---|---|
| Raw LCLD | 145 | — | — |
| After missing/near-constant filter | 91 | High-missing and near-constant columns | Automated noise removal |
| After leakage + loan_status removal | 81 | Payment-behavior columns known only post-origination (`total_pymnt_inv`, `total_rec_prncp`, `last_pymnt_amnt`, `debt_settlement_flag`, etc.), plus `loan_status` (used only to build the target) | Prevent data leakage |
| After correlation dedup (>0.85) | 73 | Near-exact duplicates (`funded_amnt`, `funded_amnt_inv`, `num_sats`, `num_rev_tl_bal_gt_0`, `bc_util`) replaced two balance/limit pairs with derived ratios (`tot_cur_bal_util`, `total_bal_il_util`) | Remove redundant signal, keep more informative ratios |
| After domain-driven family selection | 41 | Narrower/redundant variants within concept families (time-since-event, account counts by product type, recent-account-opening by product type) — kept one representative per family where variants measured the same underlying concept | Reduce granularity without losing distinct signal (validated: the 5 utilization-ratio columns showed max pairwise corr of 0.66, all kept) |
| After dropping low-value categoricals | 38 | `purpose` (13 categories, combined importance ~0.0013), `disbursement_method`, `initial_list_status` (near-zero importance) | Empirically confirmed negligible via Random Forest importance |

Full per-family reasoning (which variant was kept and why, e.g.
`mo_sin_old_rev_tl_op` kept over `mo_sin_rcnt_tl`) is preserved in the
project's git history (superseded working files) if needed for reference.

## 4. GMSC ↔ LCLD schema mapping (unified feature names)

| Unified feature | GMSC | LCLD | Notes |
|---|---|---|---|
| annual_income | MonthlyIncome (×12) | annual_inc | Normalize to annual basis |
| age | age | — | Not available in LCLD (privacy) |
| revolving_utilization | RevolvingUtilizationOfUnsecuredLines | revol_util | LCLD in %, GMSC as ratio — harmonize scale |
| open_credit_lines | NumberOfOpenCreditLinesAndLoans | open_acc | `open_acc` confirmed as the correct equivalent (not `total_acc`, which includes closed lines) |
| delinquency_90d | NumberOfTimes90DaysLate | num_tl_90g_dpd_24m | Not an exact equivalent — LCLD lacks a granular 30/60/90-day breakdown; `delinq_2yrs` used as a broader proxy where finer granularity isn't available |
| debt_ratio | DebtRatio | dti | Different scales, normalize |
| dependents | NumberOfDependents | — | Not available in LCLD |

## 5. Final feature set (38 columns) by category

- **Loan characteristics**: `loan_amnt`, `term`, `int_rate`, `installment`
- **Income & employment**: `emp_length`, `home_ownership`, `annual_inc`, `verification_status`
- **Application type**: `application_type`
- **Credit history — core**: `dti`, `delinq_2yrs`, `inq_last_6mths`, `open_acc`, `revol_util`, `revol_bal`, `mort_acc`, `total_cu_tl`, `tot_coll_amt`, `collections_12_mths_ex_med`, `pub_rec_bankruptcies`, `pct_tl_nvr_dlq`, `num_tl_90g_dpd_24m`
- **Credit history — activity/utilization**: `num_actv_rev_tl`, `num_tl_op_past_12m`, `acc_open_past_24mths`, `mo_sin_old_rev_tl_op`, `mths_since_recent_inq`, `all_util`, `avg_cur_bal`, `tot_cur_bal_util`, `total_bal_il_util`, `total_bc_limit`

(`grade`/`sub_grade` were dropped early in the process and are not part of
this set — see Section 6 for why they matter to the modeling decision below
even though they aren't columns in the data anymore.)

## 6. Key modeling finding — int_rate/term as risk-judgment proxies

A Random Forest importance check on the 38-feature set showed `int_rate`
dominating (importance ≈ 0.41) with `term_60_months` a distant second
(≈ 0.20) — together capturing ~60% of total importance. Re-running without
`int_rate` did **not** shift importance toward raw credit-history signals
(`delinq_2yrs`, `num_tl_90g_dpd_24m` stayed near zero); instead, `term`
absorbed most of the freed weight.

**Interpretation**: even without the `grade`/`sub_grade` columns themselves,
`int_rate` and `term` are strong proxies for Lending Club's own internal
risk assessment (which originally set the rate and term). The model leans
heavily on LC's implicit judgment rather than on raw credit-bureau signals.

**Design decision**: build and compare two model variants —
1. **Full model**: includes `int_rate` and `term` — represents realistic
   production performance, but is close to reproducing LC's own risk scoring
2. **Independent-signal model**: excludes `int_rate` and `term` — forces the
   model to learn from raw credit-history data only, weaker performance but
   demonstrates genuine risk-modeling capability independent of LC's own
   assessment

This comparison will be implemented as an MLflow-tracked experiment on
Databricks (two training jobs, compared on AUC/precision/recall), not as
further local exploration — see `docs/architecture.md` (to be created) for
where this fits in the pipeline.

## 7. Open items for later (not blocking)

- `emp_title` and `title` (free text) — deferred, candidate for a future
  embedding/RAG experiment
- `addr_state` — kept for geography; `zip_code` dropped as too granular
- Deeper correlation check between `all_util` and the two derived
  utilization ratios could still reduce Section 5's list slightly, but is
  not a priority given the shift in focus to the AWS/Databricks pipeline
