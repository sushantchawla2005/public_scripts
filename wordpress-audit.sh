#!/bin/bash
# Author: Sushant Chawla & Afraz Ahmed
# Description: Optimized WordPress Audit Script for Multisite (Runs Core Checks Once, Autoload Check for Each)

###################
# Global Variables
###################

# Initialize WP-CLI
if [ "$(id -u)" -eq 0 ]; then
    WP="/usr/local/bin/wp --allow-root --skip-themes --skip-plugins"
else
    WP="/usr/local/bin/wp --skip-themes --skip-plugins"
fi

# Initialize Timeout and Utility Variables
GREP="/bin/grep"
WC="/usr/bin/wc"
MYSQL="/usr/bin/mysql"
TIMEOUT="/usr/bin/timeout 10"
COLORCODE_CYAN="\e[36m"
COLORCODE_RED="\e[31m"
COLORCODE_GREEN="\e[32m"
COLORCODE_ORANGE="\e[38;5;214m"
COLORCODE_RESET="\e[0m"

# Check if site is WordPress Multisite
IS_MULTISITE=$(${WP} config get MULTISITE --quiet 2> /dev/null)

# Store Primary Site (Main URL)
PRIMARY_SITE=$(${WP} option get siteurl)
FIRST_RUN=true  # Flag to ensure some checks only run once

# Function to Run Audit Checks
run_audit() {
    local SITE_URL=$1
    echo -e "\n${COLORCODE_CYAN}🔍 Auditing WordPress Site: ${COLORCODE_RESET}${SITE_URL}"

    # Run Core Checks Only for First Site (Primary Site)
    if [[ "$FIRST_RUN" == "true" ]]; then
        # Get WordPress version
        CURRENT_VERSION=$(${TIMEOUT} ${WP} --url=${SITE_URL} core version 2>/dev/null)
        LATEST_VERSION=$(${TIMEOUT} ${WP} core version --extra 2>/dev/null | ${GREP} -oP 'Latest: \K[^\s]+')

        if [ -z "$LATEST_VERSION" ]; then
            LATEST_VERSION=$(${TIMEOUT} curl -s https://api.wordpress.org/core/version-check/1.7/ | ${GREP} -oP '"version":"\K[0-9.]+' | head -1)
        fi

        echo -e "${COLORCODE_CYAN}Current Version: ${COLORCODE_RESET}${CURRENT_VERSION} | ${COLORCODE_CYAN}Latest Version: ${COLORCODE_RESET}${LATEST_VERSION}"

        if [ "$CURRENT_VERSION" != "$LATEST_VERSION" ]; then
            echo -e "${COLORCODE_RED}Outdated WordPress version detected!${COLORCODE_RESET}"
        else
            echo -e "${COLORCODE_GREEN}WordPress is up-to-date.${COLORCODE_RESET}"
        fi

        echo -e " "
        # Verify checksum
        echo -e "${COLORCODE_CYAN}== WordPress checksum verification result ==${COLORCODE_RESET}"
        CHECKSUM_OUTPUT=$(${TIMEOUT} ${WP} --url=${SITE_URL} core verify-checksums 2>&1)

        if echo "$CHECKSUM_OUTPUT" | ${GREP} -q "Error: WordPress installation doesn't verify against checksums"; then
            echo -e "${COLORCODE_RED}$CHECKSUM_OUTPUT${COLORCODE_RESET}"
        else
            echo -e "${COLORCODE_GREEN}$CHECKSUM_OUTPUT${COLORCODE_RESET}"
        fi

        # Check Plugin Status
        echo -e "
${COLORCODE_CYAN} == Plugins Status ==${COLORCODE_RESET}"
        TOTAL_PLUGINS=$(${TIMEOUT} ${WP} --url=${SITE_URL} plugin list --format=count 2>/dev/null)
        echo -e "${COLORCODE_CYAN}Total Plugins Installed: ${COLORCODE_RESET}${TOTAL_PLUGINS}"

        PLUGINS_TO_UPDATE=$(${TIMEOUT} ${WP} --url=${SITE_URL} plugin status | ${GREP} -E 'UA|UN|UI' 2> /dev/null)
        if [ -n "$PLUGINS_TO_UPDATE" ]; then
            echo -e "
${COLORCODE_ORANGE} == Plugins Available for Update ==${COLORCODE_RESET}"
            echo -e "$PLUGINS_TO_UPDATE"
        else
            echo -e "${COLORCODE_GREEN}✅ All Plugins are Up-to-Date.${COLORCODE_RESET}"
        fi

	# Check Theme status
	echo -e "
${COLORCODE_CYAN}== Themes Status ==${COLORCODE_RESET}"
	${TIMEOUT} ${WP} --url=${SITE_URL} theme status 2> /dev/null

	# Check Database Size
        echo -e "
${COLORCODE_CYAN}== Database size of application: ==${COLORCODE_RESET}"
        ${TIMEOUT} ${WP} --url=${SITE_URL} db size --human-readable 2> /dev/null

        # Check Memory Usage
        echo -e "
${COLORCODE_CYAN} Memory Usage ${COLORCODE_RESET} ` ${TIMEOUT} ${WP} --url=${SITE_URL} eval "echo round( memory_get_usage() / 1048576, 2 );" 2> /dev/null` MB"
        FIRST_RUN=false  # Disable further runs for core checks
    fi

    # Check Autoloaded Options Size (Runs for Every Site)
    PREFIX=$(${TIMEOUT} ${WP} --url=${SITE_URL} db prefix)
    AUTOLOAD_SIZE=$(${TIMEOUT} ${WP} --url=${SITE_URL} db query "SELECT ROUND(SUM(LENGTH(option_value))/1024) FROM ${PREFIX}options WHERE autoload='yes';" --skip-column-names --raw 2> /dev/null)

    if [[ -z "$AUTOLOAD_SIZE" || "$AUTOLOAD_SIZE" == "NULL" ]]; then
        AUTOLOAD_SIZE=0
    fi

    echo -e "
${COLORCODE_CYAN} Autoloaded options size: ${COLORCODE_RESET} ${AUTOLOAD_SIZE} KB"

    if [ "$AUTOLOAD_SIZE" -gt 1024 ]; then
        echo -e "${COLORCODE_RED}⚠️ Autoloaded options exceed 1MB. Consider optimizing!${COLORCODE_RESET}"
    fi

    sleep 1
    # Check Cron status
    echo -e "
${COLORCODE_CYAN} Cron Status:${COLORCODE_RESET} `${TIMEOUT} ${WP} --url=${SITE_URL} cron event list 2> /dev/null | ${GREP} -v "hook" | ${WC} -l`"

    # Check Transient variables
    echo -e "
${COLORCODE_CYAN} Transient variables:${COLORCODE_RESET} `${TIMEOUT} ${WP} --url=${SITE_URL} transient list 2> /dev/null | wc -l`"

}

# Run audit checks for Multisite
if [[ "$IS_MULTISITE" == "1" ]]; then
    echo -e "${COLORCODE_CYAN}🔄 Multisite detected. Running checks for all subsites...${COLORCODE_RESET}"
    SITE_LIST=$(${WP} site list --field=url)

    for SITE in ${SITE_LIST}; do
        run_audit "${SITE}"
    done
else
    echo -e "${COLORCODE_CYAN}🔹 No WordPress Multisite detected.${COLORCODE_RESET}"
    run_audit "$PRIMARY_SITE"
fi

# 404 error check
echo -e "
${COLORCODE_CYAN}== Checking 404 errors count/ratio for today and yesterday: ==${COLORCODE_RESET}"
curl -H 'Cache-Control: no-cache' -s https://raw.githubusercontent.com/sushantchawla2005/public_scripts/refs/heads/main/check-404-responses.sh | bash -s 10 ../logs

# Run Vulnerability Check and Slow Plugin Check (Only on Primary Site)
echo -e "
${COLORCODE_ORANGE}🐢 Running Slow Plugin & Vulnerability Checks on Primary Site: ${COLORCODE_RESET}${PRIMARY_SITE}"

# Run vulnerability check
echo -e ""
read -p "Do you want to run the vulnerability check script? (y/n): " choice <&1
if [ "$choice" == "y" ]; then
    curl -H 'Cache-Control: no-cache' -s https://raw.githubusercontent.com/sushantchawla2005/public_scripts/refs/heads/main/check-vulnerability.sh | bash
fi

# Image Optimization
echo -e ""
read -p "Do you want to run image optimization in current folder, it will use tools like oxipng and jpegoptim to optimize images? (y/n): " choice <&1
if [ "$choice" == "y" ]; then
    curl -H 'Cache-Control: no-cache' -s https://raw.githubusercontent.com/sushantchawla2005/public_scripts/refs/heads/main/optimize-images.sh | bash
fi

# Slow Plugins Check (Only on primary site)
echo -e "
${COLORCODE_CYAN}== Slow Plugins List: ==${COLORCODE_RESET}"
curl -H 'Cache-Control: no-cache' -s https://raw.githubusercontent.com/aphraz/cloudways/master/plugin-perf.sh | bash
