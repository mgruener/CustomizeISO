#!/bin/bash
TMPDIR="$(mktemp -d)"
DESTDIR="."
SYSTEMREPOS=''
ARCHLIST=''
OSRELEASE=$(python -c 'import platform; print(platform.linux_distribution()[1])')
MYNAME="$(basename ${0})"

function cleanup {
  if [ -d ${TMPDOR} ]; then
    rm -rf "${TMPDIR}"
  fi
  exit $1
}

function usage {
  echo "Usage: ${MYNAME} -k <kickstartfile> [-d <destdir>] [-v ksversion] [-r <osrelease>] [-a <archlist>] [-s]" >&2
  cleanup 1
}

if [ $# -eq 0 ]; then
  usage
fi

while getopts ":hsk:d:v:r:a:" opt; do
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
      SYSTEMREPOS=",/etc/yum.repos.d"
      ;;
    r)
      OSRELEASE=${OPTARG}
      ;;
    a)
      ARCHLIST="--archlist=${OPTARG}"
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

# create the basic layout for the temporary directory
# and create a yum configuration that exclusively
# uses the temp dir
mkdir -p "${TMPDIR}/yumcache"
mkdir -p "${TMPDIR}/yumlog"
mkdir -p "${TMPDIR}/yum.repos.d"
mkdir -p "${TMPDIR}/kickstart"

cat << EOF > "${TMPDIR}/yum.conf"
[main]
cachedir=${TMPDIR}/yumcache/\$basearch/\$releasever
logfile=${TMPDIR}/yumlog/yum.log
reposdir=${TMPDIR}/yum.repos.d${SYSTEMREPOS}
keepcache=0
debuglevel=2
exactarch=1
obsoletes=1
gpgcheck=0
plugins=1
installonly_limit=3
EOF

# validate the provided kickstart file and flatten it
# ksflatten combines all kickstart parts referenced with
# %include to one large kickstart file. It also combines
# all %package section to a single one
ksvalidator -i -e ${KSVERSION} ${KSFILE}
if [ $? -ne 0 ]; then
  cleanup 1
fi
FLATTENEDKS="${TMPDIR}/kickstart/flattened.ks"
STRIPPEDKS="${TMPDIR}/kickstart/stripped.ks"
PACKAGELIST="${TMPDIR}/kickstart/packages"
ksflatten -c ${KSFILE} -o "${FLATTENEDKS}"

# strip all unnecessary stuff from the provided kickstart file
# and extract all package / group names (we will use the package list
# as input for yumdownloader later)
sed -n -e '/^%packages/,/^%end/p' -e '/^repo /p' "${FLATTENEDKS}" > "${STRIPPEDKS}"
sed -n -e '/^%packages/,/^%end/p' ${STRIPPEDKS} | egrep -v '^%|^\s*$' > "${PACKAGELIST}"
sed -i -e 's/^-//' ${PACKAGELIST}
# if the option --nobase is not used, explicitely add the
# @base group the the packagelist
if [ -z "$(grep -o -- '--nobase' ${STRIPPEDKS})" ]; then
  echo "@base" >> "${PACKAGELIST}"
fi

# parse alle kickstart repo statements
# as repo uses the same parameter format as normal cli programs, use getopt
# to easily parse each repo line and create a yum repository file from each
# line
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

# download all necessary packages with yumdownloader (part of yum-utils)
# we use the temporary yum configuration, the repository configurations
# we just created and simulate an empty system with --installroot
# This prevents yum from trying to resolve dependencies using packages
# installed on the host system
# To resolve $releasever in repo configurations, yum needs to be able
# determine the os version, which is not possible due to the empty
# installroot so we have to provide it explicitely
yumdownloader --installroot "${TMPDIR}" \
              -c "${TMPDIR}/yum.conf" \
              --releasever ${OSRELEASE} \
              ${ARCHLIST} \
              --resolve \
              --destdir="${DESTDIR}" \
              $(cat "${PACKAGELIST}")

cleanup 0
