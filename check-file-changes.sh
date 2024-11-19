#! /bin/bash

#####################################################
# Script to check file changes during last 60 minutes
# and send alert on slack channel
# Author: Sushant Chawla
#####################################################

# Global Variables Initialization
FIND="/usr/bin/find"
PROGNAME=$0
PATH=$1
FILE_EXTENSION=$2
WC="/usr/bin/wc"
SLACK_WEBHOOK_URL=""
SLEEP="/bin/sleep"
GREP="/bin/grep"
HOSTNAME=$(/usr/bin/dig @resolver1.opendns.com myip.opendns.com +short)
DATE="`/bin/date +%Y%m%d-%H`"
# End Global Variables Initialization

# If arguments are less, show help
if [ $# -lt 2 ]
then
	echo -e
	echo -e "USAGE: ${PROGNAME} Folder-Path \"File-Extension\""
	echo -e "Example: ${PROGNAME} /home/master/applications/*/public_html/ \"*.php\""
	echo -
	${SLEEP} 1
	exit 1
fi

COUNT=`${FIND} ${PATH} -type f -iname "${FILE_EXTENSION}" -mmin -60 -print | ${WC} -l`
if [ ${COUNT} -eq 0 ]
then
	echo -e "Could not find any modified file(s) on ${PATH} with the extension ${FILE_EXTENSION}"
else
	FILESLIST=/tmp/modified-files-list.txt
	echo "" > ${FILESLIST}
	${FIND} ${PATH} -type f -iname "${FILE_EXTENSION}" -mmin -60 -ls >> ${FILESLIST}
	MESSAGE=":Warning: *${HOSTNAME}*: Files Changed recently on path *${PATH}*: \n $(/usr/bin/cat ${FILESLIST})"
	echo "${MESSAGE}"
	# Send alert to Slack
	/usr/bin/curl -X POST -H 'Content-type: application/json' --data "{\"text\": \"$MESSAGE\"}" ${SLACK_WEBHOOK_URL}
fi
