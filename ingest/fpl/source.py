"""FPL API -> Bronze, as a dlt source (ADR-0010 EL, ADR-0011 source, ADR-0003 layer).

**No business logic here.** ADR-0010 is explicit that dlt does extract-load only: records are
written as the API returned them, and every interpretation (typing, validation, dedup,
renaming) belongs to dbt in Silver (ADR-0005). Two deliberate exceptions, both *provenance*
rather than transformation, and both flagged in the code below:

  1. The `bootstrap-static` envelope is split into one resource per collection it contains.
     dlt needs a table per record shape, and 564 players and 20 teams cannot share one. The
     records themselves are untouched — only the envelope is unwrapped.
  2. `event/{gw}/live/` responses do not carry the gameweek they belong to, so `event_id` is
     stamped onto each row. Without it the rows are unattributable once they land.

Everything is `write_disposition="append"`: Bronze is append-only and replayable (ADR-0003).
Re-ingesting a still-churning gameweek therefore adds an observation rather than corrupting
one, which is exactly what `gameweeks.select_live_gameweeks` relies on.
"""

from __future__ import annotations

from typing import Any, Iterator

import dlt

# dlt's requests wrapper, not bare `requests`: it ships with retry + exponential backoff on
# connection errors and 5xx already configured. ADR-0011 commits us to polling this
# unofficial endpoint *politely*, and this is the cheapest way to honour that.
from dlt.sources.helpers import requests

FPL_API_BASE = "https://fantasy.premierleague.com/api"

# An unofficial API with no published rate limit deserves an honest caller. A real UA with a
# contact URL means that if this job ever misbehaves, FPL can see who it is instead of
# blackholing an anonymous scraper.
USER_AGENT = "pitch-control/0.1 (+https://github.com/stephendelaney/pitch-control)"

REQUEST_TIMEOUT = 30.0

# The list collections inside `bootstrap-static`; each becomes one Bronze table of the same
# name. Keeping this as data (not seven near-identical functions) means adding a collection is
# a one-line change, and a collection that *disappears* upstream is a logged warning rather
# than a crash. It doubles as the allowlist — `bootstrap-static`'s non-list members
# (`game_settings`, `game_config`, `total_players`) are handled by `game_meta` below.
#
# Names deliberately keep FPL's own vocabulary ("elements", not "players"): Bronze is
# source-faithful down to the naming, and translating to domain language is Silver's job
# (ADR-0005). The source is already identified by the `fpl` dataset directory, so no prefix.
BOOTSTRAP_COLLECTIONS: tuple[str, ...] = (
    "elements",       # players (~105 fields each)
    "teams",
    "events",         # the 38 gameweeks
    "element_types",  # GK / DEF / MID / FWD
    "element_stats",  # the stat vocabulary (goals, assists, ...)
    "phases",
    "chips",
)


def _get(path: str) -> Any:
    """GET one FPL endpoint and return the decoded JSON."""
    response = requests.get(
        f"{FPL_API_BASE}/{path}",
        headers={"User-Agent": USER_AGENT, "Accept": "application/json"},
        timeout=REQUEST_TIMEOUT,
    )
    response.raise_for_status()
    return response.json()


# `max_table_nesting=0` is load-bearing, not a tuning knob. dlt's default is to *normalise*
# nested structures into child tables — a first FPL load produces things like
# `game_meta__game_config__rules__percentile_ranks`. That is a relational transformation,
# and ADR-0003 reserves all interpretation for Silver: Bronze must be able to reproduce the
# source payload. It is also fragile in exactly the way ADR-0011 warns about — a nesting
# change upstream would silently add or drop whole tables. At 0, nested objects and arrays
# stay inline as JSON in the row, and one API collection maps to exactly one Bronze table.
@dlt.source(name="fpl", max_table_nesting=0)
def fpl_source(gameweeks: list[int] | None = None) -> Any:
    """The FPL Bronze source.

    `gameweeks` is resolved by the caller (`run_fpl.py`) rather than here, so that the
    selection rule stays pure and testable and this function stays about I/O.
    """
    # `bootstrap-static` is ~1.3 MB and feeds seven resources. Fetch it once per run and
    # share it: seven requests for one payload would be exactly the impoliteness ADR-0011
    # warns about. dlt evaluates resources lazily, so this closure is the shared cache.
    bootstrap_cache: dict[str, Any] = {}

    def bootstrap() -> Any:
        if "data" not in bootstrap_cache:
            bootstrap_cache["data"] = _get("bootstrap-static/")
        return bootstrap_cache["data"]

    def make_bootstrap_resource(collection: str) -> Any:
        @dlt.resource(name=collection, write_disposition="append")
        def _resource() -> Iterator[dict[str, Any]]:
            records = bootstrap().get(collection)

            if records is None:
                # Schema drift on an unofficial API (ADR-0011). Losing one collection must
                # not cost us the other six, so this degrades instead of raising — the
                # missing table is then visible as a freshness miss downstream (ADR-0012).
                print(f"  ! bootstrap-static has no '{collection}' — skipping")
                return

            yield from records

        return _resource

    resources = [make_bootstrap_resource(c) for c in BOOTSTRAP_COLLECTIONS]

    @dlt.resource(name="game_meta", write_disposition="append")
    def game_meta() -> Iterator[dict[str, Any]]:
        """The scalar/dict leftovers of `bootstrap-static`, as a single row per run.

        `game_settings` and `game_config` are objects, not collections, and `total_players`
        is a bare int — none of them is a table on its own. Grouped into one row so the
        season's rules-of-the-day are captured alongside everything else; ADR-0018 mirrors
        FPL's transfer/economy rules, so a record of when those settings changed is worth
        having.
        """
        payload = bootstrap()
        yield {
            "total_players": payload.get("total_players"),
            "game_settings": payload.get("game_settings"),
            "game_config": payload.get("game_config"),
        }

    @dlt.resource(name="fixtures", write_disposition="append")
    def fixtures() -> Iterator[dict[str, Any]]:
        """All 380 fixtures. Appended whole each run — scores, kickoff times and postponements
        all mutate in place upstream, and a full snapshot is both simplest and replayable."""
        yield from _get("fixtures/")

    @dlt.resource(name="event_live", write_disposition="append")
    def event_live() -> Iterator[dict[str, Any]]:
        """Per-player points for each selected gameweek (ADR-0017's scoring oracle)."""
        if not gameweeks:
            # Pre-season, or every gameweek already settled. A no-op run, not a failure.
            print("  - no gameweeks need live points this run")
            return

        for event_id in gameweeks:
            payload = _get(f"event/{event_id}/live/")
            elements = payload.get("elements") or []
            print(f"  - GW{event_id}: {len(elements)} player rows")

            for element in elements:
                # Provenance stamp (exception 2 in the module docstring): the response has no
                # gameweek field, so without this the row cannot be attributed to a gameweek.
                yield {**element, "event_id": event_id}

    return [*resources, game_meta, fixtures, event_live]
