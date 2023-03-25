#!/bin/bash

cat /home/master/applications/*/conf/server.apache  | grep -i serveralias | sed 's/\#UI_Domain_alias//' | sed 's/[a-z]*.[a-z]*.[0-9]*.[0-9]*.cloudwaysapps.com//g' | sed 's/ServerAlias//' | awk {'print $NF}' | sed '/^[[:space:]]*$/d' > /tmp/domains.txt

while read DOMAIN
do
	website="${DOMAIN}"
	certificate_file=$(mktemp)
	echo -n | openssl s_client -servername "$website" -connect "$website":443 2>/dev/null | sed -ne '/-BEGIN CERTIFICATE-/,/-END CERTIFICATE-/p' > $certificate_file
	date=$(openssl x509 -in $certificate_file -enddate -noout | sed "s/.*=\(.*\)/\1/")
	date_s=$(date -d "${date}" +%s)
	now_s=$(date -d now +%s)
	date_diff=$(( (date_s - now_s) / 86400 ))
	echo "$website will expire in $date_diff days"
	rm "$certificate_file"
done < /tmp/domains.txt
