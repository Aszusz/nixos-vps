import argparse
import os
import subprocess
import sys


def required_env(name):
    value = os.environ.get(name)
    if not value:
        raise SystemExit(f"{name} is required")
    return value


def main():
    parser = argparse.ArgumentParser(description="Ensure an app PostgreSQL role and database exist.")
    parser.add_argument("--psql", required=True)
    args = parser.parse_args()

    user = required_env("POSTGRES_USER")
    password = required_env("POSTGRES_PASSWORD")
    database = required_env("POSTGRES_DB")

    sql = r"""
SELECT format('CREATE ROLE %I LOGIN', :'user')
WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = :'user')\gexec

ALTER ROLE :"user" WITH PASSWORD :'password';

SELECT format('CREATE DATABASE %I OWNER %I', :'database', :'user')
WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = :'database')\gexec
"""

    subprocess.run(
        [
            args.psql,
            "--set=ON_ERROR_STOP=1",
            f"--set=user={user}",
            f"--set=password={password}",
            f"--set=database={database}",
        ],
        input=sql,
        text=True,
        check=True,
    )


if __name__ == "__main__":
    try:
        main()
    except subprocess.CalledProcessError as error:
        sys.exit(error.returncode)
