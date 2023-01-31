#!/bin/bash
WP_LANG=en_US

echo "This script will clear all files/folders from webroot of wordpress site except wp-content folder and files like wp-config.php, robots.txt, etc and install fresh and latest wordpress core"
echo -e
echo "Current language pack set in the script is: ${WP_LANG}"
sleep 5

# Create list of applications
ls -l /home/master/applications/| grep "^d" | awk '{print $NF}' > /home/master/applications/list.txt

# Fetch latest wordpress core
rm -rf /tmp/wordpress
mkdir -p /tmp/wordpress
cd /tmp/wordpress && /usr/local/bin/wp --allow-root core download --locale=${WP_LANG}
wget https://raw.githubusercontent.com/sushantchawla2005/public_scripts/a35020d1bc9e976b0ef0d41b8edba664ff566545/wp-salt.php
rm -rf /tmp/wordpress/wp-content
echo "# BEGIN WordPress" > /tmp/wordpress/.htaccess
echo "<IfModule mod_rewrite.c>" >> /tmp/wordpress/.htaccess
echo "RewriteEngine On" >> /tmp/wordpress/.htaccess
echo "RewriteBase /" >> /tmp/wordpress/.htaccess
echo "RewriteRule ^index.php$ - [L]" >> /tmp/wordpress/.htaccess
echo "RewriteCond %{REQUEST_FILENAME} !-f" >> /tmp/wordpress/.htaccess
echo "RewriteCond %{REQUEST_FILENAME} !-d" >> /tmp/wordpress/.htaccess
echo "RewriteRule . /index.php [L]" >> /tmp/wordpress/.htaccess
echo "</IfModule>" >> /tmp/wordpress/.htaccess
echo "# END WordPress" >> /tmp/wordpress/.htaccess


if [[ -d "/tmp/wordpress/wp-admin" ]];
then
	while read line;
	do
		sleep 1
		echo "Cleaning up application $line"
		WEBROOT=/home/master/applications/$line/public_html
		TMP=/home/master/applications/$line/tmp
			if [[ -f "${WEBROOT}/wp-config.php" ]];
			then
				echo "$line is a wordpress site"
				mv ${WEBROOT}/wp-content ${TMP}/
				[ -e ${WEBROOT}/wp-config.php ] && mv ${WEBROOT}/wp-config.php ${TMP}/
				[ -e ${WEBROOT}/malcare-waf.php ] && mv ${WEBROOT}/malcare-waf.php ${TMP}/
				[ -e ${WEBROOT}/robots.txt ] &&  mv ${WEBROOT}/robots.txt ${TMP}/
				[ -e ${WEBROOT}/wordfence-waf.php ] && mv ${WEBROOT}/wordfence-waf.php ${TMP}/
				[ ! -d ${WEBROOT}/wp-content ]; rm -rf ${WEBROOT}/*

				cp -ar /tmp/wordpress/* ${WEBROOT}/ && cp -ar /tmp/wordpress/.htaccess ${WEBROOT}/
				mv ${TMP}/* ${WEBROOT}/
				chown -R $line:www-data ${WEBROOT}/ && chmod -R 775 ${WEBROOT}/&& chmod 640 ${WEBROOT}/wp-config.php
			else
				echo "$line is not a wordpress site, doing nothing"
			fi
	done < /home/master/applications/list.txt

else
	echo "There is a possible issue downloading fresh wordpress copy from wordpress.org at /tmp/wordpress, exiting..."
	exit 1
fi
