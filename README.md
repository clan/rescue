# Rescue & Initiramfs build script

\# gen_initramfs_img.sh -k [initramfs|rescue|...]

initramfs: load storage/fs driver for real root file system, then switch to it.

rescue: load storage/input/net/fs driver and some useful programs for system rescue, then run the whole system in memory.

edit *.conf to for more drivers (storage & file system etc) and utilities.
