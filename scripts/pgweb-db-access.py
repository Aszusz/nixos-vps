#!/usr/bin/env python3

import argparse
import os
import subprocess
import sys
import time
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

    readonly_role = quote_ident(args.readonly_role)
    readonly_role_literal = quote_literal(args.readonly_role)
    password = quote_literal(readonly_password())
    database = quote_ident(required_env("POSTGRES_DB"))
    database_owner = quote_ident(required_env("POSTGRES_USER"))
    schema_array = "ARRAY[{}]".format(
        ",".join(quote_literal(schema) for schema in args.schemas)
    )

    sql = rf"""
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = {readonly_role_literal}) THEN
    CREATE ROLE {readonly_role} LOGIN PASSWORD {password};
  ELSE
    ALTER ROLE {readonly_role} WITH LOGIN PASSWORD {password};
  END IF;
END $$;

GRANT CONNECT ON DATABASE {database} TO {readonly_role};

SELECT format('GRANT USAGE ON SCHEMA %I TO {readonly_role}', schema_name)
FROM unnest({schema_array}::text[]) AS schema_name
\gexec

SELECT format('GRANT SELECT ON ALL TABLES IN SCHEMA %I TO {readonly_role}', schema_name)
FROM unnest({schema_array}::text[]) AS schema_name
\gexec

SELECT format('ALTER DEFAULT PRIVILEGES FOR ROLE {database_owner} IN SCHEMA %I GRANT SELECT ON TABLES TO {readonly_role}', schema_name)
FROM unnest({schema_array}::text[]) AS schema_name
\gexec
"""

    subprocess.run(
        psql_args,
        input=sql,
        text=True,
        check=True,
        env=env,
    )


if __name__ == "__main__":
    try:
        main()
    except subprocess.CalledProcessError as error:
        sys.exit(error.returncode)
