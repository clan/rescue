#!/bin/bash

export PATH="/sbin:/usr/sbin:"${PATH}

BOLD="\033[1m"
GOOD="\033[32;1m"
BAD="\033[31;1m"
WARN="\033[33;1m"
NORMAL="\033[0m"

good_msg()
{
    msg="$@"
    msg="${msg:-...}"

    echo -e "${GOOD}>>${NORMAL} ${msg} ${NORMAL}"
}

bad_msg()
{
    msg="$@"
    msg="${msg:-...}"

    echo -e "${BAD}>>${NORMAL} ${msg} ${NORMAL}"
}

die()
{
    local ret="${1:-0}"
    shift

    bad_msg "$@"
    exit $ret
}

iter_dirname()
{
    d0=$1
    while [ True ] ; do
        d1=$(dirname ${d0})
        if [ "${d1}" == "." -o "${d0}" = "${d1}" ] ; then
            break
        fi
        echo ${d1}
        d0=${d1}
    done
}

gen_file()
{
    f=$1
    if [[ "$#" -lt 2 ]] ; then
        fn=${f}
    else
        fn=$2
    fi

    local list_files=""
    if [ -h "${f}" ] ; then
        ft=$(readlink -e "${f}")
        list_files=${list_filess}"slink ${fn} ${ft} 0777 0 0\n"
        fm=$(stat -c "%04a" "${ft}")
        list_files=${list_files}"file ${ft} ${ft} ${fm} 0 0\n"
    else
        fm=$(stat -c "%04a" "${f}")
        list_files=${list_files}"file ${fn} ${f} ${fm} 0 0\n"
    fi

    echo -e ${list_files}
}

ARGVS=$(getopt -o k: -- "$@") || die $? getopt failed.
eval set -- "$ARGVS"

KIND="initramfs"

while true; do
    case "$1" in
        -k) KIND="$2"; shift 2;;
        --) shift; break;;
        *) die 1 "getopt internal error!";;
    esac
done

PROG_LIST=${KIND}.conf
if [ ! -s "${PROG_LIST}" ] ; then
    die 1 "${PROG_LIST} not found"
fi

KV=$1
[ -z "${KV}" ] && KV=$(uname -r)
km_directory="/lib/modules/${KV}/"
if [ ! -d "${km_directory}" ] ; then
    die 1 "modules directory for kernel ${KV} not found"
fi
good_msg "build initramfs image w/ kernel ${KV}"

list_items="
slink /linuxrc init 0777 0 0

# /bin
dir /bin 0755 0 0

dir /dev 0755 0 0
nod /dev/console 0660 0 0 c 5 1
nod /dev/null 0660 0 0 c 1 3
dir /dev/shm 1777 0 0
nod /dev/tty0 0600 0 0 c 4 0
nod /dev/tty1 0600 0 0 c 4 1
nod /dev/ttyS0 0600 0 0 c 4 64
nod /dev/zero 0660 0 0 c 1 5

dir /etc 0755 0 0

dir /lib64 0755 0 0
slink /lib lib64 0777 0 0

dir /run 0755 0 0

dir /sbin 0755 0 0

dir /usr 0755 0 0
dir /usr/bin 0755 0 0
dir /usr/sbin 0755 0 0
dir /usr/lib64 0755 0 0
slink /usr/lib lib64 0777 0 0
"

list_confs=""
list_dirs="./${KIND}"
source ${PROG_LIST}
for g in ${!conf_*}; do
    k=${g#conf_}
    if [ "${k}" == "dirs" ] ; then
        echo ">>> collect dirs"
        for e in ${!g}; do
            list_dirs=${list_dirs}" ${e}"
        done
    elif [ "${k}" == "files" ] ; then
        for f in ${!g}; do
	    list_confs=${list_confs}"$(gen_file ${f})\n"
        done
    elif [ "${k}" == "executables" ] ; then
        echo ">>> collect executables"
        for e in ${!g}; do
            fe=$(which $e)
            if [ "${e}" == "busybox" ] ; then
                busybox_path=${fe}
            fi
	    list_confs=${list_confs}"$(gen_file ${fe})\n"
        done
    elif [ "${k}" == "link_to_busybox" ] ; then
        echo ">>> collect link to busybox"
        if [ -z "${busybox_path}" ] ; then
            die 1 "busybox not included in executables, please fix!"
        fi
        for s in ${!g}; do
            fe=$(which $s)
            if [ "${fe%/*}" == "${busybox_path%/*}" ] ; then
                fb=busybox
            else
                fb=${busybox_path}
            fi
            list_confs=${list_confs}"slink ${fe} ${fb} 0777 0 0\n"
        done
    fi
done
list_items=${list_items}"${list_confs}"

list_confs=""
for d in ${list_dirs}; do
    if [ -d "${d}" ] ; then
        for f in $(find ${d}); do
            if [[ "${d}" =~ "./" ]] ; then
                [[ "${f}" == "${d}" ]] && continue
                fn=${f#${d}/}
            else
                fn=${f}
            fi
            if [[ "${fn:0:1}" != "/" ]] ; then
                fn=/${fn}
            fi
            if [ -d ${f} ] ; then
                list_confs=${list_confs}"dir ${fn} 0755 0 0\n"
            else
                list_confs=${list_confs}"$(gen_file ${f} ${fn})\n"
            fi
        done
    fi
done
list_items=${list_items}"${list_confs}"

good_msg "Collect udev files ..."

udevd_bin="/sbin/udevd"
[ ! -e "${udevd_bin}" ] && udevd_bin="/usr/lib/systemd/systemd-udevd"
[ ! -e "${udevd_bin}" ] && udevd_bin="/lib/systemd/systemd-udevd"

list_udev=""
list_udev=${list_udev}"file /sbin/udevd ${udevd_bin} 0755 0 0\n"
list_udev=${list_udev}"dir /lib/udev 0755 0 0\n"
for u in ata_id scsi_id; do
    list_udev=${list_udev}"file /lib/udev/${u} /lib/udev/${u} 0755 0 0\n"
done
list_udev=${list_udev}"dir /lib/udev/rules.d/ 0755 0 0\n"
for u in 40-gentoo.rules \
         50-udev-default.rules \
         60-persistent-storage.rules \
         80-drivers.rules ; do
    list_udev=${list_udev}"file /lib/udev/rules.d/${u} /lib/udev/rules.d/${u} 0644 0 0\n"
done

list_items=${list_items}${list_udev}

AWK_EXEC='{
    if ($1 == "#") { next }
    if (NF == 6 && $1 == "file") {
        if (and($4, 0111)) {
            print $3
        }
    }
}'

AWK_LDD='{
    if (NF == 2 && $1 ~ /^\/lib/) {
        print $1
    } else if (NF == 4 && $1 ~ /^lib/ && $2 == "=>") {
        print $3
    }
}'

good_msg "Find executables from lists ..."
programs=$(echo -e "${list_items}" | awk "${AWK_EXEC}")

good_msg "Collect libraries from executables ..."
libraries=$(ldd ${programs} | awk "${AWK_LDD}" | sort | uniq)
list_libraries=""
for l in ${libraries} ; do
    list_libraries=${list_libraries}"file ${l} ${l} 0755 0 0\n"
done

list_items=${list_items}${list_libraries}

good_msg "Collect kernel modules ..."

file_modules=""
for g in ${!kernel_modules_*}; do
    for m in ${!g}; do
        fm="$(find ${km_directory} -name "${m}.ko")"
        if [ -z "${fm}" ] ; then
            bad_msg "module ${m} not found"
        else
            fm=${fm#${km_directory}}
            file_modules=${file_modules}"${fm}\n"
            for d in $(grep ${fm} ${km_directory}/modules.dep | cut -d\: -f2); do
                file_modules=${file_modules}"${d}\n"
            done
        fi
    done
done

dir_modules=""
for m in $(echo -e "${file_modules}" | sort | uniq); do
    d=${m#${km_directory}}
    dir_modules=${dir_modules}"$(iter_dirname ${d})\n"
done

list_modules_dir="dir /lib64/modules 0755 0 0
dir /lib64/modules/${KV} 0755 0 0
file /lib64/modules/${KV}/modules.builtin /lib/modules/${KV}/modules.builtin 0644 0 0
file /lib64/modules/${KV}/modules.order /lib/modules/${KV}/modules.order 0644 0 0\n"
for d in $(echo -e "${dir_modules}" | sort | uniq); do
    list_modules_dir=${list_modules_dir}"dir /lib64/modules/${KV}/${d} 0755 0 0\n"
done
list_items=${list_items}${list_modules_dir}

list_modules=""
for m in $(echo -e "${file_modules}" | sort | uniq); do
    list_modules=${list_modules}"file /lib64/modules/${KV}/${m} ${km_directory}${m} 0644 0 0\n"
done
list_items=${list_items}${list_modules}

good_msg "Build ${KIND}-${KV}.img"
echo -e "${list_items}" | \
    sort -k2 | \
    uniq | \
    tee ${KIND}-${KV}.list | \
    /usr/src/linux/usr/gen_init_cpio - | \
    xz -e --check=none -z -f -9 > ${KIND}-${KV}.img
