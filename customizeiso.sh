#!/bin/bash

SRCISO=""
KICKSTART=""
INCLUDEDIR=""
DSTISO="custom.iso"
ISOLINUX=""
GRUB=""
SRCISFILE=1
GATHERRPMS=0
MYNAME=$(basename "${0}")
KSDOWNLOADOPTIONS=''

CREATEREPO="$(which --skip-alias --skip-functions createrepo 2>/dev/null)"
MKISOFS="$(which --skip-alias --skip-functions mkisofs 2>/dev/null)"
IMPLANTISOMD5="$(which --skip-alias --skip-functions implantisomd5 2>/dev/null)"
KSDOWNLOAD="$(which --skip-alias --skip-functions kickstart-download.sh 2>/dev/null)"

function usage {
  echo "Usage: ${MYNAME} -s <sourceiso> -k <kickstartfile> [-g] [-d] [-v <ksversion>] [-r <osrelease>] [-a <archlist>] [-o <destiso>] [-i <includedir>] [-l <isolinuxcfg>] [-b <grubconf>] [-- <bootopts>]" >&2
  exit 1
}

if [ $# -eq 0 ]; then
  usage
fi

CLI="${MYNAME} ${@}"

while getopts ":hgds:o:k:i:l:v:r:a:b:" opt; do
  case ${opt} in
    s)
      SRCISO=${OPTARG}
      ;;
    o)
      DSTISO=${OPTARG}
      ;;
    k)
      KICKSTART=${OPTARG}
      ;;
    i)
      INCLUDEDIR=${OPTARG}
      ;;
    l)
      ISOLINUX=${OPTARG}
      ;;
    b)
      GRUB=${OPTARG}
      ;;
    g)
      GATHERRPMS=1
      ;;
    d)
      KSDOWNLOADOPTIONS="${KSDOWNLOADOPTIONS} -s"
      ;;
    v)
      KSDOWNLOADOPTIONS="${KSDOWNLOADOPTIONS} -v ${OPTARG}"
      ;;
    r)
      KSDOWNLOADOPTIONS="${KSDOWNLOADOPTIONS} -r ${OPTARG}"
      ;;
    a)
      KSDOWNLOADOPTIONS="${KSDOWNLOADOPTIONS} -a ${OPTARG}"
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
BOOTOPTS=$@

# Do some sanity checks
# Have all necessary options been provided?
# Do we have all necessary tools?
if [ -z "${SRCISO}" ]; then
  echo "No sourceiso provided" >&2
  usage
fi

if [ -z "${KICKSTART}" ]; then
  echo "No kickstartfile provided" >&2
  usage
fi

if ! [ -e "${SRCISO}" ]; then
  echo "Can not find ${SRCISO}" >&2
  exit 1
fi

if ! [ -f "${KICKSTART}" ]; then
  echo "Can not find ${KICKSTART}" >&2
  exit 1
fi

if [ -n "${ISOLINUX}" ]; then
  if ! [ -f "${ISOLINUX}" ]; then
    echo "Can not find ${ISOLINUX}"
    exit 1
  fi
fi

if [ -z "${CREATEREPO}" ]; then
  echo "Can not find createrepo executable"
  exit 1
fi

if [ -z "${MKISOFS}" ]; then
  echo "Can not find mkisofs executable"
  exit 1
fi

if [ -z "${IMPLANTISOMD5}" ]; then
  echo "Can not find implantisomd5 executable"
  exit 1
fi

if [ ${GATHERRPMS} -ne 0 ]; then
  if [ -z "${KSDOWNLOAD}" ]; then
    echo "Can not find kickstart-downloader.sh script"
    exit 1
  fi
fi

BUILDDIR=$(mktemp -d)
DSTDIR="${BUILDDIR}/dst"
SRCDIR="${BUILDDIR}/src"
RPMDIR="${BUILDDIR}/rpm"

# prepare build directory

# Yes, you can provide a directory as source media
# this way non-root execution is possible because we
# do not need to mount the media.
if [ -d "${SRCISO}" ]; then
  # A directory was given as source media
  # use it as source directory but remove a trailing
  # slash if present (a trailing slash alters how 
  # mkisofs treats the directory)
  SRCDIR="${SRCISO%/}"
  SRCISFILE=0
else
  if [ $(id -u) -ne 0 ]; then
    echo "${MYNAME} must be run as root when using an iso file as source" >&2
    exit 1
  fi
fi

if ! [ -d "${BUILDDIR}" ]; then
  echo "Failed to create build directory ${BUILDDIR}" >&2
  exit 1
fi

mkdir "${DSTDIR}"

# If an iso file has been provided as source media,
# mount it.
if [ ${SRCISFILE} -eq 1 ]; then
  mkdir "${SRCDIR}"
  mount "${SRCISO}" "${SRCDIR}" -o loop
  if [ $? -ne 0 ]; then
    echo "Failed to mount ${SRCISO} to ${SRCDIR}"
    rm -rf "${BUILDDIR}"
    exit 1
  fi
fi

# Every CentOS / RHEL installation media contains a .discinfo file
# if it is missing we can not create a valid media, even if we wanted to.
if ! [ -f "${SRCDIR}/.discinfo" ]; then
  echo "${SRCISO}/.discinfo is missing, this is not a valid installation media" >&2
  if [ ${SRCISFILE} -eq 1 ]; then
    umount "${SRCDIR}"
  fi
  rm -rf "${BUILDDIR}"
  exit 1
fi

# copy the bootloader directory from the source media because we want to
# modify the bootloader configration
cp -av "${SRCDIR}/isolinux" "${SRCDIR}/EFI" "${DSTDIR}/."
if [ $? -ne 0 ];then
  echo "Failed to copy source iso contents from ${SRCDIR} to ${DSTDIR}" >&2
  if [ ${SRCISFILE} -eq 1 ]; then
    umount "${SRCDIR}"
  fi
  rm -rf "${BUILDDIR}"
  exit 1
fi

chmod -R +w "${DSTDIR}"

# Copy the kickstart file and this script
# to the build directory of the new ISO.
# The ksinclude.inc snippet can be %included
# in any kickstart file to provide easy access
# to any files copied to the new iso.
cp -v "${KICKSTART}" "${DSTDIR}/ks.cfg"
cp -v "${0}" "${DSTDIR}/"
if [ -n "${KSDOWNLOAD}" ]; then
  cp -v "${KSDOWNLOAD}" "${DSTDIR}/"
fi
cat << EOF > "${DSTDIR}/ksinclude.inc"
%post --nochroot --interpreter /bin/bash --log /mnt/sysimage/root/install.log.post.ksinclude --erroronfail
set -x
if [ -e /mnt/source/ksinclude ]; then
  cp -av /mnt/source/ksinclude /mnt/sysimage/root/
  rm -f /mnt/sysimage/root/ksinclude/TRANS.TBL
fi

mkdir -p /mnt/sysimage/root/bin
cp -av /mnt/source/${MYNAME} /mnt/sysimage/root/bin/
if [ -n "${KSDOWNLOAD}" ]; then
  cp -av /mnt/source/${KSDOWNLOAD} /mnt/sysimage/root/bin/
fi
cat << MYEOF > /mnt/sysimage/root/bin/recreate-iso.sh
#!/bin/bash
${CLI}
MYEOF
chmod +x /mnt/sysimage/root/bin/recreate-iso.sh
%end
EOF

# use kickstart-downloader.sh to download all necessary rpms
# using the repositories specified in the kickstart file
# to create a self contained installation medium (so no
# network access is necessary during the installation)
if [ ${GATHERRPMS} -ne 0 ]; then
  mkdir "${RPMDIR}"
  ( 
    cd ${DSTDIR}
    ${KSDOWNLOAD} -k "${DSTDIR}/ks.cfg" -d "${RPMDIR}" ${KSDOWNLOADOPTIONS}
  )
  # delete all repo statements in the kickstart file
  # because we downloaded all necessary rpms, there
  # is no need to keep them
  sed -i -e '/^repo /d' "${DSTDIR}/ks.cfg"
fi

# anaconda treats all relative includes to be relative to the cwd
# and not to the media mountpoint
# convert all relative %include statements to absolute ones
# by prefixing the media mountpoint (/mnt/stage2)
sed -i -e '/%include [^/]/s!^%include \(.*\)$!%include /mnt/stage2/\1!g' "${DSTDIR}/ks.cfg"

# Recreate repository information.
# It is safe to assume that ther is only one file
# matching *-*.xml because you can specify -g only once
# when calling createrepo.
cp ${SRCDIR}/repodata/*-*.xml "${BUILDDIR}/comps.xml"
# Because createrepo can only work on one directory
# we have to link the "Packages" directory from
# the source media to our destination directory.
ln -s "${SRCDIR}/Packages" "${DSTDIR}/Packages"
ln -s "${INCLUDEDIR}" "${DSTDIR}/ksinclude"
ln -s "${RPMDIR}" "${DSTDIR}/customrpms"
${CREATEREPO} -u "media://$(head -n1 ${SRCDIR}/.discinfo)" -g "${BUILDDIR}/comps.xml" "${DSTDIR}/."
if [ $? -ne 0 ];then
  echo "Failed to create repository data" >&2
  if [ ${SRCISFILE} -eq 1 ]; then
    umount "${SRCDIR}"
  fi
  rm -rf "${BUILDDIR}"
  exit 1
fi
rm -f "${DSTDIR}/Packages"
rm -f "${DSTDIR}/ksinclude"
rm -f "${DSTDIR}/customrpms"

# Clean up in case we are working on an already
# customized source media.
# The BEGIN and END comments are added during isolinux.cfg / grub.conf
# customization, see below
sed -i -e '/^# BEGIN CUSTOM$/,/^# END CUSTOM$/d' "${DSTDIR}/isolinux/isolinux.cfg"
if [ -z "${ISOLINUX}" ]; then
# Create a new default boot menu entry in case no
# specific isolinux.cfg snippet has been provided.
cat << EOF >> "${DSTDIR}/isolinux/isolinux.cfg"
# BEGIN CUSTOM
label linux-custom
  menu label ^Custom kickstart installation
  menu default
  kernel vmlinuz
  append initrd=initrd.img ks=cdrom:ks.cfg ${BOOTOPTS}
# END CUSTOM
EOF
else
  # A specific isolinux.cfg snippet has been provided.
  # If bootoptions where provided on the commandline
  # add them to each append line of the snippet.
  cp "${ISOLINUX}" "${BUILDDIR}/isolinux.cfg"
  if [ -n "${BOOTOPTS}" ]; then
    sed -i -e "s/^\(\s*append.*\)/\1 ${BOOTOPTS}/g" "${BUILDDIR}/isolinux.cfg"
  fi
  # Add the isolinux.cfg snippet to the media isolinux.cfg
  # and enclose it in BEGIN and END comments so we can remove
  # these additions when re-customizing this iso
  echo "# BEGIN CUSTOM" >> "${DSTDIR}/isolinux/isolinux.cfg"
  cat "${BUILDDIR}/isolinux.cfg" >> "${DSTDIR}/isolinux/isolinux.cfg"
  echo "# END CUSTOM" >> "${DSTDIR}/isolinux/isolinux.cfg"
fi

if [ -e "${DSTDIR}/EFI/BOOT/BOOTX64.conf" ]; then
  sed -i -e '/^# BEGIN CUSTOM$/,/^# END CUSTOM$/d' "${DSTDIR}/EFI/BOOT/BOOTX64.conf"
  if [ -z "${GRUB}" ]; then
  cat << EOF >> "${DSTDIR}/EFI/BOOT/BOOTX64.conf"
# BEGIN CUSTOM
title Custom kickstart installation
        kernel /images/pxeboot/vmlinuz ks=cd:ks.cfg ${BOOTOPTS}
        initrd /images/pxeboot/initrd.img
# END CUSTOM
EOF
  else
    # A specific grub.conf snippet has been provided.
    # If bootoptions where provided on the commandline
    # add them to each append line of the snippet.
    cp "${ISOLINUX}" "${BUILDDIR}/BOOTX64.conf"
    if [ -n "${BOOTOPTS}" ]; then
      sed -i -e "s/^\(\s*kernel .*\)/\1 ${BOOTOPTS}/g" "${BUILDDIR}/BOOTX64.conf"
    fi
    # Add the grub.conf snippet to the media grub.conf
    # and enclose it in BEGIN and END comments so we can remove
    # these additions when re-customizing this iso
    echo "# BEGIN CUSTOM" >> "${DSTDIR}/EFI/BOOT/BOOTX64.conf"
    cat "${BUILDDIR}/BOOTX64.conf" >> "${DSTDIR}/EFI/BOOT/BOOTX64.conf"
    echo "# END CUSTOM" >> "${DSTDIR}/EFI/BOOT/BOOTX64.conf"
  fi
fi

# If the destination iso already exists remove it.
# This is a cruel world, deal with it...
if [ -f "${DSTISO}" ]; then
  rm -f "${DSTISO}"
fi

# Remove the boot catalog because it will be recreated
# and it can lead to problems when it already exists when
# creating the new iso
rm -f "${DSTDIR}/isolinux/boot.cat"
# Create the new iso image
# - mkisofs options according to
#   https://access.redhat.com/site/documentation/en-US/Red_Hat_Satellite/5.6/html/Getting_Started_Guide/appe-Red_Hat_Network_Satellite-User_Guide-Boot_Devices.html
# - Because the contents of SRCDIR and DSTDIR must not intersect, use -m
#   to filter out all content from SRCDIR that will be present in DSTDIR.
# - filter out all vcs data
# - Map the INCLUDEDIR to the /ksinclude directory on the new iso.
# - merge the remaining contents of SRCDIR and DSTDIR
ISOCONTENT="${SRCDIR} ${DSTDIR}"
if [ -n "${INCLUDEDIR}" ]; then
  ISOCONTENT="${ISOCONTENT} ksinclude=${INCLUDEDIR}"
fi
if [ ${GATHERRPMS} -ne 0 ]; then
  ISOCONTENT="${ISOCONTENT} customrpms=${RPMDIR}"
fi
${MKISOFS} -o "${DSTISO}" \
           -b isolinux/isolinux.bin \
           -c isolinux/boot.cat \
           -no-emul-boot \
           -boot-load-size 4 \
           -boot-info-table \
           -graft-points \
           -J -l -r -T -v -V "Custom Kickstart ISO" \
           -m "${SRCDIR}/isolinux" \
           -m "${SRCDIR}/EFI" \
           -m "${SRCDIR}/repodata" \
           -m "${SRCDIR}/ksinclude" \
           -m "${SRCDIR}/customrpms" \
           -m "${SRCDIR}/ksinclude.inc" \
           -m "${SRCDIR}/${MYNAME}" \
           -m "${SRCDIR}/${KSDOWNLOAD:-kickstart-download.sh}" \
           -m "${SRCDIR}/ks.cfg" \
           -m ".svn" \
           -m ".git" \
           ${ISOCONTENT}

if [ $? -ne 0 ]; then
  echo "Failed to create ${DSTISO}" >&2
  if [ ${SRCISFILE} -eq 1 ]; then
    umount "${SRCDIR}"
  fi
  rm -rf "${BUILDDIR}"
  exit 1
fi

# add a checksum to the media so it can easily be checked
# later on
${IMPLANTISOMD5} "${DSTISO}"

if [ ${SRCISFILE} -eq 1 ]; then
  umount "${SRCDIR}"
fi
rm -rf "${BUILDDIR}"

exit 0
