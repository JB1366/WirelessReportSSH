#!/bin/sh
##############################################################################
#               _    _  _               _                                    #
#              | |  | |(_)             | |                                   #
#              | |  | | _  _ __  ___   | |  ___  ___  ___                    #
#              | |/\| || || '__|/ _ \  | | / _ \/ __|/ __|                   #
#              \  /\  /| || |  |  __/  | ||  __/\__ \\__ \                   #
#               \/  \/ |_||_|   \___|  |_| \___||___/|___/                   #
#                                                                            #
#               _____                             _                          #
#              |  __ \                           | |                         #
#              | |__) | ___  _ __    ___   _ __  | |_                        #
#              |  _  / / _ \| '_ \  / _ \ | '__| | __|                       #
#              | | \ \|  __/| |_) || (_) || |    | |_                        #
#              |_|  \_\\___|| .__/  \___/ |_|     \__|                       #
#                           | |                                              #
#                           |_|                                              #
#                                                                            #
# Author: JB_1366                                                            #
##############################################################################
# shellcheck shell=sh disable=SC2086,SC2155,SC3043                           #
##############################################################################

SCRIPT_VERSION="1.3.5"
INSTALL_DIR="/jffs/addons/wireless_report"
REPORT_SCRIPT="$INSTALL_DIR/wirelessreport.sh"
CONF_FILE="$INSTALL_DIR/webui.conf"
[ -f "$CONF_FILE" ] && . "$CONF_FILE"
USB_PATH=$(ls -d /tmp/mnt/*/wirelessreport 2>/dev/null | head -n 1)
if [ -z "$USB_PATH" ]; then
    OLD_PATH=$(ls -d /tmp/mnt/*/gen_report 2>/dev/null | head -n 1)
    if [ -n "$OLD_PATH" ]; then
        NEW_PATH="${OLD_PATH%/*}/wirelessreport"
        mkdir -p "$NEW_PATH"
        mv "$OLD_PATH"/* "$NEW_PATH/" 2>/dev/null
        rm -rf "$OLD_PATH" 2>/dev/null
        USB_PATH="$NEW_PATH"
    fi
fi
[ -z "$USB_PATH" ] && USB_PATH="$INSTALL_DIR/data" && mkdir -p "$USB_PATH"
export PATH="/usr/sbin:/usr/bin:/sbin:/bin:/jffs/bin"
KNOWN_DB="$USB_PATH/known_macs.db"; HISTORY_DB="$USB_PATH/rssi_history.db"
OUT_FILE="/tmp/wireless.asp"; YAZ_CLIENTS="/jffs/addons/YazDHCP.d/DHCP_clients"
SEEN_MACS="/tmp/seen_macs.txt"; ARP_CACHE="/tmp/arp_cache.tmp"
YAZ_CACHE="/tmp/yaz_cache.tmp"; NEW_HISTORY="/tmp/rssi_new.db"
Q_RELAY="/tmp/q_relay.tmp"; MAIN_ROWS="/tmp/main_rows.tmp"
NODE_ROWS="/tmp/node_rows.tmp"; ALL_ROWS="/tmp/all_rows.tmp"
CYAN='\033[0;36m'; GREEN='\033[0;32m'; RED='\033[0;31m'; NC='\033[0m'
SSH_KEY="/tmp/home/root/.ssh/id_dropbear"
doScriptUpdateFromAMTM=true
GITHUB="https://raw.githubusercontent.com/JB1366/Wireless_Report/main/wirelessreport.sh"
REMOTE_VER=$(curl -s -m 2 "$GITHUB" | grep "SCRIPT_VERSION=" | head -n 1 | cut -d'"' -f2 | tr -cd '0-9.')
[ -n "$REMOTE_VER" ] && [ "$REMOTE_VER" != "$SCRIPT_VERSION" ] && HOVER_TEXT="Current Script v$SCRIPT_VERSION <br> New Version v$REMOTE_VER available" || HOVER_TEXT="SCRIPT v$SCRIPT_VERSION"
[ ${#HOVER_TEXT} -le 14 ] && V_WIDTH="100px" || V_WIDTH="190px"
[ "$REPORT_UNIT" = "C" ] && D_FMT="+%-d-%b %-H:%M" || D_FMT="+%b-%-d %-H:%M"
[ "$REPORT_UNIT" = "C" ] && T_FMT="+%-d-%b %-H:%M:%S" || T_FMT="+%b-%-d %-H:%M:%S"
> $SEEN_MACS; > $MAIN_ROWS; > $NODE_ROWS; > $ALL_ROWS; > $NEW_HISTORY; > $Q_RELAY

##########################
#  Inject Menu Function  #
##########################
inject_menu() {
	source /usr/sbin/helper.sh
	SYSTEM_MENU="/www/require/modules/menuTree.js"
	TEMP_MENU="/tmp/menuTree.js"
	TAB_LABEL="Wireless Report"
	WEB_PAGE="$INSTALL_DIR/wireless.asp"
	RAM_PAGE="/tmp/wireless.asp"
	
	[ -f "$CONF_FILE" ] && sed -i '/^INSTALLED_PAGE=/d' "$CONF_FILE"

	# Does the firmware support addons?
	nvram get rc_support | grep -q am_addons
	if [ $? != 0 ]; then
		logger -t "Wireless Report" "This firmware does not support addons!"
		exit 5
	fi

	# Create the directory if it doesn't exist
	mkdir -p "$INSTALL_DIR"

	# Ensure the RAM target exists so the mount doesn't fail later
	if [ ! -f "$RAM_PAGE" ]; then
		echo "<html><body>Generating Report... Please refresh.</body></html>" > "$RAM_PAGE"
	fi

	# If this is a first-time install, create a placeholder so the API sees a file
	if [ ! -f "$WEB_PAGE" ]; then
		echo "Initial Install: Creating placeholder."
		echo "<html><body>Generating Report... Please refresh.</body></html>" > "$WEB_PAGE"
	fi

	[ -f "$CONF_FILE" ] && sed -i '/^INSTALLED_PAGE=/d' "$CONF_FILE"

	# Obtain the first available mount point in $am_webui_page
	am_get_webui_page "$WEB_PAGE"

	if [ "$am_webui_page" = "none" ]; then
		logger -t "Wireless Report" "Unable to install Wireless Report"
		exit 5
	fi

	cp "$WEB_PAGE" "/www/user/$am_webui_page"
	rm -f "$WEB_PAGE"

	[ -f "/tmp/menuTree.js" ] && sed -i '/Wireless Report/d' /tmp/menuTree.js 2>/dev/null

	# Copy mounted user page to installed directory config
	if [ -f "$CONF_FILE" ]; then
		echo "INSTALLED_PAGE=$am_webui_page" >> "$CONF_FILE"
	else
		echo "INSTALLED_PAGE=$am_webui_page" > "$CONF_FILE"
	fi

	# Copy menuTree (if no other script has done it yet) so we can modify it
	if [ ! -f "$TEMP_MENU" ]; then
		cp "$SYSTEM_MENU" /tmp/
		mount -o bind "$TEMP_MENU" "$SYSTEM_MENU"
	fi

	# Wireless Menu-Tab Insertion
	# Inject Wireless Report tab just before the Wireless menu's __INHERIT__ sentinel
	sed -i "/index: \"menu_Wireless\"/,/{url: \"NULL\", tabName: \"__INHERIT__\"}/ {/{url: \"NULL\", tabName: \"__INHERIT__\"}/i \\
	{url: \"$am_webui_page\", tabName: \"$TAB_LABEL\"},
	}" "$TEMP_MENU"
	logger -t "Wireless Report" "Mounting Menu/Wireless TAB/Wireless Report as $am_webui_page"

	# Remount modified menu
	umount "$SYSTEM_MENU" && mount -o bind "$TEMP_MENU" "$SYSTEM_MENU"
	umount "/www/user/$am_webui_page" 2>/dev/null
	mount -o bind "$RAM_PAGE" "/www/user/$am_webui_page"
	service restart_httpd >/dev/null 2>&1 || killall -HUP httpd >/dev/null 2>&1
	"$INSTALL_DIR/wirelessreport.sh" &
}

##############################
#  Script Install Functions  #
##############################
ScriptUpdateFromAMTM() {
    if ! "$doScriptUpdateFromAMTM"
    then
        printf "Automatic script updates via AMTM are currently disabled.\n\n"
        return 1
    fi
    if [ $# -gt 0 ] && [ "$1" = "check" ]
    then return 0
    fi
    do_update
	echo -e "\n${GREEN}SUCCESS: AMTM Auto Update complete!${NC}"
    return "$?"
}

do_update() { 
    curl -sfL --connect-timeout 3 "$GITHUB" -o "$REPORT_SCRIPT"
	chmod +x "$REPORT_SCRIPT" 2>/dev/null
	echo -e "\n${GREEN}SUCCESS: Installation of Wireless Report complete!${NC}"
}

check_version() {
    local 
    if [ -f "$REPORT_SCRIPT" ]; then
        LOCAL_VER=$(grep "SCRIPT_VERSION=" "$REPORT_SCRIPT" | head -n 1 | cut -d'"' -f2 2>/dev/null)
    else
        LOCAL_VER="NOT INSTALLED"
    fi
    REMOTE_DATA=$(curl -sfL --connect-timeout 2 "$GITHUB")
    if [ $? -ne 0 ] || [ -z "$REMOTE_DATA" ]; then
        REMOTE_VER=""
    else
        REMOTE_VER=$(echo "$REMOTE_DATA" | grep "SCRIPT_VERSION=" | head -n 1 | cut -d'"' -f2 2>/dev/null)
    fi
    echo -e "${CYAN}==================================================${NC}"
    echo -e "${CYAN}              WIRELESS REPORT AIMESH              ${NC}"
    echo -e "${CYAN}==================================================${NC}"
    if [ -z "$REMOTE_VER" ]; then
        echo -e " STATUS: ${RED}[Offline]${NC} Could not reach GitHub"
    elif [ "$LOCAL_VER" = "NOT INSTALLED" ]; then
        echo -e " STATUS: [Ready] Latest available is v$REMOTE_VER"
    elif [ "$LOCAL_VER" != "$REMOTE_VER" ]; then
        echo -e " STATUS: ${RED}[UPDATE AVAILABLE] v$REMOTE_VER${NC} (Current: v$LOCAL_VER)"
    else
        echo -e " STATUS: [Up to date] v$LOCAL_VER"
    fi
    echo -e "${CYAN}==================================================${NC}"
}

check_storage() {
    echo -e "${CYAN}[*] Checking for Storage...${NC}"
    if echo "$USB_PATH" | grep -q "/tmp/mnt/"; then
        echo -e "${GREEN}[+] USB Found: Using $USB_PATH for reports and history.${NC}"
    else
        echo -e "${YELLOW}[!] No USB detected: Using JFFS at $USB_PATH.${NC}"
    fi
    mkdir -p "$USB_PATH" 2>/dev/null
}

show_menu() {
    echo -e ""
    echo -e "  (1)  Install/Update Wireless Report"
    echo -e "  (2)  Uninstall Wireless Report"
    echo -e "  (3)  Temperature Unit: °F(def) or °C"
    echo -e "  (4)  Set Router/Node Nicknames"
    echo -e "  (e)  Exit"
    echo -e ""
    echo -e "${CYAN}==================================================${NC}"
    printf " Selection: "
}

check_ssh_environment() {
    mkdir -p "$INSTALL_DIR" 2>/dev/null
    
    [ ! -f "$CONF_FILE" ] && touch "$CONF_FILE"

    echo -e "${CYAN}[*] Verifying Passwordless SSH Environment...${NC}"
    
    if [ ! -f "$SSH_KEY" ]; then
        echo -e "${RED}[!] ERROR: Local SSH Key not found at $SSH_KEY${NC}"
        echo -e "${RED}[!] Please setup passwordless SSH Key(s) and try again.${NC}"
        return 1
    fi

    SSH_PORT=$(nvram get sshd_port)
    [ -z "$SSH_PORT" ] && SSH_PORT=22  

    NODE_IPS=$(nvram get asus_device_list | sed 's/</\n/g' | grep '>2$' | awk -F '>' '{print $2 "|" $3}' | sort -t . -k 4,4n)
    NODE_USER=$(nvram get http_username)
    
    if [ -z "$NODE_IPS" ]; then
        echo -e "${RED}[!] No AiMesh Nodes detected. This script requires a AiMesh environment.${NC}"
        echo -e "${RED}[!] Installation aborted.${NC}"
        return 1
    fi

    any_success=0
    VALID_NODES=""
    
    for line in $NODE_IPS; do
        ALIAS=$(echo "$line" | cut -d'|' -f1)
        IP=$(echo "$line" | cut -d'|' -f2)

        echo -ne "[*] Testing Passwordless SSH to $ALIAS ($IP) on port $SSH_PORT... "
        /usr/bin/ssh -p "$SSH_PORT" -i "$SSH_KEY" -o StrictHostKeyChecking=no -o ConnectTimeout=3 -o BatchMode=yes "${NODE_USER}@${IP}" "exit" >/dev/null 2>&1
        
        if [ $? -eq 0 ]; then
            echo -e "${GREEN}AUTHENTICATED${NC}"
            any_success=1
            VALID_NODES="$VALID_NODES $ALIAS|$IP"
        else
            echo -e "${RED}FAILED${NC}"
        fi
    done

    if [ "$any_success" -eq 0 ]; then
        echo -e "${RED}[!] Error: No nodes authenticated. Setup SSH Keys and try again.${NC}"
        return 1
    fi

    sed -i '/SSH_NODES=/d' "$CONF_FILE"
    echo "SSH_NODES=\"$VALID_NODES\"" >> "$CONF_FILE"
}

do_install() {
    mkdir -p "$INSTALL_DIR" 2>/dev/null
    
    if [ -f "$REPORT_SCRIPT" ]; then
        LOCAL_VER=$(grep "SCRIPT_VERSION=" "$REPORT_SCRIPT" | head -n 1 | cut -d'"' -f2 2>/dev/null)
        REMOTE_DATA=$(curl -s --connect-timeout 2 "$GITHUB")
        REMOTE_VER=$(echo "$REMOTE_DATA" | grep "SCRIPT_VERSION=" | head -n 1 | cut -d'"' -f2 2>/dev/null)
        
        if [ "$LOCAL_VER" = "$REMOTE_VER" ] && [ -n "$REMOTE_VER" ]; then
            echo -e "\n${GREEN}[i] You are already on the latest version (v$LOCAL_VER).${NC}"
            printf " Do you want to reinstall/overwrite anyway? (y/n): "
            read -r confirm_reinstall
            if [ "$confirm_reinstall" != "y" ] && [ "$confirm_reinstall" != "Y" ]; then
                return
            fi
        fi
		if do_update; then
            service restart_httpd >/dev/null 2>&1
            pause
            return 0
        fi
	fi

    if [ "$(nvram get jffs2_scripts)" != "1" ]; then
        echo -e "${RED}[!] ERROR: JFFS custom scripts not enabled.${NC}"
        return 1
    fi

    check_storage
    check_ssh_environment
    
    echo -e "${CYAN}[*] Processing Wireless Report Files...${NC}"
    
    [ ! -f "$CONF_FILE" ] && touch "$CONF_FILE"
	
    if ! grep -q "REPORT_UNIT=" "$CONF_FILE" 2>/dev/null; then 
        echo "REPORT_UNIT=F" >> "$CONF_FILE"
    fi

    [ -f "/tmp/menuTree.js" ] && sed -i '/Wireless Report/d' /tmp/menuTree.js 2>/dev/null
    
    if [ -f "$CONF_FILE" ]; then
        OLD_PAGE=$(grep "INSTALLED_PAGE=" "$CONF_FILE" | cut -d'=' -f2)
        if [ -n "$OLD_PAGE" ]; then
            umount -l "/www/user/$OLD_PAGE" 2>/dev/null
            rm -f "/www/user/$OLD_PAGE"
        fi
    fi
    
    curl -s --connect-timeout 5 "$GITHUB" -o "$REPORT_SCRIPT"
    chmod +x "$REPORT_SCRIPT" 2>/dev/null
    
    if [ -f "$REPORT_SCRIPT" ]; then
        inject_menu
        
        [ ! -f "/jffs/scripts/services-start" ] && echo "#!/bin/sh" > /jffs/scripts/services-start
        sed -i "\|$REPORT_SCRIPT|d" /jffs/scripts/services-start
        echo "sh $REPORT_SCRIPT inject # Inject Wireless Report" >> /jffs/scripts/services-start
        chmod +x /jffs/scripts/services-start
        
        [ ! -f "/jffs/scripts/service-event" ] && echo "#!/bin/sh" > /jffs/scripts/service-event
        sed -i "/wireless_report/d" /jffs/scripts/service-event
        echo 'if [ "$1" = "restart" ] && [ "$2" = "wireless_report" ]; then sh '$REPORT_SCRIPT'; fi # Wireless Report' >> /jffs/scripts/service-event
		
        chmod +x /jffs/scripts/service-event
        service restart_httpd >/dev/null 2>&1 || killall -HUP httpd >/dev/null 2>&1
        sh "$REPORT_SCRIPT" >/dev/null 2>&1 &
        echo -e "\n${GREEN}SUCCESS: Installation complete!${NC}"
        echo -e "${CYAN}[i] Use Option 4 if you wish to set custom nicknames.${NC}"
    else
        echo -e "${RED}[!] ERROR: Download failed.${NC}"
    fi
    pause
}

do_uninstall() {
    if [ ! -d "$INSTALL_DIR" ]; then
        echo -e "\n${RED}[!] Wireless Report is not installed.${NC}"
        pause
        return
    fi

    echo -e "\n${RED}[!] WARNING: Removing Wireless Report...${NC}"
    printf " Are you sure? (y/n): "
    read confirm
    if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
        [ -f "$CONF_FILE" ] && . "$CONF_FILE"

        if mount | grep -q "menuTree.js"; then
            echo -e "${CYAN}[*] Detaching menu for cleaning...${NC}"
            umount -l /www/require/modules/menuTree.js >/dev/null 2>&1
            sed -i '/tabName:[[:space:]]*"Wireless Report"/d' /tmp/menuTree.js
            
            if grep -q "tabName" /tmp/menuTree.js; then
                mount --bind /tmp/menuTree.js /www/require/modules/menuTree.js
            else
                echo -e "${CYAN}[*] Restoring menu to factory default.${NC}"
            fi
        fi

        if [ -n "$INSTALLED_PAGE" ]; then
            logger -t "Wireless Report" "Unmounting Menu/Wireless TAB/Wireless Report"
			umount -l "/www/user/$INSTALLED_PAGE" >/dev/null 2>&1
			rm -f "/www/user/$INSTALLED_PAGE" >/dev/null 2>&1
        fi

        sed -i "\|$REPORT_SCRIPT|d" /jffs/scripts/services-start
        sed -i "/wireless_report/d" /jffs/scripts/service-event
        service restart_httpd >/dev/null 2>&1 || killall -HUP httpd >/dev/null 2>&1
        rm -rf "$INSTALL_DIR" 2>/dev/null
        rm -f /tmp/wireless.asp 2>/dev/null
		rm -rf "$USB_PATH" 2>/dev/null
        echo -e "${GREEN}[+] Uninstalled. Wireless Report tab is gone.${NC}"
    fi
    pause
}

pause() { printf "\nPress [Enter] to return..."; read discard; }

set_temp_unit() {
    clear
    echo -e "${CYAN}==================================================${NC}"
    echo -e "             TEMPERATURE UNIT SETTINGS                        "
    echo -e "${CYAN}==================================================${NC}"
    
    [ -f "$CONF_FILE" ] && . "$CONF_FILE"
    CURRENT_UNIT=${REPORT_UNIT:-F}
    
    echo -e " Current Setting: ${GREEN}$CURRENT_UNIT${NC}"
    echo -e ""
    echo -e "  (1)  Fahrenheit (°F) - Default"
    echo -e "  (2)  Celsius (°C)"
    echo -e "  (r)  Return to main menu"
    echo -e ""
    printf " Selection: "
    read t_choice

    case "$t_choice" in
        1) NEW_UNIT="F" ;;
        2) NEW_UNIT="C" ;;
        r|R) return ;;
        *) echo -e "${RED}Invalid selection.${NC}"; sleep 1; set_temp_unit; return ;;
    esac

    if [ ! -f "$CONF_FILE" ]; then
        echo "REPORT_UNIT=$NEW_UNIT" > "$CONF_FILE"
    else
        sed -i '/REPORT_UNIT=/d' "$CONF_FILE"
        echo "REPORT_UNIT=$NEW_UNIT" >> "$CONF_FILE"
    fi

    echo -e "${GREEN}[+] Temperature unit set to $NEW_UNIT${NC}"
    
    [ -f "$REPORT_SCRIPT" ] && sh "$REPORT_SCRIPT" >/dev/null 2>&1 &
    
    pause
}
set_nicknames() {
    clear
    RAW_NODES=$(nvram get asus_device_list | sed 's/</\n/g' | grep '>2$')
    MAIN_IP=$(nvram get lan_ipaddr)
    MAIN_HW_MODEL=$(nvram get modelid)
    [ -z "$MAIN_HW_MODEL" ] && MAIN_HW_MODEL=$(nvram get productid)
    
    [ -f "$CONF_FILE" ] && . "$CONF_FILE"

    echo -e "${CYAN}==================================================${NC}"
    echo -e "              ROUTER NICKNAME SETUP               "
    echo -e "      (Press [Enter] to keep the current name)     "
    echo -e "${CYAN}==================================================${NC}"
    echo -e ""

    CURRENT_MAIN_NICK=${MAIN_NICK:-"$MAIN_HW_MODEL"}
    printf " Main $MAIN_IP [$CURRENT_MAIN_NICK]: "
    read input_main
    
    MAIN_NICK=${input_main:-"$CURRENT_MAIN_NICK"}
    sed -i '/^MAIN_NICK=/d' "$CONF_FILE"
    echo "MAIN_NICK=\"$MAIN_NICK\"" >> "$CONF_FILE"

    if [ -n "$RAW_NODES" ]; then
        VALID_NODES=$(echo "$RAW_NODES" | awk -F '>' '{print $2 "|" $3}' | sort -t . -k 4,4n)
        for node in $VALID_NODES; do
            ALIAS=$(echo "$node" | cut -d'|' -f1)
            IP=$(echo "$node" | cut -d'|' -f2)
            CLEAN_IP=$(echo "$IP" | tr '.' '_')
            
            eval SAVED_NICK=\$NODE_NICK_$CLEAN_IP
            CURRENT_DISPLAY=${SAVED_NICK:-"$ALIAS"}
            
            printf " Node $IP [$CURRENT_DISPLAY]: "
            read input_node
            
            NEW_NICK=${input_node:-"$CURRENT_DISPLAY"}
            sed -i "/^NODE_NICK_$CLEAN_IP=/d" "$CONF_FILE"
            echo "NODE_NICK_$CLEAN_IP=\"$NEW_NICK\"" >> "$CONF_FILE"
        done
    fi
    echo -e "\n${GREEN}[+] Nicknames updated successfully.${NC}"
}

install_menu() {
	while true; do
		clear; check_version; show_menu; read choice
		case "$choice" in
			1) do_install ;;
			2) do_uninstall ;;
			3) set_temp_unit ;;
			4) 
				if [ -f "$CONF_FILE" ]; then
					set_nicknames
					[ -f "$REPORT_SCRIPT" ] && sh "$REPORT_SCRIPT" >/dev/null 2>&1 &
					pause
				else
					echo -e "${RED}[!] Please install the report (Option 1) first.${NC}"
					sleep 2
				fi
				;;
			e|E) clear; exit 0 ;;
			*) echo -e "${RED}Invalid selection.${NC}"; sleep 1 ;;
		esac
	done
}

######################
#  Report Functions  #
######################
get_rssi_style() {
    local r=$1
    if [ "$r" -ge -50 ]; then echo "color: #30d158; font-weight: bold;"
    elif [ "$r" -ge -60 ]; then echo "color: #64d2ff; font-weight: bold;"
    elif [ "$r" -ge -70 ]; then echo "color: #ffd60a; font-weight: bold;"
    else echo "color: #ff453a; font-weight: bold;"; fi
}

get_bars() {
    local r=$1
    if [ "$r" -ge -50 ]; then echo "<span class='bar-box sig-exc'>||||</span>"
    elif [ "$r" -ge -60 ]; then echo "<span class='bar-box sig-good'>|||</span>"
    elif [ "$r" -ge -70 ]; then echo "<span class='bar-box sig-fair'>||</span>"
    else echo "<span class='bar-box sig-poor'>|</span>"; fi
}

get_trend() {
    local mac=$(echo "$1" | tr '[:lower:]' '[:upper:]'); local current=$2
    local old=$(grep "$mac" "$HISTORY_DB" | cut -d'|' -f2)
    echo "$mac|$current" >> "$NEW_HISTORY"
    if [ -z "$old" ] || [ "$old" -eq 0 ]; then echo "<span class='trend-box'>•</span>"; return; fi
    if [ "$current" -gt "$old" ]; then echo "<span class='trend-box trend-up sig-exc'>↑</span>"
    elif [ "$current" -lt "$old" ]; then echo "<span class='trend-box trend-down sig-poor'>↓</span>"
    else echo "<span class='trend-box'>•</span>"; fi
}

get_name() {
    local mac=$(echo "$1" | tr '[:lower:]' '[:upper:]')
    local name=""
    [ -f "$YAZ_CACHE" ] && name=$(grep -i "$mac" "$YAZ_CACHE" | awk -F'|' '{print $3}' | head -n 1)
    [ -z "$name" ] && name=$(grep -i "$mac" /var/lib/misc/dnsmasq.leases | awk '{print $4}' | head -n 1)
    [ -z "$name" ] || [ "$name" = "*" ] && name=$(nvram get custom_clientlist | sed 's/</\n/g' | grep -i "$mac" | awk -F'>' '{print $1}')
    if [ -z "$name" ] || [ "$name" = "*" ]; then
        local fuzzy=$(echo "$mac" | cut -d: -f2-5)
        name=$(grep -i "$fuzzy" "$YAZ_CACHE" | awk -F'|' '{print $3}' | head -n 1)
    fi
    [ -z "$name" ] || [ "$name" = "*" ] && name="$mac"
    echo "$name"
}

check_new() {
    local mac=$(echo "$1" | tr '[:lower:]' '[:upper:]')
    [ ! -f "$KNOWN_DB" ] && touch "$KNOWN_DB"
    if ! grep -qi "$mac" "$KNOWN_DB"; then echo "$mac" >> "$KNOWN_DB"; echo "new-device-row"; fi
}

ip_to_num() { echo "$1" | awk -F. '{if(NF==4) printf "%03d%03d%03d%03d", $1,$2,$3,$4; else printf "000000000000";}' ; }

get_band_html() {
    local iface=$1; local width=$2; local model=$3
	width=$(echo "$width" | sed 's/-[0-9]//g' | sed 's/M//g')
    local w_text=""; [ -n "$width" ] && w_text=" ($width)"
    local theUILabel="Unknown"

    # Quad-Band Mapping
    # Models: GT-BE98(Pro), BQ16, GT-AXE16000, GT-BE25000
    if echo "$model" | grep -qiE "BE98|BQ16|AXE16000|BE25000"; then
		case "$iface" in
			wl0*) theUILabel="5G" ;;
			wl1*) echo "$model" | grep -qiE "PRO|BQ16" && theUILabel="6G-1" || theUILabel="5G-2" ;;
			wl2*) echo "$model" | grep -qiE "PRO|BQ16" && theUILabel="6G-2" || theUILabel="6G" ;;
			wl3*) theUILabel="2.4G" ;;
		esac

    # Tri-Band Mapping (2.4G,5G,6G)
    # Models: RT-BE96U, RT-BE92U, GT-BE19000, GS-BE18000, GS-BE12000, BT6, BT8, BT10, 
    #         RT-AXE7800, GT-AXE11000, ET8, ET9, ET12 
    elif echo "$model" | grep -qiE "BE96U|BE92U|BE19000|BE18000|BE12000|BT6|BT8|BT10|AXE7800|AXE11000|ET8|ET9|ET12"; then
        case "$iface" in
            wl0*|eth1*|eth4*) theUILabel="2.4G" ;; 
            wl1*|eth2*|eth5*) theUILabel="5G" ;;
            wl2*|eth6*)       theUILabel="6G" ;; 
        esac
		
	# Tri-Band Mapping (2.4G,5G-1,5G-2)
    # Models:  RT-AX92U, GT6, XT8, XT9, XT12
    elif echo "$model" | grep -qiE "AX92U|GT6|XT8|XT9|XT12"; then
        case "$iface" in
            wl0*|eth1*|eth4*) theUILabel="2.4G" ;; 
            wl1*|eth2*|eth5*) theUILabel="5G-1" ;;
            wl2*|eth6*)       theUILabel="5G-2" ;; 
        esac	

    # Dual-Band Mapping
    else
        case "$iface" in
            wl0*|eth1*|eth4*|eth6*) theUILabel="2.4G" ;;
            wl1*|eth2*|eth5*|eth7*) theUILabel="5G" ;;
            *)                      theUILabel="Unknown" ;;
        esac
    fi
	
	# Band UI Renderer
    local class="" sort="0"
	case "$theUILabel" in
		"2.4G")              class="text-24"; sort="2.4" ;;
		"5G"|"5G-1"|"5G-2")  class="text-5g"; sort="5"   ;;
		"6G"|"6G-1"|"6G-2")  class="text-6g"; sort="6"   ;;
	esac
	echo "<td data-sort='$sort' style='text-align:center;'><span class='$class'>$theUILabel$w_text</span></td>"
}

fmt_time() {
    T=$1; [ -z "$T" ] || ! echo "$T" | grep -qE '^[0-9]+$' && echo "<span data-sort='0'>---</span>" && return
    local pulse=""; [ "$T" -lt 900 ] && pulse="pulse-blue"
    echo "$T" | awk -v p="$pulse" '{d=int($1/86400); h=int(($1%86400)/3600); m=int(($1%3600)/60); printf "<span class=\""p"\" data-sort=\"%s\">", $1; if(d>0) printf "%02dd %02dh", d, h; else if(h>0) printf "%02dh %02dm", h, m; else printf "00h %02dm", m; printf "</span>";}'
}

to_f() {
    local raw_c=$1
    [ -z "$raw_c" ] || ! echo "$raw_c" | grep -qE '^-?[0-9]+$' && echo "--" && return
    if [ "$REPORT_UNIT" = "C" ]; then
        echo "${raw_c}°C"
    else
        echo "$raw_c" | awk '{printf "%.0f°F", ($1 * 1.8) + 32}'
    fi
}

get_temp_class() {
    local temp_str=$1
    [ "$temp_str" = "--" ] && echo "val-blue" && return
    local val=$(echo "$temp_str" | sed 's/[^0-9.]//g')
    if [ "$REPORT_UNIT" = "C" ]; then
        awk -v t="$val" 'BEGIN { if(t>75) print "stat-hot"; else if(t>68) print "stat-warm"; else print "val-blue"; }'
    else
        awk -v t="$val" 'BEGIN { if(t>167) print "stat-hot"; else if(t>155) print "stat-warm"; else print "val-blue"; }'
    fi
}
 
get_load_class() {
    local l=$1; [ "$l" = "--" ] && { echo "val-blue"; return; }
    awk -v l="$l" 'BEGIN { print (l>2.0 ? "stat-hot" : (l>1.0 ? "stat-warm" : "val-blue")) }'
}

run_report() {
###############
#  Main Scan  #
###############
grep "0x2" /proc/net/arp | awk '{print toupper($4)"|"$1}' > "$ARP_CACHE"
[ -f "$YAZ_CLIENTS" ] && awk -F',' '{print toupper($1) "|" $2 "|" $3}' "$YAZ_CLIENTS" > $YAZ_CACHE || > $YAZ_CACHE
M_T=$(($(cat /sys/class/thermal/thermal_zone0/temp 2>/dev/null || echo 0) / 1000))
M_TEMP=$(to_f "$M_T")
M_LOAD=$(cat /proc/loadavg | awk '{print $1}')
MC_TEMP=$(get_temp_class "$M_TEMP")
MC_LOAD=$(get_load_class "$M_LOAD")
M_UPTIME=$(awk -v s=$(cat /proc/uptime | cut -d. -f1) 'BEGIN {d=int(s/86400); h=int((s%86400)/3600); m=int((s%3600)/60); if(d>0) printf "%dd %dh %dm", d, h, m; else if(h>0) printf "%dh %dm", h, m; else printf "%dm", m}')
M_BOOT=$(date -d @$(( $(date +%s) - $(cut -d. -f1 /proc/uptime) )) "$D_FMT")
MAIN_PFX=$(nvram get lan_hwaddr | cut -c 1-14 | tr '[:lower:]' '[:upper:]')
NODE_PFX=$(nvram get asus_device_list | sed 's/</\n/g' | awk -F'>' '{print $1}' | cut -c 1-14 | tr '[:lower:]' '[:upper:]')
ROUTER_IP=$(nvram get lan_ipaddr)
DEVICE_LIST=$(nvram get cfg_device_list)
M_ALIAS=$(echo "$DEVICE_LIST" | sed 's/</\n/g' | grep ">$ROUTER_IP>" | awk -F'>' '{print $1}')
M_NAME="${MAIN_NICK:-${M_ALIAS:-"Main Router"}}"
[ ${#M_NAME} -gt 25 ] && M_NAME="${M_NAME:0:25}"
MAIN_LABEL="<span class='router-branding'>$M_NAME (MAIN)</span>"
RSSI_UNIT="<span style='font-size:14px; font-weight:bold; margin-left:2px;'>ᵈᴮᵐ</span>"
MBPS_UNIT="<span style='font-size:14px; font-weight:bold; margin-left:2px;'>ᵐᵇᵖˢ</span>"
MHZ_UNIT="<span style='font-size:14px; font-weight:bold; margin-left:2px;'>ᵐʰᶻ</span>"
T_EXC=0; T_GOOD=0; T_FAIR=0; T_POOR=0; M_TOTAL=0; N_TOTAL=0

for iface in $(ifconfig -a | grep -oE "wl[0-9](\.[0-9])?|eth[1-7]"); do
	case "$iface" in wl0.0|wl1.0|wl2.0|wl3.0) continue ;; esac
	case "$iface" in eth1|eth4|eth6) [ -n "$(nvram get wl3_ssid)" ] && data_iface="wl3" || { [ -n "$(nvram get wl2_ssid)" ] && data_iface="wl2" || data_iface="wl0"; } ;; eth2|eth5|eth7) data_iface="wl1" ;; *) data_iface="$iface" ;; esac
	SNAME=$(nvram get "${data_iface}_ssid")
	[ -z "$SNAME" ] && SNAME=$(nvram get "${iface%.*}_ssid")
	if echo "$SNAME" | grep -qE '^[0-9A-Fa-f]{16,}$'; then continue; fi
	for mac in $(wl -i "$iface" assoclist 2>/dev/null | awk '{print $2}'); do
		m_live=$(echo "$mac" | tr '[:lower:]' '[:upper:]')
		m_prefix=$(echo "$m_live" | cut -c 1-14)
		if echo "$MAIN_PFX $NODE_PFX" | grep -q "$m_prefix"; then continue; fi
		yaz_entry=$(grep -i "^$m_live|" "$YAZ_CACHE" | head -n 1)
		[ -z "$yaz_entry" ] && yaz_entry=$(grep -i "$(echo "$m_live" | cut -d: -f2-5)" "$YAZ_CACHE" | grep -vE '[]r]' | head -n 1)
		[ -n "$yaz_entry" ] && { m_up=$(echo "$yaz_entry" | cut -d'|' -f1 | tr '[:lower:]' '[:upper:]'); ip=$(echo "$yaz_entry" | cut -d'|' -f2); name=$(echo "$yaz_entry" | cut -d'|' -f3); } || \
		{ m_up="$m_live"; name=$(get_name "$m_up"); ip=$(grep -ih "$m_up" "$ARP_CACHE" "$YAZ_CACHE" | cut -d'|' -f2 | head -n 1); }
		[ -z "$ip" ] && ip="---" || ip=$(printf "%s.%03d" "${ip%.*}" "${ip##*.}")
		{ [ -z "$name" ] || [ "$name" = "*" ]; } && name="$m_up"
		rssi=$(wl -i "$iface" rssi "$mac" 2>/dev/null | awk '{print $1}')
		! echo "$rssi" | grep -qE '^-[0-9]+$' && continue
		[ "$rssi" -ge -20 ] || [ "$rssi" -le -100 ] || grep -qi "$m_up" "$SEEN_MACS" && continue
		echo "$m_up" | grep -qE '^([0-9A-F]{2}:){5}[0-9A-F]{2}$' && echo "$m_up" >> "$SEEN_MACS"
		raw_info=$(wl -i "$iface" sta_info "$mac" 2>/dev/null)
		rx_raw=$(echo "$raw_info" | grep "rate of last rx pkt" | awk '{print $6/1000}')
		tx_raw=$(echo "$raw_info" | grep "rate of last tx pkt" | awk -F': ' '{print $2}' | awk '{print $1/1000}')
		max_raw=$(echo "$raw_info" | grep "Max Rate =" | awk '{print $4}')
		mhz_width=$(echo "$raw_info" | grep "chanspec" | awk -F'/' '{print $2}' | awk '{print $1}')
		[ -z "$mhz_width" ] && mhz_width="20"
		[ -z "$rx_raw" ] || [ "$rx_raw" = "0" ] && rx_disp="?" || rx_disp="${rx_raw%.*}"
		[ -z "$tx_raw" ] || [ "$tx_raw" = "0" ] && tx_disp="${max_raw:-?}" || tx_disp="${tx_raw%.*}"
		l_rate_disp="${rx_disp} / ${tx_disp}"
		[ "$rx_disp" = "?" ] && [ "$tx_disp" = "?" ] && l_rate_disp="---"
		l_rate_val=${tx_disp:-0}
		is_new=$(check_new "$m_up")
		trend=$(get_trend "$m_up" "$rssi")
		bars=$(get_bars "$rssi")
		rssi_style=$(get_rssi_style "$rssi")
		uptime=$(echo "$raw_info" | grep 'in network' | awk '{print $3}')
		[ ${#name} -gt 20 ] && name="${name:0:20}"
		display_ssid="$SNAME"
		[ ${#display_ssid} -gt 15 ] && display_ssid="${display_ssid:0:15}"
		ip_s=$(ip_to_num "$ip")
		band_td=$(get_band_html "$iface" "$mhz_width" "$M_ALIAS")
		if [ "$rssi" -ge -50 ]; then T_EXC=$((T_EXC+1)); elif [ "$rssi" -ge -60 ]; then T_GOOD=$((T_GOOD+1)); elif [ "$rssi" -ge -70 ]; then T_FAIR=$((T_FAIR+1)); else T_POOR=$((T_POOR+1)); fi
		ROW_STR="<tr class='$is_new'><td style='text-align:left;'>$name</td><td class='toggle-cell'><span class='m-val' data-sort='$m_up'>$m_up</span><span class='i-val' data-sort='$ip_s'>$ip</span></td><td data-sort='$rssi'>$bars <span style='$rssi_style'>$rssi</span> $trend</td><td data-sort='$l_rate_val' style='$rssi_style; text-align:center;'>$l_rate_disp</td><td class='toggle-ssid'><span class='s-val' data-sort='$SNAME'>$display_ssid</span><span class='if-val' data-sort='$iface'>$iface</span></td>$band_td<td>$(fmt_time "$uptime")</td></tr>"
		echo "$ROW_STR" >> $MAIN_ROWS; echo "$ROW_STR" >> $ALL_ROWS
		M_TOTAL=$((M_TOTAL + 1))
	done
done

CONSOLIDATED_T="<span class='${MC_TEMP}'>${M_TEMP}</span>"
CONSOLIDATED_L="<span class='${MC_LOAD}'>${M_LOAD}</span>"
CONSOLIDATED_U="<span class='val-blue'>${M_UPTIME}</span>"
CONSOLIDATED_B="<span class='val-blue'>${M_BOOT}</span>"

####################
#  Node Scan Loop  #
####################
[ -n "$SSH_NODES" ] && TARGET_LIST="$SSH_NODES" || TARGET_LIST=$(nvram get asus_device_list | sed 's/</\n/g' | grep '>2$' | awk -F '>' '{print $1"|"$2"|"$3}' | sort -t '|' -k 1,1 | awk -F '|' '{print $2"|"$3}')
for line in $TARGET_LIST; do ALIAS="${line%|*}"; IP="${line#*|}"; done
SSH_PORT=$(nvram get sshd_port); SSH_PORT=${SSH_PORT:-22}; SSH_KEY="/tmp/home/root/.ssh/id_dropbear"
NODE_USER=$(nvram get http_username)
NODE_DATA=$(nvram get asus_device_list | sed 's/</\n/g' | grep '>2$' | awk -F '>' '{print $2 "|" $3}' | sort -t . -k 4,4n)
NODE_COUNT_TOTAL=$(echo "$NODE_DATA" | grep -v "^$" | wc -l)
[ "$NODE_COUNT_TOTAL" -gt 1 ] && N_SUFFIX="(NODES)" || N_SUFFIX="(NODE)"
NODE_COLORS="#64d2ff #30d158 #ffd60a #bf40bf #ff9500 #ff453a"; PIPE=" <span style='color:white;'>|</span> "
N_NAMES=""; N_TEMPS=""; N_LOADS=""; N_BOOTS=""; N_UPTIMES=""; N_SPLIT_COUNTS=""; COLOR_IDX=0; ACTIVE_NODES=0

for line in $TARGET_LIST; do
    NODE_OUT=""
    IP=$(echo "$line" | cut -d'|' -f2)
    ALIAS=$(echo "$line" | cut -d'|' -f1)
    [ -z "$IP" ] && continue
    CLEAN_IP=$(echo "$IP" | tr '.' '_'); eval CUSTOM_NICK=\$NODE_NICK_$CLEAN_IP
    NODE_DISPLAY_NAME="${CUSTOM_NICK:-${ALIAS:-$IP}}"
	[ ${#NODE_DISPLAY_NAME} -gt 25 ] && NODE_DISPLAY_NAME="${NODE_DISPLAY_NAME:0:25}"
    NODE_OUT=$(/usr/bin/ssh -p "$SSH_PORT" -i "$SSH_KEY" -o StrictHostKeyChecking=no "${NODE_USER}@${IP}" "
        UP_SEC=\$(cut -d. -f1 /proc/uptime)
		F_UP=\$(awk -v s=\"\$UP_SEC\" 'BEGIN {d=int(s/86400); h=int((s%86400)/3600); m=int((s%3600)/60); if(d>0) printf \"%dd %dh %dm\", d, h, m; else if(h>0) printf \"%dh %dm\", h, m; else printf \"%dm\", m}')
		NODE_COUNT=0
        for iface in \$(ifconfig -a | grep -oE \"wl[0-9](\.[0-9])?\"); do
            case \"\$iface\" in wl0.0|wl1.0|wl2.0|wl3.0) continue ;; esac
			SN=\$(nvram get \"\${iface}_ssid\"); [ -z \"\$SN\" ] && SN=\$(nvram get \"\${iface%.*}_ssid\")
            if echo \"\$SN\" | grep -qE '^[0-9A-Fa-f]{16,}$'; then continue; fi
            for mac in \$(wl -i \"\$iface\" assoclist 2>/dev/null | awk '{print \$2}'); do
                RAW=\$(wl -i \"\$iface\" sta_info \"\$mac\" 2>/dev/null)
                RSSI=\$(wl -i \"\$iface\" rssi \"\$mac\" 2>/dev/null | awk '{print \$1}')
                RX=\$(echo \"\$RAW\" | grep \"rate of last rx pkt\" | awk '{print \$6/1000}')
                TX=\$(echo \"\$RAW\" | grep \"rate of last tx pkt\" | awk -F': ' '{print \$2}' | awk '{print \$1/1000}')
                MX=\$(echo \"\$RAW\" | grep \"Max Rate =\" | awk '{print \$4}')
                W=\$(echo \"\$RAW\" | grep \"chanspec\" | awk -F'/' '{print \$2}' | awk '{print \$1}')
                HB=\$(wl -i \"\$iface\" band | awk '{print \$1}')
                [ -z \"\$W\" ] && W=\"20\"
                RXD=\$(echo \"\$RX\" | awk '{if (\$1==0) print \"?\"; else printf \"%.0f\", \$1}')
                TXD=\$(echo \"\$TX\" | awk -v m=\"\$MX\" '{if (\$1==0) print m; else printf \"%.0f\", \$1}')
                [ \"\$RXD\" = \"?\" ] && [ \"\$TXD\" = \"?\" ] && LRD=\"\${MX:-?}\" || LRD=\"\${RXD} / \${TXD}\"
                echo \"DATA|\$mac|\$RSSI|\$iface|\$(echo \"\$RAW\" | grep \"in network\" | awk '{print \$3}')|\$SN|\$TX|\$LRD|\$W|\$HB\"
                NODE_COUNT=\$((NODE_COUNT + 1))
            done
        done
        echo \"TEMP|\$(cat /sys/class/thermal/thermal_zone0/temp 2>/dev/null | cut -c1-2)\"
        echo \"LOAD|\$(cat /proc/loadavg | awk '{print \$1}')\"
        echo \"UPTIME_VAL|\$F_UP\"; echo \"UPTIME_RAW|\$UP_SEC\"; echo \"COUNT|\$NODE_COUNT\"
    " 2>/dev/null)
    if [ -n "$NODE_OUT" ]; then
        ACTIVE_NODES=$((ACTIVE_NODES + 1)); COLOR_IDX=$((COLOR_IDX + 1))
        CUR_COLOR=$(echo $NODE_COLORS | cut -d' ' -f$((COLOR_IDX)))
        [ -z "$CUR_COLOR" ] && CUR_COLOR="#ffffff"
        STAR_HTML="<span style='color:$CUR_COLOR;'><sup>$ACTIVE_NODES</sup></span>"
        NODE_BRAND="<span class='router-branding' style='color:$CUR_COLOR;'>${NODE_DISPLAY_NAME}<sup>$ACTIVE_NODES</sup></span>"
        [ -z "$N_NAMES" ] && N_NAMES="$NODE_BRAND" || N_NAMES="$N_NAMES$PIPE$NODE_BRAND"
		N_TEMP_RAW=$(echo "$NODE_OUT" | grep "TEMP|" | cut -d'|' -f2)
        [ ${#N_TEMP_RAW} -gt 3 ] && N_TEMP_RAW=$((N_TEMP_RAW / 1000))
        N_TEMP=$(to_f "$N_TEMP_RAW")
        N_LOAD=$(echo "$NODE_OUT" | grep "LOAD|" | cut -d'|' -f2)
		NC_TEMP=$(get_temp_class "$N_TEMP")
		NC_LOAD=$(get_load_class "$N_LOAD")
        N_UPTIME_RAW=$(echo "$NODE_OUT" | grep "UPTIME_RAW|" | cut -d'|' -f2)
		N_UPTIME=$(echo "$NODE_OUT" | grep "UPTIME_VAL|" | cut -d'|' -f2)
		N_BOOT=$(date -d @$(( $(date +%s) - ${N_UPTIME_RAW:-0} )) "$D_FMT")
		CONSOLIDATED_T="$CONSOLIDATED_T | <span class='${NC_TEMP}'>${N_TEMP}</span>"
        CONSOLIDATED_L="$CONSOLIDATED_L | <span class='${NC_LOAD}'>${N_LOAD}</span>"
        CONSOLIDATED_U="$CONSOLIDATED_U | <span style='color:$CUR_COLOR;'>${N_UPTIME}</span>"
        CONSOLIDATED_B="$CONSOLIDATED_B | <span style='color:$CUR_COLOR;'>${N_BOOT}</span>"
		N_TEMPS="${N_TEMPS}${N_TEMPS:+$PIPE}<span class='${NC_TEMP}'>$N_TEMP</span>"
		N_LOADS="${N_LOADS}${N_LOADS:+$PIPE}<span class='${NC_LOAD}'>$N_LOAD</span>"
        N_UPTIMES="${N_UPTIMES}${N_UPTIMES:+$PIPE}<span style='color:$CUR_COLOR;'>$N_UPTIME</span>"
		N_BOOTS="${N_BOOTS}${N_BOOTS:+$PIPE}<span style='color:$CUR_COLOR;'>$N_BOOT</span>"
        NODE_DISPLAY_COUNT=0
		
        while read -r dline; do
            [ -z "$dline" ] && continue
            m_live=$(echo "$dline" | cut -d'|' -f2 | tr '[:lower:]' '[:upper:]')
            m_prefix=$(echo "$m_live" | cut -c 1-14)
			{ echo "$MAIN_PFX $NODE_PFX" | grep -q "$m_prefix" || grep -qi "$m_live" "$SEEN_MACS"; } && continue
            yaz_entry=$(grep -i "^$m_live|" "$YAZ_CACHE" | head -n 1)
            [ -z "$yaz_entry" ] && yaz_entry=$(grep -i "$(echo "$m_live" | cut -d: -f2-5)" "$YAZ_CACHE" | grep -vE '[]r]' | head -n 1)
			[ -n "$yaz_entry" ] && { m_up=$(echo "$yaz_entry" | cut -d'|' -f1 | tr '[:lower:]' '[:upper:]'); n_ip=$(echo "$yaz_entry" | cut -d'|' -f2); n_name=$(echo "$yaz_entry" | cut -d'|' -f3); } || \
			{ m_up="$m_live"; n_name=$(get_name "$m_up"); n_ip=$(grep -ih "$m_up" "$ARP_CACHE" "$YAZ_CACHE" | cut -d'|' -f2 | head -n 1); }
			[ -z "$n_ip" ] && n_ip="---" || n_ip=$(printf "%s.%03d" "${n_ip%.*}" "${n_ip##*.}")
			{ [ -z "$n_name" ] || [ "$n_name" = "*" ]; } && n_name="$m_up"
            grep -qi "$m_up" "$SEEN_MACS" && continue
            echo "$m_up" | grep -qE '^([0-9A-F]{2}:){5}[0-9A-F]{2}$' && echo "$m_up" >> "$SEEN_MACS"
            N_TOTAL=$((N_TOTAL + 1))
            NODE_DISPLAY_COUNT=$((NODE_DISPLAY_COUNT + 1))
            r_raw=$(echo "$dline" | cut -d'|' -f3)
            if [ "$r_raw" -ge -50 ]; then echo "EXC" >> "$Q_RELAY"
            elif [ "$r_raw" -ge -60 ]; then echo "GOOD" >> "$Q_RELAY"
            elif [ "$r_raw" -ge -70 ]; then echo "FAIR" >> "$Q_RELAY"
            else echo "POOR" >> "$Q_RELAY"; fi
            i_raw=$(echo "$dline" | cut -d'|' -f4)
			u_raw=$(echo "$dline" | cut -d'|' -f5)
			s_name=$(echo "$dline" | cut -d'|' -f6)
            display_s_name="$s_name"
			[ ${#display_s_name} -gt 15 ] && display_s_name="${display_s_name:0:15}"
            l_rate_val=$(echo "$dline" | cut -d'|' -f7)
			l_rate_disp_n=$(echo "$dline" | cut -d'|' -f8)
			w_raw=$(echo "$dline" | cut -d'|' -f9)
			hb_raw=$(echo "$dline" | cut -d'|' -f10)
            is_new=$(check_new "$m_up")
			trend=$(get_trend "$m_up" "$r_raw")
			bars_n=$(get_bars "$r_raw")
			rssi_style_n=$(get_rssi_style "$r_raw")
            [ ${#n_name} -gt 20 ] && n_name="${n_name:0:20}"
            ip_ns=$(ip_to_num "$n_ip")
			band_td_n=$(get_band_html "$i_raw" "$w_raw" "$ALIAS")
            N_ROW="<tr><td style='text-align:left;'>$n_name$STAR_HTML</td><td class='toggle-cell'><span class='m-val' data-sort='$m_up'>$m_up</span><span class='i-val' data-sort='$ip_ns'>$n_ip</span></td><td data-sort='$r_raw'>$bars_n <span style='$rssi_style_n'>$r_raw</span> $trend</td><td data-sort='$l_rate_val' style='$rssi_style_n; text-align:center;'>$l_rate_disp_n</td><td class='toggle-ssid'><span class='s-val' data-sort='$s_name'>$display_s_name</span><span class='if-val' data-sort='$i_raw'>$i_raw</span></td>$band_td_n<td>$(fmt_time "$u_raw")</td></tr>"
            echo "$N_ROW" >> $NODE_ROWS; echo "$N_ROW" >> $ALL_ROWS
        done <<EOF
$(echo "$NODE_OUT" | grep "DATA|")
EOF
			N_SPLIT_COUNTS="${N_SPLIT_COUNTS}${N_SPLIT_COUNTS:+ | }<span style='color:$CUR_COLOR;'>$NODE_DISPLAY_COUNT</span>"
    fi
done
T_EXC=$((T_EXC + $(grep -c "EXC" "$Q_RELAY"))); T_GOOD=$((T_GOOD + $(grep -c "GOOD" "$Q_RELAY")))
T_FAIR=$((T_FAIR + $(grep -c "FAIR" "$Q_RELAY"))); T_POOR=$((T_POOR + $(grep -c "POOR" "$Q_RELAY")))
GRAND_TOTAL=$((M_TOTAL + N_TOTAL))
BRAND_LINE_ALL="<span class='router-branding'>$M_NAME</span> | $N_NAMES"
[ "$ACTIVE_NODES" -ge 1 ] && FULL_DEVICE_BREAKDOWN="Devices: <span class='val-blue'>$GRAND_TOTAL</span> <span class='dash-sep'>—›</span> <span class='val-blue'>$M_TOTAL</span> | $N_SPLIT_COUNTS" || FULL_DEVICE_BREAKDOWN="Devices: <span class='val-blue'>$M_TOTAL</span>"
mv "$NEW_HISTORY" "$HISTORY_DB"

##########
#  HTML  #
##########
CUR_TIME=$(date "$T_FMT")
/usr/bin/printf '\xEF\xBB\xBF' > $OUT_FILE
cat <<HTML >> $OUT_FILE
<!DOCTYPE html>
<html>
<head>
<meta charset="UTF-8" />
<title>ASUS Wireless Router $M_NAME - Wireless Report</title>
<link rel="shortcut icon" href="images/favicon.png">
<link rel="icon" href="images/favicon.png">
<link rel="stylesheet" href="index_style.css" />
<link rel="stylesheet" href="form_style.css" />
<link rel="stylesheet" href="usp_style.css" />
<link rel="stylesheet" href="other.css" />
<script src="/js/jquery.js"></script>
<script src="/state.js"></script>
<script src="/general.js"></script>
<script src="/popup.js"></script>
<script src="/help.js"></script>
<style>
  #wifiReportContainer { color: #f2f2f7; font-size: 12px; font-family: Arial, sans-serif; width: 97% !important; margin: 0 !important; padding: 0 !important; position: relative; }
  .report-header-main { text-align: center; color: #0096ff; margin: 0 0 10px 0; font-size: 1.8em; text-transform: uppercase; font-weight: bold; width: 100%; position: static; margin-left: 0; }
  .top-controls { display: flex; justify-content: center; gap: 8px; width: 100%; margin: 0 0 12px 0; }
  .total-count { text-align: center; color: #f2f2f7; margin-bottom: 12px; font-size: 11px; font-weight: bold; text-transform: uppercase; letter-spacing: 0.5px; }
  .count-highlight { background: #0096ff; color: #000; padding: 1px 6px; border-radius: 3px; margin-left: 4px; font-weight: 900; }
  .v-wrap { text-align: center; width: 100%; margin: 10px 0; }
  .v-tip { position: relative; cursor: pointer; display: inline-block; }
  .v-box { visibility: hidden; width: var(--v-width, 190px); background: #1c232b; color: #3498db; text-align: center; border: 1px solid #475a68; border-radius: 6px; padding: 8px; position: absolute; z-index: 999; bottom: 135%; left: 50%; transform: translateX(-50%); opacity: 0; transition: opacity 0.6s cubic-bezier(0.4, 0, 0.2, 1), bottom 0.6s cubic-bezier(0.4, 0, 0.2, 1); font-size: 0.85rem; font-weight: bold; box-shadow: 0 4px 12px #000; pointer-events: none; line-height: 1.4; }
  .v-tip:hover .v-box { visibility: visible; opacity: 1; bottom: 145%; }
  .quality-bar { display: flex; justify-content: center; gap: 12px; align-items: center; width: 100%; margin: -5px auto -5px auto; padding: 0; background: transparent; border: none; height: auto; }
  .q-box { display: inline-block; height: 28px; line-height: 26px; text-align: center; padding: 0 12px; border-radius: 4px; background: rgba(0,0,0,0.4); border: 1px solid #475a68; font-weight: bold; box-sizing: border-box; transition: all 0.2s ease; }
  .q-box:hover { border-color: #0096ff; box-shadow: 0 0 10px rgba(0,150,255,0.4); cursor: pointer; }
  .q-box:hover select, .q-box:hover .btn-manual { color: #0096ff !important; }
  .btn-black-blue { background: rgba(0,0,0,0.6); border: 1px solid #475a68; color: #0096ff; cursor: pointer; padding: 0 12px; font-size: 12px; border-radius: 4px; font-weight: bold; height: 28px; line-height: 26px; transition: all 0.2s ease; box-sizing: border-box; }
  .btn-black-blue:hover, .btn-black-blue.active { border-color: #0096ff; box-shadow: 0 0 10px rgba(0,150,255,0.4); color: #0096ff; }
  .btn-black-blue.active { background: rgba(0,150,255,0.15); }
  #countdown { margin-left: 6px; font-weight: bold; }
  #refreshRate:focus { outline: none; border: none; background: #000; }
  .grid-container { display: flex; flex-direction: column; gap: 15px; align-items: center; width: 100%; }
  .report-column { width: 100%; background: #1c232b; border-radius: 8px; border: 1px solid #475a68; overflow: hidden; display: flex; flex-direction: column; }
  .report_table tbody tr:hover td { background-color: rgba(0, 123, 255, 0.15) !important; cursor: pointer; }
  table.report_table { width: 100%; border-collapse: collapse; }
  table.report_table.show-ip .m-val { display: none !important; } 
  table.report_table.show-ip .i-val { display: inline !important; color: #64d2ff; }
  table.report_table.show-iface .s-val { display: none !important; } 
  table.report_table.show-iface .if-val { display: inline !important; color: #64d2ff; }
  table.report_table thead th { position: sticky; top: 0; z-index: 10; background: linear-gradient(to bottom, #0096ff, #0056b3); color: #fff; padding: 8px; cursor: pointer; text-align: center; border-right: 1px solid rgba(255,255,255,0.1); }
  table.report_table th:hover { background: #00e5ff; color: #000; text-shadow: 0 0 10px rgba(0,229,255,0.8); }
  table.report_table td { padding: 6px; border-bottom: 1px solid #3d454b; background: #1c232b; vertical-align: middle; text-align: center; }
  table.report_table td:nth-child(1) { max-width: 150px; white-space: nowrap; overflow: hidden; text-overflow: clip; }
  table.report_table td:nth-child(5) { max-width: 100px; white-space: nowrap; overflow: hidden; text-overflow: clip; }
  table.report_table tr td:first-child { text-align: left; padding-left: 10px; }
  table.report_table thead th:first-child { text-align: left; padding-left: 10px; }
  table.report_table tfoot td { border-top: 1px solid #475a68; padding: 12px 10px !important; font-weight: bold; background: #171b1f; color: #fff; }
  .f-res { color: #0096ff; }
  .pulse-blue { color: #00e5ff !important; font-weight: bold; animation: pulse-blue-glow 2s infinite; }
  @keyframes pulse-blue-glow { 0% { opacity: 1; } 50% { opacity: 0.5; } 100% { opacity: 1; } }
  .sig-exc { color: #30d158; } .sig-good { color: #64d2ff; } .sig-fair { color: #ffd60a; } .sig-poor { color: #ff453a; }
  .stat-warm { color: #ffa500 !important; font-weight: bold; } .stat-hot { color: #ff453a !important; font-weight: bold; }
  .bar-box { font-family: monospace; font-weight: 900; width: 40px; display: inline-block; text-align: right; margin-right: 5px; }
  .section-header { background: linear-gradient(to bottom, #171b1f, #354961); color: #ffffff; font-weight: bold; padding: 12px; text-align: center; border-bottom: 1px solid #475a68; }
  .router-branding { color: #0096ff; font-size: 1.4em; font-weight: bold; text-transform: uppercase; display: inline-block; margin-bottom: 4px; }
  .header-stats-row { display: block; font-size: 14px; color: #f2f2f7; margin-top: 5px; font-weight: bold; white-space: nowrap; width: 100%; overflow: visible !important; }
  .sep-line { border: 0; border-top: 1px solid #475a68; margin: 8px -12px; width: calc(100% + 24px); display: block; }
  .val-blue { color: #0096ff; font-weight: bold; }
  .m-val, .s-val { display: inline; } .i-val, .if-val { display: none; }
  .text-24 { color: #ffa500 !important; font-weight: bold; }
  .text-5g { color: #0096ff !important; font-weight: bold; }
  .text-6g { color: #bf40bf !important; font-weight: bold; }
  .modal-overlay { display: none; position: fixed; top:0; left:0; width:100%; height:100%; background:rgba(0,0,0,0.4); z-index:9999; align-items: center; justify-content: center; backdrop-filter: blur(8px); }
  .modal-content { background: rgba(0, 0, 0, 0.2); width: 95%; max-width: 1450px; margin: auto; padding:15px; border-radius:15px; border:1px solid rgba(0, 150, 255, 0.4); position: relative; max-height: 95vh; overflow-y: auto; box-shadow: 0 0 40px rgba(0,0,0,0.6); backdrop-filter: blur(20px); }
  .close-x { position: absolute; top: 10px; right: 20px; color: #fff; font-size: 30px; cursor: pointer; font-weight: bold; }
  .modal-grid { display: flex; width: 100%; gap: 5px; margin-top: 5px; align-items: flex-start; justify-content: center; }
  .modal-grid .report-column { flex: 1; max-width: 49.5%; }
  #popoutModal th, #popoutModal td { white-space: nowrap; height: 25px !important; line-height: 25px !important; padding: 0 4px !important; }
  .dash-sep { color: rgba(255,255,255,0.4); font-size: 0.9em; margin: 0 4px; animation: sep-glow 3s infinite ease-in-out; }
  @keyframes sep-glow { 0% { color: rgba(255,255,255,0.2); } 50% { color: #0096ff; text-shadow: 0 0 5px #0096ff; } 100% { color: rgba(255,255,255,0.2); } }
  #allCol { display: none; width: 100% ; align-self: flex-start; }
  .row-break { flex-basis: 100%; height: 0; margin: 0; }
  sup { font-size: 0.6em; margin-left: 2px; }
</style>
<script>
function initial(){ 
    show_menu(); 
    var savedRate = localStorage.getItem('wifiReportAutoRefresh') || "0";
    document.getElementById('refreshRate').value = savedRate;
    initAutoRefresh(parseInt(savedRate));
    sortTable(2, 'mainTable', false, true);
    if(document.getElementById('nodeTable')) sortTable(2, 'nodeTable', false, true);
    sortTable(2, 'allTable', false, true);
}
var timeLeft = 0; var refreshTimer = null; var isRefreshing = false;
function triggerRefresh() {
    if (isRefreshing) return; isRefreshing = true;
    var btn = document.querySelector('.btn-manual');
    if (btn) btn.innerText = "Refreshing...";
    var expires = new Date(Date.now() + 30000).toUTCString();
    document.cookie = "report_done=true; expires=" + expires + "; path=/";
    fetch('/apply.cgi', { 
        method: 'POST', 
        body: 'action_mode=apply&rc_service=restart_wireless_report&current_page=$INSTALLED_PAGE&next_page=$INSTALLED_PAGE' 
    }).then(function() { 
        setTimeout(function() { window.location.reload(); }, 7000); 
    });
}
window.addEventListener('load', function() {
    if (document.cookie.indexOf("report_done=true") === -1) {
        triggerRefresh();
    } else {
        console.log("Cookie found: Skipping auto-refresh to prevent loop.");
    }
});
function initAutoRefresh(seconds) {
    clearInterval(refreshTimer);
    if (seconds > 0) {
        timeLeft = seconds;
        refreshTimer = setInterval(function() { timeLeft--; if (timeLeft <= 0) { triggerRefresh(); clearInterval(refreshTimer); } document.getElementById('countdown').innerHTML = "&nbsp;" + timeLeft + "s"; }, 1000);
    } else { document.getElementById('countdown').innerHTML = ""; }
}
function switchTab(view) {
    var split = document.getElementById('splitView');
    var all = document.getElementById('allCol');
    var btnMain = document.getElementById('btnMain');
    var btnAll = document.getElementById('btnAll');
    if(view === 'all') {
        split.style.display = 'none'; all.style.display = 'flex';
        btnAll.classList.add('active'); btnMain.classList.remove('active');
    } else {
        split.style.display = 'flex'; all.style.display = 'none';
        btnMain.classList.add('active'); btnAll.classList.remove('active');
    }
}
function toggleCols(tId, cls, header, labelA, labelB) { 
    var table = document.getElementById(tId); if(!table) return;
    var isActive = table.classList.toggle(cls); header.innerHTML = (isActive ? labelB : labelA) + " ⇅";
    var colIdx = (cls === 'show-ip') ? 1 : 4; sortTable(colIdx, tId, true);
}
function sortTable(n, tId, keepDir, forceDesc) {
    var table = document.getElementById(tId); if(!table) return;
    var tbody = table.tBodies[0]; var rows = Array.prototype.slice.call(tbody.rows); if(!rows.length) return;
    var dir = table.getAttribute("data-dir-" + n) || "asc";
    if (forceDesc) { dir = "desc"; } else if (!keepDir) { dir = (dir === "asc") ? "desc" : "asc"; }
    table.setAttribute("data-dir-" + n, dir);
    var headers = table.querySelectorAll('th');
    headers.forEach(function(h, idx) {
		var isPop = tId.startsWith("pop");
		var txt = h.innerText.toUpperCase();
		if (idx === 1) {
			h.innerHTML = table.classList.contains('show-ip') ? "IP ADDRESS ⇵" : "MAC ADDRESS ⇵";
		} else if (txt.includes("RSSI")) {
			h.innerHTML = "RSSI" + "${RSSI_UNIT}";
		} else if (txt.includes("RX/TX")) {
			h.innerHTML = "RX/TX" + "${MBPS_UNIT}";
		} else if (txt.includes("BAND")) {
			h.innerHTML = "BAND" + "${MHZ_UNIT}";
		} else if (idx === 4) {
			h.innerHTML = table.classList.contains('show-iface') ? "IFACE ⇵" : "SSID ⇵";
		} else {
			h.innerHTML = h.innerHTML.replace(/[▼▲▾▴]/g, "").trim();
		}
	});	
    rows.sort(function(a, b) {
        var valA, valB; var cellA = a.cells[n]; var cellB = b.cells[n];
        if (n === 1) { 
            var sel = table.classList.contains('show-ip') ? '.i-val' : '.m-val';
            valA = cellA.querySelector(sel).getAttribute('data-sort'); valB = cellB.querySelector(sel).getAttribute('data-sort'); if (sel === '.m-val') {
			return dir === "asc" ? valA.localeCompare(valB) : valB.localeCompare(valA);
		}
        } else if (n === 4) { 
            var sel = table.classList.contains('show-iface') ? '.if-val' : '.s-val';
            valA = cellA.querySelector(sel).innerText.trim().toLowerCase(); valB = cellB.querySelector(sel).innerText.trim().toLowerCase();
        } else if (n === 6) { 
            var parseTime = function(s) {
				var d = s.match(/(\d+)d/) ? parseInt(s.match(/(\d+)d/)[1]) : 0;
				var h = s.match(/(\d+)h/) ? parseInt(s.match(/(\d+)h/)[1]) : 0;
				var m = s.match(/(\d+)m/) ? parseInt(s.match(/(\d+)m/)[1]) : 0;
				return (d * 1440) + (h * 60) + m;
			};
            valA = parseTime(cellA.innerText); valB = parseTime(cellB.innerText);
        } else if (cellA.hasAttribute('data-sort')) { valA = cellA.getAttribute('data-sort'); valB = cellB.getAttribute('data-sort');
        } else { valA = cellA.innerText.trim(); valB = cellB.innerText.trim(); }

        var numA = parseFloat(valA); var numB = parseFloat(valB);
        if(!isNaN(numA) && !isNaN(numB)) { return dir === "asc" ? numA - numB : numB - numA; }
        return dir === "asc" ? valA.localeCompare(valB) : valB.localeCompare(valA);
    });
    rows.forEach(function(r) { tbody.appendChild(r); });
}
function openPopout() {
    var body = document.getElementById('popoutBody'); body.innerHTML = "";
    var mCol = document.getElementById('mainCol').cloneNode(true); var nCol = document.getElementById('nodeCol').cloneNode(true);
    mCol.querySelector('table').id = "popMainTable"; nCol.querySelector('table').id = "popNodeTable";
    mCol.querySelectorAll('th').forEach(function(th, i) {
        if(i===1) th.onclick = function() { toggleCols('popMainTable', 'show-ip', this, 'MAC ADDRESS', 'IP ADDRESS'); };
        else if(i===4) th.onclick = function() { toggleCols('popMainTable', 'show-iface', this, 'SSID', 'IFACE'); };
        else th.onclick = function() { sortTable(i, 'popMainTable'); };
    });
    nCol.querySelectorAll('th').forEach(function(th, i) {
        if(i===1) th.onclick = function() { toggleCols('popNodeTable', 'show-ip', this, 'MAC ADDRESS', 'IP ADDRESS'); };
        else if(i===4) th.onclick = function() { toggleCols('popNodeTable', 'show-iface', this, 'SSID', 'IFACE'); };
        else th.onclick = function() { sortTable(i, 'popNodeTable'); };
    });
    body.appendChild(mCol); body.appendChild(nCol); document.getElementById('popoutModal').style.display = 'flex';
}
function closePopout() { document.getElementById('popoutModal').style.display = 'none'; }
</script>
</head>
<body onload="initial();">
<div id="TopBanner"></div>
<div id="Loading" class="popup_bg"></div>
<table class="content" align="center" cellpadding="0" cellspacing="0">
  <tr>
    <td width="17">&nbsp;</td>
    <td valign="top" width="202"><div id="mainMenu"></div><div id="subMenu"></div></td>
    <td valign="top">
      <div id="tabMenu" class="submenuBlock"></div>
      <div id="wifiReportContainer" style="padding:10px;">
      <div class="v-wrap"><div class="v-tip" style="--v-width: $V_WIDTH;"><h1 id="v-header" class="report-header-main" style="margin:0; display:inline-block;">WIRELESS REPORT</h1><span class="v-box">$HOVER_TEXT</span></div></div>
        <div class="total-count">Total Wireless Devices: <span class="count-highlight">$GRAND_TOTAL</span></div>
		<div class="top-controls">
			<div class="q-box" style="padding:0 5px; display:inline-flex; align-items:center;">
			<button class="btn-manual btn-black-blue" style="border:none; height:100%; line-height:inherit; padding:0 8px;" onclick="triggerRefresh()">Refresh</button>
				<span style="font-size:12px; margin-left:5px;">Auto: </span>
				<select id="refreshRate" onchange="localStorage.setItem('wifiReportAutoRefresh', this.value); initAutoRefresh(parseInt(this.value));" style="background:#000; color:#0096ff; border:0px solid #444; margin-left:2px; font-size:12px; height:20px;">
					<option value="0">Off</option><option value="30">30s</option><option value="60">1m</option><option value="120">2m</option><option value="300">5m</option><option value="600">10m</option><option value="1200">20m</option><option value="1800">30m</option>
				</select><span id="countdown"></span>
			</div>
			<button id="btnMain" class="btn-black-blue active" onclick="switchTab('split')">Stacked</button>
			<button id="btnAll" class="btn-black-blue" onclick="switchTab('all')">All Devices</button>
			<button class="btn-black-blue" onclick="openPopout()">Side by Side ⇗</button>
		</div>
          <div class="grid-container">
          <div id="splitView" style="display:flex; flex-direction:column; gap:15px; width:100%;">
              <div id="mainCol" class="report-column">
                <div class="section-header">
                  $MAIN_LABEL<br>
                  <span style="font-size:11px; font-weight:bold;">Updated: $CUR_TIME</span>
                  <hr class="sep-line">
                  <div class="header-stats-row">Temp: <span class="$MC_TEMP">$M_TEMP</span> • Load: <span class="$MC_LOAD">$M_LOAD</span> • Devices: <span class="val-blue">$M_TOTAL</span></div>
                </div>
                <table id="mainTable" class="report_table show-ip">
                  <thead><tr>
                    <th onclick="sortTable(0, 'mainTable')">HOSTNAME</th>
                    <th onclick="toggleCols('mainTable', 'show-ip', this, 'MAC ADDRESS', 'IP ADDRESS')">IP ADDRESS</th>
					<th onclick="sortTable(2, 'mainTable')">RSSI</th>
					<th onclick="sortTable(3, 'mainTable')">RX/TX</th>
                    <th onclick="toggleCols('mainTable', 'show-iface', this, 'SSID', 'IFACE')">SSID</th>
                    <th onclick="sortTable(5, 'mainTable')">BAND</th>
                    <th onclick="sortTable(6, 'mainTable')">UPTIME</th>
                  </tr></thead>
                  <tbody>$(cat $MAIN_ROWS)</tbody>
                  <tfoot><tr><td colspan="7" style="text-align: center !important;">Uptime: <span class="f-res">$M_UPTIME</span> • Reboot: <span class="f-res">$M_BOOT</span></td></tr></tfoot>
                </table>
              </div>
			  <div class="quality-bar">
				  <div class="q-box sig-exc">Excellent: <span style="background:#30d158; color:#000; padding:1px 5px; border-radius:3px; margin-left:4px;">$T_EXC</span></div>
				  <div class="q-box sig-good">Good: <span style="background:#0096ff; color:#000; padding:1px 5px; border-radius:3px; margin-left:4px;">$T_GOOD</span></div>
				  <div class="q-box sig-fair" style="color:#ffd60a;">Fair: <span style="background:#ffd60a; color:#000; padding:1px 5px; border-radius:3px; margin-left:4px;">$T_FAIR</span></div>
				  <div class="q-box sig-poor" style="color:#ff453a;">Poor: <span style="background:#ff453a; color:#000; padding:1px 5px; border-radius:3px; margin-left:4px;">$T_POOR</span></div>
			  </div>
			  <div id="nodeCol" class="report-column">
                <div class="section-header">
                  $N_NAMES <span class="router-branding">$N_SUFFIX</span><br>
                  <span style="font-size:11px; font-weight:bold;">Updated: $CUR_TIME</span>
                  <hr class="sep-line">
                  <div class="header-stats-row">Temp: <span class='${NC_TEMP}'>${N_TEMPS:-0}</span> • Load: <span class='${NC_LOAD}'>${N_LOADS:-0}</span> • Devices: <span class="val-blue">$N_TOTAL</span> <span class="dash-sep">—›</span> $N_SPLIT_COUNTS</div>
                </div>
                <table id="nodeTable" class="report_table show-ip">
                  <thead><tr>
                    <th onclick="sortTable(0, 'nodeTable')">HOSTNAME</th>
                    <th onclick="toggleCols('nodeTable', 'show-ip', this, 'MAC ADDRESS', 'IP ADDRESS')">IP ADDRESS</th>
                    <th onclick="sortTable(2, 'nodeTable')">RSSI</th>
                    <th onclick="sortTable(3, 'nodeTable')">RX/TX</th>
                    <th onclick="toggleCols('nodeTable', 'show-iface', this, 'SSID', 'IFACE')">SSID</th>
                    <th onclick="sortTable(5, 'nodeTable')">BAND</th>
                    <th onclick="sortTable(6, 'nodeTable')">UPTIME</th>
                  </tr></thead>
                  <tbody>$(cat $NODE_ROWS)</tbody>
                  <tfoot><tr><td colspan="7" style="text-align: center !important;">$( [ -n "$N_UPTIMES" ] && echo "Uptime: $N_UPTIMES • Reboot: $N_BOOTS" || echo "Offline" )</td></tr></tfoot>
                </table>
              </div>
          </div>
          <div id="allCol" class="report-column">
            <div class="section-header">
              $BRAND_LINE_ALL<br>
              <span style="font-size:11px; font-weight:bold;">Updated: $CUR_TIME</span>
              <hr class="sep-line">
              <div class="header-stats-row">Temp: $CONSOLIDATED_T • Load: $CONSOLIDATED_L • $FULL_DEVICE_BREAKDOWN</div>
            </div>
            <table id="allTable" class="report_table show-ip">
              <thead><tr>
                <th onclick="sortTable(0, 'allTable')">HOSTNAME</th>
                <th onclick="toggleCols('allTable', 'show-ip', this, 'MAC ADDRESS', 'IP ADDRESS')">IP ADDRESS</th>
                <th onclick="sortTable(2, 'allTable')">RSSI</th>
                <th onclick="sortTable(3, 'allTable')">RX/TX</th>
                <th onclick="toggleCols('allTable', 'show-iface', this, 'SSID', 'IFACE')">SSID</th>
                <th onclick="sortTable(5, 'allTable')">BAND</th>
                <th onclick="sortTable(6, 'allTable')">UPTIME</th>
              </tr></thead>
              <tbody>$(cat $ALL_ROWS)</tbody>
              <tfoot><tr><td colspan="7" style="text-align: center !important;">Uptime: $CONSOLIDATED_U • Reboot: $CONSOLIDATED_B</td></tr></tfoot>
            </table>
          </div>
        </div>
      </div>
    </td>
  </tr>
</table>
<div id="footer"></div>
<div id="popoutModal" class="modal-overlay" onclick="closePopout()">
  <div class="modal-content" onclick="event.stopPropagation()">
    <span class="close-x" onclick="closePopout()">&times;</span>
    <h2 style="color:#0096ff; margin:0 0 10px 0; text-align:center; text-shadow: 0 0 15px rgba(0,150,255,0.7);">Wireless Network</h2>
    <div id="popoutBody" class="modal-grid"></div>
  </div>
</div>
</body>
</html>
HTML
rm -f $SEEN_MACS $ARP_CACHE $YAZ_CACHE $MAIN_ROWS $NODE_ROWS $ALL_ROWS $Q_RELAY
}

case "$1" in
    install)
        # Install/Uninstall options
        # Command: wirelessreport install
        install_menu
        ;;
    inject)
        # Called by services-start to mount the tab
		# Command: wirelessreport inject
        inject_menu
        ;;
    amtmupdate)
        # Called by AMTM for autoupdates
		# Command: wirelessreport amtmupdate
        shift
        ScriptUpdateFromAMTM "$@"
        exit "$?"
        ;;
    *)
        # Run (Scans)
        # Runs if no argument is provided
		run_report
        ;;
esac