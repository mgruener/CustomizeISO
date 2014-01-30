#!/bin/bash
PUNGIBASE="/var/lib/pungi"
PUNGI="$(which --skip-alias --skip-functions pungi 2>/dev/null)"
MYNAME=$(basename ${0})

function usage {
  echo "Usage: ${MYNAME} -k <kickstartfile> [-d <destdir>]"
  exit 1
}

if [ $# -eq 0 ]; then
  usage
fi


while getopts ":hk:d:" opt; do
  case ${opt} in
    k)
      KSFILE=${OPTARG}
      ;;
    d)
      DESTDIR=${OPTARG}
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

if [ -z "${KSFILE}" ]; then
  echo "No kickstartfile provided" >&2
  usage
fi

if ! [ -f "${KSFILE}" ]; then
  echo "Can not find ${KSFILE}" >&2
  exit 1
fi

if [ -n ${DESTDIR} ]; then
  if ! [ -d "${DESTDIR}" ]; then
    echo "Can not find ${DESTDIR}"
    exit 1
  fi
else
  DESTDIR="."
fi

if [ -z "${PUNGI}" ]; then
  echo "Can not find pungi executable"
  exit 1
fi

# call pungi with the kickstart file
# call it in a subshell because it always creates
# some (empty) directories in its current workdir
set -o pipefail
(
set -o pipefail
cd "${PUNGIBASE}/cache"
${PUNGI} --nosource --nohash --nodebuginfo --nodownload --showurl \
         --destdir="${PUNGIBASE}/root" \
         --cachedir="${PUNGIBASE}/cache" \
         -c ${KSFILE} \
         -G | grep 'RPM:' | sed -e 's#^RPM:\s*##'
) | while read url; do
  file=$(basename $url)
  echo "${url}"
  curl -k -L -o "${DESTDIR}/${file}" ${url} || exit 1
done

if [ $? -ne 0 ]; then
  echo "error: failed to gather and download the necessary rpms, see last error for details"
  exit 1
fi

