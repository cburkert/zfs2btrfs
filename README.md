# zfs2btrfs

This is a simple shell script that transfers a ZFS filesystem into to Btrfs filesystem.

**Warning: This script is experimental and still under development.**

## Features

* maintain snapshots
* convert subvolume recursively (not really tested)

## Usage

`bash zfs2btrfs.sh <zfs filesystem/volume> <btrfs filesystem>`

Example:
`bash zfs2btrfs.sh tank/home /mnt/data/home`
