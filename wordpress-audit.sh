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
    PREFIX=$(${WP} db prefix)
fi

GREP="/bin/grep"
WC="/usr/bin/wc"
MYSQL="/usr/bin/mysql"
TIMEOUT="/usr/bin/timeout 10"
COLORCODE_CYAN="\e[36m"
COLORCODE_RED="\e[31m"
COLORCODE_GREEN="\e[32m"
COLORCODE_ORANGE="\e[38;5;214m"
COLORCODE_RESET="\e[0m"

echo -e " "
# Check wordpress version
# Get current WordPress version
CURRENT_VERSION=$(${TIMEOUT} ${WP} core version 2>/dev/null)

# Get the latest WordPress version from WordPress.org using WP-CLI
LATEST_VERSION=$(${TIMEOUT} ${WP} core version --extra 2>/dev/null | grep -oP 'Latest: \K[^\s]+')

# Fallback to API if WP-CLI fails to retrieve the latest version
if [ -z "$LATEST_VERSION" ]; then
    LATEST_VERSION=$(${TIMEOUT} curl -s https://api.wordpress.org/core/version-check/1.7/ | grep -oP '"version":"\K[0-9.]+' | head -1)
fi

# Output the versions
echo -e " "
if [ -n "$CURRENT_VERSION" ] && [ -n "$LATEST_VERSION" ]; then
    echo -e "${COLORCODE_CYAN}Current Version: ${COLORCODE_RESET}${CURRENT_VERSION} | ${COLORCODE_CYAN}Latest Version: ${COLORCODE_RESET}${LATEST_VERSION}"

    # Check if WordPress is outdated
    if [ "$CURRENT_VERSION" != "$LATEST_VERSION" ]; then
        echo -e "${COLORCODE_RED}Outdated WordPress version detected!${COLORCODE_RESET}"
    else
        echo -e "${COLORCODE_GREEN}WordPress is up-to-date.${COLORCODE_RESET}"
    fi
else
    echo -e "${COLORCODE_RED}Error: Unable to retrieve WordPress version information.${COLORCODE_RESET}"
fi

echo -e " "
# Verify checksum
echo -e "${COLORCODE_CYAN}== Wordpress checksum verification result ==${COLORCODE_RESET}"
${TIMEOUT} ${WP} core verify-checksums 2> /dev/null

sleep 1
# Check plugin status
echo -e "
${COLORCODE_CYAN} == Plugins Status ==${COLORCODE_RESET}"
${TIMEOUT} ${WP} plugin status --no-color 2> /dev/null

# Check plugins using most admin-ajax.php file
echo -e "
${COLORCODE_ORANGE} == Plugins using most admin-ajax.php calls ==${COLORCODE_RESET}"
grep -Rinl "add_action('wp_ajax_" wp-content/plugins/* | awk -F'/' '{print $3}'  | sort | uniq -c | sort -nr
echo -e "-------------------------------------------------------------"

# Check Theme status
echo -e "
${COLORCODE_CYAN}== Themes Status ==${COLORCODE_RESET}"
${TIMEOUT} ${WP} theme status --no-color 2> /dev/null

echo -e "
${COLORCODE_ORANGE}== Themes using most admin-ajax.php calls ==${COLORCODE_RESET}"
grep -Rinl "add_action('wp_ajax_" wp-content/themes/* | awk -F'/' '{print $3}'  | sort | uniq -c | sort -nr

sleep 2
echo -e "-------------------------------------------------------------"
# Check Cron status
echo -e "
${COLORCODE_CYAN} Cron Status:${COLORCODE_RESET} `${TIMEOUT} ${WP} cron event list 2> /dev/null | ${GREP} -v "hook" | ${WC} -l`"

# Check transient variable
echo -e "
${COLORCODE_CYAN} Transient varibles:${COLORCODE_RESET} `${TIMEOUT} ${WP} transient list 2> /dev/null | wc -l`"

# Check memory usage
echo -e "
${COLORCODE_CYAN} Memory Usage ${COLORCODE_RESET} ` ${TIMEOUT} ${WP} eval "echo round( memory_get_usage() / 1048576, 2 );" 2> /dev/null` MB"

sleep 1
# Application's database size
echo -e "
${COLORCODE_CYAN}== Database size of application: ==${COLORCODE_RESET}"
${TIMEOUT} ${WP} db size --human-readable 2> /dev/null

# Check Autoloaded options size
echo -e "
${COLORCODE_CYAN}== Autoloaded options size: ==${COLORCODE_RESET}"
${TIMEOUT} ${WP} db query "SELECT 'autoloaded data in KiB' as name, ROUND(SUM(LENGTH(option_value))/ 1024) as value FROM ${PREFIX}options WHERE autoload='yes' UNION SELECT 'autoloaded data count', count(*) FROM ${PREFIX}options WHERE autoload='yes' UNION (SELECT option_name, length(option_value) FROM ${PREFIX}options WHERE autoload='yes' ORDER BY length(option_value) DESC LIMIT 5);" 2> /dev/null

AUTOLOAD_SIZE=$(${TIMEOUT} ${WP} db query "SELECT ROUND(SUM(LENGTH(option_value))/1024) AS autoloaded_size_kb FROM ${PREFIX}options WHERE autoload='yes';" --skip-column-names --raw 2> /dev/null)
# Check if AUTOLOAD_SIZE is empty or NULL
if [[ -z "$AUTOLOAD_SIZE" || "$AUTOLOAD_SIZE" == "NULL" ]]; then
    AUTOLOAD_SIZE=0
fi

if [ "$AUTOLOAD_SIZE" -gt 1024 ]; then
    echo -e "${COLORCODE_RED}Autoloaded options size ${AUTOLOAD_SIZE} KB exceeds 1 MB, please consider trimming it below 1 MB for best performance.${COLORCODE_RESET}"
fi

# Run vulnerability check script
echo -e ""
read -p "Do you want to run Vulnerability check script? This may take some time (y/n): " choice <&1

	if [ "$choice" == "y" ]; then
		# Check if jq is installed, if not install it
		check_jq() {
    		if ! command -v jq &> /dev/null; then
        		echo -e "${COLORCODE_RED}jq package is not installed. Please install jq package and re-run this script.${COLORCODE_RESET}"
            		echo -e "${COLORCODE_RED}On Debian/Ubuntu based servers command should be: sudo apt update && sudo apt install -y jq${COLORCODE_RESET}"
			echo -e "${COLORCODE_RED}On Redhat based servers command should be: sudo yum install -y jq${COLORCODE_RESET}"
        	else
        		curl -H 'Cache-Control: no-cache' -s https://raw.githubusercontent.com/sushantchawla2005/public_scripts/refs/heads/main/check-vulnerability.sh | bash
        	fi
		}
		# Call the function to check for jq package
		check_jq
	fi

# Report slow plugins
echo -e "
${COLORCODE_CYAN}== Slow Plugins List: ==${COLORCODE_RESET}"
curl -H 'Cache-Control: no-cache' -s https://raw.githubusercontent.com/aphraz/cloudways/master/plugin-perf.sh | bash
