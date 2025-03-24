#!/bin/bash

# Usage help
if [ "$#" -eq 0 ]; then
    echo "Usage: $0 US CA IN PK"
    echo "Pass the list of allowed country codes as arguments (ISO Alpha-2 codes)"
    exit 1
fi

# Allowed countries from user input
ALLOWED=("$@")

# Convert ALLOWED to uppercase to avoid mismatch
for i in "${!ALLOWED[@]}"; do
    ALLOWED[$i]=$(echo "${ALLOWED[$i]}" | tr '[:lower:]' '[:upper:]')
done

# All ISO country codes (ISO Alpha-2)
ALL_COUNTRIES=(AF AL DZ AS AD AO AI AQ AG AR AM AW AU AT AZ BS BH BD BB BY BE BZ BJ BM BT BO BQ BA BW BV BR IO BN BG BF BI KH CM CA CV KY CF TD CL CN CX CC CO KM CG CD CK CR CI HR CU CW CY CZ DK DJ DM DO EC EG SV GQ ER EE ET FK FO FJ FI FR GF PF TF GA GM GE DE GH GI GR GL GD GP GU GT GG GN GW GY HT HM VA HN HK HU IS IN ID IR IQ IE IM IL IT JM JP JE JO KZ KE KI KP KR KW KG LA LV LB LS LR LY LI LT LU MO MG MW MY MV ML MT MH MQ MR MU YT MX FM MD MC MN ME MS MA MZ MM NA NR NP NL NC NZ NI NE NG NU NF MK MP NO OM PK PW PS PA PG PY PE PH PN PL PT PR QA RE RO RU RW BL SH KN LC MF PM VC WS SM ST SA SN RS SC SL SG SX SK SI SB SO ZA GS SS ES LK SD SR SJ SE CH SY TW TJ TZ TH TL TG TK TO TT TN TR TM TC TV UG UA AE GB US UM UY UZ VU VE VN VG VI WF EH YE ZM ZW)

echo "⚙️ Whitelisting allowed countries: ${ALLOWED[*]}..."

# Whitelist allowed countries (skip if already whitelisted)
for country in "${ALLOWED[@]}"; do
    echo "✅ Whitelisting: $country"
    imunify360-agent whitelist country add "$country"
done

# Fetch currently whitelisted countries
EXISTING_WHITELIST=($(imunify360-agent whitelist country list 2>/dev/null | awk '{print $1}' | sort | uniq))

# Blacklist others
echo "🚫 Blacklisting all countries except allowed and existing whitelisted ones..."
for country in "${ALL_COUNTRIES[@]}"; do
    # Skip if country is in allowed or already whitelisted
    if [[ " ${ALLOWED[*]} " =~ " ${country} " || " ${EXISTING_WHITELIST[*]} " =~ " ${country} " ]]; then
        echo "✅ Skipping $country (allowed or already whitelisted)"
    else
        echo "🚫 Blacklisting: $country"
        imunify360-agent blacklist country add "$country"
    fi
done

# Reload firewall rules
echo "== Reloading firewall rules =="
imunify360-agent reload-lists

echo "Done. Only ${ALLOWED[*]} are allowed. All others blocked (except existing whitelist)."
