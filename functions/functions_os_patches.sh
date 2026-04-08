#!/bin/bash
function fixup_dtoverlay_linking {
    echo "--------------------------------------------------------------"
    echo " Fixing dtoverlay utility (Bookworm bug)"
    echo "--------------------------------------------------------------"
    apt install cmake device-tree-compiler libfdt-dev libncurses-dev --assume-yes --fix-missing
    cd /tmp
    wget -q https://github.com/raspberrypi/utils/archive/refs/heads/master.zip
    unzip -q master.zip
    cd utils-master
    cmake .
    make -j4
    make install
    cd /tmp
    rm -rf utils-master master.zip
}
