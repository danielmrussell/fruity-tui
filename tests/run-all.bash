#!/usr/bin/env bash
# Run every test file and print one line each. Exits nonzero if any file failed.
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1
failed=0
# STDERR IS THE ALT SCREEN. Anything bash prints there — "bad array subscript", "unbound
# variable", "bad substitution" — is written straight over the running UI, and it is invisible
# to assertions, which only read what a function RETURNS. The suite was emitting six such
# errors per run with nobody looking. Capturing it separately turns the whole class into an
# automatic failure: a test file that makes the framework complain now fails, whatever it
# asserted. (The tests themselves print only to stdout.)
errdir=$(mktemp -d); trap 'rm -rf "$errdir"' EXIT
for t in tests/test-*.bash; do
    name=$(basename "$t")
    out=$(bash "$t" 2>"$errdir/$name.err")
    tally=$(printf '%s\n' "$out" | grep -Eo '[0-9]+/[0-9]+ assertions passed' | tail -1)
    noise=""
    [[ -s "$errdir/$name.err" ]] && noise=$(grep -c . "$errdir/$name.err")
    # ANCHORED to the harness's own marker — `  FAIL ` at the start of a line. A bare
    # substring match read the word out of a test's PROSE ("…nor may a FAILED encode clear
    # it") and reported a file with 32/32 passing as a failure. A gate that cries wolf over
    # its own section headings is one people learn to ignore.
    if printf '%s\n' "$out" | grep -q '^  FAIL '; then
        failed=$(( failed + 1 ))
        printf 'FAIL  %-32s %s\n' "$name" "${tally:-no tally}"
        printf '%s\n' "$out" | grep -A2 '^  FAIL ' | sed 's/^/        /'
    elif [[ -n "$noise" ]]; then
        failed=$(( failed + 1 ))
        printf 'FAIL  %-32s %s — %s line(s) on STDERR\n' "$name" "${tally:-no tally}" "$noise"
        sort -u "$errdir/$name.err" | head -4 | sed 's/^/        /'
    else
        printf 'ok    %-32s %s\n' "$name" "${tally:-no tally}"
    fi
done
echo
if (( failed )); then echo "$failed test file(s) FAILED"; exit 1; fi
echo "all test files passed"
