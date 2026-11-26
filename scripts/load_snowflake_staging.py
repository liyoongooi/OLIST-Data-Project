"""Copy the PostgreSQL Olist snapshot into Snowflake STAGING."""

import argparse
import csv
import logging
import sys
import warnings
from getpass import GetPassWarning, getpass
from pathlib import Path
from tempfile import TemporaryDirectory
from uuid import uuid4

import psycopg
from psycopg import sql
import snowflake.connector
from snowflake.connector.errors import Error as SnowflakeError

from load_postgresql import ROOT, SCHEMA, TABLES, Table


LOGGER = logging.getLogger(__name__)
FETCH_ROWS = 10_000
NULL_MARKER = "__OLIST_SQL_NULL__"


def extract(postgres, name: str, spec: Table, path: Path) -> int:
    """Stream one PostgreSQL table to a temporary UTF-8 transfer file."""
    columns = sql.SQL(", ").join(map(sql.Identifier, spec.columns))
    query = sql.SQL("SELECT {} FROM {}").format(columns, sql.Identifier(SCHEMA, name))
    count = 0
    with postgres.cursor(name=f"extract_{name}") as cursor, path.open(
        "w", encoding="utf-8", newline=""
    ) as output:
        cursor.itersize = FETCH_ROWS
        cursor.execute(query)
        writer = csv.writer(output, quoting=csv.QUOTE_ALL)
        for row in cursor:
            if NULL_MARKER in row:
                raise ValueError(f"{name}: source contains the reserved NULL marker")
            writer.writerow([NULL_MARKER if value is None else value for value in row])
            count += 1
    if count == 0:
        raise ValueError(f"{name}: empty source table in the full Olist snapshot")
    return count


def load_buffer(cursor, name: str, spec: Table, path: Path, stage_path: str) -> None:
    """Bulk load the extract into a session-scoped Snowflake table."""
    buffer = f"STAGING.INCOMING_{name}"
    columns = ", ".join(spec.columns)
    cursor.execute(
        f"CREATE TEMPORARY TABLE {buffer} AS SELECT {columns} FROM STAGING.{name} WHERE FALSE"
    )
    with path.open("rb") as source:
        cursor.execute(
            f"PUT file://{name}.csv {stage_path} AUTO_COMPRESS=TRUE",
            file_stream=source,
        )
    cursor.execute(
        f"""
        COPY INTO {buffer}
        FROM {stage_path}
        FILE_FORMAT = (
            TYPE = CSV
            FIELD_OPTIONALLY_ENCLOSED_BY = '"'
            ESCAPE_UNENCLOSED_FIELD = NONE
            MULTI_LINE = TRUE
            NULL_IF = ('{NULL_MARKER}')
            EMPTY_FIELD_AS_NULL = FALSE
        )
        ON_ERROR = ABORT_STATEMENT
        PURGE = TRUE
        """
    )


def load(cursor, name: str, spec: Table, source_count: int) -> None:
    """Upsert changed rows by source key and reconcile against the extract."""
    target = f"STAGING.{name}"
    buffer = f"STAGING.INCOMING_{name}"
    columns = ", ".join(spec.columns)
    keys = " AND ".join(f"t.{key} = s.{key}" for key in spec.key)
    attributes = [column for column in spec.columns if column not in spec.key]
    updates = ", ".join(f"{column} = s.{column}" for column in attributes)
    changed = " OR ".join(f"t.{column} IS DISTINCT FROM s.{column}" for column in attributes)
    values = ", ".join(f"s.{column}" for column in spec.columns)
    matches = " AND ".join(f"t.{column} IS NOT DISTINCT FROM s.{column}" for column in attributes)

    cursor.execute(f"SELECT COUNT(*) FROM {buffer}")
    if cursor.fetchone()[0] != source_count:
        raise ValueError(f"{name}: bulk load count differs from PostgreSQL ({source_count:,})")

    cursor.execute(
        f"""
        MERGE INTO {target} AS t
        USING {buffer} AS s ON {keys}
        WHEN MATCHED AND ({changed}) THEN UPDATE SET {updates}
        WHEN NOT MATCHED THEN INSERT ({columns}) VALUES ({values})
        """
    )
    cursor.execute(f"SELECT COUNT(*) FROM {target}")
    target_count = cursor.fetchone()[0]
    cursor.execute(f"SELECT COUNT(*) FROM {target} AS t JOIN {buffer} AS s ON {keys} WHERE {matches}")
    matched_count = cursor.fetchone()[0]
    if (target_count, matched_count) != (source_count, source_count):
        raise ValueError(
            f"{name}: source={source_count:,}, staging={target_count:,}, "
            f"matching={matched_count:,}; check for stale rows or duplicate keys"
        )
    # Snowflake standard tables do not enforce primary keys.
    cursor.execute(
        f"SELECT 1 FROM {target} GROUP BY {', '.join(spec.key)} HAVING COUNT(*) > 1 LIMIT 1"
    )
    if cursor.fetchone() is not None:
        raise ValueError(f"{name}: duplicate Snowflake staging key")
    LOGGER.info("Reconciled %s: %s rows", name, f"{source_count:,}")


def transfer(postgres, snowflake) -> None:
    """Read a consistent source snapshot and commit all staging merges together."""
    run_path = f"@~/olist_transfer/{uuid4().hex}"
    counts = {}
    with snowflake.cursor() as cursor, TemporaryDirectory(prefix="olist-transfer-") as folder:
        try:
            with postgres.transaction():
                postgres.execute("SET TRANSACTION ISOLATION LEVEL REPEATABLE READ READ ONLY")
                for name, spec in TABLES.items():
                    path = Path(folder) / f"{name}.csv"
                    counts[name] = extract(postgres, name, spec, path)
                    load_buffer(cursor, name, spec, path, f"{run_path}/{name}/")
                    path.unlink()

            # Create and fill buffers first. Snowflake DDL can implicitly commit.
            cursor.execute("BEGIN")
            try:
                for name, spec in TABLES.items():
                    load(cursor, name, spec, counts[name])
                cursor.execute("COMMIT")
            except BaseException:
                cursor.execute("ROLLBACK")
                raise
        except BaseException:
            try:
                cursor.execute(f"REMOVE {run_path}/")
            except SnowflakeError:
                LOGGER.warning("Could not clean up transfer files at %s/", run_path)
            raise
    LOGGER.info("Committed all %d Snowflake staging tables", len(counts))


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--pg-host", default="127.0.0.1")
    parser.add_argument("--pg-port", type=int, default=5432)
    parser.add_argument("--pg-database", default="olist_portfolio")
    parser.add_argument("--pg-user", default="olist_loader")
    parser.add_argument("--sf-account", required=True)
    parser.add_argument("--sf-user", required=True)
    parser.add_argument("--sf-warehouse", default="COMPUTE_WH")
    parser.add_argument("--sf-role", default="OLIST_PIPELINE")
    parser.add_argument("--sf-database", default="OLIST_PORTFOLIO")
    parser.add_argument("--init-staging", action="store_true", help="Apply staging.sql first.")
    args = parser.parse_args()
    if not sys.stdin.isatty():
        parser.error("Run from an interactive terminal to enter credentials.")

    logging.basicConfig(level=logging.INFO, format="%(message)s")
    logging.getLogger("snowflake.connector").setLevel(logging.WARNING)
    try:
        with warnings.catch_warnings():
            warnings.simplefilter("error", GetPassWarning)
            pg_password = getpass("PostgreSQL password: ")
            sf_password = getpass("Snowflake password: ")
            passcode = getpass("Snowflake MFA code (Enter to skip if unused): ").strip()
        mfa = {"passcode": passcode} if passcode else {}
        with psycopg.connect(
            host=args.pg_host, port=args.pg_port, dbname=args.pg_database,
            user=args.pg_user, password=pg_password, connect_timeout=10, autocommit=True,
        ) as postgres, snowflake.connector.connect(
            account=args.sf_account, user=args.sf_user, password=sf_password,
            warehouse=args.sf_warehouse, role=args.sf_role, database=args.sf_database,
            schema="STAGING", authenticator="username_password_mfa",
            client_store_temporary_credential=False, login_timeout=30, autocommit=True,
            enable_server_session_keep_alive_auto_detection=False,
            session_parameters={"ERROR_ON_NONDETERMINISTIC_MERGE": True},
            **mfa,
        ) as snowflake_connection:
            if args.init_staging:
                ddl = ROOT / "sql" / "snowflake" / "staging.sql"
                for cursor in snowflake_connection.execute_string(ddl.read_text(encoding="utf-8")):
                    cursor.close()
            transfer(postgres, snowflake_connection)
    except (EOFError, KeyboardInterrupt):
        LOGGER.error("Transfer cancelled.")
        return 1
    except (GetPassWarning, OSError, ValueError, psycopg.Error, SnowflakeError) as error:
        LOGGER.error("Transfer failed: %s", error)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
