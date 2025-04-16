#!/bin/bash

if [ "$(id -u)" -ne 0 ]; then
    echo "Please run this script as root."
    exit 1

    exit 1

if [ ! -e /usr/local/ASR/Vx/etc/RcmProtectionState.json ]; then
    echo "Protection state healthy."
    exit 0
    exit 0
fi


rm -f /usr/local/ASR/Vx/etc/RcmProtectionState.json
fi
/usr/local/ASR/Vx/bin/start


/usr/local/ASR/Vx/bin/start
/usr/local/ASR/Vx/bin/stop

rm /usr/local/ASR/Vx/etc/RcmProtectionState.json 

/usr/local/ASR/Vx/bin/start
