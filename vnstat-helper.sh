	# !/bin/bash
	# 🌐 VNSTAT HELPER — Multi-Interface & Oneline Edition
	# Version: 2.8.9

	set -euo pipefail

	# ───────────────────────────────────────────────
	# CONFIGURATION
	# ───────────────────────────────────────────────
	VERSION="2.8.9"
	BASE_DIR="/root/vnstat-helper"
	SELF_PATH="$BASE_DIR/vnstat-helper.sh"
	DATA_FILE="$BASE_DIR/baseline"
	BASELINE_LOG="$BASE_DIR/baseline.log"
	LOG_FILE="$BASE_DIR/log"
	DAILY_LOG="$BASE_DIR/daily.log"
	CRON_FILE="/etc/cron.d/vnstat-daily"
	mkdir -p "$BASE_DIR"

	# Colors
	GREEN="\033[1;32m"; YELLOW="\033[1;33m"; RED="\033[1;31m"
	CYAN="\033[1;36m"; MAGENTA="\033[1;35m"; BLUE="\033[1;34m"; NC="\033[0m"

	# ───────────────────────────────────────────────
	# DEPENDENCY CHECK
	# ───────────────────────────────────────────────
	check_dependencies() {
	  local deps=("vnstat" "jq" "bc")
	  local missing=()
	  for dep in "${deps[@]}"; do
		if ! command -v "$dep" >/dev/null 2>&1; then
		  missing+=("$dep")
		fi
	  done

	  if [ "${#missing[@]}" -gt 0 ]; then
		echo -e "${YELLOW}Missing dependencies:${NC} ${RED}${missing[*]}${NC}"
		read -rp "Install them now? [Y/n]: " ans
		if [[ "${ans,,}" != "n" ]]; then
		  apt update -qq && apt install -y vnstat jq bc
		  systemctl enable vnstat >/dev/null 2>&1 || true
		  systemctl start vnstat >/dev/null 2>&1 || true
		else
		  echo -e "${RED}Dependencies required. Exiting.${NC}"
		  exit 1
		fi
	  fi
	}
	check_dependencies
	
	check_baseline_file() {
	local file="/root/vnstat-helper/baseline"
		if [[ ! -f "$file" ]]; then
			echo "⚠️  Baseline file missing: $file"
			read -rp "Install now? [Y/n]: " ans			
			if [[ "${ans,,}" != "n" ]]; then
			  record_baseline_auto
			fi
		fi
	}

	# ───────────────────────────────────────────────
	# HELPERS
	# ───────────────────────────────────────────────
	detect_ifaces() {
	  ip -br link show | awk '{print $1}' | grep -E '^e|^en|^eth|^wlan' | paste -sd, -
	}

	fmt_uptime() {
	  local up=$(uptime -p | sed 's/^up //')

	  # Compact units
	  up=$(echo "$up" | sed -E 's/weeks?/w/g; s/days?/d/g; s/hours?/h/g; s/minutes?/m/g; s/seconds?/s/g; s/,//g')

	  # If uptime includes weeks or days, drop minutes and seconds
	  if echo "$up" | grep -qE '[wd]'; then
		up=$(echo "$up" | sed -E 's/[0-9]+m//g; s/[0-9]+s//g')
	  fi

	  # Normalize spaces and remove trailing junk
	  up=$(echo "$up" | tr -s ' ' | sed 's/ *$//')

	  echo "$up"
	}


	round2() { printf "%.2f" "$1"; }

	# ───────────────────────────────────────────────
	# UNIT CONVERSION
	# ───────────────────────────────────────────────
	format_size() {
	  local val="$1"
	  local unit="GB"
	  [[ -z "$val" ]] && val=0
	  # if (( $(echo "$val >= 1000" | bc -l) )); then
		# val=$(echo "scale=2; $val/1024" | bc)
		# unit="GB"
	  # fi
	  if (( $(echo "$val >= 1000" | bc -l) )); then
		val=$(echo "scale=2; $val/1024" | bc)
		unit="TB"
	  fi
	  echo "$(round2 "$val") $unit"
	}

	# ───────────────────────────────────────────────
	# SYSTEM INFORMATION
	# ───────────────────────────────────────────────
	system_info() {
	  local HOSTNAME=$(hostname)
	  local OS=$(lsb_release -ds 2>/dev/null || grep PRETTY_NAME /etc/os-release | cut -d= -f2 | tr -d '"')
	  local KERNEL=$(uname -r)
	  local CPU=$(awk -F: '/model name/ {name=$2} END {print name}' /proc/cpuinfo | xargs)
	  local CORES=$(nproc)
	  local MEM_USED=$(free -m | awk '/Mem:/ {print $3}')
	  local MEM_TOTAL=$(free -m | awk '/Mem:/ {print $2}')
	  local DISK_USED=$(df -h / | awk 'NR==2 {print $3}')
	  local DISK_TOTAL=$(df -h / | awk 'NR==2 {print $2}')
	  local LOAD=$(uptime | awk -F'load average:' '{print $2}' | xargs)
	  local IP=$(hostname -I | awk '{print $1}')

	  echo -e "${YELLOW} Hostname:${NC}        $HOSTNAME"
	  echo -e "${YELLOW} OS:${NC}              $OS"
	  echo -e "${YELLOW} Kernel:${NC}          $KERNEL"
	  echo -e "${YELLOW} CPU:${NC}             $CPU ($CORES cores)"
	  echo -e "${YELLOW} Memory:${NC}          ${MEM_USED}MB / ${MEM_TOTAL}MB"
	  echo -e "${YELLOW} Disk:${NC}            ${DISK_USED} / ${DISK_TOTAL}"
	  echo -e "${YELLOW} Load Average:${NC}    $LOAD"
	  echo -e "${YELLOW} IP Address:${NC}      $IP"
	}

	# ───────────────────────────────────────────────
	# VNSTAT DATA (Multi-Interface Aggregation)
	# ───────────────────────────────────────────────
	get_vnstat_data() {
	  local total_rx=0 total_tx=0 total_sum=0
	  local rx_val tx_val rx_unit tx_unit RX_GB TX_GB

	  for iface in $(ip -br link show | awk '{print $1}' | grep -E '^e|^en|^eth|^wlan'); do
		line=$(vnstat --oneline -i "$iface" 2>/dev/null || true)
		[[ -z "$line" ]] && continue

		# Extract value + unit for RX/TX (fields 9/10)
		rx_val=$(echo "$line" | awk -F';' '{print $9}' | awk '{print $1}')
		rx_unit=$(echo "$line" | awk -F';' '{print $9}' | awk '{print $2}')
		tx_val=$(echo "$line" | awk -F';' '{print $10}' | awk '{print $1}')
		tx_unit=$(echo "$line" | awk -F';' '{print $10}' | awk '{print $2}')

		[[ -z "$rx_val" || -z "$tx_val" ]] && continue

		# Convert based on unit reported by vnStat
		case "$rx_unit" in
		  KiB|kib) RX_GB=$(echo "scale=6; $rx_val/1024/1024" | bc) ;;
		  MiB|mib) RX_GB=$(echo "scale=6; $rx_val/1024" | bc) ;;
		  GiB|gib|G|Gi) RX_GB=$(echo "scale=6; $rx_val" | bc) ;;
		  TiB|tib|T|Ti) RX_GB=$(echo "scale=6; $rx_val*1024" | bc) ;;
		  *) RX_GB=$(echo "scale=6; $rx_val/1024/1024" | bc) ;;
		esac

		case "$tx_unit" in
		  KiB|kib) TX_GB=$(echo "scale=6; $tx_val/1024/1024" | bc) ;;
		  MiB|mib) TX_GB=$(echo "scale=6; $tx_val/1024" | bc) ;;
		  GiB|gib|G|Gi) TX_GB=$(echo "scale=6; $tx_val" | bc) ;;
		  TiB|tib|T|Ti) TX_GB=$(echo "scale=6; $tx_val*1024" | bc) ;;
		  *) TX_GB=$(echo "scale=6; $tx_val/1024/1024" | bc) ;;
		esac

		total_rx=$(echo "$total_rx + $RX_GB" | bc)
		total_tx=$(echo "$total_tx + $TX_GB" | bc)
	  done

	  total_sum=$(echo "$total_rx + $total_tx" | bc)
	  echo "$(round2 "$total_rx") $(round2 "$total_tx") $(round2 "$total_sum")"
	}



	# ───────────────────────────────────────────────
	# VNSTAT FUNCTIONS MENU
	# ───────────────────────────────────────────────
	vnstat_functions_menu() {
	  local iface=$(ip -br link show | awk '{print $1}' | grep -E '^e|^en|^eth|^wlan' | head -n1)
	  while true; do
		clear
		echo -e "${BLUE}╔══════════════════════════════════════════════════════╗${NC}"
		echo -e "${BLUE}             ⚙️ vnStat Utilities${NC}"
		echo -e "${BLUE}╚══════════════════════════════════════════════════════╝${NC}"
		echo -e " ${GREEN}[1]${NC} Daily Stats"
		echo -e " ${GREEN}[2]${NC} Monthly Stats"
		echo -e " ${GREEN}[3]${NC} Yearly Stats"
		echo -e " ${GREEN}[4]${NC} Top Days"
		echo -e " ${GREEN}[5]${NC} Reset Database"
		echo -e " ${GREEN}[6]${NC} Install / Update vnStat"
		echo -e " ${GREEN}[7]${NC} Uninstall vnStat"
		echo -e " ${GREEN}[0]${NC} Return"
		echo -e "${CYAN}────────────────────────────────────────────────────────${NC}"
		read -rp "Select: " f
		case "${f^^}" in
		  1) vnstat --days -i "$iface";;
		  2) vnstat --months -i "$iface";;
		  3) vnstat --years -i "$iface";;
		  4) vnstat --top -i "$iface";;
		  5) systemctl stop vnstat; rm -rf /var/lib/vnstat; systemctl start vnstat; echo -e "${GREEN}Database reset.${NC}";;
		  6) apt update -qq && apt install -y vnstat jq bc; systemctl enable vnstat; systemctl start vnstat; echo -e "${GREEN}vnStat installed/updated.${NC}";;
		  7) apt purge -y vnstat; rm -rf /var/lib/vnstat /etc/vnstat.conf; echo -e "${GREEN}vnStat removed.${NC}";;
		  0) return;;
		  *) echo -e "${RED}Invalid option.${NC}";;
		esac
		read -n 1 -s -r -p "Press any key to continue..."
	  done
	}

	# ───────────────────────────────────────────────
	# BASELINE MANAGEMENT
	# ───────────────────────────────────────────────
	record_baseline_auto() {
	  # check baseline data from system
	  local total_rx=0 total_tx=0
	  for iface in $(ip -br link show | awk '{print $1}' | grep -E '^e|^en|^eth|^wlan'); do
		read RX TX <<<$(ip -s link show "$iface" | awk '/RX:/{getline;rx=$1} /TX:/{getline;tx=$1} END{print rx,tx}')
		RX_GB=$(echo "scale=6; $RX/1024/1024/1024" | bc)
		TX_GB=$(echo "scale=6; $TX/1024/1024/1024" | bc)
		total_rx=$(echo "$total_rx + $RX_GB" | bc)
		total_tx=$(echo "$total_tx + $TX_GB" | bc)
	  done
	  # record baseline data to file
	  total=$(echo "$total_rx + $total_tx" | bc)
	  local TIME=$(date '+%Y-%m-%d %H:%M')  
	  # set main baseline data
	  {
		echo "BASE_RX=$(round2 "$total_rx")"
		echo "BASE_TX=$(round2 "$total_tx")"
		echo "BASE_TOTAL=$(round2 "$total")"
		echo "RECORDED_TIME=\"$TIME\""
	  } > "$DATA_FILE"
	  # update baseline log
	  echo "$TIME | Auto | $total_rx GB | $total_tx GB | $total GB" >> "$BASELINE_LOG"
	  
	  echo -e "${GREEN}New baseline recorded: ${YELLOW}${total} GB${NC}"
	}
	  
	record_baseline_manual() {
	  
	  read -rp "Enter manual baseline total (in GB): " input
	  [[ -z "$input" ]] && echo -e "${RED}No value entered.${NC}" && return  
	  # set main baseline data
	  local total_rx=0 total_tx=0 total=0
	  total=$(round2 "$input")
	  local TIME=$(date '+%Y-%m-%d %H:%M')
	  {
		echo "BASE_RX=\"$total_rx\""
		echo "BASE_TX=\"$total_tx\""
		echo "BASE_TOTAL=\"$total\""
		echo "RECORDED_TIME=\"$TIME\""
	  } > "$DATA_FILE"
	  # update baseline log
	  echo "$TIME | Auto | $total_rx GB | $total_tx GB | $total GB" >> "$BASELINE_LOG"
	  
	  echo -e "${GREEN}Manual baseline set to ${YELLOW}${input} GB${NC}"
	}

	select_baseline_from_log() {
	  if [ ! -s "$BASELINE_LOG" ]; then
		echo -e "${RED}No baselines in log.${NC}"; return
	  fi
	  echo -e "${CYAN}──────────────────────────────────────────────${NC}"
	  nl -w2 -s". " <(tac "$BASELINE_LOG")
	  echo -e "${CYAN}──────────────────────────────────────────────${NC}"
	  read -rp "Select baseline number: " choice
	  line=$(tac "$BASELINE_LOG" | sed -n "${choice}p")
	  [[ -z "$line" ]] && echo -e "${RED}Invalid selection.${NC}" && return
	  
	  # Parse baseline values from the input line
	  # echo "$TIME | Auto | $total_rx GB" | $total_tx GB" | $total GB" >> "$BASELINE_LOG"
		
	  # Extract values from the log line
	  baseline_time=$(echo "$line" | awk -F'|' '{print $1}' | xargs)
	  baseline_rx_value=$(echo "$line" | awk -F'|' '{print $3}' | awk '{print $1}')
	  baseline_tx_value=$(echo "$line" | awk -F'|' '{print $4}' | awk '{print $1}')
	  baseline_total_value=$(echo "$line" | awk -F'|' '{print $5}' | awk '{print $1}')
	  
	  # Write baseline data to file
	  {
		echo "BASE_RX=$(round2 "$baseline_rx_value")"
		echo "BASE_TX=$(round2 "$baseline_tx_value")"
		echo "BASE_TOTAL=$(round2 "$baseline_total_value")"
		echo "RECORDED_TIME=\"$baseline_time\""
	  } > "$DATA_FILE"

	  # Display confirmation
	  echo -e "${GREEN}Selected"
	  echo -e "${GREEN}Baseline RX/Download: ${YELLOW}${baseline_rx_value} GB${NC}"
	  echo -e "${GREEN}Baseline TX/Upload: ${YELLOW}${baseline_tx_value} GB${NC}"
	  echo -e "${GREEN}Baseline Total: ${YELLOW}${baseline_total_value} GB${NC}"
	  echo -e "${GREEN}Timestamp: ${YELLOW}${baseline_time}${NC}"
	}

	baseline_menu() {
	  while true; do
		clear
		echo -e "${BLUE}╔════════════════════════════════════════════════════╗${NC}"
		echo -e "${BLUE}           ⚙️  Baseline Options${NC}"
		echo -e "${BLUE}╚════════════════════════════════════════════════════╝${NC}"
		echo -e " ${GREEN}[1]${NC} Record Current Total as Baseline"
		echo -e " ${GREEN}[2]${NC} Enter Manual Baseline"
		echo -e " ${GREEN}[3]${NC} Select Baseline from Log"
		echo -e " ${GREEN}[0]${NC} Back"
		echo -e "${CYAN}────────────────────────────────────────────────────${NC}"
		read -rp "Select: " opt
		case "${opt^^}" in
		  1) record_baseline_auto ;;
		  2) record_baseline_manual ;;
		  3) select_baseline_from_log ;;
		  0) return ;;
		  *) echo -e "${RED}Invalid option.${NC}" ;;
		esac
		read -n 1 -s -r -p "Press any key to continue..."
	  done
	}

	# ───────────────────────────────────────────────
	# AUTO TRAFFIC MENU (CRON)
	# ───────────────────────────────────────────────
	auto_traffic_menu() {
	  local status="Disabled"
	  if [ -f "$CRON_FILE" ]; then
		case "$(cat "$CRON_FILE")" in
		  *"0 * * * *"*) status="Hourly" ;;
		  *"0 0 * * *"*) status="Daily" ;;
		  *"0 0 * * 0"*) status="Weekly" ;;
		  *"0 0 1 * *"*) status="Monthly" ;;
		esac
	  fi
	  echo -e "${CYAN}──────────────────────────────────────────────${NC}"
	  echo -e "${YELLOW}Auto Traffic (Current: ${status})${NC}"
	  echo -e "${CYAN}──────────────────────────────────────────────${NC}"
	  echo "1) Enable Hourly"
	  echo "2) Enable Daily"
	  echo "3) Enable Weekly"
	  echo "4) Enable Monthly"
	  echo "5) Disable"
	  echo "0) Back"
	  echo -e "${CYAN}──────────────────────────────────────────────${NC}"
	  read -rp "Select: " x
	  case "${x^^}" in
		1) echo "0 * * * * root $SELF_PATH >>$DAILY_LOG 2>&1" > "$CRON_FILE";;
		2) echo "0 0 * * * root $SELF_PATH >>$DAILY_LOG 2>&1" > "$CRON_FILE";;
		3) echo "0 0 * * 0 root $SELF_PATH >>$DAILY_LOG 2>&1" > "$CRON_FILE";;
		4) echo "0 0 1 * * root $SELF_PATH >>$DAILY_LOG 2>&1" > "$CRON_FILE";;
		5) rm -f "$CRON_FILE";;
		0) return ;;
		*) echo -e "${RED}Invalid choice.${NC}" ;;
	  esac
	  echo -e "${GREEN}Auto Traffic updated.${NC}"
	}

	# ───────────────────────────────────────────────
	# VIEW TRAFFIC LOG
	# ───────────────────────────────────────────────
	view_traffic_log() {
	  echo -e "${CYAN}────────────────────────────────────────────────────────${NC}"
	  echo -e "${YELLOW} Traffic Log — $DAILY_LOG ${NC}"
	  echo -e "${CYAN}────────────────────────────────────────────────────────${NC}"
	  if [ -s "$DAILY_LOG" ]; then
		tail -n 20 "$DAILY_LOG" | awk '{print NR")", $0}'
	  else
		echo -e "${RED}No traffic logs found.${NC}"
	  fi
	  echo -e "${CYAN}────────────────────────────────────────────────────────${NC}"
	}

	# ───────────────────────────────────────────────
	# DASHBOARD
	# ───────────────────────────────────────────────
	show_dashboard() {
	  clear	  
	  # Data Information
	  BASE_TOTAL=0; BASE_RX=0; BASE_TX=0; RECORDED_TIME="N/A"
	  [ -f "$DATA_FILE" ] && source "$DATA_FILE"
	  
	  BASE_RX=$(round2 "${BASE_RX:-0}")
	  BASE_RX_SHOW=$(format_size "$(echo "$BASE_RX" | bc)")
	  BASE_TX=$(round2 "${BASE_TX:-0}")
	  BASE_TX_SHOW=$(format_size "$(echo "$BASE_TX" | bc)")
	  BASE_TOTAL=$(round2 "${BASE_TOTAL:-0}")  
	  BASE_TOTAL_SHOW=$(format_size "$(echo "$BASE_TOTAL" | bc)")
	  
	  read RX_GB TX_GB TOTAL_GB < <(get_vnstat_data)
	  
	  RX_GB_SHOW=$(format_size "$RX_GB")
	  TX_GB_SHOW=$(format_size "$TX_GB")
	  TOTAL_GB_SHOW=$(format_size "$TOTAL_GB")
	  
	  RX_SUM=$(echo "scale=6; $BASE_RX + $RX_GB" | bc)
	  RX_SUM=$(round2 "$RX_SUM")
	  RX_SUM_SHOW=$(format_size "$RX_SUM")
	  TX_SUM=$(echo "scale=6; $BASE_TX + $TX_GB" | bc)
	  TX_SUM=$(round2 "$TX_SUM")
	  TX_SUM_SHOW=$(format_size "$TX_SUM")
	  TOTAL_SUM=$(echo "scale=6; $BASE_TOTAL + $TOTAL_GB" | bc)
	  TOTAL_SUM=$(round2 "$TOTAL_SUM")
	  TOTAL_SUM_SHOW=$(format_size "$TOTAL_SUM")

	  echo -e "${BLUE}╔════════════════════════════════════════════════════════════╗${NC}"
	  echo -e "${BLUE}       🌐 VNSTAT HELPER v${VERSION}   |   vnStat v$(vnstat --version | awk '{print $2}') ${NC}"
	  echo -e "${BLUE}╚════════════════════════════════════════════════════════════╝${NC}"    
	  system_info
	  echo -e "${CYAN} ────────────────────────────────────────────────────────────${NC}"    
	  printf "${MAGENTA} %-13s${NC} %-19s ${MAGENTA}%-12s${NC} %s\n" \
		"Boot Time:" "$(who -b | awk '{print $3, $4}')" "Interfaces:" "$(detect_ifaces)"
	  printf "${MAGENTA} %-13s${NC} %-19s ${MAGENTA}%-12s${NC} %s\n" \
		"Server Time:" "$(date '+%Y-%m-%d %H:%M')" "Uptime:" "$(fmt_uptime)"
	  echo -e "${CYAN} ────────────────────────────────────────────────────────────${NC}"
	  printf "${YELLOW} %-10s %-10s %-10s %-10s %-20s ${NC}\n" "Type" "RX/UL" "TX/DL" "Total" "Timestamp"
	  echo -e "${CYAN} ────────────────────────────────────────────────────────────${NC}"
	  printf " %-10s %-10s %-10s %-10s %-20s\n" "Baseline" "$BASE_RX_SHOW" "$BASE_TX_SHOW" "$BASE_TOTAL_SHOW" "$RECORDED_TIME"
	  printf " %-10s %-10s %-10s %-10s %-20s\n" "vnStat" "$RX_GB_SHOW" "$TX_GB_SHOW" "$TOTAL_GB_SHOW" "$(date '+%Y-%m-%d %H:%M')"
	  printf " %-10s %-10s %-10s %-10s %-20s\n" "SUM" "$RX_SUM_SHOW" "$TX_SUM_SHOW" "$TOTAL_SUM_SHOW"
	  echo -e "${CYAN} ────────────────────────────────────────────────────────────${NC}"
	  
	}

	# ───────────────────────────────────────────────
	# MAIN MENU
	# ───────────────────────────────────────────────
	check_baseline_file
	while true; do
	  show_dashboard
	  echo -e " ${GREEN}[1]${NC} Daily Stats             ${GREEN}[5]${NC} Baseline Options"
	  echo -e " ${GREEN}[2]${NC} Monthly Stats           ${GREEN}[6]${NC} vnStat Functions"
	  echo -e " ${GREEN}[3]${NC} Traffic Log             ${GREEN}[7]${NC} Traffic Options"
	  echo -e " ${GREEN}[4]${NC} Logs                    ${GREEN}[0]${NC} Quit"
	  echo -e "${CYAN} ────────────────────────────────────────────────────────────${NC}"
	  read -rp "Select: " ch
	  echo ""
	  case "${ch^^}" in
		1) vnstat --days ;;
		2) vnstat --months ;;
		3) view_traffic_log ;;
		4) tail -n 20 "$LOG_FILE" 2>/dev/null || echo -e "${YELLOW}No logs yet.${NC}" ;;
		5) baseline_menu ;;
		6) vnstat_functions_menu ;;
		7) auto_traffic_menu ;;
		*) echo -e "${RED}Invalid option.${NC}" ;;
	  esac
	  echo ""
	  read -n 1 -s -r -p "Press any key to continue..."
	done
