#!/usr/bin/env bash
# fm-captain-board.sh - prove which captain-held tasks are open on the
# captain's Notion board, so bin/fm-session-start.sh can leave them out.
#
# Usage: fm-captain-board.sh <config-file> [pairs-file]
#
# Input (pairs-file, else stdin): one "<task-id><TAB><url>" line per URL
#   cited by a captain-held task.
# stdout: each task id with at least one cited Notion page that is, read live
#   now, an open card on the board: a page whose parent is the configured
#   Notion data source, not archived or in trash, and whose State is not Done.
#   Ids print once each, sorted. Any URL that is not a Notion page, any failed
#   page read, and any other page proves nothing for its task.
# Exit 0 after a completed check (zero proven ids is a valid result). Exit 1,
#   printing nothing on stdout, when the config is unusable or the board's data
#   source itself cannot be read; the caller then keeps every held item.
#
# Config file (config/captain-board, local and gitignored), key=value lines:
#   notion-cards=<data source id>   required; the board's card list
#   ntn=<executable>                optional; an `ntn`-compatible command,
#                                   default `ntn` on PATH
# Reads only; never writes to Notion.
set -u

case "${1:-}" in
  ''|-h|--help) sed -n '2,/^set -u/{/^set -u/d;s/^# \{0,1\}//;p;}' "$0"; [ -n "${1:-}" ]; exit ;;
esac
conf=$1
[ -z "${2:-}" ] || exec <"$2"
get() { [ -f "$conf" ] && sed -n "s/^$1=//p" "$conf" | tail -n 1; }
ds=$(get notion-cards | tr -d '-' | tr 'A-F' 'a-f')
ntn=$(get ntn); ntn=${ntn:-ntn}
case "$ds" in
  *[!0-9a-f]*|'') echo "fm-captain-board: $conf needs notion-cards=<data source id>" >&2; exit 1 ;;
esac
if ! "$ntn" api "v1/data_sources/$ds" -X GET </dev/null >/dev/null 2>&1; then
  echo "fm-captain-board: cannot read Notion data source $ds through $ntn" >&2
  exit 1
fi

while IFS=$'\t' read -r id url; do
  [ -n "$id" ] || continue
  # The page id is the last standalone 32-hex or dashed-UUID run of a Notion
  # URL path; a title slug ending in a hex letter must not join it.
  page=$(printf '%s\n' "$url" | perl -ne '
    m{^https://([a-z0-9-]+\.)?notion\.(so|site|com)/([^?#]*)}i or exit;
    my @ids = $3 =~ /(?<![0-9a-f])([0-9a-f]{32}|[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12})(?![0-9a-f])/gi;
    ($_ = lc $ids[-1]) =~ s/-//g, print if @ids')
  [ -n "$page" ] || continue
  json=$("$ntn" api "v1/pages/$page" -X GET </dev/null 2>/dev/null) || continue
  printf '%s' "$json" | perl -MJSON::PP -e '
    my $p = eval { JSON::PP->new->decode(do { local $/; <STDIN> }) } or exit 1;
    my $parent = lc($p->{parent}{data_source_id} // ""); $parent =~ s/-//g;
    my $state = (($p->{properties}{State} // {})->{select} // {})->{name} // "";
    exit !(($p->{object} // "") eq "page" && $parent eq $ARGV[0]
      && !$p->{archived} && !$p->{in_trash} && $state ne "Done");
  ' "$ds" && printf '%s\n' "$id"
done | sort -u
