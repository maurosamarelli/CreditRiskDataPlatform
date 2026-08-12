# Credit Risk Data Platform

End-to-end data engineering project: a credit-risk scoring pipeline built on
AWS + Databricks, following a Bronze → Silver → Gold (Medallion) architecture.
Built as a practical exercise mirroring the tech stack of a senior data
engineer role (AWS S3/Glue/Kinesis/Lambda/Redshift + Databricks Delta Live
Tables/Auto Loader + Terraform + CI/CD).

## Data sources

- [Give Me Some Credit](https://www.kaggle.com/c/GiveMeSomeCredit) (Kaggle)
- [Lending Club Loan Data](https://www.kaggle.com/datasets/wordsforthewise/lending-club) (Kaggle)

## Status

- [x] Local exploration and feature engineering (pandas) — see `docs/feature_engineering.md`
- [x] Infrastructure as Code (Terraform: S3, IAM, Glue Data Catalog, Glue Crawler)
- [x] Raw data ingestion to S3
- [x] Schema discovery (Glue Crawler) + verification (Athena) — see `docs/aws_setup.md`
- [x] Databricks connected to S3, both raw datasets read into Spark — see `docs/databricks_setup.md`
- [x] Bronze → Silver transformation on Databricks (PySpark; Delta Live Tables/Auto Loader deferred — not available on Community Edition; Silver layer written as Parquet, not Delta, for the same reason)
- [ ] Data quality checks
- [ ] Orchestration (Airflow / Databricks Workflows)
- [ ] Model training + MLflow tracking (two variants, see `docs/feature_engineering.md` §6)
- [ ] Model serving (FastAPI)
- [ ] CI/CD (GitHub Actions)

## Repository structure

```
docs/            architecture notes, feature engineering decisions
notebooks/        local exploration notebooks (pandas)
infra/            Terraform IaC
ingestion/        ingestion scripts (Lambda, Kinesis producers)
transform/        PySpark / Delta Live Tables pipelines
orchestration/    Airflow DAGs / Databricks Workflows configs
ml/               feature engineering (Spark), training, MLflow
api/              FastAPI serving layer
tests/            unit and integration tests
```

## Documentation

- [Feature engineering decisions](docs/feature_engineering.md)
- [AWS setup: infra, ingestion, schema discovery](docs/aws_setup.md)
- [Databricks setup: Community Edition limitations and workarounds](docs/databricks_setup.md)
