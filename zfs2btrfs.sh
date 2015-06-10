#!/bin/bash


PROG="${0##*/}"
VERSION="0.0" # not released yet

set -eu
trap unexpected_err ERR

function unexpected_err() {
  echo "An unexpected error has occured at line '$BASH_LINENO'. Please report." >&2
  exit 99
}

function usage() {
  cat <<EOF
usage: $PROG [options] <zfs volume> <btrfs volume>

Transfers given ZFS volume to Btrfs target.

$PROG provides options:
  Output
    -h     Shows this usage dialog
    -m     Set difference calculation mode:
            rsync Use rsync (slower but more stable; default)
            zfs   Use zfs diff (zfsonlinux has a bug here)
    -v     Verbose output
    -d     Debug output
EOF
}

function convert() {
  local zvol=${1:?zfs volume required}
  local bvol=${2:?btrfs volume required}
  local sub

for sub in `zfs list -r -t filesystem -H -o name "$zvol"`
do
    local relsubname="${sub#$zvol}"
    local bsubvol="$bvol/$relsubname"
    local mountpoint=`zfs get -H -o value mountpoint "$sub"`
    echo_info "Converting subvolume $relsubname..."
    if [[ -n "$relsubname" ]] # vol not parent volume itself
    then
      btrfs subvolume create "$bsubvol"
    fi

    local prevsnap=""
    for snap in `zfs list -r -t snap -H -o name "$sub"`
    do
      local snaplabel=${snap#$sub@}
      if [[ -e "$bsubvol/$snaplabel" ]]
      then
        echo_info "snapshot already exists. skip..."
        prevsnap="$snap"
        continue
      fi

      echo_info "Converting subvolume $relsubname snapshot $snaplabel..."
      if [[ -z "$prevsnap" ]]
      then
        # copy everythink for this is the first snapshot
        cp -a "$mountpoint/.zfs/snapshot/$snaplabel/." "$bsubvol"
      else
        if [[ "$MODE" == "zfsdiff" ]]
        then
          # apply zfs changes to btrfs
          IFS=$'\t'
          zfs diff -H -F "$prevsnap" "$snap" | tee /tmp/log | \
            while read -r changetype filetype rawpath renamepath
          do
            echo_debug "diff: $changetype $filetype $rawpath $renamepath"
            eval rawpath=\$\'$rawpath\' # zfs diff uses octal encoding for spaces
            local path="${rawpath#$mountpoint}"
            local zpath="$mountpoint/.zfs/snapshot/$snaplabel/$path"
            local bpath="$bsubvol/$path"
            local brenamepath="$bsubvol/${renamepath#$mountpoint}"
            apply_change "$changetype" "$filetype" "$zpath" "$bpath" "$brenamepath"
          done
        else
          # use rsync
          rsync -ac --delete ${VERBOSE:+--progress} "$mountpoint/.zfs/snapshot/$snaplabel/" "$bsubvol"
        fi
      fi
      echo_debug btrfs subvolume snapshot -r "$bsubvol" "$bsubvol/$snaplabel"
      btrfs subvolume snapshot -r "$bsubvol" "$bsubvol/$snaplabel"
      prevsnap="$snap"
    done
  done
}

function apply_change() {
  local changetype=${1:?changetype missing}
  local filetype=${2:?filetype missing}
  local zpath=${3:?zfs path missing}
  local bpath=${4:?btrfs path missing}
  local brenamepath=${5:-}
  echo_debug "Apply change: $@"

  case "$changetype" in
    "-") rm -rf "$bpath";;
    "+") apply_creation "$filetype" "$zpath" "$bpath";;
    "M") apply_modification "$filetype" "$zpath" "$bpath";;
    "R") mv "$bpath" "$brenamepath";;
    *) echo "Unknown change type" >&2; exit 3;;
  esac
}

function apply_creation() {
  local filetype=${1:?filetype missing}
  local zpath=${2:?zfs path missing}
  local bpath=${3:?btrfs path missing}
  echo_debug "Apply creation: $@"

  case "$filetype" in
    "/") mkdir -p "$bpath";;
    *) cp -a "$zpath" "$bpath";;
    # TODO: distinguish more filetypes, some type cannot be copied like this
  esac
}

function apply_modification() {
  local filetype=${1:?filetype missing}
  local zpath=${2:?zfs path missing}
  local bpath=${3:?btrfs path missing}
  echo_debug "Apply mod: $@"

  case "$filetype" in
    "/") true;; # currently no changes to directories besides contained files are supported
    *) cp -a "$zpath" "$bpath";;
    # TODO: distinguish more filetypes, some type cannot be copied like this
  esac
}

function echo_info() {
  [[ -v VERBOSE ]] && echo $@ || true
}

function echo_debug() {
  [[ -v DEBUG ]] && echo $@ || true
}

function set_diff_mode() {
  case ${1:-rsync} in
    rsync)
      MODE="rsync"
      ;;
    zfs)
      MODE="zfsdiff"
      ;;
    *)
      return 1
      ;;
  esac
  return 0
}


while getopts ":dhm:v" opt; do
  case $opt in
    d)
      DEBUG=1
      ;;
    h)
      usage
      exit 0
      ;;
    m)
      set_diff_mode $OPTARG || { echo "Unknown mode $OPTARG" >&2; usage; exit 1; }
      ;;
    v)
      VERBOSE=1
      ;;
    \?)
      echo "Invalid option: -$OPTARG" >&2
      usage
      exit 1
      ;;
  esac
done

convert $@
