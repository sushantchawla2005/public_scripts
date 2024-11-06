#!/bin/bash
# Author: Sushant Chawla
# Description: Script to quickly audit a wordpress site
###################
# Global Variables
###################

# Initialize WP-CLI
if [ "$(id -u)" -eq 0 ]; then
    WP="/usr/local/bin/wp --allow-root --skip-themes --skip-plugins"
else
    WP="/usr/local/bin/wp --skip-themes --skip-plugins"
fi

# Initialize Wordpress DB table prefix
if [ -f ./wp-config.php ]; then
    PREFIX=$(grep "table_prefix" ./wp-config.php | awk '{print $3}' | tr -d \'\;)
else
    PREFIX=$(wp db prefix)
fi

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
Transient varibles: `${WP} transient list | wc -l`"

# Check memory usage
echo -e "
Memory Usage `${WP} eval "echo round( memory_get_usage() / 1048576, 2 );"` MB"


# Check Autoloaded options size
echo -e "
Autoloaded options size"
${WP} db query "SELECT 'autoloaded data in KiB' as name, ROUND(SUM(LENGTH(option_value))/ 1024) as value FROM ${PREFIX}options WHERE autoload='yes' UNION SELECT 'autoloaded data count', count(*) FROM ${PREFIX}options WHERE autoload='yes' UNION (SELECT option_name, length(option_value) FROM ${PREFIX}options WHERE autoload='yes' ORDER BY length(option_value) DESC LIMIT 10);"

# Report slow plugins
echo -e "
Slow Plugins List:"
curl -s https://raw.githubusercontent.com/aphraz/cloudways/master/plugin-perf.sh | bash
