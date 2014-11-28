#!/bin/bash
TMPDIR="$(mktemp -d)"
DESTDIR="."
MYNAME="$(basename ${0})"

function cleanup {
  if [ -d ${TMPDOR} ]; then
    rm -rf "${TMPDIR}"
  fi
  exit $1
}

function usage {
  echo "Usage: ${MYNAME} -k <kickstartfile> [-d <destdir>] [-v ksversion]"
  cleanup 1
}

if [ $# -eq 0 ]; then
  usage
fi

while getopts ":hk:d:v:" opt; do
  case ${opt} in
    k)
      KSFILE=${OPTARG}
      ;;
    d)
      DESTDIR=${OPTARG}
      ;;
    v)
      KSVERSION="-v ${OPTARG}"
      ;;
    h)
      usage
      ;;
    \?)
      echo "Invalid option: -${OPTARG}" >&2
      usage
      ;;
    :)
      echo "Option -${OPTARG} requires an argument." >&2
      usage
      ;;
  esac
done
shift $((OPTIND-1))

if ! [ -f "${KSFILE}" ]; then
  echo "Can not find ${KSFILE}" >&2
  cleanup 1
fi

if ! [ -d "${DESTDIR}" ]; then
  echo "Can not find ${DESTDIR}"
  cleanup 1
fi

YDVERSION=$(yumdownloader --version 2>&1)
if [ $? -eq 0 ]; then
  echo "using ${YDVERSION}"
else
  echo "error: yumdownloader not found!"
  cleanup 1
fi

mkdir -p "${TMPDIR}/yumcache"
mkdir -p "${TMPDIR}/yumlog"
mkdir -p "${TMPDIR}/yum.repos.d"
mkdir -p "${TMPDIR}/kickstart"

cat << EOF > "${TMPDIR}/yum.conf"
[main]
cachedir=${TMPDIR}/yumcache/\$basearch/\$releasever
logfile=${TMPDIR}/yumlog/yum.log
reposdir=${TMPDIR}/yum.repos.d
keepcache=0
debuglevel=2
exactarch=1
obsoletes=1
gpgcheck=0
plugins=1
installonly_limit=3
EOF

ksvalidator -i -e ${KSVERSION} ${KSFILE}
if [ $? -ne 0 ]; then
  cleanup 1
fi
FLATTENEDKS="${TMPDIR}/kickstart/flattened.ks"
STRIPPEDKS="${TMPDIR}/kickstart/stripped.ks"
ksflatten -c ${KSFILE} -o "${FLATTENEDKS}"


sed -n -e '/^%packages/,/^%end/p' -e '/^repo /p' "${FLATTENEDKS}" > "${STRIPPEDKS}"
grep '^@' "${STRIPPEDKS}" > "${TMPDIR}/kickstart/groups"
grep '^repo ' "${STRIPPEDKS}" | while read -r repo
do
  echo "${repo}"
  TEMP=$(getopt -u -l name:,baseurl:,mirrorlist:,cost:,excludepkgs:,includepkgs:,proxy:,ignoregroups:,noverifyssl,install -- ${repo})
#  echo "${TEMP}"
  if [ $? -ne 0 ]; then
    echo "error while parsing repo: ${repo}"
    cleanup 1
  fi
  eval set -- "${TEMP}"
  while true ; do
    case "${1}" in
      --name)
        REPO_NAME=${2}
        shift 2
        ;;
      --baseurl)
        REPO_BASEURL=${2}
        shift 2
        ;;
      --mirrorlist)
        REPO_MIRRORLIST=${2}
        shift 2
        ;;
      --cost)
        REPO_COST=${2}
        shift 2
        ;;
      --excludepkgs)
        REPO_EXCLUDEPKGS=${2}
        shift 2
        ;;
      --includepkgs)
        REPO_INCLUDEPKGS=${2}
        shift 2
        ;;
      --proxy)
        REPO_PROXY=${2}
        shift 2
        ;;
      --ignoregroups)
        REPO_IGNOREGROUPS=${2}
        shift 2
        ;;
      --noverifyssl)
        REPO_NOVERIFYSSL=${2}
        shift
        ;;
      --install)
        REPO_INSTALL=${2}
        shift
        ;;
      --)
        shift
        break
        ;;
      *)
        echo "error while parsing repository"
        cleanup 1
        ;;
    esac
  done
done

cleanup 0
