#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  A FILE'S MODE IN GIT MATCHES WHAT THE FILE IS.
#
#  The author kept losing the executable bit on scripts and having to chmod them back by hand,
#  "inconsistently". The inconsistency was the clue: nothing was stripping the bit. The bit was
#  never in the INDEX. A file recorded 100644 comes back 100644 on every checkout, stash pop and
#  branch switch, so a manual `chmod u+x` lives until the next git operation and then vanishes
#  — at a moment unrelated to the chmod, which is what made it look random. Four demos were in
#  that state because I took the bit OFF with `git update-index --chmod=-x` to keep an unrelated
#  mode change out of a commit. Staging modes you do not want is a thing you do not do; if a
#  mode change is not part of the commit, leave it unstaged.
#
#  So the mode is a fact about the file that this gate holds, and it holds it in the INDEX —
#  the worktree is one checkout, the index is what everybody else gets:
#
#     runnable  (demo/ tests/ tools/)   starts with a shebang  ⇒  100755
#     library   (controls/, ft-*.bash)  you `source` it        ⇒  100644, shebang or not
#
#  The shebang is the same fact stated in the file, which is why the two are checked together:
#  tools/keycap.bash was executable with `.#!/usr/bin/env bash` on line 1 — one stray byte, and
#  the kernel stops seeing a shebang at all and hands a bash script to sh.
# ─────────────────────────────────────────────────────────────────────────────
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$here/tests/_harness.bash"
cd "$here" || exit 1

# mode<TAB>path for every tracked file, and the same list split by what each file IS.
_MODES=$(git ls-files -s | awk '{print $1 "\t" $4}')
_has_shebang() { [[ $(head -c 2 "$1" 2>/dev/null) == '#!' ]]; }

note "every script you RUN is executable in the index"
notexec=""
while IFS=$'\t' read -r mode path; do
    case $path in demo/*|tests/*|tools/*) ;; *) continue ;; esac
    _has_shebang "$path" || continue
    [[ $mode == 100755 ]] || notexec+="$path "
done <<< "$_MODES"
check "no runnable script is recorded 100644" "${notexec% }" ""

note "every file you SOURCE is not executable"
wrongexec=""
while IFS=$'\t' read -r mode path; do
    case $path in controls/*.bash|ft-*.bash|fruity-tui.bash) ;; *) continue ;; esac
    [[ $mode == 100644 ]] || wrongexec+="$path "
done <<< "$_MODES"
check "no library file is recorded 100755" "${wrongexec% }" ""

# The bit and the shebang are one claim: an executable file the kernel cannot launch is worse
# than a non-executable one, because the failure is a syntax error from a shell you did not
# choose rather than "permission denied".
note "executable means launchable"
noshebang=""
while IFS=$'\t' read -r mode path; do
    [[ $mode == 100755 ]] || continue
    _has_shebang "$path" || noshebang+="$path "
done <<< "$_MODES"
check "every executable file starts with a shebang" "${noshebang% }" ""

badshebang=""
while IFS=$'\t' read -r mode path; do
    _has_shebang "$path" || continue
    read -r line < "$path"
    [[ $line == '#!'*[!\ ]* ]] || badshebang+="$path "
done <<< "$_MODES"
check "every shebang names an interpreter" "${badshebang% }" ""

# The worktree is allowed to be more permissive than the index (a local umask, a copy), but a
# script that is NOT executable here is one the author will trip over today.
note "the checkout the author is standing in agrees"
worktree=""
while IFS=$'\t' read -r mode path; do
    [[ $mode == 100755 ]] || continue
    [[ -x $path ]] || worktree+="$path "
done <<< "$_MODES"
check "every script recorded 100755 is executable on disk" "${worktree% }" ""

summary
