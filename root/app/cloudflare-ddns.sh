#!/usr/bin/with-contenv bash
# shellcheck shell=bash

###############
## FUNCTIONS ##
###############

curl_header() {
    if [[ -n ${CF_APITOKEN_ZONE} ]] && [[ $* != *dns_records* ]]; then
        curl -s -H "Accept: application/json" -H "Content-Type: application/json" -H "Authorization: Bearer ${CF_APITOKEN_ZONE}" "$@"
    elif [[ -n ${CF_APITOKEN} ]]; then
        curl -s -H "Accept: application/json" -H "Content-Type: application/json" -H "Authorization: Bearer ${CF_APITOKEN}" "$@"
    else
        curl -s -H "Accept: application/json" -H "Content-Type: application/json" -H "X-Auth-Email: ${CF_USER}" -H "X-Auth-Key: ${CF_APIKEY}" "$@"
    fi
}
auth_log() {
    if [[ -n ${CF_APITOKEN_ZONE} ]] && [[ $* != *DNS* ]]; then
        [[ ${LOG_LEVEL} -gt 2 ]] && echo -e "$(date +'%Y-%m-%d %H:%M:%S') - [${DETECTION_MODE}] - [${host}] - [${type}] -" "$@" "- Using [CF_APITOKEN_ZONE=${BMAGENTA}${CF_APITOKEN_ZONE}${NC}] to authenticate..."
    elif [[ -n ${CF_APITOKEN} ]]; then
        [[ ${LOG_LEVEL} -gt 2 ]] && echo -e "$(date +'%Y-%m-%d %H:%M:%S') - [${DETECTION_MODE}] - [${host}] - [${type}] -" "$@" "- Using [CF_APITOKEN=${BMAGENTA}${CF_APITOKEN}${NC}] to authenticate..."
    else
        [[ ${LOG_LEVEL} -gt 2 ]] && echo -e "$(date +'%Y-%m-%d %H:%M:%S') - [${DETECTION_MODE}] - [${host}] - [${type}] -" "$@" "- Using [CF_USER=${BMAGENTA}${CF_USER}${NC} & CF_APIKEY=${BMAGENTA}${CF_APIKEY}${NC}] to authenticate..."
    fi
}
verbose_debug_log() {
    [[ ${LOG_LEVEL} -gt 3 ]] && echo -e "$(date +'%Y-%m-%d %H:%M:%S') - [${DETECTION_MODE}] - [${host}] - [${type}] -" "$@"
}
debug_log() {
    [[ ${LOG_LEVEL} -gt 2 ]] && echo -e "$(date +'%Y-%m-%d %H:%M:%S') - [${DETECTION_MODE}] - [${host}] - [${type}] -" "$@"
}
verbose_log() {
    [[ ${LOG_LEVEL} -gt 1 ]] && echo -e "$(date +'%Y-%m-%d %H:%M:%S') - [${DETECTION_MODE}] - [${host}] - [${type}] -" "$@"
}
log() {
    [[ ${LOG_LEVEL} -gt 0 ]] && echo -e "$(date +'%Y-%m-%d %H:%M:%S') - [${DETECTION_MODE}] - [${host}] - [${type}] -" "$@"
}

#############
## STARTUP ##
#############

# SET COLORS
RED='\e[31m'
BMAGENTA='\e[45m'
GREEN='\e[32m'
YELLOW='\e[33m'
NC='\e[0m'

# SET REGEX
regexv4='^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'
regexv6='^([0-9a-fA-F]{0,4}:){1,7}[0-9a-fA-F]{0,4}$'

# SET DEFAULTS
CHECK_IPV4="${CHECK_IPV4:-true}"
CHECK_IPV6="${CHECK_IPV6:-false}"
INTERVAL="${INTERVAL:-300}"
DETECTION_MODE="${DETECTION_MODE:-dig-whoami.cloudflare}"
LOG_LEVEL="${LOG_LEVEL:-3}"
INFLUXDB_ENABLED="${INFLUXDB_ENABLED:-false}"
INFLUXDB_HOST="${INFLUXDB_HOST:-http://127.0.0.1:8086}"
INFLUXDB_DB="${INFLUXDB_DB:-cloudflare_ddns}"

# READ IN VALUES
DEFAULTIFS="${IFS}"
IFS=';'
read -r -a cfhost <<< "${CF_HOSTS}"
read -r -a cfzone <<< "${CF_ZONES}"
read -r -a cftype <<< "${CF_RECORDTYPES}"
IFS="${DEFAULTIFS}"

# SETUP CACHE
if [[ -z $1 ]]; then
    cache_location="/dev/shm"
else
    cache_location="$1"
fi
rm -f "${cache_location}"/*.cache

###################################
## CREATE INFLUXDB DB IF ENABLED ##
###################################

if [[ ${INFLUXDB_ENABLED} == "true" ]]; then
    if result=$(curl -fsSL -XPOST "${INFLUXDB_HOST}/query" -u "${INFLUXDB_USER}:${INFLUXDB_PASS}" --data-urlencode "q=SHOW DATABASES"); then
        [[ ${LOG_LEVEL} -gt 0 ]] && echo "$(date +'%Y-%m-%d %H:%M:%S') - Connection to [${INFLUXDB_HOST}] succeeded!"
        if echo "${result}" | jq -erc ".results[].series[].values[] | select(. == [\"${INFLUXDB_DB}\"])" > /dev/null; then
            [[ ${LOG_LEVEL} -gt 0 ]] && echo "$(date +'%Y-%m-%d %H:%M:%S') - Database [${INFLUXDB_DB}] found!"
        else
            [[ ${LOG_LEVEL} -gt 0 ]] && echo "$(date +'%Y-%m-%d %H:%M:%S') - Database [${INFLUXDB_DB}] not found! Creating database..."
            curl -fsSL -XPOST "${INFLUXDB_HOST}/query" -u "${INFLUXDB_USER}:${INFLUXDB_PASS}" --data-urlencode "q=CREATE DATABASE ${INFLUXDB_DB}" > /dev/null
            [[ ${LOG_LEVEL} -gt 0 ]] && echo "$(date +'%Y-%m-%d %H:%M:%S') - Adding sample data..."
            curl -fsSL -XPOST "${INFLUXDB_HOST}/write?db=${INFLUXDB_DB}" -u "${INFLUXDB_USER}:${INFLUXDB_PASS}" --data-binary "domains,host=sample-generator,domain=ipv4.cloudflare.com,recordtype=A ip=\"1.1.1.1\""
            curl -fsSL -XPOST "${INFLUXDB_HOST}/write?db=${INFLUXDB_DB}" -u "${INFLUXDB_USER}:${INFLUXDB_PASS}" --data-binary "domains,host=sample-generator,domain=ipv6.cloudflare.com,recordtype=AAAA ip=\"2606:4700:4700::1111\""
        fi
    fi
fi

#################
## UPDATE LOOP ##
#################

while true; do

    ## CHECK FOR NEW IP ##
    newipv4="disabled"
    newipv6="disabled"
    [[ ${LOG_LEVEL} -gt 2 ]] && echo "$(date +'%Y-%m-%d %H:%M:%S') - Trying to get IP..."
    case "${DETECTION_MODE}" in
        dig-google.com)
            [[ ${CHECK_IPV4} == "true" ]] && newipv4=$(dig -4 TXT +short o-o.myaddr.l.google.com @ns1.google.com | tr -d '"')
            [[ ${CHECK_IPV6} == "true" ]] && newipv6=$(dig -6 TXT +short o-o.myaddr.l.google.com @ns1.google.com | tr -d '"')
            ;;
        dig-opendns.com)
            [[ ${CHECK_IPV4} == "true" ]] && newipv4=$(dig -4 A +short myip.opendns.com @resolver1.opendns.com)
            [[ ${CHECK_IPV6} == "true" ]] && newipv6=$(dig -6 AAAA +short myip.opendns.com @resolver1.opendns.com)
            ;;
        dig-whoami.cloudflare)
            [[ ${CHECK_IPV4} == "true" ]] && newipv4=$(dig -4 TXT +short whoami.cloudflare @1.1.1.1 ch | tr -d '"')
            [[ ${CHECK_IPV6} == "true" ]] && newipv6=$(dig -6 TXT +short whoami.cloudflare @2606:4700:4700::1111 ch | tr -d '"')
            ;;
        curl-icanhazip.com)
            [[ ${CHECK_IPV4} == "true" ]] && newipv4=$(curl -fsL -4 icanhazip.com)
            [[ ${CHECK_IPV6} == "true" ]] && newipv6=$(curl -fsL -6 icanhazip.com)
            ;;
        curl-wtfismyip.com)
            [[ ${CHECK_IPV4} == "true" ]] && newipv4=$(curl -fsL -4 wtfismyip.com/text)
            [[ ${CHECK_IPV6} == "true" ]] && newipv6=$(curl -fsL -6 wtfismyip.com/text)
            ;;
        curl-showmyip.ca)
            [[ ${CHECK_IPV4} == "true" ]] && newipv4=$(curl -fsL -4 showmyip.ca/ip.php)
            [[ ${CHECK_IPV6} == "true" ]] && newipv6=$(curl -fsL -6 showmyip.ca/ip.php)
            ;;
        curl-da.gd)
            [[ ${CHECK_IPV4} == "true" ]] && newipv4=$(curl -fsL -4 da.gd/ip)
            [[ ${CHECK_IPV6} == "true" ]] && newipv6=$(curl -fsL -6 da.gd/ip)
            ;;
        curl-seeip.org)
            [[ ${CHECK_IPV4} == "true" ]] && newipv4=$(curl -fsL -4 ip.seeip.org)
            [[ ${CHECK_IPV6} == "true" ]] && newipv6=$(curl -fsL -6 ip.seeip.org)
            ;;
        curl-ifconfig.co)
            [[ ${CHECK_IPV4} == "true" ]] && newipv4=$(curl -fsL -4 ifconfig.co)
            [[ ${CHECK_IPV6} == "true" ]] && newipv6=$(curl -fsL -6 ifconfig.co)
            ;;
    esac
    [[ ${LOG_LEVEL} -gt 2 ]] && echo "$(date +'%Y-%m-%d %H:%M:%S') - IPv4 is: [$newipv4]"
    [[ ${LOG_LEVEL} -gt 2 ]] && echo "$(date +'%Y-%m-%d %H:%M:%S') - IPv6 is: [$newipv6]"

    ## LOG CONNECTION STATUS TO INFLUXDB IF ENABLED ##
    if [[ ${INFLUXDB_ENABLED} == "true" ]]; then
        [[ ${LOG_LEVEL} -gt 2 ]] && echo "$(date +'%Y-%m-%d %H:%M:%S') - Writing connection status to InfluxDB..."
        if [[ $newipv4 =~ $regexv4 ]]; then
            curl -fsSL -XPOST "${INFLUXDB_HOST}/write?db=${INFLUXDB_DB}" -u "${INFLUXDB_USER}:${INFLUXDB_PASS}" --data-binary "connection,host=$(hostname),type=ipv4 status=1,ip=\"$newipv4\""
        else
            curl -fsSL -XPOST "${INFLUXDB_HOST}/write?db=${INFLUXDB_DB}" -u "${INFLUXDB_USER}:${INFLUXDB_PASS}" --data-binary "connection,host=$(hostname),type=ipv4 status=0,ip=\"no ipv4\""
        fi

        if [[ $newipv6 =~ $regexv6 ]]; then
            curl -fsSL -XPOST "${INFLUXDB_HOST}/write?db=${INFLUXDB_DB}" -u "${INFLUXDB_USER}:${INFLUXDB_PASS}" --data-binary "connection,host=$(hostname),type=ipv6 status=1,ip=\"$newipv6\""
        else
            curl -fsSL -XPOST "${INFLUXDB_HOST}/write?db=${INFLUXDB_DB}" -u "${INFLUXDB_USER}:${INFLUXDB_PASS}" --data-binary "connection,host=$(hostname),type=ipv6 status=0,ip=\"no ipv6\""
        fi
    fi

    ## UPDATE DOMAINS ##
    for index in ${!cfhost[*]}; do

        host=${cfhost[$index]}

        if [[ -n ${cftype[$index]} ]]; then
            type=${cftype[$index]}
        elif [[ -z ${type} ]]; then
            type="A"
            log "${YELLOW}No value was found in [CF_RECORDTYPES] for host [${host}], also no previous value was found, the default [A] is used instead.${NC}"
        else
            log "${YELLOW}No value was found in [CF_RECORDTYPES] for host [${host}], the previous value [${type}] is used instead.${NC}"
        fi

        cache="${cache_location}/cf-ddns-${host}-${type}.cache"

        case "${type}" in
            A)
                regex="${regexv4}"
                newip="${newipv4}"
                ;;
            AAAA)
                regex="${regexv6}"
                newip="${newipv6}"
                ;;
        esac

        if ! [[ $newip =~ $regex ]]; then
            log "${RED}Returned IP [${newip}] by [${DETECTION_MODE}] is not valid for an [${type}] record! Check your connection.${NC}"
        else

            if [[ -n ${cfzone[$index]} ]]; then
                zone=${cfzone[$index]}
            elif [[ -z ${zone} ]]; then
                log "${RED}No value was found in [CF_ZONES] for host [${host}], also no previous value was found, can't do anything until you fix this!${NC}"
            else
                log "${YELLOW}No value was found in [CF_ZONES] for host [${host}], the previous value [${zone}] is used instead.${NC}"
            fi

            ##################################################
            ## Try getting the DNS records                  ##
            ##################################################
            if [[ ! -f "$cache" ]]; then

                ## Try getting the Zone ID ##
                zoneid=""
                dnsrecords=""
                if [[ ${zone} == *.* ]]; then
                    auth_log "Reading zone list from [Cloudflare]"
                    response=$(curl_header -X GET "https://api.cloudflare.com/client/v4/zones")
                    if [[ $(echo "${response}" | jq -r .success) == false ]]; then
                        log "${RED}Error response from [Cloudflare]:\n$(echo "${response}" | jq .)${NC}"
                    else
                        debug_log "Retrieved zone list from [Cloudflare]"
                        verbose_debug_log "${YELLOW}Response from [Cloudflare]:\n$(echo "${response}" | jq .)${NC}"
                        zoneid=$(echo "${response}" | jq -r '.result[] | select (.name == "'"${zone}"'") | .id')
                        if [[ -n ${zoneid} ]]; then
                            debug_log "Zone ID returned by [Cloudflare] for zone [${zone}] is: $zoneid"
                        else
                            log "${RED}Something went wrong trying to find the Zone ID of [${zone}] in the zone list!${NC}"
                        fi
                    fi
                elif [[ -n ${zone} ]]; then
                    zoneid=${zone} && debug_log "Zone ID supplied by [CF_ZONES] is: $zoneid"
                fi

                ## Try getting the DNS records from Cloudflare ##
                if [[ -n $zoneid ]]; then
                    auth_log "Reading DNS records from [Cloudflare]"
                    response=$(curl_header -X GET "https://api.cloudflare.com/client/v4/zones/$zoneid/dns_records")
                    if [[ $(echo "${response}" | jq -r .success) == false ]]; then
                        log "${RED}Error response from [Cloudflare]:\n$(echo "${response}" | jq .)${NC}"
                    else
                        verbose_debug_log "${YELLOW}Response from [Cloudflare]:\n$(echo "${response}" | jq .)${NC}"
                        dnsrecords=$(echo "${response}" | jq -r '.result[] | {name, id, zone_id, zone_name, content, type, proxied, ttl} | select (.name == "'"${host}"'") | select (.type == "'"${type}"'")')
                        if [[ -n ${dnsrecords} ]]; then
                            echo "$dnsrecords" > "$cache" && debug_log "Wrote DNS records to cache file: $cache" && verbose_debug_log "${YELLOW}Data written to cache:\n$(echo "${dnsrecords}" | jq .)${NC}"
                        else
                            log "${RED}Something went wrong trying to find [${host} - ${type}] in the DNS records returned by [Cloudflare]!${NC}"
                        fi
                    fi
                fi

            else
                dnsrecords=$(cat "$cache") && debug_log "Read back DNS records from cache file: $cache" && verbose_debug_log "${YELLOW}Data read from cache:\n$(echo "${dnsrecords}" | jq .)${NC}"
            fi
            ##################################################

            ##################################################
            ## If DNS records were retrieved, do the update ##
            ##################################################
            if [[ -n ${dnsrecords} ]]; then

                 zoneid=$(echo "$dnsrecords" | jq -r '.zone_id' | head -1)
                     id=$(echo "$dnsrecords" | jq -r '.id'      | head -1)
                proxied=$(echo "$dnsrecords" | jq -r '.proxied' | head -1)
                    ttl=$(echo "$dnsrecords" | jq -r '.ttl'     | head -1)
                     ip=$(echo "$dnsrecords" | jq -r '.content' | head -1)

                if [[ "$ip" != "$newip" ]]; then
                    auth_log "Updating DNS record"
                    response=$(curl_header -X PUT "https://api.cloudflare.com/client/v4/zones/$zoneid/dns_records/$id" --data '{"id":"'"$id"'","type":"'"${type}"'","name":"'"${host}"'","content":"'"$newip"'","ttl":'"$ttl"',"proxied":'"$proxied"'}')
                    if [[ $(echo "${response}" | jq -r .success) == false ]]; then
                        log "${RED}Error response from [Cloudflare]:\n$(echo "${response}" | jq .)${NC}"
                    else
                        log "Updating IP [$ip] to [$newip]: ${GREEN}OK${NC}"
                        verbose_debug_log "${YELLOW}Response from [Cloudflare]:\n$(echo "${response}" | jq .)${NC}"
                        [[ ${INFLUXDB_ENABLED} == "true" ]] && curl -fsSL -XPOST "${INFLUXDB_HOST}/write?db=${INFLUXDB_DB}" -u "${INFLUXDB_USER}:${INFLUXDB_PASS}" --data-binary "domains,host=$(hostname),domain=${host},recordtype=${type} ip=\"$newip\"" && debug_log "Wrote IP update to InfluxDB."
                        rm "$cache" && debug_log "Deleted cache file: $cache"
                    fi
                else
                    verbose_log "Updating IP [$ip] to [$newip]: ${YELLOW}NO CHANGE${NC}"
                fi

            fi
            ##################################################

        fi

    done

    ## Reset values
    unset host
    unset zone
    unset type

    ## Go to sleep ##
    [[ ${LOG_LEVEL} -gt 2 ]] && echo "$(date +'%Y-%m-%d %H:%M:%S') - Going to sleep for ${INTERVAL} seconds..."
    sleep "${INTERVAL}"

done
