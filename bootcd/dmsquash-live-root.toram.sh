#!/bin/sh
 
. /lib/dracut-lib.sh
[ -f /tmp/root.info ] && . /tmp/root.info
 
PATH=$PATH:/sbin:/usr/sbin
 
if getarg rdlivedebug; then
    exec > /tmp/liveroot.$$.out
    exec 2>> /tmp/liveroot.$$.out
    set -x
fi
 
[ -z "$1" ] && exit 1
livedev="$1"
 
# parse various live image specific options that make sense to be
# specified as their own things
live_dir=$(getarg live_dir)
[ -z "$live_dir" ] && live_dir="LiveOS"
getarg live_ram && live_ram="yes"
getarg no_eject && no_eject="yes"
getarg reset_overlay && reset_overlay="yes"
getarg readonly_overlay && readonly_overlay="--readonly" || readonly_overlay=""
overlay=$(getarg overlay)
 
getarg toram && toram="yes"
 
# FIXME: we need to be able to hide the plymouth splash for the check really
[ -e $livedev ] & fs=$(blkid -s TYPE -o value $livedev)
if [ "$fs" = "iso9660" -o "$fs" = "udf" ]; then
    check="yes"
fi
getarg check || check=""
if [ -n "$check" ]; then
    checkisomd5 --verbose $livedev || :
    if [ $? -ne 0 ]; then
  die "CD check failed!"
  exit 1
    fi
fi
 
getarg ro && liverw=ro
getarg rw && liverw=rw
[ -z "$liverw" ] && liverw=ro
# mount the backing of the live image first
mkdir -p /dev/.initramfs/live
mount -n -t $fstype -o $liverw $livedev /dev/.initramfs/live
RES=$?
if [ "$RES" != "0" ]; then
    die "Failed to mount block device of live image"
    exit 1
fi
 
# overlay setup helper function
do_live_overlay() {
    # create a sparse file for the overlay
    # overlay: if non-ram overlay searching is desired, do it,
    #              otherwise, create traditional overlay in ram
    OVERLAY_LOOPDEV=$( losetup -f )
 
    l=$(blkid -s LABEL -o value $livedev) || l=""
    u=$(blkid -s UUID -o value $livedev) || u=""
 
    if [ -z "$overlay" ]; then
        pathspec="/${live_dir}/overlay-$l-$u"
    elif ( echo $overlay | grep -q ":" ); then
        # pathspec specified, extract
        pathspec=$( echo $overlay | sed -e 's/^.*://' )
    fi
 
    if [ -z "$pathspec" -o "$pathspec" = "auto" ]; then
        pathspec="/${live_dir}/overlay-$l-$u"
    fi
    devspec=$( echo $overlay | sed -e 's/:.*$//' )
 
    # need to know where to look for the overlay
    setup=""
    if [ -n "$devspec" -a -n "$pathspec" -a -n "$overlay" ]; then
        mkdir /overlayfs
        mount -n -t auto $devspec /overlayfs || :
        if [ -f /overlayfs$pathspec -a -w /overlayfs$pathspec ]; then
            losetup $OVERLAY_LOOPDEV /overlayfs$pathspec
            if [ -n "$reset_overlay" ]; then
               dd if=/dev/zero of=$OVERLAY_LOOPDEV bs=64k count=1 2>/dev/null
            fi
            setup="yes"
        fi
        umount -l /overlayfs || :
    fi
 
    if [ -z "$setup" ]; then
        if [ -n "$devspec" -a -n "$pathspec" ]; then
           warn "Unable to find persistent overlay; using temporary"
           sleep 5
        fi
 
        dd if=/dev/null of=/overlay bs=1024 count=1 seek=$((512*1024)) 2> /dev/null
        losetup $OVERLAY_LOOPDEV /overlay
    fi
 
    # set up the snapshot
    echo 0 `blockdev --getsz $BASE_LOOPDEV` snapshot $BASE_LOOPDEV $OVERLAY_LOOPDEV p 8 | dmsetup create $readonly_overlay live-rw
}
 
# live cd helper function
do_live_from_base_loop() {
    do_live_overlay
}
 
# we might have a genMinInstDelta delta file for anaconda to take advantage of
if [ -e /dev/.initramfs/live/${live_dir}/osmin.img ]; then
    OSMINSQFS=/dev/.initramfs/live/${live_dir}/osmin.img
fi
 
if [ -n "$OSMINSQFS" ]; then
    # decompress the delta data
    dd if=$OSMINSQFS of=/osmin.img 2> /dev/null
    OSMIN_SQUASHED_LOOPDEV=$( losetup -f )
    losetup -r $OSMIN_SQUASHED_LOOPDEV /osmin.img
    mkdir -p /squashfs.osmin
    mount -n -t squashfs -o ro $OSMIN_SQUASHED_LOOPDEV /squashfs.osmin
    OSMIN_LOOPDEV=$( losetup -f )
    losetup -r $OSMIN_LOOPDEV /squashfs.osmin/osmin
    umount -l /squashfs.osmin
fi
 
# we might have just an embedded ext3 to use as rootfs (uncompressed live)
if [ -e /dev/.initramfs/live/${live_dir}/ext3fs.img ]; then
  EXT3FS="/dev/.initramfs/live/${live_dir}/ext3fs.img"
fi
 
if [ -n "$EXT3FS" ] ; then
    BASE_LOOPDEV=$( losetup -f )
    losetup -r $BASE_LOOPDEV $EXT3FS
 
    # Create overlay only if toram is not set
    if [ -z "$toram" ] ; then
        do_live_from_base_loop
    fi
fi
 
# we might have an embedded ext3 on squashfs to use as rootfs (compressed live)
if [ -e /dev/.initramfs/live/${live_dir}/squashfs.img ]; then
  SQUASHED="/dev/.initramfs/live/${live_dir}/squashfs.img"
fi
 
if [ -e "$SQUASHED" ] ; then
    if [ -n "$live_ram" ] ; then
        echo "Copying live image to RAM..."
        echo "(this may take a few minutes)"
        dd if=$SQUASHED of=/squashed.img bs=512 2> /dev/null
        umount -n /dev/.initramfs/live
        echo "Done copying live image to RAM."
        if [ ! -n "$no_eject" ]; then
            eject -p $livedev || :
        fi
        SQUASHED="/squashed.img"
    fi
 
    SQUASHED_LOOPDEV=$( losetup -f )
    losetup -r $SQUASHED_LOOPDEV $SQUASHED
    mkdir -p /squashfs
    mount -n -t squashfs -o ro $SQUASHED_LOOPDEV /squashfs
 
    BASE_LOOPDEV=$( losetup -f )
    losetup -r $BASE_LOOPDEV /squashfs/LiveOS/ext3fs.img
 
    umount -l /squashfs
 
    # Create overlay only if toram is not set
    if [ -z "$toram" ] ; then
        do_live_from_base_loop
    fi
fi
 
# If the kernel parameter toram is set, create a tmpfs device and copy the 
# filesystem to it. Continue the boot process with this tmpfs device as
# a writable root device.
if [ -n "$toram" ] ; then
    blocks=$( blockdev --getsz $BASE_LOOPDEV )
 
    echo "Create tmpfs ($blocks blocks) for the root filesystem..."
    mkdir -p /image
    mount -n -t tmpfs -o nr_blocks=$blocks tmpfs /image
 
    echo "Copy filesystem image to tmpfs... (this may take a few minutes)"
    dd if=$BASE_LOOPDEV of=/image/rootfs.img
 
    ROOTFS_LOOPDEV=$( losetup -f )
    echo "Create loop device for the root filesystem: $ROOTFS_LOOPDEV"
    losetup $ROOTFS_LOOPDEV /image/rootfs.img
 
    echo "It's time to clean up.. "
 
    echo " > Umounting images"
    umount -l /image
    umount -l /dev/.initramfs/live
 
    echo " > Detach $OSMIN_LOOPDEV"
    losetup -d $OSMIN_LOOPDEV
 
    echo " > Detach $OSMIN_SQUASHED_LOOPDEV"
    losetup -d $OSMIN_SQUASHED_LOOPDEV
    
    echo " > Detach $BASE_LOOPDEV"
    losetup -d $BASE_LOOPDEV
    
    echo " > Detach $SQUASHED_LOOPDEV"
    losetup -d $SQUASHED_LOOPDEV
    
    echo " > Detach /dev/loop0"
    losetup -d /dev/loop0
 
    losetup -a
 
    echo "Root filesystem is now on $ROOTFS_LOOPDEV."
    echo
 
    ln -s $ROOTFS_LOOPDEV /dev/root
    printf '/bin/mount -o rw %s %s\n' "$ROOTFS_LOOPDEV" "$NEWROOT" > /mount/01-$$-live.sh
    exit 0
fi
 
if [ -b "$OSMIN_LOOPDEV" ]; then
    # set up the devicemapper snapshot device, which will merge
    # the normal live fs image, and the delta, into a minimzied fs image
    if [ -z "$toram" ] ; then
        echo "0 $( blockdev --getsz $BASE_LOOPDEV ) snapshot $BASE_LOOPDEV $OSMIN_LOOPDEV p 8" | dmsetup create --readonly live-osimg-min
    fi
fi
 
ROOTFLAGS="$(getarg rootflags)"
if [ -n "$ROOTFLAGS" ]; then
    ROOTFLAGS="-o $ROOTFLAGS"
fi
 
ln -fs /dev/mapper/live-rw /dev/root
printf '/bin/mount %s /dev/mapper/live-rw %s\n' "$ROOTFLAGS" "$NEWROOT" > /mount/01-$$-live.sh
 
exit 0
