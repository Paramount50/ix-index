from __future__ import annotations

import argparse
import datetime as dt
import logging
from dataclasses import dataclass
from pathlib import Path
from typing import cast

import duckdb
import httpx


LOGGER = logging.getLogger("daily_scraper")


@dataclass(frozen=True)
class CliArgs:
    output_dir: Path
    repo: str
    github_api_url: str
    user_agent: str


@dataclass(frozen=True)
class RepoMetric:
    run_date: dt.date
    fetched_at: dt.datetime
    source_url: str
    repository: str
    default_branch: str
    stars: int
    forks: int
    open_issues: int


def parse_args() -> CliArgs:
    parser = argparse.ArgumentParser(
        prog="daily-scraper",
        description="Fetch one GitHub repository record and write it as Parquet.",
    )
    _ = parser.add_argument(
        "--output-dir",
        type=Path,
        required=True,
        help="Directory for Parquet output.",
    )
    _ = parser.add_argument(
        "--repo",
        default="indexable-inc/index",
        help="GitHub repository in owner/name form.",
    )
    _ = parser.add_argument(
        "--github-api-url",
        default="https://api.github.com",
        help="GitHub API base URL.",
    )
    _ = parser.add_argument(
        "--user-agent",
        default="ix-daily-scraper-example/0.1",
        help="HTTP User-Agent header.",
    )
    namespace = parser.parse_args()

    return CliArgs(
        output_dir=cast(Path, namespace.output_dir),
        repo=cast(str, namespace.repo),
        github_api_url=cast(str, namespace.github_api_url),
        user_agent=cast(str, namespace.user_agent),
    )


def int_field(payload: dict[str, object], key: str) -> int:
    value = payload.get(key)
    if not isinstance(value, int):
        raise TypeError(f"{key} is missing or is not an integer")
    return value


def str_field(payload: dict[str, object], key: str) -> str:
    value = payload.get(key)
    if not isinstance(value, str):
        raise TypeError(f"{key} is missing or is not a string")
    return value


def fetch_repo_metric(repo: str, api_url: str, user_agent: str) -> RepoMetric:
    source_url = f"{api_url.rstrip('/')}/repos/{repo}"
    headers = {
        "Accept": "application/vnd.github+json",
        "User-Agent": user_agent,
    }

    with httpx.Client(headers=headers, follow_redirects=True, timeout=30.0) as client:
        response = client.get(source_url)
        _ = response.raise_for_status()
        raw_payload = cast(object, response.json())

    if not isinstance(raw_payload, dict):
        raise TypeError("GitHub returned a non-object response")

    payload = cast(dict[str, object], raw_payload)
    fetched_at = dt.datetime.now(dt.UTC).replace(microsecond=0)
    return RepoMetric(
        run_date=fetched_at.date(),
        fetched_at=fetched_at,
        source_url=source_url,
        repository=str_field(payload, "full_name"),
        default_branch=str_field(payload, "default_branch"),
        stars=int_field(payload, "stargazers_count"),
        forks=int_field(payload, "forks_count"),
        open_issues=int_field(payload, "open_issues_count"),
    )


def sql_string(value: str) -> str:
    return "'" + value.replace("'", "''") + "'"


def write_parquet(metric: RepoMetric, output_dir: Path) -> Path:
    output_dir.mkdir(parents=True, exist_ok=True)
    output_path = output_dir / f"github-repo-metrics-{metric.run_date.isoformat()}.parquet"

    connection = duckdb.connect(database=":memory:")
    try:
        _ = connection.execute(
            """
            create table repo_metrics (
              run_date date,
              fetched_at timestamp with time zone,
              source_url varchar,
              repository varchar,
              default_branch varchar,
              stars integer,
              forks integer,
              open_issues integer
            )
            """,
        )
        _ = connection.execute(
            """
            insert into repo_metrics values (?, ?, ?, ?, ?, ?, ?, ?)
            """,
            [
                metric.run_date,
                metric.fetched_at,
                metric.source_url,
                metric.repository,
                metric.default_branch,
                metric.stars,
                metric.forks,
                metric.open_issues,
            ],
        )
        copy_sql = (
            f"copy repo_metrics to {sql_string(str(output_path))} (format parquet, compression zstd)"
        )
        _ = connection.execute(copy_sql)
    finally:
        connection.close()

    return output_path


def main() -> None:
    logging.basicConfig(level=logging.INFO, format="%(levelname)s %(message)s")
    args = parse_args()

    metric = fetch_repo_metric(
        repo=args.repo,
        api_url=args.github_api_url,
        user_agent=args.user_agent,
    )
    output_path = write_parquet(metric=metric, output_dir=args.output_dir)
    LOGGER.info("wrote %s", output_path)
