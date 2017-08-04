#!/bin/sh

ifconfig ${1} up

udhcpc -i ${1} -n -s /etc/udhcpc.script
