"""Ingest the configured PSA Poverty Statistics workbook into Landing."""

from datetime import datetime
from pathlib import Path
from urllib.parse import unquote, urljoin, urlparse

import requests
import yaml
from bs4 import BeautifulSoup


def find_config() -> Path:
    """Find config/sources.yaml from local or Databricks execution."""
    start_locations = [Path.cwd()]

    script_path = globals().get("__file__")
    if script_path:
        start_locations.append(Path(script_path).resolve().parent)

    for start in start_locations:
        for folder in (start, *start.parents):
            config = folder / "config" / "sources.yaml"

            if config.exists():
                return config

    raise FileNotFoundError("config/sources.yaml not found.")


CONFIG = find_config()


def main() -> None:
    with CONFIG.open(encoding="utf-8") as file:
        source = yaml.safe_load(file)["sources"]["poverty"]

    page = requests.get(
        source["source_page_url"],
        timeout=60,
    )
    page.raise_for_status()

    soup = BeautifulSoup(page.text, "html.parser")

    links = [
        link
        for link in soup.find_all("a", href=True)
        if "statistical tables" in link.get_text(" ", strip=True).lower()
    ]

    if len(links) != 1:
        raise RuntimeError(
            f"Expected 1 Statistical Tables attachment, found {len(links)}."
        )

    date_text = soup.find(
        string=lambda text: text and "Release Date" in text
    )

    if date_text is None:
        raise RuntimeError("PSA release date not found.")

    date_element = date_text.parent
    release_date = date_element.find_next().get_text(" ", strip=True)

    try:
        as_of_date = datetime.strptime(
            release_date,
            "%A, %B %d, %Y",
        )
    except ValueError as error:
        raise RuntimeError(
            f"Unexpected PSA release date: {release_date}"
        ) from error

    file_url = urljoin(
        page.url,
        links[0]["href"],
    )

    source_name = Path(
        unquote(urlparse(file_url).path)
    ).name

    if not source_name:
        raise RuntimeError(
            "PSA source filename could not be determined."
        )

    extension = Path(source_name).suffix

    file_name = (
        f"psa_poverty_asof_{as_of_date:%Y%m%d}"
        f"{extension}"
    )

    landing_file = (
        Path(source["landing_path"])
        / file_name
    )

    if landing_file.exists():
        print(
            f"SKIPPED: {file_name} already exists."
        )
        return

    response = requests.get(
        file_url,
        timeout=60,
    )
    response.raise_for_status()

    content_type = response.headers.get(
        "Content-Type",
        "",
    ).lower()

    if "text/html" in content_type:
        raise RuntimeError(
            "PSA returned HTML instead of the source file."
        )

    landing_file.parent.mkdir(
        parents=True,
        exist_ok=True,
    )

    landing_file.write_bytes(
        response.content
    )

    print(
        f"INGESTED: {file_name}"
    )


if __name__ == "__main__":
    main()