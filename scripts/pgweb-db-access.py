#!/usr/bin/env python3

import argparse
import os
import subprocess
import sys
import time
from pathlib import Path
from urllib.parse import unquote, urlparse


def query(args, env=None):
    return subprocess.run(
        args,
        check=True,
        env=env,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    ).stdout


def required_env(name):
    value = os.environ.get(name)
    if not value:
        raise SystemExit(f"{name} is required")
    return value


def readonly_password():
    url = required_env("PGWEB_DATABASE_URL")
    password = urlparse(url).password
    if not password:
        raise SystemExit("PGWEB_DATABASE_URL must include the read-only role password")
    return unquote(password)


def psql_base(psql):
    return [
        psql,
        "-h",
        "127.0.0.1",
        "-p",
        required_env("POSTGRES_PORT"),
        "-U",
        required_env("POSTGRES_USER"),
        "-d",
        required_env("POSTGRES_DB"),
        "-v",
        "ON_ERROR_STOP=1",
    ]


def wait_for_postgres(psql_args, env):
    for attempt in range(60):
        try:
            query(psql_args + ["-tAc", "SELECT 1"], env=env)
            return
        except subprocess.CalledProcessError:
            if attempt == 59:
                raise
            time.sleep(2)


def validate_schemas(schemas):
    for schema in schemas:
        if not schema:
            raise SystemExit("schema names must not be empty")


def quote_ident(value):
    return '"' + value.replace('"', '""') + '"'


def quote_literal(value):
    return "'" + value.replace("'", "''") + "'"


def render_sql(args):
    template = Path(__file__).with_suffix(".sql").read_text()
    schema_array = "ARRAY[{}]".format(
        ",".join(quote_literal(schema) for schema in args.schemas)
    )
    replacements = {
        "__READONLY_ROLE__": quote_ident(args.readonly_role),
        "__READONLY_ROLE_LITERAL__": quote_literal(args.readonly_role),
        "__READONLY_PASSWORD__": quote_literal(readonly_password()),
        "__DATABASE__": quote_ident(required_env("POSTGRES_DB")),
        "__DATABASE_OWNER__": quote_ident(required_env("POSTGRES_USER")),
        "__SCHEMA_ARRAY__": schema_array,
    }

    sql = template
    for placeholder, value in replacements.items():
        sql = sql.replace(placeholder, value)
    return sql


def main():
    parser = argparse.ArgumentParser(
        description="Ensure pgweb read-only PostgreSQL role and schema grants."
    )
    parser.add_argument("--psql", required=True)
    parser.add_argument("--readonly-role", required=True)
    parser.add_argument("--schema", action="append", required=True, dest="schemas")
    args = parser.parse_args()

    validate_schemas(args.schemas)

    env = os.environ.copy()
    env["PGPASSWORD"] = required_env("POSTGRES_PASSWORD")
    psql_args = psql_base(args.psql)

    wait_for_postgres(psql_args, env)

    subprocess.run(
        psql_args,
        input=render_sql(args),
        text=True,
        check=True,
        env=env,
    )


if __name__ == "__main__":
    try:
        main()
    except subprocess.CalledProcessError as error:
        sys.exit(error.returncode)
