#!/bin/bash
###################
# Global Variables
###################

WP="/usr/local/bin/wp --allow-root --skip-themes --skip-plugins"
PREFIX=`grep "table_prefix" ./wp-config.php | awk '{print $3}'| tr -d \'\;`
GREP="/bin/grep"
WC="/usr/bin/wc"
MYSQL="/usr/bin/mysql"

echo -e " "
# Check wordpress version
echo -e "Your Current Wordpress Version is: `${WP} core version`"

echo -e " "
# Verify checksum
echo -e "Wordpress checksum verification result is:"
${WP} core verify-checksums

# Check plugin status
echo -e "
Plugins Status:"
${WP} plugin status

# Check Theme status
echo -e "
Themes Status:"
${WP} theme status

# Check Cron status
echo -e "
Cron Status: `${WP} cron event list | ${GREP} -v "hook" | ${WC} -l`"

# Check transient variable
echo -e "
Transient varibles: `${WP} option list | ${GREP} "_site\|_trans" | wc -l`"

# Check memory usage
echo -e "
Memory Usage `${WP} eval "echo round( memory_get_usage() / 1048576, 2 );"` MB"

# Check MySQL query status
echo -e "
MySQL queries running on the server"
${MYSQL} -uroot -e "show processlist;"
