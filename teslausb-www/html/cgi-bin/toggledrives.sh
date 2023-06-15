#!/bin/bash

if [ -e "/sys/kernel/config/usb_gadget/teslausb/" ]
then
    echo 'disconnect from client and mount on host'
  sudo /root/bin/disable_gadget.sh
  mount /mnt/lightshow
else
    echo 'unmount from host and mount on client'
  umount -d /mnt/lightshow
  sudo /root/bin/enable_gadget.sh
fi

cat << EOF
HTTP/1.0 200 OK
Content-type: application/json

EOF
