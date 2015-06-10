#!/bin/bash

set -eu

VERBOSE=1
#DEBUG=1

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

function echo_info {
  [[ -v VERBOSE ]] && echo $@ || true
}

function echo_debug {
  [[ -v DEBUG ]] && echo $@ || true
}

convert $@
