#! /bin/sh
# kickstart.sh — vermaden's rudimentary kickstart templating engine, adapted to
# AlmaLinux. It sources kickstart.config, substitutes every TOKEN in
# kickstart.skel via `sed -e s@TOKEN@${TOKEN}@g`, writes files/${SYSTEM_NAME}.cfg,
# and wraps it in a tiny ISO whose volume label is OEMDRV — the label Anaconda
# auto-scans for a /ks.cfg. POSIX sh; runs unchanged on FreeBSD (cdrtools mkisofs)
# and on Linux (genisoimage/mkisofs).

if [ ! -f kickstart.config ]
then
  echo "ERROR: file 'kickstart.config' not available"
  exit 1
fi

if [ ! -f kickstart.skel ]
then
  echo "ERROR: file 'kickstart.skel' not available"
  exit 1
fi

. "$( pwd )/kickstart.config"

mkdir -p files ksfloppy iso

cp kickstart.config files/${SYSTEM_NAME}.config

if [ ${?} -eq 0 ]
then
  echo "INFO: kickstart config copied to 'files/${SYSTEM_NAME}.config' location"
else
  echo "ERROR: could not copy config to 'files/${SYSTEM_NAME}.config' location"
  exit 1
fi

sed                                       \
  -e s@SYSTEM_NAME@${SYSTEM_NAME}@g       \
  -e s@REPO_SERVER_IP@${REPO_SERVER_IP}@g \
  -e s@ALMA_MAJOR@${ALMA_MAJOR}@g         \
  -e s@ALMA_ARCH@${ALMA_ARCH}@g           \
  -e s@INTERFACE1@${INTERFACE1}@g         \
  -e s@IP_ADDRESS1@${IP_ADDRESS1}@g       \
  -e s@NETMASK1@${NETMASK1}@g             \
  -e s@INTERFACE2@${INTERFACE2}@g         \
  -e s@IP_ADDRESS2@${IP_ADDRESS2}@g       \
  -e s@NETMASK2@${NETMASK2}@g             \
  -e s@GATEWAY@${GATEWAY}@g               \
  -e s@NAMESERVER1@${NAMESERVER1}@g       \
  -e s@NAMESERVER2@${NAMESERVER2}@g       \
  -e s@NTP1@${NTP1}@g                     \
  -e s@NTP2@${NTP2}@g                     \
  kickstart.skel > files/${SYSTEM_NAME}.cfg

if [ ${?} -eq 0 ]
then
  echo "INFO: kickstart file 'files/${SYSTEM_NAME}.cfg' generated"
else
  echo "ERROR: failed to generate 'files/${SYSTEM_NAME}.cfg' kickstart file"
  exit 1
fi

echo "INFO: mkisofs(8) output BEGIN"
echo "-----------------------------"

mkisofs -J -R -l -graft-points -V "OEMDRV" \
        -input-charset utf-8 \
        -o iso/${SYSTEM_NAME}.oemdrv.iso \
        ks.cfg=files/${SYSTEM_NAME}.cfg ksfloppy

echo "-----------------------------"
echo "INFO: mkisofs(8) output ENDED"

if [ ${?} -eq 0 ]
then
  echo "INFO: ISO image 'iso/${SYSTEM_NAME}.oemdrv.iso' generated"
else
  echo "ERROR: failed to generate 'iso/${SYSTEM_NAME}.oemdrv.iso' ISO image"
  exit 1
fi
