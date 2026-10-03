"""Load the 9 Olist CSVs into a SQLite database (olist.db).

Equivalent to DB Browser for SQLite -> File -> Import -> Table from CSV, once per file.
Usage: python load_data.py
"""
import sqlite3
from pathlib import Path

import pandas as pd

DATA_DIR = Path(__file__).parent / "data"
DB_PATH = Path(__file__).parent / "olist.db"

TABLES = {
    "orders": "olist_orders_dataset.csv",
    "customers": "olist_customers_dataset.csv",
    "order_items": "olist_order_items_dataset.csv",
    "payments": "olist_order_payments_dataset.csv",
    "reviews": "olist_order_reviews_dataset.csv",
    "products": "olist_products_dataset.csv",
    "sellers": "olist_sellers_dataset.csv",
    "geolocation": "olist_geolocation_dataset.csv",
    "category_translation": "product_category_name_translation.csv",
}

# Zip prefixes have leading zeros, so keep them as text.
TEXT_COLS = {"customer_zip_code_prefix": str, "seller_zip_code_prefix": str,
             "geolocation_zip_code_prefix": str}

with sqlite3.connect(DB_PATH) as con:
    for table, filename in TABLES.items():
        df = pd.read_csv(DATA_DIR / filename, dtype=TEXT_COLS, encoding="utf-8-sig")
        df.to_sql(table, con, if_exists="replace", index=False)
        print(f"{table:<22} {len(df):>9,} rows")

    # Indexes on join keys keep the analysis queries fast.
    con.executescript("""
        CREATE INDEX IF NOT EXISTS ix_orders_order    ON orders(order_id);
        CREATE INDEX IF NOT EXISTS ix_orders_customer ON orders(customer_id);
        CREATE INDEX IF NOT EXISTS ix_customers_id    ON customers(customer_id);
        CREATE INDEX IF NOT EXISTS ix_payments_order  ON payments(order_id);
        CREATE INDEX IF NOT EXISTS ix_reviews_order   ON reviews(order_id);
        CREATE INDEX IF NOT EXISTS ix_items_order     ON order_items(order_id);
    """)

print(f"\nDatabase written to {DB_PATH}")
