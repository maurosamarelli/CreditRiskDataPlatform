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
- [ ] Infrastructure as Code (Terraform: S3, IAM, Glue Data Catalog)
- [ ] Raw data ingestion to S3
- [ ] Bronze → Silver → Gold transformation on Databricks (Delta Live Tables, Auto Loader)
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
