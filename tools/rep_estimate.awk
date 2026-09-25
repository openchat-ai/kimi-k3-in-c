#!/usr/bin/env bash
# Zero-model repetition estimator for --spec (n-gram draft) gain.
# Re-implements the engine's spec_draft (k3_run.c:416) semantics: a draft fires for
# the LAST 4-gram only once it has occurred at least twice BEFORE the current position
# and both occurrences' continuations AGREE; draft length = the agreed run, capped.
# Reads an ids file (one id per line, or whitespace-separated) from $1/$IDS.
#
# Run on the PROMPT token file. During generation the sequence ALSO contains the
# model's own output echoing earlier text, so this prompt-only figure is a lower
# bound on what the PC will see. Prints the draft histogram and per-K mean accepted
# length (the trunk-amortization factor for --spec K sweeps).
set -u

IDS="${1:-${IDS:?set IDS=... to the prompt ids file}}"

awk '
{
    for (f = 1; f <= NF; f++) {
    t++
    a[t] = $f + 0
    if (t >= 4) {
        g = a[t-3] "," a[t-2] "," a[t-1] "," a[t]
        key = "k" g
        if (has[key]) {
            # g occurred before; spec_draft scans for its TWO most recent hits, so at
            # any position the stored pair (hi=most recent, lo=second) below t-3 qualifies.
            hi = last1[key] + 0; lo = last2[key] + 0
            nd = 0
            for (i = 0; nd < 16 && hi + 4 + i <= t; i++) {
                cc = a[hi + 4 + i]
                if (lo > 0 && (lo + 4 + i > t || a[lo + 4 + i] != cc)) break
                nd++
            }
            hist[nd]++
            if (nd >= 1) fired++
            tot += nd
            if (nd > max) max = nd
        }
        # store this occurrence: keep the two most recent, most-recent first
        last2[key] = last1[key] + 0
        last1[key] = t - 3
        has[key] = 1
    }
    }
}
END {
    n = t
    base = n - 4
    if (base < 1) { printf "ids=%d: too short to estimate\n", n; exit }
    printf "ids=%d base=%d\n", n, base
    if (fired == 0) { printf "no 4-gram replay in the prompt -> --spec will stay dormant (0.91x risk).\n"; exit }
    printf "draft fires on %.1f%% of positions (prompt-only lower bound)\n", fired / base * 100
    printf "draft-length distribution (cap 16):\n"
    for (d = 1; d <= max && d <= 16; d++) if (hist[d]) printf "  len %d: %d (%.1f%%)\n", d, hist[d], hist[d]/base*100
    printf "mean draft len when fired = %.1f (max %d)\n", tot / fired, max
    for (k = 4; k <= 8; k += 4) {
        s = 0; f = 0
        for (d = 1; d <= max && d <= 16; d++) { dd = (d < k ? d : k); s += hist[d] * dd; f += hist[d] }
        if (f) printf "  spec %d: expected mean accepted ~%.2f tokens/sweep (trunk amortized /%.2f)\n", k, s/f, s/f+1
    }
}
' "$IDS"