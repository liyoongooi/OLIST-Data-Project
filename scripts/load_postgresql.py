"""Load the full Olist snapshot into PostgreSQL in purchase-month batches."""

import argparse
import csv
import logging
import re
import sys
import warnings
from collections.abc import Iterable, Iterator
from dataclasses import dataclass
from datetime import date, datetime
from decimal import Decimal, InvalidOperation
from getpass import GetPassWarning, getpass
from pathlib import Path

import psycopg
from psycopg import sql


ROOT = Path(__file__).resolve().parents[1]
SCHEMA = "olist_source"
LOGGER = logging.getLogger(__name__)
GEOLOCATION = "geolocation"
REFERENCE_TABLES = ("products", "sellers", "category_translations")
ORDER_CHILDREN = ("order_items", "order_payments", "order_reviews")
Row = tuple


@dataclass(frozen=True)
class Table:
    file: str
    columns: tuple[str, ...]
    key: tuple[str, ...]
    nullable: frozenset[str] = frozenset()


def table(file, columns, key, nullable=""):
    return Table(file, tuple(columns.split()), tuple(key.split()), frozenset(nullable.split()))


TABLES = {
    "customers": table(
        "olist_customers_dataset.csv",
        "customer_id customer_unique_id customer_zip_code_prefix customer_city customer_state",
        "customer_id",
    ),
    "products": table(
        "olist_products_dataset.csv",
        "product_id product_category_name product_name_length product_description_length "
        "product_photos_qty product_weight_g product_length_cm product_height_cm product_width_cm",
        "product_id",
        "product_category_name product_name_length product_description_length product_photos_qty "
        "product_weight_g product_length_cm product_height_cm product_width_cm",
    ),
    "sellers": table(
        "olist_sellers_dataset.csv",
        "seller_id seller_zip_code_prefix seller_city seller_state",
        "seller_id",
    ),
    "category_translations": table(
        "product_category_name_translation.csv",
        "product_category_name product_category_name_english",
        "product_category_name",
    ),
    GEOLOCATION: table(
        "olist_geolocation_dataset.csv",
        "source_row_number geolocation_zip_code_prefix geolocation_lat geolocation_lng "
        "geolocation_city geolocation_state",
        "source_row_number",
    ),
    "orders": table(
        "olist_orders_dataset.csv",
        "order_id customer_id order_status order_purchase_timestamp order_approved_at "
        "order_delivered_carrier_date order_delivered_customer_date order_estimated_delivery_date",
        "order_id",
        "order_approved_at order_delivered_carrier_date order_delivered_customer_date",
    ),
    "order_items": table(
        "olist_order_items_dataset.csv",
        "order_id order_item_id product_id seller_id shipping_limit_date price freight_value",
        "order_id order_item_id",
    ),
    "order_payments": table(
        "olist_order_payments_dataset.csv",
        "order_id payment_sequential payment_type payment_installments payment_value",
        "order_id payment_sequential",
    ),
    "order_reviews": table(
        "olist_order_reviews_dataset.csv",
        "order_id review_id review_score review_comment_title review_comment_message "
        "review_creation_date review_answer_timestamp",
        "order_id review_id",
        "review_comment_title review_comment_message",
    ),
}

SOURCE_HEADERS = {
    "product_name_length": "product_name_lenght",
    "product_description_length": "product_description_lenght",
}
INTEGER_COLUMNS = frozenset(
    "order_item_id payment_sequential payment_installments review_score product_name_length "
    "product_description_length product_photos_qty product_weight_g product_length_cm "
    "product_height_cm product_width_cm".split()
)
MONEY_COLUMNS = {"price", "freight_value", "payment_value"}
COORDINATE_LIMITS = {"geolocation_lat": 90, "geolocation_lng": 180}


def extract(data_dir: Path, spec: Table) -> Iterator[tuple[int, dict[str, str]]]:
    """Read one CSV in source order and yield its data-record number and fields."""
    with (data_dir / spec.file).open(encoding="utf-8-sig", newline="") as source:
        reader = csv.DictReader(source, strict=True)
        expected = {
            SOURCE_HEADERS.get(column, column)
            for column in spec.columns
            if column != "source_row_number"
        }
        headers = reader.fieldnames or []
        if set(headers) != expected or len(headers) != len(expected):
            raise ValueError(f"{spec.file}: unexpected headers: {headers}")
        for record_number, row in enumerate(reader, start=1):
            if None in row or any(value is None for value in row.values()):
                raise ValueError(f"{spec.file}: wrong number of fields in record {record_number}")
            yield record_number, row


def parse_value(column: str, value: str):
    """Convert source text while preserving IDs, ZIP prefixes, and review text."""
    if column in INTEGER_COLUMNS:
        number = int(value)
        if not -(2**31) <= number < 2**31:
            raise ValueError(f"{column} exceeds the PostgreSQL integer range")
        if column == "review_score" and not 1 <= number <= 5:
            raise ValueError("review_score must be between 1 and 5")
        if column in {"order_item_id", "payment_sequential"} and number < 1:
            raise ValueError(f"{column} must be positive")
        if column == "payment_installments" and number < 0:
            raise ValueError("payment_installments must be nonnegative")
        return number
    if column in MONEY_COLUMNS:
        if not re.fullmatch(r"[+-]?\d{1,10}(?:\.\d{1,2})?", value):
            raise ValueError(f"{column} must fit numeric(12, 2)")
        amount = Decimal(value)
        if amount < 0 or (column == "price" and amount == 0):
            raise ValueError(f"invalid sign for {column}")
        return amount
    if column in COORDINATE_LIMITS:
        coordinate = float(value)
        limit = COORDINATE_LIMITS[column]
        if not -limit <= coordinate <= limit:
            raise ValueError(f"{column} is out of bounds")
        return coordinate
    if column.endswith(("_date", "_timestamp", "_at")):
        timestamp = datetime.fromisoformat(value)
        if timestamp.tzinfo is not None:
            raise ValueError(f"{column} must be a local source timestamp")
        return timestamp
    if column.endswith("_zip_code_prefix") and not re.fullmatch(r"[0-9]{5}", value):
        raise ValueError(f"{column} must contain five digits")
    return value


def transform(spec: Table, records: Iterable[tuple[int, dict[str, str]]]) -> Iterator[Row]:
    """Produce typed PostgreSQL rows and validate the candidate key."""
    key_positions = tuple(spec.columns.index(column) for column in spec.key)
    seen = set()
    for record_number, raw in records:
        values = []
        try:
            for column in spec.columns:
                if column == "source_row_number":
                    values.append(record_number)
                    continue
                value = raw[SOURCE_HEADERS.get(column, column)]
                if value.strip():
                    values.append(parse_value(column, value))
                elif column in spec.nullable:
                    values.append(None)
                else:
                    raise ValueError(f"required column {column} is blank")
            row = tuple(values)
            # Geolocation record numbers are already unique by construction.
            if spec.key != ("source_row_number",):
                key = tuple(row[position] for position in key_positions)
                if key in seen:
                    raise ValueError(f"duplicate key on {', '.join(spec.key)}")
                seen.add(key)
            yield row
        except (ValueError, InvalidOperation) as error:
            raise ValueError(f"{spec.file}, record {record_number}: {error}") from error


def read_table(data_dir: Path, name: str) -> Iterator[Row]:
    spec = TABLES[name]
    return transform(spec, extract(data_dir, spec))


def prepare_batches(rows):
    """Validate relationships and group orders and their children by purchase month."""
    customers = {row[0] for row in rows["customers"]}
    products = {row[0] for row in rows["products"]}
    sellers = {row[0] for row in rows["sellers"]}
    order_month = {}
    batches = {}
    for order in rows["orders"]:
        order_id, customer_id, _, purchased_at, *_ = order
        if customer_id not in customers:
            raise ValueError(f"Order {order_id} has no customer record")
        month = purchased_at.strftime("%Y-%m")
        order_month[order_id] = month
        batch = batches.setdefault(month, {name: [] for name in ("orders", *ORDER_CHILDREN)})
        batch["orders"].append(order)

    for name in ORDER_CHILDREN:
        for row in rows[name]:
            month = order_month.get(row[0])
            if month is None:
                raise ValueError(f"{name}: missing parent order {row[0]}")
            if name == "order_items" and (row[2] not in products or row[3] not in sellers):
                raise ValueError(f"Order item {row[:2]} has no product or seller record")
            batches[month][name].append(row)

    return batches


def load(cursor, name: str, rows: Iterable[Row]) -> int:
    """Bulk copy into transaction-local staging, upsert, then reconcile staged rows."""
    spec = TABLES[name]
    target = sql.Identifier(SCHEMA, name)
    stage_name = f"stage_{name}"
    stage = sql.Identifier("pg_temp", stage_name)
    columns = sql.SQL(", ").join(map(sql.Identifier, spec.columns))
    keys = sql.SQL(", ").join(map(sql.Identifier, spec.key))
    def row_values(alias):
        qualified = sql.SQL(", ").join(sql.Identifier(alias, col) for col in spec.columns)
        return sql.SQL("ROW({})").format(qualified)

    updates = sql.SQL(", ").join(
        sql.SQL("{} = EXCLUDED.{}").format(sql.Identifier(col), sql.Identifier(col))
        for col in spec.columns if col not in spec.key
    )

    cursor.execute(
        sql.SQL("CREATE TEMP TABLE {} ON COMMIT DROP AS SELECT {} FROM {} WITH NO DATA")
        .format(sql.Identifier(stage_name), columns, target)
    )
    count = 0
    with cursor.copy(sql.SQL("COPY {} ({}) FROM STDIN").format(stage, columns)) as copy:
        for row in rows:
            copy.write_row(row)
            count += 1

    cursor.execute(
        sql.SQL(
            "INSERT INTO {} AS target ({}) SELECT {} FROM {} "
            "ON CONFLICT ({}) DO UPDATE SET {} "
            "WHERE {} IS DISTINCT FROM {}"
        ).format(target, columns, columns, stage, keys, updates,
                 row_values("target"), row_values("excluded"))
    )
    cursor.execute(
        sql.SQL("SELECT count(*) FROM {} AS loaded JOIN {} AS staged USING ({}) "
                "WHERE {} IS NOT DISTINCT FROM {}")
        .format(target, stage, keys, row_values("loaded"), row_values("staged"))
    )
    if cursor.fetchone()[0] != count:
        raise ValueError(f"{name}: PostgreSQL rows do not match the {count:,} staged rows")
    return count


def load_batch(connection, label, tables):
    """Load all tables for one batch in a single PostgreSQL transaction."""
    counts = {}
    with connection.transaction(), connection.cursor() as cursor:
        for name, rows in tables.items():
            counts[name] = load(cursor, name, rows)
    LOGGER.info("Committed %s: %s", label, counts)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__) # command-line parser
    parser.add_argument("--data-dir", type=Path, default=ROOT / "data")
    parser.add_argument("--month", help="Load one purchase month, YYYY-MM. Default: full history.")
    parser.add_argument("--validate-only", action="store_true", help="Check the CSVs without connecting.")
    parser.add_argument("--init-schema", action="store_true", help="Apply the PostgreSQL schema SQL first.")
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=5432)
    parser.add_argument("--dbname", default="olist_portfolio")
    parser.add_argument("--user", default="olist_loader")
    parser.add_argument("--password-prompt", action="store_true", help="Enter the password locally.")
    args = parser.parse_args()
    if args.month:
        try:
            if date.fromisoformat(f"{args.month}-01").strftime("%Y-%m") != args.month:
                raise ValueError
        except ValueError:
            parser.error("--month must be in YYYY-MM format.")
    if args.password_prompt and not args.validate_only and not sys.stdin.isatty():
        parser.error("--password-prompt requires an interactive terminal.")

    logging.basicConfig(level=logging.INFO, format="%(message)s")
    try:
        rows = {name: list(read_table(args.data_dir, name)) for name in TABLES if name != GEOLOCATION}
        batches = prepare_batches(rows)
        if args.month and args.month not in batches:
            raise ValueError(f"No orders found for {args.month}")
        months = [args.month] if args.month else sorted(batches)
        if args.validate_only:
            counts = {name: len(records) for name, records in rows.items()}
            counts[GEOLOCATION] = sum(1 for _ in read_table(args.data_dir, GEOLOCATION))
            LOGGER.info("Validated source rows: %s", counts)
            LOGGER.info("Selected purchase months: %s", ", ".join(months))
            return 0

        options = {}
        if args.password_prompt:
            with warnings.catch_warnings():
                warnings.simplefilter("error", GetPassWarning)
                options["password"] = getpass("PostgreSQL password: ")
        with psycopg.connect(
            host=args.host, port=args.port, dbname=args.dbname, user=args.user,
            connect_timeout=10, autocommit=True, **options,
        ) as connection:
            if args.init_schema:
                ddl = ROOT / "sql" / "postgresql" / "schema.sql"
                with connection.transaction():
                    connection.execute(ddl.read_text(encoding="utf-8"))

            reference_rows = {name: rows[name] for name in ("customers", *REFERENCE_TABLES)}
            reference_rows[GEOLOCATION] = read_table(args.data_dir, GEOLOCATION)
            load_batch(connection, "reference tables", reference_rows)
            for month in months:
                batch = batches[month]
                load_batch(connection, month, batch)
        return 0
    except (OSError, csv.Error, ValueError, psycopg.Error, GetPassWarning) as error:
        LOGGER.error("%s", error)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
