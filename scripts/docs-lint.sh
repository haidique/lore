#!/usr/bin/env bash
#
# scripts/docs-lint.sh — Run the Lore docs linter trio.
#
# Runs Vale, markdownlint-cli2, and lychee against the Lore documentation
# tree. Continues through all three even when one fails so you see every
# finding. Warns (on stderr) when a linter is missing locally; the run is
# considered complete-enough as long as at least one linter ran.
#
# The summary distinguishes three outcomes per tool so a crash is never
# mistaken for a clean pass or a findings list:
#   passed    — the linter ran and reported nothing.
#   FINDINGS  — the linter ran and reported issues to fix.
#   ERRORED   — the linter could not run to completion (bad input, parse
#               error, …); its result is not a verdict on your docs.
#
# Exit codes:
#   0  Every linter that ran was clean. Missing linters only warn.
#   1  At least one linter ran and reported findings, and none errored.
#   2  At least one linter errored (could not run to completion), or no
#      linter is installed at all — the run's signal is incomplete.
#
# Usage: bash scripts/docs-lint.sh
#
# Reference: docs/developing/doc-standards/tools/README.md

set -uo pipefail

readonly NOT_INSTALLED=255
readonly LYCHEE_CONFIG="docs/developing/doc-standards/tools/lychee/lychee.toml"
readonly INSTALL_HINT="Install: see docs/developing/doc-standards/tools/README.md"

# Resolve repo root from the script's location so the script behaves the
# same regardless of where it is invoked from.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
readonly REPO_ROOT

# warn prints a single-line warning to stderr.
warn() {
    printf 'WARNING: %s\n' "$*" >&2
}

# err prints a single-line error to stderr.
err() {
    printf 'ERROR: %s\n' "$*" >&2
}

# run_linter runs a single linter command. It prints a section header and the
# linter's output on stdout, and stashes the combined output (stdout+stderr)
# in the global REPLY_OUTPUT so the caller can classify the result. Returns
# the linter's exit code, or NOT_INSTALLED (255) when it is not on PATH.
#
# Output is captured (not streamed) so it can be classified; the linters here
# finish in well under a second, so buffering costs nothing in practice.
#
# Args:
#   $1     human-readable name for the section header (e.g. "Vale (prose)")
#   $2     command to invoke (e.g. "vale")
#   $3..$n arguments forwarded to the command
REPLY_OUTPUT=""
run_linter() {
    local name="$1"
    local cmd="$2"
    shift 2

    printf '\n=== %s ===\n' "${name}"

    if ! command -v "${cmd}" >/dev/null 2>&1; then
        warn "${cmd} is not installed; skipping."
        printf '%s\n' "${INSTALL_HINT}" >&2
        REPLY_OUTPUT=""
        return "${NOT_INSTALLED}"
    fi

    local out code
    out="$("${cmd}" "$@" 2>&1)"
    code=$?
    printf '%s\n' "${out}"
    REPLY_OUTPUT="${out}"
    return "${code}"
}

# classify maps a linter's (exit code, output) to one of:
#   clean | findings | errored | missing
#
# Exit-code semantics differ per tool, so each is handled explicitly:
#   Vale          0 = no errors, but it ALSO exits 0 when it only prints
#                 warnings/suggestions (MinAlertLevel = warning), so the code
#                 alone cannot tell clean from findings. 2 = a fatal/parse
#                 error. We read Vale's own summary line to detect findings.
#   markdownlint  0 = clean, 1 = findings, >=2 = operational error.
#   lychee        0 = clean, 2 = broken links (findings), 1/>=3 = runtime error.
#
# Args: $1 tool key (vale|markdownlint|lychee)  $2 exit code  $3 output
classify() {
    local tool="$1" code="$2" out="$3"

    if (( code == NOT_INSTALLED )); then
        printf 'missing'
        return
    fi

    case "${tool}" in
        vale)
            # Vale's summary reads "✔ 0 errors, 0 warnings and 0 suggestions"
            # when clean and "✖ N errors, M warnings …" when not. Any non-zero
            # count (or the ✖ glyph) means findings; exit >= 2 means it aborted.
            if (( code >= 2 )); then
                printf 'errored'
            elif printf '%s' "${out}" | grep -qE '✖|[1-9][0-9]* (error|warning|suggestion)'; then
                printf 'findings'
            elif (( code != 0 )); then
                printf 'findings'
            else
                printf 'clean'
            fi
            ;;
        markdownlint)
            case "${code}" in
                0) printf 'clean' ;;
                1) printf 'findings' ;;
                *) printf 'errored' ;;
            esac
            ;;
        lychee)
            case "${code}" in
                0) printf 'clean' ;;
                2) printf 'findings' ;;
                *) printf 'errored' ;;
            esac
            ;;
    esac
}

# state_label renders a classification as an aligned summary cell.
state_label() {
    local state="$1" code="$2"
    case "${state}" in
        clean)    printf 'passed   — no findings' ;;
        findings) printf 'FINDINGS — issues reported (review the output above)' ;;
        errored)  printf 'ERRORED  — could not run to completion (exit %s)' "${code}" ;;
        missing)  printf 'missing  — not installed (skipped)' ;;
    esac
}

main() {
    if ! cd "${REPO_ROOT}"; then
        err "Failed to change directory to repo root: ${REPO_ROOT}"
        return 2
    fi

    # docs-epic/ is internal-only. Include it in the linted set when present;
    # community contributors will not have this directory.
    local include_epic=0
    [[ -d "docs-epic" ]] && include_epic=1

    # Build per-tool argument arrays. The shape varies by tool:
    #   Vale takes paths (directories and files).
    #   markdownlint-cli2 takes globs.
    #   lychee takes paths (directories only).
    #
    # NOTE: a root README.md is intentionally NOT linted yet — it does not
    # exist on this branch. When it lands, add "README.md" to vale_args and
    # 'README.md' to md_args (lychee scans directories, so it needs no change).
    local -a vale_args md_args lychee_args
    if (( include_epic )); then
        vale_args=("docs/" "docs-epic/")
        md_args=('docs/**/*.md' 'docs-epic/**/*.md')
        lychee_args=("docs/" "docs-epic/")
    else
        vale_args=("docs/")
        md_args=('docs/**/*.md')
        lychee_args=("docs/")
    fi

    # Run each linter, then classify its result from (exit code, output).
    # Capture each REPLY_OUTPUT immediately, before the next run overwrites it.
    local vale_exit md_exit lychee_exit
    local vale_state md_state lychee_state

    run_linter "Vale (prose)" vale --glob='!*-template.md' "${vale_args[@]}"
    vale_exit=$?
    vale_state="$(classify vale "${vale_exit}" "${REPLY_OUTPUT}")"

    run_linter "markdownlint (structure)" markdownlint-cli2 "${md_args[@]}"
    md_exit=$?
    md_state="$(classify markdownlint "${md_exit}" "${REPLY_OUTPUT}")"

    run_linter "lychee (links)" lychee --config "${LYCHEE_CONFIG}" "${lychee_args[@]}"
    lychee_exit=$?
    lychee_state="$(classify lychee "${lychee_exit}" "${REPLY_OUTPUT}")"

    # Final summary, always printed.
    printf '\n=== Summary ===\n'
    printf 'Vale:         %s\n' "$(state_label "${vale_state}" "${vale_exit}")"
    printf 'markdownlint: %s\n' "$(state_label "${md_state}" "${md_exit}")"
    printf 'lychee:       %s\n' "$(state_label "${lychee_state}" "${lychee_exit}")"
    printf '\n'

    # Tally states, then pick the exit code by severity:
    # errored (incomplete signal) outranks findings outranks clean.
    local errored=0 findings=0 clean=0 missing=0
    local state
    for state in "${vale_state}" "${md_state}" "${lychee_state}"; do
        case "${state}" in
            errored)  errored=$(( errored + 1 )) ;;
            findings) findings=$(( findings + 1 )) ;;
            clean)    clean=$(( clean + 1 )) ;;
            missing)  missing=$(( missing + 1 )) ;;
        esac
    done

    local ran=$(( errored + findings + clean ))

    # No linter installed at all: fail loud — the run produced no signal.
    if (( ran == 0 )); then
        err "No linters are installed locally; the run produced no signal."
        printf '%s\n' "${INSTALL_HINT}" >&2
        return 2
    fi

    # Some linters missing: warn, but missing alone does not fail the run.
    if (( missing > 0 )); then
        warn "${missing} of 3 linters were missing — your local check is incomplete. Maintainer review will run the full set."
    fi

    # A linter that could not run leaves the check incomplete: exit 2.
    if (( errored > 0 )); then
        err "${errored} linter(s) could not run to completion — the check is incomplete. Fix the errors above and re-run."
        return 2
    fi

    # Everything that ran completed; findings (if any) set the exit code.
    if (( findings > 0 )); then
        return 1
    fi

    return 0
}

main "$@"
