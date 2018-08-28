#!/bin/bash

export LANG=C
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

    >&2 echo -e "${BAD}>>${NORMAL} ${msg} ${NORMAL}"
}

die()
{
    local ret="${1:-0}"
    shift

    bad_msg "$@"
    exit $ret
}

iter_file()
{
    local f=$1
    local fm=
    local ft=
    local nm=

    while [ 1 ] ; do
        if [[ -z "$f" || $f = "/" || $f = "." ]] ; then
            break
        fi
        if [[ -h ${f} ]] ; then
            ft=$(readlink -e ${f})
            if [ "${f%/*}" == "${ft%/*}" ] ; then
                echo "slink ${f} ${ft##*/} 0777 0 0\n"
            else
                echo "slink ${f} ${ft} 0777 0 0\n"
            fi
            iter_file ${ft}
        elif [[ -d ${f} ]] ; then
            echo "dir ${f} 0755 0 0"
        elif [[ -b ${f} || -c ${f} ]] ; then
            [ -b "${f}" ] && ft="b" || ft="c"
            fm=$(stat -c "%04a" "${f}")
            nm=$(printf "%d %d" $(LANG=C stat -c "0x%t 0x%T" "${f}"))
            echo "nod ${f} ${fm} 0 0 ${ft} ${nm}"
        elif [[ -o ${f} ]] ; then
            echo "pipe ${f}"
        elif [[ -S ${f} ]] ; then
            echo "sock ${f}"
        elif [[ -f ${f} ]] ; then
            fm=$(stat -c "%04a" "${f}")
            echo "file ${f} ${f} ${fm} 0 0"
        else
            die 1 "unknown file type: ${f}"
        fi
        f=$(dirname ${f})
    done
}

iter_files()
{
    while [ $# -ne 0 ] ; do
        iter_file $1
        shift
    done | sort | uniq
}

find_km()
{
    if [ $# -ne 1 ] ; then
        die 1 "find_km called w/ $# args"
    fi

    local m=$1
    local fms=""

    local fm="$(find ${km_directory} -name "${m}.ko")"
    if [ -z "${fm}" ] ; then
        grep -E "/${m}.ko$" ${km_directory}/modules.builtin > /dev/null 2>&1
        if [ $? -eq 0 ] ; then
            return
        fi
        local fm=$(grep -E "^alias ${m} " ${km_directory}/modules.alias | awk '{print $3}')
        if [ -z "${fm}" ] ; then
            local fm=$(grep -E "^alias .* ${m}$" ${km_directory}/modules.alias | awk '{print $2}')
            if [ -z "${fm}" ] ; then
                bad_msg "module ${m} not found"
                return
            fi
        fi
        for d in $(echo -e ${fm} | sort | uniq); do
            if [[ ${d} =~ .*:.* ]] ; then
                continue
            fi
            if [ -v "km_aliases[${d}]" ] ; then
                continue
            fi
            km_aliases[${d}]=1
            local fms=${fms}"$(find_km ${d})"
        done
    else
        local fm=${fm#${km_directory}/}
        local fms=${fms}"${fm}\n"
        for d in $(grep "${fm}:" ${km_directory}/modules.dep | cut -d\: -f2); do
            if [ -v "km_modules[${d}]" ] ; then
                continue
            fi
            km_modules[${d}]=1
            local fms=${fms}"${d}\n"
        done
    fi

    if [ ! -z "${fms}" ] ; then
        echo "${fms}"
    fi
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

for f in /usr/src/linux.build/usr/gen_init_cpio /usr/src/linux/usr/gen_init_cpio ; do
    if [[ -x ${f} ]] ; then
        CPIO_CMD=${f}
    fi
done
if [[ -z ${CPIO_CMD} ]] ; then
    die 1 "gen_init_cpio not found"
fi

PROG_LIST=${KIND}.conf
if [ ! -s "${PROG_LIST}" ] ; then
    die 1 "${PROG_LIST} not found"
fi

KV=$1
[ -z "${KV}" ] && KV=$(uname -r)
km_directory="/lib64/modules/${KV}"
if [ ! -d "${km_directory}" ] ; then
    die 1 "modules directory for kernel ${KV} not found"
fi
good_msg "build initramfs image w/ kernel ${KV}"

declare -A km_aliases
declare -A km_modules

list_items="
dir /etc 0755 0 0
dir /run 0755 0 0
"

list_confs=""
list_dirs=""
list_devices=""
list_executables=""
list_files=""
list_sdirs="./${KIND}"
source ${PROG_LIST}
for g in ${!conf_*}; do
    k=${g#conf_}
    echo ">>> collect ${k}"
    if [[ ${k} == "dirs" ]] ; then
        list_sdirs=${list_sdirs}" ${!g}"
    elif [[ ${k} =~ "files" ]] ; then
        list_files=${list_files}" ${!g}"
    elif [[ ${k} =~ ^(slink|file)_[[:print:]]+$ ]] ; then
        kk=${BASH_REMATCH[1]}
        a=(${!g})
        if [[ ${#a[@]} == 2 ]] ; then
            fdst=${a[0]}
            fsrc=${a[1]}
            if [[ $kk == "file" ]] ; then
                fm=$(stat -c "%04a" "${fsrc}")
            else
                fm="0777"
            fi
            list_confs=${list_confs}"${kk} ${fdst} ${fsrc} ${fm} 0 0\n"
        else
            die 1 "${k}(${!g}) must contains two element only"
        fi
    elif [[ ${k} =~ "devices" ]] ; then
        for f in ${!g}; do
            if [[ "${f:0:1}" != "/" ]] ; then
                f="/dev/${f}"
            fi
            list_devices=${list_devices}" ${f}"
        done
    elif [[ ${k} =~ "executables" ]] ; then
        for e in ${!g}; do
            list_executables=${list_executables}" $(which $e)"
        done
    elif [ ${k} == "link_to_busybox" ] ; then
        busybox_path=$(which busybox)
        list_executables=${list_executables}" ${busybox_path}"
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
list_items=${list_items}"${list_confs}\n"

list_confs=""
for d in ${list_sdirs}; do
    if [ -d "${d}" ] ; then
        for f in $(find ${d}); do
            if [[ ${d:0:1} == "/" ]] ; then
                fn=${f}
            else
                [[ "${f}" == "${d}" ]] && continue
                fn=${f#${d}/}
            fi
            if [[ "${fn:0:1}" != "/" ]] ; then
                fn=/${fn}
            fi
            if [ -d ${f} ] ; then
                list_confs=${list_confs}"dir ${fn} 0755 0 0\n"
            else
                if [[ -h ${f} ]] ; then
                    list_confs=${list_confs}"slink ${f} $(readlink ${f}) 0777 0 0\n"
                else
                    fm=$(stat -c "%04a" "${f}")
                    list_confs=${list_confs}"file ${fn} ${f} ${fm} 0 0\n"
                fi
            fi
        done
    else
        die 1 "directory ${d} not found"
    fi
done
list_items=${list_items}"${list_confs}"

list_iters="$(iter_files $(echo "${list_files}" "${list_devices}" "${list_executables}" | sed 's/ /\n/g' | sort | uniq))"

good_msg "Collect udev files ..."

udevd_bin="/sbin/udevd"
[ ! -e "${udevd_bin}" ] && udevd_bin="/usr/lib/systemd/systemd-udevd"
[ ! -e "${udevd_bin}" ] && udevd_bin="/lib/systemd/systemd-udevd"

list_udev=${list_udev}"file /sbin/udevd ${udevd_bin} 0755 0 0\n"
list_udevs=""
for u in ata_id scsi_id; do
    list_udevs=${list_udevs}"/lib64/udev/${u}\n"
done
for u in 10-dm.rules \
         11-dm-lvm.rules \
         13-dm-disk.rules \
         40-gentoo.rules \
         50-udev-default.rules \
         60-cdrom_id.rules \
         60-persistent-storage.rules \
         63-md-raid-arrays.rules \
         64-md-raid-assembly.rules \
         69-dm-lvm-metad.rules \
         80-drivers.rules \
         95-dm-notify.rules ; do
    list_udevs=${list_udevs}"/lib64/udev/rules.d/${u}\n"
done
list_udevs="$(iter_files $(echo -e "${list_udevs}" | sort | uniq))"

list_items=${list_items}${list_iters}"\n"${list_udev}"\n"${list_udevs}"\n"

AWK_EXEC='{
    if ($1 == "#") {
        next
    } else if (NF == 6 && $1 == "file") {
        if (and($4, 0111)) {
            print $3
        }
    }
}'

AWK_LDD='{
    if (NF == 1 && $1 ~ /\:$/) {
        next
    } else if (NF == 2 && $1 ~ /^linux-vdso.so/) {
        next
    } else if (NF == 2 && $1 ~ /^\/lib/) {
        print $1
    } else if (NF == 4 && $1 ~ /^lib/ && $2 == "=>") {
        print $3
    } else {
        print "unhandled line format: \"", $0, "\"" > "/dev/stderr"
    }
}'

good_msg "Find executables from lists ..."
programs=$(echo -e "${list_items}" | awk "${AWK_EXEC}" | sort | uniq)

programs_d=""
programs_s=""
good_msg "Split executables into static linked & shared"
for f in ${programs}; do
    ldd ${f} > /dev/null 2>&1
    if [[ $? -eq 0 ]] ; then
        programs_d=${programs_d}" ${f}"
    else
        programs_s=${programs_s}" ${f}"
    fi
done

good_msg "Collect libraries from dynamic executables ..."
libraries=$(ldd ${programs_d} | awk "${AWK_LDD}" | sort | uniq)
list_libraries=""
for l in ${libraries} ; do
    list_libraries=${list_libraries}"${l}\n"
done

good_msg "Collect interpreter from static linked executables ..."
list_interpreters=""
for l in $(expr "$(readelf -l ${programs_s} 2> /dev/null | grep interpreter)" : ".*Requesting program interpreter: \([^] ]*\)" | sort | uniq) ; do
    list_interpreters=${list_preters}"${l}\n"
done

# just copy all libraries to (/usr)?/lib(32|64)?/
list_relocated=
for l in $(echo -e "${list_libraries}" "${list_interpreters}" | sort | uniq); do
    if [[ ${l} =~ ^((/usr)?/lib(32|64)?/)[[:print:]]+ ]] ; then
        lp=${BASH_REMATCH[1]}
        ln=$(basename ${l})
        lm=$(stat -L -c "%04a" "${l}")
        list_relocated=${list_relocated}"file ${lp}${ln} ${l} ${lm} 0 0\n"
    else
        die 1 "${l} is in unexpected path"
    fi
done

list_items=${list_items}"${list_relocated}\n"

good_msg "Collect kernel modules ..."

file_modules=""
for g in ${!kernel_modules_*}; do
    for m in ${!g}; do
        fms=$(find_km ${m})
        if [ ! -z ${fms} ] ; then
            file_modules=${file_modules}"${fms}\n"
        fi
    done
done
file_modules=$(echo -e "${file_modules}" | sort | uniq)

AWK_SOFTDEP='{
    if ($3 == "pre:" || $3 == "post:") {
        for (i = 4; i <= NF; i++) {
            print $i
        }
    } else {
        print "softdep: malformed line: \"", $0, "\"" > "/dev/stderr"
    }
}'

file_softdeps=""
for m in ${file_modules}; do
    m=${m%.ko}
    m=${m##*/}
    for d in $(grep -E "^softdep ${m} " ${km_directory}/modules.softdep | awk "${AWK_SOFTDEP}"); do
        file_softdeps=$(find_km ${d})
    done
done
file_softdeps=$(echo -e "${file_softdeps}" | sort | uniq)
#echo ${file_softdeps}

list_modules="${km_directory}/modules.alias\n
${km_directory}/modules.builtin\n
${km_directory}/modules.order\n
${km_directory}/modules.softdep\n"
for m in ${file_modules} ${file_softdeps}; do
    list_modules=${list_modules}"${km_directory}/${m}\n"
done
list_items=${list_items}"$(iter_files $(echo -e "${list_modules}" | sort | uniq))\n"

good_msg "Generate ${KIND}-${KV}.list"
echo -e "${list_items}" | \
    awk -f sort.awk | \
    sort -k 1h -k 3 | \
    uniq | \
    cut -d" " -f 2- > ${KIND}-${KV}.list

good_msg "Build ${KIND}-${KV}.img"
cat ${KIND}-${KV}.list | \
    ${CPIO_CMD} - | \
    xz -e --check=none -z -f -9 > ${KIND}-${KV}.img
