#!/bin/bash
# Author: Sushant Chawla & Afraz Ahmed
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
COLORCODE_CYAN="\e[36m"
COLORCODE_RED="\e[31m"
COLORCODE_GREEN="\e[32m"

echo -e " "
# Check wordpress version
echo -e "${COLORCODE_CYAN} Your Current Wordpress Version is: \e[0m `${WP} core version 2> /dev/null`"

echo -e " "
# Verify checksum
echo -e "${COLORCODE_CYAN} == Wordpress checksum verification result == \e[0m"
${WP} core verify-checksums 2> /dev/null

sleep 1
# Check plugin status
echo -e "
${COLORCODE_CYAN} == Plugins Status ==\e[0m"
${WP} plugin status --no-color 2> /dev/null

# Check Theme status
echo -e "
${COLORCODE_CYAN} == Themes Status == \e[0m"
${WP} theme status --no-color 2> /dev/null

sleep 2

# Check Cron status
echo -e "
${COLORCODE_CYAN} Cron Status: \e[0m`${WP} cron event list 2> /dev/null | ${GREP} -v "hook" | ${WC} -l`"

# Check transient variable
echo -e "
${COLORCODE_CYAN} Transient varibles: \e[0m`${WP} transient list 2> /dev/null | wc -l`"

# Check memory usage
echo -e "
${COLORCODE_CYAN} Memory Usage \e[0m`${WP} eval "echo round( memory_get_usage() / 1048576, 2 );" 2> /dev/null` MB"

# Application's database size
echo -e "
${COLORCODE_CYAN} == Database size of application: == \e[0m"
${WP} db size --human-readable 2> /dev/null

# Check Autoloaded options size
echo -e "
${COLORCODE_CYAN} == Autoloaded options size: == \e[0m"
${WP} db query "SELECT 'autoloaded data in KiB' as name, ROUND(SUM(LENGTH(option_value))/ 1024) as value FROM ${PREFIX}options WHERE autoload='yes' UNION SELECT 'autoloaded data count', count(*) FROM ${PREFIX}options WHERE autoload='yes' UNION (SELECT option_name, length(option_value) FROM ${PREFIX}options WHERE autoload='yes' ORDER BY length(option_value) DESC LIMIT 5);" 2> /dev/null

# Run vulnerability check script
echo -e ""
read -p "Do you want to run Vulnerability check script? This may take some time (y/n): " choice <&1

	if [ "$choice" == "y" ]; then
		# Check if jq is installed, if not install it
		check_jq() {
    		if ! command -v jq &> /dev/null; then
        		echo -e "${COLORCODE_RED}jq package is not installed. Please install jq package and re-run this script.\e[0m"
            		echo -e "${COLORCODE_RED}On Debian/Ubuntu based servers command should be: sudo apt update && sudo apt install -y jq\e[0m"
			echo -e "${COLORCODE_RED}On Redhat based servers command should be: sudo yum install -y jq\e[0m"
        	else
        		echo -e "\e[32mjq is already installed.\e[0m"
        		curl -s https://raw.githubusercontent.com/sushantchawla2005/public_scripts/refs/heads/main/check-vulnerability.sh | bash
        	fi
		}
		# Call the function to check for jq package
		check_jq
	fi

# Report slow plugins
echo -e "
${COLORCODE_CYAN} == Slow Plugins List: ==\e[0m"
curl -s https://raw.githubusercontent.com/aphraz/cloudways/master/plugin-perf.sh | bash
