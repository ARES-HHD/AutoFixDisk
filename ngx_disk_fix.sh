#!/bin/bash
#description: fix the disks
#authors: ARES.HHD@gmail.com
#date: 2013-10-21 20:20

PATH="$PATH:/sbin:/bin:/usr/sbin:/usr/bin"
export PATH

mail_from_info="diskwatch@xxx"
mail_to_infor="xxx@xxx"
HOST=`hostname`
role=`echo $HOST|awk -F. '{print $3}'`
disk_msg=""
var_msg=""

function report_to_bk() {
#调用bookkeeper的api摘除磁盘
    local mnt
    local args
    api=$1
    mnt=${2/\/data}
    args=$3
    server=$(cat /usr/local/fetcher/fetcher.conf|grep -v "^#"|grep "myip"|awk '{print $NF}')
    bookkeeper=$(cat /usr/local/fetcher/fetcher.conf|grep -v "^#"|grep "bookkeeper"|awk '{print $NF}')

    if [ x"$api" == x"add_location" ];then
        bkmsgs=`curl -s http://$bookkeeper/stats|awk 'BEGIN{RS="},  |{|]}"}{print $0}'|egrep -v 'result|url_count|reason|^$'|awk '{print $2,$8,$10}'|sed 's/,//g;s/"//g'`
        bkmsg=`echo "$bkmsgs"|grep "$server $mnt"`
        if [ x"$bkmsg" == x""];then
            server_private_ip=$(cat /usr/local/init_bk_location/init_loc_settings.py|grep "SELF_PRIVATE_IP"|awk '{print $NF}'|sed s/\'//g)
            pr_pu_dk="privateip=$server_private_ip&publicip=$server&disk=$mnt"
            echo "curl -m 5 -d \"$pr_pu_dk\" http://$bookkeeper/$api"
            curl -m 5 -d "$pr_pu_dk" http://$bookkeeper/$api
            echo ""
        else
            sta=`echo $bkmsg|awk '{print $1}'`
            if [ x"$sta" == x"-1"];then
                api="change_location"
                args="1"
            fi
        fi
    fi

    if [ x"$api" == x"change_location" ];then
        data="publicip=$server&disk=$mnt"
    
        if [ ! -z "$args" ]; then
            data="$data&status=$args"
        fi
    
        echo "curl -m 5 -d \"$data\" http://$bookkeeper/$api"
        curl -m 5 -d "$data" http://$bookkeeper/$api
        echo ""
    fi
}

function report_to_ngxcluster() {
    local mnt
    local args
    mnt=$1
    args=$2
    mapfile=/usr/local/sinaedge/esnv2/nginx.chash.mmap
    cmd=/usr/local/sinaedge/esnv2/sbin/disk_stat
    cachepath=/usr/local/sinaedge/esnv2/conf/cache_store.conf
    value=`$cmd $mapfile|grep $mnt|awk '{print $2}'`
    weight=`grep $mnt $cachepath|awk '{print $3}'|awk -F';' '{print $1}'`
  
    if [ ! -n "$weight" ]; then
        weight=100
    fi
   
    if [ 0 -eq "$args" ]; then      
        if [ -n "$value" ] && [ "$value" -gt 0 ]; then 
            $cmd $mapfile $mnt 0
            echo "modity $mnt weight to 0!"
        fi
    elif [ 1 -eq "$args" ]; then
        if [ ! -n "$value" ] || [ "$weight" -ne "$value" ]; then 
            $cmd $mapfile $mnt $weight
            echo "modity $mnt weight to $weight!"
        fi
    else
        echo "wrong input!"
    fi
}

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

function handle() {
#处理磁盘、格式化磁盘
    arg1=$1
    mnt=`df -h|grep data|grep $arg1|awk '{print $6}'`
    role=`echo $HOST|awk -F. '{print $3}'`
    if [ x"$role" == x"esnv2" ];then
        report_to_ngxcluster $mnt 0
    else
        report_to_bk change_location $mnt -1
    fi
    if [ x"$mnt" == x"/data0" ];then
        subject="$HOST $mnt read-only"
        message="please manual fix $HOST $mnt read-only"
        mailhandle "$subject" "$message"
        echo "data0 read-only" >> /tmp/disks.txt
    else
        umount $mnt
        if [ $? -ne 0 ]; then
            if [ x"$role" == x"esnv2" ];then
                /etc/init.d/esnv2 stop
                umount $mnt
                /etc/init.d/esnv2 start
            else
                /etc/init.d/nginx stop
                umount $mnt
                /etc/init.d/nginx start
            fi
        fi

        mkfs.ext3  $arg1
        mount $arg1 $mnt

        chmod -R 777 $mnt
        chown -R daemon:daemon $mnt
        echo "$mnt read-only" >> /tmp/disks.txt

    fi
}

function mountmsg() {
#通过/proc/mounts获取磁盘信息，从而判断磁盘good or bad
    dev=$1
    flag=`cat /proc/mounts |grep $dev|awk '{print $4}'|awk -F',' '{print $1}'`
    if [ "$flag" != "rw" ];then
        return 1
    else
        return 0
    fi
}

function judge_handle() {
#判断磁盘good or bad，并执行handle操作，失败，停止格式化，发邮件报警
    if [ $1 -ne 0 ]; then
        handle $dev
        $2 $dev
        RET=$?
        mnt_data=`cat /proc/mounts |grep $dev|grep "/data0"`
        if [ $RET -ne 0 ] && [ x"$mnt_data" == x"" ]; then
            subject="Fail! $HOST $dev read-only fail"
            message="please manual fix $HOST $dev read-only"
            mailhandle "$subject" "$message"

            #如果格式化失败，使得磁盘处于umount状态
            umount $mnt
            if [ $? -ne 0 ]; then
                if [ x"$role" == x"esnv2" ];then
                    /etc/init.d/esnv2 stop
                    umount $mnt
                    /etc/init.d/esnv2 start
                else
                    /etc/init.d/nginx stop
                    umount $mnt
                    /etc/init.d/nginx start
                fi
            fi
        elif [ $RET -eq 0 ] && [ x"$mnt_data" == x"" ]; then
            mnt=`cat /proc/mounts |grep $dev|awk '{print $2}'`
            if [ x"$role" == x"esnv2" ];then
                report_to_ngxcluster $mnt 1
            else
                report_to_bk change_location $mnt 1
            fi

            subject="Success! $HOST was successful in fixing $mnt read-only"
            message="$HOST was successful in fixing $mnt read-only"
            mailhandle "$subject" "$message"
        fi
    fi
}


function megacli() {
#check the new disk and to do raid0 for dell and ibm

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
            $MEGACLI -DiscardPreservedCache -Lall -aALL -NoLog
        fi

        $MEGACLI -CfgLdAdd -r0[$device:$slot] WB Direct -a0 -NoLog
        disk_msg=$disk_msg" "$device":"$slot
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

function fdisk_mkfs() {
#check the new dev and to do fdisk_mkfs

    mounts_dev=`df 2>/dev/null|grep data|grep -v -E 'c0d0|sda'|awk '{print $1}'`
    for var in `fdisk -l 2>/dev/null|grep Disk|grep -v identifier|egrep -v 'c0d0|sda'|awk '{print $2}'|sed s/://g`
    do
        if echo $mounts_dev|grep -v $var >/dev/null;then
            fdisk_dev=`fdisk -l 2>/dev/null|grep Linux|egrep -v 'c0d0|sda'|awk '{print $1}'`
            if echo $fdisk_dev|grep -v $var >/dev/null;then
                fdisk $var << END
                d
                n
                p
                1


                w
END

                partprobe

                sleep 5
                hp=`echo $var|grep 'cciss'`
                tt=${var:(-1)}
                if [ x"$hp" == x"" ];then
                    mkfs.ext3 "$var"1
                    nn=$(expr `printf '%d' "'$tt"` - `printf '%d' "'a"`)
                    if [ ! -d /data"$nn" ];then
                        mkdir /data"$nn"
                    fi
                    mount "$var"1 /data"$nn"
                else
                    mkfs.ext3 "$var"p1
                    nn=$tt
                    if [ ! -d /data"$nn" ];then
                        mkdir /data"$nn"
                    fi
                    mount "$var"p1 /data"$nn"
                fi

                chmod -R 777 /data"$nn"
                chown -R daemon:daemon /data"$nn" 
                if [ x"$role" == x"esnv2" ];then
                    report_to_ngxcluster /data"$nn" 1
                else
                    report_to_bk add_location /data"$nn" 
                fi
                var_msg=$var_msg" "$var
            fi
        fi
    done 
}


for dev in `df -h|grep data |awk '{print $1}'`
do
#对所有磁盘进行遍历
    mountmsg $dev
    judge_handle $? "mountmsg"

done

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
    fi
fi

fdisk_mkfs
RET_VAL=$?
if [ $RET_VAL -ne 0 ]; then
    subject="Fail! $HOST fail to fdisk_mkfs"
    message="$HOST fail to fdisk_mkfs"
    mailhandle "$subject" "$message"
elif [ $RET_VAL -eq 0 ] && [ x"$var_msg" != x"" ]; then
    subject="Success! $HOST was successful in fdisk_mkfs"
    message="$HOST was successful in fdisk_mkfs$var_msg"
    mailhandle "$subject" "$message"
fi

for da in `ls /|grep data`
#有没有挂载磁盘通知bk，以此跟bk同步磁盘信息
do
    disk_mount=`cat /proc/mounts |grep '/data'`
    if echo $disk_mount|grep -v $da >/dev/null;then
        if [ x"$role" == x"esnv2" ];then
            report_to_ngxcluster /$da 0
        else
            report_to_bk change_location /$da -1
        fi
    else
        if [ x"$role" == x"esnv2" ];then
            report_to_ngxcluster /$da 1
        else
            report_to_bk add_location /$da 
        fi
    fi
done

