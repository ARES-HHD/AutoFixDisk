#!/bin/bash
#description: fix the disks
#authors: ARES.HHD@gmail.com
#date: 2013-10-21 20:20

PATH="$PATH:/sbin:/bin:/usr/sbin:/usr/bin"
export PATH

mail_from_info="diskwatch@xxx"
mail_to_infor="xxx@xxx"
HOST=`hostname`
disk_msg=""

function mailhandle() {
#发送邮件信息
    subject=$1
    message=$2
    statusmsg=`/etc/init.d/sendmail status|grep running`
    if [ x"$statusmsg" == x"" ];then
        /etc/init.d/sendmail start
    fi

    release_msg=$(cat /etc/issue|grep "release 6")
    if [ x"$release_msg" != x"" ];then
        echo "$message" | mail -s "$subject" -r "$mail_from_info" "$mail_to_infor"
    else
        echo "$message" | mail -s "$subject" "$mail_to_infor" -- -f "$mail_from_info"
    fi
}

function megacli() {
#check the new disk and to do raid0

    if [ -e /opt/MegaRAID/MegaCli/MegaCli64 ]; then
        MEGACLI=/opt/MegaRAID/MegaCli/MegaCli64
    else
        MEGACLI=`which MegaCli`
    fi

    if $MEGACLI -PDList -a0 -NoLog|grep -q 'controller is not present'; then
        #subject="Raid not found! $HOST"
        message="Raid not found! $HOST"
        #mailhandle "$subject" "$message"
        echo $message
        return 2
    fi

    while read device slot 
    do

    if [ x"$device" != x"" ];then
        #change Unconfigured(bad) to Unconfigured(good)
        $MEGACLI -PDMakeGood -PhysDrv[$device:$slot] -a0 -NoLog 
        $MEGACLI -cfgforeign -clear -a0 -NoLog

        $MEGACLI GetPreservedCacheList -a0 -NoLog|grep "Target ID"
        if [ $? -eq 0 ]; then
            $MEGACLI -DiscardPreservedCache -Lall -aALL -NoLog
        fi
    fi

    done < <($MEGACLI -PDList -a0 -NoLog|grep -E 'Enclosure Device|Slot Number|Firmware state|Foreign State'|awk '{if(NR%4)printf $0",";else print $0}'|awk -F'[ :,]' '$13 == "Unconfigured(bad)"{print $5,$9}')

    while read device slot foreign 
    do

    if [ x"$device" != x"" ];then
        if [ x"$foreign" == x"Foreign" ];then
            $MEGACLI -cfgforeign -clear -a0 -NoLog
        fi

        $MEGACLI GetPreservedCacheList -a0 -NoLog|grep "Target ID"
        if [ $? -eq 0 ]; then
            $MEGACLI -DiscardPreservedCache -Lall –aALL -NoLog
        fi

        $MEGACLI -CfgLdAdd -r0[$device:$slot] WB Direct -a0 -NoLog
        disk_msg=$disk_msg" "$device":"$slot" "
    fi

    done < <($MEGACLI -PDList -a0 -NoLog|grep -E 'Enclosure Device|Slot Number|Firmware state|Foreign State'|awk '{if(NR%4)printf $0",";else print $0}'|awk -F'[ :,]' '$13 == "Unconfigured(good)"{print $5,$9,$(NF-1)}')

}

function hpacucli_create() {
#check the new disk and to do raid0 for hp 
    
    slot_num=`hpacucli ctrl all show status|grep 'Slot'|awk '{print $6}'`
    
    while read physicaldrive
    do

    if [ x"$physicaldrive" != x"" ];then
        hpacucli ctrl slot=$slot_num create type=ld drives=$physicaldrive raid=0
	dev_msg=$dev_msg" "$physicaldrive
    fi

    done < <(hpacucli ctrl slot=$slot_num show config detail|grep -E 'physicaldrive|Drive Type'|awk '{if(NR%2)printf $0;else print $0}'|awk '$5 == "Unassigned"{print $2}')
}

function set_raw(){
#set raw for centos 6

    DISK_DEV=`fdisk -l 2>/dev/null|grep Disk|grep -v identifier|grep -v -E 'c0d0|sda'|awk '{print $2}'|sed s/://g`
    PATH_RAWCONFIG='/etc/udev/rules.d/60-raw.rules'
    cat /dev/null > $PATH_RAWCONFIG
    i=1
    for disk_dev in $DISK_DEV
    do 
        dev=`echo $disk_dev|sed s#/dev/##g`
        echo "ACTION==\"add\", KERNEL==\"$dev\", RUN+=\"/bin/raw /dev/raw/raw$i %N\"" >> $PATH_RAWCONFIG
        echo "ACTION==\"add\", KERNEL==\"raw$i\", OWNER==\"root\", GROUP==\"root\", MODE==\"0777\"" >> $PATH_RAWCONFIG
        let i+=1
    done
    start_udev
}

#check disk is raid or not
is_raid=0

if lspci | grep -i -q 'RAID'; then
    is_raid=1
elif which lspci > /dev/null; then
    is_raid=0
fi

#Dell2850|1850
m_num=$(/usr/sbin/dmidecode -t system |grep "Product Name"|grep -i PowerEdge|awk '{print $4}')
if [ x"${m_num}" != x"" ];then
    if [ x"${m_num}" == x"1850" ] || [ x"${m_num}" == x"2850" ];then
        is_raid=0
    fi
fi

#check machine type and handle
#/usr/sbin/dmidecode -t system |grep 'Product Name'|head -1|cut -d : -f 2|egrep -i -q 'PowerEdge|IBM'
machine_type=`/usr/sbin/dmidecode -t system |grep 'Product Name'|head -1|cut -d : -f 2`
if echo $machine_type|egrep -i -q 'PowerEdge|IBM';then
    machine="mega"
elif echo $machine_type|egrep -i -q 'ProLiant';then
    machine="hpac"
fi

if [ x"$machine" == x"mega" ] && [ x"$is_raid" == x"1" ]; then
    megacli
    RETVAL=$?
    if [ $RETVAL -ne 0 ] && [ $RETVAL -ne 2 ]; then
        subject="Fail! $HOST fail to megacli raid0"
        message="$HOST fail to megacli raid0"
        mailhandle "$subject" "$message"
    elif [ $RETVAL -eq 0 ] && [ x"$disk_msg" != x"" ]; then
        subject="Success! $HOST was successful in megacli raid0"
        message="$HOST was successful in megacli raid0$disk_msg"
        mailhandle "$subject" "$message"
        release_msg=$(cat /etc/issue|grep "release 6")
        if [ x"$release_msg" != x"" ];then
            set_raw
        fi
        /usr/local/bin/traffic_line -R
	    
    fi
elif [ x"$machine" == x"hpac" ] && [ x"$is_raid" == x"1" ]; then 
    hpacucli_create
    RETVAL=$?
    if [ $RETVAL -ne 0 ] && [ $RETVAL -ne 2 ]; then
        subject="Fail! $HOST fail to hpacucli raid0"
        message="$HOST fail to hpacucli raid0"
        mailhandle "$subject" "$message"
    elif [ $RETVAL -eq 0 ] && [ x"$dev_msg" != x"" ]; then
        subject="Success! $HOST was successful in hpacucli raid0"
        message="$HOST was successful in hpacucli raid0$dev_msg"
        mailhandle "$subject" "$message"
        release_msg=$(cat /etc/issue|grep "release 6")
        if [ x"$release_msg" != x"" ];then
            set_raw
        fi
        /usr/local/bin/traffic_line -R
	    
    fi

fi
