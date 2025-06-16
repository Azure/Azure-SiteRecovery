#! /bin/bash

INSTALL_LOGFILE="/var/log/ua_install.log"

#
# Function Name: trace_log_message()
#
#  Description  Prints date and time followed by all arguments to
#               stdout and to INSTALL_LOGFILE.  If -q is used, only send
#               message to log file, not to stdout.  If no arguments
#               are given, a blank line is returned to stdout and to
#               INSTALL_LOGFILE.
#
#  Usage        trace_log_message [-q] "Message"
#
#  Notes        If -q is used, it must be the first argument.
#
trace_log_message()
{
    QUIET_MODE=FALSE

    if [ $# -gt 0 ]
    then
        if [ "X$1" = "X-q" ]
        then
            QUIET_MODE=TRUE
            shift
        fi
    fi

    if [ $# -gt 0 ]
    then
        DATE_TIME=`date '+%m/%d/%Y %H:%M:%S'`

        if [ "${QUIET_MODE}" = "TRUE" ]
        then
            echo "${DATE_TIME}: $*" >> ${INSTALL_LOGFILE}
        else
            echo -e "$@"
            echo "${DATE_TIME} : $@ " >> ${INSTALL_LOGFILE} 2>&1
        fi
    else
        if [ "${QUIET_MODE}" = "TRUE" ]
        then
            echo "" >> ${INSTALL_LOGFILE}
        else
            echo "" | tee -a ${INSTALL_LOGFILE}
        fi
    fi
}

# Get the drivers install dir root path
test_root_dir=$1
if [ -z "$test_root_dir" ]; then
    trace_log_message "Please provide the directory path under which the Drivers directory is present on your machine."
    exit 1
fi

VX_VERSION_FILE="/usr/local/.vx_version"
INSTALL_DIR=$(grep ^INSTALLATION_DIR $VX_VERSION_FILE | cut -d"=" -f2 | tr -d " ")
if [ -z "$INSTALL_DIR" ]; then
    GREENFIELD=1
    trace_log_message "Please provide the ASR install directory path (example: /usr/local/ASR/Vx)"
    exit 1
fi

trace_log_message "ASR install directory path: $INSTALL_DIR"

# Get the platform type
DRSCOUT_PLATFORM=$(grep ^VmPlatform ${INSTALL_DIR}/etc/drscout.conf | cut -d"=" -f2 | tr -d " ")
DrScout_Platform=$(tr [A-Z] [a-z] <<<$DRSCOUT_PLATFORM)
VM_PLATFORM=`echo $DrScout_Platform | tr -d " "`
if [ -z "$VM_PLATFORM" ]; then
    trace_log_message "Please provide the VM platform - VmWare or Azure"
    exit 1
fi

trace_log_message "VM platform: $VM_PLATFORM"

# Get the original ASR install dir path


IMDS_URL="http://169.254.169.254/metadata/instance/compute/securityProfile?api-version=2023-11-15"

declare -A DRIVERS
DRIVERS=(
    ["UBUNTU18"]="https://aka.ms/DriversPackage_UBUNTU18"
    ["UBUNTU20"]="https://aka.ms/DriversPackage_UBUNTU20"
    ["UBUNTU22"]="https://aka.ms/DriversPackage_UBUNTU22"
    ["UBUNTU24"]="https://aka.ms/DriversPackage_UBUNTU24"
    ["DEBIAN11"]="https://aka.ms/DriversPackage_DEBIAN11"
    ["DEBIAN12"]="https://aka.ms/DriversPackage_DEBIAN12"
    ["SLES15"]="https://aka.ms/DriversPackage_SLES15"
    ["RHEL8"]="https://aka.ms/DriversPackage_RHEL8"
    ["RHEL9"]="https://aka.ms/DriversPackage_RHEL9"
)

module_load_log_file=$INSTALL_LOGFILE

if [ -z "$GREENFIELD" ]; then
    # brownfield case
    os_details_file_path="$INSTALL_DIR/scripts/vCon/OS_details.sh"
else
    # greenfield case - new installation
    os_details_file_path="$test_root_dir/OS_details.sh"
    if [ ! -f "$os_details_file_path" ]; then
        trace_log_message "OS_details.sh file not found in the given directory path."
        exit 1
    fi
fi

OS=`$os_details_file_path 1`

drivers_file_dir="$test_root_dir/Drivers"
ker_ver=`uname -r`
driver_dir="kernel/drivers/char"
k_dir="/lib/modules/$ker_ver/$driver_dir"
RHEL5_KVL="2.6.18"
RHEL6_KVL="2.6.32"
RHEL7_KVL="3.10.0"
RHEL8_KVL="4.18.0"
RHEL9_KVL="5.14.0"

is_TrustedLaunch()
{
    secType=`curl -s -H Metadata:true --noproxy "*" $IMDS_URL`
    if echo "$secType" | grep -q "TrustedLaunch"; then
        trace_log_message -q "VM is TrustedLaunch enabled."
        echo "true"
    else
        trace_log_message -q "VM is not TrustedLaunch enabled."
        echo "false"
    fi
}

# FUNCTION to get the driver directory
get_driver_directory_for_sles()
{
    local DEPLOY_DIR=$drivers_file_dir

    # set default value to unsigned driver directory
    driver="${DEPLOY_DIR}/UnSigned"

    if [ "$OS" = "SLES12-64" ]; then
        # we dont ship signed driver for SLES12-64
        trace_log_message -q "Loading unsigned driver from drivers dir for SLES12-64 in all cases"
        driver="${DEPLOY_DIR}/UnSigned"
    elif [ "$OS" = "SLES15-64" ]; then
        if [ "$VM_PLATFORM" = "VmWare" ]; then
            trace_log_message -q "Loading from drivers_unsigned for SLES15-64 on VmWare"
            driver="${DEPLOY_DIR}/UnSigned"
        elif [ "$VM_PLATFORM" = "Azure" ]; then
            IS_TVM=$(is_TrustedLaunch)
            if [ "$IS_TVM" = "true" ]; then
                # For TVM VMs, we always load signed driver
                trace_log_message -q "Loading signed driver from drivers dir for SLES15-64 on Azure TVM"
                driver="${DEPLOY_DIR}/Signed"
            else
                trace_log_message -q "Loading from drivers_unsigned dir for SLES15-64 on Azure non-TVM"
                driver="${DEPLOY_DIR}/UnSigned"
            fi
        fi
    fi
    echo "${driver}" # return the driver directory
}

copy_rhel9_drivers()
{

    trace_log_message -q "Kernel dir = $k_dir"

    RHEL9_KMV_V0="70"
    RHEL9_KMV_V0_1="13"
    RHEL9_KMV_V0_2="36"
    RHEL9_KMV_V1="162"
    RHEL9_KMV_V1_1="6"
    RHEL9_KMV_V1_2="22"
    RHEL9_KMV_V2="284"
    RHEL9_KMV_V3="362"
    RHEL9_KMV_V3_1="8"
    RHEL9_KMV_V3_2="18"
    RHEL9_KMV_V4="427"
    RHEL9_KMV_V5="503"
    RHEL9_KMV_V6="570"

    KERNEL_MINOR_VERSION=`echo "$k_dir" | cut -d"-" -f2 | cut -d"." -f1`
    KERNEL_COPY_VERSION=""
    local KERNEL_MINOR_VERSION_UPDATE=`echo "$k_dir" | cut -d"-" -f2 | cut -d"." -f2`
    ret=1
    case $KERNEL_MINOR_VERSION in
        $RHEL9_KMV_V0)
            if [ $KERNEL_MINOR_VERSION_UPDATE -lt $RHEL9_KMV_V0_2 ]; then
                KERNEL_UPDATE_VERSION=$RHEL9_KMV_V0_1
            else
                KERNEL_UPDATE_VERSION=$RHEL9_KMV_V0_2
            fi
            KERNEL_COPY_VERSION="$RHEL9_KMV_V0.$KERNEL_UPDATE_VERSION"
        ;;
        $RHEL9_KMV_V1)
            if [ $KERNEL_MINOR_VERSION_UPDATE -lt $RHEL9_KMV_V1_2 ]; then
                KERNEL_UPDATE_VERSION=$RHEL9_KMV_V1_1
            else
                KERNEL_UPDATE_VERSION=$RHEL9_KMV_V1_2
            fi
            KERNEL_COPY_VERSION="$RHEL9_KMV_V1.$KERNEL_UPDATE_VERSION"
        ;;
        $RHEL9_KMV_V2)
            KERNEL_COPY_VERSION=$RHEL9_KMV_V2
        ;;
        $RHEL9_KMV_V3)
            if [ $KERNEL_MINOR_VERSION_UPDATE -lt $RHEL9_KMV_V3_2 ]; then
                KERNEL_UPDATE_VERSION=$RHEL9_KMV_V3_1
            else
                local KERNEL_VERSION_NUM=`echo "$k_dir" | cut -d"-" -f2 | cut -d"." -f3`
                KERNEL_UPDATE_VERSION=$RHEL9_KMV_V3_2.$KERNEL_VERSION_NUM
            fi
            KERNEL_COPY_VERSION="$RHEL9_KMV_V3.$KERNEL_UPDATE_VERSION"
        ;;
        $RHEL9_KMV_V4)
            KERNEL_COPY_VERSION=$RHEL9_KMV_V4
        ;;
        $RHEL9_KMV_V5)
            KERNEL_COPY_VERSION=$RHEL9_KMV_V5
        ;;
		*)
            KERNEL_COPY_VERSION=$RHEL9_KMV_V6
        ;;
    esac

    if [ -z $KERNEL_COPY_VERSION ]; then
        trace_log_message -q "Not copying involflt driver to kernel $k_dir"
    else
        trace_log_message -q "Copying $drivers_file_dir/involflt.ko.${RHEL9_KVL}-${KERNEL_COPY_VERSION} ${k_dir}"
        cp -f $drivers_file_dir/involflt.ko.${RHEL9_KVL}-${KERNEL_COPY_VERSION}* ${k_dir}/involflt.ko
        ret=$?
    fi

    return $ret
}

is_supported_rhel8_kernel()
{
    CURR_KERNEL=$1
    EXTRA_VER1=$2
    EXTRA_VER2=$3

    ret=1
    extra_minor1=`echo ${CURR_KERNEL} | awk -F"." '{print $4}'`
    extra_minor2=`echo ${CURR_KERNEL} | awk -F"." '{print $5}'`
    if [ ! -z $extra_minor1 -a $extra_minor1 -eq $extra_minor1 ] 2> /dev/null; then
        if [ $extra_minor1 -gt $EXTRA_VER1 ]; then
            ret=0
        elif [ $extra_minor1 -eq $EXTRA_VER1 ]; then
            if [ ! -z $extra_minor2 -a $extra_minor2 -eq $extra_minor2 ] 2> /dev/null; then
                if [ $extra_minor2 -ge $EXTRA_VER2 ]; then
                    ret=0
                fi
            fi
        fi
    fi

    return $ret
}

copy_rhel8_drivers()
{
    RHEL8_KMV_V0="80"
    RHEL8_KMV_V1="147"
    RHEL8_KMV_V2="193"
    RHEL8_KMV_V3="240"
    RHEL8_KMV_V4="305"
	RHEL8_KMV_V4_2="305.148.1"
    RHEL8_KMV_V5="348"
    RHEL8_KMV_V6="372"
    RHEL8_KMV_V7="425"
    RHEL8_KMV_V7_1="425.3.1"
    RHEL8_KMV_V7_2="425.10.1"

    VER_DIR=$(dirname $(dirname $(dirname $k_dir)))
    K_VER=${VER_DIR##*/}

    KERNEL_MINOR_VERSION=`echo "$k_dir" | cut -d"-" -f2 | cut -d"." -f1`
    KERNEL_COPY_VERSION=""
    ret=1
    case $KERNEL_MINOR_VERSION in
        $RHEL8_KMV_V0)
            KERNEL_COPY_VERSION=$RHEL8_KMV_V0
        ;;
        $RHEL8_KMV_V1|$RHEL8_KMV_V2|$RHEL8_KMV_V3)
            KERNEL_COPY_VERSION=$RHEL8_KMV_V1
        ;;
        $RHEL8_KMV_V4)
            is_supported_rhel8_kernel $K_VER 30 1
            if [ $? -eq "0" ]; then
                is_supported_rhel8_kernel $K_VER 148 1
				if [ $? -eq 0 ]; then
					KERNEL_COPY_VERSION=$RHEL8_KMV_V4_2
				else
					KERNEL_COPY_VERSION="${RHEL8_KMV_V4}.el8"
				fi
            fi
        ;;
        $RHEL8_KMV_V5)
            is_supported_rhel8_kernel $K_VER 5 1
            if [ $? -eq "0" ]; then
                KERNEL_COPY_VERSION=$RHEL8_KMV_V5
            fi
        ;;
        $RHEL8_KMV_V6)
            KERNEL_COPY_VERSION=$RHEL8_KMV_V5
        ;;
        $RHEL8_KMV_V7)
            local KERNEL_MINOR_VERSION_UPDATE=`echo "$k_dir" | cut -d"-" -f2 | cut -d"." -f1,2,3`
            if [ $KERNEL_MINOR_VERSION_UPDATE = $RHEL8_KMV_V7_1 ]; then
                KERNEL_COPY_VERSION=$RHEL8_KMV_V7_1
            else
                KERNEL_COPY_VERSION=$RHEL8_KMV_V7_2
            fi
        ;;
        *)
            KERNEL_COPY_VERSION=$RHEL8_KMV_V7_2
        ;;
    esac
    if [ -z $KERNEL_COPY_VERSION ]; then
        trace_log_message -q "Not copying involflt driver to kernel $k_dir"
    else
        trace_log_message -q "Copying $drivers_file_dir/involflt.ko.${RHEL9_KVL}-${KERNEL_COPY_VERSION} ${k_dir}"
        cp -f $drivers_file_dir/involflt.ko.${RHEL8_KVL}-${KERNEL_COPY_VERSION}* ${k_dir}/involflt.ko
        ret=$?
    fi

    return $ret
}

copy_rhel7_drivers()
{
    RHEL7_KMV_BASE="123"
    RHEL7_KMV_U3="514"
    RHEL7_KMV_U4="693"

    KERNEL_MINOR_VERSION=`echo ${k_dir} | cut -d"-" -f2 | cut -d"." -f1`
    if [ $KERNEL_MINOR_VERSION -lt "$RHEL7_KMV_U4" ]; then
        if [ $KERNEL_MINOR_VERSION -lt "$RHEL7_KMV_U3" ]; then
            cp -f $drivers_file_dir/involflt.ko.${RHEL7_KVL}-${RHEL7_KMV_BASE}* ${k_dir}/involflt.ko
        else
            cp -f $drivers_file_dir/involflt.ko.${RHEL7_KVL}-${RHEL7_KMV_U3}* ${k_dir}/involflt.ko
        fi
    else
        cp -f $drivers_file_dir/involflt.ko.${RHEL7_KVL}-${RHEL7_KMV_U4}* ${k_dir}/involflt.ko
    fi

    return $?
}

copy_rhel_drivers()
{
    if [ -f ${k_dir}/involflt.ko ]; then
        trace_log_message -q "involflt.ko already exists in ${k_dir}"
        return 0
    fi

    if [ "$OS" = "RHEL7-64" -o "$OS" = "OL7-64" ]; then
        copy_rhel7_drivers
    elif [ "$OS" = "RHEL8-64" -o "$OS" = "OL8-64" ]; then
        copy_rhel8_drivers
    elif [ "$OS" = "RHEL9-64" -o "$OS" = "OL9-64" ]; then
        copy_rhel9_drivers
    else
        cp -f ${DEPLOY_DIR}/bin/involflt.ko.${RHEL6_KVL}*${SEP}${suffix} ${k_dir}/involflt.ko
    fi
    local ret=$?

    if [ "${ret}" = "0" ]; then
        trace_log_message "Installed involflt.ko successfully under ${k_dir}"
    else
        trace_log_message "Could not install involflt.ko under ${k_dir}, return val : ${ret}"
    fi
    return $ret
}

copy_uek_driver()
{
    # UEK kernels
    local kernel="`echo $k_dir | cut -f 4 -d "/" | cut -f 1 -d "-"`"
    if [ "$kernel" = "4.14.35" ]; then
        echo $k_dir | grep -q "\-18" && kernel="${kernel}-1818" || kernel="${kernel}-1902"
    fi
    trace_log_message -q "Copying involflt.ko.${kernel}*uek.x86_64"
    cp -f $drivers_file_dir/involflt.ko.${kernel}*uek.x86_64 ${k_dir}/involflt.ko
    local ret=$?
    if [ "${ret}" = "0" ]; then
        trace_log_message "Installed involflt.ko successfully under ${k_dir}"
    else
        trace_log_message "Could not install involflt.ko under ${k_dir}"
    fi
}

copy_driver_file()
{
    trace_log_message -q "OS is $OS"
    if echo $OS | grep -q 'RHEL\|SLES11' ; then
        copy_rhel_drivers || return $?
    elif [ "${OS}" = "OL7-64" -o "${OS}" = "OL8-64" -o "${OS}" = "OL9-64" ]; then
        if [[ $ker_ver =~ "uek" ]]; then
            #Copy driver for uek kernel
            copy_uek_driver || return $?
        else
            copy_rhel_drivers || return $?
        fi
    else
        local driver_dir_path=$drivers_file_dir
        if [ "${OS}" = "SLES12-64" -o "${OS}" = "SLES15-64" ]; then
            driver_dir_path=$(get_driver_directory_for_sles)
        fi

        if [ -f $driver_dir_path/involflt.ko.${ker_ver} ]; then
            trace_log_message -q "Copying $driver_dir_path/involflt.ko.${ker_ver} to ${k_dir}"
            cp -f $driver_dir_path/involflt.ko.${ker_ver} ${k_dir}/involflt.ko
            return 0
        else
            trace_log_message -q "Unable to find file $driver_dir_path/involflt.ko.${ker_ver}"
            return 1
        fi
    fi
}

stop_agent_service()
{
    if [ -z "$GREENFIELD" ]; then
        $INSTALL_DIR/bin/stop >> ${INSTALL_LOGFILE} 2>&1
    fi
}

start_agent_service()
{
    if [ -z "$GREENFIELD" ]; then
        $INSTALL_DIR/bin/start >> ${INSTALL_LOGFILE} 2>&1
    fi
}

load_driver()
{
    if lsmod | grep -iq involflt; then
        trace_log_message -q "Filter driver is already loaded"
        return 0
    fi

    copy_driver_file || return $?
    local driver_file_path="$k_dir/involflt.ko"
    if [ ! -f $driver_file_path ]; then
        trace_log_message "Filter driver file is not present"
        return $FAILED_LOAD_FILTER_DRIVER
    fi

    # Install the driver dependencies
    depmod -a >> ${INSTALL_LOGFILE} 2>&1

    modinfo $k_dir/involflt.ko >> ${INSTALL_LOGFILE} 2>&1

    if [ "${OS}" = "SLES12-64" -o "${OS}" = "SLES15-64" ]; then
	    modprobe -vs involflt --allow-unsupported >> ${INSTALL_LOGFILE} 2>&1
	else
        modprobe -vs involflt >> ${INSTALL_LOGFILE} 2>&1
    fi

    if lsmod | grep -iq involflt; then
        trace_log_message "Filter driver is loaded successfully"
    else
        trace_log_message "Failed to load filter driver"
        return $FAILED_LOAD_FILTER_DRIVER
    fi

    local maj_num=`cat /proc/devices | grep involflt | awk '{print $1}'`
    [ -e /dev/involflt ] || mknod /dev/involflt c $maj_num 0
    if [ $? -eq 0 ]; then
        trace_log_message "Filter device /dev/involflt created successfully..."
    else
        trace_log_message "Failed to create filter device /dev/involflt"
        return $FAILED_CREATE_FILTER_DEVICE
    fi

    # Ensure that we regenerate initrd to persist the driver across reboots
    if [ -z "$GREENFIELD" ]; then
        trace_log_message -q "Regenerating initrd..."
        $INSTALL_DIR/scripts/initrd/install.sh regenerate $ker_ver >> /var/log/InMage_drivers.log
    fi
}

# Function to detect OS and download driver
download_driver()
{
    if [ -d "$drivers_file_dir" ]; then
        trace_log_message -q "$drivers_file_dir already exists, hence not proceeding with the download."
        return 0
    fi

    local OS_VERSION=${OS}

    case "$OS_VERSION" in
        *"UBUNTU-18.04-64"*) OS_KEY="UBUNTU18" ;;
        *"UBUNTU-20.04-64"*) OS_KEY="UBUNTU20" ;;
        *"UBUNTU-22.04-64"*) OS_KEY="UBUNTU22" ;;
        *"UBUNTU-24.04-64"*) OS_KEY="UBUNTU24" ;;
        *"DEBIAN11-64"*) OS_KEY="DEBIAN11" ;;
        *"DEBIAN12-64"*) OS_KEY="DEBIAN12" ;;
        *"SLES15-64"*) OS_KEY="SLES15" ;;
        *"RHEL8-64"*) OS_KEY="RHEL8" ;;
        *"RHEL9-64"*) OS_KEY="RHEL9" ;;
        *) echo "Unsupported OS"; return 1 ;;
    esac

    URL=${DRIVERS[$OS_KEY]}
    trace_log_message -q "Detected OS: $OS_KEY"
    trace_log_message -q "Downloading from: $URL"

    # Download the driver package and extract it.
    # Purposely not logging the download progress as it may pollute the logs
    wget -O "${OS_KEY}_drivers.tar.gz" "$URL"
    if [ $? -ne 0 ]; then
        trace_log_message "Failed to download driver package"
        return 1
    fi

    tar -zxvf "${OS_KEY}_drivers.tar.gz" -C $test_root_dir
    if [ $? -ne 0 ]; then
        trace_log_message "Failed to extract driver package"
        return 1
    fi
}

trace_log_message -q  "`date`"
trace_log_message -q  "----------------------------"
download_driver || exit $?
stop_agent_service || exit $?
load_driver || exit $?
start_agent_service || exit $?