# Databricks notebook source
# ============================================================
# Notebook version 2 — clean, credentials via Databricks Secrets
# SETUP — AWS credentials via Databricks Secrets
# Community Edition workaround: fs.s3a.* is blocked on serverless
# compute (Spark Connect), so boto3 is used instead of native
# spark.read on S3. See docs/databricks_setup.md for details..
# Secrets (not widgets!) are used so credentials are never
# serialized into the notebook file when committed to Git.
# ============================================================
access_key = dbutils.secrets.get(scope="aws-creds", key="access-key-id")
secret_key = dbutils.secrets.get(scope="aws-creds", key="secret-access-key")

# COMMAND ----------


import boto3
import pandas as pd
from io import BytesIO

s3 = boto3.client(
    "s3",
    aws_access_key_id=access_key,
    aws_secret_access_key=secret_key,
    region_name="eu-west-1"
)

RAW_BUCKET = "credit-risk-platform-raw-385ac098"

# COMMAND ----------

# ============================================================
# READ GMSC — small file, safe to load via get_object() + pandas
# ============================================================
obj = s3.get_object(Bucket=RAW_BUCKET, Key="gmsc/gmsc.csv")
pdf_gmsc = pd.read_csv(BytesIO(obj["Body"].read()))

df_gmsc = spark.createDataFrame(pdf_gmsc)
df_gmsc.printSchema()
df_gmsc.show(5)

# COMMAND ----------

# ============================================================
# READ LENDING CLUB — large file (1.1 GB), must stream to disk
# first (download_file), then read natively with Spark.
# Only /Workspace is a writable+readable path on serverless compute
# (see docs/databricks_setup.md for the full chain of restrictions
# hit: fs.s3a blocked, DBFS disabled, local filesystem denied)
# ============================================================
local_path = "/Workspace/tmp_lending_club.csv"
s3.download_file(RAW_BUCKET, "lending_club/lending_club.csv", local_path)

df_lc = spark.read.option("header", "true").option("inferSchema", "true").csv(local_path)

print(f"Rows: {df_lc.count()}")
print(f"Columns: {len(df_lc.columns)}")

# COMMAND ----------

# ============================================================
# Convert to Parquet once — CSV is row-based and non-splittable,
# forcing Spark to parse every row even with pushed-down filters
# (see explain() output: Format: CSV, Batched: false). Parquet
# is columnar with embedded statistics, letting Spark skip
# irrelevant data instead of scanning row by row.
# ============================================================
df_lc.write.mode("overwrite").parquet("/Workspace/lending_club_parquet")

print("Lending Club converted to Parquet")
