#!/bin/bash
TMPDIR="$(mktemp -d)"
DESTDIR="."
DISABLEREPOS='--disablerepo="*"'
MYNAME="$(basename ${0})"

function cleanup {
  if [ -d ${TMPDOR} ]; then
    rm -rf "${TMPDIR}"
  fi
  exit $1
}

function usage {
  echo "Usage: ${MYNAME} -k <kickstartfile> [-d <destdir>] [-v ksversion] [-s]"
  cleanup 1
}

if [ $# -eq 0 ]; then
  usage
fi

while getopts ":hsk:d:v:" opt; do
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
    s)
      DISABLEREPOS=""
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
PACKAGELIST="${TMPDIR}/kickstart/packages"
ksflatten -c ${KSFILE} -o "${FLATTENEDKS}"

sed -n -e '/^%packages/,/^%end/p' -e '/^repo /p' "${FLATTENEDKS}" > "${STRIPPEDKS}"
sed -n -e '/^%packages/,/^%end/p' ${STRIPPEDKS} | egrep -v '^%|^\s*$' > "${PACKAGELIST}"
if [ -z "$(grep -o -- '--nobase' ${STRIPPEDKS})" ]; then
  echo "@base" >> "${PACKAGELIST}"
fi

grep '^repo ' "${STRIPPEDKS}" | while read -r repo
do
  TEMP=$(getopt -u -l name:,baseurl:,mirrorlist:,cost:,excludepkgs:,includepkgs:,proxy:,ignoregroups:,noverifyssl,install -- ${repo})
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
        REPO_BASEURL="baseurl=${2}"
        shift 2
        ;;
      --mirrorlist)
        REPO_MIRRORLIST="mirrorlist=${2}"
        shift 2
        ;;
      --cost)
        REPO_COST="cost=${2}"
        shift 2
        ;;
      --excludepkgs)
        REPO_EXCLUDEPKGS="exclude=${2}"
        shift 2
        ;;
      --includepkgs)
        REPO_INCLUDEPKGS="includepkgs=${2}"
        shift 2
        ;;
      --proxy)
        REPO_PROXY="proxy=${2}"
        shift 2
        ;;
      --ignoregroups)
        # unused
        shift 2
        ;;
      --noverifyssl)
        REPO_NOVERIFYSSL="sslverify=false"
        shift
        ;;
      --install)
        # unused
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
  cat << EOF > "${TMPDIR}/yum.repos.d/${REPO_NAME}.repo"
[${REPO_NAME}]
name=${REPO_NAME}
${REPO_BASEURL}
${REPO_MIRRORLIST}
${REPO_COST}
${REPO_EXCLUDEPKGS}
${REPO_INCLUDEPKGS}
${REPO_PROXY}
${REPO_NOVERIFYSSL}
EOF
done

yumdownloader --installroot "${TMPDIR}" -c "${TMPDIR}/yum.conf" ${DISABLEREPOS} --resolve --destdir="${DESTDIR}" $(cat "${PACKAGELIST}")

cleanup 0
