#!/usr/bin/env bash
# Parse config.yml and emit runner entries, one per line, with fields
# separated by ASCII Unit Separator (\x1f) so empty fields are preserved:
#   title \x1f repo_url \x1f token \x1f workdir \x1f ephemeral \x1f pat
#     \x1f labels \x1f runner_group_id \x1f idle_regeneration \x1f image
#     \x1f startup_script \x1f additional_packages
#     \x1f watchdog_enabled \x1f watchdog_interval
#     \x1f docker_enabled
#     \x1f instances_min \x1f instances_max \x1f instances_headroom
#
# Also supports --get <dotted.key> to print a single scalar (e.g.
# `general.autoprune`, `defaults.image`). Prints empty string if missing.
#
# This is a minimal YAML parser tailored to our schema -- it is NOT a
# general-purpose YAML library. Supported constructs:
#   * top-level mappings: general / defaults / runners
#   * scalars (plain, single- or double-quoted)
#   * inline flow lists: [a, b, c]
#   * block lists of scalars:
#       key:
#         - a
#         - b
#   * one-level nested mappings under `defaults:` and runner items
#     (currently only `watchdog:` is recognised -- unknown nested keys
#     are ignored)
#   * "# comment" stripping (respects quotes)
#
# Usage:
#   parse-config.sh [<config.yml>]                 # default: $CONFIG_FILE
#   parse-config.sh --get <dotted.key> [<file>]

set -euo pipefail

mode="runners"
get_key=""
if [[ "${1:-}" == "--get" ]]; then
    mode="get"
    get_key="${2:-}"
    shift 2 || true
    if [[ -z "$get_key" ]]; then
        echo "parse-config: --get requires a dotted key argument" >&2
        exit 2
    fi
fi

CONFIG_FILE="${1:-${CONFIG_FILE:-/etc/github-runners/config.yml}}"

if [[ ! -r "$CONFIG_FILE" ]]; then
    echo "parse-config: config file not readable: $CONFIG_FILE" >&2
    exit 1
fi

awk -v MODE="$mode" -v GET_KEY="$get_key" -v GITHUB_PAT="${GITHUB_PAT:-}" '
function trim(s) {
    sub(/^[[:space:]]+/, "", s); sub(/[[:space:]]+$/, "", s); return s
}
# Strip an unquoted trailing "# comment" (respects single/double quotes).
function strip_comment(s,    i, n, c, in_sq, in_dq) {
    in_sq = 0; in_dq = 0; n = length(s)
    for (i = 1; i <= n; i++) {
        c = substr(s, i, 1)
        if (c == "\"" && !in_sq)        in_dq = !in_dq
        else if (c == "'\''" && !in_dq) in_sq = !in_sq
        else if (c == "#" && !in_sq && !in_dq) return substr(s, 1, i - 1)
    }
    return s
}
function unquote(s,    n, a, b) {
    s = trim(s); n = length(s)
    if (n < 2) return s
    a = substr(s, 1, 1); b = substr(s, n, 1)
    if ((a == "\"" && b == "\"") || (a == "'\''" && b == "'\''"))
        return substr(s, 2, n - 2)
    return s
}
function parse_scalar(s) { return unquote(trim(strip_comment(s))) }
function bool_true(s,    t) {
    t = tolower(trim(s))
    return (t == "true" || t == "yes" || t == "1" || t == "on")
}
# Parse "[a, b, \"c d\"]" or bare comma-separated -> space-separated string.
function parse_list_space(s,    inner, n, a, i, v, out) {
    s = trim(strip_comment(s)); out = ""
    if (s == "") return ""
    if (substr(s, 1, 1) == "[" && substr(s, length(s), 1) == "]")
        inner = substr(s, 2, length(s) - 2)
    else
        inner = s
    n = split(inner, a, ",")
    for (i = 1; i <= n; i++) {
        v = unquote(trim(a[i]))
        if (v != "") out = (out == "" ? v : out " " v)
    }
    return out
}
function indent_of(s,    i, n) {
    n = length(s)
    for (i = 1; i <= n; i++) if (substr(s, i, 1) != " ") return i - 1
    return n
}

function reset_item() {
    delete it; delete it_set
    it_has_pkgs = 0
}

function merge_pkgs(a, b,    arr, n, i, p, seen, out) {
    n = split(trim(a) " " trim(b), arr, /[[:space:]]+/)
    delete seen; out = ""
    for (i = 1; i <= n; i++) {
        p = arr[i]
        if (p == "" || (p in seen)) continue
        seen[p] = 1
        out = (out == "" ? p : out " " p)
    }
    return out
}

function emit_item(    title, repo, token, workdir, eph, pat, labels, group,
                       idle, image, startup, pkgs, wd_en, wd_iv, dk_en,
                       in_min, in_max, in_head) {
    title = ("title"    in it) ? it["title"]    : ""
    repo  = ("repo_url" in it) ? it["repo_url"] : ""
    if (title == "" || repo == "") {
        printf("parse-config: invalid runner entry (missing title/repo_url) at item %d\n", item_idx) > "/dev/stderr"
        exit 1
    }
    sub(/\/+$/, "", repo); sub(/\.git$/, "", repo)

    token   = ("token"   in it) ? it["token"]   : ""
    workdir = ("workdir" in it) ? it["workdir"] : ""
    sub(/^\/+/, "", workdir)

    eph = ("ephemeral" in it_set) \
          ? (bool_true(it["ephemeral"]) ? "1" : "0") \
          : (bool_true(d_ephemeral) ? "1" : "0")

    pat = ("pat" in it_set && it["pat"] != "") ? it["pat"] : d_pat
    if (pat == "") pat = GITHUB_PAT

    labels = ("labels"            in it_set && it["labels"]            != "") ? it["labels"]            : d_labels
    group  = ("runner_group_id"   in it_set && it["runner_group_id"]   != "") ? it["runner_group_id"]   : d_group
    idle   = ("idle_regeneration" in it_set && it["idle_regeneration"] != "") ? it["idle_regeneration"] : d_idle
    if (group == "") group = "1"
    if (idle  == "") idle  = "0"

    image = ("image" in it_set && it["image"] != "") ? it["image"] : d_image
    image = tolower(image)
    if (image == "") image = "debian:stable-slim"

    startup = ("startup_script" in it_set) ? it["startup_script"] : d_startup
    pkgs = merge_pkgs(d_packages, (it_has_pkgs ? it["additional_packages"] : ""))

    # watchdog.enabled / watchdog.interval (per-runner overrides defaults).
    wd_en = ("watchdog.enabled" in it_set) \
            ? (bool_true(it["watchdog.enabled"]) ? "1" : "0") \
            : (bool_true(d_wd_enabled) ? "1" : "0")
    wd_iv = ("watchdog.interval" in it_set && it["watchdog.interval"] != "") \
            ? it["watchdog.interval"] : d_wd_interval
    if (wd_iv == "") wd_iv = "0"

    # docker.enabled (per-runner overrides defaults).
    dk_en = ("docker.enabled" in it_set) \
            ? (bool_true(it["docker.enabled"]) ? "1" : "0") \
            : (bool_true(d_docker_enabled) ? "1" : "0")

    # instances.{min,max,headroom} -- pool sizing. Per-runner overrides
    # defaults. min defaults to 1, max defaults to min, headroom to 0.
    in_min  = ("instances.min"      in it_set && it["instances.min"]      != "") ? it["instances.min"]      : d_in_min
    in_max  = ("instances.max"      in it_set && it["instances.max"]      != "") ? it["instances.max"]      : d_in_max
    in_head = ("instances.headroom" in it_set && it["instances.headroom"] != "") ? it["instances.headroom"] : d_in_headroom
    if (in_min  == "" || in_min  + 0 < 1) in_min  = "1"
    if (in_max  == "")                    in_max  = in_min
    if (in_max  + 0 < in_min + 0)         in_max  = in_min
    if (in_head == "" || in_head + 0 < 0) in_head = "0"

    if (MODE != "runners") return

    if (eph == "1" && pat == "") {
        printf("parse-config: runner %s: ephemeral runners require pat (per-runner, defaults.pat, or $GITHUB_PAT)\n", title) > "/dev/stderr"
        exit 1
    }
    if (eph == "0" && token == "" && pat == "") {
        printf("parse-config: runner %s: persistent runners need token or pat\n", title) > "/dev/stderr"
        exit 1
    }

    printf("%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\n",
           title, repo, token, workdir, eph, pat, labels, group, idle,
           image, startup, pkgs, wd_en, wd_iv, dk_en,
           in_min, in_max, in_head)
}

function set_default(key, val) {
    if      (key == "ephemeral")         d_ephemeral = val
    else if (key == "pat")               d_pat = val
    else if (key == "labels")            d_labels = val
    else if (key == "runner_group_id")   d_group = val
    else if (key == "idle_regeneration") d_idle = val
    else if (key == "image")             d_image = tolower(val)
    else if (key == "startup_script")    d_startup = val
}

function set_item(key, val) { it[key] = val; it_set[key] = 1 }

BEGIN {
    section = ""; in_item = 0; item_idx = 0
    pending_scope = ""; pending_key = ""; pending_indent = -1

    d_ephemeral = "true"
    d_pat = ""
    d_labels = "self-hosted,linux,x64"
    d_group = "1"
    d_idle = "0"
    d_image = "debian:stable-slim"
    d_startup = ""
    d_packages = ""
    d_wd_enabled = "false"
    d_wd_interval = "0"
    d_docker_enabled = "false"
    d_in_min = "1"
    d_in_max = ""
    d_in_headroom = "0"

    g_autoprune = "false"
}

{ sub(/\r$/, "") }
/^[[:space:]]*(#.*)?$/ { next }

{
    stripped = strip_comment($0)
    indent   = indent_of(stripped)
    content  = substr(stripped, indent + 1)
    sub(/[[:space:]]+$/, "", content)

    # Top-level section key.
    if (indent == 0 && content ~ /^[A-Za-z_][A-Za-z0-9_]*:[[:space:]]*$/) {
        if (section == "runners" && in_item) { emit_item(); in_item = 0 }
        section = content; sub(/:.*/, "", section)
        pending_scope = ""; pending_key = ""; pending_indent = -1
        next
    }

    # Block-list continuation ("  - value" under a pending key:).
    if (pending_key != "" && indent > pending_indent && content ~ /^-[[:space:]]+/) {
        val = content; sub(/^-[[:space:]]+/, "", val)
        val = unquote(trim(strip_comment(val)))
        if (pending_scope == "defaults") {
            if (pending_key == "additional_packages")
                d_packages = (d_packages == "" ? val : d_packages " " val)
        } else if (pending_scope == "item") {
            if (pending_key == "additional_packages") {
                it["additional_packages"] = (it_has_pkgs ? it["additional_packages"] " " val : val)
                it_has_pkgs = 1; it_set["additional_packages"] = 1
            }
        }
        next
    }
    if (pending_key != "" && indent <= pending_indent) {
        pending_key = ""; pending_scope = ""; pending_indent = -1
    }

    # Runner list item start ("  - key: value").
    if (section == "runners" && content ~ /^-[[:space:]]+/) {
        if (in_item) emit_item()
        reset_item(); in_item = 1; item_idx++
        rest = content; sub(/^-[[:space:]]+/, "", rest)
        if (rest ~ /^[A-Za-z_][A-Za-z0-9_]*:/) {
            pos = index(rest, ":")
            k = substr(rest, 1, pos - 1)
            v = trim(substr(rest, pos + 1))
            if (v == "") {
                pending_scope = "item"; pending_key = k
                pending_indent = indent + 2
            } else if (k == "additional_packages") {
                it["additional_packages"] = parse_list_space(v)
                it_has_pkgs = 1; it_set[k] = 1
            } else {
                set_item(k, parse_scalar(v))
            }
        }
        next
    }

    # "key: value" inside a known section.
    if (content ~ /^[A-Za-z_][A-Za-z0-9_]*:/) {
        pos = index(content, ":")
        k = substr(content, 1, pos - 1)
        v = trim(substr(content, pos + 1))

        # Nested-map continuation: e.g. `defaults.watchdog.enabled`.
        # Active when a parent key (pending_key) was opened with no inline
        # value and we are now indented strictly deeper than that parent.
        if (pending_key != "" && indent > pending_indent) {
            if (pending_scope == "defaults" && pending_key == "watchdog") {
                if      (k == "enabled")  d_wd_enabled  = parse_scalar(v)
                else if (k == "interval") d_wd_interval = parse_scalar(v)
                next
            }
            if (pending_scope == "item" && pending_key == "watchdog") {
                if      (k == "enabled")  { it["watchdog.enabled"]  = parse_scalar(v); it_set["watchdog.enabled"]  = 1 }
                else if (k == "interval") { it["watchdog.interval"] = parse_scalar(v); it_set["watchdog.interval"] = 1 }
                next
            }
            if (pending_scope == "defaults" && pending_key == "docker") {
                if (k == "enabled") d_docker_enabled = parse_scalar(v)
                next
            }
            if (pending_scope == "item" && pending_key == "docker") {
                if (k == "enabled") {
                    it["docker.enabled"] = parse_scalar(v)
                    it_set["docker.enabled"] = 1
                }
                next
            }
            if (pending_scope == "defaults" && pending_key == "instances") {
                if      (k == "min")      d_in_min      = parse_scalar(v)
                else if (k == "max")      d_in_max      = parse_scalar(v)
                else if (k == "headroom") d_in_headroom = parse_scalar(v)
                next
            }
            if (pending_scope == "item" && pending_key == "instances") {
                if      (k == "min")      { it["instances.min"]      = parse_scalar(v); it_set["instances.min"]      = 1 }
                else if (k == "max")      { it["instances.max"]      = parse_scalar(v); it_set["instances.max"]      = 1 }
                else if (k == "headroom") { it["instances.headroom"] = parse_scalar(v); it_set["instances.headroom"] = 1 }
                next
            }
            # Unknown nested key -- swallow silently to avoid leaking into
            # the flat defaults namespace.
            next
        }

        if (section == "general") {
            if (k == "autoprune" && v != "")
                g_autoprune = (bool_true(parse_scalar(v)) ? "true" : "false")
            next
        }

        if (section == "defaults") {
            if (v == "") {
                pending_scope = "defaults"; pending_key = k; pending_indent = indent
            } else if (k == "additional_packages") {
                d_packages = parse_list_space(v)
            } else {
                set_default(k, parse_scalar(v))
            }
            next
        }

        if (section == "runners" && in_item) {
            if (v == "") {
                pending_scope = "item"; pending_key = k; pending_indent = indent
            } else if (k == "additional_packages") {
                it["additional_packages"] = parse_list_space(v)
                it_has_pkgs = 1; it_set[k] = 1
            } else {
                set_item(k, parse_scalar(v))
            }
            next
        }
    }
}

END {
    if (section == "runners" && in_item) emit_item()

    if (MODE == "get") {
             if (GET_KEY == "general.autoprune")       print g_autoprune
        else if (GET_KEY == "defaults.image")          print d_image
        else if (GET_KEY == "defaults.pat")            print d_pat
        else if (GET_KEY == "defaults.ephemeral")      print d_ephemeral
        else if (GET_KEY == "defaults.labels")         print d_labels
        else if (GET_KEY == "defaults.startup_script") print d_startup
        else print ""
    }
}
' "$CONFIG_FILE"
