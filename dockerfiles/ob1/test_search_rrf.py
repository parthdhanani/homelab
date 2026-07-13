"""
Regression check for the RRF scoring formula in main.py's _search() (SQL, ~line 260).
Mirrors that exact formula in Python so it can be asserted without touching the live DB.
If the SQL formula changes, update RRF_K / rrf_score below to match, or this test lies.

Run: python3 test_search_rrf.py
"""

RRF_K = 60  # must match main.py's RRF_K


def rrf_score(vec_rank: int | None, kw_rank: int | None, k: int = RRF_K) -> float:
    score = 0.0
    if vec_rank is not None:
        score += 1.0 / (k + vec_rank)
    if kw_rank is not None:
        score += 1.0 / (k + kw_rank)
    return score


def demo():
    # A doc that's #1 in both lists must outrank everything else.
    top_both = rrf_score(vec_rank=1, kw_rank=1)
    mid_both = rrf_score(vec_rank=5, kw_rank=5)
    assert top_both > mid_both, "top-ranked-in-both should beat mid-ranked-in-both"

    # RRF deliberately resists letting one extreme signal dominate — a #1 keyword
    # hit that's weak in vector search (#20) should still beat a doc that's fully
    # absent from keyword search entirely, but need NOT beat a doc that's decent
    # in *both* lists. This is the actual fix over the old flat-boost approach:
    # score reflects consistent relevance across both signals, not a single
    # extreme hit or a binary keyword-present/absent flag.
    strong_keyword_weak_vector = rrf_score(vec_rank=20, kw_rank=1)
    vector_only_no_keyword = rrf_score(vec_rank=20, kw_rank=None)
    assert strong_keyword_weak_vector > vector_only_no_keyword, (
        "adding a #1 keyword hit must increase score over vector-only"
    )
    mediocre_both = rrf_score(vec_rank=8, kw_rank=8)
    assert mediocre_both > 0, "consistent-in-both should score positively too"

    # Present-in-only-one-list still scores, absent-from-both scores exactly 0.
    only_vector = rrf_score(vec_rank=3, kw_rank=None)
    assert only_vector > 0
    assert rrf_score(None, None) == 0.0

    # Monotonic: worse rank (higher number) in either list never increases the score.
    assert rrf_score(1, 1) > rrf_score(2, 1) > rrf_score(3, 1)
    assert rrf_score(1, 1) > rrf_score(1, 2) > rrf_score(1, 3)

    # Score is bounded — two rank-1 hits is the max any single row can get.
    assert rrf_score(1, 1) == 2.0 / (RRF_K + 1)

    print("OK — RRF formula properties hold (K=%d)" % RRF_K)


if __name__ == "__main__":
    demo()
