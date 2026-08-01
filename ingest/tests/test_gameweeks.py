"""Unit tests for gameweek selection.

Fixtures are hand-built, not captured from the live API — ADR-0011 says the source is
unofficial and can change without notice, so a test that hits it would be testing FPL's
uptime rather than our rule. The pre-season case below is the state the API was actually in
when this was written (2026-08-01: GW1 `is_next`, nothing current or finished).
"""

from __future__ import annotations

import pytest

from fpl.gameweeks import MAX_EVENT_ID, parse_backfill, select_live_gameweeks


def event(event_id: int, **flags: bool) -> dict:
    """An `events` entry with every flag false unless named."""
    base = {
        "id": event_id,
        "is_current": False,
        "is_previous": False,
        "is_next": False,
        "finished": False,
        "data_checked": False,
    }
    base.update(flags)
    return base


class TestSelectLiveGameweeks:
    def test_preseason_selects_nothing(self):
        """August: GW1 is next, nothing has been played. Empty is the correct answer."""
        events = [event(1, is_next=True)] + [event(i) for i in range(2, 39)]
        assert select_live_gameweeks(events) == []

    def test_current_and_next_gameweeks(self):
        """The current gameweek is always taken; the next one never is."""
        events = [
            event(1, finished=True, data_checked=True),
            event(2, is_previous=True, finished=True, data_checked=True),
            event(3, is_current=True),
            event(4, is_next=True),
        ]
        # GW1 is settled and no longer `is_previous` — dropped. GW4 has no data yet.
        # GW2 is settled but still `is_previous`: see the test below for why it stays.
        assert select_live_gameweeks(events) == [2, 3]

    def test_previous_gameweek_included_until_data_checked(self):
        """The bonus-points window: GW1 is finished but not yet checked, so it can still move."""
        events = [
            event(1, is_previous=True, finished=True, data_checked=False),
            event(2, is_current=True),
        ]
        assert select_live_gameweeks(events) == [1, 2]

    def test_settled_previous_gameweek_still_included(self):
        """`is_previous` is taken even once `data_checked` is true, and this is the subtle
        part of the rule.

        The straggler branch stops selecting a gameweek the instant FPL flips `data_checked`.
        But FPL applies the correction *and* sets the flag between two of our polls — so the
        newest observation in Bronze may be from before the correction landed, and nothing
        would ever go back for it. Keeping `is_previous` guarantees at least one fetch after
        settlement (it stays `is_previous` for the whole following gameweek), for the price
        of one request per run.
        """
        events = [
            event(1, is_previous=True, finished=True, data_checked=True),
            event(2, is_current=True),
        ]
        assert select_live_gameweeks(events) == [1, 2]

    def test_straggler_unchecked_gameweek_is_recovered(self):
        """The case this rule exists for: GW3 finished but was never data_checked, and the
        run that should have picked up the correction did not happen. A later run recovers
        it instead of leaving Bronze permanently stale for that week."""
        events = [
            event(1, finished=True, data_checked=True),
            event(2, finished=True, data_checked=True),
            event(3, finished=True, data_checked=False),
            event(4, is_previous=True, finished=True, data_checked=True),
            event(5, is_current=True),
        ]
        assert select_live_gameweeks(events) == [3, 4, 5]

    def test_future_gameweeks_never_selected(self):
        """`event/{gw}/live/` returns an empty elements list for these — a wasted request."""
        events = [event(i, is_next=(i == 1)) for i in range(1, 39)]
        assert select_live_gameweeks(events) == []

    def test_malformed_event_is_skipped_not_fatal(self):
        """Schema drift tolerance (ADR-0011): an id-less event loses that event, not the run."""
        events = [{"is_current": True}, event(2, is_current=True)]
        assert select_live_gameweeks(events) == [2]

    def test_result_is_sorted_and_deduped(self):
        events = [event(5, is_current=True), event(5, is_current=True), event(2, is_previous=True)]
        assert select_live_gameweeks(events) == [2, 5]

    def test_empty_input(self):
        assert select_live_gameweeks([]) == []


class TestParseBackfill:
    def test_single(self):
        assert parse_backfill("5") == [5]

    def test_range(self):
        assert parse_backfill("1-4") == [1, 2, 3, 4]

    def test_full_season(self):
        assert parse_backfill(f"1-{MAX_EVENT_ID}") == list(range(1, MAX_EVENT_ID + 1))

    def test_mixed_list_is_sorted_and_deduped(self):
        assert parse_backfill("7,1,3-5,4") == [1, 3, 4, 5, 7]

    def test_whitespace_tolerated(self):
        assert parse_backfill(" 1 , 3 - 5 ") == [1, 3, 4, 5]

    def test_inverted_range_rejected(self):
        with pytest.raises(ValueError, match="inverted"):
            parse_backfill("9-2")

    @pytest.mark.parametrize("spec", ["0", "39", "0-5", "35-40"])
    def test_out_of_range_rejected(self, spec):
        """A typo'd backfill would otherwise fire dozens of pointless requests at an
        unofficial API — cheap to catch, rude not to."""
        with pytest.raises(ValueError, match="outside"):
            parse_backfill(spec)

    def test_non_numeric_rejected(self):
        with pytest.raises(ValueError):
            parse_backfill("gw5")
