#!/bin/bash

rm -rf ./list.txt

for A in $(ls -l /home/master/applications/| grep "^d" | awk '{print $NF}'); do echo $A && if [[ -f /home/master/applications/$A/public_html/wp-config.php ]]; then echo $A >> ./list.txt; fi;done

while read line
do
	grep xmlrpc /etc/nginx/sites-available/$line >> /dev/null 2>&1
	if [[ $? -ne 0 ]]
	then
		echo "Adding XMLRPC to $line"
		sed -i '/additional_server_conf/a include /etc/nginx/extras/xmlrpc_blocked.conf;' /etc/nginx/sites-enabled/$line
	fi

done < ./list.txt
