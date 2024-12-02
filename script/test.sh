#!/usr/bin/env bash

SIMPLEFS_MOD=simplefs.ko
IMAGE=${1:-simplefs.img}
IMAGESIZE=${2:-400}
MKFS=${3:-mkfs.simplefs}

D_MOD="drwxr-xr-x"
F_MOD="-rw-r--r--"
S_MOD="lrwxrwxrwx"
SIMPLEFS_BLOCK_SIZE=4096
SIMPLEFS_MAX_BLOCKS_PER_EXTENT=8
SIMPLEFS_MAX_SIZES_PER_EXTENT=$((SIMPLEFS_MAX_BLOCKS_PER_EXTENT*SIMPLEFS_BLOCK_SIZE))
SIZEOF_U32=4
SIZEOF_SIMPLEFS_EXTENT=$((3*$SIZEOF_U32))
SIMPLEFS_MAX_EXTENTS=$(((SIMPLEFS_BLOCK_SIZE-$SIZEOF_U32)/$SIZEOF_SIMPLEFS_EXTENT))
MAXFILESIZE=$(($SIMPLEFS_MAX_EXTENTS*$SIMPLEFS_MAX_BLOCKS_PER_EXTENT*$SIMPLEFS_BLOCK_SIZE)) # should compute to 11173888
MAXFILES=40920        # max files per dir
MOUNT_TEST=100
QUIETLY=0

test_op() {
    local op=$1
    if [ $QUIETLY -eq 0 ]; then
        echo -n "Testing cmd: $op ..."
    fi
    sh -c "$op" > /dev/null
    if [ $? -eq 0 ];then
	if [ $QUIETLY -eq 0 ]; then
	    echo "Success"
	fi
	return 0
    else
	if [ $QUIETLY -ne 0 ]; then
	    echo "Failed while testing cmd: $op ..."
        else
	    echo "Failed"
	fi
    fi
    return 1
}

check_exist() {
    local mode=$1
    local nlink=$2
    local name=$3
#    echo
    echo -n "Check if exist: $mode $nlink $name..."
#    sudo ls -lR  | grep -e "$mode $nlink".*$name >/dev/null && echo "Success" || \
    ls -lR  | grep -e "$mode $nlink".*$name >/dev/null
    if [ $? -eq 0 ];then
	echo "Success"
    else
    	echo "Failed"
    fi
}

if [ "$EUID" -eq 0 ]; then
    echo "Don't run this script as root"
    exit 1
fi

modinfo $SIMPLEFS_MOD > /dev/null 2>&1 
if [ $? -ne 0 ]; then
    echo "No such module as $SIMPLEFS_MOD. You need to make it first."
    exit 1
fi

if [ ! -x $MKFS ]; then
    echo "No such executable as $MKFS. Be sure to make it first."
    exit 1
fi

if [ -d test ]; then
    sudo umount test 2>/dev/null
    sleep 1
    rm -rf test
fi
mkdir -p test
echo "Replacing simplefs module ..."
sudo rmmod simplefs 2>/dev/null
sleep 1
modinfo $SIMPLEFS_MOD
if [ $? -ne 0 ]; then
    echo "Module info not obtained"
    exit 1
fi
echo "Inserting simplefs module ..."
sudo insmod $SIMPLEFS_MOD
if [ $? -ne 0 ]; then
    echo "Failed to insert simplefs module"
    exit 1
fi
echo "Create image: $IMAGE with size of $IMAGESIZE Megabytes ..."
rm -f $IMAGE
dd if=/dev/zero of=$IMAGE bs=1M count=$IMAGESIZE > /dev/null 2>&1
if [ $? -ne 0 ]; then
    echo "Failed to create $IMAGE"
    exit 1
fi
echo "Create empty filesystem in $IMAGE ..."
./$MKFS $IMAGE
if [ $? -ne 0 ]; then
    echo "Failed to create filesystem in $IMAGE"
    exit 1
fi
echo "Mount simplefs to 'test' ..."
sudo mount -t simplefs -o loop,owner $IMAGE test
if [ $? -ne 0 ]; then
    echo "Failed to mount simplefs to 'test'"
    exit 1
fi
echo "Change permissions on filesystem to allow writes ..."
sudo chmod 777 test
if [ $? -ne 0 ]; then
    echo "Failed to change permissions"
    exit 1
fi
echo "cd to 'test'"
pushd test >/dev/null
if [ $? -ne 0 ]; then
    echo "Failed to pushd to 'test'"
    exit 1
fi
# mkdir
test_op 'mkdir dir'
echo "The following mkdir is expected to fail with 'already exists' ..."
test_op 'mkdir dir' # expected to fail

# create file
test_op 'touch file'

# create MAXFILES files
QUIETLY=1
file_limit=$(($MAXFILES-2))	# Have two files created earlier, so account for them
for ((i=0; i<$file_limit; i++))
do
#    test_op "echo $i > $i.txt"
    lastfile=$(($i+999))
    if [ $lastfile -ge $file_limit ]; then
	lastfile=$(($file_limit-1))
    fi
    if [ $(($i%1000)) -eq 0 ]; then
        echo "`date +%T`: Creating files $i.txt through $lastfile.txt ..."
    fi
    test_op "touch $i.txt"
    if [ $? -ne 0 ]; then
	exit 1
    fi
done
QUIETLY=0
echo "Expect this last one to fail ..."
test_op "touch $i.txt"
if [ $? -eq 0 ]; then
	echo "It didn't fail like it was supposed to ..."
	exit 1
fi
filecnts=$(ls | wc -w)
filecnts=$(($filecnts))
if [ $filecnts -ne $MAXFILES ];then
    echo "Fail count check failed: filecnt of $filecnts should be exactly $MAXFILES."
    exit 1
fi
sync
echo "Ensure all the txt files exist ..."
for ((i=0; i<$file_limit; i++))
do
    lastfile=$(($i+999))
    if [ $lastfile -ge $file_limit ]; then
	lastfile=$(($file_limit-1))
    fi
    if [ $(($i%1000)) -eq 0 ]; then
        echo "`date +%T`: Checking for existence of $i.txt through $lastfile.txt ..."
    fi
    if [ ! -f "$i.txt" ]; then
        echo "Failed: $i.txt does not exist."
        exit 1
    fi
    rm -f $i.txt
done

# create 100 files with filenames inside
for ((i=1; i<=$MOUNT_TEST; i++))
do
    echo file_$i > file_$i.txt
    if [ $? -ne 0 ]; then
        echo "Failed to create file_$i.txt"
	exit 1
    fi
done
sync

# unmount and remount the filesystem
echo "Unmounting filesystem..."
popd > /dev/null
if [ $? -ne 0 ]; then
    echo "popd failed"
    exit 1
fi
sudo umount test
if [ $? -ne 0 ]; then
    echo "umount failed"
    exit 1
fi
sleep 1
echo "Remounting filesystem..."
sudo mount -t simplefs -o loop,owner $IMAGE test
if [ $? -ne 0 ]; then
    echo "mount failed"
    exit 1
fi
echo "Remount succeeds."
pushd test
if [ $? -ne 0 ]; then
    echo "pushd to test failed"
    exit 1
fi

echo "Check if files exist and content is correct after remounting ..."
for ((i=1; i<=$MOUNT_TEST; i++))
do
    if [[ -f "file_$i.txt" ]]; then
        content=$(cat "file_$i.txt" | tr -d '\000')
        if [[ "$content" != "file_$i" ]]; then
            echo "Failed: file_$i.txt content is incorrect."
            exit 1
        fi
    else
        echo "Failed: file_$i.txt does not exist."
        exit 1
    fi
done

# hard link
test_op 'ln file hdlink'
test_op 'mkdir -p dir/dir'

# symbolic link
test_op 'ln -s file symlink'

# list directory contents
test_op 'ls -lR'

# now it supports longer filename
test_op 'mkdir len_of_name_of_this_dir_is_29'
test_op 'touch len_of_name_of_the_file_is_29'
test_op 'ln -s dir len_of_name_of_the_link_is_29'

# write to file
test_op 'echo abc > file'
test $(cat file) = "abc" || echo "Failed to write"

# file too large
echo "The 'dd' operation is expected to fail with 'no room' error"
test_op 'dd if=/dev/zero of=file bs=1M count=12 status=none'
if [ $? -eq 0 ]; then
    echo "dd command did not fail as expected."
    exit 1
fi
filesize=$(stat --printf "%s" file)
if [ $? -ne 0 ]; then
    echo "Failed to compute size of 'file' made by dd command"
    exit 1
fi
if [ $filesize -gt $MAXFILESIZE ]; then
       echo "Failed, file size ($filesize) is over the limit ($MAXFILESIZE)"
       exit 1
fi

# test remove symbolic link
test_op 'ln -s file symlink_fake'
test_op 'rm -f symlink_fake'
test_op 'touch symlink_fake'
test_op 'ln file symlink_hard_fake'
test_op 'rm -f symlink_hard_fake'
test_op 'touch symlink_hard_fake'

# test if exist
check_exist $D_MOD 3 dir
check_exist $F_MOD 2 file
check_exist $F_MOD 2 hdlink
check_exist $D_MOD 2 dir
check_exist $S_MOD 1 symlink
check_exist $F_MOD 1 symlink_fake
check_exist $F_MOD 1 symlink_hard_fake

sleep 1
popd >/dev/null
sudo umount test
sudo rmmod simplefs
rmdir test
