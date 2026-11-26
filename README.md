# Olist Data Project

An end-to-end e-commerce analytics project built with Python, PostgreSQL, Snowflake, and Power BI.

## Dataset and scope

The project covers all nine source files and the full published history of the [Olist Brazilian E-Commerce Public Dataset](https://www.kaggle.com/datasets/olistbr/brazilian-ecommerce).

## Workflow

Download the original dataset ZIP from the Olist link above and save it as `data/olist-brazilian-ecommerce.zip` in your local clone. Extract its nine CSVs directly into `data/` and retain the original ZIP. Git ignores this folder, so each clone needs its own copy of the source.

For the [source profiling notebook](notebooks/olist_source_profiling.ipynb), install `pandas`, `matplotlib`, and `ipykernel` in the project environment. Select the project’s Python 3.11 kernel in VS Code and run the notebook from top to bottom.

1. Python validates and replays historical purchase-month batches through a repeatable command-line entry point.
2. PostgreSQL stores the related operational-style records and enforces keys and relationships.
3. Snowflake transforms those records into order, order-item, and review facts with four dimensions.
4. Power BI presents findings with metrics traceable to warehouse SQL and the source.

The pipeline must support safe reruns and updates to existing records. Historical replay simulates incremental ingestion from a fixed snapshot. See [ARCHITECTURE.md](ARCHITECTURE.md) for the model, verification criteria, and milestone dates.

## Local setup

From the repository root in PowerShell, use Python 3.11 to create the environment and install both database drivers.

```powershell
py -3.11 -m venv .venv
.\.venv\Scripts\python.exe -m pip install "psycopg[binary]" snowflake-connector-python
```

For the profiling notebook, also run `.\.venv\Scripts\python.exe -m pip install pandas matplotlib ipykernel`.

## PostgreSQL ETL

Start PostgreSQL and connect as an administrator in pgAdmin. Under **Login/Group Roles → Create**, create `olist_loader`, set its password, and enable **Can login**. Under **Databases → Create**, create `olist_portfolio` with `olist_loader` as its owner. The [Python loader](scripts/load_postgresql.py) uses that login to create its schema and load the nine CSVs.

### First project load

Run steps 1 and 2 in order from the repository root in PowerShell.

**Step 1. Validate all nine source CSVs.** This reports row counts and purchase months without connecting to PostgreSQL.

```powershell
.\.venv\Scripts\python.exe .\scripts\load_postgresql.py --validate-only
```

**Step 2. Create the schema and load the full history.** This applies the [schema SQL](sql/postgresql/schema.sql) to create `olist_source` and its nine tables in the local `olist_portfolio` database. Enter the `olist_loader` password at the local prompt. The loader processes reference tables first, then automatically commits all 25 purchase-month batches in order.

```powershell
.\.venv\Scripts\python.exe .\scripts\load_postgresql.py --init-schema --password-prompt
```

### Optional capability: replay one purchase month

**Step 3 is a pipeline capability demonstration and can be skipped during the project load.** For example, after the full load, the following command would process the reference tables again and replay January 2018.

```powershell
.\.venv\Scripts\python.exe .\scripts\load_postgresql.py --month 2018-01 --password-prompt
```

Upserts keep row counts unchanged when the same input is replayed and apply corrected values when an existing key is supplied. In a disposable PostgreSQL test, replaying January restored 7,269 deliberately changed order statuses and left all nine table counts unchanged. The batch log reports rows processed and verified.

Keep the geolocation CSV in its original record order because its key is based on position. Override connection settings with `--host`, `--port`, `--dbname`, and `--user`. For unattended use, omit the password prompt and configure a local PostgreSQL password file.

The [PostgreSQL operational walkthrough](docs/postgresql-operational-scenarios.md) covers fulfillment exceptions and payment reconciliation, with runnable queries and verified results.

## PostgreSQL to Snowflake transfer

The [staging transfer script](scripts/load_snowflake_staging.py) copies all nine tables from a consistent PostgreSQL snapshot. Run it from the repository root in an interactive PowerShell terminal, replacing the account and login placeholders. The Snowflake database and `STAGING` schema must exist, and `OLIST_PIPELINE` needs permission to use the warehouse and schema and create and write the staging tables.

```powershell
.\.venv\Scripts\python.exe .\scripts\load_snowflake_staging.py --sf-account YOUR_ORG-YOUR_ACCOUNT --sf-user YOUR_LOGIN --init-staging
```

`--init-staging` applies [staging.sql](sql/snowflake/staging.sql) on the first run. The script prompts locally for database passwords and any Snowflake MFA code. Run one transfer at a time. Each successful run checks all nine staging tables against the extract and commits the upserts together. Source keys missing from PostgreSQL are flagged as a reconciliation error if they already exist in Snowflake.

For a fresh Snowflake setup, create the `OLIST_PORTFOLIO` database and its `STAGING` and `ANALYTICS` schemas before transferring data. Create the `OLIST_PIPELINE` role and grant it to your login. Grant it `USAGE` on the database, both schemas, and `COMPUTE_WH`, and `CREATE TABLE` on both schemas. Run the initial transfer and warehouse builds with this role so it owns the tables it creates.

After a successful transfer, run the warehouse SQL in this order in Snowsight:

1. [Build the four dimensions](sql/snowflake/build_dimensions.sql).
2. [Build the three facts](sql/snowflake/build_facts.sql).
3. [Validate the warehouse tables](sql/snowflake/validate_analytics.sql) and confirm each check reports `PASS`.

If you use different Snowflake object names, update the `USE` statements in these files to match.

## Power BI report

Open the [saved report](powerbi/dashboard.pbix) in Power BI Desktop to explore the imported snapshot. To refresh it against your own warehouse, update the Snowflake source connection and credentials before refreshing. The refresh role needs `USAGE` on the warehouse, database, and schema, plus `SELECT` on the analytical tables.

The [dashboard walkthrough](docs/powerbi-dashboard-walkthrough.md) explains both pages, their metrics, and how to investigate the findings further in Snowflake.
