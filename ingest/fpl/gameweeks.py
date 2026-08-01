"""Which gameweeks should this run fetch live points for?

Split out from `source.py` and kept **pure** (dict in, list of ints out) so it can be unit
tested without touching the network. ADR-0011 treats the FPL API as unofficial and
contract-unstable, so the tests drive this from captured `events` fixtures rather than from
the live endpoint — otherwise the suite would fail every August, when there is no current
gameweek at all.

The `event/{gw}/live/` endpoint has an awkward property: **it is mutable**. During a
gameweek, points churn as matches play; after the final whistle FPL still adjusts them
(bonus points, then post-match stat corrections) until the event is flagged `data_checked`.
So "fetch it once and never again" is wrong, and "fetch every gameweek every run" is wasteful
and impolite to an unofficial endpoint.

The rule below is the middle: re-fetch anything that can still move, and stop once it cannot.
Bronze is append-only (ADR-0003), so re-fetching is safe — each run appends another
observation of that gameweek and Silver (ADR-0005) reduces to the latest per
`(event_id, element_id)`.
"""

from __future__ import annotations

from typing import Any, Iterable

# Gameweeks in a Premier League season. Used only to bound the --backfill range.
MAX_EVENT_ID = 38


def select_live_gameweeks(events: Iterable[dict[str, Any]]) -> list[int]:
    """Return the gameweek ids whose live points are still worth fetching.

    A gameweek is *settled* when FPL sets `data_checked` — bonus points are applied and the
    stat corrections window has closed. Anything not settled can still move, so we take:

      - the current gameweek (`is_current`) — actively churning;
      - the previous gameweek (`is_previous`) — **even once `data_checked` is set**. FPL
        applies the final correction and flips the flag between two of our polls, so the
        newest rows in Bronze can predate settlement and the straggler rule below would
        never go back for them. `is_previous` holds for the whole following gameweek, so
        taking it unconditionally guarantees at least one post-settlement fetch;
      - any earlier gameweek that is `finished` but NOT `data_checked` — the straggler case,
        where a correction is outstanding and the run that would have caught it was skipped.

    Deliberately excluded: future gameweeks (`event/{gw}/live/` returns an empty `elements`
    list for them — a wasted request), and settled gameweeks (immutable; already in Bronze).

    **Pre-season returns `[]`** and that is a success, not a failure — in early August no
    event is current, previous, or finished. The caller must treat an empty selection as a
    no-op rather than an error.
    """
    selected: set[int] = set()

    for event in events:
        event_id = event.get("id")
        if event_id is None:
            continue  # malformed event — schema drift; Bronze tolerance (ADR-0011)

        if event.get("is_current") or event.get("is_previous"):
            selected.add(event_id)
        elif event.get("finished") and not event.get("data_checked"):
            selected.add(event_id)

    return sorted(selected)


def parse_backfill(spec: str) -> list[int]:
    """Parse a `--backfill` spec into gameweek ids: `"5"`, `"1-38"`, or `"1,3,5-7"`.

    Backfill exists for the season-history load and for replaying Bronze after a schema
    change. It bypasses `select_live_gameweeks` entirely — an explicit operator override,
    which is why it is a separate entry point rather than another branch in the rule above.
    """
    ids: set[int] = set()

    for part in spec.split(","):
        part = part.strip()
        if not part:
            continue

        if "-" in part:
            lo_str, _, hi_str = part.partition("-")
            lo, hi = int(lo_str), int(hi_str)
            if lo > hi:
                raise ValueError(f"backfill range {part!r} is inverted (low > high)")
            ids.update(range(lo, hi + 1))
        else:
            ids.add(int(part))

    out_of_range = [i for i in ids if not 1 <= i <= MAX_EVENT_ID]
    if out_of_range:
        raise ValueError(
            f"gameweek(s) {sorted(out_of_range)} outside 1-{MAX_EVENT_ID}"
        )

    return sorted(ids)
