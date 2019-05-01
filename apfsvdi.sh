#!/bin/bash

##
##  apfsvdi.sh
##
##  Created by Bryan Christianson (bryan@whatroute.net) on 1/05/19.
##  Copyright © 2019 Bryan Christianson. All rights reserved.
##
##
##    This program is free software: you can redistribute it and/or modify
##    it under the terms of the GNU General Public License as published by
##    the Free Software Foundation, either version 3 of the License, or
##    (at your option) any later version.
##
##    This program is distributed in the hope that it will be useful,
##    but WITHOUT ANY WARRANTY; without even the implied warranty of
##    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
##    GNU General Public License for more details.
##
##    You should have received a copy of the GNU General Public License
##    along with this program.  If not, see <https://www.gnu.org/licenses/>.
##

# This script creates an empty .vdi file that can be used for running macOS Mojave
# as a VirtualBox Virtual machine.
#
# 1. Download and install VirtualBox
# 2. Download the Mojave Installer application from Apple (apple.com)
# 3. Generate a bootable ISO installer file using a suitable script (InstallerApp2ISO comes to mind for this)
# 4. Use the generated ISO as input to this script to create a VirtualBox VDI file.
# 5. Run VirtualBox and create a new macOS 64 bit VM. Use your newly create .vdi file
# 6. Load your ISO file into the VM's DVD drive
# 7. Continue with the macOS Mojave installation
#

##
## Based on the macOS Mojave VirtualBox installer created by Alexander Willner
##
## https://github.com/AlexanderWillner/runMacOSinVirtualBox
##

#
# The 'cunning plan' being used in this script is to copy the APFS driver from the
# Apple macOS Installer ISO to the EFI file tree, along with the nifty EFI startup.nsh
# borrowed from Alexander Willners code.
#
# There are no 3rd party binaries installed in the EFI tree or into the macOS filesystem
#

# ---------------------------------------------------------------
# Set some script strict checking
# ---------------------------------------------------------------
#set -o errexit;
#set -u
#set -o pipefail

my_usage()
{
    echo ""
    echo "Usage:"
    echo ""
    echo "   apfsvdi.sh  -i|--iso <macOS Installer ISO>"
    echo "               -s|--size <VDI disk size in GB - default 64>"
	exit $1
}

#
# Initialise variables
#
ISO=""
SIZE=64


# ---------------------------------------------------------------
# Parse the arguments.
# ---------------------------------------------------------------
if [ $# -eq "0" ]; then
    echo "*** ERROR: No arguments specified. The --iso option is mandatory."
    my_usage 1
fi

while test $# -ge 1;
do
    ARG=$1;
    shift;
    case "$ARG" in
        -i|--iso)
            if test $# -eq 0; then
                echo "*** ERROR: missing --installer argument.";
                echo "";
                exit 1;
            fi
            ISO="$1";
            if [ ! -f "$ISO" ]; then
            	echo "$ISO" cannot be found.
            	exit 1
            fi
            shift;
            ;;

		-s|--size)
            if test $# -eq 0; then
                echo "*** ERROR: missing --size argument.";
                echo "";
                exit 1;
            fi
            SIZE="$1";
            if test "$SIZE" -lt 10; then
            	echo "$SIZE GB is too small to install macOS."
            	myusage 1
            fi
            if test "$SIZE" -gt 100000; then
            	echo "$SIZE GB is too large to install."
            	myusage 1
            fi
            shift;
            ;;

        *)
            echo "*** ERROR: Invalid syntax."
            my_usage 1;
            ;;
    esac
done

PREFIX="$(basename -s .iso $ISO)"
DIR="$(dirname $ISO)"

VDI=$DIR/$PREFIX.vdi
SPARSE=$DIR/$PREFIX.sparsebundle
PLIST=$DIR/$PREFIX.plist

#
# Mount the ISO and find its mounted volume name
#
INSTALLER="$(hdiutil attach "$ISO" | awk -F '\t' '/Apple_HFS/ {print $3}')"
echo $INSTALLER

#
# Check the CFBundleVersion
#
app=$(ls -d "$INSTALLER"/*.app)
plist="$app/Contents/Info.plist"
if [ ! -f "$plist" ]; then
	echo "$INSTALLER does not contain an Info.plist file"
	exit 1
fi
version="$(/usr/libexec/PlistBuddy -c "print :CFBundleVersion" "${plist}")"

echo "version: $version"
if [ version -lt 14000 ]; then
	echo "Cannot create APFS file system with $INSTALLER"
	exit 1
fi

#
# Locate the Base System image within the installer
#
BASESYSTEM="$(find "$INSTALLER" -name BaseSystem.dmg)"
echo $BASESYSTEM

#
# Mount the base system and find the path to the APFS boot driver
#
BASEMOUNT="$(hdiutil attach "$BASESYSTEM" | awk -F '\t' '/Apple_HFS/ {print $3}')"
echo $BASEMOUNT
APFS_EFI="$BASEMOUNT"/usr/standalone/i386/apfs.efi

#
# Create and attach a sparse bundle - it will be converted to the VDI file
#
rm -rf $SPARSE
hdiutil create -layout GPTSPUD -type SPARSEBUNDLE -fs APFS -size $SIZE"g" $SPARSE
hdiutil attach $SPARSE -nomount -plist > "$PLIST"

EFI_DEV=$(/usr/libexec/PlistBuddy -c "print :system-entities:0:dev-entry" "$PLIST")
DEVICE=$(/usr/libexec/PlistBuddy -c "print :system-entities:1:dev-entry" "$PLIST")

## we're finished with the .plist file
rm -f "$PLIST"

#
# Add the required entries to the EFI file system
#
echo $EFI_DEV
diskutil mount $EFI_DEV

#
# copy the apfs.efi driver into the EFI file system
#
mkdir -p /Volumes/EFI/EFI/drivers
cp "$APFS_EFI" /Volumes/EFI/EFI/drivers/

# we're finished with the ISO and can unmount the file systems
hdiutil detach "$BASEMOUNT"
hdiutil detach "$INSTALLER"

#
# create startup and install the script to boot either macOS or the macOS installer
#
cat <<EOT > /Volumes/EFI/startup.nsh
@echo -off
#fixme startup delay
set StartupDelay 0
load "fs0:\EFI\drivers\apfs.efi"
#fixme bcfg driver add 0 "fs0:\\EFI\\drivers\\apfs.efi" "APFS Filesystem Driver"
map -r
echo "Trying to find a bootable device..."
for %p in "macOS Install Data" "macOS Install Data\Locked Files\Boot Files" "OS X Install Data" "Mac OS X Install Data" "System\Library\CoreServices" ".IABootFiles"
  for %d in fs2 fs3 fs4 fs5 fs6 fs1
    if exist "%d:\%p\boot.efi" then
      echo "Booting: %d:\%p\boot.efi ..."
      #fixme: bcfg boot add 0 "%d:\\%p\\boot.efi" "macOS"
      "%d:\%p\boot.efi"
    endif
  endfor
endfor
echo "Failed."
EOT

## convert the sparseimage disk to a VirtualBox .vdi file
echo "Creating the VDI file: $VDI"
echo "This going to take a while"
rm -f "$VDI"
VBoxManage convertfromraw "$DEVICE" "$VDI" --format VDI

#
# cleanup
#
diskutil unmount $EFI_DEV
diskutil eject $DEVICE
rm -rf $SPARSE

