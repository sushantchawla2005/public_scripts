#!/bin/bash

mkdir /home/master/scripts/
SCRIPTFILE=/home/master/scripts/cleanup-prestashop-cache.sh
CRONSCRIPT=/etc/cron.d/cleanup-prestashop-cache

echo "#!/bin/bash" > ${SCRIPTFILE}
echo "DATE=\$(date +%F-%H)" >> ${SCRIPTFILE}
echo "LOGFILE=/home/master/scripts/cache-cleanup.log" >> ${SCRIPTFILE}
echo "PATH1=/home/master/applications/*/public_html/var/cache/" >> ${SCRIPTFILE}
echo 'echo "### Running the cleanup of 7 days older files from path(s): ${PATH1} on ${DATE} ###" | tee -a ${LOGFILE}' >> ${SCRIPTFILE}
echo "find \${PATH1} -type f -mtime +7 -print -exec rm -f {} \; >> \${LOGFILE} 2>&1" >> ${SCRIPTFILE}

chmod +x ${SCRIPTFILE}

echo "PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin" > ${CRONSCRIPT}
echo "0 18 * * * root /home/master/scripts/cleanup-prestashop-cache.sh" >> ${CRONSCRIPT}
