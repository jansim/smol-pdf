#!/bin/bash
# Compresses a set of PDFs with smolpdf at several settings and, if installed, with
# PDF Squeezer's `pdfs` tool, then reports run time and output size per setting.
#
# Written for the bash 3.2 that ships with macOS (no associative arrays, no mapfile).
set -uo pipefail

usage() {
    cat <<'EOF'
usage: scripts/benchmark.sh [options] <file-or-list>...

Arguments are PDF files, or text files listing one PDF path per line
(blank lines and lines starting with # are ignored).

options:
  -n, --runs <n>            runs per file and setting; the fastest run counts (default: 1)
  -c, --config <name=args>  add a smolpdf setting, e.g. 'q40r100=-q 40 -r 100' (repeatable).
                            Without -c the built-in profiles are used:
                            lossless, low, medium, high, maximum
  -P, --squeezer-profile <path-or-name>
                            add a PDF Squeezer profile (.pdfscp file; repeatable).
                            Without -P, PDF Squeezer runs once with its default profile
      --no-squeezer         skip PDF Squeezer even if it is installed
      --keep-original       let smolpdf keep the original when the result is larger
                            (default: always measure the real output, --keep-larger)
      --build               build smolpdf in release mode first
  -o, --out <folder>        where to put results (default: a new folder under scratch/benchmark)
  -h, --help                show this help

environment:
  SMOLPDF   path to the smolpdf binary (default: build/…/smolpdf, .build/release/smolpdf, PATH)
  PDFS      path to PDF Squeezer's command-line tool (default: pdfs on PATH, /usr/local/bin/pdfs)

Results are written to <out>/results.csv (one row per run) and <out>/summary.txt.
The compressed files are kept in <out>/output/<tool>-<setting>/ so you can inspect them.
EOF
}

die() { echo "benchmark: $*" >&2; exit 64; }

CALLER_PWD="$PWD"
cd "$(dirname "$0")/.." || exit 1
REPO="$PWD"

runs=1
configs=()
squeezer_profiles=()
use_squeezer=1
keep_flag="--keep-larger"
build=0
out=""
inputs=()

while [ $# -gt 0 ]; do
    case "$1" in
        -h|--help) usage; exit 0 ;;
        -n|--runs) [ $# -ge 2 ] || die "$1 needs a value"; runs="$2"; shift ;;
        -c|--config) [ $# -ge 2 ] || die "$1 needs a value"; configs+=("$2"); shift ;;
        -P|--squeezer-profile) [ $# -ge 2 ] || die "$1 needs a value"; squeezer_profiles+=("$2"); shift ;;
        --no-squeezer) use_squeezer=0 ;;
        --keep-original) keep_flag="" ;;
        --build) build=1 ;;
        -o|--out) [ $# -ge 2 ] || die "$1 needs a value"; out="$2"; shift ;;
        -*) die "unknown option $1 (see --help)" ;;
        *) inputs+=("$1") ;;
    esac
    shift
done

case "$runs" in ''|*[!0-9]*|0) die "runs must be a positive number" ;; esac
[ ${#inputs[@]} -gt 0 ] || { usage >&2; exit 64; }
if [ ${#configs[@]} -eq 0 ]; then
    configs=("lossless=-p lossless" "low=-p low" "medium=-p medium" "high=-p high" "maximum=-p maximum")
fi

# Paths are resolved against the caller's directory, not the repo.
abspath() {
    case "$1" in
        /*) printf '%s\n' "$1" ;;
        *) printf '%s/%s\n' "$CALLER_PWD" "$1" ;;
    esac
}

# --- collect PDFs -------------------------------------------------------------
pdfs=()
add_pdf() {
    local p seen
    p="$(abspath "$1")"
    for seen in ${pdfs[@]+"${pdfs[@]}"}; do [ "$seen" = "$p" ] && return; done
    if [ -f "$p" ]; then pdfs+=("$p"); else echo "warning: not found, skipped: $1" >&2; fi
}
for arg in "${inputs[@]}"; do
    path="$(abspath "$arg")"
    if [ -f "$path" ] && [ "$(head -c 5 "$path")" = "%PDF-" ]; then
        add_pdf "$arg"
    elif [ -f "$path" ]; then
        # A list file: entries are relative to the list's own folder.
        list_dir="$(cd "$(dirname "$path")" && pwd)"
        while IFS= read -r line || [ -n "$line" ]; do
            line="${line%$'\r'}"
            case "$line" in ''|'#'*) continue ;; esac
            case "$line" in /*) add_pdf "$line" ;; *) add_pdf "$list_dir/$line" ;; esac
        done < "$path"
    else
        echo "warning: not found, skipped: $arg" >&2
    fi
done
[ ${#pdfs[@]} -gt 0 ] || die "no PDF files found"

# --- locate tools -------------------------------------------------------------
if [ "$build" = 1 ]; then
    swift build -c release --product smolpdf || die "build failed"
fi
smolpdf="${SMOLPDF:-}"
if [ -z "$smolpdf" ]; then
    for candidate in "$REPO/build/smol-pdf.app/Contents/Resources/smolpdf" \
                     "$REPO/.build/release/smolpdf" \
                     "$(command -v smolpdf 2>/dev/null)"; do
        if [ -n "$candidate" ] && [ -x "$candidate" ]; then smolpdf="$candidate"; break; fi
    done
fi
[ -n "$smolpdf" ] && [ -x "$smolpdf" ] || die "smolpdf not found; run with --build or set SMOLPDF"

pdfs_tool=""
if [ "$use_squeezer" = 1 ]; then
    pdfs_tool="${PDFS:-}"
    if [ -z "$pdfs_tool" ]; then
        for candidate in "$(command -v pdfs 2>/dev/null)" /usr/local/bin/pdfs /opt/homebrew/bin/pdfs; do
            if [ -n "$candidate" ] && [ -x "$candidate" ]; then pdfs_tool="$candidate"; break; fi
        done
    fi
    if [ -z "$pdfs_tool" ]; then
        echo "note: PDF Squeezer's command-line tool (pdfs) not found; skipping it." >&2
        echo "      Install it from PDF Squeezer's settings, or set PDFS=/path/to/pdfs." >&2
    fi
fi

# --- helpers ------------------------------------------------------------------
now() { perl -MTime::HiRes=time -e 'printf "%.6f\n", time'; }
filesize() { wc -c < "$1" | tr -d ' '; }
csv_field() { printf '"%s"' "$(printf '%s' "$1" | sed 's/"/""/g')"; }

[ -n "$out" ] || out="$REPO/scratch/benchmark/$(date +%Y%m%d-%H%M%S)"
out="$(abspath "$out")"
mkdir -p "$out/output" || die "cannot create $out"
csv="$out/results.csv"
log="$out/tool-output.log"
echo "tool,setting,file,run,seconds,original_bytes,output_bytes,status" > "$csv"
: > "$log"

# record <tool> <setting> <file> <run> <seconds> <orig> <out> <status>
record() {
    printf '%s,%s,%s,%s,%s,%s,%s,%s\n' "$1" "$(csv_field "$2")" "$(csv_field "$3")" \
        "$4" "$5" "$6" "$7" "$8" >> "$csv"
}

# run_one <tool> <setting> <pdf> <run> <output-file> <command...>
# Runs the command, times it, and records the size of <output-file>.
run_one() {
    local tool="$1" setting="$2" pdf="$3" run="$4" result="$5"
    shift 5
    local orig start end secs size status
    orig="$(filesize "$pdf")"
    echo "### $tool / $setting / $pdf (run $run): $*" >> "$log"
    start="$(now)"
    if "$@" >> "$log" 2>&1; then
        # No output after a clean exit means smolpdf kept the original (--keep-original).
        if [ -s "$result" ]; then status=ok; else status=kept; fi
    else
        status=failed
    fi
    end="$(now)"
    secs="$(awk -v a="$start" -v b="$end" 'BEGIN { printf "%.3f", b - a }')"
    case "$status" in
        ok) size="$(filesize "$result")" ;;
        kept) size="$orig" ;;
        *) size="" ;;
    esac
    record "$tool" "$setting" "$pdf" "$run" "$secs" "$orig" "$size" "$status"
    printf '  %-10s %-14s run %d  %7ss  %s\n' "$tool" "$setting" "$run" "$secs" \
        "$([ "$status" = failed ] && echo FAILED || echo "$orig → $size bytes$([ "$status" = kept ] && echo " (original kept)")")"
}

echo "smolpdf:      $smolpdf"
echo "PDF Squeezer: ${pdfs_tool:-not used}"
echo "Files:        ${#pdfs[@]}, runs per setting: $runs"
echo "Results:      $out"
echo

# --- benchmark ----------------------------------------------------------------
index=0
for pdf in "${pdfs[@]}"; do
    index=$((index + 1))
    # Index prefix keeps outputs apart when two inputs share a file name.
    # smolpdf always writes a lowercase .pdf extension.
    name="$(basename "$pdf")"
    base="$(printf '%03d' "$index")-${name%.*}.pdf"
    echo "[$index/${#pdfs[@]}] $pdf"

    for config in "${configs[@]}"; do
        name="${config%%=*}"
        args="${config#*=}"
        [ "$name" != "$config" ] || args=""
        dir="$out/output/smolpdf-$name"
        mkdir -p "$dir"
        # smolpdf names the output after the input, so stage the input under its unique name.
        staged="$out/output/.staged-$base"
        cp "$pdf" "$staged"
        run=1
        while [ "$run" -le "$runs" ]; do
            rm -f "$dir/.staged-$base"
            # shellcheck disable=SC2086  # args is intentionally word-split
            run_one smolpdf "$name" "$pdf" "$run" "$dir/.staged-$base" \
                "$smolpdf" $args $keep_flag -o "$dir" "$staged"
            run=$((run + 1))
        done
        [ -f "$dir/.staged-$base" ] && mv -f "$dir/.staged-$base" "$dir/$base"
        rm -f "$staged"
    done

    if [ -n "$pdfs_tool" ]; then
        if [ ${#squeezer_profiles[@]} -eq 0 ]; then sq_list=("default"); else sq_list=("${squeezer_profiles[@]}"); fi
        for profile in "${sq_list[@]}"; do
            name="$(basename "$profile" .pdfscp)"
            dir="$out/output/squeezer-$name"
            mkdir -p "$dir"
            run=1
            while [ "$run" -le "$runs" ]; do
                # pdfs compresses in place with --replace, so work on a fresh copy each run.
                cp "$pdf" "$dir/$base"
                if [ "$profile" = default ]; then
                    run_one squeezer "$name" "$pdf" "$run" "$dir/$base" \
                        "$pdfs_tool" "$dir/$base" --replace
                else
                    run_one squeezer "$name" "$pdf" "$run" "$dir/$base" \
                        "$pdfs_tool" "$dir/$base" --profile "$profile" --replace
                fi
                run=$((run + 1))
            done
        done
    fi
done

# --- summary ------------------------------------------------------------------
# Per setting: fastest run for each file, then totals across files.
summary="$out/summary.txt"
awk -F',' '
    function unq(s) { gsub(/^"|"$/, "", s); gsub(/""/, "\"", s); return s }
    NR == 1 { next }
    {
        key = $1 SUBSEP unq($2) SUBSEP unq($3)
        if ($8 == "failed") { failed[key] = 1; if (!(key in seen)) { seen[key] = 1; order[++n] = key }; next }
        if (!(key in seen)) { seen[key] = 1; order[++n] = key }
        if (!(key in best) || $5 + 0 < best[key]) best[key] = $5 + 0
        orig[key] = $6; size[key] = $7
    }
    END {
        for (i = 1; i <= n; i++) {
            split(order[i], k, SUBSEP)
            s = k[1] SUBSEP k[2]
            if (!(s in files)) { sorder[++m] = s; files[s] = 0; fails[s] = 0 }
            if (order[i] in best) {
                files[s]++; t[s] += best[order[i]]
                o[s] += orig[order[i]]; z[s] += size[order[i]]
                r = size[order[i]] / orig[order[i]]
                if (!(s in maxr) || r > maxr[s]) maxr[s] = r
                if (r < 1) smaller[s]++
            } else fails[s]++
        }
        printf "%-10s %-14s %5s %5s %10s %8s %12s %12s %8s %8s\n", \
            "tool", "setting", "ok", "fail", "time (s)", "s/file", "original", "output", "saved", "smaller"
        for (j = 1; j <= m; j++) {
            s = sorder[j]; split(s, k, SUBSEP)
            if (files[s] > 0)
                printf "%-10s %-14s %5d %5d %10.2f %8.2f %12s %12s %7.1f%% %4d/%-3d\n", \
                    k[1], k[2], files[s], fails[s], t[s], t[s] / files[s], mb(o[s]), mb(z[s]), \
                    (1 - z[s] / o[s]) * 100, smaller[s] + 0, files[s]
            else
                printf "%-10s %-14s %5d %5d %10s %8s %12s %12s %8s %8s\n", \
                    k[1], k[2], 0, fails[s], "-", "-", "-", "-", "-", "-"
        }
    }
    function mb(b) { return sprintf("%.2f MB", b / 1048576) }
' "$csv" > "$summary"

echo
cat "$summary"
echo
echo "time = sum over files of the fastest run; saved = total size reduction;"
echo "smaller = files whose output is smaller than the original."
echo "Per-run data: $csv"
echo "Tool output:  $log"
