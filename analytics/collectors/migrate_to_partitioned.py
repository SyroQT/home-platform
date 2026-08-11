#!/usr/bin/env python3
"""
Migrate flat S3 files to date-partitioned layout.

Before: analytics/raw/host/2026-05-22T10-30-45.000000-00-00.json
After:  analytics/raw/host/2026/05/22/2026-05-22T10-30-45.000000-00-00.json

Usage:
    python migrate_to_partitioned.py                     # dry run (default)
    python migrate_to_partitioned.py --apply              # execute changes, throttled to 10/sec
    python migrate_to_partitioned.py --apply --rate 20     # execute changes, throttled to 20/sec
    python migrate_to_partitioned.py --apply --rate 0      # execute changes, unthrottled
"""
import argparse
import os
import re
import sys
import time

FLAT_KEY_PATTERN = re.compile(r"/\d{4}-\d{2}-\d{2}T[^/]+\.json$")
PARTITIONED_PATTERN = re.compile(r"/\d{4}/\d{2}/\d{2}/[^/]+\.json$")
RAW_PREFIX = "analytics/raw/"


def is_partitioned(key: str) -> bool:
    return bool(PARTITIONED_PATTERN.search(key))


def is_migratable(key: str) -> bool:
    return bool(FLAT_KEY_PATTERN.search(key)) and not is_partitioned(key)


def make_partitioned_key(key: str) -> str:
    filename = key.split("/")[-1]
    prefix = "/".join(key.split("/")[:-1])
    date_path = filename[:10].replace("-", "/")  # "2026-05-22" -> "2026/05/22"
    return f"{prefix}/{date_path}/{filename}"


def list_flat_keys(client, bucket: str) -> list[str]:
    paginator = client.get_paginator("list_objects_v2")
    flat_keys = []
    for page in paginator.paginate(Bucket=bucket, Prefix=RAW_PREFIX):
        for obj in page.get("Contents", []):
            key = obj["Key"]
            if is_migratable(key):
                flat_keys.append(key)
    return flat_keys


def migrate(client, bucket: str, old_key: str, dry_run: bool) -> None:
    new_key = make_partitioned_key(old_key)
    if dry_run:
        print(f"[dry-run] {old_key}\n      --> {new_key}")
        return
    try:
        client.copy_object(
            Bucket=bucket,
            CopySource={"Bucket": bucket, "Key": old_key},
            Key=new_key,
        )
        client.delete_object(Bucket=bucket, Key=old_key)
        print(f"Migrated: {old_key} -> {new_key}")
    except Exception as exc:
        print(f"ERROR migrating {old_key}: {exc}", file=sys.stderr)


def get_s3_client():
    import boto3
    from botocore.config import Config

    endpoint = os.environ.get("S3_ENDPOINT_URL")
    if not endpoint:
        print("ERROR: S3_ENDPOINT_URL is not set", file=sys.stderr)
        sys.exit(1)
    return boto3.client(
        "s3",
        endpoint_url=endpoint,
        aws_access_key_id=os.environ.get("AWS_ACCESS_KEY_ID"),
        aws_secret_access_key=os.environ.get("AWS_SECRET_ACCESS_KEY"),
        config=Config(retries={"max_attempts": 10, "mode": "adaptive"}),
    )


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Migrate flat S3 files to date-partitioned layout"
    )
    parser.add_argument(
        "--apply", action="store_true", help="Execute migration (default: dry run)"
    )
    parser.add_argument(
        "--rate",
        type=float,
        default=10.0,
        help="max migrations/sec during --apply; 0 = unthrottled (default: 10)",
    )
    args = parser.parse_args()
    dry_run = not args.apply
    delay = 1.0 / args.rate if (not dry_run and args.rate > 0) else 0

    bucket = os.environ.get("S3_BUCKET")
    if not bucket:
        print("ERROR: S3_BUCKET is not set", file=sys.stderr)
        sys.exit(1)

    if dry_run:
        print("DRY RUN — pass --apply to execute\n")

    client = get_s3_client()
    flat_keys = list_flat_keys(client, bucket)

    if not flat_keys:
        print("No flat files found — nothing to migrate")
        sys.exit(0)

    print(f"Found {len(flat_keys)} file(s) to migrate")
    if delay:
        print(f"Throttling to {args.rate}/sec (pass --rate 0 to disable)\n")
    for key in flat_keys:
        migrate(client, bucket, key, dry_run=dry_run)
        if delay:
            time.sleep(delay)

    if dry_run:
        print(f"\nRun with --apply to migrate {len(flat_keys)} file(s)")


if __name__ == "__main__":
    main()
